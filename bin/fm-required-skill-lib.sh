#!/usr/bin/env bash
# fm-required-skill-lib.sh - the one owner of required-skill proof.
#
# When a request names a skill (for example /poteto-mode or /tdd), the
# dispatcher records it as a required skill, and the recipient must prove both
# that the skill started and how it shaped the work before its done counts.
# This library owns the record forms, the proof-line grammar, the checks, and
# the worker-facing instructions; every other surface calls it.
#
# Records:
#   a task         state/<id>.meta carries required_skills=<a,b> (bin/fm-spawn.sh
#                  --required-skill, agreeing with the brief's machine line)
#   a brief, a     the machine line "Required skills: <a,b>" at a line start,
#   request, or    rendered by fm_required_skills_section (bin/fm-brief.sh
#   inbox record   --required-skill, bin/fm-send.sh --required-skill)
#   a marked       the parent pending-reply record carries required_skills=
#   request        (bin/fm-pending-reply-lib.sh)
#
# Proof lines are ordinary status lines whose note opens with a proof keyword:
#   start   <verb>: skill-start <name> path=<SKILL.md path read> route=<first routing decision>
#   shaped  <verb>: skill-shaped <name>: <how the skill shaped the work>
# A marked secondmate request's proof must carry that request's [corr=<id>]
# token before the colon, which bin/fm-secondmate-report.sh writes itself; a
# proof line never answers the request (fm_pending_reply_line_resolves).
#
# Enforcement:
#   start  bin/fm-task-inbox-lib.sh reopens an acknowledged inbox record that
#          carries the machine line until every start proof is present, so the
#          watcher's existing re-ring ladder keeps ringing and then escalates.
#   done   bin/fm-dod-lib.sh's fm_dod_accept_ship_done and bin/fm-crew-state.sh
#          refuse a ship or scout done, bin/fm-pr-check.sh refuses to register
#          its PR, bin/fm-secondmate-report.sh refuses a done reply, and the
#          parent pending-reply record stays open, while any start or shaped
#          proof is missing. A task or request with no required skill is
#          unchanged.
#
# Sourced by bin/fm-dod-lib.sh, bin/fm-task-inbox-lib.sh,
# bin/fm-pending-reply-lib.sh, bin/fm-brief.sh, bin/fm-spawn.sh,
# bin/fm-send.sh, bin/fm-secondmate-report.sh, and tests. Requires
# bin/fm-classify-lib.sh's status_line_note (sourced below). No side effects.

_FM_REQUIRED_SKILL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F status_line_note >/dev/null; then
  # shellcheck source=bin/fm-classify-lib.sh
  . "$_FM_REQUIRED_SKILL_LIB_DIR/fm-classify-lib.sh"
fi
# Skill names and harness invocations come from the skill-opener owner.
# shellcheck source=bin/fm-skill-opener.sh
. "$_FM_REQUIRED_SKILL_LIB_DIR/fm-skill-opener.sh"

FM_REQUIRED_SKILLS_LINE='Required skills: '

# Normalize repeated --required-skill values into one comma list, refusing a
# malformed name and dropping duplicates. A value may be bare or carry any
# invocation form fm_skill_name reads. Prints the list (empty for none).
fm_required_skills_join() {  # <name>...
  local out='' v n
  for v in "$@"; do
    n=$(fm_skill_name "$v") || n=$(fm_skill_name "/$v") || {
      printf 'error: --required-skill needs a skill name such as poteto-mode or /tdd (got %s)\n' "'$v'" >&2
      return 1
    }
    case ",$out," in *",$n,"*) continue ;; esac
    out="${out}${out:+,}$n"
  done
  printf '%s' "$out"
}

# The comma list from the first machine line in <text>, or empty.
fm_required_skills_from_text() {  # <text>
  local line
  while IFS= read -r line; do
    case "$line" in
      "$FM_REQUIRED_SKILLS_LINE"*) printf '%s' "${line#"$FM_REQUIRED_SKILLS_LINE"}"; return 0 ;;
    esac
  done <<EOF
$1
EOF
}

# The recorded comma list in a task's meta, or empty.
fm_required_skills_from_meta() {  # <meta>
  grep '^required_skills=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# 0 when <line> is a valid <kind> proof (start|shaped) for <name>, carrying
# [corr=<corr>] before the colon when <corr> is given.
fm_required_skill_line_proves() {  # <line> <start|shaped> <name> [corr]
  local line=$1 kind=$2 name=$3 corr=${4:-} note rest
  case "${line%%:*}" in *"[source=firstmate]"*) return 1 ;; esac
  if [ -n "$corr" ]; then
    case "${line%%:*}" in *"[corr=$corr]"*) ;; *) return 1 ;; esac
  fi
  note=$(status_line_note "$line")
  note=$(printf '%s' "$note" | sed 's/ (.*via-helper)$//')
  case "$kind" in
    start)
      case "$note" in "skill-start $name "*) ;; *) return 1 ;; esac
      rest=${note#"skill-start $name "}
      case "$rest" in path=?*' route='?*) ;; *) return 1 ;; esac
      [ -n "${rest##* route=}" ] || return 1
      rest=${rest##* route=}
      [ -n "${rest//[[:space:]]/}" ] || return 1
      ;;
    shaped)
      case "$note" in "skill-shaped $name:"*) ;; *) return 1 ;; esac
      rest=${note#"skill-shaped $name:"}
      [ -n "${rest//[[:space:]]/}" ] || return 1
      ;;
    *) return 1 ;;
  esac
}

