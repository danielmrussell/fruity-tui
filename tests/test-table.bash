#!/usr/bin/env bash
# Unit tests for controls/ft-table.bash — the data table with ft-table-header headers
# and ft-table-row cells. Covers: children attach, per-column auto/fixed width, cell
# storage, prefw/height per style, and that a render emits the header, every
# cell, and the right structural glyphs (box grid vs borderless rules).
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=100; FT_ROWS=40

# Strip ANSI (CSI + our resets) from a string → plain text, for content checks.
_plain() { local s=$1; s=$(printf '%s' "$s" | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g'); printf '%s' "$s"; }

note "children attach to the table via the nesting DSL"
ft-form name=app width=100 height=40
ft-table name=t variant=grid
    ft-table-header text="Key" width=16
    ft-table-header text="Action"
    ft-table-header text="Note" align=center
    ft-table-row "Ctrl+A"          "Move to start"        "home"
    ft-table-row "Ctrl+E / End"    "Move to end of line"  "end"
    ft-table-row "Ctrl+W"          "Delete word before"   "word"
end_ft_table
end_ft_form

_ft_table_cols t; check "3 columns attached" "${#FT_TABLE_COLUMNS[@]}" "3"
_ft_table_rows t; check "3 rows attached"    "${#FT_TABLE_ROWS[@]}" "3"

note "cells are stored per row, in column order"
declare -n _r0="_fti_${FT_TABLE_ROWS[0]}__cells"
check "row 0 has 3 cells"       "${#_r0[@]}" "3"
check "row 0 cell 1 is content" "${_r0[1]}"  "Move to start"

note "column widths: fixed honoured, auto = widest of header vs cells"
declare -n CW="_fti_t__colw"
check "col 0 fixed width honoured"        "${CW[0]}" "16"
check "col 1 auto = 'Move to end of line' (19)" "${CW[1]}" "19"   # longest cell
check "col 2 auto = 'Note' header (4)"    "${CW[2]}" "4"          # header beats cells

note "prefw: box style = sum + 3*ncol + 1 (2 pad/cell + ncol+1 verticals)"
_ft_preferred_width_table t
check "grid prefw = 16+19+4 + 3*3 + 1 = 49" "$FT_RET" "49"

note "height per style (3 data rows)"
_ft_setprop t variant grid;    _ft_height_table t; check "grid   height = 2*3+3 = 9" "$FT_RET" "9"
_ft_setprop t variant lines;   _ft_height_table t; check "lines  height = 2*3+1 = 7" "$FT_RET" "7"
_ft_setprop t variant minimal; _ft_height_table t; check "minimal height = 3+2 = 5" "$FT_RET" "5"
_ft_setprop t variant grid

note "render (grid): header, every cell, and box glyphs present"
ft_layout app
FT_OUT=""; _ft_redraw_walk app
plain=$(_plain "$FT_OUT")
for want in "Key" "Action" "Note" "Ctrl+A" "Move to end of line" "word"; do
    case "$plain" in *"$want"*) check "grid render contains '$want'" 1 1 ;; *) check "grid render contains '$want'" 0 1 ;; esac
done
case "$plain" in *"┌"*) check "grid draws a top-left corner ┌" 1 1 ;; *) check "grid draws a top-left corner ┌" 0 1 ;; esac
case "$plain" in *"┼"*) check "grid draws a cross junction ┼" 1 1 ;; *) check "grid draws a cross junction ┼" 0 1 ;; esac

note "render (minimal): no box glyphs, but a header rule and all cells"
ft_empty app
ft-table name=t2 variant=minimal
    ft-table-header text="A"; ft-table-header text="B"
    ft-table-row "one" "two"
    ft-table-row "three" "four"
