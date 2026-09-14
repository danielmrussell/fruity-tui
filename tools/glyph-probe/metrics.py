#!/usr/bin/env python3
"""Two more measurements the write-up must not assert from memory.

1. The CELL ASPECT.  "A terminal cell is about 1:2" is the load-bearing constant
   of the whole exercise, and it is a property of the FONT, not folklore: the
   advance width of a monospace glyph against the line height the terminal uses
   (ascender - descender + lineGap).  Read straight out of hhea/head/hmtx.

2. Whether U+1FB70-1FB8B — the Legacy Computing block that contains exactly the
   UPPER and RIGHT eighth families Unicode 1.0-era block elements left out — is
   in any of these fonts.
"""
import struct
import sys
sys.path.insert(0, ".")
from cmap import read_font, cmap_set

MISSING_FAMILIES = {
    "middle vertical eighths U+1FB70-75": range(0x1FB70, 0x1FB76),
    "middle horiz eighths  U+1FB76-7B": range(0x1FB76, 0x1FB7C),
    "UPPER eighths        U+1FB82-86": range(0x1FB82, 0x1FB87),
    "RIGHT eighths        U+1FB87-8B": range(0x1FB87, 0x1FB8C),
}

for path in sys.argv[1:]:
    data, tables = read_font(path)
    upm = struct.unpack(">H", data[tables["head"][0] + 18:tables["head"][0] + 20])[0]
    h = tables["hhea"][0]
    asc, desc, gap = struct.unpack(">hhh", data[h + 4:h + 10])
    n_hmetrics = struct.unpack(">H", data[h + 34:h + 36])[0]
    adv = struct.unpack(">H", data[tables["hmtx"][0]:tables["hmtx"][0] + 2])[0]
    line = asc - desc + gap
    print("\n== %s ==" % path.split("/")[-1])
    print("   unitsPerEm %d   advanceWidth %d   ascender %d  descender %d  lineGap %d"
          % (upm, adv, asc, desc, gap))
    print("   cell = %d x %d design units  ->  aspect w:h = 1 : %.3f"
          % (adv, line, line / adv if adv else 0))
    codes = cmap_set(data, tables)
    for label, rng in MISSING_FAMILIES.items():
        have = sum(1 for c in rng if c in codes)
        print("   %-34s %d of %d" % (label, have, len(rng)))
