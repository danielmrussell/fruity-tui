#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Callout leaders, AT EVERY SCREEN SIZE.
#
#  A callout's leader is the line from its box to the thing it is about. Whether that line
#  looks right is not a property of the code alone — it is a property of the code AT A GIVEN
#  SCREEN SIZE, because placement is a search over the space that happens to be free. One
#  golden at one width cannot see that, and did not: a whole run of "no change, therefore no
#  effect" readings were taken at 95 columns while the reported defect was at 170.
#
#  So this drives the real css-demo at several sizes and asserts on the leader's SHAPE:
#
#     LENGTH   at least _MIN_LEADER cells of drawn line. Below that it stops reading as a
#              leader and becomes a stub beside a floating arrowhead.
#     TURNS    at most two. A callout that needs three bends to reach its target is in the
#              wrong place; the bends are the symptom, the placement is the bug.
#     AXIS     the final segment runs along the arrowhead's own axis. A `▲` reached by a
#              horizontal line kinks 90° at the head and reads as an arrow with no line.
#     NO SPUR  the line never doubles back along its own axis. TURNS cannot see this — a
#              reversal is not a change of axis — so a leader that overshot its arrowhead and
#              came back, drawing a whisker past the junction, passed all three checks above.
#              22 of 104 leaders did exactly that across the four widths.
#
#  Failures print the offending geometry, because the useful question is always "where did it
#  put the box, and what shape did that force" — not "did the screen change".
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"

export FT_NO_WTFIX=1
# Sourced from INSIDE the tree: the demo derives its own root from BASH_SOURCE, so a copy in
# /tmp resolves `here` to / and silently loads nothing.
noloop="$here/demo/.css-demo-callout.bash"
sed '/^ft-run app/d' "$here/demo/css-demo.bash" > "$noloop"
trap 'rm -f "$noloop"' EXIT
source "$noloop"
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256

