#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ─────────────────────────────────────────────────────────────────────────────
#  rec-frame.py — replay an FT_RECORD byte stream into a plain-text frame.
#
#    tools/rec-frame.py REC                      the frame at the END of the recording
#    tools/rec-frame.py REC --at BYTES           the frame after the first BYTES of it
#    tools/rec-frame.py REC --before-page N      the last frame BEFORE the counter "(N/…)"
#                                                was painted (i.e. the previous page's end)
#    tools/rec-frame.py REC --pages              list where the page counter was painted
#
#  Size comes from REC.meta ("SIZE cols rows", written by ft_term_size) unless --size C R.
#  The demo records every run (see demo/callout-demo.bash, FT_RECORD); the previous run is
#  kept as REC.prev. Under damage narrowing only CHANGED cells are repainted, so a page's
#  constant title prefix never reappears in the stream — the "(N/7)" counter does, and that
#  is what --pages / --before-page key on.
# ─────────────────────────────────────────────────────────────────────────────
import io, os, re, subprocess, sys, tempfile

USAGE = "usage: rec-frame.py REC [--at BYTES | --before-page N | --pages] [--size COLS ROWS]"

def usage(msg=""):
    sys.exit((msg + "\n" if msg else "") + USAGE)

args = sys.argv[1:]
if not args:
    usage()
rec = args.pop(0)
cols = rows = None
cut = None
before_page = None
list_pages = False
while args:
    a = args.pop(0)
    if a == "--size":
        cols, rows = int(args.pop(0)), int(args.pop(0))
    elif a == "--at":
        cut = int(args.pop(0))
    elif a == "--before-page":
        before_page = args.pop(0)
    elif a == "--pages":
        list_pages = True
    else:
        usage("unknown argument: " + a)

data = io.open(rec, "rb").read()
if cols is None:
    try:
        for line in io.open(rec + ".meta", "r", encoding="utf-8"):
            if line.startswith("SIZE "):
                _, c, r = line.split()
                cols, rows = int(c), int(r)
    except IOError:
        pass
if cols is None:
    usage("no size: " + rec + ".meta has no SIZE line — pass --size COLS ROWS")

hits = [(m.start(), m.group(1).decode()) for m in re.finditer(rb"\((\d+)/\d+\)", data)]
trans, last = [], None
for off, pg in hits:
    if pg != last:
        trans.append((off, pg)); last = pg
if list_pages:
    print("page counter painted at (offset:page):", " ".join("%d:%s" % t for t in trans) or "(never)")
    sys.exit(0)
if before_page is not None:
    at = [off for off, pg in trans if pg == before_page]
    if not at:
        usage("page %s was never painted; --pages lists what was" % before_page)
    cut = data.rfind(b"\x1b[", 0, at[-1])     # back up to the escape that carries the paint
if cut is not None:
    data = data[:cut]

here = os.path.dirname(os.path.abspath(__file__))
with tempfile.NamedTemporaryFile(delete=False, suffix=".bin") as tmp:
    tmp.write(data)
try:
    out = subprocess.run([sys.executable, os.path.join(here, "screen-cells.py"), tmp.name, str(rows), str(cols)],
                         capture_output=True, text=True).stdout
finally:
    os.unlink(tmp.name)
grid = [[" "] * cols for _ in range(rows)]
for line in out.splitlines():
    try:
        pos, glyph, _ = line.split("\t", 2)
        r, c = (int(x) for x in pos.split(","))
    except ValueError:
        continue
    if 0 <= r < rows and 0 <= c < cols:
        grid[r][c] = glyph
for r in range(rows):
    print("".join(grid[r]).rstrip())
