#!/usr/bin/env bash
# tests/fm-watch-poll-batch.test.sh - the watcher's per-poll pane read against
# a REAL tmux server on a private socket: every recorded tmux window of one
# poll is captured through a single tmux client call, a missing window costs
# only a resumed call for the windows after it and then sits out up to four polls,
# the stale classification those captures feed is unchanged, and an idle
# poll backs its wait off until a worker changes; a settled escalated inbox
# keeps that backoff, as does a busy pane past its turn bound under a declared wait, and the inactive-outcome scan runs only when its inputs change or once a minute.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
TMP_ROOT=$(fm_test_tmproot fm-watch-poll-batch)
SOCKET="$TMP_ROOT/tmux.sock"
cleanup_tmux() { "$REAL_TMUX" -S "$SOCKET" kill-server >/dev/null 2>&1 || true; }
trap cleanup_tmux EXIT
"$REAL_TMUX" -f /dev/null -S "$SOCKET" new-session -d -s pb -x 120 -y 30 'sleep 100000' \
  || fail "could not start the private tmux server"

# make_case's fake tmux is replaced by a shim onto the private server that
# logs each client call, one line per call.
real_tmux_case() {  # <name> -> case dir
  local dir
  dir=$(make_case "$1")
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/tmux-calls.log"
exec "$REAL_TMUX" -S "$SOCKET" "\$@"
SH
  chmod +x "$dir/fakebin/tmux"
  printf '%s\n' "$dir"
}

add_window() {  # <state> <id> <command>
  "$REAL_TMUX" -S "$SOCKET" new-window -d -t pb: -n "fm-$2" "$3" || fail "could not open window fm-$2"
  record_window "$1" "$2"
}

record_window() {  # <state> <id>
  printf 'window=pb:fm-%s\nharness=claude\nkind=ship\n' "$2" > "$1/$2.meta"
  printf 'done [at=%s]: finished\n' "$(date +%s)" > "$1/$2.status"
}

static_pane() { printf "printf 'idle %s\\\\n'; sleep 100000" "$1"; }
changing_pane() { printf "while :; do date +%%s%%N; sleep 0.3; done"; }

# Wait for the watcher to exit on its own, failing the case past <ticks>.
wait_wake() {  # <pid> <ticks>
  wait_for_exit "$1" "$2"
  [ "$?" -ne 124 ] || { reap "$1"; fail "the watcher never woke"; }
}

# Prime every recorded status as already reported, so only the stale scan wakes.
prime_signals() {  # <state> <dir>
  local pid
  watch_bg "$1" "$2/fakebin" "$2/prime.out" env FM_POLL_IDLE_MAX=0
  pid=$!
  wait_for_exit "$pid" 600 || true
  reap "$pid"
  ack_stopped_cycle "$1" >/dev/null 2>&1 || true
  : > "$2/tmux-calls.log"
}

# --- one capture call per poll, feeding the unchanged stale classification ----
DIR=$(real_tmux_case batch)
STATE="$DIR/state"
for id in a b c d; do add_window "$STATE" "$id" "$(static_pane "$id")"; done
record_window "$STATE" zz-gone   # recorded last, with no window
prime_signals "$STATE" "$DIR"
watch_bg "$STATE" "$DIR/fakebin" "$DIR/watch.out" env FM_POLL_IDLE_MAX=0
PID=$!
wait_wake "$PID" 300
grep -q '^stale: pb:fm-a$' "$DIR/watch.out" \
  || fail "the first idle window should surface stale as before; got: $(cat "$DIR/watch.out")"
captures=$(grep -c 'capture-pane' "$DIR/tmux-calls.log")
[ "$captures" -ge 2 ] || fail "expected at least two polls of captures, got $captures calls"
grep 'capture-pane' "$DIR/tmux-calls.log" | while IFS= read -r call; do
  n=$(printf '%s\n' "$call" | grep -o 'capture-pane' | wc -l | tr -d ' ')
  # The missing zz-gone sits out the polls after its failed capture.
  [ "$n" -eq 5 ] || [ "$n" -eq 4 ] || { echo "a capture call covered $n windows, not all 5 (or 4 once zz-gone failed): $call" >&2; exit 1; }
done || fail "every poll should capture all recorded windows in one tmux call"
grep 'capture-pane' "$DIR/tmux-calls.log" | head -1 | grep -q 'pb:fm-zz-gone' \
  || fail "the first poll should include the not-yet-failed window"
pass "watcher: one tmux client call captures every recorded window per poll, and the stale verdict is unchanged"

