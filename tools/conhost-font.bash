#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tools/conhost-font.bash — make the classic Windows console (conhost) render
#  the glyphs Fruity TUI draws with.
#
#      bash tools/conhost-font.bash            # status + a glyph probe
#      bash tools/conhost-font.bash probe      # just the glyph probe
#      bash tools/conhost-font.bash apply      # pin Consolas + UTF-8 (new windows)
#      bash tools/conhost-font.bash restore    # put your originals back
#
#  The probe is the point: run it in the console that looks wrong and READ it. It
#  prints the exact glyphs the library draws with, grouped by what they are for.
#  Whichever group comes out as boxes/blanks tells you what the font is missing —
#  that is a font gap, not a Unicode gap, and `apply` fixes it.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/ft-conhostfix.bash"

_probe() {
    printf '\n── glyph probe ─ each row should show SHAPES, not boxes or blanks ──\n\n'
    printf '  light box   (borders, always used)   %b\n' '\xe2\x94\x8c\xe2\x94\x80\xe2\x94\x90 \xe2\x94\x82 \xe2\x94\x94\xe2\x94\x80\xe2\x94\x98 \xe2\x94\x9c\xe2\x94\xbc\xe2\x94\xa4'
    printf '  HEAVY box   (the shimmer/thick)      %b\n' '\xe2\x94\x8f\xe2\x94\x81\xe2\x94\x93 \xe2\x94\x83 \xe2\x94\x97\xe2\x94\x81\xe2\x94\x9b'
    printf '  blocks      (scrollbar thumbs)       %b\n' '\xe2\x96\x8a \xe2\x96\x89 \xe2\x96\x88 \xe2\x96\x80 \xe2\x96\x84 \xe2\x96\x8c'
    printf '  dashed      (border styles)          %b\n' '\xe2\x94\x84\xe2\x94\x86 \xe2\x94\x88\xe2\x94\x8a'
    printf '  arrows/misc (trees, wrap marks)      %b\n' '\xe2\x96\xb8 \xe2\x96\xbe \xe2\x86\xa9 \xe2\x80\xa6 \xe2\x97\x8f\xe2\x97\x8b'
    printf '\n  If ONLY the HEAVY row is broken, your console font is almost certainly\n'
    printf '  Lucida Console: it has light box drawing but no heavy set. `apply` fixes it.\n\n'
    printf '── environment ──\n'
    printf '  TERM=%s  WT_SESSION=%s\n' "${TERM:-?}" "${WT_SESSION:-<unset — so NOT Windows Terminal>}"
    printf '  LC_ALL=%s  LANG=%s\n' "${LC_ALL:-<unset>}" "${LANG:-<unset>}"
    if [[ -f "$here/ft-core.bash" ]]; then
        ( source "$here/ft-core.bash" 2>/dev/null; ft_setup_locale 2>/dev/null
          printf '  FT_USE_UTF8=%s (0 would mean we fall back to ASCII borders)\n' "${FT_USE_UTF8:-?}" )
    fi
}

case "${1:-status}" in
    status)
        ft_ch_status; printf '%s\n' "$FT_RET"; _probe ;;
    probe)
        _probe ;;
    apply)
        ft_ch_apply || { printf '%s\n' "$FT_RET"; exit 1; }
        printf '%s\n' "$FT_RET" ;;
    restore)
        ft_ch_restore || { printf '%s\n' "$FT_RET"; exit 1; }
        printf '%s\n' "$FT_RET" ;;
    *)
        printf 'usage: %s [status|probe|apply|restore]\n' "${0##*/}"; exit 2 ;;
esac
