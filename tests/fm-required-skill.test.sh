#!/usr/bin/env bash
# Behavior tests for required-skill proof (bin/fm-required-skill-lib.sh).
#
# Seams: the steering-inbox ladder (fm_task_inbox_due_action) for the
# start-proof re-ring, fm_dod_accept_ship_done for a worker's done,
# bin/fm-secondmate-report.sh for a secondmate's done reply, and
# fm_pending_reply_try_resolve for the parent's record of that reply.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pending-reply-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-dod-lib.sh"

REPORT="$ROOT/bin/fm-secondmate-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-required-skill)
export FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=2

new_state() {  # <name> -> echoes an empty state dir
  mkdir -p "$TMP_ROOT/$1/state"
  printf '%s\n' "$TMP_ROOT/$1/state"
}

action_verb() {  # <state> <task>
  local a
  a=$(fm_task_inbox_due_action "$1" "$2")
  printf '%s' "${a%% *}"
}

# A record naming a required skill keeps ringing after its acknowledgement
# until the status file proves the skill started, then escalates; the proof
# makes the acknowledgement stick.
test_missing_start_proof_keeps_ringing() {
  local state rec
  state=$(new_state start-proof)
  rec=$(fm_task_inbox_write "$state" w1 "$(fm_required_skills_section tdd task)") \
    || fail "could not write the start-proof record"
  assert_equals ring "$(action_verb "$state" w1)" "an unacknowledged start-proof record is due a ring"
  fm_task_inbox_record_ring "$state" w1 "$rec" || fail "ring bookkeeping failed"

  mv "$rec" "$state/w1.inbox/handled/" || fail "could not acknowledge the record"
  printf 'working [at=1]: started work\n' > "$state/w1.status"
  assert_equals ring "$(action_verb "$state" w1)" "an acknowledgement without a start proof did not keep ringing"
  [ -f "$rec" ] || fail "the unproven record was not reopened out of handled/"
  fm_task_inbox_record_ring "$state" w1 "$rec" || fail "ring bookkeeping failed"
  assert_equals escalate "$(action_verb "$state" w1)" "an unproven record did not escalate after its ring budget"

  # A malformed proof (no route) and another skill's proof do not count.
  printf 'working [at=2]: skill-start tdd path=/s/tdd/SKILL.md\n' >> "$state/w1.status"
  printf 'working [at=2]: skill-start other path=/s/o/SKILL.md route=x\n' >> "$state/w1.status"
  mv "$rec" "$state/w1.inbox/handled/" || fail "could not acknowledge the record"
  fm_task_inbox_due_action "$state" w1 >/dev/null
  [ -f "$rec" ] || fail "a malformed or foreign proof let the acknowledgement stick"

  printf 'working [at=3]: skill-start tdd path=/s/tdd/SKILL.md route=red test first at the CLI seam\n' >> "$state/w1.status"
  mv "$rec" "$state/w1.inbox/handled/" || fail "could not acknowledge the record"
  assert_equals quiet "$(action_verb "$state" w1)" "a proven, acknowledged record still rang"
  [ -f "$state/w1.inbox/handled/${rec##*/}" ] || fail "a proven acknowledgement was reopened"
  [ ! -e "$state/w1.inbox/.proof-pending" ] || fail "a proven record stayed in the proof index"
  pass "a required skill missing its start proof keeps ringing until the proof is present"
}

# A marked request's start proof counts only with that request's corr token.
test_request_start_proof_needs_its_corr() {
  local state corr req rec
  state=$(new_state request-proof)
  corr=0123456789abcdef
  fm_pending_reply_embed_corr "Hill-climb the wiki."$'\n\n'"$(fm_required_skills_section poteto-mode request)" "$corr" req
  rec=$(fm_task_inbox_write "$state" mate "$req") || fail "could not write the request record"
  printf 'working [at=1]: skill-start poteto-mode path=/s/p/SKILL.md route=hill-climb\n' > "$state/mate.status"
  mv "$rec" "$state/mate.inbox/handled/" || fail "could not acknowledge the request"
  fm_task_inbox_due_action "$state" mate >/dev/null
  [ -f "$rec" ] || fail "an uncorrelated start proof satisfied a marked request"
  printf 'working [corr=%s] [at=2]: skill-start poteto-mode path=/s/p/SKILL.md route=hill-climb (via-helper)\n' "$corr" >> "$state/mate.status"
  mv "$rec" "$state/mate.inbox/handled/" || fail "could not acknowledge the request"
  assert_equals quiet "$(action_verb "$state" mate)" "a correlated start proof did not settle the request"
  pass "a marked request's start proof must carry its correlation token"
}

