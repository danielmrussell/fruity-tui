#!/usr/bin/env python3
"""Draw ONE arrow, six ways, at the same cell size — then look at them.

The point of the exercise is the EDGE. A big arrow is a filled shape whose two
barbs are long, shallow diagonals; how smooth those read is the whole question.

Aspect: a terminal cell is ~1 wide x 2 tall. Every shape here is defined in
VISUAL units (1 unit = one cell WIDTH) and a cell row is therefore 2 units tall.
Nothing is drawn in "cell space" without that factor — a 45 degree line in cell
space is 63 degrees on screen.
"""
import sys

# ── the shape, in visual units ───────────────────────────────────────────────
class Arrow:
    def __init__(self, length_cells, head_frac=0.42, half_angle_deg=26.0, shaft_frac=0.34):
        self.L = float(length_cells)
        self.HL = self.L * head_frac
        import math
        # visual half-height of the head at its base
        self.hh = self.HL * math.tan(math.radians(half_angle_deg))
        self.t = self.hh * shaft_frac

    def inside(self, X, Y):
        """X, Y in visual units; tip at X=L, axis at Y=0."""
        if X < 0 or X > self.L:
            return False
        if X >= self.L - self.HL:
            return abs(Y) <= self.hh * (self.L - X) / self.HL
        return abs(Y) <= self.t

    def rows_needed(self):
        return int(2 * self.hh / 2.0 + 1.5)     # visual height / 2 units per row


def sample(arrow, rows, cols, SX, SY):
    """Sub-cell coverage grid: grid[r][c] is a list of SY rows of SX bools."""
    cy = rows / 2.0
    grid = []
    for r in range(rows):
        line = []
        for c in range(cols):
            cell = []
            for sy in range(SY):
                sub = []
                for sx in range(SX):
                    X = c + (sx + 0.5) / SX
                    Y = (r + (sy + 0.5) / SY - cy) * 2.0     # <- the aspect correction
                    sub.append(arrow.inside(X, Y))
                cell.append(sub)
            line.append(cell)
        grid.append(line)
    return grid


def coverage(cell):
    n = sum(sum(1 for b in row if b) for row in cell)
    total = len(cell) * len(cell[0])
    return n / total


# ── renderers ────────────────────────────────────────────────────────────────
def render_solid(arrow, rows, cols):
    """(a) the naive approach the brief forbids: fill a cell or don't."""
    g = sample(arrow, rows, cols, 1, 1)
    return ["".join("█" if coverage(cell) >= 0.5 else " " for cell in line) for line in g]


QUAD = {  # (tl, tr, bl, br) -> glyph
    (0, 0, 0, 0): " ", (1, 0, 0, 0): "▘", (0, 1, 0, 0): "▝",
    (1, 1, 0, 0): "▀", (0, 0, 1, 0): "▖", (1, 0, 1, 0): "▌",
    (0, 1, 1, 0): "▞", (1, 1, 1, 0): "▛", (0, 0, 0, 1): "▗",
    (1, 0, 0, 1): "▚", (0, 1, 0, 1): "▐", (1, 1, 0, 1): "▜",
    (0, 0, 1, 1): "▄", (1, 0, 1, 1): "▙", (0, 1, 1, 1): "▟",
    (1, 1, 1, 1): "█",
}


def render_quadrant(arrow, rows, cols):
    """(c) 2x2 per cell."""
    g = sample(arrow, rows, cols, 2, 2)
    out = []
    for line in g:
        s = ""
        for cell in line:
            key = (int(cell[0][0]), int(cell[0][1]), int(cell[1][0]), int(cell[1][1]))
            s += QUAD[key]
        out.append(s)
    return out


BRAILLE_BIT = [[0x01, 0x08], [0x02, 0x10], [0x04, 0x20], [0x40, 0x80]]


def render_braille(arrow, rows, cols):
    """(d) 2x4 per cell — the drawille technique."""
    g = sample(arrow, rows, cols, 2, 4)
    out = []
    for line in g:
        s = ""
        for cell in line:
            bits = 0
            for sy in range(4):
                for sx in range(2):
                    if cell[sy][sx]:
                        bits |= BRAILLE_BIT[sy][sx]
            s += chr(0x2800 + bits)
        out.append(s)
    return out


