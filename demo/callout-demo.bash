#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — demo/callout-demo.bash   (a guided tour of the CALLOUT system)
#
#  SEVEN pages, one callout idea each. Every page puts real controls on a stage
#  and then points at them, so the thing being taught is the thing you are
#  looking at — the callout on screen IS the example:
#
#     1  What a callout is        5  The callout's own chrome (badge/width/▶)
#     2  anchor — the nine points 6  The other variants (halo, ghost, badge)
#     3  place= vs auto           7  Where the engine decides to put it
#     4  Any control is a target
#
#  Each page is WALKED IN STEPS with ◀ ▶ (or < >). The code pane always shows
#  the ft-beacon call that produced the box you are looking at — target, place,
#  anchor and all — so nothing on screen is unexplained. On a screen too small
#  to spare it seven rows it collapses to a ONE-LINE form of the same call:
#  see _metrics, where every rung of the responsive ladder is a measurement of
#  what the placer needed and did not have.
#
#  Okay next page · Back previous · < > step · Tab move · Enter use · Q quit
#  E cycles the callout's effect · R un-parks a callout you dragged aside
#
#    bash demo/callout-demo.bash
# ─────────────────────────────────────────────────────────────────────────────
set -o pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/fruity-tui.bash"
# ALWAYS RECORD THE LAST RUN. Every frame this demo ships is appended to FT_RECORD (see
# ft_flush) and the terminal size to FT_RECORD.meta (see ft_term_size), so "what just happened
# on my screen" is replayable cell-for-cell without having to reproduce it — a drag report can
# be traced from the bytes instead of from a screenshot. Truncated per run; ~50KB a minute.
# Set FT_RECORD yourself to put it elsewhere, or FT_RECORD="" to turn it off.
# THE PREVIOUS RUN IS KEPT as FT_RECORD.prev (+ .prev.meta): one extra launch — a quick look, a
# probe, a test — must not destroy the evidence of the run being reported. (It did: a 22MB
# recording of a drag session was gone before anyone read it, overwritten by the very probe
# sent to replay it. The pty harness itself no longer records at all — tests/render-screen.py
# passes FT_RECORD="" unless the caller sets one.)
: "${FT_RECORD=/tmp/callout-last.rec}"
if [[ -n "$FT_RECORD" ]]; then
    [[ -s "$FT_RECORD" ]] && { mv -f "$FT_RECORD" "$FT_RECORD.prev"; mv -f "$FT_RECORD.meta" "$FT_RECORD.prev.meta" 2>/dev/null; }
    : > "$FT_RECORD"; : > "$FT_RECORD.meta"
fi
ft_init
ft_term_size
[[ -z "${FT_NO_WTFIX:-}" ]] && declare -F ft_wt_autofix_enter >/dev/null && ft_wt_autofix_enter

# DEMO_PAGE=N / DEMO_STEP=M open straight onto a page and step. Both matter for a screenshot
# gate: the STEPPED path (_goto_step) and a FRESH build of the same step are two different code
# paths through the same picture, and only having the first made a discrepancy between them
# invisible — you could not render the second to compare.
PAGE=${DEMO_PAGE:-1}
STEP=${DEMO_STEP:-1}
LAST=8
# Two pages are named rather than numbered, because two rules elsewhere are ABOUT them and a
# bare `2` in a layout function is unreadable: COMPASS_PAGE is the one that needs air on all
# four sides of its target (see _metrics), VARIANT_PAGE the one that raises specimen beacons
# of its own beside the step callout (see _place_variants).
COMPASS_PAGE=2
VARIANT_PAGE=6
# …and ARROW_PAGE the one that raises a variant=bigarrow specimen, which needs a clear LANE
# rather than clear air on all four sides: the arrow is thirty columns long and six rows
# tall, so the page is laid out to leave it a band nothing else uses (see _metrics).
ARROW_PAGE=8

# The step callout's own effect, cycled live with E — the one property of the callout you can
# change without leaving the page that teaches it. `none` by default: a static, persistent
# beacon arms no animation at all, so the event loop stays idle between keystrokes.
CALLOUT_EFFECT=none

