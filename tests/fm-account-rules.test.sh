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

# make_cswap_fakes <fakebin> <case-dir>
# Log and data paths are written into the fakes because the sign-in check and
# the account probe run them with a cleared environment.
make_cswap_fakes() {
  local fakebin=$1 dir=$2
  cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = auth ] && [ "\${2:-}" = status ]; then
  [ -f "\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/.credentials.json" ]
  exit
fi
printf 'CLAUDE_CONFIG_DIR=%s\n' "\${CLAUDE_CONFIG_DIR-unset}" > '$dir/claude-worker'
SH
  cat > "$fakebin/cswap" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  list)
    [ "\${2:-}" = --json ] || exit 2
    cat '$dir/cswap-list.json'
    ;;
  run)
    num=\$2
    shift 2
    [ "\${1:-}" != -- ] || shift
    printf '%s\n' "\$num" >> '$dir/cswap-runs'
    echo "Launching Account-\$num [session mode]"
    if [ "\$num" = "\$(cat '$dir/cswap-active')" ] && [ -z "\${CLAUDE_CONFIG_DIR:-}" ]; then
      exec claude "\$@"
    fi
    mkdir -p '$dir/sessions/'"\$num"
    [ ! -f '$dir/signed-out-'"\$num" ] || rm -f '$dir/sessions/'"\$num"/.credentials.json
    [ -f '$dir/signed-out-'"\$num" ] || printf '{}\n' > '$dir/sessions/'"\$num"/.credentials.json
    CLAUDE_CONFIG_DIR='$dir/sessions/'"\$num" exec claude "\$@"
    ;;
  switch) printf 'switch\n' >> '$dir/cswap-global-switches'; exit 0 ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/claude" "$fakebin/cswap"
}

# cswap_accounts <active> <num:fiveHour:sevenDay>...
# Writes the fake account list; a usage field of - is omitted, and a whole
# spec of <num>:error marks that account's usage unavailable.
cswap_accounts() {
  local active=$1 spec num five seven sep='' body=''
  shift
  printf '%s\n' "$active" > "$CASE/cswap-active"
  for spec in "$@"; do
    IFS=: read -r num five seven <<<"$spec"
    if [ "$five" = error ]; then
      body="$body$sep{\"number\":$num,\"email\":\"a$num@example.test\",\"active\":false,\"usageStatus\":\"error\"}"
    else
      local usage='' usep=''
      [ "$five" = - ] || { usage="\"fiveHour\":{\"pct\":$five}"; usep=,; }
      [ "$seven" = - ] || usage="$usage$usep\"sevenDay\":{\"pct\":$seven}"
      body="$body$sep{\"number\":$num,\"email\":\"a$num@example.test\",\"active\":$([ "$num" = "$active" ] && echo true || echo false),\"usageStatus\":\"ok\",\"usage\":{$usage}}"
    fi
    sep=,
  done
  printf '{"schemaVersion":1,"activeAccountNumber":%s,"accounts":[%s]}\n' "$active" "$body" > "$CASE/cswap-list.json"
}

# new_case <name> -> sets CASE HOME_DIR PROJ WT FAKEBIN
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/projects/${2:-demo}"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  make_cswap_fakes "$FAKEBIN" "$CASE"
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
  out=$(HOME="$HOME_DIR/user-home" FM_HOME="$HOME_DIR" python3 -I "$ROOT_DIR/tests/fixtures/pty-answer.py" \
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
  cswap_accounts 1 1:10:40 2:5:30 3:0:0 4:2:16
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

test_rules_pick_the_least_used_allowed_account_and_never_a_forbidden_one

echo "# all fm-account-rules tests passed"
