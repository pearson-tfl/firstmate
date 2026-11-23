#!/usr/bin/env bash
# tests/fm-backend-orca-live-safety.test.sh - pins the safeguards of the
# real-Orca lane (tests/fm-backend-orca-live-e2e.test.sh) with a fake `orca`,
# so they hold on every machine without a real Orca: the runtime never sees
# ssh or tmux identity, and no key reaches a terminal that is not the lane's
# own nonce-prompted shell.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-orca-live-safety)
trap fm_test_cleanup EXIT
GUARD="$ROOT/tests/fm-backend-orca-live-e2e.test.sh"

# make_fake <dir> <own|foreign|login>: a fake Orca CLI whose state lives beside
# it (the guard runs it under `env -i`, so it cannot take settings from the
# environment). In `own` mode a terminal behaves like the shell SHELL names,
# showing that wrapper's PS1; in `foreign` mode it shows an agent composer,
# the screen a tmux client attached to a live session would show; in `login`
# mode it shows a login shell's own prompt, as when SHELL was ignored; in
# `own-orca` mode it is the `own` shell read the way Orca 1.4.271 returns
# rows, with the space after the prompt dropped.
make_fake() {
  local dir=$1 mode=$2
  mkdir -p "$dir/bin" "$dir/state"
  printf '%s\n' "$mode" > "$dir/state/mode"
  printf 'rt-scratch\n' > "$dir/state/runtime-id"
  cat > "$dir/bin/orca" <<'FAKE'
#!/usr/bin/env bash
set -u
S="$(cd "$(dirname "$0")/.." && pwd)/state"
{ printf 'orca'; printf ' %s' "$@"; printf '\n'; } >> "$S/log"
mode=$(cat "$S/mode")
cmd="${1:-} ${2:-}"
path='' repo='' name='' worktree='' text='' enter=0 interrupt=0
shift 2 2>/dev/null || shift $#
while [ $# -gt 0 ]; do
  case "$1" in
    --path) path=$2; shift ;;
    --repo) repo=$2; shift ;;
    --name) name=$2; shift ;;
    --worktree) worktree=${2#id:}; shift ;;
    --text) text=$2; shift ;;
    --enter) enter=1 ;;
    --interrupt) interrupt=1 ;;
  esac
  shift
