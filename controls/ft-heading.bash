#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — controls/ft-heading.bash
#
#  HEADING — a single-row heading bar filling its box, for titling a region that
#  does not warrant the 3-row ft-boxheader banner:
#
#      ft-heading name=h text="Advanced"
#      ft-heading name=h "Advanced"          # bare content → text=
#
#  A block leaf, exactly 1 row tall, never a focus stop. Colours resolve through
#  the cascade: `heading { … }` / `#h { … }`. With no stylesheet the theme role
#  FT_COLOR_HEADING is the fallback.
#
#  Depends on ft-core.bash and ft-forms.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_HEADING_LOADED:-}" ]] && return 0
_FT_HEADING_LOADED=1

ft_prototype_heading() {
    ft_prototype extends=ft_control focusable=false \
        defaults="display=block text="
}

ft-heading() { ft_new heading "$@"; }

_ft_height_heading() { FT_RET=1; }

_ft_draw_heading() {            # name
    local name=$1
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local cols=${FT_MEASURED_WIDTH[$name]:-0}
    (( cols < 1 )) && return

    ft_resolved_prop "$name" text ""; local text=$FT_RET
    _ft_compose_sgr "$name" "$FT_COLOR_HEADING"; local hsgr=$FT_RET
    # Full-width coloured row: hand ft_print_at_width the known display width so it skips
    # ft_print_at's byte-length clip test (which would force an ANSI scan).
    ft_fit " $text" "$cols"
    ft_print_at_width "$row" "$col" "$hsgr$FT_FIT$FT_COLOR_RESET" "$cols"
}
