#!/usr/bin/env bash
# Credentialed real-omp relaunch guard, confined to a private tmux socket and
# disposable secondmate homes. No live fleet endpoint is ever addressed.
# FM_OMP_CONTROL_LIVE=1 enables it; FM_OMP_CONTROL_LIVE_ROOT retains evidence
# at a chosen directory, FM_OMP_CONTROL_LIVE_PROFILE selects a profile.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_OMP_CONTROL_LIVE omp bun tmux git

REAL_TMUX=$(command -v tmux)
OMP_BIN=$(command -v omp)
VERSION=$(omp --version)
LAB=${FM_OMP_CONTROL_LIVE_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/fm-control-omp.XXXXXX")}
SOCKET="fm-control-omp-$$"
mkdir -p "$LAB/parent/state" "$LAB/parent/config" "$LAB/parent/data" "$LAB/shim"
LAB=$(cd "$LAB" && pwd -P)
fail() { printf 'not ok - omp %s: %s (evidence: %s)\n' "$VERSION" "$1" "$LAB" >&2; exit 1; }
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true; }
trap cleanup EXIT
cat > "$LAB/shim/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
EOF
chmod +x "$LAB/shim/tmux"
export PATH="$LAB/shim:$PATH"
NO_OMP_PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$(dirname "$OMP_BIN")" | paste -sd: -)
[ -z "$(PATH=$NO_OMP_PATH command -v omp)" ] || fail 'cannot build a PATH without omp'
# Clear inherited home bindings before selecting the disposable parent.
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE
export FM_HOME="$LAB/parent" FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf 'omp\n' > "$FM_HOME/config/secondmate-harness"
printf 'tmux\n' > "$FM_HOME/config/backend"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail 'cannot load tmux adapter'
"$REAL_TMUX" -L "$SOCKET" new-session -d -s lab -n control /bin/sh || fail 'cannot create private server'

wait_idle() {
  local target=$1 n state composer busy screen status
  for n in $(seq 1 150); do
    state=$(fm_backend_agent_state tmux "$target")
    composer=$(fm_backend_composer_state tmux "$target")
    busy=$(fm_pane_busy_state "$target" omp)
    screen=$(fm_backend_visible_capture tmux "$target")
    # Empty composers exist during a running turn too. Require the settled
    # reply, no working/spinner signal, and the live seat's bare prompt shape.
    if [ "$state" = alive ] && [ "$composer" = empty ] && [ "$busy" = idle ] \
      && printf '%s\n' "$screen" | grep -Eq '^[[:space:]]*IDLE[[:space:]]*$' \
      && printf '%s\n' "$screen" | grep -Eq '^[[:space:]]*❯[[:space:]]*$'; then
      status=$(printf '%s\n' "$screen" | awk '/^[[:space:]]*❯[[:space:]]*$/ { getline; row=$0 } END { print row }')
      printf '%s\n' "$status" | grep -Eq '^[[:space:]]*π(-[a-z0-9._-]+)?[[:space:]]+·[[:space:]]+[^[:space:]·][^·]*[[:space:]]+·[[:space:]]+📁[[:space:]]+[^[:space:]·][^·]*([[:space:]]+·.*)?$' \
        || fail "$target lacks the adjacent profile/model/folder status row"
      return 0
    fi
    sleep 0.2
  done
  fail "$target never settled at the matching idle screen ($state/$composer/$busy)"
}

omp_pid() {  # <target>: the attributed agent, not its persistent pane shell
  local pid args
  for pid in $(fm_backend_tmux_foreground_pids "$1"); do
    args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || continue
    if fm_agent_process_omp_args "$args"; then printf '%s' "$pid"; return 0; fi
  done
  return 1
}

for id in without-extension with-extension; do
  seat="$LAB/$id"
  mkdir -p "$seat/state" "$seat/data" "$seat/config" "$seat/projects"
  git -C "$seat" init -q || fail 'cannot initialize disposable home'
  printf '%s\n' "$id" > "$seat/.fm-secondmate-home"
  printf 'Isolated lifecycle test. Follow only the test charter.\n' > "$seat/AGENTS.md"
  [ ! -e "$seat/bin" ] && [ ! -L "$seat/bin" ] || fail 'live root must be fresh; refusing to follow an existing bin link'
  ln -s "$ROOT/bin" "$seat/bin" || fail 'cannot expose launch tools'
  printf 'Reply exactly IDLE. Do not use tools, start work, or run supervision.\n' > "$seat/data/charter.md"
  extension="$FM_HOME/state/$id.omp-ext.ts"
  if [ "$id" = with-extension ]; then printf 'export default function() {}\n' > "$extension"; fi
  mkdir -p "$FM_HOME/config/secondmate-accounts/$id"
  profile_args=()
  if [ -n "${FM_OMP_CONTROL_LIVE_PROFILE:-}" ]; then
    printf '%s\n' "$FM_OMP_CONTROL_LIVE_PROFILE" > "$FM_HOME/config/secondmate-accounts/$id/omp-profile"
    profile_args=(--profile "$FM_OMP_CONTROL_LIVE_PROFILE")
  fi
  cat > "$FM_HOME/state/$id.meta" <<EOF
