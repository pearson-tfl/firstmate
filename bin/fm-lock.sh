#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
#
# Line 1 of state/.lock is the owner: holder:<name>, written for a caller that
# sets FM_LOCK_HOLDER=<name>. Only a named holder acquires. An unnamed run of
# this script exits 1 and changes nothing; a legacy pid line left by an older
# build is refused while that pid is a live verified harness, and claimed once
# it is dead or not a harness. Readers that still need a pid on line 1 are
# inert under a named holder: task leases, the supervision host and
# bin/fm-supervision-handoff.sh (#5138); the Pi primary's park proof and the
# omp and Cursor primaries' extension and park proofs (#5137); the OpenCode primary's watch-arm
# ownership check (.opencode/plugins/fm-primary-watch-arm.js); and
# bin/fm-live-lab.sh's primary and mate checks.
#
# The trusted Claude session id (fm_session_lock_trusted_session_id in
# bin/fm-session-lock-lib.sh) is recorded beside the lock in
# state/.lock-session, a sidecar written only here and only under the claim
# lock: refreshed on every acquisition, removed when the acquiring session
# proves no trusted id, and left byte-identical when it already names that id.
#
# A named holder: with FM_LOCK_HOLDER=<name> set (letters, digits, dot,
# underscore, dash), acquisition claims line 1 as holder:<name> under the
# claim lock. A free, emptied or stale line 1, or this same name, is claimed
# and the sidecar is published or cleared as above; a live harness pid or
# another name is refused and nothing changes. The two-mains guard refuses
# every caller that is not the recorded holder with "main is held by <name>;
# read-only". A refusal because the prior session's startup sweep holds the
# claim lock exits 75: wait and retry rather than treating main as taken. A
# name never expires; only release clears it. Two runs under one name both
# pass.
#
# Usage: FM_LOCK_HOLDER=<name> fm-lock.sh
#                             acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0.
#                             A held lock is not proof the holder is consuming
#                             wakes. Machine-readable lock fields live on
#                             fm-inbox.sh ready, from the same inspect helper.
#        FM_LOCK_HOLDER=<name> fm-lock.sh release
#                             under the claim lock, remove state/.lock and
#                             state/.lock-session only when line 1 is
#                             holder:<name>; otherwise exit 1, changing nothing.
#
# After a verified acquisition (the re-check a named holder runs before each
# drain, spawn or merge), a home with config/detector-notify (one argument per
# line) gets one row through that command when the hung-forwarder detector's
# beat is stale (bin/fm-forwarder-detector-lib.sh). It never changes the exit.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
LOCK_SESSION="$STATE/.lock-session"

# Harness identity (FM_HARNESS_RE, holder liveness, trusted session id) is owned
# by the shared session-lock lib so the Claude Stop auto-arm applies the exact
# same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ "${1:-}" = "status" ]; then
  fm_session_lock_inspect "$STATE"
  case "$FM_LOCK_INSPECT_STATE" in
    free) echo "lock: free" ;;
    unreadable) echo "lock: unreadable" ;;
    held)
      if [ -n "$FM_LOCK_INSPECT_HOLDER" ]; then
        echo "lock: held by $FM_LOCK_INSPECT_HOLDER"
      else
        echo "lock: held by live harness pid $FM_LOCK_INSPECT_PID"
      fi
      ;;
    *) echo "lock: stale (pid $FM_LOCK_INSPECT_PID dead or not a harness)" ;;
  esac
  exit 0
fi

HOLDER_NAME=${FM_LOCK_HOLDER:-}
if [ -z "$HOLDER_NAME" ]; then
  if [ "${1:-}" = "release" ]; then
    echo "error: release needs FM_LOCK_HOLDER set to the holder's name; nothing released" >&2
  elif held=$(fm_session_lock_recorded_holder "$STATE"); then
    # The two-mains guard, read without the claim lock: nothing is written.
    echo "error: main is held by $held; read-only" >&2
  else
    echo "error: acquiring the session lock needs FM_LOCK_HOLDER set to this session's holder name; nothing changed; operate read-only until resolved" >&2
  fi
  exit 1
