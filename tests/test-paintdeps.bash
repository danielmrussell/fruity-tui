#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tests/test-paintdeps.bash — a control whose paint is DERIVED from another control's state
#  must be repainted when that state moves, and there must be exactly one place that knows it.
#
#  `ft-scrollbar for=doc` reads the TARGET's scrollTop and extent at DRAW time. That pull is the
#  right design and it was simply never called: scrolling the target entered the target in
#  FT_DIRTY and nobody else, so ft_redraw_dirty repainted the document and left the bar's column
#  showing where the content used to be. The state was right and the screen was a lie. Measured,
#  with writing the BAR's own offset as the control proving the probe could see dirtiness at all:
#
#      ft_set bar scrollTop=3     dirty=[doc bar]     ← the coupling, wired
#      ft_set doc scrollTop=8     dirty=[doc]         ← the same coupling, not wired
#      ft_label_scroll_set doc 5     dirty=[doc]
#      the target's content shrinks  dirty=[doc]
#
#  IT IS NOT A SCROLLBAR PROBLEM, which is why the framework got the concept instead of the
#  scrollbar getting a special case: a `keys=auto` keylegend derives from the FOCUSED control the
#  same way, and every future control that displays something another control owns will too.
#  ft_paint_depends_on registers it; ft_dirty walks it.
#
#  AND WHY NO OTHER GATE SEES THIS. Every gate in this suite renders from scratch —
#  test-roundtrip's oracle is _ft_redraw_walk, a forced full walk — so a missing ft_dirty cannot
#  register in any of them. A full repaint asks everybody; the defect is in who gets asked.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=60; FT_ROWS=16; FT_USE_UTF8=1

# ── sabotage, for the teeth ──────────────────────────────────────────────────
# Teeth are proved by putting the defect back, not by replaying history: both halves of this bug
# were introduced and fixed inside a single commit each, so nothing flips either side of them.
_pd_sab=${FT_PAINTDEPS_SABOTAGE:-}
case "$_pd_sab" in
    # ft_dirty stops walking the dependency table — the defect exactly as it shipped.
    nowalk)  ft_dirty() { FT_DIRTY[$1]=1; unset "FT_RETAINED_TOKEN[$1]" "FT_RETAINED_BLOCK[$1]"; } ;;
    # ft_dirty_subtree goes back to writing the set itself instead of calling ft_dirty — the COPY
    # that drifted, and the reason three routes were fixed while the fourth stayed broken.
    subtree) ft_dirty_subtree() { local n=$1 kid
                 FT_DIRTY[$n]=1; unset "FT_RETAINED_TOKEN[$n]" "FT_RETAINED_BLOCK[$n]"
                 for kid in ${FT_KIDS[$n]:-}; do ft_dirty_subtree "$kid"; done; } ;;
esac

_PD_DOC=$(for i in $(seq 1 20); do printf 'line %s\n' "$i"; done)
_pd_dirty() { local d="${!FT_DIRTY[*]}"; printf '%s' "${d:-none}"; }
_pd_has()   { case " ${!FT_DIRTY[*]} " in *" $1 "*) printf yes ;; *) printf no ;; esac; }

note "the mechanism: dirtying a source dirties whatever derives from it"
ft-form name=pdm width=60 height=16
    ft-label name=pdA text=A
    ft-label name=pdB text=B
    ft-label name=pdC text=C
end_ft_form
ft_layout pdm; FT_ROOT=pdm
ft_paint_depends_on pdB pdA          # B is derived from A
FT_DIRTY=(); ft_dirty pdA
check "the source is dirty"                      "$(_pd_has pdA)" "yes"
check "…and so is what derives from it"          "$(_pd_has pdB)" "yes"
# POSITIVE CONTROL IN THE OTHER DIRECTION: an unregistered control must NOT be swept in, or this
# file would pass just as happily on an ft_dirty that dirtied the whole world.
check "…and nothing else is"                     "$(_pd_has pdC)" "no"
FT_DIRTY=(); ft_dirty pdB
check "the dependency is one-way"                "$(_pd_has pdA)" "no"
ft_paint_depends_none pdB
FT_DIRTY=(); ft_dirty pdA
check "unregistering stops it"                   "$(_pd_has pdB)" "no"

note "a dependency that points back at itself settles instead of hanging"
# A local depth counter cannot see mutual recursion (reference: cycles hang or segfault), so the
# guard is "was it already dirty" — which terminates after one hop whatever the shape.
ft_paint_depends_on pdB pdA
ft_paint_depends_on pdA pdB
FT_DIRTY=(); ft_dirty pdA
check "a mutual dependency terminates"           "$(_pd_has pdA),$(_pd_has pdB)" "yes,yes"
ft_paint_depends_none pdA; ft_paint_depends_none pdB

