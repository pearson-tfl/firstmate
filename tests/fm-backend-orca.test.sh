#!/usr/bin/env bash
# tests/fm-backend-orca.test.sh - fake-Orca-CLI unit tests for the Orca
# terminal adapter primitives in bin/backends/orca.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-orca-tests)
# A claude spawn writes workspace trust into the launching user's own store,
# and the script resolves it as ${CLAUDE_CONFIG_DIR:-${HOME:-}}, so the value
# is pinned EMPTY beside the throwaway HOME: an inherited one would beat that
# HOME and reach the developer's real store, while empty falls through to it
# and adds no launch prefix, since fm-spawn only prefixes a non-empty value.
SPAWN_HOME="$TMP_ROOT/user-home"
mkdir -p "$SPAWN_HOME"

write_spawn_brief() {  # <data-dir> <id>
  local data=$1 id=$2
  cat > "$data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Orca dispatch.

## Firstmate spec
Verify the Orca lifecycle behavior under test.
EOF
}

make_orca_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ORCA_LOG:?}"
RESP="${FM_ORCA_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
{
  printf 'orca'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ] && [ "${FM_ORCA_STATUS_RESPONSE:-ready}" != sequence ]; then
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
  exit 0
fi
n=$next
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/orca"
  ln -sf orca "$fb/orca-ide"
  printf '%s\n' "$fb"
}

orca_case() {  # <name> -> sets CASE_DIR LOG RESP FB
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR/responses"
  LOG="$CASE_DIR/log"
  RESP="$CASE_DIR/responses"
  : > "$LOG"
  FB=$(make_orca_fakebin "$CASE_DIR")
}

neutral_fm_root() {  # <dir> -> echoes a minimal root with a quiet guard
  local root="$1/root"
  mkdir -p "$root/bin"
  cat > "$root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$root/bin/fm-guard.sh"
  printf '%s\n' "$root"
}

add_tmux_fake() {
  local fb=$1
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ORCA_LOG:?}"
{
  printf 'tmux'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
exit 0
SH
  chmod +x "$fb/tmux"
}

test_capture_reads_terminal_tail_json() {
  local out
  orca_case capture-tail
  printf '{"result":{"terminal":{"source":"screen","tail":["line one","line two"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_capture term-123 40' "$ROOT" )
  [ "$out" = $'line one\nline two' ] || fail "capture should print result.terminal.tail joined by newlines, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--screen'$'\x1f''--limit'$'\x1f''40'$'\x1f''--json' \
    "capture did not call orca terminal read --screen with terminal/limit/json"
  pass "fm_backend_orca_capture: reads the drawn screen and parses result.terminal.tail"
}

# Composer judgement reads rows such as a padded prompt box, so capture must
# return the cleared screen's rows byte-for-byte, runs of spaces intact.
test_capture_returns_cleared_screen_rows_with_spaces() {
  local out
  orca_case capture-cleared-screen
  printf '%s\n' '{"ok":true,"result":{"terminal":{"source":"screen","tail":["➜  fm-t1 git:(fm-t1) echo alpha beta gamma","alpha beta gamma","│ >               │"]}}}' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_capture term-123 40' "$ROOT" )
  [ "$out" = $'➜  fm-t1 git:(fm-t1) echo alpha beta gamma\nalpha beta gamma\n│ >               │' ] \
    || fail "capture should return exactly the drawn screen rows with their spaces, got '$out'"
  pass "fm_backend_orca_capture: returns only the cleared screen's rows, spaces intact"
}

# A read Orca did not render from the drawn screen - accumulated output
# (source stream), a screen it could not render (screen-unavailable, which
# returns the accumulated output instead), or a host that predates the source
# field - is the history read that replays stale frames, so it is refused.
test_capture_refuses_reads_not_from_the_drawn_screen() {
  local case_name resp out status
  for case_name in stream screen-unavailable absent; do
    orca_case "capture-source-$case_name"
    case "$case_name" in
      absent) resp='{"ok":true,"result":{"terminal":{"tail":["stale banner"]}}}' ;;
      *) resp='{"ok":true,"result":{"terminal":{"source":"'"$case_name"'","tail":["stale banner"]}}}' ;;
    esac
    printf '%s\n' "$resp" > "$RESP/1.out"
    out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
      bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_capture term-abc 5' "$ROOT" 2>&1 )
    status=$?
    [ "$status" -ne 0 ] || fail "capture should refuse a read with source $case_name, got '$out'"
    assert_not_contains "$out" "stale banner" "capture must not print the text of a $case_name read"
    assert_contains "$out" "drawn screen" "capture should name the missing drawn-screen read for source $case_name"
    printf '%s\n' "${resp/stale banner/│ > │}" > "$RESP/2.out"
    out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
      bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state term-abc' "$ROOT" 2>/dev/null )
    [ "$out" = unknown ] || fail "composer state on a $case_name read should be unknown, got '$out'"
  done
  pass "fm_backend_orca_capture: refuses stream, screen-unavailable, and source-less reads; composer reads unknown"
}

# The viewport-only read is the whole drawn frame: --screen with no --limit,
# routed through the generic dispatcher that Kimi's trust gate and fm-control use.
test_visible_capture_reads_the_whole_drawn_screen() {
  local out
  orca_case visible-capture
  printf '{"ok":true,"result":{"terminal":{"source":"screen","tail":["row one","row two"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_visible_capture_supported orca && fm_backend_visible_capture orca term-vis fm-task' "$ROOT" )
  [ "$out" = $'row one\nrow two' ] || fail "visible capture should print the drawn screen rows, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f''term-vis'$'\x1f''--screen'$'\x1f''--json' \
    "visible capture should read --screen with no row limit"
  pass "fm_backend_visible_capture: orca advertises and reads the whole drawn screen"
}

# Liveness is not screen rendering: a live terminal whose screen Orca cannot
# render still exists, so the existence probe must not report it gone.
test_target_exists_accepts_live_terminal_without_a_rendered_screen() {
  local status
  orca_case target-exists-screen-unavailable
  printf '{"ok":true,"result":{"terminal":{"source":"screen-unavailable","status":"running","tail":["x"]}}}\n' > "$RESP/1.out"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_exists orca term-live fm-task' "$ROOT"
  status=$?
  [ "$status" -eq 0 ] || fail "fm_backend_target_exists should accept a live terminal whose screen is unavailable"
  pass "fm_backend_target_exists: orca liveness does not depend on a rendered screen"
}

# Orca's drawn-screen read omits blank rows (docs/verification/runtime-backends.md
# "Orca drawn-screen read"), so an empty bordered composer whose footer sat one
# blank row below it arrives with the footer directly under the box. That is
# still an empty composer, and text in it is still pending. A stale box with
# anything but a known footer below it - the zsh prompt that evidence records,
# a harness's exit message, transcript - is not, at one row as at two.
orca_screen_state() {  # <tail-json-array> -> composer verdict
  printf '%s\n' '{"ok":true,"result":{"terminal":{"source":"screen","tail":'"$1"'}}}' > "$RESP/1.out"
  rm -f "$RESP/.count"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state term-123' "$ROOT"
}

test_composer_state_empty_box_with_elided_footer_gap() {
  local box yolo tail out
  orca_case composer-elided-footer
  box='"╭──────────────────╮","│ >                │","╰──────────────────╯"'
  yolo='"╭──────────────────╮","│ permissions: YOLO│","╰──────────────────╯"'
  out=$(orca_screen_state "[$box,\"  ? for shortcuts\"]")
  [ "$out" = empty ] || fail "an empty box above an elided-gap footer should read empty, got '$out'"
  out=$(orca_screen_state '["╭──────────────────╮","│ > fix the tests  │","╰──────────────────╯","  ? for shortcuts"]')
  [ "$out" = pending ] || fail "a box holding text above an elided-gap footer should read pending, got '$out'"
  for tail in \
    "$box,\"➜  fm-pkgb git:(fm-pkgb)\"" \
    "$box,\"Error: session ended\",\"➜  fm-pkgb git:(fm-pkgb)\"" \
    "$box,\"Resume this session with:\"" \
    "$box,\"Resume this session with:\",\"claude --resume 1234\"" \
    "$yolo,\"line one\"" \
    "$yolo,\"line one\",\"line two\"" \
    "$yolo,\"line one\",\"line two\",\"line three\""; do
    out=$(orca_screen_state "[$tail]")
    [ "$out" = unknown ] || fail "a stale box above non-footer rows [$tail] should read unknown, got '$out'"
  done
  pass "fm_backend_orca_composer_state: only a known footer below a box survives the elided gap; prompts and transcript leave it stale"
}

# The steering inbox reads a held composer's text with the backend's own caps,
# so a boxed Orca composer holding a stuck doorbell with its footer gap elided
# still yields that text (fm_task_inbox_ring submits it instead of skipping).
test_task_inbox_reads_held_text_above_elided_footer_gap() {
  local out
  orca_case inbox-composer-text
  printf '%s\n' '{"ok":true,"result":{"terminal":{"source":"screen","tail":["╭──────────────────────╮","│ > : doorbell line x  │","╰──────────────────────╯","  ? for shortcuts"]}}}' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/fm-task-inbox-lib.sh"; fm_task_inbox_composer_text orca term-123' "$ROOT" )
  [ "$out" = ': doorbell line x' ] || fail "the held composer text should be read above an elided footer gap, got '$out'"
  pass "fm_task_inbox_composer_text: reads a boxed Orca composer's text above an elided footer gap"
}

test_capture_fails_on_orca_error_json() {
  local out status
  orca_case capture-error-json
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_capture term-stale 5' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail on Orca ok:false read JSON"
  assert_contains "$out" "terminal handle stale" "capture should surface the Orca read error message"
  pass "fm_backend_orca_capture: fails closed on Orca read error JSON"
}

test_runtime_check_accepts_ready_orca_status() {
  local out
  orca_case runtime-ready
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_STATUS_RESPONSE=sequence \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_runtime_check' "$ROOT" )
  [ -z "$out" ] || fail "runtime_check should be quiet on ready status, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''status'$'\x1f''--json' \
    "runtime_check did not call orca status --json"
  pass "fm_backend_orca_runtime_check: accepts reachable ready runtime"
}

test_runtime_check_refuses_unready_orca_status() {
  local out status
  orca_case runtime-unready
  printf '{"ok":true,"result":{"runtime":{"reachable":false,"state":"starting"}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_STATUS_RESPONSE=sequence \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_runtime_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check should fail when Orca runtime is not ready"
  assert_contains "$out" "requires a ready Orca runtime" "runtime_check should explain the readiness requirement"
  pass "fm_backend_orca_runtime_check: fails closed when runtime is not ready"
}

test_send_text_submit_verifies_empty_composer_after_enter() {
  local out
  orca_case send-submit
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"source":"screen","tail":["╭───╮","│ > │","╰───╯"]}}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should report empty on successful Orca send, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f''hello captain'$'\x1f''--json' \
    "send_text_submit did not type the text literally before Enter"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f\x1f''--enter'$'\x1f''--json' \
    "send_text_submit did not send Enter after typing"
  # The composer read is ONE bounded tail read: the old backward paging
  # (--cursor follow-ups on a limited page) is deleted, because paging into
  # scrollback is what let a stale startup banner compete with the live
  # composer (audit fm-composer-consolidation-audit-s1, section 3.3).
  assert_not_contains "$(cat "$LOG")" $'\x1f''--cursor'$'\x1f' \
    "the composer read must never page backward into scrollback"
  pass "fm_backend_orca_send_text_submit: verifies empty composer after Enter with one bounded read"
}

