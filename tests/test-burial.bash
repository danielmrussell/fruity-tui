#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  What callout placements BURY, measured on the real screen.
#
#  The unit suites check state and the render gate checks pixels, but neither
#  says whether a placement landed on something that mattered. This walks every
#  page/step of the callout demo at one cramped size, renders each page in a
#  pty WITHOUT its callout (so the ink map is the bare interface), and counts
#  the cells the box-plus-leader actually covers, classified the way the user
#  ranked the sins: TEXT is the gravest, DECOR is explicitly welcome, BLANK is
#  free. tests/burial-count.py does the counting and documents the one blind
#  spot (a colour-filled strip reads as blank).
#
#  The numbers pinned here are the measured state of the engine — improvements
#  pass, regressions fail. When a pin trips after a deliberate placement
#  change, re-measure, decide whether the new number is a better engine or a
#  worse one, and re-pin with the ledger updated. History that earned them:
#  buried TEXT was 204; overhang candidates (_OVERHANG, swept to 1) took it to
#  190; the rescue sweep (_RESCUE_AT — the generator that can see cheap tier
#  space inside controls) took it to 73, with 36 of 43 placements burying
#  nothing and every remaining offender on the dense page 4.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
cd "$here"

COLS=62; ROWS=40
work=$(mktemp -d)
noloop=demo/.callout-demo-burial.$$.bash
bare=demo/.callout-demo-burial-bare.$$.bash
trap 'rm -rf "$work" "$noloop" "$bare"' EXIT

# The same demo twice: once with the run loop stripped so it can be driven in-process, and once
# with _place_callout neutered so the pty render shows the page and nothing of the overlay.
sed '/^ft_run app/d' demo/callout-demo.bash > "$noloop"
sed 's/^_place_callout() {/_place_callout() { return 0;/' demo/callout-demo.bash > "$bare"

export FT_NO_WTFIX=1
source "$noloop"
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_USE_UTF8=1; FT_ROOT=app
FT_COLS=$COLS; FT_ROWS=$ROWS

: > "$work/placements.txt"
for (( p=1; p<=LAST; p++ )); do
    FT_TEST_COLS=$COLS FT_TEST_ROWS=$ROWS DEMO_PAGE=$p DEMO_STEP=1 \
        python3 tests/render-screen.py "$bare" "" > "$work/bare-$p.txt" 2>/dev/null
    PAGE=$p; STEP=1; _resize >/dev/null 2>&1; _page_annotations
    settle >/dev/null 2>&1   # ft_run settles the burst; a gate must too
    for (( s=1; s<=${#PA_TARGET[@]}; s++ )); do
        STEP=$s; _goto_step >/dev/null 2>&1
        settle >/dev/null 2>&1   # ft_run settles the burst; a gate must too
        _ft_beacon_placement stepcallout || continue
        bT=$FT_PLACED_T; bL=$FT_PLACED_L; bB=$FT_PLACED_B; bR=$FT_PLACED_R
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$s" "$bT" "$bL" "$bB" "$bR" \
            "${FT_BEACON_LEADER[stepcallout]:-}" >> "$work/placements.txt"
    done
done

out=$(python3 tests/burial-count.py "$work" "$COLS" "$ROWS")
note "measured at ${COLS}x${ROWS}: $out"
N=0; TEXT=0; DECOR=0; BLANK=0; ANYTXT=0
for kv in $out; do printf -v "${kv%%=*}" '%s' "${kv#*=}"; done

# A collapsed placement count means the walk itself broke — every pin below would then "pass"
# vacuously on an empty corpus, which is how a gate goes toothless without failing.
check "the walk produced the full corpus of placements" \
    $(( N >= 40 ? 1 : 0 )) 1
check "the ink maps saw the pages (some text exists to bury)" \
    $(( TEXT + DECOR + BLANK > 5000 ? 1 : 0 )) 1

# The pins. Measured 2026-08-19: TEXT=73 ANYTXT=15 (of 43). Re-measured 2026-08-21: TEXT=93 —
# box 77 / leader 16. The +16 is the arrowhead STEM: the approach used to shrink to one cell to
# dodge whatever sat above the target, which put the last corner against the head and read as
# the line entering the arrow sideways; the user ruled that a full stem through label text beats
# any dogleg at the head, so those cells are now leader ink by contract, not a regression. Box
# burial itself moved 73→77. Ceilings, with a little slack for demo copy edits moving a wrap
# point — a real regression blows through these by tens, not ones.
check "buried TEXT stays at or below the pinned ceiling (105)" \
    $(( TEXT <= 105 ? 1 : 0 )) 1
check "placements burying ANY text stay at or below the ceiling (17)" \
    $(( ANYTXT <= 17 ? 1 : 0 )) 1
check "most placements bury no text at all" \
    $(( (N - ANYTXT) * 100 / N >= 60 ? 1 : 0 )) 1

summary
