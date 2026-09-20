#!/usr/bin/env bash
# Tests for controls/ft-keylegend.bash: the one-row key legend split out from the status
# bar — the "KEY=Label" split (spaces in labels survive), 1-row height, non-focusable,
# keys=auto derivation, the importance sort, keycap glyphs, and the keycap/exit pulse.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=80; FT_ROWS=24

_vis() { LC_ALL=C sed -E $'s/\x1b\\][^\x07]*\x07//g; s/\x1b\\[[0-9;]*[A-Za-z]//g' ; }

note "the legend splits on 2+ spaces; single-space labels stay whole"
_ft_kl_split "Enter=Open  Ctrl+N=New Folder  Del=Delete"
check "three pairs"        "${#FT_KEYLEGEND_PAIRS[@]}" "3"
check "pair 0"             "${FT_KEYLEGEND_PAIRS[0]}"  "Enter=Open"
check "label keeps space"  "${FT_KEYLEGEND_PAIRS[1]}"  "Ctrl+N=New Folder"
check "pair 2"             "${FT_KEYLEGEND_PAIRS[2]}"  "Del=Delete"

note "a bare token (no '=') is kept as its own legend segment"
_ft_kl_split "F1=Help  |  Q=Quit"
check "bare separator survives" "${FT_KEYLEGEND_PAIRS[1]}" "|"

note "the control is a one-row, non-focusable block"
ft_prototype_init keylegend          # lazy init otherwise waits for the first instance
check "height is 1"     "$(_ft_height_keylegend; echo "$FT_RET")" "1"
check "class not focusable" "${FT_PROTO_FOCUSABLE[keylegend]}" "0"

note "keys= accepts a value containing spaces (registered prop)"
ft-form name=root width=80 height=6
  ft-keylegend name=legend keys="Enter=Open  Del=Delete"
end_ft_form
ft_layout root
_ft_get_raw legend keys; check "keys stored with spaces" "$FT_RET" "Enter=Open  Del=Delete"
check "legend laid out 3 tall (capStyle=boxed, the default)" "${FT_MEASURED_HEIGHT[legend]}" "3"
ft_set legend capStyle=flat; ft_layout root
check "…and 1 tall with capStyle=flat"                       "${FT_MEASURED_HEIGHT[legend]}" "1"
ft_set legend capStyle=boxed; ft_layout root

note "the legend paints its caps + labels"
FT_OUT=""; _ft_draw_keylegend legend
vis=$(printf '%s' "$FT_OUT" | _vis)
[[ "$vis" == *"Enter"*"Open"*"Del"*"Delete"* ]] && check "legend painted" 1 1 || check "legend painted" 0 1

note "an over-long legend is clipped to the strip, never spilling past its width"
ft_set legend keys="A=aaaaaaaaaa  B=bbbbbbbbbb  C=cccccccccc  D=dddddddddd  E=eeeeeeeeee  F=ffffffffff  G=gggggggggg  H=hhhhhhhhhh"
FT_OUT=""; ft_layout root; _ft_draw_keylegend legend
check "legend width unchanged" "${FT_MEASURED_WIDTH[legend]}" "80"

note "in a MODE (FT_MODE_HINT) the exit key (Esc) is pulled to the FRONT with a distinct chip"
ft_set legend keys="Tab=Next  Enter=Edit  Esc=Exit edit  Q=Quit"
FT_OUT=""; _ft_draw_keylegend legend
vis=$(printf '%s' "$FT_OUT" | _vis | tr -s ' ')
# Match on ORDER alone, not on the cap's punctuation: capStyle=boxed renders `│ Tab │ Next`
# where flat renders `Tab: Next`, and what this is actually asserting is which cap comes FIRST.
[[ "$vis" == *"Tab"*"Esc"* ]] && check "no mode: Tab leads, Esc later" 1 1 \
                             || check "no mode: Tab leads, Esc later" 0 1
