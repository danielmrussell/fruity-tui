#!/usr/bin/env bash
# Unit tests for the ft-frame TITLE — the frame's content property.
#
# A frame's content is its title (ft_prototype_frame declares textProp=title), and content is not
# chrome: a <fieldset> with border:none still shows its <legend>. Two ways this disagreed with
# `ft_get title`, both of them in the draw:
#
#   · the borderless branch returned before the title was ever painted, so `border=false` took
#     the title away while the property went on reporting it;
#   · an empty title fell back to `text`, so a frame painted a title ft_get did not report —
#     and `ft_set f title=""`, the way you take a title off, painted the old `text` instead.
#
# tests/test-border.bash covers the border itself; this file covers what is written over it.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=60; FT_ROWS=30

# What a frame actually painted, escapes stripped — the property is only half the assertion.
_painted() {                    # name → FT_RET = its ink as plain text, one line
    local n=$1
    FT_OUT=""; ft_dirty "$n"; ft_draw_one "$n" >/dev/null 2>&1
    local ink=$FT_OUT; FT_OUT=""
    FT_RET=$(printf '%s' "$ink" | sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g' | tr -d '\n')
}
_has() {                        # name needle → FT_RET = 1 when the paint contains it
    _painted "$1"
    case "$FT_RET" in *"$2"*) FT_RET=1 ;; *) FT_RET=0 ;; esac
}

note "a bare DSL argument IS the title (textProp=title), not text"
ft-form name=app width=60 height=30 display=flex flexDirection=column
    ft-frame name=bare width=24 height=4 title=" My Window "
    end_ft_frame
end_ft_form
ft_layout app
ft_get bare title; check "bare content landed in title" "$FT_RET" " My Window "
ft_get bare text;  check "…and not in text"             "$FT_RET" ""
_has bare "My Window"; check "…and it is on the screen"  "$FT_RET" "1"

note "a title is CONTENT: the border can go and the title stays"
ft-form name=app2 width=60 height=30 display=flex flexDirection=column
    ft-frame name=tBord   width=24 height=4 title=Kept
    end_ft_frame
    ft-frame name=tPlain  width=24 height=4 title=Ghost border=false
    end_ft_frame
    ft-frame name=tNone   width=24 height=4 title=Styled borderStyle=none
    end_ft_frame
end_ft_form
ft_layout app2
_has tBord  Kept;   check "a bordered frame paints its title"          "$FT_RET" "1"
_has tPlain Ghost;  check "border=false paints its title too"          "$FT_RET" "1"
_has tNone  Styled; check "borderStyle=none paints its title too"      "$FT_RET" "1"
# …and the property agreed all along, which is why nobody caught the other two.
ft_get tPlain title; check "border=false still reports it"      "$FT_RET" "Ghost"
ft_get tNone  title; check "borderStyle=none still reports it"  "$FT_RET" "Styled"
# Live, through the route an app actually takes.
ft_set tBord border=false; ft_layout app2
_has tBord Kept;    check "ft_set border=false keeps the title" "$FT_RET" "1"
ft_set tBord border=true;  ft_layout app2
_has tBord Kept;    check "…and putting the border back keeps it"  "$FT_RET" "1"

note "the title's row is RESERVED — the border row when there is one, its own row when not"
# Without this a borderless frame painted its title into the content area and the first child,
# which draws after its container, went straight over it: ft_get said Dashed, the screen said
# "border on/off". A <fieldset> keeps room for its <legend> under border:none, and so does this.
ft-form name=app2b width=60 height=30 display=flex flexDirection=column
    ft-frame name=rBord width=24 height=5 title=Top
        ft-label name=rBordKid text=under
    end_ft_frame
    ft-frame name=rPlain width=24 height=5 title=Top border=false
        ft-label name=rPlainKid text=under
    end_ft_frame
    ft-frame name=rBare  width=24 height=5 border=false
        ft-label name=rBareKid text=under
    end_ft_frame
