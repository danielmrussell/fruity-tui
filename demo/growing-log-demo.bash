#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — demo/growing-log-demo.bash   (retained mode, interactive)
#
#  A log pane that fills up while the app runs. Three things to watch:
#
#    1  the label grows as lines arrive, and the frame grows with it,
#    2  until it reaches the docked chrome — then it scrolls instead, and the
#       scrollbar appears on its own (CSS overflow:auto),
#    3  while the key legend and status bar stay pinned across the bottom.
#
#    bash demo/growing-log-demo.bash
# ─────────────────────────────────────────────────────────────────────────────
set -o pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/fruity-tui.bash"
ft_init
ft_term_size

lines=0                             # how many lines the log holds
log_text=""

add_lines() {                       # how_many
    local i
    for (( i = 0; i < ${1:-1}; i++ )); do
        (( lines++ ))
        printf -v log_text '%s%s%04d  a line of output arriving while the app runs' \
               "$log_text" "${log_text:+$'\n'}" "$lines"
    done
    ft-modify log text="$log_text"
    ft-modify statusline status="$lines lines"
}
add_one()    { add_lines 1; }
add_ten()    { add_lines 10; }
clear_log()  { lines=0; log_text=""; add_lines 0; }

# ── The shell ────────────────────────────────────────────────────────────────
# There is no scrollbar here on purpose: a label is overflowY=auto by default, so it
# reserves its own gutter and grows its own bar the moment the text outruns the box —
# CSS overflow:auto, done by the engine. Its keymap brings the scroll keys with it.
# (ft-scrollbar is for a bar you want placed or styled separately; adding one here would
# just suppress the label's own and duplicate it.)
ft-form name=app width="$FT_COLS" height="$FT_ROWS" \
        display=flex flexDirection=column \
        key='[Aa]' keyCode=add_one key='[Tt]' keyCode=add_ten key='[Xx]' keyCode=clear_log key='[Qq]' keyCode=ft_quit

    ft-frame name=viewport title=" output " flexGrow=1 flexShrink=1 minHeight=0 \
             display=flex flexDirection=column
        ft-label name=log text="" flexGrow=1 alignSelf=stretch
    end_ft_frame

    ft-keylegend name=legend     flexShrink=0 keys=auto
    ft-statusbar name=statusline flexShrink=0 status="Press A to add a line."
end_ft_form

ft-modify app \
    key='[Aa]' keyCap="Add a line" keyImp=crucial keyCode=add_one \
    key='[Tt]' keyCap="Add ten" keyImp=important keyCode=add_ten \
    key='[Xx]' keyCap="Clear" keyImp=normal keyCode=clear_log \
    key='[Qq]' keyCap="Quit" keyImp=40 keyCode=ft_quit

setup() { add_lines 3; }
ft-run app setup
