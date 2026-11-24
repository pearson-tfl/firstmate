#!/usr/bin/env bash
set -u
ROOT={run-worktree}
E=~/.no-mistakes/evidence/01M87Y5E24QJM9D7GRZBS9GVZA/live2
LAB="$E/l"
[ ! -e "$LAB" ] || exit 2
mkdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB/h" || exit 2
"$ROOT/bin/fm-lab-home.sh" create "$LAB/s" || exit 2
mkdir -p "$LAB/tmux" "$LAB/s/bin" "$LAB/h/config/secondmate-accounts/sm"
export TMUX_TMPDIR="$LAB/tmux"
cleanup() {
  tmux -L fm-lab list-panes -a -F '#{pane_pid}' > "$E/final-pane-pids.txt" 2>/dev/null || true
  tmux -L fm-lab kill-server > "$E/kill-server.log" 2>&1 || true
  sleep 1
  if tmux -L fm-lab list-sessions > "$E/final-socket-check.txt" 2>&1; then
    printf 'ERROR: lab server survives\n'; return 1
  fi
  chmod -R u+w "$LAB"
  rm -rf "$LAB"
  [ ! -e "$LAB" ] || return 1
  printf 'scratch homes removed; private fm-lab server stopped\n' > "$E/cleanup.txt"
}
trap cleanup EXIT
printf 'manual\n' > "$LAB/h/config/backlog-backend"
printf 'tmux\n' > "$LAB/h/config/backend"
printf 'omp antigravity-cli/gemini-4-neon xhigh\n' > "$LAB/h/config/secondmate-harness"
printf 'neon\n' > "$LAB/h/config/secondmate-accounts/sm/omp-profile"
printf 'sm\n' > "$LAB/s/.fm-secondmate-home"
printf '%s\n' 'Isolated Firstmate secondmate launch verification. Do only the charter request. Do not run fleet scripts, supervision, or background jobs. Never change files.' 'The home context token is COPPER-COMET-9146.' > "$LAB/s/AGENTS.md"
printf '%s\n' 'For this isolated launch verification, reply exactly NEON_READY followed by the home context token from AGENTS.md. Do not use tools or start any work.' > "$LAB/s/data/charter.md"
git -C "$LAB/s" init -q -b main
cat > "$E/controller.sh" <<'INNER'
#!/usr/bin/env bash
set -u
ROOT={run-worktree}
E=~/.no-mistakes/evidence/01M87Y5E24QJM9D7GRZBS9GVZA/live2
LAB="$E/l"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TASK_ID FM_LOCK_HOLDER FM_LOCK_RECEIPT
export FM_HOME="$LAB/h" FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 FM_BACKEND=tmux
cd "$ROOT" || exit 2
bash tests/fm-omp-harness.test.sh > "$E/omp-portable-isolated.log" 2>&1
printf '%s\n' "$?" > "$E/omp-portable-isolated.exit"
bash bin/fm-spawn.sh sm "$LAB/s" --secondmate > "$E/spawn.log" 2>&1
printf '%s\n' "$?" > "$E/spawn.exit"
INNER
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s lab -n control -x 180 -y 55 -c "$ROOT" -e FM_HOME="$LAB/h" /bin/bash || exit 2
tmux -L fm-lab send-keys -t lab:control -l "bash '$E/controller.sh'"
tmux -L fm-lab send-keys -t lab:control Enter
for ((i=0;i<180;i++)); do
  [ ! -f "$E/spawn.exit" ] || break
  sleep 1
