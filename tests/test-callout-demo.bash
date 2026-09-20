#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Integration test for demo/callout-demo.bash — the seven-page callout tour.
#
#  It sources the REAL demo with its run-loop stripped, builds every page at
#  every step, PAINTS it, and then asserts on what the callout engine actually
#  decided — not on what the demo asked for. So this is an end-to-end check of
#  the callout system THROUGH the demo: targets resolve, the nine anchors put
#  the arrowhead on the nine named points, the chip never sits on the thing it
#  is pointing at, the leader connects and arrives along its head's axis, and
#  every page builds at four real terminal sizes.
#
#  ══ WHY THE GEOMETRY SWEEP COVERS EVERY STEP AT EVERY SIZE ══════════════════
#  It did not, and that was the defect. It swept the FIRST AND LAST step of each
#  page at two sizes and asked only two things of them: that the chip missed its
#  own target and that the leader was not a stub. Every failure a reader found on
#  a small terminal was in a MIDDLE step:
#
#    p2 s3  84×34  the band above the target was 3 rows and the chip 6, so a chip
#                  told to anchor topCenter was placed UNDERNEATH and the leader
#                  ran up THROUGH the target — 5 crossed cells — to reach the top
#                  edge. Steps 2, 4 and 6 the same. Step 1 and step 10 were fine,
#                  which is exactly why nothing failed.
#    p3 s2/s3/s4   every step of the page that TEACHES place= was overruled at
#                  84×34 and drawn on the side it had not asked for, while its own
#                  sentence said "place=above pins the chip over #hub".
#    p6 s1         the step callout's leader was routed between two decorative
#                  beacons and drawn straight over both their rules.
#
#  So: every step, every page, at 80×30, 84×34, 120×40 and 171×45, asserting
#      a. the leader never crosses its own target (centerCenter excepted — it
#         points INTO the middle by design)
#      b. the chip never lands on the key legend, the status bar, or the BORDER
#         RING of anything that draws one
#      c. page 2's nine anchors each put the head on the point they name
#      d. the chip stays inside its bounding container
#      e. page 3's five named sides are each honoured
#      f. no leader is a stub, and no chip sits on its own target
#
#  A leniency in here has to be EARNED BY A MEASUREMENT and the measurement has
#  to be written next to it. There are two, both about 80×30, both stated.
#
#  It also guards the demo's own editorial rules, which would otherwise rot the
#  moment somebody adds a page:
#
#    · place= is `auto` on every page except page 3 (the page that TEACHES
#      place=). A placement override anywhere else is a workaround, and the
#      whole point of the demo is that the engine does not need one.
#    · no two callouts say the same thing, and outside the three pages that walk
#      one property across a fixed specimen, no two steps of a page point at the
#      same control.
#    · THE SENTENCE-LENGTH CEILINGS ARE LOAD-BEARING and are measured here, not
#      trusted to a comment. A chip's height is its sentence divided by its wrap
#      width; on the pages whose lesson is the space AROUND a target, a sentence
#      one line longer is a chip that no longer fits the band it has to occupy,
#      and the page silently starts contradicting itself.
#
#  ONE PAINT PER STEP. Every geometric fact below is collected in a single
#  sweep and asserted afterwards. Written the obvious way — a loop per section —
#  it re-placed all forty-three callouts five times over, and a placement is a
#  real routing search, so the file took minutes instead of a minute. A slow
#  test in a suite is a test people stop running. The four-size sweep uses
#  _goto_step, the same cheap path the ◀ ▶ arrows use, and rebuilds a page only
#  when it changes page — which is what makes four sizes affordable at all.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"

export FT_NO_WTFIX=1
# Sourced from INSIDE the tree: the demo derives its own root from BASH_SOURCE, so a copy in
# /tmp resolves `here` to / and silently loads nothing.
noloop="$here/demo/.callout-demo-noloop.bash"
sed '/^ft_run app/d' "$here/demo/callout-demo.bash" > "$noloop"
trap 'rm -f "$noloop"' EXIT
source "$noloop"
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256
FT_USE_UTF8=1
# ft_run sets FT_ROOT; headless it has to be set by hand or ft_refresh returns without ever
# laying the rebuilt tree out, and every geometry assertion below reads an empty rect.
FT_ROOT=app

# NOTHING HERE MAY BE CALLED _shape OR _cand. _ft_beacon_paint_callout defines
# helpers with those names INSIDE itself, and a nested function definition in bash is global —
# so the first paint replaces the test's helper with the beacon's, and the next call feeds a
# polyline into `(( w < 6 ))`. (It cost a debugging round trip; hence the `_t_` prefix on
# everything in this file.)

