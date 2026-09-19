#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — ft-keymap.bash
#
#  Keymaps: ordered binding lists with reverse-scan / last-declared-wins matching,
#  bash-pattern keys (e.g. [[:alpha:]]), modifier tokens (CTRL+/ALT+/SHIFT+), a
#  bubble/drop default, sharing by reference, and a per-control local overlay
#  that cascades root→focused-leaf.
#
#  ── Storage ──────────────────────────────────────────────────────────────────
#  A keymap is a NAMED ordered list held in an indexed array _fti_<name>__list, each
#  element "PATTERN<TAB>ACTION". Order = precedence; the LAST matching entry wins,
#  so we scan in REVERSE and break on the first hit (newest-wins, efficient).
#  Re-binding an existing PATTERN removes the old element and appends a fresh one
#  (move-to-end → clean list, newest precedence, no stale duplicates).
#
#  The reserved pattern "default" holds bubble|drop for unmatched keys.
#
#  ── Matching ─────────────────────────────────────────────────────────────────
#  An event token (e.g. ENTER, K, CTRL+a, or a literal char) is tested against
#  each entry's PATTERN via bash [[ == ]] so classes/globs work: [[:alpha:]], ?,
#  *, [a-f]. Exact strings match exactly. First hit in reverse order wins.
#
#  ── Actions ──────────────────────────────────────────────────────────────────
#  An ACTION is a function name, or the reserved words "bubble" / "drop".
#
#  Depends on: nothing (pure bash). Used by ft-forms.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_KEYMAP_LOADED:-}" ]] && return 0
_FT_KEYMAP_LOADED=1

# ft-keymap NAME — declare an (empty) named keymap with a bubble default.
#
# EVERY function in this file takes the keymap NAME and composes the storage array itself,
# so `_fti_<name>__list` is private to this file and callers never spell it. The `_fti_`
# prefix keeps the engine's side tables out of the caller's variable namespace — bash is
# dynamically scoped, so an unprefixed `<name>__list` is visible to (and clobberable by) any
# function in the call chain. Same reasoning as properties' `_ftp_` prefix in ft-forms.bash.
ft-keymap() {
    local name=$1
    declare -g -a "_fti_${name}__list=()"
    ft-keymap-set "$name" default bubble
}

# ft_keymap_once NAME — declare NAME and return true, but only the FIRST time it is asked for.
#
# A prototype KEYMAP is global, but a prototype CONSTRUCTOR is not: it runs once per derived
# prototype, because building a derived prototype's struct means running its base prototype's
# constructor again (label's runs for label, button, checkbox…). So the keymap-building block
# inside a constructor had to be guarded, and every control invented its own flag to do it —
# _FT_KM_LABEL_READY, _FT_KM_TREE_READY, _FT_KM_SLIDER_READY, eight of them, each a global
# spelled out by hand.
# The guard is a property of the KEYMAP, so it belongs to the keymap:
#
#     if ft_keymap_once ft_keymap_label; then
#         ft-keymap-cap ft_keymap_label UP ft_label_key_up "$FT_IMPORTANCE_CRUCIAL" "Scroll up"
#         …
#     fi
declare -A FT_KEYMAP_DEFINED=()
ft_keymap_once() {              # name → 0 the first time only
    [[ -n "${FT_KEYMAP_DEFINED[$1]:-}" ]] && return 1
    FT_KEYMAP_DEFINED[$1]=1
    ft-keymap "$1"
    return 0
}

