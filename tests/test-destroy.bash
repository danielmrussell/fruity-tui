#!/usr/bin/env bash
# Unit tests for ft_remove: the missing piece that let FT_DIRTY (and every
# other per-control bookkeeping array) accumulate forever across every demo
# that rebuilds its screen on each interaction (wizard/growth/scrollbar-demo),
# eventually making ft_redraw_dirty's O(n^2) sort over an ever-growing dirty
# set visibly slower with every rebuild.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null

note "ft_remove removes a leaf control from every bookkeeping array"
ft-form name=app
ft-label name=leaf parent=app text=hi margin=1
ft_remove leaf
check "FT_TYPE entry gone"       "${FT_TYPE[leaf]+set}"       ""
check "FT_PARENT entry gone"     "${FT_PARENT[leaf]+set}"     ""
check "FT_PROPS entry gone"      "${FT_PROPS[leaf]+set}"      ""
check "FT_DIRTY entry gone (it was dirtied at construction)" "${FT_DIRTY[leaf]+set}" ""
check "the underlying _ftp_leaf_text global variable is gone"   "${_ftp_leaf_text+set}"   ""
check "the underlying _ftp_leaf_margin global variable is gone" "${_ftp_leaf_margin+set}" ""

note "ft_remove recurses into every descendant"
ft-div name=parentPanel parent=app
ft-label name=childA parent=parentPanel text=a
ft-div name=childPanel parent=parentPanel
ft-label name=grandchild parent=childPanel text=g
ft_remove parentPanel
check "the panel itself is gone"      "${FT_TYPE[parentPanel]+set}" ""
check "its direct child is gone"      "${FT_TYPE[childA]+set}"      ""
check "its nested grandchild is gone" "${FT_TYPE[grandchild]+set}"  ""
check "the grandchild's own dirty entry is gone too" "${FT_DIRTY[grandchild]+set}" ""

note "ft_remove cleans up a control's own instance-overlay keymap"
# (Prototype-default keymaps are shared and survive — only the per-instance
# overlay, created by a trailing `keymap k=action` section, is torn down.)
ft-scrollbar name=sb parent=app width=1 height=5 key=UP onKey=ft_quit
km="${FT_KEYMAP[sb]}"
check "sb got an overlay keymap list" "$(declare -p "_fti_${km}__list" 2>/dev/null >/dev/null; echo $?)" "0"
ft_remove sb
check "FT_KEYMAP[sb] itself is gone" "${FT_KEYMAP[sb]+set}" ""
check "the overlay's backing array is gone" "$(declare -p "_fti_${km}__list" 2>/dev/null >/dev/null; echo $?)" "1"

note "ft_remove on an already-abandoned subtree fixes the real bug: FT_DIRTY stops growing across rebuilds"
ft-form name=app2
dirty_before=${#FT_DIRTY[@]}
type_before=${#FT_TYPE[@]}
_build_id=0
_rebuild() {
    (( _build_id++ ))
    local suf="_r${_build_id}"
    local old="${FT_KIDS[app2]:-}"
    ft-div name="win${suf}" parent=app2
    ft-label name="msg${suf}" parent="win${suf}" text=hi
    ft-label name="msg2${suf}" parent="win${suf}" text=bye
    FT_KIDS[app2]="win${suf}"
    [[ -n "$old" ]] && ft_remove "$old"
}
for i in 1 2 3 4 5; do _rebuild; done
check "FT_DIRTY only grew by the CURRENT build's 3 controls, not all 15 ever created across 5 rebuilds" \
    "$(( ${#FT_DIRTY[@]} - dirty_before ))" "3"
check "FT_TYPE only grew by the current build's 3 controls too, old ones fully gone" \
    "$(( ${#FT_TYPE[@]} - type_before ))" "3"

note "ft_redraw_all with no root (e.g. a modal closing over no host app) is a safe no-op"
FT_ROOT=""
err=$( { ft_redraw_all "$FT_ROOT"; } 2>&1 1>/dev/null )
check "empty root → no stderr noise from the redraw walk" "$err" ""

note "removing a control that does not exist is a no-op — and is NOT fatal under set -u"
# "Clear the old one, then make a new one" is the natural way to write a caller, and on the
# FIRST run there is no old one. ft_remove read FT_KIDS[$name] with no `:-`, so that first
# call killed the whole app under `set -u`: pressing '.' (the focus locator, which clears a
# previous beacon before placing one) quit runlevel-demo instantly, with the error going to
# an alt screen already being torn down. The demos run with set -u; the unit suites did not.
err=$( { ft_remove __never_created_at_all; } 2>&1 )
check "no stderr from removing a missing control" "$err" ""
ok   "…and it returns cleanly"                    ft_remove __never_created_at_all
ok   "fatal-under-set-u regression: a whole app survives it" \
     bash -uc 'source '"$here"'/fruity-tui.bash; ft_init; exec {FT_TTY}>/dev/null
               ft-form name=a width=10 height=4; end_ft_form
               ft_remove __missing; ft_focus_ping a'

summary
