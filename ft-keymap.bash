#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — ft-keymap.bash
#
#  Keymaps: ordered binding lists with reverse-scan / last-declared-wins matching,
#  bash-pattern keys (e.g. [[:alpha:]]), modifier tokens (CTRL+/ALT+/SHIFT+), a
#  bubble/drop default, sharing by reference, and a per-control local overlay
#  that cascades root→focused-leaf.
#
#  ── A binding is written as FIELDS ───────────────────────────────────────────
#      key=<pattern>  [keyCap="<label>"]  [keyImp=<importance>]  [onKey='<code>']
#
#  A `key=` opens a group; the fields after it describe that group until the next `key=`.
#  They are SEPARATE SHELL WORDS, which is the whole point: bash quoting does all the
#  escaping, so a label may contain a colon, a comma, quotes and an `=`, and code may
#  contain `;`, quotes, `=` and newlines, with nothing to escape and no inner grammar to
#  learn. Three earlier designs packed these into one token —  `ENTER=action`,
#  `ENTER="Edit":crucial:'code'` — and every one of them needed an escape rule for the
#  delimiter; the author's verdict on requiring escapes was "this is unacceptable".
#
#      key=EQUALS           the `=` key — the one key the field=value shape cannot spell
#      keyImp=              crucial | important | normal | minor, or a raw 0–255 weight
#      keyCap=              what the legend prints; no cap ⇒ bound but not advertised
#      onKey=             CODE (see below), or the reserved words `bubble` / `drop`
#
#  A cap WITHOUT code is legend-only: it advertises a key that somebody else handles
#  (engine Tab traversal), which is what the old `-` action meant.
#
#  Fields are accepted in four places, all parsed by _ft_keyfields:
#      ft_keymap_set MAP key=… …          a named map
#      ft-key key=… …                     a row inside ft-keymap NAME … end_ft_keymap
#      ft-button "Save" key=… …           any tag → that control's instance overlay
#      ft_prototype … key=… …             the prototype's own map
#  They are NOT properties. A control binds many keys and the property store holds one
#  value per name, so each group is folded into a keymap instead.
#
#  ── An ACTION IS CODE ────────────────────────────────────────────────────────
#  `onKey` holds shell code, evaluated with `$this` (the control the key was dispatched
#  to) and `$key` (the token) in scope — the same bargain HTML makes with onclick=, and
#  the reason the author asked for it: a binding used to be a FUNCTION NAME, invoked with
#  the control and the token appended silently. That convention had two costs. It was
#  invisible ("where are your arguments???"), and it meant every key needed a named
#  function to hold one line, which is most of why this framework had 341 public
#  functions — 106 of them existed only to be the right-hand side of a binding.
#
#      key=ENTER onKey='ft_activate $this'
#      key=s     onKey='ft_set status text="Saved"; ft_save'
#
#  Measured before adopting it: eval costs 8µs against 4µs for a direct call, per keypress.
#  A frame is milliseconds. Injection is not the risk it looks like — the string is code
#  you wrote, exactly like an onclick attribute; it must never be BUILT from untrusted data.
#
#  ── Storage ──────────────────────────────────────────────────────────────────
#  A keymap is a NAMED ordered list held in an indexed array _fti_<name>__list, each
#  element "PATTERN<TAB>CODE<TAB>IMPORTANCE<TAB>CAP". Order = precedence; the LAST matching
#  entry wins, so we scan in REVERSE and break on the first hit (newest-wins, efficient).
#  Re-binding an existing PATTERN removes the old element and appends a fresh one
#  (move-to-end → clean list, newest precedence, no stale duplicates).
#
#  The reserved pattern "default" holds bubble|drop for unmatched keys.
#
#  EVERY function here takes the keymap NAME and composes the storage array itself, so
#  `_fti_<name>__list` is private to this file and callers never spell it. The `_fti_`
#  prefix keeps the engine's side tables out of the caller's variable namespace — bash is
#  dynamically scoped, so an unprefixed `<name>__list` is visible to (and clobberable by)
#  any function in the call chain. Same reasoning as properties' `_ftp_` prefix.
#
#  ── Matching ─────────────────────────────────────────────────────────────────
#  An event token (e.g. ENTER, K, CTRL+a, or a literal char) is tested against each entry's
#  PATTERN via bash [[ == ]] so classes/globs work: [[:alpha:]], ?, *, [a-f]. Exact strings
#  match exactly. First hit in reverse order wins.
#
#  Depends on: _ft_importance (ft-forms.bash) for keyword importances. Used by ft-forms.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_KEYMAP_LOADED:-}" ]] && return 0
_FT_KEYMAP_LOADED=1

