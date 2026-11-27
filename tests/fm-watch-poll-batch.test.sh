#!/usr/bin/env bash
# tests/fm-watch-poll-batch.test.sh - the watcher's per-poll pane read against
# a REAL tmux server on a private socket: every recorded tmux window of one
# poll is captured through a single tmux client call, a missing window costs
# only a resumed call for the windows after it, the stale classification those
# captures feed is unchanged, and an idle poll backs its wait off until a
# worker changes.
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
  [ "$n" -eq 5 ] || { echo "a capture call covered $n windows, not all 5: $call" >&2; exit 1; }
done || fail "every poll should capture all recorded windows in one tmux call"
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
pass "watcher: a missing window ends its batch call and the poll resumes with the windows after it"

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
