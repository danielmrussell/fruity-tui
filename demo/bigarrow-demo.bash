#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  demo/bigarrow-demo.bash — the BIG ARROW beacon, five pages, one idea each.
#
#     1  What it is             a giant arrow, drawn out of many cells, that
#                               flies in along its own axis and settles
#     2  Which way it points    place= — the four axes, and auto
#     3  Anything is a target   it points at whatever control you name
#     4  The glyphs             smoothing= — eighths vs halves vs solid blocks,
#                               THE SAME ARROW, so the research is visible
#     5  The bounce             animation-timing-function= — five curves,
#                               including the two that overshoot
#     6  Getting out of the way exit= — a big arrow is the right amount of
#                               emphasis for a second and the wrong amount
#                               after ten, so by default it leaves
#
#  PAGES 1-5 PIN lifetime=persist so the thing can be studied. That is NOT the
#  default: a bigarrow retires on its own, which is what page 6 is about, and a
#  demo whose every page emptied itself after three seconds would be useless for
#  looking at the one thing it exists to show.
#
#  There is a REAL TEXT FIELD on every page, on purpose. Put the caret in it and
#  type while the arrow is flying: that is the acceptance test for this whole
#  feature, and it is meant to be done by hand, not only by a benchmark.
#
#     < >   step within a page        E  next timing curve (page 5)
#     N B   next / back a page        G  next smoothing rung (page 4)
#     R     replay the flight         Q  quit          Tab / arrows  move focus
#
#    bash demo/bigarrow-demo.bash
# ─────────────────────────────────────────────────────────────────────────────
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./fruity-tui.bash
ft_init
ft_term_size
[[ -z "${FT_NO_WTFIX:-}" ]] && declare -F ft_wt_autofix_enter >/dev/null && ft_wt_autofix_enter

PAGE=${DEMO_PAGE:-1}
STEP=${DEMO_STEP:-1}
LAST=6

# ── What each page walks through ─────────────────────────────────────────────
# One list per page, so a step is an index and nothing has to know about the others.
P2_PLACE=(auto left right above below)
P3_TARGET=(btnOk field cbOne head btnGo)
P4_SMOOTH=(eighths halves solid)
# Two of these are real CSS keywords, two are the -back curves CSS has no keyword for, and the
# last is the same curve wound up — the demo's own argument that a NAMED easing is not enough.
P5_EASE=(ease-out-back ease-out linear ease-in-out "cubic-bezier(0.2,2.4,0.5,1)")
# retract and fade are the two graceful exits; none is the control, and it is on the list
# so the difference between "it left" and "it vanished" can be seen rather than described.
P6_EXIT=(retract fade none)

_steps_on_page() {              # → FT_RET
    case $PAGE in
        2) FT_RET=${#P2_PLACE[@]} ;;
        3) FT_RET=${#P3_TARGET[@]} ;;
        4) FT_RET=${#P4_SMOOTH[@]} ;;
        5) FT_RET=${#P5_EASE[@]} ;;
        6) FT_RET=${#P6_EXIT[@]} ;;
        *) FT_RET=1 ;;
    esac
}

# ── The stage the arrow points AT ────────────────────────────────────────────
# Deliberately NOT full width. A form that fills every cell leaves no room for any annotation
# — callout, arrow or otherwise — and a demo that hides that from you is lying about the
# feature. The stage takes the middle; the arrow gets the margins.
_stage_metrics() {
    STAGE_W=$(( FT_COLS * 42 / 100 )); (( STAGE_W < 30 )) && STAGE_W=30
    (( STAGE_W > 54 )) && STAGE_W=54
    PROSE_W=$(( FT_COLS - 8 )); (( PROSE_W > 100 )) && PROSE_W=100
}

