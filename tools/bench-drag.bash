#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  What does ONE FRAME OF DRAGGING a callout cost?
#
#      bash tools/bench-drag.bash [frames]
#
#  WHY THIS EXISTS. A cascade correction shipped that made every property read consult one more
#  table, and it slowed a drag frame enough that dragging quickly stopped showing intermediate
#  frames. Nothing caught it: bench-layout and bench-modify both looked fine, because a drag is
#  not a layout and not a property write. The author felt it before any tool did.
#
#  IT MEASURES THE FRAME ft_run ACTUALLY PAINTS, and the distinction is not academic. The run loop
#  wraps every dispatch in FT_COALESCING=1 and settles the burst ONCE afterwards, and under
#  coalescing `_ft_beacon_mouse_drag` records its damage and returns WITHOUT painting — its own
#  comment says so, and says why (painting mid-burst was the reported smear). The first version of
#  this tool called that handler with coalescing OFF, so the handler painted a whole frame by
#  itself and the harness then painted another on top: three composites of the chip where the app
#  does one, and ~10ms a frame that no user ever waits for. Both drives are reported below, the
#  faithful one first, because the older number is what earlier measurements were taken with.
#
#  IT ALSO REPORTS THE RELEASE, on its own line, because a mouse-up is the frame this project
#  has already been bitten by once (the release's `ft_refresh` WAS the drag freeze) and it is not
#  a drag frame: it swaps the ghost ring for the full callout and re-routes the leader. It used
#  to sit outside the timed loop but INSIDE the draw counter, which is how "the release emits 248
#  pieces, five full callout paints" got written down — that was two releases summed and divided
#  by a paint measured at another park position. Counted properly it is ONE composite of the chip
#  per release, and the number is now printed rather than inferred.
#
#  GUARDS, because a benchmark that measures nothing reports a beautiful number:
#    · the chip must actually MOVE — otherwise this times the same-cell early return;
#    · each frame must actually PAINT bytes — otherwise it times a handler that gave up;
#    · the faithful drive must draw the chip about ONCE per frame — if that count ever climbs,
#      this tool has drifted away from the loop it is imitating, which is the exact fault it was
#      written to stop repeating;
#    · and the release must draw it EXACTLY once, which is the same rule for the same reason.
#  A run that fails a guard says so and exits nonzero instead of printing a time.
# ─────────────────────────────────────────────────────────────────────────────
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here" || exit 1
export FT_RECORD="" FT_NO_WTFIX=1
source fruity-tui.bash
ft_init
frames=${1:-20}

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
exec {FT_TTY}>"$work/stream"
FT_COLOR_MODE=256; FT_USE_UTF8=1; FT_COLS=118; FT_ROWS=40

# A page with something UNDER the chip: a drag's real cost is repairing what it uncovers, and a
# chip dragged across blank cells would flatter every candidate fix.
ft-form name=app width=118 height=40
    ft-frame name=page width=110 height=34 title=" Drag "
        ft-label name=tgt text="TARGET"
        ft-label name=filler1 text="some other content on the page to repair over"
        ft-label name=filler2 text="and another line of it, so a repair is not free"
    end_ft_frame
end_ft_form
FT_ROOT=app
ft_layout app >/dev/null 2>&1
ft-beacon name=chip variant=callout target=tgt number=1 \
          text="A callout being dragged across the page, which must repair what it uncovers."
ft_layout app >/dev/null 2>&1
FT_OUT=""; _ft_redraw_walk app >/dev/null 2>&1; _ft_composite_overlays; ft_flush
[[ -n "${FT_BEACON_BOX[chip]:-}" ]] || { echo "GUARD FAILED: the callout has no box to drag"; exit 1; }

DRAWS=0
eval "$(declare -f _ft_draw_beacon | sed '1s/^_ft_draw_beacon/_ft_draw_beacon_real/')"
_ft_draw_beacon() { (( DRAWS++ )); _ft_draw_beacon_real "$@"; }

