#!/usr/bin/env bash
# Unit tests for the prototype system: constructor-chain inheritance (a derived
# prototype's prototype-constructor calls its base prototype's, then overrides
# struct entries), memoized one-time prototype registration, per-prototype
# property defaults, and the nesting DSL (auto-parent from the open-container
# stack, end_ft_* type checking, <type>_on_children_complete hooks).
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init

note "constructor-chain inheritance: button IS-A label"
ft-button name=b1 text="Grow"
check "button inherited label's height fn"          "${FT_PROTO_HEIGHT[button]}" "_ft_height_label"
check "button OVERRODE the width fn (adds its own padding)" "${FT_PROTO_PREFERRED_WIDTH[button]}" "_ft_preferred_width_button"
check "button OVERRODE the draw fn"                 "${FT_PROTO_DRAW[button]}"  "_ft_draw_button"
check "label keeps its own draw fn"                 "${FT_PROTO_DRAW[label]:-unset}" "unset"
ft_prototype_init label
check "label's own struct untouched by button's"    "${FT_PROTO_DRAW[label]}"   "_ft_draw_label"

note "class registration is memoized (runs once, first instance)"
_CLASS_CTOR_RUNS=0
ft_prototype_gadget() {
    ft_prototype extends=ft_control
    (( _CLASS_CTOR_RUNS++ ))
}
ft-gadget() { ft_new gadget "$@"; }
ft-gadget name=g1
ft-gadget name=g2
ft-gadget name=g3
check "three instances, ONE class construction" "$_CLASS_CTOR_RUNS" "1"

note "a subclass overrides superclass DEFAULTS by appending later tokens"
ft_prototype_biggadget() {
    ft_prototype extends=gadget defaults="padding=2"   # superclass first, then extend
}
ft-biggadget() { ft_new biggadget "$@"; }
ft-biggadget name=bg1
ft_get bg1 display; check "inherited default present" "$FT_RET" "block"
ft_get bg1 padding; check "subclass default applied"  "$FT_RET" "2"
ft-biggadget name=bg2 padding=5
ft_get bg2 padding; check "user args still beat class defaults" "$FT_RET" "5"

note "per-class defaults: frame borders, leaves inline-block"
ft-frame name=fr1
end_ft_frame
ft_get fr1 border; check "frame defaults border=true"    "$FT_RET" "true"
ft-label name=lb1 text=x
ft_get lb1 display; check "label defaults inline-block"   "$FT_RET" "inline-block"
ft-div name=pn1
end_ft_div
ft_get pn1 display; check "panel defaults block"          "$FT_RET" "block"

note "nesting DSL: the open container is the implicit parent"
ft-form name=nf width=40 height=10
    ft-div name=np
        ft-label name=nl text=deep
    end_ft_div
    ft-label name=nl2 text=shallow
end_ft_form
check "nested label's parent"    "${FT_PARENT[nl]}"  "np"
check "after end_, parent pops"  "${FT_PARENT[nl2]}" "nf"
check "explicit parent= wins over the stack" "$(
    ft-form name=nf2 width=10 height=4
        ft-label name=nlx text=x parent=nf
    end_ft_form
    printf '%s' "${FT_PARENT[nlx]}"
)" "nf"

note "end_ft_* catches mis-nesting immediately"
err=$( { ft-div name=mm; end_ft_frame; } 2>&1 )
check "mismatch names both types" "$(
    case "$err" in *end_ft_frame*div*) echo yes ;; *) echo "$err" ;; esac
)" "yes"
end_ft_div 2>/dev/null   # clean the stack (the pop still happened above)
err=$(end_ft_div 2>&1)
check "underflow reported" "$(
    case "$err" in *'no open container'*) echo yes ;; *) echo "$err" ;; esac
)" "yes"

note "ft_empty + ft_refresh: THE rebuild idiom"
ft-form name=rb width=40 height=10
    ft-button name=rbBtn text=" A "
end_ft_form
FT_ROOT=rb
exec {FT_TTY}>/dev/null
check "button focused after first build" "$FT_FOCUS" "rbBtn"
ft_empty rb
check "children destroyed" "${FT_TYPE[rbBtn]+set}" ""
check "the container itself survives" "${FT_TYPE[rb]}" "form"
ft-button name=rbBtn parent=rb text=" A again "
ft-button name=rbNew parent=rb text=" New "
ft_refresh rb
check "refresh rebuilt the focus ring" "${FT_FOCUS_RING[*]}" "rbBtn rbNew"
check "focus survived the rebuild by name" "$FT_FOCUS" "rbBtn"
check "layout ran (button measured)" "$(( ${FT_MEASURED_WIDTH[rbNew]:-0} > 0 ))" "1"

