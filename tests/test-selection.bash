#!/usr/bin/env bash
# Unit tests for the multitoggle/checkbox and radio controls: independent
# toggling, mutually-exclusive group selection scoped to siblings-under-one-
# parent, multiple independent groups not interfering, and glyph-aware sizing.
# Checkbox is a two-state multitoggle (FT_TYPE is "multitoggle", not
# "checkbox" — see controls/ft-checkbox.bash), so this also exercises a
# genuine 3-state multitoggle directly, not just through the checkbox sugar.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/ft-core.bash"; source "$here/ft-keymap.bash"; source "$here/ft-forms.bash"
source "$here/controls/ft-multitoggle.bash"; source "$here/controls/ft-checkbox.bash"; source "$here/controls/ft-radio.bash"
ft_init

note "checkbox: default unchecked, toggles independently"
ft-form name=app
ft-checkbox name=cb1 parent=app text="Notifications" accessKey=N
check "checkbox is its OWN type (so \`checkbox {…}\` CSS matches it)" "${FT_TYPE[cb1]}" "checkbox"
no "default not checked" ft_checkbox_is_checked cb1
ft_checkbox_toggle cb1
ok "first toggle → checked"    ft_checkbox_is_checked cb1
ft_checkbox_toggle cb1
no "second toggle → unchecked" ft_checkbox_is_checked cb1

note "checkbox: explicit initial state and independence from siblings"
ft-checkbox name=cb2 parent=app text="Auto-save" checked=true accessKey=A
ft-checkbox name=cb3 parent=app text="Show line numbers" accessKey=S
ok "cb2 starts checked" ft_checkbox_is_checked cb2
ft_checkbox_toggle cb3
ok "toggling cb3 doesn't affect cb2" ft_checkbox_is_checked cb2
ok "cb3 toggled independently"      ft_checkbox_is_checked cb3

note "checkbox: options carry value (submitted) and glyph (presentation)"
ft-checkbox name=cb4 parent=app text="High contrast" checkmarkVariant=unicode
_ft_options cb4
check "checkbox = exactly 2 options"   "${#FT_OPTS[@]}" "2"
ft_get "${FT_OPTS[0]}" value _o0; ft_get "${FT_OPTS[1]}" value _o1; check "option values are false/true" "$_o0,$_o1" "false,true"
ft_get cb4 value; check "value tracks selection"         "$FT_RET" "false"
ft_checkbox_toggle cb4
ft_get cb4 value; check "toggled value = true"           "$FT_RET" "true"

