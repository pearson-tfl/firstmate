#!/usr/bin/env bash
# Behavioral coverage for bin/fm-merge-stall.sh: a PR a home merges without
# asking, left unmerged while its worker waits, wakes the home to merge it and
# then reaches the captain, identically in main, local-mate, and remote-mate
# homes, plus a replay of the stall it was built for and the real watcher poll.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCAN="$ROOT/bin/fm-merge-stall.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-stall)
URL=https://github.com/owner/repo/pull/628
T0=1795641826  # the replayed worker's first paused: line, 2026-11-25T21:23:46Z

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

make_world() {  # <name>
  WORLD="$TMP_ROOT/$1"
  MAIN="$WORLD/main"
  MATE="$WORLD/mate"
  mkdir -p "$WORLD/fakebin" "$MAIN"/{state,data,config} "$MATE"/{state,data,config}
  # Stand-ins for the forge reader and the captain-hold predicate.
  cat > "$WORLD/fakebin/pr-state" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_TEST_FORGE_LOG:?}"
if [ "${FM_TEST_HANG_READ:-}" = forge ] && [ "$1" = "${FM_TEST_BAD_PR:-}" ]; then exec "${0%/*}/hang-read"; fi
if [ "${FM_TEST_PR_RC:-0}" != 0 ] && { [ -z "${FM_TEST_BAD_PR:-}" ] || [ "$1" = "$FM_TEST_BAD_PR" ]; }; then exit "$FM_TEST_PR_RC"; fi
if [ "$1" = "${FM_TEST_CLOSED_URL:-}" ]; then
  printf 'STATE: closed\n'
elif [ "$1" = "${FM_TEST_PR_DRAFT_URL:-}" ]; then
  printf 'DRAFT: pull request is not ready for review\n'
else
  [ -z "${FM_TEST_PR_STATE:-}" ] || printf '%s\n' "$FM_TEST_PR_STATE"
fi
SH
  cat > "$WORLD/fakebin/captain-hold" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "${0%/fakebin/captain-hold}/hold.log"
if [ "${FM_TEST_HANG_READ:-}" = hold ] && [ "$2" = "${FM_TEST_BAD_TASK:-}" ]; then exec "${0%/*}/hang-read"; fi
[ "${FM_TEST_HELD:-}" = "$2" ] && exit 0
[ -z "${FM_TEST_HOLD_ERROR:-}" ] || printf '%s\n' "$FM_TEST_HOLD_ERROR" >&2
exit "${FM_TEST_HOLD_RC:-1}"
SH
  cat > "$WORLD/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "${FM_TEST_LOOKUP_LOG:?}"
case "$*" in
  'pr list --state open --head fm/unregistered --limit 20 --json url,isDraft,headRefName,headRepository,headRepositoryOwner') ;;
  *) exit 2 ;;
esac
if [ "${FM_TEST_HANG_READ:-}" = discovery ]; then exec "${0%/*}/hang-read"; fi
if [ "${FM_TEST_DISCOVERY_RC:-0}" != 0 ]; then
  printf '%s\n' "${FM_TEST_DISCOVERY_ERROR:-discovery unavailable}" >&2
  exit "$FM_TEST_DISCOVERY_RC"
fi
if [ "${FM_TEST_DISCOVERY_OUTPUT+x}" ]; then
  printf '%s\n' "$FM_TEST_DISCOVERY_OUTPUT"
elif [ -n "${FM_TEST_BRANCH_URL:-}" ]; then
  entry=$(printf '{"url":"%s","isDraft":%s,"headRefName":"%s","headRepository":{"name":"%s"},"headRepositoryOwner":{"login":"%s"}}' \
    "$FM_TEST_BRANCH_URL" "${FM_TEST_BRANCH_DRAFT:-false}" "${FM_TEST_BRANCH_REF:-fm/unregistered}" \
    "${FM_TEST_BRANCH_REPO:-repo}" "${FM_TEST_BRANCH_OWNER:-owner}")
  if [ "${FM_TEST_BRANCH_DUP:-0}" = 1 ]; then printf '[%s,%s]\n' "$entry" "$entry"; else printf '[%s]\n' "$entry"; fi
else
  printf '[]\n'
fi
SH
  cat > "$WORLD/fakebin/crew-state" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${0%/fakebin/crew-state}/activity.log"
if [ "${FM_TEST_SLOW_CREW:-0}" = 1 ]; then
  case "$1" in slow-*) sleep 600 ;; esac
fi
if [ "$1" = "${FM_TEST_BAD_TASK:-}" ]; then
  if [ "${FM_TEST_HANG_READ:-}" = crew ]; then exec "${0%/*}/hang-read"; fi
  [ "${FM_TEST_ACTIVITY_RC:-0}" = 0 ] || exit "$FM_TEST_ACTIVITY_RC"
  printf '%s\n' "${FM_TEST_ACTIVITY:-state: paused · source: status-log · waiting on home}"
else
  printf 'state: paused · source: status-log · waiting on home\n'
fi
SH
  cat > "$WORLD/fakebin/hang-read" <<'SH'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" > "${FM_TEST_READ_PIDS:?}"
