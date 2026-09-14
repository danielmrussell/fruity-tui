#!/usr/bin/env bash
# What does one terminal-size probe cost, and is there a fork-free way to get it?
# ft_term_size runs on SIGWINCH only — never per frame — so this is about how a RESIZE
# DRAG feels (which fires a stream of WINCHes), not about steady-state lag.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

iterations=${1:-200}
now_microseconds() { local stamp=${EPOCHREALTIME/./}; printf '%s' "$stamp"; }

report() { printf '  %-42s %7d µs each\n' "$1" "$(( ($3 - $2) / iterations ))"; }

started=$(now_microseconds)
for (( i = 0; i < iterations; i++ )); do size=$(stty size </dev/tty 2>/dev/null); done
finished=$(now_microseconds)
report "stty size  (a FORK, what we do today)" "$started" "$finished"

shopt -s checkwinsize
started=$(now_microseconds)
for (( i = 0; i < iterations; i++ )); do rows=${LINES:-24}; columns=${COLUMNS:-80}; done
finished=$(now_microseconds)
report "\$LINES / \$COLUMNS  (no fork)" "$started" "$finished"

echo
echo "  stty says      : ${size:-<none>}"
echo "  LINES/COLUMNS  : ${LINES:-unset} ${COLUMNS:-unset}"
echo
echo "  NB \$LINES/\$COLUMNS are only refreshed by bash after a FOREGROUND COMMAND completes"
echo "  (with checkwinsize). A fork-free event loop runs no such commands, so they can go"
echo "  stale — the dependable fork-free probe is the terminal query \\e[18t, answered with"
echo "  \\e[8;<rows>;<cols>t, read the same way the keyboard protocol is negotiated."
