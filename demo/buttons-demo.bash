#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — demo/buttons-demo.bash   (retained mode, interactive)
#
#  Six worked examples exercising different widths, heights, titles, and
#  single- vs multi-line text, each with a different button count (1-6) —
#  at 6, two stacked button rows.
#
#    bash demo/buttons-demo.bash N      (N = 1..6, default 3)
#
#  Buttons are generated from specs, so their on_activate hooks are generated
#  too: each reports "<label> clicked!" (btnQuit's quits). Focus order is
#  declaration order; accessKey letters are auto-bound; Q/ESC quit.
# ─────────────────────────────────────────────────────────────────────────────
set -o pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/fruity-tui.bash"
ft_init
ft_term_size

N=${1:-3}
[[ "$N" =~ ^[1-6]$ ]] || { printf 'Usage: %s [1-6]\n' "$0" >&2; exit 1; }

TWOROWS=0
case "$N" in
    1) TITLE="Confirm";          TEXT="Are you sure?"
       WIDTH=28; HEIGHT=5; SPECS=(btnOk:OK:K) ;;
    2) TITLE="Save Changes";     TEXT="You have unsaved changes."
       WIDTH=36; HEIGHT=5; SPECS=(btnOk:OK:K btnCancel:Cancel:C) ;;
    3) TITLE="Preferences";      TEXT="Choose how you'd like to proceed."
       WIDTH=44; HEIGHT=5; SPECS=(btnOk:OK:K btnHelp:Help:H btnQuit:Quit:Q) ;;
    4) TITLE="Unsaved Document"; TEXT=$'This document has unsaved changes.\nWhat would you like to do?'
       WIDTH=44; HEIGHT=6
       SPECS=(btnSave:Save:S btnDiscard:Discard:D btnHelp:Help:H btnCancel:Cancel:C) ;;
    5) TITLE="Setup Wizard";     TEXT="Step 3 of 5: Configure your options."
       WIDTH=48; HEIGHT=5
       SPECS=(btnBack:Back:B btnNext:Next:N btnHelp:Help:H btnSave:Save:S btnQuit:Quit:Q) ;;
    6) TITLE="Toolbar Demo";     TEXT="Six actions, arranged across two rows."
       WIDTH=48; HEIGHT=7; TWOROWS=1
       ROW1_SPECS=(btnNew:New:N btnOpen:Open:O btnSave:Save:S)
       ROW2_SPECS=(btnHelp:Help:H btnUndo:Undo:U btnQuit:Quit:Q) ;;
esac

# Generate one button + one on_activate hook per "name:label:accessKey" spec.
_emit_buttons() {               # spec...
    local spec name label accessKey rest
    for spec in "$@"; do
        name="${spec%%:*}"; rest="${spec#*:}"
        label="${rest%:*}"; accessKey="${rest##*:}"
        ft-button name="$name" text="$label" accessKey="$accessKey"
        if [[ "$name" == btnQuit ]]; then
            eval "${name}_on_activate() { ft_quit; }"
        else
            local trimmed="${label#"${label%%[![:space:]]*}"}"
            trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
            eval "${name}_on_activate() { ft-modify msg text=\"${trimmed} clicked!\"; }"
        fi
    done
}

ft-form name=app width="$FT_COLS" height="$FT_ROWS" keymap '[Qq]'=ft_quit
    ft-frame name=win position=absolute left=4 top=2 width="$WIDTH" height="$HEIGHT" \
             text="$TITLE" display=flex flexDirection=column gap=1 \
             justifyContent=center alignItems=center
        ft-label name=msg text="$TEXT"
        if (( TWOROWS )); then
            ft-div name=btnrow1 display=flex gap=2 justifyContent=center
                _emit_buttons "${ROW1_SPECS[@]}"
            end_ft_div
            ft-div name=btnrow2 display=flex gap=2 justifyContent=center
                _emit_buttons "${ROW2_SPECS[@]}"
            end_ft_div
        else
            ft-div name=btnrow display=flex gap=2 justifyContent=center
                _emit_buttons "${SPECS[@]}"
            end_ft_div
        fi
    end_ft_frame
end_ft_form

_setup() { ft_layout app; }
ft-run app _setup
