#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — controls/ft-keylegend.bash
#
#  The KEY LEGEND: a one-row block leaf listing "keycap + action" pairs. Split out
#  from the status bar so the two concerns are separate controls — stack a
#  ft-keylegend above a ft-statusbar to get the classic two-row bar, but a handler
#  updating the synopsis can never touch the legend and vice-versa.
#
#      ft-keylegend name=legend keys="Enter=Open  Ctrl+N=New Folder  Esc=Cancel"
#      ft-keylegend name=legend keys=auto      # DERIVED from the focused control
#
#  keys= is a list of "KEY=Label" pairs separated by TWO-OR-MORE spaces (so a label
#  may itself contain single spaces, e.g. "New Folder"). A bare token with no "=" is
#  drawn as plain text. keys=auto derives the caps from the focused control's keymap
#  chain, already sorted by importance. Crucial caps pulse; in a MODE the exit key
#  (Esc) leads and breathes the exit ramp.
#
#  Colours resolve through the cascade: `keylegend { … }` / `#legend { … }` tint the
#  strip, `keylegend::keycap { … }` the caps. Never a focus stop.
#
#  Depends on ft-core.bash and ft-forms.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_KEYLEGEND_LOADED:-}" ]] && return 0
_FT_KEYLEGEND_LOADED=1

ft_class_keylegend() {
    ft_class extends=ft_control focusable=false defaults="display=block keys= capStyle=boxed importance=crucial"
    ft_prop_kind_set keys paint     # value CONTAINS spaces → register so it isn't split as content
    ft_prop_kind_set capStyle layout   # boxed is 3 rows tall — a size change, so it reflows
}

ft-keylegend() { ft_new keylegend "$@"; }

_ft_destroy_keylegend() {       # the pulse itself is shared and keyed globally; the cell
    ft_anim_stop "$1"           # positions are per instance and must go with the instance
    unset "FT_KEYLEGEND_ANIMATED_CELLS[$1]"
}

# capStyle=boxed  → THE DEFAULT. Three rows, each cap drawn as a key:
#         ╭───────╮        ╭─────╮
#         │ Enter │ Edit   │ Esc │ Done
#         ╰───────╯        ╰─────╯
# capStyle=flat   → one row, "Enter: Edit" — for a screen that cannot spare the two rows.
# `boxed` is the class DEFAULT, so this cannot read the instance variable alone: with defaults
# resolved at cascade level 5 rather than stamped onto the control, a raw read answers "" and
# the legend lays out one row tall instead of three.
_ft_kl_boxed() { _ft_prop_or_class "$1" capStyle ""; [[ "$FT_RET" == boxed ]]; }
_ft_height_keylegend() { _ft_kl_boxed "$1" && FT_RET=3 || FT_RET=1; }