sleep 600 &
printf '%s\n' "$!" >> "$FM_TEST_READ_PIDS"
wait
SH
  chmod +x "$WORLD/fakebin"/*
  : > "$WORLD/forge.log"
  : > "$WORLD/lookup.log"
}

bind_mate() {  # <local|remote>
  printf 'mate\n' > "$MATE/.fm-secondmate-home"
  if [ "$1" = local ]; then
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$MAIN" > "$MATE/.fm-secondmate-parent"
  else
    printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$MATE/.fm-secondmate-parent"
  fi
}

# A ship task with a recorded PR and an armed merge poll for it.
write_task() {  # <home> <task> <yolo> <status-lines...>
  local home=$1 task=$2 yolo=$3
  shift 3
  printf 'kind=ship\nmode=direct-PR\nyolo=%s\npr=%s\n' "$yolo" "$URL" > "$home/state/$task.meta"
  printf 'github\n%s\ngithub.com\nowner/repo\n628\n' "$URL" > "$home/state/$task.pr-poll"
  printf '%s\n' "$@" > "$home/state/$task.status"
}

scan() {  # <home> <now>
  PATH="$WORLD/fakebin:$PATH" FM_TEST_LOOKUP_LOG="$WORLD/lookup.log" \
    FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" \
    FM_MERGE_STALL_PR_STATE_BIN="$WORLD/fakebin/pr-state" \
    FM_MERGE_STALL_CAPTAIN_HOLD_BIN="$WORLD/fakebin/captain-hold" \
    FM_MERGE_STALL_CREW_STATE_BIN="${FM_TEST_CREW_STATE_BIN:-$WORLD/fakebin/crew-state}" \
    FM_TEST_FORGE_LOG="$WORLD/forge.log" bash "$SCAN" scan --now "$2"
}

observe_merge() (
  local fixture_home=$1 task=$2
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-pr-lib.sh"
  fm_pr_url_parse "$URL" && fm_pr_poll_merge_mark_notified "$fixture_home/state" "$task" "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" || exit 1
  rm -f "$fixture_home/state/$task.pr-poll"
)

parent_open() (
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-classify-lib.sh"
  status_open_decisions "$1"
)

fail_ledger_commit() {
  local real_mv
  real_mv=$(command -v mv)
  printf '%s\n' "$real_mv" > "$WORLD/real-mv"
  : > "$WORLD/renames"
  cat > "$WORLD/fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.merge-stall)
      dir=${0%/fakebin/mv}
      printf 'rename\n' >> "$dir/renames"
      [ "$(wc -l < "$dir/renames" | tr -d ' ')" != 2 ] || exit 1
      ;;
  esac
done
IFS= read -r real_mv < "${0%/fakebin/mv}/real-mv"
exec "$real_mv" "$@"
SH
  chmod +x "$WORLD/fakebin/mv"
}

channel_lines() {  # <file> -> lines with stamps removed
  sed -E 's/ \[at=[0-9]+\]//' "$1" 2>/dev/null
}

# The stall as it happened: a direct-PR yolo task reports its fix PR in a
# working: line, then declares paused: waits on its home, and the PR's only
# failing check is reported but not required.
test_replay_paused_worker_red_pr() {
  local out P
  make_world paused-red-pr
  write_task "$MAIN" wf-wiki-grill-session on \
    "working [at=$T0]: Ready fix PR $URL is OPEN, isDraft=false; no merge or auto-merge." \
    "paused [at=$T0] [key=advisory-032-native-and-ci-results]: awaits native job; await firstmate if Python fails." \
    "resolved [at=$((T0 + 70))] [key=advisory-032-native-and-ci-results]: watcher timed out; ready unmerged fix remains $URL." \
    "paused [at=$((T0 + 70))] [key=advisory-032-native-and-python-watch-v2]: If Python fails, the verified ready fix PR is already open for firstmate; do not merge it."
  P=$((T0 + 70))  # the standing paused: line, 21:24:56Z
  out=$(scan "$MAIN" $((P + 300))) || fail "replay scan failed"
  [ -z "$out" ] || fail "a fresh wait woke the home before the stall bound: $out"
  [ ! -s "$WORLD/forge.log" ] || fail "a scan before the bound read the forge"

  export FM_TEST_PR_STATE=$'CHECKS: no required check has reported; readiness unconfirmed\nREPORTED CHECK: python (FAILURE)'
  out=$(scan "$MAIN" $((P + 600))) || fail "replay scan failed at the bound"
  case "$out" in
    "wf-wiki-grill-session PR $URL unmerged 600s while its worker waits on this home (paused: "*"merge it now with bin/fm-pr-merge.sh wf-wiki-grill-session $URL, and if that refuses, act on the refusal [forge: CHECKS: no required check has reported; readiness unconfirmed; REPORTED CHECK: python (FAILURE)]") ;;
    *) fail "the replayed stall did not direct the home to merge with the red check named: $out" ;;
  esac
  out=$(scan "$MAIN" $((P + 900))) || fail "replay rescan failed"
  [ -z "$out" ] || fail "the merge wake repeated before its interval: $out"
  out=$(scan "$MAIN" $((P + 1200))) || fail "replay repeat failed"
  case "$out" in *"unmerged 1200s"*) ;; *) fail "the merge wake did not repeat while unmerged: $out" ;; esac
  out=$(scan "$MAIN" $((P + 1800))) || fail "replay escalation failed"
  case "$out" in *"unmerged 1800s"*"; stalled past 1800s: tell the captain now") ;; *) fail "the main home was not told to tell the captain: $out" ;; esac
  out=$(scan "$MAIN" $((P + 2400))) || fail "post-escalation scan failed"
  [ -z "$out" ] || fail "after escalation the wake repeated on the short interval: $out"
  out=$(scan "$MAIN" $((P + 3600))) || fail "post-escalation repeat failed"
  case "$out" in *"unmerged 3600s"*"tell the captain now") ;; *) fail "the escalated stall stopped repeating: $out" ;; esac
  unset FM_TEST_PR_STATE
  pass "the replayed stall wakes the home to merge at 10 minutes, repeats, and reaches the captain at 30"
}

test_merged_or_released_ends_stall() {
  local out
  make_world ends
  write_task "$MAIN" t on "done [at=$T0]: PR $URL checks green"
  FM_TEST_PR_STATE='STATE: merged at 2026-11-25T22:00:00Z' out=$(FM_TEST_PR_STATE='STATE: merged at 2026-11-25T22:00:00Z' scan "$MAIN" $((T0 + 600)))
  [ -z "$out" ] || fail "a merged PR still woke the home: $out"
  [ ! -s "$MAIN/state/.merge-stall" ] || fail "a merged PR kept its stall row"

  make_world retired
  write_task "$MAIN" t on "done [at=$T0]: PR $URL checks green"
  observe_merge "$MAIN" t || fail "could not record the merged PR identity"
  out=$(scan "$MAIN" $((T0 + 600)))
  [ -z "$out" ] || fail "a PR whose merge was observed still woke the home: $out"

  make_world resumed
  write_task "$MAIN" t on "done [at=$T0]: PR $URL checks green" "working [at=$((T0 + 10))]: fixing review comments"
  out=$(scan "$MAIN" $((T0 + 600)))
  [ -z "$out" ] || fail "a working worker was treated as waiting: $out"
  pass "a merged PR, a retired merge poll, or a working worker is not a stall"
}

test_posture_and_holds_respected() {
  local out
  make_world posture
  write_task "$MAIN" t off "done [at=$T0]: PR $URL checks green"
  out=$(scan "$MAIN" $((T0 + 3600)))
  [ -z "$out" ] || fail "a home that asks before merging was told to merge: $out"
  make_world held
  write_task "$MAIN" t on "done [at=$T0]: PR $URL checks green"
  out=$(FM_TEST_HELD=t scan "$MAIN" $((T0 + 3600)))
  [ -z "$out" ] || fail "a task held for the captain was told to merge: $out"
  out=$(FM_TEST_HOLD_RC=2 scan "$MAIN" $((T0 + 3600)))
  case "$out" in *"captain-hold read failed (rc=2)"*"repair the captain-hold authorization check before merging"*) ;; *) fail "an unreadable captain-hold answer was silent: $out" ;; esac
  case "$out" in *"merge it now"*|*"bin/fm-pr-merge.sh"*) fail "an unreadable captain hold authorized a merge: $out" ;; esac
  make_world captain-held
  write_task "$MAIN" t on "captain-held [at=$T0]: captain reviews the PR"
  out=$(scan "$MAIN" $((T0 + 3600)))
  [ -z "$out" ] || fail "a captain-held transfer was told to merge: $out"
  pass "held tasks stay silent and unreadable holds surface without merge authorization"
}

# The same lever in a secondmate home also reaches main through the parent
# channel, once per stall, and closes that blocker when the stall ends.
check_mate_route() {  # <local|remote>
  local route=$1 channel out key
  make_world "mate-$route"; bind_mate "$route"
  if [ "$route" = local ]; then channel="$MAIN/state/mate.status"; else channel="$MATE/state/parent-replies.status"; fi
  write_task "$MATE" child on "done [at=$T0]: PR $URL checks green"
  out=$(scan "$MATE" $((T0 + 600)))
  case "$out" in "child PR $URL unmerged 600s"*"merge it now with bin/fm-pr-merge.sh child $URL"*) ;; *) fail "$route mate home was not told to merge: $out" ;; esac
  [ ! -e "$channel" ] || fail "$route mate escalated before the captain bound"
  out=$(scan "$MATE" $((T0 + 1800)))
  case "$out" in *"stalled past 1800s: reported to the captain through the parent channel") ;; *) fail "$route mate wake did not name the escalation: $out" ;; esac
  key=$(channel_lines "$channel" | sed -n 's/^blocked \[key=\(merge-stall-child-[0-9]*\)\]: merge stall child: PR .* unmerged while its worker waits on this home (waiting since [0-9]*)$/\1/p')
  [ -n "$key" ] || fail "$route mate did not publish the stall on its parent channel: $(cat "$channel" 2>/dev/null)"
  scan "$MATE" $((T0 + 3600)) >/dev/null
  [ "$(grep -c "^blocked" "$channel")" = 1 ] || fail "$route mate re-published one stall"
  observe_merge "$MATE" child || fail "could not record the mate PR merge"
  out=$(scan "$MATE" $((T0 + 3700)))
  [ -z "$out" ] || fail "$route mate woke after the merge was observed: $out"
  channel_lines "$channel" | grep -Fxq "resolved [key=$key]: merge stall child: PR $URL is no longer a merge candidate or its worker waiting episode ended" \
    || fail "$route mate did not resolve the stall upstream: $(cat "$channel")"
}

test_secondmate_routes() {
  check_mate_route local
  check_mate_route remote
  pass "local and remote secondmate homes merge-wake themselves and escalate once through the parent channel"
}

write_unregistered_task() {
  local home=$1 task=$2 verb=$3
  mkdir -p "$home/copy"
  git -C "$home/copy" init -q
  git -C "$home/copy" remote add origin "${FM_TEST_PUSH_REMOTE:-https://github.com/owner/repo.git}" 2>/dev/null || :
  printf 'kind=ship\nmode=direct-PR\nyolo=on\nworktree=%s\nbranch=fm/unregistered\n' "$home/copy" > "$home/state/$task.meta"
  printf 'working [at=%s]: Ready fix PR %s\n%s [at=%s]: waiting on home\n' "$T0" "$URL" "$verb" "$T0" > "$home/state/$task.status"
}

test_unregistered_pr() {
  local route home verb out
  for route in main local remote; do
    for verb in paused "done"; do
      make_world "unregistered-$route-$verb"
      home=$MAIN
      if [ "$route" != main ]; then bind_mate "$route"; home=$MATE; fi
      write_unregistered_task "$home" t "$verb"
      out=$(FM_TEST_BRANCH_URL="$URL" scan "$home" $((T0 + 600))) || fail "unregistered PR scan failed"
      case "$out" in "t PR $URL unmerged 600s"*"merge it now with bin/fm-pr-merge.sh t $URL"*) ;; *) fail "unregistered $route $verb PR was missed: $out" ;; esac
      [ "$(wc -l < "$WORLD/lookup.log" | tr -d ' ')" = 1 ] || fail "unregistered PR needed more than one forge lookup"
      grep -Fxq "$home/copy|pr list --state open --head fm/unregistered --limit 20 --json url,isDraft,headRefName,headRepository,headRepositoryOwner" "$WORLD/lookup.log" || fail "lookup did not address the task branch in its repository"
      [ ! -e "$home/state/t.pr-poll" ] || fail "lookup created a second PR registry"
      out=$(FM_TEST_BRANCH_URL="$URL" scan "$home" $((T0 + 900))) || fail "unregistered PR rescan failed"
      [ -z "$out" ] || fail "unregistered PR bypassed reminder backoff: $out"
    done
  done
  make_world no-lookup
  write_unregistered_task "$MAIN" active paused
  printf 'working [at=%s]: still coding\n' "$((T0 + 10))" >> "$MAIN/state/active.status"
  write_unregistered_task "$MAIN" asks paused
  printf 'yolo=off\n' >> "$MAIN/state/asks.meta"
  write_task "$MAIN" registered on "done [at=$T0]: PR ready"
  scan "$MAIN" $((T0 + 600)) >/dev/null || fail "registered PR scan failed"
  [ ! -s "$WORLD/lookup.log" ] || fail "a registered, working, or non-yolo task caused branch discovery"
  make_world no-open-pr
  write_unregistered_task "$MAIN" t paused
  out=$(scan "$MAIN" $((T0 + 600))) || fail "empty discovery failed"
  [ -z "$out" ] || fail "no open branch PR still caused a merge wake"
  pass "unregistered paused and done PRs are discovered once per scan in every home route"
}

test_due_stalls_make_progress() {
  local out n now seen='' closed=https://github.com/owner/repo/pull/1
  make_world closed-oldest
  URL="$closed" write_task "$MAIN" a-closed on "done [at=$((T0 - 100))]: closed PR"
  write_task "$MAIN" b-open on "done [at=$T0]: open PR"
  for now in $((T0 + 600)) $((T0 + 1200)); do
    out=$(FM_TEST_CLOSED_URL="$closed" scan "$MAIN" "$now") || fail "closed PR scan failed"
    case "$out" in "b-open PR $URL unmerged"*) ;; *) fail "an older terminal PR consumed the wake: $out" ;; esac
  done
  make_world many-stalls
  for n in 1 2 3 4 5 6 7 8; do
    write_task "$MAIN" "t$n" on "done [at=$((T0 + n))]: ready PR"
  done
  for n in 0 1 2 3 4 5 6 7; do
    out=$(scan "$MAIN" $((T0 + 4000 + n * 300))) || fail "fairness scan failed"
    seen="$seen ${out%% *}"
  done
  for n in 1 2 3 4 5 6 7 8; do
    case " $seen " in *" t$n "*) ;; *) fail "a repeating older stall starved t$n: $seen" ;; esac
  done
  out=$(scan "$MAIN" $((T0 + 6400))) || fail "least-recent reminder scan failed"
  case "$out" in "t1 PR "*) ;; *) fail "least recently notified stall did not repeat first: $out" ;; esac
  pass "terminal PRs cannot consume notifications and due stalls progress before reminders"
}

test_replaced_waiting_episode() {
  local route verb channel out first second new_time
  for route in local remote; do
    for verb in paused "done"; do
      make_world "episode-$route-$verb"; bind_mate "$route"
      if [ "$route" = local ]; then channel="$MAIN/state/mate.status"; else channel="$MATE/state/parent-replies.status"; fi
      write_task "$MATE" child on "$verb [at=$T0]: first wait"
      scan "$MATE" $((T0 + 1800)) >/dev/null || fail "first episode failed"
      first=$(channel_lines "$channel" | sed -n 's/^blocked \[key=\([^]]*\)\]:.*/\1/p')
      new_time=$((T0 + 1900))
      printf 'working [at=%s]: more work\n%s [at=%s]: second wait\n' "$((T0 + 1850))" "$verb" "$new_time" >> "$MATE/state/child.status"
      out=$(scan "$MATE" $((new_time + 300))) || fail "replacement scan failed"
      [ -z "$out" ] || fail "new waiting episode inherited the old age: $out"
      channel_lines "$channel" | grep -Fq "resolved [key=$first]:" || fail "old episode stayed open upstream"
      out=$(scan "$MATE" $((new_time + 600))) || fail "replacement wake failed"
      case "$out" in "child PR $URL unmerged 600s"*"merge it now"*) ;; *) fail "new episode inherited reminder suppression: $out" ;; esac
      out=$(scan "$MATE" $((new_time + 1800))) || fail "replacement escalation failed"
      second=$(channel_lines "$channel" | sed -n 's/^blocked \[key=\([^]]*\)\]:.*/\1/p' | tail -1)
      [ -n "$first" ] && [ -n "$second" ] && [ "$first" != "$second" ] || fail "distinct episodes reused their parent key"
      [ "$(grep -c '^blocked' "$channel")" = 2 ] || fail "new episode inherited escalation suppression"
    done
  done
  make_world unstamped
  write_task "$MAIN" t on 'paused: first wait'
  scan "$MAIN" "$T0" >/dev/null || fail "unstamped first sight failed"
  out=$(scan "$MAIN" $((T0 + 600))) || fail "unstamped wake failed"
  case "$out" in *"unmerged 600s"*) ;; *) fail "unstamped episode lost its first sight time" ;; esac
  printf 'working: more work\npaused: second wait\n' >> "$MAIN/state/t.status"
  out=$(scan "$MAIN" $((T0 + 700))) || fail "unstamped replacement failed"
  [ -z "$out" ] || fail "unstamped replacement inherited the first episode"
  pass "paused and done episode replacements reset age, reminders and escalation on both parent routes"
}

