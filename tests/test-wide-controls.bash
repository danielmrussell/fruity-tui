#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tests/test-wide-controls.bash — NO CONTROL MAY PAINT OUTSIDE ITS OWN BOX.
#
#  The text field turned out to be indexing strings by screen column (see test-wide.bash), and
#  the question that follows is: where else? Rather than read every control looking for the
#  mistake, this drives them all and checks the one thing the mistake always breaks.
#
#  A control's draw ends in ft_print_at/ft_print_at_width calls, each addressed to a cell. Whatever the control
#  believes about its content, every one of those runs must start inside the control's box and
#  end inside it — measured in DISPLAY COLUMNS, which is what the terminal will actually
#  advance by. A control that counted characters where it meant columns paints past its right
#  edge by one cell per wide glyph, over its neighbour or over the border; a control that
#  counted columns where it meant characters comes up short and leaves a hole.
#
#  Each control is given the same five strings: ASCII (the control case), Japanese, a mix,
#  emoji, and something far too long for its box. ASCII passing while CJK fails is the whole
#  signature of this bug class, so both run every time.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=100; FT_ROWS=40
FT_USE_UTF8=1          # the mode a person actually sees — in ASCII mode the glyphs degrade

TEXTS=(
    "Options"                                   # ASCII: the control case
    "設定オプション"                              # all wide
    "設定 Options 設定"                          # mixed
    "🎉🎉🎉"                                     # emoji (wide, and outside the BMP)
    "設定オプション設定オプション設定オプション設定"   # far too long for any box here
)
LABELS=(ascii japanese mixed emoji overlong)

# Every addressed run in the frame, as "row col text" — the split points are the cursor
# addresses ft_print_at writes, so each run is exactly one uninterrupted write.
_runs() {                       # → the array RUNS
    RUNS=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && RUNS+=("$line")
    done < <(printf '%s' "$FT_OUT" | sed -e $'s/\x1b\\[\\([0-9]*\\);\\([0-9]*\\)H/\\n\\1 \\2 /g' | sed -n '2,$p')
}