# _ft_kl_split LEGEND → fills FT_KEYLEGEND_PAIRS[] with the "KEY=Label" / bare tokens, splitting only
# on runs of TWO-OR-MORE spaces so single-space labels survive. Fork-free char scan.
_ft_kl_split() {                # legend
    local s=$1                       # (n depends on s — MUST be a separate init)
    local n=${#s} i ch cur="" spaces=0
    FT_KEYLEGEND_PAIRS=()
    for (( i=0; i<n; i++ )); do
        ch=${s:i:1}
        if [[ "$ch" == " " ]]; then
            (( spaces++ ))
        else
            if (( spaces >= 2 )); then
                [[ -n "$cur" ]] && FT_KEYLEGEND_PAIRS+=("$cur"); cur=""
            elif (( spaces == 1 )) && [[ -n "$cur" ]]; then
                cur+=" "
            fi
            cur+="$ch"; spaces=0
        fi
    done
    [[ -n "$cur" ]] && FT_KEYLEGEND_PAIRS+=("$cur")
}

# Which SGR one cap wears, and whether that SGR is the pulse. ONE place, called by both the
# boxed and the unboxed renderer — they used to carry identical copies of this decision, and
# both copies were wrong in the same way, which is exactly how a bug like this survives being
# fixed.
#
# THE EXIT CHIP IS DECIDED BY THE KEY. It used to be decided by comparing colours —
# `[[ "$cap" != "$excap" ]]`, meaning "this cap is not the exit chip, so it may pulse". But
# `excap` is `${exitcap:-$keycapbase}`, and outside a mode `exitcap` is empty, so `excap` WAS
# `keycapbase`, which is what `cap` had just been set to. The test compared a value against
# itself, was false for every cap on every frame, and the pulse colour never reached a keycap
# in the app's ordinary state. Meanwhile the loop was armed anyway, so the engine re-derived
# the entire legend eight times a second forever to emit the bytes already on screen.
#
# Sets FT_KEYLEGEND_CAP_RAMP to the themeable ramp that colours this cap — `crucial`, `exit`,
# or empty for a cap that does not animate. The caller arms on what was actually painted rather
# than on what was merely available, and records where the animated caps landed so a pulse
# frame can repaint just those cells.
FT_KEYLEGEND_CAP_RAMP=""
# This legend is the PRODUCER of FT_KEYLEGEND_ANIMATED_CELLS; the pulse machinery that consumes
# it lives with the rest of _ft_kcpulse_* in ft-forms.bash, which is where it is declared.
_ft_keylegend_cap_sgr() {       # key inmode baseSgr exitSgr pulseSgr crucialSet → FT_RET
    local key=$1 inmode=$2 base_sgr=$3 exit_sgr=$4 pulse_sgr=$5 crucial_set=$6
    FT_KEYLEGEND_CAP_RAMP=""
    # The way OUT wears its own ramp and never the crucial one, so it reads as distinct.
    if [[ -n "$inmode" ]]; then
        case "$key" in
            [Ee][Ss][Cc]|[Ee]scape)
                if [[ -n "$exit_sgr" ]]; then FT_RET=$exit_sgr; FT_KEYLEGEND_CAP_RAMP=exit
                else                          FT_RET=$base_sgr; fi
                return 0 ;;
        esac
    fi
    if [[ -n "$pulse_sgr" && "$crucial_set" == *$'\n'"$key"$'\n'* ]]; then
        FT_RET=$pulse_sgr; FT_KEYLEGEND_CAP_RAMP=crucial; return 0
    fi
    FT_RET=$base_sgr
}

# Note where an animated cap landed, so _ft_kcpulse_frame can repaint that cell instead of the
# legend. Called only for caps that actually made it onto the strip — a cap the width test
# dropped is not on screen and must not be repainted onto it.
_ft_keylegend_note_animated_cell() {   # legend row col width text
    FT_KEYLEGEND_ANIMATED_CELLS[$1]+="$2"$'\t'"$3"$'\t'"$4"$'\t'"$FT_KEYLEGEND_CAP_RAMP"$'\t'"$5"$'\n'
}

