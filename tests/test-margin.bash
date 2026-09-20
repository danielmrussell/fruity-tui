#!/usr/bin/env bash
# Unit tests for margin: OUTSIDE the border/padding box (never changes a
# control's own FT_MEASURED_WIDTH/FT_MEASURED_HEIGHT), but reserves space around it in the parent's
# flow — pushing siblings on the main axis and offsetting from the edge on
# the cross axis, in flex rows/columns and in block flow.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init

note "margin never changes the control's own box"
ft-form name=app width=60 height=24
    ft-div name=row display=flex height=5 alignItems=start
        ft-label name=m1 text="abcd" margin=2
        ft-label name=m2 text="efgh"
    end_ft_div
end_ft_form
ft_layout app
check "m1's own width excludes margin"  "${FT_MEASURED_WIDTH[m1]}" "4"
check "m1's own height excludes margin" "${FT_MEASURED_HEIGHT[m1]}" "1"

note "flex row: margin reserves main-axis space and offsets the cross axis"
check "m1 offset from the row's left edge" "${FT_ABSOLUTE_X[m1]}" "2"
check "m1 offset from the row's top edge"  "${FT_ABSOLUTE_Y[m1]}" "2"
check "m2 pushed past m1's margin box"     "${FT_ABSOLUTE_X[m2]}" "$(( 2 + 4 + 2 ))"

note "flex row sizing includes children's margins"
ft-form name=sz width=60 height=24
    ft-div name=szRow display=flex alignItems=start
        ft-label name=szA text="abcd" margin=1
    end_ft_div
end_ft_form
ft_layout sz
# szRow is a block-level child of the form, so its USED width stretches to 60
# (real CSS); its PREFERRED (content) width is what margins feed into.
check "row preferred width = child + 2*margin" "${FT_PREFERRED_WIDTH[szRow]}" "6"
check "row height = child + 2*margin" "${FT_MEASURED_HEIGHT[szRow]}" "3"

note "flex column: margin pushes siblings vertically"
ft-form name=col width=60 height=24
    ft-div name=colBox display=flex flexDirection=column alignItems=start
        ft-label name=cA text="one" margin=1
        ft-label name=cB text="two"
    end_ft_div
end_ft_form
ft_layout col
check "cA offset by its margin"      "${FT_ABSOLUTE_X[cA]},${FT_ABSOLUTE_Y[cA]}" "1,1"
check "cB below cA's margin box"     "${FT_ABSOLUTE_Y[cB]}" "3"

note "block flow: margins offset stacking and line boxes"
ft-form name=blk width=40 height=24
    ft-div name=bBox height=2 margin=1
    end_ft_div
    ft-label name=bLbl text="after"
end_ft_form
ft_layout blk
check "block child inset by margin"      "${FT_ABSOLUTE_X[bBox]},${FT_ABSOLUTE_Y[bBox]}" "1,1"
check "block child stretch minus margins" "${FT_MEASURED_WIDTH[bBox]}" "38"
check "next line clears the margin box"   "${FT_ABSOLUTE_Y[bLbl]}" "4"

note "alignItems=center/end account for margin on the cross axis"
ft-form name=al width=60 height=24
    ft-div name=alRow display=flex alignItems=end height=6
        ft-label name=alA text="x" margin=1
    end_ft_div
end_ft_form
ft_layout al
check "end-aligned = bottom minus margin" "${FT_ABSOLUTE_Y[alA]}" "4"

# ─────────────────────────────────────────────────────────────────────────────
#  PER-SIDE MARGIN. marginTop/Right/Bottom/Left were registered properties the
#  DSL accepted and validated, and no layout path read: every reader went
#  through a _ft_margin that returned only the uniform `margin`. So they parsed,
#  stored, and moved nothing — the failure mode a test cannot notice unless it
#  asks for a side ASYMMETRICALLY. Every case below therefore uses four
#  different values, so a fix that quietly reads one side for all four cannot
#  pass, and so can a fix that reads the uniform value.
# ─────────────────────────────────────────────────────────────────────────────
note "per-side margin never changes the control's own box"
ft-form name=ps width=60 height=24
    ft-div name=psRow display=flex alignItems=start
        ft-label name=p1 text="abcd" marginLeft=3 marginTop=2 marginRight=1 marginBottom=4
        ft-label name=p2 text="efgh"
    end_ft_div
