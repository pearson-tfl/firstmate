#!/usr/bin/env bash
# Opt-in live guard for the exact agent session flags a spawn fixes and the
# `resume` control verb reopens (bin/fm-control-lib.sh's
# fm_control_agent_session_flag), against every installed runner it names.
#
# The flags are vendor surface - Claude Code's --session-id and --resume, and
# Pi's --session-id - so a fake runner can only restate the assumption written
# into it. This guard asks each REAL installed runner, in print mode, to start
# a session on an id it minted with the `fresh` flag, then to answer a second
# prompt on the same id with the `resume` flag, and passes only when:
#   - the runner's own transcript is the one file named by that id, and
#   - the resumed answer recalls the first turn, so the conversation, not just
#     the file name, came back.
# The divergence it depends on is asserted too: a third prompt on a NEW id does
# not recall the word, so the recall is the resumed session at work.
#
# It submits prompts and spends tokens, so it is opt-in; run it with
# FM_AGENT_SESSION_LIVE_E2E=1 (or FM_LIVE=1) after every Claude or Pi upgrade
# and before trusting the "Agent session resume" entry in
# docs/verification/runtime-backends.md. It uses the operator's own logins.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_AGENT_SESSION_LIVE_E2E jq
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agent-session-live)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'fm_test_remove_tree "$TMP_ROOT"' EXIT
CHECKED=
WORD=MARIGOLD
FIRST="Reply with exactly the word $WORD and nothing else. Use no tools."
ASK="Which single word did you reply with earlier in this conversation? Reply with that word only, or NONE if there was no earlier reply. Use no tools."

new_uuid() {
  uuidgen | tr 'A-F' 'a-f'
}

# runner_case <harness> <session-root> <file-glob-suffix> <command...>
# The command is the runner's print-mode invocation, to which the session flag
# and prompt are appended.
runner_case() {
  local harness=$1 root=$2 suffix=$3
  shift 3
  local version cwd sid other fresh resume out files
  version=$("$1" --version 2>/dev/null | head -1)
  cwd="$TMP_ROOT/$harness-proj"
  mkdir -p "$cwd"
  fresh=$(fm_control_agent_session_flag "$harness" fresh) || fail "$harness has no fresh session flag"
  resume=$(fm_control_agent_session_flag "$harness" resume) || fail "$harness has no resume session flag"
  sid=$(new_uuid)
  (cd "$cwd" && "$@" "$fresh" "$sid" "$FIRST" >/dev/null 2>&1) \
    || fail "$harness $version: the first prompt on $fresh $sid failed"
  out=$(cd "$cwd" && "$@" "$resume" "$sid" "$ASK" 2>&1) \
    || fail "$harness $version: the resumed prompt on $resume $sid failed: $out"
  files=$(find "$root" -name "*$sid$suffix" 2>/dev/null | wc -l | tr -d ' ')
  [ "$files" = 1 ] || fail "$harness $version: expected one transcript named by $sid under $root, found $files"
  assert_contains "$out" "$WORD" "$harness $version: the resumed session must recall its first turn"
  other=$(new_uuid)
  out=$(cd "$cwd" && "$@" "$fresh" "$other" "$ASK" 2>&1) \
    || fail "$harness $version: the divergence prompt on a new id failed: $out"
  assert_not_contains "$out" "$WORD" "$harness $version: a new session must not recall the word, or the recall proves nothing"
  pass "$harness $version: $fresh starts the session on the minted id, and $resume reopens that exact conversation"
  CHECKED="$CHECKED $harness"
}

if command -v claude >/dev/null 2>&1; then
  runner_case claude "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" .jsonl \
    claude -p --model claude-haiku-5-5
else
  echo "skip-runner: claude is not installed, so its session flags were not exercised"
fi
for pi_harness in pi pi-signed; do
  if command -v "$pi_harness" >/dev/null 2>&1; then
    runner_case "$pi_harness" "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/sessions" .jsonl \
      "$pi_harness" -p --no-tools
  else
    echo "skip-runner: $pi_harness is not installed, so its session flags were not exercised"
  fi
done

[ -n "$CHECKED" ] || fail "no runner with an exact session flag is installed, so this guard checked nothing"
echo "# agent session live guard checked:$CHECKED"
