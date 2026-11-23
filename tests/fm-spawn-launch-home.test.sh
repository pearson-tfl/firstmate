#!/usr/bin/env bash
# tests/fm-spawn-launch-home.test.sh - a ship or scout worker starts with the
# FM_HOME of the home that spawned it, never the one a long-lived tmux server's
# global environment carries.
#
# A secondmate's tmux panes come from the same server as the primary's, and that
# server's global environment can hold the primary's FM_HOME, which every new
# window inherits. The assertions never read bin/fm-spawn.sh's source. They drive
# the real spawn against a fake pane, then EXECUTE the launch command the pane
# received inside a window of a private tmux lab server (tmux -L, never the
# shared default server) whose global environment names a different home, with
# the harness binary replaced by a probe that records what the agent saw.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
TMP_ROOT=$(fm_test_tmproot fm-spawn-launch-home)
SOCKET="fm-launch-home-$$"
lab() { "$REAL_TMUX" -L "$SOCKET" -f /dev/null "$@"; }
trap 'lab kill-server >/dev/null 2>&1 || true' EXIT

# The home the tmux server's global environment names: the primary's, in the
# reported fault.
GLOBAL_HOME="$TMP_ROOT/global-home"
fm_test_spawn_home "$GLOBAL_HOME" codex
lab new-session -d -s lab -x 120 -y 30 || fail "could not start the lab tmux server"
lab set-environment -g FM_HOME "$GLOBAL_HOME"
lab set-environment -g FM_STATE_OVERRIDE "$GLOBAL_HOME/state"

# run_in_lab_window <script> <result-file>: run a script in a new lab window and
# wait for it to write its result.
run_in_lab_window() {
  local script=$1 result=$2 i
  rm -f "$result"
  lab new-window -d "/bin/sh $(printf '%q' "$script")" || fail "could not open a lab window"
  for i in $(seq 1 100); do
    [ -s "$result" ] && return 0
    sleep 0.1
  done
  fail "the lab window never wrote $result"
}

# The fault's precondition: a new window of this server inherits the global
# FM_HOME. Without it the cases below would pass vacuously.
test_lab_window_inherits_global_home() {
  local script="$TMP_ROOT/control.sh" result="$TMP_ROOT/control.out"
  # shellcheck disable=SC2016 # expanded by the window shell, not here
  printf '#!/bin/sh\nprintf "%%s\\n" "${FM_HOME-unset}" > %q\n' "$result" > "$script"
  run_in_lab_window "$script" "$result"
  assert_equals "$GLOBAL_HOME" "$(cat "$result")" \
    "a new lab window must inherit the server's global FM_HOME"
  pass "a new window of the lab tmux server inherits the global FM_HOME"
}

# spawn_and_probe <name> <kind> <secondmate|primary>: spawn a <kind> worker from
# a fresh home and print what its agent saw of FM_HOME and FM_STATE_OVERRIDE.
spawn_and_probe() {
  local name=$1 kind=$2 spawning_home=$3 case_dir home proj wt fakebin launchlog panelog id out status script result
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  panelog="$case_dir/pane.log"
  result="$case_dir/probe.out"
  id="$name-a1"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  [ "$spawning_home" = primary ] || printf '%s\n' "$name" > "$home/.fm-secondmate-home"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  : > "$launchlog"
  : > "$panelog"
  if [ "$kind" = ship ]; then
    out=$(FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$panelog" \
      fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off)
  else
    out=$(FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$panelog" \
      fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --scout)
  fi
  status=$?
  expect_code 0 "$status" "$name: $kind spawn should succeed: $out"
  [ -s "$launchlog" ] || fail "$name: the spawn sent no launch command"
  # shellcheck disable=SC2016 # expanded by the probe, not here
  printf '#!/bin/sh\nprintf "%%s|%%s\\n" "${FM_HOME-unset}" "${FM_STATE_OVERRIDE-unset}" > %q\n' "$result" > "$fakebin/codex"
  chmod +x "$fakebin/codex"
  # The pane exports run before the launch in the real pane shell; replay them.
  script="$case_dir/pane.sh"
  {
    printf 'export PATH=%q\n' "$fakebin:$PATH"
    grep '^export ' "$panelog"
    cat "$launchlog"
  } > "$script"
  run_in_lab_window "$script" "$result"
  printf '%s|%s\n' "$(cd "$home" && pwd -P)" "$(cat "$result")"
}

assert_launch_home() {  # <name> <kind> <secondmate|primary>
  local seen home fm_home state_override
  seen=$(spawn_and_probe "$1" "$2" "$3") || exit 1
  IFS='|' read -r home fm_home state_override <<EOF
$seen
EOF
  assert_equals "$home" "$(cd "$fm_home" 2>/dev/null && pwd -P || printf '%s' "$fm_home")" \
    "a $2 spawned from a $3 home must see that home's FM_HOME, not the tmux global $GLOBAL_HOME"
  assert_equals "" "$state_override" \
    "a $2 spawned from a $3 home must not inherit another home's FM_STATE_OVERRIDE"
}

test_secondmate_workers_see_their_home() {
  assert_launch_home sm-ship ship secondmate
  assert_launch_home sm-scout scout secondmate
  pass "a ship and a scout spawned from a secondmate home see that home's FM_HOME despite the tmux global"
}

test_primary_workers_see_the_primary_home() {
  assert_launch_home primary-ship ship primary
  pass "a ship spawned from the primary home still sees the primary home's FM_HOME"
}

test_lab_window_inherits_global_home
test_secondmate_workers_see_their_home
test_primary_workers_see_the_primary_home
