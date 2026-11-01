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
  # A genuine primary root, so the rebuild hook and the Stop guard run here.
  mkdir -p "$root/bin"
  printf 'Synthetic fixture.\n' > "$root/AGENTS.md"
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

# The same on a Pi primary, the harness whose compaction re-emits AGENTS.md.
start_as_pi() {  # <name> <root> <home> <fakebin> [session-start args...]
  local name=$1 root=$2 home=$3 fakebin=$4
  shift 4
  env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u GROK_AGENT -u FM_SUPERVISION_MODEL \
    PI_CODING_AGENT=true FM_PI_HARNESS=pi FM_LOCK_HOLDER="$name" FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$BASE_PATH" "$SESSION_START" "$@"
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

run_hook_as() {  # <name> <root> <home> <fakebin> <source>
  env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u PI_CODING_AGENT \
    -u FM_PI_HARNESS -u GROK_AGENT FM_LOCK_HOLDER="$1" FM_HOME="$3" FM_ROOT_OVERRIDE="$2" \
    PATH="$4:$BASE_PATH" "$ROOT/bin/fm-sessionstart-run.sh" --source "$5" </dev/null
}

test_named_holder_completion_marker_routes_a_rebuild_to_reemit() {
  local rec root home fakebin out
  rec=$(new_world completion); IFS='|' read -r root home fakebin <<<"$rec"
  out=$(start_as pocock "$root" "$home" "$fakebin" 2>&1)
  wait_network "$root" "$home"
  assert_not_contains "$out" "SESSION_START_COMPLETION: not recorded" "pocock's full start must record completion"
  assert_equals "holder:pocock" "$(cat "$home/state/.session-start-complete" 2>/dev/null)" \
    "the completion marker must be the holder name"
  out=$(run_hook_as pocock "$root" "$home" "$fakebin" compact 2>&1)
  wait_network "$root" "$home"
  assert_contains "$out" "SESSION START (CONTEXT RE-EMIT)" "a compact after a completed pocock start must re-emit"
  out=$(run_hook_as pocock "$root" "$home" "$fakebin" clear 2>&1)
  wait_network "$root" "$home"
  assert_contains "$out" "SESSION START (CONTEXT RE-EMIT)" "a second rebuild must still re-emit, not run a full start"
  pass "a pocock start records holder:pocock as its completion marker, so each later rebuild re-emits instead of a full start"
}

test_second_session_while_pocock_holds_main_stays_read_only() {
  local rec root home fakebin out before net_before guard_out
  rec=$(new_world second); IFS='|' read -r root home fakebin <<<"$rec"
  out=$(start_as pocock "$root" "$home" "$fakebin" 2>&1)
  wait_network "$root" "$home"
  assert_equals "holder:pocock" "$(head -n 1 "$home/state/.lock")" "setup: pocock must hold main"
  # No watcher runs in this home (the watcher is stopped), and work is in
  # flight, so a Stop that is not foreign would be held by the guard.
  printf 'project=synthetic\n' > "$home/state/task.meta"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  append_wake "$home/state" signal task-b "done: must stay queued" || fail "seed wake failed"
  before=$(cat "$home/state/.lock"); net_before=$(cat "$home/state/.startup-network.status")

  out=$(in_claude "$root" "$home" "$fakebin" '"$SESSION_START"' CLAUDE_CODE_SESSION_ID=synthetic-second 2>&1)
  assert_contains "$out" "main is held by pocock; read-only" "the second session must be refused by the two-mains guard"
  assert_contains "$out" "READ-ONLY SESSION" "the second session must get the READ-ONLY banner"
  assert_contains "$out" "skipped (read-only session)" "the second session must skip the drain"
  assert_contains "$(cat "$home/state/.wake-queue")" "must stay queued" "the queued wake must remain"
  assert_contains "$out" "Detect-only bootstrap" "bootstrap must run detect-only"
  assert_equals "$net_before" "$(cat "$home/state/.startup-network.status")" "no startup sweep may start"
  assert_equals "$before" "$(cat "$home/state/.lock")" "line 1 must be unchanged"

  guard_out=$(in_claude "$root" "$home" "$fakebin" \
    'printf "%s\n" "{\"session_id\":\"synthetic-second\",\"stop_hook_active\":true}" | "$ROOT/bin/fm-turnend-guard.sh" --claude' \
    CLAUDE_CODE_SESSION_ID=synthetic-second FM_STATE_OVERRIDE="$home/state" 2>&1)
  assert_contains "$guard_out" "rc=0" "the second session's Stop must be allowed"
  assert_contains "$guard_out" "OWNED BY ANOTHER LIVE SESSION" "the Stop must say supervision is owned by another session"
  assert_contains "$guard_out" "lock held by pocock" "the Stop must name the holder"
  assert_equals "$before" "$(cat "$home/state/.lock")" "the Stop must not move line 1"
  pass "test 2: a second session while pocock holds main is refused read-only, skips drain, sweeps and bootstrap mutation, and its Stop is allowed as owned by another session"
}

snapshot() {  # <home> -> lock line 1 and session sidecar
  printf '%s|%s' "$(cat "$1/state/.lock" 2>/dev/null)" "$(cat "$1/state/.lock-session" 2>/dev/null)"
}

test_claude_main_fallback_after_pocock_releases() {
  local rec root home fakebin out before
  rec=$(new_world fallback); IFS='|' read -r root home fakebin <<<"$rec"
  out=$(start_as pocock "$root" "$home" "$fakebin" 2>&1)
  wait_network "$root" "$home"
  out=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_LOCK_HOLDER=pocock FM_HOME="$home" "$LOCK_SH" release 2>&1)
  assert_contains "$out" "lock released: holder pocock" "pocock must release main"

  append_wake "$home/state" signal task-c "done: drained by the claude fallback" || fail "seed wake failed"
  out=$(in_claude "$root" "$home" "$fakebin" '"$SESSION_START"' \
    CLAUDE_CODE_SESSION_ID=synthetic-fallback FM_LOCK_HOLDER=claude 2>&1)
  wait_network "$root" "$home"
  assert_equals "holder:claude" "$(head -n 1 "$home/state/.lock")" "the fallback session must claim as holder:claude"
  assert_contains "$out" "lock acquired: holder claude" "the digest must show the claude claim"
  assert_not_contains "$out" "READ-ONLY SESSION" "the fallback session must get no banner"
  assert_contains "$out" "drained by the claude fallback" "the fallback session must drain the queue"

  before=$(snapshot "$home")
  out=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_LOCK_HOLDER=pocock FM_HOME="$home" \
    "$LOCK_SH" 2>&1; printf 'rc=%s\n' "$?")
  assert_contains "$out" "rc=1" "pocock's re-check must refuse while claude holds main"
  assert_contains "$out" "main is held by claude" "pocock's refusal must name claude"
  assert_equals "$before" "$(snapshot "$home")" "pocock's refused re-check must change nothing"
  pass "test 22: after pocock releases, FM_LOCK_HOLDER=claude claims main with no banner and drains; pocock's re-check refuses, naming claude, unchanged"
}

