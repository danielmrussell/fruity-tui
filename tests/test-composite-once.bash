#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  ONE SETTLE, ONE COMPOSITE — an overlay is painted once per frame, and only if
#  something under it moved.
#
#  `ft_redraw_dirty` already composites: it deliberately SKIPS overlays in its depth-ordered
#  draw loop and hands them to `_ft_composite_overlays_touching`, which repaints an overlay that
#  is dirty, that overlaps a control painted this pass, or that sits over a repaired damage
#  rect — and then flushes. Its own comment prices the alternative: a callout that painted in
#  the loop AND in the composite cost two full paints a settle, ~15-20ms of every drag frame.
#  `ft_anim_step` knows the rule too ("composites overlays itself").
#
#  Five call sites in controls/ft-beacon.bash did not, and each followed `ft_redraw_dirty` with a
#  blanket `_ft_composite_overlays; ft_flush` — a second, identical paint of EVERY live overlay
#  on the screen, including ones nothing had touched. That is CONTRIBUTING §1's recurring root
#  cause exactly: the same predicate on one route and not its siblings.
#
#  So this file counts `ft_draw_one` per control across every route that repairs and composites,
#  and requires the callout to be drawn ONCE — and a callout parked far away, which nothing in
#  the gesture touches, to be drawn NOT AT ALL.
#
#  WHY A COUNT AND NOT A PICTURE: painting twice is invisible on screen (the second paint lands
#  on top of the first, identically), so no residue gate can ever see it. It is a pure cost, and
#  a count is the only instrument that reads it. The picture is checked anyway, at the bottom,
#  because "drawn once" is worthless if the once was wrong — and because a count of 1 is what a
#  renderer that draws NOTHING also produces.
#
#  TEETH, watched 2026-09-05: putting `_ft_composite_overlays` back after `ft_redraw_dirty` in
#  _ft_beacon_mouse_release turns "the release composites the chip once" from 1 to 2 and the
#  bystander from 0 to 1. Stubbing out `_ft_composite_overlays_touching` (the compositor this
#  file asserts is sufficient) drops the driven screen from 536 non-blank cells to 372 and the
#  residue verdict at the bottom goes red.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_RECORD="" FT_NO_WTFIX=1
source "$here/fruity-tui.bash"
ft_init

work=$(mktemp -d)
exec {FT_TTY}>"$work/stream"
FT_COLOR_MODE=256; FT_USE_UTF8=1; FT_COLS=118; FT_ROWS=40

# tools/bench-drag.bash's scene — a callout over content it must repair — plus a SECOND callout
# parked well away from it. The bystander is the whole point: a blanket composite repaints every
# overlay on the screen, and only an overlay nothing touched can tell that apart from a correct
# one.
ft-form name=app width=118 height=40
    ft-frame name=page width=110 height=34 title=" Composite "
        ft-label name=tgt     text="TARGET"
        ft-label name=far     text="FAR"
        ft-label name=filler1 text="some other content on the page to repair over"
        ft-label name=filler2 text="and another line of it, so a repair is not free"
    end_ft_frame
end_ft_form
FT_ROOT=app
ft_layout app
ft-beacon name=chip variant=callout target=tgt number=1 \
          text="A callout being dragged across the page, which must repair what it uncovers."
ft-beacon name=bystander variant=callout target=far number=2 parkedTop=30 parkedLeft=70 \
          text="A second callout, parked well away from the drag."
ft_layout app
FT_OUT=""; _ft_redraw_walk app; _ft_composite_overlays; ft_flush

declare -A DRAWS=()
eval "$(declare -f ft_draw_one | sed '1s/^ft_draw_one/_ft_draw_one_counted/')"
ft_draw_one() { (( DRAWS[$1] = ${DRAWS[$1]:-0} + 1 )); _ft_draw_one_counted "$@"; }

_bytes=0
_begin() { DRAWS=(); _bytes=$(wc -c < "$work/stream"); }
_drew()  { printf '%s' "${DRAWS[$1]:-0}"; }
# The companion to every count: an operation that emitted no bytes drew nothing, and "drawn
# once" would be true of it for the wrong reason.
_painted() { (( $(wc -c < "$work/stream") > _bytes )) && printf 1 || printf 0; }

_grab_and_move() {              # leaves the chip grabbed, one move made and settled
    local gr gc
    set -- ${FT_BEACON_BOX[chip]}; gr=$1; gc=$2
    _ft_beacon_grab_at "$gc" "$gr" || return 1
    FT_COALESCING=1; _ft_beacon_mouse_drag $(( gc + 2 )) $(( gr + 1 ))
    FT_COALESCING=0; ft_reflow_flush; ft_redraw_dirty
    return 0
}

