#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — demo/growth-demo.bash   (retained mode, interactive)
#
#  Proves the CSS sizing model (auto/fixed + min/max + wrapping + overflow),
#  one scenario at a time — press OK (or K) to advance:
#
#    1  Short text          — baseline, auto-sized to content
#    2  Wide growth         — width auto + maxWidth caps how wide it gets
#    3  Wrap instead        — width=20 is a hard cap: the long line WRAPS
#    4  Large vertical text — maxHeight caps the box; the for= scrollbar
#                             pages through the rest (H hides it live)
#    5  Shrink back         — auto sizing shrinks back down too
#
#    bash demo/growth-demo.bash
# ─────────────────────────────────────────────────────────────────────────────
set -o pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/fruity-tui.bash"
ft_init
ft_term_size

N_SCENARIOS=5
LONG_SENTENCE="This single sentence is deliberately much longer than the box's own nominal width, to prove growth and wrapping."

BIG_TEXT=""
for i in $(seq 1 20); do
    BIG_TEXT+="This is paragraph line $i of a genuinely large amount of vertical text."$'\n'
done
BIG_TEXT=${BIG_TEXT%$'\n'}

STAGE=1

_build_stage() {                    # stage
    STAGE=$1
    local title desc
    local -a msgargs=(name=msg)
    local needSb=0
    case "$STAGE" in
        1) title="1/5: Short Text"
           desc="Baseline: short text, auto-sized."
           msgargs+=(text="Just a short line.") ;;
        2) title="2/5: Wide Growth (auto width + maxWidth)"
           desc="width auto: the box is as wide as the text, capped by maxWidth."
           msgargs+=(text="$LONG_SENTENCE" maxWidth=60) ;;
        3) title="3/5: Wrap Instead Of Growing Wide"
           desc="width=20 is a hard cap (CSS): the text WRAPS."
           msgargs+=(text="$LONG_SENTENCE" width=20) ;;
        4) title="4/5: Large Vertical Text + Scrollbar"
           desc="maxHeight caps the box -- scroll for the rest. H hides the bar."
           msgargs+=(text="$BIG_TEXT" width=50 maxHeight=10)
           needSb=1 ;;
        5) title="5/5: Shrink Back Down"
           desc="Proves auto sizing shrinks back too, not just grows."
           msgargs+=(text="Back to short again.") ;;
    esac

    ft-empty app
        ft-frame name=win title="$title" \
                 display=flex flexDirection=column gap=1 alignItems=center
            ft-label name=desc text="$desc" color=brightcyan margin=1
            ft-div name=content display=flex gap=1 alignItems=start
                ft-label "${msgargs[@]}"
                if (( needSb )); then
                    ft-scrollbar name=sb for=msg width=4 indicator=percentage
                fi
            end_ft_div
            ft-div name=btnrow display=flex gap=2 justifyContent=center
                ft-button name=btnOk   OK   accessKey=K onActivate=btnOk_on_activate
                ft-button name=btnQuit Quit accessKey=Q onActivate=btnQuit_on_activate
            end_ft_div
        end_ft_frame
    end_ft_form
    ft_refresh
}

btnOk_on_activate()   { _build_stage $(( STAGE % N_SCENARIOS + 1 )); }
btnQuit_on_activate() { ft_quit; }

# display=none live toggle: H hides/shows scenario 4's scrollbar in place —
# no rebuild; the content row reflows around it.
_toggle_sb() {
    [[ -z "${FT_TYPE[sb]:-}" ]] && return 0
    ft_get sb display
    if [[ "$FT_RET" == none ]]
    then ft-modify sb display=inline-block
    else ft-modify sb display=none; fi
}

_setup() { _build_stage 1; }

ft-form name=app width="$FT_COLS" height="$FT_ROWS" \
        display=flex justifyContent=center alignItems=center \
        key='[Qq]' onKey=ft_quit key='[Hh]' onKey=_toggle_sb
end_ft_form
ft-run app _setup
