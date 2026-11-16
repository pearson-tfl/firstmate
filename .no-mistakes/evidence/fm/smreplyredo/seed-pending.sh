#!/usr/bin/env bash
# Seed one delivered marked request to second mate "hibit" in the lab parent home.
set -u
WT=$1 LAB=$2
. "$WT/bin/fm-pending-reply-lib.sh"
corr=$(fm_pending_reply_create "$LAB" "$LAB/state" hibit "please confirm the alpha merge plan") || exit 1
fm_pending_reply_mark_delivered "$LAB/state" "$corr" || exit 1
printf '%s\n' "$corr"
