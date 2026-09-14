#!/usr/bin/env bash
# Tests for ft-keyboard.bash: the (codepoint,mods)→token normalizer, the kitty and
# xterm-modifyOtherKeys decoders, env-based negotiation, and the full decode path.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null

# helper: run the normalizer and render "TOK" or "CHAR:hex"
tok() { _ft_kbd_token "$1" "$2"; [[ "$FT_KTOK" == CHAR ]] && printf 'CHAR:%s' "$FT_KARG" || printf '%s' "$FT_KTOK"; }

note "normalizer: (codepoint, modmask) → the shared token vocabulary"
check "Space plain → SPACE"        "$(tok 32 0)"  "SPACE"
check "Ctrl+Space (mod4) → CTRL+SPACE" "$(tok 32 4)" "CTRL+SPACE"
check "Ctrl+@ (cp64,mod4) → CTRL+SPACE" "$(tok 64 4)" "CTRL+SPACE"
check "a plain → CHAR 61"          "$(tok 97 0)"  "CHAR:61"
check "Shift+a → CHAR 41 (A)"      "$(tok 97 1)"  "CHAR:41"
check "Ctrl+a → CTRL+a"            "$(tok 97 4)"  "CTRL+a"
check "Alt+f → ALT+f"              "$(tok 102 2)" "ALT+f"
check "Ctrl+g → CTRL+g"            "$(tok 103 4)" "CTRL+g"
check "Enter (cp13) → ENTER"       "$(tok 13 0)"  "ENTER"
check "Esc (cp27) → ESC"           "$(tok 27 0)"  "ESC"
check "Tab (cp9) → TAB"            "$(tok 9 0)"   "TAB"
check "Shift+Tab → BTAB"           "$(tok 9 1)"   "BTAB"
check "Backspace (cp127) → BACKSPACE" "$(tok 127 0)" "BACKSPACE"
check "Ctrl+< (cp60,mod4) → CTRL+<" "$(tok 60 4)" "CTRL+<"

note "UTF-8 encoder (pure arithmetic, no fork)"
_ft_kbd_utf8 233;    check "é (U+00E9) → c3a9"     "$FT_RET" "c3a9"
_ft_kbd_utf8 8364;   check "€ (U+20AC) → e282ac"   "$FT_RET" "e282ac"
_ft_kbd_utf8 65;     check "A (U+0041) → 41"       "$FT_RET" "41"

note "kitty decoder: \\e[ code ; mods[:event] u"
kit() { _ft_kbd_decode_kitty "$1"; [[ "$FT_KTOK" == CHAR ]] && printf 'CHAR:%s' "$FT_KARG" || printf '%s' "$FT_KTOK"; }
check "[32;5u → CTRL+SPACE"        "$(kit '[32;5u')"   "CTRL+SPACE"
check "[97;5u → CTRL+a"            "$(kit '[97;5u')"   "CTRL+a"
check "[122;3u → ALT+z"            "$(kit '[122;3u')"  "ALT+z"
check "[27u → ESC"                 "$(kit '[27u')"     "ESC"
check "[13u → ENTER"               "$(kit '[13u')"     "ENTER"
check "[97u (no mods) → CHAR 61"   "$(kit '[97u')"     "CHAR:61"
_ft_kbd_decode_kitty '[97;5:3u';   check "release event (…:3) is dropped" "$FT_KTOK" ""
check "[97;5:1u (press) → CTRL+a"  "$(kit '[97;5:1u')" "CTRL+a"
check "[97:65;5u (alternates) → CTRL+a" "$(kit '[97:65;5u')" "CTRL+a"
_ft_kbd_decode_kitty '[57442;5u'; check "kitty modifier-key report (Left-Ctrl PUA) is dropped" "$FT_KTOK" ""
_ft_kbd_decode_kitty '[57441;6u'; check "kitty modifier-key report (Left-Shift PUA) is dropped" "$FT_KTOK" ""
_ft_kbd_token 57442 4;            check "PUA codepoint → no garbage CHAR"                       "$FT_KTOK" ""

