#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  A SLIDER'S VALUE IS SANITIZED AT EVERY WRITE, NOT CORRECTED AT EVERY PAINT.
#
#  `ft-modify sl max=4` on a slider showing 5 left the property at 5. _ft_draw_slider clamped
#  for itself, so the knob AND the value text said 4 while `ft_get sl value` said 5: the app and
#  the user were reading different numbers off the same control. `ft-modify sl value=500` was
#  the same divergence from the other end, and `value=7 step=5` put the knob where the slider's
#  own arrow keys could never place it.
#
#  HTML calls the rule the value sanitization algorithm and runs it when value, min, max OR step
#  changes: clamp into range, round to the nearest step-aligned value (step base = min, ties up),
#  then back into range. It is _ft_slider_sanitize, and it is the ONLY copy — the mouse used to
#  carry its own clamp-and-snap and the paint its own clamp.
#
#  THE PAINT IS ASSERTED ALONGSIDE THE PROPERTY EVERYWHERE BELOW. That pairing is the whole
#  point: a fix that sanitized the property but left the drawing correcting a second time would
#  pass every property assertion on its own.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=70; FT_ROWS=24; FT_USE_UTF8=1

ft-form name=app width=70 height=24
    ft-slider name=sl min=0 max=10 value=5 step=1 width=24 showValue=true
end_ft_form
ft_layout app
FT_ROOT=app

_prop() { ft_get sl value; printf '%s' "${FT_RET:-<unset>}"; }
_drawn() {                      # NAME → the number the control actually DRAWS (showValue text)
    FT_OUT=""; ft_dirty "$1"; ft_draw_one "$1" >/dev/null 2>&1
    local p=$FT_OUT; FT_OUT=""
    # The readout is padded to the width the track reserved for the widest value, so the
    # number is the last WORD, not the last thing painted.
    printf '%s' "$p" | sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g' | tr -d '\n' | sed -E 's/ +$//; s/^.* //'
}
_shown() { _drawn sl; }
_knob() {                       # 0-based column of the knob within the painted track
    FT_OUT=""; ft_dirty sl; ft_draw_one sl >/dev/null 2>&1
    local p=$FT_OUT; FT_OUT=""
    p=$(printf '%s' "$p" | sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g' | tr -d '\n')
    p=${p%% *}                                     # drop the value text
    p=${p%%●*}                                     # everything before the knob
    ft_display_width "$p"; printf '%s' "$FT_DISPLAY_WIDTH"
}
_agree() {                      # NAME EXPECTED — the property, the drawn number, and each other
    check "$1"            "$(_prop)"  "$2"
    check "…and it DRAWS that too" "$(_shown)" "$2"
}

note "the fixture really draws a knob and a number (without this the rest is vacuous)"
check "the value text is there" "$(_shown)" "5"
_k5=$(_knob); (( _k5 > 0 )) && check "the knob is on the track, not at the end" 1 1 \
                            || check "the knob is on the track, not at the end" 0 1

note "lowering max UNDER the value brings the value down with it"
ft-modify sl max=4
_agree "max=4 pulls value to 4" "4"
_k4=$(_knob)
(( _k4 > _k5 )) && check "…and the knob moved right, to the new end" 1 1 \
                || check "…and the knob moved right, to the new end ($_k5 → $_k4)" 0 1
ft-modify sl max=10 value=5

note "raising min OVER the value pushes the value up"
ft-modify sl min=8 max=20
_agree "min=8 pushes value to 8" "8"
check "…and the knob is at the low end now" "$(_knob)" "0"

note "writing the value out of range clamps it — el.value = 500 with max=10 gives 10"
ft-modify sl min=0 max=10 step=1 value=5
ft-modify sl value=500
_agree "above max" "10"
ft-modify sl value=-7
_agree "below min" "0"

note "step alignment: the step base is MIN, and ties round up"
ft-modify sl min=0 max=10 step=5 value=0
ft-modify sl value=7
_agree "7 with step 5 → 5" "5"
ft-modify sl value=8
_agree "8 with step 5 → 10" "10"
ft-modify sl value=2                                    # 2 and 3 are the tie neighbours of 2.5
_agree "2 rounds down" "0"
ft-modify sl value=3
_agree "3 rounds up" "5"
ft-modify sl min=10 max=20 step=4 value=10
ft-modify sl value=19
_agree "the last aligned value below max, not max" "18"

note "the same rule at CONSTRUCTION, where only the DSL route can apply it"
ft-form name=app2 width=70 height=24
    ft-slider name=born value=50 max=10 width=24 showValue=true   # value written BEFORE its max
    ft-slider name=grid min=10 max=20 step=2 value=15 width=24    # off its own grid
end_ft_form
ft_layout app2
check "a value written before its max is still clamped" "$(ft_get born value; printf %s "$FT_RET")" "10"
check "an off-grid starting value snaps"                "$(ft_get grid value; printf %s "$FT_RET")" "16"

note "a max below its min collapses the range onto min, as in HTML"
ft-modify sl min=10 max=20 step=1 value=15
ft-modify sl max=3
_agree "max under min → min wins" "10"

note "a non-numeric value cannot reach (( )) — it becomes the range's midpoint"
# `value` is deliberately absent from _FT_NUMERIC_PROP, so nothing upstream rejects this: the
# string reaches the control. Bash arithmetic EVALUATES ARRAY SUBSCRIPTS, so a `(( v < mn ))`
# anywhere on the value's path runs the command — verified in isolation, the canary does fire.
# THE PAINT BELOW IS THE POINT: it is where the old code did its clamping, so the check has to
# come after a real draw or it passes by never having drawn anything.
ft-modify sl min=0 max=10 step=1 value=5
rm -f /tmp/ft-slider-injection-canary
ft-modify sl value='q[$(touch /tmp/ft-slider-injection-canary)]' 2>/dev/null
_shown >/dev/null
check "the subscript did NOT execute" "$([[ -e /tmp/ft-slider-injection-canary ]] && printf ran || printf no)" "no"
_agree "…and the value is the midpoint" "5"
rm -f /tmp/ft-slider-injection-canary

note "the key route agrees with the property route"
ft-modify sl min=0 max=10 step=3 value=0
ft_focus sl >/dev/null 2>&1
ft_slider_key_max sl;  _agree "End goes to the last aligned value" "9"
ft_slider_key_min sl;  _agree "Home goes to min" "0"
ft_slider_key_inc sl;  _agree "Right steps by one step" "3"
ft_slider_key_biginc sl; _agree "PgUp steps by five, clamped" "9"

note "the mouse route lands on aligned values too — it no longer carries its own copy of the rule"
ft-modify sl min=0 max=10 step=3 value=0
FT_MEASURED_WIDTH[sl]=24
_ft_mouse_slider sl press 9 0
_v=$(_prop); case "$_v" in 0|3|6|9) check "a click lands on the grid" 1 1 ;;
                          *) check "a click lands on the grid ($_v)" 0 1 ;; esac

