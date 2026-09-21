#!/usr/bin/env bash
# DOM-shaped API: classList / matches / closest / query(_all) / parent / children / blur / focus.
# Names mirror the DOM verbatim (adapted to bash call-style).
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_COLS=40; FT_ROWS=12

ft-form name=app width=40 height=12 display=flex flexDirection=column
  ft-div name=box class=spotlight
    ft-textfield name=fld class="a b" value="hi"
    ft-label name=lbl text="x"
  end_ft_div
  ft-button name=btn text="Go"
end_ft_form
ft_layout app; FT_ROOT=app

note "classList: add / remove / toggle / contains — one class, others untouched"
ft_get fld class; check "starts with 'a b'" "$FT_RET" "a b"
ft_classlist_add fld hot
ft_get fld class; check "add hot → 'a b hot'" "$FT_RET" "a b hot"
ft_classlist_add fld hot
ft_get fld class; check "add existing is a no-op" "$FT_RET" "a b hot"
ft_classlist_contains fld b; check "contains b" "$?" "0"
ft_classlist_contains fld zzz; check "does not contain zzz" "$?" "1"
ft_classlist_remove fld b
ft_get fld class; check "remove middle 'b' → 'a hot'" "$FT_RET" "a hot"
ft_classlist_toggle fld a; check "toggle off 'a' returns absent(1)" "$?" "1"
ft_get fld class; check "…leaving 'hot'" "$FT_RET" "hot"
ft_classlist_toggle fld new; check "toggle on 'new' returns present(0)" "$?" "0"
ft_get fld class; check "…→ 'hot new'" "$FT_RET" "hot new"

note "ft_set accepts a spaced multi-class value now that class is registered"
ft_set lbl class="c d e"
ft_get lbl class; check "multi-class via ft_set" "$FT_RET" "c d e"

note "matches: a compound selector against one element"
ft_matches fld ".hot";        check "fld matches .hot" "$?" "0"
ft_matches fld "textfield";   check "fld matches type" "$?" "0"
ft_matches fld ".nope";       check "fld !match .nope" "$?" "1"
ft_matches btn "button.go" 2>/dev/null; FT_PROPS[btn]=""; printf -v _ftp_btn_class go
ft_matches btn "button.go";   check "btn matches button.go" "$?" "0"

note "closest: nearest self-or-ancestor matching a selector"
ft_closest fld ".spotlight";  check "closest .spotlight is #box" "$FT_RET" "box"
ft_closest fld "textfield";   check "closest textfield is self" "$FT_RET" "fld"
ft_closest fld ".missing";    check "closest with no match → empty" "$FT_RET" ""

note "query / query_all: find by (compound) selector under a root"
ft_classlist_add lbl hot
ft_query_all ".hot"; check "query_all .hot finds both" "$FT_RET" "fld lbl"
ft_query ".hot";     check "query .hot → first" "$FT_RET" "fld"
ft_query_all "button"; check "query_all button" "$FT_RET" "btn"

note "parent / children accessors"
ft_parent fld;   check "parent of fld is box" "$FT_RET" "box"
ft_children box;  check "children of box" "$FT_RET" "fld lbl"

note "focus / blur"
# Focus is a POINTER (which control) and a RUNG (how far into it). Both halves have to move
# together: ft_blur used to clear the pointer only, so a blurred control kept its rung and went
# on matching :focus — which reads the rung, not FT_FOCUS — while nothing held focus at all.
# Asserted through the STATES, because that is what a stylesheet actually sees.
ft_focus fld; check "focus set FT_FOCUS" "$FT_FOCUS" "fld"
ft_get fld runlevel; check "…and stood it on the poised rung" "$FT_RET" "poised"
ft_stylesheet name=blurprobe style='#fld:focus { --blur-probe: 7; }'
ft_style fld --blur-probe; check "…and a :focus rule resolves for it" "${FT_RET:-none}" "7"
ft_blur fld;  check "blur cleared it" "$FT_FOCUS" ""
ft_get fld runlevel; check "…and took the rung down with it" "$FT_RET" "unfocused"
# Through the CASCADE rather than by calling the predicate: `ft_state_is_focused` reads
# FT_FOCUS, so asking it directly would only restate the line above it. This half always
# worked — FT_FOCUS is in the cascade cache key, so :focus re-resolves on its own — and it is
# pinned here precisely because it is the half that is easy to break while fixing the other.
# The RUNG is what did not come down; that is the assertion above, and the one below.
ft_style fld --blur-probe; check "…and the :focus rule stops applying" "${FT_RET:-none}" "none"
ft_blur fld;  check "blur on an unfocused control is a safe no-op" "$FT_FOCUS" ""

