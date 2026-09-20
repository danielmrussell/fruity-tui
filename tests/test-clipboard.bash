#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tests/test-clipboard.bash — a copy either happens or says it didn't.
#
#  ft_clip_copy writes the terminal's clipboard with OSC 52. The thing that makes it
#  dangerous is that `\e]52;c;<payload>\a` with an EMPTY payload does not mean "do
#  nothing" — it means SET THE CLIPBOARD TO EMPTY. So every path that produced an empty
#  payload destroyed whatever the user had on their clipboard:
#
#    · copying an empty selection, or an empty label
#    · `base64` (or `tr`, whose stderr was not even redirected — "tr: command not found"
#      went straight to the alt screen) not being on PATH
#
#  A third path corrupts the screen instead: past a terminal's OSC string ceiling the
#  sequence is dropped, or parsing stops mid-string and the remaining base64 is PRINTED
#  over the UI.
#
#  And on top of all three, the text field announced "Copied" unconditionally — the same
#  lie as a silent save, discovered only when the user pastes and gets the old contents.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
FT_COLS=80; FT_ROWS=24

CLIP="$XDG_STATE_HOME/clip.out"; mkdir -p "$XDG_STATE_HOME"
_arm()  { : > "$CLIP"; exec {FT_TTY}>&-; exec {FT_TTY}>"$CLIP"; }
_sent() { [[ -s "$CLIP" ]] && FT_RET=yes || FT_RET=no; }
_clipboard() {                  # → FT_RET = what the terminal would end up holding
    local raw payload
    raw=$(<"$CLIP")
    if [[ "$raw" != *$'\e]52'* ]]; then FT_RET="(untouched)"; return; fi
    payload=${raw#*$'\e]52;c;'}; payload=${payload%$'\a'}
    [[ -z "$payload" ]] && { FT_RET="(CLEARED)"; return; }
    FT_RET=$(printf '%s' "$payload" | base64 -d 2>/dev/null)
}
_arm

CJK="設定オプション"            # 7 characters, 14 columns

note "what does reach the clipboard reaches it intact"
for t in "plain ascii" "$CJK" "mixed 設定 x🎉y" $'two\nlines' $'a\tb'; do
    _arm; ok "copy succeeds  [${t:0:8}]" ft_clip_copy "$t"
    _clipboard; check "…and round-trips through base64 byte for byte" "$FT_RET" "$t"
done

note "COPYING NOTHING MUST NOT CLEAR THE CLIPBOARD"
_arm
no "an empty copy reports that it did not copy" ft_clip_copy ""
_sent;      check "…and sends nothing at all"   "$FT_RET" "no"
_clipboard; check "…so the clipboard is untouched, not emptied" "$FT_RET" "(untouched)"

note "…nor may an encode that could not run clear it"
_arm
badpath() { local PATH=/nonexistent; ft_clip_copy "$1"; }
no "with no base64 on PATH, the copy reports failure" badpath "$CJK"
_sent;      check "…and sends nothing"          "$FT_RET" "no"
_clipboard; check "…leaving the clipboard alone" "$FT_RET" "(untouched)"
err="$XDG_STATE_HOME/clip.err"
badpath "$CJK" 2>"$err"
check "…and says nothing on the screen the user is looking at" "$(<"$err")" ""

note "…nor may a copy too large for an OSC string go out half-parsed"
big=$(printf '%0.sX' {1..200000})
_arm
ft_clip_copy "$big"; rc=$?
check "an oversized copy is refused with its own status" "$rc" "2"
_sent; check "…and nothing is emitted to be printed over the UI" "$FT_RET" "no"
# The ceiling is the TERMINAL's, so it is a knob, not a constant.
FT_CLIP_MAX_BYTES=999999999
_arm; ok "raising FT_CLIP_MAX_BYTES lets the same copy through" ft_clip_copy "$big"
_clipboard; check "…intact" "${#FT_RET}" "${#big}"
FT_CLIP_MAX_BYTES=74994

note "a selection copies exactly the characters selected, wide glyphs included"
ft-form name=cf width=60 height=14
    ft-textfield name=one  size=20 value="$CJK"
    ft-textfield name=area size=20 rows=3 value=$'第一行の設定\n第二行の設定'
    ft-label     name=lab  "ラベルのテキスト" width=20
    ft-label     name=empt "" width=20
    ft-statusbar name=sb
end_ft_form
ft_layout cf; FT_ROOT=cf; ft_focus one; ft_textfield_activate one
_copysel() {                    # name lo hi
    FT_TEXTFIELD_ANCHOR[$1]=$2; FT_TEXTFIELD_CARET[$1]=$3
    _arm; ft_textfield_copy "$1" >/dev/null 2>&1
    _clipboard
}
_copysel one 2 5; check "characters 2..5 of a wide-glyph value" "$FT_RET" "${CJK:2:3}"
_copysel one 0 7; check "the whole value"                       "$FT_RET" "$CJK"
ft_focus area; ft_textfield_activate area
v=$'第一行の設定\n第二行の設定'
_copysel area 3 10; check "a span across the newline"           "$FT_RET" "${v:3:7}"
_arm; ft_label_copy lab; _clipboard
check "a label copies its whole text"                           "$FT_RET" "ラベルのテキスト"

note "an EMPTY label copies nothing rather than wiping the clipboard"
_arm; ft_label_copy empt
_clipboard; check "the clipboard is untouched" "$FT_RET" "(untouched)"

note "the announcer lives in ft-core, so a LABEL's copy does not need the text field"
# It started life in ft-textfield.bash. A label copy in an app that never sourced the text
# field then announced nothing at all.
check "_ft_announce_copy is declared by ft-core.bash" \
      "$(grep -c '^_ft_announce_copy()' "$here/ft-core.bash")" "1"
check "…and no longer by the text field" \
      "$(grep -c '^_ft_announce_copy()' "$here/controls/ft-textfield.bash")" "0"

note "the status bar is told what actually happened"
_STATUS=""
ft_emit_status() { _STATUS=$1; return 0; }     # stand in for the bar
_STATUS=""; _copysel one 1 4 >/dev/null
check "a real copy announces textCopied"        "$_STATUS" "textCopied"
_STATUS=""; _arm
_ft_announce_copy 2
check "an oversized one announces copyTooLarge" "$_STATUS" "copyTooLarge"
_STATUS=""
_ft_announce_copy 1
check "a failed one announces copyFailed"       "$_STATUS" "copyFailed"
check "…and both wordings ship as framework defaults" \
      "${FT_STATUS_TEXT[copyFailed]:-missing}/${FT_STATUS_TEXT[copyTooLarge]:-missing}" \
      "Could not copy/Too much to copy"

note "itemCopied is EMITTED — a list control copies the item you are looking at"
# It shipped with a wording (FT_STATUS_TEXT[itemCopied]) and a registered property slot
# (text[itemCopied]) from the start, and grep found exactly two mentions in the whole
# repo — both of them that registration. Nothing ever emitted it: the wording was waiting
# for a feature that had never been wired.
ft_remove itf 2>/dev/null
ft-form name=itf width=60 height=20
    ft-tree name=itree rows=6
        ft-tree-node name=itn1 "設定"     id=a depth=0 expanded=true
        ft-tree-node name=itn2 "子ノード" id=b depth=1
        ft-tree-node name=itn3 "README"   id=c depth=0
    end_ft_tree
    ft-select name=isel size=1
        ft-option value=r "Red"
        ft-option value=g "緑 Green"
        ft-option value=b "Blue"
    end_ft_select
    ft-select name=imul size=4 multiple=true
        ft-option value=1 "One"   selected=true
        ft-option value=2 "Two"
        ft-option value=3 "Three" selected=true
    end_ft_select
    # A label is only a Tab stop WHEN IT SCROLLS (_ft_label_focus_skip), so a copy key on a
    # plain one can never be pressed. Three lines in a one-row box makes this one focusable —
    # and makes the point that a label's copy is reachable only in that state.
    ft-label name=ilab $'ラベル\nline two\nline three' width=20 height=1
    ft-statusbar name=isb
end_ft_form
ft_layout itf; FT_ROOT=itf

_STATUS=""
ft_emit_status() { _STATUS=$1; return 0; }

_arm; ft_focus itree; ft_tree_key_down itree           # cursor onto the child node
ft_tree_copy itree
_clipboard; check "a tree copies the WHOLE tree, drawn as it looks" \
                  "$FT_RET" $'▾ 設定\n    子ノード\n  README'
check "…and announces itemCopied, not textCopied"          "$_STATUS" "itemCopied"
_arm; _STATUS=""; ft_tree_key_home itree
ft_tree_copy itree
_clipboard; check "…the same wherever the cursor happens to be" \
                  "$FT_RET" $'▾ 設定\n    子ノード\n  README'
# A collapsed branch keeps its ▸ and its children stay hidden — that IS the tree as it
# stands, and the glyph would otherwise contradict the lines under it.
_arm; ft-modify itn1 expanded=false
ft_tree_copy itree
_clipboard; check "a collapsed branch copies collapsed" "$FT_RET" $'▸ 設定\n  README'
ft-modify itn1 expanded=true

_arm; _STATUS=""
ft-modify isel selectedIndex=1
ft_select_copy isel
_clipboard; check "a closed select copies the CHOSEN option" "$FT_RET" "緑 Green"
check "…as an item"                                          "$_STATUS" "itemCopied"

_arm; _STATUS=""
ft-modify isel open=true cursor=2
ft_select_copy isel
_clipboard; check "an OPEN select copies the option under the cursor" "$FT_RET" "Blue"
ft-modify isel open=false

_arm; _STATUS=""
ft_select_copy imul
_clipboard; check "a multiple-select copies every chosen option, one per line" \
                  "$FT_RET" $'One\nThree'

note "COPY IS SPELLED THE SAME WAY ON EVERY CONTROL"
# The framework has exactly two spellings of copy and they are both deliberate: Ctrl+C, taken
# from the tty by ft_enter_tty (`intr undef`, behind FT_CTRL_C_COPY) and offered by name in
# Settings; and readline's Alt+W, which is the one that still ARRIVES on a terminal that
# never negotiated a keyboard protocol, where the tty raises SIGINT before Ctrl+C can be
# delivered as a key. The text field binds both. A label bound Alt+C — a third spelling that
# matched neither — and when list copying was added that mistake was copied along with it.
for fn in ft_tree_copy ft_select_copy ft_label_copy; do
    ok "$fn is a defined function" declare -F "$fn"
done
_dispatches() {                 # control token expected-clipboard
    FT_UNRESOLVED_ACTIONS=()
    _arm                        # …or _clipboard reads the PREVIOUS copy's payload
    ft_focus "$1"; ft_dispatch_event "$2" >/dev/null 2>&1
    ft_unresolved_actions
    check "$2 on $1 resolves its action" "${FT_RET:-clean}" "clean"
    _clipboard; check "…and really copied" "$FT_RET" "$3"
}
ft_tree_key_home itree
_dispatches itree "CTRL+c" $'▾ 設定\n    子ノード\n  README'
_dispatches itree "ALT+w"  $'▾ 設定\n    子ノード\n  README'
ft-modify isel selectedIndex=0 open=false
_dispatches isel "CTRL+c" "Red"
_dispatches isel "ALT+w"  "Red"
ok "a scrolling label IS focusable, so its copy key is reachable" ft_focus ilab
_dispatches ilab "CTRL+c" $'ラベル\nline two\nline three'
_dispatches ilab "ALT+w"  $'ラベル\nline two\nline three'

note "…and the key nobody meant is gone"
# Alt+C must not linger as a third way to do it — a key that works on one control and not
# its neighbours is worse than one that works nowhere.
check "no control still binds Alt+C for copy" \
      "$(grep -l 'ALT+c' "$here"/controls/*.bash 2>/dev/null | wc -l)" "0"

note "CTRL+C NEVER QUITS — that is the whole point of taking it"
# It used to fall through to `exit 130` whenever nothing claimed it. So a user reaching for
# the most reflexive chord there is, whose selection had never been made or had been
# silently unmade by a stray arrow key, lost everything they were working on.
ft_remove qf 2>/dev/null
ft-form name=qf width=50 height=10
    ft-textfield name=qtf size=20 value="hello"
    ft-button    name=qbtn "Nothing"
    ft-statusbar name=qsb
end_ft_form
ft_layout qf; FT_ROOT=qf
_STATUS=""

note "…a field you are merely FOCUSED on copies all of itself"
ft_focus qtf
check "it really is idle, not engaged" \
      "$(_ft_textfield_engaged qtf && echo engaged || echo idle)" "idle"
_arm; _STATUS=""; ft_dispatch_event "CTRL+c" >/dev/null 2>&1
_clipboard; check "Ctrl+C on a focused field copies the whole value" "$FT_RET" "hello"
check "…and says so"                                                 "$_STATUS" "textCopied"

note "…a field you are EDITING with nothing selected hints instead of quitting"
ft_textfield_activate qtf
check "it really is engaged now" \
      "$(_ft_textfield_engaged qtf && echo engaged || echo idle)" "engaged"
_ft_textfield_sel_clear qtf 2>/dev/null; unset "FT_TEXTFIELD_ANCHOR[qtf]"
_arm; _STATUS=""
ft_dispatch_event "CTRL+c" >/dev/null 2>&1
_clipboard; check "nothing is copied"                     "$FT_RET" "(untouched)"
check "…and the hint tells you what to do"                "$_STATUS" "copyNothing"
check "…with wording that ships as a default"             "${FT_STATUS_TEXT[copyNothing]:-missing}" \
                                                          "Select something first, then copy"
# …and with a selection it copies, as always.
FT_TEXTFIELD_ANCHOR[qtf]=0; FT_TEXTFIELD_CARET[qtf]=4
_arm; _STATUS=""; ft_dispatch_event "CTRL+c" >/dev/null 2>&1
_clipboard; check "a selection still copies"              "$FT_RET" "hell"

note "…and on a control with nothing to copy at all it is INERT"
ft_focus qbtn
_arm; _STATUS=""
ft_dispatch_event "CTRL+c" >/dev/null 2>&1
_clipboard; check "the clipboard is untouched" "$FT_RET" "(untouched)"
# Outside a comment — the branch's own note still SAYS "exit 130" to explain what it
# replaced, and a bare substring count reads that as the code being there. (Same trap as
# run-all's `FAIL` match: measure the code, not the prose about it.)
check "the run loop no longer has an exit path for Ctrl+C" \
      "$(grep -c '^[^#]*exit 130' "$here/ft-forms.bash")" "0"
check "…it emits the hint instead" \
      "$(grep -c 'ft_emit_status copyNothing' "$here/ft-forms.bash")" "1"

note "…and the way OUT is still there, and was measured, not assumed"
# tests/escape-hatch.py drives a real pty: Ctrl+\ raises SIGQUIT, bash runs the QUIT trap
# even inside a tight builtin loop with no syscall to interrupt, and the EXIT trap restores
# the terminal. `isig` must stay on for that, so assert it is never turned off.
_ft_tty_flags
check "the tty keeps isig, so Ctrl+\\ still signals" \
      "$(case "$FT_RET" in *-isig*) echo "TURNED OFF" ;; *) echo kept ;; esac)" "kept"
check "…and only intr/susp are released"  \
      "$(case "$FT_RET" in *"intr undef"*) echo yes ;; *) echo no ;; esac)" "yes"
check "the QUIT trap is installed"        "$(grep -c "trap 'exit 131' QUIT" "$here/ft-core.bash")" "1"
check "…and EXIT restores the terminal"   "$(grep -c "trap 'ft_restore_tty' EXIT" "$here/ft-core.bash")" "1"
ok   "the wedge fixture the pty test drives exists" test -f "$here/tests/wedge-app.bash"
ok   "…and the pty escape test with it"             test -f "$here/tests/escape-hatch.py"

note "a table copies by runlevel: the whole thing outside, the current row inside"
ft_remove ctf 2>/dev/null
ft-form name=ctf width=70 height=14
    ft-table name=ctb variant=grid
        ft-table-header "Key"; ft-table-header "Action"
        ft-table-row "Ctrl+A" "start"
        ft-table-row "Ctrl+E" "end"
    end_ft_table
end_ft_form
ft_layout ctf; FT_ROOT=ctf; ft_focus ctb
_STATUS=""
_arm; ft_table_copy ctb
_clipboard; check "merely focused → the whole table, header and all" \
                  "$FT_RET" $'Key\tAction\nCtrl+A\tstart\nCtrl+E\tend'
ft_dispatch_event ENTER >/dev/null 2>&1
ft_runlevel ctb; check "Enter steps in"       "$FT_RET" "browsing"
ft_dispatch_event DOWN  >/dev/null 2>&1
ft_resolved_prop ctb cursor 0; check "…and Down moves the row cursor" "$FT_RET" "1"
_arm; ft_table_copy ctb
_clipboard; check "inside → just the row you are on" "$FT_RET" $'Ctrl+E\tend'
check "…announced as an item"                        "$_STATUS" "itemCopied"
ft_dispatch_event ESC >/dev/null 2>&1
# Esc leaves the INSIDES and no further: you are still standing on the table, so the rung is
# `poised`, not `unfocused`. `unfocused` means nobody is here at all — which is exactly the
# distinction the old single `inactive` rung could not make.
ft_runlevel ctb; check "Esc comes back out — to standing on it" "$FT_RET" "poised"
_arm; ft_table_copy ctb
_clipboard; check "…and copy is the whole table again" \
                  "$FT_RET" $'Key\tAction\nCtrl+A\tstart\nCtrl+E\tend'

note "the controls with no item cursor are deliberately NOT wired"
# A table has scrollTop and no row cursor, so "the current row" does not exist to copy —
# that is a feature (row selection), not a wiring fix. A multitoggle shares the `activate`
# keymap with buttons and checkboxes, so binding Alt+C there would hand a copy key to
# controls with nothing to copy. Both are noted here so the omission is a decision on the
# record rather than something that looks forgotten.
check "a multitoggle still has no copy action" \
      "$(declare -F ft_multitoggle_copy >/dev/null && echo yes || echo no)" "no"

note "the kill ring still takes the text even when the clipboard refuses it"
# C-y must keep working: the ring is ours, the clipboard is the terminal's.
FT_KILL_RING=()
badpush() { local PATH=/nonexistent; _ft_kill_push "$1"; }
badpush "設定" 2>/dev/null
check "the text is on the ring"                 "${FT_KILL_RING[0]:-none}" "設定"
badpush "設定" 2>/dev/null
check "…and the push reports the clipboard's failure" "$?" "1"

summary
