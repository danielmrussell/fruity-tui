#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Tests for controls/ft-button.bash — and specifically for the claim the prototype is built
#  on: A BUTTON IS A LABEL THAT ACTIVATES. Its prototype-constructor calls label's; its painter
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
#  label given the same text and width — the relationship the prototype declares, checked rather
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
        ft-button name=btn text="Help" "$@"
        ft-label name=lbl text="Help" "$@"
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
# The prototype says a button is a label that activates. At the same width and alignment the two
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
    ft-button name=btn text="Disconnect" width=6
    ft-label name=lbl text="Disconnect" width=6
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
    ft-button name=bk1 accessKey=e text="Help" # the letter IS in the label
    ft-button name=bk2 accessKey=S text="Write" # it is not → " (S)" is appended
    ft-button name=bk3 accessKey=S text="Write" width=5 # …and the box is too small for it
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
    ft-button name=btb text="a	b"
    ft-label name=ltb text="a	b"
end_ft_form
ft_layout bapp
_paint btb; _b=$FT_RET
check "the button fills the width it claimed" "${#_b}" "${FT_MEASURED_WIDTH[btb]}"
_paint ltb; check "and it is the label's own expansion, padded" "$_b" " $FT_RET "
ft_remove bapp 2>/dev/null


# ── The ten common buttons ──────────────────────────────────────────────────
# A button plus the letter people already reach for. The letter is an accessKey — a SHORTCUT,
# live anywhere on the screen rather than only while the button has focus.
note "each kind brings its label and its letter"
ft-form name=kapp width=70 height=14
    ft-button-ok name=k_ok           ; ft-button-cancel name=k_cancel
    ft-button-yes name=k_yes         ; ft-button-no name=k_no
    ft-button-new name=k_new         ; ft-button-quit name=k_quit
    ft-button-help name=k_help       ; ft-button-save name=k_save
    ft-button-back name=k_back       ; ft-button-forward name=k_forward
end_ft_form
FT_ROOT=kapp; ft_layout kapp
_kind() { ft_get "$1" text; local t=$FT_RET; ft_resolved_prop "$1" accessKey; printf '%s/%s' "$t" "$FT_RET"; }
check "ok"      "$(_kind k_ok)"      "OK/k"
check "cancel"  "$(_kind k_cancel)"  "Cancel/c"
check "yes"     "$(_kind k_yes)"     "Yes/y"
check "no"      "$(_kind k_no)"      "No/n"
check "new"     "$(_kind k_new)"     "New/n"
check "quit"    "$(_kind k_quit)"    "Quit/q"
check "help"    "$(_kind k_help)"    "Help/h"
check "save"    "$(_kind k_save)"    "Save/s"
check "back"    "$(_kind k_back)"    "Back/b"
check "forward" "$(_kind k_forward)" "Forward/f"
# The letter must be IN the label, or the underline is appended as " (K)" instead of marking
# a character — which is why ok is k and not o.
missing=""
for b in k_ok k_cancel k_yes k_no k_new k_quit k_help k_save k_back k_forward; do
    ft_get "$b" text; t=$FT_RET; ft_resolved_prop "$b" accessKey
    [[ "${t^^}" == *"${FT_RET^^}"* ]] || missing+="$b "
done
check "every letter appears in its own label" "${missing% }" ""

# THE BUG THIS FAMILY FOUND. The draw underlines the letter through the cascade, but the
# REGISTRATION read the raw instance property — so a letter that comes from the prototype was
# painted with its underline and bound to nothing at all. A shortcut you can see and cannot
# press is worse than no shortcut.
note "a prototype-provided letter is really registered, not just underlined"
_ft_accel_target kapp K; check "K reaches the OK button"      "$FT_RET" "k_ok"
_ft_accel_target kapp C; check "C reaches Cancel"             "$FT_RET" "k_cancel"
_ft_accel_target kapp F; check "F reaches Forward"            "$FT_RET" "k_forward"
KB=""; kb_hit() { KB=hit; }
ft_set k_ok onActivate='kb_hit "$@"'
_ft_accel_dispatch kapp K
check "…and pressing it activates the button" "$KB" "hit"

# Sharing is the feature: no and new both claim n, and the first VISIBLE one answers.
note "two kinds may share a letter — the first visible one answers"
_ft_accel_target kapp N; check "N finds the first claimant"   "$FT_RET" "k_no"
ft_set k_no display=none
_ft_accel_target kapp N; check "…and the next one when it is hidden" "$FT_RET" "k_new"
ft_set k_no display=inline-block

note "a kind is still a button: the app's text and handler win"
ft-form name=kapp2 width=40 height=6
    ft-button-save name=k_sa text="Save As…" onActivate='kb_hit "$@"'
end_ft_form
FT_ROOT=kapp2; ft_layout kapp2
check "the app's text replaces the default" "$(ft_get k_sa text; printf '%s' "$FT_RET")" "Save As…"
check "…and the letter is still there"      "$(ft_resolved_prop k_sa accessKey; printf '%s' "$FT_RET")" "s"
KB=""; ft_activate k_sa
check "…and its own handler runs"           "$KB" "hit"

summary
