#!/usr/bin/env python3
"""Interpret a raw escape stream into a grid of CELLS — glyph AND attributes.

    screen-cells.py FILE [rows] [cols]

tests/render-screen.py already turns a frame into text, but it drops every attribute, so it
cannot see a cell painted in the wrong colour — and "same glyph, wrong colour" is exactly what
a stale style cache produces. This keeps the SGR state per cell, so two frames can be compared
for what a person would actually see rather than for the bytes that produced it.

Output: one line per non-blank cell, "row,col<TAB>glyph<TAB>attrs", which diffs cleanly.
"""
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
        self.bold = self.underline = self.reverse = self.dim = False

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
            elif code == 4:
                self.underline = True
            elif code == 7:
                self.reverse = True
            elif code == 22:
                self.bold = self.dim = False
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
                        (("b", self.bold), ("d", self.dim),
                         ("u", self.underline), ("r", self.reverse)) if on)
        return f"fg={self.fg} bg={self.bg} {flags}"


def render(data, rows, columns):
    cells = [[None] * columns for _ in range(rows)]
    pen = Pen()
    row = column = 0
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
                if final == "H" and not match.group(2):
                    parts = [int(p) for p in params.split(";") if p != ""]
                    row = max(0, (parts[0] if parts else 1) - 1)
                    column = max(0, (parts[1] if len(parts) > 1 else 1) - 1)
                elif final == "m" and not params.startswith(("<", "=", ">", "?")):
                    # PRIVATE-parameter forms are not SGR: the keyboard-protocol negotiation
                    # sends CSI > 4 ; 0 m, and feeding ">4" to the colour parser blows up.
                    pen.apply(params)
                index = match.end()
                continue
            index += 2
            continue
        if character == "\r":
            column = 0
        elif character == "\n":
            row = min(rows - 1, row + 1)
        elif ord(character) >= 32:
            width = char_cols(character)
            if 0 <= row < rows and 0 <= column < columns:
                cells[row][column] = (character, pen.signature())
                # A double-width glyph OWNS the next cell too; record it so the grid's column
                # numbers stay true to the terminal's.
                if width == 2 and column + 1 < columns:
                    cells[row][column + 1] = ("", pen.signature())
            column += width
        index += 1
    return cells


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
