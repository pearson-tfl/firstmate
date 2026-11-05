#!/usr/bin/env bash
# Behavior tests for the primary-session delegation-shape guard: the tracked
# hook registration, shared settings boundary, and PreToolUse classifier.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-subagent-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-subagent-pretool-tests)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$PRIMARY/bin" "$STATE"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q

BRIEF_ONLY_ROUTE='first classify the work under the AGENTS.md intake contract, then use bin/fm-brief.sh followed by bin/fm-spawn.sh for dispatched work'
SCOUT_ROUTE='first classify the work under the AGENTS.md intake contract: work already classified as a scout goes to bin/fm-scout.sh "<question>" [project], while authorized ship work and its bounded research go to bin/fm-brief.sh then bin/fm-spawn.sh'

# Every delegation, scheduling, worktree, and task-tracking tool Claude Code
# 2.1.217 offered a primary session in the observed baseline.
# This inventory is shape-classification coverage for the shipped guard and the
# recommended local Claude deny-list hardening list, but tracked settings must
# not ship that Claude-only permissions layer.
DELEGATION_TOOLS='Task Agent Workflow RemoteTrigger Monitor ScheduleWakeup SendMessage EnterWorktree ExitWorktree CronCreate CronDelete CronList TaskCreate TaskGet TaskList TaskUpdate TaskStop TaskOutput'

# Tools that must stay available: denying these would break ordinary work.
PRESERVED_TOOLS='Bash Edit Read Write Skill ToolSearch WebFetch WebSearch NotebookEdit ReportFindings DesignSync PushNotification'

# Session-local todo-list tools. They match a delegation stem but create no
# runnable work, so the guard's plan-only exclusion must allow them.
PLAN_ONLY_TOOLS='TaskCreate TaskUpdate'

# Names the plan-only exclusion must NOT release. Five of them contain a
# plan-only name as a substring and would be let through by a substring rather
# than exact-name match; bare Task is what a shortened entry of "task" would
# release. Together they make the exact-name contract testable instead of
# assumed.
PLAN_ONLY_NEAR_MISSES='TaskCreateAgent TaskCreateWorktree TaskUpdateAgent RemoteTaskCreate Task TaskCreator'

run_tool() {
  local tool=$1 rc=0
  shift
  : > "$OUT"
  : > "$ERR"
  env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" "$@" \
    "$CHECK" --claude --tool "$tool" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

expect_allow() {
  local label=$1 tool=$2 rc=0
  shift 2
  run_tool "$tool" "$@" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label ($tool) must allow, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$label ($tool) allow wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label ($tool) allow wrote stderr: $(cat "$ERR")"
}

expect_deny() {
  local label=$1 tool=$2 rc=0
  run_tool "$tool" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label ($tool) must deny with exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "$label ($tool) deny wrote stdout: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "$label ($tool) deny omitted Claude's permission decision: $(cat "$ERR")"
  jq -e --arg tool "$tool" '.systemMessage | startswith("[subagent-dispatch]") and contains("blocked tool: " + $tool)' "$ERR" >/dev/null 2>&1 \
    || fail "$label ($tool) deny message lost its code or tool name: $(jq -r '.systemMessage' "$ERR")"
}

# ---------------------------------------------------------------------------
# Delegation-shape PreToolUse guard.
# ---------------------------------------------------------------------------

test_guard_denies_every_currently_known_delegation_tool() {
  local tool
  for tool in $DELEGATION_TOOLS; do
    case "$tool" in
      TaskOutput|TaskStop|TaskGet|TaskList|CronList) continue ;;
      TaskCreate|TaskUpdate) continue ;;
    esac
    expect_deny "known delegation tool" "$tool"
  done
  # Grok's child-message tool can resume a finished subagent, so it remains
  # delegation rather than gaining the Claude peer-message allowance.
  expect_deny "Grok child-message delegation" send_subagent_message
  pass "the guard independently denies every work-creating delegation tool by shape"
}

test_guard_denies_hypothetical_future_tools() {
  # A fixed deny list is fail-open against tools that do not exist yet.
  # None of these names is on any list.
  local tool
  for tool in SubagentCreate SpawnWorker DelegateTask AgentPool WorkflowRun \
              ScheduleJob CronSchedule CreateWorktree DispatchAgent TaskHandoff \
              RemoteExec BackgroundAgent ListAgentsAndSpawn ListAgentsTask; do
    expect_deny "future delegation tool" "$tool"
  done
  pass "the guard denies delegation-shaped tools that no deny list knows about yet"
}

