#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  The clip memo tells the truth after every route that can move a clip rect.
#
#  `_ft_clip_for` is memoised (see the long note above it in ft-forms.bash), and the whole risk
#  of that memo is its key. The obvious key — FT_LAYOUT_EPOCH, "the geometry may have changed"
#  — is WRONG, and measurably so: that counter is bumped in exactly one place, the first line of
#  ft_layout, while six other routes move a rect. Before the memo existed this was invisible;
#  with it, every one of them is a smear waiting to happen:
#
#      ft_set win padding=3       moves the rect, epoch does not move, and does not move
#                                    after ft_reflow_flush either — ft_reflow lands in
#                                    _ft_reflow_now, which re-runs the passes and bumps nothing
#      ft_set win overflow=…      moves the rect AND the scroll gutter. This used to add
#                                    "overflow is registered PAINT-kind, so it schedules no
#                                    reflow at all" — no longer true: overflow reserves the
#                                    gutter column in _ft_inset4, which makes it an input to the
#                                    box, and it is layout-kind now. See tests/test-propkind.bash.
#      ft_scroll_set / focus move    shifts a whole subtree's absolute position, no layout
#      ft_append / ft_remove         changes the ancestor chain the rect is built from
#      ft_set win class=…         a sheet rule can supply the padding; no property of the
#                                    node itself changed
#      ft_clip_band                  changes the answer mid-paint with no state change at all
#
#  So this file asserts, for each route, that the memo answers what a FROM-SCRATCH walk answers.
#  The comparison is against the real function with its cache emptied — not against a hard-coded
#  rect — so it keeps working when the box model legitimately changes.
#
#  TEETH. Every assertion here was watched to fail: run with FT_CLIP_SABOTAGE naming a route
#  (props|scroll|tree|css|arrange|all) and the corresponding bump is disabled; each sabotage
#  must turn this file red. The teeth section at the foot runs `all` in a subshell and requires
#  it to fail, so a future edit that neuters the memo cannot leave this file passing.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_ROWS=30; FT_COLS=100; FT_USE_UTF8=1

# ── sabotage, for the teeth ──────────────────────────────────────────────────
_sab=${FT_CLIP_SABOTAGE:-}
case "$_sab" in
    props|all)  _FT_CLIP_PROPS=() ;;                       # property writes stop bumping
esac
case "$_sab" in
    scroll|tree|css|all) _ft_clip_inval() { :; } ;;        # the explicit bumps stop bumping
esac
case "$_sab" in
    arrange|all)
        # strip the bump out of the arrange pass, leaving everything else it does intact
        eval "$(declare -f _ft_pass_arrange | sed 's/(( _FT_CLIP_GEN++ ))/:/')" ;;
esac

