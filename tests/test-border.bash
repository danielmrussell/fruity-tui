#!/usr/bin/env bash
# Unit tests for CSS border styling mapped onto Unicode box-drawing:
# borderStyle (solid|double|dashed|dotted), borderWidth keywords (thin|
# medium|thick → heavy glyphs), borderRadius (a NUMBER of cells: 0 square,
# ≥1 rounded arc corners — radii >1 clamp to the one arc glyph), ASCII
# fallback, and paint-only classification.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null

note "border CORNERS are paint-only (a TUI border is always one cell); style and width are not"
# borderStyle and borderWidth went layout-kind when none|hidden and 0 started removing the
# border: those change the box's inset, so a write to either name can change geometry and the
# reflow is not optional. borderRadius can only ever pick square or arc corners.
ft_prop_kind borderStyle;  check "borderStyle -> layout" "$FT_RET" "layout"
ft_prop_kind borderWidth;  check "borderWidth -> layout" "$FT_RET" "layout"
ft_prop_kind borderRadius; check "borderRadius -> paint" "$FT_RET" "paint"

ft-form name=app width=60 height=24
    ft-frame name=fSolid   width=8 height=3
    end_ft_frame
    ft-frame name=fDouble  width=8 height=3 borderStyle=double
    end_ft_frame
    ft-frame name=fThick   width=8 height=3 borderWidth=thick
    end_ft_frame
    ft-frame name=fDashed  width=8 height=3 borderStyle=dashed
    end_ft_frame
    ft-frame name=fDotted  width=8 height=3 borderStyle=dotted
    end_ft_frame
    ft-frame name=fRound   width=8 height=3 borderRadius=1
    end_ft_frame
    ft-frame name=fRound2  width=8 height=3 borderRadius=2
    end_ft_frame
    ft-frame name=fDashHvy width=8 height=3 borderStyle=dashed borderWidth=thick
    end_ft_frame
    ft-frame name=fDblHvy  width=8 height=3 borderStyle=double borderWidth=thick borderRadius=1
    end_ft_frame
end_ft_form
ft_layout app

note "glyph selection per style/width/radius"
_ft_border_glyphs fSolid
check "solid: light line + square corners"  "$BG_H$BG_V$BG_TL$BG_BR" $'─│┌┘'
_ft_border_glyphs fDouble
check "double: ═ ║ ╔ ╝"                     "$BG_H$BG_V$BG_TL$BG_BR" $'═║╔╝'
_ft_border_glyphs fThick
check "thick: heavy line + heavy corners"   "$BG_H$BG_V$BG_TL$BG_BR" $'━┃┏┛'
_ft_border_glyphs fDashed
check "dashed: light triple-dash (matched H/V pair)" "$BG_H$BG_V" $'┄┆'
_ft_border_glyphs fDotted
check "dotted: light quadruple-dash (finer)"  "$BG_H$BG_V" $'┈┊'
_ft_border_glyphs fRound
check "radius 1: arc corners, light line"   "$BG_H$BG_TL$BG_TR$BG_BL$BG_BR" $'─╭╮╰╯'
_ft_border_glyphs fRound2
check "radius 2 CLAMPS to the one arc glyph" "$BG_TL$BG_BR" $'╭╯'
_ft_border_glyphs fDashHvy
check "dashed+thick: heavy triple-dash + heavy corners" "$BG_H$BG_V$BG_TL" $'┅┇┏'
_ft_border_glyphs fDblHvy
check "rounded is orthogonal: double sides + LIGHT arc corners" "$BG_H$BG_TL" $'═╭'

note "rounded is orthogonal to every side style"
ft-form name=app2 width=60 height=24
    ft-frame name=fRD width=8 height=3 borderStyle=dashed borderRadius=1
    end_ft_frame
    ft-frame name=fRT width=8 height=3 borderWidth=thick borderRadius=1
    end_ft_frame
end_ft_form
ft_layout app2
_ft_border_glyphs fRD
check "rounded+dashed: arc corners + triple-dash sides" "$BG_TL$BG_H$BG_V" $'╭┄┆'
_ft_border_glyphs fRT
check "rounded+thick: LIGHT arc corners + heavy sides (Unicode has no heavy arc)" "$BG_TL$BG_H$BG_V" $'╭━┃'

