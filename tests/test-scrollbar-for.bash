#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  `ft-scrollbar for=TARGET` — the promise in controls/ft-scrollbar.bash's own header:
#  "wires the bar to a scrollable control with NO glue code at all: scrollHeight and
#  clientHeight are derived from the target".
#
#  IT WAS TRUE FOR EXACTLY ONE KIND OF TARGET. _ft_sb_target_extent did not read either of those
#  properties. It resolved the target's `text` and re-wrapped it — the LABEL's content model,
#  and only the label's. A div's content is its children, a table's is its rows, a textfield's
#  is `value`; none of them has `text`, so the derivation measured the empty string, the bar
#  decided the content fitted, blanked its rect, focus-skipped and refused to drag.
#
#  AND IT CRASHED. Measuring the empty string walked into _ft_text_extent_cached, whose cache
#  test was `[[ "${!keyvar-}" == "$text" ]]` — for a control never measured before, that is
#  "" == "", a HIT, and the next expression read a variable that does not exist. In a `set -u`
#  app that is fatal, and it printed onto the alt screen. Absent versus empty.
#
#  Two controls also had to start telling the truth about themselves: a textfield and a table
#  both draw their own scrollbar and both declared `overflow: hidden`, so ft_has_scrollbar —
#  the framework's one answer to "does this box present a scrollbar" — said no about a control
#  with a visible thumb.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=80; FT_ROWS=30; FT_USE_UTF8=1

DOC=$(for i in $(seq 1 12); do printf 'line %s\n' "$i"; done)

ft-form name=app width=80 height=30 display=flex flexDirection=column
    ft-label     name=lbl width=20 height=4 overflowY=auto text="$DOC"
    ft-div       name=box width=20 height=4 overflow=auto display=flex flexDirection=column
        ft-label name=k1 text=one;  ft-label name=k2 text=two;  ft-label name=k3 text=three
        ft-label name=k4 text=four; ft-label name=k5 text=five; ft-label name=k6 text=six
    end_ft_div
    ft-textfield name=tf size=18 rows=4 value="$DOC"
    ft-table     name=tbl rows=3
        ft-table-header text="Name"
        ft-table-row alpha; ft-table-row bravo;   ft-table-row charlie
        ft-table-row delta; ft-table-row echo;    ft-table-row foxtrot
    end_ft_table
end_ft_form
ft_layout app
FT_ROOT=app
# EVERY DRAW IN THIS SHELL. A label, a textfield and a table publish their extent FROM the
# draw, and $( ) around one throws that write away — the mistake that first read this whole
# area as "scrollHeight answers 0".
FT_OUT=""; ft_dirty_subtree app >/dev/null 2>&1; _ft_redraw_walk app >/dev/null 2>&1; FT_OUT=""

TARGETS=(lbl box tf tbl)

note "each target really overflows, and says so — without this every check below is vacuous"
for _t in "${TARGETS[@]}"; do
    ft_get "$_t" scrollHeight; _sh=${FT_RET:-0}
    ft_get "$_t" clientHeight; _ch=${FT_RET:-0}
    check "$_t (${FT_TYPE[$_t]}) publishes an extent bigger than its viewport" \
          "$(( _sh > _ch && _ch > 0 ))" 1
done

note "the framework's one answer to \"does this present a scrollbar\" is yes for all four"
for _t in "${TARGETS[@]}"; do
    ok "$_t (${FT_TYPE[$_t]}) has a scrollbar" ft_has_scrollbar "$_t" y
done

note "…and a bound bar reads the target's PUBLISHED pair, not a re-derivation of one kind of it"
for _t in "${TARGETS[@]}"; do
    ft_get "$_t" scrollHeight; _sh=$FT_RET
    ft_get "$_t" clientHeight; _ch=$FT_RET
    FT_SCROLLBAR_TOTAL=""; FT_SCROLLBAR_CLIENT=""
    _ft_sb_target_extent "$_t"
    check "$_t: the bar sees the published extent"   "$FT_SCROLLBAR_TOTAL"  "$_sh"
    check "$_t: …and the published viewport"         "$FT_SCROLLBAR_CLIENT" "$_ch"
done

