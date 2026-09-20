#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Integration test for demo/css-demo.bash — the ten-page CSS tour.
#
#  It sources the REAL demo with its run-loop stripped, then drives the actual
#  page-builder and the actual control hooks and asserts that the specimen text
#  box `spec` restyles the way each page teaches. So this is a genuine end-to-end
#  check of the CSS engine THROUGH the demo: inheritance, selectors, specificity,
#  states, custom properties, colour formats, pseudo-elements, animation, and
#  combinators — every page's concept, exercised the way a user would.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"

# Source the demo minus its blocking `ft-run` line (kept inside the tree so the
# demo's `here=…/..` resolves to the project root and finds fruity-tui.bash).
export FT_NO_WTFIX=1
noloop="$here/demo/.css-demo-noloop.bash"
sed '/^ft-run app/d' "$here/demo/css-demo.bash" > "$noloop"
trap 'rm -f "$noloop"' EXIT
source "$noloop"
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_ROWS=34; FT_COLS=120
# THE DEMO BUILDS ITS FORM AT THE TERMINAL'S SIZE, measured when it is sourced (ft_term_size), and
# assigning FT_ROWS/FT_COLS afterwards does not resize a form that already exists. So this file
# tested whatever size its terminal happened to be: green from a wide window, red with no terminal
# at all, where the fallback is 80x24 and page 1's text box is squeezed to one row — too short for
# its border, so it painted nothing. The demo's own resize handler makes the size the test's.
_resize >/dev/null 2>&1

note "Page 1 — inheritance: the text box inherits its container's colour"
PAGE=1; _show_page >/dev/null 2>&1
settle >/dev/null 2>&1   # ft-run settles the burst; a gate must too
ft_style spec color; check "spec has no colour of its own → inherits crimson" "$FT_RET" crimson
inhColor_on_change 46
ft_style spec color; check "change the parent → spec re-inherits (46)" "$FT_RET" 46

note "Page 2 — selectors: the specimen's class picks which rule matches"
PAGE=2; _show_page >/dev/null 2>&1
settle >/dev/null 2>&1   # ft-run settles the burst; a gate must too
selClass_on_change warning; ft_style spec color; check ".warning matches → crimson" "$FT_RET" crimson
selClass_on_change ok;      ft_style spec color; check ".ok matches → rgb green"   "$FT_RET" "rgb(64, 200, 90)"
selClass_on_change none;    ft_style spec color; check "no class → no rule matches" "$FT_RET" ""

note "Page 3 — specificity: the most specific match wins, whatever the toggle order"
PAGE=3; SP_TYPE=on; SP_CLASS=off; SP_ID=off; _show_page >/dev/null 2>&1
settle >/dev/null 2>&1   # ft-run settles the burst; a gate must too
ft_style spec color; check "type only → 33" "$FT_RET" 33
spClass_on_activate; ft_style spec color; check "type + class → class (100) wins → 202" "$FT_RET" 202
spId_on_activate;    ft_style spec color; check "type + class + id → id (10000) wins → 201" "$FT_RET" 201
spId_on_deactivate;  ft_style spec color; check "drop the id rule → class wins again → 202" "$FT_RET" 202

note "Page 4 — states: disabling the box makes textfield:disabled match; focus makes :focus match"
PAGE=4; ST_DISABLED=off; _show_page >/dev/null 2>&1
settle >/dev/null 2>&1   # ft-run settles the burst; a gate must too
stDisabled_on_activate
_ft_get_raw spec disabled; check "the checkbox disables the box" "$FT_RET" true
ft_style spec color;       check "textfield:disabled → 244" "$FT_RET" 244
FT_FOCUS=spec; ft_style spec borderColor; check "textfield:focus → dodgerblue border" "$FT_RET" dodgerblue
FT_FOCUS=""

note "Page 5 — custom properties: --accent drives the colour through var()"
PAGE=5; _show_page >/dev/null 2>&1
settle >/dev/null 2>&1   # ft-run settles the burst; a gate must too
varPick_on_change 201; ft_style spec color; check "var(--accent) follows the chosen value (201)" "$FT_RET" 201

note "Page 6 — colour formats: name / #hex / rgb() / hsl() all resolve to the SAME crimson"
PAGE=6; _show_page >/dev/null 2>&1
settle >/dev/null 2>&1   # ft-run settles the burst; a gate must too
_is_crimson(){ _ft_compose_sgr spec "$FT_COLOR_INPUT"; case "$FT_RET" in *"38;5;161"*) echo crimson ;; *) echo other ;; esac; }
cfFmt_on_change "crimson";          check "crimson (name)"      "$(_is_crimson)" crimson
cfFmt_on_change "#dc143c";          check "#dc143c (hex)"       "$(_is_crimson)" crimson
cfFmt_on_change "rgb(220,20,60)";   check "rgb(220,20,60)"      "$(_is_crimson)" crimson
cfFmt_on_change "hsl(348,83%,47%)"; check "hsl(348,83%,47%)"    "$(_is_crimson)" crimson

