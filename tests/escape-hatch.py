#!/usr/bin/env python3
"""Prove the emergency escape still works — the gating question for taking Ctrl+C.

If Ctrl+C never quits, Ctrl+\\ (SIGQUIT) is the only keyboard way out. That has to hold
even when the app has stopped servicing its event loop, and it must leave the terminal
usable — a kill that strands you in the alt screen with raw mode set is not an escape.

SIGQUIT is TRAPPED here (`trap 'exit 131' QUIT`), not defaulted, so it needs bash to be
responsive enough to run a trap. That is exactly what a wedged app might not be, which is
why this is measured rather than assumed.

    escape-hatch.py SCRIPT [wedge]     `wedge` makes the app hang before the key is sent
"""
import os
import pty
import select
import signal
import struct
import sys
import termios
import fcntl
import time

ROWS, COLUMNS = 24, 80
QUIT_KEY = b"\x1c"          # Ctrl+\  → SIGQUIT while `isig` is on


def run(script_path, wedge):
    environment = dict(os.environ, TERM="xterm-256color",
                       LINES=str(ROWS), COLUMNS=str(COLUMNS),
                       FT_NO_WTFIX="1", FT_STATE_AUTOLOAD="0")
    if wedge:
        # Ask the app to wedge once it is up: an unkillable-looking spin inside the loop.
        environment["FT_TEST_WEDGE"] = "1"
    child_pid, terminal = pty.fork()
    if child_pid == 0:
        os.chdir(os.path.dirname(os.path.abspath(script_path)) + "/..")
        os.execvpe("bash", ["bash", script_path], environment)
        os._exit(1)
    fcntl.ioctl(terminal, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLUMNS, 0, 0))

    def drain(seconds):
        out = b""
        deadline = time.time() + seconds
        while time.time() < deadline:
            readable, _, _ = select.select([terminal], [], [], 0.1)
            if not readable:
                continue
            try:
                chunk = os.read(terminal, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
        return out

    drain(4.0)                                  # let it start and paint
    if wedge:
        # Drive it into the wedge with the key the demo binds for it, then confirm it has
        # genuinely stopped talking — otherwise this measures nothing.
        os.write(terminal, b"W")
        time.sleep(1.0)
        before = drain(1.0)
        if before:
            print("note: app still producing output; the wedge may not have taken")

    os.write(terminal, QUIT_KEY)
    tail = drain(3.0)

    status, waited = None, time.time() + 5.0
    while time.time() < waited:
        pid, raw = os.waitpid(child_pid, os.WNOHANG)
        if pid:
            status = raw
            break
        time.sleep(0.05)

    if status is None:
        try:
            os.kill(child_pid, 9); os.waitpid(child_pid, 0)
        except OSError:
            pass
        print("SURVIVED  Ctrl+\\ did not end it")
        return 1

    if os.WIFSIGNALED(status):
        print("SIGNALLED exit by signal %d (the trap did not run)" % os.WTERMSIG(status))
        code = "signal"
    else:
        code = os.WEXITSTATUS(status)
        print("EXITED    status %s" % code)

    # The EXIT trap runs ft_restore_tty, whose job is to leave the terminal usable: come off
    # the alternate screen, show the cursor again, re-enable wrap. If those are missing the
    # user's shell is left in the app's screen with an invisible cursor.
    text = tail.decode("utf-8", "replace")
    checks = {
        "left the alt screen (\\e[?1049l)": "\x1b[?1049l" in text,
        "showed the cursor (\\e[?25h)":     "\x1b[?25h" in text,
        "re-enabled wrap (\\e[?7h)":        "\x1b[?7h" in text,
    }
    for label, ok in checks.items():
        print("   %-34s %s" % (label, "yes" if ok else "NO"))
    return 0 if (code in (131, "131") and all(checks.values())) else 1


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sys.exit(run(sys.argv[1], len(sys.argv) > 2 and sys.argv[2] == "wedge"))