_ft_draw_keylegend() {          # name
    local name=$1
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local cols=${FT_MEASURED_WIDTH[$name]:-0}
    (( cols < 1 )) && return

    ft_resolved_prop "$name" keys ""; local keys=$FT_RET
    # A special MODE (edit/cursor) makes the exit key (Esc) jump to the FRONT with a
    # highlighted cap — the way out is the one thing a stuck user needs.
    local inmode=""; [[ -n "$FT_MODE_HINT" ]] && inmode=1

    # Colours through the cascade: `keylegend { … }` tints the strip, `::keycap` the caps.
    _ft_compose_sgr "$name" "$FT_COLOR_STATUS";       local statusbase=$FT_RET
    _ft_css_pe_or   "$name" keycap "$FT_COLOR_KEYCAP"; local keycapbase=$FT_RET

    # Paint the whole strip in the bar background first, then overlay the styled legend so
    # any unfilled tail stays part of it. EVERY row — a boxed legend is three tall, and
    # filling only the first would leave the box rows sitting on the terminal's background.
    local _fillrow _fillrows=1
    _ft_kl_boxed "$name" && _fillrows=3
    ft_fit "" "$cols"
    for (( _fillrow = 0; _fillrow < _fillrows; _fillrow++ )); do
        ft_print_at_width $(( row + _fillrow )) "$col" "$statusbase$FT_FIT$FT_COLOR_RESET" "$cols"
    done
    local -a pairs=()
    local crucialset=$'\n' pulsecap="" exitcap=""   # crucial-tier caps that pulse; the exit chip
    if [[ "$keys" == auto ]]; then
        _ft_legend_caps                      # → FT_CAPS, sorted desc by importance
        local _c _rest _pat _lbl _imp
        for _c in "${FT_CAPS[@]}"; do
            _imp=${_c%%$'\t'*}; _rest=${_c#*$'\t'}; _pat=${_rest%%$'\t'*}; _lbl=${_rest#*$'\t'}
            _ft_keycap_glyph "$_pat"; pairs+=("$FT_RET=$_lbl")
            (( _imp >= 160 )) && crucialset+="$FT_RET"$'\n'   # crucial tier → animate this cap
        done
    elif [[ -n "$keys" ]]; then
        _ft_kl_split "$keys"; pairs=("${FT_KEYLEGEND_PAIRS[@]}")
    fi
    if (( ${#pairs[@]} )); then
        if [[ -n "$inmode" ]]; then          # ESC first — the exit key leads in a mode
            local -a _front=() _rest=(); local _pp
            for _pp in "${pairs[@]}"; do
                case "${_pp%%=*}" in [Ee][Ss][Cc]|[Ee]scape) _front+=("$_pp") ;; *) _rest+=("$_pp") ;; esac
            done
            pairs=("${_front[@]}" "${_rest[@]}")
        fi
        # KEYCAP PULSE: crucial caps breathe --keycap-pulse; the EXIT key (Esc in a mode)
        # breathes --keycap-exit-pulse, driven by the shared animation engine (frozen while
        # you type). "" ramp ⇒ static fallback.
        local _ph=0
        _ft_kcpulse_phase; _ph=$FT_RET
        [[ "$crucialset" != $'\n' ]] && { _ft_kcpulse_capcolor  "$name" "$_ph"; pulsecap=$FT_RET; }
        [[ -n "$inmode" ]]           && { _ft_kcpulse_exitcolor "$name" "$_ph"; exitcap=$FT_RET; }
        local out="" used=0 p key label seg segw cap
        # How many caps this draw actually painted in the pulse colour. The loop below arms the
        # animation on THIS, not on "is there a pulse colour" — see _ft_keylegend_cap_sgr.
        local pulsing_caps=0
        FT_KEYLEGEND_ANIMATED_CELLS[$name]=""   # rebuilt by this draw, from this draw's geometry
        if _ft_kl_boxed "$name"; then
            # THREE ROWS: each cap drawn as a key. The three rows are built in step so a cap
            # occupies the same columns on all of them — a per-row loop would have to redo
            # the width arithmetic three times and could drift by a column.
            local top="" mid="" bot="" kw
            # Rounded when the terminal can draw them, square ASCII when it cannot — the
            # same guard and the same glyphs the beacon's callout box uses.
            local kl_tl kl_tr kl_bl kl_br kl_v
            if (( FT_USE_UTF8 )); then kl_tl="╭" kl_tr="╮" kl_bl="╰" kl_br="╯" kl_v="│"
            else                       kl_tl="+" kl_tr="+" kl_bl="+" kl_br="+" kl_v="|"; fi
            for p in "${pairs[@]}"; do
                if [[ "$p" == *"="* ]]; then key=${p%%=*}; label=${p#*=}
                else                         key=$p;       label=""; fi
                _ft_keylegend_cap_sgr "$key" "$inmode" "$keycapbase" "$exitcap" "$pulsecap" "$crucialset"
                cap=$FT_RET
                [[ "$FT_KEYLEGEND_CAP_RAMP" == crucial ]] && pulsing_caps=$(( pulsing_caps + 1 ))
                ft_display_width "$key"; kw=$FT_DISPLAY_WIDTH      # display width, not bytes: ↑ ⇧ ^X are multi-byte
                local lw=0
                [[ -n "$label" ]] && { ft_display_width "$label"; lw=$FT_DISPLAY_WIDTH; }
                ft_hrule "$(( kw + 2 ))"
                # A cap occupies:  │ + space + key + space + │  = kw + 4 …plus " label" if any.
                # (It was kw + 3 — one short per cap, which compounded across the row and let
                # the last label run off the end and get clipped by ft_print_at.)
                segw=$(( kw + 4 ))
                (( lw )) && segw=$(( segw + lw + 1 ))
                (( used + segw > cols )) && break
                top+="$statusbase$kl_tl$FT_HRULE$kl_tr  "
                mid+="$statusbase$kl_v$cap $key $statusbase$kl_v${label:+ $label}  "
                bot+="$statusbase$kl_bl$FT_HRULE$kl_br  "
                # The cap's coloured run is " $key ", starting one column past the box's left
                # rule. `used` is display columns here (see the print below), so this is the
                # cell a pulse frame can repaint on its own.
                [[ -n "$FT_KEYLEGEND_CAP_RAMP" ]] &&
                    _ft_keylegend_note_animated_cell "$name" $(( row + 1 )) $(( col + used + 1 )) \
                                                     $(( kw + 2 )) " $key "
                # pad the top/bottom rows past the label so the next box starts square
                if (( lw )); then           # blank the label's columns on the box rows
                    ft_fit "" "$(( lw + 1 ))"
                    top+="$FT_FIT"; bot+="$FT_FIT"
                fi
                used=$(( used + segw + 2 ))
            done
            if [[ -n "$mid" ]]; then
                # `used` IS THE DISPLAY WIDTH OF ALL THREE ROWS, so say so and skip three scans.
                # Every column above was added through ft_display_width (see `kw` and `lw`), not
                # through a byte count, and the three rows are built to occupy the same columns
                # by construction. ft_print_at's clip test is BYTE length, which a colour-coded row
                # always exceeds, so each of these forced a per-character scan of a ~500-byte
                # string: measured at 42ms for one legend repaint, and the keycap pulse repaints
                # the legend on every tick — 95% of an idle app's whole paint budget.
                # (The unboxed branch below keeps ft_print_at: its `used` counts BYTES, ${#key}, so it
                # is not the display width the moment a key is multi-byte.)
                ft_print_at_width "$row"        "$col" "$top$FT_COLOR_RESET" "$used"
                ft_print_at_width $(( row + 1 )) "$col" "$mid$FT_COLOR_RESET" "$used"
                ft_print_at_width $(( row + 2 )) "$col" "$bot$FT_COLOR_RESET" "$used"
            fi
        else
        # `used` counts BYTES here (${#key}), which is not the column a cap sits in the moment a
        # key is multi-byte — ↑ ⇧ ^X all are. It still decides the clip, as it always has; a
        # separate DISPLAY-column tally rides alongside it purely so an animated cap can be
        # located, because a repaint aimed by byte count would land in the wrong place.
        local displayed=0 keyw=0 labelw=0 dsegw=0
        for p in "${pairs[@]}"; do
            if [[ "$p" == *"="* ]]; then
                key=${p%%=*}; label=${p#*=}
                _ft_keylegend_cap_sgr "$key" "$inmode" "$keycapbase" "$exitcap" "$pulsecap" "$crucialset"
                cap=$FT_RET
                [[ "$FT_KEYLEGEND_CAP_RAMP" == crucial ]] && pulsing_caps=$(( pulsing_caps + 1 ))
                seg="$cap$key$statusbase: $label"
                segw=$(( ${#key} + 2 + ${#label} ))
                ft_display_width "$key";   keyw=$FT_DISPLAY_WIDTH
                ft_display_width "$label"; labelw=$FT_DISPLAY_WIDTH
                dsegw=$(( keyw + 2 + labelw ))
            else
                seg="$statusbase$p"
                segw=${#p}
                ft_display_width "$p"; dsegw=$FT_DISPLAY_WIDTH
                key=""
            fi
            (( used + segw > cols )) && break     # stop before spilling past the strip
            [[ -n "$key" && -n "$FT_KEYLEGEND_CAP_RAMP" ]] &&
                _ft_keylegend_note_animated_cell "$name" "$row" $(( col + displayed )) \
                                                 "$keyw" "$key"
            out+="$seg   "; used=$(( used + segw + 3 )); displayed=$(( displayed + dsegw + 3 ))
        done
        [[ -n "$out" ]] && ft_print_at "$row" "$col" "$out$FT_COLOR_RESET"
        fi
    fi
    # Keep the pulse running while a cap is ACTUALLY WEARING the pulse colour, or a themed exit
    # chip is on screen. Arming on "is there a pulse colour" instead is what kept an animation
    # alive that could not change a pixel: the colour was computed 8 times a second, the caps
    # were painted in the static base, and the engine re-derived the whole legend to ship the
    # bytes it had just shipped — 1 distinct frame in 240. The count comes from the same
    # statement that assigns the colour, so the arm and the application cannot drift apart.
    if (( pulsing_caps )) || [[ -n "$exitcap" ]]; then _ft_kcpulse_arm; else _ft_kcpulse_disarm; fi
}
