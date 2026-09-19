#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — ft-css.bash
#
#  A real CSS cascade for a terminal. We implement the CORE of CSS — selectors,
#  specificity, inheritance, custom properties, var() — and drop what a TTY can't
#  use. A "theme" is just a stylesheet (or a few); styling stops being a bolt-on
#  and becomes the property model.
#
#  This file is the ENGINE (parser + selector matcher + cascade resolver). It is
#  designed to be invisible until controls are switched to read through it: it adds
#  a source of property values BETWEEN inline props and inheritance, reusing the
#  existing store (_ft_setprop / _ft_get_raw for inline, FT_PARENT for ancestry).
#
#  ── The cascade (highest precedence first) ───────────────────────────────────
#    1. inline             a property set at the call site or later — _ft_get_raw
#    2. app sheets         targeted stylesheets, by CSS specificity then source order
#    3. inheritance        if the property inherits, the parent's RESOLVED value
#    4. default sheet      the user/agent default stylesheet (loses to everything above)
#    5. prototype default  the control's built-in last-resort value
#
#  ── Storage ──────────────────────────────────────────────────────────────────
#  A stylesheet is parsed into a FLAT list of rules (a `a, b { }` becomes two rules
#  sharing the declarations). Each rule i of sheet S is keyed "S<TAB>i":
#    FT_CSS_DECLARATIONS[key]   "prop:val;prop:val"      (props normalised to camelCase)
#    FT_CSS_SPECIFICITY[key]   specificity int (a*10000 + b*100 + c)
#    FT_CSS_ORDER[key]    source order (parse sequence, global) for stable tie-break
#    FT_CSS_SELECTOR_TYPE/KID/KCLASS/KPSEUDO/KPE[key]   the KEY (rightmost) compound, split
#    FT_CSS_SELECTOR_ANCESTORS[key]    ancestor compounds, newline-sep "type|id|classes|pseudos"
#  FT_CSS_RULE_COUNT[S] is S's rule count; FT_CSS_SHEETS lists registered sheets in order.
#
#  Depends on: ft-core.bash (colour fns), ft-forms.bash (property store, FT_PARENT).
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_CSS_LOADED:-}" ]] && return 0
_FT_CSS_LOADED=1

declare -A FT_CSS_RULE_COUNT=() FT_CSS_DECLARATIONS=() FT_CSS_SPECIFICITY=() FT_CSS_ORDER=() \
           FT_CSS_SELECTOR_TYPE=() FT_CSS_SELECTOR_ID=() FT_CSS_SELECTOR_CLASS=() FT_CSS_SELECTOR_PSEUDO_CLASS=() FT_CSS_SELECTOR_PSEUDO_ELEMENT=() FT_CSS_SELECTOR_ATTRIBUTE=() FT_CSS_SELECTOR_FUNCTION=() FT_CSS_SELECTOR_ANCESTORS=()
# ── Resolver memoisation ─────────────────────────────────────────────────────
# The cascade is O(sheets × rules) per lookup, and a single control draw makes DOZENS of
# lookups (colour/bg/weight + every structure's pseudo-element). So results are cached per
# (control, prop) and invalidated by a global EPOCH that bumps whenever anything a lookup
# depends on changes: a stylesheet (re)registers, the theme swaps, focus moves, or a control
# property changes. Within a stable period — e.g. every frame of an animation, which only
# advances a phase — the cache hits and the draw is cheap.
_FT_CSS_EPOCH=0
declare -A _FT_STYLE_C=() _FT_CSS_Q_C=() _FT_CSS_QPE_C=()
# The GLOBAL generation bumps only for changes that really do affect everyone — a stylesheet
# (re)registers, the theme swaps. A LOCAL change (one control's property/class/state) instead
# bumps a PER-NODE version, and the cache key carries both, so moving one callout no longer
# throws away every other control's resolved styles (the ~100ms recompute on each step).
# …and the resolved-property memo, for a reason particular to it: it only stores properties NO
# registered sheet declares, and registering one can make that false. A theme swap is the same
# event. (_FT_CLIP_GEN rides along here for the reason given at _ft_css_inval.)
_ft_css_bump() { (( _FT_CSS_EPOCH++ )); _FT_CLIP_GEN=$(( ${_FT_CLIP_GEN:-0} + 1 )); _ft_resolve_inval_all; }
declare -A _FT_CSS_VERSION=()       # name → style-cache version; bumped when a change can affect it
# 1 iff any registered sheet uses a selector whose match depends on SIBLINGS or DOCUMENT STRUCTURE
# (`+`/`~` combinators, :first/last/only/nth-* , :empty, :has). Such a selector lets a local change
# reach a sibling or an ancestor — beyond a subtree — so scoped invalidation would be UNSAFE; when
# set, _ft_css_inval conservatively falls back to a global bump (exactly the old behaviour). It is
# monotonic (once seen, stays on) and any structural sheet registers with a global bump anyway.
_FT_CSS_STRUCTURAL=0
# Invalidate NAME's resolved-style cache and its whole SUBTREE. Downward is exactly the right reach
# when no structural selectors are in play: a change to NAME can only alter NAME's own cascade and
# its DESCENDANTS' — they inherit from NAME (color/font/custom-props flow down) or match a
# `NAME-selector <descendant>` combinator. Ancestors and siblings are untouched, so adding a leaf
# overlay invalidates only itself and the rest of the screen keeps its warm cache. (An ANCESTOR
# changing still reaches this node, because that bump walks the ancestor's subtree, which includes
# it.) With structural selectors present a change could reach further, so we bump globally instead.
_ft_css_inval() {               # name
    # THE CLIP MEMO GOES TOO. _ft_inset4 and the overflow test that build a clip rect both
    # consult the sheet through _ft_gated_style, so a rule reaching an ancestor — `.wide {
    # padding: 4 }` arriving via `ft-modify win class=wide`, a theme swap, a :focus rule — moves
    # a descendant's rect. Bumping here rather than listing the properties that could do it
    # covers the whole cascade in one line, at the primitive every such change already calls.
    _FT_CLIP_GEN=$(( ${_FT_CLIP_GEN:-0} + 1 ))
    if (( _FT_CSS_STRUCTURAL )); then _ft_css_bump; return; fi
    local -a stk=("$1"); local n kid
    while (( ${#stk[@]} )); do
        n=${stk[-1]}; unset 'stk[-1]'
        _FT_CSS_VERSION[$n]=$(( ${_FT_CSS_VERSION[$n]:-0} + 1 ))
        for kid in ${FT_KIDS[$n]:-}; do stk+=("$kid"); done
    done
}
# …AND THE CASE THE SCOPED INVALIDATION ABOVE IS NEVER ASKED ABOUT AT ALL. `_ft_setprop` only
# calls it when `ft_css_prop_affects_style` says yes, and that asks whether any stylesheet
# DECLARES or MATCHES ON the property — which is the right question for the typing path (a
# textfield's `value`, restamped per keystroke, must not dirty a cascade) and the wrong one for
# `ft_style`, whose FIRST cascade level is the inline property itself. So a property no sheet
# has ever mentioned could be written with ft-modify and `ft_style` would go on serving the
# value from before the write, forever.
#
# Measured on the arrow's own `size`: `ft-modify a size=medium` then `size=x-small`
# and ft_style still answered `medium`. It was never specific to that property — every property
# `_ft_bigarrow_styled` reads (the three animation longhands, the border ones) has the same
# hole, and so does any app property a control resolves through the cascade.
#
# The fix is the narrowest thing that restores the invariant: drop the ONE memo entry for that
# node and that property. A non-inheriting property cannot reach any other node's cascade, so
# nothing else can be stale; an INHERITING one can, and that is what the subtree walk above is
# for, so this hands those straight to it.
_ft_css_inval_prop() {          # name prop — one property of one node changed
    if _ft_css_inherits "$2"; then _ft_css_inval "$1"; return; fi
    unset "_FT_STYLE_C[$1"$'\x1f'"$2]"
    unset "_FT_SGR_CACHE[$1]"
}
# ── Releasing a removed node's cached style ──────────────────────────────────
# Every style cache is keyed by NODE NAME (`_FT_CSS_VERSION[n]`, `_FT_SGR_CACHE[n]`, and the
# composite `n\x1f…` keys of _FT_STYLE_C / _FT_CSS_Q_C / _FT_CSS_QPE_C). ft_remove released a
# node's properties, side tables and line store but nothing here, so ~4 entries per control
# stayed forever: an app that creates and drops controls with FRESH names — a log appending
# rows, a list refilling — grew these tables without bound (measured: +200 entries per 50
# rows, linear, never reclaimed).
#
# THE VERSION TOKEN DID NOT MAKE A RECYCLED NAME SAFE, and this comment used to say it did.
# `_FT_CSS_VERSION[n]` was UNSET on removal, so the next control of the same name started again
# at 0 and climbed through the same values as it applied the same number of style-affecting
# properties — landing on a token the DEAD control's cache entry was already stored under.
# Measured, on nothing more exotic than a label:
#
#     ft-label name=lbl color=accent ; ft_style lbl color  →  accent   (version 3)
#     ft_remove lbl                                        →  version unset
#     ft-label name=lbl color=notice ; ft_style lbl color  →  accent   ← the DEAD one's
#
# and rebuilding a control under the same name is not exotic either: it is THE rebuild idiom
# this framework documents. So a forgotten name keeps its version and takes it one HIGHER —
# every entry the dead incarnation cached is now unreachable, whatever the new one does. The
# int stays until the next compaction, which drops the version and the composite entries in the
# same pass, so a name recreated after a sweep restarts at 0 with nothing stale to collide with.
# That is one integer per recycled name, bounded by FT_CSS_SWEEP_AFTER — which is the bounded
# behaviour this function was written for in the first place.
#
# Scanning the composite caches on every removal would be O(cache) per control, turning a
# 50-row refresh into 50 full scans of a table that exists to make painting fast. So the O(1)
# part happens per removal and the scan is AMORTISED: after enough removals, sweep once and
# drop every entry whose node no longer exists. An entry for a dead node can never become
# valid again, so a late sweep is only memory, never wrongness.
_FT_CSS_DEAD=0
: "${FT_CSS_SWEEP_AFTER:=64}"   # removals to accumulate before one compaction pass
ft_css_forget() {               # name — called by ft_remove
    _FT_CSS_VERSION[$1]=$(( ${_FT_CSS_VERSION[$1]:-0} + 1 ))   # NOT unset — see above
    unset "_FT_SGR_CACHE[$1]" "_FT_CSS_ANIM_FG[$1]" "_FT_CSS_ANIM_FG_AT[$1]"
    (( ++_FT_CSS_DEAD >= FT_CSS_SWEEP_AFTER )) && _ft_css_compact
    return 0
}
_ft_css_compact() {             # drop cached style for every node that is gone
    _FT_CSS_DEAD=0
    local k n
    for k in "${!_FT_STYLE_C[@]}";  do n=${k%%$'\x1f'*}; [[ -n "${FT_TYPE[$n]:-}" ]] || unset "_FT_STYLE_C[$k]"; done
    for k in "${!_FT_CSS_Q_C[@]}";  do n=${k%%$'\x1f'*}; [[ -n "${FT_TYPE[$n]:-}" ]] || unset "_FT_CSS_Q_C[$k]"; done
    for k in "${!_FT_CSS_QPE_C[@]}"; do n=${k%%$'\x1f'*}; [[ -n "${FT_TYPE[$n]:-}" ]] || unset "_FT_CSS_QPE_C[$k]"; done
    for k in "${!_FT_SGR_CACHE[@]}"; do [[ -n "${FT_TYPE[$k]:-}" ]] || unset "_FT_SGR_CACHE[$k]"; done
    for k in "${!_FT_CSS_ANIM_FG[@]}"; do
        [[ -n "${FT_TYPE[$k]:-}" ]] || unset "_FT_CSS_ANIM_FG[$k]" "_FT_CSS_ANIM_FG_AT[$k]"; done
    for k in "${!_FT_CSS_VERSION[@]}";   do [[ -n "${FT_TYPE[$k]:-}" ]] || unset "_FT_CSS_VERSION[$k]"; done
    # The resolved-property memo is composite-keyed the same way and grows the same way, so it is
    # reclaimed in the same pass and under the same argument: its version goes only when every
    # entry that could collide with a restart at 0 has gone with it, in this one sweep.
    for k in "${!_FT_RESOLVED_PROP_MEMO[@]}"; do n=${k%%$'\x1f'*}
        [[ -n "${FT_TYPE[$n]:-}" ]] || unset "_FT_RESOLVED_PROP_MEMO[$k]" "_FT_RESOLVED_PROP_MEMO_AT[$k]"; done
    for k in "${!_FT_RESOLVE_VERSION[@]}"; do [[ -n "${FT_TYPE[$k]:-}" ]] || unset "_FT_RESOLVE_VERSION[$k]"; done
    return 0
}

# ── Rule index: prune the cascade lookup from O(all rules) to O(candidates) ───
# A resolver lookup only needs the rules whose KEY (rightmost) compound could match this element —
# so rules are bucketed at registration by that compound's most-selective part (#id, else first
# .class, else type), with a UNIVERSAL bucket for rules that key on none of those (:root, *,
# attribute/pseudo-only). A lookup gathers just the element's id/class/type buckets + universal and
# runs the EXACT SAME match/specificity/source-order logic over that short list. Without this every
# lookup walks every rule — measured perfectly LINEAR in rule count (~0.2ms/rule), i.e. an app with
# a real stylesheet grinds to a halt. Rebuilt wholesale on any (re)registration (rare, not hot).
declare -A _FT_CSS_IDX_ID=() _FT_CSS_IDX_CLASS=() _FT_CSS_IDX_TYPE=()
_FT_CSS_IDX_UNIV=""
_ft_css_reindex() {             # rebuild the key-selector buckets from every registered sheet
    _FT_CSS_IDX_ID=(); _FT_CSS_IDX_CLASS=(); _FT_CSS_IDX_TYPE=(); _FT_CSS_IDX_UNIV=""
    local sheet n i key kid kcl kty
    for sheet in "${FT_CSS_SHEETS[@]}"; do
        n=${FT_CSS_RULE_COUNT[$sheet]:-0}
        for (( i=0; i<n; i++ )); do
            key="$sheet"$'\t'"$i"
            kid=${FT_CSS_SELECTOR_ID[$key]:-}; kcl=${FT_CSS_SELECTOR_CLASS[$key]:-}; kty=${FT_CSS_SELECTOR_TYPE[$key]:-}
            if   [[ -n "$kid" ]]; then _FT_CSS_IDX_ID[$kid]+="$key "
            elif [[ -n "$kcl" ]]; then _FT_CSS_IDX_CLASS[${kcl%% *}]+="$key "   # its first class — a match needs it
            elif [[ -n "$kty" ]]; then _FT_CSS_IDX_TYPE[$kty]+="$key "
            else _FT_CSS_IDX_UNIV+="$key "; fi
        done
    done
}
# Which control PROPERTIES a resolver lookup can depend on. Setting any OTHER property (e.g. a
# text field's `value`, restamped on every keystroke) must NOT invalidate the cache, or rapid
# typing thrashes it and every redraw pays the full uncached cascade. Two sources:
#  • STYLE props read by the styling path (inline overrides at cascade level 1), a fixed set;
#  • MATCH props a selector actually tests (class + whatever :checked/[attr]/… reference),
#    accumulated from the stylesheets as they register (so `value` only counts when a rule
#    really uses :checked / [value]). `--*` custom properties always count (var()).
declare -A _FT_CSS_STYLE_PROPS=(
    [color]=1 [backgroundColor]=1 [borderColor]=1 [borderStyle]=1 [fontWeight]=1 [fontStyle]=1
    [textDecoration]=1 [textAlign]=1 [cursor]=1 [visibility]=1
    [animation]=1 [animationDuration]=1 [animationTimingFunction]=1 [animationDelay]=1 [opacity]=1
)
declare -A _FT_CSS_MATCH_PROPS=([class]=1 [id]=1)   # #id / .class selectors test these → changing them re-cascades
# ── What any registered sheet actually DECLARES ──────────────────────────────
# Accumulated as rules parse, exactly like _FT_CSS_MATCH_PROPS above and for the same reason:
# the parser is the only place that knows. It is NOT _FT_CSS_STYLE_PROPS, which is a FIXED set
# of fifteen paint properties the styling path reads — a distinction worth stating, because the
# gate below was designed against that name on the assumption it accumulated, and it does not.
#
# THIS IS THE GATE THE LAYOUT ASKS. The layout resolves through ft_resolved_prop and the raw fast paths,
# and consulting the cascade for every property on the hottest path in the framework is not
# affordable. Consulting it for the properties a sheet MENTIONS is: an app with no layout rules
# has no layout properties in here, so the gate never opens and a read costs one assoc lookup.
#
# MONOTONIC ON PURPOSE. A property stays once seen, even if the rule that mentioned it is
# replaced. That cannot be wrong, only slower — the cascade is consulted and answers with the
# same prototype default it would have answered without being asked — and it keeps re-registering a
# sheet from having to diff two sets. _FT_CSS_MATCH_PROPS has always worked this way.
declare -A _FT_CSS_DECLARED_PROPS=()
# ft_css_prop_affects_style PROP RAWPROP → 0 if setting it can change a resolved value.
ft_css_prop_affects_style() {   # normalisedprop rawprop
    # `disabled` is ALWAYS style-affecting, whether or not any selector mentions it. The
    # framework dims a disabled control — and, since `disabled` inherits, its whole subtree —
    # in _ft_compose_sgr, entirely outside CSS. Deciding invalidation purely from what the
    # STYLESHEET matches on therefore missed it: an app with no `:disabled` rule (i.e. most
    # apps) could disable a control and see NOTHING change on screen, because the composed SGR
    # stayed in _FT_SGR_CACHE until some unrelated change happened to bump the key.
    [[ "$2" == --* || "$1" == disabled \
       || -n "${_FT_CSS_STYLE_PROPS[$1]:-}" || -n "${_FT_CSS_MATCH_PROPS[$1]:-}" ]]
}
# Record, from a just-parsed compound (globals _FT_CSS_COMPOUND_CLASS/_FT_CSS_COMPOUND_PSEUDO_CLASS/_FT_CSS_COMPOUND_ATTRIBUTE/_FT_CSS_COMPOUND_FUNCTION), which control
# properties its selectors test — so _ft_setprop knows when a change matters.
_ft_css_note_match_props() {
    [[ -n "$_FT_CSS_COMPOUND_CLASS" ]] && _FT_CSS_MATCH_PROPS[class]=1
    # Which property each pseudo-class reads comes from the STATE REGISTRY, not a list here —
    # so a state declared by a control prototype (a runlevel) is tracked for invalidation the
    # moment it is declared, with nothing to keep in step.
    local x p
    for x in $_FT_CSS_COMPOUND_PSEUDO_CLASS; do
        for p in ${FT_STATE_DEPENDS_ON[$x]:-}; do _FT_CSS_MATCH_PROPS[$p]=1; done
    done
    if [[ -n "$_FT_CSS_COMPOUND_ATTRIBUTE" ]]; then local IFS=$'\n'
        for x in $_FT_CSS_COMPOUND_ATTRIBUTE; do [[ "$x" =~ ^([a-zA-Z_][a-zA-Z0-9_-]*) ]] && _FT_CSS_MATCH_PROPS[${BASH_REMATCH[1]}]=1; done
    fi
    # :not()/:is()/:has() args may test anything — mark every property any state reads
    # (cheap, rare, and now complete rather than a hand-kept list of three).
    if [[ -n "$_FT_CSS_COMPOUND_FUNCTION" ]]; then
        for x in "${!FT_STATE_DEPENDS_ON[@]}"; do
            for p in ${FT_STATE_DEPENDS_ON[$x]}; do _FT_CSS_MATCH_PROPS[$p]=1; done
        done
        # …and an ATTRIBUTE written INSIDE those parentheses is a dependency exactly as it is
        # outside them. Only bare attributes were scanned, so `:not([runlevel=unfocused])` was
        # parsed, matched and cascaded perfectly — and then never invalidated, because a write
        # to `runlevel` was not recognised as affecting anything. The cached style outlived the
        # change, so the state was correct everywhere except on screen. `:enabled` is the same
        # shape (`:not([disabled=true])`) and had the same hole.
        local _fnarg=$_FT_CSS_COMPOUND_FUNCTION
        while [[ "$_fnarg" =~ \[([a-zA-Z_][a-zA-Z0-9_-]*) ]]; do
            _FT_CSS_MATCH_PROPS[${BASH_REMATCH[1]}]=1
            _fnarg=${_fnarg#*"[${BASH_REMATCH[1]}"}
        done
    fi
    # STRUCTURAL selectors — a structural pseudo-class on the compound, or :has()/a structural
    # keyword inside a functional pseudo — mean a match can flip from a sibling/structure change,
    # which a subtree invalidation can't reach. Flag it so _ft_css_inval falls back to a global bump.
    for x in $_FT_CSS_COMPOUND_PSEUDO_CLASS; do case $x in
        first-child|last-child|only-child|nth-child|nth-last-child|first-of-type|last-of-type|only-of-type|nth-of-type|nth-last-of-type|empty) _FT_CSS_STRUCTURAL=1 ;;
    esac; done
    case "$_FT_CSS_COMPOUND_FUNCTION" in *has*|*child*|*of-type*|*nth*|*empty*) _FT_CSS_STRUCTURAL=1 ;; esac
}

declare -A FT_CSS_KEYFRAMES=()     # @keyframes NAME → interpolated fg-colour ramp ("r,g,b r,g,b …")
declare -A FT_CSS_KEYFRAMES_BACKGROUND=()  # …its background-color ramp (if any stop sets one)
declare -A FT_CSS_KEYFRAMES_WEIGHT=()  # …its font-weight ramp (stepped: "bold normal …")
declare -A FT_CSS_KEYFRAMES_OPACITY=()  # …its opacity ramp (0-100 ints; dims the fg toward the background)
declare -A FT_CSS_KEYFRAMES_SOURCE=() # …its raw body (kept so a var() keyframe can resolve per-element)
declare -A FT_CSS_KEYFRAMES_VAR=() # …1 if the body uses var() ⇒ its ramps resolve PER-ELEMENT
# Per (control<US>name) resolved-ramp cache for var() keyframes — so `#a { --x: red }` and
# `#b { --x: blue }` on the same @keyframes each get their OWN ramp, exactly like real CSS.
# Invalidated by the epoch (theme swap / prop change); free during an animation (epoch stable).
declare -A _FT_KF_FG=() _FT_KF_BG=() _FT_KF_WT=() _FT_KF_OP=() _FT_KF_E=()
FT_CSS_SHEETS=()          # registered sheet names, in registration order
_FT_CSS_SEQ=0             # global parse sequence → source-order tie-break

# ── kebab-case ⇄ camelCase ───────────────────────────────────────────────────
# CSS spells properties kebab-case (background-color); a constructor arg spells them
# camelCase (backgroundColor). They are the SAME property — normalise to camelCase,
# the key the rest of the engine (and _ft_setprop) uses. A leading `--` (custom
# property) is preserved verbatim EXCEPT the engine stores it under a bash-safe key
# (see _ft_css_varkey) since `--x` is not a legal shell-var component.
_ft_css_camel() {               # kebab → FT_RET camelCase (custom props pass through)
    local s=$1
    case $s in
        --*) FT_RET=$s; return ;;                 # custom property: keep --name
        *-*) : ;;                                 # has a dash → convert
        *)   FT_RET=$s; return ;;                 # already camel/plain
    esac
    local out="" i ch up=0
    for (( i=0; i<${#s}; i++ )); do
        ch=${s:i:1}
        if [[ "$ch" == "-" ]]; then up=1; continue; fi
        (( up )) && { out+=${ch^^}; up=0; } || out+=$ch
    done
    FT_RET=$out
}

# ── Comment stripping ─────────────────────────────────────────────────────────
# Remove /* … */ NON-greedily (bash // is greedy and would eat everything between
# the first /* and the LAST */). Peel one comment at a time, shortest-first.
_ft_css_strip_comments() {      # css → FT_RET
    local s=$1 before after rest
    while [[ "$s" == *'/*'* ]]; do
        before=${s%%'/*'*}          # text before the first /*
        rest=${s#*'/*'}             # everything after that /*
        if [[ "$rest" == *'*/'* ]]; then after=${rest#*'*/'}; else after=""; fi
        s="$before$after"
    done
    FT_RET=$s
}

# ── Compound-selector parse ──────────────────────────────────────────────────
# "type#id.a.b:focus::pe" → the five parts. Fork-free char scan: a delimiter
# (# . : ::) flushes the token accumulated so far into the CURRENT part, then
# switches part. `*` (universal) is recorded as an empty type (matches anything).
_ft_css_compound() {            # str → _FT_CSS_COMPOUND_TYPE _FT_CSS_COMPOUND_ID _FT_CSS_COMPOUND_CLASS _FT_CSS_COMPOUND_PSEUDO_CLASS _FT_CSS_COMPOUND_PSEUDO_ELEMENT _FT_CSS_COMPOUND_ATTRIBUTE _FT_CSS_COMPOUND_FUNCTION (globals)
    local s=$1; local n=${#s} i ch mode=type cur="" depth=0 fnname=""   # n=${#s} its own statement
    _FT_CSS_COMPOUND_TYPE="" _FT_CSS_COMPOUND_ID="" _FT_CSS_COMPOUND_CLASS="" _FT_CSS_COMPOUND_PSEUDO_CLASS="" _FT_CSS_COMPOUND_PSEUDO_ELEMENT="" _FT_CSS_COMPOUND_ATTRIBUTE="" _FT_CSS_COMPOUND_FUNCTION=""
    for (( i=0; i<=n; i++ )); do
        (( i < n )) && ch=${s:i:1} || ch=$'\x1f'
        if [[ "$mode" == attr ]]; then                # inside [ … ] — # . : don't split here
            if [[ "$ch" == "]" ]]; then [[ -n "$cur" ]] && _FT_CSS_COMPOUND_ATTRIBUTE+="${_FT_CSS_COMPOUND_ATTRIBUTE:+$'\n'}$cur"; cur=""; mode=type
            else cur+=$ch; fi; continue
        fi
        if [[ "$mode" == fn ]]; then                  # inside :name( … ) — track paren nesting
            case $ch in
                '(') (( depth++ )); cur+=$ch ;;
                ')') if (( --depth == 0 )); then _FT_CSS_COMPOUND_FUNCTION+="${_FT_CSS_COMPOUND_FUNCTION:+$'\n'}${fnname}"$'\t'"$cur"; cur=""; mode=type; else cur+=$ch; fi ;;
                *)   cur+=$ch ;;
            esac; continue
        fi
        case $ch in
            '(')  if [[ "$mode" == pseudo ]]; then fnname=$cur; cur=""; mode=fn; depth=1; else cur+=$ch; fi ;;
            '['|'#'|'.'|':'|$'\x1f')
                case $mode in                         # flush the token accumulated so far
                    type)   [[ "$cur" == "*" || -z "$cur" ]] || _FT_CSS_COMPOUND_TYPE=$cur ;;
                    id)     _FT_CSS_COMPOUND_ID=$cur ;;
                    class)  [[ -n "$cur" ]] && _FT_CSS_COMPOUND_CLASS+="${_FT_CSS_COMPOUND_CLASS:+ }$cur" ;;
                    pseudo) [[ -n "$cur" ]] && _FT_CSS_COMPOUND_PSEUDO_CLASS+="${_FT_CSS_COMPOUND_PSEUDO_CLASS:+ }$cur" ;;   # simple :pseudo
                    pe)     _FT_CSS_COMPOUND_PSEUDO_ELEMENT=$cur ;;
                esac
                cur=""
                case $ch in
                    '[') mode=attr ;;
                    '#') mode=id ;;
                    '.') mode=class ;;
                    ':') if [[ "${s:i+1:1}" == ":" ]]; then mode=pe; (( i++ )); else mode=pseudo; fi ;;
                esac ;;
            *) cur+=$ch ;;
        esac
    done
}