FT_MODE_HINT="Press ESC to exit edit mode and return to navigation."
FT_OUT=""; _ft_draw_keylegend legend
vis=$(printf '%s' "$FT_OUT" | _vis | tr -s ' ')
[[ "$vis" == *"Esc"*"Tab"* ]] && check "ESC jumps to the FRONT" 1 1 \
                             || check "ESC jumps to the FRONT" 0 1
[[ "$FT_OUT" == *"38;5;16;1m"* ]] && check "the ESC cap gets its distinct exit chip (dark ink)" 1 1 \
                                 || check "the ESC cap gets its distinct exit chip (dark ink)" 0 1
FT_MODE_HINT=""

# ── Derived, importance-sorted legend ────────────────────────────────────────
note "a cap carries importance+label but dispatch still resolves only the CODE"
ft_keymap kmt
ft_keymap_set kmt key=UP   keyCap="Scroll up"  keyImp=200 onKey='act_up $this' \
                  key=PGUP keyCap="Page up"    keyImp=120 onKey='act_pgup $this' \
                  key=TAB  keyCap="Next field" keyImp=90
                  # TAB is legend-only — a cap with no code: advertised here, handled by
                  # whoever really owns it (engine Tab traversal), so it must not dispatch.
_ft_keymap_lookup kmt UP;  check "keycap dispatch reads the action" "$FT_RET" 'act_up $this'
FT_RET=SENTINEL
_ft_keymap_lookup kmt TAB && check "a legend-only cap does NOT match dispatch" 0 1 \
                                || check "a legend-only cap does NOT match dispatch" 1 1
check "...and leaves the lookup result untouched (bubbles)" "$FT_RET" "SENTINEL"

note "_ft_caps_sort orders by importance DESC and is stable on ties"
FT_CAPS=($'120\tPGUP\tPage up' $'200\tUP\tUp' $'200\tDOWN\tDown' $'60\tHOME\tTop')
_ft_caps_sort
check "highest first"                 "${FT_CAPS[0]}" $'200\tUP\tUp'
check "stable tie keeps input order"  "${FT_CAPS[1]}" $'200\tDOWN\tDown'
check "lowest last"                   "${FT_CAPS[3]}" $'60\tHOME\tTop'

note "_ft_keycap_glyph prettifies patterns for the legend"
_ft_keycap_glyph UP;       check "arrow → glyph"        "$FT_RET" "↑"
_ft_keycap_glyph PGUP;     check "named key → cap"      "$FT_RET" "PgUp"
_ft_keycap_glyph '[Kk]';   check "letter class → letter" "$FT_RET" "K"
_ft_keycap_glyph CTRL+PGUP; check "modifier spelled + dash" "$FT_RET" "Ctrl-PgUp"
_ft_keycap_glyph x;        check "bare char stays itself" "$FT_RET" "x"

note "keys=auto DERIVES the legend from the focused control's chain, sorted, Up/Down leading"
ft-form name=lroot width=80 height=8 key='[Kk]' onKey=noop
  ft-label name=big2 text=$'a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl' width=20 maxHeight=4
  ft-keylegend name=lbar keys=auto
end_ft_form
ft_keymap_set "${FT_KEYMAP[lroot]}" \
    key='[Kk]' keyCap="Next page" keyImp=150
ft_layout lroot
FT_ROOT=lroot; ft_focus big2
_ft_legend_caps
first=${FT_CAPS[0]#*$'\t'}; first=${first%%$'\t'*}
# MERELY FOCUSED, the crucial key is ENTER — the one that steps into the control. The
# scrolling keys are real but they are not yours yet, and a legend that advertised Up/Down
# out here would be promising keys that move FOCUS instead. Delve, and the legend changes.
check "focused-but-not-entered: the way IN leads"  "$first" "ENTER"
ft_dispatch_event ENTER >/dev/null 2>&1
_ft_legend_caps
first=${FT_CAPS[0]#*$'\t'}; first=${first%%$'\t'*}
check "…once inside, the scroller's crucial key leads" "$first" "UP"
FT_OUT=""; _ft_draw_keylegend lbar
vis=$(printf '%s' "$FT_OUT" | _vis)
[[ "$vis" == *"Scroll up"*"Scroll down"* ]] && check "derived legend renders Up then Down" 1 1 \
                                            || check "derived legend renders Up then Down" 0 1
case "$vis" in *"Scroll up"*"Next page"*) check "control keys lead the app-level key" 1 1 ;;
               *) check "control keys lead the app-level key" 0 1 ;; esac

