#!/usr/bin/env python3
"""Rasterise the arrow by BEST-MATCHING a glyph per cell, from a declared palette.

Every candidate glyph is described by its own coverage mask on an 8x8 sub-cell
grid. The shape is sampled at 8x8 per cell. The chosen glyph is the one whose
mask differs from the sample in the fewest of the 64 sub-cells. That turns
"which technique looks smoother" into a NUMBER (mean sub-cell error per cell on
the boundary), and it also says how much each glyph FAMILY is worth: drop a
family from the palette and watch the error move.

Inversion (fg/bg swap) doubles a palette for free where the renderer can paint a
background colour, so it is measured as its own family.
"""
import math
import sys

N = 8   # sub-cells per side


def mask_from(fn):
    return [[1 if fn(x, y) else 0 for x in range(N)] for y in range(N)]


def solid():          return mask_from(lambda x, y: True)
def blank():          return mask_from(lambda x, y: False)
def lower(k):         return mask_from(lambda x, y: y >= N - k)          # k/8 from bottom
def upper(k):         return mask_from(lambda x, y: y < k)               # k/8 from top
def left(k):          return mask_from(lambda x, y: x < k)               # k/8 from left
def right(k):         return mask_from(lambda x, y: x >= N - k)          # k/8 from right
def quad(tl, tr, bl, br):
    def f(x, y):
        top, lft = y < N // 2, x < N // 2
        return (tl if (top and lft) else tr if (top and not lft)
                else bl if (not top and lft) else br)
    return mask_from(f)
def diag_up():        return mask_from(lambda x, y: abs((N - 1 - y) - x) <= 0)   # U+2571 stroke
def diag_dn():        return mask_from(lambda x, y: abs(y - x) <= 0)
def tri_br():         return mask_from(lambda x, y: x >= y)              # U+25E2 lower-right
def tri_bl():         return mask_from(lambda x, y: x <= N - 1 - y)      # U+25E3
def tri_tl():         return mask_from(lambda x, y: x <= y)              # U+25E4
def tri_tr():         return mask_from(lambda x, y: x >= N - 1 - y)      # U+25E5


# glyph, mask, family
PALETTE = []
PALETTE.append((" ", blank(), "base"))
PALETTE.append(("█", solid(), "base"))
for k, g in zip(range(1, 8), "▁▂▃▄▅▆▇"):
    PALETTE.append((g, lower(k), "lower-eighths" if k != 4 else "halves"))
for k, g in zip(range(1, 8), "▏▎▍▌▋▊▉"):
    PALETTE.append((g, left(k), "left-eighths" if k != 4 else "halves"))
PALETTE.append(("▀", upper(4), "halves"))
PALETTE.append(("▐", right(4), "halves"))
PALETTE.append(("▔", upper(1), "thin"))
PALETTE.append(("▕", right(1), "thin"))
for bits, g in ((( 1, 0, 0, 0), "▘"), ((0, 1, 0, 0), "▝"), ((0, 0, 1, 0), "▖"),
                ((0, 0, 0, 1), "▗"), ((1, 0, 0, 1), "▚"), ((0, 1, 1, 0), "▞"),
                ((1, 1, 1, 0), "▛"), ((1, 1, 0, 1), "▜"), ((1, 0, 1, 1), "▙"),
                ((0, 1, 1, 1), "▟")):
    PALETTE.append((g, quad(*bits), "quadrants"))
PALETTE.append(("╱", diag_up(), "box-diagonals"))
PALETTE.append(("╲", diag_dn(), "box-diagonals"))
PALETTE.append(("◢", tri_br(), "triangles"))
PALETTE.append(("◣", tri_bl(), "triangles"))
PALETTE.append(("◤", tri_tl(), "triangles"))
PALETTE.append(("◥", tri_tr(), "triangles"))


