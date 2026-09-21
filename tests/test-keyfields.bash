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
ft_keymap_set gd key=default onKey=drop   # the DEFAULT entry is a policy word, not an action
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
                 key=EAT   onKey='' \
                 key=BUB   onKey='ft_bubble' \
                 key=CAPONLY keyCap="Someone else handles this"
ft-form name=app width=40 height=10
    ft-button name=btn text="Go" keymap=kd
end_ft_form
FT_ROOT=app; ft_layout app; ft_focus btn

SAW=""; ft_dispatch_event UP
check "the code ran with the control and the token" "$SAW" "up btn UP"
SAW=""; ft_dispatch_event ENTER
check "a quoted argument stays one word"            "$SAW" "a;b btn"
SAW=""; ft_dispatch_event EAT
check "onKey='' claims the key"                     "$?" "0"
check "…and runs nothing"                           "$SAW" ""
ft_dispatch_event BUB
check "ft_bubble passes it on"                      "$?" "1"
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
# The blunt instrument. `onKey='ft_bubble'` passes one key on; this silences everything the PROTOTYPE
# provides — its own map and the map for the runlevel it is in — and touches nothing the app
# wrote. It INHERITS, because the thing you want to say is "not in here", not "not on this one,
# and this one, and this one".
note "defaultKeys=false silences the prototype's keys, not the app's"
ft-form name=dkapp width=40 height=10
    ft-div name=dkbox
        ft-button name=dk1 text="Go" onActivate='dk_activate "$@"'
        ft-button name=dk2 text="No" onActivate='dk_activate "$@"'
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

# ── The event model ─────────────────────────────────────────────────────────
# A key is an EVENT and a control that binds it is a SUBSCRIBER. Three things follow, and none
# of them needs a word the action parser has to know about:
#   · a handler that does its work and calls ft_bubble passes the event on ANYWAY — something
#     "decline the key" could never express, because declining meant you had not acted;
#   · `onKey=''` is code that runs and does nothing, so the control ate the event (what the
#     reserved word `drop` used to say);
#   · no onKey= at all is not a binding — a legend-only cap, advertised and left to its owner.
note "a control may handle an event AND pass it on"
EV=""
ev() { EV+="$* "; }
ft_keymap inner; ft_keymap_set inner \
    key=A onKey='' \
    key=B keyCap="not mine" \
    key=C onKey='ev inner-c; ft_bubble' \
    key=D onKey='ev inner-d'
ft_keymap outer; ft_keymap_set outer \
    key=A onKey='ev outer-a' key=B onKey='ev outer-b' key=C onKey='ev outer-c' \
    key=D onKey='ev outer-d' key=N onKey='ev outer-n'
ft-form name=evapp width=40 height=8 keymap=outer
    ft-button name=evb text="Go" keymap=inner
end_ft_form
FT_ROOT=evapp; ft_layout evapp; ft_focus evb
EV=""; ft_dispatch_event A; check "onKey='' eats it: the ancestor never sees it" "${EV:-nothing}" "nothing"
EV=""; ft_dispatch_event B; check "a legend-only cap is not a binding"           "$EV" "outer-b "
EV=""; ft_dispatch_event C; check "handled AND bubbled: both ran, in order"      "$EV" "inner-c outer-c "
EV=""; ft_dispatch_event D; check "handled and kept: only the control ran"       "$EV" "inner-d "

# THE STATE IS PER EVENT. A handler may dispatch another event — a key that opens a dialog
# which handles keys of its own — and the inner one must not answer the outer one's question.
note "a nested event does not decide the outer one"
# The inner event BUBBLES and the outer one does not. Sharing one flag between them made the
# outer key look bubbled too, so it went on to the ancestor as well — the nested dispatch
# answering a question it was never asked.
# Z is bound ONLY on the control and it bubbles, and NOTHING above binds it — so the nested
# dispatch ends with the flag still raised. That is the only shape in which sharing one flag
# shows: an inner event that finishes bubbling leaves its answer lying around for the outer one.
ft_keymap nest; ft_keymap_set nest \
    key=Z onKey='ev inner-z; ft_bubble' \
    key=N onKey='ev nest-n; ft_dispatch_event Z'
ft_set evb keymap="inner nest"
EV=""; ft_dispatch_event N
check "the nested dispatch ran and bubbled out"  "$EV" "nest-n inner-z "
check "…and N itself was still claimed"          "$?" "0"
EV=""; ft_dispatch_event N
check "…so the ancestor's N never ran" \
      "$(case "$EV" in *outer-n*) echo leaked ;; *) echo clean ;; esac)" "clean"