note "keycap pulse: the crucial cap cycles the theme's --keycap-pulse ramp; frozen if none"
ft_use_theme ft-dark   # default ramp: 214 220 227 231 227 220
_ft_kcpulse_capcolor lbar 0; check "phase 0 → ramp[0]=214 fg" "$FT_RET" $'\e[48;5;25;38;5;227;1m\e[38;5;214m'
_ft_kcpulse_capcolor lbar 3; check "phase 3 → ramp[3]=231 fg" "$FT_RET" $'\e[48;5;25;38;5;227;1m\e[38;5;231m'
_ft_kcpulse_capcolor lbar 6; check "phase wraps (6 % 6 = 0 → 214)" "$FT_RET" $'\e[48;5;25;38;5;227;1m\e[38;5;214m'
ft_use_theme ft-ocean
_ft_kcpulse_capcolor lbar 1; check "a theme recolours the pulse (ocean ramp[1]=51)" "$FT_RET" $'\e[48;5;25;38;5;227;1m\e[38;5;51m'
ft_use_theme ft-dark

note "the EXIT key (ESC in a mode) breathes its OWN themeable ramp (--keycap-exit-pulse)"
_ft_kcpulse_exitcolor lbar 0; check "exit phase 0 → bg 208" "$FT_RET" $'\e[48;5;208;38;5;16;1m'
_ft_kcpulse_exitcolor lbar 3; check "exit phase 3 → bg 226 (it animates)" "$FT_RET" $'\e[48;5;226;38;5;16;1m'
ft_use_theme ft-ocean
_ft_kcpulse_exitcolor lbar 0; check "a theme recolours the exit chip (ocean bg 214)" "$FT_RET" $'\e[48;5;214;38;5;16;1m'
ft_use_theme ft-dark

note "which SGR a cap wears — the decision that sits between the ramp and the screen"
# Everything on either side of this was correct and tested while the pulse was invisible: the
# ramp resolved, the colours animated, arm and disarm worked. The decision BETWEEN them asked
# "is this cap the exit chip?" by comparing its colour to the exit chip's — and outside a mode
# the exit chip's colour IS the ordinary keycap base, so it compared a value against itself,
# came out false for every cap on every frame, and the pulse never reached the screen. These
# assertions pin the decision to the KEY, which is what it was always trying to ask.
_ft_keylegend_cap_sgr Enter "" BASE "" PULSE $'\nEnter\n'
check "outside a mode, a crucial cap wears the pulse"        "$FT_RET" "PULSE"
check "…and names the ramp, so the caller can arm on it"     "$FT_KEYLEGEND_CAP_RAMP" "crucial"
_ft_keylegend_cap_sgr Tab "" BASE "" PULSE $'\nEnter\n'
check "a cap that is not crucial wears the base"             "$FT_RET" "BASE"
check "…and names no ramp, so it is not repainted per frame" "$FT_KEYLEGEND_CAP_RAMP" ""
_ft_keylegend_cap_sgr Enter "" BASE "" "" $'\nEnter\n'
check "no ramp in the theme → the base, and nothing to arm"  "$FT_RET" "BASE"
check "…so an unthemed pulse leaves nothing ticking"         "$FT_KEYLEGEND_CAP_RAMP" ""
_ft_keylegend_cap_sgr Esc mode BASE EXIT PULSE $'\nEsc\n'
check "in a mode the exit chip wears its own ramp"           "$FT_RET" "EXIT"
check "…named as its own, never the crucial one"             "$FT_KEYLEGEND_CAP_RAMP" "exit"
_ft_keylegend_cap_sgr Esc mode BASE "" PULSE $'\nEsc\n'
check "an unthemed exit chip falls back to the base"         "$FT_RET" "BASE"
check "…and animates nothing"                                "$FT_KEYLEGEND_CAP_RAMP" ""
_ft_keylegend_cap_sgr Esc "" BASE EXIT PULSE $'\nEsc\n'
check "outside a mode Esc is an ordinary cap and may pulse"  "$FT_RET" "PULSE"
check "…on the crucial ramp, like any other cap"             "$FT_KEYLEGEND_CAP_RAMP" "crucial"

