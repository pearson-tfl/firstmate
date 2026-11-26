#!/usr/bin/env bash
set -euo pipefail
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TASKS_AXI_FILE TASKS_AXI_BACKEND
ROOT=$PWD
LAB=$ROOT/.batch-live
trap 'rm -rf "$LAB"' EXIT
mkdir "$LAB"
bin/fm-lab-home.sh create "$LAB/home"
export FM_HOME=$LAB/home FM_BACKEND=tmux
# No backend is reached: the public preflight must reject disagreeing contracts.
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
mkdir "$LAB/project"
git -C "$LAB/project" init -q -b main
git -c user.name=Lab -c user.email=lab@example.invalid -C "$LAB/project" commit -q --allow-empty -m 'Disposable validation project'
for kind in ship scout; do
  args=(--scout)
  [ "$kind" != ship ] || args=(--mode local-only --yolo off)
  for id in a b; do
    bin/fm-brief.sh "$kind-$id" project "${args[@]:0:1}" --required-skill tdd >/dev/null 2>&1 && [ "$kind" = scout ] || {
      [ "$kind" = ship ]
      bin/fm-brief.sh "$kind-$id" project --mode local-only --required-skill tdd >/dev/null
    }
    python3 - "$FM_HOME/data/$kind-$id/brief.md" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().replace('{TASK}', 'Verify the synthetic command contract.').replace('{FIRSTMATE_SPEC}', 'Stop at preflight; no model work is requested.')
open(p,'w').write(s)
PY
  done
  printf '\nSCENARIO %s batch: each child must retain both required-skill flags and reject a brief naming only tdd\n' "$kind"
  set +e
  OUT=$(bin/fm-spawn.sh "$kind-a=$LAB/project" "$kind-b=$LAB/project" "${args[@]}" --required-skill tdd --required-skill poteto-mode 2>&1)
  RC=$?
  set -e
  printf '%s\nexit=%s\n' "$OUT" "$RC"
  [ "$RC" -ne 0 ]
  for id in a b; do
    [[ $OUT = *"required-skill mismatch for $kind-$id:"* ]]
  done
  [[ $OUT = *'records tdd but this spawn passed tdd,poteto-mode'* ]]
  [ ! -f "$FM_HOME/state/$kind-a.meta" ]
  [ ! -f "$FM_HOME/state/$kind-b.meta" ]
done
printf '\nBoth batch preflights refused safely before launching; disposable home removed.\n'