note "<type>_on_children_complete fires at end_ (NOT a destructor)"
_GADGET_DONE=""
gadget_on_children_complete() { _GADGET_DONE=$1; }
ft-gadget name=gHook
FT_NEST_STACK+=("gHook")
ft-label name=gKid text=x
ft_end gadget
check "hook received the finished parent" "$_GADGET_DONE" "gHook"
check "children were already known inside it" "${FT_KIDS[gHook]}" "gKid"
check "nothing was destroyed" "${FT_TYPE[gHook]},${FT_TYPE[gKid]}" "gadget,label"

note "draw/preferredWidth/height bind themselves from _ft_<role>_<type>, and INHERIT"
# The convention runs for each prototype in the chain as its constructor fires, not just for the
# leaf — otherwise a derived prototype with no function of its own inherits nothing. That exact
# slip gave every button height 0, which made it invisible to the hit test: no click could land.
_ft_draw_widget()            { :; }
_ft_height_widget()          { FT_RET=1; }
_ft_preferred_width_widget() { FT_RET=1; }
ft_prototype_widget() { ft_prototype extends=ft_control focusable=true; }
ft-widget() { ft_new widget "$@"; }
_ft_draw_gizmo() { :; }                      # overrides draw ONLY
ft_prototype_gizmo() { ft_prototype extends=widget; }
ft-gizmo() { ft_new gizmo "$@"; }
ft-widget name=cw1; ft-gizmo name=cg1
check "the class binds its own draw"      "${FT_PROTO_DRAW[widget]}"             _ft_draw_widget
check "…and height"                       "${FT_PROTO_HEIGHT[widget]}"           _ft_height_widget
check "…and preferredWidth"               "${FT_PROTO_PREFERRED_WIDTH[widget]}"  _ft_preferred_width_widget
check "a subclass overrides what it has"  "${FT_PROTO_DRAW[gizmo]}"              _ft_draw_gizmo
check "…and INHERITS what it does not"    "${FT_PROTO_HEIGHT[gizmo]}"            _ft_height_widget
check "…for every conventional key"       "${FT_PROTO_PREFERRED_WIDTH[gizmo]}"   _ft_preferred_width_widget
check "the real chain: button gets a height fn" "${FT_PROTO_HEIGHT[button]}"     _ft_height_label

note "a short function value expands by convention; 'none' clears an inherited one"
check "keymap=activate  → ft_keymap_activate"  "${FT_PROTO_KEYMAP[button]}" ft_keymap_activate
check "mouse=activate   → _ft_mouse_activate"  "${FT_PROTO_MOUSE[button]}"  _ft_mouse_activate
check "focusSkip=none clears label's skip fn"  "${FT_PROTO_FOCUS_SKIP[button]}" ""
check "…which label itself still has"          "${FT_PROTO_FOCUS_SKIP[label]}"  _ft_label_focus_skip

note "ft_prototype REFUSES what the raw array pokes accepted silently"
# The whole reason the authoring API exists: FT_PROTO_FOCUSSABLE[$c]=1 was a valid bash
# assignment that created a new array nobody reads. Each of these must fail LOUDLY.
ft_prototype_typo() { ft_prototype extends=ft_control focussable=true; }
ft-typo() { ft_new typo "$@"; }
err=$(ft-typo name=t1 2>&1); rc=$?
check "an unknown key is rejected"   "$(case "$err" in *'unknown key'*focussable*) echo yes ;; *) echo "$err" ;; esac)" yes
check "…and the failure is not silent" "$(( rc != 0 ))" 1

ft_prototype_notbool() { ft_prototype extends=ft_control focusable=yes; }
ft-notbool() { ft_new notbool "$@"; }
err=$(ft-notbool name=t2 2>&1)
check "a boolean must be true/false" "$(case "$err" in *'must be true or false'*) echo yes ;; *) echo "$err" ;; esac)" yes

ft_prototype_nosuper() { ft_prototype extends=nosuchclass; }
ft-nosuper() { ft_new nosuper "$@"; }
err=$(ft-nosuper name=t3 2>&1)
check "an unknown superclass is rejected" "$(case "$err" in *'unknown prototype'*nosuchclass*) echo yes ;; *) echo "$err" ;; esac)" yes