test_named_holder_pi_compact_keys_its_agents_baseline_to_line_one() {
  local rec root home fakebin out
  rec=$(new_world pi-compact); IFS='|' read -r root home fakebin <<<"$rec"
  out=$(start_as_pi pocock "$root" "$home" "$fakebin" --source startup 2>&1)
  wait_network "$root" "$home"
  assert_equals "holder:pocock" "$(head -n 1 "$home/state/.session-start-agents-baseline" 2>/dev/null)" \
    "a named Pi start must key its AGENTS baseline to holder:pocock"
  out=$(start_as_pi pocock "$root" "$home" "$fakebin" --reemit --source compact 2>&1)
  assert_not_contains "$out" "CURRENT AGENTS.md - INSTRUCTION REFRESH" \
    "an unchanged AGENTS.md must not be re-emitted on a named holder's compact"
  printf 'Synthetic fixture, updated.\n' > "$root/AGENTS.md"
  out=$(start_as_pi pocock "$root" "$home" "$fakebin" --reemit --source compact 2>&1)
  assert_contains "$out" "Synthetic fixture, updated." "a drifted AGENTS.md must still be re-emitted"
  pass "a named holder's Pi compaction compares its AGENTS baseline against .lock line 1, not an ancestry pid"
}

ready_of() {  # <home> [env assignments...] -> "lock.state holder consumer.state reason can_receive"
  local home=$1
  shift
  env -u FM_SUPERVISION_MODEL -u FM_LOCK_HOLDER -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$@" bash "$ROOT/bin/fm-inbox.sh" ready 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); w=d["wake_consumer"]; print(d["lock"]["state"], d["lock"]["holder"], w["state"], w["reason"], d["can_receive"])'
}

# Pinned for a named holder (decided on #5060): a name carries no harness, so
# with FM_SUPERVISION_MODEL unset the inspected home's supervision model is
# unknown and can_receive stays "unknown"; with it set, the watcher verdict
# decides as for any other home.
test_inbox_ready_under_a_named_holder_pins_the_supervision_model() {
  local rec root home fakebin
  rec=$(new_world ready); IFS='|' read -r root home fakebin <<<"$rec"
  start_as pocock "$root" "$home" "$fakebin" >/dev/null 2>&1
  wait_network "$root" "$home"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  assert_equals "held pocock unknown supervision-model-unknown-for-home unknown" "$(ready_of "$home")" \
    "with no FM_SUPERVISION_MODEL a named holder's model and can_receive must be unknown"
  assert_equals "held pocock down stale-beacon False" "$(ready_of "$home" FM_SUPERVISION_MODEL=persistent)" \
    "with FM_SUPERVISION_MODEL set the watcher verdict must decide can_receive"
  pass "fm-inbox ready under holder:pocock: model unknown and can_receive unknown unless FM_SUPERVISION_MODEL is set"
}

test_named_holder_session_start_on_a_free_lock
test_second_session_while_pocock_holds_main_stays_read_only
test_named_holder_completion_marker_routes_a_rebuild_to_reemit
test_named_holder_pi_compact_keys_its_agents_baseline_to_line_one
test_startup_sweep_and_bootstrap_are_authorised_under_a_named_holder
test_claude_main_fallback_after_pocock_releases
test_inbox_ready_under_a_named_holder_pins_the_supervision_model

echo "# fm-session-start-holder.test.sh: all assertions passed"
