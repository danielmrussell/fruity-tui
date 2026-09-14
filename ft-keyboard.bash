#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — ft-keyboard.bash   (terminal keyboard-protocol negotiation)
#
#  Ordinary terminal input can't represent some keys a GUI takes for granted —
#  Ctrl+Space is NUL (bash drops it), Shift+Enter is invisible, etc. Modern
#  terminals fix this with an ENHANCED keyboard protocol that reports such keys as
#  escape sequences. Two matter, and no terminal speaks both, so we negotiate:
#
#     • kitty keyboard protocol   \e[c;mods u            (kitty, foot, WezTerm,
#                                                          Ghostty, WT 1.22+, iTerm2)
#     • xterm modifyOtherKeys     \e[27;mods;c~          (xterm, VTE/gnome, konsole)
#
#  Both collapse to (codepoint, modifier-mask) → one normalized token, so the rest
#  of the input layer and every keymap stay protocol-agnostic. Legacy patterns are
#  still matched FIRST in the decoder (the fast path); only the enhanced forms fall
#  through to here. The only added cost is a one-time startup handshake — nothing
#  per-keystroke. Enabling also disambiguates Esc, so the ESC-timeout guess can be
#  skipped where the protocol is active (a snappiness win).
#
#  Depends on ft-core (FT_TTY). No forks on the decode path.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_KBD_LOADED:-}" ]] && return 0
_FT_KBD_LOADED=1

FT_KEYBOARD_PROTOCOL=legacy         # negotiated: legacy | kitty | xterm
FT_KBD_ACTIVE=0             # 1 once we've enabled a protocol on the tty
FT_KBD_FORCE="${FT_KBD_FORCE:-}"   # user override: kitty|xterm|legacy|off (env)
# kitty "progressive enhancement" flags to push (bit 1 disambiguate, 2 event
# types, 8 report-all-keys). Flag 8 is "full takeover" — the terminal forwards
# even its OWN shortcuts (e.g. WT's Ctrl+Shift+Home scrollback) instead of acting
# on them, so no settings.json edit is needed. Default is 1 (safe: Ctrl+Space,
# unambiguous Esc; plain keys unchanged). Apps opt into takeover via this var.
FT_KBD_KITTY_FLAGS="${FT_KBD_KITTY_FLAGS:-1}"

# Printable-ASCII lookup (index cp-32) so a codepoint→char never forks on decode.
# BUILDING it must not fork either, which it did — 95 times, once per character, because the
# octal escape was made with a command substitution inside the loop. That is 85ms on EVERY
# app start (measured; the fork-free form is 1ms) spent by the very table whose reason for
# existing is to avoid forking. printf -v twice costs nothing and stays in-process.
_FT_KBD_ASCII=""
_ft_kbd_build_ascii() {
    local i o c
    for (( i=32; i<127; i++ )); do
        printf -v o '%03o' "$i"
        printf -v c '%b' "\\$o"
        _FT_KBD_ASCII+=$c
    done
}
_ft_kbd_build_ascii

# Codepoint → UTF-8 hex (pure arithmetic; used for CHAR tokens).
_ft_kbd_utf8() {                # codepoint → FT_RET (hex bytes)
    local cp=$1
    if   (( cp < 0x80 ));  then printf -v FT_RET '%02x' "$cp"
    elif (( cp < 0x800 )); then printf -v FT_RET '%02x%02x' $(( 0xC0 | cp>>6 )) $(( 0x80 | cp&0x3F ))
    elif (( cp < 0x10000 ));then printf -v FT_RET '%02x%02x%02x' $(( 0xE0 | cp>>12 )) $(( 0x80 | cp>>6&0x3F )) $(( 0x80 | cp&0x3F ))
    else printf -v FT_RET '%02x%02x%02x%02x' $(( 0xF0 | cp>>18 )) $(( 0x80 | cp>>12&0x3F )) $(( 0x80 | cp>>6&0x3F )) $(( 0x80 | cp&0x3F )); fi
}