note "a real bound scrollbar is reachable for every target kind, not just a label"
ft-form name=app2 width=80 height=30 display=flex flexDirection=column
    ft-label     name=t1 width=20 height=4 overflowY=auto text="$DOC"
    ft-scrollbar name=s1 for=t1 height=4
    ft-div       name=t2 width=20 height=4 overflow=auto display=flex flexDirection=column
        ft-label name=m1 text=one;  ft-label name=m2 text=two;  ft-label name=m3 text=three
        ft-label name=m4 text=four; ft-label name=m5 text=five; ft-label name=m6 text=six
    end_ft_div
    ft-scrollbar name=s2 for=t2 height=4
    ft-textfield name=t3 size=18 rows=4 value="$DOC"
    ft-scrollbar name=s3 for=t3 height=4
    ft-table     name=t4 rows=3
        ft-table-header text="N"
        ft-table-row a; ft-table-row b; ft-table-row c
        ft-table-row d; ft-table-row e; ft-table-row f
    end_ft_table
    ft-scrollbar name=s4 for=t4 height=4
end_ft_form
ft_layout app2
FT_ROOT=app2
FT_OUT=""; ft_dirty_subtree app2 >/dev/null 2>&1; _ft_redraw_walk app2 >/dev/null 2>&1; FT_OUT=""
for _s in s1 s2 s3 s4; do
    no "$_s is not focus-skipped (a bar with nothing to scroll would be)" \
       _ft_scrollbar_focus_skip "$_s"
done

note "dragging a bound bar moves the target it is bound to"
# The scrollbar writes  ft_set TARGET scrollTop=N  — so this also exercises the engine's
# clamp, which bounds the offset against the very pair published above.
for _pair in "s2 t2" "s4 t4"; do
    set -- $_pair
    _before=$(ft_get "$2" scrollTop; printf %s "${FT_RET:-0}")
    ft_scrollbar_set "$1" 99 2>/dev/null || _ft_scrollbar_set_pos "$1" 99 2>/dev/null || \
        ft_set "$2" scrollTop=99
    _after=$(ft_get "$2" scrollTop; printf %s "${FT_RET:-0}")
    check "$2 scrolled, and stopped at its own end" \
          "$(( _after > _before ))" 1
    ft_get "$2" scrollHeight; _sh=$FT_RET; ft_get "$2" clientHeight; _ch=$FT_RET
    check "…which is scrollHeight-clientHeight, not 99" "$_after" "$(( _sh - _ch ))"
done

note "the crash: measuring EMPTY text on a never-measured control must not kill a set -u app"
# `[[ "${!keyvar-}" == "$text" ]]` reported a cache hit for "" and then read an unset variable.
ft-form name=app3 width=40 height=10
    ft-div name=blank width=10 height=3
    end_ft_div
end_ft_form
ft_layout app3
_err=$(mktemp)
if ( set -u; _ft_text_extent_cached blank "" ) 2>"$_err"; then
    check "it survives" 1 1
else
    check "it survives" 0 1
fi
check "…silently" "$(grep -c . "$_err")" "0"
grep -q 'unbound variable' "$_err" && check "no unbound-variable error" 0 1 \
                                   || check "no unbound-variable error" 1 1
rm -f "$_err"

note "…and the whole frame draws clean, which is where it actually bit"
# stderr in a TUI is the alt screen, so a frame that scribbles there is a visible defect.
_err2=$(mktemp)
FT_ROOT=app2
if ( set -u; FT_OUT=""; ft_dirty_subtree app2 >/dev/null 2>&1
     _ft_redraw_walk app2 >/dev/null 2>&1 ) 2>"$_err2"; then
    check "a frame holding four bound scrollbars draws" 1 1
else
    check "a frame holding four bound scrollbars draws" 0 1
fi
check "…and writes nothing to stderr" "$(grep -c . "$_err2")" "0"
rm -f "$_err2"

note "the fallback survives, for a target that has published nothing at all"
ft-form name=app4 width=40 height=12
    ft-label name=fresh width=20 height=4 overflowY=auto text="$DOC"
end_ft_form
ft_layout app4
# NOT the window I first assumed. A label publishes at LAYOUT time, not only at paint:
# _ft_label_focus_skip asks _ft_label_metrics whether there is anything to scroll, and the focus
# ring is built during ft_layout — so the pair is there before any frame is drawn. Asserted
# because it is what makes a bar beside a fresh label correct on its very first paint.
check "a label has published before its first draw" \
      "$(ft_get fresh scrollHeight; printf '%s' "${FT_RET:-unset}")" "12"
