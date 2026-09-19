#!/usr/bin/env bash
# Container scrolling (overflow: auto|scroll) + ft_scroll_set + ft_scroll_into_view + the
# focus auto-reveal. A scrollable container keeps children at NATURAL height and slides a
# viewport (scrollTop) over them; the clip hides the rest.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_COLS=40; FT_ROWS=24

note "column-flex scroller: natural child heights, scrollHeight/clientHeight published"
ft-form name=app width=40 height=24 display=flex flexDirection=column
  ft-div name=pane overflow=auto height=5 width=20 display=flex flexDirection=column gap=0
    for i in 1 2 3 4 5 6 7 8 9 10; do ft-label name="L$i" "row $i"; done
  end_ft_div
  ft-button name=below "Below"
end_ft_form
ft_layout app; FT_ROOT=app
ft_get pane scrollHeight; check "scrollHeight = 10 rows of content" "$FT_RET" "10"
ft_get pane clientHeight; check "clientHeight = the 5-row viewport" "$FT_RET" "5"
ft_get pane scrollTop;    check "starts unscrolled" "$FT_RET" "0"
check "children NOT flex-shrunk (L1 keeps its 1 row)" "${FT_MEASURED_HEIGHT[L1]}" "1"
top0=${FT_ABSOLUTE_Y[L1]}
check "L6 laid out below the fold" "$(( FT_ABSOLUTE_Y[L6] - top0 ))" "5"

note "ft_scroll_set: clamped, shifts the subtree in place (no relayout)"
ft_scroll_set pane 3
ft_get pane scrollTop; check "scrollTop = 3" "$FT_RET" "3"
check "L1 shifted up by 3" "${FT_ABSOLUTE_Y[L1]}" "$(( top0 - 3 ))"
check "L4 is now at the viewport top" "${FT_ABSOLUTE_Y[L4]}" "$top0"
ft_scroll_set pane 99
ft_get pane scrollTop; check "clamps to scrollHeight-clientHeight (5)" "$FT_RET" "5"
ft_scroll_set pane -7 || true
ft_get pane scrollTop; check "negative clamps to 0" "$FT_RET" "0"

note "a full relayout REPRODUCES the scrolled state from the stored prop"
ft_scroll_set pane 4
ft_layout app
ft_get pane scrollTop; check "relayout keeps scrollTop 4" "$FT_RET" "4"
check "…and L1's position matches the incremental shift" "${FT_ABSOLUTE_Y[L1]}" "$(( top0 - 4 ))"

note "the clip hides scrolled-out rows in the actual paint"
ft_scroll_set pane 0; ft_layout app
FT_OUT=""; _ft_redraw_walk app
case "$FT_OUT" in *"row 1"*)  check "row 1 painted while visible" 1 1 ;; *) check "row 1 painted while visible" 0 1 ;; esac
case "$FT_OUT" in *"row 10"*) check "row 10 NOT painted (below the fold)" 0 1 ;; *) check "row 10 NOT painted (below the fold)" 1 1 ;; esac
ft_scroll_set pane 5; ft_layout app
FT_OUT=""; _ft_redraw_walk app
case "$FT_OUT" in *"row 10"*) check "scrolled to bottom: row 10 painted" 1 1 ;; *) check "scrolled to bottom: row 10 painted" 0 1 ;; esac
case "$FT_OUT" in *"row 1 "*|*"row 1"$'\e'*) check "row 1 no longer painted" 0 1 ;; *) check "row 1 no longer painted" 1 1 ;; esac

note "ft_scroll_into_view: minimal scroll (block:nearest)"
ft_scroll_set pane 0
ft_scroll_into_view L8
ft_get pane scrollTop; check "revealing L8 scrolls just enough (8-5=3)" "$FT_RET" "3"
ft_scroll_into_view L8
ft_get pane scrollTop; check "already visible → no change" "$FT_RET" "3"
ft_scroll_into_view L2
ft_get pane scrollTop; check "revealing L2 scrolls back up to 1" "$FT_RET" "1"

note "focus auto-reveals: focusing an off-view control scrolls it into view"
ft-form name=app2 width=40 height=24 display=flex flexDirection=column
  ft-div name=pane2 overflow=scroll height=4 width=24 display=flex flexDirection=column gap=0
    for i in 1 2 3 4 5 6 7 8; do ft-button name="B$i" "btn $i"; done
  end_ft_div
end_ft_form
ft_layout app2; FT_ROOT=app2
ft_focus B7
ft_get pane2 scrollTop; check "focusing B7 (row 7 of a 4-row pane) scrolled to 3" "$FT_RET" "3"
ft_focus B1
ft_get pane2 scrollTop; check "focusing B1 scrolls back to 0" "$FT_RET" "0"

note "block (non-flex) containers scroll too"
ft-form name=app3 width=40 height=24
  ft-div name=bpane overflow=auto height=3 width=20
    for i in 1 2 3 4 5 6; do ft-label name="K$i" display=block "blk $i"; done
  end_ft_div
