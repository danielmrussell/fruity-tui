#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  The textfield's INCREMENTAL WRAP, gated the only way it can be trusted:
#  after every edit, the patched layout must be BYTE-IDENTICAL to the layout a
#  full rebuild would have produced. A wrap that is merely "close" is a caret
#  that lands on the wrong character and a selection that highlights the wrong
#  cells, so nothing here checks a computed answer — it checks that the fast
#  path and the slow path agree, edit after edit.
#
#  It also re-splits the LINE STORE from the `value` property and compares, so
#  an in-place splice that drifts from the string it is supposed to describe is
#  caught in the same breath.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null

W=24                                    # narrow enough that plenty of lines soft-wrap
ft-form name=app width=40 height=16
    ft-textfield name=ta size=$W rows=10 wrap=true showLineNumbers=true newlineIndicator=true
end_ft_form
ft_layout app
FT_ROOT=app; FT_FOCUS=ta; ft_set ta runlevel=editing

# The layout as one comparable string: every array the draw and the caret map read.
snapshot() {                            # → SNAP
    local IFS='|'
    SNAP="${FT_TEXTFIELD_LINES_TEXT[*]}"$'\n'"${FT_TEXTFIELD_LINES_OFFSET[*]}"$'\n'"${FT_TEXTFIELD_LINES_CONT[*]}"$'\n'
    SNAP+="${FT_TEXTFIELD_LINES_HARD[*]}"$'\n'"${FT_TEXTFIELD_LINES_NUMBER[*]}"$'\n'"${FT_TEXTFIELD_LINES_ROW_COUNT[*]}"
}
# The incremental layout is computed HERE, in the real shell, so each check leaves the patched
# arrays in place and the next edit patches on top of them — the chain is the thing under test.
# The from-scratch rebuild runs in a SUBSHELL precisely so that throwing its state away costs
# nothing: it re-splits the line store from the `value` property, wraps from the top, and has
# no published edit to lean on.
PATCHES=0; REBUILDS=0; HITS=0
agrees() {                              # desc — the two must be identical
    local desc=$1 inc from was=$_FT_TEXTFIELD_LINES_PATCHED waskey=$_FT_TEXTFIELD_LINES_CACHE_KEY
    _ft_textfield_textw ta; _ft_textfield_layout ta "$FT_RET"; snapshot; inc=$SNAP
    if   (( _FT_TEXTFIELD_LINES_PATCHED > was ));      then (( PATCHES++ ))
    elif [[ "$_FT_TEXTFIELD_LINES_CACHE_KEY" == "$waskey" ]]; then (( HITS++ ))     # memoized, nothing recomputed
    else (( REBUILDS++ )); REBUILT+=" $desc"; fi
    from=$( unset "_fti_ta__linesprop" "_fti_ta__linesgen" "_fti_ta__lochintgen"
            _FT_TEXTFIELD_LINES_CACHE_KEY=""; _FT_TEXTFIELD_EDIT_FIELD=""
            _ft_textfield_textw ta; _ft_textfield_layout ta "$FT_RET"; snapshot; printf '%s' "$SNAP" )
    check "$desc" "$inc" "$from"
    local wantlen; ft_get ta value; wantlen=${#FT_RET}
    _ft_textfield_len ta
    (( FT_RET == wantlen )) || check "$desc — nchars drifted" "$FT_RET" "$wantlen"
}
# The store must also still describe the value it is standing in for. (The join lives in its
# own function because `local IFS` is scoped to a FUNCTION, not to a block — anything else
# called afterwards would inherit it.)
_join_store() { local IFS=$'\n'; local -n _L="_fti_ta__lines"; JOINED="${_L[*]}"; }
storeok() {                             # desc
    _join_store; ft_get ta value
    check "$1 — store == value" "$JOINED" "$FT_RET"
}
# The character count is carried through edits by DELTA, never recounted, and the caret clamps
# against it — so if it ever drifts from the real value the caret silently stops at the wrong
# place. Checked after every single edit, not just at the end.
countok() {                             # desc
    local want
    ft_get ta value; want=${#FT_RET}
    _ft_textfield_len ta
    check "$1 — nchars == \${#value}" "$FT_RET" "$want"
}
seed() { ft_set ta value="$1"; FT_TEXTFIELD_CARET[ta]=${2:-0}; _ft_textfield_textw ta; _ft_textfield_layout ta "$FT_RET"; }

SEED=$'the quick brown fox jumps over the lazy dog\nsecond line\n\nfourth line is also quite long indeed\nlast'

note "typing"
seed "$SEED" 0
agrees "insert at the very start"        # (the seed itself, then each edit below)
ft_textfield_insert_char ta A;  agrees "one character at offset 0"
ft_textfield_insert_char ta B;  agrees "a second character, same line"
storeok "after typing"; countok "after typing"
FT_TEXTFIELD_CARET[ta]=${#SEED}
ft_textfield_insert_char ta Z;  agrees "a character at the very end of the document"
ft_textfield_insert_char ta Y;  agrees "another at the end"
storeok "after typing at the end"; countok "after typing at the end"

note "typing that pushes a line over the wrap width"
seed "$(printf 'aaa bbb ccc\nxxx')" 11
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do ft_textfield_insert_char ta " "; ft_textfield_insert_char ta w; done
agrees "line grew from one visual row to several"
storeok "after growing a line"; countok "after growing a line"

note "deleting"
seed "$SEED" 5
ft_textfield_backspace ta;      agrees "backspace inside a line"
ft_textfield_delete ta;         agrees "forward delete inside a line"
FT_TEXTFIELD_CARET[ta]=42
ft_textfield_delete ta;         agrees "forward delete OF a newline (two lines merge)"
storeok "after merging lines"; countok "after merging lines"
FT_TEXTFIELD_CARET[ta]=0
ft_textfield_delete ta;         agrees "delete at offset 0"
ft_textfield_kill_to_end ta;    agrees "kill to end of line (line becomes empty)"
agrees "kill again (no-op)"
storeok "after kills"; countok "after kills"

note "newlines, which SPLIT a logical line"
seed "$SEED" 10
ft_textfield_insert_char ta $'\n'; agrees "a newline typed mid-line"
FT_TEXTFIELD_CARET[ta]=0
ft_textfield_insert_char ta $'\n'; agrees "a newline at the very start"
ft_textfield_doc_end ta
ft_textfield_insert_char ta $'\n'; agrees "a newline at the very end (a new empty last line)"
storeok "after splitting lines"; countok "after splitting lines"

note "pastes and kills that move many lines at once"
seed "$SEED" 12
ft_textfield_paste ta $'one\ntwo\nthree'; agrees "a multi-line paste mid-line"
storeok "after a multi-line paste"; countok "after a multi-line paste"
ft_textfield_paste ta "plain";           agrees "a single-line paste"
FT_TEXTFIELD_CARET[ta]=3; FT_TEXTFIELD_ANCHOR[ta]=40
ft_textfield_backspace ta;               agrees "deleting a selection that spans newlines"
storeok "after deleting a spanning selection"; countok "after deleting a spanning selection"
ft_textfield_kill_to_start ta;           agrees "kill to start of line"

note "undo and redo (they restore the value WITHOUT describing an edit)"
seed "$SEED" 8
ft_textfield_insert_char ta Q; ft_textfield_insert_char ta R
agrees "before undoing"
ft_textfield_undo ta;  agrees "after undo"
ft_textfield_redo ta;  agrees "after redo"
storeok "after undo/redo"; countok "after undo/redo"

note "maxLength clipping (the caller's edit no longer describes what landed)"
seed "short" 5
ft_set ta maxLength=6
ft_textfield_insert_char ta 1; agrees "the character that fits"
ft_textfield_insert_char ta 2; agrees "the character maxLength threw away"
storeok "after clipping"; countok "after clipping"
ft_set ta maxLength=0

note "an empty field, and a value that is nothing but newlines"
seed "" 0
agrees "empty value is one empty row"
ft_textfield_insert_char ta $'\n'; agrees "one newline in an empty field"
seed $'\n\n\n' 0
agrees "three newlines"
ft_textfield_delete ta; agrees "deleting one of them"
storeok "after newline-only edits"; countok "after newline-only edits"

note "wrap=false (each logical line is one visual row, however long)"
ft_set ta wrap=false
seed "$SEED" 4
ft_textfield_insert_char ta X; agrees "typing with wrapping off"
ft_textfield_insert_char ta $'\n'; agrees "a newline with wrapping off"
ft_set ta wrap=true

note "a width change forces the rebuild rather than a patch"
seed "$SEED" 6
ft_textfield_insert_char ta M
_ft_textfield_layout ta 18; snapshot; W18=$SNAP
_FT_TEXTFIELD_LINES_CACHE_KEY=""; _FT_TEXTFIELD_EDIT_FIELD=""; _ft_textfield_layout ta 18; snapshot
check "the same width from scratch matches" "$SNAP" "$W18"
agrees "and the field's own width still agrees afterwards"

note "a second field between edits invalidates the cached layout, not its correctness"
ft-textfield name=tb size=$W rows=6 wrap=true value="another field entirely"
ft_layout app
seed "$SEED" 9
ft_textfield_insert_char ta N
_ft_textfield_textw tb; _ft_textfield_layout tb "$FT_RET"      # steals the single layout slot
agrees "the first field re-derives correctly after the second one used the cache"

note "the DEFERRED value survives things that repoint the store"
# While typing, `value` is not stored at all — the line store is authoritative and the string is
# owed. Anything that replaces the store's contents therefore has to settle that debt first, or
# the only copy of what the user typed goes with the lines.
seed "hello" 5
ft_textfield_insert_char ta '!'
check "the value is deferred while typing" "${_FT_TEXT_STALE[ta]:-none}" "value"
ft_insert_data ta 0 "abc"               # CharacterData works on `text` — a DIFFERENT property
ft_get ta value; check "the typed value survived the repoint" "$FT_RET" "hello!"
ft_get ta text;  check "…and text got what was inserted"      "$FT_RET" "abc"
ft_unset ta text

seed "hello" 5
ft_textfield_insert_char ta '?'
ft_set ta value="replaced"           # a direct write must beat the owed join
ft_get ta value; check "a direct write supersedes the deferred join" "$FT_RET" "replaced"
agrees "and the layout follows the direct write"

note "…and the fast path was actually taken"
# Falling back to a full rebuild is always CORRECT, so every check above would still pass with
# the incremental path removed entirely. This is what says it ran: most edits must have been
# patched. (The rest legitimately rebuild — undo, a maxLength clip, a width change, a second
# field stealing the cache, and the first layout after each seed.)
printf '  %s%d patched · %d memoized · %d rebuilt · %d store-only edits%s\n' \
       "${_H_DIM}" "$PATCHES" "$HITS" "$REBUILDS" "$_FT_TEXTFIELD_APPLIED" "${_H_RESET}"
# Same argument as the patch counter: an edit that falls back to rebuilding the whole value is
# still CORRECT, so every assertion above would pass with _ft_textfield_apply deleted. This says the
# edits actually went through the store and never materialised the document.
ok "edits went through the store, not the whole value" test "$_FT_TEXTFIELD_APPLIED" -ge 20
[[ -n "${REBUILT:-}" ]] && printf '  %srebuilt:%s%s\n' "${_H_DIM}" "$REBUILT" "${_H_RESET}"
ok "most edits re-wrapped only their own lines" test "$PATCHES" -ge 18
# Every rebuild here is one of the KNOWN ones, and each is a case where patching would be
# wrong rather than merely slower:
#   • undo/redo restore a value without describing an edit
#   • a maxLength clip means what landed is not what the caller said it was
#   • ft_set (maxLength=, wrap=) moves the generation on its own
#   • a width change invalidates the wrap outright
#   • a second field owns the single cached layout
#   • SEVERAL edits between two layouts: only the last one is published, so the earlier ones
#     have no cached "before" to patch. A real app redraws per key, so this is a test shape.
ok "nothing else falls back to a full rebuild" test "$REBUILDS" -le 9

summary
