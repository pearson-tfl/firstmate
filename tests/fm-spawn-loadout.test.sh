#!/usr/bin/env bash
# tests/fm-spawn-loadout.test.sh - a claude crewmate starts on its loadout
# launch string, and the workflows lever decides whether it may start a
# workflow.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake pane and a real isolated git worktree, with a stub loadout
# command standing in for config/loadout-command, then EXECUTE the launch
# command the pane received with the claude binary replaced by a probe that
# prints the argv and the one environment fact it was started with.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-loadout)

# make_case <name> <id>
# Sets CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG.
make_case() {
  local name=$1 id=$2
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  PANE_LOG="$CASE_DIR/pane.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
}

# install_loadout_stub [exit-code]
# A loadout command that records its argv and prints the --line pro forma for
# the role it was asked about: its settings are the caller's base settings with
# the role's skill posture and a contrary disableWorkflows laid over them, as
# the real launch.py lays a role's launch settings over the base.
install_loadout_stub() {
  local code=${1:-0} tools=${2-Bash,Read,Edit} sources=${3:-project,local} perm=${4-'"--permission-mode", "auto", '} extra=${5:-} stub="$CASE_DIR/loadout-line"
  cat > "$stub" <<PY
#!/usr/bin/env python3
import json, sys
open("$CASE_DIR/loadout.argv", "w").write("\n".join(sys.argv[1:]) + "\n")
if $code:
    sys.stderr.write("role is unknown\n")
    sys.exit($code)
args = sys.argv[1:]
base = json.loads(args[args.index("--base-settings") + 1])
base.update({"skillOverrides": {"tdd": "off"}, "disableWorkflows": False$extra})
print(json.dumps({
    "model": "role-model", "effort": "max", "tools": "$tools",
    "settings": json.dumps(base), "mcp": json.dumps({"mcpServers": {"fetch": {"command": "fetch-mcp"}}}),
    "standing": False, "system_text": "lane-context.md", "system_text_loading": "append",
    "setting_sources": "$sources",
    "permission_args": [$perm"--allowedTools", "Bash(git:*)"],
    "plugin_args": ["--plugin-dir", "/plugins/seo"], "design_args": []}))
PY
  chmod +x "$stub"
  printf '%s\n' "$stub" > "$HOME_DIR/config/loadout-command"
}

install_claude_probe() {
  cat > "$FAKEBIN_DIR/claude" <<'SH'
#!/bin/sh
printf 'ENV_DISABLE_WORKFLOWS=%s\n' "${CLAUDE_CODE_DISABLE_WORKFLOWS-unset}"
printf 'ENV_NO_COLOR=%s ENV_FORCE_COLOR=%s\n' "${NO_COLOR-unset}" "${FORCE_COLOR-unset}"
for a in "$@"; do printf 'ARG=%s\n' "$a"; done
SH
  chmod +x "$FAKEBIN_DIR/claude"
}

run_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# What the agent process received: run the emitted launch in a synthetic pane
# whose environment carries the contrary workflows value and a colour-off
# setting, so a launch that merely inherited the pane would be caught.
probe_output() {
  install_claude_probe
  env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
    TMUX=synthetic-pane CLAUDE_CODE_DISABLE_WORKFLOWS="$1" NO_COLOR=1 FORCE_COLOR=0 \
    /bin/sh -c "$(cat "$LAUNCH_LOG")"
}

# arg_after <probe-output> <flag>: the argument that follows <flag>.
arg_after() {
  printf '%s\n' "$1" | awk -v f="ARG=$2" 'hit { sub(/^ARG=/, ""); print; exit } $0 == f { hit = 1 }'
}

settings_key() {  # <probe-output> <jq-path>
  arg_after "$1" --settings | jq -c "$2"
}

meta_value() { grep "^$2=" "$1/state/$3.meta" | head -n 1 | cut -d= -f2-; }

