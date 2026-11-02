#!/usr/bin/env bash
# Shared stale-detector-beat check for the hung-forwarder detector
# (bin/fm-forwarder-detector.sh), sourced by the wake forwarder loop
# (bin/fm-wake-forwarder.sh) and the named claim (bin/fm-lock.sh).
#
# Each detector run touches state/.detector-beat. A beat over
# FM_DETECTOR_BEAT_STALE_SECONDS (default 900) old means the detector job is
# not running or hung. fm_detector_beat_check then runs the notify command once
# with one row naming the home and the beat's age. It records that beat's mtime
# in state/.detector-stale-reported, so every caller together sends one row per
# stale beat, not one per call; a fresh detector run starts a new beat and a
# later stale episode gets its own row. A failed notify records nothing, so the
# next call retries. With no beat at all the home runs no detector and nothing
# is sent. The check never changes its caller's outcome: it always returns 0.
#
# Callers set STATE to the home's state directory and source bin/fm-wake-lib.sh
# (fm_path_mtime, fm_path_age) first.

# The one row prefix every detector row carries, naming the home.
fm_detector_row() {  # <text>
  printf 'firstmate forwarder detector in %s: %s\n' "${FM_HOME:-$STATE}" "$1"
}

fm_detector_beat_check() {  # <notify-command> [args...]
  local beat="$STATE/.detector-beat" reported="$STATE/.detector-stale-reported"
  local stale=${FM_DETECTOR_BEAT_STALE_SECONDS:-900} mtime age
  [ "$#" -gt 0 ] || return 0
  mtime=$(fm_path_mtime "$beat") || return 0
  [ -n "$mtime" ] || return 0
  age=$(fm_path_age "$beat")
  [ "$age" -gt "$stale" ] || return 0
  [ "$(cat "$reported" 2>/dev/null)" != "$mtime" ] || return 0
  if "$@" "$(fm_detector_row "detector beat is ${age}s old (over ${stale}s); the detector job is not running or is hung")" </dev/null; then
    printf '%s\n' "$mtime" > "$reported" 2>/dev/null || true
  else
    echo "detector-beat check: notify command failed; retried on the next check" >&2
  fi
  return 0
}

# Read a notify command from a file, one argument per line, into the array
# FM_DETECTOR_NOTIFY. Returns 1 when the file is absent or names no command.
fm_detector_notify_load() {  # <file>
  local line
  FM_DETECTOR_NOTIFY=()
  [ -f "$1" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && FM_DETECTOR_NOTIFY+=("$line")
  done < "$1"
  [ "${#FM_DETECTOR_NOTIFY[@]}" -gt 0 ]
}
