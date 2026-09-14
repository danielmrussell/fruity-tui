#!/usr/bin/env bash
# Unit tests for the shared accelerator-label helpers: an accelerator letter is
# underlined in place when it appears in the label, and appended as " (X)" when
# it does not (nothing to underline) — so the shortcut is always visible.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
mark() { printf '%s' "$1" | sed 's/\x1b\[4m/<U>/g; s/\x1b\[24m/<\/U>/g; s/\x1b\[[0-9;]*m//g'; }

note "accelerator IN the label is underlined in place"
_ft_accel_markup "Remove" R ""
check "R underlined in Remove" "$(mark "$FT_RET")" "<U>R</U>emove"
_ft_accel_markup "Invisible" V ""
check "first matching v underlined" "$(mark "$FT_RET")" "In<U>v</U>isible"
_ft_accel_markup "Save" S ""
check "case-insensitive match" "$(mark "$FT_RET")" "<U>S</U>ave"

note "accelerator NOT in the label is appended in parentheses"
_ft_accel_markup "Next" K ""
check "Next (K) with K underlined" "$(mark "$FT_RET")" "Next (<U>K</U>)"
_ft_accel_text "Next" K
check "effective text carries the parenthetical (for width)" "$FT_RET" "Next (K)"
_ft_accel_text "Save" S
check "effective text unchanged when accessKey is present" "$FT_RET" "Save"

note "no accelerator → label unchanged"
_ft_accel_markup "Plain" "" ""
check "no markup" "$(mark "$FT_RET")" "Plain"
_ft_accel_text "Plain" ""
check "no parenthetical" "$FT_RET" "Plain"

note "a button's intrinsic width accounts for an appended (X)"
ft-form name=app width=40 height=6
    ft-button name=bIn  text="Save" accessKey=S
    ft-button name=bOut text="Next" accessKey=K
end_ft_form
ft_layout app
# "Next (K)" is 8 cols + 2 padding = 10; "Save" is 4 + 2 = 6
check "button with in-label accessKey sized to label" "${FT_MEASURED_WIDTH[bIn]}"  "6"
check "button with appended (X) is wider"          "${FT_MEASURED_WIDTH[bOut]}" "10"

summary