# ── The normalizer: (codepoint, modmask) → FT_KTOK / FT_KARG ──────────────────
# modmask bits: 1=Shift 2=Alt 4=Ctrl 8=Super…  (i.e. the protocol's mod-1). Emits
# the SAME token vocabulary the legacy decoder uses, so nothing downstream cares
# which protocol produced it.
_ft_kbd_token() {               # codepoint modmask
    local cp=$1 mm=$2
    local ctrl=$(( (mm & 4) != 0 )) alt=$(( (mm & 2) != 0 )) shift=$(( (mm & 1) != 0 ))
    FT_KTOK=""; FT_KARG=""
    case $cp in
        27)  FT_KTOK=ESC;       return 0 ;;
        13)  FT_KTOK=ENTER;     return 0 ;;
        9)   (( shift )) && FT_KTOK=BTAB || FT_KTOK=TAB; return 0 ;;
        127|8) FT_KTOK=BACKSPACE; return 0 ;;
        32|0|64)                                 # Space / Ctrl+@ (both NUL-ish)
            if   (( ctrl )); then FT_KTOK="CTRL+SPACE"
            elif (( alt ));  then FT_KTOK="ALT+space"
            elif (( cp == 32 )); then FT_KTOK=SPACE
            else FT_KTOK="CTRL+SPACE"; fi
            return 0 ;;
    esac
    if (( cp >= 97 && cp <= 122 )); then         # a–z
        local ch=${_FT_KBD_ASCII:cp-32:1}
        if   (( ctrl )); then FT_KTOK="CTRL+$ch"
        elif (( alt ));  then FT_KTOK="ALT+$ch"
        elif (( shift )); then FT_KTOK=CHAR; printf -v FT_KARG '%02x' $(( cp - 32 ))   # → A–Z
        else FT_KTOK=CHAR; printf -v FT_KARG '%02x' "$cp"; fi
        return 0
    fi
    if (( cp >= 33 && cp <= 126 )); then         # other printable ASCII
        local ch=${_FT_KBD_ASCII:cp-32:1}
        if   (( ctrl )); then FT_KTOK="CTRL+$ch"
        elif (( alt ));  then FT_KTOK="ALT+$ch"
        else FT_KTOK=CHAR; printf -v FT_KARG '%02x' "$cp"; fi
        return 0
    fi
    # kitty reports functional keys and even bare modifier-key presses (Shift,
    # Ctrl, …) using codepoints in the Private Use Area (0xE000–0xF8FF). We already
    # get nav/function keys via their legacy CSI forms, so drop these — otherwise a
    # lone Shift press (seen under flag 8 / event-type modes) would render as a
    # garbage character. (e.g. 0xE061 Left-Shift, 0xE062 Left-Control.)
    if (( cp >= 0xE000 && cp <= 0xF8FF )); then FT_KTOK=""; return 0; fi
    # Genuine non-ASCII text → a plain character (attach as UTF-8 hex).
    if (( cp > 126 )); then _ft_kbd_utf8 "$cp"; FT_KTOK=CHAR; FT_KARG=$FT_RET; return 0; fi
    return 0                                       # unmapped control cp → dropped
}

