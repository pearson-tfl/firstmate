#!/usr/bin/env python3
"""Verify Claude's native session identity, including process generation.

Usage: fm-claude-session.py ROOT SESSION WORKTREE [idle]
Print the sole live native PID matching the exact conversation and local copy.
Never infer a successful resume from launch arguments or rendered banners.
"""
import json
import os
from pathlib import Path
import subprocess
import sys


def matching(root, session, worktree, idle=False):
    found = []
    for path in (Path(root) / "sessions").glob("*.json"):
        try:
            record = json.loads(path.read_text())
            pid = int(path.stem)
            if record.get("pid") != pid or record.get("sessionId") != session:
                continue
            if os.path.realpath(record.get("cwd", "")) != os.path.realpath(worktree):
                continue
            if idle and record.get("status") != "idle":
                continue
            start = record.get("procStart", "").strip()
            if not start:
                continue
            # Separate columns: macOS truncates comm when lstart follows it.
            # Locale is fixed because Claude writes the C-locale ps form.
            env = dict(os.environ, LC_ALL="C")
            proc = subprocess.run(["ps", "-ww", "-p", str(pid), "-o", "comm="],
                                  capture_output=True, text=True, timeout=5, env=env)
            if proc.returncode or "claude" not in proc.stdout.strip().lower():
                continue
            if start.isdigit():
                stat = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
                if stat[19] != start:
                    continue
            else:
                live = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="],
                                      capture_output=True, text=True, timeout=5, env=env)
                if live.returncode or " ".join(live.stdout.split()) != " ".join(start.split()):
                    continue
            found.append(pid)
        except (OSError, ValueError, TypeError, subprocess.SubprocessError):
            continue
    if len(found) != 1:
        raise ValueError(f"expected one live Claude record for session {session} in {root}; found {len(found)}")
    return found[0]


if __name__ == "__main__":
    try:
        print(matching(*sys.argv[1:4], idle=sys.argv[4:] == ["idle"]))
    except ValueError as error:
        print("error: " + str(error), file=sys.stderr)
        sys.exit(1)