note "a cancelled on_change restores the value the user was looking at"
ft-modify sl min=0 max=10 step=1 value=5
_veto() { return 1; }
ft-modify sl onChange=_veto
ft_slider_set sl 9
_agree "the refusal put it back" "5"
ft_remove_attribute sl onChange
ft-modify sl eventListeners=""
ft_slider_set sl 9
_agree "…and with the handler gone it moves" "9"

# ─────────────────────────────────────────────────────────────────────────────
#  AN INVALID STEP BROKE THE KEYBOARD, and one reader correcting it is not the same as it being
#  correct. _ft_slider_sanitize floored the step at 1 for its own arithmetic; _ft_slider_by —
#  the arrow keys — read the raw property. Measured on min=0 max=10 value=5:
#
#      step=0    RIGHT 5→5, LEFT 5→5    the keyboard could not move the slider AT ALL,
#                                        while the mouse still could
#      step=-1   RIGHT 5→4, LEFT 5→6    INVERTED: the key captioned "Decrease" raised it
#
#  HTML: an invalid step is ignored and the step is the default 1.
# ─────────────────────────────────────────────────────────────────────────────
note "an invalid step is ignored, and the arrows keep meaning what their captions say"
ft-modify sl min=0 max=10 step=2 value=5
ft_focus sl >/dev/null 2>&1
_step_of() { ft_get sl step; printf '%s' "$FT_RET"; }
_arrows() {                     # → "right,left" from value 5
    ft-modify sl value=5; ft_slider_key_inc sl >/dev/null 2>&1
    local r; r=$(ft_get sl value; printf %s "$FT_RET")
    ft-modify sl value=5; ft_slider_key_dec sl >/dev/null 2>&1
    printf '%s,%s' "$r" "$(ft_get sl value; printf %s "$FT_RET")"
}
# POSITIVE CONTROL first — a probe that reports "inert" for everything proves nothing.
# NB the helper writes 5 each time and 5 is OFF the step-2 grid (base = min = 0), so the write
# itself sanitizes to 6 before either arrow runs. That is the rule this file already pins above;
# the expectation is 8,4 rather than 7,3 because of it, and getting that wrong the first time is
# exactly what a positive control is for.
check "step=2 moves by two from where 5 lands" "$(_arrows)" "8,4"
ft-modify sl step=1
check "step=1 moves by one"                   "$(_arrows)" "6,4"
for _bad in 0 -1 -3; do
    ft-modify sl step=$_bad
    check "step=$_bad is ignored, and reads back 1" "$(_step_of)" "1"
    check "…and the arrows still move by one"       "$(_arrows)" "6,4"