fi
RELEASE=0
[ "${1:-}" = "release" ] && RELEASE=1
case "$HOLDER_NAME" in
  *[!A-Za-z0-9._-]*)
    echo "error: FM_LOCK_HOLDER must be letters, digits, dot, underscore or dash; operate read-only until resolved" >&2
    exit 1
    ;;
esac
me="holder:$HOLDER_NAME"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
# PHASE 0: committed/none. 1: sidecar mutated, line 1 not written. 2: line 1 written, not verified.
# KIND 0: no backup. 1: restore $LOCK_SESSION_PREV. 2: sidecar was absent.
LOCK_SESSION_PHASE=0
LOCK_SESSION_KIND=0
LOCK_SESSION_PREV="$STATE/.lock-session.prev"
LOCK_LINE_PRE=
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
restore_uncommitted_lock_session() {
  case "$LOCK_SESSION_PHASE" in
    1)
      case "$LOCK_SESSION_KIND" in
        1) mv -f "$LOCK_SESSION_PREV" "$LOCK_SESSION" 2>/dev/null || true ;;
        2) rm -f "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || true ;;
      esac
      ;;
    2) rm -f "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || true ;;
  esac
  LOCK_SESSION_PHASE=0
  LOCK_SESSION_KIND=0
}
commit_lock_session() {
  LOCK_SESSION_PHASE=0
  LOCK_SESSION_KIND=0
  rm -f "$LOCK_SESSION_PREV" 2>/dev/null || true
}
on_lock_exit() {
  restore_uncommitted_lock_session
  [ -n "$LOCK_LINE_PRE" ] && rm -f "$LOCK_LINE_PRE"
  release_claim_lock
}
trap on_lock_exit EXIT
trap 'exit 1' HUP INT TERM

remember_lock_session() {
  [ "$LOCK_SESSION_PHASE" -eq 0 ] || return 0
  if [ -e "$LOCK_SESSION" ] || [ -L "$LOCK_SESSION" ]; then
    rm -f "$LOCK_SESSION_PREV" 2>/dev/null || true
    cp -P "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || return 1
    LOCK_SESSION_KIND=1
  else
    LOCK_SESSION_KIND=2
  fi
  LOCK_SESSION_PHASE=1
}

# Record the trusted session id beside the lock, or remove a sidecar that no
# trusted id backs. Called only while the claim lock is held. A sidecar already
# naming this id is left untouched, so a same-session confirmation keeps it
# byte-identical.
publish_lock_session() {
  local trusted recorded tmp
  if trusted=$(fm_session_lock_trusted_session_id); then
    if recorded=$(fm_session_lock_recorded_session_id "$STATE") && [ "$recorded" = "$trusted" ]; then
      return 0
    fi
    remember_lock_session || return 1
    tmp=$(mktemp "$STATE/.lock-session.XXXXXX" 2>/dev/null) || return 1
    if ! { printf '%s\n' "$trusted" > "$tmp" && mv -f "$tmp" "$LOCK_SESSION"; } 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null
      return 1
    fi
    return 0
  fi
  if [ -e "$LOCK_SESSION" ] || [ -L "$LOCK_SESSION" ]; then
    remember_lock_session || return 1
    rm -f "$LOCK_SESSION" 2>/dev/null || return 1
  fi
  return 0
}

publish_lock_session_or_die() {
  publish_lock_session && return 0
  echo "error: cannot record the session identity beside the lock; operate read-only until resolved" >&2
  exit 1
}

# Take the claim lock. When the prior session's bounded startup sweep holds it,
# refuse with exit 75 so that refusal reads as wait-and-retry rather than as
# another owner.
take_claim_lock() {
  local sweep_pid
  if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
    sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
    if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
      echo "error: the prior session's bounded startup sweep is finishing; wait and retry once it releases the fleet lock" >&2
      exit 75
    fi
    fm_lock_acquire_wait "$CLAIM_LOCK"
  fi
  CLAIM_LOCK_HELD=1
}

