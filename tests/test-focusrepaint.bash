#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  A FOCUS MOVE REPAINTS — and the only honest place to check is the TTY.
#
#  This exists because the dirty path was reported broken: a focus move marked both controls
#  dirty, coalescing was off, the controls had geometry, and `settle` was measured emitting
#  ZERO bytes. It emits plenty. The measurement was:
#
#      settle; got=$FT_OUT            # always empty, whatever happened
#
#  ft_redraw_dirty ends in ft_flush, and ft_flush writes FT_OUT to FT_TTY and then sets
#  FT_OUT="". So reading FT_OUT after a settle reports zero whether the engine painted the
#  whole screen or nothing at all. Point the descriptor at a file and the bytes are there.
#
#  The same trap has now caught two people on this codebase (it produced a "bytes painted by
#  the hide = 0" reading during the transition work), so it is pinned rather than remembered:
#  these assertions read a captured stream, and one of them deliberately shows FT_OUT being
#  empty at the same moment, so the next person sees both numbers side by side.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
cd "$here"
export FT_NO_WTFIX=1
source "$here/fruity-tui.bash"
ft_init
FT_COLOR_MODE=256; FT_USE_UTF8=1
FT_COLS=50; FT_ROWS=12

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

ft-form name=app width="$FT_COLS" height="$FT_ROWS"
    ft-button name=one "One"
    ft-button name=two "Two"
end_ft_form
FT_ROOT=app
ft_layout app
exec {FT_TTY}>/dev/null

note "focus is visible on these controls in the first place"
ft_focus one; FT_OUT=""; _ft_redraw_walk app; with_one=$FT_OUT; FT_OUT=""
ft_focus two; FT_OUT=""; _ft_redraw_walk app; with_two=$FT_OUT; FT_OUT=""
check "a full render differs by where focus is" \
      "$([[ "$with_one" == "$with_two" ]] && echo same || echo different)" different

note "so the dirty path owes bytes, and pays them"
exec {FT_TTY}>"$work/drain"
ft_focus one; FT_OUT=""; _ft_redraw_walk app; ft_flush
ft_reflow_flush; ft_redraw_dirty
exec {FT_TTY}>&-; exec {FT_TTY}>"$work/move"
ft_focus two
check "the move marked the control being left dirty"  "${FT_DIRTY[one]:-}" 1
check "…and the control being landed on"              "${FT_DIRTY[two]:-}" 1
check "coalescing is off, so a settle really paints"  "$FT_COALESCING" 0
ft_reflow_flush; ft_redraw_dirty
exec {FT_TTY}>&-; exec {FT_TTY}>/dev/null
moved=$(wc -c < "$work/move")
note "  the focus move wrote $moved bytes to the tty — and FT_OUT is ${#FT_OUT} bytes, as always after a flush"
check "the focus move actually wrote to the terminal" "$(( moved > 0 ))" 1
check "…while FT_OUT reads empty at the same instant" "${#FT_OUT}" 0

note "and what it wrote is what a fresh render would have produced"
exec {FT_TTY}>"$work/a"
ft_focus one; FT_OUT=""; _ft_redraw_walk app; ft_flush; ft_reflow_flush; ft_redraw_dirty
exec {FT_TTY}>&-; exec {FT_TTY}>"$work/b"
ft_focus two; ft_reflow_flush; ft_redraw_dirty
exec {FT_TTY}>&-; exec {FT_TTY}>"$work/fresh"
FT_OUT=""; _ft_redraw_walk app; ft_flush
exec {FT_TTY}>&-; exec {FT_TTY}>/dev/null
cat "$work/a" "$work/b" > "$work/ab"
python3 tools/screen-cells.py "$work/ab"    "$FT_ROWS" "$FT_COLS" > "$work/cells-ab"
python3 tools/screen-cells.py "$work/fresh" "$FT_ROWS" "$FT_COLS" > "$work/cells-fresh"
check "the incremental screen is not empty" "$(( $(grep -c . "$work/cells-fresh") > 0 ))" 1
if diff -q "$work/cells-ab" "$work/cells-fresh" >/dev/null; then
    check "incremental end state == a from-scratch render" 1 1
else
    check "incremental end state == a from-scratch render" 0 1
    diff "$work/cells-fresh" "$work/cells-ab" | head -6 | sed 's/^/       /'
fi

note "inside a burst it is a no-op — which is why an app's trailing call paints nothing"
exec {FT_TTY}>"$work/burst"
FT_COALESCING=1                    # exactly what ft-run sets while dispatching a handler
ft_focus one
ft_redraw_dirty
FT_COALESCING=0
exec {FT_TTY}>&-; exec {FT_TTY}>/dev/null
check "ft_redraw_dirty writes nothing while coalescing" "$(wc -c < "$work/burst")" 0
check "…and leaves the work pending for the loop's settle" "$(( ${#FT_DIRTY[@]} > 0 ))" 1

summary
