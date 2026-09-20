#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  DOES A TRANSITION MAKE TYPING LAG?
#
#  Frame rate is not the acceptance bar. The bar is: while a transition is running, does a
#  keystroke still land immediately? So this measures the keystroke path — dispatch, settle,
#  repaint — with nothing else going on, and again with a transition in flight.
#
#  What "in flight" costs a keystroke is precisely the cost of ONE ANIMATION TICK. The run
#  loop blocks in `read -t $FT_ANIM_INTERVAL`; a real keystroke wins that read the instant it
#  arrives, so an animation adds latency only when the key lands while a tick is executing.
#  Worst case added latency = one tick. That is the number reported.
#
#    bash tools/bench-transition-latency.bash
# ─────────────────────────────────────────────────────────────────────────────
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export FT_NO_WTFIX=1
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_USE_UTF8=1
FT_COLOR_MODE=truecolor
FT_COLS=95; FT_ROWS=34

ft-form name=app width="$FT_COLS" height="$FT_ROWS"
    ft-frame name=win position=absolute left=2 top=1 width=80 height=24 title="Settings" \
             display=flex flexDirection=column gap=1
        ft-label name=lead text="Type here while a notice appears over the page."
        ft-textfield name=entry width=60 value=""
        ft-label name=l2 text="Compression: high   Beep: on   Retries: 3"
        ft-label name=l3 text="A second paragraph of ordinary body text here."
    end_ft_frame
end_ft_form
FT_ROOT=app
ft_layout app
FT_OUT=""; _ft_redraw_walk app; FT_OUT=""
ft_focus entry
# the field must be in edit mode, or a character is a navigation key, not a keystroke
ft_dispatch_event Enter >/dev/null 2>&1

make_notice() {                 # name schedule
    ft-frame name="$1" class=morph position=absolute left=10 top=6 width=40 height=8 \
             title="Notice" backgroundColor=57 color=231 borderColor=213 parent=app
        ft-label name="${1}_body" text="Compression finished." color=231
    end_ft_frame
    ft_layout app
}
ft_stylesheet name=lat style='.morph { transition: opacity 330ms ease-in-out; }'