end_ft_table
end_ft_form
ft_layout app
FT_OUT=""; _ft_redraw_walk app
plain=$(_plain "$FT_OUT")
case "$plain" in *"┌"*|*"│"*) check "minimal draws NO box glyphs" 0 1 ;; *) check "minimal draws NO box glyphs" 1 1 ;; esac
case "$plain" in *"─"*) check "minimal draws a header rule ─" 1 1 ;; *) check "minimal draws a header rule ─" 0 1 ;; esac
for want in "one" "two" "three" "four"; do
    case "$plain" in *"$want"*) check "minimal render contains '$want'" 1 1 ;; *) check "minimal render contains '$want'" 0 1 ;; esac
done

note "rows=N caps the body and makes the table scroll (header pinned)"
ft_empty app
ft-table name=ts variant=minimal rows=4
    ft-table-header text="N"; ft-table-header text="V"
    for _i in 1 2 3 4 5 6 7 8; do ft-table-row "r$_i" "v$_i"; done
end_ft_table
end_ft_form
_ft_table_metrics ts
check "8 rows, capped to 4 → scrolls"    "$TBL_SCROLL" "1"
check "visible rows = cap (4)"           "$TBL_VIS" "4"
check "max scroll = 8-4 = 4"             "$TBL_MAXSCROLL" "4"
_ft_height_table ts; check "scroll height = 2 pinned + 4 body" "$FT_RET" "6"
_ft_table_gridw ts; gw=$FT_RET
_ft_preferred_width_table ts; check "prefw reserves +1 gutter column when scrolling" "$FT_RET" "$(( gw + 1 ))"
no "a scrolling table is focusable (not skipped)" _ft_table_focus_skip ts

note "the arrows move the CURRENT ROW; the viewport follows it"
# They used to pan the window and nothing was ever "the row you are on", so a table could
# not say which row you meant and copying one was impossible. Now there is a cursor, the
# arrows move it, and scrolling happens only as far as it takes to keep it in view.
ft_table_key_home ts
ft_table_key_down ts; ft_resolved_prop ts cursor 0
check "Down → row 1"                       "$FT_RET" "1"
ft_resolved_prop ts scrollTop 0
check "…and the view has not moved (still visible)" "$FT_RET" "0"
ft_table_key_end ts;  ft_resolved_prop ts cursor 0
check "End → the last row (7 of 8)"        "$FT_RET" "7"
ft_resolved_prop ts scrollTop 0
check "…and the view followed to show it"  "$FT_RET" "4"
ft_table_key_down ts; ft_resolved_prop ts cursor 0
check "Down clamps at the last row"        "$FT_RET" "7"
ft_table_key_home ts; ft_resolved_prop ts cursor 0
check "Home → row 0"                       "$FT_RET" "0"
ft_resolved_prop ts scrollTop 0
check "…and the view came back with it"    "$FT_RET" "0"
ft_table_key_pgdn ts; ft_resolved_prop ts cursor 0
check "PgDn → +visible rows (4)"           "$FT_RET" "4"

note "render (scrolled): only the visible window of rows, plus a gutter"
ft_layout app
_ft_setprop ts scrollTop 5   # would clamp to 4 in draw
FT_OUT=""; _ft_redraw_walk app
plain=$(_plain "$FT_OUT")
case "$plain" in *"r5"*) check "scrolled to bottom shows r5" 1 1 ;; *) check "scrolled to bottom shows r5" 0 1 ;; esac
case "$plain" in *"r8"*) check "scrolled to bottom shows r8" 1 1 ;; *) check "scrolled to bottom shows r8" 0 1 ;; esac
case "$plain" in *"r1 "*) check "row r1 scrolled out of view" 0 1 ;; *) check "row r1 scrolled out of view" 1 1 ;; esac
case "$plain" in *"│"*) check "gutter glyph │ present" 1 1 ;; *) check "gutter glyph │ present" 0 1 ;; esac

note "border properties work independently of the style shorthand"
_render() { ft_layout app; FT_OUT=""; _ft_redraw_walk app; _plain "$FT_OUT"; }
ft_empty app
ft-table name=tb borderStyle=double
    ft-table-header text="A"; ft-table-header text="B"
    ft-table-row one two
    ft-table-row three four