# ═══ 1. a drag frame the handler paints for itself ═══════════════════════════
note "a drag frame composites the chip once"
ok "the callout can be grabbed and moved" _grab_and_move
set -- ${FT_BEACON_BOX[chip]}; _r=$1; _c=$2
_begin
FT_COALESCING=0
_ft_beacon_mouse_drag $(( _c + 4 )) $(( _r + 2 ))
check "the frame painted something"                "$(_painted)"          1
check "…and composited the chip exactly once"      "$(_drew chip)"        1
check "…and never touched the far-away callout"    "$(_drew bystander)"   0

# ═══ 2. the release, painting for itself ═════════════════════════════════════
# This is how tools/bench-drag.bash and tests/test-state.bash call it, and how any app that
# releases outside an input burst gets it.
note "a release composites the chip once (the handler's own paint)"
_begin
FT_COALESCING=0
_ft_beacon_mouse_release
check "the release painted something"              "$(_painted)"          1
check "…and composited the chip exactly once"      "$(_drew chip)"        1
check "…and never touched the far-away callout"    "$(_drew bystander)"   0
FT_DAMAGE_NARROW=0

# ═══ 3. the release the run loop actually performs ═══════════════════════════
# ft_run wraps every dispatch in FT_COALESCING=1, so the handler records and the burst's settle
# paints once. This path was already right; it is here as the control, and to pin it.
note "…and the same release inside an input burst, settled by the loop"
ok "the callout can be grabbed and moved again" _grab_and_move
_begin
FT_COALESCING=1; _ft_beacon_mouse_release
FT_COALESCING=0; ft_reflow_flush; ft_redraw_dirty
check "the settle painted something"               "$(_painted)"          1
check "…and composited the chip exactly once"      "$(_drew chip)"        1
check "…and never touched the far-away callout"    "$(_drew bystander)"   0
FT_DAMAGE_NARROW=0; FT_BEACON_NARROW_OFF_AFTER=0

# ═══ 4. closing a callout ════════════════════════════════════════════════════
# The close removes an overlay and repairs the ground under it, which repaints the frame the
# bystander sits on — so ONE recomposite of the bystander is correct here. Two is the blanket.
note "closing a callout recomposites a bystander once, not twice"
set -- ${FT_BEACON_CLOSE[chip]:-}; _cr=${1:-}; _cc=${2:-}
check "the chip has a close box to click"          "${_cr:+yes}"          yes
_begin
FT_COALESCING=0
ok "the ⊠ claimed the click" _ft_beacon_close_at "$_cc" "$_cr"
check "the close painted something"                "$(_painted)"          1
check "the chip is gone"                           "${FT_TYPE[chip]:-gone}" gone
check "…and the bystander repainted exactly once"  "$(_drew bystander)"   1

# ═══ 5. one bigarrow animation frame ═════════════════════════════════════════
# Same three-statement tail, on the path that runs it most often: an animation frame is not a
# gesture, it is sixty of them. It comes AFTER the close on purpose — an arrow will not fly into
# a corridor a parked callout is sitting in (`_ft_bigarrow_geometry` refuses, and the frame then
# returns without painting, which would make every assertion below vacuously true).
note "an animation frame composites the arrow once"
ft-beacon name=arrow variant=bigarrow target=tgt lifetime=persist
ft_layout app
FT_OUT=""; _ft_redraw_walk app; _ft_composite_overlays; ft_flush
_begin
FT_COALESCING=0
_ft_bigarrow_frame arrow
check "the animation frame painted something"      "$(_painted)"          1
check "…and composited the arrow exactly once"     "$(_drew arrow)"       1
check "…and never touched the far-away callout"    "$(_drew bystander)"   0

# ═══ 6. and the picture is still right ═══════════════════════════════════════
# Every count above is satisfied by a renderer that draws nothing, so the byte history of this
# whole file is replayed into a cell grid (glyph + fg + bg) and compared with a from-scratch
# render of the same end state — tests/test-residue.bash's instrument, with its ink guard.
note "the screen those settles produced is the screen a fresh render produces"
exec {FT_TTY}>&-; exec {FT_TTY}>/dev/null
FT_OUT=""; _ft_redraw_walk app; _ft_composite_overlays
printf '%s' "$FT_OUT" > "$work/fresh"
_driven=$(python3 "$here/tools/screen-cells.py" "$work/stream" "$FT_ROWS" "$FT_COLS")
_freshg=$(python3 "$here/tools/screen-cells.py" "$work/fresh"  "$FT_ROWS" "$FT_COLS")
_ink=$(printf '%s' "$_freshg" | grep -c .)
check "the scene put real ink on the screen (>=200 cells)" "$(( _ink >= 200 ))" 1
if [[ "$_driven" == "$_freshg" ]]; then
    check "the driven screen equals a fresh render" 1 1
else
    check "the driven screen equals a fresh render" 0 1
    diff <(printf '%s\n' "$_driven") <(printf '%s\n' "$_freshg") | head -6 | sed 's/^/         /'
fi

rm -rf "$work"
summary
