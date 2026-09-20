#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Tests for controls/ft-beacon.bash — the floating overlay marker.
#
#  Covers: prototype registration; the constructor arming an animation; geometry
#  (target-relative + outset, and absolute); the circled-number glyph map; the
#  effect envelope (pulse/blink/bob/none → visibility, colour, vertical hop);
#  themeable pulse colour; and the two lifetimes (oneshot self-destructs and
#  repaints its ground; persist loops). It is the same engine the '.' locator
#  now rides on, so these assertions also guard the homing beacon.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=80; FT_ROWS=24

# A small host so beacons have a laid-out target/root to point at.
ft-form name=root width=80 height=12
  ft-button name=btn text="Target"
end_ft_form
ft_layout root
FT_ROOT=root

note "the class registers as an absolute, non-focusable overlay with a draw fn"
ft_prototype_init beacon        # classes populate their tables lazily on first use
check "draw fn is _ft_draw_beacon"      "${FT_PROTO_DRAW[beacon]}" "_ft_draw_beacon"
check "beacons are never focusable"     "${FT_PROTO_FOCUSABLE[beacon]}" "0"
case " ${FT_PROTO_DEFAULTS[beacon]} " in *" position=absolute "*) check "default position:absolute" 1 1 ;;
                                         *) check "default position:absolute" 0 1 ;; esac
case " ${FT_PROTO_DEFAULTS[beacon]} " in *" lifetime=persist "*) check "default lifetime:persist" 1 1 ;;
                                         *) check "default lifetime:persist" 0 1 ;; esac

note "the constructor registers the control AND arms its animation"
ft-beacon name=bk target=btn
check "the beacon is a registered control" "${FT_TYPE[bk]:-}" "beacon"
[[ -n "${FT_ANIM_PHASE[bk]:-}" ]] && check "arming started an animation" 1 1 || check "arming started an animation" 0 1
check "persist loops (loop flag set)"      "${FT_ANIM_LOOP[bk]}" "1"
ft_remove bk
[[ -z "${FT_ANIM_PHASE[bk]:-}" ]] && check "destroy stops the animation" 1 1 || check "destroy stops the animation" 0 1
[[ -z "${FT_TYPE[bk]:-}" ]] && check "destroy removes the control" 1 1 || check "destroy removes the control" 0 1

note "geometry: a target frame sits OUTSIDE the target by 'outset'"
FT_ABSOLUTE_X[btn]=10; FT_ABSOLUTE_Y[btn]=4; FT_MEASURED_WIDTH[btn]=8; FT_MEASURED_HEIGHT[btn]=1
ft-beacon name=bg target=btn outset=1
_ft_beacon_rect bg
check "left  = x - outset"        "$FT_BEACON_RECT_LEFT" "9"
check "top   = y - outset"        "$FT_BEACON_RECT_TOP" "3"
check "right = x + w-1 + outset"  "$FT_BEACON_RECT_RIGHT" "18"
check "bottom= y + h-1 + outset"  "$FT_BEACON_RECT_BOTTOM" "5"
ft_set bg outset=2
_ft_beacon_rect bg
check "outset widens the frame"   "$FT_BEACON_RECT_LEFT" "8"
ft_remove bg

note "geometry: with no target, a beacon uses its own absolute rect"
ft-beacon name=ba target=
FT_ABSOLUTE_X[ba]=20; FT_ABSOLUTE_Y[ba]=6; FT_MEASURED_WIDTH[ba]=5; FT_MEASURED_HEIGHT[ba]=3
_ft_beacon_rect ba
check "left = own abs x"          "$FT_BEACON_RECT_LEFT" "20"
check "right = x + w - 1"         "$FT_BEACON_RECT_RIGHT" "24"
check "bottom = y + h - 1"        "$FT_BEACON_RECT_BOTTOM" "8"
ft_remove ba

note "the circled-number glyph map (⓪ ① … ⑳), with an ASCII fallback"
_ft_beacon_glyph 1;  check "1 → ①"  "$FT_RET" "①"
_ft_beacon_glyph 3;  check "3 → ③"  "$FT_RET" "③"
_ft_beacon_glyph 0;  check "0 → ⓪"  "$FT_RET" "⓪"
_ft_beacon_glyph 20; check "20 → ⑳" "$FT_RET" "⑳"
_ft_beacon_glyph 99; check "out of range → (99)" "$FT_RET" "(99)"
( FT_USE_UTF8=0; _ft_beacon_glyph 2; check "non-UTF8 → (2)" "$FT_RET" "(2)" )

note "the effect envelope: pulse always shows; blink halves; bob hops; none is steady"
ft-beacon name=be target=btn effect=blink
_ft_beacon_effect be border 0;   check "blink lap-front is visible" "$FT_BEACON_EFFECT_VISIBLE" "1"
_ft_beacon_effect be border 6;   check "blink lap-back is hidden"   "$FT_BEACON_EFFECT_VISIBLE" "0"
ft_set be effect=bob
_ft_beacon_effect be number 0;   check "bob lap-front: no hop" "$FT_BEACON_EFFECT_DY" "0"
_ft_beacon_effect be number 6;   check "bob lap-back: hops up a row" "$FT_BEACON_EFFECT_DY" "1"
ft_set be effect=pulse
_ft_beacon_effect be border 6;   check "pulse is always visible" "$FT_BEACON_EFFECT_VISIBLE" "1"
ft_remove be

