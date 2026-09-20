#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  A SCROLL OFFSET IS CLAMPED AT THE WRITE, NOT CORRECTED AT THE PAINT.
#
#  `ft-modify log scrollTop=99` on a 12-line label in a 4-row box stored 99 and PAINTED line 9,
#  and `scrollTop=-5` stored -5 and painted line 1. ft_label_scroll_set — the verb for the same
#  job — stored 8. Two routes, two answers, and the property route was the one an app reads back.
#  In a browser `el.scrollTop = 99` reads back scrollHeight-clientHeight.
#
#  The bounds are the box's own published scrollHeight/clientHeight, so the rule is the
#  framework's: _ft_clamp_scroll in _ft_setprop, on every route in. A scrollbar bound to a target
#  writes the property directly (`ft-modify TARGET scrollTop=N`), so it inherits the clamp too.
#
#  AND THE DOCUMENT CAN SHRINK UNDER THE OFFSET, which no clamp at write time can anticipate:
#  replacing a scrolled label's text with one line left scrollTop where it was. Both publishers
#  now clamp when they publish — _ft_label_metrics for a label's own content, _ft_pass_arrange
#  for a container's children.
#
#  A CHILDLESS SCROLLER IS NOT A CONTAINER. `ft-label overflow=scroll` is the ordinary way to
#  write it, and the container branch of the arrange claimed the same word: it computed an extent
#  from children there are none of and published scrollHeight=0 over the label's own answer.
#  Harmless while nothing consumed it; the moment offsets were clamped against that pair, a
#  layout pinned every label's scrollTop to 0.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=60; FT_ROWS=24; FT_USE_UTF8=1

_long=$(printf 'line %s\n' 1 2 3 4 5 6 7 8 9 10 11 12)
ft-form name=app width=60 height=24
    ft-label name=lg width=20 height=4 overflow=scroll text="$_long"
    ft-div name=box width=20 height=4 overflow=scroll display=flex flexDirection=column
        ft-label name=k1 text="one";  ft-label name=k2 text="two";  ft-label name=k3 text="three"
        ft-label name=k4 text="four"; ft-label name=k5 text="five"; ft-label name=k6 text="six"
    end_ft_div
end_ft_form
ft_layout app
FT_ROOT=app

# EVERY DRAW HAPPENS IN THIS SHELL. A draw publishes scrollHeight, and $( ) would throw that
# write away in a subshell — which is exactly how the first reading of this bug said
# "scrollHeight answers 0".
PAINTED=""
_draw() { FT_OUT=""; ft_dirty "$1"; ft_draw_one "$1" >/dev/null 2>&1
          PAINTED=$FT_OUT; FT_OUT=""
          PAINTED=$(printf '%s' "$PAINTED" | sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g'); }
_first() { _draw "$1"; printf '%s' "$PAINTED" | grep -o 'line [0-9]*' | head -1; }
_n()   { ft_resolved_prop "$1" "$2" 0; printf '%s' "${FT_RET:-0}"; }

note "the fixture really overflows, and really publishes its extent"
_draw lg
check "twelve lines measured"     "$(_n lg scrollHeight)" "12"
check "…into a four-row viewport" "$(_n lg clientHeight)" "4"
check "…and it starts at the top" "$(_first lg)"          "line 1"

note "a label: the offset lands inside [0, scrollHeight-clientHeight] whatever you write"
ft-modify lg scrollTop=3
check "an in-range offset is kept"  "$(_n lg scrollTop)" "3"
check "…and it paints there"        "$(_first lg)"       "line 4"
ft-modify lg scrollTop=99
check "past the bottom clamps"      "$(_n lg scrollTop)" "8"
check "…and the paint agrees"       "$(_first lg)"       "line 9"
ft-modify lg scrollTop=-5
check "above the top clamps"        "$(_n lg scrollTop)" "0"
check "…and the paint agrees"       "$(_first lg)"       "line 1"

note "…which is what the verb has always answered — the two routes now agree"
ft_label_scroll_set lg 99
check "the verb clamps the same way" "$(_n lg scrollTop)" "8"
ft-modify lg scrollTop=99
check "…and so does the property"    "$(_n lg scrollTop)" "8"

note "the document shrinking under a scrolled label takes the offset with it"
ft-modify lg scrollTop=99; _draw lg
check "scrolled to the end"          "$(_n lg scrollTop)" "8"
ft-modify lg text="only one line"; _draw lg
check "one line left → offset is 0"  "$(_n lg scrollTop)" "0"
check "…and the extent says so"      "$(_n lg scrollHeight)" "1"
ft-modify lg text="$_long"; _draw lg
check "and the long text restores the range" "$(_n lg scrollHeight)" "12"

note "a scrollable CONTAINER, whose extent comes from the arrange rather than a draw"
check "six rows of children"      "$(_n box scrollHeight)" "6"
check "…in four rows of viewport" "$(_n box clientHeight)" "4"
ft-modify box scrollTop=99
check "past the bottom clamps"    "$(_n box scrollTop)" "2"
ft-modify box scrollTop=-3
check "above the top clamps"      "$(_n box scrollTop)" "0"
ft-modify box scrollTop=1
check "in range is kept"          "$(_n box scrollTop)" "1"

note "…and its children going away brings the offset back with them"
ft-modify box scrollTop=2
check "scrolled to the end"       "$(_n box scrollTop)" "2"
ft-modify k4 display=none; ft-modify k5 display=none; ft-modify k6 display=none
ft_layout app
check "three rows left → offset 0" "$(_n box scrollTop)" "0"
check "…and the extent shrank"     "$(_n box scrollHeight)" "3"
ft-modify k4 display=block; ft-modify k5 display=block; ft-modify k6 display=block
ft_layout app

note "a childless scroller measures its OWN content — the arrange must not answer for it"
# The container branch computed the extent from children there are none of, and published 0.
ft_layout app; _draw lg
check "a layout does not zero the label's extent" "$(_n lg scrollHeight)" "12"
check "…nor pin its offset to the top"            "$(_n lg clientHeight)" "4"
ft-modify lg scrollTop=6
ft_layout app
check "an offset survives a relayout"             "$(_n lg scrollTop)" "6"
check "…and still paints where it says"           "$(_first lg)"       "line 7"

note "an extent is a number, so an app cannot post one into (( ))"
_canary=$(mktemp -u)
_err=$(mktemp)
ft-modify lg scrollHeight="q[\$(touch $_canary)]" 2>"$_err"
ft-modify lg scrollTop=3
check "the subscript did NOT execute" "$([[ -e "$_canary" ]] && printf ran || printf no)" "no"
grep -q 'is not a number' "$_err" && check "…and the declaration was dropped, loudly" 1 1 \
                                  || check "…and the declaration was dropped, loudly" 0 1
check "…leaving the real extent in place" "$(_n lg scrollHeight)" "12"
rm -f "$_canary" "$_err"

summary