note "borderGlyph tiles a decorative glyph on all sides + corners"
ft-form name=app3 width=40 height=10
    ft-frame name=hearts width=8 height=3 borderGlyph=$'\xe2\x99\xa5'
    end_ft_frame
end_ft_form
ft_layout app3
_ft_border_glyphs hearts
check "borderGlyph on every side"   "$BG_H$BG_V" $'\xe2\x99\xa5\xe2\x99\xa5'
check "borderGlyph on every corner" "$BG_TL$BG_TR$BG_BL$BG_BR" $'\xe2\x99\xa5\xe2\x99\xa5\xe2\x99\xa5\xe2\x99\xa5'

note "ft_get is fork-free: sets FT_RET, and fills OUTVAR when given"
ft-label name=gg text="hi there"
ft_get gg text
check "sets FT_RET"          "$FT_RET" "hi there"
ft_get gg text myvar
check "fills the named var too" "$myvar" "hi there"

note "the styled glyphs actually reach the screen"
cap=$(mktemp)
exec 9>"$cap"; oldtty=$FT_TTY; FT_TTY=9
FT_OUT=""; ft_draw_one fDouble; ft_flush
exec 9>&-; FT_TTY=$oldtty
grep -q $'╔' "$cap"; check "double top-left corner rendered" "$?" "0"
grep -q $'═' "$cap"; check "double horizontal rendered"      "$?" "0"
rm -f "$cap"

note "ASCII fallback: every style degrades to the plain glyph set"
_old_utf8=$FT_USE_UTF8
FT_USE_UTF8=0
_ft_border_glyphs fDouble
check "no UTF-8 -> fallback glyphs regardless of style" "$BG_H$BG_V$BG_TL" "${FT_GLYPH_HORIZONTAL}${FT_GLYPH_VERTICAL}${FT_GLYPH_TOP_LEFT}"
FT_USE_UTF8=$_old_utf8

note "restyling a border repaints without moving anything"
oldx=${FT_ABSOLUTE_X[fSolid]}; oldw=${FT_MEASURED_WIDTH[fSolid]}
FT_DIRTY=()
ft-modify fSolid borderStyle=double borderWidth=thick
check "only the frame dirtied" "${!FT_DIRTY[*]}" "fSolid"
check "geometry untouched" "${FT_ABSOLUTE_X[fSolid]},${FT_MEASURED_WIDTH[fSolid]}" "$oldx,$oldw"

# ─────────────────────────────────────────────────────────────────────────────
#  ONE VOCABULARY, AND ONE PREDICATE
#
#  borderStyle used to mean different things depending on who was reading it: ft-table took
#  none|solid|heavy|double|rounded|dashed, ft-frame took solid|double|dashed|dotted, and a frame
#  handed a keyword it did not know painted a plain solid box while ft_get went on reporting the
#  keyword. ft-help's About window has asked a frame for `rounded` since it was written.
#
#  And "does this control have a border" had two implementations that disagreed about an empty
#  value: the draw read "" as false and drew nothing, while _ft_border and _ft_inset4 read "" as
#  "nothing was set", fell through to the prototype default, and reserved the cell anyway.
# ─────────────────────────────────────────────────────────────────────────────
BOXGLYPHS='[─│┌┐└┘━┃┏┓┗┛╭╮╰╯═║╔╗╚╝┄┆┅┇┈┊┉┋]'
_painted_glyphs() {             # name → FT_RET = the box-drawing glyphs it actually emitted
    local n=$1
    FT_OUT=""; ft_dirty "$n"; ft_draw_one "$n" >/dev/null 2>&1
    local ink=$FT_OUT; FT_OUT=""
    # LC_ALL=C so the set comes back in BYTE order and an expectation is not at the mercy of the
    # runner's collation — ╰ and ╯ swap places between a C and a UTF-8 locale.
    FT_RET=$(printf '%s' "$ink" | grep -oE "$BOXGLYPHS" | LC_ALL=C sort -u | tr -d '\n')
}

note "the write normalizes borderStyle, so ft_get can only answer what something draws"
ft-form name=appv width=60 height=24
    ft-frame name=vStyle width=10 height=3
    end_ft_frame
