#!/usr/bin/env bash
# tests/fm-forwarder-detector.test.sh - the hung-forwarder detector a second
# LaunchAgent runs every 300s.
#
# Each case runs the real bin/fm-forwarder-detector.sh against a real state
# directory whose beat mtimes are set by hand. launchctl is a stub on PATH that
# logs every call and answers `print` from FM_TEST_DOORBELL, so no case can reach
# the host's launchd. The notify command is a recorder that appends each row it
# is given to an inbox file. The arm-pid filter case hand-runs the real
# bin/fm-watch-arm.sh so its cycle-exit row is a real one.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DETECTOR="$ROOT/bin/fm-forwarder-detector.sh"
LABEL=com.example.fm-forwarder
DOORBELL=com.example.doorbell

TMP_ROOT=$(fm_test_tmproot fm-forwarder-detector-tests)

make_detector_case() {  # <name>
  local dir
  dir=$(make_case "$1")
  cat > "$dir/notify" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_INBOX:?}"
SH
  # print answers from FM_TEST_DOORBELL: running, down (not loaded) or hang.
  cat > "$dir/fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_LAUNCHCTL_LOG:?}"
if [ "${1:-}" = print ]; then
  case "${FM_TEST_DOORBELL:-running}" in
    running) printf '%s = {\n\tstate = running\n\tpid = 875\n}\n' "$2"; exit 0 ;;
    hang) printf '%s\n' "$$" > "$FM_TEST_LAUNCHCTL_LOG.hang-pid"; exec sleep 600 ;;
    *) echo "Could not find service \"${2##*/}\" in domain for user gui: 501" >&2; exit 113 ;;
  esac
fi
exit 0
SH
  chmod +x "$dir/notify" "$dir/fakebin/launchctl"
  : > "$dir/inbox"
  : > "$dir/launchctl.log"
  printf '%s\n' "$dir"
}

set_age() {  # <path> <seconds-old>
  local t
  t=$(( $(date +%s) - $2 ))
  [ -e "$1" ] || : > "$1"
  perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1] or die "utime: $!"' "$t" "$1"
}

write_beat() {  # <state> <arm-pid> <seconds-old>
  printf 'arm_pid=%s\nforwarder_pid=1\n' "$2" > "$1/.forwarder-beat"
  set_age "$1/.forwarder-beat" "$3"
}

cycle_row() {  # <state> <arm-pid> <ended-at>
  printf 'arm_pid=%s\twatcher_pid=9\torigin=started\tstarted_at=%s\tended_at=%s\texit_code=0\tsignal=none\treason=actionable-check\tbeacon_age=0\tlock_before=pid:9\tlock_after=pid:none\tsuccessor=none\n' \
    "$2" "$3" "$3" >> "$1/.watch-cycle-exits.log"
}

run_detector() {  # <case-dir> [env assignments...]
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_TEST_INBOX="$dir/inbox" FM_TEST_LAUNCHCTL_LOG="$dir/launchctl.log" "$@" \
    "$DETECTOR" --label "$LABEL" --doorbell "$DOORBELL" -- "$dir/notify" \
    >> "$dir/detector.out" 2>> "$dir/detector.err"
}

row_count() {  # <inbox>
  grep -c . "$1" 2>/dev/null || true
}

kickstarts() {  # <case-dir>
  grep -c "^kickstart -k gui/$(id -u)/$LABEL\$" "$1/launchctl.log" 2>/dev/null || true
}