note "the pulse colour is THEMEABLE (--beacon-N / --locator-N), never hardcoded"
ft-beacon name=bc target=btn
ft_use_theme ft-dark;  _ft_beacon_pulsecolor bc 0; dk=$FT_RET
ft_use_theme ft-ocean; _ft_beacon_pulsecolor bc 0; oc=$FT_RET
[[ "$dk" != "$oc" ]] && check "two themes give two colours" 1 1 || check "two themes give two colours" 0 1
check "the SGR is bold + a bright fg" "$dk" $'\e[38;5;220;1m'
ft_use_theme ft-dark
ft_remove bc

note "a FRAME beacon actually paints its heavy rules on top"
FT_OUT=""
ft-beacon name=bf target=btn
_ft_draw_beacon bf
case "$FT_OUT" in *"┏"*"┓"*) check "the frame's heavy corners are painted" 1 1 ;;
                  *)          check "the frame's heavy corners are painted" 0 1 ;; esac
ft_remove bf

note "a NUMBER beacon paints its circled glyph at the chosen corner"
FT_OUT=""
ft-beacon name=bn target=btn variant=number number=4 corner=topright
_ft_draw_beacon bn
case "$FT_OUT" in *"④"*) check "the badge glyph ④ is painted" 1 1 ;;
                  *)      check "the badge glyph ④ is painted" 0 1 ;; esac
ft_remove bn

note "a CALLOUT beacon paints a rounded box with its text and a pointer at the target"
FT_ABSOLUTE_X[btn]=40; FT_ABSOLUTE_Y[btn]=12; FT_MEASURED_WIDTH[btn]=8; FT_MEASURED_HEIGHT[btn]=1
FT_OUT=""
ft-beacon name=bco target=btn variant=callout text="Pick a colour here" place=above calloutWidth=20
_ft_draw_beacon bco
case "$FT_OUT" in *"╭"*"╮"*) check "the callout box has rounded corners" 1 1 ;;
                  *)          check "the callout box has rounded corners" 0 1 ;; esac
case "$FT_OUT" in *"Pick a colour"*) check "the callout shows its text" 1 1 ;;
                  *)                 check "the callout shows its text" 0 1 ;; esac
case "$FT_OUT" in *"▼"*) check "place=above points DOWN (▼) at the target" 1 1 ;;
                  *)      check "place=above points DOWN (▼) at the target" 0 1 ;; esac
ft_set bco place=right
FT_OUT=""; _ft_draw_beacon bco
case "$FT_OUT" in *"◀"*) check "place=right points LEFT (◀) at the target" 1 1 ;;
                  *)      check "place=right points LEFT (◀) at the target" 0 1 ;; esac
ft_set bco place=below
FT_OUT=""; _ft_draw_beacon bco
case "$FT_OUT" in *"▲"*) check "place=below points UP (▲) at the target" 1 1 ;;
                  *)      check "place=below points UP (▲) at the target" 0 1 ;; esac
( FT_USE_UTF8=0; FT_OUT=""; ft_set bco place=above; _ft_draw_beacon bco
  case "$FT_OUT" in *"v"*) check "non-UTF8 pointer falls back to 'v'" 1 1 ;;
                    *)      check "non-UTF8 pointer falls back to 'v'" 0 1 ;; esac )
# The ASCII badge "(2)" is THREE cells where ② is one; the badge width was hard-coded to 1, so
# the ASCII top border ran two cells past the box's right corner. Top and bottom borders must
# be the same width whatever the badge is drawn with.
( FT_USE_UTF8=0; FT_OUT=""; ft_set bco number=2 place=above; _ft_draw_beacon bco
  top=""; bottom=""
  # `[-x>]*` because the top border also carries the ASCII close box (x) and, when a `next`
  # listener is registered, the next glyph (>) — chrome the bottom border does not have. The
  # point of the assertion is that the two borders still measure the SAME, whatever rides on top.
  [[ "$FT_OUT" =~ \+\(2\)[-x\>]*\+ ]] && top=${BASH_REMATCH[0]}
  [[ "$FT_OUT" =~ \+-+\+ ]]           && bottom=${BASH_REMATCH[0]}
  check "non-UTF8 top border carries the (2) badge"        "$(( ${#top} > 0 ))" 1
  check "…and is exactly as wide as the bottom border"     "${#top}" "${#bottom}" )
ft_remove bco

