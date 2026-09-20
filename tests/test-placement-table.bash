#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  WHERE A CALLOUT LANDS, TABULATED — because nothing else can see it move.
#
#  The placement search prices ~1000 candidates against the obstacle list, keeps a shortlist,
#  and routes a real leader for each finalist. It is the most expensive thing the engine does
#  on a keystroke, and every attempt to make it cheaper is a trade against the quality of the
#  answer. That trade needs a witness.
#
#  IT DID NOT HAVE ONE. Shrinking the finalist pool from 12 to 2 moves 20 of the 50 placements
#  in demo/callout-demo.bash, and tests/test-callout.bash (312 assertions) plus
#  tests/test-burial.bash both stay green through all of it. They assert PROPERTIES — the box
#  is on screen, the text is not buried, the leader leaves the facing edge — and a placement
#  can move a long way without breaking any of them. So the search could be "optimised" into a
#  visibly worse product with a fully green suite, which is the failure mode this file exists
#  to close.
#
#  The scene is stated HERE, not taken from a demo, for the same reason tests/leader-table.txt
#  is: the table should be a property of the contract, not of whatever a page happens to look
#  like today. Placement is asked through ft_beacon_place, the public "where will it go"
#  entry — one search, no frame, the same code a paint runs.
#
#  A diff here is not necessarily a bug, but it is always a DECISION, and it must be looked at
#  rather than absorbed:   bash tests/test-placement-table.bash --accept
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_USE_UTF8=1; FT_COLS=80; FT_ROWS=30

accept=0; [[ "${1:-}" == "--accept" ]] && accept=1
table="$here/tests/placement-table.txt"

# A scene with somewhere to put things and somewhere not to: a header strip, a column of
# controls down the left, a wide footer, and three targets in open ground. Real controls in a
# real layout, so the obstacle list the search sees is the one an app produces.
ft-form name=app width=80 height=30
    ft-label  name=header text="A header strip across the top of the screen" width=76
    ft-div    name=body display=flex gap=2
        ft-div name=sidebar display=flex flexDirection=column gap=1 width=18
            ft-button name=sideA text="Side A"
            ft-button name=sideB text="Side B"
            ft-button name=sideC text="Side C"
        end_ft_div
        ft-div name=middle display=flex flexDirection=column gap=3 width=40
            ft-button name=tgtTop text="Target top"
            ft-button name=tgtMiddle text="Target middle"
            ft-button name=tgtLow text="Target low"
        end_ft_div
    end_ft_div
    ft-label name=footer text="A wide footer strip along the bottom edge" width=76
end_ft_form
ft_layout app
FT_ROOT=app

SHORT="Short note."
MEDIUM="A sentence with enough words in it to need wrapping at most callout widths."
LONG="A much longer explanation that runs on for a while, long enough that the search has to \
choose between a tall narrow box and a short wide one, which is exactly the decision that \
moves when the shortlist changes size."

generated=""
for target in tgtTop tgtMiddle tgtLow sideA footer; do
    for place in auto above below left right; do
        for textname in SHORT MEDIUM LONG; do
            ft_remove probe >/dev/null 2>&1
            ft-beacon name=probe parent=app variant=callout \
                      target="$target" place="$place" anchor=auto \
                      calloutWidth=34 effect=none outset=0 text="${!textname}"
            ft_layout app
            if ft_beacon_place probe >/dev/null 2>&1 && _ft_beacon_placement probe; then
                printf -v _row '%-9s place=%-5s text=%-6s -> side=%-5s box=%2s,%2s..%2s,%2s  %2sx%-2s inner=%-3s lines=%s' \
                    "$target" "$place" "$textname" \
                    "$FT_PLACED_SIDE" "$FT_PLACED_T" "$FT_PLACED_L" "$FT_PLACED_B" "$FT_PLACED_R" \
                    "$FT_PLACED_W" "$FT_PLACED_H" "$FT_PLACED_INNER_W" "$FT_PLACED_LINES"
            else
                printf -v _row '%-9s place=%-5s text=%-6s -> NOT PLACED' "$target" "$place" "$textname"
            fi
            generated+="$_row"$'\n'
        done
    done
done
rows=$(printf '%s' "$generated" | grep -c .)

note "the search answered for every geometry (without this the table can be empty and equal)"
check "every row was produced"       "$rows" "75"
check "…and they are real placements" \
      "$(( $(printf '%s' "$generated" | grep -c 'side=') >= 60 ))" 1
check "…and not all the same answer"  \
      "$(( $(printf '%s' "$generated" | grep -o 'side=[a-z]*' | sort -u | wc -l) > 1 ))" 1

if (( accept )) || [[ ! -f "$table" ]]; then
    printf '%s' "$generated" > "$table"
    note "recorded $rows rows to tests/placement-table.txt"
    check "the table was recorded" 1 1
else
    if [[ "$generated" == "$(cat "$table")"$'\n' || "$generated" == "$(cat "$table")" ]]; then
        check "the placement contract answers exactly what was recorded ($rows geometries)" 1 1
    else
        check "the placement contract answers exactly what was recorded ($rows geometries)" 0 1
        diff <(cat "$table") <(printf '%s' "$generated") | head -20 | sed 's/^/       /'
        printf '       %s\n' "a placement moved. Look at the diff, then: bash tests/test-placement-table.bash --accept"
    fi
fi

summary
