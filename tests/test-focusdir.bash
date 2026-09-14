#!/usr/bin/env bash
# Tests for spatial (directional) focus: ft_focus_dir left|right|up|down.
# A 2-column × 3-row grid of buttons with KNOWN geometry (we set the absolute
# boxes directly, so no layout pass is needed). Verifies: arrows move by geometry
# (cut across columns), LEFT/RIGHT stop at the horizontal edge, and UP/DOWN fall
# back to linear ring order (wrapping) at the vertical edge.
#
#   A  B        cols: A/C/E at x=0 ; B/D/F at x=20
#   C  D        rows: A/B y=0 ; C/D y=2 ; E/F y=4   (w=8 h=1)
#   E  F
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null

ft-form name=app width=40 height=8
    ft-button name=A "A"; ft-button name=B "B"
    ft-button name=C "C"; ft-button name=D "D"
    ft-button name=E "E"; ft-button name=F "F"
end_ft_form

# Pin an explicit grid geometry (bypass layout).
set_box() { FT_ABSOLUTE_X[$1]=$2; FT_ABSOLUTE_Y[$1]=$3; FT_MEASURED_WIDTH[$1]=$4; FT_MEASURED_HEIGHT[$1]=$5; }
set_box A  0 0 8 1; set_box B 20 0 8 1
set_box C  0 2 8 1; set_box D 20 2 8 1
set_box E  0 4 8 1; set_box F 20 4 8 1
FT_FOCUS_RING=(A B C D E F)

# from FROM press DIR, expect to land on WANT
nav() { ft_focus "$1"; ft_focus_dir "$2"; check "$1 $2 → $3" "$FT_FOCUS" "$3"; }

note "LEFT / RIGHT cut across columns on the same row"
nav A right B
nav B left  A
nav C right D
nav D left  C
nav E right F
nav F left  E

note "LEFT / RIGHT fall back to ring order at the horizontal edge, like UP / DOWN"
# These four used to expect the arrow to do NOTHING. That made the control at each edge of a
# row a dead end — press Right on B and the app looked wedged, with no way to tell "there is
# nothing to the right" from "the key was dropped". Every direction now agrees with the linear
# ring when geometry runs out, which is the order all four are ultimately a shortcut through.
nav A left  F     # left edge → linear prev, wrapping to the last control
nav B right C     # right edge → linear next
nav E left  D
nav F right A     # right edge → linear next, wrapping to the first

note "UP / DOWN move to the aligned control directly above / below"
nav A down C
nav C down E
nav C up   A
nav E up   C
nav B down D
nav F up   D

note "UP / DOWN fall back to linear ring order (wrapping) at the vertical edge"
nav A up   F     # top edge → linear prev wraps to the last control
nav F down A     # bottom edge → linear next wraps to the first
nav E down F     # nothing spatially below E, but F is next in the ring

note "a diagonal is resolved by the nearer axis-aligned neighbour"
set_box A 0 0 8 1
nav F up   D     # D is directly above F; A/B are farther and off-line

note "a same-LINE neighbour beats a nearer control on another line (alignment wins)"
# The css-demo page-1 bug: Right off the colour dropdown drifted to the nearer Okay
# button a row below instead of the Bold checkbox beside it. A row-mate must win even
# when an off-row control is horizontally closer.
FT_FOCUS_RING=(A B C)
set_box A 10 0 8 1     # current
set_box B 30 0 8 1     # its row-MATE, farther to the right
set_box C 14 2 8 1     # nearer horizontally, but a row BELOW (off-line)
nav A right B          # picks the row-mate, not the nearer off-row control
set_box A 0 0 8 1; set_box B 20 0 8 1; set_box C 0 2 8 1   # restore the grid
FT_FOCUS_RING=(A B C D E F)

note "down does NOT skip a nearer band that overlaps our column (the page-4 flaw)"
# A tall pane; B directly below it (its column-band); C farther below. Down must land on B —
# not skip B's whole band to reach a farther control just because it also overlaps.
FT_FOCUS_RING=(A B C)
set_box A 10 0 40 6    # a tall code pane
set_box B 20 7 20 3    # the next band down, overlaps A's columns → this is what "down" means
set_box C  5 12 15 1   # farther down, also overlaps — must NOT win over the nearer band B
nav A down B
set_box A 0 0 8 1; set_box B 20 0 8 1; set_box C 0 2 8 1   # restore the grid
FT_FOCUS_RING=(A B C D E F)

