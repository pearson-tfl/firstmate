#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M8CHWEGA2Y88S9E5GGX55EB1
LAB=$ROOT/.skill-live
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TASKS_AXI_FILE TASKS_AXI_BACKEND
mkdir "$LAB"
cleanup() { tmux -S "$LAB/s" kill-server 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB/parent"
bin/fm-lab-home.sh create "$LAB/mate"
export FM_HOME=$LAB/parent FM_BACKEND=tmux
P=$LAB/parent
M=$LAB/mate
. bin/fm-task-inbox-lib.sh
. bin/fm-pending-reply-lib.sh
# A real tmux transport with a synthetic receiving terminal, never a fake CLI.
tmux -S "$LAB/s" new-session -d -s fm-lab-skills -n fm-sm -x 100 -y 30 'cat -v'
export TMUX="$LAB/s,$(tmux -S "$LAB/s" display-message -p '#{pid}'),0"
printf 'window=fm-lab-skills:fm-sm\nbackend=tmux\nendpoint_task_id=sm\nworktree=%s\nproject=%s\nharness=omp\nkind=secondmate\nmode=secondmate\nyolo=off\nhome=%s\n' "$M" "$M" "$M" > "$P/state/sm.meta"
printf 'sm\n' > "$M/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$P" > "$M/.fm-secondmate-parent"
printf '\nSCENARIO intake: scaffold normalized repeated skill flags and send an OMP marked request\n'
bin/fm-brief.sh task demo --scout --required-skill /poteto-mode --required-skill tdd --required-skill tdd
cp "$P/data/task/brief.md" "$EVIDENCE/generated-brief.md"
bin/fm-send.sh sm --required-skill poteto-mode --required-skill tdd 'Hill-climb the synthetic wiki'
REC=$P/state/sm.inbox/001.msg
cat "$REC"
cp "$REC" "$EVIDENCE/marked-request.msg"
BODY=$(fm_task_inbox_body "$REC")
SKILLS=$(fm_required_skills_from_text "$BODY")
[ "$SKILLS" = poteto-mode,tdd ]
CORR=$(printf '%s\n' "$BODY" | sed -n 's/.*corr=\([a-f0-9]\{16\}\).*/\1/p' | head -1)
[ "${#CORR}" = 16 ]
PR=$(fm_pending_reply_path "$P/state" "$CORR")
[ "$(fm_pending_reply_get "$PR" required_skills)" = poteto-mode,tdd ]
printf '\nSCENARIO rering: acknowledged request without proof is reopened, rings, and escalates\n'
mv "$REC" "$P/state/sm.inbox/handled/"
export FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=2
set +e
FM_POLL=1 bin/fm-watch-checkpoint.sh --seconds 5
CHECKPOINT_RC=$?
set -e
printf 'actual watcher checkpoint exit=%s; acknowledged record reopened=%s\n' "$CHECKPOINT_RC" "$([ -f "$REC" ] && echo yes || echo no)"
[ "$CHECKPOINT_RC" = 0 ] || [ "$CHECKPOINT_RC" = 124 ]
[ -f "$REC" ]
rm -f "$P/state/sm.inbox/.escalated" "$P/state/sm.inbox/.ring-state"
ACTION=$(fm_task_inbox_due_action "$P/state" sm); printf 'watcher action: %s\n' "$ACTION"; [[ $ACTION = ring* ]]
fm_task_inbox_record_ring "$P/state" sm "$REC"
fm_task_inbox_record_ring "$P/state" sm "$REC"
ACTION=$(fm_task_inbox_due_action "$P/state" sm); printf 'watcher action after ring budget: %s\n' "$ACTION"; [[ $ACTION = escalate* ]]
printf '\nSCENARIO completion: done refuses missing proofs; parenthesized initial proofs survive helper metadata and recovery\n'
if FM_HOME="$M" bin/fm-secondmate-report.sh done 'wiki ready'; then exit 10; else printf 'missing-proof done refused as required\n'; fi
printf 'note [source=firstmate]: unmatched tool exclusion before recipient starts\n' > "$P/state/sm.status"
FM_HOME="$M" bin/fm-secondmate-report.sh working 'skill-start poteto-mode path=/synthetic/poteto-mode/SKILL.md route= (render comparison first)'
FM_HOME="$M" bin/fm-secondmate-report.sh working 'skill-start tdd path=/synthetic/tdd/SKILL.md route=red test first'
fm_pending_reply_try_resolve "$P/state" "$CORR" && exit 11
mv "$REC" "$P/state/sm.inbox/handled/"
ACTION=$(fm_task_inbox_due_action "$P/state" sm); printf 'watcher action with initial proofs: %s\n' "$ACTION"; [ "$ACTION" = quiet ]
RECOVERY=$(fm_pending_reply_recovery_message "$PR")
[ "$(fm_required_skills_from_text "$RECOVERY")" = poteto-mode,tdd ]
fm_task_inbox_write "$P/state" sm "$RECOVERY" >/dev/null
if FM_HOME="$M" bin/fm-secondmate-report.sh done 'wiki ready'; then exit 12; fi
FM_HOME="$M" bin/fm-secondmate-report.sh working 'skill-shaped poteto-mode: (rendered each candidate and kept the better comparison)'
FM_HOME="$M" bin/fm-secondmate-report.sh working 'skill-shaped tdd: red CLI check drove the implementation'
FM_HOME="$M" bin/fm-secondmate-report.sh done 'wiki ready'
fm_pending_reply_try_resolve "$P/state" "$CORR"
cat "$P/state/sm.status"
printf 'parent phase: %s\n' "$(fm_pending_reply_get "$PR" phase)"
[ "$(fm_pending_reply_get "$PR" phase)" = resolved ]
new_request() {
  local text req
  text=$(fm_required_skills_section tdd request omp)
  CORR=$(fm_pending_reply_create "$P" "$P/state" "$1" "$text")
  fm_pending_reply_mark_delivered "$P/state" "$CORR"
  fm_pending_reply_embed_corr "$text" "$CORR" req
  fm_task_inbox_write "$P/state" "$1" "$req" >/dev/null
  printf '%s\n' "$1" > "$M/.fm-secondmate-home"
}
printf '\nSCENARIO adversarial helper payload: empty explanation does not satisfy completion\n'
new_request empty
FM_HOME="$M" bin/fm-secondmate-report.sh working 'skill-start tdd path=/synthetic/tdd/SKILL.md route=red test first'
FM_HOME="$M" bin/fm-secondmate-report.sh working 'skill-shaped tdd:'
if FM_HOME="$M" bin/fm-secondmate-report.sh done 'complete'; then exit 13; fi
FM_HOME="$M" bin/fm-secondmate-report.sh working 'skill-shaped tdd: failing check established the desired behavior'
FM_HOME="$M" bin/fm-secondmate-report.sh done 'complete'
cat "$P/state/empty.status"
printf '\nSCENARIO adversarial ordering: late and empty-route starts cannot authorize done\n'
new_request late
FM_HOME="$M" bin/fm-secondmate-report.sh working 'ordinary work before the skill'
FM_HOME="$M" bin/fm-secondmate-report.sh working 'skill-start tdd path=/synthetic/tdd/SKILL.md route=red first'
FM_HOME="$M" bin/fm-secondmate-report.sh working 'skill-shaped tdd: red test guided implementation'
if FM_HOME="$M" bin/fm-secondmate-report.sh done complete; then exit 14; fi
new_request route
FM_HOME="$M" bin/fm-secondmate-report.sh working 'skill-start tdd path=/synthetic/tdd/SKILL.md route='
FM_HOME="$M" bin/fm-secondmate-report.sh working 'skill-shaped tdd: red first'
if FM_HOME="$M" bin/fm-secondmate-report.sh done complete; then exit 15; fi
printf '\nSCENARIO remote-route parent boundary: unproven or foreign-correlated working cannot settle reminder\n'
TEXT=$(fm_required_skills_section tdd request omp)
CORR=$(fm_pending_reply_create "$P" "$P/state" remote "$TEXT")
fm_pending_reply_mark_delivered "$P/state" "$CORR"
fm_pending_reply_embed_corr "$TEXT" "$CORR" BODY
REMOTE_REC=$(fm_task_inbox_write "$M/state/parent-route" steering "$BODY")
mv "$REMOTE_REC" "$M/state/parent-route/steering.inbox/handled/"
printf 'working [corr=%s]: ordinary work\n' "$CORR" > "$P/state/remote.status"
if fm_pending_reply_try_resolve "$P/state" "$CORR"; then exit 16; fi
printf 'parent remains open after unproven working\n'
printf 'working [corr=ffffffffffffffff]: skill-start tdd path=/s/tdd/SKILL.md route=red first\n' > "$P/state/remote.status"
printf 'working [corr=%s]: done ordinary work\n' "$CORR" >> "$P/state/remote.status"
if fm_pending_reply_try_resolve "$P/state" "$CORR"; then exit 17; fi
printf 'parent remains open after foreign-correlation proof\n'
printf 'working [corr=%s]: skill-start tdd path=/s/tdd/SKILL.md route=red first\nworking [corr=%s]: ordinary work\n' "$CORR" "$CORR" > "$P/state/remote.status"
set +e
FM_POLL=1 bin/fm-watch-checkpoint.sh --seconds 5
CHECKPOINT_RC=$?
set -e
[ "$CHECKPOINT_RC" = 0 ] || [ "$CHECKPOINT_RC" = 124 ]
[ "$(fm_pending_reply_get "$(fm_pending_reply_path "$P/state" "$CORR")" phase)" = resolved ]
printf 'parent phase after valid initial proof and answer: %s\n' "$(fm_pending_reply_get "$(fm_pending_reply_path "$P/state" "$CORR")" phase)"
printf '\nSCENARIO worker current state: unproven scout done is blocked, proven done accepted, plain task unchanged\n'
printf 'kind=scout\nbackend=tmux\nwindow=fm-lab-skills:fm-sm\nharness=grok\nworktree=%s\nrequired_skills=tdd\n' "$LAB" > "$P/state/sc.meta"
printf 'done: report written\n' > "$P/state/sc.status"
OUT=$(bin/fm-crew-state.sh sc); printf '%s\n' "$OUT"; [[ $OUT = 'state: blocked'* ]]
printf 'failed [source=firstmate]: prior launch diagnostic\nworking: skill-start tdd path=/s/tdd/SKILL.md route=red test first\nworking: skill-shaped tdd: red check drove implementation\ndone: report written\n' > "$P/state/sc.status"
OUT=$(bin/fm-crew-state.sh sc); printf '%s\n' "$OUT"; [[ $OUT = 'state: done'* ]]
printf 'kind=scout\nbackend=tmux\nwindow=fm-lab-skills:fm-sm\nharness=grok\nworktree=%s\n' "$LAB" > "$P/state/plain.meta"
printf 'done: report written\n' > "$P/state/plain.status"
OUT=$(bin/fm-crew-state.sh plain); printf '%s\n' "$OUT"; [[ $OUT = 'state: done'* ]]
printf '\nAll manual CLI scenarios completed; private tmux server and lab homes removed by EXIT trap.\n'