# An entry is TAB-separated: PATTERN <TAB> ACTION  [<TAB> IMPORTANCE <TAB> LABEL].
# The two trailing fields are the LEGEND metadata (ft-keymap-cap): IMPORTANCE is a raw
# 0–255 weight (higher = the user should notice it more — it drives the legend sort AND
# is handed to a keycap animation as `intensity`), LABEL is what the legend prints for
# the key. Plain ft-keymap-set omits them (importance 0, no label = not shown in a
# derived legend). Dispatch only ever reads the ACTION field, so both shapes coexist.
_ft_keymap_put() {              # name pattern fullentry — add/replace, move-to-end
    local -n L="_fti_${1}__list"
    local pat=$2 i keep=()
    for i in "${!L[@]}"; do
        [[ "${L[$i]%%$'\t'*}" == "$pat" ]] && continue   # drop old binding for this pattern
        keep+=("${L[$i]}")
    done
    keep+=("$3")
    L=("${keep[@]}")
}
# ft-keymap-set NAME PATTERN ACTION — add/replace a binding (move-to-end).
#
# The ACTION is required. Left off, the binding stored an empty action, and dispatch — which
# builds a command from the action's words and appends the control name and the token — was
# left with the CONTROL'S OWN NAME in the command position. A control called `rm` ran rm.
# Dispatch now refuses an empty action outright, but the mistake is an authoring one and
# this is where it can be said plainly, while a keymap is being declared rather than while
# a key is being pressed. Use `bubble` for "match this key and decline it".
ft-keymap-set() {
    if (( $# < 3 )); then
        printf 'ft: ft-keymap-set %s %s: no ACTION (use `bubble` to match and decline)\n' \
               "${1:-?}" "${2:-?}" >&2
        return 1
    fi
    _ft_keymap_put "$1" "$2" "$2"$'\t'"$3"
}
# ft-keymap-cap NAME PATTERN ACTION IMPORTANCE LABEL — a binding that ALSO appears in the
# derived key legend: IMPORTANCE ranks it, LABEL names it. This is how a control says "this
# is the key that matters here" — the legend sorts by importance so the key the user needs
# most leads, and the crucial ones can carry an attention animation.
# ACTION may be "-" for a LEGEND-ONLY cap: it shows in the legend but is not a dispatch
# binding, so the key bubbles to whoever really handles it (e.g. engine Tab traversal).
#
# IMPORTANCE is a raw 0–255 weight, or one of the three anchor KEYWORDS — the same
# keyword-or-value shape CSS uses for `font-weight: bold | 700`:
#     crucial (200) · important (120) · normal (60)
#
# ORDER: DECLARE THE BACKWARD KEY BEFORE ITS FORWARD PARTNER — Left before Right, PgUp before
# PgDn, Home before End, Prev before Next, Back before Okay. The legend's sort is by importance
# and STABLE, so equal-weight caps come out in declaration order, and a pair declared the wrong
# way round prints "▶ Next step   ◀ Prev step" — arrows pointing away from the direction they
# move. This is a layout rule, not a preference: what the user reads left-to-right must match
# what the keys do left-to-right.
#
# (Was `ft-keymap-cap`, which sat outside the ft-keymap* family. The arguments stayed
# positional deliberately: these are written in aligned tables of six or eight bindings,
# where a column reads far better than repeated key=/action=/label= noise.)
ft-keymap-cap() {               # map pattern action importance label
    # Omitted still means 0 — "bound, but not shown in a legend". The KEYWORDS resolve through the
    # framework's one definition (_ft_importance), which a control's `importance=` property shares,
    # so a key legend and a callout cannot disagree about what "important" is worth.
    # _ft_importance RETURNS THROUGH FT_RET, and prototype constructors declare their bindings in
    # tables interleaved with other FT_RET-returning calls — so calling it here without putting
    # FT_RET back corrupted whatever the caller had in flight. Measured: the scrollbar's arrow
    # bindings silently stopped dispatching (test-scrollbar 29/33, test-dispatch 44/47) while the
    # importance values themselves were perfectly correct. Same clobber this codebase has been
    # bitten by before; the fix is to borrow FT_RET and give it back, not to duplicate the table.
    local _imp=${4:-0} _sv_ret=$FT_RET
    case $_imp in
        crucial|important|normal|minor) _ft_importance "$_imp"; _imp=$FT_RET; FT_RET=$_sv_ret ;;
    esac
    _ft_keymap_put "$1" "$2" "$2"$'\t'"$3"$'\t'"$_imp"$'\t'"${5:-}"
}

# ft-keymap-unset NAME PATTERN — remove a binding.
ft-keymap-unset() {
    local name=$1 pat=$2
    local -n L="_fti_${name}__list"
    local i keep=()
    for i in "${!L[@]}"; do
        [[ "${L[$i]%%$'\t'*}" == "$pat" ]] && continue
        keep+=("${L[$i]}")
    done
    L=("${keep[@]}")
}

# ft-bindkeys NAME PATTERN=ACTION ... — convenience: apply several at once.
ft-bindkeys() {
    local name=$1; shift
    local kv pat act
    for kv in "$@"; do
        # `${kv#*=}` hands back the WHOLE string when there is no `=` in it, so a dropped
        # `=` bound the key to its own name as an action — `ft-bindkeys map ENTER` bound
        # ENTER to a command called ENTER. Silent, and it looked like a working binding.
        if [[ "$kv" != *=* ]]; then
            printf 'ft: ft-bindkeys %s: "%s" is not PATTERN=ACTION\n' "$name" "$kv" >&2
            continue
        fi
        pat="${kv%%=*}"; act="${kv#*=}"
        ft-keymap-set "$name" "$pat" "$act"
    done
}

# _ft_keymap_lookup NAME TOKEN → sets FT_RET to the matched ACTION if a
# binding matches (reverse scan, first hit wins), returns 0; else returns 1
# (FT_RET untouched). The reserved "default" entry is skipped here (resolved
# separately so it always loses to a real binding). Sets FT_RET rather than
# echoing — this is called on every keypress dispatch (ft_dispatch_keymap),
# so a $(...) wrapper here would fork on every single key.
_ft_keymap_lookup() {
    local tok=$2
    local -n L="_fti_${1}__list"
    local i pat act rest
    for (( i=${#L[@]}-1; i>=0; i-- )); do
        pat="${L[$i]%%$'\t'*}"; rest="${L[$i]#*$'\t'}"; act="${rest%%$'\t'*}"  # ACTION only (ignore legend fields)
        [[ "$pat" == default ]] && continue
        [[ "$act" == '-' ]] && continue   # legend-only cap (ft-keymap-cap … - …): shown, but NOT a binding — let it bubble
        # The RHS is intentionally UNQUOTED so bash pattern/class matching applies
        # ([[:alpha:]], ?, *, [a-f]); an exact string simply matches itself.
        # shellcheck disable=SC2053
        if [[ "$tok" == $pat ]]; then FT_RET=$act; return 0; fi
    done
    return 1
}

# _ft_keymap_default NAME → sets FT_RET to the default action (bubble|drop).
_ft_keymap_default() {
    local -n L="_fti_${1}__list"
    local i
    for (( i=${#L[@]}-1; i>=0; i-- )); do
        if [[ "${L[$i]%%$'\t'*}" == default ]]; then FT_RET="${L[$i]#*$'\t'}"; return; fi
    done
    FT_RET=bubble
}

# Render a keymap as "PATTERN<TAB>ACTION" lines (for ft-keylegend / debugging),
# in display order (declaration order, default last).
ft-keymap-dump() {
    local -n L="_fti_${1}__list"
    local e
    for e in "${L[@]}"; do [[ "${e%%$'\t'*}" == default ]] || printf '%s\n' "$e"; done
}

# _ft_keymap_caps NAME → APPENDS this keymap's legend caps to the array FT_CAPS as
# "IMPORTANCE<TAB>PATTERN<TAB>LABEL" lines, one per binding that declared a LABEL (i.e.
# was set with ft-keymap-cap). Skips any PATTERN already present in FT_CAPS, so when a caller
# walks a chain nearest→root the nearest (most specific) label for a key wins and a
# shadowed one up the chain is ignored. The caller sorts FT_CAPS by importance.
_ft_keymap_caps() {             # name (array FT_CAPS must exist)
    local -n L="_fti_${1}__list"
    local e pat rest act imp label seen s
    for e in "${L[@]}"; do
        pat="${e%%$'\t'*}"
        [[ "$pat" == default || "$e" != *$'\t'*$'\t'* ]] && continue   # no legend fields → skip
        rest="${e#*$'\t'}"; act="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
        imp="${rest%%$'\t'*}"; label="${rest#*$'\t'}"
        [[ -z "$label" ]] && continue
        seen=0
        for s in "${FT_CAPS[@]}"; do [[ "${s#*$'\t'}" == "$pat"$'\t'* ]] && { seen=1; break; } done
        (( seen )) && continue
        FT_CAPS+=("${imp}"$'\t'"${pat}"$'\t'"${label}")
    done
}
