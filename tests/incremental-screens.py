#!/usr/bin/env python3
"""Replay a gate's recorded frames and say, per case, whether the incremental frame left the
screen a full repaint would have made.

    incremental-screens.py ROWS COLUMNS DIR…

Each DIR is one fixture, written by tests/test-incremental.bash:

    DIR/cases       one line per case:  ID <TAB> ITEM <TAB> COMMAND
    DIR/ID.full     a cold full repaint of the state after the case
    DIR/ID.inc      the bytes the incremental path wrote for the case

A case whose ITEM is `base` has no .inc: its full repaint is a freshly built scene, and it is
the screen the next case starts from rather than something to compare.

The screen a person had before case N is the full repaint after case N-1, because that is what
the gate put on it — so the incremental screen is that grid with ID.inc fed on top, and the
oracle is ID.full fed onto nothing. Both are compared by appearance (tools/screen-cells.py),
cell for cell, blanks included: a band of the wrong background has no glyph to find it by.

Output, one line per case:   DIR <TAB> ID <TAB> ITEM <TAB> VERDICT <TAB> COMMAND <TAB> DETAIL
    changed     the frames agree, and the case moved something on the screen
    unchanged   the frames agree, and the screen is what it was — agreement, but not evidence
    differ      they do not agree; DETAIL names the count and the first cells
    blank       the full repaint put no ink on the screen at all, so there is nothing to compare
"""
import importlib.util
import os
import sys

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "screen_cells", os.path.join(_here, "..", "tools", "screen-cells.py"))
screen_cells = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(screen_cells)

FIRST_DIFFERENCES = 3


def read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def looks(terminal):
    return [[screen_cells.appearance(cell) for cell in row] for row in terminal.cells]


def has_ink(grid):
    return any(cell is not None and cell[0] not in (" ", "") for row in grid for cell in row)


def describe(cell):
    if cell is None:
        return "never-written"
    return "/".join(part for part in cell if part) or "blank"


def compare(rows, columns, directory):
    with open(os.path.join(directory, "cases"), encoding="utf-8") as handle:
        cases = [line.rstrip("\n").split("\t") for line in handle if line.strip()]
    before = before_look = None                     # the screen as the previous case left it
    for identifier, item, command in cases:
        oracle = screen_cells.Terminal(rows, columns)
        oracle.feed(read(os.path.join(directory, identifier + ".full")))
        oracle_look = looks(oracle)
        if item == "base":
            before, before_look = oracle, oracle_look
            continue
        screen = before.copy()
        screen.feed(read(os.path.join(directory, identifier + ".inc")))
        screen_look = looks(screen)
        if not has_ink(oracle_look):
            verdict, detail = "blank", ""
        else:
            differences = [(r, c) for r in range(rows) for c in range(columns)
                           if screen_look[r][c] != oracle_look[r][c]]
            if differences:
                verdict = "differ"
                detail = f"{len(differences)} cells; " + "; ".join(
                    f"{r},{c} shows {describe(screen_look[r][c])} want {describe(oracle_look[r][c])}"
                    for r, c in differences[:FIRST_DIFFERENCES])
            else:
                verdict = "changed" if oracle_look != before_look else "unchanged"
                detail = ""
        print("\t".join((directory, identifier, item, verdict, command, detail)))
        before, before_look = oracle, oracle_look


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    rows, columns = int(sys.argv[1]), int(sys.argv[2])
    for directory in sys.argv[3:]:
        compare(rows, columns, directory)


if __name__ == "__main__":
    main()