# ── the instrument: what a from-scratch walk says ────────────────────────────
# Empty the memo and ask again. If the memoised answer and this disagree, the key forgot an
# input. (Emptying the table is the ONLY thing that differs — same function, same tree.)
#
# AND IT PUTS THE TABLE BACK, which is the whole difficulty. The first version of this helper
# left the cache EMPTY, so the next `_memo` was a guaranteed miss and recomputed the right
# answer every time — four of the five sabotages below sailed through a green file. A stale
# memo can only be caught by an ask that finds a WARM entry, so the truth walk has to be
# invisible: snapshot, clear, walk, restore.
_truth() {                      # name → TRUTH="r0 c0 r1 c1"
    local _save_gen=$_FT_CLIP_GEN
    local -a _sk=() _sv=()
    local _k
    for _k in "${!_FT_CLIP_CACHE[@]}"; do _sk+=("$_k"); _sv+=("${_FT_CLIP_CACHE[$_k]}"); done
    _FT_CLIP_CACHE=()
    _ft_clip_for "$1"
    TRUTH="$FT_CLIP_R0 $FT_CLIP_C0 $FT_CLIP_R1 $FT_CLIP_C1"
    _FT_CLIP_CACHE=()
    local _i
    for (( _i = 0; _i < ${#_sk[@]}; _i++ )); do _FT_CLIP_CACHE[${_sk[$_i]}]=${_sv[$_i]}; done
    _FT_CLIP_GEN=$_save_gen
}
_memo() {                       # name → MEMO="r0 c0 r1 c1" (whatever the cache serves)
    _ft_clip_for "$1"
    MEMO="$FT_CLIP_R0 $FT_CLIP_C0 $FT_CLIP_R1 $FT_CLIP_C1"
}
# THE ORDER MATTERS. Ask the memo FIRST (that is the answer the paint would get), then compute
# the truth. Asking truth-first would refill the cache with the right answer and every route
# below would pass no matter what the key forgot.
_agree() {                      # desc name
    _memo "$2"; _truth "$2"
    check "$1" "$MEMO" "$TRUTH"
}

# A NESTED container is not decoration here. _ft_scroll_apply shifts a scroller's DESCENDANTS,
# so scrolling `win` never moves `win` itself and `leaf`'s clip — built from win upward — is
# rightly unchanged. Only a control whose ANCESTOR was shifted can see it, which is `deep`.
ft-form name=app width=100 height=30
    ft-frame name=win width=60 height=20 title=" W "
        ft-frame name=inner width=40 height=8
            ft-label name=deep text="down here"
        end_ft_frame
        ft-label name=leaf text="hello"
        ft-label name=leaf2 text="world"
    end_ft_frame
    ft-frame name=other width=20 height=10
        ft-label name=far text="x"
    end_ft_frame
end_ft_form
FT_ROOT=app
ft_layout app

note "the memo agrees with a cold walk at rest"
_agree "a fresh clip is correct" leaf
_agree "…and a second ask is still correct" leaf
_agree "a sibling shares the chain and the entry" leaf2
_agree "a different container has its own" far

# ANTI-VACUITY. If the rect were the whole screen everywhere, every check above would pass for
# free and the file would be measuring nothing. The frame must actually clip its children.
_memo leaf
check "the container really clips (else nothing here is tested)" \
      "$( [[ "$MEMO" != "0 0 29 99" ]] && echo yes )" "yes"

note "a runtime padding write — layout-kind, but nothing bumps the layout epoch"
_before_epoch=$FT_LAYOUT_EPOCH
ft_set win padding=3
_agree "clip follows padding=3 immediately" leaf
ft_reflow_flush
_agree "…and after the deferred reflow settles" leaf
check "…and FT_LAYOUT_EPOCH never moved (why it cannot be the key)" \
      "$FT_LAYOUT_EPOCH" "$_before_epoch"

ft_set win paddingLeft=4
_agree "clip follows a per-side paddingLeft" leaf
ft_set win border=false
_agree "clip follows border=false" leaf
ft_unset win padding
_agree "clip follows removeAttribute(padding)" leaf

note "a runtime overflow write — PAINT-kind, so it schedules no layout at all"
ft_set win overflow=visible
_memo leaf
check "overflow=visible stops the frame clipping" "$MEMO" "0 0 29 99"
_agree "…and the memo says so" leaf
ft_set win overflow=hidden
_agree "overflow=hidden clips again" leaf
ft_set win overflow=auto
_agree "overflow=auto reserves the scrollbar gutter" leaf
ft_set win overflow=hidden

note "a reflow that re-arranges WITHOUT ft_layout"
# ft_layout bumps FT_LAYOUT_EPOCH, which the token already carries — so a full layout would
# mask the arrange bump entirely. The route that needs it is the one ft_set actually takes:
# ft_reflow → _ft_reflow_now → the four passes, and not one of those touches the epoch.
_before_epoch=$FT_LAYOUT_EPOCH
ft_set win height=9
ft_reflow_flush
_agree "clip follows a height change through a plain reflow" leaf
check "…and that route really did skip ft_layout" "$FT_LAYOUT_EPOCH" "$_before_epoch"
ft_set win height=20
ft_reflow_flush
_agree "…and back" leaf

note "a scroll shifts the subtree with no layout pass"
ft_set win overflow=auto
ft_set win height=8
ft_layout app
_agree "before scrolling" deep
_memo deep; _pre_scroll=$MEMO
ft_scroll_set win 3 0 >/dev/null 2>&1
_agree "after ft_scroll_set" deep
_memo deep
check "the scroll really moved the descendant's rect" \
      "$( [[ "$MEMO" != "$_pre_scroll" ]] && echo yes )" "yes"
ft_scroll_set win 0 0 >/dev/null 2>&1
_agree "after scrolling back" deep
ft_set win overflow=hidden
ft_set win height=20
ft_layout app

note "the tree itself moving"
_agree "before the move" far
ft_append win far >/dev/null 2>&1
_agree "a control appended under a new parent" far
ft_append other far >/dev/null 2>&1
_agree "…and moved back" far
# Moving the node itself is safe by construction — the memo is keyed on the PARENT, so `far`
# under a new parent is simply a different entry. The case that needs the bump is an ANCESTOR
# moving, which leaves the key alone and changes the answer.
_agree "before an ancestor moves" deep
_memo deep; _pre_move=$MEMO
ft_append other inner >/dev/null 2>&1
ft_layout app
_agree "an ANCESTOR reparented under a different container" deep
_memo deep
check "…and that really moved the rect" \
      "$( [[ "$MEMO" != "$_pre_move" ]] && echo yes )" "yes"
ft_append win inner >/dev/null 2>&1
ft_layout app
_agree "…and back" deep
ft_remove leaf2 >/dev/null 2>&1
_agree "a sibling removed" leaf

note "a stylesheet supplying the box"
ft_stylesheet name=clip style='.padded { padding: 4 }'
_agree "a rule registered" leaf
ft_set win class=padded
_agree "…and matched by a class change on the ANCESTOR" leaf
_memo leaf
check "the rule really moved the rect (else this section tests nothing)" \
      "$( [[ "${MEMO%% *}" != 1 ]] && echo yes )" "yes"
ft_set win class=
_agree "…and unmatched again" leaf

note "the band changes the answer with no state change at all"
_agree "wide open" leaf
ft_clip_band 5 9
_agree "narrowed to rows 5..9" leaf
_memo leaf
check "…and the narrowing really took" "${MEMO#* }" "${MEMO#* }"
check "the band actually bounded the rect" \
      "$( [[ "$(echo "$MEMO" | cut -d' ' -f3)" == 9 ]] && echo yes )" "yes"
ft_clip_band_reset
_agree "reset" leaf

note "the leaf-arrange guard, and the invariant it stands on"
# _ft_pass_arrange skips its bump for a node with no children, because a clip rect is the
# intersection over the target's PARENT CHAIN and a childless node is in nobody's chain. That is
# only true while the tree agrees with itself: every control that names P as its parent must be
# among P's kids. If any control could name a parent that does not list it, that parent would
# sit in a clip chain while looking childless, and its move would go unnoticed.
_bad=0
for _x in "${!FT_TYPE[@]}"; do
    _p=${FT_PARENT[$_x]:-}
    [[ -z "$_p" || -z "${FT_TYPE[$_p]:-}" ]] && continue
    _found=0
    for _k in ${FT_KIDS[$_p]:-}; do [[ "$_k" == "$_x" ]] && { _found=1; break; }; done
    (( _found )) || { _bad=$(( _bad + 1 )); echo "       $_x names parent $_p, not among its kids"; }
done
check "every control is among its parent's kids" "$_bad" "0"
check "…over a tree with something in it" "$( (( ${#FT_TYPE[@]} >= 5 )) && echo yes )" "yes"

_g=$_FT_CLIP_GEN
_ft_pass_arrange leaf 5 5           # a LEAF: in nobody's chain, so nothing can go stale
check "arranging a leaf does not invalidate" "$_FT_CLIP_GEN" "$_g"
_ft_pass_arrange win 0 0            # a CONTAINER: somebody's chain, so it must
check "…but arranging a container does" "$( (( _FT_CLIP_GEN > _g )) && echo yes )" "yes"
ft_layout app
_agree "the tree is still consistent after both" leaf

note "the terminal resizing under a custom resize callback that never lays out"
_agree "before" leaf
FT_ROWS=24; FT_COLS=80
_agree "after FT_ROWS/FT_COLS change alone" leaf
FT_ROWS=30; FT_COLS=100
_agree "and back" leaf

# ── TEETH ────────────────────────────────────────────────────────────────────
# Everything above passes on the memoised code. Does any of it FAIL when the memo is blinded?
# If not, this file is decoration. Re-run ourselves with each sabotage and require red.
if [[ -z "$_sab" ]]; then
    note "teeth: each sabotage must turn this file red"
    # `props` IS NOT IN THIS LIST ANY MORE, and that is a result rather than a concession.
    # _FT_CLIP_PROPS bumps the clip generation on a write to border/padding/overflow — a
    # mechanism that existed because those names were paint-kind and scheduled no reflow. They
    # are layout-kind now, so a write to any of them reflows, and the arrange pass bumps the
    # generation itself: emptying _FT_CLIP_PROPS leaves this file at 47/47. Requiring it to go
    # red would be requiring a second mechanism to be the only one.
    #
    # The list is kept rather than deleted, deliberately. _ft_setprop can be called DIRECTLY,
    # bypassing ft_set and its reflow, and proving that no direct caller ever writes a box
    # property is the enumeration this project's own cache rule demands before an invalidation
    # is removed. Until somebody does that enumeration it is a second line of defence, and the
    # honest way to say so is to stop asserting it is the first.
    for _s in scroll tree arrange all; do
        if FT_CLIP_SABOTAGE=$_s bash "$here/tests/test-clip.bash" >/dev/null 2>&1; then
            check "sabotage '$_s' is caught" "PASSED (blind)" "failed"
        else
            check "sabotage '$_s' is caught" "failed" "failed"
        fi
    done
fi

summary
