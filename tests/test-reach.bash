#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tests/test-reach.bash — a control the user cannot USE must not be reachable by ANY route.
#
#  There are five ways into a control (Tab, Shift+Tab, its accessKey, a mouse click, and an
#  app calling ft_focus) and three ways to take it out of service (display=none,
#  visibility=hidden, disabled). Every route was checking the state EXCEPT ft_focus, which
#  happily parked focus on a control the Tab ring refuses to visit — despite its own contract
#  line saying "→ 1 if the control can't be focused". Focus then sat on something invisible:
#  the ring painted on nothing, the derived key legend described a control that wasn't there,
#  and Enter activated it.
#
#  Fifteen combinations, so a guard added to one path and not the others cannot hide again.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=80; FT_ROWS=24

FIRED=""
on_first()  { FIRED+="first ";  }
on_off()    { FIRED+="off ";    }
on_gone()   { FIRED+="gone ";   }
on_unseen() { FIRED+="unseen "; }
on_last()   { FIRED+="last ";   }

build() {
    ft-form name=ap width=70 height=12
        ft-button name=first  "First"  accessKey=F onActivate=on_first
        ft-button name=off    "Off"    accessKey=O onActivate=on_off    disabled=true
        ft-button name=gone   "Gone"   accessKey=G onActivate=on_gone   display=none
        ft-button name=unseen "Unseen" accessKey=U onActivate=on_unseen visibility=hidden
        ft-button name=last   "Last"   accessKey=L onActivate=on_last
    end_ft_form
    ft_layout ap; FT_ROOT=ap; ft_focus first
}
build

note "the Tab ring visits only what can be used"
ring=""; ft_focus first
for _ in 1 2 3; do ring+="$FT_FOCUS "; ft_focus_next; done
check "Tab: first ↔ last, nothing else"      "$ring" "first last first "
ring=""; ft_focus last
for _ in 1 2 3; do ring+="$FT_FOCUS "; ft_focus_prev; done
check "Shift+Tab: the same ring backwards"   "$ring" "last first last "

note "an accessKey reaches a usable control and no other"
for c in first:f last:l; do
    FIRED=""; ft_dispatch_event "${c#*:}" >/dev/null 2>&1
    check "${c#*:} activates ${c%%:*}" "$FIRED" "${c%%:*} "
done
for c in off:o gone:g unseen:u; do
    FIRED=""; ft_dispatch_event "${c#*:}" >/dev/null 2>&1
    check "${c#*:} does NOT activate ${c%%:*}" "${FIRED:-none}" "none"
done

note "a mouse click on the cells it occupies"
click() { FT_MOUSE_BUTTON=0; FT_MOUSE_X=$(( $1 + 1 )); FT_MOUSE_Y=$(( $2 + 1 ))
          FT_MOUSE_ACTION=M; _ft_dispatch_mouse >/dev/null 2>&1
          FT_MOUSE_ACTION=m; _ft_dispatch_mouse >/dev/null 2>&1; }
for c in first last; do
    FIRED=""; FT_FOCUS=first
    click "${FT_ABSOLUTE_X[$c]}" "${FT_ABSOLUTE_Y[$c]}"
    check "clicking $c activates it" "$FIRED" "$c "
done
for c in off unseen; do
    FIRED=""; FT_FOCUS=first
    click "${FT_ABSOLUTE_X[$c]}" "${FT_ABSOLUTE_Y[$c]}"
    check "clicking $c does nothing"      "${FIRED:-none}" "none"
    check "…and does not move focus to it" "$FT_FOCUS" "first"
done

note "ft_focus refuses what the ring refuses (its own documented contract)"
for c in off gone unseen; do
    ft_focus first
    no "ft_focus $c returns non-zero" ft_focus "$c"
    check "…and focus stayed put"      "$FT_FOCUS" "first"
done
ft_focus first
ok "ft_focus on a usable control still works" ft_focus last
check "…and it took focus" "$FT_FOCUS" "last"

