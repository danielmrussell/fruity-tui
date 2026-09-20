#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  What does ONE KEYSTROKE cost in a big textarea?
#
#  The label's append path is flat in log size now (tools/bench-* and the line
#  store), but a textfield EDITS IN THE MIDDLE, so every keystroke used to re-wrap
#  the entire document. This measures the three things a keystroke actually does —
#  layout (the wrap), draw (the paint), and the round trip — at several document
#  sizes, so "flat in document size" is a claim with numbers behind it.
#
#      bash tools/bench-textfield.bash [repeats] [sizes…]
#      bash tools/bench-textfield.bash 20 100 1000 4000
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export FT_NO_WTFIX=1
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_ROWS=40; FT_COLS=100

repeats=${1:-20}; shift || true
sizes=("$@"); (( ${#sizes[@]} )) || sizes=(100 1000 4000)

now_us() { local stamp=${EPOCHREALTIME/./}; printf '%s' "$stamp"; }
_ms() { printf '%d.%03d' "$(( $1 / 1000 ))" "$(( $1 % 1000 ))"; }

measure() {                     # label command…
    local label=$1; shift
    local started finished index
    started=$(now_us)
    for (( index = 0; index < repeats; index++ )); do "$@" >/dev/null 2>&1; done
    finished=$(now_us)
    printf '  %-34s %8s ms\n' "$label" "$(_ms $(( (finished - started) / repeats )))"
}

# A document of NLINES ~36-character lines — the shape the 1229ms measurement used.
build_value() {                 # nlines → BIGVAL
    local n=$1 i
    local -a parts=()
    for (( i = 0; i < n; i++ )); do parts+=("line $i — the quick brown fox jumps"); done
    local IFS=$'\n'; BIGVAL="${parts[*]}"
}

ft-form name=app width=100 height=40
    ft-textfield name=big size=60 rows=30 wrap=true showLineNumbers=true
end_ft_form
FT_ROOT=app; FT_FOCUS=big

# One keystroke, end to end: type a character, re-layout, repaint the field.
keystroke() { ft_textfield_insert_char big x; _ft_textfield_textw big; _ft_textfield_layout big "$FT_RET"; _ft_draw_textfield big; }
# A COLD layout: pretend the value changed, so nothing is allowed to be reused. This is the
# number that used to be ~1s — the one an incremental wrap has to keep flat.
bumpgen()   { local g="_fti_big__textgen"; printf -v "$g" '%s' $(( ${!g:-0} + 1 )); }
coldlayout(){ bumpgen; _ft_textfield_textw big; _ft_textfield_layout big "$FT_RET"; }
warmlayout(){ _ft_textfield_textw big; _ft_textfield_layout big "$FT_RET"; }
resplit()   { bumpgen; _ft_textfield_lines big; }
justedit()  { ft_textfield_insert_char big x; }
editlayout(){ ft_textfield_insert_char big x; _ft_textfield_textw big; _ft_textfield_layout big "$FT_RET"; }
# A real resize does NOT change the text, so the line store stays valid and only the WRAP is
# redone — unlike coldlayout, which forces a re-split the terminal never asks for. Alternating
# the width defeats the memo the way dragging a window edge does.
RW=0
resize()    { _ft_textfield_textw big; RW=$(( RW ? 0 : 1 )); _ft_textfield_layout big $(( FT_RET - RW )); }

for n in "${sizes[@]}"; do
    build_value "$n"
    ft_set big value="$BIGVAL"
    ft_layout app
    ft_set big runlevel=editing
    FT_TEXTFIELD_CARET[big]=${#BIGVAL}                 # typing at the END, the common case
    printf '\n%d lines / %d chars\n' "$n" "${#BIGVAL}"
    keystroke >/dev/null 2>&1                   # warm up: the FIRST layout of a document is a
                                                # full rebuild, and averaging it in hides the rest
    # ORDER MATTERS: each of these leaves the memo hot, so the ones that must be measured
    # warm come first. Anything after coldlayout/resplit would pay one rebuild per average.
    measure "keystroke + layout + draw"  keystroke
    measure "  _ft_textfield_layout — memo hit"  warmlayout
    measure "    _ft_textfield_textw"            _ft_textfield_textw big
    measure "    _ft_textfield_lines (in sync)"  _ft_textfield_lines big
    measure "    _ft_textfield_rowcol (caret)"   _ft_textfield_rowcol "${FT_TEXTFIELD_CARET[big]}"
    measure "  _ft_draw_textfield"        _ft_draw_textfield big
    measure "  edit + incremental layout" editlayout
    measure "  the edit alone"            justedit
    measure "  a WIDTH change (real resize)" resize
    measure "  _ft_textfield_layout — COLD"      coldlayout
    measure "  _ft_lines_sync (re-split)" resplit
    # …and the same keystroke at the TOP of the document, where an incremental
    # wrap has the most rows after it to re-base.
    FT_TEXTFIELD_CARET[big]=0
    measure "keystroke at offset 0"       keystroke
done
echo
