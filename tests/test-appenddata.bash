#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  ft_append_data — the DOM's CharacterData.appendData(), and the reason it exists.
#
#  Handing the whole text back on every append (`ft_set log text="$all"`) re-measures
#  and re-wraps everything each time: 543ms to add ONE line to a 1000-line log, O(n²) to
#  fill it. Appending cannot change what came before, so this measures and wraps only the
#  new chunk and folds it into the caches.
#
#  The thing that MUST hold: appending N chunks is indistinguishable — text, extent, wrap,
#  and laid-out geometry — from having set the whole string at once. These tests compare
#  the two paths directly rather than trusting the incremental arithmetic.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_ROWS=24; FT_COLS=60

note "appending equals setting the whole string"
ft-form name=app width=60 height=24
    ft-label name=inc text="" width=30
    ft-label name=whole text="" width=30
end_ft_form
lines=("first line" "second line" "third line that is quite a lot longer than the others")
all=""
for l in "${lines[@]}"; do
    ft_append_data inc "$l"
    all+="${all:+$'\n'}$l"
done
ft_set whole text="$all"
ft_get inc text; inc_text=$FT_RET
check "the text matches exactly" "$inc_text" "$all"

# Extent: the incremental arithmetic vs a fresh measure of the same string.
_ft_text_extent_cached inc "$inc_text";   inc_w=$FT_TEXT_WIDTH; inc_h=$FT_TEXT_HEIGHT
_ft_text_extent "$all";                   raw_w=$FT_TEXT_WIDTH; raw_h=$FT_TEXT_HEIGHT
check "cached width matches a fresh measure"  "$inc_w" "$raw_w"
check "cached height matches a fresh measure" "$inc_h" "$raw_h"

