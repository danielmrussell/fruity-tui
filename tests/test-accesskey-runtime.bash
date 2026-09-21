#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  AN ACCELERATOR IS A REGISTRATION, NOT JUST A PROPERTY.
#
#  `accessKey` has a registry behind it — FT_ACCEL_LIST plus a binding on the enclosing form's
#  keymap — while the UNDERLINE a control draws comes from the property. It was registered at
#  construction and nowhere else, so `ft_set btn accessKey=K` moved the underline and left
#  the key bound to S: an underlined letter that did nothing, and an un-underlined one that
#  still fired. In a framework whose rule is "an underlined letter is a promise", that is the
#  promise broken.
#
#  This is the THIRD table in ft-forms.bash fed from a property at construction whose runtime
#  route was missing — FT_DRAW followed, FT_FOCUSABLE did not (fixed), FT_ACCEL_LIST did not.
#  The shared-letter case below is the one a careless fix breaks: several controls may own the
#  same accelerator, so unregistering one must not unbind the key from the others.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=60; FT_ROWS=14

FIRED=""
hit_save()   { FIRED="save"; }
hit_share()  { FIRED="share"; }
hit_second() { FIRED="second"; }

ft-form name=app width=60 height=14
    ft-button name=save text="Save" accessKey=S onActivate='hit_save "$@"'
    ft-button name=shareA text="Share" accessKey=H onActivate='hit_share "$@"'
    ft-button name=shareB text="Hide" accessKey=H onActivate='hit_second "$@"'
end_ft_form
ft_layout app
FT_ROOT=app

# ft_dispatch_event takes the TOKEN, and for a character the token IS the character —
# _ft_dispatch sets tok=$FT_EVENT_CHAR for a CHAR event, so a keymap's `[Ss]` is matched
# against `S`. Passing "CHAR 53" fires nothing and makes a working accelerator look broken.
_press() { FIRED=""; ft_dispatch_event "$1" >/dev/null 2>&1; printf '%s' "${FIRED:-none}"; }
_registered() {                 # letter → the controls registered for it, or "-"
    local akey="app"$'\x1f'"$1"
    printf '%s' "${FT_ACCEL_LIST[$akey]:--}"
}

note "the accelerator works as declared (without this the rest is vacuous)"
check "S is registered to save"   "$(_registered S)" "save"
check "…and S fires it"           "$(_press S)"      "save"
check "K is registered to nobody" "$(_registered K)" "-"
check "…and K fires nothing"      "$(_press K)"      "none"

note "changing it at runtime moves the accelerator, not just the underline"
ft_set save accessKey=K
check "the property changed"      "$(_ft_get_raw save accessKey; printf %s "$FT_RET")" "K"
check "K is registered now"       "$(_registered K)" "save"
check "…and K fires it"           "$(_press K)"      "save"
check "S is registered to nobody" "$(_registered S)" "-"
check "…and the old letter is dead" "$(_press S)"    "none"

note "a letter SHARED by two controls survives one of them changing"
# The key activates the first enabled, visible sharer — so unregistering shareA must leave H
# bound and working for shareB. A fix that simply unbinds the key would pass everything above
# and break this.
check "H is registered to both"   "$(_registered H)" "shareA shareB"
ft_set shareA accessKey=Z
check "…H now belongs to shareB alone" "$(_registered H)" "shareB"
check "…and H still fires"             "$(_press H)"      "second"
check "…while Z reaches shareA"        "$(_press Z)"      "share"

note "and removing a control gives its letter back"
ft_remove shareB
check "H is registered to nobody" "$(_registered H)" "-"
check "…and H fires nothing"      "$(_press H)"      "none"

summary