end_ft_form
ft_layout app3; FT_ROOT=app3
ft_get bpane scrollHeight; check "block scroller: scrollHeight 6" "$FT_RET" "6"
kt0=${FT_ABSOLUTE_Y[K1]}
ft_scroll_set bpane 2
check "block scroll shifts children" "${FT_ABSOLUTE_Y[K1]}" "$(( kt0 - 2 ))"

note "wheel over an inert spot of the pane scrolls it"
FT_ROOT=app; ft_layout app
ft_scroll_set pane 0
px=${FT_ABSOLUTE_X[pane]}; py=${FT_ABSOLUTE_Y[pane]}
FT_MOUSE_BUTTON=65; FT_MOUSE_ACTION=M; FT_MOUSE_X=$(( px + 18 )); FT_MOUSE_Y=$(( py + 1 )); _ft_dispatch_mouse   # wheel-down past the labels
ft_get pane scrollTop; wheel1=$FT_RET
check "wheel-down scrolled the pane (+2)" "$wheel1" "2"
FT_MOUSE_BUTTON=64; _ft_dispatch_mouse
ft_get pane scrollTop; check "wheel-up scrolled back (-2)" "$FT_RET" "0"

note "the scrollbar indicator: a stable gutter column with a proportional thumb"
FT_ROOT=app; ft_layout app
ft_get pane clientWidth 2>/dev/null; :
gcol=$(( FT_ABSOLUTE_X[pane] + FT_MEASURED_WIDTH[pane] - 1 ))            # pane has no border/padding → gutter = last col
check "gutter reserved: content is 1 col narrower than the box" "$(( FT_ABSOLUTE_X[pane] + 20 - 1 ))" "$gcol"
ft_scroll_set pane 0
FT_OUT=""; _ft_redraw_walk app
# The gutter is painted by ft_scrollbar_paint — the SAME renderer the ft-scrollbar control
# uses — so it is the themed thumb (a cell filled with FT_COLOR_THUMB) on a FT_GLYPH_VERTICAL track, not the
# private █/│ pair the gutter used to draw. That divergence is the bug this pins: one app
# should never show two different-looking scrollbars.
case "$FT_OUT" in *"$FT_COLOR_THUMB "*) check "themed thumb drawn (content overflows)" 1 1 ;;
                  *) check "themed thumb drawn (content overflows)" 0 1 ;; esac
case "$FT_OUT" in *"$FT_GLYPH_VERTICAL"*) check "track drawn with the box glyph" 1 1 ;;
                  *) check "track drawn with the box glyph" 0 1 ;; esac

note "horizontal: overflowX=auto row — natural widths, scrollWidth, ft_scroll_to, reveal"
ft-form name=happ width=20 height=8 display=flex flexDirection=column
  ft-div name=hpane overflowX=auto width=14 display=flex gap=1
    ft-label name=H1 display=inline-block "aaaaaa"
    ft-label name=H2 display=inline-block "bbbbbb"
    ft-label name=H3 display=inline-block "cccccc"
  end_ft_div
end_ft_form
ft_layout happ; FT_ROOT=happ
ft_get hpane scrollWidth; check "scrollWidth = 3×6 + 2 gaps = 20" "$FT_RET" "20"
ft_get hpane clientWidth; check "clientWidth = the 14-col viewport" "$FT_RET" "14"
check "children keep NATURAL width (no shrink)" "${FT_MEASURED_WIDTH[H1]}" "6"
h1x=${FT_ABSOLUTE_X[H1]}
ft_scroll_to hpane 4 ""
ft_get hpane scrollLeft; check "ft_scroll_to sets scrollLeft (clamped ok)" "$FT_RET" "4"
check "children shifted left by 4" "${FT_ABSOLUTE_X[H1]}" "$(( h1x - 4 ))"
ft_scroll_to hpane 0 ""
ft_scroll_into_view H3
ft_get hpane scrollLeft; check "revealing H3 scrolls right (20-14=6)" "$FT_RET" "6"
ft_scroll_into_view H1
ft_get hpane scrollLeft; check "revealing H1 scrolls back to 0" "$FT_RET" "0"
FT_OUT=""; _ft_redraw_walk happ
case "$FT_OUT" in *"$FT_COLOR_THUMB "*) check "horizontal thumb drawn in the bottom gutter" 1 1 ;;
                  *) check "horizontal thumb drawn in the bottom gutter" 0 1 ;; esac
case "$FT_OUT" in *"$FT_GLYPH_HORIZONTAL"*) check "horizontal track drawn with the box glyph" 1 1 ;;
                  *) check "horizontal track drawn with the box glyph" 0 1 ;; esac