# Test 13 and 14 on stale beats: one restart and one row in the hour, then one
# escalate row and the marker, then silence while the marker stands.
test_hung_restarts_once_then_escalates_then_stays_silent() {
  local dir state at
  dir=$(make_detector_case stale-beats)
  state="$dir/state"
  write_beat "$state" 4242 1000
  set_age "$state/.last-watcher-beat" 1000

  run_detector "$dir" || fail "detector run exited nonzero: $(cat "$dir/detector.err")"
  [ "$(kickstarts "$dir")" -eq 1 ] || fail "hung forwarder: $(kickstarts "$dir") kickstarts: $(cat "$dir/launchctl.log")"
  at=$(cat "$state/.forwarder-restart-at" 2>/dev/null)
  case "$at" in ''|*[!0-9]*) fail "restart time not recorded: '$at'" ;; esac
  [ $(( $(date +%s) - at )) -lt 30 ] || fail "restart time $at is not now"
  [ "$(row_count "$dir/inbox")" -eq 1 ] || fail "restart gave $(row_count "$dir/inbox") rows: $(cat "$dir/inbox")"
  grep -q "^firstmate forwarder detector in $dir: forwarder hung" "$dir/inbox" \
    || fail "restart row does not name the home: $(cat "$dir/inbox")"
  grep -q "kickstart -k" "$dir/inbox" || fail "restart row does not say it restarted: $(cat "$dir/inbox")"
  pass "detector: a hung forwarder (both beats over 960s) is restarted once, the time recorded, one row"

  # Still hung within the hour: no restart, one escalate row, the marker.
  run_detector "$dir" || fail "second run exited nonzero: $(cat "$dir/detector.err")"
  [ "$(kickstarts "$dir")" -eq 1 ] || fail "hung again within the hour was restarted: $(cat "$dir/launchctl.log")"
  [ "$(row_count "$dir/inbox")" -eq 2 ] || fail "escalation gave $(row_count "$dir/inbox") total rows: $(cat "$dir/inbox")"
  sed -n 2p "$dir/inbox" | grep -q "escalate" || fail "second row is not an escalation: $(sed -n 2p "$dir/inbox")"
  [ -e "$state/.forwarder-escalated" ] || fail "escalation marker not written"
  pass "detector: hung again within the hour escalates once with no restart and writes the marker"

  # While the marker stands: neither restart nor row, even past the hour.
  set_age "$state/.forwarder-restart-at" 4000
  run_detector "$dir" || fail "third run exited nonzero"
  run_detector "$dir" || fail "fourth run exited nonzero"
  [ "$(kickstarts "$dir")" -eq 1 ] || fail "restarted while escalated: $(cat "$dir/launchctl.log")"
  [ "$(row_count "$dir/inbox")" -eq 2 ] || fail "appended while escalated: $(cat "$dir/inbox")"
  pass "detector: while the escalation marker stands it neither restarts nor appends"

  # Cleared by pocock after John replies: past the hour, it restarts again.
  rm -f "$state/.forwarder-escalated"
  run_detector "$dir" || fail "post-clear run exited nonzero"
  [ "$(kickstarts "$dir")" -eq 2 ] || fail "no restart after the marker cleared and the hour passed"
  [ "$(row_count "$dir/inbox")" -eq 3 ] || fail "post-clear restart gave $(row_count "$dir/inbox") total rows"
  pass "detector: once the marker is cleared and the hour has passed, a hang restarts again"
}

test_only_one_stale_beat_is_not_hung() {
  local dir state
  dir=$(make_detector_case one-stale)
  state="$dir/state"
  write_beat "$state" 4242 1000
  set_age "$state/.last-watcher-beat" 100
  run_detector "$dir" || fail "run exited nonzero"
  write_beat "$state" 4242 100
  set_age "$state/.last-watcher-beat" 1000
  run_detector "$dir" || fail "run exited nonzero"
  [ "$(kickstarts "$dir")" -eq 0 ] || fail "one stale beat triggered a restart: $(cat "$dir/launchctl.log")"
  [ "$(row_count "$dir/inbox")" -eq 0 ] || fail "one stale beat sent a row: $(cat "$dir/inbox")"
  pass "detector: only one of the two beats over 960s is not a hang"
}

