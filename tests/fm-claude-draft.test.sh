#!/usr/bin/env bash
# Exact-byte editor bridge behavior through its public CLI (no Claude required).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-claude-draft)
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
root, tmp = map(Path, sys.argv[1:])
helper = [sys.executable, str(root / 'bin/fm-claude-draft.py')]
directory = tmp / 'bridge'
directory.mkdir()
composer = tmp / 'editor.txt'
backup = tmp / 'saved.txt'
text = 'unsubmitted $HOME; "quoted"\nsecond line  \n\nλ\n'.encode()
composer.write_bytes(text)
env = dict(os.environ, FM_CLAUDE_DRAFT_DIR=str(directory))

def run(*args, ok=True, environment=None):
    result = subprocess.run(helper + list(map(str, args)), env=environment or env,
                            capture_output=True, text=True)
    assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
    return result.stdout.strip()

def operation(mode, ok=True):
    nonce = run('prepare', directory, mode, backup)
    run('edit', composer)
    run('wait', directory, nonce, ok=ok)

operation('take')
assert backup.read_bytes() == text and composer.read_bytes() == b''
assert backup.stat().st_mode & 0o777 == 0o600
operation('restore')
assert composer.read_bytes() == text
operation('read')
composer.write_bytes(b'new input must survive')
operation('restore', ok=False)
assert composer.read_bytes() == b'new input must survive' and backup.read_bytes() == text
operation('take', ok=False)
assert composer.read_bytes() == b'new input must survive' and backup.read_bytes() == text
composer.write_bytes(text + b'divergence')
operation('read', ok=False)
assert composer.read_bytes() == text + b'divergence'
# Claude ignores its editor shortcut on empty input: only the controller's
# exact placeholder may be replaced, not concurrently typed input.
composer.write_bytes(b'nonce-placeholder')
nonce = run('prepare', directory, 'restore', backup, 'nonce-placeholder')
run('edit', composer); run('wait', directory, nonce)
assert composer.read_bytes() == text
composer.write_bytes(b'nonce-placeholder with user input')
nonce = run('prepare', directory, 'restore', backup, 'nonce-placeholder')
run('edit', composer); run('wait', directory, nonce, ok=False)
assert composer.read_bytes() == b'nonce-placeholder with user input'
nonce = run('prepare', directory, 'take', tmp / 'expired.txt')
request = directory / 'request.json'
body = json.loads(request.read_text()); body['expires'] = 0
request.write_text(json.dumps(body))
run('edit', composer)
run('wait', directory, nonce, ok=False)
assert not (tmp / 'expired.txt').exists()
# Normal Ctrl-G still delegates to the user's editor, with a literal filename.
editor = tmp / 'original-editor.py'
editor.write_text('import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"user edit")')
env['FM_CLAUDE_REAL_EDITOR'] = f'{sys.executable} {editor}'
run('edit', composer)
assert composer.read_bytes() == b'user edit'
print('PASS: exact save/restore/read, whitespace, refusal, expiry, editor delegation')
PY
rc=$?
[ "$rc" -eq 0 ] || fail "editor bridge public CLI tests failed"
pass "Claude draft transfers preserve bytes without submitting input"