# The two-mains guard: a lock already held by a named holder refuses every
# caller that is not that holder. Read under the claim lock.
refuse_other_holder() {
  local held
  held=$(fm_session_lock_recorded_holder "$STATE") || return 0
  [ "$held" = "$HOLDER_NAME" ] && return 0
  echo "error: main is held by $held; read-only" >&2
  exit 1
}

# Under the claim lock: a free lock, a hand-cleared or stale line 1, or this
# holder's own name is claimed; another name or a legacy pid line naming a live
# harness is refused and nothing changes.
named_claim_check_or_refuse() {
  local recorded
  [ -e "$LOCK" ] || [ -L "$LOCK" ] || return 0
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  recorded=$(head -n 1 "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  refuse_other_holder
  [ "$recorded" = "$me" ] && return 0
  if fm_harness_pid_alive "$recorded"; then
    refuse_live_owner "$recorded"
  fi
  return 0
}

refuse_live_owner() {  # <recorded-pid>
  local recorded
  if recorded=$(fm_session_lock_recorded_session_id "$STATE"); then
    echo "error: another live firstmate session holds the lock (pid $1, session $recorded); operate read-only until resolved" >&2
  else
    echo "error: another live firstmate session holds the lock (pid $1); operate read-only until resolved" >&2
  fi
  exit 1
}

# Release, under the claim lock: only the named holder recorded on line 1 may
# clear the lock and its sidecar; anything else exits 1 and changes nothing.
if [ "$RELEASE" -eq 1 ]; then
  take_claim_lock
  if ! held=$(fm_session_lock_recorded_holder "$STATE") || [ "$held" != "$HOLDER_NAME" ]; then
    echo "error: the session lock is not held by $HOLDER_NAME; nothing released" >&2
    exit 1
  fi
  if ! rm -f "$LOCK_SESSION" 2>/dev/null || ! rm -f "$LOCK" 2>/dev/null; then
    echo "error: cannot clear the session lock; operate read-only until resolved" >&2
    exit 1
  fi
  release_claim_lock
  echo "lock released: holder $HOLDER_NAME"
  exit 0
fi

take_claim_lock
named_claim_check_or_refuse

# The sidecar goes first: this holder beside a previous session's id would let
# that session's resume own this lock. If the sidecar changes before line 1 is
# written, a failure restores the previous sidecar. If line 1 is written but
# not yet verified, a failure removes the sidecar. After line 1 verifies as
# this holder, a later signal leaves the published pair in place.
publish_lock_session_or_die
if [ -f "$LOCK" ]; then
  LOCK_LINE_PRE=$(mktemp "$STATE/.lock.pre.XXXXXX") || {
    echo "error: cannot write session lock; operate read-only until resolved" >&2
    exit 1
  }
  if ! cp "$LOCK" "$LOCK_LINE_PRE" 2>/dev/null; then
    echo "error: cannot write session lock; operate read-only until resolved" >&2
    exit 1
  fi
fi
LOCK_SESSION_PHASE=2
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  lock_unchanged=0
  if [ -n "$LOCK_LINE_PRE" ] && cmp -s "$LOCK_LINE_PRE" "$LOCK"; then
    lock_unchanged=1
  elif [ -z "$LOCK_LINE_PRE" ] && [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ]; then
    lock_unchanged=1
  fi
  if [ "$lock_unchanged" -eq 1 ]; then
    if [ "$LOCK_SESSION_KIND" -ne 0 ]; then
      LOCK_SESSION_PHASE=1
    else
      LOCK_SESSION_PHASE=0
    fi
  fi
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
commit_lock_session
release_claim_lock
echo "lock acquired: holder $HOLDER_NAME"
# The re-check also watches the hung-forwarder detector: one row per stale
# detector beat to the command in config/detector-notify, if the home has one.
# shellcheck source=bin/fm-forwarder-detector-lib.sh
. "$SCRIPT_DIR/fm-forwarder-detector-lib.sh"
if fm_detector_notify_load "$FM_HOME/config/detector-notify"; then
  fm_detector_beat_check "${FM_DETECTOR_NOTIFY[@]}"
fi
