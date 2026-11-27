#!/usr/bin/env python3
"""Dell-first placement for a fresh ship or scout spawn on a Mac home.

fm-spawn.sh owns when this runs and the --mac-reason/--needs-tool flags.
Prints the task's one-line mac_reason on stdout and exits 0 when the worker may
start on the Mac; exits 1 with the refusal on stderr when the Dell has room and
no reason was given. Capacity is AHR's own check
($HOME/Code/Agent-Harness-Reconfig/ops/claude-lane/placement.py) and the tool
list is AHR's ops/lane-tools (tools.json and the Dell's `lane-tools.py --check`
line); neither is re-implemented here. An unreadable Dell or a missing AHR probe
warns and allows the Mac, recording why.
"""

import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
from types import SimpleNamespace

# Importing the external probe must not create files in its checkout.
sys.dont_write_bytecode = True

AHR = Path.home() / "Code/Agent-Harness-Reconfig"
TOOLS_SECONDS = 60


class Unreadable(Exception):
    """The Dell or AHR's probe of it could not be read."""


def one_line(text):
    return " ".join(str(text).split())


def load_placement():
    path = AHR / "ops/claude-lane/placement.py"
    if not path.is_file():
        raise Unreadable(f"no AHR placement probe at {path}")
    spec = importlib.util.spec_from_file_location("placement", path)
    placement = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(placement)
        return placement, placement.settings()
    except (Exception, SystemExit) as exc:
        raise Unreadable(f"AHR placement probe failed to load: {exc}") from exc


def dell_lacks(placement, tools):
    """The named tools the Dell lacks, per its lane-tools --check line."""
    path = AHR / "ops/lane-tools/tools.json"
    try:
        known = {t["name"] for t in json.loads(path.read_text())["tools"]}
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise ValueError(f"cannot read the lane-tools list {path}: {exc}") from exc
    unknown = [t for t in tools if t not in known]
    if unknown:
        raise ValueError(f"--needs-tool {', '.join(unknown)} is not in the lane-tools "
                         f"list ({', '.join(sorted(known))}); give --mac-reason instead")
    check = f"{placement.DELL_CHECKOUT}/ops/lane-tools/lane-tools.py"
    try:
        proc = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", placement.DELL,
             "python3", check, "--check"],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=TOOLS_SECONDS)
    except subprocess.TimeoutExpired as exc:
        raise Unreadable(f"the Dell's lane-tools --check did not answer within {TOOLS_SECONDS}s") from exc
    # --check exits 1 when an installable tool is missing; its line still stands.
    m = re.search(r": missing (.*?); gaps (.*?)(?: \(reasons in .*\))?$", proc.stdout.strip())
    if not m:
        raise Unreadable(f"the Dell's lane-tools --check gave no line (exit {proc.returncode}: "
                         f"{one_line(proc.stderr)})")
    absent = {n for group in m.groups() for n in group.split(", ") if n != "none"}
    return [t for t in tools if t in absent]


def dell_room(placement, cfg, project):
    """None when the Dell has room, else why not. Capacity only: Claude usage,
    trust and clone checks belong to AHR's own lanes, not every worker vendor."""
    try:
        dell, why = placement.read_dell(SimpleNamespace(
            repo=project, account=None, codex=True, glm=None, backend=None), cfg)
    except (Exception, SystemExit) as exc:
        raise Unreadable(f"the Dell's placement probe failed: {exc}") from exc
    if dell is None:
        raise Unreadable(why)
    kb, disc = dell.get("mem_available_kb"), dell.get("disc_free_mb")
    if type(kb) is not int or type(disc) is not int or not placement.usable_cpu(dell):
        raise Unreadable("no usable capacity reading: " + placement.dell_readings(dell, why, cfg))
    dell = {k: v for k, v in dell.items() if k not in ("repo_error", "account_error")}
    fault, detail = placement.dell_fault(dell, why, cfg, anthropic=False)
    print(f"fm-spawn: {placement.dell_readings(dell, why, cfg)}", file=sys.stderr)
    return f"{fault}: {detail}" if fault else None


def registered(home, host):
    """(id, line) for each secondmate route in home's registry hosted on host."""
    try:
        lines = (Path(home) / "data/secondmates.md").read_text().splitlines()
    except OSError:
        return []
    found = (re.match(r"- (\S+) - .*\(host: (\S+?);", line) for line in lines)
    return [(m.group(1), m.group(0)) for m in found if m and m.group(2) == host]


def dell_route(home, task, host):
    """How this home hands the task to its Dell partner. A local secondmate's
    partner is registered in its parent home, and is the Dell route whose line
    names this home when one does."""
    routes = [f"bin/fm-backlog-handoff.sh {p} {task}" for p, _ in registered(home, host)]
    try:
        marker = dict(line.split("=", 1) for line in
                      (Path(home) / ".fm-secondmate-parent").read_text().splitlines() if "=" in line)
        me = (Path(home) / ".fm-secondmate-home").read_text().strip()
    except OSError:
        marker, me = {}, ""
    parent = marker.get("parent_home") if marker.get("route") == "local" else None
    if parent:
        theirs = registered(parent, host)
        mine = [p for p, line in theirs if re.search(rf"\b{re.escape(me)}\b", line)] if me else []
        routes += [f"FM_HOME={parent} bin/fm-backlog-handoff.sh {p} {task}"
                   for p in (mine or [p for p, _ in theirs])]
    if routes:
        return "hand it to the Dell partner with " + " or ".join(routes)
    return ("no Dell partner is registered for this home in data/secondmates.md; provision one "
            "(secondmate-provisioning, remote route) and hand the task to it")


def place(args):
    reason = one_line(args.mac_reason)
    if reason:
        return reason
    placement, cfg = load_placement()
    if args.needs_tool:
        lacking = dell_lacks(placement, args.needs_tool)
        if lacking:
            return "tool missing on Dell: " + ", ".join(lacking)
    fault = dell_room(placement, cfg, args.project)
    if fault:
        return "Dell has no room: " + one_line(fault)
    route = dell_route(args.home, args.task, placement.DELL)
    raise ValueError(f"the Dell has room, so this worker belongs there: {route}. "
                     "To start it on the Mac, give --mac-reason '<why it needs the Mac>' "
                     "(or --needs-tool <tool> for a lane tool the Dell lacks)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--task", required=True)
    parser.add_argument("--home", required=True)
    parser.add_argument("--mac-reason", default="")
    parser.add_argument("--needs-tool", action="append", default=[])
    args = parser.parse_args()
    try:
        reason = place(args)
    except Unreadable as exc:
        reason = "Dell not readable: " + one_line(exc)
        print(f"warning: {reason}; starting this worker on the Mac", file=sys.stderr)
    except ValueError as exc:
        print(f"error: spawn refused: {exc}", file=sys.stderr)
        return 1
    print(f"fm-spawn: Mac start, mac_reason={reason}", file=sys.stderr)
    print(reason)
    return 0


if __name__ == "__main__":
    sys.exit(main())