note "the pulse arms only while a crucial cap is up, and never restarts itself (steady phase)"
_ft_kcpulse_disarm
_ft_kcpulse_arm; [[ -n "${FT_ANIM_PHASE[__ft_kcpulse]:-}" ]] && check "arm starts the animation" 1 1 || check "arm starts the animation" 0 1
FT_ANIM_PHASE[__ft_kcpulse]=7; _ft_kcpulse_arm   # idempotent: must NOT reset the phase
check "re-arm does not reset the phase" "${FT_ANIM_PHASE[__ft_kcpulse]}" "7"
_ft_kcpulse_disarm; [[ -z "${FT_ANIM_PHASE[__ft_kcpulse]:-}" ]] && check "disarm stops it" 1 1 || check "disarm stops it" 0 1


# ── A legend that goes stale is a legend that lies ──────────────────────────
# `keys=auto` is DERIVED from the focused control, so every transition that changes what the
# control can do has to mark it dirty. _ft_legend_dirty was called on focus changes, runlevel
# changes and the textfield's state — and NOT when the KEYS THEMSELVES change, which was fair
# enough while a binding could only be written before the app ran. `ft_set btn key=…` and
# `defaultKeys=` make rebinding an ordinary thing to do at runtime, and the legend went on
# advertising the keys the control used to have until something else happened to repaint it.
note "changing a control's keys repaints a derived legend"
ft-form name=slroot width=80 height=8
    ft-button name=slbtn text="Go"
    ft-keylegend name=sllegend keys=auto
end_ft_form
FT_ROOT=slroot; ft_layout slroot; ft_focus slbtn
_legend_text() { FT_OUT=""; _ft_draw_keylegend sllegend; printf '%s' "$FT_OUT"; }
before=$(_legend_text)
check "the legend starts on the button's own key" \
      "$(case "$before" in *Activate*) echo yes ;; *) echo "${before:-empty}" ;; esac)" "yes"

FT_DIRTY=(); ft_set slbtn key=Z keyCap="Zap it" keyImp=crucial onKey='ft_quit'
check "binding a key marks the legend dirty"  "${FT_DIRTY[sllegend]:-no}" "1"
check "…and the new cap is what it draws" \
      "$(case "$(_legend_text)" in *Zap*) echo yes ;; *) echo missing ;; esac)" "yes"

FT_DIRTY=(); ft_set slbtn defaultKeys=false
check "silencing prototype keys marks it dirty" "${FT_DIRTY[sllegend]:-no}" "1"
check "…and the prototype's cap is gone" \
      "$(case "$(_legend_text)" in *Activate*) echo still-there ;; *) echo gone ;; esac)" "gone"

FT_DIRTY=(); ft_set slbtn keymap=kmt
check "pointing at a shared keymap marks it dirty" "${FT_DIRTY[sllegend]:-no}" "1"
# The bar advertises ACCELERATORS as well as keys, and they move the same way.
FT_DIRTY=(); ft_set slbtn accessKey=g
check "changing an accessKey marks it dirty"       "${FT_DIRTY[sllegend]:-no}" "1"

summary
