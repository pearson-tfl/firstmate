#!/usr/bin/env bash
# Keep one home's watcher armed with no harness session and forward each wake
# to a peer inbox, for a home whose main is held by name rather than by a live
# harness process (a LaunchAgent with RunAtLoad and KeepAlive runs it).
#
# Usage:
#   FM_HOME=<home> fm-wake-forwarder.sh [--once] -- <notify-command> [args...]
#
# Each loop:
#   1. Writes state/.forwarder-beat (its mtime is the forwarder's beat), then
#      sends one row through <notify-command> when the hung-forwarder
#      detector's beat is stale (bin/fm-forwarder-detector-lib.sh).
#   2. Runs bin/fm-watch-arm.sh as a tracked child it waits on and stops on
#      TERM or INT (never fired and forgotten).
#      The child records its own pid as `arm_pid=<N>` in the beat before it
#      execs the arm, so the pid in the beat is the arm pid that
#      state/.watch-cycle-exits.log rows begin with.
#   3. Waits for the arm process to exit, then atomically records completed_at
#      in the beat. Interim attached-watcher cycle exits are not arm exits.
#      run_id and arm_sequence identify this arm incarnation. Each phase is
#      recorded in .forwarder-phases.log (last 128 rows), with UTC time, epoch,
#      arm identity, exit status and elapsed seconds. Notify payloads are omitted.
#   4. When the arm surfaced a wake (exit 0 with a reason line), runs
#      <notify-command> [args...] "<one-line row text>" once. The row names the
#      home and the arm's reason line. A failed notify is retried: the next
#      arm is a plain one, which re-announces the still-queued wake.
#   5. Repeats; --once stops after the first cycle. After a forwarded wake the
#      next arm runs as that wake's handling successor
#      (FM_WATCH_PREDECESSOR_ARM_PID, as bin/fm-claude-stop-autoarm.sh starts
#      it), so a wake still queued for its holder is forwarded once, not on
#      every re-arm; docs/watcher-continuity.md owns that contract.
#
# It never drains or acknowledges the wake queue: the queue row stays until the
# holder of main drains and acknowledges it (bin/fm-wake-drain.sh). It reads and
# writes no main lock (state/.lock) and needs no secret. Only one copy runs per
# home: the singleton is state/.forwarder.lock through fm_lock_try_acquire
# (bin/fm-wake-lib.sh), and a second copy prints
# "forwarder: already running pid=<N>" and exits 0 without arming.
#
# After a failed arm cycle (nonzero exit) or a cycle with no reason line it
# forwards no wake and waits FM_FORWARDER_RETRY_SECONDS (default 15) before the
# next arm, so a failing arm cannot spin. The first such cycle after a healthy
# one (or at start) sends one "arm failing" row naming the arm's last line;
# later failures in the same run send none, once that row was delivered. A
# failed notify command is reported on stderr and retried as above.
#
# FM_HOME must be set explicitly; the forwarder refuses to guess a home.
# FM_FORWARDER_ARM overrides the arm path (default: this checkout's
# bin/fm-watch-arm.sh).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p;}' "$0"
}

once=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --once) once=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) echo "forwarder: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$#" -eq 0 ]; then
  echo "forwarder: missing notify command after --" >&2
  exit 2
fi

if [ -z "${FM_HOME:-}" ]; then
  echo "forwarder: FM_HOME is not set; refusing to guess a firstmate home" >&2
  exit 2
fi
if [ ! -d "$FM_HOME" ]; then
  echo "forwarder: FM_HOME '$FM_HOME' is not a directory" >&2
  exit 2
fi
export FM_HOME

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-forwarder-detector-lib.sh
. "$SCRIPT_DIR/fm-forwarder-detector-lib.sh"

ARM=${FM_FORWARDER_ARM:-$SCRIPT_DIR/fm-watch-arm.sh}
RETRY=${FM_FORWARDER_RETRY_SECONDS:-15}
FORWARDER_LOCK="$STATE/.forwarder.lock"
FORWARDER_BEAT="$STATE/.forwarder-beat"
ARM_OUT="$STATE/.forwarder-arm.out"
PHASE_LOG="$STATE/.forwarder-phases.log"
run_id="$$-$(date +%s)"
arm_sequence=0
arm_pid=
started_at=0
completed_at=0

if ! fm_lock_try_acquire "$FORWARDER_LOCK"; then
  echo "forwarder: already running pid=${FM_LOCK_HELD_PID:-unknown}"
  exit 0