# A secondmate's done reply is refused, naming the skill and the exact helper
# call, until the channel records how the skill shaped the work; the parent's
# record ignores both the proof line and an unproven hand-written done.
test_secondmate_done_refused_then_accepted() {
  local dir parent mate state corr body req out rc
  dir="$TMP_ROOT/mate-done"
  parent="$dir/parent"
  mate="$dir/mate"
  state="$parent/state"
  mkdir -p "$state" "$mate/state"
  printf 'sm\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$mate/.fm-secondmate-parent"
  body="Hill-climb the wiki."$'\n\n'"$(fm_required_skills_section poteto-mode request)"
  corr=$(fm_pending_reply_create "$parent" "$state" sm "$body") || fail "could not create the parent record"
  fm_pending_reply_mark_delivered "$state" "$corr" || fail "could not mark delivery"
  assert_equals poteto-mode "$(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$corr")" required_skills)" \
    "the parent record did not carry the required skills"
  fm_pending_reply_embed_corr "$body" "$corr" req
  fm_task_inbox_write "$state" sm "$req" >/dev/null || fail "could not deliver the request"

  out=$(FM_HOME="$mate" "$REPORT" "done" "wiki rebuilt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a done without a shaped proof was accepted"
  assert_contains "$out" "required skill poteto-mode has no record of how it shaped the work" "refusal did not name the skill"
  assert_contains "$out" "bin/fm-secondmate-report.sh working $corr \"skill-shaped poteto-mode: <how the skill shaped the work>\"" \
    "refusal did not give the exact satisfying form"
  [ ! -e "$state/sm.status" ] || fail "a refused done still wrote to the parent channel"

  FM_HOME="$mate" "$REPORT" working "skill-start poteto-mode path=/s/p/SKILL.md route=hill-climb against the comparison wiki" \
    || fail "the start proof could not be written"
  printf 'done [corr=%s] [at=9]: hand-written early done\n' "$corr" >> "$state/sm.status"
  ! fm_pending_reply_try_resolve "$state" "$corr" || fail "a proof line or an unproven done resolved the parent record"

  FM_HOME="$mate" "$REPORT" working "skill-shaped poteto-mode: each pass rendered the page and kept the better variant" \
    || fail "the shaped proof could not be written"
  # The proof also validates the earlier hand-written done, so the request now
  # reads as answered and a follow-up names its corr explicitly.
  FM_HOME="$mate" "$REPORT" "done" "$corr" "wiki rebuilt" || fail "a done after the shaped proof was refused"
  fm_pending_reply_try_resolve "$state" "$corr" || fail "the proven done did not resolve the parent record"
  pass "a secondmate done is refused until the shaped proof exists, then accepted"
}

