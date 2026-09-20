#!/usr/bin/env bash
# Tests for ft-settings.bash: the Settings modal construction, faded/unsupported
# rows, and the live Windows-Terminal toggle (against a throwaway file).
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=80; FT_ROWS=26

note "F2 decodes (SS3 / xterm / linux console)"
for seq in $'\x1bOQ' $'\x1b[12~' $'\x1b[[B'; do
    printf '%s' "$seq" > /tmp/fs.$$; exec 7< /tmp/fs.$$; _ft_decode_key 7; exec 7<&-
    check "F2 decodes" "$FT_KTOK" "F2"
done
rm -f /tmp/fs.$$

# A minimal root so the modal has something to restore to.
ft-form name=app width=80 height=26
  ft-textfield name=tf size=10 value="x"
end_ft_form
ft_layout app; FT_ROOT=app; FT_FOCUS=tf

D=$(mktemp -d); FAKE="$D/settings.json"
printf '%s\n' '{' '    "actions": [' '    ],' '}' > "$FAKE"

note "status line matches the checkbox state AT BUILD TIME (regression: it used to lag)"
ft_wt_find() { FT_RET="$FAKE"; return 0; }
FT_WINDOWS_TERMINAL_APPLIED=1
_ft_settings_build; ft_layout __settings
ft_resolved_prop __setwt value ""; check "checkbox checked when applied" "$FT_RET" "true"
ft_resolved_prop __setwtnote text ""
case "$FT_RET" in *On\ *|*On—*) check "note says On when applied (not the opposite)" 1 1 ;; *) check "note says On when applied" 0 1 ;; esac
ft_remove __settings
FT_WINDOWS_TERMINAL_APPLIED=0
_ft_settings_build; ft_layout __settings
ft_resolved_prop __setwtnote text ""
case "$FT_RET" in *Off\ *|*Off—*) check "note says Off when not applied" 1 1 ;; *) check "note says Off when not applied" 0 1 ;; esac
ft_remove __settings

note "with Windows Terminal present: the WT toggle is enabled"
FT_WINDOWS_TERMINAL_APPLIED=0
_ft_settings_build; ft_layout __settings
check "keyboard-status label exists" "${FT_TYPE[__setkbd]:-none}"   "label"
check "WT checkbox exists"           "${FT_TYPE[__setwt]:-none}"    "checkbox"   # checkbox is its own type now
ft_resolved_prop __setwt disabled false;     check "WT toggle is ENABLED here" "$FT_RET" "false"
ft_resolved_prop __setmeta disabled false;   check "macOS toggle is FADED off-mac" "$FT_RET" "true"
check "Close button exists"          "${FT_TYPE[__setclose]:-none}" "button"

note "toggling the WT checkbox applies / restores live"
cp "$FAKE" "$D/pristine"
__setwt_on_activate
check "on_activate freed the keys" "$(grep -c unbound "$FAKE")" "4"
check "applied flag set"           "$FT_WINDOWS_TERMINAL_APPLIED" "1"
__setwt_on_deactivate
check "on_deactivate restored"     "$(grep -c unbound "$FAKE")" "0"
check "file back to pristine"      "$(diff -q "$FAKE" "$D/pristine" >/dev/null && echo same)" "same"
ft_remove __settings

note "with NO Windows Terminal: the WT toggle is shown but FADED"
unset -f ft_wt_find; ft_wt_find() { FT_RET=""; return 1; }
_ft_settings_build; ft_layout __settings
check "WT checkbox still shown"    "${FT_TYPE[__setwt]:-none}" "checkbox"
ft_resolved_prop __setwt disabled false;   check "WT toggle FADED when not WT" "$FT_RET" "true"
ft_remove __settings

note "the Ctrl+C toggle: copy in a copyable context, otherwise quit"
# Ctrl+C is a SETTING because it trades one thing for another. On, the tty releases `intr` so
# the key reaches the app and a selection can be copied; off, the tty keeps it and Ctrl+C is
# always an immediate kill. Either way Ctrl+\ (SIGQUIT) remains the escape from a wedged app,
# which is what makes ON a defensible default.
_saved_cc=${FT_CTRL_C_COPY:-1}
FT_CTRL_C_COPY=1; _ft_settings_build; ft_layout __settings
check "the toggle is present"        "${FT_TYPE[__setcc]:-none}" "checkbox"
# a checkbox maps `checked=` onto its `value`; ask the control, not the constructor argument
check "…and reflects the setting when on"  "$(ft_checkbox_is_checked __setcc && echo yes)" "yes"
_ft_settings_cc_note
case "$FT_RET" in *"copies a selection"*) check "the note explains ON" 1 1 ;;
                  *) check "the note explains ON" 0 1 ;; esac
ft_remove __settings
FT_CTRL_C_COPY=0; _ft_settings_build; ft_layout __settings
check "…and when off"                      "$(ft_checkbox_is_checked __setcc || echo no)" "no"
_ft_settings_cc_note
case "$FT_RET" in *"always quits"*) check "the note explains OFF" 1 1 ;;
                  *) check "the note explains OFF" 0 1 ;; esac
ft_remove __settings
# The tty flags follow the setting — that is the whole mechanism.
FT_CTRL_C_COPY=1; _ft_tty_flags
case "$FT_RET" in *"intr undef"*) check "ON releases intr so the key arrives"  1 1 ;;
                  *)             check "ON releases intr so the key arrives"  0 1 ;; esac
case "$FT_RET" in *"susp undef"*) check "…and susp stays released for undo"    1 1 ;;
                  *)             check "…and susp stays released for undo"    0 1 ;; esac
FT_CTRL_C_COPY=0; _ft_tty_flags
case "$FT_RET" in *"intr undef"*) check "OFF leaves intr as the kill"          0 1 ;;
                  *)             check "OFF leaves intr as the kill"          1 1 ;; esac
# …and software flow control is off in BOTH states. With IXON on, Ctrl+S is XOFF: the terminal
# stops showing output and the app looks hung for ever (measured: 0 bytes drawn afterwards),
# which is a cruel thing to do to the most reflexive "save" chord there is.
case "$FT_RET" in *"-ixon"*) check "flow control is off (Ctrl+S can't freeze)" 1 1 ;;
                  *)         check "flow control is off (Ctrl+S can't freeze)" 0 1 ;; esac
FT_CTRL_C_COPY=1; _ft_tty_flags
case "$FT_RET" in *"-ixon"*) check "…in the other state too"                   1 1 ;;
                  *)         check "…in the other state too"                   0 1 ;; esac
FT_CTRL_C_COPY=$_saved_cc

note "Close button sets the close flag"
_FT_SETTINGS_CLOSE=0; __setclose_on_activate
check "Close flagged the modal to close" "$_FT_SETTINGS_CLOSE" "1"

rm -rf "$D"
summary
