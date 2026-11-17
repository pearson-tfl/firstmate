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
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u FM_LOCK_HOLDER -u FM_LOCK_RECEIPT \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" LOCK_SH="$LOCK_SH" LIB="$LIB" \
    "$@" bash -c "$command"
}

# The same, inside a harness-named process that is the trusted Claude session.
# The trailing status line keeps that process from exec-replacing itself with
# the last command, so CLAUDE_PID stays a live claude-named ancestor.
in_claude_session() {  # <home> <session-id> <command> [env assignments...]
  local home=$1 id=$2 command=$3
  shift 3
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u FM_LOCK_HOLDER -u FM_LOCK_RECEIPT \
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
  printf 'lock=%s session=%s' "$(cat "$1/state/.lock" 2>/dev/null || printf '<absent>')" \
    "$(cat "$1/state/.lock-session" 2>/dev/null || printf '<absent>')"
  if [ -e "$1/state/.lock-receipt" ] || [ -L "$1/state/.lock-receipt" ]; then
    printf ' receipt=%s' "$(cat "$1/state/.lock-receipt" 2>/dev/null || printf '<unreadable>')"
  fi
  printf '\n'
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

receipt_op() {  # <home> <operation> <receipt> [holder]
  in_home "$1" '"$LOCK_SH" "$OP" "$RECEIPT"; printf "rc=%s\n" "$?"' \
    FM_LOCK_HOLDER="${4:-pocock}" OP="$2" RECEIPT="$3" 2>&1
}

reserve() {  # <home> -> receipt only; fail test on unexpected refusal
  local receipt
  receipt=$(in_home "$1" '"$LOCK_SH" reserve' FM_LOCK_HOLDER=pocock) || fail "reservation failed"
  [[ "$receipt" =~ ^v1:[0-9a-f]{32}$ ]] || fail "invalid receipt: $receipt"
  printf '%s\n' "$receipt"
}

test_receipt_matching_adopt_and_release() {
  local home receipt out before
  home=$(new_home receipt-match)
  printf '%s\n' obsolete-session > "$home/state/.lock-session"
  receipt=$(reserve "$home")
  [ ! -e "$home/state/.lock-session" ] || fail "reservation retained the launcher's old session"
  assert_equals "lock: held by pocock" "$(status_of "$home")" "reservation keeps line-one ownership"
  out=$(in_claude_session "$home" adopted-session '"$LOCK_SH" adopt "$RECEIPT"' \
    FM_LOCK_HOLDER=pocock RECEIPT="$receipt" 2>&1)
  assert_contains "$out" "rc=0" "matching receipt must adopt"
  assert_equals adopted-session "$(cat "$home/state/.lock-session")" "adopter must publish its own session"
  before=$(snapshot "$home")
  out=$(receipt_op "$home" release-receipt "$receipt" other)
  assert_contains "$out" "rc=74" "same receipt with foreign holder must refuse"
  assert_equals "$before" "$(snapshot "$home")" "foreign release must leave the pair unchanged"
  out=$(receipt_op "$home" release-receipt "$receipt")
  assert_contains "$out" "rc=0" "matching receipt must release after adoption"
  assert_equals "lock=<absent> session=<absent>" "$(snapshot "$home")" "conditional release clears the pair"
  pass "matching receipt adopts the session and releases only with matching holder"
}

test_replaced_claim_refuses_stale_adopt_and_release() {
  local home old fresh out before
  home=$(new_home receipt-replaced)
  old=$(reserve "$home")
  out=$(release "$home" pocock)
  assert_contains "$out" "rc=0" "ordinary release remains supported"
  fresh=$(reserve "$home")
  [ "$old" != "$fresh" ] || fail "new claim reused the receipt"
  printf '%s\n' replacement-session > "$home/state/.lock-session"
  before=$(snapshot "$home")
  out=$(receipt_op "$home" adopt "$old")
  assert_contains "$out" "rc=74" "old receipt cannot adopt a replacement with the same name"
  assert_equals "$before" "$(snapshot "$home")" "stale adoption changes nothing"
  out=$(receipt_op "$home" release-receipt "$old")
  assert_contains "$out" "rc=74" "old receipt cannot release a replacement"
  assert_equals "$before" "$(snapshot "$home")" "stale release changes nothing"
  out=$(claim "$home" pocock)
  assert_contains "$out" "rc=0" "ordinary same-name claim still succeeds"
  before=$(snapshot "$home")
  out=$(receipt_op "$home" adopt "$fresh")
  assert_contains "$out" "rc=74" "ordinary acquisition invalidates the receipt"
  assert_equals "$before" "$(snapshot "$home")" "invalidated receipt changes nothing"
  pass "replacement and ordinary acquisition invalidate receipts, including same-name replacements"
}

test_reservation_refuses_existing_and_unsafe_claims() {
  local home receipt before out pid
  home=$(new_home receipt-occupied)
  receipt=$(reserve "$home")
  before=$(snapshot "$home")
  out=$(in_home "$home" '"$LOCK_SH" reserve; printf "rc=%s\n" "$?"' FM_LOCK_HOLDER=pocock 2>&1)
  assert_contains "$out" "rc=73" "reserve must not replace even its own holder"
  assert_equals "$before" "$(snapshot "$home")" "occupied refusal changes nothing"
  out=$(receipt_op "$home" release-receipt "$receipt")
  assert_contains "$out" "rc=0" "setup release"
  ln -s "$home/missing" "$home/state/.lock"
  out=$(in_home "$home" '"$LOCK_SH" reserve; printf "rc=%s\n" "$?"' FM_LOCK_HOLDER=pocock 2>&1)
  assert_contains "$out" "rc=73" "dangling symlink must refuse"
  [ -L "$home/state/.lock" ] && [ ! -e "$home/missing" ] || fail "reservation changed symlink"
  rm "$home/state/.lock"
  pid=$(start_live_claude)
  printf '%s\n' "$pid" > "$home/state/.lock"
  before=$(snapshot "$home")
  out=$(in_home "$home" '"$LOCK_SH" reserve; printf "rc=%s\n" "$?"' FM_LOCK_HOLDER=pocock 2>&1)
  assert_contains "$out" "rc=73" "live legacy owner must refuse reservation"
  assert_equals "$before" "$(snapshot "$home")" "live owner remains untouched"
  : > "$home/state/.lock"
  receipt=$(reserve "$home")
  out=$(receipt_op "$home" adopt bad-receipt)
  assert_contains "$out" "rc=64" "malformed receipt has a distinct exit"
  pass "reservation protects existing and unsafe owners; empty claim is reservable"
}

test_receipt_mutex_contention_rechecks_after_retry() {
  local home receipt holder i=0 op out before
  home=$(new_home receipt-contention)
  receipt=$(reserve "$home")
  bash -c '
    FM_HOME=$3 STATE=$2
    . "$1"
    fm_lock_try_acquire "$2/.lock.acquire" || exit 1
    : > "$2/mutex-ready"
    while [ ! -e "$2/release-mutex" ] && [ "$SECONDS" -lt 60 ]; do sleep 0.05; done
    : > "$2/.lock"
    rm -f "$2/.lock-receipt"
    printf "replacement-session\n" > "$2/.lock-session"
    fm_lock_release "$2/.lock.acquire"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home" &
  holder=$!
  OWNER_PIDS+=("$holder")
  while [ "$i" -lt 400 ] && [ ! -e "$home/state/mutex-ready" ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$home/state/mutex-ready" ] || fail "claim mutex fixture never became ready"
  before=$(snapshot "$home")
  for op in adopt release-receipt; do
    out=$(receipt_op "$home" "$op" "$receipt")
    assert_contains "$out" "rc=75" "busy mutex must return retry for $op"
    assert_equals "$before" "$(snapshot "$home")" "busy $op must change nothing"
  done
  out=$(in_home "$home" '"$LOCK_SH" reserve; printf "rc=%s\n" "$?"' FM_LOCK_HOLDER=pocock 2>&1)
  assert_contains "$out" "rc=75" "busy reservation must return retry"
  out=$(in_home "$home" '"$LOCK_SH" reserve --absent-only; printf "rc=%s\n" "$?"' FM_LOCK_HOLDER=pocock 2>&1)
  assert_contains "$out" "rc=75" "busy absent-only reservation must return retry"
  for op in '' release; do
    out=$(in_home "$home" 'if [ -n "$OP" ]; then "$LOCK_SH" "$OP"; else "$LOCK_SH"; fi; printf "rc=%s\n" "$?"' \
      FM_LOCK_HOLDER=pocock FM_LOCK_RECEIPT="$receipt" OP="$op" 2>&1)
    assert_contains "$out" "rc=75" "busy receipt environment operation must return retry"
    assert_equals "$before" "$(snapshot "$home")" "busy environment operation changes nothing"
  done
  : > "$home/state/release-mutex"
  wait "$holder" || fail "mutex fixture failed"
  before=$(snapshot "$home")
  out=$(receipt_op "$home" adopt "$receipt")
  assert_contains "$out" "rc=74" "retry must check the claim replaced inside mutex"
  assert_equals "$before" "$(snapshot "$home")" "retry cannot mutate replacement"
  out=$(in_home "$home" '"$LOCK_SH" reserve --absent-only; printf "rc=%s\n" "$?"' FM_LOCK_HOLDER=pocock 2>&1)
  assert_contains "$out" "rc=73" "absent-only retry must refuse the empty lock published inside mutex"
  assert_equals "$before" "$(snapshot "$home")" "strict retry cannot mutate replacement"
  pass "receipt operations refuse busy mutex and retry against current claim, not pre-wait evidence"
}

test_receipt_sidecar_precedes_lock_publication() {
  local home receipt out bin
  home=$(new_home receipt-order)
  receipt=$(reserve "$home")
  printf '%s\n' old-session > "$home/state/.lock-session"
  bin=$(fm_fakebin "$home/bin")
  # Observe the public filesystem at the lock backup I/O seam. The old claim
  # must still exist while the new sidecar has already been published.
  cat > "$bin/cp" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "$FM_HOME/state/.lock" ]; then
  if [ "$(cat "$FM_HOME/state/.lock-session")" != ordered-session ] ||
     [ "$(cat "$1")" != holder:pocock ] ||
     [ "$(cat "$FM_HOME/state/.lock-receipt")" != "$RECEIPT" ]; then
    exit 1
  fi
  : > "$FM_HOME/ordered"
fi
exec /bin/cp "$@"
EOF
  chmod +x "$bin/cp"
  out=$(in_claude_session "$home" ordered-session '"$LOCK_SH" adopt "$RECEIPT"' \
    FM_LOCK_HOLDER=pocock RECEIPT="$receipt" PATH="$bin:$PATH" 2>&1)
  assert_contains "$out" "rc=0" "adoption with ordering observation must succeed"
  [ -e "$home/ordered" ] || fail "sidecar/claim ordering seam was not exercised"
  assert_equals ordered-session "$(cat "$home/state/.lock-session")" "new sidecar survives verified publication"
  out=$(receipt_op "$home" adopt "$receipt")
  assert_contains "$out" "rc=0" "repeat adoption without trusted identity is allowed"
  [ ! -e "$home/state/.lock-session" ] || fail "untrusted adopter retained trusted session"
  pass "adoption publishes the sidecar before the lock and clears it for untrusted callers"
}

test_absent_only_refuses_every_existing_path() {
  local home kind out before receipt
  for kind in empty stale named foreign directory symlink dangling; do
    home=$(new_home "absent-only-$kind")
    printf '%s\n' protected-session > "$home/state/.lock-session"
    case "$kind" in
      empty) : > "$home/state/.lock" ;;
      stale) printf '99999999\n' > "$home/state/.lock" ;;
      named) printf 'holder:pocock\n' > "$home/state/.lock" ;;
      foreign) printf 'holder:foreign\n' > "$home/state/.lock" ;;
      directory) mkdir "$home/state/.lock" ;;
      symlink) ln -s "$home/state/.lock-session" "$home/state/.lock" ;;
      dangling) ln -s "$home/missing" "$home/state/.lock" ;;
    esac
    before=$(snapshot "$home")
    out=$(in_home "$home" '"$LOCK_SH" reserve --absent-only; printf "rc=%s\n" "$?"' FM_LOCK_HOLDER=pocock 2>&1)
    assert_contains "$out" "rc=73" "absent-only must refuse $kind"
    assert_equals "$before" "$(snapshot "$home")" "absent-only $kind refusal changes nothing"
    case "$kind" in
      directory) [ -d "$home/state/.lock" ] || fail "directory removed" ;;
      symlink|dangling) [ -L "$home/state/.lock" ] || fail "symlink removed" ;;
    esac
  done
  home=$(new_home absent-only-success)
  receipt=$(in_home "$home" '"$LOCK_SH" reserve --absent-only' FM_LOCK_HOLDER=pocock) || fail "absent-only claim failed"
  [[ "$receipt" =~ ^v1:[0-9a-f]{32}$ ]] || fail "absent-only receipt malformed"
  pass "absent-only reserves absent path and refuses every existing pathname"
}