def err(mask, sample):
    e = 0
    for y in range(N):
        my, sy = mask[y], sample[y]
        for x in range(N):
            if my[x] != sx_get(sy, x):
                e += 1
    return e


def sx_get(row, x):
    return row[x]


class Arrow:
    """Pointing +x. Everything in VISUAL units: 1 unit = one cell WIDTH, and one
    cell ROW is 2 units tall (the aspect correction)."""

    def __init__(self, length_cells, head_frac=0.42, half_angle_deg=26.0, shaft_frac=0.34):
        self.L = float(length_cells)
        self.HL = self.L * head_frac
        self.hh = self.HL * math.tan(math.radians(half_angle_deg))
        self.t = self.hh * shaft_frac

    def inside(self, X, Y):
        if X < 0 or X > self.L:
            return False
        if X >= self.L - self.HL:
            return abs(Y) <= self.hh * (self.L - X) / self.HL
        return abs(Y) <= self.t

    def rows(self):
        return max(3, int(math.ceil(2 * self.hh / 2.0)) | 1)


def sample_cells(arrow, rows, cols):
    cy = rows / 2.0
    out = []
    for r in range(rows):
        line = []
        for c in range(cols):
            cell = []
            for sy in range(N):
                row = []
                for sx in range(N):
                    X = c + (sx + 0.5) / N
                    Y = (r + (sy + 0.5) / N - cy) * 2.0
                    row.append(1 if arrow.inside(X, Y) else 0)
                cell.append(row)
            line.append(cell)
        out.append(line)
    return out


def invert(mask):
    return [[1 - v for v in row] for row in mask]


def render(arrow, rows, cols, families, allow_invert=False):
    pal = [(g, m, f) for (g, m, f) in PALETTE if f in families or f == "base"]
    if allow_invert:
        pal = pal + [(g, invert(m), f + "*") for (g, m, f) in pal if f != "base"]
    cells = sample_cells(arrow, rows, cols)
    lines, total, boundary, worst = [], 0, 0, 0
    for line in cells:
        s = ""
        for cell in line:
            best, bg, binv = None, " ", False
            for (g, m, f) in pal:
                e = err(m, cell)
                if best is None or e < best:
                    best, bg, binv = e, g, f.endswith("*")
            s += bg
            n = sum(sum(r) for r in cell)
            if 0 < n < N * N:
                boundary += 1
                total += best
                worst = max(worst, best)
        lines.append(s)
    mean = (total / boundary) if boundary else 0.0
    return lines, mean, worst, boundary


if __name__ == "__main__":
    cols = int(sys.argv[1]) if len(sys.argv) > 1 else 30
    a = Arrow(cols)
    rows = a.rows()
    print("arrow %d cells long, %d rows, head %.1f cells, half-angle 26 deg (aspect-corrected)\n"
          % (cols, rows, a.HL))
    trials = [
        ("solid only                     ", set(), False),
        ("+ halves                       ", {"halves"}, False),
        ("+ quadrants                    ", {"halves", "quadrants"}, False),
        ("+ box diagonals                ", {"halves", "quadrants", "box-diagonals"}, False),
        ("+ triangles                    ", {"halves", "quadrants", "box-diagonals", "triangles"}, False),
        ("+ eighths (both families)      ", {"halves", "quadrants", "lower-eighths", "left-eighths", "thin"}, False),
        ("+ eighths, INVERTIBLE (fg/bg)  ", {"halves", "quadrants", "lower-eighths", "left-eighths", "thin"}, True),
        ("everything, invertible         ", {"halves", "quadrants", "lower-eighths", "left-eighths",
                                             "thin", "box-diagonals", "triangles"}, True),
    ]
    for label, fams, inv in trials:
        lines, mean, worst, nb = render(a, rows, cols, fams, inv)
        print("%s  mean err %5.2f / 64  worst %2d  (%d boundary cells)" % (label, mean, worst, nb))
        for ln in lines:
            print("      |" + ln + "|")
        print()