# Test 13, cycle-exit form: the forwarder's own arm ended over 60s after the
# beat and the forwarder never re-armed.
test_cycle_end_of_the_forwarders_arm_past_60s_is_hung() {
  local dir state now
  dir=$(make_detector_case cycle-exit)
  state="$dir/state"
  now=$(date +%s)
  write_beat "$state" 4242 200
  set_age "$state/.last-watcher-beat" 5
  cycle_row "$state" 4242 $(( now - 200 + 30 ))
  run_detector "$dir" || fail "run exited nonzero"
  [ "$(kickstarts "$dir")" -eq 0 ] || fail "a cycle end 30s after the beat triggered a restart"
  cycle_row "$state" 4242 $(( now - 200 + 90 ))
  run_detector "$dir" || fail "run exited nonzero"
  [ "$(kickstarts "$dir")" -eq 1 ] || fail "the forwarder's arm ended 90s after the beat with no restart: $(cat "$dir/launchctl.log")"
  [ "$(row_count "$dir/inbox")" -eq 1 ] || fail "cycle-exit hang gave $(row_count "$dir/inbox") rows"
  pass "detector: the forwarder's own arm ending over 60s after the beat is a hang"
}

# Test 18b: with the forwarder healthy, a hand-run arm writes a real cycle end
# under another pid, and nothing is triggered. The divergence check then proves
# the arm pid is what kept it silent.
test_hand_run_arm_cycle_triggers_nothing() {
  local dir state hand_pid
  dir=$(make_detector_case hand-arm)
  state="$dir/state"
  write_beat "$state" 4242 200
  append_wake "$state" check startup-network 'check: startup-network hand-run fixture'
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=30 FM_TEST_LAUNCHCTL_LOG="$dir/launchctl.log" \
    "$ROOT/bin/fm-watch-arm.sh" > "$dir/arm.out" 2>&1 </dev/null
  fm_test_reap_watchers
  hand_pid=$(sed -n 's/^arm_pid=\([0-9]*\).*/\1/p' "$state/.watch-cycle-exits.log" | tail -n 1)
  [ -n "$hand_pid" ] && [ "$hand_pid" != 4242 ] \
    || fail "the hand-run arm wrote no cycle end of its own: $(cat "$state/.watch-cycle-exits.log" 2>/dev/null) arm=$(cat "$dir/arm.out")"
  : > "$dir/launchctl.log"
  run_detector "$dir" || fail "run exited nonzero: $(cat "$dir/detector.err")"
  [ "$(kickstarts "$dir")" -eq 0 ] || fail "a hand-run arm's cycle end restarted the forwarder"
  [ "$(row_count "$dir/inbox")" -eq 0 ] || fail "a hand-run arm's cycle end sent a row: $(cat "$dir/inbox")"
  pass "detector: a hand-run arm's cycle end (another arm pid) triggers nothing"

  write_beat "$state" "$hand_pid" 200
  run_detector "$dir" || fail "run exited nonzero"
  [ "$(kickstarts "$dir")" -eq 1 ] || fail "divergence: the same cycle end under the beat's arm pid did not count"
  pass "detector: the same cycle end counts once its arm pid is the beat's"
}

test_doorbell_down_is_logged() {
  local dir state
  dir=$(make_detector_case doorbell)
  state="$dir/state"
  write_beat "$state" 4242 5
  set_age "$state/.last-watcher-beat" 5
  run_detector "$dir" FM_TEST_DOORBELL=running || fail "run exited nonzero"
  ! grep -q "doorbell down" "$dir/detector.err" || fail "doorbell down logged while running: $(cat "$dir/detector.err")"
  grep -q "^print gui/$(id -u)/$DOORBELL\$" "$dir/launchctl.log" || fail "doorbell not read: $(cat "$dir/launchctl.log")"
  run_detector "$dir" FM_TEST_DOORBELL=down || fail "run exited nonzero"
  grep -q "doorbell down" "$dir/detector.err" || fail "no doorbell down line: $(cat "$dir/detector.err")"
  grep -q "$DOORBELL" "$dir/detector.err" || fail "doorbell line does not name the job"
  [ "$(row_count "$dir/inbox")" -eq 0 ] || fail "doorbell down sent a row"
  pass "detector: logs doorbell down when the ping job is not running"
}