start_watcher() {
  local fixture_home=$1
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$fixture_home" FM_STATE_OVERRIDE="$fixture_home/state" \
    FM_DATA_OVERRIDE="$fixture_home/data" FM_CONFIG_OVERRIDE="$fixture_home/config" \
    FM_MERGE_STALL_PR_STATE_BIN="$WORLD/fakebin/pr-state" \
    FM_MERGE_STALL_CAPTAIN_HOLD_BIN="$WORLD/fakebin/captain-hold" FM_TEST_FORGE_LOG="$WORLD/forge.log" \
    FM_TEST_LOOKUP_LOG="$WORLD/lookup.log" FM_MERGE_STALL_CREW_STATE_BIN="$WORLD/fakebin/crew-state" \
    FM_CHECK_TIMEOUT="${FM_TEST_CHECK_TIMEOUT:-30}" FM_MERGE_STALL_READ_TIMEOUT="${FM_TEST_READ_TIMEOUT:-5}" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=300 FM_HEARTBEAT=999999 bash "$WATCH" > "$WORLD/watch.out" 2>&1 &
  WATCH_PID=$!
}

run_watcher() {
  local pid i=0
  start_watcher "$1"
  pid=$WATCH_PID
  while [ "$i" -lt "${FM_TEST_WATCH_LIMIT:-100}" ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    reap "$pid"
    fail "watcher did not finish its sweep: $(cat "$WORLD/watch.out")"
  fi
  wait "$pid" || fail "watcher failed: $(cat "$WORLD/watch.out")"
}

test_watcher_poll_wakes_home() {
  local now
  make_world watcher
  now=$(date +%s)
  write_task "$MAIN" t on "done [at=$((now - 700))]: PR $URL checks green"
  run_watcher "$MAIN"
  grep -Fq "check: merge stall: t PR $URL unmerged" "$MAIN/state/.wake-queue" \
    || fail "the watcher poll did not queue the merge-stall wake: $(cat "$WORLD/watch.out")"
  pass "the real watcher poll queues the merge-stall wake"
}

test_chatty_check_cannot_starve_scan() {
  local now
  make_world chatty
  now=$(date +%s)
  write_task "$MAIN" t on "done [at=$((now - 700))]: PR ready"
  # shellcheck disable=SC2016 # a literal script body
  printf '#!/usr/bin/env bash\nprintf "fresh mail\\n"\n' > "$MAIN/state/mail.check.sh"
  chmod 700 "$MAIN/state/mail.check.sh"
  FM_HOME="$MAIN" bash "$ROOT/bin/fm-check-register.sh" mail >/dev/null || fail "custom mail check registration failed"
  run_watcher "$MAIN"
  grep -Fq 'fresh mail' "$WORLD/watch.out" || fail "mail did not terminate the check sweep"
  grep -Fq "check: merge stall: t PR $URL unmerged" "$MAIN/state/.wake-queue" || fail "chatty mail starved the merge scan"
  [ -f "$MAIN/state/.last-check" ] || fail "chatty sweep lost its cadence marker"
  pass "merge-stall wake is queued before a chatty check exits the sweep"
}

test_scanner_failures_wake_home() {
  local kind now home channel real_mktemp real_mv real_cat
  real_mktemp=$(command -v mktemp)
  real_mv=$(command -v mv)
  real_cat=$(command -v cat)
  for kind in ledger-type ledger-read ledger-temp ledger-write parent-local parent-remote resolved-local resolved-remote; do
    make_world "failure-$kind"
    home=$MAIN
    case "$kind" in
      ledger-type) mkdir "$MAIN/state/.merge-stall" ;;
      ledger-read)
        : > "$MAIN/state/.merge-stall"
        # shellcheck disable=SC2016 # a literal script body
        printf '#!/usr/bin/env bash\ncase "$1" in */.merge-stall) echo "ledger read refused" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' "$real_cat" > "$WORLD/fakebin/cat"
        chmod +x "$WORLD/fakebin/cat"
        ;;
      ledger-temp)
        # shellcheck disable=SC2016 # a literal script body
        printf '#!/usr/bin/env bash\ncase "$1" in */.merge-stall.??????) echo "ledger storage unavailable" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' "$real_mktemp" > "$WORLD/fakebin/mktemp"
        chmod +x "$WORLD/fakebin/mktemp"
        ;;
      ledger-write)
        # shellcheck disable=SC2016 # a literal script body
        printf '#!/usr/bin/env bash\nfor arg in "$@"; do case "$arg" in */.merge-stall) echo "ledger rename refused" >&2; exit 1 ;; esac; done\nexec "%s" "$@"\n' "$real_mv" > "$WORLD/fakebin/mv"
        chmod +x "$WORLD/fakebin/mv"
        ;;
      parent-*|resolved-*)
        bind_mate "${kind##*-}"
        home=$MATE
        if [ "${kind##*-}" = local ]; then channel="$MAIN/state/mate.status"; else channel="$MATE/state/parent-replies.status"; fi
        now=$(date +%s)
        write_task "$home" t on "done [at=$((now - 2000))]: PR ready"
        case "$kind" in
          resolved-*)
            scan "$home" "$now" >/dev/null || fail "resolution fixture escalation failed"
            mv "$channel" "$WORLD/channel.saved"
            printf 'working [at=%s]: resumed\n' "$now" >> "$home/state/t.status"
            ;;
        esac
        mkdir "$channel"
        ;;
    esac
    run_watcher "$home"
    grep -Fq 'check: merge stall: scan failed (rc=1):' "$home/state/.wake-queue" || fail "$kind detector failure stayed silent: $(cat "$WORLD/watch.out")"
    case "$kind" in
      ledger-*) grep -Fq 'ledger' "$home/state/.wake-queue" || fail "$kind failure omitted its cause" ;;
      parent-*) { grep -Fq "parent channel append failed (rc=4):" "$home/state/.wake-queue" && grep -Fq "PR $URL" "$home/state/.wake-queue"; } || fail "$kind failure omitted the detected stall" ;;
      resolved-*) { grep -Fq 'parent channel read failed' "$home/state/.wake-queue" && grep -Fq "PR $URL" "$home/state/.wake-queue"; } || fail "$kind failure omitted the unresolved episode" ;;
    esac
    [ "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" = 1 ] || fail "$kind failure queued more than one wake"
    [ -f "$home/state/.last-check" ] || fail "$kind failure did not retain bounded sweep cadence"
  done
  pass "ledger and parent-channel failures produce actionable bounded watcher wakes"
}

