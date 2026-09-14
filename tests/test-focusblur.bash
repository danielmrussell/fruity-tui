#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  LEAVING A CONTROL ENDS ITS ACTIVATION — on EVERY route that leaves it.
#
#  _ft_focus_blur's own comment says so "for EVERY class": a field must drop back to idle so
#  Tabbing in later does not land you mid-edit. ft_focus_move runs it, and _ft_focus_set_try
#  runs it — but ft_focus_first landed ring[0] without it, and so did ft_focus_ring_build when
#  an autofocus= control steals focus from a live FT_FOCUS. The abandoned control kept its
#  engaged rung: it still matched :engaged, still drew its edit border, and Tabbing back landed
#  mid-edit with the arrows silently meaning something else.
#
#  Both routes are hot — ft-settings and ft-menu call ft_focus_first when they open, and the
#  refresh path rebuilds the ring. The GAIN half of this contract was fixed on these very paths
#  once; the blur half was left asymmetric. "Same predicate, every path."
#
#  NB the delve is driven with ft_key_delve, which is what the Enter binding calls. A textfield
#  ladder is `unfocused poised scrolling perusing editing` and focus alone leaves it at
#  `poised`; ft_dispatch_event Enter does not climb it, so a test written that way never gets
#  the control engaged and passes against the broken engine.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
cd "$here"
export FT_NO_WTFIX=1
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_USE_UTF8=1; FT_COLOR_MODE=256
FT_COLS=60; FT_ROWS=16

engaged_of() { if ft_runlevel_engaged "$1"; then FT_RET=yes; else FT_RET=no; fi; }
delve_to_editing() {            # climb the ladder the way Enter does
    local n=$1 i
    ft_focus "$n"
    for i in 1 2 3; do ft_key_delve "$n" Enter >/dev/null 2>&1; done
}

note "the sibling routes already blur — the baseline this one must match"
ft-form name=app width="$FT_COLS" height="$FT_ROWS"
    ft-textfield name=tfA width=20 value="alpha"
    ft-textfield name=tfB width=20 value="bravo"
end_ft_form
FT_ROOT=app; ft_layout app

delve_to_editing tfB
ft_runlevel tfB; check "tfB is editing" "$FT_RET" editing
ft_focus_move 1
engaged_of tfB; check "ft_focus_move left it disengaged" "$FT_RET" no

note "ft_focus_first must do the same"
delve_to_editing tfB
ft_runlevel tfB; check "tfB is editing again" "$FT_RET" editing
ft_focus_first
check "focus moved to the first control" "$FT_FOCUS" tfA
engaged_of tfB; check "ft_focus_first left tfB disengaged" "$FT_RET" no
ft_runlevel tfB; note "  tfB's rung after the move: $FT_RET"

note "…so that Tabbing back does not land you mid-edit"
ft_focus_move 1
check "Tab lands back on tfB" "$FT_FOCUS" tfB
engaged_of tfB; check "and it is not mid-edit" "$FT_RET" no

note "an autofocus= control stealing focus must blur what it stole from"
ft-form name=app2 width="$FT_COLS" height="$FT_ROWS"
    ft-textfield name=tfC width=20 value="charlie"
    ft-textfield name=tfD width=20 value="delta" autofocus=true
end_ft_form
FT_ROOT=app2; ft_layout app2

delve_to_editing tfC
ft_runlevel tfC; check "tfC is editing" "$FT_RET" editing
ft_focus_ring_build app2                          # autofocus steals to tfD
check "autofocus took the focus" "$FT_FOCUS" tfD
engaged_of tfC; check "the stolen-from control is disengaged" "$FT_RET" no

note "blurring must not fire when focus does not actually move"
delve_to_editing tfD
ft_runlevel tfD; check "tfD is editing" "$FT_RET" editing
ft_focus_ring_build app2                          # the autofocus target IS the current focus
check "focus stayed on tfD" "$FT_FOCUS" tfD
ft_runlevel tfD; check "…and its rung was left alone" "$FT_RET" editing

summary
