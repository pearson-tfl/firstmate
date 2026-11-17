#!/usr/bin/env bash
# Live driver: bin/fm-lock.sh receipt handoff against a disposable lab home.
set -u
WT=$1
cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
trap 'rm -rf "$LAB"' EXIT
run() { # label, then env/args
  local label=$1; shift
  local out rc
  out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_LOCK_RECEIPT -u FM_LOCK_HOLDER FM_HOME="$LAB" "$@" 2>&1); rc=$?
  printf '== %s\n$ %s\nexit=%s\n%s\n' "$label" "$*" "$rc" "$out"
  LAST_RC=$rc; LAST_OUT=$out
}
show() { printf -- '-- state: lock=[%s] receipt=[%s] session=[%s]\n' "$(cat "$LAB/state/.lock" 2>/dev/null || echo ABSENT)" "$(cat "$LAB/state/.lock-receipt" 2>/dev/null || echo ABSENT)" "$( [ -e "$LAB/state/.lock-session" ] && echo present || echo absent)"; }
expect() { if [ "$LAST_RC" = "$1" ]; then echo "PASS ($2)"; else echo "FAIL ($2): wanted $1 got $LAST_RC"; FAILS=$((FAILS+1)); fi; }
FAILS=0

echo "### S1 watchdog reserves an absent main lock"
run reserve FM_LOCK_HOLDER=main bin/fm-lock.sh reserve --absent-only; expect 0 "reserve on empty home"
R=$LAST_OUT; [[ "$R" =~ ^v1:[0-9a-f]{32}$ ]] && echo "PASS (receipt format $R)" || { echo "FAIL receipt format"; FAILS=$((FAILS+1)); }
show
[ "$(cat "$LAB/state/.lock")" = holder:main ] && [ "$(cat "$LAB/state/.lock-receipt")" = "$R" ] && echo "PASS (lock line + receipt file)" || { echo FAIL; FAILS=$((FAILS+1)); }

echo "### S2 second reserve and bare reserve refused, nothing changed"
run reserve-again FM_LOCK_HOLDER=main bin/fm-lock.sh reserve --absent-only; expect 73 "reserve with existing lock"
run reserve-bare FM_LOCK_HOLDER=main bin/fm-lock.sh reserve; expect 64 "bare reserve"
run reserve-noholder bin/fm-lock.sh reserve --absent-only; expect 64 "reserve without holder"
show; [ "$(cat "$LAB/state/.lock-receipt")" = "$R" ] && echo "PASS (receipt untouched)" || { echo FAIL; FAILS=$((FAILS+1)); }

echo "### S3 adversarial: stand-in with wrong / malformed / foreign-holder receipt cannot adopt"
run wrong-receipt FM_LOCK_HOLDER=main FM_LOCK_RECEIPT=v1:00000000000000000000000000000000 bin/fm-lock.sh; expect 74 "wrong receipt"
run malformed FM_LOCK_HOLDER=main FM_LOCK_RECEIPT=garbage bin/fm-lock.sh; expect 64 "malformed receipt"
run foreign-holder FM_LOCK_HOLDER=intruder FM_LOCK_RECEIPT="$R" bin/fm-lock.sh; expect 74 "right receipt, wrong holder"
run receipt-with-arg FM_LOCK_HOLDER=main FM_LOCK_RECEIPT="$R" bin/fm-lock.sh status2; expect 64 "receipt with stray arg"
show; [ "$(cat "$LAB/state/.lock-receipt")" = "$R" ] && echo "PASS (receipt untouched after refusals)" || { echo FAIL; FAILS=$((FAILS+1)); }

echo "### S4 recovered main adopts with its receipt (acquire + re-check)"
run adopt FM_LOCK_HOLDER=main FM_LOCK_RECEIPT="$R" bin/fm-lock.sh; expect 0 "adopt"
run recheck FM_LOCK_HOLDER=main FM_LOCK_RECEIPT="$R" bin/fm-lock.sh; expect 0 "re-check keeps receipt"
show; [ "$(cat "$LAB/state/.lock-receipt")" = "$R" ] && echo "PASS (receipt kept through re-check)" || { echo FAIL; FAILS=$((FAILS+1)); }

