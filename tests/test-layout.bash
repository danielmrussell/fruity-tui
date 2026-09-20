#!/usr/bin/env bash
# Unit tests for the CSS layout engine's non-flex half: the property model,
# CSS sizing semantics (unset = auto/content-sized, explicit = fixed,
# min*/max* clamp either), the borderBox model, block flow (stacking +
# block-child stretch), inline-block line-box wrapping, position=absolute
# with left/top, and the label's scrollTop draw window.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init

note "camelCase property storage (no aliases)"
ft-form name=app width=80 height=24
end_ft_form
ft_get app width; check "width stored"  "$FT_RET"  "80"
ft_get app height; check "height stored" "$FT_RET" "24"

note "lazy inheritance walks up parents; class defaults stop it locally"
ft-form name=t width=40 height=20 color=red
    ft-div name=tp
        ft-label name=tl text=hi
    end_ft_div
end_ft_form
# ft_resolve is the subject under test here — the resolution walk itself, uncoerced. These three
# read through it directly rather than through ft_resolved_prop: coercion is a second mechanism
# and tests/test-coerce.bash is where it is asserted. (Measured, so the choice is not a guess:
# ft_resolved_prop answers `red` / `inline-block` / `block` for these three today, so both forms
# pass — which is exactly why the narrower instrument is the right one.)
ft_resolve tl color
check "color inherits from the form" "$FT_RET" "red"
ft_resolve tl display
check "display never inherits (set locally by class defaults)" "$FT_RET" "inline-block"
ft_resolve tp display
check "panel display is block (CSS default)" "$FT_RET" "block"

note "CSS sizing: unset = auto (content), explicit = fixed, min/max clamp"
ft-form name=s width=60 height=24
    ft-label name=sAuto  text="12345"
    ft-label name=sFixed text="12345" width=30
    ft-label name=sMax   text="a much longer line of text here" maxWidth=10
    ft-label name=sMin   text="ab" minWidth=15
end_ft_form
ft_layout s
check "auto width = content"     "${FT_MEASURED_WIDTH[sAuto]}"  "5"
check "explicit width is fixed"  "${FT_MEASURED_WIDTH[sFixed]}" "30"
check "maxWidth caps auto"       "${FT_MEASURED_WIDTH[sMax]}"   "10"
check "maxWidth forces wrapping (taller)" "$(( ${FT_MEASURED_HEIGHT[sMax]} > 1 ))" "1"
check "minWidth raises auto"     "${FT_MEASURED_WIDTH[sMin]}"   "15"

note "borderBox: border+padding come out of the box, not added to it"
ft-form name=b width=60 height=24
    ft-frame name=bWin width=20 height=8 padding=1
        ft-label name=bMsg text="0123456789 ABCDEFGHIJ"
    end_ft_frame
end_ft_form
ft_layout b
check "frame outer width = declared" "${FT_MEASURED_WIDTH[bWin]}" "20"
# inner = 20 - 2*(border 1 + padding 1) = 16 → block child stretches? label is
# inline-block: shrink-to-fit → min(pref 20, avail 16) = 16 → wraps
check "label constrained to content box" "${FT_MEASURED_WIDTH[bMsg]}" "16"
check "label wrapped to 2 rows" "${FT_MEASURED_HEIGHT[bMsg]}" "2"

note "block flow: block-level children stretch to content width and stack"
ft-form name=bl width=40 height=24
    ft-div name=blA height=2
    end_ft_div
    ft-div name=blB height=3
    end_ft_div
end_ft_form
ft_layout bl
check "block child A stretches" "${FT_MEASURED_WIDTH[blA]}" "40"
check "block child B stretches" "${FT_MEASURED_WIDTH[blB]}" "40"
check "A at top"    "${FT_ABSOLUTE_Y[blA]}" "0"
check "B below A"   "${FT_ABSOLUTE_Y[blB]}" "2"

note "inline-block children flow into line boxes and wrap"
ft-form name=il width=20 height=24
    ft-label name=ilA text="aaaaaaaa"    # 8 wide
    ft-label name=ilB text="bbbbbbbb"    # 8 wide → fits beside A (16 <= 20)
    ft-label name=ilC text="cccccccc"    # 8 wide → wraps to line 2
end_ft_form
ft_layout il
check "A starts line 1"        "${FT_ABSOLUTE_X[ilA]},${FT_ABSOLUTE_Y[ilA]}" "0,0"
check "B beside A"             "${FT_ABSOLUTE_X[ilB]},${FT_ABSOLUTE_Y[ilB]}" "8,0"
check "C wraps to line 2"      "${FT_ABSOLUTE_X[ilC]},${FT_ABSOLUTE_Y[ilC]}" "0,1"
check "container height = 2 lines" "${FT_MEASURED_HEIGHT[il]}" "24"

note "a block-level box mid-flow breaks the inline line"
ft-form name=ml width=30 height=24
    ft-label name=mlA text="aaaa"
    ft-div name=mlBlock height=1
    end_ft_div
    ft-label name=mlB text="bbbb"
end_ft_form
ft_layout ml
check "inline A on line 1"      "${FT_ABSOLUTE_Y[mlA]}" "0"
check "block box on its own row" "${FT_ABSOLUTE_Y[mlBlock]},${FT_MEASURED_WIDTH[mlBlock]}" "1,30"
check "inline B starts a new line" "${FT_ABSOLUTE_X[mlB]},${FT_ABSOLUTE_Y[mlB]}" "0,2"

note "position=absolute: out of flow, placed at left/top, shrink-to-fit"
ft-form name=abs width=60 height=24
    ft-label name=absFlow text="in flow"
    ft-frame name=absWin position=absolute left=10 top=5
        ft-label name=absMsg text="floating"
    end_ft_frame
end_ft_form
ft_layout abs
check "absolute placed at left/top" "${FT_ABSOLUTE_X[absWin]},${FT_ABSOLUTE_Y[absWin]}" "10,5"
check "absolute shrink-to-fit width" "${FT_MEASURED_WIDTH[absWin]}" "$(( 8 + 2 ))"
check "flow sibling unaffected"      "${FT_ABSOLUTE_X[absFlow]},${FT_ABSOLUTE_Y[absFlow]}" "0,0"

note "label scrollTop: draw-time window, clamped to the content"
# overflowY=hidden opts out of the default auto gutter so the window itself
# is what's under test (the gutter has its own coverage elsewhere).
ft-form name=sc width=20 height=24
    ft-label name=scMsg text=$'one\ntwo\nthree\nfour\nfive' height=2 overflowY=hidden
end_ft_form
ft_layout sc
_scdump() {   # scrollTop → echoes visible text (ANSI-stripped)
    ft_set scMsg scrollTop="$1"
    local cap; cap=$(mktemp)
    exec 9>"$cap"; local oldtty=$FT_TTY; FT_TTY=9
    FT_OUT=""; ft_draw_one scMsg; ft_flush
    exec 9>&-; FT_TTY=$oldtty
    # strip CSI incl. PRIVATE-mode sequences (\e[?2026h / \e[?25l from the flush wrapper)
    sed -e 's/\x1b\[[?0-9;]*[A-Za-z]//g' "$cap" | tr -d ' '
    rm -f "$cap"
}
out=$(_scdump 0)
check "scrollTop=0 shows the top"      "${out:0:6}" "onetwo"
out=$(_scdump 2)
check "scrollTop=2 shows the middle"   "${out:0:9}" "threefour"
out=$(_scdump 99)
check "over-scroll clamps to the end"  "${out:0:8}" "fourfive"
out=$(_scdump -5)
check "negative clamps to 0"           "${out:0:6}" "onetwo"

summary
