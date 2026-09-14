#!/usr/bin/env bash
# Unit tests for controls/ft-scrollbar.bash: the DOM/CSSOM property names
# (axis-specific), clientHeight defaulting to the track length, offset
# clamping, the SEEN-percentage formula ((scrollTop+clientHeight)*100/
# scrollHeight), the indicator=percentage readout row, the <name>_on_scroll
# callback, and thumb geometry.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null

note "vertical: scrollTop/scrollHeight/clientHeight, client defaults to track"
ft-form name=app width=40 height=24
    ft-scrollbar name=v width=1 height=8 scrollHeight=20 onScroll=v_on_scroll
end_ft_form
ft_layout app
_ft_sb_state v
check "client defaulted to the track length" "$FT_SCROLLBAR_CLIENT" "8"
check "no indicator row by default"          "$FT_SCROLLBAR_TRACK" "8"
ft_scrollbar_set v 5
ft_get v scrollTop; check "offset stored under scrollTop" "$FT_RET" "5"
ft_scrollbar_set v 999
ft_get v scrollTop; check "clamps to scrollHeight-clientHeight" "$FT_RET" "12"
ft_scrollbar_set v -3
ft_get v scrollTop; check "clamps to 0" "$FT_RET" "0"

note "horizontal: scrollLeft/scrollWidth/clientWidth"
ft-form name=apph width=40 height=24
    ft-scrollbar name=h orientation=horizontal width=10 height=1 scrollWidth=50
end_ft_form
ft_layout apph
ft_scrollbar_set h 7
ft_get h scrollLeft; check "offset stored under scrollLeft" "$FT_RET" "7"
_ft_sb_state h
check "clientWidth defaulted to the track" "$FT_SCROLLBAR_CLIENT" "10"

note "percentage = share of the document SEEN (last visible line basis)"
ft-form name=appp width=40 height=24
    ft-scrollbar name=p width=1 height=8 scrollHeight=20
end_ft_form
ft_layout appp
ft_scrollbar_percent p
check "at the top: 8 of 20 visible = 40%" "$FT_RET" "40"
ft_scrollbar_set p 6
ft_scrollbar_percent p
check "mid-way: (6+8)/20 = 70%" "$FT_RET" "70"
ft_scrollbar_set p 12
ft_scrollbar_percent p
check "at the bottom: exactly 100%" "$FT_RET" "100"
ft-form name=appf width=40 height=24
    ft-scrollbar name=fits width=1 height=8 scrollHeight=5
end_ft_form
ft_layout appf
ft_scrollbar_percent fits
check "fits entirely → 100%, no divide-by-zero" "$FT_RET" "100"

note "indicator=percentage reserves the last track row (vertical only)"
ft-form name=appi width=40 height=24
    ft-scrollbar name=ind width=4 height=8 scrollHeight=20 indicator=percentage
end_ft_form
ft_layout appi
_ft_sb_state ind
check "track shrank by one row" "$FT_SCROLLBAR_TRACK" "7"
check "client follows the shrunk track" "$FT_SCROLLBAR_CLIENT" "7"
# too short to spare a row → indicator silently ignored
ft-form name=appt width=40 height=24
    ft-scrollbar name=tiny width=4 height=1 scrollHeight=20 indicator=percentage
end_ft_form
ft_layout appt
_ft_sb_state tiny
check "height=1 degrades gracefully" "$FT_SCROLLBAR_INDICATOR_ROW,$FT_SCROLLBAR_TRACK" "0,1"
# horizontal ignores the property entirely
ft-form name=appx width=40 height=24
    ft-scrollbar name=hind orientation=horizontal width=10 height=1 scrollWidth=50 indicator=percentage
end_ft_form
ft_layout appx
_ft_sb_state hind
check "horizontal ignores indicator" "$FT_SCROLLBAR_INDICATOR_ROW" "0"

note "the indicator row actually renders the percentage"
cap=$(mktemp)
exec 9>"$cap"; oldtty=$FT_TTY; FT_TTY=9
FT_OUT=""; ft_draw_one ind; ft_flush
exec 9>&-; FT_TTY=$oldtty
grep -q '35%' "$cap"
check "draw output contains the SEEN percentage (7 of 20 = 35%)" "$?" "0"
rm -f "$cap"

