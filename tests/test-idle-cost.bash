#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tests/test-idle-cost.bash — an app that nobody is touching must cost nothing.
#
#  This gate exists because demo/css-demo.bash was measured burning ~80% of a
#  core while sitting completely idle: the run loop polls every 20ms whenever
#  anything animates, each tick cost 15.96ms of real work, and 119 of every 120
#  frames it painted were BYTE-IDENTICAL to the frame before. The engine was
#  redrawing pixels that were already on the screen, forever, at 50Hz.
#
#  Every assertion below states a REQUIREMENT, never a mechanism, so the gate
#  survives whatever the fix turns out to be:
#
#    1. No two consecutive painted frames may be identical. Painting bytes that
#       change nothing is the whole defect, and it is machine-independent —
#       unlike a millisecond threshold, which would be flaky on a loaded box.
#    2. An animation must be able to show something. An `animation` whose every
#       frame composes the same output is not an animation; it is a still image
#       with a 50Hz tax.
#    3. The phase must wrap without a discontinuity. A loop length that is not a
#       whole number of ramp cycles makes the effect lurch when it wraps.
#    4. A declared duration must be the real cycle time.
#
#  ANTI-VACUITY (CONTRIBUTING §4/§5): each requirement is paired with a check
#  proving the instrument could have seen a violation — that the page painted,
#  that an animation is registered, that the ramp is non-empty. Five suites in
#  this project once passed whatever the code did; a "nothing bad happened"
#  assertion with no companion proving something happened is worthless.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"

export FT_NO_WTFIX=1 FT_RECORD=""
# Sourced minus its blocking run loop, and kept INSIDE the tree so the demo's
# own `here=$(dirname …)/..` still resolves to the project root.
noloop="$here/demo/.idle-cost-noloop.bash"
sed '/^ft-run app/d' "$here/demo/css-demo.bash" > "$noloop"
trap 'rm -f "$noloop"' EXIT
source "$noloop"
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_ROWS=34; FT_COLS=120

# Page 8 is the @keyframes page — the one that leaves an animation running.
PAGE=8; _show_page >/dev/null 2>&1
settle >/dev/null 2>&1
animPick_on_change pulse >/dev/null 2>&1
settle >/dev/null 2>&1
# A CSS animation is armed as a SIDE EFFECT OF PAINTING (_ft_css_anim_fg runs
# during the draw), so a build that never painted has nothing registered and
# every assertion below would pass on an empty room.
FT_ROOT=${FT_ROOT:-app}
ft_redraw_all "$FT_ROOT" >/dev/null 2>&1

note "the room is not empty (without this, every assertion below is vacuous)"
check "the page armed at least one animation" "$(( ${#FT_ANIM_PHASE[@]} > 0 ))" 1
check "…so the run loop is awake"             "$(( FT_ANIM_ACTIVE > 0 ))"      1
check "spec is running a @keyframes"          "${FT_CSS_ANIMATION_ON[spec]:-}"  1

# ── 1. no effect may paint the frame it has just painted ─────────────────────
# Captured by standing in for ft_flush: that is the single point every painting
# path funnels through, so nothing reaches a terminal without passing here. It
# also sidesteps the trap that FT_OUT is CLEARED by the real ft_flush, which has
# produced two false bug reports on this project already.
#
# PER EFFECT, one at a time. Measured across the mixed stream this requirement is
# toothless: two effects that each repaint one unchanging image still alternate,
# so no two ADJACENT frames match and a broken engine sails through. Isolating an
# effect also makes the poll match its own frame rate, so every tick is a real
# frame of that effect and nothing is diluted by ticks that were never due.
note "no effect paints the frame it just painted"
_ft_real_flush=$(declare -f ft_flush)

_effects=(); for _n in "${!FT_ANIM_PHASE[@]}"; do _effects+=("$_n"); done
declare -A _snap_phase=() _snap_length=() _snap_frame_ms=() _snap_step=() _snap_loop=() \
           _snap_routine=() _snap_structure=() _snap_debounce=() _snap_hold=()
