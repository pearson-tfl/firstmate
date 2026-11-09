#!/usr/bin/env bash
# tests/fm-wake-forwarder.test.sh - the wake forwarder that keeps a named-holder
# main's watcher armed and forwards each wake to a peer inbox.
#
# Real-process tests: a real bin/fm-wake-forwarder.sh runs the real
# bin/fm-watch-arm.sh and bin/fm-watch.sh against a real state directory, a real
# wake goes through the durable queue, and the notify command is a recorder that
# appends each row it is given to an inbox file. launchctl is stubbed on PATH so
# no case can reach the host's launchd.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

FORWARDER="$ROOT/bin/fm-wake-forwarder.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-forwarder-tests)

FWD_PID=

# A recorder notify command and a launchctl stub that logs any call.
make_forwarder_case() {  # <name>
  local dir
  dir=$(make_case "$1")
  cat > "$dir/notify" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_INBOX:?}"
SH
  cat > "$dir/fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_LAUNCHCTL_LOG:?}"
exit 0
SH
  chmod +x "$dir/notify" "$dir/fakebin/launchctl"
  : > "$dir/inbox"
  printf '%s\n' "$dir"
}

start_forwarder() {  # <case-dir>
  local dir=$1
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_TEST_INBOX="$dir/inbox" FM_TEST_LAUNCHCTL_LOG="$dir/launchctl.log" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=30 FM_FORWARDER_RETRY_SECONDS=1 \
    "$FORWARDER" -- "$dir/notify" > "$dir/forwarder.out" 2> "$dir/forwarder.err" &
  FWD_PID=$!
}

beat_arm_pid() {  # <state>
  sed -n 's/^arm_pid=//p' "$1/.forwarder-beat" 2>/dev/null | head -n 1
}

