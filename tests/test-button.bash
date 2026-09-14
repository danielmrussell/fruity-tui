#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Tests for controls/ft-button.bash — and specifically for the claim the class is built
#  on: A BUTTON IS A LABEL THAT ACTIVATES. Its class-constructor calls label's; its painter
#  must therefore lay text out the way a label does, not the way a hand copy of ft_fit_align
#  happened to.
#
#  It did not. The painter measured the text and distributed its own padding, which is
#  ft_fit_align's centre branch written out by hand — so it always centred (textAlign on a
#  button was accepted and thrown away), it never ellipsised (a button narrower than its label
#  painted the whole thing, straight over whatever sat beside it), and it never expanded a tab
#  at fit time (so it claimed a width it did not paint).
#
#  These assert on what is PAINTED, and the equivalence assertions compare a button against a
#  label given the same text and width — the relationship the class declares, checked rather
#  than assumed.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=60; FT_ROWS=12; FT_COLOR_MODE=256; FT_USE_UTF8=1

_paint() {                      # control → FT_RET = what it painted, ANSI stripped
    FT_OUT=""; ft_draw_one "$1"
    FT_RET=$(printf '%s' "$FT_OUT" | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g')
}
_lead()  { local s=$1 n=0; while [[ "${s:n:1}" == " " ]]; do (( n++ )); done; printf '%s' "$n"; }
_build() {                      # props… — one button and one label, same text, same width
    ft_remove bapp 2>/dev/null
    ft-form name=bapp width=60 height=8
        ft-button name=btn "Help" "$@"
        ft-label  name=lbl "Help" "$@"
    end_ft_form
    ft_layout bapp
}

note "textAlign is honoured — the property the framework already had"
_build width=26 textAlign=left
_paint btn; check "textAlign=left starts at column 0" "$(_lead "$FT_RET")" 0
_build width=26 textAlign=right
_paint btn; check "textAlign=right ends flush right"  "$(_lead "$FT_RET")" 22
_build width=26
_paint btn; check "a button still CENTRES by default" "$(_lead "$FT_RET")" 11

note "a button lays out its label exactly as a label does"
# The class says a button is a label that activates. At the same width and alignment the two
# must paint the same columns — that is the whole claim, and it is what re-joining the painter
# to ft_fit_align buys. (A button adds nothing of its own here: its one space of padding per
# side is in its WIDTH, via _ft_preferred_width_button, not in its painter.)
for _al in left right center; do
    _build width=26 textAlign=$_al
    _paint btn; _b=$FT_RET
    _paint lbl; _l=$FT_RET
    check "textAlign=$_al: button paints what the label paints" "$_b" "$_l"
done

note "a label too long for the box is ellipsised, never painted over its neighbour"
ft_remove bapp 2>/dev/null
ft-form name=bapp width=60 height=8
    ft-button name=btn  "Disconnect" width=6
    ft-label  name=lbl  "Disconnect" width=6
end_ft_form
ft_layout bapp
_paint btn; _b=$FT_RET
check "the button paints exactly its own 6 columns" "${#_b}" 6
case "$_b" in *"$FT_GLYPH_ELLIPSIS") check "…and says it was cut" 1 1 ;;
              *)                     check "…and says it was cut" 0 1 ;; esac
# The bug this replaces: the painter clamped a negative pad to zero and drew the whole label,
# so a squeezed button put 10 columns into a 6-column box and over its neighbour's cells.
case "$_b" in *Disconnect*) check "the full label is NOT painted past the box" 0 1 ;;
              *)            check "the full label is NOT painted past the box" 1 1 ;; esac
# (A LABEL is not the comparator here: a label wraps to a second row, a button is one line.
# The shared part is the fitter, which is what the assertions above check.)

note "the accessKey underline survives the re-join"
ft_remove bapp 2>/dev/null
ft-form name=bapp width=60 height=8
    ft-button name=bk1 accessKey=e "Help"          # the letter IS in the label
    ft-button name=bk2 accessKey=S "Write"         # it is not → " (S)" is appended
    ft-button name=bk3 accessKey=S "Write" width=5 # …and the box is too small for it
end_ft_form
ft_layout bapp
FT_OUT=""; ft_draw_one bk1
# Counted by removal, not by grep: FT_ANSI_UNDERLINE is an ESC sequence with a `[` in it, which
# is a character class to any regex engine that reads it.
_stripped=${FT_OUT//"$FT_ANSI_UNDERLINE"/}
check "the accessKey letter is underlined exactly once" \
      $(( (${#FT_OUT} - ${#_stripped}) / ${#FT_ANSI_UNDERLINE} )) 1
_paint bk2; check "an absent accessKey is still parenthesised" "${FT_RET// /}" "Write(S)"
# Truncated past its accessKey, the underline is simply lost — what must NOT happen is the
# markup appending a " (S)" the box has no room for, which is how the box overran before.
_paint bk3; check "a squeezed button still paints exactly its width" "${#FT_RET}" 5
ft_remove bapp 2>/dev/null

note "a TAB in a label is expanded at fit time, like every other control's text"
# The old painter measured the text, then handed a raw tab to ft_print_at, which expanded it against
# the SCREEN column — one further along, because of the button's own leading pad — so the button
# claimed 11 columns and painted 10. Expanding at fit time is what ft_fit/ft_fit_align do and
# why they do it; the button now agrees with the label to the column.
ft_remove bapp 2>/dev/null
ft-form name=bapp width=60 height=8
    ft-button name=btb "a	b"
    ft-label  name=ltb "a	b"
end_ft_form
ft_layout bapp
_paint btb; _b=$FT_RET
check "the button fills the width it claimed" "${#_b}" "${FT_MEASURED_WIDTH[btb]}"
_paint ltb; check "and it is the label's own expansion, padded" "$_b" " $FT_RET "
ft_remove bapp 2>/dev/null

summary
