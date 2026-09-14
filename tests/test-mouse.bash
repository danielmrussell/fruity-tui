#!/usr/bin/env bash
# Unit tests for mouse support: SGR decode, hit-testing, click-to-focus, click
# caret + drag-select in a field (clamped to the field), button click-activate,
# tree row click / glyph toggle, and scroll-wheel routing.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null

note "SGR mouse decode: \\e[<b;x;y(M|m) → 'MOUSE b x y act'"
export LC_ALL=C; : "${FT_ESC_DELAY:=0.05}"
printf '\x1b[<0;10;3M' > /tmp/ftm.$$; exec 8< /tmp/ftm.$$
_ft_decode_key 8; check "press decodes" "$FT_KTOK" "MOUSE 0 10 3 M"; exec 8<&-
printf '\x1b[<0;10;3m' > /tmp/ftm.$$; exec 8< /tmp/ftm.$$
_ft_decode_key 8; check "release decodes" "$FT_KTOK" "MOUSE 0 10 3 m"; exec 8<&-
rm -f /tmp/ftm.$$
FT_EVENT="MOUSE 32 44 7 M"; _ft_ev_split
check "split B" "$FT_MOUSE_BUTTON" "32"; check "split X" "$FT_MOUSE_X" "44"
check "split Y" "$FT_MOUSE_Y" "7"; check "split act" "$FT_MOUSE_ACTION" "M"

FT_COLS=60; FT_ROWS=16
ft-form name=app width=60 height=16 display=flex flexDirection=column gap=1
  ft-textfield name=f1 size=20 value="hello world foo"
  ft-textfield name=f2 size=20 value="second"
  ft-button    name=b1 OK onActivate=b1_on_activate
end_ft_form
ft_layout app; FT_ROOT=app; FT_FOCUS=f2
fx=${FT_ABSOLUTE_X[f1]}; fy=${FT_ABSOLUTE_Y[f1]}
_click() { FT_MOUSE_BUTTON=$1; FT_MOUSE_ACTION=$2; FT_MOUSE_X=$(( $3 + 1 )); FT_MOUSE_Y=$(( $4 + 1 )); _ft_dispatch_mouse; }

note "hit-test finds the deepest positioned control at a point"
_ft_hit_test $(( fx + 3 )) $(( fy + 1 )); check "hit lands on f1" "$FT_HIT" "f1"

note "a SINGLE left click only SELECTS the field — it does not start editing"
_click 0 M $(( fx + 1 + 5 )) $(( fy + 1 ))     # well starts at fx+1 (left border); col 5
check "click focused f1"            "$FT_FOCUS" "f1"
check "single click did NOT edit"   "$(ft_get f1 runlevel; printf %s "$FT_RET")" "poised"

note "a DOUBLE click enters edit mode and drops the caret where you clicked"
_click 0 M $(( fx + 1 + 5 )) $(( fy + 1 ))     # second press, same spot, within the window
check "double click entered edit mode" "$(ft_get f1 runlevel; printf %s "$FT_RET")" "editing"
_ft_textfield_caret f1; check "double click placed caret at 5" "$FT_RET" "5"

note "drag extends a selection, clamped to the field's own text (never past it)"
_click 32 M $(( fx + 1 + 11 )) $(( fy + 1 ))    # drag to col 11
_ft_textfield_selrange f1 && r="[$FT_SELECTION_START,$FT_SELECTION_END)" || r=none
check "drag selected [5,11)" "$r" "[5,11)"
ft_get f1 value; check "selection text is ' world'" "${FT_RET:FT_SELECTION_START:FT_SELECTION_END-FT_SELECTION_START}" " world"
_click 32 M $(( fx + 999 )) $(( fy + 1 ))       # drag way past the right edge
_ft_textfield_selrange f1; check "drag past the end clamps to the text length (15)" "$FT_SELECTION_END" "15"
_click 0 m $(( fx + 1 )) $(( fy + 1 ))          # release
check "release clears the mouse-down" "$_FT_MOUSE_DOWN" ""

note "button click activates on release"
CLICKED=0; b1_on_activate() { CLICKED=1; }
bx=${FT_ABSOLUTE_X[b1]}; by=${FT_ABSOLUTE_Y[b1]}
_click 0 M "$bx" "$by"                          # press on the button
check "press focused the button" "$FT_FOCUS" "b1"
check "press alone did NOT activate" "$CLICKED" "0"
_click 0 m "$bx" "$by"                          # release → activate
check "release activated the button" "$CLICKED" "1"

