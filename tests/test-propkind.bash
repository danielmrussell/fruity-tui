#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tests/test-propkind.bash — the layout/paint table is ONE table, and it must say the same
#  thing whatever order an app happens to build its widgets in.
#
#  FT_PROP_KIND answers "what does the engine owe when this property changes: a repaint, or a
#  reflow". Many classes write to it through ft_prop_kind_set, and a class constructor runs
#  LAZILY — at the first instance of its type. So a second class classifying a name the first
#  has already classified is not adjusting its own control: it is re-classifying that name for
#  the WHOLE framework, and the winner is whichever widget the app built first. Measured:
#
#      ft-beacon     text         layout → paint
#      ft-tab        title        layout → paint
#      ft-scrollbar  orientation  layout → paint
#
#  The first is the one that mattered. `text` is the property every label, button, radio and
#  multitoggle has, and ONE callout anywhere in an app made every label in it stop re-measuring:
#
#      no beacon                 text-kind=layout   label width 5 → 40   (correct)
#      a beacon was built first  text-kind=paint    label width 5 →  5   (the string clipped)
#
#  ft-beacon did not even want that. It wanted the DSL to parse `text="two words"` as an
#  assignment rather than as bare content, which a registered name is how you get — and `text`
#  was registered already. The kind table was reached for as a parsing side effect and charged
#  the whole framework for it.
#
#  So the rule this file pins: A KIND MAY ONLY EVER BE STRENGTHENED. paint → layout is allowed,
#  layout → paint is refused, and every contested name therefore settles on layout whichever
#  class is instantiated first. That is the direction the table's own rule already points — a
#  needless reflow is correct, a skipped one is not — and it makes the table order-independent
#  by construction rather than by everyone remembering.
#
#  AND THE OTHER HALF: a property that a MEASURE function reads is an input to the control's
#  SIZE, so it cannot be paint-only. Six were, and each was demonstrated by writing it and
#  watching the box not move — `size` (a textfield's intrinsic width, a select's height),
#  `accessKey` (the width functions append " (X)" for a letter not in the label), and
#  `overflow`/`overflowX` (they reserve the gutter column in _ft_inset4, so the content box
#  shrinks and the children have to reflow into what is left).
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=90; FT_ROWS=24

# ── sabotage, for the teeth ──────────────────────────────────────────────────
# A GATE'S TEETH ARE PROVED BY PUTTING THE DEFECT BACK, not by replaying history. This file was
# run at the parent of each of the fourteen defects fixed last week and caught none of them —
# because in every one of those the measure-read and the wrong kind arrived in the SAME commit,
# so there is nothing to flip either side of it. That makes this gate prospective, and the only
# honest way to show a prospective gate works is to inject the class it watches for and require
# red. Same idiom as tests/test-clip.bash's FT_CLIP_SABOTAGE.
#
# Applied HERE, before any control is built, because a class constructor runs lazily at the first
# instance of its type — sabotaging the rule after that point would sabotage nothing.
_pk_sab=${FT_PROPKIND_SABOTAGE:-}
case "$_pk_sab" in
    # The rule itself, reverted to what it was: a kind that any class can weaken, so the last
    # widget an app happens to build decides how the framework classifies a name.
    kindrule) ft_prop_kind_set() { [[ -z "$1" ]] && return 1
                                   _ft_propkey "$1"; FT_PROP_KIND[$FT_RET]=$2; } ;;
esac

note "a kind may be strengthened, never weakened"
# The rule itself, asked directly. A POSITIVE CONTROL first: if paint → layout did not work
# either, the two assertions below would both pass while ft_prop_kind_set did nothing at all.
ft_prop_kind_set _pkProbeA paint
ft_prop_kind _pkProbeA; check "a fresh name takes the kind it is given"  "$FT_RET" "paint"
ft_prop_kind_set _pkProbeA layout
ft_prop_kind _pkProbeA; check "…and paint → layout STRENGTHENS it"       "$FT_RET" "layout"
ft_prop_kind_set _pkProbeA paint
ft_prop_kind _pkProbeA; check "…while layout → paint is refused"         "$FT_RET" "layout"
ft_prop_kind_set _pkProbeA layout
ft_prop_kind _pkProbeA; check "…and re-stating layout is harmless"       "$FT_RET" "layout"