# The rung that matters most is one you have STEPPED INTO: blurring has to undo the delve, not
# only the focus, or coming back to the control finds the arrows still meaning what they meant
# inside it — with nothing on screen saying so.
ft_focus fld; ft_textfield_engage fld
check "stepped in → :engaged"        "$(ft_state_is_engaged fld && echo yes || echo no)" "yes"
ft_blur fld
ft_get fld runlevel; check "blur from inside drops all the way out" "$FT_RET" "unfocused"
check "…and it is not engaged either" "$(ft_state_is_engaged fld && echo yes || echo no)" "no"

note "classList add/remove take MULTIPLE classes in one call"
ft_set fld class=""
ft_classlist_add fld one two three
ft_get fld class; check "add three at once" "$FT_RET" "one two three"
ft_classlist_remove fld one three
ft_get fld class; check "remove two at once" "$FT_RET" "two"

note "id property: #id matches the id prop, which DEFAULTS to the name"
ft_stylesheet name=idt style='#alias { color: 7; } #lbl { color: 9; }'
ft_matches lbl "#lbl";   check "default: #lbl matches control named lbl" "$?" "0"
ft_set lbl id=alias
ft_matches lbl "#alias"; check "explicit id: #alias matches" "$?" "0"
ft_matches lbl "#lbl";   check "…#lbl no longer matches (id overrides name)" "$?" "1"
ft_style lbl color;      check "cascade resolves via the #alias rule" "$FT_RET" "7"
ft_set lbl id=""

note "ft_tokenlist: the generic token-list API works on ANY registered list property (not just class)"
ft_prop_kind_set accept paint          # a widget would register its own list prop
ft_set fld accept=""
ft_tokenlist_add fld accept .jpg .png .gif
ft_get fld accept; check "add three accept tokens" "$FT_RET" ".jpg .png .gif"
ft_tokenlist_contains fld accept .png; check "contains .png" "$?" "0"
ft_tokenlist_remove fld accept .png
ft_get fld accept; check "remove .png" "$FT_RET" ".jpg .gif"
ft_tokenlist_toggle fld accept .gif; check "toggle .gif off → absent(1)" "$?" "1"
ft_get fld accept; check "…now just .jpg" "$FT_RET" ".jpg"
ft_classlist_add fld z; ft_tokenlist_contains fld class z; check "classList is just plist over 'class'" "$?" "0"

note "ft_remove detaches the node from its parent's child list"
ft-label name=tmp parent=box text="temp"
ft_children box; case " $FT_RET " in *" tmp "*) check "tmp appended to box" 1 1 ;; *) check "tmp appended to box" 0 1 ;; esac
ft_remove tmp
ft_children box; case " $FT_RET " in *" tmp "*) check "tmp detached after ft_remove" 0 1 ;; *) check "tmp detached after ft_remove" 1 1 ;; esac

note "event listeners: onX= sugar accumulates; dispatch runs all; \$this/\$FT_EVENT_TYPE set"
LOG=""
h1() { LOG+="h1($this:$FT_EVENT_TYPE:$1) "; }
h2() { LOG+="h2($1) "; }
h3() { LOG+="h3 "; }
ft-button name=evb parent=box onActivate='h1 "$@"' onActivate='h2 "$@"' text="Ev"
# The store is US-separated (\x1f) so a listener may hold CODE — spaces, semicolons, newlines.
_LS=$'\x1f'
ft_get evb eventListeners
check "two onActivate= args both registered" "$FT_RET" "activate=h1 \"\$@\"${_LS}activate=h2 \"\$@\""
_ft_hook evb on_activate v1
check "both listeners ran, in order, with \$this + event type + arg" "$LOG" "h1(evb:activate:v1) h2(v1) "
LOG=""; ft_set evb onActivate='h1 "$@"'
ft_get evb eventListeners
check "re-adding the same listener is a no-op (DOM)" "$FT_RET" "activate=h1 \"\$@\"${_LS}activate=h2 \"\$@\""
ft_add_listener evb change=h3
ft_get evb eventListeners
check "ft_add_listener (pair form) appends" "$FT_RET" "activate=h1 \"\$@\"${_LS}activate=h2 \"\$@\"${_LS}change=h3"
# A listener is identified by its CODE, the way removeEventListener needs the same function
# reference — so removing one names exactly what was registered.
ft_remove_listener evb activate 'h2 "$@"'         # two-arg DOM shape
ft_get evb eventListeners
check "ft_remove_listener (two-arg form) removes" "$FT_RET" "activate=h1 \"\$@\"${_LS}change=h3"
ft_has_listener evb change;  check "has_listener change" "$?" "0"
ft_has_listener evb next;    check "no next listener"    "$?" "1"
ft_set evb onActivate=""
ft_get evb eventListeners; check "onActivate=\"\" clears just that event" "$FT_RET" "change=h3"

