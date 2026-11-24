#!/usr/bin/env bash
# bin/backends/orca.sh - the Orca terminal session-provider adapter.
#
# Orca owns both the task worktree and the terminal endpoint. Escape and Ctrl+U
# go as raw control bytes (fm_backend_orca_send_key). Agent state and busy come
# from Orca's own agent listing (fm_backend_orca_agent_probe).
#
# Target string shape: the Orca terminal id accepted by `orca terminal ...`.

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"
# shellcheck source=bin/fm-credential-source-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-credential-source-lib.sh"

# fm_backend_orca_bin: resolve the Orca CLI. macOS names it `orca`; Linux names
# it `orca-ide` because GNOME's screen reader owns `orca`. Lookup order:
# `orca-ide` on PATH, then the CLI a paired Orca server's install leaves in
# ~/.orca/cli/bin off PATH, then a bare `orca` on PATH last, so a GNOME `orca`
# never masks either Orca install. A test stub
# shadows any real install only when it sits ahead on PATH as `orca-ide` too.
FM_BACKEND_ORCA_BUNDLE_BIN="${FM_BACKEND_ORCA_BUNDLE_BIN:-${HOME:-}/.orca/cli/bin/orca-ide}"
fm_backend_orca_bin() {
  command -v orca-ide && return 0
  if [ -x "$FM_BACKEND_ORCA_BUNDLE_BIN" ]; then
    printf '%s' "$FM_BACKEND_ORCA_BUNDLE_BIN"
    return 0
  fi
  command -v orca
}

fm_backend_orca_cli() {  # <orca args...>
  local bin
  bin=$(fm_backend_orca_bin) || return 127
  "$bin" "$@"
}

fm_backend_orca_tool_check() {
  fm_backend_orca_bin >/dev/null 2>&1 || { echo "error: backend=orca selected but the Orca CLI was not found: neither 'orca' nor 'orca-ide' is on PATH and $FM_BACKEND_ORCA_BUNDLE_BIN is absent" >&2; return 1; }
}

fm_backend_orca_runtime_check() {
  fm_backend_orca_tool_check || return 1
  local out
  out=$(fm_backend_orca_cli status --json 2>/dev/null) || {
    echo "error: backend=orca selected but 'orca status --json' failed; start Orca and wait for the runtime to be ready" >&2
    return 1
  }
  # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  console.error("error: invalid Orca status JSON: " + err.message);
  process.exit(1);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  console.error("error: Orca runtime is not ready" + (msg ? ": " + msg : ""));
  process.exit(1);
}
const r = data.result || {};
const runtime = r.runtime || {};
const reachable = runtime.reachable ?? r.runtimeReachable;
const state = runtime.state || r.runtimeState || "";
if (reachable === true && state === "ready") process.exit(0);
console.error(`error: backend=orca requires a ready Orca runtime (reachable=${String(reachable)}, state=${state || "unknown"})`);
process.exit(1);
'
}

# Snapshot only the explicitly selected tmux session's local environment, never
# its server-global environment or the invoking process. The caller places these
# quoted assignments in its private staged launch file, never terminal input.
# Every allowlisted name must exist in the session; an explicit -NAME record is
# a deliberate unset, and a missing name refuses rather than falling back.
fm_backend_orca_launch_env_args() {  # <tmux-session> <newline-separated names>
  node - "$1" "$2" <<'JS'
const { spawnSync } = require("child_process");
const [session, names] = process.argv.slice(2);
function refuse(name) {
  // Do not echo tmux output or errors: they may contain credential values.
  const required = name === undefined ? "" : ` (required name ${name})`;
  console.error(`error: cannot snapshot configured tmux launch environment${required}; refusing Orca launch`);
  process.exit(1);
}
function read(name) {
  // Without -u, tmux sanitizes values when the client lacks a UTF-8 locale.
  const args = ["-u", "show-environment", "-t", `=${session}`];
  if (name !== undefined) args.push(name);
  // latin1 maps each byte to one code unit, so values that are not valid UTF-8
  // reach the launch file byte for byte instead of as replacement characters.
  const result = spawnSync("tmux", args, {
    encoding: "latin1", timeout: 10000, maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) refuse(name);
  return result.stdout;
}
// Verify the session even for an empty allowlist. Never derive names from raw
// multiline values or tmux's automatically populated update-environment.
read();
const assignments = [];
for (const name of new Set(names.split("\n").filter(Boolean))) {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) refuse();
  // Read each name separately so embedded/trailing newlines are preserved and
  // a value resembling another NAME=value line cannot supply another variable.
  const output = read(name);
  if (!output.endsWith("\n")) refuse(name);
  const record = output.slice(0, -1);
  if (record === `-${name}`) continue;
  if (!record.startsWith(`${name}=`)) refuse(name);
  const value = record.slice(name.length + 1);
  if (value.includes("\0")) refuse(name);
  assignments.push(`${name}='${value.replace(/'/g, "'\\''")}'`);
}
process.stdout.write(assignments.join(" "), "latin1");
JS
}

