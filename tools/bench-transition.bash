#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  What a transition costs, and whether the schedule does what it claims.
#
#    bash tools/bench-transition.bash            two sizes, both schedules, both colour modes
#    BENCH_SIZES="120 40" bash tools/bench-transition.bash
#
#  Reports, per configuration:
#    kick-off ms   — capture the ground, read both layers back, build runs, blend every frame
#    playback µs   — what one frame costs once it is armed (the number that matters)
#    live ms       — one frame on the path taken when something under the rect is animating
#    contrast      — worst |fg−bg| over the inked cells of each frame; 0 = the glyph is gone
# ─────────────────────────────────────────────────────────────────────────────
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export FT_NO_WTFIX=1
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_USE_UTF8=1

# Each configuration builds its own tree under its own names: a bench that reuses one name
# has to tear the old tree down, and ft_remove on a root under `set -u` is its own adventure.
RUN_ID=0
APP=""; POP=""
POP_W=40; POP_H=8
build_page() {                  # cols rows
    FT_COLS=$1; FT_ROWS=$2
    (( RUN_ID++ )); APP="app$RUN_ID"; POP="pop$RUN_ID"
    ft-form name="$APP" width="$FT_COLS" height="$FT_ROWS"
        ft-frame name="win$RUN_ID" position=absolute left=2 top=1 \
                 width=$(( FT_COLS - 6 )) height=$(( FT_ROWS - 8 )) \
                 title="Settings" display=flex flexDirection=column gap=1
            ft-label name="l1_$RUN_ID" text="The quick brown fox jumps over the lazy dog"
            ft-label name="l2_$RUN_ID" text="Compression: high   Beep: on   Retries: 3"
            ft-label name="l3_$RUN_ID" text="A second paragraph of ordinary body text here."
            ft-div name="row$RUN_ID" display=flex gap=2
                ft-button name="bOk$RUN_ID"  OK
                ft-button name="bNo$RUN_ID"  Cancel
            end_ft_div
        end_ft_frame
    end_ft_form
    FT_ROOT=$APP
    ft_layout "$APP"
    FT_OUT=""; _ft_redraw_walk "$APP"; FT_OUT=""
}
teardown() { FT_DIRTY=(); FT_DAMAGE=(); }

make_popup() {                  # schedule ms
    ft_stylesheet name=bench style="
        .morph { transition: opacity $2 ease-in-out; --transition-schedule: $1; }
    "
    ft-frame name="$POP" class=morph position=absolute left=8 top=4 width="$POP_W" height="$POP_H" \
             title="Notice" backgroundColor=57 color=231 borderColor=213 parent="$APP"
        ft-label name="note$RUN_ID" text="Compression finished." color=231
    end_ft_frame
    ft_layout "$APP"
}