# ── Sizes derived from the LIVE terminal ──────────────────────────────────────
# Nothing here is a constant. css-demo pins its prose to width=88 and its code panes to
# size=42, which at 80 columns is wider than the screen: the frame overflows, the panes clip
# mid-word, and the callout has nowhere to go but on top of a control. A demo ABOUT placement
# has to leave the placer somewhere to place things at every size — so the text columns shrink
# with the terminal and the STAGE takes whatever is left over.
#
# THE CODE PANES GO BESIDE THE STAGE, NOT ABOVE IT, whenever the terminal is wide enough.
# That is not cosmetic. Stacked (css-demo's arrangement) the two panes take ten rows out of the
# middle of the column, and the free band left above the specimen is three or four rows — less
# than a chip is tall. Measured on the anchor page at 171×45 with them stacked: anchor=topLeft
# could not be placed above its target at all (no free rectangle fitted box+line), so the placer
# parked the chip in the far margin and drew a 49-cell, 2-turn leader across the screen to reach
# a head one row above the target. Beside the stage, the same page has twelve clear rows above
# the target and the same call draws a straight three-cell line. The layout was the bug.
#
# PANE_MODE is the whole responsive story, and each rung buys the stage rows back:
#   side  wide+tall   the two panes down the right of the stage, stage gets the full height
#   row   narrowish   the css-demo arrangement: panes across, stage underneath
#   one   narrow      one pane at full width (two thirty-column panes are unreadable)
#   line  short       no pane at all — a ONE-ROW summary of the call, because six rows of
#                     code pane on a thirty-row terminal is six rows the placer needed and
#                     the result is a callout sitting on a control instead of beside it
CONCEPT_W=86; PANE_W=40; PANE_ROWS=6; CALLOUT_W=44; PANE_MODE=row; WIN_GAP=1
_metrics() {
    if   (( FT_ROWS < 32 ));                     then PANE_MODE=line
    elif (( FT_COLS >= 118 ));                   then PANE_MODE=side
    # A BOXED PANE COSTS SEVEN ROWS, AND UNDER ~38 ROWS — OR ~80 COLUMNS — THE STAGE CANNOT
    # AFFORD THEM. Stacked, the pane is title + border + PANE_ROWS + border; at 84×34 that is 7
    # of the 26 rows inside the frame, and it leaves the stage 9. A callout box is 6–8 rows, so
    # no band above or below the stage's controls could hold one and every placement was
    # squeezed into the 20-column side margins — where the only shape that fits is narrow and
    # tall, and where the controls are. MEASURED over all 43 steps at 84×34: 208 cells of other
    # controls painted over, one leader crossing its target, one leader with no line at all.
    # Same sweep with the one-line call instead: 17 cells, and with the wider callout below
    # it, 0. The pane is the nicer thing to look at and the placement is the thing the demo is
    # FOR.
    #
    # THE COLUMN RUNG IS MEASURED THE SAME WAY, over all 43 steps, boxed pane vs one-line:
    #     62×40   1175 covered cells, 3 leaderless   →   330, 0
    #     70×40    861 covered cells, 4 leaderless   →   340, 0
    #     78×40    188 covered cells, 2 leaderless   →     3, 0
    #     84×40      2 covered cells, 0              →     1, 0
    # Under 80 columns the boxed pane starves the stage sideways exactly as short screens starve
    # it vertically — page 7's drag step at 62×40 was the reported case: the callout had no room
    # for a line at all AND sat on two other controls, with the pane holding six rows above it.
    elif (( FT_ROWS <  38 || FT_COLS < 80 ));    then PANE_MODE=line
    elif (( FT_COLS <  92 ));                    then PANE_MODE=one
    else                                              PANE_MODE=row; fi
    if [[ "$PANE_MODE" == side ]]; then
        # Six rows is exactly the height of the generated call below, so the pane shows it whole
        # wherever there is room; under that it scrolls (it is a real, focusable, scrollable box).
        PANE_ROWS=6; (( FT_ROWS < 38 )) && PANE_ROWS=5
        # 44 is the longest line the generated call can produce, so at a wide terminal the
        # snippet is never clipped — the point of showing it is that it can be copied.
        PANE_W=44; (( FT_COLS < 134 )) && PANE_W=40
        CONCEPT_W=$(( FT_COLS - 12 )); (( CONCEPT_W > 140 )) && CONCEPT_W=140
    else
        CONCEPT_W=$(( FT_COLS - 12 )); (( CONCEPT_W > 86 )) && CONCEPT_W=86; (( CONCEPT_W < 44 )) && CONCEPT_W=44
        PANE_W=$(( (CONCEPT_W - 3) / 2 - 2 )); (( PANE_W > 44 )) && PANE_W=44; (( PANE_W < 20 )) && PANE_W=20
        PANE_ROWS=5; (( FT_ROWS < 36 )) && PANE_ROWS=4
        # One pane at full width when two would be thirty columns each and clipped mid-word. The
        # one that has to survive is the CALL: it is the only thing on screen that says what
        # produced the box you are looking at. The commentary pane is the part you can lose.
        [[ "$PANE_MODE" == one ]] && PANE_W=$(( CONCEPT_W - 2 ))
    fi
    # On a short terminal the FIVE inter-row gaps in the frame's column are five rows the stage
    # could have had, and the stage is the only part of this demo the placer can use. Closing
    # them up is what keeps 80×30 drawing a callout beside its target instead of on top of it.
    WIN_GAP=1; (( FT_ROWS < 34 )) && WIN_GAP=0
    # The callout's TEXT wrap width. The placer rewraps NARROWER still when that is the only
    # shape that fits, so this is a ceiling, not a size.
    #
    # IT DOES NOT KEEP SHRINKING WITH THE TERMINAL, and the third rung this used to have
    # (`FT_COLS < 92 → 32`) was making the small screens worse, not better. The free space on a
    # cramped screen is SHORT AND WIDE — the bands above and below the stage's controls — and a
    # narrow ceiling produces a tall chip, which fits none of them and has to go in the side
    # margins on top of a control. Swept over all 43 steps, holding everything else equal:
    #
    #        calloutWidth   32     34     36     38     40     42     44
    #   80×30  covered     897    839    208    212    267    203    212   cells
    #          crossings    11      5      0      0      0      1      1
    #   84×34  covered      17    131      1      0      0     45      4
    #          crossings      1      1      0      0      0      0      0
    #
    # 38 is the only value that is clean at both, and it is what the 92–111 column band already
    # used, so the rung simply goes away.
    CALLOUT_W=44; (( FT_COLS < 112 )) && CALLOUT_W=38
    (( CALLOUT_W > CONCEPT_W - 4 )) && CALLOUT_W=$(( CONCEPT_W - 4 ))

    # ── THE COMPASS PAGE BUYS ITS FOUR BANDS BACK ────────────────────────────
    # Page 2 teaches the nine points of a rectangle, and eight of those nine need a CHIP-SIZED
    # BAND on the side they name. That is a demand on the LAYOUT, not on the placer, and the
    # shared layout above does not meet it on a small screen. Measured, before this branch:
    #
    #   84×34  band above the target: 3 free rows against a chip 6 rows tall. anchor=topCenter
    #          therefore had nowhere above to go — the placer parked the chip UNDERNEATH and ran
    #          the leader straight up THROUGH the target to reach its top edge (5 crossed cells,
    #          and the chip landed on the step nav). topLeft, topRight and centerRight the same.
    #   120×40 PANE_MODE=side puts the stage in the left 63 columns, so the band LEFT of the
    #          target came out 17 columns wide against 63 on the right. anchor=centerLeft could
    #          not be honoured: the chip went below and took a 4-turn, 46-cell leader to get back.
    #
    # Same class of bug as the one already fixed at 171×45 by moving the panes beside the stage.
    # So this page takes a layout of its own AT EVERY SIZE — consistency is worth something on a
    # page whose whole subject is where things sit — and each rung buys a specific band:
    #   · the boxed call pane collapses to its ONE-LINE form.  Worth 6 rows of the 26 the frame
    #     has at 84×34, split between the band above the target and the band below it. This page
    #     can afford it: its callout sentence names its own anchor, and so does the one-liner.
    #   · the stage spans the FULL width instead of half of it, so LEFT and RIGHT come out equal.
    #   · the concept paragraph is two lines rather than four.
    #   · the chip is allowed to be WIDER here, not narrower. The bands above and below are short
    #     and wide, and wrapping the same sentence wider makes it SHORTER IN ROWS — which is the
    #     dimension that is scarce. (The placer still rewraps it narrow for the left/right bands;
    #     calloutWidth is a ceiling, not a size.)
    # PAGE 8 GIVES UP ITS CODE PANES FOR THE SAME REASON PAGE 2 DOES, and a stronger one: its
    # specimen is a BIG ARROW, thirty columns by six rows at the default size, and the panes take
    # forty columns out of the middle of the stage. With them the arrow had nowhere to go but on
    # top of the step callout; without them the stage is the full width and the arrow gets a lane
    # of its own down one side of it. The rest of page 2's block below is page 2's own measured
    # tuning and is deliberately not shared.
    if (( PAGE == ARROW_PAGE )); then
        PANE_MODE=line
        CONCEPT_W=$(( FT_COLS - 12 )); (( CONCEPT_W > 140 )) && CONCEPT_W=140
    fi
    if (( PAGE == COMPASS_PAGE )); then
        PANE_MODE=line
        CONCEPT_W=$(( FT_COLS - 12 )); (( CONCEPT_W > 140 )) && CONCEPT_W=140
        # 54, not the 48 this first had, for a reason that is entirely about the LADDER: the
        # narrowest shape the engine can reach is maxw/3 + 4, and the band beside an 18-column
        # specimen inside a 72-column stage is 23 usable columns once the leader has its three.
        # 48 → narrowest box 20 → 16 columns of text, and `anchor=centerLeft` is 17, so the chip
        # broke the word it exists to name (`anchor=centerLef` / `t`). 54 → narrowest box 22 →
        # 18 columns, and it fits. Nothing else on this page changes shape: the sentences still
        # wrap to two lines above and below.
        CALLOUT_W=54
        # …and on a SHORT screen it comes back DOWN, because one calloutWidth has to serve two
        # bands of opposite shape and the shorter screen tightens the one that is scarce:
        #
        #   the band ABOVE at 80×30 is 70 columns by 7 rows, and the leader wants 3 of them, so
        #   the chip has to be 4 rows — two lines of a ≤100-character sentence. That is the
        #   FLOOR on the width.  Measured at 64: the tops were fine and BOTH side anchors went
        #   below instead, because the ladder's narrowest box is maxw/3 + 4 = 25 and the band
        #   beside the target is 23.
        #   the band LEFT is 23 columns, which is the CEILING: maxw ≤ 57 or nothing fits beside
        #   the target at all.
        #
        # Measured across the whole page at 80×30 — 44 was the value with zero crossings, zero
        # stubs and all nine anchors on the side they name. It only became reachable once the
        # concept paragraph came down to one line, which gave the band above its seventh row;
        # at 56, with the same one-line concept, centerLeft and centerRight still went below.
        (( FT_ROWS < 34 )) && CALLOUT_W=44
        (( CALLOUT_W > CONCEPT_W - 4 )) && CALLOUT_W=$(( CONCEPT_W - 4 ))
        (( CALLOUT_W < 26 )) && CALLOUT_W=26
        WIN_GAP=0; (( FT_ROWS >= 42 )) && WIN_GAP=1
    fi
}

