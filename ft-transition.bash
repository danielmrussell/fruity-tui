#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — ft-transition.bash
#
#  A control that MORPHS INTO EXISTENCE out of the pixels already on the screen.
#
#  Declared in CSS, resolved through the ordinary cascade, and applicable to any control
#  that is allowed to overlay others:
#
#      #notice        { transition: opacity 320ms ease-in-out; }
#      callout:hover  { transition: opacity 200ms ease-out; }
#      #punch         { transition: opacity 480ms cubic-bezier(0.34, 1.56, 0.64, 1); }
#      :root          { --transition-schedule: contrast; }   /* contrast | average */
#
#  The timing function is CSS's whole set because it IS CSS's solver: ft_ease (ft-forms.bash),
#  shared with the bigarrow rather than reimplemented here. linear | ease | ease-in | ease-out |
#  ease-in-out | cubic-bezier() | the three -back overshoot curves.
#
#  ── WHY THE COLOURS MOVE THE WAY THEY DO ────────────────────────────────────
#  In a terminal a cell is (glyph, foreground, background) and two layers' glyphs are
#  mutually exclusive: a cell shows one or the other, never a blend. So the glyph has to be
#  SWAPPED at some instant, and the whole job of the schedule is to make that instant
#  unobservable. A glyph is unobservable exactly when its foreground equals its background —
#  contrast zero. So:
#
#      background   interpolates bottom → top across the WHOLE transition, monotonically
#      foreground   first half:  bottom's fg → the background AT THAT MOMENT   (text sinks)
#                   at the cut:  fg == bg, nothing is legible, the glyph is swapped
#                   second half: the background → top's fg                     (text rises)
#
#  and one sampled frame is FORCED to land exactly on the cut (see _ft_transition_plan), or
#  the swap happens between two frames that both have contrast, which is the visible cut the
#  whole scheme exists to hide.
#
#  The framework's author proposed a different schedule: average the two backgrounds, average
#  the two foregrounds, go to those averages and back out. Both are implemented
#  (--transition-schedule: contrast | average) because he asked for the screen to decide.
#  BOTH AVERAGE PER CELL, between that cell's own two layers — nothing is ever pooled across
#  different cells, and a run is precisely a stretch of cells whose two layers agree, so
#  averaging per run IS averaging per cell.
#  MEASURED, on the demo's own rect, as the worst per-cell |fg−bg| over the inked cells of
#  each frame (0 = the glyph cannot be seen at all):
#
#      contrast   630 612 549 447 300 111   0  264 393 486 541 561
#      average    630 629 626 619 611 600 594  578 571 564 561 561
#
#  His version never goes below 561 of a possible 765: the outgoing text stays fully legible
#  right through the swap, so the cut is exactly as visible as a hard replace — the averaging
#  changes the colours but not the thing it was meant to hide. The reason is arithmetic:
#  averaging fg and bg INDEPENDENTLY produces two different midpoints, and the distance
#  between them is what the eye reads as text. The property that hides a glyph is not "the
#  colours met in the middle", it is "the two colours became the same colour".
#
#  ── WHY IT IS FAST ──────────────────────────────────────────────────────────
#  Per-cell work per frame is impossible in bash: a 40×8 callout is 320 cells and a plain
#  array read alone is ~1.3µs, before any colour arithmetic. So NOTHING is per cell.
#
#    · BATCH BY STYLE RUN, NOT BY CELL (the author's design, and the whole of the story). A
#      RUN is a maximal horizontal stretch whose (fg, bg) pair is the same in the bottom layer
#      AND the same in the top layer, so every cell in it blends identically: one colour
#      computation per run per frame, one emitted string per run. Runs sharing a style PAIR
#      share a blend CLASS, so the arithmetic is per class. 320 cells → 29 runs → 4 classes.
#      The engine already thinks this way: ft_print_at_width emits a whole coloured row in one write, and
#      _ft_damage_fill resolves ground per RUN rather than per cell.
#    · The two layers are read back as SPANS, not cells — (row, column, text, style)
#      pieces, which is the shape the bytes already have. Work is proportional to pieces
#      (tens), never to cells (hundreds). The run decomposition is built ONCE at kick-off and
#      reused for every frame; the layers do not change shape mid-transition.
#    · The whole transition is PRECOMPUTED at kick-off into N ready-to-emit strings. A frame
#      is then one write.
#
#  MEASURED (95×34 and 140×44, 40×8 rect, 11 frames — tools/bench-transition.bash):
#      kick-off  ~120ms idle, 165ms worst under load
#                (paint the incoming layer 17–43 + capture the ground 40–65
#                 + read both layers back 40–60 + runs 8–42 + blend 11–18)
#      playback  54–100µs per frame
#  Two thirds of the kick-off is work any appearing control already costs — a damage repair
#  plus a paint — so arming a transition roughly DOUBLES the cost of making a control appear,
#  once. The read-back is the part that exists only because the framework keeps no cell
#  buffer, and the span renderer would delete it (docs/rendering-spans.md).
#
#  THE ACCEPTANCE BAR IS INPUT LATENCY, NOT FRAME RATE. The run loop blocks in a `read -t`
#  that a real keystroke wins immediately, so a running animation costs a keystroke only when
#  the key lands mid-tick: worst-case added latency IS one tick.
#  (tools/bench-transition-latency.bash, typing into a focused field)
#      nothing running                 keystroke median 2ms
#      precomputed transition running  tick median 2ms, MAX 6ms      — imperceptible
#      live ground, no yielding        tick median 153ms, MAX 188ms  — unusable, hence §live
#
#  ── WHAT IT BLENDS FROM ─────────────────────────────────────────────────────
#  The "underlying pixels" are what the damage layer calls the GROUND, and they are obtained
#  the way the damage layer obtains them: `_ft_damage_fill` for the background of every run,
#  then the controls that intersect the rect repainted over it. There is no second notion of
#  what is underneath.
#
#  ── LIMITS (read these before believing a frame) ────────────────────────────
#    · 256-COLOUR TERMINALS BAND. A ramp between two colours is quantised to the xterm cube,
#      whose steps are 40/255 apart: an 11-frame ramp between two nearby colours collapses to
#      two or three distinct steps and the "melt" becomes a snap. `ft_transition_supported`
#      reports this; the demo says so on screen. No dithering — a checkerboard of two cube
#      entries reads as texture on text, not as a blend.
#    · A cell nothing painted has no colour of its own; it is assumed to be the theme surface
#      (`FT_COLOR_BODY`'s background). A terminal whose default background differs from the
#      theme's will start such a cell from slightly the wrong colour.
#    · One transition per control. Concurrent transitions on DIFFERENT controls are fine on
#      the precomputed path (frames are stored per control); the LIVE path shares one run
#      decomposition and so supports one at a time.
#    · Transitions OUT are not implemented — only ft_transition_in. NOT for the reason first
#      recorded here (a lifecycle problem): variant=bigarrow already keeps a control alive
#      through its own exit. The obstacle is cost — 228-295ms to arm at arrow size, at a moment
#      the user did not initiate. Measured, with the alternatives, in docs/transitions.md §4a.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_TRANSITION_LOADED:-}" ]] && return 0
_FT_TRANSITION_LOADED=1

# ── CSS surface ──────────────────────────────────────────────────────────────
# `transition` is registered paint-kind for the same reason `animation` is: it changes how a
# control draws and never its box, and registering it lets the DSL accept a spaced value —
# `transition="opacity 320ms ease-in-out"` — as ONE property rather than as content.
ft_prop_kind_set transition                paint
ft_prop_kind_set transitionDuration        paint
ft_prop_kind_set transitionTimingFunction  paint
ft_prop_kind_set transitionProperty        paint

# The schedule is a CUSTOM property, not an invented CSS property. `--transition-schedule`
# is the sanctioned place for a knob CSS does not have, it inherits like any custom property,
# and a theme can set it on :root. Values: contrast (the default) | average.
FT_TRANSITION_SCHEDULE_DEFAULT=contrast
# Frame pacing. 30ms is the floor the animation loop can actually hold for a whole-region
# write in bash; below that frames queue and the transition runs long.
FT_TRANSITION_FRAME_MS=30
FT_TRANSITION_MIN_FRAMES=5
FT_TRANSITION_MAX_FRAMES=25
FT_TRANSITION_DEFAULT_MS=320

# ── State ────────────────────────────────────────────────────────────────────
# Frames live in ONE flat array with a per-control base index, rather than an array per
# control (bash has no arrays of arrays, and a delimited string would have to be re-split at
# every frame — the exact "text nonsense" the span design exists to avoid).
declare -a _FT_TRANSITION_FRAME=()
declare -A _FT_TRANSITION_BASE=() _FT_TRANSITION_COUNT=() _FT_TRANSITION_ACTIVE=() \
           _FT_TRANSITION_RECT=() _FT_TRANSITION_LIVE=()
_FT_TRANSITION_NEXT_SLOT=0
FT_TRANSITION_LAST_KICKOFF_MS=0     # what the last ft_transition_in cost, for benches/tests
FT_TRANSITION_LAST_FRAME_MS=0       # what the last LIVE frame cost (0 on the precomputed path)
FT_TRANSITION_LAST_RUNS=0
FT_TRANSITION_LAST_CLASSES=0
FT_TRANSITION_LAST_YIELDED=0        # did the last live frame skip re-reading the ground?
_FT_TRANSITION_RUNS_OWNER=""        # whose decomposition is in _FT_RUN_* right now
# How recently the user must have done something for a LIVE frame to skip its ground re-read.
# One animation tick is the window a keystroke waits in, so this is the knob that decides
# whether a transition can make typing lag. 250ms ≈ "still typing".
FT_TRANSITION_YIELD_MS=250