end_ft_form
ft_layout appv
for _pair in zzz:solid groove:solid ridge:solid inset:solid outset:solid \
             DASHED:dashed Rounded:rounded HEAVY:heavy None:none \
             dotted:dotted double:double hidden:hidden; do
    ft-modify vStyle borderStyle="${_pair%%:*}"
    ft_get vStyle borderStyle
    check "borderStyle=${_pair%%:*} reads back as ${_pair#*:}" "$FT_RET" "${_pair#*:}"
done

note "the frame draws every keyword ft-table has always taken"
ft-form name=appk width=60 height=24
    ft-frame name=kHeavy width=10 height=3 borderStyle=heavy
    end_ft_frame
    ft-frame name=kRound width=10 height=3 borderStyle=rounded
    end_ft_frame
    ft-frame name=kDotted width=10 height=3 borderStyle=dotted
    end_ft_frame
end_ft_form
ft_layout appk
_ft_border_glyphs kHeavy
check "borderStyle=heavy IS borderWidth=thick"   "$BG_H$BG_V$BG_TL$BG_BR" $'━┃┏┛'
_ft_border_glyphs kRound
check "borderStyle=rounded IS borderRadius=1"    "$BG_H$BG_TL$BG_TR$BG_BL$BG_BR" $'─╭╮╰╯'
_painted_glyphs kHeavy
check "…and heavy reaches the screen"            "$FT_RET" $'━┃┏┓┗┛'
_painted_glyphs kRound
check "…and rounded reaches the screen"          "$FT_RET" $'─│╭╮╯╰'
_painted_glyphs kDotted
check "dotted reaches the screen"                "$FT_RET" $'┈┊┌┐└┘'

note "border-style: none|hidden is CSS's own 'no border' — in the box model, not at the paint"
ft-form name=appn width=60 height=24
    ft-frame name=nNone   width=10 height=4 borderStyle=none
        ft-label name=nKid text=k
    end_ft_frame
    ft-frame name=nHidden width=10 height=4 borderStyle=hidden
    end_ft_frame
    ft-frame name=nSolid  width=10 height=4 borderStyle=solid
        ft-label name=sKid text=k
    end_ft_frame
end_ft_form
ft_layout appn
_ft_border nNone;              check "_ft_border says no for none"   "$FT_RET" "0"
_ft_border nHidden;            check "_ft_border says no for hidden" "$FT_RET" "0"
_ft_border nSolid;             check "_ft_border says yes for solid" "$FT_RET" "1"
_ft_inset4 nNone
check "none reserves nothing"  "$FT_INSET_TOP,$FT_INSET_LEFT" "0,0"
_ft_inset4 nSolid
check "solid reserves a cell"  "$FT_INSET_TOP,$FT_INSET_LEFT" "1,1"
check "a child sits where the inset put it, in both" \
      "${FT_ABSOLUTE_X[nKid]},${FT_ABSOLUTE_X[sKid]}" \
      "${FT_ABSOLUTE_X[nNone]},$(( ${FT_ABSOLUTE_X[nSolid]} + 1 ))"
_painted_glyphs nNone;   check "none paints no box at all"   "$FT_RET" ""
_painted_glyphs nHidden; check "hidden paints no box at all" "$FT_RET" ""
_painted_glyphs nSolid;  check "solid still paints its box"  "$FT_RET" $'─│┌┐└┘'

note "the draw and the inset ask ONE question about \`border\`"
ft-form name=appb width=60 height=24
    ft-frame name=bx width=10 height=4
        ft-label name=bKid text=k
    end_ft_frame
