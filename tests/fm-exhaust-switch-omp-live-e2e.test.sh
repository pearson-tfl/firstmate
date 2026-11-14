#!/usr/bin/env bash
# Token-free real-omp guard for the exhausted-login switch's vendor signals.
# A disposable secondmate runs real omp on a private tmux socket against a
# local stub that answers every Anthropic call with a 429 and a 103-hour
# retry-after-ms, so no model tokens are spent. The guard proves, on the
# installed omp, that the switch finds the seat's session file through the
# spawn-written extension, reads omp's own 429 record and idle state, records
# the login, and asks the control plane for a resume (a recording stand-in, so
# no real login is touched). It also checks each real omp profile database
# still has the auth_credentials columns the profile-to-login mapping reads.
# FM_EXHAUST_SWITCH_LIVE=0 (or FM_LIVE=0) skips it; =1 forces it.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_EXHAUST_SWITCH_LIVE omp bun tmux git python3 sqlite3

REAL_TMUX=$(command -v tmux)
VERSION=$(omp --version)
LAB=$(mktemp -d "${HOME%/}/.fm-exhaust-live.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
SOCKET="fm-exhaust-live-$$"
STUB_PID=
PASSED=0
fail() { printf 'not ok - omp %s: %s (evidence: %s)\n' "$VERSION" "$1" "$LAB" >&2; exit 1; }
cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  pkill -f -- "--cwd $LAB/" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do pgrep -f -- "--cwd $LAB/" >/dev/null 2>&1 || break; sleep 0.1; done
  [ -z "$STUB_PID" ] || kill "$STUB_PID" >/dev/null 2>&1 || true
  # A failed run keeps its lab as evidence.
  [ "$PASSED" != 1 ] || fm_test_remove_tree "$LAB"
  fm_test_cleanup
}
trap cleanup EXIT

# omp joins PI_CONFIG_DIR to the home directory, so the lab lives under it.
export PI_CONFIG_DIR=${LAB#"${HOME%/}"/}/omp-root
export FM_OMP_ROOT="$LAB/omp-root"
export FM_EXHAUSTED_LOGINS="$LAB/exhausted-logins"
mkdir -p "$LAB/omp-root/profiles/labx/agent" "$LAB/shim" "$LAB/parent/state" "$LAB/parent/config" "$LAB/parent/data"

cat > "$LAB/stub.py" <<'PY'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def _answer(self):
        n = int(self.headers.get("content-length") or 0)
        if n: self.rfile.read(n)
        body = json.dumps({"type": "error", "error": {"type": "rate_limit_error", "message": "rate limited"}}).encode()
        self.send_response(429)
        self.send_header("content-type", "application/json")
        self.send_header("retry-after-ms", "371640000")
        self.send_header("content-length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    do_POST = do_GET = _answer
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_port))
srv.serve_forever()
PY
python3 -I "$LAB/stub.py" "$LAB/stub.port" >/dev/null 2>&1 &
STUB_PID=$!
for _ in $(seq 1 50); do [ -s "$LAB/stub.port" ] && break; sleep 0.1; done
[ -s "$LAB/stub.port" ] || fail 'the 429 stub never started'
printf 'providers:\n  anthropic:\n    baseUrl: http://127.0.0.1:%s\n    apiKey: lab-not-a-real-key\n' "$(cat "$LAB/stub.port")" \
  > "$LAB/omp-root/profiles/labx/agent/models.yml"

# A second profile with a login gives the move somewhere to go; the control
# plane is stood in below, so omp never launches on it.
mkdir -p "$LAB/omp-root/profiles/spare/agent"
sqlite3 "$LAB/omp-root/profiles/spare/agent/agent.db" "create table auth_credentials (id integer primary key,
  provider text, credential_type text, data text, disabled_cause text, identity_key text);
  insert into auth_credentials (provider, credential_type, data)
  values ('anthropic', 'oauth', json_object('email', 'login-spare', 'orgId', 'org-spare'));" \
  || fail 'cannot create the spare profile'

