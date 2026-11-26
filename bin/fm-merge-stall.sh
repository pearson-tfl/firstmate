#!/usr/bin/env bash
# fm-merge-stall.sh - make a home land a PR it may merge without asking, or
# surface the stall, while that PR's worker waits on the home.
#
# Usage:
#   fm-merge-stall.sh scan [--now <epoch>]
#
# The watcher runs `scan` on every check sweep (FM_CHECK_INTERVAL) in every
# home - main, local secondmates, and remote secondmates alike - so the lever
# never depends on the supervising model remembering a PR. It exists because a
# worker that reports its PR in prose and then declares a `paused:` wait on its
# home is a declared wait: supervision absorbs it, the PR-ready landing path
# keys only off a `done:` line, and the merge poll reports only a merge, so a
# PR the home could merge sat unmerged with nobody told.
#
# A task is a merge-stall candidate when all of these hold:
#   - its meta records kind=ship, yolo=on (the home merges its green PRs
#     without asking), and a pr= URL or an open PR on its recorded branch;
#   - no matching merge-notification marker or forge result confirms it ended;
#   - its worker waits on the home: the declared wait is a `paused:` line, or
#     the newest status event is `done:`, with current activity reconciled
#     by bin/fm-crew-state.sh before either declaration is accepted;
#   - bin/fm-captain-hold.sh open confirms no captain call is open on it;
#     a held answer suppresses merge reminders; an unreadable answer wakes the home
#     to repair the authorization read without instructing it to merge.
# A candidate's stall starts at its waiting line's [at=] time, or when first
# seen, and is kept across scans and watcher restarts in state/.merge-stall
# (<task> TAB <url> TAB <since> TAB <last-wake> TAB <escalated> TAB <episode>).
#
# Once a stall is FM_MERGE_STALL_SECS old (default 600), scan prints one line
# for the watcher to wake the home with, directing it to merge through
# bin/fm-pr-merge.sh, which stays the only merge path and the only judge of
# green; that line repeats every FM_MERGE_STALL_SECS until the PR merges or
# the worker stops waiting. On GitHub the line carries bin/fm-pr-state.sh's
# blockers, so a red or conflicting PR says why it cannot land; a PR that
# reads merged or closed there ends the stall instead.
# Once a stall is FM_MERGE_STALL_ESCALATE_SECS old (default 1800, never below
# FM_MERGE_STALL_SECS) it is escalated to the captain once per stall: a main
# home's line tells it to tell the captain, and a secondmate home also appends
#   blocked [key=merge-stall-<task>-<fp8>]: merge stall <task>: ...
# to its parent channel (bin/fm-parent-channel-lib.sh), which is resolved by a
# matching `resolved` line when the stall ends. After escalation the line
# repeats every FM_MERGE_STALL_ESCALATE_SECS instead.
# Unregistered-PR discovery is GitHub-only; non-GitHub PRs are skipped there.
# One line per scan, for the least recently notified due stall, oldest first
# among ties; terminal PRs never consume that slot.
#
# Nothing here merges, comments, or changes a PR. Unreadable task evidence
# retains that task's previous episodes and adds a diagnostic to the wake.
# External reads have FM_MERGE_STALL_READ_TIMEOUT seconds (default 5).
# Exit 0 on a completed scan, 2 on usage or settings errors, 1 on a ledger or
# parent-channel failure. The ledger is checkpointed before parent publication.
set -u
export LC_ALL=C
CANCELLED=0
trap 'CANCELLED=1' HUP INT TERM

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LEDGER="$STATE/.merge-stall"
PR_STATE_BIN="${FM_MERGE_STALL_PR_STATE_BIN:-$SCRIPT_DIR/fm-pr-state.sh}"
CAPTAIN_HOLD_BIN="${FM_MERGE_STALL_CAPTAIN_HOLD_BIN:-$SCRIPT_DIR/fm-captain-hold.sh}"
CREW_STATE_BIN="${FM_MERGE_STALL_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() { sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0"; }
die() { printf 'fm-merge-stall: %s\n' "$*" >&2; exit 2; }
scan_active() { [ "$CANCELLED" = 0 ] || exit 143; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  scan) shift ;;
  *) usage >&2; exit 2 ;;
esac
NOW=
case "$#:${1:-}" in
  0:) ;;
  2:--now) NOW=$2 ;;
  *) die "usage: fm-merge-stall.sh scan [--now <epoch>]" ;;