note "Page 7 — pseudo-elements: a ::structure rule targets one part of the box"
PAGE=7; STRUCT=border; _show_page >/dev/null 2>&1
settle >/dev/null 2>&1   # ft-run settles the burst; a gate must too
_ft_css_query_pe spec border borderColor; check "::border { border-color: magenta }" "$FT_RET" magenta
structPick_on_change caret
# EVERY pseudo-element on this page is tinted the SAME demo colour — the page teaches "here is
# the structure you just targeted", and a different colour per structure reads as if the colour
# were the lesson. ::caret was the one odd rule (a bright green 46) among four magentas.
_ft_css_query_pe spec caret backgroundColor; check "switch to ::caret { background-color: magenta }" "$FT_RET" magenta

note "Page 8 — animation: a @keyframes runs live on the specimen; none stops it"
PAGE=8; AN_NAME=glow; AN_DUR=2; _show_page >/dev/null 2>&1
settle >/dev/null 2>&1   # ft-run settles the burst; a gate must too
ft_style spec animation; check "animation resolves to 'glow 2s'" "$FT_RET" "glow 2s"
unset "FT_ANIM_PHASE[spec]" 2>/dev/null; FT_ANIM_PHASE[spec]=0
if _ft_css_anim_fg spec; then check "glow is actually animating spec" running running
else check "glow is actually animating spec" stopped running; fi
animPick_on_change none; ft_style spec animation; check "animation: none is an explicit off-switch" "$FT_RET" "none 2s"

note "Page 9 — combinators: a .card ancestor makes the descendant rule match — and PROVES it by a second box that never does"
PAGE=9; CB_NEST=off; _show_page >/dev/null 2>&1
settle >/dev/null 2>&1   # ft-run settles the burst; a gate must too
cbNest_on_activate
ft_style spec    color; check "the box INSIDE .card matches → gold"                 "$FT_RET" gold
ft_style specOut color; check "the box OUTSIDE .card is UNaffected (combinator proof)" "$([[ "$FT_RET" == gold ]] && echo gold || echo other)" other
cbNest_on_deactivate; ft_style spec color; check "remove the card → not even the inside box matches" "$([[ "$FT_RET" == gold ]] && echo gold || echo other)" other

note "Page 2 — the demo now shows the BASH that drives the class change, beside the CSS"
PAGE=2; _show_page >/dev/null 2>&1
settle >/dev/null 2>&1   # ft-run settles the burst; a gate must too
[[ -n "${FT_TYPE[bash]:-}" ]] && check "a second 'bash' code panel exists" 1 1 || check "a second 'bash' code panel exists" 0 1
ft_resolved_prop bash value ""; case "$FT_RET" in *"ft-modify spec class="*) check "it shows the ft-modify class call" 1 1 ;; *) check "it shows the ft-modify class call" 0 1 ;; esac

note "Page 10 — themes: swapping the theme re-derives the whole palette"
PAGE=10; _show_page >/dev/null 2>&1
settle >/dev/null 2>&1   # ft-run settles the burst; a gate must too
themePick_on_change light; check "ft_use_theme ft-light is now active" "$FT_ACTIVE_THEME" ft-light
themePick_on_change ocean; check "ft_use_theme ft-ocean is now active" "$FT_ACTIVE_THEME" ft-ocean
themePick_on_change dark;  check "…and back to ft-dark"                 "$FT_ACTIVE_THEME" ft-dark

note "the dropdown navigation the demo relies on: closed arrows move focus, Enter opens"
PAGE=1; _show_page >/dev/null 2>&1
settle >/dev/null 2>&1   # ft-run settles the burst; a gate must too
FT_KEY_BUBBLE=0; ft_select_key_down inhColor
check "Down on the CLOSED colour dropdown does not open it" "$(ft_resolved_prop inhColor open false; echo "$FT_RET")" false
check "…it declines so focus can move on"                    "$FT_KEY_BUBBLE" 1
ft_select_key_commit inhColor
check "Enter opens it"                                       "$(ft_resolved_prop inhColor open false; echo "$FT_RET")" true

note "TWO orthogonal axes — ◀▶ step WITHIN a page (btnStepNext/Prev); Okay/Back move PAGES"
PAGE=1; STEP=1; _page_annotations; n1=${#PA_TARGET[@]}
btnStepNext_on_activate; check "▶ advances the step, same page" "$PAGE/$STEP" "1/2"
STEP=$n1; btnStepNext_on_activate; check "▶ at the last step does NOT change page" "$PAGE/$STEP" "1/$n1"
btnStepPrev_on_activate; check "◀ steps back within the page" "$PAGE/$STEP" "1/$((n1-1))"
STEP=2; btnOk_on_activate; check "Okay jumps to the next PAGE at step 1" "$PAGE/$STEP" "2/1"
btnBack_on_activate; check "Back returns to the previous PAGE at step 1" "$PAGE/$STEP" "1/1"

note "each step raises a CALLOUT that points at its control and carries the instruction"
PAGE=1; STEP=2; _show_page >/dev/null 2>&1
settle >/dev/null 2>&1   # ft-run settles the burst; a gate must too
check "the step callout is a callout beacon" "${FT_TYPE[stepcallout]:-}" beacon
ft_resolved_prop stepcallout variant ""; check "…of variant callout" "$FT_RET" callout
ft_resolved_prop stepcallout target "";  check "…pointing at step 2's control (#spec)" "$FT_RET" spec
ft_resolved_prop stepcallout text "";    case "$FT_RET" in *"INHERITS"*) check "…with the step's instruction text" 1 1 ;; *) check "…with the step's instruction text" 0 1 ;; esac