# --- a 22-window home: per-poll lookups stay fast enough to wake on time -----
# A 22-window home, each window with the busy records and turn-ended marker a
# real Claude worker leaves, once took over a minute per poll inside the
# snapshot lookups; the stale wake must arrive inside the five-window budget.
DIR=$(real_tmux_case wide)
STATE="$DIR/state"
for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22; do
  add_window "$STATE" "w$i" "$(static_pane "w$i")"
  printf 'g%s\n' "$i" > "$STATE/w$i.busy-gen"
  printf 'v1 gen=g%s seq=2 state=idle source=claude-hook event=stop ts=%s\n' "$i" "$(date +%s)" > "$STATE/w$i.busy-state"
  : > "$STATE/w$i.turn-ended"
done
prime_signals "$STATE" "$DIR"
watch_bg "$STATE" "$DIR/fakebin" "$DIR/watch.out" env FM_POLL_IDLE_MAX=0
PID=$!
wait_wake "$PID" 300
grep -q '^stale: pb:fm-w01$' "$DIR/watch.out" \
  || fail "the first idle window of 22 should surface stale; got: $(cat "$DIR/watch.out")"
pass "watcher: a 22-window home still surfaces stale within the poll budget"

# --- a missing window mid-batch: the windows after it are still read ---------
DIR=$(real_tmux_case resume)
STATE="$DIR/state"
add_window "$STATE" ra "$(changing_pane)"
record_window "$STATE" rb                # recorded, with no window
add_window "$STATE" rc "$(static_pane rc)"
prime_signals "$STATE" "$DIR"
watch_bg "$STATE" "$DIR/fakebin" "$DIR/watch.out" env FM_POLL_IDLE_MAX=0
PID=$!
wait_wake "$PID" 300
grep -q '^stale: pb:fm-rc$' "$DIR/watch.out" \
  || fail "the idle window after a missing one should still surface stale; got: $(cat "$DIR/watch.out")"
grep -q '^display-message -p [^ ]*:0 ; capture-pane -p -t pb:fm-rc -S -40 ; display-message -p [^ ]*end$' "$DIR/tmux-calls.log" \
  || fail "the batch should resume after the missing window with the windows after it"$'\n'"$(cat "$DIR/tmux-calls.log")"
if grep 'capture-pane' "$DIR/tmux-calls.log" | grep -v 'pb:fm-ra' | grep -q 'pb:fm-rb'; then
  fail "the resumed call should not retry the missing window"$'\n'"$(cat "$DIR/tmux-calls.log")"
fi
polls=$(grep -c 'capture-pane -p -t pb:fm-ra' "$DIR/tmux-calls.log")
gone=$(grep -c 'capture-pane -p -t pb:fm-rb' "$DIR/tmux-calls.log")
[ "$polls" -ge 2 ] && [ "$gone" -eq 1 ] \
  || fail "a window whose capture failed should sit out the next polls; $gone calls named it over $polls polls"$'\n'"$(cat "$DIR/tmux-calls.log")"
pass "watcher: a missing window ends its batch call, the poll resumes with the windows after it, and later polls skip it"