test_each_run_touches_the_detector_beat() {
  local dir state
  dir=$(make_detector_case beat)
  state="$dir/state"
  write_beat "$state" 4242 5
  set_age "$state/.last-watcher-beat" 5
  set_age "$state/.detector-beat" 5000
  run_detector "$dir" || fail "run exited nonzero"
  [ $(( $(date +%s) - $(perl -e 'print +(stat $ARGV[0])[9]' "$state/.detector-beat") )) -lt 30 ] || fail "detector beat not touched"
  pass "detector: each run touches the detector beat"
}

# Test 15: a hung run is ended by the alarm; a killed run leaves nothing that
# stops the next run.
test_hung_run_is_ended_by_the_alarm() {
  local dir state start took rc
  dir=$(make_detector_case alarm)
  state="$dir/state"
  write_beat "$state" 4242 1000
  set_age "$state/.last-watcher-beat" 1000
  start=$(date +%s)
  run_detector "$dir" FM_TEST_DOORBELL=hang FM_DETECTOR_ALARM_SECONDS=2
  rc=$?
  took=$(( $(date +%s) - start ))
  [ "$took" -lt 15 ] || fail "a hung run took ${took}s; the alarm did not end it"
  [ "$rc" -ne 0 ] || fail "a run ended by the alarm exited 0"
  [ -e "$state/.detector-beat" ] || fail "the hung run did not touch the beat before hanging"
  kill "$(cat "$dir/launchctl.log.hang-pid" 2>/dev/null)" 2>/dev/null || true
  pass "detector: a hung run is ended by its alarm (exit $rc after ${took}s)"

  run_detector "$dir" || fail "the run after a hung one exited nonzero: $(cat "$dir/detector.err")"
  [ "$(kickstarts "$dir")" -eq 1 ] || fail "the next run did not act on the hang"
  pass "detector: the run after an alarm-ended one acts normally"
}

test_no_forwarder_beat_does_nothing() {
  local dir state
  dir=$(make_detector_case no-beat)
  state="$dir/state"
  run_detector "$dir" || fail "run exited nonzero"
  [ "$(kickstarts "$dir")" -eq 0 ] || fail "restarted with no forwarder beat"
  [ "$(row_count "$dir/inbox")" -eq 0 ] || fail "row with no forwarder beat"
  grep -q "no forwarder beat" "$dir/detector.err" || fail "missing beat not logged: $(cat "$dir/detector.err")"
  pass "detector: a home with no forwarder beat is logged and left alone"
}

test_refuses_without_home_or_label() {
  local out status
  out=$(env -u FM_HOME "$DETECTOR" --label x -- /bin/true 2>&1)
  status=$?
  [ "$status" -eq 2 ] || fail "no FM_HOME exited $status: $out"
  assert_contains "$out" "FM_HOME is not set" "refusal names the missing home"
  out=$(FM_HOME="$TMP_ROOT" "$DETECTOR" -- /bin/true 2>&1)
  status=$?
  [ "$status" -eq 2 ] || fail "no --label exited $status: $out"
  assert_contains "$out" "--label" "refusal names the missing label"
  pass "detector: refuses to guess a home or a forwarder label"
}

fm_test_run \
  test_hung_restarts_once_then_escalates_then_stays_silent \
  test_only_one_stale_beat_is_not_hung \
  test_cycle_end_of_the_forwarders_arm_past_60s_is_hung \
  test_hand_run_arm_cycle_triggers_nothing \
  test_doorbell_down_is_logged \
  test_each_run_touches_the_detector_beat \
  test_hung_run_is_ended_by_the_alarm \
  test_no_forwarder_beat_does_nothing \
  test_refuses_without_home_or_label
