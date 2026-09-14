#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — ft-inputlayer.bash
#
#  A bidirectional coproc input layer. A producer process reads the tty, decodes
#  bytes into sanitized tokens, applies a caller-set filter, and writes tokens to
#  its stdout. The caller sends declarative control lines to the producer's stdin
#  and consumes tokens via ft_next_event.
#
#  Why a coproc: it lets the decode/sanitation run independently of the draw loop
#  and keeps the messy escape-sequence parsing in one place. ft_next_event reads
#  from a variable fd, so a FIFO event-bus could replace the coproc later without
#  any control needing to change.
#
#  Token protocol (producer → caller), one per line:
#    UP DOWN LEFT RIGHT HOME END PGUP PGDN DEL INS ENTER SPACE TAB BTAB
#    BACKSPACE ESC          — named keys
#    CHAR <hex...>          — a literal char as hex of its 1–4 UTF-8 bytes
#
#  Control protocol (caller → producer), one per line:
#    mode ascii|utf8                    — drop multibyte chars while ascii
#    keys *|<SP-separated tokens>       — which named keys to forward
#    chars all|none|re:<ere>|glob:<pat> — which literal chars to forward
#
#  The producer does only cheap, universal sanitation (drop stray control bytes,
#  invalid/truncated UTF-8, unknown escape sequences) plus this declarative
#  filter. Stateful or expensive validation belongs in the consumer. The filter
#  is best-effort (applied as of the last control line drained before each key),
#  so the consumer must still ignore events meaningless in its current context.
#
#  Depends on: ft-core.bash (for FT_ESC_DELAY only).
# ─────────────────────────────────────────────────────────────────────────────

[[ -n "${_FT_INPUT_LOADED:-}" ]] && return 0
_FT_INPUT_LOADED=1

: "${FT_ESC_DELAY:=0.05}"   # tolerate being sourced before ft-core

# ── Byte/char decoding (runs inside the producer) ────────────────────────────
_FT_CTRL_ALPHA=abcdefghijklmnopqrstuvwxyz   # Ctrl+N → this[N-1]; fork-free lookup
FT_KTOK=""; FT_KARG=""
_ft_decode_char() {            # set FT_KTOK=CHAR / FT_KARG=hex for a 1–4 byte char on fd $1
    local fd=$1 c=$2 code n i b bc hex
    printf -v code '%d' "'$c" 2>/dev/null || return 0
    (( code < 32 )) && return 0                          # stray C0 control → drop
    if   (( code < 128 ));  then FT_KTOK=CHAR; printf -v FT_KARG '%02x' "$code"; return 0
    elif (( code >= 240 )); then n=3
    elif (( code >= 224 )); then n=2
    elif (( code >= 192 )); then n=1
    else return 0; fi                                    # lone continuation → drop
    printf -v hex '%02x' "$code"
    for (( i=0; i<n; i++ )); do
        IFS= read -rsn1 -t "$FT_ESC_DELAY" -u "$fd" b || return 0   # truncated → drop
        printf -v bc '%d' "'$b" 2>/dev/null || return 0
        (( bc >= 128 && bc <= 191 )) || return 0                    # bad continuation → drop
        printf -v hex '%s%02x' "$hex" "$bc"
    done
    FT_KTOK=CHAR; FT_KARG="$hex"
}

