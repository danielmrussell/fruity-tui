#!/usr/bin/env bash
# Unit tests for backgroundColor/color/borderColor: named/numeric resolution
# in ft_color_index, the _ft_color_override escape-building helper (unset →
# no override, invalid → error logged + no override, valid name/number →
# correct 38/48-channel escape), and that the engine classifies colour
# properties as paint-only so changing one repaints without any reflow.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init

note "ft_color_index resolves named colours"
ft_color_index red
check "red -> 1"   "$FT_RET" "1"
check "red -> ok"  "$FT_COLOR_OK" "1"
ft_color_index Orange
check "case-insensitive: Orange -> 214" "$FT_RET" "214"
ft_color_index grey
check "grey (alt spelling) -> 8" "$FT_RET" "8"

note "ft_color_index passes through a raw 0-255 index"
ft_color_index 200
check "200 -> 200"  "$FT_RET" "200"
check "200 -> ok"   "$FT_COLOR_OK" "1"

note "ft_color_index rejects unknown names and out-of-range numbers"
ft_color_index notacolor
check "unknown name -> not ok" "$FT_COLOR_OK" "0"
ft_color_index 999
check "out-of-range number -> not ok" "$FT_COLOR_OK" "0"

note "_ft_color_override: unset property -> no override, no error"
ft-form name=app
ft-label name=l1 parent=app text=hi
ft_errors_clear
_ft_color_override l1 color 38
check "no color set -> empty escape" "$FT_RET" ""
check "no color set -> no error logged" "${#FT_ERRORS[@]}" "0"

note "_ft_color_override: valid named colour -> correct escape"
ft-label name=l2 parent=app text=hi color=green
_ft_color_override l2 color 38
check "color=green -> \\e[38;5;2m" "$FT_RET" $'\e[38;5;2m'

note "_ft_color_override: valid backgroundColor -> correct 48-channel escape"
ft-label name=l3 parent=app text=hi backgroundColor=17
_ft_color_override l3 backgroundColor 48
check "backgroundColor=17 -> \\e[48;5;17m" "$FT_RET" $'\e[48;5;17m'

note "_ft_color_override: invalid colour -> no override, logs an error"
ft-label name=l4 parent=app text=hi color=bogus
ft_errors_clear
_ft_color_override l4 color 38
check "invalid color -> empty escape" "$FT_RET" ""
check "invalid color -> one error logged" "${#FT_ERRORS[@]}" "1"

note "colour properties are engine-classified as paint-only"
ft_prop_kind backgroundColor
check "backgroundColor -> paint" "$FT_RET" "paint"
ft_prop_kind color
check "color -> paint" "$FT_RET" "paint"
ft_prop_kind borderColor
check "borderColor -> paint" "$FT_RET" "paint"

note "colour override composes onto a rendered frame without crashing"
ft-frame name=win parent=app width=20 height=5 title=Test borderColor=orange backgroundColor=navy color=white
ft_layout app
FT_TTY_CAPTURE=$(mktemp)
exec 9>"$FT_TTY_CAPTURE"
FT_TTY=9
ft_redraw_all win
ft_flush
exec 9>&-
# grep for whatever `orange` RESOLVES to in the active colour mode (a true-hex name resolves to
# its real rgb, not a fixed 256 index) — so this doesn't rot when the palette mapping changes.
ft_color_sgr orange 38; oesc=$FT_RET
grep -qF "$oesc" "$FT_TTY_CAPTURE"
check "rendered frame's output contains the resolved orange border-fg ($oesc)" "$?" "0"
rm -f "$FT_TTY_CAPTURE"

note "a value that is NOT a colour must report failure, not stale success"
# ft_color_index's contract is "invalid/empty input → FT_COLOR_OK=0 (FT_RET left stale;
# callers must check FT_COLOR_OK)". An EMPTY name broke it in the worst possible way: bash
# cannot subscript an associative array with "" — `${assoc[]-}` is a "bad array subscript"
# error, which printed to stderr (in a TUI that IS the alt screen) and then left the [[ -n ]]
# taking its TRUE branch, so the caller was told OK=1 with FT_RET holding the PREVIOUS
# caller's value. An unresolved var() or a cleared property produces an empty value routinely.
for bad in "" " " "   " "notacolour" "#12" "#gggggg" "rgb(300,0,0)" "999"; do
    FT_RET="LEFTOVER"; FT_COLOR_OK=1
    ft_color_sgr "$bad" 38
    check "$(printf '%q' "$bad") is refused"            "$FT_COLOR_OK" "0"
    check "…and paints nothing"                         "$FT_RET"      ""
done
# …while the same function still resolves real colours, in every spelling of one.
for good in crimson '#dc143c' 'rgb(220, 20, 60)' 'rgb(220,20,60)' '220,20,60' 'rgb:220,20,60'; do
    FT_RET=""; FT_COLOR_OK=0
    ft_color_sgr "$good" 38
    check "$(printf '%q' "$good") resolves"             "$FT_COLOR_OK" "1"
done
FT_COLOR_MODE=256
ft_color_sgr crimson 38;            _c1=$FT_RET
ft_color_sgr '#dc143c' 38;          _c2=$FT_RET
ft_color_sgr 'rgb(220, 20, 60)' 38; _c3=$FT_RET
check "a NAMED extended colour matches its own hex"     "$_c1" "$_c2"
check "…and its own rgb()"                              "$_c1" "$_c3"

summary
