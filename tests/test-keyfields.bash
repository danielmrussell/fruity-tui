#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  KEY FIELDS: ONE GRAMMAR, AND AN ACTION IS CODE.
#
#  A binding is written as separate shell words — key=PATTERN, then keyCap=, keyImp= and
#  onKey= describing that key until the next key=. Three earlier designs packed the same
#  four things into ONE token (PATTERN=action, then PATTERN="cap":imp:'code'), and every one
#  of them needed an escape rule for its own delimiter. The author's verdict on requiring
#  escapes was "this is unacceptable", and this gate is what "nothing needs escaping" means
#  in practice: a cap containing a colon, a comma, quotes AND an equals sign; code containing
#  semicolons, quotes, an `=` and a newline; a bash character class as a pattern. If any of
#  those needs a backslash, an assertion here fails.
#
#  The other half is that onKey holds CODE, evaluated with $this and $key in scope, because
#  a binding used to be a FUNCTION NAME with the control and the token appended invisibly
#  ("A bare word should not be a function name. Where are your arguments???"). So the same
#  cases are asserted through DISPATCH, not just through storage: what a key does is what its
#  code does, with the arguments you can see.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
unset -f ft_command_menu 2>/dev/null || true

SAW=""
saw() { SAW="$*"; }
# $(cmd 2>&1) runs cmd in a SUBSHELL, so a call that reports an error AND still binds a key
# would have the binding thrown away with the subshell — and the assertion about what landed
# would pass or fail for the wrong reason. Errors go to a file; the call runs here.
_ERR=$(mktemp "${TMPDIR:-/tmp}/ft-keyfields.XXXXXX")
trap 'rm -f "$_ERR"' EXIT
err() { "$@" 2>"$_ERR"; ERR=$(sed -n '1s/^ft: //p' "$_ERR"); }

# ── Storage: every field shape, read back through ft_keymap_dump ─────────────
note "a group is key= plus the fields that follow it"
ft_keymap g1
ft_keymap_set g1 key=ENTER keyCap="Edit" keyImp=crucial onKey='ft_activate $this'
check "one entry, four fields" "$(ft_keymap_dump g1 | tr '\t' '|')" 'ENTER|ft_activate $this|200|Edit'

ft_keymap_set g1 key=UP onKey='saw up' key=DOWN onKey='saw down'
check "several groups in one call" "$(ft_keymap_dump g1 | tail -2 | cut -f1 | tr '\n' ' ')" "UP DOWN "
check "…and the first one is untouched" "$(ft_keymap_dump g1 | head -1 | cut -f4)" "Edit"

note "nothing inside a field needs escaping — that is the entire point"
ft_keymap g2
ft_keymap_set g2 key=CTRL+s keyCap='Save: "now", ok=yes' onKey='ft_set st text="a;b"; saw done'
check "a cap with a colon, comma, quotes and an ="  "$(ft_keymap_dump g2 | cut -f4)" 'Save: "now", ok=yes'
check "code with a semicolon, quotes and an ="      "$(ft_keymap_dump g2 | cut -f2)" 'ft_set st text="a;b"; saw done'
ft_keymap_set g2 key=CTRL+r onKey=$'saw one\nsaw two'
_ft_keymap_lookup g2 CTRL+r
check "multi-line code survives as one action" "$FT_RET" $'saw one\nsaw two' 
ft_keymap_set g2 key=EQUALS keyCap=Zoom onKey='saw zoom'
check "EQUALS names the = key, the one pattern field=value cannot spell" \
      "$(ft_keymap_dump g2 | grep -c '^EQUALS')" "1"
ft_keymap_set g2 key='[[:alpha:]]' onKey='saw letter $key'
check "a bash character class is a pattern, not an error" \
      "$(ft_keymap_dump g2 | grep -c '^\[\[:alpha:\]\]')" "1"