test_spawn_starts_on_the_loadout_launch_string() {
  local out status seen
  make_case loadout lo-a1
  install_loadout_stub
  out=$(run_spawn lo-a1 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude --loadout implement)
  status=$?
  expect_code 0 "$status" "a claude spawn with a loadout role should succeed: $out"
  assert_equals "implement" "$(arg_after "$(sed "s/^/ARG=/" "$CASE_DIR/loadout.argv")" --role)" \
    "the loadout command should be asked for the named role"
  assert_contains "$(head -n 1 "$CASE_DIR/loadout.argv")" "--line" \
    "the loadout command should be asked for its --line pro forma"
  assert_equals "$WT_DIR" "$(arg_after "$(sed 's/^/ARG=/' "$CASE_DIR/loadout.argv")" --repo)" \
    "the loadout should resolve for the crewmate's own worktree"
  seen=$(probe_output 0) || fail "the emitted loadout launch failed to run: $seen"
  assert_equals "Bash,Read,Edit" "$(arg_after "$seen" --tools)" "the role's tool list should reach the agent"
  assert_equals '{"mcpServers":{"fetch":{"command":"fetch-mcp"}}}' "$(arg_after "$seen" --mcp-config | jq -c .)" \
    "the role's MCP map should reach the agent"
  # --mcp-config is variadic, so the boolean must stand directly after its value.
  assert_equals "ARG=--strict-mcp-config" "$(printf '%s\n' "$seen" | grep -A2 -x 'ARG=--mcp-config' | sed -n 3p)" \
    "--strict-mcp-config should directly follow the MCP map"
  assert_equals "project,local" "$(arg_after "$seen" --setting-sources)" "the role's settings sources should reach the agent"
  assert_equals "Bash(git:*)" "$(arg_after "$seen" --allowedTools)" "the role's allow list should reach the agent"
  assert_equals "/plugins/seo" "$(arg_after "$seen" --plugin-dir)" "the role's plugin arguments should reach the agent"
  printf '%s\n' "$seen" | grep -qx 'ARG=--dangerously-skip-permissions' \
    || fail "Firstmate's own permission flag should stand"
  printf '%s\n' "$seen" | grep -qx 'ARG=--permission-mode' \
    && fail "the role's permission mode should not replace Firstmate's"
  assert_equals '"off"' "$(settings_key "$seen" .feedbackDrafts)" "Firstmate's own settings should survive under the role's"
  assert_equals '{"tdd":"off"}' "$(settings_key "$seen" .skillOverrides)" "the role's skill posture should reach the agent"
  assert_equals "implement" "$(meta_value "$HOME_DIR" loadout lo-a1)" "the task record should name the loadout role"
  pass "a claude crewmate spawned with a loadout role starts on that role's launch string"
}

test_loadout_model_and_effort_stay_firstmates() {
  local out status seen
  make_case loadout-pins lo-b1
  install_loadout_stub
  out=$(run_spawn lo-b1 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude --loadout implement --model opus --effort medium)
  status=$?
  expect_code 0 "$status" "a loadout spawn with Firstmate's own model and effort should succeed: $out"
  seen=$(probe_output 0) || fail "the emitted launch failed to run"
  assert_equals "opus" "$(arg_after "$seen" --model)" "Firstmate's model axis should stand over the role's pin"
  assert_equals "medium" "$(arg_after "$seen" --effort)" "Firstmate's effort axis should stand over the role's pin"
  printf '%s\n' "$seen" | grep -q 'role-model' && fail "the role's model pin should not reach the agent"
  pass "a loadout launch keeps Firstmate's model and effort axes"
}