# extends= runs the BASE PROTOTYPE's constructor, so arriving late it would overwrite keys already
# set — silently turning a focusable derived prototype back into its base's unfocusable self.
ft_prototype_lateextend() { ft_prototype draw=_ft_draw_label; ft_prototype extends=ft_control; }
ft-lateextend() { ft_new lateextend "$@"; }
err=$(ft-lateextend name=t4 2>&1)
check "a LATE extends= is rejected" "$(case "$err" in *'must come before'*) echo yes ;; *) echo "$err" ;; esac)" yes

note "booleans are stored 1/0 — never '' — so a reader can test them arithmetically"
# `[[ -n ]]` on a boolean was true for "0", which is how a heading came to claim mouse
# clicks. Every prototype must therefore CARRY the flag, not merely omit it when false.
ft-heading name=hbool text="x"
ft-button name=bbool text="y"
check "focusable=false stored as 0"      "${FT_PROTO_FOCUSABLE[heading]}" 0
check "focusable=true stored as 1"       "${FT_PROTO_FOCUSABLE[button]}"  1
check "an undeclared boolean is 0 too"   "${FT_PROTO_NOHIT[heading]}"     0
check "…and fillsBackground likewise"    "${FT_PROTO_FILLS_BACKGROUND[heading]}" 0
check "a class that declares it gets 1"  "${FT_PROTO_FILLS_BACKGROUND[form]}"    1

note "_ft_mouse_target only offers a control that can actually TAKE the click"
ft-form name=mf width=40 height=8
    ft-button name=mfBtn text="OK"
    ft-heading name=mfHd text="Section"
end_ft_form
_ft_mouse_target mfBtn; check "a button takes its own click" "$FT_RET" mfBtn
if _ft_mouse_target mfHd; then r=$FT_RET; else r="(none)"; fi
check "an inert heading does NOT claim it" "$r" "(none)"

note "the once-guard belongs to the ENGINE now, not to eight invented globals"
# A prototype KEYMAP is global, but a prototype CONSTRUCTOR is not: building a DERIVED
# prototype re-runs its base's constructor, so label's map is declared again for button,
# checkbox and every other heir. Each control used to guard that by hand — eight globals
# called _FT_KM_<TYPE>_READY — and then with ft_keymap_once. The engine does it, which is why
# `ft_keymap` can afford to refuse a duplicate outright.
_KM_BUILDS=0
_build() { _ft_keymap_declare_once ft_keymap_probe_once && (( _KM_BUILDS++ )); }
_build; _build; _build
check "declared exactly once across three asks" "$_KM_BUILDS" 1
check "…and the keymap really exists"        "$(declare -p _fti_ft_keymap_probe_once__list >/dev/null 2>&1 && echo yes)" yes
# The thing the guard exists to prevent: a second ask must not EMPTY what the first bound.
ft_keymap_set ft_keymap_probe_once key=X onKey='probe_x $this'
_build
check "a repeat ask leaves the bindings alone" "$(ft_keymap_dump ft_keymap_probe_once | cut -f1)" "X"