note "keyImp takes the four keywords or a raw weight"
ft_keymap g3
ft_keymap_set g3 key=a keyCap=A keyImp=crucial   onKey='saw a' \
                 key=b keyCap=B keyImp=important onKey='saw b' \
                 key=c keyCap=C keyImp=normal    onKey='saw c' \
                 key=d keyCap=D keyImp=minor     onKey='saw d' \
                 key=e keyCap=E keyImp=137       onKey='saw e'
check "keywords resolve to the framework's one scale" \
      "$(ft_keymap_dump g3 | cut -f3 | tr '\n' ' ')" \
      "$FT_IMPORTANCE_CRUCIAL $FT_IMPORTANCE_IMPORTANT $FT_IMPORTANCE_NORMAL $FT_IMPORTANCE_MINOR 137 "
err ft_keymap_set g3 key=f keyImp=loud onKey='saw f'
check "an unknown importance is reported"      "$ERR" "g3: key=f keyImp=loud is not crucial|important|normal|minor or 0-255"
check "…and the binding still lands, at 0"     "$(ft_keymap_dump g3 | tail -1 | cut -f3)" "0"

note "authoring errors are reported, not guessed at"
ft_keymap g4
err ft_keymap_set g4 keyCap=orphan key=DEL onKey='saw del'
check "a modifier before any key= is named" "$ERR" "g4: keyCap= before any key= — dropped"
check "…and is NOT attached to the next key"   "$(ft_keymap_dump g4 | cut -f4)" ""
err ft_keymap_set g4 key= onKey='saw x'
check "key= with no pattern is refused" "$ERR" "g4: key= with no pattern"
err ft_keymap_set g4 key=Q
check "a group with neither code nor cap is refused" "$ERR" "g4: key=Q has neither onKey= nor keyCap="
err ft_keymap_set g4 nonsense=1
check "a field that is not a key field is named" "$ERR" 'g4: "nonsense=1" is not a key field'
err ft_keymap_set no_such_map key=Z onKey='saw z'
check "setting an undeclared map is refused" "$ERR" "ft_keymap_set no_such_map: no such keymap (declare it with ft_keymap)"

# REPORTING AN ERROR IS NOT REFUSING IT. Every message above went to stderr while the call
# still returned 0, so a caller testing `ft_keymap_set … || handle` saw success — and the
# suite, not this gate, is what noticed.
note "an authoring error FAILS, it does not merely complain"
no "a group with neither code nor cap"  ft_keymap_set g4 key=P
no "a modifier before any key="         ft_keymap_set g4 keyCap=orphan
no "a field that is not a key field"    ft_keymap_set g4 nonsense=1
no "key= with no pattern"               ft_keymap_set g4 key= onKey='saw x'
ok "…and a good call still succeeds"    ft_keymap_set g4 key=P onKey='saw p'

# `default` is the reserved pattern for "what an unmatched key does", and it is written as an
# ordinary group — so the entry has four fields like any other. Reading "everything after the
# first tab" gave "drop<TAB>0<TAB>", which equals neither drop nor bubble, and a drop default
# silently stopped dropping.
note "the reserved default entry survives being written as a group"
ft_keymap gd
ft_keymap_set gd key=default onKey=drop
_ft_keymap_default gd
check "the default reads back as exactly drop" "$FT_RET" "drop"
ft_keymap gd2
ft_keymap_set gd2 key=Z onKey='saw z'
_ft_keymap_default gd2
check "an undeclared default is bubble"        "$FT_RET" "bubble"

note "declaring a map twice is an error — it used to silently EMPTY it"
ft_keymap g5
ft_keymap_set g5 key=X onKey='saw x'
err ft_keymap g5
check "the second declaration is refused" "$ERR" "ft_keymap g5: already declared (use ft_keymap_clear to empty it)"
check "…and the bindings are still there"      "$(ft_keymap_dump g5 | cut -f1)" "X"
ft_keymap_clear g5
check "ft_keymap_clear is the explicit way to empty it" "$(ft_keymap_dump g5)" ""
ft_keymap_set g5 key=X onKey='saw x' key=Y onKey='saw y'
ft_keymap_unset g5 X
check "ft_keymap_unset removes one binding"    "$(ft_keymap_dump g5 | cut -f1 | tr '\n' ' ')" "Y "

