#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Growing content must never eat the chrome.
#
#  The contract this pins down — a log/output pane that fills up while the app runs:
#
#    · content grows to fit, and its container grows with it,
#    · until it would reach the bottom chrome, at which point it stops growing and
#      SCROLLS instead,
#    · and the key legend and status bar, docked full width across the bottom edge,
#      are never overlapped, at any content size.
#
#  The docking is ordinary flexbox, not a special mode: a column form whose chrome has
#  flexShrink=0 and whose content pane has flexGrow=1 + minHeight=0. That minHeight is
#  the load-bearing part — exactly as in CSS, a flex item's automatic minimum size would
#  otherwise refuse to shrink below its content and push the chrome off-screen.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_ROWS=24; FT_COLS=60

build_shell() {                 # rows_of_log — the app shell, rebuilt at each size
    local log_rows=$1
    # Release the previous tree first. Re-declaring a control does NOT reset its child list
    # (ft_new only initialises FT_KIDS when unset), so rebuilding in place would append a
    # second copy of every child and silently stack the shell down the screen.
    ft_remove app 2>/dev/null
    ft-form name=app width="$FT_COLS" height="$FT_ROWS" display=flex flexDirection=column
        ft-div name=viewport flexGrow=1 flexShrink=1 minHeight=0 overflow=auto \
                 display=flex flexDirection=column
            ft-textfield name=log readOnly=true wrap=true size=50 rows="$log_rows"
        end_ft_div
        ft-keylegend name=legend flexShrink=0 keys=auto
        ft-statusbar name=statusline flexShrink=0 status="growing…"
    end_ft_form
    ft_layout app
    FT_ROOT=app
}

bottom_of()  { echo $(( ${FT_ABSOLUTE_Y[$1]:-0} + ${FT_MEASURED_HEIGHT[$1]:-0} - 1 )); }
chrome_top() { local legend=${FT_ABSOLUTE_Y[legend]:-0} status=${FT_ABSOLUTE_Y[statusline]:-0}
               (( legend < status )) && echo "$legend" || echo "$status"; }

note "the chrome docks across the bottom edge, full width"
build_shell 3
check "the legend spans the full width"      "${FT_MEASURED_WIDTH[legend]}"     "$FT_COLS"
check "the status bar spans the full width"  "${FT_MEASURED_WIDTH[statusline]}" "$FT_COLS"
check "the status bar is on the last row"    "$(bottom_of statusline)" "$(( FT_ROWS - 1 ))"
check "the legend sits directly above it"    "$(bottom_of legend)" "$(( ${FT_ABSOLUTE_Y[statusline]} - 1 ))"

note "as content grows, the viewport grows with it — and never past the chrome"
overlaps=0; grew=0; chrome_pushed_offscreen=0; worst_case=""
previous_height=0
for content_rows in 1 2 4 8 12 16 24 40 80; do
    build_shell "$content_rows"
    viewport_bottom=$(bottom_of viewport)
    (( viewport_bottom >= $(chrome_top) )) && overlaps=$(( overlaps + 1 ))
    # The chrome must stay ON SCREEN. Comparing content against the chrome's own position
    # is not enough: if growing content shoves the chrome off the bottom, the two never
    # "overlap" and the check passes while the bars have silently vanished.
    if (( $(bottom_of statusline) > FT_ROWS - 1 )); then
        chrome_pushed_offscreen=$(( chrome_pushed_offscreen + 1 ))
        [[ -z "$worst_case" ]] && worst_case="$content_rows rows → status bar at row ${FT_ABSOLUTE_Y[statusline]} of $FT_ROWS"
    fi
    (( ${FT_MEASURED_HEIGHT[viewport]} > previous_height )) && grew=1
    previous_height=${FT_MEASURED_HEIGHT[viewport]}
done
check "the viewport did grow as content arrived" "$grew" "1"
check "it never overlapped the chrome, at any size" "$overlaps" "0"
[[ -n "$worst_case" ]] && note "  first failure: $worst_case"
check "the chrome stayed on screen at every size" "$chrome_pushed_offscreen" "0"

# This file found TWO separate bugs, and is kept pointed at both:
#
#  · the engine capped a scrolling container's children at the viewport height, truncating the
#    content so there was nothing left to scroll to (_ft_pass_height now passes an unconstrained
#    height to the children of a container that scrolls);
#  · and `local log_rows` in build_shell above WAS control `log`'s `rows` property — the engine
#    stored properties in unprefixed <control>_<property> globals, and bash's dynamic scoping
#    made the two the same variable, so ft_remove's unset silently emptied the caller's local
#    and every rebuild after the first built a 3-row field. Properties now live under _ftp_*.
#
# The local is deliberately still named `log_rows`: it is exactly what an app author would
# write, so leaving it here keeps that collision from coming back unnoticed.
note "once it cannot grow further it SCROLLS instead of overflowing"
build_shell 80
available_rows=$(( FT_ROWS - ${FT_MEASURED_HEIGHT[legend]} - ${FT_MEASURED_HEIGHT[statusline]} ))
check "the viewport is capped at the space left by the chrome" \
      "$([[ ${FT_MEASURED_HEIGHT[viewport]} -le $available_rows ]] && echo capped)" "capped"
ft_get viewport scrollHeight; content_height=${FT_RET:-0}
ft_get viewport clientHeight; visible_height=${FT_RET:-0}
check "the viewport reports more content than it can show" \
      "$([[ $content_height -gt $visible_height ]] && echo scrolling)" "scrolling"
check "…so a scrollbar gutter is reserved" \
      "$([[ $(( ${FT_ABSOLUTE_X[log]} + ${FT_MEASURED_WIDTH[log]} )) -le $(( ${FT_ABSOLUTE_X[viewport]} + ${FT_MEASURED_WIDTH[viewport]} )) ]] && echo inside)" "inside"

note "scrolling to the bottom still leaves the chrome untouched"
ft_scroll_set viewport 9999
ft_get viewport scrollTop; scrolled_to=${FT_RET:-0}
check "it scrolled to the end"                 "$([[ $scrolled_to -gt 0 ]] && echo yes)" "yes"
check "the chrome is still where it was"       "$(bottom_of statusline)" "$(( FT_ROWS - 1 ))"
check "the viewport still clears the chrome"   "$([[ $(bottom_of viewport) -lt $(chrome_top) ]] && echo clear)" "clear"

note "the painted screen agrees: nothing is drawn over the chrome rows"
FT_OUT=""; _ft_redraw_walk app
painted_over_chrome=0
for control in log viewport; do
    control_bottom=$(bottom_of "$control")
    (( control_bottom >= $(chrome_top) )) && painted_over_chrome=1
done
check "no content control extends into the chrome" "$painted_over_chrome" "0"

note "growth stays affordable — a relayout per arriving chunk"
ft_now_ms; started=$FT_RET
for content_rows in 10 20 30 40 50 60 70 80; do build_shell "$content_rows"; done
ft_now_ms; finished=$FT_RET
per_growth=$(( (finished - started) / 8 ))
note "  rebuild+relayout per growth step: ${per_growth}ms"
check "a growth step stays under 250ms" "$([[ $per_growth -lt 250 ]] && echo ok)" "ok"

summary
