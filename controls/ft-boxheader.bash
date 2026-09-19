#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — controls/ft-boxheader.bash
#
#  BOXHEADER — a tight 3-row boxed section label, the "major section" banner:
#
#      ┌────────────────────────────┐
#      │ Interface Wildcards        │
#      └────────────────────────────┘
#
#      ft-boxheader name=hdr text="Interface Wildcards"
#      ft-boxheader name=hdr "Interface Wildcards"      # bare content → text=
#
#  A block leaf, exactly 3 rows tall, never a focus stop. Colours resolve through
#  the cascade: `boxheader { … }` / `#hdr { … }` style the LABEL, and
#  `boxheader::border { … }` styles the surrounding rule. With no stylesheet the
#  theme roles FT_COLOR_BOX_TEXT / FT_COLOR_BOX_LINE are the fallbacks.
#
#  Depends on ft-core.bash and ft-forms.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_BOXHEADER_LOADED:-}" ]] && return 0
_FT_BOXHEADER_LOADED=1

ft_prototype_boxheader() {
    ft_prototype extends=ft_control focusable=false \
        defaults="display=block text="
}

ft-boxheader() { ft_new boxheader "$@"; }

_ft_height_boxheader() { FT_RET=3; }    # top rule + label row + bottom rule

_ft_draw_boxheader() {          # name
    local name=$1
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local cols=${FT_MEASURED_WIDTH[$name]:-0}
    (( cols < 3 )) && return                 # no room for ┌ + a cell + ┐

    ft_resolved_prop "$name" text ""; local text=$FT_RET
    local inner=$(( cols - 2 ))
    ft_hrule "$inner"
    # Capture each immediately — both helpers land in FT_RET.
    _ft_css_pe_or   "$name" border "$FT_COLOR_BOX_LINE"; local lsgr=$FT_RET   # boxheader::border
    _ft_compose_sgr "$name"        "$FT_COLOR_BOX_TEXT"; local xsgr=$FT_RET   # boxheader (label)

    ft_print_at "$row"       "$col" "$lsgr$FT_GLYPH_TOP_LEFT$FT_HRULE$FT_GLYPH_TOP_RIGHT$FT_COLOR_RESET"
    ft_fit " $text" "$inner"
    ft_print_at $(( row+1 )) "$col" "$lsgr$FT_GLYPH_VERTICAL$xsgr$FT_FIT$lsgr$FT_GLYPH_VERTICAL$FT_COLOR_RESET"
    ft_print_at $(( row+2 )) "$col" "$lsgr$FT_GLYPH_BOTTOM_LEFT$FT_HRULE$FT_GLYPH_BOTTOM_RIGHT$FT_COLOR_RESET"
}
