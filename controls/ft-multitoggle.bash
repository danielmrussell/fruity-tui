#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — controls/ft-multitoggle.bash
#
#  The "multitoggle" prototype: cycles through its ft-option children each
#  activation. Options separate VALUE from PRESENTATION (HTML's <option>):
#
#      ft-multitoggle name=priority text="Priority"
#          ft-option value=low    glyph="[Low]"
#          ft-option value=medium glyph="[Med]"
#          ft-option value=high   glyph="[Hi!]"
#      end_ft_multitoggle
#
#  The control's own `value` property is kept current AUTOMATICALLY — the
#  selected option's value — so your button's _on_activate handler just reads it
#  (ft_get priority value). No activation handler is required for that.
#
#  Instance hooks (optional, user code). In every hook $this is the control's
#  name and $1 is the new value:
#    onActivate=fn    — after a change; return nonzero to CANCEL it (the
#                            previous option stays)
#    onDeactivate=fn  — called INSTEAD when the new value is "false" (a
#                            checkbox unchecking), if defined; same cancel
#
#  Sizing uses the WIDEST option glyph so cycling never resizes (value and
#  selectedIndex are paint-only). A checkbox is a two-option multitoggle —
#  see controls/ft-checkbox.bash.
#
#  Depends on ft-core.bash and ft-forms.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_MULTITOGGLE_LOADED:-}" ]] && return 0
_FT_MULTITOGGLE_LOADED=1

ft_prototype_multitoggle() {
    ft_prototype extends=ft_control \
        focusable=true \
        mouse=activate \
        keymap=activate \
        setProp=_ft_multitoggle_setprop \
        defaults="display=inline-block selectedIndex=0"
}

