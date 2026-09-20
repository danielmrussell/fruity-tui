#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  REMOVING A PROPERTY IS SETTING IT — the same repaint is owed.
#
#  ft-modify learned this: it acts on the property's KIND. A layout property reflows, a paint
#  property dirties, an INHERITED one dirties the subtree that inherits it, and hiding a
#  control repairs the cells it had and re-checks focus. ft_remove_attribute — its sibling
#  route, and the DOM's removeAttribute — did none of it: it unset the variable, invalidated
#  the cascade, and marked the control itself dirty. Nothing else.
#
#  So `ft_remove_attribute lab width` left the old geometry until something else forced a
#  reflow, and `ft_remove_attribute panel color` repainted the panel but not the labels that
#  inherit from it.
#
#  "Same predicate, every route" — the fix landed on one and not its twin.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
cd "$here"
export FT_NO_WTFIX=1
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_USE_UTF8=1
FT_COLS=60; FT_ROWS=16

note "a LAYOUT property: removing it must reflow"
ft-form name=app width="$FT_COLS" height="$FT_ROWS"
    ft-div name=box
        ft-label name=lab text="hello"
    end_ft_div
end_ft_form
FT_ROOT=app; ft_layout app
ft-modify lab width=30
ft_reflow_flush
check "the explicit width took" "${FT_MEASURED_WIDTH[lab]}" 30
ft_remove_attribute lab width
ft_reflow_flush
note "  measured width after removing it: ${FT_MEASURED_WIDTH[lab]}"
check "removing the width re-measured the control" "$(( FT_MEASURED_WIDTH[lab] != 30 ))" 1

note "an INHERITED property: removing it must repaint what inherits it"
ft-form name=app2 width="$FT_COLS" height="$FT_ROWS"
    ft-div name=panel color=201
        ft-label name=inner text="inherits"
    end_ft_div
end_ft_form
FT_ROOT=app2; ft_layout app2
ft_style inner color
check "the child inherits the panel's colour" "$FT_RET" 201
FT_DIRTY=()
ft_remove_attribute panel color
check "the panel itself is dirty"          "${FT_DIRTY[panel]:-0}" 1
check "…and so is the child that inherits" "${FT_DIRTY[inner]:-0}" 1
ft_style inner color
check "and the inherited value really did change" "$FT_RET" ""

note "a paint property that does NOT inherit dirties only its own control"
ft-modify panel backgroundColor=52
FT_DIRTY=()
ft_remove_attribute panel backgroundColor
check "the control is dirty"         "${FT_DIRTY[panel]:-0}" 1
check "…and the child is left alone" "${FT_DIRTY[inner]:-0}" 0

note "removing display=none restores the control, and focus can reach it again"
ft-form name=app3 width="$FT_COLS" height="$FT_ROWS"
    ft-button name=b1 "One"
    ft-button name=b2 "Two"
end_ft_form
FT_ROOT=app3; ft_layout app3
ft_focus b2
ft-modify b2 display=none
check "setting display=none moved focus off it" \
      "$([[ "$FT_FOCUS" != b2 ]] && echo moved || echo stranded)" moved
ft_remove_attribute b2 display
ft_reflow_flush
# _ft_disp, not ft_style: the engine's own "is this drawn?" question. Its answer is the
# PROTOTYPE's display, which for a button is `inline-block` — not the generic `block` this asserted
# while prototype defaults were stamped onto instances. Removing an author's property restores what
# the control IS, and a button is an inline-block; `block` was the old mechanism showing through,
# because ft_remove_attribute deleted the stamped default along with the author's value and left
# _ft_disp on its own hardcoded fallback. Same assertion, correct expectation.
_ft_disp b2
check "removing the property restored it to visible" "$FT_RET" inline-block
check "…and focus may land on it again" \
      "$(_ft_focus_skippable b2 && echo skipped || echo focusable)" focusable

