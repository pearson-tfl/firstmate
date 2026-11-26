#!/usr/bin/env bash
set -eu
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
ROOT=$PWD
LAB=$ROOT/.test-required-skills
. bin/fm-task-inbox-lib.sh
. bin/fm-pending-reply-lib.sh
. bin/fm-dod-lib.sh
export FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=2
expect_refused() {
  local rc=0
  "$@" || rc=$?
  printf 'exit=%s (expected refusal)\n' "$rc"
  [ "$rc" -ne 0 ]
}
parent=$LAB/parent
mate=$LAB/mate
state=$parent/state
mkdir -p "$state" "$mate/state"
printf 'sm\n' > "$mate/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$mate/.fm-secondmate-parent"
echo 'SCENARIO intake: scaffold repeated skill flags into generated brief'
FM_HOME=$parent bash bin/fm-brief.sh skill-scout synthetic --scout --required-skill /poteto-mode --required-skill tdd --required-skill tdd
sed -n '/# Required skills/,$p' "$parent/data/skill-scout/brief.md"
[ "$(fm_required_skills_from_text "$(cat "$parent/data/skill-scout/brief.md")")" = poteto-mode,tdd ]
expect_refused env FM_HOME="$parent" bash bin/fm-brief.sh invalid synthetic --scout --required-skill 'bad name'
echo 'SCENARIO request: original acknowledgement plus automatic recovery preserves requirements'
body="Improve synthetic wiki"$'\n'"$(fm_required_skills_section poteto-mode request)"
corr=$(fm_pending_reply_create "$parent" "$state" sm "$body")
fm_pending_reply_mark_delivered "$state" "$corr"
fm_pending_reply_embed_corr "$body" "$corr" req
rec=$(fm_task_inbox_write "$state" sm "$req")
mv "$rec" "$state/sm.inbox/handled/"
recovery=$(fm_pending_reply_recovery_message "$(fm_pending_reply_path "$state" "$corr")")
fm_task_inbox_write "$state" sm "$recovery" >/dev/null
printf 'Recovery required skills: %s\n' "$(fm_required_skills_from_text "$recovery")"
[ "$(fm_pending_reply_mate_required_skills "$state/sm.inbox" "$corr")" = poteto-mode ]
expect_refused env FM_HOME="$mate" bash bin/fm-secondmate-report.sh done 'synthetic wiki ready'
echo 'SCENARIO empty helper payloads cannot unlock done'
FM_HOME=$mate bash bin/fm-secondmate-report.sh working 'skill-start poteto-mode path=/synthetic/SKILL.md route='
FM_HOME=$mate bash bin/fm-secondmate-report.sh working 'skill-shaped poteto-mode:'
expect_refused env FM_HOME="$mate" bash bin/fm-secondmate-report.sh done 'synthetic wiki ready'
# Independent request so malformed recipient first lines above are not erased.
body="Second synthetic request"$'\n'"$(fm_required_skills_section tdd request)"
corr2=$(fm_pending_reply_create "$parent" "$state" sm "$body")
fm_pending_reply_mark_delivered "$state" "$corr2"
fm_pending_reply_embed_corr "$body" "$corr2" req
fm_task_inbox_write "$state" sm "$req" >/dev/null
echo 'SCENARIO correlated ordered proof after infrastructure permits secondmate and parent completion'
printf 'note [source=firstmate] [corr=%s]: synthetic launch warning\n' "$corr2" >> "$state/sm.status"
FM_HOME=$mate bash bin/fm-secondmate-report.sh working "$corr2" 'skill-start tdd path=/synthetic/tdd/SKILL.md route=exercise CLI refusal before completion'
expect_refused env FM_HOME="$mate" bash bin/fm-secondmate-report.sh done "$corr2" 'ready without shaped proof'
FM_HOME=$mate bash bin/fm-secondmate-report.sh working "$corr2" 'skill-shaped tdd: refusal was observed before adding the completion proof'
FM_HOME=$mate bash bin/fm-secondmate-report.sh done "$corr2" 'synthetic CLI exercise finished'
fm_pending_reply_try_resolve "$state" "$corr2"
echo 'Parent accepted correlated completion'
cat "$state/sm.status"
echo 'SCENARIO acknowledgement reopens and escalates; late worker proofs remain refused'
rec=$(fm_task_inbox_write "$state" worker "$(fm_required_skills_section tdd task)")
printf 'kind=scout\nrequired_skills=tdd\n' > "$state/worker.meta"
printf 'working: ordinary recipient work\nworking: skill-start tdd path=/synthetic/tdd/SKILL.md route=late\nworking: skill-shaped tdd: late tests\n' > "$state/worker.status"
mv "$rec" "$state/worker.inbox/handled/"
action=$(fm_task_inbox_due_action "$state" worker); echo "$action"; [ "${action%% *}" = ring ]
fm_task_inbox_record_ring "$state" worker "$rec"
fm_task_inbox_record_ring "$state" worker "$rec"
action=$(fm_task_inbox_due_action "$state" worker); echo "$action"; [ "${action%% *}" = escalate ]
expect_refused fm_dod_accept_ship_done scout '' '' '' 'done: synthetic report' "$state" worker "$state/worker.meta"
echo 'SCENARIO infrastructure diagnostics do not invalidate ordered worker proofs'
printf 'failed [source=firstmate]: synthetic failed launch\nnote [source=firstmate]: synthetic exclusion warning\nworking: skill-start tdd path=/synthetic/tdd/SKILL.md route=CLI regression first\nworking: skill-shaped tdd: CLI regression guided work\n' > "$state/worker.status"
mv "$rec" "$state/worker.inbox/handled/"
action=$(fm_task_inbox_due_action "$state" worker); echo "$action"; [ "$action" = quiet ]
fm_dod_accept_ship_done scout '' '' '' 'done: synthetic report' "$state" worker "$state/worker.meta"
echo 'Worker completion accepted'
echo 'SCENARIO unrequired request retains ordinary completion behavior'
corr3=$(fm_pending_reply_create "$parent" "$state" plain 'plain synthetic audit')
fm_pending_reply_mark_delivered "$state" "$corr3"
fm_pending_reply_embed_corr 'plain synthetic audit' "$corr3" req
fm_task_inbox_write "$state" plain "$req" >/dev/null
printf 'plain\n' > "$mate/.fm-secondmate-home"
FM_HOME=$mate bash bin/fm-secondmate-report.sh done 'plain audit finished'
fm_pending_reply_try_resolve "$state" "$corr3"
cat "$state/plain.status"
echo 'All live CLI and durable-state scenarios completed'
