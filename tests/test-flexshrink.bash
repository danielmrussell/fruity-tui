#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  FLEX SHRINK MUST LAND INSIDE THE BOX ON BOTH AXES.
#
#  Distributing a shrink by integer division UNDER-shrinks: three items of 10 sharing a
#  deficit of 11 each lose 3 and settle at 7+7+7 = 21, two columns past a 19-wide box. The
#  column axis learned this and burns the remainder off the largest shrinkable items; the row
#  axis never got the fix, so a row of frames had its last child's right border clipped away
#  by the container's own overflow — the exact width analogue of the bug the column branch
#  documents having fixed.
#
#  Copy drift: one algorithm, two transcriptions, a correction applied to one. Pinned on both
#  axes with the same numbers so the pair cannot drift again.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
cd "$here"
export FT_NO_WTFIX=1
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_USE_UTF8=1
FT_COLS=60; FT_ROWS=24

note "a row of three 10-wide items in a 19-wide box"
ft-form name=app width="$FT_COLS" height="$FT_ROWS"
    ft-div name=rowbox display=flex flexDirection=row width=19 height=3
        ft-label name=r1 text="aaaaaaaaaa" width=10
        ft-label name=r2 text="bbbbbbbbbb" width=10
        ft-label name=r3 text="cccccccccc" width=10
    end_ft_div
end_ft_form
FT_ROOT=app; ft_layout app

W1=${FT_MEASURED_WIDTH[r1]}; W2=${FT_MEASURED_WIDTH[r2]}; W3=${FT_MEASURED_WIDTH[r3]}
SUM=$(( W1 + W2 + W3 ))
INNER=${FT_MEASURED_WIDTH[rowbox]}
note "  widths $W1 + $W2 + $W3 = $SUM, box $INNER"
check "the row's children fit the box" "$(( SUM <= INNER ))" 1

# the decisive geometry: the last child must end inside the container
BOX_R=$(( FT_ABSOLUTE_X[rowbox] + FT_MEASURED_WIDTH[rowbox] - 1 ))
R3_R=$(( FT_ABSOLUTE_X[r3] + FT_MEASURED_WIDTH[r3] - 1 ))
note "  container right edge $BOX_R, last child right edge $R3_R"
check "the last child ends inside the container" "$(( R3_R <= BOX_R ))" 1

note "the column twin, same numbers — it already worked and must keep working"
ft-form name=app2 width="$FT_COLS" height="$FT_ROWS"
    ft-div name=colbox display=flex flexDirection=column width=12 height=19
        ft-label name=c1 text="a" height=10
        ft-label name=c2 text="b" height=10
        ft-label name=c3 text="c" height=10
    end_ft_div
end_ft_form
FT_ROOT=app2; ft_layout app2
H1=${FT_MEASURED_HEIGHT[c1]}; H2=${FT_MEASURED_HEIGHT[c2]}; H3=${FT_MEASURED_HEIGHT[c3]}
HSUM=$(( H1 + H2 + H3 ))
HINNER=${FT_MEASURED_HEIGHT[colbox]}
note "  heights $H1 + $H2 + $H3 = $HSUM, box $HINNER"
check "the column's children fit the box" "$(( HSUM <= HINNER ))" 1

note "a deficit of one, which integer division loses entirely"
ft-form name=app3 width="$FT_COLS" height="$FT_ROWS"
    ft-div name=rowbox2 display=flex flexDirection=row width=13 height=3
        ft-label name=s1 text="aaaaaaa" width=7
        ft-label name=s2 text="bbbbbbb" width=7
    end_ft_div
end_ft_form
FT_ROOT=app3; ft_layout app3
S1=${FT_MEASURED_WIDTH[s1]}; S2=${FT_MEASURED_WIDTH[s2]}
note "  widths $S1 + $S2 = $(( S1 + S2 )), box ${FT_MEASURED_WIDTH[rowbox2]}"
check "a one-column deficit is still taken" "$(( S1 + S2 <= FT_MEASURED_WIDTH[rowbox2] ))" 1

note "and the rendered frame keeps its last border"
ft-form name=app4 width="$FT_COLS" height="$FT_ROWS"
    ft-div name=rowbox3 display=flex flexDirection=row width=19 height=3
        ft-frame name=f1 width=7 height=3
        end_ft_frame
        ft-frame name=f2 width=7 height=3
        end_ft_frame
        ft-frame name=f3 width=7 height=3
        end_ft_frame
    end_ft_div
end_ft_form
FT_ROOT=app4; ft_layout app4
FT_OUT=""; _ft_redraw_walk app4; frame=$FT_OUT; FT_OUT=""
# every frame draws a corner glyph at each end of its top row; three frames means three
# right-hand corners survive only if the third one fits inside the clip
corners=$(printf '%s' "$frame" | grep -o '┐' | grep -c .)
note "  top-right corners drawn: $corners"
check "all three frames keep their right border" "$corners" 3

note "shrink still does nothing when the row scrolls horizontally"
ft-form name=app5 width="$FT_COLS" height="$FT_ROWS"
    ft-div name=scrollrow display=flex flexDirection=row width=19 height=3 overflowX=auto
        ft-label name=x1 text="aaaaaaaaaa" width=10
        ft-label name=x2 text="bbbbbbbbbb" width=10
    end_ft_div
end_ft_form
FT_ROOT=app5; ft_layout app5
check "a scrolling row keeps its children at natural width" \
      "${FT_MEASURED_WIDTH[x1]}/${FT_MEASURED_WIDTH[x2]}" "10/10"

summary
