#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tests/test-notrace.bash — actions that must leave NO TRACE on the screen.
#
#  A whole family of bugs in this project has the same shape: something paints outside the
#  layout (a modal, a callout, a confirmation line), goes away, and the repair of what it
#  covered is wrong. The damage is always PARTIAL, which is why it survives review and unit
#  tests — the control you are looking at is fine, and so is most of the screen.
#
#  The check that catches it is differential, not descriptive: run the same keys WITH and
#  WITHOUT the action and demand the two frames be identical, control for control. Asserting
#  "the field is still there" does not work — the active control is precisely the one that
#  survives, because it is dirty for its own reasons.
#
#  Found this way: a Ctrl+S confirmation whose one-row repair blanked the entire UI
#  (FT_PROTO_FILLS_BACKGROUND never listed `form`), and a css-demo callout whose hand-rolled erase took the
#  tail off the Quit button and never put it back.
#
#  SLOW BY NATURE — every check is two real pty runs of a real app. Keep the list short and
#  each case load-bearing.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
renderer="$here/tests/render-screen.py"
export FT_STATE_AUTOLOAD=0

# round_trip LABEL DEMO WITH-ACTION WITHOUT-ACTION — the two frames must match exactly.
round_trip() {
    local label=$1 demo=$2 with=$3 without=$4 a b
    a=$(FT_TEST_QUITKEY= python3 "$renderer" "$here/demo/$demo" "$with"    2>/dev/null)
    b=$(FT_TEST_QUITKEY= python3 "$renderer" "$here/demo/$demo" "$without" 2>/dev/null)
    if [[ -z "$a" || -z "$b" ]]; then
        check "$label (the app rendered nothing)" 0 1; return
    fi
    if [[ "$a" == "$b" ]]; then
        check "$label" 1 1
    else
        check "$label" 0 1
        diff <(printf '%s\n' "$b") <(printf '%s\n' "$a") | head -8 | sed 's/^/      /'
    fi
}

note "stepping through a page and back (the callout's footprint is repaired)"
# The callout paints its box, leader and arrowhead OUTSIDE its layout box, so removing it
# leaves cells nothing owns. _goto_step hands the extent to ft_damage; when it hand-rolled the
# repair instead, the erase clipped "Quit" to "Q" and no repaint reached it.
round_trip "three steps forward and three back" css-demo.bash \
           '> 0.5,> 0.5,> 0.5,< 0.5,< 0.5,< 2.0' '2.0'
# FLAKY UNDER LOAD, twice: this case alone captured its two runs on DIFFERENT PAGES (a K
# navigation lost around startup) and failed as phantom residue. The longer pause after the
# first K adds settle margin and has held since; if it flakes again the real fix is in
# render-screen.py — wait for the app's first output before writing the first step's keys.
round_trip "…on a later page too"               css-demo.bash \
           'K 1.2,K 0.5,> 0.5,> 0.5,< 0.5,< 2.0' 'K 1.2,K 2.0'

note "an overlay that comes and goes"
round_trip "the '.' locator beacon flashes and retires" css-demo.bash       '. 3.0' '3.0'
# NAMED FOR WHAT IT SENDS. This read "F1 opens help and Esc closes it" and sent neither: the
# harness has no F-key in its KEYS table, so 'F1' typed the letter F and the digit 1, and this
# demo has no help overlay to open. What it does pin is still worth pinning — keys the focused
# control does not claim must not paint anything, and Esc after them must not either — so it is
# named that instead of describing a feature it never touched.
round_trip "unclaimed keys, then Esc, paint nothing"    textfield-demo.bash 'F1 1.5,ESC 1.5' '3.0'

note "focus moves away and back"
round_trip "Tab out and Shift+Tab back"   textfield-demo.bash 'TAB,BTAB 1.2' '1.2'
round_trip "enter a field and Esc out"    textfield-demo.bash 'ENTER,ESC 1.2' '1.2'