# Rebuild a cell grid from a byte stream using the module's own reader — enough for the
# arithmetic claims here. The REAL gate renders in a pty and reads cells with
# tools/screen-cells.py, which shares no code with this (tests/test-transition.bash).
declare -a CELL_GLYPH=() CELL_STYLE=()
cells_of() {                    # bytes top left bottom right
    local bytes=$1 top=$2 left=$3 bottom=$4 right=$5
    local h=$(( bottom-top+1 )) w=$(( right-left+1 ))
    _ft_transition_parse "$bytes" "$top" "$left" "$bottom" "$right"
    _ft_transition_resolve "$h"
    CELL_GLYPH=(); CELL_STYLE=()
    local i j row
    for (( i=0; i<w*h; i++ )); do CELL_GLYPH[i]=' '; CELL_STYLE[i]='-'; done
    for (( row=0; row<h; row++ )); do
        for (( i=_FT_SPAN_ROW_START[row]; i<_FT_SPAN_ROW_START[row]+_FT_SPAN_ROW_COUNT[row]; i++ )); do
            local text=${_FT_SPAN_TEXT[i]} c=${_FT_SPAN_COLUMN[i]} n=${_FT_SPAN_WIDTH[i]}
            for (( j=0; j<n; j++ )); do
                CELL_GLYPH[row*w+c+j]=${text:j:1}; CELL_STYLE[row*w+c+j]=${_FT_SPAN_STYLE[i]}
            done
        done
    done
}
worst_contrast() {              # → FT_RET
    local i n=${#CELL_GLYPH[@]} worst=0 d s f b fr fg fb br bg bb
    for (( i=0; i<n; i++ )); do
        [[ "${CELL_GLYPH[i]}" == ' ' || -z "${CELL_GLYPH[i]}" ]] && continue
        s=${CELL_STYLE[i]}; [[ "$s" == '-' ]] && continue
        f=${s%%|*}; s=${s#*|}; b=${s%%|*}
        fr=${f%%,*}; f=${f#*,}; fg=${f%%,*}; fb=${f#*,}
        br=${b%%,*}; b=${b#*,}; bg=${b%%,*}; bb=${b#*,}
        d=$(( (fr>br?fr-br:br-fr) + (fg>bg?fg-bg:bg-fg) + (fb>bb?fb-bb:bb-fb) ))
        (( d > worst )) && worst=$d
    done
    FT_RET=$worst
}

run_one() {                     # cols rows mode schedule
    local cols=$1 rows=$2 mode=$3 schedule=$4
    FT_COLOR_MODE=$mode
    build_page "$cols" "$rows"
    make_popup "$schedule" 330ms
    ft_transition_in "$POP" || { echo "  transition refused"; teardown; return 1; }
    ft_transition_frame_count "$POP"; local frames=$FT_RET
    # A base of -1 is the LIVE path, and reading _FT_TRANSITION_FRAME[-1+i] quietly returns the
    # PREVIOUS configuration's frames — which is exactly what happened, and the bench printed a
    # full page of plausible, wrong numbers before anyone noticed. Never again silently.
    ft_transition_live "$POP" && { echo "  BENCH BUG: precomputed path expected, got the live path"; teardown; return 1; }
    local kickoff=$FT_TRANSITION_LAST_KICKOFF_MS
    local bytes=0 i
    for (( i=0; i<frames; i++ )); do ft_transition_frame "$POP" "$i"; (( bytes += ${#FT_RET} )); done
    ft_now_ms; local a=$FT_RET
    local rep
    for rep in 1 2 3 4 5 6 7 8 9 10; do
        for (( i=0; i<frames; i++ )); do ft_transition_frame "$POP" "$i"; printf '%s' "$FT_RET" >&"$FT_TTY"; done
    done
    ft_now_ms
    printf '  %-8s %-9s frames=%-3s runs=%-4s classes=%-3s  kickoff=%-4sms  playback=%sus/frame  %sB/frame\n' \
        "$mode" "$schedule" "$frames" "$FT_TRANSITION_LAST_RUNS" "$FT_TRANSITION_LAST_CLASSES" \
        "$kickoff" $(( (FT_RET-a)*1000/(frames*10) )) $(( bytes/frames ))
    # the contrast curve
    ft_transition_rect "$POP"; local rect=$FT_RET
    set -- $rect; local t=$1 l=$2 b=$3 r=$4
    local line=""
    for (( i=0; i<frames; i++ )); do
        ft_transition_frame "$POP" "$i"; cells_of "$FT_RET" "$t" "$l" "$b" "$r"
        worst_contrast; line+=" $(printf '%3s' "$FT_RET")"
    done
    printf '  %-8s %-9s contrast/frame:%s\n' "$mode" "$schedule" "$line"
    # last frame vs a from-scratch render of the finished control
    ft_transition_frame "$POP" $(( frames-1 ))
    cells_of "$FT_RET" "$t" "$l" "$b" "$r"
    local -a got_glyph=("${CELL_GLYPH[@]}") got_style=("${CELL_STYLE[@]}")
    ft_transition_cancel "$POP"
    local saved=$FT_OUT; FT_OUT=""; _ft_redraw_walk "$POP"; local real=$FT_OUT; FT_OUT=$saved
    cells_of "$real" "$t" "$l" "$b" "$r"
    local mismatch=0
    for (( i=0; i<${#CELL_GLYPH[@]}; i++ )); do
        [[ "${got_glyph[i]}" == "${CELL_GLYPH[i]}" && "${got_style[i]}" == "${CELL_STYLE[i]}" ]] || (( mismatch++ ))
    done
    printf '  %-8s %-9s last frame vs a real render: %s/%s cells differ\n' \
        "$mode" "$schedule" "$mismatch" "${#CELL_GLYPH[@]}"
    teardown
}

run_live() {                    # cols rows
    FT_COLOR_MODE=truecolor
    build_page "$1" "$2"
    make_popup contrast 330ms
    # Something under the rect is animating — the engine's own registry is what gets asked, so
    # the animating control must genuinely OVERLAP the rect (the frame does; the first label
    # sits two rows above it and taught this bench that lesson).
    local animator="win$RUN_ID"
    ft_anim_start "$animator" 240 120 1 1
    ft_transition_in "$POP" || { echo "  transition refused"; ft_anim_stop "$animator"; teardown; return 1; }
    if ! ft_transition_live "$POP"; then
        echo "  LIVE PATH NOT TAKEN — the animating ground was not noticed"
        ft_transition_cancel "$POP"; ft_anim_stop "$animator"; teardown; return 1
    fi
    ft_transition_frame_count "$POP"; local frames=$FT_RET; local i total=0
    for (( i=1; i<=5; i++ )); do
        FT_ANIM_PHASE[$POP]=$i
        FT_OUT=""; _ft_transition_frame "$POP" transition; FT_OUT=""
        (( total += FT_TRANSITION_LAST_FRAME_MS ))
    done
    printf '  live      contrast  frames=%-3s runs=%-4s  %sms/frame (ground re-read every frame)\n' \
        "$frames" "$FT_TRANSITION_LAST_RUNS" $(( total/5 ))
    ft_transition_cancel "$POP"
    ft_anim_stop "$animator"
    teardown
}

# ── How does arming scale with the rect? ─────────────────────────────────────
# Asked because a bigarrow's extent is roughly 30x15 where a callout is 40x8, and the question
# "should exit=fade run on this machinery" turns entirely on what arming an arrow-sized rect
# would cost at a moment the user did not ask for anything.
POP_W=40; POP_H=8
run_rect() {                    # cols rows popW popH
    FT_COLOR_MODE=truecolor
    POP_W=$3; POP_H=$4
    build_page "$1" "$2"
    make_popup contrast 330ms
    if ! ft_transition_in "$POP"; then echo "  refused"; teardown; return 1; fi
    ft_transition_frame_count "$POP"; local frames=$FT_RET; local i
    ft_now_ms; local a=$FT_RET
    for rep in 1 2 3 4 5; do
        for (( i=0; i<frames; i++ )); do ft_transition_frame "$POP" "$i"; printf '%s' "$FT_RET" >&"$FT_TTY"; done
    done
    ft_now_ms
    printf '  %3sx%-3s = %4s cells   kickoff=%-4sms  playback=%sus/frame  runs=%-3s classes=%s\n' \
        "$3" "$4" $(( $3 * $4 )) "$FT_TRANSITION_LAST_KICKOFF_MS" \
        $(( (FT_RET-a)*1000/(frames*5) )) "$FT_TRANSITION_LAST_RUNS" "$FT_TRANSITION_LAST_CLASSES"
    ft_transition_cancel "$POP"
    teardown
}
if [[ -n "${BENCH_RECT_SWEEP:-}" ]]; then
    printf '\n── arming vs rect size (95x34 page, truecolor) ──────────────────\n'
    run_rect 95 34 20 5
    run_rect 95 34 40 8
    run_rect 95 34 40 15
    run_rect 95 34 60 15
    run_rect 95 34 80 20
    echo
    exit 0
fi

IFS='|' read -r -a sizes <<< "${BENCH_SIZES_LIST:-95 34|140 44}"
for size in "${sizes[@]}"; do
    set -- $size
    printf '\n── %sx%s ─────────────────────────────────────────────────────────\n' "$1" "$2"
    for mode in truecolor 256; do
        for schedule in contrast average; do run_one "$1" "$2" "$mode" "$schedule"; done
    done
    run_live "$1" "$2"
done
echo