note "the block form declares a map as a table of keys"
ft-keymap g6
    ft-key key=UP   keyCap=Up   keyImp=crucial onKey='saw up'
    ft-key key=DOWN keyCap=Down keyImp=crucial onKey='saw down'
end_ft_keymap
check "ft-key rows land in the open block"     "$(ft_keymap_dump g6 | cut -f1 | tr '\n' ' ')" "UP DOWN "
err ft-key key=ZZ onKey='saw z'
check "ft-key outside a block is refused" "$ERR" "ft-key: no open ft-keymap block"

# ── Dispatch: the code is what runs, with the arguments you can see ──────────
note "an action is code, with \$this and \$key in scope"
ft_keymap kd
ft_keymap_set kd key=UP    onKey='saw up $this $key' \
                 key=ENTER onKey='saw "a;b" $this' \
                 key=DROP  onKey=drop \
                 key=BUB   onKey=bubble \
                 key=CAPONLY keyCap="Someone else handles this"
ft-form name=app width=40 height=10
    ft-button name=btn text="Go" keymap=kd
end_ft_form
FT_ROOT=app; ft_layout app; ft_focus btn

SAW=""; ft_dispatch_event UP
check "the code ran with the control and the token" "$SAW" "up btn UP"
SAW=""; ft_dispatch_event ENTER
check "a quoted argument stays one word"            "$SAW" "a;b btn"
SAW=""; ft_dispatch_event DROP
check "onKey=drop claims the key"                 "$?" "0"
check "…and runs nothing"                           "$SAW" ""
ft_dispatch_event BUB
check "onKey=bubble declines it"                  "$?" "1"
ft_dispatch_event CAPONLY
check "a cap with no code is advertised, not bound" "$?" "1"

note "a multi-line action runs both lines"
ft_keymap_set kd key=M onKey=$'saw first\nSAW="$SAW+second"'
SAW=""; ft_dispatch_event M
check "both statements ran" "$SAW" "first+second"

note "an action naming nothing callable bubbles, and is reported once"
FT_UNRESOLVED_ACTIONS=()
ft_keymap_set kd key=NOPE onKey='ft_no_such_handler $this'
ft_dispatch_event NOPE
check "the key was not claimed"  "$?" "1"
ft_dispatch_event NOPE
ft_unresolved_actions
check "reported exactly once"    "$FT_RET" "btn ft_no_such_handler"

note "keymap= is a LIST, last wins"
ft_keymap la; ft_keymap_set la key=L onKey='saw from_a' key=A onKey='saw only_a'
ft_keymap lb; ft_keymap_set lb key=L onKey='saw from_b'
ft-form name=app2 width=40 height=10
    ft-button name=b2 text="Go" keymap="la lb"
end_ft_form
FT_ROOT=app2; ft_layout app2; ft_focus b2
SAW=""; ft_dispatch_event L
check "the later map wins the shared key"   "$SAW" "from_b"
SAW=""; ft_dispatch_event A
check "…and the earlier map is still consulted" "$SAW" "only_a"

note "key fields on a TAG bind that control, and beat everything shared"
ft-form name=app3 width=40 height=10
    ft-button name=b3 text="Go" keymap="la lb" key=L onKey='saw from_instance' \
              key=Z keyCap="Zap it" keyImp=crucial onKey='saw zap $this'
end_ft_form
FT_ROOT=app3; ft_layout app3; ft_focus b3
SAW=""; ft_dispatch_event L
check "the instance overlay wins"           "$SAW" "from_instance"
SAW=""; ft_dispatch_event Z
check "a second key on the same tag"        "$SAW" "zap b3"
FT_CAPS=(); _ft_keymap_caps "${FT_KEYMAP[b3]}"
check "its cap reaches the legend"          "${FT_CAPS[*]}" "$(printf '%s\t%s\t%s' "$FT_IMPORTANCE_CRUCIAL" Z "Zap it")"