end_ft_form
ft_layout ps
check "p1's own width excludes margin"  "${FT_MEASURED_WIDTH[p1]}"  "4"
check "p1's own height excludes margin" "${FT_MEASURED_HEIGHT[p1]}" "1"

note "flex row: each side offsets and reserves independently"
check "p1 offset by marginLeft"           "${FT_ABSOLUTE_X[p1]}" "3"
check "p1 offset by marginTop"            "${FT_ABSOLUTE_Y[p1]}" "2"
check "p2 pushed by left+width+right"     "${FT_ABSOLUTE_X[p2]}" "$(( 3 + 4 + 1 ))"
check "row height = top+height+bottom"    "${FT_MEASURED_HEIGHT[psRow]}" "$(( 2 + 1 + 4 ))"

note "preferred width counts left+right, not twice either one"
ft-form name=pw width=60 height=24
    ft-div name=pwRow display=flex alignItems=start
        ft-label name=pwA text="abcd" marginLeft=2 marginRight=5
    end_ft_div
end_ft_form
ft_layout pw
check "row preferred width = 4+2+5" "${FT_PREFERRED_WIDTH[pwRow]}" "11"

note "flex column: marginTop/Bottom stack, marginLeft offsets the cross axis"
ft-form name=pc width=60 height=24
    ft-div name=pcBox display=flex flexDirection=column alignItems=start
        ft-label name=pcA text="one" marginTop=2 marginBottom=3 marginLeft=1
        ft-label name=pcB text="two"
    end_ft_div
end_ft_form
ft_layout pc
check "pcA offset by left,top"        "${FT_ABSOLUTE_X[pcA]},${FT_ABSOLUTE_Y[pcA]}" "1,2"
check "pcB below pcA's margin box"    "${FT_ABSOLUTE_Y[pcB]}" "$(( 2 + 1 + 3 ))"

note "block flow: stretch width loses left+right; stacking clears top+bottom"
ft-form name=pb width=40 height=24
    ft-div name=pbBox height=2 marginLeft=3 marginRight=5 marginTop=1 marginBottom=2
    end_ft_div
    ft-label name=pbLbl text="after"
end_ft_form
ft_layout pb
check "block child inset by left,top"      "${FT_ABSOLUTE_X[pbBox]},${FT_ABSOLUTE_Y[pbBox]}" "3,1"
check "block child stretch = 40-3-5"       "${FT_MEASURED_WIDTH[pbBox]}" "32"
check "next line clears top+height+bottom" "${FT_ABSOLUTE_Y[pbLbl]}" "$(( 1 + 2 + 2 ))"

# The margin box must FIT the row: a child is capped to `inner - its own margins`, so a
# top+bottom that eats the whole height leaves it h=0 and this measures nothing. 1+1+2 of 6.
note "alignItems=end measures from the BOTTOM margin, not the top one"
ft-form name=pe width=60 height=24
    ft-div name=peRow display=flex alignItems=end height=6
        ft-label name=peA text="x" marginTop=1 marginBottom=2
    end_ft_div
end_ft_form
ft_layout pe
check "end-aligned = height - bottom - h" "${FT_ABSOLUTE_Y[peA]}" "$(( 6 - 2 - 1 ))"

note "uniform margin and a per-side one COMPOSE, as padding does"
ft-form name=pm width=60 height=24
    ft-div name=pmRow display=flex alignItems=start
        ft-label name=pmA text="z" margin=1 marginTop=2
    end_ft_div
end_ft_form
ft_layout pm
check "left is the uniform value alone" "${FT_ABSOLUTE_X[pmA]}" "1"
check "top is uniform + per-side"       "${FT_ABSOLUTE_Y[pmA]}" "3"

summary
