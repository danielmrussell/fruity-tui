#!/usr/bin/env python3
"""Interpret a raw escape stream into a grid of CELLS — glyph AND attributes.

    screen-cells.py FILE [rows] [cols]

tests/render-screen.py already turns a frame into text, but it drops every attribute, so it
cannot see a cell painted in the wrong colour — and "same glyph, wrong colour" is exactly what
a stale style cache produces. This keeps the SGR state per cell, so two frames can be compared
for what a person would actually see rather than for the bytes that produced it.

Output: one line per non-blank cell, "row,col<TAB>glyph<TAB>attrs", which diffs cleanly.

As a module, `Terminal` is the screen itself: feed it bytes in as many pieces as they arrived
and read the grid between them. tests/incremental-screens.py drives it that way, because the
question it asks — did an incremental frame leave the screen a full repaint would have made —
needs the screen as it stood BEFORE the frame, not a grid built from nothing.
"""
import functools
import re
import sys
import unicodedata


def char_cols(ch):
    """Terminal columns one character occupies — the same rule as ft_char_cols.

    Advancing one column per glyph (which this tool and tests/render-screen.py both used to
    do) models a double-width character exactly as wrongly as the code under test, so a grid
    built that way can never see a CJK/emoji layout bug. It has to count columns.
    """
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1

CSI = re.compile(r'\[([0-?]*)([ -/]*)([@-~])')
OSC = re.compile(r'\][0-9]*;[^\x07\x1b]*(\x07|\x1b\\)')