esac
[ -n "$NOW" ] || NOW=$(date +%s)
STALL=${FM_MERGE_STALL_SECS:-600}
ESCALATE=${FM_MERGE_STALL_ESCALATE_SECS:-1800}
READ_TIMEOUT=${FM_MERGE_STALL_READ_TIMEOUT:-5}
for value in "$NOW" "$STALL" "$ESCALATE" "$READ_TIMEOUT"; do
  case "$value" in ''|0*|*[!0-9]*) die "times must be positive whole seconds" ;; esac
  [ "${#value}" -le 12 ] || die "times must be positive whole seconds"
done
[ "$ESCALATE" -ge "$STALL" ] || die "FM_MERGE_STALL_ESCALATE_SECS is below FM_MERGE_STALL_SECS"

meta_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1; }

# The waiting line, printed, when the worker of <status> waits on the home.
waiting_line() {  # <status-file>
  local line verb
  line=$(status_declared_wait_line "$1")
  if [ -n "$line" ]; then
    status_is_paused "$line" || return 1
    printf '%s' "$line"
    return 0
  fi
  line=$(last_status_line "$1")
  status_line_verb "$line" verb
  [ "$verb" = "done" ] || return 1
  printf '%s' "$line"
}

stall_key() {  # <task> <url> <since> <episode>
  printf 'merge-stall-%s-%s' "$1" "$(
    { printf '%s\t%s\t%s' "$1" "$2" "$3"; [ -z "$4" ] || printf '\t%s' "$4"; } | cksum | awk '{print substr($1, 1, 8)}'
  )"
}

# Publish one merge-stall line on a secondmate's parent channel. 0 when
# published or when this is a main home (nothing to publish).
parent_report() {  # <line>
  local rc=0
  fm_parent_channel_report "$FM_HOME" "$STATE" "$1" || rc=$?
  case "$rc" in 0|1) return 0 ;; esac
  printf 'fm-merge-stall: parent channel append failed (rc=%s): %s\n' "$rc" "$1" >&2
  return 1
}

save_ledger() {
  local tmp
  tmp=$(mktemp "$STATE/.merge-stall.XXXXXX") || { echo 'fm-merge-stall: ledger temporary file creation failed' >&2; return 1; }
  if ! printf '%s' "$1" > "$tmp" || ! mv -f "$tmp" "$LEDGER"; then
    rm -f -- "$tmp"
    echo 'fm-merge-stall: ledger write failed' >&2
    return 1
  fi
}

resolve_stall() {
  local key=$1 task=$2 url=$3 channel rc=0 open
  channel=$(fm_parent_channel_destination "$FM_HOME" "$STATE") || rc=$?
  [ "$rc" -ne 1 ] || return 0
  if [ "$rc" -ne 0 ]; then
    printf 'fm-merge-stall: parent channel read failed (rc=%s) for %s PR %s\n' "$rc" "$task" "$url" >&2
    return 1
  fi
  if [ ! -e "$channel" ] && [ ! -L "$channel" ]; then return 0; fi
  if [ ! -f "$channel" ] || [ -L "$channel" ] || [ ! -r "$channel" ]; then
    printf 'fm-merge-stall: parent channel read failed for %s PR %s: %s\n' "$task" "$url" "$channel" >&2
    return 1
  fi
  open=$(status_open_decisions "$channel")
  case "$open" in
    "$key"$'\t'*|*$'\n'"$key"$'\t'*)
      parent_report "resolved [key=$key]: merge stall $task: PR $url is no longer a merge candidate or its worker waiting episode ended"
      ;;
  esac
}

task_uncertain() {
  local preserved
  scan_active
  diagnostics=$(fm_parent_channel_clean_note "${diagnostics:+$diagnostics; }$*")
  rows=$(printf '%s' "$rows" | awk -F '\t' -v t="$id" '$1 != t')
  [ -z "$rows" ] || rows="$rows"$'\n'
  preserved=$(printf '%s' "$old" | awk -F '\t' -v t="$id" '$1 == t')
  [ -z "$preserved" ] || rows="$rows$preserved"$'\n'
}

old=
if [ -e "$LEDGER" ] || [ -L "$LEDGER" ]; then
  [ -f "$LEDGER" ] && [ ! -L "$LEDGER" ] || { echo 'fm-merge-stall: ledger is not a regular file' >&2; exit 1; }
  old=$(cat "$LEDGER") || { echo 'fm-merge-stall: ledger read failed' >&2; exit 1; }
fi

