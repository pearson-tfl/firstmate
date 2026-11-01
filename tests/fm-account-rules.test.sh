#!/usr/bin/env bash
# Behavior tests for rules-based Claude account selection through cswap
# (config/account-rules, bin/fm-account-rules.sh, bin/fm-worker-account-lib.sh).
#
# Each case drives the real fm-spawn.sh through the shared fake tmux, which
# records the launch command, then runs that command in a synthetic pane. The
# fake cswap answers `list --json` from a per-case account list and, like the
# real `cswap run`, execs the `claude` on PATH under that account's own profile
# root, or with the environment unchanged when the account is the active
# default login. The fake claude answers `auth status` from the root's stored
# login and records the root a launched worker receives.
# tests/fm-account-rules-live-e2e.test.sh proves those answers against the real
# cswap and claude.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-account-rules)
unset LAVISH_AXI_HOST ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# new_case <name> -> sets CASE HOME_DIR PROJ WT FAKEBIN
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/projects/${2:-demo}"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  fm_test_cswap_fakes "$FAKEBIN" "$CASE"
  fm_test_spawn_home "$HOME_DIR" claude
  mkdir -p "$CASE/projects"
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  mkdir -p "$HOME_DIR/user-home/.claude"
  printf '{}\n' > "$HOME_DIR/user-home/.claude/.credentials.json"
  : > "$CASE/launch.log"
}

# write_rules <line>...: writes config/account-rules and records it approved,
# the way bin/fm-account-rules.sh approve does after John confirms.
write_rules() {
  printf '%s\n' "$@" > "$HOME_DIR/config/account-rules"
  approve_rules
}

# approve_rules: John's confirmation at a real terminal, driven through a pty.
approve_rules() {
  local out
  out=$(HOME="$HOME_DIR/user-home" FM_HOME="$HOME_DIR" python3 -I "$ROOT_DIR/tests/fixtures/account-rules/pty-answer.py" \
    --answer-from-prompt "$ROOT_DIR/bin/fm-account-rules.sh" approve 2>&1) \
    || fail "approving the rules at a terminal should succeed: $out"
}

spawn_ship() {
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$CASE/launch.log"
  HOME="$HOME_DIR/user-home" FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off "$@"
}

run_pane() {
  env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN:$PATH" TERM=xterm \
    bash -c "$(cat "$CASE/launch.log")" || fail "the recorded launch failed in the synthetic pane"
}

assert_refused_before_launch() {
  local id=$1 out=$2 needle=$3
  assert_contains "$out" "$needle" "the refusal should say: $needle"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not publish a task record"
  [ ! -s "$CASE/launch.log" ] || fail "a refused spawn must not launch a worker: $(cat "$CASE/launch.log")"
}

# A relaunch's switch line is covered in tests/fm-control-relaunch.test.sh,
# whose fake tmux models stopping the running agent.
switch_lines() {
  if [ -f "$HOME_DIR/data/account-switches.log" ]; then
    wc -l < "$HOME_DIR/data/account-switches.log" | tr -d ' '
  else
    echo 0
  fi
}

test_rules_pick_the_least_used_allowed_account_and_never_a_forbidden_one() {
  local out rc id=rules-pick
  new_case pick
  # Account 3 is the least used, so only the rule keeps it out.
  fm_test_cswap_accounts "$CASE" 1 1:10:40 2:5:30 3:0:0 4:2:16
  write_rules '# John owns this file' 'forbid 3'
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a spawn under approved rules should succeed: $out"
  assert_contains "$out" "account=cswap:4" "the spawn should report the least-used allowed account"
  assert_grep "account=cswap:4" "$HOME_DIR/state/$id.meta" "the task record should carry the chosen account"
  assert_no_grep '^3$' "$CASE/cswap-runs" "a forbidden account must never be prepared through cswap"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/sessions/4" "$CASE/claude-worker" \
    "the worker should run in account 4's own cswap profile"
  assert_absent "$CASE/cswap-global-switches" "selection must never switch the global login"
  [ "$(switch_lines)" = 1 ] || fail "one pick should write exactly one report line: $(cat "$HOME_DIR/data/account-switches.log" 2>/dev/null)"
  assert_grep "task=$id from=none to=cswap:4" "$HOME_DIR/data/account-switches.log" \
    "the report line should name the task and both accounts"
  pass "rules pick the least-used allowed account, skip a forbidden one, and report the pick"
}

test_a_project_rule_limits_the_choice_to_its_accounts() {
  local out rc
  new_case project bb-signal-prototype
  fm_test_cswap_accounts "$CASE" 1 1:0:1 2:0:2 4:3:30 5:1:20
  write_rules 'forbid 3' 'project bb-signal-prototype 5 4' 'project other 1'
  out=$(spawn_ship rules-project); rc=$?
  expect_code 0 "$rc" "a project-scoped spawn should succeed: $out"
  assert_contains "$out" "account=cswap:5" "the project's own accounts should win over less-used others"

  new_case project-case BB-Signal-Prototype
  fm_test_cswap_accounts "$CASE" 1 1:0:1 4:3:30 5:1:20
  write_rules 'project bb-signal-prototype 5 4'
  out=$(spawn_ship rules-project-case); rc=$?
  expect_code 0 "$rc" "a project whose directory differs in case should succeed: $out"
  assert_contains "$out" "account=cswap:5" "the project rule should match its directory without regard to case"
  pass "a project rule limits the choice to that project's accounts"
}

