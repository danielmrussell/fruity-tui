#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  A SELECT'S `value` AND `selectedIndex` ARE ONE FACT REACHED TWO WAYS.
#
#  `_ft_select_sync` derived `value` from `selectedIndex` when the children were complete, and
#  nowhere else. So `ft-modify se selectedIndex=2` PAINTED the third option while `ft_get se
#  value` still answered the first one's: the control told the app one thing and the user
#  another, at the same time. The reverse direction did not exist at all — `ft-modify se
#  value=c` stored a shadow value the drawing never saw, which is the exact bug ft-multitoggle
#  had already been fixed for.
#
#  And the short form of the API, the one every demo writes —
#
#      ft-option "alpha"
#
#  — read as EMPTY, because `value` was read raw and that option has none. In HTML an option
#  with no value attribute is worth its text; here `ft_get se value` on a select built the
#  natural way returned nothing at all, whichever option was chosen.
#
#  Both directions and the text fallback are pinned here, along with the two things a careless
#  fix breaks: a MULTIPLE select (whose value is the joined list of selected options, and which
#  `selectedIndex` must not overwrite) and a select with DUPLICATE option values (where writing
#  the value you already have must not snap the selection to an earlier twin).
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=70; FT_ROWS=24

ft-form name=app width=70 height=24
    ft-select name=bare width=20                     # the short form: no value= anywhere
        ft-option "alpha"; ft-option "bravo"; ft-option "charlie"
    end_ft_select
    ft-select name=full width=20                     # values spelled out
        ft-option value=a "Alpha"; ft-option value=b "Bravo"; ft-option value=c "Charlie"
    end_ft_select
    ft-select name=multi width=20 multiple=true
        ft-option value=x "Ex" selected=true; ft-option value=y "Why"; ft-option value=z "Zed" selected=true
    end_ft_select
end_ft_form
ft_layout app
FT_ROOT=app

_val()   { ft_get "$1" value;         printf '%s' "${FT_RET:-<unset>}"; }
_idx()   { ft_get "$1" selectedIndex; printf '%s' "${FT_RET:-<unset>}"; }
_paint() {                            # what the closed control actually draws, escapes stripped
    FT_OUT=""; ft_dirty "$1"; ft_draw_one "$1" >/dev/null 2>&1
    local p=$FT_OUT; FT_OUT=""
    printf '%s' "$p" | sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g' | tr -d '\n' | sed -E 's/ +$//'
}

note "an option with no value= is worth its TEXT, as in HTML"
check "three options were built"       "$(_ft_options bare; printf %s ${#FT_OPTS[@]})" "3"
check "…and none of them sets a value" "$(_ft_options bare; _ft_has_prop "${FT_OPTS[0]}" value && printf yes || printf no)" "no"
check "the select's value is the text" "$(_val bare)" "alpha"

note "writing selectedIndex moves the value — and the paint agrees with both"
ft-modify bare selectedIndex=2
check "the index moved"      "$(_idx bare)"   "2"
check "…and so did the value" "$(_val bare)"  "charlie"
check "…and the paint shows it" "$(_paint bare)" "▾ charlie"
ft-modify full selectedIndex=2
check "spelled-out values too"  "$(_val full)" "c"
check "…still painting the text" "$(_paint full)" "▾ Charlie"

note "writing value moves the selection — el.value = 'b' selects Bravo"
ft-modify full value=b
check "the value took"        "$(_val full)" "b"
check "…and the index followed" "$(_idx full)" "1"
check "…and the paint followed" "$(_paint full)" "▾ Bravo"
ft-modify bare value=alpha
check "by text, for a bare option" "$(_idx bare)" "0"

note "a value no option carries is left alone — CSS's rule, and HTML's: nothing is selected"
_before=$(_idx full)
ft-modify full value=nosuchthing
check "the index did not move" "$(_idx full)" "$_before"

note "an explicit value=\"\" is a placeholder, NOT the option's text"
ft-form name=app2 width=70 height=24
    ft-select name=ph width=24
        ft-option value="" "Choose…"; ft-option value=r "Red"
    end_ft_select
end_ft_form
ft_layout app2
check "the placeholder is worth the empty string" "$(_ft_options ph; _ft_option_value "${FT_OPTS[0]}"; printf '[%s]' "$FT_RET")" "[]"
check "…and the select reports it that way"       "$(ft_get ph value; printf '[%s]' "$FT_RET")" "[]"
check "…while its sibling still says r"           "$(_ft_options ph; _ft_option_value "${FT_OPTS[1]}"; printf %s "$FT_RET")" "r"

note "duplicate values: writing the one you already have must not snap to the earlier twin"
ft-form name=app3 width=70 height=24
    ft-select name=dup width=20
        ft-option value=same "First"; ft-option value=other "Middle"; ft-option value=same "Last"
    end_ft_select
end_ft_form
ft_layout app3
ft-modify dup selectedIndex=2
check "the third option is selected" "$(_idx dup)" "2"
check "…and its value is 'same'"     "$(_val dup)" "same"
ft-modify dup value=same                 # exactly what it already answers
check "…and re-writing that value stays put" "$(_idx dup)" "2"
ft-modify dup value=other
check "…while a DIFFERENT value still moves it" "$(_idx dup)" "1"

note "a multiple select is a different shape: its value is the joined list, and the index is not it"
check "both selected options, joined" "$(_val multi)" "x z"
ft-modify multi selectedIndex=1
check "selectedIndex did not overwrite the list" "$(_val multi)" "x z"

note "the key route still agrees with the property route"
ft-modify bare selectedIndex=0
ft_focus bare >/dev/null 2>&1
ft-modify bare open=true cursor=1
ft_select_key_commit bare
check "committing the cursor moved the index" "$(_idx bare)" "1"
check "…and the value with it"                "$(_val bare)" "bravo"

note "an on_change handler reads the NEW value, and cancelling restores BOTH halves"
_seen=""
_watch() { _seen=$(ft_get bare value; printf %s "$FT_RET"); return 0; }
ft-modify bare onChange=_watch
ft-modify bare open=true cursor=2
ft_select_key_commit bare
check "the handler saw the new value" "$_seen" "charlie"
_veto() { return 1; }                        # a handler that cancels the change
ft-modify bare onChange=_veto
ft-modify bare open=true cursor=0
ft_select_key_commit bare
check "a cancelled change restores the index" "$(_idx bare)" "2"
check "…and the value, not just the index"    "$(_val bare)" "charlie"

note "a multitoggle keeps the same contract, including the text fallback"
ft-form name=app4 width=70 height=24
    ft-multitoggle name=mt text="Mode"
        ft-option "on" glyph="[x]"; ft-option "off" glyph="[ ]"
    end_ft_multitoggle
end_ft_form
ft_layout app4
check "value falls back to the option text" "$(_val mt)" "on"
ft_multitoggle_cycle mt
check "cycling moves both"                  "$(_idx mt),$(_val mt)" "1,off"
ft-modify mt value=on
check "and writing the value moves the index back" "$(_idx mt)" "0"

summary