# 0 when <note> opens with a proof keyword, so the line is proof, not an answer.
fm_required_skill_note_is_proof() {  # <note>
  case "$1" in skill-start\ *|skill-shaped\ *) return 0 ;; esac
  return 1
}

# Print, one per line, each skill in <list> with no <kind> proof in <status-file>.
fm_required_skills_missing() {  # <status-file> <start|shaped> <comma-list> [corr]
  local status=$1 kind=$2 list=$3 corr=${4:-} name line found candidate valid
  local IFS=,
  for name in $list; do
    [ -n "$name" ] || continue
    found=0
    if [ -f "$status" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        [ -n "${line//[[:space:]]/}" ] || continue
        case "${line%%:*}" in *"[source=firstmate]"*) continue ;; esac
        if [ -n "$corr" ]; then
          case "${line%%:*}" in *"[corr=$corr]"*) ;; *) continue ;; esac
        fi
        if [ "$kind" = start ]; then
          valid=0
          for candidate in $list; do
            if fm_required_skill_line_proves "$line" start "$candidate" "$corr"; then
              valid=1
              break
            fi
          done
          [ "$valid" = 1 ] || break
        fi
        if fm_required_skill_line_proves "$line" "$kind" "$name" "$corr"; then
          found=1
          break
        fi
      done < "$status"
    fi
    [ "$found" = 1 ] || printf '%s\n' "$name"
  done
}

# The exact form that satisfies a <kind> proof for <name>: a status line, or
# with "helper" the secondmate helper call that writes the correlated line,
# naming <corr> when given (the helper otherwise picks the open request).
fm_required_skill_proof_form() {  # <start|shaped> <name> [helper [corr]]
  local body
  case "$1" in
    start) body="skill-start $2 path=<SKILL.md path you read> route=<your first routing decision under it>" ;;
    shaped) body="skill-shaped $2: <how the skill shaped the work>" ;;
    *) return 2 ;;
  esac
  if [ "${3:-}" = helper ]; then
    printf 'bin/fm-secondmate-report.sh working %s"%s"' "${4:+$4 }" "$body"
  else
    printf 'working [at=<epoch>]: %s' "$body"
  fi
}

# The done gate. Prints a one-line refusal naming every skill missing its
# start or shaped proof and the exact form that satisfies each, and returns 1;
# returns 0 when <list> is empty or every skill has both proofs.
fm_required_skills_done_refusal() {  # <status-file> <comma-list> [corr]
  local status=$1 list=$2 corr=${3:-} kind missing name what='' forms=''
  [ -n "$list" ] || return 0
  for kind in start shaped; do
    missing=$(fm_required_skills_missing "$status" "$kind" "$list" "$corr")
    [ -n "$missing" ] || continue
    case "$kind" in
      start) what="${what}${what:+; }required skill $(printf '%s' "$missing" | paste -sd, -) has no start proof before other status lines" ;;
      shaped) what="${what}${what:+; }required skill $(printf '%s' "$missing" | paste -sd, -) has no record of how it shaped the work" ;;
    esac
    while IFS= read -r name; do
      forms="${forms}${forms:+; }\`$(fm_required_skill_proof_form "$kind" "$name" ${corr:+helper "$corr"})\`"
    done <<EOF
$missing
EOF
  done
  [ -n "$what" ] || return 0
  printf 'done refused: %s; required forms: %s; start proofs must precede other status lines\n' "$what" "$forms"
  return 1
}

# The ship/scout done gate on a task: reads required_skills= from <meta> and
# the proofs from <state>/<id>.status. Same output contract as above.
fm_required_skills_task_done_refusal() {  # <state> <id> <meta>
  [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || return 0
  fm_required_skills_done_refusal "$1/$2.status" "$(fm_required_skills_from_meta "$3")"
}

# Worker-facing section carrying the machine line and both proof forms, for a
# brief, the start-proof inbox record, or a marked request. <mode> is "task"
# (plain status lines) or "request" (secondmate helper lines; the helper fills
# in the request's correlation). With <harness>, each skill's literal
# invocation in that harness's form (fm_skill_invocation) is listed, and an
# unverified form fails rather than guessing (bin/fm-spawn.sh then falls back
# to the portable form); without one the brief keeps the portable /name form,
# as fm-brief.sh does for its opener.
fm_required_skills_section() {  # <comma-list> <task|request> [harness]
  local list=$1 mode=$2 harness=${3:-} via='' ring start shaped name inv invocations=''
  [ -n "$list" ] || return 0
  local IFS=,
  for name in $list; do
    if [ -n "$harness" ]; then
      inv=$(fm_skill_invocation "$harness" "$name") || return 1
    else
      inv="/$name"
    fi
    invocations="${invocations}${invocations:+, }\`$inv\`"
  done
  unset IFS
  ring='Firstmate leaves a start-proof record in your steering inbox and keeps ringing it until every start proof is present, even after you acknowledge it.'
  if [ "$mode" = request ]; then
    via=helper
    ring='Firstmate keeps ringing this request until every start proof is present, even after you acknowledge it.'
  fi
  start=$(fm_required_skill_proof_form start '<name>' $via)
  shaped=$(fm_required_skill_proof_form shaped '<name>' $via)
  cat <<EOF
# Required skills
$FM_REQUIRED_SKILLS_LINE$list
The request named these skills, so each one must shape this work, and firstmate checks the record mechanically.
1. Before any other status line, load each skill ($invocations) through the skill tool or read its complete SKILL.md, then report one start proof per skill: \`$start\`
   $ring
2. Before reporting done, report one line per skill saying how it shaped the work: \`$shaped\`
   A done without one is refused, naming the missing skill.
EOF
}
