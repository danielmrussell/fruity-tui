#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — controls/ft-frame.bash
#
#  The "frame" prototype: a plain container whose only specialization over the
#  root ft_control is a border by default (its whole purpose — same idea as
#  <fieldset> in browsers) and a draw function: border + optional centered
#  title + interior fill so stale content never shows through a repaint.
#
#  A frame's content property is `title`, which is what `textProp=title` below
#  declares and what a bare DSL argument lands in:
#
#      ft-frame name=win " My Window "        # same as title=" My Window "
#
#  It is CONTENT, not chrome, so a borderless frame still paints it — a
#  <fieldset> with border:none still shows its <legend>, and so does this.
#  The title is drawn on the frame's TOP EDGE, and the box reserves that row:
#  with a border the border row IS the title's row, and without one the frame
#  keeps a row of its own for it (`topEdgeProp=title` below, honoured by
#  _ft_inset4). So a title costs no space when a frame has a border — the
#  usual case, and why "a title never affects sizing" was true for as long as
#  a titleless borderless frame was the only other one.
#
#  `text` is NOT a second spelling of the title: the draw used to fall back to
#  `text` when `title` was empty, so a frame painted a title `ft_get title`
#  did not report, and `title=""` uncovered the `text` underneath instead of
#  clearing it.
#
#  Border styling mirrors CSS, mapped onto the Unicode box-drawing block:
#    borderStyle   solid (default) | double | dashed | dotted | heavy | rounded
#                  | none | hidden — ONE vocabulary, shared with ft-table, and
#                  normalized at the write (_ft_border_style in ft-forms.bash),
#                  so ft_get can only answer a keyword this draws. `heavy` and
#                  `rounded` are spellings of borderWidth=thick and
#                  borderRadius=1; `none`/`hidden` remove the border in the box
#                  model, so the frame loses its inset too, exactly as CSS's
#                  used border-width of 0 does. groove/ridge/inset/outset have
#                  no glyphs and normalize to solid, as does a typo.
#    borderWidth   thin | medium (light glyphs) | thick (heavy glyphs) | 0 —
#                  CSS's keywords; a TUI border is always ONE CELL, thickness
#                  is visual weight. double has no heavy variant (ignored). A
#                  <length> only answers "is there a border": 0 removes it (in
#                  the box model, like border-style: none), anything positive
#                  is the one cell that `thin` already names, and that is what
#                  the write normalizes it to.
#    borderRadius 0 (square) | ≥1 → rounded arc corners ╭╮╰╯ (radii >1 clamp to
#                   the one arc glyph — numeric like CSS, so a richer glyph set
#                   could honour them later; a negative one is dropped at the
#                   write, like every other length CSS types [0,∞])
#    borderGlyph  ONE COLUMN, tiled on all four sides and corners. A
#                   double-width glyph would paint twice the box, so a value
#                   that is not exactly one column is dropped at the write.
#  borderRadius is ORTHOGONAL: arc corners combine with any side style
#  (rounded + dashed, rounded + thick, ...). One Unicode limit is honest and
#  unavoidable — arc corners exist ONLY at light weight (there are no heavy or
#  double arc glyphs), so a rounded+thick frame has light-weight corners on
#  heavy sides. Everything is paint-only and degrades to the ASCII fallback
#  glyph set on non-UTF-8 terminals.
#
#  Depends on ft-core.bash and ft-forms.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_FRAME_LOADED:-}" ]] && return 0
_FT_FRAME_LOADED=1