_ft_decode_key() {             # read one key from fd $1 → FT_KTOK / FT_KARG ("" if dropped)
    local fd=$1 c nxt seq b
    FT_KTOK=""; FT_KARG=""
    IFS= read -rsn1 -u "$fd" c || return 1
    [[ -z "$c" ]] && { FT_KTOK=ENTER; return 0; }    # read hit its newline delimiter = Enter (LF)
    case "$c" in
        $'\e')
            IFS= read -rsn1 -t "$FT_ESC_DELAY" -u "$fd" nxt
            if [[ -z "$nxt" ]]; then FT_KTOK=ESC; return 0; fi
            if [[ "$nxt" == "[" || "$nxt" == "O" ]]; then
                seq="$nxt"
                while IFS= read -rsn1 -t "$FT_ESC_DELAY" -u "$fd" b; do
                    seq+="$b"; [[ "$b" == [A-Za-z~] ]] && break
                done
                case "$seq" in
                    '[A'|'OA') FT_KTOK=UP ;;     '[B'|'OB') FT_KTOK=DOWN ;;
                    '[C'|'OC') FT_KTOK=RIGHT ;;  '[D'|'OD') FT_KTOK=LEFT ;;
                    '[H'|'OH'|'[1~'|'[7~') FT_KTOK=HOME ;;
                    '[F'|'OF'|'[4~'|'[8~') FT_KTOK=END ;;
                    'OP'|'[11~'|'[[A') FT_KTOK=F1 ;;      # F1 (SS3 / xterm / Linux console)
                    'OQ'|'[12~'|'[[B') FT_KTOK=F2 ;;      # F2 → Settings
                    '[5~') FT_KTOK=PGUP ;;       '[6~') FT_KTOK=PGDN ;;
                    '[3~') FT_KTOK=DEL ;;        '[2~') FT_KTOK=INS ;;
                    '[Z')  FT_KTOK=BTAB ;;
                    # Modified arrows: xterm/CSI form ESC[1;<mod><dir>, where
                    # mod 3=Alt, 5=Ctrl (and 7=Ctrl+Alt). Both Alt+arrow and
                    # Ctrl+arrow are the conventional "move by word" keys, so map
                    # them to ALT+left/right — the same tokens Alt+B/Alt+F already
                    # use — and let a focused field bind them to word motion.
                    '[1;3D'|'[1;5D'|'[1;7D') FT_KTOK="ALT+left"  ;;
                    '[1;3C'|'[1;5C'|'[1;7C') FT_KTOK="ALT+right" ;;
                    '[1;3A'|'[1;5A') FT_KTOK="ALT+up"   ;;
                    '[1;3B'|'[1;5B') FT_KTOK="ALT+down" ;;
                    # Shift+arrow/Home/End (modifier 2) → SHIFT+<dir>, which a
                    # focused control binds to selection-extending motion. Shift+
                    # Ctrl/Alt+←→ (mod 6/4) extend by WORD.
                    '[1;2D') FT_KTOK="SHIFT+left"  ;;   '[1;2C') FT_KTOK="SHIFT+right" ;;
                    # Shift+Up/Down (mod 2) and Ctrl+Shift+Up/Down (mod 6) both
                    # extend the selection a line at a time (Ctrl+Shift+arrows are
                    # a scrollback binding in some terminals — unbind there to use).
                    '[1;2A'|'[1;6A') FT_KTOK="SHIFT+up"    ;;   '[1;2B'|'[1;6B') FT_KTOK="SHIFT+down"  ;;
                    '[1;2H'|'[1;2~') FT_KTOK="SHIFT+home" ;;
                    '[1;2F'|'[4;2~') FT_KTOK="SHIFT+end"  ;;
                    '[1;6D'|'[1;4D') FT_KTOK="SHIFT+ALT+left"  ;;
                    '[1;6C'|'[1;4C') FT_KTOK="SHIFT+ALT+right" ;;
                    # Ctrl+Home/End (mod 5) — and Alt+Home/End (mod 3), same intent
                    # — jump to the very start/end of a text field's document. The
                    # Shift variants (mod 6/4) extend the selection there. Both the
                    # cursor-key form (…H/…F) and the tilde form (Home=1~, End=4~)
                    # are accepted, since terminals split on which they emit.
                    '[1;5H'|'[1;3H'|'[1;5~'|'[1;3~') FT_KTOK="CTRL+home" ;;
                    '[1;5F'|'[1;3F'|'[4;5~'|'[4;3~') FT_KTOK="CTRL+end"  ;;
                    '[1;6H'|'[1;4H'|'[1;6~'|'[1;4~') FT_KTOK="SHIFT+CTRL+home" ;;
                    '[1;6F'|'[1;4F'|'[4;6~'|'[4;4~') FT_KTOK="SHIFT+CTRL+end"  ;;
                    # Enhanced keyboard protocols (negotiated in ft-keyboard.bash):
                    # xterm modifyOtherKeys  \e[27;mods;code~  and  kitty  \e[code;mods u.
                    # These carry keys legacy encoding can't (Ctrl+Space, Shift+Enter…);
                    # the decoders normalise them into the same token vocabulary.
                    '[27;'*'~') _ft_kbd_decode_xterm "$seq" ;;
                    '['*u)      _ft_kbd_decode_kitty "$seq" ;;
                    '[<'*)                               # SGR mouse: \e[<b;x;y(M|m)
                        local mbody=${seq:2} mfin=${seq: -1} moldifs=$IFS
                        mbody=${mbody%[Mm]}; IFS=';'; local -a mp=($mbody); IFS=$moldifs
                        FT_KTOK="MOUSE ${mp[0]:-0} ${mp[1]:-1} ${mp[2]:-1} $mfin" ;;
                    '[200~')                             # bracketed paste: gather to \e[201~
                        local pb="" pc phex="" pcode pi
                        while IFS= read -rsn1 -t 2 -u "$fd" pc; do
                            pb+="$pc"
                            [[ "${pb: -6}" == $'\e[201~' ]] && { pb=${pb%$'\e[201~'}; break; }
                        done
                        for (( pi=0; pi<${#pb}; pi++ )); do
                            printf -v pcode '%d' "'${pb:pi:1}" 2>/dev/null || pcode=0
                            printf -v phex '%s%02x' "$phex" "$pcode"
                        done
                        FT_KTOK=PASTE; FT_KARG="$phex" ;;
                    *)     : ;;                          # unknown → sanitized away
                esac
                return 0
            fi
            # ESC + a letter (within the delay) is Meta/Alt+<letter> — readline's
            # word motions (Alt+B/F/D). Emit an ALT+<letter> token so it reaches
            # a focused field instead of the bare ESC leaking to the form's quit.
            if [[ "$nxt" == [A-Za-z] ]]; then FT_KTOK="ALT+${nxt,,}"; return 0; fi
            # Emacs beginning/end-of-buffer: M-< and M-> (ESC then < or >).
            if [[ "$nxt" == '<' || "$nxt" == '>' ]]; then FT_KTOK="ALT+$nxt"; return 0; fi
            FT_KTOK=ESC; return 0                        # ESC + other byte → ESC
            ;;
        $'\n'|$'\r')   FT_KTOK=ENTER ;;
        ' ')           FT_KTOK=SPACE ;;
        $'\t')         FT_KTOK=TAB ;;
        $'\x7f'|$'\b') FT_KTOK=BACKSPACE ;;
        *)  # A remaining C0 control byte (Ctrl+A..Ctrl+Z, minus the ones named
            # above) becomes a CTRL+<letter> token so readline-style bindings
            # (Ctrl+A/E/K/U/W/F/B/D) can reach a focused text field; anything
            # else is decoded as a literal character.
            local _cc
            printf -v _cc '%d' "'$c" 2>/dev/null || _cc=0
            if (( _cc >= 1 && _cc <= 26 )); then
                FT_KTOK="CTRL+${_FT_CTRL_ALPHA:_cc-1:1}"   # no fork: index a-z
            elif (( _cc == 31 )); then
                # 0x1f is what Ctrl+/ (and Ctrl+_) send — the classic emacs/readline
                # UNDO key. Named so a field can bind it; otherwise it would be lost
                # to the C0 drop below. (Ctrl+Z is unavailable: isig keeps it = suspend.)
                FT_KTOK="CTRL+/"
            else
                _ft_decode_char "$fd" "$c"
            fi ;;
    esac
    return 0
}