note "tree: click a row selects it; click the glyph column toggles the branch"
ft-empty app
ft-tree name=tr rows=8
  ft-tree-node "root"  key=root depth=0 expanded=true
  ft-tree-node "child" key=ch   depth=1
  ft-tree-node "leaf"  key=lf   depth=0
end_ft_tree
end_ft_form
ft_layout app; FT_FOCUS=tr
tx=${FT_ABSOLUTE_X[tr]}; ty=${FT_ABSOLUTE_Y[tr]}
_click 0 M $(( tx + 5 )) $(( ty + 1 ))          # row 1 = 'child'
ft_get tr value; check "click row 1 selected 'ch'" "$FT_RET" "ch"
_click 0 m $(( tx + 5 )) $(( ty + 1 ))
_click 0 M "$tx" "$ty"                          # row 0, glyph column (depth 0 → col 0) → toggle
_ft_tree_gather tr; check "clicking the glyph collapsed root" "${FT_TREE_NODE_EXPANDED[0]}" "0"

note "scroll wheel routes Up/Down to the control under the cursor"
ft-empty app
ft-tree name=tr2 rows=3
  for _i in 1 2 3 4 5 6; do ft-tree-node "n$_i" key="k$_i" depth=0; done
end_ft_tree
end_ft_form
ft_layout app; FT_FOCUS=tr2
gx=${FT_ABSOLUTE_X[tr2]}; gy=${FT_ABSOLUTE_Y[tr2]}
ft_tree_key_home tr2                            # cursor at node 0
FT_MOUSE_BUTTON=65; FT_MOUSE_ACTION=M; FT_MOUSE_X=$(( gx + 1 )); FT_MOUSE_Y=$(( gy + 1 )); _ft_dispatch_mouse  # wheel down
ft_resolved_prop tr2 cursor 0; check "wheel down moved the tree cursor" "$FT_RET" "1"

note "a dropdown OPENS on click, and clicking an option in the overlay SELECTS it"
ft-form name=app2 width=40 height=14 display=flex flexDirection=column
  ft-select name=dd size=1
    ft-option value=red   "Red"
    ft-option value=green "Green"
    ft-option value=blue  "Blue"
  end_ft_select
end_ft_form
ft_layout app2; FT_ROOT=app2; FT_FOCUS=dd
dx=${FT_ABSOLUTE_X[dd]}; dy=${FT_ABSOLUTE_Y[dd]}
_click 0 M "$dx" "$dy"; _click 0 m "$dx" "$dy"          # press + release on the closed line
ft_resolved_prop dd open false; check "click OPENS the closed dropdown" "$FT_RET" true
_ft_select_geom dd                                     # sets _SEL_TOP (overlay first row)
_click 0 M "$dx" "$(( _SEL_TOP + 2 ))"                 # click the 3rd option (Blue)
ft_resolved_prop dd value ""; check "clicking an option selects it (blue)" "$FT_RET" blue
ft_resolved_prop dd open false; check "…and closes the dropdown"           "$FT_RET" false

note "a textfield scrollbar is grabbable, tracks the cursor, and never drops mid-drag"
ft-form name=app3 width=30 height=10
  ft-textfield name=ta rows=3 wrap=false value=$'line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8'
