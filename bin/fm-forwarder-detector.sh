#!/usr/bin/env bash
# Detect a hung wake forwarder (bin/fm-wake-forwarder.sh) and restart it once
# an hour, escalating a repeat. A LaunchAgent with StartInterval 300 runs it.
#
# Usage:
#   FM_HOME=<home> fm-forwarder-detector.sh --label <forwarder-label>
#       [--doorbell <label>] -- <notify-command> [args...]
#
# Each run is cut off after FM_DETECTOR_ALARM_SECONDS (default 120): the script
# re-runs itself under `perl -e 'alarm N; exec @ARGV'`, and the alarm ends a
# hung run. Each run then:
#   1. Touches state/.detector-beat, which the forwarder loop and the named
#      claim (bin/fm-lock.sh) check (bin/fm-forwarder-detector-lib.sh).
#   2. With --doorbell, reads `launchctl print gui/<uid>/<label>` and logs
#      "detector: doorbell down: <label>" on stderr when that job is not
#      running, since an escalation row is silent without the inbox poller.
#   3. While state/.forwarder-escalated exists, stops: no restart, no row. The
#      holder of main clears it after the captain replies.
#   4. Decides whether the forwarder is hung. Hung means either
#      state/.forwarder-beat and state/.last-watcher-beat are both older than
#      the watcher stall bound (fm_watcher_stall_bound, 900s at the default
#      poll) plus 60s, so 960s, or a
#      state/.watch-cycle-exits.log row whose arm_pid is the beat's arm_pid
#      ended over 60s after the beat was written. A cycle end under any other
#      arm pid, such as a hand-run arm, does not count. With no
#      state/.forwarder-beat, the home runs no forwarder: logged, nothing done.
#   5. When hung and state/.forwarder-restart-at is absent or over 3600s old:
#      runs `launchctl kickstart -k gui/<uid>/<forwarder-label>`, writes the
#      time (epoch seconds) to state/.forwarder-restart-at, and runs
#      <notify-command> [args...] "<row>" once.
#      When hung again within that hour: no restart; one escalate row, then
#      state/.forwarder-escalated is written. A failed escalate notify writes
#      no marker, so the next run retries it.
#
# It never drains or acknowledges the wake queue, reads or writes no main lock
# (state/.lock), and needs no secret. FM_HOME must be set explicitly.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p;}' "$0"
}

if [ -z "${FM_DETECTOR_UNDER_ALARM:-}" ]; then
  FM_DETECTOR_UNDER_ALARM=1 exec /usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV or die "exec: $!\n"' \
    "${FM_DETECTOR_ALARM_SECONDS:-120}" /bin/bash "$0" "$@"
fi

label=
doorbell=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --label) label=${2:-}; shift 2 || shift ;;
    --doorbell) doorbell=${2:-}; shift 2 || shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) echo "detector: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "${FM_HOME:-}" ]; then
  echo "detector: FM_HOME is not set; refusing to guess a firstmate home" >&2
  exit 2
fi
if [ ! -d "$FM_HOME" ]; then
  echo "detector: FM_HOME '$FM_HOME' is not a directory" >&2
  exit 2
fi
if [ -z "$label" ]; then
  echo "detector: --label <forwarder-label> is required" >&2
  exit 2
fi
if [ "$#" -eq 0 ]; then
  echo "detector: missing notify command after --" >&2
  exit 2
fi
export FM_HOME

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# The watcher stall bound (900s at the default poll) plus 60s margin.
HUNG_SECONDS=$(( $(fm_watcher_stall_bound) + 60 ))
CYCLE_SLACK_SECONDS=60
RESTART_WINDOW_SECONDS=3600
FORWARDER_BEAT="$STATE/.forwarder-beat"
WATCHER_BEAT="$STATE/.last-watcher-beat"
CYCLE_LOG="$STATE/.watch-cycle-exits.log"
RESTART_AT="$STATE/.forwarder-restart-at"
ESCALATED="$STATE/.forwarder-escalated"
DOMAIN="gui/$(id -u)"

log() { echo "detector: $*" >&2; }

notify_row() {  # <row-text> <notify-command> [args...]
  local row
  row=$(fm_detector_row "$1")
  shift
  "$@" "$row" </dev/null
}

mkdir -p "$STATE" 2>/dev/null
touch "$STATE/.detector-beat"

if [ -n "$doorbell" ]; then
  if ! launchctl print "$DOMAIN/$doorbell" 2>/dev/null | grep -q '^[[:space:]]*state = running$'; then
    log "doorbell down: $doorbell is not running; escalation rows will not reach the holder"
  fi
fi

if [ -e "$ESCALATED" ]; then
  log "escalated ($ESCALATED stands): no restart, no row"
  exit 0
fi

if [ ! -e "$FORWARDER_BEAT" ]; then
  log "no forwarder beat at $FORWARDER_BEAT; nothing to check"
  exit 0
fi

beat_mtime=$(fm_path_mtime "$FORWARDER_BEAT")
beat_age=$(fm_path_age "$FORWARDER_BEAT")
watcher_age=$(fm_path_age "$WATCHER_BEAT")
arm_pid=$(sed -n 's/^arm_pid=//p' "$FORWARDER_BEAT" 2>/dev/null | head -n 1)

why=
if [ "$beat_age" -gt "$HUNG_SECONDS" ] && [ "$watcher_age" -gt "$HUNG_SECONDS" ]; then
  why="forwarder beat ${beat_age}s and watcher beat ${watcher_age}s old, both over ${HUNG_SECONDS}s"
elif [ -n "$arm_pid" ] && [ -f "$CYCLE_LOG" ]; then
  ended=$(awk -F '\t' -v pid="arm_pid=$arm_pid" '
    $1 == pid { for (i = 2; i <= NF; i++) if ($i ~ /^ended_at=[0-9]+$/) { v = substr($i, 10); if (v + 0 > max + 0) max = v } }
    END { if (max != "") print max }
  ' "$CYCLE_LOG")
  if [ -n "$ended" ] && [ "$ended" -gt $(( beat_mtime + CYCLE_SLACK_SECONDS )) ]; then
    why="the forwarder's arm $arm_pid ended $(( ended - beat_mtime ))s after its beat with no re-arm"
  fi
fi

if [ -z "$why" ]; then
  exit 0
fi

restart_age=$(fm_path_age "$RESTART_AT")
if [ ! -e "$RESTART_AT" ] || [ "$restart_age" -gt "$RESTART_WINDOW_SECONDS" ]; then
  if launchctl kickstart -k "$DOMAIN/$label"; then
    result="restarted with launchctl kickstart -k $DOMAIN/$label"
  else
    result="launchctl kickstart -k $DOMAIN/$label failed (exit $?)"
  fi
  printf '%s\n' "$(date +%s)" > "$RESTART_AT.tmp" && mv -f "$RESTART_AT.tmp" "$RESTART_AT"
  log "forwarder hung ($why); $result"
  notify_row "forwarder hung ($why); $result" "$@" || log "notify command failed for the restart row"
  exit 0
fi

row="forwarder hung again ${restart_age}s after its last restart ($why); not restarted; escalate to the captain; clear $ESCALATED after the reply"
log "$row"
if notify_row "$row" "$@"; then
  : > "$ESCALATED"
else
  log "notify command failed for the escalate row; no marker written, retried next run"
fi
exit 0
