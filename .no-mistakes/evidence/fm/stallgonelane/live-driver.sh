#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$(mktemp -d "$ROOT/.merge-stall-live.XXXXXX")
BASE="$ROOT/bin/.merge-stall-baseline-$$.sh"
cleanup() { if [ -S "$LAB/socket" ]; then tmux -S "$LAB/socket" kill-server; fi; rm -rf "$LAB"; rm -f "$BASE"; }
trap cleanup EXIT
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$LAB/home/state" FM_CREW_STATE_NO_FORGE=1
mkdir -p "$FM_HOME"/{state,data,config} "$LAB/existing-copy"
tmux -S "$LAB/socket" new-session -d -s fm-lab-stall -x 100 -y 30 'sleep 600'
export TMUX="$LAB/socket,0,0"
git show 4d4aa5edc9edcc52f28bfb509ccfbafb2be00498:bin/fm-merge-stall.sh > "$BASE"
write_task() {
 printf 'kind=ship\nmode=direct-PR\nyolo=on\npr=https://github.com/owner/repo/pull/628\nbackend=tmux\nworktree=%s\n' "$1" > "$FM_HOME/state/lane.meta"
 printf 'paused [at=1795641826]: waiting on home\n' > "$FM_HOME/state/lane.status"
}
scan() { bash "$1" scan --now 1795645426; }
write_task "$LAB/missing-copy"
printf 'window=fm-lab-stall:removed-worker\n' >> "$FM_HOME/state/lane.meta"
echo 'SCENARIO: missing local copy and worker'
bash bin/fm-crew-state.sh lane
before=$(scan "$BASE")
printf 'BASELINE: %s\n' "$before"
[[ "$before" == *'evidence unavailable: current activity unreadable'* ]]
# A previously persisted stall must be retired, rather than preserved by uncertainty.
printf 'lane\thttps://github.com/owner/repo/pull/628\t1795641826\t1795642426\t0\tepisode\n' > "$FM_HOME/state/.merge-stall"
for sweep in 1 2; do
 out=$(scan bin/fm-merge-stall.sh)
 printf 'TARGET sweep %s: output=%q; ledger-bytes=%s\n' "$sweep" "$out" "$(wc -c < "$FM_HOME/state/.merge-stall" | tr -d ' ')"
 [ -z "$out" ] && [ ! -s "$FM_HOME/state/.merge-stall" ]
done

echo 'SCENARIO: existing local copy but missing target on real private tmux server'
write_task "$LAB/existing-copy"
printf 'window=fm-lab-stall:removed-worker\n' >> "$FM_HOME/state/lane.meta"
state=$(bash bin/fm-crew-state.sh lane)
printf '%s\n' "$state"
[[ "$state" == *'backend target gone: fm-lab-stall:removed-worker' ]]
out=$(scan bin/fm-merge-stall.sh)
printf 'TARGET: output=%q; ledger-bytes=%s\n' "$out" "$(wc -c < "$FM_HOME/state/.merge-stall" | tr -d ' ')"
[ -z "$out" ] && [ ! -s "$FM_HOME/state/.merge-stall" ]

echo 'SCENARIO: incomplete target metadata still warns and preserves prior stall'
write_task "$LAB/existing-copy"
printf 'lane\thttps://github.com/owner/repo/pull/628\t1795641826\t1795642426\t0\tepisode\n' > "$FM_HOME/state/.merge-stall"
prior=$(cat "$FM_HOME/state/.merge-stall")
bash bin/fm-crew-state.sh lane
out=$(scan bin/fm-merge-stall.sh)
printf 'TARGET: %s\n' "$out"
[[ "$out" == *'evidence unavailable: current activity unreadable for lane: state: unknown · source: none · no backend target recorded'* ]]
[[ "$out" != *'merge it now'* ]]
[ "$prior" = "$(cat "$FM_HOME/state/.merge-stall")" ]
echo 'Prior stall preserved; all live assertions passed. Private tmux server and disposable home removed on exit.'
