#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  `checked` IS THE STATE — ON A CHECKBOX AND ON A RADIO.
#
#  CHECKBOX: _ft_multitoggle_setprop keeps `value` and `selectedIndex` in step and left `checked`
#  wherever the app last wrote it. After `ft-modify cb value=false` the box DREW unchecked while
#  `ft_get cb checked` still answered true — the same "reported CHECKED and drew UNCHECKED at the
#  same time" that reconciler was written to prevent, surviving in the one name it did not write.
#
#  RADIO: worse, because the route never existed. `checked=true` — at construction OR at runtime
#  — stored a property nothing read, and the radio drew an empty circle. The selection lived only
#  in FT_RADIO_SELECTED[group], reachable through ft_radio_select and nothing else. `checked` is
#  now the per-control truth (as on <input type=radio>) and the table is the group INDEX over it,
#  which is what makes `ft_radio_value GROUP` possible and is all it is for.
#
#  EVERY ASSERTION READS THE PAINT AS WELL AS THE PROPERTY. That pairing is the point: this whole
#  family of bugs is a property and a glyph disagreeing, and either half alone proves nothing.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=80; FT_ROWS=30; FT_USE_UTF8=1

ft-form name=app width=80 height=30
    ft-checkbox name=cb  text="Ready"
    ft-checkbox name=cb2 text="Born on" checked=true
    ft-radio name=r1 text="One"   group=g
    ft-radio name=r2 text="Two"   group=g checked=true
    ft-radio name=r3 text="Three" checked=true group=h      # checked written BEFORE its group
end_ft_form
ft_layout app
FT_ROOT=app

_p() { ft_get "$1" "$2"; printf '%s' "${FT_RET:-<unset>}"; }
_glyph() {                      # name label — what it paints in front of its label: [x] or ●
    FT_OUT=""; ft_dirty "$1"; ft_draw_one "$1" >/dev/null 2>&1
    local p=$FT_OUT; FT_OUT=""
    p=$(printf '%s' "$p" | sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g' | tr -d '\n')
    p=${p%%"$2"*}               # …by label, NOT by the first space: "[ ]" contains one
    printf '%s' "${p% }"
}
_three() { printf '%s,%s,%s' "$(_p "$1" checked)" "$(_p "$1" value)" "$(_p "$1" selectedIndex)"; }

note "the fixture really draws two different glyphs (without this every glyph check is vacuous)"
check "an unchecked box"  "$(_glyph cb Ready)"  "[ ]"
check "a checked one"     "$(_glyph cb2 "Born on")" "[x]"
check "an empty circle"   "$(_glyph r1 One)"  "○"
check "a filled one"      "$(_glyph r2 Two)"  "●"

note "a checkbox: all three names agree, whichever one you write"
check "as built"                      "$(_three cb)"  "false,false,0"
check "checked= at construction"      "$(_three cb2)" "true,true,1"
ft-modify cb checked=true
check "after checked=true"            "$(_three cb)"  "true,true,1"
check "…and it draws checked"         "$(_glyph cb Ready)"  "[x]"
ft-modify cb value=false
check "after value=false"             "$(_three cb)"  "false,false,0"
check "…and it draws unchecked"       "$(_glyph cb Ready)"  "[ ]"
ft-modify cb selectedIndex=1
check "after selectedIndex=1"         "$(_three cb)"  "true,true,1"
check "…and it draws checked"         "$(_glyph cb Ready)"  "[x]"
ft_checkbox_toggle cb
check "after the toggle verb"         "$(_three cb)"  "false,false,0"
check "…and it draws unchecked"       "$(_glyph cb Ready)"  "[ ]"
ft-modify cb checked=nonsense
check "a non-boolean reads as false"  "$(_three cb)"  "false,false,0"

note "a radio: checked= selects it, at construction and at runtime"
check "an unselected one says so"  "$(_p r1 checked)" "false"
check "checked= at construction"   "$(_p r2 checked)" "true"
check "…and it is really selected" "$(ft_radio_is_selected r2 && printf yes || printf no)" "yes"
check "…even when checked came BEFORE group" "$(_p r3 checked)" "true"
check "…and that one indexes under its group" "$(ft_radio_value h; printf %s "$FT_RET")" "r3"

note "selecting one deselects the group — through either route, with both glyphs following"
ft-modify r1 checked=true
check "the new one is on"   "$(_p r1 checked),$(_glyph r1 One)" "true,●"
check "…and the old one off" "$(_p r2 checked),$(_glyph r2 Two)" "false,○"
ft_radio_select r2
check "the verb agrees: r2 on" "$(_p r2 checked),$(_glyph r2 Two)" "true,●"
check "…and r1 off"            "$(_p r1 checked),$(_glyph r1 One)" "false,○"

note "checked=false leaves the group with NOTHING on — it does not pick a replacement"
ft-modify r2 checked=false
check "r2 is off"                 "$(_p r2 checked),$(_glyph r2 Two)" "false,○"
check "…and r1 was not promoted"  "$(_p r1 checked)" "false"
check "…so the group has no value" "$(ft_radio_value g; printf '[%s]' "$FT_RET")" "[]"
ft_radio_select r1
check "and selecting again fills it" "$(ft_radio_value g; printf %s "$FT_RET")" "r1"

note "a radio that changes group takes its selection with it, releasing the old index"
ft-modify r1 group=moved
check "the old group is empty"   "$(ft_radio_value g; printf '[%s]' "$FT_RET")" "[]"
check "…and the new one has it"  "$(ft_radio_value moved; printf %s "$FT_RET")" "r1"
check "…and it still draws on"   "$(_p r1 checked),$(_glyph r1 One)" "true,●"
ft-modify r1 group=g checked=false

note "checked is a real property, so the generic state save carries it"
# It used to need a per-control-kind record in ft-state.bash for exactly this reason.
ft_radio_select r2
ft-modify cb checked=true
case " ${FT_PROPS[r2]} " in *" checked "*) check "a radio registers checked" 1 1 ;;
                           *) check "a radio registers checked" 0 1 ;; esac
