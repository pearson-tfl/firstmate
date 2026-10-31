"""Run a command on a fresh pseudo-terminal and answer its approval prompt.

Usage: pty-answer.py --answer-from-prompt <command> [args...]
       pty-answer.py --answer <text> <command> [args...]

The child gets the pty as its controlling terminal, so a script that reads its
confirmation from /dev/tty sees a real terminal. With --answer-from-prompt the
answer is the code in the child's "Type <code> to approve" prompt; with
--answer it is the given text. Prints the child's terminal output and exits
with the child's exit status.
"""

import os
import pty
import re
import select
import sys


def main(argv):
    if len(argv) < 2:
        sys.exit("usage: pty-answer.py (--answer-from-prompt | --answer <text>) <command> [args...]")
    fixed = None
    if argv[0] == "--answer":
        fixed, cmd = argv[1], argv[2:]
    elif argv[0] == "--answer-from-prompt":
        cmd = argv[1:]
    else:
        sys.exit("pty-answer.py: unknown mode " + argv[0])
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(cmd[0], cmd)
    seen = b""
    answered = False
    while True:
        ready, _, _ = select.select([fd], [], [], 20)
        if not ready:
            os.kill(pid, 9)
            sys.stdout.write(seen.decode(errors="replace"))
            sys.exit("pty-answer.py: timed out waiting for the child")
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        seen += chunk
        if not answered:
            match = re.search(rb"Type (\S+) to approve", seen)
            if match:
                answer = fixed.encode() if fixed is not None else match.group(1)
                os.write(fd, answer + b"\n")
                answered = True
    _, status = os.waitpid(pid, 0)
    sys.stdout.write(seen.decode(errors="replace"))
    sys.exit(os.waitstatus_to_exitcode(status))


if __name__ == "__main__":
    main(sys.argv[1:])
