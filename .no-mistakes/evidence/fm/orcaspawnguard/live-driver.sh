#!/usr/bin/env bash
# Real-Orca test lane: drives the adapter in bin/backends/orca.sh against a
# disposable Orca runtime this guard starts and stops itself, so each Orca
# release can be proved against the backend. It spends no model tokens.
#
# Opt-in (FM_ORCA_LIVE_E2E=1 or FM_LIVE=1) although it is token-free: an Orca
# terminal starts the operator's login shell under the operator's real account,
# so a run that types into the wrong terminal reaches live sessions. The guard
# therefore runs only with these safeguards, and refuses rather than degrade:
#
# - It re-executes itself under `env -i` with a short allowlist, so the runtime
#   and every terminal it opens never see SSH_CONNECTION, SSH_CLIENT, SSH_TTY,
#   TMUX, TMUX_PANE or any inherited ORCA_* identity; a login-shell rule keyed
#   on them (for example an ssh-login tmux auto-attach) cannot fire.
# - It starts its own `orca serve` on a scratch profile (ORCA_USER_DATA_PATH),
#   scratch HOME and XDG folders, loopback only, no pairing, telemetry off, and
#   refuses every Orca call unless `orca status` reports the runtime id that
#   runtime printed at start.
# - SHELL names a guard-written plain sh whose prompt carries a fresh random
#   nonce. Before every key it sends, the guard reads the terminal and requires
#   the last non-empty row to begin with that prompt; anything else - a tmux
#   client, an agent composer, a login shell that ignored SHELL - stops the run
#   with nothing sent.
#
# FM_ORCA_LIVE_SHELL_WAIT_S bounds each wait for the terminal (default 30).
# Refresh: FM_ORCA_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-backend-orca-live-e2e.test.sh
# docs/verification/runtime-backends.md "Orca" records its result;
# tests/fm-backend-orca-live-safety.test.sh pins the safeguards without Orca.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_ORCA_LIVE_INNER:-}" != 1 ]; then
  fm_live_gate opt-in FM_ORCA_LIVE_E2E orca node git
  orca_bin=$(command -v orca)
  node_dir=$(dirname "$(command -v node)")
  git_dir=$(dirname "$(command -v git)")
  fm_test_cleanup
  # Only these names cross into the run; everything else is dropped.
  exec env -i \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin:$node_dir:$git_dir" \
    USER="${USER:-}" LOGNAME="${LOGNAME:-}" LANG=C TMPDIR="{run-worktree}/.orca-validation/tmp" \
    FM_ORCA_LIVE_INNER=1 FM_ORCA_LIVE_BIN="$orca_bin" \
    FM_ORCA_LIVE_E2E="${FM_ORCA_LIVE_E2E:-}" FM_LIVE="${FM_LIVE:-}" \
    FM_ORCA_LIVE_SHELL_WAIT_S="${FM_ORCA_LIVE_SHELL_WAIT_S:-30}" \
    bash "${BASH_SOURCE[0]}"
fi

[ -n "${FM_ORCA_LIVE_BIN:-}" ] || fail "orca live: FM_ORCA_LIVE_BIN is unset; run this file directly, not its inner stage"
for v in $(compgen -e); do
  case "$v" in
    SSH_* | TMUX | TMUX_* | ORCA_*) fail "orca live: $v survived the environment reset" ;;
  esac
done

WAIT_S=${FM_ORCA_LIVE_SHELL_WAIT_S:-30}
SB=$(fm_test_tmproot fm-orca-live)
SERVE_PID=''
WT_ID=''
TERM_ID=''

