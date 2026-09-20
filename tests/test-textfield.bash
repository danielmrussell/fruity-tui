#!/usr/bin/env bash
# Unit tests for controls/ft-textfield.bash: the value model, readline-style
# editing operations, insert/overwrite typing, and the Insert-key mode toggle.
# Pure logic — no tty needed; we call the bound handlers directly and read the
# field's `value` and caret exactly as a real keypress would leave them.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null

# A textfield's scroll offsets are `scrollTop`/`scrollLeft` — the DOM's names, and ordinary
# properties — where they used to be two private tables (FT_TEXTFIELD_VSCROLL/_SCROLL). These
# read them the way an app would, which is the point of the move.
_voff() { _ft_get_raw "$1" scrollTop;  printf '%s' "${FT_RET:-0}"; }
_hoff() { _ft_get_raw "$1" scrollLeft; printf '%s' "${FT_RET:-0}"; }

# The "Enter to edit" model: a merely-focused field is IDLE (keys bubble); you
# press Enter to enter edit/cursor mode. These unit tests exercise the EDIT
# behaviour by dispatching key tokens, so wrap dispatch to auto-ENTER the focused
# field first — exactly what a user's Enter does interactively. (Direct handler
# calls like ft_textfield_insert_char bypass the keymap and are unaffected.)
eval "_orig_dispatch() $(declare -f ft_dispatch_event | tail -n +2)"
ft_dispatch_event() {
    local f=${FT_FOCUS:-}
    if [[ "${FT_TYPE[$f]:-}" == textfield ]] && ! _ft_textfield_engaged "$f"; then
        local c=${FT_TEXTFIELD_CARET[$f]:-}          # entering edit resets caret to end;
        ft_textfield_activate "$f"                    # the tests pre-position it, so put it back
        [[ -n "$c" ]] && FT_TEXTFIELD_CARET[$f]=$c
    fi
    _orig_dispatch "$@"
}

ft-form name=app width=60 height=6
    ft-textfield name=tf size=12 value="hello"
end_ft_form
ft_layout app
FT_ROOT=app; FT_FOCUS=tf

val() { ft_get tf value; }
car() { _ft_textfield_caret tf; }

note "seeded value + caret opens at the START of the document (not the end)"
val; check "initial value" "$FT_RET" "hello"
car; check "caret opens at the start (cursorStartAtCharacter default 0)" "$FT_RET" "0"
# ...and cursorStartAtCharacter=-1 is how you ask for the old end-of-value behaviour.
ft-textfield name=tfend size=12 value="hello" cursorStartAtCharacter=-1
_ft_textfield_caret tfend; check "cursorStartAtCharacter=-1 opens at the end" "$FT_RET" "5"

note "motion: home / left / right / end"
ft_textfield_home tf;  car; check "home → 0" "$FT_RET" "0"
ft_textfield_right tf; car; check "right → 1" "$FT_RET" "1"
ft_textfield_end tf;   car; check "end → len" "$FT_RET" "5"
ft_textfield_left tf;  car; check "left → 4" "$FT_RET" "4"

note "typing inserts at the caret (insert mode is default)"
ft_textfield_end tf
ft_textfield_insert_char tf "!"
val; check "typed '!' at end" "$FT_RET" "hello!"
ft_textfield_home tf
ft_textfield_insert_char tf ">"
val; check "typed '>' at start" "$FT_RET" ">hello!"
car; check "caret advanced past inserted char" "$FT_RET" "1"

note "space is its own token and types a space"
ft_textfield_end tf; ft_textfield_space tf
val; check "space appended" "$FT_RET" ">hello! "

note "backspace deletes left, delete removes under caret"
ft_textfield_backspace tf
val; check "backspace removed the space" "$FT_RET" ">hello!"
ft_textfield_home tf; ft_textfield_delete tf
val; check "delete removed leading '>'" "$FT_RET" "hello!"

note "overwrite mode replaces the char under the caret"
ft_textfield_home tf
ft_textfield_toggle_mode tf      # insert → overwrite
_ft_textfield_mode tf; check "mode is overwrite after toggle" "$FT_RET" "overwrite"
ft_textfield_insert_char tf "J"
val; check "overwrote first char" "$FT_RET" "Jello!"
ft_textfield_toggle_mode tf      # back to insert
_ft_textfield_mode tf; check "mode back to insert" "$FT_RET" "insert"