# ── a dropdown closes itself when focus leaves (no stuck-open overlay) ────────
note "an OPEN dropdown collapses when focus moves away (Tab/arrow), via _ft_blur_select"
ft-form name=f2 width=40 height=8
    ft-select name=dd size=1
        ft-option value=a "Alpha"
        ft-option value=b "Beta"
    end_ft_select
    ft-button name=after "OK"
end_ft_form
ft_focus dd
ft_select_open dd
ft_resolved_prop dd open false; check "dropdown is open after ft_select_open" "$FT_RET" "true"
ft_focus after                       # focus leaves the select → _ft_blur_select fires
ft_resolved_prop dd open false; check "dropdown CLOSED itself on blur"        "$FT_RET" "false"

note "an open overlay suspends the keycap pulse (it must not repaint OVER the dropdown)"
ft_use_theme ft-dark; FT_FOCUS=dd
FT_OVERLAY_DEPTH=0; _ft_kcpulse_disarm; _ft_kcpulse_arm
[[ -n "${FT_ANIM_PHASE[__ft_kcpulse]:-}" ]] && check "pulse runs with no overlay" 1 1 || check "pulse runs with no overlay" 0 1
ft_select_open dd
check "opening a dropdown raises the overlay depth" "$FT_OVERLAY_DEPTH" "1"
[[ -z "${FT_ANIM_PHASE[__ft_kcpulse]:-}" ]] && check "…and suspends the pulse" 1 1 || check "…and suspends the pulse" 0 1
_ft_kcpulse_arm
[[ -z "${FT_ANIM_PHASE[__ft_kcpulse]:-}" ]] && check "arm is a no-op under an overlay" 1 1 || check "arm is a no-op under an overlay" 0 1
ft_select_close dd
check "closing balances the depth back to 0" "$FT_OVERLAY_DEPTH" "0"
_ft_kcpulse_arm
[[ -n "${FT_ANIM_PHASE[__ft_kcpulse]:-}" ]] && check "the pulse resumes once closed" 1 1 || check "the pulse resumes once closed" 0 1
_ft_kcpulse_disarm
ft_focus after                       # restore state for the tests that follow

# ── the focus locator is now a one-shot BEACON around the focused control ────
note "ft_focus_ping drops a one-shot locator beacon aimed at the focused control"
FT_ABSOLUTE_X[after]=5; FT_ABSOLUTE_Y[after]=4; FT_MEASURED_WIDTH[after]=8; FT_MEASURED_HEIGHT[after]=1
ft_focus_ping
check "a locator beacon exists"                 "${FT_TYPE[$FT_LOCATOR]:-}" "beacon"
ft_resolved_prop "$FT_LOCATOR" target ""
check "the locator targets the focused control" "$FT_RET" "after"
ft_resolved_prop "$FT_LOCATOR" lifetime ""
check "the locator is one-shot (it self-destroys)" "$FT_RET" "oneshot"
[[ -n "${FT_ANIM_PHASE[$FT_LOCATOR]:-}" ]] && check "the locator animation is armed" 1 1 \
                                           || check "the locator animation is armed" 0 1

note "the locator pulse is THEMEABLE via --locator-N custom properties (not hardcoded)"
ft_use_theme ft-dark;  _ft_beacon_pulsecolor "$FT_LOCATOR" 0; dk=$FT_RET
ft_use_theme ft-ocean; _ft_beacon_pulsecolor "$FT_LOCATOR" 0; oc=$FT_RET
check "dark locator-1 is the gold default"       "$dk" $'\e[38;5;220;1m'
check "ocean overrides locator-1 (theme recolours)" "$oc" $'\e[38;5;51;1m'
[[ "$oc" != "$dk" ]] && check "the two themes differ" 1 1 || check "the two themes differ" 0 1
ft_use_theme ft-dark
ft_remove "$FT_LOCATOR"

note "ft_focus works on a control added AFTER the ring was built (rebuilds + retries)"
ft-button name=lateadd "late" parent=f2       # f2's ring was built at end_ft_form, before this
ok "focus lands on the freshly-added control" ft_focus lateadd
check "…and FT_FOCUS is it" "$FT_FOCUS" "lateadd"

# ── The arrow trail: reversing a step brings you back ────────────────────────
# R sits midway below P and Q, so from R the two are EXACTLY equidistant and geometry has to
# break the tie arbitrarily — it takes P, the first in the ring. That is what made stepping
# Q ↓ R ↑ strand you on the far side of the row: nothing was wrong with the distances, the
# question simply has no geometric answer. The trail answers it with the one fact that does
# distinguish them — you came from Q.
#
#     P        Q          P at x=0, Q at x=20, both on row 0
#          R              R at x=10, row 2 — centred between them
ft-form name=f3 width=40 height=8
    ft-button name=P "P"; ft-button name=Q "Q"; ft-button name=R "R"