test_hold_failure_diagnostic() {
  local out
  make_world hold-diagnostic
  write_task "$MAIN" t on "done [at=$T0]: PR ready"
  out=$(FM_TEST_HOLD_RC=2 FM_TEST_HOLD_ERROR='compatible tasks-axi is required' scan "$MAIN" $((T0 + 600))) || fail "hold read failure scan failed"
  case "$out" in *'captain-hold read failed (rc=2): compatible tasks-axi is required'*) ;; *) fail "hold failure diagnostic was lost: $out" ;; esac
  case "$out" in *'merge it now'*|*'bin/fm-pr-merge.sh'*) fail "hold failure emitted a merge instruction" ;; esac
  out=$(FM_TEST_HOLD_RC=2 scan "$MAIN" $((T0 + 900))) || fail "hold failure rescan failed"
  [ -z "$out" ] || fail "hold failure ignored the reminder interval"
  pass "captain-hold read diagnostics reach the home without a merge instruction"
}

test_discovery_failure_preserves_episode() {
  local route kind channel before out rc
  for route in local remote; do
    make_world "unknown-discovery-$route"; bind_mate "$route"
    if [ "$route" = local ]; then channel="$MAIN/state/mate.status"; else channel="$MATE/state/parent-replies.status"; fi
    write_unregistered_task "$MATE" child paused
    FM_TEST_BRANCH_URL="$URL" scan "$MATE" $((T0 + 1800)) >/dev/null || fail "unregistered escalation failed"
    before=$(cat "$MATE/state/.merge-stall")
    for kind in timeout malformed invalid-url invalid-draft invalid-shape no-output empty-url invalid-draft-url whitespace multiple-payloads; do
      rc=0
      case "$kind" in
        timeout) out=$(FM_TEST_DISCOVERY_RC=124 FM_TEST_DISCOVERY_ERROR='lookup timed out' scan "$MATE" $((T0 + 3600)) 2>&1) || rc=$? ;;
        malformed) out=$(FM_TEST_DISCOVERY_OUTPUT='not JSON' scan "$MATE" $((T0 + 3600)) 2>&1) || rc=$? ;;
        invalid-url) out=$(FM_TEST_DISCOVERY_OUTPUT='[{"url":"not-a-PR","isDraft":false}]' scan "$MATE" $((T0 + 3600)) 2>&1) || rc=$? ;;
        invalid-draft) out=$(FM_TEST_DISCOVERY_OUTPUT='[{"url":"https://github.com/owner/repo/pull/628","isDraft":"false"}]' scan "$MATE" $((T0 + 3600)) 2>&1) || rc=$? ;;
        invalid-shape) out=$(FM_TEST_DISCOVERY_OUTPUT='{}' scan "$MATE" $((T0 + 3600)) 2>&1) || rc=$? ;;
        no-output) out=$(FM_TEST_DISCOVERY_OUTPUT='' scan "$MATE" $((T0 + 3600)) 2>&1) || rc=$? ;;
        empty-url) out=$(FM_TEST_DISCOVERY_OUTPUT='[{"url":"","isDraft":false}]' scan "$MATE" $((T0 + 3600)) 2>&1) || rc=$? ;;
        invalid-draft-url) out=$(FM_TEST_DISCOVERY_OUTPUT='[{"url":"not-a-PR","isDraft":true}]' scan "$MATE" $((T0 + 3600)) 2>&1) || rc=$? ;;
        whitespace) out=$(FM_TEST_DISCOVERY_OUTPUT='   ' scan "$MATE" $((T0 + 3600)) 2>&1) || rc=$? ;;
        multiple-payloads) out=$(FM_TEST_DISCOVERY_OUTPUT='[] []' scan "$MATE" $((T0 + 3600)) 2>&1) || rc=$? ;;
      esac
      [ "$rc" = 0 ] || fail "$kind discovery prevented scan completion: $out"
      case "$out" in *'PR discovery'*'child'*) ;; *) fail "$kind discovery omitted its task diagnostic: $out" ;; esac
      [ "$(cat "$MATE/state/.merge-stall")" = "$before" ] || fail "$kind discovery discarded an existing episode"
      [ "$(wc -l < "$channel" | tr -d ' ')" = 1 ] || fail "$kind discovery falsely resolved the parent blocker"
    done
    out=$(FM_TEST_BRANCH_URL="$URL" scan "$MATE" $((T0 + 3600))) || fail "discovery recovery failed"
    case "$out" in *'unmerged 3600s'*) ;; *) fail "recovered lookup reset the waiting episode: $out" ;; esac
    [ "$(grep -c '^blocked' "$channel")" = 1 ] || fail "discovery recovery repeated escalation"
    before=$(cat "$MATE/state/.merge-stall")
    rc=0
    out=$(FM_TEST_BRANCH_URL="$URL" FM_TEST_PR_RC=1 scan "$MATE" $((T0 + 5400)) 2>&1) || rc=$?
    [ "$rc" = 0 ] || fail "unreadable PR state prevented scan completion"
    case "$out" in *'forge state unreadable for child'*) ;; *) fail "PR state failure omitted its diagnostic: $out" ;; esac
    [ "$(cat "$MATE/state/.merge-stall")" = "$before" ] || fail "unreadable PR state discarded an existing episode"
    [ "$(wc -l < "$channel" | tr -d ' ')" = 1 ] || fail "unreadable PR state falsely resolved the parent blocker"
    out=$(scan "$MATE" $((T0 + 5500))) || fail "confirmed empty discovery failed"
    [ -z "$out" ] && [ ! -s "$MATE/state/.merge-stall" ] || fail "confirmed empty discovery retained a candidate"
    [ "$(grep -c '^resolved' "$channel")" = 1 ] || fail "positive absence did not close the old episode"
  done
  make_world watcher-discovery
  write_unregistered_task "$MAIN" t paused
  FM_TEST_DISCOVERY_RC=124 FM_TEST_DISCOVERY_ERROR='lookup timed out' run_watcher "$MAIN"
  grep -Fq 'PR discovery failed for t (rc=124): lookup timed out' "$MAIN/state/.wake-queue" || fail "watcher swallowed discovery failure"
  pass "unknown discovery preserves both parent routes and wakes the home; confirmed absence resolves"
}

test_drafts_are_not_candidates() {
  local registration route home channel out
  for route in main local remote; do
    for registration in recorded discovered; do
      make_world "draft-$route-$registration"
      home=$MAIN
      if [ "$route" != main ]; then bind_mate "$route"; home=$MATE; fi
      if [ "$route" = local ]; then channel="$MAIN/state/mate.status"; else channel="$MATE/state/parent-replies.status"; fi
      if [ "$registration" = recorded ]; then
        write_task "$home" t on "paused [at=$T0]: intentionally held draft"
      else
        write_unregistered_task "$home" t paused
      fi
      out=$(FM_TEST_BRANCH_URL="$URL" FM_TEST_BRANCH_DRAFT=true FM_TEST_PR_DRAFT_URL="$URL" scan "$home" $((T0 + 3600))) || fail "draft scan failed"
      [ -z "$out" ] || fail "a $registration draft received a merge instruction: $out"
      [ ! -s "$home/state/.merge-stall" ] || fail "a $registration draft retained a stall"
      [ ! -e "$channel" ] || fail "a $registration draft escalated upstream"
      out=$(FM_TEST_BRANCH_URL="$URL" scan "$home" $((T0 + 3700))) || fail "ready PR scan failed"
      case "$out" in "t PR $URL unmerged 3700s"*'merge it now'*) ;; *) fail "a ready $registration PR was excluded with drafts: $out" ;; esac
    done
  done
  pass "recorded and discovered drafts stay silent in every route while ready PRs wake"
}

test_active_validation_is_not_a_merge_wait() {
  local registration verb out head state
  fm_git_identity fmtest fmtest@example.invalid
  for registration in recorded discovered; do
    for verb in paused "done"; do
      make_world "validation-$registration-$verb"
      write_unregistered_task "$MAIN" t "$verb"
      printf 'mode=no-mistakes\n' >> "$MAIN/state/t.meta"
      if [ "$registration" = recorded ]; then
        printf 'pr=%s\n' "$URL" >> "$MAIN/state/t.meta"
        printf 'github\n%s\ngithub.com\nowner/repo\n628\n' "$URL" > "$MAIN/state/t.pr-poll"
      fi
      git -C "$MAIN/copy" init -q
      git -C "$MAIN/copy" symbolic-ref HEAD refs/heads/fm/unregistered
      git -C "$MAIN/copy" commit -q --allow-empty -m fixture
      head=$(git -C "$MAIN/copy" rev-parse HEAD)
      cat > "$WORLD/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'daemon status') printf 'daemon running\n' ;;
  'axi logs --step ci --run 01RUN --full') printf '%s\n' "${FM_TEST_CI_LOG:-CI checks running, waiting for results...}" ;;
  axi|'axi status'|'axi status --run 01RUN')
    cat <<EOF
run:
  id: "01RUN"
  branch: fm/unregistered
  status: running
  head: "$FM_TEST_RUN_HEAD"
  pr: "https://github.com/owner/repo/pull/628"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
    ;;
  *) exit 2 ;;
esac
SH
      chmod +x "$WORLD/fakebin/no-mistakes"
      state=$(PATH="$WORLD/fakebin:$PATH" FM_TEST_RUN_HEAD="$head" FM_HOME="$MAIN" FM_CREW_STATE_NO_FORGE=1 bash "$ROOT/bin/fm-crew-state.sh" t)
      case "$state" in 'state: working · source: run-step'*) ;; *) fail "pending CI fixture is not actively validating: $state" ;; esac
      out=$(FM_TEST_RUN_HEAD="$head" FM_TEST_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" FM_TEST_BRANCH_URL="$URL" scan "$MAIN" $((T0 + 3600))) || fail "active validation scan failed"
      [ -z "$out" ] && [ ! -s "$MAIN/state/.merge-stall" ] || fail "$registration $verb during active CI was a merge stall: $out"
      [ ! -s "$WORLD/lookup.log" ] || fail "active validation performed branch discovery"
      state=$(PATH="$WORLD/fakebin:$PATH" FM_TEST_RUN_HEAD="$head" FM_TEST_CI_LOG='all CI checks passed - still monitoring until merged or closed' FM_HOME="$MAIN" FM_CREW_STATE_NO_FORGE=1 bash "$ROOT/bin/fm-crew-state.sh" t)
      case "$state" in 'state: done · source: run-step'*'checks green'*) ;; *) fail "green CI fixture is not waiting for merge: $state" ;; esac
      out=$(FM_TEST_RUN_HEAD="$head" FM_TEST_CI_LOG='all CI checks passed - still monitoring until merged or closed' FM_TEST_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" FM_TEST_BRANCH_URL="$URL" scan "$MAIN" $((T0 + 3700))) || fail "green monitor scan failed"
      case "$out" in "t PR $URL unmerged 3700s"*'merge it now'*) ;; *) fail "green merge monitor stayed classified as validation: $out" ;; esac
    done
  done
  pass "real crew-state excludes pending CI for paused and done declarations and accepts a green monitor"
}

