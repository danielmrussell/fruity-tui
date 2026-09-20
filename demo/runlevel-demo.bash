#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — demo/runlevel-demo.bash   (RUNLEVELS: how engaged a control is)
#
#  A control is not simply "focused or not". It sits at a RUNLEVEL, and the keys
#  that work depend on which one:
#
#      unfocused ──focus──▶ poised ──Enter──▶ scrolling ──Enter──▶ editing   (writable)
#                                                        ──Enter──▶ perusing  (read-only)
#
#      Esc, from any rung, comes back to `poised` — not all the way out. You are still
#      standing on the control, just no longer inside it; Tabbing away is what returns
#      it to `unfocused`.
#
#  The point of the bottom rung: while a field is merely POISED, the arrow keys
#  still move focus between controls. They only scroll the field once you have
#  asked for it. Tab to the log below and press ↓ — focus moves. Press Enter
#  first, and the same ↓ scrolls.
#
#  Watch the KEY LEGEND as you go: it is derived from the control's computed
#  keymap, so it changes with the runlevel. It can never advertise a key that
#  would not fire, because dispatch reads the same keymap it does.
#
#      bash demo/runlevel-demo.bash
#
#  Keys:  Tab/arrows move · Enter climbs a rung · Esc leaves · B legend style · Q quit
# ─────────────────────────────────────────────────────────────────────────────
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/fruity-tui.bash"
ft_init
ft_term_size

_log_text=$'nothing here yet\nsecond line\nthird line\nfourth line\nfifth line\nsixth line\nseventh line\neighth line\nninth line\ntenth line'
_readme=$'This field is readOnly.\n\nEnter takes it to `scrolling`, and a second\nEnter to `perusing` — a caret you can move\nand select with, but nothing you type\nchanges the text.\n\nTry Backspace in here: nothing happens,\nbecause the mutating keys are not bound\nat this runlevel at all.'

ft-form name=app width="$FT_COLS" height="$FT_ROWS" display=flex flexDirection=column \
        key='[Qq]' onKey=ft_quit key='[Bb]' onKey=toggle_caps
    ft-frame name=win title="Runlevels" display=flex flexDirection=column gap=1 \
             padding=1 flexGrow=1
        ft-label name=hint text="Tab between the three fields. Enter climbs a rung, Esc leaves. Watch the legend."

        ft-label     name=lab1 text="A one-line field — nothing to scroll, so ONE Enter reaches editing:"
        ft-textfield name=one  value="type here"

        ft-label     name=lab2 text="A scrollable log — Enter for scrolling, Enter again for editing:"
        ft-textfield name=log  rows=4 value="$_log_text"

        ft-label     name=lab3 text="A read-only viewer — the second Enter reaches perusing, not editing:"
        ft-textfield name=view rows=4 readOnly=true value="$_readme"
    end_ft_frame

    ft-keylegend name=legend flexShrink=0 keys=auto
    # The base status is static help. Once a field is ENGAGED the framework's own mode hint
    # takes the bar over and names the runlevel you are in — so the bar is live without the
    # demo tracking anything. (An earlier version updated it from a callback and lagged a
    # keypress behind: ft_run's `render` argument only fires on invalidation, not per frame,
    # and there is no instance-level focus event to hang it on.)
    ft-statusbar name=bar flexShrink=0 \
                 status="Tab moves · Enter climbs a rung · Esc leaves · B legend style · Q quit"
end_ft_form

# B toggles the legend between the boxed default and the one-row flat style, so both
# are visible without editing the file.
toggle_caps() {
    ft_get legend capStyle
    [[ "$FT_RET" == boxed ]] && ft_set legend capStyle=flat \
                             || ft_set legend capStyle=boxed
    ft_refresh
}

# The `keymap` property above BINDS B and Q (and creates the instance overlay these caps hang
# on), but a plain binding carries no LABEL — and only a labelled cap reaches a `keys=auto`
# legend. So the demo advertised "Q quit" in its status line while the legend never showed it.
# Re-declaring the same patterns as caps upgrades them in place (same pattern = replace).
_bind_app_keys() {
    ft_set app \
        key='[Bb]' keyCap="Legend style" keyImp=normal onKey=toggle_caps \
        key='[Qq]' keyCap="Quit" keyImp=normal onKey=ft_quit
}

_setup() { _bind_app_keys; ft_layout app; ft_focus one; }
ft_run app _setup
