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

Real agents have run whole Firstmate tasks on Orca in daily use, from `fm-spawn.sh` through `fm-send.sh` steering to landing and `fm-teardown.sh` cleanup, on a Linux paired Orca server (real Orca).
The [whole-task proof](verification/runtime-backends.md#orca-whole-task-proof) section records it.

## Setup

Pick Orca when you already use Orca and want Orca-managed worktrees and terminals instead of Treehouse plus a session multiplexer.
Orca is explicit-only (code); a second mate runs in a terminal opened in its home ([Second-mate seats](#second-mate-seats)).
Firstmate's Orca backend has run whole tasks with real agents on a Linux paired Orca server, and its adapter building blocks on macOS (real Orca).

Prerequisites:

- An Orca runtime on the same machine as the Firstmate home, running and ready: `/Applications/Orca.app` on macOS, or a paired Orca server on Linux.
- The Orca CLI: `orca` on PATH (macOS), `orca-ide` on PATH (Linux, where GNOME's screen reader owns `orca`), or the `~/.orca/cli/bin/orca-ide` that a paired Orca server's install leaves off PATH.
  Firstmate tries `orca-ide` on PATH, then `~/.orca/cli/bin/orca-ide`, then a bare `orca` on PATH last, so GNOME's screen reader never masks an Orca install.
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
Orca also sets `CLAUDE_CONFIG_DIR` in its terminals to its own managed Claude folder, so a Claude launched there without a Firstmate account pin uses that folder's sign-in rather than the home's (real Orca).
To scope worker credentials, configure an [Orca environment source](configuration.md#orca-environment-source-configlaunch-env-vault-configlaunch-env-tmux-session): a vault, with no tmux, or a tmux session.

## Shell ownership

That login shell runs your startup files before Firstmate types anything, so a startup rule such as `exec tmux attach` can turn a new terminal into a client of another session whose pane would receive the launch keys (real Orca).
Before its first key, spawn checks terminal placement, listed agents, and screen shape; it accepts a candidate shell only when all of these checks pass, and otherwise refuses, typing nothing (fake Orca):

- `orca terminal show` places the terminal in the task worktree or secondmate home entry selected by spawn.
- `orca agent list` names no agent on the terminal's pane.
- The drawn screen reads the same twice in a row, has one or two nonblank rows, and shows no tmux status or session-picker row, no box-drawn chrome, and no agent composer the shared classifier recognizes.

These checks cannot prove the foreground process is a shell: Orca reports no process for the terminal, so a tmux client with its status row off whose attached pane shows only a bare prompt would pass (code).
A prompt the shared classifier reads as an agent composer (a lone `❯`, as some themes draw) or one drawn over more than two nonblank rows refuses (code).

A refused spawn closes that terminal and releases the worktree it just created, like any other failed Orca spawn (code).
`bin/backends/orca.sh` (`fm_backend_orca_fresh_shell`) owns those checks and the screen-read wait.
The real-Orca test lane's nonce prompt cannot be used here, because spawn chooses neither the shell nor the prompt Orca starts.
Orca 1.4.271's `orca terminal create` has no option to set or clear a terminal's environment, so spawn cannot open a terminal without inherited `SSH_*` or `TMUX` (Orca help): `--command` is typed into the login shell after its startup files ran, and `--shell` applies only on Windows hosts.
Keep those variables out of the environment the Orca runtime starts from, since every terminal inherits it.

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

Spawn registers the repository, creates an independent worktree, reuses only the verified `result.terminal.handle` returned by Orca or creates a terminal explicitly, passes the [shell-ownership check](#shell-ownership), installs harness hooks, records metadata, and launches the selected harness.
Registration, worktree creation, and terminal creation work against real Orca (real Orca); the full spawn, including hooks and the harness launch, has not run there.
Exact command flags and response parsing are owned by `bin/backends/orca.sh` and script help.

Every capture reads the drawn screen with `orca terminal read --screen`, never the accumulated output stream (fake Orca).
That stream is a bounded tail of everything printed, not the drawn screen: it returned lines a `clear` had already removed and dropped spaces a shell prompt drew by moving the cursor (real Orca).
Orca's own help calls that stream read unsuitable for verifying rendered output (Orca help).
A read Orca reports as anything other than the drawn screen, including `screen-unavailable`, is refused rather than used, while the terminal-exists probe uses a plain read so an unrenderable screen does not mark a live terminal gone (fake Orca).
The drawn screen has no scrollback, and Orca omits its blank rows, so a capture longer than the screen returns only the screen (real Orca).
The composer read declares those omitted blank rows to the shared classifier (`blanks=elided` in `bin/fm-composer-lib.sh`), so a known agent footer such as `? for shortcuts` that sat one blank row below an empty composer does not make it read stale, while a shell prompt or transcript below a stale composer still does; the steering inbox reads a held composer's text with the same declaration (fake Orca).
Without a row limit that read is the viewport, so Orca serves the viewport-only read the Kimi trust gate requires (fake Orca); the interrupt screen checks do not rely on it, because it has never been verified with a real Devin or Command Code on it (code).
An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and only its best-effort constant doorbell passes through Orca's submit machinery (fake Orca).
On the typed plane, `fm-send.sh` verifies composer clearance through the fleet-wide classifier in `bin/fm-composer-lib.sh`, retrying Enter without retyping when a slash popup first fills an argument placeholder (fake Orca).
The composer read is the bottom rows of the drawn screen, so a stale startup banner cannot compete with the bottom-anchored composer (fake Orca); no real agent's composer has yet been classified on Orca.
A bare shell row is `unknown`, not an empty agent composer, and plain-text captures degrade a glyph row carrying trailing text to `unknown` rather than a false `pending` (fake Orca).
Grok alone retains its isolated rendered-tail fallback (code).

Cleanup keeps all shared Firstmate safety checks.
A scout still requires its report and completed decision inventory.
A ship still refuses dirty or unlanded work.
Before release, cleanup resolves the recorded Orca worktree id and verifies its path matches the recorded worktree path (fake Orca).
A missing, unreadable, or mismatched identity preserves metadata and stops rather than deleting anything (fake Orca).
After those checks, Firstmate closes the exact terminal and releases the exact worktree with Orca's worktree command.
Closing an Orca terminal ends the process running in it, and a re-read then reports the terminal `exited` (real Orca).
Firstmate re-reads the terminal after its close and, unless Orca reports it `exited`, stops cleanup with the metadata intact and names what it read: a terminal still running, a stale handle, or no answer (fake Orca).
A stale handle is not treated as closed, because after an Orca restart the terminal may live on under a new handle.
The release keeps the task branch unless asked to delete it (real Orca).
Firstmate asks only when the landed-work test passed, so a scout, a `--force` discard, or a missing worktree keeps the branch (real Orca for a landed and a forced ship).
Orca preserves a branch it cannot prove merged (real Orca); [checked close and branch choice](verification/runtime-backends.md#orca-checked-close-and-branch-choice) records the deletion cases exercised.
Firstmate names a branch Orca kept that way (fake Orca).
It never raw-deletes an Orca worktree.
A close the CLI never attempted, because no Orca CLI was found, stops cleanup with the metadata intact even under `--force`: removing those records would leave nothing on disk naming a terminal that may still be live.
Reinstall the CLI and rerun; [`verification/runtime-backends.md`](verification/runtime-backends.md) "Endpoint close" owns what this arm can and cannot prove about its own close.

The Orca desktop app kept its terminals when the app itself restarted (real Orca).
After a headless Orca runtime restarted, it refused the old terminal handles as stale (real Orca), and after a reboot every agent is gone (reported).
A task whose terminal ended, including in an Orca restart, is recovered with `fm-control.sh <task> relaunch`, which opens a fresh terminal in the same worktree ("Exit and relaunch" below).

## Second-mate seats

A second mate on Orca runs in one Orca terminal opened in its home rather than in a task worktree (fake Orca).
Spawn registers the home as an Orca folder project, git or not, when Orca does not know it yet, opens the terminal in that project's root entry, and records the entry's id, `<repo id>::<home>`, as `orca_worktree_id=` (fake Orca).
That registration, the root entry, a terminal opening in the home with `ORCA_TERMINAL_HANDLE` and `ORCA_WORKTREE_ID` set, and Orca refusing to delete a project root were [exercised on a disposable runtime](verification/runtime-backends.md#orca-second-mate-home-terminal) (real Orca).
Spawn refuses when Orca resolves the home to an entry at another path, and the new terminal passes the same [shell-ownership check](#shell-ownership) as a task terminal before any key (fake Orca).
A refused seat spawn closes only that terminal (code).
Retiring the second mate closes its terminal and never asks Orca to remove the home's entry (fake Orca).
Steering doorbells reach the seat through the recorded terminal with the same agent-state, busy, and composer checks as any Orca worker (code).
The recovery sweep relaunches a seat that reads missing only when Orca reports its terminal exited, or still lists the home's entry with no live terminal in it, because the desktop app re-attaches terminals under new handles after a restart (code).

Away mode accepts a seat running in an Orca terminal; [supervisor backend configuration](configuration.md#away-mode-supervisor-backend-fm_supervisor_backend--fm_supervisor_target) owns endpoint discovery and its nested-multiplexer precedence (fake Orca).
The away daemon then injects through Orca's agent listing for busy and the shared composer classifier, as for any Orca endpoint (code).
Away mode's `start` has no hidden-terminal launch on Orca, so the daemon runs there only as a harness's own tracked background job (`start-native`) (code).
The host hand-back retry in `bin/fm-supervision-handoff.sh` types into the seat's Orca terminal only when Orca lists an idle agent on it, the session holds its terminal's foreground, and the composer reads empty; like its tmux path, it stays inert until #5138 restores session ownership (code).

## Agent state

Agent state and busy come from Orca itself, not from the screen: `orca agent list` names each terminal agent on its pane with a state that Orca's status hooks report - working, waiting, blocked, or done - from the agent's first report until it ends (real Orca).
The adapter matches the recorded terminal's pane through `orca terminal show` and reads the newest terminal entry there (fake Orca).
Working reads busy, done reads idle, and waiting or blocked reads as an agent held on a question such as a permission or trust prompt (real Orca).
`fm-crew-state.sh` reports that wait as `parked` with `waiting for input`, ahead of Firstmate's own turn record, which still reads busy while Claude waits on a permission prompt (real Orca).
With no Firstmate turn record, Orca's busy is trusted as busy and its idle is not, as for the other native backends (code).
Orca drops an agent from that listing when it ends, but `orca terminal show` keeps naming Pi and Oh My Pi after they exit, so only the listing counts as presence (real Orca).
A running terminal with no listed agent reads unverified, as before: a harness Orca does not hook, one that has not reported yet, and one that ended and left its shell look the same (code).

Firstmate's Orca launch ends the terminal with the agent: the staged launch file exits the pane shell once the worker returns, while a refused launch keeps the shell (fake Orca).
An ended terminal reads `exited`, and a handle Orca no longer knows answers `terminal_handle_stale`; the agent-state classifier maps both to a gone endpoint (real Orca).
That classification does not prove a safe close for cleanup; the cleanup rules above govern release.
`orca terminal wait --for exit` reports the same end but not a trustworthy exit code (real Orca), so nothing here reads that code.
The [agent-state verification](verification/runtime-backends.md#orca-agent-state) records the real Claude, Pi, and Oh My Pi checks.
Waiting for input is unsupported for Pi on Orca; its busy, idle, and gone states are verified (real Orca).

## Exit and relaunch

`fm-control.sh exit` types the harness's exit command, then waits with `orca terminal wait --for exit` until Orca reports the terminal exited, because the agent ends its own terminal (fake Orca).
If the terminal keeps running after that wait but Orca no longer lists the agent on it, only the shell the agent left is running, and Firstmate closes that terminal as a last resort; it never closes a terminal Orca still lists an agent on (fake Orca).
A terminal already exited reads as `endpoint-gone`, and the worktree with every uncommitted change stays untouched (code).
`relaunch` opens one fresh terminal in the recorded worktree with `orca terminal create` and points the task record at it; the old terminal is never reused, because it ended with its agent (fake Orca).
Before typing into that fresh terminal, relaunch runs the same placement, agent-listing, and screen checks as a first spawn, against the recorded worktree, and refuses on any failure, typing nothing (fake Orca).
A stale handle after an Orca restart proves the terminal gone only when Orca still lists the recorded worktree and no live terminal in it, because the desktop app can re-attach its terminals under new handles; otherwise `exit` and `relaunch` refuse (code).
A refused relaunch closes the fresh terminal it opened and never the worktree (code).

## Active limits

- The backend is explicit-only.
- The Orca runtime must share the Firstmate home's filesystem, because spawn and cleanup check the worktree on local disk (code).
  To run lanes on a paired Orca server, run the Firstmate home on that server's machine; it drives that runtime through its local CLI, which is the same runtime the paired client reaches (real Orca).
  Pointing a home at another machine's runtime with `--environment` or `ORCA_ENVIRONMENT` is unsupported.
- The Orca runtime must be running and report ready.
- No real agent has run as a second mate on Orca, and away mode's `start` has no Orca launch (code).
- An interrupt is reported delivered with its cancellation unconfirmed unless the harness keeps its own confirmation record (muse confirms from its session log), and an interrupt for a harness that must read its screen between or after presses (Devin and Command Code) is refused because Orca's screen read has never been verified with a real Devin or Command Code on it (code); [`agent-control.md`](agent-control.md) owns the per-backend control matrix.
- `exit` and `relaunch` act only on an agent Orca lists; a running terminal with no listed agent reads unverified and refuses (code).
- `exit` and `relaunch` have not yet run against a real agent on real Orca.
- Cortex and Command Code are refused because Orca supplies no pane identity for their composers (code).
- Firstmate checks readiness, not Orca's version (code).
- The [shell-ownership check](#shell-ownership) has screen-based acceptance and prompt-compatibility limits (code).
- Only the verified terminal-handle and worktree result fields are accepted; speculative response shapes are rejected (fake Orca).
- Orca's linked worktree has the shape the spawn-time Claude workspace-trust check in `bin/fm-claude-trust.sh` requires, and every Claude worker launched on Orca has passed that check (real Orca).

## Regression entry points

```sh
tests/fm-backend-orca.test.sh
tests/fm-backend-orca-live-safety.test.sh
tests/fm-spawn-orca-worktree.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
tests/fm-teardown-endpoint-safety.test.sh
tests/fm-daemon.test.sh
tests/fm-secondmate-liveness.test.sh
```

These run against the stand-in `orca`; [`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the real-Orca evidence.
After an Orca update, `FM_ORCA_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-backend-orca-live-e2e.test.sh` re-proves the adapter against a disposable Orca runtime; [`verification/runtime-backends.md`](verification/runtime-backends.md#real-orca-lane) records its state.