test_escalation_retry_is_idempotent() {
  local route channel rc before after
  for route in local remote; do
    make_world "retry-$route"; bind_mate "$route"
    if [ "$route" = local ]; then channel="$MAIN/state/mate.status"; else channel="$MATE/state/parent-replies.status"; fi
    write_task "$MATE" child on "done [at=$T0]: PR ready"
    scan "$MATE" $((T0 + 600)) >/dev/null || fail "retry fixture first wake failed"
    before=$(cat "$MATE/state/.merge-stall")
    fail_ledger_commit
    rc=0
    FM_TEST_PR_STATE='REQUIRED CHECK: tests (PENDING)' scan "$MATE" $((T0 + 1800)) > "$WORLD/scan.out" 2> "$WORLD/scan.err" || rc=$?
    [ "$rc" = 1 ] || fail "ledger failure fixture did not fail"
    [ "$(cat "$MATE/state/.merge-stall")" = "$before" ] || fail "failed ledger write changed notification state"
    [ "$(grep -c '^blocked' "$channel")" = 1 ] || fail "first parent publication missing"
    after=$(channel_lines "$channel")
    mv "$WORLD/fakebin/mv" "$WORLD/mv.saved"
    FM_TEST_PR_STATE='MERGEABILITY: conflicting' scan "$MATE" $((T0 + 2100)) >/dev/null || fail "ledger retry failed"
    [ "$(channel_lines "$channel")" = "$after" ] || fail "new age or forge state duplicated the episode blocker"
    [ "$(grep -c '^blocked' "$channel")" = 1 ] || fail "retry published multiple parent blockers"
    scan "$MATE" $((T0 + 3900)) >/dev/null || fail "post-retry reminder failed"
    [ "$(grep -c '^blocked' "$channel")" = 1 ] || fail "post-retry reminder re-published escalation"
  done
  pass "parent escalation stays singular across failed ledger writes and changing age or blockers"
}

test_interrupted_registration_is_detected() {
  local route poll fixture_home out channel
  for route in main local remote; do
    for poll in missing mismatched; do
      make_world "registration-$route-$poll"
      fixture_home=$MAIN
      if [ "$route" != main ]; then bind_mate "$route"; fixture_home=$MATE; fi
      write_task "$fixture_home" t on "paused [at=$T0]: ready PR awaits home"
      if [ "$poll" = missing ]; then
        mv "$fixture_home/state/t.pr-poll" "$WORLD/poll.saved"
      else
        printf 'github\nhttps://github.com/owner/repo/pull/999\ngithub.com\nowner/repo\n999\n' > "$fixture_home/state/t.pr-poll"
      fi
      out=$(scan "$fixture_home" $((T0 + 1800))) || fail "interrupted registration scan failed"
      case "$out" in "t PR $URL unmerged 1800s"*'merge it now'*) ;; *) fail "$poll poll excluded the ready PR: $out" ;; esac
      out=$(scan "$fixture_home" $((T0 + 3600))) || fail "interrupted registration repeat failed"
      case "$out" in "t PR $URL unmerged 3600s"*) ;; *) fail "$poll poll ended a live episode: $out" ;; esac
      out=$(FM_TEST_PR_STATE='STATE: merged' scan "$fixture_home" $((T0 + 5400))) || fail "positive merged observation failed"
      [ -z "$out" ] && [ ! -s "$fixture_home/state/.merge-stall" ] || fail "confirmed merge retained the stall"
      if [ "$route" != main ]; then
        if [ "$route" = local ]; then channel="$MAIN/state/mate.status"; else channel="$MATE/state/parent-replies.status"; fi
        [ "$(grep -c '^blocked' "$channel")" = 1 ] && [ "$(grep -c '^resolved' "$channel")" = 1 ] || fail "interrupted registration broke parent episode continuity"
      fi
    done
  done
  pass "missing and mismatched polls remain eligible until positive merge evidence in every home route"
}

test_publication_failure_then_terminal_recovery() {
  local route phase ending channel rc key out
  for route in local remote; do
    for phase in first existing; do
      for ending in resumed merged; do
        make_world "terminal-retry-$route-$phase-$ending"; bind_mate "$route"
        if [ "$route" = local ]; then channel="$MAIN/state/mate.status"; else channel="$MATE/state/parent-replies.status"; fi
        write_task "$MATE" child on "done [at=$T0]: ready PR"
        if [ "$phase" = existing ]; then scan "$MATE" $((T0 + 600)) >/dev/null || fail "existing episode fixture failed"; fi
        fail_ledger_commit
        rc=0
        scan "$MATE" $((T0 + 1800)) > "$WORLD/scan.out" 2> "$WORLD/scan.err" || rc=$?
        [ "$rc" = 1 ] || fail "post-publication ledger failure did not occur"
        [ -s "$MATE/state/.merge-stall" ] || fail "parent publication left no recoverable episode"
        key=$(parent_open "$channel" | cut -f1)
        [ -n "$key" ] || fail "failed commit did not leave a parent blocker"
        [ "$(awk -F '\t' '$1 == "child" { print $5 }' "$MATE/state/.merge-stall")" = 0 ] || fail "fixture unexpectedly committed escalation"
        mv "$WORLD/fakebin/mv" "$WORLD/mv.failed"
        if [ "$ending" = resumed ]; then
          printf 'working [at=%s]: resumed work\n' "$((T0 + 1900))" >> "$MATE/state/child.status"
        fi
        if [ "$phase:$ending" = first:resumed ]; then
          fail_ledger_commit
          rc=0
          scan "$MATE" $((T0 + 3600)) > "$WORLD/close.out" 2> "$WORLD/close.err" || rc=$?
          [ "$rc" = 1 ] || fail "resolution commit failure did not occur"
          [ -z "$(parent_open "$channel")" ] || fail "failed resolution commit left the parent key open"
          mv "$WORLD/fakebin/mv" "$WORLD/mv.close-failed"
        fi
        out=$(FM_TEST_PR_STATE='STATE: merged' scan "$MATE" $((T0 + 3601))) || fail "terminal recovery failed"
        [ -z "$out" ] && [ ! -s "$MATE/state/.merge-stall" ] || fail "terminal recovery retained a stale episode: $out"
        [ -z "$(parent_open "$channel")" ] || fail "terminal recovery left the parent blocker open"
        channel_lines "$channel" | grep -Fq "resolved [key=$key]:" || fail "terminal recovery closed a different parent key"
        [ "$(grep -c '^blocked' "$channel")" = 1 ] && [ "$(grep -c '^resolved' "$channel")" = 1 ] || fail "terminal recovery duplicated parent events"
      done
    done
  done
  pass "first and existing episodes close after failed publication even with an uncommitted escalation flag"
}

test_short_checksum_has_a_valid_parent_key() {
  local route channel out
  for route in local remote; do
    make_world "short-checksum-$route"; bind_mate "$route"
    if [ "$route" = local ]; then channel="$MAIN/state/mate.status"; else channel="$MATE/state/parent-replies.status"; fi
    # shellcheck disable=SC2016 # a literal script body
    printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "1234567 42\\n"\n' > "$WORLD/fakebin/cksum"
    chmod +x "$WORLD/fakebin/cksum"
    write_task "$MATE" child on "done [at=$T0]: PR ready"
    scan "$MATE" $((T0 + 1800)) >/dev/null || fail "short checksum escalation failed"
    [ "$(parent_open "$channel" | cut -f1)" = merge-stall-child-1234567 ] || fail "short checksum produced a key the parent classifier rejects"
    printf 'working [at=%s]: resumed\n' "$((T0 + 1900))" >> "$MATE/state/child.status"
    out=$(scan "$MATE" $((T0 + 2000))) || fail "short checksum resolution failed"
    [ -z "$out" ] && [ -z "$(parent_open "$channel")" ] || fail "short checksum resolution left a blocker open"
    channel_lines "$channel" | grep -Fq 'resolved [key=merge-stall-child-1234567]:' || fail "resolution did not reuse the valid short key"
  done
  pass "seven-digit cksum records produce parent keys that open and resolve on both routes"
}

