# Orca runtime backend

Orca is an experimental backend in which an Orca runtime - the macOS app, or a headless Orca server on Linux - owns both the task worktree and terminal endpoint.
The crewmate harness remains the agent process launched inside that endpoint.
Firstmate agents load [`firstmate-orca`](../.agents/skills/firstmate-orca/SKILL.md) before operating or recovering this backend.

## How each claim is proved

Each behavioral claim below ends with one of these marks.

- **(real Orca)** - exercised against a real Orca runtime; [`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the date, version, commands, and output.
- **(fake Orca)** - pinned only by the stand-in `orca` in the regression entry points below; not yet exercised on real Orca.
- **(Orca help)** - read from the real `orca` CLI's own help text; not exercised.
- **(code)** - read from Firstmate's own scripts, which own the exact behavior; not exercised on real Orca.
- **(reported)** - recorded by an earlier Orca evaluation and not re-checked.

No real agent has yet run a whole Firstmate task on Orca: `fm-spawn.sh`, `fm-send.sh`, and `fm-teardown.sh` have not run end to end against real Orca.
The [whole-task proof](verification/runtime-backends.md#orca-whole-task-proof) section is where that proof is recorded once it runs.

## Setup

Pick Orca when you already use Orca and want Orca-managed worktrees and terminals instead of Treehouse plus a session multiplexer.
Orca is explicit-only and does not support secondmate spawns (code).
Firstmate's Orca backend has run its adapter building blocks only on macOS (real Orca); on Linux only the CLI lookup and readiness check have run against a paired Orca server (real Orca).

Prerequisites:

- An Orca runtime on the same machine as the Firstmate home, running and ready: `/Applications/Orca.app` on macOS, or a paired Orca server on Linux.
- The Orca CLI: `orca` on PATH (macOS), `orca-ide` on PATH (Linux, where GNOME's screen reader owns `orca`), or the `~/.orca/cli/bin/orca-ide` that a paired Orca server's install leaves off PATH.
  `bin/backends/orca.sh` (`fm_backend_orca_bin`) owns that lookup order.
  Orca 1.4.271 ships the macOS CLI inside the app at `/Applications/Orca.app/Contents/Resources/bin/orca`, and the install checked reached it through a link at `/usr/local/bin/orca` (real Orca).
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select Orca with local `config/backend` containing `orca`, `FM_BACKEND=orca` for one launch, or an explicit request to Firstmate.
It is never auto-detected.

Before any spawn mutates repository state, Firstmate requires `orca status --json` to report `reachable=true` and `state="ready"` (real Orca).
Firstmate does not check Orca's version (code), although Orca reports one through `orca --version` and `result.runtime.appVersion` (real Orca).
Orca updates often, so rerun the [real-Orca checks](verification/runtime-backends.md#orca) after an update rather than assuming earlier evidence still holds.
The first task for a project registers that repository with `orca repo add --path` when needed (real Orca).
No manual repository registration is required.

Open the Orca app to watch a task's terminal.
Routine supervision uses the recorded endpoint through `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'`.
The adapter sends text and Enter in one send and sends Ctrl-C (real Orca).
Its separate Enter key, which the submit retries use, sends empty text with Enter (code).
Orca itself writes raw control bytes such as Escape and Ctrl-U when text is sent without Enter (real Orca).
The adapter sends Escape and Ctrl-U as keys through that path, as raw control bytes (code).
The adapter's typed steer writes its text without Enter, so control bytes inside a steer's text pass through (code).

An Orca terminal opens your normal login shell in your real home folder with your personal shell startup files, and a variable set in the environment Orca starts from reaches every new terminal (real Orca).
`config/launch-env-allowlist` alone therefore cannot scope worker credentials on Orca, because allowlisted values resolve from the Orca terminal's own environment.
To scope worker credentials, configure an [Orca environment source](configuration.md#orca-environment-source-configlaunch-env-vault-configlaunch-env-tmux-session): a vault, with no tmux, or a tmux session.

## Task shape and metadata

Each task has one Orca-managed git worktree and one Orca terminal.
Orca creates the worktree as a linked git worktree on a new branch, listed by `git worktree list` (real Orca).
`fm-spawn.sh` does not call Treehouse for Orca tasks.
The normal isolation and unlanded-work refusal rules still apply.

```text
backend=orca
window=fm-<id>
terminal=<orca terminal handle>
orca_worktree_id=<orca repo id>::<absolute worktree path>
worktree=<absolute Orca worktree path>
```

`window=` remains the caller-facing Firstmate alias.
`terminal=` and `orca_worktree_id=` are the backend authority used by operation and cleanup paths.
Orca returns `orca_worktree_id=` as that composite of the Orca repo id and the worktree path (real Orca), and cleanup validation requires both halves rather than treating the value as a simple name (fake Orca).

## Current lifecycle and safety

Spawn registers the repository, creates an independent worktree, reuses only the verified `result.terminal.handle` returned by Orca or creates a terminal explicitly, installs harness hooks, records metadata, and launches the selected harness.
Registration, worktree creation, and terminal creation work against real Orca (real Orca); the full spawn, including hooks and the harness launch, has not run there.
Exact command flags and response parsing are owned by `bin/backends/orca.sh` and script help.

Every capture reads the drawn screen with `orca terminal read --screen`, never the accumulated output stream (fake Orca).
That stream is a bounded tail of everything printed, not the drawn screen: it returned lines a `clear` had already removed and dropped spaces a shell prompt drew by moving the cursor (real Orca).
Orca's own help calls that stream read unsuitable for verifying rendered output (Orca help).
A read Orca reports as anything other than the drawn screen, including `screen-unavailable`, is refused rather than used, while the terminal-exists probe uses a plain read so an unrenderable screen does not mark a live terminal gone (fake Orca).
The drawn screen has no scrollback, and Orca omits its blank rows, so a capture longer than the screen returns only the screen (real Orca).
The composer read declares those omitted blank rows to the shared classifier (`blanks=elided` in `bin/fm-composer-lib.sh`), so a known agent footer such as `? for shortcuts` that sat one blank row below an empty composer does not make it read stale, while a shell prompt or transcript below a stale composer still does; the steering inbox reads a held composer's text with the same declaration (fake Orca).
Without a row limit that read is the viewport, so Orca serves the viewport-only read the Kimi trust gate and the interrupt screen checks require (fake Orca).
An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and only its best-effort constant doorbell passes through Orca's submit machinery (fake Orca).
On the typed plane, `fm-send.sh` verifies composer clearance through the fleet-wide classifier in `bin/fm-composer-lib.sh`, retrying Enter without retyping when a slash popup first fills an argument placeholder (fake Orca).
The composer read is the bottom rows of the drawn screen, so a stale startup banner cannot compete with the bottom-anchored composer (fake Orca); no real agent's composer has yet been classified on Orca.
A bare shell row is `unknown`, not an empty agent composer, and plain-text captures degrade a glyph row carrying trailing text to `unknown` rather than a false `pending` (fake Orca).
The watcher has no native Orca busy signal, so each harness adapter's semantic lifecycle supplies worker state (code).
Grok alone retains its isolated rendered-tail fallback (code).

Cleanup keeps all shared Firstmate safety checks.
A scout still requires its report and completed decision inventory.
A ship still refuses dirty or unlanded work.
Before release, cleanup resolves the recorded Orca worktree id and verifies its path matches the recorded worktree path (fake Orca).
A missing, unreadable, or mismatched identity preserves metadata and stops rather than deleting anything (fake Orca).
After those checks, Firstmate closes the exact terminal and releases the exact worktree with Orca's worktree command.
Closing an Orca terminal ends the process running in it and Orca answers `ptyKilled: true` (real Orca), but Firstmate does not read that answer or re-read the terminal after the close (code).
The release removes the worktree folder and keeps the task branch (real Orca).
It never raw-deletes an Orca worktree.
A close the CLI never attempted, because `orca` is not on the path, stops cleanup with the metadata intact even under `--force`: removing those records would leave nothing on disk naming a terminal that may still be live.
Reinstall the CLI and rerun; [`verification/runtime-backends.md`](verification/runtime-backends.md) "Endpoint close" owns what this arm can and cannot prove about its own close.

The Orca desktop app kept its terminals when the app itself restarted (real Orca).
After a headless Orca runtime restarted, it refused the old terminal handles as stale (real Orca), and after a reboot every agent is gone (reported).
Firstmate cannot relaunch an agent on Orca (code), so a task whose terminal ended needs manual recovery.

## Active limits

- The backend is explicit-only.
- The Orca runtime must share the Firstmate home's filesystem, because spawn and cleanup check the worktree on local disk (code).
  To run lanes on a paired Orca server, run the Firstmate home on that server's machine; it drives that runtime through its local CLI, which is the same runtime the paired client reaches (real Orca).
  Pointing a home at another machine's runtime with `--environment` or `ORCA_ENVIRONMENT` is unsupported.
- The Orca runtime must be running and report ready.
- Secondmate spawns are unsupported (code).
- An interrupt is reported delivered with its cancellation unconfirmed unless the harness keeps its own confirmation record (muse confirms from its session log), and an interrupt for a harness that must read its screen between or after presses (Devin and Command Code) is refused because Orca has no verified viewport read (code); [`agent-control.md`](agent-control.md) owns the per-backend control matrix.
- Orca has no recovery-grade agent-state classifier, so `exit` and `relaunch` refuse (code).
- Cortex and Command Code are refused because Orca supplies no pane identity for their composers (code).
- Firstmate checks readiness, not Orca's version (code).
- Only the verified terminal-handle and worktree result fields are accepted; speculative response shapes are rejected (fake Orca).
- Orca's linked worktree has the shape the spawn-time Claude workspace-trust check in `bin/fm-claude-trust.sh` requires (real Orca), but that check has not run against an Orca worktree.
- No real agent has run a whole task on Orca.

## Regression entry points

```sh
tests/fm-backend-orca.test.sh
tests/fm-backend-orca-live-safety.test.sh
tests/fm-spawn-orca-worktree.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
tests/fm-teardown-endpoint-safety.test.sh
```

These run against the stand-in `orca`; [`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the real-Orca evidence.
After an Orca update, `FM_ORCA_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-backend-orca-live-e2e.test.sh` re-proves the adapter against a disposable Orca runtime; [`verification/runtime-backends.md`](verification/runtime-backends.md#real-orca-lane) records its state.
