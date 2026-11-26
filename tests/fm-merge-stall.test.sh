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
[ -z "${FM_TEST_PR_STATE:-}" ] || printf '%s\n' "$FM_TEST_PR_STATE"
SH
  cat > "$WORLD/fakebin/captain-hold" <<'SH'
#!/usr/bin/env bash
[ "${FM_TEST_HELD:-}" = "$2" ] && exit 0
exit "${FM_TEST_HOLD_RC:-1}"
SH
  chmod +x "$WORLD/fakebin"/*
  : > "$WORLD/forge.log"
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
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" \
    FM_MERGE_STALL_PR_STATE_BIN="$WORLD/fakebin/pr-state" \
    FM_MERGE_STALL_CAPTAIN_HOLD_BIN="$WORLD/fakebin/captain-hold" \
    FM_TEST_FORGE_LOG="$WORLD/forge.log" "$SCAN" scan --now "$2"
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
  [ -z "$out" ] || fail "an unreadable captain-hold answer still let the home merge: $out"
  make_world captain-held
  write_task "$MAIN" t on "captain-held [at=$T0]: captain reviews the PR"
  out=$(scan "$MAIN" $((T0 + 3600)))
  [ -z "$out" ] || fail "a captain-held transfer was told to merge: $out"
  pass "a home that asks first, a task held for the captain, and an unreadable hold are left alone"
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
  channel_lines "$channel" | grep -Fxq "resolved [key=$key]: merge stall child: PR $URL is merged or its worker no longer waits on this home" \
    || fail "$route mate did not resolve the stall upstream: $(cat "$channel")"
}

test_secondmate_routes() {
  check_mate_route local
  check_mate_route remote
  pass "local and remote secondmate homes merge-wake themselves and escalate once through the parent channel"
}

# The real watcher poll runs the scan on its check sweep and queues the wake.
test_watcher_poll_wakes_home() {
  local pid i out now
  make_world watcher
  now=$(date +%s)
  write_task "$MAIN" t on "done [at=$((now - 700))]: PR $URL checks green"
  out="$WORLD/watch.out"
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" \
    FM_DATA_OVERRIDE="$MAIN/data" FM_CONFIG_OVERRIDE="$MAIN/config" \
    FM_MERGE_STALL_PR_STATE_BIN="$WORLD/fakebin/pr-state" \
    FM_MERGE_STALL_CAPTAIN_HOLD_BIN="$WORLD/fakebin/captain-hold" FM_TEST_FORGE_LOG="$WORLD/forge.log" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    kill -0 "$pid" 2>/dev/null || break
    grep -q 'check: merge stall:' "$MAIN/state/.wake-queue" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  reap "$pid"
  grep -Fq "check: merge stall: t PR $URL unmerged" "$MAIN/state/.wake-queue" \
    || fail "the watcher poll did not queue the merge-stall wake: $(cat "$out")"
  pass "the real watcher poll queues the merge-stall wake"
}

test_replay_paused_worker_red_pr
test_merged_or_released_ends_stall
test_posture_and_holds_respected
test_secondmate_routes
test_watcher_poll_wakes_home
