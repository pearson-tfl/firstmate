#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process or named holder holds this
# home's session lock, and does the current process belong to it?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock and its
# state/.lock-session sidecar; bin/fm-claude-stop-autoarm.sh and the turn-end
# guards use it to prove a hook fires inside the lock-owning primary session.
# Only a named holder (holder:<name> on line 1) is ever owned, and only by the
# process whose FM_LOCK_HOLDER carries that name; a legacy pid line is never
# owned, and while its pid is a live harness it is a foreign owner.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
_FM_SESSION_LOCK_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_SESSION_LOCK_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_SESSION_LOCK_LIB_DIR=.
# shellcheck source=bin/fm-cursor-lib.sh
. "${_FM_SESSION_LOCK_LIB_DIR:-/}/fm-cursor-lib.sh"
unset _FM_SESSION_LOCK_LIB_DIR

# Known harness command names; extend when a new adapter is verified. omp and
# agy are anchored exactly like pi: their process names are the bare words `omp`
# (verified, omp 18.1.11) and `agy`, and a substring match would claim ompd or
# comp.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$|^omp$|^agy$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi omp agy)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# Portable single-pid process introspection.
#
# procps/BSD `ps -o comm=/args=` custom-format columns are the primary
# path and cover Linux and macOS. Cygwin's ps, which Git for Windows ships, has
# no -o option at all and exits with "unknown option -- o", so the primary path
# fails outright there and every harness check would fail. The
# fallbacks parse Cygwin's fixed columns instead:
#   ps -p PID     PID PPID PGID WINPID TTY UID STIME COMMAND   (executable path)
#   ps -f -p PID  UID PID PPID TTY STIME COMMAND               (full argv)
# A genuinely dead or inaccessible pid still fails both paths, so this widens
# nothing: it only stops a supported platform from failing on ps syntax alone.
fm_ps_comm() {  # <pid> -> executable name or path
  local pid=$1 out
  out=$(ps -o comm= -p "$pid" 2>/dev/null) && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  out=$(ps -p "$pid" 2>/dev/null | awk 'NR == 2 { for (i = 8; i <= NF; i++) printf "%s%s", (i > 8 ? " " : ""), $i; exit }')
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

fm_ps_args() {  # <pid> -> full command line
  local pid=$1 out
  out=$(ps -o args= -p "$pid" 2>/dev/null) && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  out=$(ps -f -p "$pid" 2>/dev/null | awk 'NR == 2 { for (i = 6; i <= NF; i++) printf "%s%s", (i > 6 ? " " : ""), $i; exit }')
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the trusted-id check.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a live Cursor pid would never
  # read as a harness.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}

# --- Windows process-boundary bridge -----------------------------------------
#
# On Cygwin (Git for Windows) the harness is a native Windows process, and the
# parent link from a shell it spawns does NOT cross the Cygwin boundary: Cygwin
# reports that shell's PPID as 1, and its pid is not in the Cygwin process table.
# `ps -W` lists Windows processes keyed by WINPID, so liveness and identity of a
# Windows pid are answered from there instead.
#
# Windows pids live in a DIFFERENT namespace from Cygwin pids: `kill -0` on a
# Windows pid reports "No such process" even while that process is running, and a
# Windows pid can collide with an unrelated live Cygwin pid. A bare number is
# therefore ambiguous and unsafe to store. Every pid resolved through this bridge
# is tagged, which makes the namespace explicit for readers and makes the value
# non-numeric so that any consumer treating it as a Cygwin pid - including a
# future `kill` - refuses it instead of acting on the wrong process.
FM_WIN_PID_PREFIX='win:'

# True on a Cygwin-family userspace, where the boundary above applies.
fm_win_boundary_applies() {
  case "$(uname -s 2>/dev/null)" in
    CYGWIN*|MINGW*|MSYS*) return 0 ;;
  esac
  return 1
}

# Strip the namespace tag from $1, or return 1 when $1 is not a tagged pid.
# The tag is only meaningful where the boundary applies; anywhere else it is
# rejected exactly like any other non-numeric lock value.
fm_win_untag_pid() {  # <pid>
  local winpid
  case "$1" in
    "$FM_WIN_PID_PREFIX"*) winpid=${1#"$FM_WIN_PID_PREFIX"} ;;
    *) return 1 ;;
  esac
  case "$winpid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_win_boundary_applies || return 1
  printf '%s' "$winpid"
}