cat > "$LAB/shim/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
EOF
chmod +x "$LAB/shim/tmux"
export PATH="$LAB/shim:$PATH"
unset TMUX TMUX_PANE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_TASK_ID
export FM_HOME="$LAB/parent" FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf 'tmux\n' > "$FM_HOME/config/backend"
printf 'omp anthropic/claude-haiku-5-5 low\n' > "$FM_HOME/config/secondmate-harness"
mkdir -p "$FM_HOME/config/secondmate-accounts/labx-mate"
printf 'labx\n' > "$FM_HOME/config/secondmate-accounts/labx-mate/omp-profile"
mate="$LAB/mate"
mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects"
git -C "$mate" init -q || fail 'cannot create the mate home'
printf 'labx-mate\n' > "$mate/.fm-secondmate-home"
printf 'Isolated lab seat.\n' > "$mate/AGENTS.md"
ln -s "$ROOT/bin" "$mate/bin"
printf 'Reply with exactly one word, IDLE, to every message. Do not use tools.\n' > "$mate/data/charter.md"
"$REAL_TMUX" -L "$SOCKET" new-session -d -s firstmate -n control /bin/sh || fail 'cannot create private server'
"$ROOT/bin/fm-spawn.sh" labx-mate "$mate" --secondmate > "$LAB/spawn.out" 2>&1 \
  || fail "the lab seat did not spawn: $(tail -3 "$LAB/spawn.out")"

cat > "$LAB/control" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$LAB/control.log"
EOF
chmod +x "$LAB/control"
out=
for _ in $(seq 1 90); do
  out=$(FM_TEST_SEAM=1 FM_TEST_EXHAUST_CONTROL="$LAB/control" "$ROOT/bin/fm-exhaust-switch.sh" check 2>&1)
  [ -z "$out" ] || break
  sleep 1
done
case "$out" in
  *"labx-mate ran out of usage on omp:labx"*) ;;
  *) fail "the switch never read the seat's real 429 as exhausted: ${out:-no output}" ;;
esac
session=$(sed -n 1p "$FM_HOME/state/labx-mate.omp-session" 2>/dev/null)
expected_dir="$LAB/omp-root/profiles/labx/agent/sessions/$(printf '%s' "${mate#"${HOME%/}"}" | tr '/' '-')"
[ "${session%/*}" = "$expected_dir" ] \
  || fail "omp no longer keeps sessions where the pre-record fallback looks: ${session:-none}"
awk '$1 == "omp:labx" && $2 > 1700000000 { found = 1 } END { exit !found }' "$FM_EXHAUSTED_LOGINS" \
  || fail "the login was not recorded exhausted: $(cat "$FM_EXHAUSTED_LOGINS" 2>/dev/null)"
for _ in $(seq 1 50); do [ -s "$LAB/control.log" ] && break; sleep 0.1; done
grep -q '^labx-mate resume --note ' "$LAB/control.log" || fail "the move did not ask for a resume: $(cat "$LAB/control.log" 2>/dev/null)"
pass "omp $VERSION: the switch reads a real seat's long 429, session file and idle state, records the login, and resumes it"

checked=0
for db in "${HOME%/}"/.omp/profiles/*/agent/agent.db "${HOME%/}"/.omp/agent/agent.db; do
  [ -f "$db" ] || continue
  sqlite3 -readonly "$db" 'SELECT provider, credential_type, data, disabled_cause FROM auth_credentials LIMIT 0' >/dev/null 2>&1 \
    || fail "$db lacks the auth_credentials columns the profile-to-login mapping reads"
  checked=$((checked + 1))
done
if [ "$checked" -gt 0 ]; then
  pass "omp $VERSION: $checked real profile database(s) carry the auth_credentials columns the login mapping reads"
else
  printf 'skip: live: no real omp profile database on this machine\n'
fi
PASSED=1