note "on_scroll fires only on ACTUAL changes, with the new offset"
CALLS=0; LASTV=""
v_on_scroll() { (( CALLS++ )); LASTV=$1; }   # $this=v, $1=new offset
ft_scrollbar_set v 4
check "callback fired with new value" "$CALLS,$LASTV" "1,4"
ft_scrollbar_set v 4
check "same value → no callback, no repaint" "$CALLS" "1"
ft_scrollbar_scroll v 2
check "relative scroll works" "$LASTV" "6"

note "class keymap: arrows/PGUP/PGDN/HOME/END drive it when focused"
FT_ROOT=app
ft_focus v 2>/dev/null || FT_FOCUS=v
ft_dispatch_keymap v DOWN
ft_get v scrollTop; check "DOWN steps forward" "$FT_RET" "7"
ft_dispatch_keymap v UP
ft_get v scrollTop; check "UP steps back" "$FT_RET" "6"
ft_dispatch_keymap v END
ft_get v scrollTop; check "END goes to max" "$FT_RET" "12"
ft_dispatch_keymap v HOME
ft_get v scrollTop; check "HOME goes to 0" "$FT_RET" "0"
ft_dispatch_keymap v PGDN
ft_get v scrollTop; check "PGDN pages by clientHeight" "$FT_RET" "8"

note "for=TARGET derives everything from the target (HTML label-for)"
LONG=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do LONG+="line $i"$'\n'; done
LONG=${LONG%$'\n'}
ft-form name=appfor width=40 height=24
    ft-div name=frow display=flex gap=1 alignItems=start
        ft-label name=ftxt text="$LONG" width=10 maxHeight=5
        ft-scrollbar name=fbar for=ftxt width=4
    end_ft_div
end_ft_form
ft_layout appfor
check "bar's auto height matches the target" "${FT_MEASURED_HEIGHT[fbar]}" "${FT_MEASURED_HEIGHT[ftxt]}"
_ft_sb_state fbar
check "total derived from the target's lines" "$FT_SCROLLBAR_TOTAL" "12"
check "client derived from the target's box"  "$FT_SCROLLBAR_CLIENT" "5"
ft_scrollbar_set fbar 3
ft_get ftxt scrollTop; check "target's scrollTop synced automatically" "$FT_RET" "3"
ft_scrollbar_set fbar 999
ft_get fbar scrollTop; check "clamped against derived extents" "$FT_RET" "7"

note "for= bars hide themselves when the content fits (overflow:auto)"
ft-form name=appfit width=40 height=24
    ft-div name=fitRow display=flex gap=1 alignItems=start
        ft-label name=fitTxt text=$'a\nb' width=10 maxHeight=5
        ft-scrollbar name=fitBar for=fitTxt width=4
    end_ft_div
end_ft_form
ft_layout appfit
cap=$(mktemp)
exec 9>"$cap"; oldtty=$FT_TTY; FT_TTY=9
FT_OUT=""; ft_draw_one fitBar; ft_flush
exec 9>&-; FT_TTY=$oldtty
grep -q '48;5;245' "$cap" && thumb=yes || thumb=no
check "no thumb drawn when content fits" "$thumb" "no"
rm -f "$cap"
_ft_scrollbar_focus_skip fitBar && skipped=yes || skipped=no
check "a fitting bar is skipped by focus (invisible = unfocusable)" "$skipped" "yes"
_ft_scrollbar_focus_skip fbar && skipped=yes || skipped=no
check "an overflowing bar stays focusable" "$skipped" "no"

note "thumb geometry: proportional length, position tracks the offset"
# track 8, client 8, total 20 → thumbLen = 8*8/20 = 3
ft_scrollbar_set v 0
cap=$(mktemp); exec 9>"$cap"; oldtty=$FT_TTY; FT_TTY=9
FT_OUT=""; ft_draw_one v; ft_flush
exec 9>&-; FT_TTY=$oldtty
thumb_rows=$(grep -o '48;5;245' "$cap" | grep -c '')
check "thumb is 3 of 8 rows (unfocused FT_COLOR_THUMB colour)" "$thumb_rows" "3"
rm -f "$cap"

summary
