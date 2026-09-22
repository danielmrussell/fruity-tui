#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  AN APP HOLDS SCREENS, AND A SCREEN IS ONE WHOLE TERMINAL VIEW.
#
#  Every app written before ft-screen opens `ft-form name=app width="$FT_COLS" height="$FT_ROWS"`
#  and four demos carry a hand-written _resize to keep that true. That form IS a screen — it
#  fills the terminal, it owns the focus ring, and it carries Tab/Shift-Tab/the arrows/Esc. A
#  screen is that, named, so the size and the resize leave app code; and an APP is the thing
#  that can hold a SECOND one, which is the only thing a form could never do.
#
#  The screens that are not current are display=none, so they keep every bit of their state —
#  no rebuild, no globals to stash a value in, no guards around a page that may not exist yet.
#  That is the mechanism ft-tabs has always used for its panels.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=60; FT_ROWS=16

HIT=""
ft-app name=a
    ft-screen name=main
        ft-heading name=h text="Samba Mago"
        ft-button name=go   text="Go"   accessKey=g onActivate='HIT=went'
        ft-button name=quit text="Quit"
        ft-keylegend name=leg keys=auto
    end_ft_screen
    ft-screen name=help
        ft-button name=back text="Back"
    end_ft_screen
end_ft_app
FT_ROOT=a; ft_layout a

note "a screen is the terminal, and the first one is what you see"
check "it took the terminal's size"   "$(ft_get main width; printf '%s' "$FT_RET")x$(ft_get main height; printf '%s' "$FT_RET")" "60x16"
check "the first screen is current"   "$(ft_get a currentScreen; printf '%s' "$FT_RET")" "main"
check "…and the other is hidden"      "$(ft_get help display; printf '%s' "$FT_RET")" "none"

note "each screen owns its own focus ring"
# The ring holds REAL names: a control in a screen is qualified by it.
check "the ring is the current screen's" "${FT_FOCUS_RING[*]}" "main__go main__quit"
# NB: dispatch OUTSIDE the $( ), or the focus move happens in a subshell and dies with it —
# the check then reads the focus that never moved.
ft_focus go
ft_dispatch_event TAB
check "Tab walks it"                     "$FT_FOCUS" "main__quit"
# The two buttons sit side by side (a screen lays out as a row), so LEFT is the arrow that
# moves between them — the arrows are SPATIAL, which is why they exist as well as Tab.
ft_dispatch_event LEFT
check "…and the arrows do too"           "$FT_FOCUS" "main__go"

note "navigation is a property, not a verb"
ft_set a currentScreen=help
check "the new screen is shown"       "$(ft_get help display; printf '%s' "$FT_RET")" "flex"
check "…the old one is hidden"        "$(ft_get main display; printf '%s' "$FT_RET")" "none"
check "…and the ring is the new one's" "${FT_FOCUS_RING[*]}" "help__back"
ft_set a currentScreen=main
check "going back restores the ring"   "${FT_FOCUS_RING[*]}" "main__go main__quit"
# A hidden screen KEEPS ITS STATE — that is the whole reason pages do not need rebuilding.
ft_set back text="Return"
ft_set a currentScreen=help
check "a hidden screen kept its state" "$(ft_get back text; printf '%s' "$FT_RET")" "Return"
ft_set a currentScreen=main
no "naming a screen that does not exist is refused" ft_set a currentScreen=nope
# …and the app still points at a screen that EXISTS. The property is written before the hook
# that validates it runs, so a refusal has to put the honest value back — otherwise the ring,
# the resize and a modal coming back all ask "which screen?" and get a name that answers nothing.
check "…and the app still points at a real screen" "$(ft_get a currentScreen; printf '%s' "$FT_RET")" "main"

note "an accessKey is scoped to the SCREEN"
check "the registry is keyed by screen" "${FT_ACCEL_LIST["main"$'\x1f'"G"]:-missing}" "main__go"
HIT=""; _ft_accel_dispatch main G
check "…and the letter activates it"    "$HIT" "went"
# The legend reaches a scope's caps BY TYPE (`_ft_caps_<type>`), so a screen needed its own
# name on that body: without it the keys fired, the underline was drawn, and the bar said
# nothing about either.
FT_CAPS=(); ft_focus go; _ft_legend_caps
check "…and the bar advertises it" \
      "$(printf '%s\n' "${FT_CAPS[@]}" | grep -c $'\tG\t')" "1"

note "a resize reaches every screen, including the hidden one"
FT_COLS=80; FT_ROWS=24
_ft_fit_to_terminal a
check "the visible screen resized"  "$(ft_get main width; printf '%s' "$FT_RET")x$(ft_get main height; printf '%s' "$FT_RET")" "80x24"
check "…and so did the hidden one"  "$(ft_get help width; printf '%s' "$FT_RET")x$(ft_get help height; printf '%s' "$FT_RET")" "80x24"
FT_COLS=60; FT_ROWS=16; _ft_fit_to_terminal a

note "a modal comes back to the screen it left, not to the whole app"
ft_focus quit
ft_modal_push a
ft-form name=dlg width=20 height=5 parent=a
    ft-button name=ok text="OK"