note "the ⊠ close box: one cell wide, top-right, and it actually closes"
# A floating chip over your work that offers no way to dismiss it is the complaint, not the
# feature — so `closable` defaults ON. The glyph is U+22A0 SQUARED TIMES, not the more obvious
# U+2612 BALLOT BOX WITH X, because U+2612 is East-Asian-AMBIGUOUS: a terminal may render it two
# columns wide and push the top border a cell past its own corner. That is not a hypothetical —
# it is the same class of bug as the ASCII "(2)" badge two notes up, and as tabs-in-text.
ft_display_width "⊠"
check "the close glyph occupies exactly one column"   "$FT_DISPLAY_WIDTH" 1
ft-form name=capp display=flex flexDirection=column
    ft-label name=ctgt text="the target"
end_ft_form
_csv_root=$FT_ROOT; FT_ROOT=capp
ft_layout capp >/dev/null 2>&1
ft-beacon name=cb target=ctgt variant=callout text="a chip that can be dismissed" number=3
ft_layout capp >/dev/null 2>&1
FT_OUT=""; _ft_beacon_paint_callout cb beacon
case "$FT_OUT" in *"⊠"*) check "the chip paints a close box" 1 1 ;;
                  *)      check "the chip paints a close box" 0 1 ;; esac
_ft_beacon_placement cb
check "the close cell is the top-right interior cell" "${FT_BEACON_CLOSE[cb]:-}" \
      "$FT_PLACED_T $(( FT_PLACED_L + FT_PLACED_W - 2 ))"
# The top border carries badge + chrome and must still measure exactly as wide as the bottom —
# the failure mode is a border that runs one cell past its own corner.
_ctop=""; _cbot=""
[[ "$FT_OUT" =~ ╭③[─┴]*⊠?╮ ]] && _ctop=${BASH_REMATCH[0]}
[[ "$FT_OUT" =~ ╰─+╯ ]]       && _cbot=${BASH_REMATCH[0]}
ft_display_width "$_ctop"; _ctw=$FT_DISPLAY_WIDTH
ft_display_width "$_cbot"; _cbw=$FT_DISPLAY_WIDTH
check "top border is as wide as the bottom, close box and all" "$_ctw" "$_cbw"

# Clicking it, with no listener, dismisses the chip — that is what a close box promises.
set -- ${FT_BEACON_CLOSE[cb]}; _cr=$1; _cc=$2
_ft_beacon_close_at "$_cc" "$_cr"
check "clicking the close box claimed the click"      "$?" 0
check "…and the callout is gone"                      "${FT_TYPE[cb]-gone}" "gone"

# CLOSING IS A CANCELLABLE DEFAULT ACTION (the DOM's preventDefault, which this framework's
# dispatch already implements: any listener returning NONZERO cancels). So there are two distinct
# cases, and the difference between them is the whole contract:
#   · a listener that only wants to KNOW returns 0 — the event fires AND the chip still closes,
#     which is what the reader asked for by clicking it;
#   · a listener that wants to KEEP it returns nonzero — the event fires and nothing is removed.
# (This first shipped as "any listener at all suppresses the close", which made every observer a
# veto and left no way to observe-and-still-close.)
CLOSE_FIRED=0
cb2_on_close() { CLOSE_FIRED=1; return 0; }          # observes, does not cancel
ft-beacon name=cb2 target=ctgt variant=callout text="a chip whose owner just watches" number=4 onClose=cb2_on_close
ft_layout capp >/dev/null 2>&1
FT_OUT=""; _ft_beacon_paint_callout cb2 beacon
set -- ${FT_BEACON_CLOSE[cb2]}; _cr=$1; _cc=$2
_ft_beacon_close_at "$_cc" "$_cr"
check "an observing close listener ran"               "$CLOSE_FIRED" 1
check "…and did NOT veto the close"                   "${FT_TYPE[cb2]-gone}" "gone"

VETO_FIRED=0
cb4_on_close() { VETO_FIRED=1; return 1; }           # cancels, the way preventDefault does
ft-beacon name=cb4 target=ctgt variant=callout text="a chip that refuses to go" number=6 onClose=cb4_on_close
ft_layout capp >/dev/null 2>&1
FT_OUT=""; _ft_beacon_paint_callout cb4 beacon
set -- ${FT_BEACON_CLOSE[cb4]}; _cr=$1; _cc=$2
_ft_beacon_close_at "$_cc" "$_cr"
check "a cancelling close listener ran"               "$VETO_FIRED" 1
check "…and the callout survived, as it asked"        "${FT_TYPE[cb4]-gone}" "beacon"
ft_remove cb4

# closable=false refuses the chrome outright, and publishes no clickable cell to go with it.
ft-beacon name=cb3 target=ctgt variant=callout text="a chip that must be read" number=5 closable=false
ft_layout capp >/dev/null 2>&1
FT_OUT=""; _ft_beacon_paint_callout cb3 beacon
case "$FT_OUT" in *"⊠"*) check "closable=false paints no close box" 0 1 ;;
                  *)      check "closable=false paints no close box" 1 1 ;; esac