note "the three names two classes disagreed about all settle on layout"
# Instantiating a class is what runs its constructor, so this is the state an app is in once it
# has built one of each. The order below is the one that USED to lose.
for _t in frame tabs tab table scrollbar beacon label; do ft_class_init "$_t" >/dev/null 2>&1; done
# THE THREE DOWNGRADES ARE ATTEMPTED HERE, not left to history. Those lines were deleted from
# ft-beacon, ft-tab and ft-scrollbar when this was fixed — so asserting the names are layout
# after building one of each would only be asserting that the deletions happened, and would pass
# just as happily on a framework with no rule at all. Making the attempt is what tests the rule:
# each of these is a no-op now, and each is a global reclassification without it.
ft_prop_kind_set text        paint
ft_prop_kind_set title       paint
ft_prop_kind_set orientation paint
ft_prop_kind text;        check "text is layout even when a class asks for paint"  "$FT_RET" "layout"
ft_prop_kind title;       check "title is layout even when a class asks for paint" "$FT_RET" "layout"
ft_prop_kind orientation; check "orientation likewise"                             "$FT_RET" "layout"

note "…and the whole table is identical whatever order the app builds in"
# The end-to-end proof, in two fresh interpreters: the rule above is one mechanism, and this
# asks the question the rule exists to answer without assuming the rule is the only way to
# answer it. A future ft_prop_kind_set that grew a second door would fail here and pass above.
_D=$(mktemp -d); trap 'rm -rf "$_D"' EXIT
cat > "$_D/order.bash" <<'ORDER'
set -u
cd "$1" || exit 1
source ./fruity-tui.bash
ft_init 2>/dev/null || :
exec {FT_TTY}>/dev/null
shift
for t in "$@"; do ft_class_init "$t" >/dev/null 2>&1; done
for k in "${!FT_PROP_KIND[@]}"; do printf '%s %s\n' "$k" "${FT_PROP_KIND[$k]}"; done | LC_ALL=C sort
ORDER
_TYPES=(frame tabs tab table scrollbar beacon label button radio checkbox multitoggle slider select textfield tree statusbar keylegend)
_fwd=$(bash "$_D/order.bash" "$here" "${_TYPES[@]}")
_rev=$(bash "$_D/order.bash" "$here" $(printf '%s\n' "${_TYPES[@]}" | tac))
check "forwards and backwards give the same table" "$_fwd" "$_rev"
# ANTI-VACUITY: two EMPTY tables also compare equal, and an interpreter that failed to source
# the framework would produce exactly that. Demand the table is real before believing it agrees.
check "…and the table is not empty"        "$(( $(printf '%s\n' "$_fwd" | grep -c .) > 60 ))" "1"
check "…and holds the names under test"    "$(printf '%s\n' "$_fwd" | grep -cE '^(text|title|orientation) layout$')" "3"

note "a kind is paint or layout — nothing else gets into the table"
# `ft_prop_kind_set showLineNumbers layout# comment` (no space before the #) stored "layout#", which
# every reader compares with `== layout` and so treated as paint: toggling a textarea's line numbers
# widened its preferred size and nothing reflowed it. Every class's kinds, read back whole:
check "every kind in the table is paint or layout" \
      "$(printf '%s\n' "$_fwd" | awk '$2 != "paint" && $2 != "layout" {printf "%s=%s ", $1, $2}')" ""
ft_prop_kind_set _pkProbeTypo 'layout#' 2>/dev/null
check "…and a kind that is neither is refused" "$?" "1"
ft_prop_kind _pkProbeTypo
check "…leaving the name unclassified (the layout default)" "$FT_RET" "layout"

note "no property a MEASURE function reads is paint-only"
# A class's registered preferredWidth/height function decides the control's intrinsic size, so
# whatever it reads is an input to that size. Asked at RUNTIME rather than by grepping the
# source, because the binding is by convention through the inheritance chain — a button's height
# function IS a label's, and only the populated table knows that.
for _fn in $(declare -F | sed -n 's/^declare -f ft_class_//p'); do ft_class_init "$_fn" >/dev/null 2>&1; done
_pk_props_read() {              # function-name → one property name per line
    local body; body=$(declare -f "$1" 2>/dev/null) || return 0
    {
        printf '%s\n' "$body" | grep -oE 'ft_resolved_prop +"[^"]+" +[A-Za-z_][A-Za-z0-9_]*'  | awk '{print $NF}'
        printf '%s\n' "$body" | grep -oE '_ft_get_raw +"[^"]+" +[A-Za-z_][A-Za-z0-9_]*'       | awk '{print $NF}'
        printf '%s\n' "$body" | grep -oE '_ft_prop_or_class +"[^"]+" +[A-Za-z_][A-Za-z0-9_]*' | awk '{print $NF}'
    } | LC_ALL=C sort -u
}
# ONE ASSERTION PER READ, not one aggregate over all of them. A single "nothing is wrong" check
# cannot show PROGRESS: while any one violation remains, it fails, and a violation that has just
# been fixed is invisible underneath it. That matters beyond diagnosis — the way this project
# measures whether a gate has teeth is to run it either side of a fix and see which assertions
# changed verdict, and an aggregate has only ever one verdict to change. It also means a failure
# names the property instead of making the reader go and find it.
# The other injection: one property a measure function reads, put back to paint. `size` is the
# textfield's intrinsic width and the select's height, so this is the exact defect that was live
# in this tree three days ago. Applied here rather than at the top because it is the TABLE being
# sabotaged, not the rule that maintains it.
[[ "$_pk_sab" == coherence ]] && FT_PROP_KIND[size]=paint
_pk_seen=0
for _ty in $(printf '%s\n' "${!FT_CLASS_READY[@]}" | LC_ALL=C sort); do
    for _slot in "${FT_CLASS_PREFERRED_WIDTH[$_ty]:-}" "${FT_CLASS_HEIGHT[$_ty]:-}"; do
        [[ -n "$_slot" ]] || continue
        while IFS= read -r _p; do
            [[ -n "$_p" ]] || continue
            _pk_seen=$(( _pk_seen + 1 ))
            ft_prop_kind "$_p"
            check "$_ty measures with $_p, so it is not paint-only" "$FT_RET" "layout"
        done < <(_pk_props_read "$_slot")
    done