case " ${FT_PROPS[cb]} " in *" checked "*) check "a checkbox registers checked" 1 1 ;;
                           *) check "a checkbox registers checked" 0 1 ;; esac
_state_file=$(mktemp)
ft_state_save "$_state_file"
grep -q '^rad ' "$_state_file" && check "no radio-specific record is written any more" 0 1 \
                               || check "no radio-specific record is written any more" 1 1
grep -q "^prop r2 checked " "$_state_file" && check "the selection is saved as a property" 1 1 \
                                           || check "the selection is saved as a property" 0 1

note "…and a restore puts it back through the ordinary property route"
ft_radio_select r1                       # move it somewhere else first
ft-modify cb checked=false
ft_state_load "$_state_file"
check "the radio came back"   "$(_p r2 checked),$(_glyph r2 Two)" "true,●"
check "…and its rival is off" "$(_p r1 checked),$(_glyph r1 One)" "false,○"
check "…and the index agrees" "$(ft_radio_value g; printf %s "$FT_RET")" "r2"
check "the checkbox came back too" "$(_three cb)" "true,true,1"
rm -f "$_state_file"

# ─────────────────────────────────────────────────────────────────────────────
#  THE CONSTRUCTION ROUTE, which was destroying the very arguments it was handed.
#
#  ft-checkbox appended `selectedIndex=$idx` AFTER the author's own arguments, unconditionally.
#  So `ft-checkbox name=c value=true` and `ft-checkbox name=c selectedIndex=1` both built an
#  UNCHECKED box reporting value=false, while the identical writes at runtime worked. And the
#  constructor tested only `true` and `1` for `checked`, where the runtime reconciler accepts
#  true|1|yes|on — the same spelling, two doors, two answers.
# ─────────────────────────────────────────────────────────────────────────────
note "every spelling of \"this box starts checked\" builds a checked box"
ft-form name=app5 width=80 height=30 display=flex flexDirection=column
    ft-checkbox name=bChecked text="Chk" checked=true
    ft-checkbox name=bValue   text="Val" value=true
    ft-checkbox name=bIndex   text="Idx" selectedIndex=1
    ft-checkbox name=bPlain   text="Pln"
end_ft_form
ft_layout app5
for _n in "bChecked Chk" "bValue Val" "bIndex Idx"; do
    set -- $_n
    check "$1 built checked, all three names agreeing" "$(_three "$1")" "true,true,1"
    check "…and it paints that way"                    "$(_glyph "$1" "$2")" "[x]"
done
check "a plain one is still unchecked"  "$(_three bPlain)" "false,false,0"
check "…and paints unchecked"           "$(_glyph bPlain Pln)" "[ ]"

note "one truthiness predicate: the same spelling means the same thing on both routes"
ft-form name=app6 width=80 height=30 display=flex flexDirection=column
    ft-checkbox name=tYes text="Yes" checked=yes
    ft-checkbox name=tOn  text="On"  checked=on
    ft-checkbox name=tOne text="One" checked=1
    ft-checkbox name=tTru text="Tru" checked=true
    ft-checkbox name=tNo  text="No"  checked=off
end_ft_form
ft_layout app6
for _n in "tYes Yes" "tOn On" "tOne One" "tTru Tru"; do
    set -- $_n
    check "checked=… at CONSTRUCTION checks $1"  "$(_glyph "$1" "$2")" "[x]"
