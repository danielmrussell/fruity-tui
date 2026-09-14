#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tests/test-bigarrow.bash — the giant-arrow beacon and the easing that flies it.
#
#  Four things are gated, and they are the four things that can silently rot:
#
#  1. THE GLYPHS ARE ONE COLUMN WIDE. Every glyph the rasteriser can emit, at
#     every smoothing rung and in both orientations, measured with the
#     framework's own ft_display_width. A glyph that measures two columns
#     silently breaks every layout that assumed one, and this variant reaches
#     for a corner of Unicode most controls never touch.
#
#  2. THE EASING IS A REAL animation-timing-function. Endpoints land exactly on
#     0 and 1000, the CSS keywords parse, cubic-bezier() parses with and without
#     the spaces CSS allows, and — the property the whole cartoon rests on — an
#     -back curve's output LEAVES 0..1 while ease-out's does not.
#
#  3. IT POINTS THE RIGHT WAY AT THE RIGHT THING. All four sides honoured, the
#     tip within arrowGap of the target, and the arrow never drawn ON the thing
#     it is pointing at. Plus the bounce: retracted at phase 0, landed at the
#     last phase, and past the landing spot somewhere in between.
#
#  4. THE SCREEN. Everything above can pass while the app draws nothing — this
#     project has been bitten three times. So the last section drives the real
#     demo in a real pty and asserts on rendered cells: the arrow is there, it
#     is on the correct side of its target, and the SETTLED frame is stable
#     (which is also the check that a landed persist arrow has stopped
#     animating — a perpetual animation is this framework's definition of lag).
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256
FT_USE_UTF8=1
FT_COLS=100; FT_ROWS=30

# A host with a target that has room on every side, so a placement question has a real answer.
ft-form name=root width=100 height=30
    ft-button name=btn "Target"
end_ft_form
ft_layout root
FT_ROOT=root
_target_at() {                  # x y w h
    FT_ABSOLUTE_X[btn]=$1; FT_ABSOLUTE_Y[btn]=$2
    FT_MEASURED_WIDTH[btn]=$3; FT_MEASURED_HEIGHT[btn]=$4
}
_target_at 46 14 8 3

# ═══ 1. every glyph is one column ════════════════════════════════════════════
note "every glyph the rasteriser can emit measures ONE column"
# Not "the ones it happened to pick today" — the whole emit set, straight out of the tables the
# builder indexes, plus the two centred bars and the ASCII floor.
_all_glyphs=("${_FT_BIGARROW_LOWER[@]}" "${_FT_BIGARROW_LEFT[@]}"
             "$_FT_BIGARROW_BAR_H" "$_FT_BIGARROW_BAR_V" "#")
_bad=""
for _g in "${_all_glyphs[@]}"; do
    ft_display_width "$_g"
    (( FT_DISPLAY_WIDTH == 1 )) || _bad+="$_g "
done
check "the emit set is all one column"  "$_bad"  ""
check "…and it is not an empty set"     "$(( ${#_all_glyphs[@]} >= 20 ))"  "1"
# The control: if the probe had no teeth this would pass too.
ft_display_width "世"; check "the width probe has teeth (CJK reads 2)" "$FT_DISPLAY_WIDTH" "2"