end_ft_form
ft_layout app3; FT_ROOT=app3; FT_FOCUS=ta
FT_OUT=""; ft_draw_one ta                               # the draw publishes FT_TEXTFIELD_VBAR
read -ra VB <<< "${FT_TEXTFIELD_VBAR[ta]:-}"
[[ ${#VB[@]} -eq 6 ]] && check "the tall field drew a vertical scrollbar" 1 1 || check "the tall field drew a vertical scrollbar" 0 1
# A field's vertical offset is its `scrollTop` property — the DOM's name — where it used to be
# the private FT_TEXTFIELD_VSCROLL table. The mouse is one of the routes that has to move it.
_voff() { _ft_get_raw "$1" scrollTop; printf '%s' "${FT_RET:-0}"; }
_click 0 M "${VB[0]}" "$(( VB[3] + VB[4] - 1 ))"; _click 0 m "${VB[0]}" "$(( VB[3] + VB[4] - 1 ))"
check "clicking the track bottom scrolls to the max" "$(_voff ta)" "${VB[5]}"
_click 0 M "${VB[0]}" "${VB[3]}"; _click 0 m "${VB[0]}" "${VB[3]}"
check "clicking the track top scrolls back to 0"     "$(_voff ta)" "0"
# DRAG CAPTURE: grab the thumb, then move the cursor OFF the bar column — it must keep scrolling.
_ft_setprop ta scrollTop 0; FT_OUT=""; ft_draw_one ta; read -ra VB <<< "${FT_TEXTFIELD_VBAR[ta]}"
_click 0  M "${VB[0]}" "${VB[1]}"                        # press ON the thumb (top)
check "grabbing the thumb starts a drag capture" "$([[ -n ${FT_TEXTFIELD_SBDRAG[ta]:-} ]] && echo yes)" yes
_click 32 M "$(( VB[0] + 8 ))" "$(( VB[3] + VB[4] - 1 ))"  # drag DOWN, cursor 8 cols off the bar
check "the drag keeps scrolling even off the bar column" "$(_voff ta)" "${VB[5]}"
_click 0  m "${VB[0]}" 0
check "release ends the capture" "${FT_TEXTFIELD_SBDRAG[ta]:-none}" none

note "a beacon overlay is TRANSPARENT to the mouse — clicks pass through to the control beneath"
FT_ROOT=app2; FT_FOCUS=""
ft-beacon name=bov target=dd variant=frame parent=app2       # a real child, declared AFTER dd
# Park its hit-rect exactly over dd. Declared later, it would SHADOW dd in the hit walk —
# unless it is pointer-transparent (FT_CLASS_NOHIT), which is the whole point.
FT_ABSOLUTE_X[bov]=${FT_ABSOLUTE_X[dd]}; FT_ABSOLUTE_Y[bov]=${FT_ABSOLUTE_Y[dd]}; FT_MEASURED_WIDTH[bov]=${FT_MEASURED_WIDTH[dd]}; FT_MEASURED_HEIGHT[bov]=${FT_MEASURED_HEIGHT[dd]}
_ft_hit_test "${FT_ABSOLUTE_X[dd]}" "${FT_ABSOLUTE_Y[dd]}"
check "the hit lands on the control, not the beacon over it" "$FT_HIT" dd
ft_remove bov

note "a slider moves by clicking its track — RELX (column in the track) maps to a value"
ft-form name=sapp width=40 height=6 display=flex
  ft-slider name=sl min=0 max=100 value=0 width=22
end_ft_form
ft_layout sapp; FT_ROOT=sapp; FT_FOCUS=""
slx=${FT_ABSOLUTE_X[sl]}; sly=${FT_ABSOLUTE_Y[sl]}; slw=${FT_MEASURED_WIDTH[sl]}
_click 0 M $(( slx + slw - 1 )) "$sly"           # click the far RIGHT end of the track
check "click right end → near max" "$([[ $(ft_own_prop sl value; echo "$FT_RET") -ge 90 ]] && echo hi)" hi
_click 0 M "$slx" "$sly"                          # click the far LEFT end
check "click left end → min"       "$(ft_own_prop sl value; echo "$FT_RET")" "0"
_click 0 M $(( slx + slw/2 )) "$sly"             # click the middle
ft_own_prop sl value; smid=$FT_RET
check "click middle → mid range" "$([[ $smid -ge 35 && $smid -le 65 ]] && echo mid)" mid

note "a callout box CLAIMS every press on its own pixels — even over an interactive control"
# POLICY REVERSAL, decided from the field. The original contract here was the opposite ("a
# callout must not swallow a click meant for a control it overlaps") — and in practice it made
# a callout dragged onto a control ungrabbable at those cells, while the clicks pressed and
# FOCUSED controls the user could not see. The callout is opaque: the pressed pixel is the
# callout's, so the callout takes the grab, and the control beneath is reachable the moment the
# box is dragged off it — which this very rule is what makes possible from any cell.
ft-beacon name=cov target=sl variant=callout parent=sapp
FT_BEACON_BOX[cov]="$(( sly-1 )) $(( slx-2 )) $(( sly+1 )) $(( slx+slw+2 ))"   # blanket the slider
_FT_BEACON_GRAB=""; _FT_MOUSE_DOWN=""
_click 0 M $(( slx + 3 )) "$sly"                 # press ON the slider, under the callout box
check "the callout takes the grab, not the slider" "${_FT_BEACON_GRAB%% *}" cov
check "the slider saw no press"                    "${_FT_MOUSE_DOWN:-none}" none
_FT_BEACON_GRAB=""; FT_DAMAGE_NARROW=0
# an inert cell the box covers still starts a drag, as before
FT_BEACON_BOX[cov]="1 1 3 6"; _ft_beacon_grab_at 3 2
check "a callout grab begins over a covered cell" "$([[ -n ${_FT_BEACON_GRAB:-} ]] && echo yes)" yes
_FT_BEACON_GRAB=""; FT_DAMAGE_NARROW=0
# …and the slider is perfectly reachable where the box does NOT cover it
_FT_MOUSE_DOWN=""
_click 0 M $(( slx + 3 )) "$sly"                 # same cell, box moved away
check "with the box elsewhere the slider gets its press" "$_FT_MOUSE_DOWN" sl
ft_remove cov

note "an INERT control never claims a click it is merely standing in front of"
# _ft_mouse_target tested `focusable` with -n, which is true for the "0" every inert class
# stores, so a heading/statusbar/keylegend claimed the click. ft_focus refused to move, so
# this looked fine — the damage was that the wheel stopped chaining past them and a callout
# could not be dragged off any cell they covered.
ft-form name=inert width=40 height=10
    ft-button    name=inBtn "OK"
    ft-heading   name=inHd  "Section"
    ft-statusbar name=inSb
    ft-keylegend name=inKl
end_ft_form
ft_layout inert
_ft_mouse_target inBtn; check "a button takes its own click" "$FT_RET" inBtn
for n in inHd inSb inKl; do
    if _ft_mouse_target "$n"; then r=$FT_RET; else r=none; fi
    check "$n does not claim the click" "$r" none
done

note "wheel chaining follows the class, not a hardcoded type list"
# Browser rule: over something with nothing of its own to scroll, the wheel scrolls the
# nearest overflow container. `label` used to sit in an always-chain list, which made
# _ft_label_wheel_probe unreachable — and the probe itself only consulted an extent cache
# that an explicitly-sized label never has, so it answered "nothing to scroll" regardless.
_wheel_chains() {               # node → yes/no, exactly as the wheel router decides
    local n=$1 t="" wp
    _ft_mouse_target "$n" && t=$FT_RET
    case ${t:+${FT_TYPE[$t]:-}} in
        "") echo yes; return ;;
        *)  wp=${FT_CLASS_WHEEL_PROBE[${FT_TYPE[$t]:-}]:-}
            if [[ -n "$wp" ]] && ! "$wp" "$t"; then echo yes; else echo no; fi ;;
    esac
}
ft-form name=whl width=50 height=12
    ft-div name=whlPane height=6 overflowY=auto
        ft-heading name=whlHd "Section"
        ft-label name=whlBig   width=20 height=3 text=$'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8'
        ft-label name=whlSmall width=20 height=3 text="fits"
    end_ft_div
end_ft_form
ft_layout whl
check "over an inert heading → the pane scrolls"      "$(_wheel_chains whlHd)"    yes
check "over a label whose text FITS → the pane"       "$(_wheel_chains whlSmall)" yes
check "over a SCROLLABLE label → the label keeps it"  "$(_wheel_chains whlBig)"   no

note "a callout's box owns its own pixels — a press on it grabs, never the control beneath"
# THE BUG THIS PINS: the press path resolved the interactive control UNDER the callout first,
# so a callout dragged onto a textfield became ungrabbable wherever the field lay beneath it —
# and the click FOCUSED THE INVISIBLE FIELD instead. The user experienced a stuck callout that
# only "reset" when a click happened to land on an inert-backed cell. The callout is opaque:
# the pixel the user pressed is the callout's, so the callout claims it.
FT_COLS=60; FT_ROWS=16
ft-form name=gapp width=60 height=16
  ft-textfield name=gfld size=30 value="underneath"
end_ft_form
ft_layout gapp; FT_ROOT=gapp; FT_FOCUS=""
ft-beacon name=gcall target=gfld variant=callout text="parked right on top of the field"
# park the callout squarely over the field, as a drag would leave it
gx=${FT_ABSOLUTE_X[gfld]}; gy=${FT_ABSOLUTE_Y[gfld]}
FT_BEACON_BOX[gcall]="$gy $gx $(( gy + 2 )) $(( gx + 20 ))"
_FT_BEACON_GRAB=""
_click 0 M $(( gx + 5 )) $(( gy + 1 ))          # press mid-box, field directly beneath
[[ "${_FT_BEACON_GRAB%% *}" == gcall ]] \
    && check "the press grabbed the callout"        1 1 \
    || check "the press grabbed the callout"        0 1
[[ "$FT_FOCUS" != gfld ]] \
    && check "…and did NOT focus the hidden field"  1 1 \
    || check "…and did NOT focus the hidden field"  0 1
_FT_BEACON_GRAB=""; FT_DAMAGE_NARROW=0
# …and a press OUTSIDE the box still reaches the field normally
FT_FOCUS=""
_click 0 M $(( gx + 25 )) $(( gy + 1 ))         # field row, right of the parked box
check "a press beside the box still reaches the field" "$FT_FOCUS" "gfld"
ft_remove gcall

summary