end_ft_table
end_ft_form
pd=$(_render)
case "$pd" in *"╔"*) check "borderStyle=double draws ╔" 1 1 ;; *) check "borderStyle=double draws ╔" 0 1 ;; esac
case "$pd" in *"╬"*) check "double draws a ╬ junction" 1 1 ;; *) check "double draws a ╬ junction" 0 1 ;; esac

ft_empty app
ft-table name=tc borderStyle=solid rowLines=false
    ft-table-header text="A"; ft-table-header text="B"
    ft-table-row one two
    ft-table-row three four
end_ft_table
end_ft_form
pd=$(_render)
case "$pd" in *"┌"*) check "solid box still drawn with rowLines=false" 1 1 ;; *) check "solid box still drawn" 0 1 ;; esac
_ft_table_style tc
check "borderStyle overrides: TBL_BOX=1" "$TBL_BOX" "1"
check "rowLines=false honoured: TBL_RL=0" "$TBL_RL" "0"
# rowLines=false ⇒ shorter than the same table with rowLines=true (no inter-row rules)
_ft_height_table tc; h_off=$FT_RET
_ft_setprop tc rowLines true; _ft_height_table tc; h_on=$FT_RET
check "rowLines=false is shorter than rowLines=true" "$(( h_off < h_on ))" "1"

note "orientation=column: ft-table-column data is transposed into rows"
ft_empty app
ft-table name=tco orientation=column variant=grid
    ft-table-header text="Key"; ft-table-header text="Action"
    ft-table-column "Ctrl+A" "Ctrl+E" "Ctrl+W"       # column 0 = the keys
    ft-table-column "start"  "end"    "delete word"  # column 1 = the actions
end_ft_table
end_ft_form
_ft_table_rows tco
check "orientation detected as column"    "$FT_TABLE_ORIENTATION" "column"
check "row count = longest column (3)"    "$FT_TABLE_ROW_COUNT"     "3"
_ft_table_cell 0 0; check "cell(0,0) = Ctrl+A"       "$FT_RET" "Ctrl+A"
_ft_table_cell 0 1; check "cell(0,1) = start"        "$FT_RET" "start"
_ft_table_cell 2 1; check "cell(2,1) = delete word"  "$FT_RET" "delete word"
pd=$(_render)
for want in "Key" "Action" "Ctrl+W" "delete word"; do
    case "$pd" in *"$want"*) check "column-table render contains '$want'" 1 1 ;; *) check "column-table render contains '$want'" 0 1 ;; esac
done
note "the non-matching data element is ignored (row elements in a column table)"
ft_empty app
ft-table name=tmix orientation=column
    ft-table-header text="A"
    ft-table-column "x" "y"
    ft-table-row "IGNORED_ROW"          # wrong element for orientation=column
end_ft_table
end_ft_form
_ft_table_rows tmix
check "column table ignores ft-table-row (2 rows from the column)" "$FT_TABLE_ROW_COUNT" "2"

note "ft_remove tears down the row cell arrays"
r0="${FT_TABLE_ROWS[0]:-none}"
ft_empty app
_ft_table_rows t2   # t2 destroyed by ft_empty; expect zero rows now
check "destroyed table has no row children" "${#FT_TABLE_ROWS[@]}" "0"

