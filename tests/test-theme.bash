#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Tests for the theme layer (ft-css.bash): ft_theme / ft_use_theme and the
#  derivation of the legacy FT_COLOR_* globals from a stylesheet written in real CSS.
#
#  The load-bearing test is PIN FIDELITY: the CSS-authored `ft-dark` theme, run
#  through the same ft_sgr composer controls paint with, must reproduce every
#  themeable FT_COLOR_* byte-for-byte with the hand-written dark palette in
#  ft_setup_palette. If it does, `ft_use_theme ft-dark` renders identically to the
#  shipped palette — no terminal needed to prove it. (A live tty can never catch a
#  colour-byte regression from a headless run; an equality pin can.)
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init                     # runs ft_setup_palette → FT_COLOR_* hold the canonical dark values
exec {FT_TTY}>/dev/null

# Snapshot the hand-written dark palette BEFORE the theme system touches anything.
declare -A PIN=()
for g in SCREEN FOCUS FOCUS_BTN SEL BODY RESET PANE TITLE BORDER DIVIDER \
         SELECTED INPUT INPUT_FOCUS STRIPE FADED TEXT_ACCENT TEXT_NOTICE TEXT_MUTED; do
    v="FT_COLOR_$g"; PIN[$g]=${!v}
done
PIN_CURSOR=$FT_CURSOR_COLOR

note "ft_theme registers a theme's CSS; ft_use_theme selects it and reports unknown themes"
ok  "a built-in theme is registered"        test -n "${FT_THEME_CSS[ft-dark]+x}"
ok  "ft_use_theme ft-dark succeeds"         ft_use_theme ft-dark
check "the active theme is recorded"        "$FT_ACTIVE_THEME" "ft-dark"
no  "an unknown theme fails"                 ft_use_theme ft-nope
check "…and does not change the active one" "$FT_ACTIVE_THEME" "ft-dark"

note "PIN: the CSS-authored ft-dark derives every themeable global byte-for-byte"
ft_use_theme ft-dark        # derive from the stylesheet, overwriting the snapshot's source
for g in SCREEN FOCUS FOCUS_BTN SEL BODY RESET PANE TITLE BORDER DIVIDER \
         SELECTED INPUT INPUT_FOCUS STRIPE FADED TEXT_ACCENT TEXT_NOTICE TEXT_MUTED; do
    v="FT_COLOR_$g"; check "FT_COLOR_$g matches the hand-written palette" "${!v}" "${PIN[$g]}"
done
check "FT_CURSOR_COLOR matches"             "$FT_CURSOR_COLOR" "$PIN_CURSOR"

note "the composed escapes are exactly the expected combined SGR (bg;fg[;attr])"
check "FT_COLOR_BODY  = bg234;fg255"     "$FT_COLOR_BODY"     $'\e[48;5;234;38;5;255m'
check "FT_COLOR_SCREEN= bg16;fg250"      "$FT_COLOR_SCREEN"   $'\e[48;5;16;38;5;250m'
check "FT_COLOR_FOCUS = bg39;fg16;bold"  "$FT_COLOR_FOCUS"    $'\e[48;5;39;38;5;16;1m'
check "FT_COLOR_TITLE = bg234;fg51;bold" "$FT_COLOR_TITLE"    $'\e[48;5;234;38;5;51;1m'
check "FT_COLOR_INPUT_FOCUS has NO bold" "$FT_COLOR_INPUT_FOCUS" $'\e[48;5;24;38;5;231m'
check "FT_COLOR_TEXT_ACCENT = fg39"       "$FT_COLOR_TEXT_ACCENT" $'\e[38;5;39m'

note "the WHOLE palette derives from the ft-dark stylesheet — no hand-written escapes left"
ft_use_theme ft-dark
check "FT_COLOR_KEYCAP  = bg25;fg227;bold"  "$FT_COLOR_KEYCAP"       $'\e[48;5;25;38;5;227;1m'
check "FT_COLOR_STATUS  = bg25;fg231"       "$FT_COLOR_STATUS"       $'\e[48;5;25;38;5;231m'
check "FT_COLOR_CARET   = bg220;fg16;bold"  "$FT_COLOR_CARET"        $'\e[48;5;220;38;5;16;1m'
check "FT_COLOR_THUMB   = bg245 ONLY"       "$FT_COLOR_THUMB"        $'\e[48;5;245m'
check "FT_COLOR_VIEW    = fg44 ONLY"        "$FT_COLOR_VIEW"         $'\e[38;5;44m'
check "FT_COLOR_DISABLED_TXT = fg242 ONLY"  "$FT_COLOR_DISABLED_TXT" $'\e[38;5;242m'
check "FT_COLOR_BUTTON     = bg244;fg16"       "$FT_COLOR_BUTTON"          $'\e[48;5;244;38;5;16m'
check "FT_COLOR_HEADING = bg23;fg255;bold"  "$FT_COLOR_HEADING"      $'\e[48;5;23;38;5;255;1m'
check "FT_COLOR_HINT    = bg236;fg252"      "$FT_COLOR_HINT"         $'\e[48;5;236;38;5;252m'
check "FT_COLOR_WARN    = bg234;fg214"      "$FT_COLOR_WARN"         $'\e[48;5;234;38;5;214m'
check "FT_SHEEN_GLOW = 18 (from --sheen-glow)" "$FT_SHEEN_GLOW" "18"
# The active-line lift is themeable, and until now only test-stale checked it — and only as
# "the caret's row differs from the idle row", which a renamed custom property would fail far
# from the cause. Pinned here by VALUE so the failure names the theme token that moved. The
# property is `--textfield-active-bg`, after the selector it backs (`textfield::active`).
check "FT_COLOR_ACTIVELINE = bg235 (from --textfield-active-bg)" "$FT_COLOR_ACTIVELINE" $'\e[48;5;235m'