# specificity as a single int (ids·10000 + classes/attrs/pseudo-classes·100 + types/elements).
# Attribute selectors count like a class; :not()/:is()/:has() take the specificity of their
# most-specific argument; :where() contributes nothing; other functional pseudos count as one.
_ft_css_specificity() {         # "compound compound …" → FT_RET int
    local chain=$1 total=0 comp x fn fnname fnarg sub best
    _ft_css_split_chain "$chain"                 # bracket-aware: keeps :is(a, b) & [x~=y] whole
    local -a comps=("${_CHAIN_TOKS[@]}")         # copy before any recursion clobbers _CHAIN_TOKS
    for comp in "${comps[@]}"; do
        [[ -z "$comp" || "$comp" == '>' || "$comp" == '+' || "$comp" == '~' ]] && continue
        _ft_css_compound "$comp"
        [[ -n "$_FT_CSS_COMPOUND_ID" ]]   && (( total += 10000 ))
        [[ -n "$_FT_CSS_COMPOUND_TYPE" ]] && (( total += 1 ))
        [[ -n "$_FT_CSS_COMPOUND_PSEUDO_ELEMENT" ]]   && (( total += 1 ))
        for x in $_FT_CSS_COMPOUND_CLASS;  do (( total += 100 )); done
        for x in $_FT_CSS_COMPOUND_PSEUDO_CLASS; do (( total += 100 )); done
        # IFS is `local` here so it restores on return; keep it at the default whenever we
        # recurse (a stray IF=',' would break class-splitting inside the recursive call).
        local defIFS=$' \t\n'; local IFS=$'\n'; local -a attrs=($_FT_CSS_COMPOUND_ATTRIBUTE) fns=($_FT_CSS_COMPOUND_FUNCTION); IFS=$defIFS
        for x in "${attrs[@]}"; do [[ -n "$x" ]] && (( total += 100 )); done
        for fn in "${fns[@]}"; do
            [[ -z "$fn" ]] && continue
            fnname=${fn%%$'\t'*}; fnarg=${fn#*$'\t'}
            case $fnname in
                where) ;;
                not|is|has)                           # + the most-specific selector in the arg list
                    best=0; IFS=','; local -a subs=($fnarg); IFS=$defIFS
                    for sub in "${subs[@]}"; do
                        sub="${sub#"${sub%%[![:space:]]*}"}"; sub="${sub%"${sub##*[![:space:]]}"}"
                        [[ -z "$sub" ]] && continue
                        _ft_css_specificity "$sub"; (( FT_RET > best )) && best=$FT_RET
                    done
                    (( total += best )) ;;
                *) (( total += 100 )) ;;
            esac
        done
    done
    FT_RET=$total
}