note "a bound scrollbar is repainted by EVERY route that moves its target"
ft_remove pdm 2>/dev/null
ft-form name=pdapp width=60 height=16 display=flex flexDirection=row alignItems=start
    ft-label     name=pdDoc text="$_PD_DOC" width=20 height=6 overflowY=auto
    ft-scrollbar name=pdBar for=pdDoc height=6
end_ft_form
ft_layout pdapp; FT_ROOT=pdapp
_pd_settle() { FT_OUT=""; _ft_redraw_walk pdapp >/dev/null 2>&1; FT_OUT=""
               FT_OUT=""; _ft_redraw_walk pdapp >/dev/null 2>&1; FT_OUT=""; FT_DIRTY=(); }
# The control first: writing the BAR's own offset must dirty the bar, or nothing below means
# anything — a probe that cannot see dirtiness reports every route as broken.
_pd_settle; ft_set pdBar scrollTop=3
check "writing the bar's own offset dirties it"  "$(_pd_has pdBar)" "yes"
_pd_settle; ft_set pdDoc scrollTop=8
check "the app writes the target's offset"       "$(_pd_has pdBar)" "yes"
_pd_settle; ft_label_scroll_set pdDoc 5
check "the target scrolls by its own verb"       "$(_pd_has pdBar)" "yes"
_pd_settle; ft_set pdDoc text="one line only"
check "the target's content changes under it"    "$(_pd_has pdBar)" "yes"
# …and the registration follows `for=`, on every route, exactly as the registry does.
ft_set pdBar for=""
_pd_settle                       # …AFTER the retarget, which legitimately dirties the bar itself
ft_set pdDoc scrollTop=2
check "a released bar stops being repainted"     "$(_pd_has pdBar)" "no"

note "there is exactly ONE place that marks a control dirty"
# ft_dirty grew the dependency walk, and ft_dirty_subtree carried a COPY of its two lines under a
# comment claiming they were the same predicate. They stopped being the same the moment the walk
# was added, and a dependent came back stale on that route and not on its sibling. So the writers
# are enumerated and pinned: a new one must be justified by whoever adds it, the way
# tests/test-api-surface.bash pins framework work done in demos.
#
# The one permitted exception is not a marking at all: ft-transition.bash RESTORES a whole saved
# dirty set (alongside FT_REPAIR) after painting a frame it promised not to disturb. Routing that
# through ft_dirty would add dependents the snapshot never had, which is the opposite of putting
# the world back as it was found.
# COMMENTS ARE NOT CODE, and this check counted one on its first run: the note inside
# ft_dirty_subtree QUOTES `FT_DIRTY[$n]=1` while explaining what it used to be, and a static scan
# that reads prose as an assignment cries wolf at documentation — which is how a gate gets
# disabled. Lines whose first non-space character is `#` are dropped before counting.
_pd_scan() {                    # file… → the lines that really assign the set
    grep -rn 'FT_DIRTY\[[^]]*\]=' --include=*.bash "$@" | grep -v ':[[:space:]]*#'
}
_pd_writers=$(cd "$here" && _pd_scan . | grep -v '^\./tests/' | grep -v '^\./demo/' \
              | sed 's/:.*//' | LC_ALL=C sort -u | tr '\n' ' ')
check "only the engine and the transition snapshot write the set directly" \
      "$_pd_writers" "./ft-forms.bash ./ft-transition.bash "
_pd_informs=$(cd "$here" && _pd_scan ft-forms.bash | grep -c .)
check "…and inside ft-forms.bash that is ft_dirty and nothing else" "$_pd_informs" "1"
# ANTI-VACUITY: a scan that matched nothing would pass the file-set check by returning an empty
# string that happens not to equal the expectation — no, it would fail. But it WOULD pass the
# count check if the count were zero, so pin that the scan found the one line it must find.
check "…and the scan can see that one line"  "$(( _pd_informs >= 1 ))" "1"

# ── TEETH ────────────────────────────────────────────────────────────────────
if [[ -z "$_pd_sab" ]]; then
    note "teeth: each injected defect must turn this file red"
    for _s in nowalk subtree; do
        if FT_PAINTDEPS_SABOTAGE=$_s bash "$here/tests/test-paintdeps.bash" >/dev/null 2>&1; then
            check "injected '$_s' is caught" "PASSED (blind)" "failed"
        else
            check "injected '$_s' is caught" "failed" "failed"
        fi
    done
fi

summary