note "a cycle in the class graph must REPORT, not take the process down"
# ft_prototype_init calls "ft_prototype_<type>", and `extends=` calls the BASE PROTOTYPE's
# constructor directly — so a prototype that extends itself, or a ring of them, recursed until
# bash's stack blew and the process died of a SEGFAULT: no message, no trap, nothing for the app to
# report. FT_PROTO_READY cannot catch it, being set only on the way out. Each case must now return.
_cyc() {                        # label body → the run's outcome, or "CRASHED"
    local out rc
    out=$(timeout 6 bash -c "
        cd '$here'
        source ./fruity-tui.bash; ft_init; exec {FT_TTY}>/dev/null
        $1
        printf 'RETURNED'
    " 2>&1); rc=$?
    if   (( rc == 124 )); then printf 'HUNG'
    elif (( rc == 139 )); then printf 'CRASHED'
    elif [[ "$out" == *RETURNED* ]]; then printf 'returned'
    else printf 'died rc=%s' "$rc"; fi
}
check "a class that extends ITSELF"      "$(_cyc 'ft_prototype_selfy() { ft_prototype extends=selfy; }; ft_prototype_init selfy')" "returned"
check "a ring: aa extends bb extends aa" "$(_cyc 'ft_prototype_aa() { ft_prototype extends=bb; }; ft_prototype_bb() { ft_prototype extends=aa; }; ft_prototype_init aa')" "returned"
# A type whose NAME collides with a framework function: "ft_prototype_init" IS the initialiser, so
# `ft_prototype_init init` used to call itself. (Found by a probe that enumerated prototype names by
# grepping ^ft_prototype_* and matched the initialiser.)
check "a type named after the initialiser" "$(_cyc 'ft_prototype_init init')" "returned"
check "an EMPTY type name"                 "$(_cyc 'ft_prototype_init ""')"  "returned"
# …and a control of a cyclic prototype is simply never built, rather than half-built.
check "a control of a cyclic class is not created" \
      "$(_cyc 'ft_prototype_selfy() { ft_prototype extends=selfy; }
               ft_new selfy name=x >/dev/null 2>&1
               [[ -z "${FT_TYPE[x]:-}" ]] || exit 3')" "returned"
# The ordinary chain still works: button extends label extends ft_control.
check "button still inherits a height"  "$(_cyc 'ft_prototype_init button; [[ -n "${FT_PROTO_HEIGHT[button]:-}" ]] || exit 3')" "returned"
check "…and its own draw"               "$(_cyc 'ft_prototype_init button; [[ "${FT_PROTO_DRAW[button]:-}" == _ft_draw_button ]] || exit 3')" "returned"


# ═══ A PROTOTYPE DEFAULT IS CASCADE LEVEL 5 ══════════════════════════════════
# docs/styling-model.md §2 has always listed it last — "the control's LAST RESORT" — and the
# implementation made it FIRST, by stamping every default onto the instance as a property at
# construction. "The control's last resort" and "the author typed it at the call site" were then
# the same string and no reader could tell them apart, so no stylesheet rule could ever outrank
# one. Measured on an ordinary frame before the fix: padding 0 against a rule asking 2, gap 0
# against 3, overflow hidden against auto, flex-direction row against column. All 79 properties
# that 26 prototypes default were unreachable from a stylesheet, on every control.
note "a stylesheet rule outranks a class default (styling-model §2)"
ft-form name=capp width=90 height=30
    ft-frame name=cfr title="F"
        ft-button name=cbtn text="Go"
    end_ft_frame
end_ft_form
FT_ROOT=capp; ft_layout capp >/dev/null 2>&1
ft_stylesheet name=cascadegate style='#cfr { padding: 2; gap: 3; overflow: auto;
                                            flex-direction: column; justify-content: center;
                                            border-style: double; border-width: thick }
                                     #cbtn { importance: minor }'
for _pair in "padding 2" "gap 3" "overflow auto" "flexDirection column" \
             "justifyContent center" "borderStyle double" "borderWidth thick"; do
    set -- $_pair
    ft_style cfr "$1"; check "#cfr { $1 } wins over the class default" "$FT_RET" "$2"
done

note "…and an INLINE property still outranks the stylesheet"
ft_set cfr padding=5
ft_style cfr padding; check "inline beats the sheet"      "$FT_RET" "5"
ft_unset cfr padding
ft_style cfr padding; check "…and removing it hands back" "$FT_RET" "2"

note "…while the class default is what you get when nothing else speaks"
ft_stylesheet name=cascadegate style=''
ft_style cfr padding;       check "unstyled frame padding"    "$FT_RET" "0"
ft_style cfr flexDirection; check "unstyled flex-direction"   "$FT_RET" "row"
ft_get  cbtn display;       check "a button IS an inline-block" "$FT_RET" "inline-block"
ft_get  cfr border;         check "a frame IS bordered"        "$FT_RET" "true"
_ft_disp cbtn;              check "…and the raw fast path agrees" "$FT_RET" "inline-block"
_ft_border cfr;             check "…so does the border one"      "$FT_RET" "1"

note "importance is a class default again, and a rule still outranks it"
# Asked of a REAL prototype: ft_control is only ever initialised as somebody's ancestor, and the
# chain is appended into the DERIVED PROTOTYPE's entry. A frame declares no importance of its own,
# so finding one there is finding the base control's.
check "the base control declares importance" \
      "$(case " ${FT_PROTO_DEFAULTS[frame]} " in *" importance=normal "*) echo yes ;; *) echo no ;; esac)" "yes"
