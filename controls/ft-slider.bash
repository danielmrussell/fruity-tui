#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — controls/ft-slider.bash
#
#  The "slider" prototype — HTML's <input type=range>: min/max/step/value, one
#  row tall, drawn in one of several Unicode styles:
#
#    variant=track   ├────●─────┤     (default: light rail, round knob)
#    variant=fill    ━━━━●──────      (filled left, empty right)
#    variant=blocks  ▰▰▰▰▱▱▱▱▱▱      (music-player bar)
#    variant=dots    ●●●●○○○○○○      (rating dots)
#
#  showValue=true appends the number after the track. Keyboard (focused):
#  Left/Down −step, Right/Up +step, PgUp/PgDn ±5·step, Home/End min/max —
#  the slider's keymap shadows the form's arrows, like every scrollable
#  control. The knob/fill brightens while focused.
#
#  `value` is a paint-only property kept current automatically. Optional
#  hook: onChange=fn — $this is the slider, $1 the new value. Return
#  nonzero to cancel the change.
#
#      ft-slider name=width min=30 max=70 value=50 width=24 showValue=true
#      width_on_change() { ft-modify row width="$1"; }   # $this=width, $1=value
#
#  Depends on ft-core.bash, ft-forms.bash, ft-keymap.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_SLIDER_LOADED:-}" ]] && return 0
_FT_SLIDER_LOADED=1

# Built once, by the prototype that declares `keymap=slider`.
_ft_define_keymap_slider() {
    # INACTIVE — merely focused. Enter steps in. The arrows are NOT bound here on purpose:
    # a slider you are only passing through must not change its value, which is exactly what
    # it used to do. Moving across a form with the arrows silently edited every slider on
    # the way, and nothing on screen said a value had changed.
    ft-bindkeys ft_keymap_slider ENTER=ft_key_delve
    ft-keymap-cap ft_keymap_slider ENTER ft_key_delve "$FT_IMPORTANCE_CRUCIAL" "Adjust"

    # ADJUSTING — one Enter in, and now every arrow is the slider's. Up/Down too: a
    # horizontal slider has no vertical axis, but once you have stepped inside a control an
    # arrow with nothing to do must do NOTHING, not throw you out of it.
    ft_keymap_once ft_keymap_slider_adjusting
    ft-bindkeys ft_keymap_slider_adjusting \
        LEFT=ft_slider_key_dec  RIGHT=ft_slider_key_inc \
        UP=ft_slider_key_inc    DOWN=ft_slider_key_dec \
        PGUP=ft_slider_key_bigdec PGDN=ft_slider_key_biginc \
        HOME=ft_slider_key_min  END=ft_slider_key_max \
        ESC=ft_key_undelve
    ft-keymap-cap ft_keymap_slider_adjusting LEFT  ft_slider_key_dec    "$FT_IMPORTANCE_CRUCIAL"   "Decrease"
    ft-keymap-cap ft_keymap_slider_adjusting RIGHT ft_slider_key_inc    "$FT_IMPORTANCE_CRUCIAL"   "Increase"
    ft-keymap-cap ft_keymap_slider_adjusting PGUP  ft_slider_key_bigdec "$FT_IMPORTANCE_IMPORTANT" "Big step down"
    ft-keymap-cap ft_keymap_slider_adjusting PGDN  ft_slider_key_biginc "$FT_IMPORTANCE_IMPORTANT" "Big step up"
    ft-keymap-cap ft_keymap_slider_adjusting HOME  ft_slider_key_min    "$FT_IMPORTANCE_NORMAL"    "Minimum"
    ft-keymap-cap ft_keymap_slider_adjusting END   ft_slider_key_max    "$FT_IMPORTANCE_NORMAL"    "Maximum"
    ft-keymap-cap ft_keymap_slider_adjusting ESC   ft_key_undelve       "$FT_IMPORTANCE_IMPORTANT" "Leave"
}
ft_prototype_slider() {
    ft_runlevels adjusting=ft_keymap_slider_adjusting
    ft_prototype extends=ft_control \
        defaults="importance=important" \
        focusable=true \
        mouse=slider \
        keymap=slider \
        setProp=_ft_slider_sanitize_prop \
        defaults="display=inline-block min=0 max=100 step=1 variant=track showValue=false"
    # showValue, min and max all decide the slider's PREFERRED WIDTH now that the readout is
    # measured rather than assumed (see _ft_slider_value_columns) — so none of them is paint-only.
    # An auto-sized slider whose max grew from 100 to 2000 needs one more column for the number.
    ft_prop_kind_set showValue layout
    ft_prop_kind_set min       layout
    ft_prop_kind_set max       layout
}

