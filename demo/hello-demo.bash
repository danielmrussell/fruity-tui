#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — demo/hello-demo.bash   (retained mode, interactive)
#
#  The smallest complete Fruity TUI program — and a fair picture of the whole
#  API: a nested declarative tree (CSS properties, containers as envelopes),
#  no parent= (nesting implies it), no focus code (Tab order = declaration
#  order, assembled at end_ft_form), no event loop code (ENTER/SPACE activate
#  the focused button via its prototype keymap; K/Q are accessKey= sugar;
#  Tab/arrows and ESC come from the form's prototype keymap). App logic = two
#  functions.
#
#    bash demo/hello-demo.bash
# ─────────────────────────────────────────────────────────────────────────────
set -o pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/fruity-tui.bash"
ft_init
ft_term_size

ft-form name=app width="$FT_COLS" height="$FT_ROWS" key='[Qq]' onKey=ft_quit
    ft-frame name=win position=absolute left=4 top=2 width=40 height=5 \
             title=Hello display=flex flexDirection=column gap=1 \
             justifyContent=center alignItems=center
        ft-label name=msg text="Hello from retained mode!"
        ft-div name=btnrow display=flex gap=2 justifyContent=center
            ft-button name=btnOk text=OK accessKey=K onActivate='btnOk_on_activate "$@"'
            ft-button name=btnQuit text=Quit accessKey=Q onActivate='btnQuit_on_activate "$@"'
        end_ft_div
    end_ft_frame
end_ft_form

btnOk_on_activate()   { ft_set msg text="OK clicked!"; }
btnQuit_on_activate() { ft_quit; }

_setup() { ft_layout app; }
ft_run app _setup