run_drag() {                    # mode(loop|handler-paints) label → prints one line; 1 if a guard fails
    local mode=$1 label=$2 step row col before started finished frame_draws
    local times=() painted=0 moved=0 previous grab_row grab_col
    # `label` is captured BEFORE this, because `set --` below replaces the positional parameters
    # and $1 stops being the argument this function was called with.
    set -- ${FT_BEACON_BOX[chip]}          # grab it where it is NOW, not where it began
    grab_row=$1; grab_col=$2
    _ft_beacon_grab_at "$grab_col" "$grab_row" >/dev/null 2>&1 \
        || { echo "GUARD FAILED ($mode): could not grab the callout"; return 1; }
    previous=${FT_BEACON_BOX[chip]}
    DRAWS=0
    for (( step = 1; step <= frames; step++ )); do
        row=$(( grab_row + step )); col=$(( grab_col + step * 2 ))
        (( row > FT_ROWS - 8 ))  && row=$(( FT_ROWS - 8 ))
        (( col > FT_COLS - 30 )) && col=$(( FT_COLS - 30 ))
        before=$(wc -c < "$work/stream")
        started=${EPOCHREALTIME/./}
        if [[ "$mode" == loop ]]; then
            FT_COALESCING=1                        # …as ft_run wraps a dispatch
            _ft_beacon_mouse_drag "$col" "$row" >/dev/null 2>&1
            FT_COALESCING=0
            ft_reflow_flush >/dev/null 2>&1        # …and as it settles the burst: one paint
            ft_redraw_dirty >/dev/null 2>&1
        else
            FT_COALESCING=0                        # the older drive: the handler paints, then we do
            _ft_beacon_mouse_drag "$col" "$row" >/dev/null 2>&1
            ft_reflow_flush >/dev/null 2>&1
            ft_redraw_dirty >/dev/null 2>&1
            _ft_composite_overlays >/dev/null 2>&1
            ft_flush
        fi
        finished=${EPOCHREALTIME/./}
        times+=( $(( (finished - started) / 1000 )) )
        (( $(wc -c < "$work/stream") > before )) && (( painted++ ))
        [[ "${FT_BEACON_BOX[chip]:-}" != "$previous" ]] && (( moved++ ))
        previous=${FT_BEACON_BOX[chip]:-}
    done
    # THE RELEASE, timed on its own and counted on its own. Leaving it inside the frame counter
    # is what made the chip look like it painted more often than it does.
    frame_draws=$DRAWS
    DRAWS=0
    before=$(wc -c < "$work/stream")
    started=${EPOCHREALTIME/./}
    if [[ "$mode" == loop ]]; then
        FT_COALESCING=1                        # …as ft_run wraps the mouse-up
        _ft_beacon_mouse_release >/dev/null 2>&1
        FT_COALESCING=0
        ft_reflow_flush >/dev/null 2>&1        # …and as it settles the burst
        ft_redraw_dirty >/dev/null 2>&1
        (( FT_BEACON_NARROW_OFF_AFTER )) && { FT_DAMAGE_NARROW=0; FT_BEACON_NARROW_OFF_AFTER=0; }
    else
        _ft_beacon_mouse_release >/dev/null 2>&1
    fi
    finished=${EPOCHREALTIME/./}
    RELEASE_MS=$(( (finished - started) / 1000 ))
    RELEASE_DRAWS=$DRAWS
    RELEASE_PAINTED=0; (( $(wc -c < "$work/stream") > before )) && RELEASE_PAINTED=1
    DRAWS=$frame_draws
    if (( moved * 2 < frames || painted * 2 < frames )); then
        printf 'GUARD FAILED (%s): moved %s/%s, painted %s/%s — any timing here is meaningless\n' \
               "$mode" "$moved" "$frames" "$painted" "$frames"
        return 1
    fi
    if (( ! RELEASE_PAINTED )); then
        printf 'GUARD FAILED (%s): the release painted nothing — its timing is meaningless\n' "$mode"
        return 1
    fi
    local sorted median slowest fastest
    sorted=$(printf '%s\n' "${times[@]}" | sort -n)
    median=$(printf  '%s\n' "$sorted" | awk '{a[NR]=$1} END{print a[int(NR/2)+1]}')
    slowest=$(printf '%s\n' "$sorted" | tail -1)
    fastest=$(printf '%s\n' "$sorted" | head -1)
    printf '  %-28s median %sms   max %sms   min %sms   chip drawn %s times in %s frames\n' \
           "$label" "$median" "$slowest" "$fastest" "$DRAWS" "$frames"
    printf '  %-28s %sms            chip drawn %s time(s)\n' \
           "  …then the release" "$RELEASE_MS" "$RELEASE_DRAWS"
    LAST_DRAWS=$DRAWS
    if (( RELEASE_DRAWS != 1 )); then
        printf 'GUARD FAILED (%s): the release drew the chip %s times. A mouse-up is ONE more\n' \
               "$mode" "$RELEASE_DRAWS"
        printf '  drag frame — swap the ghost ring for the full callout and re-route the leader.\n'
        printf '  ft_redraw_dirty composites overlays itself; compositing again after it is a\n'
        printf '  second identical paint of every overlay on the screen.\n'
        return 1
    fi
    return 0
}

echo "drag frames: $frames   (118x40, a callout over content it must repair)"
LAST_DRAWS=0
run_drag loop "as ft_run paints it" || exit 1
loop_draws=$LAST_DRAWS
run_drag handler-paints "…handler painting too" || exit 1

# The count is the guard that keeps this tool honest about which frame it is imitating.
if (( loop_draws > frames * 2 )); then
    echo "GUARD FAILED: the faithful drive drew the chip $loop_draws times in $frames frames."
    echo "  ft_run composites an overlay once per settle; drawing it twice or more means this"
    echo "  harness has drifted from the loop and its headline number is not a real frame."
    exit 1
fi