end_ft_form
ft_layout app2b
_ft_inset4 rBord;  check "bordered+titled: the border row is the title's" "$FT_INSET_TOP,$FT_INSET_LEFT" "1,1"
_ft_inset4 rPlain; check "borderless+titled: a row of its own, no column" "$FT_INSET_TOP,$FT_INSET_LEFT" "1,0"
_ft_inset4 rBare;  check "borderless+untitled: a title costs nothing"     "$FT_INSET_TOP,$FT_INSET_LEFT" "0,0"
check "…so a child clears the title in both" \
      "$(( ${FT_ABSOLUTE_Y[rBordKid]}  - ${FT_ABSOLUTE_Y[rBord]}  )),$(( ${FT_ABSOLUTE_Y[rPlainKid]} - ${FT_ABSOLUTE_Y[rPlain]} ))" \
      "1,1"
check "…and an untitled one starts at the top" \
      "$(( ${FT_ABSOLUTE_Y[rBareKid]} - ${FT_ABSOLUTE_Y[rBare]} ))" "0"
# The title survives being composited under its own children — the failure that motivated this.
_painted rPlain;    _p=$FT_RET
_painted rPlainKid; _k=$FT_RET
case "$_p$_k" in *Top*) FT_RET=1 ;; *) FT_RET=0 ;; esac
check "the title is still on screen with the child drawn over the frame" "$FT_RET" "1"
case "$_k" in *Top*) FT_RET=1 ;; *) FT_RET=0 ;; esac
check "…because the child never reaches its row" "$FT_RET" "0"
# Taking the border off a titled frame must not move its content vertically.
_ft_inset4 rBord; _was=$FT_INSET_TOP
ft_set rBord border=false; ft_layout app2b
_ft_inset4 rBord
check "toggling the border on a titled frame does not move its content" "$FT_INSET_TOP" "$_was"

note "a borderless frame has the WHOLE top row for its title; a bordered one keeps its corners"
# 24 columns: bordered, " Kept " (6) centres at col 1 + (22-6)/2 = 9; borderless at (24-6)/2 = 9.
# So the interesting case is a title that only fits WITHOUT the corners.
ft-form name=app3 width=60 height=30 display=flex flexDirection=column
    ft-frame name=wBord  width=10 height=3 title=12345678
    end_ft_frame
    ft-frame name=wPlain width=10 height=3 title=12345678 border=false
    end_ft_frame
end_ft_form
ft_layout app3
_has wBord  " 12345678 "; check "bordered: 10 cells of title do not fit inside 8" "$FT_RET" "0"
_has wPlain " 12345678 "; check "borderless: the same title fits the full row"    "$FT_RET" "1"

note "\`text\` is not a title — one name, one answer"
ft-form name=app4 width=60 height=30 display=flex flexDirection=column
    ft-frame name=fText  width=24 height=4 text=Legacy
    end_ft_frame
    ft-frame name=fBoth  width=24 height=4 text=Old title=New
    end_ft_frame
end_ft_form
ft_layout app4
ft_get fText title; check "text= leaves title unset"      "$FT_RET" ""
_has fText Legacy;  check "…so nothing is painted for it" "$FT_RET" "0"
_has fBoth New;     check "title wins where both are set" "$FT_RET" "1"
_has fBoth Old;     check "…and text is not drawn at all" "$FT_RET" "0"
# The one that bit: clearing a title used to UNCOVER the text under it.
ft_set fBoth title=""
ft_get fBoth title; check "title=\"\" clears it"                 "$FT_RET" ""
_has fBoth Old;     check "…and does not fall back to text"      "$FT_RET" "0"
_has fBoth New;     check "…and the old title is gone from the paint" "$FT_RET" "0"

note "a title still never changes the frame's size"
oldw=${FT_MEASURED_WIDTH[fBoth]}; oldh=${FT_MEASURED_HEIGHT[fBoth]}
ft_set fBoth title="a very much longer title than the frame is wide"
ft_layout app4
check "geometry untouched by a title" \
      "${FT_MEASURED_WIDTH[fBoth]},${FT_MEASURED_HEIGHT[fBoth]}" "$oldw,$oldh"
_has fBoth "a very much longer"; check "…and as much of it as fits is drawn"   "$FT_RET" "1"
_has fBoth "than the frame";     check "…truncated at the border, never spilled" "$FT_RET" "0"

summary