# A worker's done: refused while a required skill lacks its shaped proof.
test_worker_done_refused_then_accepted() {
  local state meta out
  state=$(new_state worker-done)
  meta="$state/sc.meta"
  fm_write_meta "$meta" kind=scout required_skills=tdd,poteto-mode
  {
    printf 'working [at=1]: skill-start tdd path=/s/tdd/SKILL.md route=red test first\n'
    printf 'working [at=1]: skill-shaped tdd: one red test per seam before code\n'
  } > "$state/sc.status"
  if out=$(fm_dod_accept_ship_done scout '' '' '' 'done: report written' "$state" sc "$meta"); then
    fail "a scout done missing proofs was accepted"
  fi
  assert_contains "$out" "required skill poteto-mode has no start proof" "refusal did not name the missing start proof"
  assert_contains "$out" "required skill poteto-mode has no record of how it shaped the work" "refusal did not name the missing shaped proof"
  assert_not_contains "$out" "skill tdd" "refusal named a proven skill"
  assert_contains "$out" "working [at=<epoch>]: skill-shaped poteto-mode: <how the skill shaped the work>" \
    "refusal did not give the exact satisfying form"
  printf 'working [at=2]: skill-shaped poteto-mode: rendered each page before keeping it\n' >> "$state/sc.status"
  if out=$(fm_dod_accept_ship_done scout '' '' '' 'done: report written' "$state" sc "$meta"); then
    fail "a scout done with no start proof was accepted"
  fi
  assert_contains "$out" "working [at=<epoch>]: skill-start poteto-mode path=" "start refusal did not give the exact form"
  printf 'working [at=3]: skill-start poteto-mode path=/s/p/SKILL.md route=hill-climb\n' >> "$state/sc.status"
  fm_dod_accept_ship_done scout '' '' '' 'done: report written' "$state" sc "$meta" \
    || fail "a scout done with every shaped proof was refused"
  pass "a worker done is refused until every required skill is shaped, then accepted"
}

# The request names each skill in the recipient harness's own invocation form
# (fm-skill-opener.sh), and an unverified harness form is refused.
# shellcheck disable=SC2016 # The expected invocations are literal text.
test_section_uses_the_harness_invocation() {
  local out
  out=$(fm_required_skills_section poteto-mode,tdd request codex) || fail "codex section failed"
  assert_contains "$out" '`$poteto-mode`, `$tdd`' "codex section did not use the codex invocation form"
  out=$(fm_required_skills_section tdd task) || fail "portable section failed"
  assert_contains "$out" '`/tdd`' "harness-free section did not use the portable form"
  if fm_required_skills_section tdd request no-such-harness >/dev/null 2>&1; then
    fail "an unverified harness invocation was guessed"
  fi
  pass "required-skill instructions use the harness's verified invocation form"
}

# No required skill: records, acknowledgements, and dones behave as before.
test_no_required_skill_unchanged() {
  local state rec dir parent mate corr req
  state=$(new_state none)
  rec=$(fm_task_inbox_write "$state" w2 "plain steer") || fail "could not write a plain record"
  [ ! -e "$state/w2.inbox/.proof-pending" ] || fail "a plain record entered the proof index"
  mv "$rec" "$state/w2.inbox/handled/" || fail "could not acknowledge"
  assert_equals quiet "$(action_verb "$state" w2)" "a plain acknowledged record rang"
  fm_write_meta "$state/sc.meta" kind=scout
  fm_dod_accept_ship_done scout '' '' '' 'done: report written' "$state" sc "$state/sc.meta" \
    || fail "a scout done with no required skill was refused"

  dir="$TMP_ROOT/mate-plain"
  parent="$dir/parent"
  mate="$dir/mate"
  mkdir -p "$parent/state" "$mate/state"
  printf 'sm\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$mate/.fm-secondmate-parent"
  corr=$(fm_pending_reply_create "$parent" "$parent/state" sm "audit it") || fail "could not create the parent record"
  fm_pending_reply_mark_delivered "$parent/state" "$corr" || fail "could not mark delivery"
  fm_pending_reply_embed_corr "audit it" "$corr" req
  fm_task_inbox_write "$parent/state" sm "$req" >/dev/null || fail "could not deliver the request"
  FM_HOME="$mate" "$REPORT" "done" "audit clean" || fail "a plain done reply was refused"
  fm_pending_reply_try_resolve "$parent/state" "$corr" || fail "a plain done reply did not resolve"
  pass "tasks and requests with no required skill behave exactly as before"
}

fm_test_run \
  test_missing_start_proof_keeps_ringing \
  test_request_start_proof_needs_its_corr \
  test_secondmate_done_refused_then_accepted \
  test_worker_done_refused_then_accepted \
  test_section_uses_the_harness_invocation \
  test_no_required_skill_unchanged
