#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — controls/ft-checkbox.bash
#
#  A checkbox is a two-option multitoggle: value false ↔ true, glyphs are the
#  presentation. `value` is kept current automatically — your button's _on_activate
#  just reads it; no activation handler needed. Optional instance hooks:
#  onActivate=fn fires when it becomes CHECKED, onDeactivate=fn
#  when it becomes UNCHECKED (either may return nonzero to cancel).
#
#      ft-checkbox name=cbBeep text="Beep on submit" accessKey=P checked=false
#      ...
#      cbBeep_on_activate()   { ft-modify rSingle disabled=false; }
#      cbBeep_on_deactivate() { ft-modify rSingle disabled=true; }
#
#  Depends on ft-core.bash, ft-forms.bash, controls/ft-multitoggle.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_CHECKBOX_LOADED:-}" ]] && return 0
_FT_CHECKBOX_LOADED=1

_ft_checkmark_states() {                 # variant → FT_RET "OFFGLYPH<US>ONGLYPH"
    case "$1" in
        unicode)
            if (( FT_USE_UTF8 )); then FT_RET=$'\xe2\x98\x90\x1f\xe2\x98\x91'   # ☐ ☑
            else FT_RET="${FT_GLYPH_CHECK_OFF}"$'\x1f'"${FT_GLYPH_CHECK_ON}"; fi
            ;;
        *) FT_RET="${FT_GLYPH_CHECK_OFF}"$'\x1f'"${FT_GLYPH_CHECK_ON}" ;;               # [ ] / [x]
    esac
}

# A checkbox is its OWN type (so `checkbox { … }` in CSS matches it) that INHERITS the
# multitoggle machinery via the constructor chain — draw, keymap, mouse, cycle-on-activate.
# Without this a checkbox reported FT_TYPE=multitoggle and a `checkbox` selector matched
# nothing (a real hole in the CSS model). ft_activate also cycles it (see its type case).
ft_class_checkbox() {
    # A RECONCILER OF ITS OWN, AND THE REASON IS THE POINT. The one deleted in 1d9f939 existed
    # only to call its parent's and then reflect `checked` — a debt belonging to the class that
    # ACCEPTS `checked=`, which is the multitoggle, and which pays it itself now. This one has
    # work nothing above it has heard of: `checkmarkVariant` is the checkbox's own property. It
    # delegates first because FT_CLASS_SETPROP is one slot per class, so a subclass's REPLACES
    # the inherited one rather than adding to it.
    # …and the variant is DECLARED, so a checkbox nobody wrote one on still answers `box` when
    # asked which glyphs it is wearing, instead of answering nothing while wearing them.
    ft_class extends=multitoggle setProp=_ft_checkbox_setprop \
             defaults="importance=important checkmarkVariant=box"
    # `[ ]` is three columns and `☐` is one, so the variant decides the control's WIDTH.
    ft_prop_kind_set checkmarkVariant layout
}
# THE VARIANT IS A PROPERTY, and the two option glyphs are what it means. It used to be a
# constructor ARGUMENT, consumed and thrown away — so a checkbox drawing ☑ answered nothing when
# asked why, and at runtime it was worse:
#
#     ft-checkbox name=cb "Unicode" checkmarkVariant=unicode   painted ☑   ft_get <unset>
#     ft-modify cb checkmarkVariant=unicode                    painted [x] ft_get unicode
#
# The name stored and the glyphs untouched, which is this sweep's shape exactly. One function
# turns the variant into the two glyphs now, and both routes in call it: the reconciler below
# for a write, and children-complete for the constructor — which no longer computes glyphs of
# its own, because the options do not exist yet when it runs.
_ft_checkbox_setprop() {        # name prop value previous
    _ft_multitoggle_setprop "$@"
    [[ "$2" == checkmarkVariant ]] || return 0
    # Normalized at the write like every other keyword: ft_get may only answer a variant that
    # draws. `heavy` fell silently through to the box glyphs and read back as `heavy`.
    local want=${3,,}
    case $want in box|unicode) ;; *) want=box ;; esac
    [[ "$want" == "$3" ]] || _ft_stamp_prop "$1" checkmarkVariant "$want"
    _ft_checkbox_apply_variant "$1"
    return 0
}
_ft_checkbox_apply_variant() {  # name — write the variant's glyphs onto the two options
    local name=$1
    ft_resolved_prop "$name" checkmarkVariant box
    _ft_checkmark_states "$FT_RET"
    local off="${FT_RET%%$'\x1f'*}" on="${FT_RET##*$'\x1f'}"
    # The options are `value=false` then `value=true`, in that order — the constructor's own.
    # Written by VALUE rather than by position so a rebuilt or reordered pair still lands right.
    local k
    for k in ${FT_KIDS[$name]:-}; do
        _ft_get_raw "$k" value
        case $FT_RET in
            false) ft-modify "$k" glyph="$off" ;;
            true)  ft-modify "$k" glyph="$on"  ;;
        esac
    done
    return 0
}
checkbox_on_children_complete() {       # sync value after the 2 options, then seed `checked`
    _ft_multitoggle_sync "$1"
    # The options exist now, so the variant can finally reach them. (During ft_new the write of
    # `checkmarkVariant` ran the reconciler with no children to write to — harmlessly.)
    _ft_checkbox_apply_variant "$1"
    # A CHECKBOX ALWAYS HAS `checked`, whether or not anybody wrote it — it is the name its own
    # header documents and the one an app reads. Seeding it here is what makes the inherited
    # reflection maintain it from then on: that one keeps a `checked` current, it does not
    # invent one, precisely so a three-state multitoggle never grows a two-state property.
    _ft_get_raw "$1" value
    local checked=false; [[ "$FT_RET" == true ]] && checked=true
    _ft_stamp_prop "$1" checked "$checked"
    return 0
}

ft-checkbox() {                          # name=... text=... [checked=true|false] [checkmarkVariant=box|unicode] ...
    local a checked=""
    local -a rest=()
    for a in "$@"; do
        case "$a" in
            checked=*) checked="${a#checked=}" ;;
            # checkmarkVariant is NOT taken out of the list any more — it is a property of the
            # control, so it flows through like every other one and the class does the work.
            *)         rest+=("$a") ;;
        esac
    done
    # ONLY WHEN THE AUTHOR SAID `checked=`. This used to append `selectedIndex=$idx`
    # UNCONDITIONALLY, after the author's own arguments — so `ft-checkbox name=c value=true` and
    # `ft-checkbox name=c selectedIndex=1` both built an UNCHECKED box reporting value=false,
    # while the identical writes at runtime worked. The constructor was overwriting the very
    # thing it was handed.
    #
    # `checked` wins when it is given, because it is the spelling this constructor exists to
    # translate; otherwise whatever the author wrote flows through untouched and
    # _ft_multitoggle_sync reconciles it once the two options exist.
    local -a idxarg=()
    if [[ -n "$checked" ]]; then
        local idx=0; _ft_truthy "$checked" && idx=1     # ONE predicate — see _ft_truthy
        idxarg=(selectedIndex="$idx")
    fi
    ft_new checkbox "${rest[@]}" "${idxarg[@]}" && FT_NEST_STACK+=("$FT_RET")
        ft-option value=false
        ft-option value=true
    ft-end checkbox                      # …which applies the variant's glyphs to both of them
}

ft_checkbox_toggle()     { ft_multitoggle_cycle "$1"; }
ft_checkbox_is_checked() { _ft_get_raw "$1" value; [[ "$FT_RET" == true ]]; }