ft_style cbtn importance; check "button's own crucial wins over normal" "$FT_RET" "crucial"
ft_stylesheet name=cascadegate style='#cbtn { importance: minor }'
ft_style cbtn importance; check "…and a stylesheet wins over both"      "$FT_RET" "minor"
ft_stylesheet name=cascadegate style=''

note "a class default suppresses INHERITANCE, which is CSS's own rule"
# An inherited value fills in only where the cascade produced nothing FOR THIS ELEMENT, and a
# prototype default is a declaration for this element. Two of the 79 defaults inherit: a tree's
# `cursor` (a ROW INDEX that collides with CSS's inherited `cursor`) and a button's centred
# `textAlign`. Without this rule a tree takes a select's cursor index and a button stops
# centring inside a right-aligned container.
ft_set cfr textAlign=right
ft_resolved_prop cbtn textAlign "?"; check "a button keeps centring inside an aligned container" "$FT_RET" "center"
ft_unset cfr textAlign

note "…and the invariant that makes 'empty means undeclared' safe"
# The resolver treats an empty prototype default as "declares nothing" — one assoc read instead of a
# presence test and a second read, worth 40ms on a 37-control layout. That is only sound while
# no prototype default is BOTH inherited AND empty. This is the assertion that catches the day one
# is.
_t_bad=""
for _fn in $(declare -F | sed -n 's/^declare -f ft_prototype_//p'); do ft_prototype_init "$_fn" >/dev/null 2>&1; done
for _k in "${!FT_PROTO_DEFAULT[@]}"; do
    [[ -n "${FT_PROTO_DEFAULT[$_k]}" ]] && continue
    [[ -n "${FT_INHERITED_PROP[${_k#* }]:-}" ]] && _t_bad+=" $_k"
done
check "no class default is both INHERITED and EMPTY" "$_t_bad" ""
check "…and the table is not empty (the check has teeth)" \
      "$(( ${#FT_PROTO_DEFAULT[@]} > 100 ))" "1"

note "a class question asked with NO control writes nothing to stderr"
# ${FT_TYPE[""]} is a bash error, and in a TUI stderr is the alt screen. Probes reach the
# prototype helpers without an instance (a height function called for its prototype-level
# answer), so each one guards the empty name. run-all fails a file that writes to stderr; this
# fails the assertion.
_t_err=$( { _ft_prototype_default "" display; _ft_prototype_declares "" display
            _ft_prop_or_prototype "" display ""; _ft_disp ""; _ft_border ""; } 2>&1 >/dev/null )
check "no bash error from an empty control name" "$_t_err" ""