note "readline kills: Ctrl+K to end, Ctrl+U to start, Ctrl+W a word"
ft-textfield name=tf2 size=20 value="the quick brown fox"
ft_layout app; FT_FOCUS=tf2
FT_TEXTFIELD_CARET[tf2]=9        # right after 'quick'
ft_textfield_kill_to_end tf2
ft_get tf2 value; check "Ctrl+K killed to end" "$FT_RET" "the quick"
ft_textfield_kill_word tf2
ft_get tf2 value; check "Ctrl+W killed the word 'quick'" "$FT_RET" "the "
ft_textfield_end tf2; FT_TEXTFIELD_CARET[tf2]=${#FT_RET}
ft-textfield name=tf3 size=20 value="abcdef"
ft_layout app; FT_FOCUS=tf3
FT_TEXTFIELD_CARET[tf3]=4
ft_textfield_kill_to_start tf3
ft_get tf3 value; check "Ctrl+U killed to start" "$FT_RET" "ef"
car3() { _ft_textfield_caret tf3; }; car3; check "caret at 0 after Ctrl+U" "$FT_RET" "0"

note "the kills are LINE-local in a textarea, not document-local"
# On a one-line field "to the end" and "to the end of the line" are the same thing, and every
# test above is a one-line field — so Ctrl+K happily destroyed everything below the caret in a
# textarea and nothing noticed. Home/End were already line-local; these now agree with them.
ft-textfield name=tfk size=30 rows=5 wrap=true value=$'alpha\nbravo\ncharlie'
ft_layout app; FT_FOCUS=tfk
FT_TEXTFIELD_CARET[tfk]=6                        # start of "bravo"
ft_textfield_kill_to_end tfk
ft_get tfk value; check "Ctrl+K takes only that line" "$FT_RET" $'alpha\n\ncharlie'
ft-modify tfk value=$'alpha\nbravo\ncharlie'; _ft_textfield_undo_forget tfk
FT_TEXTFIELD_CARET[tfk]=11                       # end of "bravo"
ft_textfield_kill_to_start tfk
ft_get tfk value; check "Ctrl+U takes only that line" "$FT_RET" $'alpha\n\ncharlie'
# With nothing left on that side the kill takes the LINE ENDING, joining the lines (emacs), so
# the key is never simply inert.
ft-modify tfk value=$'alpha\nbravo'; _ft_textfield_undo_forget tfk
FT_TEXTFIELD_CARET[tfk]=5                        # end of "alpha", nothing left on the line
ft_textfield_kill_to_end tfk
ft_get tfk value; check "Ctrl+K at a line end joins the next line" "$FT_RET" "alphabravo"
ft-modify tfk value=$'alpha\nbravo'; _ft_textfield_undo_forget tfk
FT_TEXTFIELD_CARET[tfk]=6                        # start of "bravo", nothing left before it
ft_textfield_kill_to_start tfk
ft_get tfk value; check "Ctrl+U at a line start joins the previous" "$FT_RET" "alphabravo"

note "word motions (Alt+B/F/D)"
ft-textfield name=tfw size=30 value="the quick brown fox"
ft_layout app; FT_FOCUS=tfw
FT_TEXTFIELD_CARET[tfw]=19        # at end
ft_textfield_word_back tfw; _ft_textfield_caret tfw; check "Alt+B → start of 'fox' (16)" "$FT_RET" "16"
ft_textfield_word_back tfw; _ft_textfield_caret tfw; check "Alt+B again → start of 'brown' (10)" "$FT_RET" "10"
ft_textfield_word_fwd tfw;  _ft_textfield_caret tfw; check "Alt+F → past 'brown' (15)" "$FT_RET" "15"
FT_TEXTFIELD_CARET[tfw]=4        # start of 'quick'
ft_textfield_kill_word_fwd tfw
ft_get tfw value; check "Alt+D killed the word 'quick'" "$FT_RET" "the  brown fox"

note "Alt+←/→ tokens are bound to word motion (same as Alt+B/F)"
ft-textfield name=tfa size=30 value="the quick brown fox"
ft_layout app; FT_FOCUS=tfa
FT_TEXTFIELD_CARET[tfa]=19
ft_dispatch_event "ALT+left"  >/dev/null; _ft_textfield_caret tfa; check "Alt+Left → start of 'fox' (16)"   "$FT_RET" "16"
ft_dispatch_event "ALT+left"  >/dev/null; _ft_textfield_caret tfa; check "Alt+Left again → start 'brown' (10)" "$FT_RET" "10"
ft_dispatch_event "ALT+right" >/dev/null; _ft_textfield_caret tfa; check "Alt+Right → past 'brown' (15)"     "$FT_RET" "15"

note "a NEWLINE bounds a word — every one of these tests used a single spaced line, which is
      exactly why the bug survived: lines with no spaces in them were skipped wholesale"
# alpha 0-4 · \n 5 · bravo 6-10 · \n 11 · charlie 12-18 · \n 19 · delta 20-24
ft-textfield name=tfnl size=30 rows=6 wrap=true value=$'alpha\nbravo\ncharlie\ndelta'
ft_layout app; FT_FOCUS=tfnl
_wb() { FT_TEXTFIELD_CARET[tfnl]=$1; ft_textfield_word_back tfnl; _ft_textfield_caret tfnl; }
_wf() { FT_TEXTFIELD_CARET[tfnl]=$1; ft_textfield_word_fwd  tfnl; _ft_textfield_caret tfnl; }
_wb 25; check "back from end of 'delta' → its start (20)"      "$FT_RET" "20"
_wb 20; check "back ACROSS a newline → start of 'charlie' (12)" "$FT_RET" "12"
_wb 12; check "back again → start of 'bravo' (6)"              "$FT_RET" "6"
_wb 6;  check "back again → start of 'alpha' (0)"              "$FT_RET" "0"
_wf 0;  check "forward → end of 'alpha' (5), not the document" "$FT_RET" "5"
_wf 5;  check "forward across a newline → end of 'bravo' (11)" "$FT_RET" "11"
# A TAB is a word boundary for the same reason (soft tabs put real ones in the value).
ft-modify tfnl value=$'one\ttwo\tthree'
_wb 13; check "a tab bounds a word too → start of 'three' (8)" "$FT_RET" "8"
# …and the word KILLS use the same rule, so Ctrl+W at a line start must not eat the line above.
ft-modify tfnl value=$'alpha\nbravo'
FT_TEXTFIELD_CARET[tfnl]=11; ft_textfield_kill_word tfnl
ft_get tfnl value; check "Ctrl+W kills one word, not through the newline" "$FT_RET" $'alpha\n'

note "maxLength caps insertion"
ft-textfield name=tf4 size=6 value="" maxLength=3 onChange=tf4_on_change
ft_layout app; FT_FOCUS=tf4
ft_textfield_insert_char tf4 "a"; ft_textfield_insert_char tf4 "b"
ft_textfield_insert_char tf4 "c"; ft_textfield_insert_char tf4 "d"
ft_get tf4 value; check "capped at maxLength=3" "$FT_RET" "abc"

note "on_change fires with the new value"
CHLOG=""
tf4_on_change() { CHLOG="$1"; }   # $this=tf4, $1=new text
ft_textfield_backspace tf4
check "on_change saw the edited value" "$CHLOG" "ab"

note "textarea (rows>1): same class, height=rows, newline + visual navigation"
ft-form name=tapp width=40 height=20
    ft-textfield name=ta size=10 rows=4 value=""
end_ft_form
ft_layout tapp; FT_ROOT=tapp; FT_FOCUS=ta
check "textarea height = rows + 2 border rows" "${FT_MEASURED_HEIGHT[ta]}" "6"
# type "ab", Enter, "cd"  → value "ab\ncd" (Enter inserts a newline here)
ft_textfield_insert_char ta a; ft_textfield_insert_char ta b
ft_textfield_enter ta
ft_textfield_insert_char ta c; ft_textfield_insert_char ta d
ft_get ta value; check "Enter inserted a newline" "$FT_RET" $'ab\ncd'
car_ta() { _ft_textfield_caret ta; }; car_ta; check "caret after 'd'" "$FT_RET" "5"

# Regression: Shift+Tab (btab→unindent) with the caret PAST a newline used to run
# `${#head##*\n}` — a bad substitution (length + strip can't combine) — which killed
# the whole program. It must be clean now, even when there is no indent to strip.
note "Shift+Tab after a newline must not crash (unindent bad-substitution regression)"
# `${#head##*\n}` is a bad substitution (length + strip can't combine); it killed the
# whole program the instant the caret sat past a newline. Invoking it must be clean.
btab_err=$(ft_textfield_btab ta 2>&1 >/dev/null)
check "btab on a post-newline line emits no error" "$btab_err" ""
ft_get ta value; check "value intact (no leading spaces to strip)" "$FT_RET" $'ab\ncd'

note "textarea layout wraps long logical lines, offsets stay exact"
ft-textfield name=ta2 size=6 rows=5 value=$'hello world foo\nbar'
ft_layout app
_ft_textfield_layout ta2 6
# "hello world foo" wraps at width 6; "bar" is its own logical line
check "first visual line" "${FT_TEXTFIELD_LINES_TEXT[0]}" "hello "
check "offset of line 0 is 0" "${FT_TEXTFIELD_LINES_OFFSET[0]}" "0"
# every visual line's offset equals the previous offset + previous line length
ok=1
for ((i=1;i<${#FT_TEXTFIELD_LINES_OFFSET[@]};i++)); do
    exp=$(( FT_TEXTFIELD_LINES_OFFSET[i-1] + ${#FT_TEXTFIELD_LINES_TEXT[i-1]} ))
    # a hard \n between logical lines adds 1 to the gap; allow +0 (soft) or +1 (hard)
    d=$(( FT_TEXTFIELD_LINES_OFFSET[i] - exp )); (( d==0 || d==1 )) || ok=0
done
check "offsets are contiguous (±newline)" "$ok" "1"

note "textarea Up/Down move the caret between visual lines"
ft-textfield name=ta3 size=8 rows=4 value=$'line one\nline two\nline three'
ft_layout app; FT_FOCUS=ta3
ft_textfield_home ta3; FT_TEXTFIELD_CARET[ta3]=0        # start of doc
ft_textfield_down ta3                             # → row 1 (start of "line two")
_ft_textfield_layout ta3 8; _ft_textfield_caret ta3; _ft_textfield_rowcol "$FT_RET"
check "Down moved to visual row 1" "$FT_TEXTFIELD_LINES_CARET_ROW" "1"
ft_textfield_up ta3
_ft_textfield_caret ta3; _ft_textfield_rowcol "$FT_RET"
check "Up moved back to visual row 0" "$FT_TEXTFIELD_LINES_CARET_ROW" "0"

note "textarea Home/End are logical-line bounds, not whole-doc"
FT_TEXTFIELD_CARET[ta3]=3        # inside "line one"
ft_textfield_end ta3;  car3b() { _ft_textfield_caret ta3; }; car3b; check "End → end of logical line 1" "$FT_RET" "8"
ft_textfield_home ta3; car3b; check "Home → start of logical line 1" "$FT_RET" "0"

note "textarea layout NEVER hangs on a value ending in / being a newline"
# (regression: a trailing \n used to loop forever, freezing the whole app)
_ft_textfield_layout_probe() { ft-textfield name="$1" size=8 rows=4 value="$2"; _ft_textfield_layout "$1" 8; echo "${#FT_TEXTFIELD_LINES_TEXT[@]}"; }
check "value ending in newline yields a trailing empty line" "$(_ft_textfield_layout_probe tz1 $'ab\n')" "2"
check "value that is only a newline yields two empty lines"  "$(_ft_textfield_layout_probe tz2 $'\n')" "2"
check "typing then Enter (value ends in \\n) lays out fine"   "$(_ft_textfield_layout_probe tz3 $'hello\n')" "2"

note "cursor SHAPE: insert=bar, overwrite=block; blinking by default"
FT_CURSOR_BLINK=1
FT_TEXTFIELD_MODE[tz1]=insert;    _ft_textfield_cursor_shape tz1; check "insert → blinking bar (5)"   "$FT_RET" "5"
FT_TEXTFIELD_MODE[tz1]=overwrite; _ft_textfield_cursor_shape tz1; check "overwrite → blinking block (1)" "$FT_RET" "1"
ft-textfield name=tzb size=8 cursorStyle=block; _ft_textfield_cursor_shape tzb
check "cursorStyle=block forces the block shape (blinking=1)" "$FT_RET" "1"
FT_CURSOR_BLINK=0
FT_TEXTFIELD_MODE[tz1]=insert;    _ft_textfield_cursor_shape tz1; check "blink off → steady bar (6)"   "$FT_RET" "6"
FT_TEXTFIELD_MODE[tz1]=overwrite; _ft_textfield_cursor_shape tz1; check "blink off → steady block (2)" "$FT_RET" "2"
FT_CURSOR_BLINK=1

note "textarea wrap=false keeps each logical line whole (no soft-wrap)"
ft-textfield name=tw size=8 rows=3 wrap=false value=$'a very long single logical line here\nshort'
ft_layout app
_ft_textfield_layout tw 8
check "wrap=false: 2 visual lines = 2 logical lines" "${#FT_TEXTFIELD_LINES_TEXT[@]}" "2"
check "first visual line is the WHOLE long line" "${FT_TEXTFIELD_LINES_TEXT[0]}" "a very long single logical line here"
# same field with wrap=true would soft-wrap the long line into many rows
ft-modify tw wrap=true; _ft_textfield_layout tw 8
check "wrap=true: the long line folds to many rows" "$(( ${#FT_TEXTFIELD_LINES_TEXT[@]} > 2 ))" "1"

note "the field is focusable and reads back like any value control"
_ft_focus_skippable tf && s=yes || s=no
check "an enabled field is focusable" "$s" "no"
SUBMIT=""
btn_on_activate() { ft_get tf value; SUBMIT="$FT_RET"; }
ft-button name=btn Submit onActivate=btn_on_activate; ft_activate btn
check "a button's handler reads the field value" "$SUBMIT" "Jello!"

note "selection: Shift+motion extends, plain motion collapses, edits replace it"
ft-textfield name=sel size=20 value="hello world foo"
ft_layout app; FT_FOCUS=sel
FT_TEXTFIELD_CARET[sel]=15                       # end
ft_textfield_select_left sel; ft_textfield_select_left sel; ft_textfield_select_left sel; ft_textfield_select_left sel; ft_textfield_select_left sel
_ft_textfield_selrange sel && r="[$FT_SELECTION_START,$FT_SELECTION_END)" || r=none
check "Shift+Left x5 selects the last 5 chars" "$r" "[10,15)"
ft_get sel value; check "selected substring is 'd foo'" "${FT_RET:FT_SELECTION_START:FT_SELECTION_END-FT_SELECTION_START}" "d foo"
ft_textfield_move_left sel                            # plain Left collapses
_ft_textfield_selrange sel && r=sel || r=cleared
check "plain Left clears the selection" "$r" "cleared"
FT_TEXTFIELD_CARET[sel]=15; unset 'FT_TEXTFIELD_ANCHOR[sel]'
ft_textfield_select_home sel                            # select whole line
ft_textfield_insert_char sel "X"
ft_get sel value; check "typing over a selection replaces it" "$FT_RET" "X"
ft-textfield name=sel2 size=20 value="abcdefgh"; ft_layout app; FT_FOCUS=sel2
FT_TEXTFIELD_CARET[sel2]=8; ft_textfield_select_home sel2; ft_textfield_cut sel2
ft_get sel2 value; check "cut removes the selected range" "$FT_RET" ""
ft-textfield name=sel3 size=20 value="keepme"; ft_layout app; FT_FOCUS=sel3
FT_TEXTFIELD_CARET[sel3]=6; ft_textfield_select_home sel3; ft_textfield_copy sel3
ft_get sel3 value; check "copy leaves the value unchanged" "$FT_RET" "keepme"
ft_textfield_word_back sel3 >/dev/null 2>&1  # sanity: base motions still callable
check "SHIFT+ALT word wrappers exist" "$(declare -F ft_textfield_select_word_back >/dev/null && echo y)" "y"

note "arrows are CONSTRAINED to the field — they clamp at the edges, never move focus"
ft-form name=navapp width=44 height=12
    ft-textfield name=n1 size=12 value="hello"
    ft-textfield name=nta size=8 rows=3 value=$'aa\nbb\ncc'
    ft-textfield name=n2 size=12 value="world"
end_ft_form
ft_layout navapp; FT_ROOT=navapp; FT_FOCUS=n1
# Shift+Up on a one-liner selects to the start and stays
FT_TEXTFIELD_CARET[n1]=5; unset 'FT_TEXTFIELD_ANCHOR[n1]'
ft_textfield_select_up n1; _ft_textfield_selrange n1 && rr="[$FT_SELECTION_START,$FT_SELECTION_END)" || rr=none
check "Shift+Up selects to the line start" "$rr" "[0,5)"
check "Shift+Up kept focus in n1"          "$FT_FOCUS" "n1"
# plain Down on a one-liner STAYS and puts the caret at the end (constrained)
FT_FOCUS=n1; FT_TEXTFIELD_CARET[n1]=0; ft_textfield_move_down n1
check "plain Down keeps focus in n1"       "$FT_FOCUS" "n1"
_ft_textfield_caret n1; check "plain Down clamps caret to end (5)" "$FT_RET" "5"
# plain Up on a one-liner STAYS and puts the caret at the start
FT_FOCUS=n2; FT_TEXTFIELD_CARET[n2]=5; ft_textfield_move_up n2
check "plain Up keeps focus in n2"         "$FT_FOCUS" "n2"
_ft_textfield_caret n2; check "plain Up clamps caret to start (0)" "$FT_RET" "0"

note "textarea: arrows clamp at the edges and STAY; mid-doc moves lines"
FT_FOCUS=nta; FT_TEXTFIELD_CARET[nta]=0
ft_textfield_select_up nta; _ft_textfield_caret nta; check "Shift+Up at top clamps to 0" "$FT_RET" "0"
check "Shift+Up kept focus in nta" "$FT_FOCUS" "nta"
FT_TEXTFIELD_CARET[nta]=8; ft_textfield_select_down nta; _ft_textfield_caret nta; check "Shift+Down at bottom clamps to end (8)" "$FT_RET" "8"
FT_FOCUS=nta; FT_TEXTFIELD_CARET[nta]=0; ft_textfield_move_up nta
check "plain Up at top of textarea STAYS in the field" "$FT_FOCUS" "nta"
_ft_textfield_caret nta; check "plain Up at top clamps caret to 0" "$FT_RET" "0"
FT_FOCUS=nta; FT_TEXTFIELD_CARET[nta]=0; ft_textfield_move_down nta
check "plain Down mid-textarea stays in field" "$FT_FOCUS" "nta"
_ft_textfield_caret nta; check "plain Down moved to line 2 (caret 3)" "$FT_RET" "3"

note "Enter-to-edit: focus is idle; Enter enters edit mode; Esc/Tab leave it"
ft-form name=tabapp width=44 height=8
    ft-textfield name=ti size=12 value="x"
    ft-textfield name=tj size=12 value=""
end_ft_form
ft_layout tabapp; FT_ROOT=tabapp; FT_FOCUS=ti; ft_textfield_deactivate ti
# POISED, not unfocused — the field HAS focus, it just has not been entered. That those are
# two different things is the whole point of splitting the old single `inactive` rung.
check "field starts poised (not editing)" "$(ft_get ti runlevel; printf %s "$FT_RET")" "poised"
ft_textfield_activate ti
check "Enter (activate) enters edit mode" "$(ft_get ti runlevel; printf %s "$FT_RET")" "editing"
# The caret opens at the START of the document by default (cursorStartAtCharacter=0),
# so typing lands there — it is NOT kicked to the end any more.
_ft_textfield_caret ti; check "caret opens at the start, not the end" "$FT_RET" "0"
ft_textfield_insert_char ti "Z"; ft_get ti value; check "typing edits once in edit mode" "$FT_RET" "Zx"
ft_textfield_esc ti
# …and lands on POISED, for the reason stated sixteen lines above: the field still HAS focus.
# This asserted `unfocused`, contradicting its own fixture and pinning the one route that
# answered "where does leaving land" differently from ft_runlevel_out.
check "Esc leaves edit mode" "$(ft_get ti runlevel; printf %s "$FT_RET")" "poised"
# TAB BELONGS TO FOCUS IN A ONE-LINE FIELD. A single line has nothing to indent, so
# taking Tab there only strands the user in the box — it moves focus even mid-edit.
FT_FOCUS=ti; ft_textfield_activate ti; ft-modify ti value="abcd"; FT_TEXTFIELD_CARET[ti]=2
ft_textfield_tab ti
ft_get ti value; check "Tab in a ONE-LINE field types nothing" "$FT_RET" "abcd"
check "…it moves focus, mid-edit and all" "$([[ $FT_FOCUS != ti ]] && echo moved)" "moved"
# (from the SECOND field, so this tests the move itself and not focus-wrap behaviour)
FT_FOCUS=tj; ft_textfield_activate tj; ft-modify tj value="abcd"; FT_TEXTFIELD_CARET[tj]=2
ft_textfield_btab tj
ft_get tj value; check "Shift+Tab in a one-line field types nothing" "$FT_RET" "abcd"
check "…and moves focus back"           "$FT_FOCUS" "ti"
# …but a one-liner CAN opt in, for a path/code field where indentation is real.
ft-modify ti acceptsTab=true
FT_FOCUS=ti; ft_textfield_activate ti; ft-modify ti value="abcd"; FT_TEXTFIELD_CARET[ti]=2
ft_textfield_tab ti; ft_get ti value; check "acceptsTab=true makes Tab type again" "$FT_RET" "ab  cd"
check "…and focus stays put"            "$FT_FOCUS" "ti"
ft-modify ti acceptsTab=auto
# A multi-line text BOX is the opposite case: it is a small editor, Esc is the way out,
# and Tab types a SOFT tab — spaces to the next 4-col stop, never a literal \t (which
# would smear the fixed-cell render).
ft-textfield name=tbox size=12 rows=4 value=""; ft_layout tabapp
FT_FOCUS=tbox; ft_textfield_activate tbox; ft-modify tbox value="abcd"; FT_TEXTFIELD_CARET[tbox]=2
ft_textfield_tab tbox; ft_get tbox value; check "Tab in a TEXT BOX inserts spaces to the next 4-stop" "$FT_RET" "ab  cd"
[[ "$FT_RET" == *$'\t'* ]] && check "no literal tab byte" 1 0 || check "no literal tab byte" 1 1
_ft_textfield_caret tbox; check "caret advances past the inserted spaces (not left behind)" "$FT_RET" "4"
check "…and focus stayed in the box" "$FT_FOCUS" "tbox"
# …and a text box can opt OUT, when Tab-to-next-field matters more than indentation.
ft-modify tbox acceptsTab=false
FT_FOCUS=tbox; ft_textfield_activate tbox; ft-modify tbox value="abcd"; FT_TEXTFIELD_CARET[tbox]=2
ft_textfield_tab tbox; ft_get tbox value; check "acceptsTab=false gives Tab back to focus" "$FT_RET" "abcd"
check "…and it moved" "$([[ $FT_FOCUS != tbox ]] && echo moved)" "moved"
ft-modify tbox acceptsTab=auto
FT_FOCUS=ti
# soft-tab-aware Backspace: one press deletes the whole soft tab (caret jumps a tab)
ft-modify ti value="    x"; FT_TEXTFIELD_CARET[ti]=4; ft_textfield_backspace ti
ft_get ti value; check "Backspace removes a whole soft tab of spaces" "$FT_RET" "x"
_ft_textfield_caret ti; check "caret jumped back a full tab width" "$FT_RET" "0"
# but a non-space run deletes ONE char
ft-modify ti value="abcd"; FT_TEXTFIELD_CARET[ti]=4; ft_textfield_backspace ti
ft_get ti value; check "Backspace on text still deletes one char" "$FT_RET" "abc"
# select-all (Alt+A), then the selection can be copied or deleted to clear the field
ft-modify ti value="clear me"; FT_TEXTFIELD_CARET[ti]=0; ft_textfield_select_all ti
_ft_textfield_selrange ti && check "Alt+A selects the whole field" "[$FT_SELECTION_START,$FT_SELECTION_END)" "[0,8)" || check "Alt+A selects the whole field" none "[0,8)"
ft_textfield_backspace ti; ft_get ti value; check "deleting the select-all clears the field" "$FT_RET" ""
# In a tab-accepting field Shift+Tab UNINDENTS the current line (not focus movement)
FT_FOCUS=tbox; ft_textfield_activate tbox; ft-modify tbox value="    xy"; FT_TEXTFIELD_CARET[tbox]=6
ft_textfield_btab tbox; ft_get tbox value; check "Shift+Tab unindents (removes a leading soft tab)" "$FT_RET" "xy"
_ft_textfield_caret tbox; check "caret shifts left by the unindent" "$FT_RET" "2"
check "Shift+Tab kept focus in the box" "$FT_FOCUS" "tbox"
FT_FOCUS=ti

note "activateToEdit=false: field is editable immediately on focus; Tab moves focus"
ft-textfield name=aie size=12 value="ab" activateToEdit=false; ft_layout tabapp
FT_FOCUS=aie; _ft_focusin_textfield aie
check "activateToEdit=false enters edit on focus" "$(ft_get aie runlevel; printf %s "$FT_RET")" "editing"
FT_TEXTFIELD_CARET[aie]=2; ft_textfield_tab aie
check "Tab moves focus (no literal tab)" "$([[ $FT_FOCUS != aie ]] && echo moved)" "moved"
ft_get aie value; check "value unchanged by Tab" "$FT_RET" "ab"
# Ctrl+C copies, and NEVER quits. It used to bubble when nothing was selected, and the run
# loop then exited 130 — so reaching for copy with a selection you had not made, or had
# silently unmade with a stray arrow, threw away everything you were working on. Now:
# editing with a selection → the selection; editing with none → a hint and nothing else;
# merely focused → the whole value, because you have not told it about any smaller part.
FT_FOCUS=tj; ft_textfield_activate tj; ft-modify tj value="copyme"
FT_TEXTFIELD_CARET[tj]=6; ft_textfield_select_home tj; FT_KILL_RING=(); ft_textfield_ctrl_c tj
check "Ctrl+C copied the selection to the ring" "${FT_KILL_RING[0]:-}" "copyme"
_ft_textfield_sel_clear tj; FT_KILL_RING=(); FT_KEY_BUBBLE=0
_STATUS_WAS=""; ft_emit_status() { _STATUS_WAS=$1; return 0; }
ft_textfield_ctrl_c tj
check "Ctrl+C with no selection does NOT bubble to the quit path" "$FT_KEY_BUBBLE" "0"
check "…copies nothing"                                           "${FT_KILL_RING[0]:-none}" "none"
check "…and hints instead"                                        "$_STATUS_WAS" "copyNothing"
ft_textfield_deactivate tj
_STATUS_WAS=""; FT_KILL_RING=(); ft_textfield_ctrl_c tj
check "merely focused, Ctrl+C copies the whole value"             "${FT_KILL_RING[0]:-none}" "copyme"
unset -f ft_emit_status

note "idle read-only viewer scrolls its VIEW every arrow press (not a hidden caret)"
ft-textfield name=view readOnly=true wrap=true rows=4 size=16 \
    value=$'a\nb\nc\nd\ne\nf\ng\nh'; ft_layout tabapp
FT_FOCUS=view; _ft_focusin_textfield view          # seeds vscroll=0 at the top
check "viewer starts at top"        "$(_voff view)" "0"
ft_textfield_idle_down view; check "Down #1 → vscroll 1" "$(_voff view)" "1"
ft_textfield_idle_down view; check "Down #2 → vscroll 2 (moves EVERY press)" "$(_voff view)" "2"
ft_textfield_idle_up   view; check "Up → vscroll 1"       "$(_voff view)" "1"
check "scrolling never entered edit mode" "$(ft_get view runlevel; printf %s "$FT_RET")" "unfocused"
ft_textfield_idle_home view; check "Home → top"           "$(_voff view)" "0"

note "cursorStartAtCharacter / cursorStartAtLine decide where the caret OPENS (neg = from end)"
ft-form name=csapp width=40 height=14
  ft-textfield name=c0 size=12 value="hello"                                   # class default 0
  ft-textfield name=cend size=12 value="hello" cursorStartAtCharacter=-1       # -1 = the very end
  ft-textfield name=cmid size=12 value="hello" cursorStartAtCharacter=2
  ft-textfield name=cneg size=12 value="hello" cursorStartAtCharacter=-2       # one before the end
  ft-textfield name=cl   size=12 rows=4 value=$'aa\nbb\ncc' cursorStartAtLine=1
  ft-textfield name=cll  size=12 rows=4 value=$'aa\nbb\ncc' cursorStartAtLine=-1  # last line
end_ft_form
ft_layout csapp
_ft_textfield_start_caret c0;   check "default opens at the START (0)"        "$FT_RET" "0"
_ft_textfield_start_caret cend; check "-1 opens at the very END"              "$FT_RET" "5"
_ft_textfield_start_caret cmid; check "2 opens at index 2"                    "$FT_RET" "2"
_ft_textfield_start_caret cneg; check "-2 opens one before the end"           "$FT_RET" "4"
_ft_textfield_start_caret cl;   check "cursorStartAtLine=1 → start of line 1" "$FT_RET" "3"
_ft_textfield_start_caret cll;  check "cursorStartAtLine=-1 → last line"      "$FT_RET" "6"
# and the caret is REMEMBERED: leaving and re-entering does not reset it
FT_FOCUS=cmid; ft_textfield_activate cmid; FT_TEXTFIELD_CARET[cmid]=4; ft_textfield_deactivate cmid
ft_textfield_activate cmid; _ft_textfield_caret cmid
check "re-entering remembers where the caret was" "$FT_RET" "4"

note "ONCE YOU HAVE ENTERED A CONTROL, THE ARROWS BELONG TO IT"
# These handlers are the SCROLLING rung's — you got here by pressing Enter. They used to
# bubble whenever the axis could not move, so a stray Up at the top of a document, or in a
# panel that only scrolls SIDEWAYS, threw you out into a neighbouring control. Exploring
# the keys of a control you deliberately entered should not be something you do carefully.
# The way out is a key you CHOSE: Tab, or Esc.
ft-textfield name=ml rows=4 size=16 wrap=true value=$'a\nb\nc\nd\ne\nf'; ft_layout tabapp
FT_FOCUS=ml
ft_textfield_idle_down ml; check "multiline Down SCROLLS" "$(_voff ml)" "1"
check "scrolling did NOT enter edit mode" "$(ft_get ml runlevel; printf %s "$FT_RET")" "unfocused"
_ft_textfield_view_maxv ml; _ft_setprop ml scrollTop $FT_RET
FT_KEY_BUBBLE=0; ft_textfield_idle_down ml
check "at the bottom edge Down is CONSUMED, not an ejection" "$?/$FT_KEY_BUBBLE" "0/0"
FT_KEY_BUBBLE=0; _ft_setprop ml scrollTop 0; ft_textfield_idle_up ml
check "…and at the top edge Up likewise"                     "$?/$FT_KEY_BUBBLE" "0/0"
# The case that made it obvious: a WRAPPING box has no sideways to go, so Left/Right can
# never scroll — and must still not eject you.
FT_KEY_BUBBLE=0; ft_textfield_idle_right ml
check "a wrapping box consumes Right (no horizontal axis at all)" "$?/$FT_KEY_BUBBLE" "0/0"
FT_KEY_BUBBLE=0; ft_textfield_idle_left ml
check "…and Left"                                                 "$?/$FT_KEY_BUBBLE" "0/0"
# A single-line field never reaches this rung (ft_textfield_engage skips it), but if it is
# driven here directly the same rule holds — no key at this runlevel ejects you.
ft-textfield name=sl rows=1 size=10 value="hi"; ft_layout tabapp; FT_FOCUS=sl
FT_KEY_BUBBLE=0; ft_textfield_idle_down sl
check "single-line Down is consumed too" "$?/$FT_KEY_BUBBLE" "0/0"
for k in up down pgup pgdn home end left right; do
    FT_KEY_BUBBLE=0; "ft_textfield_idle_$k" ml >/dev/null 2>&1
    check "…nor does $k at this runlevel" "$?/$FT_KEY_BUBBLE" "0/0"
done

note "a non-wrapping overflowing READ-ONLY viewer pans sideways (horizontal scroll), clamped"
ft-form name=hbapp width=30 height=12
  ft-textfield name=code readOnly=true wrap=false rows=4 size=10 \
      value=$'short\nthis line is far wider than ten columns for sure'
  ft-textfield name=wr rows=4 size=10 wrap=true value=$'aaa\nbbb'
end_ft_form
ft_layout hbapp; FT_ROOT=hbapp; FT_FOCUS=code
FT_OUT=""; _ft_draw_textfield code                 # draw records the clamped h-scroll range
ft_textfield_idle_right code; ft_textfield_idle_right code
check "Right pans the code panel (hscroll>0)" "$([[ $(_hoff code) -gt 0 ]] && echo y)" "y"
_i=0; while (( _i++ < 60 )); do ft_textfield_idle_right code; done
FT_OUT=""; _ft_draw_textfield code                 # re-clamps hscroll to (widest line − width)
check "hscroll clamps at the last column (< line length)" "$([[ $(_hoff code) -lt 48 ]] && echo y)" "y"
# a WRAPPING field never pans horizontally
FT_FOCUS=wr; ft_textfield_idle_right wr; check "wrapped field does not h-scroll" "$(_hoff wr)" "0"

note "destroy releases a field's scroll state (rebuilt field starts fresh, not stale)"
_ft_setprop ml scrollTop 3; FT_TEXTFIELD_CARET[ml]=9; ft_remove ml
# Asked of the property VARIABLE, not through _voff: an offset reads as 0 when it is absent, so
# reading it could never tell "cleared" from "at the top". ft_remove clears a control's
# properties, which is what releases the offset now that it is one.
_mlv="_ftp_ml_scrollTop"
check "the scroll offset is cleared on destroy" "${!_mlv:-unset}" "unset"
check "caret cleared on destroy"   "${FT_TEXTFIELD_CARET[ml]:-unset}"   "unset"

note "bracketed paste: insert at caret, flatten newlines on one line, replace selection"
ft-textfield name=pp size=20 value="ab"; ft_layout app; FT_FOCUS=pp
FT_TEXTFIELD_CARET[pp]=1; FT_PASTE="XY"; ft_textfield_paste pp
ft_get pp value; check "paste inserts at the caret" "$FT_RET" "aXYb"
ft-textfield name=pp2 size=20 value=""; ft_layout app; FT_FOCUS=pp2
FT_PASTE=$'one\ntwo'; ft_textfield_paste pp2
ft_get pp2 value; check "single-line paste flattens newline → space" "$FT_RET" "one two"
ft-textfield name=pp3 size=20 rows=3 value=""; ft_layout app; FT_FOCUS=pp3
FT_PASTE=$'a\nb'; ft_textfield_paste pp3
ft_get pp3 value; check "textarea paste keeps the newline" "$FT_RET" $'a\nb'
ft-textfield name=pp4 size=20 value="hello"; ft_layout app; FT_FOCUS=pp4
FT_TEXTFIELD_CARET[pp4]=5; ft_textfield_select_home pp4; FT_PASTE="X"; ft_textfield_paste pp4
ft_get pp4 value; check "paste replaces the active selection" "$FT_RET" "X"

note "clipboard keys: Alt+W copies, Ctrl+W cuts a selection (else kills a word)"
ft-textfield name=cw size=20 value="the quick brown"; ft_layout app; FT_FOCUS=cw
FT_TEXTFIELD_CARET[cw]=15                        # end, no selection
ft_textfield_ctrl_w cw
ft_get cw value; check "Ctrl+W with no selection kills a word" "$FT_RET" "the quick "
FT_TEXTFIELD_CARET[cw]=10; unset 'FT_TEXTFIELD_ANCHOR[cw]'
ft_textfield_select_home cw                            # select "the quick "
ft_textfield_ctrl_w cw
ft_get cw value; check "Ctrl+W with a selection cuts it" "$FT_RET" ""
ft-textfield name=cw2 size=20 value="keepme"; ft_layout app; FT_FOCUS=cw2
FT_TEXTFIELD_CARET[cw2]=6; ft_textfield_select_home cw2; ft_textfield_copy cw2
ft_get cw2 value; check "Alt+W copy leaves the value unchanged" "$FT_RET" "keepme"

note "kill-ring: kills push; Ctrl+Y yanks the top; Alt+Y (yank-pop) cycles older"
FT_KILL_RING=(); _FT_YANK_ACTIVE=0
ft-textfield name=kr size=30 value="alpha beta gamma"; ft_layout app; FT_FOCUS=kr
FT_TEXTFIELD_CARET[kr]=16
ft_textfield_kill_word kr; check "first kill pushed 'gamma'" "${FT_KILL_RING[0]}" "gamma"
ft_get kr value;    check "value after kill" "$FT_RET" "alpha beta "
ft_textfield_kill_word kr; check "second kill pushed 'beta '" "${FT_KILL_RING[0]}" "beta "
ft_textfield_yank kr;      ft_get kr value; check "Ctrl+Y yanked the top ('beta ')" "$FT_RET" "alpha beta "
ft_textfield_yank_pop kr;  ft_get kr value; check "Alt+Y popped to older ('gamma')" "$FT_RET" "alpha gamma"
ft_textfield_move_left kr                          # a motion ends the yank cycle
ft_textfield_yank_pop kr;  ft_get kr value; check "Alt+Y after a move is a no-op" "$FT_RET" "alpha gamma"
ft_textfield_copy kr >/dev/null 2>&1           # (no selection → no push)
FT_KILL_RING=("ZZ")
ft-textfield name=kr3 size=20 value="abcde"; ft_layout app; FT_FOCUS=kr3
FT_TEXTFIELD_CARET[kr3]=5; ft_textfield_select_home kr3; ft_textfield_yank kr3
ft_get kr3 value; check "Ctrl+Y replaces the active selection" "$FT_RET" "ZZ"

note "readOnly: edits are inert; navigation, selection and copy still work"
ft-textfield name=ro size=20 value="frozen text" readOnly=true; ft_layout app; FT_FOCUS=ro
FT_TEXTFIELD_CARET[ro]=0;  ft_textfield_insert_char ro "X"; ft_get ro value; check "readOnly ignores typing"   "$FT_RET" "frozen text"
FT_TEXTFIELD_CARET[ro]=5;  ft_textfield_backspace ro;       ft_get ro value; check "readOnly ignores backspace" "$FT_RET" "frozen text"
ft_textfield_delete ro;                              ft_get ro value; check "readOnly ignores delete"    "$FT_RET" "frozen text"
FT_TEXTFIELD_CARET[ro]=11; ft_textfield_kill_to_start ro;   ft_get ro value; check "readOnly ignores Ctrl+U"    "$FT_RET" "frozen text"
FT_PASTE="ZZ";      ft_textfield_paste ro;           ft_get ro value; check "readOnly ignores paste"     "$FT_RET" "frozen text"
FT_KILL_RING=("YY"); ft_textfield_yank ro;           ft_get ro value; check "readOnly ignores yank"      "$FT_RET" "frozen text"
FT_TEXTFIELD_CARET[ro]=11; ft_textfield_move_left ro; _ft_textfield_caret ro; check "readOnly Left navigates" "$FT_RET" "10"
FT_TEXTFIELD_CARET[ro]=11; unset 'FT_TEXTFIELD_ANCHOR[ro]'; ft_textfield_select_home ro
_ft_textfield_selrange ro && r="[$FT_SELECTION_START,$FT_SELECTION_END)" || r=none; check "readOnly Shift+Home selects" "$r" "[0,11)"
FT_KILL_RING=(); ft_textfield_copy ro; check "readOnly Alt+W copies" "${FT_KILL_RING[0]}" "frozen text"
FT_CURSOR_BLINK=1; _ft_textfield_cursor_shape ro; check "readOnly cursor = blinking underline (3)" "$FT_RET" "3"

note "chrome: every field frames its well with focus-border bars (+2 cols)"
ft-textfield name=cf size=12 value="hi"
_ft_preferred_width_textfield cf; check "single-line prefw = size + 2 bars" "$FT_RET" "14"
_ft_textfield_chrome cf
check "single-line reserves no line-number gutter" "$FT_TEXTFIELD_LINE_NUMBER_WIDTH" "0"
check "single-line reserves no wrap-indicator col"  "$FT_TEXTFIELD_WRAP_INDICATOR_WIDTH" "0"

note "textarea line-number + wrap-indicator gutters widen the box, not the text"
ft-textfield name=cta size=20 rows=4 showLineNumbers=true wrapIndicator=true value=$'aaa\nbbb'
_ft_textfield_chrome cta
check "left bar reserved"                    "$FT_TEXTFIELD_LEFT_BORDER"  "1"
check "right bar reserved"                   "$FT_TEXTFIELD_RIGHT_BORDER"  "1"
check "line-number width = 1 digit + space"  "$FT_TEXTFIELD_LINE_NUMBER_WIDTH" "2"
check "wrap-indicator column reserved (2 wide)" "$FT_TEXTFIELD_WRAP_INDICATOR_WIDTH" "2"
_ft_preferred_width_textfield cta; check "prefw = size + bars + lnum + wrapind (26)" "$FT_RET" "26"

note "line numbers count LOGICAL lines; soft-wrap continuations get none"
ft-textfield name=cln size=6 rows=6 wrap=true value=$'hello world\nbye'
_ft_textfield_layout cln 6         # "hello world" → "hello " / "world"; then "bye"
check "3 visual lines (2 logical + 1 soft-wrap)" "${#FT_TEXTFIELD_LINES_TEXT[@]}" "3"
check "line 0 soft-wraps (CONT=1)"        "${FT_TEXTFIELD_LINES_CONT[0]}" "1"
check "line 1 ends a logical line (CONT=0)" "${FT_TEXTFIELD_LINES_CONT[1]}" "0"
check "line 0 numbered 1"                 "${FT_TEXTFIELD_LINES_NUMBER[0]}" "1"
check "line 1 (continuation) unnumbered"  "${FT_TEXTFIELD_LINES_NUMBER[1]}" "0"
check "line 2 numbered 2"                 "${FT_TEXTFIELD_LINES_NUMBER[2]}" "2"

note "hard-newline indicator: ¶ marks a line ending in a real \\n, not a soft wrap or the last line"
# same layout: line 0 soft-wraps (¶ off), line 1 ends logical line 1 which a \n follows (¶ on),
# line 2 is the final logical line (¶ off — end of text, no newline after).
check "line 0 soft-wrap → not a hard newline" "${FT_TEXTFIELD_LINES_HARD[0]}" "0"
check "line 1 ends at a hard \\n"              "${FT_TEXTFIELD_LINES_HARD[1]}" "1"
check "line 2 is the last line → no ¶"        "${FT_TEXTFIELD_LINES_HARD[2]}" "0"

note "focus border: the caret sits INSIDE the left bar"
ft-form name=capp width=40 height=10
    ft-textfield name=cc size=8 value="hi"
end_ft_form
ft_layout capp; FT_ROOT=capp; FT_FOCUS=cc
FT_TEXTFIELD_CARET[cc]=2
_ft_textfield_caret_screen cc
check "single-line caret offset by the left bar" "$(( FT_CARET_C - FT_ABSOLUTE_X[cc] ))" "3"

note "Ctrl+Home / Ctrl+End (and M-< / M->) jump to the document ends"
ft-form name=dapp width=40 height=10
    ft-textfield name=cdoc rows=4 size=20 wrap=true value=$'line one\nline two\nline three'
end_ft_form
ft_layout dapp; FT_ROOT=dapp; FT_FOCUS=cdoc
ft_get cdoc value; dlen=${#FT_RET}
FT_TEXTFIELD_CARET[cdoc]=12; ft_dispatch_event CTRL+home
check "Ctrl+Home → caret 0"        "${FT_TEXTFIELD_CARET[cdoc]}" "0"
ft_dispatch_event CTRL+end
check "Ctrl+End → caret at end"     "${FT_TEXTFIELD_CARET[cdoc]}" "$dlen"
FT_TEXTFIELD_CARET[cdoc]=12; ft_dispatch_event 'ALT+<'
check "M-< → caret 0"              "${FT_TEXTFIELD_CARET[cdoc]}" "0"
ft_dispatch_event 'ALT+>'
check "M-> → caret at end"         "${FT_TEXTFIELD_CARET[cdoc]}" "$dlen"
FT_TEXTFIELD_CARET[cdoc]=12; _ft_textfield_sel_clear cdoc; ft_dispatch_event SHIFT+CTRL+home
check "Shift+Ctrl+Home extends selection to start (caret)" "${FT_TEXTFIELD_CARET[cdoc]}" "0"
check "Shift+Ctrl+Home keeps the anchor"                   "${FT_TEXTFIELD_ANCHOR[cdoc]}" "12"

note "markdown=true makes a read-only rich VIEWER: no caret, arrows scroll"
ft-form name=mapp width=60 height=16
    ft-textfield name=mv size=40 rows=6 readOnly=true markdown=true \
        value=$'# Title\n\npara one is here\n\n- a\n- b\n- c\n- d\n- e\n- f\n- g\n- h'
end_ft_form
ft_layout mapp; FT_ROOT=mapp; FT_FOCUS=mv
_ft_textfield_md mv && check "predicate: mv is a markdown field" 1 1 || check "predicate: mv is a markdown field" 0 1
_ft_textfield_md_render mv
check "markdown viewer renders many lines" "$(( FT_MARKDOWN_TOTAL > 6 ))" "1"
_ft_setprop mv scrollTop 0
ft_dispatch_event DOWN;  check "Down scrolls the viewer by 1"  "$(_voff mv)" "1"
ft_dispatch_event DOWN;  check "Down again → 2"                "$(_voff mv)" "2"
ft_dispatch_event UP;    check "Up scrolls back"              "$(_voff mv)" "1"
ft_dispatch_event CTRL+home; check "Ctrl+Home → top"          "$(_voff mv)" "0"
ft_dispatch_event CTRL+end
mvmax=$(( FT_MARKDOWN_TOTAL - 6 )); (( mvmax < 0 )) && mvmax=0
check "Ctrl+End → bottom (clamped)"                           "$(_voff mv)" "$mvmax"
_ft_textfield_caret_screen mv; check "no editing caret in a markdown viewer" "$FT_CARET_R" "-1"
ft_get mv value; ins_before=$FT_RET
_ft_textfield_type mv x 2>/dev/null
ft_get mv value
check "markdown viewer rejects edits (read-only)" "$FT_RET" "$ins_before"

note "emacs mark: Ctrl+Space starts a sticky region that PLAIN motion extends"
ft-form name=mkapp width=40 height=8
    ft-textfield name=mk size=20 value="hello world foo"
end_ft_form
ft_layout mkapp; FT_ROOT=mkapp; FT_FOCUS=mk
FT_TEXTFIELD_CARET[mk]=0; _ft_textfield_sel_clear mk; unset "FT_TEXTFIELD_MARK[mk]"
ft_dispatch_event CTRL+SPACE
_ft_textfield_mark_active mk && check "Ctrl+Space activates the mark" 1 1 || check "Ctrl+Space activates the mark" 0 1
check "mark anchored at caret" "${FT_TEXTFIELD_ANCHOR[mk]}" "0"
ft_dispatch_event RIGHT; ft_dispatch_event RIGHT; ft_dispatch_event RIGHT   # PLAIN motion
if _ft_textfield_selrange mk; then check "plain Right extends the region" "$FT_SELECTION_START-$FT_SELECTION_END" "0-3"; else check "plain Right extends the region" "sel" "none"; fi
ft_dispatch_event ALT+f                                                     # plain word-fwd extends too
_ft_textfield_selrange mk && check "plain word-forward keeps extending" "$FT_SELECTION_END" "5" || check "extend word" 0 1

note "Ctrl+G cancels the region and the mark"
ft_dispatch_event CTRL+g
_ft_textfield_mark_active mk && check "Ctrl+G clears the mark" 0 1 || check "Ctrl+G clears the mark" 1 1
_ft_textfield_selrange mk && check "Ctrl+G clears the selection" 0 1 || check "Ctrl+G clears the selection" 1 1

note "an edit consumes the region and deactivates the mark"
FT_TEXTFIELD_CARET[mk]=0; ft_dispatch_event CTRL+SPACE
ft_dispatch_event RIGHT; ft_dispatch_event RIGHT       # region [0,2]
_ft_textfield_type mk Z
_ft_textfield_mark_active mk && check "typing deactivates the mark" 0 1 || check "typing deactivates the mark" 1 1
ft_get mk value; check "typed text replaced the region" "$FT_RET" "Zllo world foo"

note "second Ctrl+Space toggles the mark back off"
FT_TEXTFIELD_CARET[mk]=1; ft_dispatch_event CTRL+SPACE; ft_dispatch_event CTRL+SPACE
_ft_textfield_mark_active mk && check "double Ctrl+Space leaves no mark" 0 1 || check "double Ctrl+Space leaves no mark" 1 1

note "editHint: a custom exit hint (spaces allowed) overrides the generic edit-mode hint"
ft-textfield name=eh value="x" parent=app editHint="Esc applies the CSS and exits."
_ft_get_raw eh editHint
check "editHint stores despite spaces (a registered prop always assigns)" "$FT_RET" "Esc applies the CSS and exits."
ft_textfield_activate eh
check "entering edit shows editHint as the mode hint" "$FT_MODE_HINT" "Esc applies the CSS and exits."
ft_textfield_deactivate eh
check "leaving clears the mode hint" "$FT_MODE_HINT" ""
ft-textfield name=eh2 value="y" parent=app
ft_textfield_activate eh2
# The generic hint NAMES THE RUNLEVEL now ("Editing" / "Perusing"), in the same voice as the
# scrolling one. It used to say "edit mode" / "cursor mode" — vocabulary from before the
# runlevels were named, so the status bar announced a state nothing else in the framework used.
check "a field WITHOUT editHint keeps the generic hint" "$FT_MODE_HINT" "Editing — ESC to leave."
ft_textfield_deactivate eh2

note "on_deactivate fires on leaving edit (commit-on-leave), with the final value visible"
_DEACT=""
eh3_on_deactivate() { ft_get eh3 value; _DEACT=$FT_RET; }
ft-textfield name=eh3 value="start" parent=app onDeactivate=eh3_on_deactivate
ft_textfield_activate eh3
printf -v _ftp_eh3_value '%s' "committed text"
ft_textfield_deactivate eh3
check "on_deactivate ran and saw the final value" "$_DEACT" "committed text"
_DEACT="not-again"
ft_textfield_deactivate eh3            # idle field: deactivate is a no-op, must NOT refire
check "on_deactivate does NOT refire on an already-idle field" "$_DEACT" "not-again"

note "Shift+Tab removes a soft tab BEFORE the caret, not only leading-of-line spaces"
ft-textfield name=ind rows=3 value="" parent=app
ft_textfield_activate ind
printf -v _ftp_ind_value '%s' "foo    bar"; FT_TEXTFIELD_CARET[ind]=7   # caret just after the 4 spaces
_ft_textfield_unindent ind
ft_get ind value; check "mid-line spaces before caret are eaten" "$FT_RET" "foobar"
check "caret follows the deletion" "${FT_TEXTFIELD_CARET[ind]}" "3"
printf -v _ftp_ind_value '%s' "a"$'\n'"    foo"; FT_TEXTFIELD_CARET[ind]=6   # 2nd line, caret after indent
_ft_textfield_unindent ind
ft_get ind value; check "leading indent on a later line is dedented" "$FT_RET" $'a\nfoo'

note "the key legend is STATE-DEPENDENT: idle vs editing, selection → copy/cut, kill → paste"
capstr() { FT_CAPS=(); _ft_legend_caps; printf '%s' "${FT_CAPS[*]}"; }
ft-textfield name=cap rows=3 value="hello world" parent=app
FT_FOCUS=cap                                  # ring was built before this field; point focus directly
[[ "$(capstr)" == *"ENTER"*"Edit"* ]] && check "idle field offers Enter: Edit" 1 1 || check "idle field offers Enter: Edit" 0 1
ft_textfield_activate cap
s=$(capstr)
[[ "$s" == *"New line"* ]] && check "editing a textarea shows Enter: New line" 1 1 || check "editing a textarea shows Enter: New line" 0 1
[[ "$s" == *$'ENTER\tEdit'* ]] && check "…and NOT a stale Enter: Edit" 0 1 || check "…and NOT a stale Enter: Edit" 1 1
FT_KILL_RING=()                                # earlier kill-ring tests polluted the global
FT_TEXTFIELD_CARET[cap]=0; ft_textfield_set_mark cap; FT_TEXTFIELD_CARET[cap]=5      # a live selection 0..5
s=$(capstr)
{ [[ "$s" == *"Copy"* ]] && [[ "$s" == *"Cut"* ]]; } && check "a selection offers Copy + Cut" 1 1 || check "a selection offers Copy + Cut" 0 1
[[ "$s" == *"Paste"* ]] && check "nothing to paste yet" 0 1 || check "nothing to paste yet" 1 1
ft_textfield_copy cap
[[ "$(capstr)" == *"Paste"* ]] && check "after copy, Paste is offered" 1 1 || check "after copy, Paste is offered" 0 1

note "modifiers SPELL OUT (Ctrl/Alt/Shift-key), readable; arrows stay as ↑↓←→ glyphs"
_ft_keycap_glyph ALT+w;     check "Alt+W → Alt-W"        "$FT_RET" "Alt-W"
_ft_keycap_glyph CTRL+c;    check "Ctrl+C → Ctrl-C"      "$FT_RET" "Ctrl-C"
_ft_keycap_glyph SHIFT+TAB; check "Shift+Tab spelled"    "$FT_RET" "Shift-Tab"
_ft_keycap_glyph UP;        check "arrows are readable glyphs" "$FT_RET" "↑"

note "the legend prefers HUMAN keys by default, EMACS keys once a mark is set"
ft-textfield name=km rows=2 value="hello world" parent=app
FT_FOCUS=km; ft_textfield_activate km; FT_KILL_RING=()
keys() { FT_CAPS=(); _ft_legend_caps; local e r p l out=""; for e in "${FT_CAPS[@]}"; do r=${e#*$'\t'}; p=${r%$'\t'*}; l=${r#*$'\t'}; out+="$p:$l "; done; echo "$out"; }
FT_TEXTFIELD_ANCHOR[km]=0; FT_TEXTFIELD_CARET[km]=5                        # shift-style selection (no mark)
s=$(keys); { [[ "$s" == *"CTRL+c:Copy"* ]] && [[ "$s" == *"CTRL+x:Cut"* ]]; } \
    && check "shift-select → Ctrl+C / Ctrl+X" 1 1 || check "shift-select → Ctrl+C / Ctrl+X" 0 1
[[ "$s" == *"ALT+w"* ]] && check "…and NOT the emacs Alt+W by default" 0 1 || check "…and NOT the emacs Alt+W by default" 1 1
unset "FT_TEXTFIELD_ANCHOR[km]"; FT_TEXTFIELD_CARET[km]=0; ft_textfield_set_mark km; FT_TEXTFIELD_CARET[km]=5   # emacs mark
s=$(keys); { [[ "$s" == *"ALT+w:Copy"* ]] && [[ "$s" == *"CTRL+w:Cut"* ]]; } \
    && check "emacs mark → Alt+W / Ctrl+W" 1 1 || check "emacs mark → Alt+W / Ctrl+W" 0 1

note "the border animation is a CSS structure: textfield::border { animation: … } drives it"
ft-form name=baf width=24 height=6; ft-textfield name=baf_tf value="hi" width=14; end_ft_form
_ft_border_anim_name baf_tf; check "default (no rule, no property) → the calm sheen" "$FT_RET" sheen
ft-modify baf_tf activateBorderAnimation=beacon
_ft_border_anim_name baf_tf; check "activateBorderAnimation=beacon overrides the default" "$FT_RET" beacon
ft-modify baf_tf activateBorderAnimation=none
_ft_border_anim_name baf_tf; check "activateBorderAnimation=none → off" "$FT_RET" ""
ft-modify baf_tf activateBorderAnimation=""
ft_stylesheet name=batest style='textfield::border { animation: none; }'
_ft_border_anim_name baf_tf; check "::border { animation: none } → off"   "$FT_RET" ""
ft_stylesheet name=batest style='textfield::border { animation: beacon; }'
_ft_border_anim_name baf_tf; check "::border { animation: beacon } → beacon" "$FT_RET" beacon
ft_stylesheet name=batest style='textfield::border { animation: none; } textfield:focus::border { animation: sheen; }'
FT_FOCUS=""     ; _ft_border_anim_name baf_tf; check "unfocused :focus::border → off"  "$FT_RET" ""
FT_FOCUS=baf_tf ; _ft_border_anim_name baf_tf; check "focused  :focus::border → sheen" "$FT_RET" sheen
FT_FOCUS=""; ft_stylesheet name=batest style=''

note "the border sheen paints ONLY when a border-anim frame is bound — not when a CSS"
note "structure animation (a pulsing scrollbar) merely arms the SAME per-control loop"
ft-form name=sgf width=30 height=6; ft-textfield name=sgtf value=$'a\nb\nc\nd\ne\nf' width=20 height=4 multiline=true; end_ft_form
ft_layout sgf; FT_ROOT=sgf; ft_focus sgtf
# a CSS loop is armed (phase present) but NO border-anim frame is bound (FT_ANIM_FRAME empty)
FT_ANIM_PHASE[sgtf]=5; unset "FT_ANIM_FRAME[sgtf]" "FT_SHEEN_FROZEN[sgtf]" 2>/dev/null
FT_OUT=""; _ft_border_anim_overlay sgtf 0 0 4 20 "$FT_COLOR_BORDER"
[[ -z "${FT_SHEEN_FROZEN[sgtf]+x}" ]] && check "CSS-loop phase does NOT trigger the sheen" 1 1 \
                                     || check "CSS-loop phase does NOT trigger the sheen" 0 1
# now a real border animation is bound (and the field opts into sheen) → the sheen paints
ft-modify sgtf activateBorderAnimation=sheen
FT_ANIM_FRAME[sgtf]=_ft_banim_sheen_frame
FT_OUT=""; _ft_border_anim_overlay sgtf 0 0 4 20 "$FT_COLOR_BORDER"
[[ -n "${FT_SHEEN_FROZEN[sgtf]+x}" ]] && check "a bound sheen frame DOES paint the sheen" 1 1 \
                                     || check "a bound sheen frame DOES paint the sheen" 0 1

note "a caret/selection span (which may be bold) closes with a reset — bold must NOT leak right"
_ft_textfield_rowspan "SGR" $'\e[1mCARET' "hello world" 2 5    # sel carries bold (\e[1m)
# the text AFTER the span must be preceded by a reset, so no bold bleeds to the rest of the row
[[ "$FT_RET" == *$'\e[0m'"SGR world" ]] && check "span is reset before the trailing text" 1 1 \
                                       || check "span is reset before the trailing text" 0 1
_ft_textfield_rowspan "SGR" "SEL" "abc" 0 0    # empty span (vhi<=vlo) → plain row, no stray reset
check "no span → plain row" "$FT_RET" "SGRabc"

note "THE CONTRACT: if a field draws a scrollbar, ENTER must stop at the 'scrolling' rung"
# can_scroll decides whether ENTER stops at `scrolling`, so it has to answer the same question
# the DRAW answers when it decides to put a bar on the box. It asked only about VERTICAL
# overflow, behind a `multiline` gate — so a non-wrapping panel that PANS SIDEWAYS drew a
# horizontal scrollbar and still skipped straight to perusing/editing. Both axes now.
ft-form name=scrollagree width=120 height=40
    ft-textfield name=agTall  rows=4 size=30 value=$'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8'
    ft-textfield name=agFits  rows=4 size=30 value=$'a\nb'
    ft-textfield name=agPanRo rows=3 size=30 wrap=false readOnly=true \
                 value="a single line far wider than its box will ever be, on and on and on"
    ft-textfield name=agPan1  rows=1 size=20 wrap=false \
                 value="a single line far wider than its box will ever be, on and on and on"
    ft-textfield name=agPlain rows=1 size=30 value="short"
    # …and the shape that asked the wrong question: a NON-WRAPPING box whose lines each fit but
    # whose value, newlines and all, is longer than the box is wide. No bar, and ENTER stopped at
    # `scrolling` anyway — the predicate measured the value, the draw the widest line.
    ft-textfield name=agLinesFit   rows=4 size=20 wrap=false value=$'alpha beta\ngamma delta\nepsilon'
    ft-textfield name=agLinesFitRo rows=4 size=20 wrap=false readOnly=true value=$'alpha beta\ngamma delta\nepsilon'
    ft-textfield name=agOneTooWide rows=4 size=20 wrap=false value=$'alpha beta gamma delta epsilon\nb'
    # …and a ONE-LINE field has nothing to wrap: a long value draws its bar whatever `wrap` says,
    # so ENTER must stop at `scrolling` for it too — where the arrows then have to pan it.
    ft-textfield name=agLongLine rows=1 size=12 value="someone.with.a.long.address@example.com"
end_ft_form
ft_layout scrollagree
FT_OUT=""; _ft_redraw_walk scrollagree
for _f in agTall agFits agPanRo agPan1 agPlain agLinesFit agLinesFitRo agOneTooWide agLongLine; do
    FT_OUT=""; ft_draw_one "$_f"                       # publish this field's bars
    _want=no
    [[ -n "${FT_TEXTFIELD_VBAR[$_f]:-}" || -n "${FT_TEXTFIELD_HBAR[$_f]:-}" ]] && _want=YES
    _got=no; _ft_textfield_can_scroll "$_f" && _got=YES
    check "$_f: draws a bar ($_want) ⇔ can_scroll" "$_got" "$_want"
done
check "a sideways-panning viewer can scroll"   "$(_ft_textfield_can_scroll agPanRo && echo YES)" YES
check "…and so can a one-line panning field"   "$(_ft_textfield_can_scroll agPan1  && echo YES)" YES
check "an ordinary short input still cannot"   "$(_ft_textfield_can_scroll agPlain || echo no)"  no
# Anti-vacuity for the new pair: the same box with ONE line too wide must draw its bar, or the two
# "no bar" verdicts above would pass on a draw that never draws one.
check "a box with one line too wide draws a bar" "${FT_TEXTFIELD_HBAR[agOneTooWide]:+YES}" YES
check "a long one-line field draws a bar"         "${FT_TEXTFIELD_HBAR[agLongLine]:+YES}" YES
FT_FOCUS=agLongLine; _ft_setprop agLongLine runlevel poised; ft_textfield_engage agLongLine
check "ENTER on it stops at scrolling"            "$(ft_get agLongLine runlevel; printf %s "$FT_RET")" scrolling
ft_textfield_idle_right agLongLine; ft_textfield_idle_right agLongLine
check "…where Right pans it"                      "$(_ft_get_raw agLongLine scrollLeft; printf %s "$FT_RET")" 2
for _i in $(seq 1 60); do ft_textfield_idle_right agLongLine; done
_ft_textfield_hscroll_max agLongLine; _agmax=$FT_RET
check "…never past the last column"               "$(_ft_get_raw agLongLine scrollLeft; printf %s "$FT_RET")" "$_agmax"
check "…which is value minus well (39 - 12)"      "$_agmax" 27
ft_textfield_idle_left agLongLine
check "…and Left pans back"                       "$(_ft_get_raw agLongLine scrollLeft; printf %s "$FT_RET")" 26
FT_FOCUS=""

# ── Enter-to-commit asks the LISTENER REGISTRY, not a function name ──────────
# docs/api-naming.md: "There is NO name-convention magic: a function named <name>_on_<event>
# is just a function — wire it … or it never runs" (pinned by tests/test-domapi.bash). Enter
# in a single-line field used to decide "submit or commit-and-leave" by probing for a function
# CALLED <name>_on_activate, while the dispatch it then ran reads the eventListeners plist —
# two registries on one route, and both halves of the mismatch were reachable:
#   · wired the documented way but not convention-named → Enter fired NOTHING
#   · convention-named but never wired                  → Enter went inert AND left the field
#                                                         stranded in edit mode
# The demos never saw it because they both name their handlers <name>_on_activate AND wire them.
note "Enter fires the field's activate LISTENER, whatever the listener is called"
ft-form name=enterapp width=44 height=10
    ft-textfield name=fWired size=10 value="one"   onActivate=submit_the_form
    ft-textfield name=fConv  size=10 value="two"
    ft-textfield name=fBoth  size=10 value="three" onActivate=fBoth_on_activate
end_ft_form
ft_layout enterapp
ELOG=""
submit_the_form()   { ELOG+="wired "; }
fConv_on_activate() { ELOG+="convention "; }
fBoth_on_activate() { ELOG+="both "; }

# 1. wired, NOT convention-named: the documented way, and it must fire.
FT_FOCUS=fWired; ft_textfield_activate fWired
ELOG=""; ft_textfield_enter fWired
check "a listener wired by onActivate= fires on Enter" "$ELOG" "wired "

# 2. defined but never wired: the function is just a function — Enter must ignore it entirely
#    and do what a field with no submit handler does, which is leave edit mode.
FT_FOCUS=fConv; ft_textfield_activate fConv
check "…the unwired field is in edit mode first" "$(ft_get fConv runlevel; printf %s "$FT_RET")" "editing"
ELOG=""; ft_textfield_enter fConv
check "a defined-but-unwired <name>_on_activate never runs" "$ELOG" ""
check "…and Enter still commits and leaves edit mode" \
      "$(_ft_textfield_engaged fConv && echo stuck-in-edit || echo left)" "left"

# 3. wired AND convention-named (every demo): fires, exactly once.
FT_FOCUS=fBoth; ft_textfield_activate fBoth
ELOG=""; ft_textfield_enter fBoth
check "wired and convention-named fires once" "$ELOG" "both "

# A textarea is unaffected: Enter is a newline there, listener or no listener.
ft-textfield name=fArea rows=3 size=16 value="ab" parent=enterapp onActivate=submit_the_form
ft_layout enterapp
FT_FOCUS=fArea; ft_textfield_activate fArea; FT_TEXTFIELD_CARET[fArea]=2
ELOG=""; ft_textfield_enter fArea
check "a textarea's Enter is still a newline, not a submit" "$ELOG" ""
check "…and it really typed one" "$(ft_get fArea value; printf %s "${FT_RET//$'\n'/<NL>}")" "ab<NL>"
ft_remove enterapp

summary
