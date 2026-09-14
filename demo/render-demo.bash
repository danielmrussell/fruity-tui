#!/usr/bin/env bash
# Fruity TUI — core render demo (non-interactive).
# Draws a framed panel with a title, a wrapped paragraph, and a hrule to a
# capture file, then prints it. Proves ft-core's primitives work standalone.
#
#   bash demo/render-demo.bash
set -o pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/ft-core.bash"
ft_init

FT_ROWS=18; FT_COLS=64
out=$(mktemp)
exec {FT_TTY}>"$out"

# Frame
ft_hrule $(( FT_COLS - 2 ))
FT_OUT=""
ft_print_at 0 0 "$FT_COLOR_BORDER$FT_GLYPH_TOP_LEFT$FT_HRULE$FT_GLYPH_TOP_RIGHT"
title=" Fruity TUI "
ft_print_at 0 $(( (FT_COLS - ${#title}) / 2 )) "$FT_COLOR_TITLE$title$FT_COLOR_BORDER"
for (( r=1; r<FT_ROWS-1; r++ )); do
    ft_fit "" $(( FT_COLS - 2 ))
    ft_print_at "$r" 0 "$FT_COLOR_BODY$FT_GLYPH_VERTICAL$FT_FIT$FT_GLYPH_VERTICAL"
done
ft_print_at $(( FT_ROWS-1 )) 0 "$FT_COLOR_BORDER$FT_GLYPH_BOTTOM_LEFT$FT_HRULE$FT_GLYPH_BOTTOM_RIGHT"

# Wrapped paragraph
para="ft-core gives you locale-aware glyphs, a themeable palette, terminal lifecycle, resize handling, and buffered draw primitives — with no ncurses and no forks in the draw path."
ft_wrap "$para" $(( FT_COLS - 6 ))
row=2
for line in "${FT_WRAP_LINES[@]}"; do
    ft_fit "$line" $(( FT_COLS - 6 ))
    ft_print_at "$row" 3 "$FT_COLOR_BODY$FT_FIT"
    (( row++ ))
done

# A hrule divider + glyph sampler
ft_hrule $(( FT_COLS - 6 ))
ft_print_at $(( row+1 )) 3 "$FT_COLOR_DIVIDER$FT_HRULE"
ft_print_at $(( row+3 )) 3 "$FT_COLOR_BODY glyphs: $FT_GLYPH_TREE_BRANCH $FT_GLYPH_TREE_LAST $FT_GLYPH_CHECK_ON $FT_GLYPH_RADIO_ON $FT_GLYPH_ARROW_UP$FT_GLYPH_ARROW_DOWN$FT_GLYPH_ARROW_LEFT$FT_GLYPH_ARROW_RIGHT"
ft_flush
exec {FT_TTY}>&-

echo "=== rendered (ANSI stripped) ==="
python3 - "$out" <<'PY'
import re,sys
d=open(sys.argv[1],encoding="utf-8",errors="replace").read()
d=re.sub(r"\x1b\[\?[0-9]*[hl]","",d)
parts=re.split(r"\x1b\[(\d+);(\d+)H",d); rows={}; i=1
while i+2 < len(parts):
    r=int(parts[i]); c=int(parts[i+1]); t=re.sub(r"\x1b\[[0-9;]*m","",parts[i+2])
    rows.setdefault(r,[]).append((c,t)); i+=3
for r in sorted(rows):
    buf={}
    for c,s in rows[r]:
        for k,ch in enumerate(s): buf[c-1+k]=ch
    if buf:
        print("".join(buf.get(j," ") for j in range(max(buf)+1)).rstrip())
PY
rm -f "$out"
