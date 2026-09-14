#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  The resolved-property memo tells the truth after every route that can change an answer.
#
#  `ft_resolved_prop` is memoised (see the long note above _ft_resolve_inval in ft-forms.bash),
#  and the whole risk of that memo is its key. A stale entry here is not a crash: it is a wrong
#  colour, a wrong width, a control that keeps a property it was just told to drop — silent, and
#  only visible on screen. So this file drives every route in that enumeration:
#
#      ft-modify n width=…            a property the control resolves for itself
#      ft-modify container color=…    an INHERITING property — the whole subtree reads it
#      ft_remove_attribute            the same two, on the other route in
#      ft_remove + rebuild            a recycled name must not read the dead control's answers
#      ft_clone                       stamps _ftp_* with printf -v, behind _ft_setprop's back
#      ft_append (reparent)           the moved node inherits through somewhere else now
#      ft_stylesheet                  a sheet DECLARING a property is store-condition 3 itself
#      ft-modify n style="…"          _ft_setprop's early exit that writes and returns
#      ft-modify n onActivate=fn      …and its other one
#      a multitoggle's selectedIndex  the one control that writes a property variable directly
#
#  THE COMPARISON is against the real function with its table emptied — not against a hard-coded
#  value — so it keeps working when the box model or a class default legitimately changes. The
#  truth walk snapshots the table, clears it, asks, and PUTS IT BACK, because a stale entry can
#  only be caught by an ask that finds a warm one; a helper that left the table empty would make
#  every following read a guaranteed miss and every assertion below vacuous.
#
#  ANTI-VACUITY: the file first proves the memo is LIVE — that a planted answer is served — so
#  "the memo agrees with the truth" cannot be passing merely because nothing is ever memoised.
#
#  TEETH. Run with FT_RESOLVEMEMO_SABOTAGE naming a route (pair|subtree|global|all) and the
#  corresponding invalidation is disabled; each sabotage must turn this file red. The teeth
#  section at the foot runs each in a subshell and requires failure, so a future edit that
#  neuters the memo cannot leave this file passing.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_ROWS=30; FT_COLS=100; FT_USE_UTF8=1

# ── sabotage, for the teeth ──────────────────────────────────────────────────
_sab=${FT_RESOLVEMEMO_SABOTAGE:-}
case "$_sab" in pair|all)    _ft_resolve_forget()   { :; } ;; esac
case "$_sab" in subtree|all) _ft_resolve_inval()    { :; } ;; esac
case "$_sab" in global|all)  _ft_resolve_inval_all() { :; } ;; esac

# ── the instrument: what a from-scratch resolution says ──────────────────────
_truth() {                      # name prop [default] → TRUTH
    local -a _sk=() _sv=() _st=()
    local _k _i
    for _k in "${!_FT_RESOLVED_PROP_MEMO[@]}"; do
        _sk+=("$_k"); _sv+=("${_FT_RESOLVED_PROP_MEMO[$_k]}"); _st+=("${_FT_RESOLVED_PROP_MEMO_AT[$_k]}")
    done
    _FT_RESOLVED_PROP_MEMO=(); _FT_RESOLVED_PROP_MEMO_AT=()
    ft_resolved_prop "$@"
    TRUTH=$FT_RET
    _FT_RESOLVED_PROP_MEMO=(); _FT_RESOLVED_PROP_MEMO_AT=()
    for _i in "${!_sk[@]}"; do
        _FT_RESOLVED_PROP_MEMO[${_sk[$_i]}]=${_sv[$_i]}
        _FT_RESOLVED_PROP_MEMO_AT[${_sk[$_i]}]=${_st[$_i]}
    done
}
# Ask through the memo FIRST — that ask must find the warm entry the mutation should have
# killed — and only then compute the truth.
_agree() {                      # desc name prop [default]
    local _d=$1; shift
    ft_resolved_prop "$@"; local _memoised=$FT_RET
    _truth "$@"
    check "$_d" "$_memoised" "$TRUTH"
}
_warm() { ft_resolved_prop "$@" >/dev/null; }   # make the pair present in the table

ft-form name=app width=100 height=30
    ft-frame name=win width=60 height=20 color=201
        ft-label name=leaf text="leaf"
        ft-label name=other text="other"
    end_ft_frame
end_ft_form
FT_ROOT=app
ft_layout app

# ── the memo is LIVE ─────────────────────────────────────────────────────────
# Everything below compares the memo against the truth, so if nothing is ever stored every
# assertion is two identical fresh computations and this file proves nothing. Plant an answer
# no resolution could produce and require the read to serve it.
note "the memo is actually serving reads (or nothing below means anything)"
_warm leaf width
_k="leaf"$'\x1f'"width"
check "a warm read left an entry in the table" \
      "$( [[ -n "${_FT_RESOLVED_PROP_MEMO_AT[$_k]:-}" ]] && echo yes )" "yes"
_FT_RESOLVED_PROP_MEMO[$_k]="planted"
ft_resolved_prop leaf width
check "…and the next read is served from it"  "$FT_RET" "planted"
_ft_resolve_forget leaf width       # put the planted lie back in its box

# ── a property the control resolves for itself ───────────────────────────────
note "a property write (ft-modify) — the pair"
_warm leaf width
ft-modify leaf width=17
_agree "width follows the write"                       leaf width
_warm leaf width
ft-modify leaf width=23
_agree "…and the next one"                             leaf width
check "the value is the one just written"              "$FT_RET" "23"