test_uncertain_task_does_not_block_siblings() {
  local route kind id fixture_home channel out before after bad_url=https://github.com/owner/repo/pull/777
  for route in local remote; do
    for kind in unknown activity-failure missing-branch discovery-failure malformed invalid-url forge-failure unknown-late; do
      make_world "uncertain-$route-$kind"; bind_mate "$route"
      fixture_home=$MATE
      if [ "$route" = local ]; then channel="$MAIN/state/mate.status"; else channel="$MATE/state/parent-replies.status"; fi
      id=a
      [ "$kind" != unknown-late ] || id=z
      case "$kind" in
        missing-branch|discovery-failure|malformed)
          write_unregistered_task "$fixture_home" "$id" paused
          FM_TEST_BRANCH_URL="$bad_url" scan "$fixture_home" $((T0 + 1800)) >/dev/null || fail "uncertain discovery fixture failed"
          ;;
        *)
          URL="$bad_url" write_task "$fixture_home" "$id" on "done [at=$T0]: ready PR"
          scan "$fixture_home" $((T0 + 1800)) >/dev/null || fail "uncertain recorded fixture failed"
          ;;
      esac
      before=$(awk -F '\t' -v t="$id" '$1 == t' "$fixture_home/state/.merge-stall")
      write_task "$fixture_home" b on "done [at=$((T0 + 1))]: another ready PR"
      case "$kind" in
        unknown|unknown-late) out=$(FM_TEST_BAD_TASK="$id" FM_TEST_ACTIVITY='state: unknown · source: none · endpoint gone' scan "$fixture_home" $((T0 + 3600))) ;;
        activity-failure) out=$(FM_TEST_BAD_TASK="$id" FM_TEST_ACTIVITY_RC=2 scan "$fixture_home" $((T0 + 3600))) ;;
        missing-branch) printf 'branch=\n' >> "$fixture_home/state/$id.meta"; out=$(scan "$fixture_home" $((T0 + 3600))) ;;
        discovery-failure) out=$(FM_TEST_DISCOVERY_RC=124 scan "$fixture_home" $((T0 + 3600))) ;;
        malformed) out=$(FM_TEST_DISCOVERY_OUTPUT='not JSON' scan "$fixture_home" $((T0 + 3600))) ;;
        invalid-url) printf 'pr=not-a-PR\n' >> "$fixture_home/state/$id.meta"; out=$(scan "$fixture_home" $((T0 + 3600))) ;;
        forge-failure) out=$(FM_TEST_PR_RC=2 FM_TEST_BAD_PR="$bad_url" scan "$fixture_home" $((T0 + 3600))) ;;
      esac
      case "$out" in "b PR $URL unmerged 3599s"*'merge it now'*'evidence unavailable:'*"$id"*) ;; *) fail "$kind suppressed the readable sibling or its diagnostic: $out" ;; esac
      after=$(awk -F '\t' -v t="$id" '$1 == t' "$fixture_home/state/.merge-stall")
      [ -n "$before" ] && [ "$before" = "$after" ] || fail "$kind changed the uncertain episode"
      [ "$(parent_open "$channel" | awk 'END { print NR }')" = 2 ] || fail "$kind did not retain the old blocker and escalate the readable sibling"
      [ "$(grep -c '^resolved' "$channel")" = 0 ] || fail "$kind falsely resolved uncertain evidence"
    done
  done
  pass "unreadable tasks retain their episodes while earlier and later readable siblings still escalate"
}

assert_reads_stopped() {
  local pid i=0 live
  [ -s "$WORLD/read.pids" ] || fail "hanging read fixture never started"
  while [ "$i" -lt 100 ]; do
    live=0
    while IFS= read -r pid; do
      kill -0 "$pid" 2>/dev/null && live=1
    done < "$WORLD/read.pids"
    [ "$live" = 1 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  fail "bounded read left a live process: $(cat "$WORLD/read.pids")"
}

test_read_deadlines_and_watcher_cancellation() {
  local kind now out pid i real_mktemp
  for kind in crew hold discovery forge; do
    make_world "read-deadline-$kind"
    now=$(date +%s)
    if [ "$kind" = discovery ]; then
      write_unregistered_task "$MAIN" a paused
    else
      write_task "$MAIN" a on "done [at=$((now - 700))]: PR ready"
    fi
    if [ "$kind" = crew ]; then write_task "$MAIN" b on "done [at=$((now - 701))]: sibling PR ready"; fi
    FM_TEST_HANG_READ="$kind" FM_TEST_BAD_TASK=a FM_TEST_BAD_PR="$URL" FM_TEST_READ_PIDS="$WORLD/read.pids" FM_TEST_READ_TIMEOUT=1 FM_TEST_CHECK_TIMEOUT=8 run_watcher "$MAIN"
    out=$(cat "$MAIN/state/.wake-queue")
    case "$kind" in
      crew) case "$out" in *"b PR $URL unmerged"*'current activity read failed for a (rc=124)'*) ;; *) fail "crew read timeout blocked its sibling: $out" ;; esac ;;
      hold) case "$out" in *'captain-hold read failed (rc=124)'*) ;; *) fail "hold read was not bounded: $out" ;; esac ;;
      discovery) case "$out" in *'PR discovery failed for a (rc=124)'*) ;; *) fail "discovery was not bounded: $out" ;; esac ;;
      forge) case "$out" in *'forge state unreadable for a'*) ;; *) fail "forge state read was not bounded: $out" ;; esac ;;
    esac
    assert_reads_stopped
  done
  make_world scan-deadline
  real_mktemp=$(command -v mktemp)
  # shellcheck disable=SC2016 # a literal script body
  printf '#!/usr/bin/env bash\ncase "$1" in */.merge-stall.??????) exec "${0%%/*}/hang-read" ;; esac\nexec "%s" "$@"\n' "$real_mktemp" > "$WORLD/fakebin/mktemp"
  chmod +x "$WORLD/fakebin/mktemp"
  FM_TEST_READ_PIDS="$WORLD/read.pids" FM_TEST_READ_TIMEOUT=1 FM_TEST_CHECK_TIMEOUT=1 run_watcher "$MAIN"
  grep -Fq 'scan deadline exceeded' "$MAIN/state/.wake-queue" || fail "whole scan did not surface its deadline"
  assert_reads_stopped

  make_world scan-cancellation
  now=$(date +%s)
  write_task "$MAIN" a on "done [at=$((now - 700))]: PR ready"
  FM_TEST_HANG_READ=crew FM_TEST_BAD_TASK=a FM_TEST_READ_PIDS="$WORLD/read.pids" FM_TEST_READ_TIMEOUT=30 start_watcher "$MAIN"
  pid=$WATCH_PID
  i=0
  while [ ! -s "$WORLD/read.pids" ] && [ "$i" -lt 200 ]; do sleep 0.02; i=$((i + 1)); done
  [ -s "$WORLD/read.pids" ] || { reap "$pid"; fail "cancellation read did not start"; }
  kill -TERM "$pid"
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.02; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then reap "$pid"; fail "watcher ignored cancellation while scanning"; fi
  wait "$pid" 2>/dev/null || true
  assert_reads_stopped
  [ ! -s "$MAIN/state/.watch.lock/pid" ] || fail "watcher retained its lock after scanner cancellation"
  pass "task reads and the whole scan have deadlines and watcher cancellation stops read descendants"
}

test_sweep_budget_reaches_every_registered_task() {
  local route fixture_home n now task out channel
  for route in main local remote; do
    make_world "sweep-budget-$route"
    fixture_home=$MAIN
    if [ "$route" != main ]; then bind_mate "$route"; fixture_home=$MATE; fi
    now=$(date +%s)
    for n in 1 2 3 4 5 6; do
      write_task "$fixture_home" "slow-$n" on "done [at=$((now - 2000))]: ready PR"
    done
    write_task "$fixture_home" z-ready on "done [at=$((now - 2000))]: ready PR"
    FM_TEST_SLOW_CREW=1 FM_TEST_READ_TIMEOUT=1 FM_TEST_CHECK_TIMEOUT=1 FM_TEST_WATCH_LIMIT=400 run_watcher "$fixture_home"
    out=$(cat "$fixture_home/state/.wake-queue")
    case "$out" in *"z-ready PR $URL unmerged"*'merge it now'*'current activity read failed for slow-1 (rc=124)'*) ;; *) fail "earlier timed-out tasks starved z-ready: $out" ;; esac
    for task in slow-1 slow-2 slow-3 slow-4 slow-5 slow-6 z-ready; do
      [ "$(grep -Fxc "$task" "$WORLD/activity.log")" = 1 ] || fail "sweep did not reach $task exactly once"
    done
    case "$out" in *'scan failed'*|*'scan deadline exceeded'*) fail "whole-sweep budget expired before finishing its bounded tasks: $out" ;; esac
    if [ "$route" != main ]; then
      if [ "$route" = local ]; then channel="$MAIN/state/mate.status"; else channel="$MATE/state/parent-replies.status"; fi
      parent_open "$channel" | grep -Fq 'merge-stall-z-ready-' || fail "later ready task did not escalate after earlier read timeouts"
    fi
  done
  pass "every registered task is reached after six earlier read timeouts in every home route"
}

test_terminal_state_retires_held_stalls() {
  local route poll terminal channel out key before hold_reads
  for route in local remote; do
    for poll in present missing mismatched; do
      for terminal in closed merged; do
        make_world "held-terminal-$route-$poll-$terminal"; bind_mate "$route"
        if [ "$route" = local ]; then channel="$MAIN/state/mate.status"; else channel="$MATE/state/parent-replies.status"; fi
        write_task "$MATE" child on "paused [at=$T0]: ready PR awaits home"
        scan "$MATE" $((T0 + 1800)) >/dev/null || fail "held stall fixture failed"
        key=$(parent_open "$channel" | cut -f1)
        [ -n "$key" ] || fail "held stall fixture did not escalate"
        case "$poll" in
          missing) mv "$MATE/state/child.pr-poll" "$WORLD/poll.saved" ;;
          mismatched) printf 'github\nhttps://github.com/owner/repo/pull/999\ngithub.com\nowner/repo\n999\n' > "$MATE/state/child.pr-poll" ;;
        esac
        out=$(FM_TEST_HELD=child scan "$MATE" $((T0 + 3600))) || fail "held open PR scan failed"
        [ -z "$out" ] && [ -n "$(parent_open "$channel")" ] || fail "holding an open PR either authorized merging or discarded its episode: $out"
        before=$(cat "$MATE/state/.merge-stall")
        out=$(FM_TEST_HELD=child FM_TEST_PR_RC=2 scan "$MATE" $((T0 + 3601))) || fail "unreadable held PR scan failed"
        case "$out" in *'evidence unavailable: forge state unreadable for child'*) ;; *) fail "held PR evidence failure stayed silent: $out" ;; esac
        [ "$(cat "$MATE/state/.merge-stall")" = "$before" ] || fail "unknown terminal evidence discarded the held episode"
        hold_reads=$(wc -l < "$WORLD/hold.log" | tr -d ' ')
        out=$(FM_TEST_HELD=child FM_TEST_PR_STATE="STATE: $terminal" scan "$MATE" $((T0 + 3602))) || fail "held terminal PR scan failed"
        [ -z "$out" ] && [ ! -s "$MATE/state/.merge-stall" ] || fail "confirmed $terminal PR retained its held stall: $out"
        [ -z "$(parent_open "$channel")" ] || fail "confirmed $terminal PR retained its upstream blocker with $poll poll"
        channel_lines "$channel" | grep -Fq "resolved [key=$key]:" || fail "terminal state closed the wrong held episode"
        [ "$(wc -l < "$WORLD/hold.log" | tr -d ' ')" = "$hold_reads" ] || fail "terminal state retirement still consulted captain-hold suppression"
        [ "$(grep -c '^resolved' "$channel")" = 1 ] || fail "held terminal episode was resolved more than once"
      done
    done
  done
  pass "closed and merged PRs retire held escalations across both routes and all poll states"
}

