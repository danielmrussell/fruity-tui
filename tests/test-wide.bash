#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tests/test-wide.bash — COLUMNS are not CHARACTERS.
#
#  A string has two coordinate systems. A caret, a selection endpoint and a line offset are
#  CHARACTER indices — that is the document. A scroll offset, a click and the width of a well
#  are COLUMNS — that is the screen. In pure ASCII the two are the same number, which is how a
#  single variable came to serve as both in five separate places, and why nothing noticed.
#
#  One CJK glyph — ONE character, TWO columns — pulls them apart. What it did:
#
#    · Typing at the end of a Japanese string in a one-line field made the CARET DISAPPEAR.
#      The window was sliced `textw` CHARACTERS wide (twice as many columns as fit), the
#      truncator threw the overflowing half away, and the caret cell was in the half thrown
#      away. The view then stopped following the caret, so it never came back.
#    · Clicking in such a field put the caret at roughly HALF the character clicked.
#    · Panning a non-wrapping text area sideways skipped two characters per column.
#    · The terminal cursor sat left of the block caret the draw had painted.
#
#  Every case below is checked in ASCII too — the fix must not move the common case, and an
#  ASCII-only fixture is exactly what let this hide (see the word-motion bug: a uniform
#  fixture tests one case N times).
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=80; FT_ROWS=24

_plain() { printf '%s' "$1" | sed -E $'s/\x1b\\[[0-9;?]*[A-Za-z]//g'; }

# A field's pan and its vertical offset are `scrollLeft` and `scrollTop` — the DOM's names, and
# ordinary properties — where they used to be two private tables. This file drives the pan
# directly, so it reads and writes them the way an app would.
_voff() { _ft_get_raw "$1" scrollTop;  printf '%s' "${FT_RET:-0}"; }
_hoff() { _ft_get_raw "$1" scrollLeft; printf '%s' "${FT_RET:-0}"; }

