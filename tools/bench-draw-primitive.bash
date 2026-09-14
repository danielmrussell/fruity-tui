#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Should the two draw primitives be one function?
#
#  The framework paints through two nearly identical functions: ft_print_at, which
#  measures the string it is given, and ft_print_at_width, whose caller already
#  knows the display width and so skips the measuring scan. Two names for one idea
#  is a smell, and merging them behind an optional fourth argument costs ONE branch
#  on the hottest path in the framework. This prices that branch against a real
#  frame — and, as it turned out, answers a better question than the one asked.
#
#  It reports, in order:
#    1. how many draw calls a real page build and a real repaint make;
#    2. what the busiest repaint and the busiest page build cost end to end;
#    3. what ONE arithmetic test costs inside the primitive — the calibration, and
#       the bench's TEETH: a variant doing exactly one more arithmetic test than
#       ft_print_at_width, which can never change the answer, MUST measure slower.
#       A second canary times a byte-identical COPY of ft_print_at_width under
#       another name; it must measure the SAME. Between them they bound what a
#       difference here is worth believing;
#    4. what the merged forms cost against the split ones they would replace;
#    5. what the width fast path itself is worth, which is the number that decided
#       it: 44 µs against 368 µs for the same coloured row. The two calls are not
#       one operation with an optional detail — see ft-core.bash.
#
#  Variants are timed INTERLEAVED (a,b,c,a,b,c…), never in blocks, so a machine
#  that drifts mid-run cannot charge the drift to one candidate; the report gives
#  the median and the min–max spread of every sweep.
#
#  EVERY VARIANT CARRIES THE BLOCK RECORDER, and every loop empties it. The primitives append
#  to FT_BLOCK_BEING_DRAWN as well as to FT_OUT (the retained display list), so a copy without
#  that line is not a copy — it would hand the recorder's cost to whichever variant has it —
#  and a loop that resets FT_OUT but not the recorder lets a 2,000-iteration sweep grow one
#  string until the appends themselves drift: measured, ft_print_at_width read 68µs on its
#  first call and 2.2ms on its last, with the canary steady at 44µs beside it.
#
#  EVERY CASE IS A NO-ARGUMENT FUNCTION holding its own literal arguments. An
#  earlier draft passed "fn args…" as one packed string and let word-splitting
#  unpack it — which tore the SGR escapes out of the coloured row, so the
#  known-width variants were timed erroring on a fragment of their own argument.
#  The numbers looked plausible (they were 2× the truth) and only a line on stderr
#  gave it away. Pass arguments, not strings that look like arguments.
#
#      bash tools/bench-draw-primitive.bash [iterations] [repeats]
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export FT_NO_WTFIX=1
without_run_loop="$here/demo/.bench-draw-demo.bash"
sed '/^ft-run app/d' "$here/demo/css-demo.bash" > "$without_run_loop"
source "$without_run_loop"
rm -f "$without_run_loop"
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_ROWS=40; FT_COLS=118

iterations=${1:-12000}
repeats=${2:-9}
now_microseconds() { local stamp=${EPOCHREALTIME/./}; printf '%s' "$stamp"; }

# ── 1. how many calls do a real page build and a real repaint make? ──────────
eval "$(declare -f ft_print_at       | sed '1s/^ft_print_at/_real_print_at/')"
eval "$(declare -f ft_print_at_width | sed '1s/^ft_print_at_width/_real_print_at_width/')"
PRINT_AT_CALLS=0; PRINT_AT_WIDTH_CALLS=0
ft_print_at()       { (( PRINT_AT_CALLS++ ));       _real_print_at       "$@"; }
ft_print_at_width() { (( PRINT_AT_WIDTH_CALLS++ )); _real_print_at_width "$@"; }

PAGE=1; STEP=1; _show_page >/dev/null 2>&1
FT_ROOT=app
ft_redraw_all >/dev/null 2>&1                       # warm

