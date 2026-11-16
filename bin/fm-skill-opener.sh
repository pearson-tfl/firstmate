#!/usr/bin/env bash
# Render a workflow's literal skill invocation before its launch carrier.
# Usage: fm-skill-opener.sh <harness> <encode|record|pointer> <brief-path>
# A brief's first line may be /name, $name, /skill:name, or @skill:name.
# fm-brief uses the portable /name spelling; the harness-adapters invocation
# map owns conversion to the selected harness. Unknown forms fail closed.
# The remaining launch envelope/record is owned by fm-operational-input.sh.
# pointer renders the same opener before a file-read instruction for adapters
# with a post-launch prompt. A brief without an opener keeps its old carrier.
# Source-safe helpers also let spawn validate ships before allocating work.

_FM_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_skill_name() { # <first-line>
  local name=$1
  case "$name" in
    /skill:*) name=${name#/skill:} ;;
    @skill:*) name=${name#@skill:} ;;
    /*) name=${name#/} ;;
    \$*) name=${name#\$} ;;
    *) return 1 ;;
  esac
  case "$name" in ''|*[!a-zA-Z0-9_-]*) return 1 ;; esac
  printf '%s' "$name"
}

fm_skill_brief_name() { # <brief>
  local first=
  IFS= read -r first < "$1" || [ -n "$first" ] || return 1
  fm_skill_name "${first%%[[:space:]]*}"
}

fm_skill_brief_body() { # <brief>
  local first token
  IFS= read -r first < "$1" || [ -n "$first" ] || return 1
  token=${first%%[[:space:]]*}
  if fm_skill_name "$token" >/dev/null; then
    [ "$first" = "$token" ] || printf '%s\n' "${first#"$token"}"
    tail -n +2 "$1"
  else
    cat "$1"
  fi
}

fm_skill_invocation() { # <harness> <name>
  local prefix owner
  case "$2" in ''|*[!a-zA-Z0-9_-]*) return 2 ;; esac
  owner="$_FM_SKILL_DIR/../.agents/skills/harness-adapters/SKILL.md"
  prefix=$(awk '/^```json harness-skill-invocations-v1$/ { found=1; next }
    found && /^```$/ { exit } found { print }' "$owner" |
    jq -er --arg harness "$1" '.[$harness] | select(type == "string" and length > 0)') || {
    printf 'error: no verified skill invocation for harness %s; see harness-adapters\n' "$1" >&2
    return 1
  }
  printf '%s%s' "$prefix" "$2"
}

# A stored invocation is data, not input to the harness parser. This load
# instruction travels in the record itself, including remote handoffs.
fm_skill_steer() { # <harness> <name> <body>
  local invocation
  invocation=$(fm_skill_invocation "$1" "$2") || return 1
  printf '%s\nLoad the %s skill through the harness skill tool or read its complete SKILL.md before doing this step. If unavailable, report blocked and stop.\n%s' "$invocation" "$2" "$3"
}

fm_skill_opener_main() {
  case "${1:-}" in
    -h|--help)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$_FM_SKILL_DIR/fm-skill-opener.sh"
      return 0
      ;;
  esac
  [ "$#" -eq 3 ] || { echo 'usage: fm-skill-opener.sh <harness> <encode|record|pointer> <brief-path>' >&2; return 2; }
  local harness=$1 carrier=$2 brief=$3 name invocation body
  [ -r "$brief" ] || return 1
  name=$(fm_skill_brief_name "$brief") || name=
  invocation=
  if [ -n "$name" ]; then
    invocation=$(fm_skill_invocation "$harness" "$name") || return 1
  fi
  case "$carrier" in
    encode|record)
      body=$("$_FM_SKILL_DIR/fm-operational-input.sh" "$carrier" launch-brief < "$brief") || return 1
      ;;
    pointer) body="Read the brief at $brief and follow it exactly." ;;
    *) return 2 ;;
  esac
  [ -z "$invocation" ] || printf '%s\n' "$invocation"
  printf '%s' "$body"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_skill_opener_main "$@"
fi
