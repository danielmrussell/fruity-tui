#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — controls/ft-table.bash
#
#  A data table (HTML's <table>) declared with ft-table-header columns and
#  ft-table-row data rows:
#
#      ft-table name=keys variant=grid striped=true
#          ft-table-header "Key"    width=16
#          ft-table-header "Action" textAlign=left
#          ft-table-row "Ctrl+A / Home"  "Move to start of line"
#          ft-table-row "Ctrl+E / End"   "Move to end of line"
#          ft-table-row "Ctrl+W"         "Delete the word before the cursor"
#      end_ft_table
#
#  Headers describe the layout (header text, optional fixed width=, and
#  textAlign=left|center|right for the whole column, headers included — CSS's
#  text-align, the same property a label reads, so a form-level textAlign reaches
#  the columns too; `align=` is kept as an alias). Every positional argument of an
#  ft-table-row is one CELL, in column order.
#
#  Data can arrive the other way up — ft-table-column "Ctrl+A" "Ctrl+E" gives one
#  COLUMN's cells — by declaring orientation=column on the table. The element that
#  does not match the current orientation is ignored.
#
#  WIDTH. Column widths size to their content unless a header pins width=, and the
#  table is display:inline-block — shrink-to-fit — so by default it is exactly as
#  wide as its content. Give the TABLE a width= and that is what it paints: columns
#  shrink (auto ones first, pinned ones only if that is not enough) or grow to fill,
#  and cells ellipsise. It never paints outside its own box.
#
#  variant=  is the whole look, and every variant honours striped= (zebra rows):
#      grid     full light box grid — a rule around and between every cell.
#      heavy    the same, drawn in heavy box glyphs — bold Excel-style rules.
#      lines    no outer box, no verticals; a rule under the header AND a thin
#               rule between rows — an airy ledger.
#      minimal  no box, no verticals, one rule under the header — clean and
#               compact (the modern data-table default).
#  (It is `variant`, not `style`. `style` is the framework-wide inline-CSS
#  property — style="color: red" — and means something else on every control.)
#
#  Any variant's atoms can be overridden individually: borderStyle, borderColor,
#  colLines, rowLines, headerLine. rows=N caps the body and scrolls it with the
#  header pinned.
#
#  Colours are all themed (FT_COLOR_TITLE headers, FT_COLOR_BORDER rules, FT_COLOR_STRIPE
#  zebra), so a table reads correctly on every palette with no ad-hoc colours.
#
#  Depends on ft-core.bash and ft-forms.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_TABLE_LOADED:-}" ]] && return 0
_FT_TABLE_LOADED=1

