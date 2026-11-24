#!/usr/bin/env bash
set -u
ROOT={run-worktree}
E=~/.no-mistakes/evidence/01M87Y5E24QJM9D7GRZBS9GVZA/live2
LAB="$E/l"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TASK_ID FM_LOCK_HOLDER FM_LOCK_RECEIPT
export FM_HOME="$LAB/h" FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 FM_BACKEND=tmux
cd "$ROOT" || exit 2
bash tests/fm-omp-harness.test.sh > "$E/omp-portable-isolated.log" 2>&1
printf '%s\n' "$?" > "$E/omp-portable-isolated.exit"
bash bin/fm-spawn.sh sm "$LAB/s" --secondmate > "$E/spawn.log" 2>&1
printf '%s\n' "$?" > "$E/spawn.exit"
