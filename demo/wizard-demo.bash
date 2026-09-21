#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — demo/wizard-demo.bash   (retained mode, interactive)
#
#  Six dialogs chained into one wizard. Each dialog is a full rebuild with
#  STABLE control names (destroy the old subtree, register the same names) —
#  focus persists across steps by name; wizard-wide state (theme, checkboxes)
#  lives in plain variables updated from <name>_on_activate hooks.
#
#  Each step showcases a different feature combination:
#    1  Welcome         — label with margin
#    2  Quick Note      — custom borderColor + color
#    3  Some Details    — a checkbox ("Don't show this again")
#    4  Long Explanation— long multi-line wrapped text
#    5  Preferences     — a radio group (Theme) + a checkbox (Notifications)
#    6  Finished        — backgroundColor + borderColor + color together
#
#  No _handle_event anywhere: TAB/arrows and ESC come from the form
#  prototype keymap; ENTER/SPACE activate the focused control through its
#  prototype keymap
#  (radio selects itself, checkbox toggles itself, then the <name>_on_activate
#  hook updates wizard state); every accessKey= letter is auto-bound on the form.
#
#    bash demo/wizard-demo.bash
# ─────────────────────────────────────────────────────────────────────────────
set -o pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/fruity-tui.bash"
ft_init
ft_term_size

LAST_STEP=6
CUR_STEP=1

# Wizard-wide state — survives every dialog rebuild.
WIZ_THEME="Dark"        # Light/Dark/Auto
WIZ_NOTIFY=true
WIZ_DONTSHOW=false

_step_config() {                 # step → TITLE TEXT WIDTH HEIGHT BGCOLOR BORDERCOLOR TEXTCOLOR MARGIN EXTRA
    BGCOLOR=""; BORDERCOLOR=""; TEXTCOLOR=""; MARGIN=0; EXTRA=""
    case "$1" in
        1) TITLE="Welcome";      TEXT="Welcome to the Fruity TUI wizard!"
           WIDTH=44; HEIGHT=7;  BORDERCOLOR=teal; MARGIN=1 ;;
        2) TITLE="Quick Note";   TEXT="This step has a short message."
           WIDTH=40; HEIGHT=5;  BORDERCOLOR=blue; TEXTCOLOR=brightcyan ;;
        3) TITLE="Some Details"; TEXT="Here's a medium amount of text for this particular screen."
           WIDTH=64; HEIGHT=8;  BORDERCOLOR=purple; MARGIN=1; EXTRA=confirm ;;
        4) TITLE="Long Explanation"
           TEXT=$'This dialog intentionally contains a much\nlonger message than the others, to make\nsure multi-line text sizing, vertical\ncentering, and box height all keep working\ncorrectly when there is a lot to say\ninstead of just one short sentence.'
           WIDTH=54; HEIGHT=10; BORDERCOLOR=orange; TEXTCOLOR=gold ;;
        5) TITLE="Preferences";  TEXT="Choose your preferences below."
           WIDTH=50; HEIGHT=18; BORDERCOLOR=green; MARGIN=1; EXTRA=options ;;
        6) TITLE="Finished";     TEXT="All done! Thanks for trying Fruity TUI."
           WIDTH=46; HEIGHT=7;  BGCOLOR=navy; BORDERCOLOR=gold; TEXTCOLOR=brightwhite; MARGIN=1 ;;
    esac
}

_build_dialog() {                # step
    local step=$1
    _step_config "$step"

    ft_empty app
    ft-frame name=win \
             width="$WIDTH" height="$HEIGHT" title="$TITLE" \
             display=flex flexDirection=column gap=1 \
             justifyContent=center alignItems=center \
             backgroundColor="$BGCOLOR" borderColor="$BORDERCOLOR"
        ft-label name=msg text="$TEXT" margin="$MARGIN" color="$TEXTCOLOR"

        case "$EXTRA" in
            confirm)
                ft-checkbox name=cbDontShow text="Don't show this again" onActivate='cbDontShow_on_activate "$@"' \
                            accessKey=W checked="$WIZ_DONTSHOW" margin=1
                ;;
            options)
                ft-div name=themeGrp display=flex flexDirection=column gap=0 margin=1 alignItems=start
                    ft-label name=themeHdr text="Theme:"
                    ft-radio name=rLight text="Light" group=theme accessKey=L onActivate='rLight_on_activate "$@"'
                    ft-radio name=rDark  text="Dark"  group=theme accessKey=D onActivate='rDark_on_activate "$@"'
                    ft-radio name=rAuto  text="Auto"  group=theme accessKey=U onActivate='rAuto_on_activate "$@"'
                end_ft_div
                case "$WIZ_THEME" in
                    Light) ft_radio_select rLight ;;
                    Auto)  ft_radio_select rAuto  ;;
                    *)     ft_radio_select rDark  ;;
                esac
                ft-div name=optGrp display=flex flexDirection=column gap=0 margin=1 alignItems=start
                    ft-checkbox name=cbNotify text="Enable notifications" onActivate='cbNotify_on_activate "$@"' \
                                accessKey=N checked="$WIZ_NOTIFY"
                end_ft_div
                ;;
        esac

        ft-div name=btnrow display=flex gap=2 justifyContent=center
            if (( step > 1 )); then
                ft-button name=btnBack text=Back accessKey=B onActivate='btnBack_on_activate "$@"'
            fi
            local oklabel=OK
            (( step == LAST_STEP )) && oklabel=Finish
            ft-button name=btnOk text="$oklabel" accessKey=K onActivate='btnOk_on_activate "$@"'
        end_ft_div
    end_ft_frame
    end_ft_form
    CUR_STEP=$step
    ft_refresh
    # First-ever build: default focus to OK, not the first focusable — the
    # sensible wizard default. After that, name persistence does the work.
    [[ -z "${FT_TYPE[$FT_FOCUS]:-}" ]] && ft_focus btnOk
}

# ── Wizard logic: pure activation hooks ──────────────────────────────────────
btnOk_on_activate() {
    if (( CUR_STEP < LAST_STEP )); then _build_dialog $(( CUR_STEP + 1 )); else ft_quit; fi
}
btnBack_on_activate() { _build_dialog $(( CUR_STEP - 1 )); }
rLight_on_activate()  { WIZ_THEME=Light; }
rDark_on_activate()   { WIZ_THEME=Dark; }
rAuto_on_activate()   { WIZ_THEME=Auto; }
cbNotify_on_activate()   { ft_checkbox_is_checked cbNotify   && WIZ_NOTIFY=true   || WIZ_NOTIFY=false; }
cbDontShow_on_activate() { ft_checkbox_is_checked cbDontShow && WIZ_DONTSHOW=true || WIZ_DONTSHOW=false; }

_setup() { _build_dialog 1; }

ft-form name=app width="$FT_COLS" height="$FT_ROWS" \
        display=flex justifyContent=center alignItems=center \
        key='[Qq]' onKey=ft_quit
end_ft_form
ft_run app _setup
