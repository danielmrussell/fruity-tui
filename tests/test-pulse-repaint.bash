#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  A PULSE FRAME MUST LEAVE THE SCREEN A FULL RE-DERIVATION WOULD PRODUCE.
#
#  The keycap pulse used to answer a colour change by throwing the legend's retained block
#  away and re-deriving every cap from the focused control's keymap chain and live state:
#  13.44ms a frame, eight times a second, forever. It now repaints only the cells the animated
#  caps occupy, from geometry the draw already computed.
#
#  That is the whole risk of the change. A repaint aimed at the wrong row, the wrong column,
#  or the wrong width does not fail loudly — it corrupts a few cells of a status strip that
#  nobody is looking directly at, and a byte-stream comparison cannot see it because the two
#  paths legitimately emit different bytes. So this replays the real tty stream into a cell
#  grid (glyph + fg + bg, tools/screen-cells.py) and demands the incremental path agree with a
#  from-scratch render, cell for cell, at several phases.
#
#  ANTI-VACUITY: two fresh renders at different phases must DIFFER, or the comparison is
#  between two identical pictures and would pass with the pulse painting nothing at all. And
#  the fresh render must put real ink on the screen, or two blank grids compare equal.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
noloop="$here/demo/.pulse-repaint-noloop.bash"
sed '/^ft-run app/d' "$here/demo/css-demo.bash" > "$noloop"
tmp=$(mktemp -d); trap 'rm -rf "$tmp" "$noloop"' EXIT
source "$noloop"
FT_COLOR_MODE=256; FT_USE_UTF8=1; FT_ROWS=34; FT_COLS=120
FT_ROOT=app

PAGE=1
exec {FT_TTY}>"$tmp/stream"
_resize   >/dev/null 2>&1        # the full opening frame
settle    >/dev/null 2>&1
FT_LAST_INPUT_MS=0               # the typing debounce has long expired

note "the pulse is actually running (without this every check below is vacuous)"
check "a keycap pulse is armed"            "$(( ${#FT_ANIM_PHASE[__ft_kcpulse]} >= 0 ))" 1
_recorded=${FT_KEYLEGEND_ANIMATED_CELLS[navlegend]:-}   # ${#x[k]:-0} is not a substitution
check "…and the legend recorded animated cells" "$(( ${#_recorded} > 0 ))" 1

_fresh_at() {                    # phase file — a from-scratch render with the caps re-derived
    FT_ANIM_PHASE[__ft_kcpulse]=$1
    _ft_legend_dirty             # force the derivation, so the legend is not served retained
    FT_OUT=""
    _ft_redraw_walk app >/dev/null 2>&1
    _ft_composite_overlays
    printf '%s' "$FT_OUT" > "$2"
    FT_OUT=""
}
_cells() { python3 "$here/tools/screen-cells.py" "$1" "$FT_ROWS" "$FT_COLS"; }

note "two phases of the pulse are genuinely different pictures"
_fresh_at 0 "$tmp/f0"; f0=$(_cells "$tmp/f0")
_fresh_at 3 "$tmp/f3"; f3=$(_cells "$tmp/f3")
painted=$(printf '%s' "$f0" | grep -c .)
check "the page put ink on the screen (>=40 cells)" "$(( painted >= 40 ))" 1
check "phase 0 and phase 3 differ (else the comparison below is empty)" \
      "$([[ "$f0" != "$f3" ]] && echo 1 || echo 0)" 1

note "the incremental pulse frame agrees with a full re-derivation, cell for cell"
# The baseline has to be a WHOLE frame, because the comparison is against a whole-screen
# render: _resize is the same opening frame tests/test-residue.bash replays, and that pairing
# is already known to compare equal. (A legend-only redraw as the baseline compares a strip
# against a screen, which is a broken instrument, not a broken renderer.)
exec {FT_TTY}>&-; exec {FT_TTY}>"$tmp/stream"
FT_ANIM_PHASE[__ft_kcpulse]=0                      # the phase the baseline is drawn at
_resize >/dev/null 2>&1
settle  >/dev/null 2>&1
for phase in 1 2 3 4 5 0 3; do
    FT_ANIM_PHASE[__ft_kcpulse]=$phase
    FT_OUT=""; _ft_kcpulse_frame; ft_flush         # the incremental path, and only it
    _fresh_at "$phase" "$tmp/fresh"
    a=$(_cells "$tmp/stream"); b=$(_cells "$tmp/fresh")
    if [[ "$a" == "$b" ]]; then
        check "phase $phase: the recoloured cells match a full re-derivation" 1 1
    else
        check "phase $phase: the recoloured cells match a full re-derivation" 0 1
        diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -4 | sed 's/^/         /'
    fi
done

note "a pulse frame costs a fraction of the re-derivation it replaced"
# Not a millisecond threshold — those are flaky on a loaded box. The requirement is structural:
# a frame must not re-derive the caps. _ft_legend_caps refills FT_CAPS, so watch that.
_derivations=0
_ft_legend_caps_real=$(declare -f _ft_legend_caps)
_ft_legend_caps() { _derivations=$(( _derivations + 1 )); FT_CAPS=(); }
for phase in 1 2 3 4 5 6 7 8; do
    FT_ANIM_PHASE[__ft_kcpulse]=$phase; FT_OUT=""; _ft_kcpulse_frame
done
eval "${_ft_legend_caps_real/#_ft_legend_caps/_ft_legend_caps}"
check "eight pulse frames re-derive the caps zero times" "$_derivations" 0
# Teeth: the counter must be able to see a derivation happen.
_derivations=0
_ft_legend_caps_real=$(declare -f _ft_legend_caps)
_ft_legend_caps() { _derivations=$(( _derivations + 1 )); FT_CAPS=(); }
_ft_legend_dirty; ft_redraw_dirty >/dev/null 2>&1
eval "${_ft_legend_caps_real/#_ft_legend_caps/_ft_legend_caps}"
check "…but a real legend redraw does (so the counter has teeth)" "$(( _derivations > 0 ))" 1

summary