# --- idle backoff: the wait doubles while nothing changes, and resets --------
DIR=$(real_tmux_case backoff)
STATE="$DIR/state"
watch_bg "$STATE" "$DIR/fakebin" "$DIR/watch.out" env FM_POLL_IDLE_MAX=8
PID=$!
beats=()
last=
added=0
tick=0
while [ "$tick" -lt 600 ]; do   # 0.1s ticks: ~60s unloaded, stretches under load
  tick=$((tick + 1))
  kill -0 "$PID" 2>/dev/null || fail "the idle watcher exited: $(cat "$DIR/watch.out")"
  now=$(file_mtime "$STATE/.last-watcher-beat")
  if [ -n "$now" ] && [ "$now" != "$last" ]; then
    beats+=("$now")
    last=$now
    # After three idle gaps, record a new window: the window set changed.
    if [ "${#beats[@]}" -eq 4 ] && [ "$added" -eq 0 ]; then
      # A meta alone: a new status log would wake the watcher as a signal.
      printf 'window=pb:fm-late\nharness=claude\nkind=ship\n' > "$STATE/late.meta"
      added=${#beats[@]}
    fi
    [ "${#beats[@]}" -lt 7 ] || break
  fi
  sleep 0.1
done
reap "$PID"
[ "${#beats[@]}" -ge 7 ] || fail "expected seven polls within 600 ticks, saw ${#beats[@]}: ${beats[*]}"
idle_gap=$(( beats[3] - beats[2] ))
reset_gap=$(( beats[5] - beats[4] ))
[ "$idle_gap" -ge 6 ] || fail "idle polls should back off toward 8s; beats: ${beats[*]}"
[ "$reset_gap" -le 3 ] || fail "a changed window set should return the wait to the 1s poll; beats: ${beats[*]}"
pass "watcher: idle polls back off to FM_POLL_IDLE_MAX and a worker change restores FM_POLL"

# Poll beats of a running watcher: <count> distinct beacon mtimes, into BEATS.
collect_beats() {  # <pid> <state> <count> [<at-beat> <command>]
  local pid=$1 state=$2 want=$3 at=${4:-0} cmd=${5:-} last='' now tick=0
  BEATS=()
  while [ "$tick" -lt 900 ]; do   # 0.1s ticks
    tick=$((tick + 1))
    kill -0 "$pid" 2>/dev/null || fail "the watcher exited: $(cat "$DIR/watch.out")"
    now=$(file_mtime "$state/.last-watcher-beat")
    if [ -n "$now" ] && [ "$now" != "$last" ]; then
      BEATS+=("$now")
      last=$now
      [ "${#BEATS[@]}" -ne "$at" ] || eval "$cmd"
      [ "${#BEATS[@]}" -lt "$want" ] || return 0
    fi
    sleep 0.1
  done
  fail "expected $want polls within 900 ticks, saw ${#BEATS[@]}: ${BEATS[*]}"
}

# --- a settled escalated inbox leaves the idle backoff alone -----------------
# A recorded task whose oldest unread instruction is already escalated waits on
# a person, so its polls back off; once that escalation is gone the inbox is a
# timed ladder again and the poll returns to FM_POLL.
DIR=$(real_tmux_case inbox-backoff)
STATE="$DIR/state"
record_window "$STATE" inb               # recorded, with no window
prime_signals "$STATE" "$DIR"
mkdir -p "$STATE/inb.inbox/handled"
printf 'schema=fm-task-inbox.v1\n--\nan unread instruction\n' > "$STATE/inb.inbox/001.msg"
printf '001.msg\n' > "$STATE/inb.inbox/.escalated"
watch_bg "$STATE" "$DIR/fakebin" "$DIR/watch.out" env FM_POLL_IDLE_MAX=8
PID=$!
# shellcheck disable=SC2016 # collect_beats evaluates the command later.
collect_beats "$PID" "$STATE" 8 6 'rm -f "$STATE/inb.inbox/.escalated"'
reap "$PID"
idle_gap=$(( BEATS[5] - BEATS[4] ))
reset_gap=$(( BEATS[7] - BEATS[6] ))
[ "$idle_gap" -ge 6 ] || fail "a settled escalated inbox should let polls back off toward 8s; beats: ${BEATS[*]}"
[ "$reset_gap" -le 3 ] || fail "an inbox no longer escalated should return the wait to the 1s poll; beats: ${BEATS[*]}"
pass "watcher: an already-escalated unread instruction keeps the idle backoff; an active ladder keeps FM_POLL"

# --- a busy pane past its turn bound under a declared wait keeps the backoff --
# A busy pane whose footer changes every read takes a new hash every poll. Past
# its turn bound under a declared wait, the long pause cadence owns it, so its
# churn leaves the idle backoff alone; the same churning pane with no declared
# wait is on the wedge timer and keeps FM_POLL.
busy_churn_case() {  # <id> <status-verb> -> case dir
  local dir state gen
  dir=$(real_tmux_case "$1")
  state="$dir/state"
  add_window "$state" "$1" "$(changing_pane)"
  printf 'window=pb:fm-%s\nharness=pi\nkind=ship\n' "$1" > "$state/$1.meta"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$1") || fail "could not arm the busy record"
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$1" busy --gen "$gen" --source pi-ext --event agent-start \
    || fail "could not record the pane busy"
  touch -t 200001010000 "$state/$1.meta"   # no completed turn since long ago
  printf '%s [at=%s]: waiting\n' "$2" "$(date +%s)" > "$state/$1.status"
  seen_sig "$state/$1.status" > "$state/.seen-$1_status"
  printf '%s\n' "$dir"
}
busy_churn_beats() {  # <id> <status-verb>: six poll beats into BEATS, case dir in DIR
  DIR=$(busy_churn_case "$1" "$2")
  STATE="$DIR/state"
  watch_bg "$STATE" "$DIR/fakebin" "$DIR/watch.out" env FM_POLL_IDLE_MAX=8 FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999
  PID=$!
  collect_beats "$PID" "$STATE" 6
  reap "$PID"
}
busy_churn_beats bzp paused
[ -e "$STATE/.paused-pb_fm-bzp" ] \
  || fail "the busy declared-wait pane should be on the pause cadence; out: $(cat "$DIR/watch.out")"
idle_gap=$(( BEATS[5] - BEATS[4] ))
[ "$idle_gap" -ge 6 ] || fail "a churning busy pane past its turn bound under a declared wait should let polls back off toward 8s; beats: ${BEATS[*]}"
busy_churn_beats bzw working
[ -s "$STATE/.stale-since-pb_fm-bzw" ] || fail "the undeclared churning busy pane should be on the wedge timer; out: $(cat "$DIR/watch.out")"
busy_gap=$(( BEATS[5] - BEATS[4] ))
[ "$busy_gap" -le 3 ] || fail "the same churning pane with no declared wait should keep the 1s poll; beats: ${BEATS[*]}"
pass "watcher: a churning busy pane past its turn bound under a declared wait keeps the idle backoff; with no declared wait it keeps FM_POLL"

# --- a skipped missing window is retried within four polls under backoff -----
# A missing window may sit out a poll only while the next poll, at the longest
# wait the backoff can pick, still comes within four 1s polls of its failed
# capture. So whenever the watcher skipped it, its next retry follows the
# previous try within four seconds plus one poll's own run time.
DIR=$(real_tmux_case gone-backoff)
STATE="$DIR/state"
# A secondmate's unchanged window is captured every poll and never woken on,
# so each poll shows as one capture call without counting as a change.
add_window "$STATE" lv "$(static_pane lv)"
printf 'window=pb:fm-lv\nharness=claude\nkind=secondmate\n' > "$STATE/lv.meta"
record_window "$STATE" mw                # recorded, with no window
prime_signals "$STATE" "$DIR"
cat > "$DIR/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in *capture-pane*) printf '%s %s\\n' "\$(date +%s.%N)" "\$*" >> "$DIR/captures.log" ;; esac
exec "$REAL_TMUX" -S "$SOCKET" "\$@"
SH
chmod +x "$DIR/fakebin/tmux"
watch_bg "$STATE" "$DIR/fakebin" "$DIR/watch.out" env FM_POLL_IDLE_MAX=8
PID=$!
collect_beats "$PID" "$STATE" 8
reap "$PID"
# Each capture call is one poll. After a poll that skipped mw, the next poll
# must come within six seconds of mw's last try: four 1s polls plus a poll's
# run time. The case must also have skipped once and backed off past 4s.
verdict=$(awk '{
    t = $1; tried = index($0, "pb:fm-mw") > 0
    if (n > 0 && t - prev >= 4) backoff = 1
    if (pending && t - last > 6) late = late sprintf(" %.1fs", t - last)
    pending = 0
    if (tried) last = t; else if (n > 0) { pending = 1; skipped = 1 }
    prev = t; n++
  } END { printf "late=%s skipped=%d backoff=%d", late, skipped, backoff }' "$DIR/captures.log")
case "$verdict" in
  "late= skipped=1 backoff=1") ;;
  *) fail "a skipped missing window should be retried within four polls of its last try under backoff ($verdict)"$'\n'"$(cat "$DIR/captures.log")" ;;