printf 'draw primitive — css-demo at %sx%s\n\n' "$FT_COLS" "$FT_ROWS"
echo "  — how much painting actually happens —"
busiest_repaint=0 busiest_repaint_plain=0 busiest_repaint_width=0 busiest_repaint_page=1
busiest_build=0
for page in 1 2 3 4 5 6 7 8 9 10; do
    PAGE=$page; STEP=1
    PRINT_AT_CALLS=0; PRINT_AT_WIDTH_CALLS=0
    _show_page >/dev/null 2>&1                      # a page BUILD: layout + full paint
    build_plain=$PRINT_AT_CALLS build_width=$PRINT_AT_WIDTH_CALLS
    (( build_plain + build_width > busiest_build )) && busiest_build=$(( build_plain + build_width ))
    PRINT_AT_CALLS=0; PRINT_AT_WIDTH_CALLS=0
    ft_redraw_all >/dev/null 2>&1                   # a repaint of that page
    printf '    page %-2s   build %4d calls (%3d + %3d)     repaint %4d calls (%3d + %3d)\n' \
        "$page" "$(( build_plain + build_width ))" "$build_plain" "$build_width" \
        "$(( PRINT_AT_CALLS + PRINT_AT_WIDTH_CALLS ))" "$PRINT_AT_CALLS" "$PRINT_AT_WIDTH_CALLS"
    if (( PRINT_AT_CALLS + PRINT_AT_WIDTH_CALLS > busiest_repaint )); then
        busiest_repaint=$(( PRINT_AT_CALLS + PRINT_AT_WIDTH_CALLS ))
        busiest_repaint_plain=$PRINT_AT_CALLS
        busiest_repaint_width=$PRINT_AT_WIDTH_CALLS
        busiest_repaint_page=$page
    fi
done

# put the real ones back before timing anything
eval "$(declare -f _real_print_at       | sed '1s/^_real_print_at/ft_print_at/')"
eval "$(declare -f _real_print_at_width | sed '1s/^_real_print_at_width/ft_print_at_width/')"
unset -f _real_print_at _real_print_at_width

PAGE=$busiest_repaint_page; STEP=1; _show_page >/dev/null 2>&1
started=$(now_microseconds)
for (( i = 0; i < 20; i++ )); do ft_redraw_all >/dev/null 2>&1; done
finished=$(now_microseconds)
repaint_microseconds=$(( (finished - started) / 20 ))
printf '\n  busiest repaint: page %s — %d calls (%d + %d) in %d.%03d ms\n' \
    "$busiest_repaint_page" "$busiest_repaint" "$busiest_repaint_plain" "$busiest_repaint_width" \
    "$(( repaint_microseconds / 1000 ))" "$(( repaint_microseconds % 1000 ))"
PAGE=9; STEP=1
started=$(now_microseconds)
for (( i = 0; i < 5; i++ )); do _show_page >/dev/null 2>&1; done
finished=$(now_microseconds)
build_microseconds=$(( (finished - started) / 5 ))
printf '  busiest page build: %d calls in %d.%03d ms\n\n' "$busiest_build" \
    "$(( build_microseconds / 1000 ))" "$(( build_microseconds % 1000 ))"