# ── Rectangle arithmetic, once ───────────────────────────────────────────────
# _t_overlap aT aL aB aR  bT bL bB bR → FT_RET = cells the two rects share
_t_overlap() {
    local t=$(( $1 > $5 ? $1 : $5 )) l=$(( $2 > $6 ? $2 : $6 ))
    local b=$(( $3 < $7 ? $3 : $7 )) r=$(( $4 < $8 ? $4 : $8 ))
    if (( t > b || l > r )); then FT_RET=0; else FT_RET=$(( (b-t+1)*(r-l+1) )); fi
}
# _t_rect NAME → T_R_T/L/B/R, or 1 if the control was never laid out
_t_rect() {
    [[ -n "${FT_ABSOLUTE_Y[$1]:-}" ]] || return 1
    T_R_T=${FT_ABSOLUTE_Y[$1]}; T_R_L=${FT_ABSOLUTE_X[$1]}
    T_R_B=$(( T_R_T + ${FT_MEASURED_HEIGHT[$1]:-0} - 1 ))
    T_R_R=$(( T_R_L + ${FT_MEASURED_WIDTH[$1]:-0} - 1 ))
    (( T_R_B >= T_R_T && T_R_R >= T_R_L ))
}
# Cells of the POLYLINE that fall inside a rect. The polyline is the routed leader as the
# engine published it — the same waypoints it draws from — so this counts drawn line, not a
# model of it. Each segment is axis-aligned, which is what makes it a clamp and not a raster.
_t_poly_in_rect() {             # poly T L B R → FT_RET
    local poly=$1 rt=$2 rl=$3 rb=$4 rr=$5
    local -a w=($poly); local n=${#w[@]} i r0 c0 r1 c1 lo hi hits=0
    for (( i=0; i+3<n; i+=2 )); do
        r0=${w[i]}; c0=${w[i+1]}; r1=${w[i+2]}; c1=${w[i+3]}
        if (( r0 == r1 )); then
            (( r0 < rt || r0 > rb )) && continue
            lo=$(( c0<c1?c0:c1 )); hi=$(( c0<c1?c1:c0 ))
            (( lo < rl )) && lo=$rl; (( hi > rr )) && hi=$rr
            (( hi >= lo )) && (( hits += hi - lo + 1 ))
        else
            (( c0 < rl || c0 > rr )) && continue
            lo=$(( r0<r1?r0:r1 )); hi=$(( r0<r1?r1:r0 ))
            (( lo < rt )) && lo=$rt; (( hi > rb )) && hi=$rb
            (( hi >= lo )) && (( hits += hi - lo + 1 ))
        fi
    done
    FT_RET=$hits
}

# ── Probe: report what the engine chose for the CURRENT page+step ────────────
# Sets: T_BOX_T/L/B/R, T_POLY, T_HEAD_R/C, T_TGT, T_TT/TL/TB/TR, T_TURNS, T_LEN,
#       T_LASTAX, T_SIDE_PC (the side the engine recorded), T_SIDE_GEOM (where the box
#       really sits relative to the target).
_t_collect() {                  # → 0 iff a callout was placed and its target is laid out
    T_POLY=${FT_BEACON_LEADER[stepcallout]:-}
    local box=${FT_BEACON_BOX[stepcallout]:-}
    # A CALLOUT WITH NO LEADER IS PLACED, NOT MISSING. When the screen leaves the chip hard
    # against its target the exit cell IS the arrowhead cell, and the engine deliberately draws
    # neither line nor arrow rather than wedge an arrow glyph between two borders. The BOX is
    # still the proof a callout exists; T_HEAD_* are left empty and the line assertions skip.
    [[ -n "$box" ]] || return 1
    read -r T_BOX_T T_BOX_L T_BOX_B T_BOX_R <<< "$box"
    ft_beacon_side stepcallout; T_SIDE_PC=$FT_RET      # the achieved side, from the public accessor
    T_HEAD_R=""; T_HEAD_C=""
    if [[ -n "$T_POLY" ]]; then
        local -a p=($T_POLY)
        T_HEAD_R=${p[-2]}; T_HEAD_C=${p[-1]}
    fi
    T_TGT=${PA_TARGET[$(( STEP - 1 ))]}
    _t_rect "$T_TGT" || return 1
    T_TT=$T_R_T; T_TL=$T_R_L; T_TB=$T_R_B; T_TR=$T_R_R
    # WHERE THE CHIP REALLY SITS — the side it is FURTHEST CLEAR ON, which is the same
    # derivation the engine's own shortlist uses, down to the tie order. Four independent
    # "does it clear this edge" tests written in sequence do NOT answer this: a chip parked up
    # and to the left of its target satisfies both `above` and `left`, and whichever test ran
    # last silently won. That is a bug in the JUDGE, not in the thing being judged — it
    # reported page 3's `place=above` as having landed `left` when the box cleared the target's
    # top by exactly as much as it cleared its left, and the leader did come down from above.
    local _dA=$(( T_TT - T_BOX_B )) _dB=$(( T_BOX_T - T_TB ))
    local _dL=$(( T_TL - T_BOX_R )) _dR=$(( T_BOX_L - T_TR )) _mm
    _mm=$_dB; T_SIDE_GEOM=below
    (( _dA > _mm )) && { _mm=$_dA; T_SIDE_GEOM=above; }
    (( _dL > _mm )) && { _mm=$_dL; T_SIDE_GEOM=left; }
    (( _dR > _mm )) && {           T_SIDE_GEOM=right; }
    # turns, drawn length and the axis of the final segment, from the published polyline
    local i pr="" pc="" r c dr dc last="" ax
    T_TURNS=0; T_LEN=0; T_LASTAX=none
    for (( i=0; i+1 < ${#p[@]}; i+=2 )); do
        r=${p[i]}; c=${p[i+1]}
        if [[ -n "$pr" ]]; then
            dr=$(( r>pr ? r-pr : pr-r )); dc=$(( c>pc ? c-pc : pc-c ))
            (( T_LEN += dr + dc ))
            if   (( dr > 0 && dc == 0 )); then ax=v
            elif (( dc > 0 && dr == 0 )); then ax=h
            else ax=$last; fi
            [[ -n "$ax" ]] && { [[ -n "$last" && "$ax" != "$last" ]] && (( T_TURNS++ )); last=$ax; T_LASTAX=$ax; }
        fi
        pr=$r; pc=$c
    done
    return 0
}
# A FRESH BUILD of the current page+step, rather than the stepped path. Both are real code
# paths through the same picture and only having one made a discrepancy between them
# invisible — you could not render the second to compare.
_t_probe() {                    # page step → 0 iff a callout was placed
    PAGE=$1; STEP=$2
    _show_page >/dev/null 2>&1
    settle >/dev/null 2>&1   # ft_run settles the burst; a gate must too
    FT_OUT=""; _ft_redraw_walk app >/dev/null 2>&1; _ft_composite_overlays >/dev/null 2>&1
    _t_collect
}

# Cells of the TARGET the chip covers. The head may land on the target (that is what
# anchor=centerCenter is for); the BOX may not, on any page, at any size — it would hide the
# one thing the callout exists to indicate.
_t_box_covers_target() {        # → FT_RET
    _t_overlap "$T_BOX_T" "$T_BOX_L" "$T_BOX_B" "$T_BOX_R" "$T_TT" "$T_TL" "$T_TB" "$T_TR"
}
# Cells of DOCKED CHROME the chip covers — the key legend and the status bar, which live
# outside the frame and cannot be repainted by a stage redraw.
_t_chip_on_chrome() {           # → FT_RET
    local n total=0
    for n in navlegend navbar; do
        _t_rect "$n" || continue
        _t_overlap "$T_BOX_T" "$T_BOX_L" "$T_BOX_B" "$T_BOX_R" "$T_R_T" "$T_R_L" "$T_R_B" "$T_R_R"
        (( total += FT_RET ))
    done
    FT_RET=$total
}
# Cells of any BORDER RING the chip covers. The ring is a control's rect MINUS its interior:
# a bordered box's own frame characters, which are the cells that look broken when something
# is painted over them.
#
# CHECK THE PREDICATE, NOT THE TYPE. `_ft_border NAME` is the only thing that says whether a
# control draws a ring; a frame with border=false draws none and its rect is just a region of
# free space that a chip is perfectly entitled to sit in. Enumerating by type instead reports
# every borderless div and frame in the tree as a violation, which is a false positive per
# container per step.
_t_chip_on_ring() {             # → FT_RET
    local n total=0 whole inner
    for n in "${!FT_TYPE[@]}"; do
        _ft_border "$n"; (( FT_RET )) || continue
        _t_rect "$n" || continue
        _t_overlap "$T_BOX_T" "$T_BOX_L" "$T_BOX_B" "$T_BOX_R" "$T_R_T" "$T_R_L" "$T_R_B" "$T_R_R"
        whole=$FT_RET
        (( whole )) || continue
        _t_overlap "$T_BOX_T" "$T_BOX_L" "$T_BOX_B" "$T_BOX_R" \
                   $(( T_R_T+1 )) $(( T_R_L+1 )) $(( T_R_B-1 )) $(( T_R_R-1 ))
        inner=$FT_RET
        (( total += whole - inner ))
    done
    FT_RET=$total
}
# Where the callout may park, derived the way the engine derives it: boundBox=CONTROL's interior
# when the author set one, otherwise the whole screen. (It used to default to the nearest
# bordered ancestor; a frame's ring is an obstacle now, so the cage went — see ft-beacon.)
_t_boundbox() {                 # → T_BB / T_BB_T/L/B/R
    ft_resolved_prop stepcallout boundBox ""; T_BB=$FT_RET
    if [[ -n "$T_BB" ]] && _t_rect "$T_BB"; then
        T_BB_T=$(( T_R_T+1 )); T_BB_L=$(( T_R_L+1 ))
        T_BB_B=$(( T_R_B-1 )); T_BB_R=$(( T_R_R-1 ))
    else
        T_BB=screen; T_BB_T=0; T_BB_L=0; T_BB_B=$(( FT_ROWS-1 )); T_BB_R=$(( FT_COLS-1 ))
    fi
    return 0
}
# Where anchor=X must put the arrowhead, from the target's own rect. The demo builds every
# callout with outset=0 and the default arrowPadding=1, so the head sits one column clear
# sideways (apad) and flush above/below (vpad = apad-1 = 0) — see _ft_beacon_paint_callout.
_t_expect_anchor() {            # anchor → T_EXP_R T_EXP_C
    local a=$1 mr=$(( (T_TT+T_TB)/2 )) mc=$(( (T_TL+T_TR)/2 ))
    case "$a" in
        topLeft)      T_EXP_R=$(( T_TT-1 )); T_EXP_C=$T_TL ;;
        topCenter)    T_EXP_R=$(( T_TT-1 )); T_EXP_C=$mc ;;
        topRight)     T_EXP_R=$(( T_TT-1 )); T_EXP_C=$T_TR ;;
        bottomLeft)   T_EXP_R=$(( T_TB+1 )); T_EXP_C=$T_TL ;;
        bottomCenter) T_EXP_R=$(( T_TB+1 )); T_EXP_C=$mc ;;
        bottomRight)  T_EXP_R=$(( T_TB+1 )); T_EXP_C=$T_TR ;;
        centerLeft)   T_EXP_R=$mr;           T_EXP_C=$(( T_TL-2 )) ;;
        centerRight)  T_EXP_R=$mr;           T_EXP_C=$(( T_TR+2 )) ;;
        centerCenter) T_EXP_R=$mr;           T_EXP_C=$mc ;;
        *)            T_EXP_R=-1; T_EXP_C=-1 ;;
    esac
}
# The axis the head must be ENTERED along, read off the TARGET: a head level with the target's
# rows is a ◀/▶ and wants a horizontal final segment; anything else is ▲/▼ and wants vertical.
_t_head_axis() { if (( T_HEAD_R >= T_TT && T_HEAD_R <= T_TB )); then T_AXIS=h; else T_AXIS=v; fi; }

