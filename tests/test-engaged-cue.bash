#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  ENGAGING A CONTROL MUST NOT LOOK LIKE SELECTING ITS TEXT.
#
#  `:engaged { background-color: … }` marks the control that has taken the keys, and it paints
#  the WHOLE element — which for a text box is the ground under the text. Dark shipped a
#  saturated magenta (53 = 95,0,95) against an 8,8,8 well, so stepping into a field made its
#  contents look highlighted. Reported as "the text looks like it's selected".
#
#  The marker is still a background, because three controls — slider, label, list-box select —
#  have no structural cue at all and deleting it would leave them with no engaged indication
#  whatsoever (measured: their poised->engaged frames differ in zero cells without it). What
#  changed is the RULE the value has to obey, and that is what this file pins:
#
#    · it must be a LIFT along the ground's own hue, not a colour,
#    · so it must sit far from the SELECTION band, which is what it was being mistaken for,
#    · while still differing from the ground enough to be seen.
#
#  A hue is what makes a fill read as a highlight, so the distance to the selection band is the
#  assertion that actually encodes the bug report.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_COLS=60; FT_ROWS=16

ft-form name=app width=60 height=16
    ft-textfield name=box value="text a person is reading" size=24 rows=3
end_ft_form
ft_layout app

_rgb_of_index() { ft_256_to_rgb "$1"; RGB_R=$FT_RGB_RED; RGB_G=$FT_RGB_GREEN; RGB_B=$FT_RGB_BLUE; }
_distance() {                   # indexA indexB → FT_RET (euclidean rgb)
    _rgb_of_index "$1"; local ar=$RGB_R ag=$RGB_G ab=$RGB_B
    _rgb_of_index "$2"; local br=$RGB_R bg=$RGB_G bb=$RGB_B
    local sq=$(( (ar-br)*(ar-br) + (ag-bg)*(ag-bg) + (ab-bb)*(ab-bb) ))
    FT_RET=$(awk -v s="$sq" 'BEGIN{printf "%.0f", sqrt(s)}')
}
_saturation() {                 # index → FT_RET (max channel minus min: 0 is neutral grey)
    _rgb_of_index "$1"
    local hi=$RGB_R lo=$RGB_R
    (( RGB_G > hi )) && hi=$RGB_G; (( RGB_B > hi )) && hi=$RGB_B
    (( RGB_G < lo )) && lo=$RGB_G; (( RGB_B < lo )) && lo=$RGB_B
    FT_RET=$(( hi - lo ))
}
_index_of_sgr_bg() {            # sgr → FT_RET (its 256 index, via rgb)
    ft_sgr_rgb "$1" 48 || { FT_RET=""; return 1; }
    ft_rgb_to_256 "$FT_RGB_RED" "$FT_RGB_GREEN" "$FT_RGB_BLUE"
}

for theme in ft-dark ft-light ft-ocean; do
    ft_use_theme "$theme"
    note "$theme"
    ft_style app --engaged-bg; engaged=$FT_RET
    check "the theme names an engaged background" "$(( ${#engaged} > 0 ))" 1

    _index_of_sgr_bg "$FT_COLOR_INPUT"; ground=$FT_RET
    check "…and the well it will paint over is known" "$(( ${#ground} > 0 ))" 1

    _index_of_sgr_bg "$FT_COLOR_SEL"; selection=$FT_RET

    # 1. FAR FROM THE SELECTION. This is the bug report, stated as a number.
    _distance "$engaged" "$selection"; from_selection=$FT_RET
    check "$theme: the engaged tint is nothing like the selection band" \
          "$(( from_selection > 120 ))" 1

    # 2. A LIFT, NOT A COLOUR. A saturated fill behind text reads as a highlight whatever its
    #    hue; the ground's own saturation is the budget, and the marker may not exceed it much.
    _saturation "$ground";  ground_saturation=$FT_RET
    _saturation "$engaged"; engaged_saturation=$FT_RET
    check "$theme: it is no more colourful than the ground it lifts" \
          "$(( engaged_saturation <= ground_saturation + 40 ))" 1

    # 3. …but still visible, or three controls lose their only cue. THERE ARE TWO GROUNDS and
    #    it has to clear both: a text box paints its own well, while a slider, a label and a
    #    list-box sit directly on the form's body. A value tuned against the well alone can
    #    land exactly on the body — the first attempt at this fix chose 234, which IS the dark
    #    theme's body, and slider and label went from a wash to no cue whatsoever.
    _distance "$engaged" "$ground"; from_ground=$FT_RET
    check "$theme: …and still far enough from the well to be seen" \
          "$(( from_ground >= 12 ))" 1
    _index_of_sgr_bg "$FT_COLOR_BODY"; body=$FT_RET
    if [[ -n "$body" ]]; then
        _distance "$engaged" "$body"
        check "$theme: …and from the body, for the controls that sit on it" \
              "$(( FT_RET >= 12 ))" 1
    fi

    # 4. IT MUST NOT COLLIDE WITH THE ACTIVE LINE. Both are backgrounds and both are subtle, so
    #    they stack: the caret's line is drawn ON the engaged ground, and if the two are the same
    #    index the line the caret is on stops standing out in a multi-line field. Caught by
    #    measuring a real frame after the first attempt at this fix set them both to 235.
    _index_of_sgr_bg "$FT_COLOR_ACTIVELINE"; active_line=$FT_RET
    if [[ -n "$active_line" ]]; then
        check "$theme: the engaged tint is not the active line's tint" \
              "$(( engaged != active_line ))" 1
    fi
done

note "the assertions can fail (a value that reads as a highlight must be caught)"
ft_use_theme ft-dark
# 53 is exactly what dark shipped, and what the report was about.
_index_of_sgr_bg "$FT_COLOR_SEL"; selection=$FT_RET
_index_of_sgr_bg "$FT_COLOR_INPUT"; ground=$FT_RET
_saturation "$ground"; ground_saturation=$FT_RET
_saturation 53; shipped_saturation=$FT_RET
check "the old magenta would fail the colourfulness rule" \
      "$(( shipped_saturation <= ground_saturation + 40 ))" 0
_distance 53 "$ground"
check "…and it really was a fill, not a lift (rgb distance from the well)" \
      "$(( FT_RET > 100 ))" 1

summary
