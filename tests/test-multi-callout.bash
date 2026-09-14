#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  MORE THAN ONE CALLOUT ON A PAGE — the case that had never been tested.
#
#  Every gate before this one drives a demo that shows exactly ONE callout at a time, so
#  everything about two of them coexisting was unverified: whether the second knows the
#  first is there, whether either leader runs through the other's chip, whether removing
#  one leaves the other intact. The engine does publish each callout's painted footprint
#  (FT_BEACON_EXTENT) and the placement search does add other overlays' ink to its
#  obstacle list — but "the code intends to" and "it does" are different claims, and only
#  one of them is a test.
#
#  A real tutorial or a form with two hints is the ordinary case, not an exotic one.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_USE_UTF8=1

_build() {                      # cols rows — a form with three targets and two callouts
    FT_COLS=$1; FT_ROWS=$2
    ft-form name=app display=flex flexDirection=column gap=1 padding=1
        ft-label name=title text="Two callouts, one page"
        ft-div name=row display=flex gap=6
            ft-textfield name=host value="mago.local" size=14
            ft-button name=scan text="Scan"
            ft-checkbox name=deep text="Deep"
        end_ft_div
        ft-label name=note text="a paragraph of prose that the callouts may cover if they must"
    end_ft_form
    FT_ROOT=app
    ft_layout app >/dev/null 2>&1
    ft-beacon name=c1 target=host variant=callout number=1 \
        text="The first callout points at the host field."
    ft-beacon name=c2 target=deep variant=callout number=2 \
        text="The second points at the Deep checkbox and must not sit on the first."
    ft_layout app >/dev/null 2>&1
    FT_OUT=""; _ft_redraw_walk app >/dev/null 2>&1; _ft_composite_overlays
}
_teardown() { ft_remove c1 2>/dev/null; ft_remove c2 2>/dev/null; ft_remove app 2>/dev/null; }
_box() { _ft_beacon_placement "$1"; }   # → FT_PLACED_T/L/B/R

for _size in "80 30" "120 40" "62 40"; do
    set -- $_size
    note "two callouts at $1×$2"
    _build "$1" "$2"

    _box c1; c1T=$FT_PLACED_T; c1L=$FT_PLACED_L; c1B=$FT_PLACED_B; c1R=$FT_PLACED_R
    _box c2; c2T=$FT_PLACED_T; c2L=$FT_PLACED_L; c2B=$FT_PLACED_B; c2R=$FT_PLACED_R

    _ov=0; (( c1T <= c2B && c2T <= c1B && c1L <= c2R && c2L <= c1R )) && _ov=1
    check "the two chips do not overlap each other"        "$_ov" 0
    check "callout 1 drew a leader"  "$([[ -n "${FT_BEACON_LEADER[c1]:-}" ]] && echo yes || echo no)" yes
    check "callout 2 drew a leader"  "$([[ -n "${FT_BEACON_LEADER[c2]:-}" ]] && echo yes || echo no)" yes

    # Neither leader may cross the OTHER chip: a line through a callout's text is unreadable, and
    # the other chip is exactly the ink the obstacle list is supposed to have learned about.
    _ft_beacon_poly_in_rect "${FT_BEACON_LEADER[c1]:-}" "$c2T" "$c2L" "$c2B" "$c2R"
    check "callout 1's leader stays out of callout 2's chip" "$FT_RET" 0
    _ft_beacon_poly_in_rect "${FT_BEACON_LEADER[c2]:-}" "$c1T" "$c1L" "$c1B" "$c1R"
    check "callout 2's leader stays out of callout 1's chip" "$FT_RET" 0

    # …and neither chip may sit on the OTHER's target, which would hide the thing being explained.
    for _pair in "c1 deep" "c2 host"; do
        set -- $_pair; _who=$1; _other=$2
        _box "$_who"
        _tT=${FT_ABSOLUTE_Y[$_other]}; _tL=${FT_ABSOLUTE_X[$_other]}
        _tB=$(( _tT + FT_MEASURED_HEIGHT[$_other] - 1 )); _tR=$(( _tL + FT_MEASURED_WIDTH[$_other] - 1 ))
        _c=0; (( FT_PLACED_T <= _tB && _tT <= FT_PLACED_B && FT_PLACED_L <= _tR && _tL <= FT_PLACED_R )) && _c=1
        check "$_who's chip keeps off $_other" "$_c" 0
    done
    _teardown
done

note "removing one callout leaves the other whole"
# A removed overlay has to give back the cells it owned WITHOUT taking its neighbour's with it —
# each publishes its own extent, and the repair is driven from that.
_build 80 30
_c2_extent=${FT_BEACON_EXTENT[c2]:-}
ft_remove c1
FT_OUT=""; _ft_redraw_walk app >/dev/null 2>&1; _ft_composite_overlays
check "callout 2 still knows its own footprint" "${FT_BEACON_EXTENT[c2]:-}" "$_c2_extent"
check "callout 2 still has its leader" "$([[ -n "${FT_BEACON_LEADER[c2]:-}" ]] && echo yes || echo no)" yes
check "the removed callout kept nothing" "${FT_BEACON_EXTENT[c1]-gone}" "gone"
case "$FT_OUT" in *"②"*) check "callout 2 still paints its badge" 1 1 ;;
                  *)      check "callout 2 still paints its badge" 0 1 ;; esac
_teardown

summary