# The vault alternative to the tmux snapshot above, with no tmux involved: each
# allowlisted name is read through its declared source in <file>, which
# bin/fm-credential-source-lib.sh owns (schema, adapters, containment). Every
# name must be declared and yield a non-empty value; a refusal names the name,
# never a value. Output has the same shape as the tmux snapshot's.
fm_backend_orca_launch_env_vault_args() {  # <file> <newline-separated names>
  local file=$1 name value problem src
  local -a names=() assignments=()
  while IFS= read -r name; do
    [ -n "$name" ] && names+=("$name")
  done <<<"$2"
  problem=$(fm_credsrc_check "$file" ${names[@]+"${names[@]}"}) || {
    echo "error: config/launch-env-vault: ${problem:-unreadable}; refusing Orca launch" >&2
    return 1
  }
  for name in ${names[@]+"${names[@]}"}; do
    if ! fm_credsrc_declares "$file" "$name"; then
      echo "error: config/launch-env-vault declares no source for allowlisted name $name; refusing Orca launch" >&2
      return 1
    fi
    src=$(fm_credsrc_field "$file" "$name" source)
    if ! fm_credsrc_supported "$src"; then
      echo "error: config/launch-env-vault source $src for $name cannot run on this host; refusing Orca launch" >&2
      return 1
    fi
    if ! value=$(fm_credsrc_read "$file" "$name") || [ -z "$value" ]; then
      echo "error: cannot read $name from its config/launch-env-vault source; refusing Orca launch" >&2
      return 1
    fi
    assignments+=("$name='${value//\'/\'\\\'\'}'")
  done
  local IFS=' '
  printf '%s' "${assignments[*]-}"
}

fm_backend_orca_json_get() {  # <field> ; fields: worktree-id worktree-path terminal-handle worktree-terminal-handle repo-id
  # Terminal handles are accepted only from verified terminal result shapes:
  # result.terminal or a root terminal object with .handle. Undocumented
  # result.id and result.worktree.terminal shapes are ignored until a real Orca
  # smoke run proves them.
  local field=$1
  node -e '
const fs = require("fs");
const field = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
const wt = r.worktree || r.item || r;
const explicitTerm = r.terminal || null;
const repo = r.repo || r.repository || r;
function scalar(v) {
  return (typeof v === "string" || typeof v === "number") ? String(v) : "";
}
function handle(obj) {
  if (!obj) return "";
  if (typeof obj === "string" || typeof obj === "number") return String(obj);
  return scalar(obj.handle) || "";
}
let v = "";
if (field === "worktree-id") v = wt.id || wt.worktreeId || r.worktreeId || "";
if (field === "worktree-path") v = wt.path || (wt.git && wt.git.path) || r.path || "";
if (field === "terminal-handle") v = handle(explicitTerm || r) || "";
if (field === "worktree-terminal-handle") v = handle(explicitTerm) || "";
if (field === "repo-id") v = repo.id || repo.repoId || r.repoId || "";
if (!v) process.exit(1);
process.stdout.write(String(v));
' "$field"
}