# ─────────────────────────────────────────────────────────────────────────────
note "width= is the width the table paints — in BOTH directions"
# It used to be neither. The column widths are measured from the CONTENT, and the draw used
# them whatever box it had been given: a table declared width=26 with 37 columns of content
# painted 37, straight over the control beside it. A table is display:inline-block —
# shrink-to-fit — so with no width= of its own it is as wide as its content and the box is
# irrelevant; an explicit width= is the author overriding that, and is now honoured whether
# the content is narrower or wider than it. (Nothing to do with wide glyphs: ASCII and CJK
# overflowed identically. Both are checked because they take different paths through the
# measuring.)
_tw_runs() {                    # name → FT_RET = the widest painted run, in COLUMNS
    local n=$1 widest=0 seg
    FT_OUT=""; ft_draw_one "$n"
    while IFS= read -r seg; do
        [[ -n "$seg" ]] || continue
        ft_display_width "${seg#* }"
        (( FT_DISPLAY_WIDTH > widest )) && widest=$FT_DISPLAY_WIDTH
    done < <(printf '%s' "$FT_OUT" | sed -e $'s/\x1b\\[\\([0-9]*\\);\\([0-9]*\\)H/\\n\\1 /g' | sed -n '2,$p')
    FT_RET=$widest
}
_tw_build() {                   # formname tablename widthargs… ‹then cells via $CELLS›
    local fn=$1 tn=$2; shift 2
    ft_remove "$fn" 2>/dev/null
    ft-form name="$fn" width=90 height=20
    ft-table name="$tn" variant=grid "$@"
        ft-table-header text="Key" width=10
        ft-table-header text="Action"
        ft-table-row "$C1" "$C2"
        ft-table-row "BB"  "End"
    end_ft_table
    end_ft_form
    ft_layout "$fn"; FT_ROOT=$fn
}
for pair in "ascii:AAAAAAAAAAAAAAAAAAAA:Move to the start of the line" \
            "japanese:設定オプション設定オプション:行頭へ移動します"; do
    lbl=${pair%%:*}; rest=${pair#*:}; C1=${rest%%:*}; C2=${rest#*:}
    for w in 40 26 20 16; do
        _tw_build wf wt width=$w
        _tw_runs wt
        check "$lbl width=$w — nothing painted past it" "$(( FT_RET <= w ))" "1"
        check "$lbl width=$w — and the grid fills it"   "$FT_RET" "$w"
    done
    # Wider than the content: the table grows into it rather than leaving a ragged edge.
    _tw_build wf wt width=70
    _tw_runs wt
    check "$lbl width=70 (wider than the content) fills the box" "$FT_RET" "70"
done

note "…while a table with NO width= keeps its natural size"
C1="Ctrl+A"; C2="Move to start"
_tw_build nf nt
_ft_table_gridw nt; natural=$FT_RET
_tw_runs nt
check "an auto-sized table is exactly its content width" "$FT_RET" "$natural"
check "…which is narrower than the form it sits in"      "$(( natural < 90 ))" "1"

note "shrinking takes from the AUTO columns before an author's fixed one"
C1="AAAAAAAAAAAAAAAAAAAA"; C2="Move to the start of the line"
_tw_build sf st width=40
_ft_table_fit st 40 1
declare -n _fit=$FT_TABLE_FITTED
check "the fixed column kept the width it was given" "${_fit[0]}" "10"
check "…and the auto column absorbed the shrink"     "$(( _fit[1] < 29 ))" "1"
unset -n _fit
# Only when the auto columns have nothing left does a fixed one give way — better than
# overflowing the box, which is what it used to do instead.
_tw_build sf2 st2 width=16
_ft_table_fit st2 16 1
declare -n _fit2=$FT_TABLE_FITTED
check "squeezed hard, even the fixed column yields" "$(( _fit2[0] < 10 ))" "1"
unset -n _fit2
_tw_runs st2
check "…and the row is still exactly the box" "$FT_RET" "16"

note "a box too small for any grid still cannot paint outside itself"
# Two columns and their rules need nine cells; asked for eight there is nowhere left to
# give, so the row is clipped rather than allowed to reach the neighbouring control.
for w in 9 8 5 3; do
    _tw_build df dt width=$w
    _tw_runs dt
    check "width=$w — clipped, never over" "$(( FT_RET <= w ))" "1"
done

note "a SCROLLING table leaves its gutter column alone"
C1="AAAAAAAAAAAAAAAAAAAA"; C2="Move to the start of the line"
ft_remove gf 2>/dev/null
ft-form name=gf width=90 height=20
ft-table name=gt variant=grid width=30 rows=2
    ft-table-header text="Key" width=10
    ft-table-header text="Action"
    ft-table-row "$C1" "$C2"
    ft-table-row "BB"  "End"
    ft-table-row "CC"  "More"
end_ft_table
end_ft_form
ft_layout gf; FT_ROOT=gf
_ft_table_metrics gt
check "it really is scrolling" "$TBL_SCROLL" "1"
_tw_runs gt
check "the grid stops one short, leaving the scrollbar its column" "$FT_RET" "29"

note "the fitted widths are cached, and the cache notices the box changing"
_tw_build cf ct width=40
_ft_table_fit ct 40 1; declare -n _c1=$FT_TABLE_FITTED; first="${_c1[*]}"; unset -n _c1
_ft_table_fit ct 26 1; declare -n _c2=$FT_TABLE_FITTED; second="${_c2[*]}"; unset -n _c2
check "a different width gives different columns" "$(( "${first// /+}" > "${second// /+}" ))" "1"
_ft_table_fit ct 40 1; declare -n _c3=$FT_TABLE_FITTED
check "and going back gives the first answer again" "${_c3[*]}" "$first"
unset -n _c3

# ── Column alignment is CSS's textAlign; `align` is the documented alias ─────
# The table used to read an invented `align` and nothing else, so a header written the way
# every other control in the tree is written — textAlign=right — was ACCEPTED and silently
# ignored, and a form-level textAlign that labels and buttons obeyed stopped at the table's
# edge. These assert on the painted grid, because "the property resolves" was never the
# question; the question is whether the column moved.
note "column alignment: textAlign is the property, align the alias"
_al_render() {                  # → FT_RET = where "hi" sits in its 16-wide column
    ft_layout alapp; FT_OUT=""; _ft_redraw_walk alapp
    local p; p=$(_plain "$FT_OUT")
    case "$p" in
        *"              hi"*) FT_RET=right ;;         # 14 spaces, then the value
        *"       hi       "*) FT_RET=center ;;        # 7 and 7
        *"hi              "*) FT_RET=left ;;
        *)                    FT_RET=none ;;
    esac
}
_al_build() {                   # header-props… — one 16-wide column holding "hi"
    ft_remove alapp 2>/dev/null
    ft-form name=alapp width=40 height=10
    ft-table name=alt variant=grid
        ft-table-header text="Note" width=16 "$@"
        ft-table-row "hi"
    end_ft_table
    end_ft_form
}
_al_build;                 _al_render; check "nothing said → left"          "$FT_RET" left
_al_build textAlign=right; _al_render; check "textAlign=right right-aligns" "$FT_RET" right
_al_build textAlign=center;_al_render; check "textAlign=center centres"     "$FT_RET" center
_al_build align=right;     _al_render; check "align=right still works (alias)" "$FT_RET" right