done
check "…and a falsy spelling does not"          "$(_glyph tNo No)" "[ ]"
# The runtime half, on a fresh unchecked box each time — same spellings, same answers.
for _sp in yes on 1 true; do
    ft-modify tNo checked=false
    ft-modify tNo checked="$_sp"
    check "ft-modify checked=$_sp checks it too"  "$(_glyph tNo No)" "[x]"
done
ft-modify tNo checked=off
check "…and off unchecks it"                     "$(_glyph tNo No)" "[ ]"

note "an out-of-range index is clamped at the WRITE — the paint must never see one"
# Before: index 2 or 5 painted NO GLYPH AT ALL; index -1 painted a CHECKED box while `checked`
# and `value` both said false (bash reads -1 as the last element); index -3 or lower put a bash
# "bad array subscript" diagnostic on stderr FROM INSIDE THE DRAW — the alt screen, in a live
# app. stderr is asserted here because that is where the worst of it landed.
_cberr=$(mktemp)
for _v in 2 5 99; do
    ft-modify bPlain selectedIndex=$_v
    check "index $_v clamps to the last option"  "$(_three bPlain)" "true,true,1"
    check "…and paints it"                       "$(_glyph bPlain Pln)" "[x]"
done
for _v in -1 -3 -9; do
    ft-modify bPlain selectedIndex=$_v
    check "index $_v clamps to the first"        "$(_three bPlain)" "false,false,0"
    check "…and paints it"                       "$(_glyph bPlain Pln)" "[ ]"
done
# …and none of that may write a byte to stderr, on the write OR on the paint.
( ft-modify bPlain selectedIndex=-9
  FT_OUT=""; ft_dirty bPlain; ft_draw_one bPlain >/dev/null ) 2>"$_cberr"
check "nothing reached stderr" "$(grep -c . "$_cberr")" "0"
rm -f "$_cberr"

# ─────────────────────────────────────────────────────────────────────────────
#  A BARE MULTITOGGLE'S `checked` WENT STALE, AND THEN WEDGED THE CONTROL.
#
#  The reconciler ACCEPTS `checked=` — it maps it to a selection — so it has claimed the name.
#  It wrote the name back only on the checkbox derived prototype, so a plain multitoggle's went
#  stale the moment the state moved any other way, and ft-modify's "skip a write equal to the stored
#  value" then made `checked=true` a no-op:
#
#      ft-modify mt checked=true   paint [x]  value true   checked true
#      ft_multitoggle_cycle mt     paint [ ]  value false  checked TRUE   ← stale
#      ft-modify mt checked=true   paint [ ]  …nothing at all             ← WEDGED
#
#  Only `false` then `true` recovered it. Maintained now, but only for a control that HAS the
#  property: a three-state multitoggle nobody spells `checked` at must not grow a two-state one.
# ─────────────────────────────────────────────────────────────────────────────
note 'a bare multitoggle keeps `checked` current once it has one — and is not wedged by it'
ft-form name=app7 width=80 height=30 display=flex flexDirection=column
    ft-multitoggle name=mt text="Beep"
        ft-option value=false glyph="[ ]"
        ft-option value=true  glyph="[x]"
    end_ft_multitoggle
    ft-multitoggle name=tri text="Pri"
        ft-option value=low  glyph="(l)"
        ft-option value=mid  glyph="(m)"
        ft-option value=high glyph="(h)"
    end_ft_multitoggle
end_ft_form
ft_layout app7
check "a multitoggle nobody spelled checked at has none" \
      "$(ft_get mt checked; printf '%s' "${FT_RET:-<unset>}")" "<unset>"
ft-modify mt checked=true
check "writing it checks the box"        "$(_glyph mt Beep),$(ft_get mt checked; printf %s "$FT_RET")" "[x],true"
ft_multitoggle_cycle mt
check "…and the CYCLE keeps it current"  "$(_glyph mt Beep),$(ft_get mt checked; printf %s "$FT_RET")" "[ ],false"
ft-modify mt checked=true
check "…so it can be re-checked, not wedged" \
      "$(_glyph mt Beep),$(ft_get mt checked; printf %s "$FT_RET")" "[x],true"
ft-modify mt selectedIndex=0
check "…and an index write keeps it too"  "$(_glyph mt Beep),$(ft_get mt checked; printf %s "$FT_RET")" "[ ],false"

note "…while a three-state multitoggle never grows a two-state property"
ft_multitoggle_cycle tri
check "the cycle moved it"               "$(ft_get tri value; printf %s "$FT_RET")" "mid"
check "…and it still has no checked"     "$(ft_get tri checked; printf '%s' "${FT_RET:-<unset>}")" "<unset>"

summary