test_send_text_submit_borderless_claude_confirms() {
  # The #2029 analogue this adapter never received: a borderless claude
  # composer (bare `❯` row between horizontal rules) must confirm a submit.
  # Before consolidation orca knew only the bordered shape, so every steer to
  # a borderless harness exited unconfirmed and --resolve-key never closed.
  local out
  orca_case send-submit-borderless
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"source":"screen","tail":["────────────────","❯","────────────────"]}}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "a borderless claude composer should confirm the submit, got '$out'"
  pass "fm_backend_orca_send_text_submit: a borderless claude composer confirms delivery (the missing #2029 shape)"
}

test_composer_state_stale_banner_never_wins() {
  # The audit's confidently-wrong case (section 3.3): codex's startup banner
  # (`│ permissions: YOLO mode │` inside a rounded box) classified as the
  # composer, reading `pending` for a row that is not a composer at all. With
  # the full shape catalogue the live bare row below the banner wins; with a
  # plain capture its trailing hint text is unreadable, so the verdict is
  # `unknown` (defer) - never the banner's false `pending`.
  local out
  orca_case composer-stale-banner
  printf '{"ok":true,"result":{"terminal":{"source":"screen","tail":["╭────────────────────────╮","│ permissions: YOLO mode │","╰────────────────────────╯","› Use /skills to list available skills"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state term-123' "$ROOT" )
  [ "$out" != pending ] || fail "a stale startup banner must never classify as pending composer text"
  [ "$out" = unknown ] || fail "the plain-capture codex hint should defer as unknown, got '$out'"
  pass "fm_backend_orca_composer_state: a stale startup banner cannot outrank the live composer row"
}

test_send_text_submit_retries_when_composer_stays_pending() {
  local out log_text enter_count
  orca_case send-submit-pending
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"source":"screen","tail":["╭─────────────────╮","│ > hello captain │","╰─────────────────╯"]}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{"terminal":{"source":"screen","tail":["╭─────────────────╮","│ >               │","╰─────────────────╯"]}}}\n' > "$RESP/5.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should retry Enter until the composer clears, got '$out'"
  log_text=$(cat "$LOG")
  enter_count=$(printf '%s\n' "$log_text" | grep -c $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-123\x1f--text\x1f\x1f--enter\x1f--json')
  [ "$enter_count" -eq 2 ] || fail "send_text_submit should send Enter twice when the first read is pending, got $enter_count"
  pass "fm_backend_orca_send_text_submit: retries Enter while composer remains pending"
}

test_composer_state_popup_placeholder_fill_is_pending() {
  local out
  orca_case composer-popup-placeholder
  printf '{"ok":true,"result":{"terminal":{"source":"screen","tail":["  ╭──────────────────────────────────────╮","  │ ❯ /compact compaction instructions   │","  ╰──────────────── Composer ────────────╯","","  Enter:send"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state term-123' "$ROOT" )
  [ "$out" = pending ] || fail "a popup-close-with-placeholder-fill must still read as pending (not yet submitted), got '$out'"
  pass "fm_backend_orca_composer_state: a slash-command popup's argument-hint placeholder still reads pending"
}

# Dead-shell injection safety (task fm-composer-shellglyph-safety): a pane whose
# agent has exited to a bare login shell has no bordered composer row, so the
# classifier finds nothing and reports `unknown` - NOT a safe (empty) injection
# target. Covers the same guarantee herdr/cmux/tmux tests pin for their backends.
test_composer_state_bare_shell_prompt_is_unknown() {
  local out
  orca_case composer-bare-shell
  printf '{"ok":true,"result":{"terminal":{"source":"screen","tail":["some earlier output","kunchen@mac firstmate $ "]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state term-123' "$ROOT" )
  [ "$out" = unknown ] || fail "a bare dead-shell prompt (no bordered composer row) must read unknown, got '$out'"
  pass "fm_backend_orca_composer_state: a bare dead-shell prompt reads unknown (unsafe-for-injection), never empty"
}

test_send_text_submit_popup_autocomplete_requires_second_enter() {
  local out log_text enter_count
  orca_case send-submit-popup-autocomplete
  # 1: literal send "/compact"
  # 2: Enter #1 closes the popup and fills the placeholder
  # 3: read - composer still holds real pending text
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"source":"screen","tail":["  ╭──────────────────────────────────────╮","  │ ❯ /compact compaction instructions   │","  ╰──────────────── Composer ────────────╯","","  Enter:send"]}}}\n' > "$RESP/3.out"
  # 4: Enter #2 actually submits
  # 5: read - composer is empty
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{"terminal":{"source":"screen","tail":["  ╭────────────────────────╮","  │ ❯                      │","  ╰──────── Composer ──────╯","","  Shift+Tab:mode"]}}}\n' > "$RESP/5.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "/compact" 3 0.01 1.2' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should eventually report empty once the SECOND Enter actually clears the composer, got '$out'"
  log_text=$(cat "$LOG")
  enter_count=$(printf '%s\n' "$log_text" | grep -c $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-123\x1f--text\x1f\x1f--enter\x1f--json')
  [ "$enter_count" -eq 2 ] || fail "send_text_submit must send a SECOND Enter after the popup-placeholder fill still reads pending, got $enter_count Enter(s)"
  pass "fm_backend_orca_send_text_submit: a slash-command popup's placeholder fill on Enter #1 does not short-circuit as submitted; Enter #2 is retried and lands it"
}

test_send_literal_constructs_non_enter_send() {
  orca_case send-literal
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_literal term-123 "typed only"' "$ROOT"
  expect_code 0 $? "send_literal should succeed"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f''typed only'$'\x1f''--json' \
    "send_literal did not send text without --enter"
  assert_not_contains "$(cat "$LOG")" $'\x1f''--enter' "send_literal should not submit Enter"
  pass "fm_backend_orca_send_literal: sends text without submitting"
}

test_send_text_submit_reports_send_failed() {
  local out
  orca_case send-fail
  printf '1\n' > "$RESP/1.exit"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello" 1 0.01 0.01' "$ROOT" )
  [ "$out" = send-failed ] || fail "failed Orca send should report send-failed, got '$out'"
  pass "fm_backend_orca_send_text_submit: reports send-failed when Orca send fails"
}

test_send_helpers_reject_orca_error_json() {
  local out status
  orca_case send-error-json
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_line term-stale "hello"' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_text_line should fail on Orca ok:false JSON"
  assert_contains "$out" "terminal handle stale" "send_text_line should surface the Orca send error"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/2.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_literal term-stale "typed"' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_literal should fail on Orca ok:false JSON"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-stale Enter' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should fail on Orca ok:false JSON"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/4.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-stale "hello" 1 0.01 0.01' "$ROOT" 2>/dev/null )
  [ "$out" = send-failed ] || fail "send_text_submit should report send-failed on Orca ok:false JSON, got '$out'"
  pass "Orca send helpers: fail closed on ok:false JSON"
}

test_send_key_enter_and_interrupt() {
  orca_case send-key
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-123 Enter; fm_backend_orca_send_key term-123 C-c' "$ROOT"
  expect_code 0 $? "send_key Enter and C-c should succeed"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f\x1f''--enter'$'\x1f''--json' \
    "send_key Enter did not send empty text with --enter"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--interrupt'$'\x1f''--json' \
    "send_key C-c did not send --interrupt"
  pass "fm_backend_orca_send_key: Enter maps to empty enter, C-c maps to interrupt"
}

test_send_key_refuses_unknown_key() {
  local out status
  orca_case send-key-unknown
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-123 F12' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should refuse unsupported Orca keys"
  assert_contains "$out" "unsupported Orca key 'F12'" "send_key did not name the unsupported key"
  pass "fm_backend_orca_send_key: refuses unsupported keys loudly"
}

test_send_key_escape_and_composer_keys_are_raw_bytes() {
  local out status
  orca_case send-key-raw
  mv "$FB/orca" "$FB/orca-ide"
  out=$( PATH="$FB:$(fm_test_base_path_sans "$PATH" orca orca-ide)" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-123 Escape && fm_backend_orca_send_key term-123 C-u && ! fm_backend_orca_send_key term-123 C-g' "$ROOT" 2>&1 )
  status=$?
  expect_code 0 "$status" "send_key Escape and C-u should succeed and C-g should be refused"
  assert_contains "$out" "unsupported Orca key 'C-g'" "send_key did not refuse C-g"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f\x1b\x1f''--json' \
    "send_key Escape did not send the raw Escape byte without --enter"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f\x15\x1f''--json' \
    "send_key C-u did not send the raw Ctrl+U byte without --enter"
  case "$(cat "$LOG")" in *$'\x07'*) fail "a refused C-g must not reach orca" ;; esac
  case "$(cat "$LOG")" in *--enter*|*--interrupt*) fail "a raw key must not carry --enter or --interrupt" ;; esac
  pass "fm_backend_orca_send_key: Escape and C-u go as raw control bytes through orca-ide alone; C-g is refused"
}

# A re-close of an already-closed terminal is what a cleanup re-run sends, so
# a close that exits nonzero still succeeds once the re-read reports exited.
test_kill_succeeds_when_the_reread_reports_exited() {
  orca_case kill
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"terminal":{"status":"exited"}}}\n' > "$RESP/2.out"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_kill term-123' "$ROOT"
  expect_code 0 $? "kill should succeed when the re-read reports the terminal exited"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--json' \
    "kill did not call orca terminal close"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--limit'$'\x1f''1'$'\x1f''--json' \
    "kill did not re-read the terminal after closing it"
  pass "fm_backend_orca_kill: closes, then succeeds on a re-read that reports exited"
}

# A close that did not take - the terminal still running, a stale handle, or a
# re-read with no answer - is reported, never passed off as a closed terminal.
test_kill_refuses_when_the_close_did_not_take() {
  local case_name resp out status n
  for case_name in running stale silent; do
    orca_case "kill-not-closed-$case_name"
    case "$case_name" in
      running) resp='{"ok":true,"result":{"terminal":{"status":"running"}}}' ;;
      stale) resp='{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal_handle_stale"}}' ;;
      silent) resp='' ;;
    esac
    printf '{"ok":true,"result":{"close":{"ptyKilled":false}}}\n' > "$RESP/1.out"
    for n in 2 3 4 5 6 7 8 9 10 11; do
      [ -z "$resp" ] || printf '%s\n' "$resp" > "$RESP/$n.out"
    done
    out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
      bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_kill term-123' "$ROOT" 2>&1 )
    status=$?
    [ "$status" -ne 0 ] || fail "kill reported a $case_name terminal closed"
    assert_contains "$out" "Orca terminal term-123 did not close" "kill did not report the $case_name close"
    case "$case_name" in
      running) assert_contains "$out" "still reports the terminal running" "kill did not name the running terminal" ;;
      stale) assert_contains "$out" "terminal_handle_stale" "kill did not name the stale handle" ;;
    esac
  done
  pass "fm_backend_orca_kill: a terminal still running, a stale handle, or a silent re-read reports the close failed"
}

