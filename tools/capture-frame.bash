#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tools/capture-frame.bash — capture EXACTLY what a demo draws, at the size of
#  the terminal you are sitting in, into ONE file you can hand over.
#
#  BATCH form (any number of page:steps entries, steps comma-separated):
#      bash tools/capture-frame.bash callout-demo p3:5 p6:2,5 p7:5
#      bash tools/capture-frame.bash p3:5 p6:2,5          # demo defaults to callout-demo
#  Single-frame form (back-compatible):
#      bash tools/capture-frame.bash callout-demo 2 6
#
#  EVERY requested frame lands in /tmp/frame.txt, each under a ═══ header naming
#  its page, step and size. When it finishes, tell Claude:  read /tmp/frame.txt
#  (that is a message TO CLAUDE, not a shell command — bash's `read` builtin
#  will just error on it.)
#
#  Each frame boots the real app in its own pty and waits out the keyboard-
#  protocol negotiation (~4s) — that cost is real, so the frames all render IN
#  PARALLEL: a six-frame batch takes about as long as one.
#
#  Why this exists: copying from a terminal mangles box-drawing glyphs, eats
#  trailing spaces and adds CRLF; and passing $COLUMNS through `wsl.exe -- bash
#  -c '…'` silently does not work. RUN THIS FROM THE TERMINAL YOU ARE LOOKING
#  AT: it reads the real size off the tty, so the file shows what you see.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=/tmp/frame.txt

demo=callout-demo
declare -a entries=()
declare -a legacy=()
for a in "$@"; do
    case "$a" in
        p[0-9]*:*) entries+=("$a") ;;
        [0-9]*)    legacy+=("$a") ;;
        *)         demo=$a ;;
    esac
done
[[ "$demo" != */* ]] && demo="demo/${demo%.bash}.bash"
[[ -f "$here/$demo" ]] || { printf 'no such demo: %s\n' "$here/$demo" >&2; exit 1; }

# THE SIZE OF THE REAL TERMINAL, read off the tty rather than the environment —
# $COLUMNS is unset in non-interactive shells and `tput` needs a tty too.
if sz=$(stty size 2>/dev/null) && [[ -n "$sz" ]]; then
    rows=${sz% *}; cols=${sz#* }
else
    rows=${LINES:-40}; cols=${COLUMNS:-118}
    printf 'warning: no tty — falling back to %sx%s. Run me from the terminal you are looking at.\n' \
        "$cols" "$rows" >&2
fi

# legacy "PAGE STEP" positionals become one entry
if (( ${#entries[@]} == 0 )); then
    entries=("p${legacy[0]:-1}:${legacy[1]:-1}")
fi

# expand entries → flat "page step" list, order preserved
declare -a flat=()
for e in "${entries[@]}"; do
    page=${e#p}; page=${page%%:*}
    steps=${e#*:}
    IFS=',' read -r -a steplist <<< "$steps"
    for step in "${steplist[@]}"; do flat+=("$page $step"); done
done

printf 'capturing %s frame(s) of %s at %sx%s (in parallel — allow ~10s)…\n' \
    "${#flat[@]}" "${demo##*/}" "$cols" "$rows" >&2
declare -a pids=() parts=()
i=0
for ps in "${flat[@]}"; do
    set -- $ps
    part="/tmp/.frame-part-$$-$i"
    parts+=("$part")
    {
        printf '═══════════ %s — page %s, step %s — %sx%s ═══════════\n' \
            "${demo##*/}" "$1" "$2" "$cols" "$rows"
        FT_TEST_COLS=$cols FT_TEST_ROWS=$rows DEMO_PAGE=$1 DEMO_STEP=$2 \
            python3 "$here/tests/render-screen.py" "$here/$demo" "" 2>/dev/null
        printf '\n'
    } > "$part" &
    pids+=($!)
    (( i++ ))
done
for p in "${pids[@]}"; do wait "$p"; done
cat "${parts[@]}" > "$out"
rm -f "${parts[@]}"

frames=$(grep -c '═══════════' "$out")
if [[ -s "$out" ]] && (( frames == ${#flat[@]} )); then
    printf 'wrote %s frame(s) to %s\n' "$frames" "$out" >&2
    printf 'now tell Claude:  read /tmp/frame.txt   (a message to Claude, NOT a shell command)\n' >&2
else
    printf 'expected %s frames, wrote %s — is python3 present?\n' "${#flat[@]}" "$frames" >&2
    exit 1
fi
