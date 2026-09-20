#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  A DRAGGED callout's leader keeps the contract wherever the box is parked.
#
#  Auto placement never parks a box on the wrong side of a named anchor, so every rule
#  about exits and approaches was only ever exercised from the sides the placer chooses.
#  A drag can park the box anywhere — and three things the user reported, each reproduced
#  in the real pty, each byte-traced, are pinned here so they stay fixed:
#    · parked BELOW an anchor=topLeft target, the line ran straight up THROUGH the callout's
#      own box (the exit exploration assumed box-above-target in a second place)
#    · parked BELOW an anchor=topCenter target, the line went THROUGH the target's text
#      (the router's degenerate Z family burned the scan before the first clean column)
#    · parked ONE ROW above its target, the line AND the arrowhead vanished (a zero-length
#      leader was treated as a swallowed head)
#    · the box directly ABOVE the head's row (p4:3, p5:3 at 62×33 — no drag needed): the line
#      left the bottom edge and ran PARALLEL to it, a bare ─── floating one row under the box
#      with nothing attaching it ("the arrowhead doesn't connect to the callout"). The drawn
#      line now starts ON the border — a ┬ junction, a stub, a corner: ◀──╯ hanging from ┬ —
#      and a straight stem gets its ┴ too.
#  These assert SHAPES in the rendered frame, not goldens: a golden would re-record the bug.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
renderer="$here/tests/render-screen.py"
demo="$here/demo/callout-demo.bash"
export FT_STATE_AUTOLOAD=0 FT_RECORD=""

frame() {                       # page step keys → $FRAME   (FRAME_ROWS overrides the 40)
    FRAME=$(FT_TEST_QUITKEY= FT_TEST_COLS=62 FT_TEST_ROWS=${FRAME_ROWS:-40} DEMO_PAGE=$1 DEMO_STEP=$2 \
            python3 "$renderer" "$demo" "$3" 2>/dev/null)
    [[ -n "$FRAME" ]]
}
rows_matching() { printf '%s\n' "$FRAME" | grep -cE "$1"; }

note "parked straight below an anchor=topLeft target: out the top, around, never through itself"
frame 2 2 'MOUSE:0;25;10;M MOUSE:32;25;20;M MOUSE:32;25;30;M MOUSE:0;25;30;m 1.5' \
    || check "the app rendered" 0 1
# the callout's text must be INTACT — a line through the box cuts a word in two (the bug drew
# "anchor=topL│ft" and "target's to│-LEFT"); asserting on the whole word is what catches that
check "the callout's first text row is intact"       "$(rows_matching 'anchor=topLeft parks')" 1
check "…and its second"                              "$(rows_matching "top-LEFT corner")" 1
check "the head is above the target's corner"        "$(rows_matching '▼')" 1
check "the target's box is intact"                   "$(rows_matching '┌────────────────┐')" 1

note "parked straight below an anchor=topCenter target: routed AROUND the control"
frame 2 3 'MOUSE:0;25;10;M MOUSE:32;25;20;M MOUSE:32;25;28;M MOUSE:0;25;28;m 1.5' \
    || check "the app rendered" 0 1
check "the target's text is not cut by the line"     "$(rows_matching 'Nine points')" 1
check "the target's top border is not cut"           "$(rows_matching '┌────────────────┐')" 1
check "a head points down at the target"             "$(rows_matching '▼')" 1

note "parked one free row above its target: the head still shows"
frame 2 2 'MOUSE:0;25;10;M MOUSE:32;25;12;M MOUSE:32;25;14;M MOUSE:0;25;14;m 1.5' \
    || check "the app rendered" 0 1
check "the arrowhead is drawn"                       "$(rows_matching '▼')" 1
check "the callout is still there"                   "$(rows_matching '╭②')" 1

note "box directly above the head's row (p4:3 at 62×33): the line hangs from the box, ◀──╯ under ┬"
FRAME_ROWS=33 frame 4 3 '1.2' || check "the app rendered" 0 1
check "the line turns up into the box"               "$(rows_matching 'Deep ◀──╯')" 1
check "…from a junction in the bottom border"        "$(rows_matching '╰─+┬─+╯')" 1

note "same shape, never dragged (p5:3 at 62×33)"
FRAME_ROWS=33 frame 5 3 '1.2' || check "the app rendered" 0 1
check "the line turns up into the box"               "$(rows_matching 'Padding  ◀──╯')" 1
check "…from a junction in the bottom border"        "$(rows_matching '╰─+┬─+╯')" 1

note "a straight stem is attached too (p1:1 at 62×33): ┴ in the top border"
FRAME_ROWS=33 frame 1 1 '1.2' || check "the app rendered" 0 1
# `[─▶⊠]` after the junction: the top border also carries the next glyph and the ⊠ close box,
# which are chrome the assertion is not about — it is about the stem meeting the border at a ┴.
check "the stem enters the top border at a junction" "$(rows_matching '╭①─+┴[─▶⊠]+╮')" 1

note "dragged OUT of the frame onto the key legend (p1:1 at 62×33): it parks there, and the line runs along the frame's ═"
# A callout used to be caged in its home frame — the user hit it as a wall while dragging. The
# placer still SEARCHES the home frame (auto placements are byte-identical to before), but a
# drag may park anywhere on screen. The leader then has to leave the frame: with the frame's
# ring an obstacle priced as decoration, and the router comparing candidates in the judge's
# currency, it runs along the `═` into the box's left edge instead of cutting through "Back".
FRAME_ROWS=33 frame 1 1 'MOUSE:0;20;21;M MOUSE:32;30;26;M MOUSE:32;40;31;M MOUSE:0;40;31;m 1.5' \
    || check "the app rendered" 0 1
check "the box parked across the frame's bottom border" "$(rows_matching '╚═+╰─+┤ target=share')" 1
check "…and over the legend row"                        "$(rows_matching '│ Enter │ Edit  │ < │ with variant')" 1
check "the stem still rises straight from the field"   "$(rows_matching '…and ▲one of them knows')" 1
check "no line through the Back button"                "$(rows_matching 'B│ck')" 0

summary
