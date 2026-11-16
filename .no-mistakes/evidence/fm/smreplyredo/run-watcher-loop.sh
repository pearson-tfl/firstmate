#!/usr/bin/env bash
# Run the real bin/fm-watch.sh against the lab home; each exit is one wake.
# After every wake, drain the queue like main and ack it (main handled it).
set -u
WT=$1 LAB=$2 OUT=$3 RUNS=${4:-6}
for i in $(seq 1 "$RUNS"); do
  printf '=== watcher run %s start %s\n' "$i" "$(date +%T)" >> "$OUT"
  env -u NO_MISTAKES_GATE FM_HOME=$LAB FM_POLL=2 FM_PENDING_REPLY_GRACE_SECS=3 timeout 45 "$WT/bin/fm-watch.sh" >> "$OUT" 2>&1
  printf '=== watcher run %s exit=%s %s\n' "$i" "$?" "$(date +%T)" >> "$OUT"
  printf -- '--- record phase: %s\n' "$(grep '^phase=' "$LAB"/state/pending-replies/[0-9a-f]* | tail -1)" >> "$OUT"
  printf -- '--- drain (what main reads):\n' >> "$OUT"
  d=$(env -u NO_MISTAKES_GATE FM_HOME=$LAB "$WT/bin/fm-wake-drain.sh" 2>&1); printf '%s\n' "$d" >> "$OUT"
  ack=$(printf '%s\n' "$d" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run //p' | head -1)
  [ -z "$ack" ] || { env -u NO_MISTAKES_GATE bash -c "$ack" >> "$OUT" 2>&1; printf -- '--- acked\n' >> "$OUT"; }
done
echo DONE >> "$OUT"