# test_kill_succeeds_when_the_reread_reports_exited above has an `orca` stub
# present; this case is the CLI-absent direction, where no close was attempted.
test_kill_refuses_when_the_orca_cli_is_absent() {
  local out status orca_free
  orca_case kill-no-cli
  orca_free=$(fm_test_base_path_sans "$PATH" orca orca-ide)
  ! PATH="$orca_free" command -v orca >/dev/null 2>&1 \
    || fail "the orca-free search path still resolved orca"
  ! PATH="$orca_free" command -v orca-ide >/dev/null 2>&1 \
    || fail "the orca-free search path still resolved orca-ide"
  PATH="$orca_free" command -v bash >/dev/null 2>&1 \
    || fail "the orca-free search path lost bash, so this case would pass vacuously"
  out=$( PATH="$orca_free" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_kill term-123' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "kill reported success for a close its missing CLI never attempted"
  assert_contains "$out" "backend=orca selected but the Orca CLI was not found: neither 'orca' nor 'orca-ide' is on PATH" \
    "kill did not name the missing CLI as the reason the close never happened"
  [ ! -s "$LOG" ] || fail "kill invoked orca despite the CLI being absent"
  pass "fm_backend_orca_kill: a close its missing CLI never attempted reports the failure instead of a success"
}

# Linux names the Orca CLI orca-ide, and a paired Orca server's install leaves
# it in ~/.orca/cli/bin off PATH; every adapter call must reach whichever the
# host has, with `orca-ide` winning where one PATH directory holds both.
test_cli_resolves_orca_ide_and_paired_server_install() {
  local orca_free out
  orca_free=$(fm_test_base_path_sans "$PATH" orca orca-ide)

  orca_case cli-orca-ide-on-path
  printf '{"ok":true,"result":{"terminal":{"status":"exited"}}}\n' > "$RESP/2.out"
  mv "$FB/orca" "$FB/orca-ide"
  PATH="$FB:$orca_free" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_kill term-123' "$ROOT"
  expect_code 0 $? "kill should succeed through orca-ide on PATH"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "orca-ide on PATH was not used when orca is absent"

  orca_case cli-both-on-path
  printf '{"ok":true,"result":{"terminal":{"status":"exited"}}}\n' > "$RESP/2.out"
  mv "$FB/orca" "$FB/orca-ide"
  printf '#!/bin/sh\necho ran >> "%s"\nexit 1\n' "$CASE_DIR/bare-orca-ran" > "$FB/orca"
  chmod +x "$FB/orca"
  PATH="$FB:$orca_free" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_kill term-123' "$ROOT"
  expect_code 0 $? "kill should succeed through orca-ide beside orca"
  [ ! -e "$CASE_DIR/bare-orca-ran" ] || fail "orca should not win over orca-ide in the same PATH directory"

  orca_case cli-bare-orca-only
  printf '{"ok":true,"result":{"terminal":{"status":"exited"}}}\n' > "$RESP/2.out"
  rm "$FB/orca-ide"
  out=$( PATH="$FB:$orca_free" FM_BACKEND_ORCA_BUNDLE_BIN="$CASE_DIR/no-bundle/orca-ide" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_runtime_check && fm_backend_orca_kill term-123' "$ROOT" 2>&1 )
  expect_code 0 $? "runtime check and kill should succeed through a bare orca on PATH (macOS): $out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''status' "a bare orca on PATH did not answer the readiness check"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' "a bare orca on PATH was not used as the last resort"

  orca_case cli-paired-server-install
  printf '{"ok":true,"result":{"terminal":{"status":"exited"}}}\n' > "$RESP/2.out"
  mv "$FB/orca" "$FB/orca-ide"
  out=$( PATH="$orca_free" FM_BACKEND_ORCA_BUNDLE_BIN="$FB/orca-ide" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_runtime_check && fm_backend_orca_kill term-123' "$ROOT" 2>&1 )
  expect_code 0 $? "runtime check and kill should succeed through the paired-server install: $out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''status' "the paired-server install did not answer the readiness check"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' "the paired-server install was not used off PATH"
  pass "fm_backend_orca_bin: reaches orca-ide on PATH, the paired-server install, then a bare orca"
}

# A Linux GNOME desktop ships its screen reader as /usr/bin/orca. With a paired
# Orca server's CLI off PATH in ~/.orca/cli/bin, the adapter must drive that
# install and never run the screen reader.
test_paired_server_install_beats_a_non_orca_orca_on_path() {
  local orca_free gnome out
  orca_free=$(fm_test_base_path_sans "$PATH" orca orca-ide)
  orca_case cli-gnome-orca-on-path
  printf '{"ok":true,"result":{"terminal":{"status":"exited"}}}\n' > "$RESP/2.out"
  mv "$FB/orca" "$FB/orca-ide"
  gnome="$CASE_DIR/gnome-bin"
  mkdir -p "$gnome"
  printf '#!/bin/sh\necho ran >> "%s"\nexit 1\n' "$CASE_DIR/gnome-ran" > "$gnome/orca"
  chmod +x "$gnome/orca"
  out=$( PATH="$gnome:$orca_free" FM_BACKEND_ORCA_BUNDLE_BIN="$FB/orca-ide" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_runtime_check && fm_backend_orca_kill term-123' "$ROOT" 2>&1 )
  expect_code 0 $? "runtime check and kill should succeed through the paired-server install: $out"
  [ ! -e "$CASE_DIR/gnome-ran" ] || fail "the non-Orca orca on PATH was run instead of the paired-server install"
  assert_contains "$(cat "$LOG")" $'orca\x1f''status' "the paired-server install did not answer the readiness check"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' "the paired-server install was not used"
  pass "fm_backend_orca_bin: a paired-server install wins over a non-Orca orca on PATH"
}

test_remove_worktree_refuses_empty_id() {
  local out status
  orca_case remove-empty
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_remove_worktree ""' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "remove_worktree should fail when the Orca worktree id is empty"
  assert_contains "$out" "missing Orca worktree id" "remove_worktree did not explain the missing id"
  [ ! -s "$LOG" ] || fail "remove_worktree should not call Orca with an empty id"
  pass "fm_backend_orca_remove_worktree: refuses empty worktree ids"
}

test_remove_worktree_rejects_orca_error_json() {
  local out status
  orca_case remove-error-json
  printf '{"ok":false,"error":{"code":"worktree_not_found","message":"worktree not found"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_remove_worktree wt-gone::/orca/wt-gone' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "remove_worktree should fail on Orca ok:false JSON"
  assert_contains "$out" "worktree not found" "remove_worktree should surface the Orca removal error"
  pass "fm_backend_orca_remove_worktree: fails closed on ok:false JSON"
}

test_remove_worktree_deletes_the_branch_only_when_asked() {
  local out
  orca_case remove-branch-choice
  printf '{"ok":true,"result":{"removed":true}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"removed":true,"preservedBranch":{"branchName":"fm/kept","head":"abc"}}}\n' > "$RESP/2.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"
      fm_backend_orca_remove_worktree wt-a::/orca/wt-a || exit 1
      fm_backend_orca_remove_worktree wt-b::/orca/wt-b delete-branch' "$ROOT" 2>&1 )
  expect_code 0 $? "remove_worktree should succeed on removed:true$'\n'$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-a::/orca/wt-a'$'\x1f''--force'$'\x1f''--json' \
    "remove_worktree without delete-branch should keep the branch"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-b::/orca/wt-b'$'\x1f''--force'$'\x1f''--delete-branch'$'\x1f''--json' \
    "remove_worktree delete-branch should pass --delete-branch"
  assert_not_contains "$(head -1 "$LOG")" "--delete-branch" "remove_worktree passed --delete-branch unasked"
  assert_contains "$out" "Orca kept branch fm/kept" "remove_worktree should name a branch Orca kept"
  pass "fm_backend_orca_remove_worktree: --delete-branch only when asked, and a branch Orca kept is named"
}

test_worktree_path_resolves_id() {
  local out
  orca_case path-resolve
  printf '{"ok":true,"result":{"worktree":{"id":"wt-123::/orca/wt-123","path":"/tmp/orca-wt"}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_path wt-123::/orca/wt-123' "$ROOT" )
  [ "$out" = /tmp/orca-wt ] || fail "worktree path helper should print the resolved path, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-123::/orca/wt-123'$'\x1f''--json' \
    "worktree path helper did not call orca worktree show"
  pass "fm_backend_orca_worktree_path: resolves an Orca worktree id to its path"
}

test_json_get_ignores_undocumented_terminal_id_shapes() {
  local out status wt_id wt_path term
  orca_case parser-pruned-terminal-shapes

  set +e
  out=$( printf '{"ok":true,"result":{"id":"term-root-id"}}\n' | \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_json_get terminal-handle' "$ROOT" )
  status=$?
  set +e
  [ "$status" -ne 0 ] || fail "terminal-handle should not treat undocumented result.id as a terminal handle, got '$out'"

  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-123"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-123::/orca/wt-123","path":"/tmp/orca-wt","terminal":{"handle":"term-nested"}}}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create /repo/path fm-task' "$ROOT" )
  wt_id=${out%%$'\t'*}
  wt_path=${out#*$'\t'}
  term=${wt_path#*$'\t'}
  wt_path=${wt_path%%$'\t'*}
  [ "$wt_id" = wt-123::/orca/wt-123 ] || fail "worktree helper should still print worktree id, got '$wt_id'"
  [ "$wt_path" = /tmp/orca-wt ] || fail "worktree helper should still print worktree path, got '$wt_path'"
  [ "$term" = "$wt_path" ] || fail "worktree helper should ignore undocumented result.worktree.terminal and omit an implicit terminal, got '$out'"
  pass "fm_backend_orca_json_get: ignores undocumented terminal id shapes"
}

test_worktree_and_terminal_helpers_parse_json() {
  local out wt_id wt_path term
  orca_case lifecycle-helpers
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-123"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-123::/orca/wt-123","path":"/tmp/orca-wt"}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"handle":"term-123"}}}\n' > "$RESP/4.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create /repo/path fm-task' "$ROOT" )
  wt_id=${out%%$'\t'*}
  wt_path=${out#*$'\t'}
  [ "$wt_id" = wt-123::/orca/wt-123 ] || fail "worktree helper should print worktree id, got '$wt_id'"
  [ "$wt_path" = /tmp/orca-wt ] || fail "worktree helper should print worktree path, got '$wt_path'"
  term=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_terminal_create wt-123::/orca/wt-123 fm-task' "$ROOT" )
  [ "$term" = term-123 ] || fail "terminal helper should print terminal handle, got '$term'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''repo'$'\x1f''show'$'\x1f''--repo'$'\x1f''path:/repo/path'$'\x1f''--json' \
    "worktree helper should first check repo registration"
  assert_contains "$(cat "$LOG")" $'orca\x1f''repo'$'\x1f''add'$'\x1f''--path'$'\x1f''/repo/path'$'\x1f''--json' \
    "worktree helper should register an absent repo"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''create'$'\x1f''--repo'$'\x1f''id:repo-123'$'\x1f''--name'$'\x1f''fm-task'$'\x1f''--no-parent'$'\x1f''--setup'$'\x1f''skip'$'\x1f''--json' \
    "worktree helper did not create an independent no-hook worktree"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create'$'\x1f''--worktree'$'\x1f''id:wt-123::/orca/wt-123'$'\x1f''--title'$'\x1f''fm-task'$'\x1f''--json' \
    "terminal helper did not create a titled terminal for the worktree"
  pass "Orca lifecycle helpers: register repo, create worktree, create terminal, parse stable ids"
}