# …and now the glyphs an ACTUAL arrow emits, at every rung and both orientations, read back
# out of the built art rather than out of the table.
_art_glyphs_ok() {              # name → 0 if every glyph of the built art is one column
    local n=$1 r c paint w g bad=0 i ch
    _ft_beacon_rect "$n"; _ft_bigarrow_geometry "$n" -1 || return 1
    set -- ${FT_BIGARROW_ART[$FT_BIGARROW_SHAPE_KEY]}
    while (( $# >= 5 )); do
        r=$1; c=$2; paint=$3; w=$4; g=$5; shift 5
        # the segment's glyph count must equal the width it claims, or ft_print_at_width lies to the clip
        (( ${#g} == w )) || bad=1
        for (( i=0; i<${#g}; i++ )); do
            ch=${g:i:1}; ft_display_width "$ch"
            (( FT_DISPLAY_WIDTH == 1 )) || bad=1
        done
    done
    return $bad
}
ft-beacon name=ga variant=bigarrow target=btn
# IN THE TREE FOR THE CASCADE, BY HAND. `parent=root` on the constructor would attach it
# and reflow, and a reflow recomputes btn's absolutes — which is exactly what _target_at
# is faking. ft_style's inheritance walk reads FT_PARENT, so this is all it needs.
FT_PARENT[ga]=root
for _sm in eighths halves solid; do
    for _pl in left right above below; do
        ft-modify ga smoothing="$_sm" place="$_pl"
        ok "art is one-column: smoothing=$_sm place=$_pl" _art_glyphs_ok ga
    done
done
# …and every AUTHORED SPRITE, at every rung, in all four directions — asked of the SPRITE
# SHEET rather than of the placer, because a 30-row screen has no room for the tall sizes and
# "suppressed" is the right answer there, not a failure. The sheet is hand-typed text: one
# mistyped character is a glyph the framework will happily paint two columns wide, and every
# layout downstream assumed one.
_sprite_glyphs_ok() {           # size dir sub → 0 if every glyph of the built art is one column
    local key="$1|$2|$3|1" r c paint w g bad=0 i ch
    _ft_bigarrow_span "$1" "$2" "$3" || return 1
    set -- ${FT_BIGARROW_ART[$key]}
    while (( $# >= 5 )); do
        r=$1; c=$2; paint=$3; w=$4; g=$5; shift 5
        # the segment's glyph count must equal the width it claims, or ft_print_at_width lies to the clip
        (( ${#g} == w )) || bad=1
        for (( i=0; i<${#g}; i++ )); do
            ch=${g:i:1}; ft_display_width "$ch"
            (( FT_DISPLAY_WIDTH == 1 )) || bad=1
        done
    done
    return $bad
}
for _sub in 8 2 1; do
    for _sz in "${_FT_BIGARROW_SIZES[@]}"; do
        for _d in right left down up; do
            ok "sprite is one-column: $_sz/$_d/sub=$_sub" _sprite_glyphs_ok "$_sz" "$_d" "$_sub"
        done
    done
done
ft-modify ga smoothing=eighths place=auto

# ═══ 2. the easing ═══════════════════════════════════════════════════════════
note "animation-timing-function, spelled the way CSS spells it"
ft_ease_points linear;      check "linear"       "$FT_RET" "0 0 1000 1000"
ft_ease_points ease-out;    check "ease-out"     "$FT_RET" "0 0 580 1000"
ft_ease_points ease-in-out; check "ease-in-out"  "$FT_RET" "420 0 580 1000"
ft_ease_points ease-out-back
check "ease-out-back is the canonical curve" "$FT_RET" "340 1560 640 1000"
ft_ease_points "cubic-bezier(0.34,1.56,0.64,1)"
check "cubic-bezier() parses"                "$FT_RET" "340 1560 640 1000"
ft_ease_points "cubic-bezier(0.34, 1.56, 0.64, 1)"
check "…and with the spaces CSS allows"      "$FT_RET" "340 1560 640 1000"
ft_ease_points "cubic-bezier(0.36,-0.28,0.66,-0.06)"
check "…and with negative control points"    "$FT_RET" "360 -280 660 -60"
no "an unparseable spec reports failure" ft_ease_points "wobble"
ft_ease_points "wobble"; check "…and falls back to linear" "$FT_RET" "0 0 1000 1000"
# A fraction like .08 must not be read as octal — `08` in (( )) is a hard error, and a bash
# error goes to STDERR, which in this framework is the alt screen (run-all.bash fails on it).
ft_ease_points "cubic-bezier(0.08,0.09,1,1)"
check "a leading-zero fraction is decimal, not octal" "$FT_RET" "80 90 1000 1000"

ft_ease ease-out-back 0;    check "phase 0 is exactly 0"       "$FT_RET" "0"
ft_ease ease-out-back 1000; check "phase 1 is exactly 1000"    "$FT_RET" "1000"
ft_ease linear 500;         check "linear is the identity"     "$FT_RET" "500"
# THE PROPERTY THE CARTOON RESTS ON: an -back curve leaves 0..1 and ease-out does not.
_peak=0; _peak_out=0
for (( _p=0; _p<=1000; _p+=25 )); do
    ft_ease ease-out-back "$_p"; (( FT_RET > _peak )) && _peak=$FT_RET
    ft_ease ease-out "$_p";      (( FT_RET > _peak_out )) && _peak_out=$FT_RET
done
check "ease-out-back overshoots past the target" "$(( _peak > 1000 ))" "1"
check "…by about a tenth (peak 1097)"            "$_peak" "1097"
check "ease-out never overshoots"                "$(( _peak_out <= 1000 ))" "1"

ft_ease_table ease-out-back 20; _tbl=$FT_RET
_t=($_tbl)
check "the table has one entry per frame"  "${#_t[@]}" "20"
check "…starting at 0"                     "${_t[0]}" "0"
check "…and landing exactly on 1000"       "${_t[19]}" "1000"
ft_ease_table linear 2;  check "a two-frame table degenerates cleanly" "$FT_RET" "0 1000"
ft_ease_table linear 1;  check "…and a one-frame table is just the end" "$FT_RET" "1000"

# ═══ 3. geometry, placement and the bounce ═══════════════════════════════════
note "the arrow points the right way at the right thing"
_geo() { ft_clip_reset; _ft_beacon_rect ga; _ft_bigarrow_geometry ga "${1:--1}"; }
_rung_index() {                 # size name -> FT_RET = its place on the ladder, -1 if unknown
    local i
    for i in "${!_FT_BIGARROW_SIZES[@]}"; do
        [[ "${_FT_BIGARROW_SIZES[i]}" == "$1" ]] && { FT_RET=$i; return 0; }
    done
    FT_RET=-1; return 1
}
for _case in "left right" "right left" "above down" "below up"; do
    set -- $_case
    ft-modify ga place="$1"
    if _geo; then check "place=$1 makes it point $2" "$FT_BIGARROW_DIRECTION" "$2"
    else          check "place=$1 makes it point $2" "suppressed" "$2"; fi
done
ft-modify ga place=auto
_geo
check "auto picks a horizontal axis on a wide screen" \
      "$(case $FT_BIGARROW_DIRECTION in left|right) echo yes ;; *) echo no ;; esac)" "yes"

# THE TIP LANDS ONE arrowGap CLEAR OF THE TARGET, and the body never touches it. An arrow drawn
# ON the thing it points at is the one failure that cannot be argued as a matter of taste.
ft-modify ga place=left arrowGap=1
_geo
_tip=$(( FT_BIGARROW_LEFT + FT_BIGARROW_COLUMNS - 1 ))
check "pointing right: the tip is 1 clear of the target" "$(( FT_BEACON_RECT_LEFT - _tip ))" "2"
check "…and the whole arrow is left of the target"       "$(( _tip < FT_BEACON_RECT_LEFT ))" "1"
ft-modify ga arrowGap=3; _geo
_tip=$(( FT_BIGARROW_LEFT + FT_BIGARROW_COLUMNS - 1 ))
check "arrowGap=3 opens the gap"                         "$(( FT_BEACON_RECT_LEFT - _tip ))" "4"
ft-modify ga arrowGap=1

ft-modify ga place=above; _geo
check "pointing down: the tip is 1 clear above"          "$(( FT_BEACON_RECT_TOP - (FT_BIGARROW_TOP + FT_BIGARROW_ROWS - 1) ))" "2"
ft-modify ga place=below; _geo
check "pointing up: the tip is 1 clear below"            "$(( FT_BIGARROW_TOP - FT_BEACON_RECT_BOTTOM ))" "2"
ft-modify ga place=auto

note "it takes the largest AUTHORED size that fits, and refuses to draw when none does"
# THE SHAPE IS NOT FITTED TO THE ROOM ANY MORE, and this is the assertion that says so. It used
# to solve a shape per length — a different arrow in every window, which is the whole reason the
# sprite sheet exists — so what is checked now is that a placement lands on a RUNG of the ladder
# and that the drawn footprint is that rung's authored footprint to the cell.
ft-modify ga place=left
_target_at 46 14 8 3; _geo; _wide=$FT_BIGARROW_SIZE
# 34, not 20: at 20 there is no room for the SMALLEST rung either, and "suppressed" is a
# different lesson (the one two assertions down). 34 leaves 32 columns — medium fits, large
# does not — so this is the ladder stepping down rather than the arrow giving up.
_target_at 34 14 8 3; _geo; _narrow=$FT_BIGARROW_SIZE
_rung_index "$_narrow"; _ni=$FT_RET
_rung_index "$_wide";   _wi=$FT_RET
check "a target with less room drops a rung"        "$(( _ni < _wi ))" "1"
_target_at  3 14 8 3
if _geo; then check "…and no room at all suppresses that side" "drew $FT_BIGARROW_SIZE dir=$FT_BIGARROW_DIRECTION" "suppressed"
else         check "…and no room at all suppresses that side" "suppressed" "suppressed"; fi
_target_at 46 14 8 3
ft-modify ga place=auto
_geo; check "the chosen size is a rung of the ladder" \
      "$(case " ${_FT_BIGARROW_SIZES[*]} " in *" $FT_BIGARROW_SIZE "*) echo yes ;; *) echo no ;; esac)" "yes"

note "size names a shape, and the shape is EXACTLY as authored"
# The footprint the placer publishes must be the sprite's own, cell for cell — if the drawn size
# and the authored size can ever disagree, something is fitting again.
ft-modify ga place=left
for _sz in small medium large; do
    ft-modify ga size="$_sz"
    _ft_bigarrow_span "$_sz" right 8; _span=$FT_RET
    if _geo; then
        check "size=$_sz draws its authored footprint" \
              "$FT_BIGARROW_COLUMNS $FT_BIGARROW_ROWS" "$_span"
        check "…and reports that rung"  "$FT_BIGARROW_SIZE" "$_sz"
    else
        check "size=$_sz draws its authored footprint" "suppressed" "$_span"
    fi
done
# …and a named size that does NOT fit is SUPPRESSED rather than quietly swapped for a smaller
# one. Substituting is the behaviour that produced "a different arrow in every window".
ft-modify ga size=x-large
_target_at 34 14 8 3
if _geo; then check "a named size that does not fit is suppressed, not substituted" "drew $FT_BIGARROW_SIZE" "suppressed"
else         check "a named size that does not fit is suppressed, not substituted" "suppressed" "suppressed"; fi
_target_at 46 14 8 3
# …while UNSET keeps the ladder, so the same screen still gets an arrow.
ft_remove_attribute ga size
_target_at 34 14 8 3
if _geo; then check "…but unset falls down the ladder instead" "drew" "drew"
else         check "…but unset falls down the ladder instead" "suppressed" "drew"; fi
_target_at 46 14 8 3
# CSS spells the ladder with seven keywords and this one has four rungs; the two below `small`
# and the one above `x-large` map onto the ends rather than being ignored, and a value that is
# not a keyword at all falls back to fitting rather than to a guess.
for _pair in "xx-small small" "x-small small" "medium medium" "xx-large x-large" "wobble "; do
    set -- $_pair
    ft-modify ga size="$1"
    _ft_bigarrow_size ga
    check "size=$1 → ${2:-fit}" "$FT_RET" "${2:-}"
done
ft_remove_attribute ga size
_ft_bigarrow_size ga; check "unset means fit-the-largest" "$FT_RET" ""
# …and it is NOT a class default, or `beacon { size: large }` could never win.
check "size is not baked into the class" \
      "$(case " ${FT_CLASS_DEFAULTS[beacon]} " in *" size="*) echo "baked in" ;; *) echo free ;; esac)" \
      "free"
ft_stylesheet name=ft-test-arrowsize style="beacon { size: large }"
_ft_bigarrow_size ga; check "…so a stylesheet rule reaches it" "$FT_RET" "large"
ft_stylesheet name=ft-test-arrowsize style=""
ft-modify ga place=left

note "the authored sprites are exact: symmetric, and one size on both axes"
# A hand-drawn sprite is a hand-TYPED sprite. Left/right and up/down are mirrors of one authored
# half, so an asymmetric result means the mirror is wrong; and the two AXES of one size have to
# match in visual units or `size: large` would mean two different things depending on which
# way the placer turned the arrow.
for _sz in "${_FT_BIGARROW_SIZES[@]}"; do
    _ft_bigarrow_span "$_sz" right 8; _h=$FT_RET
    _ft_bigarrow_span "$_sz" left  8; _hl=$FT_RET
    _ft_bigarrow_span "$_sz" down  8; _v=$FT_RET
    _ft_bigarrow_span "$_sz" up    8; _vu=$FT_RET
    check "$_sz: right and left are the same footprint" "$_h" "$_hl"
    check "$_sz: down and up are the same footprint"    "$_v" "$_vu"
    set -- $_h; _hcols=$1; _hrows=$2
    set -- $_v; _vcols=$1; _vrows=$2
    check "$_sz: both axes are the same visual length" \
          "$_hcols" "$(( _vrows * FT_BIGARROW_ASPECT ))"
    # …ACROSS, to within one visual unit, and that unit is forced by two parities that cannot
    # both be had: a horizontal arrow needs an EVEN row count so its axis lands on a cell
    # boundary and the tip can converge, a vertical one needs an ODD column count so its apex
    # is a single centred cell. One column in seventeen, against a blunt tip on one axis.
    _t_dh=$(( _hrows * FT_BIGARROW_ASPECT - _vcols ))
    (( _t_dh < 0 )) && _t_dh=$(( -_t_dh ))
    check "$_sz: …and the same visual thickness, ±1 (parity)" "$(( _t_dh <= 1 ))" "1"
    # EVEN, and the tip is why. With an odd row count the axis falls in the MIDDLE of a cell,
    # so the converging tip is a run touching neither edge of it — the one case no font here
    # has a glyph for — and it came out as a mid-height bar butted against a full cell, which
    # is what "none of them look pointy" was looking at. Even puts the axis on a BOUNDARY.
    check "$_sz: an even row count lets the tip converge" "$(( _hrows % 2 ))" "0"
done
# …and each vertical sprite is its own mirror, left to right, which is what puts the tip on the
# axis instead of one cell off it. ▌ and ▐ swap under that reflection; nothing else moves.
_sprite_symmetric() {           # size → 0 if every authored row reads the same backwards
    local rows=${FT_BIGARROW_SPRITE[$1|v]} line rev i n
    while IFS= read -r line; do
        rev=""; n=${#line}
        for (( i=n-1; i>=0; i-- )); do
            case "${line:i:1}" in
                "▌") rev+="▐" ;; "▐") rev+="▌" ;;      # the half blocks…
                "▏") rev+="▕" ;; "▕") rev+="▏" ;;      # …and the eighths the tip is drawn with
                *)   rev+=${line:i:1} ;;
            esac
        done
        [[ "$rev" == "$line" ]] || return 1
    done <<< "$rows"
    return 0
}
for _sz in "${_FT_BIGARROW_SIZES[@]}"; do
    ok "$_sz: the vertical sprite is left-right symmetric" _sprite_symmetric "$_sz"
done
# …and the horizontal ones are authored as their top half, so the ASSEMBLED art must come back
# symmetric about the centre row — the mirror is code, and code is what gets this wrong.
_art_symmetric() {              # size → 0 if row r and row rows-1-r cover the same columns
    local key="$1|right|8|1" spans r lo hi
    _ft_bigarrow_span "$1" right 8 || return 1
    declare -A _lo=() _hi=()
    set -- ${FT_BIGARROW_ROWSPAN[$key]}
    while (( $# >= 3 )); do _lo[$1]=$2; _hi[$1]=$3; shift 3; done
    local span=${FT_BIGARROW_SPAN[$key]} rows=${span##* } i
    for (( i=0; i<rows; i++ )); do
        [[ "${_lo[$i]:-}" == "${_lo[$((rows-1-i))]:-}" ]] || return 1
        [[ "${_hi[$i]:-}" == "${_hi[$((rows-1-i))]:-}" ]] || return 1
    done
    return 0
}
for _sz in "${_FT_BIGARROW_SIZES[@]}"; do
    ok "$_sz: the assembled horizontal art is top-bottom symmetric" _art_symmetric "$_sz"
done

note "the ink, read with the reverse APPLIED: mirrored exactly, and converging to a point"
# A GLYPH DUMP CANNOT BE READ AS A PICTURE OF THIS VARIANT, and that cost a review round. An
# upper-anchored cell is drawn as a LOWER block painted fg/bg REVERSED, so a row of `▁` sitting
# under a row of `▇` is a mirror PAIR and reads, to anyone looking at the characters, as violent
# asymmetry — reported as "the bottom of the arrow is not correctly mirroring the top ... torn
# up". It was not torn up. What follows asks the question in INK: for every cell, how many
# eighths are actually inked and from which edge, with the reverse applied. That is the only
# form of this shape anyone can honestly judge, and it is now a gate rather than a probe.
_ink_of() {                     # glyph paintmode → _INK_N, _INK_FROM (b|t|l|r|F|c|.)
    local g=$1 pm=$2 n=0 fam="" i
    for (( i=1; i<=8; i++ )); do
        [[ "$g" == "${_FT_BIGARROW_LOWER[i]}" ]] && { n=$i; fam=lower; break; }
        [[ "$g" == "${_FT_BIGARROW_LEFT[i]}"  ]] && { n=$i; fam=left;  break; }
    done
    [[ "$g" == "━" || "$g" == "┃" ]] && { n=2; fam=centred; }
    [[ "$g" == "#" ]] && { n=8; fam=lower; }
    # modes 4/5 are the hairline: the glyph is the RIM sliver and the rest of the cell is fill,
    # so the whole cell carries arrow either way.
    if (( pm >= 4 )); then _INK_N=8; _INK_FROM=F; return; fi
    if [[ "$fam" == centred ]]; then _INK_N=$n; _INK_FROM=c; return; fi
    if (( n >= 8 )); then _INK_N=8; _INK_FROM=F; return; fi
    if (( pm == 1 || pm == 3 )); then           # reversed: the cell shows the COMPLEMENT
        _INK_N=$(( 8 - n )); [[ "$fam" == lower ]] && _INK_FROM=t || _INK_FROM=r
    else
        _INK_N=$n;           [[ "$fam" == lower ]] && _INK_FROM=b || _INK_FROM=l
    fi
    (( _INK_N == 0 )) && _INK_FROM=.
    (( _INK_N == 8 )) && _INK_FROM=F
}
# → _INK_COVER / _INK_ANCHOR, one entry per cell, row-major; _INK_COLS / _INK_ROWS
_ink_map() {                    # size dir → 0, or 1 if there is no such sprite
    local key="$1|$2|8|1" i
    _ft_bigarrow_span "$1" "$2" 8 || return 1
    local span=${FT_BIGARROW_SPAN[$key]}
    _INK_COLS=${span%% *}; _INK_ROWS=${span##* }
    _INK_COVER=(); _INK_ANCHOR=()
    for (( i=0; i < _INK_ROWS * _INK_COLS; i++ )); do _INK_COVER[i]=0; _INK_ANCHOR[i]="."; done
    local r c pm w g j
    set -- ${FT_BIGARROW_ART[$key]}
    while (( $# >= 5 )); do
        r=$1; c=$2; pm=$3; w=$4; g=$5; shift 5
        for (( j=0; j<w; j++ )); do
            i=$(( r * _INK_COLS + c + j ))
            _ink_of "${g:j:1}" "$pm"
            _INK_COVER[i]=$_INK_N; _INK_ANCHOR[i]=$_INK_FROM
        done
    done
    return 0
}
# THE MIRROR, IN INK. Row r and row rows-1-r must carry the SAME number of eighths in every
# column, anchored to the OPPOSITE edge. Anything else is the reported "torn up", for real.
_mirror_defects() {             # size dir → FT_RET = differing cells (and pairs in _MIRROR_PAIRS)
    _ink_map "$1" "$2" || { FT_RET=-1; return 1; }
    local horiz=0; [[ "$2" == right || "$2" == left ]] && horiz=1
    local bad=0 pairs=0 r c ia ib opp
    if (( horiz )); then
        for (( r=0; r < _INK_ROWS/2; r++ )); do for (( c=0; c < _INK_COLS; c++ )); do
            ia=$(( r * _INK_COLS + c )); ib=$(( (_INK_ROWS-1-r) * _INK_COLS + c )); (( pairs++ ))
            case ${_INK_ANCHOR[ia]} in b) opp=t ;; t) opp=b ;; *) opp=${_INK_ANCHOR[ia]} ;; esac
            (( _INK_COVER[ia] != _INK_COVER[ib] )) && { (( bad++ )); continue; }
            [[ "${_INK_ANCHOR[ib]}" == "$opp" ]] || (( bad++ ))
        done; done
    else
        for (( r=0; r < _INK_ROWS; r++ )); do for (( c=0; c < _INK_COLS/2; c++ )); do
            ia=$(( r * _INK_COLS + c )); ib=$(( r * _INK_COLS + _INK_COLS-1-c )); (( pairs++ ))
            case ${_INK_ANCHOR[ia]} in l) opp=r ;; r) opp=l ;; *) opp=${_INK_ANCHOR[ia]} ;; esac
            (( _INK_COVER[ia] != _INK_COVER[ib] )) && { (( bad++ )); continue; }
            [[ "${_INK_ANCHOR[ib]}" == "$opp" ]] || (( bad++ ))
        done; done
    fi
    _MIRROR_PAIRS=$pairs; FT_RET=$bad
    return 0
}
_t_pairs=0
for _sz in "${_FT_BIGARROW_SIZES[@]}"; do
    for _d in right left down up; do
        _mirror_defects "$_sz" "$_d"
        check "$_sz/$_d mirrors EXACTLY, in ink" "$FT_RET" "0"
        (( _t_pairs += _MIRROR_PAIRS ))
    done
done
# …and the anti-vacuity check the assertion above needs, because "0 differing cells in 0 pairs"
# is what a broken map returns.
check "…and that compared a real number of cells" "$(( _t_pairs > 900 ))" "1"
# The teeth: mirror one sprite by hand into something that is NOT its mirror and demand a
# complaint. Without this the whole section passes on any map that always answers zero.
_ink_map medium right
_INK_COVER[0]=$(( _INK_COVER[0] == 8 ? 4 : 8 ))
_t_bad=0
for (( _t_i=0; _t_i < _INK_COLS; _t_i++ )); do
    (( _INK_COVER[_t_i] != _INK_COVER[(_INK_ROWS-1)*_INK_COLS + _t_i] )) && (( _t_bad++ ))
done
check "…and the comparison has teeth (a hand-broken cell is seen)" "$_t_bad" "1"

note "the tip converges to a point"
# "None of them look pointy at all." It was true, and it was structural: with an ODD row count
# the arrow's axis falls in the MIDDLE of a cell, so the converging tip is a run touching
# neither edge of that cell — the one case no font here has a glyph for (§6c) — and it came out
# as a mid-height `━` bar butted against a full cell. Cross-section 8 eighths, then 2. An EVEN
# count puts the axis on a cell BOUNDARY: the tip is two anchored runs, one eighth above it and
# one below, and every step down to it is the authored slope.
_tip_profile() {                # size dir → FT_RET = cross-sections from the head base to the tip
    _ink_map "$1" "$2" || { FT_RET=""; return 1; }
    local horiz=0; [[ "$1" == "" ]] && horiz=0
    [[ "$2" == right || "$2" == left ]] && horiz=1
    local -a total=()
    local m n r c i major
    if (( horiz )); then major=$_INK_COLS; else major=$_INK_ROWS; fi
    for (( m=0; m<major; m++ )); do
        n=0
        if (( horiz )); then
            for (( r=0; r < _INK_ROWS; r++ )); do (( n += _INK_COVER[r * _INK_COLS + m] )); done
        else
            for (( c=0; c < _INK_COLS; c++ )); do (( n += _INK_COVER[m * _INK_COLS + c] )); done
        fi
        total[m]=$n
    done
    # the head base is the LAST position carrying the maximum; the tip is the far end
    local best=0 basei=0
    for (( m=0; m<major; m++ )); do (( total[m] >= best )) && { best=${total[m]}; basei=$m; }; done
    local out=""
    if [[ "$2" == right || "$2" == down ]]; then
        for (( m=basei; m<major; m++ )); do out+="${total[m]} "; done
    else
        # left/up point the other way, so the walk to the tip runs backwards
        local first=0
        for (( m=major-1; m>=0; m-- )); do (( total[m] >= best )) && { first=$m; break; }; done
        for (( m=first; m>=0; m-- )); do out+="${total[m]} "; done
    fi
    FT_RET=${out% }
    return 0
}
for _sz in "${_FT_BIGARROW_SIZES[@]}"; do
    for _d in right left down up; do
        _tip_profile "$_sz" "$_d"
        _t_prof=($FT_RET)
        _t_n=${#_t_prof[@]}
        _t_last=${_t_prof[_t_n-1]}
        # THE SHARPEST APEX EACH AXIS CAN HAVE, and they differ because the resolution does.
        # A horizontal arrow has eighth resolution ACROSS itself, so its tip is two eighths —
        # one above the axis and one below — and each step down to it is the authored slope,
        # two eighths per side. A vertical arrow has eighth resolution across itself too, but
        # NONE along its length, so its apex row cannot taper within itself: the sharpest
        # honest apex is one whole centred cell, reached in the staircase's own step of one
        # cell per side. Drawing a quarter-cell sliver there instead was measured and looked
        # WORSE — a spike on the end of a triangle, because the step into it was 14 where every
        # other step is 16.
        if [[ "$_d" == right || "$_d" == left ]]; then _t_tipmax=2;  _t_stepmax=4
        else                                           _t_tipmax=8;  _t_stepmax=16; fi
        check "$_sz/$_d ends in a point (≤$_t_tipmax eighths)" "$(( _t_last <= _t_tipmax ))" "1"
        _t_step=0; _t_up=0
        for (( _t_i=1; _t_i < _t_n; _t_i++ )); do
            (( _t_prof[_t_i] > _t_prof[_t_i-1] )) && _t_up=1
            _t_d=$(( _t_prof[_t_i-1] - _t_prof[_t_i] ))
            (( _t_d > _t_step )) && _t_step=$_t_d
        done
        check "$_sz/$_d narrows all the way to it"   "$_t_up"   "0"
        check "…in steps of at most $_t_stepmax eighths" "$(( _t_step <= _t_stepmax ))" "1"
    done
done

note "a geometry property that is not a number never reaches (( ))"
# `(( ${arr[$(cmd)]} ))` EXECUTES. Both of these are app-supplied and both land in arithmetic,
# so each must fall back to its default rather than be evaluated. The canary file is the proof:
# if a subscript ran, it exists.
_canary="$XDG_STATE_HOME/bigarrow-canary"
mkdir -p "$XDG_STATE_HOME"; rm -f "$_canary"
ft-modify ga place=left
for _p in arrowGap bounceTravel; do
    ft-modify ga "$_p"='a[$(touch '"$_canary"')]'
    if _geo -1; then check "$_p= garbage still draws (default taken)" "$(( FT_BIGARROW_LENGTH > 0 ))" "1"
    else            check "$_p= garbage still draws (default taken)" "suppressed" "1"; fi
    ft_remove_attribute ga "$_p"
done
check "…and nothing was executed" "$([[ -e "$_canary" ]] && echo EXECUTED || echo clean)" "clean"
ft-modify ga arrowGap=1 bounceTravel=auto

note "the bounce runs along the arrow's own axis"
ft-modify ga place=left
_geo -1;                 _landed=$FT_BIGARROW_LEFT
_geo 0;                  _launch=$FT_BIGARROW_LEFT
check "at phase 0 it is retracted, back along its axis" "$(( _launch < _landed ))" "1"
check "…by its own length (bounceTravel=auto)"          "$(( _landed - _launch ))" "$FT_BIGARROW_LENGTH"
_geo 19; check "at the last frame it has landed"        "$FT_BIGARROW_LEFT" "$_landed"
# …and somewhere in the middle it is PAST the landing spot. That is the overshoot, and it is
# the difference between a bounce and a slide.
_past=0
for (( _p=0; _p<20; _p++ )); do _geo "$_p"; (( FT_BIGARROW_LEFT > _landed )) && _past=1; done
check "it overshoots past the landing spot"             "$_past" "1"
# the control: with a non-overshooting curve it must never pass the landing spot
ft-modify ga animationTimingFunction=ease-out
_ft_bigarrow_arm ga
_past=0
for (( _p=0; _p<20; _p++ )); do _geo "$_p"; (( FT_BIGARROW_LEFT > _landed )) && _past=1; done
check "…and with ease-out it never does"                "$_past" "0"
ft-modify ga animationTimingFunction=ease-out-back
_ft_bigarrow_arm ga

note "the timing function resolves through the CASCADE, not just the call site"
check "it is NOT a class default (or a stylesheet could never win)" \
      "$(case " ${FT_CLASS_DEFAULTS[beacon]} " in *" animationTimingFunction="*) echo "baked in" ;; *) echo free ;; esac)" \
      "free"
ft_remove_attribute ga animationTimingFunction
_ft_bigarrow_styled ga animationTimingFunction "$FT_BIGARROW_EASING"
check "…and unset, it falls back to the code constant" "$FT_RET" "$FT_BIGARROW_EASING"

note "its colour comes through the CASCADE, with no constant baked in"
# WHAT THIS SECTION EXISTS TO STOP HAPPENING AGAIN. The arrow's ink used to come from a
# beacon-private role lookup that consulted the cascade for one thing only — a `beacon::arrow`
# pseudo-element — so `color=196` on the instance, `#id { color: 82 }`, `.class { color: 201 }`
# and `color: crimson` were ALL silently ignored: four of the six things a user reaches for
# first. It now resolves through _ft_color_override, the same call every other control paints
# through, and `::arrow` is gone rather than layered under it — with `color` working, a
# pseudo-element naming the whole element is a second word for the same thing.
_paint_bytes() {                # → FT_RET = what one paint emits
    FT_OUT=""; ft_clip_reset; _ft_beacon_rect ga; _ft_beacon_paint_bigarrow ga -1
    FT_RET=$FT_OUT
}
_fgs() {                        # bytes → FT_RET = the distinct foreground colours in them, sorted
    local b=$1 out="" tok
    while [[ "$b" == *$'\e['* ]]; do
        b=${b#*$'\e['}; tok=${b%%m*}
        case "$tok" in *38\;5\;*|*38\;2\;*) out+="${tok##*38;}"$'\n' ;; esac
    done
    FT_RET=$(printf '%s' "$out" | sort -u | tr '\n' ' ')
}
_has_fg() {                     # bytes colour → 0 if that colour is one of the foregrounds
    ft_color_sgr "$2" 38; local want=$FT_RET
    [[ "$1" == *"$want"* ]]
}
ft-modify ga place=left size=medium
_paint_bytes; _plain=$FT_RET
check "a paint emits something"                 "$(( ${#_plain} > 100 ))" "1"
# the theme's ramp — the same --beacon-N / --locator-N triple every other variant reads — is
# what `color` resolves to when NOTHING declares one, which is why an unstyled arrow is
# unchanged by all of this.
ft-modify ga --beacon-1=196; _paint_bytes; _c1=$FT_RET
ft-modify ga --beacon-1=46;  _paint_bytes; _c2=$FT_RET
check "--beacon-1 changes what is painted" \
      "$(case "$_c1" in "$_c2") echo same ;; *) echo different ;; esac)" "different"
ft_remove_attribute ga --beacon-1

# ── the six ways a user would actually spell it ─────────────────────────────
ft-modify ga color=196
_paint_bytes; ok  "color= as a property reaches the ink"        _has_fg "$FT_RET" 196
ft_remove_attribute ga color
ft_stylesheet name=ft-test-arrowcss style='#ga { color: 82 }'
_paint_bytes; ok  "#id { color } reaches the ink"               _has_fg "$FT_RET" 82
ft_stylesheet name=ft-test-arrowcss style=''
ft-modify ga class=loud
ft_stylesheet name=ft-test-arrowcss style='.loud { color: 201 }'
_paint_bytes; ok  ".class { color } reaches the ink"            _has_fg "$FT_RET" 201
ft_stylesheet name=ft-test-arrowcss style=''
ft-modify ga class=
ft_stylesheet name=ft-test-arrowcss style='#ga { color: crimson }'
_paint_bytes; ok  "a CSS colour NAME resolves"                  _has_fg "$FT_RET" crimson
ft_stylesheet name=ft-test-arrowcss style=''
# INHERITED, which is the one that needs the cascade rather than the property: the value is on
# an ancestor and lives only in a stylesheet, so nothing on the beacon itself carries it.
ft_stylesheet name=ft-test-arrowcss style='#root { color: 45 }'
_paint_bytes; ok  "…and an ancestor's colour is INHERITED"      _has_fg "$FT_RET" 45
ft_stylesheet name=ft-test-arrowcss style=''
ft_stylesheet name=ft-test-arrowcss style='#root { --ink: 129 } #ga { color: var(--ink) }'
_paint_bytes; ok  "…and var(--custom) resolves"                 _has_fg "$FT_RET" 129
ft_stylesheet name=ft-test-arrowcss style=''
# background-color was the ONE that already worked; it must keep working.
ft_stylesheet name=ft-test-arrowcss style='#ga { background-color: 53 }'
ft_color_sgr 53 48; _wantbg=$FT_RET
_paint_bytes
check "background-color still reaches the cells" \
      "$(case "$FT_RET" in *"$_wantbg"*) echo yes ;; *) echo no ;; esac)" "yes"
ft_stylesheet name=ft-test-arrowcss style=''
# …and the ramp is a DEFAULT, not an override of one: a declared colour holds on every frame of
# the flight too, rather than the pulse cycling over the top of it for the first 560ms.
ft-modify ga color=196 effect=pulse
FT_OUT=""; ft_clip_reset; _ft_beacon_rect ga; _ft_beacon_paint_bigarrow ga 3
ok "a declared colour holds while the arrow is still flying" _has_fg "$FT_OUT" 196
ft_remove_attribute ga color

# …and `animation:` came along with the cascade, which brought a collision with it. The CSS
# colour engine arms its OWN loop on the same control, and a landed arrow read those ticks as
# positions on its flight path and flew in again, forever (measured: column -34, -25, -18 on
# successive ticks). The loop's owner is recorded, so the painter asks.
ft_stylesheet name=ft-test-arrowanim style='@keyframes ftglow { from,to { color: crimson } 50% { color: gold } }
                                            #ga { animation: ftglow }'
ft_anim_stop ga; unset "FT_ANIM_PHASE[ga]"
FT_OUT=""; ft_clip_reset; _ft_beacon_rect ga; _ft_draw_beacon ga
_anim_landed=${FT_BIGARROW_AT[ga]:-}
check "a CSS animation on a beacon arms the colour loop" "${FT_CSS_ANIMATION_ON[ga]:-off}" "1"
_anim_moved=0
for _p in 1 2 3; do
    FT_ANIM_PHASE[ga]=$_p
    FT_OUT=""; ft_clip_reset; _ft_beacon_rect ga; _ft_draw_beacon ga
    [[ "${FT_BIGARROW_AT[ga]:-}" == "$_anim_landed" ]] || _anim_moved=1
done
check "…and a landed arrow does NOT re-fly on its ticks" "$_anim_moved" "0"
_ft_effective_bg ga; _anim_g=$FT_RET
FT_ANIM_PHASE[ga]=0; _ft_bigarrow_color ga -1 "$_anim_g"; _anim_c0=$FT_RET
FT_ANIM_PHASE[ga]=6; _ft_bigarrow_color ga -1 "$_anim_g"; _anim_c6=$FT_RET
check "…while its colour really does cycle" \
      "$(case "$_anim_c0" in "$_anim_c6") echo frozen ;; *) echo cycling ;; esac)" "cycling"
ft_stylesheet name=ft-test-arrowanim style=''
_ft_css_anim_disarm ga 2>/dev/null; ft_anim_stop ga; unset "FT_ANIM_PHASE[ga]"

note "an arrow that costs more than it is worth is not drawn"
# A RUNG CANNOT SHRINK, so without a floor the least-bad candidate wins however bad it is — and
# on a dense stage that is an arrow lying across a control. The old placer could always shrink
# its way out, which is the deforming the sprite sheet replaced, so this floor arrived with it.
# Bury the whole left side of the screen under a control and demand it refuses that side.
ft-modify ga place=left size=small
_geo; check "with the side clear it draws"     "$(( FT_BIGARROW_COLUMNS > 0 ))" "1"
ft-button name=blocker "x" parent=root
# BOTH RECTS ARE FAKED AFTER THE CONSTRUCTION, and that ordering is the whole trick: adding or
# removing a control reflows, and a reflow recomputes btn's absolutes — which is what every
# _target_at in this file is pretending to control.
_target_at 46 14 8 3
FT_ABSOLUTE_X[blocker]=0; FT_ABSOLUTE_Y[blocker]=10
FT_MEASURED_WIDTH[blocker]=44; FT_MEASURED_HEIGHT[blocker]=9
FT_BIGARROW_PKEY[ga]=""                       # the obstacle is faked, so the cache cannot see it
if _geo; then check "…and buried under a control it does not" "drew at $FT_BIGARROW_LEFT" "suppressed"
else        check "…and buried under a control it does not" "suppressed" "suppressed"; fi
ft_remove blocker
_target_at 46 14 8 3; FT_BIGARROW_PKEY[ga]=""
ft_remove_attribute ga size

# The REVERSED cells are how the arrow gets an anchor Unicode never shipped — they must
# actually be emitted, or every arrow is silently half-resolution.
_paint_bytes
check "reversed cells are emitted (the missing eighth family)" \
      "$(case "$FT_RET" in *$'\e[7m'*) echo yes ;; *) echo no ;; esac)" "yes"
ft-modify ga smoothing=solid; _paint_bytes
check "…and solid, having no partial cells, emits none" \
      "$(case "$FT_RET" in *$'\e[7m'*) echo yes ;; *) echo no ;; esac)" "no"
ft-modify ga smoothing=eighths

note "the silhouette border, and the CSS that drives it"
# THE ARROW HAS AN OUTLINE BY DEFAULT, and it is CSS's own initial value doing it: border-color
# is `currentColor`, shaded back toward the ground, because an outline in exactly the fill's
# colour is not an outline in a terminal. Nothing about that is written down in the painter —
# take the colour away and the rim follows it.
#
# Every assertion here is BYTE IDENTITY against the same arrow with the border removed, which
# also pins the other half of the promise: a removed border is not a border painted in the
# fill's colour, it is the bytes an arrow drew before this feature existed.
ft-modify ga place=left size=medium color=196
ft-modify ga borderWidth=0; _paint_bytes; _bare=$FT_RET
ft-modify ga borderWidth=thin; _paint_bytes; _outlined=$FT_RET
check "an outline is drawn by DEFAULT" \
      "$(case "$_outlined" in "$_bare") echo none ;; *) echo outlined ;; esac)" "outlined"
_ft_effective_bg ga; _ground=$FT_RET
_ft_bigarrow_color ga -1 "$_ground"; _ink=$FT_RET
if _ft_bigarrow_outline_color ga "$_ink" "$_ground"; then _rim=$FT_RET; else _rim=NONE; fi
check "…and the default rim is not the ink itself" \
      "$(case "$_rim" in "$_ink") echo same ;; NONE) echo none ;; *) echo shaded ;; esac)" "shaded"
ok    "…while the ink is still exactly what was declared" _has_fg "$_outlined" 196
# border-color takes it over, at every level of the cascade.
ft_stylesheet name=ft-test-arrowcss style='#ga { border-color: 226 }'
_paint_bytes; ok "#id { border-color } paints the outline"      _has_fg "$FT_RET" 226
ft_stylesheet name=ft-test-arrowcss style='beacon { border-color: dodgerblue }'
_paint_bytes; ok "…by type selector, and by colour NAME"        _has_fg "$FT_RET" dodgerblue
ft_stylesheet name=ft-test-arrowcss style=''
ft-modify ga borderColor=51
_paint_bytes; ok "…and as an inline property"                   _has_fg "$FT_RET" 51
# …and CSS's own ways of saying "no border" each put the bytes back exactly as they were.
_same_as_bare() { _paint_bytes; [[ "$FT_RET" == "$_bare" ]]; }
ft-modify ga borderColor=transparent
ok "border-color: transparent removes the outline"  _same_as_bare
ft-modify ga borderColor=none
ok "border-color: none removes it too"              _same_as_bare
ft-modify ga borderColor=51 borderWidth=0
ok "border-width: 0 removes it"                     _same_as_bare
ft-modify ga borderWidth=thin borderStyle=none
ok "border-style: none removes it"                  _same_as_bare
ft-modify ga borderStyle=solid
ft_remove_attribute ga borderColor
ft_remove_attribute ga color
# THE OUTLINE IS THE SHAPE'S OWN, not a box around it: it may only ever repaint cells the arrow
# already drew, so the footprint must not move by a single cell when the border is styled.
ft-modify ga borderWidth=0; _geo -1; _noborder_span="$FT_BIGARROW_COLUMNS $FT_BIGARROW_ROWS"
ft-modify ga borderWidth=thin borderColor=226; _geo -1
check "a border never grows the arrow's footprint" \
      "$FT_BIGARROW_COLUMNS $FT_BIGARROW_ROWS" "$_noborder_span"
ft_remove_attribute ga borderColor
# …and it FADES with the arrow rather than hanging over the page as a bright wireframe once the
# fill has dissolved. exit=fade lerps the ink toward the ground; the rim has to travel with it.
ft_remove ga2 2>/dev/null
# place=right, not left: `ga` is still standing in the left lane with its ink published, and a
# second arrow that would bury it there is now REFUSED rather than drawn on top of it — which is
# the burial floor working, not a fault to route around silently.
ft-beacon name=ga2 variant=bigarrow target=btn place=right exit=fade borderColor=226 \
          animationTimingFunction="ease-out-back, linear"
FT_BIGARROW_STAGE[ga2]=exit
_rim_at() {                     # phase → FT_RET = the rim's SGR that frame
    ft_clip_reset; _ft_beacon_rect ga2; _ft_bigarrow_geometry ga2 "$1"
    _ft_effective_bg ga2; local ground=$FT_RET
    _ft_bigarrow_color ga2 "$1" "$ground"; local ink=$FT_RET
    _ft_bigarrow_outline_color ga2 "$ink" "$ground"
}
_rim_at 0;  _rim0=$FT_RET
_rim_at 10; _rim9=$FT_RET
ft_color_sgr 226 38
check "a declared rim starts at the colour it was given" "$_rim0" "$FT_RET"
check "…and fades with the arrow rather than lingering" \
      "$(case "$_rim9" in "$_rim0") echo frozen ;; *) echo faded ;; esac)" "faded"
ft_remove ga2
ft-modify ga place=left

# ═══ the erase record ════════════════════════════════════════════════════════
note "a move damages the strip it vacated, never a bounding box"
ft-modify ga place=left animationTimingFunction=ease-out-back
FT_OUT=""; ft_clip_reset; _ft_beacon_rect ga; _ft_beacon_paint_bigarrow ga -1
check "a paint records where it painted" "$(( ${#FT_BIGARROW_AT[ga]} > 0 ))" "1"
_geo -1
FT_DAMAGE=()
_ft_bigarrow_damage_move ga "$FT_BIGARROW_TOP" $(( FT_BIGARROW_LEFT + 1 )) "$FT_BIGARROW_SHAPE_KEY"
check "a one-cell move damages one rect per painted row" "${#FT_DAMAGE[@]}" "$FT_BIGARROW_ROWS"
_cells=0
for _d in "${FT_DAMAGE[@]}"; do
    set -- $_d; (( _cells += ($3 - $1 + 1) * ($4 - $2 + 1) ))
done
check "…and exactly one cell each"                       "$_cells" "$FT_BIGARROW_ROWS"
FT_DAMAGE=()
_ft_bigarrow_damage_move ga "$FT_BIGARROW_TOP" "$FT_BIGARROW_LEFT" "$FT_BIGARROW_SHAPE_KEY"
check "no move damages nothing"                          "${#FT_DAMAGE[@]}" "0"
FT_DAMAGE=()
# …and an arrow that stops being drawable takes its ink with it, rather than standing on the
# screen forever. Move the target somewhere no side has room and paint again.
FT_OUT=""; ft_clip_reset; _ft_beacon_rect ga; _ft_beacon_paint_bigarrow ga -1
check "…and it painted before we squeeze it" "$(( ${#FT_BIGARROW_AT[ga]} > 0 ))" "1"
_target_at 1 1 96 27       # fills the bound: no room on any side
FT_DAMAGE=(); FT_OUT=""
ft_clip_reset; _ft_beacon_rect ga; _ft_beacon_paint_bigarrow ga -1
check "a suppressed arrow damages what it had drawn"     "$(( ${#FT_DAMAGE[@]} > 0 ))" "1"
check "…and paints nothing"                              "$FT_OUT" ""
check "…and forgets where it was"                        "${FT_BIGARROW_AT[ga]:-gone}" "gone"
FT_DAMAGE=(); _target_at 46 14 8 3

note "the constructor arms a flight; destroying it takes everything with it"
ft_remove ga
ft-beacon name=ga2 variant=bigarrow target=btn
check "it is a registered beacon"        "${FT_TYPE[ga2]:-}" "beacon"
# `>= 0` here was ALWAYS TRUE — a string's length is never negative, and no `set -u` is in force
# to make an unset key error either, so this assertion passed whether or not a flight was armed.
# The sibling four lines down already uses the correct shape.
check "a flight was armed"               "$(( ${#FT_ANIM_PHASE[ga2]} > 0 ))" "1"
check "…that does NOT loop (it lands)"   "${FT_ANIM_LOOP[ga2]}" "0"
check "…for FT_BIGARROW_FRAMES frames"   "${FT_ANIM_LENGTH[ga2]}" "$(( FT_BIGARROW_FRAMES + 1 ))"
check "…bound to the bigarrow frame fn"  "${FT_ANIM_FRAME[ga2]}" "_ft_bigarrow_frame"
check "…with its curve precomputed"      "$(( ${#FT_BIGARROW_EASE[ga2]} > 0 ))" "1"
# The FLY is its own animation now, whatever the lifetime — the hold and the exit are two more,
# armed in turn (see the stage machine). It used to be one animation of frames*(1+cycles), which
# is where a two-and-a-half-second hold cost ~85 no-op repaints.
ft-modify ga2 lifetime=oneshot; _ft_bigarrow_arm ga2
check "oneshot's FLY is still just the flight" "${FT_ANIM_LENGTH[ga2]}" "$(( FT_BIGARROW_FRAMES + 1 ))"
FT_OUT=""; ft_clip_reset; _ft_beacon_rect ga2; _ft_beacon_paint_bigarrow ga2 -1
ft_remove ga2
_leak=""
[[ -n "${FT_BIGARROW_AT[ga2]:-}" ]]   && _leak+="AT "
[[ -n "${FT_BIGARROW_EASE[ga2]:-}" ]] && _leak+="EASE "
[[ -n "${FT_ANIM_PHASE[ga2]:-}" ]]    && _leak+="ANIM "
[[ -n "${FT_OVERLAY[ga2]:-}" ]]       && _leak+="OVERLAY "
check "destroy leaves nothing behind"    "$_leak" ""

# ═══ 5. it gets out of the way ═══════════════════════════════════════════════
# "A huge arrow is the right amount of emphasis for a second and the wrong amount after ten."
# The retirement is therefore not a nicety, and three things about it are load-bearing: it
# happens BY DEFAULT, it happens in stages that do not burn the event loop while waiting, and
# the cells it covered come back — an overlay paints outside its layout box, so nothing else on
# the page knows those cells were ever touched.
note "a bigarrow retires unless you say otherwise"
ft_remove ga2 2>/dev/null
ft-beacon name=gx variant=bigarrow target=btn
ft_resolved_prop gx lifetime "?"
check "saying nothing gets you oneshot"          "$FT_RET" "oneshot"
ft_remove gx
ft-beacon name=gx variant=bigarrow target=btn lifetime=persist
ft_resolved_prop gx lifetime "?"
check "…and persist is available, deliberately"  "$FT_RET" "persist"
ft_remove gx
# …and the other variants are untouched: this default belongs to the arrow, not to beacons.
ft-beacon name=gf variant=frame target=btn
ft_resolved_prop gf lifetime "?"
check "a frame beacon still defaults to persist" "$FT_RET" "persist"
ft_remove gf

note "the three stages, and the waiting that must not cost anything"
ft-beacon name=gx variant=bigarrow target=btn
check "it starts in the fly stage"        "${FT_BIGARROW_STAGE[gx]}" "fly"
# +1 on both counts: the last frame of a stage is spent TRANSITIONING, not painting, so an
# animation exactly as long as its curve never paints the curve's endpoint. Measured on the
# retract, where the last frame anyone saw still had 26 columns of arrow on the screen.
check "…for FT_BIGARROW_FRAMES frames +1"  "${FT_ANIM_LENGTH[gx]}"    "$(( FT_BIGARROW_FRAMES + 1 ))"
check "…and both curves are precomputed"  "$(( ${#FT_BIGARROW_EASE[gx]} > 0 && ${#FT_BIGARROW_XEASE[gx]} > 0 ))" "1"
_ft_bigarrow_enter_hold gx
check "the hold is its own animation"     "${FT_BIGARROW_STAGE[gx]}" "hold"
check "…of exactly two frames"            "${FT_ANIM_LENGTH[gx]}"    "2"
# THE POINT of that two: one wakeup for the whole wait. A single animation spanning all three
# stages at the fly's frame rate would tick holdDuration/frameMs times — ~85 no-op repaints at
# ~15ms each — which is this framework's definition of input lag.
check "…so the whole wait costs ONE tick" "$(( FT_ANIM_FRAME_MS[gx] >= 1000 ))" "1"
_ft_bigarrow_enter_exit gx
check "the exit is its own animation"     "${FT_BIGARROW_STAGE[gx]}" "exit"
check "…of FT_BIGARROW_EXIT_FRAMES +1"    "${FT_ANIM_LENGTH[gx]}"    "$(( FT_BIGARROW_EXIT_FRAMES + 1 ))"
ft_remove gx

note "the two exits do what they say"
_t_walk() {                     # exit= → _T_OFFS (left per exit frame) and _T_ALPHAS
    ft_remove gx 2>/dev/null
    ft-beacon name=gx variant=bigarrow target=btn exit="$1" "${@:2}"
    ft_clip_reset; _ft_beacon_rect gx; _ft_bigarrow_geometry gx -1
    _T_HOME=$FT_BIGARROW_LEFT
    FT_BIGARROW_STAGE[gx]=exit
    _T_OFFS=""; _T_ALPHAS=""
    local p
    for (( p=0; p<FT_BIGARROW_EXIT_FRAMES; p++ )); do
        _ft_bigarrow_geometry gx "$p"
        _T_OFFS+="$(( FT_BIGARROW_LEFT - _T_HOME )) "; _T_ALPHAS+="$FT_BIGARROW_ALPHA "
    done
}
_t_walk retract
# It must END somewhere it is no longer on the screen — retracting by the fly-in's own travel
# put it back at its LAUNCH position, which is thirty columns of arrow sitting in plain view,
# and then destroyed it there: exactly the pop a graceful exit exists to avoid.
_t_last=${_T_OFFS% }; _t_last=${_t_last##* }
check "retract ends clear of the bound"   "$(( _T_HOME + _t_last + FT_BIGARROW_COLUMNS <= 0 ))" "1"
check "…and it moves AWAY from the target" "$(( _t_last < 0 ))" "1"
# …with an anticipation beat first: an -back curve leans it toward the target before it goes.
_t_leaned=0
for _t_o in $_T_OFFS; do (( _t_o > 0 )) && _t_leaned=1; done
check "…after leaning in first (ease-in-back)" "$_t_leaned" "1"
check "retract never touches the colour"  "${_T_ALPHAS// /}" "$(printf '100%.0s' $(seq 1 $FT_BIGARROW_EXIT_FRAMES))"
_t_walk fade "animationTimingFunction=ease-out-back, linear"
_t_moved=0
for _t_o in $_T_OFFS; do (( _t_o != 0 )) && _t_moved=1; done
check "fade does NOT move the arrow"      "$_t_moved" "0"
_t_first=${_T_ALPHAS%% *}; _t_lastA=${_T_ALPHAS% }; _t_lastA=${_t_lastA##* }
check "…it starts opaque"                 "$_t_first" "100"
check "…and ends nearly transparent"      "$(( _t_lastA < 25 ))" "1"
ft_remove gx

note "…and the ground comes back"
# THE GATE THE WHOLE EXIT RESTS ON. Paint a page, remember every cell. Raise an arrow, let it
# retire, and demand the screen is what it was — not "close", identical. An overlay paints
# outside its layout box, so if the retirement forgot to damage what it drew, those glyphs
# would still be standing and nothing else would ever repaint them.
_t_cells() { FT_OUT=""; ft_refresh; FT_RET=$FT_OUT; }
ft_remove ga 2>/dev/null
_target_at 46 14 8 3
_t_cells; _t_before=$FT_RET
ft-beacon name=gx variant=bigarrow target=btn
FT_OUT=""; ft_clip_reset; _ft_beacon_rect gx; _ft_beacon_paint_bigarrow gx 10
check "the arrow painted something to clean up" "$(( ${#FT_OUT} > 100 ))" "1"
_t_painted=${FT_BIGARROW_AT[gx]:-}
check "…and recorded where"                     "$(( ${#_t_painted} > 0 ))" "1"
FT_DAMAGE=(); FT_OUT=""
_ft_bigarrow_retire gx
check "retiring destroys the beacon"            "${FT_TYPE[gx]:-gone}" "gone"
check "…and leaves no state behind"             "${FT_BIGARROW_AT[gx]:-clean}${FT_BIGARROW_STAGE[gx]:-}${FT_BIGARROW_EASE[gx]:-}" "clean"
_t_cells; _t_after=$FT_RET
check "the screen is what it was before the arrow" \
      "$(case "$_t_after" in "$_t_before") echo identical ;; *) echo DIFFERENT ;; esac)" "identical"

note "…and the retirement runs on its own, through the engine's own tick"
# Not a hand-driven walk: this is ft_anim_step, the real loop, driving the real animation until
# the beacon is gone. If a stage transition failed to re-arm, this hangs and the guard fires.
ft-beacon name=gx variant=bigarrow target=btn
_t_ticks=0
while [[ -n "${FT_TYPE[gx]:-}" ]] && (( _t_ticks < 4000 )); do
    (( _t_ticks++ ))
    FT_ANIM_POLL_MS=${FT_ANIM_POLL_MS:-20}
    ft_anim_step
done
check "the arrow retires itself, unaided"       "${FT_TYPE[gx]:-gone}" "gone"
check "…without spinning (bounded tick count)"  "$(( _t_ticks < 4000 ))" "1"

# ═══ 6. THE SCREEN ═══════════════════════════════════════════════════════════
# Everything above can pass while the app draws nothing at all. This drives the real demo in a
# real pty and reads the cells that came out.
note "the screen: the real demo, in a real pty"
renderer="$here/tests/render-screen.py"
_render() {                     # page step → _SCREEN
    _SCREEN=$(FT_TEST_ROWS=40 FT_TEST_COLS=118 FT_NO_WTFIX=1 \
              DEMO_PAGE=$1 DEMO_STEP=$2 python3 "$renderer" "$here/demo/bigarrow-demo.bash" '' 2>/dev/null)
    (( ${#_SCREEN} > 0 ))
}
# Which columns on the screen carry ARROW ink, and on which rows. Read cell by cell against the
# emit set, so this counts the glyphs the rasteriser actually produces and nothing else.
_INK_MINCOL=999; _INK_MAXCOL=-1; _INK_MINROW=999; _INK_MAXROW=-1; _INK_CELLS=0
_scan_ink() {                   # screen
    local line ch r=0 i
    _INK_MINCOL=999; _INK_MAXCOL=-1; _INK_MINROW=999; _INK_MAXROW=-1; _INK_CELLS=0
    while IFS= read -r line; do
        for (( i=0; i<${#line}; i++ )); do
            ch=${line:i:1}
            case "$ch" in
                █|▁|▂|▃|▄|▅|▆|▇|▏|▎|▍|▌|▋|▊|▉|━|┃)
                    (( _INK_CELLS++ ))
                    (( i < _INK_MINCOL )) && _INK_MINCOL=$i
                    (( i > _INK_MAXCOL )) && _INK_MAXCOL=$i
                    (( r < _INK_MINROW )) && _INK_MINROW=$r
                    (( r > _INK_MAXROW )) && _INK_MAXROW=$r ;;
            esac
        done
        (( r++ ))
    done <<< "$1"
}
# The frame the demo points into — its left border column, from the title row.
_FRAME_L=-1
_scan_frame() {                 # screen
    local line i
    _FRAME_L=-1
    while IFS= read -r line; do
        [[ "$line" == *"┌"* ]] || continue
        for (( i=0; i<${#line}; i++ )); do
            [[ "${line:i:1}" == "┌" ]] && { _FRAME_L=$i; return 0; }
        done
    done <<< "$1"
    return 1
}

if _render 1 1; then
    _scan_ink "$_SCREEN"; _scan_frame "$_SCREEN"
    check "page 1 draws a big arrow"            "$(( _INK_CELLS > 60 ))" "1"
    check "…several rows tall"                  "$(( _INK_MAXROW - _INK_MINROW >= 3 ))" "1"
    check "…and many columns wide"              "$(( _INK_MAXCOL - _INK_MINCOL >= 15 ))" "1"
    check "the demo drew its Settings frame"    "$(( _FRAME_L > 0 ))" "1"
    check "auto put the arrow LEFT of it"       "$(( _INK_MAXCOL < _FRAME_L ))" "1"
    # SETTLED MEANS SETTLED. A second render of the same page must be cell-identical: if the
    # landed arrow were still animating, or its phase snapped back when the animation retired,
    # the two frames would differ. This is the cheapest possible test for "it stopped".
    _first=$_SCREEN
    _render 1 1
    check "the settled frame is stable across runs" \
          "$(case "$_SCREEN" in "$_first") echo same ;; *) echo DIFFERENT ;; esac)" "same"
else
    check "page 1 renders" "no output" "a screen"
fi

if _render 2 2; then            # place=left  → points right, arrow in the left margin
    _scan_ink "$_SCREEN"; _scan_frame "$_SCREEN"
    check "place=left keeps the arrow left of the target" "$(( _INK_MAXCOL < _FRAME_L ))" "1"
    check "…and it is a big arrow, not a stub"            "$(( _INK_CELLS > 60 ))" "1"
else
    check "page 2 step 2 renders" "no output" "a screen"
fi
if _render 2 5; then            # place=below → points up, arrow BELOW the frame
    _scan_ink "$_SCREEN"
    _fb=-1; _r=0
    while IFS= read -r _l; do [[ "$_l" == *"└"* ]] && _fb=$_r; (( _r++ )); done <<< "$_SCREEN"
    check "place=below keeps the arrow below the target"  "$(( _INK_MINROW > _fb ))" "1"
else
    check "page 2 step 5 renders" "no output" "a screen"
fi
if _render 4 3; then            # smoothing=solid → whole cells only
    _solid=$_SCREEN
    _render 4 1                 # smoothing=eighths → sub-cell glyphs
    check "smoothing changes what is drawn" \
          "$(case "$_SCREEN" in "$_solid") echo same ;; *) echo different ;; esac)" "different"
    case "$_solid" in *▆*|*▄*|*▂*) check "…solid really is whole cells only" 0 1 ;;
                      *)          check "…solid really is whole cells only" 1 1 ;; esac
    case "$_SCREEN" in *▆*|*▄*|*▂*) check "…and eighths really uses eighths" 1 1 ;;
                       *)           check "…and eighths really uses eighths" 0 1 ;; esac
else
    check "page 4 renders" "no output" "a screen"
fi

summary
