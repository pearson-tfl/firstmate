# fm-orca-claude-pin.sh - resume-time Claude pin for Orca terminals.
#
# Sourced from the login-shell startup file when ORCA_TERMINAL_HANDLE is set.
# Reads the pin record Firstmate wrote for this working directory and exports
# CLAUDE_CONFIG_DIR to that root so Orca's claude wrapper passes through
# (CLAUDE_CONFIG_DIR differs from the injected managed profile).
# Outside Orca, or when no pin record exists, this file changes nothing.
#
# Back out: remove the source line from the login-shell startup file.
# bin/fm-worker-account-lib.sh owns writing and clearing the record.

case ${ORCA_TERMINAL_HANDLE-} in
'') return 0 2>/dev/null || true ;;
esac

_fm_orca_claude_pin_state=${XDG_STATE_HOME:-${HOME:-}/.local/state}/firstmate/orca-claude-pin
_fm_orca_claude_pin_cwd=$PWD
if [ -d "$PWD" ]; then
  _fm_orca_claude_pin_cwd=$(pwd -P 2>/dev/null) || _fm_orca_claude_pin_cwd=$PWD
fi
_fm_orca_claude_pin_key=
if command -v shasum >/dev/null 2>&1; then
  _fm_orca_claude_pin_key=$(printf '%s' "$_fm_orca_claude_pin_cwd" | shasum -a 256 | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  _fm_orca_claude_pin_key=$(printf '%s' "$_fm_orca_claude_pin_cwd" | sha256sum | awk '{print $1}')
fi
_fm_orca_claude_pin_file=$_fm_orca_claude_pin_state/$_fm_orca_claude_pin_key
if [ -n "$_fm_orca_claude_pin_key" ] && [ -r "$_fm_orca_claude_pin_file" ]; then
  _fm_orca_claude_pin_root=$(sed -n '1p' "$_fm_orca_claude_pin_file")
  case $_fm_orca_claude_pin_root in
  /*) export CLAUDE_CONFIG_DIR=$_fm_orca_claude_pin_root ;;
  esac
fi
unset _fm_orca_claude_pin_state _fm_orca_claude_pin_cwd _fm_orca_claude_pin_key \
  _fm_orca_claude_pin_file _fm_orca_claude_pin_root