# True when $1 is a well-formed session-lock identity: a local pid, or a tagged
# Windows pid. Every reader of state/.lock decides "is this value usable at all"
# through this one predicate, because the readers are spread across several
# scripts and a private numeric test in any one of them silently rejects a valid
# holder - which reads as "startup never completed" and repeats the whole
# sequence on every clear or compact.
fm_session_pid_valid() {  # <value>
  fm_win_untag_pid "$1" >/dev/null && return 0
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# True when $1 is a well-formed state/.lock line 1 identity: a session pid that
# fm_session_pid_valid accepts, or a named holder, holder:<name>, in the name
# charset bin/fm-lock.sh accepts. The string compares that ask "does the lock
# still name the session that asked for this work?" - the startup sweep's
# re-check, bootstrap's clone refresh, and the session-start completion marker -
# take either. fm_session_pid_valid itself still rejects a name, because its
# other readers kill -0 the value as a pid.
fm_session_lock_identity_valid() {  # <value>
  fm_session_pid_valid "$1" && return 0
  case "$1" in
    holder:|holder:*[!A-Za-z0-9._-]*) return 1 ;;
    holder:*) return 0 ;;
  esac
  return 1
}

# Windows command paths are backslash-separated and .exe-suffixed, neither of
# which the path-component matcher above understands. Normalizing here is what
# keeps that matcher's whole-component safety intact: without it the harness
# regex would fall back to matching the entire unsplit path, so an unrelated
# C:\claude-notes\tool.exe would read as a harness process.
fm_win_normalize_command() {  # <windows path>
  local path=${1//\\//}
  printf '%s' "${path%.exe}"
}

# Print the normalized executable path of live Windows process $1, or return 1.
# Presence in `ps -W` is also this bridge's liveness test, because kill -0 cannot
# answer that question across the namespace boundary.
fm_win_command() {  # <winpid>
  local winpid=$1 table out
  case "$winpid" in
    ''|*[!0-9]*) return 2 ;;
  esac
  # Return 1 only when a readable table proves the pid absent, and 2 when the
  # table itself could not be read, so a caller can tell gone from unknown.
  table=$(ps -W 2>/dev/null) || return 2
  case "$table" in
    *WINPID*) ;;
    *) return 2 ;;
  esac
  out=$(printf '%s\n' "$table" | awk -v w="$winpid" '$4 == w { for (i = 8; i <= NF; i++) printf "%s%s", (i > 8 ? " " : ""), $i; exit }')
  [ -n "$out" ] || return 1
  fm_win_normalize_command "$out"
}

# True if $1 is a live process that looks like a verified harness.
# A tagged Windows pid is answered from the Windows process table, because
# kill -0 cannot see across that boundary and would report a live harness as
# dead - which would hand a running session's home to a second one.
fm_harness_pid_alive() {
  local pid=$1 comm args winpid
  if winpid=$(fm_win_untag_pid "$pid"); then
    comm=$(fm_win_command "$winpid") || return 1
    fm_harness_process_matches "$comm" "$comm"
    return
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(fm_ps_comm "$pid") || return 1
  args=$(fm_ps_args "$pid")
  fm_harness_process_matches "$comm" "$args"
}

# Liveness and identity of a session-lock pid for readers outside this file:
# the supervision host's main-session key and the Claude auto-arm. A tagged
# Windows pid is answered from the Windows process table, as above; any other
# value goes to the generic fm_pid_alive and fm_pid_identity in
# bin/fm-wake-lib.sh, which those readers already have sourced.
fm_session_pid_alive() {  # <value>
  local winpid
  if winpid=$(fm_win_untag_pid "$1"); then
    fm_win_command "$winpid" >/dev/null
    return
  fi
  fm_pid_alive "$1"
}

