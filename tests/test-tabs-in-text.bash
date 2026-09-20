#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tests/test-tabs-in-text.bash — a TAB in a control's text.
#
#  A tab is ASCII, so every width fast path counted it as ONE column while a terminal advances
#  to its own next stop — measured from the SCREEN edge, which has nothing to do with the
#  control's box. A label reading $'ab\tcd' measured 5 and painted 10: the cursor jumped clear
#  of the box and the next control overwrote the tail, so the "cd" simply vanished. Text that
#  arrives from outside — a config file, command output, a pasted snippet — has tabs in it
#  routinely, and this is a samba tool.
#
#  The rule: no tab ever reaches the terminal. It is expanded to spaces at DISPLAY time, with
#  stops measured from the start of the string — the one origin the measurer and the painter
#  can both agree on. NOT at storage time: a text field holding a config file has to give back
#  the tabs it was given.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=80; FT_ROWS=24

note "expansion puts a tab on the next stop, counting from the start of the string"
ft_expand_tabs $'ab\tcd';   check "ab<TAB>cd"        "$FT_RET" "ab      cd"
ft_expand_tabs $'\tx';      check "a leading tab"    "$FT_RET" "        x"
ft_expand_tabs $'abcdefg\tx'; check "just short of a stop" "$FT_RET" "abcdefg x"
ft_expand_tabs $'abcdefgh\tx'; check "exactly on a stop → a full run" "$FT_RET" "abcdefgh        x"
ft_expand_tabs $'a\tb\tc';  check "several tabs"     "$FT_RET" "a       b       c"
ft_expand_tabs "no tabs";   check "left alone"       "$FT_RET" "no tabs"
ft_expand_tabs $'日\tx';    check "after a wide glyph, by COLUMNS not characters" "$FT_RET" "日      x"

note "measurement agrees with what a terminal would draw"
ft_display_width $'ab\tcd';  check "ab<TAB>cd is 10 columns" "$FT_DISPLAY_WIDTH" 10
ft_display_width $'\tx';     check "a leading tab is 9"      "$FT_DISPLAY_WIDTH" 9
ft_display_width "ab      cd"
_w=$FT_DISPLAY_WIDTH; ft_display_width $'ab\tcd'
check "a tab measures the same as the spaces it stands for" "$FT_DISPLAY_WIDTH" "$_w"

note "NO control may let a tab reach the terminal"
# The last gate is ft_print_at — controls that compose their own string (a button centring its
# label) never pass through ft_fit, so guarding only there left them broken.
emits_tab() {                   # type build-args… → 0 if a raw tab reaches the output
    local t=$1; shift
    ft_remove tp 2>/dev/null
    ft-form name=tp width=60 height=10
        "ft-$t" name=probe "$@"
    end_ft_form
    ft_layout tp; FT_ROOT=tp
    FT_OUT=""; ft_draw_one probe >/dev/null 2>&1
    [[ "$FT_OUT" == *$'\t'* ]]
}
for spec in "label" "heading" "button"; do
    if emits_tab "$spec" text=$'ab\tcd'; then check "$spec emits no raw tab" "a raw tab" "none"
    else check "$spec emits no raw tab" 1 1; fi
done
if emits_tab textfield size=20 value=$'ab\tcd'; then check "textfield emits no raw tab" "a raw tab" "none"
else check "textfield emits no raw tab" 1 1; fi

note "…and the control is laid out at the width it will actually paint"
# This is the half that keeps it INSIDE the box: the layout asked one of the inlined width
# fast paths, which took the ASCII shortcut and returned 5 for a string that paints 10.
ft_remove tp 2>/dev/null
ft-form name=tp width=60 height=10
    ft-label name=lt text=$'ab\tcd'
    ft-label name=ls text="ab      cd"
end_ft_form
ft_layout tp; FT_ROOT=tp
check "a tabbed label is as wide as the spaces it draws" "${FT_MEASURED_WIDTH[lt]}" "${FT_MEASURED_WIDTH[ls]}"

note "storage is untouched — a config file keeps its tabs"
ft_remove tp 2>/dev/null
ft-form name=tp width=60 height=10
    ft-textfield name=cfg size=30 value=$'[global]\n\tworkgroup = WG'
end_ft_form
ft_layout tp; FT_ROOT=tp
ft_get cfg value
case "$FT_RET" in *$'\t'*) check "the tab is still in the value" 1 1 ;;
                  *)       check "the tab is still in the value" "$FT_RET" "…with a tab" ;; esac

# ─────────────────────────────────────────────────────────────────────────────
#  …AND A NEWLINE, which is the same rule with a worse consequence.
#
#  A newline sends the cursor to column 1 of the NEXT row — outside the clip, outside the
#  control's box, over whatever is there — and emitted on the last row it SCROLLS THE WHOLE
#  SCREEN. The layout already knows a label can have one: a radio's height function answers
#  FT_TEXT_HEIGHT, so the second row is measured and reserved. It was the DRAW that had no way
#  to reach it, and three controls put the byte straight into the stream:
#
#      label     ESC[1;1H … ESC[2;1H      two positioned rows — correct all along
#      radio     ESC[4;1H … \n            one position, then a raw newline
#      checkbox  ESC[7;1H … \n
#      button    ESC[10;1H … \n
#
#  ft_print_at is the last gate the tab rule already lives at, and it is the last gate for this.
# ─────────────────────────────────────────────────────────────────────────────
note "a newline never reaches the terminal either — every row is positioned"
_ink() {                        # name → FT_RET = its raw ink
    FT_OUT=""; ft_dirty "$1"; ft_draw_one "$1" >/dev/null 2>&1
    FT_RET=$FT_OUT; FT_OUT=""
}
_rows() { printf '%s' "$1" | grep -oE $'\x1b\\[[0-9]+;[0-9]+H' | wc -l; }
_bare() { printf '%s' "$1" | tr -cd '\n' | wc -c; }

ft_remove nl 2>/dev/null
TWO="first line"$'\n'"second line"
ft-form name=nl width=50 height=24 display=flex flexDirection=column gap=1
    ft-label name=nlLabel text="$TWO"
    ft-radio name=nlRadio group=g text="$TWO"
    ft-checkbox name=nlCheck text="$TWO"
    ft-button name=nlBtn text="$TWO"
end_ft_form
ft_layout nl; FT_ROOT=nl
for _c in nlLabel nlRadio nlCheck nlBtn; do
    _ink "$_c"
    check "$_c puts no bare newline in the stream" "$(_bare "$FT_RET")" "0"
    check "…and positions both of its rows"        "$(_rows "$FT_RET")" "2"
done
# The second row lands in the control's OWN column, not the terminal's first — which is the
# whole point, and the thing a newline could never do.
ft-form name=nl2 width=50 height=10
    ft-radio name=nlOff group=g2 left=12 top=3 position=absolute text="$TWO"
end_ft_form
ft_layout nl2; FT_ROOT=nl2
_ink nlOff
check "an offset control's second row is at its own column" \
      "$(printf '%s' "$FT_RET" | grep -oE $'\x1b\\[[0-9]+;[0-9]+H' | tr -d $'\x1b[H' | tr '\n' ' ')" \
      "4;13 5;13 "

summary
