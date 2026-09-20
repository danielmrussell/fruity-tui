#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  THE ACTIVE-ROW COLOUR IS A COLOUR, NEVER THE LADDER'S WORDS.
#
#  _ft_runlevel_active_sgr computes the ::active SGR into FT_RET, then asks
#  _ft_runlevels_of whether the control has a ladder — and that lookup ANSWERS IN FT_RET,
#  the same register the colour was just put in. Two early returns then handed the caller
#  the clobbered value:
#
#    engaged   → the literal string "unfocused poised browsing", which ft-tree and ft-table
#                paste straight into the row: `ft_print_at … "$sgr$FT_FIT…"`. The words appear on
#                screen. This is the state Enter's progressive delve puts you in — the one
#                the function's own comment says "lights it up".
#    no ladder → "" — no colour at all, so the row loses the caller's fallback.
#
#  The not-engaged path only looked right by accident: the line after the returns overwrote
#  the garbage with FT_COLOR_FADED. The stale-FT_RET family, which this project names as a
#  law: an early return that leaves a stale FT_RET is a known bug.
#
#  Pinned at both altitudes — the function's contract, and a real painted frame.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
cd "$here"
export FT_NO_WTFIX=1
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_USE_UTF8=1; FT_COLOR_MODE=256
FT_COLS=80; FT_ROWS=24

FALLBACK=$'\e[48;5;21;38;5;231m'         # a recognisable fallback SGR

ft-form name=app width="$FT_COLS" height="$FT_ROWS"
    ft-label name=plain text="a control with a ladder"
    ft-tree name=trec rows=6
        ft-tree-node text="alpha" id=a depth=0
        ft-tree-node text="beta" id=b depth=0
        ft-tree-node text="gamma" id=g depth=0
    end_ft_tree
end_ft_form
FT_ROOT=app; ft_layout app

note "the function's contract: every path answers with a colour"

# ENGAGED — the path that painted words. Driven through ft_key_delve, which is what the
# Enter binding calls; ft_dispatch_event Enter alone stops at `poised` and never engages,
# which is exactly why the first version of this test passed against the broken code.
ft_focus trec
ft_key_delve trec Enter >/dev/null 2>&1
ok "the tree really is engaged after the delve" ft_runlevel_engaged trec
_ft_runlevel_active_sgr trec "$FALLBACK"
check "engaged: the computed SGR survives the ladder lookup" "$FT_RET" "$FALLBACK"
case "$FT_RET" in
    *unfocused*|*poised*|*browsing*) check "…and no ladder word is in the colour" leaked never ;;
    *)                               check "…and no ladder word is in the colour" never never ;;
esac

# NOT ENGAGED — always worked, because the line after the returns overwrote the clobber.
# Pinned so the fix does not lose the fade.
ft_set trec runlevel=unfocused
_ft_runlevel_active_sgr trec "$FALLBACK"
check "merely focused: the faded colour" "$FT_RET" "$FT_COLOR_FADED"

# NO LADDER — unreachable through the public API today (every control inherits at least the
# form's single `unfocused` rung), so the branch is exercised by clearing both sources the
# lookup consults. It is still the same defect and the same fix.
_saved_class=${FT_PROTO_RUNLEVELS[label]:-}
FT_PROTO_RUNLEVELS[label]=""; FT_RUNLEVELS[plain]=""
_ft_runlevels_of plain
check "the no-ladder case really has no ladder" "$FT_RET" ""
_ft_runlevel_active_sgr plain "$FALLBACK"
check "no ladder: the fallback SGR survives" "$FT_RET" "$FALLBACK"
FT_PROTO_RUNLEVELS[label]=$_saved_class

note "the draw path: a delved-into tree paints colours, not vocabulary"
ft_set trec runlevel=browsing
ok "…engaged again for the paint" ft_runlevel_engaged trec
FT_OUT=""; ft_draw_one trec; frame=$FT_OUT; FT_OUT=""
check "the tree drew something" "$(( ${#frame} > 100 ))" 1
case "$frame" in
    *"unfocused poised browsing"*) check "the frame never contains the ladder words" leaked never ;;
    *)                             check "the frame never contains the ladder words" never never ;;
esac
# Every positioned write must be followed by an ESCAPE, not by a letter. When the colour was
# clobbered the row read `\e[1;24Hunfocused poised browsing  alpha` — a cursor move landing
# straight on text is the signature of a "colour" that was really a word. Position-independent
# on purpose: the first version pinned column 1 and failed on a correct frame drawn at 24.
if [[ "$frame" =~ $'\e'\\[[0-9\;]*H[A-Za-z] ]]; then
    check "no positioned write lands straight on a letter" "${BASH_REMATCH[0]}" "an escape"
else
    check "no positioned write lands straight on a letter" "an escape" "an escape"
fi

summary
