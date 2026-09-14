#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Where does layout actually spend its time?
#
#  A page rebuild costs well over a second, and layout is believed to be ~4ms per
#  control — but "believed" has been wrong twice this week (a cached style lookup was
#  30µs, not 200µs; integer array keys were slower, not faster). So: measure the four
#  passes separately, and measure the primitives they lean on, before designing a cache.
#
#      bash tools/bench-layout.bash [repeats]
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export FT_NO_WTFIX=1
without_run_loop="$here/demo/.bench-layout-demo.bash"
sed '/^ft-run app/d' "$here/demo/css-demo.bash" > "$without_run_loop"
source "$without_run_loop"
rm -f "$without_run_loop"
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_ROWS=40; FT_COLS=118

repeats=${1:-10}
now_microseconds() { local stamp=${EPOCHREALTIME/./}; printf '%s' "$stamp"; }

measure() {                     # label command…
    local label=$1; shift
    local started finished index
    started=$(now_microseconds)
    for (( index = 0; index < repeats; index++ )); do "$@" >/dev/null 2>&1; done
    finished=$(now_microseconds)
    local microseconds_each=$(( (finished - started) / repeats ))
    printf '  %-40s %6d.%03d ms\n' "$label" "$(( microseconds_each / 1000 ))" "$(( microseconds_each % 1000 ))"
}

count_controls() {
    local node=$1 child
    control_count=$(( control_count + 1 ))
    for child in ${FT_KIDS[$node]:-}; do count_controls "$child"; done
}

PAGE=1; STEP=1; _show_page >/dev/null 2>&1
FT_ROOT=app
control_count=0; count_controls app

printf 'layout — page 1, %d controls, averaged over %d runs\n\n' "$control_count" "$repeats"

measure "ft_layout (everything)"          ft_layout app
measure "  ft_measure (passes 1-3)"       ft_measure app
measure "  _ft_pass_pref   (pass 1)"      _ft_pass_pref app
measure "  _ft_pass_width  (pass 2)"      _ft_pass_width app
measure "  _ft_pass_height (pass 3)"      _ft_pass_height app
measure "  _ft_pass_arrange (pass 4)"     _ft_pass_arrange app 0 0

echo
echo "  primitives the passes lean on:"
measure "ft_resolved_prop (one property, inherits)" ft_resolved_prop spec width
measure "_ft_get_raw (one property, raw)"   _ft_get_raw spec width
measure "ft_display_width (a short string)" ft_display_width "The quick brown fox"
measure "ft_wrap (the specimen text, w=44)" ft_wrap "$SPEC" 44