test_guard_allows_ordinary_and_observe_only_tools() {
  local tool
  for tool in $PRESERVED_TOOLS; do
    expect_allow "ordinary tool" "$tool"
  done
  # Observing or stopping work that already exists is not creating unaccounted
  # work, and blocking it would strand a runaway task with no way to end it.
  for tool in TaskOutput TaskStop TaskGet TaskList CronList BashOutput KillShell ListAgents; do
    expect_allow "observe-or-stop tool" "$tool"
  done
  pass "the guard leaves ordinary tools and observe-or-stop operations alone"
}

test_guard_allows_session_local_todo_tools() {
  # These write, so they are not observe-or-stop, but what they write is the
  # harness's session-local todo list: no executor, no agent, no worktree, no
  # schedule, nothing that outlives the session. Denying them stops the primary
  # tracking its own plan and grants no delegation power in exchange.
  local tool
  for tool in $PLAN_ONLY_TOOLS; do
    expect_allow "session-local todo tool" "$tool"
  done
  pass "the guard leaves the session-local todo list alone"
}

test_plan_only_exclusion_is_exact_name() {
  # The plan-only exclusion must never widen by substring or by a shorter stem.
  # Every name here would be released by such a widening and must stay denied.
  local tool
  for tool in $PLAN_ONLY_NEAR_MISSES; do
    expect_deny "plan-only near miss" "$tool"
  done
  pass "the plan-only exclusion releases exactly two names and nothing that merely contains them"
}

test_guard_never_classifies_mcp_tools() {
  # An MCP server names its own tools; a task or agent noun there is common and
  # has nothing to do with fleet dispatch.
  local tool
  for tool in mcp__linear__list_issues mcp__tracker__create_task \
              mcp__acme__spawn_agent mcp__slack__slack_send_message; do
    expect_allow "MCP tool" "$tool"
  done
  pass "MCP tool names are never classified as harness delegation"
}

test_deny_message_defers_to_intake_classification() {
  local actual
  printf '#!/usr/bin/env bash\n' > "$PRIMARY/bin/fm-scout.sh"
  run_tool Agent && fail "scout-present case must still deny"
  actual=$(jq -r '.systemMessage' "$ERR")
  case "$actual" in
    *"$SCOUT_ROUTE"*) ;;
    *) fail "deny must reserve bin/fm-scout.sh for classified scout work: $actual" ;;
  esac
  case "$actual" in
    *'investigation or diagnosis goes to bin/fm-scout.sh'*) fail "deny must not classify all investigation or diagnosis as scout work: $actual" ;;
  esac
  rm -f "$PRIMARY/bin/fm-scout.sh"
  run_tool Agent && fail "scout-absent case must still deny"
  actual=$(jq -r '.systemMessage' "$ERR")
  case "$actual" in
    *"$BRIEF_ONLY_ROUTE"*) ;;
    *) fail "deny must degrade to brief-then-spawn when fm-scout.sh is absent: $actual" ;;
  esac
  pass "deny defers to intake classification and degrades gracefully without fm-scout.sh"
}

test_escape_hatch_allows_deliberate_use() {
  local rc value
  expect_allow "escape hatch set" Agent FM_ALLOW_SUBAGENT=1
  expect_deny "escape hatch unset" Agent
  for value in '' 0 yes true 11; do
    rc=0
    run_tool Agent "FM_ALLOW_SUBAGENT=$value" || rc=$?
    [ "$rc" -eq 2 ] || fail "FM_ALLOW_SUBAGENT='$value' must not release the guard, got exit $rc"
  done
  pass "the single documented escape hatch releases the guard only on the exact opt-in value"
}

test_task_worktree_and_non_firstmate_repo_are_inert() {
  local child="$TMP_ROOT/child" plain="$TMP_ROOT/plain" rc=0
  git -C "$PRIMARY" config user.name fixture
  git -C "$PRIMARY" config user.email fixture@example.test
  git -C "$PRIMARY" add AGENTS.md
  git -C "$PRIMARY" commit -qm fixture
  git -C "$PRIMARY" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/bin" "$child/state"
  printf '# fixture\n' > "$child/AGENTS.md"
  : > "$OUT"
  : > "$ERR"
  FM_ROOT_OVERRIDE="$child" FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" \
    "$CHECK" --claude --tool Agent > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a crewmate task worktree must be out of scope, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "task-worktree no-op wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "task-worktree no-op wrote stderr: $(cat "$ERR")"

  mkdir -p "$plain/bin"
  git -C "$plain" init -q
  rc=0
  FM_ROOT_OVERRIDE="$plain" FM_HOME="$plain" FM_STATE_OVERRIDE="$plain/state" \
    "$CHECK" --claude --tool Agent > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a non-firstmate repo must be out of scope, got exit $rc"
  pass "the guard is inert in a crewmate task worktree and in a non-firstmate repo"
}