# So reach the fallback the only way that is left: take the pair away.
ft_unset fresh scrollHeight; ft_unset fresh clientHeight
FT_SCROLLBAR_TOTAL=""; FT_SCROLLBAR_CLIENT=""
_ft_sb_target_extent fresh
check "with nothing published, the extent is still measured from its text" \
      "$(( FT_SCROLLBAR_TOTAL > FT_SCROLLBAR_CLIENT ))" 1

# ─────────────────────────────────────────────────────────────────────────────
#  `for` IS STATE, AND SO IS THE OFFSET
#
#  FT_SCROLLBAR_FOR_TARGET is the reverse index — which bar drives which target — and a label
#  consults it to stand its OWN gutter down when an external bar owns its scrolling UI. It was
#  written by the ft-scrollbar constructor and by nothing else, so retargeting or removing a bar
#  left the old target marked as driven by a bar that had left or, after ft_remove, by a control
#  that no longer existed.
#
#  And the offset: everything that makes a scroll a scroll — the clamp, the target's own
#  offset, onScroll — lived in ft_scrollbar_set, so `ft_set sb scrollTop=7` moved a number
#  and nothing else. The property route is the one an app reaches for and the one ft-state
#  restores through.
# ─────────────────────────────────────────────────────────────────────────────
note "the reverse registry follows \`for\`, on every route"
ft-form name=app5 width=60 height=20 display=flex flexDirection=row
    ft-label     name=tgtA width=20 height=6  overflowY=auto text="$DOC"
    ft-label     name=tgtB width=20 height=10 overflowY=auto text="$DOC"
    ft-scrollbar name=bar  for=tgtA height=6
end_ft_form
ft_layout app5; FT_ROOT=app5
_reg() { printf '%s/%s' "${FT_SCROLLBAR_FOR_TARGET[tgtA]:-none}" "${FT_SCROLLBAR_FOR_TARGET[tgtB]:-none}"; }
check "the constructor registers the target"      "$(_reg)" "bar/none"
ft_set bar for=tgtB
check "ft_set moves the registration"          "$(_reg)" "none/bar"
ft_get bar for
check "…and the property agrees with it"          "$FT_RET" "tgtB"
# The consequence, in the control that reads the registry: a label whose bar has left draws its
# own gutter again, and the one now driven stands its down. Both were wrong the other way.
_ft_label_metrics tgtA; check "the released label draws its own gutter"  "$LBL_GUTTER" "1"
_ft_label_metrics tgtB; check "the driven one stands its gutter down"    "$LBL_GUTTER" "0"
ft_unset bar for
check "removing the attribute releases it too"    "$(_reg)" "none/none"
ft_set bar for=tgtA
check "…and it can be pointed somewhere again"    "$(_reg)" "bar/none"
ft_remove bar
check "removing the BAR takes its entry with it"  "$(_reg)" "none/none"
_ft_label_metrics tgtA; check "…so the label is not driven by a control that is gone" "$LBL_GUTTER" "1"

note "\`for\` is a layout property: it decides two measurements"
ft_prop_kind for; check "for -> layout" "$FT_RET" "layout"

note "writing the offset does everything the verb does, because it is the same job"
ft-form name=app6 width=60 height=20 display=flex flexDirection=row
    ft-label     name=doc width=20 height=4 overflowY=auto text="$DOC"
    ft-scrollbar name=sb6 for=doc height=4
end_ft_form
ft_layout app6; FT_ROOT=app6
SB6_FIRED=""
sb6_on_scroll() { SB6_FIRED="$1"; }
ft_set sb6 onScroll=sb6_on_scroll
_offsets() {                    # → bar/target
    _ft_get_raw sb6 scrollTop; local b=${FT_RET:-unset}
    _ft_get_raw doc scrollTop; printf '%s/%s' "$b" "${FT_RET:-unset}"
}
SB6_FIRED=""; ft_set sb6 scrollTop=5
check "ft_set moves the bar AND the target" "$(_offsets)" "5/5"
check "…and fires onScroll with the offset"    "$SB6_FIRED" "5"
SB6_FIRED=""; ft_scrollbar_set sb6 2
check "the verb does exactly the same"         "$(_offsets)" "2/2"
check "…and fires it too"                      "$SB6_FIRED" "2"
# The clamp is the property's, not the verb's — 12 lines in a 4-row box tops out at 8.
SB6_FIRED=""; ft_set sb6 scrollTop=99
check "an out-of-range write is clamped at the write" "$(_offsets)" "8/8"
check "…and reports the offset it actually reached"   "$SB6_FIRED" "8"
SB6_FIRED=""; ft_set sb6 scrollTop=99
check "…and asking again, from the top, does not move it" "$(_offsets)" "8/8"
check "…nor fire a scroll event for a scroll that did not happen" "$SB6_FIRED" ""
SB6_FIRED=""; ft_set sb6 scrollTop=-4
check "a negative offset is clamped to the top"  "$(_offsets)" "0/0"
check "…and that IS a move, so it fires"         "$SB6_FIRED" "0"