class Pen:
    """Just enough SGR state to tell two paints apart."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.fg = self.bg = "-"
        self.bold = self.underline = self.reverse = self.dim = self.italic = False

    def apply(self, params):
        codes = [int(p) if p else 0 for p in params.split(";")] if params else [0]
        index = 0
        while index < len(codes):
            code = codes[index]
            if code == 0:
                self.reset()
            elif code == 1:
                self.bold = True
            elif code == 2:
                self.dim = True
            elif code == 3:
                self.italic = True
            elif code == 4:
                self.underline = True
            elif code == 7:
                self.reverse = True
            elif code == 22:
                self.bold = self.dim = False
            elif code == 23:
                self.italic = False
            elif code == 24:
                self.underline = False
            elif code == 27:
                self.reverse = False
            elif code in (38, 48) and index + 1 < len(codes):
                # 38;5;N (256) or 38;2;R;G;B (truecolor) — consume the whole run, or the
                # colour components would be read back as separate attribute codes.
                kind = codes[index + 1]
                if kind == 5 and index + 2 < len(codes):
                    value = f"5:{codes[index + 2]}"
                    index += 2
                elif kind == 2 and index + 4 < len(codes):
                    value = f"2:{codes[index + 2]},{codes[index + 3]},{codes[index + 4]}"
                    index += 4
                else:
                    index += 1
                    value = "?"
                if code == 38:
                    self.fg = value
                else:
                    self.bg = value
            elif 30 <= code <= 37 or 90 <= code <= 97:
                self.fg = str(code)
            elif 40 <= code <= 47 or 100 <= code <= 107:
                self.bg = str(code)
            elif code == 39:
                self.fg = "-"
            elif code == 49:
                self.bg = "-"
            index += 1

    def signature(self):
        flags = "".join(letter for letter, on in
                        (("b", self.bold), ("d", self.dim), ("i", self.italic),
                         ("u", self.underline), ("r", self.reverse)) if on)
        return f"fg={self.fg} bg={self.bg} {flags}"


def _colour(value):
    """One name per colour, whichever SGR spelling painted it.

    Foreground 31, background 41 and 256-colour index 1 are the same palette entry; a
    comparison of the raw codes would call a reversed red-on-blue different from blue-on-red.
    """
    if value.isdigit():
        code = int(value)
        for base, offset in ((30, 0), (40, 0), (90, 8), (100, 8)):
            if base <= code <= base + 7:
                return f"palette:{code - base + offset}"
    if value.startswith("5:") and value[2:].isdigit() and int(value[2:]) < 16:
        return f"palette:{value[2:]}"
    return value


@functools.lru_cache(maxsize=None)     # a screen holds a few dozen distinct cells, asked about thousands of times
def appearance(cell):
    """What a person sees in one cell, so that two cells compare equal exactly when they LOOK equal.

    A raw (glyph, signature) pair over-reports in two ways, and a gate built on it cries wolf:
      - a SPACE has no visible foreground, bold, dim or italic — only its background and an
        underline show — so a blank painted with a different pen is not a different screen;
      - REVERSE is a swap, so `x` in fg=A bg=B reversed looks exactly like `x` in fg=B bg=A.
    And it under-reports in none: every colour that reaches the eye is still in the answer.
    A cell nothing ever wrote stays None, which is not the same as a written blank.
    """
    if cell is None:
        return None
    glyph, signature = cell
    fg, bg, flags = signature.split(" ", 2)
    fg, bg = _colour(fg[len("fg="):]), _colour(bg[len("bg="):])
    if "r" in flags:
        # The terminal's own defaults are two DIFFERENT colours, so a swapped default has to
        # keep saying which one it was.
        fg, bg = (bg if bg != "-" else "default-bg"), (fg if fg != "-" else "default-fg")
        flags = flags.replace("r", "")
    if glyph == " ":
        return (" ", bg, "u" if "u" in flags else "")
    return (glyph, fg, bg, flags)


class Terminal:
    """Just enough terminal to know what ended up on each cell: cursor addressing, SGR, and
    the two erasures the framework sends (CSI 2J clearing the screen, CSI K a line).

    An erase paints BLANKS IN THE CURRENT BACKGROUND (xterm's background-colour-erase, which
    every terminal the framework targets implements), and that is why ft_repaint_all sets the
    screen colour before it clears: the clear is itself paint. Ignoring the two sequences — as
    this tool did while every caller compared frames that never contained one — leaves the cells
    of a previous frame standing under a clear that removed them.
    """

    def __init__(self, rows, columns):
        self.rows = rows
        self.columns = columns
        self.cells = [[None] * columns for _ in range(rows)]
        self.pen = Pen()
        self.row = self.column = 0

    def copy(self):
        """The same screen, to be written on without disturbing this one."""
        twin = Terminal(self.rows, self.columns)
        twin.cells = [row[:] for row in self.cells]    # cells are immutable tuples: rows suffice
        twin.pen.__dict__.update(self.pen.__dict__)
        twin.row, twin.column = self.row, self.column
        return twin

    def _blank(self, row, first, last):
        blank = (" ", self.pen.signature())
        for column in range(max(0, first), min(self.columns, last)):
            self.cells[row][column] = blank

    def feed(self, data):
        index = 0
        while index < len(data):
            character = data[index]
            if character == "\x1b":
                if index + 1 < len(data) and data[index + 1] == "]":
                    match = OSC.match(data, index + 1)
                    index = match.end() if match else len(data)
                    continue
                match = CSI.match(data, index + 1)
                if match:
                    final, params = match.group(3), match.group(1)
                    private = params.startswith(("<", "=", ">", "?")) or match.group(2)
                    if final == "H" and not match.group(2):
                        parts = [int(p) for p in params.split(";") if p != ""]
                        self.row = max(0, (parts[0] if parts else 1) - 1)
                        self.column = max(0, (parts[1] if len(parts) > 1 else 1) - 1)
                    elif final == "m" and not private:
                        # PRIVATE-parameter forms are not SGR: the keyboard-protocol negotiation
                        # sends CSI > 4 ; 0 m, and feeding ">4" to the colour parser blows up.
                        self.pen.apply(params)
                    elif final == "J" and not private and params in ("2", "3"):
                        for row in range(self.rows):
                            self._blank(row, 0, self.columns)
                    elif final == "K" and not private and 0 <= self.row < self.rows:
                        mode = params or "0"
                        if mode == "0":
                            self._blank(self.row, self.column, self.columns)
                        elif mode == "1":
                            self._blank(self.row, 0, self.column + 1)
                        elif mode == "2":
                            self._blank(self.row, 0, self.columns)
                    index = match.end()
                    continue
                index += 2
                continue
            if character == "\r":
                self.column = 0
            elif character == "\n":
                self.row = min(self.rows - 1, self.row + 1)
            elif ord(character) >= 32:
                width = char_cols(character)
                if 0 <= self.row < self.rows and 0 <= self.column < self.columns:
                    self.cells[self.row][self.column] = (character, self.pen.signature())
                    # A double-width glyph OWNS the next cell too; record it so the grid's column
                    # numbers stay true to the terminal's.
                    if width == 2 and self.column + 1 < self.columns:
                        self.cells[self.row][self.column + 1] = ("", self.pen.signature())
                self.column += width
            index += 1


def render(data, rows, columns):
    terminal = Terminal(rows, columns)
    terminal.feed(data)
    return terminal.cells


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    rows = int(sys.argv[2]) if len(sys.argv) > 2 else 40
    columns = int(sys.argv[3]) if len(sys.argv) > 3 else 120
    with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
        cells = render(handle.read(), rows, columns)
    out = []
    for r, line in enumerate(cells):
        for c, cell in enumerate(line):
            if cell is not None and cell[0] != " ":
                out.append(f"{r:3d},{c:3d}\t{cell[0]}\t{cell[1]}")
    print("\n".join(out))


if __name__ == "__main__":
    main()
