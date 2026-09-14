#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  A SCROLLBAR IS A PROMISE THAT YOU CAN SCROLL, AND IT LIVES IN A RESERVED COLUMN.
#
#  The container gutter painter used to draw a bar whenever a `scrollHeight` property merely
#  EXISTED. Two things follow from that, and both were on screen:
#
#    * A label publishes scrollHeight/clientHeight to answer the DOM question "did this
#      overflow?" — a MEASUREMENT. The painter read it as "this is a scrolling container" — a
#      DECISION. So `overflowY=visible`, which means "do not clip, no scrollbar", got a
#      scrollbar. demo/tutorial-demo.bash step 5 exists precisely to teach that value, and the
#      engine was contradicting the lesson: a rail appeared, a reader tried to reach it, and
#      focus was correctly refused because there is genuinely nothing to scroll.
#    * The bar was painted at `x + width - FT_INSET_RIGHT`. With no gutter RESERVED that inset
#      is 0, which is one column PAST the box — over whatever is beside it. A label that really
#      scrolls already paints its own bar in its own last column, so this was a duplicate of a
#      correct bar, one column out.
#
#  Both guards are exercised below, and each is load-bearing on its own: `visibleLabel` fails
#  only the overflow test, `autoLabel` passes it and fails only the reserved-gutter test.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=80; FT_ROWS=24
THIRTY=$(for i in $(seq 1 30); do printf 'line %s\n' "$i"; done)

# Every bar the CONTAINER route paints, with the two facts that decide whether it may.
declare -a GUTTER_BARS=()
ft_scrollbar_paint() {
    local name=$1 col=$3
    _ft_inset4 "$name"
    GUTTER_BARS+=("$name@$col")
}

ft-form name=app width=80 height=24
    ft-div name=scroller width=30 height=6 overflow=auto
        ft-label name=inner text="$THIRTY" width=28
    end_ft_div
    ft-label name=visibleLabel text="$THIRTY" width=20 maxHeight=6 overflowY=visible
    ft-label name=autoLabel    text="$THIRTY" width=20 maxHeight=6 overflowY=auto
end_ft_form
ft_layout app

_paint_cold() {                 # a container served from its retained block never re-runs its
    GUTTER_BARS=()              # gutter draw, and this file would measure nothing at all
    FT_RETAINED_BLOCK=(); FT_RETAINED_TOKEN=()
    ft_dirty_subtree app >/dev/null 2>&1
    FT_OUT=""; _ft_redraw_walk app >/dev/null 2>&1; FT_OUT=""
}
_paint_cold

note "the room is not empty (without this every assertion below is vacuous)"
check "the scrolling container reserved a gutter" \
      "$(_ft_inset4 scroller; echo "$(( FT_INSET_RIGHT > 0 ))")" 1
check "…and the labels did not"  \
      "$(_ft_inset4 autoLabel; echo "$FT_INSET_RIGHT")" 0
check "the labels really do overflow" \
      "$(ft_get autoLabel scrollHeight; echo "$(( FT_RET > 6 ))")" 1

note "a bar is painted only where a gutter was reserved for it"
_bars=" ${GUTTER_BARS[*]:-} "
check "the scrolling container gets its bar"        "$([[ "$_bars" == *" scroller@"* ]] && echo 1 || echo 0)" 1
check "a label with overflowY=visible gets none"    "$([[ "$_bars" == *" visibleLabel@"* ]] && echo 1 || echo 0)" 0
check "a label that paints its OWN bar gets no second one" \
      "$([[ "$_bars" == *" autoLabel@"* ]] && echo 1 || echo 0)" 0

note "the predicate answers the question everything else asks"
ok  "a scrolling container shows a scrollbar"        ft_has_scrollbar scroller y
ok  "…so does an overflowing auto label"             ft_has_scrollbar autoLabel y
no  "overflowY=visible shows none"                   ft_has_scrollbar visibleLabel y
no  "…and neither axis is confused for the other"    ft_has_scrollbar autoLabel x

note "the axis property wins over the shorthand, and both are honoured"
# CSS's rule: overflow-y decides the vertical axis when it is set; the overflow shorthand
# decides it when it is not. Driven through ft-modify, which is how a control's overflow is
# actually spelled in every demo.
ft-modify visibleLabel overflowY=auto;   _paint_cold
ok  "overflowY=auto shows a scrollbar"              ft_has_scrollbar visibleLabel y
ft-modify visibleLabel overflowY=clip;   _paint_cold
no  "…clip hard-clips, so no scrollbar"             ft_has_scrollbar visibleLabel y
ft-modify visibleLabel overflowY=hidden; _paint_cold
no  "…hidden has no bar either (still scrollable programmatically)" ft_has_scrollbar visibleLabel y
ft_remove_attribute visibleLabel overflowY; _paint_cold
ok  "a label with NO overflow property still scrolls (its documented class default)" \
    ft_has_scrollbar visibleLabel y