# Built once, by the prototype that declares `keymap=table`.
_ft_define_keymap_table() {
    # INACTIVE — merely focused. Enter steps in; the arrows still belong to focus
    # navigation. Copy here takes the WHOLE table (see ft_table_copy).
    ft-bindkeys ft_keymap_table ENTER=ft_key_delve CTRL+c=ft_table_copy ALT+w=ft_table_copy
    ft-keymap-cap ft_keymap_table ENTER  ft_key_delve   "$FT_IMPORTANCE_CRUCIAL" "Browse rows"
    ft-keymap-cap ft_keymap_table CTRL+c ft_table_copy  "$FT_IMPORTANCE_NORMAL"  "Copy table"

    # BROWSING — one Enter in, and NOW there is a current row: the arrows move it, it is
    # highlighted, and copy takes that row rather than the whole table. Nothing here bubbles.
    ft_keymap_once ft_keymap_table_browsing
    ft-bindkeys ft_keymap_table_browsing \
        UP=ft_table_key_up      DOWN=ft_table_key_down \
        LEFT=ft_table_key_up    RIGHT=ft_table_key_down \
        PGUP=ft_table_key_pgup  PGDN=ft_table_key_pgdn \
        HOME=ft_table_key_home  END=ft_table_key_end \
        ESC=ft_key_undelve \
        CTRL+c=ft_table_copy    ALT+w=ft_table_copy
    ft-keymap-cap ft_keymap_table_browsing UP   ft_table_key_up   "$FT_IMPORTANCE_CRUCIAL"   "Up a row"
    ft-keymap-cap ft_keymap_table_browsing DOWN ft_table_key_down "$FT_IMPORTANCE_CRUCIAL"   "Down a row"
    ft-keymap-cap ft_keymap_table_browsing PGUP ft_table_key_pgup "$FT_IMPORTANCE_IMPORTANT" "Page up"
    ft-keymap-cap ft_keymap_table_browsing PGDN ft_table_key_pgdn "$FT_IMPORTANCE_IMPORTANT" "Page down"
    ft-keymap-cap ft_keymap_table_browsing HOME ft_table_key_home "$FT_IMPORTANCE_NORMAL"    "Top"
    ft-keymap-cap ft_keymap_table_browsing END  ft_table_key_end  "$FT_IMPORTANCE_NORMAL"    "Bottom"
    ft-keymap-cap ft_keymap_table_browsing CTRL+c ft_table_copy   "$FT_IMPORTANCE_NORMAL"    "Copy row"
    ft-keymap-cap ft_keymap_table_browsing ESC  ft_key_undelve    "$FT_IMPORTANCE_IMPORTANT" "Leave"
}
# WHAT COPY TAKES IS A FUNCTION OF HOW FAR IN YOU ARE. Standing next to the table, there is
# no current row and copy hands you the whole thing, printable. Once you have stepped in
# there IS one, highlighted, and copy takes that row. (When a runlevel with SELECTION
# arrives, the same rule continues: the selection, or nothing — the row highlight goes
# impotent for copying the moment a real selection is available.)
ft_table_copy() {               # name
    local n=$1 out="" i j cell row
    _ft_table_cols "$n"; _ft_table_rows "$n"
    local nc=${#FT_TABLE_COLUMNS[@]}
    if ft_runlevel_engaged "$n"; then
        ft_resolved_prop "$n" cursor 0; local cur=${FT_RET:-0}
        (( cur < 0 )) && cur=0
        (( cur >= FT_TABLE_ROW_COUNT )) && cur=$(( FT_TABLE_ROW_COUNT - 1 ))
        (( cur < 0 )) && { ft_emit_status copyNothing; return 0; }
        for (( j=0; j<nc; j++ )); do _ft_table_cell "$cur" "$j"; out+="${out:+$'\t'}$FT_RET"; done
    else
        for (( j=0; j<nc; j++ )); do
            _ft_get_raw "${FT_TABLE_COLUMNS[$j]}" text; row+="${row:+$'\t'}$FT_RET"
        done
        out=$row
        for (( i=0; i<FT_TABLE_ROW_COUNT; i++ )); do
            row=""
            for (( j=0; j<nc; j++ )); do _ft_table_cell "$i" "$j"; row+="${row:+$'\t'}$FT_RET"; done
            out+=$'\n'"$row"
        done
    fi
    (( ${#out} == 0 )) && { ft_emit_status copyNothing; return 0; }
    ft_clip_copy "$out"; _ft_announce_copy $? itemCopied
    return 0
}
ft_prototype_table() {
    # A table is styled by BORDER PROPERTIES, like any other control:
    #   borderStyle  none|hidden|solid|heavy|double|rounded|dashed|dotted  (outer box + glyphs)
    #   borderColor  themed/any colour
    #   colLines     vertical rule between columns   (implied by a box)
    #   rowLines     horizontal rule between rows
    #   headerLine   rule under the header row
    #   striped      zebra data rows
    # `style` is an optional SHORTHAND that presets those atoms (grid | heavy |
    # lines | minimal); any atom set explicitly overrides the shorthand. rows>0
    # caps the body and scrolls (header pinned), like a label with overflow auto.
    # borderStyle= blanks the base control's inherited default (solid) so an
    # UNSET borderStyle reads empty and the `style` shorthand can supply it; a
    # user borderStyle=heavy still overrides.
    ft_runlevels browsing=ft_keymap_table_browsing
    ft_prototype extends=ft_control \
        focusable=true \
        focusSkip=_ft_table_focus_skip \
        keymap=table \
        setProp=_ft_table_setprop \
        defaults="display=inline-block striped=false rows=0 scrollTop=0 cursor=0 borderStyle= overflowY=auto"
    # overflowY=auto BECAUSE THAT IS WHAT IT DOES: rows>0 caps the body and scrolls it with the
    # header pinned, and the draw reserves a gutter column and paints a thumb in it. It was
    # declaring `overflow: hidden`, inherited from the base control, so ft_has_scrollbar — the
    # framework's one answer to "does this box present a scrollbar" — said no about a table with
    # a visible one. Same declaration ft-label carries, gated the same way by the published
    # pair, so a table whose rows all fit still answers no.
    #
    # The AXIS property, never the `overflow` shorthand: _ft_inset4 reserves a stable gutter
    # COLUMN from the shorthand, and a table reserves its own inside its own width (see
    # `gutter=1; tw=$(( cols - 1 ))` in the draw). Declaring the shorthand would take a second
    # column off every table on screen and hand the container gutter painter a bar to draw over
    # the table's own.
    ft_prop_kind_set cursor paint        # the current ROW — exists only once you step in
    ft_prop_kind_set scrollTop   paint
    ft_prop_kind_set striped     paint
    ft_prop_kind_set borderColor paint
    ft_prop_kind_set variant     layout   # each of these changes the table's SIZE
    ft_prop_kind_set colLines    layout   # (borderStyle is layout-kind framework-wide now)
    ft_prop_kind_set rowLines    layout
    ft_prop_kind_set headerLine  layout
    ft_prop_kind_set orientation layout   # row (default) | column
}

# Resolve the effective look. `style` shorthand supplies defaults; an explicit
# atom (read LOCAL-only, so it never inherits) overrides. Sets:
#   TBL_BS (border style), TBL_BOX, TBL_VERT (verticals), TBL_RL/TBL_HL (row/
#   header rules).
_ft_table_style() {             # name
    local name=$1 style dbs drl dcl dhl v
    ft_resolved_prop "$name" variant ""; style=$FT_RET
    case "$style" in
        heavy)   dbs=heavy;  drl=1; dcl=1; dhl=1 ;;
        lines)   dbs=none;   drl=1; dcl=0; dhl=1 ;;
        minimal) dbs=none;   drl=0; dcl=0; dhl=1 ;;
        grid|*)  dbs=solid;  drl=1; dcl=1; dhl=1 ;;   # default = grid
    esac
    _ft_get_raw "$name" borderStyle; TBL_BS=${FT_RET:-$dbs}
    case $TBL_BS in none|hidden) TBL_BOX=0 ;; *) TBL_BOX=1 ;; esac
    _ft_get_raw "$name" rowLines;   v=$FT_RET; [[ -z "$v" ]] && TBL_RL=$drl || { [[ "$v" == true ]] && TBL_RL=1 || TBL_RL=0; }
    _ft_get_raw "$name" headerLine; v=$FT_RET; [[ -z "$v" ]] && TBL_HL=$dhl || { [[ "$v" == true ]] && TBL_HL=1 || TBL_HL=0; }
    _ft_get_raw "$name" colLines;   v=$FT_RET; [[ -z "$v" ]] && v=$dcl || { [[ "$v" == true ]] && v=1 || v=0; }
    (( TBL_BOX )) && TBL_VERT=1 || TBL_VERT=$v
}