fm_backend_orca_json_ok() {
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8").trim();
if (!input) process.exit(0);
let data;
try {
  data = JSON.parse(input);
} catch (err) {
  console.error("invalid Orca JSON: " + err.message);
  process.exit(2);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
'
}

fm_backend_orca_run_json() {
  local out
  out=$("$@") || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok
}

fm_backend_orca_repo_ensure() {  # <project-path>
  local project=$1 out repo_id
  fm_backend_orca_tool_check || return 1
  out=$(fm_backend_orca_cli repo show --repo "path:$project" --json 2>/dev/null || true)
  if repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id 2>/dev/null); then
    printf '%s' "$repo_id"
    return 0
  fi
  out=$(fm_backend_orca_cli repo add --path "$project" --json) || return 1
  repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id) || {
    echo "error: orca repo add did not return a repo id for $project" >&2
    return 1
  }
  printf '%s' "$repo_id"
}

fm_backend_orca_worktree_create() {  # <project-path> <name>
  local project=$1 name=$2 repo_id out wt_id wt_path terminal
  repo_id=$(fm_backend_orca_repo_ensure "$project") || return 1
  out=$(fm_backend_orca_cli worktree create --repo "id:$repo_id" --name "$name" --no-parent --setup skip --json) || return 1
  wt_id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id) || {
    echo "error: orca worktree create did not return a worktree id for $name" >&2
    return 1
  }
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-terminal-handle 2>/dev/null || true)
  wt_path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree create did not return a path for $name" >&2
    [ -z "$terminal" ] || fm_backend_orca_kill "$terminal" >/dev/null 2>&1 || true
    if fm_backend_orca_remove_worktree "$wt_id" >/dev/null; then
      return 1
    fi
    if [ -n "$terminal" ]; then
      printf '%s\t\t%s' "$wt_id" "$terminal"
    else
      printf '%s\t' "$wt_id"
    fi
    return 2
  }
  printf '%s\t%s' "$wt_id" "$wt_path"
  [ -z "$terminal" ] || printf '\t%s' "$terminal"
}

fm_backend_orca_terminal_create() {  # <worktree-id> <title>
  local worktree_id=$1 title=$2 out terminal
  fm_backend_orca_tool_check || return 1
  out=$(fm_backend_orca_cli terminal create --worktree "id:$worktree_id" --title "$title" --json) || return 1
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get terminal-handle) || {
    echo "error: orca terminal create did not return a terminal handle for $title" >&2
    return 1
  }
  printf '%s' "$terminal"
}

# fm_backend_orca_fresh_shell_verdict: classify one drawn screen of a terminal
# spawn has just created and not yet typed into. Prints one word:
#   shell    a bare prompt: at most FM_BACKEND_ORCA_FRESH_SHELL_MAX_ROWS rows,
#            none of the shapes below
#   empty    nothing drawn yet
#   tmux     a tmux status row (`[session] 0:win`, ` 1:win `, first or last
#            row) or a tmux session-picker row (`(0) + session: 1 windows`)
#   foreign  box-drawing chrome, an agent composer the shared classifier
#            recognizes (`❯`, `›` ...), or more rows than a bare prompt draws
# The screen alone never proves ownership: fm_backend_orca_fresh_shell pairs
# it with Orca's own account of the terminal.
FM_BACKEND_ORCA_FRESH_SHELL_MAX_ROWS=${FM_BACKEND_ORCA_FRESH_SHELL_MAX_ROWS:-2}
fm_backend_orca_fresh_shell_verdict() {  # <screen>
  local row first='' last='' rows=0
  local status_re='^ *(\[[^]]*\] +)?[0-9]+:[^ ]' picker_re='^\([0-9]+\) +[-+] '
  while IFS= read -r row; do
    case "$row" in *[![:space:]]*) ;; *) continue ;; esac
    rows=$((rows + 1))
    [ -n "$first" ] || first=$row
    last=$row
    if [[ $row =~ $picker_re ]]; then printf 'tmux'; return 0; fi
    # Whole UTF-8 sequences, never a bracket set, which would match single bytes.
    case "$row" in
      *─* | *━* | *│* | *┃* | *┌* | *┐* | *└* | *┘* | *╭* | *╮* | *╰* | *╯* | *├* | *┤* | *═* | *║*)
        printf 'foreign'; return 0 ;;
    esac
  done <<<"$1"
  [ "$rows" -gt 0 ] || { printf 'empty'; return 0; }
  if [[ $first =~ $status_re ]] || [[ $last =~ $status_re ]]; then printf 'tmux'; return 0; fi
  [ "$rows" -le "$FM_BACKEND_ORCA_FRESH_SHELL_MAX_ROWS" ] || { printf 'foreign'; return 0; }
  case "$(fm_composer_classify_screen "$(fm_backend_orca_composer_caps)" "$1")" in
    empty | pending | pending-unproven) printf 'foreign'; return 0 ;;
  esac
  printf 'shell'
}