note "removing a property (ft_remove_attribute) — the same pair, the other route"
_warm leaf width
ft_remove_attribute leaf width
_agree "width falls back once the property is gone"    leaf width

# ── an INHERITING property: the subtree, not the pair ────────────────────────
note "an inheriting property on a container — every descendant reads it"
_warm leaf color
_warm other color
ft-modify win color=45
_agree "the descendant's colour follows its ancestor's" leaf color
_agree "…and so does its sibling's"                     other color
check "the colour is the one just written"              "$FT_RET" "45"
_warm leaf color
ft_remove_attribute win color
_agree "…and follows the ancestor's REMOVAL too"        leaf color

# ── a recycled name ──────────────────────────────────────────────────────────
# The scar this framework has already paid for once: a version UNSET on removal restarts at 0
# and compares equal to the dead control's, so a rebuild under the same name reads its answers.
note "a rebuilt control under the same name"
ft-label name=recycle text="first" width=11 parent=win
ft_layout app
_warm recycle width
check "the first incarnation resolves its own width"    "$FT_RET" "11"
ft_remove recycle
ft-label name=recycle text="second" width=22 parent=win
ft_layout app
_agree "the rebuild does not read the dead one's width" recycle width
check "…it reads its own"                               "$FT_RET" "22"

# ── ft_clone: printf -v straight into the shell ──────────────────────────────
note "ft_clone stamps properties behind _ft_setprop's back"
ft-label name=src text="src" width=31 parent=win
ft_layout app
_warm clonedst width                # resolve the name BEFORE it is a control
ft_clone src clonedst
_agree "the clone resolves the source's width"          clonedst width
check "…which is the source's"                          "$FT_RET" "31"

# ── reparenting ──────────────────────────────────────────────────────────────
note "a moved node inherits through somewhere else now"
ft-modify win color=201
ft-frame name=win2 width=30 height=8 color=99 parent=app
ft-label name=mover text="mover" parent=win
ft_layout app
_warm mover color
check "the mover inherits its first parent's colour"    "$FT_RET" "201"
ft_append win2 mover
_agree "…and its new parent's after the move"           mover color
check "…which is the new parent's"                      "$FT_RET" "99"

# ── a stylesheet declaring a property is store-condition 3 ───────────────────
# The memo only stores properties NO registered sheet declares. Registering one that DOES
# declare a property makes every entry for it wrong, whatever node it is on.
note "a stylesheet that declares a property the memo had already answered"
# No author width: an instance property is cascade level 1 and would beat the sheet outright,
# which would prove nothing about the memo.
ft-label name=sheeted text="sheeted" parent=win2
ft_layout app
_warm sheeted width
check "before the sheet, nothing resolves a width"      "$FT_RET" ""
ft_stylesheet name=memotest style='#sheeted { width: 41 }'
_agree "after the sheet, the sheet's"                   sheeted width
check "…and it is the sheet's number"                   "$FT_RET" "41"

# ── _ft_setprop's two early exits ────────────────────────────────────────────
note "_ft_setprop's early exits write a property and return before the invalidation"
_warm leaf style
ft-modify leaf style="color: 46"
_agree "the inline style string"                        leaf style
_warm leaf eventListeners
ft-modify leaf onActivate=_memo_probe_handler
_agree "the listener plist"                             leaf eventListeners

# ── the one control that writes a property variable directly ─────────────────
note "a multitoggle's selectedIndex, stamped with printf -v"
ft-multitoggle name=mt parent=win2
    ft-option name=mtA value=a text="A" parent=mt
    ft-option name=mtB value=b text="B" parent=mt
ft_layout app
ft-modify mt value=a
_warm mt selectedIndex
ft-modify mt value=b
_agree "selectedIndex follows the value that moved it"  mt selectedIndex

# ── the class table ──────────────────────────────────────────────────────────
# A class default is the last level of every resolution, and a class may be declared lazily.
# It cannot be driven into staleness — _ft_class_ensure runs before the first instance exists,
# so no control can have resolved against the missing default — so the assertion is about the
# ROUTE rather than about a stale answer: declaring a class must drop everything.
note "declaring a class drops every entry (insurance, not a reachable staleness)"
_g=$_FT_RESOLVE_GENERATION
ft_class_init memoprobe >/dev/null 2>&1     # a type nothing has declared: falls back to ft_control
check "a class declaration bumped the generation" \
      "$( (( _FT_RESOLVE_GENERATION > _g )) && echo yes )" "yes"
_g=$_FT_RESOLVE_GENERATION
ft_class_init memoprobe >/dev/null 2>&1     # …and an already-ready class does no work at all
check "…and re-asking for a ready class does not"  "$_FT_RESOLVE_GENERATION" "$_g"

# ── TEETH ────────────────────────────────────────────────────────────────────
# Everything above passes on the memoised code. Does any of it FAIL when the memo is blinded?
# If not, this file is decoration. Re-run ourselves with each sabotage and require red.
if [[ -z "$_sab" ]]; then
    note "teeth: each sabotage must turn this file red"
    for _s in pair subtree global all; do
        if FT_RESOLVEMEMO_SABOTAGE=$_s bash "$here/tests/test-resolvememo.bash" >/dev/null 2>&1; then
            check "sabotage '$_s' is caught" "PASSED (blind)" "failed"
        else
            check "sabotage '$_s' is caught" "failed" "failed"
        fi
    done
fi

summary