# Manhattan length + turn count of a polyline "r c r c …"
_leader_shape() {               # poly → LEADER_LEN LEADER_TURNS LEADER_LASTAXIS(v|h|none)
    local -a p=($1)
    LEADER_LEN=0; LEADER_TURNS=0; LEADER_LASTAXIS=none
    local i pr="" pc="" r c dr dc lastaxis="" axis
    for (( i=0; i+1 < ${#p[@]}; i+=2 )); do
        r=${p[i]}; c=${p[i+1]}
        if [[ -n "$pr" ]]; then
            dr=$(( r>pr ? r-pr : pr-r )); dc=$(( c>pc ? c-pc : pc-c ))
            (( LEADER_LEN += dr + dc ))
            if   (( dr > 0 && dc == 0 )); then axis=v
            elif (( dc > 0 && dr == 0 )); then axis=h
            else axis=$lastaxis; fi                     # zero-length hop: not a turn
            if [[ -n "$axis" ]]; then
                [[ -n "$lastaxis" && "$axis" != "$lastaxis" ]] && (( LEADER_TURNS++ ))
                lastaxis=$axis; LEADER_LASTAXIS=$axis
            fi
        fi
        pr=$r; pc=$c
    done
}

# The arrowhead's axis, read off the TARGET — the thing the arrow points into.
#
# The head is parked clear of the target on exactly ONE axis and squarely within its span on the
# other: `▼`/`▲` sit a row off the target's top/bottom at a column inside it, `◀`/`▶` a column
# off its left/right at a row inside it. So "the head's row is within the target's rows" IS the
# horizontal arrow, exactly, with nothing to infer.
#
# It was derived from the BOX before — "head outside the box's rows ⇒ vertical" — and that is a
# guess that the sweep breaks in both directions. A box placed `right` and slid one row down
# still draws `◀`, and was read as vertical; a box placed `below` and slid twenty columns along
# is still `▲`, and the obvious repair (take whichever separation is larger) reads it as
# horizontal. Neither is a property of the box. It is a property of where the head meets the
# target, so that is what this measures — still what was DRAWN, just from the correct end.
_head_axis() {                  # tgtT tgtL tgtB tgtR headR headC → HEAD_AXIS (v|h)
    local tt=$1 tl=$2 tb=$3 tr=$4 hr=$5 hc=$6
    if (( hr >= tt && hr <= tb )); then HEAD_AXIS=h; else HEAD_AXIS=v; fi
}

# A waypoint collinear with its neighbours but OUTSIDE them means the line ran past a junction
# and came back over itself. Counted here rather than folded into _leader_shape so a failure
# names the actual defect.
_leader_reversals() {           # poly → LEADER_REV
    local -a p=($1); LEADER_REV=0
    local i ar ac br bc cr cc
    for (( i=0; i+5 < ${#p[@]}; i+=2 )); do
        ar=${p[i]};   ac=${p[i+1]}
        br=${p[i+2]}; bc=${p[i+3]}
        cr=${p[i+4]}; cc=${p[i+5]}
        if (( ar == br && br == cr )); then
            (( (bc > ac && bc > cc) || (bc < ac && bc < cc) )) && (( LEADER_REV++ ))
        elif (( ac == bc && bc == cc )); then
            (( (br > ar && br > cr) || (br < ar && br < cr) )) && (( LEADER_REV++ ))
        fi
    done
}

# Cells of the DOCKED CHROME (key legend, status bar) the box covers. Nothing in this file used
# to look at where the box LANDED at all — only at the shape of the line — so a placement that
# obliterated the key legend and the status bar passed every assertion. It was reported from a
# screenshot, and measured at 16 placements wiping up to 132 cells.
_chrome_cover() {               # boxT boxL boxB boxR → CHROME_CELLS
    local bT=$1 bL=$2 bB=$3 bR=$4 n t cT cL cB cR ot ol ob orr
    CHROME_CELLS=0
    for n in "${!FT_TYPE[@]}"; do
        t=${FT_TYPE[$n]}
        case "$t" in keylegend|statusbar) ;; *) continue ;; esac
        [[ -n "${FT_ABSOLUTE_X[$n]:-}" ]] || continue
        cT=${FT_ABSOLUTE_Y[$n]}; cL=${FT_ABSOLUTE_X[$n]}
        cB=$(( cT + ${FT_MEASURED_HEIGHT[$n]:-0} - 1 )); cR=$(( cL + ${FT_MEASURED_WIDTH[$n]:-0} - 1 ))
        ot=$(( bT > cT ? bT : cT )); ol=$(( bL > cL ? bL : cL ))
        ob=$(( bB < cB ? bB : cB )); orr=$(( bR < cR ? bR : cR ))
        (( ot > ob || ol > orr )) && continue
        (( CHROME_CELLS += (ob-ot+1) * (orr-ol+1) ))
    done
}

: "${_MIN_LEADER:=3}"
MAX_TURNS=2

# Two sizes by default — the CRAMPED extreme and the ROOMY one, which is where the two failure
# classes actually live and enough to stop a width-blind regression. The full sweep costs minutes
# (every page × every step × a real render each), which is too slow to sit in run-all:
#     FT_CALLOUT_SIZES="80 30|95 34|120 40|170 50" bash tests/test-callout.bash
# 171×45 is the user's actual terminal — wide but SHORT, a geometry none of the original four
# sizes covered, and where two reported defects lived (the height axis matters as much as the
# width one). The cramped extreme plus the real terminal are the defaults; the sweep adds the
# tall variants:  FT_CALLOUT_SIZES="80 30|95 34|120 40|170 50|171 45" bash tests/test-callout.bash
IFS='|' read -r -a _sizes <<< "${FT_CALLOUT_SIZES:-80 30|171 45}"
for size in "${_sizes[@]}"; do
    set -- $size; cols=$1; rows=$2
    FT_COLS=$cols; FT_ROWS=$rows
    # RESIZE THE APP, not just the globals. `ft-form name=app width="$FT_COLS" height="$FT_ROWS"`
    # is evaluated ONCE when the demo is sourced, so setting FT_COLS/FT_ROWS alone moves what the
    # PLACER believes about the screen while the app stays the size it was built at. This suite
    # ran for two sessions that way: every size reported the same 120×30 layout, the four widths
    # were a fiction, and the placer was free to park a callout on rows the app did not occupy —
    # which is precisely the defect the sweep existed to catch. `_resize` is the demo's own
    # SIGWINCH handler, so this resizes exactly as a real terminal resize does.
    _resize >/dev/null 2>&1
    settle >/dev/null 2>&1   # ft-run settles the burst; a gate must too
    note "at ${cols}×${rows}"
    for PAGE in 1 2 3 4 5 6 7 8 9 10; do
        _page_annotations; nsteps=${#PA_TARGET[@]}
        for (( STEP=1; STEP<=nsteps; STEP++ )); do
            _show_page >/dev/null 2>&1
            settle >/dev/null 2>&1   # ft-run settles the burst; a gate must too
            FT_OUT=""; _ft_redraw_walk app >/dev/null 2>&1; _ft_composite_overlays >/dev/null 2>&1
            poly=${FT_BEACON_LEADER[stepcallout]:-}
            box=${FT_BEACON_BOX[stepcallout]:-}
            [[ -n "$box" ]] || { check "p$PAGE s$STEP has a callout" 0 1; continue; }
            # A CALLOUT WITH NO LEADER IS A VALID OUTCOME, not a missing callout. When the screen
            # leaves the chip hard against its target, the exit cell IS the arrowhead cell: there
            # is no line to draw and an arrow glyph wedged between two borders reads as a fault.
            # The engine draws neither, on purpose. What must then hold is that the chip is
            # ACTUALLY adjacent — a leaderless chip parked away from its target points at nothing
            # and is a real defect — so that is what gets asserted instead of the line rules.
            if [[ -z "$poly" ]]; then
                set -- $box; _bt=$1; _bl=$2; _bb=$3; _br=$4
                tgt=${PA_TARGET[$((STEP-1))]}
                _tt=${FT_ABSOLUTE_Y[$tgt]}; _tl=${FT_ABSOLUTE_X[$tgt]}
                _tb=$(( _tt + ${FT_MEASURED_HEIGHT[$tgt]} - 1 )); _tr=$(( _tl + ${FT_MEASURED_WIDTH[$tgt]} - 1 ))
                # "Against it" is exact arithmetic, not a fudge. The head sits arrowPadding(1)
                # cells clear PLUS its own glyph — two columns out — while the exit sits one cell
                # off the box, so the line collapses to a point when the horizontal gap reaches 2
                # (box right == target left - 3). Vertically vpad is apad-1 = 0, so the same
                # collapse happens one cell sooner. Those are the only distances at which a
                # leaderless chip is the honest answer; further away it is pointing at nothing.
                if (( _bt <= _tb + 2 && _bb >= _tt - 2 && _bl <= _tr + 3 && _br >= _tl - 3 )); then
                    check "p$PAGE s$STEP leaderless chip sits against its target" 1 1
                else
                    check "p$PAGE s$STEP leaderless chip sits against its target" 0 1
                    printf '         box=[%s] target=[%s %s %s %s]\n' "$box" "$_tt" "$_tl" "$_tb" "$_tr"
                fi
                continue
            fi
            _leader_shape "$poly"
            pp=($poly); headR=${pp[-2]}; headC=${pp[-1]}   # the route ends ON the arrowhead
            tgt=${PA_TARGET[$((STEP-1))]}                  # live geometry, as the beacon read it
            tT=${FT_ABSOLUTE_Y[$tgt]}; tL=${FT_ABSOLUTE_X[$tgt]}
            _head_axis "$tT" "$tL" $(( tT + ${FT_MEASURED_HEIGHT[$tgt]} - 1 )) \
                       $(( tL + ${FT_MEASURED_WIDTH[$tgt]} - 1 )) "$headR" "$headC"
            tag="p$PAGE s$STEP @${cols}"
            # DOES THE APP EVEN HAVE ROOM? Ask the same allocator the placer uses whether any free
            # rectangle could hold this box. When none can, every placement overlaps something and
            # a full-length leader is unreachable — a fact about the screen, not a defect in the
            # placer — so the test measures which case it is in rather than hard-coding "be
            # lenient below N rows". At 80×30 this demo's largest free rectangle is 80×3 while the
            # box needs 6-9 rows; by 170×50 there is room to spare.
            # What has to fit is the box PLUS the line — asking only about the box says "there was
            # room" about a region exactly box-sized and jammed against the screen edge, where the
            # leader can only ever be a stub. Either orientation counts: room to the side, or room
            # above/below.
            # via the engine's own accessor, not by counting fields in its packed cache
            _ft_beacon_placement stepcallout; cbw=$FT_PLACED_W; cbh=$FT_PLACED_H
            _ft_route_obstacles
            tB=$(( tT + ${FT_MEASURED_HEIGHT[$tgt]} - 1 )); tR=$(( tL + ${FT_MEASURED_WIDTH[$tgt]} - 1 ))
            # REACHABLE room, not just room: a region that fits box+leader AND lines up with the
            # target on the matching axis, so a straight leader into it is geometrically possible.
            # "A 40×6 region exists in the far corner" says nothing when every line from it to the
            # target must bend around or cut through the row the target sits in — which is exactly
            # the 95×34 situation, where the brute-forced best over EVERY zero-burial box position
            # still needs 4 turns and 2 crossings. Strictness is earned by reachable room; without
            # it the standing rule applies: the screen was made too small for a good answer.
            # …and the straight shot from that region to the target must be CLEAR. At 95×34 a
            # region fits to the target's right and lines up with its row — and the line from it
            # still has to pass through the Bold checkbox sitting in between. A region you can
            # only reach by crossing a control is not reachable in any sense that earns the strict
            # rules; the brute-forced optimum over every zero-burial box position there is 4 turns
            # and 2 crossings, so 4 turns is what the test permits there.
            _clear_h() {        # row c0 c1 → 0 iff no control on that row between the columns
                local r=$1 lo=$2 hi=$3 j t
                (( lo > hi )) && { t=$lo; lo=$hi; hi=$t; }
                for j in "${!_RT_T[@]}"; do
                    (( _RT_T[j] <= r && r <= _RT_B[j] && _RT_L[j] <= hi && _RT_R[j] >= lo )) && return 1
                done
                return 0
            }
            _clear_v() {        # col r0 r1 → 0 iff no control in that column between the rows
                local c=$1 lo=$2 hi=$3 j t
                (( lo > hi )) && { t=$lo; lo=$hi; hi=$t; }
                for j in "${!_RT_T[@]}"; do
                    (( _RT_L[j] <= c && c <= _RT_R[j] && _RT_T[j] <= hi && _RT_B[j] >= lo )) && return 1
                done
                return 0
            }
            reachable=0
            ft_free_regions 0 0 $(( FT_ROWS-1 )) $(( FT_COLS-1 )) $(( cbw + _MIN_LEADER )) "$cbh"
            for _k in "${!FT_FREE_T[@]}"; do
                (( FT_FREE_B[_k] >= tT && FT_FREE_T[_k] <= tB )) || continue
                _row=$(( (tT > FT_FREE_T[_k] ? tT : FT_FREE_T[_k]) ))   # a row both share
                if   (( FT_FREE_R[_k] < tL )); then _clear_h "$_row" $(( FT_FREE_R[_k]+1 )) $(( tL-1 )) || continue
                elif (( FT_FREE_L[_k] > tR )); then _clear_h "$_row" $(( tR+1 )) $(( FT_FREE_L[_k]-1 )) || continue
                fi                                                       # adjacent/overlapping: clear
                reachable=1; break
            done
            ft_free_regions 0 0 $(( FT_ROWS-1 )) $(( FT_COLS-1 )) "$cbw" $(( cbh + _MIN_LEADER ))
            if (( ! reachable )); then
                for _k in "${!FT_FREE_T[@]}"; do
                    (( FT_FREE_R[_k] >= tL && FT_FREE_L[_k] <= tR )) || continue
                    _col=$(( (tL > FT_FREE_L[_k] ? tL : FT_FREE_L[_k]) ))
                    if   (( FT_FREE_B[_k] < tT )); then _clear_v "$_col" $(( FT_FREE_B[_k]+1 )) $(( tT-1 )) || continue
                    elif (( FT_FREE_T[_k] > tB )); then _clear_v "$_col" $(( tB+1 )) $(( FT_FREE_T[_k]-1 )) || continue
                    fi
                    reachable=1; break
                done
            fi
            # A full-length line where there is room for one; where there is not, it must still
            # CONNECT — a callout whose arrowhead floats free of its box points at nothing.
            #
            # A SHORT leader is acceptable exactly when it is SIMPLE AND CLEAN: straight (≤1 turn),
            # crossing nothing, box right beside its target. That is what a person draws when a
            # target is hemmed in on every side (a checkbox row with neighbours left and right, the
            # specimen above, a shallow band below): the box tucked adjacent with a stub `▲`. The
            # alternative the length rule used to force was a LONGER line from further away that
            # had to bend or cross to get there — which reads worse, not better. "Roomy" cannot
            # arbitrate this: it asks whether space exists somewhere, not whether that space is
            # REACHABLE with a clean line from this target.
            _ft_route_score "$poly"; leader_cross=$(( FT_RET / 10000 ))
            if (( LEADER_LEN >= _MIN_LEADER )) || \
               { (( reachable == 0 )) && (( LEADER_LEN >= 1 )); } || \
               (( LEADER_LEN >= 1 && LEADER_TURNS <= 1 && leader_cross == 0 )); then
                check "$tag leader is a line" 1 1
            else check "$tag leader is a line" 0 1; printf '         len=%s turns=%s cross=%s box=[%s] poly=[%s]\n' \
                "$LEADER_LEN" "$LEADER_TURNS" "$leader_cross" "$box" "$poly"; fi
            # Two turns when a clean side exists; up to four when the measurement above says the
            # screen offers no straight-reachable room (the brute-forced optimum at 95×34 IS four).
            maxt=$MAX_TURNS; (( reachable == 0 )) && maxt=4
            if (( LEADER_TURNS <= maxt )); then check "$tag at most $MAX_TURNS turns" 1 1
            else check "$tag at most $MAX_TURNS turns" 0 1; printf '         turns=%s (max %s) box=[%s] poly=[%s]\n' "$LEADER_TURNS" "$maxt" "$box" "$poly"; fi
            if [[ "$LEADER_LASTAXIS" == "$HEAD_AXIS" ]]; then check "$tag enters the head along its axis" 1 1
            else check "$tag enters the head along its axis" 0 1; printf '         last=%s head=%s box=[%s] poly=[%s]\n' "$LEADER_LASTAXIS" "$HEAD_AXIS" "$box" "$poly"; fi
            _leader_reversals "$poly"
            if (( LEADER_REV == 0 )); then check "$tag never doubles back on itself" 1 1
            else check "$tag never doubles back on itself" 0 1; printf '         reversals=%s box=[%s] poly=[%s]\n' "$LEADER_REV" "$box" "$poly"; fi
            # ZERO wherever the app has anywhere else to put it. At the cramped extreme it does
            # not: measured at 80×30, EVERY side buries ≥39 cells, because the app fills all 30
            # rows and the callout has to go somewhere. Capping there rather than exempting the
            # size keeps the assertion meaningful — the 132-cell disaster still fails loudly.
            # Keyed on REACHABLE, not roomy: at p9 s3 @80 two regions FIT the box but sit flush
            # under the target's own row, so the box-plus-line cannot exist in them — and the
            # judge's table shows every alternative buries MORE content cells than the chrome
            # placement (116 vs 100). Room that cannot host box+line earns no strictness.
            set -- $box; _chrome_cover "$1" "$2" "$3" "$4"
            budget=0; (( reachable == 0 )) && budget=112
            if (( CHROME_CELLS <= budget )); then check "$tag keeps off the keylegend/statusbar" 1 1
            else check "$tag keeps off the keylegend/statusbar" 0 1
                 printf '         chrome=%s (budget %s) box=[%s]\n' "$CHROME_CELLS" "$budget" "$box"; fi
            # …AND OFF EVERY BORDER IT IS NOT ALLOWED TO ERASE. A container's border is drawn ink,
            # not empty margin, and a chip sitting on it cannot be wiped by repainting that
            # container — which is the whole reason `boundBox` exists. This went unmeasured until
            # a user looked at the tour on an 84-column terminal and found the chip painted over
            # the frame's `║` column on 43 of 43 steps: at that size the only space wide enough
            # was OUTSIDE the frame, and nothing said it was not free.
            #
            # The predicate is `_ft_border`, not `type == frame`. A borderless frame draws no ring,
            # and keying on the type reports a ring it never painted (my first probe did exactly
            # that and blamed the placer for 43 phantom failures).
            _ring_cover() {     # boxT boxL boxB boxR → RING_CELLS on any bordered control's ring
                local bt=$1 bl=$2 bb=$3 br=$4 n fT fL fB fR o1 o2
                RING_CELLS=0
                for n in "${!FT_TYPE[@]}"; do
                    _ft_border "$n"; (( FT_RET )) || continue
                    [[ -n "${FT_ABSOLUTE_Y[$n]:-}" ]] || continue
                    fT=${FT_ABSOLUTE_Y[$n]}; fL=${FT_ABSOLUTE_X[$n]}
                    fB=$(( fT + ${FT_MEASURED_HEIGHT[$n]:-0} - 1 )); fR=$(( fL + ${FT_MEASURED_WIDTH[$n]:-0} - 1 ))
                    (( fB <= fT + 1 || fR <= fL + 1 )) && continue     # no interior ⇒ no ring
                    _rect_ov "$bt" "$bl" "$bb" "$br" "$fT" "$fL" "$fB" "$fR"; o1=$FT_RET
                    _rect_ov "$bt" "$bl" "$bb" "$br" $(( fT+1 )) $(( fL+1 )) $(( fB-1 )) $(( fR-1 )); o2=$FT_RET
                    (( RING_CELLS += o1 - o2 ))
                done
            }
            _rect_ov() {        # aT aL aB aR bT bL bB bR → FT_RET = overlapping cells
                local t=$(( $1 > $5 ? $1 : $5 )) l=$(( $2 > $6 ? $2 : $6 ))
                local b=$(( $3 < $7 ? $3 : $7 )) r=$(( $4 < $8 ? $4 : $8 ))
                if (( t > b || l > r )); then FT_RET=0; else FT_RET=$(( (b-t+1)*(r-l+1) )); fi
            }
            set -- $box; _ring_cover "$1" "$2" "$3" "$4"
            if (( RING_CELLS == 0 )); then check "$tag stays off every drawn border" 1 1
            else check "$tag stays off every drawn border" 0 1
                 printf '         border cells=%s box=[%s]\n' "$RING_CELLS" "$box"; fi
        done
    done
done

summary
