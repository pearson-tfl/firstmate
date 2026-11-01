#!/usr/bin/env bash
# tests/fm-spawn-lock-holder.test.sh - fm-spawn's launch environment for the
# named session-lock holder (FM_LOCK_HOLDER, bin/fm-lock.sh).
#
# A launch never inherits a holder name: an inherited FM_LOCK_HOLDER=pocock
# reaching a worker would let it claim main under main's own name. A secondmate
# launch is then given its own name, read from its home's secondmate marker, so
# it claims its own home as holder:<marker name>.
#
# The assertions never read bin/fm-spawn.sh's source. Each case drives the real
# spawn against a fake pane with FM_LOCK_HOLDER=pocock inherited, then EXECUTES
# the launch command the pane received, in a synthetic pane shell that also
# carries the inherited name, with the harness binary replaced by a probe. The
# probe prints the holder name it was started with and then runs the real
# bin/fm-lock.sh in that same environment, so the claim it reports is the claim
# the launched agent would make. One case per launch path: the shared launch
# prefix (codex), cursor and omp.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-lock-holder)
INHERITED=pocock

# make_case <name> <harness> <id> -> echoes the case record.
make_case() {
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  install_harness_fakes "$fakebin"
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  # Main is held by name, as it is once pocock has claimed it.
  printf 'holder:%s\n' "$INHERITED" > "$home/state/.lock"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log|$case_dir/pane.log"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

# The cursor and omp executables answer the probes fm-spawn runs before launch.
install_harness_fakes() {  # <fakebin>
  cat > "$1/cursor-agent" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Start the Cursor Agent'
  exit 0
fi
if [ "${1:-}" = --list-models ]; then
  printf '%b\n' 'Available models\ncursor-grok-4.5-high - Grok 4.5 High'
fi
exit 0
SH
  cat > "$1/omp" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != models ] || printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-6-astra","selector":"openai-codex/gpt-6-astra"}]}'
exit 0
SH
  cat > "$1/timeout" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -k ]; then shift 2; fi
shift
exec "$@"
SH
  chmod +x "$1/cursor-agent" "$1/omp" "$1/timeout"
}

# A seeded secondmate home whose marker names <id>.
make_secondmate_home() {  # <dir> <id>
  mkdir -p "$1/bin" "$1/data"
  printf '# Firstmate\n' > "$1/AGENTS.md"
  printf '%s\n' "$2" > "$1/.fm-secondmate-home"
  printf 'charter for %s\n' "$2" > "$1/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$1/.gitignore"
  git -C "$1" init -q -b main
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_LOCK_HOLDER=$INHERITED FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# Replace <exe> with a probe that reports the holder it received, then runs the
# real fm-lock as the launched agent would. <lock-home> is the home it claims:
# the main home for a crewmate (which must be refused), and the launched FM_HOME
# for a secondmate (left empty to keep the launch's own value).
install_lock_probe() {  # <fakebin> <exe> [lock-home]
  local home_assign=
  [ -z "${3:-}" ] || home_assign="FM_HOME='$3' FM_STATE_OVERRIDE='$3/state'"
  cat > "$1/$2" <<SH
#!/bin/sh
printf 'holder=%s\n' "\${FM_LOCK_HOLDER-unset}"
$home_assign '$ROOT/bin/fm-lock.sh' 2>&1
printf 'lock=%s\n' "\$?"
SH
  chmod +x "$1/$2"
}

# Run the emitted launch in a synthetic pane shell that carries the inherited
# holder name, so a launch that merely forwarded the pane's environment shows.
emitted_launch() {
  local preamble
  preamble=$(grep '^export ' "$PANE_LOG")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
    TMUX=synthetic-pane FM_LOCK_HOLDER="$INHERITED" \
    /bin/sh -c "$preamble
$(cat "$LAUNCH_LOG")"
}

# A crewmate on <harness> launched with pocock's name inherited carries no holder,
# and its claim on main is refused.
check_crewmate() {  # <harness> <exe> [spawn args...]
  local harness=$1 exe=$2 id rec out status seen
  shift 2
  id="holder-$harness-a1"
  rec=$(make_case "crew-$harness" "$harness" "$id")
  read_case "$rec"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off "$@")
  status=$?
  expect_code 0 "$status" "$harness ship spawn should succeed: $out"
  install_lock_probe "$FAKEBIN_DIR" "$exe" "$HOME_DIR"
  seen=$(emitted_launch) || fail "$harness ship: the emitted launch failed to run: $seen"
  assert_contains "$seen" "holder=unset" \
    "a $harness worker launched with FM_LOCK_HOLDER=$INHERITED inherited must carry no holder name"
  assert_contains "$seen" "main is held by $INHERITED; read-only" \
    "a $harness worker's claim on main must be refused as read-only"
  assert_not_contains "$seen" "lock=0" "a $harness worker must not claim main"
  assert_equals "holder:$INHERITED" "$(head -n 1 "$HOME_DIR/state/.lock")" \
    "a refused $harness worker must leave main's holder line untouched"
}

# A secondmate on <harness> launches with its marker's name and claims its own
# home under that name, whatever name it inherited.
check_secondmate() {  # <harness> <exe> [spawn args...]
  local harness=$1 exe=$2 id rec out status seen sm
  shift 2
  id="sm-$harness"
  rec=$(make_case "sm-$harness" "$harness" "$id")
  read_case "$rec"
  printf '%s\n' "$harness" > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE_DIR/secondmate-home"
  make_secondmate_home "$sm" "$id"
  out=$(run_case_spawn "$id" "$sm" --secondmate "$@")
  status=$?
  expect_code 0 "$status" "$harness secondmate spawn should succeed: $out"
  install_lock_probe "$FAKEBIN_DIR" "$exe"
  seen=$(emitted_launch) || fail "$harness secondmate: the emitted launch failed to run: $seen"
  assert_contains "$seen" "holder=$id" \
    "a $harness secondmate must launch with FM_LOCK_HOLDER set to its marker's name, not the inherited $INHERITED"
  assert_contains "$seen" "lock=0" "a $harness secondmate must claim its own home: $seen"
  assert_equals "holder:$id" "$(head -n 1 "$sm/state/.lock" 2>/dev/null)" \
    "a $harness secondmate must claim its own home as holder:$id"
  assert_equals "holder:$INHERITED" "$(head -n 1 "$HOME_DIR/state/.lock")" \
    "a $harness secondmate must leave main's holder line untouched"
}

test_shared_prefix_launch() {
  check_crewmate codex codex
  check_secondmate codex codex
  pass "shared launch prefix: a worker carries no inherited holder and a secondmate carries its marker's name"
}

test_cursor_launch() {
  check_crewmate cursor cursor-agent --model cursor-grok-4.5-high
  check_secondmate cursor cursor-agent --model cursor-grok-4.5-high
  pass "cursor launch: a worker carries no inherited holder and a secondmate carries its marker's name"
}

test_omp_launch() {
  check_crewmate omp omp --model openai-codex/gpt-6-astra
  check_secondmate omp omp --model openai-codex/gpt-6-astra
  pass "omp launch: a worker carries no inherited holder and a secondmate carries its marker's name"
}

test_shared_prefix_launch
test_cursor_launch
test_omp_launch
