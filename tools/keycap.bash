#!/usr/bin/env bash
# keycap.bash — show the exact bytes your terminal sends for a key, the enhanced
# keyboard protocol it negotiates, and how our decoder classifies it. Press q to quit.
#
#   bash tools/keycap.bash              # default protocol (disambiguate: gets Ctrl+Space)
#   bash tools/keycap.bash --takeover   # kitty "report all keys" (flag 8) — ask the
#                                        #   terminal to forward its OWN shortcuts too,
#                                        #   e.g. WT's Ctrl+Shift+Home. Test if it works!
#   bash tools/keycap.bash --raw        # legacy only, no protocol (see the bare bytes)
#
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/fruity-tui.bash"          # brings in ft_kbd_* AND _ft_decode_key

mode=${1:-}
exec {TFD}<>/dev/tty || { echo "cannot open /dev/tty"; exit 1; }
FT_TTY=$TFD
old=$(stty -g <&"$TFD")
cleanup() { [[ "$mode" != --raw ]] && ft_kbd_disable; stty "$old" <&"$TFD" 2>/dev/null; printf '\n'; }
# EXIT does the cleanup; INT/TERM must EXIT (not just run the handler and resume,
# which is what made this need `kill -9` before). Now `kill <pid>` stops it cleanly.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
stty -icanon -echo min 1 time 0 <&"$TFD"

case "$mode" in
    --raw)
        FT_KEYBOARD_PROTOCOL=legacy
        printf 'keycap (legacy/raw — no protocol). Press q to quit.\n\n' ;;
    --takeover)
        FT_KBD_KITTY_FLAGS=9            # 1 disambiguate + 8 report-all-keys (full takeover)
        ft_kbd_negotiate; ft_kbd_enable; ft_kbd_summary
        printf 'keycap TAKEOVER — protocol: \e[1m%s\e[22m flags=%s  (%s)\n' "$FT_KEYBOARD_PROTOCOL" "$FT_KBD_KITTY_FLAGS" "$FT_RET"
        printf 'Now press \e[1mCtrl+Shift+Home\e[22m — if it prints bytes here instead of\n'
        printf 'scrolling, the terminal released it and we need NO settings edit. Press q.\n\n' ;;
    *)
        ft_kbd_negotiate; ft_kbd_enable; ft_kbd_summary
        printf 'keycap — protocol: \e[1m%s\e[22m flags=%s  (%s)\n' "$FT_KEYBOARD_PROTOCOL" "$FT_KBD_KITTY_FLAGS" "$FT_RET"
        printf 'Try Ctrl+Space, Shift+Enter, Ctrl+Shift+Home. Press q to quit.\n\n' ;;
esac

printf '(quit with Ctrl+C — works even in takeover mode, where it is forwarded not signalled)\n\n'
while :; do
    IFS= read -rsn1 -u "$TFD" c || break
    seq=$c
    while IFS= read -rsn1 -t 0.02 -u "$TFD" c2; do seq+=$c2; done

    # Decode FIRST so quit works regardless of encoding: in --takeover mode the
    # terminal forwards Ctrl+C as \e[99;5u instead of raising SIGINT, so we catch
    # the decoded CTRL+c token here. (Non-takeover Ctrl+C fires the INT trap.)
    f=$(mktemp); printf '%s' "$seq" > "$f"; exec {r}<"$f"; _ft_decode_key "$r"; exec {r}<&-; rm -f "$f"
    [[ "$FT_KTOK" == "CTRL+c" ]] && break

    printf 'hex:'
    for (( i=0; i<${#seq}; i++ )); do printf ' %02x' "'${seq:i:1}"; done
    read_form=""
    for (( i=0; i<${#seq}; i++ )); do
        ch=${seq:i:1}; printf -v code '%d' "'$ch"
        if   (( code == 27 )); then read_form+='\e'
        elif (( code < 32 ));  then printf -v cc '^%s' "$(printf \\$(printf '%03o' $((code+64))))"; read_form+=$cc
        else read_form+=$ch; fi
    done
    tokshow=$FT_KTOK; [[ "$FT_KTOK" == CHAR ]] && tokshow="CHAR($FT_KARG)"
    printf '    seq: %-18s token: %s\n' "$read_form" "$tokshow"
done
