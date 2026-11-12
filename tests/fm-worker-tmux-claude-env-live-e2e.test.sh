#!/usr/bin/env bash
# Opt-in credentialed Claude live guard for config/worker-tmux-dir's Claude leg
# (bin/fm-spawn.sh header, "Worker tmux stand-in").
# Claude Code's Bash tool rebuilds PATH from its login-shell snapshot, so the
# stand-in export in the launch command does not reach it; the spawn adds a
# SessionStart hook that writes the same PATH line to CLAUDE_ENV_FILE, which the
# Bash tool sources after that snapshot. Both halves are vendor behaviour, so
# this guard proves them against the real installed Claude Code: it takes the
# exact hook a real spawn wrote, runs one prompt whose Bash tool reports
# `command -v tmux`, and requires the stand-in; a control run without the hook
# must NOT see the stand-in, so the pass cannot be vacuous.
# The spawn runs against a fake pane in an isolated home; Claude keeps its
# existing managed authentication. Two short prompts are submitted.
# Refresh docs/verification/runtime-backends.md ("Worker tmux stand-in through
# Claude's Bash tool") from this guard's output after a Claude Code upgrade.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_WORKER_TMUX_CLAUDE_LIVE claude

CLAUDE_BIN=$(type -P claude)
CLAUDE_VERSION=$("$CLAUDE_BIN" --version) || fail "could not read the installed Claude Code version"
note() { printf '# %s\n' "$1"; }
note "claude: $CLAUDE_VERSION"

TMP_ROOT=$(fm_test_tmproot fm-worker-tmux-claude-live)
STANDIN="$TMP_ROOT/standin"
mkdir -p "$STANDIN"
printf '#!/bin/sh\necho standin\n' > "$STANDIN/tmux"
chmod +x "$STANDIN/tmux"

HOME_DIR="$TMP_ROOT/home"
WT_DIR="$TMP_ROOT/wt"
FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake")
fm_test_spawn_home "$HOME_DIR" claude
fm_git_worktree "$TMP_ROOT/project" "$WT_DIR" wt-live
fm_test_spawn_brief "$HOME_DIR" tmux-claude-live
printf '%s\n' "$STANDIN" > "$HOME_DIR/config/worker-tmux-dir"
out=$(FM_FAKE_LAUNCH_LOG="$TMP_ROOT/launch.log" FM_FAKE_PANE_LOG="$TMP_ROOT/pane.log" \
  fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" tmux-claude-live "$TMP_ROOT/project" \
  --mode no-mistakes --yolo off) || fail "the spawn with worker-tmux-dir set failed: $out"
HOOK=$(jq -c '{hooks: {SessionStart: .hooks.SessionStart}}' "$WT_DIR/.claude/settings.local.json") \
  || fail "the spawned worker settings are not valid JSON"
[ "$HOOK" != '{"hooks":{"SessionStart":null}}' ] || fail "the spawn wrote no SessionStart hook"

PROBE_DIR="$TMP_ROOT/probe"
mkdir -p "$PROBE_DIR"
git -C "$PROBE_DIR" init -q
PROMPT='Run exactly this shell command with your Bash tool and reply with only its output, nothing else: command -v tmux'

ask() {  # <settings-json>
  (cd "$PROBE_DIR" && timeout 180 "$CLAUDE_BIN" -p "$PROMPT" --model haiku \
    --dangerously-skip-permissions --settings "$1" 2>&1)
}

with_hook=$(ask "$HOOK") || fail "claude $CLAUDE_VERSION: the run with the spawn's hook failed: $with_hook"
note "with hook: $with_hook"
assert_contains "$with_hook" "$STANDIN/tmux" \
  "claude $CLAUDE_VERSION: the Bash tool must resolve the stand-in once the spawn's SessionStart hook ran"
pass "claude $CLAUDE_VERSION: the spawn's SessionStart hook puts the stand-in first for the Bash tool"

control=$(ask '{"feedbackDrafts":"off"}') || fail "claude $CLAUDE_VERSION: the control run failed: $control"
note "control: $control"
assert_not_contains "$control" "$STANDIN/tmux" \
  "claude $CLAUDE_VERSION: without the hook the Bash tool must not see the stand-in, or this guard proves nothing"
pass "claude $CLAUDE_VERSION: the control run without the hook does not see the stand-in"
