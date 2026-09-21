#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  ENTER GOES IN, AND AT THE BOTTOM IT COMES OUT.
#
#  `ft_runlevel_deeper` answers "no" for two different worlds: a button with no rungs at all,
#  and a slider standing on the last rung of its ladder. `ft_key_delve` treated both as "run
#  the control's action", so Enter at the deepest rung was CLAIMED and did nothing — a slider
#  sat at `adjusting` however many times you pressed it, and the key never bubbled to the form
#  either. Reported as "hitting enter on sliders after entering them doesn't exit them".
#
#  Four prototypes reached that dead end: slider, label, table, tabs. Two never do, because they
#  bind ENTER in the deepest rung's own keymap — a tree expands the branch, a multi-line field
#  takes a newline — and Enter there has a real deeper meaning that must be left alone. Those
#  are the companions below, and they are the point: a fix that made Enter leave EVERYWHERE
#  would pass the first half of this file and destroy the second.
#
#  It leaves all the way out, to `poised`, the same landing Esc gives. One rung up is not the
#  alternative — it is a bug that already shipped, and a read-only field ping-ponged
#  `scrolling`↔`perusing` forever on exactly that rule.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=70; FT_ROWS=26

SLIDER_ACTIVATIONS=0
slider_activated() { SLIDER_ACTIVATIONS=$(( SLIDER_ACTIVATIONS + 1 )); }
TREE_ACTIVATIONS=0
tree_activated()   { TREE_ACTIVATIONS=$(( TREE_ACTIVATIONS + 1 )); }

ft-form name=app width=70 height=26
    ft-slider name=sl  min=0 max=10 value=5
    ft-slider name=sla min=0 max=10 value=5 onActivate='slider_activated "$@"'
    ft-label  name=lb  text=$'one\ntwo\nthree\nfour\nfive\nsix' width=12 maxHeight=2
    ft-button name=bt text="Press"
    # A real tree with a branch: Enter INSIDE it toggles that branch, which is the whole point
    # of the companion. An empty ft-tree is also focus-skipped, so the companion would silently
    # not run. (ft-tree opens a scope — end_ft_tree closes it, and leaving it to end_ft_form
    # warns on stderr, which tests/run-all.bash counts as a failure.)
    ft-tree   name=tr  rows=4 onActivate='tree_activated "$@"'
        ft-tree-node text="branch" id=br depth=0 expanded=true
        ft-tree-node text="leaf" id=lf depth=1
    end_ft_tree
end_ft_form
ft_layout app
FT_ROOT=app

_enter()   { ft_dispatch_event ENTER >/dev/null 2>&1; }
_rung()    { ft_get "$1" runlevel; printf '%s' "$FT_RET"; }
_stand_on() {                   # name → 0 if focus really landed there
    ft_focus "$1" >/dev/null 2>&1
    [[ "${FT_FOCUS:-}" == "$1" ]]
}

note "Enter delves in, and at the bottom of the ladder it leaves"
for c in sl lb; do
    if ! _stand_on "$c"; then check "$c: focus landed (else the rest is vacuous)" 0 1; continue; fi
    check "$c: starts poised"                    "$(_rung "$c")" "poised"
    _enter
    deep=$(_rung "$c")
    # A STRING TEST, in [[ ]]. Inside (( )) a bare word is a VARIABLE name, so `"$deep" !=
    # "poised"` compares two undefined variables — 0 != 0 — and reports false however the
    # control behaved. It failed here on a working fix and would just as happily pass on a
    # broken one.
    check "$c: Enter delved in (not still poised)" \
          "$([[ -n "$deep" && "$deep" != poised ]] && echo 1 || echo 0)" 1
    _enter
    check "$c: …and Enter at the bottom leaves"   "$(_rung "$c")" "poised"
    check "$c: …without moving focus"             "${FT_FOCUS:-}" "$c"
    _enter
    check "$c: …and it delves in again, so it is a toggle not a one-way trip" "$(_rung "$c")" "$deep"
    _enter
done

note "…but a control whose Enter has something to DO still does it"
# The bottom rung is the only place a laddered control's onActivate is reachable from the
# keyboard, so making Enter always leave would silently delete that hook.
_stand_on sla || check "sla: focus landed" 0 1
SLIDER_ACTIVATIONS=0
_enter; _enter; _enter
check "a slider with onActivate fires it"        "$(( SLIDER_ACTIVATIONS >= 1 ))" 1
check "…and stays inside rather than leaving"    "$(_rung sla)" "adjusting"

note "…and a control with NO ladder still just activates"
_stand_on bt || check "bt: focus landed" 0 1
_enter
check "a button never moves rung"                "$(_rung bt)" "poised"

note "…and a class that binds ENTER at its deepest rung never reaches the shared rule"
# The tree expands a branch with Enter. If it started leaving instead, this is what would say
# so — and without it the assertions above are satisfied by "Enter always leaves".
if _stand_on tr; then
    _enter
    tr_deep=$(_rung tr)
    check "tr: Enter delved in" \
          "$([[ -n "$tr_deep" && "$tr_deep" != poised ]] && echo 1 || echo 0)" 1
    _enter
    check "tr: …and Enter INSIDE the tree does not leave it" "$(_rung tr)" "$tr_deep"
else
    note "  (an empty tree is focus-skipped; companion not run — see the note in the file)"
fi

note "…and the legend says what Enter will actually do"
# The prototype keymap's ENTER label describes going IN ("Adjust", "Scroll"), which is right at
# every rung but the last. An unchanged legend at the bottom names a key and lies about it.
_enter_cap() {                  # control → the ENTER label the legend would derive
    ft_focus "$1" >/dev/null 2>&1
    _ft_legend_caps
    local c
    for c in "${FT_CAPS[@]}"; do
        [[ "$c" == *$'\t'ENTER$'\t'* ]] && { printf '%s' "${c##*$'\t'}"; return; }
    done
    printf '<none>'
}
_stand_on sl || check "sl: focus landed" 0 1
ft_set sl runlevel=poised
check "at poised the legend says what going IN does"  "$(_enter_cap sl)" "Adjust"
ft_set sl runlevel=adjusting
check "at the bottom rung it says Leave"              "$(_enter_cap sl)" "Leave"
ft_set sl runlevel=poised

# THE COMPANION THAT MATTERS: the legend must compute the SAME predicate dispatch does, not
# merely "am I engaged". A slider with an onActivate does NOT leave on Enter, so its legend
# must still advertise the action — otherwise this rule is a second, drifting copy.
_stand_on sla || check "sla: focus landed" 0 1
ft_set sla runlevel=adjusting
check "…but a control whose Enter still acts keeps its own label" "$(_enter_cap sla)" "Adjust"
ft_set sla runlevel=poised

summary
