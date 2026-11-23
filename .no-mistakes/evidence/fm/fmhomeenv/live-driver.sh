#!/bin/bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M857KTN6MHT14HB8TE4Z32Y0
D=$(mktemp -d "$PWD/.fm-home-live.XXXXXX")
LAB=$D/mate
bin/fm-lab-home.sh create "$LAB"
SOCKDIR=$(bin/fm-lab-home.sh tmux-dir "$LAB")
export TMUX_TMPDIR=$SOCKDIR
lab() { tmux -L fm-lab -f /dev/null "$@"; }
cleanup() { lab kill-server 2>/dev/null || true; bin/fm-lab-home.sh teardown "$LAB"; rm -rf "$D"; }
trap cleanup EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX TMUX_PANE
mkdir -p "$D/user" "$D/project" "$D/primary"
export HOME=$D/user TREEHOUSE_ROOT=$D/pool SHELL=/bin/bash
export XDG_CONFIG_HOME=$HOME/.config XDG_DATA_HOME=$HOME/.local/share
export FM_HOME=$LAB
printf 'codex\n' > "$LAB/config/crew-harness"
printf 'lab-mate\n' > "$LAB/.fm-secondmate-home"
touch "$LAB/state/.last-watcher-beat"
git -C "$D/project" init -q
git -C "$D/project" -c user.name=Lab -c user.email=lab@example.invalid commit -qm initial --allow-empty
lab new-session -d -s fm-lab-home -x 120 -y 40 /bin/bash --noprofile --norc
lab set-option -g default-shell /bin/bash
lab set-option -g default-command '/bin/bash --noprofile --norc'
lab set-environment -g FM_HOME "$D/primary"
for v in FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE; do lab set-environment -g "$v" "$D/primary/foreign"; done
export TMUX=$(lab display-message -p '#{socket_path},#{pid},#{session_id}' | sed 's/\$//g')
lab new-window -d -n control "/usr/bin/env > '$E/control-environment.txt'"
sleep 1
cat > "$D/probe.sh" <<'PROBE'
#!/bin/sh
{
 printf 'FM_HOME=%s\n' "$FM_HOME"
 for v in FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE; do eval 'printf "%s=%s\n" "$v" "${'"$v"'-unset}"'; done
 printf 'cwd=%s\n' "$PWD"
} > "$1"
PROBE
for kind in ship scout primary; do
 id=home-$kind
 if [ "$kind" = primary ]; then rm "$LAB/.fm-secondmate-home"; fi
 mkdir -p "$LAB/data/$id"
 cat > "$LAB/data/$id/brief.md" <<EOF
/implement

# Task
## Captain's intent
Record the isolated worker environment.

## Firstmate spec
Execute the supplied custom environment-report command only.
EOF
 flags=(--mode local-only --yolo off)
 if [ "$kind" = scout ]; then flags=(--scout); fi
 result=$E/$kind-environment.txt
 launch="/bin/sh '$D/probe.sh' '$result'; /bin/sh '$D/probe.sh' '$E/$kind-compound-environment.txt'"
 echo "SPAWN $kind"
 FM_HOME="$LAB" bin/fm-spawn.sh "$id" "$D/project" "${flags[@]}" "$launch"
 for i in $(seq 1 50); do [ -s "$result" ] && break; sleep .2; done
 cat "$result"
 test "$(sed -n 's/^FM_HOME=//p' "$result")" = "$LAB"
 for v in FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE; do grep -qx "$v=" "$result"; done
 cmp "$result" "$E/$kind-compound-environment.txt"
 echo "OBSERVED $kind: spawning home preserved; all five foreign overrides cleared across compound command"
 lab capture-pane -p -t "fm-lab-home:fm-$id" -S -100 > "$E/$kind-pane.txt" || true
 done
