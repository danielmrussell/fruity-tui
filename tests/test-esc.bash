#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  What Esc does — and, just as load-bearing, what it no longer does.
#
#  Esc used to open a command menu (ft-menu.bash, deleted): one safe key that
#  reached Help/Settings/About/Quit, chosen because terminals steal every other
#  chord. That design was retired when the runlevel model gave Esc a better job —
#  LEAVING. Esc backs out of a field's edit mode and cancels a dialog, and those
#  live where they belong, in the textfield and the dialog. At the form level it
#  is now a deliberate NO-OP, and `ft_esc_action` is an empty function in
#  ft-forms.bash that exists to keep the binding documented and greppable.
#
#  This file was tests/test-menu.bash and it tested two things. Half of it drove
#  the retired menu by REBUILDING ITS FORM INLINE — so it asserted against a copy
#  of the constructor rather than the constructor — and then checked a flag
#  (_FT_MENU_CLOSE) that the menu's own loop never read. A mutation probe proved
#  the point: deleting the loop's real close (`quit) want_quit=1; break`) left the
#  file passing 19/19, including an assertion named "Quit DOES close the menu".
#  A gate that cannot fail is worse than no gate, because it reads as coverage.
#  That half went with the feature. What survives is the half that was always
#  real: Esc's live contract.
#
#  THE CONTRACT
#    · the form still BINDS Esc (to the no-op), so the key stays accounted for
#    · Esc opens no menu and quits nothing — a stray Esc is never destructive
#    · an IDLE field does not bind Esc at all, so it bubbles to the form
#    · in EDIT mode Esc cancels a selection first and STAYS in edit
#    · in EDIT mode with nothing to cancel, Esc leaves edit mode
#    · Esc never edits the text on any of those paths
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=60; FT_ROWS=20

ft-form name=app width=60 height=20
  ft-textfield name=tf size=20 value="hello"
end_ft_form
ft_layout app; FT_ROOT=app; FT_FOCUS=tf

note "Esc at the form level is a deliberate NO-OP (the command menu is gone)"
if _ft_keymap_lookup ft_keymap_form ESC; then check "form still binds Esc → ft_esc_action" "$FT_RET" "ft_esc_action"
else check "form binds Esc" "missing" "ft_esc_action"; fi

# The retired menu is GONE, not stubbed: if anything ever re-introduces a menu call on
# this path, ft_command_menu will not exist and this asserts the absence directly.
check "no command menu survives to be opened" \
      "$(declare -F ft_command_menu >/dev/null && echo exists || echo absent)" "absent"
QUIT=0; ft_quit() { QUIT=1; }
ft_esc_action
check "Esc does NOT quit" "$QUIT" "0"
unset -f ft_quit 2>/dev/null || true

note "Esc from a field: an idle field bubbles it; in edit it cancels, then leaves"
# In the Enter-to-edit model an IDLE field's keymap doesn't bind Esc at all, so
# ft_dispatch_event leaves it unhandled and it bubbles up to the form.
ft_textfield_deactivate tf; FT_TEXTFIELD_CARET[tf]=0; _ft_textfield_sel_clear tf; unset "FT_TEXTFIELD_MARK[tf]"
_ft_try_keymaps tf ESC
check "idle field declines Esc (→ bubbles up to the form)" "$?" "1"
# In EDIT mode, Esc with a live selection clears it (consumed, stays in edit)
ft_textfield_activate tf; FT_TEXTFIELD_CARET[tf]=0; FT_TEXTFIELD_ANCHOR[tf]=3
ft_textfield_esc tf
_ft_textfield_selrange tf && check "Esc cleared the selection" 0 1 || check "Esc cleared the selection" 1 1
ft_get tf runlevel; check "still in edit mode after clearing selection" "$FT_RET" "editing"
# In EDIT mode with nothing to cancel, Esc leaves edit mode (back to idle)
ft_textfield_esc tf
# POISED, because `tf` still has focus (line 41). Esc leaves the INSIDES of the control, not
# the control — the same landing ft_runlevel_out gives every other class. This asserted
# `unfocused` and was pinning a defect: a text box went two rungs down where everything else
# went one, and the field claimed to be unfocused while FT_FOCUS still named it.
ft_get tf runlevel; check "Esc with nothing to cancel exits edit mode" "$FT_RET" "poised"
ft_get tf value; check "Esc never edited the text" "$FT_RET" "hello"

# …and `poised` is a LIVE ANSWER, not the word `unfocused` renamed. With focus elsewhere the
# same call lands on `unfocused`, because where leaving lands is a question about focus and
# _ft_runlevel_resting is the one place that answers it.
ft_textfield_activate tf
ft_get tf runlevel; check "back in edit mode for the companion" "$FT_RET" "editing"
FT_FOCUS=""
ft_textfield_esc tf
ft_get tf runlevel; check "…with focus elsewhere, leaving lands on unfocused" "$FT_RET" "unfocused"
FT_FOCUS=tf

summary
