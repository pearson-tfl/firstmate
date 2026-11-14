#!/usr/bin/env bash
# Token-free guard for the exhausted-login switch's Claude signal: replays the
# rate_limit API error records the installed Claude Code actually wrote in the
# last week of this machine's transcripts through bin/fm-exhaust-switch.sh
# check, and fails naming the version when a record's wording is neither a
# known usage stop (the seat must move) nor the known transient throttle (it
# must stay). The control plane is a recording stand-in, so no login is touched.
# FM_EXHAUST_SWITCH_CLAUDE_LIVE=0 (or FM_LIVE=0) skips it; =1 forces it.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_EXHAUST_SWITCH_CLAUDE_LIVE claude jq

VERSION=$(claude --version 2>/dev/null | head -n 1)
TMP_ROOT=$(fm_test_tmproot fm-exhaust-claude-live)
fail() { printf 'not ok - Claude Code %s: %s\n' "$VERSION" "$1" >&2; exit 1; }

records="$TMP_ROOT/records.jsonl"
find "${HOME%/}/.claude/projects" -name '*.jsonl' -mtime -7 -print0 2>/dev/null \
  | LC_ALL=C xargs -0 grep -hF '"error":"rate_limit"' 2>/dev/null \
  | jq -c 'select(.type == "assistant" and .isApiErrorMessage == true and .error == "rate_limit")
      | {text: ([.message.content[]? | select(.type == "text") | .text] | join("")), rec: .}' 2>/dev/null \
  | jq -sc 'unique_by(.text[0:40]) | .[]' > "$records"
if [ ! -s "$records" ]; then
  printf 'skip: live: no Claude rate_limit record in the last week of transcripts\n'
  exit 0
fi

FM_HOME="$TMP_ROOT/home"
STATE="$FM_HOME/state"
mkdir -p "$STATE" "$FM_HOME/config" "$FM_HOME/data" "$TMP_ROOT/bin" "$TMP_ROOT/claude/.claude/projects/-wt"
export FM_HOME FM_EXHAUSTED_LOGINS="$TMP_ROOT/exhausted" FM_TEST_SEAM=1 FM_TEST_EXHAUST_CONTROL="$TMP_ROOT/bin/control"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/control.log"\n' "$TMP_ROOT" > "$TMP_ROOT/bin/control"
printf '%s\n' '#!/bin/sh' \
  "printf '%s\\n' '{\"schemaVersion\":1,\"accounts\":[{\"number\":1,\"usageStatus\":\"ok\",\"usage\":{\"fiveHour\":{\"pct\":5}}},{\"number\":2,\"usageStatus\":\"ok\",\"usage\":{\"fiveHour\":{\"pct\":40}}}]}'" \
  > "$TMP_ROOT/bin/cswap"
chmod +x "$TMP_ROOT/bin/control" "$TMP_ROOT/bin/cswap"

checked=0
while IFS= read -r line; do
  text=$(printf '%s' "$line" | jq -r .text)
  case "$text" in
    "You've hit your "* | "You've reached your "* | "You're out of usage"*) want=move ;;
    "API Error: Server is temporarily limiting requests"*) want=stay ;;
    *) fail "unrecognised rate_limit wording, neither a known usage stop nor the transient throttle: ${text:0:80}" ;;
  esac
  rm -f "$STATE"/cl.* "$FM_EXHAUSTED_LOGINS" "$TMP_ROOT/control.log"
  printf 'window=fake:cl\nharness=claude\nkind=ship\naccount=cswap:1\nproject=/x/proj\nagent_session_id=sess-1\n' > "$STATE/cl.meta"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" cl --state idle --source claude-hook --event test)
  printf 'busy_gen=%s\n' "$gen" >> "$STATE/cl.meta"
  printf '%s' "$line" | jq -c .rec > "$TMP_ROOT/claude/.claude/projects/-wt/sess-1.jsonl"
  out=$(HOME="$TMP_ROOT/claude" PATH="$TMP_ROOT/bin:$PATH" FM_BACKEND=tmux "$ROOT/bin/fm-exhaust-switch.sh" check 2>&1)
  case "$want:$out" in
    move:*"cl ran out of usage on cswap:1"*) ;;
    stay:) ;;
    *) fail "the switch read '${text:0:60}' wrongly (wanted $want): ${out:-no output}" ;;
  esac
  # Let a started move finish before the next record replaces the seat.
  for _ in $(seq 1 50); do grep -qE '^status=(done|failed)' "$STATE/cl.exhaust-switch" 2>/dev/null || [ "$want" = stay ] && break; sleep 0.1; done
  checked=$((checked + 1))
done < "$records"
pass "Claude Code $VERSION: $checked distinct rate_limit wordings from real transcripts read correctly as usage stop or throttle"