done
prompt() { sed -n "s/^PS1='\(.*\)'\$/\1/p" "$SHELL"; }
screen_json() {  # <status>
  local rows="$S/screen"
  if [ "$mode" = own-orca ] && [ -f "$S/screen" ]; then
    rows="$S/screen.read"
    p=$(prompt)
    while IFS= read -r l; do
      case "$l" in "$p"*) l="${p% }${l#"$p"}" ;; esac
      printf '%s\n' "$l"
    done < "$S/screen" > "$rows"
  fi
  node -e 'const fs=require("fs"); const t=fs.existsSync(process.argv[1])?fs.readFileSync(process.argv[1],"utf8").split("\n").filter((l,i,a)=>i<a.length-1):[]; process.stdout.write(JSON.stringify({ok:true,result:{terminal:{handle:"term_fake",status:process.argv[2],tail:t}}}))' "$rows" "$1"
}
case "$cmd" in
  "--version ") echo 9.9.9-fake ;;
  "serve --bind")
    env > "$S/serve.env"
    echo $$ > "$S/serve.pid"
    printf '{"type":"orca_server_ready","runtimeId":"%s"}\n' "$(cat "$S/runtime-id")"
    trap 'exit 0' INT TERM
    while :; do sleep 0.1; done
    ;;
  "status --json")
    id=$(cat "$S/status-runtime-id" 2>/dev/null || cat "$S/runtime-id")
    printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready","runtimeId":"%s"}}}\n' "$id"
    ;;
  "repo show")
    [ -f "$S/repo-path" ] && printf '{"ok":true,"result":{"repo":{"id":"repo-1"}}}\n' ||
      printf '{"ok":false,"error":{"code":"repo_not_found"}}\n'
    ;;
  "repo add") printf '%s\n' "$path" > "$S/repo-path"; printf '{"ok":true,"result":{"repo":{"id":"repo-1"}}}\n' ;;
  "worktree create")
    wt="$HOME/orca/workspaces/repo/$name"
    mkdir -p "$(dirname "$wt")"
    git -C "$(cat "$S/repo-path")" worktree add -q -b "$name" "$wt" >/dev/null 2>&1 || exit 1
    printf '{"ok":true,"result":{"worktree":{"id":"repo-1::%s","path":"%s"}}}\n' "$wt" "$wt"
    ;;
  "worktree show") printf '{"ok":true,"result":{"worktree":{"id":"%s","path":"%s"}}}\n' "$worktree" "${worktree#*::}" ;;
  "worktree rm")
    git -C "$(cat "$S/repo-path")" worktree remove --force "${worktree#*::}" >/dev/null 2>&1
    printf '{"ok":true,"result":{"removed":true}}\n'
    ;;
  "terminal create")
    case "$mode" in
      own | own-orca) prompt > "$S/screen" ;;
      foreign) printf '● Kneading…\n❯ \n' > "$S/screen" ;;
      login) printf 'bash-3.2$ \n' > "$S/screen" ;;
    esac
    printf '{"ok":true,"result":{"terminal":{"handle":"term_fake"}}}\n'
    ;;
  "terminal read")
    if [ -f "$S/closed" ]; then rm -f "$S/screen"; screen_json exited; else screen_json running; fi
    ;;
  "terminal send")
    last=$(tail -n 1 "$S/screen")
    if [ "$interrupt" = 1 ]; then
      [ -f "$S/running" ] && { rm -f "$S/running"; prompt >> "$S/screen"; }
    else
      sed -i.bak '$d' "$S/screen"
      printf '%s%s\n' "$last" "$text" >> "$S/screen"
      if [ "$enter" = 1 ]; then
        p=$(prompt)
        line="$last$text"
        run=${line#"$p"}
        case "$run" in
          sleep\ *) : > "$S/running" ;;
          *) sh -c "$run" >> "$S/screen" 2>&1; prompt >> "$S/screen" ;;
        esac
      fi
    fi
    printf '{"ok":true,"result":{"send":{"accepted":true}}}\n'
    ;;
  "terminal close") : > "$S/closed"; printf '{"ok":true,"result":{"close":{"ptyKilled":true}}}\n' ;;
  *) printf '{"ok":false,"error":{"code":"fake_unknown"}}\n'; exit 1 ;;
esac
FAKE
  chmod +x "$dir/bin/orca"
}

run_guard() {  # <fake-dir> -> sets OUT, ERR, RC
  local dir=$1
  OUT=$(PATH="$dir/bin:$PATH" FM_ORCA_LIVE_E2E=1 FM_ORCA_LIVE_SHELL_WAIT_S=1 \
    SSH_CONNECTION='10.0.0.1 22 10.0.0.2 22' SSH_CLIENT='10.0.0.1 22 22' SSH_TTY=/dev/ttys999 \
    TMUX=/tmp/tmux-live/default,1,0 TMUX_PANE=%1 ORCA_TERMINAL_HANDLE=term_live \
    bash "$GUARD" 2> "$dir/stderr")
  RC=$?
  ERR=$(cat "$dir/stderr")
}

serve_stopped() {  # <fake-dir>
  local pid
  pid=$(cat "$1/state/serve.pid" 2>/dev/null) || fail "the fake runtime never started"
  ! kill -0 "$pid" 2>/dev/null || fail "the guard left its runtime running (pid $pid)"
}

