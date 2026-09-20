#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  KEY FIELDS: ONE GRAMMAR, AND AN ACTION IS CODE.
#
#  A binding is written as separate shell words — key=PATTERN, then keyCap=, keyImp= and
#  keyCode= describing that key until the next key=. Three earlier designs packed the same
#  four things into ONE token (PATTERN=action, then PATTERN="cap":imp:'code'), and every one
#  of them needed an escape rule for its own delimiter. The author's verdict on requiring
#  escapes was "this is unacceptable", and this gate is what "nothing needs escaping" means
#  in practice: a cap containing a colon, a comma, quotes AND an equals sign; code containing
#  semicolons, quotes, an `=` and a newline; a bash character class as a pattern. If any of
#  those needs a backslash, an assertion here fails.
#
#  The other half is that keyCode holds CODE, evaluated with $this and $key in scope, because
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
ft_keymap_set g1 key=ENTER keyCap="Edit" keyImp=crucial keyCode='ft_activate $this'
check "one entry, four fields" "$(ft_keymap_dump g1 | tr '\t' '|')" 'ENTER|ft_activate $this|200|Edit'

ft_keymap_set g1 key=UP keyCode='saw up' key=DOWN keyCode='saw down'
check "several groups in one call" "$(ft_keymap_dump g1 | tail -2 | cut -f1 | tr '\n' ' ')" "UP DOWN "
check "…and the first one is untouched" "$(ft_keymap_dump g1 | head -1 | cut -f4)" "Edit"

note "nothing inside a field needs escaping — that is the entire point"
ft_keymap g2
ft_keymap_set g2 key=CTRL+s keyCap='Save: "now", ok=yes' keyCode='ft_set st text="a;b"; saw done'
check "a cap with a colon, comma, quotes and an ="  "$(ft_keymap_dump g2 | cut -f4)" 'Save: "now", ok=yes'
check "code with a semicolon, quotes and an ="      "$(ft_keymap_dump g2 | cut -f2)" 'ft_set st text="a;b"; saw done'
ft_keymap_set g2 key=CTRL+r keyCode=$'saw one\nsaw two'
_ft_keymap_lookup g2 CTRL+r
check "multi-line code survives as one action" "$FT_RET" $'saw one\nsaw two' 
ft_keymap_set g2 key=EQUALS keyCap=Zoom keyCode='saw zoom'
check "EQUALS names the = key, the one pattern field=value cannot spell" \
      "$(ft_keymap_dump g2 | grep -c '^EQUALS')" "1"
ft_keymap_set g2 key='[[:alpha:]]' keyCode='saw letter $key'
check "a bash character class is a pattern, not an error" \
      "$(ft_keymap_dump g2 | grep -c '^\[\[:alpha:\]\]')" "1"

note "keyImp takes the four keywords or a raw weight"
ft_keymap g3
ft_keymap_set g3 key=a keyCap=A keyImp=crucial   keyCode='saw a' \
                 key=b keyCap=B keyImp=important keyCode='saw b' \
                 key=c keyCap=C keyImp=normal    keyCode='saw c' \
                 key=d keyCap=D keyImp=minor     keyCode='saw d' \
                 key=e keyCap=E keyImp=137       keyCode='saw e'
check "keywords resolve to the framework's one scale" \
      "$(ft_keymap_dump g3 | cut -f3 | tr '\n' ' ')" \
      "$FT_IMPORTANCE_CRUCIAL $FT_IMPORTANCE_IMPORTANT $FT_IMPORTANCE_NORMAL $FT_IMPORTANCE_MINOR 137 "
err ft_keymap_set g3 key=f keyImp=loud keyCode='saw f'
check "an unknown importance is reported"      "$ERR" "g3: key=f keyImp=loud is not crucial|important|normal|minor or 0-255"
check "…and the binding still lands, at 0"     "$(ft_keymap_dump g3 | tail -1 | cut -f3)" "0"

