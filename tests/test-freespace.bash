#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  ft_free_regions — the screen's unclaimed rectangles, the way an allocator reports free blocks.
#
#  A floating box (a callout) needs to know WHERE THERE IS ROOM before it can choose a place to
#  land. These tests pin the two properties that makes it usable:
#
#    SOUND     every reported rectangle really is empty — no reported cell touches an obstacle.
#              A region that lies about being free is worse than no region at all, because the
#              caller will land a box on content and never re-check.
#    COMPLETE  every empty cell is inside at least one reported rectangle, and a box that fits
#              anywhere is reported as fitting. A missed region silently degrades the caller to
#              its fallback, which is exactly the bug that is invisible from the outside.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null

# Drive ft_free_regions off a hand-built obstacle list rather than a live tree, so the geometry
# under test is stated in the test and not a property of some demo page.
_set_obstacles() {              # "T L B R" …
    _ft_obstacles_clear
    local r
    for r in "$@"; do set -- $r; _ft_obstacle_push "$1" "$2" "$3" "$4" "${FT_IMPORTANCE_NORMAL:-60}" ""; done
}
_occupied() {                   # r c → 0 iff some obstacle covers that cell
    local r=$1 c=$2 j
    for j in "${!_RT_T[@]}"; do
        (( _RT_T[j] <= r && r <= _RT_B[j] && _RT_L[j] <= c && c <= _RT_R[j] )) && return 0
    done
    return 1
}

# SOUND: no reported region contains an occupied cell.
_check_sound() {                # T L B R (the bounds that were asked for)
    local bt=$1 bl=$2 bb=$3 br=$4 k r c bad=0
    for k in "${!FT_FREE_T[@]}"; do
        for (( r=FT_FREE_T[k]; r<=FT_FREE_B[k]; r++ )); do
            for (( c=FT_FREE_L[k]; c<=FT_FREE_R[k]; c++ )); do
                _occupied "$r" "$c" && { bad=1; break 3; }
                (( r < bt || r > bb || c < bl || c > br )) && { bad=1; break 3; }
            done
        done
    done
    SOUND=$bad
}
# COMPLETE: every free cell in the bounds is inside some reported region.
_check_complete() {             # T L B R
    local bt=$1 bl=$2 bb=$3 br=$4 r c k miss=0 found
    for (( r=bt; r<=bb; r++ )); do
        for (( c=bl; c<=br; c++ )); do
            _occupied "$r" "$c" && continue
            found=0
            for k in "${!FT_FREE_T[@]}"; do
                (( FT_FREE_T[k] <= r && r <= FT_FREE_B[k] && FT_FREE_L[k] <= c && c <= FT_FREE_R[k] )) \
                    && { found=1; break; }
            done
            (( found )) || { miss=1; break 2; }
        done
    done
    COMPLETE=$miss
}
# Does any reported region hold a w×h box?
_fits() {                       # w h → 0 iff some region can hold it
    local w=$1 h=$2 k
    for k in "${!FT_FREE_T[@]}"; do
        (( FT_FREE_R[k] - FT_FREE_L[k] + 1 >= w && FT_FREE_B[k] - FT_FREE_T[k] + 1 >= h )) && return 0
    done
    return 1
}

note "an empty screen is one region — the whole thing"
_set_obstacles
ft_free_regions 0 0 9 19
check "one region"        "${#FT_FREE_T[@]}" "1"
check "covers everything" "${FT_FREE_T[0]} ${FT_FREE_L[0]} ${FT_FREE_B[0]} ${FT_FREE_R[0]}" "0 0 9 19"

note "a single obstacle in the middle splits the space four ways (above/below/left/right)"
_set_obstacles "4 8 5 11"
ft_free_regions 0 0 9 19
_check_sound 0 0 9 19;    check "every region is really empty"   "$SOUND"    "0"
_check_complete 0 0 9 19; check "every empty cell is covered"    "$COMPLETE" "0"
ok "the full-width band above it is reported" _fits 20 4
ok "the full-height column left of it is reported" _fits 8 10

note "SOUNDNESS holds with obstacles that overlap and touch"
_set_obstacles "0 0 2 5" "1 4 3 9" "6 12 9 19" "5 0 5 19"
ft_free_regions 0 0 9 19
_check_sound 0 0 9 19;    check "no region overlaps an obstacle" "$SOUND"    "0"
_check_complete 0 0 9 19; check "no empty cell is missed"        "$COMPLETE" "0"

note "a fully covered area reports nothing at all"
_set_obstacles "0 0 9 19"
ft_free_regions 0 0 9 19
check "no regions" "${#FT_FREE_T[@]}" "0"

note "regions are clipped to the BOUNDS, never to the screen"
_set_obstacles "5 5 6 6"
ft_free_regions 2 2 7 7
_check_sound 2 2 7 7;     check "stays inside the asked-for box" "$SOUND" "0"
_check_complete 2 2 7 7;  check "and still covers all of it"     "$COMPLETE" "0"

note "the fit question a callout actually asks"
# A 30x4 box cannot fit between two panes 20 columns apart, but does fit in the band below them.
_set_obstacles "0 0 5 24" "0 30 5 59"
ft_free_regions 0 0 11 59
ok  "a 30x4 box fits (the band below the panes)"      _fits 30 4
ok  "a 5x6 box fits (the gap between the panes)"      _fits 5 6
if _fits 30 12; then check "a box taller than the space does NOT fit" 0 1
else                 check "a box taller than the space does NOT fit" 1 1; fi

note "cost: the regions for a realistic screen are computed once per placement"
_set_obstacles "2 15 4 102" "6 14 6 20" "7 14 14 57" "7 61 14 104" "16 35 19 82" \
               "21 33 21 41" "21 44 21 56" "21 59 21 70" "21 73 21 85" "25 48 25 50" \
               "25 53 25 65" "25 68 25 70" "26 0 28 119" "27 48 27 53" "27 56 27 61" \
               "27 64 27 69" "29 0 29 119" "0 0 0 119" "1 12 1 106"
# ft_now_ms RETURNS VIA FT_RET — it does not echo. `t0=$(ft_now_ms)` captured an empty string,
# so this note printed "0ms" no matter how slow the allocator got: an instrument that cannot
# move is worse than none, because it reads as a passing measurement.
ft_now_ms; t0=$FT_RET
ft_free_regions 0 0 39 119
ft_now_ms; t1=$FT_RET
_check_sound 0 0 39 119; check "sound on a real page layout" "$SOUND" "0"
ok "it reported some usable space" test "${#FT_FREE_T[@]}" -gt 0
note "  ($((t1-t0))ms for ${#FT_FREE_T[@]} regions over ${#_RT_T[@]} obstacles)"

summary
