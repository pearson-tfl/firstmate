#!/usr/bin/env bash
# Tests for the watcher's repeated bare turn-end absorb: a stopped worker whose
# harness keeps re-touching its turn-end marker, with no status append and an
# unchanged pane, surfaces once and then only on the bounded re-surface cadence,
# while any status append or pane change surfaces as before.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-turnend-repeat)

DIR=$(make_case repeat)
STATE="$DIR/state"
FAKEBIN="$DIR/fakebin"
WINDOW="test:fm-t1"
KEY=$(printf '%s' "$WINDOW" | tr ':/.' '___')
CAPTURE="$DIR/pane.txt"
STAMP=$(( $(date +%s) - 1000 ))
export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

set_pane() {  # <text>
  printf '%s' "$1" > "$CAPTURE"
  printf '%s' "$(hash_text "$1")" > "$STATE/.hash-$KEY"
  printf '0\n' > "$STATE/.count-$KEY"
}

# Re-touch the marker at a fresh, distinct mtime so its size:mtime signature moves.
touch_turnend() {
  STAMP=$((STAMP + 7))
  set_mtime "$STAMP" "$STATE/t1.turn-ended"
}

# Launch one watcher in the background; its pid lands in WATCH_PID.
launch() {  # [env...]
  PATH="$FAKEBIN:$PATH" FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
    FM_FAKE_TMUX_WINDOW="$WINDOW" FM_FAKE_TMUX_CAPTURE="$CAPTURE" \
    FM_POLL=3 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 env "$@" "$WATCH" > "$DIR/watch.out" &
  WATCH_PID=$!
}

# A reaped absorb round leaves watcher downtime behind, so the next watcher may
# first announce its recovery; acknowledge that and launch again.
rearm_recovered() {  # <label> [env...]
  local label=$1
  shift
  grep -Fxq 'check: rearm-resurface' "$DIR/watch.out" || return 1
  ack_stopped_cycle "$STATE" >/dev/null || fail "$label: could not acknowledge the recovery wake"
  launch "$@"
}

# One watcher round. <expect> is wake (it must exit with a signal wake, which is
# then drained and acknowledged) or absorb (it must log the repeat absorb and
# queue no signal wake).
round() {  # <expect> <label> [env...]
  local expect=$1 label=$2 out="$DIR/watch.out" i=0
  shift 2
  : > "$STATE/.watch-triage.log"
  launch "$@"
  if [ "$expect" = wake ]; then
    wait_for_exit "$WATCH_PID" 100 || fail "$label: the watcher did not surface a wake"
    if rearm_recovered "$label" "$@"; then
      wait_for_exit "$WATCH_PID" 100 || fail "$label: the watcher did not surface a wake"
    fi
    grep -F "signal: " "$out" >/dev/null || fail "$label: no signal wake printed: $(cat "$out")"
    ack_stopped_cycle "$STATE" >/dev/null || fail "$label: could not drain and acknowledge the wake"
    return 0
  fi
  while ! grep -Fq "absorbed repeated bare turn-end" "$STATE/.watch-triage.log" 2>/dev/null; do
    if ! kill -0 "$WATCH_PID" 2>/dev/null; then
      wait_for_exit "$WATCH_PID" 100 || true
      rearm_recovered "$label" "$@" \
        || fail "$label: the watcher surfaced instead of absorbing: $(cat "$out")"
    fi
    [ "$i" -lt 150 ] || { reap "$WATCH_PID"; fail "$label: no repeat absorb was logged"; }
    sleep 0.1
    i=$((i + 1))
  done
  reap "$WATCH_PID"
  [ ! -s "$out" ] || fail "$label: an absorbed repeat printed a wake: $(cat "$out")"
  if FM_STATE_OVERRIDE="$STATE" "$DRAIN" 2>/dev/null | grep -F "$(printf '\tsignal\t')" >/dev/null; then
    fail "$label: an absorbed repeat queued a signal wake"
  fi
  return 0
}

printf 'window=%s\nkind=ship\nharness=claude\n' "$WINDOW" > "$STATE/t1.meta"
set_pane 'stopped: the model was refused'
: > "$STATE/t1.turn-ended"
touch_turnend

round wake "first turn-end"
pass "a first bare turn-end from a stopped worker surfaces"

touch_turnend
round absorb "unchanged repeat"
[ "$(cat "$STATE/.seen-t1_turn-ended")" = "$(seen_sig "$STATE/t1.turn-ended")" ] \
  || fail "the absorbed repeat did not advance the turn-end's seen marker"
pass "a repeated bare turn-end with status and pane unchanged is absorbed and its seen marker advanced"

printf 'working [at=%s]: retrying\n' "$(date +%s)" >> "$STATE/t1.status"
round wake "status append"
pass "a status append surfaces"

touch_turnend
round wake "first turn-end after a status wake"
touch_turnend
round absorb "repeat after the status wake"
set_pane 'the worker printed something new'
touch_turnend
round wake "changed pane"
pass "a repeat whose pane hash changed surfaces"

touch_turnend
round absorb "repeat before the bound" FM_TURNEND_REPEAT_RESURFACE_SECS=10
sleep 10
touch_turnend
round wake "repeat past the bound" FM_TURNEND_REPEAT_RESURFACE_SECS=10
touch_turnend
round absorb "repeat after the re-surface" FM_TURNEND_REPEAT_RESURFACE_SECS=10
pass "repeats past the re-surface bound surface exactly once, then absorb again"

rm -f "$STATE/.hash-$KEY"
touch_turnend
round wake "unreadable pane"
pass "a repeat whose pane cannot be read surfaces"
