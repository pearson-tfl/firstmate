#!/usr/bin/env bash
# Behaviour of bin/fm-exhaust-switch.sh: which seats it moves, when, and what
# it records. The control plane is stood in for (FM_TEST_EXHAUST_CONTROL), so
# this pins detection and decisions only; the real move is proven by the live
# lab recorded in the PR (a real omp seat on a stubbed exhausted login).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-exhaust-switch.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
mkdir -p "$STATE" "$HOME_DIR/config" "$HOME_DIR/data" "$TMP_ROOT/bin"
export FM_HOME="$HOME_DIR" FM_EXHAUSTED_LOGINS="$TMP_ROOT/exhausted"
# The stand-in control plane records each call; the omp one also rewrites the
# record's profile the way a real relaunch republishes it.
cat > "$TMP_ROOT/bin/control" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$FM_HOME/control.log"
[ "$2" != resume ] || printf 'omp_profile=spare\n' >> "$FM_HOME/state/$1.meta"
exit 0
SH
chmod +x "$TMP_ROOT/bin/control"
export FM_TEST_EXHAUST_CONTROL="$TMP_ROOT/bin/control"

# omp_seat <id> <retry-after-ms> [busy|idle]: an omp seat whose session ends in a 429.
omp_seat() {
  local id=$1 ms=$2 st=${3:-idle} gen session="$TMP_ROOT/$1.jsonl"
  printf 'window=fake:%s\nharness=omp\nkind=secondmate\nomp_profile=busy\n' "$id" > "$STATE/$id.meta"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$id" --state "$st" --source omp-ext --event test)
  printf 'busy_gen=%s\n' "$gen" >> "$STATE/$id.meta"
  printf '%s\n' "$session" > "$STATE/$id.omp-session"
  {
    printf '{"type":"session","id":"s-%s"}\n' "$id"
    printf '{"type":"message","message":{"role":"assistant","stopReason":"stop","timestamp":1}}\n'
    printf '{"type":"message","message":{"role":"assistant","stopReason":"error","errorStatus":429,"timestamp":1794595559049,"completedAt":1794595559425,"errorMessage":"429 {\\"type\\":\\"error\\",\\"error\\":{\\"type\\":\\"rate_limit_error\\"}} retry-after-ms=%s"}}\n' "$ms"
    printf '{"type":"custom_message","customType":"session-stop-continuation"}\n'
  } > "$session"
}

run_check() { FM_BACKEND=tmux bash "$ROOT/bin/fm-exhaust-switch.sh" check 2>&1; }
wait_record() {  # <id> <status>
  for _ in $(seq 1 50); do
    grep -qx "status=$2" "$STATE/$1.exhaust-switch" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

# A long 429 on an idle seat moves it once, records the login, and reports.
omp_seat longwait 371640000
out=$(run_check)
case "$out" in *"longwait ran out of usage on omp:busy"*) ;; *) fail "a long 429 on an idle seat must start a move: $out" ;; esac
wait_record longwait "done" || fail "the detached move must finish: $(cat "$STATE/longwait.exhaust-switch.log" 2>/dev/null)"
grep -qx "longwait resume --note Firstmate moved this seat to another login because omp:busy ran out of usage; carry on with your task." "$HOME_DIR/control.log" \
  || fail "an omp seat must move through resume: $(cat "$HOME_DIR/control.log")"
awk '$1 == "omp:busy" && $2 == 1794967199 { found = 1 } END { exit !found }' "$FM_EXHAUSTED_LOGINS" \
  || fail "the login must be recorded until completedAt plus retry-after: $(cat "$FM_EXHAUSTED_LOGINS")"
out=$(run_check)
case "$out" in *"longwait moved from omp:busy to omp:spare"*) ;; *) fail "the outcome must be reported once: $out" ;; esac
[ "$(grep -c resume "$HOME_DIR/control.log")" = 1 ] || fail "the same error must never move the seat twice"
[ -z "$(run_check)" ] || fail "a reported outcome must not be reported again"
pass "exhaust switch: an idle omp seat on a long 429 moves once, records the login, and reports the outcome"

# A short wait is omp's own retry, and a busy seat is left for a later cycle.
: > "$HOME_DIR/control.log"
omp_seat shortwait 120000
omp_seat working 371640000 busy
[ -z "$(run_check)" ] || fail "a short retry or a busy seat must not be moved"
[ ! -s "$HOME_DIR/control.log" ] || fail "nothing may be moved: $(cat "$HOME_DIR/control.log")"
pass "exhaust switch: a short retry-after and a busy seat are left alone"

# A Claude seat on a usage stop moves through the account verb to the best
# other cswap account, skipping the one it is leaving.
claude_root="$TMP_ROOT/claude-home"
mkdir -p "$claude_root/.claude/projects/-wt"
printf 'window=fake:cl\nharness=claude\nkind=ship\naccount=cswap:1\nproject=/x/proj\nagent_session_id=sess-1\n' > "$STATE/cl.meta"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" cl --state idle --source claude-hook --event test)
printf 'busy_gen=%s\n' "$gen" >> "$STATE/cl.meta"
printf '{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,"timestamp":"2026-11-03T11:22:53.741Z","message":{"content":[{"type":"text","text":"limit"}]}}\n' \
  > "$claude_root/.claude/projects/-wt/sess-1.jsonl"
cat > "$TMP_ROOT/bin/cswap" <<'SH'
#!/bin/sh
printf '%s\n' '{"schemaVersion":1,"accounts":[{"number":1,"usageStatus":"ok","usage":{"fiveHour":{"pct":5}}},{"number":2,"usageStatus":"ok","usage":{"fiveHour":{"pct":40}}}]}'
SH
chmod +x "$TMP_ROOT/bin/cswap"
out=$(HOME=$claude_root PATH="$TMP_ROOT/bin:$PATH" run_check)
case "$out" in *"cl ran out of usage on cswap:1"*) ;; *) fail "a Claude usage stop must start a move: $out" ;; esac
HOME=$claude_root PATH="$TMP_ROOT/bin:$PATH" wait_record cl "done" || fail "the Claude move must finish: $(cat "$STATE/cl.exhaust-switch.log")"
grep -qx "cl account 2" "$HOME_DIR/control.log" || fail "the Claude seat must move to account 2: $(cat "$HOME_DIR/control.log")"
pass "exhaust switch: a Claude usage stop moves to the best other cswap account through the account verb"

# arm registers the check on the watcher cycle; disarm retires it.
out=$(bash "$ROOT/bin/fm-exhaust-switch.sh" arm) || fail "arm failed: $out"
[ -x "$STATE/exhaust-switch.check.sh" ] && [ -f "$STATE/exhaust-switch.check-trust" ] || fail "arm must write and register the shim"
out=$(bash "$ROOT/bin/fm-exhaust-switch.sh" disarm) || fail "disarm failed: $out"
[ ! -e "$STATE/exhaust-switch.check.sh" ] && [ ! -e "$STATE/exhaust-switch.check-trust" ] || fail "disarm must remove the shim and its trust"
pass "exhaust switch: arm registers the watcher check and disarm retires it"
