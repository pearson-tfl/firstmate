#!/usr/bin/env bash
# Credentialed real-omp relaunch guard, confined to a private tmux socket and
# disposable secondmate homes. No live fleet endpoint is ever addressed.
# FM_OMP_CONTROL_LIVE=1 enables it; FM_OMP_CONTROL_LIVE_ROOT retains evidence
# at a chosen directory, FM_OMP_CONTROL_LIVE_PROFILE selects a profile.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_OMP_CONTROL_LIVE omp tmux git

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
  local target=$1 n state composer busy screen
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
      printf '%s\n' "$screen" | grep -Eq 'π[^·]*·.*📁' \
        || fail "$target lacks the profile/model/folder status row"
      return 0
    fi
    sleep 0.2
  done
  fail "$target never settled at the matching idle screen ($state/$composer/$busy)"
}

for id in before with; do
  seat="$LAB/$id"
  mkdir -p "$seat/state" "$seat/data" "$seat/config" "$seat/projects"
  git -C "$seat" init -q || fail 'cannot initialize disposable home'
  printf '%s\n' "$id" > "$seat/.fm-secondmate-home"
  printf 'Isolated lifecycle test. Follow only the test charter.\n' > "$seat/AGENTS.md"
  [ ! -e "$seat/bin" ] && [ ! -L "$seat/bin" ] || fail 'live root must be fresh; refusing to follow an existing bin link'
  ln -s "$ROOT/bin" "$seat/bin" || fail 'cannot expose launch tools'
  printf 'Reply exactly IDLE. Do not use tools, start work, or run supervision.\n' > "$seat/data/charter.md"
  extension="$FM_HOME/state/$id.omp-ext.ts"
  if [ "$id" = with ]; then printf 'export default function() {}\n' > "$extension"; fi
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
  # matches a settled live seat. The before case starts without its extension.
  printf -v launch '%q ' env OMP_SKIP_SETUP=1 FM_OMP_HARNESS=omp "$OMP_BIN" "${profile_args[@]}" --config "$ROOT/.omp/fm-worker-overlay.yml" --auto-approve --cwd "$seat" -e "$extension" "$(cat "$seat/data/charter.md")"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "lab:fm-$id" -l "$launch" || fail 'initial launch failed'
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "lab:fm-$id" Enter || fail 'initial Enter failed'
  wait_idle "lab:fm-$id"
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "lab:fm-$id" > "$LAB/$id-before.txt"
  if [ "$id" = before ]; then printf 'export default function() {}\n' > "$extension"; fi
  old_pid=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "lab:fm-$id" '#{pane_current_command} #{pane_pid}')
  bash "$ROOT/bin/fm-control.sh" "$id" relaunch > "$LAB/$id-relaunch.log" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "$id relaunch exited $rc"
  grep -q '^phase=complete$' "$FM_HOME/state/$id.control-relaunch" || fail "$id transaction did not complete"
  wait_idle "lab:fm-$id"
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "lab:fm-$id" > "$LAB/$id-after.txt"
  printf 'ok - omp %s: %s secondmate relaunched (initial %s)\n' "$VERSION" "$id" "$old_pid"
done

# A genuinely unattributed foreground process must receive no lifecycle input.
"$REAL_TMUX" -L "$SOCKET" new-window -d -t lab: -n fm-ambiguous -c "$LAB/before" sleep 900 || fail 'cannot create ambiguous endpoint'
sed 's/window=lab:fm-before/window=lab:fm-ambiguous/;s/endpoint_task_id=before/endpoint_task_id=ambiguous/' \
  "$FM_HOME/state/before.meta" > "$FM_HOME/state/ambiguous.meta"
# Checkpoint marker must name this independent task, not the successful seat.
mkdir -p "$LAB/ambiguous/state"
git -C "$LAB/ambiguous" init -q || fail 'cannot initialize ambiguous home'
printf 'ambiguous\n' > "$LAB/ambiguous/.fm-secondmate-home"
sed "s|$LAB/before|$LAB/ambiguous|g" "$FM_HOME/state/ambiguous.meta" > "$LAB/ambiguous-meta"
cp "$LAB/ambiguous-meta" "$FM_HOME/state/ambiguous.meta"
bash "$ROOT/bin/fm-control.sh" ambiguous relaunch > "$LAB/ambiguous-relaunch.log" 2>&1
rc=$?
[ "$rc" -ne 0 ] || fail 'ambiguous relaunch returned success'
grep -q "endpoint reads 'ambiguous'" "$LAB/ambiguous-relaunch.log" || fail 'refusal was not due to ambiguous identity'
printf 'ok - omp %s: ambiguous relaunch refused with exit %s; evidence %s\n' "$VERSION" "$rc" "$LAB"
