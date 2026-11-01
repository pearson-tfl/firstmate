#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
#
# Line 1 of state/.lock is the owning session's anchor pid, resolved by
# fm_session_lock_anchor_pid in bin/fm-session-lock-lib.sh: the harness (agent)
# process found by walking the shell's ancestry, which lives as long as the
# firstmate session - unlike the transient subshell PID of any one tool call,
# which is dead moments after it is written. For a Claude session that proves a
# trusted session id the anchor is CLAUDE_PID, the model-loop process, so a
# shared transient daemon or a front-end that outlives the session never keeps
# a dead session's lock alive. On Windows that pid is recorded tagged, and a
# /clear re-key under the same tagged pid refreshes the sidecar as it does on
# POSIX. Line 1 keeps its whole-line pid format because every other reader
# takes the first line as the pid.
#
# The trusted id itself is recorded beside the lock in state/.lock-session, a
# sidecar written only here and only under the claim lock: refreshed on every
# confirmed-own acquisition, including the early already-mine exit that waits
# for the claim lock, removed when the acquiring session proves no trusted id,
# and left byte-identical when it already names that id. A same-session
# confirmation keeps a live line 1 that is in this session's harness ancestry,
# because bin/fm-startup-network.sh compares that pid across its deferred
# sweeps; a dead recorded pid is reclaimed and rewritten to this session's
# anchor. A live line 1 outside the ancestry, owned only through the trusted
# id, is rewritten to the anchor under the claim lock and then the
# lease-command lock, and task leases recorded against the old pid move to the
# anchor in that same section (fm_lease_rekey_holder in bin/fm-lease-lib.sh),
# as does a Claude auto-arm rewake bound to the old pid, under
# state/.claude-autoarm.lock (fm_autoarm_rekey_session in bin/fm-wake-lib.sh).
# A later /clear re-key in the same process is then still proven by ancestry
# after the id changes, a held lease stays live, and the mid-turn guard still
# accepts that rewake. A lease or rewake that cannot be moved, including when
# the auto-arm lock stays busy past LEASE_LOCK_WAIT seconds, is reported as a
# warning and the re-anchor still completes. When the lease-command
# lock stays busy past LEASE_LOCK_WAIT seconds, the confirmation only refreshes
# the sidecar, as for a line 1 in the ancestry, and a later acquisition
# re-anchors.
#
# A named holder: with FM_LOCK_HOLDER=<name> set (letters, digits, dot,
# underscore, dash), acquisition skips the ancestry anchor and claims line 1 as
# holder:<name> under the claim lock. A free, emptied or stale line 1, or this
# same name, is claimed and the sidecar is published or cleared as above; a
# live harness pid or another name is refused and nothing changes. The
# two-mains guard refuses every caller that is not the recorded holder, named
# or not, with "main is held by <name>; read-only". On the named path, a
# refusal because the prior session's startup sweep holds the claim lock exits
# 75: wait and retry rather than treating main as taken. A name never expires;
# only release clears it. Two runs under one name both pass.
#
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0.
#                             A held lock is not proof the holder is consuming
#                             wakes. Machine-readable lock fields live on
#                             fm-inbox.sh ready, from the same inspect helper.
#        FM_LOCK_HOLDER=<name> fm-lock.sh release
#                             under the claim lock, remove state/.lock and
#                             state/.lock-session only when line 1 is
#                             holder:<name>; otherwise exit 1, changing nothing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
LOCK_SESSION="$STATE/.lock-session"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness, trusted
# session id, anchor pid) is owned by the shared session-lock lib so the Claude
# Stop auto-arm applies the exact same identity contract.
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

# A named holder (FM_LOCK_HOLDER) claims through its own path below and never
# resolves an ancestry anchor; only an unnamed caller does.
HOLDER_NAME=${FM_LOCK_HOLDER:-}
RELEASE=0
if [ "${1:-}" = "release" ]; then
  RELEASE=1
  if [ -z "$HOLDER_NAME" ]; then
    echo "error: release needs FM_LOCK_HOLDER set to the holder's name; nothing released" >&2
    exit 1
  fi