# ── Per-page STEP annotations ─────────────────────────────────────────────────
# _page_annotations fills four parallel arrays for the CURRENT page: the control each step
# points at, the callout's `place` and `anchor` for that step, and the sentence it shows.
# Step N gets the circled-number badge N and a callout pointing at its control; the step count
# per page is just ${#PA_TARGET[@]}.
#
# PLACE IS `auto` EVERYWHERE EXCEPT PAGE 3, the page that teaches what place= does. That is
# the demo's own rule and it is deliberate: naming a side is how you tell the engine you know
# better than it does about free space, and outside a lesson about the property itself, you
# don't. Every placement on the other six pages was searched for, not asked for — including
# the ones that come out awkward, which is the honest way to show a placer off.
declare -a PA_TARGET=() PA_PLACE=() PA_ANCHOR=() PA_TEXT=() PA_ARROW=()
# arrow="…" is the fifth column, and it belongs HERE rather than in a second table keyed by page
# and step. A step is one row — which control, which side, which anchor, what it says, and now
# whether it also gets shouted at — and the reason that matters is page 6's hard-won rule: the
# sentence must name what is on the screen. Keeping the arrow in the same row as the sentence is
# what makes "did I describe this?" a thing you can see rather than a thing you have to check.
# Its value is the extra properties the ft-beacon call gets, so a step can name a size, a border
# colour or an exit without this function growing a parameter per property.
_ann() {                        # _ann TARGET [place=…] [anchor=…] [arrow="props…"] TEXT
    local tgt=$1; shift
    local pl=auto an=auto ar=""
    while (( $# > 1 )); do
        case "$1" in place=*)  pl=${1#place=} ;;
                     anchor=*) an=${1#anchor=} ;;
                     arrow=*)  ar=${1#arrow=} ;; esac
        shift
    done
    PA_TARGET+=("$tgt"); PA_PLACE+=("$pl"); PA_ANCHOR+=("$an"); PA_TEXT+=("$1"); PA_ARROW+=("$ar")
}
_page_annotations() {
    PA_TARGET=(); PA_PLACE=(); PA_ANCHOR=(); PA_TEXT=(); PA_ARROW=()
    case "$PAGE" in
    1)  _ann share    "target=share, text=… — those two facts ARE the callout. It is an ft-beacon with variant=callout: this box, its line and its arrowhead."
        _ann btnMount "No coordinates appear anywhere. place=auto asked the screen for its unclaimed rectangles, fitted the callout in one, and covered nothing."
        _ann chkRO    "The line is ROUTED, not ruled: it leaves the callout square to a border, bends as few times as it can, and stops one cell clear of the control."
_ann note1    "A callout is an OVERLAY — out of the layout flow, nothing reflows around it, never focusable, and composited last so it is never painted over." ;;
    # THE SENTENCES ON THIS PAGE ARE THE SHORTEST IN THE TOUR, ON PURPOSE. A chip's height is
    # its sentence's length divided by its wrap width, and this page is the one that has to fit
    # a whole chip in the band above its target AND in the band below it. The originals ran to
    # 130–195 characters; at 80×30 that is a 7-row chip against a 6-row band, and the placer's
    # honest answer to "no room above" is to put the chip below and cross the target — which is
    # what it did. THE HUNDRED-CHARACTER CEILING BELOW IS LOAD-BEARING: it is what lets these
    # wrap to TWO lines at the calloutWidth this page can afford (see the window calculation in
    # _metrics), and a longer sentence here reopens the bug at 80×30. test-callout-demo measures
    # it rather than trusting this comment.
    2)  _ann compass anchor=auto         "anchor=auto, the default: the head goes to the MIDDLE of whichever side the callout took."
        _ann compass anchor=topLeft      "anchor=topLeft parks the head above the target's top-LEFT corner: 'this corner', not 'this control'."
        _ann compass anchor=topCenter    "anchor=topCenter — the middle of the top edge: auto's answer when the callout lands above."
        _ann compass anchor=topRight     "anchor=topRight. The head slid to the far end of the same edge; the callout did not follow it."
        _ann compass anchor=centerLeft   "anchor=centerLeft — the middle of the LEFT edge. A side anchor picks the SIDE too: callout left."
        _ann compass anchor=centerRight  "anchor=centerRight, its mirror. The glyph always points INTO the control: ▶ from left, ◀ from right."
        _ann compass anchor=bottomLeft   "anchor=bottomLeft. The head sits one row under the bottom-LEFT corner, so the leader comes up to it."
        _ann compass anchor=bottomCenter "anchor=bottomCenter — the middle of the bottom edge: auto's answer when the callout lands below."
        _ann compass anchor=bottomRight  "anchor=bottomRight, last of the eight. Four corners, four edge middles: any rectangle's compass."
        _ann compass anchor=centerCenter "anchor=centerCenter is the ONE head allowed to sit ON the target. For the other eight, nothing does." ;;
    # PAGE 3 IS THE SECOND PAGE WHOSE LESSON IS A SIDE, so it lives under the same ceiling as
    # page 2 and for the same measured reason. A page that says "place=above pins the chip over
    # #hub" and then shows it below is not teaching, it is contradicting itself in front of the
    # reader — and `place=` is only a bias, so the engine is right to overrule a side with no
    # room and the LAYOUT is what has to provide the room. At 84×34 with the old 130–166
    # character sentences the chip came out 7 rows against a 7-row band, leaving nothing for a
    # leader: steps 2, 3 and 4 were all placed below or right whatever they said. ≤ 112
    # characters wraps to 3 lines, the chip is 5 rows, and all four sides can be honoured.
    # THESE FIVE SENTENCES ARE PROMISES, AND A PROMISE IS ONLY SHOWN KEPT. place= is a bias, not
    # an order — that is this page's whole lesson — so on a small enough screen the engine will
    # rightly overrule a named side, and a callout that then still said "the head turns to ▶"
    # while sitting underneath its target would be lying about the very thing it teaches
    # ("all lies", read a user at 62×40, fairly). So every side-naming promise hedges itself
    # with "space permitting" — the honoured wording already admits the bias — and
    # _p3_reconcile below reads the side the engine ACTUALLY chose after every placement and
    # swaps in _p3_overrule's sentence whenever it differs, which names BOTH sides: the one
    # asked for and the one the engine gave. The overrule stops being a contradiction and
    # becomes the lesson's best possible demonstration: you asked, it weighed the room, it
    # said no — and told you where it went instead.
    3)  _ann hub place=auto   "place=auto is the default, and this is what it chose. Every placement so far was found this way."
        _ann hub place=above  "place=above lifts the callout above #hub, space permitting, and the head becomes a ▼ on its top edge."
        _ann hub place=below  "place=below drops the same callout underneath, space permitting, and the head flips to ▲. One word did it."
        _ann hub place=left   "place=left, space permitting: the head turns to ▶, into the target as ever. A thin margin makes it tall."
        _ann hub place=right  "place=right, space permitting. A preference is a BIAS, not an order: hide too much and you are overruled."
        _ann crowdC           "Back to auto, on a checkbox with neighbours either side: auto found the band with room by itself." ;;
    4)  _ann tfHost     "A textfield's rect includes its BORDER, so the head lands on the frame and never on the text inside. Every control is measured the same way."
        _ann btnScan    "A button is one row tall. Vertical padding is a step tighter than horizontal — a cell is twice as tall as it is wide — so ▲▼ sit closer than ◀▶."
        _ann chkDeep    "Nothing was added to this checkbox to make it pointable. The callout named it; the placer read its rectangle straight out of the layout."
_ann selProto   "A dropdown is targeted by its closed box. The arrow is the only thing saying WHICH control the sentence is about — which is why this beats a numbered list."
        _ann sldWorkers "A slider is wide and one row tall, and that SHAPE hems a callout in sideways far more than its type does. Placement answers to geometry, not class."
        _ann lblStat    "A plain label works too: a target need not be focusable, interactive, or even chrome. If the layout gave it a rectangle, it can be pointed at."
        _ann tblShares  "A table is ONE control however many rows it draws, so the arrow means the whole block. A tree is the same: no single row has a name to aim at." ;;
    5)  _ann badgeT  "number= stamps a circled ①..⑳ into the top border, drawn in the EDGE colour so it belongs to the frame. Here it is the step number — which is how a badge earns its place."
        _ann wrapT   "calloutWidth= is the TEXT wrap width: the callout comes out four columns wider than it. Ask for less and the same sentence gets taller and slimmer."
        _ann padT    "arrowPadding= is the blank gap the head keeps from the target (1 by default). The vertical gap is one less again, so ▲▼ never appear to float away."
        _ann nextT   "onNext=fn draws the clickable ▶ in this callout's top-right border and wires its 'next' event to fn. That ▶ up there is live: click it. The ⊠ beside it is live too — it closes this callout."
        _ann outsetT "outset= inflates the rect the callout treats as the target, so the head stands that many cells further out — as though the control were a size bigger." ;;
    # PAGE 6 NAMES WHAT IS ON THE SCREEN, AND ONLY WHAT IS ON THE SCREEN. It used to keep a
    # halo, a dashed ghost and a stray circled ⑥ up on all five steps, on five different
    # buttons, whatever the step was about — so nothing ever changed when you stepped, the
    # sentence never said which of the three marks it meant, and the step callout's leader
    # threaded BETWEEN them (a beacon's rule is painted outside the layout, so the router
    # cannot see it and will draw straight through one). Two boxes now, at most two marks, and
    # every sentence names its box by the label printed inside it.
    # …and they are held to about 130 characters for the same reason page 2's are held to 100:
    # a chip that will not fit the band above or below its target gets rewrapped narrow, and at
    # a third of the ceiling the wrap starts breaking words — `variant=fram/e`, `frameStyle=d/
    # ashed`. A sentence that has to be reassembled across a line break is not legible, which is
    # the whole complaint this page is answering.
    6)  _ann specA "Box A wears a beacon and Box B does not. variant=frame rules a heavy border one cell outside the control — no text, no leader."
        _ann specB "Both are ringed now, and one property differs: Box B adds frameStyle=dashed, so its rule is light, rounded and broken."
        _ann specB "Both rings are gone. variant=number draws only the circled ⑨ in Box B's top-right corner; corner= takes all four and center."
        _ann specA "One ring again on Box A, and it is breathing: effect=pulse walks its colour along the --beacon ramp. blink and bob MOVE it."
        _ann specB "Two rings were raised here. Box A's is lifetime=persist and stays; Box B's is lifetime=oneshot — watch it play its laps and go." ;;
    # ONE SPECIMEN, FIVE STEPS, exactly like pages 2, 3 and 6: the page walks one property
    # across a fixed target, so pointing at the same box every step IS the lesson rather than
    # five different things to keep track of. Sentences held to ~135 characters, page 6's
    # ceiling, for page 6's reason — a chip that will not fit the band beside its target gets
    # rewrapped narrow, and at a third of the ceiling the wrap starts breaking words.
    8)  _ann arrowBox arrow="place=left lifetime=persist" \
                      "One arrow, two hundred cells of it. It flies in along its own axis and OVERSHOOTS — that rebound is the whole of why it reads as a cartoon."
        _ann arrowBox arrow="place=left lifetime=persist size=small" \
                      "size names the shape. There are four, drawn by hand: this is the smallest, and it is the same drawing at every terminal size."
        _ann arrowBox arrow="place=left lifetime=persist size=medium" \
                      "size=medium, one rung up. Nothing stretches to get here — a rung the room cannot hold is not drawn at all, which is what stops it deforming."
        _ann arrowBox arrow="place=left lifetime=persist borderColor=226" \
                      "border-color paints the SILHOUETTE — the outermost cells of the shape itself, never a box round it. Unset, it is this arrow's own colour, shaded."
        _ann arrowBox arrow="place=left exit=retract" \
                      "And it leaves. lifetime=oneshot is this variant's default: hold a beat, whip back out the way it came, and repair every cell it covered."
        _ann arrowBox arrow="place=left exit=fade animationTimingFunction=ease-out-back,linear" \
                      "exit=fade dissolves it in place instead. Both are built; retract is the default, because a fading arrow is a big dim smudge for its last third."
        _ann arrowBox arrow="place=left lifetime=persist smoothing=solid" \
                      "smoothing=solid rounds the same drawing to whole cells of █ — the naive way, kept so it can be looked at. Error 24.94 sub-cells against 3.45." ;;
    7)  _ann regionsBtn "Free space FIRST: the callout is offered every unclaimed rectangle on the screen, the way an allocator offers blocks, so one that fits covers nothing at all."