window=lab:fm-$id
endpoint_task_id=$id
worktree=$seat
project=$seat
home=$seat
harness=omp
kind=secondmate
mode=secondmate
yolo=off
EOF
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t lab: -n "fm-$id" -c "$seat" /bin/sh || fail 'cannot create test endpoint'
  # A tiny turn dismisses omp's fresh-session keybind hint so the idle screen
  # matches a settled live seat. One case starts without its extension.
  printf -v launch '%q ' env OMP_SKIP_SETUP=1 FM_OMP_HARNESS=omp "$OMP_BIN" "${profile_args[@]}" --config "$ROOT/.omp/fm-worker-overlay.yml" --auto-approve --cwd "$seat" -e "$extension" "$(cat "$seat/data/charter.md")"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "lab:fm-$id" -l "$launch" || fail 'initial launch failed'
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "lab:fm-$id" Enter || fail 'initial Enter failed'
  wait_idle "lab:fm-$id"
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "lab:fm-$id" > "$LAB/$id-before.txt"
  if [ "$id" = without-extension ]; then printf 'export default function() {}\n' > "$extension"; fi
  old_pid=$(omp_pid "lab:fm-$id") || fail "$id has no attributed omp process"
  # Issue #5935: the supervisor's tool shell usually has no Bun directory on
  # PATH, so relaunch from exactly that shell.
  PATH=$NO_OMP_PATH bash "$ROOT/bin/fm-control.sh" "$id" relaunch > "$LAB/$id-relaunch.log" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "$id relaunch exited $rc"
  grep -q '^phase=complete$' "$FM_HOME/state/$id.control-relaunch" || fail "$id transaction did not complete"
  wait_idle "lab:fm-$id"
  new_pid=$(omp_pid "lab:fm-$id") || fail "$id has no replacement omp process"
  [ "$old_pid" != "$new_pid" ] || fail "$id retained its old agent process"
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "lab:fm-$id" > "$LAB/$id-after.txt"
  printf 'ok - omp %s: %s secondmate relaunched (agent %s -> %s)\n' "$VERSION" "$id" "$old_pid" "$new_pid"
done

# Unrelated real Bun scripts remain unattributed even with a deceptive screen,
# an omp basename, or the same package directory spelling as the installed tool.
for decoy in ambiguous package-collision; do
  seat="$LAB/$decoy"
  mkdir -p "$seat/state" "$seat/@oh-my-pi/pi-coding-agent/dist"
  script="$seat/omp"
  [ "$decoy" != package-collision ] || script="$seat/@oh-my-pi/pi-coding-agent/dist/cli.js"
  printf '%s\n' 'console.log("❯\n π-test · model · 📁 test"); setInterval(() => {}, 1000);' > "$script"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t lab: -n "fm-$decoy" -c "$seat" bun "$script" || fail 'cannot create ambiguous endpoint'
  [ "$(fm_backend_agent_state tmux "lab:fm-$decoy")" = ambiguous ] || fail "$decoy acquired agent identity"
  sed "s/window=lab:fm-without-extension/window=lab:fm-$decoy/;s/endpoint_task_id=without-extension/endpoint_task_id=$decoy/;s|$LAB/without-extension|$seat|g" \
    "$FM_HOME/state/without-extension.meta" > "$FM_HOME/state/$decoy.meta"
  git -C "$seat" init -q || fail 'cannot initialize ambiguous home'
  printf '%s\n' "$decoy" > "$seat/.fm-secondmate-home"
  PATH=$NO_OMP_PATH bash "$ROOT/bin/fm-control.sh" "$decoy" relaunch > "$LAB/$decoy-relaunch.log" 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "$decoy relaunch returned success"
  grep -q "endpoint reads 'ambiguous'" "$LAB/$decoy-relaunch.log" || fail 'refusal was not due to ambiguous identity'
  printf 'ok - omp %s: %s relaunch refused with exit %s; evidence %s\n' "$VERSION" "$decoy" "$rc" "$LAB"
done