# EVERY SLIDER HAS A VALUE, including one built without a `value=`. HTML's range input defaults
# to the midpoint of its range, and this control's own sanitizer already answers exactly that for
# an unparseable value — it was simply answering it for nobody. Measured on
# `ft-slider name=s min=10 max=20`: the PAINT drew 10 (the draw falls back to min), `ft_get s
# value` answered the EMPTY STRING, and _ft_slider_sanitize answered 15. Three answers to one
# question, which is the ft-option "no value= of its own" shape one control over.
#
# Materialised HERE rather than in the reconciler because a slider built with no min, max, step
# OR value writes none of the four, so the reconciler never runs for it — the prototype
# defaults are not stamped onto instances. The constructor is the one place every slider passes
# through.
ft-slider() {
    ft_new slider "$@" || return
    local n=$FT_RET
    _ft_get_raw "$n" value
    if (( ${#FT_RET} == 0 )); then
        _ft_slider_sanitize "$n" ""          # → the range's midpoint, HTML's default
        _ft_stamp_prop "$n" value "$FT_RET"
    fi
    FT_RET=$n                                # …callers read the new control's name from here
}

# HTML's VALUE SANITIZATION ALGORITHM for <input type=range>, which this control is: clamp into
# [min,max], round to the nearest step-aligned value (the step base is `min`, ties round up),
# and put the rounded answer back in range. A range input has no invalid state — it has a
# sanitized one.
#
# It lives here because THREE routes were each rounding by hand and one of them wasn't: the
# mouse computed clamp-and-snap inline, ft_slider_set clamped without snapping, and
# _ft_draw_slider clamped a value it had no business correcting — so `ft-modify sl max=4` on a
# slider showing 5 PAINTED "4" while `ft_get sl value` still answered 5. The app and the user
# were reading different numbers off the same control.
#
# A NON-NUMERIC value becomes the range's midpoint, HTML's default, rather than a diagnostic:
# `value` is deliberately absent from _FT_NUMERIC_PROP (a textfield's value is arbitrary text),
# so this is the only place a slider's can be checked — and the check has to exist, because the
# next thing that happens to it is (( )), which resolves bare words and EXECUTES array
# subscripts. Same predicate as _ft_setprop's numeric guard, deliberately.
_ft_slider_sanitize() {         # name value → FT_RET
    local v=$2 mn mx st
    ft_resolved_prop "$1" min 0;   mn=$FT_RET
    ft_resolved_prop "$1" max 100; mx=$FT_RET
    ft_resolved_prop "$1" step 1;  st=$FT_RET     # …already >= 1: sanitized at the write above
    (( mx < mn )) && mx=$mn      # a max below its min collapses the range onto min
    case $v in ''|*[!0-9-]*|-*-*|-) v=$(( mn + (mx - mn) / 2 )) ;; esac
    (( v < mn )) && v=$mn
    (( v > mx )) && v=$mx
    v=$(( mn + ((v - mn + st/2) / st) * st ))                  # nearest step, ties upward
    (( v > mx )) && v=$(( mn + ((mx - mn) / st) * st ))        # …and back inside the range
    FT_RET=$v
}
# The prototype's setProp reconciler: `value` has to be sanitized whenever it changes OR
# whenever the range it is measured against does. _ft_setprop is every route in — ft-modify, the
# DSL, a state restore — which matters most at CONSTRUCTION, where `ft-slider value=50 max=10`
# writes the two in that order and only the second one can fix the first.
# Writes go through _ft_stamp_prop, not _ft_setprop: the setter is our caller.
_ft_slider_sanitize_prop() {    # name prop value
    case $2 in min|max|step|value) : ;; *) return 0 ;; esac
    # STEP IS SANITIZED WHERE IT IS WRITTEN, because one reader correcting it is not the same as
    # it being correct. _ft_slider_sanitize floors it at 1 for its own arithmetic, and
    # _ft_slider_by — the arrow keys — read the raw property instead. Measured on min=0 max=10
    # value=5:
    #
    #     step=0    RIGHT 5→5, LEFT 5→5     the keyboard cannot move the slider at all,
    #                                        while the mouse still can (it goes through
    #                                        ft_slider_set, whose sanitize floors the step)
    #     step=-1   RIGHT 5→4, LEFT 5→6     INVERTED — the key captioned "Decrease" raises it
    #     step=-3   RIGHT 5→2, LEFT 5→8     inverted by three
    #
    # HTML: the step attribute must be a valid positive number, and an invalid one is ignored,
    # so the step is the default 1 and the arrows move by 1. With this, every reader sees a step
    # that is already valid — which is why _ft_slider_sanitize no longer carries its own floor.
    if [[ "$2" == step ]]; then
        case $3 in ''|*[!0-9-]*|-*-*|-) : ;;
            *) (( $3 < 1 )) && _ft_stamp_prop "$1" step 1 ;;
        esac
    fi
    _ft_get_raw "$1" value
    (( ${#FT_RET} == 0 )) && return 0        # no value of its own yet: nothing to sanitize
    local was=$FT_RET
    _ft_slider_sanitize "$1" "$was"
    [[ "$FT_RET" == "$was" ]] && return 0
    _ft_stamp_prop "$1" value "$FT_RET"
    ft_dirty "$1"
    return 0
}

# Click (or drag) anywhere on the track jumps the knob there — like dragging <input type=range>.
# RELX is the 0-based column within the slider; the value text (when showValue) sits AFTER the
# track, so a click past the rail just pins to the max end. Press sets _FT_MOUSE_DOWN=slider (the
# run loop), so a held drag keeps arriving here and the knob tracks the cursor.
_ft_mouse_slider() {            # name action relx rely
    local name=$1 act=$2 relx=$3
    [[ "$act" == release ]] && return 0
    ft_resolved_prop "$name" min 0;   local mn=$FT_RET
    ft_resolved_prop "$name" max 100; local mx=$FT_RET
    local cols=${FT_MEASURED_WIDTH[$name]:-0}          # NB: separate line — `local a=X b=$a` reads the OLD a
    _ft_slider_track "$name" "$cols"; local track=$FT_RET
    (( track < 2 )) && return 0
    local pos=$relx; (( pos < 0 )) && pos=0; (( pos > track-1 )) && pos=$(( track-1 ))
    local span=$(( mx - mn )); (( span < 1 )) && span=1
    # The cell under the cursor → a value; the step rounding is ft_slider_set's, via
    # _ft_slider_sanitize, so the mouse does not carry its own copy of the rule.
    ft_slider_set "$name" $(( mn + (pos * span + (track-1)/2) / (track-1) ))
    return 0
}

# THE READOUT IS AS WIDE AS THE WIDEST VALUE THE RANGE CAN PRODUCE, not four columns. showValue
# reserved a hardcoded 4 — one space plus three digits — which is exactly right for the default
# 0..100 and one column short of `max=2000`, whose four-digit readout painted past the right
# edge of the box and over whatever was beside it. Measured from min and max rather than from
# the CURRENT value, because a track that changed length as the knob moved would be worse than
# a track one column short. (An integer in [min,max] is longest at one of the two ends, so the
# wider of the two endpoints is a real bound and not a guess.)
_ft_slider_value_columns() {    # name → FT_RET (columns the readout occupies, its space included)
    ft_resolved_prop "$1" min 0;   local mn=$FT_RET
    ft_resolved_prop "$1" max 100; local mx=$FT_RET
    local w=${#mn}; (( ${#mx} > w )) && w=${#mx}
    (( w < 1 )) && w=1
    FT_RET=$(( w + 1 ))
}
# …and ONE function answers "how long is the rail", for the draw, the mouse and the width. It
# was three copies of `cols - 4`, which is three places to be wrong in the same way.
_ft_slider_track() {            # name cols → FT_RET (track columns)
    local track=$2
    ft_resolved_prop "$1" showValue false
    if [[ "$FT_RET" == true ]]; then
        _ft_slider_value_columns "$1"
        track=$(( track - FT_RET ))
        (( track < 3 )) && track=3
    fi
    FT_RET=$track
}
_ft_preferred_width_slider() {            # name → FT_RET (content columns)
    local name=$1
    ft_resolved_prop "$name" showValue false
    [[ "$FT_RET" == true ]] || { FT_RET=20; return; }
    _ft_slider_value_columns "$name"
    FT_RET=$(( 20 + FT_RET ))             # 20 columns of rail, plus the readout beside it
}
_ft_height_slider() { FT_RET=1; }

# ft_slider_set NAME VALUE — sanitize into the range, fire the cancelable onChange=fn hook,
# repaint (value is paint-only). Sanitizing HERE rather than trusting the write is what lets the
# hook be told the value that actually landed, and what makes "it didn't move" a real early exit.
ft_slider_set() {
    local name=$1
    _ft_slider_sanitize "$name" "$2"; local v=$FT_RET
    _ft_get_raw "$name" value; local old=$FT_RET
    # A slider nobody has given a value to SHOWS its minimum (see _ft_draw_slider), so that is
    # what "unchanged" compares against and what a cancelled change restores.
    (( ${#old} == 0 )) && { ft_resolved_prop "$name" min 0; old=$FT_RET; }
    [[ "$v" == "$old" ]] && return 0
    ft-modify "$name" value="$v"
    _ft_hook "$name" on_change "$v" || ft-modify "$name" value="$old"   # nonzero = cancel
    return 0
}
_ft_slider_by() {
    local name=$1 mult=$2
    ft_resolved_prop "$name" step 1; local st=$FT_RET
    ft_resolved_prop "$name" min 0;  local mn=$FT_RET
    _ft_get_raw "$name" value
    ft_slider_set "$name" $(( ${FT_RET:-$mn} + mult*st ))
}
ft_slider_key_dec()    { _ft_slider_by "$1" -1; }
ft_slider_key_inc()    { _ft_slider_by "$1" 1; }
ft_slider_key_bigdec() { _ft_slider_by "$1" -5; }
ft_slider_key_biginc() { _ft_slider_by "$1" 5; }
ft_slider_key_min()    { ft_resolved_prop "$1" min 0;   ft_slider_set "$1" "$FT_RET"; }
ft_slider_key_max()    { ft_resolved_prop "$1" max 100; ft_slider_set "$1" "$FT_RET"; }

_ft_draw_slider() {                      # name
    local name=$1
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local cols=${FT_MEASURED_WIDTH[$name]:-0}
    (( cols < 3 )) && return

    ft_resolved_prop "$name" min 0;    local mn=$FT_RET
    ft_resolved_prop "$name" max 100;  local mx=$FT_RET
    # No clamp here. The value is sanitized at every write (_ft_slider_sanitize_prop), so a
    # paint that corrected it would be a second, disagreeing answer — which is exactly what it
    # was: the knob and the value text showed 4 while ft_get answered 5.
    ft_resolved_prop "$name" value "$mn"; local v=${FT_RET:-$mn}
    ft_resolved_prop "$name" variant track;     local style=$FT_RET
    ft_resolved_prop "$name" showValue false; local showv=$FT_RET

    _ft_slider_track "$name" "$cols"; local track=$FT_RET
    local vtxt=""
    [[ "$showv" == true ]] && vtxt=" $v"
    # THE READOUT OWNS EVERY COLUMN THE TRACK LEFT IT, and paints all of them. The track makes
    # room for the WIDEST value (_ft_slider_value_columns), so " 9" in a slider reserved for
    # " 20" used to paint two of its three columns and leave the third to whatever was there
    # before — "11" stepping down to 9 showed "91", and turning showValue on kept the old rail's
    # ┤ standing in the last column. A full repaint hid it by clearing first; the incremental
    # path does not (tests/test-incremental.bash).
    (( cols > track )) && { ft_fit "$vtxt" $(( cols - track )); vtxt=$FT_FIT; }
    local span=$(( mx - mn )); (( span < 1 )) && span=1
    local pos=$(( (v - mn) * (track - 1) / span ))

    # Themed: FT_COLOR_KNOB when idle, the FT_COLOR_FOCUS accent while focused —
    # never the button-focus colour, so an unfocused slider can't masquerade
    # as a focused button.
    local hot=$FT_COLOR_KNOB
    [[ "${FT_FOCUS:-}" == "$name" ]] && hot=$FT_COLOR_FOCUS
    _ft_compose_sgr "$name"; local base=$FT_RET     # rail: cascaded bg/fg (slider{color:…} tints it)
    _ft_dim_if_disabled "$name" "$hot"; hot=$FT_RET

    local out="" i
    if (( FT_USE_UTF8 )); then
        case "$style" in
            fill)
                for (( i=0; i<track; i++ )); do
                    if   (( i <  pos )); then out+="$hot"$'━'"$FT_COLOR_RESET$base"
                    elif (( i == pos )); then out+="$hot"$'●'"$FT_COLOR_RESET$base"
                    else out+=$'─'; fi
                done ;;
            blocks)
                for (( i=0; i<track; i++ )); do
                    if (( i <= pos )); then out+="$hot"$'▰'"$FT_COLOR_RESET$base"
                    else out+=$'▱'; fi
                done ;;
            dots)
                for (( i=0; i<track; i++ )); do
                    if (( i <= pos )); then out+="$hot"$'●'"$FT_COLOR_RESET$base"
                    else out+=$'○'; fi
                done ;;
            *)  # track: ├ rail ┤ with a knob
                for (( i=0; i<track; i++ )); do
                    if   (( i == pos )); then out+="$hot"$'●'"$FT_COLOR_RESET$base"
                    elif (( i == 0 ));   then out+=$'├'
                    elif (( i == track-1 )); then out+=$'┤'
                    else out+=$'─'; fi
                done ;;
        esac
    else
        for (( i=0; i<track; i++ )); do
            if   (( i == pos )); then out+="${hot}o${FT_COLOR_RESET}${base}"
            elif (( i == 0 || i == track-1 )); then out+="|"
            else out+="-"; fi
        done
    fi
    ft_print_at "$row" "$col" "$base$out$vtxt$FT_COLOR_RESET"
}