# THERE IS NO ARROW ON THIS STEP, AND THAT IS A MEASUREMENT RATHER THAN AN OMISSION. A
        # bigarrow was tried here — the one step in the tour whose lesson is about the target
        # being sacred, so a giant thing shouting at it while the chip stays off it would have
        # been the cost model in one picture. Every side of this stage buries between 23 and 100
        # cells of real control at every supported size (the stage is dense on purpose; that is
        # page 7's own subject), and the placer now refuses rather than lying across a textfield.
        # The same held for every other step of the tour: outside page 8, whose layout is built
        # around a lane for it, there is nowhere in this demo a hand-drawn arrow fits cleanly.
        _ann targetBtn  "It will not sit on its own target while any alternative exists — that is priced at 100000 a cell, against 5000 for covering anything else."
        _ann crossBtn   "The LINE is scored too: a crossed cell costs the same order as a covered one and each bend about as much again, so a wandering line loses to a moved callout."
        _ann chromeBox  "It also keeps off the docked chrome — the key legend and status bar under this frame — wherever it has anywhere else at all to go."
        # SELF-REFERENTIAL ON PURPOSE, AND SHORT ON PURPOSE. This step's earlier text said "drag
        # this chip", and a reader at 62×40 — where the callout had drawn no arrow at all — took
        # it as an instruction to drag the CHECKBOX it stood beside. Nothing but the text says
        # which box is the draggable one, so the text points at itself. The dashed outline it
        # names is the :dragging ghost a grabbed callout becomes — the one visual the reader
        # sees mid-drag that nothing else on the page explains. And it is held to ≤102
        # characters because the drag lesson NEEDS a visible arrow to demonstrate re-attaching:
        # the stage's free band below the checkboxes is 5 rows at 56×38, and 102 characters is
        # what wraps to three lines — a 5-row box — at every width the search will try there.
        # At 112 it wrapped to four, missed the band by one row, went ABOVE instead and drew
        # its line straight through the textfield en route; at 150 it fit nowhere at all and
        # was rewrapped into a 17-row column that sat on three controls with no arrow at all.
        _ann dragChk    "Drag THIS box you are reading: it moves as a dashed outline, the arrow re-attaching; R sends it home."
        _ann boundChk   "boundBox=NAME confines the whole callout inside that control's interior. Unset, it may use the screen margin — on a wide terminal, most of the free space there is." ;;
    esac
}

# ── The callout the current step raises ───────────────────────────────────────
# parent=lower puts it in the stage subtree; callouts are z=10 among overlays, so it is
# composited last and nothing — not even another beacon — paints over it.
#
# ONE GLYPH, ONE MEANING. onNext gives the chip a clickable ▶, and it used to mean "advance" —
# the next STEP normally, and the next PAGE on a page's last step. Two meanings on one glyph, and
# a reader told us what that reads as: "I thought it meant there are more steps, but then it
# showed up on the last steps of each page." He was reading it correctly; the demo was saying
# two things with one symbol. Now ▶ means exactly one thing — there is another step on THIS page
# — and moving between pages is the Okay button and the N key, which the legend already names.
_place_callout() {
    local i=$(( STEP - 1 ))
    local onnext=""
    (( STEP < ${#PA_TARGET[@]} )) && onnext=btnStepNext_on_activate
    ft-beacon name=stepcallout parent=lower variant=callout \
              target="${PA_TARGET[$i]}" \
              place="${PA_PLACE[$i]}" anchor="${PA_ANCHOR[$i]}" \
              number="$STEP" calloutWidth="$CALLOUT_W" effect="$CALLOUT_EFFECT" outset=0 \
              onNext="$onnext" \
              text="${PA_TEXT[$i]}"
}
# ── PAGE 3 MUST NEVER LIE ────────────────────────────────────────────────────
# place= is a BIAS, and on a small enough screen the engine will overrule a named side — which
# is this page's own lesson, so the overrule is not a failure to hide, it is the thing to show.
# What must never happen is the callout still carrying the PROMISE sentence while sitting on
# the side it was refused: at 62×40 step 4 said "place=left, and the head turns to ▶" from
# UNDERNEATH the target. So after every placement the achieved side is read back off the
# engine's own record (FT_BEACON_PC's first field — the side the leader really left from) and,
# when it differs from the request, the sentence is swapped for one that teaches the overrule.
#
# The overrule sentence names BOTH sides — the one asked for and the one the engine chose.
# Naming the achieved side puts it into the text, the text into the placement key, and the
# placement key back into the achieved side — a cycle whose fixed point has to be ENGINEERED,
# not hoped for: every wording a step can show (its promise plus each of the three possible
# overrules) wraps to the SAME line count at every width the placement search will try
# (calloutWidth and its 2/3, 1/2, 1/3 ladder rungs — see _shape in ft-beacon). Same height ⇒
# same box shape ⇒ the text swap cannot move the box, so the side read back after the swap is
# the side that was just named. test-callout-demo measures the equal heights with ft_wrap and
# replays every step twice, asserting the second placement is byte-identical.
_p3_overrule() {    # requested-side achieved-side → FT_RET = the sentence that teaches the overrule
    local side
    case "$1" in left)  side="the left side" ;;
                 right) side="the right side" ;;
                 *)     side="the side $1" ;; esac
    FT_RET="place=$1 asks for $side, space permitting — not enough room here, so it went $2 instead."
}
# Re-read the achieved side and swap the sentence if the two disagree.
#
# THIS RAN FROM THE FIRST DAY AND NEVER ONCE FIRED, which is worth more than the fix. Placement
# is computed AT PAINT, this runs from the step handler, and the step handler deliberately does
# not paint (the run loop settles the burst). So `ft_beacon_side` had nothing to answer with, the
# `|| return 0` below took every call, and the page kept shipping the contradiction this function
# was written to prevent — measured at 62x40, step 4: asked `left`, engine chose `above`, sentence
# still said left. A fix that cannot run is indistinguishable from no fix, and only a probe that
# asked "did it actually change the text" could tell the difference.
#
# `ft_beacon_place` is the engine answering "where will it go" without a frame. It fills the same
# cache the paint consults, so the paint that follows re-searches nothing.
#
# ONE PASS, NO RETRY LOOP. There used to be a `tries < 3` cap around this, because the side could
# be read STALE — the loop was guarding against the very ordering that is now fixed. The swap
# cannot move the box: the wordings are engineered to identical line counts at every width the
# search tries (see _p3_overrule), so the box shape, and therefore the side, is the same before
# and after. That was an assumption; it is measured now, over every overruled step at five
# terminal sizes, and tests/test-callout-demo.bash asserts it.
_p3_reconcile() {
    (( PAGE == 3 )) || return 0
    local i=$(( STEP - 1 ))         # NB separate lines — `local a=$1 b=${arr[$a]}` reads the OLD a
    local requested=${PA_PLACE[$i]:-auto} achieved current wanted
    [[ "$requested" == auto ]] && return 0
    # Place it NOW. Without this the question below has no answer yet.
    ft_beacon_place stepcallout || return 0
    # ft_beacon_side is the ENGINE'S answer to "which side did place=auto actually choose".
    # This used to `read` the first field of FT_BEACON_PC — an internal packed cache — which
    # made a demo depend on the order of fields in an implementation detail.
    ft_beacon_side stepcallout || return 0
    achieved=$FT_RET
    if [[ "$achieved" == "$requested" ]]; then wanted=${PA_TEXT[$i]}
    else _p3_overrule "$requested" "$achieved"; wanted=$FT_RET; fi
    ft_resolved_prop stepcallout text ""; current=$FT_RET
    [[ "$current" == "$wanted" ]] || ft-modify stepcallout text="$wanted"
    return 0
}
# ── Page 6's SPECIMENS — the marks the page is about, raised one lesson at a time ────────────
# These are themselves beacons: the halo, the dashed ghost and the bare badge. Removed by NAME
# before being rebuilt — a beacon paints outside its own (zero-size) layout box, so the layout
# alone can never clean one up, and ft_remove is what gives those cells back.
#
# THIS FUNCTION IS STEP-AWARE, AND THAT IS THE WHOLE FIX FOR PAGE 6. It used to raise all three
# marks on all five steps: a reader stepping through saw the same three decorations every time,
# so nothing ever visibly changed, the step's sentence never said which mark it was talking
# about, and — because a beacon's rule is painted OUTSIDE the layout, where the leader router
# cannot see it — the step callout's line was routed straight through two of them. Reported as
# "pure chaos … I can't even tell what's a bug and what's not", which was a fair reading: the
# screen contained four beacons and named none of them.
#
# So: at most TWO marks, both named in the step's own sentence, and each step changes what the
# specimen boxes look like. The router still cannot see a rule, but with nothing on screen that
# the sentence does not mention, there is nothing left for a leader to cut through by surprise.
_place_variants() {
    local n ext
    for n in specRingA specRingB specBadge; do
        [[ -n "${FT_TYPE[$n]:-}" ]] || continue

        ft_remove "$n" 2>/dev/null
    done
    (( PAGE == VARIANT_PAGE )) || return 0
    [[ -n "${FT_TYPE[specA]:-}" ]] || return 0     # the page is not built yet
    # pulse cycles COLOUR only, so the glyphs never move — a breath, not a strobe. Step 4 is the
    # one that asks for it, and it is the only animated thing on the page; every other step is
    # static, so the event loop idles between keystrokes exactly as it does everywhere else.
    case "$STEP" in
    1)  ft-beacon name=specRingA parent=lower target=specA variant=frame effect=none outset=1 ;;
    2)  ft-beacon name=specRingA parent=lower target=specA variant=frame effect=none outset=1
        ft-beacon name=specRingB parent=lower target=specB variant=frame effect=none outset=1 frameStyle=dashed ;;
    3)  ft-beacon name=specBadge parent=lower target=specB variant=number effect=none number=9 corner=topright outset=1 ;;
    4)  ft-beacon name=specRingA parent=lower target=specA variant=frame effect=pulse outset=1 ;;
        # The oneshot is REAL, not narrated: it plays its laps and then ft_remove's itself, so a
        # reader who steps here watches Box B's ring go while Box A's stays. A demo that only
        # SAID that would be the sort of thing the reader cannot tell from a bug.
    5)  ft-beacon name=specRingA parent=lower target=specA variant=frame effect=none outset=1 lifetime=persist
        ft-beacon name=specRingB parent=lower target=specB variant=frame effect=blink outset=1 lifetime=oneshot cycles=3 ;;
    esac
    return 0
}