note "a removal bumps the text generation, because a removal IS a write"
# _ft_setprop bumps `_fti_<name>__textgen` on ANY property write, and says why in its own words:
# a control's displayed text is often composed from several of its properties, so over-
# invalidating costs a recompute whereas under-invalidating serves a stale measurement. This
# route did everything else that rule demands — clip, resolve, cascade, repaint-by-kind, the
# focus check, each with a "same predicate, same route" comment — and skipped this one.
#
# The counter is a FAST PATH: callers that pass it instead of the string get an integer compare
# rather than a full compare of a 1000-line log. So a missed bump does not corrupt the callers
# that still pass the text, which is why this was latent rather than visible when it was found.
# It is asserted here because the invariant is what gets relied on, not today's callers.
#
# WATCHED FAILING: before the fix, a write moved the counter 8 → 9 and a removal left it 9 → 9.
_gen_of() { local v="_fti_${1}__textgen"; printf '%s' "${!v:-0}"; }
ft-modify b2 padding=1
_g0=$(_gen_of b2); ft-modify b2 padding=2;        _g1=$(_gen_of b2)
check "a property WRITE bumps the text generation"   "$(( _g1 > _g0 ))" 1
_g2=$(_gen_of b2); ft_remove_attribute b2 padding;  _g3=$(_gen_of b2)
check "…and a property REMOVAL bumps it too"         "$(( _g3 > _g2 ))" 1
# ANTI-VACUITY: if the counter never existed, both comparisons above would read 0 > 0 and fail
# — but a future refactor that removes the counter entirely would make them pass by never
# incrementing anything. Demand it is a real, moving number.
check "…and the generation is a real counter, not a constant" "$(( _g3 > 0 && _g3 > _g0 ))" 1

# ─────────────────────────────────────────────────────────────────────────────
#  AND THE PROTOTYPE RECONCILER — the sixth item on this file's own list.
#
#  `setProp=` (FT_PROTO_SETPROP) is the hook a prototype registers so a property that NAMES its
#  state does the work on every route in, and its whole selling point over FT_PROTO_REPROP is
#  that _ft_setprop is EVERY route. It was not: this one never called it.
#
#  Measured before the fix, on a checked checkbox — `ft_remove_attribute cb selectedIndex`
#  repainted it UNCHECKED while `ft_get cb checked` and `ft_get cb value` both still answered
#  true. That is verbatim the failure the reconciler exists to prevent, reached through the one
#  door the fix left open. A radio was worse: removing `checked` left FT_RADIO_SELECTED naming
#  a radio whose property and paint both denied it.
# ─────────────────────────────────────────────────────────────────────────────
note "removing a property reaches the class reconciler, like every other route in"
ft-form name=app5 width="$FT_COLS" height="$FT_ROWS" display=flex flexDirection=column
    ft-checkbox name=rcb text="Ready"
    ft-radio    name=rr1 text="One" group=rg
    ft-radio    name=rr2 text="Two" group=rg
end_ft_form
FT_ROOT=app5; ft_layout app5
_glyph() {                      # name label — what it paints in front of its label
    FT_OUT=""; ft_dirty "$1"; ft_draw_one "$1" >/dev/null 2>&1
    local p=$FT_OUT; FT_OUT=""
    p=$(printf '%s' "$p" | sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g' | tr -d '\n')
    p=${p%%"$2"*}; printf '%s' "${p% }"
}
_three() { printf '%s,%s,%s' "$(ft_get "$1" checked; printf %s "$FT_RET")" \
                             "$(ft_get "$1" value; printf %s "$FT_RET")" \
                             "$(ft_get "$1" selectedIndex; printf %s "$FT_RET")"; }

ft-modify rcb checked=true
check "the box is checked, and all three names agree" "$(_three rcb)" "true,true,1"
check "…and it paints that way"                       "$(_glyph rcb Ready)" "[x]"
ft_remove_attribute rcb selectedIndex
check "removing the index unchecks it in the PAINT"   "$(_glyph rcb Ready)" "[ ]"
check "…and the other two names followed"             "$(_three rcb)" "false,false,0"

note "…and a radio's group index is not left naming a radio the paint denies"
ft_radio_select rr1
check "rr1 is on"            "$(_glyph rr1 One)" "●"
check "…and the group says so" "$(ft_radio_value rg; printf %s "$FT_RET")" "rr1"
ft_remove_attribute rr1 checked
check "removing checked turns it off in the paint" "$(_glyph rr1 One)" "○"
check "…and the group index agrees"                "$(ft_radio_value rg; printf '[%s]' "$FT_RET")" "[]"

note "a truthy spelling is canonicalised even when the selection does not move"
# ft_radio_select returned before its stamp when prev == name, so `checked=1` on an ALREADY
# selected radio was stored verbatim — and ft_radio_is_selected tests `== true`, so the radio
# painted ○ while the group index still named it. The same write on an UNSELECTED radio worked,
# which is exactly what kept it hidden.
ft_radio_select rr2
check "rr2 is on"                    "$(_glyph rr2 Two)" "●"
ft-modify rr2 checked=1
check "checked=1 is stored as true"  "$(_ft_get_raw rr2 checked; printf %s "$FT_RET")" "true"
check "…it is still selected"        "$(ft_radio_is_selected rr2 && printf yes || printf no)" "yes"
check "…and still paints on"         "$(_glyph rr2 Two)" "●"
check "…with the group agreeing"     "$(ft_radio_value rg; printf %s "$FT_RET")" "rr2"

summary
