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
if [ "$1" = "${FM_TEST_CLOSED_URL:-}" ]; then
  printf 'STATE: closed\n'
else
  [ -z "${FM_TEST_PR_STATE:-}" ] || printf '%s\n' "$FM_TEST_PR_STATE"
fi
SH
  cat > "$WORLD/fakebin/captain-hold" <<'SH'
#!/usr/bin/env bash
[ "${FM_TEST_HELD:-}" = "$2" ] && exit 0
[ -z "${FM_TEST_HOLD_ERROR:-}" ] || printf '%s\n' "$FM_TEST_HOLD_ERROR" >&2
exit "${FM_TEST_HOLD_RC:-1}"
SH
  cat > "$WORLD/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "${FM_TEST_LOOKUP_LOG:?}"
case "$*" in
  'pr list --state open --head fm/unregistered --limit 1 --fields url') ;;
  *) exit 2 ;;
esac
printf 'pull_requests[1]{url}:\n  "%s"\n' "${FM_TEST_BRANCH_URL:-}"
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
    FM_TEST_FORGE_LOG="$WORLD/forge.log" bash "$SCAN" scan --now "$2"
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
  rm "$MAIN/state/t.pr-poll"
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
  key=$(channel_lines "$channel" | sed -n 's/^blocked \[key=\(merge-stall-child-[0-9]*\)\]: merge stall child: PR .* unmerged 1800s while its worker waits on this home \[forge: .*\]$/\1/p')
  [ -n "$key" ] || fail "$route mate did not publish the stall on its parent channel: $(cat "$channel" 2>/dev/null)"
  scan "$MATE" $((T0 + 3600)) >/dev/null
  [ "$(grep -c "^blocked" "$channel")" = 1 ] || fail "$route mate re-published one stall"
  rm "$MATE/state/child.pr-poll"
  out=$(scan "$MATE" $((T0 + 3700)))
  [ -z "$out" ] || fail "$route mate woke after the merge was observed: $out"
  channel_lines "$channel" | grep -Fxq "resolved [key=$key]: merge stall child: PR $URL is merged, closed, or its worker waiting episode ended" \
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
  printf 'kind=ship\nmode=direct-PR\nyolo=on\nworktree=%s\nbranch=fm/unregistered\n' "$home/copy" > "$home/state/$task.meta"
  printf 'working [at=%s]: Ready fix PR %s\n%s [at=%s]: waiting on home\n' "$T0" "$URL" "$verb" "$T0" > "$home/state/$task.status"
}

test_unregistered_pr() {
  local route home verb out
  for route in main local remote; do
    for verb in paused done; do
      make_world "unregistered-$route-$verb"
      home=$MAIN
      if [ "$route" != main ]; then bind_mate "$route"; home=$MATE; fi
      write_unregistered_task "$home" t "$verb"
      out=$(FM_TEST_BRANCH_URL="$URL" scan "$home" $((T0 + 600))) || fail "unregistered PR scan failed"
      case "$out" in "t PR $URL unmerged 600s"*"merge it now with bin/fm-pr-merge.sh t $URL"*) ;; *) fail "unregistered $route $verb PR was missed: $out" ;; esac
      [ "$(wc -l < "$WORLD/lookup.log" | tr -d ' ')" = 1 ] || fail "unregistered PR needed more than one forge lookup"
      grep -Fxq "$home/copy|pr list --state open --head fm/unregistered --limit 1 --fields url" "$WORLD/lookup.log" || fail "lookup did not address the task branch in its repository"
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
    for verb in paused done; do
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

run_watcher() {
  local home=$1 pid i=0
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_MERGE_STALL_PR_STATE_BIN="$WORLD/fakebin/pr-state" \
    FM_MERGE_STALL_CAPTAIN_HOLD_BIN="$WORLD/fakebin/captain-hold" FM_TEST_FORGE_LOG="$WORLD/forge.log" \
    FM_TEST_LOOKUP_LOG="$WORLD/lookup.log" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=300 FM_HEARTBEAT=999999 bash "$WATCH" > "$WORLD/watch.out" 2>&1 &
  pid=$!
  while [ "$i" -lt 100 ]; do
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
        printf '#!/usr/bin/env bash\ncase "$1" in */.merge-stall) echo "ledger read refused" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' "$real_cat" > "$WORLD/fakebin/cat"
        chmod +x "$WORLD/fakebin/cat"
        ;;
      ledger-temp)
        printf '#!/usr/bin/env bash\ncase "$1" in */.merge-stall.??????) echo "ledger storage unavailable" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' "$real_mktemp" > "$WORLD/fakebin/mktemp"
        chmod +x "$WORLD/fakebin/mktemp"
        ;;
      ledger-write)
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
      parent-*|resolved-*) grep -Fq "parent channel append failed (rc=4):" "$home/state/.wake-queue" && grep -Fq "PR $URL" "$home/state/.wake-queue" || fail "$kind failure omitted the detected stall" ;;
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