ft-modify visibleLabel overflowY=visible;  _paint_cold

# The shorthand-vs-axis rule is asked of the DIV, not the label: ft-label deliberately defaults
# overflowY=auto (controls/ft-label.bash:71, documented in its header), so the axis property is
# never unset there and the shorthand can never be the one deciding. Asking on a control whose
# class pins the answer would be a test that cannot fail for the reason it claims.
ft-modify scroller overflow=clip; ft_layout app
no  "a div with overflow=clip shows no bar"         ft_has_scrollbar scroller y
ft-modify scroller overflowY=auto; ft_layout app
ok  "…and its overflow-y outranks the shorthand"    ft_has_scrollbar scroller y
ft_remove_attribute scroller overflowY
ft-modify scroller overflow=auto; ft_layout app; _paint_cold

note "the label that owns a bar still draws one — this fix must not delete it"
# The label paints its own thumb inline and never calls ft_scrollbar_paint, so the check above
# cannot see it. Look at the cells: its own last column must carry ink no other column does.
_paint_cold
_x=${FT_ABSOLUTE_X[autoLabel]:-0}; _w=${FT_MEASURED_WIDTH[autoLabel]:-0}
_own=$(( _x + _w - 1 )); _outside=$(( _x + _w ))
_tmp=$(mktemp); trap 'rm -f "$_tmp"' EXIT
FT_OUT=""; _ft_redraw_walk app >/dev/null 2>&1; printf '%s' "$FT_OUT" > "$_tmp"; FT_OUT=""
_col_ink() {                    # column → how many non-blank cells it holds
    python3 "$here/tools/screen-cells.py" "$_tmp" "$FT_ROWS" "$FT_COLS" \
      | awk -v want="$1" -F'\t' '{ split($1,p,","); if (p[2]+0 == want && $2 != " " && $2 != "") n++ } END { print n+0 }'
}
check "its own last column is inked (its thumb)" "$(( $(_col_ink "$_own") > 0 ))" 1
check "the column beside it is not"              "$(_col_ink "$_outside")" 0

# ─────────────────────────────────────────────────────────────────────────────
#  THE FIXTURE ABOVE COULD NOT REACH THE CASE IT WAS WRITTEN FOR.
#
#  `autoLabel` is spelled `overflowY=auto`, and _ft_inset4 reserves its gutter from the
#  `overflow` SHORTHAND — so autoLabel's inset is 0 and the `FT_INSET_RIGHT > 0` guard stopped
#  the second bar without the label ever being the reason. Write the same label the other way,
#  `ft-label overflow=scroll`, and the inset IS 1: the guard passes, and the container route
#  painted a bar in the very column the label had just painted its own in. Measured inside one
#  ft_draw_one at 60x30: 718 bytes, of which 199 were the second bar.
#
#  The predicate that actually separates the two cases is whether the box scrolls its CHILDREN.
#  A childless control scrolls its own content, draws its own bar in its own well with its own
#  range, and wants no second one from the engine — the same distinction _ft_pass_arrange had
#  to learn when its container branch published a scrollHeight of 0 over a label's own answer.
# ─────────────────────────────────────────────────────────────────────────────
note "a label written with the SHORTHAND reserves a gutter — the case the fixture above misses"
ft-form name=app2 width=80 height=24
    ft-label name=shorthandLabel text="$THIRTY" width=20 maxHeight=6 overflow=scroll
    ft-div   name=emptyScroller  width=20 height=6 overflow=auto
    end_ft_div                                       # an ft-div opens a scope: closing an empty
                                                     # one is what makes it EMPTY, not malformed

    ft-div   name=fullScroller   width=20 height=6 overflow=auto
        ft-label name=inner2 text="$THIRTY" width=18
    end_ft_div
end_ft_form
ft_layout app2
_paint2() { GUTTER_BARS=(); FT_RETAINED_BLOCK=(); FT_RETAINED_TOKEN=()
            ft_dirty_subtree app2 >/dev/null 2>&1
            FT_OUT=""; _ft_redraw_walk app2 >/dev/null 2>&1; FT_OUT=""; }
_paint2

check "it DID reserve a gutter (so the old guard cannot be what stops it)" \
      "$(_ft_inset4 shorthandLabel; echo "$(( FT_INSET_RIGHT > 0 ))")" 1
check "…and it really overflows" \
      "$(ft_get shorthandLabel scrollHeight; echo "$(( FT_RET > 6 ))")" 1
ok  "…and the engine agrees it has a scrollbar"  ft_has_scrollbar shorthandLabel y
_bars2=" ${GUTTER_BARS[*]:-} "
check "…yet the container route paints it NO bar" \
      "$([[ "$_bars2" == *" shorthandLabel@"* ]] && echo 1 || echo 0)" 0

note "…because that route is for a box that scrolls its CHILDREN"
check "a container WITH children still gets its bar" \
      "$([[ "$_bars2" == *" fullScroller@"* ]] && echo 1 || echo 0)" 1
