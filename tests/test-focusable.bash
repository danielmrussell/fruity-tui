#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  `focusable` IS A BOOLEAN, AND A BOOLEAN IS 1 OR 0 WHOEVER WROTE IT.
#
#  ft-forms.bash states the rule where the class table is declared: "a boolean is always
#  present, always 1 or 0, and always tested as a NUMBER". `ft_class focusable=true` is
#  normalised at the declaration and ft-modify normalises a runtime write — but an INSTANCE
#  property went into FT_FOCUSABLE raw, and every reader tests `== 1`. So
#
#      ft-label name=x focusable=true
#
#  — the spelling every other boolean in this framework uses (disabled=true, readOnly=true,
#  wrap=true), and the spelling the class declarations use for this very key — stored the
#  string "true" and made the control UNFOCUSABLE. Silently: `false` and a typo also fail
#  `== 1`, so the one wrong answer that mattered looked like it worked.
#
#  TWO DIFFERENT QUESTIONS, deliberately kept apart below:
#    · `focusable` decides whether a control is in the RING at all.
#    · a class's own skip predicate decides whether focus may REST there — a label with
#      nothing to scroll is in the ring and still skipped, because focusing it would do
#      nothing. That is not this bug and must not be "fixed" by it.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=60; FT_ROWS=20

ft-form name=app width=60 height=20
    ft-button name=btnTrue  "true"  focusable=true
    ft-button name=btnOne   "one"   focusable=1
    ft-button name=btnFalse "false" focusable=false
    ft-button name=btnZero  "zero"  focusable=0
    ft-button name=btnPlain "plain"
end_ft_form
ft_layout app
FT_ROOT=app
ft_focus_ring_build app >/dev/null 2>&1

_in_ring() { local c=$1 r; for r in "${FT_FOCUS_RING[@]}"; do [[ "$r" == "$c" ]] && { echo 1; return; }; done; echo 0; }

note "the table holds a number, whichever spelling the app used"
check "focusable=true  → 1" "${FT_FOCUSABLE[btnTrue]:-}"  "1"
check "focusable=1     → 1" "${FT_FOCUSABLE[btnOne]:-}"   "1"
check "focusable=false → 0" "${FT_FOCUSABLE[btnFalse]:-}" "0"
check "focusable=0     → 0" "${FT_FOCUSABLE[btnZero]:-}"  "0"

note "…and the ring agrees, which is what the app actually asked about"
check "focusable=true is in the ring"  "$(_in_ring btnTrue)"  "1"
check "focusable=1 is too"             "$(_in_ring btnOne)"   "1"
check "focusable=false is not"         "$(_in_ring btnFalse)" "0"
check "focusable=0 is not"             "$(_in_ring btnZero)"  "0"
check "a button with no focusable= at all is (its class says so)" "$(_in_ring btnPlain)" "1"

note "…and focus really lands on the one spelled with a word"
FT_FOCUS=""
ft_focus btnTrue >/dev/null 2>&1
check "ft_focus btnTrue" "${FT_FOCUS:-<refused>}" "btnTrue"
FT_FOCUS=""
ft_focus btnFalse >/dev/null 2>&1
check "…and refuses the one turned off" "${FT_FOCUS:-<refused>}" "<refused>"

note "a runtime write answers the same way — the two routes may not disagree"
# ft-modify already normalised; construction did not. That divergence IS the bug, so both
# are asserted here rather than only the one that was broken.
ft-modify btnFalse focusable=true
check "ft-modify focusable=true → 1" "${FT_FOCUSABLE[btnFalse]:-}" "1"
ft-modify btnFalse focusable=false
check "ft-modify focusable=false → 0" "${FT_FOCUSABLE[btnFalse]:-}" "0"

note "ring MEMBERSHIP and being SKIPPABLE are different questions"
# A label with nothing to scroll is focusable by class (it may scroll when it overflows) and
# still skipped, because focusing it would do nothing. Asserting both keeps a future "fix" for
# the bug above from quietly deleting the skip.
ft-form name=app2 width=60 height=10
    ft-label name=shortLabel text="fits" width=20
end_ft_form
ft_layout app2
ft_focus_ring_build app2 >/dev/null 2>&1
check "a non-overflowing label is in the ring"  "$(_in_ring shortLabel)" "1"
ok    "…and is skipped, because there is nothing to scroll" _ft_focus_skippable shortLabel

summary