note "authoring errors are reported, not guessed at"
ft_keymap g4
err ft_keymap_set g4 keyCap=orphan key=DEL keyCode='saw del'
check "a modifier before any key= is named" "$ERR" "g4: keyCap= before any key= — dropped"
check "…and is NOT attached to the next key"   "$(ft_keymap_dump g4 | cut -f4)" ""
err ft_keymap_set g4 key= keyCode='saw x'
check "key= with no pattern is refused" "$ERR" "g4: key= with no pattern"
err ft_keymap_set g4 key=Q
check "a group with neither code nor cap is refused" "$ERR" "g4: key=Q has neither keyCode= nor keyCap="
err ft_keymap_set g4 nonsense=1
check "a field that is not a key field is named" "$ERR" 'g4: "nonsense=1" is not a key field'
err ft_keymap_set no_such_map key=Z keyCode='saw z'
check "setting an undeclared map is refused" "$ERR" "ft_keymap_set no_such_map: no such keymap (declare it with ft_keymap)"

# REPORTING AN ERROR IS NOT REFUSING IT. Every message above went to stderr while the call
# still returned 0, so a caller testing `ft_keymap_set … || handle` saw success — and the
# suite, not this gate, is what noticed.
note "an authoring error FAILS, it does not merely complain"
no "a group with neither code nor cap"  ft_keymap_set g4 key=P
no "a modifier before any key="         ft_keymap_set g4 keyCap=orphan
no "a field that is not a key field"    ft_keymap_set g4 nonsense=1
no "key= with no pattern"               ft_keymap_set g4 key= keyCode='saw x'
ok "…and a good call still succeeds"    ft_keymap_set g4 key=P keyCode='saw p'

# `default` is the reserved pattern for "what an unmatched key does", and it is written as an
# ordinary group — so the entry has four fields like any other. Reading "everything after the
# first tab" gave "drop<TAB>0<TAB>", which equals neither drop nor bubble, and a drop default
# silently stopped dropping.
note "the reserved default entry survives being written as a group"
ft_keymap gd
ft_keymap_set gd key=default keyCode=drop
_ft_keymap_default gd
check "the default reads back as exactly drop" "$FT_RET" "drop"
ft_keymap gd2
ft_keymap_set gd2 key=Z keyCode='saw z'
_ft_keymap_default gd2
check "an undeclared default is bubble"        "$FT_RET" "bubble"

note "declaring a map twice is an error — it used to silently EMPTY it"
ft_keymap g5
ft_keymap_set g5 key=X keyCode='saw x'
err ft_keymap g5
check "the second declaration is refused" "$ERR" "ft_keymap g5: already declared (use ft_keymap_clear to empty it)"
check "…and the bindings are still there"      "$(ft_keymap_dump g5 | cut -f1)" "X"
ft_keymap_clear g5
check "ft_keymap_clear is the explicit way to empty it" "$(ft_keymap_dump g5)" ""
ft_keymap_set g5 key=X keyCode='saw x' key=Y keyCode='saw y'
ft_keymap_unset g5 X
check "ft_keymap_unset removes one binding"    "$(ft_keymap_dump g5 | cut -f1 | tr '\n' ' ')" "Y "

note "the block form declares a map as a table of keys"
ft-keymap g6
    ft-key key=UP   keyCap=Up   keyImp=crucial keyCode='saw up'
    ft-key key=DOWN keyCap=Down keyImp=crucial keyCode='saw down'
end_ft_keymap
check "ft-key rows land in the open block"     "$(ft_keymap_dump g6 | cut -f1 | tr '\n' ' ')" "UP DOWN "
err ft-key key=ZZ keyCode='saw z'
check "ft-key outside a block is refused" "$ERR" "ft-key: no open ft-keymap block"