test_the_per_home_claude_setting_is_refused_under_rules() {
  local out rc id=rules-pin
  new_case pin
  fm_test_cswap_accounts "$CASE" 1 1:0:0 2:0:0
  write_rules 'forbid 2'
  printf 'ordinary\n' > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id" 2>&1); rc=$?
  expect_code 1 "$rc" "rules plus a per-home Claude setting should refuse: $out"
  assert_refused_before_launch "$id" "$out" "config/account-rules replaces the per-home Claude account setting"
  pass "the per-home Claude account setting is refused, not used, when rules exist"
}

test_a_rules_change_without_john_approval_refuses() {
  local out rc id=rules-unapproved
  new_case unapproved
  fm_test_cswap_accounts "$CASE" 1 1:0:0 2:0:0 3:0:0
  write_rules 'forbid 3'
  printf 'forbid 2\n' > "$HOME_DIR/config/account-rules"
  out=$(spawn_ship "$id" 2>&1); rc=$?
  expect_code 1 "$rc" "an edited, unapproved rules file should refuse: $out"
  assert_refused_before_launch "$id" "$out" "config/account-rules has changed since the captain approved it"
  assert_absent "$CASE/cswap-runs" "an unapproved rules file must not prepare any account"

  rm -f "$HOME_DIR/config/account-rules.approved"
  out=$(spawn_ship "$id" 2>&1); rc=$?
  expect_code 1 "$rc" "a never-approved rules file should refuse: $out"
  assert_refused_before_launch "$id" "$out" "config/account-rules has changed since the captain approved it"

  # No controlling terminal: the approval cannot be given from a tool shell.
  out=$(FM_HOME="$HOME_DIR" perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' \
    "$ROOT_DIR/bin/fm-account-rules.sh" approve </dev/null 2>&1); rc=$?
  expect_code 1 "$rc" "approval with no terminal should refuse: $out"
  assert_contains "$out" "needs the captain at a terminal" "the refusal should say approval needs a terminal"
  assert_absent "$HOME_DIR/config/account-rules.approved" "a refused approval must not record a fingerprint"

  # A wrong confirmation at a terminal is refused too.
  out=$(FM_HOME="$HOME_DIR" python3 -I "$ROOT_DIR/tests/fixtures/account-rules/pty-answer.py" \
    --answer yes "$ROOT_DIR/bin/fm-account-rules.sh" approve 2>&1); rc=$?
  expect_code 1 "$rc" "a wrong confirmation should refuse: $out"
  assert_absent "$HOME_DIR/config/account-rules.approved" "a wrong confirmation must not record a fingerprint"

  approve_rules
  out=$(spawn_ship "$id" 2>&1); rc=$?
  expect_code 0 "$rc" "the same rules should launch once John approves them: $out"
  assert_contains "$out" "account=cswap:1" "the approved rules should now govern the choice"

  # Removing the rules file while its approval remains is a change too.
  rm -f "$HOME_DIR/config/account-rules" "$CASE/cswap-runs"
  out=$(spawn_ship rules-removed 2>&1); rc=$?
  expect_code 1 "$rc" "a removed rules file with its approval left should refuse: $out"
  assert_refused_before_launch rules-removed "$out" "config/account-rules was removed while the captain's approval of it remains"
  pass "a rules change launches nothing until John approves it at a terminal"
}

test_malformed_rules_refuse() {
  local out rc id=rules-bad
  new_case malformed
  fm_test_cswap_accounts "$CASE" 1 1:0:0
  write_rules 'forbid 3'
  printf 'forbid three\n' > "$HOME_DIR/config/account-rules"
  out=$(FM_HOME="$HOME_DIR" "$ROOT_DIR/bin/fm-account-rules.sh" status 2>&1); rc=$?
  expect_code 1 "$rc" "status should refuse a malformed rules file: $out"
  assert_contains "$out" "line 1 is not" "the refusal should name the bad line"
  pass "a malformed rules file is refused with its line"
}

test_no_headroom_refuses_and_unmeasured_ranks_last() {
  local out rc id=rules-full
  new_case headroom
  fm_test_cswap_accounts "$CASE" 1 1:100:40 2:20:100 3:0:0
  write_rules 'forbid 3'
  out=$(spawn_ship "$id" 2>&1); rc=$?
  expect_code 1 "$rc" "every allowed account at its limit should refuse: $out"
  assert_refused_before_launch "$id" "$out" "allows no cswap account with headroom"

  fm_test_cswap_accounts "$CASE" 1 1:100:40 2:error 4:80:90
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a measured account with headroom should launch: $out"
  assert_contains "$out" "account=cswap:4" "a measured account should rank before an unmeasured one"
  pass "no headroom refuses, and an account cswap cannot measure ranks last"
}

test_the_default_login_account_launches_on_the_default_login() {
  local out rc id=rules-default
  new_case default-login
  fm_test_cswap_accounts "$CASE" 2 1:50:50 2:0:1
  write_rules 'forbid 3'
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "choosing the default login's account should succeed: $out"
  assert_contains "$out" "account=cswap:2" "the least-used account is the default login"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=unset" "$CASE/claude-worker" \
    "cswap runs the default login's account on the default login, so the root must be unset"
  pass "the default login's account launches with the Claude root unset, as cswap runs it"
}

test_rules_pick_the_least_used_allowed_account_and_never_a_forbidden_one
test_a_project_rule_limits_the_choice_to_its_accounts
test_the_per_home_claude_setting_is_refused_under_rules
test_a_rules_change_without_john_approval_refuses
test_malformed_rules_refuse
test_no_headroom_refuses_and_unmeasured_ranks_last
test_the_default_login_account_launches_on_the_default_login

echo "# all fm-account-rules tests passed"
