#!/usr/bin/env bash
# Measure the framework's OWN opinion of every candidate glyph's display width.
# ft_display_width is the authority this project believes (see the header note in
# ft-core.bash); intuition is not.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "$here/ft-core.bash"
ft_setup_locale 2>/dev/null

_row() {                        # label  glyphs…
    local label=$1; shift
    local g bad=0 n=0 widths=""
    for g in "$@"; do
        ft_display_width "$g"
        widths+="$FT_DISPLAY_WIDTH"
        (( n++ ))
        (( FT_DISPLAY_WIDTH != 1 )) && (( bad++ ))
    done
    printf '  %-34s n=%-4d all-one-column=%s  %s\n' "$label" "$n" \
        "$( (( bad == 0 )) && echo yes || echo "NO ($bad wrong)" )" "$*"
}

printf 'FT_USE_UTF8=%s\n\n' "${FT_USE_UTF8:-?}"

_row "box diagonals"      ╱ ╲ ╳
_row "quadrants"          ▘ ▝ ▖ ▗ ▚ ▞ ▙ ▟ ▛ ▜ ▀ ▄ ▌ ▐ █
_row "left eighths"       ▏ ▎ ▍ ▌ ▋ ▊ ▉ █
_row "lower eighths"      ▁ ▂ ▃ ▄ ▅ ▆ ▇ █
_row "shades"             ░ ▒ ▓
_row "triangles (corner)" ◢ ◣ ◤ ◥
_row "triangles (big)"    ▲ ▶ ▼ ◀ △ ▷ ▽ ◁
_row "sextants (sample)"  🬀 🬁 🬂 🬃 🬄 🬅 🬆
_row "octants (sample)"   𜺠 𜺡 𜺢
_row "braille (sample)"   ⠁ ⠃ ⠇ ⡇ ⣿ ⢰ ⠔ ⣀ ⠉ ⠘ ⠸ ⢸

# the full braille block, all 256
brl=()
for ((i=0x2800;i<=0x28FF;i++)); do printf -v c '\\U%08x' "$i"; printf -v c "$c"; brl+=("$c"); done
_row "braille (all 256)" "${brl[@]}" >/dev/null 2>&1
bad=0
for c in "${brl[@]}"; do ft_display_width "$c"; (( FT_DISPLAY_WIDTH != 1 )) && (( bad++ )); done
printf '  %-34s n=256  all-one-column=%s\n' "braille (all 256)" "$( (( bad == 0 )) && echo yes || echo "NO ($bad)" )"

# and the whole legacy-computing sextant block
sx=()
for ((i=0x1FB00;i<=0x1FB3B;i++)); do printf -v c '\\U%08x' "$i"; printf -v c "$c"; sx+=("$c"); done
bad=0
for c in "${sx[@]}"; do ft_display_width "$c"; (( FT_DISPLAY_WIDTH != 1 )) && (( bad++ )); done
printf '  %-34s n=60   all-one-column=%s\n' "sextants (all 60)" "$( (( bad == 0 )) && echo yes || echo "NO ($bad)" )"

printf '\n-- the known trap, for contrast --\n'
_row "U+2612 (rejected yesterday)" ☒
_row "CJK / emoji"                 世 🙂