for _n in "${_effects[@]}"; do
    _snap_phase[$_n]=${FT_ANIM_PHASE[$_n]};       _snap_length[$_n]=${FT_ANIM_LENGTH[$_n]}
    _snap_frame_ms[$_n]=${FT_ANIM_FRAME_MS[$_n]}; _snap_step[$_n]=${FT_ANIM_STEP[$_n]}
    _snap_loop[$_n]=${FT_ANIM_LOOP[$_n]};         _snap_routine[$_n]=${FT_ANIM_FRAME[$_n]:-}
    _snap_structure[$_n]=${FT_ANIM_STRUCT[$_n]:-}
    _snap_debounce[$_n]=${FT_ANIM_DEBOUNCE[$_n]:-0}; _snap_hold[$_n]=${FT_ANIM_HOLD[$_n]:-}
done
_leave_only_the_effect() {      # name — strip the registry down to this one effect
    FT_ANIM_PHASE=(); FT_ANIM_LENGTH=(); FT_ANIM_FRAME_MS=(); FT_ANIM_STEP=()
    FT_ANIM_LOOP=(); FT_ANIM_ACCUMULATED_MS=(); FT_ANIM_FRAME=(); FT_ANIM_STRUCT=()
    FT_ANIM_DEBOUNCE=(); FT_ANIM_HOLD=()
    FT_ANIM_PHASE[$1]=${_snap_phase[$1]};       FT_ANIM_LENGTH[$1]=${_snap_length[$1]}
    FT_ANIM_FRAME_MS[$1]=${_snap_frame_ms[$1]}; FT_ANIM_STEP[$1]=${_snap_step[$1]}
    FT_ANIM_LOOP[$1]=${_snap_loop[$1]};         FT_ANIM_ACCUMULATED_MS[$1]=0
    FT_ANIM_FRAME[$1]=${_snap_routine[$1]};     FT_ANIM_STRUCT[$1]=${_snap_structure[$1]}
    FT_ANIM_DEBOUNCE[$1]=${_snap_debounce[$1]}; FT_ANIM_HOLD[$1]=${_snap_hold[$1]}
    _ft_anim_repoll
}