# ── Colour ───────────────────────────────────────────────────────────────────
# Interpolation is a straight per-channel lerp on the 0-255 sRGB values — the same space
# `_ft_css_blend` and every @keyframes ramp in this framework already use. It is not
# perceptually uniform (a gamma-correct blend would square, average, and take a root, which
# integer bash cannot do without a table), but it is what the rest of the engine does, and
# consistency matters more here than correctness-in-principle: a transition that ended on a
# subtly different colour from the keyframe ramp beside it would look like a bug.
declare -A _FT_TRANSITION_INDEX_RGB=()
_ft_transition_index_rgb() {    # 256 index → FT_RET "r,g,b"
    local v=${_FT_TRANSITION_INDEX_RGB[$1]:-}
    if [[ -z "$v" ]]; then
        ft_256_to_rgb "$1"; v="$FT_RGB_RED,$FT_RGB_GREEN,$FT_RGB_BLUE"
        _FT_TRANSITION_INDEX_RGB[$1]=$v
    fi
    FT_RET=$v
}
# The other direction, memoised for the same reason: on a 256-colour terminal EVERY blended
# colour of every frame has to be quantised to the cube, and ft_rgb_to_256 is six function
# calls of cube-versus-grey arithmetic. Classes × frames is small and the ramps repeat, so the
# table fills at once. Measured: the blend step 30ms → 11ms in 256 mode, matching truecolor.
declare -A _FT_TRANSITION_RGB_INDEX=()
_ft_transition_rgb_to_256() {   # r g b → FT_RET index
    local key="$1,$2,$3"        # SEPARATE LINES: `local a=$1 b=${arr[$a]}` reads the OLD a,
    local v=${_FT_TRANSITION_RGB_INDEX[$key]:-}     # which under set -u is an unbound read
    if [[ -z "$v" ]]; then ft_rgb_to_256 "$1" "$2" "$3"; v=$FT_RET; _FT_TRANSITION_RGB_INDEX[$key]=$v; fi
    FT_RET=$v
}
# The theme surface as RGB — the colour a cell nothing painted is assumed to already be.
FT_TRANSITION_GROUND_FG=192,192,192
FT_TRANSITION_GROUND_BG=0,0,0
_ft_transition_sample_theme() {
    local s=$FT_COLOR_BODY v
    if [[ "$s" == *"[48;5;"* ]]; then v=${s#*"[48;5;"}; v=${v%%m*}; v=${v%%;*}
        _ft_transition_index_rgb "$v"; FT_TRANSITION_GROUND_BG=$FT_RET
    elif [[ "$s" == *";48;5;"* ]]; then v=${s#*";48;5;"}; v=${v%%m*}; v=${v%%;*}
        _ft_transition_index_rgb "$v"; FT_TRANSITION_GROUND_BG=$FT_RET; fi
    if [[ "$s" == *"[38;5;"* ]]; then v=${s#*"[38;5;"}; v=${v%%m*}; v=${v%%;*}
        _ft_transition_index_rgb "$v"; FT_TRANSITION_GROUND_FG=$FT_RET
    elif [[ "$s" == *";38;5;"* ]]; then v=${s#*";38;5;"}; v=${v%%m*}; v=${v%%;*}
        _ft_transition_index_rgb "$v"; FT_TRANSITION_GROUND_FG=$FT_RET; fi
}

# ft_transition_supported → 0 if the terminal can actually show a melt, 1 if it will band.
# 256-colour mode quantises every intermediate to the xterm cube (steps of 40 in each
# channel), so a ramp between two nearby colours has two or three distinct values in it.
ft_transition_supported() { [[ "$FT_COLOR_MODE" == truecolor ]]; }

# ── Display width, with the characters remembered ────────────────────────────
# ft_char_cols costs ~60µs a glyph (it runs a printf builtin to get the code point), so
# ft_display_width on one 40-cell box-drawing border is ~2.1ms — and a parse meets a dozen
# of them. A character's width never changes, so it is asked once: 60µs → ~2µs.
# (The same memo inside ft_char_cols would speed up every width scan in the framework.
# Deliberately not done on this branch — see docs/transitions.md, "What we did not change".)
declare -A _FT_TRANSITION_CHAR_WIDTH=() _FT_TRANSITION_TEXT_WIDTH=()
_ft_transition_width() {        # text → FT_RET columns
    local s=$1
    [[ "$s" != *[![:ascii:]]* ]] && { FT_RET=${#s}; return; }
    local v=${_FT_TRANSITION_TEXT_WIDTH[$s]:-}
    if [[ -z "$v" ]]; then
        local rest=$s run width=0 character character_width
        while [[ -n "$rest" ]]; do
            run=${rest%%[![:ascii:]]*}
            if [[ -n "$run" ]]; then (( width += ${#run} )); rest=${rest#"$run"}; fi
            [[ -z "$rest" ]] && break
            character=${rest:0:1}; character_width=${_FT_TRANSITION_CHAR_WIDTH[$character]:-}
            if [[ -z "$character_width" ]]; then
                ft_char_cols "$character"; character_width=$FT_CHAR_WIDTH
                _FT_TRANSITION_CHAR_WIDTH[$character]=$character_width
            fi
            (( width += character_width )); rest=${rest:1}
        done
        v=$width; _FT_TRANSITION_TEXT_WIDTH[$s]=$v
    fi
    FT_RET=$v
}
_ft_transition_index() {        # text column → FT_RET character index
    local s=$1 want=$2
    [[ "$s" != *[![:ascii:]]* ]] && { (( want > ${#s} )) && want=${#s}; FT_RET=$want; return; }
    local i=0 n=${#s} width=0 character character_width
    while (( i < n && width < want )); do
        character=${s:i:1}; character_width=${_FT_TRANSITION_CHAR_WIDTH[$character]:-}
        if [[ -z "$character_width" ]]; then
            ft_char_cols "$character"; character_width=$FT_CHAR_WIDTH
            _FT_TRANSITION_CHAR_WIDTH[$character]=$character_width
        fi
        (( width += character_width, i++ ))
    done
    FT_RET=$i
}
# THE WHOLE-STRING CASE IS THE COMMON ONE and must not walk the string: slicing a non-ASCII
# run by display column costs two index walks, and the parser asks for a hundred slices of
# which almost all are "all of it". The caller already knows the width, so pass it.
_ft_transition_slice() {        # text knownWidth fromColumn count → FT_RET
    local s=$1
    (( $3 == 0 && $4 >= $2 )) && { FT_RET=$s; return; }
    if [[ "$s" != *[![:ascii:]]* ]]; then FT_RET=${s:$3:$4}; return; fi
    _ft_transition_index "$s" "$3"; local from=$FT_RET
    _ft_transition_index "$s" $(( $3 + $4 )); FT_RET=${s:from:$(( FT_RET - from ))}
}

# ── The ground, through the engine's own repair path ─────────────────────────
# Not a second notion of "what is underneath": this is `_ft_damage_fill` for the background
# of every run, then exactly the controls `_ft_damage_dirty_multi` would enlist, painted in
# depth order, then the other live overlays. The control being transitioned in is skipped
# because _FT_TRANSITION_ACTIVE is already set for it and ft_draw_one honours that.
_ft_transition_capture_ground() {   # top left bottom right → FT_RET bytes
    local top=$1 left=$2 bottom=$3 right=$4
    local saved_output=$FT_OUT; FT_OUT=""
    local -a was_dirty=("${!FT_DIRTY[@]}") was_repair=("${!FT_REPAIR[@]}")
    FT_DIRTY=(); FT_REPAIR=()
    # NARROWED REPAIR, for the reason the engine's own narrowed repair exists: `_ft_damage_fill`
    # has just laid every container's background, so a draw-less container has nothing left to
    # contribute and enlisting one drags its whole subtree into the capture. Measured here:
    # 49ms → 30ms, and the ground bytes fall with it.
    local was_narrow=$FT_DAMAGE_NARROW
    FT_DAMAGE_NARROW=1
    ft_clip_band "$top" "$bottom"
    _FT_DFILL_BUILT=0
    _ft_damage_fill "$top" "$left" "$bottom" "$right"
    _FT_DFILL_BUILT=1
    _FT_DD_T=("$top"); _FT_DD_L=("$left"); _FT_DD_B=("$bottom"); _FT_DD_R=("$right"); _FT_DD_N=1
    [[ -n "${FT_ROOT:-}" ]] && _ft_damage_enlist "$FT_ROOT"
    _FT_DFILL_BUILT=0
    local name i j swap_name swap_depth
    local -a names=() depths=()
    # The enlisted set is FT_REPAIR now, not FT_DIRTY — the repair says "your cells were painted
    # over", which is the claim ft_draw_one can answer from the retained block. Reading the wrong
    # set here would capture a ground with nothing in it but the refill.
    for name in "${!FT_REPAIR[@]}"; do
        names+=("$name"); _ft_depth "$name"; depths+=("$FT_RET")
    done
    for (( i=1; i<${#names[@]}; i++ )); do          # ancestors before descendants
        swap_name=${names[i]}; swap_depth=${depths[i]}; j=$(( i-1 ))
        while (( j >= 0 )) && (( depths[j] > swap_depth )); do
            names[j+1]=${names[j]}; depths[j+1]=${depths[j]}; (( j-- ))
        done
        names[j+1]=$swap_name; depths[j+1]=$swap_depth
    done
    for name in "${names[@]}"; do ft_draw_one "$name"; done
    _ft_composite_overlays
    ft_clip_band_reset
    FT_DAMAGE_NARROW=$was_narrow
    FT_DIRTY=(); for name in "${was_dirty[@]}"; do FT_DIRTY[$name]=1; done
    FT_REPAIR=(); for name in "${was_repair[@]}"; do FT_REPAIR[$name]=1; done
    FT_RET=$FT_OUT; FT_OUT=$saved_output
}

# ── Bytes → pieces ───────────────────────────────────────────────────────────
# The framework keeps no cell buffer (the span renderer of docs/rendering-spans.md is a
# design, not code), so what a layer looks like cannot be looked up. But the bytes we emit
# ARE the answer and their escape vocabulary is ours and tiny: CUP, SGR, text. Each text
# chunk becomes one piece, clipped to the rect, with columns relative to its left edge.
declare -a _FT_PIECE_ROW=() _FT_PIECE_COLUMN=() _FT_PIECE_WIDTH=() \
           _FT_PIECE_TEXT=() _FT_PIECE_STYLE=()
_FT_PIECE_COUNT=0
# A pen transition is a pure function of (pen before, parameters), and a repaired region is
# a hundred-odd chunks of which most repeat a colour the pen has already seen — so remember
# the pair rather than re-splitting and re-decoding it.
declare -A _FT_PEN_NEXT=() _FT_PEN_STYLE=()
_ft_transition_parse() {        # bytes top left bottom right
    local stream=$1 top=$2 left=$3 bottom=$4 right=$5
    local foreground=$FT_TRANSITION_GROUND_FG background=$FT_TRANSITION_GROUND_BG
    local bold=0 underline=0 reverse=0
    local style="$foreground|$background|"
    local pen="$foreground|$background|000"
    _FT_PEN_STYLE[$pen]=$style
    _FT_PIECE_ROW=(); _FT_PIECE_COLUMN=(); _FT_PIECE_WIDTH=()
    _FT_PIECE_TEXT=(); _FT_PIECE_STYLE=(); _FT_PIECE_COUNT=0
    local row=0 column=0 width first last cut key next flags rest_of_pen
    local chunk rest params final text
    local -a chunks=()
    local IFS=$'\e'
    set -f; chunks=($stream); set +f
    IFS=$' \t\n'
    local total=${#chunks[@]} index
    for (( index=0; index<total; index++ )); do
        chunk=${chunks[index]}
        (( ${#chunk} == 0 )) && continue
        text=$chunk
        if [[ "$chunk" == \[* ]]; then
            rest=${chunk:1}
            params=${rest%%[a-zA-Z]*}
            final=${rest:${#params}:1}
            text=${rest:$(( ${#params} + 1 ))}
            if [[ "$final" == H ]]; then
                if [[ "$params" == *\;* ]]; then
                    row=$(( ${params%%;*} - 1 )); column=$(( ${params#*;} - 1 ))
                else row=$(( ${params:-1} - 1 )); column=0; fi
            elif [[ "$final" == m && "$params" != [\<\=\>?]* ]]; then
                key="$pen"$'\x1f'"$params"
                next=${_FT_PEN_NEXT[$key]:-}
                if [[ -z "$next" ]]; then
                    local -a codes=(); local outer_ifs=$IFS; IFS=';'; set -f
                    codes=(${params:-0}); set +f; IFS=$outer_ifs
                    local k count=${#codes[@]} code kind value
                    for (( k=0; k<count; k++ )); do
                        code=${codes[k]:-0}
                        case "$code" in
                            0)  foreground=$FT_TRANSITION_GROUND_FG; background=$FT_TRANSITION_GROUND_BG
                                bold=0; underline=0; reverse=0 ;;
                            1)  bold=1 ;;  2) bold=0 ;;  4) underline=1 ;;  7) reverse=1 ;;
                            22) bold=0 ;; 24) underline=0 ;; 27) reverse=0 ;;
                            38|48) kind=${codes[k+1]:-}; value=""
                                if [[ "$kind" == 5 ]]; then
                                    _ft_transition_index_rgb "${codes[k+2]:-0}"; value=$FT_RET; (( k += 2 ))
                                elif [[ "$kind" == 2 ]]; then
                                    value="${codes[k+2]:-0},${codes[k+3]:-0},${codes[k+4]:-0}"; (( k += 4 ))
                                else (( k += 1 )); fi
                                if [[ -n "$value" ]]; then
                                    if [[ "$code" == 38 ]]; then foreground=$value; else background=$value; fi
                                fi ;;
                            39) foreground=$FT_TRANSITION_GROUND_FG ;;
                            49) background=$FT_TRANSITION_GROUND_BG ;;
                            3[0-7])  _ft_transition_index_rgb $(( code - 30 ));      foreground=$FT_RET ;;
                            4[0-7])  _ft_transition_index_rgb $(( code - 40 ));      background=$FT_RET ;;
                            9[0-7])  _ft_transition_index_rgb $(( code - 90 + 8 ));  foreground=$FT_RET ;;
                            10[0-7]) _ft_transition_index_rgb $(( code - 100 + 8 )); background=$FT_RET ;;
                        esac
                    done
                    next="$foreground|$background|$bold$underline$reverse"
                    # REVERSE VIDEO IS A COLOUR SWAP, and it must be resolved here: the
                    # attribute palette uses it heavily, and a cell whose fg/bg are recorded
                    # unswapped blends toward the wrong end and inverts halfway through.
                    if (( reverse )); then style="$background|$foreground|"
                    else                    style="$foreground|$background|"; fi
                    (( bold )) && style+='1'; (( underline )) && style+='4'
                    _FT_PEN_NEXT[$key]=$next; _FT_PEN_STYLE[$next]=$style
                    pen=$next
                else
                    pen=$next; style=${_FT_PEN_STYLE[$next]}
                    foreground=${next%%|*}; rest_of_pen=${next#*|}
                    background=${rest_of_pen%%|*}; flags=${rest_of_pen#*|}
                    bold=${flags:0:1}; underline=${flags:1:1}; reverse=${flags:2:1}
                fi
            fi
        fi
        (( ${#text} == 0 )) && continue
        _ft_transition_width "$text"; width=$FT_RET
        if (( row >= top && row <= bottom )); then
            first=$column; last=$(( column + width - 1 ))
            if (( last >= left && first <= right )); then
                cut=0
                if (( first < left )); then cut=$(( left - first )); first=$left; fi
                (( last > right )) && last=$right
                _ft_transition_slice "$text" "$width" "$cut" $(( last - first + 1 ))
                # rows AND columns relative to the rect — every consumer indexes from its
                # top-left, and an absolute row here silently addressed row_pieces past the
                # end of the rect: half the layer vanished and the other half painted four
                # rows low.
                _FT_PIECE_ROW[_FT_PIECE_COUNT]=$(( row - top ))
                _FT_PIECE_COLUMN[_FT_PIECE_COUNT]=$(( first - left ))
                _FT_PIECE_WIDTH[_FT_PIECE_COUNT]=$(( last - first + 1 ))
                _FT_PIECE_TEXT[_FT_PIECE_COUNT]=$FT_RET
                _FT_PIECE_STYLE[_FT_PIECE_COUNT]=$style
                (( _FT_PIECE_COUNT++ ))
            fi
        fi
        (( column += width ))
    done
}

# ── Pieces → the row's final spans ───────────────────────────────────────────
# Later paint wins where pieces overlap. Walked BACKWARDS with a set of claimed columns,
# which is the one order that never has to rewrite what is already stored: the newest piece
# is unobstructed, and each older one is clipped to what nothing above it has taken.
declare -a _FT_SPAN_COLUMN=() _FT_SPAN_WIDTH=() _FT_SPAN_TEXT=() _FT_SPAN_STYLE=() \
           _FT_SPAN_ROW_START=() _FT_SPAN_ROW_COUNT=()
_ft_transition_resolve() {      # height (rows are indexed relative to the rect's top)
    local height=$1
    local -a row_pieces=()
    local i row
    for (( row=0; row<height; row++ )); do row_pieces[row]=""; done
    for (( i=0; i<_FT_PIECE_COUNT; i++ )); do
        row=${_FT_PIECE_ROW[i]}; row_pieces[row]+="$i "
    done
    _FT_SPAN_COLUMN=(); _FT_SPAN_WIDTH=(); _FT_SPAN_TEXT=(); _FT_SPAN_STYLE=()
    _FT_SPAN_ROW_START=(); _FT_SPAN_ROW_COUNT=()
    local out=0 piece count start end k claim_count j
    local -a indices=() claim_start=() claim_end=()
    local fragment_start fragment_end row_first a t_column t_width t_text t_style
    for (( row=0; row<height; row++ )); do
        _FT_SPAN_ROW_START[row]=$out
        indices=(${row_pieces[row]})
        count=${#indices[@]}
        claim_start=(); claim_end=(); claim_count=0
        for (( k=count-1; k>=0; k-- )); do
            piece=${indices[k]}
            start=${_FT_PIECE_COLUMN[piece]}
            end=$(( start + _FT_PIECE_WIDTH[piece] - 1 ))
            fragment_start=$start
            for (( j=0; j<claim_count; j++ )); do
                (( claim_end[j] < fragment_start )) && continue
                (( claim_start[j] > end )) && break
                if (( claim_start[j] > fragment_start )); then
                    fragment_end=$(( claim_start[j] - 1 )); (( fragment_end > end )) && fragment_end=$end
                    _ft_transition_slice "${_FT_PIECE_TEXT[piece]}" "${_FT_PIECE_WIDTH[piece]}" \
                        $(( fragment_start - start )) $(( fragment_end - fragment_start + 1 ))
                    _FT_SPAN_COLUMN[out]=$fragment_start
                    _FT_SPAN_WIDTH[out]=$(( fragment_end - fragment_start + 1 ))
                    _FT_SPAN_TEXT[out]=$FT_RET; _FT_SPAN_STYLE[out]=${_FT_PIECE_STYLE[piece]}
                    (( out++ ))
                fi
                (( claim_end[j] + 1 > fragment_start )) && fragment_start=$(( claim_end[j] + 1 ))
                (( fragment_start > end )) && break
            done
            if (( fragment_start <= end )); then
                _ft_transition_slice "${_FT_PIECE_TEXT[piece]}" "${_FT_PIECE_WIDTH[piece]}" \
                    $(( fragment_start - start )) $(( end - fragment_start + 1 ))
                _FT_SPAN_COLUMN[out]=$fragment_start
                _FT_SPAN_WIDTH[out]=$(( end - fragment_start + 1 ))
                _FT_SPAN_TEXT[out]=$FT_RET; _FT_SPAN_STYLE[out]=${_FT_PIECE_STYLE[piece]}
                (( out++ ))
            fi
            _ft_transition_claim "$start" "$end"
            claim_count=$_FT_CLAIM_COUNT
            claim_start=("${_FT_CLAIM_START[@]}"); claim_end=("${_FT_CLAIM_END[@]}")
        done
        row_first=${_FT_SPAN_ROW_START[row]}
        for (( a=row_first+1; a<out; a++ )); do          # by column; a row holds a handful
            t_column=${_FT_SPAN_COLUMN[a]}; t_width=${_FT_SPAN_WIDTH[a]}
            t_text=${_FT_SPAN_TEXT[a]}; t_style=${_FT_SPAN_STYLE[a]}; j=$(( a-1 ))
            while (( j >= row_first )) && (( _FT_SPAN_COLUMN[j] > t_column )); do
                _FT_SPAN_COLUMN[j+1]=${_FT_SPAN_COLUMN[j]}; _FT_SPAN_WIDTH[j+1]=${_FT_SPAN_WIDTH[j]}
                _FT_SPAN_TEXT[j+1]=${_FT_SPAN_TEXT[j]};     _FT_SPAN_STYLE[j+1]=${_FT_SPAN_STYLE[j]}
                (( j-- ))
            done
            _FT_SPAN_COLUMN[j+1]=$t_column; _FT_SPAN_WIDTH[j+1]=$t_width
            _FT_SPAN_TEXT[j+1]=$t_text;     _FT_SPAN_STYLE[j+1]=$t_style
        done
        _FT_SPAN_ROW_COUNT[row]=$(( out - row_first ))
        # the claim set belongs to one row only
        _FT_CLAIM_START=(); _FT_CLAIM_END=(); _FT_CLAIM_COUNT=0
    done
}
# Merge [start..end] into the claimed set, keeping it sorted and disjoint. Extracted because
# the inner search does not belong four levels deep inside _ft_transition_resolve.
declare -a _FT_CLAIM_START=() _FT_CLAIM_END=()
_FT_CLAIM_COUNT=0
_ft_transition_claim() {        # start end
    local start=$1 end=$2 j placed=0 out=0
    local -a merged_start=() merged_end=()
    for (( j=0; j<_FT_CLAIM_COUNT; j++ )); do
        if (( _FT_CLAIM_END[j] + 1 < start )); then
            merged_start[out]=${_FT_CLAIM_START[j]}; merged_end[out]=${_FT_CLAIM_END[j]}; (( out++ ))
        elif (( _FT_CLAIM_START[j] > end + 1 )); then
            if (( ! placed )); then merged_start[out]=$start; merged_end[out]=$end; (( out++, placed=1 )); fi
            merged_start[out]=${_FT_CLAIM_START[j]}; merged_end[out]=${_FT_CLAIM_END[j]}; (( out++ ))
        else
            (( _FT_CLAIM_START[j] < start )) && start=${_FT_CLAIM_START[j]}
            (( _FT_CLAIM_END[j]   > end   )) && end=${_FT_CLAIM_END[j]}
        fi
    done
    (( ! placed )) && { merged_start[out]=$start; merged_end[out]=$end; (( out++ )); }
    _FT_CLAIM_START=("${merged_start[@]}"); _FT_CLAIM_END=("${merged_end[@]}"); _FT_CLAIM_COUNT=$out
}

# ── The two layers → transition runs ─────────────────────────────────────────
# A run is a stretch of one row over which BOTH layers hold one style, so every cell in it
# blends identically. Runs that share a style PAIR share a blend class, and the colour
# arithmetic is done per class per frame — six classes, not 320 cells.
declare -a _FT_RUN_PREFIX=() _FT_RUN_CLASS=() _FT_RUN_TEXT_FROM=() _FT_RUN_TEXT_TO=()
declare -a _FT_CLASS_FG_FROM=() _FT_CLASS_BG_FROM=() _FT_CLASS_ATTR_FROM=() \
           _FT_CLASS_FG_TO=()   _FT_CLASS_BG_TO=()   _FT_CLASS_ATTR_TO=()
declare -A _FT_CLASS_ID=()
_FT_RUN_COUNT=0
_FT_CLASS_COUNT=0
declare -a _FT_GROUND_COLUMN=() _FT_GROUND_WIDTH=() _FT_GROUND_TEXT=() _FT_GROUND_STYLE=() \
           _FT_GROUND_ROW_START=() _FT_GROUND_ROW_COUNT=()
# OWNER FIRST, AND IT IS NOT OPTIONAL. These arrays are shared by every transition, and the
# live path decides whether to skip a ~90ms ground re-read by asking whether they still
# describe it (_FT_TRANSITION_RUNS_OWNER). That tag used to be stamped on the live route only,
# so ARMING a second transition rebuilt the arrays and left the tag naming the first: the
# first control's next yielded frame passed the guard and emitted the second control's texts
# at the second control's cursor addresses — a frame for A painted wholly inside B. Taking the
# owner as a parameter is what makes "rebuild without re-stamping" unwriteable, rather than
# something every future caller has to remember.
_ft_transition_runs() {         # owner top left height width
    local owner=$1 top=$2 left=$3 height=$4 width=$5
    _FT_TRANSITION_RUNS_OWNER=$owner
    _FT_RUN_PREFIX=(); _FT_RUN_CLASS=(); _FT_RUN_TEXT_FROM=(); _FT_RUN_TEXT_TO=()
    _FT_CLASS_FG_FROM=(); _FT_CLASS_BG_FROM=(); _FT_CLASS_ATTR_FROM=()
    _FT_CLASS_FG_TO=();   _FT_CLASS_BG_TO=();   _FT_CLASS_ATTR_TO=()
    _FT_CLASS_ID=(); _FT_RUN_COUNT=0; _FT_CLASS_COUNT=0
    local row ground top_index ground_end top_end start end key id
    local last_row=-1 last_end=-1 screen_row screen_column
    local ground_style ground_text top_style top_text
    for (( row=0; row<height; row++ )); do
        ground=${_FT_GROUND_ROW_START[row]}; top_index=${_FT_SPAN_ROW_START[row]}
        ground_end=$(( ground + _FT_GROUND_ROW_COUNT[row] ))
        top_end=$(( top_index + _FT_SPAN_ROW_COUNT[row] ))
        start=0
        while (( start < width )); do
            while (( ground < ground_end )) && (( _FT_GROUND_COLUMN[ground] + _FT_GROUND_WIDTH[ground] <= start )); do (( ground++ )); done
            while (( top_index < top_end )) && (( _FT_SPAN_COLUMN[top_index] + _FT_SPAN_WIDTH[top_index] <= start )); do (( top_index++ )); done
            end=$width
            if (( ground < ground_end )); then
                if (( _FT_GROUND_COLUMN[ground] > start )); then (( _FT_GROUND_COLUMN[ground] < end )) && end=${_FT_GROUND_COLUMN[ground]}
                else (( _FT_GROUND_COLUMN[ground] + _FT_GROUND_WIDTH[ground] < end )) && end=$(( _FT_GROUND_COLUMN[ground] + _FT_GROUND_WIDTH[ground] )); fi
            fi
            if (( top_index < top_end )); then
                if (( _FT_SPAN_COLUMN[top_index] > start )); then (( _FT_SPAN_COLUMN[top_index] < end )) && end=${_FT_SPAN_COLUMN[top_index]}
                else (( _FT_SPAN_COLUMN[top_index] + _FT_SPAN_WIDTH[top_index] < end )) && end=$(( _FT_SPAN_COLUMN[top_index] + _FT_SPAN_WIDTH[top_index] )); fi
            fi
            # A CELL THE INCOMING LAYER DOES NOT PAINT IS NOT IN TRANSITION AT ALL. It keeps
            # whatever is under it and is left out of every frame — which is why a callout
            # with a transparent margin costs nothing for that margin.
            if (( top_index < top_end && _FT_SPAN_COLUMN[top_index] <= start )); then
                top_style=${_FT_SPAN_STYLE[top_index]}
                _ft_transition_slice "${_FT_SPAN_TEXT[top_index]}" "${_FT_SPAN_WIDTH[top_index]}" \
                    $(( start - _FT_SPAN_COLUMN[top_index] )) $(( end - start ))
                top_text=$FT_RET
                if (( ground < ground_end && _FT_GROUND_COLUMN[ground] <= start )); then
                    ground_style=${_FT_GROUND_STYLE[ground]}
                    _ft_transition_slice "${_FT_GROUND_TEXT[ground]}" "${_FT_GROUND_WIDTH[ground]}" \
                        $(( start - _FT_GROUND_COLUMN[ground] )) $(( end - start ))
                    ground_text=$FT_RET
                else
                    ground_style="$FT_TRANSITION_GROUND_FG|$FT_TRANSITION_GROUND_BG|"
                    printf -v ground_text '%*s' $(( end - start )) ''
                fi
                key="$ground_style|$top_style"
                id=${_FT_CLASS_ID[$key]:-}
                if [[ -z "$id" ]]; then
                    id=$_FT_CLASS_COUNT; _FT_CLASS_ID[$key]=$id
                    IFS='|' read -r _FT_CLASS_FG_FROM[id] _FT_CLASS_BG_FROM[id] _FT_CLASS_ATTR_FROM[id] \
                                    _FT_CLASS_FG_TO[id]   _FT_CLASS_BG_TO[id]   _FT_CLASS_ATTR_TO[id] <<< "$key"
                    (( _FT_CLASS_COUNT++ ))
                fi
                screen_row=$(( top + row )); screen_column=$(( left + start ))
                _FT_RUN_CLASS[_FT_RUN_COUNT]=$id
                _FT_RUN_TEXT_FROM[_FT_RUN_COUNT]=$ground_text
                _FT_RUN_TEXT_TO[_FT_RUN_COUNT]=$top_text
                # a run that continues where the last one ended needs no cursor address
                if (( screen_row == last_row && screen_column == last_end )); then
                    _FT_RUN_PREFIX[_FT_RUN_COUNT]=''
                else
                    printf -v _FT_RUN_PREFIX[_FT_RUN_COUNT] '\e[%d;%dH' $(( screen_row+1 )) $(( screen_column+1 ))
                fi
                last_row=$screen_row; last_end=$(( screen_column + end - start ))
                (( _FT_RUN_COUNT++ ))
            fi
            start=$end
        done
    done
}

# ── The schedule ─────────────────────────────────────────────────────────────
# THE WORKING PLAN, and the per-control store behind it. _FT_TRANSITION_EASED and
# _FT_TRANSITION_CUT_FRAME are scratch: whichever transition armed last owned them both, so
# `ft_transition_cut_frame A` answered with B's cut, and any frame blended after B armed used
# B's curve for A. Measured: A with `600ms linear` (21 frames, cut 10) and B with `300ms
# ease-in-out` (11 frames, cut 5) — asking A after B armed returned 5, and A's frame 5 has
# every run legible where A's real cut frame 10 has none. Same shape as the runs decomposition
# beside it: shared scratch plus per-control truth, loaded before use.
declare -a _FT_TRANSITION_EASED=()
_FT_TRANSITION_CUT_FRAME=0
declare -A _FT_TRANSITION_PLAN=()   # name → its eased curve, space separated
declare -A _FT_TRANSITION_CUT=()    # name → its cut frame index
# Put NAME's plan into the working globals. Every route that blends calls this first, so no
# caller can blend one transition along another's curve.
_ft_transition_load_plan() {    # name → 0 if it had one
    local stored=${_FT_TRANSITION_PLAN[$1]:-}
    [[ -n "$stored" ]] || return 1
    _FT_TRANSITION_EASED=()
    read -r -a _FT_TRANSITION_EASED <<< "$stored"
    _FT_TRANSITION_CUT_FRAME=${_FT_TRANSITION_CUT[$1]:-0}
    return 0
}
# ONE EASING SOLVER FOR THE WHOLE FRAMEWORK. This used to be a private `case` over five
# keywords with hand-rolled quadratics. `ft_ease_table` (ft-forms.bash) is a real cubic-bezier
# solver behind CSS's own `animation-timing-function` surface, so calling it deletes a fork AND
# gives transitions `cubic-bezier(x1,y1,x2,y2)` and the three -back overshoot curves for free.
# It is called ONCE at arm time and returns the whole curve as a table; no frame solves a
# bezier.
#
# OVERSHOOT IS THE INTERESTING PART, and it is why this function does more than call it:
#   · an -back curve returns values BELOW 0 and ABOVE 1000 on purpose, so a blended channel can
#     leave 0..255. Channels are clamped in _ft_transition_blend rather than the curve being
#     clamped here — clamping the curve would throw away the overshoot, which is the effect.
#   · the glyph swap is chosen by FRAME INDEX against the cut, not by re-testing the eased
#     value. A curve that crosses 500 more than once (any cubic-bezier may) would otherwise
#     swap the text back and forth. The swap happens exactly once, at the cut, for every curve.
_ft_transition_plan() {         # frames timingFunction
    local frames=$1 timing=$2 f eased best=0 best_distance=100000 distance
    _FT_TRANSITION_EASED=()
    ft_ease_table "$timing" "$frames"
    read -r -a _FT_TRANSITION_EASED <<< "$FT_RET"
    for (( f=0; f<frames; f++ )); do
        eased=${_FT_TRANSITION_EASED[f]}
        distance=$(( eased > 500 ? eased-500 : 500-eased ))
        (( distance < best_distance )) && { best_distance=$distance; best=$f; }
    done
    # THE CUT MUST BE A FRAME. If nothing lands on 500 the glyph swap happens between two
    # frames that both have contrast — the visible cut this whole schedule exists to hide.
    # Snapping the nearest one moves a colour, not a time: the frame still shows when it was
    # always going to show, so the pacing is unchanged.
    _FT_TRANSITION_EASED[best]=500
    _FT_TRANSITION_CUT_FRAME=$best
}

# ── Blend → ready-to-emit frames ─────────────────────────────────────────────
declare -a _FT_TRANSITION_SGR=()
# CUT_AT is the index, within THIS call's frames, from which the TOP layer's text and
# attributes are shown. It is passed rather than re-derived from the eased value because the
# live path blends one frame at a time and would have no way to know which side it is on — and
# because an overshoot curve may cross 500 more than once, and the glyph must swap exactly once.
_ft_transition_blend() {        # frames schedule slotBase cutAt
    local frames=$1 schedule=$2 slot_base=$3 cut_at=$4
    local class f eased base part
    local from_fg_r from_fg_g from_fg_b from_bg_r from_bg_g from_bg_b
    local to_fg_r to_fg_g to_fg_b to_bg_r to_bg_g to_bg_b
    local fg_r fg_g fg_b bg_r bg_g bg_b
    local mid_bg_r mid_bg_g mid_bg_b mid_fg_r mid_fg_g mid_fg_b
    local half attributes attribute_codes index_background
    _FT_TRANSITION_SGR=()
    for (( class=0; class<_FT_CLASS_COUNT; class++ )); do
        part=${_FT_CLASS_FG_FROM[class]}; from_fg_r=${part%%,*}; part=${part#*,}; from_fg_g=${part%%,*}; from_fg_b=${part#*,}
        part=${_FT_CLASS_BG_FROM[class]}; from_bg_r=${part%%,*}; part=${part#*,}; from_bg_g=${part%%,*}; from_bg_b=${part#*,}
        part=${_FT_CLASS_FG_TO[class]};   to_fg_r=${part%%,*};   part=${part#*,}; to_fg_g=${part%%,*};   to_fg_b=${part#*,}
        part=${_FT_CLASS_BG_TO[class]};   to_bg_r=${part%%,*};   part=${part#*,}; to_bg_g=${part%%,*};   to_bg_b=${part#*,}
        # his schedule's two midpoints are frame-independent, so they are hoisted out
        mid_bg_r=$(( (from_bg_r+to_bg_r)/2 )); mid_bg_g=$(( (from_bg_g+to_bg_g)/2 )); mid_bg_b=$(( (from_bg_b+to_bg_b)/2 ))
        mid_fg_r=$(( (from_fg_r+to_fg_r)/2 )); mid_fg_g=$(( (from_fg_g+to_fg_g)/2 )); mid_fg_b=$(( (from_fg_b+to_fg_b)/2 ))
        base=$(( class * frames ))
        for (( f=0; f<frames; f++ )); do
            eased=${_FT_TRANSITION_EASED[f]}
            if [[ "$schedule" == average ]]; then
                if (( f < cut_at )); then half=$(( eased*2 )); (( half > 1000 )) && half=1000
                    bg_r=$(( from_bg_r + (mid_bg_r-from_bg_r)*half/1000 ))
                    bg_g=$(( from_bg_g + (mid_bg_g-from_bg_g)*half/1000 ))
                    bg_b=$(( from_bg_b + (mid_bg_b-from_bg_b)*half/1000 ))
                    fg_r=$(( from_fg_r + (mid_fg_r-from_fg_r)*half/1000 ))
                    fg_g=$(( from_fg_g + (mid_fg_g-from_fg_g)*half/1000 ))
                    fg_b=$(( from_fg_b + (mid_fg_b-from_fg_b)*half/1000 ))
                else half=$(( (eased-500)*2 )); (( half < 0 )) && half=0
                    bg_r=$(( mid_bg_r + (to_bg_r-mid_bg_r)*half/1000 ))
                    bg_g=$(( mid_bg_g + (to_bg_g-mid_bg_g)*half/1000 ))
                    bg_b=$(( mid_bg_b + (to_bg_b-mid_bg_b)*half/1000 ))
                    fg_r=$(( mid_fg_r + (to_fg_r-mid_fg_r)*half/1000 ))
                    fg_g=$(( mid_fg_g + (to_fg_g-mid_fg_g)*half/1000 ))
                    fg_b=$(( mid_fg_b + (to_fg_b-mid_fg_b)*half/1000 )); fi
            else
                # background: bottom → top across the whole transition, monotonically
                bg_r=$(( from_bg_r + (to_bg_r-from_bg_r)*eased/1000 ))
                bg_g=$(( from_bg_g + (to_bg_g-from_bg_g)*eased/1000 ))
                bg_b=$(( from_bg_b + (to_bg_b-from_bg_b)*eased/1000 ))
                if (( f < cut_at )); then half=$(( eased*2 )); (( half > 1000 )) && half=1000
                    fg_r=$(( from_fg_r + (bg_r-from_fg_r)*half/1000 ))
                    fg_g=$(( from_fg_g + (bg_g-from_fg_g)*half/1000 ))
                    fg_b=$(( from_fg_b + (bg_b-from_fg_b)*half/1000 ))
                else half=$(( (eased-500)*2 )); (( half < 0 )) && half=0
                    fg_r=$(( bg_r + (to_fg_r-bg_r)*half/1000 ))
                    fg_g=$(( bg_g + (to_fg_g-bg_g)*half/1000 ))
                    fg_b=$(( bg_b + (to_fg_b-bg_b)*half/1000 )); fi
            fi
            # EVERY RUN'S ESCAPE STATES THE WHOLE PEN. A frame is a chain of runs with no
            # resets between them, so an escape that set only colours let the previous run's
            # bold run on into this one — the final frame came out bold across a whole title
            # bar and matched no real render. `22;24` first, then what this class wants.
            # AN OVERSHOOT CURVE LEAVES THE GAMUT ON PURPOSE. ease-out-back returns >1000, so
            # a channel lands past its target and has to come back — that IS the punch. The
            # CURVE is never clamped (that would delete the effect); the CHANNEL is, because
            # 38;2;-14;… is not a colour. CSS clamps interpolated colours to the gamut too.
            (( bg_r < 0 )) && bg_r=0; (( bg_r > 255 )) && bg_r=255
            (( bg_g < 0 )) && bg_g=0; (( bg_g > 255 )) && bg_g=255
            (( bg_b < 0 )) && bg_b=0; (( bg_b > 255 )) && bg_b=255
            (( fg_r < 0 )) && fg_r=0; (( fg_r > 255 )) && fg_r=255
            (( fg_g < 0 )) && fg_g=0; (( fg_g > 255 )) && fg_g=255
            (( fg_b < 0 )) && fg_b=0; (( fg_b > 255 )) && fg_b=255
            if (( f < cut_at )); then attributes=${_FT_CLASS_ATTR_FROM[class]}
            else                      attributes=${_FT_CLASS_ATTR_TO[class]}; fi
            attribute_codes='22;24'
            [[ "$attributes" == *1* ]] && attribute_codes+=';1'
            [[ "$attributes" == *4* ]] && attribute_codes+=';4'
            if [[ "$FT_COLOR_MODE" == truecolor ]]; then
                printf -v part '\e[%s;48;2;%d;%d;%d;38;2;%d;%d;%dm' "$attribute_codes" \
                    "$bg_r" "$bg_g" "$bg_b" "$fg_r" "$fg_g" "$fg_b"
            else
                _ft_transition_rgb_to_256 "$bg_r" "$bg_g" "$bg_b"; index_background=$FT_RET
                _ft_transition_rgb_to_256 "$fg_r" "$fg_g" "$fg_b"
                printf -v part '\e[%s;48;5;%d;38;5;%dm' "$attribute_codes" "$index_background" "$FT_RET"
            fi
            _FT_TRANSITION_SGR[base+f]=$part
        done
    done
    local run buffer
    for (( f=0; f<frames; f++ )); do
        buffer=""
        if (( f < cut_at )); then
            for (( run=0; run<_FT_RUN_COUNT; run++ )); do
                buffer+="${_FT_RUN_PREFIX[run]}${_FT_TRANSITION_SGR[_FT_RUN_CLASS[run]*frames+f]}${_FT_RUN_TEXT_FROM[run]}"
            done
        else
            for (( run=0; run<_FT_RUN_COUNT; run++ )); do
                buffer+="${_FT_RUN_PREFIX[run]}${_FT_TRANSITION_SGR[_FT_RUN_CLASS[run]*frames+f]}${_FT_RUN_TEXT_TO[run]}"
            done
        fi
        _FT_TRANSITION_FRAME[slot_base+f]="$buffer$FT_COLOR_RESET"
    done
}

# ── Reading the cascade ──────────────────────────────────────────────────────
# `transition: <property> <duration> <timing-function>` in any order, exactly like CSS's
# shorthand, with the long-hands out-specifying it. The property token is accepted and
# ignored beyond `none`: a terminal has one thing to transition — the cell.
_ft_transition_settings() {     # name → FT_TRANSITION_MS / _TIMING / _SCHEDULE; 1 if none
    FT_TRANSITION_MS=0; FT_TRANSITION_TIMING=ease-in-out
    FT_TRANSITION_SCHEDULE=$FT_TRANSITION_SCHEDULE_DEFAULT
    local shorthand="" token rest
    ft_style "$1" transition; shorthand=$FT_RET
    [[ "$shorthand" == none ]] && return 1
    rest=$shorthand
    # A cubic-bezier() is ONE value with commas and legal internal spaces, so it is lifted out
    # whole before the shorthand is split on whitespace. Splitting first turned
    # `transition: opacity 300ms cubic-bezier(0.34, 1.56, 0.64, 1)` into four unrecognised
    # tokens and silently fell back to the default curve.
    if [[ "$rest" == *cubic-bezier\(*\)* ]]; then
        local before=${rest%%cubic-bezier(*} after=${rest#*cubic-bezier(}
        FT_TRANSITION_TIMING="cubic-bezier(${after%%)*})"
        rest="$before ${after#*)}"
    fi
    for token in $rest; do
        case "$token" in
            linear|ease|ease-in|ease-out|ease-in-out|\
            ease-out-back|ease-in-back|ease-in-out-back) FT_TRANSITION_TIMING=$token ;;
            *[0-9]s|*[0-9]ms) _ft_css_duration_ms "$token"; FT_TRANSITION_MS=$FT_RET ;;
        esac
    done
    ft_style "$1" transitionDuration
    [[ -n "$FT_RET" ]] && { _ft_css_duration_ms "$FT_RET"; FT_TRANSITION_MS=$FT_RET; }
    ft_style "$1" transitionTimingFunction
    [[ -n "$FT_RET" ]] && FT_TRANSITION_TIMING=$FT_RET
    ft_style "$1" --transition-schedule
    [[ "$FT_RET" == average || "$FT_RET" == contrast ]] && FT_TRANSITION_SCHEDULE=$FT_RET
    # A shorthand with no time is still a request to transition — CSS's own initial duration
    # is 0s, but a 0ms transition in a TUI is indistinguishable from not asking for one, and
    # `transition: opacity` reading as "no" would be a trap. Give it the default.
    (( FT_TRANSITION_MS == 0 )) && [[ -n "$shorthand" ]] && FT_TRANSITION_MS=$FT_TRANSITION_DEFAULT_MS
    (( FT_TRANSITION_MS > 0 ))
}

# ── Is anything under this rect animating? ───────────────────────────────────
# Asked of the engine's own registry rather than of a flag we invent: a control that animates
# is in FT_ANIM_PHASE, and its box is in the layout arrays. If one of them overlaps the rect,
# the ground is NOT static and precomputed frames would be stale the moment they are emitted.
_ft_transition_ground_animates() {  # name top left bottom right → 0 if something animates
    local self=$1 top=$2 left=$3 bottom=$4 right=$5 other x y w h
    for other in "${!FT_ANIM_PHASE[@]}"; do
        [[ "$other" == "$self" ]] && continue
        x=${FT_ABSOLUTE_X[$other]:-}; [[ -z "$x" ]] && continue
        y=${FT_ABSOLUTE_Y[$other]:-0}
        w=${FT_MEASURED_WIDTH[$other]:-0}; h=${FT_MEASURED_HEIGHT[$other]:-0}
        (( w < 1 || h < 1 )) && continue
        (( x <= right && x+w-1 >= left && y <= bottom && y+h-1 >= top )) && return 0
    done
    return 1
}

# The transitioning control and everything inside it are one surface: they are hidden from
# the ordinary paint paths and from the ground fill together, and handed back together.
_ft_transition_mark() {         # name
    local n=$1 kid
    _FT_TRANSITION_ACTIVE[$n]=1
    for kid in ${FT_KIDS[$n]:-}; do _ft_transition_mark "$kid"; done
}
_ft_transition_unmark() {       # name
    local n=$1 kid
    unset "_FT_TRANSITION_ACTIVE[$n]"
    for kid in ${FT_KIDS[$n]:-}; do _ft_transition_unmark "$kid"; done
}
# The incoming layer as it will finally look: the control AND its children, parents first, the
# same order and the same draws the real paint would use. (ft_draw_one alone would have
# captured a callout's frame and none of its contents — the box would melt in empty.)
_ft_transition_paint_layer() {  # name
    local n=$1 kid
    _ft_disp "$n"; [[ "$FT_RET" == none ]] && return
    ft_draw_one "$n"
    for kid in ${FT_KIDS[$n]:-}; do _ft_transition_paint_layer "$kid"; done
}

# ── Arming ───────────────────────────────────────────────────────────────────
# INTERNAL. Returns 1 when the cascade asks for no transition (or the control cannot have
# one), which is how both callers decide to let the ordinary paint happen. Nothing outside
# this file calls it: an application changes `display` and the engine arms from there.
_ft_transition_arm() {          # name
    local name=$1
    [[ -n "${FT_TYPE[$name]:-}" ]] || return 1
    [[ -n "${_FT_TRANSITION_ACTIVE[$name]:-}" ]] && return 1
    _ft_transition_settings "$name" || return 1
    local x=${FT_ABSOLUTE_X[$name]:-}
    [[ -z "$x" ]] && return 1
    local y=${FT_ABSOLUTE_Y[$name]:-0}
    local w=${FT_MEASURED_WIDTH[$name]:-0} h=${FT_MEASURED_HEIGHT[$name]:-0}
    (( w < 1 || h < 1 )) && return 1
    local top=$y left=$x bottom=$(( y+h-1 )) right=$(( x+w-1 ))
    (( bottom > FT_ROWS-1 )) && bottom=$(( FT_ROWS-1 ))
    (( right  > FT_COLS-1 )) && right=$(( FT_COLS-1 ))
    (( bottom < top || right < left )) && return 1

    ft_now_ms; local started=$FT_RET
    local mark=$started
    _ft_transition_sample_theme

    # Frame count from the duration. ODD, so a symmetric easing puts a sample exactly on the
    # cut before _ft_transition_plan has to snap one.
    local frames=$(( FT_TRANSITION_MS / FT_TRANSITION_FRAME_MS ))
    (( frames < FT_TRANSITION_MIN_FRAMES )) && frames=$FT_TRANSITION_MIN_FRAMES
    (( frames > FT_TRANSITION_MAX_FRAMES )) && frames=$FT_TRANSITION_MAX_FRAMES
    (( frames % 2 == 0 )) && (( frames++ ))

    # 1. the incoming layer, painted once into a scratch buffer
    local saved_output=$FT_OUT; FT_OUT=""
    _ft_transition_paint_layer "$name"
    local top_bytes=$FT_OUT; FT_OUT=$saved_output
    if (( ${#top_bytes} == 0 )); then return 1; fi

    # 2. from here on the control's cells belong to the transition — AND ITS DESCENDANTS'.
    #    A control's children are part of the thing morphing in; leaving them unmarked let the
    #    damage repair paint a callout's label over its own half-melted box.
    _ft_transition_mark "$name"
    _FT_TRANSITION_RECT[$name]="$top $left $bottom $right"

    [[ -n "${FT_TRANSITION_PROFILE:-}" ]] && { ft_now_ms
        printf 'TR toplayer %sms %sB\n' $(( FT_RET-mark )) "${#top_bytes}" >&2; mark=$FT_RET; }

    # 3. the ground, through the engine's own repair
    _ft_transition_capture_ground "$top" "$left" "$bottom" "$right"
    local ground_bytes=$FT_RET
    [[ -n "${FT_TRANSITION_PROFILE:-}" ]] && { ft_now_ms
        printf 'TR capture  %sms %sB\n' $(( FT_RET-mark )) "${#ground_bytes}" >&2; mark=$FT_RET; }

    local height=$(( bottom-top+1 )) width=$(( right-left+1 ))
    _ft_transition_parse "$ground_bytes" "$top" "$left" "$bottom" "$right"
    _ft_transition_resolve "$height"
    _FT_GROUND_COLUMN=("${_FT_SPAN_COLUMN[@]}");   _FT_GROUND_WIDTH=("${_FT_SPAN_WIDTH[@]}")
    _FT_GROUND_TEXT=("${_FT_SPAN_TEXT[@]}");       _FT_GROUND_STYLE=("${_FT_SPAN_STYLE[@]}")
    _FT_GROUND_ROW_START=("${_FT_SPAN_ROW_START[@]}"); _FT_GROUND_ROW_COUNT=("${_FT_SPAN_ROW_COUNT[@]}")
    [[ -n "${FT_TRANSITION_PROFILE:-}" ]] && { ft_now_ms
        printf 'TR readgnd  %sms %s pieces\n' $(( FT_RET-mark )) "$_FT_PIECE_COUNT" >&2; mark=$FT_RET; }
    _ft_transition_parse "$top_bytes" "$top" "$left" "$bottom" "$right"
    _ft_transition_resolve "$height"
    [[ -n "${FT_TRANSITION_PROFILE:-}" ]] && { ft_now_ms
        printf 'TR readtop  %sms %s pieces\n' $(( FT_RET-mark )) "$_FT_PIECE_COUNT" >&2; mark=$FT_RET; }
    _ft_transition_runs "$name" "$top" "$left" "$height" "$width"
    [[ -n "${FT_TRANSITION_PROFILE:-}" ]] && { ft_now_ms
        printf 'TR runs     %sms %s runs %s classes\n' $(( FT_RET-mark )) "$_FT_RUN_COUNT" "$_FT_CLASS_COUNT" >&2; mark=$FT_RET; }
    FT_TRANSITION_LAST_RUNS=$_FT_RUN_COUNT
    FT_TRANSITION_LAST_CLASSES=$_FT_CLASS_COUNT
    if (( _FT_RUN_COUNT == 0 )); then _ft_transition_unmark "$name"; return 1; fi

    _ft_transition_plan "$frames" "$FT_TRANSITION_TIMING"
    # …and remember it as THIS control's, so arming another cannot take it over
    _FT_TRANSITION_PLAN[$name]="${_FT_TRANSITION_EASED[*]}"
    _FT_TRANSITION_CUT[$name]=$_FT_TRANSITION_CUT_FRAME

    # 4. either precompute the whole thing, or arrange to compute each frame live
    if _ft_transition_ground_animates "$name" "$top" "$left" "$bottom" "$right"; then
        _FT_TRANSITION_LIVE[$name]=$FT_TRANSITION_SCHEDULE
        _FT_TRANSITION_BASE[$name]=-1
    else
        unset "_FT_TRANSITION_LIVE[$name]"
        local slot=$_FT_TRANSITION_NEXT_SLOT
        _FT_TRANSITION_BASE[$name]=$slot
        (( _FT_TRANSITION_NEXT_SLOT += frames ))
        _ft_transition_blend "$frames" "$FT_TRANSITION_SCHEDULE" "$slot" "$_FT_TRANSITION_CUT_FRAME"
    fi
    [[ -n "${FT_TRANSITION_PROFILE:-}" ]] && { ft_now_ms
        printf 'TR blend    %sms %s frames\n' $(( FT_RET-mark )) "$frames" >&2; mark=$FT_RET; }
    _FT_TRANSITION_COUNT[$name]=$frames

    # 5. ride the shared animation loop. Phase is the frame index; phases 1..frames render,
    #    and the engine's own retire-and-dirty at phase frames+1 lays down the real control —
    #    byte-identical to the last frame, so nothing steps.
    ft_anim_start "$name" $(( frames + 1 )) "$FT_TRANSITION_FRAME_MS" 1 0 0
    ft_anim_bind "$name" _ft_transition_frame transition
    ft_now_ms; FT_TRANSITION_LAST_KICKOFF_MS=$(( FT_RET - started ))
    FT_TRANSITION_LAST_FRAME_MS=0
    return 0
}

# ── The public surface ───────────────────────────────────────────────────────
# AN APPLICATION SHOULD NEVER NEED ANY OF THIS. Changing `display` is the whole API:
#
#     ft-modify notice display=block      # transitions in, if the cascade says `transition:`
#     ft-modify notice display=none       # goes away, and the ground repairs itself
#
# — which is how CSS behaves, and it is what demo/transition-demo.bash now contains. What
# follows exists for the two cases that legitimately need more: an app that wants to force a
# transition at a moment of its own choosing, and a test that has to look at the frames.
#
# ft_transition_in NAME — transition NAME into existence over whatever is already there.
# ALWAYS SUCCEEDS: if the cascade asks for no transition it marks NAME dirty and returns 0, so
# the control appears either way. (It used to return 1 in that case, which pushed
# `|| ft_dirty "$n"` onto every call site — a public call that silently does nothing unless
# you remember to write `||` after it is a trap, and the demo was the proof.)
ft_transition_in() {            # name
    _ft_transition_arm "$1" && return 0
    [[ -n "${FT_TYPE[$1]:-}" ]] && ft_dirty_subtree "$1"
    return 0
}
# ft_transition_active NAME — 0 while a transition owns NAME's cells.
ft_transition_active() { [[ -n "${_FT_TRANSITION_ACTIVE[$1]:-}" ]]; }
# ft_transition_live NAME — 0 if it is re-reading the ground every frame (something under it
# animates), 1 if its frames were precomputed.
ft_transition_live() { [[ "${_FT_TRANSITION_BASE[$1]:--1}" == -1 ]] && [[ -n "${_FT_TRANSITION_ACTIVE[$1]:-}" ]]; }
# ft_transition_frame_count NAME → FT_RET (0 if none is running)
ft_transition_frame_count() { FT_RET=${_FT_TRANSITION_COUNT[$1]:-0}; }
# ft_transition_cut_frame NAME → FT_RET = the frame index at which the glyphs are exchanged.
# That frame has zero contrast by construction; it is the one worth looking at.
ft_transition_cut_frame() { FT_RET=${_FT_TRANSITION_CUT[$1]:-0}; }
# ft_transition_frame NAME INDEX → FT_RET = that frame's bytes ("" if there is no such frame,
# or if the transition is on the live path, where frames are computed one at a time).
ft_transition_frame() {         # name index
    local base=${_FT_TRANSITION_BASE[$1]:--1} count=${_FT_TRANSITION_COUNT[$1]:-0}
    if (( base < 0 || $2 < 0 || $2 >= count )); then FT_RET=""; return 1; fi
    FT_RET=${_FT_TRANSITION_FRAME[base+$2]}
}
# ft_transition_rect NAME → FT_RET = "top left bottom right", the cells it owns.
ft_transition_rect() { FT_RET=${_FT_TRANSITION_RECT[$1]:-}; }

# ── The automatic path: display none → visible ───────────────────────────────
# WHAT CSS DOES, AND WHY IT NEEDS SAYING. In a browser a transition runs because a style
# changed and a stylesheet asked for it; nothing is invoked. Transitioning an element that is
# APPEARING is the awkward corner of that model — `display` is a discrete property, and a
# browser needs `transition-behavior: allow-discrete` plus `@starting-style` to describe "and
# here is what it looked like before it existed". A terminal has an answer a browser does not:
# the cells were already showing something, so the starting style is not a declaration, it is
# THE GROUND. That is why there is no @starting-style here and no need for one.
#
# The change is NOTICED in ft-modify and ARMED here, because between those two moments the
# layout has to settle: arming needs the control's final box, and inside an input burst the
# reflow is deferred to ft_reflow_flush. ft_redraw_dirty calls this after that, before it
# paints anything — so the control is already hidden from the paint path when the paint runs.
declare -A _FT_TRANSITION_PENDING=()
ft_transition_pending() { _FT_TRANSITION_PENDING[$1]=1; }
_ft_transition_arm_pending() {
    (( ${#_FT_TRANSITION_PENDING[@]} == 0 )) && return 0
    local -a names=("${!_FT_TRANSITION_PENDING[@]}")
    _FT_TRANSITION_PENDING=()
    local n
    for n in "${names[@]}"; do
        [[ -n "${FT_TYPE[$n]:-}" ]] || continue
        [[ -n "${_FT_TRANSITION_ACTIVE[$n]:-}" ]] && continue
        _ft_disp "$n"; [[ "$FT_RET" == none ]] && continue     # hidden again before we got here
        _ft_transition_arm "$n" || :        # no transition declared → the ordinary paint runs
    done
    return 0
}

# The bound animation routine: one frame. On the precomputed path this is a lookup and an
# append — the whole point. On the live path the ground is re-read every frame, because a
# precomputed frame of an animating ground is a photograph of a moment that has passed.
_ft_transition_frame() {        # name structure
    local name=$1
    local phase=${FT_ANIM_PHASE[$name]:-0}
    local frames=${_FT_TRANSITION_COUNT[$name]:-0}
    (( frames == 0 )) && return 0
    local index=$(( phase - 1 ))
    (( index < 0 )) && index=0
    (( index >= frames )) && index=$(( frames - 1 ))
    local base=${_FT_TRANSITION_BASE[$name]:--1}
    if (( base >= 0 )); then
        FT_OUT+="${_FT_TRANSITION_FRAME[base+index]}"
        return 0
    fi
    # ── live path ──
    ft_now_ms; local started=$FT_RET
    local rect=${_FT_TRANSITION_RECT[$name]}
    set -- $rect; local top=$1 left=$2 bottom=$3 right=$4
    local height=$(( bottom-top+1 )) width=$(( right-left+1 ))
    # A LATE CHARACTER IS WORSE THAN A COARSE FRAME. Re-reading the ground costs ~90ms, and
    # this routine runs from the animation tick, which is exactly the window a keystroke has
    # to wait in — so while the user is actually interacting, the ground is NOT re-read. The
    # run decomposition from the previous frame is reused and only the colours are recomputed
    # (~1ms): the transition keeps moving, an animation underneath it holds still for a frame,
    # and typing does not stutter. FT_LAST_INPUT_MS is stamped by the input layer, so this
    # asks the engine when the user last did something rather than inventing its own signal.
    if (( started - FT_LAST_INPUT_MS < FT_TRANSITION_YIELD_MS )) \
       && [[ "${_FT_TRANSITION_RUNS_OWNER:-}" == "$name" ]]; then
        _ft_transition_blend_one "$name" "$index"
        ft_now_ms; FT_TRANSITION_LAST_FRAME_MS=$(( FT_RET - started ))
        FT_TRANSITION_LAST_YIELDED=1
        return 0
    fi
    FT_TRANSITION_LAST_YIELDED=0
    _ft_transition_capture_ground "$top" "$left" "$bottom" "$right"
    _ft_transition_parse "$FT_RET" "$top" "$left" "$bottom" "$right"
    _ft_transition_resolve "$height"
    _FT_GROUND_COLUMN=("${_FT_SPAN_COLUMN[@]}");   _FT_GROUND_WIDTH=("${_FT_SPAN_WIDTH[@]}")
    _FT_GROUND_TEXT=("${_FT_SPAN_TEXT[@]}");       _FT_GROUND_STYLE=("${_FT_SPAN_STYLE[@]}")
    _FT_GROUND_ROW_START=("${_FT_SPAN_ROW_START[@]}"); _FT_GROUND_ROW_COUNT=("${_FT_SPAN_ROW_COUNT[@]}")
    local saved_output=$FT_OUT; FT_OUT=""
    _ft_transition_unmark "$name"; _ft_transition_paint_layer "$name"; _ft_transition_mark "$name"
    local top_bytes=$FT_OUT; FT_OUT=$saved_output
    _ft_transition_parse "$top_bytes" "$top" "$left" "$bottom" "$right"
    _ft_transition_resolve "$height"
    _ft_transition_runs "$name" "$top" "$left" "$height" "$width"
    _ft_transition_blend_one "$name" "$index"
    ft_now_ms; FT_TRANSITION_LAST_FRAME_MS=$(( FT_RET - started ))
    return 0
}
# One frame from whatever run decomposition is currently loaded. A one-entry plan, so the
# blend loop is the same code the precomputed path uses — there is no second blender to keep
# in step with the first.
_ft_transition_blend_one() {    # name frameIndex
    local name=$1 index=$2
    _ft_transition_load_plan "$name" || :   # blend along THIS control's curve, not the last armed one
    local -a whole_plan=("${_FT_TRANSITION_EASED[@]}")
    _FT_TRANSITION_EASED=("${whole_plan[index]}")
    local slot=$_FT_TRANSITION_NEXT_SLOT        # a scratch slot, reused every live frame
    # one frame, so "which side" collapses to a 0-or-1 cut: 0 = already past it
    local side=1; (( index >= _FT_TRANSITION_CUT_FRAME )) && side=0
    _ft_transition_blend 1 "${_FT_TRANSITION_LIVE[$name]}" "$slot" "$side"
    _FT_TRANSITION_EASED=("${whole_plan[@]}")
    FT_OUT+="${_FT_TRANSITION_FRAME[slot]}"
}

# ft_transition_cancel NAME — stop a transition and let the control paint normally again.
# Called by the engine when the control is removed, and available to an app that wants out.
ft_transition_cancel() {        # name
    [[ -n "${_FT_TRANSITION_ACTIVE[$1]:-}" ]] || return 1
    _ft_transition_retire "$1"
    [[ -n "${FT_ANIM_PHASE[$1]:-}" ]] && ft_anim_stop "$1"
    ft_dirty "$1"
    return 0
}
# Called from ft_anim_stop, which is where every ending arrives: retired normally, cancelled,
# or the control destroyed mid-flight.
_ft_transition_retire() {       # name
    _ft_transition_unmark "$1"
    # GIVE THE FRAME SLOTS BACK. Every transition appends its frames to one flat array and
    # they are dead the moment it ends; a long session that shows a notice a few hundred times
    # would otherwise hold every frame of every one of them. Slots are only truly reclaimed
    # when nothing is armed (a free list would be the general answer, and is not worth it
    # while transitions are this short-lived and this rare).
    local base=${_FT_TRANSITION_BASE[$1]:--1} count=${_FT_TRANSITION_COUNT[$1]:-0} i
    if (( base >= 0 )); then
        for (( i=0; i<count; i++ )); do unset "_FT_TRANSITION_FRAME[base+i]"; done
    fi
    unset "_FT_TRANSITION_BASE[$1]" "_FT_TRANSITION_COUNT[$1]" \
          "_FT_TRANSITION_RECT[$1]" "_FT_TRANSITION_LIVE[$1]" \
          "_FT_TRANSITION_PLAN[$1]" "_FT_TRANSITION_CUT[$1]"
    (( ${#_FT_TRANSITION_ACTIVE[@]} == 0 )) && { _FT_TRANSITION_FRAME=(); _FT_TRANSITION_NEXT_SLOT=0; }
    [[ "${_FT_TRANSITION_RUNS_OWNER:-}" == "$1" ]] && _FT_TRANSITION_RUNS_OWNER=""
    # THE WHOLE SUBTREE, not just the control. Every caller of ft_anim_stop follows it with
    # `ft_dirty NAME`, which repaints the control ALONE — and a frame's draw fills its box, so
    # the real paint that lands after the last blended frame erased the label the transition
    # had just finished melting in. The notices came out empty.
    [[ -n "${FT_TYPE[$1]:-}" ]] && ft_dirty_subtree "$1"
    return 0
}
