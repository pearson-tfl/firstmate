#!/usr/bin/env bash
# fm-exhaust-switch.sh - move a seat off a login that has run out of usage,
# onto the best other login, on the same conversation.
#
# Usage:
#   fm-exhaust-switch.sh [check]   one pass over this home's local seats
#   fm-exhaust-switch.sh arm       run `check` on the watcher's check cycle
#   fm-exhaust-switch.sh arm --default   the same unless this home disarmed it
#                                  (bin/fm-bootstrap.sh runs this at every start)
#   fm-exhaust-switch.sh disarm    stop running it there and keep it off
#   fm-exhaust-switch.sh move <task-id> <login>   (internal: one detached move)
#   fm-exhaust-switch.sh --help
#
# docs/configuration.md "Exhausted-login switch" owns the operator contract;
# this header owns the mechanics.
#
# Detection reads each seat's own session file, never its screen:
#   omp     the file its spawn-written extension records
#           (bin/fm-omp-profile-lib.sh fm_omp_session_file). Exhausted when the
#           last assistant message ended in error with errorStatus 429 and a
#           retry-after-ms beyond FM_EXHAUST_MIN_WAIT_MS (default 300000, omp's
#           own retry.maxDelayMs default), so omp gave up retrying.
#   claude  ~/.claude/projects/*/<agent_session_id>.jsonl (the shared
#           transcript the `account` verb moves). Exhausted when the last
#           assistant entry is an API error message with error "rate_limit"
#           whose text is Claude Code's own usage stop ("You've hit your ...
#           limit", "You've reached your ... limit", "You're out of usage
#           credits"); its transient server throttle carries the same error tag
#           and is ignored.
# A seat is moved only once its busy state reads idle (bin/fm-busy-lib.sh), so
# a seat still retrying or working is left until a later cycle, and each error
# is acted on once (state/<id>.exhaust-switch keeps its key).
#
# The move records the login in the machine-wide exhausted-login record
# (bin/fm-worker-account-lib.sh), so no launch from any home picks it until its
# wait passes, then runs the existing control plane detached from the check,
# which the watcher bounds to FM_CHECK_TIMEOUT:
#   omp     bin/fm-control.sh <id> resume: the same session file on a profile
#           re-picked by usage (a pin yields while its login is exhausted).
#   claude  bin/fm-control.sh <id> account <num>: the identical conversation
#           on the cswap account fm_account_rules_pick ranks best.
# The launch owner appends the move to data/account-switches.log. Each start
# and each outcome prints one line, which the watcher turns into a wake.
# Remote secondmates and raw-command seats are skipped: the control plane
# cannot move them.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME
CHECK_ID=exhaust-switch
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
DISARMED="$STATE/$CHECK_ID.disarmed"
MIN_WAIT_MS=${FM_EXHAUST_MIN_WAIT_MS:-300000}
CONTROL_BIN="$SCRIPT_DIR/fm-control.sh"
# Test seam: an isolated suite may stand in for the control plane.
[ "${FM_TEST_SEAM:-}" != 1 ] || CONTROL_BIN=${FM_TEST_EXHAUST_CONTROL:-$CONTROL_BIN}
# Claude's stop names no wait; hold its login this long unless cswap shows a
# later reset. shortcut: a fixed fallback, read the stop's own reset text if
# five hours proves wrong in practice.
CLAUDE_HOLD_SECONDS=${FM_EXHAUST_CLAUDE_HOLD_SECONDS:-18000}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-omp-profile-lib.sh
. "$SCRIPT_DIR/fm-omp-profile-lib.sh"

usage() { sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p;}' "$0"; }

record_get() {  # <id> <key>
  [ -f "$STATE/$1.exhaust-switch" ] || return 0
  sed -n "s/^$2=//p" "$STATE/$1.exhaust-switch" | tail -n 1
}

record_set() {  # <id> <key=value>...
  local id=$1
  shift
  printf '%s\n' "$@" >> "$STATE/$id.exhaust-switch"
}

