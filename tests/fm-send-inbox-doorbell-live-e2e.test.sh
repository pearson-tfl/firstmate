#!/usr/bin/env bash
# tests/fm-send-inbox-doorbell-live-e2e.test.sh - the live doorbell guard
# (live-harness-optin family).
#
# The steering inbox's one behavioral assumption is that a real worker agent
# follows the constant self-describing doorbell line: list the inbox, read and
# act on its records in numeric order, then mv each into handled/. The
# doorbell names the inbox as "$FM_TASK_INBOX", so each worker is launched the
# way bin/fm-spawn.sh launches it, with FM_TASK_INBOX exported to its home's
# state/<task>.inbox, and receives no brief at all: it must resolve the inbox
# from the doorbell plus its own environment. A stub can only confirm the
# assumption already written into the stub, so per
# .agents/skills/firstmate-coding-guidelines this is proven against every
# INSTALLED verified harness: each is launched idle in an isolated tmux server,
# steered through the REAL fm-send (durable record + doorbell), and must both
# ACT on the instruction (create a named file) and ACKNOWLEDGE it (the mv into
# handled/), failing loudly with the harness name and version.
#
# Run explicitly with FM_SEND_INBOX_LIVE_E2E=1. This test spends a small
# number of real model tokens per installed harness (one short turn each) -
# authorized by the harness-dependent-checks rule. An absent harness is
# reported explicitly and skipped; a run that verified nothing fails rather
# than passing vacuously. Restrict with
# FM_SEND_INBOX_LIVE_HARNESSES="claude codex ..." when needed, and tune the
# per-harness wait with FM_SEND_INBOX_LIVE_TIMEOUT (seconds, default 240).
# Record the dated per-harness result in
# docs/verification/runtime-backends.md ("Steering-inbox doorbell").
#
# Folder trust: harnesses launch with the repo root as cwd, which the
# operator's machine has normally already trusted; a trust dialog is a real
# unready state and correctly fails that harness's check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# FM_WORKFLOW_SKILL_LIVE=1 exercises literal openers and stored workflow
# steers in real Claude/Pi/Codex print-mode sessions. PI provider/model can be
# selected with FM_WORKFLOW_PI_PROVIDER and FM_WORKFLOW_PI_MODEL. Pi runs with
# the production worker flags: its real agent directory and extensions, the
# Firstmate busy extension fm-spawn writes, and default skill discovery from
# the user-level ~/.agents/skills (a lab HOME holding the fixture skills beside
# links to the real ones), never --skill. Proof lives in
# FM_WORKFLOW_SKILL_PROOF_DIR (otherwise a temporary directory).
if [ "${FM_WORKFLOW_SKILL_LIVE:-0}" = 1 ]; then
  fm_live_gate opt-in FM_WORKFLOW_SKILL_LIVE python3
  PROOF_DIR=${FM_WORKFLOW_SKILL_PROOF_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/fm-workflow-skill.XXXXXX")}
  python3 - "$ROOT" "$PROOF_DIR" <<'PY'
"""Live opener + stored-steer proof, called by the existing doorbell live guard.

Uses real print-mode sessions, resuming each for its stored steer. Random
sentinels occur only in SKILL.md, never in the prompts or skill descriptions.
The durable writer and constant doorbell are production inbox interfaces.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

root, lab = map(Path, sys.argv[1:3])
lab.mkdir(parents=True, exist_ok=True)
checked = 0
real_home = Path.home()


def pi_executable():
    # The mise shim re-resolves under HOME; the lab HOME must reach the real binary.
    if shutil.which("mise"):
        found = subprocess.run(["mise", "which", "pi"], capture_output=True, text=True)
        if found.returncode == 0 and found.stdout.strip():
            return found.stdout.strip()
    return shutil.which("pi")


def firstmate_pi_extension(directory, task):
    """Render the worker busy extension exactly as fm-spawn writes it."""
    source = (root / "bin/fm-spawn.sh").read_text()
    start = source.index('cat >"$STATE/$ID.pi-ext.ts" <<EOF\n') + len('cat >"$STATE/$ID.pi-ext.ts" <<EOF\n')
    body = source[start:source.index("\nEOF\n", start)]
    state = directory / "state"
    (directory / "config").mkdir(exist_ok=True)
    values = {"busy_notify_turnend": "true", "EXCLUDE_TOOLS": "", "CONFIG": str(directory / "config"),
              "STATE": str(state), "ID": task, "FM_ROOT": str(root), "STATE_REAL": str(state.resolve()),
              "BUSY_GEN": "1", "TURNEND": str(state / (task + ".turn-ended"))}
    rendered = subprocess.check_output(["bash", "-c", 'eval "cat <<EOF\n$1\nEOF"', "_", body],
                                       env={**os.environ, **values}, text=True)
    extension = state / (task + ".pi-ext.ts")
    extension.write_text(rendered)
    return extension


def run(args, directory, output, env):
    (directory / (output + ".command.json")).write_text(json.dumps(args))
    with (directory / output).open("w") as stream:
        result = subprocess.run(args, cwd=directory, env=env, stdin=subprocess.DEVNULL, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=180, check=False)
    if result.returncode:
        raise RuntimeError(f"{args[0]} exited {result.returncode}; see {directory / output}")
    events = []
    for line in (directory / output).read_text().splitlines():
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return events


def assistant_text(events):
    texts = []
    for event in events:
        if event.get("type") in ("message_end", "assistant"):
            message = event.get("message", {})
            if message.get("stopReason") == "error":
                raise RuntimeError(message.get("errorMessage", "provider error"))
            if message.get("role") == "assistant":
                texts.extend(block.get("text", "") for block in message.get("content", [])
                             if block.get("type") == "text")
        if event.get("type") == "item.completed":
            item = event.get("item", {})
            if item.get("type") == "agent_message":
                texts.append(item.get("text", ""))
    return texts


for harness in ("claude", "pi", "codex"):
    executable = pi_executable() if harness == "pi" else shutil.which(harness)
    if not executable:
        print(f"skip: workflow skills: {harness} absent", flush=True)
        continue
    version = subprocess.check_output([executable, "--version"], text=True).strip()
    print(f"# checking {harness} {version}", flush=True)
    directory = lab / harness
    directory.mkdir(exist_ok=True)
    env = os.environ.copy()
    env["DISABLE_AUTOUPDATER"] = "1"
    env["FM_STATE_OVERRIDE"] = str(directory / "state")
    env["FM_TASK_INBOX"] = str(directory / "state/proof.inbox")
    (directory / "state").mkdir(exist_ok=True)
    skills = directory / ".agents/skills"
    if harness == "pi":
        env["PI_CODING_AGENT_DIR"] = os.environ.get("PI_CODING_AGENT_DIR", str(real_home / ".pi/agent"))
        env["HOME"] = str(directory / "home")
        skills = directory / "home/.agents/skills"
        skills.mkdir(parents=True, exist_ok=True)
        real_skills = real_home / ".agents/skills"
        for installed in (real_skills.iterdir() if real_skills.is_dir() else ()):
            if not (skills / installed.name).exists():
                (skills / installed.name).symlink_to(installed)
    tokens = {}
    for name in ("fm-opener-proof", "fm-steer-proof"):
        skill = skills / name
        skill.mkdir(parents=True, exist_ok=True)
        tokens[name] = "SKILL_" + uuid.uuid4().hex
        body = f"Reply with exactly {tokens[name]} and do nothing else."
        if name == "fm-steer-proof":
            body = f"Move the pending inbox record to its handled directory, then {body.lower()}"
        (skill / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: Live verification fixture.\n---\n{body}\n")
        claude_skill = directory / ".claude/skills" / name
        claude_skill.parent.mkdir(parents=True, exist_ok=True)
        if harness == "claude" and not claude_skill.exists():
            claude_skill.symlink_to(skill)
    brief = directory / "brief.md"
    brief.write_text("/fm-opener-proof\n\nFollow the invoked skill. Read-only verification.\n")
    opener = subprocess.check_output(
        ["bash", str(root / "bin/fm-skill-opener.sh"), harness,
         "record" if harness == "claude" else "encode", str(brief)], env=env, text=True)
    (directory / "opener.prompt").write_text(opener)
    session = str(uuid.uuid4())
    if harness == "claude":
        common = ["claude", "-p", "--setting-sources", "project,local",
                  "--dangerously-skip-permissions", "--output-format", "stream-json", "--verbose"]
        args = common + ["--session-id", session, opener]
    elif harness == "pi":
        common = [executable, "-p", "--mode", "json",
                  "--provider", os.environ.get("FM_WORKFLOW_PI_PROVIDER", "openai"),
                  "--model", os.environ.get("FM_WORKFLOW_PI_MODEL", "openai/gpt-6.1-sol"),
                  "--session-dir", str(directory / "sessions"), "--session-id", session,
                  "-e", str(firstmate_pi_extension(directory, "proof"))]
        args = common + [opener]
    else:
        common = ["codex", "exec", "--json", "--skip-git-repo-check", "--disable", "hooks",
                  "-c", 'sandbox_mode="danger-full-access"']
        args = common + [opener]
    events = run(args, directory, "opener.out", env)
    if not any(tokens["fm-opener-proof"] in text for text in assistant_text(events)):
        raise RuntimeError(f"{harness} {version}: opener did not return skill-only sentinel")
    if harness == "codex":
        session = next(event["thread_id"] for event in events if event.get("type") == "thread.started")
    # Reuse fm-send's production stored-step formatter, then enqueue behind
    # the constant doorbell. The prompt contains neither the body nor sentinel.
    script = '. "$1/bin/fm-skill-opener.sh"; . "$1/bin/fm-task-inbox-lib.sh"; '
    script += 'body=$(fm_skill_steer "$2" fm-steer-proof "Follow this step.") || exit; '
    script += 'rec=$(fm_task_inbox_write "$3" proof "$body") || exit; fm_task_inbox_doorbell_line "$rec"'
    doorbell = subprocess.check_output(["bash", "-c", script, "_", str(root), harness,
                                       str(directory / "state")], env=env, text=True)
    # The ordinary launch establishes FM_TASK_INBOX. Repeat its exact path
    # here because print-mode Codex does not preserve arbitrary env on resume.
    steer = doorbell + "\nYour task inbox is " + env["FM_TASK_INBOX"] + "."
    (directory / "steer.prompt").write_text(steer)
    if harness == "claude":
        args = common + ["--resume", session, steer]
    elif harness == "pi":
        args = common + [steer]
    else:
        args = ["codex", "exec", "resume", "--json", "--skip-git-repo-check", "--disable", "hooks",
                "-c", 'sandbox_mode="danger-full-access"', session, steer]
    events = run(args, directory, "steer.out", env)
    # The steer fixture lowercases the requested token as part of its rule.
    if not any(tokens["fm-steer-proof"].lower() in text for text in assistant_text(events)):
        raise RuntimeError(f"{harness} {version}: steer did not return skill-only sentinel")
    if not (directory / "state/proof.inbox/handled/001.msg").is_file():
        raise RuntimeError(f"{harness} {version}: steer was not acknowledged")
    checked += 1
    print(f"ok - {harness} {version}: opener and stored steer loaded skill-only sentinels; steer acknowledged", flush=True)

if not checked:
    raise RuntimeError("no installed harness was verified")
print(f"workflow skills: {checked} real harnesses verified", flush=True)
PY
  exit $?
fi
fm_live_gate opt-in FM_SEND_INBOX_LIVE_E2E tmux

unset NO_MISTAKES_GATE

SOCKET="fm-inbox-live-$$"
SESSION="inboxlive"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-inbox-live.XXXXXX")
LAB=$(cd "$LAB" && pwd)
TIMEOUT=${FM_SEND_INBOX_LIVE_TIMEOUT:-240}
CHECKED=0
FAILED=0

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

# fm-send and the composer readiness read both reach tmux through bare `tmux`
# calls, so a PATH shim pins them to the private socket.
SHIM_DIR="$LAB/shim"
mkdir -p "$SHIM_DIR"
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -c "$ROOT"

harness_version() {  # <binary>
  "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'
}

# Launch <name> idle with its unattended-autonomy flags (the same posture
# bin/fm-spawn.sh uses), so the doorbell-triggered shell actions need no
# interactive approval.
launch_cmd() {  # <name>
  case "$1" in
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '\''{"feedbackDrafts":"off"}'\''' ;;
    codex) printf '%s' 'codex --dangerously-bypass-approvals-and-sandbox --disable hooks' ;;
    opencode) printf '%s' "OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' opencode" ;;
    pi|pi-signed) printf '%s' "$1" ;;
    grok) printf '%s' 'grok --always-approve' ;;
    kimi) printf '%s' 'kimi --auto' ;;
    muse) printf '%s' 'MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on muse --yolo' ;;
    *) return 1 ;;
  esac
}

# codex's crewmate launch in bin/fm-spawn.sh carries --disable hooks because the
# hook-trust modal ("N hooks are new or changed") opens on "Review hooks" and
# firstmate's key plane has no arrow navigation to move off it. Without the flag
# this guard parks on that dialog for the whole timeout and reports the doorbell
# unhonored, which is a dialog verdict rather than a doorbell one, so pin the
# switch here instead of letting the codex check go quietly unprovable again.
case "$(launch_cmd codex)" in
  *'--disable hooks'*) ;;
  *) fail 'codex launch recipe lost --disable hooks; the check would park on the hook-trust modal instead of judging the doorbell' ;;
esac

# Wait for the harness to look steerable. 0 = the composer classified a
# proven empty; 2 = the readiness budget expired without an empty verdict but
# also without a pending one. The caller proceeds on 2 with a note, because
# that mirrors production exactly: the send path's composer check is ADVISORY
# and skips only on visibly pending text, so a harness whose idle screen the
# classifier cannot positively identify still gets its doorbell (the composer
# matrix guard, not this one, owns re-proving the classifier per release).
wait_ready() {  # <window>
  local win=$1 i=0 budget=60 verdict dismissed=0 screen
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_tmux_composer_state "$SESSION:$win")
    [ "$verdict" = empty ] && return 0
    i=$((i + 1))
    # Dismiss one non-trust startup modal (update prompts), as the composer
    # matrix guard does; never Enter, which could accept an upgrade.
    if [ "$dismissed" -eq 0 ] && [ "$i" -ge $((budget / 3)) ]; then
      screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null || true)
      if ! printf '%s\n' "$screen" | grep -qi 'trust'; then
        tmux -L "$SOCKET" send-keys -t "$SESSION:$win" Escape 2>/dev/null || true
      fi
      dismissed=1
    fi
    sleep 1
  done
  case "$verdict" in
    pending) return 1 ;;
  esac
  return 2
}

check_harness_doorbell() {  # <name>
  local name=$1 version cmd win="hx-$1" home task acted rec handled i ready_rc
  version=$(harness_version "$name")
  cmd=$(launch_cmd "$name") || { note "no launch recipe for $name"; return 0; }
  home="$LAB/$name-home"
  mkdir -p "$home/state"
  task="live-$name"
  acted="$LAB/acted-$name"
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$ROOT" \
    -- bash -lc "export FM_TASK_INBOX=$(printf '%q' "$home/state/$task.inbox"); $cmd" \
    || { FAILED=1; printf 'not ok - %s (%s): could not launch in the isolated tmux server\n' "$name" "$version" >&2; return 0; }
  wait_ready "$win"; ready_rc=$?
  if [ "$ready_rc" -eq 1 ]; then
    FAILED=1
    printf 'not ok - %s (%s): composer stayed visibly pending; the pane is not steerable\n' "$name" "$version" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -6 | sed 's/^/#   /' >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  [ "$ready_rc" -eq 0 ] || note "$name ($version): idle composer never classified empty; proceeding as production does (advisory check skips only on pending)"
  printf 'window=%s:%s\nkind=ship\nharness=%s\n' "$SESSION" "$win" "$name" > "$home/state/$task.meta"
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task" \
    "Firstmate live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message. Reply with one short line." \
    >/dev/null 2>&1; then
    FAILED=1
    printf 'not ok - %s (%s): fm-send refused the live steer\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  rec="$home/state/$task.inbox/001.msg"
  handled="$home/state/$task.inbox/handled/001.msg"
  [ -f "$rec" ] || {
    FAILED=1
    printf 'not ok - %s (%s): fm-send left no durable inbox record\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  }
  i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    [ -f "$handled" ] && [ -e "$acted" ] && break
    # Halfway through, play the watcher's role once: re-ring an unacknowledged
    # message so a doorbell swallowed by a startup or update modal recovers
    # exactly as the production re-ring ladder recovers it.
    if [ "$i" -eq $((TIMEOUT / 2)) ] && [ -f "$rec" ]; then
      fm_task_inbox_ring tmux "$SESSION:$win" "$rec" || true
      note "$name ($version): re-rang the doorbell once (watcher's role) at ${i}s"
    fi
    sleep 1
    i=$((i + 1))
  done
  if [ -f "$handled" ] && [ -e "$acted" ]; then
    CHECKED=$((CHECKED + 1))
    pass "$name ($version): the doorbell reached a real worker, which acted and acked with the mv"
  else
    FAILED=1
    printf 'not ok - %s (%s): doorbell not honored within %ss (acted=%s acked=%s)\n' \
      "$name" "$version" "$TIMEOUT" "$([ -e "$acted" ] && echo yes || echo no)" \
      "$([ -f "$handled" ] && echo yes || echo no)" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
  fi
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

HARNESSES=${FM_SEND_INBOX_LIVE_HARNESSES:-'claude codex opencode pi grok kimi muse'}
for h in $HARNESSES; do
  if command -v "$h" >/dev/null 2>&1; then
    check_harness_doorbell "$h"
  else
    note "harness absent, not verified here: $h"
  fi
done

if [ "$FAILED" -ne 0 ]; then
  printf 'not ok - live steering-inbox doorbell guard found failures above\n' >&2
  exit 1
fi
if [ "$CHECKED" -eq 0 ]; then
  printf 'not ok - live steering-inbox doorbell guard verified nothing (no harness installed?)\n' >&2
  exit 1
fi
pass "live steering-inbox doorbell guard: $CHECKED harness(es) honored the doorbell contract"