note "a mouse drag leaves no trace"
# The drag path is the ONE place repairs run narrowed (FT_DAMAGE_NARROW), and its release used
# to hide any repair debt behind a full ft_refresh. That refresh is gone — release is a drag
# frame now — so this is the gate that keeps it honest: grab the callout, drag it out and back,
# release, then step away and back so the callout rebuilds fresh in both runs. Every cell the
# ghost, its damage, or the release frame touched must end up exactly as if no drag happened.
# (The dragged callout itself may legitimately re-route its leader, which is why the step
# round-trip does the final erase — the comparison never depends on the drag's own placement.)
export FT_TEST_COLS=62 FT_TEST_ROWS=40
_drag='MOUSE:0;24;23;M MOUSE:32;26;23;M MOUSE:32;28;23;M MOUSE:32;30;23;M MOUSE:32;28;23;M MOUSE:32;26;23;M MOUSE:32;24;23;M MOUSE:0;24;23;m 1.0'
round_trip "drag the callout out and back, then step" callout-demo.bash \
           "$_drag,> 0.5,< 2.0" '> 0.5,< 2.0'
# …and a release the placement CLAMPS: dropped hard against the frame edge, the parked box is
# pushed back inside the boundBox, so the ghost's ring at the drop point and the painted box are
# NOT the same cells — the release must damage the ring it abandons or its corners stay behind.
_dragclamp='MOUSE:0;24;23;M MOUSE:32;35;25;M MOUSE:32;45;28;M MOUSE:32;55;30;M MOUSE:32;60;32;M MOUSE:0;60;32;m 1.0'
round_trip "drop against the frame edge (clamped park)" callout-demo.bash \
           "$_dragclamp,> 0.5,< 2.0" '> 0.5,< 2.0'
# …and TWO gestures, compared against ONE that parks in the identical spot. The first-move
# erase (full interior + leader; the ghost that replaces the chip paints only a ring) was keyed
# on "has this callout ever been dragged" — FT_BEACON_DRAG, which PERSISTS across releases
# because parking is the feature. So a SECOND gesture never erased the full callout its own
# release had just painted: interior text fragments, leader segments and the arrowhead all
# stood at the first parking spot. NOTE the comparison shape: a step round-trip repaints the
# whole stage subtree and erases exactly the residue this hunts, so both runs end at the SAME
# parked state via different hop counts and the frames are compared as-is — the parked box,
# its leader, everything legitimate is identical in both; only residue can differ.
_hop2='MOUSE:0;27;23;M MOUSE:32;31;25;M MOUSE:32;35;27;M MOUSE:0;35;27;m 0.8,MOUSE:0;35;27;M MOUSE:32;31;25;M MOUSE:32;27;21;M MOUSE:0;27;21;m 1.5'
_hop1='MOUSE:0;27;23;M MOUSE:32;27;22;M MOUSE:32;27;21;M MOUSE:0;27;21;m 1.5'
round_trip "two hops leave what one hop leaves" callout-demo.bash "$_hop2" "$_hop1"
# …and a WILD path against a clean one to the same park. The tame cases above cancel any
# residue COMMON to both runs, so a whole class survived them: the wild wandering deposits its
# damage along path-dependent cells the clean run never visits. This is the case that caught
# the ghost crossing a checkbox and leaving "-only" of "[ ] Read-only": the narrow repair's
# container test read "has kids" where it meant "paints no ink", and a checkbox's zero-sized
# option children made it skip enlistment — the control under the ghost was never repainted.
_wild='MOUSE:0;27;23;M MOUSE:32;31;24;M MOUSE:32;25;22;M 0.2'
_wild+=',MOUSE:32;33;26;M MOUSE:32;24;21;M MOUSE:32;36;27;M 0.2'
_wild+=',MOUSE:32;22;20;M 0.2,MOUSE:32;30;16;M 0.2,MOUSE:32;20;14;M 0.2'
_wild+=',MOUSE:32;34;24;M MOUSE:32;26;18;M MOUSE:32;38;27;M 0.2'
_wild+=',MOUSE:0;38;27;m 0.6'
_wild+=',MOUSE:0;38;27;M MOUSE:32;30;22;M 0.2,MOUSE:32;42;30;M 0.2,MOUSE:32;28;19;M 0.2'
_wild+=',MOUSE:32;40;28;M 0.2,MOUSE:0;40;28;m 1.5'
_tame='MOUSE:0;27;23;M MOUSE:32;33;25;M MOUSE:32;38;27;M 0.2,MOUSE:0;38;27;m 0.6'
_tame+=',MOUSE:0;38;27;M MOUSE:32;39;28;M MOUSE:32;40;28;M 0.2,MOUSE:0;40;28;m 1.5'
round_trip "a wild path deposits nothing a clean one lacks" callout-demo.bash "$_wild" "$_tame"
unset FT_TEST_COLS FT_TEST_ROWS

summary