rows=
diagnostics=
due_row=
due_since=
due_last=
due_forge=
due_hold_error=
due_line=
for meta in "$STATE"/*.meta; do
  scan_active
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  id=${meta##*/}; id=${id%.meta}
  [ "$(meta_get "$meta" kind)" = ship ] || continue
  [ "$(meta_get "$meta" yolo)" = on ] || continue
  [ "$(meta_get "$meta" mode)" != local-only ] || continue
  line=$(waiting_line "$STATE/$id.status") || continue
  url=$(meta_get "$meta" pr)
  if [ -n "$url" ]; then
    if ! fm_pr_url_parse "$url"; then
      task_uncertain "PR identity unreadable for $id: $url"
      continue
    fi
    if fm_pr_poll_merge_already_notified "$STATE" "$id" "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"; then
      continue
    fi
  fi
  activity_rc=0
  activity=$(fm_exec_timed "$READ_TIMEOUT" 1 env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_NO_FORGE=1 "$CREW_STATE_BIN" "$id" 2>&1) || activity_rc=$?
  scan_active
  if [ "$activity_rc" -ne 0 ]; then
    task_uncertain "current activity read failed for $id (rc=$activity_rc): $activity"
    continue
  fi
  case "$activity" in
    'state: paused '*|'state: done '*) ;;
    'state: working '*|'state: parked '*|'state: blocked '*|'state: failed '*) continue ;;
    *) task_uncertain "current activity unreadable for $id: $activity"; continue ;;
  esac
  if [ -z "$url" ]; then
    worktree=$(meta_get "$meta" worktree)
    branch=$(meta_get "$meta" branch)
    if [ ! -d "$worktree" ] || [ -z "$branch" ] || [ "$branch" = HEAD ]; then
      task_uncertain "PR discovery lacks a worktree or branch for $id"
      continue
    fi
    lookup_rc=0
    lookup=$(cd "$worktree" && fm_exec_timed "$READ_TIMEOUT" 1 gh pr list --state open --head "$branch" --limit 1 --json url,isDraft 2>&1) || lookup_rc=$?
    scan_active
    if [ "$lookup_rc" -ne 0 ]; then
      task_uncertain "PR discovery failed for $id (rc=$lookup_rc): $lookup"
      continue
    fi
    if ! record=$(printf '%s' "$lookup" | jq -sr '
      if length == 1 and (.[0] | type) == "array" and (.[0] | length) <= 1 and all(.[0][];
        type == "object" and (.url | type) == "string" and (.isDraft | type) == "boolean")
      then .[0][] | [.url, .isDraft] | @tsv
      else error("expected an array of PR URLs and draft flags") end' 2>&1); then
      task_uncertain "PR discovery unreadable for $id: $record"
      continue
    fi
    [ -n "$record" ] || continue
    IFS=$'\t' read -r url draft <<EOF
$record
EOF
    if ! fm_pr_url_parse "$url"; then
      task_uncertain "PR discovery returned an invalid URL for $id: $url"
      continue
    fi
    [ "$FM_PR_PROVIDER" = github ] && [ "$draft" = false ] || continue
  fi
  episode=$(printf '%s' "$line" | cksum | awk '{print $1}')
  since='' last=0 escalated=0
  while IFS=$'\t' read -r o_task o_url o_since o_last o_esc o_episode; do
    [ "$o_task" = "$id" ] && [ "$o_url" = "$url" ] && [ "$o_episode" = "$episode" ] || continue
    case "$o_since:$o_last:$o_esc" in *[!0-9:]*|:*|*::*|*:) continue ;; esac
    since=$o_since last=$o_last escalated=$o_esc
    break
  done <<EOF