test_loadout_refusals() {
  local out status
  make_case loadout-noconfig lo-c1
  out=$(run_spawn lo-c1 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude --loadout implement)
  status=$?
  expect_code 1 "$status" "a loadout role without config/loadout-command should be refused: $out"
  assert_contains "$out" "config/loadout-command" "the refusal should name the missing config"
  [ -s "$LAUNCH_LOG" ] && fail "a refused loadout spawn must launch nothing"

  make_case loadout-pi lo-c2
  install_loadout_stub
  out=$(run_spawn lo-c2 "$PROJ_DIR" --mode no-mistakes --yolo off --harness codex --loadout implement)
  status=$?
  expect_code 1 "$status" "a loadout role on a non-claude harness should be refused: $out"
  assert_contains "$out" "--loadout" "the refusal should name the flag"

  make_case loadout-fails lo-c3
  install_loadout_stub 2
  out=$(run_spawn lo-c3 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude --loadout nosuch)
  status=$?
  expect_code 1 "$status" "a loadout command that fails should refuse the spawn: $out"
  assert_contains "$out" "role is unknown" "the refusal should carry the loadout command's own error"
  [ -s "$LAUNCH_LOG" ] && fail "a failed loadout must launch nothing"

  make_case loadout-notools lo-c4
  install_loadout_stub 0 ''
  out=$(run_spawn lo-c4 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude --loadout implement)
  status=$?
  expect_code 1 "$status" "a loadout line with an empty tool list should refuse the spawn: $out"
  [ -s "$LAUNCH_LOG" ] && fail "an empty tool list must launch nothing"
  pass "a loadout spawn refuses a missing command, a non-claude harness, a failing command, and an empty tool list"
}

test_workflows_lever() {
  local out status seen
  make_case wf-default wf-a1
  out=$(run_spawn wf-a1 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude)
  status=$?
  expect_code 0 "$status" "a plain claude spawn should succeed: $out"
  seen=$(probe_output 0) || fail "the emitted launch failed to run"
  assert_contains "$seen" "ENV_DISABLE_WORKFLOWS=1" "workflows should be off by default, whatever the pane holds"
  assert_contains "$seen" "ENV_NO_COLOR=unset ENV_FORCE_COLOR=unset" "a claude launch should clear an inherited colour-off setting"
  assert_equals "true" "$(settings_key "$seen" .disableWorkflows)" "the default launch settings should turn workflows off"
  assert_equals "off" "$(meta_value "$HOME_DIR" workflows wf-a1)" "the task record should name the lever"

  make_case wf-on wf-b1
  out=$(run_spawn wf-b1 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude --workflows on)
  status=$?
  expect_code 0 "$status" "a claude spawn with workflows on should succeed: $out"
  seen=$(probe_output 1) || fail "the emitted launch failed to run"
  assert_contains "$seen" "ENV_DISABLE_WORKFLOWS=unset" "workflows on should clear an inherited off switch"
  assert_contains "$seen" "ENV_NO_COLOR=unset ENV_FORCE_COLOR=unset" "workflows on should still clear an inherited colour-off setting"
  assert_equals "false" "$(settings_key "$seen" .disableWorkflows)" "workflows on should turn them on in the launch settings"

  make_case wf-config wf-c1
  printf 'on\n' > "$HOME_DIR/config/crew-workflows"
  out=$(run_spawn wf-c1 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude)
  expect_code 0 "$?" "a spawn under config/crew-workflows should succeed: $out"
  assert_equals "on" "$(meta_value "$HOME_DIR" workflows wf-c1)" "config/crew-workflows should set the default"
  make_case wf-flag-wins wf-c2
  printf 'on\n' > "$HOME_DIR/config/crew-workflows"
  out=$(run_spawn wf-c2 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude --workflows off)
  expect_code 0 "$?" "an explicit lever should succeed: $out"
  assert_equals "off" "$(meta_value "$HOME_DIR" workflows wf-c2)" "the per-spawn lever should win over the home default"

  make_case wf-loadout wf-d1
  install_loadout_stub
  out=$(run_spawn wf-d1 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude --loadout research)
  expect_code 0 "$?" "a loadout spawn with the default lever should succeed: $out"
  seen=$(probe_output 0) || fail "the emitted launch failed to run"
  assert_equals "true" "$(settings_key "$seen" .disableWorkflows)" "the lever should win over a role's own workflows setting"
  assert_contains "$seen" "ENV_DISABLE_WORKFLOWS=1" "the lever's off switch should ride a loadout launch too"
  assert_contains "$seen" "ENV_NO_COLOR=unset ENV_FORCE_COLOR=unset" "a loadout launch should clear an inherited colour-off setting"
  assert_equals "Bash,Read,Edit" "$(arg_after "$seen" --tools)" "workflows off should leave the role's tool list alone"

  make_case wf-loadout-on wf-d2
  install_loadout_stub
  out=$(run_spawn wf-d2 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude --loadout implement --workflows on)
  expect_code 0 "$?" "a loadout spawn with workflows on should succeed: $out"
  seen=$(probe_output 1) || fail "the emitted launch failed to run"
  assert_equals "Bash,Read,Edit,Workflow" "$(arg_after "$seen" --tools)" \
    "workflows on should add the Workflow tool to a role's tool list"
  make_case wf-loadout-has wf-d3
  install_loadout_stub 0 Bash,Workflow,Read
  out=$(run_spawn wf-d3 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude --loadout implement --workflows on)
  expect_code 0 "$?" "a loadout spawn whose role lists Workflow should succeed: $out"
  seen=$(probe_output 1) || fail "the emitted launch failed to run"
  assert_equals "Bash,Workflow,Read" "$(arg_after "$seen" --tools)" "a role that lists Workflow should keep its list as is"

  make_case wf-bad wf-e1
  out=$(run_spawn wf-e1 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude --workflows maybe)
  status=$?
  expect_code 1 "$status" "an unknown lever value should be refused: $out"
  [ -s "$LAUNCH_LOG" ] && fail "a refused lever value must launch nothing"
  pass "the workflows lever is off by default, on by flag or home default, and wins over a role's setting; every claude launch clears NO_COLOR and FORCE_COLOR"
}

