#!/usr/bin/env bash
# Public native-record verifier, with a real live process and process generation.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-claude-session)
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
root, tmp = map(Path, sys.argv[1:])
(tmp / 'sessions').mkdir(parents=True)
(tmp / 'claude').symlink_to('/bin/sleep')
process = subprocess.Popen([str(tmp / 'claude'), '60'])
try:
    env = dict(os.environ, LC_ALL='C')
    stat = Path('/proc') / str(process.pid) / 'stat'
    start = (stat.read_text().rsplit(')', 1)[1].split()[19] if stat.exists() else
             subprocess.check_output(['ps','-p',str(process.pid),'-o','lstart='],env=env,text=True).strip())
    sid = 'b8113c88-1111-4222-8333-444455558888'
    record = dict(pid=process.pid, sessionId=sid, cwd=str(tmp), status='idle', procStart=start)
    path = tmp / 'sessions' / (str(process.pid) + '.json')
    command = [sys.executable,str(root / 'bin/fm-claude-session.py'),str(tmp),sid,str(tmp),'idle']
    def check(ok):
        path.write_text(json.dumps(record))
        result = subprocess.run(command,capture_output=True,text=True)
        assert (result.returncode == 0) == ok, result.stderr
        if ok:
            assert result.stdout.strip() == str(process.pid)
    check(True)
    record['status']='busy'; check(False)
    record['status']='idle'; record['sessionId']='different'; check(False)
    record['sessionId']=sid; record['cwd']='/wrong'; check(False)
    record['cwd']=str(tmp); record['procStart']='wrong-generation'; check(False)
    record['procStart']=start; check(True)
    # Locale must not change the generation check on macOS.
    localized = dict(os.environ, LC_ALL='en_GB.UTF-8')
    assert subprocess.run(command,env=localized,capture_output=True).returncode == 0
    process.terminate();process.wait()
    check(False)
    print('PASS: real process, session/cwd/status/generation refusal, locale, stopped process')
finally:
    if process.poll() is None:
        process.terminate();process.wait()
PY
rc=$?
[ "$rc" -eq 0 ] || fail "native Claude session public CLI tests failed"
pass "native session verification binds the exact live process generation"
