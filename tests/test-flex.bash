#!/usr/bin/env bash
# Unit tests for display=flex with CSS semantics: flexDirection, gap,
# justifyContent (incl. space-between), alignItems/alignSelf (incl. stretch,
# the CSS default), and the flex item attributes flexGrow / flexShrink /
# flexBasis — including the motivating case: three boxes exchanging real
# estate inside a fixed-width row while the total stays constant.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init

note "flex row: main-axis flow with gap"
ft-form name=r width=60 height=24
    ft-div name=row display=flex gap=2 height=3
        ft-label name=rA text="aaaa"
        ft-label name=rB text="bbb"
    end_ft_div
end_ft_form
ft_layout r
check "A at start"        "${FT_ABSOLUTE_X[rA]}" "0"
check "B after A + gap"   "${FT_ABSOLUTE_X[rB]}" "6"

note "flex column: children stack on the main axis"
ft-form name=c width=60 height=24
    ft-div name=col display=flex flexDirection=column gap=1 alignItems=start
        ft-label name=cA text="one"
        ft-label name=cB text="two"
    end_ft_div
end_ft_form
ft_layout c
check "A on row 0"        "${FT_ABSOLUTE_Y[cA]}" "0"
check "B below + gap"     "${FT_ABSOLUTE_Y[cB]}" "2"

note "justifyContent: center / end / space-between"
ft-form name=j width=20 height=24
    ft-div name=jc display=flex justifyContent=center width=20 height=1
        ft-label name=jcA text="abcd"
    end_ft_div
    ft-div name=je display=flex justifyContent=end width=20 height=1
        ft-label name=jeA text="abcd"
    end_ft_div
    ft-div name=js display=flex justifyContent=space-between width=20 height=1
        ft-label name=jsA text="ab"
        ft-label name=jsB text="cd"
    end_ft_div
end_ft_form
ft_layout j
check "center offsets by free/2"   "${FT_ABSOLUTE_X[jcA]}" "8"
check "end offsets by free"        "${FT_ABSOLUTE_X[jeA]}" "16"
check "space-between pins first"   "${FT_ABSOLUTE_X[jsA]}" "0"
check "space-between pins last"    "${FT_ABSOLUTE_X[jsB]}" "18"

note "alignItems: stretch is the CSS default; start/center/end position"
ft-form name=a width=60 height=24
    ft-div name=aRow display=flex width=30 height=5
        ft-div name=aK width=4
        end_ft_div
    end_ft_div
    ft-div name=aCenter display=flex alignItems=center width=30 height=5
        ft-label name=aC text="x"
    end_ft_div
    ft-div name=aEnd display=flex alignItems=end width=30 height=5
        ft-label name=aE text="x"
    end_ft_div
end_ft_form
ft_layout a
check "stretch fills the row's height (auto-height child)" "${FT_MEASURED_HEIGHT[aK]}" "5"
check "center offsets cross axis" "$(( ${FT_ABSOLUTE_Y[aC]} - ${FT_ABSOLUTE_Y[aCenter]} ))" "2"
check "end pins to cross end"     "$(( ${FT_ABSOLUTE_Y[aE]} - ${FT_ABSOLUTE_Y[aEnd]} ))" "4"

note "alignSelf overrides alignItems per item"
ft-form name=asf width=60 height=24
    ft-div name=asRow display=flex alignItems=start width=30 height=5
        ft-label name=asA text="x"
        ft-label name=asB text="x" alignSelf=end
    end_ft_div
end_ft_form
ft_layout asf
check "sibling follows alignItems=start" "${FT_ABSOLUTE_Y[asA]}" "0"
check "alignSelf=end wins for the item"  "${FT_ABSOLUTE_Y[asB]}" "4"

note "flexGrow: the three-divs case — sides trade space, total constant"
ft-form name=g width=60 height=24
    ft-div name=gRow display=flex width=60 height=3
        ft-div name=gL flexGrow=1
        end_ft_div
        ft-div name=gM width=20
        end_ft_div
        ft-div name=gR flexGrow=3
        end_ft_div
    end_ft_div
end_ft_form
ft_layout g
check "middle keeps its fixed width" "${FT_MEASURED_WIDTH[gM]}" "20"
check "free space split 1:3"         "${FT_MEASURED_WIDTH[gL]},${FT_MEASURED_WIDTH[gR]}" "10,30"
check "total conserved"              "$(( ${FT_MEASURED_WIDTH[gL]} + ${FT_MEASURED_WIDTH[gM]} + ${FT_MEASURED_WIDTH[gR]} ))" "60"

note "flexShrink: overflow deficit removed in proportion to shrink*base"
ft-form name=sh width=30 height=24
    ft-div name=shRow display=flex width=30 height=1
        ft-label name=shA text="aaaaaaaaaaaaaaaaaaaa"   # base 20
        ft-label name=shB text="bbbbbbbbbbbbbbbbbbbb"   # base 20, sum 40 > 30
    end_ft_div
end_ft_form
ft_layout sh
check "equal bases shrink equally" "${FT_MEASURED_WIDTH[shA]},${FT_MEASURED_WIDTH[shB]}" "15,15"
ft-form name=sh2 width=30 height=24
    ft-div name=sh2Row display=flex width=30 height=1
        ft-label name=sh2A text="aaaaaaaaaaaaaaaaaaaa" flexShrink=0
        ft-label name=sh2B text="bbbbbbbbbbbbbbbbbbbb"
    end_ft_div
end_ft_form
ft_layout sh2
check "flexShrink=0 is rigid; the other absorbs it" "${FT_MEASURED_WIDTH[sh2A]},${FT_MEASURED_WIDTH[sh2B]}" "20,10"

note "flexBasis overrides width/content as the starting main size"
ft-form name=fb width=40 height=24
    ft-div name=fbRow display=flex width=40 height=1
        ft-label name=fbA text="aa" flexBasis=10
        ft-label name=fbB text="bb" flexBasis=10 flexGrow=1
    end_ft_div
end_ft_form
ft_layout fb
check "basis sets the base size"        "${FT_MEASURED_WIDTH[fbA]}" "10"
check "grow adds the leftover to B"     "${FT_MEASURED_WIDTH[fbB]}" "30"

note "column flexGrow distributes free height at arrange time"
ft-form name=cg width=20 height=24
    ft-div name=cgCol display=flex flexDirection=column width=20 height=12
        ft-div name=cgA height=2
        end_ft_div
        ft-div name=cgB flexGrow=1
        end_ft_div
    end_ft_div
end_ft_form
ft_layout cg
check "fixed child keeps height"    "${FT_MEASURED_HEIGHT[cgA]}" "2"
check "grow child takes the rest"   "${FT_MEASURED_HEIGHT[cgB]}" "10"
check "grow child positioned below" "${FT_ABSOLUTE_Y[cgB]}" "2"

summary