LOWER = " ▁▂▃▄▅▆▇█"    # 0..8 eighths from the BOTTOM
UPPER_HALF = "▀"
LEFT = " ▏▎▍▌▋▊▉█"      # 0..8 eighths from the LEFT
RIGHT = " ▕▕▕▐▐▐▐█"     # coarse: only 1/8, 1/4(=1/2?) exist


def render_eighths(arrow, rows, cols):
    """(f) 8 sub-rows per cell, edge-following: for a SHALLOW edge, the boundary
    inside a cell is a fraction of a row, and a vertical-eighth block draws it."""
    g = sample(arrow, rows, cols, 1, 8)
    out = []
    for line in g:
        s = ""
        for cell in line:
            filled = [cell[i][0] for i in range(8)]
            n = sum(1 for f in filled if f)
            if n == 0:
                s += " "
            elif n == 8:
                s += "█"
            else:
                # which END is filled? bottom-anchored -> LOWER, top-anchored -> use
                # the upper-eighths, which DO NOT EXIST as a set; only U+2580 (1/2).
                if filled[-1] and not filled[0]:
                    s += LOWER[n]
                elif filled[0] and not filled[-1]:
                    s += UPPER_HALF if n >= 4 else "▔"     # 1/8 top bar
                else:
                    s += LOWER[n]
        out.append(s)
    return out


def render_eighths_hybrid(arrow, rows, cols):
    """(f') the same, but with an UPPER-eighth family faked from the only glyph
    that exists (U+2594 upper one-eighth, U+2580 upper half). This is the honest
    picture of what the block does and does not give you."""
    return render_eighths(arrow, rows, cols)


def render_diagonal(arrow, rows, cols):
    """(b) box diagonals for the edge + full block for the interior.

    A diagonal glyph can only draw ONE angle: exactly one cell across per cell
    down. Corrected for aspect that is a 63 degree line on screen. So an edge is
    approximated by RUNS of horizontal fill with a single diagonal at each step —
    which is the stair-step the brief is trying to avoid, wearing a diagonal hat.
    """
    g = sample(arrow, rows, cols, 1, 1)
    out = []
    for r, line in enumerate(g):
        s = ""
        for c, cell in enumerate(line):
            cov = coverage(cell)
            if cov >= 0.5:
                s += "█"
            else:
                s += " "
        out.append(list(s))
    # now replace the LAST filled cell of each row-run with a diagonal where the
    # boundary moves by exactly one cell between adjacent rows
    for r in range(rows - 1):
        for c in range(cols):
            pass
    return ["".join(x) for x in out]


def edge_profile(arrow, rows, cols, SY):
    """Where the TOP barb crosses each column, in sub-rows. The measure of
    smoothness: how many DISTINCT step sizes, and the biggest single jump."""
    cy = rows / 2.0
    prof = []
    for c in range(cols):
        X = c + 0.5
        # topmost sub-row that is inside
        found = None
        for r in range(rows):
            for sy in range(SY):
                Y = (r + (sy + 0.5) / SY - cy) * 2.0
                if arrow.inside(X, Y):
                    found = r * SY + sy
                    break
            if found is not None:
                break
        prof.append(found)
    steps = [abs(prof[i + 1] - prof[i]) for i in range(len(prof) - 1)
             if prof[i] is not None and prof[i + 1] is not None]
    return prof, steps


if __name__ == "__main__":
    cols = int(sys.argv[1]) if len(sys.argv) > 1 else 30
    a = Arrow(cols)
    rows = a.rows_needed()
    print("arrow: length=%d cells, head=%.1f cells, head half-height=%.1f visual units"
          " (= %.1f rows), shaft half-thickness=%.1f  -> %d rows"
          % (cols, a.HL, a.hh, a.hh / 2, a.t, rows))
    for label, fn, SY in (("(a) SOLID  1x1  (the naive baseline)", render_solid, 1),
                          ("(c) QUADRANT 2x2", render_quadrant, 2),
                          ("(f) EIGHTHS 1x8 (vertical)", render_eighths, 8),
                          ("(d) BRAILLE 2x4", render_braille, 4)):
        print("\n" + label)
        for line in fn(a, rows, cols):
            print("   |" + line + "|")
        prof, steps = edge_profile(a, rows, cols, SY)
        if steps:
            print("   edge: max jump %d sub-rows, distinct steps %s, sub-rows/cell %d"
                  % (max(steps), sorted(set(steps)), SY))