note "taking the FOCUSED control out of service moves focus off it"
# The realistic path — a wizard step or mode switch hides the control you are standing on.
for how in "display=none" "visibility=hidden" "disabled=true"; do
    ft_remove ap; build
    ft_focus first
    ft-modify first $how
    ft_layout ap
    check "$how while focused → focus moved away" "$FT_FOCUS" "last"
    FIRED=""; ft_dispatch_event ENTER >/dev/null 2>&1
    check "…and Enter no longer reaches it"       "$FIRED" "last "
done

note "a control added AFTER the form was built joins the ring, in its tree position"
# The ring used to be rebuilt from FT_PENDING_FOCUS, which holds only what has been declared
# SINCE the last build and is cleared by it. So an app that added one control at runtime and
# called ft_refresh — the documented way — had its ENTIRE ring replaced by that one control,
# and Tab cycled between it and itself. Building from the tree fixes the order too: a control
# added into a container in the middle lands in the middle, not at the end.
ft_remove ap 2>/dev/null
ft-form name=rt width=70 height=12
    ft-button name=alpha "Alpha" onActivate=on_first
    ft-div    name=slot
    end_ft_div
    ft-button name=omega "Omega" onActivate=on_last
end_ft_form
ft_layout rt; FT_ROOT=rt; ft_focus alpha
check "the ring starts with the declared two" "${FT_FOCUS_RING[*]}" "alpha omega"
ft-button name=middle "Middle" accessKey=M onActivate=on_gone parent=slot
ft_layout rt
ft_refresh >/dev/null 2>&1
check "the new control joined the ring"       "${FT_FOCUS_RING[*]}" "alpha middle omega"
ft_focus alpha
ring=""; for _ in 1 2 3; do ft_focus_next; ring+="$FT_FOCUS "; done
check "…and Tab reaches all three, in order"  "$ring" "middle omega alpha "
FIRED=""; ft_dispatch_event m >/dev/null 2>&1
check "its accessKey works"                   "$FIRED" "gone "
# Removing it again must leave the ring intact rather than emptying it.
ft_remove middle
ft_refresh >/dev/null 2>&1
check "removing it restores the original ring" "${FT_FOCUS_RING[*]}" "alpha omega"

note "NOTHING may write to stderr when handed a control that has been removed"
# THE SIGNATURE FAILURE OF THIS CODEBASE. A control's NAME outlives it — in the focus ring, as
# the mouse-capture target, in a handler that runs after the removal — and the code then asks
# for its TYPE to look up a class table. `${SOME_ASSOC[""]}` is a bash ERROR, printed to
# stderr, which in a TUI is the alt screen the user is looking at; worse, the surrounding
# `[[ -n … ]]` can still take its TRUE branch, so the caller acts on garbage.
# Found four separate sites this way. This drives every entry point that reaches such a
# lookup, so a fifth cannot be added quietly.
_dead_build() {
    ft_remove dap 2>/dev/null
    ft-form name=dap width=70 height=12
        ft-textfield name=ghost size=20 value="x" border=true
        ft-button    name=alive "Keep"
    end_ft_form
    ft_layout dap; FT_ROOT=dap; ft_focus alive
    ft_remove ghost                      # `ghost` is now a name with no type
}
_dead_probe() {                 # label command…
    local label=$1; shift
    _dead_build
    local e; e=$( { "$@"; } 2>&1 >/dev/null )
    check "$label" "${e:-clean}" "clean"
}
_dead_probe "_ft_setprop (a plain property)"  _ft_setprop ghost color 42
_dead_probe "_ft_setprop runlevel"            _ft_setprop ghost runlevel active
_dead_probe "_ft_setprop value"               _ft_setprop ghost value v
_dead_probe "ft-modify"                       ft-modify ghost text=hi
_dead_probe "ft_draw_one"                     ft_draw_one ghost
_dead_probe "_ft_resolve_draw"                _ft_resolve_draw ghost
_dead_probe "ft_dirty"                        ft_dirty ghost
_dead_probe "ft_style"                        ft_style ghost color
_dead_probe "ft_sgr"                          ft_sgr ghost
_dead_probe "ft_resolved_prop"                        ft_resolved_prop ghost color x
_dead_probe "_ft_css_state"                   _ft_css_state ghost focus
_dead_probe "_ft_legend_caps"                 _ft_legend_caps
_dead_probe "_ft_hit_test"                    _ft_hit_test 1 1
_dead_probe "_ft_focus_skippable"             _ft_focus_skippable ghost
_dead_probe "ft_focus"                        ft_focus ghost
_dead_probe "_ft_focus_dirty"                 _ft_focus_dirty ghost
_dead_probe "ft_activate"                     ft_activate ghost
_dead_probe "_ft_mouse_deliver"               _ft_mouse_deliver ghost release 1 1
declare -F _ft_border_sgr >/dev/null && _dead_probe "_ft_border_sgr" _ft_border_sgr ghost
# …while the runlevel check still REJECTS an undeclared level on a LIVE control, which is the
# whole reason that diagnostic exists.
_dead_build
_rl_err=$( { _ft_setprop alive runlevel bogus_level; } 2>&1 >/dev/null )
case "$_rl_err" in *"not declared"*) check "a live control still rejects a bad runlevel" 1 1 ;;
                   *)                check "a live control still rejects a bad runlevel" "${_rl_err:-silent}" "a rejection" ;; esac
