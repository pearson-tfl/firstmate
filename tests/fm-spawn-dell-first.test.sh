#!/usr/bin/env bash
# Behavior tests for Dell-first placement of Mac worker spawns, through fm-spawn.sh.
# A stand-in AHR checkout under the throwaway HOME provides placement.py and the
# lane-tools list; a fake ssh answers the Dell capacity probe and lane-tools --check.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-dell-first)
export FM_BACKEND=tmux
# Resolve before faking uname: version-manager shims may themselves inspect it.
PYTHON=$(python3 -c 'import os, sys; print(os.path.realpath(sys.executable))')
ROOM='{"mem_available_kb":134217728,"cpu_idle_percent":90,"cores":32,"disc_free_mb":1000000,"repo_error":"not cloned on Dell"}'
LOW='{"mem_available_kb":524288,"cpu_idle_percent":90,"cores":32,"disc_free_mb":1000000}'

make_case() {
  ID=$1
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  PROBE_LOG="$CASE_DIR/probe.log"
  READING="$CASE_DIR/dell.json"
  TOOLS_LINE="$CASE_DIR/tools.line"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  ln -s "$PYTHON" "$FAKEBIN/python3"
  fm_test_spawn_home "$HOME_DIR" codex
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$1"
  fm_test_spawn_brief "$HOME_DIR" "$1"
  printf '%s\n' '- dellmate - Dell partner. (host: dell; root: /r; home: /h; scope: all; projects: p; added 2026-11-27)' \
    > "$HOME_DIR/data/secondmates.md"
  cat > "$FAKEBIN/uname" <<'SH'
#!/bin/sh
printf '%s\n' "${FM_TEST_KERNEL:-Darwin}"
SH
  cat > "$FAKEBIN/ssh" <<'SH'
#!/bin/sh
cat >/dev/null
[ "${FM_TEST_SSH_FAILURE:-0}" = 0 ] || exit 255
for a in "$@"; do
  case "$a" in
  *lane-tools.py*) printf 'tools\n' >> "$FM_TEST_PROBE_LOG"; cat "$FM_TEST_TOOLS_LINE"; exit 0 ;;
  esac
done
printf 'probed\n' >> "$FM_TEST_PROBE_LOG"
cat "$FM_TEST_DELL_READING"
SH
  chmod +x "$FAKEBIN/uname" "$FAKEBIN/ssh"
  printf '%s\n' "$ROOM" > "$READING"
  printf '%s\n' 'dell-v100 arch: missing none; gaps plaud (reasons in /x/tools.json)' > "$TOOLS_LINE"
  AHR_DIR="$HOME_DIR/user-home/Code/Agent-Harness-Reconfig"
  mkdir -p "$AHR_DIR/ops/claude-lane" "$AHR_DIR/ops/lane-tools"
  printf '%s\n' '{"tools":[{"name":"plaud"},{"name":"jq"}]}' > "$AHR_DIR/ops/lane-tools/tools.json"
  cat > "$AHR_DIR/ops/claude-lane/placement.py" <<'PY'
# Contract stand-in for the external AHR module; no production thresholds copied.
import json
import subprocess

DELL = "dell"
DELL_CHECKOUT = "/dell/ahr"


def settings():
    return {}


def read_dell(args, cfg):
    assert args.account is None and args.codex is True and args.glm is None
    proc = subprocess.run(['ssh', 'dell', 'probe'], input='probe', text=True,
                          capture_output=True)
    if proc.returncode:
        return None, 'the Dell did not answer'
    return json.loads(proc.stdout), None


def usable_cpu(dell):
    return isinstance(dell.get('cpu_idle_percent'), (int, float))


def dell_fault(dell, why, cfg, anthropic=True):
    assert anthropic is False
    assert 'repo_error' not in dell and 'account_error' not in dell
    if dell['mem_available_kb'] == 524288:
        return 'memory', 'low memory'
    return None, 'room available'


def dell_readings(dell, why, cfg):
    return 'the Dell: %d kB available' % dell['mem_available_kb']
PY
}

spawn() {
  FM_TEST_PROBE_LOG="$PROBE_LOG" FM_TEST_DELL_READING="$READING" \
    FM_TEST_TOOLS_LINE="$TOOLS_LINE" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$@"
}

ship() {
  spawn "$ID" "$PROJ_DIR" --mode no-mistakes --yolo off "$@"
}

refused() {
  [ "$STATUS" -ne 0 ] || fail "spawn should refuse: $OUT"
  assert_contains "$OUT" "$1" "refusal explains why"
  [ ! -s "$LAUNCH_LOG" ] || fail "refused worker received a launch"
  [ ! -e "$HOME_DIR/state/$ID.meta" ] || fail "refused worker has a task record"
}

launched_with() {
  expect_code 0 "$STATUS" "spawn should launch: $OUT"
  [ -s "$LAUNCH_LOG" ] || fail "admitted worker received no launch"
  grep -qxF "mac_reason=$1" "$HOME_DIR/state/$ID.meta" ||
    fail "meta lacks mac_reason=$1: $(cat "$HOME_DIR/state/$ID.meta")"
}

make_case room-ship
OUT=$(ship)
STATUS=$?
refused 'the Dell has room'
assert_contains "$OUT" 'fm-backlog-handoff.sh dellmate room-ship' 'refusal names the Dell partner route'
assert_contains "$OUT" '--mac-reason' 'refusal names the way through'
[ -s "$PROBE_LOG" ] || fail 'Mac spawn must read the Dell first'
pass 'Mac ship with Dell room and no reason is refused toward the Dell partner'