# omp_exhaustion <session-file>: "<error-key> <until-epoch>" for a long 429.
omp_exhaustion() {
  tail -n 400 "$1" | jq -c 'select(.type == "message" and .message.role == "assistant") | .message' 2>/dev/null \
    | jq -rs --argjson min "$MIN_WAIT_MS" '
      last // empty
      | select(.stopReason == "error" and .errorStatus == 429)
      | ((.errorMessage // "") | capture("retry-after-ms=(?<ms>[0-9]+)").ms | tonumber) as $ms
      | select($ms > $min)
      | "\(.timestamp) \(((.completedAt // .timestamp) + $ms) / 1000 | floor)"' 2>/dev/null
}

# claude_exhaustion <session-file>: "<error-key> <until-epoch>" for a usage stop.
# Claude also tags a transient server throttle "rate_limit" ("API Error: Server
# is temporarily limiting requests (not your usage limit)"); only its own
# usage-stop wording counts ("You've hit your session limit", "You've reached
# your Fable limit", "You're out of usage credits"), per the dated record in
# docs/verification/runtime-backends.md.
claude_exhaustion() {
  local key
  key=$(tail -n 400 "$1" | jq -rs '
    map(select(.type == "assistant")) | last // empty
    | select(.isApiErrorMessage == true and .error == "rate_limit")
    | select([.message.content[]? | select(.type == "text") | .text] | join("")
        | test("^You(\u0027ve| have) (hit|reached) your |^You\u0027re out of usage"))
    | .timestamp' 2>/dev/null)
  [ -n "$key" ] || return 0
  printf '%s %s\n' "$key" "$(( $(date +%s) + CLAUDE_HOLD_SECONDS ))"
}

claude_session_file() {  # <meta>
  local sid root
  sid=$(fm_meta_get "$1" agent_session_id)
  [ -n "$sid" ] || return 1
  root=$(fm_meta_get "$1" account_root)
  find "$HOME/.claude/projects" ${root:+"$root/projects"} -maxdepth 2 -name "$sid.jsonl" -type f 2>/dev/null \
    | head -n 1 | grep .
}

# claude_login <meta>: the seat's cswap account, else cswap's active login.
claude_login() {
  local account
  account=$(fm_meta_get "$1" account)
  case "$account" in
    cswap:*) printf '%s\n' "$account"; return 0 ;;
  esac
  fm_account_rules_list 2>/dev/null | jq -r 'first(.accounts[] | select(.active == true) | "cswap:\(.number)") // empty'
}

check_seat() {  # <meta>
  local meta=$1 id harness file found key until login verdict
  id=$(basename "$meta" .meta)
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || return 0
  harness=$(fm_meta_get "$meta" harness)
  case "$harness" in
    omp)
      file=$(fm_omp_session_file "$STATE" "$id") || return 0
      found=$(omp_exhaustion "$file")
      ;;
    claude)
      file=$(claude_session_file "$meta") || return 0
      found=$(claude_exhaustion "$file")
      ;;
    *) return 0 ;;
  esac
  [ -n "$found" ] || return 0
  key=${found%% *}
  until=${found#* }
  [ "$(record_get "$id" key)" != "$key" ] || return 0
  verdict=$(fm_busy_classify_meta "$meta" "$id" "$STATE")
  case "$verdict" in idle*) ;; *) return 0 ;; esac
  if [ "$harness" = omp ]; then
    login=$(fm_omp_profile_login "$(fm_meta_get "$meta" omp_profile)" "$(fm_account_rules_list 2>/dev/null)")
    [ -n "$(fm_meta_get "$meta" omp_profile)" ] || login=omp:default
  else
    login=$(claude_login "$meta")
    [ -n "$login" ] || { record_set "$id" "key=$key" "status=failed" "detail=no cswap account is known for this Claude seat" "reported=0"; return 0; }
  fi
  fm_login_exhausted_record "$login" "$until" "fm-exhaust-switch:$id" \
    || echo "warning: could not record $login as exhausted in $(fm_login_exhausted_file)" >&2
  : > "$STATE/$id.exhaust-switch"
  record_set "$id" "key=$key" "login=$login" "status=moving" "at=$(date +%s)" "reported=1"
  # Detached into its own process group so the watcher's check timeout cannot
  # cut a move off halfway; fm-control's own lock serialises it per task.
  perl -e 'setpgrp(0, 0); exec @ARGV' -- \
    "$SCRIPT_DIR/fm-exhaust-switch.sh" move "$id" "$login" \
    > "$STATE/$id.exhaust-switch.log" 2>&1 < /dev/null &
  printf 'exhaust-switch: %s ran out of usage on %s (wait until %s); moving it to another login on the same conversation\n' \
    "$id" "$login" "$(date -u -r "$until" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$until" +%Y-%m-%dT%H:%MZ)"
}