note "an offset does not outlive the document it was measured against"
# The offset is clamped at the write, but nothing writes it when the CONTENT UNDER IT changes.
# Scroll a 12-line target to the bottom, replace its text with one line, and the bar went on
# holding 8 against a maximum of 0 — while the target, which re-clamps its own on the same
# path, had already gone back to 0. Two numbers for one scroll position.
SB6_FIRED=""; ft_set sb6 scrollTop=8
check "at the bottom of twelve lines in four rows" "$(_offsets)" "8/8"
ft_set doc text="one line only"
ft_layout app6
ft_dirty doc; ft_draw_one doc >/dev/null 2>&1
ft_dirty sb6; ft_draw_one sb6 >/dev/null 2>&1
FT_OUT=""
check "the content shrinks and the bar comes back with it" "$(_offsets)" "0/0"
_ft_sb_state sb6
check "…and the bar's own state agrees"          "$FT_SCROLLBAR_POSITION" "0"

# ─────────────────────────────────────────────────────────────────────────────
#  A TEXTFIELD IS A SCROLL SURFACE LIKE ANY OTHER
#
#  It kept its offsets in two private tables (FT_TEXTFIELD_VSCROLL / FT_TEXTFIELD_SCROLL), so
#  the public names were inert: `ft_set tf scrollTop=5` stored 5 and left the view on line 1,
#  `ft-scrollbar for=tf` — documented as needing no glue at all — steered nothing, and a state
#  save carried an offset nothing would restore from. docs/api-naming.md wrote that down and
#  asked for the offsets to be moved onto scrollTop/scrollLeft in one deliberate change.
# ─────────────────────────────────────────────────────────────────────────────
note "a textfield's offsets ARE scrollTop and scrollLeft"
_TFDOC=$(for i in $(seq 1 12); do printf 'line %s\n' "$i"; done)
ft-form name=app7 width=60 height=20 display=flex flexDirection=row alignItems=start
    ft-textfield name=tfv size=18 rows=4 height=4 value="$_TFDOC"
    ft-scrollbar name=tfbar for=tfv height=4
end_ft_form
ft_layout app7; FT_ROOT=app7
_tf_first_line() {              # → FT_RET = the first line number the field is showing
    FT_OUT=""; ft_dirty tfv; ft_draw_one tfv >/dev/null 2>&1
    local ink=$FT_OUT; FT_OUT=""
    FT_RET=$(printf '%s' "$ink" | sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g' | grep -oE 'line [0-9]+' | head -1)
}
_tf_off() { _ft_get_raw "$1" scrollTop; printf '%s' "${FT_RET:-0}"; }
_tf_first_line
check "the field starts at the top"              "$FT_RET" "line 1"
check "…and says so through the DOM's name"      "$(_tf_off tfv)" "0"
ft_set tfv scrollTop=5
_tf_first_line
check "ft_set scrollTop MOVES THE VIEW"       "$FT_RET" "line 6"
check "…and the property agrees with the paint"  "$(_tf_off tfv)" "5"
# The pair the draw publishes bounds it, on every route in — the field's own clamp and the
# framework's have to be the same number or the last line becomes unreachable.
ft_set tfv scrollTop=999
check "an out-of-range write is clamped to the last page" "$(_tf_off tfv)" "10"
_tf_first_line
check "…and that is what it paints"              "$FT_RET" "line 11"
# The promise the header of controls/ft-scrollbar.bash makes: no glue code at all.
ft_scrollbar_set tfbar 3
_tf_first_line
check "an ft-scrollbar for= a textfield steers it" "$FT_RET" "line 4"
check "…and the field's own property followed"     "$(_tf_off tfv)" "3"
# …and the field's own keys move the same property, so there is one offset and not two.
ft_focus tfv >/dev/null 2>&1
ft_textfield_idle_down tfv
check "the field's own Down moves the public name" "$(_tf_off tfv)" "4"
_ft_sb_state tfbar
check "…and the bar beside it sees the move"       "$FT_SCROLLBAR_POSITION" "4"

summary