# fm_backend_orca_owner: Orca's own account of a new terminal. Prints `owned`
# when `orca terminal show` places it in <worktree-id> and `orca agent list`
# names no agent on its pane; otherwise a short reason.
fm_backend_orca_owner() {  # <terminal-id> <worktree-id>
  local terminal=$1 expected=$2 out pane worktree state
  out=$(fm_backend_orca_cli terminal show --terminal "$terminal" --json 2>/dev/null) || { printf 'show-failed'; return 0; }
  pane=$(printf '%s' "$out" | fm_backend_orca_agent_json pane 2>/dev/null) || { printf 'show-unreadable'; return 0; }
  worktree=${pane%%$'\t'*}
  pane=${pane#*$'\t'}
  [ "$worktree" = "$expected" ] || { printf 'other-worktree'; return 0; }
  out=$(fm_backend_orca_cli agent list --worktree "id:$worktree" --json 2>/dev/null) || { printf 'agent-list-failed'; return 0; }
  state=$(printf '%s' "$out" | fm_backend_orca_agent_json state "$pane" 2>/dev/null) || { printf 'agent-list-unreadable'; return 0; }
  [ "$state" = none ] || { printf 'agent-%s' "$state"; return 0; }
  printf 'owned'
}

# fm_backend_orca_fresh_shell: before spawn types its first key into a new
# terminal, require Orca to vouch for it and its screen to be a bare prompt.
# A login profile can exec something else first - an ssh-keyed `tmux attach`
# once turned a new Orca terminal into a client of a live tmux session, and
# every key typed went to that session's pane. Orca offers no process facts
# and spawn sets no prompt, so the live lane's nonce cannot apply; the proof is
# Orca's placement and agent listing (fm_backend_orca_owner) plus the same
# `shell` screen read twice in a row. Refuses at once on tmux, a foreign
# screen, or an Orca account that is not `owned`, and after
# FM_BACKEND_ORCA_FRESH_SHELL_WAIT_S on an empty, unreadable or unsettled
# screen. Sends nothing in every case.
FM_BACKEND_ORCA_FRESH_SHELL_WAIT_S=${FM_BACKEND_ORCA_FRESH_SHELL_WAIT_S:-20}
fm_backend_orca_fresh_shell() {  # <terminal-id> <orca-worktree-id>
  local terminal=$1 expected=$2 screen='' prev='' verdict=unreadable i tries owner=unchecked
  tries=$((FM_BACKEND_ORCA_FRESH_SHELL_WAIT_S * 2))
  for ((i = 0; i <= tries; i++)); do
    [ "$i" -eq 0 ] || sleep 0.5
    if ! screen=$(fm_backend_orca_screen_read "$terminal" 2>/dev/null); then
      verdict=unreadable prev=''
      continue
    fi
    verdict=$(fm_backend_orca_fresh_shell_verdict "$screen")
    case "$verdict" in
      tmux | foreign) break ;;
      shell)
        if [ "$screen" = "$prev" ]; then
          owner=$(fm_backend_orca_owner "$terminal" "$expected")
          [ "$owner" != owned ] || return 0
          break
        fi
        prev=$screen
        ;;
      *) prev='' ;;
    esac
  done
  [ "$verdict" != shell ] || [ "$owner" != unchecked ] || verdict='shell, never settled'
  local row=${screen:-}
  row=${row##*$'\n'}
  echo "error: refusing to send to Orca terminal $terminal: it is not proven to be the plain shell spawn just created (screen: $verdict; orca: $owner; last row: '${row:0:80}'); nothing was typed" >&2
  return 1
}

fm_backend_orca_send_text_line() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json fm_backend_orca_cli terminal send --terminal "$terminal" --text "$text" --enter --json
}

