#!/usr/bin/env bash
# ft_route — the engine's obstacle-avoiding orthogonal connector router (leader lines for
# callouts, diagrams, HUD pointers). Scores crossings ≫ bends > length, so it takes the
# straightest CLEAN path and only detours when something is actually in the way.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_COLS=60; FT_ROWS=24

# crossings of a polyline against the CURRENT obstacle set (independent recompute, so the
# assertions don't just re-run the code under test's own scoring)
_crossings() {
    local -a wp=($1); local n=${#wp[@]} i r0 c0 r1 c1 j lo hi ov cross=0
    for (( i=0; i+3<n; i+=2 )); do
        r0=${wp[i]}; c0=${wp[i+1]}; r1=${wp[i+2]}; c1=${wp[i+3]}
        for j in "${!_RT_T[@]}"; do
            if (( r0 == r1 )); then
                (( _RT_T[j] <= r0 && r0 <= _RT_B[j] )) || continue
                lo=$(( c0<c1?c0:c1 )); hi=$(( c0<c1?c1:c0 ))
                ov=$(( (hi < _RT_R[j] ? hi : _RT_R[j]) - (lo > _RT_L[j] ? lo : _RT_L[j]) + 1 ))
            else
                (( _RT_L[j] <= c0 && c0 <= _RT_R[j] )) || continue
                lo=$(( r0<r1?r0:r1 )); hi=$(( r0<r1?r1:r0 ))
                ov=$(( (hi < _RT_B[j] ? hi : _RT_B[j]) - (lo > _RT_T[j] ? lo : _RT_T[j]) + 1 ))
            fi
            (( ov > 0 )) && cross=$(( cross + ov ))
        done
    done
    printf '%s' "$cross"
}
_bends() { local -a wp=($1); echo $(( ${#wp[@]}/2 - 2 )); }

note "an empty field: the route is the straight line, no bends"
FT_ROUTE_EXTRA=""
ft_route 5 2 5 30; check "aligned → crossing-free" "$?" "0"
check "straight polyline" "$FT_RET" "5 2 5 30"
check "no bends" "$(_bends "$FT_RET")" "0"

note "an offset pair with a clear field: a single L (one bend)"
ft_route 4 2 9 30; check "clear → crossing-free" "$?" "0"
check "one bend" "$(_bends "$FT_RET")" "1"

note "an obstacle straight in the path: the router DETOURS around it (the callout bug)"
# a control sitting between the endpoints, on the same row
FT_TYPE[blk]=label; FT_PARENT[blk]=""; FT_ABSOLUTE_X[blk]=10; FT_ABSOLUTE_Y[blk]=4
FT_MEASURED_WIDTH[blk]=12; FT_MEASURED_HEIGHT[blk]=3          # rows 4..6, cols 10..21
ft_route 5 2 5 30; rc=$?
check "still finds a crossing-FREE route" "$rc" "0"
check "…verified independently: 0 crossings" "$(_crossings "$FT_RET")" "0"
check "…by bending around it" "$([[ $(_bends "$FT_RET") -ge 1 ]] && echo yes)" "yes"
check "…and it still starts/ends at the endpoints" \
      "$(set -- $FT_RET; echo "$1 $2 ${@: -2}")" "5 2 5 30"

note "excluded controls are not obstacles (you may point AT a thing)"
ft_route 5 2 5 30 blk; check "excluding blk → straight again" "$FT_RET" "5 2 5 30"

note "a fully walled corridor: returns 1 (least-bad) but still yields a polyline"
FT_TYPE[wall]=label; FT_PARENT[wall]=""; FT_ABSOLUTE_X[wall]=0; FT_ABSOLUTE_Y[wall]=0
FT_MEASURED_WIDTH[wall]=60; FT_MEASURED_HEIGHT[wall]=24       # the whole screen
ft_route 5 2 5 30; rc=$?
check "no clean route → returns 1" "$rc" "1"
check "…but a polyline is still produced" "$([[ -n "$FT_RET" ]] && echo yes)" "yes"
ft_remove wall 2>/dev/null; unset 'FT_TYPE[wall]'

note "FT_ROUTE_EXTRA rects are obstacles too (a callout's own box)"
unset 'FT_TYPE[blk]'
FT_ROUTE_EXTRA="4 10 6 21"
ft_route 5 2 5 30; check "extra rect is avoided" "$(_crossings "$FT_RET")" "0"
check "…and it did have to bend" "$([[ $(_bends "$FT_RET") -ge 1 ]] && echo yes)" "yes"
FT_ROUTE_EXTRA=""

note "containers/overlays are NOT obstacles (only real leaf controls block a line)"
FT_TYPE[pnl]=div; FT_PARENT[pnl]=""; FT_ABSOLUTE_X[pnl]=10; FT_ABSOLUTE_Y[pnl]=4
FT_MEASURED_WIDTH[pnl]=12; FT_MEASURED_HEIGHT[pnl]=3
ft_route 5 2 5 30; check "a panel does not block" "$FT_RET" "5 2 5 30"
unset 'FT_TYPE[pnl]'

note "ft_route_draw paints the segments and rounded corners"
FT_OUT=""; ft_clip_reset
ft_route_draw "4 2 4 8 9 8 9 14" "$FT_COLOR_BODY"
out=$FT_OUT
case "$out" in *"─"*) check "horizontal run drawn" 1 1 ;; *) check "horizontal run drawn" 0 1 ;; esac
case "$out" in *"│"*) check "vertical run drawn"   1 1 ;; *) check "vertical run drawn"   0 1 ;; esac
case "$out" in *"╮"*) check "corner turning down-from-left ╮" 1 1 ;; *) check "corner ╮" 0 1 ;; esac
case "$out" in *"╰"*) check "corner turning right-from-up ╰"  1 1 ;; *) check "corner ╰" 0 1 ;; esac