# ── Declaring a map ──────────────────────────────────────────────────────────
declare -A FT_KEYMAP_DEFINED=()

# _ft_keymap_declare_once NAME — declare NAME the first time it is asked for, and say so
# (return 0); return 1 if it already exists. A prototype's map is global but a prototype
# CONSTRUCTOR is not — building a derived prototype re-runs its base's constructor, so label's
# map would be declared again for button, checkbox and every other heir, emptying it. This is
# the engine's own guard and the reason no app ever needs one; `ft_keymap_once`, which every
# control used to call by hand, is gone.
_ft_keymap_declare_once() {
    [[ -n "${FT_KEYMAP_DEFINED[$1]:-}" ]] && return 1
    _ft_keymap_declare "$1"
    return 0
}

# _ft_keymap_declare NAME — create (or empty) NAME unconditionally. The engine's own
# instance overlays go through here: they are created on demand, once, by the control
# that needs one, so the duplicate question never arises for them.
_ft_keymap_declare() {
    local name=$1
    declare -g -a "_fti_${name}__list=()"
    FT_KEYMAP_DEFINED[$name]=1
    _ft_keymap_put "$name" default $'default\tbubble'
}

# ft_keymap NAME — declare an empty named keymap with a bubble default.
#
# A DUPLICATE IS AN ERROR. Re-declaring used to silently EMPTY the map, which is a
# destructive answer to what is nearly always a mistake — and the reason a whole second
# function (`ft_keymap_once`) existed, so that a prototype constructor running a second
# time for a derived prototype would not wipe the bindings the first run made. The engine
# now defines a prototype's map once and this says so out loud. `ft_keymap_clear` is the
# explicit way to ask for what re-declaring used to do by accident.
ft_keymap() {
    local name=$1
    if [[ -n "${FT_KEYMAP_DEFINED[$name]:-}" ]]; then
        printf 'ft: ft_keymap %s: already declared (use ft_keymap_clear to empty it)\n' "$name" >&2
        return 1
    fi
    _ft_keymap_declare "$name"
}

# ft-keymap NAME … end_ft_keymap — the same declaration as a BLOCK, so a map reads as a
# table of keys rather than a column of repeated map names:
#
#     ft-keymap ft_keymap_textfield_scrolling
#         ft-key key=UP    keyCap=Scroll keyImp=crucial onKey='ft_textfield_up $this'
#         ft-key key=ENTER keyCap=Edit   keyImp=crucial onKey='ft_textfield_edit $this'
#     end_ft_keymap
#
# `ft-key` exists because a bash line needs a command word; the hyphen says DECLARATION,
# the same rule every tag in this framework follows.
_FT_KEYMAP_BLOCK=""
ft-keymap() {
    # A block opened INSIDE a block means the first one lost its end_ft_keymap. The rows written
    # after that point still landed somewhere sensible, which is exactly why it was worth saying:
    # nothing about the result told you a `end_ft_keymap` was missing.
    [[ -n "$_FT_KEYMAP_BLOCK" ]] && \
        printf 'ft: ft-keymap %s: %s is still open — missing end_ft_keymap\n' "$1" "$_FT_KEYMAP_BLOCK" >&2
    ft_keymap "$1" || return 1
    _FT_KEYMAP_BLOCK=$1
}
ft-key() {
    if [[ -z "$_FT_KEYMAP_BLOCK" ]]; then
        printf 'ft: ft-key: no open ft-keymap block\n' >&2
        return 1
    fi
    _ft_keyfields "$_FT_KEYMAP_BLOCK" "$@"
}
end_ft_keymap() { _FT_KEYMAP_BLOCK=""; }

