#!/usr/bin/env bash
# A deliberately wedgeable app, for tests/escape-hatch.py.
#
# Press W and it stops servicing its event loop forever — the state a real hang leaves you
# in. The only question that matters is whether the keyboard can still get you out, because
# once Ctrl+C stops quitting, Ctrl+\ is the last thing standing between a user and a
# terminal they have to close.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/fruity-tui.bash"

wedge_now() {
    # A tight builtin loop: no syscall to be interrupted, no subprocess to kill. If bash can
    # still run a trap between iterations, the escape works; if it cannot, nothing does.
    local i=0
    while :; do (( i++ )); done
}

ft-form name=app width=40 height=8
    ft-label  name=hint "Press W to wedge this app on purpose."
    ft-button name=b "Nothing"
end_ft_form

ft_keymap wedge_map
ft_keymap_set wedge_map key=W onKey='wedge_now $this'
ft-modify app keymap=wedge_map

_setup() { ft_layout app; }
ft-run app _setup
