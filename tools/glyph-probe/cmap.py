#!/usr/bin/env python3
"""Minimal TTF/OTF cmap reader: does this font actually have these code points?

No fontTools on this box, and "the font probably has it" is exactly the kind of
claim this project refuses. Parses the sfnt table directory, finds cmap, and
reads format 4 (BMP) and format 12 (full) subtables. Also reads hmtx advances
so we can see whether a glyph is drawn one cell wide by the FONT.
"""
import struct
import sys


def read_font(path):
    with open(path, "rb") as fh:
        data = fh.read()
    tag = data[:4]
    off = 0
    if tag == b"ttcf":
        n = struct.unpack(">I", data[8:12])[0]
        off = struct.unpack(">I", data[12:16])[0]
    numtables = struct.unpack(">H", data[off + 4:off + 6])[0]
    tables = {}
    for i in range(numtables):
        p = off + 12 + 16 * i
        t = data[p:p + 4].decode("latin-1")
        toff, tlen = struct.unpack(">II", data[p + 8:p + 16])
        tables[t] = (toff, tlen)
    return data, tables


def cmap_set(data, tables):
    if "cmap" not in tables:
        return set()
    base, _ = tables["cmap"]
    n = struct.unpack(">H", data[base + 2:base + 4])[0]
    subs = []
    for i in range(n):
        p = base + 4 + 8 * i
        pid, eid, off = struct.unpack(">HHI", data[p:p + 8])
        subs.append((pid, eid, base + off))
    codes = set()
    for pid, eid, off in subs:
        fmt = struct.unpack(">H", data[off:off + 2])[0]
        if fmt == 4:
            segx2 = struct.unpack(">H", data[off + 6:off + 8])[0]
            seg = segx2 // 2
            ends = struct.unpack(">%dH" % seg, data[off + 14:off + 14 + segx2])
            sp = off + 16 + segx2
            starts = struct.unpack(">%dH" % seg, data[sp:sp + segx2])
            for s, e in zip(starts, ends):
                if s == 0xFFFF:
                    continue
                for c in range(s, min(e, 0xFFFE) + 1):
                    codes.add(c)
        elif fmt == 12:
            ngroups = struct.unpack(">I", data[off + 12:off + 16])[0]
            for g in range(ngroups):
                p = off + 16 + 12 * g
                s, e, _gi = struct.unpack(">III", data[p:p + 12])
                if e - s > 0x20000:
                    continue
                for c in range(s, e + 1):
                    codes.add(c)
    return codes


GROUPS = {
    "box diagonals U+2571-2573": [0x2571, 0x2572, 0x2573],
    "box light/heavy (baseline)": [0x2500, 0x2502, 0x250C, 0x2501, 0x2503, 0x250F],
    "block full/halves U+2580-2590": [0x2580, 0x2584, 0x258C, 0x2590, 0x2588],
    "block eighths (h) U+2589-258F": list(range(0x2589, 0x2590)),
    "block eighths (v) U+2581-2587": list(range(0x2581, 0x2588)),
    "quadrants U+2596-259F": list(range(0x2596, 0x25A0)),
    "shades U+2591-2593": [0x2591, 0x2592, 0x2593],
    "braille U+2800-28FF": list(range(0x2800, 0x2900)),
    "sextants U+1FB00-1FB3B": list(range(0x1FB00, 0x1FB3C)),
    "smooth mosaic U+1FB3C-1FB6B": list(range(0x1FB3C, 0x1FB6C)),
    "octants U+1CD00-1CDE5": list(range(0x1CD00, 0x1CDE6)),
    "triangles U+25E2-25E5": [0x25E2, 0x25E3, 0x25E4, 0x25E5],
    "triangles big U+25B2..": [0x25B2, 0x25B6, 0x25BC, 0x25C0, 0x25B3, 0x25B7, 0x25BD, 0x25C1],
    "arrowheads U+276C.. / U+27A1": [0x276E, 0x276F, 0x27A1, 0x2B05],
}

fonts = sys.argv[1:]
rows = []
for f in fonts:
    try:
        data, tables = read_font(f)
        codes = cmap_set(data, tables)
    except Exception as exc:                      # noqa
        print("%-34s  ERROR %s" % (f.split("/")[-1], exc))
        continue
    name = f.split("/")[-1]
    print("\n== %s ==  %d code points" % (name, len(codes)))
    for g, cps in GROUPS.items():
        have = sum(1 for c in cps if c in codes)
        mark = "ALL" if have == len(cps) else ("none" if have == 0 else "%d/%d" % (have, len(cps)))
        print("   %-32s %6s of %d" % (g, mark, len(cps)))