check "…and publishes no close cell"                  "${FT_BEACON_CLOSE[cb3]-unset}" "unset"
ft_remove cb3; ft_remove capp; FT_ROOT=$_csv_root

note "the drag ghost is painted by ONE painter, reached two ways"
# A grabbed callout draws as a ring plus its badge, and `_ft_beacon_paint_callout` reaches that
# from two places: a fast path that skips the placement prelude when a placement is cached, and a
# fall-through for a grab with no cache (a resize mid-drag). Each used to carry its own copy of
# the ring — identical line for line except for the names of the four box coordinates — which is
# how a fix to the ghost lands on one drag and not the other. Now both call
# `_ft_beacon_paint_ghost`; this compares the CELLS the two paths emit, not just that they ran.
ft-form name=gapp display=flex flexDirection=column
    ft-label name=gtgt text="the target"
end_ft_form
_gsv_root=$FT_ROOT; FT_ROOT=gapp
ft_layout gapp >/dev/null 2>&1
ft-beacon name=gb target=gtgt variant=callout text="a callout being dragged about" number=2
ft_layout gapp >/dev/null 2>&1
FT_OUT=""; _ft_beacon_paint_callout gb beacon >/dev/null 2>&1     # cache a placement
_FT_BEACON_GRAB="gb 0 0"; ft_set gb dragging=true; FT_BEACON_DRAG[gb]="8 20"
FT_OUT=""; _ft_beacon_paint_callout gb beacon
_gfast=$FT_OUT; _gfast_ext=${FT_BEACON_EXTENT[gb]}; _gfast_box=${FT_BEACON_BOX[gb]}
unset 'FT_BEACON_PC[gb]' 'FT_BEACON_PKEY[gb]'                      # …now force the fall-through
FT_OUT=""; _ft_beacon_paint_callout gb beacon
check "both ghost paths emit the same cells"        "$FT_OUT"                  "$_gfast"
check "…the same published extent"                  "${FT_BEACON_EXTENT[gb]}"  "$_gfast_ext"
check "…and the same draggable box"                 "${FT_BEACON_BOX[gb]}"     "$_gfast_box"
# `${x-}` not `${x:-}`: a ghost sets its leader to EMPTY, which `:-` cannot tell from unset.
check "a ghost owns no leader"                      "${FT_BEACON_LEADER[gb]-unset}" ""
check "…and publishes no clickable ▶"               "${FT_BEACON_NEXT[gb]-unset}"   "unset"
_FT_BEACON_GRAB=""; ft_remove gb; ft_remove gapp; FT_ROOT=$_gsv_root

note "importance is ACTION DENSITY: static per class, and live per STATE through the cascade"
# What a callout may cover is driven by importance, and importance is not a fixed label — a
# textfield is nearly inert until the caret is in it, at which point it is the most important
# thing on screen. This asserts the whole chain the placer actually reads.
#
# THE BUG THIS PINS: `importance` was declared as a prototype default on `ft_control`, and a
# prototype default is an instance-level write, which outranks every stylesheet rule exactly as
# inline style does. So `textfield:focus { importance: crucial }` was a silent no-op and NO state
# could ever change a control's importance. Nothing failed — it just quietly never worked. The
# default now lives at the READ instead. Second half of the same bug: `_ft_control_importance` asked
# `ft_resolved_prop`, which does not consult the stylesheet, so even a working sheet never reached
# the placer; it asks `ft_style` now.
ft_stylesheet name=impsheet style='
    textfield        { importance: minor; }
    textfield:focus  { importance: crucial; }
'
ft-form name=improot width=80 height=8
  ft-textfield name=imptf value="hi" size=10
  ft-button name=impbtn text="Go"
end_ft_form
ft_layout improot
_ft_control_importance impbtn
check "a button is crucial by class default"        "$FT_RET" "$FT_IMPORTANCE_CRUCIAL"
_ft_sv_focus=${FT_FOCUS:-}
FT_FOCUS=""
_ft_control_importance imptf
check "an UNFOCUSED textfield takes the sheet's minor" "$FT_RET" "$FT_IMPORTANCE_MINOR"
FT_FOCUS=imptf
_ft_control_importance imptf
check "…and becomes crucial when the caret enters it" "$FT_RET" "$FT_IMPORTANCE_CRUCIAL"
FT_FOCUS=""
_ft_control_importance imptf
check "…and drops back when focus leaves"             "$FT_RET" "$FT_IMPORTANCE_MINOR"
FT_FOCUS=$_ft_sv_focus
ft_remove improot

