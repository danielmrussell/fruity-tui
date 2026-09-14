#!/usr/bin/env bash
# Unit tests for the 24-bit RGB / colour-depth pipeline in ft-core.bash:
# hex parsing, rgb→256 (cube vs grey), rgb→16/8 nearest, 256→rgb inverse, and
# ft_color_sgr routing per FT_COLOR_MODE.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/ft-core.bash"
ft_setup_glyphs

note "hex parsing (#rgb, #rrggbb, r,g,b)"
ft_parse_rgb "#ff0000"; check "#ff0000 → 255,0,0"  "$FT_RGB_RED,$FT_RGB_GREEN,$FT_RGB_BLUE" "255,0,0"
ft_parse_rgb "#f00";    check "#f00 short → 255,0,0" "$FT_RGB_RED,$FT_RGB_GREEN,$FT_RGB_BLUE" "255,0,0"
ft_parse_rgb "#3aa8ff"; check "#3aa8ff → 58,168,255" "$FT_RGB_RED,$FT_RGB_GREEN,$FT_RGB_BLUE" "58,168,255"
ft_parse_rgb "12,34,56"; check "bare r,g,b" "$FT_RGB_RED,$FT_RGB_GREEN,$FT_RGB_BLUE" "12,34,56"
ft_parse_rgb "#xyz"; check "garbage hex → not OK" "$FT_COLOR_OK" "0"

note "rgb → xterm-256 (cube primaries + grey ramp)"
ft_rgb_to_256 255 0 0;    check "red → 196"     "$FT_RET" "196"
ft_rgb_to_256 0 255 0;    check "green → 46"    "$FT_RET" "46"
ft_rgb_to_256 0 0 255;    check "blue → 21"     "$FT_RET" "21"
ft_rgb_to_256 0 0 0;      check "black → 16"    "$FT_RET" "16"
ft_rgb_to_256 255 255 255;check "white → 231"   "$FT_RET" "231"
ft_rgb_to_256 128 128 128;check "mid grey → 244 (grey ramp beats cube)" "$FT_RET" "244"

note "rgb → base ANSI (nearest of 16 / of 8)"
ft_rgb_to_ansi 255 0 0 16; check "pure red → 9 (bright red)" "$FT_RET" "9"
ft_rgb_to_ansi 0 0 0 16;   check "black → 0"                 "$FT_RET" "0"
ft_rgb_to_ansi 250 250 250 8; check "near-white in 8-mode → 7" "$FT_RET" "7"

note "256 → rgb inverse (cube, grey, base16)"
ft_256_to_rgb 196; check "196 → 255,0,0"      "$FT_RGB_RED,$FT_RGB_GREEN,$FT_RGB_BLUE" "255,0,0"
ft_256_to_rgb 231; check "231 → 255,255,255"  "$FT_RGB_RED,$FT_RGB_GREEN,$FT_RGB_BLUE" "255,255,255"
ft_256_to_rgb 244; check "244 → 128,128,128"  "$FT_RGB_RED,$FT_RGB_GREEN,$FT_RGB_BLUE" "128,128,128"
ft_256_to_rgb 16;  check "16 → 0,0,0"         "$FT_RGB_RED,$FT_RGB_GREEN,$FT_RGB_BLUE" "0,0,0"

note "ft_color_sgr routes by FT_COLOR_MODE"
FT_COLOR_MODE=truecolor
ft_color_sgr "#3aa8ff" 48; check "truecolor bg → 48;2;58;168;255" "$FT_RET" $'\e[48;2;58;168;255m'
FT_COLOR_MODE=256
ft_color_sgr "#ff0000" 38; check "256 fg red → 38;5;196" "$FT_RET" $'\e[38;5;196m'
ft_color_sgr "red" 38;     check "named colour still works → 38;5;1" "$FT_RET" $'\e[38;5;1m'
ft_color_sgr "nonsense" 38; check "unknown colour → empty" "$FT_RET" ""
FT_COLOR_MODE=8
ft_color_sgr "#ff0000" 38; check "8-mode red fg → 31" "$FT_RET" $'\e[31m'

note "ft_detect_color_mode assumes 24-bit on modern terminals (COLORTERM is often unset)"
_detect() { (  unset FT_TRUECOLOR COLORTERM; export TERM="$1"
               [[ -n "$2" ]] && export COLORTERM="$2"; [[ -n "$3" ]] && export FT_TRUECOLOR="$3"
               ft_detect_color_mode; echo "$FT_COLOR_MODE" ) }