test_secondmate_home_is_in_scope() {
  local second="$TMP_ROOT/second" rc=0
  git -C "$PRIMARY" worktree add -q -b fixture-second "$second"
  mkdir -p "$second/bin" "$second/state"
  printf '# fixture\n' > "$second/AGENTS.md"
  printf 'sm-fixture\n' > "$second/.fm-secondmate-home"
  FM_ROOT_OVERRIDE="$second" FM_HOME="$second" FM_STATE_OVERRIDE="$second/state" \
    "$CHECK" --claude --tool Agent > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "a marked secondmate home operates a fleet and must be guarded, got exit $rc"
  pass "a marked secondmate home is guarded even though it is a linked worktree"
}

test_stdin_transports_and_output_shapes() {
  local rc=0
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"tool_name":"Agent","tool_input":{"prompt":"go"}}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Claude-shaped stdin must deny, got exit $rc"
  [ ! -s "$OUT" ] || fail "Claude deny wrote stdout, which makes Claude ignore the deny: $(cat "$OUT")"

  rc=0
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"toolName":"send_subagent_message"}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Grok-shaped stdin must deny, got exit $rc"
  jq -e '.decision == "deny" and (.reason | startswith("[subagent-dispatch]"))' "$OUT" >/dev/null 2>&1 \
    || fail "default deny mode must write a Grok decision object on stdout: $(cat "$OUT")"

  rc=0
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "Bash through stdin must allow, got exit $rc"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "stdin allow wrote output"
  pass "both stdin transports classify correctly and Claude's deny keeps stdout empty"
}