note "…and the taught colour REACHES THE SCREEN, not just the cascade"
# Everything above asks ft_style what a property RESOLVES to. That is the cascade's answer, not
# the demo's picture, and this file called itself "a genuine end-to-end check … exercised the way
# a user would" while never once looking at a rendered frame. Found by a mutation sweep,
# 2026-08-30: with ft_draw_one returning without drawing, AND with the whole layout pipeline
# stubbed so every control measured 0x0, this file still scored 42/42. The demo could paint
# nothing at all, or paint it the wrong colour, and every verdict above would still be green.
#
# So one page is carried the rest of the way: page 1 teaches INHERITANCE, its parent declares
# crimson, and crimson is FT_CSS_HEX #dc143c — a real colour, not a palette index (see the
# colour-names ruling). The bytes the specimen actually paints must carry it.
# Asserted WITHOUT naming a colour or an escape sequence: change what page 1's container teaches,
# and require the specimen's painted bytes to follow. That is the end-to-end claim itself — the
# cascade's answer reaches the screen — and it needs no knowledge of how a colour is encoded, so
# it survives a palette change and still fails a wrong one.
PAGE=1; STEP=1; _show_page >/dev/null 2>&1
settle >/dev/null 2>&1
inhColor_on_change 46;  settle >/dev/null 2>&1
ft_style spec color;    _resolved_a=$FT_RET
FT_OUT=""; ft_draw_one spec >/dev/null 2>&1; _paint_a=$FT_OUT
inhColor_on_change 201; settle >/dev/null 2>&1
ft_style spec color;    _resolved_b=$FT_RET
FT_OUT=""; ft_draw_one spec >/dev/null 2>&1; _paint_b=$FT_OUT

check "the cascade reports the two taught colours"  "$_resolved_a/$_resolved_b" "46/201"
# WHEN THIS FAILS, IT MUST SAY WHY. These three verdicts have been reported failing twice inside a
# full 89-file run while passing every time solo and under run-all's own invocation, and I could
# not reproduce them deliberately — I checked the obvious mechanism (ft_draw_one returns without
# painting while a transition is active, ft-forms.bash:4077) and REFUTED it: no transition is armed
# here and the specimen paints 643 bytes. So rather than guess at a fix, the failure now carries
# its own diagnosis. Every reason ft_draw_one can decline to paint is asked directly, so the next
# occurrence names the cause instead of leaving the next reader where I am now.
_diag_paint() {                 # why is the specimen not painting?
    printf '         does spec exist?        %s\n' "${FT_TYPE[spec]:-<NO SUCH CONTROL>}"
    _ft_disp spec 2>/dev/null;  printf '         its display resolves to: %s\n' "${FT_RET:-<empty>}"
    printf '         a transition active?    %s\n' "${_FT_TRANSITION_ACTIVE[spec]:-no}"
    printf '         geometry:               %sx%s at (%s,%s)\n' \
        "${FT_MEASURED_WIDTH[spec]:-?}" "${FT_MEASURED_HEIGHT[spec]:-?}" \
        "${FT_ABSOLUTE_Y[spec]:-?}" "${FT_ABSOLUTE_X[spec]:-?}"
    # The clip rect is FT_CLIP_R0/C0/R1/C1 — rows and columns, not T/L/B/R. A control clipped to
    # nothing paints nothing, and that is the one cause this diagnosis exists to distinguish from
    # "the draw declined for another reason".
    _ft_clip_for spec 2>/dev/null
    printf '         clip rows %s..%s cols %s..%s\n' \
        "${FT_CLIP_R0:-?}" "${FT_CLIP_R1:-?}" "${FT_CLIP_C0:-?}" "${FT_CLIP_C1:-?}"
}
# ANTI-VACUITY: two empty frames compare equal-and-different from nothing. If the specimen paints
# nothing, the comparison below means nothing — which is exactly how this file scored 42/42 with
# the renderer stubbed.
if (( ${#_paint_a} > 0 && ${#_paint_b} > 0 )); then
    check "the specimen paints something at all" 1 1
else
    check "the specimen paints something at all" 0 1
    printf '         first paint %s bytes, second %s bytes\n' "${#_paint_a}" "${#_paint_b}"
    _diag_paint
fi
if [[ "$_paint_a" == "$_paint_b" ]]; then
    check "…and re-teaching the colour CHANGES the painted bytes" unchanged changed
    printf '         both paints were identical (%s bytes)\n' "${#_paint_a}"
    _diag_paint
else
    check "…and re-teaching the colour CHANGES the painted bytes" changed changed
fi
inhColor_on_change 46; settle >/dev/null 2>&1     # leave the demo as this file found it

summary
