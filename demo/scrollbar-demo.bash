#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — demo/scrollbar-demo.bash   (retained mode, interactive)
#
#  A scrollable text block with a for= scrollbar, across two aspects cycled
#  with OK (K). Grow Text (G) appends a line — the bar is declared ONCE and
#  simply appears the moment the content outgrows maxHeight (and hides again
#  after OK resets the text), because for= bars derive everything from their
#  target: overflow:auto, not app logic.
#
#    A  Wide, short   — fits at first; grow it until the bar appears
#    B  Narrow + tall — wraps, and already needs the bar
#
#  While the bar is focused (Tab), Up/Down/PgUp/PgDn/Home/End scroll the
#  text; its last row shows how much of the document you've seen.
#
#    bash demo/scrollbar-demo.bash
# ─────────────────────────────────────────────────────────────────────────────
set -o pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/fruity-tui.bash"
ft_init
ft_term_size

N_ASPECTS=2
ASPECT=1
GROWN=0   # extra "Grow Text" presses applied to the CURRENT aspect

_aspect_config() {                  # sets TITLE, DESC, WIDTH, BASE_LINES
    case "$1" in
        1) TITLE="A: Wide, Short (no scrollbar yet)"
           DESC="Fits within maxHeight -- the bar hides itself. Grow Text until it appears."
           WIDTH=50
           BASE_LINES=("First line of a comfortably short block." "Second line, still fits fine.") ;;
        2) TITLE="B: Narrow + Tall (wraps AND scrolls)"
           DESC="Width is narrow enough to wrap; already needs the scrollbar."
           WIDTH=24
           BASE_LINES=(
               "This sentence is long enough that it will definitely wrap across several lines at this width."
               "A second sentence, also long enough to wrap, so there is plenty to scroll through immediately."
               "A third sentence, added so the overflow is large and obvious rather than just one extra line."
               "A fourth sentence, for good measure, making the scroll range clearly visible when you test it."
           ) ;;
    esac
}

_current_text() {
    local -a lines=("${BASE_LINES[@]}")
    local i
    for (( i=1; i<=GROWN; i++ )); do
        lines+=("Extra grown line $i, added by pressing Grow Text.")
    done
    local IFS=$'\n'; TEXT="${lines[*]}"; unset IFS
}

_build() {
    _aspect_config "$ASPECT"
    _current_text

    ft_empty app
        ft-frame name=win title="$TITLE" \
                 display=flex flexDirection=column gap=1 alignItems=center
            ft-label name=desc text="$DESC" color=brightcyan margin=1
            ft-div name=content display=flex gap=1 alignItems=start
                ft-label name=msg text="$TEXT" width="$WIDTH" maxHeight=8
                ft-scrollbar name=sb for=msg width=4 indicator=percentage
            end_ft_div
            ft-div name=btnrow display=flex gap=2 justifyContent=center
                ft-button name=btnGrow text="Grow Text" accessKey=G onActivate=btnGrow_on_activate
                ft-button name=btnOk text=OK accessKey=K onActivate=btnOk_on_activate
                ft-button name=btnQuit text=Quit accessKey=Q onActivate=btnQuit_on_activate
            end_ft_div
        end_ft_frame
    end_ft_form
    ft_refresh
}

btnGrow_on_activate() { (( GROWN++ )); _build; }
btnOk_on_activate()   { ASPECT=$(( ASPECT % N_ASPECTS + 1 )); GROWN=0; _build; }
btnQuit_on_activate() { ft_quit; }

_setup() { _build; }

ft-form name=app width="$FT_COLS" height="$FT_ROWS" \
        display=flex justifyContent=center alignItems=center \
        key='[Qq]' onKey=ft_quit
end_ft_form
ft_run app _setup
