#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  A CALLOUT'S PLACEMENT SEARCH IS OWED, NOT PAID ON THE KEYSTROKE.
#
#  Measured on demo/callout-demo.bash page 4 at 118×40: one press of the step arrow cost 687 ms,
#  of which 560 ms was _ft_beacon_paint_callout — the search prices ~1000 candidate boxes and
#  routes a leader for each finalist, and it ran inside ft_draw_one, inside the settle for one
#  keypress. The page the user asked for is correct WITHOUT the callout, so the settle hands the
#  frame over and ft_run pays for the callout immediately afterwards.
#
#  THE PREDICATE IS THE WHOLE SAFETY ARGUMENT: deferral needs a pump, and ft_run's loop is the
#  only one. With FT_RUN_ACTIVE=0 — every test in this directory, ft_beacon_place, any app that
#  drives its own paints — the search happens in place, synchronously, exactly as before. That is
#  what leaves ~600 existing callout assertions untouched, and it is asserted here rather than
#  assumed.
#
#  AND THE ANSWER MUST NOT CHANGE. A placement reached the slow way and the fast way is the same
#  placement, only later; if deferral moved a box it would be a rewrite of the search wearing a
#  performance change's clothes.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_USE_UTF8=1

_build() {                      # → a form with two targets and one callout aimed at the first
    FT_COLS=90; FT_ROWS=30
    ft-form name=app display=flex flexDirection=column gap=1 padding=1
        ft-label name=title text="Deferred placement"
        ft-div name=row display=flex gap=6
            ft-textfield name=host value="mago.local" size=14
            ft-button name=scan text="Scan"
            ft-checkbox name=deep text="Deep"
        end_ft_div
        ft-label name=note text="a paragraph of prose the callout may cover if it must"
    end_ft_form
    FT_ROOT=app
    ft_layout app >/dev/null 2>&1
    ft-beacon name=c1 target=host variant=callout number=1 \
        text="A callout whose placement costs a search."
    ft_layout app >/dev/null 2>&1
}
_teardown() { ft_remove c1 2>/dev/null; ft_remove app 2>/dev/null; FT_BEACON_PENDING=(); }
_paint() {                      # paint the beacon into a discarded buffer → FT_RET = bytes drawn
    local keep=$FT_OUT; FT_OUT=""
    _ft_draw_beacon c1 >/dev/null 2>&1
    FT_RET=${#FT_OUT}; FT_OUT=$keep
}
_pc()   { printf '%s' "${FT_BEACON_PC[c1]:-<none>}"; }
_debts(){ printf '%s' "${#FT_BEACON_PENDING[@]}"; }

note "with no run loop the search happens in place — this is what every other gate relies on"
_build
FT_RUN_ACTIVE=0
_paint; _bytes=$FT_RET
check "the paint drew the callout"      "$(( _bytes > 0 ))" "1"
check "…and the placement is cached"    "$([[ -n "${FT_BEACON_PC[c1]:-}" ]] && printf yes || printf no)" "yes"
check "…owing nothing"                  "$(_debts)" "0"
_sync_placement=$(_pc)

note "…and a repeat paint is a cache HIT, so the fixture really does miss the first time"
# Without this, "records a debt" below could be satisfied by a beacon that misses every paint.
_paint
check "the second paint still draws"    "$(( FT_RET > 0 ))" "1"
check "…and still owes nothing"         "$(_debts)" "0"
check "…at the same placement"          "$(_pc)" "$_sync_placement"

note "inside a running app the same miss is DEFERRED: nothing painted, a debt recorded"
_teardown; _build
FT_RUN_ACTIVE=1
_paint
check "the frame drew no callout"       "$FT_RET" "0"
check "…and no placement was cached"    "$(_pc)" "<none>"
check "…but the search is owed"         "$(_debts)" "1"

note "the drain pays it, and the answer is the one the slow path gives"
ft_beacon_drain_placements >/dev/null 2>&1
check "nothing is owed afterwards"      "$(_debts)" "0"
check "…the placement is cached"        "$([[ -n "${FT_BEACON_PC[c1]:-}" ]] && printf yes || printf no)" "yes"
check "…and it is the SAME placement"   "$(_pc)" "$_sync_placement"
_paint
check "…and the callout now paints"     "$(( FT_RET > 0 ))" "1"

note "a settled callout does not re-defer: a hit is a hit whether or not a loop is running"
_paint
check "still drawing"                   "$(( FT_RET > 0 ))" "1"
check "…and owing nothing"              "$(_debts)" "0"

note "a burst leaves ONE debt per beacon, not one per change — the held-key case"
_teardown; _build
FT_RUN_ACTIVE=1
for _t in "first text" "second text" "third text" "fourth text"; do
    ft_set c1 text="$_t"
    _paint
done
check "four changes, one debt"          "$(_debts)" "1"
ft_beacon_drain_placements >/dev/null 2>&1
check "…paid once"                      "$(_debts)" "0"
check "…and it placed the LAST text"    "$([[ -n "${FT_BEACON_PC[c1]:-}" ]] && printf yes || printf no)" "yes"
_paint
check "…and the callout is on screen"   "$(( FT_RET > 0 ))" "1"

note "ft_beacon_place answers NOW even inside a running app — that is its whole contract"
_teardown; _build
FT_RUN_ACTIVE=1
ft_beacon_place c1
check "the placement is there"          "$([[ -n "${FT_BEACON_PC[c1]:-}" ]] && printf yes || printf no)" "yes"
check "…and nothing is owed"            "$(_debts)" "0"
check "…and ft_beacon_side can answer"  "$(ft_beacon_side c1; printf %s "$FT_RET")" "$(printf '%s' "$_sync_placement" | cut -d' ' -f1)"

note "a DRAGGED callout never defers — there is no search to owe, and it must not vanish"
_teardown; _build
FT_RUN_ACTIVE=0
_paint                                        # place it first, so the drag has a shape to keep
FT_RUN_ACTIVE=1
ft_set c1 parkedTop=3 parkedLeft=40
_paint
check "the dragged callout still paints" "$(( FT_RET > 0 ))" "1"
check "…and owes nothing"                "$(_debts)" "0"

note "a beacon removed while its debt is outstanding is dropped, quietly"
_teardown; _build
FT_RUN_ACTIVE=1
_paint
check "a debt is outstanding"            "$(_debts)" "1"
ft_remove c1
ft_beacon_drain_placements >/dev/null 2>&1
check "the drain cleared it"             "$(_debts)" "0"

FT_RUN_ACTIVE=0
_teardown
summary