test_receipt_environment_preserves_claim_across_startup_and_release() {
  local home receipt out expected before
  home=$(new_home receipt-env)
  receipt=$(reserve "$home")
  expected=$(cat "$home/state/.lock")
  out=$(in_claude_session "$home" env-session '"$LOCK_SH"' FM_LOCK_HOLDER=pocock FM_LOCK_RECEIPT="$receipt" 2>&1)
  assert_contains "$out" "rc=0" "receipt-aware ordinary startup must succeed"
  assert_contains "$out" "lock acquired: holder pocock" "ordinary acquisition output stays compatible"
  assert_equals "$expected" "$(cat "$home/state/.lock")" "ordinary startup must retain holder"
  assert_equals "$receipt" "$(cat "$home/state/.lock-receipt")" "ordinary startup must retain receipt"
  assert_equals env-session "$(cat "$home/state/.lock-session")" "ordinary startup publishes trusted sidecar"
  before=$(snapshot "$home")
  out=$(in_claude_session "$home" env-session '"$LOCK_SH"' FM_LOCK_HOLDER=pocock FM_LOCK_RECEIPT="$receipt" 2>&1)
  assert_contains "$out" "rc=0" "receipt-aware recheck must succeed"
  assert_equals "$before" "$(snapshot "$home")" "same-session recheck preserves pair"
  out=$(in_home "$home" '"$LOCK_SH" release; printf "rc=%s\n" "$?"' FM_LOCK_HOLDER=pocock FM_LOCK_RECEIPT="$receipt" 2>&1)
  assert_contains "$out" "rc=0" "receipt-aware ordinary release must succeed"
  assert_equals "lock=<absent> session=<absent>" "$(snapshot "$home")" "receipt-aware release clears pair"
  out=$(in_home "$home" '"$LOCK_SH"; printf "rc=%s\n" "$?"' FM_LOCK_HOLDER=pocock FM_LOCK_RECEIPT="$receipt" 2>&1)
  assert_contains "$out" "rc=74" "receipt-aware ordinary acquire must not reclaim absent lock"
  assert_equals "lock=<absent> session=<absent>" "$(snapshot "$home")" "missing receipt cannot recreate pair"
  pass "receipt environment preserves claim and trusted session across ordinary startup/rechecks/release"
}