# ── Dispatch: the code is what runs, with the arguments you can see ──────────
note "an action is code, with \$this and \$key in scope"
ft_keymap kd
ft_keymap_set kd key=UP    keyCode='saw up $this $key' \
                 key=ENTER keyCode='saw "a;b" $this' \
                 key=DROP  keyCode=drop \
                 key=BUB   keyCode=bubble \
                 key=CAPONLY keyCap="Someone else handles this"
ft-form name=app width=40 height=10
    ft-button name=btn "Go" keymap=kd
end_ft_form
FT_ROOT=app; ft_layout app; ft_focus btn

SAW=""; ft_dispatch_event UP
check "the code ran with the control and the token" "$SAW" "up btn UP"
SAW=""; ft_dispatch_event ENTER
check "a quoted argument stays one word"            "$SAW" "a;b btn"
SAW=""; ft_dispatch_event DROP
check "keyCode=drop claims the key"                 "$?" "0"
check "…and runs nothing"                           "$SAW" ""
ft_dispatch_event BUB
check "keyCode=bubble declines it"                  "$?" "1"
ft_dispatch_event CAPONLY
check "a cap with no code is advertised, not bound" "$?" "1"

note "a multi-line action runs both lines"
ft_keymap_set kd key=M keyCode=$'saw first\nSAW="$SAW+second"'
SAW=""; ft_dispatch_event M
check "both statements ran" "$SAW" "first+second"

note "an action naming nothing callable bubbles, and is reported once"
FT_UNRESOLVED_ACTIONS=()
ft_keymap_set kd key=NOPE keyCode='ft_no_such_handler $this'
ft_dispatch_event NOPE
check "the key was not claimed"  "$?" "1"
ft_dispatch_event NOPE
ft_unresolved_actions
check "reported exactly once"    "$FT_RET" "btn ft_no_such_handler"

note "keymap= is a LIST, last wins"
ft_keymap la; ft_keymap_set la key=L keyCode='saw from_a' key=A keyCode='saw only_a'
ft_keymap lb; ft_keymap_set lb key=L keyCode='saw from_b'
ft-form name=app2 width=40 height=10
    ft-button name=b2 "Go" keymap="la lb"
end_ft_form
FT_ROOT=app2; ft_layout app2; ft_focus b2
SAW=""; ft_dispatch_event L
check "the later map wins the shared key"   "$SAW" "from_b"
SAW=""; ft_dispatch_event A
check "…and the earlier map is still consulted" "$SAW" "only_a"

note "key fields on a TAG bind that control, and beat everything shared"
ft-form name=app3 width=40 height=10
    ft-button name=b3 "Go" keymap="la lb" key=L keyCode='saw from_instance' \
              key=Z keyCap="Zap it" keyImp=crucial keyCode='saw zap $this'
end_ft_form
FT_ROOT=app3; ft_layout app3; ft_focus b3
SAW=""; ft_dispatch_event L
check "the instance overlay wins"           "$SAW" "from_instance"
SAW=""; ft_dispatch_event Z
check "a second key on the same tag"        "$SAW" "zap b3"
FT_CAPS=(); _ft_keymap_caps "${FT_KEYMAP[b3]}"
check "its cap reaches the legend"          "${FT_CAPS[*]}" "$(printf '%s\t%s\t%s' "$FT_IMPORTANCE_CRUCIAL" Z "Zap it")"

note "ft-modify rebinds a key on a live control"
ft-modify b3 key=L keyCode='saw rebound'
SAW=""; ft_dispatch_event L
check "the new code replaced the old"       "$SAW" "rebound"
check "…and the control's text is untouched" "$(ft_get b3 text; echo "$FT_RET")" "Go"

note "an instance key beats the control's prototype"
ft-form name=app4 width=40 height=10
    ft-button name=b4 "Go" key=ENTER keyCode='saw mine $this'
end_ft_form
FT_ROOT=app4; ft_layout app4; ft_focus b4
SAW=""; ft_dispatch_event ENTER
check "ENTER runs the instance code, not activate" "$SAW" "mine b4"

summary