# Approval failover writes config/claude-permission-mode=auto; a role that
# asks for bypass must not bring it back.
test_loadout_keeps_firstmates_permission_mode() {
  local out seen
  make_case loadout-auto lo-g1
  install_loadout_stub 0 Bash,Read project,local '"--dangerously-skip-permissions", '
  printf 'auto\n' > "$HOME_DIR/config/claude-permission-mode"
  out=$(run_spawn lo-g1 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude --loadout implement)
  expect_code 0 "$?" "a loadout spawn under auto should succeed: $out"
  seen=$(probe_output 0) || fail "the emitted launch failed to run"
  assert_equals "auto" "$(arg_after "$seen" --permission-mode)" "config/claude-permission-mode should stand over the role"
  printf '%s\n' "$seen" | grep -qx 'ARG=--dangerously-skip-permissions' \
    && fail "a role's bypass flag must not return after approval failover"
  assert_equals "Bash(git:*)" "$(arg_after "$seen" --allowedTools)" "the role's allow list should still reach the agent"
  assert_equals "auto" "$(meta_value "$HOME_DIR" approval_mode lo-g1)" "the record should report the mode actually launched"
  make_case loadout-attribution lo-g3
  install_loadout_stub 0 Bash,Read all '' ', "attribution": {"commit": "role trailer"}, "feedbackDrafts": "on"'
  out=$(run_spawn lo-g3 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude --loadout implement)
  expect_code 0 "$?" "a loadout spawn whose role sets attribution should succeed: $out"
  seen=$(probe_output 0) || fail "the emitted launch failed to run"
  assert_equals '""' "$(settings_key "$seen" .attribution.commit)" "Firstmate's attribution policy should win over the role's"
  assert_equals '"off"' "$(settings_key "$seen" .feedbackDrafts)" "Firstmate's feedbackDrafts should win over the role's"

  make_case loadout-modeforms lo-g2
  install_loadout_stub 0 Bash,Read project,local '"--disallowedTools", "WebFetch", "--permission-mode=plan", '
  out=$(run_spawn lo-g2 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude --loadout implement)
  expect_code 0 "$?" "a loadout spawn with mixed mode forms should succeed: $out"
  seen=$(probe_output 0) || fail "the emitted launch failed to run"
  assert_equals "WebFetch" "$(arg_after "$seen" --disallowedTools)" "the role's deny list should reach the agent"
  printf '%s\n' "$seen" | grep -q '^ARG=--permission-mode' \
    && fail "the = form of a role mode should not reach the agent"
  printf '%s\n' "$seen" | grep -qx 'ARG=--dangerously-skip-permissions' \
    || fail "Firstmate's own mode should stand"
  pass "a loadout launch keeps config/claude-permission-mode and drops the role's own mode in either form"
}