# _ft_table_glyphs BS → H V and the corner/junction set for the border family.
_ft_table_glyphs() {            # borderStyle
    if (( ! FT_USE_UTF8 )); then
        H='-'; V='|'; TL='+'; TT='+'; TR='+'; ML='+'; MC='+'; MR='+'; BL='+'; BB='+'; BR='+'; return
    fi
    case "$1" in
        heavy)  H=$'\xe2\x94\x81'; V=$'\xe2\x94\x83'; TL=$'\xe2\x94\x8f'; TT=$'\xe2\x94\xb3'; TR=$'\xe2\x94\x93'
                ML=$'\xe2\x94\xa3'; MC=$'\xe2\x95\x8b'; MR=$'\xe2\x94\xab'; BL=$'\xe2\x94\x97'; BB=$'\xe2\x94\xbb'; BR=$'\xe2\x94\x9b' ;;
        double) H=$'\xe2\x95\x90'; V=$'\xe2\x95\x91'; TL=$'\xe2\x95\x94'; TT=$'\xe2\x95\xa6'; TR=$'\xe2\x95\x97'
                ML=$'\xe2\x95\xa0'; MC=$'\xe2\x95\xac'; MR=$'\xe2\x95\xa3'; BL=$'\xe2\x95\x9a'; BB=$'\xe2\x95\xa9'; BR=$'\xe2\x95\x9d' ;;
        dashed) H=$'\xe2\x94\x84'; V=$'\xe2\x94\x86'; TL=$FT_GLYPH_TOP_LEFT; TT=$FT_GLYPH_TEE_DOWN; TR=$FT_GLYPH_TOP_RIGHT
                ML=$FT_GLYPH_TEE_LEFT; MC=$FT_GLYPH_CROSS; MR=$FT_GLYPH_TEE_RIGHT; BL=$FT_GLYPH_BOTTOM_LEFT; BB=$FT_GLYPH_TEE_UP; BR=$FT_GLYPH_BOTTOM_RIGHT ;;
        dotted) H=$'\xe2\x94\x88'; V=$'\xe2\x94\x8a'; TL=$FT_GLYPH_TOP_LEFT; TT=$FT_GLYPH_TEE_DOWN; TR=$FT_GLYPH_TOP_RIGHT
                ML=$FT_GLYPH_TEE_LEFT; MC=$FT_GLYPH_CROSS; MR=$FT_GLYPH_TEE_RIGHT; BL=$FT_GLYPH_BOTTOM_LEFT; BB=$FT_GLYPH_TEE_UP; BR=$FT_GLYPH_BOTTOM_RIGHT ;;
        rounded) H=$FT_GLYPH_HORIZONTAL; V=$FT_GLYPH_VERTICAL; TL=$'\xe2\x95\xad'; TT=$FT_GLYPH_TEE_DOWN; TR=$'\xe2\x95\xae'
                ML=$FT_GLYPH_TEE_LEFT; MC=$FT_GLYPH_CROSS; MR=$FT_GLYPH_TEE_RIGHT; BL=$'\xe2\x95\xb0'; BB=$FT_GLYPH_TEE_UP; BR=$'\xe2\x95\xaf' ;;
        *)      H=$FT_GLYPH_HORIZONTAL; V=$FT_GLYPH_VERTICAL; TL=$FT_GLYPH_TOP_LEFT; TT=$FT_GLYPH_TEE_DOWN; TR=$FT_GLYPH_TOP_RIGHT
                ML=$FT_GLYPH_TEE_LEFT; MC=$FT_GLYPH_CROSS; MR=$FT_GLYPH_TEE_RIGHT; BL=$FT_GLYPH_BOTTOM_LEFT; BB=$FT_GLYPH_TEE_UP; BR=$FT_GLYPH_BOTTOM_RIGHT ;;
    esac
}
ft-table()     { ft_new table "$@" && FT_NEST_STACK+=("$FT_RET"); }
end_ft_table() { ft-end table; }

# ── Data children (display=none — the table renders them, never themselves) ───
# A table is DECLARED with column HEADERS plus DATA. The header set is fixed;
# the data comes either as ROWS (orientation=row, the default, HTML-<tr> style)
# or as COLUMNS (orientation=column). The element that doesn't match the current
# orientation is simply ignored.
#
#   ft-table-header "Key"  width=14 textAlign=left # one per column
#   ft-table-row    "Ctrl+A" "start of line"       # row-oriented data
#   ft-table-column "Ctrl+A" "Ctrl+E" "Ctrl+W"     # column-oriented data