note "the wrap cache is carried forward, not thrown away"
# Warm a slot, append, and confirm the carried-forward rows equal a from-scratch wrap.
ft-label name=wr text="alpha beta gamma" width=12 parent=app
ft_wrap_cached wr "alpha beta gamma" 12
ft_append_data wr "delta epsilon zeta eta theta"
ft_get wr text; wr_text=$FT_RET
ft_wrap_cached wr "$wr_text" 12; carried=("${FT_WRAP_LINES[@]}")
ft_wrap "$wr_text" 12;           fresh=("${FT_WRAP_LINES[@]}")
check "same number of wrapped rows" "${#carried[@]}" "${#fresh[@]}"
same=1; for (( i=0; i<${#fresh[@]}; i++ )); do
    [[ "${carried[$i]}" == "${fresh[$i]}" ]] || same=0
done
check "every wrapped row is identical" "$same" "1"

note "a cold or stale cache is left alone, not corrupted"
ft-label name=cold text="one" width=20 parent=app
ft_append_data cold "two"                 # nothing warmed it first
ft_get cold text; check "text still correct with a cold cache" "$FT_RET" $'one\ntwo'
_ft_text_extent_cached cold "$FT_RET"; cold_h=$FT_TEXT_HEIGHT
_ft_text_extent $'one\ntwo';           check "extent still correct" "$FT_TEXT_HEIGHT" "$cold_h"

# Poison the extent cache, then append: the stale entry must NOT be extended.
ft-label name=stale text="aaa" width=20 parent=app
_ft_text_extent_cached stale "aaa"
printf -v _fti_stale__extkey '%s' "completely different text"
ft_append_data stale "bbbb"
ft_get stale text; stale_text=$FT_RET
_ft_text_extent_cached stale "$stale_text"; got_w=$FT_TEXT_WIDTH; got_h=$FT_TEXT_HEIGHT
_ft_text_extent "$stale_text"
check "a stale extent entry is not extended (width)"  "$got_w" "$FT_TEXT_WIDTH"
check "a stale extent entry is not extended (height)" "$got_h" "$FT_TEXT_HEIGHT"

note "geometry after appending matches geometry after one big set"
ft_remove app 2>/dev/null
ft-form name=app2 width=60 height=24 display=flex flexDirection=column
    ft-label name=g1 text="" width=24
    ft-label name=g2 text="" width=24
end_ft_form
built=""
for l in "alpha" "beta gamma delta epsilon zeta" "eta"; do
    ft_append_data g1 "$l"
    built+="${built:+$'\n'}$l"
done
ft_set g2 text="$built"
ft_layout app2
check "appended label has the same height as the set one" "${FT_MEASURED_HEIGHT[g1]}" "${FT_MEASURED_HEIGHT[g2]}"
check "…and the same width"                               "${FT_MEASURED_WIDTH[g1]}" "${FT_MEASURED_WIDTH[g2]}"

note "appending to a textfield's value works the same way"
ft-textfield name=tf value="line one" rows=3 parent=app2
ft_append_data tf "line two" value
ft_get tf value; check "value appended" "$FT_RET" $'line one\nline two'

note "it refuses what it cannot append to"
ft_append_data nosuchcontrol "x"; check "unknown control returns nonzero" "$?" "1"
ft_append_data g1 ""            ; check "empty append is a no-op, returns 0" "$?" "0"
ft_get g1 text; check "…and changed nothing" "$FT_RET" "$built"

note "insertData / deleteData / replaceData match plain string surgery"
# The oracle is bash's own slicing: whatever ${v:0:o}$d${v:o} produces is the right answer.
ft-form name=capp width=60 height=24
    ft-label name=cd text="" width=40
end_ft_form
oracle=""
set_both() { oracle=$1; ft_set cd text="$1"; }
expect()   { ft_get cd text; check "$1" "$FT_RET" "$oracle"; }

set_both "hello world"
ft_insert_data cd 5 " there"; oracle="hello there world"
expect "insert mid-line"

ft_insert_data cd 0 ">> ";   oracle=">> hello there world"
expect "insert at the very start"

ft_insert_data cd "${#oracle}" " <<"; oracle="$oracle <<"
expect "insert at the very end"

set_both $'alpha\nbeta\ngamma'
ft_insert_data cd 6 "XX"; oracle=$'alpha\nXXbeta\ngamma'
expect "insert at the start of a later line"

ft_insert_data cd 5 $'\ninserted'; oracle=$'alpha\ninserted\nXXbeta\ngamma'
expect "inserting a NEWLINE splits the line"

set_both $'one\ntwo\nthree'
ft_delete_data cd 0 4; oracle=$'two\nthree'
expect "deleting across a newline merges lines"

set_both $'one\ntwo\nthree'
ft_delete_data cd 4 3; oracle=$'one\n\nthree'
expect "deleting a whole line's text leaves the empty line"

set_both "abcdef"
ft_delete_data cd 2 2; oracle="abef"
expect "delete inside one line"

set_both "abcdef"
ft_replace_data cd 1 3 "XYZ"; oracle="aXYZef"
expect "replaceData is delete-then-insert"

set_both $'first\nsecond\nthird'
ft_substring_data cd 6 6; check "substringData reads a range" "$FT_RET" "second"

note "the store and the geometry stay consistent after editing"
set_both $'aaa\nbbb\nccc'
ft_insert_data cd 4 $'X\nY'
ft_get cd text; edited=$FT_RET
ft-label name=cdref text="$edited" width=40 parent=capp
ft_layout capp
check "an edited label measures like a freshly-set one" "${FT_MEASURED_HEIGHT[cd]}" "${FT_MEASURED_HEIGHT[cdref]}"
check "…and the same width"                             "${FT_MEASURED_WIDTH[cd]}" "${FT_MEASURED_WIDTH[cdref]}"

note "editing then appending still works (the store stays authoritative)"
set_both "start"
ft_insert_data cd 0 "A"
ft_append_data cd "appended"
ft_get cd text; check "insert then append" "$FT_RET" $'Astart\nappended'

note "it refuses what it cannot edit"
ft_insert_data nosuch 0 "x"; check "insertData on an unknown control" "$?" "1"
ft_delete_data nosuch 0 1;   check "deleteData on an unknown control" "$?" "1"

summary