note "checkmarkVariant is a PROPERTY, so it reads back and it acts on every route"
# It used to be a constructor ARGUMENT, consumed and thrown away: a checkbox drawing ☑ answered
# nothing when asked why, and `ft-modify cb checkmarkVariant=unicode` stored the name and
# changed no glyph at all — ft_get said unicode while the screen said [x].
_glyphs_of() {                  # name → FT_RET = its two options' glyphs, off then on
    _ft_options "$1"
    ft_get "${FT_OPTS[0]}" glyph; local off=$FT_RET
    ft_get "${FT_OPTS[1]}" glyph
    FT_RET="$off$FT_RET"
}
_ft_checkmark_states box;     _BOX=$FT_RET;  _BOX=${_BOX//$'\x1f'/}
_ft_checkmark_states unicode; _UNI=$FT_RET;  _UNI=${_UNI//$'\x1f'/}
ft_get cb4 checkmarkVariant;  check "the constructor's variant reads back" "$FT_RET" "unicode"
_glyphs_of cb4;               check "…and its glyphs are the unicode pair" "$FT_RET" "$_UNI"
ft-checkbox name=cb5 parent=app text="Plain"
ft_get cb5 checkmarkVariant;  check "a checkbox nobody asked answers box"  "$FT_RET" "box"
_glyphs_of cb5;               check "…and wears the box pair"              "$FT_RET" "$_BOX"
ft-modify cb5 checkmarkVariant=unicode
ft_get cb5 checkmarkVariant;  check "ft-modify stores it"                  "$FT_RET" "unicode"
_glyphs_of cb5;               check "…AND changes the glyphs"              "$FT_RET" "$_UNI"
ft-modify cb5 checkmarkVariant=box
_glyphs_of cb5;               check "…and back again"                      "$FT_RET" "$_BOX"
# Normalized at the write, like every other keyword: ft_get may only answer a variant that draws.
ft-checkbox name=cb6 parent=app text="Bogus" checkmarkVariant=heavy
ft_get cb6 checkmarkVariant;  check "an unknown variant reads back as box"  "$FT_RET" "box"
_glyphs_of cb6;               check "…and draws the box pair"               "$FT_RET" "$_BOX"
ft-modify cb6 checkmarkVariant=UNICODE
ft_get cb6 checkmarkVariant;  check "…and a keyword is case-insensitive"    "$FT_RET" "unicode"
# `[ ]` is three columns and `☐` is one, so the variant decides the control's width.
# Asserted against the TABLE, not against ft_prop_kind: an unregistered name already answers
# `layout` (the conservative default), so asking the accessor would pass whatever the prototype did.
check "checkmarkVariant is registered layout, not merely defaulted" \
      "${FT_PROP_KIND[checkmarkVariant]:-<unregistered>}" "layout"
ft_prop_kind glyph;            check "glyph -> layout, for the same reason" "$FT_RET" "layout"

note "multitoggle: a genuine 3-option cycle, value kept current with NO hook"
ft-multitoggle name=priority parent=app text="Priority" accessKey=P onActivate=priority_on_activate
    ft-option value=low    glyph="Low"
    ft-option value=medium glyph="Medium"
    ft-option value=high   glyph="High"
end_ft_multitoggle
ft_get priority value; check "starts at low"     "$FT_RET" "low"
ft_multitoggle_cycle priority
ft_get priority value; check "cycles to medium"  "$FT_RET" "medium"
ft_multitoggle_cycle priority
ft_get priority value; check "cycles to high"    "$FT_RET" "high"
ft_multitoggle_cycle priority
ft_get priority value; check "wraps back to low" "$FT_RET" "low"

note "the hook can CANCEL a change by returning nonzero"
priority_on_activate() { [[ "$1" != high ]]; }   # $1=new value; refuse 'high'
ft_multitoggle_cycle priority
ft_get priority value; check "medium accepted"   "$FT_RET" "medium"
ft_multitoggle_cycle priority
ft_get priority value; check "high refused, medium stays" "$FT_RET" "medium"
unset -f priority_on_activate

note "radio: none selected until one is chosen"
ft-div name=grp1 parent=app
ft-radio name=rLight parent=grp1 text="Light" group=theme accessKey=L
ft-radio name=rDark  parent=grp1 text="Dark"  group=theme accessKey=D
ft-radio name=rAuto  parent=grp1 text="Auto"  group=theme accessKey=U
no "rLight not selected before any pick" ft_radio_is_selected rLight
no "rDark not selected before any pick"  ft_radio_is_selected rDark
no "rAuto not selected before any pick"  ft_radio_is_selected rAuto

note "radio: selecting one deselects its group siblings"
ft_radio_select rDark
ok "rDark is selected"        ft_radio_is_selected rDark
no "rLight is not selected"   ft_radio_is_selected rLight
no "rAuto is not selected"    ft_radio_is_selected rAuto

ft_radio_select rLight
ok "rLight now selected"      ft_radio_is_selected rLight
no "rDark no longer selected" ft_radio_is_selected rDark

note "radio: a second group under a different parent is independent"
ft-div name=grp2 parent=app
ft-radio name=rSmall parent=grp2 text="Small" group=size accessKey=S
ft-radio name=rLarge parent=grp2 text="Large" group=size accessKey=L
ft_radio_select rLarge
ok "rLarge selected in its own group"   ft_radio_is_selected rLarge
ok "rLight still selected (untouched)"  ft_radio_is_selected rLight
no "rSmall not selected"                ft_radio_is_selected rSmall

note "sizing: checkbox/radio/multitoggle measure to glyph-prefix + text width"
ft-checkbox name=cbSize parent=app text="1234567890"
ft-radio    name=rSize  parent=app text="1234567890" group=sizecheck
ft-multitoggle name=mtSize parent=app text="1234567890"
    ft-option value=a glyph="X"
    ft-option value=b glyph="YY"
    ft-option value=c glyph="ZZZ"
end_ft_multitoggle
ft_layout app
check "checkbox width = 3 (widest glyph [x]) + 1 (space) + 10 (text)" "${FT_MEASURED_WIDTH[cbSize]}" "14"
check "radio width = 1 (glyph) + 1 (space) + 10 (text)"               "${FT_MEASURED_WIDTH[rSize]}"  "12"
check "multitoggle sizes to WIDEST option glyph (ZZZ=3) + 1 + 10"     "${FT_MEASURED_WIDTH[mtSize]}" "14"

summary