# --- opt-in: a token-free guard that still stays off unless asked -----------
D="$TMP_ROOT/optin"; make_fake "$D" own
out=$(PATH="$D/bin:$PATH" FM_ORCA_LIVE_E2E='' FM_LIVE='' bash "$GUARD")
assert_equals 'skip: live: opt-in; set FM_ORCA_LIVE_E2E=1 to run' "$out" "the lane must stay off unless requested"
[ ! -e "$D/state/log" ] || fail "an unrequested lane must not call Orca"
pass "orca live lane: off unless FM_ORCA_LIVE_E2E or FM_LIVE requests it"

# --- own shell: ssh and tmux identity stripped, lane completes --------------
D="$TMP_ROOT/own"; make_fake "$D" own
run_guard "$D"
expect_code 0 "$RC" "own-shell lane run (stderr: $ERR)"
assert_contains "$OUT" "ok - orca live lane: Orca 9.9.9-fake runtime rt-scratch" "own-shell lane run"
for v in SSH_CONNECTION SSH_CLIENT SSH_TTY TMUX TMUX_PANE ORCA_TERMINAL_HANDLE; do
  ! grep -q "^$v=" "$D/state/serve.env" || fail "the runtime environment kept $v"
done
grep -q '^SHELL=.*/fm-orca-live-shell$' "$D/state/serve.env" || fail "the runtime SHELL is not the lane's own shell"
grep -q "^HOME=$HOME\$" "$D/state/serve.env" && fail "the runtime kept the caller's HOME"
assert_grep 'terminal send' "$D/state/log" "the own-shell lane must reach its sends"
assert_grep '--interrupt' "$D/state/log" "the own-shell lane must send Ctrl-C"
assert_grep 'terminal close' "$D/state/log" "the lane must close its terminal"
serve_stopped "$D"
pass "orca live lane: the runtime never sees SSH_*, TMUX or Orca identity, and a run in its own shell completes and stops the runtime"

# --- own shell as Orca 1.4.271 reads it: no space after the prompt ---------
D="$TMP_ROOT/own-orca"; make_fake "$D" own-orca
run_guard "$D"
expect_code 0 "$RC" "own-shell lane run on Orca-style reads (stderr: $ERR)"
# The Enter key is an empty --text, logged as two spaces.
assert_grep 'orca terminal send --terminal term_fake --text  --enter' "$D/state/log" "the lane must press Enter after a literal send"
assert_grep '--interrupt' "$D/state/log" "the lane must reach Ctrl-C on Orca-style reads"
serve_stopped "$D"
pass "orca live lane: its own shell still passes when Orca's read drops the space after the prompt"

# --- foreign screen: nothing sent, everything released ----------------------
for mode in foreign login; do
  D="$TMP_ROOT/$mode"; make_fake "$D" "$mode"
  run_guard "$D"
  assert_not_equals 0 "$RC" "a $mode terminal must fail the lane"
  assert_contains "$ERR" "refusing to send" "a $mode terminal must be named as the reason"
  ! grep -q 'terminal send' "$D/state/log" || fail "a key reached a $mode terminal that is not the lane's own shell"
  assert_grep 'worktree rm' "$D/state/log" "a refused $mode run must still release its worktree"
  serve_stopped "$D"
done
pass "orca live lane: a terminal showing anything but its nonce prompt (agent composer or plain login shell) gets no key, and the run still releases and stops"

# --- another runtime answering: no Orca mutation at all ---------------------
D="$TMP_ROOT/mismatch"; make_fake "$D" own
printf 'rt-live-app\n' > "$D/state/status-runtime-id"
run_guard "$D"
assert_not_equals 0 "$RC" "a CLI reaching another runtime must fail the lane"
assert_contains "$ERR" "never another Orca" "the runtime mismatch must be named"
! grep -Eq '^orca (repo|worktree|terminal) ' "$D/state/log" || fail "the lane touched a runtime it did not start"
serve_stopped "$D"
pass "orca live lane: when the CLI reaches any runtime but its own, nothing is registered, created or sent"