note "xterm modifyOtherKeys decoder: \\e[27;mods;code~"
xt() { _ft_kbd_decode_xterm "$1"; [[ "$FT_KTOK" == CHAR ]] && printf 'CHAR:%s' "$FT_KARG" || printf '%s' "$FT_KTOK"; }
check "[27;5;32~ → CTRL+SPACE"     "$(xt '[27;5;32~')" "CTRL+SPACE"
check "[27;5;97~ → CTRL+a"         "$(xt '[27;5;97~')" "CTRL+a"
check "[27;3;100~ → ALT+d"         "$(xt '[27;3;100~')" "ALT+d"

note "full pipeline: raw bytes → _ft_decode_key → token"
feed() { local f; f=$(mktemp); printf '%b' "$1" > "$f"; exec {r}<"$f"; _ft_decode_key "$r"; exec {r}<&-; rm -f "$f"; }
feed '\e[32;5u';    check "bytes \\e[32;5u → CTRL+SPACE"   "$FT_KTOK" "CTRL+SPACE"
feed '\e[27;5;32~'; check "bytes \\e[27;5;32~ → CTRL+SPACE" "$FT_KTOK" "CTRL+SPACE"
feed '\e[105;5u';   check "bytes \\e[105;5u → CTRL+i"       "$FT_KTOK" "CTRL+i"
feed '\e[A';        check "legacy arrow still decodes (fast path)" "$FT_KTOK" "UP"

note "negotiation from environment (no I/O)"
env_proto() ( unset KITTY_WINDOW_ID WT_SESSION VTE_VERSION TERM_PROGRAM; export TERM=""; "$@"; _ft_kbd_from_env; printf '%s' "$FT_RET" )
check "KITTY_WINDOW_ID → kitty"   "$(env_proto export KITTY_WINDOW_ID=1)"   "kitty"
check "WT_SESSION → kitty"        "$(env_proto export WT_SESSION=abc)"      "kitty"
check "VTE_VERSION → xterm"       "$(env_proto export VTE_VERSION=6800)"    "xterm"
check "TERM=xterm-256color → xterm" "$(env_proto export TERM=xterm-256color)" "xterm"
check "TERM_PROGRAM=WezTerm → kitty" "$(env_proto export TERM_PROGRAM=WezTerm)" "kitty"
check "bare/unknown → legacy"     "$(env_proto true)"                       "legacy"

note "enable/disable emit the right control sequences (captured)"
cap=$(mktemp); exec {FT_TTY}>"$cap"
FT_KEYBOARD_PROTOCOL=kitty; ft_kbd_enable; ft_kbd_disable
grep -qF $'\e[>1u' "$cap" && check "kitty enable = CSI>1u" 1 1 || check "kitty enable = CSI>1u" 0 1
grep -qF $'\e[<u'  "$cap" && check "kitty disable = CSI<u" 1 1 || check "kitty disable = CSI<u" 0 1
: > "$cap"; FT_KEYBOARD_PROTOCOL=xterm; ft_kbd_enable; ft_kbd_disable
grep -qF $'\e[>4;2m' "$cap" && check "xterm enable = CSI>4;2m" 1 1 || check "xterm enable = CSI>4;2m" 0 1
grep -qF $'\e[>4;0m' "$cap" && check "xterm disable = CSI>4;0m" 1 1 || check "xterm disable = CSI>4;0m" 0 1
exec {FT_TTY}>/dev/null; rm -f "$cap"

note "FT_KBD_FORCE override wins over detection"
( FT_KBD_FORCE=off;   ft_kbd_negotiate; [[ "$FT_KEYBOARD_PROTOCOL" == legacy ]] ) && check "FORCE=off → legacy" 1 1 || check "FORCE=off → legacy" 0 1
( FT_KBD_FORCE=xterm; ft_kbd_negotiate; [[ "$FT_KEYBOARD_PROTOCOL" == xterm ]] ) && check "FORCE=xterm → xterm" 1 1 || check "FORCE=xterm → xterm" 0 1

summary
