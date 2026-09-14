#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — ft-settings.bash   (the Settings modal, opened with F2)
#
#  A dedicated screen for capability toggles. Features the current system can't do
#  are shown DIMMED-but-present (disabled=true) with a one-line reason, so the user
#  learns what's possible everywhere — like a real GUI's greyed-out menu items.
#  Built on the modal-context stack, so it can stack over help or anything else.
#
#  Depends on ft-forms, ft-frame, ft-checkbox, ft-button, ft-keyboard, ft-wtfix.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_SETTINGS_LOADED:-}" ]] && return 0
_FT_SETTINGS_LOADED=1

_FT_SETTINGS_CLOSE=0

# The status line under the WT toggle — ALWAYS derived from FT_WINDOWS_TERMINAL_APPLIED, so the
# build and the live toggle can't disagree (the earlier bug: the build tested a
# "true"/"false" STRING with (( )), which reads as 0, so it always showed "off").
_ft_settings_wt_note() {        # → FT_RET
    if (( ${FT_WINDOWS_TERMINAL_APPLIED:-0} )); then
        FT_RET="  On — Ctrl+Shift+Home/End/Up/Down reach the app (restored on exit)"
    else
        FT_RET="  Off — Windows Terminal keeps those keys for scrollback"
    fi
}

# Checkbox / button hooks (live only while the modal is up).
_ft_settings_cc_note() {        # → FT_RET — derived from the SAME global the checkbox shows
    if (( ${FT_CTRL_C_COPY:-0} )); then
        FT_RET="  On — copies a selection; quits when nothing is selected"
    else
        FT_RET="  Off — Ctrl+C always quits (Alt+W copies)"
    fi
}
__setcc_on_activate()   { ft_ctrl_c_copy_set 1; _ft_settings_cc_note; ft-modify __setccnote text="$FT_RET"; ft_dirty __setccnote; }
__setcc_on_deactivate() { ft_ctrl_c_copy_set 0; _ft_settings_cc_note; ft-modify __setccnote text="$FT_RET"; ft_dirty __setccnote; }
__setclose_on_activate() { _FT_SETTINGS_CLOSE=1; }
__setwt_on_activate()   { ft_wt_autofix_enter; _ft_settings_wt_note; ft-modify __setwtnote text="$FT_RET"; ft_dirty __setwtnote; }
__setwt_on_deactivate() { ft_wt_autofix_exit;  _ft_settings_wt_note; ft-modify __setwtnote text="$FT_RET"; ft_dirty __setwtnote; }

# _ft_settings_build — construct the __settings form (split out for testing).
_ft_settings_build() {
    local ww=$(( FT_COLS - 8 )); (( ww > 64 )) && ww=64; (( ww < 34 )) && ww=34
    local wh=$(( FT_ROWS - 4 )); (( wh > 18 )) && wh=18; (( wh < 10 )) && wh=10

    # Probe capabilities (all read-only / no side effects).
    local wt=0; declare -F ft_wt_find >/dev/null && ft_wt_find && wt=1
    local kbd="legacy"; [[ -n "${FT_KEYBOARD_PROTOCOL:-}" ]] && kbd=$FT_KEYBOARD_PROTOCOL
    ft_kbd_summary 2>/dev/null || FT_RET="keyboard: legacy"; local kbdsummary=$FT_RET
    local ismac=0; [[ "${OSTYPE:-}" == darwin* ]] && ismac=1
    local wtchecked=false; (( ${FT_WINDOWS_TERMINAL_APPLIED:-0} )) && wtchecked=true
    _ft_settings_wt_note; local wtnote=$FT_RET    # note derived from the SAME source as the checkbox
    local ccchecked=false; (( ${FT_CTRL_C_COPY:-0} )) && ccchecked=true
    _ft_settings_cc_note; local ccnote=$FT_RET

    ft-form name=__settings width="$FT_COLS" height="$FT_ROWS" \
            display=flex justifyContent=center alignItems=center
        ft-frame name=__setwin title=" Settings — Esc to close " borderStyle=double \
                 display=flex flexDirection=column gap=0 padding=1 width="$ww" height="$wh"

            ft-label name=__sethk1 color=accent "Keyboard"
            ft-label name=__setkbd color=muted "  $kbdsummary"
            ft-label name=__setsp1 " "

            ft-label name=__sethk2 color=accent "Windows Terminal"
            if (( wt )); then
                ft-checkbox name=__setwt accessKey=F checked="$wtchecked" onActivate=__setwt_on_activate onDeactivate=__setwt_on_deactivate \
                            "Take Ctrl+Shift+Home/End/Up/Down from scrollback"
            else
                ft-checkbox name=__setwt disabled=true onActivate=__setwt_on_activate onDeactivate=__setwt_on_deactivate \
                            "Take Ctrl+Shift nav keys from scrollback (Windows Terminal only)"
            fi
            ft-label name=__setwtnote color=muted "$wtnote"
            ft-label name=__setsp2 " "

            ft-label name=__sethk4 color=accent "Editing"
            ft-checkbox name=__setcc accessKey=K checked="$ccchecked" \
                        onActivate=__setcc_on_activate onDeactivate=__setcc_on_deactivate \
                        "Ctrl+C copies a selection instead of quitting"
            ft-label name=__setccnote color=muted "$ccnote"
            ft-label name=__setsp4 " "

            ft-label name=__sethk3 color=accent "macOS"
            if (( ismac )); then
                ft-checkbox name=__setmeta "Option key sends Meta/Alt (enable in your terminal)"
            else
                ft-checkbox name=__setmeta disabled=true "Option-as-Meta — macOS only"
            fi
            ft-label name=__setsp3 " "

            ft-div name=__setbtns display=flex justifyContent=center width=$(( ww - 4 ))
                ft-button name=__setclose accessKey=C Close onActivate=__setclose_on_activate
            end_ft_div
        end_ft_frame
    end_ft_form
}

# ft_settings — open the Settings modal (F2). Safe to call from anywhere.
ft_settings() {
    ft_modal_push
    _ft_settings_build
    _FT_SETTINGS_CLOSE=0
    FT_ROOT=__settings; FT_COALESCING=0
    ft_layout __settings; ft_focus_first
    ft_repaint_all __settings

    local rc tok
    while true; do
        ft_next_event; rc=$?
        if (( rc == 2 )); then
            FT_WINCH=0; ft_term_size
            _ft_setprop __settings width "$FT_COLS"; _ft_setprop __settings height "$FT_ROWS"
            ft_layout __settings; ft_repaint_all __settings; continue
        fi
        (( rc != 0 )) && break
        [[ "$FT_EVENT_TOKEN" == ESC || "$FT_EVENT_TOKEN" == F2 ]] && break
        if [[ "$FT_EVENT_TOKEN" == MOUSE ]]; then _ft_dispatch_mouse
        else tok=$FT_EVENT_TOKEN; [[ "$FT_EVENT_TOKEN" == CHAR ]] && tok=$FT_EVENT_CHAR; ft_dispatch_event "$tok"; fi
        (( _FT_SETTINGS_CLOSE )) && break
        ft_redraw_dirty
    done

    ft_remove __settings
    ft_modal_pop
    ft_repaint_all "$FT_ROOT"
}