test_worktree_create_removes_worktree_when_path_missing() {
  local out status
  orca_case lifecycle-missing-path
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-no-path"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-no-path::/orca/wt-no-path"},"terminal":{"handle":"term-no-path"}}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create /repo/path fm-task' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "worktree helper should fail when Orca omits the worktree path"
  assert_contains "$out" "orca worktree create did not return a path for fm-task" \
    "worktree helper did not explain the missing path"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-no-path'$'\x1f''--json' \
    "worktree helper did not close the implicit terminal when path parsing failed"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-no-path::/orca/wt-no-path'$'\x1f''--force'$'\x1f''--json' \
    "worktree helper did not remove the pathless Orca worktree"
  pass "fm_backend_orca_worktree_create: removes created worktree when path is missing"
}

test_spawn_preserves_orca_metadata_when_pathless_worktree_cleanup_fails() {
  local proj data state config id out status
  id="orcapathlessz6"
  proj="$TMP_ROOT/pathless-cleanup-project"
  data="$TMP_ROOT/pathless-cleanup-data"
  state="$TMP_ROOT/pathless-cleanup-state"
  config="$TMP_ROOT/pathless-cleanup-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case pathless-cleanup-fail
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-pathless-cleanup"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-pathless-cleanup::/orca/wt-pathless-cleanup"}}}\n' > "$RESP/3.out"
  printf '{"ok":false,"error":{"code":"worktree_not_removed","message":"worktree not removed"}}\n' > "$RESP/4.out"
  printf '{"ok":false,"error":{"code":"worktree_not_removed","message":"worktree not removed"}}\n' > "$RESP/5.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when path parsing and cleanup fail"
  assert_contains "$out" "orca worktree create did not return a path" \
    "pathless worktree failure should explain the missing path"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-pathless-cleanup::/orca/wt-pathless-cleanup'$'\x1f''--force'$'\x1f''--json' \
    "pathless cleanup should attempt helper-backed worktree removal"
  assert_present "$state/$id.meta" "failed pathless cleanup should preserve metadata"
  assert_grep "window=fm-$id" "$state/$id.meta" "preserved pathless metadata missing stable window alias"
  assert_grep "backend=orca" "$state/$id.meta" "preserved pathless metadata missing backend=orca"
  assert_grep "orca_worktree_id=wt-pathless-cleanup::/orca/wt-pathless-cleanup" "$state/$id.meta" "preserved pathless metadata missing Orca worktree id"
  assert_no_grep "terminal=" "$state/$id.meta" "preserved pathless metadata should not invent a terminal handle"
  pass "fm-spawn.sh --backend orca: preserves metadata when pathless cleanup fails"
}

test_spawn_writes_orca_metadata_and_launches_harness() {
  local proj wt data state config id out log staged launch
  id="orcaspawnz1"
  proj="$TMP_ROOT/spawn-project"
  wt="$TMP_ROOT/spawn-wt"
  data="$TMP_ROOT/spawn-data"
  state="$TMP_ROOT/spawn-state"
  config="$TMP_ROOT/spawn-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case spawn
  log="$LOG"
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-spawn"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-spawn::/orca/wt-spawn","path":"%s"},"terminal":{"handle":"term-spawn"}}}\n' "$wt" > "$RESP/3.out"
  # Two settled reads of a bare prompt, then Orca places the terminal in the
  # new worktree and lists no agent on its pane: spawn's proof before its first key.
  printf '{"ok":true,"result":{"terminal":{"source":"screen","tail":["➜  %s git:(task)"]}}}\n' "${wt##*/}" | tee "$RESP/4.out" > "$RESP/5.out"
  printf '{"ok":true,"result":{"terminal":{"handle":"term-spawn","worktreeId":"wt-spawn::/orca/wt-spawn","tabId":"tab-1","leafId":"leaf-1"}}}\n' > "$RESP/6.out"
  printf '{"ok":true,"result":{"agents":[]}}\n' > "$RESP/7.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  expect_code 0 $? "fm-spawn.sh --backend orca should succeed with fake Orca"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=claude kind=ship mode=no-mistakes yolo=off window=fm-$id worktree=$wt" \
    "spawn output missing Orca window/worktree summary"
  assert_grep "backend=orca" "$state/$id.meta" "meta missing backend=orca"
  assert_grep "window=fm-$id" "$state/$id.meta" "meta missing stable Orca window alias"
  assert_grep "terminal=term-spawn" "$state/$id.meta" "meta missing terminal handle"
  assert_grep "orca_worktree_id=wt-spawn::/orca/wt-spawn" "$state/$id.meta" "meta missing Orca worktree id"
  assert_grep "worktree=$wt" "$state/$id.meta" "meta missing Orca worktree path"
  assert_not_contains "$(cat "$log")" $'orca\x1f''terminal'$'\x1f''create' \
    "spawn should reuse the implicit terminal returned by Orca worktree creation"
  assert_contains "$(cat "$log")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-spawn'$'\x1f''--text'$'\x1f''export GOTMPDIR=/tmp/fm-orcaspawnz1/gotmp'$'\x1f''--enter'$'\x1f''--json' \
    "spawn did not export GOTMPDIR through the Orca terminal"
  staged=$(tr '\037' '\n' < "$log" | sed -n "s/^\. '\([^']*\)'$/\1/p" | tail -1)
  [ -n "$staged" ] && [ -f "$staged" ] \
    || fail "spawn did not send Orca a readable staged launch command"
  launch=$(cat "$staged")
  add_dirs="--add-dir '$(cd "$state" && pwd -P)/operational-inbox' --add-dir '$(cd "$state" && pwd -P)/$id.inbox' --add-dir '$(cd "$data" && pwd -P)/$id' --add-dir '$(cd "$ROOT" && pwd -P)/.agents/skills'"
  assert_contains "$launch" "CLAUDE_CODE_DISABLE_WORKFLOWS=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions $add_dirs --name '$id' --settings '{\"feedbackDrafts\":\"off\",\"attribution\":{\"commit\":\"\",\"pr\":\"\",\"sessionUrl\":false},\"disableWorkflows\":true}'" \
    "the staged launch sent through Orca did not select the Claude harness"
  rm -rf "/tmp/fm-$id" "$(dirname "$staged")"
  pass "fm-spawn.sh --backend orca: reuses implicit terminal, records metadata, launches harness"
}

test_spawn_orca_secondmate_opens_terminal_in_home() {
  local home subhome data state config id out status log
  id="orcasmz1"
  home="$TMP_ROOT/secondmate-home"
  subhome="$TMP_ROOT/secondmate-subhome"
  data="$home/data"
  state="$home/state"
  config="$home/config"
  mkdir -p "$data" "$state" "$config" "$subhome/bin" "$subhome/data" "$subhome/state" "$subhome/config" "$subhome/projects"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf 'firstmate\n' > "$subhome/AGENTS.md"
  printf '# Charter\n\nSecondmate charter for %s.\n' "$id" > "$subhome/data/charter.md"
  printf 'projects/\nstate/\ndata/\nconfig/\n.no-mistakes/\n' > "$subhome/.gitignore"
  git -C "$subhome" init -q -b main
  subhome=$(cd "$subhome" && pwd -P)
  touch "$state/.last-watcher-beat"
  orca_case secondmate-spawn
  log="$LOG"
  # Orca does not know the home yet, registers it as a folder project, and
  # resolves the project root entry; then a fresh terminal there passes the
  # same pre-key guard as any spawn.
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-home","kind":"folder"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"repo-home::%s","path":"%s"}}}\n' "$subhome" "$subhome" > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"handle":"term-seat"}}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{"terminal":{"source":"screen","tail":["seat$"]}}}\n' | tee "$RESP/5.out" > "$RESP/6.out"
  printf '{"ok":true,"result":{"terminal":{"handle":"term-seat","worktreeId":"repo-home::%s","tabId":"tab-1","leafId":"leaf-1"}}}\n' "$subhome" > "$RESP/7.out"
  printf '{"ok":true,"result":{"agents":[]}}\n' > "$RESP/8.out"
  set +e
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$subhome" "sh -c 'exit 0'" --backend orca --secondmate 2>&1 )
  status=$?
  set +e
  expect_code 0 "$status" "backend=orca --secondmate should spawn with fake Orca"$'\n'"$out"
  assert_contains "$(cat "$log")" $'orca\x1f''repo'$'\x1f''add'$'\x1f''--path'$'\x1f'"$subhome"$'\x1f''--kind'$'\x1f''folder'$'\x1f''--json' \
    "a secondmate home should be registered as an Orca folder project"
  assert_contains "$(cat "$log")" $'orca\x1f''terminal'$'\x1f''create'$'\x1f''--worktree'$'\x1f'"id:repo-home::$subhome" \
    "the seat terminal should open in the home's project root entry"
  assert_not_contains "$(cat "$log")" $'orca\x1f''worktree'$'\x1f''create' \
    "a secondmate spawn must not create an Orca worktree"
  assert_grep "kind=secondmate" "$state/$id.meta" "meta missing kind=secondmate"
  assert_grep "backend=orca" "$state/$id.meta" "meta missing backend=orca"
  assert_grep "terminal=term-seat" "$state/$id.meta" "meta missing the seat terminal"
  assert_grep "orca_worktree_id=repo-home::$subhome" "$state/$id.meta" "meta missing the home's Orca entry"
  pass "fm-spawn.sh --backend orca --secondmate: opens one terminal in the home's Orca folder project"
}

test_spawn_orca_secondmate_refuses_a_mismatched_home_entry() {
  local home subhome data state config id out status
  id="orcasmz2"
  home="$TMP_ROOT/secondmate-mismatch-home"
  subhome="$TMP_ROOT/secondmate-mismatch-subhome"
  data="$home/data"
  state="$home/state"
  config="$home/config"
  mkdir -p "$data" "$state" "$config" "$subhome/bin" "$subhome/data" "$subhome/state" "$subhome/config" "$subhome/projects"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf 'firstmate\n' > "$subhome/AGENTS.md"
  printf '# Charter\n\nSecondmate charter for %s.\n' "$id" > "$subhome/data/charter.md"
  printf 'projects/\nstate/\ndata/\nconfig/\n.no-mistakes/\n' > "$subhome/.gitignore"
  git -C "$subhome" init -q -b main
  touch "$state/.last-watcher-beat"
  orca_case secondmate-mismatch
  printf '{"ok":true,"result":{"repo":{"id":"repo-other"}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"worktree":{"id":"repo-other::/elsewhere","path":"/elsewhere"}}}\n' > "$RESP/2.out"
  set +e
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$subhome" "sh -c 'exit 0'" --backend orca --secondmate 2>&1 )
  status=$?
  set +e
  [ "$status" -ne 0 ] || fail "a home Orca resolves to another path should refuse"
  assert_contains "$out" "refusing to open a seat there" "the mismatch refusal should name the seat"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create' \
    "no terminal should open after the home entry mismatch"
  assert_absent "$state/$id.meta" "a refused seat spawn should publish no record"
  pass "fm-spawn.sh --backend orca --secondmate: refuses a home entry at another path before opening a terminal"
}

