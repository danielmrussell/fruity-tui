#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  ONE ANSWER TO "IS THIS VISIBLE?"
#
#  There were two. `ft_state_is_hidden` — what `:hidden` and the painter use — resolves
#  `visibility` through the cascade, so a child that explicitly re-shows itself under a hidden
#  container is visible: visibility inherits, and the child's own value wins, which is CSS's
#  rule and the codebase's own re-show idiom (`ft_set X visibility=visible`).
#  `_ft_hidden_anywhere` — what focus and accelerators use — walked ancestors reading the RAW
#  property and called the control hidden if ANY ancestor said so.
#
#  So a re-shown control was painted on the screen, matched `button:visible`, and could not be
#  Tabbed to or reached by its accessKey: visible to the eye, unreachable by the keyboard, with
#  nothing saying why.
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

ft-form name=app width="$FT_COLS" height="$FT_ROWS"
    ft-div name=grp visibility=hidden
        ft-button name=btnIn text="Sneak" accessKey=Y visibility=visible
        ft-button name=btnHid text="Stay"
    end_ft_div
    ft-button name=btnOut text="Outside"
end_ft_form
FT_ROOT=app; ft_layout app

note "a child that re-shows itself under a hidden container"
ft_resolved_prop btnIn visibility visible
check "the cascade resolves it visible" "$FT_RET" visible
FT_OUT=""; ft_draw_one btnIn; drawn=$FT_OUT; FT_OUT=""
case "$drawn" in *Sneak*) check "the painter draws it" 1 1 ;; *) check "the painter draws it" 0 1 ;; esac
check "the :hidden predicate calls it visible" \
      "$(ft_state_is_hidden btnIn && echo hidden || echo visible)" visible

note "…so focus and accelerators must agree"
check "focus may land on it" \
      "$(_ft_focus_skippable btnIn && echo skipped || echo focusable)" focusable
_ft_accel_target app Y
check "its accessKey reaches it" "$FT_RET" btnIn

note "a sibling that merely INHERITS the hidden container stays hidden everywhere"
check "the :hidden predicate calls it hidden" \
      "$(ft_state_is_hidden btnHid && echo hidden || echo visible)" hidden
check "…and focus skips it" \
      "$(_ft_focus_skippable btnHid && echo skipped || echo focusable)" skipped

note "display:none still hides a subtree outright — it does not inherit, it is walked"
ft-form name=app2 width="$FT_COLS" height="$FT_ROWS"
    ft-div name=gone display=none
        ft-button name=deep text="Deep" visibility=visible
    end_ft_div
end_ft_form
FT_ROOT=app2; ft_layout app2
check "a control under display:none is hidden" \
      "$(ft_state_is_hidden deep && echo hidden || echo visible)" hidden
check "…and focus skips it" \
      "$(_ft_focus_skippable deep && echo skipped || echo focusable)" skipped

summary
