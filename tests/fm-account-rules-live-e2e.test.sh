#!/usr/bin/env bash
# Opt-in live guard for rules-based account selection through cswap
# (bin/fm-worker-account-lib.sh, "Rules-based Claude account selection").
#
# The selection's root comes from what the real `cswap run <num>` hands the
# `claude` it execs, and its account list from `cswap list --json`, so a fake
# can only restate the assumption written into it. This guard asks the real
# cswap and claude, under the operator's own HOME because that is where the
# cswap accounts live:
#   - the list parses as schemaVersion 1 and the rules pick an allowed account;
#   - the root the probe records for a non-default account is signed in, and
#     `claude auth status --json` there names the same email cswap lists for
#     that number;
#   - the default login's account records an empty root, so the launch unsets
#     CLAUDE_CONFIG_DIR and runs on the default login.
# The guard never runs `cswap switch`; it reads the default login before and
# after and fails if it moved.
#
# The served-account read keeps USER, because Claude keys its macOS Keychain
# lookup to it. It submits no prompt, but `cswap run` may refresh the chosen account's stored
# login over the network and prepares its profile, so it is opt-in:
#   FM_ACCOUNT_RULES_LIVE_E2E=1 FM_ACCOUNT_RULES_LIVE_ACCOUNT=<num> \
#     bash tests/fm-account-rules-live-e2e.test.sh
# where <num> is a cswap account that is not the default login. Run it after
# every cswap or Claude upgrade and before trusting the "Account rules through
# cswap" entry in docs/verification/runtime-backends.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_ACCOUNT_RULES_LIVE_E2E cswap claude jq perl
# shellcheck source=bin/fm-worker-account-lib.sh
. "$ROOT/bin/fm-worker-account-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-account-rules-live)
unset CLAUDE_CONFIG_DIR ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
NUM=${FM_ACCOUNT_RULES_LIVE_ACCOUNT:-}
[ -n "$NUM" ] || fail "set FM_ACCOUNT_RULES_LIVE_ACCOUNT to a cswap account number that is not the default login"

CSWAP_VERSION=$(cswap --version 2>/dev/null | head -1)
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
LIST=$(cswap list --json) || fail "cswap $CSWAP_VERSION: cswap list --json failed"
ACTIVE=$(printf '%s\n' "$LIST" | jq -r '.activeAccountNumber')
WANT_EMAIL=$(printf '%s\n' "$LIST" | jq -r --argjson n "$NUM" '.accounts[] | select(.number == $n) | .email')
[ -n "$WANT_EMAIL" ] || fail "cswap $CSWAP_VERSION: account $NUM is not in cswap list --json"
[ "$ACTIVE" != "$NUM" ] || fail "account $NUM is the default login; choose another for this guard"

# The rules pick: forbid every account but NUM, so the only allowed one wins.
mkdir -p "$TMP_ROOT/config"
printf '%s\n' "$LIST" | jq -r --argjson n "$NUM" \
  '"forbid " + ([.accounts[].number | select(. != $n) | tostring] | join(" "))' \
  > "$TMP_ROOT/config/account-rules"
fm_account_rules_fingerprint "$TMP_ROOT/config/account-rules" > "$TMP_ROOT/config/account-rules.approved"
PICKED=$(fm_account_rules_pick "$TMP_ROOT/config" live-project) || fail "cswap $CSWAP_VERSION: the rules could not pick from the real account list"
[ "$PICKED" = "$NUM" ] || fail "cswap $CSWAP_VERSION: the rules picked $PICKED, but only $NUM is allowed"
pass "cswap $CSWAP_VERSION: the real account list parses and the rules pick the one allowed account"

ROOT_DIR_FOR_NUM=$(fm_account_rules_profile "$NUM" claude) || fail "cswap $CSWAP_VERSION: cswap run $NUM did not hand claude a root"
[ -n "$ROOT_DIR_FOR_NUM" ] || fail "cswap $CSWAP_VERSION: a non-default account recorded the default login"
fm_worker_account_check claude "cswap:$NUM" "$ROOT_DIR_FOR_NUM" claude config/account-rules ||
  fail "claude $CLAUDE_VERSION: the root cswap prepared for account $NUM is not signed in"
SERVED=$(env -i HOME="$HOME" PATH="$PATH" USER="${USER:-}" LOGNAME="${LOGNAME:-}" TMPDIR="${TMPDIR:-/tmp}" CLAUDE_CONFIG_DIR="$ROOT_DIR_FOR_NUM" claude auth status --json 2>/dev/null </dev/null | jq -r '.email // empty')
[ "$SERVED" = "$WANT_EMAIL" ] ||
  fail "claude $CLAUDE_VERSION: account $NUM's root serves '${SERVED:-nothing}', not cswap's $WANT_EMAIL"
pass "cswap $CSWAP_VERSION, claude $CLAUDE_VERSION: account $NUM's root serves that account's own login"

DEFAULT_ROOT=$(fm_account_rules_profile "$ACTIVE" claude) || fail "cswap $CSWAP_VERSION: cswap run $ACTIVE did not launch claude"
[ -z "$DEFAULT_ROOT" ] || fail "cswap $CSWAP_VERSION: the default login's account recorded root '$DEFAULT_ROOT' rather than the default login"
pass "cswap $CSWAP_VERSION: the default login's account runs on the default login"

AFTER=$(cswap list --json | jq -r '.activeAccountNumber')
[ "$AFTER" = "$ACTIVE" ] || fail "the default login moved from $ACTIVE to $AFTER during the guard"
pass "the default login stayed on account $ACTIVE"
echo "# all fm-account-rules live tests passed"