note "anchor=… : the nine compass points of the target, as an API contract"
# THE PUBLIC PROMISE, tested at the API rather than through a demo. `anchor` names WHICH POINT
# of the target the arrowhead lands on; auto (the default) resolves to the middle of whichever
# side the box ended up on. The demo suite proves the same nine values on a real page — this
# proves the contract itself, so a caller can rely on it without the demo existing.
#
# The head is the LAST point of the leader polyline: _ft_beacon_leader ends the route on it.
FT_ABSOLUTE_X[btn]=30; FT_ABSOLUTE_Y[btn]=8; FT_MEASURED_WIDTH[btn]=20; FT_MEASURED_HEIGHT[btn]=5
_t_tT=8; _t_tL=30; _t_tB=12; _t_tR=49
_t_mr=$(( (_t_tT + _t_tB) / 2 )); _t_mc=$(( (_t_tL + _t_tR) / 2 ))
# outset=0 so the anchored rect IS the target's rect; with the default outset the nine points are
# still the nine points, just of a rect one cell larger all round.
_anchor_head() {                # anchor → A_R A_C, the arrowhead the engine actually drew
    ft-beacon name=ba target=btn variant=callout text="anchored" calloutWidth=18 outset=0 anchor="$1"
    FT_OUT=""; _ft_draw_beacon ba
    local poly=${FT_BEACON_LEADER[ba]} w
    A_R=""; A_C=""
    for w in $poly; do A_R=$A_C; A_C=$w; done
    ft_remove ba
}
while read -r _a _er _ec; do
    [[ -z "$_a" ]] && continue
    _anchor_head "$_a"
    if [[ "$A_R" == "$_er" && "$A_C" == "$_ec" ]]; then
        check "anchor=$_a puts the head at ($_er,$_ec)" 1 1
    else
        check "anchor=$_a puts the head at ($_er,$_ec)" 0 1
        printf '         head=(%s,%s)\n' "$A_R" "$A_C"
    fi
# The head stops CLEAR of the point it names — arrowPadding=1 blank cell plus the glyph itself,
# so one row above/below and two columns left/right. centerCenter is the exception: it names the
# middle, and the head goes there.
done <<EOF
topLeft      $(( _t_tT - 1 )) $_t_tL
topCenter    $(( _t_tT - 1 )) $_t_mc
topRight     $(( _t_tT - 1 )) $_t_tR
bottomLeft   $(( _t_tB + 1 )) $_t_tL
bottomCenter $(( _t_tB + 1 )) $_t_mc
bottomRight  $(( _t_tB + 1 )) $_t_tR
centerLeft   $_t_mr $(( _t_tL - 2 ))
centerRight  $_t_mr $(( _t_tR + 2 ))
centerCenter $_t_mr $_t_mc
EOF
# AUTO IS THE MIDDLE OF A SIDE, never a corner — the default a caller gets when they say nothing.
# That is the whole shape of the rule the screenshots asked for: a leader meets the edge it faces,
# square on, at its midpoint.
_anchor_head auto
if   (( A_R == _t_tT - 1 || A_R == _t_tB + 1 )); then
    check "anchor=auto lands on the middle of the top/bottom edge" "$A_C" "$_t_mc"
elif (( A_C == _t_tL - 2 || A_C == _t_tR + 2 )); then
    check "anchor=auto lands on the middle of the left/right edge" "$A_R" "$_t_mr"
else
    check "anchor=auto lands on the middle of a side" "($A_R,$A_C)" "an edge midpoint"
fi
# CENTERCENTER IS THE ONLY ONE ALLOWED TO CROSS THE TARGET. Every other anchor names a point ON
# the boundary, so its head sits on the edge and the line stops outside; centerCenter names the
# middle, so its head is inside by definition.
_t_inside=""
while read -r _a; do
    [[ -z "$_a" ]] && continue
    _anchor_head "$_a"
    (( A_R > _t_tT && A_R < _t_tB && A_C > _t_tL && A_C < _t_tR )) && _t_inside+=" $_a"
done <<EOF
topLeft
topCenter
topRight
bottomLeft
bottomCenter
bottomRight
centerLeft
centerRight
auto
EOF
check "no anchor but centerCenter puts its head inside the target" "$_t_inside" ""
_anchor_head centerCenter
(( A_R > _t_tT && A_R < _t_tB && A_C > _t_tL && A_C < _t_tR )) \
    && check "centerCenter does put its head inside the target" 1 1 \
    || check "centerCenter does put its head inside the target" 0 1
FT_ABSOLUTE_X[btn]=40; FT_ABSOLUTE_Y[btn]=12; FT_MEASURED_WIDTH[btn]=8; FT_MEASURED_HEIGHT[btn]=1

note "lifetime=oneshot: the final frame destroys the beacon and repaints its ground"
ft-beacon name=bo target=btn lifetime=oneshot cycles=1
check "oneshot does not loop" "${FT_ANIM_LOOP[bo]}" "0"
len=${FT_ANIM_LENGTH[bo]}
FT_ANIM_PHASE[bo]=$(( len - 1 ))          # the last live frame (engine retires the next)
_ft_beacon_frame bo beacon
[[ -z "${FT_TYPE[bo]:-}" ]] && check "the beacon destroyed itself" 1 1 || check "the beacon destroyed itself" 0 1
[[ -z "${FT_ANIM_PHASE[bo]:-}" ]] && check "...and its animation is gone" 1 1 || check "...and its animation is gone" 0 1