ft_remove dap 2>/dev/null

note "a control removed BETWEEN the press and the release"
# A press captures its target by NAME until the release. A row that deletes itself, a button
# that closes its own panel — the control is gone before the release arrives. The capture then
# pointed at a corpse: the release was delivered to it, the next press fought a stale capture,
# and asking for the class mouse handler of a control with no type subscripted an associative
# array with "", which bash reports on stderr — the alt screen.
ft_remove ap 2>/dev/null
ft-form name=mp width=70 height=10
    ft-button name=doomed  "Doomed" onActivate=on_gone
    ft-button name=bystander "Other" onActivate=on_last
end_ft_form
ft_layout mp; FT_ROOT=mp; ft_focus bystander
FT_MOUSE_BUTTON=0; FT_MOUSE_X=$(( ${FT_ABSOLUTE_X[doomed]} + 1 )); FT_MOUSE_Y=$(( ${FT_ABSOLUTE_Y[doomed]} + 1 ))
FT_MOUSE_ACTION=M; _ft_dispatch_mouse >/dev/null 2>&1
check "the press captured it"                 "${_FT_MOUSE_DOWN:-none}" "doomed"
ft_remove doomed
check "removing it releases the capture"      "${_FT_MOUSE_DOWN:-none}" "none"
FIRED=""
_mouse_err=$( { FT_MOUSE_ACTION=m; _ft_dispatch_mouse; } 2>&1 >/dev/null )
check "…and the release says nothing to stderr" "${_mouse_err:-clean}" "clean"
check "…and activates nothing"                "${FIRED:-none}" "none"
# The next press must work normally — no stale capture in the way.
FIRED=""; FT_MOUSE_BUTTON=0
FT_MOUSE_X=$(( ${FT_ABSOLUTE_X[bystander]} + 1 )); FT_MOUSE_Y=$(( ${FT_ABSOLUTE_Y[bystander]} + 1 ))
FT_MOUSE_ACTION=M; _ft_dispatch_mouse >/dev/null 2>&1
FT_MOUSE_ACTION=m; _ft_dispatch_mouse >/dev/null 2>&1
check "the next click still activates"        "$FIRED" "last "
ft_remove mp 2>/dev/null

