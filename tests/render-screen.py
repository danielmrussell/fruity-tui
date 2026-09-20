#!/usr/bin/env python3
"""Render a Fruity TUI app in a real pty and print the resulting screen as plain text.

The unit suite checks state; this checks PIXELS. Three rendering regressions in this
project passed a fully green suite and were caught only by looking at a frame, so
anything that changes drawing has to be gated on the actual screen.

    render-screen.py SCRIPT [keys…]     keys: a comma-separated script, e.g. "> 0.6,< 0.6"

Prints the visible grid, one line per row, trailing blanks stripped. Escape sequences are
interpreted only as far as cursor positioning — the point is what a human would see.
"""
import codecs
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import fcntl
import time
import unicodedata

# Overridable so a demo can be checked at the size a person's terminal actually is —
# a layout that behaves at 40x118 can still be wrong at 24x80.
ROWS = int(os.environ.get("FT_TEST_ROWS", 40))
COLUMNS = int(os.environ.get("FT_TEST_COLS", 118))
SETTLE_SECONDS = 3.5           # the app negotiates the keyboard protocol before its first frame

# The real CSI grammar: parameter bytes 0x30–0x3F, then intermediate bytes 0x20–0x2F, then one
# final byte 0x40–0x7E. Anything narrower silently leaks sequences onto the captured screen as
# literal text — the previous [0-9;?]*[A-Za-z] missed both the private-parameter form the
# keyboard negotiation uses (CSI > 4 ; 0 m) and the intermediate-byte form of the cursor-shape
# reset (CSI 0 SP q), so ">4;0m" and "0 q" appeared as visible characters in a frame.
CSI = re.compile(r'\[([0-?]*)([ -/]*)([@-~])')
PARTIAL_CSI = re.compile(r'\[[0-?]*[ -/]*')  # a CSI sequence cut off by a chunk boundary
OSC = re.compile(r'\][0-9]*;[^\x07\x1b]*(\x07|\x1b\\)')
KEYS = {"PGDN": "\x1b[6~", "PGUP": "\x1b[5~", "TAB": "\t", "ENTER": "\r",
        "SPACE": " ", "DOWN": "\x1b[B", "UP": "\x1b[A", "ESC": "\x1b",
        "HOME": "\x1b[H", "END": "\x1b[F",
        "LEFT": "\x1b[D", "RIGHT": "\x1b[C", "BTAB": "\x1b[Z"}
# Ctrl chords, as CTRL+S / CTRL+Z / CTRL+C. The framework took these back from the tty
# (undo, copy, save), so they are exactly the keys whose effect has to be gated on a
# SCREEN — an app that saves without showing it looks identical to one that ignored you.
KEYS.update({"CTRL+" + chr(ord("A") + n): chr(n + 1) for n in range(26)})