esac
pass "watcher: under the idle backoff a skipped missing window is still retried within four polls of its last try"

# --- the inactive-outcome scan runs when its inputs change ------------------
# A copied code root whose fm-inactive-reconcile.sh only logs each call: with
# nothing changing, polls inside a minute run the scan once; a new record
# runs it again on the next poll.
DIR=$(real_tmux_case inactive-scan)
STATE="$DIR/state"
cp -R "$ROOT/bin" "$DIR/root-bin"
printf '#!/usr/bin/env bash\nprintf "scan %%s\\n" "$*" >> "%s"\n' "$DIR/scans.log" > "$DIR/root-bin/fm-inactive-reconcile.sh"
chmod +x "$DIR/root-bin/fm-inactive-reconcile.sh"
: > "$DIR/scans.log"
WATCH_SAVED=$WATCH
WATCH="$DIR/root-bin/fm-wat""ch.sh"
watch_bg "$STATE" "$DIR/fakebin" "$DIR/watch.out" env FM_POLL_IDLE_MAX=0
PID=$!
WATCH=$WATCH_SAVED
collect_beats "$PID" "$STATE" 5
before=$(grep -c '^scan scan$' "$DIR/scans.log")
printf 'window=pb:fm-late\nharness=claude\nkind=ship\n' > "$STATE/late.meta"
collect_beats "$PID" "$STATE" 3
reap "$PID"
after=$(grep -c '^scan scan$' "$DIR/scans.log")
[ "$before" -eq 1 ] || fail "five unchanged polls inside a minute should scan once, scanned $before times"
[ "$after" -eq 2 ] || fail "a new record should scan once more on the next poll, scanned $after times in all"
pass "watcher: the inactive-outcome scan runs on its first poll and when a record changes, not every poll"