# Paint ONE control and report every run that escaped its box.
_escapes() {                    # name → FT_RET ("" when clean)
    local n=$1
    local x=${FT_ABSOLUTE_X[$n]:-0} y=${FT_ABSOLUTE_Y[$n]:-0}
    local w=${FT_MEASURED_WIDTH[$n]:-0} h=${FT_MEASURED_HEIGHT[$n]:-0}
    FT_OUT=""; ft_draw_one "$n"
    local -a RUNS; _runs
    local r row col text out=""
    for r in "${RUNS[@]}"; do
        row=${r%% *}; r=${r#* }
        col=${r%% *}; text=${r#* }
        ft_display_width "$text"
        (( row - 1 <  y ))          && out+="row $((row-1))<top "
        (( row - 1 >= y + h ))      && out+="row $((row-1))>=bottom($((y+h))) "
        (( col - 1 <  x ))          && out+="col $((col-1))<left "
        (( col - 1 + FT_DISPLAY_WIDTH > x + w )) \
            && out+="run at col $((col-1)) is $FT_DISPLAY_WIDTH wide, past right edge $((x+w)) "
    done
    FT_RET=$out
}

# Drive one control type through all five strings. `build` is a function taking the text.
_sweep() {                      # description buildfn
    local desc=$1 build=$2 i
    for i in "${!TEXTS[@]}"; do
        ft_remove sweepform 2>/dev/null
        ft-form name=sweepform width=30 height=14
            "$build" "${TEXTS[$i]}"
        end_ft_form
        ft_layout sweepform; FT_ROOT=sweepform
        _escapes victim
        check "$desc — ${LABELS[$i]}" "${FT_RET:-inside its box}" "inside its box"
    done
}

note "leaf controls stay inside their boxes"
_b_label()      { ft-label      name=victim "$1" width=14; }
_b_heading()    { ft-heading    name=victim "$1" width=14; }
_b_button()     { ft-button     name=victim "$1" width=14; }
_b_checkbox()   { ft-checkbox   name=victim "$1" width=14; }
_b_radio()      { ft-radio      name=victim "$1" width=14 group=g; }
_b_boxheader()  { ft-boxheader  name=victim text="$1" width=14; }
_b_slider()     { ft-slider     name=victim min=0 max=10 value=5 width=14 text="$1"; }
_sweep "label"      _b_label
_sweep "heading"    _b_heading
_sweep "button"     _b_button
_sweep "checkbox"   _b_checkbox
_sweep "radio"      _b_radio
_sweep "boxheader"  _b_boxheader
_sweep "slider"     _b_slider

note "controls with an accessKey underlined in wide text"
_b_akey() { ft-button name=victim "$1" width=14 accessKey=O; }
_sweep "button+accessKey" _b_akey

note "controls that hold a list"
_b_select() {
    ft-select name=victim size=1 width=14
        ft-option value=a "$1"
        ft-option value=b "Second"
    end_ft_select
}
_b_multi() {
    ft-multitoggle name=victim text="Set" width=14
        ft-option value=a glyph="$1"
        ft-option value=b glyph="Second"
    end_ft_multitoggle
}
_b_tree() {
    ft-tree name=victim rows=3 width=14
        ft-tree-node "$1"   id=a depth=0 expanded=true
        ft-tree-node "Leaf" id=b depth=1
    end_ft_tree
}
_b_tabs() {
    ft-tabs name=victim width=26 height=6
        ft-tab title="$1"
            ft-label name=tb1 text="Body"
        end_ft_tab
        ft-tab title="Two"
            ft-label name=tb2 text="Body"
        end_ft_tab
    end_ft_tabs
}
_sweep "select (closed)" _b_select
_sweep "multitoggle"     _b_multi
_sweep "tree"            _b_tree
_sweep "tabs"            _b_tabs

note "a table's rows all measure the same, whatever alignment the cells use"
# NOT a box-containment check: a table sizes itself to its content and spills out of a
# narrower box — verified identical in ASCII, so it is a separate question from this one and
# not a wide-glyph bug. What IS a wide-glyph bug is a row coming out a different width from
# its neighbours, because then the vertical rules and the right border stop lining up. That
# is exactly what a truncation stopping short of a double-width glyph does.
_t_widths() {                   # name → FT_RET (the distinct painted row widths, sorted)
    local n=$1
    FT_OUT=""; ft_draw_one "$n"
    local -a RUNS; _runs
    local r text seen="" w
    for r in "${RUNS[@]}"; do
        text=${r#* }; text=${text#* }
        ft_display_width "$text"; w=$FT_DISPLAY_WIDTH
        [[ " $seen " == *" $w "* ]] || seen+=" $w"
    done
    FT_RET=${seen# }
}
for align in left center right; do
    for i in "${!TEXTS[@]}"; do
        ft_remove sweepform 2>/dev/null
        ft-form name=sweepform width=60 height=14
            ft-table name=victim variant=grid
                ft-table-header "Key" width=10 align=$align
                ft-table-header "Col" width=12 align=$align
                ft-table-row "${TEXTS[$i]}" "Second"
                ft-table-row "abc"          "${TEXTS[$i]}"
            end_ft_table
        end_ft_form
        ft_layout sweepform; FT_ROOT=sweepform
        _t_widths victim
        check "table/$align — ${LABELS[$i]}: every row one width" \
              "$(( $(set -- $FT_RET; echo $#) == 1 ))" "1"
    done
done

note "text fields, one line and many"
_b_tf()   { ft-textfield name=victim size=10 value="$1" border=true animation=none; }
_b_area() { ft-textfield name=victim size=10 rows=3 wrap=false border=true animation=none value="$1"; }
_b_wrap() { ft-textfield name=victim size=10 rows=3 wrap=true  border=true animation=none value="$1"; }
_sweep "textfield"          _b_tf
_sweep "textarea (nowrap)"  _b_area
_sweep "textarea (wrap)"    _b_wrap

note "…and with the caret walked through the whole value"
# The single hardest case: the field follows the caret, so every caret position is a
# different scroll offset and a different slice. One of them is where the caret vanished.
for i in "${!TEXTS[@]}"; do
    ft_remove sweepform 2>/dev/null
    ft-form name=sweepform width=30 height=14
        ft-textfield name=victim size=10 value="${TEXTS[$i]}" border=true animation=none
    end_ft_form
    ft_layout sweepform; FT_ROOT=sweepform; ft_focus victim; ft_textfield_activate victim
    bad=""
    for (( k=0; k<=${#TEXTS[$i]}; k++ )); do
        FT_TEXTFIELD_CARET[victim]=$k
        _escapes victim; [[ -z "$FT_RET" ]] || bad+="caret=$k: $FT_RET"
    done
    check "caret at every position — ${LABELS[$i]}" "${bad:-inside its box}" "inside its box"
done

note "alignment centres and right-justifies by columns"
# ft_fit_align is the shared primitive: a control that centres a wide-glyph label with it
# must get a row exactly as wide as it asked for, or the padding is wrong on one side.
for t in "${TEXTS[@]}"; do
    for a in left center right; do
        ft_fit_align "$t" 20 "$a"
        ft_display_width "$FT_FIT"
        (( FT_DISPLAY_WIDTH == 20 )) || bad2+="$a/${t:0:4}:$FT_DISPLAY_WIDTH "
    done
done
check "every alignment of every string is exactly 20 columns" "${bad2:-clean}" "clean"

note "word wrap never hands back a line wider than the box"
bad3=""
for t in "${TEXTS[@]}" "設定 オプション 設定 オプション" "a設b定c"; do
    for w in 3 4 7 12; do
        ft_wrap "$t" "$w"
        for l in "${FT_WRAP_LINES[@]}"; do
            ft_display_width "$l"
            (( FT_DISPLAY_WIDTH > w )) && bad3+="w=$w:'${l:0:6}'=$FT_DISPLAY_WIDTH "
        done
    done
done
check "no wrapped line overflows its width" "${bad3:-clean}" "clean"

note "a markdown table's rules line up under the ones above them"
# The headline feature of the markdown renderer. Its column widths came from character
# counts while its cells painted columns, so a table of Japanese cells came apart: the
# border was built to one width and the row below it to another, and no vertical rule met
# the ┬ above it. The check is the invariant a table has to satisfy to look like a table —
# every box-drawing glyph on every row sits in the same column as the one above.
_rulecols() {                   # line → FT_RET (the columns its rules sit at)
    local s=$1 i=0 n=${#1} ch col=0 out=""
    while (( i < n )); do
        ch=${s:i:1}; (( i++ ))
        if [[ "$ch" == $'\e' ]]; then                    # skip an SGR run, it has no width
            while (( i < n )) && [[ "${s:i:1}" != [@-~] ]]; do (( i++ )); done
            (( i++ )); continue
        fi
        case "$ch" in
            '│'|'┌'|'┬'|'┐'|'├'|'┼'|'┤'|'└'|'┴'|'┘') out+="$col " ;;
        esac
        ft_char_cols "$ch"; (( col += FT_CW ))
    done
    FT_RET=${out% }
}
_md_rules_align() {             # src width → FT_RET ("" when every row agrees)
    ft_markdown "$1" "$2"
    local l first="" bad="" seen=0
    for l in "${FT_MARKDOWN_LINES[@]}"; do
        _rulecols "$l"
        [[ -z "$FT_RET" ]] && continue                   # not a table row
        if (( seen == 0 )); then first=$FT_RET; seen=1
        elif [[ "$FT_RET" != "$first" ]]; then bad+="[$FT_RET vs $first] "; fi
    done
    (( seen )) || bad="no table rows rendered"
    FT_RET=$bad
}
_md_ascii='| Key | Action |
| --- | ------ |
| Ctrl+A | Move to start |
| Ctrl+E | End of line |'
_md_cjk='| 設定 | 動作 |
| --- | ------ |
| 制御A | 行頭へ移動 |
| 制御E | 行末へ移動 |'
_md_mixed='| Key | 動作 |
| :-: | -----: |
| Ctrl+A | 行頭へ移動 |
| 制御E | End of line |'
_md_wide='| 設定 | 動作 |
| --- | ------ |
| 制御 | 設定オプション設定オプション設定オプション設定オプション |'
for w in 20 30 40 60; do
    _md_rules_align "$_md_ascii" "$w"; check "markdown table/ascii at $w"  "${FT_RET:-aligned}" "aligned"
    _md_rules_align "$_md_cjk"   "$w"; check "markdown table/japanese at $w" "${FT_RET:-aligned}" "aligned"
    _md_rules_align "$_md_mixed" "$w"; check "markdown table/mixed+align at $w" "${FT_RET:-aligned}" "aligned"
    _md_rules_align "$_md_wide"  "$w"; check "markdown table/truncated wide at $w" "${FT_RET:-aligned}" "aligned"
done

note "NOTHING wrote to stderr through any of it"
err=$( { for t in "${TEXTS[@]}"; do
             ft_remove sweepform 2>/dev/null
             ft-form name=sweepform width=30 height=14
                 ft-label name=victim "$t" width=14
             end_ft_form
             ft_layout sweepform; FT_ROOT=sweepform; FT_OUT=""; ft_draw_one victim
         done; } 2>&1 >/dev/null )
check "clean" "${err:-clean}" "clean"

summary
