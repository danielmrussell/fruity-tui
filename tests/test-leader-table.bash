#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  THE LEADER CONTRACT, TABULATED — every side, every anchor, every geometry.
#
#  `_ft_beacon_leader_once` decides what line a box gets, and it is the single most
#  bug-prone function in the engine: four separate user-visible defects this month
#  (the line entering the arrowhead sideways; a dragged box routing up through its own
#  box; a line through "Nine po|nts"; a head that vanished) were all one arm of its
#  side `case` disagreeing with the others. Those four arms are now TWO — one per axis,
#  parameterised by a sign — which removes the divergence but concentrates the risk:
#  a change now lands on two sides at once.
#
#  So this pins the whole contract as a TABLE. A box is swept all around a target —
#  every side, aligned and diagonal, overlapping its span, clamped against the screen
#  edges — under every anchor, and each row records what the contract answered:
#  side, arrowhead cell, routed polyline, length, turns, crossings, head-swallowed.
#  Auto placement only ever visits a fraction of these; a DRAG reaches all of them,
#  which is why every one of those four bugs was reported from a drag.
#
#  A diff here is not necessarily a bug — but it is always a DECISION, and it must be
#  looked at rather than absorbed:  bash tests/test-leader-table.bash --accept
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_USE_UTF8=1; FT_COLS=80; FT_ROWS=40

accept=0; [[ "${1:-}" == "--accept" ]] && accept=1
table="$here/tests/leader-table.txt"

# A target in the middle, and obstacles around it — stated here, not taken from a demo, so the
# table is a property of the contract and not of whatever a page happens to look like today.
FT_BEACON_RECT_TOP=18; FT_BEACON_RECT_LEFT=34; FT_BEACON_RECT_BOTTOM=21; FT_BEACON_RECT_RIGHT=46
_ft_obstacles_clear
_ft_obstacle_push 18 34 21 46 "$FT_IMPORTANCE_NORMAL" ""      # the target itself
_ft_obstacle_push 10 10 12 30 "$FT_IMPORTANCE_NORMAL" ""      # something above-left
_ft_obstacle_push 25 50 27 70 "$FT_IMPORTANCE_NORMAL" ""      # something below-right
_ft_obstacle_push 30  5 30 75 "$FT_IMPORTANCE_NORMAL" ""      # a wide strip below

generated=""
# centerCenter is included deliberately: it is the one anchor with its OWN code path (an early
# return that points into the target's middle), so leaving it out would pin nine anchors and
# leave the tenth — the one that is written separately — unguarded.
for anchor in auto topLeft topCenter topRight bottomLeft bottomCenter bottomRight centerLeft centerRight centerCenter; do
    for bt in 2 8 14 18 20 24 30 34; do
        for bl in 0 6 16 28 34 40 48 58 66; do
            bw=18; bh=6
            (( bl + bw - 1 >= FT_COLS )) && continue
            (( bt + bh - 1 >= FT_ROWS )) && continue
            FT_ANCHOR_ROW=0; FT_ANCHOR_COLUMN=0
            _ft_beacon_leader_once "$bt" "$bl" $(( bt+bh-1 )) $(( bl+bw-1 )) 1 0 "$anchor"
            # `xtgt` — cells of the line lying across the TARGET — is recorded because it is
            # priced at _XTGT_COST a cell and was computed in three separate places until they
            # were unified; without it a change to that arithmetic could move a placement while
            # every other column here stayed put.
            printf -v _row '%-13s box=%2s,%2s  side=%-5s head=%2s,%2s len=%-3s turns=%-2s cross=%-4s in=%s xtgt=%-3s poly=[%s]' \
                "$anchor" "$bt" "$bl" "$FT_LEADER_SIDE" "$FT_LEADER_ARROW_ROW" "$FT_LEADER_ARROW_COLUMN" \
                "$FT_LEADER_LENGTH" "$FT_LEADER_TURNS" "$FT_LEADER_CROSSINGS" "$FT_LEADER_HEAD_INSIDE_BOX" "${FT_LEADER_CROSSES_TARGET:-}" "$FT_LEADER_POLYLINE"
            generated+="$_row"$'\n'
        done
    done
done
rows=$(printf '%s' "$generated" | grep -c .)

if (( accept )) || [[ ! -f "$table" ]]; then
    printf '%s' "$generated" > "$table"
    note "recorded $rows rows to tests/leader-table.txt"
    check "the table was recorded" 1 1
else
    if [[ "$generated" == "$(cat "$table")"$'\n' || "$generated" == "$(cat "$table")" ]]; then
        check "the leader contract answers exactly what was recorded ($rows geometries)" 1 1
    else
        check "the leader contract answers exactly what was recorded ($rows geometries)" 0 1
        echo "    first differences (recorded vs now):"
        diff <(cat "$table") <(printf '%s' "$generated") | head -12 | sed 's/^/      /'
        echo "    if this change is intended: bash tests/test-leader-table.bash --accept"
    fi
fi

# …and the contract's own invariants, asserted on every row rather than eyeballed: a drawn line
# never ends inside the box that owns it, and a head is either outside the box or declared
# swallowed. These are the two rules whose breach produced the reported "line through its own
# box" and "the arrowhead disappeared".
bad_head=0
while IFS= read -r _l; do
    [[ -n "$_l" ]] || continue
    _bt=${_l#*box=}; _bt=${_bt%%,*}; _bt=${_bt// /}
    _bl=${_l#*box=}; _bl=${_bl#*,}; _bl=${_bl%% *}
    _hr=${_l#*head=}; _hr=${_hr%%,*}; _hr=${_hr// /}
    _hc=${_l#*head=}; _hc=${_hc#*,}; _hc=${_hc%% *}
    _in=${_l#*in=}; _in=${_in%% *}
    (( _hr >= _bt && _hr <= _bt+5 && _hc >= _bl && _hc <= _bl+17 && _in == 0 )) && (( bad_head++ ))
done <<< "$generated"
check "no row puts an undeclared arrowhead inside its own box" "$bad_head" 0

summary