test_spawn_refuses_orca_when_runtime_not_ready() {
  local proj data state config id out status
  id="orcaruntimez6"
  proj="$TMP_ROOT/runtime-down-project"
  data="$TMP_ROOT/runtime-down-data"
  state="$TMP_ROOT/runtime-down-state"
  config="$TMP_ROOT/runtime-down-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case runtime-down-spawn
  printf '{"ok":true,"result":{"runtime":{"reachable":false,"state":"starting"}}}\n' > "$RESP/1.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_STATUS_RESPONSE=sequence \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn.sh --backend orca should refuse when Orca runtime is not ready"
  assert_contains "$out" "requires a ready Orca runtime" \
    "runtime readiness refusal should explain the Orca requirement"
  assert_absent "$state/$id.meta" "runtime refusal must not record metadata"
  assert_contains "$(cat "$LOG")" $'orca\x1f''status'$'\x1f''--json' \
    "spawn did not probe Orca runtime readiness"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''repo' \
    "spawn should fail before repo/worktree creation when runtime is not ready"
  pass "fm-spawn.sh --backend orca: refuses before mutation when Orca runtime is not ready"
}

test_spawn_refuses_orca_nonisolated_worktree() {
  local proj data state config id out status
  id="orcabadwtz4"
  proj="$TMP_ROOT/bad-spawn-project"
  data="$TMP_ROOT/bad-spawn-data"
  state="$TMP_ROOT/bad-spawn-state"
  config="$TMP_ROOT/bad-spawn-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case bad-spawn
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-bad"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-bad::/orca/wt-bad","path":"%s"},"terminal":{"handle":"term-bad"}}}\n' "$proj" > "$RESP/3.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  expect_code 1 "$status" "fm-spawn.sh --backend orca should refuse a primary checkout worktree"
  assert_contains "$out" "orca worktree create did not yield an isolated worktree" \
    "Orca spawn should reuse the isolated-worktree guard"
  assert_absent "$state/$id.meta" "aborted Orca spawn must not record meta"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create' \
    "Orca spawn should validate the worktree before creating a terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-bad'$'\x1f''--json' \
    "Orca spawn should close the implicit terminal after validation aborts"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-bad::/orca/wt-bad'$'\x1f''--force'$'\x1f''--json' \
    "Orca spawn should remove the worktree after validation aborts"
  pass "fm-spawn.sh --backend orca: refuses non-isolated worktrees and closes implicit terminals"
}

test_spawn_removes_orca_worktree_when_terminal_create_fails() {
  local proj wt data state config id out status
  id="orcatermfailz8"
  proj="$TMP_ROOT/terminal-fail-project"
  wt="$TMP_ROOT/terminal-fail-wt"
  data="$TMP_ROOT/terminal-fail-data"
  state="$TMP_ROOT/terminal-fail-state"
  config="$TMP_ROOT/terminal-fail-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case terminal-fail
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-terminal-fail"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-terminal-fail::/orca/wt-terminal-fail","path":"%s"}}}\n' "$wt" > "$RESP/3.out"
  printf '1\n' > "$RESP/4.exit"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when terminal creation fails"
  assert_absent "$state/$id.meta" "terminal-create abort should not record metadata after successful cleanup"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create'$'\x1f''--worktree'$'\x1f''id:wt-terminal-fail::/orca/wt-terminal-fail'$'\x1f''--title'$'\x1f'"fm-$id"$'\x1f''--json' \
    "Orca spawn should attempt terminal creation before abort cleanup"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-terminal-fail::/orca/wt-terminal-fail'$'\x1f''--force'$'\x1f''--json' \
    "Orca spawn should remove the worktree when terminal creation fails"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "Orca spawn should not close a terminal when no handle was recorded"
  pass "fm-spawn.sh --backend orca: removes worktree when terminal creation fails"
}

test_spawn_preserves_orca_metadata_when_abort_cleanup_fails() {
  local proj wt data state config id out status
  id="orcacleanupleakz0"
  proj="$TMP_ROOT/cleanup-fail-project"
  wt="$TMP_ROOT/cleanup-fail-wt"
  data="$TMP_ROOT/cleanup-fail-data"
  state="$TMP_ROOT/cleanup-fail-state"
  config="$TMP_ROOT/cleanup-fail-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case cleanup-fail
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-cleanup-fail"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-cleanup-fail::/orca/wt-cleanup-fail","path":"%s"}}}\n' "$wt" > "$RESP/3.out"
  printf '1\n' > "$RESP/4.exit"
  printf '1\n' > "$RESP/5.exit"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when terminal creation and abort cleanup fail"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-cleanup-fail::/orca/wt-cleanup-fail'$'\x1f''--force'$'\x1f''--json' \
    "Orca spawn should attempt helper cleanup before preserving metadata"
  assert_present "$state/$id.meta" "failed Orca abort cleanup should preserve metadata"
  assert_grep "window=fm-$id" "$state/$id.meta" "preserved metadata missing stable window alias"
  assert_grep "backend=orca" "$state/$id.meta" "preserved metadata missing backend=orca"
  assert_grep "orca_worktree_id=wt-cleanup-fail::/orca/wt-cleanup-fail" "$state/$id.meta" "preserved metadata missing Orca worktree id"
  assert_no_grep "terminal=" "$state/$id.meta" "preserved metadata should not invent a terminal handle"
  pass "fm-spawn.sh --backend orca: preserves metadata when abort cleanup fails"
}

test_spawn_releases_orca_resources_when_metadata_write_fails() {
  local proj wt data state config id out status
  id="orcametafailz9"
  proj="$TMP_ROOT/meta-fail-project"
  wt="$TMP_ROOT/meta-fail-wt"
  data="$TMP_ROOT/meta-fail-data"
  state="$TMP_ROOT/meta-fail-state"
  config="$TMP_ROOT/meta-fail-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state/$id.meta" "$config"
  write_spawn_brief "$data" "$id"
  orca_case meta-fail
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-meta-fail"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-meta-fail::/orca/wt-meta-fail","path":"%s"}}}\n' "$wt" > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"handle":"term-meta-fail"}}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{"terminal":{"source":"screen","tail":["➜  %s git:(task)"]}}}\n' "${wt##*/}" | tee "$RESP/5.out" > "$RESP/6.out"
  printf '{"ok":true,"result":{"terminal":{"handle":"term-meta-fail","worktreeId":"wt-meta-fail::/orca/wt-meta-fail","tabId":"tab-1","leafId":"leaf-1"}}}\n' > "$RESP/7.out"
  printf '{"ok":true,"result":{"agents":[]}}\n' > "$RESP/8.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when metadata cannot be written"
  assert_contains "$out" "task record for $id could not be published" \
    "spawn should report metadata publication failure without relying on platform-specific mv output"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-meta-fail'$'\x1f''--json' \
    "Orca spawn should close the recorded terminal when a later abort occurs"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-meta-fail::/orca/wt-meta-fail'$'\x1f''--force'$'\x1f''--json' \
    "Orca spawn should remove the recorded worktree when a later abort occurs"
  [ ! -f "$state/$id.meta" ] || fail "metadata-write abort should not publish a regular metadata file"
  pass "fm-spawn.sh --backend orca: releases terminal and worktree on later aborts"
}

test_peek_send_and_crew_state_route_through_orca_meta() {
  local wt state id out neutral record body
  id="orcaiopathz2"
  wt="$TMP_ROOT/io-wt"
  fm_git_init_commit "$wt"
  state="$TMP_ROOT/io-state"; mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-io" "worktree=$wt" "project=$wt" "harness=claude" "kind=scout" "backend=orca"
  touch "$state/.last-watcher-beat"
  orca_case io-path
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  printf '{"ok":true,"result":{"terminal":{"source":"screen","tail":["ready"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-peek.sh" "fm-$id" 10 )
  [ "$out" = ready ] || fail "fm-peek should read through Orca metadata, got '$out'"
  printf '{"ok":true,"result":{"send":{"handle":"term-io","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-io","accepted":true}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"source":"screen","tail":["│ > │"]}}}\n' > "$RESP/4.out"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "fm-$id" "hello orca"
  printf '{"ok":true,"result":{"terminal":{"source":"screen","tail":["idle prompt"]}}}\n' > "$RESP/5.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-crew-state.sh" "$id" )
  assert_contains "$out" "state: unknown" "crew-state should fall back cleanly for an idle Orca scout"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f''term-io' \
    "peek/crew-state did not read the recorded Orca terminal"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f'"fm-$id" \
    "crew-state should not read the stable Orca alias as a terminal handle"
  record="$state/$id.inbox/001.msg"
  [ -f "$record" ] || fail "send did not enqueue through the task inbox"
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$record")
  [ "$body" = "hello orca" ] || fail "Orca task inbox did not preserve the send body, got '$body'"
  assert_not_contains "$(cat "$LOG")" $'--text\x1fhello orca\x1f' \
    "send typed the payload instead of recording it"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-io'$'\x1f''--text'$'\x1f'': Firstmate instruction waiting:' \
    "send did not ring the inbox doorbell through the recorded Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-io'$'\x1f''--text'$'\x1f\x1f''--enter'$'\x1f''--json' \
    "send did not submit the doorbell through the recorded Orca terminal"
  pass "fm-peek/fm-send/fm-crew-state route through backend=orca metadata and its durable inbox"
}

test_peek_and_crew_state_fail_closed_on_orca_error_json() {
  local wt state id out status neutral
  id="orcareaderrz7"
  wt="$TMP_ROOT/read-error-wt"
  fm_git_init_commit "$wt"
  state="$TMP_ROOT/read-error-state"; mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-stale" "worktree=$wt" "project=$wt" "harness=claude" "kind=scout" "backend=orca"
  touch "$state/.last-watcher-beat"
  orca_case read-error-json
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-peek.sh" "fm-$id" 10 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-peek should fail when Orca reports a stale terminal"
  assert_contains "$out" "terminal handle stale" "fm-peek should surface the Orca read error message"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/2.out"
  cp "$RESP/2.out" "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-crew-state.sh" "$id" )
  assert_contains "$out" "state: unknown" "crew-state should not treat an Orca read error as a live endpoint"
  assert_contains "$out" "backend target gone: term-stale" "crew-state should report the stale Orca terminal as gone"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f''term-stale' \
    "fm-peek/fm-crew-state did not read the recorded Orca terminal"
  pass "fm-peek/fm-crew-state: Orca read error JSON fails closed"
}

# A live terminal whose screen Orca cannot render is still a live endpoint:
# crew-state's liveness probe must not call it gone.
test_crew_state_keeps_live_orca_terminal_without_a_rendered_screen() {
  local wt state id out
  id="orcanoscreenz8"
  wt="$TMP_ROOT/no-screen-wt"
  fm_git_init_commit "$wt"
  state="$TMP_ROOT/no-screen-state"; mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-live" "worktree=$wt" "project=$wt" "harness=claude" "kind=scout" "backend=orca"
  touch "$state/.last-watcher-beat"
  orca_case crew-state-no-screen
  printf '{"ok":true,"result":{"terminal":{"source":"screen-unavailable","status":"running","tail":["x"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-crew-state.sh" "$id" )
  assert_not_contains "$out" "backend target gone" "crew-state must not call a live Orca terminal gone because its screen is unavailable"
  pass "fm-crew-state: a live Orca terminal without a rendered screen is not reported gone"
}

