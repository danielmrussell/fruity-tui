#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  THE APP MAY NOT DO THE FRAMEWORK'S JOB. A RATCHET, NOT A WISH.
#
#  The demos are APP CODE — the only app code this repository has, and therefore the only
#  honest sample of what using this framework feels like. Twice now a feature has shipped
#  whose demo had to reach into the engine to work:
#
#    · a transition demo that hid a box by reading FT_PAINT_RECT, cancelling a transition
#      through the PRIVATE _FT_TRANSITION_ACTIVE, and calling ft_damage itself;
#    · a callout demo that removes an overlay by capturing FT_BEACON_EXTENT and handing it
#      back to ft_damage — three times — once via the private _ft_bigarrow_damage_all;
#    · every css-demo handler that sets a colour and then tells the renderer to repaint:
#      `ft-modify inhbox color=$1; _ft_dirty_subtree inhbox`.
#
#  The design law says copy CSS/CSSOM, sketch the user code FIRST, and fix the root rather
#  than repeating a fix per case. That law was written down in docs/ and in nobody's test,
#  so it did not hold. This is the test.
#
#  ══ WHY A RATCHET AND NOT A BAN ══════════════════════════════════════════════
#  A flat ban would fail today, and a failing suite teaches people to skip the suite. So
#  each file carries the count it had when this gate was written. MORE than that fails —
#  a new leak cannot be added quietly. FEWER than that also fails, loudly and with
#  instructions: lower the number, because a fixed leak must never silently un-fix.
#  The only acceptable direction is down, and the only way down is through the engine.
#
#  ══ WHAT COUNTS AS A LEAK ════════════════════════════════════════════════════
#   1. A PRIVATE name in app code — anything matching _ft_* or _FT_*. The underscore is
#      the promise that an app never needs it. If an app does need it, that is a missing
#      public API (ft_beacon_side was added exactly this way, when a demo was caught
#      parsing an internal placement cache).
#   2. HAND-ROLLED REPAIR — ft_damage / ft_dirty / ft_redraw_dirty / FT_PAINT_RECT /
#      FT_BEACON_EXTENT. Repair is what the engine is FOR. An app that has to say which
#      cells to give back is an app doing the compositor's job, and it will get it wrong
#      for every control whose ink is not its layout box.
#
#  Exceptions are allowed and must be EARNED: put the reason on the line, in a comment
#  containing "API-EXCEPTION:", and it stops counting. A reason nobody wrote is a leak.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
cd "$here" || exit 1

