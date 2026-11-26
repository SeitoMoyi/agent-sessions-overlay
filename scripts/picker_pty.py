#!/usr/bin/env python3
"""Drives `mo sessions` (the picker) in a pseudo-terminal.

    picker_pty.py <path-to-mole>          `mo sessions`: remove the oldest session
    picker_pty.py <path-to-mole> menu     `mo`: "6. Sessions" opens the picker

Default: waits for the picker, presses Enter (selects the row under the
cursor, the oldest session), then Enter at the confirm prompt, and expects
the summary. menu: waits for the main menu's Sessions line, presses 6,
expects the picker, then Q.
Exits non-zero if any screen does not appear within its timeout.
"""
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][A-Z0-9]")


def main() -> int:
    signal.alarm(120)
    menu = sys.argv[2:] == ["menu"]
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(sys.argv[1], [sys.argv[1]] if menu else [sys.argv[1], "sessions"])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 140, 0, 0))
    seen = ""

    def wait(text: str, timeout: float = 45) -> bool:
        nonlocal seen
        end = time.time() + timeout
        while time.time() < end:
            if text in ANSI.sub("", seen):
                return True
            ready, _, _ = select.select([fd], [], [], 0.2)
            if ready:
                try:
                    seen += os.read(fd, 65536).decode("utf8", "replace")
                except OSError:
                    break
        return text in ANSI.sub("", seen)

    if menu:
        steps = [(None, "6. Sessions"), ("6", "Select sessions to remove"), ("q", "")]
    else:
        steps = [(None, "Select sessions to remove"), ("\r", "Enter confirm"), ("\r", "Sessions removed")]
    for key, expect in steps:
        if key is not None:
            seen = ""
            time.sleep(0.3)
            os.write(fd, key.encode())
        if not wait(expect):
            print(f"picker: never saw {expect!r}; last screen:\n{ANSI.sub('', seen)[-1500:]}")
            os.kill(pid, signal.SIGKILL)
            return 1
    # Keep reading until the terminal closes: a child blocked on a full pty
    # buffer never exits.
    while True:
        try:
            if not os.read(fd, 65536):
                break
        except OSError:
            break
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main())