# _ft_border_glyphs NAME → sets BG_H BG_V BG_TL BG_TR BG_BL BG_BR from the
# control's borderStyle/borderWidth/borderRadius (CSS-ish names, glyph-mapped).
_ft_border_glyphs() {           # name
    local name=$1
    # borderGlyph=<glyph> — a DECORATIVE border: tile one glyph (a heart,
    # star, flower, ...) on all four sides and corners. Overrides style/
    # width/radius. Falls back to solid on non-UTF-8 terminals.
    ft_resolved_prop "$name" borderGlyph ""; local deco=$FT_RET
    if [[ -n "$deco" ]] && (( FT_USE_UTF8 )); then
        BG_H=$deco; BG_V=$deco; BG_TL=$deco; BG_TR=$deco; BG_BL=$deco; BG_BR=$deco
        return
    fi
    if (( ! FT_USE_UTF8 )); then
        BG_H=$FT_GLYPH_HORIZONTAL; BG_V=$FT_GLYPH_VERTICAL
        BG_TL=$FT_GLYPH_TOP_LEFT; BG_TR=$FT_GLYPH_TOP_RIGHT; BG_BL=$FT_GLYPH_BOTTOM_LEFT; BG_BR=$FT_GLYPH_BOTTOM_RIGHT
        return
    fi
    ft_resolved_prop "$name" borderStyle solid;  local style=$FT_RET
    ft_resolved_prop "$name" borderWidth thin;   local width=$FT_RET
    ft_resolved_prop "$name" borderRadius 0;  local radius=$FT_RET
    # `heavy` and `rounded` are ft-table's spellings of borderWidth=thick and borderRadius=1,
    # and they are the same property on the same framework, so they mean the same thing here.
    # They are the MORE SPECIFIC statement and win over a width or radius set alongside them —
    # nobody writes borderStyle=rounded borderRadius=0 meaning square. (See _ft_border_style in
    # ft-forms.bash for the one list of keywords, and note that none|hidden cannot reach this
    # function: they take the border away in the box model, before anything is drawn.)
    case $style in
        heavy)   width=thick; style=solid ;;
        rounded) radius=1;    style=solid ;;
    esac
    # borderRadius is a NUMBER of cells, like CSS border-radius: 0 = square corners; any radius
    # ≥ 1 draws the arc corners ╭╮╰╯. Radii > 1 CLAMP to 1 — the terminal's box-drawing set has
    # exactly one arc size — but the API is numeric so a future glyph set (or a custom font) can
    # honour larger radii without an API change. A negative one is not a radius at all and never
    # reaches here: it is dropped at the write like any other `<length [0,∞]>`. (This line used
    # to also accept the literal `true`, which the numeric validation has never let through — a
    # tolerance for a spelling that could not arrive, and a comment promising it worked.)
    local rounded=0
    [[ "$radius" =~ ^[0-9]+$ ]] && (( radius > 0 )) && rounded=1
    # `thin` and `medium` are both one light cell; only `thick` changes the glyph set. A width of
    # 0 cannot arrive either — it removes the border in the box model, so nothing is drawn at all.
    local heavy=0
    [[ "$width" == thick ]] && heavy=1

    if [[ "$style" == double ]]; then      # doubles: sides + square double corners
        BG_H=$'═'; BG_V=$'║'
        if (( rounded )); then BG_TL=$'╭'; BG_TR=$'╮'; BG_BL=$'╰'; BG_BR=$'╯'  # light arcs (no double arc exists)
        else BG_TL=$'╔'; BG_TR=$'╗'; BG_BL=$'╚'; BG_BR=$'╝'; fi
        return
    fi
    # Sides by style + weight. dashed/dotted use the canonical MATCHED
    # horizontal/vertical pairs (same dash count) so the two axes line up:
    #   dashed = triple-dash  ┄ / ┆   (clearly broken, evenly spaced)
    #   dotted = quadruple-dash ┈ / ┊ (finer, reads as dots)
    case "$style" in
        dashed) if (( heavy )); then BG_H=$'┅'; BG_V=$'┇'
                else                 BG_H=$'┄'; BG_V=$'┆'; fi ;;
        dotted) if (( heavy )); then BG_H=$'┉'; BG_V=$'┋'
                else                 BG_H=$'┈'; BG_V=$'┊'; fi ;;
        *)      if (( heavy )); then BG_H=$'━'; BG_V=$'┃'
                else                 BG_H=$'─'; BG_V=$'│'; fi ;;
    esac
    # Corners: radius wins (arc corners, orthogonal to side style) — only
    # light arcs exist in Unicode, so they pair with heavy sides too. Without
    # radius, corner weight follows the sides.
    if (( rounded )); then
        BG_TL=$'╭'; BG_TR=$'╮'; BG_BL=$'╰'; BG_BR=$'╯'
    elif (( heavy )); then
        BG_TL=$'┏'; BG_TR=$'┓'; BG_BL=$'┗'; BG_BR=$'┛'
    else
        BG_TL=$'┌'; BG_TR=$'┐'; BG_BL=$'└'; BG_BR=$'┘'
    fi
}

