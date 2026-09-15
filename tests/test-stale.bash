#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Stale-cache hunt: WARM must equal COLD, on the screen.
#
#  The framework caches aggressively — wrapped lines, text extents, resolved styles, SGR
#  strings, a whole rendered border ring. Every one of those is keyed by a signature, and a
#  signature that forgets one of its inputs produces a frame that is silently WRONG while every
#  unit test still passes. That has now shipped once: the border sheen cached its ring without
#  the scrollbar thumb's position in the key, so an overflowing textarea painted its thumb and
#  then had the stale ring blitted straight over it — no scrollbar on screen, ever, and a green
#  suite throughout (every scrollbar test read a DIRECT draw, which was correct).
#
#  So this suite does not check any particular pixel. For each scene it:
#     1. drives the app (typing, scrolling, selecting, restyling) with caches warm,
#     2. paints a frame                                        → WARM,
#     3. throws EVERY cache away and paints the same state again → COLD,
#     4. requires the two frames to be identical CELL BY CELL, glyph and attributes.
#  Any difference is a cache that failed to notice something it depends on.
#
#  Colours matter here, so the comparison goes through tools/screen-cells.py rather than the
#  text-only renderer: "same glyph, wrong colour" is precisely what a stale style cache does.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_ROWS=30; FT_COLS=100
# RENDER IN THE MODE A PERSON ACTUALLY SEES. Headless, FT_USE_UTF8 comes out 0, and in ASCII
# the scrollbar thumb degrades from ▊ to '|' — the same glyph as the border it sits on. The
# sheen bug is then invisible to a cell comparison, because the only thing that differs is a
# glyph that is identical in that mode. A gate that quietly runs in a different rendering mode
# from the product is a gate that cannot see a whole class of bug.
FT_USE_UTF8=1
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# ── THE LIST ABOVE IS HAND-MAINTAINED, SO IT IS CHECKED ──────────────────────
# A cache this file does not drop is a cache this file CANNOT SEE: the "cold" frame gets
# resolved out of the very table under test, and warm==cold means nothing. That is not
# hypothetical — an inheritance memo added on a branch had its invalidation deliberately broken
# at all five of its routes and this file still scored 63/63, because `go_cold` had never heard
# of it. Every entry above was correct on the day it was written; the failure mode is the NEXT
# cache, and no reviewer reliably remembers this file exists.
#
# So the gate detects its own blind spot: enumerate the associative arrays whose names say they
# are caches, and require each one to appear in `go_cold`'s body. Adding `_FT_FOO_C` without
# listing it now fails HERE, with the name, instead of silently hollowing out the file.
#
# Read from `declare -f`, not from the file, so re-indenting or moving the function cannot make
# the check pass by accident.
note "the cold pass can see every cache there is"
_cold_body=$(declare -f go_cold)
_cache_names=()
while read -r _nm; do
    case "$_nm" in
        # RETAINED* joined this list when the retained display list landed: it is a cache by
        # every test that matters and by none of the names above, which is the blind spot this
        # enumeration exists to close — so the pattern grows with the framework, deliberately.
        *_C|*_CACHE|*CACHE*|*_MEMO|*MEMO*|*FROZEN*|*COERCED*|*RETAINED*) _cache_names+=("$_nm") ;;
    esac
done < <(declare -A -p 2>/dev/null | sed -n 's/^declare -A \([A-Za-z_][A-Za-z0-9_]*\).*/\1/p')
# ANTI-VACUITY: if the enumeration finds nothing, every assertion below passes for free. Nine
# cache-shaped arrays exist as this is written; demand a plausible floor rather than a number
# that has to be edited each time one is added.
check "the enumeration found the framework's caches" "$(( ${#_cache_names[@]} >= 8 ))" "1"
_unseen=""
for _nm in "${_cache_names[@]}"; do
    [[ "$_cold_body" == *"$_nm"* ]] || _unseen+=" $_nm"
done
check "…and go_cold drops every one of them" "$_unseen" ""
[[ -n "$_unseen" ]] && echo "         ↑ add these to go_cold (tests/_harness.bash), or the warm-vs-cold comparison is
         resolving the cold frame out of the table it is meant to be testing."
