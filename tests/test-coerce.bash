#!/usr/bin/env bash
# Unit tests for the coerce pipeline: ft_new as the framework's registration
# entry point every prototype constructor calls, and <TYPE>_<PROP>_coerce hooks
# by naming convention (validate/compute a suggestion into a final value, or
# fail with a collected error and a safe fallback).
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init

note "ft_new is what the built-in constructors call"
ft-button name=b1 text=Hi
check "type recorded"      "${FT_TYPE[b1]}"   "button"
check "marked dirty on construct" "$(ft_is_dirty b1 && echo yes)" "yes"

note "a custom class's constructor follows the same pattern"
ft-mywidget() { ft_new mywidget "$@"; }
ft-mywidget name=w1 label=hello
check "custom class type recorded" "${FT_TYPE[w1]}" "mywidget"
ft_get w1 label; check "custom class prop stored"   "$FT_RET" "hello"

note "content vs assignment: a =-bearing PHRASE is refused, not made a bogus property"
# It used to become TEXT, because bare content was accepted and an unknown key with a spaced
# value is not an assignment. Content by position is gone, so the phrase is refused outright —
# and the thing that must still never happen is a property called `compression`.
_err=$(ft-label name=amb1 "compression=high beep=on" 2>&1)
check "spaced =-phrase is refused" \
      "$(case "$_err" in *"is not a property"*) echo refused ;; *) echo "${_err:-silent}" ;; esac)" "refused"
ft_get amb1 compression; check "no phantom 'compression' property set" "$FT_RET" ""
ft_set amb1 text="compression=high beep=on"
ft_get amb1 text; check "…and text= takes the phrase verbatim" "$FT_RET" "compression=high beep=on"
ft-label name=amb2 text="ratio=3:1"               # explicit text= keeps its =
ft_get amb2 text; check "explicit text= keeps its =" "$FT_RET" "ratio=3:1"
ft-label name=amb3 width=20                        # known prop, single word → assignment
ft_get amb3 width; check "known prop still assigns" "$FT_RET" "20"

note "no coerce hook declared → suggestion passes through unchanged"
ft-div name=p1 gap=3
end_ft_div
ft_resolved_prop p1 gap 0
check "gap passes through" "$FT_RET" "3"
check "no errors recorded" "$(ft_has_errors && echo yes)" ""

note "a declared <TYPE>_<PROP>_coerce hook transforms the suggestion"
widget_scale_coerce() {           # name prop suggestion → sets FT_RET
    local suggestion=$3
    FT_RET=$(( suggestion * 2 ))
}
ft-widget() { ft_new widget "$@"; }
ft-widget name=wg1 scale=5
ft_resolved_prop wg1 scale 0
check "hook doubles the value" "$FT_RET" "10"
ft_coerced wg1 scale            # answers in FT_RET now, like every other accessor
check "coerced value cached"   "$FT_RET" "10"

note "a failing hook keeps the suggestion and records an error"
# The hook's rule used to be "a non-negative integer", exercised with width=-5 — until the
# framework began dropping a negative length itself (`+` in _FT_NUMERIC_PROP), which takes the
# declaration away before any hook can see it. What this section tests is the MECHANISM, so
# the rule is now one the framework has no opinion about: an even number of columns. The
# teeth are unchanged — a fallback that did NOT happen leaves the ERROR MESSAGE where the
# value should be, and the measure below reads that as 0.
ft_errors_clear
strictbox_width_coerce() {        # name prop suggestion → sets FT_RET
    local suggestion=$3
    if [[ "$suggestion" =~ ^[0-9]+$ ]] && (( suggestion % 2 == 0 )); then
        FT_RET=$suggestion
    else
        printf -v FT_RET 'width must be an even number of columns, got %q' "$suggestion"
        return 1
    fi
}
ft-strictbox() { ft_new strictbox "$@"; }
ft-strictbox name=sb1 width=5
ft_own_prop sb1 width
check "bad value falls back to suggestion" "$FT_RET" "5"
check "error was recorded" "$(ft_has_errors && echo yes)" "yes"
check "error count is 1" "${#FT_ERRORS[@]}" "1"
check "error names the control" "${FT_ERRORS[0]%%$'\t'*}" "sb1"

ft_errors_clear
ft-strictbox name=sb2 width=12
ft_own_prop sb2 width
check "good value passes"    "$FT_RET" "12"
check "no error for good value" "$(ft_has_errors && echo yes)" ""

note "coerce hooks apply automatically during a real layout pass"
ft_errors_clear
ft-form name=f2
    ft-strictbox name=sb3 width=7 height=3
end_ft_form
ft_layout f2
check "measure kept fallback outer width" "${FT_MEASURED_WIDTH[sb3]}" "7"
check "layout-time coercion recorded the error" "$(ft_has_errors && echo yes)" "yes"

summary