# Orca answers a running terminal's read, its pane, and the agent listing in
# three calls; these write those answers as fake responses <n>, <n+1>, <n+2>.
orca_running_read() { printf '{"ok":true,"result":{"terminal":{"status":"running","tail":[]}}}\n'; }
orca_exited_read() { printf '{"ok":true,"result":{"terminal":{"status":"exited","tail":[]}}}\n'; }
orca_pane_show() { printf '{"ok":true,"result":{"terminal":{"worktreeId":"repo-a::/orca/wt-a","tabId":"tab-a","leafId":"leaf-a"}}}\n'; }
orca_agent_list() {  # <state-on-our-pane|none> -> list JSON
  local mine=''
  # An older entry on the same pane precedes the newest one.
  [ "$1" = none ] || mine=',{"kind":"terminal","agent":"claude","state":"working","paneKey":"tab-a:leaf-a","updatedAt":10},{"kind":"terminal","agent":"claude","state":"'"$1"'","paneKey":"tab-a:leaf-a","updatedAt":20}'
  printf '{"ok":true,"result":{"agents":[{"kind":"terminal","agent":"claude","state":"working","paneKey":"tab-b:leaf-b","updatedAt":30},{"kind":"chat","agent":"omp","state":"working","paneKey":"tab-a:leaf-a","updatedAt":40}%s]}}\n' "$mine"
}
orca_probe_responses() {  # <first-n> <state|none>
  orca_running_read > "$RESP/$1.out"
  orca_pane_show > "$RESP/$(($1 + 1)).out"
  orca_agent_list "$2" > "$RESP/$(($1 + 2)).out"
}

# Route B: busy and agent state come from Orca's agent listing for the
# terminal's own pane - the newest terminal entry there, never another pane's
# or a chat's - and from the terminal's own status for an ended endpoint.
test_busy_and_agent_state_read_orca_agent_listing() {
  local state busy agent want_busy want_agent out
  for state in working waiting blocked "done" none exited stale read-error show-error; do
    orca_case "agent-listing-$state"
    case "$state" in
      exited) orca_exited_read > "$RESP/1.out"; orca_exited_read > "$RESP/2.out" ;;
      stale)
        printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal_handle_stale"}}\n' > "$RESP/1.out"
        cp "$RESP/1.out" "$RESP/2.out"
        ;;
      read-error)
        printf '{"ok":false,"error":{"code":"runtime_unavailable","message":"no runtime"}}\n' > "$RESP/1.out"
        cp "$RESP/1.out" "$RESP/2.out"
        ;;
      show-error)
        orca_running_read > "$RESP/1.out"
        printf '{"ok":false,"error":{"code":"runtime_unavailable","message":"no runtime"}}\n' > "$RESP/2.out"
        orca_running_read > "$RESP/3.out"
        cp "$RESP/2.out" "$RESP/4.out"
        ;;
      *) orca_probe_responses 1 "$state"; orca_probe_responses 4 "$state" ;;
    esac
    out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
      bash -c '. "$0/bin/fm-backend.sh"; fm_backend_busy_state orca term-a; printf " "; fm_backend_agent_state orca term-a' "$ROOT" )
    busy=${out%% *}
    agent=${out#* }
    case "$state" in
      working) want_busy=busy want_agent=alive ;;
      waiting|blocked) want_busy=blocked want_agent=alive ;;
      done) want_busy=idle want_agent=alive ;;
      none) want_busy=unknown want_agent=unverified ;;
      exited|stale) want_busy=unknown want_agent=missing ;;
      *) want_busy=unknown want_agent=unreadable ;;
    esac
    assert_equals "$want_busy" "$busy" "Orca agent listing '$state' should read busy=$want_busy"
    assert_equals "$want_agent" "$agent" "Orca agent listing '$state' should read agent state $want_agent"
  done
  assert_contains "$(cat "$TMP_ROOT/agent-listing-working/log")" $'orca\x1f''agent'$'\x1f''list'$'\x1f''--worktree'$'\x1f''id:repo-a::/orca/wt-a'$'\x1f''--json' \
    "the agent listing was not scoped to the terminal's own Orca worktree"
  pass "fm_backend_busy_state/agent_state: Orca's listing for the terminal's own pane decides busy, waiting, idle, and presence"
}

# An Orca terminal that has exited is no longer a live endpoint.
test_target_exists_rejects_exited_orca_terminal() {
  local status
  orca_case target-exists-exited
  orca_exited_read > "$RESP/1.out"
  set +e
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_exists orca term-exited fm-task' "$ROOT"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "fm_backend_target_exists should reject an exited Orca terminal"
  orca_case target-exists-running
  orca_running_read > "$RESP/1.out"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_exists orca term-live fm-task' "$ROOT" \
    || fail "fm_backend_target_exists should accept a running Orca terminal"
  pass "fm_backend_target_exists: an exited Orca terminal is gone, a running one exists"
}

# fm-crew-state reports a worker Orca sees busy, waiting for input, or gone.
test_crew_state_reports_orca_agent_state() {
  local wt state id out case_name
  for case_name in waiting working exited; do
    id="orcastate${case_name}z9"
    wt="$TMP_ROOT/agent-state-$case_name-wt"
    fm_git_init_commit "$wt"
    state="$TMP_ROOT/agent-state-$case_name-state"; mkdir -p "$state"
    fm_write_meta "$state/$id.meta" \
      "window=fm-$id" "endpoint_task_id=$id" "terminal=term-$case_name" "worktree=$wt" "project=$wt" "harness=claude" "kind=scout" "backend=orca"
    touch "$state/.last-watcher-beat"
    orca_case "crew-state-$case_name"
    case "$case_name" in
      waiting)
        orca_running_read > "$RESP/1.out"
        orca_probe_responses 2 waiting
        ;;
      working)
        orca_running_read > "$RESP/1.out"
        orca_probe_responses 2 working
        printf '{"ok":true,"result":{"terminal":{"source":"screen","tail":["working"]}}}\n' > "$RESP/5.out"
        orca_probe_responses 6 working
        ;;
      exited) orca_exited_read > "$RESP/1.out"; orca_exited_read > "$RESP/2.out" ;;
    esac
    out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
      FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-crew-state.sh" "$id" )
    case "$case_name" in
      waiting) assert_contains "$out" "state: parked · source: pane · waiting for input (orca-native)" "crew-state should report an Orca agent waiting for input" ;;
      working) assert_contains "$out" "state: working · source: pane · harness busy (orca-native)" "crew-state should report an Orca agent Orca lists as working" ;;
      exited) assert_contains "$out" "backend target gone: term-exited" "crew-state should report an exited Orca terminal as gone" ;;
    esac
  done
  pass "fm-crew-state: an Orca worker reads busy, waiting for input, or gone from Orca's own state"
}

test_target_exists_rejects_orca_error_json() {
  local status
  orca_case target-exists-error-json
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  set +e
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_exists orca term-stale fm-task' "$ROOT"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "fm_backend_target_exists should reject Orca ok:false read JSON"
  pass "fm_backend_target_exists: Orca ok:false read JSON is not live"
}

test_scout_teardown_removes_orca_worktree_via_helper() {
  local proj wt data state config id out rc neutral
  id="orcateardownz3"
  proj="$TMP_ROOT/teardown-project"
  wt="$TMP_ROOT/teardown-wt"
  data="$TMP_ROOT/teardown-data"
  state="$TMP_ROOT/teardown-state"
  config="$TMP_ROOT/teardown-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-teardown" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-teardown::/orca/wt-teardown" \
    "decisions_reviewed=1" "decision_keys="
  orca_case teardown
  printf '{"ok":true,"result":{"worktree":{"id":"wt-teardown::/orca/wt-teardown","path":"%s"}}}\n' "$wt" > "$RESP/1.out"
  printf '{"ok":true,"result":{"terminal":{"status":"exited"}}}\n' > "$RESP/3.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "Orca scout teardown should succeed once report exists"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-teardown'$'\x1f''--json' \
    "teardown did not close the recorded Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-teardown::/orca/wt-teardown'$'\x1f''--force'$'\x1f''--json' \
    "teardown did not remove the Orca worktree through orca worktree rm"
  assert_not_contains "$(cat "$LOG")" "--delete-branch" "a scout has no landed-work test, so its branch must stay"
  assert_absent "$state/$id.meta" "teardown should remove task metadata"
  pass "fm-teardown.sh backend=orca: scout report gate then helper-backed worktree removal, branch kept"
}

test_scout_teardown_refuses_orca_id_path_mismatch() {
  local proj wt other_wt data state config id out rc neutral
  id="orcascoutmismatchz5"
  proj="$TMP_ROOT/scout-mismatch-project"
  wt="$TMP_ROOT/scout-mismatch-wt"
  other_wt="$TMP_ROOT/scout-mismatch-other-wt"
  data="$TMP_ROOT/scout-mismatch-data"
  state="$TMP_ROOT/scout-mismatch-state"
  config="$TMP_ROOT/scout-mismatch-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  git -C "$proj" worktree add --quiet -b "fm/$id-other" "$other_wt"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-scout-mismatch" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-scout-mismatch::/orca/wt-scout-mismatch" \
    "decisions_reviewed=1" "decision_keys="
  orca_case scout-mismatch
  printf '{"ok":true,"result":{"worktree":{"id":"wt-scout-mismatch::/orca/wt-scout-mismatch","path":"%s"}}}\n' "$other_wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca scout teardown should refuse when id path differs from worktree="
  assert_contains "$out" "not inspected worktree" \
    "mismatched Orca scout worktree path refusal should name the mismatch"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused mismatched Orca scout teardown should not close terminals"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused mismatched Orca scout teardown should not remove worktrees"
  assert_present "$state/$id.meta" "refused mismatched scout teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: scout teardown refuses id/path mismatches"
}

test_teardown_removes_orca_worktree_when_path_missing() {
  local proj wt data state config id out rc neutral
  id="orcamissingpathz7"
  proj="$TMP_ROOT/missing-path-project"
  wt="$TMP_ROOT/missing-path-wt"
  data="$TMP_ROOT/missing-path-data"
  state="$TMP_ROOT/missing-path-state"
  config="$TMP_ROOT/missing-path-config"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-missing-path" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-missing-path::/orca/wt-missing-path" \
    "decisions_reviewed=1" "decision_keys="
  orca_case missing-path
  printf '{"ok":true,"result":{"terminal":{"status":"exited"}}}\n' > "$RESP/2.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "Orca teardown should release helpers even when the path is absent"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-missing-path'$'\x1f''--json' \
    "teardown did not close the recorded Orca terminal when the path was absent"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-missing-path::/orca/wt-missing-path'$'\x1f''--force'$'\x1f''--json' \
    "teardown did not remove the recorded Orca worktree when the path was absent"
  assert_absent "$state/$id.meta" "successful helper cleanup should remove task metadata"
  pass "fm-teardown.sh backend=orca: releases terminal/worktree when path is absent"
}

