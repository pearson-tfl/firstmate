#!/usr/bin/env python3
"""Exact Claude composer transfer through its external editor, never the screen.

Claude launches set EDITOR to this program's `edit` command, carrying the user's
original editor in FM_CLAUDE_REAL_EDITOR. With no control request it delegates to
that editor. A request is private to one launch and expires after 30 seconds.
`prepare DIR take|restore|read BACKUP` prints a nonce; the controller sends Ctrl-G
then calls `wait DIR NONCE`. take saves bytes before clearing; restore requires
an empty editor file (or the controller's exact placeholder, for Claude versions
that ignore Ctrl-G on an empty composer); read compares bytes unchanged. No command
submits the composer. All backups and failure records remain available.
"""

import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import time


def atomic(path, data):
    """Publish private bytes, with fsync before the rename."""
    path = Path(path)
    temp = path.with_name(path.name + "." + secrets.token_hex(8))
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)


def edit(filename):
    directory = Path(os.environ["FM_CLAUDE_DRAFT_DIR"])
    request = directory / "request.json"
    try:
        body = json.loads(request.read_text())
    except FileNotFoundError:
        return subprocess.call(shlex.split(os.environ.get("FM_CLAUDE_REAL_EDITOR") or "vi") + [filename])
    nonce = body["nonce"]
    claimed = directory / (nonce + ".request")
    os.replace(request, claimed)
    try:
        if time.time() > body["expires"]:
            raise ValueError("draft request expired; composer left unchanged")
        source = Path(filename)
        current = source.read_bytes()
        backup = Path(body["backup"])
        if body["mode"] == "take":
            # Never overwrite an earlier saved draft, including an empty one.
            fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as stream:
                stream.write(current)
                stream.flush()
                os.fsync(stream.fileno())
            source.write_bytes(b"")
        elif body["mode"] == "restore":
            if current != body.get("placeholder", "").encode():
                raise ValueError("replacement composer is not empty or the exact placeholder; saved draft retained")
            source.write_bytes(backup.read_bytes())
        elif body["mode"] == "read":
            if current != backup.read_bytes():
                raise ValueError("composer readback differs from saved draft")
        else:
            raise ValueError("unknown draft operation")
        result = {"ok": True}
    except (OSError, ValueError) as error:
        result = {"ok": False, "error": str(error)}
    atomic(directory / (nonce + ".result"), json.dumps(result).encode())
    # Return normally even on refusal: Claude must recover the unchanged text.
    return 0


def main():
    command, *args = sys.argv[1:]
    if command == "edit":
        return edit(args[0])
    directory = Path(args[0])
    if command == "prepare":
        mode, backup = args[1:3]
        placeholder = args[3] if len(args) == 4 else ""
        if len(args) not in (3, 4) or (placeholder and mode != "restore"):
            raise ValueError("placeholder is only valid for restore")
        if mode not in ("take", "restore", "read"):
            raise ValueError("invalid draft operation")
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        if (directory / "request.json").exists():
            raise ValueError("an earlier draft request needs reconciliation")
        nonce = secrets.token_hex(16)
        atomic(directory / "request.json", json.dumps({
            "nonce": nonce, "expires": time.time() + 30,
            "mode": mode, "backup": str(Path(backup).resolve()), "placeholder": placeholder,
        }).encode())
        print(nonce)
        return 0
    if command == "wait":
        nonce = args[1]
        if len(nonce) != 32 or any(c not in "0123456789abcdef" for c in nonce):
            raise ValueError("invalid draft request identity")
        end = time.monotonic() + 30
        while time.monotonic() < end:
            result = directory / (nonce + ".result")
            if result.exists():
                body = json.loads(result.read_text())
                if not body.get("ok"):
                    raise ValueError(body.get("error", "draft operation refused"))
                return 0
            time.sleep(0.1)
        raise ValueError("Claude did not acknowledge its external editor; saved draft retained")
    raise ValueError("unknown command")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError) as error:
        print("error: " + str(error), file=sys.stderr)
        sys.exit(1)