done
# ANTI-VACUITY, and it is not hypothetical: the scan above is three regexes over `declare -f`
# output, and a regex that stops matching turns this whole section into a gate that passes
# whatever the code does. It did exactly that on its first run here.
#
# The guard is a KNOWN ANSWER rather than a count, because a count is a magic number that a
# legitimate refactor moves and nobody dares touch. _ft_preferred_width_textfield reads exactly
# one property and that property is `size` — if the scanner cannot see that, it can see nothing.
check "the scanner can see a read it is known to contain" \
      "$(_pk_props_read _ft_preferred_width_textfield | tr '\n' ' ')" "size "
# …and a floor underneath it, well below the 18 measured when this was written, so a scanner
# that half-breaks — one of the three spellings silently stopping — still fails rather than
# quietly narrowing what this gate covers.
check "…and it is still reading across the framework" "$(( _pk_seen >= 12 ))" "1"

note "the consequence, which is the only thing that really matters"
# A kind is a table entry; what an app sees is whether the box moved. Each of these was measured
# NOT moving before the four names were reclassified.
ft-form name=pkapp width=90 height=24 display=flex flexDirection=column alignItems=start
    ft-textfield name=pkTf size=10
    ft-button    name=pkBt "Save"
    ft-select    name=pkSe size=2
        ft-option value=a "A"
        ft-option value=b "B"
        ft-option value=c "C"
        ft-option value=d "D"
    end_ft_select
    ft-label     name=pkLb text="short"
end_ft_form
ft_layout pkapp; FT_ROOT=pkapp

_w=${FT_MEASURED_WIDTH[pkTf]};  ft-modify pkTf size=40;     ft_reflow_flush
check "a textfield re-measures when its size changes"   "$(( ${FT_MEASURED_WIDTH[pkTf]} > _w ))" "1"
_h=${FT_MEASURED_HEIGHT[pkSe]}; ft-modify pkSe size=4;      ft_reflow_flush
check "a select re-measures when its size changes"      "$(( ${FT_MEASURED_HEIGHT[pkSe]} > _h ))" "1"
_w=${FT_MEASURED_WIDTH[pkBt]};  ft-modify pkBt accessKey=Z; ft_reflow_flush
check "a button widens to hold its own accelerator"     "$(( ${FT_MEASURED_WIDTH[pkBt]} > _w ))" "1"
_w=${FT_MEASURED_WIDTH[pkLb]};  ft-modify pkLb text="a considerably longer string than before"
ft_reflow_flush
check "a label still grows with its text"               "$(( ${FT_MEASURED_WIDTH[pkLb]} > _w ))" "1"
# …and it still does after a beacon exists, which is the whole reason this file was written.
ft-beacon name=pkBc target=pkLb parent=pkapp 2>/dev/null
_w=${FT_MEASURED_WIDTH[pkLb]};  ft-modify pkLb text="longer again, now that a callout has been built"
ft_reflow_flush
check "…including after a callout has been built"       "$(( ${FT_MEASURED_WIDTH[pkLb]} > _w ))" "1"

# ── TEETH ────────────────────────────────────────────────────────────────────
# Everything above passes on the shipped code. Does any of it FAIL when the class of defect this
# file exists for is put back? If not, it is decoration.
if [[ -z "$_pk_sab" ]]; then
    note "teeth: each injected defect must turn this file red"
    for _s in kindrule coherence; do
        if FT_PROPKIND_SABOTAGE=$_s bash "$here/tests/test-propkind.bash" >/dev/null 2>&1; then
            check "injected '$_s' is caught" "PASSED (blind)" "failed"
        else
            check "injected '$_s' is caught" "failed" "failed"
        fi
    done
fi

summary