note "a listener returning nonzero CANCELS (preventDefault) — but all listeners still run"
LOG=""
veto() { LOG+="veto "; return 1; }
ft_add_listener evb activate=veto; ft_add_listener evb activate=h3
if _ft_hook evb on_activate; then check "veto → _ft_hook returns nonzero" 0 1; else check "veto → _ft_hook returns nonzero" 1 1; fi
check "the later listener still ran after the veto" "$LOG" "veto h3 "

note "NO name-convention magic: an UNWIRED <name>_on_<event> function never fires"
LOG=""
cvb_on_activate() { LOG+="conv "; }
ft-button name=cvb parent=box text="C" # note: NOT wired
_ft_hook cvb on_activate
check "unwired convention-named fn does NOT fire" "$LOG" ""
ft_add_listener cvb activate cvb_on_activate     # wire it explicitly…
_ft_hook cvb on_activate
check "…wired, it fires (once)" "$LOG" "conv "
ft_add_listener cvb activate cvb_on_activate     # identical re-add dedups
LOG=""; _ft_hook cvb on_activate
check "identical re-add still fires once" "$LOG" "conv "

note "HTML inline style attribute: style=\"decls\" parses into element properties"
ft-label name=sty parent=box style="color: 201; font-weight: bold" text="S"
ft_style sty color;      check "style= sets color (201)"        "$FT_RET" "201"
ft_style sty fontWeight; check "style= sets font-weight (camel)" "$FT_RET" "bold"
ft_get sty style;        check "raw string round-trips"          "$FT_RET" "color: 201; font-weight: bold"
ft_set sty style="--tint: 46"
ft_style sty --tint;     check "custom property via style= (--tint)" "$FT_RET" "46"

note "ft_unset: truly unsets — falls back to the stylesheet/class default"
ft_stylesheet name=rat style='#raEl { color: 33; }'
ft-label name=raEl parent=box color=99 text="R"
ft_style raEl color; check "inline color wins first" "$FT_RET" "99"
ft_unset raEl color
ft_style raEl color; check "removed → the #raEl rule shows through" "$FT_RET" "33"
ft_get raEl color;   check "raw prop is gone (not just empty)" "$FT_RET" ""

note "ft_clone: shallow copies props detached; deep clones the subtree; clones are independent"
ft-div name=corig class=spotty --tone=7
  ft-label name=ckid color=45 text="kid"
end_ft_div
ft_clone corig ccopy
check "clone type = original's type" "${FT_TYPE[ccopy]}" "${FT_TYPE[corig]}"
ft_get ccopy class; check "clone got the class" "$FT_RET" "spotty"
ft_get ccopy --tone; check "clone got the custom prop" "$FT_RET" "7"
check "shallow: no children"  "${FT_KIDS[ccopy]}" ""
check "clone is detached"     "${FT_PARENT[ccopy]}" ""
ft_set ccopy class=other
ft_get corig class; check "mutating the clone leaves the original alone" "$FT_RET" "spotty"
ft_clone corig cdeep deep
ft_children cdeep; kidname=$FT_RET
check "deep: one generated child" "$(set -- $kidname; echo $#)" "1"
ft_get "$kidname" color; check "deep child carries its props" "$FT_RET" "45"
check "deep child parent is the clone" "${FT_PARENT[$kidname]}" "cdeep"

note "imperative tree mutation: append / before / after / replace_with"
ft-form name=tapp width=30 height=10 display=flex flexDirection=column
  ft-div name=tbox display=flex flexDirection=column
    ft-label name=n1 text="1"
    ft-label name=n2 text="2"
    ft-label name=n3 text="3"
  end_ft_div
end_ft_form
FT_ROOT=tapp
ft_children tbox; check "initial order"                 "$FT_RET" "n1 n2 n3"
ft-label name=nx parent=tbox text="x" # create appends at end
ft_children tbox; check "create parent= appends at end" "$FT_RET" "n1 n2 n3 nx"
ft_before n1 nx;  ft_children tbox; check "ft_before moves nx to front"  "$FT_RET" "nx n1 n2 n3"
ft_after  n2 nx;  ft_children tbox; check "ft_after repositions nx"      "$FT_RET" "n1 n2 nx n3"
ft_append tbox nx; ft_children tbox; check "ft_append moves nx to end"   "$FT_RET" "n1 n2 n3 nx"
ft-label name=nr parent=tbox text="r" # tbox: n1 n2 n3 nx nr
ft_replace_with n2 nr; ft_children tbox; check "ft_replace_with swaps in nr for n2" "$FT_RET" "n1 nr n3 nx"
check "…and the replaced node is freed" "${FT_TYPE[n2]:-gone}" "gone"

summary