# ── Peers ───────────────────────────────────────────────────────────────────
# Controls that share a shortcut letter have no ancestral relationship, so there is no cascade
# to pick a winner between them: each is a subscriber and each responds. Five pages can all
# claim `s` for their own Save because only one is ever on screen; two VISIBLE claimants both
# act, and keeping their effects disjoint is the author's job.
note "every visible, enabled claimant of a shortcut responds"
PH=""
ph_one() { PH+="one "; }; ph_two() { PH+="two "; }; ph_three() { PH+="three "; }
ft-form name=phapp width=50 height=8
    ft-button name=ph1 text="Save file"  accessKey=s onActivate='ph_one "$@"'
    ft-button name=ph2 text="Save state" accessKey=s onActivate='ph_two "$@"'
    ft-button name=ph3 text="Sleep"      accessKey=s onActivate='ph_three "$@"'
end_ft_form
FT_ROOT=phapp; ft_layout phapp
PH=""; _ft_accel_dispatch phapp S
check "all three respond"                "$PH" "one two three "
ft_set ph2 display=none
PH=""; _ft_accel_dispatch phapp S
check "…a hidden one does not"           "$PH" "one three "
ft_set ph2 display=inline-block; ft_set ph3 disabled=true
PH=""; _ft_accel_dispatch phapp S
check "…nor a disabled one"              "$PH" "one two "

# ── A listener holds code too ───────────────────────────────────────────────
# It could not before: the store was a SPACE-SEPARATED list of "event=fn" tokens, so code with
# a space in it split into two entries and _ft_hook then looked up a command literally called
# "fn arg", failed its `declare -F` test and did nothing. Silently, for as long as the framework
# has existed. The separator is US (\x1f) now — the byte set aside for exactly this.
note "an on<Event>= handler takes code, like a key does"
LIS=""
lis() { LIS+="$* | "; }
ft-form name=lapp width=50 height=8
    ft-label  name=ltotal text="0"
    ft-slider name=lsl value=3 min=0 max=10 onChange='ft_set ltotal text="$1 items"; lis "saw $1"'
    ft-button name=lb text="Go" onActivate='lis one' onDeactivate='lis off'
end_ft_form
FT_ROOT=lapp; ft_layout lapp
LIS=""; ft_slider_set lsl 7
check "the code ran"                     "$LIS" "saw 7 | "
check "…and the event DETAIL reached it" "$(ft_get ltotal text; printf '%s' "$FT_RET")" "7 items"
LIS=""; ft_activate lb
check "a plain call still works"         "$LIS" "one | "
# Listeners ACCUMULATE — `onActivate=` twice is two listeners, as the DOM has it — so the
# plain one above is still there and still first.
ft_set lb onActivate=$'lis "a;b"\nlis "x=y"'
LIS=""; ft_activate lb
check "semicolons, quotes, = and a NEWLINE survive" "$LIS" 'one | a;b | x=y | '
ft_add_listener lb activate='lis added'
LIS=""; ft_activate lb
check "ft_add_listener adds another, in order"      "$LIS" 'one | a;b | x=y | added | '
ft_set lb onActivate=
LIS=""; ft_activate lb
check "onActivate= clears them all"                 "${LIS:-nothing}" "nothing"

# A listener that CANCELS still cancels: nonzero from any of them, and every one still runs.
note "a listener returning nonzero still cancels the action"
ft_set lsl onChange='lis "veto $1"; false'
ft_slider_set lsl 9
check "the value was put back"           "$(ft_get lsl value; printf '%s' "$FT_RET")" "7"

# ── Batching ────────────────────────────────────────────────────────────────
# The engine always coalesced writes inside an input burst — three ft_set calls in a HANDLER
# have always cost one reflow. Outside a handler, in setup code or a loop over rows, each write
# reflowed on its own, which is the case the author was worried about and was right to be.
# A batch SETTLES, which paints — so this section needs somewhere for the paint to go.
exec {FT_TTY}>/dev/null
note "a batch costs one reflow, however many writes it holds"
ft-form name=bapp width=60 height=10
    ft-label name=br1 text="one"; ft-label name=br2 text="two"; ft-label name=br3 text="three"