# THE SELECTION IS THE TRUTH. A multitoggle (and so a checkbox, which is one with two options)
# renders from `selectedIndex`; `value` and `checked` are the friendly names for the same fact.
# Writing either of those directly used to leave the three out of step — the constructor
# translated `checked=` and nothing else did, so `ft_set cb checked=true` did nothing at all
# and `ft_set cb value=true` made the control report checked while still drawing unchecked.
# _ft_setprop calls this after storing any of the three, so every route in agrees.
# Writes go through _ft_stamp_prop, NOT _ft_setprop: the setter is our caller, and going back
# through it would recurse. (_ft_stamp_prop forgets each pair it stamps — written out by hand,
# this forgot `value`, on the argument that a line-store-backed property is never memoised.
# ft-select then needed the same two lines, which is what moved them into the engine.)
_ft_multitoggle_setprop() {     # name prop value
    local n=$1 p=$2 v=$3 i want
    case $p in
        checked) if _ft_truthy "$v"; then want=true; else want=false; fi ;;
        value)   want=$v ;;
        selectedIndex)
            # The other direction: the index moved, so `value` must follow it.
            _ft_options "$n"; (( ${#FT_OPTS[@]} == 0 )) && return 0
            # CLAMPED, NOT ABANDONED. This used to `return 0` on an out-of-range index, leaving
            # it stored verbatim for the paint to trip over — and the paint does not survive it.
            # Measured on a two-option checkbox: index 2 or 5 painted NO GLYPH AT ALL, index -1
            # painted a CHECKED box while `checked` and `value` both answered false (bash reads
            # -1 as the last element), and index -3 or lower put a "bad array subscript"
            # diagnostic on stderr FROM INSIDE THE DRAW — the alt screen, in a live app.
            # Every other control in this framework now bounds its index at the write; so does
            # this one.
            case $v in ''|*[!0-9-]*|-*-*|-) return 0 ;; esac
            (( v < 0 )) && v=0
            (( v >= ${#FT_OPTS[@]} )) && v=$(( ${#FT_OPTS[@]} - 1 ))
            _ft_stamp_prop "$n" selectedIndex "$v"
            _ft_option_value "${FT_OPTS[$v]}"
            _ft_stamp_prop "$n" value "$FT_RET"
            _ft_multitoggle_reflect_checked "$n"
            return 0 ;;
        *) return 0 ;;
    esac
    _ft_options "$n"; (( ${#FT_OPTS[@]} == 0 )) && return 0
    for i in "${!FT_OPTS[@]}"; do
        _ft_option_value "${FT_OPTS[$i]}"
        [[ "$FT_RET" == "$want" ]] || continue
        _ft_stamp_prop "$n" selectedIndex "$i"
        _ft_stamp_prop "$n" value "$want"
        _ft_multitoggle_reflect_checked "$n"
        ft_dirty "$n"
        return 0
    done
    return 0
}
# IF YOU CLAIM THE NAME, YOU KEEP IT TRUE. The reconciler above ACCEPTS `checked=` and maps it to
# a selection — so it has claimed the name — but it used to write `checked` back only on the
# derived prototype, and a bare multitoggle's went stale the moment the state moved any other
# way:
#
#     ft_set mt checked=true   paint [x]  idx 1  value true   checked true
#     ft_multitoggle_cycle mt     paint [ ]  idx 0  value false  checked TRUE   ← stale
#     ft_set mt checked=true   paint [ ]  …no change at all                  ← WEDGED
#
# Wedged because ft_set skips a write whose value equals the stored one, so the stale `true`
# made `checked=true` a no-op: the control could not be re-checked through the name it accepts.
# Only `false` then `true` recovered it.
#
# MAINTAINED ONLY IF THE CONTROL HAS ONE, so a multitoggle nobody spells `checked` at never grows
# the property — its options are not a two-state truth, and inventing one for a three-state
# control would be a worse lie than the stale one. A CHECKBOX always has it, because its
# children-complete seeds it (see ft-checkbox.bash); from then on this keeps it current, which is
# why the derived prototype no longer needs a reconciler of its own.
_ft_multitoggle_reflect_checked() {      # name — checked := (value == true), if it has a `checked`
    _ft_has_prop "$1" checked || return 0
    _ft_get_raw "$1" value
    local checked=false; [[ "$FT_RET" == true ]] && checked=true
    _ft_stamp_prop "$1" checked "$checked"
    return 0
}

ft-multitoggle()     { ft_new multitoggle "$@" && FT_NEST_STACK+=("$FT_RET"); }
end_ft_multitoggle() { ft_end multitoggle; }

# "children fully known": adopt the selected option's value as our own.
multitoggle_on_children_complete() { _ft_multitoggle_sync "$1"; }
_ft_multitoggle_sync() {        # name — reconcile the names, once the options exist
    local name=$1
    _ft_options "$name"
    (( ${#FT_OPTS[@]} == 0 )) && return 0
    # WHICH NAME DID THE AUTHOR ACTUALLY USE? This ran index→value unconditionally, and the
    # index at construction is usually still its prototype default — so `ft-checkbox name=c
    # value=true` was reconciled INTO false, the author's own word overwritten by a default.
    # The selection is the truth, as the prototype comment says; but if the author named the
    # VALUE and not the index, the value is the selection they meant. (The runtime reconciler
    # already maps value→index; this is the same rule at the one moment it could not run, because
    # the options did not exist yet when the property was written.)
    if _ft_has_prop "$name" value && ! _ft_has_prop "$name" selectedIndex; then
        _ft_get_raw "$name" value
        _ft_multitoggle_setprop "$name" value "$FT_RET"
        return 0
    fi
    ft_resolved_prop "$name" selectedIndex 0; local idx=${FT_RET:-0}
    (( idx >= ${#FT_OPTS[@]} )) && idx=0
    _ft_option_value "${FT_OPTS[$idx]}"
    _ft_setprop "$name" value "$FT_RET"
}

_ft_preferred_width_multitoggle() {       # name → FT_RET (content columns)
    local name=$1
    ft_resolved_prop "$name" text; local text=$FT_RET
    ft_resolved_prop "$name" accessKey; _ft_accel_text "$text" "$FT_RET"   # may add " (X)"
    ft_display_width "$FT_RET"; local tw=$FT_DISPLAY_WIDTH
    _ft_options "$name"
    local widest=0 o
    for o in "${FT_OPTS[@]}"; do
        _ft_get_raw "$o" glyph
        ft_display_width "$FT_RET"
        (( FT_DISPLAY_WIDTH > widest )) && widest=$FT_DISPLAY_WIDTH
    done
    FT_RET=$(( tw + widest + 1 ))
}
_ft_height_multitoggle() {      # name contentwidth → FT_RET (content rows)
    ft_resolved_prop "$1" text
    _ft_text_extent_cached "$1" "$FT_RET"
    FT_RET=$FT_TEXT_HEIGHT
}

_ft_draw_multitoggle() {                 # name
    local name=$1
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local cols=${FT_MEASURED_WIDTH[$name]:-0}
    (( cols < 1 )) && return

    ft_resolved_prop "$name" text;          local text=$FT_RET
    ft_resolved_prop "$name" accessKey;         local accessKey=$FT_RET
    ft_resolved_prop "$name" selectedIndex; local idx=${FT_RET:-0}
    _ft_options "$name"
    local glyph=""
    [[ -n "${FT_OPTS[$idx]:-}" ]] && { _ft_get_raw "${FT_OPTS[$idx]}" glyph; glyph=$FT_RET; }

    local base; [[ "${FT_FOCUS:-}" == "$name" ]] && base="$FT_COLOR_SEL" || base="$FT_COLOR_BODY"
    _ft_compose_sgr "$name" "$base"; local sgr=$FT_RET   # cascaded bg/fg/weight/decoration

    _ft_accel_markup "$text" "$accessKey" "$sgr"
    local out="$glyph $FT_RET"

    ft_fit "$out" "$cols"
    ft_print_at "$row" "$col" "$sgr$FT_FIT$FT_COLOR_RESET"
}

# Cycle to the next option, update value, fire the instance hook (which may
# cancel), repaint. Works with NO hook defined at all — that's the point.
ft_multitoggle_cycle() {                 # name
    local name=$1
    _ft_options "$name"
    local n=${#FT_OPTS[@]}
    (( n < 1 )) && return 0
    ft_resolved_prop "$name" selectedIndex 0; local old=${FT_RET:-0}
    local new=$(( (old + 1) % n ))
    _ft_option_value "${FT_OPTS[$new]}"; local newval=$FT_RET
    ft_set "$name" selectedIndex="$new"      # `value` follows the index in _ft_multitoggle_setprop
    # on_activate when the new value is truthy; on_deactivate when it toggled to
    # `false` (a checkbox unchecking). $this=name, $1=new value; nonzero cancels.
    local event=on_activate
    [[ "$newval" == false ]] && ft_has_listener "$name" deactivate && event=on_deactivate
    _ft_hook "$name" "$event" "$newval" || ft_set "$name" selectedIndex="$old"
    return 0
}
