#!/usr/bin/env bash
# Dropdown geometry + scrolling: an open <select> opens BELOW by default, flips ABOVE when
# it's near the bottom, and — when the option list is taller than the space — becomes a
# SCROLLABLE window (with cursor-following scroll and page keys) rather than running off
# the screen. The "…" affordance is drawn by _ft_draw_select; here we exercise the model.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null

ft-form name=app width=40 height=6
    ft-select name=s size=1
        ft-option value=1 A; ft-option value=2 B; ft-option value=3 C; ft-option value=4 D
        ft-option value=5 E; ft-option value=6 F; ft-option value=7 G; ft-option value=8 H
        ft-option value=9 I; ft-option value=10 J; ft-option value=11 K; ft-option value=12 L
    end_ft_select
end_ft_form
FT_ROWS=14                       # a short screen: 12 options can't all fit

note "an open dropdown opens BELOW when there's room, ABOVE when it's near the bottom"
FT_ABSOLUTE_Y[s]=2;  _ft_select_geom s; check "high up → opens down" "$_SEL_DIR" "down"
                                   check "…starting on the next row" "$_SEL_TOP" "3"
FT_ABSOLUTE_Y[s]=12; _ft_select_geom s; check "near the bottom → opens up" "$_SEL_DIR" "up"

note "a list taller than the space becomes a scrollable window (vis = rows that FIT, not n)"
FT_ABSOLUTE_Y[s]=2;  _ft_select_geom s
check "visible rows are capped to the fit" "$_SEL_VIS" "11"   # 14-2-1 rows below
(( _SEL_VIS < 12 )) && check "…which is fewer than all 12 options" 1 1 || check "…which is fewer than all 12 options" 0 1

note "the cursor stays in view: scrolling follows it, clamped to the ends"
FT_ROWS=8; FT_ABSOLUTE_Y[s]=1; ft-modify s open=true    # below = 8-1-1 = 6 → opens DOWN, vis=6
_ft_select_cursor_to s 0
ft_resolved_prop s scroll 0; check "cursor at top → no scroll" "$FT_RET" "0"
_ft_select_cursor_to s 11                 # jump to the last option
ft_resolved_prop s scroll 0; check "cursor at end → scrolled to show the tail (12-6=6)" "$FT_RET" "6"
ft_resolved_prop s cursor 0; check "cursor is on the last option" "$FT_RET" "11"

note "Page Down / Page Up move by a visible window; Home / End jump to the ends"
_ft_select_cursor_to s 0
ft_select_key_pgdn s; ft_resolved_prop s cursor 0; check "PgDn advances by a page (6)" "$FT_RET" "6"
ft_select_key_pgup s; ft_resolved_prop s cursor 0; check "PgUp goes back a page" "$FT_RET" "0"
ft_select_key_end s;  ft_resolved_prop s cursor 0; check "End → last option" "$FT_RET" "11"
ft_select_key_home s; ft_resolved_prop s cursor 0; check "Home → first option" "$FT_RET" "0"

note "scrollbars are OPT-IN (default off) — the ⋯ affordance is the default"
# ft_get, not _ft_get_raw: a prototype default is resolved at cascade level 5 now rather than
# stamped onto the instance, so _ft_get_raw answers "what did the AUTHOR set" (nothing) and
# ft_get answers "what is this control's value" (the prototype's `false`), which is the question.
ft_get s scrollbar; check "scrollbar defaults to false" "$FT_RET" "false"

note "a CLOSED dropdown does not open on an arrow — it declines so focus can move"
ft-modify s open=false
FT_KEY_BUBBLE=0; ft_select_key_down s
check "Down on a closed dropdown does NOT open it" "$(ft_resolved_prop s open false; echo "$FT_RET")" "false"
check "…and it declines (bubbles to focus nav)"    "$FT_KEY_BUBBLE" "1"
FT_KEY_BUBBLE=0; ft_select_key_up s
check "Up on a closed dropdown also declines"      "$FT_KEY_BUBBLE" "1"

note "ENTER / SPACE is what opens a closed dropdown"
FT_KEY_BUBBLE=0; ft_select_key_commit s
check "Enter opens the closed dropdown" "$(ft_resolved_prop s open false; echo "$FT_RET")" "true"

note "in an OPEN dropdown, Up at the very top COLLAPSES it; a further Up then moves focus"
_ft_select_cursor_to s 0
FT_KEY_BUBBLE=0; ft_select_key_up s          # cursor already at top → close, keep focus
check "Up at the top closes the dropdown" "$(ft_resolved_prop s open false; echo "$FT_RET")" "false"
check "…and does NOT bubble (it consumed the key to close)" "$FT_KEY_BUBBLE" "0"
FT_KEY_BUBBLE=0; ft_select_key_up s          # now closed → declines so focus moves back
check "the next Up (now closed) bubbles to focus nav" "$FT_KEY_BUBBLE" "1"

note "Down inside an open dropdown still moves the cursor (does not collapse)"
ft-modify s open=true; _ft_select_cursor_to s 0
ft_select_key_down s; ft_resolved_prop s cursor 0; check "Down advances the cursor" "$FT_RET" "1"

summary