fm_backend_orca_send_literal() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json fm_backend_orca_cli terminal send --terminal "$terminal" --text "$text" --json
}

fm_backend_orca_remove_worktree() {  # <worktree-id>
  local worktree_id=${1:-}
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot remove worktree" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json fm_backend_orca_cli worktree rm --worktree "id:$worktree_id" --force --json
}

fm_backend_orca_worktree_path() {
  local worktree_id=${1:-} out path
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot resolve worktree path" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  out=$(fm_backend_orca_cli worktree show --worktree "id:$worktree_id" --json) || return 1
  path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree show did not return a path for $worktree_id" >&2
    return 1
  }
  printf '%s' "$path"
}

# fm_backend_orca_screen_read: the terminal as Orca draws it now, never the
# accumulated output stream. `orca terminal read` without --screen replays
# everything printed - repainted lines stack as fragments, cursor-drawn spaces
# vanish, and a cleared startup banner comes back - so every adapter read asks
# for the drawn screen. A read whose reported source is not `screen` (a stream
# read, `screen-unavailable` falling back to the stream, or a host predating the
# field) is refused rather than passed off as the screen. The drawn screen has
# no scrollback, and Orca omits its blank rows.
fm_backend_orca_screen_read() {  # <terminal-id> [orca read args...]
  local terminal=$1 out
  shift
  fm_backend_orca_tool_check || return 1
  out=$(fm_backend_orca_cli terminal read --terminal "$terminal" --screen "$@" --json) || return 1
  fm_backend_orca_json_text "$out"
}

# fm_backend_orca_capture: the bottom <lines> rows of the drawn screen; with
# --screen, Orca's --limit keeps the last rows.
fm_backend_orca_capture() {  # <terminal-id> <lines>
  fm_backend_orca_screen_read "$1" --limit "${2:-40}"
}

# fm_backend_orca_visible_capture: the whole drawn screen (no --limit), which
# is the viewport by construction. Listed in FM_BACKEND_VISIBLE_CAPTURE.
fm_backend_orca_visible_capture() {  # <terminal-id> [expected-label]
  fm_backend_orca_screen_read "$1"
}

# fm_backend_orca_target_ready: existence only, through a plain read, so a live
# terminal whose screen Orca cannot render is not reported gone. A terminal
# Orca reads as exited has ended, so it no longer exists as an endpoint.
fm_backend_orca_target_ready() {  # <terminal-id>
  local out
  fm_backend_orca_tool_check || return 1
  out=$(fm_backend_orca_cli terminal read --terminal "$1" --limit 1 --json) || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok || return 1
  [ "$(printf '%s' "$out" | fm_backend_orca_agent_json terminal-status 2>/dev/null)" != exited ]
}

# fm_backend_orca_terminal_status: running|exited from Orca's plain read, stale
# when Orca refuses the handle as terminal_handle_stale (the handle names no
# terminal on this Orca), or unreadable for any other answer or failure.
fm_backend_orca_terminal_status() {  # <terminal-id>
  local out
  out=$(fm_backend_orca_cli terminal read --terminal "$1" --limit 1 --json 2>/dev/null) || true
  printf '%s' "$out" | fm_backend_orca_agent_json terminal-status 2>/dev/null || printf 'unreadable'
}

