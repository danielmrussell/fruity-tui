#!/usr/bin/env bash
# What does a CACHED style lookup actually cost, and what is it made of?
# The span design claims per-frame computed-style memoisation is the biggest available
# win, on the basis that ft_style costs ~200µs even on a cache hit. Verify that.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/fruity-tui.bash"
ft_init 2>/dev/null
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_ROWS=40; FT_COLS=118

iterations=${1:-5000}
now_microseconds() { local stamp=${EPOCHREALTIME/./}; printf '%s' "$stamp"; }

ft_stylesheet name=bench style='
    #specimen { color: 202; background-color: 234; font-weight: bold; }
    textfield { border-color: 250; }
'
FT_TYPE[specimen]=textfield; FT_PARENT[specimen]=""
ft_style specimen color >/dev/null          # warm the cache

baseline=0
measure() {
    local label=$1 case_function=$2 started finished elapsed
    started=$(now_microseconds); "$case_function"; finished=$(now_microseconds)
    elapsed=$(( finished - started - baseline ))
    (( elapsed < 0 )) && elapsed=0
    printf '  %-44s %6d ms   %6d ns/op\n' "$label" "$(( elapsed / 1000 ))" "$(( elapsed * 1000 / iterations ))"
}

case_empty_loop()    { local i v; for (( i=0; i<iterations; i++ )); do v=$i; done; }
case_style_cached()  { local i;   for (( i=0; i<iterations; i++ )); do ft_style specimen color; done; }
case_query_cached()  { local i;   for (( i=0; i<iterations; i++ )); do _ft_css_query specimen color app; done; }
case_raw_prop_read() { local i;   for (( i=0; i<iterations; i++ )); do _ft_get_raw specimen color; done; }
case_compose_sgr()   { local i;   for (( i=0; i<iterations; i++ )); do _ft_compose_sgr specimen; done; }

printf 'cascade cost — %d iterations\n\n' "$iterations"
s=$(now_microseconds); case_empty_loop; f=$(now_microseconds); baseline=$(( f - s ))
printf '  %-44s %6d ms   (subtracted below)\n\n' "empty loop (baseline)" "$(( baseline / 1000 ))"

measure "ft_style (cache hit)"                 case_style_cached
measure "_ft_css_query (cache hit)"            case_query_cached
measure "_ft_get_raw (one prop read)"          case_raw_prop_read
measure "_ft_compose_sgr (a paint does this)"  case_compose_sgr