ft_prototype_frame() {
    # A frame's content is its TITLE (drawn over the top border, never
    # inside) — so its bare-argument/content property is `title`, not text:
    #     ft-frame name=win " My Window "
    ft_prototype extends=ft_control textProp=title topEdgeProp=title defaults="border=true"
    ft_prop_kind_set title layout   # same cheap size-unchanged path text takes
}

_ft_draw_frame() {                       # name
    local name=$1
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local rows=${FT_MEASURED_HEIGHT[$name]:-0} cols=${FT_MEASURED_WIDTH[$name]:-0}
    (( rows < 1 || cols < 1 )) && return

    # THE predicate, not a fourth reading of it. `ft_resolved_prop "$name" border` answered ""
    # for a frame written `border=""`, took the borderless branch, and drew no lines — while
    # _ft_inset4 and _ft_border read that same empty value as "nothing was set" and fell through
    # to the prototype default, reserving the cell anyway. A child sat at (1,1) inside a frame
    # with no border to sit inside. One question, one implementation, and this one also answers for
    # `borderStyle: none`, which the layout now agrees is no border.
    _ft_border "$name"; local bordered=$FT_RET
    ft_resolved_prop "$name" title;  local title=$FT_RET

    _ft_compose_sgr "$name"; local bodysgr=$FT_RET     # body: cascaded bg/fg/weight/decoration
    _ft_color_override "$name" borderColor 38;     local borderfgov=$FT_RET
    local bordersgr="$FT_COLOR_BORDER$borderfgov"          # border is a STRUCTURE (→ ::border later)

    # `pad` is the cell each side that the corner glyphs occupy — one on a bordered frame, none
    # on a borderless one, and the title below is laid out inside what is left.
    local r pad=0
    if (( bordered )); then
        pad=1
        _ft_border_glyphs "$name"
        local inner=$(( cols - 2 ))
        (( inner < 0 )) && inner=0
        local hrule; printf -v hrule '%*s' "$inner" ''; hrule=${hrule// /$BG_H}
        ft_print_at_width "$row"            "$col" "$bordersgr$BG_TL$hrule$BG_TR" "$cols"
        ft_print_at_width $(( row+rows-1 )) "$col" "$bordersgr$BG_BL$hrule$BG_BR" "$cols"

        # Left border + interior fill + right border are contiguous cells on one
        # row, so emit them as a SINGLE positioned write. Three ft_print_at per row meant
        # three printf cursor-moves per interior row — the dominant cost of drawing
        # a large frame (the outer window is ~46 rows). One write per row cuts that
        # threefold; the row string itself is constant, so it is built just once,
        # and its display width is known (cols) so ft_print_at_width skips the ANSI scan.
        ft_fit "" "$inner"
        local rowstr="$bordersgr$BG_V$bodysgr$FT_FIT$bordersgr$BG_V"
        for (( r=1; r<rows-1; r++ )); do
            ft_print_at_width $(( row+r )) "$col" "$rowstr" "$cols"
        done
    else
        ft_fit "" "$cols"
        local fillrow="$bodysgr$FT_FIT"
        for (( r=0; r<rows; r++ )); do ft_print_at_width $(( row+r )) "$col" "$fillrow" "$cols"; done
    fi

    # Centered title over the top border. One space of breathing room is
    # added automatically on each side (so callers write title=Settings, not
    # title=" Settings "). Display-width aware, never touches the corner
    # glyphs, truncated (not shifted) when too long.
    #
    # A TITLE IS CONTENT; THE BORDER IS CHROME. This used to sit past the borderless branch's
    # `return`, so `border=false` silently took the title with it while ft_get went on reporting
    # one — and a <fieldset> with border:none still shows its <legend>. It is drawn last either
    # way, over a top border or over the fill.
    if [[ -n "$title" ]]; then
        title=" $title "
        ft_display_width "$title"; local tw=$FT_DISPLAY_WIDTH
        local maxtw=$(( cols - 2*pad ))
        if (( tw > maxtw )); then
            ft_display_truncate "$title" "$maxtw"; title=$FT_DISPLAY_TRUNCATED; tw=$maxtw
        fi
        local tcol=$(( col + pad + (maxtw - tw) / 2 ))
        ft_print_at "$row" "$tcol" "$FT_COLOR_TITLE$title$FT_COLOR_RESET"
    fi
}