test_receipt_environment_refuses_replacement_foreign_and_invalid() {
  local home old fresh before op out receipt holder
  home=$(new_home receipt-env-refusals)
  old=$(reserve "$home")
  out=$(release "$home" pocock)
  assert_contains "$out" "rc=0" "setup release"
  fresh=$(reserve "$home")
  printf '%s\n' preserved-session > "$home/state/.lock-session"
  before=$(snapshot "$home")
  for op in '' release; do
    for receipt in "$old" invalid "$fresh"; do
      holder=pocock
      [ "$receipt" != "$fresh" ] || holder=foreign
      out=$(in_home "$home" 'if [ -n "$OP" ]; then "$LOCK_SH" "$OP"; else "$LOCK_SH"; fi; printf "rc=%s\n" "$?"' \
        FM_LOCK_HOLDER="$holder" FM_LOCK_RECEIPT="$receipt" OP="$op" 2>&1)
      if [ "$receipt" = invalid ]; then
        assert_contains "$out" "rc=64" "invalid environment receipt must refuse"
      else
        assert_contains "$out" "rc=74" "stale or foreign environment receipt must refuse"
      fi
      assert_equals "$before" "$(snapshot "$home")" "environment receipt refusal changes nothing"
    done
  done
  pass "receipt-aware ordinary acquire/release protect replacement and foreign claims"
}