unset _cold_body _cache_names _unseen _nm

# Paint a whole frame and LEAVE IT IN FT_OUT. Deliberately not ft_redraw_all: that ends in
# ft_flush, which writes the frame to the tty and empties FT_OUT — so a harness built on it
# compares two empty strings and passes everything. (It did. That is why the teeth section at
# the foot of this file exists, and why every comparator here refuses an EMPTY frame.)
_paint() { FT_OUT=""; _ft_redraw_walk "$1"; _ft_composite_overlays; }

_cells() {                      # file → the frame as comparable cells
    python3 "$here/tools/screen-cells.py" "$1" "$FT_ROWS" "$FT_COLS"
}
_paint_cells() {                # root → PAINTED_CELLS (this frame, as comparable cells)
    _paint "$1"; printf '%s' "$FT_OUT" > "$tmp/frame"
    PAINTED_CELLS=$(_cells "$tmp/frame")
}
# AN EMPTY FRAME IS A BROKEN SCENE, NOT A PASSING ONE. screen-cells.py emits one line per
# NON-BLANK cell, so a frame that painted nothing at all renders as zero bytes — and every
# comparison in this file is then a comparison of two empty strings, which agree. Measured: with
# _paint neutered so no scene ever rendered, 50 of 55 assertions here stayed green, every
# warm/cold and every bare-cell verdict among them. So each comparator asks first whether there
# is a frame to compare, and says so in the verdict rather than passing on the absence.
_no_frame() {                   # desc — report a scene that rendered nothing
    check "$1" "the scene painted NOTHING" "a rendered frame"
}
# NO CELL MAY FALL THROUGH TO THE TERMINAL'S BACKGROUND. A write that sets only a foreground
# leaves the background at whatever is current — and every write ends in a reset, so that is
# the terminal's colour, not the theme's. The app then has a hole in it: black residue on a
# light theme, invisible on a dark one, different from cell to cell. That shipped, in the one
# theme role (`.view`, the read-only well) that had no background-color.
_bare_count() {                 # cells → how many carry no background of their own
    printf '%s\n' "$1" | grep -c 'bg=- ' || true
}
no_bare_cells() {               # desc root
    local desc=$1 root=$2 bare
    desc+=" — every painted cell carries a background"
    _paint_cells "$root"
    [[ -z "$PAINTED_CELLS" ]] && { _no_frame "$desc"; return; }
    bare=$(_bare_count "$PAINTED_CELLS")
    check "$desc" "$bare" "0"
    (( bare )) && printf '%s\n' "$PAINTED_CELLS" | grep 'bg=- ' | head -4 | sed 's/^/         /'
    return 0
}

# Paint ROOT warm, then throw the caches away and paint it again. Identical or bust.
# → WARM_COLD_VERDICT = blank | same | differ, and the two cell grids, so the teeth section at
#   the foot of this file can demand a verdict of `differ` from a deliberately poisoned cache.
_warm_vs_cold() {               # root
    _paint "$1"; printf '%s' "$FT_OUT" > "$tmp/warm"
    WARM_CELLS=$(_cells "$tmp/warm")
    if [[ -z "$WARM_CELLS" ]]; then WARM_COLD_VERDICT=blank; COLD_CELLS=""; return; fi
    # COLD = the same state with every derived value thrown away. Deliberately WITHOUT a
    # re-layout: laying out again perturbs the very state under test (it re-clamps a label's
    # scrollTop, for one), so the comparison would be against a different app, not a colder one.
    go_cold
    _paint "$1"; printf '%s' "$FT_OUT" > "$tmp/cold"
    COLD_CELLS=$(_cells "$tmp/cold")
    if [[ "$WARM_CELLS" == "$COLD_CELLS" ]]; then WARM_COLD_VERDICT=same
    else WARM_COLD_VERDICT=differ; fi
}
warm_equals_cold() {            # desc root
    local desc=$1
    _warm_vs_cold "$2"
    case $WARM_COLD_VERDICT in
        blank) _no_frame "$desc" ;;
        same)  check "$desc" 1 1 ;;
        *)     check "$desc" 0 1
               printf '       %sfirst differences (warm vs cold):%s\n' "${_H_DIM}" "${_H_RESET}"
               diff <(printf '%s\n' "$WARM_CELLS") <(printf '%s\n' "$COLD_CELLS") \
                   | head -8 | sed 's/^/         /' ;;
    esac
    return 0
}