fi
trap 'fm_lock_release "$FORWARDER_LOCK"' EXIT
# A shutdown signal stops the arm too, whose own TERM handler stops its
# watcher, so neither outlives the forwarder.
arm_child=
stop_arm() {  # <exit-code>
  if [ -n "$arm_child" ]; then
    kill -TERM "$arm_child" 2>/dev/null || true
    wait "$arm_child" 2>/dev/null || true
  fi
  exit "$1"
}
trap 'stop_arm 143' TERM
trap 'stop_arm 130' INT

record_phase() {  # <phase> [exit-code] [elapsed-seconds]
  local phase=$1 now
  now=$(date +%s)
  {
    printf 'arm_pid=%s\nforwarder_pid=%s\nrun_id=%s\narm_sequence=%s\n' "$arm_pid" "$$" "$run_id" "$arm_sequence"
    printf 'started_at=%s\ncompleted_at=%s\nphase=%s\n' "$started_at" "$completed_at" "$phase"
  } > "$FORWARDER_BEAT.tmp" && mv -f "$FORWARDER_BEAT.tmp" "$FORWARDER_BEAT"
  printf 'at=%s\tepoch=%s\trun_id=%s\tarm_sequence=%s\tarm_pid=%s\tphase=%s\texit_code=%s\telapsed=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$now" "$run_id" "$arm_sequence" "$arm_pid" "$phase" "${2:-none}" "${3:-0}" >> "$PHASE_LOG"
  tail -n 128 "$PHASE_LOG" > "$PHASE_LOG.tmp" && mv -f "$PHASE_LOG.tmp" "$PHASE_LOG"
}

notify_row() {  # <row-text> <notify-command> [args...]
  local row=$1 begin result
  shift
  begin=$(date +%s)
  record_phase notify-begin
  "$@" "$row" </dev/null
  result=$?
  record_phase notify-end "$result" "$(( $(date +%s) - begin ))"
  return "$result"
}

predecessor=
failing=0
while :; do
  arm_sequence=$((arm_sequence + 1))
  arm_pid=
  completed_at=0
  started_at=$(date +%s)
  record_phase arm-start
  fm_detector_beat_check "$@"
  # The child writes its own pid, then execs the arm in place, so the pid in
  # the beat is the arm's own pid. The forwarder waits on it and signals it on
  # shutdown: a tracked child, never fired and forgotten.
  /bin/bash -c '
    printf "arm_pid=%s\nforwarder_pid=%s\nrun_id=%s\narm_sequence=%s\nstarted_at=%s\ncompleted_at=0\nphase=arm-wait\n" "$$" "$2" "$5" "$6" "$7" > "$1.tmp" && mv -f "$1.tmp" "$1"
    if [ -n "$4" ]; then
      FM_WATCH_PREDECESSOR_ARM_PID=$4 exec "$3"
    fi
    unset FM_WATCH_PREDECESSOR_ARM_PID
    exec "$3"
  ' _ "$FORWARDER_BEAT" "$$" "$ARM" "$predecessor" "$run_id" "$arm_sequence" "$started_at" > "$ARM_OUT" 2>&1 </dev/null &
  arm_child=$!
  wait "$arm_child"
  rc=$?
  arm_pid=$arm_child
  arm_child=
  completed_at=$(date +%s)
  record_phase arm-exit "$rc" "$((completed_at - started_at))"
  predecessor=
  reason=$(grep -v '^watcher: ' "$ARM_OUT" | grep -v '^[[:space:]]*$' | tail -n 1)
  if [ "$rc" -eq 0 ] && [ -n "$reason" ]; then
    failing=0
    if notify_row "firstmate wake in $FM_HOME: $reason" "$@"; then
      # The next arm is this wake's handling successor, as the Claude
      # auto-arm's is, so it does not re-announce the delivered wake while it
      # stays queued.
      predecessor=$arm_pid
    else
      # Undelivered: a plain re-arm re-announces the still-queued wake, so the
      # row is retried after the pause.
      echo "forwarder: notify command failed for: $reason" >&2
      [ "$once" -eq 1 ] || sleep "$RETRY"
    fi
  else
    last=$(tail -n 1 "$ARM_OUT")
    echo "forwarder: arm cycle forwarded nothing (exit $rc): $last" >&2
    # The beat stays fresh while the arm fails, so no beat-age check can see a
    # failing arm: the first failed cycle of each run of failures sends one row.
    if [ "$failing" -eq 0 ]; then
      if notify_row "firstmate wake forwarder in $FM_HOME: arm failing (exit $rc): $last" "$@"; then
        failing=1
      else
        echo "forwarder: notify command failed for the arm-failure row" >&2
      fi
    fi
    [ "$once" -eq 1 ] || sleep "$RETRY"
  fi
  [ "$once" -eq 0 ] || exit 0
done
