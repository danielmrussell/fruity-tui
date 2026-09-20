#!/usr/bin/env bash
# Unit tests for the reflow/repaint pipeline — the CSS performance model:
# paint-only properties repaint ONE control and touch nothing else (scrolling
# is repaint-only, by classification); layout properties reflow but stop the
# moment the control's own size comes out unchanged; genuine size changes
# re-lay only the nearest fixed-size ancestor's subtree. All driven
# automatically by ft_set — no manual relayout calls anywhere.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init

note "the engine's property classification"
ft_prop_kind scrollTop;   check "scrollTop -> paint"    "$FT_RET" "paint"
ft_prop_kind scrollLeft;  check "scrollLeft -> paint"   "$FT_RET" "paint"
ft_prop_kind text;        check "text -> layout"        "$FT_RET" "layout"
ft_prop_kind display;     check "display -> layout"     "$FT_RET" "layout"
ft_prop_kind flexGrow;    check "flexGrow -> layout"    "$FT_RET" "layout"
ft_prop_kind someUnknownProp
check "unknown props default to layout (safe)" "$FT_RET" "layout"
ft_prop_kind_set someUnknownProp paint
ft_prop_kind someUnknownProp
check "classes can classify their own props" "$FT_RET" "paint"

# One fixed-size window with a scrolling label, a sibling, and a cousin —
# the cast for every scenario below.
ft-form name=app width=80 height=24
    ft-frame name=win width=40 height=12
        ft-label name=msg text=$'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8' height=4
        ft-label name=sibling text="sibling"
    end_ft_frame
    ft-label name=cousin text="elsewhere"
end_ft_form
ft_layout app
FT_DIRTY=()

note "scrolling is repaint-only: ONE control dirty, nothing measured"
ft_set msg scrollTop=3
check "only msg is dirty" "${!FT_DIRTY[*]}" "msg"
check "msg size untouched" "${FT_MEASURED_WIDTH[msg]}x${FT_MEASURED_HEIGHT[msg]}" "2x4"
FT_DIRTY=()

note "re-setting the identical value is a complete no-op"
ft_set msg scrollTop=3
check "nothing dirty at all" "${#FT_DIRTY[@]}" "0"

note "a layout change whose size comes out UNCHANGED stops at the control"
ft_set msg text=$'x1\nx2\nx3\nx4\nx5\nx6\nx7\nx8'   # same 2x4 box
check "size identical"       "${FT_MEASURED_WIDTH[msg]}x${FT_MEASURED_HEIGHT[msg]}" "2x4"
check "only msg dirtied"     "${!FT_DIRTY[*]}" "msg"
check "cousin never touched" "${FT_DIRTY[cousin]+set}" ""
FT_DIRTY=()

note "a genuine size change re-lays the nearest fixed-size ancestor only"
ft_set msg text=$'wider line of text here\nsecond'
check "msg got wider"  "$(( ${FT_MEASURED_WIDTH[msg]} > 2 ))" "1"
check "win's subtree repainted (win dirty)"     "${FT_DIRTY[win]+set}"     "set"
check "sibling repositioned/repainted"          "${FT_DIRTY[sibling]+set}" "set"
check "the COUSIN outside the boundary was NOT touched" "${FT_DIRTY[cousin]+set}" ""
# inline flow: the wider msg pushes its line-mate rightward
check "sibling repositioned after the wider msg" "${FT_ABSOLUTE_X[sibling]}" "$(( ${FT_ABSOLUTE_X[msg]} + ${FT_MEASURED_WIDTH[msg]} ))"
FT_DIRTY=()

note "pure moves (left/top) re-arrange the parent without measuring"
ft-form name=mv width=80 height=24
    ft-frame name=mvWin position=absolute left=2 top=2 width=10 height=4
    end_ft_frame