# ── The field parser ─────────────────────────────────────────────────────────
# _ft_keyfields MAP FIELD… — fold key-field groups into MAP.
#
# Callers hand it ONLY the key fields (each tag parser already walks its arguments and
# can recognise one in a case), so this never has to decide what is a property.
#
# An orphan modifier — keyCap= before any key= — is an authoring error, reported and
# dropped. It cannot be silently attached to the PREVIOUS group, because "the previous
# group" is whatever happened to be written before it, and a cap landing on the wrong
# key is a legend that lies.
_ft_keyfields() {               # map field…
    local map=$1; shift
    local f pat="" cap="" imp="" code="" open=0 bad=0 hascode=0
    for f in "$@"; do
        case $f in
            key=*)
                (( open )) && [[ -n "$pat" ]] && { _ft_keyfield_put "$map" "$pat" "$code" "$imp" "$cap" "$hascode" || bad=1; }
                pat=${f#key=}; cap=""; imp=""; code=""; hascode=0; open=1
                # A patternless key= still OPENS a group, so its modifiers are absorbed rather
                # than each reported as an orphan: one mistake, one message.
                [[ -z "$pat" ]] && { printf 'ft: %s: key= with no pattern\n' "$map" >&2; bad=1; } ;;
            keyCap=*)  if (( open )); then cap=${f#keyCap=};  else _ft_keyfield_orphan "$map" "$f"; bad=1; fi ;;
            keyImp=*)  if (( open )); then imp=${f#keyImp=};  else _ft_keyfield_orphan "$map" "$f"; bad=1; fi ;;
            onKey=*) if (( open )); then code=${f#onKey=}; hascode=1
                     else _ft_keyfield_orphan "$map" "$f"; bad=1; fi ;;
            *) printf 'ft: %s: "%s" is not a key field\n' "$map" "$f" >&2; bad=1 ;;
        esac
    done
    (( open )) && [[ -n "$pat" ]] && { _ft_keyfield_put "$map" "$pat" "$code" "$imp" "$cap" "$hascode" || bad=1; }
    return $bad
}
_ft_keyfield_orphan() {
    printf 'ft: %s: %s before any key= — dropped\n' "$1" "${2%%=*}=" >&2
}

# One group → one entry. IMPORTANCE resolves through the framework's single definition
# (_ft_importance), which a control's `importance=` property shares, so a key legend and a
# callout cannot disagree about what "important" is worth.
#
# _ft_importance RETURNS THROUGH FT_RET, and bindings are declared in tables interleaved
# with other FT_RET-returning calls — so calling it here without putting FT_RET back
# corrupted whatever the caller had in flight. Measured, when this was missing: the
# scrollbar's arrow bindings silently stopped dispatching while the importance values
# themselves were perfectly correct. Borrow FT_RET and give it back.
_ft_keyfield_put() {            # map pattern code importance cap hascode
    local map=$1 pat=$2 code=$3 imp=${4:-} cap=${5:-} hascode=${6:-0}
    if [[ -z "$code" ]] && (( ! hascode )) && [[ -z "$cap" ]]; then
        printf 'ft: %s: key=%s has neither onKey= nor keyCap=\n' "$map" "$pat" >&2
        return 1
    fi
    # `onKey=''` IS A BINDING — the one that eats the event. It is stored as the shell's own
    # no-op, which is exactly what it means: code that runs and does nothing, so the control
    # handled the key and, having not called ft_bubble, keeps it. That is what the reserved
    # word `drop` used to say, said in the language everything else here is written in.
    #
    # NO onKey= at all is a different thing and must stay different: a legend-only cap, which
    # advertises a key somebody else handles and must not swallow it.
    [[ -z "$code" ]] && (( hascode )) && code=':'      # `:` is the shell's no-op
    # `default` IS THE RESERVED PATTERN for "what an unmatched key does", and what it stores is
    # a POLICY word that _ft_keymap_default reads, not an action dispatch ever runs. Written as
    # a field it has to mean the same thing it means on a real key, or `onKey=''` would eat a
    # key here and pass one on there: an empty handler is "eat it" (drop), ft_bubble is "pass it
    # on" (bubble). The two words stay readable in the store, where the only reader is looking
    # for exactly them.
    if [[ "$pat" == default ]]; then
        case $code in
            ''|':')      code=drop ;;
            ft_bubble)   code=bubble ;;
            bubble|drop) : ;;                      # written out; the store's own vocabulary
            *) printf 'ft: %s: key=default takes onKey='"''"' (eat) or onKey=ft_bubble (pass on), not %s\n' \
                      "$map" "$code" >&2
               return 1 ;;
        esac
    fi
    case $imp in
        '') imp=0 ;;
        crucial|important|normal|minor)
            local _sv=$FT_RET; _ft_importance "$imp"; imp=$FT_RET; FT_RET=$_sv ;;
        *[!0-9]*)
            printf 'ft: %s: key=%s keyImp=%s is not crucial|important|normal|minor or 0-255\n' \
                   "$map" "$pat" "$imp" >&2
            imp=0 ;;
    esac
    _ft_keymap_put "$map" "$pat" "$pat"$'\t'"$code"$'\t'"$imp"$'\t'"$cap"
}

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

# ── The five calls ───────────────────────────────────────────────────────────
# ft_keymap_set MAP FIELD… — add or replace bindings, as many per call as you like.
ft_keymap_set() {
    local map=$1; shift
    if [[ -z "${FT_KEYMAP_DEFINED[$map]:-}" ]]; then
        printf 'ft: ft_keymap_set %s: no such keymap (declare it with ft_keymap)\n' "$map" >&2
        return 1
    fi
    _ft_keyfields "$map" "$@"
}