# One keystroke, the whole path the run loop takes for it.
keystroke() {                   # char → FT_RET ms
    ft_now_ms; local a=$FT_RET
    FT_COALESCING=1
    ft_dispatch_event "$1" >/dev/null 2>&1
    FT_COALESCING=0
    ft_reflow_flush
    ft_redraw_dirty
    ft_now_ms; FT_RET=$(( FT_RET - a ))
}
# One animation tick, exactly as ft_next_event calls it on a read timeout.
tick() {                        # → FT_RET ms
    ft_now_ms; local a=$FT_RET
    ft_anim_step
    ft_now_ms; FT_RET=$(( FT_RET - a ))
}
stats() {                       # label values… → prints min/median/max
    local label=$1; shift
    local -a v=("$@"); local n=${#v[@]} i j t
    for (( i=1; i<n; i++ )); do t=${v[i]}; j=$(( i-1 ))
        while (( j >= 0 )) && (( v[j] > t )); do v[j+1]=${v[j]}; (( j-- )); done
        v[j+1]=$t
    done
    printf '  %-46s min %-4s median %-4s max %-4s ms\n' "$label" "${v[0]}" "${v[n/2]}" "${v[n-1]}"
}

CHARS=(a b c d e f g h i j k l m n o p q r s t)

note_baseline() {
    local -a times=(); local c
    for c in "${CHARS[@]}"; do keystroke "$c"; times+=("$FT_RET"); done
    stats "keystroke, nothing else running" "${times[@]}"
}

note_with_transition() {        # schedule label live
    local label=$2 want_live=$3
    local notice="pop_${label//[^a-z]/}"
    make_notice "$notice" "$1"
    if (( want_live )); then ft_anim_start win 240 120 1 1; fi
    ft_now_ms; local a=$FT_RET
    ft_transition_in "$notice" || { echo "  transition refused"; return 1; }
    ft_now_ms; local kickoff=$(( FT_RET - a ))
    local is_live=0; ft_transition_live "$notice" && is_live=1
    if (( want_live != is_live )); then
        printf '  BENCH BUG: wanted live=%s got live=%s\n' "$want_live" "$is_live"
        ft_transition_cancel "$notice"; (( want_live )) && ft_anim_stop win; return 1
    fi
    local -a key_times=() tick_times=(); local c
    for c in "${CHARS[@]}"; do
        tick;      tick_times+=("$FT_RET")
        keystroke "$c"; key_times+=("$FT_RET")
        FT_OUT=""
        # a real key restamps this; keystroke() goes around the input layer, so do it here
        ft_now_ms; FT_LAST_INPUT_MS=$FT_RET
        [[ -z "${FT_ANIM_PHASE[$notice]:-}" ]] && { FT_ANIM_PHASE[$notice]=1; FT_ANIM_ACTIVE=1; }
    done
    printf '  %s: kick-off %sms  (the one-off hitch when the notice appears)\n' "$label" "$kickoff"
    stats "$label: animation tick (the added latency)" "${tick_times[@]}"
    stats "$label: keystroke while it runs" "${key_times[@]}"
    ft_transition_cancel "$notice"
    (( want_live )) && ft_anim_stop win
}

echo
echo "── keystroke into a focused text field, 95x34 ────────────────────────────"
note_baseline
echo
echo "── with a transition in flight ──────────────────────────────────────────"
note_with_transition contrast "precomputed" 0
echo
note_with_transition contrast "live-ground" 1
echo
printf '  live path yielded on the last frame: %s   (FT_TRANSITION_YIELD_MS=%s)\n' \
    "$FT_TRANSITION_LAST_YIELDED" "$FT_TRANSITION_YIELD_MS"
echo
echo "── the same live path with yielding switched OFF ────────────────────────"
FT_TRANSITION_YIELD_MS=0
note_with_transition contrast "live-no-yield" 1
FT_TRANSITION_YIELD_MS=250
echo
echo "── a transition AND a bigarrow, both on the shared loop ─────────────────"
# The arrow is the other half of the animation machinery this branch merged with. Both now
# tick from the same ft_anim_step, so the honest question is what a keystroke costs with BOTH
# of them running — not with either alone.
ft-beacon name=bigarrow variant=bigarrow target=lead parent=app lifetime=oneshot
ft_layout app
# ARROW ALONE FIRST, so its cost is attributed to it and not to the transition beside it.
declare -a arrow_ticks=()
for c in "${CHARS[@]}"; do
    tick; arrow_ticks+=("$FT_RET")
    keystroke "$c"; FT_OUT=""
    ft_now_ms; FT_LAST_INPUT_MS=$FT_RET
done
stats "bigarrow alone: animation tick" "${arrow_ticks[@]}"
printf '  ticks in order: %s\n' "${arrow_ticks[*]}"
echo
ft_remove bigarrow 2>/dev/null
ft-beacon name=bigarrow variant=bigarrow target=lead parent=app lifetime=oneshot
ft_layout app
make_notice pop_both contrast
ft_transition_in pop_both >/dev/null || echo "  transition refused"
declare -a both_keys=() both_ticks=()
for c in "${CHARS[@]}"; do
    tick;            both_ticks+=("$FT_RET")
    keystroke "$c";  both_keys+=("$FT_RET")
    FT_OUT=""
    ft_now_ms; FT_LAST_INPUT_MS=$FT_RET
done
printf '  arrow animating: %s\n' \
    "$([[ -n "${FT_ANIM_PHASE[bigarrow]:-}" ]] && echo yes || echo "no — it had already retired")"
stats "transition + bigarrow: animation tick" "${both_ticks[@]}"
stats "transition + bigarrow: keystroke" "${both_keys[@]}"
# THE SERIES, NOT JUST THE MAX. A single expensive tick buried in a min/median/max reads as
# "sometimes it stalls", which is a different bug from "the first tick builds something". The
# arrow rasterises its art lazily on the first geometry for a new shape, and that is a one-off.
printf '  ticks in order: %s\n' "${both_ticks[*]}"
echo