# ── The ARROW a step raises, if its annotation row asks for one ──────────────
# The same shape as _place_variants and for the same reasons: torn down and rebuilt on every
# step so the step's own sentence describes what is on the screen, and so that STEPPING ONTO A
# STEP REPLAYS THE FLIGHT — which is how a reader watches the exit happen more than once
# without the page needing a key of its own.
#
# IT USED TO BE PAGE 8'S ALONE, with the page number and a `case $STEP` hard-coded here. It is
# now whatever the step's annotation row says (PA_ARROW), which is what let the arrow become a
# real callout device on two other pages instead of a specimen on one — see the notes beside
# those two rows for why THOSE two steps and not the other twenty-nine.
#
# boundBox=lower is doing real work, not decoration. It confines the whole arrow to the stage
# frame, so it CANNOT reach the concept paragraph above it or the step chrome below it however
# the placement search scores. The engine's burial term keeps it off the specimen and the chip
# INSIDE that box; the bound keeps it off the page's own text, by construction rather than by
# a cost model that could be argued with.
#
# EVERY ARROW IN THIS DEMO NAMES ITS SIDE. The arrow and the step callout are two overlays
# wanting the same free band, and each avoids the other's published ink — so with both on auto,
# WHO PLACES FIRST WINS THE GOOD LANE, and that is decided by z-order and by whether a cache
# happened to be warm. Measured at 118×40 on the arrow page: placed with no chip on screen the
# arrow takes the lane down the left; re-placed after a resize, with the chip already there, the
# same call yields a stub pointing up (candidate dump: right/left both bury 40-44 cells, up
# buries 0). Both are defensible answers to different questions, which is exactly the problem —
# the page looked different depending on how you got to it. The arrow is the SUBJECT of the step
# that raises it, so it gets the lane deterministically; the chip works around it, which it does
# well because a bigarrow publishes its LANDED rect.
_place_arrow() {
    if [[ -n "${FT_TYPE[specArrow]:-}" ]]; then
        # Just remove it. ft_remove gives the cells back — the arrow's erase record is exact and
        # ft_damage_subtree asks the prototype for it (see _ft_ink_beacon). This used to call
        # _ft_bigarrow_damage_all first, a PRIVATE function, because a bigarrow's ink is not its
        # extent and an app has no way to know that. An app should never have known that.
        ft_remove specArrow 2>/dev/null
    fi
    local i=$(( STEP - 1 ))
    local spec=${PA_ARROW[$i]:-}
    (( ${#spec} )) || return 0
    local target=${PA_TARGET[$i]}
    [[ -n "${FT_TYPE[$target]:-}" ]] || return 0          # the page is not built yet
    # `spec` is deliberately unquoted: it is the step's own list of properties, written in this
    # file three screens up, and splitting it into words is the whole point.
    ft-beacon name=specArrow parent=lower target="$target" boundBox=lower variant=bigarrow $spec
    return 0
}

# ── Titled read-only code panes (Enter-to-edit: focus to scroll, never traps keys) ──
_code_panel() {                 # name title text
    ft-div name="${1}Pane" display=flex flexDirection=column gap=0 alignItems=start
        ft-label     name="${1}Title" color=accent "$2"
        ft-textfield name="$1" value="$3" readOnly=true wrap=false size="$PANE_W" rows="$PANE_ROWS"
    end_ft_div
}

# ── Per-page teaching content ─────────────────────────────────────────────────
# title + CONCEPT + NOTE are per PAGE; CALL is per STEP — the left pane shows the EXACT
# ft-beacon call that drew the box currently on screen, generated from the same annotation row
# the beacon itself was built from, so the pane cannot drift from the picture.
_page_content() {
    local i=$(( STEP - 1 ))
    case "$PAGE" in
    1)  title="1 · What a callout is"
        CONCEPT="A callout says ONE thing about ONE control. You give it two facts — target= (which control) and text= (what to say); the engine finds room the box can occupy without covering anything, routes a line to that control, and caps it with an arrowhead."
        NOTE='# the stage is ordinary controls — not one
# of them knows a callout exists:
ft-textfield name=share     size=20
ft-button    name=btnMount  "Mount"
ft-checkbox  name=chkRO     "Read-only"
# …the callout is declared afterwards.' ;;
    2)  title="2 · anchor — the nine points of a control"
        # ONE line, not four. On this page a row of prose is a row the band above the target does
        # not get, and that band is the lesson: measured at 80×30, the four-line paragraph left
        # 6 free rows above the target against a chip 5 rows tall plus a leader, so `topCenter`
        # had to be drawn from underneath THROUGH the target. One line leaves 7 and it is drawn
        # from above. Held under 68 characters so it stays one row even at the narrowest width
        # the demo supports; the nine sentences that follow carry the detail.
        CONCEPT="place= picks the callout's SIDE. anchor= picks one of nine points."
        NOTE='#  topLeft    topCenter    topRight
#  centerLeft centerCenter centerRight
#  bottomLeft bottomCenter bottomRight
#
# auto = middle of the side it landed on
# centerCenter may sit ON the target' ;;
    3)  title="3 · place= — a preference, not a command"
        # Two lines, for page 2's reason: this page also has to keep a chip-sized band on all
        # four sides of #hub, and a paragraph row comes straight out of the band above it.
        # "callout" is three characters longer than the jargon this used to say, and at 56
        # columns CONCEPT_W is 44 — so the four sides had to come out of the sentence to keep
        # it at two lines there. The five step sentences each name their side anyway.
        CONCEPT="place= names the side you would LIKE the callout on — or auto, the default."
        NOTE='# the ONLY page here that names a side —
# everywhere else the call reads auto.
#   above   callout on top,     head ▼
#   below   callout underneath, head ▲
#   left    callout leftward,   head ▶
#   right   callout rightward,  head ◀' ;;
    4)  title="4 · Any control can be the target"
        CONCEPT="A target is a control NAME, and every control has a rectangle, so anything on the screen can be pointed at. The rect is re-read on every paint, so a target that moves, resizes or is rebuilt keeps its arrow without the callout being touched."
        NOTE='# the rect a callout points at, re-read
