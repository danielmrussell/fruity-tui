#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  :disabled MUST MEAN WHAT DISABLED MEANS.
#
#  `disabled` inherits — it is in FT_INHERITED_PROP — and every behavioural consumer resolves
#  it that way: the paint dims a disabled subtree, focus skips it, ft_activate refuses to fire
#  its handlers. The SELECTOR did not. `:disabled` was declared as the attribute shape
#  `[disabled=true]`, which the evaluator answers with a raw property read, so a button inside
#  a disabled container was inert, unfocusable and drawn dim — while `button:disabled` did not
#  match it and `button:enabled` did.
#
#  A theme could not style what the engine was already doing. The selector and the behaviour
#  disagreed about the same control, which is the one thing a state registry exists to prevent.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
cd "$here"
export FT_NO_WTFIX=1
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_USE_UTF8=1
FT_COLS=60; FT_ROWS=16

fired=0
kid_on_activate() { fired=1; }

ft-form name=app width="$FT_COLS" height="$FT_ROWS"
    ft-div name=holder
        ft-button name=kid text="Go" onActivate='kid_on_activate "$@"'
    end_ft_div
    ft-div name=other
        ft-button name=free text="Free"
    end_ft_div
end_ft_form
FT_ROOT=app; ft_layout app

note "nothing disabled: the control point"
check "the selector says enabled" "$(ft_matches kid :enabled  && echo yes || echo no)" yes
check "…and not disabled"         "$(ft_matches kid :disabled && echo yes || echo no)" no
fired=0; ft_activate kid >/dev/null 2>&1
check "the handler fires"         "$fired" 1

note "disable the CONTAINER — the behaviour follows it down"
ft_set holder disabled=true
ft_resolved_prop kid disabled
check "the engine resolves the child as disabled" "$FT_RET" true
fired=0; ft_activate kid >/dev/null 2>&1
check "the handler no longer fires"               "$fired" 0
check "focus must skip it" "$(_ft_focus_skippable kid && echo yes || echo no)" yes

note "…and so must the selector, which is the bug"
check "the selector says disabled" "$(ft_matches kid :disabled && echo yes || echo no)" yes
check "…and not enabled"           "$(ft_matches kid :enabled  && echo yes || echo no)" no

note "a stylesheet rule follows the same answer"
ft_stylesheet name=ds style='
    button:disabled { --probe: dis; }
    button:enabled  { --probe: en;  }
'
ft_style kid --probe
check "button:disabled is what matches the child" "$FT_RET" dis
ft_style free --probe
check "…and an untouched button is still enabled" "$FT_RET" en

note "un-disabling the container releases the child again"
ft_set holder disabled=false
check "the selector says enabled again" "$(ft_matches kid :enabled && echo yes || echo no)" yes
fired=0; ft_activate kid >/dev/null 2>&1
check "and the handler fires again"     "$fired" 1

note "disabling the control directly still works (it always did)"
ft_set kid disabled=true
check "directly disabled matches :disabled" "$(ft_matches kid :disabled && echo yes || echo no)" yes
check "…and not :enabled"                   "$(ft_matches kid :enabled  && echo yes || echo no)" no

summary