report_outcomes() {
  local f id status
  for f in "$STATE"/*.exhaust-switch; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .exhaust-switch)
    [ "$(record_get "$id" reported)" = 0 ] || continue
    status=$(record_get "$id" status)
    case "$status" in
      done) printf 'exhaust-switch: %s moved from %s to %s on the same conversation\n' "$id" "$(record_get "$id" login)" "$(record_get "$id" to)" ;;
      failed) printf 'exhaust-switch: %s could not be moved off %s: %s (log: %s)\n' "$id" "$(record_get "$id" login)" "$(record_get "$id" detail)" "$STATE/$id.exhaust-switch.log" ;;
      *) continue ;;
    esac
    record_set "$id" "reported=1"
  done
}

action_check() {
  local meta
  [ -d "$STATE" ] || return 0
  report_outcomes
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    check_seat "$meta"
  done
}

action_move() {  # <id> <login>
  local id=$1 login=$2 meta="$STATE/$1.meta" out rc target to project
  case "$(fm_meta_get "$meta" harness)" in
    omp)
      out=$("$CONTROL_BIN" "$id" resume \
        --note "Firstmate moved this seat to another login because $login ran out of usage; carry on with your task." 2>&1)
      rc=$?
      to="omp:$(fm_meta_get "$meta" omp_profile)"
      ;;
    claude)
      project=$(fm_worker_account_project "$(fm_meta_get "$meta" project)")
      if target=$(fm_account_rules_pick "$CONFIG" "$project" "${login#cswap:}" 2>&1); then
        out=$("$CONTROL_BIN" "$id" account "$target" 2>&1)
        rc=$?
        to="cswap:$target"
      else
        out=$target
        rc=1
      fi
      ;;
    *) out="unsupported harness"; rc=1 ;;
  esac
  printf '%s\n' "$out"
  if [ "$rc" -eq 0 ]; then
    record_set "$id" "status=done" "to=$to" "reported=0"
  else
    record_set "$id" "status=failed" "detail=$(printf '%s\n' "$out" | grep -m1 '^error:' | cut -c1-300)" "reported=0"
  fi
  return "$rc"
}

action_arm() {
  local home tmp
  if [ "${1:-}" = --default ]; then
    [ ! -e "$DISARMED" ] || return 0
  fi
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || { echo "error: cannot resolve FM_HOME $FM_HOME" >&2; return 1; }
  [ -d "$STATE" ] && [ ! -L "$STATE" ] && [ ! -L "$CHECK_SHIM" ] || { echo "error: $CHECK_SHIM is unsafe to write" >&2; return 1; }
  tmp=$(umask 077; mktemp "$STATE/.fm-exhaust-switch-check.XXXXXX") || return 1
  printf '%s\n' '#!/usr/bin/env bash' \
    '# Auto-generated by fm-exhaust-switch.sh - exhausted-login switch shim.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-exhaust-switch.sh") check" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    return 1
  fi
  # An unregistered shim makes the watcher raise an untrusted-check alarm.
  FM_HOME="$home" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null \
    || { rm -f -- "$CHECK_SHIM"; echo "error: could not register $CHECK_SHIM" >&2; return 1; }
  rm -f -- "$DISARMED"
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) action_check ;;
  move) [ "$#" -eq 3 ] || { usage >&2; exit 2; }; action_move "$2" "$3" ;;
  arm) action_arm "${2:-}" ;;
  disarm)
    : > "$DISARMED" && "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" \
      && printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