note "the box tuples say exactly what the class table says"
# _ft_inset4 and _ft_margin4 take ONE tuple read instead of five keyed ones, because five reads
# per control per layout pass cost 3.3ms of a 43ms drag frame. That is only sound while the tuple
# is the table: a tuple that came out empty would fall back to `0 0 0 0 0 0 - - -`, look faster
# still, and quietly drop `tabs`' three-row strip and every frame's border. So compare every
# field of every registered prototype against the table it was built from.
#
# The ninth field is not a property DEFAULT but a prototype SLOT — topEdgeProp, the name of
# the property this prototype draws on its top edge — so it is checked against its own table.
_t_inset_props=(border padding paddingTop paddingRight paddingBottom paddingLeft overflow overflowX)
_t_margin_props=(margin marginTop marginRight marginBottom marginLeft)
_t_bad=""; _t_fields=0; _t_nonfallback=0
for _fn in $(declare -F | sed -n 's/^declare -f ft_prototype_//p'); do ft_prototype_init "$_fn" >/dev/null 2>&1; done
for _ty in "${!FT_PROTO_READY[@]}"; do
    set -- ${FT_PROTO_INSET_BOX[$_ty]-}
    (( $# == 9 )) || { _t_bad+=" $_ty:inset-has-$#-fields"; continue; }
    _i=0
    for _p in "${_t_inset_props[@]}"; do
        _i=$(( _i + 1 )); _want=${FT_PROTO_DEFAULT["$_ty $_p"]-}
        if [[ -z "$_want" ]]; then
            case $_p in overflow|overflowX) _want="-" ;; *) _want=0 ;; esac
        else (( _t_nonfallback++ )); fi
        _t_fields=$(( _t_fields + 1 ))
        [[ "${!_i}" == "$_want" ]] || _t_bad+=" $_ty.$_p(${!_i}≠$_want)"
    done
    _want=${FT_PROTO_TOP_EDGE_PROP[$_ty]:--}
    [[ -n "${FT_PROTO_TOP_EDGE_PROP[$_ty]:-}" ]] && (( _t_nonfallback++ ))
    _t_fields=$(( _t_fields + 1 ))
    [[ "$9" == "$_want" ]] || _t_bad+=" $_ty.topEdgeProp($9≠$_want)"
    set -- ${FT_PROTO_MARGIN_BOX[$_ty]-}
    (( $# == 5 )) || { _t_bad+=" $_ty:margin-has-$#-fields"; continue; }
    _i=0
    for _p in "${_t_margin_props[@]}"; do
        _i=$(( _i + 1 )); _want=${FT_PROTO_DEFAULT["$_ty $_p"]-}; [[ -z "$_want" ]] && _want=0
        _t_fields=$(( _t_fields + 1 ))
        [[ "${!_i}" == "$_want" ]] || _t_bad+=" $_ty.$_p(${!_i}≠$_want)"
    done
done
check "every tuple field equals the class table's answer"      "$_t_bad" ""
check "…across enough fields to mean something"                "$(( _t_fields > 100 ))" "1"
# TEETH: a table of nothing but fallbacks would pass the comparison above and still be wrong. At
# least some fields must carry a value the prototype actually declared.
check "…and the tuples carry real declared values, not just fallbacks" "$(( _t_nonfallback > 10 ))" "1"
check "tabs keeps the three rows it reserves for its strip" \
      "$(set -- ${FT_PROTO_INSET_BOX[tabs]-}; echo "$3")" "3"
check "a frame still defaults to having a border" \
      "$(set -- ${FT_PROTO_INSET_BOX[frame]-}; echo "$1")" "true"

note "…and a stylesheet still outranks them"
# The readers skip asking the sheet while no sheet declares a box property. That shortcut is only
# safe because registering one flips the flag — if it ever stops flipping, level 2 silently loses
# to level 5 for thirteen properties and this is the assertion that says so.
if declare -f ft_stylesheet >/dev/null; then
    # Cleared first: an earlier sheet in this file already declares a box property, so asking
    # "was it off before?" would only prove that this file ran in order.
    _FT_CSS_FASTPATH_DECLARED=""
    ft_stylesheet name=_t_nonboxsheet style='#nothing_matches_this { color: red; }'
    check "a sheet with no box property leaves the gate shut (the check has teeth)" \
          "${_FT_CSS_FASTPATH_DECLARED:-}" ""
    ft_stylesheet name=_t_boxsheet style='#nothing_matches_this { padding: 4; }'
    check "…and declaring one opens it" "${_FT_CSS_FASTPATH_DECLARED:-unset}" "1"
fi


# ── A prototype may bring a HANDLER, not only a value ───────────────────────
# `on<Event>=` is not an ordinary property: _ft_setprop intercepts it and appends to the
# control's eventListeners plist. A prototype default never passes through that path — it is
# consulted during RESOLUTION — so `defaults="onActivate=fn"` resolved to nothing at all and the
# control looked wired while being inert. Found by writing ft-button-quit and watching Q do
# nothing.
note "a prototype default on<Event>= really registers a listener"
PSEQ=""
p_handler() { PSEQ+="proto "; }
a_handler() { PSEQ+="app "; }
ft_prototype_wired() { ft_prototype extends=button defaults="onActivate=p_handler"; }
ft-wired() { ft_new wired "$@"; }
ft-form name=plapp width=40 height=8
    ft-wired name=pl1
    ft-wired name=pl2 onActivate=a_handler
end_ft_form
FT_ROOT=plapp; ft_layout plapp
PSEQ=""; ft_activate pl1
check "the prototype's handler runs"            "$PSEQ" "proto "
# Listeners ACCUMULATE, exactly as two onActivate= arguments in one call do — the instance adds
# to the prototype, it does not replace it. Prototype first, because that is the order every
# other level of resolution uses.
PSEQ=""; ft_activate pl2
check "the app's handler adds to it, in that order" "$PSEQ" "proto app "
ft_set pl2 onActivate=
PSEQ=""; ft_activate pl2
check "onActivate= clears both, like el.onactivate = null" "${PSEQ:-nothing}" "nothing"
# It must not become a phantom PROPERTY while it is at it.
ft_get pl1 onActivate
check "it is a listener, not a property"        "${FT_RET:-unset}" "unset"
check "…and it is on the listener plist"        "$(ft_has_listener pl1 activate && echo yes)" "yes"

summary