# A task whose recorded PR merged or closed opens a second PR and waits again:
# the recorded identity retires and the task's branch is searched for the next.
test_later_pr_after_terminal_recorded_pr() {
  local next=https://github.com/owner/repo/pull/629 end out
  for end in merged closed; do
    make_world "later-pr-$end"
    write_unregistered_task "$MAIN" t paused
    printf 'pr=%s\n' "$URL" >> "$MAIN/state/t.meta"
    printf 'github\n%s\ngithub.com\nowner/repo\n628\n' "$URL" > "$MAIN/state/t.pr-poll"
    if [ "$end" = merged ]; then
      observe_merge "$MAIN" t || fail "could not record the first PR merge"
      out=$(FM_TEST_BRANCH_URL="$next" scan "$MAIN" $((T0 + 600))) || fail "later PR scan failed after $end"
    else
      out=$(FM_TEST_CLOSED_URL="$URL" FM_TEST_BRANCH_URL="$next" scan "$MAIN" $((T0 + 600))) || fail "later PR scan failed after $end"
    fi
    case "$out" in "t PR $next unmerged 600s"*"merge it now with bin/fm-pr-merge.sh t $next"*) ;; *) fail "the PR after a $end recorded PR stayed silent: $out" ;; esac
    case "$out" in *"$URL"*) fail "the $end recorded PR still received a merge instruction: $out" ;; esac
  done
  pass "a later PR from the same task wakes the home once its recorded PR merged or closed"
}

# Discovery acts only on a PR whose head is this task's branch on its own fork.
test_discovered_pr_identity_is_bound() {
  local case_name out
  for case_name in other-owner other-repo other-branch duplicate non-github-remote; do
    make_world "bind-$case_name"
    if [ "$case_name" = non-github-remote ]; then
      FM_TEST_PUSH_REMOTE=https://gitlab.example/owner/repo.git write_unregistered_task "$MAIN" t paused
    else
      write_unregistered_task "$MAIN" t paused
    fi
    case "$case_name" in
      other-owner) out=$(FM_TEST_BRANCH_URL="$URL" FM_TEST_BRANCH_OWNER=someone-else scan "$MAIN" $((T0 + 600))) ;;
      other-repo) out=$(FM_TEST_BRANCH_URL="$URL" FM_TEST_BRANCH_REPO=other scan "$MAIN" $((T0 + 600))) ;;
      other-branch) out=$(FM_TEST_BRANCH_URL="$URL" FM_TEST_BRANCH_REF=fm/elsewhere scan "$MAIN" $((T0 + 600))) ;;
      duplicate) out=$(FM_TEST_BRANCH_URL="$URL" FM_TEST_BRANCH_DUP=1 scan "$MAIN" $((T0 + 600))) ;;
      non-github-remote) out=$(FM_TEST_BRANCH_URL="$URL" scan "$MAIN" $((T0 + 600))) ;;
    esac || fail "$case_name binding scan failed"
    case "$out" in *"merge it now"*|*"bin/fm-pr-merge.sh"*) fail "an unbound $case_name PR received a merge instruction: $out" ;; esac
    case "$out" in *"evidence unavailable: PR discovery"*"t"*) ;; *) fail "an unbound $case_name PR was not reported as uncertain: $out" ;; esac
  done
  make_world bind-case-insensitive
  write_unregistered_task "$MAIN" t paused
  out=$(FM_TEST_BRANCH_URL="$URL" FM_TEST_BRANCH_OWNER=Owner scan "$MAIN" $((T0 + 600))) || fail "case-insensitive owner scan failed"
  case "$out" in "t PR $URL unmerged 600s"*"merge it now"*) ;; *) fail "the task's own PR with a differently cased owner was rejected: $out" ;; esac
  pass "a discovered PR wakes the home only when bound to the task's own fork and branch"
}

test_retired_pr_is_not_restored_by_uncertainty() {
  local route evidence failure channel key out next=https://github.com/owner/repo/pull/629
  for route in local remote; do
    for evidence in marker merged closed; do
      for failure in activity-failure activity-unknown missing-worktree remote-identity timeout malformed ambiguous invalid-url replacement-forge; do
        case "$evidence:$failure" in merged:activity-*|closed:activity-*) continue ;; esac
        (
          make_world "retired-$route-$evidence-$failure"; bind_mate "$route"
          if [ "$route" = local ]; then channel="$MAIN/state/mate.status"; else channel="$MATE/state/parent-replies.status"; fi
          write_unregistered_task "$MATE" child paused
          printf 'pr=%s\n' "$URL" >> "$MATE/state/child.meta"
          scan "$MATE" $((T0 + 1800)) >/dev/null || fail "retired PR fixture failed"
          key=$(parent_open "$channel" | cut -f1)
          [ -n "$key" ] || fail "retired PR fixture did not escalate"
          case "$evidence" in
            marker) observe_merge "$MATE" child || fail "could not record the first PR merge" ;;
            merged) export FM_TEST_PR_STATE='STATE: merged' ;;
            closed) export FM_TEST_CLOSED_URL="$URL" ;;
          esac
          case "$failure" in
            activity-failure) export FM_TEST_BAD_TASK=child FM_TEST_ACTIVITY_RC=2 ;;
            activity-unknown) export FM_TEST_BAD_TASK=child FM_TEST_ACTIVITY='state: unknown' ;;
            missing-worktree) printf 'worktree=%s/missing\n' "$WORLD" >> "$MATE/state/child.meta" ;;
            remote-identity) git -C "$MATE/copy" remote set-url origin https://gitlab.example/owner/repo.git || fail "could not change the push remote" ;;
            timeout) export FM_TEST_DISCOVERY_RC=124 ;;
            malformed) export FM_TEST_DISCOVERY_OUTPUT='not JSON' ;;
            ambiguous) export FM_TEST_BRANCH_URL="$next" FM_TEST_BRANCH_DUP=1 ;;
            invalid-url) export FM_TEST_BRANCH_URL='not-a-PR' ;;
            replacement-forge) export FM_TEST_BRANCH_URL="$next" FM_TEST_PR_RC=2 FM_TEST_BAD_PR="$next" ;;
          esac
          out=$(scan "$MATE" $((T0 + 3600))) || fail "retired PR recovery scan failed"
          case "$out" in *'evidence unavailable:'*) ;; *) fail "replacement uncertainty lost its diagnostic: $out" ;; esac
          case "$out" in *'merge it now'*) fail "retired or uncertain PR received a merge instruction: $out" ;; esac
          [ ! -s "$MATE/state/.merge-stall" ] || fail "uncertainty restored a retired candidate: $(cat "$MATE/state/.merge-stall")"
          [ -z "$(parent_open "$channel")" ] || fail "uncertainty retained the retired PR's parent blocker"
          channel_lines "$channel" | grep -Fq "resolved [key=$key]:" || fail "retirement resolved a different parent blocker"
          [ "$(grep -c '^blocked' "$channel")" = 1 ] && [ "$(grep -c '^resolved' "$channel")" = 1 ] || fail "retirement duplicated parent events"
        ) || fail "$route $evidence $failure restored a retired PR"
      done
    done
  done
  pass "confirmed terminal PRs resolve both parent routes despite activity, discovery, or replacement forge uncertainty"
}

write_noop_no_mistakes() {
  printf '#!/usr/bin/env bash\nexit 0\n' > "$WORLD/fakebin/no-mistakes"
  chmod +x "$WORLD/fakebin/no-mistakes"
}

real_crew_state() {  # <home> <task>
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_CREW_STATE_NO_FORGE=1 \
    bash "$ROOT/bin/fm-crew-state.sh" "$2"
}

