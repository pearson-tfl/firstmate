#!/usr/bin/env bash
# tests/fm-session-start-holder.test.sh - session start, the deferred startup
# sweep and bootstrap under a named session-lock holder (FM_LOCK_HOLDER), and
# the Claude-main fallback.
#
# Every case drives the real bin/fm-session-start.sh, bin/fm-lock.sh,
# bin/fm-startup-network.sh, bin/fm-bootstrap.sh, bin/fm-sessionstart-run.sh,
# bin/fm-turnend-guard.sh or bin/fm-inbox.sh against an isolated synthetic home.
# A second Claude session is a real process whose executable is named claude,
# with CLAUDE_PID set to it, so the ancestry walk finds a live harness.
# shellcheck disable=SC2016 # single quotes are deliberate: the fixture child expands them
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

SESSION_START="$ROOT/bin/fm-session-start.sh"
LOCK_SH="$ROOT/bin/fm-lock.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-session-start-holder)
trap fm_test_cleanup EXIT
fm_git_identity fmtest fmtest@example.invalid

HARNESS_BIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$HARNESS_BIN/claude"
NAMED_CLAUDE="$HARNESS_BIN/claude"

# new_world <name>: a throwaway firstmate root on main plus an empty home and a
# fakebin holding every tool bootstrap detects. Echoes "<root>|<home>|<fakebin>".
new_world() {
  local w="$TMP_ROOT/$1" root home fakebin
  root="$w/root"; home="$w/home"; fakebin="$w/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  fm_fake_exit0 "$fakebin" tmux node chrome-devtools-axi gh
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.80
  fm_fake_version_tool "$fakebin" gh-axi FM_FAKE_GH_AXI_VERSION 0.1.29
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = get ] && [ "${2:-}" = --help ] && printf '%s\n' 'Usage: treehouse get [--lease]'
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && printf '%s\n' 'no-mistakes version v1.46.0 (fake) 2026-06-27T00:02:18Z'
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/no-mistakes"
  printf '%s|%s|%s\n' "$root" "$home" "$fakebin"
}

# Session start as a named holder: a per-command FM_LOCK_HOLDER prefix and no
# harness in the environment, which is how pocock runs it.
start_as() {  # <name> <root> <home> <fakebin> [session-start args...]
  local name=$1 root=$2 home=$3 fakebin=$4
  shift 4
  env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u PI_CODING_AGENT \
    -u FM_PI_HARNESS -u GROK_AGENT -u FM_SUPERVISION_MODEL \
    FM_LOCK_HOLDER="$name" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    PATH="$fakebin:$BASE_PATH" "$SESSION_START" "$@"
}

# An unnamed Claude session: <command> runs inside a live claude-named process.
in_claude() {  # <root> <home> <fakebin> <command> [env assignments...]
  local root=$1 home=$2 fakebin=$3 command=$4
  shift 4
  env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u FM_LOCK_HOLDER -u PI_CODING_AGENT \
    -u FM_PI_HARNESS -u GROK_AGENT -u FM_SUPERVISION_MODEL \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$BASE_PATH" \
    SESSION_START="$SESSION_START" LOCK_SH="$LOCK_SH" ROOT="$ROOT" "$@" \
    "$NAMED_CLAUDE" -c "export CLAUDE_PID=\$\$; $command; printf 'rc=%s\n' \"\$?\""
}

wait_network() {  # <root> <home>
  FM_HOME="$2" FM_ROOT_OVERRIDE="$1" "$ROOT/bin/fm-startup-network.sh" wait 30 >/dev/null 2>&1 || true
}

test_named_holder_session_start_on_a_free_lock() {
  local rec root home fakebin out
  rec=$(new_world free); IFS='|' read -r root home fakebin <<<"$rec"
  append_wake "$home/state" signal task-a "done: drained by pocock" || fail "seed wake failed"
  out=$(start_as pocock "$root" "$home" "$fakebin" 2>&1)
  wait_network "$root" "$home"
  assert_equals "holder:pocock" "$(head -n 1 "$home/state/.lock")" "pocock's start must record holder:pocock"
  assert_contains "$out" "lock acquired: holder pocock" "the digest must show the named claim"
  assert_not_contains "$out" "READ-ONLY SESSION" "pocock must get no read-only banner"
  assert_not_contains "$out" "skipped (read-only session)" "the wake drain must run"
  assert_contains "$out" "drained by pocock" "the drain must present the queued wake"
  assert_contains "$(cat "$home/state/.startup-network.status" 2>/dev/null)" "locked=1" \
    "the startup sweeps must run locked"
  pass "test 1: pocock's session start on a free lock claims holder:pocock, no banner, drain and sweeps run"
}

bootstrap_network_as_lock() {  # <root> <home> <fakebin> <expected line 1>
  env -u FM_LOCK_HOLDER FM_HOME="$2" FM_ROOT_OVERRIDE="$1" PATH="$3:$BASE_PATH" \
    FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_NETWORK_LOCK_PID="$4" "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

test_startup_sweep_and_bootstrap_are_authorised_under_a_named_holder() {
  local rec root home fakebin out status
  rec=$(new_world sweep); IFS='|' read -r root home fakebin <<<"$rec"
  printf 'holder:pocock\n' > "$home/state/.lock"
  out=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_LOCK_HOLDER=pocock FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-startup-network.sh" run --locked 1 2>&1)
  status=$(cat "$home/state/.startup-network.status" 2>/dev/null)
  assert_contains "$status" "locked=1" "the sweep worker must keep mutation authority under holder:pocock"
  assert_contains "$status" "phases=probe,sweeps" "the sweeps must run, not just the probe"
  assert_contains "$status" "lock_pid=holder:pocock" "the worker must record the holder it re-checks"
  assert_not_contains "$out$(cat "$home/state/.startup-network.out" 2>/dev/null)" "holder changed" \
    "no sweep may be skipped as a changed holder"

  out=$(bootstrap_network_as_lock "$root" "$home" "$fakebin" holder:pocock)
  assert_not_contains "$out" "the recorded fleet lock holder changed" \
    "bootstrap's clone refresh must be authorised while line 1 still names pocock"
  printf 'holder:claude\n' > "$home/state/.lock"
  out=$(bootstrap_network_as_lock "$root" "$home" "$fakebin" holder:pocock)
  assert_contains "$out" "the recorded fleet lock holder changed before project clone refresh" \
    "bootstrap must still refuse once line 1 names another holder"
  pass "test 5: the startup sweep and bootstrap's clone refresh are authorised under holder:pocock, and refused once it changes"
}

test_named_holder_session_start_on_a_free_lock
test_startup_sweep_and_bootstrap_are_authorised_under_a_named_holder

echo "# fm-session-start-holder.test.sh: all assertions passed"