test_teardown_retires_orca_secondmate_closing_only_its_terminal() {
  local home mate state id out rc
  id="orcasmretirez1"
  home="$TMP_ROOT/retire-home"
  mate="$TMP_ROOT/retire-mate"
  state="$home/state"
  mkdir -p "$state" "$home/data" "$home/config" "$mate/state" "$mate/data" "$mate/config"
  printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-seat" "worktree=$mate" "project=$mate" "home=$mate" \
    "harness=claude" "kind=secondmate" "mode=secondmate" "yolo=off" "projects=" \
    "backend=orca" "orca_worktree_id=repo-home::$mate"
  orca_case retire-secondmate
  printf '{"ok":true,"result":{"terminal":{"status":"exited"}}}\n' > "$RESP/2.out"
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "retiring an Orca secondmate should succeed"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-seat'$'\x1f''--json' \
    "retirement did not close the seat's Orca terminal"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "retirement must never ask Orca to remove the home's project root"
  pass "fm-teardown.sh backend=orca: retiring a secondmate closes its terminal and leaves its home's Orca entry"
}

test_teardown_preserves_metadata_when_orca_remove_error_json() {
  local proj wt data state config id out rc neutral
  id="orcaremoveerrz2"
  proj="$TMP_ROOT/remove-error-project"
  wt="$TMP_ROOT/remove-error-wt"
  data="$TMP_ROOT/remove-error-data"
  state="$TMP_ROOT/remove-error-state"
  config="$TMP_ROOT/remove-error-config"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-remove-error" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-remove-error::/orca/wt-remove-error" \
    "decisions_reviewed=1" "decision_keys="
  orca_case remove-error-teardown
  printf '{"ok":true,"result":{}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"terminal":{"status":"exited"}}}\n' > "$RESP/2.out"
  printf '{"ok":false,"error":{"code":"worktree_not_removed","message":"worktree not removed"}}\n' > "$RESP/3.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca teardown should fail when worktree removal returns ok:false JSON"
  assert_contains "$out" "worktree not removed" "teardown should surface the Orca removal error"
  assert_present "$state/$id.meta" "failed Orca removal should preserve task metadata"
  pass "fm-teardown.sh backend=orca: preserves metadata on remove ok:false JSON"
}

test_scout_teardown_refuses_orca_missing_report_when_path_missing() {
  local proj wt data state config id out rc neutral
  id="orcanoreportz4"
  proj="$TMP_ROOT/missing-report-project"
  wt="$TMP_ROOT/missing-report-wt"
  data="$TMP_ROOT/missing-report-data"
  state="$TMP_ROOT/missing-report-state"
  config="$TMP_ROOT/missing-report-config"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-missing-report" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-missing-report::/orca/wt-missing-report"
  orca_case missing-report
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca scout teardown should refuse without a report even when the path is absent"
  assert_contains "$out" "has no report" "Orca scout teardown should explain the missing report"
  [ ! -s "$LOG" ] || fail "refused Orca scout teardown should not close terminals or remove worktrees"
  assert_present "$state/$id.meta" "refused Orca scout teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: scout report gate precedes pathless helper cleanup"
}

test_ship_teardown_refuses_orca_missing_worktree_path() {
  local proj wt data state config id out rc neutral
  id="orcashipmissingz8"
  proj="$TMP_ROOT/missing-ship-project"
  wt="$TMP_ROOT/missing-ship-wt"
  data="$TMP_ROOT/missing-ship-data"
  state="$TMP_ROOT/missing-ship-state"
  config="$TMP_ROOT/missing-ship-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-missing-ship" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-missing-ship::/orca/wt-missing-ship"
  orca_case missing-ship-path
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca ship teardown should refuse a missing worktree path"
  assert_contains "$out" "no inspectable git worktree" \
    "Orca ship teardown should explain the fail-closed worktree requirement"
  [ ! -s "$LOG" ] || fail "refused Orca ship teardown should not close terminals or remove worktrees"
  assert_present "$state/$id.meta" "refused Orca ship teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: ship teardown fails closed when worktree path is missing"
}

test_ship_teardown_removes_orca_worktree_when_id_path_matches() {
  local proj wt data state config id out rc neutral
  id="orcashipmatchz2"
  proj="$TMP_ROOT/ship-match-project"
  wt="$TMP_ROOT/ship-match-wt"
  data="$TMP_ROOT/ship-match-data"
  state="$TMP_ROOT/ship-match-state"
  config="$TMP_ROOT/ship-match-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-ship-match" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-ship-match::/orca/wt-ship-match"
  orca_case ship-match
  printf '{"ok":true,"result":{"worktree":{"id":"wt-ship-match::/orca/wt-ship-match","path":"%s"}}}\n' "$wt" > "$RESP/1.out"
  printf '{"ok":true,"result":{"terminal":{"status":"exited"}}}\n' > "$RESP/3.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "Orca ship teardown should succeed when the id path matches the inspected worktree"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-ship-match::/orca/wt-ship-match'$'\x1f''--json' \
    "teardown did not resolve the Orca worktree id before removal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-ship-match'$'\x1f''--json' \
    "teardown did not close the matched Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-ship-match::/orca/wt-ship-match'$'\x1f''--force'$'\x1f''--delete-branch'$'\x1f''--json' \
    "teardown did not remove the matched Orca worktree and its landed branch"
  assert_absent "$state/$id.meta" "successful matched teardown should remove task metadata"
  pass "fm-teardown.sh backend=orca: ship teardown requires a matching Orca id path and deletes a landed branch"
}

# The landed-work test is the only authority on the branch: with work that has
# not landed, a forced teardown discards the worktree but keeps the branch.
test_ship_force_teardown_keeps_an_unlanded_orca_branch() {
  local proj wt data state config id out rc neutral
  id="orcashipforcez4"
  proj="$TMP_ROOT/ship-force-project"
  wt="$TMP_ROOT/ship-force-wt"
  data="$TMP_ROOT/ship-force-data"
  state="$TMP_ROOT/ship-force-state"
  config="$TMP_ROOT/ship-force-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  printf 'unlanded\n' > "$wt/unlanded.txt"
  git -C "$wt" add unlanded.txt
  git -C "$wt" -c user.name=fm-test -c user.email=fm-test@example.invalid commit -q -m unlanded
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-ship-force" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-ship-force::/orca/wt-ship-force"
  neutral=$(neutral_fm_root "$TMP_ROOT/ship-force-neutral")
  orca_case ship-force-unforced
  printf '{"ok":true,"result":{"worktree":{"id":"wt-ship-force::/orca/wt-ship-force","path":"%s"}}}\n' "$wt" > "$RESP/1.out"
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca ship teardown should refuse unlanded work without --force"
  assert_contains "$out" "has work not yet merged" "unforced teardown should refuse on the landed-work test"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' "refused unlanded teardown removed the worktree"
  orca_case ship-force
  printf '{"ok":true,"result":{"worktree":{"id":"wt-ship-force::/orca/wt-ship-force","path":"%s"}}}\n' "$wt" > "$RESP/1.out"
  printf '{"ok":true,"result":{"terminal":{"status":"exited"}}}\n' > "$RESP/3.out"
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "forced Orca ship teardown should succeed"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-ship-force::/orca/wt-ship-force'$'\x1f''--force'$'\x1f''--json' \
    "forced teardown did not remove the Orca worktree"
  assert_not_contains "$(cat "$LOG")" "--delete-branch" "forced teardown asked Orca to delete an unlanded branch"
  git -C "$proj" rev-parse --verify -q "refs/heads/fm/$id" >/dev/null \
    || fail "forced teardown deleted the unlanded task branch itself"
  assert_absent "$state/$id.meta" "forced teardown should remove task metadata"
  pass "fm-teardown.sh --force backend=orca: discards the worktree but keeps a branch whose work has not landed"
}

# A close the re-read cannot confirm stops cleanup before the worktree goes,
# keeping the record that names the terminal.
test_ship_teardown_stops_when_the_orca_close_fails() {
  local proj wt data state config id out rc neutral n
  id="orcashipclosefailz3"
  proj="$TMP_ROOT/ship-close-fail-project"
  wt="$TMP_ROOT/ship-close-fail-wt"
  data="$TMP_ROOT/ship-close-fail-data"
  state="$TMP_ROOT/ship-close-fail-state"
  config="$TMP_ROOT/ship-close-fail-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-ship-close-fail" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-ship-close-fail::/orca/wt-ship-close-fail"
  orca_case ship-close-fail
  printf '{"ok":true,"result":{"worktree":{"id":"wt-ship-close-fail::/orca/wt-ship-close-fail","path":"%s"}}}\n' "$wt" > "$RESP/1.out"
  for n in 3 4 5 6 7 8 9 10 11 12; do
    printf '{"ok":true,"result":{"terminal":{"status":"running"}}}\n' > "$RESP/$n.out"
  done
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca teardown completed although the terminal was still running after its close"
  assert_contains "$out" "Orca terminal term-ship-close-fail did not close" "teardown did not report the failed close"
  assert_contains "$out" "could not be closed" "teardown did not stop through the endpoint close refusal"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' "teardown removed the worktree after a failed close"
  assert_present "$state/$id.meta" "a failed close must keep the record naming the terminal"
  pass "fm-teardown.sh backend=orca: stops and reports when the terminal close does not take"
}

test_ship_teardown_refuses_orca_unresolvable_worktree_id() {
  local proj wt data state config id out rc neutral
  id="orcashipunresolvedz1"
  proj="$TMP_ROOT/ship-unresolved-project"
  wt="$TMP_ROOT/ship-unresolved-wt"
  data="$TMP_ROOT/ship-unresolved-data"
  state="$TMP_ROOT/ship-unresolved-state"
  config="$TMP_ROOT/ship-unresolved-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-ship-unresolved" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-ship-unresolved::/orca/wt-ship-unresolved"
  orca_case ship-unresolved
  printf '1\n' > "$RESP/1.exit"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca ship teardown should refuse when the worktree id cannot be resolved"
  assert_contains "$out" "cannot resolve Orca worktree id wt-ship-unresolved::/orca/wt-ship-unresolved" \
    "unresolvable Orca worktree id refusal should explain the fail-closed check"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-ship-unresolved::/orca/wt-ship-unresolved'$'\x1f''--json' \
    "teardown did not attempt to resolve the Orca worktree id"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused unresolved Orca ship teardown should not close terminals"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused unresolved Orca ship teardown should not remove worktrees"
  assert_present "$state/$id.meta" "refused unresolved Orca ship teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: ship teardown fails closed when id resolution fails"
}

test_ship_teardown_refuses_orca_id_path_mismatch() {
  local proj wt other_wt data state config id out rc neutral
  id="orcashipmismatchz9"
  proj="$TMP_ROOT/ship-mismatch-project"
  wt="$TMP_ROOT/ship-mismatch-wt"
  other_wt="$TMP_ROOT/ship-mismatch-other-wt"
  data="$TMP_ROOT/ship-mismatch-data"
  state="$TMP_ROOT/ship-mismatch-state"
  config="$TMP_ROOT/ship-mismatch-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  git -C "$proj" worktree add --quiet -b "fm/$id-other" "$other_wt"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-ship-mismatch" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-ship-mismatch::/orca/wt-ship-mismatch"
  orca_case ship-mismatch
  printf '{"ok":true,"result":{"worktree":{"id":"wt-ship-mismatch::/orca/wt-ship-mismatch","path":"%s"}}}\n' "$other_wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca ship teardown should refuse when the id path differs from worktree="
  assert_contains "$out" "not inspected worktree" \
    "mismatched Orca worktree path refusal should name the mismatch"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-ship-mismatch::/orca/wt-ship-mismatch'$'\x1f''--json' \
    "teardown did not resolve the mismatched Orca worktree id"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused mismatched Orca ship teardown should not close terminals"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused mismatched Orca ship teardown should not remove worktrees"
  assert_present "$state/$id.meta" "refused mismatched Orca ship teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: ship teardown refuses id/path mismatches"
}