check "xterm-256color, no COLORTERM → truecolor (the WSL case we were quantising)" "$(_detect xterm-256color)" "truecolor"
check "plain xterm → truecolor"                    "$(_detect xterm)" "truecolor"
check "COLORTERM=truecolor → truecolor"            "$(_detect xterm truecolor)" "truecolor"
check "TERM=dumb → 8 (no colour)"                  "$(_detect dumb)" "8"
check "TERM=linux (VT console) → 16"               "$(_detect linux)" "16"
check "TERM=xterm-16color → 16"                    "$(_detect xterm-16color)" "16"
check "FT_TRUECOLOR=0 forces 256 back"             "$(_detect xterm-256color '' 0)" "256"
check "FT_TRUECOLOR=1 forces truecolor even on linux" "$(_detect linux '' 1)" "truecolor"

note "CSS colour VALUES: #hex, rgb()/rgba() function form, and extended CSS names"
FT_COLOR_MODE=256      # deterministic index mapping for the assertions
ft_color_sgr "#ff0000" 38;             check "#rrggbb hex → 196"          "$FT_RET" $'\e[38;5;196m'
ft_color_sgr "#0f0" 38;                check "#rgb short hex → 46"        "$FT_RET" $'\e[38;5;46m'
ft_color_sgr "rgb(255, 0, 0)" 38;      check "rgb(r, g, b) → 196"         "$FT_RET" $'\e[38;5;196m'
ft_color_sgr "rgb(0 128 255)" 38;      check "rgb(r g b) space form → 33" "$FT_RET" $'\e[38;5;33m'
ft_color_sgr "rgba(255,255,0,0.5)" 38; check "rgba() ignores alpha → 226" "$FT_RET" $'\e[38;5;226m'
ft_color_sgr "rgb(300,0,0)" 38;        check "out-of-range rgb → empty"   "$FT_RET" ""
ft_color_sgr "rgb(1,2)" 38;            check "too few channels → empty"   "$FT_RET" ""
ft_color_sgr "crimson" 48;             check "extended name crimson (bg) → 161" "$FT_RET" $'\e[48;5;161m'
ft_color_sgr "dodgerblue" 38;          check "extended name dodgerblue → 33"    "$FT_RET" $'\e[38;5;33m'
FT_COLOR_MODE=truecolor
ft_color_sgr "#00afff" 38;             check "hex in truecolor → 24-bit"  "$FT_RET" $'\e[38;2;0;175;255m'
ft_color_sgr "rgb(64, 200, 90)" 38;    check "rgb() in truecolor → 24-bit" "$FT_RET" $'\e[38;2;64;200;90m'

note "hsl()/hsla() colour functions (converted to RGB, then the depth pipeline)"
ft_color_sgr "hsl(0, 100%, 50%)" 38;      check "hsl red → 255,0,0"        "$FT_RET" $'\e[38;2;255;0;0m'
ft_color_sgr "hsl(120, 100%, 50%)" 38;    check "hsl green → 0,255,0"      "$FT_RET" $'\e[38;2;0;255;0m'
ft_color_sgr "hsl(240, 100%, 50%)" 38;    check "hsl blue → 0,0,255"       "$FT_RET" $'\e[38;2;0;0;255m'
ft_color_sgr "hsl(0, 0%, 50%)" 38;        check "hsl gray → 127,127,127"   "$FT_RET" $'\e[38;2;127;127;127m'
ft_color_sgr "hsl(60 100 50)" 38;         check "hsl space form, no % → yellow" "$FT_RET" $'\e[38;2;255;255;0m'
ft_color_sgr "hsla(300,100%,50%,0.5)" 48; check "hsla ignores alpha (bg) → magenta" "$FT_RET" $'\e[48;2;255;0;255m'
FT_COLOR_MODE=256
ft_color_sgr "hsl(0,100%,50%)" 38;        check "hsl red → 196 in 256 mode" "$FT_RET" $'\e[38;5;196m'

# ── ft_rgb_to_256 is memoised ────────────────────────────────────────────────
# Pure arithmetic on three numbers, asked once per themed cell per frame in
# 256-colour mode. The table must answer exactly what the arithmetic answered —
# so the arithmetic is kept here, verbatim, and the two are swept against each
# other. (The same shape as tests/test-charwidth.bash, for the same reason.)
note "ft_rgb_to_256 memo == the arithmetic it replaces"

