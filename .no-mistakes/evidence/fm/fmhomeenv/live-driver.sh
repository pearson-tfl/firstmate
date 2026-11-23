#!/bin/bash
set -eu
ROOT=$PWD
D=$ROOT/.live-home
E=~/.no-mistakes/evidence/01M85AJTDXHG508BFYP0Y5E4FJ
SOCKET=fm-lab-home-$$
lab() { tmux -L "$SOCKET" "$@"; }
trap 'lab kill-server 2>/dev/null || true' EXIT
for name in global secondmate primary; do
 bin/fm-lab-home.sh create "$D/$name"
 echo manual > "$D/$name/config/backlog-backend"
done
printf 'lab-secondmate\n' > "$D/secondmate/.fm-secondmate-home"
mkdir -p "$D/project"
git -C "$D/project" init -b main -q
git -C "$D/project" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -m initial -q
cat > "$D/probe.sh" <<'PROBE'
#!/bin/sh
printf 'task=%s\nFM_HOME=%s\nFM_ROOT_OVERRIDE=%s\nFM_STATE_OVERRIDE=%s\nFM_DATA_OVERRIDE=%s\nFM_CONFIG_OVERRIDE=%s\nFM_PROJECTS_OVERRIDE=%s\ncwd=%s\n' "$FM_TASK_ID" "$FM_HOME" "${FM_ROOT_OVERRIDE-unset}" "${FM_STATE_OVERRIDE-unset}" "${FM_DATA_OVERRIDE-unset}" "${FM_CONFIG_OVERRIDE-unset}" "${FM_PROJECTS_OVERRIDE-unset}" "$PWD" > "~/.no-mistakes/evidence/01M85AJTDXHG508BFYP0Y5E4FJ/live-$FM_TASK_ID.txt"
PROBE
lab new-session -d -s lab -x 120 -y 30
lab set-environment -g FM_HOME "$D/global"
for v in ROOT STATE DATA CONFIG PROJECTS; do lab set-environment -g FM_${v}_OVERRIDE "$D/global"; done
lab set-environment -g TREEHOUSE_ROOT "$D/pool"
lab set-environment -g SHELL /bin/bash
lab set-environment -g PATH "$PATH"
lab new-window -d -n control "printenv FM_HOME > '$E/live-control.txt'"
for spec in secondmate:ship secondmate:scout primary:ship; do
 home=${spec%:*}; kind=${spec#*:}; id=$home-$kind
 mkdir -p "$D/$home/data/$id"
 cat > "$D/$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Report the launch environment in a disposable fixture.
## Firstmate spec
Run the requested environment capture only.
EOF
 touch "$D/$home/state/.last-watcher-beat"
 flags='--mode local-only --yolo off'
 [ "$kind" != scout ] || flags=--scout
 cat > "$D/$id.sh" <<EOF
#!/bin/bash
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TASK_ID
export FM_HOME='$D/$home' TREEHOUSE_ROOT='$D/pool' PROBE_RESULT='$E/live-$id.txt'
cd '$ROOT'
'$ROOT/bin/fm-spawn.sh' '$id' '$D/project' $flags '/bin/sh $D/probe.sh' > '$E/spawn-$id.log' 2>&1
printf '%s' \$? > '$D/$id.rc'
EOF
 lab new-window -d -n "driver-$id" "/bin/bash '$D/$id.sh'"
 for n in $(seq 1 100); do [ ! -f "$D/$id.rc" ] || break; sleep 1; done
 if [ ! -f "$D/$id.rc" ]; then lab capture-pane -p -t "driver-$id" > "$E/timeout-$id.txt"; exit 1; fi
 cat "$E/spawn-$id.log"
 [ "$(cat "$D/$id.rc")" = 0 ] || exit 1
 for n in $(seq 1 20); do [ ! -s "$E/live-$id.txt" ] || break; sleep 1; done
 cat "$E/live-$id.txt"
 done