class Screen:
    """Just enough terminal to know what ended up on each cell."""

    def __init__(self, rows=None, columns=None):
        # Instance state, not the module globals: the grid has to follow a mid-run RESIZE.
        self.rows = rows if rows is not None else ROWS
        self.columns = columns if columns is not None else COLUMNS
        self.cells = [[" "] * self.columns for _ in range(self.rows)]
        self.row = self.column = 0
        self.pending = ""

    def feed(self, data):
        data, self.pending = self.pending + data, ""
        index = 0
        while index < len(data):
            character = data[index]
            if character == "\x1b":
                if index + 1 >= len(data):
                    self.pending = data[index:]          # a bare ESC ends this chunk
                    return
                if data[index + 1] == "]":
                    match = OSC.match(data, index + 1)
                    if not match:
                        self.pending = data[index:]      # OSC split across reads
                        return
                    index = match.end()
                    continue
                match = CSI.match(data, index + 1)
                if match:
                    if match.group(3) == "H" and not match.group(2):
                        parts = [int(p) for p in match.group(1).split(";") if p != ""]
                        self.row = max(0, (parts[0] if parts else 1) - 1)
                        self.column = max(0, (parts[1] if len(parts) > 1 else 1) - 1)
                    index = match.end()      # absolute: the ESC and the sequence are consumed
                    continue
                # No complete match. If what remains is a valid PREFIX of a CSI sequence, it was
                # split across reads — hold it and finish when the rest arrives. Getting this
                # wrong leaks half an escape into the screen as literal text.
                if PARTIAL_CSI.fullmatch(data[index + 1:]):
                    self.pending = data[index:]
                    return
                index += 2
                continue
            if character == "\r":
                self.column = 0
            elif character == "\n":
                self.row = min(self.rows - 1, self.row + 1)
            elif character == "\t":
                # A terminal advances to the next 8-column tab stop — it does NOT print one
                # cell. Ignoring that modelled a tab exactly as wrongly as the code under test
                # does, so this gate could never see text walking out of its box on one.
                self.column = min(self.columns - 1, (self.column // 8 + 1) * 8)
            elif ord(character) >= 32:
                # Advance by COLUMNS, not by characters. A double-width glyph (CJK, emoji)
                # occupies two cells; counting one modelled wide text exactly as wrongly as a
                # bug in the code under test would, so this gate could never see such a bug.
                width = 0 if unicodedata.combining(character) else \
                    (2 if unicodedata.east_asian_width(character) in ("W", "F") else 1)
                if 0 <= self.row < self.rows and 0 <= self.column < self.columns:
                    self.cells[self.row][self.column] = character
                self.column += width
            index += 1

    def resize(self, rows, columns):
        """Grow/shrink the grid the way a terminal does: content stays anchored at the top
        left, new cells are blank. Deliberately NOT cleared — a repaint that fails to cover
        the new geometry must leave its stale cells visible, or the test cannot see it."""
        grid = [[" "] * columns for _ in range(rows)]
        for r in range(min(rows, len(self.cells))):
            for c in range(min(columns, len(self.cells[0]))):
                grid[r][c] = self.cells[r][c]
        self.cells = grid
        self.rows, self.columns = rows, columns
        self.row = min(self.row, rows - 1)
        self.column = min(self.column, columns - 1)

    def __str__(self):
        return "\n".join("".join(row).rstrip() for row in self.cells)


def run(script_path, key_script):
    # A golden screen must depend on the app and NOTHING else. Ctrl+S state restores on
    # start (ft-state.bash), so whoever last pressed Ctrl+S in a demo would otherwise
    # decide what this test sees — the suite would pass or fail on the contents of the
    # developer's home directory. Launch every app as if it had never been saved.
    # And NEVER RECORD unless the caller asks: a demo that auto-records its last run
    # (callout-demo → /tmp/callout-last.rec) would have that recording — the evidence of
    # whatever the user just reported — overwritten by the first gate or probe that runs it.
    environment = dict(os.environ, TERM="xterm-256color",
                       LINES=str(ROWS), COLUMNS=str(COLUMNS), FT_NO_WTFIX="1",
                       FT_STATE_AUTOLOAD=os.environ.get("FT_STATE_AUTOLOAD", "0"),
                       FT_RECORD=os.environ.get("FT_RECORD", ""))
    child_pid, terminal = pty.fork()
    if child_pid == 0:
        os.chdir(os.path.dirname(os.path.abspath(script_path)) + "/..")
        os.execvpe("bash", ["bash", script_path], environment)
        os._exit(1)
    # A pty is 0x0 until told otherwise, and a zero-size screen lays out to nothing.
    fcntl.ioctl(terminal, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLUMNS, 0, 0))

    screen = Screen()
    # A multi-byte character can straddle a read() boundary. Decoding each chunk on its own
    # turns the split halves into U+FFFD, which makes the screen — and therefore the gate —
    # nondeterministic. An incremental decoder holds the partial sequence instead.
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")

    # WAIT FOR QUIET, NOT FOR THE CLOCK. A fixed wall-clock pause assumes the app gets a fixed
    # share of the CPU inside it — false when the whole suite is running, where the same 1.2s
    # buys far less work and a frame is captured half-painted. That made the gate FLAKY: the
    # state-restore scenario failed roughly one run in two and passed alone every time, which
    # is the worst kind of test, because the honest response to it is to stop believing it.
    #
    # So `seconds` is now a MINIMUM. After it, keep reading while the app is still talking,
    # and only stop once the pty has been silent for QUIET_SECONDS — capped, so a demo with a
    # permanent animation still terminates.
    QUIET_SECONDS = 0.25
    saw_data = [False]              # did the app ever speak? (see the check at the end)
    def pump(seconds, quiet=QUIET_SECONDS, what="settle", require_output=False):
        floor = time.time() + seconds
        cap = time.time() + max(seconds * 4, seconds + 3.0)
        last_data = time.time()
        spoke_here = False           # has THIS pump seen a byte yet?
        while True:
            now = time.time()
            if now >= cap:
                return
            # "Quiet" means the app STOPPED talking — which is only meaningful once it has
            # STARTED. last_data begins at `now`, so with no output yet the two are
            # indistinguishable: at the floor, now - last_data is the whole settle time, the
            # pump concludes "finished" and returns a blank screen. Under load an app can
            # easily take longer than the floor to reach its first paint, and the result was
            # an empty capture reported as "the app rendered nothing" — a flake that passed
            # on every rerun and failed inside a full suite. Wait for it to speak first; the
            # cap still bounds the wait, so a genuinely dead app is not waited on forever.
            #
            # Only STARTUP requires output. A keypress pump must NOT: plenty of keys correctly
            # paint nothing (a bubbled arrow at the edge of a list), and making those wait for
            # the cap would add seconds to every such step — trading a rare flake for a slow
            # suite on every single run.
            if now >= floor and (spoke_here or not require_output) and now - last_data >= quiet:
                return
            readable, _, _ = select.select([terminal], [], [], 0.05)
            if not readable:
                continue
            try:
                chunk = os.read(terminal, 65536)
            except OSError:
                return
            if not chunk:
                return
            last_data = time.time()
            saw_data[0] = True
            spoke_here = True
            screen.feed(decoder.decode(chunk))

    pump(SETTLE_SECONDS, what="startup", require_output=True)
    for step in (s.strip() for s in key_script.split(",") if s.strip()):
        pieces = step.split()
        pause = float(pieces[-1]) if re.match(r"^[0-9.]+$", pieces[-1]) else 0.5
        keys = pieces[:-1] if re.match(r"^[0-9.]+$", pieces[-1]) else pieces
        # A number is a pause only in LAST place; anywhere else it is sent as literal
        # keystrokes. "K 0.5 2.0" quietly types "0", ".", "5" into the app — which reads as a
        # rendering bug in whatever you were comparing against. Refuse it instead.
        stray = [k for k in keys if re.match(r"^[0-9.]+$", k) and len(k) > 1]
        if stray:
            sys.exit("render-screen.py: %r in %r — a pause must be the LAST word of a step"
                     % (stray[0], step))
        # RESIZE:COLSxROWS — retype the pty and raise SIGWINCH, the way a person dragging a
        # window corner does. Nothing else exercises the resize path, and a layout that only
        # ever renders at one size can be wrong at every other one.
        for key in list(keys):
            if not key.startswith("RESIZE:"):
                continue
            new_columns, _, new_rows = key[len("RESIZE:"):].partition("x")
            new_columns, new_rows = int(new_columns), int(new_rows)
            fcntl.ioctl(terminal, termios.TIOCSWINSZ,
                        struct.pack("HHHH", new_rows, new_columns, 0, 0))
            os.kill(child_pid, signal.SIGWINCH)
            screen.resize(new_rows, new_columns)
            keys.remove(key)
        for key in keys:
            # MOUSE:b;c;r;M — one SGR mouse event, exactly the bytes a terminal sends:
            # b = button code (0 press, 32 motion-with-button-held), c/r = 1-based col/row,
            # final M = press/motion, m = release. The only way to drive a DRAG through the
            # real run loop — synthesizing FT_EVENT tokens skips the input layer, the
            # coalescing, and everything a real mouse actually exercises.
            if key.startswith("MOUSE:"):
                b, c, r, kind = key[len("MOUSE:"):].split(";")
                os.write(terminal, ("\x1b[<%s;%s;%s%s" % (b, c, r, kind)).encode())
                continue
            os.write(terminal, KEYS.get(key, key).encode())
        pump(pause, what="after %r" % step)
    # Normally we quit the app so it tears down cleanly. But anything DISMISSED BY THE NEXT
    # KEYPRESS — a transient confirmation, a hint — is destroyed by that very "q", so the
    # gate could never see it. FT_TEST_QUITKEY="" captures the frame as it stands and kills
    # the child instead.
    quit_key = os.environ.get("FT_TEST_QUITKEY", "q")
    if quit_key:
        os.write(terminal, quit_key.encode())
        pump(0.3)
    # The quit key is a REQUEST, not a guarantee — most scenarios here end with the caret in an
    # open text field, where "q" is simply the letter q (which is why the goldens carry a
    # trailing q). So never wait for the child to leave on its own: kill it and reap.
    try:
        os.kill(child_pid, 9)
        os.waitpid(child_pid, 0)
    except OSError:
        pass
    # NO OUTPUT AT ALL can never be a legitimate frame — the app did not start. Returning the
    # blank screen made that look like a golden mismatch, i.e. like a rendering regression,
    # which sends you hunting in the wrong file entirely.
    if not saw_data[0]:
        sys.exit("render-screen.py: the app produced no output at all "
                 "(did it fail to start? run it by hand, or check FT_TEST_ROWS/COLS)")
    # NOTE: reaching pump's cap is NOT a usable signal and is deliberately not reported.
    # It was tried: a text field animates its border for as long as the caret is in it, so
    # these demos never go quiet and every scenario caps as a matter of course. "Capped" and
    # "half-painted" are not the same thing here, and treating them as the same turned a
    # green gate red across the board.
    return str(screen)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    print(run(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""))