# A tagged pid's identity is its Windows pid and executable path rather than a
# start time. Every reader pairs it with the session sidecar id, which a new
# session always changes, so a reused Windows pid still reads as a different
# session.
fm_session_pid_identity() {  # <value>
  local winpid comm
  if winpid=$(fm_win_untag_pid "$1"); then
    comm=$(fm_win_command "$winpid") || return 1
    printf 'win-pid=%s command=%s\n' "$winpid" "$comm"
    return 0
  fi
  fm_pid_identity "$1"
}

# --- trusted session identity ----------------------------------------------
# Claude Code hands every hook and tool shell CLAUDE_CODE_SESSION_ID (the
# session's conversation id) and CLAUDE_PID (the pid of the process running the
# model loop). bin/fm-lock.sh records that id beside a named holder's lock in
# state/.lock-session, and the Claude auto-arm keys its rewake on it.
#
# Trust gate: CLAUDE_PID must be a live verified Claude harness. An id retained
# in an environment whose Claude process has exited is ignored. On Windows the
# pid is answered in its tagged form from the Windows process table, because
# kill -0 cannot see across that boundary. Ids are read from the environment
# only, never from ps argv, where prompts and briefs are visible.

# Print the Claude session id this process may record, or return 1.
fm_session_lock_trusted_session_id() {
  local id=${CLAUDE_CODE_SESSION_ID:-} claude_pid=${CLAUDE_PID:-}
  [ -n "$id" ] || return 1
  case "$id" in *$'\n'*|*$'\r'*) return 1 ;; esac
  case "$claude_pid" in ''|*[!0-9]*) return 1 ;; esac
  if fm_win_boundary_applies; then
    claude_pid=$FM_WIN_PID_PREFIX$claude_pid
  fi
  fm_harness_pid_alive "$claude_pid" || return 1
  [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || return 1
  printf '%s\n' "$id"
}

# Print the session id recorded beside the lock in state dir $1, or return 1.
# bin/fm-lock.sh is the only writer of state/.lock-session; a missing,
# symlinked, unreadable, or empty sidecar, or one whose first line contains a
# newline or carriage return, is simply no recorded id.
fm_session_lock_recorded_session_id() {  # <state>
  local state=$1 recorded
  [ -f "$state/.lock-session" ] && [ ! -L "$state/.lock-session" ] || return 1
  recorded=$(head -n 1 "$state/.lock-session" 2>/dev/null) || return 1
  [ -n "$recorded" ] || return 1
  case "$recorded" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$recorded"
}

# Print the named holder recorded in state dir $1, or return 1. A named holder
# is line 1 of state/.lock reading holder:<name>, written by bin/fm-lock.sh for
# a caller that sets FM_LOCK_HOLDER. Only line 1 is read; a missing, symlinked
# or unreadable lock, a pid line, or an empty name is no named holder.
fm_session_lock_recorded_holder() {  # <state>
  local state=$1 line
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  line=$(head -n 1 "$state/.lock" 2>/dev/null) || return 1
  case "$line" in
    holder:?*) printf '%s\n' "${line#holder:}" ;;
    *) return 1 ;;
  esac
}

# True when state dir $1 holds a session lock that this process's session owns:
# a named holder equal to this process's FM_LOCK_HOLDER. A pid line, a missing
# or malformed lock, another name, or no FM_LOCK_HOLDER is never owned, because
# only a named holder can acquire.
fm_session_lock_owned_by_self() {
  local holder
  holder=$(fm_session_lock_recorded_holder "$1") || return 1
  [ -n "${FM_LOCK_HOLDER:-}" ] && [ "$holder" = "$FM_LOCK_HOLDER" ]
}

