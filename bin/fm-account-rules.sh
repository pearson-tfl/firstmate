#!/usr/bin/env bash
# fm-account-rules.sh - inspect and validate this home's Claude account rules.
# Usage: fm-account-rules.sh status
# Valid edits take effect on the next launch; no terminal approval is required.
# docs/configuration.md "Account rules" owns the format and ranking.
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
case "${1:-}" in
  -h|--help) printf 'Usage: fm-account-rules.sh status\n'; exit 0 ;;
esac
if [ "$#" -ne 1 ] || [ "$1" != status ]; then
  echo 'Usage: fm-account-rules.sh status' >&2
  exit 2
fi
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
RULES="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/account-rules"
[ -f "$RULES" ] || { echo "error: no account rules at $RULES" >&2; exit 1; }
fm_account_rules_parse "$RULES" >/dev/null || exit 1
cat "$RULES"
echo 'valid: applies to the next Claude launch'
