#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — controls/ft-radio.bash
#
#  The "radio" prototype: a mutually-exclusive option — a `group` name and a
#  `text` label beside a ●/○ glyph. `checked` is the selection, exactly as on
#  <input type=radio>: writing it selects this one and deselects the group,
#  reading it says whether this one is on. FT_RADIO_SELECTED[group] is the
#  INDEX over that — the one question a per-control property cannot answer,
#  "which member of group G is on", which is what ft_radio_value is handed a
#  group name for. Activating a focused radio (ENTER/SPACE via the shared
#  activate keymap, or its accessKey) selects it through ft_activate, then
#  calls onActivate=fn for app logic.
#
#  SCOPED BY GROUP ALONE, ACROSS PARENTS. This header used to claim "siblings
#  sharing the same parent and group"; nothing in this file has ever read
#  FT_PARENT, and the behaviour is group-only. That is the correct DOM copy —
#  HTML groups radios by `name` across the whole form, not by common parent —
#  so the comment was the wrong half, and it is the comment that changed.
#
#  Depends on ft-core.bash and ft-forms.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_RADIO_LOADED:-}" ]] && return 0
_FT_RADIO_LOADED=1

ft_prototype_radio() {
    ft_prototype extends=ft_control focusable=true mouse=activate keymap=activate \
        setProp=_ft_radio_setprop \
        defaults="display=inline-block checked=false"
}

# `checked` IS the selection, exactly as it is on <input type=radio>: setting it selects this
# radio and deselects the group, and reading it says whether this one is on.
#
# It used to do NEITHER. `ft-radio name=r1 group=g checked=true` stored a property nothing read
# and drew an EMPTY circle; `ft_set r1 checked=true` did the same at runtime. The selection
# lived only in FT_RADIO_SELECTED, a table with no property route in at all — the shape
# CONTRIBUTING §1 lists three other instances of, in its purest form: not a route that was
# forgotten, a route that was never built.
#
# Reconciling through setProp covers CONSTRUCTION as well as ft_set, which matters because a
# radio has no `ft_end` and therefore no children-complete hook to apply `checked=` at.
#
# `group` is on the list because the selection is INDEXED by it: a radio that changes group has
# to release the old group's index and claim the new one, and _ft_setprop stores before it
# reconciles, so the old group is found by asking the index who it points at rather than by
# reading a property that has already moved.
_ft_radio_setprop() {           # name prop value
    local name=$1 g
    case $2 in
        checked)
            if _ft_truthy "$3"; then ft_radio_select "$name"     # ONE predicate — see _ft_truthy
            else                     ft_radio_deselect "$name"; fi ;;
        group)
            _ft_get_raw "$name" checked
            [[ "$FT_RET" == true ]] || return 0
            for g in "${!FT_RADIO_SELECTED[@]}"; do
                [[ "${FT_RADIO_SELECTED[$g]}" == "$name" ]] && unset "FT_RADIO_SELECTED[$g]"
            done
            _ft_stamp_prop "$name" checked false     # so the select below is not a no-op
            ft_radio_select "$name" ;;
    esac
    return 0
}

# A RADIO WRITTEN WITHOUT `value=` HAS ONE ANYWAY, and it is its name. That was already the
# answer — ft_radio_value has always said so, in its own header — but it said it by falling back
# at the READ, so the fact had two spellings that disagreed:
#
#     ft-radio name=rA group=h "Alpha"     ft_get rA value   →  (nothing)
#     ft_radio_select rA                   ft_radio_value h  →  rA
#
# The property an app reads was the emptier of the two, and a state save carried the emptier
# one. Materialised once here, at the only place every radio passes through, so the property,
# the group query and a save all answer the same thing — the shape ft-slider's midpoint uses,
# for the same reason. An EXPLICIT `value=` of any kind, including the empty string, is left
# exactly as written: HTML's placeholder row is a real value and this must not invent over it.
ft-radio() {
    ft_new radio "$@" || return
    local n=$FT_RET
    _ft_has_prop "$n" value || _ft_stamp_prop "$n" value "$n"
    FT_RET=$n
}

# _ft_radio_group NAME → FT_RET = the group this radio belongs to.
#
# A radio declared WITHOUT group= is not an error — HTML's `<input type=radio>` with no name
# is still a radio, it is simply grouped with nothing, so selecting it can never deselect
# anything else. Its own name is therefore its group: a group of one, which behaves exactly
# that way for free.
#
# Before this, the missing property left FT_RET EMPTY and every caller subscripted
# FT_RADIO_SELECTED with "" — a bash "bad array subscript" error on stderr, which in a TUI is
# the alt screen. Four separate paths did it: select, is_selected, the draw, and activate. So
# `ft-radio name=x "Label"` — forgetting one attribute — scribbled errors over the UI.
_ft_radio_group() {             # name → FT_RET (never empty)
    ft_resolved_prop "$1" group
    [[ -z "$FT_RET" ]] && FT_RET=$1
    return 0
}

# A group's selection is stored under the GROUP name, not the control's — so ft_remove could
# not release it and the leak scan (which looks for the control's name) could not see it. Left
# behind, it points at a control that no longer exists: a group rebuilt with different names
# reports `r2` selected while nothing on screen is, and a rebuild silently inherits a choice
# the user made in a previous screen. Same rule as a textfield's caret — a rebuilt control
# starts clean, and Ctrl+S is what carries a choice across a restart (see ft-state.bash).
_ft_destroy_radio() {           # name
    _ft_radio_group "$1"
    [[ "${FT_RADIO_SELECTED[$FT_RET]:-}" == "$1" ]] && unset "FT_RADIO_SELECTED[$FT_RET]"
    return 0                    # the `checked` property goes with the control, like every other
}