test_teardown_refuses_orca_missing_worktree_id() {
  local proj wt data state config id out rc neutral
  id="orcamissingidz5"
  proj="$TMP_ROOT/missing-id-project"
  wt="$TMP_ROOT/missing-id-wt"
  data="$TMP_ROOT/missing-id-data"
  state="$TMP_ROOT/missing-id-state"
  config="$TMP_ROOT/missing-id-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-missing-id" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" "backend=orca" \
    "decisions_reviewed=1" "decision_keys="
  orca_case missing-id
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca teardown should refuse missing orca_worktree_id"
  assert_contains "$out" "missing orca_worktree_id" "teardown did not explain the missing Orca worktree id"
  assert_present "$state/$id.meta" "failed teardown must preserve task metadata"
  [ ! -s "$LOG" ] || fail "teardown should fail before closing terminals or removing worktrees without an Orca worktree id"
  pass "fm-teardown.sh backend=orca: refuses missing worktree ids before cleanup"
}

test_teardown_refuses_orca_worktree_without_terminal_handle() {
  local proj wt data state config id out rc neutral
  id="orcanotermz0"
  proj="$TMP_ROOT/no-terminal-project"
  wt="$TMP_ROOT/no-terminal-wt"
  data="$TMP_ROOT/no-terminal-data"
  state="$TMP_ROOT/no-terminal-state"
  config="$TMP_ROOT/no-terminal-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-no-terminal::/orca/wt-no-terminal" \
    "decisions_reviewed=1" "decision_keys="
  orca_case no-terminal
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca teardown accepted metadata without a terminal handle"
  assert_contains "$out" "missing terminal" "teardown did not explain the incomplete Orca endpoint"
  [ ! -s "$LOG" ] || fail "teardown dispatched to Orca before rejecting the incomplete endpoint"
  assert_present "$state/$id.meta" "missing-terminal refusal removed task metadata"
  pass "fm-teardown.sh backend=orca: refuses incomplete worktree-only endpoint metadata before runtime dispatch"
}

test_secondmate_force_teardown_removes_orca_child_via_orca() {
  local home subhome childproj childwt child_id neutral out rc
  home="$TMP_ROOT/orca-child-parent"
  subhome="$TMP_ROOT/orca-child-secondmate"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/orca-child-worktree"
  child_id="orcachildz6"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/projects"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_git_worktree "$childproj" "$childwt" "fm/$child_id"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' "- domain - Orca child cleanup (home: $subhome; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/$child_id.meta" \
    "window=fm-$child_id" "endpoint_task_id=$child_id" \
    "terminal=term-child-cleanup" "worktree=$childwt" "project=$childproj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-child-cleanup::/orca/wt-child-cleanup"
  orca_case secondmate-child-cleanup
  printf '{"ok":true,"result":{"worktree":{"id":"wt-child-cleanup::/orca/wt-child-cleanup","path":"%s"}}}\n' "$childwt" > "$RESP/1.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-child-cleanup::/orca/wt-child-cleanup","path":"%s"}}}\n' "$childwt" > "$RESP/2.out"
  printf '{"ok":true,"result":{}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"status":"exited"}}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{}}\n' > "$RESP/5.out"
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "forced secondmate teardown should remove Orca child work through Orca"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-child-cleanup'$'\x1f''--json' \
    "child cleanup did not close the recorded Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-child-cleanup::/orca/wt-child-cleanup'$'\x1f''--force'$'\x1f''--json' \
    "child cleanup did not remove the Orca worktree through orca worktree rm"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f'"fm-$child_id" \
    "child cleanup closed the stable alias instead of the Orca terminal"
  assert_absent "$home/state/domain.meta" "parent metadata should be removed after forced teardown"
  pass "fm-teardown.sh --force: removes Orca secondmate children through Orca"
}

test_secondmate_force_teardown_refuses_orca_child_id_path_mismatch() {
  local home subhome childproj childwt other_wt child_id neutral out rc
  home="$TMP_ROOT/orca-child-mismatch-parent"
  subhome="$TMP_ROOT/orca-child-mismatch-secondmate"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/orca-child-mismatch-worktree"
  other_wt="$TMP_ROOT/orca-child-mismatch-other-worktree"
  child_id="orcachildmismatchz1"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/projects"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_git_worktree "$childproj" "$childwt" "fm/$child_id"
  git -C "$childproj" worktree add --quiet -b "fm/$child_id-other" "$other_wt"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' "- domain - Orca child cleanup (home: $subhome; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/$child_id.meta" \
    "window=fm-$child_id" "endpoint_task_id=$child_id" \
    "terminal=term-child-mismatch" "worktree=$childwt" "project=$childproj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-child-mismatch::/orca/wt-child-mismatch"
  orca_case secondmate-child-mismatch
  printf '{"ok":true,"result":{"worktree":{"id":"wt-child-mismatch::/orca/wt-child-mismatch","path":"%s"}}}\n' "$other_wt" > "$RESP/1.out"
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "forced secondmate teardown should refuse mismatched Orca child id/path"
  assert_contains "$out" "not inspected worktree" \
    "mismatched Orca child worktree path refusal should name the mismatch"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused mismatched Orca child cleanup should not close terminals"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused mismatched Orca child cleanup should not remove worktrees"
  assert_present "$home/state/domain.meta" "refused forced secondmate teardown should preserve parent metadata"
  pass "fm-teardown.sh --force: refuses Orca child id/path mismatches"
}

test_secondmate_force_teardown_refuses_partial_orca_child() {
  local home subhome childproj childwt child_id neutral out rc
  home="$TMP_ROOT/orca-partial-child-parent"
  subhome="$TMP_ROOT/orca-partial-child-secondmate"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/orca-partial-child-worktree"
  child_id="orcapartialz9"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/projects"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_git_worktree "$childproj" "$childwt" "fm/$child_id"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' "- domain - Orca partial child cleanup (home: $subhome; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/$child_id.meta" \
    "window=fm-$child_id" "endpoint_task_id=$child_id" \
    "worktree=$childwt" "project=$childproj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-partial-child::/orca/wt-partial-child"
  orca_case secondmate-partial-child-cleanup
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "forced secondmate teardown accepted a child with no terminal identity"
  assert_contains "$out" "missing terminal" "partial child refusal did not explain the incomplete endpoint"
  [ ! -s "$LOG" ] || fail "partial child refusal dispatched to Orca or tmux"
  assert_present "$home/state/domain.meta" "partial child refusal removed parent metadata"
  assert_present "$subhome/state/$child_id.meta" "partial child refusal removed child metadata"
  pass "fm-teardown.sh --force: refuses partial Orca secondmate children before runtime dispatch"
}

test_dispatcher_sources_orca_and_routes_primitives() {
  local out
  orca_case dispatch
  printf '{"result":{"terminal":{"source":"screen","tail":["via dispatch"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_validate orca; fm_backend_capture orca term-123 9' "$ROOT" )
  [ "$out" = "via dispatch" ] || fail "dispatcher should route capture to the Orca adapter, got '$out'"
  pass "fm-backend dispatcher: accepts orca and routes capture through bin/backends/orca.sh"
}

test_capture_reads_terminal_tail_json
test_capture_returns_cleared_screen_rows_with_spaces
test_capture_refuses_reads_not_from_the_drawn_screen
test_visible_capture_reads_the_whole_drawn_screen
test_target_exists_accepts_live_terminal_without_a_rendered_screen
test_composer_state_empty_box_with_elided_footer_gap
test_task_inbox_reads_held_text_above_elided_footer_gap
test_capture_fails_on_orca_error_json
test_runtime_check_accepts_ready_orca_status
test_runtime_check_refuses_unready_orca_status
test_send_text_submit_verifies_empty_composer_after_enter
test_send_text_submit_borderless_claude_confirms
test_composer_state_stale_banner_never_wins
test_send_text_submit_retries_when_composer_stays_pending
test_composer_state_popup_placeholder_fill_is_pending
test_composer_state_bare_shell_prompt_is_unknown
test_send_text_submit_popup_autocomplete_requires_second_enter
test_send_literal_constructs_non_enter_send
test_send_text_submit_reports_send_failed
test_send_helpers_reject_orca_error_json
test_send_key_enter_and_interrupt
test_send_key_refuses_unknown_key
test_send_key_escape_and_composer_keys_are_raw_bytes
test_kill_succeeds_when_the_reread_reports_exited
test_kill_refuses_when_the_close_did_not_take
test_kill_refuses_when_the_orca_cli_is_absent
test_cli_resolves_orca_ide_and_paired_server_install
test_paired_server_install_beats_a_non_orca_orca_on_path
test_remove_worktree_refuses_empty_id
test_remove_worktree_rejects_orca_error_json
test_remove_worktree_deletes_the_branch_only_when_asked
test_worktree_path_resolves_id
test_dispatcher_sources_orca_and_routes_primitives
test_json_get_ignores_undocumented_terminal_id_shapes
test_worktree_and_terminal_helpers_parse_json
test_worktree_create_removes_worktree_when_path_missing
test_spawn_preserves_orca_metadata_when_pathless_worktree_cleanup_fails
test_spawn_writes_orca_metadata_and_launches_harness
test_spawn_orca_secondmate_opens_terminal_in_home
test_spawn_orca_secondmate_refuses_a_mismatched_home_entry
test_spawn_refuses_orca_when_runtime_not_ready
test_spawn_refuses_orca_nonisolated_worktree
test_spawn_removes_orca_worktree_when_terminal_create_fails
test_spawn_preserves_orca_metadata_when_abort_cleanup_fails
test_spawn_releases_orca_resources_when_metadata_write_fails
test_peek_send_and_crew_state_route_through_orca_meta
test_peek_and_crew_state_fail_closed_on_orca_error_json
test_target_exists_rejects_orca_error_json
test_target_exists_rejects_exited_orca_terminal
test_busy_and_agent_state_read_orca_agent_listing
test_crew_state_reports_orca_agent_state
test_crew_state_keeps_live_orca_terminal_without_a_rendered_screen
test_scout_teardown_removes_orca_worktree_via_helper
test_scout_teardown_refuses_orca_id_path_mismatch
test_teardown_removes_orca_worktree_when_path_missing
test_teardown_retires_orca_secondmate_closing_only_its_terminal
test_teardown_preserves_metadata_when_orca_remove_error_json
test_scout_teardown_refuses_orca_missing_report_when_path_missing
test_ship_teardown_refuses_orca_missing_worktree_path
test_ship_teardown_removes_orca_worktree_when_id_path_matches
test_ship_teardown_refuses_orca_unresolvable_worktree_id
test_ship_teardown_refuses_orca_id_path_mismatch
test_teardown_refuses_orca_missing_worktree_id
test_ship_force_teardown_keeps_an_unlanded_orca_branch
test_ship_teardown_stops_when_the_orca_close_fails
test_teardown_refuses_orca_worktree_without_terminal_handle
test_secondmate_force_teardown_removes_orca_child_via_orca
test_secondmate_force_teardown_refuses_orca_child_id_path_mismatch
test_secondmate_force_teardown_refuses_partial_orca_child