# on every single paint:
#   FT_ABSOLUTE_X/Y[t]        where it is
#   FT_MEASURED_WIDTH/HEIGHT  how big it is
# …grown by outset= cells. Not laid out yet?
# Then it draws nothing rather than guess.' ;;
    5)  title="5 · The callout's own chrome"
        # THIS PAGE'S PROSE IS LOAD-BEARING, and the unit is WRAPPED ROWS, not characters. The
        # concept label sits above the stage and the note is a code pane beside it, so either one
        # gaining a row shifts every target under it — and the placements with them. Measured:
        # naming `closable=` in the concept sentence cost SIX corpus defects, all on this page and
        # none anywhere else; two rounds of "tighter" wording made it three, then four, because a
        # shorter line moves the layout just as surely as a longer one, and because BOTH strings
        # had been edited while only one was being tuned.
        #
        # So neither is edited. `closable=` is taught in the step annotation for the ▶/⊠ step
        # (see _ann nextT), which is the callout's OWN text: it changes that one chip's shape and
        # nothing else on the page. A demo teaches by pointing at the thing, and the ⊠ is already
        # on screen in every chip here.
        CONCEPT="Everything the callout itself shows is a property: number= stamps a circled badge into the top border, calloutWidth= sets where the TEXT wraps, arrowPadding= is the gap the head keeps, onNext= adds a clickable ▶, and outset= grows the rect being pointed at."
        NOTE='#  ╭①───────────▶╮  ① number= · ▶ onNext=
#  │ wrapped text │  calloutWidth = this
#  ╰──────────────╯  (box = text + 4 cols)
#         ▼          arrowPadding cells
#  ┌──────────────┐  clear of the target
#  │  the target  │  outset= grows THIS rect
#  └──────────────┘  before anything points' ;;
    6)  title="6 · The other beacon variants"
        CONCEPT="A callout is one variant of ft-beacon. The others carry no text and no leader: variant=frame rules a halo just outside a control, variant=number parks a circled badge in a corner of one."
        NOTE='# the two boxes below wear one mark each,
# and only the mark THIS step is about:
ft-beacon target=specA variant=frame
ft-beacon target=specB frameStyle=dashed
ft-beacon target=specB variant=number number=9
# effect=   pulse blink bob shimmer none
# lifetime= persist (loops) · oneshot (plays
#           cycles= laps, then destroys itself)' ;;
    8)  title="8 · variant=bigarrow — when a whisper will not do"
        # A NEW page's CONCEPT and NOTE cannot move any other page's layout, which is why the
        # arrow got a page instead of a sixth step on page 6. Held to two wrapped rows at every
        # width the demo supports, for page 2's reason: every row of prose here is a row the
        # arrow's lane does not get, and the lane is the lesson.
        CONCEPT="A callout whispers. variant=bigarrow shouts — one enormous arrow drawn out of ordinary cells, which flies in along its own axis, holds for a beat, and then gets out of the way."
        NOTE='# the edges are EIGHTH-blocks, not █:
#   ▁▂▃▄▅▆▇  + a fg/bg swap for the
#   anchor Unicode never shipped
# 3.45 sub-cells of error out of 64,
#   against 24.94 for whole blocks
# docs/unicode-art.md — box diagonals
#   ╱╲ and braille both LOST, with
#   numbers. Read it before editing.' ;;
    7)  title="7 · Where the engine decides to put it"
        # Held to ~180 characters: at 56 columns this wraps at 44, and every 44 characters is a
        # ROW — one the drag step needs, because its callout fits the stage's free band only as
        # the wide 5-row shape, and the 235-character original left that band 4 rows tall.
        CONCEPT="Placement is a search. The screen is asked for its unclaimed rectangles, the callout is tried at several widths in each, and every finalist is judged on the line it would REALLY get."
        NOTE='# what a candidate placement is charged:
