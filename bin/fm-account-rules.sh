#!/usr/bin/env bash
# fm-account-rules.sh - the captain's approval of this home's Claude account rules.
#
# Usage:
#   fm-account-rules.sh status    show the rules and whether they are approved
#   fm-account-rules.sh approve   approve the current config/account-rules
#
# docs/configuration.md "Account rules (config/account-rules)" owns the
# contract.
# `approve` reads its confirmation from /dev/tty, never stdin.
# Exit status: 0 approved (or status printed), 1 refused or malformed, 2 usage.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"

FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RULES="$CONFIG/account-rules"

usage() {
  sed -n '4,6p' "$0" | sed 's/^# //' >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
[ -f "$RULES" ] || {
  echo "error: no account rules at $RULES" >&2
  exit 1
}
fm_account_rules_parse "$RULES" >/dev/null || exit 1
FINGERPRINT=$(fm_account_rules_fingerprint "$RULES") || exit 1

case "$1" in
status)
  cat "$RULES"
  if fm_account_rules_approved "$CONFIG" 2>/dev/null; then
    echo "approved: $FINGERPRINT"
  else
    echo "not approved: $FINGERPRINT"
  fi
  ;;
approve)
  if ! { exec 3<>/dev/tty; } 2>/dev/null; then
    echo "error: approving account rules needs the captain at a terminal; this process has none" >&2
    exit 1
  fi
  CODE=${FINGERPRINT:0:12}
  {
    printf 'Account rules at %s:\n\n' "$RULES"
    cat "$RULES"
    printf '\nFingerprint %s\nType %s to approve: ' "$FINGERPRINT" "$CODE"
  } >&3
  IFS= read -r ANSWER <&3 || ANSWER=
  if [ "$ANSWER" != "$CODE" ]; then
    echo "refused: the confirmation did not match; the rules stay unapproved" >&3
    exit 1
  fi
  printf '%s\n' "$FINGERPRINT" > "$RULES.approved.tmp" && mv "$RULES.approved.tmp" "$RULES.approved" || exit 1
  echo "approved: $FINGERPRINT" >&3
  ;;
*) usage ;;
esac
