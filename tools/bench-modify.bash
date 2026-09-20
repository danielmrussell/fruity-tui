#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  What ft-modify and ft_remove cost, on the paths that are actually hot.
#
#  ft-modify is on every keystroke, every step change and every property write in the
#  framework, so making it do MORE (mark dirty by property kind) has to be measured, not
#  assumed. ft_remove is on every overlay teardown. Run before and after a change to either.
#
#    bash tools/bench-modify.bash
# ─────────────────────────────────────────────────────────────────────────────
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export FT_NO_WTFIX=1
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_USE_UTF8=1; FT_COLOR_MODE=truecolor
FT_COLS=118; FT_ROWS=40

ft-form name=app width="$FT_COLS" height="$FT_ROWS"
    ft-frame name=win position=absolute left=2 top=1 width=100 height=30 title="Bench" \
             display=flex flexDirection=column gap=1
        ft-label name=lead text="A settled page with a few controls on it."
        ft-textfield name=entry width=60 value=""
        ft-div name=box display=flex flexDirection=column gap=1
            ft-label name=b1 text="Compression: high   Beep: on   Retries: 3"
            ft-label name=b2 text="The quick brown fox jumps over the lazy dog."
            ft-label name=b3 text="Valid users: @staff, @archivists, mago-svc"
        end_ft_div
        ft-div name=row display=flex gap=2
            ft-button name=bOk OK
            ft-button name=bNo Cancel
        end_ft_div
    end_ft_frame
end_ft_form
FT_ROOT=app
ft_layout app
FT_OUT=""; _ft_redraw_walk app; FT_OUT=""
ft_focus entry
ft_dispatch_event Enter >/dev/null 2>&1

report() {                      # label totalMs iterations
    printf '  %-44s %8s us/op\n' "$1" $(( $2 * 1000 / $3 ))
}
timeit() {                      # label iterations command...
    local label=$1 n=$2; shift 2
    ft_now_ms; local a=$FT_RET local i
    for (( i=0; i<n; i++ )); do "$@" >/dev/null 2>&1; done
    ft_now_ms
    report "$label" $(( FT_RET - a )) "$n"
}

N=200
echo
echo "── ft-modify, by property kind ──────────────────────────────────────────"
i=0
paint_change()  { (( i++ )); ft-modify b1 color=$(( 200 + i % 50 )); }
layout_change() { (( i++ )); ft-modify b1 text="row $i"; }
noop_change()   { ft-modify b1 color=203; }
inherit_change(){ (( i++ )); ft-modify box color=$(( 200 + i % 50 )); }

ft-modify b1 color=203 >/dev/null 2>&1
timeit "paint property (color) on a leaf"        "$N" paint_change
timeit "…the same value again (must stay a no-op)" "$N" noop_change
timeit "inherited property on a container"        "$N" inherit_change
timeit "layout property (text)"                   "$N" layout_change
FT_DIRTY=(); FT_REFLOW_PENDING=(); FT_DAMAGE=()

echo
echo "── the paths a person actually feels ────────────────────────────────────"
keystroke() {                   # one character, dispatch → settle → paint
    FT_COALESCING=1
    ft_dispatch_event "$1" >/dev/null 2>&1
    FT_COALESCING=0
    ft_reflow_flush
    ft_redraw_dirty
}
CHARS=(a b c d e f g h i j k l m n o p q r s t u v w x y z)
ft_now_ms; t0=$FT_RET
for c in "${CHARS[@]}"; do keystroke "$c"; done
ft_now_ms
report "keystroke into a focused text field" $(( FT_RET - t0 )) "${#CHARS[@]}"

# A STEP CHANGE is the heaviest ordinary interaction in this project: it re-lays a page,
# removes and re-places an overlay, and repairs what it left. css-demo's own _goto_step.
noloop="$here/demo/.css-demo-bench.bash"
sed '/^ft-run app/d' "$here/demo/css-demo.bash" > "$noloop"
trap 'rm -f "$noloop"' EXIT
(
    source "$noloop" >/dev/null 2>&1
    exec {FT_TTY}>/dev/null
    FT_COLS=118; FT_ROWS=40; FT_ROOT=app; FT_COLOR_MODE=truecolor
    _resize >/dev/null 2>&1
    _page_annotations
    steps=${#PA_TARGET[@]}
    ft_now_ms; a=$FT_RET
    # SETTLE LIKE THE RUN LOOP, or this measures nothing: the demo's handlers no longer paint
    # (their trailing ft_redraw_dirty calls were no-ops under ft-run and are gone), so a bench
    # that drives _goto_step directly must do what ft-run's burst-end settle does — the first
    # version of this loop dropped from 765ms to 40ms/step and the 40 was the cost of NOT
    # painting.
    for (( s=2; s<=steps; s++ )); do
        STEP=$s; _goto_step >/dev/null 2>&1
        ft_reflow_flush >/dev/null 2>&1; ft_redraw_dirty >/dev/null 2>&1
    done
    ft_now_ms
    printf '  %-44s %8s ms/step  (%s steps)\n' "css-demo step change" \
        $(( (FT_RET - a) / (steps - 1) )) $(( steps - 1 ))
)
echo