note "ft_set rebinds a key on a live control"
ft_set b3 key=L onKey='saw rebound'
SAW=""; ft_dispatch_event L
check "the new code replaced the old"       "$SAW" "rebound"
check "…and the control's text is untouched" "$(ft_get b3 text; echo "$FT_RET")" "Go"

note "an instance key beats the control's prototype"
ft-form name=app4 width=40 height=10
    ft-button name=b4 text="Go" key=ENTER onKey='saw mine $this'
end_ft_form
FT_ROOT=app4; ft_layout app4; ft_focus b4
SAW=""; ft_dispatch_event ENTER
check "ENTER runs the instance code, not activate" "$SAW" "mine b4"

# ── defaultKeys ─────────────────────────────────────────────────────────────
# The blunt instrument. `onKey=bubble` drops one key; this drops everything the PROTOTYPE
# provides — its own map and the map for the runlevel it is in — and touches nothing the app
# wrote. It INHERITS, because the thing you want to say is "not in here", not "not on this one,
# and this one, and this one".
note "defaultKeys=false silences the prototype's keys, not the app's"
ft-form name=dkapp width=40 height=10
    ft-div name=dkbox
        ft-button name=dk1 text="Go" onActivate=dk_activate
        ft-button name=dk2 text="No" onActivate=dk_activate
    end_ft_div
end_ft_form
DK=""; dk_activate() { DK=fired; }
FT_ROOT=dkapp; ft_layout dkapp; ft_focus dk1
DK=""; ft_dispatch_event ENTER
check "by default the prototype's ENTER activates"  "$DK" "fired"

ft_set dk1 defaultKeys=false
DK=""; ft_dispatch_event ENTER
check "…silenced, ENTER does nothing"               "${DK:-nothing}" "nothing"
ft_set dk1 key=ENTER onKey='saw mine $this'
SAW=""; DK=""; ft_dispatch_event ENTER
check "…but the app's own key still fires"          "$SAW" "mine dk1"
check "…and still does not reach the prototype"     "${DK:-nothing}" "nothing"

ft_unset dk1 defaultKeys
ft_set dkbox defaultKeys=false
ft_focus dk2; DK=""; ft_dispatch_event ENTER
check "it INHERITS: the container silenced the child" "${DK:-nothing}" "nothing"
ft_set dk2 defaultKeys=true
DK=""; ft_dispatch_event ENTER
check "…and a child can say true again"               "$DK" "fired"

# ── The conflict report ─────────────────────────────────────────────────────
# Sharing an accessKey is a FEATURE — the letter activates the first control that is enabled
# and visible. What is a bug is a plain binding for the same letter, which wins outright
# because lookup takes the last registration: the controls keep drawing their underlined
# letter while the key does something else entirely. Found in css-demo, where a `Bold`
# checkbox with accessKey=B sat on a page whose app-level [Bb] moved back a page.
note "a shortcut that cannot fire is reported, not left to be discovered"
ft-form name=ckapp width=40 height=10
    ft-button name=ck1 text="Bold" accessKey=b
    ft-button name=ck2 text="Bottom" accessKey=b
end_ft_form
FT_ROOT=ckapp; ft_layout ckapp
ok "two controls sharing a letter is not a conflict" ft_accesskey_conflicts
ft_keymap_set "${FT_KEYMAP[ckapp]}" key='[Bb]' onKey=ft_quit
no "…until a plain binding takes the letter"        ft_accesskey_conflicts

FT_DEBUG_KEYS=1
_ft_report_key_conflicts 2>"$_ERR"; rc=$?
check "the startup report fails when it finds one"  "$rc" "1"
check "…and names the control and what beat it" \
      "$(grep -c 'ck1 advertises B, but ft_quit wins the key' "$_ERR")" "1"
FT_DEBUG_KEYS=
_ft_report_key_conflicts 2>"$_ERR"
check "…and says nothing at all unless asked"       "$(wc -c < "$_ERR")" "0"

summary