done
# …and the step survives being removed: the prototype default is 1.
ft-modify sl step=4
check "a valid step is kept"                  "$(_step_of)" "4"
ft_remove_attribute sl step
check "removing it falls back to the default" "$(_step_of)" "1"
check "…and the arrows follow"                "$(_arrows)" "6,4"

# ─────────────────────────────────────────────────────────────────────────────
#  A SLIDER WITH NO value= HAD THREE ANSWERS TO ONE QUESTION. Measured on
#  `ft-slider name=s min=10 max=20`: the PAINT drew 10 (its draw falls back to min), `ft_get s
#  value` answered the EMPTY STRING, and _ft_slider_sanitize answered 15. HTML's range input
#  defaults to the midpoint of its range, and this control's own sanitizer already implements
#  exactly that for an unparseable value — it was answering it for nobody.
# ─────────────────────────────────────────────────────────────────────────────
note "a slider built without a value has one anyway, and everything agrees about it"
ft-form name=app3 width=70 height=24 display=flex flexDirection=column
    ft-slider name=bare  min=10 max=20 width=24 showValue=true
    ft-slider name=plain width=24 showValue=true                # no min or max either
end_ft_form
ft_layout app3
check "min=10 max=20 → the midpoint"        "$(ft_get bare value; printf %s "${FT_RET:-<unset>}")" "15"
check "…and that is what it PAINTS"         "$(_drawn bare)" "15"
check "…and what its own sanitizer says"    "$(_ft_slider_sanitize bare ""; printf %s "$FT_RET")" "15"
check "a slider with no range either"       "$(ft_get plain value; printf %s "${FT_RET:-<unset>}")" "50"
check "…and it paints that"                 "$(_drawn plain)" "50"
# …and it is a REGISTERED property, so a state save carries it like any other.
case " ${FT_PROPS[bare]} " in *" value "*) check "the value is registered" 1 1 ;;
                             *) check "the value is registered" 0 1 ;; esac
# The keys work from it immediately — a valueless slider used to start from an empty string.
ft_focus bare >/dev/null 2>&1
ft_slider_key_inc bare
check "and an arrow moves it from there"    "$(ft_get bare value; printf %s "$FT_RET")" "16"

note "the readout is as wide as the widest value the RANGE can produce, not four columns"
# showValue reserved a hardcoded 4 — one space plus three digits, exactly right for the default
# 0..100 and one column short of max=2000, whose four-digit readout painted past the right edge
# of the box and over whatever was beside it. Three copies of `cols - 4` said so: the draw, the
# mouse and the preferred width.
ft-form name=app4 width=70 height=24 display=flex flexDirection=column
    ft-slider name=wSmall min=0     max=10   value=7      width=24 showValue=true
    ft-slider name=wBig   min=0     max=2000 value=1500   width=24 showValue=true
    ft-slider name=wNeg   min=-1000 max=0    value=-750   width=24 showValue=true
    ft-slider name=wAuto  min=0     max=2000 value=1500            showValue=true
    ft-slider name=wNone  min=0     max=2000 value=1500            showValue=false
end_ft_form
ft_layout app4
_painted_cols() {               # name → FT_RET = the display width of the row it painted
    FT_OUT=""; ft_dirty "$1"; ft_draw_one "$1" >/dev/null 2>&1
    local p=$FT_OUT; FT_OUT=""
    p=$(printf '%s' "$p" | sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g' | tr -d '\n')
    ft_display_width "$p"; FT_RET=$FT_DISPLAY_WIDTH
}
for _s in wSmall wBig wNeg; do
    _painted_cols "$_s"
    check "$_s paints inside its own 24 columns" "$(( FT_RET <= 24 ))" "1"
done
# …and the number itself is still all there — a track one column shorter, not a clipped value.
check "…and the four-digit value is drawn whole"  "$(_drawn wBig)" "1500"
check "…and a negative one too"                   "$(_drawn wNeg)" "-750"
# The INTRINSIC width grows with the readout, so an auto-sized slider is not one column short.
# (Asked of the width function, because a flex column stretches both of these to the container.)
_ft_preferred_width_slider wNone; _pwNone=$FT_RET
_ft_preferred_width_slider wAuto; _pwAuto=$FT_RET
_ft_preferred_width_slider wSmall; _pwSmall=$FT_RET
check "no readout: twenty columns of rail"          "$_pwNone"  "20"
check "0..10 reserves three (a space and two digits)" "$_pwSmall" "23"
check "0..2000 reserves five, not four"             "$_pwAuto"  "25"
# showValue, min and max all decide that width, so none of them is paint-only.
ft_prop_kind showValue; check "showValue -> layout" "$FT_RET" "layout"
ft_prop_kind min;       check "min -> layout"       "$FT_RET" "layout"
ft_prop_kind max;       check "max -> layout"       "$FT_RET" "layout"

summary