end_ft_form
ft_layout mv
FT_DIRTY=()
ft_set mvWin left=20 top=5
check "moved to the new spot" "${FT_ABSOLUTE_X[mvWin]},${FT_ABSOLUTE_Y[mvWin]}" "20,5"
check "parent repainted (vacated cells)" "${FT_DIRTY[mv]+set}" "set"
FT_DIRTY=()

note "display=none toggle reflows the row around it"
ft-form name=tg width=80 height=24
    ft-div name=tgRow display=flex gap=1 height=1
        ft-label name=tgA text="aaaa"
        ft-label name=tgB text="bbbb"
    end_ft_div
end_ft_form
ft_layout tg
check "B beside A initially" "${FT_ABSOLUTE_X[tgB]}" "5"
ft_set tgA display=none
check "B reflowed to the start" "${FT_ABSOLUTE_X[tgB]}" "0"
check "hidden box has no size"  "${FT_MEASURED_WIDTH[tgA]}" "0"
ft_set tgA display=inline-block
check "B back beside A"         "${FT_ABSOLUTE_X[tgB]}" "5"
FT_DIRTY=()

note "hidden controls are never drawn"
_probe_draw_called=0
_probe_draw() { _probe_draw_called=1; }
ft-form name=hd width=20 height=5
    ft-label name=hdL text=hi draw=_probe_draw display=none
end_ft_form
ft_layout hd
ft_draw_one hdL
check "draw skipped for display=none" "$_probe_draw_called" "0"

note "layout is COALESCED across an input burst, exactly as painting already was"
# A burst of keystrokes used to re-lay the tree once per keystroke and paint once at the end.
# In demo/textfield-demo.bash each key's onChange rewrites three labels — three re-layouts at
# ~84ms apiece — so past ~7 keys/second the loop fell permanently behind and never caught up
# (measured: 151ms CPU per keystroke, and 77% of a core still burning after typing stopped).
# Now a reflow inside a burst is RECORDED and every distinct control is re-laid once at the
# end. What must NOT change is where anything ends up.
_coal_build() {
    ft-form name=cz width=70 height=10 display=flex flexDirection=column
        ft-label name=cz1 text="one"   width=20
        ft-label name=cz2 text="two"   width=20
        ft-label name=cz3 text="three" width=20
    end_ft_form
    ft_layout cz; FT_ROOT=cz
}
_coal_geom() { printf '%s|%s|%s|%s' "${FT_ABSOLUTE_X[cz3]}" "${FT_ABSOLUTE_Y[cz3]}" "${FT_MEASURED_WIDTH[cz3]}" "${FT_MEASURED_HEIGHT[cz3]}"; }
_coal_burst() {                 # 10 "keystrokes", each rewriting all three labels
    local i
    for (( i=0; i<10; i++ )); do
        ft_set cz1 text="one $i"; ft_set cz2 text="two $i"; ft_set cz3 text="three $i"
    done
}
_coal_build; FT_REFLOW_COUNT=0
_coal_burst
_plain=$FT_REFLOW_COUNT; _plaingeom=$(_coal_geom)
ft_remove cz
_coal_build; FT_REFLOW_COUNT=0
FT_COALESCING=1; _coal_burst; FT_COALESCING=0; ft_reflow_flush
check "uncoalesced: one reflow per modify"   "$_plain" "30"
# Three sibling labels pending → ONE reflow of the container that holds all three. Reflowing
# them one by one would each climb past that container anyway, so this is strictly less work.
check "coalesced: collapsed to a single reflow" "$FT_REFLOW_COUNT" "1"
check "…and the geometry is identical"       "$(_coal_geom)" "$_plaingeom"
ft_get cz3 text; check "…and so is the content" "$FT_RET" "three 9"
check "nothing left pending after the flush" "${#FT_REFLOW_PENDING[@]}" "0"
# A control removed mid-burst must not be reflowed after the fact.
FT_COALESCING=1; ft_set cz2 text="gone soon"; ft_remove cz2; FT_COALESCING=0
FT_REFLOW_COUNT=0
ok "flushing after a removal is safe" ft_reflow_flush
ft_remove cz

summary