# True when state dir $1 records a named holder other than this process's
# FM_LOCK_HOLDER, or a legacy pid line naming a live verified harness, which no
# session can prove is its own. Sets FM_SESSION_LOCK_FOREIGN_OWNER_PID for a
# diagnostic caller (the holder name for a named holder), and
# FM_SESSION_LOCK_FOREIGN_OWNER_HOLDER to that name, empty for a pid owner.
# Malformed, missing and dead locks are not foreign-owner evidence.
# shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
FM_SESSION_LOCK_FOREIGN_OWNER_PID=
# shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
FM_SESSION_LOCK_FOREIGN_OWNER_HOLDER=
fm_session_lock_foreign_owner_live() {
  local state=$1 lock_pid holder
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=
  FM_SESSION_LOCK_FOREIGN_OWNER_HOLDER=
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  if holder=$(fm_session_lock_recorded_holder "$state"); then
    [ -n "${FM_LOCK_HOLDER:-}" ] && [ "$holder" = "$FM_LOCK_HOLDER" ] && return 1
    # shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
    FM_SESSION_LOCK_FOREIGN_OWNER_PID=$holder
    # shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
    FM_SESSION_LOCK_FOREIGN_OWNER_HOLDER=$holder
    return 0
  fi
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  fm_session_pid_valid "$lock_pid" || return 1
  fm_harness_pid_alive "$lock_pid" || return 1
  # shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=$lock_pid
  return 0
}

# Read-only classification of state/.lock for machine-readable callers.
# Never acquires the lock. A held lock is not proof the holder is consuming
# wakes; that question belongs to the inbox readiness projection.
#
# Sets:
#   FM_LOCK_INSPECT_STATE         free|held|stale|unreadable|unknown
#   FM_LOCK_INSPECT_PID           recorded pid, or empty
#   FM_LOCK_INSPECT_LIVE_HARNESS  true|false|unknown
#   FM_LOCK_INSPECT_HOLDER        named holder, or empty
#
# held: the recorded pid is a live verified harness, or line 1 names a holder
# (holder:<name>); a named holder has no pid and its liveness is unknown, since
# a name never expires.
# stale: the recorded pid is gone.
# unknown: the file or pid cannot be classified without guessing, including a
# live process that is not a verified harness. Existence of a lock file, a
# session record, or a pane is never treated as liveness.
# shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
FM_LOCK_INSPECT_STATE=unknown
FM_LOCK_INSPECT_PID=
FM_LOCK_INSPECT_LIVE_HARNESS=unknown
FM_LOCK_INSPECT_HOLDER=
fm_session_lock_inspect() {  # <state>
  local state=$1 lock pid winpid win_rc
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_HOLDER=
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_STATE=unknown
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_LIVE_HARNESS=unknown
  lock="$state/.lock"
  if [ ! -e "$lock" ]; then
    FM_LOCK_INSPECT_STATE=free
    FM_LOCK_INSPECT_LIVE_HARNESS=false
    return 0
  fi
  if [ ! -f "$lock" ] || [ -L "$lock" ]; then
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  fi
  pid=$(cat "$lock" 2>/dev/null) || {
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  }
  pid=${pid%%$'\n'*}
  case "$pid" in
    holder:?*)
      # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
      FM_LOCK_INSPECT_STATE=held
      # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
      FM_LOCK_INSPECT_HOLDER=${pid#holder:}
      return 0
      ;;
  esac
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=$pid
  fm_session_pid_valid "$pid" || return 0
  if winpid=$(fm_win_untag_pid "$pid"); then
    # The same verdicts as a local pid below, read from the Windows table.
    if fm_harness_pid_alive "$pid"; then
      FM_LOCK_INSPECT_STATE=held
      FM_LOCK_INSPECT_LIVE_HARNESS=true
      return 0
    fi
    win_rc=0
    fm_win_command "$winpid" >/dev/null || win_rc=$?
    case "$win_rc" in
      0) FM_LOCK_INSPECT_LIVE_HARNESS=false ;;
      1)
        FM_LOCK_INSPECT_STATE=stale
        FM_LOCK_INSPECT_LIVE_HARNESS=false
        ;;
    esac
    return 0
  fi
  if kill -0 "$pid" 2>/dev/null; then
    if fm_harness_pid_alive "$pid"; then
      FM_LOCK_INSPECT_STATE=held
      FM_LOCK_INSPECT_LIVE_HARNESS=true
    else
      FM_LOCK_INSPECT_STATE=unknown
      FM_LOCK_INSPECT_LIVE_HARNESS=false
    fi
    return 0
  fi
  if ps -o comm= -p "$pid" >/dev/null 2>&1; then
    FM_LOCK_INSPECT_STATE=unknown
    return 0
  fi
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_STATE=stale
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_LIVE_HARNESS=false
}