end_ft_form
FT_ROOT=bapp; ft_layout bapp
FT_REFLOW_COUNT=0
ft_set br1 text="a longer one"; ft_set br2 text="a longer two"; ft_set br3 text="a longer three"
check "three loose writes reflow three times" "$FT_REFLOW_COUNT" "3"
FT_REFLOW_COUNT=0
ft_batch_begin
ft_set br1 text="x1"; ft_set br2 text="x2"; ft_set br3 text="x3"
check "…inside a batch, nothing reflows yet"  "$FT_REFLOW_COUNT" "0"
ft_batch_end
check "…and the batch settles to exactly one" "$FT_REFLOW_COUNT" "1"
check "…with the writes really applied"       "$(ft_get br2 text; printf '%s' "$FT_RET")" "x2"
FT_REFLOW_COUNT=0
ft_batch_begin; for _i in 1 2 3 4 5 6 7 8 9 10; do ft_set br1 text="row $_i"; done; ft_batch_end
check "ten writes in a loop: still one"       "$FT_REFLOW_COUNT" "1"

# Nestable, and safe inside a handler: a batch that finds coalescing already on leaves the
# settling to whoever turned it on, or the screen would be painted mid-burst.
note "a batch inside a burst does not settle early"
FT_COALESCING=1; FT_REFLOW_COUNT=0
ft_batch_begin; ft_set br3 text="in a burst"; ft_batch_end
check "the burst is still open"               "$FT_COALESCING" "1"
check "…and nothing has reflowed"             "$FT_REFLOW_COUNT" "0"
ft_reflow_flush; FT_COALESCING=0
check "…until the burst itself settles"       "$FT_REFLOW_COUNT" "1"
no "ft_batch_end with no open batch is refused" ft_batch_end

# A batch left open at FILE SCOPE would freeze the screen — coalescing on, every write deferred,
# and nothing to settle it because nothing was going to until the missing ft_batch_end. Inside a
# handler the run loop rescues it; before the loop starts nothing does, so ft_run clears it and
# says so rather than starting an app that will not paint.
note "a batch left open is reported and cleared before the app runs"
ft_batch_begin; ft_set br1 text="orphaned"
check "coalescing is on while it is open"   "$FT_COALESCING" "1"
err _ft_batch_reset_stale
check "…the leak is named"                  "$ERR" "1 batch(es) left open — ft_batch_begin without ft_batch_end"
check "…and coalescing is released"         "$FT_COALESCING" "0"
ok "…and a clean slate says nothing"        _ft_batch_reset_stale

# A batch a HANDLER opens and never closes would sit at depth>0 for the rest of the session:
# every later ft_batch_begin nests inside the ghost, so its ft_batch_end never settles and
# batching quietly stops working — ten writes, ten reflows. The end of every input burst clears
# it, which is where the run loop already puts everything that must not outlive a burst.
note "a batch leaked inside a handler does not poison the next one"
FT_COALESCING=1; ft_batch_begin          # a handler opens one and returns early
FT_COALESCING=0; ft_reflow_flush         # …the run loop's settle, minus the reset
check "the ghost is still open"          "$_FT_BATCH_DEPTH" "1"
FT_REFLOW_COUNT=0
ft_batch_begin; for _i in 1 2 3 4 5; do ft_set br1 text="r$_i"; done; ft_batch_end
check "…and batching has stopped working" "$FT_REFLOW_COUNT" "5"
err _ft_batch_reset_stale
FT_REFLOW_COUNT=0
ft_batch_begin; for _i in 1 2 3 4 5; do ft_set br1 text="s$_i"; done; ft_batch_end
check "…until the reset, after which it works again" "$FT_REFLOW_COUNT" "1"
# …and the run loop really does that reset, at the end of every burst.
check "the burst settle clears a leaked batch" \
      "$(declare -f ft_run | grep -c '_ft_batch_reset_stale')" "2"

# An event's propagation is decided by handlers OF THAT EVENT. Without that, a button's
# onActivate calling ft_bubble made the KEY that activated it bubble to the form as well.
note "ft_bubble in a listener does not steer the key that caused it"
EV=""
ft_keymap acc; ft_keymap_set acc key=Z onKey='ft_activate $this'
ft_keymap accup; ft_keymap_set accup key=Z onKey='ev ancestor'
ft-form name=accapp width=40 height=8 keymap=accup
    ft-button name=accb text="Go" keymap=acc onActivate='ev listener; ft_bubble'
end_ft_form
FT_ROOT=accapp; ft_layout accapp; ft_focus accb
EV=""; ft_dispatch_event Z
check "the listener ran and the key stayed claimed" "$EV" "listener "

# ── Things that used to fail in silence ─────────────────────────────────────
note "a keymap= that names nothing is reported, not silently empty"
ft-form name=tyapp width=40 height=6
    ft-button name=tyb text="g" keymap=no_such_map key=K onKey='ev own'