# ── Parse a stylesheet string into the registry ──────────────────────────────
# Top-level scan: accumulate a selector-list until '{', a body until '}'. A selector
# beginning with `@keyframes` opens a NESTED block (its body has its own `{…}` stops),
# consumed by brace depth and handed to _ft_css_add_keyframes. Each ordinary selector in
# the list becomes its own flat rule sharing the body's declarations.
_ft_css_parse() {               # sheet cssText
    local sheet=$1 css
    _ft_css_bump                # a stylesheet changed → the resolver cache is stale
    _ft_css_strip_comments "$2"; css=$FT_RET
    FT_CSS_RULE_COUNT[$sheet]=0
    # SPLIT ON BRACES; DO NOT WALK CHARACTERS. This was `for (( i=0; i<n; i++ ))` reading
    # ${css:i:1}, and that substring extraction is O(i) in bash — so the parser was QUADRATIC
    # in the length of the sheet. Measured before: 10 rules 20ms, 80 rules 322ms, 320 rules
    # 3.7 SECONDS, cost per rule climbing 2.0 → 11.5ms. The bundled theme (33 rules) was 152ms
    # of every single startup. Parameter expansion does the same scanning inside bash at C
    # speed, once per RULE instead of once per character.
    #
    # Nested braces occur only inside @keyframes, which keeps the depth counter; everywhere
    # else a rule is exactly "…{…}".
    local sel body trimmed brace chunk depth
    while [[ "$css" == *'{'* ]]; do
        sel=${css%%\{*}; css=${css#*\{}
        trimmed=${sel#"${sel%%[![:space:]]*}"}
        if [[ "$trimmed" == @keyframes* ]]; then
            # Find whichever brace comes first, by measuring the run up to each SEPARATELY.
            # NB: the obvious `${css%%[{}]*}` does not work — an unescaped `}` inside a
            # ${…} pattern CLOSES THE EXPANSION, so that reads as ${css%%[{} followed by the
            # literal text `]*}`, and the loop silently consumed the whole sheet on its first
            # pass. Every rule after a @keyframes block was dropped.
            body=""; depth=1
            local upto_open upto_close n_open n_close
            while (( depth > 0 )); do
                upto_open=${css%%\{*};  n_open=${#upto_open}
                upto_close=${css%%\}*}; n_close=${#upto_close}
                [[ "$upto_open"  == "$css" ]] && n_open=-1      # no '{' left
                [[ "$upto_close" == "$css" ]] && n_close=-1     # no '}' left
                if (( n_close < 0 )); then body+=$css; css=""; break; fi   # unbalanced sheet
                if (( n_open >= 0 && n_open < n_close )); then
                    (( depth++ )); body+="$upto_open{"; css=${css:n_open+1}
                else
                    (( depth-- ))
                    if (( depth > 0 )); then body+="$upto_close}"; else body+="$upto_close"; fi
                    css=${css:n_close+1}
                fi
            done
            _ft_css_add_keyframes "$trimmed" "$body"
        else
            body=${css%%\}*}; css=${css#*\}}
            _ft_css_add_rules "$sheet" "$sel" "$body"
        fi
    done
}
# @keyframes NAME { from|0% { color:…; background-color:…; font-weight:…; opacity:… } … }.
# Its raw body is STORED. A keyframe with no var() is resolved ONCE (its stops are concrete)
# into the shared global ramps; one that uses var() is resolved PER-ELEMENT on use, so an
# element's own custom property overrides the inherited :root value — exactly like real CSS.
_ft_css_add_keyframes() {       # "@keyframes NAME" innerbody
    local name=${1#@keyframes}; name=${name#"${name%%[![:space:]]*}"}; name=${name%"${name##*[![:space:]]}"}
    [[ -z "$name" ]] && return
    FT_CSS_KEYFRAMES_SOURCE[$name]=$2
    if [[ "$2" == *var\(* ]]; then
        FT_CSS_KEYFRAMES_VAR[$name]=1              # themeable / per-element → resolved lazily, per control
        unset "FT_CSS_KEYFRAMES[$name]" "FT_CSS_KEYFRAMES_BACKGROUND[$name]" "FT_CSS_KEYFRAMES_WEIGHT[$name]" "FT_CSS_KEYFRAMES_OPACITY[$name]"
    else
        unset "FT_CSS_KEYFRAMES_VAR[$name]"        # concrete → resolve once; every element shares it
        FT_TYPE[__ft_kf_root]=""; FT_PARENT[__ft_kf_root]=""
        _ft_css_kf_parse_ramps __ft_kf_root "$name"
        [[ -n "$_KF_FG" ]] && FT_CSS_KEYFRAMES[$name]=$_KF_FG    || unset "FT_CSS_KEYFRAMES[$name]"
        [[ -n "$_KF_BG" ]] && FT_CSS_KEYFRAMES_BACKGROUND[$name]=$_KF_BG || unset "FT_CSS_KEYFRAMES_BACKGROUND[$name]"
        [[ -n "$_KF_WT" ]] && FT_CSS_KEYFRAMES_WEIGHT[$name]=$_KF_WT || unset "FT_CSS_KEYFRAMES_WEIGHT[$name]"
        [[ -n "$_KF_OP" ]] && FT_CSS_KEYFRAMES_OPACITY[$name]=$_KF_OP || unset "FT_CSS_KEYFRAMES_OPACITY[$name]"
    fi
}
# Parse NAME's body, resolving each stop's var() against CONTROL (the element the animation
# runs on — its own --x wins, else the inherited :root value), and interpolate into the
# TRANSIENT ramps _KF_FG/_KF_BG/_KF_WT/_KF_OP.
_ft_css_kf_parse_ramps() {      # control name → _KF_FG _KF_BG _KF_WT _KF_OP
    local control=$1 name=$2; local body=${FT_CSS_KEYFRAMES_SOURCE[$name]:-}
    local n=${#body} i ch sel="" decls="" st=sel
    local -a c_off=() c_val=() b_off=() b_val=() w_off=() w_val=() o_off=() o_val=()
    for (( i=0; i<n; i++ )); do
        ch=${body:i:1}
        if [[ "$st" == sel ]]; then
            if [[ "$ch" == "{" ]]; then st=decl; decls=""; else sel+=$ch; fi
        else
            if [[ "$ch" == "}" ]]; then
                _ft_css_norm_decls "$decls"; local nd=$FT_RET
                _ft_css_decl_get "$nd" color;           local cv=$FT_RET
                _ft_css_decl_get "$nd" backgroundColor; local bv=$FT_RET
                _ft_css_decl_get "$nd" fontWeight;      local wv=$FT_RET
                _ft_css_decl_get "$nd" opacity;         local ov=$FT_RET
                [[ "$cv" == *var\(* ]] && { _ft_css_resolve_value "$control" "$cv"; cv=$FT_RET; }
                [[ "$bv" == *var\(* ]] && { _ft_css_resolve_value "$control" "$bv"; bv=$FT_RET; }
                [[ "$ov" == *var\(* ]] && { _ft_css_resolve_value "$control" "$ov"; ov=$FT_RET; }
                [[ -n "$ov" ]] && { _ft_css_opacity_pct "$ov"; ov=$FT_RET; }
                local off _IFS=$IFS; IFS=','
                for off in $sel; do                         # SELECTOR may be "from, 0%" (shared block)
                    off=${off//[[:space:]]/}
                    case $off in from) off=0 ;; to) off=100 ;; *%) off=${off%\%} ;; esac
                    [[ "$off" =~ ^[0-9]+$ ]] || continue
                    [[ -n "$cv" ]] && { c_off+=("$off"); c_val+=("$cv"); }
                    [[ -n "$bv" ]] && { b_off+=("$off"); b_val+=("$bv"); }
                    [[ -n "$wv" ]] && { w_off+=("$off"); w_val+=("$wv"); }
                    [[ -n "$ov" ]] && { o_off+=("$off"); o_val+=("$ov"); }
                done
                IFS=$_IFS; sel=""; st=sel
            else decls+=$ch; fi
        fi
    done
    _ft_css_kf_ramp     c_off c_val; _KF_FG=$FT_RET
    _ft_css_kf_ramp     b_off b_val; _KF_BG=$FT_RET
    _ft_css_kf_step     w_off w_val; _KF_WT=$FT_RET
    _ft_css_kf_num_ramp o_off o_val; _KF_OP=$FT_RET
}
# Set the transient ramps for NAME as it applies to CONTROL: the shared globals for a concrete
# keyframe, else the per-(control,name) epoch-cached resolve (rebuilt only when the cascade
# changed — free during an animation).
_ft_css_kf_for() {              # control name → _KF_FG _KF_BG _KF_WT _KF_OP
    local control=$1 name=$2
    if [[ -z "${FT_CSS_KEYFRAMES_VAR[$name]:-}" ]]; then
        _KF_FG=${FT_CSS_KEYFRAMES[$name]:-}; _KF_BG=${FT_CSS_KEYFRAMES_BACKGROUND[$name]:-}
        _KF_WT=${FT_CSS_KEYFRAMES_WEIGHT[$name]:-}; _KF_OP=${FT_CSS_KEYFRAMES_OPACITY[$name]:-}; return
    fi
    local ck="$control"$'\x1f'"$name" kftok="$_FT_CSS_EPOCH:${_FT_CSS_VERSION[$control]:-0}"
    if [[ "${_FT_KF_E[$ck]:-x}" == "$kftok" ]]; then
        _KF_FG=${_FT_KF_FG[$ck]:-}; _KF_BG=${_FT_KF_BG[$ck]:-}
        _KF_WT=${_FT_KF_WT[$ck]:-}; _KF_OP=${_FT_KF_OP[$ck]:-}; return
    fi
    _ft_css_kf_parse_ramps "$control" "$name"
    _FT_KF_FG[$ck]=$_KF_FG; _FT_KF_BG[$ck]=$_KF_BG; _FT_KF_WT[$ck]=$_KF_WT; _FT_KF_OP[$ck]=$_KF_OP
    _FT_KF_E[$ck]=$kftok
}
# A CSS opacity value → 0-100 int. "1"→100, "0.5"→50, "0"→0, "50%"→50, ".4"→40.
_ft_css_opacity_pct() {         # value → FT_RET
    local v=$1; FT_RET=100; [[ -z "$v" ]] && return
    if [[ "$v" == *% ]]; then v=${v%\%}; [[ "$v" =~ ^[0-9]+$ ]] && FT_RET=$v; (( FT_RET>100 )) && FT_RET=100; return; fi
    local ip=${v%%.*} fp=""; [[ "$v" == *.* ]] && fp=${v#*.}
    [[ "${ip:-0}" =~ ^[0-9]*$ && "${fp:-0}" =~ ^[0-9]*$ ]] || return
    fp=${fp}00; fp=${fp:0:2}
    FT_RET=$(( 10#${ip:-0}*100 + 10#${fp:-0} )); (( FT_RET>100 )) && FT_RET=100
}
# ── One stop table, one sampling rule, three ramps ───────────────────────────
# The three ramp builders below (colour, numeric, stepped) differ ONLY in what they emit per
# sample. Everything before that — put the stops in offset order, and decide how many samples a
# segment gets — was written out three times, character for character. They are not free to
# drift apart either: _ft_css_kf_compose indexes every ramp of one @keyframes block as
# `phase % length`, so the three MUST come out the same length for the same stop offsets.
# Patching the density in one of them (tried, to see what it costs) desynchronised colour from
# weight at once — at phase 24 the colour had wrapped to sample 11 while the weight sat on its
# last. So the shared halves live in one place each.
#
# This is parse-time code — the concrete case runs once at _ft_css_add_keyframes, the var() case
# is epoch-cached per (control, name) in _ft_css_kf_for — so the "mirror the arms rather than
# call a function" argument that justifies duplication on a paint path does not apply here.

# THE STOPS, IN OFFSET ORDER. A @keyframes block's stops arrive in source order and a ramp has
# to walk them by offset, so `to {} from {}` reads the same as `from {} to {}`. Sorted IN PLACE
# through the caller's own arrays (a handful of stops — an insertion sort is the right size).
_ft_css_kf_sort_stops() {       # offsetsArrayName valuesArrayName → FT_RET = the stop count
    local -n _offsets=$1 _values=$2
    local count=${#_offsets[@]} a b swap
    for (( a=1; a<count; a++ )); do
        for (( b=a; b>0; b-- )); do
            (( _offsets[b] < _offsets[b-1] )) || break
            swap=${_offsets[b]}; _offsets[b]=${_offsets[b-1]}; _offsets[b-1]=$swap
            swap=${_values[b]};  _values[b]=${_values[b-1]};   _values[b-1]=$swap
        done
    done
    FT_RET=$count
}
# HOW MANY SAMPLES ONE SEGMENT GETS. The density is samples per whole 0-100 cycle: a segment
# spanning half the cycle gets half of them. Never fewer than one, or two stops at the same
# offset would contribute nothing and the ramp would be shorter than its siblings'.
# (docs/transitions.md notes that a move to a gamma-correct space belongs here.)
FT_CSS_KEYFRAME_DENSITY=24
_ft_css_kf_segment_steps() {    # fromOffset toOffset → FT_RET
    FT_RET=$(( ($2 - $1) * FT_CSS_KEYFRAME_DENSITY / 100 ))
    (( FT_RET < 1 )) && FT_RET=1
    return 0
}

# Interpolate a NUMERIC (non-colour) property ramp — like _ft_css_kf_ramp but 1-D (opacity).
_ft_css_kf_num_ramp() {         # offsetsArrayName valuesArrayName → FT_RET
    _ft_css_kf_sort_stops "$1" "$2"; local m=$FT_RET
    (( m == 0 )) && { FT_RET=""; return; }
    local -n _o=$1 _v=$2
    if (( m == 1 )); then FT_RET=${_v[0]}; return; fi
    local ramp="" k v1 v2 steps s
    for (( k=0; k<m-1; k++ )); do
        v1=${_v[k]}; v2=${_v[k+1]}
        _ft_css_kf_segment_steps "${_o[k]}" "${_o[k+1]}"; steps=$FT_RET
        for (( s=0; s<steps; s++ )); do ramp+="${ramp:+ }$(( v1 + (v2-v1)*s/steps ))"; done
    done
    ramp+="${ramp:+ }${_v[m-1]}"; FT_RET=$ramp
}
# Blend two colour values: FT_RET = lerp(A, B, pct/100) as "r,g,b" (pct 0 → A, 100 → B).
_ft_css_blend() {               # colourA colourB pct → FT_RET
    _ft_css_rgb_of "$1"; local ar=$FT_RGB_RED ag=$FT_RGB_GREEN ab=$FT_RGB_BLUE
    _ft_css_rgb_of "$2"; local br=$FT_RGB_RED bg=$FT_RGB_GREEN bb=$FT_RGB_BLUE
    FT_RET="$(( ar + (br-ar)*$3/100 )),$(( ag + (bg-ag)*$3/100 )),$(( ab + (bb-ab)*$3/100 ))"
}
# A stepped (non-interpolated) ramp for a discrete property like font-weight: each stop's
# value is held until the next stop, sampled at the same ~24-step density as the colour ramps.
_ft_css_kf_step() {             # offsetsArrayName valuesArrayName → FT_RET
    _ft_css_kf_sort_stops "$1" "$2"; local m=$FT_RET
    (( m == 0 )) && { FT_RET=""; return; }
    local -n _o=$1 _v=$2
    if (( m == 1 )); then FT_RET=${_v[0]}; return; fi
    local ramp="" k steps s
    for (( k=0; k<m-1; k++ )); do
        _ft_css_kf_segment_steps "${_o[k]}" "${_o[k+1]}"; steps=$FT_RET
        for (( s=0; s<steps; s++ )); do ramp+="${ramp:+ }${_v[k]}"; done
    done
    ramp+="${ramp:+ }${_v[m-1]}"; FT_RET=$ramp
}
# Compose the animated SGR for a @keyframes NAME at PHASE from its per-property ramps:
# background-color + colour (dimmed toward BASEBG by the opacity ramp) + font-weight, combined
# into one escape (bg-then-fg-then-weight), or "". BASEFG/BASEBG (colour VALUES) are the
# element's own colours — so a colour-less keyframe (e.g. `opacity`-only pulse) animates the
# element's OWN colour, exactly like CSS opacity acting on whatever is there.
# Compose the animated SGR at PHASE from the TRANSIENT ramps (set by _ft_css_kf_for): bg +
# colour (dimmed toward BASEBG by opacity) + weight. A colour-less keyframe animates BASEFG.
_ft_css_kf_compose() {          # phase basefg basebg → FT_RET
    local ph=$1 basefg=$2 basebg=$3 params="" ramp m fgval=""
    ramp=$_KF_BG; if [[ -n "$ramp" ]]; then local -a r=($ramp); m=${#r[@]}
        (( m )) && { _ft_css_params "${r[ph % m]}" 48; [[ -n "$FT_RET" ]] && params+=$FT_RET; }; fi
    ramp=$_KF_FG; if [[ -n "$ramp" ]]; then local -a r=($ramp); m=${#r[@]}
        (( m )) && fgval=${r[ph % m]}; fi
    [[ -z "$fgval" ]] && fgval=$basefg
    ramp=$_KF_OP; if [[ -n "$ramp" && -n "$fgval" ]]; then local -a r=($ramp); m=${#r[@]}
        (( m )) && { _ft_css_blend "${basebg:-0}" "$fgval" "${r[ph % m]}"; fgval=$FT_RET; }; fi
    [[ -n "$fgval" ]] && { _ft_css_params "$fgval" 38; [[ -n "$FT_RET" ]] && params+="${params:+;}$FT_RET"; }
    ramp=$_KF_WT; if [[ -n "$ramp" ]]; then local -a r=($ramp); m=${#r[@]}
        (( m )) && [[ "${r[ph % m]}" == bold ]] && params+="${params:+;}1"; fi
    [[ -n "$params" ]] && FT_RET=$'\e['"$params"m || FT_RET=""
}
# build an interpolated "r,g,b r,g,b …" ramp from parallel offset/colour arrays (by name).
_ft_css_kf_ramp() {             # offsetsArrayName coloursArrayName → FT_RET
    _ft_css_kf_sort_stops "$1" "$2"; local m=$FT_RET
    (( m == 0 )) && { FT_RET=""; return; }
    local -n _offs=$1 _cols=$2
    if (( m == 1 )); then _ft_css_rgb_of "${_cols[0]}"; FT_RET="$FT_RGB_RED,$FT_RGB_GREEN,$FT_RGB_BLUE"; return; fi
    local ramp="" k r1 g1 b1 r2 g2 b2 steps s rr gg bb
    for (( k=0; k<m-1; k++ )); do
        _ft_css_rgb_of "${_cols[k]}";   r1=$FT_RGB_RED g1=$FT_RGB_GREEN b1=$FT_RGB_BLUE
        _ft_css_rgb_of "${_cols[k+1]}"; r2=$FT_RGB_RED g2=$FT_RGB_GREEN b2=$FT_RGB_BLUE
        _ft_css_kf_segment_steps "${_offs[k]}" "${_offs[k+1]}"; steps=$FT_RET
        for (( s=0; s<steps; s++ )); do
            rr=$(( r1 + (r2-r1)*s/steps )); gg=$(( g1 + (g2-g1)*s/steps )); bb=$(( b1 + (b2-b1)*s/steps ))
            ramp+="${ramp:+ }$rr,$gg,$bb"
        done
    done
    _ft_css_rgb_of "${_cols[m-1]}"; ramp+="${ramp:+ }$FT_RGB_RED,$FT_RGB_GREEN,$FT_RGB_BLUE"   # land exactly on the last stop
    FT_RET=$ramp
}
# resolve any colour VALUE (#hex, rgb(), name, 256 index) to FT_RGB_RED/FT_RGB_GREEN/FT_RGB_BLUE.
_ft_css_rgb_of() {              # value → FT_RGB_RED FT_RGB_GREEN FT_RGB_BLUE
    local v=$1
    if [[ "$v" == \#* || "$v" == rgb:* || "$v" == rgb\(* || "$v" == rgba\(* || "$v" == *,*,* ]]; then
        ft_parse_rgb "$v"; (( FT_COLOR_OK )) && return
    fi
    ft_color_index "$v"; (( FT_COLOR_OK )) && { ft_256_to_rgb "$FT_RET"; return; }
    FT_RGB_RED=0 FT_RGB_GREEN=0 FT_RGB_BLUE=0
}

# normalise a declaration block "p1:v1; p2:v2" → "prop:val;prop:val" (camelCase props,
# trimmed). Values are kept verbatim (var()/rgb() intact).
_ft_css_norm_decls() {          # body → FT_RET
    local body=$1 out="" decl prop val
    local IFS=';'
    for decl in $body; do
        [[ "$decl" != *:* ]] && continue
        prop=${decl%%:*}; val=${decl#*:}
        prop=${prop//[$' \t\n']/}                 # strip all whitespace from the property
        [[ -z "$prop" ]] && continue
        # trim leading/trailing whitespace from the value
        val=${val#"${val%%[![:space:]]*}"}; val=${val%"${val##*[![:space:]]}"}
        _ft_css_camel "$prop"; prop=$FT_RET
        _FT_CSS_DECLARED_PROPS[$prop]=1       # the layout's gate — see the note at its declaration
        # …and the coarser gate the box readers take, which lets _ft_inset4 and _ft_margin4 skip
        # asking about thirteen properties one at a time when no sheet has an opinion about any of
        # them. One list, in ft-forms beside the tuples it guards, so the two can never disagree.
        [[ -n "${_FT_FASTPATH_PROPS[$prop]:-}" ]] && _FT_CSS_FASTPATH_DECLARED=1
        out+="${prop}:${val};"
    done
    FT_RET=$out
}

# Tokenise a selector chain into compounds and combinators (> + ~), respecting [ … ] and
# ( … ) so a "~" inside [x~=y] or a "+" inside :nth-child(2n+1) is NOT read as a combinator.
_ft_css_split_chain() {         # chain → _CHAIN_TOKS (array of compounds and ">"/"+"/"~")
    local s=$1; local n=${#s} i ch cur="" depth=0 inbr=0
    _CHAIN_TOKS=()
    for (( i=0; i<n; i++ )); do
        ch=${s:i:1}
        if (( inbr )); then cur+=$ch; [[ "$ch" == "]" ]] && inbr=0; continue; fi
        if (( depth )); then cur+=$ch; case $ch in '(') (( depth++ )) ;; ')') (( depth-- )) ;; esac; continue; fi
        case $ch in
            '[') inbr=1; cur+=$ch ;;
            '(') depth=1; cur+=$ch ;;
            ' '|$'\t'|$'\n') [[ -n "$cur" ]] && { _CHAIN_TOKS+=("$cur"); cur=""; } ;;
            '>'|'+'|'~') [[ -n "$cur" ]] && { _CHAIN_TOKS+=("$cur"); cur=""; }; _CHAIN_TOKS+=("$ch") ;;
            *) cur+=$ch ;;
        esac
    done
    [[ -n "$cur" ]] && _CHAIN_TOKS+=("$cur")
}
# split a selector list on TOP-LEVEL commas only — commas inside :is(a, b) or [x=","]
# are not list separators.  → _SEL_LIST (array of whole selector chains)
_ft_css_split_list() {          # "a, b c, :is(x, y)" → _SEL_LIST
    local s=$1; local n=${#s} i ch cur="" depth=0 inbr=0
    _SEL_LIST=()
    for (( i=0; i<n; i++ )); do
        ch=${s:i:1}
        if (( inbr )); then cur+=$ch; [[ "$ch" == "]" ]] && inbr=0; continue; fi
        if (( depth )); then cur+=$ch; case $ch in '(') (( depth++ )) ;; ')') (( depth-- )) ;; esac; continue; fi
        case $ch in
            '[') inbr=1; cur+=$ch ;;
            '(') depth=1; cur+=$ch ;;
            ',') _SEL_LIST+=("$cur"); cur="" ;;
            *)   cur+=$ch ;;
        esac
    done
    _SEL_LIST+=("$cur")
}
# split a selector-list "a, b c, .d" into flat rules under `sheet`
_ft_css_add_rules() {           # sheet selectorlist body
    local sheet=$1 sellist=$2 body=$3
    _ft_css_norm_decls "$body"; local decls=$FT_RET
    [[ -z "$decls" ]] && return
    local sel key idx chain
    _ft_css_split_list "$sellist"
    for sel in "${_SEL_LIST[@]}"; do
        chain=${sel//$'\t'/ }; chain=${chain//$'\n'/ }
        chain=${chain# }; chain=${chain% }
        [[ -z "$chain" ]] && continue
        _ft_css_split_chain "$chain"                       # → _CHAIN_TOKS
        # compounds + the combinator PRECEDING each (default descendant " ")
        local -a comps=() combs=(); local ti pend=""
        for ti in "${_CHAIN_TOKS[@]}"; do
            case $ti in
                '+'|'~') pend=$ti; _FT_CSS_STRUCTURAL=1 ;;   # sibling combinator → beyond a subtree
                '>')     pend=$ti ;;
                *)       comps+=("$ti"); combs+=("${pend:- }"); pend="" ;;
            esac
        done
        local nc=${#comps[@]}; (( nc == 0 )) && continue
        idx=${FT_CSS_RULE_COUNT[$sheet]}; key="$sheet"$'\t'"$idx"
        FT_CSS_DECLARATIONS[$key]=$decls
        _ft_css_specificity "$chain"; FT_CSS_SPECIFICITY[$key]=$FT_RET
        FT_CSS_ORDER[$key]=$(( _FT_CSS_SEQ++ ))
        # ancestors 0..nc-2 in source order; each carries the combinator that LINKS it to the
        # next (more specific) compound = combs[i+1]. Fields \x1f-sep, entries \x1e-sep.
        local anc="" i
        for (( i=0; i<nc-1; i++ )); do
            _ft_css_compound "${comps[i]}"; _ft_css_note_match_props
            anc+="${combs[i+1]}"$'\x1f'"${_FT_CSS_COMPOUND_TYPE}"$'\x1f'"${_FT_CSS_COMPOUND_ID}"$'\x1f'"${_FT_CSS_COMPOUND_CLASS}"$'\x1f'"${_FT_CSS_COMPOUND_PSEUDO_CLASS}"$'\x1f'"${_FT_CSS_COMPOUND_ATTRIBUTE}"$'\x1f'"${_FT_CSS_COMPOUND_FUNCTION}"$'\x1e'
        done
        _ft_css_compound "${comps[nc-1]}"; _ft_css_note_match_props   # the KEY compound (rightmost)
        FT_CSS_SELECTOR_TYPE[$key]=$_FT_CSS_COMPOUND_TYPE; FT_CSS_SELECTOR_ID[$key]=$_FT_CSS_COMPOUND_ID
        FT_CSS_SELECTOR_CLASS[$key]=$_FT_CSS_COMPOUND_CLASS; FT_CSS_SELECTOR_PSEUDO_CLASS[$key]=$_FT_CSS_COMPOUND_PSEUDO_CLASS; FT_CSS_SELECTOR_PSEUDO_ELEMENT[$key]=$_FT_CSS_COMPOUND_PSEUDO_ELEMENT
        FT_CSS_SELECTOR_ATTRIBUTE[$key]=$_FT_CSS_COMPOUND_ATTRIBUTE; FT_CSS_SELECTOR_FUNCTION[$key]=$_FT_CSS_COMPOUND_FUNCTION
        FT_CSS_SELECTOR_ANCESTORS[$key]=$anc
        FT_CSS_RULE_COUNT[$sheet]=$(( idx + 1 ))
    done
}

# ── Public: register a stylesheet ────────────────────────────────────────────
# ft_stylesheet name=NAME style='…css…' [default=true]
# A stylesheet is an object built like any other (name + props). Its `style` prop is
# real CSS; we parse it now. `default=true` marks it the low-precedence user/agent
# default sheet (cascade level 4); otherwise it is an app-targeted sheet (level 2).
# ── Sheet-scoped restyle: editing a stylesheet repaints what it can style ────
# The CSSOM behaviour this engine copies: you edit a stylesheet and the STYLE ENGINE does
# selector-based invalidation — affected elements restyle, the page author writes zero repaint
# code. This engine had half of that: re-registering a sheet bumped the cascade epoch (so the
# next paint resolves fresh) but REPAINTED NOTHING, so every app that edited a sheet at runtime
# carried its own hand-picked ft_dirty_subtree list — demo/css-demo.bash's `_repaint_spec`,
# three subtrees chosen by a person, wrong the day the sheet grows a fourth.
#
# The sheet itself says which elements it can style: the same KEY-SELECTOR extraction the rule
# index is built from (_ft_css_reindex). Both the sheet's OLD rules and its NEW ones count — a
# rule that was removed must restyle the elements it used to match, or they keep its colour.
# Matching is one tree walk of hash lookups; a matched node's whole SUBTREE repaints, because
# inherited properties and var() reach downward. A rule with no id/class/type key (`:root`,
# `*`, bare `[attr]`/`:hover`) can style anything: the root repaints, which is the honest cost
# of editing a sheet that styles everything.
declare -A _FT_SHEET_IDS=() _FT_SHEET_CLASSES=() _FT_SHEET_TYPES=()
_FT_SHEET_UNIV=0
_ft_css_sheet_keys() {          # sheet — ACCUMULATE its key selectors into _FT_SHEET_*
    local sheet=$1 n=${FT_CSS_RULE_COUNT[$1]:-0} i key kid kcl kty
    for (( i=0; i<n; i++ )); do
        key="$sheet"$'\t'"$i"
        kid=${FT_CSS_SELECTOR_ID[$key]:-}; kcl=${FT_CSS_SELECTOR_CLASS[$key]:-}; kty=${FT_CSS_SELECTOR_TYPE[$key]:-}
        if   [[ -n "$kid" ]]; then _FT_SHEET_IDS[$kid]=1
        elif [[ -n "$kcl" ]]; then _FT_SHEET_CLASSES[${kcl%% *}]=1
        elif [[ -n "$kty" ]]; then _FT_SHEET_TYPES[$kty]=1
        else _FT_SHEET_UNIV=1; fi
    done
}
_ft_css_restyle_matching() {    # (reads _FT_SHEET_*) — dirty every subtree the sheet can style
    local root=${FT_ROOT:-}
    [[ -n "$root" && -n "${FT_TYPE[$root]:-}" ]] || return 0     # no tree yet → first paint covers it
    if (( _FT_SHEET_UNIV )); then ft_dirty_subtree "$root"; return 0; fi
    local -a stack=("$root"); local n kid cls matched
    while (( ${#stack[@]} )); do
        n=${stack[-1]}; unset 'stack[-1]'
        matched=0
        [[ -n "${_FT_SHEET_IDS[$n]:-}" ]] && matched=1
        (( ! matched )) && [[ -n "${_FT_SHEET_TYPES[${FT_TYPE[$n]:-}]:-}" ]] && matched=1
        if (( ! matched )) && (( ${#_FT_SHEET_CLASSES[@]} )); then
            _ft_get_raw "$n" class
            for cls in $FT_RET; do [[ -n "${_FT_SHEET_CLASSES[$cls]:-}" ]] && { matched=1; break; }; done
        fi
        # a matched subtree is dirtied whole — descending further finds nothing new
        if (( matched )); then ft_dirty_subtree "$n"; continue; fi
        for kid in ${FT_KIDS[$n]:-}; do stack+=("$kid"); done
    done
}
ft_stylesheet() {               # name=… style=… [default=…]
    local name="" css="" isdefault=0 arg
    for arg in "$@"; do
        case $arg in
            name=*)    name=${arg#name=} ;;
            style=*)   css=${arg#style=} ;;
            default=*) [[ "${arg#default=}" == true ]] && isdefault=1 ;;
        esac
    done
    [[ -z "$name" ]] && return 1
    _FT_SHEET_IDS=(); _FT_SHEET_CLASSES=(); _FT_SHEET_TYPES=(); _FT_SHEET_UNIV=0
    _ft_css_sheet_keys "$name"          # the OLD rules — a removed rule must restyle its matches
    _ft_css_parse "$name" "$css"
    _ft_css_sheet_keys "$name"          # …and the new ones
    # (re)register in order; a default sheet is remembered so the resolver can place it
    local s found=0
    for s in "${FT_CSS_SHEETS[@]}"; do [[ "$s" == "$name" ]] && found=1; done
    (( found )) || FT_CSS_SHEETS+=("$name")
    (( isdefault )) && FT_CSS_DEFAULT_SHEET=$name
    _ft_css_reindex   # a sheet's rules changed → rebuild the key-selector index
    _ft_css_bump   # the sheet is now IN the cascade — a var()-driven @keyframes it defines can
                   # finally resolve; the epoch bump forces a per-element re-resolve on next use.
    _ft_css_restyle_matching            # …and what it can style REPAINTS, CSSOM-style
    return 0
}
FT_CSS_DEFAULT_SHEET=""

# ── Which properties INHERIT (cascade level 3) ───────────────────────────────
# CSS inherits some properties (color, visibility, custom properties) and not others
# (background-color, border-*). Custom properties (--*) always inherit.
# One table, owned by ft-forms.bash (FT_INHERITED_PROP), consulted by BOTH the cascade and
# ft_resolve — so "does this property inherit?" has a single answer everywhere.
_ft_css_mark_inherit() { local p; for p in "$@"; do FT_INHERITED_PROP[$p]=1; done; }
_ft_css_mark_inherit color visibility cursor textAlign fontWeight fontStyle
_ft_css_inherits() { [[ "$1" == --* ]] && return 0; [[ -n "${FT_INHERITED_PROP[$1]:-}" ]]; }

# ── Selector matching ────────────────────────────────────────────────────────
_ft_css_class_has() {           # control className → 0 if the control carries it
    _ft_get_raw "$1" class
    case " $FT_RET " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}
# Answers a pseudo-class from the STATE REGISTRY (ft-forms.bash) rather than a `case` here.
# A control TYPE's own declaration wins over the global one, which is what lets each control
# define its own states (runlevels) without this file knowing any of them.
_ft_css_state() {               # control pseudo-class → 0 if the control is in that state
    local spec
    # ONE lookup in the common case. A per-TYPE declaration wins, but hardly any state has
    # one, so the type-scoped key is only built when some prototype actually declared this name —
    # otherwise this pays a string concat and a second lookup on every pseudo-class tested.
    if [[ -n "${FT_STATE_TYPED[$2]:-}" ]]; then
        spec=${FT_STATE_TEST[${FT_TYPE[$1]:-}:$2]:-}
        [[ -n "$spec" ]] || spec=${FT_STATE_TEST[$2]:-}
    else
        spec=${FT_STATE_TEST[$2]:-}
    fi
    [[ -n "$spec" ]] || return 1                              # unknown pseudo → never matches
    case ${spec:0:1} in
        '@') "${spec:1}" "$1"; return ;;                       # a test function
        '~') _ft_css_simple_matches "${spec:1}" "$1"; return ;;  # any richer selector alias
    esac
    # The common shapes, pre-parsed at declaration: read the property and compare; `!` negates.
    #
    # ft_own_prop AND NOT _ft_get_raw, for the same reason `:disabled` resolves through
    # ft_resolved_prop rather than an attribute shape: a selector asks about the ELEMENT, and a
    # prototype default is part of what the element is. Every per-prototype runlevel state is
    # declared as `[runlevel=<rung>]` (see _ft_prototype_finish_runlevels), and `runlevel=unfocused`
    # is a prototype default — so with defaults off the instance a raw read answered "" and
    # `label:unfocused` matched NOTHING, which is `:unfocused` failing to describe a control that is
    # unfocused. ft_own_prop also still settles a stale `value` out of the line store.
    ft_own_prop "$1" "${spec%% *}"
    spec=${spec#* }
    [[ "${spec:0:1}" == '!' ]] && { [[ "$FT_RET" != "${spec:1}" ]]; return; }
    [[ "$FT_RET" == "$spec" ]]
}
# Attribute selector: "attr" (present), "attr=v", "attr~=v" (space list), "attr^=v"/"$="/"*="
# (prefix/suffix/substring), "attr|=v" (v or v-…). Value quotes are stripped. → 0 if it matches.
_ft_css_attr_match() {          # control cond → 0/1
    local c=$1 cond=$2 op="" attr val cur
    if   [[ "$cond" == *'~='* ]]; then op='~='; attr=${cond%%'~='*}; val=${cond#*'~='}
    elif [[ "$cond" == *'^='* ]]; then op='^='; attr=${cond%%'^='*}; val=${cond#*'^='}
    elif [[ "$cond" == *'$='* ]]; then op='$='; attr=${cond%%'$='*}; val=${cond#*'$='}
    elif [[ "$cond" == *'*='* ]]; then op='*='; attr=${cond%%'*='*}; val=${cond#*'*='}
    elif [[ "$cond" == *'|='* ]]; then op='|='; attr=${cond%%'|='*}; val=${cond#*'|='}
    elif [[ "$cond" == *'='*   ]]; then op='=';  attr=${cond%%'='*};  val=${cond#*'='}
    else attr=$cond; fi
    attr=${attr//[[:space:]]/}; val=${val#\"}; val=${val%\"}; val=${val#\'}; val=${val%\'}
    ft_own_prop "$c" "$attr"; cur=$FT_RET          # the ELEMENT's value — see the note above
    case $op in
        '')   [[ -n "$cur" ]] ;;                         # [attr] — present & non-empty
        '=')  [[ "$cur" == "$val" ]] ;;
        '~=') case " $cur " in *" $val "*) return 0;; *) return 1;; esac ;;
        '^=') [[ "$cur" == "$val"* ]] ;;
        '$=') [[ "$cur" == *"$val" ]] ;;
        '*=') [[ "$cur" == *"$val"* ]] ;;
        '|=') [[ "$cur" == "$val" || "$cur" == "$val"-* ]] ;;
    esac
}
_ft_css_match_compound() {      # type id classes pseudos attr fn control → 0 if all match
    local type=$1 id=$2 classes=$3 pseudos=$4 attr=$5 fn=$6 c=$7 x
    [[ -n "$type" && "$type" != "${FT_TYPE[$c]:-}" ]] && return 1
    # #id matches the control's `id` PROPERTY, which DEFAULTS to its name — so `#spec` still matches
    # a control named spec, but you can also give it an explicit id distinct from its bash handle.
    if [[ -n "$id" ]]; then _ft_get_raw "$c" id; [[ "$id" != "${FT_RET:-$c}" ]] && return 1; fi
    for x in $classes; do _ft_css_class_has "$c" "$x" || return 1; done
    for x in $pseudos; do _ft_css_state    "$c" "$x" || return 1; done
    if [[ -n "$attr" ]]; then local a IFS=$'\n'
        for a in $attr; do [[ -n "$a" ]] && { _ft_css_attr_match "$c" "$a" || return 1; }; done
    fi
    if [[ -n "$fn" ]]; then local f IFS=$'\n'
        for f in $fn; do [[ -n "$f" ]] && { _ft_css_fn_match "$c" "$f" || return 1; }; done
    fi
    return 0
}
# match a single COMPOUND selector (no combinators) against one control
_ft_css_simple_matches() {      # compound control → 0/1
    _ft_css_compound "$1"
    _ft_css_match_compound "$_FT_CSS_COMPOUND_TYPE" "$_FT_CSS_COMPOUND_ID" "$_FT_CSS_COMPOUND_CLASS" "$_FT_CSS_COMPOUND_PSEUDO_CLASS" "$_FT_CSS_COMPOUND_ATTRIBUTE" "$_FT_CSS_COMPOUND_FUNCTION" "$2"
}

# ── Public DOM-shaped selector & class API ────────────────────────────────────
# Names mirror the DOM verbatim, adapted to bash call-style. SELECTOR here is a single COMPOUND
# (type / #id / .class / :state / [attr] / :not()…); combinator selectors like ".a .b" are for
# stylesheet rules, not these element queries.
ft_matches() {                  # el.matches(selector) — NAME SELECTOR → 0 iff it matches
    _ft_css_simple_matches "$2" "$1"
}
ft_closest() {                  # el.closest(selector) — NAME SELECTOR → FT_RET = nearest self-or-
    local n=$1 sel=$2           #   ancestor that matches (0), or "" (1)
    while [[ -n "$n" ]]; do
        _ft_css_simple_matches "$sel" "$n" && { FT_RET=$n; return 0; }
        n=${FT_PARENT[$n]:-}
    done
    FT_RET=""; return 1
}
ft_query_all() {                # querySelectorAll(selector [, root]) → FT_RET = space-sep matching
    local sel=$1 root=${2:-$FT_ROOT} out="" ; _ft_query_walk() {
        local n=$1; _ft_css_simple_matches "$sel" "$n" && out+="${out:+ }$n"
        local k; for k in ${FT_KIDS[$n]:-}; do _ft_query_walk "$k"; done
    }
    [[ -n "$root" ]] && _ft_query_walk "$root"; unset -f _ft_query_walk; FT_RET=$out; [[ -n "$out" ]]
}
ft_query() {                    # querySelector(selector [, root]) → FT_RET = FIRST match (0), or "" (1)
    ft_query_all "$@"; FT_RET=${FT_RET%% *}; [[ -n "$FT_RET" ]]
}
# classList — add/remove/toggle/contains one class, leaving the others alone. Routed through
# ft-modify so a class change reflows/repaints exactly like `ft-modify el class=…`.
# ── Token-list properties (the DOM's DOMTokenList) ────────────────────────────
# A property whose value is a SPACE-separated token list — `class`, or a widget's own (a file
# dialog's `accept`, etc.). ft_tokenlist_* add/remove/toggle/contains those tokens generically; the
# change routes through ft-modify, so it reflows/repaints and invalidates the cascade exactly like
# any property set. The DOM exposes this only per-attribute (el.classList / el.relList); one generic
# call taking the property name covers the lists it otherwise handles ad-hoc. A list property must be
# REGISTERED (ft_prop_kind_set) so a multi-token value with spaces parses — `class` is; a widget
# registers its own. add/remove are variadic; toggle/contains act on one token.
ft_tokenlist_contains() {           # NAME PROP token → 0 iff present
    ft_get "$1" "$2"; case " $FT_RET " in *" $3 "*) return 0 ;; *) return 1 ;; esac
}
ft_tokenlist_add() {                # NAME PROP token... — add each token (if absent)
    local n=$1 p=$2; shift 2
    ft_get "$n" "$p"; local -a all; read -ra all <<< "$FT_RET"
    local c x seen
    for c in "$@"; do
        seen=0; for x in "${all[@]}"; do [[ "$x" == "$c" ]] && { seen=1; break; }; done
        (( seen )) || all+=("$c")
    done
    ft-modify "$n" "$p"="${all[*]}"
}
ft_tokenlist_remove() {             # NAME PROP token... — remove each token
    local n=$1 p=$2; shift 2
    ft_get "$n" "$p"; local -a all; read -ra all <<< "$FT_RET"
    local -a out=(); local x c keep
    for x in "${all[@]}"; do
        keep=1; for c in "$@"; do [[ "$x" == "$c" ]] && { keep=0; break; }; done
        (( keep )) && out+=("$x")
    done
    ft-modify "$n" "$p"="${out[*]}"
}
ft_tokenlist_toggle() {             # NAME PROP token → 0 iff the token is now PRESENT
    if ft_tokenlist_contains "$1" "$2" "$3"; then ft_tokenlist_remove "$1" "$2" "$3"; return 1
    else ft_tokenlist_add "$1" "$2" "$3"; return 0; fi
}
# classList — the DOM-familiar name for the `class` token list (thin aliases over ft_tokenlist_*).
ft_classlist_add()      { local n=$1; shift; ft_tokenlist_add    "$n" class "$@"; }   # classList.add
ft_classlist_remove()   { local n=$1; shift; ft_tokenlist_remove "$n" class "$@"; }   # classList.remove
ft_classlist_toggle()   { ft_tokenlist_toggle   "$1" class "$2"; }                    # classList.toggle
ft_classlist_contains() { ft_tokenlist_contains "$1" class "$2"; }                    # classList.contains
# does any descendant of `node` match the compound `selc`?
_ft_css_has_descendant() {      # node compound → 0/1
    local node=$1 selc=$2 k
    for k in ${FT_KIDS[$node]:-}; do
        _ft_css_simple_matches "$selc" "$k" && return 0
        _ft_css_has_descendant "$k" "$selc" && return 0
    done
    return 1
}
# functional pseudo-class: :not() :is()/:matches() :where() :has(); arg is a comma list of compounds
_ft_css_fn_match() {            # control "name<TAB>arg" → 0/1
    local c=$1 name=${2%%$'\t'*} arg=${2#*$'\t'} sub IFS=','
    case $name in
        not)
            for sub in $arg; do sub="${sub#"${sub%%[![:space:]]*}"}"; sub="${sub%"${sub##*[![:space:]]}"}"
                [[ -z "$sub" ]] && continue; _ft_css_simple_matches "$sub" "$c" && return 1
            done; return 0 ;;
        is|matches|where)
            for sub in $arg; do sub="${sub#"${sub%%[![:space:]]*}"}"; sub="${sub%"${sub##*[![:space:]]}"}"
                [[ -z "$sub" ]] && continue; _ft_css_simple_matches "$sub" "$c" && return 0
            done; return 1 ;;
        has)
            for sub in $arg; do sub="${sub#"${sub%%[![:space:]]*}"}"; sub="${sub%"${sub##*[![:space:]]}"}"
                [[ -z "$sub" ]] && continue; _ft_css_has_descendant "$c" "$sub" && return 0
            done; return 1 ;;
        *) return 1 ;;            # unsupported functional pseudo → never matches (safe)
    esac
}
# the sibling immediately before `node` among its parent's children (or "")
_ft_css_prev_sibling() {        # node → FT_RET
    local n=$1 k prev=""; local p=${FT_PARENT[$n]:-}   # (split: $n must be set before use)
    FT_RET=""
    [[ -z "$p" ]] && return
    for k in ${FT_KIDS[$p]:-}; do [[ "$k" == "$n" ]] && { FT_RET=$prev; return; }; prev=$k; done
}
# does rule `key` (its whole selector, incl. combinators/ancestors) match `control`?
_ft_css_matches() {             # key control → 0/1
    local key=$1 control=$2
    _ft_css_match_compound "${FT_CSS_SELECTOR_TYPE[$key]}" "${FT_CSS_SELECTOR_ID[$key]}" \
        "${FT_CSS_SELECTOR_CLASS[$key]}" "${FT_CSS_SELECTOR_PSEUDO_CLASS[$key]}" "${FT_CSS_SELECTOR_ATTRIBUTE[$key]}" \
        "${FT_CSS_SELECTOR_FUNCTION[$key]}" "$control" || return 1
    local anc=${FT_CSS_SELECTOR_ANCESTORS[$key]}
    [[ -z "$anc" ]] && return 0
    # split entries (\x1e-sep, source order); each: comb \x1f type \x1f id \x1f cls \x1f ps \x1f attr \x1f fn
    local -a entries=(); local rest=$anc e
    while [[ -n "$rest" ]]; do
        e=${rest%%$'\x1e'*}; [[ -n "$e" ]] && entries+=("$e")
        [[ "$rest" == *$'\x1e'* ]] && rest=${rest#*$'\x1e'} || rest=""
    done
    # match RIGHT-TO-LEFT; `anchor` is the node the current entry relates to via its combinator
    local i=$(( ${#entries[@]} - 1 )) anchor=$control
    local comb t id cls ps at fn found cur
    while (( i >= 0 )); do
        e=${entries[i]}
        comb=${e%%$'\x1f'*}; e=${e#*$'\x1f'}
        t=${e%%$'\x1f'*};    e=${e#*$'\x1f'}
        id=${e%%$'\x1f'*};   e=${e#*$'\x1f'}
        cls=${e%%$'\x1f'*};  e=${e#*$'\x1f'}
        ps=${e%%$'\x1f'*};   e=${e#*$'\x1f'}
        at=${e%%$'\x1f'*};   fn=${e#*$'\x1f'}
        found=0
        case $comb in
            '>')                       # child: the anchor's direct parent must match
                cur=${FT_PARENT[$anchor]:-}
                [[ -n "$cur" ]] && _ft_css_match_compound "$t" "$id" "$cls" "$ps" "$at" "$fn" "$cur" \
                    && { found=1; anchor=$cur; } ;;
            '+')                       # adjacent sibling: the immediately-preceding sibling must match
                _ft_css_prev_sibling "$anchor"; cur=$FT_RET
                [[ -n "$cur" ]] && _ft_css_match_compound "$t" "$id" "$cls" "$ps" "$at" "$fn" "$cur" \
                    && { found=1; anchor=$cur; } ;;
            '~')                       # general sibling: some preceding sibling matches
                _ft_css_prev_sibling "$anchor"; cur=$FT_RET
                while [[ -n "$cur" ]]; do
                    if _ft_css_match_compound "$t" "$id" "$cls" "$ps" "$at" "$fn" "$cur"; then found=1; anchor=$cur; break; fi
                    _ft_css_prev_sibling "$cur"; cur=$FT_RET
                done ;;
            *)                         # descendant: some ancestor matches (greedy)
                cur=${FT_PARENT[$anchor]:-}
                while [[ -n "$cur" ]]; do
                    if _ft_css_match_compound "$t" "$id" "$cls" "$ps" "$at" "$fn" "$cur"; then found=1; anchor=$cur; break; fi
                    cur=${FT_PARENT[$cur]:-}
                done ;;
        esac
        (( found )) || return 1
        (( i-- ))
    done
    return 0
}

# ── Value lookup within a rule's declaration block ───────────────────────────
_ft_css_decl_get() {            # decls prop → FT_RET, _DGOT(0/1); LAST decl wins
    local d=";$1" p=$2 rest
    _DGOT=0; FT_RET=""
    [[ "$d" == *";$p:"* ]] || return
    rest=${d##*";$p:"}; FT_RET=${rest%%;*}; _DGOT=1
}
# best declared value for `prop` on `control` from either the app sheets or the default
# sheet — highest specificity, then latest source order. → FT_RET, _QGOT(0/1).
_ft_css_query() {               # control prop mode(app|default) → FT_RET, _QGOT (memoised)
    local tok="$_FT_CSS_EPOCH:${_FT_CSS_VERSION[$1]:-0}:${FT_FOCUS:-}:${FT_ROOT:-}" ck="$1"$'\x1f'"$2"$'\x1f'"$3" e=${_FT_CSS_Q_C["$1"$'\x1f'"$2"$'\x1f'"$3"]:-}
    if [[ -n "$e" && "${e%%$'\x1f'*}" == "$tok" ]]; then
        e=${e#*$'\x1f'}; _QGOT=${e%%$'\x1f'*}; FT_RET=${e#*$'\x1f'}; return
    fi
    _ft_css_query_compute "$1" "$2" "$3"
    _FT_CSS_Q_C[$ck]="$tok"$'\x1f'"$_QGOT"$'\x1f'"$FT_RET"
}
_ft_css_query_compute() {       # control prop mode(app|default)
    local control=$1 prop=$2 mode=$3
    _QGOT=0; local best="" bestspec=-1 bestord=-1 key val spec ord sheet cl
    # only the rules whose key compound could match this element (see _ft_css_reindex)
    _ft_get_raw "$control" class; local xcls=$FT_RET
    _ft_get_raw "$control" id;    local xid=${FT_RET:-$control}   # effective id: the id prop, else the name
    local xt=${FT_TYPE[$control]:-} cands="${_FT_CSS_IDX_ID[$xid]:-}${_FT_CSS_IDX_UNIV}"
    [[ -n "$xt" ]] && cands+="${_FT_CSS_IDX_TYPE[$xt]:-}"   # empty subscript is an error — guard it
    for cl in $xcls; do cands+="${_FT_CSS_IDX_CLASS[$cl]:-}"; done
    # keys hold a TAB (sheet\ti) → split on SPACE only (scoped to read, so IFS is undisturbed)
    local -a keys=(); IFS=' ' read -r -a keys <<< "$cands"
    for key in "${keys[@]}"; do
        sheet=${key%%$'\t'*}
        if [[ "$mode" == default ]]; then [[ "$sheet" == "$FT_CSS_DEFAULT_SHEET" ]] || continue
        else [[ "$sheet" == "$FT_CSS_DEFAULT_SHEET" ]] && continue; fi
        [[ -n "${FT_CSS_SELECTOR_PSEUDO_ELEMENT[$key]}" ]] && continue     # ::pseudo-element rules style STRUCTURES, not the element
        _ft_css_decl_get "${FT_CSS_DECLARATIONS[$key]}" "$prop"; (( _DGOT )) || continue
        val=$FT_RET                                     # capture before match clobbers FT_RET
        _ft_css_matches "$key" "$control" || continue
        spec=${FT_CSS_SPECIFICITY[$key]}; ord=${FT_CSS_ORDER[$key]}
        if (( spec > bestspec )) || { (( spec == bestspec )) && (( ord >= bestord )); }; then
            best=$val; bestspec=$spec; bestord=$ord; _QGOT=1
        fi
    done
    FT_RET=$best
}

# ── var() substitution ───────────────────────────────────────────────────────
# var(--name) / var(--name, fallback) → the resolved custom property (which cascades
# and inherits like any property), or the fallback. Custom-property values may
# themselves contain var(), so this recurses through ft_style.
# Custom properties currently being resolved, as "control\x1fname" entries. A var() cycle is
# MUTUAL recursion, not a loop: this calls ft_style for the referenced property, ft_style
# computes its value, and that value is another var() back here. The `guard` below is a LOCAL,
# reset on every entry, so it never sees the recursion — `--a: var(--a)` (or a --a/--b pair, or
# a cycle reached through a fallback) simply HUNG THE APP. One typo in a stylesheet.
# CSS calls this "invalid at computed-value time": the reference resolves to nothing rather
# than to the fallback, which is what a second visit to the same property yields here.
_FT_CSS_VAR_CHAIN=""
_ft_css_resolve_value() {       # control value → FT_RET
    local control=$1 v=$2 guard=0
    while [[ "$v" == *'var('* ]] && (( guard++ < 32 )); do
        local before=${v%%var(*} rest=${v#*var(}
        local inside=${rest%%)*} after=${rest#*)}
        local vname=${inside%%,*} fallback=""
        [[ "$inside" == *,* ]] && fallback=${inside#*,}
        vname=${vname//[$' \t']/}
        fallback=${fallback#"${fallback%%[![:space:]]*}"}; fallback=${fallback%"${fallback##*[![:space:]]}"}
        local _vkey="$control"$'\x1f'"$vname" resolved=""
        case " $_FT_CSS_VAR_CHAIN " in
            *" $_vkey "*) resolved="" ;;        # already resolving it — a cycle
            *)  _FT_CSS_VAR_CHAIN="$_FT_CSS_VAR_CHAIN $_vkey"
                ft_style "$control" "$vname"; resolved=$FT_RET
                _FT_CSS_VAR_CHAIN=${_FT_CSS_VAR_CHAIN% *}
                ;;
        esac
        [[ -z "$resolved" ]] && resolved=$fallback
        v="$before$resolved$after"
    done
    FT_RET=$v
}

# ── The resolver: ft_style CONTROL PROP → FT_RET (the cascaded value) ─────────
# The five levels, first hit wins. This is the value BEFORE type-coercion/paint —
# a caller that needs an SGR still runs it through ft_color_sgr, exactly as today.
ft_style() {                    # control prop → FT_RET (memoised)
    local tok="$_FT_CSS_EPOCH:${_FT_CSS_VERSION[$1]:-0}:${FT_FOCUS:-}:${FT_ROOT:-}" ck="$1"$'\x1f'"$2" e=${_FT_STYLE_C["$1"$'\x1f'"$2"]:-}
    if [[ -n "$e" && "${e%%$'\x1f'*}" == "$tok" ]]; then FT_RET=${e#*$'\x1f'}; return; fi
    _ft_style_compute "$1" "$2"
    _FT_STYLE_C[$ck]="$tok"$'\x1f'"$FT_RET"
}
_ft_style_compute() {           # control prop → FT_RET
    local control=$1 prop=$2
    # 1. inline (a property set at the call site or later). _ft_get_raw → _ft_propkey maps a custom
    #    property (--x) to its bash-safe storage key — the SAME key the write path (_ft_setprop) uses,
    #    so `el { --x: v }`, `ft-modify el --x=v`, and an inline `--x=v` all resolve to one place.
    _ft_get_raw "$control" "$prop"
    if [[ -n "$FT_RET" ]]; then _ft_css_resolve_value "$control" "$FT_RET"; return; fi
    # 2. targeted app stylesheets
    _ft_css_query "$control" "$prop" app
    if (( _QGOT )); then _ft_css_resolve_value "$control" "$FT_RET"; return; fi
    # 3. inheritance — only if this property inherits, AND only if this element's own prototype
    #    does not declare it. That second clause is CSS's own rule (an inherited value fills in
    #    where the cascade produced nothing FOR THIS ELEMENT, and a prototype default is a
    #    declaration for this element), and it is what keeps the two inherited prototype defaults
    #    where they were: a tree does not take a select's `cursor` INDEX, and a button keeps
    #    centring its label inside a right-aligned container.
    if _ft_css_inherits "$prop" && ! _ft_prototype_declares "$control" "$prop"; then
        local parent=${FT_PARENT[$control]:-}
        [[ -n "$parent" ]] && { ft_style "$parent" "$prop"; return; }
    fi
    # 4. the user/agent default stylesheet
    _ft_css_query "$control" "$prop" default
    if (( _QGOT )); then _ft_css_resolve_value "$control" "$FT_RET"; return; fi
    # 5. prototype built-in default — the control's last resort, and the slot this comment used
    #    to say was empty. Everything above outranks it, which is what docs/styling-model.md §2 has
    #    always claimed and what stamping defaults onto the instance made false.
    if _ft_prototype_default "$control" "$prop"; then _ft_css_resolve_value "$control" "$FT_RET"; return; fi
    FT_RET=""
}

# ── Bridge to painting: a cascaded colour → an SGR ───────────────────────────
# _ft_css_color CONTROL CSSPROP CHANNEL(38 fg|48 bg) → FT_RET = the SGR for that
# colour resolved through the cascade, or "" if the cascade says nothing (the caller
# then keeps its current/base colour — this is what makes adoption ADDITIVE: an
# unstyled control is byte-for-byte unchanged). The theme's text ROLES (accent /
# notice / muted) resolve to the matching --*-text custom property so `color=accent`
# keeps working, now sourced from the stylesheet instead of a global.
_ft_css_color() {               # control cssprop channel → FT_RET
    local control=$1 prop=$2 ch=$3
    ft_style "$control" "$prop"; local val=$FT_RET
    [[ -z "$val" ]] && { FT_RET=""; return; }
    if [[ "$ch" == 38 ]]; then
        case $val in
            accent) ft_style "$control" --accent-text; [[ -n "$FT_RET" ]] && val=$FT_RET ;;
            notice) ft_style "$control" --notice-text; [[ -n "$FT_RET" ]] && val=$FT_RET ;;
            muted)  ft_style "$control" --muted-text;  [[ -n "$FT_RET" ]] && val=$FT_RET ;;
        esac
    fi
    ft_color_sgr "$val" "$ch"           # → FT_RET (or "" if the value isn't a colour)
}

# ── SGR composition: a cascaded element → the escape that paints it ──────────
# _ft_css_params VALUE CHANNEL(38|48) → FT_RET = just the numeric params of the colour
# (e.g. "48;5;234" or "48;2;r;g;b"), so several can be joined into ONE \e[…m — matching
# the palette's combined form, not a run of separate escapes.
_ft_css_params() {              # value channel → FT_RET
    ft_color_sgr "$1" "$2"; local p=$FT_RET
    p=${p#$'\e['}; FT_RET=${p%m}
}
# ft_sgr CONTROL → FT_RET = the combined SGR for the element from its cascaded
# color / background-color / font-weight (bold) / text-decoration (underline). "" if the
# cascade says nothing. This is the bridge controls will paint through as structural
# colours migrate off the FT_COLOR_* globals; it composes bg-then-fg-then-attrs so the bytes
# match today's baked palette values.
ft_sgr() {                      # control → FT_RET
    local control=$1 params="" v
    ft_style "$control" backgroundColor; v=$FT_RET
    [[ -n "$v" ]] && { _ft_css_params "$v" 48; [[ -n "$FT_RET" ]] && params+="${params:+;}$FT_RET"; }
    ft_style "$control" color; v=$FT_RET
    if [[ -n "$v" ]]; then
        case $v in accent) ft_style "$control" --accent-text; [[ -n "$FT_RET" ]] && v=$FT_RET ;;
                   notice) ft_style "$control" --notice-text; [[ -n "$FT_RET" ]] && v=$FT_RET ;;
                   muted)  ft_style "$control" --muted-text;  [[ -n "$FT_RET" ]] && v=$FT_RET ;; esac
        _ft_css_params "$v" 38; [[ -n "$FT_RET" ]] && params+="${params:+;}$FT_RET"
    fi
    ft_style "$control" fontWeight;     [[ "$FT_RET" == bold ]]      && params+="${params:+;}1"
    ft_style "$control" textDecoration; [[ "$FT_RET" == underline ]] && params+="${params:+;}4"
    [[ -n "$params" ]] && FT_RET=$'\e['"$params"m || FT_RET=""
}

# ── Pseudo-elements: the STRUCTURES inside a control ─────────────────────────
# `textfield::scrollbar`, `::selection`, `::caret`, `::border` — parts a control paints
# that are not separate controls. A pseudo-element rule styles the structure, never the
# element's own box, so element queries skip it (see _ft_css_query) and these functions
# query it explicitly: same specificity/source-order cascade, matched on the element part.
# THE ORIGIN LADDER IS THE SAME ONE THE ELEMENT WALKS. An app sheet outranks the default/theme
# sheet whatever their specificities or source orders — that is what _ft_style_compute's levels
# 2 and 4 mean, and it is not a tie-break, it is a precedence. This query used to pool both
# origins into one specificity/source-order contest, so a `::caret` rule in the theme could beat
# the app's own `::caret` rule while the element's `color` on the very same control resolved the
# other way round. Two ways it bit, neither fixable by writing the sheets in a different order:
# ft_use_theme RE-REGISTERS the default sheet at runtime, so its rules take fresh, higher orders
# and win every equal-specificity contest; and a theme rule with higher specificity wins from
# any position at all. Nothing shipped today trips it — the three bundled themes carry zero `::`
# rules — but docs/styling-model.md §6 invites exactly the theme that would.
_ft_css_query_pe() {            # control pe prop → FT_RET, _QGOT (memoised)
    local tok="$_FT_CSS_EPOCH:${_FT_CSS_VERSION[$1]:-0}:${FT_FOCUS:-}:${FT_ROOT:-}" ck="$1"$'\x1f'"$2"$'\x1f'"$3" e=${_FT_CSS_QPE_C["$1"$'\x1f'"$2"$'\x1f'"$3"]:-}
    if [[ -n "$e" && "${e%%$'\x1f'*}" == "$tok" ]]; then
        e=${e#*$'\x1f'}; _QGOT=${e%%$'\x1f'*}; FT_RET=${e#*$'\x1f'}; return
    fi
    _ft_css_query_pe_compute "$1" "$2" "$3" app
    (( _QGOT )) || _ft_css_query_pe_compute "$1" "$2" "$3" default
    _FT_CSS_QPE_C[$ck]="$tok"$'\x1f'"$_QGOT"$'\x1f'"$FT_RET"
}
_ft_css_query_pe_compute() {    # control pe prop mode(app|default) → FT_RET, _QGOT(0/1)
    local control=$1 pe=$2 prop=$3 mode=$4
    _QGOT=0; local best="" bestspec=-1 bestord=-1 key val spec ord sheet cl
    _ft_get_raw "$control" class; local xcls=$FT_RET
    _ft_get_raw "$control" id;    local xid=${FT_RET:-$control}   # effective id: the id prop, else the name
    local xt=${FT_TYPE[$control]:-} cands="${_FT_CSS_IDX_ID[$xid]:-}${_FT_CSS_IDX_UNIV}"
    [[ -n "$xt" ]] && cands+="${_FT_CSS_IDX_TYPE[$xt]:-}"   # empty subscript is an error — guard it
    for cl in $xcls; do cands+="${_FT_CSS_IDX_CLASS[$cl]:-}"; done
    # keys hold a TAB (sheet\ti) → split on SPACE only (scoped to read, so IFS is undisturbed)
    local -a keys=(); IFS=' ' read -r -a keys <<< "$cands"
    for key in "${keys[@]}"; do
        sheet=${key%%$'\t'*}                            # the origin split, as the element does it
        if [[ "$mode" == default ]]; then [[ "$sheet" == "$FT_CSS_DEFAULT_SHEET" ]] || continue
        else [[ "$sheet" == "$FT_CSS_DEFAULT_SHEET" ]] && continue; fi
        [[ "${FT_CSS_SELECTOR_PSEUDO_ELEMENT[$key]}" == "$pe" ]] || continue     # must target THIS structure
        _ft_css_decl_get "${FT_CSS_DECLARATIONS[$key]}" "$prop"; (( _DGOT )) || continue
        val=$FT_RET
        _ft_css_matches "$key" "$control" || continue        # element part matches the control
        spec=${FT_CSS_SPECIFICITY[$key]}; ord=${FT_CSS_ORDER[$key]}
        if (( spec > bestspec )) || { (( spec == bestspec )) && (( ord >= bestord )); }; then
            best=$val; bestspec=$spec; bestord=$ord; _QGOT=1
        fi
    done
    FT_RET=$best
}
# _ft_css_color_pe CONTROL PE CSSPROP CHANNEL → FT_RET = SGR for the structure's colour,
# or "" if no rule (caller keeps its built-in colour — additive, like _ft_css_color).
_ft_css_color_pe() {            # control pe prop channel → FT_RET
    local control=$1 pe=$2 prop=$3 ch=$4
    # A structure that declares `animation` cycles its foreground live (like the element does).
    if [[ "$prop" == color && "$ch" == 38 ]]; then
        _ft_css_anim_pe "$control" "$pe" 38 && return
    fi
    _ft_css_query_pe "$control" "$pe" "$prop"
    (( _QGOT )) || { FT_RET=""; return; }
    _ft_css_resolve_value "$control" "$FT_RET"; local val=$FT_RET
    [[ -z "$val" ]] && { FT_RET=""; return; }
    if [[ "$ch" == 38 ]]; then
        case $val in accent) ft_style "$control" --accent-text; [[ -n "$FT_RET" ]] && val=$FT_RET ;;
                     notice) ft_style "$control" --notice-text; [[ -n "$FT_RET" ]] && val=$FT_RET ;;
                     muted)  ft_style "$control" --muted-text;  [[ -n "$FT_RET" ]] && val=$FT_RET ;; esac
    fi
    ft_color_sgr "$val" "$ch"
}

# ft_sgr_pseudo_element CONTROL PSEUDO-ELEMENT → FT_RET = the combined SGR a pseudo-element rule
# declares (background-color + color + font-weight), or "" if no rule touches it. The
# pseudo-element analogue of ft_sgr, for structures painted as a bg+fg pair (a selection band,
# a caret block).
ft_sgr_pseudo_element() {       # control pseudo-element → FT_RET
    local control=$1 pe=$2 params="" v
    _ft_css_query_pe "$control" "$pe" backgroundColor
    if (( _QGOT )); then _ft_css_resolve_value "$control" "$FT_RET"; v=$FT_RET
        _ft_css_params "$v" 48; [[ -n "$FT_RET" ]] && params+=$FT_RET; fi
    # foreground: an animating structure (`::caret { animation: blink }`) cycles it live;
    # otherwise the static declared colour.
    local afg=""
    if _ft_css_anim_pe "$control" "$pe" 38; then afg=${FT_RET#$'\e['}; afg=${afg%m}; fi
    if [[ -n "$afg" ]]; then params+="${params:+;}$afg"
    else
        _ft_css_query_pe "$control" "$pe" color
        if (( _QGOT )); then _ft_css_resolve_value "$control" "$FT_RET"; v=$FT_RET
            case $v in accent) ft_style "$control" --accent-text; [[ -n "$FT_RET" ]] && v=$FT_RET ;;
                       notice) ft_style "$control" --notice-text; [[ -n "$FT_RET" ]] && v=$FT_RET ;;
                       muted)  ft_style "$control" --muted-text;  [[ -n "$FT_RET" ]] && v=$FT_RET ;; esac
            _ft_css_params "$v" 38; [[ -n "$FT_RET" ]] && params+="${params:+;}$FT_RET"; fi
    fi
    _ft_css_query_pe "$control" "$pe" fontWeight
    (( _QGOT )) && [[ "$FT_RET" == bold ]] && params+="${params:+;}1"
    [[ -n "$params" ]] && FT_RET=$'\e['"$params"m || FT_RET=""
}

# ── Themes: a stylesheet you swap wholesale ──────────────────────────────────
# A THEME is an ordinary stylesheet (real CSS) that owns the palette. `ft_theme`
# registers its CSS under a name; `ft_use_theme` makes it the active default sheet
# (cascade level 4) AND derives the legacy FT_COLOR_* globals from it, so controls that
# still read a global stay in sync until they migrate to `ft_sgr self`. Switching
# themes is then ONE call — "swap the stylesheet" — not a hand-reassignment of a
# few dozen globals across the app.
#
# The theme vocabulary — real selectors the cascade already understands, each mapped
# to the global it derives. Every entry sets BOTH background-color and color (the
# palette bakes opaque bg+fg pairs), so the composed bytes match the hand-written
# escapes exactly; that byte-identity for the dark theme is pinned in tests/test-theme.bash.
#   :root            screen backdrop      → FT_COLOR_SCREEN   (+ role/cursor custom props)
#   :focus           the one focus accent → FT_COLOR_FOCUS (=FOCUS_BTN=SEL)
#   .surface         a dialog body/frame  → FT_COLOR_BODY  (= FT_COLOR_RESET)
#   .pane            a content pane       → FT_COLOR_PANE
#   .title .border .divider               → FT_COLOR_TITLE / FT_COLOR_BORDER / FT_COLOR_DIVIDER
#   .selected        a selected row       → FT_COLOR_SELECTED
#   .input           an input well        → FT_COLOR_INPUT
#   .input:focus     a focused input well → FT_COLOR_INPUT_FOCUS
#   .stripe .faded                        → FT_COLOR_STRIPE / FT_COLOR_FADED
#   :root { --accent-text --notice-text --muted-text } → FT_COLOR_TEXT_ACCENT/NOTICE/MUTED
#   :root { --cursor-color }                            → FT_CURSOR_COLOR
# Globals NOT in this list (idle button, knob, thumb, caret, status/keycap rows, …) keep
# whatever ft_setup_palette set — they migrate onto the cascade in later passes.
declare -A FT_THEME_CSS=()
ft_theme() {                    # name=… style='…css…'
    local name="" css="" arg
    for arg in "$@"; do
        case $arg in
            name=*)  name=${arg#name=} ;;
            style=*) css=${arg#style=} ;;
        esac
    done
    [[ -z "$name" ]] && return 1
    FT_THEME_CSS[$name]=$css
    return 0
}

FT_ACTIVE_THEME=""
# ft_use_theme NAME — the atomic swap: install the theme's CSS as the default sheet
# (re-registering ft-default replaces its rules in place) and re-derive the themeable
# globals. Returns 1 for an unknown theme. Callers repaint afterwards (ft_refresh).
ft_use_theme() {                # name
    local name=$1
    [[ -n "${FT_THEME_CSS[$name]+x}" ]] || return 1
    ft_stylesheet name=ft-default default=true style="${FT_THEME_CSS[$name]}"
    FT_ACTIVE_THEME=$name
    _ft_theme_sync
    return 0
}

# A detached probe control we point at each theme selector to read the composed SGR
# back out. Reused (not re-created) each sync; its parent is kept empty so `:root` and
# non-inheriting backgrounds resolve cleanly, and it carries no FT_TYPE so app type
# selectors can't accidentally style it.
_FT_THEME_PROBE=__ft_theme_probe
_ft_theme_compose() {           # classes focus(0/1) → FT_RET (composed sgr, "" if none)
    local P=$_FT_THEME_PROBE
    _ft_setprop "$P" class "$1"
    local savef=${FT_FOCUS:-}
    (( $2 )) && FT_FOCUS=$P || FT_FOCUS=""
    ft_sgr "$P"
    FT_FOCUS=$savef
}
_ft_theme_var_sgr() {           # customprop channel → FT_RET (fg/bg SGR, "" if unset)
    ft_style "$_FT_THEME_PROBE" "$1"
    [[ -z "$FT_RET" ]] && { FT_RET=""; return; }
    ft_color_sgr "$FT_RET" "$2"
}
_ft_theme_sync() {              # derive EVERY FT_COLOR_* from the active default sheet (the theme)
    local P=$_FT_THEME_PROBE
    FT_PARENT[$P]=""
    # THE PROBE MUST LOOK LIKE A CONTROL AT REST. It is detached and carries no properties of
    # its own, so a rule written against a state it lacks still matches it — and whatever that
    # rule sets is then baked into EVERY FT_COLOR_* global derived through it. The activated
    # marker (`:not([runlevel=unfocused])`) is exactly that shape: with no runlevel on the probe
    # it matched, and the entire palette came out wearing the activated colour, so every
    # control looked activated all the time. Say what it is instead of leaving it unsaid.
    _ft_setprop "$P" runlevel unfocused
    _ft_theme_compose screen   0; [[ -n "$FT_RET" ]] && FT_COLOR_SCREEN=$FT_RET
    _ft_theme_compose ""       1; [[ -n "$FT_RET" ]] && FT_COLOR_FOCUS=$FT_RET
    _ft_theme_compose surface  0; [[ -n "$FT_RET" ]] && FT_COLOR_BODY=$FT_RET
    _ft_theme_compose pane     0; [[ -n "$FT_RET" ]] && FT_COLOR_PANE=$FT_RET
    _ft_theme_compose title    0; [[ -n "$FT_RET" ]] && FT_COLOR_TITLE=$FT_RET
    _ft_theme_compose heading  0; [[ -n "$FT_RET" ]] && FT_COLOR_HEADING=$FT_RET
    _ft_theme_compose border   0; [[ -n "$FT_RET" ]] && FT_COLOR_BORDER=$FT_RET
    _ft_theme_compose boxline  0; [[ -n "$FT_RET" ]] && FT_COLOR_BOX_LINE=$FT_RET
    _ft_theme_compose boxtext  0; [[ -n "$FT_RET" ]] && FT_COLOR_BOX_TEXT=$FT_RET
    _ft_theme_compose subtext  0; [[ -n "$FT_RET" ]] && FT_COLOR_SUBTEXT=$FT_RET
    _ft_theme_compose divider  0; [[ -n "$FT_RET" ]] && FT_COLOR_DIVIDER=$FT_RET
    _ft_theme_compose selected 0; [[ -n "$FT_RET" ]] && FT_COLOR_SELECTED=$FT_RET
    _ft_theme_compose seldim   0; [[ -n "$FT_RET" ]] && FT_COLOR_SEL_DIM=$FT_RET
    _ft_theme_compose btn      0; [[ -n "$FT_RET" ]] && FT_COLOR_BUTTON=$FT_RET
    _ft_theme_compose input    0; [[ -n "$FT_RET" ]] && FT_COLOR_INPUT=$FT_RET
    _ft_theme_compose input    1; [[ -n "$FT_RET" ]] && FT_COLOR_INPUT_FOCUS=$FT_RET
    _ft_theme_compose field    0; [[ -n "$FT_RET" ]] && FT_COLOR_FIELD=$FT_RET
    _ft_theme_compose fieldlocked 0; [[ -n "$FT_RET" ]] && FT_COLOR_FIELD_LOCKED=$FT_RET
    _ft_theme_compose thumb    0; [[ -n "$FT_RET" ]] && FT_COLOR_THUMB=$FT_RET
    _ft_theme_compose knob     0; [[ -n "$FT_RET" ]] && FT_COLOR_KNOB=$FT_RET
    _ft_theme_compose stripe   0; [[ -n "$FT_RET" ]] && FT_COLOR_STRIPE=$FT_RET
    _ft_theme_compose disabled 0; [[ -n "$FT_RET" ]] && FT_COLOR_DISABLED=$FT_RET
    _ft_theme_compose disabledtext 0; [[ -n "$FT_RET" ]] && FT_COLOR_DISABLED_TXT=$FT_RET
    _ft_theme_compose faded    0; [[ -n "$FT_RET" ]] && FT_COLOR_FADED=$FT_RET
    _ft_theme_compose statusbar 0; [[ -n "$FT_RET" ]] && FT_COLOR_STATUS=$FT_RET
    _ft_theme_compose keycap   0; [[ -n "$FT_RET" ]] && FT_COLOR_KEYCAP=$FT_RET
    _ft_theme_compose hint     0; [[ -n "$FT_RET" ]] && FT_COLOR_HINT=$FT_RET
    _ft_theme_compose caret    0; [[ -n "$FT_RET" ]] && FT_COLOR_CARET=$FT_RET
    _ft_theme_compose caretro  0; [[ -n "$FT_RET" ]] && FT_COLOR_CARET_RO=$FT_RET
    _ft_theme_compose view     0; [[ -n "$FT_RET" ]] && FT_COLOR_VIEW=$FT_RET
    _ft_theme_compose caution  0; [[ -n "$FT_RET" ]] && FT_COLOR_CAUTION=$FT_RET
    _ft_theme_compose warn     0; [[ -n "$FT_RET" ]] && FT_COLOR_WARN=$FT_RET
    FT_COLOR_FOCUS_BTN=$FT_COLOR_FOCUS; FT_COLOR_SEL=$FT_COLOR_FOCUS
    # FT_COLOR_RESET is a CLEAN-SLATE reset: \e[0m (clears bold/dim/underline/reverse) THEN body
    # colours. A colours-only reset (the old FT_COLOR_BODY) could not clear an attribute, so a
    # span that turned on bold — e.g. the border-sheen crest — leaked bold onto whatever was
    # painted next (the "text goes bold after you tab away" bug). This is the ONE terminator
    # every control closes a styled span with, so fixing it here fixes every attribute leak.
    FT_COLOR_RESET=$FT_ANSI_RESET$FT_COLOR_BODY
    _ft_theme_var_sgr --accent-text 38; [[ -n "$FT_RET" ]] && FT_COLOR_TEXT_ACCENT=$FT_RET
    _ft_theme_var_sgr --notice-text 38; [[ -n "$FT_RET" ]] && FT_COLOR_TEXT_NOTICE=$FT_RET
    _ft_theme_var_sgr --muted-text  38; [[ -n "$FT_RET" ]] && FT_COLOR_TEXT_MUTED=$FT_RET
    # The SCROLLING rung needs its own hue. A merely-poised field and a scrolling one
    # both fell back to --accent-text, so they were BYTE-IDENTICAL: climbing the first rung
    # changed nothing on screen. Each runlevel now sits well apart on the wheel —
    # azure (poised) → violet (scrolling) → gold (editing) / cyan (perusing).
    _ft_theme_var_sgr --scrolling-text 38; [[ -n "$FT_RET" ]] && FT_COLOR_SCROLLING=$FT_RET
    # The active-line lift is a BACKGROUND ONLY, on purpose: it is composed over whatever well
    # the field already has, so an editable input and a read-only viewer each lift from their
    # own colour and keep their own text colour. A role class would have dragged a foreground
    # along with it and recoloured the caret line's text.
    # Named for the selector it backs — `textfield::active` — so a theme author who wants to
    # override it in CSS instead of in a variable can guess the rule and be right.
    _ft_theme_var_sgr --textfield-active-bg 48; FT_COLOR_ACTIVELINE=$FT_RET
    ft_style "$P" --cursor-color; [[ -n "$FT_RET" ]] && FT_CURSOR_COLOR=$FT_RET
    ft_style "$P" --sheen-glow;   [[ -n "$FT_RET" ]] && FT_SHEEN_GLOW=$FT_RET
    _ft_setprop "$P" class ""     # leave the probe clean
}

# ── Built-in themes (authored in real CSS) ───────────────────────────────────
# ft-dark is the canonical palette expressed as a stylesheet — its derived globals are
# pinned byte-for-byte to ft_setup_palette's dark values (tests/test-theme.bash), so an
# app that does `ft_use_theme ft-dark` renders identically to the hand-written palette.
# ft-light / ft-ocean reuse the same vocabulary; globals outside the vocabulary are
# inherited from ft_setup_palette (as the demos already did before this system existed).
# The FULL palette, authored as CSS. `:root` carries only inheriting CUSTOM PROPERTIES
# (colours would leak into every bg-/fg-only role, since the derivation probe is the root);
# the screen backdrop is `.screen`. Every FT_COLOR_* global is derived from one of these rules
# (see _ft_theme_sync) — there is no hand-written palette any more. Values here match the
# historical ft_setup_palette dark palette byte-for-byte (pinned in tests/test-theme.bash).
ft_theme name=ft-dark style="
    :root        { --accent-text:39; --notice-text:220; --muted-text:245; --scrolling-text:141; --engaged-bg:236;
                   --cursor-color:#5fd7ff; --sheen-glow:18; --textfield-active-bg:235;
                   --locator-1:220; --locator-2:208; --locator-3:51;
                   --keycap-pulse:214 220 227 231 227 220;
                   --keycap-exit-pulse:208 214 220 226 220 214; }
    .screen      { background-color:16;  color:250; }
    :focus       { background-color:39;  color:16;  font-weight:bold; }
    .surface     { background-color:234; color:255; }
    .pane        { background-color:233; color:255; }
    .title       { background-color:234; color:51;  font-weight:bold; }
    .heading     { background-color:23;  color:255; font-weight:bold; }
    .border      { background-color:234; color:250; }
    .boxline     { background-color:233; color:73;  }
    .boxtext     { background-color:233; color:87;  font-weight:bold; }
    .subtext     { background-color:233; color:110; }
    .divider     { background-color:234; color:240; }
    .selected    { background-color:22;  color:255; }
    .seldim      { background-color:238; color:250; }
    .btn         { background-color:244; color:16;  }
    .input       { background-color:232; color:253; }
    .input:focus { background-color:24;  color:231; font-weight:normal; }
    .field       { background-color:239; color:255; }
    .fieldlocked { background-color:237; color:245; }
    .thumb       { background-color:245; }
    .knob        { background-color:234; color:44;  }
    .stripe      { background-color:238; color:255; }
    .disabled    { background-color:233; color:240; }
    .disabledtext { color:242; }
    .faded       { background-color:233; color:240; }
    .statusbar   { background-color:25;  color:231; }
    .keycap      { background-color:25;  color:227; font-weight:bold; }
    .hint        { background-color:236; color:252; }
    .caret       { background-color:220; color:16;  font-weight:bold; }
    .caretro     { background-color:44;  color:16;  font-weight:bold; }
    .view        { color:44; }
    .caution     { background-color:233; color:214; }
    .warn        { background-color:234; color:214; }
"
# A role may legitimately declare NO background-color — `.view` does, so a read-only viewer
# sits on whatever is behind it instead of stamping a well. That is CSS's `transparent`, and
# resolving it is the RENDERER's job (see _ft_inherited_bg in ft-forms.bash), not something
# every theme has to remember to paper over.
#
# ft-light / ft-ocean override the roles they want to recolour; anything they leave out keeps
# the value from the previously-active theme (the derivation leaves a global unchanged when a
# theme is silent about it), so they need only spell out what differs.
ft_theme name=ft-light style="
    :root        { --accent-text:25; --notice-text:130; --muted-text:245; --scrolling-text:91; --engaged-bg:189;
                   --cursor-color:#005fd7; --textfield-active-bg:255;
                   --locator-1:202; --locator-2:166; --locator-3:33;
                   --keycap-pulse:208 214 220 227 220 214;
                   --keycap-exit-pulse:202 208 214 208 202 196; }
    .screen      { background-color:250; color:240; }
    :focus       { background-color:25;  color:255; font-weight:bold; }
    .surface     { background-color:254; color:235; }
    .pane        { background-color:253; color:235; }
    .title       { background-color:254; color:25;  font-weight:bold; }
    .border      { background-color:254; color:244; }
    .divider     { background-color:254; color:249; }
    .selected    { background-color:29;  color:255; }
    .input       { background-color:252; color:235; }
    .input:focus { background-color:153; color:17;  font-weight:normal; }
    .stripe      { background-color:251; color:235; }
    .faded       { background-color:252; color:245; }
"
ft_theme name=ft-ocean style="
    :root        { --accent-text:51; --notice-text:222; --muted-text:66; --scrolling-text:171; --engaged-bg:18;
                   --cursor-color:#00d7ff; --textfield-active-bg:23;
                   --locator-1:51; --locator-2:87; --locator-3:220;
                   --keycap-pulse:45 51 87 123 87 51;
                   --keycap-exit-pulse:214 220 226 220 214 208; }
    .screen      { background-color:17;  color:111; }
    :focus       { background-color:51;  color:17;  font-weight:bold; }
    .surface     { background-color:23;  color:231; }
    .pane        { background-color:22;  color:231; }
    .title       { background-color:23;  color:123; font-weight:bold; }
    .border      { background-color:23;  color:80;  }
    .divider     { background-color:23;  color:66;  }
    .selected    { background-color:41;  color:16;  font-weight:bold; }
    .input       { background-color:17;  color:159; }
    .input:focus { background-color:31;  color:231; font-weight:normal; }
    .stripe      { background-color:24;  color:231; }
    .faded       { background-color:17;  color:66;  }
"

# ── The ACTIVATED marker ─────────────────────────────────────────────────────
# Merely poised means "the arrows move BETWEEN controls"; engaged means "the arrows
# now belong to THIS control". Those are opposite meanings for one keypress, and a slider
# painted byte-for-byte identically in both — the only way to tell was to press an arrow and
# watch what moved. ONE rule covers every prototype and every runlevel NAME (adjusting / browsing
# / editing / scrolling / perusing …) because it asks the only question that generalises: is
# this control still at rest?
#
# It is an ORDINARY sheet, deliberately not the theme/default one. A default sheet is cascade
# level 4, and `_ft_color_override` — how most controls ask "has anything overridden my
# colour?" — ignores that level on purpose, since a user-agent default is not an override. Put
# there, the rule resolved correctly through ft_style and never reached a single paint.
#
# The colour comes from the active theme through var(), so switching themes retints it and a
# theme that says nothing still gets a sane default.
# ── The ENGAGED marker ───────────────────────────────────────────────────────
# A control that has taken the keys must LOOK like it. `:engaged` (ft-forms.bash) is true for
# any control at a runlevel other than `unfocused`, whatever that prototype calls it, so one rule
# covers every control there will ever be.
#
# An ORDINARY sheet, deliberately not the theme/default one. A default sheet is cascade level 4
# and `_ft_color_override` — how most controls ask "has anything overridden my colour?" —
# ignores that level on purpose, since a user-agent default is not an override. Written there
# the rule resolved correctly through ft_style and never reached a single paint.
#
# The colour comes from the active theme through var(), so switching themes retints it and a
# theme that says nothing still gets a sane default.
#
# IT MUST BE A LIFT, NOT A HUE. This paints the whole element, which for a text box is the
# ground under the TEXT — and a saturated fill behind text is what a SELECTION looks like, so
# a reader sees their document highlighted rather than their control engaged. Dark shipped 53
# (95,0,95, a magenta at rgb distance 123 from the 8,8,8 well) and ocean shipped 54; both read
# as "this text is selected". A neutral step along the theme's own ground — dark 235 (38,38,38,
# distance 52), ocean 18 — says "this control has the keys" and cannot be confused with the
# selection band, which in dark is 0,175,255 and over 250 away from any of them.
#
# So a theme choosing this value has one rule to follow: stay in the ground's own hue family
# and move only far enough to be seen. Reach for a colour and you have written a highlighter.
ft_stylesheet name=ft-engaged style='
    :engaged { background-color: var(--engaged-bg, 235); }
'

# ── Built-in animations, authored as REAL @keyframes ─────────────────────────
# The SHARED MECHANICS live here, in a stylesheet that is always in the cascade. `animation:
# pulse|blink` is ordinary CSS, not a hardcoded name. pulse/blink use `opacity` (the CSS
# primitive), so they dim whatever colour the element already has toward its background — they
# adapt to any element/theme with no colour spelled out. The THEMEABLE bits are custom
# properties (here `--pulse-min`, the dim floor): a keyframe reads them with var(), and each
# theme's :root sets them, so switching theme re-tunes the animation without redefining it —
# the ramps re-resolve per-element on the swap. Apps add/override their own @keyframes
# (`@keyframes glow { from,to { color: var(--accent-text) } 50% { color: gold } }`). sheen/
# beacon stay text-field border ROUTINES (they animate glyph geometry) referenced by name.
_ft_css_parse ft-builtin-anims '
    @keyframes pulse { from, to { opacity: 1; } 50% { opacity: var(--pulse-min, 0.45); } }
    @keyframes blink { from, 49% { opacity: 1; } 50%, to { opacity: 0; } }
'

# ── CSS-declarable animation (works on ANY control) ──────────────────────────
# Turn an animation on from the stylesheet and it runs LIVE — pure CSS:
#     @keyframes glow { from,to { color: crimson } 50% { color: gold } }
#     checkbox { animation: glow; }        radio:focus { animation: pulse 1.5s; }
# `animation: NAME [<time>]` names a @keyframes (built-in pulse/blink or your own); its per-
# property ramps (color/background-color/font-weight/opacity) are sampled at the phase and
# composed. It rides the shared animation engine — one loop per control, repainted each tick —
# armed/disarmed automatically as the cascade changes (re-applying an edited stylesheet
# switches it on/off with no wiring). A control already running its border sheen is left alone.
declare -A FT_CSS_ANIMATION_ON=()
FT_CSS_ANIMATION_MS=120
# THE LOOP'S LENGTH IS THE RAMP'S LENGTH. _ft_css_kf_compose samples every ramp at
# `phase % rampLength`, so a loop that does not wrap on a whole number of ramp cycles jumps
# mid-ramp when it wraps. This used to arm a fixed 240 — chosen because it divides the ramp
# lengths that were common at the time — and `pulse` builds 25 samples: 240 % 25 = 15, so
# phase 239 sat on sample 14 and the next frame was sample 0. A visible lurch every 19.2s.
# Passing the ramp's own length makes the wrap seamless for every ramp, including the ones
# nobody has written yet, and makes the declared duration the true cycle: _ft_css_frame_ms
# already spreads the duration over exactly these samples.
_ft_css_anim_arm() {            # name frameMs rampLength — start (or RE-RATE) the colour loop
    local name=$1 frame_ms=${2:-$FT_CSS_ANIMATION_MS} ramp_length=${3:-240}
    if [[ -n "${FT_ANIM_PHASE[$name]:-}" ]]; then
        # Already looping — update the rate AND the length in place, so an edited
        # animation-duration or an edited @keyframes takes effect LIVE (without this, changing
        # `animation: glow 2s` → `4s` did nothing, and switching to a @keyframes with a
        # different number of samples kept the old ramp's wrap point). Only OUR colour loop;
        # never re-rate someone else's animation (e.g. a border sheen we don't own).
        if [[ -n "${FT_CSS_ANIMATION_ON[$name]:-}" ]]; then
            [[ -n "${2:-}" ]] && FT_ANIM_FRAME_MS[$name]=$frame_ms
            if [[ -n "${3:-}" ]] && (( ramp_length > 0 )); then
                FT_ANIM_LENGTH[$name]=$ramp_length
                # A phase left over from a longer ramp would sit past the new end until the
                # engine's own wrap caught it a frame later; fold it in now.
                (( FT_ANIM_PHASE[$name] %= ramp_length ))
            fi
        fi
        return 0
    fi
    (( ramp_length > 0 )) || ramp_length=240
    ft_anim_start "$name" "$ramp_length" "$frame_ms" 1 1  # loop; no bound frame ⇒ engine repaints it
    FT_CSS_ANIMATION_ON[$name]=1
}
_ft_css_anim_disarm() {         # name — stop OUR colour loop (never someone else's animation)
    [[ -n "${FT_CSS_ANIMATION_ON[$1]:-}" ]] || return 0
    unset "FT_CSS_ANIMATION_ON[$1]"; ft_anim_stop "$1"
}
# A CSS <time> → milliseconds. "2s"→2000, "1.5s"→1500, "500ms"→500, bare "120"→120, ""→0.
_ft_css_duration_ms() {         # value → FT_RET ms
    local v=$1; FT_RET=0; [[ -z "$v" ]] && return
    if [[ "$v" == *ms ]]; then v=${v%ms}; [[ "$v" =~ ^[0-9]+$ ]] && FT_RET=$v; return; fi
    if [[ "$v" == *s ]]; then v=${v%s}
        local ip=${v%%.*} fp=""; [[ "$v" == *.* ]] && fp=${v#*.}
        [[ "${ip:-0}" =~ ^[0-9]+$ && "${fp:-0}" =~ ^[0-9]*$ ]] || return
        fp=${fp}000; fp=${fp:0:3}; FT_RET=$(( 10#${ip:-0}*1000 + 10#${fp:-0} )); return
    fi
    [[ "$v" =~ ^[0-9]+$ ]] && FT_RET=$v
}
# Per-frame ms for a loop: the cycle DURATION spread over the ramp's length, else the default.
_ft_css_frame_ms() {            # durationMs rampLen → FT_RET
    local dur=$1 len=$2
    (( dur <= 0 || len <= 0 )) && { FT_RET=$FT_CSS_ANIMATION_MS; return; }
    FT_RET=$(( dur / len )); (( FT_RET < 16 )) && FT_RET=16   # clamp to a sane frame floor
}
# The cycle duration (ms) for an animation: an explicit animation-duration, else a <time>
# token in the `animation` shorthand (`animation: glow 2s`), else 0 (⇒ the default frame ms).
_ft_css_anim_duration() {       # durationValue animValue → FT_RET ms
    if [[ -n "$1" ]]; then _ft_css_duration_ms "$1"; return; fi
    local tok
    for tok in $2; do [[ "$tok" =~ ^[0-9.]+(s|ms)$ ]] && { _ft_css_duration_ms "$tok"; return; }; done
    FT_RET=0
}
# Does the ELEMENT or any of its known STRUCTURES want a (non-none) animation? The one loop
# per control is armed while this is true — so a structure animation (e.g. a pulsing
# scrollbar) keeps running even though the element itself does not animate.
_ft_css_anim_pes="border caret caretro scrollbar track thumb selection cursor selected header stripe active tab keycap hint placeholder gutter wrap"
_ft_css_wants_anim() {          # control → 0 if anything on it wants to animate
    local c=$1 pe
    ft_style "$c" animation; [[ -n "$FT_RET" && "$FT_RET" != none ]] && return 0
    for pe in $_ft_css_anim_pes; do
        _ft_css_query_pe "$c" "$pe" animation
        (( _QGOT )) && [[ -n "$FT_RET" && "$FT_RET" != none ]] && return 0
    done
    return 1
}
# → FT_RET = the animated foreground SGR for the current phase; returns 0 iff an animation is
# running (`animation` set, not `none`, with a resolvable ramp). Arms the loop as a side
# effect (idempotent). Because the cascade decides `animation`, a state-scoped rule like
# `button:focus { animation: pulse }` turns the loop ON when the control enters that state and
# OFF when it leaves — per-event animation, for free.
# A @keyframes ramp's length = the longest of its per-property ramps. Reads the TRANSIENT
# ramps set by the preceding _ft_css_kf_for (per-element resolved).
_ft_css_kf_len() {              # → FT_RET
    local best=0 n ramp
    for ramp in "$_KF_FG" "$_KF_BG" "$_KF_WT" "$_KF_OP"; do
        [[ -z "$ramp" ]] && continue; local -a r=($ramp); n=${#r[@]}; (( n > best )) && best=$n
    done; FT_RET=$best
}
# Is the animation value's first token a defined @keyframes? (sheen/beacon are not — they are
# text-field border ROUTINES referenced by name, handled by the border-animation system.)
_ft_css_kf_is() { [[ -n "${FT_CSS_KEYFRAMES_SOURCE[${1%% *}]:-}" ]]; }
# → FT_RET = the animated SGR for the element at the current phase; returns 0 iff a @keyframes
# animation is running (`animation: NAME`, NAME a @keyframes, not `none`). Arms the loop as a
# side effect. Because the cascade decides `animation`, a state-scoped rule like
# `button:focus { animation: pulse }` turns it ON on entering the state and OFF on leaving.
# Non-@keyframes names (sheen/beacon) are the text-field border routines, handled elsewhere.
#
# MEMOISED PER FRAME, because it is now asked TWICE per frame: once by the engine to name the
# frame (so an unchanged one is never drawn) and once by the paint that draws it. Recomputing
# it the second time made the frame-name guard cost more than it saved on a ramp that barely
# quantises — measured, `pulse` went 14.9% -> 16.6% of a core with the guard and no memo,
# while `glow`, which collapses 25 samples into 7 distinct SGRs at 256 colours, went
# 14.5% -> 8.9%. With the memo both are wins.
#
# THE INVALIDATION SURFACE, enumerated (CONTRIBUTING §3): the phase, the cascade epoch and this
# element's own cascade version (a restyle), FT_FOCUS and FT_ROOT (ft_style resolves state-
# scoped rules through them, so `button:focus { animation: … }` must not serve a blurred
# answer), and FT_COLOR_MODE (the same ramp composes 24 distinct SGRs in truecolour and 7 at
# 256). Same shape and same reasoning as _ft_css_kf_for's own token, two functions above.
declare -A _FT_CSS_ANIM_FG=() _FT_CSS_ANIM_FG_AT=()
_ft_css_anim_fg() {             # name
    local token="${_FT_CSS_EPOCH}:${_FT_CSS_VERSION[$1]:-0}:${FT_FOCUS:-}:${FT_ROOT:-}:${FT_COLOR_MODE}:${FT_ANIM_PHASE[$1]:-0}"
    # Only serve the memo for an animation that is already ARMED. The uncached path arms as a
    # side effect, so serving a cached answer to a control whose loop has been stopped — by
    # hiding it, say — would answer its colour and never start it running again.
    if [[ -n "${FT_ANIM_PHASE[$1]:-}" && "${_FT_CSS_ANIM_FG_AT[$1]:-}" == "$token" ]]; then
        FT_RET=${_FT_CSS_ANIM_FG[$1]}
        [[ -n "$FT_RET" ]]
        return
    fi
    _ft_css_anim_fg_uncached "$1"
    local composed=$FT_RET
    _FT_CSS_ANIM_FG[$1]=$composed; _FT_CSS_ANIM_FG_AT[$1]=$token
    FT_RET=$composed
    [[ -n "$FT_RET" ]]
}
_ft_css_anim_fg_uncached() {    # name
    # Every "there is no animation here" exit clears FT_RET first: it is about to be stored by
    # the memo above, and an early return that leaves the last lookup's value in FT_RET would
    # cache the string "none" as this element's animated colour.
    ft_style "$1" animation; local anim=$FT_RET
    [[ -z "$anim" || "$anim" == none ]] && { FT_RET=""; return 1; }
    _ft_css_kf_is "$anim" || { FT_RET=""; return 1; }
    local first=${anim%% *} phase=${FT_ANIM_PHASE[$1]:-0}
    _ft_css_kf_for "$1" "$first"                              # resolve var() against THIS element
    _ft_css_kf_len; local m=$FT_RET; (( m == 0 )) && { FT_RET=""; return 1; }
    # The element's USED colours — the base a colour-less (opacity) frame animates. Used, not
    # specified: an opacity ramp has nothing to modulate against "" and composes an empty
    # frame for its whole lap, which is how `animation: pulse` on an element with no declared
    # colour ran invisibly at the price of a full repaint per frame.
    _ft_used_color "$1";            local basefg=$FT_RET
    _ft_used_background_color "$1"; local basebg=$FT_RET
    ft_style "$1" animationDuration; _ft_css_anim_duration "$FT_RET" "$anim"
    _ft_css_frame_ms "$FT_RET" "$m"; _ft_css_anim_arm "$1" "$FT_RET" "$m"
    _ft_css_kf_compose "$phase" "$basefg" "$basebg"; [[ -n "$FT_RET" ]]
}
# The pseudo-element analogue: animate a STRUCTURE (`control::PE { animation: NAME }`). Shares
# the control's single loop (the engine keys a loop on a real control), so the structure and
# the element advance on the same phase. → FT_RET = the structure's animated SGR; 0 iff running.
_ft_css_anim_pe() {             # control pe channel → FT_RET
    local c=$1 pe=$2
    _ft_css_query_pe "$c" "$pe" animation; (( _QGOT )) || return 1
    local anim=$FT_RET
    [[ -z "$anim" || "$anim" == none ]] && return 1
    _ft_css_kf_is "$anim" || return 1
    local first=${anim%% *} phase=${FT_ANIM_PHASE[$c]:-0}
    _ft_css_kf_for "$c" "$first"                              # resolve var() against the control
    _ft_css_kf_len; local m=$FT_RET; (( m == 0 )) && return 1
    # As in _ft_css_anim_fg: the structure's own colours if it declares any, otherwise the
    # control's USED colours, so an opacity ramp on a pseudo-element has a base too.
    local basefg="" basebg=""
    _ft_css_query_pe "$c" "$pe" color;           (( _QGOT )) && basefg=$FT_RET
    _ft_css_query_pe "$c" "$pe" backgroundColor; (( _QGOT )) && basebg=$FT_RET
    [[ -z "$basefg" ]] && { _ft_used_color "$c";            basefg=$FT_RET; }
    [[ -z "$basebg" ]] && { _ft_used_background_color "$c"; basebg=$FT_RET; }
    _ft_css_query_pe "$c" "$pe" animationDuration; local dv=""; (( _QGOT )) && dv=$FT_RET
    _ft_css_anim_duration "$dv" "$anim"; _ft_css_frame_ms "$FT_RET" "$m"; _ft_css_anim_arm "$c" "$FT_RET" "$m"
    _ft_css_kf_compose "$phase" "$basefg" "$basebg"; [[ -n "$FT_RET" ]]
}
