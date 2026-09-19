#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  `activeTab` IS THE STATE, SO WRITING IT MUST SWITCH THE TAB.
#
#  `ft-modify tabs activeTab=1` moved the number and nothing else: tab 1 stayed visible and tab
#  2 stayed hidden, so programmatic tab switching silently did nothing. `ft_tabs_select` — the
#  same work reached another way — always worked, which is how it went unnoticed.
#
#  Marking the property layout-kind was not enough, and that is the part worth remembering:
#  a reflow re-lays out whatever is visible, and WHICH body is visible is decided by `display`
#  on each body, written only by _ft_tabs_show_only. The reflow faithfully re-laid out the
#  wrong tab.
#
#  In the DOM an index property that names the state is settable and acts — `select.selectedIndex`
#  moves the selection — so the prototype acts on the change, via FT_PROTO_REPROP.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=70; FT_ROWS=24

ft-form name=app width=70 height=24
    ft-tabs name=tb width=40 height=10
        ft-tab title="One";   ft-label name=b1 text="first";  end_ft_tab
        ft-tab title="Two";   ft-label name=b2 text="second"; end_ft_tab
        ft-tab title="Three"; ft-label name=b3 text="third";  end_ft_tab
    end_ft_tabs
end_ft_form
ft_layout app
FT_ROOT=app

_bodies() { _ft_tabs_tabs tb; printf '%s' "${FT_TABS[*]}"; }
_disp()   { _ft_get_raw "$1" display; printf '%s' "${FT_RET:-<unset>}"; }
_shown()  {                     # which body is visible, by name
    local b; _ft_tabs_tabs tb
    for b in "${FT_TABS[@]}"; do [[ "$(_disp "$b")" != none ]] && { printf '%s' "$b"; return; }; done
    printf '<none>'
}

note "the fixture has three real bodies (without this the rest is vacuous)"
check "three tab bodies"          "$(_bodies | wc -w)" "3"
check "the first one is showing"  "$(_shown)"          "$(_ft_tabs_tabs tb; printf '%s' "${FT_TABS[0]}")"

note "writing activeTab switches the tab, not just the number"
ft-modify tb activeTab=1
check "the property moved"        "$(ft_get tb activeTab; printf %s "$FT_RET")" "1"
check "…and so did the body"      "$(_shown)" "$(_ft_tabs_tabs tb; printf '%s' "${FT_TABS[1]}")"
ft-modify tb activeTab=2
check "…and again, to the third"  "$(_shown)" "$(_ft_tabs_tabs tb; printf '%s' "${FT_TABS[2]}")"

note "exactly one body is visible at a time"
# A hook that showed the new tab without hiding the old one would pass everything above.
_visible=0
for _b in $(_bodies); do [[ "$(_disp "$_b")" != none ]] && _visible=$(( _visible + 1 )); done
check "one visible body, not two" "$_visible" "1"

note "an out-of-range index is clamped, as _ft_tabs_apply already promised"
ft-modify tb activeTab=99
check "clamped to the last tab"   "$(ft_get tb activeTab; printf %s "$FT_RET")" "2"
ft-modify tb activeTab=-5
check "…and to the first"         "$(ft_get tb activeTab; printf %s "$FT_RET")" "0"
check "…with the first body showing" "$(_shown)" "$(_ft_tabs_tabs tb; printf '%s' "${FT_TABS[0]}")"

note "the verb still works, and agrees with the property"
ft_tabs_select tb 1
check "ft_tabs_select moved the body"     "$(_shown)" "$(_ft_tabs_tabs tb; printf '%s' "${FT_TABS[1]}")"
check "…and the property agrees with it"  "$(ft_get tb activeTab; printf %s "$FT_RET")" "1"

summary