end_ft_form
FT_ROOT=tyapp; ft_layout tyapp; ft_focus tyb
EV=""; ft_dispatch_event K
check "the control's own keys still work" "$EV" "own "
err _ft_report_missing_keymaps
check "…and the dangling reference is named" \
      "$(case "$ERR$(cat "$_ERR")" in *"tyb → no_such_map"*) echo named ;; *) echo "${ERR:-silent}" ;; esac)" "named"

note "a block left open is named when the next one opens"
err ft-keymap blkA
ft-key key=A onKey='ev a'
err ft-keymap blkB
check "the missing end_ft_keymap is named" "$ERR" "ft-keymap blkB: blkA is still open — missing end_ft_keymap"
ft-key key=B onKey='ev b'
end_ft_keymap
check "…and the rows still went to the right maps" \
      "$(ft_keymap_dump blkA | cut -f1)/$(ft_keymap_dump blkB | cut -f1)" "A/B"

# `on<Event>` is not a property — the listeners live on the eventListeners plist — so unsetting
# one removed nothing and said nothing, which is the obvious way to try to drop a handler.
note "ft_unset clears a listener, like ft_set onX= does"
UN=""
ft-form name=unapp width=40 height=6
    ft-button name=unb text="u" onActivate='UN=fired'
end_ft_form
FT_ROOT=unapp; ft_layout unapp
UN=""; ft_activate unb; check "the listener fires"          "$UN" "fired"
ft_unset unb onActivate
UN=""; ft_activate unb; check "…and ft_unset really drops it" "${UN:-cleared}" "cleared"

# THE PROPAGATION PATH IS DECIDED BEFORE ANY HANDLER RUNS, as the DOM decides an event's path
# at dispatch. Walking the tree as we went read a tree the handler had just changed: rebuilding
# a container from inside one of its own keys — an ordinary thing to do — left the walk standing
# on a node with no parent, and the ancestor never saw the event it was passed.
note "a handler may rebuild the tree under itself and still bubble"
EV=""
ft_keymap selfrm; ft_keymap_set selfrm key=X onKey='ev gone; ft_remove rmdiv; ft_bubble'
ft_keymap rmup;   ft_keymap_set rmup   key=X onKey='ev ancestor'
ft-form name=rmapp width=40 height=8 keymap=rmup
    ft-div name=rmdiv keymap=selfrm
        ft-button name=rmb text="i"
    end_ft_div
end_ft_form
FT_ROOT=rmapp; ft_layout rmapp; ft_focus rmdiv
EV=""; ft_dispatch_event X
check "the ancestor still received it" "$EV" "gone ancestor "
check "…and the control really is gone" "${FT_TYPE[rmdiv]:-gone}" "gone"

# `default` is the pattern for "what an unmatched key does", and it has to mean the same thing a
# real key does: an empty handler eats, ft_bubble passes on.
note "key=default speaks the same grammar as any other key"
ft_keymap dfa; ft_keymap_set dfa key=default onKey=''
_ft_keymap_default dfa; check "onKey='' on default means eat"        "$FT_RET" "drop"
ft_keymap dfb; ft_keymap_set dfb key=default onKey='ft_bubble'
_ft_keymap_default dfb; check "ft_bubble on default means pass on"   "$FT_RET" "bubble"
ft_keymap dfc
err ft_keymap_set dfc key=default onKey='do_something $this'
check "…and anything else is refused" \
      "$(case "$ERR" in *"key=default takes"*) echo refused ;; *) echo "${ERR:-silent}" ;; esac)" "refused"

# ── The wheel ───────────────────────────────────────────────────────────────
# A DECLINE HAS TO TRAVEL. The wheel path returned "handled" whatever the action said, so a
# control with nothing left to scroll — which is exactly what ft-label reports by calling
# ft_bubble — ATE the event. Wheeling past the end of an inner list left the list it sits in
# perfectly still, the one thing every other program in the terminal gets right.
note "the wheel keeps travelling when a control has nothing left to scroll"
OUT=0
ft-form name=wapp width=40 height=10 keymap=wouter
    ft-label name=wlab text=$'one\ntwo\nthree\nfour\nfive\nsix' height=3 overflowY=auto
end_ft_form
ft_keymap wouter; ft_keymap_set wouter key=DOWN onKey='OUT=$(( OUT + 1 ))'
ft_set wapp keymap=wouter
FT_ROOT=wapp; ft_layout wapp; ft_focus wlab
ft_set wlab scrollTop=0
OUT=0; _ft_wheel_dispatch wlab DOWN
check "with room to scroll, the inner keeps it"  "$OUT" "0"
ft_set wlab scrollTop=99                          # parked at the very bottom
OUT=0; _ft_wheel_dispatch wlab DOWN
check "at the end, the container scrolls instead" "$OUT" "1"

summary