# Intrinsic: glyph (1 col) + separating space + text.
_ft_preferred_width_radio() {             # name → FT_RET (content columns)
    ft_resolved_prop "$1" text; local text=$FT_RET
    ft_resolved_prop "$1" accessKey; _ft_accel_text "$text" "$FT_RET"   # may add " (X)"
    ft_display_width "$FT_RET"
    FT_RET=$(( FT_DISPLAY_WIDTH + 2 ))
}
_ft_height_radio() {            # name contentwidth → FT_RET (content rows)
    ft_resolved_prop "$1" text
    _ft_text_extent_cached "$1" "$FT_RET"
    FT_RET=$FT_TEXT_HEIGHT
}

declare -A FT_RADIO_SELECTED=()

_ft_draw_radio() {                       # name
    local name=$1
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local cols=${FT_MEASURED_WIDTH[$name]:-0}
    (( cols < 1 )) && return

    ft_resolved_prop "$name" text;  local text=$FT_RET
    ft_resolved_prop "$name" accessKey; local accessKey=$FT_RET

    local glyph; ft_radio_is_selected "$name" && glyph="$FT_GLYPH_RADIO_ON" || glyph="$FT_GLYPH_RADIO_OFF"
    local base; [[ "${FT_FOCUS:-}" == "$name" ]] && base="$FT_COLOR_SEL" || base="$FT_COLOR_BODY"
    _ft_compose_sgr "$name" "$base"; local sgr=$FT_RET   # cascaded bg/fg/weight/decoration

    _ft_accel_markup "$text" "$accessKey" "$sgr"
    local out="$glyph $FT_RET"

    ft_fit "$out" "$cols"
    ft_print_at "$row" "$col" "$sgr$FT_FIT$FT_COLOR_RESET"
}

ft_radio_select() {                      # name — selects it, deselects group siblings
    _ft_ctl "${1-}" || return 1; set -- "$FT_RET" "${@:2}"    # a path, a tail of one, or a plain name
    local name=$1
    _ft_radio_group "$name"; local grp=$FT_RET
    local prev=${FT_RADIO_SELECTED[$grp]:-}
    # NORMALISE FIRST, THEN DECIDE WHETHER ANYTHING MOVED. The early return used to come before
    # the stamp, so a truthy spelling other than the literal `true`, written to a radio that was
    # ALREADY selected, was stored verbatim and never canonicalised. Measured:
    # `ft_set r1 checked=1` on the selected r1 left the raw property `1`, and
    # ft_radio_is_selected — which tests `== true` — then said NO, so the radio painted ○ while
    # FT_RADIO_SELECTED still named it. Three answers to one question, and the same write on an
    # UNselected radio worked, which is what kept it hidden.
    _ft_stamp_prop "$name" checked true
    [[ "$prev" == "$name" ]] && return 0
    FT_RADIO_SELECTED[$grp]=$name
    # Only the two radios whose glyph actually changed need repainting — no
    # sweep of the whole group (and no value mutation: a radio's `value` is its
    # OPTION value, like <select>'s; the group's CURRENT value is read below).
    # Stamped, not set: _ft_setprop calls US, so writing back through it would recurse.
    [[ -n "$prev" ]] && { _ft_stamp_prop "$prev" checked false; ft_dirty "$prev"; }
    ft_dirty "$name"                        # …the stamp for THIS one is above, unconditional
}
# The counterpart, because `checked=false` has to mean something: a group with nothing selected
# is a real state (it is how every group starts), so this leaves the group EMPTY rather than
# picking a replacement.
ft_radio_deselect() {                    # name — no-op unless this one is the group's selection
    local name=$1
    _ft_radio_group "$name"; local grp=$FT_RET
    _ft_stamp_prop "$name" checked false
    [[ "${FT_RADIO_SELECTED[$grp]:-}" == "$name" ]] || return 0
    unset "FT_RADIO_SELECTED[$grp]"
    ft_dirty "$name"
    return 0
}
# The PROPERTY is the truth — one control, one fact, answered without a group lookup.
# FT_RADIO_SELECTED is an INDEX over it: the only question it answers that a property cannot is
# "which member of group G is on", asked by ft_radio_value with a group name and no control.
ft_radio_is_selected() {                 # name → exit 0 if it is the one that is on
    _ft_get_raw "$1" checked
    [[ "$FT_RET" == true ]]
}

# ft_radio_value GROUP [OUTVAR] — the ft_get-style read for a radio group: the `value` of the
# currently-selected radio, or "" if nothing is selected. One call, every option, fork-free —
# this replaces chains of `ft_radio_is_selected rX && v=x`.
#   ft_radio_value comp comp        # comp := "none" | "fast" | "best" | ""
#
# IT NO LONGER FALLS BACK TO THE NAME. It used to, which is where the second answer came from:
# the radio itself reported nothing while this reported the name. The fallback moved to the one
# place it can be a FACT rather than a guess — ft-radio(), where a radio with no value= is given
# its name as one. So this reads the property and only the property, which also means an
# explicit `value=""` finally survives being read back.
ft_radio_value() {
    local sel=${FT_RADIO_SELECTED[$1]:-}
    if [[ -n "$sel" ]]; then
        ft_resolved_prop "$sel" value ""
    else
        FT_RET=""
    fi
    [[ -n "${2:-}" ]] && printf -v "$2" '%s' "$FT_RET"
    return 0
}
