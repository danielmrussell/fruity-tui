#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  THERE IS NO NAME-CONVENTION MAGIC — and this pins the examples that said there was.
#
#  docs/api-naming.md says a function named <name>_on_<event> is just a function: wire it, or
#  it never runs. tests/test-domapi.bash pins the rule. But the comment sitting directly above
#  the dispatcher taught the opposite model — "a control event runs the handler you named
#  <control>_on_EVENT" — with two UNWIRED examples to copy.
#
#  That is not a harmless stale comment: a maintainer who believes it writes a handler that
#  never fires, and the obvious "fix" is to add a `declare -F "${n}_on_EVENT"` gate to the
#  dispatcher. That gate has actually been written in this codebase (in the textfield's Enter
#  path), where it makes a properly wired listener never run on Enter and an unwired
#  conventionally-named function swallow the key.
#
#  So this asserts the comment's OWN examples do nothing until they are wired. It passes
#  before and after the comment was corrected — the comment was the defect; this is the guard
#  that stops anyone making the code match it.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
cd "$here"
export FT_NO_WTFIX=1
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_USE_UTF8=1
FT_COLS=40; FT_ROWS=10

LOG=""
# the comment's own example names, defined but never wired
rowW_on_change()    { LOG+="convention "; }
btnGo_on_activate() { LOG+="convention "; }
# and the sanctioned form
rowW_changed()      { LOG+="wired "; }

ft-form name=app width="$FT_COLS" height="$FT_ROWS"
    ft-button name=btnGo text="Go"
    ft-slider name=rowW min=0 max=10 value=1
end_ft_form
FT_ROOT=app; ft_layout app

note "a conventionally-named but UNWIRED handler never runs"
LOG=""; ft_activate btnGo >/dev/null 2>&1
check "activating fires nothing" "$LOG" ""
check "…and the function really does exist" \
      "$(declare -F btnGo_on_activate >/dev/null 2>&1 && echo defined || echo missing)" defined

note "wiring it is what makes it run"
ft_add_listener btnGo activate btnGo_on_activate
LOG=""; ft_activate btnGo >/dev/null 2>&1
check "now it fires" "$LOG" "convention "

note "and a listener wired the documented way needs no special name"
ft_set rowW onChange='rowW_changed "$@"'
LOG=""; _ft_hook rowW on_change 5 >/dev/null 2>&1
check "the wired listener fires"                 "$LOG" "wired "
check "…and the same-named convention one did not" \
      "$([[ "$LOG" == *convention* ]] && echo fired || echo silent)" silent

summary