_page_title() {                 # → FT_RET
    case $PAGE in
        1) FT_RET="What it is" ;;
        2) FT_RET="Which way it points — place=" ;;
        3) FT_RET="Anything is a target — target=" ;;
        4) FT_RET="The glyphs — smoothing=" ;;
        5) FT_RET="The bounce — animation-timing-function=" ;;
        6) FT_RET="Getting out of the way — exit=" ;;
    esac
}
_page_prose() {                 # → FT_RET
    local i=$(( STEP - 1 ))
    case $PAGE in
    1) FT_RET="A beacon with variant=bigarrow is one enormous arrow made of ordinary text cells. It picks a side with room, takes the largest of FOUR hand-drawn sizes that fits, flies in along its own axis, overshoots and settles. Press R to watch it again." ;;
    2) case ${P2_PLACE[i]} in
         auto)  FT_RET="place=auto scores all four sides in VISUAL units — a row is worth two columns — and takes the roomiest. On most screens that is a side arrow, because a terminal is wider than it is tall." ;;
         left)  FT_RET="place=left puts the arrow in the LEFT margin, so it points right. Named sides are honoured absolutely: an arrow on the wrong side does not point at the thing, and no cost model can trade that away." ;;
         right) FT_RET="place=right — the mirror. The bounce runs along the arrow's own axis, so this one slides in from the right edge and rebounds leftward." ;;
         above) FT_RET="place=above points DOWN. A vertical arrow is its own drawing, not the side one turned: it uses left-half blocks instead of lower-eighth ones, because now it is the HORIZONTAL edge that needs the sub-cell precision." ;;
         below) FT_RET="place=below points UP, and it is FEWER ROWS than the side arrows are columns — that is the 1:2 cell aspect. The two axes of one size are the same VISUAL size: 28 columns, or 14 rows." ;;
       esac ;;
    3) FT_RET="target=${P3_TARGET[i]} — the arrow tracks that control's box every frame, so it follows a control that moves or is rebuilt. Any control at all: a label, a field, a checkbox, a heading, a button." ;;
    4) case ${P4_SMOOTH[i]} in
         eighths) FT_RET="smoothing=eighths (the default). Eight sub-positions per cell from ▁▂▃▄▅▆▇, plus a foreground/background swap for the anchor Unicode never shipped. Mean boundary error 3.45 sub-cells of 64." ;;
         halves)  FT_RET="smoothing=halves — ▀▄▌▐ only, which is every font measured including Consolas and Lucida Console, where the eighths are missing. Still symmetric, because the swap still applies. Error 5.00 of 64." ;;
         solid)   FT_RET="smoothing=solid — whole cells of █, the naive approach, kept so it can be LOOKED AT rather than argued about. Error 24.94 of 64. Step back to eighths and watch the barbs." ;;
       esac ;;
    6) case ${P6_EXIT[i]} in
         retract) FT_RET="exit=retract, the default. It holds for a beat, leans a cell TOWARD the target, then whips back out the way it came and repairs every cell it covered. Free: the same offset machinery as the bounce, no colour maths." ;;
         fade)    FT_RET="exit=fade blends the ink toward whatever is underneath, over the same frames — the shimmer effect's technique. It works, and it dissolves IN PLACE, so for its last third there is a big dim arrow-shaped smudge on the page." ;;
         *)       FT_RET="exit=none is the control: it just stops existing. Watch this one and then step back to retract — the difference between an arrow that LEFT and an arrow that vanished is the whole reason the other two exist." ;;
       esac ;;
    5) case ${P5_EASE[i]} in
         ease-out-back) FT_RET="ease-out-back — cubic-bezier(0.34,1.56,0.64,1). Its output leaves 0..1: it peaks at 1.097, so the arrow travels 9.7% past where it lands and comes back. That overshoot IS the cartoon." ;;
         ease-out)      FT_RET="ease-out — a real CSS keyword, and no overshoot at all. It arrives and stops. Correct, and completely uncartoonish; a good control for what the -back curves are doing." ;;
         linear)        FT_RET="linear — constant speed, arrives like a lift. Every one of these is a real animation-timing-function resolved through the cascade, so a THEME can retime every arrow in an app." ;;
         ease-in-out)   FT_RET="ease-in-out — slow, fast, slow. Reads as heavy rather than springy: the arrow has weight but no bounce." ;;
         *)             FT_RET="cubic-bezier(0.2,2.4,0.5,1) — the same shape wound up. This is why a named easing is not enough on its own, and why the full cubic-bezier() form is parsed." ;;
       esac ;;
    esac
}
# The exact call that produced what you are looking at.
_page_call() {                  # → FT_RET
    local i=$(( STEP - 1 ))
    case $PAGE in
    1) FT_RET="ft-beacon name=arrow variant=bigarrow target=btnOk" ;;
    2) FT_RET="ft-beacon name=arrow variant=bigarrow target=btnOk place=${P2_PLACE[i]}" ;;
    3) FT_RET="ft-beacon name=arrow variant=bigarrow target=${P3_TARGET[i]}" ;;
    4) FT_RET="ft-beacon name=arrow variant=bigarrow target=btnOk smoothing=${P4_SMOOTH[i]}" ;;
    5) FT_RET="ft-beacon name=arrow variant=bigarrow target=btnOk animationTimingFunction=${P5_EASE[i]}" ;;
    6) FT_RET="ft-beacon name=arrow variant=bigarrow target=btnOk exit=${P6_EXIT[i]}   # lifetime=oneshot is the default" ;;
    esac
}