stop_runtime() {
  local i
  if [ -n "$WT_ID" ]; then
    orca worktree rm --worktree "id:$WT_ID" --force --json >/dev/null 2>&1 || true
  fi
  if [ -n "$SERVE_PID" ] && kill -0 "$SERVE_PID" 2>/dev/null; then
    # TERM, not INT: a background job of a non-interactive shell ignores SIGINT.
    kill -TERM "$SERVE_PID" 2>/dev/null
    for i in $(seq 1 50); do kill -0 "$SERVE_PID" 2>/dev/null || break; sleep 0.2; done
    kill -KILL "$SERVE_PID" 2>/dev/null || true
  fi
  TMUX_TMPDIR=/tmp tmux -L "fm-lab-orca-$NONCE" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap stop_runtime EXIT

export HOME="$SB/home" XDG_CONFIG_HOME="$SB/home/.config" XDG_DATA_HOME="$SB/home/.local/share"
export XDG_CACHE_HOME="$SB/home/.cache" XDG_STATE_HOME="$SB/home/.local/state" CFFIXED_USER_HOME="$SB/home"
export ORCA_USER_DATA_PATH="$SB/userdata" ORCA_SERVE_RUNTIME=orcad ORCA_TELEMETRY_DISABLED=1 DO_NOT_TRACK=1
mkdir -p "$HOME" "$ORCA_USER_DATA_PATH" "$SB/bin"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$FM_ORCA_LIVE_BIN" > "$SB/bin/orca"
NONCE=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
PROMPT="fm-orca-live-$NONCE\$"
cat > "$SB/bin/fm-orca-live-shell" <<SH
#!/bin/sh
unset ENV
PS1='$PROMPT '
export PS1
exec /bin/sh -i
SH
chmod +x "$SB/bin/orca" "$SB/bin/fm-orca-live-shell"
# The adapter prefers `orca-ide`, so the wrapper must shadow a host install under that name too.
ln -s orca "$SB/bin/orca-ide"
export SHELL="$SB/bin/fm-orca-live-shell" PATH="$SB/bin:$PATH"

VERSION=$(orca --version 2>/dev/null | head -1)

orca serve --bind 127.0.0.1 --no-pairing --json > "$SB/serve.out" 2> "$SB/serve.err" &
SERVE_PID=$!
ready=''
for _ in $(seq 1 $((WAIT_S * 5))); do
  ready=$(grep -m1 orca_server_ready "$SB/serve.out" 2>/dev/null) && break
  kill -0 "$SERVE_PID" 2>/dev/null || break
  sleep 0.2
done
[ -n "$ready" ] || fail "Orca $VERSION: the scratch runtime never reported ready: $(tail -3 "$SB/serve.err")"

field() {  # <json> <dotted key>
  node -e 'const d=JSON.parse(process.argv[1]); const v=process.argv[2].split(".").reduce((o,k)=>o==null?o:o[k], d); process.stdout.write(v==null?"":String(v))' "$1" "$2"
}
RUNTIME_ID=$(field "$ready" runtimeId)
[ -n "$RUNTIME_ID" ] || fail "Orca $VERSION: the ready line named no runtime id: $ready"
reached=$(field "$(orca status --json 2>/dev/null)" result.runtime.runtimeId)
assert_equals "$RUNTIME_ID" "$reached" "Orca $VERSION: the CLI must reach the scratch runtime, never another Orca"

# shellcheck source=bin/backends/orca.sh
. "$ROOT/bin/backends/orca.sh"

fm_backend_orca_runtime_check || fail "Orca $VERSION: the adapter readiness gate refused the scratch runtime"

REPO="$SB/repo"
git init -q -b main "$REPO"
printf 'scratch\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" -c user.name=fm-test -c user.email=fm-test@example.invalid commit -q -m init
repo_id=$(fm_backend_orca_repo_ensure "$REPO") || fail "Orca $VERSION: repo registration failed"
assert_equals "$repo_id" "$(fm_backend_orca_repo_ensure "$REPO")" "Orca $VERSION: a second registration must find the same repo"

created=$(fm_backend_orca_worktree_create "$REPO" fm-orca-live) || fail "Orca $VERSION: worktree create failed"
WT_ID=$(printf '%s' "$created" | cut -f1)
wt_path=$(printf '%s' "$created" | cut -f2)
TERM_ID=$(printf '%s' "$created" | cut -f3)
assert_equals "$wt_path" "$(fm_backend_orca_worktree_path "$WT_ID")" "Orca $VERSION: worktree show must return the created path"
[ -f "$wt_path/.git" ] || fail "Orca $VERSION: the worktree is not a linked git worktree"
assert_equals "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)" \
  "$(git -C "$wt_path" rev-parse --path-format=absolute --git-common-dir)" \
  "Orca $VERSION: the worktree must share the project's git common dir"
[ -n "$TERM_ID" ] || TERM_ID=$(fm_backend_orca_terminal_create "$WT_ID" fm-orca-live) ||
  fail "Orca $VERSION: terminal create failed"

echo "Real Orca $VERSION runtime $RUNTIME_ID; isolated terminal $TERM_ID"
wait_screen() {
  local i
  for i in $(seq 1 100); do
    SCREEN=$(fm_backend_orca_screen_read "$TERM_ID")
    case "$SCREEN" in *"$1"*) return 0;; esac
    sleep .2
  done
  fail "screen never showed $1: $SCREEN"
}
refuse() {
  echo "SCENARIO: $1"
  fm_backend_orca_screen_read "$TERM_ID"
  if FM_BACKEND_ORCA_FRESH_SHELL_WAIT_S=1 fm_backend_orca_fresh_shell "$TERM_ID" "$PROMPT"; then
    fail "guard accepted $1"
  fi
  echo "REFUSED; guard invoked without any send operation"
}
wait_screen "$PROMPT"
refuse 'fresh nonce-prompt shell is refused without ownership evidence'
mkdir -p "$SB/tmux"
# Only this deliberately prepared lab shell receives the scenario setup command.
fm_backend_orca_send_text_line "$TERM_ID" "TMUX_TMPDIR=/tmp tmux -L fm-lab-orca-$NONCE -f /dev/null new-session -s proof 'env PS1=\"$PROMPT \" /bin/sh -i'"
for i in $(seq 1 100); do
  TMUX_TMPDIR=/tmp tmux -L "fm-lab-orca-$NONCE" list-clients -F '#{client_pid}' > "$SB/clients" 2>/dev/null
  [ -s "$SB/clients" ] && break
  sleep .2
done
[ -s "$SB/clients" ] || { fm_backend_orca_screen_read "$TERM_ID"; fail 'real tmux client did not attach'; }
echo "Attached real tmux client PID: $(cat "$SB/clients")"
sleep 1
refuse 'real tmux client with visible status is refused'
TMUX_TMPDIR=/tmp tmux -L "fm-lab-orca-$NONCE" set-option -g status off
sleep 1
refuse 'real tmux client with hidden status and matching nonce prompt is refused'
TMUX_TMPDIR=/tmp tmux -L "fm-lab-orca-$NONCE" kill-server
sleep 1
wait_screen "$PROMPT"
fm_backend_orca_send_text_line "$TERM_ID" "printf '\033[2J\033[H╭ foreign composer ╮\n❯\n'; sleep 300"
wait_screen 'foreign composer'
refuse 'foreign program screen is refused'
fm_backend_orca_kill "$TERM_ID" || fail 'terminal close failed'
fm_backend_orca_remove_worktree "$WT_ID" || fail 'worktree release failed'
[ ! -e "$wt_path" ] || fail 'worktree remains'
WT_ID=''
echo 'Real terminal closed and disposable worktree removed'