note "switching themes actually changes the palette (swap-the-stylesheet)"
ft_use_theme ft-light
no  "light body differs from dark body"      test "$FT_COLOR_BODY" = "${PIN[BODY]}"
check "light screen backdrop"                "$FT_COLOR_SCREEN"  $'\e[48;5;250;38;5;240m'
check "light focus accent"                   "$FT_COLOR_FOCUS"   $'\e[48;5;25;38;5;255;1m'
check "light cursor colour"                  "$FT_CURSOR_COLOR" "#005fd7"
check "light active line lifts to 255"       "$FT_COLOR_ACTIVELINE" $'\e[48;5;255m'

ft_use_theme ft-ocean
check "ocean selected row carries bold"      "$FT_COLOR_SELECTED" $'\e[48;5;41;38;5;16;1m'
check "ocean focus accent"                   "$FT_COLOR_FOCUS"    $'\e[48;5;51;38;5;17;1m'
check "ocean active line lifts to 23"        "$FT_COLOR_ACTIVELINE" $'\e[48;5;23m'

note "returning to dark restores the canonical palette exactly"
ft_use_theme ft-dark
check "dark body restored"                   "$FT_COLOR_BODY"    "${PIN[BODY]}"
check "dark focus restored"                  "$FT_COLOR_FOCUS"   "${PIN[FOCUS]}"

note "FT_COLOR_RESET is a CLEAN-SLATE reset — clears bold/underline before restoring body colours"
check "FT_COLOR_RESET starts with ESC[0m"        "${FT_COLOR_RESET:0:4}" $'\e[0m'
check "FT_COLOR_RESET then restores body colours" "$FT_COLOR_RESET"      "$FT_ANSI_RESET${PIN[BODY]}"

note "a theme switch is clean under set -u (the derivation probe is not a built control)"
# The demos run with `set -u`; the probe is never made by a constructor, so any
# FT_PROPS/array read in the switch path must be guarded. Regression for the crash
# `FT_PROPS[$name]: unbound variable` on selecting a theme.
( set -u; ft_use_theme ft-light && ft_use_theme ft-ocean && ft_use_theme ft-dark ) >/dev/null 2>&1
ok "ft_use_theme runs under set -u without an unbound-variable error" \
   bash -uc 'source '"$here"'/fruity-tui.bash; ft_init; exec {FT_TTY}>/dev/null
             ft_use_theme ft-light && ft_use_theme ft-ocean && ft_use_theme ft-dark'

note "the attribute palette is a FLOOR, not the no-colour alternative"
# _ft_theme_sync assigns each FT_COLOR_* only when the theme actually produced a value, and then
# reads some of them straight back — `FT_COLOR_FOCUS_BTN=$FT_COLOR_FOCUS`. While those defaults
# sat inside the no-colour `else`, a theme silent on one slot left that read unbound: invisible
# normally, fatal under `set -u`. So the floor must hold with NO theme applied at all, which is
# what this asks — laying the defaults alone and requiring every read-back slot to exist.
# Stubbing the theme to define NOTHING is the whole point: it is the silent-theme case, and it
# fails against defaults that live in the no-colour branch, because the colour branch is the one
# taken here. Asserting the defaults merely exist would pass either way and prove nothing.
ok "colour path lays the floor BEFORE the theme, so a silent theme leaves no slot unset" \
   env TERM=xterm-256color bash -uc 'source '"$here"'/fruity-tui.bash
             ft_use_theme() { :; }                       # a theme that produces no value at all
             ft_setup_palette
             for v in FT_COLOR_FOCUS FT_COLOR_FOCUS_BTN FT_COLOR_SEL FT_COLOR_BODY \
                      FT_COLOR_RESET FT_SHEEN_GLOW; do
                 [[ -v $v ]] || exit 1
             done
             printf %s "$FT_COLOR_FOCUS_BTN$FT_COLOR_SEL$FT_COLOR_RESET" >/dev/null'
ok "ft_init survives set -u with no colour and no tty" \
   env -u TERM bash -uc 'source '"$here"'/fruity-tui.bash; ft_init; exec {FT_TTY}>/dev/null
                         printf %s "$FT_COLOR_FOCUS" >/dev/null'

summary