end_ft_form
ft_layout appb
for _b in true false "" 1; do
    ft-modify bx border="$_b"
    ft_layout appb
    _ft_inset4 bx; _inset=$FT_INSET_LEFT
    _painted_glyphs bx; _drew=0; (( ${#FT_RET} )) && _drew=1
    check "border=${_b:-<empty>}: the draw and the inset agree" "$_drew" "$_inset"
    check "border=${_b:-<empty>}: the child sits inside what was drawn" \
          "${FT_ABSOLUTE_X[bKid]}" "$(( ${FT_ABSOLUTE_X[bx]} + _inset ))"
done

note "borderWidth is a vocabulary too, and 0 is CSS's other spelling of 'no border'"
ft-form name=appw width=60 height=24
    ft-frame name=wZero  width=10 height=4 borderWidth=0
        ft-label name=wZeroKid text=k
    end_ft_frame
    ft-frame name=wThick width=10 height=4 borderWidth=thick
    end_ft_frame
end_ft_form
ft_layout appw
for _pair in thin:thin medium:medium thick:thick THICK:thick 0:0 none:0 5px:thin zzz:thin; do
    ft-modify wThick borderWidth="${_pair%%:*}"
    ft_get wThick borderWidth
    check "borderWidth=${_pair%%:*} reads back as ${_pair#*:}" "$FT_RET" "${_pair#*:}"
done
ft-modify wThick borderWidth=thick
_ft_border wZero;   check "borderWidth=0 removes the border"     "$FT_RET" "0"
_ft_border wThick;  check "…and thick still has one"             "$FT_RET" "1"
_ft_inset4 wZero;   check "…so it reserves nothing"              "$FT_INSET_TOP,$FT_INSET_LEFT" "0,0"
_painted_glyphs wZero;  check "…and paints no box"               "$FT_RET" ""
_painted_glyphs wThick; check "…while thick paints a heavy one"  "$FT_RET" $'━┃┏┓┗┛'

note "a decorative borderGlyph is ONE COLUMN, or it is not stored"
# It tiles one glyph per cell across all four sides, so a two-column one paints twice the box:
# borderGlyph=🌸 drew a 40-column top rule on a 20-column frame, over whatever was beside it.
ft-form name=appg width=60 height=24
    ft-frame name=gl width=20 height=3
    end_ft_frame
end_ft_form
ft_layout appg
_glyph_err=$(mktemp)
_glyphtry() {                   # value → _GL_REFUSED / FT_RET = the painted top rule's width
    : > "$_glyph_err"
    ft-modify gl borderGlyph="$1" 2>"$_glyph_err"    # a file, not $( ): a subshell loses the write
    _GL_REFUSED=no; [[ -s "$_glyph_err" ]] && _GL_REFUSED=yes
    FT_OUT=""; ft_dirty gl; ft_draw_one gl >/dev/null 2>&1
    local ink=$FT_OUT; FT_OUT=""
    local top; top=$(printf '%s' "$ink" | sed -E $'s/\x1b\\[[0-9;]*m//g' \
                      | sed -E $'s/\x1b\\[[0-9;]*H/\\\n/g' | sed -n '2p')
    ft_display_width "$top"; FT_RET=$FT_DISPLAY_WIDTH
}
_glyphtry '-';  check "a one-column glyph is accepted"      "$_GL_REFUSED" "no"
                check "…and tiles the frame's own width"    "$FT_RET"      "20"
_glyphtry $'\xe2\x99\xa5'
                check "a one-column ♥ is accepted"          "$_GL_REFUSED" "no"
                check "…and still tiles 20 columns"         "$FT_RET"      "20"
for _wide in $'\xf0\x9f\x8c\xb8' $'\xe4\xb8\xad' 'ab' '--'; do
    _glyphtry "$_wide"
    check "a two-column borderGlyph is refused"             "$_GL_REFUSED" "yes"
    check "…and the box still paints its own width"         "$FT_RET"      "20"
done
_glyphtry ''
check "clearing it is not a refusal"                        "$_GL_REFUSED" "no"
check "…and the plain border comes back at 20"              "$FT_RET"      "20"
rm -f "$_glyph_err"

note "ft-table reads the same vocabulary the frame does"
_ft_table_glyphs dotted
check "table dotted = the frame's ┈┊ pair"  "$H$V" $'┈┊'
_ft_table_glyphs heavy
check "table heavy = the frame's ━┃ pair"   "$H$V" $'━┃'
ft-form name=appt width=100 height=40
ft-table name=tHid variant=grid borderStyle=hidden
    ft-table-header "Key"
    ft-table-row "a"
end_ft_table
ft-table name=tBox variant=grid
    ft-table-header "Key"
    ft-table-row "a"
end_ft_table
end_ft_form
ft_layout appt
_ft_table_style tHid; check "table borderStyle=hidden drops the box, like none" "$TBL_BOX" "0"
_ft_table_style tBox; check "table with a style keeps it"                       "$TBL_BOX" "1"

summary