# ── Protocol decoders (called from the input layer for enhanced sequences) ────
# kitty:  \e[ code[:alt] ; mods[:event] [; text] u   — seq is WITHOUT the leading ESC.
_ft_kbd_decode_kitty() {        # seq (e.g. "[32;5u") → FT_KTOK/FT_KARG
    local body=${1#\[}; body=${body%u}
    local oIFS=$IFS; IFS=';'; local -a f=($body); IFS=$oIFS
    local cp=${f[0]%%:*}; [[ -z "$cp" ]] && cp=0
    local modev=${f[1]:-1} mod ev
    mod=${modev%%:*}; ev=${modev#*:}; [[ "$ev" == "$modev" ]] && ev=1
    (( ev == 3 )) && { FT_KTOK=""; return 0; }     # key-release → ignore
    [[ $cp == *[!0-9]* || $mod == *[!0-9]* ]] && { FT_KTOK=""; return 0; }
    _ft_kbd_token "$cp" $(( mod>0 ? mod-1 : 0 ))
}
# xterm modifyOtherKeys:  \e[ 27 ; mods ; code ~
_ft_kbd_decode_xterm() {        # seq (e.g. "[27;5;32~") → FT_KTOK/FT_KARG
    local body=${1#\[}; body=${body%\~}
    local oIFS=$IFS; IFS=';'; local -a f=($body); IFS=$oIFS
    local mod=${f[1]:-1} cp=${f[2]:-0}
    [[ $cp == *[!0-9]* || $mod == *[!0-9]* ]] && { FT_KTOK=""; return 0; }
    _ft_kbd_token "$cp" $(( mod>0 ? mod-1 : 0 ))
}

# ── Negotiation ──────────────────────────────────────────────────────────────
# _ft_kbd_from_env → FT_RET: a protocol guess from environment alone (no I/O), so
# it is unit-testable and also the fallback when the query round-trip is unreliable.
_ft_kbd_from_env() {
    local term=${TERM:-} prog=${TERM_PROGRAM:-}
    if   [[ -n "${KITTY_WINDOW_ID:-}" || "$term" == *kitty* || "$term" == foot* || "$term" == ghostty* ]]; then FT_RET=kitty
    elif [[ "$prog" == WezTerm || "$prog" == ghostty || "$prog" == iTerm.app || "$prog" == rio ]]; then FT_RET=kitty
    elif [[ -n "${WT_SESSION:-}" ]]; then FT_RET=kitty          # WT ≥1.22 speaks kitty; older ignores the enable
    elif [[ -n "${VTE_VERSION:-}" ]]; then FT_RET=xterm         # gnome-terminal, Tilix, …
    elif [[ "$prog" == vscode ]]; then FT_RET=xterm
    elif [[ "$term" == xterm* || "$term" == screen* || "$term" == tmux* ]]; then FT_RET=xterm
    else FT_RET=legacy; fi
}

# Ask the terminal directly: send the kitty flags query + DA1, read the reply with
# a short bound. A kitty-capable terminal answers "\e[?<flags>u" before the DA1;
# everyone answers DA1. Runs ONCE, before the input coproc starts. Best-effort:
# any hiccup falls back to the env guess.
_ft_kbd_query() {               # → FT_RET: kitty | "" (unknown)
    FT_RET=""
    [[ -z "${FT_TTY:-}" ]] && return 1
    printf '\e[?u\e[c' >&"$FT_TTY" 2>/dev/null || return 1
    local reply="" ch
    while IFS= read -rsn1 -t 0.2 -u "$FT_TTY" ch; do
        reply+=$ch
        [[ "$ch" == c ]] && break                  # DA1 terminator → done
        (( ${#reply} > 64 )) && break
    done
    [[ "$reply" == *$'\e['\?*u* ]] && FT_RET=kitty
    return 0
}

# ft_kbd_negotiate — decide FT_KEYBOARD_PROTOCOL (query wins; else env; honor FT_KBD_FORCE).
ft_kbd_negotiate() {
    case "$FT_KBD_FORCE" in
        off|legacy) FT_KEYBOARD_PROTOCOL=legacy; return 0 ;;
        kitty|xterm) FT_KEYBOARD_PROTOCOL=$FT_KBD_FORCE; return 0 ;;
    esac
    _ft_kbd_query
    if [[ "$FT_RET" == kitty ]]; then FT_KEYBOARD_PROTOCOL=kitty; return 0; fi
    _ft_kbd_from_env; FT_KEYBOARD_PROTOCOL=$FT_RET
    return 0
}

# ── Enable / disable on the tty (paired; disable is idempotent-safe) ──────────
ft_kbd_enable() {
    [[ -z "${FT_TTY:-}" ]] && return 0
    case $FT_KEYBOARD_PROTOCOL in
        kitty) printf '\e[>%su' "$FT_KBD_KITTY_FLAGS" >&"$FT_TTY" 2>/dev/null; FT_KBD_ACTIVE=1 ;;
        xterm) printf '\e[>4;2m' >&"$FT_TTY" 2>/dev/null; FT_KBD_ACTIVE=1 ;; # modifyOtherKeys=2
        *) FT_KBD_ACTIVE=0 ;;
    esac
}
ft_kbd_disable() {
    [[ -z "${FT_TTY:-}" ]] && return 0
    case $FT_KEYBOARD_PROTOCOL in
        kitty) printf '\e[<u' >&"$FT_TTY" 2>/dev/null ;;                     # pop
        xterm) printf '\e[>4;0m' >&"$FT_TTY" 2>/dev/null ;;                  # modifyOtherKeys off
    esac
    FT_KBD_ACTIVE=0
}

# ft_kbd_summary → FT_RET: one-line status for the Settings page.
ft_kbd_summary() {
    case $FT_KEYBOARD_PROTOCOL in
        kitty) FT_RET="kitty keyboard protocol (full modified-key fidelity)" ;;
        xterm) FT_RET="xterm modifyOtherKeys (modified-key fidelity)" ;;
        *)     FT_RET="legacy (some modified keys, e.g. Ctrl+Space, unavailable)" ;;
    esac
}
