#!/usr/bin/env bash
# tests/fm-lock-holder.test.sh - the named session-lock holder
# (FM_LOCK_HOLDER in bin/fm-lock.sh and bin/fm-session-lock-lib.sh).
#
# Every case drives the real bin/fm-lock.sh, the sourced session-lock library,
# or bin/fm-inbox.sh ready against an isolated synthetic home. A live harness
# owner is a real long-lived process whose executable is named claude, and a
# trusted Claude session id is proven by running the claim inside such a
# process with CLAUDE_PID set to it.
# shellcheck disable=SC2016 # single quotes are deliberate: $$ and $FM_HOME expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock-holder)
LOCK_SH="$ROOT/bin/fm-lock.sh"
LIB="$ROOT/bin/fm-session-lock-lib.sh"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"

OWNER_PIDS=()
cleanup_owners() {
  local pid
  for pid in ${OWNER_PIDS[@]+"${OWNER_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}
trap 'cleanup_owners; fm_test_cleanup' EXIT

new_home() {  # <name> -> home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# Run <command> in a clean shell for <home>: the suite's own session identity
# and any inherited holder name are scrubbed, so only what a case sets reaches
# the scripts under test.
in_home() {  # <home> <command> [env assignments...]
  local home=$1 command=$2
  shift 2
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u FM_LOCK_HOLDER \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" LOCK_SH="$LOCK_SH" LIB="$LIB" \
    "$@" bash -c "$command"
}

# The same, inside a harness-named process that is the trusted Claude session.
# The trailing status line keeps that process from exec-replacing itself with
# the last command, so CLAUDE_PID stays a live claude-named ancestor.
in_claude_session() {  # <home> <session-id> <command> [env assignments...]
  local home=$1 id=$2 command=$3
  shift 3
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u FM_LOCK_HOLDER \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" LOCK_SH="$LOCK_SH" LIB="$LIB" \
    CLAUDE_CODE_SESSION_ID="$id" "$@" \
    "$NAMED_CLAUDE" -c "export CLAUDE_PID=\$\$; $command; printf 'rc=%s\n' \"\$?\""
}

test_named_claim_on_a_free_lock_writes_the_holder_and_publishes_the_session() {
  local home out
  home=$(new_home free-claim)
  out=$(in_claude_session "$home" synthetic-pocock '"$LOCK_SH"' FM_LOCK_HOLDER=pocock 2>&1)
  assert_contains "$out" "rc=0" "a named claim on a free lock must succeed"
  assert_equals "holder:pocock" "$(cat "$home/state/.lock")" "line 1 must name the holder"
  assert_equals "synthetic-pocock" "$(cat "$home/state/.lock-session")" "the trusted session id must be published beside the lock"
  pass "named claim on a free lock writes holder:pocock and publishes the session file"
}

# A live harness owner: a long-lived claude-named process, recorded in .lock.
start_live_claude() {  # -> pid
  "$NAMED_CLAUDE" -c 'while :; do sleep 1; done' >/dev/null 2>&1 &
  OWNER_PIDS+=("$!")
  printf '%s\n' "$!"
}

claim() {  # <home> <name> -> "rc=N" plus output
  in_home "$1" '"$LOCK_SH"; printf "rc=%s\n" "$?"' FM_LOCK_HOLDER="$2" 2>&1
}

release() {  # <home> <name or empty>
  if [ -n "$2" ]; then
    in_home "$1" '"$LOCK_SH" release; printf "rc=%s\n" "$?"' FM_LOCK_HOLDER="$2" 2>&1
  else
    in_home "$1" '"$LOCK_SH" release; printf "rc=%s\n" "$?"' 2>&1
  fi
}

status_of() {  # <home>
  in_home "$1" '"$LOCK_SH" status'
}

snapshot() {  # <home> -> lock line and sidecar, for "nothing changed" checks
  printf 'lock=%s session=%s\n' "$(cat "$1/state/.lock" 2>/dev/null || printf '<absent>')" \
    "$(cat "$1/state/.lock-session" 2>/dev/null || printf '<absent>')"
}

test_named_claim_is_refused_while_a_live_claude_pid_holds_the_lock() {
  local home pid out before
  home=$(new_home live-pid)
  pid=$(start_live_claude)
  printf '%s\n' "$pid" > "$home/state/.lock"
  printf '%s\n' synthetic-owner > "$home/state/.lock-session"
  before=$(snapshot "$home")
  out=$(claim "$home" pocock)
  assert_contains "$out" "rc=1" "a named claim must not take a lock a live Claude pid holds"
  assert_contains "$out" "another live firstmate session holds the lock (pid $pid" "the refusal must name the live owner"
  assert_equals "$before" "$(snapshot "$home")" "a refused claim must change nothing"
  pass "named claim refused while a live Claude pid holds the lock"
}

test_release_clears_only_for_the_matching_name() {
  local home out before
  home=$(new_home release)
  out=$(in_claude_session "$home" synthetic-pocock '"$LOCK_SH"' FM_LOCK_HOLDER=pocock 2>&1)
  assert_contains "$out" "rc=0" "setup claim must succeed"
  before=$(snapshot "$home")
  out=$(release "$home" ahr)
  assert_contains "$out" "rc=1" "a release under another name must fail"
  assert_equals "$before" "$(snapshot "$home")" "a wrong-name release must change nothing"
  out=$(release "$home" "")
  assert_contains "$out" "rc=1" "an unnamed release must fail"
  assert_equals "$before" "$(snapshot "$home")" "an unnamed release must change nothing"
  out=$(release "$home" pocock)
  assert_contains "$out" "rc=0" "the holder's own release must succeed"
  assert_equals "lock=<absent> session=<absent>" "$(snapshot "$home")" "release must clear line 1 and the session file"
  assert_equals "lock: free" "$(status_of "$home")" "a released lock must read free"
  pass "release clears line 1 and the session file only for the matching name"
}

test_recheck_reclaims_a_hand_cleared_lock_and_refuses_otherwise() {
  local home out pid before
  home=$(new_home recheck)
  out=$(claim "$home" pocock)
  assert_contains "$out" "rc=0" "setup claim must succeed"
  rm -f "$home/state/.lock"
  out=$(claim "$home" pocock)
  assert_contains "$out" "rc=0" "a re-check on a removed lock must reclaim"
  assert_equals "holder:pocock" "$(cat "$home/state/.lock")" "the reclaim must rewrite the holder"
  : > "$home/state/.lock"
  out=$(claim "$home" pocock)
  assert_contains "$out" "rc=0" "a re-check on an emptied lock must reclaim"
  assert_equals "holder:pocock" "$(cat "$home/state/.lock")" "the reclaim must rewrite the holder"
  out=$(claim "$home" pocock)
  assert_contains "$out" "rc=0" "a re-check on its own name must pass"
  assert_contains "$out" "lock acquired: holder pocock" "the re-check must report the holder"

  printf '%s\n' holder:ahr > "$home/state/.lock"
  before=$(snapshot "$home")
  out=$(claim "$home" pocock)
  assert_contains "$out" "rc=1" "a re-check must refuse another name"
  assert_contains "$out" "main is held by ahr; read-only" "the two-mains guard must name the holder"
  assert_equals "$before" "$(snapshot "$home")" "a refused re-check must change nothing"

  pid=$(start_live_claude)
  printf '%s\n' "$pid" > "$home/state/.lock"
  before=$(snapshot "$home")
  out=$(claim "$home" pocock)
  assert_contains "$out" "rc=1" "a re-check must refuse a live Claude pid"
  assert_equals "$before" "$(snapshot "$home")" "a refused re-check must change nothing"
  pass "a re-check reclaims a hand-cleared lock and refuses another name or a live pid unchanged"
}

test_status_and_inbox_ready_show_the_named_holder() {
  local home out
  home=$(new_home status)
  out=$(claim "$home" pocock)
  assert_contains "$out" "rc=0" "setup claim must succeed"
  assert_equals "lock: held by pocock" "$(status_of "$home")" "fm-lock status must name the holder"
  out=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u FM_LOCK_HOLDER FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" bash "$ROOT/bin/fm-inbox.sh" ready 2>&1)
  assert_equals "held pocock None" "$(printf '%s' "$out" | python3 -c 'import json,sys; l=json.load(sys.stdin)["lock"]; print(l["state"], l["holder"], l["pid"])')" \
    "fm-inbox ready must report the lock held by pocock"
  pass "fm-lock status and fm-inbox ready show held by pocock"
}

test_inherited_name_in_a_hand_run_session_claims_as_that_holder() {
  local home out
  home=$(new_home inherited)
  out=$(claim "$home" pocock)
  assert_contains "$out" "rc=0" "setup claim must succeed"
  # A Claude session started by hand from a shell prefixed with the holder's
  # name inherits it and claims as that holder. This is the accepted leak risk:
  # the name is a cooperation guard, not security.
  out=$(in_claude_session "$home" synthetic-hand '"$LOCK_SH"' FM_LOCK_HOLDER=pocock 2>&1)
  assert_contains "$out" "rc=0" "a hand-run session with the inherited name claims"
  assert_equals "holder:pocock" "$(cat "$home/state/.lock")" "it claims as pocock"
  assert_equals "synthetic-hand" "$(cat "$home/state/.lock-session")" "its session id is published"
  pass "inherited-name leak: a hand-run session prefixed FM_LOCK_HOLDER=pocock claims as pocock (accepted risk)"
}

test_secondmate_named_holder_claims_and_refuses_other_sessions() {
  local home out before
  home=$(new_home ahr)
  out=$(in_claude_session "$home" synthetic-ahr '"$LOCK_SH"' FM_LOCK_HOLDER=ahr 2>&1)
  assert_contains "$out" "rc=0" "ahr's named claim must succeed"
  assert_equals "holder:ahr" "$(cat "$home/state/.lock")" "line 1 must name ahr"
  assert_equals "synthetic-ahr" "$(cat "$home/state/.lock-session")" "ahr's session id must be published"
  before=$(snapshot "$home")
  out=$(in_claude_session "$home" synthetic-other '"$LOCK_SH"' FM_LOCK_HOLDER=pocock 2>&1)
  assert_contains "$out" "rc=1" "a session under another name must be refused"
  assert_contains "$out" "main is held by ahr; read-only" "the refusal must be the two-mains guard"
  out=$(in_claude_session "$home" synthetic-unnamed '"$LOCK_SH"' 2>&1)
  assert_contains "$out" "rc=1" "an unnamed Claude session must be refused"
  assert_contains "$out" "main is held by ahr; read-only" "the unnamed refusal must be the two-mains guard"
  assert_equals "$before" "$(snapshot "$home")" "refused sessions must change nothing"
  pass "FM_LOCK_HOLDER=ahr claims holder:ahr with the session published; another session is refused read-only"
}

test_secondmate_release_then_reclaim() {
  local home out before
  home=$(new_home ahr-release)
  out=$(in_claude_session "$home" synthetic-ahr '"$LOCK_SH"' FM_LOCK_HOLDER=ahr 2>&1)
  assert_contains "$out" "rc=0" "setup claim must succeed"
  before=$(snapshot "$home")
  out=$(release "$home" pocock)
  assert_contains "$out" "rc=1" "a wrong-name release must fail"
  assert_equals "$before" "$(snapshot "$home")" "a wrong-name release must change nothing"
  out=$(release "$home" ahr)
  assert_contains "$out" "rc=0" "ahr's release must succeed"
  assert_equals "lock=<absent> session=<absent>" "$(snapshot "$home")" "release must clear the lock"
  out=$(in_claude_session "$home" synthetic-ahr-2 '"$LOCK_SH"' FM_LOCK_HOLDER=ahr 2>&1)
  assert_contains "$out" "rc=0" "a fresh ahr claim must reclaim"
  assert_equals "holder:ahr" "$(cat "$home/state/.lock")" "the reclaim must name ahr"
  pass "FM_LOCK_HOLDER=ahr release clears line 1, a wrong name changes nothing, a fresh claim reclaims"
}

test_two_runs_under_one_name_both_pass() {
  local home a b
  home=$(new_home same-name)
  claim "$home" pocock > "$TMP_ROOT/same-a.out" &
  a=$!
  claim "$home" pocock > "$TMP_ROOT/same-b.out" &
  b=$!
  wait "$a"; wait "$b"
  assert_contains "$(cat "$TMP_ROOT/same-a.out")" "rc=0" "the first run must pass"
  assert_contains "$(cat "$TMP_ROOT/same-b.out")" "rc=0" "the second run must pass"
  assert_equals "lock: held by pocock" "$(status_of "$home")" "status must show the one name"
  pass "two runs under one name both pass and status shows the one name"
}

test_startup_sweep_refusal_reads_as_wait_and_retry() {
  local home out before holder i=0
  home=$(new_home sweep)
  printf '%s\n' holder:pocock > "$home/state/.lock"
  bash -c '
    set -u
    FM_HOME=$3 STATE=$2
    . "$1"
    fm_lock_try_acquire "$2/.lock.acquire" || exit 1
    printf "pid=%s\n" "$$" > "$2/.startup-network.status"
    : > "$2/sweep-ready"
    while [ ! -e "$2/release-sweep" ] && [ "$SECONDS" -lt 60 ]; do sleep 0.05; done
    fm_lock_release "$2/.lock.acquire"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home" &
  holder=$!
  while [ "$i" -lt 400 ] && [ ! -e "$home/state/sweep-ready" ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$home/state/sweep-ready" ] || fail "the synthetic sweep never took the claim lock"
  before=$(snapshot "$home")
  out=$(claim "$home" pocock)
  : > "$home/state/release-sweep"
  wait "$holder"
  assert_contains "$out" "rc=75" "the sweep refusal must exit with the retry status"
  assert_contains "$out" "wait and retry" "the sweep refusal must say wait and retry"
  assert_equals "$before" "$(snapshot "$home")" "the sweep refusal must change nothing"
  out=$(claim "$home" pocock)
  assert_contains "$out" "rc=0" "the retry after the sweep releases must pass"
  pass "a refusal from the startup sweep finishing is distinguishable as wait-and-retry"
}

lib_eval() {  # <home> <expression> [env assignments...]
  local home=$1 expr=$2
  shift 2
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u FM_LOCK_HOLDER "$@" \
    bash -c ". \"\$0\"; $expr" "$LIB"
}

test_library_reads_the_named_holder_from_line_one() {
  local home state
  home=$(new_home lib)
  state="$home/state"
  printf 'holder:pocock\nholder:other\n' > "$state/.lock"
  assert_equals "pocock" "$(lib_eval "$home" "fm_session_lock_recorded_holder '$state'")" "the helper must read line 1 only"
  assert_equals "yes" "$(lib_eval "$home" "fm_session_lock_owned_by_self '$state' && echo yes || echo no" FM_LOCK_HOLDER=pocock)" \
    "owned_by_self must be true for the matching holder"
  assert_equals "no" "$(lib_eval "$home" "fm_session_lock_owned_by_self '$state' && echo yes || echo no" FM_LOCK_HOLDER=ahr)" \
    "owned_by_self must be false for another holder"
  assert_equals "no" "$(lib_eval "$home" "fm_session_lock_owned_by_self '$state' && echo yes || echo no")" \
    "owned_by_self must be false for an unnamed caller"
  assert_equals "yes pocock pocock" \
    "$(lib_eval "$home" "fm_session_lock_foreign_owner_live '$state' && echo yes \"\$FM_SESSION_LOCK_FOREIGN_OWNER_HOLDER\" \"\$FM_SESSION_LOCK_FOREIGN_OWNER_PID\" || echo no" FM_LOCK_HOLDER=ahr)" \
    "foreign_owner_live must be true for another name and expose it"
  assert_equals "no" "$(lib_eval "$home" "fm_session_lock_foreign_owner_live '$state' && echo yes || echo no" FM_LOCK_HOLDER=pocock)" \
    "foreign_owner_live must be false for the holder itself"
  printf '123\nholder:pocock\n' > "$state/.lock"
  assert_equals "none" "$(lib_eval "$home" "fm_session_lock_recorded_holder '$state' || echo none")" \
    "a holder below line 1 is not a named holder"
  pass "the library reads the named holder from line 1 and decides ownership by name"
}

# The re-check main's named holder runs before each drain, spawn or merge
# also checks the hung-forwarder detector's beat: one row per stale beat to
# the notify command in config/detector-notify, and the claim's outcome is
# unchanged. It claims as claude, the Claude first mate the detector notifies
# after the switch from pocock (#5266), with the installed route's target and
# tag.
test_recheck_sends_one_row_on_a_stale_detector_beat() {
  local home out t
  home=$(new_home detector-beat)
  mkdir -p "$home/config"
  printf '#!/usr/bin/env bash\nprintf "%%s|%%s|%%s\\n" "$1" "$2" "$3" >> "%s/inbox"\n' "$home" > "$home/notify"
  chmod +x "$home/notify"
  printf '%s\n%s\n%s\n' "$home/notify" firstmate fm-lock-recheck > "$home/config/detector-notify"
  : > "$home/inbox"
  : > "$home/state/.detector-beat"
  out=$(claim "$home" claude)
  assert_contains "$out" "rc=0" "claim with a fresh detector beat"
  [ ! -s "$home/inbox" ] || fail "a fresh detector beat sent a row: $(cat "$home/inbox")"
  t=$(( $(date +%s) - 1000 ))
  perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1] or die' "$t" "$home/state/.detector-beat"
  out=$(claim "$home" claude)
  assert_contains "$out" "rc=0" "claim with a stale detector beat still succeeds"
  assert_contains "$out" "lock acquired: holder claude" "claim output unchanged"
  [ "$(grep -c . "$home/inbox")" -eq 1 ] || fail "stale detector beat gave $(grep -c . "$home/inbox") rows: $(cat "$home/inbox")"
  grep -q "^firstmate|fm-lock-recheck|firstmate forwarder detector in $home: detector beat is" "$home/inbox" \
    || fail "row does not carry the configured arguments and the home: $(cat "$home/inbox")"
  out=$(claim "$home" claude)
  [ "$(grep -c . "$home/inbox")" -eq 1 ] || fail "a second re-check on the same stale beat sent another row"
  rm -f "$home/config/detector-notify"
  t=$(( $(date +%s) - 2000 ))
  perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1] or die' "$t" "$home/state/.detector-beat"
  out=$(claim "$home" claude)
  assert_contains "$out" "rc=0" "claim with no detector-notify config"
  [ "$(grep -c . "$home/inbox")" -eq 1 ] || fail "a row was sent with no detector-notify config"
  pass "the named re-check sends one row on a detector beat over 900s and still claims"
}

fm_test_run \
  test_named_claim_on_a_free_lock_writes_the_holder_and_publishes_the_session \
  test_named_claim_is_refused_while_a_live_claude_pid_holds_the_lock \
  test_release_clears_only_for_the_matching_name \
  test_recheck_reclaims_a_hand_cleared_lock_and_refuses_otherwise \
  test_status_and_inbox_ready_show_the_named_holder \
  test_inherited_name_in_a_hand_run_session_claims_as_that_holder \
  test_secondmate_named_holder_claims_and_refuses_other_sessions \
  test_secondmate_release_then_reclaim \
  test_two_runs_under_one_name_both_pass \
  test_startup_sweep_refusal_reads_as_wait_and_retry \
  test_library_reads_the_named_holder_from_line_one \
  test_recheck_sends_one_row_on_a_stale_detector_beat
