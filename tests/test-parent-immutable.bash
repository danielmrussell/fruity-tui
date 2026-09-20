#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  THE TREE IS NOT A PROPERTY.
#
#  `parent` says "attach me here" at construction, and ft_new wires FT_PARENT and the parent's
#  FT_KIDS from it. Written AFTERWARDS it moved nothing: the property named one container while
#  FT_PARENT and FT_KIDS named another. Layout walks FT_KIDS, the focus ring walks FT_KIDS,
#  clipping walks FT_PARENT — and ft-state serialises PROPERTIES, so a save/restore would have
#  put the control inside whatever the stale property said.
#
#  Refused rather than performed, because that is the DOM: `parentNode` is read-only and you
#  move a node with a verb. docs/api-naming.md already maps it to a reader.
#
#  This is the fourth table in ft-forms.bash fed from a property at construction whose runtime
#  route was wrong; see CONTRIBUTING §1 for the other three.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=60; FT_ROWS=16

ft-form name=app width=60 height=16
    ft-div name=boxA width=20 height=6
        ft-button name=btn "Move me"
    end_ft_div
    ft-div name=boxB width=20 height=6
    end_ft_div
end_ft_form
ft_layout app
FT_ROOT=app

_prop()   { _ft_get_raw btn parent; printf '%s' "${FT_RET:-<empty>}"; }
# "no children" is UNSET in one place and the EMPTY STRING in another — the entry is created
# lazily and dropped again — and asserting on the raw value made this file fail on the state it
# was written to describe. One answer for both, since the question is "does it own anything".
_kidsof() { local k=${FT_KIDS[$1]:-}; printf '%s' "${k:-<no children>}"; }

note "the tree and the property agree to begin with"
check "property names boxA"  "$(_prop)"            "boxA"
check "FT_PARENT agrees"     "${FT_PARENT[btn]}"   "boxA"
check "boxA owns the button" "$(_kidsof boxA)"     "btn"
check "boxB owns nothing"    "$(_kidsof boxB)"     "<no children>"

note "a runtime parent= is refused, and refused LOUDLY"
# IT MUST RUN IN THIS SHELL. `_err=$(ft-modify …)` is a command substitution, so ft-modify would
# run in a SUBSHELL and every write it makes — including the bad one this file exists to catch —
# would be discarded on return. Written that way the divergence assertions below PASS on the
# broken engine, which is exactly what the teeth check caught. Same trap as `ft-modify … | sed`.
# So: redirect stderr to a file, and read the file afterwards.
_errfile=$(mktemp); trap 'rm -f "$_errfile"' EXIT
ft-modify btn parent=boxB 2>"$_errfile"
_err=$(cat "$_errfile")
check "…it says so on stderr"        "$([[ "$_err" == *"not settable"* ]] && echo 1 || echo 0)" 1
check "…and names the verb to use"   "$([[ "$_err" == *"ft_append"* ]]    && echo 1 || echo 0)" 1

note "…and nothing diverged: the property still tells the truth"
check "property still names boxA" "$(_prop)"          "boxA"
check "FT_PARENT unmoved"         "${FT_PARENT[btn]}" "boxA"
check "boxA still owns it"        "$(_kidsof boxA)"   "btn"
check "boxB still owns nothing"   "$(_kidsof boxB)"   "<no children>"

note "the verb it names actually moves the control, tree and property together"
# Without this the refusal could be "parent can never change", which would be a different and
# wrong contract — and a fix that simply deleted the property would pass everything above.
ft_append boxB btn
check "ft_append moved FT_PARENT"      "${FT_PARENT[btn]}" "boxB"
check "…boxB owns it now"              "$(_kidsof boxB)"   "btn"
check "…and boxA has let it go"        "$(_kidsof boxA)"   "<no children>"

summary