# file → leaks recorded when this gate was written. Lower these as the engine takes the work
# back; never raise one.
# 2026-08-28: THE METRIC WIDENED (suffixed repair names now count — see BOOKKEEPING below), so
# numbers from this date measure MORE than the originals: a baseline that rises across this
# line reflects the wider net, not a new leak. That is the one legitimate way a baseline goes
# up, and this note is what keeps the ratchet's promise honest across it. Re-measured under the
# widened counter on that date, every baseline below is at or under its pre-widening value.
declare -A BASELINE=(
    [css-demo.bash]=0          # was 12 — half were handlers that set a style then told the
                               #   renderer to repaint (ft-modify acts on the property KIND now,
                               #   subtree-wide when it inherits); the rest was `_repaint_spec`,
                               #   three HAND-PICKED subtrees after every stylesheet edit —
                               #   which was also WRONG: page 3's bare `textfield` rule styles
                               #   the code panes too, and the hand list left them stale.
                               #   ft_stylesheet now restyles what the sheet's own selectors
                               #   can match, old rules and new — the CSSOM behaviour.
    [callout-demo.bash]=0      # was 11 — step changes handing a removed callout's footprint back
                               #   by hand. ft_remove now gives back every cell the subtree inked,
                               #   asking the class where its ink is (_ft_ink_<type>) because a
                               #   bigarrow's is not its extent.
    [tutorial-demo.bash]=0     # was 3 — a label now publishes scrollHeight/clientHeight like a
                               #   container, so "did this overflow?" is the DOM's own question.
    [textfield-demo.bash]=0    # was 2 — the other was a dead read of an internal
    [bigarrow-demo.bash]=0
    [tabs-demo.bash]=0
    [tree-demo.bash]=0
    [wizard-demo.bash]=0
    [_perf.bash]=0             # its one line is API-EXCEPTION'd: the probe MEASURES the
                               #   repaint pipeline, so invoking it is the subject
)
# ZERO, down from 34. Every entry above is kept at 0 rather than deleted, because a file that
# reached zero is the one most worth watching: the map names the demos that once did engine work,
# and any of them going back above 0 fails here by name.
#
# What paid for the thirty-four: ft_remove repairs what it removed; ft-modify dirties by property
# kind, subtree-wide when the property inherits; ft_stylesheet restyles what its own selectors can
# match; FT_CLASS_REPROP lets a class ACT on a change (a beacon re-arms its effect) instead of an
# app calling _ft_beacon_arm; labels publish their scroll metrics; ft_dirty_subtree became public,
# because an app that edits a STYLESHEET at runtime has changed how a branch resolves without
# touching any property and no ft-modify can see it.
#
# The last fourteen were trailing `ft_redraw_dirty` calls, and they went in two groups for two
# DIFFERENT reasons — both measured, neither assumed:
#   · in a HANDLER the loop has set FT_COALESCING=1, and ft_redraw_dirty returns immediately;
#     measured at the tty, 0 bytes written and the dirty set left pending for the loop's settle;
#   · in the function ft-run takes as its `setup` argument, ft-run calls ft_redraw_all on the whole
#     root immediately afterwards (ft-forms.bash:6501 then :6508), so anything painted there is
#     superseded on the same frame.
# The scaffolding those calls really served — a gate driving a handler directly, outside any burst
# — now lives in tests/_harness.bash as `settle`, which does what the run loop's settle does.
PRIVATE='\b_ft_[a-z_]+|\b_FT_[A-Z_]+'
# SUFFIXED NAMES COUNT TOO. `\bft_dirty\b` does not match ft_dirty_subtree — underscore is a
# word character, so there is no boundary — and renaming _ft_dirty_subtree to the public
# ft_dirty_subtree moved every call site off BOTH patterns at once: the count fell without a
# single leak dying. A rename must never look like a fix to this gate, so every repair verb
# matches its whole family.
BOOKKEEPING='\bft_damage(_[a-z_]+)?\b|\bft_dirty(_[a-z_]+)?\b|\bft_redraw_dirty\b|\bFT_PAINT_RECT\b|\bFT_BEACON_EXTENT\b'

_leaks_in() {                   # file → FT_RET = count, LEAK_LINES = the offending lines
    local f=$1
    LEAK_LINES=$(grep -nE "$PRIVATE|$BOOKKEEPING" "$f" 2>/dev/null \
                 | grep -v 'API-EXCEPTION:' \
                 | grep -vE '^[0-9]+: *#')          # a comment describing the problem is not the problem
    FT_RET=$(printf '%s' "$LEAK_LINES" | grep -c . )
}