end_ft_form
FT_ROOT=dlg; ft_layout dlg; ft_focus ok
check "the modal has its own ring"    "${FT_FOCUS_RING[*]}" "ok"
ft_modal_pop
check "…and the screen's ring is back" "${FT_FOCUS_RING[*]}" "main__go main__quit"
check "…with the focus it had"         "$FT_FOCUS" "main__quit"
ft_remove dlg

note "an app that holds no screens says so"
err_file=$(mktemp "${TMPDIR:-/tmp}/ft-app.XXXXXX"); trap 'rm -f "$err_file"' EXIT
ft-app name=empty 2>"$err_file"
end_ft_app 2>>"$err_file"
check "the empty app is named" \
      "$(case "$(<"$err_file")" in *"holds screens, and this one holds none"*) echo named ;; *) echo "${_x:-silent}" ;; esac)" "named"

note "a form is still runnable, because every app ever written is one"
ft-form name=legacy width=40 height=8
    ft-button name=lb text="L"
end_ft_form
FT_ROOT=legacy; ft_layout legacy
check "a root form still owns its ring" "${FT_FOCUS_RING[*]}" "lb"
check "…and is still its own scope"     "$(_ft_is_focus_scope legacy && echo scope || echo group)" "scope"

# `${ASSOC[""]}` IS A BASH ERROR, not an empty lookup, and stderr in a TUI is the screen the
# user is reading. FT_ROOT is legitimately empty in plenty of moments — before ft_run, inside a
# test that has not set one — and the file dialog found this the day it was written.
# `currentScreen` NAMES THE STATE, so writing it must SWITCH — and it arrives three ways:
# ft_set, the construction DSL, and a STATE RESTORE. ft-tabs learned this with activeTab, where
# a reloaded app came back with the number restored and the first tab still on screen. Driving
# it the way a restore does — straight through _ft_setprop, which ft_set's own route never
# touches — is the only way to tell the two apart.
note "every route that writes currentScreen switches the screen"
ft_set a currentScreen=main
_ft_setprop a currentScreen help          # exactly what a state restore does
check "the restore switched screens"  "$(ft_get help display; printf '%s' "$FT_RET")" "flex"
check "…and hid the other"            "$(ft_get main display; printf '%s' "$FT_RET")" "none"
check "…and moved the ring"           "${FT_FOCUS_RING[*]}" "help__back"
ft_set a currentScreen=main
# The construction DSL is the third route.
ft-app name=ctor currentScreen=second
    ft-screen name=first;  ft-button name=f1 text="1"; end_ft_screen
    ft-screen name=second; ft-button name=f2 text="2"; end_ft_screen
end_ft_app
check "the DSL chose the screen too" "$(ft_get second display; printf '%s' "$FT_RET")" "flex"
ft_remove ctor

# THINGS ONLY A RUNNING APP FINDS. Every one of these was invisible to 116 test files, because
# a test builds a tree and calls ft_layout itself — an APP does neither.
note "ft_run lays the app out before it paints it"
# Every demo in this tree passed a `_setup` callback whose whole body was `ft_layout app`.
# Ceremony the framework was asking for and could do itself — and an app that forgot it drew
# NOTHING, in silence, which is the least debuggable failure a UI can have.
_body=$(declare -f ft_run)
_lay=$(printf '%s\n' "$_body" | grep -n 'ft_layout "\$root"'   | head -1 | cut -d: -f1)
_pnt=$(printf '%s\n' "$_body" | grep -n 'ft_redraw_all "\$root"' | head -1 | cut -d: -f1)
check "ft_run lays out BEFORE the first paint" "$(( _lay > 0 && _lay < _pnt ))" "1"

note "a screen stacks its children; a form is a row"
# Inheriting `row` from form gave a heading and a status bar ZERO WIDTH and stood them beside
# the body. A screen is a heading, a body and a status bar, one above the other.
ft-app name=stackapp
    ft-screen name=stk
        ft-heading name=head text="Title"
        ft-label   name=body text="Body"
    end_ft_screen
end_ft_app
FT_ROOT=stackapp; ft_layout stackapp
check "the screen is a column"   "$(ft_resolved_prop stk flexDirection ''; printf '%s' "$FT_RET")" "column"
check "…so the heading has width" "$(( ${FT_MEASURED_WIDTH[stk__head]:-0} > 0 ))" "1"
check "…and the body is below it" "$(( ${FT_ABSOLUTE_Y[stk__body]:-0} > ${FT_ABSOLUTE_Y[stk__head]:-0} ))" "1"
ft_remove stackapp; FT_ROOT=a

note "asking which scope is live before there is one says nothing"
_sv_root=$FT_ROOT
_e=$(mktemp "${TMPDIR:-/tmp}/ft-scope.XXXXXX")
FT_ROOT=""; _ft_current_scope 2>"$_e"
check "no scope, no complaint"   "$(<"$_e")" ""
check "…and it answers nothing"  "${FT_RET:-empty}" "empty"
: > "$_e"; _ft_fit_to_terminal "" 2>"$_e"
check "fitting nothing is quiet" "$(<"$_e")" ""
: > "$_e"; _ft_app_show a "" 2>"$_e"
check "showing no screen names the gap" \
      "$(case "$(<"$_e")" in *"no screen named <nothing>"*) echo named ;; *) echo "${_x:-silent}" ;; esac)" "named"
rm -f "$_e"; FT_ROOT=$_sv_root

summary