note "a bordered container's RING is an obstacle — four strips, priced as decoration, never 'blocking'"
# A frame's interior stays see-through, but its drawn ring is ink a line breaks. Crossing it
# costs the decoration rate (FT_TIER_DECORATION/100 of a crossing), and a route over a ring
# alone is NOT blocked: the router hunts no detour for it (two bends would cost the judge far
# more than two ring cells). The unlock of callouts from their frame rests on exactly this.
FT_TYPE[ring]=div; FT_PARENT[ring]=""; FT_ABSOLUTE_X[ring]=10; FT_ABSOLUTE_Y[ring]=3
FT_MEASURED_WIDTH[ring]=12; FT_MEASURED_HEIGHT[ring]=5; _ftp_ring_border=true   # rows 3..7, cols 10..21
_ft_route_obstacles
n_ring=0; for _j in "${!_RT_N[@]}"; do [[ "${_RT_N[_j]}" == ring ]] && (( n_ring++ )); done
check "the ring contributes exactly four strips"        "$n_ring" 4
_w=""; for _j in "${!_RT_N[@]}"; do [[ "${_RT_N[_j]}" == ring ]] && _w=${_RT_CROSS[_j]}; done
check "…each crossing at the decoration rate"           "$_w" "$FT_TIER_DECORATION"
ft_route 5 2 5 30; rc=$?
check "a line through the ring only is not 'blocked'"   "$rc" 0
check "…so it stays straight (no detour hunted)"        "$FT_RET" "5 2 5 30"
_ft_route_score "$FT_RET"
check "…two ring cells crossed, in hundredths"          "$FT_ROUTE_CROSS" $(( 2 * FT_TIER_DECORATION ))
check "…and no INK crossed"                             "$FT_ROUTE_HARD" 0
unset 'FT_TYPE[ring]'; unset _ftp_ring_border

note "the obstacle list is SEVEN arrays in lockstep, grown and shrunk only through the helpers"
FT_TYPE[blk]=label; FT_PARENT[blk]=""; FT_ABSOLUTE_X[blk]=10; FT_ABSOLUTE_Y[blk]=4
FT_MEASURED_WIDTH[blk]=12; FT_MEASURED_HEIGHT[blk]=3
_ft_route_obstacles
n0=${#_RT_T[@]}
check "T/L/B/R/I/N/CROSS all the same length after a build" \
      "${#_RT_L[@]} ${#_RT_B[@]} ${#_RT_R[@]} ${#_RT_I[@]} ${#_RT_N[@]} ${#_RT_CROSS[@]}" "$n0 $n0 $n0 $n0 $n0 $n0"
_ft_obstacle_push 1 1 2 2 "$FT_IMPORTANCE_NORMAL" ""
check "a push grows every array"                        "${#_RT_T[@]} ${#_RT_N[@]} ${#_RT_CROSS[@]}" "$(( n0+1 )) $(( n0+1 )) $(( n0+1 ))"
check "…a control's cell crosses at the full rate"      "${_RT_CROSS[-1]}" 100
_ft_obstacle_pop
check "a pop shrinks every array"                       "${#_RT_T[@]} ${#_RT_N[@]} ${#_RT_CROSS[@]}" "$n0 $n0 $n0"

note "every cell is scored ONCE: a bend on an obstacle cell is one crossing, not two"
unset 'FT_TYPE[blk]'
FT_TYPE[dot]=label; FT_PARENT[dot]=""; FT_ABSOLUTE_X[dot]=10; FT_ABSOLUTE_Y[dot]=5
FT_MEASURED_WIDTH[dot]=1; FT_MEASURED_HEIGHT[dot]=1                                 # the single cell (5,10)
_ft_route_obstacles
_ft_route_score "5 2 5 10 9 10"                                                     # bends exactly on it
check "the corner cell counts one crossing"             "$FT_ROUTE_HARD" 1
_ft_route_score "5 10 5 10"
check "a single-cell polyline on it counts one too"     "$FT_ROUTE_HARD" 1
unset 'FT_TYPE[dot]'

note "performance: a clean route is one scoring pass (the common case)"
ft_now_ms; t0=$FT_RET
for _i in $(seq 1 20); do ft_route 5 2 5 30 >/dev/null; done
ft_now_ms; t1=$FT_RET
per=$(( (t1 - t0) / 20 ))
check "clean route under 5ms each (got ${per}ms)" "$([[ $per -lt 5 ]] && echo fast)" "fast"

summary
