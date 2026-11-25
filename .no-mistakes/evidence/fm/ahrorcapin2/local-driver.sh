#!/usr/bin/env bash
set -u
ROOT=$PWD
CASE="$ROOT/.local-test-tmp/live"
mkdir -p "$CASE"
LAB="$CASE/home"
[ -f "$LAB/.fm-lab-home" ] || bash bin/fm-lab-home.sh create "$LAB" || exit 1
mkdir -p "$CASE/project" "$CASE/wt" "$LAB/data/pin-check"
printf 'unlanded\n' > "$CASE/wt/unlanded.txt"
printf '/implement\n\n## Captain\x27s intent\nLocal account refusal verification\n' > "$LAB/data/pin-check/brief.md"
printf 'claude\n' > "$LAB/config/crew-harness"
printf 'manual\n' > "$LAB/config/backlog-backend"
touch "$LAB/state/.last-watcher-beat"
cat > "$LAB/state/pin-check.meta" <<EOF
window=fm-pin-check
endpoint_task_id=pin-check
worktree=$CASE/wt
project=$CASE/project
harness=codex
kind=ship
mode=direct-PR
yolo=off
branch=task-pin-check
backend=orca
orca_worktree_id=wt-1::$CASE/wt
terminal=synthetic-never-contact
EOF
cp "$LAB/state/pin-check.meta" "$CASE/before.meta"
cp "$LAB/data/pin-check/brief.md" "$CASE/before.brief"
export HOME="$ROOT/.local-test-tmp/auth-home"
export TMPDIR="$ROOT/.local-test-tmp"
export FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS CLAUDE_CONFIG_DIR
for pin in ordinary root; do
  if [ "$pin" = ordinary ]; then printf 'ordinary\n' > "$LAB/config/claude-account"; else printf '%s\n' "$HOME/.claude" > "$LAB/config/claude-account"; fi
  for entry in control; do
    printf '\nCASE %s / %s (synthetic local account and task records)\n' "$pin" "$entry"
    if [ "$entry" = control ]; then
      bash bin/fm-control.sh pin-check relaunch --harness claude --note 'Preserve existing work' > "$CASE/output" 2>&1
    else
      bash bin/fm-spawn.sh pin-check --relaunch --harness claude > "$CASE/output" 2>&1
    fi
    rc=$?
    cat "$CASE/output"
    printf 'exit=%s\n' "$rc"
    [ "$rc" = 1 ] || exit 10
    rg -q 'backend=orca cannot guarantee the Claude worker account pin' "$CASE/output" || exit 11
    cmp "$CASE/before.meta" "$LAB/state/pin-check.meta" || exit 12
    cmp "$CASE/before.brief" "$LAB/data/pin-check/brief.md" || exit 13
    [ "$(cat "$CASE/wt/unlanded.txt")" = unlanded ] || exit 14
    printf 'Persisted task record, instructions, and unlanded file unchanged.\n'
  done
done
printf '\nCASE fresh spawn / root pin\n'
bash bin/fm-spawn.sh fresh-pin "$CASE/project" --harness claude --mode no-mistakes --yolo off --backend orca > "$CASE/fresh-output" 2>&1
rc=$?
cat "$CASE/fresh-output"
printf 'exit=%s\n' "$rc"
printf '\nNOTE: Orca is not installed; no runtime endpoint or real Orca worker was contacted.\n'