# fm_backend_orca_agent_json: the JSON reads behind the agent probe.
#   terminal-status  read JSON  -> running|exited|stale (fails otherwise)
#   pane             show JSON  -> "<worktree-id>\t<tab-id>:<leaf-id>"
#   state <pane-key> list JSON  -> the newest terminal agent's state on that
#                                  pane, or none when Orca lists no agent there
fm_backend_orca_agent_json() {  # <mode> [pane-key]
  node -e '
const fs = require("fs");
const [mode, pane] = process.argv.slice(1);
let data;
try { data = JSON.parse(fs.readFileSync(0, "utf8")); } catch (err) { process.exit(1); }
if (!data || typeof data !== "object") process.exit(1);
const r = data.result || {};
if (mode === "terminal-status") {
  if (data.ok === false) {
    if (data.error && data.error.code === "terminal_handle_stale") { process.stdout.write("stale"); process.exit(0); }
    process.exit(1);
  }
  const s = r.terminal && r.terminal.status;
  if (s === "running" || s === "exited") { process.stdout.write(s); process.exit(0); }
  process.exit(1);
}
if (data.ok === false) process.exit(1);
if (mode === "pane") {
  const t = r.terminal || {};
  const ok = (v) => typeof v === "string" && v !== "" && !/[\t\n]/.test(v);
  if (!ok(t.worktreeId) || !ok(t.tabId) || !ok(t.leafId)) process.exit(1);
  process.stdout.write(t.worktreeId + "\t" + t.tabId + ":" + t.leafId);
  process.exit(0);
}
if (mode === "state") {
  if (!Array.isArray(r.agents)) process.exit(1);
  const mine = r.agents.filter((a) => a && a.kind === "terminal" && a.paneKey === pane);
  if (mine.length === 0) { process.stdout.write("none"); process.exit(0); }
  mine.sort((a, b) => (Number(b.updatedAt) || 0) - (Number(a.updatedAt) || 0));
  const s = mine[0].state;
  process.stdout.write(typeof s === "string" && /^[a-z_]+$/.test(s) ? s : "unknown");
  process.exit(0);
}
process.exit(1);
' "$@"
}

# fm_backend_orca_agent_probe: Orca's own report of the agent in one terminal
# (route B). Orca's status hooks list a terminal agent by the pane it runs in,
# from its first report until it ends, with its state: working, blocked,
# waiting, or done. Prints:
#   missing     Orca refused the handle as stale, or the terminal has exited
#   unreadable  a read failed or answered in an unrecognized shape
#   none        the terminal runs but Orca lists no agent on its pane
#   <state>     Orca's word for the agent listed on the terminal's pane
# Orca keeps a terminal's agentIdentity after the agent exits (Pi and Oh My Pi,
# Orca 1.4.271), so only the agent listing is read as presence.
fm_backend_orca_agent_probe() {  # <terminal-id>
  local terminal=$1 status out pane worktree
  fm_backend_orca_tool_check >/dev/null 2>&1 || { printf 'unreadable'; return 0; }
  status=$(fm_backend_orca_terminal_status "$terminal")
  case "$status" in
    stale|exited) printf 'missing'; return 0 ;;
    running) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  out=$(fm_backend_orca_cli terminal show --terminal "$terminal" --json 2>/dev/null) || { printf 'unreadable'; return 0; }
  pane=$(printf '%s' "$out" | fm_backend_orca_agent_json pane 2>/dev/null) || { printf 'unreadable'; return 0; }
  worktree=${pane%%$'\t'*}
  pane=${pane#*$'\t'}
  out=$(fm_backend_orca_cli agent list --worktree "id:$worktree" --json 2>/dev/null) || { printf 'unreadable'; return 0; }
  printf '%s' "$out" | fm_backend_orca_agent_json state "$pane" 2>/dev/null || printf 'unreadable'
}

# fm_backend_orca_busy_state: the dispatcher's busy vocabulary from Orca's
# agent state: working is busy, done is idle, and waiting or blocked - an agent
# held on a question such as a permission or trust prompt - is blocked, the
# same word Tern uses. Everything else, including no listed agent, is unknown.
fm_backend_orca_busy_state() {  # <terminal-id> -> busy|idle|blocked|unknown
  case "$(fm_backend_orca_agent_probe "$1")" in
    working) printf 'busy' ;;
    done) printf 'idle' ;;
    waiting|blocked) printf 'blocked' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_orca_agent_state: the recovery-grade contract in bin/fm-backend.sh.
# alive rests on Orca's listing, which Orca clears when the agent ends, not on
# a Firstmate process read: the terminal's processes belong to the Orca host.
# A running terminal with no listed agent - a harness Orca does not hook, one
# that has not reported yet, or one that ended and left its shell - is beyond
# that listing, so it stays unverified, as every Orca terminal read before it,
# and dead is never claimed. Firstmate's Orca launch ends the terminal with the
# agent (route A), which makes an ended agent read missing.
fm_backend_orca_agent_state() {  # <terminal-id>
  case "$(fm_backend_orca_agent_probe "$1")" in
    missing) printf 'missing' ;;
    unreadable) printf 'unreadable' ;;
    none) printf 'unverified' ;;
    *) printf 'alive' ;;
  esac
}

