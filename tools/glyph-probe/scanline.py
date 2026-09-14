#!/usr/bin/env python3
"""The SHIPPABLE rasteriser: one anchored eighth-block per cell + fg/bg inversion.

The exhaustive best-match in palette.py is the right answer and the wrong
algorithm — 30 glyphs x 64 sub-cells x every cell is seconds of bash. But the
shape is analytic, so per COLUMN the arrow occupies one continuous interval of
sub-rows, and a cell's coverage is that interval clipped to its 8 sub-rows. A
contiguous run anchored to the bottom IS a lower-eighth block; anchored to the
top it is the same glyph painted fg/bg swapped. That is O(1) integer arithmetic
per cell and no per-cell search at all.

Measured here against the exhaustive best-match so the shortcut is priced.
"""
import math
import sys

sys.path.insert(0, ".")
import palette as P

LOWER = " ▁▂▃▄▅▆▇█"          # index = eighths filled FROM THE BOTTOM


def half_at(a, x):
    """Visual half-thickness of a right-pointing arrow at distance x from tail."""
    if x < 0 or x > a.L:
        return None
    if x >= a.L - a.HL:
        return a.hh * (a.L - x) / a.HL
    return a.t


def scanline(a, rows, cols, SUB=8):
    """Return (lines, inverted_flags). One pass, integer arithmetic per cell."""
    cy = rows / 2.0                                  # cell rows
    lines, invs = [], []
    # per column: the sub-row span [top, bot) the arrow occupies
    spans = []
    for c in range(cols):
        h = half_at(a, c + 0.5)
        if h is None or h <= 0:
            spans.append(None)
            continue
        # visual units -> cell rows -> sub-rows.  ONE cell row = 2 visual units.
        top = int(round((cy - h / 2.0) * SUB))
        bot = int(round((cy + h / 2.0) * SUB))
        if bot <= top:
            bot = top + 1                            # never let a thin tip vanish
        spans.append((top, bot))
    for r in range(rows):
        lo, hi = r * SUB, (r + 1) * SUB
        line, inv = "", []
        for c in range(cols):
            sp = spans[c]
            if sp is None:
                line += " "; inv.append(0); continue
            t, b = max(sp[0], lo), min(sp[1], hi)
            n = b - t
            if n <= 0:
                line += " "; inv.append(0); continue
            if n >= SUB:
                line += "█"; inv.append(0); continue
            top_free, bot_free = t - lo, hi - b
            if bot_free == 0:                        # bottom-anchored: the native family
                line += LOWER[n * 8 // SUB]; inv.append(0)
            elif top_free == 0:                      # top-anchored: the same glyph, swapped
                line += LOWER[(SUB - n) * 8 // SUB]; inv.append(1)
            else:
                # floating run: Unicode HAS these (U+1FB76-1FB7B) and no font here does.
                # Extend to whichever edge is nearer — the smaller lie.
                if top_free <= bot_free:
                    line += LOWER[(SUB - (n + top_free)) * 8 // SUB]; inv.append(1)
                else:
                    line += LOWER[(n + bot_free) * 8 // SUB]; inv.append(0)
        lines.append(line); invs.append(inv)
    return lines, invs


def measure(a, rows, cols, SUB=8):
    """Mean sub-cell error of the scanline result, in the same 8x8 units as palette.py."""
    lines, invs = scanline(a, rows, cols, SUB)
    cells = P.sample_cells(a, rows, cols)
    total = boundary = worst = 0
    for r in range(rows):
        for c in range(cols):
            sample = cells[r][c]
            n = sum(sum(row) for row in sample)
            if n == 0 or n == 64:
                continue
            g, iv = lines[r][c], invs[r][c]
            k = LOWER.index(g)
            mask = [[1 if (y >= 8 - k) else 0 for x in range(8)] for y in range(8)]
            if iv:
                mask = [[1 - v for v in row] for row in mask]
            e = sum(1 for y in range(8) for x in range(8) if mask[y][x] != sample[y][x])
            total += e; boundary += 1; worst = max(worst, e)
    return (total / boundary if boundary else 0), worst, boundary


if __name__ == "__main__":
    print("%-6s %-5s   %-28s %-28s %-28s" % ("cols", "rows", "SOLID (1x1)", "SCANLINE halves (SUB=2)", "SCANLINE eighths (SUB=8)"))
    for cols in (10, 14, 20, 30, 44, 60):
        a = P.Arrow(cols)
        rows = a.rows()
        _sl, solid_mean, _sw, _sn = P.render(a, rows, cols, set(), False)
        m2, w2, _ = measure(a, rows, cols, 2)
        m8, w8, nb = measure(a, rows, cols, 8)
        _bl, best, bw, _bn = P.render(a, rows, cols,
                                      {"halves", "quadrants", "lower-eighths", "left-eighths", "thin"}, True)
        print("%-6d %-5d   solid %5.2f          halves %5.2f (worst %2d)     eighths %5.2f (worst %2d)   exhaustive-best %5.2f"
              % (cols, rows, solid_mean, m2, w2, m8, w8, best))
    print()
    for cols in (14, 30, 52):
        a = P.Arrow(cols); rows = a.rows()
        for SUB, label in ((2, "halves  (SUB=2)"), (8, "eighths (SUB=8)")):
            lines, invs = scanline(a, rows, cols, SUB)
            print("%d cells, %s   ('~' marks a cell painted fg/bg SWAPPED)" % (cols, label))
            for r in range(rows):
                print("   |" + lines[r] + "|")
            for r in range(rows):
                print("   :" + "".join("~" if invs[r][c] else (" " if lines[r][c] == " " else "-")
                                       for c in range(cols)) + ":")
            print()
