#!/usr/bin/env bash
# tests/fm-composer-claude-suggestion-live-e2e.test.sh - live guard for the
# monochrome prompt-suggestion read (live-harness-optin family).
#
# Under NO_COLOR, Claude Code draws its prompt suggestion with no dim run, so
# only the cursor column tells it from typing (fm_composer_cursor_at_text_start
# in bin/fm-composer-lib.sh). That is a vendor-rendered signal, so this guard
# proves it against the REAL installed claude: it launches claude twice in an
# isolated tmux server, once under NO_COLOR=1 FORCE_COLOR=0 and once in colour,
# submits one prompt to each so a real suggestion appears, and requires the
# real fm_tmux_composer_state to read the suggestion `empty` and real typed
# text `pending` in both panes. A failure names the harness version.
#
# Run explicitly with FM_CLAUDE_SUGGESTION_LIVE=1; it submits prompts, so it
# spends model tokens. A suggestion that never appears is reported as a
# failure naming the version, never a pass. Refresh
# docs/verification/runtime-backends.md ("Composer classification matrix")
# from its output after any Claude Code upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_SUGGESTION_LIVE tmux claude

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCKET="fm-csugg-live-$$"
SESSION=csugg
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-csugg-live.XXXXXX")
REAL_TMUX=$(command -v tmux)
CLAUDE_BIN=$(command -v claude)
VERSION=$("$CLAUDE_BIN" --version 2>/dev/null | head -1)
MODEL=${FM_CLAUDE_SUGGESTION_MODEL:-haiku}

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT
fail() { printf 'not ok - claude %s: %s\n' "$VERSION" "$1" >&2; exit 1; }
pass() { printf 'ok - claude %s: %s\n' "$VERSION" "$1"; }

mkdir -p "$LAB/shim" "$LAB/wt"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

t() { "$REAL_TMUX" -L "$SOCKET" "$@"; }
composer_row() { t capture-pane -p -t "$SESSION:$1" | grep '❯' | tail -1; }
cursor_x() { t display-message -p -t "$SESSION:$1" '#{cursor_x}'; }

# A guard run from inside a Claude session must not hand its session markers to
# the child, which then runs as a nested session; prompt suggestions are forced
# on for this run.
launch() {  # <window> <env-args...>
  local win=$1
  shift
  t new-window -d -t "$SESSION:" -n "$win" -c "$LAB/wt" -- \
    env -u TMUX -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
    -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
    -u CLAUDE_PID -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_EXECPATH -u AI_AGENT \
    "$@" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=true \
    "$CLAUDE_BIN" --model "$MODEL" --dangerously-skip-permissions \
    || fail "could not launch $win"
}

wait_for() {  # <window> <pane-text> <tries>
  local i=0
  while [ "$i" -lt "$3" ]; do
    t capture-pane -p -t "$SESSION:$1" 2>/dev/null | grep -qF "$2" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

t new-session -d -s "$SESSION" -x 160 -y 45 -c "$LAB/wt"
launch mono -u NO_COLOR -u FORCE_COLOR NO_COLOR=1 FORCE_COLOR=0
launch colour -u NO_COLOR -u FORCE_COLOR

for win in mono colour; do
  # A fresh directory raises the folder-trust dialog; its second option trusts.
  if wait_for "$win" 'trust this folder' 30; then
    t send-keys -t "$SESSION:$win" Down
    sleep 0.3
    t send-keys -t "$SESSION:$win" Enter
  fi
  wait_for "$win" '❯' 30 || fail "$win: no composer appeared"
done

# Claude chooses whether to offer a suggestion, so each pane gets up to three
# prompts that invite a follow-up, each with a minute for the suggestion.
PROMPTS=('Write notes.txt holding a three-item todo list for a tiny Python CLI, then stop.'
  'Read notes.txt and say which item I should start with. One sentence.'
  'Name the next step after that one. One sentence.')
suggestion_ready() {  # <window>
  row=$(composer_row "$1")
  fm_composer_normalize_spaces_var row
  cx=$(cursor_x "$1")
  case "$row" in '❯ '?*) [ "$cx" = 2 ] ;; *) return 1 ;; esac
}

for win in mono colour; do
  row='' cx='' found=0
  for prompt in "${PROMPTS[@]}"; do
    t send-keys -t "$SESSION:$win" -l "$prompt"
    sleep 0.5
    t send-keys -t "$SESSION:$win" Enter
    sleep 5
    i=0
    while [ "$i" -lt 60 ]; do
      suggestion_ready "$win" && { found=1; break; }
      sleep 1
      i=$((i + 1))
    done
    [ "$found" = 1 ] && break
  done
  [ "$found" = 1 ] || fail "$win: no prompt suggestion appeared after ${#PROMPTS[@]} prompts (last row [$row], cursor_x $cx)"
  if [ "$win" = mono ]; then
    t capture-pane -e -p -t "$SESSION:$win" | grep '❯' | tail -1 | grep -q $'\033\\[2m' \
      && fail "mono: the suggestion carries a dim run, so NO_COLOR did not reach claude and this case proves nothing"
  fi
  verdict=$(fm_tmux_composer_state "$SESSION:$win")
  [ "$verdict" = empty ] || fail "$win: a real suggestion [$row] with the cursor at its start read $verdict, not empty"
  pass "$win: a real prompt suggestion reads empty"

  t send-keys -t "$SESSION:$win" -l 'fix the bug'
  sleep 1
  [ "$(cursor_x "$win")" -gt 2 ] || fail "$win: typing did not move the cursor past the text start"
  verdict=$(fm_tmux_composer_state "$SESSION:$win")
  [ "$verdict" = pending ] || fail "$win: real typed text read $verdict, not pending"
  pass "$win: real typed text reads pending"
  t send-keys -t "$SESSION:$win" C-u
done
