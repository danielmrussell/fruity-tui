#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Tests for per-field undo / redo (controls/ft-textfield.bash).
#
#  Covers: recording at the _ft_textfield_commit chokepoint; typing coalescing into
#  word-ish undo groups; Ctrl+/ undo and Ctrl+R redo; a fresh edit invalidating
#  the redo stack; deletes as their own steps; read-only fields being inert; the
#  Ctrl+/ input token; and history being released on destroy.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=80; FT_ROWS=24

ft-form name=root width=80 height=6
  ft-textfield name=f value=""
end_ft_form
ft_layout root
_val() { ft_resolved_prop "$1" value ""; printf '%s' "$FT_RET"; }
_type() { local n=$1 s=$2 i; for (( i=0; i<${#s}; i++ )); do ft_textfield_insert_char "$n" "${s:i:1}"; done; }
_reset() { _ft_setprop f value ""; FT_TEXTFIELD_CARET[f]=0; _ft_textfield_undo_forget f; }

note "typing coalesces into ONE undo group; undo removes the whole word"
_reset
_type f "hello"
check "the word is typed"                "$(_val f)" "hello"
check "…as a single undo group"          "${FT_TEXTFIELD_UNDO_COUNT[f]:-0}" "1"
ft_textfield_undo f
check "one undo clears the whole word"   "$(_val f)" ""

note "spaces break the group, so undo peels off word-ish chunks"
_reset
_type f "hello world"
check "typed two words"                  "$(_val f)" "hello world"
ft_textfield_undo f; check "undo 1 → drop 'world'"  "$(_val f)" "hello "
ft_textfield_undo f; check "undo 2 → drop the space" "$(_val f)" "hello"
ft_textfield_undo f; check "undo 3 → back to empty"  "$(_val f)" ""
ft_textfield_undo f; check "undo past the bottom is a harmless no-op" "$(_val f)" ""

note "redo re-applies what undo took back, in order"
_reset
_type f "abc"
ft_textfield_undo f; check "undo → empty"       "$(_val f)" ""
ft_textfield_redo f; check "redo → 'abc' again" "$(_val f)" "abc"
ft_textfield_redo f; check "redo past the top is a no-op" "$(_val f)" "abc"

note "a fresh edit after an undo invalidates the redo stack"
_reset
_type f "abc"
ft_textfield_undo f                              # value "" , redo has "abc"
check "redo is armed"                    "${FT_TEXTFIELD_REDO_COUNT[f]:-0}" "1"
_type f "z"                              # a new edit
check "the new edit clears redo"         "${FT_TEXTFIELD_REDO_COUNT[f]:-0}" "0"
ft_textfield_redo f; check "redo now does nothing" "$(_val f)" "z"

note "backspace / delete are each their own undo step"
_reset
_ft_setprop f value "cat"; FT_TEXTFIELD_CARET[f]=3
ft_textfield_backspace f; check "backspace → 'ca'" "$(_val f)" "ca"
ft_textfield_backspace f; check "backspace → 'c'"  "$(_val f)" "c"
ft_textfield_undo f; check "undo restores one delete" "$(_val f)" "ca"
ft_textfield_undo f; check "undo restores the other"  "$(_val f)" "cat"

note "a read-only field never records or applies undo"
ft-textfield name=ro value="frozen" readOnly=true parent=root
ft_textfield_insert_char ro "X"; check "read-only ignores typing" "$(_val ro)" "frozen"
ft_textfield_undo ro;           check "read-only undo is inert"   "$(_val ro)" "frozen"

note "the input layer now delivers Ctrl+/ (0x1f) as the undo token"
_kt() { FT_KTOK=""; printf '%b' "$1" | { _ft_decode_key 0; printf '%s' "$FT_KTOK"; }; }
check "0x1f decodes to CTRL+/" "$(_kt '\x1f')" "CTRL+/"

note "the edit + idle keymaps bind undo/redo"
_binding() { local -n L="_fti_${1}__list"; local e p a; for e in "${L[@]}"; do
    p=${e%%$'\t'*}; a=${e#*$'\t'}; a=${a%%$'\t'*}
    [[ "$p" == "$2" ]] && { printf '%s' "$a"; return; }; done; }
check "edit keymap: Ctrl+/ → undo" "$(_binding ft_keymap_textfield 'CTRL+/')" "ft_textfield_undo"
check "edit keymap: Ctrl+R → redo" "$(_binding ft_keymap_textfield 'CTRL+r')" "ft_textfield_redo"
check "idle keymap: Ctrl+/ → undo" "$(_binding ft_keymap_textfield_idle 'CTRL+/')" "ft_textfield_undo"

note "destroy releases the field's history"
_reset
_type f "keep"
ft_remove f
[[ -z "${FT_TEXTFIELD_UNDO_COUNT[f]:-}" ]] && check "undo depth is gone after destroy" 1 1 || check "undo depth is gone after destroy" 0 1

note "history stores the EDIT, not a copy of the document"
# This is the whole point of the edit-based history: typing one character into a large field
# must cost one character of history, not another copy of the field.
big=""; for i in $(seq 1 400); do big+="line $i of a fairly long document"$'\n'; done
ft-textfield name=bigf value="${big%$'\n'}" rows=5 parent=app
ft_textfield_activate bigf
FT_TEXTFIELD_CARET[bigf]=0
_ft_textfield_type bigf "Z"
_us=$'\x1f'
_k="bigf${_us}$(( ${FT_TEXTFIELD_UNDO_OLDEST_INDEX[bigf]:-0} + ${FT_TEXTFIELD_UNDO_COUNT[bigf]:-0} - 1 ))"
check "the entry records the inserted character"  "${FT_TEXTFIELD_UNDO_INSERTED[$_k]}" "Z"
check "…and deletes nothing"                     "${FT_TEXTFIELD_UNDO_REMOVED[$_k]}" ""
check "…at the caret's offset"                   "${FT_TEXTFIELD_UNDO_OFFSET[$_k]}" "0"
stored=$(( ${#FT_TEXTFIELD_UNDO_INSERTED[$_k]} + ${#FT_TEXTFIELD_UNDO_REMOVED[$_k]} ))
ft_get bigf value; docsize=${#FT_RET}
check "history holds ~1 char, not the whole ${docsize}-char document" \
      "$([[ $stored -lt 10 ]] && echo compact)" "compact"

note "…and undo/redo still round-trip exactly on a large document"
ft_get bigf value; after_type=$FT_RET
ft_textfield_undo bigf; ft_get bigf value; check "undo restores the original" "$FT_RET" "${big%$'\n'}"
ft_textfield_redo bigf; ft_get bigf value; check "redo re-applies the edit"   "$FT_RET" "$after_type"

note "Ctrl+Z is bound to undo — the history worked all along, the KEY never arrived"
# Ctrl+Z is the undo key everywhere outside a terminal, but the tty owns it as the SUSPEND
# character, so the byte never reached the app and the key silently did nothing in a field.
# ft_enter_tty now frees it (`stty susp undef`) and an unclaimed CTRL+z suspends instead.
# A FRESH field: `f` was ft_remove'd earlier in this file, and dispatch can only reach a
# control that is still in the tree — reusing it would have tested nothing.
ft-textfield name=uz size=30 value="" parent=root
ft_layout root
FT_ROOT=root; FT_FOCUS=uz       # dispatch walks from the focused control up to the ROOT form
_ft_textfield_undo_forget uz
_type uz "hello world"
check "typed"                            "$(_val uz)" "hello world"
ft_dispatch_event "CTRL+z" >/dev/null 2>&1
check "Ctrl+Z undid the last group"      "$(_val uz)" "hello "
ft_dispatch_event "CTRL+z" >/dev/null 2>&1
check "Ctrl+Z again"                     "$(_val uz)" "hello"
ft_dispatch_event "CTRL+r" >/dev/null 2>&1
check "Ctrl+R redid it"                  "$(_val uz)" "hello "
# …and, like the emacs Ctrl+/ binding, it works while merely FOCUSED, not only mid-edit.
ft-modify uz runlevel=unfocused
ft_dispatch_event "CTRL+z" >/dev/null 2>&1
check "Ctrl+Z works when only focused"   "$(_val uz)" "hello"
# The tty must actually release the key, or the binding above can never fire on a real
# terminal — and SUSPEND must survive, for every context that is not editing text.
grep -q 'susp undef' "$here/ft-core.bash" \
  && check "the tty frees Ctrl+Z (stty susp undef)" 1 1 \
  || check "the tty frees Ctrl+Z (stty susp undef)" 0 1
grep -q '_ft_on_tstp' "$here/ft-forms.bash" \
  && check "an unclaimed Ctrl+Z still suspends"     1 1 \
  || check "an unclaimed Ctrl+Z still suspends"     0 1

summary