test_gone_worker_is_skipped_quietly() {
  local state out route channel key before after unknown_line idx=0
  # 1. Parked yolo ship lane whose worktree and window are gone (real crew-state):
  # no wake, no evidence-unavailable diagnostic, no forge read, and siblings still wake cleanly.
  make_world gone-worktree
  write_noop_no_mistakes
  cat > "$WORLD/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'other-window\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$WORLD/fakebin/tmux"
  write_task "$MAIN" gone-wt on "paused [at=$T0]: waiting on home"
  printf 'worktree=%s/missing-wt\nbranch=fm/gone-wt\nwindow=fm:fm-gone-wt\nbackend=tmux\n' "$WORLD" >> "$MAIN/state/gone-wt.meta"
  state=$(real_crew_state "$MAIN" gone-wt)
  [ "$state" = 'state: unknown · source: none · worktree gone (torn down?)' ] || fail "unexpected worktree-gone crew-state output: $state"
  out=$(FM_TEST_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" scan "$MAIN" $((T0 + 3600))) || fail "gone-worktree scan failed"
  [ -z "$out" ] || fail "a gone worktree produced a wake or diagnostic: $out"
  [ ! -s "$MAIN/state/.merge-stall" ] || fail "a gone worktree wrote a stall row: $(cat "$MAIN/state/.merge-stall")"
  [ ! -s "$WORLD/forge.log" ] || fail "a gone worktree read the forge"
  # A readable due sibling alongside the gone worktree wakes without an evidence-unavailable suffix.
  mkdir -p "$MAIN/live-wt"
  git -C "$MAIN/live-wt" init -q
  write_task "$MAIN" live on "paused [at=$T0]: waiting on home"
  printf 'worktree=%s/live-wt\nbranch=fm/live\nwindow=fm:fm-live\nbackend=tmux\nharness=claude\n' "$MAIN" >> "$MAIN/state/live.meta"
  cat > "$WORLD/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'fm-live\n' ;;
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$WORLD/fakebin/tmux"
  printf 'g1\n' > "$MAIN/state/live.busy-gen"
  printf 'v1 gen=g1 seq=1 state=idle source=claude-hook event=Stop ts=%s\n' "$T0" > "$MAIN/state/live.busy-state"
  state=$(real_crew_state "$MAIN" live)
  [ "$state" = 'state: paused · source: status-log · waiting on home' ] || fail "unexpected live-sibling crew-state output: $state"
  out=$(FM_TEST_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" scan "$MAIN" $((T0 + 600))) || fail "gone-with-sibling scan failed"
  case "$out" in
    *"evidence unavailable:"*) fail "a gone sibling attached a diagnostic to a readable wake: $out" ;;
    "live PR $URL unmerged 600s"*'merge it now'*) ;;
    *) fail "readable sibling did not wake alongside a gone lane: $out" ;;
  esac

  # 2. Existing escalated stall whose worktree later disappears resolves cleanly on both parent routes.
  for route in local remote; do
    make_world "gone-resolves-$route"; bind_mate "$route"
    if [ "$route" = local ]; then channel="$MAIN/state/mate.status"; else channel="$MATE/state/parent-replies.status"; fi
    write_task "$MATE" child on "paused [at=$T0]: waiting on home"
    scan "$MATE" $((T0 + 1800)) >/dev/null || fail "prior episode fixture failed"
    key=$(parent_open "$channel" | cut -f1)
    [ -n "$key" ] || fail "prior episode did not escalate on $route route"
    printf 'worktree=%s/missing-wt\nbranch=fm/child\nwindow=fm:fm-child\nbackend=tmux\n' "$WORLD" >> "$MATE/state/child.meta"
    out=$(FM_TEST_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" scan "$MATE" $((T0 + 3600))) || fail "gone-worker resolution scan failed"
    [ -z "$out" ] || fail "gone worker resolution raised output on $route route: $out"
    [ ! -s "$MATE/state/.merge-stall" ] || fail "gone worker retained its stall row on $route route"
    [ -z "$(parent_open "$channel")" ] || fail "gone worker left its parent blocker open on $route route"
    channel_lines "$channel" | grep -Fq "resolved [key=$key]:" || fail "gone worker resolved the wrong parent key on $route route"
  done

  # 3. Worktree still on disk, no active run, backend target gone (missing tmux window and dead herdr agent):
  # both report 'backend target gone: ...' from real crew-state and skip quietly.
  make_world gone-backend-target
  mkdir -p "$MAIN/wt"
  git -C "$MAIN/wt" init -q
  write_noop_no_mistakes
  cat > "$WORLD/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'other-window\n' ;;
  *) exit 1 ;;
esac
SH
  cat > "$WORLD/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'status --json') printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n' ;;
  'pane read') exit 1 ;;
  'pane get') printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  'agent get') printf '{"error":{"code":"agent_not_found","message":"no agent in pane"}}\n' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$WORLD/fakebin/tmux" "$WORLD/fakebin/herdr"
  write_task "$MAIN" gone-win on "paused [at=$T0]: waiting on home"
  printf 'worktree=%s/wt\nbranch=fm/gone-win\nwindow=fm:fm-gone-win\nbackend=tmux\n' "$MAIN" >> "$MAIN/state/gone-win.meta"
  state=$(real_crew_state "$MAIN" gone-win)
  [ "$state" = 'state: unknown · source: none · backend target gone: fm:fm-gone-win' ] || fail "unexpected missing-window crew-state output: $state"
  write_task "$MAIN" gone-husk on "done [at=$T0]: PR $URL checks green"
  printf 'worktree=%s/wt\nbranch=fm/gone-husk\nwindow=default:w1:p2\nbackend=herdr\nharness=claude\n' "$MAIN" >> "$MAIN/state/gone-husk.meta"
  state=$(real_crew_state "$MAIN" gone-husk)
  [ "$state" = 'state: unknown · source: none · backend target gone: default:w1:p2 (agent gone, pane shell remains)' ] || fail "unexpected husk-pane crew-state output: $state"
  out=$(FM_TEST_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" scan "$MAIN" $((T0 + 3600))) || fail "gone-backend-target scan failed"
  [ -z "$out" ] || fail "gone backend targets produced a wake or diagnostic: $out"
  [ ! -s "$MAIN/state/.merge-stall" ] || fail "gone backend targets wrote stall rows"
  [ ! -s "$WORLD/forge.log" ] || fail "gone backend targets read the forge"

  # 4. Genuinely unreadable or other unknown activity MUST still raise the diagnostic and preserve prior episodes:
  # (a) real crew-state with unreachable tmux and missing backend target.
  cat > "$WORLD/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'no current client\n' >&2
exit 1
SH
  chmod +x "$WORLD/fakebin/tmux"
  rm -f "$MAIN/state/gone-husk.meta" "$MAIN/state/gone-husk.status" "$MAIN/state/gone-husk.pr-poll"
  state=$(real_crew_state "$MAIN" gone-win)
  case "$state" in 'state: unknown · source: none · backend unreachable ('*) ;; *) fail "unexpected unreachable-backend crew-state output: $state" ;; esac
  out=$(FM_TEST_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" scan "$MAIN" $((T0 + 3600))) || fail "unreachable-backend scan failed"
  case "$out" in *'evidence unavailable: current activity unreadable for gone-win: state: unknown · source: none · backend unreachable ('*) ;; *) fail "unreachable backend stopped raising diagnostic: $out" ;; esac
  case "$out" in *'merge it now'*) fail "unreachable backend authorized a merge: $out" ;; esac

  make_world no-backend-target
  mkdir -p "$MAIN/wt"
  git -C "$MAIN/wt" init -q
  write_noop_no_mistakes
  write_task "$MAIN" no-target on "paused [at=$T0]: waiting on home"
  printf 'worktree=%s/wt\nbranch=fm/no-target\nbackend=tmux\n' "$MAIN" >> "$MAIN/state/no-target.meta"
  state=$(real_crew_state "$MAIN" no-target)
  [ "$state" = 'state: unknown · source: none · no backend target recorded' ] || fail "unexpected no-target crew-state output: $state"
  out=$(FM_TEST_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" scan "$MAIN" $((T0 + 3600))) || fail "no-target scan failed"
  case "$out" in *'evidence unavailable: current activity unreadable for no-target: state: unknown · source: none · no backend target recorded'*) ;; *) fail "missing backend target stopped raising diagnostic: $out" ;; esac

  # (b) other non-gone unknown crew-state outputs keep raising the diagnostic and preserving episodes.
  for unknown_line in \
    'state: unknown · source: run-step · run inventory unavailable; run id: 01RUN' \
    'state: unknown · source: pane · harness state unavailable (unknown no-record)' \
    'state: unknown · source: none · no current-state source available' \
    'state: unknown · source: none · worktree gone (torn downX)' \
    'state: unknown · source: none · backend target gone: ' \
    $'state: unknown · source: none · worktree gone (torn down?)\nunexpected stderr' \
    $'state: unknown · source: none · backend target gone: fm:fm-t\nunexpected stderr'; do
    idx=$((idx + 1))
    make_world "unknown-other-$idx"
    write_task "$MAIN" t on "paused [at=$T0]: waiting on home"
    scan "$MAIN" $((T0 + 600)) >/dev/null || fail "prior unknown-other episode failed"
    before=$(cat "$MAIN/state/.merge-stall")
    out=$(FM_TEST_BAD_TASK=t FM_TEST_ACTIVITY="$unknown_line" scan "$MAIN" $((T0 + 3600))) || fail "unknown-other scan failed"
    case "$out" in *'evidence unavailable: current activity unreadable for t:'*) ;; *) fail "non-gone unknown stopped raising diagnostic ($unknown_line): $out" ;; esac
    case "$out" in *'merge it now'*) fail "non-gone unknown authorized a merge ($unknown_line): $out" ;; esac
    after=$(cat "$MAIN/state/.merge-stall")
    [ -n "$before" ] && [ "$before" = "$after" ] || fail "non-gone unknown dropped prior episode ($unknown_line)"
  done
  pass "gone workers are skipped quietly while unreadable or other unknown activity still raises a diagnostic"
}

test_retired_pr_is_not_restored_by_uncertainty
test_replay_paused_worker_red_pr
test_merged_or_released_ends_stall
test_posture_and_holds_respected
test_secondmate_routes
test_unregistered_pr
test_due_stalls_make_progress
test_replaced_waiting_episode
test_hold_failure_diagnostic
test_watcher_poll_wakes_home
test_chatty_check_cannot_starve_scan
test_scanner_failures_wake_home
test_discovery_failure_preserves_episode
test_drafts_are_not_candidates
test_active_validation_is_not_a_merge_wait
test_escalation_retry_is_idempotent
test_interrupted_registration_is_detected
test_publication_failure_then_terminal_recovery
test_short_checksum_has_a_valid_parent_key
test_uncertain_task_does_not_block_siblings
test_read_deadlines_and_watcher_cancellation
test_sweep_budget_reaches_every_registered_task
test_terminal_state_retires_held_stalls
test_later_pr_after_terminal_recorded_pr
test_discovered_pr_identity_is_bound
test_gone_worker_is_skipped_quietly
