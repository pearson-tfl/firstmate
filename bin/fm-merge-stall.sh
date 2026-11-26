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
#     without asking), and a pr= URL;
#   - its merge poll sidecar (state/<task>.pr-poll) is still armed for that
#     same URL, so no merge of it has been observed;
#   - its worker waits on the home: the declared wait is a `paused:` line, or
#     the newest status event is `done:`;
#   - no captain hold is open on it (bin/fm-captain-hold.sh open).
# A candidate's stall starts at its waiting line's [at=] time, or when first
# seen, and is kept across scans and watcher restarts in state/.merge-stall
# (<task> TAB <url> TAB <since> TAB <last-wake> TAB <escalated>).
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
# One line per scan, for the oldest due stall; others follow on later sweeps.
#
# Nothing here merges, comments, or changes a PR, and a failed forge read only
# drops the blocker detail. Exit 0 on success, 2 on usage or settings errors,
# 1 when the ledger or parent channel cannot be written.
set -u
export LC_ALL=C

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LEDGER="$STATE/.merge-stall"
PR_STATE_BIN="${FM_MERGE_STALL_PR_STATE_BIN:-$SCRIPT_DIR/fm-pr-state.sh}"
CAPTAIN_HOLD_BIN="${FM_MERGE_STALL_CAPTAIN_HOLD_BIN:-$SCRIPT_DIR/fm-captain-hold.sh}"

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
for value in "$NOW" "$STALL" "$ESCALATE"; do
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

stall_key() {  # <task> <url> <since>
  printf 'merge-stall-%s-%s' "$1" "$(printf '%s\t%s\t%s' "$1" "$2" "$3" | cksum | cut -c1-8)"
}

# Publish one merge-stall line on a secondmate's parent channel. 0 when
# published or when this is a main home (nothing to publish).
parent_report() {  # <line>
  local rc=0
  fm_parent_channel_report "$FM_HOME" "$STATE" "$1" || rc=$?
  case "$rc" in 0|1) return 0 ;; esac
  printf 'fm-merge-stall: parent channel append failed (rc=%s)\n' "$rc" >&2
  return 1
}

old=
if [ -e "$LEDGER" ] || [ -L "$LEDGER" ]; then
  [ -f "$LEDGER" ] && [ ! -L "$LEDGER" ] || { echo 'fm-merge-stall: ledger is not a regular file' >&2; exit 1; }
  old=$(cat "$LEDGER") || exit 1
fi

rows=
due_row=
due_since=
due_line=
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  id=${meta##*/}; id=${id%.meta}
  [ "$(meta_get "$meta" kind)" = ship ] || continue
  [ "$(meta_get "$meta" yolo)" = on ] || continue
  url=$(meta_get "$meta" pr)
  [ -n "$url" ] || continue
  poll="$STATE/$id.pr-poll"
  [ -f "$poll" ] && [ ! -L "$poll" ] || continue
  [ "$(sed -n 2p "$poll")" = "$url" ] || continue
  line=$(waiting_line "$STATE/$id.status") || continue
  since='' last=0 escalated=0
  while IFS=$'\t' read -r o_task o_url o_since o_last o_esc; do
    [ "$o_task" = "$id" ] && [ "$o_url" = "$url" ] || continue
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
  row="$id"$'\t'"$url"$'\t'"$since"$'\t'"$last"$'\t'"$escalated"
  rows="$rows$row"$'\n'
  age=$((NOW - since))
  [ "$age" -ge "$STALL" ] || continue
  interval=$STALL
  [ "$escalated" = 0 ] || interval=$ESCALATE
  [ "$last" -eq 0 ] || [ $((NOW - last)) -ge "$interval" ] || continue
  # A captain call on the task owns it; exit 0 means still held.
  FM_HOME="$FM_HOME" "$CAPTAIN_HOLD_BIN" open "$id" >/dev/null 2>&1 && continue
  if [ -z "$due_since" ] || [ "$since" -lt "$due_since" ]; then
    due_row=$row due_since=$since due_line=$line
  fi
done

# A stall that ended since the last scan: its row is gone from the rebuilt set.
while IFS=$'\t' read -r o_task o_url o_since o_last o_esc; do
  [ -n "$o_task" ] && [ "$o_esc" = 1 ] || continue
  case "$rows" in "$o_task"$'\t'"$o_url"$'\t'*|*$'\n'"$o_task"$'\t'"$o_url"$'\t'*) continue ;; esac
  parent_report "resolved [key=$(stall_key "$o_task" "$o_url" "$o_since")]: merge stall $o_task: PR $o_url is merged or its worker no longer waits on this home" || exit 1
done <<EOF
$old
EOF

out=
if [ -n "$due_row" ]; then
  IFS=$'\t' read -r id url since last escalated <<EOF
$due_row
EOF
  forge=
  if fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ]; then
    if forge=$(fm_run_timed 25 "$PR_STATE_BIN" "$url" 2>/dev/null); then
      forge=$(printf '%s\n' "$forge" | awk 'NF { printf "%s%s", sep, $0; sep = "; " }')
      [ -n "$forge" ] || forge='no blockers seen'
    else
      forge='forge state unreadable'
    fi
  fi
  case "$forge" in
    'STATE: '*)
      # The PR already merged or closed; the merge poll records the outcome.
      rows=$(printf '%s' "$rows" | awk -F '\t' -v t="$id" -v u="$url" '!($1 == t && $2 == u)')
      [ -z "$rows" ] || rows="$rows"$'\n'
      if [ "$escalated" = 1 ]; then
        parent_report "resolved [key=$(stall_key "$id" "$url" "$since")]: merge stall $id: PR $url ${forge#STATE: }" || exit 1
      fi
      due_row=
      ;;
  esac
fi
if [ -n "$due_row" ]; then
  age=$((NOW - since))
  wait_note=$(fm_parent_channel_clean_note "$(status_line_note "$due_line")" | cut -c1-200)
  out="$id PR $url unmerged ${age}s while its worker waits on this home ($(status_line_verb "$due_line"): $wait_note); this home merges it without asking: merge it now with bin/fm-pr-merge.sh $id $url, and if that refuses, act on the refusal"
  [ -z "$forge" ] || out="$out [forge: $forge]"
  if [ "$age" -ge "$ESCALATE" ]; then
    if [ "$escalated" = 0 ]; then
      parent_report "blocked [key=$(stall_key "$id" "$url" "$since")]: merge stall $id: PR $url unmerged ${age}s while its worker waits on this home${forge:+ [forge: $forge]}" || exit 1
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

tmp=$(mktemp "$STATE/.merge-stall.XXXXXX") || exit 1
if ! printf '%s' "$rows" > "$tmp" || ! mv -f "$tmp" "$LEDGER"; then
  rm -f -- "$tmp"
  exit 1
fi
[ -z "$out" ] || printf '%s\n' "$out"
exit 0
