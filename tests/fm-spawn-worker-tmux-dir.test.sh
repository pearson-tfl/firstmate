#!/usr/bin/env bash
# tests/fm-spawn-worker-tmux-dir.test.sh - config/worker-tmux-dir puts the
# configured tmux stand-in first on every launched worker's PATH, and a bad
# value refuses the spawn rather than launching an unguarded worker.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake pane and a real isolated git worktree, then EXECUTE the launch
# command the pane received, with the harness binary replaced by a probe that
# prints `command -v tmux` as the agent would resolve it. The pane PATH already
# holds a different tmux first, so a pass proves the configured directory wins.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-worker-tmux-dir)

# The stand-in under test is a marker script; only its PATH position matters.
STANDIN="$TMP_ROOT/standin"
mkdir -p "$STANDIN"
printf '#!/bin/sh\necho standin\n' > "$STANDIN/tmux"
chmod +x "$STANDIN/tmux"

make_case() {  # <name> <harness> <id>
  local case_dir="$TMP_ROOT/$1"
  CASE_DIR=$case_dir
  HOME_DIR="$case_dir/home"
  PROJ_DIR="$case_dir/project"
  WT_DIR="$case_dir/wt"
  LAUNCH_LOG="$case_dir/launch.log"
  PANE_LOG="$case_dir/pane.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$HOME_DIR" "$2"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$1"
  fm_test_spawn_brief "$HOME_DIR" "$3"
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# Run the emitted launch in a synthetic pane whose PATH starts with the fakebin
# (which holds its own tmux), replaying the pane exports first as the real pane
# shell would, and print what the probe agent resolved.
launched_tmux() {  # <harness>
  local preamble
  printf '#!/bin/sh\ncommand -v tmux\n' > "$FAKEBIN_DIR/$1"
  chmod +x "$FAKEBIN_DIR/$1"
  preamble=$(grep '^export ' "$PANE_LOG")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm TMUX=synthetic-pane \
    /bin/sh -c "$preamble
$(cat "$LAUNCH_LOG")"
}

test_ship_path_order() {
  local setting allow out status seen
  for setting in absent set; do
    for allow in absent enabled; do
      make_case "ship-$setting-$allow" codex "ship-$setting-$allow-a1"
      [ "$allow" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
      [ "$setting" = absent ] || printf '%s\n' "$STANDIN" > "$HOME_DIR/config/worker-tmux-dir"
      out=$(run_case_spawn "ship-$setting-$allow-a1" "$PROJ_DIR" --mode no-mistakes --yolo off)
      status=$?
      expect_code 0 "$status" "ship spawn, worker-tmux-dir $setting, allowlist $allow: $out"
      seen=$(launched_tmux codex) || fail "ship, worker-tmux-dir $setting, allowlist $allow: the emitted launch failed to run"
      if [ "$setting" = set ]; then
        assert_equals "$STANDIN/tmux" "$seen" \
          "with worker-tmux-dir set and allowlist $allow the worker must resolve the stand-in first"
      else
        assert_equals "$FAKEBIN_DIR/tmux" "$seen" \
          "with worker-tmux-dir absent and allowlist $allow the worker PATH must be unchanged"
      fi
    done
  done
  pass "a ship worker resolves the configured stand-in first on PATH, and an absent file changes nothing"
}

test_secondmate_path_order() {
  local sm out status seen
  make_case secondmate codex sm-tmux
  printf '%s\n' "$STANDIN" > "$HOME_DIR/config/worker-tmux-dir"
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' sm-tmux > "$sm/.fm-secondmate-home"
  printf 'charter for sm-tmux\n' > "$sm/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
  git -C "$sm" init -q -b main
  out=$(run_case_spawn sm-tmux "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn with worker-tmux-dir set: $out"
  seen=$(launched_tmux codex) || fail "secondmate: the emitted launch failed to run"
  assert_equals "$STANDIN/tmux" "$seen" "a secondmate must resolve the stand-in first"
  pass "a secondmate launch resolves the configured stand-in first on PATH"
}

test_bad_directory_refuses() {
  local name value want out status
  mkdir -p "$TMP_ROOT/empty-dir" "$TMP_ROOT/noexec-dir"
  printf '#!/bin/sh\n' > "$TMP_ROOT/noexec-dir/tmux"
  chmod -x "$TMP_ROOT/noexec-dir/tmux"
  for name in missing empty noexec relative; do
    case "$name" in
      missing) value="$TMP_ROOT/no-such-dir"; want="$TMP_ROOT/no-such-dir/tmux is missing or not executable" ;;
      empty) value="$TMP_ROOT/empty-dir"; want="$TMP_ROOT/empty-dir/tmux is missing or not executable" ;;
      noexec) value="$TMP_ROOT/noexec-dir"; want="$TMP_ROOT/noexec-dir/tmux is missing or not executable" ;;
      relative) value=standin; want="one absolute directory path" ;;
    esac
    make_case "bad-$name" codex "bad-$name-a1"
    printf '%s\n' "$value" > "$HOME_DIR/config/worker-tmux-dir"
    out=$(run_case_spawn "bad-$name-a1" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "a $name worker-tmux-dir must refuse the spawn: $out"
    assert_contains "$out" "$want" "the $name refusal must name what is missing"
    assert_contains "$out" "refusing to launch an unguarded worker" "the $name refusal must say no worker launched"
    [ ! -s "$LAUNCH_LOG" ] || fail "a $name worker-tmux-dir must send no launch command: $(cat "$LAUNCH_LOG")"
    [ ! -e "$HOME_DIR/state/bad-$name-a1.meta" ] || fail "a $name worker-tmux-dir must write no task record"
  done
  pass "a configured directory without an executable tmux refuses the spawn and names what is missing"
}

test_ship_path_order
test_secondmate_path_order
test_bad_directory_refuses