done
[ -f "$E/spawn.exit" ] || { printf 'spawn controller timed out\n'; exit 3; }
printf 'portable isolated exit='; cat "$E/omp-portable-isolated.exit"
printf 'spawn exit='; cat "$E/spawn.exit"
cat "$E/spawn.log"
[ "$(cat "$E/spawn.exit")" = 0 ] || exit 4
cp "$LAB/h/state/sm.meta" "$E/spawn.meta"
for ((i=0;i<150;i++)); do
  tmux -L fm-lab capture-pane -p -S - -t lab:fm-sm > "$E/spawn-pane.txt"
  if grep -q 'NEON_READY COPPER-COMET-9146' "$E/spawn-pane.txt" && ! grep -q 'Working…' "$E/spawn-pane.txt"; then break; fi
  sleep 1
done
tmux -L fm-lab list-panes -t lab:fm-sm -F '#{pane_pid} #{pane_width}x#{pane_height} #{pane_current_command}' > "$E/spawn-terminal.txt"
ps -axo pid=,ppid=,args= | awk -v h="$LAB/s" 'index($0,h)' > "$E/spawn-process.txt"
cat "$E/spawn-pane.txt"
if ! grep -q 'NEON_READY COPPER-COMET-9146' "$E/spawn-pane.txt"; then printf 'spawn answer absent\n'; exit 5; fi
if grep -Eq 'RESOURCE_EXHAUSTED|code 429' "$E/spawn-pane.txt"; then printf 'spawn had quota error\n'; exit 6; fi
printf '%s\n' 'Isolated Firstmate secondmate launch verification. Do only the charter request. Do not run fleet scripts, supervision, or background jobs. Never change files.' 'The home context token is SILVER-ORBIT-6829.' > "$LAB/s/AGENTS.md"
cat > "$E/relaunch.sh" <<'RELAUNCH'
#!/usr/bin/env bash
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TASK_ID FM_LOCK_HOLDER FM_LOCK_RECEIPT
export FM_HOME=~/.no-mistakes/evidence/01M87Y5E24QJM9D7GRZBS9GVZA/live2/l/h FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 FM_BACKEND=tmux
cd {run-worktree} || exit 2
bash bin/fm-control.sh sm relaunch > ~/.no-mistakes/evidence/01M87Y5E24QJM9D7GRZBS9GVZA/live2/relaunch.log 2>&1
printf '%s\n' "$?" > ~/.no-mistakes/evidence/01M87Y5E24QJM9D7GRZBS9GVZA/live2/relaunch.exit
RELAUNCH
tmux -L fm-lab send-keys -t lab:control -l "bash '$E/relaunch.sh'"
tmux -L fm-lab send-keys -t lab:control Enter
for ((i=0;i<120;i++)); do [ ! -f "$E/relaunch.exit" ] || break; sleep 1; done
[ -f "$E/relaunch.exit" ] || { printf 'relaunch controller timed out\n'; exit 7; }
printf 'relaunch exit='; cat "$E/relaunch.exit"
cat "$E/relaunch.log"
[ "$(cat "$E/relaunch.exit")" = 0 ] || exit 8
cp "$LAB/h/state/sm.meta" "$E/relaunch.meta"
cp "$LAB/h/state/sm.control-relaunch" "$E/relaunch-transaction.txt"
for ((i=0;i<150;i++)); do
  tmux -L fm-lab capture-pane -p -S - -t lab:fm-sm > "$E/relaunch-pane.txt"
  if grep -q 'NEON_READY SILVER-ORBIT-6829' "$E/relaunch-pane.txt" && ! grep -q 'Working…' "$E/relaunch-pane.txt"; then break; fi
  sleep 1
done
ps -axo pid=,ppid=,args= | awk -v h="$LAB/s" 'index($0,h)' > "$E/relaunch-process.txt"
cat "$E/relaunch-pane.txt"
if ! grep -q 'NEON_READY SILVER-ORBIT-6829' "$E/relaunch-pane.txt"; then printf 'relaunch answer absent\n'; exit 9; fi
if grep -Eq 'RESOURCE_EXHAUSTED|code 429' "$E/relaunch-pane.txt"; then printf 'relaunch had quota error\n'; exit 10; fi
printf 'live spawn and relaunch completed\n'