note "a textarea that grows a scrollbar while you type"
# The scene the sheen bug lived in: the field is activated while its content FITS (so the
# border ring is cached without a thumb), and only then grows past the box.
ft-form name=a1 width=60 height=14
    ft-textfield name=t1 size=30 rows=6 wrap=true value="short"
end_ft_form
ft_layout a1; FT_ROOT=a1
ft_focus t1; ft_textfield_activate t1
FT_OUT=""; ft_redraw_all a1                 # prime every cache while it still fits
for w in aaa bbb ccc ddd eee fff ggg hhh; do
    for (( i=0; i<${#w}; i++ )); do ft_textfield_insert_char t1 "${w:i:1}"; done
    ft_textfield_insert_char t1 $'\n'
done
warm_equals_cold "typing until it overflows" a1
ft_textfield_doc_home t1; warm_equals_cold "…then scrolling back to the top" a1
FT_TEXTFIELD_ANCHOR[t1]=2; FT_TEXTFIELD_CARET[t1]=18
warm_equals_cold "…then selecting across lines" a1
ft_textfield_backspace t1
warm_equals_cold "…then deleting the selection" a1

note "a single-line field that outgrows its box (the horizontal bar)"
ft-form name=a2 width=60 height=6
    ft-textfield name=t2 size=16 value="short"
end_ft_form
ft_layout a2; FT_ROOT=a2
ft_focus t2; ft_textfield_activate t2
FT_OUT=""; ft_redraw_all a2
ft_textfield_end t2
for (( i=0; i<40; i++ )); do ft_textfield_insert_char t2 "$(( i % 10 ))"; done
warm_equals_cold "typing past the right edge" a2
ft_textfield_home t2; warm_equals_cold "…then Home (the view scrolls back)" a2

note "a growing log (the label line store + wrap cache)"
ft-form name=a3 width=60 height=12
    ft-label name=l3 text="first line" width=30 height=6 overflow=auto
end_ft_form
ft_layout a3; FT_ROOT=a3
FT_OUT=""; ft_redraw_all a3
for (( i=0; i<12; i++ )); do ft_append_data l3 "appended line $i, long enough to wrap around"; done
ft_layout a3
warm_equals_cold "appending lines" a3
ft-modify l3 scrollTop=4; warm_equals_cold "…then scrolling it" a3

note "restyling at runtime (the cascade + SGR caches)"
ft-form name=a4 width=60 height=10
    ft-label name=l4 text="styled" width=20
    ft-textfield name=t4 size=16 value="styled too"
end_ft_form
ft_layout a4; FT_ROOT=a4
FT_OUT=""; ft_redraw_all a4
ft-modify l4 color=201; warm_equals_cold "a colour change on a label" a4
ft-modify t4 backgroundColor=57; warm_equals_cold "a background change on a field" a4
ft_classlist_add l4 loud 2>/dev/null || ft-modify l4 class=loud
warm_equals_cold "a class change" a4
ft-modify t4 disabled=true; warm_equals_cold "disabling a control" a4

note "tabs: switching the active tab"
ft-form name=a5 width=60 height=16
    ft-tabs name=tb5 width=44 height=12
        ft-tab title="One"
            ft-label name=p1 text="page one"
        end_ft_tab
        ft-tab title="Two"
            ft-label name=p2 text="page two"
        end_ft_tab
        ft-tab title="Three"
            ft-label name=p3 text="page three"
        end_ft_tab
    end_ft_tabs
end_ft_form
ft_layout a5; FT_ROOT=a5; FT_FOCUS=tb5
FT_OUT=""; _ft_redraw_walk a5
ft-modify tb5 selectedIndex=1; ft_layout a5
warm_equals_cold "after selecting the second tab" a5
ft-modify tb5 selectedIndex=2; ft_layout a5
warm_equals_cold "…and the third" a5

note "tree: moving the cursor and collapsing a branch"
ft-form name=a6 width=60 height=16
    ft-tree name=tr6 rows=6
        ft-tree-node "src"      key=src  depth=0 expanded=true
        ft-tree-node "core"     key=core depth=1
        ft-tree-node "controls" key=ctl  depth=1 expanded=true
        ft-tree-node "tree"     key=tree depth=2
        ft-tree-node "README"   key=rd   depth=0
    end_ft_tree
end_ft_form
ft_layout a6; FT_ROOT=a6; FT_FOCUS=tr6
FT_OUT=""; _ft_redraw_walk a6
ft_tree_key_down tr6; ft_tree_key_down tr6
warm_equals_cold "after moving the cursor" a6
ft_tree_key_left tr6 2>/dev/null || ft-modify tr6 cursor=2
ft_layout a6
warm_equals_cold "after collapsing a branch" a6

note "table: selecting and scrolling"
ft-form name=a7 width=70 height=16
    ft-table name=tb7 variant=grid rows=4
        ft-table-header "Key" width=16
        ft-table-header "Action"
        ft-table-row "Ctrl+A" "Move to start"
        ft-table-row "Ctrl+E" "Move to end"
        ft-table-row "Ctrl+W" "Delete word"
        ft-table-row "Ctrl+K" "Kill to end"
        ft-table-row "Ctrl+U" "Kill to start"
    end_ft_table
end_ft_form
ft_layout a7; FT_ROOT=a7; FT_FOCUS=tb7
FT_OUT=""; _ft_redraw_walk a7
ft-modify tb7 selectedIndex=3; ft_layout a7
warm_equals_cold "after selecting a row further down" a7

# A table with an explicit width= fits its columns to the box and CACHES that, keyed by the
# box. Resizing it is the move that catches a key which forgot the box — the columns would
# stay the width they were computed at while the border is redrawn to the new one.
ft-form name=a7b width=70 height=16
    ft-table name=tb7b variant=grid width=52
        ft-table-header "Key" width=16
        ft-table-header "Action"
        ft-table-row "Ctrl+A" "Move to the very start of the line"
        ft-table-row "Ctrl+W" "Delete the word before the cursor"
    end_ft_table
end_ft_form
ft_layout a7b; FT_ROOT=a7b; FT_FOCUS=tb7b
FT_OUT=""; _ft_redraw_walk a7b
warm_equals_cold "a table fitted to an explicit width" a7b
ft-modify tb7b width=34; ft_layout a7b
warm_equals_cold "…and after that width changes under it" a7b
ft-modify tb7b width=64; ft_layout a7b
warm_equals_cold "…and after it grows again" a7b

note "select: opening the dropdown and choosing"
ft-form name=a8 width=40 height=14
    ft-select name=s8 size=1
        ft-option value=1 Alpha; ft-option value=2 Beta; ft-option value=3 Gamma
    end_ft_select
end_ft_form
ft_layout a8; FT_ROOT=a8; FT_FOCUS=s8
FT_OUT=""; _ft_redraw_walk a8
ft-modify s8 selectedIndex=2; ft_layout a8
warm_equals_cold "after choosing a different option" a8

note "focus moving between controls"
ft-form name=a9 width=60 height=8
    ft-textfield name=f1 size=12 value="one"
    ft-textfield name=f2 size=12 value="two"
end_ft_form
ft_layout a9; FT_ROOT=a9
ft_focus f1; FT_OUT=""; _ft_redraw_walk a9
ft_focus f2
warm_equals_cold "after focus moves to the other field" a9
ft_focus f1
warm_equals_cold "…and back again" a9

note "structure changing under the caches (add / remove a control)"
ft-form name=aa width=60 height=10
    ft-label name=k1 text="first" width=20
    ft-label name=k2 text="second" width=20
end_ft_form
ft_layout aa; FT_ROOT=aa
FT_OUT=""; _ft_redraw_walk aa
ft-modify k1 text="first, rewritten longer"; ft_layout aa
warm_equals_cold "after rewriting a label's text" aa
ft_remove k2; ft_layout aa
warm_equals_cold "after removing a sibling" aa

note "state the FRAMEWORK renders from, which CSS knows nothing about"
# `disabled` was one of these and was broken: invalidation was decided purely from what the
# stylesheet matches on, but the framework dims/recolours from these properties whether or not
# any rule mentions them. Every one of them therefore has to invalidate on its own account.
ft-form name=ab width=60 height=12
    ft-textfield name=r1 size=16 value="editable"
    ft-label     name=r2 text="a label" width=20
    ft-button    name=r3 Press
end_ft_form
ft_layout ab; FT_ROOT=ab; ft_focus r1
FT_OUT=""; _ft_redraw_walk ab
ft-modify r1 readOnly=true;  warm_equals_cold "a field turned read-only" ab
ft-modify r1 readOnly=false; warm_equals_cold "…and editable again" ab
ft-modify r2 disabled=true;  warm_equals_cold "a label disabled" ab
ft-modify r3 disabled=true;  warm_equals_cold "a button disabled" ab
ft-modify ab disabled=true;  warm_equals_cold "the whole FORM disabled (inherits down)" ab
ft-modify ab disabled=false; warm_equals_cold "…and enabled again" ab

note "no control paints a hole through to the terminal background"
ft-form name=ad width=60 height=16
    ft-textfield name=w1 size=20 rows=4 wrap=true readOnly=true value=$'read-only\nviewer text'
    ft-textfield name=w2 size=20 value="editable"
    ft-label     name=w3 text="a label" width=20
    ft-button    name=w4 Press
end_ft_form
ft_layout ad; FT_ROOT=ad
no_bare_cells "a page of controls" ad
ft_focus w1; ft_textfield_activate w1          # cursor mode on the READ-ONLY viewer: the reported case
ft_layout ad
no_bare_cells "…with a read-only field in cursor mode" ad
ft_focus w2; ft_textfield_activate w2
ft_layout ad
no_bare_cells "…and an editable field in edit mode" ad

note "the ACTIVE LINE: the caret's row lifts a shade, and only that row"
ft-form name=ae width=40 height=12
    ft-textfield name=al size=24 rows=6 wrap=true value=$'first\nsecond\nthird\nfourth'
end_ft_form
ft_layout ae; FT_ROOT=ae
# The well background of one text row inside the field, as a single value.
_wellbg() {                     # screenrow → BGV
    _paint ae; printf '%s' "$FT_OUT" > "$tmp/al"
    BGV=$(_cells "$tmp/al" | awk -F'\t' -v want="$1" '
        # column 5, deliberately clear of the caret cell — that one wears the caret colour,
        # not the line background, and sampling it measures the wrong thing.
        { split($1,p,","); if (p[1]+0 == want && p[2]+0 == 5) { bg=$3; sub(/.*bg=/,"",bg); sub(/ .*/,"",bg); print bg } }' | head -1)
}
_wellbg 2; _idle2=$BGV
_wellbg 3; _idle3=$BGV
check "idle: the two rows share one well colour" "$_idle2" "$_idle3"
ft_focus al; ft_textfield_activate al; FT_TEXTFIELD_CARET[al]=8       # caret on the SECOND line
ft_layout ae
_wellbg 2; _edit2=$BGV
_wellbg 3; _edit3=$BGV
# Engaging the field re-tints the WHOLE well (the :engaged marker), so the outside
# sample is no longer this frame's baseline. The lift is a claim about one row
# relative to its neighbours, so measure it inside the engaged frame: turning the
# highlight off gives the untouched engaged well to compare both rows against.
check "editing: the caret's row lifted"        "$([[ "$_edit2" != "$_edit3" ]] && echo yes)" yes
ft-modify al currentLineHighlight=false; ft_layout ae
_wellbg 2; _plain2=$BGV
_wellbg 3; _plain3=$BGV
check "currentLineHighlight=false turns it off" "$_plain2" "$_plain3"
check "editing: the OTHER row did not"         "$_edit3" "$_plain3"
ft-modify al currentLineHighlight=true

note "DOUBLE-WIDTH text keeps a control inside its box"
# A CJK or emoji character is ONE character and TWO terminal columns. While ft_display_width
# returned the code-point count, every measurement was short and a field's row overflowed by
# one cell per wide glyph — the right border walked away from the box. The check is where the
# border lands: it must not move when the content changes script.
ft-form name=af width=40 height=10
    ft-textfield name=wf size=12 rows=4 wrap=true value="abcdef"
end_ft_form
ft_layout af; FT_ROOT=af
_bordercol() {                  # → BCOL: the column of the field's right border on row 1
    ft-modify wf value="$1"; _paint af; printf '%s' "$FT_OUT" > "$tmp/wide"
    BCOL=$(_cells "$tmp/wide" | awk -F'\t' '$2 == "│" { split($1,p,","); if (p[1]+0 == 1) print p[2]+0 }' | tail -1)
}
_bordercol "abcdef";        _ascii=$BCOL
check "…with plain ASCII the border has a column"  "$([[ -n "$_ascii" ]] && echo yes)" yes
_bordercol "漢字abc";       check "CJK does not move the border"    "$BCOL" "$_ascii"
_bordercol "漢字漢字漢字";  check "a full line of CJK neither"      "$BCOL" "$_ascii"
_bordercol "ab😀cd";        check "an emoji neither"                "$BCOL" "$_ascii"
_bordercol "日本語テキストです"; check "text that must WRAP neither" "$BCOL" "$_ascii"

# An AUTO-SIZED control must measure wide text in columns too, or it reserves half the room it
# needs. This is where a duplicated "fast path" went stale: three places had inlined
# ft_display_width's escape-free shortcut, which kept the one-column-per-glyph assumption after
# that function learned better — so a CJK label asked for 8 columns and drew 16.
ft-label name=wlab text="漢字漢字漢字漢字" parent=af
ft_layout af
check "an auto-sized label measures 8 CJK as 16 columns" "${FT_MEASURED_WIDTH[wlab]}" "16"
ft-modify wlab text="abcdefgh"; ft_layout af
check "…and 8 ASCII as 8"                                "${FT_MEASURED_WIDTH[wlab]}" "8"
ft_remove wlab; ft_layout af

# Wrapping decides how much goes on a row; the draw truncates what will not fit. Measure those
# two differently and the difference is text that silently never appears at all.
for _v in "漢字漢字漢字漢字" "日本語のテキストです" "ab漢cd漢ef漢gh"; do
    ft-modify wf value="$_v"; ft_layout af; _paint af
    printf '%s' "$FT_OUT" > "$tmp/wrap"
    _seen=$(_cells "$tmp/wrap" | awk -F'\t' '{printf "%s", $2}')
    _miss=""
    for (( _i=0; _i<${#_v}; _i++ )); do
        [[ "$_seen" == *"${_v:_i:1}"* ]] || _miss+="${_v:_i:1}"
    done
    check "wrapping '$_v' loses no glyph" "$_miss" ""
done
ft-modify wf value="abcdef"; ft_layout af
ft-modify wf value="abcdef"

note "the ASCII fallback glyphs must not collide with what they are drawn on"
# A scrollbar thumb sits IN the border it scrolls. The ASCII fallback for the vertical thumb
# was '|' — which IS ft-core's ASCII vertical border — so on a non-UTF-8 terminal the
# scrollbar was painted, correctly positioned, and completely invisible. A fallback has to be
# chosen against the glyph it replaces, not in isolation.
_saved_utf8=$FT_USE_UTF8
FT_USE_UTF8=0; _ft_textfield_thumb_glyphs
check "ASCII vertical thumb differs from the vertical rule"   "$([[ "$FT_TEXTFIELD_THUMB_VERTICAL" != "|" ]] && echo yes)" yes
check "ASCII vertical CREST differs from the vertical rule"   "$([[ "$FT_TEXTFIELD_THUMB_VERTICAL_THICK" != "|" ]] && echo yes)" yes
check "ASCII horizontal thumb differs from the horizontal rule" "$([[ "$FT_TEXTFIELD_THUMB_HORIZONTAL" != "-" ]] && echo yes)" yes
check "ASCII horizontal CREST differs from the horizontal rule" "$([[ "$FT_TEXTFIELD_THUMB_HORIZONTAL_THICK" != "-" ]] && echo yes)" yes
check "…and they are 7-bit, so no terminal renders them as accents" \
      "$([[ "$FT_TEXTFIELD_THUMB_VERTICAL$FT_TEXTFIELD_THUMB_VERTICAL_THICK$FT_TEXTFIELD_THUMB_HORIZONTAL$FT_TEXTFIELD_THUMB_HORIZONTAL_THICK" != *[$'\x80'-$'\xff']* ]] && echo yes)" yes
FT_USE_UTF8=1; _ft_textfield_thumb_glyphs
check "UTF-8 vertical thumb is the block, not the rule" "$FT_TEXTFIELD_THUMB_VERTICAL" $'\xe2\x96\x8a'
FT_USE_UTF8=$_saved_utf8

note "a custom property changed at runtime (var() consumers must follow)"
ft-form name=ac width=60 height=8
    ft-label name=v1 text="var-driven" width=20 --accent=201
end_ft_form
ft_layout ac; FT_ROOT=ac
FT_OUT=""; _ft_redraw_walk ac
ft-modify v1 --accent=45; warm_equals_cold "after changing a custom property" ac

# ═══ THE TEETH ═══════════════════════════════════════════════════════════════
note "the gate's own teeth: a poisoned cache must come back RED"
# Everything above is a comparison of two frames, and a comparison is only worth its runtime if
# a WRONG frame actually makes it fail. Nothing above proves that: every scene here has always
# agreed with itself, so the whole file's evidence is negative. (The header has promised a teeth
# check since the initial import and never carried one.) So sabotage the subject on purpose —
# poison a cache by hand, exactly the way a signature that forgot one of its inputs does — and
# require the comparator to return `differ`. Then unpoison and require `same`, or the teeth
# would be proving nothing but that the scene is unstable.
#
# THE THREE SABOTAGES, and what each stands in for:
#   · _FT_SGR_CACHE[<name>] rewritten to a different foreground, token kept  → a style cache
#     that kept an old colour: same glyphs, wrong attributes. The class this whole file exists
#     for, and the one the text-only renderer cannot see.
#   · FT_SHEEN_FROZEN[<name>] with a border glyph swapped, signature kept    → the frozen
#     border ring blitted over what the draw had just painted. THE BUG THAT SHIPPED (see the
#     header); poisoning its cache reproduces its shape byte for byte.
#   · FT_RETAINED_BLOCK[<name>] rewritten, token kept                        → the retained
#     display list serving a control's OLD appearance. The same shape as the two above, one
#     layer further out, and the only one that can put a whole stale control on the screen.
#   · the root hidden, so the frame is empty                                 → the failure mode
#     that made 50 of 55 assertions here vacuous. It must read as "painted NOTHING", not "same".
#
# CHECKED RATHER THAN ASSUMED — three sabotages of this file, one at a time, against the tree
# as it stands (each was watched going red, then restored):
#   RED  _paint renders nothing            20/63, 43 FAIL   (before this work: 50/55, 5 FAIL)
#   RED  the comparator always says "same" 61/63, 2 FAIL    — both teeth verdicts, nothing else
#   RED  the two poisons above removed     61/63, 2 FAIL    — the teeth measure the POISON, not
#                                                             a scene that happens to be unstable
ft-form name=ag width=60 height=10
    ft-label     name=g1 text="teeth" width=20
    ft-textfield name=g2 size=16 value="teeth too"
end_ft_form
ft_layout ag; FT_ROOT=ag
FT_OUT=""; _ft_redraw_walk ag                # prime the caches, then reach in and break one
_warm_vs_cold ag
check "the teeth scene agrees with itself to begin with" "$WARM_COLD_VERDICT" "same"

FT_OUT=""; _ft_redraw_walk ag                # re-warm: _warm_vs_cold left the caches cold
_teeth_token=${_FT_SGR_CACHE[g1]%%$'\x1f'*}  # keep the key, replace the answer
_FT_SGR_CACHE[g1]="$_teeth_token"$'\x1f'$'\e[38;5;93m'
# THE RETAINED BLOCK SITS IN FRONT OF EVERY CACHE BELOW IT, so poisoning an inner one and
# painting proves nothing while the outer one hits: the warm frame is g1's stored bytes and no
# style is resolved at all. That is not a hole in the gate — a valid retained block means the
# inner answer was never consulted, and go_cold drops the blocks, so a block whose own token
# is wrong still shows up as warm != cold (and has its own teeth, below). It IS a hole in this
# sabotage, so make the poisoned control derive.
unset "FT_RETAINED_TOKEN[g1]" "FT_RETAINED_BLOCK[g1]"
_warm_vs_cold ag
check "a style cache holding the wrong colour is caught" "$WARM_COLD_VERDICT" "differ"

# …and the retained block itself, which is now the outermost cache in the framework: keep the
# token, change the bytes. This is the same sabotage one layer up — "the signature says this is
# still valid and it is not" — and it is the only one that can put a whole control's stale
# appearance on the screen.
FT_OUT=""; _ft_redraw_walk ag
check "…and there IS a retained block to poison" \
      "$([[ -n "${FT_RETAINED_BLOCK[g1]:-}" ]] && echo yes)" yes
FT_RETAINED_BLOCK[g1]=${FT_RETAINED_BLOCK[g1]//teeth/TEETH}
_warm_vs_cold ag
check "a retained block holding stale bytes is caught" "$WARM_COLD_VERDICT" "differ"

# The sheen ring: activate a field and let it overflow, which is the scene the shipped bug
# lived in, then corrupt the cached ring the next draw will blit.
ft-form name=ah width=60 height=14
    ft-textfield name=h1 size=30 rows=6 wrap=true value="short"
end_ft_form
ft_layout ah; FT_ROOT=ah
ft_focus h1; ft_textfield_activate h1
FT_OUT=""; ft_redraw_all ah
for w in aaa bbb ccc ddd eee fff ggg hhh; do
    for (( i=0; i<${#w}; i++ )); do ft_textfield_insert_char h1 "${w:i:1}"; done
    ft_textfield_insert_char h1 $'\n'
done
FT_OUT=""; _ft_redraw_walk ah
check "…and there IS a frozen ring to poison" \
      "$([[ -n "${FT_SHEEN_FROZEN[h1]:-}" ]] && echo yes)" yes
FT_SHEEN_FROZEN[h1]=${FT_SHEEN_FROZEN[h1]//│/!}
unset "FT_RETAINED_TOKEN[h1]" "FT_RETAINED_BLOCK[h1]"   # …and make it derive — see g1 above
_warm_vs_cold ah
check "a frozen border ring holding the wrong glyph is caught" "$WARM_COLD_VERDICT" "differ"

# An empty frame. This is not an exotic sabotage: hiding the root is an ordinary thing an app
# does, and until now it read as a pass in every warm/cold and bare-cell verdict in the file.
ft-modify ag display=none; ft_layout ag
_warm_vs_cold ag
check "a scene that renders nothing is NOT 'unchanged'" "$WARM_COLD_VERDICT" "blank"
# no_bare_cells reaches the same conclusion through the same door — assert the door rather than
# calling it, since a verdict deliberately failed here would fail the whole file.
_paint_cells ag
check "…and the bare-cell gate finds no frame to count" \
      "$([[ -z "$PAINTED_CELLS" ]] && echo "no frame")" "no frame"
ft_remove ag

# And the bare-cell PREDICATE itself: 'bg=- ' has to match something, or the counter is zero
# for the same reason an empty frame is. A hand-written write that sets only a foreground is
# precisely the hole the check hunts for.
printf '\e[H\e[38;5;196mX\e[0m' > "$tmp/teeth-bare"
check "the bare-cell counter finds a foreground-only write" \
      "$(( $(_bare_count "$(_cells "$tmp/teeth-bare")") > 0 ))" "1"
printf '\e[H\e[48;5;234;38;5;196mX\e[0m' > "$tmp/teeth-clad"
check "…and does not cry wolf over a clad one" \
      "$(_bare_count "$(_cells "$tmp/teeth-clad")")" "0"

summary