fm_backend_orca_json_text() {  # <json>
  printf '%s' "$1" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
const t = r.terminal || r;
if (t.source !== "screen" || !Array.isArray(t.tail)) {
  console.error("error: orca terminal read returned source " + (t.source || "(none)") + ", not the drawn screen");
  process.exit(3);
}
process.stdout.write(t.tail.join("\n"));
'
}

# fm_backend_orca_composer_capture: the orca composer screen - the bottom
# rows of the drawn screen. Deliberately NOT the old 200-line
# backward-paged read: the composer is bottom-anchored, and paging back into
# scrollback is what let a stale startup banner (codex's bordered
# "permissions" box) compete with - and once outrank - the live composer.
fm_backend_orca_composer_capture() {  # <terminal-id> [expected-label]
  fm_backend_orca_capture "$1" "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_caps: static capability facts, not logic (see the
# capability model in bin/fm-composer-lib.sh). Orca's `terminal read` returns
# plain text; whether it can emit ANSI is unverified (orca is not installed
# on the verification machine), so styled stays 0 - the conservative
# degradation - until a live capture proves otherwise. The drawn-screen read
# omits blank rows, which blanks=elided declares.
fm_backend_orca_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nblanks=elided\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_state: thin adapter - capture plus capabilities in,
# shared verdict out. Every shape (bordered boxes AND the borderless bare-glyph
# row this adapter never learned, which left every claude/codex/pi/muse steer
# unconfirmed) lives in bin/fm-composer-lib.sh.
fm_backend_orca_composer_state() {  # <terminal-id> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_orca_composer_capture "$1") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_orca_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

fm_backend_orca_send_key() {  # <terminal-id> <key>
  local terminal=$1 key=$2
  fm_backend_orca_tool_check || return 1
  case "$key" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_orca_run_json fm_backend_orca_cli terminal send --terminal "$terminal" --interrupt --json
      ;;
    Enter|enter)
      fm_backend_orca_run_json fm_backend_orca_cli terminal send --terminal "$terminal" --text "" --enter --json
      ;;
    # Without --enter Orca writes --text to the PTY verbatim, so a control byte
    # is the key itself (orca terminal send --help, Orca 1.4.271).
    Escape|escape)
      fm_backend_orca_run_json fm_backend_orca_cli terminal send --terminal "$terminal" --text $'\x1b' --json
      ;;
    C-u|ctrl+u|Ctrl-u|Ctrl-U)
      fm_backend_orca_run_json fm_backend_orca_cli terminal send --terminal "$terminal" --text $'\x15' --json
      ;;
    *)
      echo "error: unsupported Orca key '$key'" >&2
      return 1
      ;;
  esac
}

# fm_backend_orca_send_text_submit: type <text> once, then drive the shared
# verify-and-retry-Enter loop (bin/fm-composer-lib.sh:
# fm_composer_submit_retry_core) against the shared composer verdict, so a
# slash-command popup placeholder fill gets the required second Enter without
# duplicating text.
fm_backend_orca_send_text_submit() {  # <terminal-id> <text> <retries> <enter-sleep> <settle>
  local terminal=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  fm_backend_orca_tool_check || { printf 'send-failed'; return 0; }
  fm_backend_orca_send_literal "$terminal" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_orca_send_key fm_backend_orca_composer_state \
    "$terminal" "$retries" "$sleep_s"
}

# fm_backend_orca_kill: close one recorded task terminal. A missing CLI is a
# close that was never even attempted, not an endpoint proven gone - with no
# CLI there is no read that could show the terminal absent - so it reports the
# failure its tool check already named instead of a success. The close call
# itself stays best-effort: whether an accepted-then-failed close left the
# terminal alive is not yet decidable without a presence re-read proven
# against the real Orca binary (docs/verification/runtime-backends.md
# "Endpoint close").
fm_backend_orca_kill() {  # <terminal-id>
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_cli terminal close --terminal "$1" --json >/dev/null 2>&1 || true
}
