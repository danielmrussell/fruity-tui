#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  The three costs the span renderer is built on top of.
#
#    1. a function call            — the API is one call per span, so this sets the floor
#    2. appending to a big string  — the frame is assembled by concatenation
#    3. a CACHED cascade lookup    — measured at ~200µs, but array access is only ~1.3µs,
#                                    so where does the rest go?
#
#      bash tools/bench-render-primitives.bash [iterations]
# ─────────────────────────────────────────────────────────────────────────────
set -u
iterations=${1:-20000}

now_microseconds() { local stamp=${EPOCHREALTIME/./}; printf '%s' "$stamp"; }

baseline_microseconds=0
measure() {
    local label=$1 case_function=$2
    local started finished elapsed
    started=$(now_microseconds)
    "$case_function"
    finished=$(now_microseconds)
    elapsed=$(( finished - started - baseline_microseconds ))
    (( elapsed < 0 )) && elapsed=0
    printf '  %-44s %6d ms   %6d ns/op\n' "$label" "$(( elapsed / 1000 ))" "$(( elapsed * 1000 / iterations ))"
}

# ── 1. function call overhead ────────────────────────────────────────────────
do_nothing() { :; }
take_four_arguments() { local a=$1 b=$2 c=$3 d=$4; :; }
take_four_and_assign_global() { FT_RET=$1; }

case_empty_loop()        { local i v; for (( i=0; i<iterations; i++ )); do v=$i; done; }
case_call_empty()        { local i;   for (( i=0; i<iterations; i++ )); do do_nothing; done; }
case_call_with_args()    { local i;   for (( i=0; i<iterations; i++ )); do take_four_arguments 1 2 3 4; done; }
case_call_sets_global()  { local i;   for (( i=0; i<iterations; i++ )); do take_four_and_assign_global 7; done; }
case_call_nested_three() { local i;   for (( i=0; i<iterations; i++ )); do outer_of_three; done; }
inner_of_three()  { FT_RET=1; }
middle_of_three() { inner_of_three; }
outer_of_three()  { middle_of_three; }

# ── 2. string building ───────────────────────────────────────────────────────
case_append_small_string() {
    local i buffer=""
    for (( i=0; i<iterations; i++ )); do buffer+="hello"; done
}
case_append_with_printf_v() {
    local i buffer="" piece
    for (( i=0; i<iterations; i++ )); do printf -v piece '%s' "hello"; buffer+=$piece; done
}
case_append_escape_and_text() {         # what emitting a span looks like
    local i buffer="" row=5 column=10
    for (( i=0; i<iterations; i++ )); do buffer+=$'\e['"$row;$column"$'H\e[38;5;255m'"hello"; done
}

printf 'render primitives — %d iterations\n\n' "$iterations"
started=$(now_microseconds); case_empty_loop; finished=$(now_microseconds)
baseline_microseconds=$(( finished - started ))
printf '  %-44s %6d ms   (subtracted below)\n\n' "empty loop (baseline)" "$(( baseline_microseconds / 1000 ))"

echo "  — function calls (the ft_draw_* API pays one per span) —"
measure "call, no arguments"                case_call_empty
measure "call, four arguments"              case_call_with_args
measure "call, sets FT_RET"                 case_call_sets_global
measure "three nested calls"                case_call_nested_three
echo
echo "  — building the frame string —"
measure "append 5 chars to a growing buffer" case_append_small_string
measure "append via printf -v then +="       case_append_with_printf_v
measure "append a positioned, styled span"   case_append_escape_and_text
