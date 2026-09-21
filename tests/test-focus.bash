#!/usr/bin/env bash
# Unit tests for focus: the ring is the form's focusable controls in
# DECLARATION order (HTML tab order without tabindex), assembled by
# end_ft_form. Focus persists across a rebuild because names are STABLE like
# CSS ids — the same name in the new ring stays focused; a vanished name
# falls back to the first entry. display=none controls are skipped.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init

note "the ring assembles in declaration order at end_ft_form"
ft-form name=app width=40 height=20
    ft-div name=grp
        ft-scrollbar name=sb width=1 height=4
        ft-button name=btnGrow text=" Grow "
    end_ft_div
    ft-button name=btnOk   text=" OK "
    ft-button name=btnQuit text=" Quit "
    ft-label  name=lbl text="fits, so focus skips it"
end_ft_form
ft_layout app     # labels' focusability depends on real geometry (scrollable?)
check "order = declaration, across nesting" "${FT_FOCUS_RING[*]}" "sb btnGrow btnOk btnQuit lbl"
check "first focusable gets initial focus" "$FT_FOCUS" "sb"

note "ft_focus_move wraps and SKIPS the unscrollable label"
ft_focus_move 1;  check "forward"  "$FT_FOCUS" "btnGrow"
ft_focus_move -1; ft_focus_move -1
check "backward wraps past the label to the end" "$FT_FOCUS" "btnQuit"

note "ft_focus jumps to a named control; unknown names fail cleanly"
ft_focus btnOk
check "jumped" "$FT_FOCUS" "btnOk"
ft_focus nosuch && r=0 || r=1
check "unknown name returns 1"        "$r" "1"
check "failed set left focus alone"   "$FT_FOCUS" "btnOk"

note "THE bug this design fixes: focus survives a rebuild by NAME"
ft_focus btnGrow
# rebuild: destroy the old subtree, register the SAME names again
old="${FT_KIDS[app]}"
FT_KIDS[app]=""
for k in $old; do ft_remove "$k"; done
FT_NEST_STACK=(app)
ft-div name=grp
    ft-scrollbar name=sb width=1 height=4
    ft-button name=btnGrow text=" Grow "
end_ft_div
ft-button name=btnOk text=" OK "
ft_end form >/dev/null 2>&1   # pop app + fire the form hook
check "same name → still focused after the rebuild" "$FT_FOCUS" "btnGrow"

note "a vanished name falls back to the first focusable"
old="${FT_KIDS[app]}"
FT_KIDS[app]=""
for k in $old; do ft_remove "$k"; done
FT_NEST_STACK=(app)
ft-button name=btnNew text=" New "
ft-button name=btnEnd text=" End "
ft_end form >/dev/null 2>&1
check "fell back to the first entry" "$FT_FOCUS" "btnNew"

note "display=none controls are skipped when moving focus"
ft_set btnEnd display=none
ft_focus btnNew
ft_focus_move 1
check "skipped the hidden control (wrapped around)" "$FT_FOCUS" "btnNew"
ft_set btnEnd display=inline-block
ft_focus_move 1
check "visible again → reachable again" "$FT_FOCUS" "btnEnd"

note "autofocus=true wins the initial focus over name-persistence"
ft-form name=af width=40 height=10
    ft-button name=afA text=A
    ft-button name=afB text=B autofocus=true
    ft-button name=afC text=C
end_ft_form
check "autofocus control gets initial focus" "$FT_FOCUS" "afB"

note "ft_focus_first jumps to the first focusable, ignoring persistence"
ft_focus afC
ft_focus_first
check "focus_first -> first control" "$FT_FOCUS" "afA"

note "disabling the FOCUSED control moves focus off it (not stranded)"
ft_focus afB
ft_set afB disabled=true          # focused control becomes unfocusable
check "focus left the now-disabled control" "$([[ "$FT_FOCUS" != afB ]] && echo moved)" "moved"
check "focus landed on a focusable neighbour" "$(_ft_focus_skippable "$FT_FOCUS" && echo bad || echo ok)" "ok"
note "hiding the focused control also moves focus"
ft_set afB disabled=false
ft_focus afC
ft_set afC visibility=hidden
check "focus left the hidden control" "$([[ "$FT_FOCUS" != afC ]] && echo moved)" "moved"


# ── The focus scope ─────────────────────────────────────────────────────────
# A FOCUS SCOPE owns a ring: the controls Tab walks between, and the letters an accessKey is
# scoped to. It used to be "the nearest FORM", which made a form three things at once — the
# root of an app, the owner of the ring, and a group of fields — and GROUPING TWO FIELDS
# TOGETHER REMOVED THEM FROM THE KEYBOARD: the ring walk refused to descend into a nested form,
# and that form's own end_ft_form then rebuilt the one global ring out of just its own fields.
note "a form inside a form is a GROUP: its fields stay on the keyboard"
ft-form name=nf width=40 height=10
    ft-button name=nf_a text="A"
    ft-form name=nf_group
        ft-button name=nf_b text="B"
        ft-button name=nf_c text="C"
    end_ft_form
    ft-button name=nf_d text="D"
end_ft_form
ft_layout nf; FT_ROOT=nf
check "every field is in the one ring"  "${FT_FOCUS_RING[*]}" "nf_a nf_b nf_c nf_d"
check "…and the outer form still owns it" "$(_ft_focus_scope_of nf_b; printf '%s' "$FT_RET")" "nf"
check "…and the group owns nothing"       "$(_ft_is_focus_scope nf_group && echo scope || echo group)" "group"
_seq=""; ft_focus nf_a
for _i in 1 2 3 4; do ft_focus_next; _seq+="$FT_FOCUS "; done
check "Tab reaches the grouped fields"  "$_seq" "nf_b nf_c nf_d nf_a "

# Adding a group to an ALREADY-BUILT scope is where the clobber shows: during construction the
# outer end_ft_form rebuilt the ring afterwards and hid it, so the damage only surfaced for an
# app that grouped some fields later — which is exactly when it is hardest to explain.
note "a group added later joins the ring instead of replacing it"
ft-form name=nf_late parent=nf
    ft-button name=nf_e text="E"
    ft-button name=nf_f text="F"
end_ft_form
check "the ring GAINED them"        "${FT_FOCUS_RING[*]}" "nf_a nf_b nf_c nf_d nf_e nf_f"
check "…and focus was not yanked"   "$FT_FOCUS" "nf_a"

# The outermost form is the scope, not every form on the way up — so a control deep inside two
# groups still answers with the one container that owns the ring.
note "the scope is the OUTERMOST form when there is no screen"
check "a doubly-grouped field finds the root" "$(_ft_focus_scope_of nf_c; printf '%s' "$FT_RET")" "nf"
check "the root form IS a scope"              "$(_ft_is_focus_scope nf && echo scope || echo group)" "scope"

summary