check "an EMPTY scrolling container gets none"  \
      "$([[ "$_bars2" == *" emptyScroller@"* ]] && echo 1 || echo 0)" 0

# ─────────────────────────────────────────────────────────────────────────────
#  AND THE SHAPE THAT WAS ACTUALLY SHIPPING: PADDING AND BORDERS.
#
#  FT_INSET_RIGHT is a SUM — border + padding + (1 if the overflow shorthand reserves a gutter)
#  — so `FT_INSET_RIGHT > 0` cannot tell "a scroll gutter was reserved" from "this control has
#  padding". A scrolling label needs neither the shorthand nor a stylesheet to trip it: one
#  `padding=2` is enough. Measured on the tree before this fix, in one real frame:
#
#      padLbl@col18+len6    the label's own rail is at col 19 — a SECOND rail, one column over
#      bordLbl@col19+len6   same column as its own rail, two thumbs at different positions
#
#  and both ran to row+len-1 = TWO ROWS BELOW the label's box, outside the paint rect the
#  damage system repairs from, over whatever was underneath.
# ─────────────────────────────────────────────────────────────────────────────
note "a scrolling label with PADDING or a BORDER — the shape that was on screen"
ft-form name=app3 width=40 height=24 display=flex flexDirection=column
    ft-label name=padLbl  text="$THIRTY" width=20 maxHeight=6 padding=2
    ft-label name=bordLbl text="$THIRTY" width=20 maxHeight=6 border=true
    ft-div   name=padBox  width=20 height=6 overflow=auto padding=2 display=flex flexDirection=column
        ft-label name=c1 text=one;  ft-label name=c2 text=two;  ft-label name=c3 text=three
        ft-label name=c4 text=four; ft-label name=c5 text=five; ft-label name=c6 text=six
    end_ft_div
end_ft_form
ft_layout app3
GUTTER_BARS=(); FT_RETAINED_BLOCK=(); FT_RETAINED_TOKEN=()
ft_dirty_subtree app3 >/dev/null 2>&1
FT_OUT=""; _ft_redraw_walk app3 >/dev/null 2>&1; FT_OUT=""
_bars3=" ${GUTTER_BARS[*]:-} "

check "the padded label reserved an inset (so the old guard let it through)" \
      "$(_ft_inset4 padLbl; echo "$(( FT_INSET_RIGHT > 0 ))")" 1
ok  "…and it overflows"                       ft_has_scrollbar padLbl y
check "…yet it gets NO container bar"         "$([[ "$_bars3" == *" padLbl@"* ]] && echo 1 || echo 0)" 0
check "the bordered label reserved one too"   "$(_ft_inset4 bordLbl; echo "$(( FT_INSET_RIGHT > 0 ))")" 1
check "…and it gets NO container bar either"  "$([[ "$_bars3" == *" bordLbl@"* ]] && echo 1 || echo 0)" 0

note "…while a PADDED container still gets its bar, and inside its own box"
check "the padded container is painted"       "$([[ "$_bars3" == *" padBox@"* ]] && echo 1 || echo 0)" 1
# The bar runs from y+INSET_TOP for clientHeight rows; both ends must sit inside the control,
# because ink outside its paint rect is ink the damage compositor will never repair.
_ft_inset4 padBox
_top=$(( ${FT_ABSOLUTE_Y[padBox]:-0} + FT_INSET_TOP ))
ft_get padBox clientHeight; _len=${FT_RET:-0}
_boxTop=${FT_ABSOLUTE_Y[padBox]:-0}; _boxBot=$(( _boxTop + ${FT_MEASURED_HEIGHT[padBox]:-0} - 1 ))
check "its bar starts inside the box"         "$(( _top >= _boxTop ))" 1
check "…and ends inside it"                   "$(( _top + _len - 1 <= _boxBot ))" 1

note "and the drag hit-test agrees with the painter, or a bar you can see is one you cannot grab"
# _ft_scroll_gutter_at walks UP from the hit control, so it must refuse the label's own column
# too — otherwise a drag on the label's bar is captured by the container route and scrolls
# nothing.
_sx=${FT_ABSOLUTE_X[shorthandLabel]:-0}; _sw=${FT_MEASURED_WIDTH[shorthandLabel]:-0}
_sy=${FT_ABSOLUTE_Y[shorthandLabel]:-0}
no  "the label's reserved column is not a container gutter" \
    _ft_scroll_gutter_at shorthandLabel $(( _sx + _sw - 1 )) $(( _sy + 1 ))
_fx=${FT_ABSOLUTE_X[fullScroller]:-0}; _fw=${FT_MEASURED_WIDTH[fullScroller]:-0}
_fy=${FT_ABSOLUTE_Y[fullScroller]:-0}
ok  "…but the real container's gutter still is" \
    _ft_scroll_gutter_at fullScroller $(( _fx + _fw - 1 )) $(( _fy + 1 ))

summary