# ft_keymap_unset MAP PATTERN — remove one binding.
ft_keymap_unset() {
    local -n L="_fti_${1}__list"
    local pat=$2 i keep=()
    for i in "${!L[@]}"; do
        [[ "${L[$i]%%$'\t'*}" == "$pat" ]] && continue
        keep+=("${L[$i]}")
    done
    L=("${keep[@]}")
}

# ft_keymap_clear MAP — empty it, keeping it declared. The explicit form of what
# re-declaring a map used to do silently.
ft_keymap_clear() {
    declare -g -a "_fti_${1}__list=()"
    _ft_keymap_put "$1" default $'default\tbubble'
}

# ft_keymap_dump MAP — the bindings as "PATTERN<TAB>CODE<TAB>IMPORTANCE<TAB>CAP" lines, in
# display order (declaration order, default last). For debugging and for tests.
ft_keymap_dump() {
    local -n L="_fti_${1}__list"
    local e
    for e in "${L[@]}"; do [[ "${e%%$'\t'*}" == default ]] || printf '%s\n' "$e"; done
}

# ft_keymap_default MAP bubble|drop — what an unmatched key does. Dispatch consults this
# only after every real binding has failed to match, so it can never beat one.
ft_keymap_default() {
    case $2 in bubble|drop) : ;;
        *) printf 'ft: ft_keymap_default %s: must be bubble or drop, got "%s"\n' "$1" "$2" >&2
           return 1 ;;
    esac
    _ft_keymap_put "$1" default "default"$'\t'"$2"
}

# ── Lookup (dispatch's half) ─────────────────────────────────────────────────
# _ft_keymap_lookup NAME TOKEN → sets FT_RET to the matched CODE if a binding matches
# (reverse scan, first hit wins), returns 0; else returns 1 (FT_RET untouched). The
# reserved "default" entry is skipped here (resolved separately so it always loses to a
# real binding). Sets FT_RET rather than echoing — this is called on every keypress, so a
# $(...) wrapper here would fork on every single key.
_ft_keymap_lookup() {
    local tok=$2
    local -n L="_fti_${1}__list"
    local i pat act rest
    for (( i=${#L[@]}-1; i>=0; i-- )); do
        pat="${L[$i]%%$'\t'*}"; rest="${L[$i]#*$'\t'}"; act="${rest%%$'\t'*}"  # CODE only
        [[ "$pat" == default ]] && continue
        [[ -z "$act" ]] && continue       # legend-only cap: advertised, not bound — let it bubble
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
    local i rest
    for (( i=${#L[@]}-1; i>=0; i-- )); do
        # FIELD TWO, not "everything after the first tab": `key=default onKey=drop` writes a
        # full four-field entry like any other group, and reading the rest of the line gave
        # "drop<TAB>0<TAB>", which equals neither `drop` nor `bubble` — so a drop default
        # silently stopped dropping.
        if [[ "${L[$i]%%$'\t'*}" == default ]]; then
            rest="${L[$i]#*$'\t'}"; FT_RET="${rest%%$'\t'*}"; return
        fi
    done
    FT_RET=bubble
}

# _ft_keymap_caps NAME → APPENDS this keymap's legend caps to the array FT_CAPS as
# "IMPORTANCE<TAB>PATTERN<TAB>CAP" lines, one per binding that declared a keyCap. Skips any
# PATTERN already present in FT_CAPS, so when a caller walks a chain nearest→root the
# nearest (most specific) cap for a key wins and a shadowed one up the chain is ignored.
# The caller sorts FT_CAPS by importance.
_ft_keymap_caps() {             # name (array FT_CAPS must exist)
    local -n L="_fti_${1}__list"
    local e pat rest imp label seen s
    for e in "${L[@]}"; do
        pat="${e%%$'\t'*}"
        [[ "$pat" == default || "$e" != *$'\t'*$'\t'* ]] && continue   # no legend fields → skip
        rest="${e#*$'\t'}"; rest="${rest#*$'\t'}"
        imp="${rest%%$'\t'*}"; label="${rest#*$'\t'}"
        [[ -z "$label" ]] && continue
        seen=0
        for s in "${FT_CAPS[@]}"; do [[ "${s#*$'\t'}" == "$pat"$'\t'* ]] && { seen=1; break; } done
        (( seen )) && continue
        FT_CAPS+=("${imp}"$'\t'"${pat}"$'\t'"${label}")
    done
}