make_case room-scout
rm "$HOME_DIR/data/secondmates.md"
OUT=$(spawn "$ID" "$PROJ_DIR" --scout)
STATUS=$?
refused 'the Dell has room'
assert_contains "$OUT" 'no Dell partner' 'refusal says how to get a Dell partner'
pass 'Mac scout uses the same placement'

make_case room-child
PARENT="$CASE_DIR/parent"
mkdir -p "$PARENT/data"
mv "$HOME_DIR/data/secondmates.md" "$PARENT/data/secondmates.md"
printf '%s\n' '- otherdell - Dell lanes for other. (host: dell; root: /r; home: /h; scope: other; projects: q; added 2026-11-27)' \
  '- childdell - Dell lanes for child. (host: dell; root: /r; home: /h; scope: child work; projects: p; added 2026-11-27)' \
  >> "$PARENT/data/secondmates.md"
printf 'child\n' > "$HOME_DIR/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" > "$HOME_DIR/.fm-secondmate-parent"
OUT=$(ship)
STATUS=$?
refused 'the Dell has room'
assert_contains "$OUT" "FM_HOME=$PARENT bin/fm-backlog-handoff.sh childdell room-child" 'refusal names the partner the parent registers for this home'
case "$OUT" in *otherdell*) fail "refusal named another home's partner: $OUT" ;; esac
pass "a secondmate home is pointed at its Dell partner in the parent's registry"

make_case reason
OUT=$(ship --mac-reason $'Mac-only files:\n~/Documents/x')
STATUS=$?
launched_with 'Mac-only files: ~/Documents/x'
[ ! -e "$PROBE_LOG" ] || fail 'a written reason needs no Dell read'
pass 'a written reason starts on the Mac and lands in meta as one line'

make_case low
printf '%s\n' "$LOW" > "$READING"
OUT=$(ship)
STATUS=$?
launched_with 'Dell has no room: memory: low memory'
pass 'a Dell without room writes its own reason'

make_case unreadable
OUT=$(FM_TEST_SSH_FAILURE=1 ship)
STATUS=$?
launched_with 'Dell not readable: the Dell did not answer'
assert_contains "$OUT" 'warning' 'an unreadable Dell warns'
pass 'an unreadable Dell warns and starts on the Mac with mac_reason'

make_case no-placement
rm "$HOME_DIR/user-home/Code/Agent-Harness-Reconfig/ops/claude-lane/placement.py"
OUT=$(ship)
STATUS=$?
expect_code 0 "$STATUS" "missing placement.py still starts: $OUT"
grep -q '^mac_reason=Dell not readable: ' "$HOME_DIR/state/$ID.meta" || fail 'missing placement.py records no reason'
pass 'a missing AHR placement probe warns and starts on the Mac'

make_case tool-gap
OUT=$(ship --needs-tool plaud)
STATUS=$?
launched_with 'tool missing on Dell: plaud'
pass 'a tool the Dell lacks is written as the reason'

make_case tool-present
OUT=$(ship --needs-tool jq)
STATUS=$?
refused 'the Dell has room'
pass 'a tool the Dell has is no reason'

make_case tool-unknown
OUT=$(ship --needs-tool nosuchtool)
STATUS=$?
refused 'not in the lane-tools list'
pass 'an unknown tool name is refused'

make_case relaunch
OUT=$(ship --mac-reason 'Outlook/mail access')
STATUS=$?
launched_with 'Outlook/mail access'
: > "$LAUNCH_LOG"
# The relaunch preflight needs a positively agent-free endpoint.
mv "$FAKEBIN/tmux" "$FAKEBIN/tmux-inner"
cat > "$FAKEBIN/tmux" <<'SH'
#!/bin/sh
case "$*" in *'#{pane_current_command}'*) printf 'bash\n'; exit 0 ;; esac
exec "$(dirname "$0")/tmux-inner" "$@"
SH
chmod +x "$FAKEBIN/tmux"
OUT=$(spawn "$ID" --relaunch)
STATUS=$?
expect_code 0 "$STATUS" "relaunch is never placed: $OUT"
[ ! -e "$PROBE_LOG" ] || fail 'relaunch read the Dell'
grep -qxF 'mac_reason=Outlook/mail access' "$HOME_DIR/state/$ID.meta" || fail 'relaunch dropped mac_reason'
OUT=$(spawn "$ID" --relaunch --mac-reason x)
STATUS=$?
[ "$STATUS" -ne 0 ] || fail "relaunch must refuse a new placement flag: $OUT"
pass 'relaunch is untouched by placement and keeps mac_reason'

for kind in ship scout; do
  make_case "dell-$kind"
  rm -r "$HOME_DIR/user-home/Code"
  ARGS=(--scout)
  [ "$kind" = scout ] || ARGS=(--mode no-mistakes --yolo off)
  OUT=$(FM_TEST_KERNEL=Linux spawn "$ID" "$PROJ_DIR" "${ARGS[@]}")
  STATUS=$?
  expect_code 0 "$STATUS" "Dell-hosted $kind is unaffected: $OUT"
  [ ! -e "$PROBE_LOG" ] || fail 'Dell-hosted spawn ran placement'
  ! grep -q '^mac_reason=' "$HOME_DIR/state/$ID.meta" || fail 'Dell-hosted spawn wrote mac_reason'
done
pass 'Dell-hosted ship and scout need no placement and write no mac_reason'

make_case batch
OUT=$(spawn "$ID=$PROJ_DIR" --mode no-mistakes --yolo off --mac-reason='tool missing on Dell: plaud')
STATUS=$?
launched_with 'tool missing on Dell: plaud'
pass 'batch shares the Mac reason'