test_receipt_publication_failure_restores_both_sidecars() {
  local home bin before out
  home=$(new_home receipt-rollback)
  : > "$home/state/.lock"
  printf '%s\n' previous-session > "$home/state/.lock-session"
  printf '%s\n' previous-receipt > "$home/state/.lock-receipt"
  before=$(snapshot "$home")
  bin=$(fm_fakebin "$home/bin")
  cat > "$bin/cp" <<'EOF'
#!/usr/bin/env bash
[ "$1" != "$FM_HOME/state/.lock" ] || exit 1
exec /bin/cp "$@"
EOF
  chmod +x "$bin/cp"
  out=$(in_home "$home" '"$LOCK_SH" reserve; printf "rc=%s\n" "$?"' FM_LOCK_HOLDER=pocock PATH="$bin:$PATH" 2>&1)
  assert_contains "$out" "rc=1" "lock publication I/O failure has distinct exit"
  assert_equals "$before" "$(snapshot "$home")" "failed reservation restores trusted and receipt sidecars"
  [ ! -e "$home/state/.lock-session.prev" ] && [ ! -e "$home/state/.lock-receipt.prev" ] || fail "rollback retained backup files"
  out=$(in_claude_session "$home" launcher-session '"$LOCK_SH" reserve' FM_LOCK_HOLDER=pocock 2>&1)
  assert_contains "$out" "rc=0" "retry reservation under trusted launcher succeeds"
  [ ! -e "$home/state/.lock-session" ] || fail "reservation published launcher identity instead of clearing it"
  pass "failed reservation restores both sidecars; trusted launcher is never credited as adopted session"
}

fm_test_run \
  test_receipt_publication_failure_restores_both_sidecars \
  test_absent_only_refuses_every_existing_path \
  test_receipt_environment_preserves_claim_across_startup_and_release \
  test_receipt_environment_refuses_replacement_foreign_and_invalid \
  test_receipt_matching_adopt_and_release \
  test_replaced_claim_refuses_stale_adopt_and_release \
  test_reservation_refuses_existing_and_unsafe_claims \
  test_receipt_mutex_contention_rechecks_after_retry \
  test_receipt_sidecar_precedes_lock_publication \
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