note "lifetime=persist: a mid-life frame just repaints, never destroys"
ft-beacon name=bp target=btn lifetime=persist
FT_ANIM_PHASE[bp]=4
_ft_beacon_frame bp beacon
[[ -n "${FT_TYPE[bp]:-}" ]] && check "a persistent beacon survives its frames" 1 1 || check "a persistent beacon survives its frames" 0 1
ft_remove bp

# ── Tier rects ────────────────────────────────────────────────────────────────
# THE INVARIANT EVERY HOOK MUST HOLD: the tiers PARTITION the control — every cell claimed once,
# none invented, none dropped. Burial is an area, so a hook that overlaps its own rects doubles
# a region's price and one that leaves a gap makes cells free; either silently bends every
# placement without failing anything. Proved by painting the rects onto a cell map, because a
# hook can be wrong in a way that still returns plausible-looking numbers.
note "tier rects partition each control exactly"
ft-form name=tapp width=40 height=10
ft-label     name=tlab  text="hello" parent=tapp
ft-textfield name=tfld  value="abc" size=10 parent=tapp
FT_ABSOLUTE_X[tlab]=2;  FT_ABSOLUTE_Y[tlab]=1;  FT_MEASURED_WIDTH[tlab]=5;  FT_MEASURED_HEIGHT[tlab]=1
FT_ABSOLUTE_X[tfld]=2;  FT_ABSOLUTE_Y[tfld]=4;  FT_MEASURED_WIDTH[tfld]=12; FT_MEASURED_HEIGHT[tfld]=3
_ft_route_obstacles
ft_tier_rects
declare -A _tw=() _th=()
for (( _j=0; _j<${#_RT_T[@]}; _j++ )); do
    for (( _y=_RT_T[_j]; _y<=_RT_B[_j]; _y++ )); do
        for (( _x=_RT_L[_j]; _x<=_RT_R[_j]; _x++ )); do _tw["$_y,$_x"]=1; done
    done
done
for (( _j=0; _j<FT_TIER_COUNT; _j++ )); do
    for (( _y=FT_TIER_TOP[_j]; _y<=FT_TIER_BOTTOM[_j]; _y++ )); do
        for (( _x=FT_TIER_LEFT[_j]; _x<=FT_TIER_RIGHT[_j]; _x++ )); do (( _th["$_y,$_x"]++ )); done
    done
done
_tdbl=0; _tmiss=0; _textra=0
for _k in "${!_th[@]}"; do
    (( _th[$_k] > 1 )) && (( _tdbl++ ))
    [[ -n "${_tw[$_k]:-}" ]] || (( _textra++ ))
done
for _k in "${!_tw[@]}"; do [[ -n "${_th[$_k]:-}" ]] || (( _tmiss++ )); done
check "no cell is counted twice"        "$_tdbl"   0
check "no cell is dropped"              "$_tmiss"  0
check "no cell is invented"             "$_textra" 0
check "the field decomposed into tiers" $(( FT_TIER_COUNT > ${#_RT_T[@]} ? 1 : 0 )) 1

# A ring is decoration and the run past "abc" is empty text; both must be CHEAPER than the text
# beside them, and neither free — "cheap is not free" is what keeps a search from stacking
# callouts on borders forever.
_tmin=99999; _tmax=0
for (( _j=0; _j<FT_TIER_COUNT; _j++ )); do
    (( FT_TIER_WEIGHT[_j] < _tmin )) && _tmin=${FT_TIER_WEIGHT[_j]}
    (( FT_TIER_WEIGHT[_j] > _tmax )) && _tmax=${FT_TIER_WEIGHT[_j]}
done
check "the cheapest tier is cheaper than the dearest" $(( _tmin < _tmax ? 1 : 0 )) 1
check "no tier is free"                               $(( _tmin > 0 ? 1 : 0 ))     1

# Flat pricing must still be reachable exactly — it is the A/B baseline, and the proof that the
# tiers only redistribute cost rather than inventing or losing any.
_ft_beacon_overlap 4 2 12 3; _tiered=$FT_RET
FT_TIER_CONTENT=100 FT_TIER_DECORATION=100 FT_TIER_EMPTY_TEXT=100 ft_tier_rects
_ft_beacon_overlap 4 2 12 3; _tflat=$FT_RET
check "tiers cost less than flat over the same field" $(( _tiered < _tflat ? 1 : 0 )) 1
ft_remove tapp

# ── The z tier follows the variant, WHENEVER the variant is set ──────────────
# "A callout is the most on-top of all" is a contract about a property, and `variant` is a
# runtime property: FT_PROTO_REPROP lists it precisely so it can be changed. Derived in the
# constructor alone, the cached tier went stale in both directions — `ft_set b
# variant=callout` gave a callout at z=0 that every frame beacon was free to paint over, and a
# demoted callout kept z=10 and went on suppressing its neighbours. Asserted on the tier AND on
# what the tier decides: the order the two-pass composite paints in, and the cells a lower
# overlay refuses to draw.
note "variant= at runtime moves the z tier, both directions"
ft-form name=zapp width=60 height=14
  ft-label name=ztgt text="the target row"
end_ft_form
ft_layout zapp
FT_ROOT=zapp
ft-beacon name=zflip target=ztgt variant=frame  effect=none
ft-beacon name=zcall target=ztgt variant=callout effect=none text="a callout on top"
check "a constructed callout is the top tier" "${FT_OVERLAY_Z_ORDER[zcall]}" "10"
check "a constructed frame is the base tier"  "${FT_OVERLAY_Z_ORDER[zflip]}" "0"

ft_set zflip variant=callout
check "promoted to callout at runtime → top tier" "${FT_OVERLAY_Z_ORDER[zflip]}" "10"
ft_set zcall variant=frame
check "demoted to frame at runtime → base tier"   "${FT_OVERLAY_Z_ORDER[zcall]}" "0"

# The composite paints tier 0 first and tier 10 last; the order is the whole point of the tier.
_zorder=""
_zdraw_src=$(declare -f _ft_draw_beacon)
eval "_ft_draw_beacon_real${_zdraw_src#_ft_draw_beacon}"
_ft_draw_beacon() { _zorder+="$1 "; _ft_draw_beacon_real "$@"; }
FT_OUT=""; _ft_composite_overlays >/dev/null 2>&1
eval "$_zdraw_src"                             # put the real painter back
check "the runtime callout is composited LAST" "${_zorder% }" "zcall zflip"

# …and the guarantee under the composite: a lower overlay does not draw where a higher one is.
FT_OVERLAY[zflip]="4 4 8 40"                   # pretend the promoted callout owns this rect
_ft_beacon_cell_blocked zcall 6 10 && _zb=blocked || _zb=clear
check "the demoted frame will not paint over the promoted callout" "$_zb" "blocked"
_ft_beacon_cell_blocked zflip 6 10 && _zb=blocked || _zb=clear
check "…and the callout is not blocked by the frame"               "$_zb" "clear"
ft_remove zcall; ft_remove zflip; ft_remove zapp
FT_ROOT=root


# ═══ ONE ALPHA BLEND ═════════════════════════════════════════════════════════
# docs/transitions.md §6a: the shimmer effect and the arrow's exit=fade are "the same arithmetic
# open-coded", and merging them "deletes two copies of the opacity blend". They are one function
# now — _ft_alpha_blend — and this is the gate on the contract that merge had to preserve, which
# is not the same for both callers: the arrow FAILS on a colour it cannot read so it can keep its
# solid ink (a wrong colour is worse than no blend), while the shimmer SUBSTITUTES so an
# unreadable end still gets a ghost. One function, two failure modes, chosen by the caller.
note "one alpha blend serves the shimmer and the arrow"
check "the bigarrow-private copy is gone" \
      "$(declare -F _ft_bigarrow_mix >/dev/null 2>&1 && echo present || echo gone)" "gone"
check "…and the shared one is here" \
      "$(declare -F _ft_alpha_blend >/dev/null 2>&1 && echo present || echo missing)" "present"

# the arithmetic: 0% is the ground, 100% is the ink, and the midpoint is between them
ft_color_sgr 16  48; _bg_sgr=$FT_RET
ft_color_sgr 231 38; _ink_sgr=$FT_RET
_ft_alpha_blend "$_bg_sgr" "$_ink_sgr" 0;   _at0=$FT_RET
_ft_alpha_blend "$_bg_sgr" "$_ink_sgr" 100; _at100=$FT_RET
_ft_alpha_blend "$_bg_sgr" "$_ink_sgr" 50;  _at50=$FT_RET
check "0% lands on the ground"  "$(ft_sgr_rgb "$_at0" 38 && echo "$FT_RGB_RED")"   "0"
check "100% lands on the ink"   "$(ft_sgr_rgb "$_at100" 38 && echo "$FT_RGB_RED")" "255"
check "…and 50% is between them" \
      "$(ft_sgr_rgb "$_at50" 38 && echo "$(( FT_RGB_RED > 100 && FT_RGB_RED < 160 ))")" "1"
# ANTI-VACUITY: three empty strings would satisfy nothing above but would compare equal to each
# other, so demand the three answers are actually DIFFERENT and non-empty.
check "…and the three are distinct, non-empty answers" \
      "$(( ${#_at0} > 0 && ${#_at50} > 0 && ${#_at100} > 0 ))$([[ "$_at0" != "$_at50" && "$_at50" != "$_at100" ]] && echo " distinct")" \
      "1 distinct"

note "…and the two callers' failure modes, which is why it is one function and not one rule"
# An SGR the reader cannot turn into RGB: a bare attribute carries no colour.
_unreadable=$'\e[1m'
if _ft_alpha_blend "$_bg_sgr" "$_unreadable" 50; then _r=drew; else _r=failed; fi
check "no fallback → it FAILS, so the arrow keeps its solid ink" "$_r" "failed"
check "…and says nothing rather than guessing"                   "$FT_RET" ""
if _ft_alpha_blend "$_bg_sgr" "$_unreadable" 100 255,0,0; then _r=drew; else _r=failed; fi
check "a fallback → it SUBSTITUTES, so the shimmer still ghosts"  "$_r" "drew"
check "…using the substitute that was handed to it" \
      "$(ft_sgr_rgb "$FT_RET" 38 && echo "$FT_RGB_RED,$FT_RGB_GREEN,$FT_RGB_BLUE")" "255,0,0"


# ═══ PLACING A BEACON WITHOUT A FRAME ════════════════════════════════════════
# Placement is computed at PAINT and cached, so anything wanting to know where a callout went
# had to drive a frame first. ft_beacon_place closes that: it runs the beacon's own draw into a
# discarded buffer, so a forced placement and a painted one cannot disagree — there is one search
# reached one way.
note "ft_beacon_place answers before any frame exists"
ft-form name=papp width=90 height=30
    ft-button name=ptgt text="Target"
end_ft_form
FT_ROOT=papp; ft_layout papp >/dev/null 2>&1
ft-beacon name=pc parent=papp variant=callout target=ptgt calloutWidth=30 effect=none \
          text="A sentence long enough to wrap and be placed somewhere."
ft_beacon_side pc; check "…nothing is placed before it is asked" "$FT_RET" ""
ok    "ft_beacon_place succeeds"           ft_beacon_place pc
ft_beacon_side pc
check "…and now the side is known"         "$(case "$FT_RET" in above|below|left|right) echo yes ;; *) echo "no($FT_RET)" ;; esac)" "yes"
_t_side=$FT_RET
_ft_beacon_placement pc
check "…with a real box behind it, not an empty record" \
      "$(( FT_PLACED_W > 0 && FT_PLACED_H > 0 ))" "1"

note "…and the paint that follows re-searches nothing"
# THE COST QUESTION. A forced placement that fills a key the next paint MISSES would double the
# search on every step. The key holds no animation phase and no layout epoch, so with the same
# inputs the paint is a cache hit — observable directly as the key surviving the paint.
_t_key=${FT_BEACON_PKEY[pc]:-}
check "…a placement key exists to compare (else the next check is vacuous)" "$(( ${#_t_key} > 0 ))" "1"
FT_OUT=""; ft_clip_reset; _ft_beacon_rect pc; _ft_beacon_paint_callout pc 0
check "the paint reused the forced placement" "${FT_BEACON_PKEY[pc]:-}" "$_t_key"
check "…and did not move it"                  "$(ft_beacon_side pc; printf %s "$FT_RET")" "$_t_side"
# …and the control: change an INPUT and the key must change, or the check above passes on a
# cache that never re-keys for anything.
ft_set pc text="A completely different sentence, of a different length entirely, to re-key it."
FT_OUT=""; ft_clip_reset; _ft_beacon_rect pc; _ft_beacon_paint_callout pc 0
check "…while a changed input DOES re-key it (the check has teeth)" \
      "$(case "${FT_BEACON_PKEY[pc]:-}" in "$_t_key") echo stuck ;; *) echo rekeyed ;; esac)" "rekeyed"
ft_remove pc

note "a forced placement sees the world as it is WHEN ASKED"
# An ordering property, not a defect, and callers need it: _ft_beacon_rect grows a callout's
# target rect to include a RING drawn around that same target ("if the target is already ringed,
# the ring is its visible edge"), and a ring publishes its extent when it paints. Place the
# callout before the ring and it measures the un-ringed target; the ring then paints first in the
# real frame and the callout re-measures — a different key, so a second search. Measured on the
# callout tour's page 6: 12 misses of 15 without the ring placed first, 0 with it.
ft-beacon name=pring parent=papp variant=frame target=ptgt effect=none outset=1
# outset=0, as the tour's own step callout uses. With the default outset=1 the callout already
# measures the target plus a cell — which is exactly the rect the ring occupies — so the ring
# would enlarge nothing, and this would compare two identical keys and prove nothing.
ft-beacon name=pc2 parent=papp variant=callout target=ptgt calloutWidth=30 effect=none outset=0 \
          text="A sentence long enough to wrap and be placed somewhere."
ft_beacon_place pc2 >/dev/null 2>&1; _t_unringed=${FT_BEACON_PKEY[pc2]:-}
ft_beacon_place pring >/dev/null 2>&1        # …now the ring has published its extent
ft_beacon_place pc2 >/dev/null 2>&1; _t_ringed=${FT_BEACON_PKEY[pc2]:-}
check "placing the ring first changes what the callout measures" \
      "$(case "$_t_ringed" in "$_t_unringed") echo same ;; *) echo different ;; esac)" "different"
check "…and both keys are real (else 'different' is two empties)" \
      "$(( ${#_t_unringed} > 0 && ${#_t_ringed} > 0 ))" "1"
ft_remove pc2; ft_remove pring; ft_remove ptgt; ft_remove papp

summary