# ── Build ────────────────────────────────────────────────────────────────────
_build() {
    _stage_metrics
    ft_remove stage 2>/dev/null
    local ttl; _page_title; ttl=$FT_RET
    local prose; _page_prose; prose=$FT_RET
    local call;  _page_call;  call=$FT_RET

    ft-div name=stage parent=body flexGrow=1 flexShrink=1 minHeight=0 overflow=hidden \
           display=flex flexDirection=column alignItems=center gap=1
        ft-label name=intro width="$PROSE_W" text="$prose" wrap=true
        ft-div name=mid flexGrow=1 flexShrink=1 minHeight=0 display=flex justifyContent=center alignItems=center
            ft-frame name=box width="$STAGE_W" height=13 title="Settings" \
                     display=flex flexDirection=column gap=1 padding=1
                ft-heading name=head text="Connection"
                ft-label name=hint text="Type in the field while it flies."
                ft-textfield name=field size=18 value="hello"
                ft-checkbox name=cbOne text="Remember me"
                ft-div name=row display=flex gap=2
                    ft-button name=btnOk text="OK"
                    ft-button name=btnGo text="Connect"
                end_ft_div
            end_ft_frame
        end_ft_div
        ft-label name=callsrc width="$PROSE_W" text="  $call" color=accent
    end_ft_div
    _arm_arrow
}

# Remove and re-create, which is also how you REPLAY: the constructor arms the flight.
_arm_arrow() {
    local i=$(( STEP - 1 ))
    local target=btnOk place=auto smooth=eighths ease="$FT_BIGARROW_EASING"
    # persist on the pages that teach the SHAPE, so it holds still while you look at it; the
    # real default (oneshot) on the page that teaches leaving. Saying lifetime= at all is the
    # deliberate act — see the note in ft-beacon's constructor.
    local life=persist xexit=$FT_BIGARROW_EXIT xease=$FT_BIGARROW_EXIT_EASING
    case $PAGE in
        2) place=${P2_PLACE[i]} ;;
        3) target=${P3_TARGET[i]} ;;
        4) smooth=${P4_SMOOTH[i]} ;;
        5) ease=${P5_EASE[i]} ;;
        6) life=oneshot; xexit=${P6_EXIT[i]}
           # linear for a fade: an -back curve winds BACKWARD before it goes, which is
           # anticipation for something about to MOVE and merely a pause for something about to
           # dissolve. Measured over the twelve exit frames, ease-in-back spends six of them at
           # full opacity and ease-in spends eight. A fade wants opacity = progress.
           [[ "$xexit" == fade ]] && xease=linear ;;
    esac
    ft_remove arrow 2>/dev/null
    ft-beacon name=arrow parent=body variant=bigarrow target="$target" \
              place="$place" smoothing="$smooth" animationTimingFunction="$ease, $xease" \
              lifetime="$life" exit="$xexit" \
              boundBox=stage
}

_legend() {
    ft_set app \
        key='<' keyCap="Prev step" keyImp=important onKey=_prev_step \
        key='>' keyCap="Next step" keyImp=important onKey=_next_step \
        key='[Bb]' keyCap="Back ← page" keyImp=normal onKey=_prev_page \
        key='[Nn]' keyCap="Next → page" keyImp=normal onKey=_next_page \
        key='[Rr]' keyCap="Replay" keyImp=normal onKey=_replay \
        key='[Qq]' keyCap="Quit" keyImp=40 onKey=ft_quit
}

_show() {
    _build
    _legend
    local ttl; _page_title; ttl=$FT_RET
    local n; _steps_on_page; n=$FT_RET
    local _hint="< > step · N B page · R replay · Q quit"
    (( PAGE == 6 )) && _hint="R replays it — the arrow LEAVES on this page   ·   $_hint"
    ft_set navbar status="Page $PAGE/$LAST — $ttl   ·   step $STEP/$n   ·   $_hint"
    ft_refresh
    ft_focus field || ft_focus_first
    return 0
}

_next_step() { local n; _steps_on_page; n=$FT_RET; (( STEP < n )) && (( STEP++ )) || STEP=1; _show; }
_prev_step() { local n; _steps_on_page; n=$FT_RET; (( STEP > 1 )) && (( STEP-- )) || STEP=$n; _show; }
_next_page() { (( PAGE < LAST )) && (( PAGE++ )) || PAGE=1; STEP=1; _show; }
_prev_page() { (( PAGE > 1 ))    && (( PAGE-- )) || PAGE=$LAST; STEP=1; _show; }
# Replay is a re-arm and a repaint — the old arrow's cells are the ones the refresh clears.
_replay()    { _arm_arrow; ft_refresh; ft_focus field || ft_focus_first; }

_resize() { ft_set app width="$FT_COLS" height="$FT_ROWS"; _show; }

# ── App scaffold ─────────────────────────────────────────────────────────────
ft-form name=app width="$FT_COLS" height="$FT_ROWS" \
        display=flex flexDirection=column \
        key='[Qq]' onKey=ft_quit
    ft-div name=body flexGrow=1 flexShrink=1 minHeight=0 overflow=hidden \
           display=flex flexDirection=column
    end_ft_div
    ft-keylegend name=navlegend flexShrink=0 keys=auto
    ft-statusbar name=navbar     flexShrink=0 status="Loading…"
end_ft_form

ft_run app _show _resize '' _show