test_loadout_refuses_to_drop_worker_hooks() {
  local out
  make_case loadout-nolocal lo-h1
  install_loadout_stub 0 Bash,Read user,project
  out=$(run_spawn lo-h1 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude --loadout implement)
  expect_code 1 "$?" "settings sources without local should be refused: $out"
  [ -s "$LAUNCH_LOG" ] && fail "a line that drops local settings must launch nothing"
  make_case loadout-nohooks lo-h2
  install_loadout_stub 0 Bash,Read all '' ', "disableAllHooks": True'
  out=$(run_spawn lo-h2 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude --loadout implement)
  expect_code 1 "$?" "settings with disableAllHooks should be refused: $out"
  assert_contains "$out" "worker hooks" "the refusal should say the worker hooks would be lost"
  assert_not_contains "$out" "skillOverrides" "the refusal must not echo the line's settings"
  assert_contains "$out" "disableAllHooks" "the refusal should name the cause that fired"
  pass "a loadout line that would drop Firstmate's worker hooks is refused without echoing it"
}

test_more_refusals() {
  local out status
  make_case loadout-notjson lo-f1
  printf '#!/bin/sh\necho not-json\n' > "$CASE_DIR/loadout-line"
  chmod +x "$CASE_DIR/loadout-line"
  printf '%s\n' "$CASE_DIR/loadout-line" > "$HOME_DIR/config/loadout-command"
  out=$(run_spawn lo-f1 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude --loadout implement)
  status=$?
  expect_code 1 "$status" "a line that is not the --line JSON should refuse the spawn: $out"
  assert_contains "$out" "not the --line JSON" "the refusal should name the unreadable line"
  assert_not_contains "$out" "not-json" "the refusal must not echo the line"
  [ -s "$LAUNCH_LOG" ] && fail "an unreadable line must launch nothing"

  make_case loadout-noexec lo-f2
  install_loadout_stub
  chmod -x "$CASE_DIR/loadout-line"
  out=$(run_spawn lo-f2 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude --loadout implement)
  expect_code 1 "$?" "a non-executable loadout command should be refused: $out"
  assert_contains "$out" "config/loadout-command" "the refusal should name the config"

  make_case wf-badconfig lo-f3
  printf 'sometimes\n' > "$HOME_DIR/config/crew-workflows"
  out=$(run_spawn lo-f3 "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude)
  expect_code 1 "$?" "a bad config/crew-workflows value should be refused: $out"
  assert_contains "$out" "config/crew-workflows must be on or off" "the refusal should name the config"

  make_case wf-codex lo-f4
  out=$(run_spawn lo-f4 "$PROJ_DIR" --mode no-mistakes --yolo off --harness codex --workflows on)
  expect_code 1 "$?" "--workflows on a non-claude harness should be refused: $out"
  assert_contains "$out" "--workflows applies to a claude crewmate" "the refusal should name the flag"

  make_case wf-secondmate lo-f5
  out=$(run_spawn lo-f5 "$CASE_DIR" --secondmate --workflows on)
  expect_code 1 "$?" "--workflows on a secondmate should be refused: $out"
  assert_contains "$out" "a secondmate takes neither" "the refusal should name the secondmate rule"

  make_case wf-relaunch lo-f6
  out=$(run_spawn lo-f6 --relaunch --loadout implement)
  expect_code 1 "$?" "--loadout as a relaunch override should be refused: $out"
  assert_contains "$out" "cannot override them" "the refusal should say the recorded values stand"
  [ -s "$LAUNCH_LOG" ] && fail "a refused lever must launch nothing"
  pass "unreadable lines, a non-executable command, a bad home default, and misplaced levers are refused"
}

test_spawn_starts_on_the_loadout_launch_string
test_loadout_model_and_effort_stay_firstmates
test_loadout_refusals
test_workflows_lever
test_more_refusals
test_loadout_keeps_firstmates_permission_mode
test_loadout_refuses_to_drop_worker_hooks