echo "### S5 same-name ordinary acquisition (stand-in at handoff) invalidates the receipt"
run ordinary-same-name FM_LOCK_HOLDER=main bin/fm-lock.sh; expect 0 "ordinary same-name acquire still passes (compat)"
show; [ ! -e "$LAB/state/.lock-receipt" ] && echo "PASS (receipt file removed)" || { echo FAIL; FAILS=$((FAILS+1)); }
run adopt-after-standin FM_LOCK_HOLDER=main FM_LOCK_RECEIPT="$R" bin/fm-lock.sh; expect 74 "old receipt no longer adopts"
run release-after-standin FM_LOCK_HOLDER=main FM_LOCK_RECEIPT="$R" bin/fm-lock.sh release; expect 74 "old receipt cannot release"
show

echo "### S6 conditional release: mismatch refused, match clears; no reclaim of missing claim"
run ordinary-release FM_LOCK_HOLDER=main bin/fm-lock.sh release; expect 0 "ordinary release (compat)"
run reserve2 FM_LOCK_HOLDER=main bin/fm-lock.sh reserve --absent-only; expect 0 reserve2; R2=$LAST_OUT
run release-wrong FM_LOCK_HOLDER=main FM_LOCK_RECEIPT="$R" bin/fm-lock.sh release; expect 74 "release with stale receipt"
show
run release-right FM_LOCK_HOLDER=main FM_LOCK_RECEIPT="$R2" bin/fm-lock.sh release; expect 0 "release with matching receipt"
show; [ ! -e "$LAB/state/.lock" ] && [ ! -e "$LAB/state/.lock-receipt" ] && echo "PASS (lock + receipt cleared)" || { echo FAIL; FAILS=$((FAILS+1)); }
run adopt-missing FM_LOCK_HOLDER=main FM_LOCK_RECEIPT="$R2" bin/fm-lock.sh; expect 74 "missing claim not reclaimed"
show; [ ! -e "$LAB/state/.lock" ] && echo "PASS (no lock created)" || { echo FAIL; FAILS=$((FAILS+1)); }

echo "### S7 reserve refuses empty file, directory and dangling symlink"
for kind in empty dir symlink; do
  rm -rf "$LAB/state/.lock"
  case $kind in empty) : > "$LAB/state/.lock";; dir) mkdir "$LAB/state/.lock";; symlink) ln -s "$LAB/nowhere" "$LAB/state/.lock";; esac
  run "reserve-$kind" FM_LOCK_HOLDER=main bin/fm-lock.sh reserve --absent-only; expect 73 "reserve over $kind"
  [ ! -e "$LAB/state/.lock-receipt" ] && echo "PASS (no receipt written)" || { echo FAIL; FAILS=$((FAILS+1)); }
done
rm -rf "$LAB/state/.lock"

echo "### S8 mutex contention: receipt acquisition WAITS, reserve fails fast with 75"
run reserve3 FM_LOCK_HOLDER=main bin/fm-lock.sh reserve --absent-only; expect 0 reserve3; R3=$LAST_OUT
# Hold the claim mutex from a separate process for 3s.
FM_HOME="$LAB" bash -c '. bin/fm-wake-lib.sh; fm_lock_try_acquire "$FM_HOME/state/.lock.acquire" || exit 9; echo held > "$FM_HOME/held"; sleep 3; fm_lock_release "$FM_HOME/state/.lock.acquire"' &
HP=$!
for _ in $(seq 50); do [ -e "$LAB/held" ] && break; sleep 0.1; done
[ -e "$LAB/held" ] && echo "mutex held by pid $HP"
run reserve-busy FM_LOCK_HOLDER=other bin/fm-lock.sh reserve --absent-only; expect 75 "reserve fails fast on busy mutex"
t0=$(date +%s)
run adopt-waits FM_LOCK_HOLDER=main FM_LOCK_RECEIPT="$R3" bin/fm-lock.sh; expect 0 "receipt adopt waited for mutex"
t1=$(date +%s); echo "adopt took $((t1-t0))s (mutex held ~3s)"
wait "$HP"; echo "holder exit=$?"
[ $((t1-t0)) -ge 1 ] && echo "PASS (adopt blocked then succeeded)" || { echo "FAIL (did not wait)"; FAILS=$((FAILS+1)); }
show

echo "TOTAL FAILS=$FAILS"
