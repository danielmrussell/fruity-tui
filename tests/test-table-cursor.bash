#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  A TABLE'S CURSOR AND SCROLL ARE THE TABLE'S STATE, SO WRITING THEM DOES THE WORK.
#
#  `ft-modify tb cursor=99` on a six-row table stored 99 and highlighted NOTHING — measured on
#  the paint: with a valid cursor exactly one row carries the cursor colours, and with 99 no row
#  did, while `ft_get tb cursor` went on answering 99. `scrollTop=99` was stored verbatim too.
#  ft_table_cursor_set clamped and scrolled the row into view; the property did neither. An app
#  reaching for the obvious name got the wrong one of the two.
#
#  Both verbs are now the property write and nothing else, and the rule they carried lives once
#  in _ft_table_setprop — which _ft_setprop calls on every route in, so a key, an app, the DSL
#  and a state restore all bound the cursor the same way and all drag the view after it.
#
#  The same question for a select's `cursor` — the option an open dropdown is over — has the
#  same answer for the same reason, so it is pinned here beside the table.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=70; FT_ROWS=24; FT_USE_UTF8=1; FT_COLOR_MODE=256

ft-form name=app width=70 height=24
    ft-table name=tb rows=3 striped=false
        ft-table-header "Name"
        ft-table-header "Size"
        ft-table-row "alpha"   "1";  ft-table-row "bravo" "2"; ft-table-row "charlie" "3"
        ft-table-row "delta"   "4";  ft-table-row "echo"  "5"; ft-table-row "foxtrot" "6"
    end_ft_table
    ft-table name=empty rows=3
        ft-table-header "Nothing"
    end_ft_table
    ft-select name=se size=4              # a listbox: four of eight options visible, so it scrolls
        ft-option "one"; ft-option "two"; ft-option "three"; ft-option "four"
        ft-option "five"; ft-option "six"; ft-option "seven"; ft-option "eight"
    end_ft_select
end_ft_form
ft_layout app
FT_ROOT=app

_ROWS=(alpha bravo charlie delta echo foxtrot)
PAINT=""
_draw() { FT_OUT=""; ft_dirty "$1"; ft_draw_one "$1" >/dev/null 2>&1; PAINT=$FT_OUT; FT_OUT=""; }
_visible() {                    # which row names the body is showing, in order
    _draw tb
    local flat=${PAINT} out="" r
    for r in "${_ROWS[@]}"; do case "$flat" in *"$r"*) out+="${out:+ }$r" ;; esac; done
    printf '%s' "$out"
}
_cursor_row() {                 # the ONE visible row painted in different colours from its peers
    _draw tb
    local r before sgr; local -a seen=() names=()
    for r in "${_ROWS[@]}"; do
        case "$PAINT" in *"$r"*) : ;; *) continue ;; esac
        before=${PAINT%%"$r"*}; before=${before##*$'\e['}; sgr=${before%%m*}
        seen+=("$sgr"); names+=("$r")
    done
    local i j n
    for i in "${!seen[@]}"; do                 # the odd one out is the cursor row
        n=0
        for j in "${!seen[@]}"; do [[ "${seen[$j]}" == "${seen[$i]}" ]] && n=$(( n + 1 )); done
        (( n == 1 )) && { printf '%s' "${names[$i]}"; return; }
    done
    printf '<none>'
}
_p() { ft_get "$1" "$2"; printf '%s' "${FT_RET:-<unset>}"; }

note "the fixture really scrolls, and really marks one row (else every check below is vacuous)"
check "three of six rows are shown" "$(_visible)" "alpha bravo charlie"
ft-modify tb cursor=1
check "exactly one row is marked"   "$(_cursor_row)" "bravo"

note "a cursor past the last row lands ON the last row, and the view follows it"
ft-modify tb cursor=99
check "clamped to the last row"     "$(_p tb cursor)"    "5"
check "…and the view scrolled to it" "$(_p tb scrollTop)" "3"
check "…which is what is on screen"  "$(_visible)"        "delta echo foxtrot"
check "…and it is the marked row"    "$(_cursor_row)"     "foxtrot"

note "…and a negative one lands on the first, scrolling back"
ft-modify tb cursor=-4
check "clamped to the first row"     "$(_p tb cursor)"    "0"
check "…and the view came back"      "$(_p tb scrollTop)" "0"
check "…and it is the marked row"    "$(_cursor_row)"     "alpha"

note "the scroll offset is bounded by the rows there are"
ft-modify tb scrollTop=99
check "past the end clamps"          "$(_p tb scrollTop)" "3"
check "…and shows the last window"   "$(_visible)"        "delta echo foxtrot"
ft-modify tb scrollTop=-2
check "before the start clamps"      "$(_p tb scrollTop)" "0"
ft-modify tb scrollTop=1
check "in range is left alone"       "$(_p tb scrollTop)" "1"
check "…and that is the window"      "$(_visible)"        "bravo charlie delta"

note "the verbs are the property write now, so the two routes cannot disagree"
ft-modify tb cursor=0 scrollTop=0
ft_table_cursor_set tb 99
check "the verb clamps the same way"  "$(_p tb cursor),$(_p tb scrollTop)" "5,3"
ft-modify tb cursor=99
check "…and so does the property"     "$(_p tb cursor),$(_p tb scrollTop)" "5,3"
ft_table_key_home tb
check "Home goes to the first row"    "$(_p tb cursor),$(_p tb scrollTop)" "0,0"
ft_table_key_end tb
check "End goes to the last"          "$(_p tb cursor),$(_p tb scrollTop)" "5,3"
ft_table_key_up tb
check "Up steps back one"             "$(_p tb cursor)" "4"

note "a table with no rows takes a cursor write without inventing one"
ft-modify empty cursor=3
check "no rows, no cursor to move"    "$(_p empty cursor)" "0"
ft-modify empty scrollTop=7
check "…and nothing to scroll"        "$(_p empty scrollTop)" "0"

note "a select's cursor is the same rule: bounded, and the window follows it"
ft-modify se cursor=0 scroll=0
ft-modify se cursor=99
check "clamped to the last option"    "$(_p se cursor)" "7"
check "…and the window scrolled to it" "$(_p se scroll)" "4"    # 8 options, 4 visible
ft-modify se cursor=-3
check "…and a negative one to the first" "$(_p se cursor)" "0"
check "…scrolling back to the top"       "$(_p se scroll)" "0"
ft_select_key_end se
check "End still agrees with the property" "$(_p se cursor)" "7"

summary