note "no demo may do the framework's job — and the count may only go down"
total=0; total_base=0
for f in demo/*.bash; do
    b=${f#demo/}
    [[ "$b" == .* ]] && continue                    # run-loop-stripped scratch copies
    _leaks_in "$f"; n=$FT_RET
    base=${BASELINE[$b]:-0}
    (( total += n )); (( total_base += base ))
    if (( n > base )); then
        check "$b: no NEW engine work in app code (was $base)" "$n" "$base"
        printf '%s\n' "$LEAK_LINES" | head -6 | sed 's/^/         /'
        echo "         ↑ the engine should be doing this. See this file's header."
    elif (( n < base )); then
        check "$b: baseline is stale — lower it to $n (was $base)" "$n" "$base"
        echo "         Good news: $(( base - n )) leak(s) fixed. Edit BASELINE in this file to $n"
        echo "         so the improvement is locked in and cannot come back."
    else
        check "$b: $n known leak(s), none new" "$n" "$base"
    fi
done

note "the whole app surface, in one number"
check "total leaks across every demo is $total_base or fewer" "$(( total <= total_base ))" 1
note "  ($total today; every one of them is a missing piece of framework)"

# The two that are never acceptable, at any count: a private name is a missing public API, and
# nothing in a demo may reach into another control's internals to repair it.
note "no demo writes the engine's palette by hand — and this count may only go down"
# THE FIRST PATTERN CANNOT SEE THIS. `PRIVATE` requires a leading underscore, and the engine's
# palette globals have none: `FT_COLOR_BODY=$'\e[48;5;252;38;5;236m'` is an app assigning a
# framework colour and the ratchet was blind to it. Two demos hand-roll a complete three-theme
# palette between them — ~60 lines apiece reimplementing ft-dark / ft-light / ft-ocean, which
# the framework already ships and which demo/css-demo.bash selects in ONE line with
# ft_use_theme. It is the same debt as any other leak: app code doing the engine's job.
#
# PRECISE ON PURPOSE. A blanket `FT_[A-Z_]+=` would also match `FT_RET=`, which is the
# framework's own return channel — a demo callback setting it is CORRECT code, and 39 of them
# do. A gate that fires on the right thing is worse than no gate, so this matches the palette
# and nothing else.
#
# FT_COLOR_MODE IS NOT A PALETTE ENTRY. It says how many colours the terminal has, and a
# harness pinning it (demo/_perf.bash) is doing something legitimate — so it is excluded by
# name rather than by loosening the pattern. Caught by this gate firing on it the first time
# it ran.
PALETTE='\bFT_COLOR_[A-Z_]+=|\bFT_SHEEN_GLOW='
PALETTE_NOT='FT_COLOR_MODE='
_palette_lines_in() {           # file → FT_RET = count, PALETTE_LINES = the offending lines
    PALETTE_LINES=$(grep -nE "$PALETTE" "$1" 2>/dev/null | grep -vE "$PALETTE_NOT" \
                    | grep -vE '^[0-9]+: *#')
    FT_RET=$(printf '%s' "$PALETTE_LINES" | grep -c .)
}
declare -A PALETTE_BASELINE=(
    [tutorial-demo.bash]=26    # three complete palettes in apply_theme(), deliberately tuned —
                               #   replacing them with ft_use_theme changes what the demo LOOKS
                               #   like, so it is a separate, deliberate piece of work
    [tabs-demo.bash]=16
)
palette_total=0; palette_base_total=0
for f in demo/*.bash; do
    b=${f#demo/}
    [[ "$b" == .* ]] && continue
    _palette_lines_in "$f"; n=$FT_RET
    base=${PALETTE_BASELINE[$b]:-0}
    (( palette_total += n )); (( palette_base_total += base ))
    if (( n > base )); then
        check "$b: no NEW hand-written palette (was $base)" "$n" "$base"
        printf '%s\n' "$PALETTE_LINES" | head -4 | sed 's/^/         /'
        echo "         ↑ ft_theme declares a palette; ft_use_theme selects one."
    elif (( n < base )); then
        check "$b: palette baseline is stale — lower it to $n (was $base)" "$n" "$base"
        echo "         Good news: $(( base - n )) fewer. Edit PALETTE_BASELINE so it cannot come back."
    fi
done
check "hand-written palette lines across every demo is $palette_base_total or fewer" \
      "$(( palette_total <= palette_base_total ))" 1
note "  ($palette_total today, in $((${#PALETTE_BASELINE[@]})) demo(s); css-demo does it in one line)"

note "the hard rules, which no baseline forgives"
worst=$(grep -rnE '_ft_bigarrow_damage_all|_FT_TRANSITION_ACTIVE' demo/*.bash 2>/dev/null \
        | grep -v 'API-EXCEPTION:' | grep -vE ':[0-9]+: *#' | head -4)
check "no app reaches into a control's private repair machinery" "$(printf '%s' "$worst" | grep -c .)" 0
[[ -n "$worst" ]] && printf '%s\n' "$worst" | sed 's/^/         /'

summary
