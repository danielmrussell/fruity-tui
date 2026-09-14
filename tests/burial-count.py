#!/usr/bin/env python3
"""Count what callout placements really cover, against real rendered frames.

    burial-count.py DIR COLS ROWS

DIR holds `placements.txt` (one per line: page step boxT boxL boxB boxR poly, tab-separated)
and `bare-<page>.txt` (the page rendered WITHOUT its callout, so nothing of the overlay is in
the ink map). Every covered cell — box plus leader — is classified the way the user ranked the
sins: TEXT (a glyph that is not box-drawing; the gravest), DECOR (a border glyph; explicitly
welcome), BLANK (nothing).

KNOWN BLIND SPOT: a space is BLANK whatever its background colour, so a strip that paints its
full width in a bar colour (the keylegend, the statusbar) reads as empty where it is really
chrome. That inflates BLANK and cannot inflate TEXT, so the TEXT numbers a gate pins are safe;
just don't read BLANK as "nothing would be harmed there".

Output: one line, `N=… TEXT=… DECOR=… BLANK=… ANYTXT=…` (ANYTXT = placements burying any text).
"""
import io
import os
import sys

BORDER = set("─│┌┐└┘├┤┬┴┼━┃┏┓┗┛╭╮╰╯═║╔╗╚╝╞╡▏▕▔▁┄┈╌╍▲▼◀▶")

d, cols, rows = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])

frames = {}
def frame(p):
    if p not in frames:
        path = os.path.join(d, "bare-%s.txt" % p)
        frames[p] = io.open(path, encoding="utf-8", errors="replace").read().split("\n")
    return frames[p]

def cell(p, y, x):
    f = frame(p)
    if y < 0 or y >= len(f):
        return " "
    row = f[y]
    return row[x] if 0 <= x < len(row) else " "

def poly_cells(poly):
    v = [int(t) for t in poly.split()] if poly.strip() else []
    pts = [(v[i], v[i + 1]) for i in range(0, len(v) - 1, 2)]
    out = set()
    for i in range(len(pts) - 1):
        (r0, c0), (r1, c1) = pts[i], pts[i + 1]
        if r0 == r1:
            for c in range(min(c0, c1), max(c0, c1) + 1):
                out.add((r0, c))
        elif c0 == c1:
            for r in range(min(r0, r1), max(r0, r1) + 1):
                out.add((r, c0))
    return out

n = text = decor = blank = anytxt = 0
src = io.open(os.path.join(d, "placements.txt"), encoding="utf-8").read()
for line in src.splitlines():
    if not line:
        continue
    parts = line.split("\t")
    p, s, bT, bL, bB, bR = (int(x) for x in parts[:6])
    poly = parts[6] if len(parts) > 6 else ""
    cells = set((y, x) for y in range(bT, bB + 1) for x in range(bL, bR + 1))
    cells |= poly_cells(poly)
    t = 0
    for (y, x) in cells:
        c = cell(p, y, x)
        if c in (" ", ""):
            blank += 1
        elif c in BORDER:
            decor += 1
        else:
            t += 1
    text += t
    n += 1
    if t:
        anytxt += 1

print("N=%d TEXT=%d DECOR=%d BLANK=%d ANYTXT=%d" % (n, text, decor, blank, anytxt))
