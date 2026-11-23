#!/usr/bin/env bash
# Disposable Orca CLI emulator: terminals are panes on a private tmux socket.
# --screen reads the rendered pane (blank rows omitted, as real Orca 1.4.271 does);
# without --screen it replays the accumulated output stream with escapes stripped.
set -u
EMU=${FM_ORCAEMU:?}
T() { TMUX_TMPDIR="$EMU/tmux" tmux -L fm-orcaemu "$@"; }
echo "orca $*" >> "$EMU/calls.log"
[ "${1:-}" = status ] && { echo '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready","appVersion":"emu"}}}'; exit 0; }
[ "${1:-} ${2:-}" = "terminal read" ] || [ "${1:-} ${2:-}" = "terminal send" ] || { echo '{"ok":false,"error":{"message":"emu: unsupported"}}'; exit 1; }
verb=$2; shift 2
term= screen=0 limit= text= enter=0
while [ $# -gt 0 ]; do case $1 in
  --terminal) term=$2; shift 2;; --screen) screen=1; shift;; --limit) limit=$2; shift 2;;
  --text) text=$2; shift 2;; --enter) enter=1; shift;; --json) shift;; *) shift;; esac; done
T has-session -t "$term" 2>/dev/null || { echo '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}'; exit 1; }
if [ "$verb" = send ]; then
  [ -n "$text" ] && T send-keys -t "$term" -l "$text"
  [ "$enter" = 1 ] && T send-keys -t "$term" Enter
  echo '{"ok":true,"result":{"send":{"handle":"'"$term"'","accepted":true}}}'; exit 0
fi
mode=$(cat "$EMU/mode" 2>/dev/null || echo normal)
if [ "$screen" = 1 ] && [ "$mode" = normal ]; then
  rows=$(T capture-pane -p -t "$term" | grep -v '^[[:space:]]*$'); src=screen
else
  rows=$(perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g; s/\e[()][A-Z0-9]//g; s/\r//g' "$EMU/$term.stream" | grep -v '^[[:space:]]*$'); src=stream
  [ "$screen" = 1 ] && src=$mode
fi
[ -n "$limit" ] && rows=$(printf '%s\n' "$rows" | tail -n "$limit")
printf '%s\n' "$rows" | SRC=$src node -e '
const rows=require("fs").readFileSync(0,"utf8").replace(/\n$/,"").split("\n");
const t={tail:rows,status:"running"}; if(process.env.SRC!=="legacy") t.source=process.env.SRC;
process.stdout.write(JSON.stringify({ok:true,result:{terminal:t}})+"\n");'