# Wait until the forwarder's arm is recorded and its watcher holds the lock.
wait_for_armed() {  # <state>
  local state=$1 i=0 pid
  while [ "$i" -lt 200 ]; do
    pid=$(beat_arm_pid "$state")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
      && [ -n "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" ] \
      && [ -e "$state/.last-watcher-beat" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# The forwarder runs its arm in the foreground, so its TERM takes effect when
# the arm's cycle ends: signal the forwarder, then end the arm's cycle.
stop_forwarder() {  # <state>
  local state=$1 arm
  arm=$(beat_arm_pid "$state")
  kill "$FWD_PID" 2>/dev/null || true
  [ -z "$arm" ] || kill "$arm" 2>/dev/null || true
  wait "$FWD_PID" 2>/dev/null || true
  fm_test_reap_watchers
}

row_count() {  # <inbox>
  grep -c . "$1" 2>/dev/null || true
}

test_one_wake_gives_one_row_and_keeps_the_queue_row() {
  local dir state arm i n
  dir=$(make_forwarder_case one-wake)
  state="$dir/state"
  start_forwarder "$dir"
  wait_for_armed "$state" || fail "forwarder never armed a watcher: $(cat "$dir/forwarder.err")"
  arm=$(beat_arm_pid "$state")
  case "$arm" in ''|*[!0-9]*) fail "beat does not carry a numeric arm pid: $(cat "$state/.forwarder-beat")" ;; esac
  ps -p "$arm" -o command= | grep -q 'fm-watch-arm.sh' \
    || fail "beat pid $arm is not the arm: $(ps -p "$arm" -o command=)"

  append_wake "$state" check startup-network 'check: startup-network forwarder fixture'

  i=0
  while [ "$i" -lt 300 ] && [ "$(row_count "$dir/inbox")" -lt 1 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(row_count "$dir/inbox")" -ge 1 ] \
    || fail "no inbox row after a wake: err=$(cat "$dir/forwarder.err") arm=$(cat "$state/.forwarder-arm.out")"
  grep -q "^firstmate wake in $dir: check: " "$dir/inbox" \
    || fail "row does not carry the home and the arm's reason line: $(cat "$dir/inbox")"

  # The forwarder re-arms after the row. Give several re-arm cycles the chance
  # to forward the same un-acknowledged wake again.
  wait_for_armed "$state" || fail "forwarder did not re-arm after the wake: $(cat "$dir/forwarder.err")"
  sleep 6
  n=$(row_count "$dir/inbox")
  [ "$n" -eq 1 ] || fail "one wake gave $n inbox rows: $(cat "$dir/inbox")"
  grep -q "$(printf '\tcheck\tstartup-network\t')" "$state/.wake-queue" \
    || fail "the forwarder consumed the queue row: $(cat "$state/.wake-queue" 2>/dev/null)"
  grep -q "^arm_pid=$arm	" "$state/.watch-cycle-exits.log" \
    || fail "no cycle-exit row for the beat's arm pid $arm: $(cat "$state/.watch-cycle-exits.log")"
  [ ! -s "$dir/launchctl.log" ] || fail "forwarder called launchctl: $(cat "$dir/launchctl.log")"
  pass "forwarder: one wake gives one inbox row, the queue row stays, the beat carries the arm pid"

  # A later wake, with the first still unacknowledged, is forwarded once too.
  append_wake "$state" check inbox:fixture 'check: captain inbox note fixture'
  i=0
  while [ "$i" -lt 300 ] && [ "$(row_count "$dir/inbox")" -lt 2 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  wait_for_armed "$state" || fail "forwarder did not re-arm after the second wake"
  sleep 6
  n=$(row_count "$dir/inbox")
  [ "$n" -eq 2 ] || fail "two wakes gave $n inbox rows: $(cat "$dir/inbox")"
  [ "$(grep -c . "$state/.wake-queue")" -eq 2 ] \
    || fail "the forwarder changed the queue: $(cat "$state/.wake-queue")"
  stop_forwarder "$state"
  pass "forwarder: a later wake gets its own row while the first stays queued"
}

test_second_copy_exits_without_arming() {
  local dir state beat_before out status
  dir=$(make_forwarder_case second-copy)
  state="$dir/state"
  start_forwarder "$dir"
  wait_for_armed "$state" || fail "first forwarder never armed: $(cat "$dir/forwarder.err")"
  beat_before=$(cat "$state/.forwarder-beat")

  cat > "$dir/arm-recorder" <<'SH'
#!/usr/bin/env bash
printf 'armed\n' >> "${FM_TEST_ARM_LOG:?}"
SH
  chmod +x "$dir/arm-recorder"
  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_TEST_INBOX="$dir/inbox" FM_TEST_ARM_LOG="$dir/arm.log" \
    FM_FORWARDER_ARM="$dir/arm-recorder" "$FORWARDER" --once -- "$dir/notify" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "second copy exited $status: $out"
  assert_contains "$out" "forwarder: already running pid=$FWD_PID" "second copy names the running copy"
  [ ! -e "$dir/arm.log" ] || fail "second copy armed: $(cat "$dir/arm.log")"
  [ "$(cat "$state/.forwarder-beat")" = "$beat_before" ] || fail "second copy rewrote the beat"
  stop_forwarder "$state"
  pass "forwarder: a second copy started while one runs exits without arming"
}

test_failing_arm_sends_one_row_per_failure_run() {
  local dir state i
  dir=$(make_forwarder_case failing-arm)
  state="$dir/state"
  cat > "$dir/arm-fails" <<'SH'
#!/usr/bin/env bash
printf 'x\n' >> "${FM_TEST_ARM_LOG:?}"
echo "watcher: FAILED - no live watcher with a fresh beacon"
exit 1
SH
  chmod +x "$dir/arm-fails"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_TEST_INBOX="$dir/inbox" FM_TEST_ARM_LOG="$dir/arm.log" \
    FM_FORWARDER_ARM="$dir/arm-fails" FM_FORWARDER_RETRY_SECONDS=0.1 \
    "$FORWARDER" -- "$dir/notify" > "$dir/forwarder.out" 2> "$dir/forwarder.err" &
  FWD_PID=$!
  i=0
  while [ "$i" -lt 100 ] && [ "$(grep -c . "$dir/arm.log" 2>/dev/null || echo 0)" -lt 5 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  kill "$FWD_PID" 2>/dev/null || true
  wait "$FWD_PID" 2>/dev/null || true
  [ "$(grep -c . "$dir/arm.log")" -ge 5 ] || fail "forwarder did not keep retrying a failing arm"
  [ "$(row_count "$dir/inbox")" -eq 1 ] \
    || fail "a run of failed arms gave $(row_count "$dir/inbox") rows: $(cat "$dir/inbox")"
  grep -q "^firstmate wake forwarder in $dir: arm failing (exit 1): watcher: FAILED" "$dir/inbox" \
    || fail "failure row does not name the home and the arm's line: $(cat "$dir/inbox")"
  pass "forwarder: a run of failed arm cycles sends one row"
}

test_failed_notify_is_retried() {
  local dir state i
  dir=$(make_forwarder_case notify-retry)
  state="$dir/state"
  # The notify fails once, then delivers.
  cat > "$dir/notify" <<'SH'
#!/usr/bin/env bash
if [ ! -e "${FM_TEST_INBOX:?}.failed-once" ]; then
  : > "$FM_TEST_INBOX.failed-once"
  exit 1
fi
printf '%s\n' "$*" >> "$FM_TEST_INBOX"
SH
  start_forwarder "$dir"
  wait_for_armed "$state" || fail "forwarder never armed: $(cat "$dir/forwarder.err")"
  append_wake "$state" check startup-network 'check: startup-network retry fixture'
  i=0
  while [ "$i" -lt 300 ] && [ "$(row_count "$dir/inbox")" -lt 1 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$dir/inbox.failed-once" ] || fail "the notify was never attempted"
  [ "$(row_count "$dir/inbox")" -eq 1 ] \
    || fail "a wake whose first notify failed was not delivered: $(cat "$dir/forwarder.err")"
  stop_forwarder "$state"
  pass "forwarder: a wake whose notify failed is delivered on retry"
}

test_term_stops_the_arm_and_watcher() {
  local dir state arm watcher i
  dir=$(make_forwarder_case term-stops)
  state="$dir/state"
  start_forwarder "$dir"
  wait_for_armed "$state" || fail "forwarder never armed: $(cat "$dir/forwarder.err")"
  arm=$(beat_arm_pid "$state")
  watcher=$(cat "$state/.watch.lock/pid")
  kill -TERM "$FWD_PID"
  i=0
  while [ "$i" -lt 100 ] && { kill -0 "$FWD_PID" 2>/dev/null || kill -0 "$arm" 2>/dev/null \
    || kill -0 "$watcher" 2>/dev/null; }; do
    sleep 0.1
    i=$((i + 1))
  done
  wait "$FWD_PID" 2>/dev/null || true
  ! kill -0 "$arm" 2>/dev/null || fail "arm $arm outlived the forwarder's TERM"
  ! kill -0 "$watcher" 2>/dev/null || fail "watcher $watcher outlived the forwarder's TERM"
  pass "forwarder: TERM stops the forwarder, its arm and its watcher"
}

test_refuses_without_an_explicit_home() {
  local out status
  out=$(env -u FM_HOME "$FORWARDER" --once -- /bin/true 2>&1)
  status=$?
  [ "$status" -eq 2 ] || fail "no FM_HOME exited $status: $out"
  assert_contains "$out" "FM_HOME is not set" "refusal names the missing home"
  pass "forwarder: refuses to guess a home"
}

# Each forwarder loop checks the detector's beat: one row per stale beat, not
# one per loop.
test_loop_sends_one_row_on_a_stale_detector_beat() {
  local dir state i t
  dir=$(make_forwarder_case detector-beat)
  state="$dir/state"
  : > "$state/.detector-beat"
  t=$(( $(date +%s) - 1000 ))
  perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1] or die' "$t" "$state/.detector-beat"
  start_forwarder "$dir"
  wait_for_armed "$state" || fail "forwarder never armed: $(cat "$dir/forwarder.err")"
  i=0
  while [ "$i" -lt 50 ] && ! grep -q "detector beat" "$dir/inbox"; do
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(grep -c "detector beat is" "$dir/inbox")" -eq 1 ] \
    || fail "a stale detector beat gave $(grep -c "detector beat is" "$dir/inbox") rows: $(cat "$dir/inbox")"
  grep -q "^firstmate forwarder detector in $dir: detector beat is" "$dir/inbox" \
    || fail "detector row does not name the home: $(cat "$dir/inbox")"
  # A wake makes the loop run again; the same stale beat sends no second row.
  append_wake "$state" check startup-network 'check: startup-network detector fixture'
  i=0
  while [ "$i" -lt 300 ] && ! grep -q "^firstmate wake in" "$dir/inbox"; do
    sleep 0.1
    i=$((i + 1))
  done
  wait_for_armed "$state" || fail "forwarder did not re-arm after the wake"
  [ "$(grep -c "detector beat is" "$dir/inbox")" -eq 1 ] \
    || fail "the next loop sent another row for the same stale beat: $(cat "$dir/inbox")"
  stop_forwarder "$state"
  pass "forwarder: the loop sends one row on a detector beat over 900s"
}

test_phase_records_are_bounded_and_terminal() {
  local dir state
  dir=$(make_forwarder_case phase-records)
  state="$dir/state"
  cat > "$dir/arm" <<'SH'
#!/usr/bin/env bash
printf 'check: fixture phase wake\n'
SH
  chmod +x "$dir/arm"
  # Seed old evidence to prove the public executable enforces the bound.
  for _ in $(seq 1 140); do printf 'old phase\n'; done > "$state/.forwarder-phases.log"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_FORWARDER_ARM="$dir/arm" FM_TEST_INBOX="$dir/inbox" \
    "$FORWARDER" --once -- "$dir/notify" > "$dir/forwarder.out" 2> "$dir/forwarder.err" \
    || fail "phase forwarder failed: $(cat "$dir/forwarder.err")"
  [ "$(wc -l < "$state/.forwarder-phases.log" | tr -d ' ')" -eq 128 ] || fail "phase evidence is unbounded"
  grep -q 'phase=arm-exit.*exit_code=0.*elapsed=' "$state/.forwarder-phases.log" || fail "terminal timing missing"
  grep -q 'phase=notify-begin' "$state/.forwarder-phases.log" || fail "notify start missing"
  grep -q 'phase=notify-end.*exit_code=0.*elapsed=' "$state/.forwarder-phases.log" || fail "notify finish missing"
  grep -Eq '^completed_at=[1-9][0-9]+$' "$state/.forwarder-beat" || fail "terminal completion not retained"
  grep -q '^run_id=' "$state/.forwarder-beat" || fail "incarnation absent"
  ! grep -q 'fixture phase wake' "$state/.forwarder-phases.log" || fail "diagnostic recorded payload"
  pass "forwarder: bounded phase records retain terminal/notify timing without wake payloads"
}

test_one_wake_gives_one_row_and_keeps_the_queue_row
test_second_copy_exits_without_arming
test_failing_arm_sends_one_row_per_failure_run
test_failed_notify_is_retried
test_term_stops_the_arm_and_watcher
test_refuses_without_an_explicit_home
test_loop_sends_one_row_on_a_stale_detector_beat

test_phase_records_are_bounded_and_terminal
