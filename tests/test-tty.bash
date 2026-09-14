#!/usr/bin/env bash
# Tests for the terminal mode handling in ft-core.bash.
#
# THE BUG THIS GUARDS: a full-screen TUI positions every cell absolutely, but with
# DECAWM (auto-wrap) ON, writing the BOTTOM-RIGHT cell makes the terminal scroll the
# whole screen up one line. The status bar is the only control that paints the FULL
# WIDTH of the LAST row, so it scrolled itself away — the window looked fine and the
# bar was simply gone. It never reproduced in headless tests because those write to a
# FILE, and files don't scroll. ncurses disables auto-wrap for exactly this reason.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init

note "the auto-wrap (DECAWM) control strings exist"
check "FT_ANSI_WRAP_OFF is CSI ?7l" "$FT_ANSI_WRAP_OFF" "$(printf '\e[?7l')"
check "FT_ANSI_WRAP_ON  is CSI ?7h" "$FT_ANSI_WRAP_ON"  "$(printf '\e[?7h')"

# Capture what each tty routine writes to fd 3 without touching a real terminal.
_cap() {                    # fn -> stdout = the bytes it wrote to fd 3
    local fn=$1 tmp; tmp=$(mktemp)
    ( exec 3>"$tmp"; _FT_TERM_ENTERED=1; _FT_RESTORED=0
      FT_DEBUG_NOALT=""; declare -F ft_kbd_negotiate >/dev/null && ft_kbd_negotiate() { :; }
      declare -F ft_kbd_enable >/dev/null && ft_kbd_enable() { :; }
      declare -F ft_kbd_disable >/dev/null && ft_kbd_disable() { :; }
      declare -F ft_wt_autofix_exit >/dev/null && ft_wt_autofix_exit() { :; }
      stty() { :; }; "$fn" >/dev/null 2>&1 ) 2>/dev/null
    cat "$tmp"; rm -f "$tmp"
}

note "entering the tty turns auto-wrap OFF (so a full-width last row can't scroll)"
out=$(_cap ft_resume_tty)
case "$out" in *"$FT_ANSI_WRAP_OFF"*) check "ft_resume_tty disables auto-wrap" 1 1 ;;
               *)                  check "ft_resume_tty disables auto-wrap" 0 1 ;; esac

note "restoring the tty turns auto-wrap back ON (leave the shell as we found it)"
out=$(_cap ft_restore_tty)
case "$out" in *"$FT_ANSI_WRAP_ON"*) check "ft_restore_tty re-enables auto-wrap" 1 1 ;;
               *)                 check "ft_restore_tty re-enables auto-wrap" 0 1 ;; esac

note "the enter path emits wrap-off (source-level guard: it must never be dropped)"
grep -q 'FT_ANSI_WRAP_OFF' "$here/ft-core.bash" && check "ft-core references FT_ANSI_WRAP_OFF" 1 1 || check "ft-core references FT_ANSI_WRAP_OFF" 0 1
n=$(grep -c 'FT_ANSI_WRAP_OFF' "$here/ft-core.bash")
check "wrap-off applied on enter AND resume (>=2 uses + the definition)" "$([[ $n -ge 3 ]] && echo y)" "y"

note "every flush is FLICKER-FREE: atomic (synchronized output) + cursor hidden while it paints"
# The cursor must not skate across the frame as it applies each cell-address (the
# lag-independent "flicker"), and no half-drawn frame may show. ft_flush wraps the
# whole frame in ?2026 (synchronized output) and ?25l (hide cursor).
FT_CARET_FN=""; FT_OUT="CELLS"; out=$( exec {FT_TTY}>/tmp/ftflush.$$; ft_flush; exec {FT_TTY}>&-; cat /tmp/ftflush.$$; rm -f /tmp/ftflush.$$ )
case "$out" in "$FT_ANSI_SYNC_ON"*)            check "frame OPENS with synchronized-output on" 1 1 ;;
               *)                           check "frame OPENS with synchronized-output on" 0 1 ;; esac
case "$out" in *"$FT_ANSI_SYNC_ON$FT_ANSI_CURSOR_HIDE"*) check "...then hides the cursor before painting" 1 1 ;;
               *)                            check "...then hides the cursor before painting" 0 1 ;; esac
case "$out" in *"$FT_ANSI_SYNC_OFF") check "frame CLOSES with synchronized-output off (atomic)" 1 1 ;;
               *)                 check "frame CLOSES with synchronized-output off (atomic)" 0 1 ;; esac

summary