run_send_message() {
  local input=$1 rc=0
  : > "$OUT"; : > "$ERR"
  jq -cn --argjson i "$input" '{tool_name:"SendMessage",tool_input:$i}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

test_send_message_peer_message_is_allowed() {
  # Current Claude peers use ListAgents names; legacy uds: addresses remain
  # accepted. Recipient validation is only a string with no CR or LF.
  local input rc
  for input in \
    '{"to":"researcher","message":"received msg-42"}' \
    '{"to":"main","message":"hello"}' \
    '{"to":"a1b2c3-d4e5","message":"hello"}' \
    '{"to":"worker [3fa9c1]","message":"hello"}' \
    '{"to":"","message":"hello"}' \
    '{"to":"uds:/tmp/claude-peer-1234.sock","message":"received msg-42"}' \
    '{"to":"uds:/tmp/claude-peer-1234.sock","summary":"receipt","message":"received msg-42","notify_when_idle":false}' \
    '{"to":"researcher","summary":"receipt","message":"hello\nthere","notify_when_idle":true}'; do
    rc=0
    run_send_message "$input" || rc=$?
    [ "$rc" -eq 0 ] || fail "plain peer message must allow, got exit $rc for $input: $(cat "$ERR")"
    [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "plain peer message allow wrote output for $input"
  done
  pass "plain-text SendMessage to named or legacy uds: peers passes with either idle notification value"
}

test_send_message_other_shapes_stay_denied() {
  local input rc
  for input in \
    '{"to":"researcher\nother","message":"hello"}' \
    '{"to":"researcher\rother","message":"hello"}' \
    '{"to":"researcher\n","message":"hello"}' \
    '{"to":"researcher","message":{"type":"shutdown_response","request_id":"r1","approve":true}}' \
    '{"to":"uds:/tmp/x.sock","message":{"type":"plan_approval_response","request_id":"r1","approve":false}}' \
    '{"to":"researcher","message":""}' \
    '{"to":"researcher","notify_when_idle":true}' \
    '{"to":"researcher","message":null}' \
    '{"to":"researcher","message":42}' \
    '{"to":"researcher","message":["hi"]}' \
    '{"to":"researcher","message":"hi","extra":1}' \
    '{"to":["researcher"],"message":"hi"}' \
    '{"to":42,"message":"hi"}' \
    '{"to":null,"message":"hi"}' \
    '{"message":"hi"}' \
    'null' \
    '[]'; do
    rc=0
    run_send_message "$input" || rc=$?
    [ "$rc" -eq 2 ] || fail "SendMessage shape must stay denied, got exit $rc for $input"
    jq -e '.systemMessage | contains("blocked tool: SendMessage")' "$ERR" >/dev/null 2>&1 \
      || fail "SendMessage deny lost its tool name for $input: $(cat "$ERR")"
  done
  # The CLI form carries no tool input, so it can never prove a peer reply.
  expect_deny "SendMessage without tool input" SendMessage
  pass "multiline recipients, structured or missing messages, extra keys, and uninspectable SendMessage calls stay denied"
}

test_peer_messaging_scope_is_unchanged() {
  local root payload rc expected
  for root in "$PRIMARY" "$TMP_ROOT/second" "$TMP_ROOT/child"; do
    for payload in \
      '{"tool_name":"SendMessage","tool_input":{"to":"researcher","message":"receipt","notify_when_idle":true}}' \
      '{"tool_name":"ListAgents","tool_input":{}}' \
      '{"tool_name":"SendMessage","tool_input":{"to":"researcher","message":{"type":"shutdown_response"}}}' \
      '{"tool_name":"Agent","tool_input":{"prompt":"go"}}'; do
      expected=0
      if [ "$root" != "$TMP_ROOT/child" ]; then
        case "$payload" in
          *shutdown_response*|*'"tool_name":"Agent"'*) expected=2 ;;
        esac
      fi
      rc=0
      printf '%s' "$payload" \
        | FM_ROOT_OVERRIDE="$root" FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
          "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
      [ "$rc" -eq "$expected" ] || fail "scope $root expected $expected, got $rc for $payload"
      [ ! -s "$OUT" ] || fail "Claude scope case wrote stdout for $payload"
      if [ "$expected" -eq 0 ]; then
        [ ! -s "$ERR" ] || fail "scope allow wrote stderr for $payload"
      fi
    done
  done
  pass "primary and secondmate enforce peer-message safety; worker hook stays inert without changing its status/inbox-only role contract"
}

test_malformed_transport_fails_open() {
  local rc payload
  for payload in '{not-json' '' '{}' '{"tool_name":null}'; do
    rc=0
    : > "$OUT"; : > "$ERR"
    printf '%s' "$payload" \
      | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
        "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
    [ "$rc" -eq 0 ] || fail "malformed transport must fail open, payload '$payload' gave exit $rc"
    [ ! -s "$OUT" ] || fail "fail-open path wrote stdout for payload '$payload'"
  done
  pass "malformed, empty, and tool-name-less payloads fail open rather than blocking every tool call"
}

test_missing_jq_stdin_transport_fails_open() {
  local fakebin="$TMP_ROOT/no-jq-bin" bash_bin cat_bin rc=0
  bash_bin=$(command -v bash) || fail "test needs bash to simulate the hook shebang"
  cat_bin=$(command -v cat) || fail "test needs cat to feed stdin without jq"
  mkdir -p "$fakebin"
  ln -sf "$bash_bin" "$fakebin/bash"
  ln -sf "$cat_bin" "$fakebin/cat"
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"tool_name":"Agent"}' \
    | env PATH="$fakebin" FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "missing jq transport must fail open, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "missing jq fail-open path wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "missing jq fail-open path wrote stderr: $(cat "$ERR")"
  pass "missing jq for stdin transport fails open rather than denying every tool call"
}

test_guard_denies_every_currently_known_delegation_tool
test_guard_denies_hypothetical_future_tools
test_guard_allows_ordinary_and_observe_only_tools
test_guard_allows_session_local_todo_tools
test_plan_only_exclusion_is_exact_name
test_guard_never_classifies_mcp_tools
test_deny_message_defers_to_intake_classification
test_escape_hatch_allows_deliberate_use
test_task_worktree_and_non_firstmate_repo_are_inert
test_secondmate_home_is_in_scope
test_stdin_transports_and_output_shapes
test_send_message_peer_message_is_allowed
test_send_message_other_shapes_stay_denied
test_peer_messaging_scope_is_unchanged
test_malformed_transport_fails_open
test_missing_jq_stdin_transport_fails_open