ft_prototype_tableheader() { ft_prototype extends=ft_control defaults="display=none"; }
# COLUMN ALIGNMENT IS `textAlign`, THE ONE THE FRAMEWORK ALREADY HAD.
#
# This control shipped with an invented `align` while CSS's text-align was sitting right there
# — registered as an inherited property, resolved by ft_resolved_prop, and read by every label and
# button in the tree. So `ft-table-header "Note" textAlign=right` was ACCEPTED and silently
# ignored (the value resolved on the control and nothing ever asked for it), a form-level
# textAlign that every other control in the form obeyed stopped at the table's edge, and an
# author who knew CSS had to learn a second word for the same idea. Copy CSS verbatim; a
# deviation has to earn itself, and this one earned nothing.
#
# `align` STAYS AS AN ALIAS, because it is in the file's own header examples and in whatever
# app code already uses it, and a silently ignored property is exactly the bug being fixed
# here. The rule, written down because it is a deviation: an `align` set ON THE COLUMN wins,
# since it is the author naming this column specifically; otherwise textAlign resolves
# normally, inheritance and all; left when neither says anything.
#
# The prototype default that used to say `align=left` is GONE, and had to be: a prototype
# default is applied as an INLINE property (see _ft_apply_args), so "the author said nothing"
# and "the author said left" were the same string, and the alias would have out-ranked every
# textAlign ever written. The `left` fallback now lives where it can be told apart from an answer —
# in the read below.
_ft_table_column_align() {      # column-control → FT_RET = left|center|right
    ft_get "$1" align                       # local-only: did the author name THIS column?
    (( ${#FT_RET} )) && return 0
    ft_resolved_prop "$1" textAlign left            # the CSS property, inherited like anywhere else
}
_FT_TH_SEQ=0
ft-table-header() {             # [header] [width=] [textAlign=]  (header text is content)
    local a hasname=0
    for a in "$@"; do [[ "$a" == name=* ]] && hasname=1; done
    if (( hasname )); then
        ft_new tableheader "$@"
    else
        local o=""
        (( ${#FT_NEST_STACK[@]} > 0 )) && o="${FT_NEST_STACK[$(( ${#FT_NEST_STACK[@]} - 1 ))]}"
        ft_new tableheader name="${o}_th$(( ++_FT_TH_SEQ ))" "$@"
    fi
}

ft_prototype_tablerow()    { ft_prototype extends=ft_control defaults="display=none"; }
ft_prototype_tablecolumn() { ft_prototype extends=ft_control defaults="display=none"; }
_FT_TR_SEQ=0; _FT_TC_SEQ=0
# A data element (row OR column): EVERY positional argument is a cell value;
# name= is the only recognised property. Cells go in _fti_${name}__cells, which
# ft_remove tears down.
_ft_table_dataelt() {           # type seqvar suffix args...
    local type=$1 suf=$3; local -n _seq=$2; shift 3
    local a name="" cells=()
    for a in "$@"; do if [[ "$a" == name=* ]]; then name="${a#name=}"; else cells+=("$a"); fi; done
    if [[ -z "$name" ]]; then
        local o=""
        (( ${#FT_NEST_STACK[@]} > 0 )) && o="${FT_NEST_STACK[$(( ${#FT_NEST_STACK[@]} - 1 ))]}"
        name="${o}${suf}$(( ++_seq ))"
    fi
    ft_new "$type" name="$name"
    local rn=$FT_RET
    declare -ga "_fti_${rn}__cells=()"
    local -n _c="_fti_${rn}__cells"; _c=("${cells[@]}")
}
ft-table-row()    { _ft_table_dataelt tablerow    _FT_TR_SEQ _tr "$@"; }
ft-table-column() { _ft_table_dataelt tablecolumn _FT_TC_SEQ _tc "$@"; }

# ── Child gathering (orientation-aware) ──────────────────────────────────────
FT_TABLE_COLUMNS=(); FT_TABLE_ROWS=(); FT_TABLE_COLUMN_DATA=(); FT_TABLE_ORIENTATION=row; FT_TABLE_ROW_COUNT=0
_ft_table_cols() { local k; FT_TABLE_COLUMNS=(); for k in ${FT_KIDS[$1]:-}; do [[ "${FT_TYPE[$k]:-}" == tableheader ]] && FT_TABLE_COLUMNS+=("$k"); done; }
# _ft_table_rows NAME — resolve the DATA into a uniform (row,col) view: sets
# FT_TABLE_ORIENTATION, FT_TABLE_ROWS / FT_TABLE_COLUMN_DATA, and FT_TABLE_ROW_COUNT (the number of data rows).
_ft_table_rows() {              # name
    local name=$1 k
    _ft_get_raw "$name" orientation; FT_TABLE_ORIENTATION=${FT_RET:-row}   # local-only (no inherit)
    FT_TABLE_ROWS=(); FT_TABLE_COLUMN_DATA=(); FT_TABLE_ROW_COUNT=0
    if [[ "$FT_TABLE_ORIENTATION" == column ]]; then
        for k in ${FT_KIDS[$name]:-}; do [[ "${FT_TYPE[$k]:-}" == tablecolumn ]] && FT_TABLE_COLUMN_DATA+=("$k"); done
        for k in "${FT_TABLE_COLUMN_DATA[@]}"; do local -n _c="_fti_${k}__cells"; (( ${#_c[@]} > FT_TABLE_ROW_COUNT )) && FT_TABLE_ROW_COUNT=${#_c[@]}; done
    else
        for k in ${FT_KIDS[$name]:-}; do [[ "${FT_TYPE[$k]:-}" == tablerow ]] && FT_TABLE_ROWS+=("$k"); done
        FT_TABLE_ROW_COUNT=${#FT_TABLE_ROWS[@]}
    fi
}
# _ft_table_cell ROWIDX COLIDX → FT_RET (the cell value, "" if absent).
_ft_table_cell() {              # rowidx colidx
    local j=$1 i=$2
    if [[ "$FT_TABLE_ORIENTATION" == column ]]; then
        [[ -n "${FT_TABLE_COLUMN_DATA[$i]:-}" ]] || { FT_RET=""; return; }
        local -n _c="_fti_${FT_TABLE_COLUMN_DATA[$i]}__cells"; FT_RET=${_c[$j]:-}
    else
        [[ -n "${FT_TABLE_ROWS[$j]:-}" ]] || { FT_RET=""; return; }
        local -n _c="_fti_${FT_TABLE_ROWS[$j]}__cells"; FT_RET=${_c[$i]:-}
    fi
}

# On close, compute each column's content width once (header vs every cell) and
# stash it in _fti_${name}__colw; the layout/draw passes read it, never re-measure.
table_on_children_complete() { _ft_table_measure "$1"; }
_ft_table_measure() {           # name
    local name=$1 i c w r cell
    _ft_table_cols "$name"; _ft_table_rows "$name"
    local ncol=${#FT_TABLE_COLUMNS[@]}
    local -a cw=() fixed=()
    for (( i=0; i<ncol; i++ )); do
        c=${FT_TABLE_COLUMNS[$i]}
        # LOCAL-only read: width must NOT inherit (ft_resolved_prop/ft_resolve walk up the
        # parent chain, and the enclosing form's width= would masquerade as the
        # column's). A column is auto-sized unless width= is set ON the column.
        _ft_get_raw "$c" width
        if [[ -n "$FT_RET" ]]; then cw[$i]=$FT_RET; fixed[$i]=1; continue; fi
        fixed[$i]=0
        _ft_get_raw "$c" text; ft_display_width "$FT_RET"; w=$FT_DISPLAY_WIDTH
        for (( r=0; r<FT_TABLE_ROW_COUNT; r++ )); do
            _ft_table_cell "$r" "$i"; ft_display_width "$FT_RET"; (( FT_DISPLAY_WIDTH > w )) && w=$FT_DISPLAY_WIDTH
        done
        cw[$i]=$w
    done
    declare -ga "_fti_${name}__colw=()" "_fti_${name}__colfixed=()"
    local -n _cwv="_fti_${name}__colw";     _cwv=("${cw[@]}")
    local -n _cfv="_fti_${name}__colfixed"; _cfv=("${fixed[@]}")
    unset "_fti_${name}__fitkey"            # the fit below is derived from these
}

# ── Fitting those columns into the box the table actually got ────────────────
# The widths above are the table's NATURAL ones — what it would like. What it GETS is
# FT_MEASURED_WIDTH, and the two are not the same number. The draw used the natural widths
# regardless, so a table in a narrower box painted straight over whatever sat beside it: a
# `width=26` table with 37 columns of content painted 37. (ASCII and CJK alike — this was
# never a wide-glyph bug, it was the table ignoring its own width.)
#
# CSS shrinks a table's columns rather than overflowing, and ft-markdown's tables already do
# exactly that, so this does too. Auto-sized columns give up the surplus in proportion to how
# much they have; a column with an explicit width= is only touched when shrinking the auto
# ones cannot free enough, so the author's number is honoured wherever it can be. Cells then
# ellipsise through ft_fit_align, as they always have.
#
# Cached against the box and the natural widths, because the draw asks every frame.
FT_TABLE_FITTED=""
_ft_table_fit() {               # name avail vert → FT_TABLE_FITTED names the width array
    local name=$1 avail=$2 vert=$3
    local -n _nat="_fti_${name}__colw"
    local nc=${#_nat[@]}
    FT_TABLE_FITTED="_fti_${name}__fitw"
    # A table is display:inline-block, i.e. shrink-to-fit: with no width= of its own it is
    # AS WIDE AS ITS CONTENT and the box it sits in is irrelevant. An explicit width= is the
    # author saying otherwise, and then it is honoured in BOTH directions — a table told to
    # be 60 wide fills 60 instead of drawing 46 and leaving a ragged edge. Only explicit,
    # because growing an auto-sized table would stretch every existing one to its container.
    _ft_get_raw "$name" width; local explicit=0; [[ -n "$FT_RET" ]] && explicit=1
    local keyvar="_fti_${name}__fitkey" key="$avail|$vert|$explicit|${_nat[*]}"
    [[ "${!keyvar:-}" == "$key" ]] && return

    local chrome=0
    if   (( vert )); then chrome=$(( 3*nc + 1 ))
    elif (( nc > 0 )); then chrome=$(( 2*(nc - 1) )); fi
    local target=$(( avail - chrome ))
    (( target < nc )) && target=$nc         # one column apiece is the hard floor

    local -a out=(); local i sum=0
    for (( i=0; i<nc; i++ )); do out[i]=${_nat[i]}; (( sum += out[i] )); done

    if (( explicit && sum < target )); then
        # Spare room goes to the AUTO columns — a column given an explicit width keeps it,
        # exactly as when shrinking. If every column is fixed the table stays its natural
        # size rather than stretching columns the author pinned.
        local -n _fixed="_fti_${name}__colfixed"
        local pool=0 give spare=$(( target - sum ))
        for (( i=0; i<nc; i++ )); do (( ${_fixed[i]:-0} )) || (( pool += out[i] )); done
        if (( pool > 0 )); then
            for (( i=0; i<nc; i++ )); do
                (( ${_fixed[i]:-0} )) && continue
                give=$(( out[i] * spare / pool )); (( give < 1 )) && continue
                (( out[i] += give, sum += give ))
            done
            for (( i=nc-1; i>=0 && sum < target; i-- )); do    # the rounding remainder
                (( ${_fixed[i]:-0} )) && continue
                (( out[i]++, sum++ ))
            done
        fi
    elif (( sum > target )); then
        local -n _fixed="_fti_${name}__colfixed"
        local pass pool need take
        # Two proportional passes — the auto columns first, then everything — so the work is
        # O(columns) however far over the table is, rather than one cell at a time.
        for pass in auto all; do
            (( sum <= target )) && break
            pool=0
            for (( i=0; i<nc; i++ )); do
                [[ "$pass" == auto ]] && (( ${_fixed[i]:-0} )) && continue
                (( pool += out[i] ))
            done
            (( pool > 0 )) || continue
            need=$(( sum - target ))
            for (( i=0; i<nc; i++ )); do
                [[ "$pass" == auto ]] && (( ${_fixed[i]:-0} )) && continue
                take=$(( out[i] * need / pool ))
                (( take > out[i] - 1 )) && take=$(( out[i] - 1 ))
                (( take < 1 )) && continue
                (( out[i] -= take, sum -= take ))
            done
        done
        # Whatever integer division left over: at most one column each, off the widest.
        local guard=0 widest wi
        while (( sum > target && guard < nc + 2 )); do
            widest=0; wi=-1
            for (( i=0; i<nc; i++ )); do (( out[i] > widest )) && { widest=${out[i]}; wi=$i; }; done
            (( wi < 0 || widest <= 1 )) && break
            (( out[wi]--, sum--, guard++ ))
        done
    fi

    declare -ga "_fti_${name}__fitw=()"
    local -n _fit="_fti_${name}__fitw"; _fit=("${out[@]}")
    declare -g "$keyvar=$key"
}

# _ft_table_gridw NAME → FT_RET: the table's grid width WITHOUT any scrollbar
# gutter (sum of columns + the verticals/gutters the current look implies).
_ft_table_gridw() {             # name
    local name=$1
    local -n _cw="_fti_${name}__colw"; local nc=${#_cw[@]}
    _ft_table_style "$name"
    local sum=0 i; for (( i=0; i<nc; i++ )); do sum=$(( sum + _cw[i] )); done
    if (( TBL_VERT )); then
        FT_RET=$(( sum + 3*nc + 1 ))          # 2 pad/cell + (nc+1) verticals
    else
        (( nc > 0 )) && FT_RET=$(( sum + 2*(nc - 1) )) || FT_RET=0   # 2-col gutters
    fi
}

# _ft_table_metrics NAME → the scroll situation. Sets TBL_NR, the style atoms
# (via _ft_table_style), TBL_FTOP/FBOT (pinned lines above/below the body),
# TBL_MAXROWS, TBL_SCROLL, TBL_VIS, TBL_MAXSCROLL.
_ft_table_metrics() {           # name
    local name=$1
    _ft_table_rows "$name"; TBL_NR=$FT_TABLE_ROW_COUNT
    _ft_table_style "$name"     # → TBL_BS TBL_BOX TBL_VERT TBL_RL TBL_HL
    TBL_FTOP=$(( TBL_BOX + 1 + TBL_HL ))    # top border? + header + header rule?
    TBL_FBOT=$TBL_BOX                       # bottom border?
    ft_resolved_prop "$name" rows 0; TBL_MAXROWS=$FT_RET; (( TBL_MAXROWS < 0 )) && TBL_MAXROWS=0
    if (( TBL_MAXROWS > 0 && TBL_NR > TBL_MAXROWS )); then
        TBL_SCROLL=1; TBL_VIS=$TBL_MAXROWS
    else
        TBL_SCROLL=0; TBL_VIS=$TBL_NR
    fi
    TBL_MAXSCROLL=$(( TBL_NR - TBL_VIS )); (( TBL_MAXSCROLL < 0 )) && TBL_MAXSCROLL=0
}

# ── Measurement ──────────────────────────────────────────────────────────────
_ft_preferred_width_table() {             # name → FT_RET (content columns; +1 gutter if it scrolls)
    local name=$1
    _ft_table_gridw "$name"; local w=$FT_RET
    _ft_table_metrics "$name"
    (( TBL_SCROLL )) && (( w++ ))          # reserve the scrollbar-gutter column
    FT_RET=$w
}
# Body lines for N data rows = N rows + (N-1) inter-row rules when rowLines is on.
_ft_height_table() {            # name contentwidth → FT_RET (content rows)
    local name=$1
    _ft_table_metrics "$name"
    local vis=$TBL_NR; (( TBL_SCROLL )) && vis=$TBL_VIS
    local body=$vis; (( TBL_RL )) && body=$(( vis + vis - 1 )); (( body < 0 )) && body=0
    FT_RET=$(( TBL_FTOP + body + TBL_FBOT ))
}

# ── Scrolling ────────────────────────────────────────────────────────────────
_ft_table_focus_skip() {        # name → 0 = skip (only a scrolling table is focusable)
    _ft_table_metrics "$1"
    (( TBL_SCROLL == 0 || TBL_MAXSCROLL == 0 ))
}
# `cursor` AND `scrollTop` ARE THE TABLE'S STATE, so the two verbs below are now nothing but
# the property write, and the rule that used to live in each of them lives once, in the
# reconciler _ft_setprop calls. Written as a property they were stored verbatim:
# `ft-modify tb cursor=99` on a six-row table reported 99 while NO row was highlighted, and
# `scrollTop=99` reported 99 with the body where it was. The verbs clamped; the property did
# not; an app that reached for the obvious name got the wrong one of the two.
ft_table_scroll_set() { ft-modify "$1" scrollTop="$2"; }
# (A scroll-by-delta helper lived here, from when the arrows PANNED the window. Nothing has
# called it since the cursor model below replaced that: every key and every wheel tick moves
# the row and lets scrolling follow. Left in place it went on teaching the superseded model to
# whoever read it next — a scan of every live route reached the cursor helper 15 times and it
# zero times — so it is gone. tests/test-deadcode.bash now asks that question of every helper.)
# THE CURRENT ROW. Once you have stepped into a table there is one, it is highlighted, and
# the arrows move IT — scrolling follows to keep it in view, which is the other way round
# from before, when the arrows only panned the window and nothing was ever "the row you are
# on". A table could therefore never say which row you meant, so copying one was impossible.
ft_table_cursor_set() { ft-modify "$1" cursor="$2"; }

# The prototype's setProp reconciler: _ft_setprop is every route in, so a cursor written by an
# app, by a key, by the DSL or by a state restore is bounded the same way and drags the view
# after it.
# Stamped, not written back through ft-modify: the setter is our caller.
_ft_table_setprop() {           # name prop value
    local n=$1 v=$3 last sc
    case $2 in cursor|scrollTop) : ;; *) return 0 ;; esac
    case $v in ''|*[!0-9-]*|-*-*|-) return 0 ;; esac    # _ft_setprop's numeric guard covers this
    _ft_table_metrics "$n"                              # → TBL_NR TBL_SCROLL TBL_VIS TBL_MAXSCROLL
    last=$(( TBL_NR - 1 ))
    # A TABLE WITH NO ROWS HAS NO ROW TO BE ON, and answering 3 would be the same lie in
    # miniature — so the write lands on the prototype default it started at rather than being
    # kept.
    (( last < 0 )) && { _ft_stamp_prop "$n" "$2" 0; return 0; }
    if [[ "$2" == cursor ]]; then
        (( v < 0 )) && v=0; (( v > last )) && v=$last
        _ft_stamp_prop "$n" cursor "$v"
        # KEEPING THE ROW ON SCREEN IS THE OTHER HALF OF MOVING TO IT, and it is why this is a
        # reconciler rather than a clamp: scroll only as far as it takes, so the view does not
        # jump about. (`selectedIndex` scrolls the option into view in a browser too.)
        if (( TBL_SCROLL )); then
            ft_resolved_prop "$n" scrollTop 0; sc=${FT_RET:-0}
            case $sc in ''|*[!0-9-]*|-*-*|-) sc=0 ;; esac
            (( v <  sc ))           && sc=$v
            (( v >= sc + TBL_VIS )) && sc=$(( v - TBL_VIS + 1 ))
            (( sc < 0 )) && sc=0; (( sc > TBL_MAXSCROLL )) && sc=$TBL_MAXSCROLL
            _ft_stamp_prop "$n" scrollTop "$sc"
        fi
    else
        (( v < 0 )) && v=0; (( v > TBL_MAXSCROLL )) && v=$TBL_MAXSCROLL
        _ft_stamp_prop "$n" scrollTop "$v"
    fi
    ft_dirty "$n"
    return 0
}
_ft_table_cursor_by() { ft_resolved_prop "$1" cursor 0; ft_table_cursor_set "$1" $(( ${FT_RET:-0} + $2 )); }
ft_table_key_up()   { _ft_table_cursor_by "$1" -1; }
ft_table_key_down() { _ft_table_cursor_by "$1" 1; }
ft_table_key_pgup() { _ft_table_metrics "$1"; _ft_table_cursor_by "$1" $(( -TBL_VIS )); }
ft_table_key_pgdn() { _ft_table_metrics "$1"; _ft_table_cursor_by "$1" "$TBL_VIS"; }
ft_table_key_home() { ft_table_cursor_set "$1" 0; }
ft_table_key_end()  { _ft_table_rows "$1"; ft_table_cursor_set "$1" $(( FT_TABLE_ROW_COUNT - 1 )); }

# ── Draw ─────────────────────────────────────────────────────────────────────
_ft_draw_table() {              # name
    local name=$1
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local cols=${FT_MEASURED_WIDTH[$name]:-0} rows=${FT_MEASURED_HEIGHT[$name]:-0}
    (( cols < 1 || rows < 1 )) && return
    local -n NAT="_fti_${name}__colw"
    local nc=${#NAT[@]}
    (( nc == 0 )) && return
    _ft_table_cols "$name"
    _ft_table_metrics "$name"                # sets TBL_* (also gathers FT_TABLE_ROWS)
    local nr=$TBL_NR
    # PUBLISH THE DOM'S "DID THIS OVERFLOW?" — the same pair a label and a container publish,
    # from the same place a label does (the draw, where the numbers are already in hand).
    # _ft_table_metrics has always computed exactly these two and told nobody, so a table that
    # was visibly scrolling reported nothing: ft_has_scrollbar said no about a table with a
    # thumb, and an ft-scrollbar bound with for= read no extent and blanked itself.
    # Written only when they change — this is the draw path, and an unconditional property
    # write per paint churns the cascade cache for nothing.
    # EXTENT BEFORE VIEWPORT: _ft_clamp_scroll bounds a scroll offset against this pair.
    local _pub="_ftp_${name}_scrollHeight"
    [[ "${!_pub:-}" != "$TBL_NR" ]] && _ft_setprop "$name" scrollHeight "$TBL_NR"
    _pub="_ftp_${name}_clientHeight"
    [[ "${!_pub:-}" != "$TBL_VIS" ]] && _ft_setprop "$name" clientHeight "$TBL_VIS"
    ft_resolved_prop "$name" striped false; local striped=$FT_RET

    # Scrolling: reserve the last column for a gutter; the grid paints into tw.
    local gutter=0 tw=$cols
    if (( TBL_SCROLL )); then gutter=1; tw=$(( cols - 1 )); fi
    # THE WIDTHS THE ROWS ARE BUILT FROM ARE THE FITTED ONES, not the natural ones — the
    # box is `tw` wide and that is what the table gets to paint. Done after tw is known,
    # so the scrollbar gutter is already out of the budget.
    _ft_table_fit "$name" "$tw" "$TBL_VERT"
    local -n CW="$FT_TABLE_FITTED"
    # Below a certain width a bordered grid CANNOT fit — two columns and their rules need
    # nine cells, so a table asked to be eight wide has nowhere left to give. The fitter
    # stops at one column apiece rather than producing zero-width columns, which leaves the
    # row one or two cells over. Rather than let that reach a neighbour, work out the grid's
    # built width here and clip the rows when (and only when) it exceeds the box: in every
    # ordinary case this is a single comparison and nothing is scanned.
    local gridw=0 clip=0 _gi
    for (( _gi=0; _gi<nc; _gi++ )); do (( gridw += CW[_gi] )); done
    if (( TBL_VERT )); then (( gridw += 3*nc + 1 )); else (( gridw += 2*(nc - 1) )); fi
    (( gridw > tw )) && clip=1
    ft_resolved_prop "$name" scrollTop 0; local sc=$FT_RET
    (( sc < 0 )) && sc=0; (( sc > TBL_MAXSCROLL )) && sc=$TBL_MAXSCROLL

    # Per-column alignment, cached once.
    local -a AL=()
    local i
    for (( i=0; i<nc; i++ )); do _ft_table_column_align "${FT_TABLE_COLUMNS[$i]}"; AL[$i]=$FT_RET; done

    local H V TL TT TR ML MC MR BL BB BR
    _ft_table_glyphs "$TBL_BS"
    _ft_color_override "$name" borderColor 38; local bcov=$FT_RET
    local bsgr="$FT_COLOR_BORDER$bcov" rst=$FT_COLOR_RESET
    _ft_css_pe_or "$name" header "$FT_COLOR_TITLE";               local hsgr=$FT_RET      # table::header
    _ft_compose_sgr "$name";                                  local bodysgr=$FT_RET   # table{color/bg}
    _ft_css_pe_or "$name" stripe "${FT_COLOR_STRIPE:-$FT_COLOR_BODY}"; local stripesgr=$FT_RET  # table::stripe
    local vert=$TBL_VERT y=$row

    # A rule row of width tw. With verticals it carries column junctions; without
    # them it is a continuous rule. (Painted at the current y, which advances.)
    _ft_table_rule() {          # leftGlyph midGlyph rightGlyph
        local lg=$1 mg=$2 rg=$3 out seg j
        if (( vert )); then
            [[ -z "$lg" ]] && lg=$H; [[ -z "$mg" ]] && mg=$H; [[ -z "$rg" ]] && rg=$H
            out="$bsgr$lg"
            for (( j=0; j<nc; j++ )); do
                printf -v seg '%*s' $(( CW[j] + 2 )) ''; seg=${seg// /$H}
                out+="$seg"; (( j < nc-1 )) && out+="$mg"
            done
            out+="$rg"
        else
            printf -v out '%*s' "$tw" ''; out=${out// /$H}; out="$bsgr$out"
        fi
        (( clip )) && { ft_display_truncate "$out" "$tw"; out=$FT_DISPLAY_TRUNCATED; }
        ft_print_at_width "$y" "$col" "$out$rst" "$tw"; (( y++ ))
    }
    # A data/header row. csgr is the run's base colour (body / stripe / header);
    # rj is the data-row index, or -1 for the header (cells from HDR). Cells are
    # fetched orientation-agnostically via _ft_table_cell.
    _ft_table_row() {           # csgr rowidx
        local csgr=$1 rj=$2 out j cellv
        for (( j=0; j<nc; j++ )); do
            if (( rj < 0 )); then cellv=${HDR[$j]:-}; else _ft_table_cell "$rj" "$j"; cellv=$FT_RET; fi
            ft_fit_align "$cellv" "${CW[$j]}" "${AL[$j]}"
            if (( vert )); then
                (( j == 0 )) && out="$bsgr$V"
                out+="$csgr $FT_FIT $bsgr$V"
            else
                (( j == 0 )) && out=""
                (( j > 0 )) && out+="$csgr  "
                out+="$csgr$FT_FIT"
            fi
        done
        (( clip )) && { ft_display_truncate "$out" "$tw"; out=$FT_DISPLAY_TRUNCATED; }
        ft_print_at_width "$y" "$col" "$out$rst" "$tw"; (( y++ ))
    }
    # Draw one inter-row / header rule (the junction glyphs when boxed).
    _ft_table_hrule() { if (( TBL_BOX )); then _ft_table_rule "$ML" "$MC" "$MR"; else _ft_table_rule "" "" ""; fi; }

    # Header cells = each column's text.
    local -a HDR=()
    for (( i=0; i<nc; i++ )); do _ft_get_raw "${FT_TABLE_COLUMNS[$i]}" text; HDR[$i]=$FT_RET; done

    # ── Pinned header ────────────────────────────────────────────────────────
    (( TBL_BOX )) && _ft_table_rule "$TL" "$TT" "$TR"
    _ft_table_row "$hsgr" -1
    (( TBL_HL )) && _ft_table_hrule

    local j csgr first last bodyTop=$y
    if (( TBL_SCROLL )); then first=$sc; last=$(( sc + TBL_VIS - 1 ))
    else first=0; last=$(( nr - 1 )); fi
    # The row the keyboard is on — `table::active`, the same pseudo-element a tree's cursor
    # row and a tab use, so one rule spelling covers every control that has a current item.
    # FADED until you have stepped in with Enter: out here there is no current row to speak
    # of, and copy takes the whole table.
    local focused=0; [[ "${FT_FOCUS:-}" == "$name" ]] && focused=1
    ft_resolved_prop "$name" cursor 0; local curRow=${FT_RET:-0}
    local activesgr=""
    (( focused )) && { _ft_runlevel_active_sgr "$name" "$FT_COLOR_FOCUS"; _ft_dim_if_disabled "$name" "$FT_RET"; activesgr=$FT_RET; }
    for (( j=first; j<=last; j++ )); do
        csgr=$bodysgr
        [[ "$striped" == true ]] && (( j % 2 == 1 )) && csgr=$stripesgr
        (( focused && j == curRow )) && [[ -n "$activesgr" ]] && csgr=$activesgr
        _ft_table_row "$csgr" "$j"
        (( TBL_RL )) && (( j < last )) && _ft_table_hrule
    done
    (( TBL_BOX )) && _ft_table_rule "$BL" "$BB" "$BR"

    # Scrollbar gutter beside the body region (data rows + any inter-row rules).
    if (( TBL_SCROLL )); then
        local bodyLines=$TBL_VIS; (( TBL_RL )) && bodyLines=$(( 2*TBL_VIS - 1 ))
        local gcol=$(( col + cols - 1 )) r tsgr
        local thumbLen=$(( bodyLines * TBL_VIS / nr )); (( thumbLen < 1 )) && thumbLen=1
        local maxstart=$(( bodyLines - thumbLen )); (( maxstart < 0 )) && maxstart=0
        local thumbStart=0
        (( TBL_MAXSCROLL > 0 )) && thumbStart=$(( maxstart * sc / TBL_MAXSCROLL ))
        [[ "${FT_FOCUS:-}" == "$name" ]] && tsgr=$FT_COLOR_FOCUS || tsgr=$FT_COLOR_THUMB
        _ft_css_pe_or "$name" scrollbar "$tsgr"; tsgr=$FT_RET      # `table::scrollbar { … }`
        local tracksgr; _ft_css_pe_or "$name" track "$FT_COLOR_DIVIDER"; tracksgr=$FT_RET   # `table::track`
        for (( r=0; r<bodyLines; r++ )); do
            if (( r >= thumbStart && r < thumbStart + thumbLen )); then
                ft_print_at_width $(( bodyTop + r )) "$gcol" "$tsgr $rst" 1
            else
                ft_print_at_width $(( bodyTop + r )) "$gcol" "$tracksgr$FT_GLYPH_VERTICAL$rst" 1
            fi
        done
    fi

    unset -f _ft_table_rule _ft_table_row _ft_table_hrule
}