#   covering the TARGET     100000/cell
#   covering any control      5000/cell
#   the line crossing one     3000/cell
#   each bend in the line     3000
#   no line at all           40000 + 3000/cell' ;;
    esac
    # The LEFT pane: the live call, built from the same annotation row the beacon was. Six lines,
    # which is exactly PANE_ROWS wherever the terminal has the height for it.
    local _t=${PA_TEXT[$i]} _abbrev
    _abbrev=${_t:0:24}; (( ${#_t} > 24 )) && _abbrev+="…"
    local _onnext="btnStepNext_on_activate"
    (( STEP < ${#PA_TARGET[@]} )) || { (( PAGE < LAST )) && _onnext="btnOk_on_activate" || _onnext="(none — last step)"; }
    CALL="ft-beacon name=stepcallout parent=lower \\
   variant=callout target=${PA_TARGET[$i]} \\
   place=${PA_PLACE[$i]} anchor=${PA_ANCHOR[$i]} \\
   number=$STEP calloutWidth=$CALLOUT_W effect=$CALLOUT_EFFECT \\
   outset=0 onNext=$_onnext \\
   text=\"$_abbrev\""
    # The short terminal's stand-in: the four arguments that actually differ from step to step.
    CALL_ONELINE="ft-beacon variant=callout target=${PA_TARGET[$i]} place=${PA_PLACE[$i]} anchor=${PA_ANCHOR[$i]} number=$STEP"
}
# Regenerate the code pane(s) from the CURRENT page+step without rebuilding anything: a pane has
# fixed rows, so a new value is a repaint and never a relayout.
_refresh_code_panes() {
    [[ -n "${FT_TYPE[call]:-}" ]] || return 0
    local title CONCEPT CALL NOTE CALL_ONELINE
    _page_content
    # `call` is a scrollable textfield in three of the four pane modes and a plain label in the
    # fourth, and the two carry their content under different property names. Ask the control
    # what it is rather than keeping a parallel flag that a future mode could forget to set.
    if [[ "${FT_TYPE[call]}" == label ]]; then ft-modify call text="$CALL_ONELINE"
    else                                       ft-modify call value="$CALL"; fi
    [[ -n "${FT_TYPE[note]:-}" ]] && ft-modify note value="$NOTE"
    return 0
}
# Chrome the demo owns, registered ONCE: the dashed ghost reads as a hint, not a border, so it
# cannot be mistaken for the solid halo beside it — which is the entire point of step 2.
ft_stylesheet name=calloutchrome style='#specRingB::border { color: subtext; }'

# ── A STEP change: the page is identical except the callout, the code pane(s) and the step
#    counter — so update just those. A rebuild+relayout of a page is ~230ms in pure bash and
#    the arrows have to feel instant.
_goto_step() {
    _page_annotations; local nsteps=${#PA_TARGET[@]}
    (( STEP < 1 )) && STEP=1; (( STEP > nsteps )) && STEP=$nsteps
    # ft_remove gives back every cell the callout painted — chip, leader and arrowhead, which
    # are all outside its own layout box. The app used to capture FT_BEACON_EXTENT here and
    # hand it to ft_damage; it no longer knows or needs to.
    ft_remove stepcallout 2>/dev/null
    ft-modify stepcount text=" Step $STEP of $nsteps "
    (( STEP == 1 ))      && ft-modify btnStepPrev disabled=true || ft-modify btnStepPrev disabled=false
    (( STEP == nsteps )) && ft-modify btnStepNext disabled=true || ft-modify btnStepNext disabled=false
    _refresh_code_panes
    # …and the SPECIMEN marks on page 6 change with the step exactly as the callout does, so they
    # are torn down and rebuilt here too. Leaving this out of the cheap step path was the reason
    # a step-aware _place_variants would have looked like it did nothing: the arrows never
    # rebuild a page, and _show_page is the only other place it is called from.
    _place_variants
    _place_arrow
    _place_callout
    # NOTHING PAINTS HERE — see the same note in css-demo's _goto_step. The run loop settles
    # the burst; a gate that drives this directly settles it itself.
    # Placement has now actually happened (it runs at paint), so the achieved side is known and
    # page 3's sentence can be made to match it. Both step paths need this — here and at the
    # bottom of _show_page — or the truth would depend on which arrow key built the picture.
    _p3_reconcile
}

# ═══ Stage control hooks — small, real, and only where a page needs one ═══════
selProto_on_change()   { ft-modify lblStat text="protocol: $1"; return 0; }
sldWorkers_on_change() { ft-modify lblStat text="$1 workers"; return 0; }

# ═══ The demonstration stage ══════════════════════════════════════════════════
# Emitted INSIDE the `lower` frame by whichever of the two layouts is in force, so the controls
# a page points at are declared exactly once and cannot drift between arrangements.
_stage_controls() {
            case "$PAGE" in
            1)  ft-div name=row1 display=flex gap=4 alignItems=center
                    ft-textfield name=share value="\\\\mago\\public" size=20 rows=1
                    ft-button    name=btnMount "Mount" accessKey=M
                    ft-checkbox  name=chkRO    "Read-only" accessKey=O
                end_ft_div
                ft-label name=note1 color=muted "…and none of them knows a callout exists" ;;
            # ONE control on the stage, and nothing else: this page is about where the ARROW
            # lands, so every free row above and below the target belongs to the chip. (A live
            # "anchor = …" readout used to sit under it and was cut — the callout's own sentence
            # and the call pane both name the anchor already, and the two rows it cost were two
            # rows the placer needed to put the chip straight above the target.)
            #
            # …and the one control SHRINKS when the screen does. The target sits in the MIDDLE
            # of the four bands the page needs, so every row it takes is a row the band above
            # and the band below both lose, and every column is one the left and right bands
            # both lose. Measured at 80×30 with the 30×5 specimen: 6 free rows above it and a
            # chip 6 rows tall — no slack at all for a sentence that wraps one line longer. The
            # 26×3 specimen leaves 8 rows above and 8 below, and 22 columns either side.
            2)  if (( FT_ROWS >= 36 && FT_COLS >= 100 )); then
                    ft-textfield name=compass size=28 rows=3 wrap=true readOnly=true \
                        value=$'One rectangle, nine points.\n< and > walk the arrowhead\nround its compass.'
                else
                    # size=16, and BOTH numbers are measured. The value has to FIT: at 22 columns
                    # the 26-character sentence overflowed and the textfield drew its horizontal
                    # scrollbar along the bottom border, which on the page about pointing at edges
                    # reads as the edge being marked. And 18 columns wide is what leaves 28 either
                    # side of it, which is the narrowest band the shape ladder can put a 28-wide
                    # chip in — one rung wider than the 20 a 22-column specimen allowed, and the
                    # difference between `anchor=centerLeft` fitting on one line of the chip and
                    # being broken across two as `anchor=centerLef` / `t`.
                    ft-textfield name=compass size=16 rows=1 wrap=false readOnly=true \
                        value="Nine points"
                fi ;;
            # #hub sits CENTRED and alone on its row, with the crowd pushed off to one side and a
            # row down. A page that teaches place= has to be able to honour all four sides, and a
            # preference is only a bias: with #hub anywhere near an edge, `place=left` asks for a
            # margin too thin to hold a chip and the engine rightly overrules it — the page would
            # then be demonstrating the opposite of what it says. Clear air on all four sides is
            # what makes the lesson true at every size.
            3)  ft-div name=hubrow display=flex gap=3 alignItems=center
                    ft-label  name=hubL color=muted "before"
                    ft-button name=hub  "Apply" accessKey=A
                    ft-label  name=hubR color=muted "after"
                end_ft_div
                # No accessKey on these four: they are here to CROWD, not to be pressed, and a
                # digit accelerator cannot be underlined, so the control appends "(1)" to its own
                # label — four pieces of noise in the row the page is about.
                ft-div name=crowd display=flex gap=1 alignItems=center alignSelf=start
                    ft-checkbox name=crowdA "one"
                    ft-checkbox name=crowdB "two"
                    ft-checkbox name=crowdC "three"
                    ft-checkbox name=crowdD "four"
                end_ft_div ;;
            4)  ft-div name=gridA display=flex gap=3 alignItems=center
                    ft-textfield name=tfHost value="mago.local" size=12 rows=1
                    ft-button    name=btnScan "Scan" accessKey=S
                    ft-checkbox  name=chkDeep "Deep" accessKey=D
                end_ft_div
                ft-div name=gridB display=flex gap=3 alignItems=center
                    ft-select name=selProto size=1 onChange=selProto_on_change
                        ft-option value=smb3 "SMB3"
                        ft-option value=smb2 "SMB2"
                        ft-option value=nfs  "NFS"
                    end_ft_select
                    ft-slider name=sldWorkers min=1 max=8 value=4 step=1 width=12 \
                              variant=fill showValue=true onChange=sldWorkers_on_change
                    ft-label  name=lblStat color=notice "4 workers"
                end_ft_div
                ft-table name=tblShares variant=lines striped=true
                    ft-table-header "Share"  width=10
                    ft-table-header "Path"   width=14
                    ft-table-row    "public" "/srv/public"
                    ft-table-row    "backup" "/srv/backup"
                end_ft_table ;;
            5)  ft-div name=chromeRow display=flex gap=3 alignItems=center
                    ft-button name=badgeT "Badge"   accessKey=G
                    ft-button name=wrapT  "Width"   accessKey=I
                    ft-button name=padT   "Padding" accessKey=P
                end_ft_div
                ft-div name=chromeRow2 display=flex gap=3 alignItems=center
                    ft-button name=nextT   "Next ▶" accessKey=X
                    ft-button name=outsetT "Outset" accessKey=U
                end_ft_div ;;
            # TWO IDENTICAL BOXES, SIDE BY SIDE, AND NOTHING ELSE. Five buttons in two rows used
            # to sit here, each wearing (or not wearing) one of three permanent marks, and the
            # reader had to work out which of five things a sentence meant. Two boxes that differ
            # only in the mark they are wearing make the difference the ONLY thing on the stage,
            # which is what a specimen page is for — the same argument that leaves page 2 with a
            # single control. They carry no accessKey: they are specimens, not actions, and an
            # underlined letter is a promise that pressing it does something.
            # The gap is wide because a beacon rules ONE CELL OUTSIDE its target and the two
            # rules must not touch — adjacent halos read as one box with a line down the middle.
            6)  ft-div name=varRow display=flex gap=8 alignItems=center
                    ft-button name=specA "Box A"
                    ft-button name=specB "Box B"
                end_ft_div ;;
            # ONE control, small, and centred — page 2's shape and page 2's reason. The
            # arrow is thirty columns long, so what this page has to leave is a thirty-column
            # LANE beside the specimen; a wide control would take it, and a tall one would take
            # the six rows the arrow needs to be thick. The step callout goes in whatever is
            # left, which on this page is the other side.
            # …AND ON A NARROW TERMINAL IT MOVES TO THE END OF THE STAGE. A centred specimen
            # splits the stage into two equal bands, and the smallest arrow there is is twenty
            # columns: measured, 56×34 leaves 15 columns either side, 60×38 leaves 17 and 64×42
            # leaves 19 — so the arrow page drew NO ARROW at three supported sizes. The shapes
            # are hand-drawn now and a rung that does not fit is not drawn rather than squashed
            # (that squashing is the whole defect the sprite sheet replaced), so the room has to
            # come from the LAYOUT. Pushed to the end, the same three sizes leave 30, 34 and 38
            # columns in one lane, and the page shows the medium and large rungs instead of a
            # blank stage. Above 72 columns the centred specimen already leaves enough for the
            # biggest rung and is the better-looking arrangement, so it is left alone.
            8)  if (( FT_COLS >= 72 )); then ft-button name=arrowBox "Look at this"
                else                         ft-button name=arrowBox alignSelf=end "Look at this"
                fi ;;
            7)  ft-div name=denseRow display=flex gap=2 alignItems=center
                    ft-button name=regionsBtn "Free space" accessKey=F
                    ft-button name=targetBtn  "The target" accessKey=T
                    ft-button name=crossBtn   "The line"   accessKey=L
                end_ft_div
                ft-textfield name=chromeBox size=32 rows=1 readOnly=true \
                             value="…and it keeps off the chrome"
                ft-div name=denseRow2 display=flex gap=2 alignItems=center
                    ft-checkbox name=dragChk  "Drag me aside" accessKey=G
                    ft-checkbox name=boundChk "boundBox"      accessKey=U
                end_ft_div ;;
            esac
}
# The `lower` frame the stage lives in — borderless, so it is a region of free space with
# controls in it rather than another box the eye has to parse.
_stage_frame() {                # [extra props…]
    # The stage's OWN inter-row gap follows WIN_GAP for the reason the frame's does: on a short
    # terminal a blank row between the stage's two rows of controls is a row that the band above
    # them and the band below them are each half of. Page 3 at 80×30 is the case that forced it —
    # with the gap, the free band above #hub was 6 rows against a 5-row chip plus a leader, so
    # `place=above` could not draw a line at all (40000, the no-line charge, against the 24000 a
    # named side is worth) and the step that says "place=above pins the chip over #hub" was drawn
    # underneath it. Without it the band is 7 and the chip goes where the sentence says.
    # PAGE 7 HUGS THE TOP OF ITS STAGE ON A NARROW TERMINAL, and that is a placement decision:
    # its drag step targets a checkbox on the stage's LAST row, and everything above that row —
    # the wide textfield, the button row — is an obstacle any downward leader must cross.
    # Centred at 56×38, the band under the checkboxes was 4 rows against a 5-row callout, so
    # the drag callout went ABOVE and drew its line straight through the textfield's interior.
    # Start-justified, the same free rows pool BELOW the last row instead: the callout sits
    # under the checkbox it points at with a short clean ▲ and crosses nothing.
    # PAGE 1 HAS THE SAME SHAPE AND EARNED THE SAME FIX: its lesson-critical target #note1 is
    # the stage's last row, directly under the 50-column control row. Centred at 80×30 the
    # stage's free rows split into two 5-row bands, and a 6-row chip fits neither — measured,
    # the placer's least-bad answer was a 17-row column in the side margin that overlapped
    # #note1 by one cell and chkRO by six. Start-justified the rows pool below #note1 and
    # every step of the page places with zero covered cells at every line-mode size measured
    # (80×30, 84×34, 62×40, 56×38). Everywhere else the centred stage is the better-looking
    # one and measures clean.
    local _justify=center
    (( PAGE == 7 || PAGE == 1 )) && [[ "$PANE_MODE" == line ]] && _justify=start
    ft-frame name=lower border=false flexGrow=1 flexShrink=1 minHeight=5 \
             display=flex flexDirection=column gap="$WIN_GAP" alignItems=center justifyContent="$_justify" "$@"
        _stage_controls
    end_ft_frame
}
_pane_pair() {                  # the code pane(s) for the current PANE_MODE
    case "$PANE_MODE" in
    side) ft-div name=panes display=flex flexDirection=column gap=1 alignItems=start flexShrink=0
              _code_panel call "The call"      "$CALL"
              _code_panel note "What it means" "$NOTE"
          end_ft_div ;;
    one)  ft-div name=panes display=flex gap=3 alignItems=start justifyContent=center
              _code_panel call "The call" "$CALL"
          end_ft_div ;;
    line) ft-label name=call color=accent width="$CONCEPT_W" "$CALL_ONELINE" ;;
    *)    ft-div name=panes display=flex gap=3 alignItems=start justifyContent=center
              _code_panel call "The call"      "$CALL"
              _code_panel note "What it means" "$NOTE"
          end_ft_div ;;
    esac
}

