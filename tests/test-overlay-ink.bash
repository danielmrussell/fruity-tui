#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  EVERY LEADER ROUTES AROUND THE OTHER OVERLAYS' INK — from every preamble.
#
#  _ft_route_obstacles walks the layout tree and skips beacons outright, so the only way a
#  router learns that a frame beacon's halo or another chip is on screen is the loop that
#  pushes the published FT_BEACON_EXTENT rects. That loop existed in the placement search
#  and in the bigarrow placer, and NOT in the draw's cache-miss re-route — which is the one
#  preamble a DRAGGED callout's leader goes through (its leader is never computed by the
#  search) and the one every layout-epoch bump sends a parked callout back to. Those leaders
#  were routed blind: straight through a neighbour's halo, arrowhead parked under it, the
#  compositor then painting the halo on top.
#
#  This asks the question directly, at the moment it is decided: when the router is asked to
#  route a leader, is the neighbouring halo's rect in the obstacle list it was given? One
#  digit per _ft_beacon_leader call, per route. The old code answers 1111/0/0.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=80; FT_ROWS=30; FT_COLOR_MODE=256; FT_USE_UTF8=1

# Is this exact rect in the router's obstacle list right now?
_rt_has_rect() {                # "t l b r" → 0 if present
    local want=$1 i
    for (( i=0; i<${#_RT_T[@]}; i++ )); do
        [[ "${_RT_T[$i]} ${_RT_L[$i]} ${_RT_B[$i]} ${_RT_R[$i]}" == "$want" ]] && return 0
    done
    return 1
}
# Interpose on the leader: one digit per call, recorded from the list the caller built.
# (A test may fork; running-app code may not — this rename is why it lives here and not there.)
_leader_src=$(declare -f _ft_beacon_leader)
eval "_ft_beacon_leader_real${_leader_src#_ft_beacon_leader}"
LEADER_SAW=""
HALO_RECT=""
_ft_beacon_leader() {
    if _rt_has_rect "$HALO_RECT"; then LEADER_SAW+=1; else LEADER_SAW+=0; fi
    _ft_beacon_leader_real "$@"
}

ft-form name=app display=flex flexDirection=column gap=1 padding=1
    ft-label name=title text="One halo, one callout"
    ft-div name=row display=flex gap=6
        ft-textfield name=host value="mago.local" size=14
        ft-button name=scan text="Scan"
    end_ft_div
    ft-label name=note text="a paragraph of prose the callout may cover if it must"
end_ft_form
FT_ROOT=app
ft_layout app >/dev/null 2>&1
ft-beacon name=halo target=scan variant=frame effect=none outset=1
ft-beacon name=c    target=host variant=callout number=1 \
    text="The callout points at the host field and must route around the halo."
ft_layout app >/dev/null 2>&1
FT_OUT=""; _ft_redraw_walk app >/dev/null 2>&1; _ft_composite_overlays
FT_OUT=""; _ft_redraw_walk app >/dev/null 2>&1; _ft_composite_overlays

HALO_RECT=${FT_BEACON_EXTENT[halo]:-}
note "the scene"
check "the halo published an extent" "$([[ -n "$HALO_RECT" ]] && echo yes || echo no)" yes
check "the callout drew a leader"    "$([[ -n "${FT_BEACON_LEADER[c]:-}" ]] && echo yes || echo no)" yes

# ── A. the placement search — the preamble that always had the loop ──────────
note "the placement search routes with the halo in its list"
unset "FT_BEACON_PKEY[c]"                      # forget the placement → full search
LEADER_SAW=""; FT_OUT=""; _ft_draw_beacon c >/dev/null 2>&1
check "every searched leader saw the halo"  "${LEADER_SAW//1/}" ""
check "…and the search did route leaders"   "$([[ -n "$LEADER_SAW" ]] && echo yes || echo no)" yes

# ── B. the draw's re-route of a CACHED placement (a layout-epoch bump) ───────
note "an epoch-bumped re-route of a parked callout routes with the halo in its list"
(( FT_LAYOUT_EPOCH++ ))                        # placement still cached; the leader cache is not
LEADER_SAW=""; FT_OUT=""; _ft_draw_beacon c >/dev/null 2>&1
check "the re-routed leader saw the halo"   "$LEADER_SAW" "1"

# ── C. the draw's re-route of a DRAGGED park ────────────────────────────────
note "a dragged park's leader routes with the halo in its list"
# Parked at (12,30) the difference is not academic: routed blind, the line ran FOUR cells
# through the halo (measured); routed with the ink in the list, none.
# The park is a PROPERTY now, not a parallel array. This line used to write
# FT_BEACON_DRAG[c]="12 30" directly, and when that array was replaced by parkedTop/parkedLeft the
# write went nowhere: the chip was never parked, so no dragged leader was routed, and the gate's
# own anti-vacuity guard below caught it — which is the guard doing exactly its job.
ft_set c parkedTop=12 parkedLeft=30
LEADER_SAW=""; FT_OUT=""; _ft_draw_beacon c >/dev/null 2>&1
check "the dragged leader saw the halo"     "${LEADER_SAW//1/}" ""
check "…and it did route one"                "$([[ -n "$LEADER_SAW" ]] && echo yes || echo no)" yes

# The point of knowing: the line that is actually painted keeps off the halo.
_ft_beacon_poly_in_rect "${FT_BEACON_LEADER[c]:-}" $HALO_RECT
check "the dragged leader stays out of the halo" "$FT_RET" 0

unset "FT_BEACON_DRAG[c]"
summary