# The run painted at screen cell (R,C) by the draw just captured in FT_OUT, SGR removed.
# Anchored at a CELL, not just a row: a row is painted as one wide run plus separate
# one-cell overlays (the right border, a scrollbar thumb), and concatenating those would
# make every row look wider than it is.
_run_at() {                     # row col (1-based) → FT_RET
    local want="$1,$2: " seg
    FT_RET=""
    while IFS= read -r seg; do
        [[ "$seg" == "$want"* ]] || continue
        FT_RET=${seg#"$want"}; return
    done < <(printf '%s' "$FT_OUT" \
             | sed -e $'s/\x1b\\[[0-9;]*m//g' -e $'s/\x1b\\[\\([0-9]*\\);\\([0-9]*\\)H/\\n\\1,\\2: /g' \
             | sed -n '2,$p')
}

CJK="日本語日本語日本語日本語日本語日本語日本"     # 20 characters, 40 columns
ASCII="abcdefghijklmnopqrst"                       # 20 characters, 20 columns

# ── The conversions themselves ───────────────────────────────────────────────
note "ft_display_col / ft_display_index are the exact inverse of ft_display_width"
for s in "$ASCII" "$CJK" "ab日cd語ef" "a"$'\t'"b" $'\e[31mred\e[0m' "e👍f" "e"$'́'"f"; do
    ft_display_width "$s"; w=$FT_DISPLAY_WIDTH
    ft_display_col "$s" ${#s}
    check "col(whole string) == its width  [${s@Q}]" "$FT_RET" "$w"
done
ft_display_col "$CJK" 0;  check "col of character 0 is column 0"   "$FT_RET" "0"
ft_display_col "$CJK" 3;  check "3 wide characters is 6 columns"   "$FT_RET" "6"
ft_display_col "$ASCII" 3; check "3 ASCII characters is 3 columns" "$FT_RET" "3"

note "ft_display_index maps a column back to a character, and reports where it landed"
ft_display_index "$CJK" 6;  check "column 6 → character 3"          "$FT_RET" "3"
check "…and column 6 is exactly where it is"                        "$FT_DISPLAY_COL" "6"
ft_display_index "$CJK" 7;  check "column 7 splits a glyph → snaps FORWARD to character 4" "$FT_RET" "4"
check "…and says so: the real column is 8, not 7"                   "$FT_DISPLAY_COL" "8"
ft_display_index "$ASCII" 7; check "ASCII: column 7 → character 7"  "$FT_RET" "7"
ft_display_index "$CJK" 999; check "past the end clamps to the last character" "$FT_RET" "20"
ft_display_index "$CJK" -5;  check "before the start clamps to 0"   "$FT_RET" "0"
ft_display_index "" 4;       check "the empty string has no characters" "$FT_RET" "0"

note "round trip: index(col(k)) == k for every character of a mixed string"
mixed="a日b語c👍d"
bad=""
for (( k=0; k<=${#mixed}; k++ )); do
    ft_display_col "$mixed" "$k"; c=$FT_RET
    ft_display_index "$mixed" "$c"
    [[ "$FT_RET" == "$k" ]] || bad+="$k(→$c→$FT_RET) "
done
check "every character survives the round trip" "${bad:-clean}" "clean"

# ── The one-line field ───────────────────────────────────────────────────────
ft-form name=f width=40 height=14
    ft-textfield name=one  size=10 value="" border=true animation=none
    ft-textfield name=area size=10 rows=4 wrap=false border=true animation=none
end_ft_form
ft_layout f; FT_ROOT=f; ft_focus one
ft_textfield_activate one
_ft_textfield_textw one; TEXTW=$FT_RET

paint() { FT_OUT=""; ft_draw_one "$1"; }
# The Nth text row of a field's box (0 = the row under the top border), whole: border,
# gutters and all. Both fields are painted one row per ft_print_at, anchored at the box's left.
boxrow() {                      # name n → FT_RET
    _run_at $(( ${FT_ABSOLUTE_Y[$1]:-0} + 2 + $2 )) $(( ${FT_ABSOLUTE_X[$1]:-0} + 1 ))
}
# …and just the WELL out of it: drop the left border and line-number gutter (single-width
# cells, so characters and columns agree there), then take exactly `textw` COLUMNS. What
# follows the well — a wrap rail, the right border — is painted differently by the two
# draws, so it is measured off rather than assumed.
wellof() {                      # name n textw → FT_RET  (after _ft_textfield_textw NAME)
    local lead=$(( FT_TEXTFIELD_LEFT_BORDER + FT_TEXTFIELD_LINE_NUMBER_WIDTH ))
    boxrow "$1" "$2"; local r=${FT_RET:lead}
    ft_display_index "$r" "$3"
    FT_RET=${r:0:$FT_RET}
}

note "the well is exactly its own width, whatever is in it (textw=$TEXTW)"
for v in "$ASCII" "$CJK" "ab日cd語ef" "👍👍👍👍👍👍👍👍" "short"; do
    ft-modify one value="$v"
    FT_TEXTFIELD_CARET[one]=0; _ft_setprop one scrollLeft 0
    paint one; boxrow one 0
    ft_display_width "$FT_RET"
    check "the box is ${FT_MEASURED_WIDTH[one]} columns wide  [${v:0:6}…]" \
          "$FT_DISPLAY_WIDTH" "${FT_MEASURED_WIDTH[one]}"
done

note "THE BUG: the caret at the end of a wide-glyph value is still on screen"
# The field follows the caret in COLUMNS, so the last glyphs of the value are what shows.
ft-modify one value="$CJK"
FT_TEXTFIELD_CARET[one]=20; _ft_setprop one scrollLeft 0
paint one; wellof one 0 "$TEXTW"
check "the END of the value is visible"  "$FT_RET" "日本語日本  "
check "…and the scroll offset is COLUMNS, not characters" "$(_hoff one)" "30"
_ft_textfield_caret_screen one
check "the terminal cursor is inside the well" \
      "$(( FT_CARET_C >= FT_ABSOLUTE_X[one] + 1 && FT_CARET_C <= FT_ABSOLUTE_X[one] + TEXTW ))" "1"
check "…on the column right after the last glyph" \
      "$FT_CARET_C" "$(( FT_ABSOLUTE_X[one] + 1 + 10 ))"

ft-modify one value="$ASCII"        # the same field, the same caret, in ASCII — unchanged
FT_TEXTFIELD_CARET[one]=20; _ft_setprop one scrollLeft 0
paint one; wellof one 0 "$TEXTW"
check "ASCII is untouched: the end still shows" "$FT_RET" "jklmnopqrst "
check "…with the same offset it always had"     "$(_hoff one)" "9"

note "a caret in the middle keeps its glyph whole"
ft-modify one value="$CJK"
FT_TEXTFIELD_CARET[one]=3; _ft_setprop one scrollLeft 0
paint one; wellof one 0 "$TEXTW"
check "no scrolling needed yet"    "$(_hoff one)" "0"
check "the first six glyphs show"  "$FT_RET" "日本語日本語"
_ft_textfield_caret_screen one
check "the cursor sits on column 6 of the well (3 glyphs in)" \
      "$FT_CARET_C" "$(( FT_ABSOLUTE_X[one] + 1 + 6 ))"

note "a click lands on the character the user pointed at"
# Round trip through the SCREEN: put the caret at k, ask where that is, click there, expect k.
for v in "$ASCII" "$CJK" "ab日cd語ef"; do
    ft-modify one value="$v"
    _ft_setprop one scrollLeft 0
    bad=""
    for (( k=0; k<=6; k++ )); do
        FT_TEXTFIELD_CARET[one]=$k
        paint one                                   # the draw settles the scroll offset
        ft_display_col "$v" "$k"; c=$FT_RET
        _ft_textfield_caret_at one $(( 1 + c - $(_hoff one) )) 1
        [[ "$FT_RET" == "$k" ]] || bad+="$k→$FT_RET "
    done
    check "click round trip  [${v:0:8}…]" "${bad:-clean}" "clean"
done

note "clicking PAST the text puts the caret at the end, not beyond it"
ft-modify one value="日本"          # 2 characters, 4 columns, in a 12-column well
_ft_setprop one scrollLeft 0
_ft_textfield_caret_at one 11 1
check "a click in the empty right of the well → the last character" "$FT_RET" "2"
_ft_textfield_caret_at one 2 1
check "a click on the second half of glyph 1 → the next boundary"   "$FT_RET" "1"

# ── The text area ────────────────────────────────────────────────────────────
note "a non-wrapping text area pans sideways in columns"
ft_focus area
ft-modify area value="$CJK"$'\n'"$ASCII"
FT_TEXTFIELD_CARET[area]=0; _ft_setprop area scrollLeft 0; _ft_setprop area scrollTop 0
_ft_textfield_textw area; ATW=$FT_RET
# An IDLE viewer, so the pan under test is the one set here — an engaged field re-derives
# its offset from the caret every frame, which would simply undo the assignment.
ft_textfield_deactivate area
paint area; wellof area 0 "$ATW"
check "unpanned: the wide line starts at its start" "$FT_RET" "日本語日本語"
_ft_setprop area scrollLeft 6                 # six COLUMNS = three glyphs
paint area; wellof area 0 "$ATW"
check "panned 6 columns: three glyphs have gone by"           "$FT_RET" "日本語日本語"
wellof area 1 "$ATW"
check "…and the ASCII line on the next row moved 6 characters" "$FT_RET" "ghijklmnopqr"
_ft_setprop area scrollLeft 7                 # HALF a glyph in: snap forward, never split one
paint area; wellof area 0 "$ATW"
check "panned 7 columns: the straddling glyph is skipped whole" "$FT_RET" "本語日本語日"
# The area keeps the RAW column, unlike the one-line field which stores the snapped one.
# It has to: the offset is shared by every row, and each row's glyph boundaries are its
# own — normalising to one row's boundary would misalign all the others. Each row snaps
# for itself at paint time, and the click mapping snaps by the same rule on the same row,
# so the two always agree about which glyph a cell belongs to.
check "…and the shared offset stays the column asked for" "$(_hoff area)" "7"

note "every row of the area is exactly its own width, panned or not"
bad=""
for s in 0 1 6 7 30; do
    _ft_setprop area scrollLeft $s
    paint area
    for (( r=0; r<2; r++ )); do
        boxrow area "$r"
        ft_display_width "$FT_RET"
        (( FT_DISPLAY_WIDTH == ${FT_MEASURED_WIDTH[area]} )) \
            || bad+="scroll=$s row=$r:$FT_DISPLAY_WIDTH "
    done
done
check "no row overflows or falls short" "${bad:-clean}" "clean"

note "the caret follows in a wide-glyph line the same way it does in ASCII"
ft_textfield_activate area
_ft_setprop area scrollLeft 0
FT_TEXTFIELD_CARET[area]=20                 # end of the first (CJK) line
paint area
check "the area scrolled by columns to reach it" "$(_hoff area)" "$(( 40 - ATW ))"
wellof area 0 "$ATW"
ft_display_width "$FT_RET"
check "…and the row it painted is still exactly the well" "$FT_DISPLAY_WIDTH" "$ATW"

note "a click in the area lands on the character pointed at, on any row"
_ft_setprop area scrollLeft 0; _ft_setprop area scrollTop 0
_ft_textfield_caret_at area 1 1;  check "row 0, column 0 → character 0"        "$FT_RET" "0"
_ft_textfield_caret_at area 5 1;  check "row 0, column 4 → character 2"        "$FT_RET" "2"
_ft_textfield_caret_at area 6 1;  check "row 0, mid-glyph → snaps to character 3" "$FT_RET" "3"
_ft_textfield_caret_at area 4 2;  check "row 1 (ASCII) column 3 → character 24" "$FT_RET" "24"

note "NOTHING wrote to stderr while any of that was drawn"
err=$( { ft-modify one value="$CJK"; FT_TEXTFIELD_CARET[one]=20; paint one
         ft-modify area value="$CJK"; _ft_setprop area scrollLeft 7; paint area
         _ft_textfield_caret_at one 99 1; _ft_textfield_caret_at area 0 9
         _ft_textfield_caret_screen one; _ft_textfield_caret_screen area; } 2>&1 >/dev/null )
check "clean" "${err:-clean}" "clean"

note "ft_display_width measures EVERY category — the fast paths must not change any answer"
# There are three paths now: pure ASCII (length), escape-free-but-not-ASCII (ASCII runs counted
# wholesale, ft_char_cols asked only about the non-ASCII characters), and the full per-character
# scan for strings containing escapes. The middle one was added because ONE em-dash in a line
# used to send all 36 of its characters through the slow scan — 2.5s to measure a 4000-line
# document, which is most of what a resize cost. Every category below has to survive that.
_dw() { ft_display_width "$1"; printf '%s' "$FT_DISPLAY_WIDTH"; }
check "pure ASCII"                   "$(_dw 'hello world')"        11
check "the empty string"             "$(_dw '')"                    0
check "prose with an em-dash"        "$(_dw 'line 1 — the fox')"   16
check "curly quotes"                 "$(_dw '“quoted”')"            8
check "accented latin"               "$(_dw 'café')"                4
check "CJK is TWO columns each"      "$(_dw '日本語')"               6
check "CJK mixed with ASCII"         "$(_dw 'ab日本cd')"             8
check "an emoji is two columns"      "$(_dw '🙂')"                  2
check "a combining mark adds none"   "$(_dw $'é')"            1
check "a zero-width space adds none" "$(_dw $'a​b')"           2
check "a tab advances to the stop"   "$(_dw $'a\tb')"               9
check "SGR escapes are zero width"   "$(_dw $'\e[1mbold\e[0m')"     4
check "escape AND non-ASCII together" "$(_dw $'\e[1m—\e[0m')"       1

summary