fi
if [ -n "$HOLDER_NAME" ]; then
  case "$HOLDER_NAME" in
    *[!A-Za-z0-9._-]*)
      echo "error: FM_LOCK_HOLDER must be letters, digits, dot, underscore or dash; operate read-only until resolved" >&2
      exit 1
      ;;
  esac
  me="holder:$HOLDER_NAME"
else
  me=$(fm_session_lock_anchor_pid) || {
    if fm_win_boundary_applies; then
      # Here the parent link does not reach the harness at all, so "not in the
      # ancestry" would describe the wrong problem and send the reader hunting a
      # process tree that can never contain the answer.
      echo "error: cannot identify this harness session on Windows: it publishes no session pid this build recognizes (see FM_WIN_HARNESS_PID_VARS in bin/fm-session-lock-lib.sh; CLAUDE_PID is taken only together with CLAUDE_CODE_SESSION_ID); operate read-only until resolved" >&2
    else
      echo "error: cannot locate harness process in ancestry" >&2
    fi
    exit 1
  }
fi
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
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
LEASE_LOCK="$STATE/.fm-lease-command.lock"
LEASE_LOCK_HELD=0
LEASE_LOCK_WAIT=5
AUTOARM_LOCK="$STATE/.claude-autoarm.lock"
AUTOARM_LOCK_HELD=0
# The live line-1 pid a same-session confirmation is moving off, or empty.
REANCHOR=
# PHASE 0: committed/none. 1: sidecar mutated, line 1 not written. 2: line 1 written, not verified.
# KIND 0: no backup. 1: restore $LOCK_SESSION_PREV. 2: sidecar was absent.
LOCK_SESSION_PHASE=0
LOCK_SESSION_KIND=0
LOCK_SESSION_PREV="$STATE/.lock-session.prev"
LOCK_LINE_PRE=
release_autoarm_lock() {
  if [ "$AUTOARM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$AUTOARM_LOCK"
    AUTOARM_LOCK_HELD=0
  fi
}
release_lease_lock() {
  if [ "$LEASE_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$LEASE_LOCK"
    LEASE_LOCK_HELD=0
  fi
}
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
  release_autoarm_lock
  release_lease_lock
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

# This session already holds the lock, recorded as pid $1. Line 1 stays exactly
# as recorded while that pid is alive and in this session's ancestry; only the
# sidecar is refreshed, under the claim lock, so a /clear re-key inside the same
# process replaces the old id. A live line 1 outside the ancestry is re-anchored
# as the header describes: REANCHOR records it and the caller keeps both locks
# for the guarded write below.
# A same-session confirmation waits for the claim lock so the sidecar refresh
# completes. After the wait, the lock is re-read and the sidecar is refreshed
# only when this session still owns it; otherwise the claim lock is released
# and the caller continues with the ordinary live-owner or reclaim path. The
# prior-session-sweep-is-finishing refusal is a takeover rule and does not
# apply here.
confirm_own_lock() {  # <recorded-pid>
  local recorded pids waited=0
  if [ "$CLAIM_LOCK_HELD" -ne 1 ]; then
    fm_lock_acquire_wait "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=1
    waited=1
  fi
  recorded=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$recorded" = "$me" ] || fm_session_lock_owned_by_self "$STATE"; then
    if [ "$recorded" != "$me" ] && pids=$(fm_harness_ancestry_pids) \
      && ! fm_harness_pid_listed "$recorded" "$pids" \
      && fm_lock_acquire_wait_max "$LEASE_LOCK" "$LEASE_LOCK_WAIT"; then
      LEASE_LOCK_HELD=1
      REANCHOR=$recorded
      return 0
    fi
    publish_lock_session_or_die
    commit_lock_session
    release_claim_lock
    echo "lock acquired: harness pid $recorded"
    exit 0
  fi
  if [ "$waited" -eq 1 ]; then
    release_claim_lock
  fi
  return 1
}

# Take the claim lock. When the prior session's bounded startup sweep holds it,
# refuse with exit <rc>; the named path passes SWEEP_RETRY_RC so that refusal
# reads as wait-and-retry rather than as another owner.
SWEEP_RETRY_RC=75
take_claim_lock() {  # <sweep-refusal-rc>
  local sweep_pid
  if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
    sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
    if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
      if [ "$1" -eq "$SWEEP_RETRY_RC" ]; then
        echo "error: the prior session's bounded startup sweep is finishing; wait and retry once it releases the fleet lock" >&2
      else
        echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
      fi
      exit "$1"
    fi
    fm_lock_acquire_wait "$CLAIM_LOCK"
  fi
  CLAIM_LOCK_HELD=1
}

# The two-mains guard: a lock already held by a named holder refuses every
# caller that is not that holder. Read under the claim lock by the named path
# and before each live-owner check on the unnamed path.
refuse_other_holder() {
  local held
  held=$(fm_session_lock_recorded_holder "$STATE") || return 0
  [ -n "$HOLDER_NAME" ] && [ "$held" = "$HOLDER_NAME" ] && return 0
  echo "error: main is held by $held; read-only" >&2
  exit 1
}

# Named path, under the claim lock: a free lock, a hand-cleared or stale line 1,
# or this holder's own name is claimed; another name or a live harness pid is
# refused and nothing changes.
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
  take_claim_lock "$SWEEP_RETRY_RC"
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

if [ -z "$HOLDER_NAME" ] && [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  refuse_other_holder
  old=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$old" = "$me" ] || fm_session_lock_owned_by_self "$STATE"; then
    confirm_own_lock "$old"
    old=$(cat "$LOCK" 2>/dev/null || true)
  fi
  if [ -z "$REANCHOR" ] && fm_harness_pid_alive "$old"; then
    refuse_live_owner "$old"
  fi
fi

if [ -z "$HOLDER_NAME" ]; then
  if [ "$CLAIM_LOCK_HELD" -ne 1 ]; then
    take_claim_lock 1
  fi
else
  take_claim_lock "$SWEEP_RETRY_RC"
  named_claim_check_or_refuse
fi

if [ -z "$HOLDER_NAME" ] && { [ -e "$LOCK" ] || [ -L "$LOCK" ]; }; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  refuse_other_holder
  # A re-anchor decided above has held the claim lock since, so line 1 is the
  # pid it recorded and needs no second verdict.
  if [ -z "$REANCHOR" ] && [ "$old" != "$me" ] && fm_harness_pid_alive "$old"; then
    fm_session_lock_owned_by_self "$STATE" && confirm_own_lock "$old"
    old=$(cat "$LOCK" 2>/dev/null || true)
    if [ -z "$REANCHOR" ] && [ "$old" != "$me" ] && fm_harness_pid_alive "$old"; then
      refuse_live_owner "$old"
    fi
  fi
fi
# The sidecar goes first: a fresh pid beside a previous session's id would let
# that session's resume own this lock. If the sidecar changes before line 1 is
# written, a failure restores the previous sidecar. If line 1 is written but
# not yet verified, a failure removes the sidecar and leaves the lock
# ancestry-only. After line 1 verifies as this session's anchor, a later
# signal leaves the published pair in place, except on the re-anchor path:
# there a HUP, INT, or TERM during the lease move or the bounded
# .claude-autoarm.lock wait, before commit_lock_session, still runs
# restore_uncommitted_lock_session with phase 2 and removes the sidecar.
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
if [ -n "$REANCHOR" ] && ! fm_lease_rekey_holder "$REANCHOR" "$me"; then
  echo "warning: a task lease recorded against pid $REANCHOR could not be moved to pid $me, so it reads as stale" >&2
fi
if [ -n "$REANCHOR" ] && fm_autoarm_ledger_read "$STATE" && [ "$FM_AUTOARM_SESSION" = "$REANCHOR" ]; then
  if fm_lock_acquire_wait_max "$AUTOARM_LOCK" "$LEASE_LOCK_WAIT"; then
    AUTOARM_LOCK_HELD=1
  fi
  if [ "$AUTOARM_LOCK_HELD" -ne 1 ] || ! fm_autoarm_rekey_session "$STATE" "$REANCHOR" "$me"; then
    echo "warning: the Claude auto-arm rewake recorded against pid $REANCHOR could not be moved to pid $me, so a mid-turn guard can report supervision off until the next Stop" >&2
  fi
  release_autoarm_lock
fi
commit_lock_session
release_lease_lock
release_claim_lock
if [ -n "$HOLDER_NAME" ]; then
  echo "lock acquired: holder $HOLDER_NAME"
else
  echo "lock acquired: harness pid $me"
fi