# INHERITANCE IS THE HALF AN INVENTED PROPERTY CAN NEVER HAVE. textAlign is an inherited
# property, so a form that sets it once styles everything inside — and now that includes the
# table's columns, which is what the old `align` could not do at any spelling.
ft_remove alapp 2>/dev/null
ft-form name=alapp width=40 height=10 textAlign=right
ft-table name=alt variant=grid
    ft-table-header text="Note" width=16
    ft-table-row "hi"
end_ft_table
end_ft_form
_al_render; check "a form-level textAlign reaches the columns" "$FT_RET" right

# …and the deviation, written down where it is enforced: an `align` named ON THE COLUMN is the
# author being specific about this column, so it outranks an inherited textAlign.
ft_remove alapp 2>/dev/null
ft-form name=alapp width=40 height=10 textAlign=right
ft-table name=alt variant=grid
    ft-table-header text="Note" width=16 align=left
    ft-table-row "hi"
end_ft_table
end_ft_form
_al_render; check "an align on the column beats an inherited textAlign" "$FT_RET" left
ft_remove alapp 2>/dev/null

note "nothing wrote to stderr while any of that was drawn"
err=$( { for w in 3 8 16 26 40 70; do _tw_build ef et width=$w; FT_OUT=""; ft_draw_one et; done; } 2>&1 >/dev/null )
check "clean" "${err:-clean}" "clean"

summary