# ═════════════════════════════════════════════════════════════════════════════
note "the tour is seven pages, every page has steps, every step is fully specified"
check "LAST names eight pages" "$LAST" 8
_t_total=0
for PAGE in 1 2 3 4 5 6 7 8; do
    _page_annotations
    n=${#PA_TARGET[@]}
    (( _t_total += n ))
    (( n >= 1 )) && check "page $PAGE has $n step(s)" 1 1 || check "page $PAGE has steps" 0 1
    _bad=0
    for (( i=0; i<n; i++ )); do
        [[ -n "${PA_TARGET[$i]}" && -n "${PA_PLACE[$i]}" && -n "${PA_ANCHOR[$i]}" && -n "${PA_TEXT[$i]}" ]] || _bad=1
    done
    check "page $PAGE: every step names a target, a place, an anchor and a sentence" "$_bad" 0
done
check "the tour has more than thirty teaching steps" "$(( _t_total > 30 ? 1 : 0 ))" 1

note "place= is auto EVERYWHERE except page 3, the page that teaches place="
_t_overrides=""
for PAGE in 1 2 3 4 5 6 7 8; do
    _page_annotations
    for (( i=0; i<${#PA_TARGET[@]}; i++ )); do
        [[ "${PA_PLACE[$i]}" == auto ]] && continue
        (( PAGE == 3 )) && continue
        _t_overrides+=" p$PAGE.s$((i+1))=${PA_PLACE[$i]}"
    done
done
check "no placement override outside page 3" "$_t_overrides" ""
PAGE=3; _page_annotations
_t_sides=""
for (( i=0; i<${#PA_PLACE[@]}; i++ )); do _t_sides+=" ${PA_PLACE[$i]}"; done
check "page 3 exercises all four sides plus auto" "$_t_sides" " auto above below left right auto"

note "page 2 walks all NINE anchors plus auto, on one control"
PAGE=2; _page_annotations
_t_anchors=""
for (( i=0; i<${#PA_ANCHOR[@]}; i++ )); do _t_anchors+=" ${PA_ANCHOR[$i]}"; done
check "the anchor page names every compass point" "$_t_anchors" \
      " auto topLeft topCenter topRight centerLeft centerRight bottomLeft bottomCenter bottomRight centerCenter"
_t_onetarget=1
for (( i=0; i<${#PA_TARGET[@]}; i++ )); do [[ "${PA_TARGET[$i]}" == compass ]] || _t_onetarget=0; done
check "…all on the SAME control, so only the arrow moves" "$_t_onetarget" 1

note "no callout repeats another — the filler-text rule, machine-checked"
declare -A _t_seen=()
_t_dupes=""
for PAGE in 1 2 3 4 5 6 7 8; do
    _page_annotations
    for (( i=0; i<${#PA_TEXT[@]}; i++ )); do
        t=${PA_TEXT[$i]}
        [[ -n "${_t_seen[$t]:-}" ]] && _t_dupes+=" p$PAGE.s$((i+1))"
        _t_seen[$t]="p$PAGE.s$((i+1))"
    done
done
check "every callout sentence in the tour is distinct" "$_t_dupes" ""
# …and the stronger form: on a page that is NOT walking one property across a fixed specimen,
# pointing twice at the same box is what "nothing new to say" looks like. Pages 2, 3, 6 and 8
# are the four that do walk one — the nine anchors on one control, the four sides on one
# control, the beacon variants on two labelled boxes, and the big arrow's exits and smoothing
# rungs on one button — and there the repeat IS the lesson.
_t_repeats=""
for PAGE in 1 4 5 7; do
    _page_annotations
    declare -A _t_tg=()
    for (( i=0; i<${#PA_TARGET[@]}; i++ )); do
        [[ -n "${_t_tg[${PA_TARGET[$i]}]:-}" ]] && _t_repeats+=" p$PAGE:${PA_TARGET[$i]}"
        _t_tg[${PA_TARGET[$i]}]=1
    done
    unset _t_tg
done
check "outside pages 2, 3, 6 and 8, every step points at a DIFFERENT control" "$_t_repeats" ""
PAGE=6; _page_annotations
_t_p6targets=""
for (( i=0; i<${#PA_TARGET[@]}; i++ )); do _t_p6targets+=" ${PA_TARGET[$i]}"; done
check "…and page 6 walks its variants across the two labelled specimen boxes" \
      "$_t_p6targets" " specA specB specB specA specB"

note "THE SENTENCE-LENGTH CEILINGS — load-bearing, not editorial"
# A chip's height is its sentence divided by its wrap width. On the pages whose lesson is the
# space AROUND a target, one line more is a chip that no longer fits the band it has to sit in,
# and the engine's honest answer to "no room above" is to place below and cross the target.
# These three numbers were measured, not chosen (see _metrics and the annotations):
#   page 2  ≤100  wraps to 2 lines at the calloutWidth an 80×30 frame can give it
#   page 3  ≤112  wraps to 3 lines, a 5-row chip, which fits both 7-row bands round #hub
#   page 6  ≤130  above this the chip is rewrapped to a third of its ceiling and starts
#                 breaking words mid-token (`variant=fram` / `e`)
_t_longest() { PAGE=$1; _page_annotations; local i m=0
    for (( i=0; i<${#PA_TEXT[@]}; i++ )); do (( ${#PA_TEXT[$i]} > m )) && m=${#PA_TEXT[$i]}; done
    FT_RET=$m; }
_t_longest 2; check "page 2's longest sentence is ≤100 characters (is $FT_RET)" "$(( FT_RET <= 100 ))" 1
_t_longest 3; check "page 3's longest sentence is ≤112 characters (is $FT_RET)" "$(( FT_RET <= 112 ))" 1
_t_longest 6; check "page 6's longest sentence is ≤130 characters (is $FT_RET)" "$(( FT_RET <= 130 ))" 1
# …and the OVERRULE sentences live under page 3's ceiling too: _p3_reconcile swaps one in at
# exactly the sizes where space is scarcest, so an over-ceiling overrule sentence would undo
# the fix it exists to deliver. There are twelve now — one per requested→achieved pair,
# because the overrule names BOTH sides — and every one is measured.
_t_om=0
for _s in above below left right; do
    for _a in above below left right; do
        [[ "$_a" == "$_s" ]] && continue
        _p3_overrule "$_s" "$_a"; (( ${#FT_RET} > _t_om )) && _t_om=${#FT_RET}
    done
done
check "…and page 3's overrule sentences are ≤112 as well (longest is $_t_om)" "$(( _t_om <= 112 ))" 1

note "page 3's promises hedge, and its overrules name both sides"
# The honoured wording must already admit that place= is a bias — "space permitting" — so the
# reader is never promised a side unconditionally; and an overrule must say which side was
# asked for AND which side the engine gave, so the reader can see both halves of the decision.
PAGE=3; _page_annotations
_t_hedge=""
for _i in 1 2 3 4; do
    [[ "${PA_TEXT[$_i]}" == *"space permitting"* ]] || _t_hedge+=" s$((_i+1))"
done
check "every side-naming promise says 'space permitting'" "$_t_hedge" ""
_t_names=""
for _s in above below left right; do
    for _a in above below left right; do
        [[ "$_a" == "$_s" ]] && continue
        _p3_overrule "$_s" "$_a"
        [[ "$FT_RET" == *"place=$_s"* ]]         || _t_names+=" $_s→$_a(requested unnamed)"
        [[ "$FT_RET" == *"went $_a instead"* ]]  || _t_names+=" $_s→$_a(achieved unnamed)"
        [[ "$FT_RET" == *"space permitting"* ]]  || _t_names+=" $_s→$_a(no hedge)"
    done
done
check "every overrule names the requested side and the achieved side" "$_t_names" ""
# The drag step's sentence has its own, tighter ceiling: it must wrap to THREE lines at every
# width the placer will try on page 7's stage, or the 5-row box becomes 6, misses the stage's
# free band, and the arrow the drag lesson depends on is the first thing to go (measured at
# 56×38 — see the annotation).
PAGE=7; _page_annotations
check "the drag step's sentence is ≤102 characters (is ${#PA_TEXT[4]})" "$(( ${#PA_TEXT[4]} <= 102 ))" 1

note "no user-facing string says 'chip' — it is undefined jargon to a reader"
# Reported verbatim: "WTF is a chip????? as a user I have no idea what you're talking about."
# Every string the demo can put on the SCREEN is swept: the step sentences, the concept
# paragraph, the NOTE pane, the generated call lines, the page title, and the overrule
# sentences. Code comments may keep the word; the reader never sees those.
_t_chip=""
for PAGE in 1 2 3 4 5 6 7 8; do
    STEP=1; _page_annotations
    title=""; CONCEPT=""; CALL=""; NOTE=""; CALL_ONELINE=""
    _page_content
    for (( i=0; i<${#PA_TEXT[@]}; i++ )); do
        [[ "${PA_TEXT[$i]}" == *[Cc]hip* ]] && _t_chip+=" p$PAGE.s$((i+1))"
    done
    [[ "$title"        == *[Cc]hip* ]] && _t_chip+=" p$PAGE:title"
    [[ "$CONCEPT"      == *[Cc]hip* ]] && _t_chip+=" p$PAGE:concept"
    [[ "$NOTE"         == *[Cc]hip* ]] && _t_chip+=" p$PAGE:note"
    [[ "$CALL"         == *[Cc]hip* ]] && _t_chip+=" p$PAGE:call"
    [[ "$CALL_ONELINE" == *[Cc]hip* ]] && _t_chip+=" p$PAGE:calline"
done
for _s in above below left right; do
    for _a in above below left right; do
        [[ "$_a" == "$_s" ]] && continue
        _p3_overrule "$_s" "$_a"
        [[ "$FT_RET" == *[Cc]hip* ]] && _t_chip+=" overrule:$_s→$_a"
    done
done
check "'chip' appears in no sentence, concept, note, call line or title" "$_t_chip" ""

# ═════════════════════════════════════════════════════════════════════════════
# THE GEOMETRY SWEEP — EVERY STEP, EVERY PAGE, FOUR SIZES.
#
# 80×30 is the smallest terminal the demo claims to support; 84×34 and 120×40 are the two the
# defects were reported at; 171×45 is a full-screen one. They straddle all three pane layouts
# (`line`, `row`, `side`), which is what actually varies: a callout's placement is a search over
# whatever space happens to be free, so a demo that behaves at one width can be broken at every
# other one.
#
# One build per PAGE and then _goto_step per step — the same path the ◀ ▶ arrows take, and the
# reason four sizes cost about what two used to.
_t_sizes=("80 30" "84 34" "120 40" "171 45")
declare -A _t_fail_cross=() _t_fail_chrome=() _t_fail_ring=() _t_fail_bound=() \
           _t_fail_cover=() _t_fail_stub=() _t_fail_axis=() _t_fail_headin=() \
           _t_fail_place=() _t_fail_missing=() _t_fail_fit=()
declare -A _t_anchor_verdict=()     # "SIZE|anchor" → "hit|got|want"

# ── PAGE 3 MUST NEVER LIE ────────────────────────────────────────────────────
# place= is a bias, and on a cramped screen the engine may overrule it — which is the page's
# own lesson, so the failure mode is not the overrule, it is a sentence still promising the
# side that was refused ("place=left, and the head turns to ▶", drawn from underneath —
# reported as "all lies" at 62×40, fairly). _p3_reconcile in the demo swaps in the overrule
# sentence after reading the achieved side back off FT_BEACON_PC; this makes skipping the swap
# untestable:
#   · the LIVE text must be the PROMISE when the engine honoured the request and the demo's
#     own _p3_overrule sentence when it did not;
#   · a shown promise must be TRUE in the frame — and only what the sentence actually claims
#     is asserted. s2/s3 claim the BOX is above/below, so the box side is checked; s4/s5 claim
#     the HEAD is a ▶/◀ into the facing edge, so the head is checked. An honoured place=left
#     may legitimately park the box diagonally up-left and hook its arrow into the left edge
#     (84×34 does exactly that) — the box's quadrant is the engine's business, the arrow is
#     the promise.
_t_p3_truth() {                 # requested-side → appends any lie to _t_fail_place[$_t_key]
    local pl=$1 live
    ft_resolved_prop stepcallout text ""; live=$FT_RET
    if [[ "$T_SIDE_PC" == "$pl" ]]; then
        [[ "$live" == "${PA_TEXT[$((STEP-1))]}" ]] \
            || _t_fail_place[$_t_key]+=" $_t_id(honoured but showing the overrule text)"
        case "$pl" in
            above|below) [[ "$T_SIDE_GEOM" == "$pl" ]] \
                || _t_fail_place[$_t_key]+=" $_t_id(box=$T_SIDE_GEOM want=$pl)" ;;
            left)  { [[ "$T_LASTAX" == h ]] && (( T_HEAD_C < T_TL )); } \
                || _t_fail_place[$_t_key]+=" $_t_id(head is not a ▶ into the left edge)" ;;
            right) { [[ "$T_LASTAX" == h ]] && (( T_HEAD_C > T_TR )); } \
                || _t_fail_place[$_t_key]+=" $_t_id(head is not a ◀ into the right edge)" ;;
        esac
    else
        # The overrule wording names the achieved side, so matching it verbatim IS the check
        # that the sentence tells the reader where the callout really went.
        _p3_overrule "$pl" "$T_SIDE_PC"
        [[ "$live" == "$FT_RET" ]] \
            || _t_fail_place[$_t_key]+=" $_t_id(overruled to $T_SIDE_PC, text does not name it)"
    fi
}

for _size in "${_t_sizes[@]}"; do
    set -- $_size; FT_COLS=$1; FT_ROWS=$2
    _t_key="${FT_COLS}×${FT_ROWS}"
    for PAGE in 1 2 3 4 5 6 7 8; do
        STEP=1
        _resize >/dev/null 2>&1     # the demo's own SIGWINCH path — NOT just the globals,
        settle >/dev/null 2>&1   # ft_run settles the burst; a gate must too
                                    # or every "size" re-tests the same layout
        _page_annotations; n=${#PA_TARGET[@]}
        # The frame must still fit the screen: a layout that overflows is how css-demo ends up
        # clipping its own code panes at 80 columns.
        (( ${FT_MEASURED_WIDTH[win]:-9999}  <= FT_COLS )) || _t_fail_fit[$_t_key]+=" p$PAGE:w"
        (( ${FT_MEASURED_HEIGHT[win]:-9999} <= FT_ROWS )) || _t_fail_fit[$_t_key]+=" p$PAGE:h"
        for (( STEP=1; STEP<=n; STEP++ )); do
            _goto_step >/dev/null 2>&1
            settle >/dev/null 2>&1   # ft_run settles the burst; a gate must too
            a=${PA_ANCHOR[$((STEP-1))]}; pl=${PA_PLACE[$((STEP-1))]}
            _t_id="p$PAGE.s$STEP"
            if ! _t_collect; then _t_fail_missing[$_t_key]+=" $_t_id"; continue; fi

            # (a) THE LEADER NEVER CROSSES ITS OWN TARGET. The target is a routing obstacle:
            #     a line drawn over the control it is pointing at reads as a line pointing at
            #     something behind it. centerCenter is the sole exception and the sole anchor
            #     whose entire meaning is "into the middle".
            if [[ "$a" != centerCenter ]]; then
                _t_poly_in_rect "$T_POLY" "$T_TT" "$T_TL" "$T_TB" "$T_TR"
                (( FT_RET )) && _t_fail_cross[$_t_key]+=" $_t_id=$FT_RET"
            fi
            # (b) THE CHIP KEEPS OFF THE DOCKED CHROME AND OFF EVERY DRAWN BORDER RING.
            _t_chip_on_chrome; (( FT_RET )) && _t_fail_chrome[$_t_key]+=" $_t_id=$FT_RET"
            _t_chip_on_ring;   (( FT_RET )) && _t_fail_ring[$_t_key]+=" $_t_id=$FT_RET"
            # (d) …AND STAYS INSIDE ITS BOUND: the boundBox when one is set, else the screen.
            _t_boundbox
            (( T_BOX_T >= T_BB_T && T_BOX_L >= T_BB_L && T_BOX_B <= T_BB_B && T_BOX_R <= T_BB_R )) \
                || _t_fail_bound[$_t_key]+=" $_t_id(box=$T_BOX_T,$T_BOX_L..$T_BOX_B,$T_BOX_R in $T_BB=$T_BB_T,$T_BB_L..$T_BB_B,$T_BB_R)"
            # (f) the chip is not on its own target, and the leader is a real line
            _t_box_covers_target; (( FT_RET )) && _t_fail_cover[$_t_key]+=" $_t_id=$FT_RET"
            # A LEADERLESS CHIP IS A DELIBERATE OUTCOME, not a stub. Where the screen leaves the
            # chip hard against its target there is no line to draw and no room for an arrowhead,
            # and the engine paints neither rather than wedge an arrow between two borders. Every
            # assertion below is about a LINE, so they have nothing to say here — what has to hold
            # instead is that the chip really is against its target, which (f) above already
            # covers through "no chip sits on the thing it points at" plus the bound-box check.
            if [[ -z "$T_POLY" ]]; then
                (( T_BOX_T <= T_TB + 2 && T_BOX_B >= T_TT - 2 &&
                   T_BOX_L <= T_TR + 3 && T_BOX_R >= T_TL - 3 )) \
                    || _t_fail_stub[$_t_key]+=" $_t_id(leaderless but not adjacent)"
                continue
            fi
            (( T_LEN >= 1 )) || _t_fail_stub[$_t_key]+=" $_t_id"
            # the leader arrives along its arrowhead's own axis, and only centerCenter's head
            # may be inside the target at all
            if [[ "$a" != centerCenter ]]; then
                _t_head_axis
                [[ "$T_LASTAX" == "$T_AXIS" ]] || _t_fail_axis[$_t_key]+=" $_t_id($T_LASTAX/$T_AXIS)"
                (( T_HEAD_R >= T_TT && T_HEAD_R <= T_TB && T_HEAD_C >= T_TL && T_HEAD_C <= T_TR )) \
                    && _t_fail_headin[$_t_key]+=" $_t_id"
            fi
            # (c) PAGE 2: the head lands on exactly the point the anchor names.
            if (( PAGE == 2 )); then
                if [[ "$a" == auto ]]; then
                    # auto resolves to the MIDDLE of whichever side the chip landed on — one of
                    # exactly four points, never a corner. WHICH of the four is the placer's
                    # business, not the test's.
                    mr=$(( (T_TT+T_TB)/2 )); mc=$(( (T_TL+T_TR)/2 )); hit=0
                    (( T_HEAD_R == T_TT-1 && T_HEAD_C == mc )) && hit=1
                    (( T_HEAD_R == T_TB+1 && T_HEAD_C == mc )) && hit=1
                    (( T_HEAD_R == mr && T_HEAD_C == T_TL-2 )) && hit=1
                    (( T_HEAD_R == mr && T_HEAD_C == T_TR+2 )) && hit=1
                    _t_anchor_verdict["$_t_key|$a"]="$hit|$T_HEAD_R,$T_HEAD_C|middle of a side"
                else
                    _t_expect_anchor "$a"
                    _t_anchor_verdict["$_t_key|$a"]="$(( T_HEAD_R == T_EXP_R && T_HEAD_C == T_EXP_C ? 1 : 0 ))|$T_HEAD_R,$T_HEAD_C|$T_EXP_R,$T_EXP_C"
                fi
            fi
            # (e) PAGE 3 MUST NEVER LIE — see _t_p3_truth above the sweep.
            if (( PAGE == 3 )) && [[ "$pl" != auto ]]; then
                _t_p3_truth "$pl"
            fi
        done
    done
done

for _size in "${_t_sizes[@]}"; do
    set -- $_size; _t_key="$1×$2"
    note "every step of every page at $_t_key"
    check "every step placed a callout with a live target"        "${_t_fail_missing[$_t_key]:-}" ""
    check "no leader crosses its own target (centerCenter aside)" "${_t_fail_cross[$_t_key]:-}"   ""
    check "no chip lands on the key legend or the status bar"     "${_t_fail_chrome[$_t_key]:-}"  ""
    check "no chip lands on a drawn border ring"                  "${_t_fail_ring[$_t_key]:-}"    ""
    check "every chip is inside its bound (boundBox, else the screen)" "${_t_fail_bound[$_t_key]:-}" ""
    check "no chip sits on the thing it points at"                "${_t_fail_cover[$_t_key]:-}"   ""
    check "every leader is at least one cell of drawn line"       "${_t_fail_stub[$_t_key]:-}"    ""
    check "every leader enters its head along the head's axis"    "${_t_fail_axis[$_t_key]:-}"    ""
    check "only centerCenter puts its head inside the target"     "${_t_fail_headin[$_t_key]:-}"  ""
    check "page 3 tells the truth about the side it got"          "${_t_fail_place[$_t_key]:-}"   ""
    check "the frame still fits the terminal"                     "${_t_fail_fit[$_t_key]:-}"     ""
done

# ═════════════════════════════════════════════════════════════════════════════
note "page 3 tells the truth at the small sizes it was reported lying at"
# 56×38 and 62×40 straddle the report's terminal (~62×40): at these sizes some of the four
# named sides genuinely cannot hold the callout, so the OVERRULE path — the one the four
# canonical sizes barely exercise — is the path under test here.
for _size in "56 38" "62 40"; do
    set -- $_size; FT_COLS=$1; FT_ROWS=$2; _t_key="$1×$2"
    PAGE=3; STEP=1
    _resize >/dev/null 2>&1
    settle >/dev/null 2>&1   # ft_run settles the burst; a gate must too
    _page_annotations
    for STEP in 2 3 4 5; do
        _goto_step >/dev/null 2>&1
        settle >/dev/null 2>&1   # ft_run settles the burst; a gate must too
        # RECONCILE NEEDS A PLACEMENT, AND PLACEMENT HAPPENS AT PAINT. _goto_step calls
        # _p3_reconcile inline, where the placement it wants does not exist yet — under ft_run
        # that inline call reads the PREVIOUS step's placement and the trailing ft_redraw_dirty
        # the demo used to carry was a no-op inside a burst, so it never helped. The gate does
        # what the app's next frame does: settle, reconcile against the real placement, settle.
        # (The engine-side fix is a public "place this beacon now" that needs no frame; until
        # then the scaffolding lives here, not in the demo.)
        _p3_reconcile >/dev/null 2>&1
        settle >/dev/null 2>&1
        _t_id="p3.s$STEP"
        if ! _t_collect; then _t_fail_place[$_t_key]+=" $_t_id(no placement)"; continue; fi
        _t_p3_truth "${PA_PLACE[$((STEP-1))]}"
    done
    check "page 3 tells the truth about every named side at $_t_key" "${_t_fail_place[$_t_key]:-}" ""
done

# ═════════════════════════════════════════════════════════════════════════════
note "page 3's reconcile fixed point is BUILT: every wording is the same height"
# Naming the achieved side puts it into the text, the text into the placement key, and the
# placement key back into the achieved side — a cycle with a guaranteed fixed point ONLY if the
# text swap cannot change the box's shape. So every wording a step can show (its promise plus
# each of the three possible overrules) must wrap to the SAME line count at every width the
# placement search will try: the page's calloutWidth and the 2/3, 1/2, 1/3 rungs of _shape's
# ladder (see ft-beacon). Measured with ft_wrap — the engine's own wrapper — at the CALLOUT_W
# _metrics derives for every column width 56–70, the whole band the overrule was reported in.
# (At ≥112 columns CALLOUT_W widens to 44, but the sweep above pins all four sides HONOURED at
# 120×40 and 171×45 — the swap never fires there, so 38's ladder is the one that has to hold.)
_t_eqh=""
PAGE=3
declare -A _t_cw_seen=()
for (( _w=56; _w<=70; _w++ )); do
    FT_COLS=$_w; FT_ROWS=40
    _metrics
    [[ -n "${_t_cw_seen[$CALLOUT_W]:-}" ]] && continue      # same CALLOUT_W ⇒ same wraps
    _t_cw_seen[$CALLOUT_W]=$_w
    _page_annotations
    for _i in 1 2 3 4; do
        _req=${PA_PLACE[$_i]}
        for _lw in "$CALLOUT_W" $(( CALLOUT_W*2/3 )) $(( CALLOUT_W/2 )) $(( CALLOUT_W/3 )); do
            ft_wrap "${PA_TEXT[$_i]}" "$_lw"; _base=${#FT_WRAP_LINES[@]}
            for _a in above below left right; do
                [[ "$_a" == "$_req" ]] && continue
                _p3_overrule "$_req" "$_a"
                ft_wrap "$FT_RET" "$_lw"
                (( ${#FT_WRAP_LINES[@]} == _base )) \
                    || _t_eqh+=" ${_w}c:s$((_i+1)):w$_lw:$_req→$_a(${#FT_WRAP_LINES[@]}≠$_base)"
            done
        done
    done
done
check "promise and every overrule wrap to the same line count at every search width, 56–70 cols" \
      "$_t_eqh" ""

note "…and the fixed point is VERIFIED: placing a step twice is byte-identical"
# The construction above says the text swap cannot move the box; this replays the whole cycle
# and demands it. _goto_step places the promise, reconciles (possibly swapping in the overrule
# and re-placing), and settles; a second _goto_step runs the identical cycle from scratch. If
# the fixed point were not real — if the overrule wording re-placed to a different spot or a
# different side — the second pass would settle somewhere else, and FT_BEACON_PC or the routed
# leader would differ by at least a byte.
for _size in "56 38" "62 40" "70 40" "84 34"; do
    set -- $_size; FT_COLS=$1; FT_ROWS=$2; _t_key="$1×$2"
    PAGE=3; STEP=1
    _resize >/dev/null 2>&1
    settle >/dev/null 2>&1   # ft_run settles the burst; a gate must too
    _t_conv=""
    for STEP in 2 3 4 5; do
        _goto_step >/dev/null 2>&1
        settle >/dev/null 2>&1   # ft_run settles the burst; a gate must too
        _t_first="${FT_BEACON_PC[stepcallout]:-}|${FT_BEACON_LEADER[stepcallout]:-}"
        _goto_step >/dev/null 2>&1
        settle >/dev/null 2>&1   # ft_run settles the burst; a gate must too
        _t_second="${FT_BEACON_PC[stepcallout]:-}|${FT_BEACON_LEADER[stepcallout]:-}"
        [[ "$_t_second" == "$_t_first" ]] \
            || _t_conv+=" s$STEP(1st=$_t_first 2nd=$_t_second)"
    done
    check "page 3 placement converges — second placement byte-identical at $_t_key" "$_t_conv" ""
done

note "page 7's drag step demonstrates what it says, at the report's sizes"
# The reported frame (62×40) had the drag callout leaderless — 2 cells from the checkbox, so
# the engine rightly drew no arrow — while its text said "drag this chip": the reader took it
# as an instruction to drag the CHECKBOX. A drag lesson without an arrow cannot demonstrate
# re-attaching, so at every reported size the callout must draw a real line, keep off the
# stage's other controls AND the step nav, and its line must not punch through the textfield
# above the checkbox (the 56×38 failure once the line existed).
for _size in "56 38" "62 40" "84 34"; do
    set -- $_size; FT_COLS=$1; FT_ROWS=$2; _t_key="$1×$2"
    PAGE=7; STEP=1
    _resize >/dev/null 2>&1
    settle >/dev/null 2>&1   # ft_run settles the burst; a gate must too
    _page_annotations
    STEP=5; _goto_step >/dev/null 2>&1
    settle >/dev/null 2>&1   # ft_run settles the burst; a gate must too
    _t_id="p7.s5"; _t_drag=""
    if _t_collect; then
        (( T_LEN >= 3 )) || _t_drag+=" leader=${T_LEN}cells(want ≥3)"
        for _n in chromeBox dragChk boundChk stepnav btnrow; do
            _t_rect "$_n" || continue
            _t_overlap "$T_BOX_T" "$T_BOX_L" "$T_BOX_B" "$T_BOX_R" "$T_R_T" "$T_R_L" "$T_R_B" "$T_R_R"
            (( FT_RET )) && _t_drag+=" box-on-$_n=$FT_RET"
        done
        _t_rect chromeBox && { _t_poly_in_rect "$T_POLY" "$T_R_T" "$T_R_L" "$T_R_B" "$T_R_R"
                               (( FT_RET )) && _t_drag+=" line-through-chromeBox=$FT_RET"; }
    else
        _t_drag=" no placement"
    fi
    check "the drag callout has a real arrow and a clear home at $_t_key" "$_t_drag" ""
done

note "page 2: each anchor puts the arrowhead on exactly the point it names, at every size"
for _size in "${_t_sizes[@]}"; do
    set -- $_size; _t_key="$1×$2"
    for _a in auto topLeft topCenter topRight centerLeft centerRight \
              bottomLeft bottomCenter bottomRight centerCenter; do
        IFS='|' read -r _hit _got _want <<< "${_t_anchor_verdict["$_t_key|$_a"]:-0||}"
        if (( _hit )); then check "$_t_key anchor=$_a → head on the named point" 1 1
        else check "$_t_key anchor=$_a → head on the named point" 0 1
             printf '         head=%s expected=%s\n' "$_got" "$_want"; fi
    done
done

# ═════════════════════════════════════════════════════════════════════════════
# THE DEEP PASS — one size, fresh page builds, for everything that is not geometry.
FT_COLS=120; FT_ROWS=40; _resize >/dev/null 2>&1
settle >/dev/null 2>&1   # ft_run settles the burst; a gate must too
_t_wrongtype=""; _t_wrongtarget=""; _t_nonext=""; _t_extranext=""
_t_cc_row=0; _t_cc_col=0
_t_lastnextcell=""; _t_firstnextcell=""
declare -A _t_p3side=()
for PAGE in 1 2 3 4 5 6 7 8; do
    _page_annotations; n=${#PA_TARGET[@]}
    for (( STEP=1; STEP<=n; STEP++ )); do
        a=${PA_ANCHOR[$((STEP-1))]}
        _t_probe "$PAGE" "$STEP" || continue
        [[ "${FT_TYPE[stepcallout]:-}" == beacon ]] || _t_wrongtype+=" p$PAGE.s$STEP"
        ft_resolved_prop stepcallout variant ""; [[ "$FT_RET" == callout ]] || _t_wrongtype+=" p$PAGE.s$STEP"
        ft_resolved_prop stepcallout target "";  [[ "$FT_RET" == "$T_TGT" ]] || _t_wrongtarget+=" p$PAGE.s$STEP"
        if [[ "$a" == centerCenter ]]; then
            (( T_HEAD_R >= T_TT && T_HEAD_R <= T_TB )) && _t_cc_row=1
            (( T_HEAD_C >= T_TL && T_HEAD_C <= T_TR )) && _t_cc_col=1
        fi
        # ONE GLYPH, ONE MEANING: ▶ says "there is another step on THIS page", so the last step of
        # every page carries none. It used to mean "advance" — next step, or next PAGE on a
        # page's last step — and a reader reported exactly the ambiguity that creates: "I thought
        # it meant there are more steps, but then it showed up on the last steps of each page."
        # Moving between pages is the Okay button and the N key, which the legend names.
        if (( STEP == n )); then
            ft_has_listener stepcallout next && _t_extranext+=" p$PAGE.s$STEP"
            (( PAGE == LAST )) && _t_lastnextcell=${FT_BEACON_NEXT[stepcallout]:-}
        else
            ft_has_listener stepcallout next || _t_nonext+=" p$PAGE.s$STEP"
            (( PAGE == 1 && STEP == 1 )) && _t_firstnextcell=${FT_BEACON_NEXT[stepcallout]:-}
        fi
        (( PAGE == 3 )) && _t_p3side[$STEP]=$T_SIDE_PC
    done
done

note "every step raises a real callout whose target is a laid-out control (120×40)"
check "…and each is a variant=callout beacon"         "$_t_wrongtype" ""
check "…pointing at the control the annotation named" "$_t_wrongtarget" ""

note "centerCenter is the ONLY anchor whose head may sit on the target"
check "…and centerCenter's head IS inside it (row)"    "$_t_cc_row" 1
check "…and centerCenter's head IS inside it (column)" "$_t_cc_col" 1

note "page 3: a fresh build agrees with the stepped path about the side"
check "place=above → the chip really sits above its target" "${_t_p3side[2]:-}" above
check "place=below → the chip really sits below its target" "${_t_p3side[3]:-}" below
check "place=left  → the chip really sits left of it"       "${_t_p3side[4]:-}" left
check "place=right → the chip really sits right of it"      "${_t_p3side[5]:-}" right

note "onNext: ▶ means there is another step on THIS page — nothing else"
check "every step but its page's last wires a next listener"  "$_t_nonext" ""
check "…and every page's last step wires none (▶ would be a lie)" "$_t_extranext" ""
check "the very last callout draws no ▶ cell"     "$_t_lastnextcell" ""
[[ -n "$_t_firstnextcell" ]] && check "an ordinary callout DOES draw a ▶ cell" 1 1 \
                             || check "an ordinary callout DOES draw a ▶ cell" 0 1

# ═════════════════════════════════════════════════════════════════════════════
note "page 6 raises ONE lesson's specimens at a time, and names them in its text"
# The page used to keep three decorations up on all five steps whatever the step was about, so
# nothing changed when you stepped and no sentence said which mark it meant. What is on the
# stage now is exactly what the step's own sentence names — which is the property worth gating,
# because it is the one that made the page unreadable when it was missing.
_t_p6() {                       # step → T_P6 = "ringA ringB badge" (type or "-")
    _t_probe 6 "$1" >/dev/null
    T_P6="${FT_TYPE[specRingA]:-−} ${FT_TYPE[specRingB]:-−} ${FT_TYPE[specBadge]:-−}"
}
_t_p6 1; check "step 1 — the solid halo on Box A, and nothing else" "$T_P6" "beacon − −"
ft_resolved_prop specRingA variant ""; check "…and it is variant=frame" "$FT_RET" frame
_t_p6 2; check "step 2 — both boxes ringed, for the comparison the text makes" "$T_P6" "beacon beacon −"
ft_resolved_prop specRingB frameStyle ""; check "…and Box B's is the dashed ghost" "$FT_RET" dashed
_t_p6 3; check "step 3 — no ring at all, just the badge on Box B" "$T_P6" "− − beacon"
ft_resolved_prop specBadge variant ""; check "…and it is variant=number"   "$FT_RET" number
ft_resolved_prop specBadge corner "";  check "…parked at a named corner"   "$FT_RET" topright
ft_resolved_prop specBadge number "";  check "…numbered so it cannot be read as a step badge" "$FT_RET" 9
_t_p6 4; check "step 4 — one ring again, the one that animates" "$T_P6" "beacon − −"
ft_resolved_prop specRingA effect ""; check "…and effect=pulse is really on it" "$FT_RET" pulse
_t_p6 5; check "step 5 — two rings, one of each lifetime" "$T_P6" "beacon beacon −"
ft_resolved_prop specRingA lifetime ""; check "…Box A's persists"  "$FT_RET" persist
ft_resolved_prop specRingB lifetime ""; check "…and Box B's is a real oneshot, not a narrated one" "$FT_RET" oneshot
# …and gone again the moment the page changes. A beacon paints outside its own layout box, so
# nothing but an explicit ft_remove can clean one up.
_t_probe 7 1 >/dev/null
check "the specimens are gone once the page changes" \
      "${FT_TYPE[specRingA]:-−}${FT_TYPE[specRingB]:-−}${FT_TYPE[specBadge]:-−}" "−−−"

# ═════════════════════════════════════════════════════════════════════════════
note "the code pane shows the call that drew the box currently on screen"
# `call` is a scrollable textfield in three pane modes and a plain label in the fourth, and the
# two carry their content under different property names. Ask the control what it is — the
# compass page is always in the one-line mode, so hard-coding `value` here read an empty string
# and passed nothing.
_t_call_text() { if [[ "${FT_TYPE[call]:-}" == label ]]; then ft_resolved_prop call text ""
                 else ft_resolved_prop call value ""; fi; }
FT_COLS=120; FT_ROWS=40; _resize >/dev/null 2>&1
settle >/dev/null 2>&1   # ft_run settles the burst; a gate must too
_t_probe 2 5 >/dev/null; _t_call_text; _t_p2s5_call=$FT_RET
case "$_t_p2s5_call" in *"target=compass"*)    check "the pane names the live target" 1 1 ;;
                        *)                     check "the pane names the live target" 0 1 ;; esac
case "$_t_p2s5_call" in *"anchor=centerLeft"*) check "…and the live anchor" 1 1 ;;
                        *)                     check "…and the live anchor" 0 1 ;; esac
case "$_t_p2s5_call" in *"number=5"*)          check "…and the live step number" 1 1 ;;
                        *)                     check "…and the live step number" 0 1 ;; esac
# Stepping must update it WITHOUT rebuilding the page — _goto_step is the cheap path the
# arrows use, and a pane it forgot to refresh would describe the previous step's box.
PAGE=2; STEP=5; _show_page >/dev/null 2>&1
settle >/dev/null 2>&1   # ft_run settles the burst; a gate must too
btnStepNext_on_activate >/dev/null 2>&1
_t_call_text
case "$FT_RET" in *"anchor=centerRight"*) check "◀▶ refresh the pane without a page rebuild" 1 1 ;;
                  *)                      check "◀▶ refresh the pane without a page rebuild" 0 1 ;; esac

note "TWO orthogonal axes — ◀▶ step WITHIN a page, Okay/Back move PAGES"
PAGE=1; STEP=1; _page_annotations; n1=${#PA_TARGET[@]}
btnStepNext_on_activate >/dev/null 2>&1; check "▶ advances the step, same page" "$PAGE/$STEP" "1/2"
STEP=$n1; btnStepNext_on_activate >/dev/null 2>&1
check "▶ at the last step does NOT change page" "$PAGE/$STEP" "1/$n1"
btnStepPrev_on_activate >/dev/null 2>&1; check "◀ steps back within the page" "$PAGE/$STEP" "1/$((n1-1))"
STEP=2; btnOk_on_activate; check "Okay jumps to the next PAGE at step 1" "$PAGE/$STEP" "2/1"
btnBack_on_activate;       check "Back returns to the previous PAGE at step 1" "$PAGE/$STEP" "1/1"

note "E cycles the callout's own effect through the four the beacon implements"
PAGE=1; STEP=1; _show_page >/dev/null 2>&1
settle >/dev/null 2>&1   # ft_run settles the burst; a gate must too
check "the callout is static by default (an idle event loop)" "$CALLOUT_EFFECT" none
for _want in pulse blink bob none; do
    _cycle_effect >/dev/null 2>&1
    ft_resolved_prop stepcallout effect ""
    check "E → effect=$_want, on the beacon itself" "$FT_RET" "$_want"
done

note "R sends a dragged callout home"
# THIS ASSERTED ON AN ARRAY THAT DOES NOT EXIST. `FT_BEACON_DRAG` was replaced by the ordinary
# properties parkedTop/parkedLeft (see controls/ft-beacon.bash) and is declared nowhere — so
# writing FT_BEACON_DRAG[stepcallout] made bash create an INDEXED array, evaluate the subscript
# as arithmetic to 0, and store it there; the demo's R key unset the same slot and the check
# went green. Both halves were talking about a table the framework had deleted, and the feature
# the key advertises has been inert ever since. Ask the engine instead.
ft_set stepcallout parkedTop=4 parkedLeft=9
ok  "…parked first, or 'forgotten' means nothing" _ft_beacon_park stepcallout
_reset_drag >/dev/null 2>&1
no  "R forgets the parked position"               _ft_beacon_park stepcallout
ft_get stepcallout parkedTop
check "…and the property really is gone"          "${FT_RET:-unset}" unset

note "no accessKey on any page promises a shortcut that cannot fire"
_t_conflicts=""
for PAGE in 1 2 3 4 5 6 7 8; do
    STEP=1; _show_page >/dev/null 2>&1
    settle >/dev/null 2>&1   # ft_run settles the burst; a gate must too
    ft_accesskey_conflicts
    [[ -n "$FT_RET" ]] && _t_conflicts+=" p$PAGE:$FT_RET"
done
check "every underlined letter reaches its control" "$_t_conflicts" ""

# ══ Page 8 — the big arrow ═══════════════════════════════════════════════════
# The page exists to be LOOKED at, so what it is checked for is what a reader would notice:
# an arrow is actually raised, it points at the specimen, it is on the side the page pins it
# to, it does not sit on the step callout it shares the stage with, and its lifetime says it
# will leave. Swept at the same four sizes as everything else above.
note "page 8 raises a big arrow that shares the stage without fighting it"
_t8_missing=""; _t8_wrongside=""; _t8_onchip=""; _t8_persist=""; _t8_compared=0; _t8_drew=0
for _t8size in "80 30" "84 34" "120 40" "171 45"; do
    set -- $_t8size
    FT_COLS=$1; FT_ROWS=$2
    ft_set app width="$FT_COLS" height="$FT_ROWS"
    PAGE=8
    for STEP in 1 2 3 4 5 6 7; do
        _show_page >/dev/null 2>&1
        settle >/dev/null 2>&1   # ft_run settles the burst; a gate must too
        if [[ -z "${FT_TYPE[specArrow]:-}" ]]; then _t8_missing+=" ${1}x${2}:s$STEP"; continue; fi
        # lifetime: the two steps ABOUT leaving must be oneshot. They are 5 and 6 since the page
        # grew the two rungs of the size ladder — read the step's own annotation row rather than
        # hard-coding a number here, so renumbering the page cannot silently disarm this.
        ft_resolved_prop specArrow lifetime persist
        case "${PA_ARROW[$(( STEP - 1 ))]:-}" in
            *exit=*) [[ "$FT_RET" == oneshot ]] || _t8_persist+=" ${1}x${2}:s$STEP=$FT_RET" ;;
        esac
        ft_clip_reset; _ft_beacon_rect specArrow
        if ! _ft_bigarrow_geometry specArrow -1; then continue; fi   # suppressed: no room, honest
        (( _t8_drew++ ))
        # the page pins place=left, so the arrow must point RIGHT and sit left of its target
        [[ "$FT_BIGARROW_DIRECTION" == right ]] || _t8_wrongside+=" ${1}x${2}:s$STEP=$FT_BIGARROW_DIRECTION"
        (( FT_BIGARROW_HOME_LEFT + FT_BIGARROW_COLUMNS - 1 < FT_BEACON_RECT_LEFT )) || _t8_wrongside+=" ${1}x${2}:s$STEP=overlapsTarget"
        # …and it must not be drawn through the chip it shares the stage with
        if [[ -n "${FT_BEACON_BOX[stepcallout]:-}" ]]; then
            _t_rect_overlap_ok=1
            read -r _c8t _c8l _c8b _c8r <<< "${FT_BEACON_BOX[stepcallout]}"
            _t_overlap "$FT_BIGARROW_HOME_TOP" "$FT_BIGARROW_HOME_LEFT" $(( FT_BIGARROW_HOME_TOP + FT_BIGARROW_ROWS - 1 )) $(( FT_BIGARROW_HOME_LEFT + FT_BIGARROW_COLUMNS - 1 )) \
                       "$_c8t" "$_c8l" "$_c8b" "$_c8r"
            (( FT_RET > 0 )) && _t8_onchip+=" ${1}x${2}:s$STEP=$FT_RET"
            (( _t8_compared++ ))
        fi
    done
done
check "page 8 raises its arrow at every size and step"   "$_t8_missing"   ""
check "…pointing the way the page pins it"               "$_t8_wrongside" ""
check "…never through the step callout's chip"           "$_t8_onchip"    ""
check "…and every step about leaving really does leave"  "$_t8_persist"   ""
# THE TEETH. Both geometric assertions above are of the form "this list of violations is
# empty", and a list stays empty just as convincingly when the loop never looked at anything —
# the arrow suppressed at every size, or the chip's box never published. An empty result has to
# be an empty result FROM SOMETHING, so say how many comparisons produced it.
check "…and those were real comparisons, not an empty sweep" \
      "$(( _t8_drew >= 15 && _t8_compared >= 15 ))" "1"



# ═══ PAGE 3 NEVER LIES, AND THE FIX FOR IT ACTUALLY RUNS ═════════════════════
# `place=` is a BIAS: on a small enough screen the engine overrules a named side, which is the
# page's own lesson. What must never happen is the callout carrying the PROMISE sentence while
# sitting on the side it was refused — a reader's verdict on that was "all lies". _p3_reconcile
# exists to swap in a sentence naming BOTH sides.
#
# IT RAN FROM THE FIRST DAY AND NEVER FIRED. Placement is computed at paint; the reconcile runs
# from the step handler; the step handler does not paint. `ft_beacon_side` had nothing to answer
# with and the function took its `|| return 0` every time. This is the gate that would have said
# so: it drives the app's own step path and NEVER settles, then demands the text be exactly the
# overrule sentence.
note "page 3's overrule reconciles in the step handler, with no frame"
_t_p3_found=0; _t_p3_wrong=""; _t_p3_sides=""
for _t_p3size in "62 40" "70 34" "80 30" "100 40"; do
    set -- $_t_p3size
    FT_COLS=$1; FT_ROWS=$2
    PAGE=3; STEP=1; _resize >/dev/null 2>&1; _page_annotations
    for _t_st in 2 3 4 5; do
        STEP=$_t_st
        _goto_step >/dev/null 2>&1              # the cheap step path — deliberately no paint
        _page_annotations
        _t_req=${PA_PLACE[$(( _t_st - 1 ))]:-auto}
        [[ "$_t_req" == auto ]] && continue
        ft_beacon_side stepcallout || { _t_p3_wrong+=" ${1}x${2}:s$_t_st:unplaced"; continue; }
        _t_ach=$FT_RET
        _t_p3_sides+=" $_t_ach"
        ft_resolved_prop stepcallout text ""; _t_have=$FT_RET
        if [[ "$_t_ach" == "$_t_req" ]]; then _t_want=${PA_TEXT[$(( _t_st - 1 ))]}
        else _t_p3_found=1; _p3_overrule "$_t_req" "$_t_ach"; _t_want=$FT_RET; fi
        # EXACT, not a substring: the overrule sentence names BOTH sides, so "does it contain the
        # achieved side" is true of the promise sentence too and would pass on the broken code.
        [[ "$_t_have" == "$_t_want" ]] || _t_p3_wrong+=" ${1}x${2}:s$_t_st"
    done
done
check "every step's sentence matches the side the engine chose" "$_t_p3_wrong" ""
check "…and the sweep found a size where the engine OVERRULES" "$_t_p3_found" "1"
check "…and it read real sides, not empties (anti-vacuity)" \
      "$(( $(printf '%s\n' $_t_p3_sides | grep -c .) >= 8 ))" "1"

note "…and the swap does not move the box, which is why there is no retry loop"
# _p3_reconcile used to loop up to three times because the side it read could be stale. With the
# placement forced before the sentence is chosen it reads once — sound only while the swap cannot
# change the box, which page 3's wordings are engineered for (identical line counts at every
# search width). Assumption until measured: swap, place again, compare.
_t_p3_moved=""
FT_COLS=62; FT_ROWS=40
PAGE=3; STEP=1; _resize >/dev/null 2>&1
for _t_st in 2 3 4 5; do
    STEP=$_t_st; _goto_step >/dev/null 2>&1; _page_annotations
    _t_req=${PA_PLACE[$(( _t_st - 1 ))]:-auto}
    [[ "$_t_req" == auto ]] && continue
    ft_beacon_side stepcallout || continue
    _t_before=$FT_RET
    ft_beacon_place stepcallout >/dev/null 2>&1
    ft_beacon_side stepcallout || continue
    [[ "$FT_RET" == "$_t_before" ]] || _t_p3_moved+=" s$_t_st($_t_before→$FT_RET)"
done
check "re-placing after the swap lands on the same side" "$_t_p3_moved" ""

summary