# ── Producer-side filter state ───────────────────────────────────────────────
FT_FMODE=utf8; FT_FKEYS='*'; FT_FCMATCH=all; FT_FCPAT=''
_ft_apply_ctl() {              # parse one control line into the filter state
    local -; set -f            # no globbing while splitting (patterns contain * [ ])
    set -- $1
    case "$1" in
        mode)  [[ "$2" == ascii || "$2" == utf8 ]] && FT_FMODE="$2" ;;
        keys)  shift; FT_FKEYS="${*:-*}" ;;
        chars) case "$2" in
                   all|none) FT_FCMATCH="$2"; FT_FCPAT="" ;;
                   re:*)     FT_FCMATCH=re;   FT_FCPAT="${2#re:}" ;;
                   glob:*)   FT_FCMATCH=glob; FT_FCPAT="${2#glob:}" ;;
               esac ;;
    esac
}

_ft_filter_ok() {              # 0 if (FT_KTOK,FT_KARG) passes the current filter
    if [[ "$FT_KTOK" == CHAR ]]; then
        [[ "$FT_FMODE" == ascii && ${#FT_KARG} -gt 2 ]] && return 1
        case "$FT_FCMATCH" in
            all)  return 0 ;;
            none) return 1 ;;
            re|glob)
                local fmt="" i ch
                for (( i=0; i<${#FT_KARG}; i+=2 )); do fmt+="\\x${FT_KARG:i:2}"; done
                printf -v ch "$fmt"
                [[ "$FT_FCMATCH" == re ]] && { [[ "$ch" =~ $FT_FCPAT ]]; return; }
                [[ "$ch" == $FT_FCPAT ]]; return ;;     # glob (set -f doesn't affect [[==]])
        esac
    fi
    [[ "$FT_FKEYS" == '*' || " $FT_FKEYS " == *" $FT_KTOK "* ]]
}

_ft_input_producer() {
    trap 'exit 0' TERM INT HUP
    trap '' WINCH
    export LC_ALL=C; set -f
    exec 5</dev/tty 2>/dev/null || exit 0       # keys come from the tty (fd 5)
    FT_FMODE=utf8; FT_FKEYS='*'; FT_FCMATCH=all; FT_FCPAT=''
    local ctl
    while _ft_decode_key 5; do
        while IFS= read -r -t 0.001 ctl <&0; do _ft_apply_ctl "$ctl"; done   # drain control
        [[ -z "$FT_KTOK" ]] && continue
        if _ft_filter_ok; then
            # CHAR and PASTE carry a hex payload (the char / the pasted bytes);
            # every other token is emitted bare.
            [[ -n "$FT_KARG" ]] && printf '%s %s\n' "$FT_KTOK" "$FT_KARG" || printf '%s\n' "$FT_KTOK"
        fi
    done
}

# ── Caller side ──────────────────────────────────────────────────────────────
FT_IN_RFD=""; FT_IN_WFD=""; FT_INPUT_PID=""
ft_start_input() {
    coproc FT_INPUT { _ft_input_producer; }
    FT_IN_RFD=${FT_INPUT[0]}; FT_IN_WFD=${FT_INPUT[1]}; FT_INPUT_PID=$FT_INPUT_PID
}
ft_input_ctl() { [[ -n "$FT_IN_WFD" ]] && printf '%s\n' "$*" >&"$FT_IN_WFD" 2>/dev/null; }
ft_stop_input() {
    [[ -n "$FT_INPUT_PID" ]] && kill "$FT_INPUT_PID" 2>/dev/null
    [[ -n "$FT_IN_RFD" ]] && eval "exec ${FT_IN_RFD}<&- ${FT_IN_WFD}>&-" 2>/dev/null
    FT_IN_RFD=""; FT_IN_WFD=""; FT_INPUT_PID=""
}

# ft_next_event: block (with a short poll) for the next event.
# Returns: 0 = event ready (FT_EVENT_TOKEN / FT_EVENT_CHAR set), 2 = resize pending,
#          1 = producer gone. Polls so SIGWINCH is acted on promptly even where
#          it doesn't interrupt the blocked read.
FT_EVENT=""; FT_EVENT_TOKEN=""; FT_EVENT_CHAR=""; FT_PASTE=""
# Split FT_EVENT into FT_EVENT_TOKEN + (for CHAR/PASTE) the decoded hex payload in
# FT_EVENT_CHAR; a PASTE's text is also parked in FT_PASTE for ft_textfield_paste to read.
_ft_ev_split() {
    FT_EVENT_TOKEN="${FT_EVENT%% *}"; FT_EVENT_CHAR=""
    if [[ "$FT_EVENT_TOKEN" == CHAR || "$FT_EVENT_TOKEN" == PASTE ]]; then
        local hex="${FT_EVENT#* }" fmt="" i
        for (( i=0; i<${#hex}; i+=2 )); do fmt+="\\x${hex:i:2}"; done
        printf -v FT_EVENT_CHAR "$fmt"            # reassembled in the parent's UTF-8 locale
        [[ "$FT_EVENT_TOKEN" == PASTE ]] && FT_PASTE="$FT_EVENT_CHAR"
    elif [[ "$FT_EVENT_TOKEN" == MOUSE ]]; then         # "MOUSE b x y act"
        local -a mf=($FT_EVENT)
        FT_MOUSE_BUTTON=${mf[1]:-0}; FT_MOUSE_X=${mf[2]:-1}; FT_MOUSE_Y=${mf[3]:-1}; FT_MOUSE_ACTION=${mf[4]:-M}
    fi
}
ft_next_event() {
    local rc poll
    # PAY WHAT THE LAST FRAME PUT OFF, then go to sleep on input. A callout's placement search
    # prices ~1000 candidate boxes and routes a leader for each finalist — measured at 560 ms of
    # a 687 ms keypress on demo/callout-demo.bash page 4, inside the settle for that one key. The
    # page is correct without the callout, so the settle hands the frame over (see
    # FT_BEACON_PENDING) and the bill comes due here, with the new page already on the screen.
    #
    # HERE RATHER THAN IN ft-run's LOOP, because ft-run's is one of FOUR: Help, Settings and the
    # file dialog each run their own, and a callout raised inside one of those would have owed a
    # search nobody ever paid. Every loop in the framework goes through this function. (Same
    # `declare -F` shape as the ft_anim_step call below — the input layer knows nothing about
    # beacons and must keep working when ft-beacon.bash is not loaded.)
    #
    # BEFORE the read, not after it, and that is a correctness property rather than a preference:
    # a deferred callout has no box yet, and _ft_beacon_hit_at answers from the box. Paying the
    # debt here means no click is ever tested against a placement that is about to change.
    declare -F ft_beacon_drain_placements >/dev/null && ft_beacon_drain_placements
    while true; do
        # Poll lazily (0.25s) when idle; tighten to the frame interval only WHILE
        # something animates. A real keystroke wins this read immediately either way,
        # so animating never adds input latency — it just fills the dead time.
        poll=0.25
        (( ${FT_ANIM_ACTIVE:-0} )) && poll=${FT_ANIM_INTERVAL:-0.05}
        IFS= read -r -t "$poll" -u "$FT_IN_RFD" FT_EVENT; rc=$?
        if (( rc == 0 )); then ft_now_ms; FT_LAST_INPUT_MS=$FT_RET; _ft_ev_split; return 0; fi
        (( ${FT_WINCH:-0} )) && return 2
        if (( rc > 128 )); then             # timeout / non-WINCH signal → keep waiting
            (( ${FT_ANIM_ACTIVE:-0} )) && declare -F ft_anim_step >/dev/null && ft_anim_step
            continue
        fi
        return 1                            # EOF / error → producer gone
    done
}

# ft_poll_event: NON-blocking single read (tiny timeout). Returns 0 with
# FT_EVENT_TOKEN/FT_EVENT_CHAR set if an event was immediately available, 1 if not. Used
# by the run loop to COALESCE a burst of held-key input into one redraw:
# process every queued event, but paint only once at the end.
: "${FT_COALESCE_WINDOW:=0.005}"  # near-zero: only DRAIN input that's ALREADY
                                  # queued (a burst, a paste, or events that
                                  # arrived while the last paint ran), then
                                  # settle. It is NOT a wait — a lone keypress
                                  # is not stalled for a follow-up, so typing
                                  # and cursor motion feel instant. Held keys
                                  # self-coalesce: events pile up during a paint
                                  # and get drained in the next pass.
ft_poll_event() {
    IFS= read -r -t "$FT_COALESCE_WINDOW" -u "$FT_IN_RFD" FT_EVENT || return 1
    _ft_ev_split
    return 0
}