$old
EOF
  if [ -z "$since" ]; then
    since=$(status_line_at_epoch "$line") || since=$NOW
    [ "$since" -le "$NOW" ] || since=$NOW
  fi
  row="$id"$'\t'"$url"$'\t'"$since"$'\t'"$last"$'\t'"$escalated"$'\t'"$episode"
  rows="$rows$row"$'\n'
  age=$((NOW - since))
  [ "$age" -ge "$STALL" ] || continue
  interval=$STALL
  [ "$escalated" = 0 ] || interval=$ESCALATE
  [ "$last" -eq 0 ] || [ $((NOW - last)) -ge "$interval" ] || continue
  forge=
  if fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ]; then
    if forge=$(fm_exec_timed "$READ_TIMEOUT" 1 "$PR_STATE_BIN" "$url" 2>&1); then
      scan_active
      forge=$(printf '%s\n' "$forge" | awk 'NF { printf "%s%s", sep, $0; sep = "; " }')
      [ -n "$forge" ] || forge='no blockers seen'
    else
      task_uncertain "forge state unreadable for $id: $url: $forge"
      continue
    fi
  fi
  case "$forge" in
    'STATE: '*|'DRAFT: '*)
      rows=$(printf '%s' "$rows" | awk -F '\t' -v t="$id" -v u="$url" '!($1 == t && $2 == u)')
      [ -z "$rows" ] || rows="$rows"$'\n'
      continue
      ;;
  esac
  hold_rc=0
  hold_error=$(fm_exec_timed "$READ_TIMEOUT" 1 env FM_HOME="$FM_HOME" "$CAPTAIN_HOLD_BIN" open "$id" 2>&1) || hold_rc=$?
  scan_active
  [ "$hold_rc" -ne 0 ] || continue
  if [ "$hold_rc" -eq 1 ]; then
    hold_error=
  else
    hold_error=$(fm_parent_channel_clean_note "$hold_error")
    hold_error="captain-hold read failed (rc=$hold_rc)${hold_error:+: $hold_error}"
  fi
  if [ -z "$due_last" ] || [ "$last" -lt "$due_last" ] \
    || { [ "$last" -eq "$due_last" ] && [ "$since" -lt "$due_since" ]; }; then
    due_row=$row due_since=$since due_last=$last due_line=$line
    due_forge=$forge due_hold_error=$hold_error
  fi
done

scan_active
checkpoint=$(printf '%s\n%s' "$rows" "$old" | awk -F '\t' 'NF >= 5 && !seen[$1 FS $2 FS $3 FS $6]++')
[ -z "$checkpoint" ] || checkpoint="$checkpoint"$'\n'
save_ledger "$checkpoint" || exit 1

# A stall that ended since the last scan: its row is gone from the rebuilt set.
while IFS=$'\t' read -r o_task o_url o_since o_last o_esc o_episode; do
  [ -n "$o_task" ] || continue
  if printf '%s' "$rows" | awk -F '\t' -v t="$o_task" -v u="$o_url" -v s="$o_since" -v e="$o_episode" \
    '$1 == t && $2 == u && $3 == s && $6 == e { found = 1 } END { exit !found }'; then
    continue
  fi
  resolve_stall "$(stall_key "$o_task" "$o_url" "$o_since" "$o_episode")" "$o_task" "$o_url" || exit 1
done <<EOF
$old
EOF

out=
if [ -n "$due_row" ]; then
  IFS=$'\t' read -r id url since last escalated episode <<EOF
$due_row
EOF
  forge=$due_forge
  age=$((NOW - since))
  wait_note=$(fm_parent_channel_clean_note "$(status_line_note "$due_line")" | cut -c1-200)
  out="$id PR $url unmerged ${age}s while its worker waits on this home ($(status_line_verb "$due_line"): $wait_note)"
  if [ -n "$due_hold_error" ]; then
    out="$out; $due_hold_error; repair the captain-hold authorization check before merging"
  else
    out="$out; this home merges it without asking: merge it now with bin/fm-pr-merge.sh $id $url, and if that refuses, act on the refusal"
  fi
  [ -z "$forge" ] || out="$out [forge: $forge]"
  if [ "$age" -ge "$ESCALATE" ]; then
    if [ "$escalated" = 0 ]; then
      parent_report "blocked [key=$(stall_key "$id" "$url" "$since" "$episode")]: merge stall $id: PR $url unmerged while its worker waits on this home (waiting since $since)" || exit 1
    fi
    escalated=1
    if fm_parent_channel_home_id "$FM_HOME" >/dev/null 2>&1; then
      out="$out; stalled past ${ESCALATE}s: reported to the captain through the parent channel"
    else
      out="$out; stalled past ${ESCALATE}s: tell the captain now"
    fi
  fi
  rows=$(printf '%s' "$rows" | awk -F '\t' -v OFS='\t' -v t="$id" -v u="$url" -v now="$NOW" -v esc="$escalated" \
    '{ if ($1 == t && $2 == u) { $4 = now; $5 = esc } print }')
  rows="$rows"$'\n'
fi

save_ledger "$rows" || exit 1
[ -z "$diagnostics" ] || out="${out:+$out; }evidence unavailable: $diagnostics"
[ -z "$out" ] || printf '%s\n' "$out"
exit 0
