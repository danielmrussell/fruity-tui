#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  A PUBLIC ACCESSOR ANSWERS IN FT_RET. IT DOES NOT ECHO.
#
#  The law is written in ft-forms.bash beside ft_get: it "NEVER echoes (echoing forced callers
#  into `$(...)`, a subshell fork on every read — and, called unwrapped, leaked property values
#  onto the live terminal)". In a running app fd 1 IS the alt screen, so an accessor that
#  prints its answer writes it across the UI.
#
#  ft_coerced broke both halves: unwrapped it wrote the value to stdout, and it left FT_RET
#  holding the property KEY rather than the value — so the fork-free read was not merely
#  unavailable, it was actively wrong.
#
#  (Two dead public names get their own sections here as they are removed.)
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

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# A class with a real coerce hook. The memo is only populated when something coerces, and a
# control that coerces NOTHING makes the "it printed nothing" assertion pass for the wrong
# reason — the first draft of this test used a slider and did exactly that.
widget_scale_coerce() { FT_RET=$(( $3 * 2 )); }
ft-widget() { ft_new widget "$@"; }
ft-widget name=wg1 scale=5
ft_resolved_prop wg1 scale 0                    # the read that populates the coercion memo
COERCED_KEY_VALUE=$FT_RET
check "the fixture really coerces (5 doubled)" "$COERCED_KEY_VALUE" 10

note "ft_coerced answers in FT_RET, like every other accessor"
FT_RET=SENTINEL
ft_coerced wg1 scale > "$work/out" 2>&1
check "it printed nothing to stdout" "$(wc -c < "$work/out")" 0
check "…and FT_RET holds the VALUE, not the property key" "$FT_RET" "$COERCED_KEY_VALUE"

note "…so it can be read without a subshell"
ft_coerced wg1 scale
v=$FT_RET
check "a fork-free read gets the value" "$v" "$COERCED_KEY_VALUE"

note "an unknown property answers empty rather than the key"
FT_RET=SENTINEL
ft_coerced wg1 nosuchprop > "$work/out2" 2>&1
check "nothing printed"        "$(wc -c < "$work/out2")" 0
check "and FT_RET is empty"    "$FT_RET" ""

note "a dead public name stays dead"
# ft_dirty_list had no caller anywhere and answered only on stdout — the two properties this
# file exists to forbid, in one four-line function.
check "ft_dirty_list is gone"       "$(declare -F ft_dirty_list >/dev/null 2>&1 && echo present || echo gone)" gone
check "…and its live siblings remain"       "$(declare -F ft_dirty >/dev/null 2>&1 && declare -F ft_dirty_subtree >/dev/null 2>&1 && echo both || echo missing)" both
# ft_arrange was the same shape: a public one-line wrapper nobody called, whose two natural
# callers reached past it to _ft_pass_arrange.
check "ft_arrange is gone"       "$(declare -F ft_arrange >/dev/null 2>&1 && echo present || echo gone)" gone
check "…and the layout entry points that ARE used remain"       "$(declare -F ft_layout >/dev/null 2>&1 && declare -F ft_measure >/dev/null 2>&1 && echo both || echo missing)" both

summary
