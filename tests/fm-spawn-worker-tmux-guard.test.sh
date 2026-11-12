#!/usr/bin/env bash
# tests/fm-spawn-worker-tmux-guard.test.sh - the two spawn-side guards against a
# worker killing the tmux server it was launched on:
#   - config/worker-tmux-dir puts the configured tmux stand-in first on every
#     launched worker's PATH, and a bad value refuses the spawn rather than
#     launching an unguarded worker;
#   - every ship and scout launch removes TMUX, TMUX_PANE and the SSH names and
#     points TMUX_TMPDIR at a private folder, while a secondmate keeps its tmux.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake pane and a real isolated git worktree, then EXECUTE the launch
# command the pane received, with the harness binary replaced by a probe that
# reports what the agent would see. The synthetic pane carries TMUX, TMUX_PANE,
# SSH_CONNECTION and a different tmux first on PATH, so a pass proves the launch
# changed them rather than inheriting them.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-worker-tmux-guard)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
shell_quote_test() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

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

make_secondmate_home() {  # <id>; prints the home path
  local sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$1" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$1" > "$sm/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
  git -C "$sm" init -q -b main
  printf '%s\n' "$sm"
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
launched_probe() {  # <harness> <probe-body>
  local preamble
  printf '#!/bin/sh\n%s\n' "$2" > "$FAKEBIN_DIR/$1"
  chmod +x "$FAKEBIN_DIR/$1"
  preamble=$(grep '^export ' "$PANE_LOG")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
    TMUX=/tmp/synthetic-live/default,1,0 TMUX_PANE=%1 SSH_CONNECTION='10.0.0.1 1 10.0.0.2 22' \
    /bin/sh -c "$preamble
$(cat "$LAUNCH_LOG")"
}

launched_tmux() { launched_probe "$1" 'command -v tmux'; }

# What a worker sees of its tmux location: the three ambient names it must lose
# and the private folder it must gain.
# shellcheck disable=SC2016 # expanded by the probe, not here
TMUX_ENV_PROBE='printf "%s|%s|%s|%s\n" "${TMUX-unset}" "${TMUX_PANE-unset}" "${SSH_CONNECTION-unset}" "${TMUX_TMPDIR-unset}"'

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
  sm=$(make_secondmate_home sm-tmux)
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
  for name in missing empty noexec relative colon space; do
    case "$name" in
      missing) value="$TMP_ROOT/no-such-dir"; want="$TMP_ROOT/no-such-dir/tmux is missing or not executable" ;;
      empty) value="$TMP_ROOT/empty-dir"; want="$TMP_ROOT/empty-dir/tmux is missing or not executable" ;;
      noexec) value="$TMP_ROOT/noexec-dir"; want="$TMP_ROOT/noexec-dir/tmux is missing or not executable" ;;
      relative) value=standin; want="one absolute directory path" ;;
      colon) value="$STANDIN:/usr/bin"; want="one absolute directory path" ;;
      space) value="$STANDIN /x"; want="one absolute directory path" ;;
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

# Claude's Bash tool rebuilds PATH from the login-shell snapshot, so the launch
# export alone does not reach it; the worker's SessionStart hook must re-prepend
# the stand-in through CLAUDE_ENV_FILE. Run the hook the spawn wrote exactly as
# Claude would, then source the env file over a reset PATH, as the Bash tool does.
test_claude_bash_tool_leg() {
  local setting out status hook envfile seen
  for setting in absent set; do
    make_case "claude-$setting" claude "claude-$setting-a1"
    [ "$setting" = absent ] || printf '%s\n' "$STANDIN" > "$HOME_DIR/config/worker-tmux-dir"
    out=$(run_case_spawn "claude-$setting-a1" "$PROJ_DIR" --mode no-mistakes --yolo off)
    status=$?
    expect_code 0 "$status" "claude spawn, worker-tmux-dir $setting: $out"
    hook=$(jq -r '.hooks.SessionStart[0].hooks[0].command // empty' "$WT_DIR/.claude/settings.local.json") \
      || fail "claude, worker-tmux-dir $setting: the worker settings are not valid JSON"
    if [ "$setting" = absent ]; then
      [ -z "$hook" ] || fail "with worker-tmux-dir absent the claude worker must get no SessionStart hook: $hook"
      continue
    fi
    [ -n "$hook" ] || fail "with worker-tmux-dir set the claude worker must get a SessionStart hook"
    envfile="$CASE_DIR/claude-env"
    : > "$envfile"
    CLAUDE_ENV_FILE="$envfile" /bin/sh -c "$hook" || fail "the SessionStart hook failed: $hook"
    seen=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:/usr/bin:/bin" /bin/sh -c ". '$envfile'; command -v tmux")
    assert_equals "$STANDIN/tmux" "$seen" "the Bash tool must resolve the stand-in first after sourcing CLAUDE_ENV_FILE"
  done
  pass "a claude worker's SessionStart hook puts the stand-in first for its Bash tool, and an absent file adds no hook"
}

test_ship_and_scout_isolated() {
  local kind allow id out status seen
  for kind in ship scout; do
    for allow in absent enabled; do
      id="iso-$kind-$allow-a1"
      make_case "iso-$kind-$allow" codex "$id"
      [ "$allow" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
      if [ "$kind" = ship ]; then
        out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
      else
        out=$(run_case_spawn "$id" "$PROJ_DIR" --scout)
      fi
      status=$?
      expect_code 0 "$status" "$kind spawn, allowlist $allow: $out"
      seen=$(launched_probe codex "$TMUX_ENV_PROBE") || fail "$kind, allowlist $allow: the emitted launch failed to run"
      assert_equals "unset|unset|unset|/tmp/fm-$id/tmux" "$seen" \
        "a $kind worker with allowlist $allow must start without TMUX, TMUX_PANE or SSH_CONNECTION and with its private TMUX_TMPDIR"
      [ -d "/tmp/fm-$id/tmux" ] || fail "the $kind worker's private tmux folder must exist before launch"
      [ -z "$(find "/tmp/fm-$id/tmux" -prune \( -perm -g=r -o -perm -o=r \) -print)" ] \
        || fail "the $kind worker's private tmux folder must be private to its owner"
      if [ -n "$REAL_TMUX" ]; then
        # The real tmux by full path, past the fake pane's stub, with no server
        # anywhere it can reach: an unnamed command must address the private
        # folder, never the pane's server.
        seen=$(launched_probe codex "$(shell_quote_test "$REAL_TMUX") display-message -p x 2>&1; true")
        assert_contains "$seen" "/tmp/fm-$id/tmux/tmux-" \
          "an unnamed tmux command from a $kind worker must address its private folder"
      fi
    done
  done
  pass "ship and scout workers start without the launching tmux and SSH names and with a private tmux folder"
}

test_secondmate_keeps_tmux() {
  local sm out status seen
  make_case secondmate-iso codex sm-iso
  sm=$(make_secondmate_home sm-iso)
  out=$(run_case_spawn sm-iso "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn: $out"
  seen=$(launched_probe codex "$TMUX_ENV_PROBE") || fail "secondmate: the emitted launch failed to run"
  assert_equals "/tmp/synthetic-live/default,1,0|%1|10.0.0.1 1 10.0.0.2 22|unset" "$seen" \
    "a secondmate supervises through tmux and must keep its tmux environment"
  pass "a secondmate launch keeps its tmux environment"
}

test_ship_path_order
test_secondmate_path_order
test_bad_directory_refuses
test_claude_bash_tool_leg
test_ship_and_scout_isolated
test_secondmate_keeps_tmux