# ═══ The page builder ═════════════════════════════════════════════════════════
_show_page() {
    _metrics
    _page_annotations
    local nsteps=${#PA_TARGET[@]}
    (( STEP < 1 )) && STEP=1
    (( STEP > nsteps )) && STEP=$nsteps
    local oktext=Okay; (( PAGE == LAST )) && oktext=Done
    local title CONCEPT CALL NOTE CALL_ONELINE
    _page_content

    ft-empty stage
        # No explicit height: `stage` STRETCHES its child, so `win` is exactly as tall as the
        # screen minus the docked chrome, and the demonstration frame inside it (flexGrow=1)
        # soaks up every row the prose, the panes and the nav did not use.
        ft-frame name=win title="Fruity callouts — $title  ($PAGE/$LAST)" \
                 display=flex flexDirection=column gap="$WIN_GAP" padding=1 alignItems=center \
                 borderStyle=double
            ft-label name=concept width="$CONCEPT_W" color=subtext "$CONCEPT"

            if [[ "$PANE_MODE" == side ]]; then
                # WIDE: stage on the left with the whole column height, panes down the right.
                ft-div name=middle display=flex gap=3 alignItems=stretch alignSelf=stretch \
                        flexGrow=1 flexShrink=1 minHeight=0
                    _stage_frame
                    _pane_pair
                end_ft_div
            else
                # NARROW: the css-demo arrangement — pane(s) across, stage underneath.
                _pane_pair
                _stage_frame alignSelf=stretch
            fi

            # ── STEP through THIS page's lesson (◀ ▶); the bottom buttons move PAGES ──
            ft-div name=stepnav display=flex gap=2 alignItems=center justifyContent=center
                ft-button name=btnStepPrev "◀" onActivate=btnStepPrev_on_activate
                ft-label  name=stepcount color=accent " Step $STEP of $nsteps "
                ft-button name=btnStepNext "▶" onActivate=btnStepNext_on_activate
            end_ft_div

            ft-div name=btnrow display=flex gap=2 justifyContent=center
                ft-button name=btnBack "Back" accessKey=B onActivate=btnBack_on_activate
                ft-button name=btnOk   "$oktext" accessKey=K onActivate=btnOk_on_activate
                ft-button name=btnQuit "Quit" accessKey=Q onActivate=btnQuit_on_activate
            end_ft_div

            _place_variants   # page 6's halo / ghost / badge specimens
            _place_arrow      # page 8's big arrow
            _place_callout    # the CURRENT step's numbered callout, pointing at its control
        end_ft_frame
    end_ft_div

    (( PAGE == 1 ))      && ft-modify btnBack     disabled=true
    (( STEP == 1 ))      && ft-modify btnStepPrev disabled=true
    (( STEP == nsteps )) && ft-modify btnStepNext disabled=true
    ft-modify navbar status="Page $PAGE of $LAST — $title    ·    ◀ ▶ step · Okay / Back = page · Q quit"
    # App-level legend caps, registered LAST so the buttons' accessKey= rebinds cannot clobber
    # our LABELLED versions (same keymap → last registration wins). Backward before forward: the
    # legend sorts stably by importance, so declaring Next first would print it to the LEFT of
    # Prev and read backwards against the very buttons it describes.
    local km=${FT_KEYMAP[app]}
    ft-keymap-cap "$km" '<' btnStepPrev_on_activate "$FT_IMPORTANCE_IMPORTANT" "Prev step"
    ft-keymap-cap "$km" '>' btnStepNext_on_activate "$FT_IMPORTANCE_IMPORTANT" "Next step"
    ft-keymap-cap "$km" '[Bb]' btnBack_on_activate "$FT_IMPORTANCE_NORMAL" "Back ← page"
    ft-keymap-cap "$km" '[Kk]' btnOk_on_activate   "$FT_IMPORTANCE_NORMAL" "Okay → next page"
    ft-keymap-cap "$km" '[Ee]' _cycle_effect "$FT_IMPORTANCE_NORMAL" "effect="
    ft-keymap-cap "$km" '[Rr]' _reset_drag   "$FT_IMPORTANCE_NORMAL" "un-drag"
    ft-keymap-cap "$km" '[Qq]' ft_quit 40 "Quit"
    ft_refresh
    ft_focus call || ft_focus_first
    _p3_reconcile
}

# ── Navigation — TWO orthogonal axes ─────────────────────────────────────────
# ◀ ▶ walk the teaching STEPS within a page; Okay/Back move between PAGES (each page starts at
# step 1). Stepping is a cheap in-place update, never a rebuild.
btnStepNext_on_activate() { _page_annotations; (( STEP < ${#PA_TARGET[@]} )) && { (( STEP++ )); _goto_step; }; }
btnStepPrev_on_activate() { (( STEP > 1 )) && { (( STEP-- )); _goto_step; }; }
btnOk_on_activate()   { if (( PAGE < LAST )); then (( PAGE++ )); STEP=1; ft_invalidate; else ft_quit; fi; }
btnBack_on_activate() { (( PAGE > 1 )) && { (( PAGE-- )); STEP=1; ft_invalidate; }; }
btnQuit_on_activate() { ft_quit; }

# E — cycle the step callout's own effect. The property is live: re-arming a beacon restarts its
# animation, and effect=none disarms it entirely (a static persistent beacon runs no animation at
# all, which is why this demo idles between keystrokes instead of burning a core).
_cycle_effect() {
    case "$CALLOUT_EFFECT" in
        none)  CALLOUT_EFFECT=pulse ;;
        pulse) CALLOUT_EFFECT=blink ;;
        blink) CALLOUT_EFFECT=bob ;;
        *)     CALLOUT_EFFECT=none ;;
    esac
    ft-modify stepcallout effect="$CALLOUT_EFFECT"   # re-arms the effect; the prototype is told
    _refresh_code_panes
    return 0
}
# R — forget a mouse-parked position and let the placer choose again.
_reset_drag() {
    ft_beacon_unpark stepcallout
    ft_refresh
    return 0
}

_resize() { ft-modify app width="$FT_COLS" height="$FT_ROWS"; _show_page; }

# ── App scaffold ──────────────────────────────────────────────────────────────
ft-form name=app width="$FT_COLS" height="$FT_ROWS" \
        display=flex flexDirection=column \
        keymap '[Qq]'=ft_quit
    # alignItems=stretch, not center: `win` then fills the stage's height, and its own flex
    # column can hand the leftover rows to the demonstration frame instead of overflowing.
    ft-div name=stage flexGrow=1 flexShrink=1 minHeight=0 overflow=hidden \
             display=flex justifyContent=center alignItems=stretch
    end_ft_div
    ft-keylegend name=navlegend flexShrink=0 keys=auto
    ft-statusbar name=navbar     flexShrink=0 status="Loading…"
end_ft_form

ft-run app _show_page _resize '' _show_page