_ref_rgb_to_256() {             # the pre-memo body, verbatim
    local r=$1 g=$2 b=$3 lr lg lb cr cg cb cd gi gv gd
    _ft_cube6 "$r"; lr=$FT_RET; _ft_cubeval "$lr"; cr=$FT_RET
    _ft_cube6 "$g"; lg=$FT_RET; _ft_cubeval "$lg"; cg=$FT_RET
    _ft_cube6 "$b"; lb=$FT_RET; _ft_cubeval "$lb"; cb=$FT_RET
    cd=$(( (r-cr)*(r-cr) + (g-cg)*(g-cg) + (b-cb)*(b-cb) ))
    local avg=$(( (r+g+b)/3 ))
    gi=$(( (avg - 8 + 5) / 10 )); (( gi < 0 )) && gi=0; (( gi > 23 )) && gi=23
    gv=$(( 8 + 10*gi ))
    gd=$(( (r-gv)*(r-gv) + (g-gv)*(g-gv) + (b-gv)*(b-gv) ))
    if (( gd < cd )); then _REF256=$(( 232 + gi )); else _REF256=$(( 16 + 36*lr + 6*lg + lb )); fi
}

# Every cube level boundary in each channel, the whole grey ramp, and a stride
# through the cube — the cube/grey tie-break is the part with an edge in it.
_diff=0; _n=0; _first=""
_LEVELS=(0 1 47 48 49 114 115 116 135 154 155 156 194 195 196 214 215 216 254 255)
for r in "${_LEVELS[@]}"; do
  for g in 0 55 95 128 175 215 255; do
    for b in 0 47 95 135 195 255; do
        ft_rgb_to_256 "$r" "$g" "$b"; _got=$FT_RET
        _ref_rgb_to_256 "$r" "$g" "$b"
        (( _n++ ))
        if [[ "$_got" != "$_REF256" ]]; then
            (( _diff++ )); [[ -z "$_first" ]] && _first="$r,$g,$b: $_got vs $_REF256"
        fi
    done
  done
done
for v in {0..255}; do           # the grey diagonal, where cube and ramp compete
    ft_rgb_to_256 "$v" "$v" "$v"; _got=$FT_RET
    _ref_rgb_to_256 "$v" "$v" "$v"
    (( _n++ ))
    if [[ "$_got" != "$_REF256" ]]; then
        (( _diff++ )); [[ -z "$_first" ]] && _first="grey $v: $_got vs $_REF256"
    fi
done
check "no disagreement over $_n colours" "$_diff${_first:+ ($_first)}" "0"
# Teeth: a sweep that only ever produced cube indices would not test the ramp.
_saw_grey=0; _saw_cube=0
for v in 90 128 160; do ft_rgb_to_256 "$v" "$v" "$v"; (( FT_RET >= 232 )) && _saw_grey=1; done
for c in "255 0 0" "0 128 255"; do ft_rgb_to_256 $c; (( FT_RET >= 16 && FT_RET < 232 )) && _saw_cube=1; done
check "sweep covered both the grey ramp and the cube" "$_saw_grey$_saw_cube" "11"

# Cold == warm, and the table really fills.
_FT_RGB256_MEMO=(); _FT_RGB256_MEMO_N=0
ft_rgb_to_256 58 168 255; _cold=$FT_RET
ft_rgb_to_256 58 168 255; _warm=$FT_RET
check "cold == warm"                      "$_cold/$_warm" "75/75"
check "one entry per distinct colour"     "${#_FT_RGB256_MEMO[@]}" "1"
ft_rgb_to_256 58 168 254
check "a different colour is a new entry" "${#_FT_RGB256_MEMO[@]}" "2"
check "memo is associative"  "$(declare -p _FT_RGB256_MEMO 2>/dev/null | cut -d' ' -f2)" "-A"

# Index 0 never occurs (the cube starts at 16), but a memo that mistook a valid
# answer for an empty miss would still be a bug — so the hit test is on the
# stored string, not on truthiness. Prove a stored value round-trips as itself.
check "stored value is the index, not a flag" "${_FT_RGB256_MEMO[58,168,255]-unset}" "75"