note "wheel CHAINS through a content-fits control to the pane (browser scroll chaining)"
FT_ROOT=app; ft_layout app; ft_scroll_set pane 0
FT_OUT=""; _ft_redraw_walk app          # a draw, so caches (extents) are warm
lx=${FT_ABSOLUTE_X[L2]}; ly=${FT_ABSOLUTE_Y[L2]}
FT_MOUSE_BUTTON=65; FT_MOUSE_ACTION=M; FT_MOUSE_X=$(( lx + 2 )); FT_MOUSE_Y=$(( ly + 1 )); _ft_dispatch_mouse   # wheel ON the label
ft_get pane scrollTop; check "wheel over a non-overflowing label scrolled the PANE" "$FT_RET" "2"

note "…and so do the KEYS — a label with nothing to scroll declines them, like the wheel"
# The wheel chained (above) but the keys did not: a label bound Up/Down/PgUp/PgDn/Home/End
# unconditionally, so a log inside a scrolling pane could be scrolled by wheel and by nothing
# else. A textfield already declined these six (ft_textfield_idle_*); a label now does too.
FT_ROOT=app; ft_layout app; ft_scroll_set pane 0
FT_KEY_BUBBLE=0; ft_label_key_down L2
check "the key is declined"                    "$?" "1"
check "…and marked to bubble to the pane"      "$FT_KEY_BUBBLE" "1"
ft_get L2 scrollTop; check "the label did not scroll itself" "${FT_RET:-0}" "0"

# A label that CAN scroll still keeps the key — declining is direction-aware, as in a browser.
ft-label name=tall parent=pane text="$(printf 'row %s\n' 1 2 3 4 5 6 7 8 9 10)" height=3
ft_layout app; FT_OUT=""; _ft_redraw_walk app
FT_KEY_BUBBLE=0; ft_label_key_down tall
check "an overflowing label handles the key itself" "$?" "0"
check "…and does not bubble"                        "$FT_KEY_BUBBLE" "0"
ft_get tall scrollTop; check "it scrolled its own text" "${FT_RET:-0}" "1"
FT_KEY_BUBBLE=0; ft_label_key_up tall; ft_label_key_up tall
check "at the top it declines again"                "$FT_KEY_BUBBLE" "1"
ft_remove tall; ft_layout app

note "the gutter is GRABBABLE — press and drag it like any scrollbar"
# Neither the gutter nor the ft-scrollbar control had a mouse handler at all, so a bar you
# could see was a bar you could not touch. A container is inert (no FT_PROTO_MOUSE), so the
# press has to be intercepted before normal targeting and held for the whole drag.
FT_ROOT=app; ft_layout app; ft_scroll_set pane 0
FT_OUT=""; _ft_redraw_walk app
gcol=$(( FT_ABSOLUTE_X[pane] + FT_MEASURED_WIDTH[pane] - 1 ))
gtop=${FT_ABSOLUTE_Y[pane]}
_FT_GUTTER_AXIS=""                      # so the axis check below cannot pass by default
_ft_hit_test "$gcol" $(( gtop + 1 ))
_ft_scroll_gutter_at "$FT_HIT" "$gcol" $(( gtop + 1 ))
check "a point on the gutter resolves to the container" "$FT_RET" "pane"
check "…on the vertical axis"                           "$_FT_GUTTER_AXIS" "v"
_ft_hit_test $(( gcol - 3 )) $(( gtop + 1 ))
_ft_scroll_gutter_at "$FT_HIT" $(( gcol - 3 )) $(( gtop + 1 ))
check "a point on the CONTENT is not a gutter hit"      "$?" "1"

# NB _ft_dispatch_mouse takes 1-BASED terminal coordinates and converts them itself, so
# these are the geometry values +1 — passing raw FT_ABS_* lands one cell off the bar.
ft_get pane clientHeight; track=${FT_RET:-1}       # derive the point; the box height varies above
FT_MOUSE_BUTTON=0; FT_MOUSE_ACTION=M                                     # press at the BOTTOM of the track
FT_MOUSE_X=$(( gcol + 1 )); FT_MOUSE_Y=$(( gtop + track - 1 + 1 ))
_ft_dispatch_mouse
ft_get pane scrollTop; pressed=${FT_RET:-0}
check "pressing the track scrolls there"    "$([[ $pressed -gt 0 ]] && echo moved)" "moved"
check "…and the grab is held for the drag"  "$_FT_GUTTER_GRAB" "pane"
FT_MOUSE_BUTTON=32; FT_MOUSE_ACTION=M                                    # drag back to the top
FT_MOUSE_X=$(( gcol + 1 )); FT_MOUSE_Y=$(( gtop + 1 ))
_ft_dispatch_mouse
ft_get pane scrollTop; check "dragging back up scrolls back" "${FT_RET:-0}" "0"
FT_MOUSE_BUTTON=0; FT_MOUSE_ACTION=m; _ft_dispatch_mouse
check "releasing drops the grab" "$_FT_GUTTER_GRAB" ""

note "a NON-scrollable container is untouched by the machinery"
ft_get below scrollHeight; check "plain button has no scrollHeight" "$FT_RET" ""
ft_scroll_set below 3; check "ft_scroll_set on a non-scroller fails cleanly" "$?" "1"

summary