_TICKS=240
_any_effect_painted=0
for _n in "${_effects[@]}"; do
    _leave_only_the_effect "$_n"
    _painted=(); ft_flush() { [[ -n "$FT_OUT" ]] && _painted+=("$FT_OUT"); FT_OUT=""; }
    for (( _t=0; _t<_TICKS; _t++ )); do ft_anim_step; done
    eval "${_ft_real_flush/#ft_flush/ft_flush}"      # put the real one back

    _n_painted=${#_painted[@]}
    (( _n_painted )) && _any_effect_painted=1
    (( _n_painted )) || continue                     # an effect that paints nothing wastes nothing
    _repeats=0
    for (( _i=1; _i<_n_painted; _i++ )); do
        [[ "${_painted[_i]}" == "${_painted[_i-1]}" ]] && (( _repeats++ ))
    done
    _distinct=$(printf '%s\n' "${_painted[@]}" | sort -u | wc -l)
    check "$_n: painted $_n_painted frames — more than one of them is distinct" "$(( _distinct > 1 ))" 1
    check "$_n: no frame repeats the one before it" "$_repeats" 0
done
check "at least one effect painted (else nothing above was measured)" "$_any_effect_painted" 1

# Put the whole registry back for the checks that follow.
for _n in "${_effects[@]}"; do
    FT_ANIM_PHASE[$_n]=${_snap_phase[$_n]};       FT_ANIM_LENGTH[$_n]=${_snap_length[$_n]}
    FT_ANIM_FRAME_MS[$_n]=${_snap_frame_ms[$_n]}; FT_ANIM_STEP[$_n]=${_snap_step[$_n]}
    FT_ANIM_LOOP[$_n]=${_snap_loop[$_n]};         FT_ANIM_ACCUMULATED_MS[$_n]=0
    FT_ANIM_FRAME[$_n]=${_snap_routine[$_n]};     FT_ANIM_STRUCT[$_n]=${_snap_structure[$_n]}
    FT_ANIM_DEBOUNCE[$_n]=${_snap_debounce[$_n]}; FT_ANIM_HOLD[$_n]=${_snap_hold[$_n]}
done
_ft_anim_repoll

# ── 2. an animation must be able to show something ───────────────────────────
# `pulse` is an OPACITY ramp, and _ft_css_kf_compose modulates it against the
# element's colour. When that colour resolves to nothing there is nothing to
# modulate and every frame composes the empty string — an invisible animation
# costing a full repaint per frame. In CSS an element always has a used colour.
note "an animation composes something a viewer could see"
_ft_css_kf_for spec pulse
_ft_css_kf_len; _ramp_len=$FT_RET
check "the pulse ramp resolved (else the next check is vacuous)" "$(( _ramp_len > 1 ))" 1
# Ask the ENGINE what it composes, through the entry point the paint uses. Composing by hand
# from `ft_style spec color` would only re-implement the defect — the specified value is empty
# here, and resolving the USED value is the whole point.
declare -A _composed=()
_saved_phase=${FT_ANIM_PHASE[spec]}
for (( _p=0; _p<_ramp_len; _p++ )); do
    FT_ANIM_PHASE[spec]=$_p
    _ft_css_anim_fg spec
    _composed[${FT_RET:-<empty>}]=1
done
FT_ANIM_PHASE[spec]=$_saved_phase
check "the animation has more than one distinct frame" "$(( ${#_composed[@]} > 1 ))" 1
check "…and no frame composes nothing at all" "${_composed[<empty>]:-absent}" absent

# ── 3. the phase wraps without a lurch ───────────────────────────────────────
# _ft_css_kf_compose indexes every ramp as r[phase % rampLength]. If the loop
# length is not a whole number of ramp cycles the wrap jumps mid-ramp: with a
# length of 240 and a ramp of 25, phase 239 sits at index 14 and the next frame
# is index 0 — a visible lurch every 19.2 seconds.
note "the phase wraps where the ramp does"
_loop_len=${FT_ANIM_LENGTH[spec]}
check "the loop length is a whole number of ramp cycles" "$(( _loop_len % _ramp_len ))" 0

# ── 4. a declared duration is the real cycle time ────────────────────────────
# `animation: pulse 2s` must take two seconds to come back to where it started.
note "a declared duration is the cycle the user gets"
_step=${FT_ANIM_STEP[spec]}
_cycle_ms=$(( _ramp_len * FT_ANIM_FRAME_MS[spec] / _step ))
check "one cycle of 'pulse 2s' takes 2000ms" "$_cycle_ms" 2000

# ── 5. a skipped frame must be one that is already on the screen ─────────────
# The engine skips a frame whose NAME matches the one standing. That is only safe if the name
# is sound: same name ⇒ same painted frame. An unsound name freezes an animation, and a frozen
# animation is SILENT — it paints nothing, raises nothing, and a screenshot of it looks fine.
# So the soundness is checked directly, and then checked again with a name that lies.
note "the same frame name always means the same painted frame"
_soundness_sweep() {            # → _unsound, _name_changes
    local phase name paint previous="" key
    declare -gA _paint_for_name=()
    _unsound=0; _name_changes=0
    for (( phase=0; phase<_ramp_len; phase++ )); do
        FT_ANIM_PHASE[spec]=$phase
        _ft_anim_signature spec; name=$FT_RET
        ft_dirty spec; FT_OUT=""; ft_draw_one spec; paint=$FT_OUT; FT_OUT=""
        key="name:$name"                     # never an empty subscript, whatever the name is
        if [[ -n "${_paint_for_name[$key]+seen}" ]]; then
            [[ "${_paint_for_name[$key]}" == "$paint" ]] || _unsound=$(( _unsound + 1 ))
        else
            _paint_for_name[$key]=$paint
        fi
        [[ "$name" != "$previous" ]] && _name_changes=$(( _name_changes + 1 ))
        previous=$name
    done
}
_soundness_sweep
check "no two phases share a name but paint differently" "$_unsound" 0
check "…and the name is not a constant (it moved)"       "$(( _name_changes > 1 ))" 1
check "…nor unique per phase, or it would skip nothing"  "$(( ${#_paint_for_name[@]} < _ramp_len ))" 1

note "…and a name that lies is caught"
# TEETH. Pin the name to a constant: every phase now claims to be the frame already on screen,
# so the sweep must report the phases that actually paint something else. Without this the
# check above passes just as well on an engine that never skips anything at all.
_frozen_name() { FT_RET=FROZEN; }
ft_anim_bind_signature spec _frozen_name
_soundness_sweep
check "a constant name is reported as unsound" "$(( _unsound > 0 ))" 1
unset "FT_ANIM_SIGNATURE[spec]" "FT_ANIM_SIGNATURE_ON_SCREEN[spec]"
_soundness_sweep
check "…and removing it makes the sweep sound again" "$_unsound" 0

summary
