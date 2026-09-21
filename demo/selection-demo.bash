#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — demo/selection-demo.bash   (retained mode, interactive)
#
#  Exercises the checkbox (a two-state multitoggle) and radio controls: a
#  mutually-exclusive "Theme" radio group, three independent checkboxes, and
#  an OK button that reports the live selection state.
#
#  Note how little app code there is: activating a radio SELECTS it and a
#  checkbox TOGGLES it as prototype behavior inside ft_activate — the app only
#  hooks btnOk_on_activate to read the state back. Focus order is declaration
#  order; every accessKey= letter is auto-bound on the form.
#
#    bash demo/selection-demo.bash
# ─────────────────────────────────────────────────────────────────────────────
set -o pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/fruity-tui.bash"
ft_init
ft_term_size

ft-form name=app width="$FT_COLS" height="$FT_ROWS" \
        display=flex justifyContent=center alignItems=center \
        key='[Qq]' onKey=ft_quit
    ft-frame name=win width=46 height=18 \
             title="Selection Controls" display=flex flexDirection=column gap=1 alignItems=center
        ft-label name=hint \
                 text=$'Tab/arrows: move    Space/Enter: pick\nAccelerator letter: pick directly'
        ft-div name=themeGrp display=flex flexDirection=column gap=0 alignItems=start
            ft-label name=themeHdr text="Theme:"
            ft-radio name=rLight text="Light" group=theme accessKey=L
            ft-radio name=rDark  text="Dark"  group=theme accessKey=D
            ft-radio name=rAuto  text="Auto"  group=theme accessKey=U
        end_ft_div
        ft-div name=optGrp display=flex flexDirection=column gap=0 alignItems=start
            ft-label name=optHdr text="Options:"
            ft-checkbox name=cbNotify text="Notifications"     checked=true  accessKey=N
            ft-checkbox name=cbSave   text="Auto-save"         checked=false accessKey=V
            ft-checkbox name=cbLines  text="Show line numbers" checked=false accessKey=W
        end_ft_div
        ft-div name=btnrow display=flex justifyContent=center
            ft-button name=btnOk text=OK accessKey=K onActivate='btnOk_on_activate "$@"'
        end_ft_div
        ft-label name=status text=""
    end_ft_frame
end_ft_form
ft_radio_select rDark   # default selection

_onoff() { ft_checkbox_is_checked "$1" && FT_RET=on || FT_RET=off; }
btnOk_on_activate() {
    local n s l
    _onoff cbNotify; n=$FT_RET
    _onoff cbSave;   s=$FT_RET
    _onoff cbLines;  l=$FT_RET
    ft_resolved_prop rLight group; local theme=${FT_RADIO_SELECTED[$FT_RET]#r}
    ft_set status text="Theme: ${theme}  Notifications: $n  Auto-save: $s  Lines: $l"
}

_setup() { ft_focus rDark; ft_refresh; }
ft_run app _setup