# ── the candidate merged forms ───────────────────────────────────────────────
# Three ways to ask "did the caller give me a width?": a fourth local tested by
# length, the argument count, and a test on the positional itself.
merged_on_local_length() {
    local row=$1 col=$2 s=$3 w=${4-}
    (( row < FT_CLIP_R0 || row > FT_CLIP_R1 || col > FT_CLIP_C1 || col < FT_CLIP_C0 )) && return 0
    if (( ${#w} )); then
        if (( col + w - 1 > FT_CLIP_C1 )); then
            ft_display_truncate "$s" $(( FT_CLIP_C1 - col + 1 )); s="$FT_DISPLAY_TRUNCATED"$'\e[0m'
        fi
    else
        [[ "$s" == *$'\t'* ]] && { ft_expand_tabs "$s"; s=$FT_RET; }
        if (( col + ${#s} > FT_CLIP_C1 )); then
            local maxw=$(( FT_CLIP_C1 - col + 1 ))
            ft_display_width "$s"
            if (( FT_DISPLAY_WIDTH > maxw )); then ft_display_truncate "$s" "$maxw"; s="$FT_DISPLAY_TRUNCATED"$'\e[0m'; fi
        fi
    fi
    printf -v FT_CURSOR_POSITION '\e[%d;%dH' "$(( row + 1 ))" "$(( col + 1 ))"
    FT_OUT+="$FT_CURSOR_POSITION$s"
    FT_BLOCK_BEING_DRAWN+="$FT_CURSOR_POSITION$s"
}
merged_on_argument_count() {
    local row=$1 col=$2 s=$3
    (( row < FT_CLIP_R0 || row > FT_CLIP_R1 || col > FT_CLIP_C1 || col < FT_CLIP_C0 )) && return 0
    if (( $# > 3 )); then
        if (( col + $4 - 1 > FT_CLIP_C1 )); then
            ft_display_truncate "$s" $(( FT_CLIP_C1 - col + 1 )); s="$FT_DISPLAY_TRUNCATED"$'\e[0m'
        fi
    else
        [[ "$s" == *$'\t'* ]] && { ft_expand_tabs "$s"; s=$FT_RET; }
        if (( col + ${#s} > FT_CLIP_C1 )); then
            local maxw=$(( FT_CLIP_C1 - col + 1 ))
            ft_display_width "$s"
            if (( FT_DISPLAY_WIDTH > maxw )); then ft_display_truncate "$s" "$maxw"; s="$FT_DISPLAY_TRUNCATED"$'\e[0m'; fi
        fi
    fi
    printf -v FT_CURSOR_POSITION '\e[%d;%dH' "$(( row + 1 ))" "$(( col + 1 ))"
    FT_OUT+="$FT_CURSOR_POSITION$s"
    FT_BLOCK_BEING_DRAWN+="$FT_CURSOR_POSITION$s"
}
merged_on_positional_test() {
    local row=$1 col=$2 s=$3
    (( row < FT_CLIP_R0 || row > FT_CLIP_R1 || col > FT_CLIP_C1 || col < FT_CLIP_C0 )) && return 0
    if [[ -n "${4-}" ]]; then
        if (( col + $4 - 1 > FT_CLIP_C1 )); then
            ft_display_truncate "$s" $(( FT_CLIP_C1 - col + 1 )); s="$FT_DISPLAY_TRUNCATED"$'\e[0m'
        fi
    else
        [[ "$s" == *$'\t'* ]] && { ft_expand_tabs "$s"; s=$FT_RET; }
        if (( col + ${#s} > FT_CLIP_C1 )); then
            local maxw=$(( FT_CLIP_C1 - col + 1 ))
            ft_display_width "$s"
            if (( FT_DISPLAY_WIDTH > maxw )); then ft_display_truncate "$s" "$maxw"; s="$FT_DISPLAY_TRUNCATED"$'\e[0m'; fi
        fi
    fi
    printf -v FT_CURSOR_POSITION '\e[%d;%dH' "$(( row + 1 ))" "$(( col + 1 ))"
    FT_OUT+="$FT_CURSOR_POSITION$s"
    FT_BLOCK_BEING_DRAWN+="$FT_CURSOR_POSITION$s"
}
# THE CALIBRATION AND THE BENCH'S TEETH (see the header): one more arithmetic
# test than ft_print_at_width, and one that can never change the answer.
width_plus_one_test() {
    local row=$1 col=$2 s=$3 w=$4
    (( row < FT_CLIP_R0 || row > FT_CLIP_R1 || col > FT_CLIP_C1 || col < FT_CLIP_C0 )) && return 0
    (( w < -1 )) && return 0
    if (( col + w - 1 > FT_CLIP_C1 )); then
        ft_display_truncate "$s" $(( FT_CLIP_C1 - col + 1 )); s="$FT_DISPLAY_TRUNCATED"$'\e[0m'
    fi
    printf -v FT_CURSOR_POSITION '\e[%d;%dH' "$(( row + 1 ))" "$(( col + 1 ))"
    FT_OUT+="$FT_CURSOR_POSITION$s"
    FT_BLOCK_BEING_DRAWN+="$FT_CURSOR_POSITION$s"
}
# THE SAFETY QUESTION, priced. The two functions do not merely differ in whether
# they measure: ft_print_at guards against a TAB reaching the terminal (it is the
# last gate before bytes go out) and ft_print_at_width is deliberately exempt,
# because its callers build their row through ft_fit, which has already expanded.
# A merged function with an optional width silently turns that guard off for
# anyone who passes one. Keeping the guard on both paths removes the asymmetry —
# this is what that costs.
width_plus_tab_guard() {
    local row=$1 col=$2 s=$3 w=$4
    (( row < FT_CLIP_R0 || row > FT_CLIP_R1 || col > FT_CLIP_C1 || col < FT_CLIP_C0 )) && return 0
    [[ "$s" == *$'\t'* ]] && { ft_expand_tabs "$s"; s=$FT_RET; }
    if (( col + w - 1 > FT_CLIP_C1 )); then
        ft_display_truncate "$s" $(( FT_CLIP_C1 - col + 1 )); s="$FT_DISPLAY_TRUNCATED"$'\e[0m'
    fi
    printf -v FT_CURSOR_POSITION '\e[%d;%dH' "$(( row + 1 ))" "$(( col + 1 ))"
    FT_OUT+="$FT_CURSOR_POSITION$s"
    FT_BLOCK_BEING_DRAWN+="$FT_CURSOR_POSITION$s"
}
# The other canary: a byte-identical copy of ft_print_at_width under another name.
width_identical_copy() {
    local row=$1 col=$2 s=$3 w=$4
    (( row < FT_CLIP_R0 || row > FT_CLIP_R1 || col > FT_CLIP_C1 || col < FT_CLIP_C0 )) && return 0
    if (( col + w - 1 > FT_CLIP_C1 )); then
        ft_display_truncate "$s" $(( FT_CLIP_C1 - col + 1 )); s="$FT_DISPLAY_TRUNCATED"$'\e[0m'
    fi
    printf -v FT_CURSOR_POSITION '\e[%d;%dH' "$(( row + 1 ))" "$(( col + 1 ))"
    FT_OUT+="$FT_CURSOR_POSITION$s"
    FT_BLOCK_BEING_DRAWN+="$FT_CURSOR_POSITION$s"
}

# ── realistic arguments ──────────────────────────────────────────────────────
# The width path exists for a colour-coded full-width row: SGR escapes inflate
# the byte count, so ft_print_at's cheap clip test always fires and forces a scan.
printf -v pad '%*s' 100 ''
WIDE_ROW=$'\e[48;5;236m\e[38;5;252m'"$pad"$'\e[0m'
SHORT_TEXT="Save changes"
FT_CLIP_R0=0; FT_CLIP_R1=39; FT_CLIP_C0=0; FT_CLIP_C1=117

_time_it() { local started=${EPOCHREALTIME/./}; "$@"; RESULT=$(( ${EPOCHREALTIME/./} - started )); }

width_today()      { local i; for (( i=0; i<iterations; i++ )); do FT_OUT=""; FT_BLOCK_BEING_DRAWN=""; ft_print_at_width        5 2 "$WIDE_ROW" 100; done; }
width_twin()       { local i; for (( i=0; i<iterations; i++ )); do FT_OUT=""; FT_BLOCK_BEING_DRAWN=""; width_identical_copy     5 2 "$WIDE_ROW" 100; done; }
width_calibrate()  { local i; for (( i=0; i<iterations; i++ )); do FT_OUT=""; FT_BLOCK_BEING_DRAWN=""; width_plus_one_test      5 2 "$WIDE_ROW" 100; done; }
width_tab_guard()  { local i; for (( i=0; i<iterations; i++ )); do FT_OUT=""; FT_BLOCK_BEING_DRAWN=""; width_plus_tab_guard     5 2 "$WIDE_ROW" 100; done; }
width_merge_len()  { local i; for (( i=0; i<iterations; i++ )); do FT_OUT=""; FT_BLOCK_BEING_DRAWN=""; merged_on_local_length   5 2 "$WIDE_ROW" 100; done; }
width_merge_argc() { local i; for (( i=0; i<iterations; i++ )); do FT_OUT=""; FT_BLOCK_BEING_DRAWN=""; merged_on_argument_count 5 2 "$WIDE_ROW" 100; done; }
width_merge_test() { local i; for (( i=0; i<iterations; i++ )); do FT_OUT=""; FT_BLOCK_BEING_DRAWN=""; merged_on_positional_test 5 2 "$WIDE_ROW" 100; done; }
# WHAT THE FAST PATH IS WORTH: the same coloured row through ft_print_at, which
# must scan it per character because the SGR bytes push its cheap length test
# over the clip. This is the saving any merge branch must be small against.
width_via_scan()   { local i; for (( i=0; i<iterations; i++ )); do FT_OUT=""; FT_BLOCK_BEING_DRAWN=""; ft_print_at              5 2 "$WIDE_ROW"; done; }

plain_today()      { local i; for (( i=0; i<iterations; i++ )); do FT_OUT=""; FT_BLOCK_BEING_DRAWN=""; ft_print_at              5 2 "$SHORT_TEXT"; done; }
plain_merge_len()  { local i; for (( i=0; i<iterations; i++ )); do FT_OUT=""; FT_BLOCK_BEING_DRAWN=""; merged_on_local_length   5 2 "$SHORT_TEXT"; done; }
plain_merge_argc() { local i; for (( i=0; i<iterations; i++ )); do FT_OUT=""; FT_BLOCK_BEING_DRAWN=""; merged_on_argument_count 5 2 "$SHORT_TEXT"; done; }
plain_merge_test() { local i; for (( i=0; i<iterations; i++ )); do FT_OUT=""; FT_BLOCK_BEING_DRAWN=""; merged_on_positional_test 5 2 "$SHORT_TEXT"; done; }

declare -A NANOSECONDS=()
run_group() {                   # group-label  case-fn:label…
    local group=$1; shift
    local -a fns=() labels=()
    local spec
    for spec in "$@"; do fns+=("${spec%%:*}"); labels+=("${spec#*:}"); done
    local n=${#fns[@]} r k
    local -a samples=(); for (( k=0; k<n; k++ )); do samples[k]=""; done
    for (( r = 0; r < repeats; r++ )); do
        for (( k = 0; k < n; k++ )); do _time_it "${fns[k]}"; samples[k]+=" $RESULT"; done
    done
    echo "  — $group —"
    for (( k = 0; k < n; k++ )); do
        local -a sorted; readarray -t sorted < <(printf '%s\n' ${samples[k]} | sort -n)
        local med=${sorted[$(( ${#sorted[@]} / 2 ))]} lo=${sorted[0]} hi=${sorted[-1]}
        printf '    %-42s %7d ns/call   [%d–%d]\n' "${labels[k]}" \
            "$(( med * 1000 / iterations ))" "$(( lo * 1000 / iterations ))" "$(( hi * 1000 / iterations ))"
        NANOSECONDS[${fns[k]}]=$(( med * 1000 / iterations ))
    done
}

run_group "the KNOWN-WIDTH path (a full-width coloured row)" \
    "width_today:ft_print_at_width (today)" \
    "width_twin:identical copy of it (canary)" \
    "width_calibrate:it + one arithmetic test (calib)" \
    "width_merge_len:merged, dispatch on \${#w}" \
    "width_merge_argc:merged, dispatch on \$#" \
    "width_merge_test:merged, dispatch on [[ -n \$4 ]]" \
    "width_tab_guard:it + ft_print_at's tab guard" \
    "width_via_scan:ft_print_at on the same row"
echo
run_group "the MEASURING path (a short plain string)" \
    "plain_today:ft_print_at (today)" \
    "plain_merge_len:merged, dispatch on \${#w}" \
    "plain_merge_argc:merged, dispatch on \$#" \
    "plain_merge_test:merged, dispatch on [[ -n \$4 ]]"

echo
echo "  — the verdict —"
printf '    canary  : two identical bodies differ by %+6d ns   ← the noise floor\n' \
    "$(( NANOSECONDS[width_twin] - NANOSECONDS[width_today] ))"
printf '    calibrn : one arithmetic test costs      %+6d ns\n' \
    "$(( NANOSECONDS[width_calibrate] - NANOSECONDS[width_today] ))"
printf '    the tab guard on the width path costs    %+6d ns/call\n' \
    "$(( NANOSECONDS[width_tab_guard] - NANOSECONDS[width_today] ))"
printf '    THE WIDTH FAST PATH ITSELF SAVES         %6d ns/call — %d.%03d ms over a %d-call page build\n\n' \
    "$(( NANOSECONDS[width_via_scan] - NANOSECONDS[width_today] ))" \
    "$(( (NANOSECONDS[width_via_scan] - NANOSECONDS[width_today]) * busiest_build / 1000000 ))" \
    "$(( ((NANOSECONDS[width_via_scan] - NANOSECONDS[width_today]) * busiest_build / 1000) % 1000 ))" \
    "$busiest_build"
report() {                      # label  Δwidth  Δplain
    local total=$(( $2 * busiest_repaint_width + $3 * busiest_repaint_plain ))
    local build=$(( ($2 + $3) * busiest_build / 2 ))
    printf '    merge on %-6s %+6d ns/width %+6d ns/plain → repaint %+d.%03d ms (%d%%), page build %+d.%03d ms (%d%%)\n' \
        "$1" "$2" "$3" "$(( total / 1000000 ))" "$(( (total / 1000) % 1000 ))" \
        "$(( total / 10 / repaint_microseconds ))" \
        "$(( build / 1000000 ))" "$(( (build / 1000) % 1000 ))" \
        "$(( build / 10 / build_microseconds ))"
}
report '${#w}'  "$(( NANOSECONDS[width_merge_len]  - NANOSECONDS[width_today] ))" "$(( NANOSECONDS[plain_merge_len]  - NANOSECONDS[plain_today] ))"
report '$#'     "$(( NANOSECONDS[width_merge_argc] - NANOSECONDS[width_today] ))" "$(( NANOSECONDS[plain_merge_argc] - NANOSECONDS[plain_today] ))"
report '[[-n]]' "$(( NANOSECONDS[width_merge_test] - NANOSECONDS[width_today] ))" "$(( NANOSECONDS[plain_merge_test] - NANOSECONDS[plain_today] ))"