end_ft_form
set_box P 0 0 8 1; set_box Q 20 0 8 1; set_box R 10 2 8 1
FT_FOCUS_RING=(P Q R)

note "reversing an arrow returns you to where you came from"
ft_focus P; ft_focus_dir down
check "P down → R (the only thing below)"        "$FT_FOCUS" "R"
ft_focus_dir up
check "…and Up goes back to P"                   "$FT_FOCUS" "P"
ft_focus Q; ft_focus_dir down
check "Q down → R as well"                       "$FT_FOCUS" "R"
ft_focus_dir up
check "…and Up returns to Q, not equidistant P"  "$FT_FOCUS" "Q"

note "…but the trail does not outlive the walk that made it"
# Arrive somewhere any other way and the memory is gone, or an arrow would send you to a
# control you were never on.
ft_focus Q; ft_focus_dir down                    # trail: R came from Q
ft_focus R                                       # …re-taken by a NON-arrow route
ft_focus_dir up
check "a plain ft_focus clears it (geometry decides)" "$FT_FOCUS" "P"
ft_focus Q; ft_focus_dir down
ft_focus_move 1; ft_focus_move -1                # Tab away and back
ft_focus_dir up
check "Tab clears it too"                        "$FT_FOCUS" "P"

note "…and it is only a TIEBREAK — geometry still wins when there is a real answer"
# T sits directly above R, in a nearer band than the P/Q row. The trail must not drag focus
# past it back to Q, or a control could become unreachable by arrow.
#
#     P        Q
#          T              T at x=10, row 2
#          R              R at x=10, row 4
ft-button name=T "T" parent=f3
set_box P 0 0 8 1; set_box Q 20 0 8 1; set_box T 10 2 8 1; set_box R 10 4 8 1
FT_FOCUS_RING=(P Q T R)
ft_focus R; FT_FOCUS_CAME_FROM[R]=Q; FT_FOCUS_CAME_DIR[R]=down   # as if we had arrived from Q
ft_focus_dir up
check "the nearer aligned control still wins over the trail" "$FT_FOCUS" "T"

# …and the case the assertion above CANNOT see. It passed before this rule was corrected too,
# because the old two-pass search filtered Q out by band before the trail was consulted. The
# trail only ever bit in the FALLBACK regime — when nothing ahead overlapped you at all — and
# there it overrode the geometry outright, whatever the scores were. So: nothing aligned above
# R, a near T off to one side, and a far Q off to the other that we arrived from.
#
#              T                    Q       T at x=0 row 2, Q at x=30 row 0
#              R                            R at x=10 row 4  (current)
set_box P 0 0 8 1; set_box Q 30 0 8 1; set_box T 0 2 8 1; set_box R 10 4 8 1
FT_FOCUS_RING=(P Q T R)
ft_focus R; FT_FOCUS_CAME_FROM[R]=Q; FT_FOCUS_CAME_DIR[R]=down
ft_focus_dir up
check "reversing takes the nearer control, not the one it came from" "$FT_FOCUS" "T"

note "a near neighbour slightly off-line beats a far one that happens to line up"
# demo/callout-demo.bash page 4, measured at 118x40: the "Deep" checkbox at 46,8; the
# SMB/Workers slider three rows below at 30,11, four columns clear of it; the step arrow
# thirteen rows below at 48,21, overlapping Deep's columns. Down must reach the slider.
# Reported by the author: "no combination of arrow keys could get me there."
#
# THIS IS ONE WALL OF THE OFF-LINE PENALTY and the row-mate assertion above is the other:
# raise FT_FOCUS_OFF_LINE_PENALTY past 15 and this fails, drop it below 8 and that one does.
# Both are pinned so a future edit lands on a red test rather than a slightly worse feel.
set_box P 46  8  8 1        # chkDeep     (current)
set_box Q 30 11 12 1        # sldWorkers  — 3 rows below, 4 columns clear
set_box R 48 21  3 1        # btnStepPrev — 13 rows below, column-aligned
FT_FOCUS_RING=(P Q R)
ft_focus P; unset "FT_FOCUS_CAME_DIR[P]" "FT_FOCUS_CAME_FROM[P]"
ft_focus_dir down
check "down reaches the near slider, not the far aligned arrow" "$FT_FOCUS" "Q"

summary
