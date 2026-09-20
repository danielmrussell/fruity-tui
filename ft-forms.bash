#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — ft-forms.bash   (retained mode)
#
#  The object/property model, the prototype system, the CSS layout engine, the
#  reflow/repaint pipeline, the nesting DSL, focus, and event dispatch.
#
#  ── Design: a faithful subset of CSS ────────────────────────────────────────
#  Property names and semantics are CSS's, verbatim:
#
#    display   none | block | inline-block | flex
#    sizing    width/height unset = auto (content-sized), set = fixed;
#              minWidth/maxWidth/minHeight/maxHeight clamp either
#    flex      flexDirection row|column, gap, justifyContent
#              (start|center|end|space-between), alignItems / alignSelf
#              (start|center|end|stretch), flexGrow, flexShrink, flexBasis
#    position  static (default) | absolute with left/top
#    box       border (0/1 cell), padding, margin, boxSizing=borderBox
#    paint     color, backgroundColor, borderColor, overflow/X/Y, scrollTop
#
#  Deliberate deviations: character-cell units; no margin collapsing; overflow
#  defaults hidden (spilling text reads as broken in a terminal). Reserved,
#  accepted-but-unimplemented names: display=grid|inline, flexWrap,
#  row-reverse|column-reverse, position=relative|fixed, right/bottom.
#
#  ── Reflow vs repaint (the CSS performance model) ───────────────────────────
#  Every property is engine-classified as layout or paint (FT_PROP_KIND — one
#  table, like a browser; never per-prototype annotations). ft_set consults
#  it: paint-only changes repaint that one control and touch NOTHING else — so
#  scrolling (scrollTop) costs one repaint, by definition. Layout changes
#  reflow: recompute the control's own size; unchanged → repaint just it;
#  changed → re-lay the nearest fixed-size ancestor's subtree and repaint only
#  within it. Nothing outside that boundary is ever measured or painted.
#
#  ── Object & property model ──────────────────────────────────────────────────
#  A control is a NAME (stable across rebuilds, like a CSS id — rebuild by
#  ft_remove-ing the old subtree and registering the same names again).
#  Properties are <name>_<property> shell variables, camelCase CSS names.
#  Framework bookkeeping (assoc arrays keyed by name):
#     FT_TYPE FT_PARENT FT_KIDS FT_DRAW FT_FOCUSABLE FT_KEYMAP FT_PROPS
#  Computed geometry: FT_ABSOLUTE_X FT_ABSOLUTE_Y FT_MEASURED_WIDTH FT_MEASURED_HEIGHT (used outer sizes) and
#  FT_PREFERRED_WIDTH (preferred/max-content outer width, cached between passes).
#
#  ── Prototype system (constructor-chain inheritance) ─────────────────────────
#  A prototype is registered by a prototype-constructor `ft_prototype_<type>`
#  that DECLARES itself with `ft_prototype`, naming its base prototype — real
#  constructor-chain inheritance, resolved once at prototype-registration time
#  (memoized; first instance triggers it), never by runtime lookup chains:
#
#      ft_prototype_button() {
#          ft_prototype extends=label \
#                   draw=_ft_draw_button preferredWidth=_ft_preferred_width_button \
#                   focusable=true mouse=_ft_mouse_activate keymap=ft_keymap_activate
#      }
#
#  The root pure-virtual prototype is ft_control (ft_prototype_ft_control):
#  sane defaults for everything. See ft_prototype for the full key list and the
#  rules. Layout algorithms are NOT prototype code — they belong to display
#  modes in the engine; a prototype contributes only its intrinsic content size
#  and drawing.
#
#  ── Nesting DSL ──────────────────────────────────────────────────────────────
#  Container constructors push themselves as the current parent; end_ft_* pops
#  (mismatch = immediate error). A control with no explicit parent= gets the
#  innermost open container. end_ft_* is NOT a destructor: it means "all
#  children known" — <type>_on_children_complete runs there (the form's builds
#  the focus ring from the focusable controls in declaration order).
#
#  ── Events ───────────────────────────────────────────────────────────────────
#  ft_dispatch_event walks the focused control's keymaps (instance overlay →
#  shared keymap=NAME ref → prototype default), then each ancestor's, up to
#  the root. First match runs `action [args…] name token`; a `drop` default
#  stops the walk. ENTER/SPACE on activatable prototypes run ft_activate, which
#  calls onActivate=fn if defined. accessKey=G is sugar: underline + an auto
#  [Gg]→"ft_activate <name>" binding on the enclosing form.
#
#  Depends on ft-core.bash and ft-keymap.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_FORMS_LOADED:-}" ]] && return 0
_FT_FORMS_LOADED=1

declare -A FT_TYPE=() FT_PARENT=() FT_KIDS=() FT_DRAW=() FT_FOCUSABLE=() FT_KEYMAP=() FT_PROPS=()
declare -A FT_ABSOLUTE_X=() FT_ABSOLUTE_Y=() FT_MEASURED_WIDTH=() FT_MEASURED_HEIGHT=() FT_PREFERRED_WIDTH=()

# ── Property get / set (camelCase, no aliasing) ──────────────────────────────
# ── Subscripted property names ───────────────────────────────────────────────
# A property may be SUBSCRIPTED — `text[textCopied]`, `borderAnimation[activated]`
# — the CSS-ish way a control keys a family of related values by event/variant.
# But a prop name becomes both a shell-variable component (`<name>_<prop>`) and an
# array subscript (`FT_PROP_KIND[<prop>]`), and bash reads `foo[bar]` there as an
# array reference, not a literal. So we fold the brackets into a bash-safe key
# ONCE at every boundary: text[textCopied] → text__textCopied. Non-subscripted
# names (the overwhelming common case) short-circuit untouched — one glob test,
# no allocation — so the hot read/resolve paths pay effectively nothing.
_ft_propkey() { case $1 in
    --*)   local k="cssvar__${1#--}"; FT_RET=${k//[^a-zA-Z0-9_]/_} ;;   # custom property (--x) → bash-safe key
    *'['*) local k=${1//'['/__}; FT_RET=${k//']'/} ;;                    # subscripted prop (text[event])
    *)     FT_RET=$1 ;;
esac; }

# The properties a CLIP RECT is made of. _ft_inset4 reads these straight out of the shell
# variable, so writing one changes the rect on the very next paint — no layout pass in between,
# and for overflow/overflowX not even a scheduled one, since those are registered paint-kind.
# Declared -A up here, ahead of _ft_setprop's first call, because an undeclared name would make
# bash evaluate the subscript as ARITHMETIC and quietly answer slot 0 for every property.
declare -A _FT_CLIP_PROPS=()
for _p in border padding paddingTop paddingRight paddingBottom paddingLeft \
          overflow overflowX overflowY; do _FT_CLIP_PROPS[$_p]=1; done
unset _p
# The two cache generations, declared HERE rather than beside the caches they key (which live
# with _ft_clip_for and _ft_inset4, ~2000 lines down) because _ft_setprop bumps them and a
# prototype constructor can call _ft_setprop while this file is still being sourced. An
# undeclared name reaching `(( ))` is an unbound-variable error under set -u, not a zero.
declare -i _FT_CLIP_GEN=0       # geometry, the tree, or a box changed → clip rects
# (Defined up here with the counter: _ft_setprop bumps it, and a prototype registered while this
# file is still being sourced reaches _ft_setprop.)
_ft_clip_inval() { (( _FT_CLIP_GEN++ )); }

# ── The resolved-property memo ───────────────────────────────────────────────
# ft_resolved_prop is the framework's hot read — 538 in one warm layout of the 37-control
# css-demo page, 54 in every frame of a callout drag — and it kept no memory of its answer.
# Measured with tools/bench-resolve.bash — 4000 calls, run on a checkout with the memo and one
# without, so the two columns are the same measurement of the same function:
#
#     ft_resolved_prop, value set on the instance      72.2 µs  →  31.8 µs from the memo
#     ft_resolved_prop, INHERITED — walks ancestors   178.6 µs
#     an empty bash function call, for scale            5.6 µs
#
# so a hit is worth 40 µs on the ordinary read and ~147 µs where it replaces an ancestor walk.
# THE TAX ON A READ IT REFUSES is 16-23 µs — the probe, paid and wasted. That is why the store
# conditions are chosen to be rare rather than merely safe: measured over a real layout and a
# real drag frame, 98% and 93% of reads are eligible, so the tax lands on a fortieth of them.
#
# WHAT IS STORED is ft_resolve's answer — before the caller's default, which belongs to the CALL
# SITE (two of them may pass different ones), and before coercion, which belongs to the prototype.
# An entry is only made when all four of these hold; they are checked on the miss path, so a hit
# pays for none of them:
#
#   1. the property is not `text`/`value`. Those may be owed a join from the line store and
#      ft_resolve materialises it as a side effect; a hit would skip the join.
#   2. the name contains no `-` and no `[`. `_ft_setprop` does not fold kebab→camel (the DSL does
#      that earlier), so this makes the memo key exactly the key a write normalises to — and it
#      keeps a literal bracket out of an array subscript. Custom properties (`--x`) fall out here.
#   3. NO REGISTERED SHEET DECLARES IT. This is the condition that makes the rest of this comment
#      short: with that gate shut, ft_resolve provably never reaches the cascade, so the answer
#      cannot depend on a stylesheet, the theme, FT_FOCUS, `:root`, var(), specificity or any
#      selector — and none of them appear below. It costs almost nothing: measured, 98% of a
#      layout's reads and 93% of a drag frame's pass it, because the properties a LAYOUT asks
#      about are not the ones stylesheets are written about.
#   4. the property has no coercion hook for this control's type, so the stored value is the whole
#      answer. A hook may read anything — a percentage against the parent, a colour against the
#      colour mode — and "anything" is not an enumerable surface.
#
# WHAT AN ENTRY THEN DEPENDS ON, exhaustively:
#     the control's own `_ftp_<name>_<prop>`;
#     whether the property inherits (FT_INHERITED_PROP — fixed once ft-css has loaded);
#     FT_TYPE[name], and FT_PROTO_DEFAULT["<type> <prop>"];
#     for an inheriting property, the FT_PARENT chain and every ancestor's own value and
#       prototype default;
#     _FT_CSS_DECLARED_PROPS[prop] — condition 3 itself.
#
# AND EVERY ROUTE THAT CAN CHANGE ONE. This enumeration is what the cache lives or dies on, so
# each route is driven by tests/test-resolvememo.bash and fails there if its bump is removed:
#
#   · a property is written or removed — _ft_setprop, ft_unset, and _ft_setprop's two
#     early exits (the `onX=` listener plist and the inline `style` string). The pair goes; if the
#     property INHERITS, this node's whole SUBTREE goes, because everything under it may have been
#     reading that value through the ancestor walk. A custom property needs neither: it is never
#     stored (condition 2) and it can only reach another property through var(), which is
#     cascade-only and therefore never stored either.
#   · a control is created, removed or cloned — its version goes up. NEVER unset: an unset version
#     and a fresh one compare equal, and this framework has already paid once for a rebuilt
#     control serving a dead one's cached answer (see ft_css_forget's comment).
#   · a control is MOVED (_ft_reparented) — its subtree inherits through somewhere else now.
#   · a prototype finishes declaring — FT_PROTO_DEFAULT is the last level of every instance's
#     resolution, so the generation goes up and every entry everywhere is dropped.
#   · a stylesheet registers, or the theme swaps (_ft_css_bump) — it may DECLARE a property, which
#     is condition 3, so the generation goes up.
#   · a prototype's `setProp=` reconciler stamps a SIBLING property — _ft_multitoggle_setprop and
#     _ft_select_setprop keep `value` and `selectedIndex` in step — without going back through
#     the setter, which would recurse. They write through _ft_stamp_prop, which forgets the pair
#     it stamps; that is the whole reason it is a function.
#
# NOT in the surface, and this is exactly what condition 3 buys: geometry, FT_LAYOUT_EPOCH, the
# clip rect, paint order, the focused control, the theme, and every selector in every sheet.
#
# A SUBTREE WALK RATHER THAN A GLOBAL BUMP for an inheriting write, though the bump would be one
# statement instead of a walk: an animation that steps `color` on one leaf every frame would then
# drop all 37 controls' entries every frame, which is the case this memo exists to serve.
declare -A _FT_RESOLVED_PROP_MEMO=()     # "<name><US><prop>" → the value ft_resolve answered
declare -A _FT_RESOLVED_PROP_MEMO_AT=()  # …the token it was answered under
declare -A _FT_RESOLVE_VERSION=()        # name → bumped when THIS node's answers may change
declare -i _FT_RESOLVE_GENERATION=0      # bumped when EVERY node's answers may change
_ft_resolve_inval() {           # name — this node, and everything that inherits through it
    _FT_RESOLVE_VERSION[$1]=$(( ${_FT_RESOLVE_VERSION[$1]:-0} + 1 ))
    # A LEAF IS THE COMMON CASE AND MUST NOT PAY FOR THE WALK. Every inheriting write comes
    # through here, and an animation stepping `color` does it every frame. So: one bump and a
    # test, with the loop set up only when there is something to walk. Measured on
    # tools/bench-modify.bash, `ft_set b1 color=…` on a leaf — the array form cost ~65µs of a
    # ~300µs write; this one costs ~15µs (medians of five alternating runs, 295µs → 310µs).
    local kids=${FT_KIDS[$1]:-}
    (( ${#kids} )) || return 0
    local -a stack=($kids); local node
    while (( ${#stack[@]} )); do
        node=${stack[-1]}; unset 'stack[-1]'
        _FT_RESOLVE_VERSION[$node]=$(( ${_FT_RESOLVE_VERSION[$node]:-0} + 1 ))
        kids=${FT_KIDS[$node]:-}
        (( ${#kids} )) && stack+=($kids)
    done
}
_ft_resolve_inval_all() { (( _FT_RESOLVE_GENERATION++ )); }
_ft_resolve_forget() {          # name prop — only this pair's answer can have changed
    unset "_FT_RESOLVED_PROP_MEMO[$1"$'\x1f'"$2]" "_FT_RESOLVED_PROP_MEMO_AT[$1"$'\x1f'"$2]"
}
# _ft_stamp_prop NAME PROP VALUE — write a property variable WITHOUT going through _ft_setprop.
#
# The one legitimate caller is a prototype's `setProp=` reconciler keeping a SIBLING property
# in step with the one just written (a multitoggle's `value` following its `selectedIndex`);
# the setter calls the reconciler, so a reconciler that called the setter back would recurse.
#
# Bypassing the setter also bypasses the setter's memo invalidation — which is why this is a
# function rather than a `printf -v` written out at each site. The two lines were written out
# twice, and the second copy forgot one of its two pairs. PROP must already be a normalised key
# (a reconciler is handed one); an app-facing route would need _ft_propkey first.
#
# IT DOES NOT INVALIDATE THE CASCADE, and that is safe for a measured reason rather than an
# assumed one. A stamp only ever happens inside a reconciler, which only ever runs from
# _ft_setprop — so the write that TRIGGERED it has already run the full cascade invalidation on
# that node in the same breath, and a later read re-resolves. Verified: with a sheet carrying
# `slider[value="4"]`, `ft_set sl max=4` (which sanitizes `value` through this function)
# resolves to the attribute rule's colour, not the previous frame's.
#
# The hole in that argument is a reconciler stamping onto a DIFFERENT control, whose cascade
# nothing invalidated — ft_radio_select does exactly that to the previously selected radio. It
# is not reachable today only because `checked` is not one of the properties a selector can
# match on (_FT_CSS_MATCH_PROPS is id, runlevel, class, value). If `checked` is ever added to
# that set, or a reconciler ever stamps `value` onto another control, this function owes the
# cascade invalidation too.
#
# IT REGISTERS THE PROPERTY, because that is the difference between a property and a variable:
# FT_PROPS is what ft-state walks to save a control and what _ft_has_prop answers from. A radio's
# `checked` is stamped and never otherwise written, and until this line existed ft-state.bash had
# to carry a per-control-kind record to save the one fact the generic route could not see.
# _ft_clamp_scroll NAME PROP VALUE → FT_RET — the offset that may actually be stored: 0 at the
# top, scrollHeight-clientHeight at the bottom, VALUE in between. Answers VALUE unchanged while
# the box has not published its extent yet, and for a non-integer, which _ft_setprop's numeric
# guard has already rejected by the time this runs on any real write.
_ft_clamp_scroll() {            # name prop value → FT_RET
    local v=$3 extentProp clientProp extent client
    case $2 in
        scrollTop)  extentProp=scrollHeight; clientProp=clientHeight ;;
        scrollLeft) extentProp=scrollWidth;  clientProp=clientWidth  ;;
    esac
    FT_RET=$v
    case $v in ''|*[!0-9-]*|-*-*|-) return 0 ;; esac    # not a number: the guard above rejects it
    (( v < 0 )) && { FT_RET=0; return 0; }              # the top edge needs no measurement
    _ft_get_raw "$1" "$extentProp"; extent=$FT_RET
    _ft_get_raw "$1" "$clientProp"; client=$FT_RET
    FT_RET=$v                                          # …the two reads above just clobbered it
    (( ${#extent} && ${#client} )) || return 0         # not measured yet — leave the value alone
    local max=$(( extent - client )); (( max < 0 )) && max=0
    (( v > max )) && FT_RET=$max
    return 0
}
_ft_stamp_prop() {              # name prop value
    printf -v "_ftp_${1}_${2}" '%s' "$3"
    local props=${FT_PROPS[$1]:-}
    case " $props " in *" $2 "*) : ;; *) FT_PROPS[$1]="${props:+$props }$2" ;; esac
    _ft_resolve_forget "$1" "$2"
    return 0
}

# THE GENERATION CLOCK. Every per-control generation — `_fti_<name>__writegen`, `__textgen` — takes
# its next value from this one counter, never from its own old value plus one. A cache keyed on
# "name + generation" is only sound if a value, once used, is never used again, and a per-control
# counter broke that the moment a control was removed: ft_remove unsets the counter, the control
# rebuilt under the same name — which is the documented rebuild idiom, `ft_empty` then the same
# stable names — counted up from zero again, and after one write each its key equalled the dead
# control's. A text area on page two then drew page one's lines, while `ft_get … value` answered
# page two (the textfield layout memo, _FT_TEXTFIELD_LINES_CACHE_KEY, is the one that showed it).
# CONTRIBUTING §3 says "bump a version, never unset it"; this is how the unset stays harmless.
# The same one statement per bump as before — only the source of the number changed.
_FT_GENERATION_CLOCK=0
_ft_setprop() {                 # name prop value
    local name=$1 prop val=$3
    # onEvent=fn SUGAR: `onActivate=fn` (constructor or ft_set) registers fn as an event
    # LISTENER — it appends to the `eventListeners` plist ("activate=fn change=g …"), so several
    # listeners per event coexist and repeated onActivate= args in ONE call all accumulate.
    # An EMPTY value clears that event's listeners (like el.onactivate = null). Explicit runtime
    # add/remove: ft_add_listener / ft_remove_listener. Dispatch: _ft_hook.
    # A runlevel the prototype never declared would leave the control in a state no pseudo-class
    # can match — silently. Reject it where the mistake is, not where it fails to show.
    local _rl_from=""
    # A control's TYPE is empty once it has been removed, and `${SOME_ASSOC[""]}` is a bash
    # error printed to stderr — the alt screen, in a TUI. Read it once into a local and
    # subscript with that. (Writing a property on a control a handler already removed is an
    # ordinary race, not a misuse.)
    local _ty=${FT_TYPE[$1]:-}
    # A GEOMETRY VALUE ENDS UP INSIDE (( … )), AND BASH ARITHMETIC IS NOT INERT. It resolves
    # bare words as variables and it EVALUATES ARRAY SUBSCRIPTS — so `width=q[$(cmd)]` RUNS cmd,
    # and backticks work too (both verified). Short of that, `width=1e3` is "value too great for
    # base", `width="3 4"` is a syntax error, and a twenty-digit width makes bash try to
    # allocate 18 exabytes — every one of them printing onto the alt screen. `width=abc` was
    # quietly 0, which is how it goes unnoticed. These values come from an app's own code, but
    # in a samba tool that code computes them from a config file.
    #
    # CSS's rule: an invalid declaration is DROPPED, leaving the previous value. Same here.
    # …UNLESS THE PROTOTYPE SAYS IT READS THAT NAME AS A KEYWORD. A property's meaning belongs
    # to the PROTOTYPE, not to a global table — `value` already means four different things —
    # and `size` is the case that proved it: a textfield's size is a column count, and a
    # bigarrow's is one of four authored shapes (`small | medium | large | x-large`). The guard
    # exists to keep an app-supplied value out of `(( ))`; a prototype that resolves the name
    # through a fixed `case` never puts it there, so guarding it is not safety, it is a wrong
    # answer — measured, as `ft: ga: size="small" is not a number — declaration dropped`.
    # Declared per prototype (`keywordProps=`), so the exemption is exactly as wide as the
    # prototype that asked for it and every other control's `size` is still a number or dropped.
    if [[ -n "${_FT_NUMERIC_PROP[$2]:-}" && -n "$3" ]] \
       && [[ " ${FT_PROTO_KEYWORD_PROPS[$_ty]:-} " != *" $2 "* ]]; then
        case "$3" in
            auto|inherit|initial|unset) : ;;                 # keywords the layout understands
            *[!0-9-]* | -*-* | -)                            # anything not a plain integer
                printf 'ft: %s: %s="%s" is not a number — declaration dropped\n' "$1" "$2" "$3" >&2
                return 1 ;;
            *)  # …and an integer still has to have the SIGN the property allows. CSS types a
                # length as `<length>` or `<length [0,∞]>`, and a width of -6 here did not stay
                # inside the control that asked for it — it moved the next sibling backwards
                # over the first (see _FT_NUMERIC_PROP for the measurement).
                if [[ "$3" == -* && "${_FT_NUMERIC_PROP[$2]}" == + ]]; then
                    printf 'ft: %s: %s="%s" cannot be negative — declaration dropped\n' "$1" "$2" "$3" >&2
                    return 1
                fi
                # …and a plausible SIZE. A twenty-digit width overflows bash's arithmetic and
                # then makes it try to allocate 18 exabytes for the padding — the process dies
                # of the allocation, not of the number. A terminal is a few hundred cells wide
                # and a document a few million lines.
                if (( ${#3} > 7 )); then
                    printf 'ft: %s: %s="%s" is out of range — declaration dropped\n' "$1" "$2" "$3" >&2
                    return 1
                fi ;;
        esac
    fi
    case $2 in runlevel)
        # …but only for a control that still HAS a prototype. On a removed one there is nothing to
        # have declared anything, so the diagnostic could only say "not declared for ?" — and
        # printing it would put that on the alt screen. Every other property is stored silently
        # for a dead name; this one now behaves the same instead of shouting about a prototype that
        # no longer exists.
        if [[ -n "$_ty" ]]; then
            _ft_runlevels_of "$1"; local _rls=${FT_RET:-unfocused}
            case " $_rls " in
                *" $3 "*) : ;;
                *) printf 'ft: %s: runlevel "%s" is not declared for %s (have: %s)\n' "$1" "$3" \
                       "$_ty" "$_rls" >&2
                   return 1 ;;
            esac
        fi
        # THE RUNG BEING LEFT IS THE ELEMENT'S, WHICH INCLUDES ITS PROTOTYPE DEFAULT. Read raw,
        # this answered "" for the first transition of every control's life — because `unfocused`
        # is a prototype default and prototype defaults stopped being stamped onto instances —
        # and the line below reads "" as CONSTRUCTION. So the first Enter into any control
        # skipped its exit script and its enter script: measured as a textfield reaching
        # runlevel `editing` with `textfield_runlevel_editing_enter` never called, i.e. no mode
        # hint, no border sheen.
        _ft_prop_or_prototype "$1" runlevel ""
        _rl_from=$FT_RET
        # Setting it to what it already is is a NO-OP: no scripts, no invalidation. Guarded
        # once here so no runlevel script ever has to defend against being run twice. This is
        # also what makes construction a no-op rather than a special case now: a control is born
        # at its prototype's rung, so writing that same rung changes nothing and returns here.
        [[ "$_rl_from" == "$3" ]] && return 0
        # Leaving fires while the OLD runlevel is still current, so a script can still see
        # what it is tearing down.
        [[ -n "$_rl_from" ]] && _ft_runlevel_script "$1" "$_rl_from" exit
        ;;
    esac
    case $2 in on[A-Z]*)
        local __e=${2#on} __ev="" __i __ch                # camelCase → snake event name
        for (( __i=0; __i<${#__e}; __i++ )); do           # (onChildrenComplete → children_complete)
            __ch=${__e:__i:1}
            if [[ $__ch == [A-Z] ]]; then (( __i )) && __ev+=_; __ev+=${__ch,,}; else __ev+=$__ch; fi
        done
        local __lk="_ftp_${name}_eventListeners"          # NB: separate line — same-statement local
        local __cur=${!__lk-} __tok __out=""
        if [[ -z "$val" ]]; then                          # onX="" → drop all listeners for X
            for __tok in $__cur; do [[ ${__tok%%=*} == "$__ev" ]] || __out+="${__out:+ }$__tok"; done
            printf -v "$__lk" '%s' "$__out"
        else
            case " $__cur " in *" $__ev=$val "*) : ;;     # identical listener twice = once (DOM)
                *) printf -v "$__lk" '%s' "${__cur:+$__cur }$__ev=$val" ;; esac
        fi
        local __cp=${FT_PROPS[$name]:-}                   # register the plist prop for cleanup
        case " $__cp " in *" eventListeners "*) : ;; *) FT_PROPS[$name]="${__cp:+$__cp }eventListeners" ;; esac
        _ft_resolve_forget "$name" eventListeners         # this exit writes a property and returns
        return 0
    ;; style)
        # HTML's inline `style` attribute: style="color: 201; font-weight: bold" — each declaration
        # is parsed (kebab→camel, like el.style.cssText) and set as the element's own property, so
        # it lands at cascade level 1 exactly like color=201 would. Custom properties (--x: v) work
        # too. The raw string is stored as well, so ft_get NAME style round-trips.
        if declare -F _ft_css_camel >/dev/null 2>&1; then
            local __rest="$3;" __d __p __v
            while [[ -n "$__rest" ]]; do
                __d=${__rest%%;*}; __rest=${__rest#*;}
                [[ "$__d" == *:* ]] || continue
                __p=${__d%%:*}; __v=${__d#*:}
                __p=${__p//[[:space:]]/}
                __v="${__v#"${__v%%[![:space:]]*}"}"; __v="${__v%"${__v##*[![:space:]]}"}"
                [[ -z "$__p" ]] && continue
                _ft_css_camel "$__p"
                _ft_setprop "$name" "$FT_RET" "$__v"
            done
        fi
        printf -v "_ftp_${name}_style" '%s' "$3"
        local __sp=${FT_PROPS[$name]:-}
        case " $__sp " in *" style "*) : ;; *) FT_PROPS[$name]="${__sp:+$__sp }style" ;; esac
        _ft_resolve_forget "$name" style      # the declarations recursed and forgot themselves;
        return 0                              # the raw string stored just above did not
    esac
    _ft_propkey "$2"; prop=$FT_RET
    # A SCROLL OFFSET IS CLAMPED AT THE WRITE, not corrected at the paint. `el.scrollTop = 99` on
    # a 12-line box in a 4-row viewport reads back 8 in a browser; here it read back 99 while the
    # label PAINTED line 9 — a property and a picture disagreeing, and ft_label_scroll_set (the
    # verb for the same job) stored 8, so the two routes gave different answers.
    #
    # The bounds are the box's OWN published scrollHeight/clientHeight, so this belongs to the
    # framework rather than to a prototype: every scrollable control publishes that pair (see
    # _ft_pass_arrange and _ft_label_metrics) and none of them may hold an offset outside it.
    # Skipped while the pair is unknown — before the first arrange, during construction — because
    # clamping against a scrollHeight of nothing would pin every offset to 0.
    #
    # THE BORDER PROPERTIES ARE NORMALIZED AT THE WRITE for the same reason, one step earlier:
    # the value is corrected before it is stored, so `ft_get` can only ever answer something a
    # renderer draws. borderStyle read back `zzz` while the frame painted a plain solid box;
    # borderWidth read back `5px` and drew thin. borderGlyph is the one that cannot be
    # corrected — a two-column glyph has no honest tiling into an arbitrary width — so it is
    # DROPPED, which is what CSS does with a value it cannot use.
    case $prop in
        scrollTop|scrollLeft) _ft_clamp_scroll "$name" "$prop" "$val"; val=$FT_RET ;;
        borderStyle)          _ft_border_style "$val"; val=$FT_RET ;;
        borderWidth)          _ft_border_width "$val"; val=$FT_RET ;;
        borderGlyph)          _ft_border_glyph_fits "$name" "$val" || return 1 ;;
    esac
    # Bump this control's TEXT GENERATION whenever its text changes. The extent and wrap
    # caches are keyed on the text itself, so every lookup costs a full string compare —
    # 4ms and 14ms on a 1000-line log, on every layout pass, even when it HITS. A caller that
    # knows it is passing the control's own text can pass this counter instead and the
    # lookup becomes an integer compare. See _ft_text_extent_cached / ft_wrap_cached.
    # TWO QUESTIONS, TWO COUNTERS, and they were one counter serving both.
    #
    #   __writegen   did ANYTHING about this control change? The retained display list asks
    #                this (see _ft_retain_token), and it must stay maximally conservative —
    #                it is what covers a write that forgot to dirty, the failure that design
    #                fears most. Bumped on every write, forever, no exceptions.
    #   __textgen    did this control's displayed TEXT change? The extent and wrap memos ask
    #                this, and for them "over-invalidating merely costs a recompute" turned
    #                out to be false by two orders of magnitude.
    #
    # Measured on a 1200-line textfield, whose wrap memo keys on the generation:
    #
    #     repaint, nothing changed                      8 ms
    #     repaint after `ft_set f runlevel=editing` 199 ms
    #     repaint after `ft_set f runlevel=poised`  145 ms
    #
    # Every Enter INTO the field and every Esc OUT of it re-wrapped a document that had not
    # changed — on the keystone interaction of the whole framework. And it never had to:
    # _ft_textfield_layout's key is "$name|$w|$wrap|$gen", so the width and the wrap flag are
    # already in it by name and the generation has only ever needed to track the value.
    #
    # A prototype declares `textProps="…"` to name the properties that can change what it displays.
    # DECLARING NOTHING KEEPS EXACTLY THE OLD BEHAVIOUR — bump on everything — so a prototype that
    # composes its label out of four properties (a radio, a multitoggle) is untouched and cannot
    # be broken by failing to opt in. The failure mode of forgetting is a recompute; the failure
    # mode of getting the LIST wrong is a stale measurement, which is why it is one line in the
    # prototype that owns the text rather than a guess made here.
    # `_ty` is EMPTY for a control an earlier handler in this burst removed, and ${ASSOC[""]} is
    # a bash error on stderr — which in a TUI is the alt screen. Read it into a local first, the
    # same shape the reconciler below uses and for the same reason. An empty list then falls to
    # the "declares nothing" arm, which is the conservative answer.
    local _genvar="_fti_${name}__writegen" _tprops=""
    printf -v "$_genvar" '%s' $(( ++_FT_GENERATION_CLOCK ))
    [[ -n "$_ty" ]] && _tprops=${FT_PROTO_TEXT_PROPS[$_ty]:-}
    case " $_tprops " in
        "  "|*" $prop "*) _genvar="_fti_${name}__textgen"
                          printf -v "$_genvar" '%s' $(( ++_FT_GENERATION_CLOCK )) ;;
    esac
    # Every property lives in the shell variable  _ftp_<control>_<property>.
    #
    # The `_ftp_` prefix is NOT decoration — it is what keeps the engine out of the caller's
    # variable namespace. Bash is dynamically scoped: a `local` in the calling function is
    # visible to everything it calls, so unprefixed storage would make a control's property
    # and a user's local THE SAME VARIABLE whenever the names lined up. They line up easily,
    # because property names are ordinary words:
    #
    #     build_shell() {
    #         local log_rows=$1                       # ← this *is* control `log`, prop `rows`
    #         ft_remove app                           #   …so ft_remove's unset clears it,
    #         ft-textfield name=log rows="$log_rows"  #   and the field is built empty.
    #     }
    #
    # That exact collision silently broke tests/test-growth.bash. Reads, writes and unsets
    # all go through this file, so the prefix is applied in one place per operation and the
    # user's `log_rows` is now simply a different variable.
    # A RECONCILER CANNOT ASK WHAT IT REPLACED, because by the time it runs — deliberately last,
    # see below — the old value is already gone. Read it HERE, where it is still there, and only
    # for a prototype that has a reconciler to tell: this is the array read the call site at the
    # bottom used to make, moved up rather than added.
    #
    # ft-scrollbar is why. "Scroll to 8" on a bar already at 8 must not fire onScroll, and the
    # write that carries it is `scrollTop=99` clamped down to 8 — which looks like a change to
    # everything above this line, because the raw value really did differ from the stored one.
    # Only the previous value can tell the difference, and only this line can still see it.
    local _recon="" _prev=""
    if [[ -n "$_ty" ]]; then
        _recon=${FT_PROTO_SETPROP[$_ty]:-}
        if [[ -n "$_recon" ]]; then local _pv="_ftp_${name}_${prop}"; _prev=${!_pv-}; fi
    fi
    printf -v "_ftp_${name}_${prop}" '%s' "$val"
    # …and ENTERING fires once the new runlevel is current, so a script reads the world it
    # is arriving in. (_rl_from is only set for a real runlevel transition — see the top.)
    [[ -n "$_rl_from" ]] && _ft_runlevel_script "$name" "$val" enter
    # Writing the property DIRECTLY supersedes any deferred join: the line store no longer
    # describes this control's content, and a read that still thought the property was owed
    # would join the OLD lines straight over what was just written. (The generation bump above
    # already tells the store to rebuild — this is the other half of the same fact.)
    case $prop in text|value)
        [[ "${_FT_TEXT_STALE[$name]:-}" == "$prop" ]] && unset "_FT_TEXT_STALE[$name]" ;;
    esac
    # A CONTROL THAT IS NOT DRAWN IS NOT ANIMATING. ft_anim_step's reaper collects the
    # animations of DESTROYED controls and nothing else, so `ft_remove` stopped an animation
    # and `display:none` did not — measured: hide the animated control on css-demo page 8 and
    # it is still in the registry thirty ticks later, while removing it clears it. The cost is
    # not the milliseconds; it is that FT_ANIM_ACTIVE never returns to 0, so the run loop never
    # falls back to its lazy 0.25s idle poll, and every tab body you have ever opened keeps its
    # animations registered for the life of the process.
    #
    # It is asked HERE, at the property write, because that is the one path into the state.
    # The two routes that hide things do not share anything above this: ft_set has its own
    # `display` branch, and _ft_tabs_show_only deliberately bypasses ft_set (see the comment
    # at controls/ft-tabs.bash — routing it through would drag in a full reflow per switch).
    # A guard on one route and not its siblings is this codebase's most frequently logged root
    # cause, and the sibling here was already written and already exempt.
    #
    # Asking the visibility predicate per TICK instead was measured and rejected:
    # _ft_hidden_anywhere costs ~300us a call, and nothing bumps an epoch on a display change
    # that a reaper could watch to skip it (FT_LAYOUT_EPOCH does not move). Showing it again
    # needs no counterpart — every arm in the framework is idempotent and runs from the paint.
    # (`:-0` because FT_ANIM_ACTIVE is declared further down this file, and a `set -u` app must
    # not die on a property written before sourcing reaches it.)
    # THE SELECTIVE TEST FIRST, not the cheapest. FT_ANIM_ACTIVE is non-zero whenever ANYTHING
    # on screen animates — which is most of the time — so leading with it filters nothing and
    # runs two string comparisons on every property write in the framework. `display` writes
    # are rare; that is the test that short-circuits.
    if [[ "$prop" == display && "$val" == none ]] && (( ${FT_ANIM_ACTIVE:-0} )); then
        ft_anim_stop_subtree "$name"
    fi
    local cur=${FT_PROPS[$name]:-}          # :- so a not-yet-registered name is safe under set -u
    case " $cur " in *" $prop "*) : ;; *) FT_PROPS[$name]="${cur:+$cur }$prop" ;; esac
    # Invalidate the resolver cache ONLY for props a lookup can depend on (style overrides,
    # custom properties, or a prop some selector matches on). A textfield's `value`, restamped
    # every keystroke, does NOT normally qualify — so rapid typing keeps the cache warm.
    # A box property changes every descendant's clip rect immediately, and the cascade
    # invalidation below will NOT notice: _ft_css_inval_prop only bumps properties that
    # INHERIT, and border/padding/overflow do not.
    [[ -n "${_FT_CLIP_PROPS[$prop]:-}" ]] && _ft_clip_inval
    # The resolved-property memo, on its own predicate and outside the two branches below,
    # because it must hold whether or not ft-css.bash is loaded — tests/test-selection.bash
    # sources ft-forms alone, and in that configuration neither `declare -F` below is true and
    # the whole `if` does nothing. An inheriting property reaches every descendant's ancestor
    # walk, so its subtree goes; nothing else can read this pair.
    if [[ -n "${FT_INHERITED_PROP[$prop]:-}" ]]; then _ft_resolve_inval "$name"
    else _ft_resolve_forget "$name" "$prop"; fi
    if declare -F ft_css_prop_affects_style >/dev/null && ft_css_prop_affects_style "$prop" "$2"; then
        # Scoped: this change can only affect NAME's own cascade and its descendants' (inheritance /
        # descendant combinators), so invalidate just that subtree — not every control on screen.
        if declare -F _ft_css_inval >/dev/null; then _ft_css_inval "$name"
        else _FT_CSS_EPOCH=$(( ${_FT_CSS_EPOCH:-0} + 1 )); fi
    elif declare -F _ft_css_inval_prop >/dev/null; then
        # …and the property no stylesheet has ever mentioned still just changed the FIRST level
        # of its own cascade, so its one memo entry has to go. See _ft_css_inval_prop.
        _ft_css_inval_prop "$name" "$prop"
    fi
    # A PROTOTYPE MAY KEEP ITS REAL STATE SOMEWHERE ELSE. A checkbox is a two-option multitoggle
    # whose truth is `selectedIndex`; `checked=` was translated to it by the ft-checkbox
    # CONSTRUCTOR and nowhere else, so `ft_set cb checked=true` was a silent no-op, while
    # `ft_set cb value=true` set a shadow value the drawing never saw — the control then
    # reported CHECKED to the app and drew UNCHECKED to the user, at the same time. Give
    # the prototype one place to reconcile, on every route in (ft_set, the DSL, a state restore).
    #
    # THE PROPERTY NAMES USED TO BE LISTED HERE, and the list was wrong four times in one
    # sitting: `checked|value|selectedIndex` did not cover a slider's min/max/step, then not a
    # radio's group, then not a table's cursor, then not its scrollTop — each time a reconciler
    # that WAS registered simply never ran, silently, which is the same shape as every bug this
    # mechanism exists to fix. A prototype declaring a reconciler is the whole declaration; a second
    # global list deciding whether it is ever called is a place to forget. Measured, the list was
    # not buying anything either: it replaced one associative read with up to nine string
    # compares. So the prototype is asked directly, and every reconciler opens with its own `case`.
    # The asymmetry is the point: forgetting that `case` now costs a little wasted work, where
    # forgetting a name on the old list cost a reconciler that never ran and said nothing.
    #
    # LAST, not first, and that placement is load-bearing: a reconciler READS the property that
    # just changed, and until the lines above have run, ft_resolved_prop still answers out of the
    # memo with the OLD value. Reconciling first, `ft_set sl max=4` sanitized 5 against a max
    # of 100 and left it at 5 — the very bug the reconciler was added to fix.
    #
    # (`_recon` and `_prev` were read above, just before the write — the type guard lives there
    # now, for the same reason it lived here: ${SOME_ASSOC[""]} is a bash error on stderr, which
    # in a TUI is the alt screen.) THE FOURTH ARGUMENT IS WHAT THE PROPERTY HELD BEFORE, so a
    # reconciler can tell a real move from a write that landed back where it started.
    [[ -n "$_recon" ]] && "$_recon" "$name" "$prop" "$val" "$_prev"
    return 0
}
# el.removeAttribute — truly UNSET a property (distinct from setting ""), so the control falls
# back to its prototype default / the stylesheet. Handles subscripted props and custom properties
# (--x) via _ft_propkey, and invalidates the cascade when the property could affect a style.
ft_unset() {         # NAME PROP
    local name=$1
    _ft_propkey "$2"; local pk=$FT_RET
    local _rpv="_ftp_${name}_${pk}" _rprev; _rprev=${!_rpv-}   # what the reconciler is replacing
    unset "_ftp_${name}_${pk}" "FT_COERCED[${name}_${pk}]"
    # THE TEXT GENERATION, for the same reason _ft_setprop bumps it and in the same words:
    # a control's displayed text is often composed from SEVERAL of its properties, so any write
    # invalidates the extent and wrap measurements — and a removal is a write. The counter is a
    # fast path for callers that pass it INSTEAD of the string (an integer compare rather than a
    # full compare of a 1000-line log), so a missed bump does not corrupt the callers that still
    # pass the text; it serves a stale measurement to the ones that do not.
    #
    # Latent rather than live when this was fixed — removing `width` still re-measured, because
    # the caches key on the text as well — and restored anyway, because the invariant is the
    # thing being relied on, not today's set of callers. Over-invalidating costs a recompute;
    # under-invalidating is a wrong number on screen. This route already says "same predicate,
    # same route" four times below; this was the fifth and it was missing.
    # BOTH counters, and by the same rule as _ft_setprop's: a removal is a write, so __writegen
    # always moves; __textgen moves when the prototype has not narrowed itself or has named this
    # property. Same predicate, same route.
    local _genvar="_fti_${name}__writegen" _rty=${FT_TYPE[$name]:-} _tprops=""
    printf -v "$_genvar" '%s' $(( ++_FT_GENERATION_CLOCK ))
    [[ -n "$_rty" ]] && _tprops=${FT_PROTO_TEXT_PROPS[$_rty]:-}   # ${ASSOC[""]} is a stderr error
    case " $_tprops " in
        "  "|*" $pk "*) _genvar="_fti_${name}__textgen"
                        printf -v "$_genvar" '%s' $(( ++_FT_GENERATION_CLOCK )) ;;
    esac
    # Removing it also cancels any join it was owed (see _ft_setprop) — otherwise the next
    # read would materialise the line store back into a property that was just deleted.
    [[ "${_FT_TEXT_STALE[$name]:-}" == "$pk" ]] && unset "_FT_TEXT_STALE[$name]"
    local np="" p
    for p in ${FT_PROPS[$name]:-}; do [[ "$p" == "$pk" ]] || np+="${np:+ }$p"; done
    FT_PROPS[$name]=$np
    [[ -n "${_FT_CLIP_PROPS[$pk]:-}" ]] && _ft_clip_inval  # same predicate, same route
    if [[ -n "${FT_INHERITED_PROP[$pk]:-}" ]]; then _ft_resolve_inval "$name"   # …and again
    else _ft_resolve_forget "$name" "$pk"; fi
    if declare -F ft_css_prop_affects_style >/dev/null 2>&1 && ft_css_prop_affects_style "$pk" "$2"; then
        declare -F _ft_css_inval >/dev/null 2>&1 && _ft_css_inval "$name"
    elif declare -F _ft_css_inval_prop >/dev/null 2>&1; then
        _ft_css_inval_prop "$name" "$pk"       # same predicate, same route — see _ft_setprop
    fi
    # AND THE PROTOTYPE RECONCILER, which this route did not call — the sixth "same predicate, one
    # route" in this function's own list, inside the mechanism built to end them.
    #
    # Measured: on a checked checkbox, `ft_unset cb selectedIndex` repainted it
    # UNCHECKED while `ft_get cb checked` and `ft_get cb value` both still answered true. That is
    # verbatim the "reported CHECKED to the app and drew UNCHECKED to the user, at the same time"
    # that _ft_setprop's reconciler comment describes, reached through the one door the fix left
    # open. A radio was worse: removing `checked` left FT_RADIO_SELECTED naming a radio whose
    # property and paint both denied it.
    #
    # THE VALUE PASSED IS WHAT THE PROPERTY NOW RESOLVES TO, not the empty string. A removal does
    # not make a control's state absent — it makes it the prototype default, which is what the
    # control now IS and what the paint is about to use. Handing the reconciler "" would have it
    # reconcile against a value nothing will ever read.
    local _rty=${FT_TYPE[$name]:-}
    if [[ -n "$_rty" ]]; then
        local _recon=${FT_PROTO_SETPROP[$_rty]:-}
        if [[ -n "$_recon" ]]; then
            ft_resolved_prop "$name" "$pk" ""
            "$_recon" "$name" "$pk" "$FT_RET" "$_rprev"
        fi
    fi
    # REMOVING A PROPERTY IS SETTING IT, so the same repaint is owed — and it is owed by the SAME
    # function ft_set pays through (_ft_prop_owed, above ft_set). This route used to carry
    # its own copy: acting on the kind, then a display/visibility/disabled arm for damage and
    # focus. Dropping an explicit `width` once left the old geometry on screen, dropping a
    # container's `color` left the inheriting labels in the old colour, and dropping `position`
    # left a sibling where the absolute control had let it slide — each a repair to the copy.
    # Called AFTER the reconciler, as ft_set's is (_ft_setprop reconciles before returning).
    local _ft_owed="" _ft_owed_keys="" rejected=0
    _ft_prop_owed "$name" "$pk" || rejected=1       # `parent` is refused on this route too
    _ft_prop_owed_pay "$name"
    return $rejected
}
# ft_get NAME PROP [OUTVAR] — local-only read (no inherit), FORK-FREE. It
# NEVER echoes (echoing forced callers into `$(...)`, a subshell fork on
# every read — and, called unwrapped, leaked property values onto the live
# terminal). It always sets FT_RET, and if OUTVAR is given assigns it
# directly (bash printf -v, the nameref-style output pattern), so user code
# reads a value without a subshell:
#     ft_get cbBeep value beep;   [[ $beep == true ]] && ...   # into your var
#     ft_get cbBeep value;        [[ $FT_RET == true ]] && ... # or via FT_RET
ft_get() {
    # A store-backed `text`/`value` may be deferred; materialise it before handing it out. The
    # case test costs nothing for every other property, and the array probe only runs for these.
    case $2 in text|value) [[ "${_FT_TEXT_STALE[$1]:-}" == "$2" ]] && _ft_text_join "$1" ;; esac
    _ft_propkey "$2"; local var="_ftp_${1}_${FT_RET}" key=$FT_RET
    FT_RET="${!var-}"
    # …and the PROTOTYPE DEFAULT when the author set nothing, because this is the public accessor
    # and "what is this control's display" has one right answer whether or not anybody typed it.
    # It reads the prototype table rather than the instance since defaults stopped being stamped
    # there; _ft_get_raw stays the narrower question the cascade's level 1 asks.
    [[ -v "$var" ]] || FT_RET=${FT_PROTO_DEFAULT["${FT_TYPE[$1]:-} $key"]-}
    [[ -n "${3:-}" ]] && printf -v "$3" '%s' "$FT_RET"
    return 0
}
# The framework's most-called accessor — every ft_resolved_prop, every layout pass, every paint.
# An ordinary property name IS its own storage key, so the common case skips the call to
# _ft_propkey entirely; only custom properties (--accent) and subscripted ones (text[event])
# need translating. Measured: ~19.6µs before, and the nested call was about a third of it.
_ft_get_raw() {                 # name prop → FT_RET (raw, no inheritance, no coercion)
    case $2 in
        --*|*'['*) _ft_propkey "$2"; local var="_ftp_${1}_${FT_RET}" ;;
        text|value) [[ "${_FT_TEXT_STALE[$1]:-}" == "$2" ]] && _ft_text_join "$1"
                   local var="_ftp_${1}_${2}" ;;
        *)         local var="_ftp_${1}_${2}" ;;
    esac
    FT_RET="${!var-}"
}
# el.hasAttribute: does the control set this property ITSELF, however empty? The distinction
# _ft_get_raw cannot make — unset and "" both read as an empty FT_RET — and `value=""` on an
# option means something different from an option with no value at all.
# `:-` because a control that has never been written to has no FT_PROPS entry, and a bare
# subscript of a missing key is a fatal error in a `set -u` app.
_ft_has_prop() { _ft_propkey "$2"; case " ${FT_PROPS[$1]:-} " in *" $FT_RET "*) return 0 ;; *) return 1 ;; esac; }
# _ft_truthy VALUE → 0 if it means yes. ONE predicate, because there were two and they
# disagreed: _ft_multitoggle_setprop accepted true|1|yes|on while ft-checkbox's constructor
# tested only `true` and `1`, so `ft-checkbox name=c checked=yes` built an UNCHECKED box that
# `ft_set c checked=yes` then checked. The same spelling, two routes, two answers — which is
# the second half of the FT_FOCUSABLE bug CONTRIBUTING §1 writes out in full ("the value was not
# normalised on the construction route either"). A control's own state must not depend on which
# door the author came through.
_ft_truthy() { case "$1" in true|1|yes|on) return 0 ;; *) return 1 ;; esac; }

# ── Lazy inheritance (non-geometry reads walk up the parent chain) ───────────
# HOT PATH: a property is "set on this control" iff its <name>_<prop> shell
# variable exists (_ft_setprop always creates it), so `[[ -v … ]]` is an O(1)
# existence test — far cheaper than scanning the FT_PROPS string list at every
# ancestor step, and this runs thousands of times per layout/draw pass.
# Which properties take an ancestor's value when the control does not set one of its own.
# This is CSS's inherited set — plus `disabled`, which the framework treats as inherited so
# that disabling a container disables everything inside it. ft-css.bash adds to this table as
# it learns properties (see _ft_css_mark_inherit); it is the one authority.
#
# Everything NOT in here is per-control: width, padding, margin, gap, the flex properties,
# value, text, rows… In CSS none of those inherit, and resolving them up the tree let a
# container's box values leak into every descendant — which is why the base control prototype
# had to default them all to 0. That default masked the leak; this table removes it.
declare -A FT_INHERITED_PROP=(
    [color]=1 [visibility]=1 [cursor]=1 [textAlign]=1 [fontWeight]=1 [fontStyle]=1
    [disabled]=1
    # `defaultKeys` INHERITS so a container can silence a whole subtree's prototype keys with
    # one word — the same reach `disabled` has, and for the same reason: the thing you want to
    # say is "not in here", not "not on this one, and this one, and this one".
    [defaultKeys]=1
)

# ── The STATE registry (what a pseudo-class asks) ────────────────────────────
# A state is a named predicate about a control — `:disabled`, `:checked`, `:editing`. It is
# declared ONCE, and that single declaration feeds BOTH consumers:
#   • the selector matcher — how to answer "is this control in that state?"
#   • cache invalidation   — which property, changed, must re-cascade the subtree
# Keeping those together is the whole point. They used to be two hand-written `case`
# statements in ft-css.bash that had to agree: `:editing` was in the matcher and missing
# from the invalidation one, which is exactly why entering edit mode has to call
# _ft_css_inval by hand. You cannot declare a state here without saying what it reads.
#
# A state is an ALIAS from a pseudo-class to a selector — which is what a state pseudo-class
# actually IS in CSS: `:checked` is `[checked]`, `:disabled` is `[disabled]`. Two arguments,
# no keywords. Scope lives in the selector, exactly where CSS puts it, so there is no second
# "declare it for one type" verb.
#
#   ft_state :disabled          '[disabled=true]'
#   ft_state :enabled           ':not([disabled=true])'
#   ft_state textfield:editing  '[runlevel=editing]'     # only for this control type
#   ft_state :root              ft_state_is_root         # no selector can say it → a function
#
# The definition is a SELECTOR when it starts with `[` or `:`, otherwise a function name; a
# function name can be neither, so there is nothing to disambiguate.
#
# The alias is parsed ONCE, here, into the form the matcher wants — never per match. The
# property it reads is taken from that parse, so the answer and the invalidation key come
# from the same source and cannot drift.
#
# Stored: "<property> <expected>" (a leading `!` on <expected> negates) for the two common
# shapes, "@<function>" for a function, "~<selector>" for any richer selector (matched by the
# ordinary compound matcher). A property name can start with none of `@ ~`.
declare -A FT_STATE_TEST=()        # state | type:state → "<prop> <want>" | "@<fn>" | "~<sel>"
declare -A FT_STATE_TYPED=()       # state → 1 if ANY control type declares its own version
declare -A FT_STATE_DEPENDS_ON=()  # state → every property it reads, across all types

_ft_state_reads() {             # state property — record it, once
    case " ${FT_STATE_DEPENDS_ON[$1]:-} " in
        *" $2 "*) : ;;
        *) FT_STATE_DEPENDS_ON[$1]="${FT_STATE_DEPENDS_ON[$1]:+${FT_STATE_DEPENDS_ON[$1]} }$2" ;;
    esac
}
ft_state() {                    # [type]:name  '<selector>' | <function>  [property…]
    local sel=$1 def=${2-}
    [[ "$sel" == *:* ]] || { printf 'ft: state "%s": name it as :state or type:state\n' "$sel" >&2; return 1; }
    local type=${sel%%:*} name=${sel#*:}
    [[ -n "$name" ]] || { printf 'ft: state "%s": missing the state name\n' "$sel" >&2; return 1; }
    [[ -n "$def"  ]] || { printf 'ft: state %s: needs a selector or a test function\n' "$sel" >&2; return 1; }
    local key=${type:+$type:}$name property=""
    [[ -n "$type" ]] && FT_STATE_TYPED[$name]=1

    case $def in
        \[*\])                      # [prop=value] — the common shape
            local body=${def#[}; body=${body%]}
            [[ "$body" == *=* ]] || { printf 'ft: state %s: "%s" needs [property=value]\n' "$sel" "$def" >&2; return 1; }
            property=${body%%=*}
            FT_STATE_TEST[$key]="$property ${body#*=}" ;;
        ':not('\[*\]')')            # :not([prop=value]) — the negated shape
            local body=${def#:not(}; body=${body%)}; body=${body#[}; body=${body%]}
            [[ "$body" == *=* ]] || { printf 'ft: state %s: "%s" needs [property=value]\n' "$sel" "$def" >&2; return 1; }
            property=${body%%=*}
            FT_STATE_TEST[$key]="$property !${body#*=}" ;;
        \[*|:*)                     # any other selector — correct, just not on the fast path
            FT_STATE_TEST[$key]="~$def" ;;
        *)                          # a test function
            declare -F "$def" >/dev/null 2>&1 || {
                printf 'ft: state %s: test function "%s" is not defined\n' "$sel" "$def" >&2; return 1; }
            FT_STATE_TEST[$key]="@$def" ;;
    esac

    # What the state READS, keyed by the BARE name — a stylesheet may write `:editing` with no
    # type, and invalidation still has to know it reads `runlevel`. A selector alias tells us
    # this for free; a function cannot, so it names its properties as trailing arguments.
    [[ -n "$property" ]] && _ft_state_reads "$name" "$property"
    shift 2 2>/dev/null || shift $#
    local dep
    for dep in "$@"; do _ft_state_reads "$name" "$dep"; done
    return 0
}

# The states every control has. Functions first — ft_state checks they exist.
ft_state_is_root()    { [[ -z "${FT_PARENT[$1]:-}" || "${FT_ROOT:-}" == "$1" ]]; }
# :focus is DERIVED from the rung, not from a second variable. Every rung above `unfocused`
# means this control has focus, so the runlevel already answers it — and asking it twice, of
# two different sources, is how they come to disagree.
# WHO HAS FOCUS IS FT_FOCUS'S QUESTION, and the runlevel is the reflection of the answer.
# Deriving this from the rung instead looked like single-source-of-truth, but it inverted
# which one is the source: FT_FOCUS is a pointer that cannot go stale, while a per-control
# rung has to be WRITTEN by every path that moves focus — and three of them did not (the
# ring rebuild, ft_focus_first, a modal pop), so a control could hold focus, be drawn as the
# focused one, and still fail to match `:focus`. Those paths are fixed too (see
# _ft_focus_land), because the rung must be right for the border colour regardless; but the
# predicate reads the thing that is true by construction.
#
# `:focus` still spans several rungs, which is what it should do: only the focused control
# is ever at `poised` or deeper, so `:focus` covers all of them and `:engaged` / `:poised`
# name the finer distinctions.
ft_state_is_focused() { [[ "${FT_FOCUS:-}" == "$1" ]]; }
ft_state_is_empty()   { [[ -z "${FT_KIDS[$1]:-}" ]]; }       # no children
ft_state :root       ft_state_is_root
# NO property dependency, deliberately. A state declares the properties its predicate READS, so
# that a write to one invalidates the cached style. This predicate reads FT_FOCUS, which is not
# a property at all — it is a component of the cascade cache token (see _ft_css_q / ft_style),
# so moving focus re-resolves `:focus` everywhere by itself. It used to declare `runlevel`,
# which it has never read: harmless, because the extra invalidation was a superset of what was
# needed, but a declaration that names the wrong input is worse than none. The next person to
# ask "what makes :focus re-resolve?" would have got the wrong answer and, reasonably, stopped
# maintaining the thing that actually does it.
ft_state :focus      ft_state_is_focused
ft_state :unfocused  ':not(:focus)'
ft_state :empty      ft_state_is_empty
# `disabled` INHERITS, so the selector must resolve it the way the engine does. Declared as
# the attribute shape `[disabled=true]` it was answered by a RAW property read, and a button
# inside a disabled container was inert, unfocusable and painted dim while `button:disabled`
# refused to match it and `button:enabled` did — the selector and the behaviour disagreeing
# about the same control, which is the one thing this registry exists to prevent. A test
# function asks ft_resolved_prop, which is what the dim, the focus skip and ft_activate all ask.
ft_state_is_disabled() { ft_resolved_prop "$1" disabled; [[ "$FT_RET" == true ]]; }
ft_state :disabled   ft_state_is_disabled
ft_state :enabled    ':not(:disabled)'
# A control being MOVED by the mouse. Today only a grabbed callout sets it (its drag ghost reads
# borderStyle/borderRadius through the cascade, so `beacon:dragging { borderStyle: double }` is
# how an app restyles the ghost) — but the state is generic on purpose: anything draggable can
# set `dragging=true` while a grab is live and pick up `:dragging` rules for free.
ft_state :dragging   '[dragging=true]'
ft_state :selected   '[selected=true]'                       # a selected option/row
ft_state :checked    '[value=true]'                          # a checkbox/toggle that is on
# CSS Selectors L4 — the CAPABILITY axis, orthogonal to engagement. `readOnly` already exists
# as a textfield property; these give it its standard spellings.
ft_state :read-only  '[readOnly=true]'
ft_state :read-write ':not([readOnly=true])'

# ── :engaged / :outside — has this control taken the keys? ───────────────────
# The one question that generalises across every prototype and every runlevel NAME (adjusting,
# browsing, editing, scrolling, perusing…): is this control still at rest, or has it captured
# the arrows? Focused-but-outside means the arrows move BETWEEN controls; engaged means they
# belong to THIS one. Opposite meanings for the same keypress, so it has to be visible, and
# `:engaged` is what a theme styles to make it so.
#
# A PREDICATE, not a stored flag. A boolean property maintained alongside `runlevel` would be
# a second copy of the same fact, and every write to one would have to remember the other —
# the kind of duplicated state that goes stale the first time some path forgets. There is one
# source of truth and this reads it.
#
# It also cannot be written `:not([runlevel=unfocused])`: an attribute test is TRUE when the
# attribute is ABSENT, so every detached control — the theme-derivation probe, a hand-built
# test control — matched, and the palette itself came out engaged. "No runlevel" means at
# rest, and only a predicate can say that.
#
# `runlevel` is declared as its dependency, so a write invalidates the cascade automatically.
ft_state_is_engaged() {
    local v="_ftp_${1}_runlevel"
    case "${!v-}" in ''|unfocused|poised) return 1 ;; *) return 0 ;; esac
}
# `:engaged`, not `:active`: `::active` is already the PSEUDO-ELEMENT for the current item
# (a tree's cursor row, a table's row, the live tab). One colon apart, same word, unrelated
# meanings — the pair a reader would have to keep straight forever.
ft_state :engaged ft_state_is_engaged runlevel
# No name for the negation: `:not(:engaged)` says it, and the rung state `:poised` names the
# case that actually matters. Every invented word for it so far (at-rest, outside) has been
# a second metaphor competing with the first.

# ── :hidden / :visible — is this control actually on screen? ─────────────────
# A DELIBERATE extension: CSS has no such pseudo-class, because in CSS you never need to ask.
# Here you do — an accelerator must not fire for a control in a collapsed tab, and a legend
# must not advertise it. jQuery's :visible/:hidden are the nearest precedent for the names.
#
# It cannot be a selector alias: `[display=none]` reads only the control's OWN value, and
# display does NOT inherit, so a box inside a hidden container would report itself visible.
# (_ft_disp is likewise per-control — layout gets its ancestor-awareness by never descending
# into a hidden node, so nothing existing answers this question.) Hence the walk.
#
# NB reads RAW properties, never ft_resolved_prop: a state test is called FROM the cascade, so
# consulting the cascade here would recurse. Every other state works the same way.
ft_state_is_hidden() {          # name → 0 if this control is not rendered
    ft_resolve "$1" visibility          # visibility inherits: one resolve covers the chain
    [[ "$FT_RET" == hidden ]] && return 0
    local n=$1                          # display does not inherit — walk for it
    while [[ -n "$n" ]]; do
        _ft_disp "$n"
        [[ "$FT_RET" == none ]] && return 0
        n=${FT_PARENT[$n]:-}
    done
    return 1
}
ft_state_is_visible() { ! ft_state_is_hidden "$1"; }
ft_state :hidden  ft_state_is_hidden  display visibility
ft_state :visible ft_state_is_visible display visibility

# ── Runlevels — a control's engagement, as an ordinary property ──────────────
# A runlevel is which of a control's mutually-exclusive engagement states it is in:
# `unfocused` (the universal zero — every control has it, so `:not(:unfocused)` means "engaged"
# everywhere) plus whatever else the prototype declares. Making it a PROPERTY is the whole trick:
#   • the cascade invalidates on it automatically, because states declare what they read
#   • `ft_set field runlevel=editing` works — from a sibling, a parent, or the engine
#   • ft_get reads it, a stylesheet matches it, a state serialiser can save it
# Values are NOT globally ordered — a select's `open` and a textfield's `editing` are not
# comparable depths — so they are keywords, never numbers.
declare -A FT_PROTO_RUNLEVELS=()        # type → "unfocused [focused] <the levels it declared…>"
declare -A FT_PROTO_RUNLEVEL_KEYMAP=()  # type:level → the keymap in effect at that level

# THE TWO FREE RUNGS. Every control is `unfocused` — that is what it is when nobody is near
# it. A FOCUSABLE control also gets `poised`: you are standing on it, and have not gone in.
# A control that cannot take focus never gets that rung, because it could never reach it.
#
# They used to be one rung called `unfocused`, which meant BOTH "nobody is here" and "you are
# standing on this" — two states a person plainly distinguishes, collapsed into one value, so
# no border, colour or animation could tell them apart from the runlevel alone. Naming the
# state by what is NOT happening is what made that look acceptable.
#
# Deeper rungs are what a prototype ADDS (ft_runlevels); most prototypes add one, a text field
# adds three, a button adds none.
_ft_prototype_base_runlevels() {    # type → FT_RET
    [[ "${FT_PROTO_FOCUSABLE[$1]:-}" == 1 ]] && FT_RET="unfocused poised" || FT_RET="unfocused"
}

# ft_runlevels TYPE level[=keymap]…   — the free rungs above come first, always.
# A level may name the keymap that is in effect while the control is in it; entering the
# level then simply selects that map (layer 3 of _ft_keymap_layers). Nothing is saved or
# restored, because nothing is overwritten.
#
#   ft_runlevels scrolling perusing editing=ft_keymap_textfield
# Runlevel SCRIPTS — a control prototype does its entry/exit work in per-runlevel functions:
#
#     textfield_runlevel_editing_enter() { … }      # named for the level, not a switch
#     textfield_runlevel_editing_exit()  { … }
#
# One function per level per direction, dispatched by name — deliberately NOT one event with
# a case over every runlevel, which is the shape that turns a dispatch system back into a
# monolith. They are prototype-side; the per-instance `on…=` handlers stay free for the app.
_ft_runlevel_script() {         # name level enter|exit
    local fn="${FT_TYPE[$1]:-}_runlevel_${2}_${3}"
    declare -F "$fn" >/dev/null 2>&1 && "$fn" "$1"
    return 0                                     # a missing script is the normal case
}

# Built once, by the prototype that declares `keymap=form`.
_ft_define_keymap_form() {
    # Tab/Shift-Tab = linear ring order; the ARROWS move by geometry (spatial), so you
    # can cut across columns the way the layout looks. Controls that consume an arrow
    # (a slider's ←/→, a field in edit mode) never bubble it here, so they are unaffected.
    # None of these take the control or the key: they move THE FOCUS, which the ring owns —
    # so the code is the call, with no arguments invented for it.
    ft_keymap_set ft_keymap_form \
        key=TAB   onKey=ft_focus_next    key=BTAB  onKey=ft_focus_prev \
        key=RIGHT onKey=ft_focus_right   key=LEFT  onKey=ft_focus_left \
        key=DOWN  onKey=ft_focus_down    key=UP    onKey=ft_focus_up \
        key=ESC   onKey=ft_esc_action \
        key='.'   keyCap=Locate keyImp=normal onKey=ft_focus_ping
        # '.' = "where am I?" — flash a locator frame around the focused control. Bubbles
        # here from any idle control (printable keys are unbound on controls); while a field
        # is in EDIT mode it types a period instead, which is what you want.
}
declare -A FT_PROTO_RUNLEVEL_EXTRA=()   # type → just what the prototype ADDED, in order
# ft_runlevels [for=TYPE] level[=keymap]…
#
# INSIDE a prototype constructor the type is IMPLICIT, exactly as it is for `ft_prototype` — the
# constructor's body is the border, because ft_prototype_init scopes the prototype under
# construction with `local` and bash's dynamic scoping publishes it to everything called
# from there. That is why there is no begin/end pair to write: the function already is one.
#
#     ft_prototype_tree() {
#         ft_runlevels browsing=ft_keymap_tree_browsing
#         ft_prototype extends=ft_control focusable=true …
#     }
#
# OUTSIDE one — an app adding a rung to a prototype it did not write — name the CLASS:
#
#     ft_runlevels for=tree previewing=my_preview_map      # every tree in the app
#
# …or name a CONTROL, and the ladder is that one control's alone:
#
#     ft_runlevels for=sidebar previewing=my_preview_map   # only `sidebar`
#
# THOSE ARE DIFFERENT OPERATIONS, NOT SPELLINGS OF ONE. An instance ladder is ad hoc and
# stays ad hoc: it must never write through to the prototype, or "give this one field an extra
# rung" would silently re-rung every field in the app — and the author would have no reason
# to suspect it. A live control name therefore means the control; a name that is not a
# control is taken as a prototype.
#
# `for=` rather than a bare first word because a rung may be bare too (`scrolling perusing
# editing=…`), so a positional name could not be told from a rung name.
declare -A FT_RUNLEVELS=()              # control → its OWN ladder (ad hoc, overrides its prototype)
declare -A FT_RUNLEVEL_KEYMAP=()        # control:level → keymap, for an ad-hoc rung
ft_runlevels() {                # [for=TYPE|for=CONTROL] level[=keymap]…
    local target=$FT_PROTO_UNDER_CONSTRUCTION instance=""
    if [[ "${1:-}" == for=* ]]; then
        target=${1#for=}; shift
        [[ -n "${FT_TYPE[$target]:-}" ]] && instance=$target
    fi
    if [[ -z "$target" ]]; then
        printf 'ft_runlevels: no target — call it inside a prototype constructor, or pass for=TYPE or for=CONTROL\n' >&2
        return 2
    fi
    local spec level levels="" statetype=$target
    [[ -n "$instance" ]] && statetype=${FT_TYPE[$instance]}
    for spec in "$@"; do
        level=${spec%%=*}
        if [[ -n "$instance" ]]; then
            [[ "$spec" == *=* ]] && FT_RUNLEVEL_KEYMAP[$instance:$level]=${spec#*=}
        else
            [[ "$spec" == *=* ]] && FT_PROTO_RUNLEVEL_KEYMAP[$target:$level]=${spec#*=}
        fi
        levels+=" $level"
        # The CSS state is registered against the TYPE either way — `[runlevel=X]` is what it
        # tests, and a selector has to be writable whether the rung came from the prototype or
        # from one control. Scoping it to the instance would make `#sidebar:previewing`
        # unmatchable, which is the one rule you would actually want to write.
        ft_state "$statetype:$level" "[runlevel=$level]" || return 1
    done
    if [[ -n "$instance" ]]; then
        _ft_prototype_base_runlevels "${FT_TYPE[$instance]}"
        FT_RUNLEVELS[$instance]="$FT_RET${levels}"
    else
        FT_PROTO_RUNLEVEL_EXTRA[$target]=${levels# }
    fi
}
# The ladder that applies to THIS control: its own if it declared one, else its prototype's.
_ft_runlevels_of() {            # name → FT_RET
    local n=$1
    FT_RET=${FT_RUNLEVELS[$n]:-}
    [[ -n "$FT_RET" ]] && return 0
    FT_RET=${FT_PROTO_RUNLEVELS[${FT_TYPE[$n]:-}]:-}
}
# …and the keymap for one of its rungs, same precedence.
_ft_runlevel_keymap_of() {      # name level → FT_RET
    local n=$1 l=$2
    FT_RET=${FT_RUNLEVEL_KEYMAP[$n:$l]:-}
    [[ -n "$FT_RET" ]] && return 0
    local t=${FT_TYPE[$n]:-}
    FT_RET=${t:+${FT_PROTO_RUNLEVEL_KEYMAP[$t:$l]:-}}
}
# Stitch the free rungs onto whatever the prototype added. Deliberately NOT done inside
# ft_runlevels: whether `poised` exists depends on `focusable`, which a constructor
# may set before OR after declaring its rungs, so the only safe moment is once the whole
# constructor has run. Called from ft_prototype_init.
_ft_prototype_finish_runlevels() {  # type
    local t=$1
    _ft_prototype_base_runlevels "$t"; local base=$FT_RET
    local extra=${FT_PROTO_RUNLEVEL_EXTRA[$t]:-}
    FT_PROTO_RUNLEVELS[$t]="$base${extra:+ $extra}"
    local level
    for level in $base; do ft_state "$t:$level" "[runlevel=$level]" || return 1; done
    return 0
}
# ── Delving: Enter goes in, Esc comes out ────────────────────────────────────
# THE core end-user gesture. A control you have merely focused is a thing you are standing
# next to; Enter steps INSIDE it, and from then on its keys are yours to press without
# thinking. Esc leaves — all the way out, not one rung down, because "how many Escs?" is
# exactly the question the ladder exists to remove.
#
# These are the SHARED primitives. The text field grew its own (ft_textfield_engage /
# _leave) before anything else had a ladder, and every other control simply had none —
# arrows acted the moment a control was focused, so a tree stole Up/Down from focus
# navigation and a slider changed its value when you were only passing through.
#
# A prototype declares its rungs with ft_runlevels. Ordinary ladders are linear and need
# nothing else; a prototype whose next rung DEPENDS on the control (a read-only field peruses
# where an editable one edits) provides `<type>_runlevel_next NAME CURRENT → FT_RET`.
ft_runlevel() {                 # name → FT_RET (never empty: unset means unfocused)
    local _v="_ftp_${1}_runlevel"
    FT_RET=${!_v:-unfocused}
}
# The rung a control returns to when you leave its insides but keep standing on it. Not
# `unfocused` — you are still there, and the border must keep saying so.
_ft_runlevel_resting() {        # name → FT_RET
    [[ "${FT_FOCUS:-}" == "$1" ]] && FT_RET=poised || FT_RET=unfocused
}
# 0 (true) when the control has been stepped INTO — the test a draw uses to decide whether
# its cursor/row highlight is live or should be shown faded (or not at all).
ft_runlevel_engaged() {         # name
    local _v="_ftp_${1}_runlevel" _r
    _r=${!_v-}
    case "$_r" in ''|unfocused|poised) return 1 ;; *) return 0 ;; esac
}
# WHICH RUNG IS DEEPER — the question, asked without answering it by moving. The legend has to
# know whether Enter has anywhere to go in order to say what Enter does, and a legend that
# stepped the control into the next rung just to draw itself would be a paint with a side
# effect. Split out of ft_runlevel_deeper for that reason; the mover below is its one other
# caller.
# → FT_RET = the next rung, or "" when there is none (no ladder, or standing on the last one).
ft_runlevel_next_rung() {       # name → FT_RET
    local n=$1 type=${FT_TYPE[$n]:-}
    FT_RET=""
    [[ -n "$type" ]] || return 1
    _ft_runlevels_of "$n"; local rungs=$FT_RET
    [[ -n "$rungs" ]] || { FT_RET=""; return 1; }     # no ladder: Enter is the action
    ft_runlevel "$n"; local cur=$FT_RET next=""
    if declare -F "${type}_runlevel_next" >/dev/null 2>&1; then
        "${type}_runlevel_next" "$n" "$cur"; next=$FT_RET      # the prototype picks the branch
    else
        local seen=0 r                                          # …otherwise the next one along
        for r in $rungs; do
            (( seen )) && { next=$r; break; }
            [[ "$r" == "$cur" ]] && seen=1
        done
    fi
    [[ -n "$next" && "$next" != "$cur" ]] || { FT_RET=""; return 1; }
    FT_RET=$next
}
# One rung deeper. Returns 1 — WITHOUT moving — when there is nowhere deeper to go, which
# is how the shared Enter handler knows to run the control's own action instead.
ft_runlevel_deeper() {          # name
    ft_runlevel_next_rung "$1" || return 1
    _ft_setprop "$1" runlevel "$FT_RET"
}
# _ft_runlevel_first_rung NAME → FT_RET: the first rung past the two free ones — the
# scrolling/browsing rung every ladder starts with — or "" (and 1) when the control has none.
_ft_runlevel_first_rung() {     # name → FT_RET
    _ft_runlevels_of "$1"; local rungs=" $FT_RET "
    FT_RET=""
    [[ "$rungs" == *" poised "* ]] || return 1
    FT_RET=${rungs#*" poised "}; FT_RET=${FT_RET%% *}
    [[ -n "$FT_RET" ]]
}
# A DIRECT GRAB ON A CONTROL'S OWN SCROLLBAR STEPS INTO IT. Enter is how the KEYBOARD asks to
# be inside a control, because the keyboard has no other way to say which control it means; a
# press on the thumb already said, and said what for. It used to scroll the view and leave the
# control `poised`, so the drag worked and the very next arrow key — not yet the control's —
# walked focus off to a neighbour. The grab now lands on the first rung, where the arrows go on
# scrolling what was just dragged: the same rung the wheel resolves against, without the wheel's
# restraint, because the wheel only points and a grab takes hold.
#
# Never DOWN: a field already editing or perusing keeps its caret; grabbing its bar is scrolling
# inside a control you are already in.
_ft_runlevel_grab() {           # name — a press has landed on NAME's own scrollbar
    local n=$1 rung
    ft_runlevel_engaged "$n" && return 0
    _ft_runlevel_first_rung "$n" || return 0
    rung=$FT_RET
    # The free rungs are the focus machinery's (see below), so focus comes first and `poised`
    # with it; a control that refuses focus (disabled, hidden) is not stepped into either.
    if [[ "${FT_FOCUS:-}" != "$n" ]]; then ft_focus "$n" || return 0; fi
    _ft_setprop "$n" runlevel "$rung"
    ft_dirty "$n"; _ft_legend_dirty
}
ft_runlevel_out() {             # name — Esc: out of the insides, in one press, from any rung
    local n=$1
    ft_runlevel_engaged "$n" || return 1        # already outside — decline, let Esc bubble
    _ft_runlevel_resting "$n"
    _ft_setprop "$n" runlevel "$FT_RET"         # back to `poised`: you are still standing here
}
# The two free rungs are the FOCUS MACHINERY's to set — see _ft_focus_gain / _ft_focus_blur.
# A prototype never writes them, which is what stops `runlevel` and `FT_FOCUS` disagreeing.
_ft_runlevel_focus_gained() {   # name
    local n=$1 type=${FT_TYPE[$n]:-}
    [[ -n "$type" ]] || return 0
    _ft_runlevels_of "$n"
    case " $FT_RET " in *" poised "*) : ;; *) return 0 ;; esac
    ft_runlevel_engaged "$n" && return 0        # a prototype may have deepened it already
    _ft_setprop "$n" runlevel poised
}
# The shared ENTER: delve if there is anywhere to delve to, otherwise DO the thing. That
# single rule covers every control — a button has no rungs so Enter activates it outright,
# a tree steps in and only then does Enter open a node.
#
# …AND AT THE BOTTOM OF A LADDER, ENTER LEAVES. `ft_runlevel_deeper` answers 1 for two
# different worlds — a button with no rungs at all, and a slider standing on the last rung of
# its ladder — and only the first one wants `ft_activate`. Conflated, Enter at the deepest rung
# was CLAIMED and did nothing: slider at `adjusting`, label at `scrolling`, table and tabs at
# `browsing` all sat there however many times you pressed it, and the key did not bubble to the
# form either. Reported as "hitting enter on sliders after entering them doesn't exit them".
#
# It leaves the way Esc does — all the way out, to `poised` — because the ladder's whole point
# is that leaving is one press and you never count. One rung up is not the alternative: it is
# a bug that already shipped, and a read-only field ping-ponged `scrolling`↔`perusing` forever
# on exactly that rule.
#
# A prototype whose deepest rung has a REAL deeper meaning for Enter binds ENTER in that rung's own
# keymap — a tree expands the branch, a multi-line field takes a newline — and therefore never
# reaches here at all. "Nothing deeper for Enter to do" and "ENTER is unbound at this rung" are
# the same fact in this design, and the layer cascade has already computed it by the time we
# arrive. That is why this is the right layer for the rule rather than four prototype hooks.
#
# The `activate` listener still wins, and deliberately: the bottom rung is the only place a
# laddered control's onActivate is reachable from the keyboard, so dropping it would be an
# unannounced API break. It is also the rule ft_textfield_enter already documents and follows,
# in the one prototype the author reports as behaving correctly.
ft_key_delve() {                # name token
    local n=$1
    ft_runlevel_deeper "$n" && { ft_dirty "$n"; _ft_legend_dirty; return 0; }
    if ft_runlevel_engaged "$n" && ! ft_has_listener "$n" activate; then
        ft_key_undelve "$n" "${2:-}"; return 0
    fi
    declare -F ft_activate >/dev/null 2>&1 && ft_activate "$n"
    return 0
}
# The shared ESC. Declines (bubbles) when already outside, so Esc keeps reaching whatever
# the app put on it once you are not inside anything.
ft_key_undelve() {              # name token
    local n=$1
    if ft_runlevel_out "$n"; then ft_dirty "$n"; _ft_legend_dirty; return 0; fi
    FT_KEY_BUBBLE=1; return 1
}

# _ft_runlevel_active_sgr NAME FALLBACK → FT_RET — the colours for "the item the keyboard
# is on" (a tree's cursor row, a table's row, a tab). FADED while the control has only been
# focused rather than stepped into: the cursor is real, but it is not yours to drive yet,
# and drawing it at full strength says otherwise. Stepping in with Enter lights it up, which
# is how the ladder teaches itself without a word of documentation.
#
# Declaring a ladder registers CSS states, so a theme spells the two apart exactly:
#     tree::active          { … }     the row you are driving
#     tree:unfocused::active { … }     the row you are merely next to
# This is only what it looks like when the theme has not said.
_ft_runlevel_active_sgr() {     # name fallback
    local name=$1
    _ft_css_pe_or "$name" active "$2"
    # HOLD THE COLOUR BEFORE ASKING THE NEXT QUESTION, because the next question answers in
    # the same register. FT_RET is this framework's one return channel, so _ft_runlevels_of's
    # answer lands exactly on top of the SGR just computed — and the two early returns below
    # used to hand that ladder string to the caller. ft-tree and ft-table paste what they get
    # straight into the row (`ft_print_at … "$sgr$FT_FIT…"`), so a delved-into tree painted the
    # literal words "unfocused poised browsing" over its own cursor row. An early return that
    # leaves a stale FT_RET is a bug family this project has already named; this was one.
    local sgr=$FT_RET
    _ft_runlevels_of "$name"
    [[ -n "$FT_RET" ]] || { FT_RET=$sgr; return 0; }            # no ladder → nothing to be outside of
    ft_runlevel_engaged "$name" && { FT_RET=$sgr; return 0; }   # stepped in → full strength
    # Merely focused: faded, and fall back to the computed colour when the theme has no fade
    # slot — the old form left FT_RET holding the ladder in exactly that case.
    FT_RET=${FT_COLOR_FADED:-$sgr}
    return 0
}

ft_resolve() {                  # name prop → sets FT_RET ("" if unset and not inherited)
    case $2 in text|value) [[ "${_FT_TEXT_STALE[$1]:-}" == "$2" ]] && _ft_text_join "$1" ;; esac
    local prop=$2 inherits=0
    # Decide inheritance from the AUTHORED name, then translate to the storage key. (Inlined
    # rather than calling _ft_propkey: this is layout's innermost operation, and a function
    # call is ~2.6µs against the ~9µs the whole lookup should cost.)
    case $prop in
        --*)   inherits=1                                   # custom properties always inherit
               prop="cssvar__${prop#--}"; prop=${prop//[^a-zA-Z0-9_]/_} ;;
        *'['*) prop=${prop//'['/__}; prop=${prop//']'/} ;;   # subscripted: text[event]
        *)     [[ -n "${FT_INHERITED_PROP[$prop]:-}" ]] && inherits=1 ;;
    esac
    local var="_ftp_${1}_${prop}"
    [[ -v "$var" ]] && { FT_RET="${!var}"; return; }
    # ── THE LAYOUT ASKS THE CASCADE, BUT ONLY WHEN THERE IS SOMETHING TO ASK ────────────────
    # The layout has never consulted a stylesheet. It resolves through here and through the raw
    # fast paths; ft_style is the PAINT path. Proven on a property no prototype defaults, so the
    # level-5 fix cannot be the cause: with `#fr { width: 30; height: 7 }` registered, ft_style
    # answered 30 and 7, ft_resolved_prop answered nothing, and the frame laid out 90x3.
    # `ft_resolved_prop` appears 49 times in this file against `ft_style`'s 9.
    #
    # Routing every read through the cascade would put a query on the hottest path in the
    # framework. The gate is `_FT_CSS_DECLARED_PROPS`, accumulated by the stylesheet parser: it
    # knows whether ANY registered sheet declares a given property. (Not _FT_CSS_STYLE_PROPS,
    # which sounds like the same thing and is a fixed set of fifteen paint properties.) An app
    # with no layout rules pays one assoc read on a miss and nothing else; an app that writes
    # `#fr { padding: 2 }` pays a memoised ft_style for `padding` alone. It is also why this is
    # safe with ft-css unloaded: the array does not exist, the expansion is empty, the gate is
    # shut.
    #
    # `cursor` IS EXCLUDED BY NAME, and it is the one exclusion. It is CSS's inherited `cursor`
    # to a stylesheet and a ROW INDEX to a select, a table and a tree, so a sheet saying
    # `cursor: pointer` would feed a word into arithmetic. That is a name collision, not a
    # category — the other state-ish defaults (selectedIndex, open, scroll, expanded, activeTab)
    # share no name with any CSS property, so the gate never opens for them. A SECOND collision
    # appearing is the signal to split style from state properly rather than to extend this line.
    #
    # _FT_RESOLVING_CASCADE stops re-entry: selector matching asks controls about properties,
    # and a state predicate that resolves through here would otherwise come back round.
    if [[ -z "${_FT_RESOLVING_CASCADE:-}" && "$prop" != cursor ]] \
       && [[ -n "${_FT_CSS_DECLARED_PROPS[$prop]:-}" && -n "${_FT_CSS_LOADED:-}" ]]; then
        # THE APP-STYLESHEET LEVEL ONLY, and not `ft_style`. The missing level here is 2; 3, 4
        # and 5 are the inheritance walk and the prototype default immediately below, and asking
        # ft_style for all of them would ALSO import level 4 — the theme — which is precisely
        # what `_ft_color_override` refuses to do for a non-inheriting property. Measured: with
        # ft_style here, a control with no background of its own answered the theme's
        # `48;5;39`, and "an unset background must stay a HOLE showing whatever is behind it"
        # is a rule this framework paid for once already (tests/test-inheritpaint.bash).
        local _FT_RESOLVING_CASCADE=1
        _ft_css_query "$1" "$prop" app
        if (( _QGOT )); then _ft_css_resolve_value "$1" "$FT_RET"; return; fi
    fi
    # Nothing the author set, and nothing any sheet says. ONE assoc read answers both remaining
    # questions — whether this element's own prototype declares the property (which stops
    # inheritance) and what it declares — and it REUSES `var` rather than declaring a second
    # local. A `local` is not free in bash and this is the framework's most-called function:
    # the extra declaration alone measured ~14ms on a 37-control layout.
    var=${FT_PROTO_DEFAULT["${FT_TYPE[$1]:-} $prop"]-}
    # Only an inheriting property may look further up, and only while its own prototype is silent.
    # Skipping that walk for everything else is most of what layout was spending its time on
    # (a miss cost ~72µs of ancestor probing against ~9µs for the local read).
    if (( inherits )) && (( ${#var} == 0 )); then
        local ancestor=${FT_PARENT[$1]:-} probe
        while [[ -n "$ancestor" ]]; do
            probe="_ftp_${ancestor}_${prop}"
            [[ -v "$probe" ]] && { FT_RET="${!probe}"; return; }
            # …and an ancestor's own prototype default inherits too: it is that element's computed
            # value, which is what inheritance passes down.
            probe=${FT_PROTO_DEFAULT["${FT_TYPE[$ancestor]:-} $prop"]-}
            (( ${#probe} )) && { FT_RET=$probe; return; }
            ancestor=${FT_PARENT[$ancestor]:-}
        done
    fi
    FT_RET=$var
}

# ── Layout-vs-paint classification (engine-owned, per PROPERTY) ──────────────
# One table, like a browser. Paint-only properties repaint the one control;
# layout properties reflow. Unknown properties default to layout (safe: a
# needless reflow is correct; a skipped one is not). Prototypes may classify
# their own custom properties via ft_prop_kind_set in their prototype-constructor.
declare -A FT_PROP_KIND=()
_ft_pk() { local k=$1; shift; local p; for p in "$@"; do FT_PROP_KIND[$p]=$k; done; }
_ft_pk layout display width height minWidth maxWidth minHeight maxHeight \
       padding paddingTop paddingRight paddingBottom paddingLeft \
       margin border borderStyle borderWidth boxSizing flexDirection gap justifyContent \
       glyph \
       alignItems alignSelf flexGrow flexShrink flexBasis position left top \
       size accessKey overflow overflowX \
       text states class
# THE LAST FOUR ARE INPUTS TO A MEASUREMENT, and were classified paint. Each was demonstrated,
# by writing it through ft_set and watching the box not move:
#
#   size       12 → 12   it IS the textfield's intrinsic width (_ft_preferred_width_textfield)
#                        and the select's height (_ft_height_select)
#   accessKey   6 →  6   _ft_preferred_width_button/_radio/_multitoggle append " (X)" when the
#                        accelerator letter is not already in the label, so the control has to
#                        widen to hold its own accelerator
#   overflow    reserves a gutter column in _ft_inset4 — the content box gets SMALLER and the
#   overflowX   children never reflowed into what was left
#
# `overflowY` stays paint deliberately and that is not an oversight: _ft_inset4 reserves from the
# shorthand and overflowX only, and _ft_height_label never reaches _ft_overflow_mode — the axis
# property is read on the DRAW path (_ft_label_metrics), which changes no box.
# `glyph` is layout-kind because a glyph is not always one column: a checkbox's `[ ]` is three
# and `☐` is one, and the glyph is drawn INSIDE the control's own text — so swapping the pair
# changes how wide the control wants to be. It was paint-only, which is why the width did not
# follow when it changed.
# `class` is layout-kind (conservative: a class rule can change layout props, e.g. .hidden{display:none})
# AND registering it lets the DSL accept a multi-class value with spaces — `ft_set x class="a b"`.
_ft_pk paint color backgroundColor borderColor overflowY \
       scrollTop scrollLeft scrollHeight scrollWidth clientHeight clientWidth \
       selectedIndex group keymap draw focusable name parent for \
       borderRadius borderGlyph \
       value disabled defaultKeys type min max step style multiple open visibility \
       autofocus wrapIndicator textAlign \
       animation animationDuration animationTimingFunction animationDelay \
       eventListeners variant importance
# `animation` is registered here so the DSL treats a spaced value like `animation="glow 2s"` as ONE
# property value, not content — for EVERY control, not because an app hand-registered it. It is
# paint-only: it changes how a control draws, never its box.
# borderRadius is paint-only because a TUI border is always exactly one cell — it only ever
# chooses between square and arc corners (the deliberate character-cell deviation, documented).
# borderStyle and borderWidth are LAYOUT-kind, and for the one reason that survives that
# deviation: `border-style: none|hidden` and `border-width: 0` are CSS's own spellings of "no
# border", where the used border-width is 0 and the box gets SMALLER. Every other spelling of
# either only picks glyphs — but a property is classified by the strongest thing it can do, and
# "a needless reflow is correct; a skipped one is not" is what this table is for. (ft-table used
# to register borderStyle for itself; it is the whole framework's answer now, so the
# per-prototype line went with the reason for it.)
unset -f _ft_pk
# An EMPTY property name has no kind and cannot be registered — and asking anyway subscripts
# FT_PROP_KIND with "", which is a bash error on stderr (the alt screen, in a TUI).
ft_prop_kind()     { [[ -z "$1" ]] && { FT_RET=layout; return 0; }
                     _ft_propkey "$1"; FT_RET=${FT_PROP_KIND[$FT_RET]:-layout}; }
# A KIND MAY ONLY EVER BE STRENGTHENED, and that is not a stylistic preference — it is what makes
# this table say the same thing whatever order an app builds its widgets in.
#
# There is ONE table, many prototypes write to it, and a prototype constructor runs LAZILY, at the
# first instance of its type. So a second prototype classifying a name the first has already
# classified is not adjusting its own control: it is re-classifying that name for the whole
# framework, and the winner is decided by which widget the app happened to build first. Measured on
# this tree, each of these flipped a name that another prototype had deliberately called layout:
#
#     ft-beacon     text         layout → paint
#     ft-tab        title        layout → paint
#     ft-scrollbar  orientation  layout → paint
#
# The first is the one that mattered. `text` is the property every label, button, radio and
# multitoggle has, and building ONE callout anywhere in the app made every label in it stop
# re-measuring when its text changed:
#
#     no beacon                 text-kind=layout   label width 5 → 40   (correct)
#     a beacon was built first  text-kind=paint    label width 5 → 5    (string clipped)
#
# Refusing the downgrade settles every contested name on `layout` whichever prototype is
# instantiated first, which is the direction this table's own rule already points: a needless reflow
# is correct, a skipped one is not. Silently, because a prototype asking for `paint` on a name
# someone else needs reflowed is not an authoring error to shout about — it is a difference of
# opinion, and the conservative opinion wins by construction rather than by everyone remembering.
ft_prop_kind_set() { [[ -z "$1" ]] && return 1
                     # TWO KINDS, AND A THIRD IS A TYPO. `ft_prop_kind_set showLineNumbers layout#
                     # comment` — no space before the `#` — stored the kind "layout#", which every
                     # reader tests `== layout` against and so read as paint: toggling line numbers
                     # widened the box's preferred size and nothing reflowed it. Refused loudly now.
                     case $2 in paint|layout) : ;;
                         *) printf 'ft: ft_prop_kind_set %s: kind must be paint or layout, got "%s"\n' "$1" "$2" >&2
                            return 1 ;; esac
                     _ft_propkey "$1"
                     [[ "$2" == paint && "${FT_PROP_KIND[$FT_RET]:-}" == layout ]] && return 0
                     FT_PROP_KIND[$FT_RET]=$2; }

# ── Shared arg parser: properties, content, and key fields ──────────────────
# keymap=NAME is a property: a SHARED keymap attached by reference (a space-separated LIST,
# last wins), consulted by dispatch between the instance overlay and the prototype default.
# A control's OWN keys are written as key fields — `key=ENTER onKey='…'` — which the loop
# below collects and folds into its instance overlay. They replace a bare `keymap` token
# that opened a section of PATTERN=ACTION arguments, a second grammar for the same thing.
#
# A bare argument is the element's CONTENT, like text between HTML tags: it
# sets the prototype's content property (text for most prototypes, title for frames —
# FT_PROTO_TEXTPROP):   ft-label name=hello "Hello, terminal!"
#
# An argument is a PROPERTY assignment when it starts with `IDENT=` and either
#   (a) IDENT is a KNOWN property (in FT_PROP_KIND — every built-in prop is, and
#       a prototype registers its own custom props in its constructor, which runs
#       before any arg is parsed), OR
#   (b) the value is a single word (no embedded whitespace) — the normal shape
#       of a positional value, so unregistered custom props like `scale=5` still
#       just work.
# Everything else is CONTENT. This closes the real ambiguity: a value passed
# positionally is one shell word, so free text with spaces —
#     ft_set status "compression=high beep=on"
# — is NOT a property named `compression`; it has spaces and `compression` is no
# property, so the whole phrase is text. When you want a SINGLE-word =-bearing
# string as content (the one residual ambiguity), be explicit with text=:
#     ft_set status text="compression=high"   ← text= wins, value keeps its =
# ── Accelerator label rendering (shared by button/radio/checkbox) ────────────
# An accelerator letter is shown by underlining it in the label. When the letter
# is NOT present in the label (nothing to underline), it is appended in
# parentheses instead — "Save (S)" — so the shortcut is always visible.
#   _ft_accel_text  TEXT ACCEL        → FT_RET = plain effective label (for width)
#   _ft_accel_markup TEXT ACCEL SGR   → FT_RET = SGR-marked label (for drawing),
#                                       where SGR is the run's base colour to
#                                       restore after the underlined letter.
_ft_accel_text() {              # text accessKey → FT_RET
    local text=$1 accessKey=$2
    FT_RET=$text
    [[ -z "$accessKey" || "${text^^}" == *"${accessKey^^}"* ]] && return
    FT_RET="$text (${accessKey^^})"
}
_ft_accel_markup() {            # text accessKey sgr → FT_RET
    local text=$1 accessKey=$2 sgr=$3 out="" ch found=0 j
    if [[ -z "$accessKey" ]]; then FT_RET=$text; return; fi
    if [[ "${text^^}" == *"${accessKey^^}"* ]]; then
        for (( j=0; j<${#text}; j++ )); do
            ch="${text:j:1}"
            if (( ! found )) && [[ "${ch^^}" == "${accessKey^^}" ]]; then
                out+="$FT_ANSI_UNDERLINE$ch$sgr$FT_ANSI_UNDERLINE_OFF"; found=1
            else out+="$ch"; fi
        done
        FT_RET=$out
    else
        FT_RET="$text ($FT_ANSI_UNDERLINE${accessKey^^}$sgr$FT_ANSI_UNDERLINE_OFF)"   # not in label → parenthesise
    fi
}

# A LABEL IS SET BY A PROPERTY, NOT BY POSITION.
#
# `ft-label name=hi "Hello"` used to work, mirroring text between HTML tags, and it is gone: the
# author's verdict on reading it back was that raw label text does not belong loose in an
# argument list. `text="Hello"` — a frame's is `title=` — names the property being set and reads
# like every other attribute on the line.
#
# REFUSED, not ignored: the failure mode of ignoring it is a control that draws nothing and says
# nothing about why. The message names the property to write instead — and it is what found the
# calls a static sweep kept missing, which were never the ones a person would think of: a loop
# body after `do`, a fixture after a `case` label, a one-line function body behind its `{`.
#
# Two positional forms survive and were never content: ft-table-row / ft-table-column take a
# row's CELLS, and ft_end takes the type it expects to close.
_FT_TEXTPROP=text
_ft_bare_content() {            # name arg
    local _ty=${FT_TYPE[$1]:-} prop=$_FT_TEXTPROP
    [[ -n "$_ty" ]] && prop=${FT_PROTO_TEXTPROP[$_ty]:-text}
    printf 'ft: %s: "%s" is not a property — write %s="%s"\n' "$1" "$2" "$prop" "$2" >&2
    return 1
}
_ft_is_assignment() {           # 0 iff "$1" is a property assignment, not content
    [[ "$1" =~ ^(--[A-Za-z][A-Za-z0-9-]*|[A-Za-z_][A-Za-z0-9_]*(\[[A-Za-z0-9_]+\])?)= ]] || return 1
    local k=${1%%=*}
    [[ "$k" == --* ]] && return 0                     # a custom property (--x): unambiguous, value may hold spaces
    _ft_propkey "$k"
    [[ -v "FT_PROP_KIND[$FT_RET]" ]] && return 0     # a real property: value may hold spaces
    [[ "$1" != *[[:space:]]* ]]                       # else only a bare word=word token is a prop
}
_ft_apply_args() {              # name args...
    local name=$1; shift
    local arg key val
    local -a _kf=()
    for arg in "$@"; do
        # KEY FIELDS are not properties — a control binds many keys and the property store
        # holds one value per name — so they are collected here and folded into this
        # control's own keymap (its instance overlay) once the arguments are read.
        case $arg in key=*|keyCap=*|keyImp=*|onKey=*) _kf+=("$arg"); continue ;; esac
        if _ft_is_assignment "$arg"; then
            _ft_setprop "$name" "${arg%%=*}" "${arg#*=}"
        else
            _ft_bare_content "$name" "$arg"
        fi
    done
    (( ${#_kf[@]} )) && { _ft_keymap_of "$name"; _ft_keyfields "$FT_RET" "${_kf[@]}"; }

}

# ── Prototype system ─────────────────────────────────────────────────────────
declare -A FT_PROTO_READY=() FT_PROTO_DRAW=() FT_PROTO_PREFERRED_WIDTH=() FT_PROTO_HEIGHT=() \
    FT_PROTO_KEYWORD_PROPS=() FT_PROTO_TEXT_PROPS=() \
           FT_PROTO_FOCUSABLE=() FT_PROTO_KEYMAP=() FT_PROTO_DEFAULTS=() FT_PROTO_FOCUS_SKIP=() \
           FT_PROTO_TEXTPROP=() FT_PROTO_TOP_EDGE_PROP=() \
           FT_PROTO_MOUSE=() FT_PROTO_NOHIT=() FT_PROTO_BORDER_SGR=() \
           FT_PROTO_REPROP=()
# FT_PROTO_REPROP[type]=fn — SOME PROPERTIES NEED THE PROTOTYPE TO DO SOMETHING, not just repaint.
# A beacon's `effect` decides whether it runs an animation loop at all, so changing it has to
# re-arm; ft_set cannot know that and must not learn it. The prototype registers a function and
# ft_set calls it with the control and the keys that actually changed:
#     FT_PROTO_REPROP[beacon]=_ft_beacon_reprop     # fn NAME "effect lifetime …"
# Same shape as _ft_destroy_<type> and _ft_ink_<type>: the engine asks, the prototype answers.
# demo/callout-demo.bash used to call _ft_beacon_arm itself after every effect change.
# Cost: one array read per ft_set for a prototype that registers nothing, which is all but one.

# The prototype struct, as the AUTHORING key each entry is written with. This table is the only
# place the two vocabularies meet: a control author writes `preferredWidth=`, the engine reads
# FT_PROTO_PREFERRED_WIDTH. Adding a slot to the struct means adding one row here — and a key that
# is not in this table is a hard error, which is the point: `FT_PROTO_FOCUSSABLE[$c]=1` used to
# create a brand-new associative array that nothing would ever read, silently, forever.
declare -A FT_PROTO_STRUCT=(
    [draw]=FT_PROTO_DRAW                 # draw fn ("" = an undrawn container)
    [preferredWidth]=FT_PROTO_PREFERRED_WIDTH      # intrinsic max-content width fn (leaf prototypes)
    [height]=FT_PROTO_HEIGHT             # intrinsic height-at-width fn   (leaf prototypes)
    [focusable]=FT_PROTO_FOCUSABLE       # true/false — can this prototype hold keyboard focus
    [focusSkip]=FT_PROTO_FOCUS_SKIP      # fn NAME → 0 to skip THIS instance (a label that fits)
    [keymap]=FT_PROTO_KEYMAP             # prototype-default keymap name ("" = none)
    [mouse]=FT_PROTO_MOUSE               # fn NAME ACTION RELX RELY
    [wheelProbe]=FT_PROTO_WHEEL_PROBE    # fn NAME → 0 iff it has something to scroll
    [textProp]=FT_PROTO_TEXTPROP         # which property bare DSL content lands in
    [topEdgeProp]=FT_PROTO_TOP_EDGE_PROP # a property drawn on the box's TOP EDGE, not inside it
                                         # (a frame's title, over its top border). The box
                                         # RESERVES that row while the property is non-empty,
                                         # whether or not a border supplies it — the way a
                                         # <fieldset> keeps room for its <legend> under
                                         # `border: none`. See _ft_inset4.
    [noHit]=FT_PROTO_NOHIT               # true = pointer-events:none (transparent to clicks)
    [setProp]=FT_PROTO_SETPROP           # fn NAME PROP VALUE — reconcile a late property write
    [fillsBackground]=FT_PROTO_FILLS_BACKGROUND  # true = its draw paints its WHOLE box (see below)
    [borderSgr]=FT_PROTO_BORDER_SGR      # fn NAME → the SGR this prototype's border wears
    [defaults]=FT_PROTO_DEFAULTS         # property defaults applied before user args (APPENDS)
    [keywordProps]=FT_PROTO_KEYWORD_PROPS   # numeric-named props THIS prototype reads as keywords
    [textProps]=FT_PROTO_TEXT_PROPS      # which props can change this prototype's DISPLAYED TEXT.
                                         # UNSET means "any of them" — the conservative answer,
                                         # and the one every prototype had before this existed. See
                                         # the two generation counters in _ft_setprop.
)
# Booleans are written as true/false and stored as 1/0.
#
# 1/0 and not 1/"" because a tri-state (true / false / never-declared) is a bug farm: every
# reader has to decide what "" means, and `[[ -n "$v" ]]` — the obvious spelling — is TRUE for
# "0". That is precisely how a deliberately inert control came to claim mouse clicks (see
# _ft_mouse_target). So a boolean is always present, always 1 or 0, and always tested as a
# NUMBER. If you find yourself writing `-n` on one of these, it is wrong.
declare -A _FT_PROTO_BOOLEAN_KEY=( [focusable]=1 [noHit]=1 [fillsBackground]=1 )

# …AND THE SAME RULE FOR AN INSTANCE. The paragraph above is the framework's boolean contract,
# but it was enforced only where a PROTOTYPE declares one. An instance property went into
# FT_FOCUSABLE raw, and every reader tests `== 1` — so `ft-label … focusable=true`, the
# spelling every other boolean here uses (disabled=true, readOnly=true) and the spelling the
# prototype declarations use for this very key, stored the string "true" and made the control
# UNFOCUSABLE. Silently, because `false` and a typo fail `== 1` as well: the one wrong answer
# that mattered looked like it worked.
#
# One function, because there are two routes into this table — construction and a runtime
# ft_set — and a rule enforced on one route and not its sibling is this codebase's most
# frequently logged root cause. The runtime route did not enforce it at all: it wrote the
# property and never touched the table, so `ft_set x focusable=false` was inert.
_ft_focusable_apply() {         # name type rawValue
    local name=$1 type=$2 raw=$3
    case "$raw" in
        '')      FT_FOCUSABLE[$name]=${FT_PROTO_FOCUSABLE[$type]:-0} ;;
        1|true)  FT_FOCUSABLE[$name]=1 ;;
        0|false) FT_FOCUSABLE[$name]=0 ;;
        *) printf 'ft: %s: focusable must be true or false, got "%s"\n' "$name" "$raw" >&2
           FT_FOCUSABLE[$name]=${FT_PROTO_FOCUSABLE[$type]:-0} ;;
    esac
    return 0
}

# The prototype currently being built. Threading this target by hand through the constructor chain
# was the sharpest edge in the old API: a derived prototype's constructor runs its BASE
# prototype's constructor to fill its OWN struct (label's constructor builds button's struct), so
# every call carried a `$c` that, passed wrong, silently filled a different prototype. It is now
# implicit and unspellable. ft_prototype_init makes it a `local`, so bash's own dynamic scoping both
# publishes it to the whole chain below and restores it on the way out — reentrancy included.
FT_PROTO_UNDER_CONSTRUCTION=""
_FT_PROTO_STRUCT_WRITTEN=0      # has any struct key been set for it yet (guards late extends=)
# Whether ft_prototype REJECTED anything while building it. A flag and not the constructor's exit
# status, because that status is whatever the author's last statement happened to return — a
# trailing `(( count++ ))` returns 1 on its first run and would fail an entirely valid prototype,
# while a trailing `|| true` would swallow a real rejection. The flag can do neither.
_FT_PROTO_DECLARATION_FAILED=0

# ft_prototype KEY=VALUE… — declare the prototype under construction. Order-independent:
#   · `extends=BASE` runs BASE's constructor FIRST wherever it appears in the argument list,
#     so "inherit, then override" is the only order that can happen.
#   · `defaults=` APPENDS to what was inherited (a derived prototype adds to its base's
#     defaults); every other key REPLACES.
#   · an unknown key, an unknown base prototype, or a non-boolean boolean is a hard error.
# Struct slots are cleared by ft_prototype_init before the chain runs, so a prototype never
# inherits a stale entry and `defaults=` can always append.
ft_prototype() {                    # key=value…
    local c=$FT_PROTO_UNDER_CONSTRUCTION
    if [[ -z "$c" ]]; then
        printf 'ft_prototype: no prototype under construction (call it from ft_prototype_<type>)\n' >&2
        _FT_PROTO_DECLARATION_FAILED=1; return 2
    fi
    local arg key val array
    # extends first, whatever the argument order
    for arg in "$@"; do
        [[ "$arg" == extends=* ]] || continue
        val=${arg#*=}
        if ! declare -F "ft_prototype_$val" >/dev/null 2>&1; then
            printf 'ft_prototype: %s extends unknown prototype "%s"\n' "$c" "$val" >&2
            _FT_PROTO_DECLARATION_FAILED=1; return 2
        fi
        # A constructor may call ft_prototype more than once, but `extends=` runs the BASE
        # PROTOTYPE's constructor — which writes the same struct. Arriving after a key has
        # already been set, it would silently overwrite it with the base's value (the derived
        # prototype would quietly become unfocusable again). Loud, because the symptom is far
        # from the cause.
        if (( _FT_PROTO_STRUCT_WRITTEN )); then
            printf 'ft_prototype: %s: extends=%s must come before any other key is set\n' \
                   "$c" "$val" >&2
            _FT_PROTO_DECLARATION_FAILED=1; return 2
        fi
        # A CYCLE IN extends= IS A SEGFAULT, NOT AN ERROR. This calls the base prototype's
        # constructor DIRECTLY — it never goes back through ft_prototype_init — so that function's
        # re-entrancy guard cannot see it. `ft_prototype_x() { ft_prototype extends=x; }` recurses
        # until bash's stack blows; so does a ring, x→y→x. _FT_PROTO_CHAIN is a `local` of
        # ft_prototype_init, so appending here is visible to every nested constructor and unwinds
        # by itself when the initialisation returns.
        case " ${_FT_PROTO_CHAIN:-} " in
            *" $val "*)
                printf 'ft_prototype: %s: extends= cycle — "%s" is already in this chain (%s)\n' \
                       "$c" "$val" "${_FT_PROTO_CHAIN// / → }" >&2
                _FT_PROTO_DECLARATION_FAILED=1; return 2 ;;
        esac
        _FT_PROTO_CHAIN="${_FT_PROTO_CHAIN:-} $val"
        "ft_prototype_$val" "$c"   # $c is vestigial — old-style constructors still read it as $1
    done
    # This prototype's own conventional functions land BEFORE its explicit keys, so an explicit
    # one always wins. The declaring prototype is read off the call stack rather than asked for:
    # ft_prototype is only ever called from ft_prototype_<type>, and making the author repeat the
    # name is precisely the ceremony this is removing.
    local declaring=${FUNCNAME[1]:-}
    [[ "$declaring" == ft_prototype_* ]] && _ft_prototype_bind_by_convention "${declaring#ft_prototype_}" "$c"
    for arg in "$@"; do
        if [[ "$arg" != *=* ]]; then
            printf 'ft_prototype: %s: "%s" is not KEY=VALUE\n' "$c" "$arg" >&2
            _FT_PROTO_DECLARATION_FAILED=1; return 2
        fi
        key=${arg%%=*}; val=${arg#*=}
        [[ "$key" == extends ]] && continue          # already handled above
        array=${FT_PROTO_STRUCT[$key]:-}
        if [[ -z "$array" ]]; then
            printf 'ft_prototype: %s: unknown key "%s" (known: %s)\n' \
                   "$c" "$key" "${!FT_PROTO_STRUCT[*]}" >&2
            _FT_PROTO_DECLARATION_FAILED=1; return 2
        fi
        if [[ -n "${_FT_PROTO_BOOLEAN_KEY[$key]:-}" ]]; then
            case "$val" in
                true)  val=1 ;;
                false) val=0 ;;
                *) printf 'ft_prototype: %s: %s must be true or false, got "%s"\n' \
                          "$c" "$key" "$val" >&2; _FT_PROTO_DECLARATION_FAILED=1; return 2 ;;
            esac
        fi
        if [[ "$key" == defaults ]]; then
            printf -v "${array}[$c]" '%s' "${FT_PROTO_DEFAULTS[$c]:-}${val:+ $val}"
        else
            _ft_prototype_resolve_value "$key" "$val" || { _FT_PROTO_DECLARATION_FAILED=1; return 2; }
            printf -v "${array}[$c]" '%s' "$FT_RET"
        fi
        _FT_PROTO_STRUCT_WRITTEN=1      # ft_prototype_init's local — see the extends= guard above
    done
}

# A function-valued key may be written SHORT. `keymap=activate` and `mouse=activate` say what
# the prototype does; `keymap=ft_keymap_activate mouse=_ft_mouse_activate` say the same thing twice
# with the prefix spelled out by hand. A value that already starts with ft_/_ft_ is taken
# verbatim, so an odd one out never has to fight the convention. `none` clears an inherited
# entry — the old spelling for that was a bare `focusSkip=`, which reads like a typo.
declare -A _FT_PROTO_SHORT_VALUE_PREFIX=(
    [keymap]=ft_keymap_          [mouse]=_ft_mouse_
    [draw]=_ft_draw_             [preferredWidth]=_ft_preferred_width_   [height]=_ft_height_
)
_ft_prototype_resolve_value() {     # key value → FT_RET
    local key=$1 val=$2 prefix=${_FT_PROTO_SHORT_VALUE_PREFIX[$1]:-}
    if [[ "$val" == none ]]; then FT_RET=""; return 0; fi
    if [[ -n "$prefix" && -n "$val" && "$val" != ft_* && "$val" != _ft_* ]]; then
        val=$prefix$val
    fi
    FT_RET=$val
    # A keymap is DECLARED here and DEFINED by `_ft_define_keymap_<name>`, run exactly once.
    # The prototype says which keymap it uses; the definer says what is in it. Before this, every
    # control opened its constructor with a hand-written once-guard, so the one line that
    # mattered — which keymap am I? — was buried under twenty binding lines.
    if [[ "$key" == keymap && -n "$val" ]]; then
        local definer=_ft_define_keymap_${val#ft_keymap_}
        if declare -F "$definer" >/dev/null 2>&1 && _ft_keymap_declare_once "$val"; then "$definer"; fi
    fi
    return 0
}

# Bind draw / preferredWidth / height from the naming convention. Every one of them is
# `_ft_<role>_<type>` — 42 of 42 across the built-in controls — so `draw=_ft_draw_button`
# inside ft_prototype_button was the type spelled a third time and the role a second, carrying
# nothing a reader could not already see.
#
# DECLARING is the prototype whose constructor is running, which is NOT the prototype being built:
# ft_prototype_label runs to fill BUTTON's struct, and what it contributes there is label's
# `_ft_draw_label`. Binding only the leaf's name would silently drop everything a base prototype
# provides by convention — button would inherit no height function at all. So each level of
# the chain binds its own, root first, and the leaf's overrides. A derived prototype with no
# function of its own (checkbox over multitoggle) finds nothing and correctly keeps what it
# inherited.
_ft_prototype_bind_by_convention() {   # declaring targetprototype
    local key fn
    for key in draw preferredWidth height; do
        fn=${_FT_PROTO_SHORT_VALUE_PREFIX[$key]}$1
        declare -F "$fn" >/dev/null 2>&1 && printf -v "${FT_PROTO_STRUCT[$key]}[$2]" '%s' "$fn"
    done
    return 0
}

# Every struct slot starts empty for a prototype about to be built, so the constructor chain only
# ever ADDS. Without this, `defaults=` could not append (it would accumulate across rebuilds)
# and a slot the chain no longer sets would keep a previous prototype's value.
_ft_prototype_struct_clear() {      # type
    local key array
    for key in "${!FT_PROTO_STRUCT[@]}"; do
        array=${FT_PROTO_STRUCT[$key]}
        # A boolean clears to 0, not "" — the guarantee readers rely on is that it is ALWAYS
        # present and always numeric, so a prototype that never mentions `noHit` still answers
        # the question. "" would put the tri-state back and invite `-n` all over again.
        printf -v "${array}[$1]" '%s' "${_FT_PROTO_BOOLEAN_KEY[$key]:+0}"
    done
}

# Root pure-virtual prototype. Every prototype-constructor chain bottoms out here.
# Defaults are CSS's real initial values wherever CSS has one (display:block,
# position:static, align-items:stretch, flex-shrink:1…).
#
# NB: paddingTop/Right/Bottom/Left MUST be defaulted here (like padding) so every control
# carries its own 0 — otherwise an unset per-side padding INHERITS from an ancestor (a tabs
# pane sets paddingTop=3), corrupting every descendant's size and position. Same for
# `runlevel=unfocused`: undefaulted, it would resolve up the parent chain and a container in
# some runlevel would drag every descendant into it.
ft_prototype_ft_control() {
    ft_prototype focusable=false textProp=text \
             defaults="display=block position=static border=false borderStyle=solid borderWidth=thin borderRadius=0 padding=0 paddingTop=0 paddingRight=0 paddingBottom=0 paddingLeft=0 margin=0 boxSizing=borderBox flexDirection=row gap=0 justifyContent=start alignItems=stretch alignSelf=auto flexGrow=0 flexShrink=1 flexBasis=auto overflow=hidden runlevel=unfocused importance=normal"
    # `importance` is here again, and its absence was a WORKAROUND for the inverted ladder rather
    # than a design. The note that stood in its place read: "A prototype default is an
    # instance-level write, which outranks every stylesheet rule exactly as inline style does — so
    # declaring importance=normal made `textfield:focus { importance: crucial }` a silent no-op."
    # That was true of every one of the other twenty-three defaults on the line above too; this
    # property was simply the one where somebody noticed. A prototype default is level 5 now, so the
    # base value lives where a reader looks for it and a state rule can still speak over it.
}

# ── Prototype defaults live HERE, not on the instance ────────────────────────
# `FT_PROTO_DEFAULT["<type> <prop>"]` is the flat form of every `defaults=` a prototype and
# its ancestors declared, built once when the prototype registers.
#
# WHAT IT REPLACED. `ft_new` used to STAMP every default onto the instance as a property, so
# "the control's last resort" and "the author typed it at the call site" were the same string
# and no reader could tell them apart. docs/styling-model.md §2 has always said a prototype default
# is cascade level FIVE; the implementation made it level ONE, inverting the ladder end to end.
# Measured on an ordinary frame with `#fr { padding: 2; gap: 3; overflow: auto; flex-direction:
# column; justify-content: center }` registered: padding 0, gap 0, overflow hidden,
# flex-direction row, justify-content start. All 79 properties that 26 prototypes default were
# unreachable from a stylesheet, on every control. `border-color` worked only because nothing
# defaults it — which is why a bigarrow's outline was stylable and its width was not.
#
# A TABLE AND NOT A REGISTERED STYLESHEET, for one decisive reason: ft-forms must work with
# ft-css unloaded. A prototype default is what a control IS — a `display: none` option, a bordered
# frame, a tab strip's three-row inset — and putting the framework's own defaults behind an
# optional dependency would mean an app that never registers a sheet gets a layout made of
# nothing. The resolver already had the slot (`_ft_style_compute`'s level 5, "supplied by
# controls in M2; nothing here yet"); this fills it. Per-PROTOTYPE storage also means the table
# is O(prototypes) rather than O(controls), and building a control got cheaper rather than dearer.
declare -A FT_PROTO_DEFAULT=()
# ── ONE READ FOR A WHOLE BOX ─────────────────────────────────────────────────────────────────
# The box readers want the same five or eight of these in a row, per control, per layout pass,
# and asking the table separately for each is what made dragging a callout stutter. MEASURED, on
# a drag frame: `_ft_inset4` cost 115µs a call against 33µs before prototype defaults moved to level
# 5, and it runs 40 times a frame — 3.3ms of a 43ms frame, the single largest piece of that
# regression. The cause was not the price of a lookup but the NUMBER of them: five keyed reads
# plus five calls plus five sheet-gate reads, where the answers never change once the
# prototype is registered. A keyed read is ~3.5µs; a whole tuple read plus `set --` is ~7µs for
# eight values.
#
# So the prototype's box answers are laid out ONCE, in the order the readers consume them, with an
# absent value already replaced by the fallback the reader would have chosen (0 for a count, `-`
# for overflow, which matches neither `auto` nor `scroll`). The reader needs no "did the
# prototype say anything" test: it takes the field.
#
# THIS IS NOT A NEW CASCADE LEVEL and it does not outrank anything. It is level 5's answer for
# a prototype, written down at the moment the prototype is built — see `_ft_prototype_box_tuples`,
# called from the one place FT_PROTO_DEFAULT is ever filled, which is why it needs no invalidation.
#
# SAFE BECAUSE NONE OF THESE VALUES CAN CONTAIN A SPACE: every one is a count or a single
# keyword. A property whose value could hold a space must never join a tuple — `set --` would
# split it in two and shift every field after it, silently, into the wrong side of the box.
declare -A FT_PROTO_INSET_BOX=()   # type → "border padding top right bottom left overflow overflowX topEdgeProp"
declare -A FT_PROTO_MARGIN_BOX=()  # type → "margin top right bottom left"
#
# THE SAME LIST GUARDS THE OTHER RAW FAST PATHS. `_ft_disp`, `_ft_border` and `_ft_padding` each
# asked `_FT_CSS_DECLARED_PROPS` whether a sheet declares their one property — a keyed read
# (~3.9µs) to learn a bit that is the same for the whole run. One scalar test (~0.5µs) answers it
# for all of them. It is deliberately COARSE: a sheet declaring `padding` turns it on for
# `display` too, and `display` then asks the sheet and is told no. That costs a reader speed in a
# case that is already the slow one, and it can never cost it truth — which is the only direction
# a shortcut like this is allowed to be wrong in.
declare -A _FT_FASTPATH_PROPS=()
for _ft_bp in border padding paddingTop paddingRight paddingBottom paddingLeft overflow overflowX \
              margin marginTop marginRight marginBottom marginLeft display; do
    _FT_FASTPATH_PROPS[$_ft_bp]=1
done
unset _ft_bp
# Set by the stylesheet parser when a sheet declares ANY of them. While it is empty — the usual
# case, and ALWAYS the case with ft-css unloaded — the readers below take their tuple and never
# ask a sheet anything. When it is set they ask per property, exactly as before, because level 2
# outranks the prototype.
_FT_CSS_FASTPATH_DECLARED=""
_ft_prototype_box_tuples() {        # type — called once, where the prototype's flat defaults are built
    local t=$1 p v inset="" margin=""
    for p in border padding paddingTop paddingRight paddingBottom paddingLeft; do
        v=${FT_PROTO_DEFAULT["$t $p"]-}; inset+=" ${v:-0}"
    done
    for p in overflow overflowX; do
        v=${FT_PROTO_DEFAULT["$t $p"]-}; inset+=" ${v:--}"
    done
    # …and the NAME of the property this prototype draws on its top edge, so _ft_inset4 can reserve
    # that row without a second table lookup. `-` for the prototypes that draw nothing there, which
    # is all of them but the frame.
    inset+=" ${FT_PROTO_TOP_EDGE_PROP[$t]:--}"
    for p in margin marginTop marginRight marginBottom marginLeft; do
        v=${FT_PROTO_DEFAULT["$t $p"]-}; margin+=" ${v:-0}"
    done
    FT_PROTO_INSET_BOX[$t]=${inset# }
    FT_PROTO_MARGIN_BOX[$t]=${margin# }
    # A prototype re-declared after its controls exist hands _ft_inset4 a different tuple, and no
    # property of any control changed to say so. Normally this runs before anything is built,
    # in which case the bump costs one increment.
    _FT_CLIP_GEN=$(( _FT_CLIP_GEN + 1 ))
}
# THE EMPTY STRING IS TREATED AS "DECLARES NOTHING", and that is safe by measurement rather than
# by luck: no prototype default is both INHERITED and EMPTY. The only two that inherit are
# `cursor=0` and `textAlign=center`, so "defaults to empty" and "does not default" cannot be
# told apart by any reader that exists — and one assoc read instead of a `-v` test plus a
# second read is worth 40ms on a 37-control layout. tests/test-prototype.bash asserts the invariant,
# so adding an inherited empty default fails there rather than here.
_ft_prototype_default() {           # name prop → FT_RET, status 1 if the prototype declares nothing
    [[ -n "${1:-}" ]] || { FT_RET=""; return 1; }     # ${FT_TYPE[""]} is a bash error on stderr
    FT_RET=${FT_PROTO_DEFAULT["${FT_TYPE[$1]:-} $2"]-}
    (( ${#FT_RET} > 0 ))
}
# …and the same answer as a VARIABLE NAME, for the readers that indirect through one. The
# scratch variable is per-call and immediately consumed; it exists so ft_own_prop's existing
# `${!var}` shape does not have to be rewritten around two different kinds of source.
_FT_PROTO_DEFAULT_SCRATCH=""
_ft_prototype_default_var() {       # name prop → FT_RET = a variable name holding the prototype default
    if [[ -n "${1:-}" ]]; then _FT_PROTO_DEFAULT_SCRATCH=${FT_PROTO_DEFAULT["${FT_TYPE[$1]:-} $2"]-}
    else                       _FT_PROTO_DEFAULT_SCRATCH=""; fi
    FT_RET=_FT_PROTO_DEFAULT_SCRATCH
}
# THE RESOLVED VALUE, FAST, for the raw readers that cannot afford ft_resolved_prop: what the author
# set, else what the prototype declares, else the caller's fallback. Every one of these used to be
# a single variable read that was correct only because the prototype default was stamped onto the
# instance — `runlevel` most of all, where an empty answer reads as "not unfocused", i.e. every
# control in the app permanently ENGAGED.
_ft_prop_or_prototype() {           # name prop fallback → FT_RET
    local v="_ftp_${1}_${2}"; FT_RET=${!v-}
    (( ${#FT_RET} )) && return
    [[ -n "${1:-}" ]] && FT_RET=${FT_PROTO_DEFAULT["${FT_TYPE[$1]:-} $2"]-} || FT_RET=""
    (( ${#FT_RET} )) || FT_RET=${3-}
}
# …and the question the INHERITANCE step has to ask, which is CSS's own rule: an inherited value
# fills in only where the cascade produced nothing FOR THIS ELEMENT, and a prototype default is a
# declaration for this element. Without it an option's `display: none` would be overridden by
# its parent's display, a tree would take a select's `cursor` INDEX, and a button's centred text
# — a UA-stylesheet promise its prototype comment spells out — would follow a container's
# `text-align`. Two of the 79 defaults inherit; this is what keeps them where they were.
_ft_prototype_declares() {          # name prop → 0 if this control's prototype defaults it
    [[ -n "${1:-}" ]] || return 1
    local _v=${FT_PROTO_DEFAULT["${FT_TYPE[$1]:-} $2"]-}
    (( ${#_v} > 0 ))
}

# Memoized: the first instance of a type triggers its prototype-constructor chain
# exactly once. A type with no ft_prototype_<type> declared is a plain control.
# Types whose initialisation is IN PROGRESS. Re-entering one is always a cycle, and a cycle
# here does not fail gracefully: `ft_prototype_init` calls "ft_prototype_$t", which calls it again,
# until bash's stack blows and the process takes a SEGFAULT — no message, no trap, nothing for
# the app to report. FT_PROTO_READY cannot catch it because it is only set on the way OUT.
# Three ways in, all of them authoring mistakes rather than exotica:
#   · `ft_prototype extends=X` inside ft_prototype_X         (a prototype extending itself)
#   · a longer ring — X extends Y, Y extends X
#   · a type whose NAME collides with a framework function: type `init` makes "ft_prototype_$t"
#     resolve to ft_prototype_init itself. (That is how this was found — a probe that enumerated
#     prototype names by grepping for ^ft_prototype_* matched the initialiser and passed it in.)
# Properties whose value the layout feeds to bash arithmetic. Listed by NAME because bash has
# no types: everything is a string until (( )) decides otherwise, and that is exactly the
# problem — see the validation in _ft_setprop. `value` is deliberately ABSENT: a text field's
# value is arbitrary text, and a slider's is range-checked by the control itself.
#
# THE VALUE IS THE SIGN THE PROPERTY ALLOWS, because "is it a number" was never the whole
# question. CSS types a length as `<length>` or `<length [0,∞]>` and drops a declaration that
# breaks it; here every one of them took a negative, and a negative length does not stay inside
# the control that asked for it:
#
#     ft_set b width=-6      a@0 b@5 c@10   →   a@0 b@5 c@0
#
# One label's width moved its NEXT SIBLING back on top of the first — a flex row summing a
# negative into its running offset. The control itself vanishes (every draw function starts
# `(( rows < 1 || cols < 1 )) && return`), silently, while ft_get answers -6: the shape this
# file already calls out for marginTop, "it fails silently, and it fails looking correct".
#
#   +  a length CSS types `[0,∞]` — dropped when negative, with a message
#   1  any integer, because the property genuinely has a negative meaning:
#      · margins are negative in CSS by design (pulling a box back over its neighbour)
#      · left/top are offsets, and `position: absolute; left: -1` is a real thing here
#      · min/max bound a slider's range, which can sit anywhere on the number line
#      · selectedIndex = -1 is HTML's "nothing is selected"
#      · scrollTop/scrollLeft are CLAMPED rather than dropped, which is what the DOM does
#        with `el.scrollTop = -5` — see _ft_clamp_scroll at the top of this file
#      · step is the slider's own, floored at the write by _ft_slider_sanitize_prop, which is
#        the prototype owning its own property rather than this table guessing for it
declare -A _FT_NUMERIC_PROP=(
    [width]=+ [height]=+ [minWidth]=+ [maxWidth]=+ [minHeight]=+ [maxHeight]=+
    [left]=1 [top]=1 [size]=+ [rows]=+ [maxLength]=+ [selectedIndex]=1
    [scrollTop]=1 [scrollLeft]=1 [min]=1 [max]=1 [step]=1
    # The published extents. The framework writes these, but nothing stopped an app from
    # writing one, and every reader feeds them straight to (( )) — ft_has_scrollbar, the
    # scrollbar's thumb arithmetic, and the scroll-offset clamp in _ft_setprop.
    [scrollHeight]=+ [scrollWidth]=+ [clientHeight]=+ [clientWidth]=+
    [padding]=+ [paddingTop]=+ [paddingRight]=+ [paddingBottom]=+ [paddingLeft]=+
    [margin]=1 [marginTop]=1 [marginRight]=1 [marginBottom]=1 [marginLeft]=1
    [gap]=+ [borderRadius]=+ [flexGrow]=+ [flexShrink]=+
    [parkedTop]=1 [parkedLeft]=1        # a dragged callout's parked box — geometry, and the one
                                        # kind that can arrive from a SAVED STATE FILE
)
declare -A _FT_PROTO_INITIALISING=()
ft_prototype_init() {               # type
    local t=$1
    [[ -z "$t" ]] && return 2                  # empty subscripts are a bash error, not a prototype
    [[ -n "${FT_PROTO_READY[$t]:-}" ]] && return 0
    if [[ -n "${_FT_PROTO_INITIALISING[$t]:-}" ]]; then
        printf 'ft_prototype_init: "%s" is already being initialised — extends= cycle, or a type name that collides with a framework function\n' \
               "$t" >&2
        return 2
    fi
    _FT_PROTO_INITIALISING[$t]=1
    # `local` is the mechanism, not a shortcut: bash's dynamic scoping publishes the target
    # prototype to every ft_prototype call in the chain below AND restores it on the way out, so a
    # constructor that itself initialises another prototype cannot corrupt the one in progress.
    local FT_PROTO_UNDER_CONSTRUCTION=$t _FT_PROTO_STRUCT_WRITTEN=0 \
          _FT_PROTO_DECLARATION_FAILED=0 _FT_PROTO_CHAIN=$t
    _ft_prototype_struct_clear "$t"
    if declare -F "ft_prototype_$t" >/dev/null 2>&1; then
        "ft_prototype_$t" "$t"
    else
        ft_prototype_ft_control "$t"
    fi
    unset "_FT_PROTO_INITIALISING[$t]"       # before either exit: a failed prototype may be retried
    # Only a prototype that declared itself cleanly is memoized. Caching a rejected one would
    # report the fault once and then behave as though the broken struct were intended.
    (( _FT_PROTO_DECLARATION_FAILED )) && return 2
    _ft_prototype_finish_runlevels "$t"      # …now that `focusable` is settled, add the free rungs
    # FT_PROTO_DEFAULTS[$t] already carries the whole extends chain, appended base-first, so
    # one pass gives the flat table with later declarations overriding earlier ones — which is
    # what lets `button` say `importance=crucial` after `label` said `importance=minor`.
    # A PROTOTYPE MAY BRING A HANDLER, not only a value. `on<Event>=` is not an ordinary
    # property — _ft_setprop intercepts it and appends to the control's eventListeners plist —
    # so a prototype default for one resolved to nothing at all: the control looked wired and
    # was not. They are collected here instead, and applied to each instance as it is built.
    local _kv
    FT_PROTO_LISTENERS[$t]=""
    for _kv in ${FT_PROTO_DEFAULTS[$t]:-}; do
        case ${_kv%%=*} in
            on[A-Z]*) FT_PROTO_LISTENERS[$t]+="${FT_PROTO_LISTENERS[$t]:+ }$_kv"; continue ;;
        esac
        FT_PROTO_DEFAULT["$t ${_kv%%=*}"]=${_kv#*=}
    done
    # A prototype default is the last level of every instance's resolution, and a prototype may be
    # declared lazily — on the first control of its type, long after other controls have resolved
    # against an empty table. Nothing here knows which properties or which types are affected, so
    # this is the global drop; prototype declaration happens a few dozen times in a program's life.
    _ft_resolve_inval_all
    _ft_prototype_box_tuples "$t"           # …and the box answers, laid out for one read apiece
    FT_PROTO_READY[$t]=1
    return 0
}

# ── Nesting DSL ──────────────────────────────────────────────────────────────
declare -a FT_NEST_STACK=()
# _ft_keymap_of NAME → FT_RET: NAME's OWN keymap — its instance overlay, the highest-precedence
# layer — created on first use. Four places built this by hand from the same three lines, which
# is three chances for one of them to compose the storage name differently.
_ft_keymap_of() {               # name → FT_RET (keymap name)
    FT_RET=${FT_KEYMAP[$1]:-}
    [[ -n "$FT_RET" ]] && return 0
    FT_RET="${1}__km"; FT_KEYMAP[$1]=$FT_RET; _ft_keymap_declare "$FT_RET"
}
declare -A FT_PENDING_FOCUS=() FT_ACCEL_FORM=() FT_ACCEL_LIST=()

# ── An accelerator is REGISTERED, not just declared ──────────────────────────
# `accessKey` has a registry behind it — FT_ACCEL_LIST plus a binding on the enclosing form's
# keymap — and the underline the control draws comes from the PROPERTY. Registering at
# construction and nowhere else meant `ft_set btn accessKey=K` moved the underline and left
# the binding on S: an underlined letter that does nothing, and an un-underlined one that still
# fires. In a framework where "an underlined letter is a promise", that is the promise broken.
#
# One pair of functions so construction, destruction and a runtime write cannot answer
# differently. This is the third table in this file fed from a property at construction whose
# runtime route was missing (FT_DRAW and FT_FOCUSABLE were the others) — if you add a fourth,
# wire all three routes at once.
#
# UNREGISTER READS THE REGISTRY, NOT THE PROPERTY. The property is exactly what may have just
# changed, so trusting it would remove the NEW letters and leave the old ones bound — which is
# also a latent bug on the destroy path, where the old code trusted it.
_ft_accel_unregister() {        # name — drop every accelerator currently registered for NAME
    local name=$1 form=${FT_ACCEL_FORM[$name]:-}
    [[ -n "$form" ]] || return 0
    local akey ac newlist x
    for akey in "${!FT_ACCEL_LIST[@]}"; do
        [[ "$akey" == "$form"$'\x1f'* ]] || continue
        case " ${FT_ACCEL_LIST[$akey]} " in *" $name "*) ;; *) continue ;; esac
        ac=${akey##*$'\x1f'}
        newlist=""
        for x in ${FT_ACCEL_LIST[$akey]}; do [[ "$x" == "$name" ]] || newlist+="${newlist:+ }$x"; done
        if [[ -n "$newlist" ]]; then
            FT_ACCEL_LIST[$akey]=$newlist                # other sharers keep the letter
        else
            unset "FT_ACCEL_LIST[$akey]"
            [[ -n "${FT_KEYMAP[$form]:-}" ]] && ft_keymap_unset "${FT_KEYMAP[$form]}" "[${ac}${ac,,}]"
        fi
    done
    unset "FT_ACCEL_FORM[$name]"
    return 0
}
_ft_accel_register() {          # name — bind NAME's accelerators from its current accessKey
    local name=$1
    # RESOLVED, not raw. The letter may come from the PROTOTYPE — ft-button-ok is a button whose
    # default accessKey is k — or from a stylesheet, and a raw read sees neither. The draw has
    # always resolved it (_ft_draw_button underlines through ft_resolved_prop), so a
    # prototype-provided letter was UNDERLINED ON SCREEN AND BOUND TO NOTHING: the exact shape
    # of promise-without-delivery that ft_accesskey_conflicts exists to catch, arriving by a
    # route that function cannot see because no binding was ever made.
    ft_resolved_prop "$name" accessKey
    [[ -n "$FT_RET" ]] || return 0
    local letters=$FT_RET ac       # save it: _ft_enclosing_form_of overwrites FT_RET
    _ft_enclosing_form_of "$name"
    [[ -n "$FT_RET" ]] || return 0
    local form=$FT_RET
    _ft_keymap_of "$form"; local km=$FT_RET
    for ac in $letters; do
        ac=${ac^^}
        local akey="${form}"$'\x1f'"${ac}"
        FT_ACCEL_LIST[$akey]="${FT_ACCEL_LIST[$akey]:-}${FT_ACCEL_LIST[$akey]:+ }$name"
        # Written in the key-field grammar, so the stored CODE is exactly the string the
        # legend and ft_accesskey_conflicts compare against — they used to match a literal
        # they each spelled out, and a change to how a binding is stored broke both readers
        # at once while the accelerator itself went on working.
        ft_keymap_set "$km" key="[${ac}${ac,,}]" onKey="_ft_accel_dispatch $form $ac"
    done
    FT_ACCEL_FORM[$name]=$form
    return 0
}

# _ft_accel_dispatch FORM LETTER [name token] — activate the first control
# sharing LETTER on FORM that is enabled AND visible (skips display=none,
# visibility=hidden, and disabled controls). Bound by the accessKey sugar.
# Which control would this accelerator actually activate right now → FT_RET ("" if none).
# ONE answer, used by the firing AND by the legend below, so the bar can never advertise an
# accelerator that would do nothing — the same rule the keymap layers follow.
_ft_accel_target() {            # form letter → FT_RET
    local akey="${1}"$'\x1f'"${2}" n
    for n in ${FT_ACCEL_LIST[$akey]:-}; do
        [[ -n "${FT_TYPE[$n]:-}" ]] || continue
        # A TAB is reachable by its accelerator even while its own panel is hidden
        # (activating it is what un-hides it) — only skip it if the whole tabs
        # widget is hidden. Every other control uses the normal skip test.
        if [[ "${FT_TYPE[$n]}" == tab ]]; then
            _ft_hidden_anywhere "${FT_PARENT[$n]:-}" && continue
        else
            _ft_focus_skippable "$n" && continue
        fi
        FT_RET=$n; return 0
    done
    FT_RET=""; return 1
}
_ft_accel_dispatch() {          # form letter
    _ft_accel_target "$1" "$2" && ft_activate "$FT_RET"
    return 0
}

# A form ADVERTISES its accelerators. They are ordinary keymap bindings already, but carry no
# keyCap — which is exactly why a focused button's accessKey never reached the bar. The label has to be read LIVE here rather than baked into
# a static keycap: `ft_set ok text="Save As"` must not leave a stale legend entry, and a
# control that has since been hidden or disabled must drop out of the bar entirely.
# Importance is deliberately NORMAL: accelerators are always live, so at a higher tier a
# six-button form would bury the focused control's own keys.
_ft_caps_form() {               # name
    local form=$1 akey letter target textprop label _tty
    for akey in "${!FT_ACCEL_LIST[@]}"; do
        [[ "$akey" == "${form}"$'\x1f'* ]] || continue
        letter=${akey#*$'\x1f'}
        _ft_accel_target "$form" "$letter" || continue      # nothing eligible → do not advertise
        target=$FT_RET
        # THE LEGEND MUST DESCRIBE WHAT THE KEY ACTUALLY DOES. A plain binding registered later
        # on the same keymap wins dispatch outright (lookup takes the last registration), so
        # advertising the accelerator anyway printed `B: Bold` for a key that paged backwards.
        # It also duplicated keys: this cap's pattern is the bare letter `K` while an app's own
        # keycap is `[Kk]`, so the pattern-based dedup never collapsed them and the bar showed
        # `K: Okay` and `K: Okay → next page` side by side. Both go away by asking the cascade.
        # (ft_accesskey_conflicts reports the same situation as an authoring error.)
        if [[ -n "${FT_KEYMAP[$form]:-}" ]] && _ft_keymap_lookup "${FT_KEYMAP[$form]}" "${letter,,}"; then
            [[ "$FT_RET" == "_ft_accel_dispatch $form $letter" ]] || continue
        fi
        _tty=${FT_TYPE[$target]:-}; textprop=text          # empty if it was just removed
        [[ -n "$_tty" ]] && textprop=${FT_PROTO_TEXTPROP[$_tty]:-text}
        _ft_get_raw "$target" "$textprop"; label=$FT_RET
        [[ -n "$label" ]] || label=$target                  # no text of its own → its name
        _ft_caps_add "$FT_IMPORTANCE_NORMAL" "$letter" "$label"
    done
}

# _ft_is_ancestor ANCESTOR NODE → 0 if ANCESTOR is at or above NODE in the tree.
# Used to refuse a reparent that would make a ring; the walk is depth-capped for the same
# reason every upward walk here is (see _ft_enclosing_form_of).
_ft_is_ancestor() {             # ancestor node
    local want=$1 n=$2 hops=0
    while [[ -n "$n" ]] && (( hops++ < 1000 )); do
        [[ "$n" == "$want" ]] && return 0
        n=${FT_PARENT[$n]:-}
    done
    return 1
}
_ft_enclosing_form_of() {       # name → FT_RET (nearest form ancestor or "")
    local n=${FT_PARENT[$1]:-} hops=0
    # DEPTH-CAPPED. A ring in FT_PARENT makes this spin forever, and it runs during
    # construction of every focusable control — so a malformed tree hung the app before it
    # drew anything. ft_append/_ft_insert_at refuse to build a ring in the first place; this
    # is the belt to that pair of braces, and no real tree is 1000 deep.
    while [[ -n "$n" ]] && (( hops++ < 1000 )); do
        [[ "${FT_TYPE[$n]:-}" == form ]] && { FT_RET=$n; return; }
        n=${FT_PARENT[$n]:-}
    done
    FT_RET=""
}

# ── Instance construction ────────────────────────────────────────────────────
# ft_new TYPE args... — the framework's registration entry point every prototype
# constructor calls. Prototype defaults apply first, user args after (later wins).
# Parent: explicit parent= wins, else the innermost open container. Focusable
# controls are recorded (in declaration order) for their form's focus ring.
# Sets FT_RET to the registered name.
ft_new() {                      # TYPE args...
    local type=$1; shift
    # A prototype that failed to declare itself is not half-usable — building instances of it
    # would scatter the real fault across whatever it later fails to draw or focus.
    ft_prototype_init "$type" || return 1
    local a name="" parent_explicit=0
    for a in "$@"; do
        case "$a" in
            name=*)   [[ -z "$name" ]] && name="${a#name=}" ;;
            parent=*) parent_explicit=1 ;;
        esac
    done
    [[ -z "$name" ]] && { printf 'ft: %s needs name=...\n' "$type" >&2; return 1; }
    # A NAME BECOMES PART OF A VARIABLE NAME. Properties live in `_ftp_<name>_<prop>` and the
    # side tables in `_fti_<name>__<what>` (see _ft_setprop), so a name that is not a valid
    # identifier fragment cannot be stored: bash rejects each write with "invalid variable
    # name" — a dozen of them, from every table the control touches, straight onto the alt
    # screen — and the control ends up half-built rather than absent. `name="my button"` is
    # enough. Refuse it once, clearly, instead.
    if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z_0-9]*$ ]]; then
        printf 'ft: %s: "%s" is not a usable control name (letters, digits and _ only, not starting with a digit)\n' \
               "$type" "$name" >&2
        return 1
    fi
    FT_TYPE[$name]="$type"
    # A NAME MAY HAVE BEEN SOMETHING ELSE. Its type decides its prototype defaults, and the rebuild
    # idiom re-declares a subtree under the same names, so the incoming control must not read the
    # outgoing one's resolved answers. (ft_remove bumps too; this covers a name that was resolved
    # against before it was ever a control.)
    _ft_resolve_inval "$name"
    [[ -z "${FT_KIDS[$name]+x}"   ]] && FT_KIDS[$name]=""
    [[ -z "${FT_KEYMAP[$name]+x}" ]] && FT_KEYMAP[$name]=""
    FT_PROPS[$name]=""
    _FT_TEXTPROP=${FT_PROTO_TEXTPROP[$type]:-text}
    # THE DEFAULTS ARE NOT APPLIED HERE ANY MORE. They used to be prepended to the constructor's
    # own arguments, which made them instance properties — cascade level 1, above every
    # stylesheet. They are resolved at level 5 now (see FT_PROTO_DEFAULT). A control is built
    # with exactly the properties its caller named, which is also why ft_state_save now writes a
    # reader's choices instead of forty-two of the prototype's.
    # The prototype's handlers first, the app's after — the same order as every other level of
    # resolution, and the same order they will run in: a prototype contributes behaviour, the
    # app adds to it. (Listeners ACCUMULATE here, exactly as two `onActivate=` arguments in one
    # call do; a prototype handler is not replaced by an instance one. Clear it with onX="".)
    local _pl
    for _pl in ${FT_PROTO_LISTENERS[$type]:-}; do _ft_setprop "$name" "${_pl%%=*}" "${_pl#*=}"; done
    _ft_apply_args "$name" "$@"
    _FT_TEXTPROP=text
    if (( ! parent_explicit )) && (( ${#FT_NEST_STACK[@]} > 0 )); then
        local top_idx=$(( ${#FT_NEST_STACK[@]} - 1 ))
        _ft_setprop "$name" parent "${FT_NEST_STACK[$top_idx]}"
    fi
    _ft_get_raw "$name" parent
    # NOTHING MAY BE ITS OWN PARENT. That is a CYCLE in the tree, and every walk up it —
    # _ft_enclosing_form_of, the inheritance chain, _ft_hidden_anywhere — then spins forever:
    # the app HANGS at construction, before it has drawn anything, and the user has to kill it.
    # It is one keystroke away in ordinary authoring, because the DSL takes the parent from the
    # nesting stack: giving a control the same name as the container it sits in is enough.
    #     ft-form name=self …
    #         ft-button name=self "Me"      ← FT_PARENT[self]=self
    local _par=$FT_RET          # separate: _ft_setprop below overwrites FT_RET
    if [[ "$_par" == "$name" ]]; then
        printf 'ft: %s: a control cannot be its own parent — check for a duplicate name\n' "$name" >&2
        _par=""
        _ft_setprop "$name" parent ""
    fi
    FT_PARENT[$name]=$_par
    _ft_get_raw "$name" draw;      FT_DRAW[$name]=$FT_RET
    _ft_get_raw "$name" focusable
    _ft_focusable_apply "$name" "$type" "$FT_RET"
    if [[ -n "${FT_PARENT[$name]}" ]]; then
        local p="${FT_PARENT[$name]}"
        FT_KIDS[$p]="${FT_KIDS[$p]}${FT_KIDS[$p]:+ }$name"
    fi
    if [[ "${FT_FOCUSABLE[$name]}" == 1 ]]; then
        _ft_enclosing_form_of "$name"
        [[ -n "$FT_RET" ]] && FT_PENDING_FOCUS[$FT_RET]="${FT_PENDING_FOCUS[$FT_RET]:-}${FT_PENDING_FOCUS[$FT_RET]:+ }$name"
    fi
    # accessKey sugar: underline is the prototype draw fn's job; the BEHAVIOR is a
    # keymap binding on the enclosing form. Several controls MAY share one
    # accelerator letter — the key activates the first of them (in declaration
    # order) that is currently enabled AND visible, so e.g. a "Hide" and an
    # "Unhide" button can both own H and the right one always responds.
    # accessKey may name SEVERAL letters, space-separated — HTML specifies the attribute as
    # an ordered set of tokens (`accessKey="s k"`). We bind them all; a browser picks one.
    _ft_accel_register "$name"
    ft_dirty "$name"
    FT_RET=$name
}

# Built-in container prototypes + the DSL statements. A container constructor
# registers, then pushes itself as the current parent; end_ft_* pops it.
ft_prototype_form() {
    # A form's draw FILLS ITS WHOLE BOX and paints no children (see _ft_draw_form), so
    # anything that repaints a form on its own erases the entire screen and leaves only
    # whatever else happened to be dirty. `fillsBackground` is the flag for exactly that,
    # and the form — the case its own comments cite — was never declared with it: any
    # damage rect anywhere enlisted the root form and blanked the app. (Found via the Ctrl+S
    # confirmation, whose one-row repair took the whole UI with it.)
    ft_prototype extends=ft_control keymap=form \
        fillsBackground=true
}
# The form ALWAYS fills its rectangle (the screen colour, or its own
# backgroundColor): the root form IS the screen — like body { background } —
# and its fill is also what erases vacated cells when children shrink or
# move, so nothing ever smears.
_ft_draw_form() {               # name
    local name=$1
    _ft_color_override "$name" backgroundColor 48; local bgov=$FT_RET
    local sgr="$FT_COLOR_SCREEN$bgov"
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local rows=${FT_MEASURED_HEIGHT[$name]:-0} cols=${FT_MEASURED_WIDTH[$name]:-0}
    ft_fit "" "$cols"
    local r
    for (( r=0; r<rows; r++ )); do
        ft_print_at_width $(( row + r )) "$col" "$sgr$FT_FIT$FT_COLOR_RESET" "$cols"   # known width: skip ft_print_at's ANSI scan
    done
}
# div: a plain undrawn ft_control container — no prototype-constructor needed.

ft-form()  { ft_new form  "$@" && FT_NEST_STACK+=("$FT_RET"); }
ft-frame() { ft_new frame "$@" && FT_NEST_STACK+=("$FT_RET"); }
# ft-div — a bare grouping container (HTML's <div>): no border, no background,
# display=block by default. The neutral box you reach for to group controls
# for layout or to make a run of text participate in structure.
#
# NB: this was ALSO spelled `ft-div`, creating the identical type — two public
# names for one thing, and the type was `panel`, so the DOM-facing `div { … }`
# selector matched nothing. Per docs/api-naming.md the DOM name wins: the type
# is `div`, `div { … }` cascades, and ft-div/end_ft_div are gone.
ft-div()     { ft_new div "$@" && FT_NEST_STACK+=("$FT_RET"); }
end_ft_div() { ft_end div; }

# ft-option — a DATA element (HTML's <option>): value= is what the enclosing
# control's `value` becomes when this option is current; glyph= (and/or
# text=) is its presentation. WITH NO value= OF ITS OWN AN OPTION IS WORTH ITS
# TEXT, as in HTML — read it with _ft_option_value, never raw. display=none —
# options are never laid out or drawn themselves; their OWNER (multitoggle,
# select) renders them. name= is optional (auto-generated from the owner).
ft_prototype_option() { ft_prototype extends=ft_control defaults="display=none"; }
_FT_OPT_SEQ=0
ft-option() {
    local a hasname=0
    for a in "$@"; do [[ "$a" == name=* ]] && hasname=1; done
    if (( hasname )); then
        ft_new option "$@"
    else
        local owner=""
        (( ${#FT_NEST_STACK[@]} > 0 )) && owner="${FT_NEST_STACK[$(( ${#FT_NEST_STACK[@]} - 1 ))]}"
        ft_new option name="${owner}_opt$(( ++_FT_OPT_SEQ ))" "$@"
    fi
}
# _ft_options NAME → fills FT_OPTS[] with NAME's option children, in order.
FT_OPTS=()
_ft_options() {                 # name
    local kid
    FT_OPTS=()
    for kid in ${FT_KIDS[$1]:-}; do
        [[ "${FT_TYPE[$kid]:-}" == option ]] && FT_OPTS+=("$kid")
    done
}
# _ft_option_value OPTION → FT_RET — what this option is WORTH: its `value` if it has one,
# otherwise its text. HTML's rule, and the reason it matters here is that the short form of the
# API is the one without a value:
#
#     ft-option "alpha"                    ← .value is "alpha" in a browser…
#
# …and reading `value` raw answered EMPTY, so `ft_get se value` on a three-option select built
# the natural way returned nothing at all, whichever option was chosen. Every reader of an
# option's worth goes through here — ft-select and ft-multitoggle, eight sites between them.
# An option that sets `value=""` DELIBERATELY is worth the empty string, not its text — that is
# HTML's placeholder row (`<option value="">Choose…</option>`) — so this asks whether the
# property is SET, not whether it is non-empty.
_ft_option_value() {            # option → FT_RET
    if _ft_has_prop "$1" value; then _ft_get_raw "$1" value
    else                            _ft_get_raw "$1" text; fi
    return 0
}

# _ft_dim_if_disabled NAME SGR → FT_RET: the SGR with the themed disabled
# FOREGROUND override appended when the control is disabled (directly or via
# a disabled ancestor — disabled inherits). Always a COLOR (FT_COLOR_DISABLED_TXT),
# never the \e[2m dim attribute: FT_COLOR_RESET is a colour pair, so a leaked
# attribute would fade the entire screen until something emitted \e[0m.
_ft_dim_if_disabled() {         # name sgr
    local name=$1 sgr=$2
    ft_resolved_prop "$name" disabled false
    [[ "$FT_RET" == true ]] && sgr+="$FT_COLOR_DISABLED_TXT"
    FT_RET=$sgr
}
ft-control() {                  # TYPE args... — fully custom type, also nests if container-like use
    ft_new "$@"
}

# ft_end TYPE — pop the innermost open container, verify its type, fire the
# "children fully known" hook. NOT a destructor: nothing is torn down; this is
# where a parent finishes construction using complete knowledge of its
# descendants (the form assembles its focus ring here).
ft_end() {                      # expected-type
    local expect=$1
    if (( ${#FT_NEST_STACK[@]} == 0 )); then
        printf 'ft: end_ft_%s with no open container\n' "$expect" >&2
        return 1
    fi
    local idx=$(( ${#FT_NEST_STACK[@]} - 1 ))
    local name="${FT_NEST_STACK[$idx]}"
    unset "FT_NEST_STACK[$idx]"
    local actual="${FT_TYPE[$name]}"
    if [[ "$actual" != "$expect" ]]; then
        printf 'ft: end_ft_%s closes "%s", which is a %s (mis-nested?)\n' "$expect" "$name" "$actual" >&2
    fi
    declare -F "${actual}_on_children_complete" >/dev/null 2>&1 && "${actual}_on_children_complete" "$name"
    FT_RET=$name
    return 0
}
end_ft_form()  { ft_end form; }
end_ft_frame() { ft_end frame; }

form_on_children_complete() { ft_focus_ring_build "$1"; }

# ft_set NAME prop=value ... — THE way to change properties after
# construction. Consults FT_PROP_KIND per property: paint-only changes just
# dirty this control; any genuinely-changed layout property triggers a reflow
# (see ft_reflow). Values identical to the current one are ignored entirely —
# re-setting the same text costs nothing. A trailing `keymap k=a ...` section
# updates the instance overlay as at construction.
# ── What a changed property is owed ──────────────────────────────────────────
# ONE ANSWER FOR EVERY ROUTE THAT CHANGES A PROPERTY. ft_set and ft_unset each
# carried their own copy of this case, and the copy in ft_unset is the one that kept
# drifting — its own comments counted six repairs, each "same predicate, same route". The
# seventh was `position`: ft_set knows that a control leaving or rejoining the flow MOVES
# its siblings and re-arranges the parent, while removing `position` ran the size-only reflow,
# which found the control's own box unchanged and stopped — the sibling stayed wherever the
# absolute control had let it slide until something else laid the page out. The same copy had
# also never re-registered an accelerator, refreshed the focusable or draw table, armed or
# cancelled a transition, or told the prototype (REPROP). Found by tests/test-incremental.bash.
#
# _ft_prop_owed NAME KEY does what cannot wait for that one property (a registration, a hide's
# damage) and RECORDS the rest in the CALLER's `_ft_owed`; _ft_prop_owed_pay NAME then pays it
# once, so a write of five properties still reflows once. Caller-scoped rather than global on
# purpose: a prototype reconciler may itself call ft_set, and a nested write must not clear the
# debts of the write it is nested in. The caller declares `local _ft_owed="" _ft_owed_keys=""`.
_ft_prop_owed() {               # name key → 1 if the change is refused (the property is put back)
    local name=$1 key=$2
    _ft_owed_keys+="$key "
    case "$key" in
        left|top|position) _ft_owed+=" moved" ;;
        # A `keys=auto` legend is DERIVED from the focused control's keys, so changing which
        # keys it has must repaint it. _ft_legend_dirty was called on focus, runlevel and the
        # textfield's own state — every transition that existed when a binding could only be
        # written before the app ran. Writing keys at RUNTIME is ordinary now (ft_set takes
        # key fields, and defaultKeys can silence a prototype), and the legend went on
        # advertising keys the control no longer had until something else repainted it.
        keymap|defaultKeys) _ft_legend_dirty ;;
        draw) _ft_get_raw "$name" draw; FT_DRAW[$name]=$FT_RET; _ft_owed+=" paint" ;;
        # `focusable` has a TABLE behind it, exactly as `draw` does, and the ring is built
        # from that table rather than from the property. Writing only the property left
        # `ft_set x focusable=false` completely inert — the control stayed in the ring
        # and stayed focusable. Same normalisation as construction, because a rule enforced
        # on one route and not its sibling is how the two drift apart.
        # `parent` NAMES THE TREE, AND THE TREE IS NOT A PROPERTY. At construction it says
        # "attach me here" and ft_new wires FT_PARENT and the parent's FT_KIDS from it.
        # Written afterwards it moved NOTHING: the property said one container, FT_PARENT
        # and FT_KIDS said another, and layout, the focus ring, clipping and ft-state all
        # walk the tables. ft-state was the sharp end — it serialises properties, so a
        # restore would have put the control in the container the stale property named.
        #
        # Refused rather than performed, because that is what the DOM does: `parentNode` is
        # read-only and you move a node with a verb. api-naming.md already maps it to a
        # READER (`ft_parent`). The verb is ft_append, which also refuses the cycles a
        # property write could not even detect.
        parent)
            printf 'ft: %s: parent is not settable — use ft_append PARENT %s to move it\n' \
                   "$name" "$name" >&2
            _ft_setprop "$name" parent "${FT_PARENT[$name]:-}"   # put the honest value back
            return 1
            ;;
        # An accelerator is a REGISTRATION, and the underline the control draws comes from
        # this property — so changing it here without re-registering leaves the key bound to
        # the OLD letter while the label advertises the new one. Unregister first: it reads
        # the registry rather than this property, which has already been written.
        accessKey)
            _ft_accel_unregister "$name"
            _ft_accel_register "$name"
            _ft_legend_dirty                    # the bar advertises accelerators too
            # `;;&` — DO THE REGISTRATION, THEN LET THE GENERAL RULE DECIDE THE REPAINT.
            # This arm used to end `need_paint=1  # the underline moved`, which is true and
            # not the whole truth: _ft_preferred_width_button, _radio and _multitoggle all
            # append " (X)" when the accelerator letter is not already in the label, so the
            # control has to WIDEN to hold its own accelerator. Measured: a Save button
            # stayed six columns after accessKey=Z and drew its accelerator into somebody
            # else's cells. A named arm that answers a general question for itself is this
            # codebase's most frequently logged root cause; the classification lives in
            # exactly one place at the bottom of this case, and this arm now falls into it.
            ;;&
        focusable)
            _ft_get_raw "$name" focusable
            _ft_focusable_apply "$name" "${FT_TYPE[$name]:-}" "$FT_RET"
            _ft_owed+=" focus"
            # The ring is a list of names, so a control joining or leaving it needs the
            # ring rebuilt — the same signal a newly declared control raises.
            _ft_enclosing_form_of "$name"
            [[ -n "$FT_RET" ]] && FT_PENDING_FOCUS[$FT_RET]="${FT_PENDING_FOCUS[$FT_RET]:-}${FT_PENDING_FOCUS[$FT_RET]:+ }$name"
            ;;
        visibility)
            # visibility inherits, so this is the general rule below plus a focus check —
            # and a hide's damage: a hidden control paints a blank over its BOX, and whatever it
            # inked outside the box (a callout, its leader) would stay. Hiding gives those cells
            # back, as display:none below does.
            _ft_owed+=" focus subtree"
            ft_resolve "$name" visibility
            [[ "$FT_RET" == hidden ]] && ft_damage_subtree "$name"
            ;;
        disabled|display)
            _ft_owed+=" focus"
            ft_prop_kind "$key"
            # `disabled` INHERITS (the engine dims a disabled control's whole subtree in
            # _ft_compose_sgr), so like any inherited paint property it repaints the
            # subtree, not the node — a disabled container with a still-bright label was
            # the visible gap. `display` is layout-kind and reflows.
            if [[ "$FT_RET" == layout ]]; then _ft_owed+=" reflow"
            else _ft_owed+=" subtree"; fi
            # SHOWING AND HIDING ARE THE WHOLE TRANSITION API. An application changes
            # `display` and the engine does the rest, because that is how CSS behaves: you
            # change a style and the transition happens because a stylesheet asked for it.
            # Nothing is invoked. (See ft-transition.bash, "The automatic path".)
            #
            # Arming cannot happen HERE — it needs the control's settled box, and inside an
            # input burst the reflow is still pending — so the intent is recorded and
            # ft_redraw_dirty arms it once layout has run.
            if [[ "$key" == display ]]; then
                _ft_disp "$name"
                if [[ "$FT_RET" == none ]]; then
                    # …AND HIDING REPAIRS ITSELF. A control that stops being drawn leaves
                    # cells nothing else knows were ever touched — most visibly an
                    # absolutely-positioned overlay, which owns cells outside every other
                    # control's box. This is the automatic damage rendering-damage.md always
                    # said `display:none` owes, and it is a bug with or without transitions:
                    # the demo was hand-rolling FT_PAINT_RECT bookkeeping to work around it.
                    if declare -F ft_transition_cancel >/dev/null 2>&1; then
                        ft_transition_cancel "$name" >/dev/null 2>&1 || :
                    fi
                    ft_damage_subtree "$name"
                elif declare -F ft_transition_pending >/dev/null 2>&1; then
                    ft_transition_pending "$name"
                fi
            fi
            ;;
        *)
            # SETTING A PROPERTY IS ALL AN APPLICATION SHOULD HAVE TO DO. In CSS you change
            # a value; you do not then tell the renderer to repaint. ft_set already
            # knows each property's KIND, so it acts on it: layout → reflow, paint → dirty.
            #
            # AN INHERITED PROPERTY CHANGES THE CHILDREN TOO, and that is the part apps
            # were hand-rolling. `ft_set inhbox color=X` repaints inhbox; every label
            # inside it still shows the old colour, because it inherits one that just
            # changed. So demo/css-demo.bash carried
            #     ft_set inhbox color="$1"; ft_dirty_subtree inhbox
            # on three separate handlers. FT_INHERITED_PROP already knows which properties
            # do this — including every --custom property, which inherits by definition —
            # so the engine can and now does.
            ft_prop_kind "$key"
            if [[ "$FT_RET" == layout ]]; then _ft_owed+=" reflow"
            else
                _ft_propkey "$key"
                if [[ "$FT_RET" == --* || -n "${FT_INHERITED_PROP[$FT_RET]:-}" ]]
                then _ft_owed+=" subtree"
                else _ft_owed+=" paint"; fi
            fi
            ;;
    esac
    return 0
}
_ft_prop_owed_pay() {           # name — settle what _ft_prop_owed recorded
    local name=$1 owed=" $_ft_owed " keys=$_ft_owed_keys moved=0
    local _ty=${FT_TYPE[$name]:-}
    [[ "$owed" == *" moved "* ]] && moved=1
    # The prototype gets told what changed BEFORE the repaint is scheduled, so anything it does in
    # response (arming an animation, resizing an internal buffer) is part of the same frame.
    # `-n "$_ty"` FIRST: ft_set is reachable for a control that has no type (removed by an
    # earlier handler in the same burst), and ${ASSOC[""]} is a bash error on stderr — which in
    # a TUI is the alt screen. tests/test-reach.bash exists to catch exactly this and did.
    if [[ -n "$keys" && -n "$_ty" && -n "${FT_PROTO_REPROP[$_ty]:-}" ]]; then
        "${FT_PROTO_REPROP[$_ty]}" "$name" "$keys"
    fi
    if (( moved )) || [[ "$owed" == *" reflow "* ]]; then
        ft_reflow "$name" "$moved"
    elif [[ "$owed" == *" subtree "* ]]; then
        ft_dirty_subtree "$name"
    elif [[ "$owed" == *" paint "* ]]; then
        ft_dirty "$name"
    fi
    # If this change made the CURRENTLY-FOCUSED control unfocusable (disabled or
    # hidden), don't leave focus stranded on it — advance to the next focusable.
    if [[ "$owed" == *" focus "* && -n "${FT_FOCUS:-}" ]] && _ft_focus_skippable "$FT_FOCUS"; then
        ft_focus_move 1
    fi
    return 0
}

ft_set() {                   # name args...
    local name=$1; shift
    local arg key val rejected=0
    local -a _kf=()
    local _ft_owed="" _ft_owed_keys=""
    # A control removed by an earlier handler has NO TYPE, and ${ASSOC[""]} is a bash error
    # on stderr — the alt screen, in a TUI. Read the type first, subscript with it.
    local _ty=${FT_TYPE[$name]:-} textprop=text
    [[ -n "$_ty" ]] && textprop=${FT_PROTO_TEXTPROP[$_ty]:-text}
    for arg in "$@"; do
        # KEY FIELDS are not properties — a control binds many keys and the property store
        # holds one value per name — so they are collected here and folded into this
        # control's own keymap (its instance overlay) once the arguments are read.
        case $arg in key=*|keyCap=*|keyImp=*|onKey=*) _kf+=("$arg"); continue ;; esac
        _ft_is_assignment "$arg" || { _ft_bare_content "$name" "$arg"; rejected=1; continue; }
        key="${arg%%=*}"; val="${arg#*=}"
        _ft_get_raw "$name" "$key"
        [[ "$FT_RET" == "$val" ]] && _ft_has_prop "$name" "$key" && continue
        # A setter may REFUSE the value (an undeclared runlevel). Skip this key's side
        # effects and report it — silently returning 0 would leave the caller believing
        # a change landed when the property was never written.
        _ft_setprop "$name" "$key" "$val" || { rejected=1; continue; }
        _ft_prop_owed "$name" "$key" || rejected=1
    done
    (( ${#_kf[@]} )) && { _ft_keymap_of "$name"; _ft_keyfields "$FT_RET" "${_kf[@]}"
                          _ft_legend_dirty; }      # same reason as keymap= above
    _ft_prop_owed_pay "$name"
    return $rejected
}

# ft_empty NAME — destroy all of NAME's children (recursively) and REOPEN
# NAME as the current container, exactly as if you were back between its
# constructor and its end_ statement. THE rebuild idiom, no parent= ever:
#     ft_empty app
#         ft-frame name=win ...           # same stable names as before
#             ...
#         end_ft_frame
#     end_ft_form                          # close app again (rebuilds focus)
#     ft_refresh
ft_empty() {                     # name
    local name=$1 kid
    for kid in ${FT_KIDS[$name]:-}; do ft_remove "$kid"; done
    FT_KIDS[$name]=""
    FT_PENDING_FOCUS[$name]=""
    ft_dirty "$name"
    FT_NEST_STACK+=("$name")
}

# ── ft_remove NAME — recursively remove ALL bookkeeping for a subtree ───────
# Every property variable, every per-control array entry, keymap overlays,
# accessKey bindings, wrap/extent caches. Call on an old subtree's root right
# after you stop referencing it (rebuilding a screen with the same names
# REQUIRES destroying the old ones first). Deliberately does NOT clear
# FT_FOCUS even if it names a destroyed control — stable-name focus
# persistence depends on the name surviving as a string so the rebuilt
# control with the same name is focused again.
# ── Imperative tree mutation (DOM ChildNode / ParentNode mixins) ──────────────
# Runtime add / move / remove of nodes, for widgets that build their subtree dynamically (a tree
# that adds child nodes as you expand it) — the static DSL can't do that. Names mirror the modern
# DOM: node-relative and consistent with ft_remove (= el.remove). These edit the tree STRUCTURE
# only; call ft_refresh afterwards to relayout. (Create a fresh node with `ft-<type> name=x
# parent=P`, which appends; these move/reorder/replace EXISTING nodes.)
# A MOVED NODE INHERITS FROM SOMEWHERE ELSE NOW. Every other route into "this node's cascade
# inputs changed" invalidates — a property write, ft_unset, a stylesheet
# registration — but the DOM move mixins rewrote FT_PARENT/FT_KIDS and bumped nothing. The
# style caches are keyed on the cascade epoch plus a per-node version, so the resolver went on
# serving the OLD parent's inherited value from a warm entry, and the documented follow-up
# ("call ft_refresh afterwards") repaints FROM that warm entry, so it never healed it.
#
# _ft_css_inval's safety argument — an ancestor's bump walks its subtree, so a descendant is
# reached — is true only for a tree that does not move; this is the case it does not cover.
# The invalidation is the subtree's, because everything below the moved node inherits through
# it, and it is followed by a repaint for the same reason.
_ft_reparented() {              # name — its ancestors changed; re-cascade and repaint it
    [[ -n "${FT_TYPE[$1]:-}" ]] || return 0
    if declare -F _ft_css_inval >/dev/null 2>&1; then _ft_css_inval "$1"
    elif declare -F _ft_css_bump >/dev/null 2>&1; then _ft_css_bump; fi
    _ft_resolve_inval "$1"      # …and an inherited value IS the ancestor chain, for the subtree
    _ft_clip_inval              # a clip rect IS the ancestor chain; this node's just changed
    ft_dirty_subtree "$1"
    return 0
}
_ft_detach() {                  # name — unlink from its current parent's child list (no free)
    local name=$1                      # NB: separate line — `local a=$1 b=${arr[$a]}` reads OLD a
    local par=${FT_PARENT[$name]:-} nk="" k
    [[ -n "$par" && -n "${FT_KIDS[$par]:-}" ]] || return 0
    for k in ${FT_KIDS[$par]}; do [[ "$k" == "$name" ]] || nk+="${nk:+ }$k"; done
    FT_KIDS[$par]=$nk
}
_ft_insert_at() {               # par child ref before|after — splice child next to ref under par
    local par=$1 child=$2 ref=$3 pos=$4 nk="" k found=0
    _ft_is_ancestor "$child" "$par" && return 1   # a ring: every upward walk would spin (see ft_append)
    FT_PARENT[$child]=$par
    for k in ${FT_KIDS[$par]}; do
        [[ "$pos" == before && "$k" == "$ref" ]] && { nk+="${nk:+ }$child"; found=1; }
        nk+="${nk:+ }$k"
        [[ "$pos" == after  && "$k" == "$ref" ]] && { nk+="${nk:+ }$child"; found=1; }
    done
    (( found )) || nk+="${nk:+ }$child"      # ref not under par → append
    FT_KIDS[$par]=$nk
}
# el.cloneNode — copy SRC's type + every property into a NEW control named DST. Shallow by
# default (like the DOM); pass `deep` (or true) to clone the subtree too — descendants get
# GENERATED names (a name is our unique handle, so it can't duplicate; an explicit `id`
# property copies verbatim, and duplicate ids are legal, as in HTML). The clone is DETACHED
# (parent="") — place it with ft_append / ft_before / ft_after. Deviation from the DOM, by
# design: eventListeners is an ordinary property here, so listeners COPY with the clone.
_FT_CLONE_N=0
ft_clone() {                    # SRC DST [deep] → FT_RET=DST
    local src=$1 dst=$2 deep=${3:-}
    [[ -z "${FT_TYPE[$src]:-}" || -z "$dst" ]] && return 1
    FT_TYPE[$dst]=${FT_TYPE[$src]}
    FT_PARENT[$dst]=""; FT_KIDS[$dst]=""; FT_PROPS[$dst]=""
    FT_KEYMAP[$dst]=${FT_KEYMAP[$src]:-}
    FT_FOCUSABLE[$dst]=${FT_FOCUSABLE[$src]:-0}; FT_DRAW[$dst]=${FT_DRAW[$src]:-}
    local p sv
    for p in ${FT_PROPS[$src]:-}; do
        sv="_ftp_${src}_${p}"
        printf -v "_ftp_${dst}_${p}" '%s' "${!sv-}"
        FT_PROPS[$dst]="${FT_PROPS[$dst]:+${FT_PROPS[$dst]} }$p"
    done
    if [[ "$deep" == deep || "$deep" == true ]]; then
        local k nk
        for k in ${FT_KIDS[$src]:-}; do
            nk="${dst}__c$(( _FT_CLONE_N++ ))"
            ft_clone "$k" "$nk" deep || continue
            FT_PARENT[$nk]=$dst
            FT_KIDS[$dst]="${FT_KIDS[$dst]:+${FT_KIDS[$dst]} }$nk"
        done
    fi
    # ft_clone stamps _ftp_<dst>_* straight into the shell with printf -v — it is the one route
    # that writes a property without going through _ft_setprop, so the bump below is the only
    # one it gets. It also plants a new node (and, deep, a new subtree) into the tree.
    _ft_clip_inval
    _ft_resolve_inval "$dst"    # every property at once, and DST's name may have been reused
    ft_dirty "$dst"
    FT_RET=$dst
}
# parent.append(child) — to the end of PARENT. Refused when the child is the parent, or an
# ANCESTOR of it: either makes a ring, and every upward walk then spins forever (see
# _ft_enclosing_form_of). The DOM raises HierarchyRequestError for the same move.
ft_append()       { _ft_is_ancestor "$2" "$1" && return 1
                    _ft_detach "$2"; FT_PARENT[$2]=$1; FT_KIDS[$1]="${FT_KIDS[$1]:+${FT_KIDS[$1]} }$2"
                    _ft_reparented "$2"; }
ft_before()       { local p=${FT_PARENT[$1]:-}; [[ -n "$p" ]] || return 1; _ft_detach "$2"; _ft_insert_at "$p" "$2" "$1" before || return 1; _ft_reparented "$2"; }  # ref.before(node)
ft_after()        { local p=${FT_PARENT[$1]:-}; [[ -n "$p" ]] || return 1; _ft_detach "$2"; _ft_insert_at "$p" "$2" "$1" after  || return 1; _ft_reparented "$2"; }  # ref.after(node)
ft_replace_with() { ft_before "$1" "$2"; ft_remove "$1"; }                                                # old.replaceWith(new)

ft_remove() {                   # name — el.remove(): detach from the tree + free the node's state
    local name=$1 kid prop
    # ONE DAMAGE WALK PER REMOVAL, not one per node. ft_remove recurses into its children, and
    # ft_damage_subtree walks a subtree — so damaging in every frame of the recursion is O(N²)
    # rects for an N-node subtree. Rebuilding a css-demo page removes ~100 controls, and the
    # page change got slow enough that the pty gate's next keypress landed before the app had
    # settled: test-notrace saw its two runs end on DIFFERENT PAGES and reported it as phantom
    # residue. The recursion passes `descendant` to say "the top of this removal already did it".
    local descendant=${2:-}
    # REMOVING SOMETHING THAT IS NOT THERE IS A NO-OP, as it is for DOM remove() on a node with
    # no parent. Without this the very next line read FT_KIDS[$name] with no `:-`, which under
    # `set -u` is fatal — and "remove it if it's there" is the natural way to write a caller:
    # ft_focus_ping clears a previous locator beacon before making a new one, so the FIRST press
    # of `.` killed every demo that runs with set -u. The demo simply vanished, with the error
    # going to an alt screen that was already being torn down.
    [[ -n "${FT_TYPE[$name]:-}" ]] || return 0
    # The cells this subtree painted are about to have no owner — damage them so the compositor
    # refills and repaints whatever was underneath. EVERY app that removed an overlay used to
    # hand-roll this, and it could not: `ft_damage $FT_BEACON_EXTENT` is wrong for a bigarrow,
    # so callout-demo reached for a PRIVATE function to erase one. An application cannot be
    # expected to know that a control's ink is not its extent; the control knows, and
    # ft_damage_subtree asks it.
    [[ -z "$descendant" ]] && ft_damage_subtree "$name"
    _ft_detach "$name"          # unlink from the parent's child list (else a runtime-added child dangles)
    for kid in ${FT_KIDS[$name]:-}; do ft_remove "$kid" descendant; done
    # A prototype may define _ft_destroy_<type> to release per-instance transient state
    # (a text field's caret/scroll/edit arrays) so a REBUILT control with the same
    # name doesn't inherit stale scroll position — the tutorial rebuilds prose/code
    # every page, and without this they'd reopen wherever the old one was scrolled.
    local _dfn="_ft_destroy_${FT_TYPE[$name]:-}"
    declare -F "$_dfn" >/dev/null 2>&1 && "$_dfn" "$name"
    _ft_accel_unregister "$name"
    for prop in ${FT_PROPS[$name]}; do
        unset "_ftp_${name}_${prop}"
        unset "FT_COERCED[${name}_${prop}]"
    done
    _ft_clip_inval              # the chain this control was part of no longer has it in it
    unset "_FT_CLIP_CACHE[/$name]"      # …and the entry goes, not just the generation
    _ft_resolve_inval "$name"   # BUMPED, never unset — a rebuild under this name must not read
                                # the dead control's answers (ft_css_forget paid for that once)
    unset "FT_TYPE[$name]" "FT_PARENT[$name]" "FT_KIDS[$name]" "FT_PROPS[$name]"
    unset "FT_ABSOLUTE_X[$name]" "FT_ABSOLUTE_Y[$name]" "FT_MEASURED_WIDTH[$name]" "FT_MEASURED_HEIGHT[$name]" "FT_PREFERRED_WIDTH[$name]" "FT_AVAILABLE_HEIGHT[$name]"
    unset "FT_FOCUSABLE[$name]" "FT_DRAW[$name]" "FT_DIRTY[$name]" "FT_PAINT_RECT[$name]"
    unset "FT_REPAIR[$name]"
    # THE RETAINED BLOCK, and this one is not merely tidiness: `_fti_<name>__writegen` is unset
    # two blocks below, so a control rebuilt under this name starts its write counter at 0 again
    # and would climb back through the very token values the dead one's block is filed under.
    # (Its siblings _FT_CSS_VERSION / _FT_RESOLVE_VERSION are BUMPED instead of unset for exactly
    # that reason — see ft_css_forget. Dropping the value outright is the same guarantee, and it
    # is what bounds the table for an app that creates controls with fresh names.)
    unset "FT_RETAINED_TOKEN[$name]" "FT_RETAINED_BLOCK[$name]"
    unset "FT_ANIM_KEEP[$name]"     # the persistent resume-phase (ft_anim_stop keeps it; destroy must not leak it)
    unset "FT_FOCUS_CAME_FROM[$name]" "FT_FOCUS_CAME_DIR[$name]"    # the arrow trail
    # Per-control side tables. Like properties (_ftp_*), these are namespaced _fti_* so the
    # engine's caches can never alias a variable in the caller's scope.
    unset "_fti_${name}__wrapkey0" "_fti_${name}__wraplines0" \
          "_fti_${name}__wrapkey1" "_fti_${name}__wraplines1" "_fti_${name}__wrapnext"
    unset "_fti_${name}__extkey" "_fti_${name}__exttw" "_fti_${name}__extth"
    unset "_fti_${name}__cells" # ft-table row cell array (no-op for other types)
    unset "_fti_${name}__sig"   # ft-tabs body layout-signature cache
    # The LINE STORE, and the deferred-property flag that points at it. This matters more than
    # the other caches: the store can be AUTHORITATIVE (the property is stale and the lines are
    # the real content), so leaving it behind would let a control created later under the same
    # name inherit a dead document as its own text.
    unset "_fti_${name}__lines" "_fti_${name}__linesgen" "_fti_${name}__linesprop" \
          "_fti_${name}__maxw" "_fti_${name}__nchars" "_fti_${name}__textgen" \
          "_fti_${name}__writegen" \
          "_fti_${name}__rows0" "_fti_${name}__rows1" "_fti_${name}__rowsw0" \
          "_fti_${name}__rowsw1" "_fti_${name}__rowsnext" \
          "_fti_${name}__lochintidx" "_fti_${name}__lochintacc" "_fti_${name}__lochintgen"
    unset "_FT_TEXT_STALE[$name]"
    # RELEASE THE MOUSE. A press captures its target by NAME until the release; removing the
    # control in between (a row that deletes itself) left the capture pointing at a corpse, so
    # the release was delivered to it and the next press had to fight a stale capture.
    [[ "${_FT_MOUSE_DOWN:-}" == "$name" ]] && _FT_MOUSE_DOWN=""
    # TAKE IT OUT OF THE FOCUS RING. Nothing pruned the ring on removal, so a removed
    # control's NAME stayed in it and Tab walked straight onto a control that no longer
    # exists — focus set to a dead name, its draw a no-op, and two associative arrays
    # subscripted with its now-empty type, which bash reports on stderr (the alt screen).
    if (( ${#FT_FOCUS_RING[@]} )); then
        local _i _keep=() _cur=${FT_FOCUS_RING[${FT_FOCUS_INDEX:-0}]:-}
        for _i in "${FT_FOCUS_RING[@]}"; do [[ "$_i" == "$name" ]] || _keep+=("$_i"); done
        if (( ${#_keep[@]} != ${#FT_FOCUS_RING[@]} )); then
            FT_FOCUS_RING=("${_keep[@]}")
            FT_FOCUS_INDEX=0
            for _i in "${!FT_FOCUS_RING[@]}"; do
                [[ "${FT_FOCUS_RING[$_i]}" == "$_cur" ]] && { FT_FOCUS_INDEX=$_i; break; }
            done
        fi
    fi
    # FT_FOCUS is deliberately LEFT ALONE even when it names this control: focus persists by
    # NAME across a rebuild, which is how a wizard keeps your place when its subtree is torn
    # down and re-declared with the same ids (ft_focus_ring_build re-finds it). A name that is
    # never re-created is harmless — _ft_focus_skippable treats a control with no type as
    # unfocusable, so the next Tab moves off it.
    [[ -n "${FT_KEYMAP[$name]:-}" ]] && unset "_fti_${FT_KEYMAP[$name]}__list"
    unset "FT_KEYMAP[$name]"    # unconditionally: a control with no instance keymap still has
                                # an EMPTY entry here, and `-n` skipped exactly those, so the
                                # table grew by one dead key per control ever created.
    # An AD-HOC ladder belongs to this control and dies with it. Left behind, a rebuild that
    # reuses the name would inherit rungs it never asked for — and since an instance ladder
    # overrides its prototype's, that control alone would behave unlike every sibling, with
    # nothing in the app's source to explain why.
    if [[ -n "${FT_RUNLEVELS[$name]:-}" ]]; then
        local _rl
        for _rl in ${FT_RUNLEVELS[$name]}; do unset "FT_RUNLEVEL_KEYMAP[$name:$_rl]"; done
        unset "FT_RUNLEVELS[$name]"
    fi
    # The resolved-style caches are keyed by name too, and only ft-css.bash knows their shape.
    declare -F ft_css_forget >/dev/null 2>&1 && ft_css_forget "$name"
}

# ── Coerce pipeline (unchanged contract) ─────────────────────────────────────
# ft_coerce NAME PROP SUGGESTION — <TYPE>_<PROP>_coerce hook if declared:
# success (exit 0) → FT_RET is the coerced value; failure → FT_RET is an error
# message recorded in FT_ERRORS, suggestion kept. FT_RET-based (fork-free).
declare -A FT_COERCED=()
FT_ERRORS=()

# Hot path. The overwhelming majority of property reads have NO coerce hook,
# so we memoize per TYPE+PROP whether a hook exists (a single declare -F per
# combination, ever) and take a near-empty fast path when there is none — no
# declare -F, no FT_COERCED hash write. This is called thousands of times per
# layout pass; the memo is the difference between a ~330ms and a ~30ms
# rebuild.
declare -A _FT_COERCE_FN=()
# The (type, prop) → coercion-hook lookup, memoised. It is SPLIT OUT of ft_coerce so that a
# caller which already has the value in FT_RET can discover there is no hook and stop there:
# handing a 150KB textfield value to ft_coerce copies it THREE times (into the argument, into
# `local suggestion`, and back into FT_RET) only to get it back unchanged. That was 6.5ms of
# every `ft_resolved_prop value` on a 4000-line field, and nearly every property has no hook at all.
FT_COERCE_HOOK='-'
_ft_coerce_hook() {             # name prop → FT_COERCE_HOOK ('-' when there is none)
    local prop=$2
    [[ $prop == *'['* ]] && { prop=${prop//'['/__}; prop=${prop//']'/}; }
    local type=${FT_TYPE[$1]:-}
    local key="$type $prop"
    FT_COERCE_HOOK=${_FT_COERCE_FN[$key]-}
    if [[ -z "$FT_COERCE_HOOK" ]]; then
        FT_COERCE_HOOK="${type}_${prop}_coerce"
        declare -F "$FT_COERCE_HOOK" >/dev/null 2>&1 || FT_COERCE_HOOK='-'
        _FT_COERCE_FN[$key]=$FT_COERCE_HOOK
    fi
}
ft_coerce() {                   # name prop suggestion → sets FT_RET
    local name=$1 prop=$2 suggestion=$3
    _ft_coerce_hook "$name" "$prop"
    local hook=$FT_COERCE_HOOK          # capture: a hook may itself call ft_coerce
    if [[ "$hook" == '-' ]]; then          # no hook: suggestion passes straight through
        FT_RET=$suggestion
        return 0
    fi
    [[ $prop == *'['* ]] && { prop=${prop//'['/__}; prop=${prop//']'/}; }
    local rc=0 value
    "$hook" "$name" "$prop" "$suggestion" || rc=$?
    if (( rc == 0 )); then
        value=$FT_RET
    else
        value=$suggestion
        FT_ERRORS+=("${name}"$'\t'"${prop}"$'\t'"${FT_RET}")
    fi
    FT_COERCED["${name}_${prop}"]=$value
    FT_RET=$value
}
# ANSWERS IN FT_RET, like every other accessor. It used to print the value to stdout — which
# in a running app is the alt screen — and leave FT_RET holding the property KEY, so the
# fork-free read this framework requires was not merely unavailable but actively wrong. The
# law is stated a few hundred lines above, beside ft_get.
ft_coerced()      { local _ck; _ft_propkey "$2"; _ck=$FT_RET; FT_RET=${FT_COERCED[${1}_${_ck}]-}; }
ft_errors_clear() { FT_ERRORS=(); }
ft_has_errors()   { (( ${#FT_ERRORS[@]} > 0 )); }

# ft_resolved_prop NAME PROP [DEFAULT] → FT_RET — the value this control RESOLVES for a
# property: what the author set, else what an app stylesheet says, else an ancestor's value if
# the property inherits, else the prototype default, else DEFAULT; then coerced to the property's
# type. This is the normal read — every control and every layout pass goes through it.
#
# It is deliberately NOT called "computed": ft_style is the full five-level cascade (the paint
# path, theme included) and this is not that. It is named for what it actually does, which is
# ft_resolve plus a default plus coercion. Its no-inheritance twin is ft_own_prop.
#
# NB the early return is not a micro-optimisation: ft_resolve has ALREADY put the value in
# FT_RET, so with no coercion hook there is nothing left to do, and calling ft_coerce would only
# move the string through three more copies to arrive back where it started.
# THE hot read: one ft_layout of a 21-control tree makes 596 of these. It used to be three
# nested bash function calls — this one, a thin `ft_prop` that added nothing but the default,
# and ft_resolve, plus → _ft_coerce_hook — and a call is ~4.6µs before it does anything, so the
# wrapping cost more than the lookup. The default and the hook's cache read are inlined here;
# ft_resolve is still a call because it is the part that actually does the work. Measured:
# 101µs → 62µs per read. (`ft_prop` outlived that inlining as a public name with no engine
# caller and is gone; ft_resolve is the uncoerced read it wrapped.)
ft_resolved_prop() {
    # THE MEMO, first, because it is the whole read: the four conditions that decided whether to
    # store are settled on the miss path, so a hit is one key, one compare and the default. The
    # note beside _ft_resolve_inval says what an entry depends on and every route that drops one.
    local _memokey=$1$'\x1f'$2
    if [[ "${_FT_RESOLVED_PROP_MEMO_AT[$_memokey]:-}" \
          == "$_FT_RESOLVE_GENERATION:${_FT_RESOLVE_VERSION[$1]:-0}" ]]; then
        FT_RET=${_FT_RESOLVED_PROP_MEMO[$_memokey]}
        (( ${#FT_RET} == 0 )) && FT_RET=${3-}
        return 0
    fi
    local n=$1 p=$2
    ft_resolve "$n" "$p"
    # The coercion hook, from its memo without building a key through a function call. A
    # subscripted prop (text[event]) is cached under its NORMALISED name, so it can never hit
    # here — send those the long way round rather than mis-keying them.
    local h
    case $p in
        *'['*) _ft_coerce_hook "$n" "$p"; h=$FT_COERCE_HOOK ;;
        *)     h=${_FT_COERCE_FN["${FT_TYPE[$n]:-} $p"]-}
               [[ -z "$h" ]] && { _ft_coerce_hook "$n" "$p"; h=$FT_COERCE_HOOK; } ;;
    esac
    # The default is applied AFTER the store, not before it: it is the CALL SITE's, and two
    # callers may pass different ones for the same property. What is stored is ft_resolve's own
    # answer, empty included — "this control resolves nothing here" is an answer worth keeping.
    # "Is it empty" must NOT be asked as `[[ -z "$FT_RET" ]]`: that EXPANDS FT_RET into a word to
    # test it, which on a 4000-line textfield's `value` is 4.7ms — per call, several times a
    # keystroke, to learn one bit. `${#…}` is a scan rather than a copy: 0.4ms. (Measured; the
    # unquoted and `${x:+…}` forms sit in between.)
    if [[ "$h" == '-' ]]; then
        case $p in
            text|value|*-*|*'['*) : ;;      # conditions 1 and 2
            *) [[ -n "${_FT_CSS_DECLARED_PROPS[$p]:-}" ]] || {        # condition 3
                   _FT_RESOLVED_PROP_MEMO[$_memokey]=$FT_RET
                   _FT_RESOLVED_PROP_MEMO_AT[$_memokey]="$_FT_RESOLVE_GENERATION:${_FT_RESOLVE_VERSION[$1]:-0}"
               } ;;
        esac
        (( ${#FT_RET} == 0 )) && FT_RET=${3-}
        return 0
    fi
    (( ${#FT_RET} == 0 )) && FT_RET=${3-}
    ft_coerce "$n" "$p" "$FT_RET"
}
# ft_own_prop answers "what is this ELEMENT's value", with no inheritance — which now includes what
# its PROTOTYPE declares, because that is the element's own value in the absence of an author one.
# "Own" is JavaScript's word for exactly this distinction (hasOwnProperty: mine, not the
# prototype chain's), and docs/api-naming.md says to take the DOM's vocabulary as it stands.
# _ft_get_raw stays the narrower question, "what did the AUTHOR set", and is what cascade level
# 1 asks; the two were the same function's job while defaults were stamped onto instances.
#
# THIS IS NOT A CONVENIENCE. Twenty layout call sites read `position` this way, and a beacon's
# `position=absolute` is a prototype default: unresolved, every overlay in the framework would join
# the normal layout flow. `_ft_in_flow` is the one that would have made it visible.
ft_own_prop() {                 # name prop → FT_RET (the element's own value, coerced; no inheritance)
    local var                                       # same fast path as _ft_get_raw
    case $2 in
        --*|*'['*) _ft_propkey "$2"; var="_ftp_${1}_${FT_RET}" ;;
        text|value) [[ "${_FT_TEXT_STALE[$1]:-}" == "$2" ]] && _ft_text_join "$1"
                   var="_ftp_${1}_${2}" ;;
        *)         var="_ftp_${1}_${2}" ;;
    esac
    # …and the SHEET, through the same gate the layout's other reads take. `width`, `height`,
    # `left`, `top` and `position` are read through here by twenty layout call sites, and none
    # of them is an inheriting property — which is exactly the restriction below, so ft_own_prop's
    # "no inheritance" contract is kept to the letter: the cascade is only consulted for
    # properties it could not inherit anyway.
    if [[ ! -v "$var" && -n "${_FT_CSS_DECLARED_PROPS[$2]:-}" ]] && _ft_gated_style_own "$1" "$2"; then
        _FT_PROTO_DEFAULT_SCRATCH=$FT_RET; var=_FT_PROTO_DEFAULT_SCRATCH
    fi
    [[ -v "$var" ]] || { _ft_prototype_default_var "$1" "$2"; var=$FT_RET; }
    local h                                         # hook memo read inline (see ft_resolved_prop)
    case $2 in
        *'['*) _ft_coerce_hook "$1" "$2"; h=$FT_COERCE_HOOK ;;
        *)     h=${_FT_COERCE_FN["${FT_TYPE[$1]:-} $2"]-}
               [[ -z "$h" ]] && { _ft_coerce_hook "$1" "$2"; h=$FT_COERCE_HOOK; } ;;
    esac
    [[ "$h" == '-' ]] && { FT_RET="${!var-}"; return 0; }
    ft_coerce "$1" "$2" "${!var-}"
}

# ── Box model helpers ────────────────────────────────────────────────────────
FT_RET=0
# border/padding/margin are read straight from their property variables, for the same reason
# as `display` above: layout properties, never inherited, no coercion hooks, prototype-defaulted.
# A layout asks for them ~400 times; going through ft_resolved_prop cost ~62µs each against ~10µs
# here. THE RAW FAST PATHS BELOW EACH GAINED A SECOND READ, and it is not optional now that a
# prototype default is no longer stamped onto the instance. `_ft_disp` is the one that matters:
# `display` is asked 479 times in one layout of a 37-control page, more than every other property
# put together, and without the prototype value every option, table row and tree node would stop
# being `display: none` and every button would stop being inline-block. `_ft_border` is why a frame
# has a border at all, and `_ft_inset4` is why a tab strip keeps its three rows.
_ft_border()  { local v="_ftp_${1}_border"; v=${!v-}
                (( ${#v} )) || { [[ -n "${_FT_CSS_FASTPATH_DECLARED:-}" ]] && { _ft_gated_style "$1" border && v=$FT_RET; }; }
                (( ${#v} )) || { [[ -n "${1:-}" ]] && v=${FT_PROTO_DEFAULT["${FT_TYPE[$1]:-} border"]-}; }
                FT_RET=0
                [[ -n "${1:-}" && ( "$v" == true || "$v" == 1 ) ]] || return
                _ft_border_off "$1" "${FT_TYPE[$1]:-}" || FT_RET=1; }
# The VOCABULARY of borderStyle, in one place, because one property name may not mean two
# different things: ft-table has always taken none|solid|heavy|double|rounded|dashed while
# ft-frame took solid|double|dashed|dotted, so `borderStyle=heavy` drew heavy glyphs on a table
# and light ones on a frame — and ft-help's About window asks a FRAME for `rounded` and has been
# getting square corners since it was written. `heavy` and `rounded` are this framework's
# spellings of borderWidth=thick and borderRadius=1; the rest is CSS's own list, minus the four
# bevels (groove/ridge/inset/outset) that a terminal has no glyphs for and that therefore
# normalize to what they would be drawn as. An unrecognised keyword does the same, so a typo
# reads back as the thing on screen instead of as itself.
_ft_border_style() {            # value → FT_RET (a keyword every border renderer draws)
    FT_RET=${1,,}
    case $FT_RET in
        ''|none|hidden|solid|double|dashed|dotted|heavy|rounded) ;;
        *) FT_RET=solid ;;
    esac
}
# borderWidth's vocabulary, and the same rule. CSS takes thin|medium|thick or a `<length [0,∞]>`,
# and a TUI border is always exactly ONE CELL — so a length answers only one question here, "is
# there a border at all": `0` is CSS's own removal spelling, and any positive length is one cell,
# which is `thin`. `none` is not CSS's word for a width, but it is the one ft-beacon has always
# accepted for this job (docs/styling-model.md §8), so it normalizes to 0 rather than meaning
# something different one control over. `5px` and `zzz` read back as themselves and drew thin.
_ft_border_width() {            # value → FT_RET (a keyword every border renderer draws)
    FT_RET=${1,,}
    case $FT_RET in
        ''|thin|medium|thick) ;;
        none|0) FT_RET=0 ;;
        *)      FT_RET=thin ;;
    esac
}
# A DECORATIVE BORDER GLYPH IS ONE COLUMN. borderGlyph tiles a single glyph across all four
# sides, one per cell, so a two-column one paints twice the box: measured, `borderGlyph=🌸` on a
# 20-column frame drew a 40-column top rule, over whatever was beside it — and `borderGlyph=ab`
# did the same with two ordinary characters. There is no honest tiling of a double-width glyph
# into an arbitrary width (some cell has to be half a flower), so this is the one border value
# that cannot be corrected into something drawable, and CSS's answer to that is to drop the
# declaration. Loudly, because a border that silently refuses to change is worse than an error.
_ft_border_glyph_fits() {       # name value → status 1 (with a message) when it cannot tile
    (( ${#2} == 0 )) && return 0                   # cleared: no decorative border, which is fine
    ft_display_width "$2"
    (( FT_DISPLAY_WIDTH == 1 )) && return 0
    printf 'ft: %s: borderGlyph="%s" is %s columns wide, not 1 — declaration dropped\n' \
        "$1" "$2" "$FT_DISPLAY_WIDTH" >&2
    return 1
}
# `border-style: none|hidden` and `border-width: 0` are CSS's own spellings of "no border", and
# in CSS both make the used border-width 0 — the box gets SMALLER, which is why this is part of
# the box model and not of a draw function. The bigarrow already honoured both
# (docs/styling-model.md §8); the frame honoured neither, so `borderStyle=none` painted a full
# solid box. Asked ONLY of a control that has a border at all, so the four-in-five controls that
# have none never pay for the reads.
_ft_border_off() {              # name type → status 0 when the style or the width removes it
    local v="_ftp_${1}_borderStyle"; v=${!v-}
    (( ${#v} )) || { [[ -n "${_FT_CSS_FASTPATH_DECLARED:-}" ]] && { _ft_gated_style "$1" borderStyle && v=$FT_RET; }; }
    (( ${#v} )) || { [[ -n "$2" ]] && v=${FT_PROTO_DEFAULT["$2 borderStyle"]-}; }
    case $v in none|hidden) return 0 ;; esac
    v="_ftp_${1}_borderWidth"; v=${!v-}
    (( ${#v} )) || { [[ -n "${_FT_CSS_FASTPATH_DECLARED:-}" ]] && { _ft_gated_style "$1" borderWidth && v=$FT_RET; }; }
    (( ${#v} )) || { [[ -n "$2" ]] && v=${FT_PROTO_DEFAULT["$2 borderWidth"]-}; }
    case $v in 0|none) return 0 ;; *) return 1 ;; esac
}
_ft_padding() { local v="_ftp_${1}_padding"; FT_RET=${!v-}
                (( ${#FT_RET} )) && return
                [[ -n "${_FT_CSS_FASTPATH_DECLARED:-}" ]] && { _ft_gated_style "$1" padding && return; }
                [[ -n "${1:-}" ]] && FT_RET=${FT_PROTO_DEFAULT["${FT_TYPE[$1]:-} padding"]-} || FT_RET=""
                (( ${#FT_RET} )) || FT_RET=0; }
_ft_inset()   { local b p; _ft_border "$1"; b=$FT_RET; _ft_padding "$1"; p=$FT_RET; FT_RET=$(( b + p )); }
# Per-side margin = uniform margin + that side's marginTop/Right/Bottom/Left, exactly as
# _ft_inset4 does for padding. The four per-side properties were registered and accepted by the
# DSL from the start, but the only reader was a `_ft_margin` that returned the UNIFORM value and
# nothing else — so `marginTop=2` parsed, validated, stored, and then changed no geometry at
# all. A property the author can set and the layout never reads is worse than one that does not
# exist: it fails silently, and it fails looking correct.
#
# Sets four globals, and callers capture them into locals the moment a nested layout pass could
# intervene — _ft_pass_height and _ft_pass_arrange recurse into the children, which overwrites
# these before the parent is finished with them.
FT_MARGIN_TOP=0; FT_MARGIN_RIGHT=0; FT_MARGIN_BOTTOM=0; FT_MARGIN_LEFT=0
# Each component is the same three-step ladder the framework resolves everywhere: what the author
# set, else what a stylesheet says, else what the prototype defaults. The sheet step is guarded by
# one flag rather than a keyed read per property, because with no sheet declaring a box property
# there is nothing there to find; the prototype step is a field of the tuple, already defaulted.
_ft_margin4() {                 # name → FT_MARGIN_TOP / FT_MARGIN_RIGHT / FT_MARGIN_BOTTOM / FT_MARGIN_LEFT
    local n=$1 v base sheet=${_FT_CSS_FASTPATH_DECLARED:-}
    local ty=${FT_TYPE[$n]:-}
    if [[ -n "$ty" ]]; then set -- ${FT_PROTO_MARGIN_BOX[$ty]:-0 0 0 0 0}   # …and its sibling,
    else                    set -- 0 0 0 0 0                                # for the same reason
    fi
    v="_ftp_${n}_margin";       v=${!v-}
    (( ${#v} )) || { [[ -n "$sheet" ]] && _ft_gated_style "$n" margin && v=$FT_RET; }
    (( ${#v} )) || v=$1;        base=$v
    v="_ftp_${n}_marginTop";    v=${!v-}
    (( ${#v} )) || { [[ -n "$sheet" ]] && _ft_gated_style "$n" marginTop && v=$FT_RET; }
    (( ${#v} )) || v=$2;        FT_MARGIN_TOP=$(( base + v ))
    v="_ftp_${n}_marginRight";  v=${!v-}
    (( ${#v} )) || { [[ -n "$sheet" ]] && _ft_gated_style "$n" marginRight && v=$FT_RET; }
    (( ${#v} )) || v=$3;        FT_MARGIN_RIGHT=$(( base + v ))
    v="_ftp_${n}_marginBottom"; v=${!v-}
    (( ${#v} )) || { [[ -n "$sheet" ]] && _ft_gated_style "$n" marginBottom && v=$FT_RET; }
    (( ${#v} )) || v=$4;        FT_MARGIN_BOTTOM=$(( base + v ))
    v="_ftp_${n}_marginLeft";   v=${!v-}
    (( ${#v} )) || { [[ -n "$sheet" ]] && _ft_gated_style "$n" marginLeft && v=$FT_RET; }
    (( ${#v} )) || v=$5;        FT_MARGIN_LEFT=$(( base + v ))
}
# Per-side inset = border + uniform padding + that side's paddingTop/Right/
# Bottom/Left (each 0 by default, so this reduces to the symmetric _ft_inset for
# every control that doesn't ask for asymmetric padding). Sets four globals;
# callers capture them into locals right away (a nested layout pass would
# otherwise clobber them).
FT_INSET_TOP=0; FT_INSET_RIGHT=0; FT_INSET_BOTTOM=0; FT_INSET_LEFT=0
# HOT PATH (per control, per layout pass, per clip). padding + the four per-side
# paddings are always set LOCALLY (base-prototype defaults, never inherited) and are
# plain integers needing no coercion — so read them straight from the shell vars
# (fork-free, no ft_resolved_prop coerce/resolve overhead). This keeps a tab switch (a
# full subtree relayout) snappy.
#
# `tabs` is why the prototype step cannot simply answer 0: it reserves paddingTop=3 for its own tab
# strip, and without the prototype value the tab body draws over the strip.
_ft_inset4() {                  # name → FT_INSET_TOP / FT_INSET_RIGHT / FT_INSET_BOTTOM / FT_INSET_LEFT (incl. any scroll gutter)
    local n=$1 b v base ty=${FT_TYPE[$1]:-} sheet=${_FT_CSS_FASTPATH_DECLARED:-}
    # A control an earlier handler in this burst removed has NO TYPE, and ${ASSOC[""]} is a bash
    # error on stderr — which in a TUI is the alt screen. _ft_border already guards its
    # prototype read for exactly this reason; these two did not, and the hole became reachable the
    # moment `overflow` turned layout-kind and a write to it began scheduling a reflow of its own.
    if [[ -n "$ty" ]]; then set -- ${FT_PROTO_INSET_BOX[$ty]:-0 0 0 0 0 0 - - -}
    else                    set -- 0 0 0 0 0 0 - - -
    fi
    v="_ftp_${n}_border";        v=${!v-}
    (( ${#v} )) || { [[ -n "$sheet" ]] && _ft_gated_style "$n" border && v=$FT_RET; }
    (( ${#v} )) || v=$1
    b=0
    [[ "$v" == true || "$v" == 1 ]] && { _ft_border_off "$n" "$ty" || b=1; }
    v="_ftp_${n}_padding";       v=${!v-}
    (( ${#v} )) || { [[ -n "$sheet" ]] && _ft_gated_style "$n" padding && v=$FT_RET; }
    (( ${#v} )) || v=$2;         base=$(( b + v ))
    v="_ftp_${n}_paddingTop";    v=${!v-}
    (( ${#v} )) || { [[ -n "$sheet" ]] && _ft_gated_style "$n" paddingTop && v=$FT_RET; }
    (( ${#v} )) || v=$3;         FT_INSET_TOP=$(( base + v ))
    v="_ftp_${n}_paddingRight";  v=${!v-}
    (( ${#v} )) || { [[ -n "$sheet" ]] && _ft_gated_style "$n" paddingRight && v=$FT_RET; }
    (( ${#v} )) || v=$4;         FT_INSET_RIGHT=$(( base + v ))
    v="_ftp_${n}_paddingBottom"; v=${!v-}
    (( ${#v} )) || { [[ -n "$sheet" ]] && _ft_gated_style "$n" paddingBottom && v=$FT_RET; }
    (( ${#v} )) || v=$5;         FT_INSET_BOTTOM=$(( base + v ))
    v="_ftp_${n}_paddingLeft";   v=${!v-}
    (( ${#v} )) || { [[ -n "$sheet" ]] && _ft_gated_style "$n" paddingLeft && v=$FT_RET; }
    (( ${#v} )) || v=$6;         FT_INSET_LEFT=$(( base + v ))
    # A PROPERTY DRAWN ON THE TOP EDGE NEEDS THAT ROW. A frame's title is painted over its top
    # border, so a bordered frame's title row is the one `b` already reserved — but with no
    # border there is nothing holding it, and the title landed in the content area where the
    # first child painted straight over it. A <fieldset> keeps room for its <legend> whatever
    # border-style says, and so does this. Tested field-first (a name, not a flag) because
    # every prototype but the frame answers `-` and stops here for the price of one comparison.
    if [[ "$9" != - ]] && (( ! b )); then
        v="_ftp_${n}_$9";        v=${!v-}
        (( ${#v} )) || { [[ -n "$sheet" ]] && _ft_gated_style "$n" "$9" && v=$FT_RET; }
        (( ${#v} )) && FT_INSET_TOP=$(( FT_INSET_TOP + 1 ))
    fi
    # STABLE scroll gutters (CSS scrollbar-gutter: stable): a vertically scrollable container
    # (overflow=auto|scroll) reserves its rightmost column for the bar; a horizontally scrollable
    # one (overflowX=auto|scroll) its bottom row. Reserved in the INSET so every pass — measure,
    # arrange, clip — agrees, and children can never occupy (or be painted over by) the bar.
    v="_ftp_${n}_overflow";      v=${!v-}
    (( ${#v} )) || { [[ -n "$sheet" ]] && _ft_gated_style "$n" overflow && v=$FT_RET; }
    (( ${#v} )) || v=$7
    case $v in auto|scroll) FT_INSET_RIGHT=$(( FT_INSET_RIGHT + 1 )) ;; esac
    v="_ftp_${n}_overflowX";     v=${!v-}
    (( ${#v} )) || { [[ -n "$sheet" ]] && _ft_gated_style "$n" overflowX && v=$FT_RET; }
    (( ${#v} )) || v=$8
    case $v in auto|scroll) FT_INSET_BOTTOM=$(( FT_INSET_BOTTOM + 1 )) ;; esac
}

_ft_clamp() {                   # value min max → FT_RET (empty min/max = unbounded)
    local v=$1 mn=$2 mx=$3
    [[ -n "$mn" ]] && (( v < mn )) && v=$mn
    [[ -n "$mx" ]] && (( v > mx )) && v=$mx
    FT_RET=$v
}
# min/max read straight from their variables, as border/padding/margin/display do above — they
# are layout properties: non-inheriting, no coercion hook, and set locally or not at all. These
# two run per control per pass, so the four reads were ~250 ft_resolved_prop calls per layout.
_ft_clamp_w() {                 # name value → FT_RET  (outer width, minWidth/maxWidth)
    local v mn mx
    v="_ftp_${1}_minWidth"; mn=${!v-}
    v="_ftp_${1}_maxWidth"; mx=${!v-}
    _ft_clamp "$2" "$mn" "$mx"
}
_ft_clamp_h() {                 # name value → FT_RET  (outer height, minHeight/maxHeight)
    local v mn mx
    v="_ftp_${1}_minHeight"; mn=${!v-}
    v="_ftp_${1}_maxHeight"; mx=${!v-}
    _ft_clamp "$2" "$mn" "$mx"
}

# ── Colour overrides ─────────────────────────────────────────────────────────
_ft_color_override() {          # name prop channel(38|48) → sets FT_RET (escape or "")
    local name=$1 prop=$2 channel=$3 val
    # LIVE CSS ANIMATION: a control declaring `animation: NAME` (a @keyframes) cycles its
    # FOREGROUND. Checked first so it wins, and armed/disarmed as the cascade changes —
    # editing the stylesheet and re-applying it turns it on or off, no wiring.
    if [[ "$prop" == color && "$channel" == 38 && -n "${_FT_CSS_LOADED:-}" ]]; then
        if _ft_css_anim_fg "$name"; then return; fi
        # Element isn't animating. Only when a loop is actually armed do we check whether a
        # STRUCTURE (::scrollbar, …) still wants it — else disarm. (Cheap: skips the pe scan
        # entirely for the common case of a control with no animation loop running.)
        [[ -n "${FT_CSS_ANIMATION_ON[$name]:-}" ]] && { _ft_css_wants_anim "$name" || _ft_css_anim_disarm "$name"; }
    fi
    # Value resolves through the cascade: inline (call-site) → app stylesheets → legacy
    # (old inheritance + coercion). ADDITIVE — with no matching stylesheet rule this is
    # exactly the previous ft_resolved_prop result, so an unstyled control is byte-for-byte
    # unchanged; a rule only ever adds a source that sits between inline and inheritance.
    _ft_get_raw "$name" "$prop"; val=$FT_RET
    if [[ -z "$val" && -n "${_FT_CSS_LOADED:-}" ]]; then
        _ft_css_query "$name" "$prop" app
        (( _QGOT )) && { _ft_css_resolve_value "$name" "$FT_RET"; val=$FT_RET; }
    fi
    [[ -z "$val" ]] && { ft_resolved_prop "$name" "$prop"; val=$FT_RET; }
    # AN INHERITED PROPERTY MUST BE ASKED OF THE CASCADE, NOT OF ANCESTORS' RAW PROPERTIES.
    # ft_resolved_prop above inherits through ft_resolve, which walks ancestors reading the property
    # VARIABLE — so a value an ancestor got from a STYLESHEET RULE is invisible to it. `color`
    # is the canonical inherited property in CSS, and the cascade had the right answer all
    # along (ft_style said 196); only the paint asked the narrower question, so a label under
    # `#panel { color: 196 }` drew in the default foreground. An inline `color=` on the same
    # ancestor did work, which is why this survived: apps set colours inline.
    #
    # ASKED ONLY WHEN THE PROPERTY ACTUALLY INHERITS, and that restraint is load-bearing.
    # ft_style also applies a prototype's built-in default, so asking it for `backgroundColor` on
    # an unstyled label answers a real colour where the engine requires NOTHING — an unset
    # background must stay a HOLE showing whatever is behind it. Background does not inherit,
    # so it never reaches this line and keeps its hole; the ancestor's background still floors
    # the cell through _ft_inherited_bg, which is a separate mechanism and untouched.
    if [[ -z "$val" && -n "${_FT_CSS_LOADED:-}" ]] \
       && [[ "$prop" == --* || -n "${FT_INHERITED_PROP[$prop]:-}" ]]; then
        ft_style "$name" "$prop"; val=$FT_RET
    fi
    FT_RET=""
    [[ -z "$val" ]] && return
    # THEME-ADAPTIVE text roles: instead of a literal colour (which may clash on
    # another theme — e.g. gold text on a white body), name a ROLE and each theme
    # supplies a value that reads well on its own background. Foreground only.
    if [[ "$channel" == 38 ]]; then
        case "$val" in
            notice) FT_RET=${FT_COLOR_TEXT_NOTICE:-}; return ;;   # a highlighted note
            accent) FT_RET=${FT_COLOR_TEXT_ACCENT:-}; return ;;   # the theme's accent
            muted)  FT_RET=${FT_COLOR_TEXT_MUTED:-};  return ;;   # de-emphasised
        esac
    fi
    # Route through the depth pipeline: #hex / rgb: / r,g,b become 24-bit (or the
    # nearest 256/16/8 colour for the current FT_COLOR_MODE); names/indices stay
    # 256. FT_RET is the SGR escape, or "" on an unknown colour.
    ft_color_sgr "$val" "$channel"
    [[ -n "$FT_RET" ]] || FT_ERRORS+=("${name}"$'\t'"${prop}"$'\t'"unknown color '$val'")
}

# _ft_compose_sgr NAME → FT_RET = the ONE painted SGR for a control's text: the theme body,
# then the cascade's background-color / color / font-weight(bold) / text-decoration(underline),
# then disabled dimming. This is the single compose point a control paints through instead of
# hand-assembling FT_COLOR_* globals and attribute escapes — so font-weight and text-decoration
# now work on ANY control that uses it, and the animated foreground (via _ft_color_override)
# is picked up for free. Close the span with FT_COLOR_RESET (a clean-slate reset).
# Composing a control's drawing escape is the most expensive thing a paint does — measured at
# ~810µs, against 30µs for a cached style lookup (tools/bench-cascade.bash). A control asks for
# it repeatedly while drawing, and every control asks on every repaint, so the same answer is
# recomputed dozens of times per frame.
#
# The result depends on: the stylesheet generation, this control's own cascade version, focus,
# the root, the caller's base sequence — and, for a control running a @keyframes animation, the
# CURRENT ANIMATION PHASE, because `_ft_color_override` resolves the animated foreground inside
# here. Leaving the phase out of the key would freeze every animation, and a golden screenshot
# would not notice: a frozen animation still matches a static snapshot.
declare -A _FT_SGR_CACHE=()
_ft_compose_sgr() {             # name [basesgr=FT_COLOR_BODY] → FT_RET
    local _cache_token="${_FT_CSS_EPOCH:-0}:${_FT_CSS_VERSION[$1]:-0}:${FT_FOCUS:-}:${FT_ROOT:-}:${2-}"
    [[ -n "${FT_CSS_ANIMATION_ON[$1]:-}" ]] && _cache_token+=":${FT_ANIM_PHASE[$1]:-0}"
    local _cached=${_FT_SGR_CACHE[$1]:-}
    if [[ -n "$_cached" && "${_cached%%$'\x1f'*}" == "$_cache_token" ]]; then
        FT_RET=${_cached#*$'\x1f'}
        return
    fi
    _ft_compose_sgr_uncached "$@"
    _FT_SGR_CACHE[$1]="$_cache_token"$'\x1f'"$FT_RET"
}
# WHAT IS BEHIND THIS CONTROL. CSS's initial `background-color` is `transparent`: an element
# that declares none shows whatever its ancestors painted. A terminal cell has no such thing
# as transparent — a write that establishes no background leaves the cell on whatever
# background is current, and since every write ends in a reset, that is the TERMINAL's colour.
# The app then has a hole in it: residue that matches no theme, black on a light terminal,
# invisible on a dark one, and different from cell to cell depending on what painted last.
#
# So transparency is resolved HERE, the way a browser resolves it — walk up to the nearest
# ancestor that actually declares a background and use that. Only when nothing in the chain
# does (the control is not inside anything that paints) does it fall back to the theme's own
# surface. The answer is always a real colour, never "leave it to the terminal".
_ft_inherited_bg() {            # name → FT_RET (a background SGR — never empty)
    local n=${FT_PARENT[$1]:-}
    while [[ -n "$n" ]]; do
        _ft_color_override "$n" backgroundColor 48
        [[ -n "$FT_RET" ]] && return 0
        n=${FT_PARENT[$n]:-}
    done
    # The theme surface — what a form fills its box with — but ONLY ITS BACKGROUND HALF.
    # FT_COLOR_BODY is a bg+fg PAIR, and the single caller appends its own base straight after
    # this, so returning the pair emitted the entire sequence TWICE for every control with no
    # ancestor background — which is most of them, on every cell of every frame. Returning
    # empty instead is not an option: a base may legitimately be foreground-only
    # (FT_COLOR_VIEW is `fg 44` and nothing else), and then the cell would fall through to the
    # terminal's own colour, which is the hole this whole function exists to prevent.
    local _surface=$FT_COLOR_BODY
    [[ "$_surface" == *';38;'* ]] && _surface="${_surface%%;38;*}m"
    FT_RET=$_surface
}
# ── Used values ──────────────────────────────────────────────────────────────
# The cascade answers what an element SPECIFIES, and "" is the honest answer when nothing
# declares a colour. But in CSS an element always HAS one: `color` inherits, and where the
# whole chain is silent the initial value applies. Anything that has to modulate a colour —
# an opacity ramp dimming text toward the surface behind it — is asking the second question,
# and "" gives it nothing to work with. `animation: pulse` composed the empty string at every
# one of its frames and the animation was simply invisible, at the cost of a full repaint per
# frame. Making the CASCADE return a colour would be wrong (every control's painted bytes
# depend on _ft_color_override's "" meaning "no override"); resolving the USED value at the
# point that needs one is the fix. Same shape as _ft_inherited_bg above, which already refuses
# to hand a background back to the terminal.
#
# Both return a colour VALUE, never an SGR, because that is what _ft_css_blend and
# _ft_css_params consume. Both always succeed: a bare call in a `set -e` app must not be able
# to kill the shell, so "no colour anywhere" is reported as an empty FT_RET, not a status.
_ft_used_color() {              # name → FT_RET (a colour value; "" only if the theme sets no fg)
    ft_style "$1" color
    [[ -n "$FT_RET" ]] && return 0
    # Nothing specified it and nothing up the chain inherits one, so the initial value applies.
    # For a terminal that is the theme body's foreground half — the mirror of _ft_inherited_bg
    # falling back to the same variable's background half.
    if ft_sgr_rgb "$FT_COLOR_BODY" 38
        then FT_RET="$FT_RGB_RED,$FT_RGB_GREEN,$FT_RGB_BLUE"
        else FT_RET=""              # mono mode: there is genuinely no colour to name
    fi
    return 0
}
_ft_used_background_color() {   # name → FT_RET (a colour value; "" only in mono mode)
    ft_style "$1" backgroundColor
    [[ -n "$FT_RET" ]] && return 0
    # _ft_effective_bg answers what actually shows through at this control: its own background,
    # else the nearest ancestor that paints one, else the frame body or the screen.
    _ft_effective_bg "$1"
    if ft_sgr_rgb "$FT_RET" 48
        then FT_RET="$FT_RGB_RED,$FT_RGB_GREEN,$FT_RGB_BLUE"
        else FT_RET=""
    fi
    return 0
}

_ft_compose_sgr_uncached() {    # name [basesgr=FT_COLOR_BODY] → FT_RET
    local name=$1 base=${2:-$FT_COLOR_BODY} bg fg attrs=""
    _ft_color_override "$name" backgroundColor 48; bg=$FT_RET
    _ft_color_override "$name" color 38;           fg=$FT_RET
    if [[ -n "${_FT_CSS_LOADED:-}" ]]; then
        ft_style "$name" fontWeight;     [[ "$FT_RET" == bold ]]      && attrs+=$FT_ANSI_BOLD
        ft_style "$name" textDecoration; [[ "$FT_RET" == underline ]] && attrs+=$FT_ANSI_UNDERLINE
    fi
    # The inherited background goes FIRST, so anything the base or the cascade sets overrides
    # it — it is the floor, not an override. Costs one ancestor walk on a compose MISS only.
    _ft_inherited_bg "$name"; local under=$FT_RET
    _ft_dim_if_disabled "$name" "$under$base$bg$fg$attrs"
}

# _ft_css_pe_or CONTROL PE FALLBACK → FT_RET = the SGR a STATE/STRUCTURE pseudo-element
# declares (`tabs::active`, `tree::active`, `table::selected`, `::header`, …), or FALLBACK
# when no rule touches it. Additive — an unstyled control is byte-identical to the role it
# used before. Animation-aware (ft_sgr_pseudo_element), and degrades gracefully if ft-css isn't loaded.
_ft_css_pe_or() {               # control pe fallbackSgr → FT_RET
    if [[ -n "${_FT_CSS_LOADED:-}" ]]; then ft_sgr_pseudo_element "$1" "$2"; [[ -n "$FT_RET" ]] && return; fi
    FT_RET=$3
}

# NB: the detached TYPE PROBE (_ft_css_type_probe / _ft_css_type_sgr / _ft_css_type_pe_sgr)
# lived here. It existed solely so the nameless immediate-mode painters (ft-title,
# ft-boxheader, ft-section-header, ft-synopsis) could obey `title { … }` without being real
# controls. Those painters are gone — boxheader/heading are proper controls that style
# through the ordinary cascade, and title/synopsis are covered by `ft-frame title=` and
# `ft-statusbar status=` — so the probe went with them.

# ── Text extent (display-width aware) ────────────────────────────────────────
FT_TEXT_WIDTH=0; FT_TEXT_HEIGHT=0
_ft_text_extent() {
    local text=$1
    FT_TEXT_WIDTH=0; FT_TEXT_HEIGHT=0
    [[ -z "$text" ]] && { FT_TEXT_HEIGHT=1; return; }
    local line
    while IFS= read -r line; do
        ft_display_width "$line"; (( FT_DISPLAY_WIDTH > FT_TEXT_WIDTH )) && FT_TEXT_WIDTH=$FT_DISPLAY_WIDTH
        (( FT_TEXT_HEIGHT++ ))
    done <<< "$text"
}
# Memoized per control name — text scans and wraps are the expensive pure-bash
# loops; scrolling and redraws must never re-pay them for unchanged text.
# GEN (optional) is the control's text generation — pass it ONLY when TEXT is the control's
# own text/value property, which is what the counter tracks. Given it, a hit is an integer
# compare instead of a full string compare (4ms on a 1000-line log, every layout pass).
# Controls that pass COMPOSED text (a radio's label+state, say) must omit it and keep the
# string compare, which stays correct however the text was built.
_ft_text_extent_cached() {      # name text [gen] → sets FT_TEXT_WIDTH/FT_TEXT_HEIGHT
    local name=$1 text=$2 gen=${3-}
    local keyvar="_fti_${name}__extkey" twvar="_fti_${name}__exttw" thvar="_fti_${name}__extth"
    local genvar="_fti_${name}__extgen"
    if [[ -n "$gen" ]]; then
        if [[ "${!genvar-}" == "$gen" ]]; then FT_TEXT_WIDTH=${!twvar}; FT_TEXT_HEIGHT=${!thvar}; return; fi
    # `-v` FIRST, AND THAT IS NOT A FORMALITY — it is the difference between "nothing is cached"
    # and "the empty string is cached". Without it, `${!keyvar-}` answers "" for a control whose
    # extent has never been measured, which EQUALS an empty TEXT argument, so the test reported a
    # HIT and the next expression read ${!twvar} — a variable that does not exist. In a `set -u`
    # app, which is what this framework's apps are, that is a fatal unbound variable, printed to
    # stderr, which in a TUI is the alt screen.
    #
    # Reached for real: _ft_sb_target_extent asks this about its target's `text`, and a target
    # that is not a label — a div, a table, a textfield — has none. So `ft-scrollbar for=pane`
    # killed the frame it was drawn in. Absent versus empty, one more time.
    elif [[ -v $keyvar && "${!keyvar}" == "$text" ]]; then
        FT_TEXT_WIDTH=${!twvar}; FT_TEXT_HEIGHT=${!thvar}
        return
    fi
    _ft_text_extent "$text"
    printf -v "$keyvar" '%s' "$text"
    printf -v "$twvar" '%s' "$FT_TEXT_WIDTH"
    printf -v "$thvar" '%s' "$FT_TEXT_HEIGHT"
    printf -v "$genvar" '%s' "$gen"
}

# ── Line store ───────────────────────────────────────────────────────────────
# A control's text, kept as LOGICAL LINES rather than one string:
#
#   _fti_<name>__lines     the logical lines            (append = one array push)
#   _fti_<name>__maxw      running max natural width    (extent width, never scanned)
#   _fti_<name>__rows      those lines wrapped          (what the display actually shows)
#   _fti_<name>__rowsw     the width __rows was wrapped at
#   _fti_<name>__linesgen  the text generation __lines corresponds to
#
# Why lines and not fixed-size chunks: WRAPPING NEVER CROSSES A NEWLINE. That is the single
# property that lets an append reuse every previously-wrapped row verbatim. Chunking by
# character count breaks it — a chunk boundary lands mid-word, so wrapping one chunk would
# need the next one, and appending would have to re-wrap backwards. Character counts also
# correspond to nothing the display cares about; the display is rows.
#
# A very long single line is not a problem here: it is one element, wrapped ONCE into its
# rows, and everything downstream reads rows. Only a width change re-wraps, which is O(total)
# under any storage scheme.
#
# Rebuild is O(n) and happens when the text changed underneath us (a plain ft_set); an
# append is O(added) and touches nothing that came before.
# LAZY-FETCH: the text is read only when a rebuild is actually needed. That matters because
# the property may be STALE (the store is ahead of it), and asking for it would join the whole
# thing back into one string — the very O(n) this exists to avoid. On the hot path (generation
# unchanged) this returns without touching the text at all.
# WHICH property the store holds is a parameter: a label's content is `text`, a textfield's is
# `value`. A control has exactly one store, so the property it was built from is recorded and a
# mismatch forces a rebuild — nothing can quietly read one control's value as another's text.
_ft_lines_sync() {              # name gen [prop=text] — make __lines describe the control's text
    local name=$1 gen=$2 prop=${3:-text}
    local genvar="_fti_${name}__linesgen" pvar="_fti_${name}__linesprop"
    [[ "${!genvar-}" == "$gen" && "${!pvar-}" == "$prop" ]] && return 0
    # A store describes ONE property. If it is currently AUTHORITATIVE for a different one —
    # that property is deferred, so these lines are the only copy of its content — materialise
    # it BEFORE the lines are replaced, or it is simply lost. (Reachable by calling the
    # CharacterData API, which works on `text`, against a textfield, whose store holds `value`.)
    [[ -n "${_FT_TEXT_STALE[$name]:-}" && "${_FT_TEXT_STALE[$name]}" != "$prop" ]] && _ft_text_join "$name"
    ft_resolved_prop "$name" "$prop" ""; local text=$FT_RET
    declare -ga "_fti_${name}__lines=()"
    local -n _lines="_fti_${name}__lines"
    local line
    if [[ -n "$text" ]]; then
        while IFS= read -r line; do _lines+=("$line"); done <<< "$text"
    fi
    # __maxw is left UNKNOWN (empty), not computed: measuring every line costs a
    # ft_display_width per line, and the controls that edit rather than measure (a textfield
    # re-splitting on every keystroke) never ask for it. _ft_lines_maxw fills it in on demand
    # and appends fold into it from there, so a measuring control pays it exactly once.
    printf -v "_fti_${name}__maxw" '%s' ""
    printf -v "_fti_${name}__nchars" '%s' ""
    printf -v "$genvar" '%s' "$gen"
    printf -v "$pvar" '%s' "$prop"
    unset "_fti_${name}__rowsw0" "_fti_${name}__rowsw1"   # wrapped rows no longer describe this
    return 0
}
# The widest logical line, in display columns — computed on first ask after a rebuild and
# cached until the lines change again. _ft_lines_append keeps it current in O(added).
_ft_lines_maxw() {              # name → FT_RET
    local mvar="_fti_${1}__maxw"
    if [[ -z "${!mvar-}" ]]; then
        local -n _mwl="_fti_${1}__lines"
        local m=0 l
        # ft_display_width's fast path (plain ASCII → ${#s}) taken inline: over thousands of
        # lines the function CALL is the cost, not the measurement. See _ft_textfield_layout for the
        # same note. THE CONDITION MUST MATCH ft_display_width's EXACTLY — this copy has now
        # been wrong twice, each time because a character that IS ASCII is not one column: ESC
        # (which starts a sequence worth zero) and TAB (which advances to the next stop).
        for l in "${_mwl[@]}"; do
            if [[ "$l" == *$'\e'* || "$l" == *[![:ascii:]]* || "$l" == *$'\t'* ]]; then ft_display_width "$l"; else FT_DISPLAY_WIDTH=${#l}; fi
            (( FT_DISPLAY_WIDTH > m )) && m=$FT_DISPLAY_WIDTH
        done
        printf -v "$mvar" '%s' "$m"
    fi
    FT_RET=${!mvar}
}
# How many CHARACTERS the whole text is — `${#value}` without materialising the value.
# The caret clamps against this on every motion, every edit and every frame, and fetching the
# string to measure it was the single most expensive thing a caret did on a big document.
# Same lazy contract as __maxw: unknown after a rebuild, exact from then on (splice and append
# adjust it by their own delta, which they know precisely).
_ft_lines_nchars() {            # name → FT_RET
    local cvar="_fti_${1}__nchars"
    if [[ -z "${!cvar-}" ]]; then
        local -n _ncl="_fti_${1}__lines"
        local n=${#_ncl[@]} total=0 l
        for l in "${_ncl[@]}"; do total=$(( total + ${#l} )); done
        (( n )) && total=$(( total + n - 1 ))       # the newlines BETWEEN the lines
        printf -v "$cvar" '%s' "$total"
    fi
    FT_RET=${!cvar}
}
# TWO slots, for the same reason the wrap cache has two: a label with a gutter measures at
# BOTH `cols` (the gutter decision) and `cols-1` (the real text width) every frame, and a
# single slot would re-wrap the whole log twice per frame, forever.
# Sets FT_LINES_ROWS to the array name holding the result, so a caller can nameref it and
# read rows without copying them.
FT_LINES_ROWS=""
_ft_lines_rows() {              # name width — ensure __rowsN holds __lines wrapped at WIDTH
    local name=$1 width=$2 slot
    for slot in 0 1; do
        local wvar="_fti_${name}__rowsw${slot}"
        if [[ "${!wvar-}" == "$width" ]]; then
            FT_LINES_ROWS="_fti_${name}__rows${slot}"; return 0
        fi
    done
    local nvar="_fti_${name}__rowsnext"
    local next=${!nvar:-0}
    printf -v "$nvar" '%s' $(( next ^ 1 ))
    declare -ga "_fti_${name}__rows${next}=()"
    local -n _rows="_fti_${name}__rows${next}"
    local -n _src="_fti_${name}__lines"
    local line
    for line in "${_src[@]}"; do
        ft_wrap "$line" "$width"
        _rows+=("${FT_WRAP_LINES[@]}")
    done
    printf -v "_fti_${name}__rowsw${next}" '%s' "$width"
    FT_LINES_ROWS="_fti_${name}__rows${next}"
    return 0
}
# When the store is authoritative the PROPERTY is left STALE rather than rewritten on every
# edit — rewriting it is a full copy of everything already there. It is materialised again the
# moment anything actually asks for the whole string, and not before.
#
# _FT_TEXT_STALE[name] holds the PROPERTY NAME that is deferred (`text` for a label, `value`
# for a textfield), not a flag: the read probes have to know that the property being asked for
# is the one that is stale, or a textfield's deferred `value` would be joined into `text`.
declare -A _FT_TEXT_STALE=()
_ft_text_join() {               # name — rebuild the deferred property from the line store
    local name=$1
    local prop=${_FT_TEXT_STALE[$name]:-text}
    local -n _join="_fti_${name}__lines"
    local IFS=$'\n'                             # safe: only builtins run under it
    printf -v "_ftp_${name}_${prop}" '%s' "${_join[*]}"
    unset "_FT_TEXT_STALE[$name]"
}
_ft_lines_append() {            # name added gen — push ADDED's lines, O(added)
    local name=$1 added=$2 gen=$3
    local -n _lines="_fti_${name}__lines"
    local mvar="_fti_${name}__maxw"             # NB separate lines: a same-statement
    local maxw=${!mvar-}                        # `local a=… b=${!a}` reads the OLD a
    # The joined text gains ADDED, plus one '\n' to join it on when something was already there.
    local cvar="_fti_${name}__nchars"
    if [[ -n "${!cvar-}" ]]; then
        local grew=${#added}; (( ${#_lines[@]} )) && grew=$(( grew + 1 ))
        printf -v "$cvar" '%s' $(( ${!cvar} + grew ))
    fi
    local line slot wvar width
    while IFS= read -r line; do
        _lines+=("$line")
        # Only fold into the max width if it is already KNOWN. Unknown stays unknown —
        # measuring here would put a per-line width scan back on the append path.
        [[ -n "$maxw" ]] && { ft_display_width "$line"; (( FT_DISPLAY_WIDTH > maxw )) && maxw=$FT_DISPLAY_WIDTH; }
        for slot in 0 1; do                     # keep every live row slot hot too
            wvar="_fti_${name}__rowsw${slot}"
            width=${!wvar-}
            [[ -n "$width" ]] || continue
            local -n _rslot="_fti_${name}__rows${slot}"
            ft_wrap "$line" "$width"
            _rslot+=("${FT_WRAP_LINES[@]}")
            unset -n _rslot
        done
    done <<< "$added"
    printf -v "$mvar" '%s' "$maxw"
    printf -v "_fti_${name}__linesgen" '%s' "$gen"
    return 0
}

# ── CharacterData, the rest of it ────────────────────────────────────────────
# appendData's siblings, over the same line store. Offsets are CHARACTER offsets into the
# text as one string (the DOM counts UTF-16 code units; we count code points, which differ
# only outside the BMP).
#
# An edit lands inside ONE line unless it spans a newline, so the work is proportional to the
# lines it touches, not to the whole text. Locating the offset walks the lines — O(lines), not
# O(characters) — which is what makes editing a long document affordable.
FT_LINE_IDX=0; FT_LINE_COL=0; FT_LINE_BASE=0
# Remember where the last lookup landed, so the next one can start there instead of at the top.
# An editor asks about the SAME line over and over — a keystroke moves the caret by one — so
# without this every edit walks the whole document to find the one line it is about to touch.
# The hint is tagged with the generation of the lines it describes and ignored otherwise.
_ft_lines_hint() {              # name idx acc
    local gvar="_fti_${1}__linesgen"
    printf -v "_fti_${1}__lochintidx" '%s' "$2"
    printf -v "_fti_${1}__lochintacc" '%s' "$3"
    printf -v "_fti_${1}__lochintgen" '%s' "${!gvar-}"
}
_ft_lines_locate() {            # name offset → FT_LINE_IDX / FT_LINE_COL / FT_LINE_BASE
    local name=$1 off=$2
    local -n _loc="_fti_${name}__lines"
    local i=0 n=${#_loc[@]} acc=0 len
    (( off < 0 )) && off=0
    local hgvar="_fti_${name}__lochintgen" lgvar="_fti_${name}__linesgen"
    if [[ -n "${!hgvar-}" && "${!hgvar}" == "${!lgvar-}" ]]; then
        local hivar="_fti_${name}__lochintidx" havar="_fti_${name}__lochintacc"
        local hi=${!hivar:-0}                   # NB separate lines (same-statement local gotcha)
        local ha=${!havar:-0}
        (( hi < n && ha <= off )) && { i=$hi; acc=$ha; }
    fi
    for (( ; i<n; i++ )); do
        len=${#_loc[i]}
        if (( off <= acc + len )); then
            FT_LINE_IDX=$i; FT_LINE_COL=$(( off - acc )); FT_LINE_BASE=$acc
            _ft_lines_hint "$name" "$i" "$acc"
            return 0
        fi
        acc=$(( acc + len + 1 ))                # +1 for the newline between lines
    done
    if (( n )); then
        FT_LINE_IDX=$(( n - 1 )); FT_LINE_COL=${#_loc[n-1]}
        FT_LINE_BASE=$(( acc - ${#_loc[n-1]} - 1 ))
    else
        FT_LINE_IDX=0; FT_LINE_COL=0; FT_LINE_BASE=0
    fi
    return 0
}
# Both mutators end here: the lines changed, so the wrapped rows and the joined string no
# longer describe them. Rows are dropped rather than patched — patching needs a row index per
# line, which is only worth building once an editor works on documents big enough to feel it.
_ft_lines_touched() {           # name
    local name=$1
    local genvar="_fti_${name}__textgen"
    local nextgen=$(( ++_FT_GENERATION_CLOCK ))
    printf -v "$genvar" '%s' "$nextgen"
    printf -v "_fti_${name}__linesgen" '%s' "$nextgen"
    unset "_fti_${name}__rowsw0" "_fti_${name}__rowsw1"
    printf -v "_fti_${name}__maxw" '%s' ""      # unknown again; _ft_lines_maxw recomputes on ask
    local lpvar="_fti_${name}__linesprop"       # WHICH property is now deferred
    _FT_TEXT_STALE[$name]=${!lpvar:-text}
    ft_reflow "$name"
    return 0
}
# THE splice: replace COUNT characters at OFF with DATA, in the LINE STORE and nothing else
# (no property write, no invalidation — the callers below decide what that means for them).
# insertData, deleteData and a textfield keystroke are all this one operation.
#
# It also REPORTS the logical lines it replaced:
#   FT_LINES_FROM   the first logical line index the edit landed in
#   FT_LINES_NDEL   how many lines were replaced      (always ≥ 1: the edit is inside a line)
#   FT_LINES_NINS   how many replaced them            (always ≥ 1: head+data+tail is ≥ 1 line)
# That range is exactly what a cached WRAP of these lines has to redo, and nothing outside it
# can have changed — which is what makes a keystroke in a big document cost one line's wrap.
# FT_LINES_BASE is the character offset of line FT_LINES_FROM — the caller needs it to
# re-seed the lookup hint, and a cached wrap needs it to re-base the rows it redoes.
FT_LINES_FROM=0; FT_LINES_NDEL=0; FT_LINES_NINS=0; FT_LINES_BASE=0
_ft_lines_splice() {            # name offset count data
    local name=$1 off=$2 count=$3 data=$4
    local -n _sp="_fti_${name}__lines"
    (( ${#_sp[@]} )) || _sp=("")
    _ft_lines_locate "$name" "$off"
    local from=$FT_LINE_IDX fromcol=$FT_LINE_COL base=$FT_LINE_BASE
    local to tocol
    # The end of the range is usually in the SAME line (a keystroke deletes 0 or 1 characters),
    # and then it is arithmetic rather than a second walk of the document.
    if (( count == 0 )); then to=$from; tocol=$fromcol
    elif (( fromcol + count <= ${#_sp[from]} )); then to=$from; tocol=$(( fromcol + count ))
    else
        _ft_lines_locate "$name" $(( off + count ))
        to=$FT_LINE_IDX; tocol=$FT_LINE_COL
    fi
    (( to < from )) && { to=$from; tocol=$fromcol; }
    local head=${_sp[from]:0:fromcol} tail=${_sp[to]:tocol}
    local -a chunk=()
    if [[ "$data" != *$'\n'* ]]; then
        chunk=("$head$data$tail")                             # the common case: one line
    else
        local piece
        while IFS= read -r piece; do chunk+=("$piece"); done <<< "$data"
        local last=$(( ${#chunk[@]} - 1 ))
        chunk[0]="$head${chunk[0]}"
        chunk[last]="${chunk[last]}$tail"
    fi
    # Keep the character count exact, while the lines being replaced are still here to measure.
    # The delta is over the replaced range only — O(lines touched), never O(document).
    local cvar="_fti_${name}__nchars"
    if [[ -n "${!cvar-}" ]]; then
        local oldlen=$(( to - from )) newlen=$(( ${#chunk[@]} - 1 )) _i
        for (( _i=from; _i<=to; _i++ )); do oldlen=$(( oldlen + ${#_sp[_i]} )); done
        for (( _i=0; _i<${#chunk[@]}; _i++ )); do newlen=$(( newlen + ${#chunk[_i]} )); done
        printf -v "$cvar" '%s' $(( ${!cvar} + newlen - oldlen ))
    fi
    if (( from == to && ${#chunk[@]} == 1 )); then
        _sp[from]=${chunk[0]}                                 # one line in, one line out
    else                                                      # the range swallowed newlines
        _sp=("${_sp[@]:0:from}" "${chunk[@]}" "${_sp[@]:to+1}")
    fi
    FT_LINES_FROM=$from; FT_LINES_NDEL=$(( to - from + 1 ))
    FT_LINES_NINS=${#chunk[@]}; FT_LINES_BASE=$base
    # The lines moved but the generation has not been bumped yet (the caller owns that), so the
    # hint no longer describes them. Callers re-seed it once they have settled the generation.
    unset "_fti_${name}__lochintgen"
    return 0
}
ft_insert_data() {              # name offset data — CharacterData.insertData()
    local name=$1 off=$2 data=$3
    [[ -n "${FT_TYPE[$name]:-}" ]] || return 1
    _ft_lines_prepare "$name" || return 1
    [[ -n "$data" ]] || return 0
    _ft_lines_splice "$name" "$off" 0 "$data"
    _ft_lines_touched "$name"
}
ft_delete_data() {              # name offset count — CharacterData.deleteData()
    local name=$1 off=$2 count=$3
    [[ -n "${FT_TYPE[$name]:-}" ]] || return 1
    _ft_lines_prepare "$name" || return 1
    (( count > 0 )) || return 0
    _ft_lines_splice "$name" "$off" "$count" ""
    _ft_lines_touched "$name"
}
# replaceData is delete-then-insert, exactly as the DOM defines it.
ft_replace_data() {             # name offset count data
    ft_delete_data "$1" "$2" "$3" || return 1
    ft_insert_data "$1" "$2" "$4"
}
ft_substring_data() {           # name offset count → FT_RET
    local name=$1 off=$2 count=$3
    _ft_get_raw "$name" text
    FT_RET=${FT_RET:off:count}
    return 0
}
# The same read, but off the LINE STORE and without materialising anything: start at the line
# the offset lands in and stop once enough characters have been taken. An editor needs this to
# record what a delete removed, and going through the joined string to fetch ONE character
# would put the whole document back on the keystroke path.
_ft_lines_substr() {            # name offset count → FT_RET
    local name=$1 off=$2 count=$3
    (( count > 0 )) || { FT_RET=""; return 0; }
    local -n _ss="_fti_${name}__lines"
    _ft_lines_locate "$name" "$off"
    local li=$FT_LINE_IDX col=$FT_LINE_COL
    local n=${#_ss[@]} out="" want=$count take
    while (( want > 0 && li < n )); do
        take=$(( ${#_ss[li]} - col ))
        (( take > want )) && take=$want
        (( take > 0 )) && { out+=${_ss[li]:col:take}; want=$(( want - take )); }
        # …and the newline that follows this line, if the range runs past it. The LAST line is
        # followed by nothing, so a range reaching the end simply stops there.
        (( want > 0 && li < n - 1 )) && { out+=$'\n'; want=$(( want - 1 )); }
        (( li++ )); col=0
    done
    FT_RET=$out
    return 0
}
# Make sure a line store exists and describes the control's current text.
_ft_lines_prepare() {           # name
    local name=$1
    local genvar="_fti_${name}__textgen"
    _ft_lines_sync "$name" "${!genvar:-0}"
}

# ft_append_data NAME TEXT [PROP] — append to a control's text, the DOM's
# CharacterData.appendData(). The point is not sugar, it is COST.
#
# `ft_set log text="$whole_log"` re-measures and re-wraps the ENTIRE text every time,
# because both caches are keyed on the text and every append misses them. Measured on a
# 1000-line log: _ft_text_extent 63ms + ft_wrap 74ms, several times per append — 543ms to
# add ONE line, and O(n²) to fill the log.
#
# Appending cannot change what came before: the earlier lines keep their measured width and
# their wrapped rows exactly. So this measures and wraps ONLY the new chunk and folds the
# result into the caches:
#     new height = old height + the chunk's lines
#     new width  = max(old width, the chunk's width)
# leaving the caches valid and hot rather than invalidated.
#
# What is left is O(n) COPIES (bash has no way to key these caches without holding the text),
# not O(n) SCANS — about 3ms per append at 1000 lines against 137ms+ before.
ft_append_data() {              # name text [prop=text]
    local name=$1 added=$2 prop=${3:-text}
    [[ -n "${FT_TYPE[$name]:-}" ]] || return 1
    [[ -n "$added" ]] || return 0

    local tgenvar0="_fti_${name}__textgen"
    local lgenvar0="_fti_${name}__linesgen"
    # ── FAST PATH ────────────────────────────────────────────────────────────────
    # The line store already describes this control's text, so it IS the text: push the new
    # lines onto it and leave the joined string stale. Nothing that came before is read,
    # copied, re-measured or re-wrapped, so the cost does not depend on how much is there.
    local lpropvar0="_fti_${name}__linesprop"
    if [[ "$prop" == text && "${!lpropvar0-text}" == text \
       && -n "${!lgenvar0-}" && "${!lgenvar0}" == "${!tgenvar0:-0}" ]]; then
        local nextgen=$(( ${!tgenvar0:-0} + 1 ))
        printf -v "$tgenvar0" '%s' "$nextgen"
        _ft_lines_append "$name" "$added" "$nextgen"
        _FT_TEXT_STALE[$name]=text          # the deferred property, by name (see _ft_text_join)
        # Keep the property REGISTERED even though its value is deferred, so ft_remove still
        # tears it down and ft_matches/the cascade still see that the control has text.
        local props=${FT_PROPS[$name]:-}
        case " $props " in *" text "*) : ;; *) FT_PROPS[$name]="${props:+$props }text" ;; esac
        ft_reflow "$name"
        return 0
    fi

    _ft_get_raw "$name" "$prop"; local old=$FT_RET
    local new=$old
    [[ -n "$old" ]] && new+=$'\n'
    new+=$added

    # Fold the chunk into the extent cache — but only if the cache actually describes the
    # text we are extending. If it is cold or stale, leave it: the normal path will rebuild it.
    local keyvar="_fti_${name}__extkey" twvar="_fti_${name}__exttw" thvar="_fti_${name}__extth"
    local genvar="_fti_${name}__extgen" tgenvar="_fti_${name}__textgen"
    local oldgen=${!tgenvar:-0}
    local extend_extent=0 oldtw=0 oldth=0
    # Valid to extend under either key form — a generation match, or the text itself.
    if [[ -n "${!genvar-}" && "${!genvar}" == "$oldgen" ]] || [[ "${!keyvar-}" == "$old" ]]; then
        extend_extent=1; oldtw=${!twvar:-0}; oldth=${!thvar:-0}
        # EMPTY text still measures one row high, so carrying that forward would make the
        # first appended line count twice. With no previous text the chunk IS the extent.
        [[ -n "$old" ]] || { oldtw=0; oldth=0; }
    fi

    # Extend the LINE STORE in place when it already describes the old text. This is the part
    # that makes an append independent of how much is already there — it pushes the new lines
    # and their wrapped rows and never looks at the rest.
    local lgenvar="_fti_${name}__linesgen"
    local extend_lines=0
    [[ "$prop" == text && "${!lpropvar0-text}" == text && "${!lgenvar-}" == "$oldgen" ]] && extend_lines=1

    _ft_setprop "$name" "$prop" "$new"                # bumps the generation
    local newgen=${!tgenvar:-0}
    (( extend_lines )) && _ft_lines_append "$name" "$added" "$newgen"
    _ft_wrap_cache_extend "$name" "$old" "$new" "$added" "$oldgen" "$newgen"

    if (( extend_extent )); then
        _ft_text_extent "$added"                      # O(added), not O(new)
        (( FT_TEXT_WIDTH < oldtw )) && FT_TEXT_WIDTH=$oldtw
        FT_TEXT_HEIGHT=$(( oldth + FT_TEXT_HEIGHT ))
        printf -v "$keyvar" '%s' "$new"
        printf -v "$twvar" '%s' "$FT_TEXT_WIDTH"
        printf -v "$thvar" '%s' "$FT_TEXT_HEIGHT"
        printf -v "$genvar" '%s' "$newgen"
    fi

    ft_reflow "$name"
    return 0
}

# ── Layout engine ────────────────────────────────────────────────────────────
# Four passes, the classic width-in/height-out constraint flow real engines
# use (widths resolve top-down because block children stretch and flex rows
# distribute; heights resolve bottom-up because wrapping depends on the used
# width):
#   1. _ft_pass_pref     bottom-up: preferred (max-content) OUTER widths
#   2. _ft_pass_width    top-down:  used outer widths per the parent's display
#   3. _ft_pass_height   bottom-up: used outer heights given used widths
#   4. _ft_pass_arrange  top-down:  absolute positions (+ flex column grow,
#                                   alignItems stretch, inline line boxes)
# display=none is skipped by every pass (and by draw and focus).

# Read STRAIGHT from the property variable. `display` is a layout property: it never inherits
# (not in FT_INHERITED_PROP), it is always set locally by the prototype defaults, and it has no
# coercion hook — so _ft_get_raw's dispatch and ft_resolved_prop's resolve+coerce can only arrive
# back at this same variable. Exactly the reasoning _ft_inset4 already uses for padding. One layout
# of a 37-control page asks 479 times, which is more than every other property put together.
# THE RAW FAST PATHS TAKE THE GATE TOO. Reading the instance and the prototype but not the sheet
# would make `#thing { display: none }` true for the paint and false for the layout, which is
# worse than either answer alone. The gate is shut for every app that writes no such rule, so
# the 479 `display` reads in a layout still cost one variable read and one assoc read.
# …and the variant that refuses INHERITING properties, so a caller promising "no inheritance"
# can take the gate without breaking that promise.
_ft_gated_style_own() {         # name prop → FT_RET, status 1 if the gate is shut or it inherits
    [[ -n "${_FT_CSS_DECLARED_PROPS[$2]:-}" ]] || return 1
    [[ -z "${FT_INHERITED_PROP[$2]:-}" && "$2" != --* ]] || return 1
    _ft_gated_style "$1" "$2"
}
# The same question the raw fast paths ask: does an APP STYLESHEET declare this property for
# this control? Level 2 only — see the note in ft_resolve for why not the whole cascade.
_ft_gated_style() {             # name prop → FT_RET, status 1 if the gate is shut or says nothing
    [[ -z "${_FT_RESOLVING_CASCADE:-}" ]] || return 1
    [[ -n "${_FT_CSS_DECLARED_PROPS[$2]:-}" && -n "${_FT_CSS_LOADED:-}" ]] || return 1
    [[ "$2" != cursor ]] || return 1              # the one name collision — see ft_resolve
    local _FT_RESOLVING_CASCADE=1
    _ft_css_query "$1" "$2" app
    (( _QGOT )) || return 1
    _ft_css_resolve_value "$1" "$FT_RET"
    (( ${#FT_RET} > 0 ))
}
_ft_disp()    { local v="_ftp_${1}_display"; FT_RET=${!v-}
                (( ${#FT_RET} )) && return
                [[ -n "${_FT_CSS_FASTPATH_DECLARED:-}" ]] && { _ft_gated_style "$1" display && return; }
                [[ -n "${1:-}" ]] && FT_RET=${FT_PROTO_DEFAULT["${FT_TYPE[$1]:-} display"]-} || FT_RET=""
                (( ${#FT_RET} )) || FT_RET=block; }
_ft_in_flow() {                 # name → 0 if participates in normal flow
    _ft_disp "$1"; [[ "$FT_RET" == none ]] && return 1
    ft_own_prop "$1" position; [[ "$FT_RET" == absolute ]] && return 1
    return 0
}
_ft_is_inline() { _ft_disp "$1"; [[ "$FT_RET" == inline-block ]]; }

# Pass 1 — preferred (max-content) outer width, bottom-up. Explicit width wins
# outright; otherwise a leaf's intrinsic width or a container's per-display
# aggregation of children, plus inset, clamped by min/max.
_ft_pass_pref() {               # name
    local name=$1 kid
    _ft_disp "$name"
    if [[ "$FT_RET" == none ]]; then
        # A hidden box has no geometry at all — zero the used sizes too, so
        # nothing downstream (or in tests) reads a stale pre-hide size.
        FT_PREFERRED_WIDTH[$name]=0; FT_MEASURED_WIDTH[$name]=0; FT_MEASURED_HEIGHT[$name]=0
        return
    fi
    for kid in ${FT_KIDS[$name]}; do
        _ft_disp "$kid"
        [[ "$FT_RET" == none ]] && { FT_PREFERRED_WIDTH[$kid]=0; FT_MEASURED_WIDTH[$kid]=0; FT_MEASURED_HEIGHT[$kid]=0; continue; }
        _ft_pass_pref "$kid"
    done

    ft_own_prop "$name" width; local uw=$FT_RET
    if [[ -n "$uw" ]]; then
        _ft_clamp_w "$name" "$uw"; FT_PREFERRED_WIDTH[$name]=$FT_RET
        return
    fi

    local content=0
    _ft_inset4 "$name"; local il=$FT_INSET_LEFT ir=$FT_INSET_RIGHT
    local type=${FT_TYPE[$name]}
    local prefw_fn=${FT_PROTO_PREFERRED_WIDTH[$type]:-}
    if [[ -n "$prefw_fn" ]]; then
        "$prefw_fn" "$name"; content=$FT_RET
    else
        _ft_disp "$name"; local disp=$FT_RET
        ft_resolved_prop "$name" flexDirection row; local fdir=$FT_RET
        ft_resolved_prop "$name" gap 0; local gap=$FT_RET
        local w n=0 sum=0 maxc=0 run=0
        for kid in ${FT_KIDS[$name]}; do
            _ft_in_flow "$kid" || continue
            _ft_margin4 "$kid"
            w=$(( ${FT_PREFERRED_WIDTH[$kid]:-0} + FT_MARGIN_LEFT + FT_MARGIN_RIGHT ))
            if [[ "$disp" == flex ]]; then
                if [[ "$fdir" == column ]]; then
                    (( w > maxc )) && maxc=$w
                else
                    sum=$(( sum + w )); (( n++ ))
                fi
            else
                # block: an inline run's max-content width is its unwrapped sum;
                # a block-level child stands alone. content = widest of both.
                if _ft_is_inline "$kid"; then
                    run=$(( run + w ))
                    (( run > maxc )) && maxc=$run
                else
                    run=0
                    (( w > maxc )) && maxc=$w
                fi
            fi
        done
        if [[ "$disp" == flex && "$fdir" != column ]]; then
            (( n > 1 )) && sum=$(( sum + gap*(n-1) ))
            content=$sum
        else
            content=$maxc
        fi
    fi
    _ft_clamp_w "$name" $(( content + il + ir ))
    FT_PREFERRED_WIDTH[$name]=$FT_RET
}

# Pass 2 — used outer widths, top-down. FT_MEASURED_WIDTH[name] must already be set (the
# root's is its explicit width or its preferred width); this computes each
# child's used width per THIS control's display mode, then recurses.
# INTEGER DIVISION UNDER-SHRINKS, on both axes. Distributing a deficit by
# `(-free) * shrink * base / ssum` floors every share, so three items of 10 sharing a deficit
# of 11 each lose 3 and settle at 21 in a 19-wide box; a deficit of 1 across two items is lost
# entirely. The remainder is burned off the LARGEST shrinkable items, so a small item (a button
# in a row) survives intact and nothing is pushed past the container's clip.
#
# ONE implementation, called by both axes. The column branch had this and the row branch never
# got it — the same algorithm transcribed twice and corrected once, which is how the row's last
# frame lost its right border to its own container's overflow. Sizes are updated in place
# through a nameref, so the caller's array is the one that changes.
_ft_flex_burn_off() {           # sizesVar kidsVar shrinksVar axis(h|v) gap inner
    local -n _bo_sizes=$1 _bo_kids=$2 _bo_shrinks=$3
    local _bo_axis=$4 _bo_gap=$5 _bo_inner=$6
    local _bo_n=${#_bo_kids[@]} _bo_i _bo_residual=0 _bo_big _bo_m
    for _bo_i in "${!_bo_kids[@]}"; do
        _ft_margin4 "${_bo_kids[$_bo_i]}"
        if [[ "$_bo_axis" == h ]]; then _bo_m=$(( FT_MARGIN_LEFT + FT_MARGIN_RIGHT ))
        else                            _bo_m=$(( FT_MARGIN_TOP + FT_MARGIN_BOTTOM )); fi
        _bo_residual=$(( _bo_residual + _bo_sizes[_bo_i] + _bo_m ))
    done
    (( _bo_n > 1 )) && _bo_residual=$(( _bo_residual + _bo_gap*(_bo_n-1) ))
    _bo_residual=$(( _bo_residual - _bo_inner ))
    while (( _bo_residual > 0 )); do
        _bo_big=-1
        for _bo_i in "${!_bo_kids[@]}"; do
            (( ${_bo_shrinks[$_bo_i]} > 0 && _bo_sizes[_bo_i] > 0 )) || continue
            (( _bo_big < 0 || _bo_sizes[_bo_i] > _bo_sizes[_bo_big] )) && _bo_big=$_bo_i
        done
        (( _bo_big < 0 )) && break
        _bo_sizes[_bo_big]=$(( _bo_sizes[_bo_big] - 1 ))
        (( _bo_residual-- ))
    done
    return 0
}
_ft_pass_width() {              # name
    local name=$1 kid
    _ft_disp "$name"; [[ "$FT_RET" == none ]] && return
    _ft_inset4 "$name"; local il=$FT_INSET_LEFT ir=$FT_INSET_RIGHT
    local inner=$(( ${FT_MEASURED_WIDTH[$name]:-0} - il - ir ))
    (( inner < 0 )) && inner=0
    _ft_disp "$name"; local disp=$FT_RET

    if [[ "$disp" == flex ]]; then
        ft_resolved_prop "$name" flexDirection row; local fdir=$FT_RET
        if [[ "$fdir" == column ]]; then
            # Cross axis: stretch (CSS default) fills; start/center/end
            # shrink-to-fit against the available content width.
            ft_resolved_prop "$name" alignItems stretch; local ai=$FT_RET
            local uw avail
            for kid in ${FT_KIDS[$name]}; do
                _ft_in_flow "$kid" || continue
                _ft_margin4 "$kid"
                avail=$(( inner - FT_MARGIN_LEFT - FT_MARGIN_RIGHT )); (( avail < 0 )) && avail=0
                ft_own_prop "$kid" width; uw=$FT_RET
                if [[ -n "$uw" ]]; then
                    _ft_clamp_w "$kid" "$uw"
                else
                    ft_resolved_prop "$kid" alignSelf auto; local as=$FT_RET
                    [[ "$as" == auto ]] && as=$ai
                    if [[ "$as" == stretch ]]; then
                        _ft_clamp_w "$kid" "$avail"
                    else
                        local pw=${FT_PREFERRED_WIDTH[$kid]:-0}
                        (( pw > avail )) && pw=$avail
                        _ft_clamp_w "$kid" "$pw"
                    fi
                fi
                FT_MEASURED_WIDTH[$kid]=$FT_RET
            done
        else
            # Main axis: resolve bases (flexBasis > width > preferred), then
            # distribute free space by flexGrow or shrink deficit by
            # flexShrink weighted by base size — CSS's model, single pass.
            ft_resolved_prop "$name" gap 0; local gap=$FT_RET
            local -a fkids=() bases=() grows=() shrinks=()
            local base sum=0 n=0 gsum=0 ssum=0
            for kid in ${FT_KIDS[$name]}; do
                _ft_in_flow "$kid" || continue
                ft_resolved_prop "$kid" flexBasis auto; base=$FT_RET
                if [[ "$base" == auto || -z "$base" ]]; then
                    ft_own_prop "$kid" width; base=$FT_RET
                    [[ -z "$base" ]] && base=${FT_PREFERRED_WIDTH[$kid]:-0}
                fi
                _ft_clamp_w "$kid" "$base"; base=$FT_RET
                _ft_margin4 "$kid"; local mw=$(( FT_MARGIN_LEFT + FT_MARGIN_RIGHT ))
                fkids+=("$kid"); bases+=("$base")
                ft_resolved_prop "$kid" flexGrow 0;   grows+=("$FT_RET");   gsum=$(( gsum + FT_RET ))
                ft_resolved_prop "$kid" flexShrink 1; shrinks+=("$FT_RET"); ssum=$(( ssum + FT_RET*base ))
                sum=$(( sum + base + mw )); (( n++ ))
            done
            (( n > 1 )) && sum=$(( sum + gap*(n-1) ))
            # A horizontally scrollable container (overflowX) keeps children at NATURAL width —
            # no shrink; the viewport slides over them (the row analogue of vertical scrolling).
            local _hsv="_ftp_${name}_overflowX" _hs=0
            case ${!_hsv:-} in auto|scroll) _hs=1 ;; esac
            local free=$(( inner - sum )) i used give taken
            local -a newws=()
            for i in "${!fkids[@]}"; do
                used=${bases[$i]}
                if (( free > 0 && gsum > 0 )); then
                    give=$(( free * grows[i] / gsum ))
                    used=$(( used + give ))
                elif (( free < 0 && ssum > 0 && ! _hs )); then
                    taken=$(( (-free) * shrinks[i] * bases[i] / ssum ))
                    used=$(( used - taken )); (( used < 0 )) && used=0
                fi
                newws[i]=$used
            done
            # …and take the remainder integer division left behind (see _ft_flex_burn_off)
            (( free < 0 && ssum > 0 && ! _hs )) && \
                _ft_flex_burn_off newws fkids shrinks h "$gap" "$inner"
            for i in "${!fkids[@]}"; do
                _ft_clamp_w "${fkids[$i]}" "${newws[$i]}"
                FT_MEASURED_WIDTH[${fkids[$i]}]=$FT_RET
            done
        fi
    else
        # block flow: block-level children with width auto STRETCH to the
        # content width (real CSS); inline-block children shrink-to-fit
        # (min(preferred, available)); explicit widths just clamp.
        local uw avail
        for kid in ${FT_KIDS[$name]}; do
            _ft_in_flow "$kid" || continue
            _ft_margin4 "$kid"
            avail=$(( inner - FT_MARGIN_LEFT - FT_MARGIN_RIGHT )); (( avail < 0 )) && avail=0
            ft_own_prop "$kid" width; uw=$FT_RET
            if [[ -n "$uw" ]]; then
                _ft_clamp_w "$kid" "$uw"
            elif _ft_is_inline "$kid"; then
                local pw=${FT_PREFERRED_WIDTH[$kid]:-0}
                (( pw > avail )) && pw=$avail
                _ft_clamp_w "$kid" "$pw"
            else
                _ft_clamp_w "$kid" "$avail"
            fi
            FT_MEASURED_WIDTH[$kid]=$FT_RET
        done
    fi

    # Absolutely-positioned children: explicit width or shrink-to-fit.
    for kid in ${FT_KIDS[$name]}; do
        _ft_disp "$kid"; [[ "$FT_RET" == none ]] && continue
        ft_own_prop "$kid" position; [[ "$FT_RET" == absolute ]] || continue
        ft_own_prop "$kid" width; local uw2=$FT_RET
        if [[ -n "$uw2" ]]; then
            _ft_clamp_w "$kid" "$uw2"
        else
            local pw2=${FT_PREFERRED_WIDTH[$kid]:-0}
            (( pw2 > inner )) && pw2=$inner
            _ft_clamp_w "$kid" "$pw2"
        fi
        FT_MEASURED_WIDTH[$kid]=$FT_RET
    done

    for kid in ${FT_KIDS[$name]}; do
        _ft_disp "$kid"; [[ "$FT_RET" == none ]] && continue
        _ft_pass_width "$kid"
    done
}

# Pass 3 — used outer heights, given used widths, with AVAILABLE HEIGHT
# threaded top-down ("" = unconstrained). A deliberate, documented deviation
# from strict CSS: an auto height is additionally capped by the space its
# context actually has, because a terminal does not scroll your UI — content
# that can't fit must CLIP OR SCROLL inside its box (labels default
# overflowY=auto and grow a scrollbar), never silently run off the screen.
# A leaf's height comes from its prototype intrinsic (label wraps to its used
# content width); a container's from stacking/line-boxing/flexing its
# children, each child measured against the space remaining for it.
declare -A FT_AVAILABLE_HEIGHT=()
_ft_pass_height() {             # name [availH]
    local name=$1 avail=${2-}
    _ft_disp "$name"; [[ "$FT_RET" == none ]] && { FT_MEASURED_HEIGHT[$name]=0; return; }
    FT_AVAILABLE_HEIGHT[$name]=$avail

    _ft_inset4 "$name"; local it=$FT_INSET_TOP ib=$FT_INSET_BOTTOM il=$FT_INSET_LEFT ir=$FT_INSET_RIGHT
    ft_own_prop "$name" height; local uh=$FT_RET
    # inner = the space this control's CHILDREN have: its own explicit
    # height wins; else whatever its context allows.
    local inner=""
    if [[ -n "$uh" ]]; then inner=$(( uh - it - ib ))
    elif [[ -n "$avail" ]]; then inner=$(( avail - it - ib )); fi
    [[ -n "$inner" ]] && (( inner < 0 )) && inner=0

    _ft_disp "$name"; local disp=$FT_RET
    ft_resolved_prop "$name" flexDirection row; local fdir=$FT_RET
    ft_resolved_prop "$name" gap 0; local gap=$FT_RET
    local innerw=$(( ${FT_MEASURED_WIDTH[$name]:-0} - il - ir )); (( innerw < 0 )) && innerw=0

    # Children first, each with its remaining share of the space: flex rows
    # give every child the full cross height; stacked flows (block, flex
    # column) hand each child what the ones before it left over.
    # A container that SCROLLS vertically must not constrain its children's height. The
    # auto-height cap below exists because a terminal cannot scroll the page — but a scrolling
    # box is exactly the case where it can. Capping here would truncate the content to the
    # viewport, leaving nothing to scroll to (the pane would clip instead of scroll).
    local scrolls_vertically=0
    ft_resolved_prop "$name" overflow hidden
    case "$FT_RET" in auto|scroll) scrolls_vertically=1 ;; esac

    local kid mv mh kavail consumed=0 n=0 cx=0 lineh=0 sum=0 maxc=0 w h
    for kid in ${FT_KIDS[$name]}; do
        _ft_disp "$kid"; [[ "$FT_RET" == none ]] && { FT_MEASURED_HEIGHT[$kid]=0; continue; }
        ft_own_prop "$kid" position
        if [[ "$FT_RET" == absolute ]]; then
            ft_own_prop "$kid" top; local kt=${FT_RET:-0}
            kavail=""; [[ -n "$inner" ]] && { kavail=$(( inner - kt )); (( kavail < 0 )) && kavail=0; }
            _ft_pass_height "$kid" "$kavail"
            continue
        fi
        # CAPTURED, not read live: _ft_pass_height below recurses into this child's own
        # children and rewrites FT_MARGIN_* before the two uses further down.
        _ft_margin4 "$kid"; mv=$(( FT_MARGIN_TOP + FT_MARGIN_BOTTOM )); mh=$(( FT_MARGIN_LEFT + FT_MARGIN_RIGHT ))
        # Every child sees the FULL inner space (not "whatever earlier
        # siblings left") — capping sequentially would starve later siblings
        # (a wall of text would squeeze the button row below it to nothing).
        # When the capped children still don't fit together, the flex-column
        # arrange pass shrinks them proportionally (flexShrink), which takes
        # space from the big ones, not the last-declared ones.
        kavail=""
        if [[ -n "$inner" ]] && (( ! scrolls_vertically )); then
            kavail=$(( inner - mv )); (( kavail < 0 )) && kavail=0
        fi
        _ft_pass_height "$kid" "$kavail"
        h=$(( ${FT_MEASURED_HEIGHT[$kid]:-0} + mv ))
        if [[ "$disp" == flex ]]; then
            if [[ "$fdir" == column ]]; then
                (( n > 0 )) && consumed=$(( consumed + gap ))
                consumed=$(( consumed + h )); sum=$consumed
            else
                (( h > maxc )) && maxc=$h
            fi
            (( n++ ))
        else
            # block flow: inline runs share a line; block boxes stack.
            w=$(( ${FT_MEASURED_WIDTH[$kid]:-0} + mh ))
            if _ft_is_inline "$kid"; then
                if (( cx > 0 && cx + w > innerw )); then
                    consumed=$(( consumed + lineh )); cx=0; lineh=0
                fi
                cx=$(( cx + w ))
                (( h > lineh )) && lineh=$h
            else
                if (( cx > 0 )); then consumed=$(( consumed + lineh )); cx=0; lineh=0; fi
                consumed=$(( consumed + h ))
            fi
        fi
    done
    (( cx > 0 )) && consumed=$(( consumed + lineh ))

    if [[ -n "$uh" ]]; then
        _ft_clamp_h "$name" "$uh"; FT_MEASURED_HEIGHT[$name]=$FT_RET
        return
    fi

    local content=0
    local type=${FT_TYPE[$name]}
    local h_fn=${FT_PROTO_HEIGHT[$type]:-}
    if [[ -n "$h_fn" ]]; then
        "$h_fn" "$name" "$innerw"; content=$FT_RET
    elif [[ "$disp" == flex && "$fdir" != column ]]; then
        content=$maxc
    else
        content=$consumed
    fi
    # The deviation: auto height never exceeds the available space.
    [[ -n "$avail" ]] && (( content + it + ib > avail )) && { content=$(( avail - it - ib )); (( content < 0 )) && content=0; }
    _ft_clamp_h "$name" $(( content + it + ib ))
    FT_MEASURED_HEIGHT[$name]=$FT_RET
}

# Pass 4 — absolute positions, top-down. Also where flex applies alignItems
# (including stretch) and column-direction flexGrow/flexShrink to heights,
# because those need the container's final size.
_ft_pass_arrange() {            # name absX absY
    local name=$1 ax=$2 ay=$3
    # THE CLIP MEMO DIES HERE, and here rather than in ft_layout on purpose: this is the one
    # function that writes an absolute position, so bumping inside it covers ft_layout,
    # _ft_reflow_now (which re-runs the passes directly and bumps nothing itself) and
    # _ft_tabs_relayout (which calls the four passes by hand for a tab switch) without any of
    # them having to remember. An increment, not a call — a call is ~25µs and this is per
    # control per pass.
    #
    # …BUT ONLY FOR A NODE THAT IS SOMEBODY'S ANCESTOR. A clip rect is the intersection over the
    # target's PARENT CHAIN, so a control with no children is never read by any clip computation
    # — its own rect is keyed on its parent, and no other control's chain contains it. Moving a
    # childless overlay therefore cannot invalidate a single cached rect. That is the whole drag
    # case: the chip is a leaf, and without this test its one arrange a frame threw away every
    # rect on the page (measured: 61% hit rate, four containers missing once per frame each,
    # none of which had moved). A node that LATER gains children is reparenting, and ft_append
    # and friends invalidate through _ft_reparented.
    [[ -n "${FT_KIDS[$name]:-}" ]] && (( _FT_CLIP_GEN++ ))
    FT_ABSOLUTE_X[$name]=$ax; FT_ABSOLUTE_Y[$name]=$ay
    _ft_disp "$name"; [[ "$FT_RET" == none ]] && return
    local disp=$FT_RET

    _ft_inset4 "$name"; local il=$FT_INSET_LEFT ir=$FT_INSET_RIGHT it=$FT_INSET_TOP ib=$FT_INSET_BOTTOM
    local innerx=$(( ax + il )) innery=$(( ay + it ))
    local innerw=$(( ${FT_MEASURED_WIDTH[$name]:-0} - il - ir )) innerh=$(( ${FT_MEASURED_HEIGHT[$name]:-0} - it - ib ))
    (( innerw < 0 )) && innerw=0
    (( innerh < 0 )) && innerh=0

    # SCROLLABLE container (overflow: auto|scroll — CSS): children keep their NATURAL heights
    # (no flex-shrink squeeze) and are placed scrollTop rows up; the box clips the rest (any
    # overflow ≠ visible already clips). scrollHeight/clientHeight are published every arrange,
    # and scrollTop is clamped to [0, scrollHeight-clientHeight] — so a full relayout reproduces
    # the scrolled state and ft_scroll_set's incremental shift stays consistent.
    # NB: keyed on `overflow` ONLY — `overflowY` is the pre-existing per-control convention for
    # a control's OWN content scrollbar (labels default overflowY=auto), not container scrolling.
    local scroll=0 stop=0 hscroll=0 sleft=0
    ft_resolved_prop "$name" overflow hidden; local _ov=$FT_RET
    case "$_ov" in auto|scroll) scroll=1 ;; esac
    # …BUT ONLY FOR A BOX THAT LAYS OUT CHILDREN. A childless control that scrolls its OWN
    # content — a label, a table — measures that content itself and publishes its own
    # scrollHeight. Reaching this path anyway, the container branch computed an extent from
    # children there are none of and published scrollHeight=0 over the label's answer. Latent
    # until scroll offsets were clamped against that pair: ft_has_scrollbar read 0 between a
    # layout and the next paint, and then `ft_set log scrollTop=99` clamped to 0 and the
    # label jumped to the top. `ft-label overflow=scroll` is the ordinary way to write it —
    # _ft_label_metrics resolves the shorthand too — so both halves claimed the same word.
    (( scroll )) && [[ -z "${FT_KIDS[$name]:-}" ]] && scroll=0
    if (( scroll )); then
        ft_resolved_prop "$name" scrollTop 0; stop=${FT_RET:-0}
        [[ "$stop" =~ ^[0-9]+$ ]] || stop=0
    fi
    ft_resolved_prop "$name" overflowX ""; local _ovx=$FT_RET
    case "$_ovx" in auto|scroll) hscroll=1 ;; esac
    if (( hscroll )); then
        ft_resolved_prop "$name" scrollLeft 0; sleft=${FT_RET:-0}
        [[ "$sleft" =~ ^[0-9]+$ ]] || sleft=0
    fi

    local kid m w h
    if [[ "$disp" == flex ]]; then
        ft_resolved_prop "$name" flexDirection row;      local fdir=$FT_RET
        ft_resolved_prop "$name" gap 0;                  local gap=$FT_RET
        ft_resolved_prop "$name" justifyContent start;   local jc=$FT_RET
        ft_resolved_prop "$name" alignItems stretch;     local ai=$FT_RET

        local -a flow=()
        for kid in ${FT_KIDS[$name]}; do _ft_in_flow "$kid" && flow+=("$kid"); done
        local n=${#flow[@]}

        if [[ "$fdir" == column ]]; then
            # Column main axis = height: apply flexGrow/flexShrink here (the
            # container's height is final only now).
            local sum=0 gsum=0 ssum=0 base
            local -a bases=() grows=() shrinks=()
            for kid in "${flow[@]}"; do
                _ft_margin4 "$kid"; local mv=$(( FT_MARGIN_TOP + FT_MARGIN_BOTTOM ))
                base=${FT_MEASURED_HEIGHT[$kid]:-0}
                bases+=("$base")
                ft_resolved_prop "$kid" flexGrow 0;   grows+=("$FT_RET");   gsum=$(( gsum + FT_RET ))
                ft_resolved_prop "$kid" flexShrink 1; shrinks+=("$FT_RET"); ssum=$(( ssum + FT_RET*base ))
                sum=$(( sum + base + mv ))
            done
            (( n > 1 )) && sum=$(( sum + gap*(n-1) ))
            if (( scroll )); then
                # content keeps its natural height; the viewport just slides over it
                local maxs=$(( sum - innerh )); (( maxs < 0 )) && maxs=0
                (( stop > maxs )) && stop=$maxs
                # THE EXTENTS FIRST, then the offset: _ft_setprop clamps scrollTop against this
                # pair, and writing the offset first would clamp it against the PREVIOUS
                # measurement — the stale one this arrange exists to replace.
                _ft_setprop "$name" scrollHeight "$sum"
                _ft_setprop "$name" clientHeight "$innerh"
                _ft_setprop "$name" scrollTop "$stop"
            fi
            local free=$(( innerh - sum )) i give taken newh
            if (( free > 0 && gsum > 0 )) || (( free < 0 && ssum > 0 && ! scroll )); then
                local -a newhs=()
                for i in "${!flow[@]}"; do
                    newh=${bases[$i]}
                    if (( free > 0 && gsum > 0 )); then
                        give=$(( free * grows[i] / gsum )); newh=$(( newh + give ))
                    else
                        taken=$(( (-free) * shrinks[i] * bases[i] / ssum ))
                        newh=$(( newh - taken )); (( newh < 0 )) && newh=0
                    fi
                    newhs[i]=$newh
                done
                # take the remainder integer division left behind — the shared
                # implementation, which the row axis calls too (see _ft_flex_burn_off)
                (( free < 0 )) && _ft_flex_burn_off newhs flow shrinks v "$gap" "$innerh"
                for i in "${!flow[@]}"; do
                    _ft_clamp_h "${flow[$i]}" "${newhs[$i]}"; FT_MEASURED_HEIGHT[${flow[$i]}]=$FT_RET
                    # A SHRUNK CONTAINER'S CHILDREN MUST SHRINK WITH IT. This used to pin the
                    # container's number and walk away: `panes` went 9→7 while the code panes
                    # inside stayed 8 — so they overflowed the shrunken parent and the clip took
                    # their bottom borders off ("the text boxes are cut off", reported from a
                    # 30-row window). Re-running the height pass with the reduced height re-caps
                    # the subtree: divs re-distribute, and a child with an explicit height is
                    # shrunk by ITS parent's own flex pass on the way down, which is this same
                    # code one level deeper. The re-pin afterwards keeps the flex algorithm's
                    # decision for the kid's own box, whatever its content would have preferred.
                    if (( FT_RET < bases[i] )) && [[ -n "${FT_KIDS[${flow[$i]}]:-}" ]]; then
                        _ft_pass_height "${flow[$i]}" "$FT_RET"
                        _ft_clamp_h "${flow[$i]}" "${newhs[$i]}"; FT_MEASURED_HEIGHT[${flow[$i]}]=$FT_RET
                    fi
                done
                free=0
            fi
            (( free < 0 )) && free=0
            local cur=0 spacing=$gap
            case "$jc" in
                center)        cur=$(( free/2 )) ;;
                end)           cur=$free ;;
                space-between) (( n > 1 )) && spacing=$(( gap + free/(n-1) )) ;;
            esac
            for kid in "${flow[@]}"; do
                # captured: _ft_pass_arrange below recurses and rewrites FT_MARGIN_*
                _ft_margin4 "$kid"
                local ml=$FT_MARGIN_LEFT mr=$FT_MARGIN_RIGHT mt=$FT_MARGIN_TOP
                local mv=$(( FT_MARGIN_TOP + FT_MARGIN_BOTTOM ))
                w=${FT_MEASURED_WIDTH[$kid]:-0}; h=${FT_MEASURED_HEIGHT[$kid]:-0}
                ft_resolved_prop "$kid" alignSelf auto; local as=$FT_RET
                [[ "$as" == auto ]] && as=$ai
                local cross=$ml
                case "$as" in
                    center) cross=$(( ml + (innerw - ml - mr - w)/2 )) ;;
                    end)    cross=$(( innerw - mr - w )) ;;
                esac
                (( cross < 0 )) && cross=0
                _ft_pass_arrange "$kid" $(( innerx + cross )) $(( innery + cur + mt - stop ))
                cur=$(( cur + h + mv + spacing ))
            done
        else
            # Row: widths already final (pass 2). Cross axis is height:
            # stretch fills auto-height items to the row.
            local sum=0
            for kid in "${flow[@]}"; do
                _ft_margin4 "$kid"
                sum=$(( sum + ${FT_MEASURED_WIDTH[$kid]:-0} + FT_MARGIN_LEFT + FT_MARGIN_RIGHT ))
            done
            (( n > 1 )) && sum=$(( sum + gap*(n-1) ))
            if (( hscroll )); then       # horizontal viewport: clamp + publish, kids slide left
                local maxsl=$(( sum - innerw )); (( maxsl < 0 )) && maxsl=0
                (( sleft > maxsl )) && sleft=$maxsl
                _ft_setprop "$name" scrollLeft "$sleft"
                _ft_setprop "$name" scrollWidth "$sum"
                _ft_setprop "$name" clientWidth "$innerw"
            fi
            local free=$(( innerw - sum )); (( free < 0 )) && free=0
            local cur=0 spacing=$gap
            case "$jc" in
                center)        cur=$(( free/2 )) ;;
                end)           cur=$free ;;
                space-between) (( n > 1 )) && spacing=$(( gap + free/(n-1) )) ;;
            esac
            for kid in "${flow[@]}"; do
                # captured: _ft_pass_arrange below recurses and rewrites FT_MARGIN_*
                _ft_margin4 "$kid"
                local mt=$FT_MARGIN_TOP mb=$FT_MARGIN_BOTTOM ml=$FT_MARGIN_LEFT
                local mv=$(( FT_MARGIN_TOP + FT_MARGIN_BOTTOM )) mh=$(( FT_MARGIN_LEFT + FT_MARGIN_RIGHT ))
                w=${FT_MEASURED_WIDTH[$kid]:-0}
                ft_resolved_prop "$kid" alignSelf auto; local as=$FT_RET
                [[ "$as" == auto ]] && as=$ai
                if [[ "$as" == stretch ]]; then
                    ft_own_prop "$kid" height
                    if [[ -z "$FT_RET" ]]; then
                        _ft_clamp_h "$kid" $(( innerh - mv ))
                        FT_MEASURED_HEIGHT[$kid]=$FT_RET
                    fi
                fi
                h=${FT_MEASURED_HEIGHT[$kid]:-0}
                local cross=$mt
                case "$as" in
                    center) cross=$(( mt + (innerh - mv - h)/2 )) ;;
                    end)    cross=$(( innerh - mb - h )) ;;
                esac
                (( cross < 0 )) && cross=0
                _ft_pass_arrange "$kid" $(( innerx + cur + ml - sleft )) $(( innery + cross ))
                cur=$(( cur + w + mh + spacing ))
            done
        fi
    else
        # block flow: stack block-level children; pack inline runs into line
        # boxes wrapped at the content width (same walk as pass 3's height).
        # A scrollable container starts the stack scrollTop rows up (the clip hides the rest).
        local cy=$(( innery - stop )) cx=$innerx lineh=0
        for kid in ${FT_KIDS[$name]}; do
            _ft_in_flow "$kid" || continue
            # captured: _ft_pass_arrange below recurses and rewrites FT_MARGIN_*
            _ft_margin4 "$kid"; local mt=$FT_MARGIN_TOP ml=$FT_MARGIN_LEFT
            w=$(( ${FT_MEASURED_WIDTH[$kid]:-0} + FT_MARGIN_LEFT + FT_MARGIN_RIGHT ))
            h=$(( ${FT_MEASURED_HEIGHT[$kid]:-0} + FT_MARGIN_TOP + FT_MARGIN_BOTTOM ))
            if _ft_is_inline "$kid"; then
                if (( cx > innerx && cx + w - innerx > innerw )); then
                    cy=$(( cy + lineh )); cx=$innerx; lineh=0
                fi
                _ft_pass_arrange "$kid" $(( cx + ml )) $(( cy + mt ))
                cx=$(( cx + w ))
                (( h > lineh )) && lineh=$h
            else
                if (( cx > innerx )); then cy=$(( cy + lineh )); cx=$innerx; lineh=0; fi
                _ft_pass_arrange "$kid" $(( innerx + ml )) $(( cy + mt ))
                cy=$(( cy + h ))
            fi
        done
        if (( scroll )); then
            local bot=$cy; (( cx > innerx )) && bot=$(( bot + lineh ))
            local contentH=$(( bot - (innery - stop) ))
            local maxs=$(( contentH - innerh )); (( maxs < 0 )) && maxs=0
            _ft_setprop "$name" scrollHeight "$contentH"
            _ft_setprop "$name" clientHeight "$innerh"
            if (( stop > maxs )); then      # content shrank under the scroll → clamp and re-place once
                _ft_setprop "$name" scrollTop "$maxs"
                _ft_pass_arrange "$name" "$ax" "$ay"
                return
            fi
            _ft_setprop "$name" scrollTop "$stop"
        fi
    fi

    # Absolutely-positioned children: left/top offsets from the content origin.
    for kid in ${FT_KIDS[$name]}; do
        _ft_disp "$kid"; [[ "$FT_RET" == none ]] && continue
        ft_own_prop "$kid" position; [[ "$FT_RET" == absolute ]] || continue
        ft_own_prop "$kid" left; local kl=${FT_RET:-0}
        ft_own_prop "$kid" top;  local kt=${FT_RET:-0}
        _ft_pass_arrange "$kid" $(( innerx + kl )) $(( innery + kt ))
    done
}

# ── Public layout entry points ───────────────────────────────────────────────
# ft_measure ROOT — sizes only (all four size-relevant passes, no positions).
ft_measure() {                  # root
    local root=$1
    _ft_pass_pref "$root"
    ft_own_prop "$root" width
    if [[ -n "$FT_RET" ]]; then
        _ft_clamp_w "$root" "$FT_RET"; FT_MEASURED_WIDTH[$root]=$FT_RET
    else
        FT_MEASURED_WIDTH[$root]=${FT_PREFERRED_WIDTH[$root]:-0}
    fi
    _ft_pass_width "$root"
    ft_own_prop "$root" height
    _ft_pass_height "$root" "$FT_RET"
}
# (ft_arrange stood here, a one-line public wrapper over _ft_pass_arrange with no caller
# anywhere and no mention in any doc. The tell was that its two natural callers reach past it:
# tools/bench-layout.bash times ft_measure and ft_layout by their public names and then calls
# _ft_pass_arrange directly, and controls/ft-tabs.bash does the same. A public name nobody
# uses is a promise the engine has to keep for nothing.)
# Full pass: measure then arrange at the root's own left/top (or 0,0).
declare -i FT_LAYOUT_EPOCH=0    # bumped per layout pass: "the geometry may have changed" in one int
ft_layout() {                   # root
    (( FT_LAYOUT_EPOCH++ ))
    ft_measure "$1"
    ft_own_prop "$1" left; local rl=${FT_RET:-0}
    ft_own_prop "$1" top;  local rt=${FT_RET:-0}
    _ft_pass_arrange "$1" "$rl" "$rt"
}

# ft_refresh [ROOT] — the one call after (re)building a screen: full layout,
# clear, repaint, flush — and, when new focusable controls were registered
# since the last ring build (a rebuild via ft_empty), resync the focus ring
# too (tab order is a living consequence of the tree, like a browser's).
#
# During INPUT COALESCING (the run loop draining a burst of held-key events),
# the expensive clear+repaint is DEFERRED: layout still runs so state/geometry
# stay correct, but the single paint happens once, after the burst — so
# holding a key that rebuilds the screen doesn't paint N screens back to back.
FT_COALESCING=0
FT_DEFER_ROOT=""
# ft_invalidate — a handler calls this to request that ft_run's RENDER
# callback rebuild the screen once, after the current input burst drains.
# This is the retained-mode pattern (mutate state + invalidate, render later):
# holding a key that advances "pages" runs the cheap state change N times but
# the expensive rebuild+paint exactly once. Without a render callback it's a
# harmless no-op flag.
FT_INVALIDATED=0
ft_invalidate() { FT_INVALIDATED=1; return 0; }
ft_refresh() {                  # [root]
    local root=${1:-$FT_ROOT}
    [[ -z "$root" ]] && return 1
    [[ -n "${FT_PENDING_FOCUS[$root]:-}" ]] && ft_focus_ring_build "$root"
    # Mid-burst, DON'T lay out either — the settle does it once for the final state, right
    # before it repaints. An app calling ft_refresh from a key handler used to pay a full
    # ft_layout per keystroke for a frame nobody was going to see.
    if (( FT_COALESCING )); then FT_DEFER_ROOT=$root; return 0; fi
    ft_layout "$root"
    ft_repaint_all "$root"
}

# ── Reflow (layout-property changes, invoked by ft_set) ───────────────────
# The CSS invariant: recompute only as far as sizes actually change.
#  • pure moves (left/top/position): re-arrange the parent's subtree — pure
#    position arithmetic, no measuring — and repaint it (the parent must
#    repaint vacated cells).
#  • size-affecting change whose resulting size is UNCHANGED: repaint just
#    this control('s subtree, for containers whose internals shifted).
#  • size actually changed: re-lay the nearest ancestor with an explicit
#    width AND height (else the root) and repaint within it. Nothing outside
#    that boundary is measured or painted, and the wrap/extent caches make
#    the re-measure cheap for unchanged text.
_ft_reflow_bound() {            # name → FT_RET (boundary ancestor)
    local n=$1 p w h
    while [[ -n "${FT_PARENT[$n]:-}" ]]; do
        p=${FT_PARENT[$n]}
        _ft_get_raw "$p" width;  w=$FT_RET
        _ft_get_raw "$p" height; h=$FT_RET
        n=$p
        [[ -n "$w" && -n "$h" ]] && break
    done
    FT_RET=$n
}
# (A second, earlier definition of this function stood here and was DEAD: the file defines it
# again further down, and the later definition silently won. The two differed — this one
# skipped a display:none subtree and read FT_KIDS without a `:-` default — so the behaviour
# everyone has actually been getting is the later one's. Removed rather than merged: making
# the dead one live is a behaviour change nobody asked for, and it belongs in its own commit
# with its own gate. Found by promoting the name to public and getting a duplicate.)

# _ft_effective_bg NAME → FT_RET = the SGR of the nearest solid background
# behind NAME (its own/ancestor backgroundColor, else the nearest frame body
# or the form's screen). Used to erase vacated cells when a subtree shrinks —
# containers (panel/div) are transparent and never repaint their own area, so
# the reflow must clear it to what shows THROUGH them.
_ft_effective_bg() {            # name → FT_RET
    local n=$1
    while [[ -n "$n" ]]; do
        _ft_color_override "$n" backgroundColor 48
        [[ -n "$FT_RET" ]] && { FT_RET="$FT_COLOR_BODY$FT_RET"; return; }
        case "${FT_TYPE[$n]:-}" in
            frame) FT_RET="$FT_COLOR_BODY";   return ;;
            form)  FT_RET="$FT_COLOR_SCREEN"; return ;;
        esac
        n=${FT_PARENT[$n]:-}
    done
    FT_RET="$FT_COLOR_BODY"
}
# _ft_erase_rect X Y W H NAME — fill a rectangle with NAME's effective
# background (clipped to NAME's overflow ancestors), appended to FT_OUT so a
# following redraw paints controls on top. Erases shrink/move residue.
_ft_erase_rect() {              # x y w h name
    local x=$1 y=$2 w=$3 h=$4 name=$5 r
    (( w < 1 || h < 1 )) && return
    _ft_effective_bg "$name"; local sgr=$FT_RET
    _ft_clip_for "$name"
    ft_fit "" "$w"
    # ft_print_at_width, not ft_print_at: the row is a COLOURED full-width fill, and ft_print_at's cheap clip test
    # is BYTE length — the SGR escapes inflate that past the right edge every time, forcing a
    # per-character ft_display_width scan of the whole row on every call. We built the row to
    # be exactly $w columns wide, so pass that. Measured on a 115x36 viewport: 69.4ms → 0.6ms
    # per erase, which is most of what made scrolling a container feel broken.
    for (( r=0; r<h; r++ )); do ft_print_at_width $(( y+r )) "$x" "$sgr$FT_FIT$FT_COLOR_RESET" "$w"; done
    ft_clip_reset
}

# COALESCED LAYOUT. Painting has always been deferred to the end of an input burst; the
# LAYOUT was not, so a burst of N keystrokes re-laid the tree N times and only painted once.
# That is what made a fast typist outrun the app: in demo/textfield-demo.bash each keystroke's
# onChange rewrites three labels, one re-layout apiece at ~84ms, so ~150ms of CPU per key —
# past ~7 keys/second the loop falls permanently behind and never catches up.
#
# During a burst a reflow is therefore RECORDED, not run, and every distinct control that
# asked is re-laid once when the burst drains. Deduplication is the whole win: N keystrokes
# × 3 labels becomes 3 reflows instead of 3N.
#
# Safe because nothing PAINTS mid-burst — the frame that reaches the terminal is always laid
# out first. The two places that would notice stale geometry flush explicitly: a mouse event
# (which hit-tests against FT_ABS_*) and opening a modal (which lays out over the tree).
declare -A FT_REFLOW_PENDING=()
FT_REFLOW_COUNT=0               # reflows actually PERFORMED — tests assert coalescing happened
ft_reflow() {                   # name [moved]
    if (( FT_COALESCING )); then
        # A full reflow is a superset of a moved-only one, so if any request for this control
        # was full, the pending one stays full.
        local cur=${FT_REFLOW_PENDING[$1]:-}
        if [[ "${2:-0}" == 0 || "$cur" == full ]]; then FT_REFLOW_PENDING[$1]=full
        else FT_REFLOW_PENDING[$1]=moved; fi
        return 0
    fi
    _ft_reflow_now "$@"
}
# The nearest common ancestor of two controls — walk the deeper one up to the shallower, then
# step both together. Used to collapse several pending reflows into one.
_ft_nca() {                     # a b → FT_RET
    local a=$1 b=$2 da=0 db=0 n
    n=$a; while [[ -n "$n" ]]; do (( da++ )); n=${FT_PARENT[$n]:-}; done
    n=$b; while [[ -n "$n" ]]; do (( db++ )); n=${FT_PARENT[$n]:-}; done
    while (( da > db )); do a=${FT_PARENT[$a]:-}; (( da-- )); done
    while (( db > da )); do b=${FT_PARENT[$b]:-}; (( db-- )); done
    while [[ -n "$a" && "$a" != "$b" ]]; do a=${FT_PARENT[$a]:-}; b=${FT_PARENT[$b]:-}; done
    FT_RET=$a
}
# Apply every reflow the burst recorded. Called wherever coalescing ends.
#
# SEVERAL controls pending are collapsed to ONE reflow of their nearest common ancestor. That
# is the case that actually hurts: an onChange mirroring a value into three labels reflowed
# three times per keystroke, and each of those could propagate to the root anyway — one
# re-layout of the container that holds all three does strictly less work than three that each
# climb past it. (Measured on demo/textfield-demo.bash: 277ms of reflow per keystroke.)
ft_reflow_flush() {
    (( ${#FT_REFLOW_PENDING[@]} )) || return 0
    local -a names=(); local n
    for n in "${!FT_REFLOW_PENDING[@]}"; do
        [[ -n "${FT_TYPE[$n]:-}" ]] && names+=("$n")        # skip anything removed mid-burst
    done
    local -A kinds=()
    for n in "${names[@]}"; do kinds[$n]=${FT_REFLOW_PENDING[$n]}; done
    FT_REFLOW_PENDING=()        # cleared FIRST: a reflow may itself ask for one
    (( ${#names[@]} )) || return 0
    if (( ${#names[@]} == 1 )); then
        n=${names[0]}
        [[ "${kinds[$n]}" == moved ]] && _ft_reflow_now "$n" 1 || _ft_reflow_now "$n"
        return 0
    fi
    local target=${names[0]} i
    for (( i=1; i<${#names[@]}; i++ )); do _ft_nca "$target" "${names[i]}"; target=$FT_RET; done
    [[ -n "$target" ]] || target=${names[0]}
    _ft_reflow_now "$target"
    return 0
}
_ft_reflow_now() {              # name [moved]
    local name=$1 moved=${2:-0}
    [[ -z "${FT_TYPE[$name]:-}" ]] && return
    FT_REFLOW_COUNT=$(( FT_REFLOW_COUNT + 1 ))

    if (( moved )); then
        local p=${FT_PARENT[$name]:-}
        [[ -z "$p" ]] && p=$name
        # erase where the moving control WAS, then re-arrange + redraw.
        _ft_erase_rect "${FT_ABSOLUTE_X[$name]:-0}" "${FT_ABSOLUTE_Y[$name]:-0}" "${FT_MEASURED_WIDTH[$name]:-0}" "${FT_MEASURED_HEIGHT[$name]:-0}" "$name"
        # …AND WHERE ITS SIBLINGS WERE. A control leaving the flow (position=absolute) or
        # rejoining it re-arranges every sibling, and a container without a draw repaints no
        # vacated cell: `beside` slid one column left and its last letter stayed standing in the
        # column it had left. The size-change path below has always erased the old box of
        # everything it re-lays; this is the same promise for the parent this path re-arranges.
        # (The control's own old box can lie outside the parent's, so both are erased — the
        # parent's to the ground behind IT, for the reason given on the unchanged-size path below.)
        [[ "$p" != "$name" ]] && _ft_erase_rect "${FT_ABSOLUTE_X[$p]:-0}" "${FT_ABSOLUTE_Y[$p]:-0}" "${FT_MEASURED_WIDTH[$p]:-0}" "${FT_MEASURED_HEIGHT[$p]:-0}" "${FT_PARENT[$p]:-$p}"
        _ft_pass_arrange "$p" "${FT_ABSOLUTE_X[$p]:-0}" "${FT_ABSOLUTE_Y[$p]:-0}"
        ft_dirty_subtree "$p"
        return
    fi

    local oldw=${FT_MEASURED_WIDTH[$name]:-} oldh=${FT_MEASURED_HEIGHT[$name]:-} oldpref=${FT_PREFERRED_WIDTH[$name]:-}
    _ft_pass_pref "$name"

    # An explicit width/height PROPERTY may itself have just changed (e.g. a
    # slider driving ft_set row width=…) — that's a size change by
    # definition; go straight to the bounded re-layout.
    ft_own_prop "$name" width; local expw=$FT_RET
    if [[ -n "$expw" ]]; then
        _ft_clamp_w "$name" "$expw"
        [[ "$FT_RET" != "$oldw" ]] && expw=""    # force the slow path below
    fi
    local exph_changed=0
    ft_own_prop "$name" height
    if [[ -n "$FT_RET" ]]; then
        _ft_clamp_h "$name" "$FT_RET"
        [[ "$FT_RET" != "$oldh" ]] && exph_changed=1
    fi
    if (( ! exph_changed )) && [[ -n "$expw" || "${FT_PREFERRED_WIDTH[$name]}" == "$oldpref" ]]; then
        # Used width can't have changed → only heights could. Recompute this
        # subtree's heights (same availability context it was laid under);
        # unchanged size = repaint locally and stop.
        _ft_pass_width "$name"
        _ft_pass_height "$name" "${FT_AVAILABLE_HEIGHT[$name]:-}"
        if [[ "${FT_MEASURED_WIDTH[$name]:-}" == "$oldw" && "${FT_MEASURED_HEIGHT[$name]:-}" == "$oldh" ]]; then
            _ft_pass_arrange "$name" "${FT_ABSOLUTE_X[$name]:-0}" "${FT_ABSOLUTE_Y[$name]:-0}"
            # THE BOX KEPT ITS SIZE; ITS CHILDREN DID NOT KEEP THEIR PLACES. `alignItems=center`
            # on a column moves every child inside an unchanged box, and a container paints no
            # vacated cell — the button's old cells stayed standing beside the centred one. The
            # bounded path below erases the old box of whatever it re-lays; this path re-arranges
            # just as much and owes the same. (A leaf's own draw covers its box.)
            # Erased to the ground BEHIND the box (the parent's): nothing in a full repaint paints
            # a container's own backgroundColor across cells its children leave empty.
            [[ -n "${FT_KIDS[$name]:-}" ]] && _ft_erase_rect "${FT_ABSOLUTE_X[$name]:-0}" "${FT_ABSOLUTE_Y[$name]:-0}" "$oldw" "$oldh" "${FT_PARENT[$name]:-$name}"
            ft_dirty_subtree "$name"
            return
        fi
    fi

    # Re-lay from the nearest ancestor with an explicit width AND height.
    #
    # TRIED AND REJECTED (measured, 2026-08-02): climbing one ancestor at a time and stopping
    # at the first whose own size is unchanged — the browser's dirty-propagation model. It is
    # the right IDEA and the wrong trade here, because deciding whether an ancestor absorbed
    # the change means calling _ft_pass_pref on it, which re-measures its whole subtree. Two
    # steps up a 21-control tree is two near-full measure passes BEFORE the real re-layout:
    # a growing label went 76ms → 130ms and a coalesced keystroke 134ms → 200ms. Stopping
    # earlier is worth nothing if finding the stopping point costs more than going all the way.
    # Making that pay needs cached/dirty-marked measurement, not a re-measure per step.
    _ft_reflow_bound "$name"; local bound=$FT_RET
    FT_REFLOW_LAST_BOUND=$bound     # diagnostic: how far up the change actually reached
    # OLD rectangle, captured before re-laying — erased afterward so a subtree that shrinks or
    # moves leaves no residue behind (containers are transparent and never repaint vacated cells).
    local obx=${FT_ABSOLUTE_X[$bound]:-0} oby=${FT_ABSOLUTE_Y[$bound]:-0}
    local obw=${FT_MEASURED_WIDTH[$bound]:-0} obh=${FT_MEASURED_HEIGHT[$bound]:-0}
    _ft_pass_pref "$bound"
    ft_own_prop "$bound" width
    if [[ -n "$FT_RET" ]]; then
        _ft_clamp_w "$bound" "$FT_RET"; FT_MEASURED_WIDTH[$bound]=$FT_RET
    else
        FT_MEASURED_WIDTH[$bound]=${FT_PREFERRED_WIDTH[$bound]:-0}
    fi
    _ft_pass_width "$bound"
    _ft_pass_height "$bound" "${FT_AVAILABLE_HEIGHT[$bound]:-}"
    _ft_pass_arrange "$bound" "$obx" "$oby"
    _ft_erase_rect "$obx" "$oby" "$obw" "$obh" "$bound"
    ft_dirty_subtree "$bound"
}

# ── Dirty set ────────────────────────────────────────────────────────────────
# "DIRTY" and "NEEDS REPAINTING" are not the same statement, and the retained display list is
# what made the difference matter. Dirty means THIS CONTROL'S CONTENT MAY HAVE CHANGED —
# re-derive it. The damage repair means SOMETHING PAINTED OVER YOUR CELLS — put the same ink
# back, which is an append (see FT_REPAIR, and _ft_damage_enlist which fills it).
declare -A FT_DIRTY=()
# Dropping the retained entry here rather than testing `is it dirty?` at the draw is the
# difference between a rule and a coincidence: the entry is gone from the moment anyone says the
# content may have moved, so no later path has to remember to ask. It also covers the state a
# token cannot see — a caret moving inside a field, a selection, an edit mode — because all of
# those already dirty the control they change.
# A CONTROL WHOSE PAINT IS DERIVED FROM ANOTHER CONTROL'S STATE MUST BE DIRTIED WITH IT, and
# until now nothing in the framework could say so. An `ft-scrollbar for=doc` reads the TARGET's
# scrollTop at draw time — a pull, which is right, and which is simply never called: scrolling
# the target enters the target in FT_DIRTY and nobody else, so ft_redraw_dirty repaints the
# document and leaves the bar's column showing where the content used to be. Measured, with
# writing the BAR's own offset as the control that proves the probe could see dirtiness at all:
#
#     ft_set bar scrollTop=3    dirty=[doc bar]      ← the coupling, wired
#     ft_set doc scrollTop=8    dirty=[doc]          ← the same coupling, not wired
#     ft_label_scroll_set doc 5    dirty=[doc]
#     the target's content shrinks dirty=[doc]
#
# It is not a scrollbar problem. A `keys=auto` keylegend is derived from the FOCUSED control's
# state the same way, and every future control that displays something another control owns will
# be too — so the framework gets the concept rather than the scrollbar getting a special case.
#
# COARSE ON PURPOSE: a dependent is repainted whenever its source is dirtied at all, not only
# when the particular fact it derives from moved. That is the same asymmetry the property-kind
# table is built on — a needless repaint costs microseconds, a skipped one leaves a lie on the
# screen — and the alternative needs every dependent to declare which facts it reads, which is
# exactly the sort of list this codebase keeps getting wrong.
declare -A FT_PAINT_DEPENDENTS=()
# …AND A SCALAR SAYING WHETHER THE TABLE HAS ANYTHING IN IT AT ALL, for the same reason
# _FT_CSS_FASTPATH_DECLARED exists a few hundred lines up: ft_dirty is called on every repaint,
# every focus move, every keystroke that changes anything, and the table is EMPTY in an app with
# no bound scrollbar — which is most of them. Measured, per ft_dirty call:
#
#     12 µs  before any of this
#     21 µs  with the walk done unconditionally   ← 75% on a function called thousands of times
#     17 µs  with this test in front of it
#     26 µs  when this control actually has a dependent, which is the work being asked for
#
# One scalar arithmetic test answers "is any of this worth doing" for every control at once, and
# five microseconds is what a conditional costs in bash — there is no cheaper way to ask.
#
# THE ALTERNATIVE WAS EXPANDING LAZILY, once per frame, inside ft_redraw_dirty: that would leave
# ft_dirty at exactly 12 µs, because the dirty set is not read until it is painted. It is not
# done that way on purpose. FT_DIRTY has more than one consumer — the redraw, the retained-block
# survey, the transition's snapshot — and expanding it in one of them would make "is this control
# going to be repainted" answerable two different ways depending on who asks. That is the precise
# shape of the bug this table exists to fix, and buying five microseconds with it would be a poor
# trade: a keystroke dirties two or three controls, and even a whole-page subtree dirty of forty
# pays 200 µs against a frame this project measures in tens of milliseconds.
declare -i _FT_PAINT_DEPS_N=0
ft_paint_depends_on() {         # dependent source — repaint DEPENDENT whenever SOURCE is dirtied
    local d=$1 s=$2
    [[ -n "$d" && -n "$s" ]] || return 0
    case " ${FT_PAINT_DEPENDENTS[$s]:-} " in *" $d "*) return 0 ;; esac
    FT_PAINT_DEPENDENTS[$s]="${FT_PAINT_DEPENDENTS[$s]:-}${FT_PAINT_DEPENDENTS[$s]:+ }$d"
    _FT_PAINT_DEPS_N=$(( _FT_PAINT_DEPS_N + 1 ))
}
ft_paint_depends_none() {       # dependent — forget every source it was registered against
    local d=$1 s keep t
    for s in "${!FT_PAINT_DEPENDENTS[@]}"; do
        keep=""
        for t in ${FT_PAINT_DEPENDENTS[$s]}; do
            if [[ "$t" == "$d" ]]; then _FT_PAINT_DEPS_N=$(( _FT_PAINT_DEPS_N - 1 ))
            else keep+="${keep:+ }$t"; fi
        done
        if [[ -n "$keep" ]]; then FT_PAINT_DEPENDENTS[$s]=$keep
        else unset "FT_PAINT_DEPENDENTS[$s]"; fi
    done
    (( _FT_PAINT_DEPS_N < 0 )) && _FT_PAINT_DEPS_N=0
    return 0
}
# The recursion is guarded by "was it already dirty", not by a depth counter: a dependency that
# points back at its own source settles after one hop instead of hanging the app, and a local
# counter cannot see mutual recursion anyway (reference: cycles hang or segfault).
ft_dirty()      { FT_DIRTY[$1]=1; unset "FT_RETAINED_TOKEN[$1]" "FT_RETAINED_BLOCK[$1]"
                  (( _FT_PAINT_DEPS_N )) || return 0
                  local _d
                  for _d in ${FT_PAINT_DEPENDENTS[$1]:-}; do
                      [[ -n "${FT_DIRTY[$_d]:-}" ]] || ft_dirty "$_d"
                  done
                  return 0; }
ft_clean()      { unset 'FT_DIRTY[$1]'; }
ft_is_dirty()   { [[ -n "${FT_DIRTY[$1]:-}" ]]; }
# (ft_dirty_list stood here: a public accessor with no caller anywhere in the tree, whose only
# return channel was stdout — so consuming it in-process needed the `$(...)` fork this file
# forbids beside ft_get, and calling it unwrapped in a running app would have printed control
# names onto the alt screen. `${!FT_DIRTY[@]}` is what its would-be callers want anyway.)

# Publish the mode-exit hint (see FT_MODE_HINT) and repaint the status bar(s) so it
# appears/vanishes at once. A no-op if the hint is unchanged. A control calls this on
# entering/leaving a special mode; it does not need to know WHICH control is the bar.
ft_set_mode_hint() {            # message ("" = navigation mode)
    [[ "$1" == "$FT_MODE_HINT" ]] && return 0
    FT_MODE_HINT=$1
    # Repaint BOTH bars: the statusbar shows the exit hint, the keylegend pulls Esc to front.
    local c
    for c in "${!FT_TYPE[@]}"; do case "${FT_TYPE[$c]}" in statusbar|keylegend) ft_dirty "$c" ;; esac; done
}

# Class types whose draw fills their WHOLE box (form, tabs). The damage repair skips such a node:
# the refill has already put its ground back, and repainting it would blank every sibling the
# rect never touched. (Children painted over by an ordinary repaint are repaired in
# ft_redraw_dirty for every container with a draw, declared here or not.)
declare -A FT_PROTO_FILLS_BACKGROUND=()
# Per-prototype property RECONCILER: <fn> NAME PROP VALUE, run by _ft_setprop after the property is
# stored, for prototypes whose real state lives in another property (see the checkbox note there).
declare -A FT_PROTO_SETPROP=()
declare -A FT_PROTO_LISTENERS=()    # type → "onActivate=fn onChange=g …" from its defaults
# A keys=auto keylegend derives its caps from the FOCUSED control (and its current state —
# edit mode, an active selection, …), so it must be repainted whenever any of that changes —
# otherwise the legend freezes on the first control's keys and looks dead. Cheap: normally a
# single legend. Call it on focus / edit / selection transitions.
_ft_legend_dirty() {
    local c
    for c in "${!FT_TYPE[@]}"; do
        [[ "${FT_TYPE[$c]}" == keylegend ]] || continue
        _ft_get_raw "$c" keys; [[ "$FT_RET" == auto ]] && ft_dirty "$c"
    done
}
_ft_focus_dirty() {             # name — dirty a control for a focus change
    # (:focus resolution follows FT_FOCUS, which is folded into the resolver cache token —
    # no epoch bump needed here.)
    _ft_legend_dirty            # keep any derived key legend in sync with the new focus
    [[ -z "$1" ]] && return
    local _ty=${FT_TYPE[$1]:-}          # separate line: an EMPTY subscript is a bash error,
    [[ -z "$_ty" ]] && return           # and a removed control can still be named as old focus
    ft_dirty "$1"                       # ft_redraw_dirty repairs the children a container covers
}

# ── Draw ─────────────────────────────────────────────────────────────────────
# Instance draw= override, else the prototype struct's draw function (filled by
# the constructor chain — a derived prototype that overrode it simply wrote a
# different name there). display=none controls are never drawn.
_ft_resolve_draw() {            # name → sets FT_RET (function name or "")
    local name=$1
    local fn=${FT_DRAW[$name]:-}
    local _ty=${FT_TYPE[$name]:-}      # empty once the control is removed
    [[ -z "$fn" && -n "$_ty" ]] && fn=${FT_PROTO_DRAW[$_ty]:-}
    if [[ -n "$fn" ]] && declare -F "$fn" >/dev/null 2>&1; then FT_RET=$fn; else FT_RET=""; fi
}
# _ft_clip_for NAME — set the paint clip (see ft-core's ft_print_at) to the
# intersection of every ancestor's content box whose overflow isn't visible:
# a control can never paint over its container's border or outside it.
# A PAINT PASS MAY DECLARE A BAND OF ROWS IT CARES ABOUT, and every draw in that pass then
# emits nothing outside it. Only ROWS, never columns: `ft_print_at`'s column guard drops a call whose
# START column is left of the clip — it does not left-truncate — so clamping columns would
# silently delete a label that begins outside the band and reaches into it. A row guard has no
# such asymmetry: a paint call is one row, and a row is either wanted or not.
#
# The transition machinery uses this to capture the GROUND under a rect: it re-runs the engine's
# own damage repair with the band set to the rect's rows, so the bytes it must parse back into
# cells are the rect's neighbourhood rather than the whole screen. Measured on a 40×8 rect over
# a 95×34 page: 8354 ground bytes → 1841, and the parse 91ms → 12ms.
# Wide open by default, so an ordinary frame is byte-identical.
FT_CLIP_BAND_R0=0; FT_CLIP_BAND_R1=999999
ft_clip_band()       { FT_CLIP_BAND_R0=$1; FT_CLIP_BAND_R1=$2; }
ft_clip_band_reset() { FT_CLIP_BAND_R0=0; FT_CLIP_BAND_R1=999999; }
# ── The clip memo ────────────────────────────────────────────────────────────
# THE WALK WAS THE FRAME. Wrapping every framework function and counting a css-demo drag frame:
# _ft_clip_for ran 25 times at ~1587µs, and ~74% of that was the _ft_inset4 it calls per
# ancestor. Removing the walk outright took the frame from ~102ms to ~78ms. It was asking the
# same ancestors the same question over and over — `app overflow` 21 times in one frame, `stage`
# 19.5, `win` 18.75 — about a tree that had not moved since layout.
#
# KEYED ON THE PARENT, NOT THE CONTROL, because the rect is built by walking from `$1`'s PARENT
# upward and never looks at `$1` itself. Every child of a container therefore computes the
# identical answer, and one entry serves all of them; a 37-control page has a handful of
# distinct chains, not 37.
#
# ── WHAT THE TOKEN CARRIES, AND WHY FT_LAYOUT_EPOCH IS NOT ENOUGH ────────────
# That counter is documented as "the geometry may have changed", and it is bumped in exactly one
# place: the first line of ft_layout. Every other route that moves a clip rect leaves it alone.
# Measured, not assumed — /tmp probe, reproduced in the commit message:
#
#     ft_set win padding=3      clip (1,1)-(18,58) → (4,4)-(15,55)   epoch 1 → 1
#     …after ft_reflow_flush too   unchanged                            epoch 1 → 1
#     ft_set win overflow=visible   (4,4)-(15,55) → (0,0)-(29,99)    epoch 1 → 1
#
# padding is layout-kind, so it reaches ft_reflow — but ft_reflow lands in _ft_reflow_now, which
# re-runs the passes directly and never bumps. `overflow` is worse: it is registered PAINT-kind
# (see _ft_pk), so it schedules no reflow at all, and it is the exact property this walk
# branches on. Neither bumps the descendants' _FT_CSS_VERSION either, because
# _ft_css_inval_prop only invalidates properties that INHERIT, and overflow/padding/border do
# not. So a memo keyed on FT_LAYOUT_EPOCH — or on the cascade token — serves a stale rect and
# the screen smears.
#
# Hence a counter of our own, bumped by hand at every route that can move an ancestor's
# overflow, inset, absolute geometry or parent link. Those routes are enumerated at
# _ft_clip_inval's callers; tests/test-clip.bash drives each one and fails if its bump is
# removed. The band, the terminal size and FT_LAYOUT_EPOCH ride along in the token as well —
# the band because ft_clip_band changes the answer mid-paint with no property change at all
# (the transition machinery narrows it around a nested paint), and the size because an app that
# supplies its own resize callback to ft_run is under no obligation to call ft_layout.
declare -A _FT_CLIP_CACHE=()    # "/parent" → "TOKEN<US>R0 C0 R1 C1"
                                # (_FT_CLIP_GEN and _ft_clip_inval: top of file)
_ft_clip_for() {                # name
    local n=${FT_PARENT[$1]:-} i x y r c
    # A leading marker keeps the key non-empty: the root has no parent, and an EMPTY subscript
    # is a bash error, not a miss.
    local _ckey="/$n"
    # FT_FOCUS and FT_ROOT ride along for the same reason the cascade's own token carries them:
    # `#win:focus { padding: 3 }` moves an ancestor's inset on a focus change, and a focus change
    # deliberately bumps NOTHING (_ft_focus_dirty says so — :focus is resolved through the token,
    # not through an epoch). _FT_CSS_EPOCH covers a sheet registering or a theme swapping.
    local _ctok="$_FT_CLIP_GEN:$FT_LAYOUT_EPOCH:${_FT_CSS_EPOCH:-0}:${FT_FOCUS:-}:${FT_ROOT:-}"
    _ctok+=":$FT_CLIP_BAND_R0:$FT_CLIP_BAND_R1:$FT_ROWS:$FT_COLS"
    local _chit=${_FT_CLIP_CACHE[$_ckey]:-}
    if [[ -n "$_chit" && "${_chit%%$'\x1f'*}" == "$_ctok" ]]; then
        # RE-ASSIGN ALL FOUR, never skip the write: callers mutate these globals after we
        # return (ft-select widens them for an open dropdown, _ft_toast_paint resets them),
        # so a hit must restore the rect, not assume it is still standing.
        set -- ${_chit#*$'\x1f'}
        FT_CLIP_R0=$1; FT_CLIP_C0=$2; FT_CLIP_R1=$3; FT_CLIP_C1=$4
        return
    fi
    FT_CLIP_R0=$FT_CLIP_BAND_R0; FT_CLIP_R1=$(( FT_ROWS - 1 ))
    (( FT_CLIP_BAND_R1 < FT_CLIP_R1 )) && FT_CLIP_R1=$FT_CLIP_BAND_R1
    FT_CLIP_C0=0; FT_CLIP_C1=$(( FT_COLS - 1 ))
    while [[ -n "$n" ]]; do
        ft_resolved_prop "$n" overflow hidden
        if [[ "$FT_RET" != visible ]]; then
            _ft_inset4 "$n"; local il=$FT_INSET_LEFT ir=$FT_INSET_RIGHT it=$FT_INSET_TOP ib=$FT_INSET_BOTTOM
            x=$(( ${FT_ABSOLUTE_X[$n]:-0} + il )); y=$(( ${FT_ABSOLUTE_Y[$n]:-0} + it ))
            c=$(( ${FT_ABSOLUTE_X[$n]:-0} + ${FT_MEASURED_WIDTH[$n]:-0} - ir - 1 ))
            r=$(( ${FT_ABSOLUTE_Y[$n]:-0} + ${FT_MEASURED_HEIGHT[$n]:-0} - ib - 1 ))
            (( x > FT_CLIP_C0 )) && FT_CLIP_C0=$x
            (( y > FT_CLIP_R0 )) && FT_CLIP_R0=$y
            (( c < FT_CLIP_C1 )) && FT_CLIP_C1=$c
            (( r < FT_CLIP_R1 )) && FT_CLIP_R1=$r
        fi
        n=${FT_PARENT[$n]:-}
    done
    _FT_CLIP_CACHE[$_ckey]="$_ctok"$'\x1f'"$FT_CLIP_R0 $FT_CLIP_C0 $FT_CLIP_R1 $FT_CLIP_C1"
}
# ── THE RETAINED DISPLAY LIST ────────────────────────────────────────────────
# What each control painted last time, and the conditions it painted it under. A repaint whose
# conditions have not moved is then an append instead of a derivation.
#
# WHY IT PAYS, measured on this tree (docs/rendering-spans-design.md has the full arithmetic):
# a control repaint is ~2% producing bytes and ~98% deciding what they should be — a 97-byte
# label costs 2.5ms of which ft_print_at_width is 65µs. So the win is not that re-emitting is
# cheaper than emitting; it is that an unchanged control need not ask the questions at all.
# A warm full repaint of css-demo page 1 derives in 88ms and re-emits in 0.5ms.
#
# THE ENTRY IS CONSULTED ONLY WHERE A REPAINT WOULD OTHERWISE RE-DERIVE, and it is dropped
# outright by ft_dirty — so retention can never be stale in a way the incremental repaint is
# not already stale, EXCEPT for state a full repaint used to launder. That is what the token is
# for: it carries the paint inputs that change with no property write behind them.
#
# WHAT THE TOKEN CARRIES, AND WHY EACH LINE IS IN IT:
#   FT_RETAIN_GENERATION      the escape hatch — ft_retain_inval, for a caller that knows it has
#                             changed something this list cannot see
#   _FT_CSS_EPOCH             a sheet registered, a theme swapped
#   _FT_RESOLVE_GENERATION    a prototype finished declaring; every resolution may differ
#   _FT_CSS_VERSION[name]     this node's scoped cascade version (already per-subtree)
#   _FT_RESOLVE_VERSION[name] this node's resolved-property version — an inheriting write
#                             anywhere above it bumps the whole subtree
#   _fti_<name>__writegen     the per-control write counter _ft_setprop ALREADY bumps on ANY
#                             property write. This is what makes the token cover `text=`,
#                             `value=`, `scrollTop`, `checked` and every other content property
#                             without enumerating them — and it covers them even when the write
#                             forgot to dirty, which is the failure this design most fears.
#                             NOT __textgen, which it used to be: that one is now narrowable by
#                             a prototype (`textProps=`) so a textfield stops re-wrapping its
#                             document on an unrelated write, and a counter a prototype may
#                             narrow is exactly what this token must not be built on
#   FT_FOCUS, FT_ROOT         :focus and :root change appearance and deliberately bump nothing
#   FT_COLOR_MODE, FT_USE_UTF8  8/256/truecolour, and whether glyphs degrade to ASCII
#   FT_ROWS, FT_COLS          the terminal size; an app may resize without laying out
#   FT_CLIP_BAND_R0/R1        the transition machinery narrows the band around a nested paint,
#                             with no property change at all. A piece recorded inside a narrowed
#                             band is not valid outside it (the same trap _ft_clip_for's own
#                             token was given this component for)
#   the control's absolute origin and measured box   a move is a new answer
#   the RESOLVED clip rect    not _FT_CLIP_GEN. The counter is bumped conservatively — building
#                             ANY modal bumps it, so a token carrying it would never validate on
#                             the one frame this list wins most (a modal closing over an app that
#                             has not changed). The rect that counter protects is what actually
#                             matters, _ft_clip_for has just been called anyway, and it is
#                             memoised: measured 31 of 32 controls served across a modal open+close
#   FT_ANIM_PHASE[name]       unconditionally, not gated on FT_CSS_ANIMATION_ON as _ft_compose_sgr
#                             gates it: a beacon pulses through FT_ANIM_PHASE with no @keyframes
#                             in sight. Leaving it out freezes an animation, and a golden
#                             screenshot of a frozen animation passes
#
# NOT in it, deliberately: FT_LAYOUT_EPOCH (a layout of ANOTHER root would invalidate everything
# while moving nothing — the control's own box and clip say whether it moved) and _FT_CLIP_GEN
# (above). Both are proxies for questions the token asks directly.
#
# EVERY ROUTE THAT DROPS AN ENTRY, which is the other half of the surface:
#   · ft_dirty / ft_dirty_subtree — the control's content may have changed
#   · _ft_release_control (ft_remove) — the name may be reused by a different control
#   · _ft_reparented — paint order and the clip chain both changed, for the whole subtree
#   · ft_retain_inval — the public sledgehammer
# tests/test-retain.bash drives each of them and fails if its drop is removed, and asserts the
# stronger property directly: for a matrix of mutations, every control whose bytes CHANGED must
# have had its entry dropped or its token moved.
declare -A FT_RETAINED_BLOCK=()   # name → the exact bytes its last ft_draw_one appended
declare -A FT_RETAINED_TOKEN=()   # name → the token those bytes were produced under
declare -i FT_RETAIN_GENERATION=0
# ft_retain_inval — forget every retained block. PUBLIC, because an application that paints
# outside the framework (writing to the tty itself, or through FT_OUT) has put ink on cells the
# list believes it owns, and there has to be a way to say so that is not an underscore.
ft_retain_inval() { (( FT_RETAIN_GENERATION++ )); return 0; }
# A PROTOTYPE MAY HAVE PAINT STATE THAT IS NOT A PROPERTY, and only the prototype knows about it. A
# textfield's caret, selection anchor and scroll offsets change what it paints and live in
# parallel arrays, so `_fti_<name>__textgen` — which covers every property write there is —
# cannot see them. Same shape as `_ft_ink_<type>`, and the same reason: nothing here knows what
# a textfield is. A prototype registers `FT_PROTO_PAINT_STATE[type]=fn`, fn answers in FT_RET,
# and a prototype with nothing to declare registers nothing and pays one array read.
#
# THE GATE FOUND THIS, which is worth recording: tests/test-stale.bash's "selecting across
# lines" scene moves an anchor and a caret and repaints, and the retained block served the old
# selection. That is exactly the hazard this design is most exposed to (§3.3 of
# docs/rendering-spans-design.md), caught on the first run by a file written for a different
# cache two months earlier.
declare -A FT_PROTO_PAINT_STATE=()
_ft_retain_token() {            # name → FT_RET   (_ft_clip_for NAME must have run first)
    local _rtg="_fti_${1}__writegen"
    FT_RET="$FT_RETAIN_GENERATION:${_FT_CSS_EPOCH:-0}:$_FT_RESOLVE_GENERATION"
    FT_RET+=":${FT_FOCUS:-}:${FT_ROOT:-}:$FT_COLOR_MODE:${FT_USE_UTF8:-0}"
    FT_RET+=":$FT_ROWS:$FT_COLS:$FT_CLIP_BAND_R0:$FT_CLIP_BAND_R1"
    FT_RET+=":${_FT_CSS_VERSION[$1]:-0}:${_FT_RESOLVE_VERSION[$1]:-0}:${!_rtg:-0}"
    FT_RET+=":${FT_ABSOLUTE_X[$1]:-}:${FT_ABSOLUTE_Y[$1]:-}"
    FT_RET+=":${FT_MEASURED_WIDTH[$1]:-}:${FT_MEASURED_HEIGHT[$1]:-}"
    FT_RET+=":$FT_CLIP_R0:$FT_CLIP_C0:$FT_CLIP_R1:$FT_CLIP_C1:${FT_ANIM_PHASE[$1]:-}"
    local _rps=${FT_PROTO_PAINT_STATE[${FT_TYPE[$1]:-}]:-}
    if [[ -n "$_rps" ]]; then
        local _rtbase=$FT_RET
        "$_rps" "$1"
        FT_RET="$_rtbase:$FT_RET"
    fi
}
ft_draw_one() {                 # name
    [[ -z "${FT_TYPE[$1]:-}" ]] && return 0
    # A CONTROL IN TRANSITION DOES NOT PAINT ITSELF. Its cells are being blended out of what
    # was underneath (ft-transition.bash), and every repaint path in the engine ends up here —
    # the dirty walk, both overlay compositors, the damage repair — so ONE guard covers all of
    # them. Without it a composite lands the finished control on top of its own half-melted
    # frame and the transition looks like a flicker. It returns BEFORE the retained list, so a
    # control that paints nothing because it is melting never records an empty block.
    [[ -n "${_FT_TRANSITION_LOADED:-}" && -n "${_FT_TRANSITION_ACTIVE[$1]:-}" ]] && return 0
    # ONE clip resolution per draw, and it happens here because the token needs it too. Nothing
    # between here and the painter touches the clip globals, so the branches below use this one.
    _ft_clip_for "$1"
    _ft_retain_token "$1"; local _rtok=$FT_RET
    # AN OVERLAY IS NEVER SERVED FROM ITS BLOCK, and this is the one exclusion in the design.
    # A callout's appearance is a function of a control it does not own — where its target sits,
    # and how much free space the rest of the screen leaves for a box and a leader — and it
    # discovers that by searching, during the draw. There is no key the engine can build before
    # the draw that says whether the answer moved, and a stale callout is a visible, reported
    # bug where a re-derived one is 6ms. Overlays still RECORD, because the damage repair and
    # both compositors reach them through here and the record costs nothing to keep.
    if [[ -z "${FT_OVERLAY[$1]:-}" && "$_rtok" == "${FT_RETAINED_TOKEN[$1]:-}" ]]; then
        # Not through _ft_print_bytes: this is a whole control's block going into the frame, not
        # a painter putting part of itself back, and ft_draw_one does not nest.
        FT_OUT+=${FT_RETAINED_BLOCK[$1]}
        ft_clip_reset
        return 0
    fi
    local _outer_block=$FT_BLOCK_BEING_DRAWN
    FT_BLOCK_BEING_DRAWN=""
    _ft_disp "$1"
    if [[ "$FT_RET" == none ]]; then
        # display:none paints nothing, and "nothing" is an answer worth retaining: the next
        # repaint then costs a token compare instead of a display resolution.
        FT_RETAINED_BLOCK[$1]=""; FT_RETAINED_TOKEN[$1]=$_rtok
        FT_BLOCK_BEING_DRAWN=$_outer_block
        ft_clip_reset
        return 0
    fi
    # CSS visibility: hidden keeps the layout space (unlike display=none) but
    # paints a blank — the box is erased, not skipped, so toggling it never
    # leaves stale pixels. Inherits, like CSS.
    ft_resolved_prop "$1" visibility visible
    if [[ "$FT_RET" == hidden ]]; then
        local _r _rows=${FT_MEASURED_HEIGHT[$1]:-0} _cols=${FT_MEASURED_WIDTH[$1]:-0}
        # WHAT SHOWS THROUGH A HIDDEN BOX IS WHAT IS BEHIND IT — the parent's ground, not the
        # frame-body grey. On the root form that is the cleared screen, and a hidden table there
        # stamped a grey column that its own draw, once shown again, never painted over.
        _ft_effective_bg "${FT_PARENT[$1]:-}"; local _ground=$FT_RET
        ft_fit "" "$_cols"
        for (( _r=0; _r<_rows; _r++ )); do
            ft_print_at_width $(( ${FT_ABSOLUTE_Y[$1]:-0} + _r )) "${FT_ABSOLUTE_X[$1]:-0}" "$_ground$FT_FIT$FT_COLOR_RESET" "$_cols"
        done
        ft_clip_reset
        FT_RETAINED_BLOCK[$1]=$FT_BLOCK_BEING_DRAWN; FT_RETAINED_TOKEN[$1]=$_rtok
        FT_BLOCK_BEING_DRAWN=$_outer_block
        return 0
    fi
    _ft_resolve_draw "$1"
    if [[ -n "$FT_RET" ]]; then
        local _fn=$FT_RET
        unset "FT_PAINT_RECT[$1]"          # the draw may publish a bigger one (it paints outside)
        "$_fn" "$1"                        # …under the clip resolved at the top of this function
        ft_clip_reset
        # Record what this control actually occupies now, so ft_damage_subtree can give those cells
        # back when it is hidden or removed.
        #
        # (Damaging the OLD rect here whenever a draw published a different one was the other half,
        # and it sat behind FT_DAMAGE_AUTO — a switch nothing set, after the note at
        # ft_damage_subtree recorded the gate as gone. Deleted rather than switched on: every way a
        # control moves already gives its old cells back where the move is known — a reflow erases
        # the boxes it re-lays, a beacon's reprop its footprint, a drag the exact cells it vacated —
        # and enabling it here would add a bounding-box repair to every one of those frames, the
        # cost the beacon's drag notes record at 1862ms of a 2100ms drag.)
        if [[ -z "${FT_PAINT_RECT[$1]:-}" ]]; then
            local _py=${FT_ABSOLUTE_Y[$1]:-} _px=${FT_ABSOLUTE_X[$1]:-}
            if [[ -n "$_py" && -n "$_px" ]]; then
                local _ph=${FT_MEASURED_HEIGHT[$1]:-0} _pw=${FT_MEASURED_WIDTH[$1]:-0}
                (( _ph >= 1 && _pw >= 1 )) && \
                    FT_PAINT_RECT[$1]="$_py $_px $(( _py+_ph-1 )) $(( _px+_pw-1 ))"
            fi
        fi
    fi
    # A scrollable container paints its bar(s) in the reserved gutter (see _ft_inset4) — after
    # its own draw, and regardless of whether the prototype has one (divs/panels often don't).
    local _sgv="_ftp_${1}_scrollHeight" _sgh="_ftp_${1}_scrollWidth"
    if [[ -n "${!_sgv:-}${!_sgh:-}" ]]; then
        _ft_clip_for "$1"                  # the painter above may have widened the rect
        _ft_scroll_gutter_draw "$1"
        ft_clip_reset
    fi
    # THE TOKEN STORED IS THE ONE TAKEN BEFORE THE DRAW, not a fresh one. A painter is allowed
    # to change something the token carries (the status bar re-arms its own animation), and a
    # token taken afterwards would certify the new conditions for bytes made under the old ones.
    # Taken before, any such change simply makes the entry miss next time, which is right.
    FT_RETAINED_BLOCK[$1]=$FT_BLOCK_BEING_DRAWN; FT_RETAINED_TOKEN[$1]=$_rtok
    FT_BLOCK_BEING_DRAWN=$_outer_block
    return 0
}
# The scrollbar indicator: a proportional thumb (█, knob-coloured) on a faint track, drawn in
# the gutter column/row _ft_inset4 reserved. Only drawn while the content actually overflows
# (CSS overflow:auto semantics — the gutter itself stays, so nothing reflows when it appears).
# A container's scroll gutter behaves like a scrollbar under the mouse: press to jump, drag
# to follow. The grab is remembered for the whole drag (a desktop scrollbar keeps scrolling
# when the pointer slides off the one-cell-wide bar), and the AXIS is decided at press time
# ── Does this box show a scrollbar? ──────────────────────────────────────────
# ONE QUESTION, ONE ANSWER. Three routes used to decide this and each asked something
# different: the label's own metrics asked `overflowY` falling back to `overflow` and required
# auto|scroll (right), the gutter PAINTER asked nothing at all (so it drew a bar on a box whose
# overflow was `visible`), and the mouse hit-test asked `overflow` but never `overflowY` (so it
# could not find the bar on a control that set the axis property). tutorial-demo step 5 exists
# to teach that `overflowY=visible` means "do not clip, no scrollbar" — and the engine painted
# a scrollbar next to it, contradicting the lesson the page is there to give.
#
# _ft_overflow_mode is the used value for one axis: the axis property if the cascade sets one,
# otherwise the shorthand, otherwise CSS's initial `auto`.
_ft_overflow_mode() {           # name y|x → FT_RET
    local axis_property=overflowY
    [[ "$2" == x ]] && axis_property=overflowX
    ft_resolved_prop "$1" "$axis_property" ""
    [[ -z "$FT_RET" ]] && ft_resolved_prop "$1" overflow auto
    return 0
}
# ft_has_scrollbar NAME [y|x] → 0 when that axis presents a scrollbar: the overflow mode asks
# for one AND the content actually overflows. `hidden` and `clip` overflow without a bar (and
# `hidden` is still scrollable programmatically); `visible` does not even clip.
#
# It reads the published scrollHeight/clientHeight pair, so it answers for anything that
# publishes them — a container from its arrange, a label from its metrics. That also means a
# control which PRODUCES those numbers must not ask this question about itself: see
# _ft_label_metrics, which owns the other half of the answer and shares only the mode above.
ft_has_scrollbar() {            # name [y|x]
    local name=$1 axis=${2:-y} scroll_size client_size
    _ft_overflow_mode "$name" "$axis"
    case "$FT_RET" in auto|scroll) ;; *) return 1 ;; esac
    if [[ "$axis" == x ]]; then
        ft_get "$name" scrollWidth;  scroll_size=${FT_RET:-0}
        ft_get "$name" clientWidth;  client_size=${FT_RET:-0}
    else
        ft_get "$name" scrollHeight; scroll_size=${FT_RET:-0}
        ft_get "$name" clientHeight; client_size=${FT_RET:-0}
    fi
    [[ "$scroll_size" =~ ^[0-9]+$ ]] || return 1
    (( scroll_size > client_size && client_size > 0 ))
}

# so a container with both gutters never switches axis mid-drag.
_FT_GUTTER_GRAB=""; _FT_GUTTER_AXIS=v
# _ft_scroll_gutter_at HIT X Y → 0, FT_RET=CONTAINER, _FT_GUTTER_AXIS set. Walks UP from the
# control under the pointer, because the gutter belongs to an ANCESTOR of whatever is
# nominally at that cell (the container itself is usually inert).
_ft_scroll_gutter_at() {        # hit x y → FT_RET = container
    local n=${1:-} x=$2 y=$3 sh ch sw cw
    [[ -n "$n" ]] || n=${FT_ROOT:-}
    # The SAME question the painter asks, so a bar you can see is a bar you can grab. This
    # route used to read `overflow` and `overflowX` raw, which missed both the cascade (a
    # stylesheet's overflow was invisible to it) and `overflowY` (a control that set the axis
    # property had a bar nothing could grab). Including, now, the childless test — a bar this
    # gutter does not paint is not a bar it may claim a click on, or a drag on a label's own
    # scrollbar would be captured by the container path instead of the label's.
    while [[ -n "$n" ]]; do
        if [[ -n "${FT_KIDS[$n]:-}" ]] && ft_has_scrollbar "$n" y; then
            ft_get "$n" clientHeight; ch=${FT_RET:-0}
            _ft_inset4 "$n"
            if (( FT_INSET_RIGHT > 0 )); then
                local col=$(( ${FT_ABSOLUTE_X[$n]:-0} + ${FT_MEASURED_WIDTH[$n]:-0} - FT_INSET_RIGHT ))
                local top=$(( ${FT_ABSOLUTE_Y[$n]:-0} + FT_INSET_TOP ))
                if (( x == col && y >= top && y < top + ch )); then
                    _FT_GUTTER_AXIS=v; FT_RET=$n; return 0
                fi
            fi
        fi
        if [[ -n "${FT_KIDS[$n]:-}" ]] && ft_has_scrollbar "$n" x; then
            ft_get "$n" clientWidth; cw=${FT_RET:-0}
            _ft_inset4 "$n"
            if (( FT_INSET_BOTTOM > 0 )); then
                local row=$(( ${FT_ABSOLUTE_Y[$n]:-0} + ${FT_MEASURED_HEIGHT[$n]:-0} - FT_INSET_BOTTOM ))
                local left=$(( ${FT_ABSOLUTE_X[$n]:-0} + FT_INSET_LEFT ))
                if (( y == row && x >= left && x < left + cw )); then
                    _FT_GUTTER_AXIS=h; FT_RET=$n; return 0
                fi
            fi
        fi
        n=${FT_PARENT[$n]:-}
    done
    return 1
}
# Scroll CONTAINER so its thumb sits under the pointer — the same mapping the scrollbar
# control uses, so grabbing a gutter and grabbing a bar feel identical.
_ft_scroll_gutter_drag() {      # container axis x y
    local n=$1 axis=$2 x=$3 y=$4
    _ft_inset4 "$n"
    if [[ "$axis" == v ]]; then
        ft_get "$n" scrollHeight; local sh=${FT_RET:-0}
        ft_get "$n" clientHeight; local ch=${FT_RET:-0}
        [[ "$sh" =~ ^[0-9]+$ ]] && (( sh > ch && ch > 0 )) || return 0
        ft_scrollbar_pos_from_point "$n" $(( ${FT_ABSOLUTE_Y[$n]:-0} + FT_INSET_TOP )) "$ch" "$sh" "$ch" "$y"
        _ft_scroll_apply "$n" "$FT_RET" ""
    else
        ft_get "$n" scrollWidth; local sw=${FT_RET:-0}
        ft_get "$n" clientWidth; local cw=${FT_RET:-0}
        [[ "$sw" =~ ^[0-9]+$ ]] && (( sw > cw && cw > 0 )) || return 0
        ft_scrollbar_pos_from_point "$n" $(( ${FT_ABSOLUTE_X[$n]:-0} + FT_INSET_LEFT )) "$cw" "$sw" "$cw" "$x"
        _ft_scroll_apply "$n" "" "$FT_RET"
    fi
    return 0
}
# A GUTTER IS A RESERVED COLUMN, AND THIS PAINTS IN IT. Both halves of that sentence are
# guards. It used to ask neither, and drew a bar whenever a scrollHeight property merely
# EXISTED — at `x + width - FT_INSET_RIGHT`, which with nothing reserved is one column PAST
# the box, on top of whatever is next to it. A label that scrolls already paints its own bar
# in its own last column (controls/ft-label.bash), so the bar outside was a duplicate of a
# correct one; a label with `overflowY=visible` got one it should never have had at all.
#
# …AND THE DUPLICATE SURVIVED THAT FIX, because a scrolling label DOES reserve a right column:
# `_ft_inset4` adds the gutter when the `overflow` SHORTHAND is auto|scroll, which is exactly
# how `ft-label overflow=scroll` is written. Measured — for a 12-line label in a 4-row box, the
# label's own paint and this one both address column 20. Two painters, one column, every frame.
# They agree today only because both call ft_scrollbar_paint with numbers derived the same way;
# the label computes its range from LBL_MAXSCROLL at the drawing width while this reads the
# published pair, and the moment those disagree the bar has two positions.
#
# THE PREDICATE IS "DOES THIS BOX SCROLL ITS CHILDREN", and a box with no children does not.
# That is the same distinction _ft_pass_arrange had to learn (a childless control measures its
# own content and publishes its own scrollHeight; the container branch published 0 over it), and
# it is the honest one: this gutter exists for a scroll CONTAINER. A control that scrolls its
# own content — label, table, textfield — draws its own bar, in its own well, with its own
# range, and does not want a second one painted over it by the engine.
_ft_scroll_gutter_draw() {      # name
    local name=$1 sh ch sw cw
    [[ -n "${FT_KIDS[$name]:-}" ]] || return 0
    _ft_inset4 "$name"
    if (( FT_INSET_RIGHT > 0 )) && ft_has_scrollbar "$name" y; then
        ft_get "$name" scrollHeight; sh=${FT_RET:-0}
        ft_get "$name" clientHeight; ch=${FT_RET:-0}
        local col=$(( ${FT_ABSOLUTE_X[$name]:-0} + ${FT_MEASURED_WIDTH[$name]:-0} - FT_INSET_RIGHT ))   # the reserved column
        local top=$(( ${FT_ABSOLUTE_Y[$name]:-0} + FT_INSET_TOP ))
        ft_get "$name" scrollTop; local st=${FT_RET:-0}
        # The SAME renderer the scrollbar control uses, so a container's gutter and a real
        # ft-scrollbar are one look, one theme, one set of ::scrollbar / ::track rules.
        ft_scrollbar_paint "$name" "$top" "$col" "$ch" 0 "$sh" "$ch" "$st"
    fi
    if (( FT_INSET_BOTTOM > 0 )) && ft_has_scrollbar "$name" x; then
        ft_get "$name" scrollWidth; sw=${FT_RET:-0}
        ft_get "$name" clientWidth; cw=${FT_RET:-0}
        local row=$(( ${FT_ABSOLUTE_Y[$name]:-0} + ${FT_MEASURED_HEIGHT[$name]:-0} - FT_INSET_BOTTOM ))   # the reserved row
        local left=$(( ${FT_ABSOLUTE_X[$name]:-0} + FT_INSET_LEFT ))
        ft_get "$name" scrollLeft; local sl=${FT_RET:-0}
        ft_scrollbar_paint "$name" "$row" "$left" "$cw" 1 "$sw" "$cw" "$sl"
    fi
    return 0
}
ft_redraw_all() {               # root — full walk, root first, flush once
    [[ -n "$1" ]] && _ft_redraw_walk "$1"    # no root (e.g. a modal closing with no host app) → just flush
    _ft_composite_overlays                   # overlays on top of every sibling in the walk
    ft_flush
    # A FULL REDRAW SATISFIES EVERY OUTSTANDING DAMAGE RECT, so carrying them forward is worse
    # than useless: the next incremental frame would refill and repaint regions described in
    # the PREVIOUS page's geometry, against controls that no longer exist there. That is a
    # stale repaint, and it is exactly what a page rebuild produces now that ft_remove damages
    # — `ft_empty stage` removes ~100 controls, each raising a rect, and _show_page then ends
    # in a full ft_refresh. test-notrace caught it as a code pane still showing the old page.
    #
    # DAMAGE ONLY, deliberately: a control's draw is allowed to dirty another control (the
    # status bar re-arms its sweep when its synopsis changes), and those dirties are set DURING
    # the walk above — clearing them here would drop a repaint the walk itself asked for. A
    # redundant dirty costs one extra paint; a dropped one is a stale screen. FT_REPAIR carries
    # no such claim: it says "your cells were painted over", and the walk has just painted them.
    FT_DAMAGE=(); FT_REPAIR=()
}
# ft_repaint_all [ROOT] — blank the screen and paint it again from nothing.
#
# THE ONE CALL, replacing fourteen copies of `FT_OUT+=clear; ft_redraw_all "$root"` in ft-help,
# ft-settings, ft-filedialog, ft_refresh, ft_run's resize path and the test harness. CONTRIBUTING
# §1: a fix repeated per case is at the wrong layer, and this one had to become a single place
# before the retained display list could exist at all — every copy is a point where the screen
# goes blank and the list would not know.
#
# It does NOT lay out. A modal that closes over an app which has not moved should not re-measure
# it, and that is exactly the frame retention wins most: measured on css-demo page 1, deriving
# the page costs 88ms and re-emitting 31 of its 32 retained blocks costs 0.5ms.
ft_repaint_all() {              # [root=FT_ROOT]
    FT_OUT+="$FT_COLOR_SCREEN$FT_ANSI_CLEAR_SCREEN"
    ft_redraw_all "${1:-${FT_ROOT:-}}"
}

# ── Animation ────────────────────────────────────────────────────────────────
# A control animates by registering a FRAME COUNT; each tick bumps its phase and
# repaints it, and it de-registers itself when the last frame lands. The tick is
# free: ft_next_event already polls on a timeout, so we only shorten the poll WHILE
# something is animating (idle apps keep the lazy 0.25s poll and burn nothing). A
# real keystroke wins the read immediately, so animation never costs input latency.
declare -A FT_ANIM_PHASE=() FT_ANIM_LENGTH=() FT_ANIM_FRAME_MS=() FT_ANIM_STEP=() FT_ANIM_LOOP=() FT_ANIM_ACCUMULATED_MS=() \
           FT_ANIM_FRAME=() FT_ANIM_STRUCT=() FT_ANIM_DEBOUNCE=() FT_ANIM_HOLD=() FT_ANIM_KEEP=() \
           FT_ANIM_REST_MS=() FT_ANIM_REST_UNTIL_MS=()
FT_ANIM_ACTIVE=0
# Phase and length are measured in CELLS, never in frames, so an effect describes
# a DISTANCE and never has to know the frame rate. Each animation carries its own
# pace, because the two effects want opposite things:
#
#   the status bar's sweep  — a one-shot ANNOUNCEMENT. Fast and over with.
#   a field's border shimmer — AMBIENT, running the whole time you are in the
#                              field. It must be slow, faint, and above all cheap:
#                              it is the thing that must never become annoying.
#
# Cost is the reason pace is per-animation and not one global knob. A multiline
# field costs ~5ms to repaint; at 50fps that is 25% of a core burning for as long
# as the caret sits there. The shimmer therefore ticks in the tens of fps, while
# the bar's half-second sweep can afford to be smooth.
#
# CONSTRAINT: no effect may use a crest NARROWER than its own step. A crest that
# moves farther per frame than it is wide skips cells, and the wave breaks into
# strobing dots instead of travelling. Widen the crest before raising the step.
FT_ANIM_INTERVAL=0.02           # read -t seconds: the FASTEST live animation's need
FT_ANIM_POLL_MS=20              # ...the same, in ms
FT_ANIM_FRAME_MS_DEFAULT=20               # default ms per frame
FT_ANIM_SPEED=8                 # default cells per frame

# The poll must run as fast as the most demanding live animation, and no faster:
# slower animations skip ticks via their own accumulator rather than dragging the
# whole loop down to their pace.
_ft_anim_repoll() {
    local n best=1000
    # Expanded bare: every FT_ANIM_* array is declared `=()`, and only that makes it safe.
    # A `declare -A X` with NO `=()` leaves X unset as far as bash is concerned, so
    # `${#X[@]}` on it is an unbound-variable error under `set -u` (the demos use it).
    # `${!X[@]}` and `${X[@]}` do NOT trip it on bash >= 4.4 — only the `${#…}` form.
    for n in "${!FT_ANIM_FRAME_MS[@]}"; do (( FT_ANIM_FRAME_MS[$n] < best )) && best=${FT_ANIM_FRAME_MS[$n]}; done
    (( best < 10 )) && best=10          # a floor: bash is not a game engine
    FT_ANIM_POLL_MS=$best
    printf -v FT_ANIM_INTERVAL '%d.%03d' $(( best / 1000 )) $(( best % 1000 ))
    FT_ANIM_ACTIVE=${#FT_ANIM_PHASE[@]}
}

ft_anim_start() {               # name cells [ms] [step] [loop] [start_phase] — (re)start it
    [[ -z "${FT_TYPE[$1]:-}" ]] && return 1
    local n=$1
    # start_phase (default 0) seeds the opening frame. Pass a saved phase — or use
    # ft_anim_resume — so an effect that STOPS and later RE-ARMS on the next event picks
    # up exactly where it froze, instead of snapping back to 0. This is what lets the
    # per-key legend animations alternate across activate/typing-delay events smoothly.
    FT_ANIM_PHASE[$n]=${6:-0};      FT_ANIM_LENGTH[$n]=$2
    FT_ANIM_FRAME_MS[$n]=${3:-$FT_ANIM_FRAME_MS_DEFAULT}
    FT_ANIM_STEP[$n]=${4:-$FT_ANIM_SPEED}
    FT_ANIM_LOOP[$n]=${5:-0}       # 1 = wrap forever instead of retiring
    FT_ANIM_ACCUMULATED_MS[$n]=0
    # A fresh start has no bound routine/structure/debounce until ft_anim_bind sets
    # them — otherwise a role left over from a previous animation (e.g. a debounce)
    # would leak into this one.
    FT_ANIM_FRAME[$n]=""; FT_ANIM_STRUCT[$n]=""; FT_ANIM_DEBOUNCE[$n]=0; FT_ANIM_HOLD[$n]=""
    unset "FT_ANIM_REST_MS[$n]" "FT_ANIM_REST_UNTIL_MS[$n]"
    # …and it has named no frame yet, and knows nothing about what is on the screen.
    unset "FT_ANIM_SIGNATURE[$n]" "FT_ANIM_SIGNATURE_ON_SCREEN[$n]"
    _ft_anim_repoll; ft_dirty "$n"; return 0
}
# ft_anim_rest NAME MS — pause MS between laps of a looping animation.
#
# A REST IS A DELAY, AND IT USED TO BE EXPRESSED AS DISTANCE. With no way to say "wait", an
# effect that wanted to sweep, pause, and sweep again had to pad its LENGTH with cells nobody
# draws — the status bar's mode sweep armed `cols + wave + 300`, and every one of those 300
# cells cost a wake and a full repaint of a bar that had not changed. Measured: sitting in an
# edit mode with your hands still cost 12.2% of a core, against 0.6% outside one.
#
# Padding the length is also a lie about the animation: its phase no longer maps to its
# picture, so nothing downstream can reason about how many frames it really has.
ft_anim_rest() {                # name ms
    [[ -n "${FT_ANIM_PHASE[$1]:-}" ]] || return 0
    FT_ANIM_REST_MS[$1]=$2
    return 0
}
# ft_anim_stop_subtree NAME — stop every animation on NAME or anything under it. The engine's
# one answer to "this is no longer being drawn", so a route that hides something asks this
# rather than carrying its own copy of the rule.
#
# It walks the REGISTRY, not the subtree. The registry holds one entry per live animation —
# typically one or two — while the subtree being hidden is a whole tab body; asking "is this
# animated control inside that?" a couple of times is far cheaper than visiting every
# descendant to ask "are you animating?". `${!FT_ANIM_PHASE[@]}` expands to a list before the
# loop body runs, so retiring entries while iterating is safe.
ft_anim_stop_subtree() {        # name
    (( FT_ANIM_ACTIVE )) || return 0
    local root=$1 animated ancestor
    for animated in "${!FT_ANIM_PHASE[@]}"; do
        ancestor=$animated
        while [[ -n "$ancestor" ]]; do
            if [[ "$ancestor" == "$root" ]]; then ft_anim_stop "$animated"; break; fi
            ancestor=${FT_PARENT[$ancestor]:-}
        done
    done
    return 0                    # a subtree with nothing animating in it is not a failure
}
ft_anim_stop() {
    # A TRANSITION ENDS WHERE ITS ANIMATION ENDS — retired normally, cancelled, or killed
    # because the control was destroyed mid-flight. All three arrive here, so the hand-back
    # ("your cells are yours again") is done here and nowhere else, and the ft_dirty every
    # caller already does then lays down the real control.
    [[ -n "${_FT_TRANSITION_LOADED:-}" && -n "${_FT_TRANSITION_ACTIVE[$1]:-}" ]] && _ft_transition_retire "$1"
    # Remember the phase we stopped ON, so a later ft_anim_resume continues from here
    # (the effect "freezes" between events instead of restarting). Cheap: one scalar.
    [[ -n "${FT_ANIM_PHASE[$1]:-}" ]] && (( FT_ANIM_PHASE[$1] >= 0 )) && FT_ANIM_KEEP[$1]=${FT_ANIM_PHASE[$1]}
    unset "FT_ANIM_PHASE[$1]" "FT_ANIM_LENGTH[$1]" "FT_ANIM_FRAME_MS[$1]" \
          "FT_ANIM_STEP[$1]" "FT_ANIM_LOOP[$1]" "FT_ANIM_ACCUMULATED_MS[$1]" \
          "FT_ANIM_FRAME[$1]" "FT_ANIM_STRUCT[$1]" "FT_ANIM_DEBOUNCE[$1]" "FT_ANIM_HOLD[$1]" \
          "FT_ANIM_REST_MS[$1]" "FT_ANIM_REST_UNTIL_MS[$1]" \
          "FT_ANIM_SIGNATURE[$1]" "FT_ANIM_SIGNATURE_ON_SCREEN[$1]"
    _ft_anim_repoll
}
# ft_anim_resume NAME CELLS [ms] [step] [loop] — start, but continue from the phase the
# last run froze on (0 if it never ran). The sibling of ft_anim_start for the common
# event-driven case "keep going from where you were."
ft_anim_resume() {              # name cells [ms] [step] [loop]
    ft_anim_start "$1" "$2" "${3:-$FT_ANIM_FRAME_MS_DEFAULT}" "${4:-$FT_ANIM_SPEED}" "${5:-0}" "${FT_ANIM_KEEP[$1]:-0}"
}
# ft_anim_phase_set NAME PHASE — jump a live animation to PHASE (and remember it for the
# next resume). Lets a caller drive the phase directly, e.g. to seed one effect from
# another's, so alternating animations stay visually continuous.
ft_anim_phase_set() {           # name phase
    [[ -n "${FT_ANIM_PHASE[$1]:-}" ]] && FT_ANIM_PHASE[$1]=$2
    FT_ANIM_KEEP[$1]=$2
}
# ft_anim_bind NAME FRAME STRUCT [DEBOUNCE_MS] [HOLD_STRUCT] — attach an animation
# ROUTINE. The engine calls it every frame as  FRAME  INSTANCE  STRUCTURE, forwarding
# BOTH the control instance AND the structure inside it the routine acts on (a border,
# a borderGlow, a label's text, …) — one routine ("sheen") branches on the structure,
# and callers never hand-forward those args.
#   DEBOUNCE_MS (0 = none) — until the user has been quiet this long, the MAIN phase is
#     held: the phase does not advance.
#   HOLD_STRUCT — what to paint DURING that hold. Empty → freeze (paint nothing new).
#     Set → the engine calls FRAME INSTANCE HOLD_STRUCT at the frozen phase, so an
#     effect can show one thing while you type (e.g. a glow that appears the instant you
#     activate, kept in phase) and its full self ("STRUCT") only once you pause.
# With no FRAME bound, a due frame just marks the control dirty (a full redraw) — how
# the status-bar sweep repaints.
ft_anim_bind() {                # name frame struct [debounce_ms] [hold_struct]
    FT_ANIM_FRAME[$1]=$2; FT_ANIM_STRUCT[$1]=$3; FT_ANIM_DEBOUNCE[$1]=${4:-0}; FT_ANIM_HOLD[$1]=${5:-}
}
ft_anim_phase() { FT_RET=${FT_ANIM_PHASE[$1]--1}; }   # -1 = not animating

# ── Easing: animation-timing-function, verbatim from CSS ─────────────────────
# The engine's phase advances LINEARLY — it must, it is a cell counter — so anything that
# wants to accelerate, decelerate or OVERSHOOT has to map that linear phase through a curve.
# CSS already has this concept and already has the surface for it, so the surface is copied
# rather than invented: `animation-timing-function` (kebab in a stylesheet, camelCase as a
# control property — _ft_css_camel makes those the same property), and the values are CSS's:
#
#     linear | ease | ease-in | ease-out | ease-in-out | cubic-bezier(x1,y1,x2,y2)
#
# …plus three names CSS does NOT define but every easing library does, because the whole
# point of a cartoon bounce is a curve whose OUTPUT LEAVES 0..1 and CSS has no keyword for
# it. They are exact aliases for the canonical cubic-bezier() everyone means by them, and
# they are spelled the way easings.net spells them so nobody has to guess:
#
#     ease-out-back    =  cubic-bezier(0.34, 1.56, 0.64, 1)    ← overshoot, then settle
#     ease-in-back     =  cubic-bezier(0.36, 0, 0.66, -0.56)   ← wind up backwards, then go
#     ease-in-out-back =  cubic-bezier(0.68, -0.6, 0.32, 1.6)
#
# The three are quoted from easings.net, verbatim, and tests/test-bigarrow.bash pins them —
# ease-in-back was first written from memory as (0.36,-0.28,0.66,-0.06), whose y ENDS at -0.06
# instead of 1, i.e. an easing that never arrives. It looked plausible and it was wrong.
#
# FIXED POINT, IN THOUSANDTHS, because bash has no floats. Progress in, eased value out,
# both scaled by 1000 — and the OUT value is deliberately allowed past 1000 and below 0,
# since that IS the overshoot. Everything fits a 64-bit int with room: the widest term is
# 3·u²·t·y1 ≤ 3·10⁹·1600 ≈ 4.8e12.
#
# Cost: a bisection of 12 rounds, ~60 arithmetic evaluations, and it is called ONCE PER
# ANIMATION at arm time to precompute the whole curve — never in a frame. See
# ft_ease_table, which is what callers actually want.
declare -A _FT_EASE_NAMED=(
    [linear]="0 0 1000 1000"          [ease]="250 100 250 1000"
    [ease-in]="420 0 1000 1000"       [ease-out]="0 0 580 1000"
    [ease-in-out]="420 0 580 1000"
    [ease-out-back]="340 1560 640 1000"
    [ease-in-back]="360 0 660 -560"
    [ease-in-out-back]="680 -600 320 1600"
)
# ft_ease_points SPEC → FT_RET = "x1 y1 x2 y2" in thousandths (linear if unrecognised).
ft_ease_points() {              # spec
    local s=$1
    # Whitespace is legal inside cubic-bezier(); strip it so `cubic-bezier(0.34, 1.56, …)`
    # and the compact form are one value. (No fork: ${s// /} is a builtin expansion.)
    s=${s// /}; s=${s//$'\t'/}
    if [[ -n "${_FT_EASE_NAMED[$s]:-}" ]]; then FT_RET=${_FT_EASE_NAMED[$s]}; return 0; fi
    if [[ "$s" == cubic-bezier\(*\) ]]; then
        local body=${s#cubic-bezier(}; body=${body%)}
        local -a p=(); local f
        local IFS=,
        for f in $body; do _ft_ease_milli "$f"; p+=("$FT_RET"); done
        if (( ${#p[@]} == 4 )); then FT_RET="${p[0]} ${p[1]} ${p[2]} ${p[3]}"; return 0; fi
    fi
    FT_RET=${_FT_EASE_NAMED[linear]}; return 1
}
# A decimal like -0.28 / 1.56 / 1 → thousandths, without a fork and without bc. Bash has no
# floats, so the fraction is read as TEXT and padded to three digits — which is also why a
# fourth decimal place is silently dropped rather than rounded (nobody writes one).
_ft_ease_milli() {              # decimal → FT_RET (integer thousandths)
    local v=$1 sign=1
    [[ "$v" == -* ]] && { sign=-1; v=${v#-}; }
    [[ "$v" == +* ]] && v=${v#+}
    local whole=${v%%.*} frac=""
    [[ "$v" == *.* ]] && frac=${v#*.}
    (( ${#whole} == 0 )) && whole=0
    frac="${frac}000"; frac=${frac:0:3}
    # 10#: a fraction like 008 is NOT octal, and `08` in (( )) is a hard error that would
    # print onto the alt screen (the stderr-is-the-alt-screen rule in tests/run-all.bash).
    FT_RET=$(( sign * (10#$whole * 1000 + 10#$frac) ))
}
# ft_ease SPEC PROGRESS → FT_RET = the eased value, both in thousandths.
# PROGRESS is clamped to 0..1000; the RESULT is not clamped — an overshoot curve returns
# more than 1000 on purpose.
ft_ease() {                     # spec progress(0..1000) → FT_RET
    local p=$2
    (( p < 0 )) && p=0; (( p > 1000 )) && p=1000
    local x1 y1 x2 y2
    ft_ease_points "$1"; read -r x1 y1 x2 y2 <<< "$FT_RET"
    # linear needs no solve, and it is the common case for everything that is not a bounce
    if (( x1 == 0 && y1 == 0 && x2 == 1000 && y2 == 1000 )); then FT_RET=$p; return 0; fi
    # Bisect for the t whose x(t) is p. x is monotone for any x1,x2 in 0..1000, which every
    # CSS-legal curve is (CSS constrains the X control points and not the Y ones — that
    # asymmetry is exactly what makes overshoot expressible and keeps it solvable).
    local lo=0 hi=1000 t u x i
    for (( i=0; i<12; i++ )); do
        t=$(( (lo + hi) / 2 )); u=$(( 1000 - t ))
        x=$(( (3*u*u*t*x1 + 3*u*t*t*x2 + t*t*t*1000) / 1000000000 ))
        if (( x < p )); then lo=$t; else hi=$t; fi
    done
    t=$(( (lo + hi) / 2 )); u=$(( 1000 - t ))
    FT_RET=$(( (3*u*u*t*y1 + 3*u*t*t*y2 + t*t*t*1000) / 1000000000 ))
}
# ── Comma-separated animation lists, verbatim from CSS ───────────────────────
# CSS puts SEVERAL animations on one element by making every animation longhand a LIST:
#
#     animation-duration:        560ms, 420ms;
#     animation-timing-function: ease-out-back, ease-in-back;
#     animation-delay:           0ms, 2400ms;
#
# — item 1 describes the first animation, item 2 the second. A control with two phases (the
# bigarrow flies, then leaves) therefore needs no invented property names at all: it reads
# item 2 of the properties it already reads item 1 of. `holdDuration`, `exitDuration` and
# `exitTimingFunction` were three names for things CSS had already named, and this is what
# replaced them.
#
# A short list REPEATS, which is CSS's own rule (§ css-animations-1: "If the lists are of
# different lengths … the shorter lists are repeated"), so one value still means "both".
# cubic-bezier() contains commas of its own, so splitting tracks parenthesis depth — a naive
# split turned `ease, cubic-bezier(0.34, 1.56, 0.64, 1)` into five items and handed
# `cubic-bezier(0.34` to the solver, which silently fell back to linear.
ft_css_list_nth() {             # value index(1-based) → FT_RET (empty value → empty)
    local value=$1 want=$2
    if [[ "$value" != *,* ]]; then FT_RET=$value; return 0; fi
    local -a items=(); local depth=0 current="" i character
    for (( i=0; i<${#value}; i++ )); do
        character=${value:i:1}
        case "$character" in
            '(') (( depth++ )); current+=$character ;;
            ')') (( depth > 0 )) && (( depth-- )); current+=$character ;;
            ',') if (( depth == 0 )); then items+=("$current"); current=""
                 else current+=$character; fi ;;
            *)   current+=$character ;;
        esac
    done
    items+=("$current")
    local count=${#items[@]}
    (( count == 0 )) && { FT_RET=""; return 0; }
    local pick=${items[ (want - 1) % count ]}
    # trim the spaces CSS allows around a list separator
    while [[ "$pick" == " "* ]]; do pick=${pick# }; done
    while [[ "$pick" == *" " ]]; do pick=${pick% }; done
    FT_RET=$pick
}

# ── Naming the frame ─────────────────────────────────────────────────────────
# THE ENGINE MUST NOT COMPUTE A FRAME THAT IS ALREADY ON THE SCREEN. A phase counter says
# time has passed; it does not say the picture changed, and for a colour ramp on a 256-colour
# terminal those are very different claims: `glow`'s 25 samples compose 24 distinct SGRs in
# truecolour and only 7 at 256, so most phase advances repaint what is already there.
#
# So an effect may NAME the frame it is on. Same name as last time ⇒ the frame is skipped
# entirely — not painted, not composed, not flushed. An effect that names nothing behaves
# exactly as it always has, which is what lets effects opt in one at a time.
#
# A NAME MUST DESCRIBE EVERY OBSERVABLE EFFECT OF THE FRAME, not just its ink. A bound routine
# whose last frame destroys the control, or disarms itself, or moves something, has effects a
# colour cannot express — skip such a frame and the control never dies. That is why bound
# routines name nothing unless ft_anim_bind_signature says otherwise, and why the one built-in
# namer is the CSS @keyframes player, whose entire frame IS the SGR it composes.
declare -A FT_ANIM_SIGNATURE=() FT_ANIM_SIGNATURE_ON_SCREEN=()
# ft_anim_bind_signature NAME FN — FN NAME must set FT_RET to a string that changes exactly
# when this effect's frame would look or behave differently. The sibling of ft_anim_bind.
ft_anim_bind_signature() {      # name fn
    FT_ANIM_SIGNATURE[$1]=$2
    unset "FT_ANIM_SIGNATURE_ON_SCREEN[$1]"     # a new namer knows nothing about the screen
    return 0
}
# → FT_RET = this frame's name, or "" when the effect does not name its frames.
_ft_anim_signature() {          # name
    local namer=${FT_ANIM_SIGNATURE[$1]:-}
    if [[ -n "$namer" ]]; then "$namer" "$1"; return 0; fi
    # The CSS @keyframes player binds no routine — the engine repaints the whole control for
    # it — and its frame is exactly the SGR _ft_css_anim_fg composes. Ask through the same
    # function the paint will ask, so the name cannot describe a different frame than the one
    # drawn; its ramps are memoised, so asking twice is cheap.
    if [[ -n "${FT_CSS_ANIMATION_ON[$1]:-}" ]] && declare -F _ft_css_anim_fg >/dev/null 2>&1; then
        _ft_css_anim_fg "$1" || FT_RET=""
        return 0
    fi
    FT_RET=""
}

# ft_ease_table SPEC FRAMES → FT_RET = FRAMES eased values (thousandths), space separated.
# THE WHOLE CURVE, PRECOMPUTED AT ARM TIME. A frame must never solve a bezier: the budget
# for a frame is what is left after the terminal has been written to, and 12 bisection
# rounds per frame would buy nothing a table cannot give for free. Frame 0 is 0 and the
# last frame is exactly 1000, so an animation always starts and lands on its endpoints
# whatever the curve did in between.
ft_ease_table() {               # spec frames → FT_RET
    local spec=$1 n=$2 i out="" v
    (( n < 2 )) && { FT_RET="1000"; return 0; }
    for (( i=0; i<n; i++ )); do
        if   (( i == 0 ));     then v=0
        elif (( i == n - 1 )); then v=1000
        else ft_ease "$spec" $(( i * 1000 / (n - 1) )); v=$FT_RET; fi
        out+="$v "
    done
    FT_RET=${out% }
}

ft_anim_step() {                # advance every animation that is DUE, then repaint once
    (( FT_ANIM_ACTIVE )) || return 0
    local n due=0 painted=0 frame db
    for n in "${!FT_ANIM_PHASE[@]}"; do
        [[ -z "${FT_TYPE[$n]:-}" ]] && { ft_anim_stop "$n"; continue; }   # destroyed mid-flight
        # RESTING BETWEEN LAPS. Nothing is painted and the phase does not move until the rest
        # elapses — the whole point is that a pause costs nothing, where padding the length
        # with undrawn cells cost a wake and a full repaint per padded cell.
        if [[ -n "${FT_ANIM_REST_UNTIL_MS[$n]:-}" ]]; then
            ft_now_ms
            (( FT_RET < FT_ANIM_REST_UNTIL_MS[$n] )) && continue
            unset "FT_ANIM_REST_UNTIL_MS[$n]"
            FT_ANIM_ACCUMULATED_MS[$n]=0
        fi
        (( FT_ANIM_ACCUMULATED_MS[$n] += FT_ANIM_POLL_MS ))
        (( FT_ANIM_ACCUMULATED_MS[$n] < FT_ANIM_FRAME_MS[$n] )) && continue    # not this one's frame yet
        FT_ANIM_ACCUMULATED_MS[$n]=0
        frame=${FT_ANIM_FRAME[$n]:-}
        # DEBOUNCE: the MAIN phase is held until the user has been quiet for its typing-
        # delay — the phase does not advance, so it resumes exactly where it left off,
        # and every keystroke restamps FT_LAST_INPUT_MS, resetting the wait. This is what
        # stops the per-keystroke flicker. During the hold, if a HOLD structure is bound,
        # paint THAT at the frozen phase (e.g. the glow that shows the instant you
        # activate, in phase with the main); otherwise stay frozen.
        db=${FT_ANIM_DEBOUNCE[$n]:-0}
        if (( db > 0 )); then ft_now_ms
            if (( FT_RET - FT_LAST_INPUT_MS < db )); then
                if [[ -n "${FT_ANIM_HOLD[$n]:-}" && -n "$frame" ]]; then
                    "$frame" "$n" "${FT_ANIM_HOLD[$n]}"; painted=1
                fi
                continue
            fi
        fi
        (( FT_ANIM_PHASE[$n] += FT_ANIM_STEP[$n] ))
        if (( FT_ANIM_PHASE[$n] >= FT_ANIM_LENGTH[$n] )); then
            if (( FT_ANIM_LOOP[$n] )); then
                (( FT_ANIM_PHASE[$n] %= FT_ANIM_LENGTH[$n] ))
                # A lap has finished. If this effect rests between laps, start resting now
                # rather than painting the opening frame of the next one.
                if (( ${FT_ANIM_REST_MS[$n]:-0} > 0 )); then
                    ft_now_ms
                    FT_ANIM_REST_UNTIL_MS[$n]=$(( FT_RET + FT_ANIM_REST_MS[$n] ))
                    continue
                fi
            else ft_anim_stop "$n"; ft_dirty "$n"; due=1; continue; fi   # clean final frame
        fi
        # IS THIS FRAME ALREADY ON THE SCREEN? Asked AFTER the phase advance, so the name
        # describes the frame about to be drawn and not the one before it. (Asking before the
        # advance shifts the name one frame against the picture, which looks exactly like a
        # broken guard and is how a correct one nearly got refuted.) An effect that names
        # nothing falls straight through and behaves as it always has.
        _ft_anim_signature "$n"
        if [[ -n "$FT_RET" ]]; then
            if [[ "$FT_RET" == "${FT_ANIM_SIGNATURE_ON_SCREEN[$n]-$'\x01'}" ]]; then continue; fi
            FT_ANIM_SIGNATURE_ON_SCREEN[$n]=$FT_RET
        fi
        # The bound routine repaints only what moved — this is what makes a permanent
        # animation affordable (a 20-row field is ~38ms to redraw whole). Called INSTANCE
        # STRUCTURE so it can branch on the structure. No routine → mark dirty for a full
        # redraw (how the status-bar sweep repaints).
        if [[ -n "$frame" ]]; then "$frame" "$n" "${FT_ANIM_STRUCT[$n]:-}"; painted=1
        else ft_dirty "$n"; due=1; fi
    done
    (( due )) && ft_redraw_dirty           # composites overlays itself
    # A bound frame routine painted a control DIRECTLY (e.g. a border-sheen frame). Only
    # re-composite overlays that control actually touches — an idle animation far from any
    # callout then costs nothing per frame (this was the perf killer: full re-placement of
    # the callout on every sheen tick).
    (( painted )) && { _ft_composite_overlays_animating; ft_flush; }
    # Recount AFTER the repaint, never before: a draw is allowed to START an
    # animation (the status bar sweeps itself whenever its synopsis changes), and
    # a count taken earlier would miss it — the loop would fall back to the lazy
    # poll and the new animation would crawl until the next keystroke.
    _ft_anim_repoll
}
_ft_redraw_walk() {
    local name=$1 kid
    _ft_disp "$name"; [[ "$FT_RET" == none ]] && return
    ft_draw_one "$name"
    ft_clean "$name"
    for kid in ${FT_KIDS[$name]}; do _ft_redraw_walk "$kid"; done
}

# _ft_paint_order NAME… → FT_PAINT_ORDER: the controls a partial redraw paints, in the order the
# FULL walk would paint them, and without the ones the full walk would never reach.
#
# THE ORDER IS THE WALK'S, NOT MERELY "ANCESTORS FIRST". This used to sort by depth, and within
# one depth the order was whatever the associative array's hash gave back. Nothing notices while
# siblings keep to their own cells, and everything does once two overlap — a control that has
# just become position:absolute sits on the sibling that slid into its place, and _ft_redraw_walk
# paints the later sibling on top while the partial redraw painted whichever hashed last.
#
# AND IT STOPS WHERE THE WALK STOPS. _ft_redraw_walk never descends into a display:none subtree,
# but a partial redraw paints controls one at a time, and ft_draw_one can only answer for the
# control itself: a label inside a hidden tab body has a `display` of its own that is not none.
# Switching tabs dirtied both bodies, and the hidden one painted over the one just shown.
# (visibility:hidden is not this: it paints a blank, and ft_draw_one handles it.)
#
# So it IS the walk, pruned: mark the path from each name to its root, then walk only the marked
# branches in FT_KIDS order. One function, two callers — the redraw and the transition's ground
# capture used to carry an insertion sort each (tests/test-incremental.bash found both defects).
_ft_paint_order() {             # name… → FT_PAINT_ORDER
    local -A _ft_order_wanted=() _ft_order_marked=()
    local -a roots=()
    local name n
    for name in "$@"; do
        _ft_order_wanted[$name]=1
        n=$name
        while [[ -z "${_ft_order_marked[$n]:-}" ]]; do     # stop at a path already marked
            _ft_order_marked[$n]=1
            [[ -n "${FT_PARENT[$n]:-}" ]] || { roots+=("$n"); break; }
            n=${FT_PARENT[$n]}
        done
    done
    FT_PAINT_ORDER=()
    for n in "${roots[@]}"; do _ft_paint_order_walk "$n"; done
}
_ft_paint_order_walk() {        # node — reads the caller's _ft_order_wanted / _ft_order_marked
    local node=$1 kid
    _ft_disp "$node"; [[ "$FT_RET" == none ]] && return 0       # exactly where the walk stops
    [[ -n "${_ft_order_wanted[$node]:-}" ]] && FT_PAINT_ORDER+=("$node")
    for kid in ${FT_KIDS[$node]:-}; do
        [[ -n "${_ft_order_marked[$kid]:-}" ]] && _ft_paint_order_walk "$kid"
    done
    return 0
}
FT_PAINT_ORDER=()
# ── Overlay compositing ──────────────────────────────────────────────────────
# position:absolute OVERLAYS (beacons/callouts) paint OUTSIDE their own layout box
# and must stay ON TOP of every other control. But they are ordinary tree children,
# so z-order only holds in a full root walk — and even THEN a later sibling (e.g. the
# button row after the stage) paints over the part of an overlay that reaches into it.
# Worse, any PARTIAL repaint beneath one — a control's own redraw, a border-animation
# frame — tramples it. So EVERY repaint path re-composites the live overlays last.
# A control registers itself here (see ft-beacon); the engine stays layer-agnostic.
# FT_OVERLAY[name] holds the overlay's last painted bounding rect ("top left bottom right"),
# or "1" before its first paint. The rect lets the ANIMATION path skip overlays no animating
# control touches — so an idle focused-control sheen nowhere near a callout costs nothing.
# The `=()` is NOT decoration: `declare -A X` alone leaves X UNSET as far as bash is concerned,
# so `${#X[@]}` on it is an unbound-variable error under `set -u` — and an app with no overlays
# at all died on the very first composite. demo/textfield-demo.bash did exactly that.
declare -A FT_OVERLAY=() FT_OVERLAY_Z_ORDER=()
# Z-ORDER: overlays with a LOWER FT_OVERLAY_Z_ORDER paint first, higher last (on top). Callouts are
# z=10 so they land above every other beacon — a callout must never be painted over. Two passes
# (low then high) keeps it fork-free; with only two tiers in play that is all it takes.
_ft_composite_overlays() {      # repaint ALL live overlays (used after a real change)
    (( ${#FT_OVERLAY[@]} == 0 )) && return
    local n pass
    for pass in 0 1; do
        for n in "${!FT_OVERLAY[@]}"; do
            [[ -n "${FT_TYPE[$n]:-}" ]] || { unset "FT_OVERLAY[$n]"; continue; }   # gone → forget it
            (( pass == 0 )) && (( ${FT_OVERLAY_Z_ORDER[$n]:-0} > 0 )) && continue         # tier 1 later
            (( pass == 1 )) && (( ${FT_OVERLAY_Z_ORDER[$n]:-0} == 0 )) && continue        # tier 0 done
            _ft_disp "$n"; [[ "$FT_RET" == none ]] && continue
            ft_draw_one "$n"
        done
    done
}
_ft_composite_overlays_animating() {   # recomposite only overlays the animated SUBSTRUCTURE touches
    (( ${#FT_OVERLAY[@]} == 0 )) && return
    local n rect ot ol ob orr a ax ay aw ah s pass
    for pass in 0 1; do                       # low-z overlays first, callouts (z>0) last → on top
        for n in "${!FT_OVERLAY[@]}"; do
            [[ -n "${FT_TYPE[$n]:-}" ]] || { unset "FT_OVERLAY[$n]"; continue; }
            (( pass == 0 )) && (( ${FT_OVERLAY_Z_ORDER[$n]:-0} > 0 )) && continue
            (( pass == 1 )) && (( ${FT_OVERLAY_Z_ORDER[$n]:-0} == 0 )) && continue
            _ft_disp "$n"; [[ "$FT_RET" == none ]] && continue
            rect=${FT_OVERLAY[$n]}
            if [[ "$rect" == 1 || -z "$rect" ]]; then ft_draw_one "$n"; continue; fi   # not yet placed → paint
            set -- $rect; ot=$1 ol=$2 ob=$3 orr=$4
            for a in "${!FT_ANIM_PHASE[@]}"; do
                ax=${FT_ABSOLUTE_X[$a]:-}; [[ -z "$ax" ]] && continue
                ay=${FT_ABSOLUTE_Y[$a]:-0}; aw=${FT_MEASURED_WIDTH[$a]:-0}; ah=${FT_MEASURED_HEIGHT[$a]:-0}
                (( aw<1 || ah<1 )) && continue
                s=${FT_ANIM_STRUCT[$a]:-}
                if (( ax<=orr && ax+aw-1>=ol && ay<=ob && ay+ah-1>=ot )); then
                    # A ::border animation only touches the PERIMETER — an overlay resting
                    # entirely in the control's interior is never painted over.
                    if [[ "$s" == border || "$s" == borderGlow ]] \
                       && (( ot > ay && ob < ay+ah-1 && ol > ax && orr < ax+aw-1 )); then :
                    else ft_draw_one "$n"; break; fi
                fi
                # The BOX rect missing the animation is not the end of it: the LEADER is the
                # overlay's pixels too, and it routinely runs right alongside a pane — i.e. down
                # the very border column a focused pane's sheen repaints every tick. That wiped
                # the line for as long as the pane stayed focused (the reported "broken line";
                # a callout box parked elsewhere never recomposited). Same segment rects the
                # dirty path tests, same interior exemption per segment.
                if [[ -n "${FT_OVERLAY_EXTRA[$n]:-}" ]]; then
                    local _seg _st _sl _sb _sr
                    while IFS= read -r -d ';' _seg; do
                        [[ -z "$_seg" ]] && continue
                        IFS=' ' read -r _st _sl _sb _sr <<< "$_seg"
                        (( ax<=_sr && ax+aw-1>=_sl && ay<=_sb && ay+ah-1>=_st )) || continue
                        if [[ "$s" == border || "$s" == borderGlow ]] \
                           && (( _st > ay && _sb < ay+ah-1 && _sl > ax && _sr < ax+aw-1 )); then continue; fi
                        ft_draw_one "$n"; break 2
                    done <<< "${FT_OVERLAY_EXTRA[$n]};"
                fi
            done
        done
    done
}
# ── Toast: the last-resort confirmation line ─────────────────────────────────
# AN ACTION THAT SUCCEEDS WITH NO VISIBLE RESULT IS INDISTINGUISHABLE FROM ONE THAT
# FAILED. That is not a cosmetic point: Ctrl+S wrote a perfectly good state file and the
# only honest description of the feature was still "nothing seemed to happen".
#
# A status bar is the RIGHT place to say "Saved" — it is themed, queued, and already
# reserves a row for exactly this. But an app need not have one, and "the confirmation
# only appears if you happened to add a status bar" is the same bug wearing a hat. So the
# engine keeps one line of its own as the floor: painted over the bottom screen row as
# the very last thing in a frame (after overlays — it must not be paintable-over), and
# dismissed by the next keypress, which is also the next thing that repaints anyway.
#
# It is deliberately the FALLBACK, not the mechanism: ft_emit_status still prefers a real
# status bar and only lands here when no bar showed the message.
_FT_TOAST_MSG=""
_FT_TOAST_RECT=""
ft_toast() {                    # message — show it until the next keypress ("" clears)
    if [[ -z "$1" ]]; then ft_toast_clear; return 0; fi
    _FT_TOAST_MSG=$1
    FT_TOAST_FN=_ft_toast_paint
    return 0
}
# ft_toast_clear → 0 if a toast was up (and its cells were damaged for repair), 1 if none.
ft_toast_clear() {
    [[ -n "$_FT_TOAST_MSG" ]] || return 1
    _FT_TOAST_MSG=""; FT_TOAST_FN=""
    [[ -n "$_FT_TOAST_RECT" ]] && ft_damage $_FT_TOAST_RECT
    _FT_TOAST_RECT=""
    return 0
}
_ft_toast_paint() {             # called from ft_flush, appends straight to FT_OUT
    local msg=" $_FT_TOAST_MSG "
    # The clip is whatever the last draw left behind; a frame is over by now, so a full
    # reset is safe — and required, or a toast can be clipped away by an unrelated box.
    local r0=$FT_CLIP_R0 r1=$FT_CLIP_R1 c0=$FT_CLIP_C0 c1=$FT_CLIP_C1
    ft_clip_reset
    # NO SCREEN, NO TOAST. A pty is 0x0 until someone sets its size, and a width of 0 turned
    # "clamp the message to the screen" into "truncate it to nothing" — the confirmation was
    # painted, empty, and looked exactly like the silent save it exists to fix.
    (( FT_COLS < 4 || FT_ROWS < 1 )) && return 0
    local max=$(( FT_COLS - 2 ))
    ft_display_width "$msg"
    if (( FT_DISPLAY_WIDTH > max )); then ft_display_truncate "$msg" "$max"; msg=$FT_DISPLAY_TRUNCATED; FT_DISPLAY_WIDTH=$max; fi
    local row=$(( FT_ROWS - 1 )) col=$(( FT_COLS - FT_DISPLAY_WIDTH - 1 ))
    (( col < 0 )) && col=0
    ft_print_at_width "$row" "$col" "${FT_COLOR_STATUS:-}$msg$FT_COLOR_RESET" "$FT_DISPLAY_WIDTH"
    _FT_TOAST_RECT="$row $col $row $(( col + FT_DISPLAY_WIDTH - 1 ))"
    FT_CLIP_R0=$r0; FT_CLIP_R1=$r1; FT_CLIP_C0=$c0; FT_CLIP_C1=$c1
}

# ── Damage regions (the compositor) ──────────────────────────────────────────
# FT_DIRTY says "this CONTROL must repaint". DAMAGE says "these CELLS are now wrong" — because
# something LEFT them: an overlay moved, a control was removed or hidden, a subtree shrank, a
# scroll shifted content. Without it, callers hand-roll erase+re-dirty (app-level rendering
# logic), and they get it wrong: erasing a span and repainting the CONTROLS in it leaves the
# cells BETWEEN them blank, because the span crosses TRANSPARENT containers (div/panel paint no
# background — only leaves paint). So repair must first refill the region from the nearest
# OPAQUE ancestor, then repaint the controls over it. See docs/rendering-damage.md.
declare -a FT_DAMAGE=()
declare -A FT_PAINT_RECT=()     # name → "T L B R" ACTUALLY painted last frame (may exceed its box)
# Repair only what the damage rect actually touches, instead of enlisting a whole no-ink container
# and its subtree. See _ft_damage_enlist — opt-in, held on for the length of one operation (a
# beacon drag) rather than set globally, because it stops covering for under-declared footprints.
declare -i FT_DAMAGE_NARROW=${FT_DAMAGE_NARROW:-0}
declare -i FT_BEACON_NARROW_OFF_AFTER=0   # a release mid-burst: settle paints narrow, then widen
ft_damage() {                   # T L B R — these cells need repair
    local t=$1 l=$2 b=$3 r=$4
    (( t < 0 )) && t=0; (( l < 0 )) && l=0
    (( b >= FT_ROWS )) && b=$(( FT_ROWS - 1 )); (( r >= FT_COLS )) && r=$(( FT_COLS - 1 ))
    (( b < t || r < l )) && return 0
    FT_DAMAGE+=("$t $l $b $r")
}
# NOT a painter — it records where a draw has ALREADY put ink, so the compositor can give those
# cells back when the control moves or goes away. It was `ft_paint_rect`, sitting between
# `ft_damage` and `ft_damage_subtree`, which both really do act: in that company the name read as
# an imperative and said the opposite of what the body does. `publish` is the verb this codebase
# already uses for it, at all four call sites and in docs/rendering-damage.md.
ft_publish_paint_rect() { FT_PAINT_RECT[$1]="$2 $3 $4 $5"; }   # a draw that paints OUTSIDE its box says so
# Damage whatever NAME last painted (its own rect and every descendant's) — used when a control
# is removed or hidden, where there is nothing left to repaint itself.
# GIVE BACK EVERY CELL THIS SUBTREE PUT INK ON. The general rule, used by ft_remove and by
# `display: none`, so no application ever has to know what a control covered.
#
# The default answer is the control's own published paint rect — `ft_draw_one` records one for
# everything it draws, and anything that paints OUTSIDE its layout box (a callout and its
# leader, an arrow) publishes its real footprint with `ft_publish_paint_rect`. That covers every
# control in the toolkit but one, and the exception is instructive: a bigarrow publishes its
# LANDED rect, because other placements need to avoid where it will end up — and mid-flight
# that is not where its ink is. So a prototype whose ink is not its paint rect says so, by
# defining `_ft_ink_<type> NAME`; nothing here knows what a beacon is.
#
# (This used to be gated behind FT_DAMAGE_AUTO, off by default, because the repair pass could
# not yet refill a region spanning transparent containers. `_ft_damage_fill` resolves ground
# per RUN now, and test-residue.bash replays real byte streams to prove it, so the gate is
# gone and removal repairs itself like everything else.)
ft_damage_subtree() {           # name
    local n=$1 kid                          # SEPARATE LINES: `local n=$1 ink=${A[$n]}` reads
    local ink="_ft_ink_${FT_TYPE[$n]:-}"    # the OLD n, which under set -u is a fatal unbound
    if declare -F "$ink" >/dev/null 2>&1; then "$ink" "$n"
    elif [[ -n "${FT_PAINT_RECT[$n]:-}" ]]; then ft_damage ${FT_PAINT_RECT[$n]}
    fi
    for kid in ${FT_KIDS[$n]:-}; do ft_damage_subtree "$kid"; done
}
# Refill one damaged rect with the ground each cell actually stands on.
#
# ONE hit-test at the rect's centre chose ONE background for the whole rect — and a callout's
# extent routinely STRADDLES the frame border, half over the frame's body, half out in the
# screen margin. Whichever side the centre landed on, the other side was refilled with the
# wrong colour: a body-grey band stamped across the black margin (the page-8 residue), or —
# headless, where FT_ROOT is unset — a silent no-op that left the old glyphs standing.
#
# So the ground is resolved PER RUN, with the machinery that already knows the answer:
# _ft_hit_test finds the deepest node covering a cell, and _ft_effective_bg resolves what that
# node's ground is (a frame → body, the root form → the cleared screen). A run extends to the
# covering node's right edge, so this costs a handful of hit-tests per row, and only on the
# damage path — a step or page change, never the per-frame composite. A cell no node covers
# (the screen margin, or anywhere when there is no root) is the cleared screen, by definition.
# The column-cut list is a property of the TREE, not of any one damage rect — so a frame that
# repairs several rects (a drag repairs four to six a settle) was rebuilding the identical list
# per call, and the rebuild walks every control with an insertion sort. Built once per
# ft_redraw_dirty damage pass; outside a pass the flag stays 0 and every call rebuilds, which is
# exactly the old behaviour for direct callers.
declare -a _FT_DFILL_CUTS=()
declare -i _FT_DFILL_BUILT=0 _FT_DFILL_N=0
# Per-pass memo of the fill's two expensive questions. The hit test walks the tree and the
# ground resolution walks ancestors — and a drag's settle asks them ~100 times for CELLS THE
# PREVIOUS RECT ALREADY ANSWERED, because the ring pieces of successive ghost positions overlap
# heavily and a one-cell-wide strip makes every row its own run. Within one damage pass the
# answer for (row, cut-interval) cannot change — the cuts themselves are the proof, they are
# built from the same geometry — so it is asked once. Measured on the drag settle: fill 180ms →
# the whole pass ~60ms. Lifecycle is _FT_DFILL_BUILT's: cleared when the cuts are.
declare -A _FT_DFILL_HIT=()     # "row:cutIndex" → covering node ("" = none; "-" = cached none)
declare -A _FT_DFILL_BG=()      # node → resolved ground SGR
declare -A _FT_DFILL_PAD=()     # width → that many spaces (session-long; widths are few)
declare -i _FT_DFILL_RUNS=0     # profiling counter (FT_BURST_LOG); MUST be declared — an app
                                # may run under set -u, and `(( x++ ))` on an unset name printed
                                # a bash error straight onto the alt screen (caught by a golden)
# The hit test itself, flattened. _ft_hit_walk recurses — ~30 function calls at ~25µs of bash
# call overhead each — and a drag settle asks it ~100 times: the walk's CALLS, not its
# arithmetic, were 100ms of every settle. The recursion's answer is exactly "the LAST node in
# DFS preorder that covers the cell" (descendants follow parents, later siblings follow
# earlier), so one flat array in DFS order, built beside the cuts, gives the identical answer
# with zero calls: scan, keep the last cover. NOHIT types are left out at build time.
declare -a _FT_DHIT_NODE=() _FT_DHIT_X=() _FT_DHIT_Y=() _FT_DHIT_R=() _FT_DHIT_B=()
declare -i _FT_DHIT_N=0
_ft_dfill_hit_build() {         # node — DFS push of every hittable control
    local n=$1 k
    [[ -z "$n" ]] && return
    # A CONTROL IN TRANSITION IS NOT PART OF THE GROUND. It is the thing being blended IN, so
    # the ground under it is whatever it will cover — not itself. Without this the fill asked
    # the incoming control for the background of its own cells and the transition started from
    # its destination: it "morphed" from purple to purple. Its subtree goes with it.
    [[ -n "${_FT_TRANSITION_LOADED:-}" && -n "${_FT_TRANSITION_ACTIVE[$n]:-}" ]] && return
    local ax=${FT_ABSOLUTE_X[$n]:-} w=${FT_MEASURED_WIDTH[$n]:-0} h=${FT_MEASURED_HEIGHT[$n]:-0}
    if [[ -n "$ax" ]] && (( w > 0 && h > 0 )); then
        if (( ${FT_PROTO_NOHIT[${FT_TYPE[$n]:-}]:-0} != 1 )); then
            _FT_DHIT_NODE+=("$n"); _FT_DHIT_X+=("$ax"); _FT_DHIT_Y+=("${FT_ABSOLUTE_Y[$n]:-0}")
            _FT_DHIT_R+=($(( ax + w - 1 ))); _FT_DHIT_B+=($(( ${FT_ABSOLUTE_Y[$n]:-0} + h - 1 )))
            (( _FT_DHIT_N++ ))
        fi
        # the recursion only descends into covering nodes, but kids can OVERHANG a parent's box
        # in this layout model exactly as overlays do — descend regardless, order is what matters
    fi
    for k in ${FT_KIDS[$n]:-}; do _ft_dfill_hit_build "$k"; done
}
_ft_damage_fill() {             # T L B R
    local t=$1 l=$2 b=$3 r=$4 row c run n sgr w i j v
    ft_clip_reset
    # WHERE A RUN CAN END IS KNOWN IN ADVANCE. The deepest covering node changes only where some
    # node's span starts or ends, so the column cuts are a property of the tree, not something to
    # discover by probing. Probing every cell — a hit test per column, each walking the tree —
    # made a repair of a 48×4 extent ~200 tree walks and showed up as step-change latency. One
    # pass over the nodes collects the cuts; then it is one hit test per RUN. The FULL cut list
    # is collected (no l/r filter) so it can be cached across the frame's rects: the row walk
    # below skips out-of-range cuts by itself.
    if (( ! _FT_DFILL_BUILT )); then
        local _tb=""
        [[ -n "${FT_BURST_LOG:-}" ]] && { ft_now_ms; _tb=$FT_RET; }
        _FT_DFILL_CUTS=(); _FT_DFILL_N=0
        _FT_DFILL_HIT=(); _FT_DFILL_BG=()   # the memo lives exactly as long as the cuts do
        _FT_DHIT_NODE=(); _FT_DHIT_X=(); _FT_DHIT_Y=(); _FT_DHIT_R=(); _FT_DHIT_B=()
        _FT_DHIT_N=0
        [[ -n "${FT_ROOT:-}" ]] && _ft_dfill_hit_build "$FT_ROOT"
        [[ -n "$_tb" ]] && { ft_now_ms; printf 'STG fillbuild-dhit %s\n' $(( FT_RET - _tb )) >> "$FT_BURST_LOG"; _tb=$FT_RET; }
        for n in "${!FT_TYPE[@]}"; do
            [[ -n "${FT_TYPE[$n]:-}" && -n "${FT_ABSOLUTE_X[$n]:-}" ]] || continue
            (( ${FT_MEASURED_WIDTH[$n]:-0} > 0 && ${FT_MEASURED_HEIGHT[$n]:-0} > 0 )) || continue
            for v in "${FT_ABSOLUTE_X[$n]}" $(( FT_ABSOLUTE_X[$n] + FT_MEASURED_WIDTH[$n] )); do
                for (( i=0; i<_FT_DFILL_N; i++ )); do (( _FT_DFILL_CUTS[i] == v )) && break; done
                (( i < _FT_DFILL_N )) && continue
                i=$_FT_DFILL_N
                while (( i > 0 )) && (( _FT_DFILL_CUTS[i-1] > v )); do
                    _FT_DFILL_CUTS[i]=${_FT_DFILL_CUTS[i-1]}; (( i-- ))
                done
                _FT_DFILL_CUTS[i]=$v; (( _FT_DFILL_N++ ))
            done
        done
        [[ -n "${_tb:-}" ]] && { ft_now_ms; printf 'STG fillbuild-cuts %s\n' $(( FT_RET - _tb )) >> "$FT_BURST_LOG"; }
    fi
    local nn=$_FT_DFILL_N _hk _pad _cur
    for (( row=t; row<=b; row++ )); do
        c=$l; j=0
        while (( c <= r )); do
            while (( j < nn )) && (( _FT_DFILL_CUTS[j] <= c )); do (( j++ )); done
            run=$r; (( j < nn )) && (( _FT_DFILL_CUTS[j] - 1 < run )) && run=$(( _FT_DFILL_CUTS[j] - 1 ))
            # one answer per (row, interval) per pass — see the memo's note above
            _hk="$row:$j"
            n=${_FT_DFILL_HIT[$_hk]:-}
            if [[ -z "$n" ]]; then
                # the flat DFS scan: last cover wins, exactly the recursion's answer, no calls
                n=""
                local _dh
                for (( _dh=0; _dh<_FT_DHIT_N; _dh++ )); do
                    (( c >= _FT_DHIT_X[_dh] && c <= _FT_DHIT_R[_dh] \
                       && row >= _FT_DHIT_Y[_dh] && row <= _FT_DHIT_B[_dh] )) && n=${_FT_DHIT_NODE[_dh]}
                done
                _FT_DFILL_HIT[$_hk]=${n:--}
            elif [[ "$n" == - ]]; then
                n=""
            fi
            if [[ -n "$n" ]]; then
                sgr=${_FT_DFILL_BG[$n]:-}
                if [[ -z "$sgr" ]]; then _ft_effective_bg "$n"; sgr=$FT_RET; _FT_DFILL_BG[$n]=$sgr; fi
            else sgr=$FT_COLOR_SCREEN; fi
            w=$(( run - c + 1 ))
            # inlined ft_fit+ft_print_at_width for the blank-run case: a drag settle paints ~130 runs and
            # the three calls were ~250µs of each run's ~370µs — the pad is a cache lookup, the
            # clip test is unnecessary (ft_clip_reset ran above and ft_damage clamps), and the
            # cursor+append are two builtins
            _pad=${_FT_DFILL_PAD[$w]:-}
            if [[ -z "$_pad" ]]; then printf -v _pad '%*s' "$w" ''; _FT_DFILL_PAD[$w]=$_pad; fi
            printf -v _cur '\e[%d;%dH' $(( row + 1 )) $(( c + 1 ))
            FT_OUT+="$_cur$sgr$_pad$FT_COLOR_RESET"
            (( _FT_DFILL_RUNS++ ))
            c=$(( run + 1 ))
        done
    done
}
# Mark every control whose painted box intersects ANY of this pass's damage rects, so it repaints
# over the refill — ALL of them in ONE tree walk. (A per-rect walk costs a full recursion over
# every node per rect, and a drag's settle repairs four to six: measured at 128 recursive calls
# and ~86ms per settle, the whole remaining drag cost, spent on bash call overhead rather than
# work. The single-rect twin this replaced sat here dead for weeks, holding the only copy of the
# reasoning below.) Rects live in _FT_DD_T/_L/_B/_R (count _FT_DD_N), filled by ft_redraw_dirty.
#
# THREE THINGS THE SKIP TEST HAS TO GET RIGHT, each of them a bug that was reported as residue:
#
#  · An ANCESTOR always "intersects" a damage rect inside it — but a control that FILLS ITS WHOLE
#    BOX would then repaint its background over the whole region, wiping every sibling the damage
#    never covered. That is what blanked the specimen: dirtying the damage rect enlisted the root
#    form, whose draw fills the screen. `_ft_damage_fill` has already restored the background, so
#    such a control is only worth repainting for its DECORATION — i.e. when the damage actually
#    reaches its border ring (`ring` above).
#
#  · A CONTAINER WITH NO INK OF ITS OWN has nothing to repair — it neither fills a background nor
#    draws a border — and enlisting it drags its entire subtree along. Measured: a 2×2 rect in the
#    middle of the callout demo's stage enlisted TWENTY-SIX controls, because `stage` is a
#    borderless div spanning the screen. That is why dragging a callout repainted the whole page.
#
#  · "HAS KIDS" IS NOT THAT PREDICATE. A checkbox carries zero-sized option data nodes as
#    children, so a kids-only test read it as a container and skipped it — a drag ghost crossing
#    "[ ] Read-only" left "-only", because the checkbox's own text was never repainted over the
#    ground refill (the reported drag residue, byte-replay traced to exactly this line). What "no
#    ink of its own" means is NO DRAW FUNCTION: every painting control registers one, and the
#    see-through containers (div, form's stage, empty) are precisely the types that do not.
#
# And a container that IS enlisted repaints its whole interior, not just the damaged part, so
# every child it will paint over is enlisted with it (`ft_dirty_subtree`). The skips above dodge
# that by not repainting at all, which works only while the damage sits wholly inside the
# container: a rect STRADDLING the border (a callout out in the screen margin whose extent reaches
# back in to its target) is neither interior-only nor outside, so the frame was enlisted, repainted
# its interior, and wiped the prose and both code panes — which had never intersected the rect and
# so were never enlisted. Erased, with nothing left to paint them back. Enlisting the subtree is a
# SUPERSET of what is strictly needed: draws are idempotent, so the extra repaints cost time, not
# correctness, and only on the damage path — a step or page change, not the per-frame composite.
declare -a _FT_DD_T=() _FT_DD_L=() _FT_DD_B=() _FT_DD_R=()
declare -i _FT_DD_N=0
# THE ENLISTED SET IS NOT THE DIRTY SET. Every control below was enlisted because the refill
# painted ground over cells it owns — its content has not changed, only its pixels were taken
# away. That is exactly the statement the retained display list can answer with an append, so
# these go in FT_REPAIR and not in FT_DIRTY, which would drop their entries. Measured on
# tools/bench-drag.bash: the four controls a dragged callout uncovers cost 11.25ms a frame to
# re-derive and ~1ms to re-emit, and they produce byte-identical output 19 frames out of 20.
declare -A FT_REPAIR=()
_ft_repair_subtree() {          # name — the container repaints its whole interior, so its
    local n=$1 kid                  # children go with it (see the note above ft_dirty_subtree)
    FT_REPAIR[$n]=1
    for kid in ${FT_KIDS[$n]:-}; do
        # A NODE WITH NO BOX OWNS NO CELLS to be painted over. A table's rows, a select's options
        # and a tree's nodes are children in the tree and data to their control — 0x0, no draw —
        # and a painted container now repairs its subtree on every dirty frame, so a table of a
        # thousand rows must not cost a thousand no-op draws per cursor move.
        (( ${FT_MEASURED_WIDTH[$kid]:-0} > 0 && ${FT_MEASURED_HEIGHT[$kid]:-0} > 0 )) || continue
        _ft_repair_subtree "$kid"
    done
}
_ft_damage_enlist() {           # node   (was _ft_damage_dirty_multi, which named the wrong set)
    local n=$1 kid
    local ay=${FT_ABSOLUTE_Y[$n]:-} ax=${FT_ABSOLUTE_X[$n]:-}
    if [[ -n "$ay" && -n "$ax" ]]; then
        local h=${FT_MEASURED_HEIGHT[$n]:-0} w=${FT_MEASURED_WIDTH[$n]:-0}
        if (( h >= 1 && w >= 1 )); then
            local ab=$(( ay+h-1 )) ar=$(( ax+w-1 )) k hit=0 ring=0
            for (( k=0; k<_FT_DD_N; k++ )); do
                (( _FT_DD_B[k] < ay || _FT_DD_T[k] > ab || _FT_DD_R[k] < ax || _FT_DD_L[k] > ar )) && continue
                hit=1
                (( _FT_DD_T[k] > ay && _FT_DD_B[k] < ab && _FT_DD_L[k] > ax && _FT_DD_R[k] < ar )) \
                    || { ring=1; break; }
            done
            if (( hit )); then
                local ty=${FT_TYPE[$n]:-} skip=0
                if (( ${FT_PROTO_FILLS_BACKGROUND[$ty]:-0} == 1 )); then
                    skip=1
                elif (( FT_DAMAGE_NARROW )) && [[ -n "${FT_KIDS[$n]:-}" && -z "${FT_PROTO_DRAW[$ty]:-}" ]] \
                     && { _ft_border "$n"; (( ! FT_RET )); }; then
                    skip=1      # draw-less containers only — see "HAS KIDS IS NOT THAT PREDICATE"
                elif [[ "$ty" == frame ]] && (( ! ring )); then
                    skip=1
                fi
                if (( ! skip )); then
                    FT_REPAIR[$n]=1
                    if [[ -n "${FT_KIDS[$n]:-}" ]]; then _ft_repair_subtree "$n"; return 0; fi
                fi
            fi
        fi
    fi
    for kid in ${FT_KIDS[$n]:-}; do _ft_damage_enlist "$kid"; done
}
# ft_dirty_subtree NAME — every control at or below NAME needs repainting.
#
# PUBLIC, and it has to be: an application that edits a STYLESHEET at runtime has changed how a
# branch resolves without touching any property, so ft_set never sees it and cannot repaint
# for it. Repainting the whole app instead is the sledgehammer demo/css-demo.bash measured at
# ~0.3s per checkbox, so narrowing to the branch that actually changed is a legitimate choice
# an app is entitled to make — with a public name, not by reaching for an underscore.
# (_ft_repair_subtree is its damage-path twin: same walk, the other set, for the reason given
# there — a repair has not changed anybody's content.)
ft_dirty_subtree() {           # name
    local n=$1 kid
    # CALLS ft_dirty RATHER THAN REPEATING IT. This used to be `FT_DIRTY[$n]=1` plus the two
    # unsets, under a comment reading "same predicate as ft_dirty" — true when it was written,
    # and a copy, so it drifted the moment ft_dirty grew the paint-dependency walk. A control
    # whose paint derives from another one came back stale on this route and not on its sibling,
    # which is the shape CONTRIBUTING §1 opens with. One call per node is what it costs.
    ft_dirty "$n"
    for kid in ${FT_KIDS[$n]:-}; do ft_dirty_subtree "$kid"; done
}
ft_redraw_dirty() {
    (( FT_COALESCING )) && return          # defer paint until the input burst drains
    # A control that just became visible and whose cascade asks for a `transition` is armed
    # HERE: layout has settled (ft_reflow_flush ran before this), and it happens before any
    # painting, so the transition owns its cells before the paint that would have drawn them.
    declare -F _ft_transition_arm_pending >/dev/null 2>&1 && _ft_transition_arm_pending
    (( ${#FT_DIRTY[@]} == 0 && ${#FT_DAMAGE[@]} == 0 && ${#FT_REPAIR[@]} == 0 )) && return
    # REPAIR PASS — refill each damaged region, then enlist everything that overlaps it.
    if (( ${#FT_DAMAGE[@]} )); then
        local d
        local -a dmg=("${FT_DAMAGE[@]}")
        FT_DAMAGE=()
        # A frame repairs each DISTINCT rect once. A coalesced burst reports the same region
        # every event — three mouse-moves each damage the same old leader segments — and the fill
        # is per-cell, so processing the duplicates tripled the frame's whole cost for cells that
        # were already ground. Exact-match dedupe is enough for that shape and costs one hash
        # lookup per rect.
        local -A _dseen=()
        local _tprof=""
        [[ -n "${FT_BURST_LOG:-}" ]] && { ft_now_ms; _tprof=$FT_RET; }
        _FT_DFILL_BUILT=0               # geometry is stable for the pass: build the cuts once
        _FT_DD_T=(); _FT_DD_L=(); _FT_DD_B=(); _FT_DD_R=(); _FT_DD_N=0
        # MERGE THE STRIPS BEFORE FILLING. A drag burst reports the ghost ring's pieces at every
        # position the pointer visited, and the pieces overlap heavily: at eight moves a settle,
        # sixteen distinct rects whose union is a fraction of their sum. Exact dedupe cannot see
        # it (each rect differs by a column or two), but the drag's shapes are all ONE-ROW or
        # ONE-COLUMN strips, and merging intervals within a row (or column) is one sort-free
        # pass over a small map. Anything not a strip fills as it always did.
        local -A _rowiv=() _coliv=()
        local _k2 _iv _lo2 _hi2
        for d in "${dmg[@]}"; do
            [[ -n "${_dseen[$d]:-}" ]] && continue
            _dseen[$d]=1
            set -- $d
            if (( $1 == $3 )); then _rowiv[$1]+="$2 $4;"
            elif (( $2 == $4 )); then _coliv[$2]+="$1 $3;"
            else
                _ft_damage_fill "$1" "$2" "$3" "$4"
                _FT_DFILL_BUILT=1
                _FT_DD_T+=("$1"); _FT_DD_L+=("$2"); _FT_DD_B+=("$3"); _FT_DD_R+=("$4"); (( _FT_DD_N++ ))
            fi
        done
        for _k2 in "${!_rowiv[@]}"; do
            _iv=${_rowiv[$_k2]}
            while [[ -n "$_iv" ]]; do              # absorb overlapping/adjacent intervals
                set -- ${_iv%%;*}; _lo2=$1; _hi2=$2; _iv=${_iv#*;}
                local _iv2="" _seg2 _a _b _grew=1
                while (( _grew )); do
                    _grew=0; _iv2=""
                    while [[ -n "$_iv" ]]; do
                        _seg2=${_iv%%;*}; _iv=${_iv#*;}
                        set -- $_seg2; _a=$1; _b=$2
                        if (( _a <= _hi2 + 1 && _b >= _lo2 - 1 )); then
                            (( _a < _lo2 )) && _lo2=$_a; (( _b > _hi2 )) && { _hi2=$_b; }
                            _grew=1
                        else _iv2+="$_seg2;"; fi
                    done
                    _iv=$_iv2
                done
                _ft_damage_fill "$_k2" "$_lo2" "$_k2" "$_hi2"
                _FT_DFILL_BUILT=1
                _FT_DD_T+=("$_k2"); _FT_DD_L+=("$_lo2"); _FT_DD_B+=("$_k2"); _FT_DD_R+=("$_hi2"); (( _FT_DD_N++ ))
            done
        done
        for _k2 in "${!_coliv[@]}"; do
            _iv=${_coliv[$_k2]}
            while [[ -n "$_iv" ]]; do
                set -- ${_iv%%;*}; _lo2=$1; _hi2=$2; _iv=${_iv#*;}
                local _iv3="" _seg3 _a2 _b2 _grew2=1
                while (( _grew2 )); do
                    _grew2=0; _iv3=""
                    while [[ -n "$_iv" ]]; do
                        _seg3=${_iv%%;*}; _iv=${_iv#*;}
                        set -- $_seg3; _a2=$1; _b2=$2
                        if (( _a2 <= _hi2 + 1 && _b2 >= _lo2 - 1 )); then
                            (( _a2 < _lo2 )) && _lo2=$_a2; (( _b2 > _hi2 )) && { _hi2=$_b2; }
                            _grew2=1
                        else _iv3+="$_seg3;"; fi
                    done
                    _iv=$_iv3
                done
                _ft_damage_fill "$_lo2" "$_k2" "$_hi2" "$_k2"
                _FT_DFILL_BUILT=1
                _FT_DD_T+=("$_lo2"); _FT_DD_L+=("$_k2"); _FT_DD_B+=("$_hi2"); _FT_DD_R+=("$_k2"); (( _FT_DD_N++ ))
            done
        done
        _FT_DFILL_BUILT=0               # direct callers outside a pass rebuild every call
        [[ -n "$_tprof" ]] && { ft_now_ms; printf 'STG fill %s rects=%s runs=%s\n' $(( FT_RET - _tprof )) "$_FT_DD_N" "${_FT_DFILL_RUNS:-0}" >> "$FT_BURST_LOG"; _tprof=$FT_RET; _FT_DFILL_RUNS=0; }
        # enlist repainting controls for ALL the rects in one tree walk, not one walk per rect
        [[ -n "${FT_ROOT:-}" ]] && (( _FT_DD_N )) && _ft_damage_enlist "$FT_ROOT"
        [[ -n "$_tprof" ]] && { ft_now_ms; printf 'STG enlist %s dirty=%s repair=%s\n' $(( FT_RET - _tprof )) "${#FT_DIRTY[@]}" "${#FT_REPAIR[@]}" >> "$FT_BURST_LOG"; }
        if [[ -n "${FT_DAMAGE_DEBUG:-}" ]]; then
            local _dbg
            for (( _dbg=0; _dbg<_FT_DD_N; _dbg++ )); do
                printf 'DMG rect %s,%s..%s,%s\n' "${_FT_DD_T[_dbg]}" "${_FT_DD_L[_dbg]}" \
                    "${_FT_DD_B[_dbg]}" "${_FT_DD_R[_dbg]}" >&2
            done
            printf 'DMG enlisted: %s\n' "${!FT_REPAIR[*]}" >&2
        fi
        _FT_DMG_LAST=("${dmg[@]}")         # overlays covering a repaired region must recomposite
    else
        _FT_DMG_LAST=()
    fi
    # A REPAIRED REGION MUST RECOMPOSITE THE OVERLAYS IT WAS UNDER, even when the repair enlisted
    # no controls — the refill just painted ground over the overlay's cells, and flushing that
    # frame without recompositing ships a half-erased callout. This path was unreachable while
    # every damage rect enlisted a container subtree; narrowed repair (FT_DAMAGE_NARROW) makes
    # pure-ground repairs routine, and this is the frame a dragged chip lives in.
    if (( ${#FT_DIRTY[@]} == 0 && ${#FT_REPAIR[@]} == 0 )); then
        if (( ${#_FT_DMG_LAST[@]} )); then _ft_composite_overlays_touching; ft_flush; fi
        return
    fi
    # A CONTROL THAT PAINTS ITS BOX PAINTS OVER ITS CHILDREN, so a dirty container repairs every
    # child it is about to cover. The damage path has always done this (_ft_damage_enlist, "a
    # container that IS enlisted repaints its whole interior") and the dirty path did not: a
    # frame's borderColor, a tab strip's focus, any paint-kind write on anything with children
    # repainted the container and left its children blank. The focus route had a copy of the
    # rule, keyed on the prototype declaring fillsBackground — which frame never did, so moving
    # focus onto a frame blanked it too. One rule, here, where every dirty paint passes.
    #
    # REPAIR, NOT DIRTY: the children's content has not changed, only their cells were painted
    # over, and a retained block re-emits in a fraction of a derive. A container with no draw
    # paints nothing and covers nobody. Found by tests/test-incremental.bash.
    local name
    for name in "${!FT_DIRTY[@]}"; do
        [[ -n "${FT_KIDS[$name]:-}" ]] || continue
        _ft_resolve_draw "$name"; [[ -n "$FT_RET" ]] && _ft_repair_subtree "$name"
    done
    # The paint set is the UNION of the two: content that changed and cells that were taken
    # away. ft_draw_one tells them apart by itself — a dirtied control has no retained entry
    # left to serve — so this loop does not have to.
    local -a names=("${!FT_DIRTY[@]}")
    for name in "${!FT_REPAIR[@]}"; do
        [[ -n "${FT_DIRTY[$name]:-}" ]] || names+=("$name")   # a dirty one is in by the stronger claim
    done
    _ft_paint_order "${names[@]}"
    names=("${FT_PAINT_ORDER[@]}")
    local _tp2=""
    [[ -n "${FT_BURST_LOG:-}" ]] && { ft_now_ms; _tp2=$FT_RET; }
    # AN OVERLAY IN THE DIRTY SET WOULD PAINT TWICE: once here in depth order, then again when
    # `_ft_composite_overlays_touching` re-composites it above whatever else painted — and a
    # composite IS the overlay's draw, so a dirty callout cost two full paints per settle
    # (measured: ~15-20ms of every drag frame). The first paint is also the WRONG one to keep:
    # only the composite is guaranteed to land above the controls painted this pass. Skip
    # overlays here and hand them to the compositor, which repaints anything in the dirty set.
    for name in "${names[@]}"; do
        [[ -n "${FT_OVERLAY[$name]:-}" ]] && continue
        ft_draw_one "$name"
    done
    [[ -n "$_tp2" ]] && { ft_now_ms; printf 'STG draw %s controls=%s [%s]\n' $(( FT_RET - _tp2 )) "${#names[@]}" "${names[*]}" >> "$FT_BURST_LOG"; _tp2=$FT_RET; }
    _ft_composite_overlays_touching "${names[@]}"   # recomposite only overlays a painted control touched
    [[ -n "$_tp2" ]] && { ft_now_ms; printf 'STG composite %s\n' $(( FT_RET - _tp2 )) >> "$FT_BURST_LOG"; }
    ft_flush
    FT_DIRTY=(); FT_REPAIR=()
}
# Recomposite overlays that a just-painted control actually overlapped (or that are themselves in
# the painted set). This keeps an ANIMATION that repaints one control from redrawing a callout
# parked elsewhere every frame — the per-frame lag on pages with a live @keyframes animation.
declare -a _FT_DMG_LAST=()      # damage rects repaired this frame (overlays over them must redraw)
# Thin rects an overlay painted OUTSIDE its box rect — a callout's leader segments and
# arrowhead. The recomposite test below uses the box alone for the common case (cheap, and what
# keeps an animation from redrawing a margin-parked callout every frame); these are the cells
# that are NOT in the box but are still the overlay's pixels, so an animated control repainting
# beneath one of them must recomposite the overlay or the line flickers away until the next
# full repaint. Published by the overlay's draw ("T L B R;…"), removed with it.
declare -A FT_OVERLAY_EXTRA=()
_ft_composite_overlays_touching() {    # $@ = names painted this pass
    (( ${#FT_OVERLAY[@]} == 0 )) && return
    local -a pr=() pov=(); local p ax ay aw ah
    # a repaired damage region counts exactly like a painted control: an overlay covering it was
    # overwritten by the refill and must composite again
    for p in "${_FT_DMG_LAST[@]}"; do pr+=("$p"); done
    for p in "$@"; do
        [[ -n "${FT_OVERLAY[$p]:-}" ]] && { pov+=("$p"); continue; }   # an overlay itself was painted
        ax=${FT_ABSOLUTE_X[$p]:-}; [[ -z "$ax" ]] && continue
        ay=${FT_ABSOLUTE_Y[$p]:-0}; aw=${FT_MEASURED_WIDTH[$p]:-0}; ah=${FT_MEASURED_HEIGHT[$p]:-0}
        (( aw<1 || ah<1 )) && continue
        pr+=("$ay $ax $(( ay+ah-1 )) $(( ax+aw-1 ))")
    done
    (( ${#pr[@]} == 0 && ${#pov[@]} == 0 )) && return
    _FT_DMG_LAST=()
    local n pass rect ot ol ob orr r rt rl rb rr hit
    for pass in 0 1; do
        for n in "${!FT_OVERLAY[@]}"; do
            [[ -n "${FT_TYPE[$n]:-}" ]] || { unset "FT_OVERLAY[$n]"; continue; }
            (( pass == 0 )) && (( ${FT_OVERLAY_Z_ORDER[$n]:-0} > 0 )) && continue
            (( pass == 1 )) && (( ${FT_OVERLAY_Z_ORDER[$n]:-0} == 0 )) && continue
            _ft_disp "$n"; [[ "$FT_RET" == none ]] && continue
            hit=0
            for p in "${pov[@]}"; do [[ "$p" == "$n" ]] && { hit=1; break; }; done   # painted overlay
            rect=${FT_OVERLAY[$n]}
            if (( ! hit )) && [[ "$rect" == 1 || -z "$rect" ]]; then hit=1; fi        # not yet placed
            # `set --` word-splitting, not `read <<<`: a herestring materialises a temp file per
            # read, and this loop was doing dozens per settle — measured as most of the
            # composite's ~26ms with the actual drawing at a fifth of that.
            if (( ! hit )); then
                set -- $rect; ot=$1; ol=$2; ob=$3; orr=$4
                for r in "${pr[@]}"; do
                    set -- $r; rt=$1; rl=$2; rb=$3; rr=$4
                    (( rl<=orr && rr>=ol && rt<=ob && rb>=ot )) && { hit=1; break; }
                done
            fi
            if (( ! hit )) && [[ -n "${FT_OVERLAY_EXTRA[$n]:-}" ]]; then
                local seg _rest="${FT_OVERLAY_EXTRA[$n]};"
                while [[ -n "$_rest" ]]; do
                    seg=${_rest%%;*}; _rest=${_rest#*;}
                    [[ -z "$seg" ]] && continue
                    set -- $seg; ot=$1; ol=$2; ob=$3; orr=$4
                    for r in "${pr[@]}"; do
                        set -- $r; rt=$1; rl=$2; rb=$3; rr=$4
                        (( rl<=orr && rr>=ol && rt<=ob && rb>=ot )) && { hit=1; _rest=""; break; }
                    done
                done
            fi
            if (( hit )); then
                if [[ -n "${FT_BURST_LOG:-}" ]]; then
                    ft_now_ms; local _tcd=$FT_RET
                    ft_draw_one "$n"
                    ft_now_ms; printf 'STG comp-draw %s %s\n' $(( FT_RET - _tcd )) "$n" >> "$FT_BURST_LOG"
                else
                    ft_draw_one "$n"
                fi
            fi
        done
    done
}

# ── Focus ────────────────────────────────────────────────────────────────────
# The ring is the form's focusable controls in DECLARATION order (HTML tab
# order), assembled automatically when end_ft_form runs. Focus persists
# across a rebuild because names are stable: if the previously-focused NAME
# exists in the new ring, it stays focused; otherwise the first entry does.
FT_FOCUS=""
FT_FOCUS_RING=()
FT_FOCUS_INDEX=0

# THE ARROW TRAIL — one step of history, so that reversing an arrow undoes it.
# Geometry alone is not enough to make directional focus feel consistent: step DOWN from the
# right-hand control of a row and the control below may sit between two above it, so pressing
# UP walks to the LEFT one and you never get back where you were. Nothing is wrong with the
# geometry — the answer is genuinely ambiguous — so the tiebreak is memory: where you came
# from. Recorded on ARRIVAL, and only by ft_focus_dir; every other way of taking focus (Tab, a
# click, ft_focus from app code) clears it in _ft_focus_gain, because a trail that outlives
# the walk that made it would send an arrow somewhere the user never was.
declare -A FT_FOCUS_CAME_FROM=()        # control → the control an arrow arrived from
declare -A FT_FOCUS_CAME_DIR=()         # control → the direction that arrow travelled

# The ring is declaration order (HTML tab order). Initial focus, in priority:
#   1. a control declared with autofocus=true (HTML's autofocus attribute)
#   2. the SAME NAME that was focused before (persists across rebuilds —
#      stable ids; a wizard keeps you where you were)
#   3. the first focusable control
# then skips forward past anything currently unfocusable.
# Collect this form's focusables in TREE ORDER, which for a statically-built form is exactly
# declaration order. A nested form owns its own ring, so the walk stops at one.
_ft_focus_collect() {           # node
    local kid
    for kid in ${FT_KIDS[$1]:-}; do
        [[ -n "${FT_TYPE[$kid]:-}" ]] || continue
        [[ "${FT_FOCUSABLE[$kid]:-}" == 1 ]] && FT_FOCUS_RING+=("$kid")
        [[ "${FT_TYPE[$kid]}" == form ]] && continue
        _ft_focus_collect "$kid"
    done
}
ft_focus_ring_build() {         # form
    local form=$1
    # BUILD FROM THE TREE, NOT FROM THE PENDING LIST. Pending holds only what has been
    # declared SINCE the last build, and it is cleared here — so a form that added one control
    # at runtime and called ft_refresh (the documented way) had its ENTIRE RING REPLACED by
    # that single control, and Tab then cycled between it and itself. The tree already knows
    # every focusable and their order, including the new one in its right place, and it forgets
    # removed ones for free. Pending survives only as the "something changed, rebuild" signal.
    FT_FOCUS_RING=()
    _ft_focus_collect "$form"
    FT_PENDING_FOCUS[$form]=""
    local target=0 i autofocused=""
    for i in "${!FT_FOCUS_RING[@]}"; do
        _ft_get_raw "${FT_FOCUS_RING[$i]}" autofocus
        [[ "$FT_RET" == true ]] && { autofocused=$i; break; }
    done
    if [[ -n "$autofocused" ]]; then
        target=$autofocused
    else
        for i in "${!FT_FOCUS_RING[@]}"; do
            [[ "${FT_FOCUS_RING[$i]}" == "$FT_FOCUS" ]] && { target=$i; break; }
        done
    fi
    FT_FOCUS_INDEX=$target
    # …and the same on the autofocus-steal route: if the ring build is about to move focus off
    # a live control, that control is being left, so it must be blurred first.
    [[ -n "${FT_FOCUS:-}" && "$FT_FOCUS" != "${FT_FOCUS_RING[$FT_FOCUS_INDEX]:-}" ]] \
        && _ft_focus_blur "$FT_FOCUS"
    _ft_focus_land "${FT_FOCUS_RING[$FT_FOCUS_INDEX]:-}"
    # Never leave focus on something currently invisible/skippable.
    [[ -n "$FT_FOCUS" ]] && _ft_focus_skippable "$FT_FOCUS" && ft_focus_move 1
    [[ -n "$FT_FOCUS" ]] && _ft_focus_dirty "$FT_FOCUS"
}

# ft_focus_first — move focus to the first focusable control in declaration
# order (skipping anything currently unfocusable). Overrides name-persistence
# for apps that want a fresh "top of the page" focus on every screen.
ft_focus_first() {
    (( ${#FT_FOCUS_RING[@]} == 0 )) && return 0
    _ft_focus_dirty "${FT_FOCUS_RING[$FT_FOCUS_INDEX]:-}"
    # LEAVING ENDS THE ACTIVATION, on this route as on its siblings. ft_focus_move and
    # _ft_focus_set_try blur the control they leave; this one landed ring[0] without it, so a
    # field abandoned here kept runlevel=editing — still matching :engaged, still drawing its
    # edit border, and Tabbing back landed you mid-edit with the arrows quietly meaning
    # something else. Guarded on an actual move, so re-landing where you already are does not
    # reset a rung you are still on.
    [[ -n "${FT_FOCUS:-}" && "$FT_FOCUS" != "${FT_FOCUS_RING[0]}" ]] && _ft_focus_blur "$FT_FOCUS"
    FT_FOCUS_INDEX=0
    _ft_focus_land "${FT_FOCUS_RING[0]}"
    _ft_focus_skippable "$FT_FOCUS" && ft_focus_move 1
    _ft_focus_dirty "$FT_FOCUS"
    return 0
}

# _ft_focus_skippable NAME → 0 if focus must skip this control right now:
# display=none, or the prototype's own focus-skip predicate says so (e.g. a for=
# scrollbar whose content currently fits — visible focus must never land on
# something the user can't see).
# _ft_hidden_anywhere NAME → 0 if NAME or ANY ancestor is display=none or
# visibility=hidden (a control inside a hidden container is itself hidden,
# just like the DOM). Used so focus and accelerators never land on something
# that is not actually on screen.
# ONE ANSWER TO "IS THIS VISIBLE?", and it is the cascade's. This used to walk ancestors
# reading the RAW `visibility` and call the control hidden if ANY of them said so — but
# visibility INHERITS, so a child that re-shows itself under a hidden container overrides it,
# which is CSS's rule, what ft_state_is_hidden answers for `:hidden`, and what ft_draw_one
# paints by. The disagreement was reachable through the codebase's own re-show idiom
# (`ft_set X visibility=visible`): the control appeared on screen and matched
# `button:visible`, while focus refused to land on it and its accessKey did nothing.
_ft_hidden_anywhere() { ft_state_is_hidden "$1"; }
_ft_focus_skippable() {         # name
    local name=$1
    # A control that no longer exists is not focusable — and asking about its type would
    # subscript an associative array with "", which is a bash ERROR printed to stderr, i.e.
    # onto the alt screen. A removed control's name can still be sitting in the focus ring.
    local ty=${FT_TYPE[$name]:-}
    [[ -z "$ty" ]] && return 0
    _ft_hidden_anywhere "$name" && return 0   # hidden here OR under a hidden ancestor
    ft_resolved_prop "$name" disabled false
    [[ "$FT_RET" == true ]] && return 0   # inherits: disabling a container disables its subtree
    local fn=${FT_PROTO_FOCUS_SKIP[$ty]:-}
    [[ -n "$fn" ]] && "$fn" "$name" && return 0
    return 1
}

# ft_focus_move DELTA — skips currently-unfocusable entries; if every entry
# is skippable, focus stays put.
# A control losing focus may need to tear down transient state (a text field in
# edit mode must drop back to idle so Tabbing back in doesn't land mid-edit). A
# prototype opts in by defining _ft_blur_<type>; the focus machinery calls it here.
_ft_focus_blur() {              # name (the control losing focus)
    local n=${1:-}; [[ -z "$n" ]] && return
    local fn="_ft_blur_${FT_TYPE[$n]:-}"
    declare -F "$fn" >/dev/null 2>&1 && "$fn" "$n"
    # LEAVING A CONTROL ENDS ITS ACTIVATION — for EVERY prototype, not just the ones that
    # remembered to opt in. The comment above has always said a field must drop back to idle
    # so Tabbing in does not land mid-edit, but it was enforced only by an optional
    # per-prototype hook, and no prototype defined one: a slider Tabbed away from stayed in
    # `adjusting`, a tree and a select stayed in `browsing`, a field stayed in `editing`. Come back
    # to it and the arrows silently meant something else than they did on every other control — with
    # nothing on screen saying so. Runlevel is an ordinary property, so this fires the prototype's
    # runlevel exit script and invalidates the cascade for free; a prototype needs no code to take
    # part.
    local _rv="_ftp_${n}_runlevel"
    [[ -n "${!_rv-}" && "${!_rv-}" != unfocused ]] && _ft_setprop "$n" runlevel unfocused
    return 0
}
# Symmetric focus-IN hook: a prototype may define _ft_focusin_<type> to react to
# GAINING focus (e.g. a text field with activateToEdit=false starts editing).
# EVERY path that changes which control has focus lands here. Setting FT_FOCUS alone leaves
# the control's rung saying `unfocused` while it plainly is not — so its border, its cursor
# highlight and any rung-keyed animation all describe the wrong state. Three paths did
# exactly that (ft_focus_ring_build, ft_focus_first, ft_modal_pop) and each lost focus
# styling in a different situation, which is why it took a rename to notice.
_ft_focus_land() {              # name — already chosen; the ring index is the caller's job
    FT_FOCUS=${1:-}
    [[ -n "$FT_FOCUS" ]] || return 0
    _ft_focus_gain "$FT_FOCUS"
    return 0
}
_ft_focus_gain() {              # name (the control gaining focus)
    local n=${1:-}; [[ -z "$n" ]] && return
    # Arriving CLEARS the arrow trail; ft_focus_dir writes its own straight after this returns.
    # Every path lands here, so a Tab, a click or an app-driven ft_focus all drop the memory —
    # which is the point. The trail is only meaningful for the step that just happened.
    unset "FT_FOCUS_CAME_FROM[$n]" "FT_FOCUS_CAME_DIR[$n]"
    # `poised` is a RUNG, not a separate axis — climbing onto it is what gaining focus means.
    # Before the prototype hook, so a prototype that wants to go deeper still (activateToEdit=false)
    # deepens from a settled state rather than racing it.
    _ft_runlevel_focus_gained "$n"
    local fn="_ft_focusin_${FT_TYPE[$n]:-}"
    declare -F "$fn" >/dev/null 2>&1 && "$fn" "$n"
}
ft_focus_move() {               # delta [name token — ignored, keymap-callable]
    local delta=$1 n=${#FT_FOCUS_RING[@]} tries=0
    (( n == 0 )) && return 0
    _ft_focus_blur "${FT_FOCUS_RING[$FT_FOCUS_INDEX]:-}"
    _ft_focus_dirty "${FT_FOCUS_RING[$FT_FOCUS_INDEX]:-}"
    while (( tries++ < n )); do
        FT_FOCUS_INDEX=$(( (FT_FOCUS_INDEX + delta + n) % n ))
        _ft_focus_skippable "${FT_FOCUS_RING[$FT_FOCUS_INDEX]}" || break
    done
    _ft_focus_land "${FT_FOCUS_RING[$FT_FOCUS_INDEX]}"
    _ft_focus_dirty "$FT_FOCUS"
    return 0
}
ft_focus_next() { ft_focus_move 1; }
ft_focus_prev() { ft_focus_move -1; }

# ── Spatial (directional) focus ──────────────────────────────────────────────
# Tab/Shift-Tab walk the ring in declaration order; the ARROWS move by GEOMETRY, so
# you can cut across columns the way the layout looks. ft_focus_dir picks, among the
# focusable controls in the current ring, the nearest one that lies in the requested
# direction — scored by distance along the travel axis plus a penalty for how far it
# is off your current line (so a control on the same row/column wins over a closer one
# that is skewed away). The "what is on my line" reasoning lives here; callers never
# compute geometry. Edge behaviour: LEFT/RIGHT stop dead at the edge (there is nothing
# beside you); UP/DOWN fall back to linear prev/next, which wraps the ring, so vertical
# travel never gets stuck. Boxes use centre*2 (integer, no rounding) from the current
# layout's absolute geometry.
# A TERMINAL CELL IS ABOUT TWICE AS TALL AS IT IS WIDE, so a row and a column are not the same
# distance and must not be added as if they were. Everything below is measured in DOUBLED
# COLUMN-EQUIVALENTS: centres are already ×2 (integer, no rounding), and a row counts as
# FT_FOCUS_ROW_ASPECT columns. Without this, "20 rows away" and "20 columns away" score the
# same and the answer looks arbitrary in one axis.
: "${FT_FOCUS_ROW_ASPECT:=2}"
# What being OFF the current line costs, in columns. A control your box does not line up with
# should lose to one it does, but by a BOUNDED amount — the old score multiplied the cross-axis
# distance by 4 with no ceiling, so 14 columns off-line cost 112 while 20 rows of travel cost
# 40, and a button 20 rows below won over the control 3 rows below. Being off-line is close to
# a yes/no fact about whether you meant this control; how far off-line barely matters once you
# are, which is why this is a flat charge and the gap itself is weighted lightly.
#
# It is charged in the CROSS AXIS'S OWN UNIT, and that is what makes the constant robust rather
# than lucky. Pressing Right, "off-line" means off by ROWS — a coarse, obvious mistake worth
# two columns each. Pressing Down it means off by COLUMNS, a much smaller drift. Charging both
# the same flat number left only 4 values satisfying every pinned case AND the reported bug;
# charging it per axis doubles that window to 8..15, so the value below is a choice near the
# middle rather than the one number that happened to fit. Both walls are pinned by tests, so a
# future edit that drifts out of the window fails rather than degrading quietly.
: "${FT_FOCUS_OFF_LINE_PENALTY:=12}"
# The clear gap between two 1-D ranges — 0 when they overlap, so "on my line" is gap 0 and
# nothing else has to special-case it.
_ft_range_gap() {               # aLo aHi bLo bHi → FT_RET
    if   (( $1 > $4 )); then FT_RET=$(( $1 - $4 - 1 ))
    elif (( $3 > $2 )); then FT_RET=$(( $3 - $2 - 1 ))
    else                     FT_RET=0
    fi
}
# _ft_focus_dir_score CAND → FT_RET = how bad a move this is; returns 1 when CAND is not in the
# direction at all. By bash dynamic scope it reads the caller's `dir` and current-control
# geometry (cx/cy/cxl/cxr/cyt/cyb), the way its predecessor did.
#
# ONE SCORE, not a two-pass band search. The old code first found the nearest row containing a
# control that overlapped you, then picked within it, and fell back to `travel + cross*4` when
# nothing overlapped. Two regimes meant two behaviours to reason about, and the fallback is
# where the reported bug lived; a single bounded score has one.
_ft_focus_dir_score() {         # cand
    local c=$1 travel gap off_line_penalty
    local xl=${FT_ABSOLUTE_X[$c]:-0} yt=${FT_ABSOLUTE_Y[$c]:-0}
    local xr=$(( xl + ${FT_MEASURED_WIDTH[$c]:-1} - 1 ))
    local yb=$(( yt + ${FT_MEASURED_HEIGHT[$c]:-1} - 1 ))
    local ex=$(( xl*2 + ${FT_MEASURED_WIDTH[$c]:-1} ))
    local ey=$(( yt*2 + ${FT_MEASURED_HEIGHT[$c]:-1} ))
    case $dir in
        down|up)
            if [[ "$dir" == down ]]; then (( ey > cy )) || return 1; travel=$(( ey - cy ))
            else                          (( ey < cy )) || return 1; travel=$(( cy - ey )); fi
            travel=$(( travel * FT_FOCUS_ROW_ASPECT ))     # doubled rows → column-equivalents
            # Off-line here means off by COLUMNS: the fine axis, so the plain charge.
            _ft_range_gap "$xl" "$xr" "$cxl" "$cxr"; gap=$(( FT_RET * 2 ))
            off_line_penalty=$(( FT_FOCUS_OFF_LINE_PENALTY * 2 )) ;;
        right|left)
            if [[ "$dir" == right ]]; then (( ex > cx )) || return 1; travel=$(( ex - cx ))
            else                           (( ex < cx )) || return 1; travel=$(( cx - ex )); fi
            # Off-line here means off by ROWS: the coarse axis, and a drift you notice, so the
            # same charge measured in rows — which is FT_FOCUS_ROW_ASPECT times as many columns.
            _ft_range_gap "$yt" "$yb" "$cyt" "$cyb"; gap=$(( FT_RET * 2 * FT_FOCUS_ROW_ASPECT ))
            off_line_penalty=$(( FT_FOCUS_OFF_LINE_PENALTY * 2 * FT_FOCUS_ROW_ASPECT )) ;;
        *) return 1 ;;
    esac
    FT_RET=$(( travel + gap ))
    (( gap )) && FT_RET=$(( FT_RET + off_line_penalty ))
    return 0
}
ft_focus_dir() {                # dir: left|right|up|down
    local dir=$1 n=${#FT_FOCUS_RING[@]}
    (( n == 0 )) && return 0
    local cur=$FT_FOCUS
    [[ -z "$cur" || -z "${FT_ABSOLUTE_X[$cur]:-}" ]] && { case $dir in up|left) ft_focus_move -1 ;; *) ft_focus_move 1 ;; esac; return 0; }
    # Current control's cell RANGES (for the on-your-line test) and centres (×2, for distance).
    local cxl=${FT_ABSOLUTE_X[$cur]:-0} cyt=${FT_ABSOLUTE_Y[$cur]:-0}
    local cxr=$(( cxl + ${FT_MEASURED_WIDTH[$cur]:-1} - 1 )) cyb=$(( cyt + ${FT_MEASURED_HEIGHT[$cur]:-1} - 1 ))
    local cx=$(( cxl*2 + ${FT_MEASURED_WIDTH[$cur]:-1} )) cy=$(( cyt*2 + ${FT_MEASURED_HEIGHT[$cur]:-1} ))
    # Reversing the arrow you just pressed should bring you back. `back` is only set when this
    # keypress is the exact opposite of the one that landed us here — it is a TIEBREAK, so it
    # can only win among candidates the geometry already considers equally reasonable. That
    # keeps every control reachable: a control the geometry ranks strictly nearer still wins,
    # so Up does not become "always back to where you came from".
    local back="" back_score=""
    case "${FT_FOCUS_CAME_DIR[$cur]:-}:$dir" in
        up:down|down:up|left:right|right:left) back=${FT_FOCUS_CAME_FROM[$cur]:-} ;;
    esac
    local i cand best="" bestscore="" score
    for i in "${!FT_FOCUS_RING[@]}"; do
        cand=${FT_FOCUS_RING[$i]}; [[ "$cand" == "$cur" ]] && continue
        [[ -z "${FT_ABSOLUTE_X[$cand]:-}" ]] && continue
        _ft_focus_skippable "$cand" && continue
        _ft_focus_dir_score "$cand" || continue
        score=$FT_RET
        [[ "$cand" == "$back" ]] && back_score=$score   # it survived every filter → a candidate
        if [[ -z "$bestscore" ]] || (( score < bestscore )); then bestscore=$score; best=$cand; fi
    done
    # A TIE, and nothing more. This used to override `best` whenever the control you came from
    # was a candidate at all, whatever it scored — which contradicted the paragraph above it
    # and meant reversing an arrow could never explore, only retrace.
    [[ -n "$best" && -n "$back_score" ]] && (( back_score == bestscore )) && best=$back
    if [[ -n "$best" ]]; then
        ft_focus "$best" && { FT_FOCUS_CAME_FROM[$best]=$cur; FT_FOCUS_CAME_DIR[$best]=$dir; }
        return 0
    fi
    # THE EDGE RULE. Nothing lies that way, so fall back to the ring — the linear order every
    # direction ultimately agrees with. Left/Right used to fall back to NOTHING, which made a
    # control at the right-hand edge a dead end: the arrow you pressed did nothing at all, with
    # no way to tell "there is nothing there" from "the app is wedged". Up/Down already did
    # this, and there was never a reason for the other axis to behave differently.
    case $dir in up|left) ft_focus_move -1 ;; down|right) ft_focus_move 1 ;; esac
    return 0
}
ft_focus_left()  { ft_focus_dir left; }
ft_focus_right() { ft_focus_dir right; }
ft_focus_up()    { ft_focus_dir up; }
ft_focus_down()  { ft_focus_dir down; }

# ── "Where am I?" — the focus locator (the "homing beacon") ──────────────────
# On a busy screen the focus highlight is easy to lose (your eye expects the labels
# arranged between the controls to take focus, and they don't). Pressing the locate key
# ('.' on the form) drops a one-shot BEACON around the focused control: a heavy pulsing
# frame that plays a single lap and then destroys itself, wiping clean.
#
# The beacon control (controls/ft-beacon.bash) owns ALL of it — the drawing, the shared
# animation engine, the theming (--locator-N / --beacon-N), the on-top overlay paint and
# the self-destruct. The locator is now just "make one of those around whatever has
# focus", so the homing beacon is a genuine instance of the reusable prototype rather than a
# private one-off. A forms-only build that never loaded the beacon control simply has no
# locator (the key becomes a no-op) — the layering stays one-directional.
FT_LOCATOR=__ft_locator          # the single, reusable locator-beacon instance
ft_focus_ping() {               # '.' — flash a locator frame around the focused control
    local t=${FT_FOCUS:-}
    [[ -z "$t" || -z "${FT_ABSOLUTE_X[$t]:-}" ]] && return 0
    declare -F ft-beacon >/dev/null 2>&1 || return 0     # no beacon control → no locator
    ft_remove "$FT_LOCATOR" 2>/dev/null                 # never stack two locators
    ft-beacon name="$FT_LOCATOR" target="$t" variant=frame effect=pulse \
              lifetime=oneshot cycles=1 outset=1
    return 0
}

# ── Keycap pulse — the CRUCIAL key breathes so you always see what to do next ──
# The status bar's legend leads with the most important key for the focused control; that
# cap gently pulses its colour so the eye is drawn to it. Fully CSS-driven and THEMEABLE:
# a theme sets `--keycap-pulse` on :root to a space-separated ramp of colours the cap
# cycles through (empty ⇒ no animation, static cap). It runs on the shared animation
# engine with a typing-delay DEBOUNCE, so it FREEZES on its current frame while you type
# and resumes when you pause — never a distraction mid-keystroke. Importance decides WHICH
# caps pulse (crucial tier only); the ramp/speed live in the theme, so the look is a style
# choice, not a constant baked in code.
FT_KCPULSE_MS=120              # frame time — slow, so the pulse reads as a breath not a blink
FT_KCPULSE_DEBOUNCE=2000       # typing-delay freeze (ms): the same ~2s as a field's
                               # activateAnimationTypingDelay, so the whole UI settles in step
# Overlays (an open dropdown, and later menus/popups) paint OVER other controls but have no
# z-order the redraw honours — so a background repaint (the pulse ticking the status bar)
# erases whatever the overlay drew on top of it. While an overlay is up, FT_OVERLAY_DEPTH>0
# and the pulse is suspended, so nothing repaints beneath it. Openers ++ it; closers -- it.
FT_OVERLAY_DEPTH=0
_ft_kcpulse_phase() { FT_RET=${FT_ANIM_PHASE[__ft_kcpulse]:-0}; }
# The keycap SGR for a crucial cap at PHASE: the base keycap chrome (bg + bold) with its
# FOREGROUND overridden to the ramp colour for this phase. "" when the theme sets no ramp.
_ft_kcpulse_capcolor() {       # control phase → FT_RET
    ft_style "$1" --keycap-pulse; local ramp=$FT_RET
    [[ -z "$ramp" ]] && { FT_RET=""; return; }
    local -a r=($ramp); local m=${#r[@]}
    (( m == 0 )) && { FT_RET=""; return; }
    FT_RET="$FT_COLOR_KEYCAP"$'\e[38;5;'"${r[ $2 % m ]}"m
}
# The EXIT chip (ESC while in a mode) breathes its OWN themeable ramp `--keycap-exit-pulse`
# — a run of BACKGROUND colours (amber/gold by default) so the way OUT pulses distinctly
# from the other crucial keys. Dark bold foreground on the bright chip. "" if unthemed.
_ft_kcpulse_exitcolor() {      # control phase → FT_RET
    ft_style "$1" --keycap-exit-pulse; local ramp=$FT_RET
    [[ -z "$ramp" ]] && { FT_RET=""; return; }
    local -a r=($ramp); local m=${#r[@]}
    (( m == 0 )) && { FT_RET=""; return; }
    FT_RET=$'\e[48;5;'"${r[ $2 % m ]}"$';38;5;16;1m'
}
# WHERE THE ANIMATED CAPS LANDED, so a pulse frame can repaint THEM instead of the legend.
# One record per animated cap, "row<TAB>col<TAB>width<TAB>ramp<TAB>text", newline separated;
# `ramp` names which of the two themeable ramps colours it, `crucial` or `exit`. A keylegend
# fills this as it draws, from the geometry that draw already computed; it is declared here,
# with the pulse machinery that reads it, because ft-forms loads before any control does.
declare -A FT_KEYLEGEND_ANIMATED_CELLS=()

# A PULSE FRAME RECOLOURS THE CAPS. It used to answer a colour change with _ft_legend_dirty +
# ft_redraw_dirty + ft_flush, which threw the legend's retained block away and re-derived every
# cap from the focused control's keymap chain and live state — 13.44ms a frame, eight times a
# second, forever, against 0.295ms for the same control served from its retained block. The
# derivation cannot depend on the phase: measured, it produced a byte-identical cap list on 20
# of 20 idle re-derivations. This is the engine's own rule, stated in ft_anim_step: a bound
# routine repaints only what moved.
#
# It does not flush. ft_anim_step composites the overlays and flushes after any bound routine,
# and doing it here as well presented the frame twice.
_ft_kcpulse_frame() {          # engine frame: recolour the animated caps at the new phase
    (( FT_OVERLAY_DEPTH > 0 )) && { _ft_kcpulse_disarm; return; }   # never paint under an overlay
    local phase=${FT_ANIM_PHASE[__ft_kcpulse]:-0}
    local legend cells rest record row col width ramp text crucial_sgr exit_sgr sgr
    for legend in "${!FT_KEYLEGEND_ANIMATED_CELLS[@]}"; do
        cells=${FT_KEYLEGEND_ANIMATED_CELLS[$legend]}
        (( ${#cells} == 0 )) && continue
        # A legend destroyed mid-flight leaves its positions behind; collect them here, the way
        # ft_anim_step collects the animations of controls that are gone.
        [[ -z "${FT_TYPE[$legend]:-}" ]] && { unset "FT_KEYLEGEND_ANIMATED_CELLS[$legend]"; continue; }
        _ft_disp "$legend"; [[ "$FT_RET" == none ]] && continue
        _ft_kcpulse_capcolor  "$legend" "$phase"; crucial_sgr=$FT_RET
        _ft_kcpulse_exitcolor "$legend" "$phase"; exit_sgr=$FT_RET
        # Split by parameter expansion, not `read <<<`: a herestring is a temp file, and this
        # runs on every frame of a permanent animation.
        rest=$cells
        while (( ${#rest} )); do
            record=${rest%%$'\n'*}; rest=${rest#*$'\n'}
            (( ${#record} == 0 )) && continue
            row=${record%%$'\t'*};   record=${record#*$'\t'}
            col=${record%%$'\t'*};   record=${record#*$'\t'}
            width=${record%%$'\t'*}; record=${record#*$'\t'}
            ramp=${record%%$'\t'*};  text=${record#*$'\t'}
            case "$ramp" in
                crucial) sgr=$crucial_sgr ;;
                exit)    sgr=$exit_sgr ;;
                *)       continue ;;
            esac
            (( ${#sgr} == 0 )) && continue      # the theme dropped this ramp since the draw
            ft_print_at_width "$row" "$col" "$sgr$text$FT_COLOR_RESET" "$width"
        done
    done
}
# Arm the pulse (idempotent — must NOT restart, or every repaint would reset the phase to 0
# and it would never move). Debounce = the typing delay that freezes it while you type.
# Suspended while an overlay is up (a dropdown must not be repainted over).
_ft_kcpulse_arm() {
    (( FT_OVERLAY_DEPTH > 0 )) && return 0
    [[ -n "${FT_ANIM_PHASE[__ft_kcpulse]:-}" ]] && return 0
    FT_TYPE[__ft_kcpulse]=__kcpulse
    ft_anim_start __ft_kcpulse 240 "$FT_KCPULSE_MS" 1 1     # len 240 (÷ common ramp lengths), loop
    ft_anim_bind  __ft_kcpulse _ft_kcpulse_frame pulse "${FT_KCPULSE_DEBOUNCE:-2000}"
}
_ft_kcpulse_disarm() { [[ -n "${FT_ANIM_PHASE[__ft_kcpulse]:-}" ]] && ft_anim_stop __ft_kcpulse; }

_ft_focus_set_try() {           # name → 0 if it was in the ring and got focus
    local name=$1 i
    for i in "${!FT_FOCUS_RING[@]}"; do
        [[ "${FT_FOCUS_RING[$i]}" == "$name" ]] || continue
        [[ "${FT_FOCUS_RING[$FT_FOCUS_INDEX]:-}" == "$name" ]] || _ft_focus_blur "${FT_FOCUS_RING[$FT_FOCUS_INDEX]:-}"
        _ft_focus_dirty "${FT_FOCUS_RING[$FT_FOCUS_INDEX]:-}"
        FT_FOCUS_INDEX=$i; FT_FOCUS=$name
        # Focus reveals: scroll any overflow container so the newly-focused control is visible
        # (the DOM does this for keyboard focus too) — BEFORE dirtying, so the repaint sees the
        # final position.
        declare -F ft_scroll_into_view >/dev/null 2>&1 && ft_scroll_into_view "$name"
        _ft_focus_dirty "$FT_FOCUS"
        _ft_focus_gain "$FT_FOCUS"
        return 0
    done
    return 1
}
# el.parentNode / el.children — thin accessors over the tree globals (DOM-shaped, so callers
# don't poke FT_PARENT/FT_KIDS directly). Each sets FT_RET and returns 0 iff non-empty.
ft_parent()   { FT_RET=${FT_PARENT[$1]:-}; [[ -n "$FT_RET" ]]; }        # → parent name
ft_children() { FT_RET=${FT_KIDS[$1]:-};   [[ -n "$FT_RET" ]]; }        # → space-sep child names
# el.blur() — drop focus from NAME if it currently holds it.
#
# Focus is TWO things: the global POINTER (which control has it) and that control's RUNG (how
# far into it you have stepped). Every path that MOVES focus does both — _ft_focus_blur runs
# the prototype's blur hook and drops the rung, then the caller reassigns the pointer. This entry
# point cleared the pointer only, on the since-outdated reasoning that FT_FOCUS being in the
# cascade cache key made :focus re-resolve by itself. It does not: :focus reads the RUNG. So a
# blurred control kept whatever rung it was on and went on matching :focus — and, if it had
# been stepped into, :engaged as well — while nothing held focus at all. Same teardown, both
# paths; the pointer is this function's only extra job.
#
# FT_FOCUS_INDEX is deliberately left where it is: the ring cursor is where Tab resumes from,
# and blurring should not silently send the next Tab back to the top of the form.
ft_blur() {
    [[ "${FT_FOCUS:-}" == "$1" ]] || return 0
    _ft_focus_blur "$1"
    FT_FOCUS=""
    ft_dirty "$1"
    return 0
}

# ── Container scrolling (overflow: auto|scroll) ───────────────────────────────
# A container whose children outgrow it slides a VIEWPORT over them: layout places children
# scrollTop rows up and publishes scrollHeight/clientHeight (see _ft_pass_arrange); the clip
# hides what's outside. These are the DOM's el.scrollTop / el.scrollIntoView():
# ft_scroll_set NAME TOP — clamped; shifts the subtree in place (NO relayout — the fast wheel
# path; a later full relayout reproduces the same state from the stored prop).
_ft_scroll_apply() {            # NAME newTop|"" newLeft|"" → 0 iff the position changed
    local name=$1 nt=$2 nl=$3 dY=0 dX=0
    if [[ -n "$nt" ]]; then
        ft_get "$name" scrollHeight; local sh=${FT_RET:-0}
        ft_get "$name" clientHeight; local ch=${FT_RET:-0}
        if [[ "$sh" =~ ^[0-9]+$ ]] && (( sh > 0 )); then
            local maxs=$(( sh - ch )); (( maxs < 0 )) && maxs=0
            [[ "$nt" =~ ^-?[0-9]+$ ]] || nt=0
            (( nt < 0 )) && nt=0; (( nt > maxs )) && nt=$maxs
            ft_get "$name" scrollTop; local oldT=${FT_RET:-0}
            if (( nt != oldT )); then dY=$(( oldT - nt )); _ft_setprop "$name" scrollTop "$nt"; fi
        fi
    fi
    if [[ -n "$nl" ]]; then
        ft_get "$name" scrollWidth; local sw=${FT_RET:-0}
        ft_get "$name" clientWidth; local cw=${FT_RET:-0}
        if [[ "$sw" =~ ^[0-9]+$ ]] && (( sw > 0 )); then
            local maxsl=$(( sw - cw )); (( maxsl < 0 )) && maxsl=0
            [[ "$nl" =~ ^-?[0-9]+$ ]] || nl=0
            (( nl < 0 )) && nl=0; (( nl > maxsl )) && nl=$maxsl
            ft_get "$name" scrollLeft; local oldL=${FT_RET:-0}
            if (( nl != oldL )); then dX=$(( oldL - nl )); _ft_setprop "$name" scrollLeft "$nl"; fi
        fi
    fi
    (( dY || dX )) || return 1
    local k kk                                                 # shift the subtree by the delta
    local -a stk=()
    for kk in ${FT_KIDS[$name]:-}; do stk+=("$kk"); done
    while (( ${#stk[@]} )); do
        k=${stk[-1]}; unset 'stk[-1]'
        [[ -n "${FT_ABSOLUTE_Y[$k]:-}" ]] && FT_ABSOLUTE_Y[$k]=$(( FT_ABSOLUTE_Y[$k] + dY ))
        [[ -n "${FT_ABSOLUTE_X[$k]:-}" ]] && FT_ABSOLUTE_X[$k]=$(( FT_ABSOLUTE_X[$k] + dX ))
        for kk in ${FT_KIDS[$k]:-}; do stk+=("$kk"); done
    done
    # The fast wheel path moves a whole subtree's absolute position and deliberately runs NO
    # layout, so nothing above bumped anything — and a clip rect is built out of exactly these
    # coordinates. It fires on plain focus movement too, via ft_scroll_into_view.
    _ft_clip_inval
    # Erase the viewport (transparent containers repaint nothing themselves — without this the
    # vacated cells keep stale glyphs), then repaint the subtree.
    _ft_inset4 "$name"
    _ft_effective_bg "$name"
    _ft_erase_rect $(( ${FT_ABSOLUTE_X[$name]:-0} + FT_INSET_LEFT )) $(( ${FT_ABSOLUTE_Y[$name]:-0} + FT_INSET_TOP )) \
                   $(( ${FT_MEASURED_WIDTH[$name]:-0} - FT_INSET_LEFT - FT_INSET_RIGHT )) $(( ${FT_MEASURED_HEIGHT[$name]:-0} - FT_INSET_TOP - FT_INSET_BOTTOM )) \
                   "$name" 2>/dev/null
    ft_dirty_subtree "$name"
    return 0
}
ft_scroll_set() { _ft_scroll_apply "$1" "$2" ""; }             # el.scrollTop = N
ft_scroll_to()  { _ft_scroll_apply "$1" "${3-}" "${2-}"; }     # el.scrollTo(x, y) — LEFT TOP
# ── Orthogonal leader routing (obstacle-avoiding connector lines) ─────────────
# ft_route R0 C0 R1 C1 [excludeName...] → FT_RET = waypoint polyline "r c r c …" (bends
# inclusive of both endpoints); returns 0 iff the route crosses NO obstacle, 1 when even the
# best candidate still crosses (the caller usually draws it anyway — least-bad).
# Obstacles are the VISIBLE leaf controls, a bordered CONTAINER's four border strips (its
# interior stays see-through — a line may cross a panel's empty area, never its drawn ring), and
# any rects in FT_ROUTE_EXTRA ("T L B R[;T L B R…]" — e.g. a callout's own box). Candidates:
# straight, both L shapes, and Z shapes with the middle leg swept across (and a little beyond)
# the span — scored by FT_ROUTE_PRICE in the leader judge's own currency, and "blocked" means INK
# crossed (FT_ROUTE_HARD), so a line over a ring alone is finished and no detour is hunted for
# it: two bends cost a reader more than two border cells. This is a channel-router
# style search, not Lee/A*: a handful of candidates × rect tests is ~1ms in bash, where a
# full grid flood would blow the frame budget.
FT_ROUTE_EXTRA=""
declare -a _RT_T=() _RT_L=() _RT_B=() _RT_R=()
# WHAT EACH OBSTACLE IS WORTH. Carried alongside the rects because "may I cover this?" is not a
# question about area — a cell of a button and a cell of a paragraph are not the same loss. Every
# decision that used to count CELLS now counts cells x importance, which is what lets one weight
# replace a pile of special cases ("never the keylegend", "never the statusbar", "never a border").
declare -a _RT_I=()
# …and WHICH CONTROL each rect came from. The router does not care, but anything that wants to ask
# what is actually inside a rect — a border ring, a textfield's unfilled tail — cannot do it from
# four numbers. Empty for published ink with no control behind it (FT_ROUTE_EXTRA).
declare -a _RT_N=()
# …and WHAT CROSSING EACH RECT COSTS, in hundredths of a crossing. A leader over a control's cell
# is a full crossing (100); over a container's border ring it is a decoration's worth — the user's
# ruling is that a line may break a border but never text, and with rings in the list at all
# (see _ft_route_obstacles) a uniform price made four cells along a frame's `═` lose to two
# cells through a button's label.
declare -a _RT_CROSS=()
# THE LIST IS SEVEN ARRAYS IN LOCKSTEP, so it is only ever grown and shrunk through these. Every
# hand-rolled `_RT_T+=(…); _RT_I+=(…)` used to leave _RT_N one short, re-pointing every later
# name at the wrong rect. (The bulk copy in _ft_beacon_leader_once stays inline on purpose: it
# runs per judged candidate, and a call per rect there is measurable.)
_ft_obstacles_clear() { _RT_T=(); _RT_L=(); _RT_B=(); _RT_R=(); _RT_I=(); _RT_N=(); _RT_CROSS=(); }
_ft_obstacle_push() {           # t l b r worth name [crossing-hundredths=100]
    _RT_T+=("$1"); _RT_L+=("$2"); _RT_B+=("$3"); _RT_R+=("$4")
    _RT_I+=("$5"); _RT_N+=("$6"); _RT_CROSS+=("${7:-100}")
}
_ft_obstacle_pop() { unset '_RT_T[-1]' '_RT_L[-1]' '_RT_B[-1]' '_RT_R[-1]' '_RT_I[-1]' '_RT_N[-1]' '_RT_CROSS[-1]'; }
_ft_route_obstacles() {         # exclude... — fill _RT_* from the live tree + FT_ROUTE_EXTRA
    _ft_obstacles_clear
    local n t skip ex container w h top left bottom right worth
    for n in "${!FT_TYPE[@]}"; do
        t=${FT_TYPE[$n]}
        [[ -n "$t" ]] || continue                     # empty type ⇒ empty subscript is an ERROR
        # Containers and overlays are see-through for routing: a line may cross a panel's empty
        # area, but never a real control's box. (Keyed on the TYPE, not on FT_PROTO_DRAW, which
        # is only populated once a control of that type has been constructed — lazy prototype init.)
        case $t in
            empty|beacon)            continue ;;
            form|frame|div|tabs|box) container=1 ;;
            *)                       container=0 ;;
        esac
        skip=0; for ex in "$@"; do [[ "$n" == "$ex" ]] && { skip=1; break; }; done
        (( skip )) && continue
        [[ -n "${FT_ABSOLUTE_X[$n]:-}" ]] || continue
        w=${FT_MEASURED_WIDTH[$n]:-0}; h=${FT_MEASURED_HEIGHT[$n]:-0}
        (( w > 0 && h > 0 )) || continue
        _ft_disp "$n"; [[ "$FT_RET" == none ]] && continue
        top=${FT_ABSOLUTE_Y[$n]}; left=${FT_ABSOLUTE_X[$n]}
        bottom=$(( top + h - 1 )); right=$(( left + w - 1 ))
        _ft_control_importance "$n"; worth=$FT_RET    # captured: _ft_border below also sets FT_RET
        if (( container )); then
            # …BUT A CONTAINER'S RING IS INK. A bordered frame's interior is free space; its
            # border is a drawn ring, and a callout parked across it — or a leader through it —
            # breaks that ring exactly as it would a checkbox's box. Before this, the ring was
            # nowhere: not an obstacle (the whole container was skipped) and not a tier (tiers
            # decompose the obstacle list), so covering or crossing it cost NOTHING, and the
            # only thing keeping callouts off the page frame was caging them inside it (the old
            # boundBox default). The four strips are the ring and nothing else: the interior
            # stays see-through, and the container's tier hook prices them as decoration.
            _ft_border "$n"; (( FT_RET )) || continue
            (( w >= 3 && h >= 3 )) || continue        # no interior ⇒ no ring to speak of
            _ft_obstacle_push "$top"          "$left"  "$top"          "$right" "$worth" "$n" "$FT_TIER_DECORATION"
            _ft_obstacle_push "$bottom"       "$left"  "$bottom"       "$right" "$worth" "$n" "$FT_TIER_DECORATION"
            _ft_obstacle_push $(( top + 1 ))  "$left"  $(( bottom - 1 )) "$left"  "$worth" "$n" "$FT_TIER_DECORATION"
            _ft_obstacle_push $(( top + 1 ))  "$right" $(( bottom - 1 )) "$right" "$worth" "$n" "$FT_TIER_DECORATION"
            continue
        fi
        _ft_obstacle_push "$top" "$left" "$bottom" "$right" "$worth" "$n"
    done
    if [[ -n "$FT_ROUTE_EXTRA" ]]; then
        local rect
        while IFS= read -r -d ';' rect; do
            [[ -z "$rect" ]] && continue
            set -- $rect
            # published ink with no control behind it — so nothing to look inside (no name)
            _ft_obstacle_push "$1" "$2" "$3" "$4" "$FT_IMPORTANCE_NORMAL" ""
        done <<< "${FT_ROUTE_EXTRA};"
    fi
}
# ── Tier rects: a control decomposed into what it is WORTH, region by region ────────────────────
# An obstacle rect says a control is there. It does not say that the middle of a button is its
# label and the two cells either side are padding, or that a field's box is a decorative ring with
# a mostly-empty well inside. Anything placing something ON TOP of the UI — a callout, a popup, a
# drag ghost — needs that difference: docs/placement-cost-model.md ranks the tiers, and the user's
# own summary is "the decorative border, and the empty text areas, are exactly where we want to be
# … the gravest sin is intersecting with text content INSIDE controls".
#
# THE CONTROL DECLARES ITS OWN TIERS, via `_ft_tiers_<type> name t l b r`, exactly like
# `_ft_height_<type>`. It has to: the first cut of this asked `_ft_border`, which is the `border`
# PROPERTY — and a textfield's box is intrinsic ("every text field is fully BOXED"), so it answered
# 0 for a control that visibly draws a ring, and the decomposition silently did nothing at all.
# Any predicate the placement engine could ask from outside would have that same shape, and would
# grow one `case` arm per control type in the wrong file.
#
# A hook MUST partition its rect exactly — every cell claimed once, none invented — or burial stops
# meaning area. `tests/test-beacon.bash` proves that over the live tree rather than trusting it.
# Overridable so the tiers can be A/B'd against flat rects WITHOUT a code change: the hooks
# partition exactly, so setting every tier to 100 reproduces the old uniform pricing cell for cell.
: "${FT_TIER_CONTENT:=100}"     # text, and any control that declares nothing — full importance
: "${FT_TIER_DECORATION:=45}"   # a drawn border ring: asked for explicitly as a good place to be
: "${FT_TIER_EMPTY_TEXT:=15}"   # past the end of the string in a field's well
declare -a FT_TIER_TOP=() FT_TIER_LEFT=() FT_TIER_BOTTOM=() FT_TIER_RIGHT=() FT_TIER_WEIGHT=()
declare -i FT_TIER_COUNT=0
declare -i _FT_TIER_IMP=0       # importance of the control currently being decomposed
ft_tier_add() {                 # t l b r tier% — emit one weighted region of the current control
    (( $3 < $1 || $4 < $2 )) && return 0        # a hook may compute an empty slice; drop it
    local w=$(( _FT_TIER_IMP * $5 / 100 ))
    (( w < 1 && _FT_TIER_IMP > 0 )) && w=1      # cheap is not free — see the divide in the caller
    FT_TIER_TOP+=("$1"); FT_TIER_LEFT+=("$2"); FT_TIER_BOTTOM+=("$3"); FT_TIER_RIGHT+=("$4")
    FT_TIER_WEIGHT+=("$w"); (( FT_TIER_COUNT++ ))
}
ft_tier_rects() {               # _RT_* → FT_TIER_*, one control ⇒ one or several weighted rects
    FT_TIER_TOP=(); FT_TIER_LEFT=(); FT_TIER_BOTTOM=(); FT_TIER_RIGHT=(); FT_TIER_WEIGHT=()
    FT_TIER_COUNT=0
    local j n hook
    local nr=${#_RT_T[@]}
    for (( j = 0; j < nr; j++ )); do
        n=${_RT_N[j]:-}
        _FT_TIER_IMP=${_RT_I[j]:-$FT_IMPORTANCE_NORMAL}
        hook=""
        [[ -n "$n" ]] && hook="_ft_tiers_${FT_TYPE[$n]}"
        if [[ -n "$hook" ]] && declare -F "$hook" >/dev/null; then
            "$hook" "$n" "${_RT_T[j]}" "${_RT_L[j]}" "${_RT_B[j]}" "${_RT_R[j]}"
        else
            ft_tier_add "${_RT_T[j]}" "${_RT_L[j]}" "${_RT_B[j]}" "${_RT_R[j]}" "$FT_TIER_CONTENT"
        fi
    done
    # SORTED BY TOP ROW, ONCE, SO THE BURIAL SCAN CAN STOP EARLY.
    #
    # `_ft_beacon_overlap` walks this list for every candidate box a placement considers, and that
    # walk IS the placement: measured on the demo's heaviest page, 403 calls at 500us each, of
    # which 460us is this loop — 13us per rect tested, 36 rects, most of them nowhere near the
    # box. Sorted by top row, the scan can break the moment a rect starts below the box's bottom
    # edge instead of testing the whole tail. The sort is an insertion sort over ~36 items ONCE
    # per placement (the list is rebuilt per placement anyway); the scan it feeds runs hundreds of
    # times. Exact, not approximate: the same rects overlap, so the same sum comes out.
    local _si _sj _st _sl _sb _sr _sw
    for (( _si = 1; _si < FT_TIER_COUNT; _si++ )); do
        _st=${FT_TIER_TOP[_si]}; _sl=${FT_TIER_LEFT[_si]}; _sb=${FT_TIER_BOTTOM[_si]}
        _sr=${FT_TIER_RIGHT[_si]}; _sw=${FT_TIER_WEIGHT[_si]}
        for (( _sj = _si - 1; _sj >= 0 && FT_TIER_TOP[_sj] > _st; _sj-- )); do
            FT_TIER_TOP[_sj+1]=${FT_TIER_TOP[_sj]};       FT_TIER_LEFT[_sj+1]=${FT_TIER_LEFT[_sj]}
            FT_TIER_BOTTOM[_sj+1]=${FT_TIER_BOTTOM[_sj]}; FT_TIER_RIGHT[_sj+1]=${FT_TIER_RIGHT[_sj]}
            FT_TIER_WEIGHT[_sj+1]=${FT_TIER_WEIGHT[_sj]}
        done
        FT_TIER_TOP[_sj+1]=$_st; FT_TIER_LEFT[_sj+1]=$_sl; FT_TIER_BOTTOM[_sj+1]=$_sb
        FT_TIER_RIGHT[_sj+1]=$_sr; FT_TIER_WEIGHT[_sj+1]=$_sw
    done
}
# A ring plus its interior, for any control whose box is drawn on all four sides. Below three rows
# or columns there is no interior to speak of and the whole thing is content — splitting a two-row
# control would claim its only text row is decoration.
ft_tier_ring() {                # t l b r → FT_RET=1 if a ring was emitted (interior in FT_TIER_IN_*)
    local t=$1 l=$2 b=$3 r=$4
    FT_TIER_IN_T=$t; FT_TIER_IN_L=$l; FT_TIER_IN_B=$b; FT_TIER_IN_R=$r; FT_RET=0
    (( b - t >= 2 && r - l >= 2 )) || return 0
    ft_tier_add "$t"         "$l" "$t"         "$r" "$FT_TIER_DECORATION"
    ft_tier_add "$b"         "$l" "$b"         "$r" "$FT_TIER_DECORATION"
    ft_tier_add $(( t + 1 )) "$l" $(( b - 1 )) "$l" "$FT_TIER_DECORATION"
    ft_tier_add $(( t + 1 )) "$r" $(( b - 1 )) "$r" "$FT_TIER_DECORATION"
    FT_TIER_IN_T=$(( t + 1 )); FT_TIER_IN_L=$(( l + 1 ))
    FT_TIER_IN_B=$(( b - 1 )); FT_TIER_IN_R=$(( r - 1 ))
    FT_RET=1
}
# A bordered container reaches the obstacle list as its four ring strips and nothing else (see
# _ft_route_obstacles), so every rect a container hook is handed IS ring: decoration, whole.
# (Not dearer than a control's ring: a placer never straddles its HOME frame — it searches that
# frame's interior, see _ft_beacon_paint_callout — and an inner bordered pane's edge is as good
# a place to sit as a field's box. Priced at twenty times content it pushed css-demo page 1 at
# 80×30 off the code panes' top border and onto a worse spot.)
_ft_tiers_ring_strip() { ft_tier_add "$2" "$3" "$4" "$5" "$FT_TIER_DECORATION"; }
_ft_tiers_form()  { _ft_tiers_ring_strip "$@"; }
_ft_tiers_frame() { _ft_tiers_ring_strip "$@"; }
_ft_tiers_div()   { _ft_tiers_ring_strip "$@"; }
_ft_tiers_tabs()  { _ft_tiers_ring_strip "$@"; }
_ft_tiers_box()   { _ft_tiers_ring_strip "$@"; }
# HOT: called once per candidate route, and a blocked route tries many. `for j in "${!_RT_T[@]}"`
# rebuilds a word list of every index on each of those calls — a numeric loop over a hoisted count
# does the same walk without that. This is the innermost loop of the whole placement search.
#
# CROSSINGS ARE PRICED BY WHAT THEY CROSS — but only because the list finally holds something
# worth telling apart. The first attempt at this (decompose every obstacle into tier rects, carry
# a weighted crossing figure through FT_POLY_PRICE and FT_LEADER_SCORE) was built end to end, changed NOTHING
# across 129 placements at three sizes, and cost 63% of the placement's latency — because over 43
# real placements at 62×40, 28 leaders crossed nothing at all and the other 15 crossed 34 cells
# between them, of which only 17% was discountable. It was reverted, and the lesson recorded here
# was: the thing to change is not this function but the fact that leaders cross so little.
#
# What changed that is the RING (2026-08-22). A bordered container contributes its four border
# strips (`_ft_route_obstacles`), so the list now contains cells a leader genuinely may break —
# and one uniform price made four cells along a frame's `═` lose to two through a button's label.
# `_RT_CROSS` is per-rect, in hundredths of a crossing: 100 for a control, FT_TIER_DECORATION for
# a ring. One multiply in the loop, no extra rects, and the tier decomposition stays out of it.
# THREE NUMBERS FROM ONE PASS:
#   FT_RET         = crossings*10000 + bends*8 + length — the historical score. "crossings" is
#                    crossed cells weighted by each rect's _RT_CROSS (a control cell 1, a ring
#                    cell FT_TIER_DECORATION/100), so FT_RET/10000 reads as whole crossing-
#                    equivalents for the callers that floor it.
#   FT_ROUTE_CROSS = that weighted count in hundredths, for the price that must not floor it.
#   FT_ROUTE_HARD  = cells of INK crossed (controls, published boxes) — what "blocked" means.
#   FT_ROUTE_PRICE = what ft_route COMPARES candidates by, in the judge's currency: ink
#                    crossings stay dominant (a clear path beats a line through a button), but a
#                    ring cell costs what the judge charges for it and a bend costs what the
#                    judge charges for a turn. The old comparison was FT_RET itself — crossings
#                    10 000 : bends 8 — so the router dodged three cells of a frame's `═` (4 050
#                    to the judge) with two extra bends (12 000 to the judge), and the judge then
#                    threw that line away for one through two buttons. The router is the leader's
#                    prefilter, and a prefilter must price what the judge prices.
: "${FT_ROUTE_CROSS_COST:=3000}"    # per ring cell ×1/100; _CROSS_COST in ft-beacon is the same 3000
: "${FT_ROUTE_TURN_COST:=3000}"     # per bend; _TURN_COST in ft-beacon is the same 3000
FT_ROUTE_CROSS=0; FT_ROUTE_HARD=0; FT_ROUTE_PRICE=0
_ft_route_score() {             # "r c r c …" → FT_RET, FT_ROUTE_CROSS, FT_ROUTE_HARD, FT_ROUTE_PRICE
    local -a wp=($1)
    local nw=${#wp[@]} nr=${#_RT_T[@]} cross=0 hard=0 len=0 i r0 c0 r1 c1 j lo hi ov
    # EVERY CELL ONCE. A bend cell is the end of one segment and the start of the next; scoring
    # both endpoints of every segment charged it twice, so a corner sitting on an obstacle cost
    # double (a leader bending on a frame's `═` paid 1 350 more than the line it was compared
    # with). Segments after the first are half-open: their start cell belongs to the one before.
    for (( i=0; i+3<nw; i+=2 )); do
        r0=${wp[i]}; c0=${wp[i+1]}; r1=${wp[i+2]}; c1=${wp[i+3]}
        if (( r0 == r1 )); then                       # horizontal segment
            lo=$(( c0<c1?c0:c1 )); hi=$(( c0<c1?c1:c0 )); len=$(( len + hi - lo ))
            (( i > 0 )) && { if (( c1 > c0 )); then (( lo++ )); else (( hi-- )); fi; (( hi < lo )) && continue; }
            for (( j=0; j<nr; j++ )); do
                (( _RT_T[j] <= r0 && r0 <= _RT_B[j] )) || continue
                ov=$(( (hi < _RT_R[j] ? hi : _RT_R[j]) - (lo > _RT_L[j] ? lo : _RT_L[j]) + 1 ))
                (( ov > 0 )) && { cross=$(( cross + ov * _RT_CROSS[j] )); (( _RT_CROSS[j] == 100 )) && hard=$(( hard + ov )); }
            done
        else                                          # vertical segment
            lo=$(( r0<r1?r0:r1 )); hi=$(( r0<r1?r1:r0 )); len=$(( len + hi - lo ))
            (( i > 0 )) && { if (( r1 > r0 )); then (( lo++ )); else (( hi-- )); fi; (( hi < lo )) && continue; }
            for (( j=0; j<nr; j++ )); do
                (( _RT_L[j] <= c0 && c0 <= _RT_R[j] )) || continue
                ov=$(( (hi < _RT_B[j] ? hi : _RT_B[j]) - (lo > _RT_T[j] ? lo : _RT_T[j]) + 1 ))
                (( ov > 0 )) && { cross=$(( cross + ov * _RT_CROSS[j] )); (( _RT_CROSS[j] == 100 )) && hard=$(( hard + ov )); }
            done
        fi
    done
    FT_ROUTE_CROSS=$cross; FT_ROUTE_HARD=$hard
    FT_ROUTE_PRICE=$(( hard*10000 + (cross - hard*100) * FT_ROUTE_CROSS_COST / 100 + (nw/2 - 2) * FT_ROUTE_TURN_COST + len ))
    FT_RET=$(( cross*100 + (nw/2 - 2)*8 + len ))
}
# Set FT_ROUTE_PREBUILT=1 to route against the _RT_* rects the CALLER already built, instead of
# rebuilding them from the whole tree. Rebuilding walks every control (~2ms), which is nothing for
# one connector and ruinous for a placement search that routes tens of candidates — that walk was
# what made "score the line you will actually draw" look unaffordable. The caller owns the list
# while the flag is set, including pushing and popping its own per-candidate rects.
FT_ROUTE_PREBUILT=""
# How many Z detours to try before settling for the least-bad one found. Only reached when the
# straight and L routes are all blocked; bounds a genuinely walled-in target.
: "${FT_ROUTE_MAX_SCAN:=120}"
ft_route() {                    # R0 C0 R1 C1 [exclude...] → FT_RET polyline; 0 iff crossing-free
    local r0=$1 c0=$2 r1=$3 c1=$4; shift 4
    [[ -n "$FT_ROUTE_PREBUILT" ]] || _ft_route_obstacles "$@"
    local best="" bestscore=999999999 cand score
    local -a cands=()
    # Candidates are generated in order of INTRINSIC niceness (straight ≺ one bend ≺ two bends)
    # and we stop at the first crossing-free one. For the straight/L candidates that IS the
    # optimum (crossings dominate the score); among the Z detours it is the first clean one
    # rather than the strictly shortest — a few cells of length traded for not scoring dozens of
    # candidates every paint. The common case (nothing in the way) costs ONE scoring pass.
    (( r0 == r1 || c0 == c1 )) && cands+=("$r0 $c0 $r1 $c1")          # straight
    if (( r0 != r1 && c0 != c1 )); then
        cands+=("$r0 $c0 $r0 $c1 $r1 $c1")            # L: H then V
        cands+=("$r0 $c0 $r1 $c0 $r1 $c1")            # L: V then H
    fi
    # Compared by FT_ROUTE_PRICE (see _ft_route_score); "blocked" means the best so far crosses
    # INK — a route over a ring alone is not blocked, and no detour is hunted for it.
    local besthard=0
    for cand in "${cands[@]}"; do
        _ft_route_score "$cand"; score=$FT_ROUTE_PRICE
        (( score < bestscore )) && { bestscore=$score; best=$cand; besthard=$FT_ROUTE_HARD; }
    done
    # GENERATE THE Z DETOURS ONLY IF A SIMPLE ROUTE IS ACTUALLY BLOCKED, AND ONE AT A TIME.
    #
    # These used to be built up front — every row and every column of the screen, ~200 candidate
    # strings — and only then scored with an early exit. So the header's claim that "the common
    # case costs ONE scoring pass" was false: the scan exited after one score, but the BUILD had
    # already run in full. Measured at 106ms per call, which is what made judging a placement on
    # its real leader look unaffordable; it is ~1ms once the work follows the early exit.
    if (( besthard > 0 )); then
        local -a cols=() rows=()
        local clo chi rlo rhi d m
        clo=$(( c0<c1?c0:c1 )); chi=$(( c0<c1?c1:c0 ))
        rlo=$(( r0<r1?r0:r1 )); rhi=$(( r0<r1?r1:r0 ))
        # ONLY AS MANY AS THE SCAN WILL CONSUME. The sweep scores at most FT_ROUTE_MAX_SCAN
        # candidates, so building a corridor list the width and height of the whole screen —
        # ~216 array appends — was work thrown away on every blocked route, and blocked routes
        # are the common case inside a busy page. Nearest-first ordering is unchanged; this just
        # stops generating past the point the scan can reach.
        local _gen=$(( FT_ROUTE_MAX_SCAN + 2 ))
        for (( m=clo+1; m<chi && ${#cols[@]}<_gen; m++ )); do cols+=("$m"); done   # inside the span first
        for (( d=0; d<FT_COLS && ${#cols[@]}<_gen; d++ )); do                      # then outward both sides
            m=$(( clo-1-d )); (( m >= 0 ))        && cols+=("$m")
            m=$(( chi+1+d )); (( m < FT_COLS ))   && cols+=("$m")
            (( clo-1-d < 0 && chi+1+d >= FT_COLS )) && break
        done
        for (( m=rlo+1; m<rhi && ${#rows[@]}<_gen; m++ )); do rows+=("$m"); done
        for (( d=0; d<FT_ROWS && ${#rows[@]}<_gen; d++ )); do
            m=$(( rlo-1-d )); (( m >= 0 ))        && rows+=("$m")
            m=$(( rhi+1+d )); (( m < FT_ROWS ))   && rows+=("$m")
            (( rlo-1-d < 0 && rhi+1+d >= FT_ROWS )) && break
        done
        local ci=0 ri=0 nc=${#cols[@]} nr=${#rows[@]} scanned=0
        # A DEGENERATE FAMILY IS NOT A CANDIDATE. With the endpoints in one column, every "rows"
        # Z (vertical at c0, across, vertical at c1) IS the straight line again — and the
        # interleave fed those into the scan budget one-for-one with the real detours, so a
        # leader whose only clean column lay nine steps out needed eighteen scans to find it
        # and never did (the line through "Nine po|nts"). Same for one row and the "cols" family.
        (( c0 == c1 )) && nr=0
        (( r0 == r1 )) && nc=0
        while (( ci < nc || ri < nr )); do                            # interleave the two families
            if (( ri < nr )); then
                m=${rows[ri]}; (( ri++ ))
                if (( m != r0 && m != r1 )); then
                    cand="$r0 $c0 $m $c0 $m $c1 $r1 $c1"
                    _ft_route_score "$cand"; score=$FT_ROUTE_PRICE
                    (( score < bestscore )) && { bestscore=$score; best=$cand; besthard=$FT_ROUTE_HARD; }
                    (( besthard == 0 )) && break
                    (( ++scanned > FT_ROUTE_MAX_SCAN )) && break
                fi
            fi
            if (( ci < nc )); then
                m=${cols[ci]}; (( ci++ ))
                if (( m != c0 && m != c1 )); then
                    cand="$r0 $c0 $r0 $m $r1 $m $r1 $c1"
                    _ft_route_score "$cand"; score=$FT_ROUTE_PRICE
                    (( score < bestscore )) && { bestscore=$score; best=$cand; besthard=$FT_ROUTE_HARD; }
                    (( besthard == 0 )) && break
                    (( ++scanned > FT_ROUTE_MAX_SCAN )) && break
                fi
            fi
        done
    fi
    FT_RET=$best
    (( besthard == 0 ))                                # 0 iff the line crosses no ink
}
# ── Free space, as an allocator sees it ──────────────────────────────────────
# ft_free_regions T L B R → FT_FREE_T/L/B/R = the MAXIMAL EMPTY RECTANGLES inside those bounds.
#
# The placer used to reason only about the four sides of its target and score whatever it landed
# on. That is backwards: what a floating box actually needs to know is WHERE THERE IS ROOM, the
# same question an allocator answers about a heap. Given that list it can ask "does this box fit
# in a free region outright?" and, when one does, land somewhere that covers nothing at all —
# instead of picking the least-awful overlap out of a fixed set of guesses.
#
# Obstacles are the _RT_* rects (built once by _ft_route_obstacles), so "free" means the same
# thing here as it does to the connector router: no real leaf control and no drawn border ring,
# a container's interior see-through.
#
# Method: cut the bounds into horizontal BANDS at every obstacle edge — inside a band the free
# column runs are constant. Then, from each band, extend downward intersecting the runs; every
# run that survives to a given depth is an empty rectangle, and keeping the deepest one per
# (top, left, right) leaves the maximal ones. Bands and runs are both small (an obstacle list of
# ~20 gives ~40 bands and ~4 runs), so this is a few thousand integer ops, and it runs on the
# CACHED placement path — a step or page change, never a frame.
declare -a FT_FREE_T=() FT_FREE_L=() FT_FREE_B=() FT_FREE_R=()
declare -a _BF_LO=() _BF_HI=()
_ft_free_band() {               # y0 y1 L R → _BF_LO/_BF_HI = the free column runs across the band
    local y0=$1 y1=$2 bl=$3 br=$4 j k n=0 a b nr=${#_RT_T[@]}
    local -a sl=() sr=()
    for (( j=0; j<nr; j++ )); do
        (( _RT_T[j] <= y0 && _RT_B[j] >= y1 )) || continue     # bands split at edges: covers all or none
        (( _RT_R[j] < bl || _RT_L[j] > br )) && continue
        a=$(( _RT_L[j] < bl ? bl : _RT_L[j] )); b=$(( _RT_R[j] > br ? br : _RT_R[j] ))
        k=$n                                                   # insertion sort by left edge (few items)
        while (( k > 0 )) && (( sl[k-1] > a )); do sl[k]=${sl[k-1]}; sr[k]=${sr[k-1]}; (( k-- )); done
        sl[k]=$a; sr[k]=$b; (( n++ ))
    done
    _BF_LO=(); _BF_HI=()
    local cur=$bl
    for (( k=0; k<n; k++ )); do
        (( sl[k] > cur )) && { _BF_LO+=("$cur"); _BF_HI+=($(( sl[k]-1 ))); }
        (( sr[k] >= cur )) && cur=$(( sr[k]+1 ))
    done
    (( cur <= br )) && { _BF_LO+=("$cur"); _BF_HI+=("$br"); }
}
# MINW/MINH: a caller looking for somewhere to put a box of a known size has no use for regions
# smaller than it, and saying so up front is what keeps this cheap — the enumeration is O(bands²)
# and most of those pairings die on the first size test instead of being built and returned.
ft_free_regions() {             # T L B R [minW minH] → FT_FREE_*  (_RT_* must already be built)
    local bt=$1 bl=$2 bb=$3 br=$4 minw=${5:-1} minh=${6:-1}
    FT_FREE_T=(); FT_FREE_L=(); FT_FREE_B=(); FT_FREE_R=()
    (( bt > bb || bl > br )) && return 0
    local -a cuts=(); local n=0 j v i
    for v in "$bt" $(( bb+1 )); do
        i=$n; while (( i > 0 )) && (( cuts[i-1] > v )); do cuts[i]=${cuts[i-1]}; (( i-- )); done
        cuts[i]=$v; (( n++ ))
    done
    for j in "${!_RT_T[@]}"; do
        (( _RT_B[j] < bt || _RT_T[j] > bb )) && continue
        for v in "${_RT_T[j]}" $(( _RT_B[j]+1 )); do
            (( v < bt || v > bb+1 )) && continue
            for (( i=0; i<n; i++ )); do (( cuts[i] == v )) && break; done
            (( i < n )) && continue                            # already a cut
            i=$n; while (( i > 0 )) && (( cuts[i-1] > v )); do cuts[i]=${cuts[i-1]}; (( i-- )); done
            cuts[i]=$v; (( n++ ))
        done
    done
    # Each band's free runs are a property of the band, so compute them ONCE. They were being
    # recomputed inside the extend-downward loop — the same band re-scanned for every band above
    # it, which is O(bands²) rect walks and measured 39ms on a real page instead of a few.
    local -a bandlo=() bandhi=()
    for (( i=0; i<n-1; i++ )); do
        _ft_free_band "${cuts[i]}" $(( cuts[i+1]-1 )) "$bl" "$br"
        bandlo[i]="${_BF_LO[*]}"; bandhi[i]="${_BF_HI[*]}"
    done
    local -A deepest=()
    local -a curlo=() curhi=() nlo=() nhi=() blo=() bhi=()
    local a b lo hi m
    for (( i=0; i<n-1; i++ )); do
        (( bb - cuts[i] + 1 < minh )) && break            # nothing below can be tall enough
        curlo=( ${bandlo[i]} ); curhi=( ${bandhi[i]} )
        (( ${#curlo[@]} == 0 )) && continue
        for (( j=i; j<n-1; j++ )); do
            if (( j > i )); then
                blo=( ${bandlo[j]} ); bhi=( ${bandhi[j]} )
                nlo=(); nhi=(); a=0; b=0
                while (( a < ${#curlo[@]} && b < ${#blo[@]} )); do
                    lo=$(( curlo[a] > blo[b] ? curlo[a] : blo[b] ))
                    hi=$(( curhi[a] < bhi[b] ? curhi[a] : bhi[b] ))
                    (( lo <= hi )) && { nlo+=("$lo"); nhi+=("$hi"); }
                    if (( curhi[a] < bhi[b] )); then (( a++ )); else (( b++ )); fi
                done
                curlo=("${nlo[@]}"); curhi=("${nhi[@]}")
                (( ${#curlo[@]} == 0 )) && break
            fi
            (( cuts[j+1] - cuts[i] < minh )) && continue   # not tall enough YET; keep extending
            for (( m=0; m<${#curlo[@]}; m++ )); do
                (( curhi[m] - curlo[m] + 1 >= minw )) || continue
                deepest["${cuts[i]} ${curlo[m]} ${curhi[m]}"]=$(( cuts[j+1]-1 ))
            done
        done
    done
    local key
    for key in "${!deepest[@]}"; do
        set -- $key
        FT_FREE_T+=("$1"); FT_FREE_L+=("$2"); FT_FREE_R+=("$3"); FT_FREE_B+=("${deepest[$key]}")
    done
    return 0
}

# ft_route_simplify POLY → FT_RET — drop every waypoint that is not a bend.
#
# A point collinear with its neighbours is one of two things, and neither should be a waypoint:
# either it lies BETWEEN them, in which case it says nothing the segment does not already say,
# or it lies OUTSIDE them, in which case the line runs out to it and comes back — a whisker
# sticking past the junction, drawn over itself.
#
# The outside case is not hypothetical. A caller that routes to an APPROACH cell offset back
# along an arrowhead's axis (so the final leg is parallel to the head) gets one whenever the
# route reaches that axis on the far side of the approach: the line overshoots the head, then
# doubles back into it. Measured across the css-demo's callouts at four screen widths, 22 of
# 104 leaders drew one. Turn-counting cannot see them — a reversal is not a change of axis —
# which is why they survived a green suite.
#
# Shortening can never introduce a crossing: what is removed is collinear with what remains, so
# the simplified line lies wholly within the original's footprint.
ft_route_simplify() {           # "r c r c …" → FT_RET simplified polyline
    local -a p=($1) out=()
    local n=${#p[@]} i ar ac br bc cr cc
    (( n < 6 )) && { FT_RET=$1; return 0; }
    out=("${p[0]}" "${p[1]}")
    for (( i=2; i+3 < n; i+=2 )); do
        ar=${out[-2]}; ac=${out[-1]}            # compare against what was actually KEPT
        br=${p[i]};   bc=${p[i+1]}
        cr=${p[i+2]}; cc=${p[i+3]}
        (( ar == br && ac == bc )) && continue  # same cell twice   → not a point at all
        (( ar == br && br == cr )) && continue  # all on one row    → B is not a bend
        (( ac == bc && bc == cc )) && continue  # all in one column → B is not a bend
        out+=("$br" "$bc")
    done
    # A REPEATED ENDPOINT IS NOT A SEGMENT. When a caller's final waypoint lands exactly on the
    # cell it then appends (an arrowhead whose approach offset shrank onto the head itself), the
    # polyline ends in a zero-length hop — and anything reading "the direction of the last leg"
    # then reads the leg BEFORE it, reporting a horizontal arrival at a vertical arrowhead.
    (( out[-2] == p[n-2] && out[-1] == p[n-1] )) || out+=("${p[n-2]}" "${p[n-1]}")
    FT_RET="${out[*]}"
}
ft_route_draw() {               # "r c r c …" SGR — draw the polyline with corner glyphs
    local -a wp=($1)
    local sgr=$2 nw=${#wp[@]}
    local hz=$'─' vt=$'│' c_es=$'╭' c_ws=$'╮' c_en=$'╰' c_wn=$'╯'
    (( FT_USE_UTF8 )) || { hz=-; vt='|'; c_es=+; c_ws=+; c_en=+; c_wn=+; }
    local i r0 c0 r1 c1 r c lo hi
    for (( i=0; i+3<nw; i+=2 )); do
        r0=${wp[i]}; c0=${wp[i+1]}; r1=${wp[i+2]}; c1=${wp[i+3]}
        if (( r0 == r1 )); then
            lo=$(( c0<c1?c0:c1 )); hi=$(( c0<c1?c1:c0 ))
            for (( c=lo; c<=hi; c++ )); do ft_print_at "$r0" "$c" "${sgr}${hz}${FT_COLOR_RESET}"; done
        else
            lo=$(( r0<r1?r0:r1 )); hi=$(( r0<r1?r1:r0 ))
            for (( r=lo; r<=hi; r++ )); do ft_print_at "$r" "$c0" "${sgr}${vt}${FT_COLOR_RESET}"; done
        fi
    done
    # corner glyphs at each bend: pick by the two directions the corner must open toward
    for (( i=2; i+1<nw-2; i+=2 )); do
        local br=${wp[i]} bc=${wp[i+1]} pr=${wp[i-2]} pc=${wp[i-1]} xr=${wp[i+2]} xc=${wp[i+3]}
        local openh="" openv=""
        (( pc < bc || xc < bc )) && openh=W; (( pc > bc || xc > bc )) && openh=E
        (( pr < br || xr < br )) && openv=N; (( pr > br || xr > br )) && openv=S
        # A COLLINEAR WAYPOINT IS NOT A BEND. Every interior point was being given a corner
        # glyph, and one whose neighbours lie on its own axis matches none of the four cases —
        # so it fell through to the `─` default and stamped a horizontal bar into the middle of
        # a vertical run. The segment pass already drew the right glyph there; leave it alone.
        # (Callers routinely produce these: a route ending at a waypoint that is in line with
        # the leg appended after it, which is exactly what an arrowhead approach cell is.)
        [[ -n "$openh" && -n "$openv" ]] || continue
        local g=$hz
        [[ "$openh" == E && "$openv" == S ]] && g=$c_es
        [[ "$openh" == W && "$openv" == S ]] && g=$c_ws
        [[ "$openh" == E && "$openv" == N ]] && g=$c_en
        [[ "$openh" == W && "$openv" == N ]] && g=$c_wn
        ft_print_at "$br" "$bc" "${sgr}${g}${FT_COLOR_RESET}"
    done
}

# Optional per-prototype wheel probe: FT_PROTO_WHEEL_PROBE[type]=fn, fn NAME → 0 iff the control
# will meaningfully consume a wheel tick itself (its own content overflows). No probe = always
# consumes (a tree/table cursor move is always meaningful). Probes let the wheel CHAIN through
# a content-fits control to the scroll pane behind it.
declare -A FT_PROTO_WHEEL_PROBE=()
_ft_scrollable_ancestor() {     # NAME → FT_RET = nearest self-or-ancestor that actually scrolls
    local n=$1
    while [[ -n "$n" ]]; do
        ft_get "$n" scrollHeight
        if [[ "$FT_RET" =~ ^[0-9]+$ ]] && (( FT_RET > 0 )); then
            local sh=$FT_RET; ft_get "$n" clientHeight
            (( sh > ${FT_RET:-0} )) && { FT_RET=$n; return 0; }
        fi
        n=${FT_PARENT[$n]:-}
    done
    FT_RET=""; return 1
}
# el.scrollIntoView() — minimally scroll every scrollable ancestor so NAME's box is visible
# (the DOM's block:'nearest'). Called automatically when focus lands on a control, so keyboard
# navigation reveals off-screen controls just like a browser.
ft_scroll_into_view() {         # NAME — both axes, minimal (block/inline: 'nearest')
    local n=$1 a=${FT_PARENT[$1]:-}
    while [[ -n "$a" ]]; do
        ft_get "$a" scrollHeight
        if [[ "$FT_RET" =~ ^[0-9]+$ ]] && (( FT_RET > 0 )); then
            _ft_inset4 "$a"
            local atop=$(( ${FT_ABSOLUTE_Y[$a]:-0} + FT_INSET_TOP ))
            ft_get "$a" clientHeight; local ch=${FT_RET:-0}
            local abot=$(( atop + ch - 1 ))
            local ntop=${FT_ABSOLUTE_Y[$n]:-0}                 # NB: split — same-statement local reads OLD vars
            local nbot=$(( ntop + ${FT_MEASURED_HEIGHT[$n]:-1} - 1 ))
            ft_get "$a" scrollTop; local st=${FT_RET:-0}
            local want=$st
            if   (( ntop < atop )); then want=$(( st - (atop - ntop) ))
            elif (( nbot > abot )); then want=$(( st + (nbot - abot) )); fi
            (( want != st )) && ft_scroll_set "$a" "$want"
        fi
        ft_get "$a" scrollWidth
        if [[ "$FT_RET" =~ ^[0-9]+$ ]] && (( FT_RET > 0 )); then
            _ft_inset4 "$a"
            local aleft=$(( ${FT_ABSOLUTE_X[$a]:-0} + FT_INSET_LEFT ))
            ft_get "$a" clientWidth; local cw=${FT_RET:-0}
            local aright=$(( aleft + cw - 1 ))
            local nleft=${FT_ABSOLUTE_X[$n]:-0}
            local nright=$(( nleft + ${FT_MEASURED_WIDTH[$n]:-1} - 1 ))
            ft_get "$a" scrollLeft; local sl=${FT_RET:-0}
            local wantl=$sl
            if   (( nleft < aleft )); then wantl=$(( sl - (aleft - nleft) ))
            elif (( nright > aright )); then wantl=$(( sl + (nright - aright) )); fi
            (( wantl != sl )) && _ft_scroll_apply "$a" "" "$wantl"
        fi
        a=${FT_PARENT[$a]:-}
    done
    return 0
}
ft_focus() {                # name → 1 if the control can't be focused
    local name=$1
    # HONOUR THAT CONTRACT. The Tab ring skips anything hidden, under a hidden ancestor, or
    # disabled — but this entry point did not, so `ft_focus x` on such a control returned 0 and
    # parked focus on something the user cannot see or use. Tab and the arrows then refuse to
    # visit it, the focus ring is painted on nothing, the derived key legend describes a
    # control that isn't there, and Enter activates it. Same guard, same predicate, both paths.
    [[ -n "${FT_TYPE[$name]:-}" ]] && _ft_focus_skippable "$name" && return 1
    _ft_focus_set_try "$name" && return 0
    # Not in the ring yet — a focusable control added AFTER the ring was built is still on
    # its form's pending list (only ft_refresh consumes it). Rebuild that form's ring from
    # pending, then retry once, so focusing a freshly-added control just works. (Was a
    # gotcha: ft_focus silently no-op'd on such a control and focus stayed put.)
    [[ -z "${FT_TYPE[$name]:-}" ]] && return 1
    local form; _ft_enclosing_form_of "$name"; form=$FT_RET
    [[ -z "$form" && "${FT_TYPE[$name]}" == form ]] && form=$name
    if [[ -n "$form" && -n "${FT_PENDING_FOCUS[$form]:-}" ]]; then
        ft_focus_ring_build "$form"
        _ft_focus_set_try "$name" && return 0
    fi
    return 1
}

# ── Modal context stack ──────────────────────────────────────────────────────
# A modal (F1 help, a dialog, an About box) takes over the screen with its OWN
# root form, and building that form REPLACES the single global focus ring. Modals
# nest arbitrarily (help → About → …), so the state each one clobbers has to be
# saved on a STACK, not swapped between two slots. ft_modal_push before you build
# a modal root; ft_modal_pop after you destroy it, to restore the caller's screen
# exactly (root, focus, the full focus ring + index, and the coalescing flag).
#
# The ring is an array; bash can't nest arrays, so it is serialised newline-joined
# (control names are DSL identifiers — never contain newlines) alongside the
# scalar state in parallel stacks.
# (No ring/index snapshot: ft_modal_pop rebuilds the ring from the tree, which is correct even
#  when the dialog added or removed one of the app's controls while it was open.)
_FT_MODAL_ROOT=(); _FT_MODAL_FOCUS=(); _FT_MODAL_COAL=()
ft_modal_push() {
    # A modal lays itself out over the tree and runs its own loop with coalescing OFF, so any
    # reflow the interrupted burst had recorded must land before it opens — otherwise the
    # dialog is positioned against geometry that was never applied.
    ft_reflow_flush
    _FT_MODAL_ROOT+=("${FT_ROOT:-}")
    _FT_MODAL_FOCUS+=("${FT_FOCUS:-}")
    _FT_MODAL_COAL+=("${FT_COALESCING:-0}")
}
ft_modal_pop() {
    local top=$(( ${#_FT_MODAL_ROOT[@]} - 1 ))
    (( top < 0 )) && return 1
    FT_ROOT=${_FT_MODAL_ROOT[top]}       # (FT_ROOT/FT_FOCUS are in the resolver cache token)
    _ft_focus_land "${_FT_MODAL_FOCUS[top]}"
    FT_COALESCING=${_FT_MODAL_COAL[top]}
    # REBUILD THE RING FROM THE TREE, do not restore the snapshot taken at push. A dialog is
    # allowed to change the app while it is open — a settings panel that reveals a control, a
    # wizard step that drops one — and the snapshot is then wrong in BOTH directions: a control
    # the dialog ADDED was unreachable by Tab afterwards (it predates the snapshot), and one the
    # dialog REMOVED came back as a dead name in the ring. The tree knows the truth either way.
    # Focus is restored FIRST so its index is re-found here; the target-selection rules in
    # ft_focus_ring_build are deliberately NOT used, so a dialog's autofocus cannot steal focus
    # from the app on the way out.
    FT_FOCUS_RING=()
    [[ -n "${FT_ROOT:-}" ]] && _ft_focus_collect "$FT_ROOT"
    FT_FOCUS_INDEX=0
    local _i
    for _i in "${!FT_FOCUS_RING[@]}"; do
        [[ "${FT_FOCUS_RING[$_i]}" == "$FT_FOCUS" ]] && { FT_FOCUS_INDEX=$_i; break; }
    done
    _FT_MODAL_ROOT=("${_FT_MODAL_ROOT[@]:0:top}")
    _FT_MODAL_FOCUS=("${_FT_MODAL_FOCUS[@]:0:top}")
    _FT_MODAL_COAL=("${_FT_MODAL_COAL[@]:0:top}")
    return 0
}

# ── Event dispatch ───────────────────────────────────────────────────────────
# THE keymap layers for one control, highest precedence first. Every consumer — dispatch,
# the back-compat single-control primitive, and the derived key legend — reads them from
# HERE, so "what keys does this control have?" has one answer. They used to be three
# separate loops, and they had already drifted: ft_dispatch_keymap omitted the `keymap=`
# layer that _ft_try_keymaps honoured.
#
#   1  instance overlay  — what the app put on THIS control
#   2  keymap= reference — a shared map the instance points at
#   3  runlevel keymap   — the prototype's map for the runlevel it is currently in
#   4  prototype keymap  — the type's base keys
#
# Layer 3 is why entering a runlevel needs no save/restore: the editing keymap is SELECTED
# by the runlevel, never written over the instance slot. Nothing is destroyed, so nothing
# has to be put back.
_ft_keymap_layers() {           # name → FT_KEYMAP_LAYERS, in precedence order
    FT_KEYMAP_LAYERS=()
    local name=$1
    [[ -n "$name" ]] || return                   # an empty name is not a subscript
    local type=${FT_TYPE[$name]:-}
    _ft_get_raw "$name" keymap;   local refkm=$FT_RET
    _ft_get_raw "$name" runlevel; local runlevel=$FT_RET
    local _rlkm=""
    [[ -n "$runlevel" ]] && { _ft_runlevel_keymap_of "$name" "$runlevel"; _rlkm=$FT_RET; }
    # `${type:+…}` so the prototype-keyed subscripts are never evaluated when the type is
    # EMPTY — `FT_PROTO_KEYMAP[]` is a "bad array subscript", not an empty lookup.
    # `keymap=` is a LIST, like `class=`: `keymap="nav editing"`, LAST WINS, so the names are
    # pushed in reverse. One shared map was never quite enough — a control that wants the app's
    # navigation keys AND a screen's shortcuts had to have one map that mentioned both, which
    # made the map about the control rather than about the behaviour.
    FT_KEYMAP_LAYERS=("${FT_KEYMAP[$name]:-}")
    local _r; for _r in $refkm; do FT_KEYMAP_LAYERS=("${FT_KEYMAP_LAYERS[0]}" "$_r" "${FT_KEYMAP_LAYERS[@]:1}"); done
    # `defaultKeys=false` silences THE KEYS THE PROTOTYPE PROVIDES — its own map and the map
    # for the runlevel it is in — and leaves every key the app wrote. It is the blunt
    # instrument; `onKey=bubble` on one key is the scalpel. It INHERITS, so it silences a
    # subtree.
    #
    # Asked only when there is something to silence. Reading it costs a cascade resolve, and
    # a resolve is not cheap even warm: measured 33µs, against 136µs for the rest of this
    # function and 571µs for a whole dispatch — 6% of a keypress. Containers and any prototype
    # with no map of its own now skip it outright, which is most of the bubble chain.
    local _proto=${type:+${FT_PROTO_KEYMAP[$type]:-}}
    [[ -z "$_rlkm" && -z "$_proto" ]] && return         # this prototype provides no keys
    ft_resolved_prop "$name" defaultKeys true
    [[ "$FT_RET" == false ]] && return
    FT_KEYMAP_LAYERS+=("$_rlkm" "$_proto")
}
declare -a FT_KEYMAP_LAYERS=()

# _ft_run_action CODE NAME TOKEN — run ONE binding's action. Returns 0 if the key was
# CLAIMED, 1 to keep it bubbling. Both dispatch paths go through here.
#
# AN ACTION IS CODE, evaluated with `$this` (the control it was dispatched to) and `$key`
# (the token) in scope — the bargain HTML's onclick= makes. It used to be a FUNCTION NAME,
# invoked as `fn "$name" "$tok"` with those two arguments appended silently. The author's
# objection to reading that back was exact: "A bare word should not be a function name.
# Where are your arguments???" The convention also priced every key at one named function,
# which is how this framework arrived at 341 public functions with 106 of them existing
# only to be the right-hand side of a binding. `key=ENTER onKey='ft_activate $this'` says
# what happens and what it happens to, and a two-line action no longer needs a name at all.
#
# Four faults this function was written to fix, all still fixed:
#   · `bubble` and `drop` — the reserved words the docs promise — were not implemented at
#     all, so `bubble` wrote "bubble: command not found" onto the alt screen and then
#     SWALLOWED the key, the exact opposite of what it says.
#   · An action naming a function that does not exist (a typo, a handler removed by a
#     rebuild) reached a command position, so bash announced it on the alt screen — and
#     dispatch still returned "handled", so the key died there instead of bubbling.
#   · An EMPTY action left no words at all, and the invocation `"${words[@]}" "$name"
#     "$tok"` then made the CONTROL'S OWN NAME the command. Names are identifiers, so a
#     control called `rm` or `clear` ran rm or clear, with the key token as its argument.
#   · The word split was unquoted, so an action was GLOBBED against the current directory.
#     Under eval that one is no longer a fault but a feature of writing code: `fn *` is a
#     glob because you wrote a glob.
#
# The unresolved-action guard survives the move to code, because a typo'd handler is still
# the common failure and stderr in a TUI is the screen the user is looking at. It applies
# where it can be applied honestly: when the code's FIRST WORD is a plain command word, it
# must name something callable. Code that starts with an assignment, a keyword, a
# subshell or an expansion is left to bash.
FT_UNRESOLVED_ACTIONS=()        # deduped "control action" pairs — see ft_unresolved_actions
_ft_run_action() {              # code name token
    local _code=$1 _name=$2 _tok=$3
    case "$_code" in
        '')     return 1 ;;                     # legend-only cap — advertised, not bound
        bubble) return 1 ;;                     # documented: decline, let an ancestor have it
        drop)   return 0 ;;                     # documented: swallow it here
    esac
    local _first=${_code%%[ 	]*}
    if [[ "$_first" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] && ! type -t "$_first" >/dev/null 2>&1; then
        # Recorded rather than printed: this fires on every press of the key.
        local _pair="$_name $_first" _seen
        for _seen in "${FT_UNRESOLVED_ACTIONS[@]}"; do [[ "$_seen" == "$_pair" ]] && return 1; done
        FT_UNRESOLVED_ACTIONS+=("$_pair")
        return 1                                # unhandled → bubble; never claim a key we dropped
    fi
    FT_KEY_BUBBLE=0
    local this=$_name key=$_tok
    eval "$_code"
    (( FT_KEY_BUBBLE )) && return 1             # handler declined → let it bubble to the parent
    return 0
}
# Every binding whose action could not be resolved, as "CONTROL ACTION" lines — a keymap
# pointing at a function that was renamed, or never written. Each pair is reported once.
ft_unresolved_actions() {       # → FT_RET (empty when every action resolved)
    local IFS=$'\n'
    FT_RET="${FT_UNRESOLVED_ACTIONS[*]}"
}

# _ft_try_keymaps NAME TOKEN — this one control's layers, in order. A binding's ACTION may
# carry arguments ("fn arg…"); it is invoked as `fn arg… NAME TOKEN`. Returns 0 if handled
# (matched, or swallowed by a drop default).
_ft_try_keymaps() {             # name token
    local name=$1 tok=$2 km
    _ft_keymap_layers "$name"
    local -a layers=("${FT_KEYMAP_LAYERS[@]}")   # copy: a handler we invoke may dispatch again
    for km in "${layers[@]}"; do
        [[ -z "$km" ]] && continue
        if _ft_keymap_lookup "$km" "$tok"; then
            FT_KEY_BUBBLE=0
            _ft_run_action "$FT_RET" "$name" "$tok" && return 0
            return 1                            # declined or unresolvable → keep bubbling
        fi
        _ft_keymap_default "$km"
        [[ "$FT_RET" == drop ]] && return 0
    done
    return 1
}

# ft_dispatch_event TOKEN — cascade from the focused control (or the root if
# nothing is focused) up through its ancestors. Returns 1 if nothing matched.
FT_ROOT=""
# A key handler normally CLAIMS its key. To let a handler conditionally decline
# (so the key keeps bubbling — e.g. a text field's Esc cancels a selection if there
# is one, else lets Esc reach the app's command menu), it sets FT_KEY_BUBBLE=1.
FT_KEY_BUBBLE=0
ft_dispatch_event() {           # token
    local tok=$1
    local n=${FT_FOCUS:-}
    [[ -z "$n" || -z "${FT_TYPE[$n]:-}" ]] && n=$FT_ROOT
    while [[ -n "$n" ]]; do
        _ft_try_keymaps "$n" "$tok" && return 0
        n=${FT_PARENT[$n]:-}
    done
    return 1
}

# Back-compat single-control primitive (no ancestor walk). Reads the SAME layers as the
# cascade — it used to check only the instance overlay and the prototype map, silently missing
# a `keymap=` reference and now a runlevel map too.
ft_dispatch_keymap() {          # name token
    local name=$1 tok=$2 km
    _ft_keymap_layers "$name"
    local -a layers=("${FT_KEYMAP_LAYERS[@]}")
    for km in "${layers[@]}"; do
        [[ -z "$km" ]] && continue
        if _ft_keymap_lookup "$km" "$tok"; then
            FT_KEY_BUBBLE=0
            _ft_run_action "$FT_RET" "$name" "$tok"     # the SAME resolver as the cascade
            return $?
        fi
        _ft_keymap_default "$km"
        [[ "$FT_RET" == drop ]] && return 0
    done
    return 1
}

# ── Derived key legend ───────────────────────────────────────────────────────
# Importance is a raw 0–255 weight, but three NAMED anchors keep controls consistent and
# give the theme somewhere to hang per-tier colour (borderCrucialColor[…] etc.). A control
# is free to use any number — the numbers, not the names, drive the sort, so close calls
# resolve cleanly (a control can sit a key at 205 to edge just above another's 200).
FT_IMPORTANCE_CRUCIAL=200      # the one key the user most needs here (arrows on a scroller/slider)
FT_IMPORTANCE_IMPORTANT=120    # clearly worth showing prominently (PgUp/PgDn, activate)
FT_IMPORTANCE_NORMAL=60        # useful, shown, but not called out (Home/End, Copy)
# _ft_imp_tier N → FT_RET = crucial|important|normal — bucket a weight for THEME colour
# lookup. Thresholds sit midway between the anchors; a routine may ignore this and read
# straight off the number (the `intensity` it is passed).
_ft_imp_tier() { local n=$1; if (( n >= 160 )); then FT_RET=crucial; elif (( n >= 90 )); then FT_RET=important; else FT_RET=normal; fi; }
# …and one below the three anchors, for content whose whole job is to be READ rather than used.
# Prose is what you cover when something has to be covered — a paragraph reads around an
# obstruction, a button does not work around one.
FT_IMPORTANCE_MINOR=30         # prose, captions, decorative text
# _ft_importance KEYWORD-OR-NUMBER → FT_RET. ONE definition of what the words mean, shared by
# a binding's `keyImp=` field and every control's `importance=` property, so a legend
# and a callout cannot end up disagreeing about what "important" is worth.
_ft_importance() {              # crucial|important|normal|minor|0-255 → FT_RET
    case "$1" in
        crucial)   FT_RET=$FT_IMPORTANCE_CRUCIAL ;;
        important) FT_RET=$FT_IMPORTANCE_IMPORTANT ;;
        normal)    FT_RET=$FT_IMPORTANCE_NORMAL ;;
        minor)     FT_RET=$FT_IMPORTANCE_MINOR ;;
        *[!0-9]*|"") FT_RET=$FT_IMPORTANCE_NORMAL ;;    # anything unparseable reads as normal
        *)         FT_RET=$1 ;;
    esac
}
# What a control's cells are WORTH — the weight anything deciding "what may I cover?" multiplies
# by. Read through ft_resolved_prop so a stylesheet or an instance can override it like any other
# property, with the prototype default as the floor.
_ft_control_importance() {      # name → FT_RET (0–255)
    # THROUGH THE CASCADE, not ft_resolved_prop. Importance is action density, and action density is
    # a function of STATE — a textfield is nearly inert until the caret is in it. `ft_style` is the
    # resolver that answers `textfield:focus { importance: crucial }`; `ft_resolved_prop` does not
    # consult the stylesheet for it and returned the prototype default forever. Measured on a focus
    # toggle: ft_style gave minor → crucial across the transition while ft_resolved_prop said
    # `normal` throughout. Called once per obstacle when the obstacle list is built (~17 controls),
    # not per candidate.
    ft_style "$1" importance
    [[ -n "$FT_RET" ]] || FT_RET=normal
    _ft_importance "$FT_RET"
}

# The legend a status bar shows is not hand-authored — it is DERIVED from whatever the
# focused control (and its ancestors, up to the form) can do RIGHT NOW. Each control
# declares its keys with a `keyCap=` and a `keyImp=`; the legend collects them from
# the exact same cascade dispatch walks — instance overlay → shared keymap=ref →
# prototype default, at the focused leaf then each ancestor — so what the user is shown to press is
# always what a press would actually do. Nearest-wins dedup: a leaf's binding for a key
# hides an ancestor's. The result is sorted by importance so the key that matters most
# here leads (Up/Down on a scroller, arrows on a slider, Space on a checkbox).
_ft_caps_sort() {               # sort FT_CAPS by importance DESC, stable (insertion sort,
    local n=${#FT_CAPS[@]} i j cur curimp    # fork-free: this is running-app code)
    for (( i=1; i<n; i++ )); do
        cur=${FT_CAPS[i]}; curimp=${cur%%$'\t'*}
        j=$(( i - 1 ))
        # shift entries with STRICTLY smaller importance right; equal keeps input order (stable)
        while (( j >= 0 )) && (( ${FT_CAPS[j]%%$'\t'*} < curimp )); do
            FT_CAPS[j+1]=${FT_CAPS[j]}; (( j-- ))
        done
        FT_CAPS[j+1]=$cur
    done
}
# A key PATTERN (the dispatch token) prettified into the human label the legend prints.
# The rule (from user feedback): use a Unicode symbol ONLY when it is INSTANTLY readable —
# ↑ ↓ ← → arrows, ⌘ Command, ⌫ Backspace, ⏏ Eject. Everything else SPELLS OUT in plain
# words — Ctrl, Alt, Shift, Esc, Enter, Tab, PgUp… — because the obscure modifier symbols
# (⌃ ⌥ ⇧) read as hieroglyphics, not keys. A DASH joins a modifier to its key: "Ctrl-C",
# "Shift-Tab", "Ctrl-Shift-Home". The status bar draws each of these inside a coloured
# "keycap" chip so it looks like a key. (A future keymode/setting can swap the vocabulary.)
_ft_keycap_glyph() {            # pattern → FT_RET
    local p=$1 pre=""
    while [[ "$p" == CTRL+* || "$p" == ALT+* || "$p" == SHIFT+* || "$p" == CMD+* ]]; do
        case "$p" in
            CTRL+*)  pre+="Ctrl-";  p=${p#CTRL+} ;;
            ALT+*)   pre+="Alt-";   p=${p#ALT+} ;;
            SHIFT+*) pre+="Shift-"; p=${p#SHIFT+} ;;
            CMD+*)   (( FT_USE_UTF8 )) && pre+="⌘-" || pre+="Cmd-"; p=${p#CMD+} ;;   # ⌘ is readable
        esac
    done
    # A case-insensitive letter class like [Kk] (how accelerators/quit are bound) shows as
    # the plain uppercase letter, not the raw bracket pattern.
    [[ "$p" == '['??']' ]] && { p=${p#'['}; p=${p%']'}; p=${p:0:1}; p=${p^^}; }
    local g
    case "$p" in
        UP) g="↑" ;; DOWN) g="↓" ;; LEFT) g="←" ;; RIGHT) g="→" ;;    # arrows read at a glance
        PGUP) g="PgUp" ;; PGDN) g="PgDn" ;; HOME) g="Home" ;; END) g="End" ;;
        ENTER) g="Enter" ;; SPACE) g="Space" ;; ESC|ESCAPE) g="Esc" ;; TAB) g="Tab" ;;
        BACKSPACE|BS) g="⌫" ;; DEL|DELETE) g="Del" ;; EJECT) g="⏏" ;;
        *) g="$p" ;;
    esac
    # A single letter after a modifier reads as uppercase by convention (Ctrl-C, Alt-W).
    [[ -n "$pre" && ${#g} == 1 && "$g" == [a-z] ]] && g=${g^^}
    (( FT_USE_UTF8 )) || case "$p" in            # ASCII fallbacks where a glyph won't render
        UP) g="Up" ;; DOWN) g="Dn" ;; LEFT) g="Lt" ;; RIGHT) g="Rt" ;;
        BACKSPACE|BS) g="Bksp" ;; EJECT) g="Eject" ;; esac
    FT_RET="$pre$g"
}
# Add one dynamic cap if its key isn't already shown. Dynamic caps are collected BEFORE a
# node's static keymap caps, so a state-dependent label (e.g. "New line" while editing)
# wins the nearest-wins dedup over a static one ("Edit" on the idle keymap).
_ft_caps_add() {                # importance pattern label
    local s; for s in "${FT_CAPS[@]}"; do [[ "${s#*$'\t'}" == "$2"$'\t'* ]] && return; done
    FT_CAPS+=("$1"$'\t'"$2"$'\t'"$3")
}
# Does ENTER actually reach the shared delve handler for this control, right now? The keymap
# CASCADE is the authority — a rung's own map, then the prototype map, then whatever is above —
# and the first layer that binds ENTER decides. Anything that claims it (a tree's expand, a
# textarea's newline) means Enter has a deeper meaning here and the shared rule never runs.
_ft_enter_reaches_delve() {     # name
    local n=$1 km
    _ft_keymap_layers "$n"
    for km in "${FT_KEYMAP_LAYERS[@]}"; do
        [[ -n "$km" ]] || continue
        if _ft_keymap_lookup "$km" ENTER; then
            # An action is CODE, so ask what it CALLS rather than comparing the whole string:
            # `ft_key_delve` and `ft_key_delve $this` are the same answer to "does Enter go
            # deeper here?", and a legend that matched one literal spelling silently stopped
            # saying Leave the moment the binding was written the other way.
            [[ "${FT_RET%%[ 	]*}" == ft_key_delve ]]; return
        fi
    done
    return 1
}
_ft_legend_caps() {             # → fills FT_CAPS = ("IMPORTANCE\tPATTERN\tLABEL" …) sorted desc
    FT_CAPS=()
    local n=${FT_FOCUS:-} km refkm capfn
    [[ -z "$n" || -z "${FT_TYPE[$n]:-}" ]] && n=$FT_ROOT
    while [[ -n "$n" ]]; do
        # AT THE BOTTOM OF A LADDER, ENTER LEAVES — so say so. The prototype keymap's ENTER label
        # describes going IN ("Adjust", "Scroll"), which is right at every rung but the last;
        # standing on the last one, ft_key_delve leaves instead, and an unchanged legend would
        # name a key and lie about it. In ONE place rather than as an _ft_caps_slider /
        # _label / _table / _tabs each repeating it — four copies of a rule is how they drift.
        #
        # IT ASKS EXACTLY WHAT THE DISPATCH ASKS, including the part that is easy to forget:
        # Enter only reaches ft_key_delve when no nearer keymap layer has claimed it. A
        # multi-line field binds ENTER at `editing` to insert a newline, so it never reaches
        # the shared rule and its legend must keep saying "New line". Checking only "engaged
        # and no deeper rung" shadowed that cap and made the field advertise Leave for a key
        # that types.
        #
        # ft_runlevel_next_rung is the non-mutating half of ft_runlevel_deeper, split out for
        # this: deriving a legend must not step the control into another rung.
        if [[ "$n" == "${FT_FOCUS:-}" ]] && ft_runlevel_engaged "$n" \
           && ! ft_runlevel_next_rung "$n" && ! ft_has_listener "$n" activate \
           && _ft_enter_reaches_delve "$n"; then
            # IMPORTANT, not CRUCIAL: inside a control the crucial keys are the ones that DO
            # something there (a slider's arrows), and leaving is the way out — the same tier
            # ESC's own "Leave" cap already uses. At CRUCIAL it sorted ahead of them and the
            # legend led with the exit.
            _ft_caps_add "$FT_IMPORTANCE_IMPORTANT" ENTER Leave
        fi
        # STATE-DEPENDENT caps first: a control may define _ft_caps_<type> to contribute
        # keys that depend on its live state (a field in edit mode, a selection to copy,
        # a kill-ring to paste) — things a static keymap can't express.
        capfn="_ft_caps_${FT_TYPE[$n]:-}"
        declare -F "$capfn" >/dev/null 2>&1 && "$capfn" "$n"
        # The SAME layers dispatch uses — so the legend can never advertise a key that
        # would not fire, and a runlevel's keymap shows up the moment it is in effect.
        _ft_keymap_layers "$n"
        for km in "${FT_KEYMAP_LAYERS[@]}"; do
            [[ -n "$km" ]] && _ft_keymap_caps "$km"
        done
        n=${FT_PARENT[$n]:-}
    done
    _ft_caps_sort
}

# ── Mouse ────────────────────────────────────────────────────────────────────
# The run loop fills these from a MOUSE event: FT_MOUSE_X/Y are 1-based cells,
# FT_MOUSE_BUTTON the SGR button code, FT_MOUSE_ACTION the final char (M press/drag, m
# release). A control opts in by setting FT_PROTO_MOUSE[type] to a handler run
# as: <fn> NAME ACTION RELX RELY   (ACTION = press | drag | release).
FT_MOUSE_BUTTON=0; FT_MOUSE_X=1; FT_MOUSE_Y=1; FT_MOUSE_ACTION=M
FT_HIT=""; _FT_MOUSE_DOWN=""
# Deepest POSITIONED control containing screen cell (x,y) (0-based). A prototype flagged
# FT_PROTO_NOHIT (CSS pointer-events:none — e.g. a beacon overlay) is TRANSPARENT to
# the mouse: it never claims the hit, so a click passes through it to the real control
# underneath (an overlay's paint position isn't even its layout rect, so a hit on it
# would be meaningless anyway).
_ft_hit_walk() {                # x y node
    local x=$1 y=$2 n=$3
    # NO NODE, NOTHING TO HIT. _ft_hit_test falls back to ${FT_ROOT:-}, so an empty root
    # reaches here as an empty name — and three associative subscripts on the next line then
    # error onto stderr, i.e. the alt screen. (This was firing inside the test suite already,
    # six times, with nobody looking at stderr.)
    [[ -z "$n" ]] && return
    local ax=${FT_ABSOLUTE_X[$n]:-} w=${FT_MEASURED_WIDTH[$n]:-0} h=${FT_MEASURED_HEIGHT[$n]:-0} ay k
    [[ -z "$ax" ]] && return
    ay=${FT_ABSOLUTE_Y[$3]:-0}
    (( x >= ax && x < ax + w && y >= ay && y < ay + h )) || return
    (( ${FT_PROTO_NOHIT[${FT_TYPE[$n]:-}]:-0} == 1 )) || FT_HIT=$n
    for k in ${FT_KIDS[$n]:-}; do _ft_hit_walk "$x" "$y" "$k"; done
}
_ft_hit_test() { FT_HIT=""; _ft_hit_walk "$1" "$2" "${3:-$FT_ROOT}"; }
# Nearest self-or-ancestor of $1 that can take the click (focusable or mousy).
#
# `focusable` is 0 or 1, so testing it with -n was true for EVERY prototype that had been
# initialised — including every deliberately inert one. A heading, statusbar, keylegend or
# boxheader therefore claimed the click it was standing in front of. ft_focus refuses to
# move onto them, so focus looked correct, and the damage landed on the two callers that
# read this answer for something else: the wheel stopped chaining to the scroll container
# underneath (a browser scrolls the pane when you spin over a heading), and a callout could
# not be dragged from any cell one of them covered. Both consumers had grown a hardcoded
# `form|frame|div|empty|box|label` list of "inert" types to compensate — the symptom of a
# predicate that could not answer the question it was being asked.
_ft_mouse_target() {            # node → FT_RET ("" if none)
    local n=$1 t
    while [[ -n "$n" ]]; do
        t=${FT_TYPE[$n]:-}
        if [[ "${FT_PROTO_FOCUSABLE[$t]:-0}" == 1 || -n "${FT_PROTO_MOUSE[$t]:-}" ]]; then
            _ft_focus_skippable "$n" || { FT_RET=$n; return 0; }
        fi
        n=${FT_PARENT[$n]:-}
    done
    FT_RET=""; return 1
}
_ft_mouse_deliver() {           # name action absx absy — call the prototype mouse handler
    local n=$1                                # NOTE: split — a same-statement $n reads OLD
    # A control can be REMOVED between the press and the release (a button that deletes its own
    # row). Its name is still held as the mouse-capture target, and asking for the prototype handler
    # of a control with no type subscripts an associative array with "" — a bash error printed
    # to stderr, which in a TUI is the alt screen.
    local ty=${FT_TYPE[$n]:-}
    [[ -z "$ty" ]] && return 0
    local fn=${FT_PROTO_MOUSE[$ty]:-}
    [[ -z "$fn" ]] && return 0
    "$fn" "$n" "$2" $(( $3 - ${FT_ABSOLUTE_X[$n]:-0} )) $(( $4 - ${FT_ABSOLUTE_Y[$n]:-0} ))
}
_ft_mouse_activate() { [[ "$2" == release ]] && ft_activate "$1"; return 0; }  # generic: click = activate
# THE WHEEL DOES NOT HAVE TO KNOCK. Delving with Enter is how the KEYBOARD asks to be inside
# a control, because the keyboard has no other way to say which control it means. A wheel
# already said: it is pointing at one. So a wheel over a tree scrolls that tree whether or
# not you have stepped into it — it resolves against the control's FIRST delved rung (the
# scrolling/browsing one), without changing the runlevel or moving focus.
#
# The first rung, not the deepest: on a text field the deepest is `editing`, where Down
# moves the CARET. Pointing at a field and turning the wheel means scroll, never type.
_ft_wheel_dispatch() {          # name token
    local n=$1 tok=$2
    local type=${FT_TYPE[$n]:-}         # NB: separate line — same-statement `local` reads the OLD $n
    # The first rung PAST the free two — the scrolling/browsing one every ladder starts with.
    if _ft_runlevel_first_rung "$n"; then
        _ft_runlevel_keymap_of "$n" "$FT_RET"; local km=$FT_RET
        if [[ -n "$km" ]] && _ft_keymap_lookup "$km" "$tok"; then
            _ft_run_action "$FT_RET" "$n" "$tok"
            return 0
        fi
    fi
    ft_dispatch_keymap "$n" "$tok"
}
_ft_dispatch_mouse() {
    local x=$(( FT_MOUSE_X - 1 )) y=$(( FT_MOUSE_Y - 1 )) b=$FT_MOUSE_BUTTON act=$FT_MOUSE_ACTION tgt
    if (( b & 64 )); then                    # scroll wheel → Up/Down on the control under it
        _ft_hit_test "$x" "$y"
        local _wtgt=""
        _ft_mouse_target "$FT_HIT" && _wtgt=$FT_RET
        # Over an INERT spot (nothing interactive, or a bare container) the wheel scrolls the
        # nearest overflow container — like a browser. Over a real control, the control keeps
        # its own wheel behavior — UNLESS its prototype probe says it has nothing to scroll (a label
        # whose text fits, a textfield with no overflow), in which case the wheel CHAINS to the
        # pane, exactly like browser scroll chaining.
        local _chain=0
        # `""` alone now covers every inert type: since _ft_mouse_target stopped claiming
        # controls that cannot take a click, form/frame/div/empty/box no longer reach here
        # and listing them only implied they could.
        case ${_wtgt:+${FT_TYPE[$_wtgt]:-}} in
            "") _chain=1 ;;
            *)  local _wp=${FT_PROTO_WHEEL_PROBE[${FT_TYPE[$_wtgt]:-}]:-}
                [[ -n "$_wp" ]] && ! "$_wp" "$_wtgt" && _chain=1 ;;
        esac
        if (( _chain )); then
            if _ft_scrollable_ancestor "${_wtgt:-${FT_HIT:-}}"; then
                local sc=$FT_RET st; ft_get "$sc" scrollTop; st=${FT_RET:-0}
                if (( b & 1 )); then ft_scroll_set "$sc" $(( st + 2 )); else ft_scroll_set "$sc" $(( st - 2 )); fi
                ft_redraw_dirty
                return 0
            fi
            [[ -z "$_wtgt" ]] && return 0     # nothing to chain to, nothing to dispatch to
        fi
        tgt=$_wtgt
        (( b & 1 )) && _ft_wheel_dispatch "$tgt" DOWN || _ft_wheel_dispatch "$tgt" UP
        return 0
    fi
    if [[ "$act" == m ]]; then               # release
        declare -F _ft_beacon_mouse_release >/dev/null && _ft_beacon_mouse_release && return 0
        _FT_GUTTER_GRAB=""
        [[ -n "$_FT_MOUSE_DOWN" ]] && _ft_mouse_deliver "$_FT_MOUSE_DOWN" release "$x" "$y"
        _FT_MOUSE_DOWN=""; return 0
    fi
    if (( b & 32 )); then                     # drag (motion with a button held)
        declare -F _ft_beacon_mouse_drag >/dev/null && _ft_beacon_mouse_drag "$x" "$y" && return 0
        # A gutter grab is held by a CONTAINER, which has no prototype mouse handler — keep
        # scrolling it directly, and (unlike the thumb) follow the pointer even when it
        # slides off the one-cell-wide bar, as a desktop scrollbar does.
        if [[ -n "$_FT_GUTTER_GRAB" ]]; then
            _ft_scroll_gutter_drag "$_FT_GUTTER_GRAB" "$_FT_GUTTER_AXIS" "$x" "$y"
            ft_redraw_dirty; ft_flush
            return 0
        fi
        [[ -n "$_FT_MOUSE_DOWN" ]] && _ft_mouse_deliver "$_FT_MOUSE_DOWN" drag "$x" "$y"
        return 0
    fi
    (( b & 3 )) && return 0                    # press: left button only
    # A PRESS PROVES THE BUTTON WAS UP — so a grab still live here lost its release (the pointer
    # left the window mid-drag, or the release hid in a flooded escape stream). Left standing,
    # the stale grab eats every later button-held motion: the user drags a slider and the
    # callout moves instead, until some accident clears it. Synthesize the release the terminal
    # never delivered — the callout parks where the drag left it — then treat this press fresh.
    if [[ -n "${_FT_BEACON_GRAB:-}" ]] && declare -F _ft_beacon_mouse_release >/dev/null; then
        _ft_beacon_mouse_release
    fi
    # A callout's ▶ "next" and ⊠ "close" glyphs are its own chrome (drawn above all) — they always
    # claim, checked before control hit-testing so a step still advances, and a chip can still be
    # dismissed, even when the callout sits over a control. Both come before the box GRAB below,
    # or a press on either would start a drag instead of pressing the thing under the pointer.
    if declare -F _ft_beacon_close_at >/dev/null && _ft_beacon_close_at "$x" "$y"; then return 0; fi
    if declare -F _ft_beacon_next_at  >/dev/null && _ft_beacon_next_at  "$x" "$y"; then return 0; fi
    # An open dropdown's option list is an OVERLAY drawn OUTSIDE the select's own box, so a
    # click on an option would otherwise hit whatever is under the overlay. Route it back to
    # the select and commit that option. (Clicking elsewhere closes it via the blur path.)
    if [[ -n "${FT_OPEN_SELECT:-}" ]] && declare -F _ft_select_overlay_at >/dev/null; then
        _ft_select_overlay_at "$x" "$y"
        if [[ -n "$FT_RET" ]]; then
            local os=$FT_OPEN_SELECT idx=$FT_RET
            _ft_select_commit_index "$os" "$idx"; ft_select_close "$os"
            ft_redraw_dirty; ft_flush
            return 0
        fi
    fi
    # A CALLOUT'S BOX OWNS ITS OWN PIXELS. This used to be the other way — "an interactive
    # target always wins", so a callout box was only grabbable over inert chrome — on the theory
    # that a callout must never swallow a click meant for a real control. But the callout is
    # OPAQUE: whatever it parks over is invisible, so a click there visibly targets the callout
    # and actually pressed a control the user could not see — after a drag parked the box over
    # the demo's textfield, clicking the box FOCUSED THE HIDDEN FIELD and the callout "refused
    # to budge" anywhere the field lay beneath it (the reported stuck-drag: some cells grabbed,
    # most didn't, no visible pattern). Auto placement minimizes covering interactive controls,
    # so this order costs the click-through case almost nothing — and a control the callout
    # does cover is reachable the moment the callout is dragged off it, which is now possible
    # from any cell of the box. The ▶ next-glyph stays ahead of this (the box's own chrome).
    if declare -F _ft_beacon_grab_at >/dev/null && _ft_beacon_grab_at "$x" "$y"; then return 0; fi
    # A scrollable container's GUTTER is a scrollbar, so it must grab the pointer like one.
    # The container itself is usually inert (a frame or panel has no mouse handler), so the
    # click would otherwise fall through to whatever is behind the bar — or to nothing.
    _ft_hit_test "$x" "$y"
    if _ft_scroll_gutter_at "$FT_HIT" "$x" "$y"; then
        _FT_GUTTER_GRAB=$FT_RET                     # held until release, like a thumb drag
        _ft_scroll_gutter_drag "$_FT_GUTTER_GRAB" "$_FT_GUTTER_AXIS" "$x" "$y"
        ft_redraw_dirty; ft_flush
        return 0
    fi
    if _ft_mouse_target "$FT_HIT"; then
        tgt=$FT_RET
        # (the callout grab already ran above — a press reaching here is genuinely for the
        # control, whether that is a label, a field or a button)
        ft_focus "$tgt"
        _FT_MOUSE_DOWN=$tgt
        _ft_mouse_deliver "$tgt" press "$x" "$y"
        return 0
    fi
    return 0
}

# ft_activate [TARGET] — run TARGET's prototype activation behavior, then its
# instance hook. Bound plain (ENTER=ft_activate) the focused name arrives as
# $1; bound with an argument ("ft_activate btnOk", the accessKey sugar) the
# target does. A disabled control (or one inside a disabled container) is
# inert. Value-bearing controls (checkbox/radio/multitoggle/select/slider)
# keep their own `value` current here automatically — so "submitting" is just
# whatever a button's onActivate=fn chooses to do: read the values it
# cares about and act (e.g. build a settings string for samba-tool). There is
# no separate form submit phase and no type=submit — a button is a button.
# ── Hook dispatch: $this + value(s) ──────────────────────────────────────────
# WHAT A LISTENER RECEIVES. (Which listeners run is the next block's subject, and it is
# always the ones you WIRED — this comment used to open by saying an event "runs the handler
# you named <control>_on_EVENT", which is the exact name-convention model the block below and
# docs/api-naming.md both forbid, with two unwired examples to copy. A maintainer who believed
# it would write a handler that never runs — or, worse, add a `declare -F "${n}_on_EVENT"`
# gate to make it run, which is a bug that has actually been written in this codebase.)
#
# The framework sets the global $this to the control's OWN name for the duration of the call,
# then restores it. Nested hooks (one hook triggering another control's hook) each see the
# right $this and unwind correctly, because the save is a LOCAL — bash's own call stack does
# the bookkeeping, so there is no reentrancy hazard.
# The handler's ARGUMENTS are the control's VALUE(s): $1 for a single value, or
# "$@" for a multi-value control. The name is never an argument — it is $this.
#     ft-textfield name=rowW  onChange=rowW_changed      # WIRED, or it never runs
#     rowW_changed()  { ft_set row width=$1; }        # $1 = new value
#     ft-select name=perms multiple=true onChange=perms_changed
#     perms_changed() { local -a values=("$@"); ... }    # multi-select
# `${this}_<prop>` is also the backing shell variable, and ft_get "$this" <prop>
# / ft_set "$this" ... all work. A hook may `return` nonzero to CANCEL the
# change (slider/select honour it).
this=""
# ── Event dispatch ────────────────────────────────────────────────────────────
# A control event runs every listener registered on the control's `eventListeners` plist for that
# event (tokens `event=fn`, in registration order) — added via `onActivate=fn` at construction/
# ft_set, or ft_add_listener. Listeners are ALWAYS explicit; there is no name-convention magic
# (a function named <name>_on_<event> is just a function — wire it, or it never runs).
# The handler contract (the "event object", bash-style): $this = the control, $FT_EVENT_TYPE = the
# event name, "$@" = the value(s)/detail; input events also see FT_MOUSE_* / FT_EVENT_CHAR.
# Any listener returning NONZERO cancels the action (preventDefault) — all listeners still run.
_ft_hook() {                    # name on_<event> [value...] → nonzero iff any listener cancelled
    local __name=$1 __hook=$2; shift 2
    local __lk="_ftp_${__name}_eventListeners"            # NB: separate line — same-statement local
    local __ls=${!__lk-}
    [[ -z "$__ls" ]] && return 0                          # no listeners (hot path)
    local __ev=${__hook#on_} __rc=0 __tok
    local _prev_this=${this-} _prev_evt=${FT_EVENT_TYPE-}
    this=$__name; FT_EVENT_TYPE=$__ev
    for __tok in $__ls; do
        [[ "${__tok%%=*}" == "$__ev" ]] || continue
        declare -F "${__tok#*=}" >/dev/null 2>&1 || continue
        "${__tok#*=}" "$@" || __rc=1
    done
    this=$_prev_this; FT_EVENT_TYPE=$_prev_evt
    return $__rc
}
# Explicit listener management (the DOM's addEventListener/removeEventListener, on the
# `eventListeners` plist). Pair form, variadic: ft_add_listener NAME activate=fn [change=g …];
# the two-arg DOM shape `ft_add_listener NAME activate fn` works too.
ft_add_listener()    { local __n=$1; shift; [[ "$1" != *=* ]] && set -- "$1=$2"; ft_tokenlist_add    "$__n" eventListeners "$@"; }
ft_remove_listener() { local __n=$1; shift; [[ "$1" != *=* ]] && set -- "$1=$2"; ft_tokenlist_remove "$__n" eventListeners "$@"; }
ft_has_listener() {             # NAME EVENT → 0 iff a listener is registered for it
    local __lk="_ftp_${1}_eventListeners"                 # NB: separate line — same-statement local
    local __ls=${!__lk-} __tok
    for __tok in $__ls; do [[ "${__tok%%=*}" == "$2" ]] && return 0; done
    return 1
}

ft_activate() {
    local target=$1
    [[ -z "${FT_TYPE[$target]:-}" ]] && return 0
    ft_resolved_prop "$target" disabled false
    [[ "$FT_RET" == true ]] && return 0
    case "${FT_TYPE[$target]}" in
        radio)                ft_radio_select "$target" ;;
        multitoggle|checkbox) ft_multitoggle_cycle "$target"; return 0 ;;  # cycle; manages hooks + cancel
        tab)                  _ft_tab_activate "$target"; return 0 ;;      # accessKey = switch to this tab
    esac
    _ft_hook "$target" on_activate
    return 0
}
# ft_accesskey_conflicts → FT_RET = one "CONTROL KEY WINNER" line per accessKey that CANNOT
# FIRE, empty if every accelerator reaches its control.
#
# Sharing a letter between controls is a deliberate feature (the key activates the first of
# them that is enabled and visible), so a shared letter is NOT a conflict. What is: a plain
# binding for the same letter on the same keymap, which wins outright because lookup takes the
# last registration. The control keeps drawing its underlined letter, so the UI goes on
# promising a shortcut that does nothing — invisible to every test, because the control renders
# perfectly and the key does something plausible instead.
#
# Found the case it exists for in demo/css-demo.bash: a `Bold` checkbox with accessKey=B on a
# page whose app-level `[Bb]` cap moves back a page. Pressing B paged backwards.
ft_accesskey_conflicts() {
    local out="" n form km ac act want sharers
    for n in "${!FT_ACCEL_FORM[@]}"; do
        [[ -n "${FT_TYPE[$n]:-}" ]] || continue          # control is gone
        form=${FT_ACCEL_FORM[$n]}
        [[ -n "${FT_TYPE[$form]:-}" ]] || continue
        _ft_get_raw "$n" accessKey; ac=${FT_RET^^}
        [[ -n "$ac" ]] || continue
        km=${FT_KEYMAP[$form]:-}
        [[ -n "$km" ]] || continue
        want="_ft_accel_dispatch $form $ac"
        _ft_keymap_lookup "$km" "${ac,,}" || continue    # nothing claims it at all
        act=$FT_RET
        [[ "$act" == "$want" ]] && continue              # the accelerator wins — fine
        # An override is USUALLY deliberate and harmless: an app rebinds its own button's
        # letter to a labelled cap that does the same thing. It only becomes a lie when the
        # letter is SHARED — then "the first enabled control wins" silently stops being true
        # and every control but the winner draws a shortcut that does something else.
        sharers=${FT_ACCEL_LIST["${form}"$'\x1f'"${ac}"]:-}
        [[ "$sharers" == *" "* ]] || continue            # only this control claims it
        out+="$n $ac $act"$'\n'
    done
    FT_RET=$out
    [[ -z "$out" ]]
}

# Switch a tab's enclosing ft-tabs to show it (used by a tab's accelerator).
_ft_tab_activate() {            # tabname
    local t=$1 i
    local p=${FT_PARENT[$t]:-}
    [[ "${FT_TYPE[$p]:-}" == tabs ]] || return 0
    _ft_tabs_tabs "$p"
    for i in "${!FT_TABS[@]}"; do
        [[ "${FT_TABS[$i]}" == "$t" ]] && { _ft_tabs_set "$p" "$i"; return 0; }
    done
    return 0
}

# Shared prototype-default keymap for anything ENTER/SPACE-activatable: a prototype that says
# `keymap=activate` gets this built for it, once. (button/radio/multitoggle/checkbox.)
_ft_define_keymap_activate() {
    # The one thing to do on a button/checkbox/radio/multitoggle: activate it. Enter carries
    # the cap that leads the legend for the whole activate family; Space does the same and is
    # deliberately unshown.
    ft_keymap_set ft_keymap_activate \
        key=SPACE onKey='ft_activate $this' \
        key=ENTER keyCap=Activate keyImp=crucial onKey='ft_activate $this'
}

# ── Run loop ─────────────────────────────────────────────────────────────────
FT_RUN_ACTIVE=0
ft_quit() { FT_RUN_ACTIVE=0; return 0; }
# Esc at the form level opens the command menu (Help/Settings/About/Quit) — the one
# global key no terminal or IDE steals. If the menu module isn't loaded, Esc just
# quits, the historical behaviour. A focused control that wants Esc for itself (a
# text field cancelling a selection, an open dropdown) consumes it first; only an
# unclaimed Esc bubbles up here.
# Esc at the form level is now a deliberate NO-OP (a boundary). The old Esc→command
# menu is retired: Esc's only jobs are to leave a text field's edit mode and to
# cancel a dialog, both handled where they belong (the field's edit keymap; each
# modal's own loop). It never "shoots off into space" or opens a menu. Help is on h.
ft_esc_action() { return 0; }

# ft_run ROOT [setup] [resize] [fallback] [render]
#  setup    — runs after the tty is entered, before the first paint (build
#             your screen here; it may draw/flush itself).
#  resize   — SIGWINCH handler; default refits ROOT to the terminal.
#  fallback — called (with FT_EVENT_TOKEN/FT_EVENT_CHAR set) for tokens no keymap in the
#             cascade claimed; most apps don't need one.
#  render   — OPTIONAL retained-mode render callback. When given, handlers
#             that change what the screen should show call ft_invalidate
#             instead of rebuilding inline; the loop runs `render` ONCE after
#             each input burst. This is what makes holding a page-advance key
#             feel instant even though each press changes state — the costly
#             rebuild happens once, for the final state, not per keypress.
# A SHORTCUT THAT CANNOT FIRE IS INVISIBLE: the control keeps drawing its underlined letter and
# the key goes on doing something plausible instead. ft_accesskey_conflicts answers the question;
# this is what asks it, once, at startup — BEFORE the alt screen is entered, because stderr in a
# TUI is the screen the user is looking at. That places it before ft_run's `setup` callback runs,
# so a control built inside setup rather than at file scope is not covered; the tree an app
# declares is.
# Behind FT_DEBUG_KEYS=1 rather than always on: sharing a letter is a deliberate feature, so this
# is a thing you go looking for, like FT_DEBUG_NOALT.
_ft_report_key_conflicts() {
    [[ -n "${FT_DEBUG_KEYS:-}" ]] || return 0
    ft_accesskey_conflicts && return 0
    local line
    printf 'ft: accessKey conflicts — each of these letters is claimed by more than one\n' >&2
    printf '    control AND bound to something else, so the shortcut cannot reach them:\n' >&2
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        set -- $line
        printf '      %s advertises %s, but %s wins the key\n' "$1" "$2" "${*:3}" >&2
    done <<< "$FT_RET"
    return 1
}

ft_run() {
    local root=$1 setup=${2:-} resize=${3:-} fallback=${4:-} render=${5:-}
    FT_ROOT=$root
    _ft_report_key_conflicts
    ft_enter_tty
    ft_install_traps
    ft_start_input
    ft_input_ctl keys '*'

    [[ -n "$setup" ]] && "$setup"

    # Put the user back where they left off (see ft-state.bash). After setup, so it applies
    # onto the UI the app just built; before the first paint, so the opening frame already
    # shows the restored text, caret and focus rather than flashing the empty form first.
    (( ${FT_STATE_AUTOLOAD:-0} )) && declare -F ft_state_load >/dev/null && ft_state_load

    ft_redraw_all "$root"

    FT_RUN_ACTIVE=1
    local rc tok
    while (( FT_RUN_ACTIVE )); do
        ft_next_event; rc=$?
        if (( rc == 2 )); then
            FT_WINCH=0; ft_term_size
            if [[ -n "$resize" ]]; then
                "$resize"
            else
                _ft_setprop "$root" width "$FT_COLS"
                _ft_setprop "$root" height "$FT_ROWS"
                ft_layout "$root"
                ft_repaint_all "$root"
            fi
            continue
        elif (( rc != 0 )); then
            break
        fi
        # Coalesce a burst of input (a held key, a paste) into ONE render +
        # paint: dispatch this event and every one already queued behind it
        # with painting deferred, then settle once. This is what keeps holding
        # a page-advance key from stacking up N full rebuilds and repaints.
        FT_COALESCING=1
        FT_DEFER_ROOT=""
        FT_INVALIDATED=0
        while true; do
            # A confirmation stays up until the user does anything at all — no timer to
            # tune, and the same keypress that dismisses it is the one that repaints.
            # (`if`, not `&&`: a trailing false test is an app-killing exit status under
            # the `set -e` some hosts run with.)
            if [[ -n "$_FT_TOAST_MSG" ]]; then ft_toast_clear; fi
            if [[ "$FT_EVENT_TOKEN" == MOUSE ]]; then
                ft_reflow_flush             # hit-testing reads FT_ABS_*: settle geometry first
                _ft_dispatch_mouse
            else
                tok=$FT_EVENT_TOKEN
                [[ "$FT_EVENT_TOKEN" == CHAR ]] && tok=$FT_EVENT_CHAR
                if ! ft_dispatch_event "$tok"; then
                    # Esc opens the command menu (Help/Settings/About/Quit) via the
                    # form's own keymap, so it doesn't need handling here. F1 still
                    # opens help where the terminal passes it through (a bonus).
                    if   [[ "$FT_EVENT_TOKEN" == F1 ]] && declare -F ft_help >/dev/null; then ft_help
                    elif [[ "$FT_EVENT_TOKEN" == "CTRL+s" ]] && declare -F ft_state_save >/dev/null; then
                        # Ctrl+S at the TUI level: save the whole UI — every control's
                        # properties, which is where typed text lives, plus caret/scroll/focus.
                        # A control that wants Ctrl+S for itself binds it and never gets here.
                        ft_reflow_flush
                        if ft_state_save; then
                            _FT_SAVED_PATH=$FT_RET
                            _ft_hook "$root" on_save "$_FT_SAVED_PATH"
                            # SAY SO. Silence after a save is indistinguishable from a
                            # broken key — and name the file, so "where did it go?" is
                            # answered on screen instead of by hunting for a dotfile.
                            declare -F ft_emit_status >/dev/null && \
                                ft_emit_status saved "${_FT_SAVED_PATH/#${HOME:-/dev/null}/\~}"
                        else
                            _ft_hook "$root" on_save_failed
                            declare -F ft_emit_status >/dev/null && ft_emit_status saveFailed
                        fi
                    elif [[ "$FT_EVENT_TOKEN" == "CTRL+c" ]] && (( ${FT_CTRL_C_COPY:-0} )); then
                        # CTRL+C IS COPY. IT DOES NOT QUIT. It used to fall through to
                        # `exit 130` when nothing claimed it, which meant the most reflexive
                        # copy chord there is quit the program the moment a selection had not
                        # been made, or had been silently unmade — losing whatever the user
                        # was in the middle of. Reaching for copy must never be able to do
                        # that. Unclaimed, it says what to do instead and nothing else.
                        #
                        # The emergency escape is unaffected and was measured, not assumed
                        # (tests/escape-hatch.py): `isig` stays on, so Ctrl+\ raises SIGQUIT,
                        # and bash runs the QUIT trap even inside a tight builtin loop with no
                        # syscall to interrupt — a genuinely wedged app still exits 131 with
                        # the terminal restored. Quit also remains on the Esc menu.
                        declare -F ft_emit_status >/dev/null && ft_emit_status copyNothing
                    elif [[ "$FT_EVENT_TOKEN" == "CTRL+z" ]] && declare -F _ft_on_tstp >/dev/null; then
                        # Ctrl+Z reaches us as a KEY (ft_enter_tty frees it from the tty so a
                        # text field can bind it to undo). Nothing claimed it, so it means what
                        # it means everywhere else in a terminal: suspend.
                        ft_reflow_flush; _ft_on_tstp
                    elif [[ -n "$fallback" ]]; then "$fallback"; fi
                fi
            fi
            (( FT_RUN_ACTIVE )) || break
            if [[ -n "${FT_BURST_LOG:-}" ]]; then
                ft_now_ms; printf 'EV %s %s\n' "$FT_RET" "$FT_EVENT_TOKEN" >> "$FT_BURST_LOG"
            fi
            ft_poll_event || break         # no more queued input → done coalescing
        done
        FT_COALESCING=0
        if [[ -n "${FT_BURST_LOG:-}" ]]; then
            ft_now_ms; printf 'SETTLE-BEGIN %s\n' "$FT_RET" >> "$FT_BURST_LOG"
        fi
        ft_reflow_flush                    # …one layout for the burst, then one paint
        if [[ -n "$render" ]] && (( FT_INVALIDATED )); then
            FT_INVALIDATED=0
            "$render"                      # rebuild once for the final state (it draws)
        elif [[ -n "$FT_DEFER_ROOT" ]]; then
            local _tdr=""
            [[ -n "${FT_BURST_LOG:-}" ]] && { ft_now_ms; _tdr=$FT_RET; }
            ft_layout "$FT_DEFER_ROOT"     # ft_refresh deferred this out of the burst
            [[ -n "$_tdr" ]] && { ft_now_ms; printf 'STG refresh-layout %s\n' $(( FT_RET - _tdr )) >> "$FT_BURST_LOG"; _tdr=$FT_RET; }
            ft_repaint_all "$FT_DEFER_ROOT"
            [[ -n "$_tdr" ]] && { ft_now_ms; printf 'STG refresh-redraw-all %s\n' $(( FT_RET - _tdr )) >> "$FT_BURST_LOG"; }
            FT_DEFER_ROOT=""
        else
            ft_redraw_dirty
        fi
        if (( ${FT_BEACON_NARROW_OFF_AFTER:-0} )); then
            # a drag RELEASE ended inside this burst: its settle just painted under narrowed
            # repair; from the next frame on, repairs go back to the proven wide path
            FT_DAMAGE_NARROW=0; FT_BEACON_NARROW_OFF_AFTER=0
        fi
        if [[ -n "${FT_BURST_LOG:-}" ]]; then
            ft_now_ms; printf 'SETTLE-END %s\n' "$FT_RET" >> "$FT_BURST_LOG"
        fi
        # A confirmation may be the ONLY thing that changed this burst — Ctrl+S dirties no
        # control, so ft_redraw_dirty returns without painting and the message would sit in
        # a buffer nobody writes. An unpainted toast (no rect yet) forces the frame.
        if [[ -n "$_FT_TOAST_MSG" && -z "$_FT_TOAST_RECT" ]]; then ft_flush; fi
    done

    ft_restore_tty
}