# The cap: unbounded growth on arbitrary RGB input is the one way this table
# could hurt a long-running app. At the cap it drops everything and refills.
( FT_RGB256_MEMO_MAX=64
  _FT_RGB256_MEMO=(); _FT_RGB256_MEMO_N=0
  for i in {0..199}; do ft_rgb_to_256 "$i" $(( (i*7) % 256 )) $(( (i*13) % 256 )); done
  check "table stays under the cap" "$( (( ${#_FT_RGB256_MEMO[@]} <= 64 )) && echo capped || echo "${#_FT_RGB256_MEMO[@]}" )" "capped"
  # …and still answers correctly after a drop.
  ft_rgb_to_256 255 0 0;    _a=$FT_RET
  ft_rgb_to_256 128 128 128; _b=$FT_RET
  check "correct after the table is dropped" "$_a/$_b" "196/244" )

note "colour depth: FT_COLOR_MODE is the whole answer, and the only thing detection writes"
# ft_detect_color_mode used to set a second global beside it, FT_TRUECOLOR_AVAIL, on three of
# its five branches and on none of the others — read by nothing anywhere in the tree. The drift
# a duplicate invites was already real: detect xterm-256color, then TERM=linux, and the flag
# still said "truecolor" while the mode said 16. Rather than name the removed variable, this
# asks the general question — what does detection actually WRITE — so a second shadow of the
# colour depth cannot be added later without this going red.
_saved_term=${TERM:-}; _saved_colorterm=${COLORTERM:-}; _saved_truecolor=${FT_TRUECOLOR:-}
_saved_color_mode=$FT_COLOR_MODE
_detected_mode() {              # term colorterm ft_truecolor → FT_RET
    TERM=$1; COLORTERM=$2; FT_TRUECOLOR=$3
    ft_detect_color_mode
    FT_RET=$FT_COLOR_MODE
}
_detected_mode xterm-256color "" "";          check "xterm-256color → truecolor"   "$FT_RET" truecolor
_detected_mode xterm "" "";                   check "a bare xterm → truecolor too" "$FT_RET" truecolor
_detected_mode linux "" "";                   check "the VT console → 16"          "$FT_RET" 16
_detected_mode xterm-16color "" "";           check "a 16-colour TERM → 16"        "$FT_RET" 16
_detected_mode dumb "" "";                    check "dumb → 8"                     "$FT_RET" 8
_detected_mode "" "" "";                      check "no TERM at all → 8"           "$FT_RET" 8
_detected_mode linux truecolor "";            check "COLORTERM overrides a lesser TERM" "$FT_RET" truecolor
_detected_mode xterm-256color "" 0;           check "FT_TRUECOLOR=0 pins 256"      "$FT_RET" 256
_detected_mode dumb "" 1;                     check "FT_TRUECOLOR=1 forces it on"  "$FT_RET" truecolor
# Every framework global the call changes, by name. One name, and it is the mode.
_colour_depth_writes() {        # → FT_RET = the FT_/_FT_ globals ft_detect_color_mode changed
    local name changed=""
    local -A before=()
    for name in $(compgen -v FT_) $(compgen -v _FT_); do before[$name]=${!name}; done
    ft_detect_color_mode
    for name in $(compgen -v FT_) $(compgen -v _FT_); do
        [[ "${before[$name]-<absent>}" == "${!name}" ]] || changed+="$name "
    done
    FT_RET=${changed% }
}
# Come at it from the LESSER mode: a second flag only shows up in this census on the transition
# that has to raise it. Priming with FT_TRUECOLOR=0 puts any such flag at its "no" value, so the
# detect that follows must raise it — and a census run the other way round would let a flag that
# is merely never LOWERED (which is the drift that had already happened) slip through unseen.
_detected_mode xterm-256color "" 0
check "…primed at the lesser mode" "$FT_RET" 256
TERM=xterm-256color; COLORTERM=""; FT_TRUECOLOR=""
_colour_depth_writes
check "detection writes FT_COLOR_MODE and nothing beside it" "$FT_RET" "FT_COLOR_MODE"
# …and the colour pipeline needs nothing else to emit 24-bit.
FT_COLOR_MODE=truecolor
ft_color_sgr "#3aa8ff" 48;      check "truecolor still emits 24-bit" "$FT_RET" $'\e[48;2;58;168;255m'
TERM=$_saved_term; COLORTERM=$_saved_colorterm; FT_TRUECOLOR=$_saved_truecolor
FT_COLOR_MODE=$_saved_color_mode

summary