note "the tree cannot be made to contain a ring"
# Every upward walk (_ft_enclosing_form_of, inheritance, _ft_hidden_anywhere) follows FT_PARENT
# to the root. A ring makes them spin forever — the app HANGS, and _ft_enclosing_form_of runs
# during construction of every focusable control, so it hangs before drawing anything. The DOM
# raises HierarchyRequestError for exactly this; here the reparent is simply refused.
ft_remove ap 2>/dev/null
ft-form name=cy width=70 height=12
    ft-div name=outer
        ft-div name=inner
        end_ft_div
    end_ft_div
end_ft_form
ft_layout cy; FT_ROOT=cy
no "appending an ANCESTOR into its own descendant is refused" ft_append inner outer
check "…and the tree is unchanged"        "${FT_PARENT[outer]:-none}" "cy"
no "a control cannot be appended to itself"                   ft_append outer outer
# The walk is depth-capped as well, so even a tree corrupted by hand terminates.
FT_PARENT[outer]=inner                  # forced, bypassing the API
_walked=$( timeout 5 bash -c "
    cd '$here'; source ./fruity-tui.bash; ft_init; exec {FT_TTY}>/dev/null
    FT_TYPE[a]=div; FT_TYPE[b]=div; FT_PARENT[a]=b; FT_PARENT[b]=a
    _ft_enclosing_form_of a; printf 'returned'" 2>&1 )
check "a hand-made ring still terminates" "${_walked:-HUNG}" "returned"
ft_remove cy 2>/dev/null

note "a modal gives the app back exactly as it found it"
# ft_modal_push/pop save the root, focus and coalescing across a dialog's nested loop.
_snap() { printf 'root=%s focus=%s idx=%s coal=%s ring=[%s]' \
        "${FT_ROOT:-}" "${FT_FOCUS:-}" "${FT_FOCUS_INDEX:-0}" "${FT_COALESCING:-0}" "${FT_FOCUS_RING[*]}"; }
_mk_app() {
    ft_remove mapp 2>/dev/null
    ft-form name=mapp width=70 height=12
        ft-button name=m1 "One"
        ft-button name=m2 "Two"
        ft-button name=m3 "Three"
    end_ft_form
    ft_layout mapp; FT_ROOT=mapp; ft_focus_ring_build mapp; ft_focus m2
}
_mk_dlg() {                     # name
    ft-form name="$1" width=40 height=6
        ft-button name="${1}_ok" "OK"
    end_ft_form
    ft_layout "$1"; FT_ROOT=$1; ft_focus_ring_build "$1"
}
_mk_app; _before=$(_snap)
ft_modal_push; _mk_dlg md1
ft_remove md1; ft_modal_pop
check "one dialog: restored exactly"        "$(_snap)" "$_before"

_mk_app; _before=$(_snap)
ft_modal_push; _mk_dlg mn1; _mid=$(_snap)
ft_modal_push; _mk_dlg mn2
ft_remove mn2; ft_modal_pop
check "nested: back to the outer dialog"    "$(_snap)" "$_mid"
ft_remove mn1; ft_modal_pop
check "nested: back to the app"             "$(_snap)" "$_before"

# A dialog may change the app while it is open — a settings panel revealing a control, a
# wizard step dropping one. The ring saved at PUSH is wrong in both directions afterwards,
# so pop rebuilds it from the tree instead of restoring that snapshot.
_mk_app
ft_modal_push; _mk_dlg md2
ft_remove m3                                   # the dialog removed one of the app's controls
ft_remove md2; ft_modal_pop
check "a control the dialog REMOVED is gone from the ring" "${FT_FOCUS_RING[*]}" "m1 m2"
ft_focus m1; _r=""; for _ in 1 2; do ft_focus_next; _r+="$FT_FOCUS "; done
check "…and Tab never lands on it"          "$_r" "m2 m1 "

_mk_app
ft_modal_push; _mk_dlg md3
ft-button name=m4 "Four" parent=mapp           # …and one it ADDED
ft_remove md3; ft_modal_pop
ft_layout mapp
check "a control the dialog ADDED is reachable" "${FT_FOCUS_RING[*]}" "m1 m2 m3 m4"
ft_remove mapp 2>/dev/null

summary
