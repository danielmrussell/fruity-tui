#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — tools/bench-display-scan.bash
#
#  The three scans that read a string a column at a time — ft_display_width,
#  ft_display_truncate, ft_display_index — priced side by side on ONE corpus.
#
#  They exist to be compared. All three are loops around ft_char_cols over the
#  same characters, differing only in what they hand back: a count, a prefix, an
#  index. So when one of them is taught a shortcut and the others are not, this
#  is where it shows: the same string, the same width, three very different
#  numbers. That is exactly how the per-character ft_display_truncate was found
#  sitting beside a wholesale ft_display_width.
#
#      bash tools/bench-display-scan.bash [iterations]     # the primitives
#      bash tools/bench-display-scan.bash scene            # a repaint that uses them
#
#  `scene` is the other half of the question. A primitive measured in a loop is
#  a number without a denominator; the scene builds an ordinary app — a table of
#  18 rows whose paths are wider than their column, and a label wider than its
#  box — counts how many times a single repaint reaches for ft_display_truncate,
#  and times the repaint. Both halves are needed: the first says what a call
#  costs, the second says whether anything makes the call.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

microseconds() { local stamp=${EPOCHREALTIME/./}; printf '%s' "$stamp"; }

# ── scene mode ───────────────────────────────────────────────────────────────
if [[ "${1:-}" == scene ]]; then
    export FT_NO_WTFIX=1 FT_COLOR_MODE=256
    source fruity-tui.bash >/dev/null 2>&1
    ft_init >/dev/null 2>&1
    exec {FT_TTY}>/dev/null
    FT_ROWS=40; FT_COLS=100

    ft-form name=app width=100 height=40 display=flex flexDirection=column
      ft-label name=hdr width=40 \
        text="A dashboard line whose text is comfortably longer than the box the layout gives it"
      ft-frame name=win title="Servers" flexGrow=1 minHeight=0 overflow=hidden
        ft-table name=tbl width=60 variant=grid striped=true
            ft-table-header "Host"; ft-table-header "State"
            ft-table-header "Path"; ft-table-header "Seen"
            for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
                ft-table-row "srv-$i.internal" "running" \
                    "/var/lib/very/long/path/that/does/not/fit/in/its/column/$i" \
                    "2026-09-0$(( i % 9 + 1 )) 11:2$(( i % 9 ))"
            done
        end_ft_table
      end_ft_frame
    end_ft_form

    FT_ROOT=app
    ft_layout app >/dev/null 2>&1
    # API-EXCEPTION: this tool MEASURES the repaint pipeline, so driving it is the
    # subject, not scaffolding.
    ft_dirty_subtree app; ft_redraw_dirty >/dev/null 2>&1        # warm

    calls=0
    eval "_unmetered_display_truncate() $(declare -f ft_display_truncate | tail -n +2)"
    metering=0
    ft_display_truncate() { (( metering )) && (( calls++ )); _unmetered_display_truncate "$@"; }

    metering=1; ft_dirty_subtree app; ft_redraw_dirty >/dev/null 2>&1; metering=0
    printf '  ft_display_truncate calls in ONE full repaint : %d\n' "$calls"
    # If nothing reaches the primitive the timing below is measuring something
    # else entirely, and the scene needs rebuilding rather than reporting.
    (( calls > 0 )) || { echo "  SCENE IS VACUOUS: nothing truncated"; exit 2; }

    runs=5; started=$(microseconds)
    for (( k=0; k<runs; k++ )); do ft_dirty_subtree app; ft_redraw_dirty >/dev/null 2>&1; done
    finished=$(microseconds)
    printf '  %d warm full repaints                         : %d ms (%d ms each)\n' \
        "$runs" $(( (finished - started) / 1000 )) $(( (finished - started) / 1000 / runs ))
    exit 0
fi

# ── primitive mode ───────────────────────────────────────────────────────────
source fruity-tui.bash >/dev/null 2>&1
iterations=${1:-400}

# The corpus is one entry per SHAPE the scans branch on, not a spread of sizes:
# pure ASCII, ASCII wrapped in one SGR, many short SGR runs, prose carrying a
# single non-ASCII character, and text with no ASCII in it at all. A shortcut
# that helps one of these can cost another — taking ASCII runs wholesale is a
# 5× win on prose and was a 1.6× LOSS on the all-CJK line until the non-ASCII
# run was taken wholesale too.
sgr=$'\e[48;5;16;38;5;250m'; reset=$'\e[0m\e[48;5;234;38;5;255m'
plain_row=""; for (( i=0; i<118; i++ )); do plain_row+="x"; done
styled_row="$sgr$plain_row$reset"
many_runs=""; for (( i=0; i<20; i++ )); do many_runs+=$'\e[1;38;5;214m'"F$i"$'\e[0m'" label "; done
prose="The quick brown fox — jumps over the lazy dog, a line of ordinary English prose that is long"
cjk="日本語のテキストが並んでいます。これは全角文字の行です。折り返しの計算に使います。"
cjk_styled="$sgr$cjk$reset"

# The empty-loop floor is subtracted and PRINTED: at these sizes it is a real
# fraction of the smallest result, and a reader who cannot see it cannot tell a
# 60 µs answer from a 60 µs measuring apparatus.
started=$(microseconds); for (( i=0; i<iterations; i++ )); do :; done; finished=$(microseconds)
floor=$(( finished - started ))
printf '  %d iterations; empty-loop floor %d µs total, %d ns each\n\n' \
    "$iterations" "$floor" $(( floor * 1000 / iterations ))

measure() {                     # label fn args...
    local label=$1; shift
    local began ended i
    began=$(microseconds)
    for (( i=0; i<iterations; i++ )); do "$@"; done
    ended=$(microseconds)
    printf '  %-40s %7d µs/call\n' "$label" $(( (ended - began - floor) / iterations ))
}

echo "  — ft_display_width: how many columns is this? —"
measure "118 plain ASCII"             ft_display_width "$plain_row"
measure "118 columns in one SGR"      ft_display_width "$styled_row"
measure "20 short SGR runs"           ft_display_width "$many_runs"
measure "prose, one em-dash"          ft_display_width "$prose"
measure "40 CJK glyphs"               ft_display_width "$cjk"
measure "40 CJK glyphs in one SGR"    ft_display_width "$cjk_styled"

echo
echo "  — ft_display_truncate: the prefix that fits —"
measure "118 plain ASCII → 118"       ft_display_truncate "$plain_row" 118
measure "118 plain ASCII → 60"        ft_display_truncate "$plain_row" 60
measure "118 columns in one SGR → 116" ft_display_truncate "$styled_row" 116
measure "20 short SGR runs → 60"      ft_display_truncate "$many_runs" 60
measure "prose, one em-dash → 60"     ft_display_truncate "$prose" 60
measure "40 CJK glyphs → 30"          ft_display_truncate "$cjk" 30
measure "40 CJK glyphs → 80"          ft_display_truncate "$cjk" 80
measure "40 CJK glyphs in one SGR → 30" ft_display_truncate "$cjk_styled" 30

echo
echo "  — ft_display_index: which character begins at column N? —"
measure "118 plain ASCII @60"         ft_display_index "$plain_row" 60
measure "118 columns in one SGR @116" ft_display_index "$styled_row" 116
measure "20 short SGR runs @60"       ft_display_index "$many_runs" 60
measure "prose, one em-dash @60"      ft_display_index "$prose" 60
measure "40 CJK glyphs @30"           ft_display_index "$cjk" 30

echo
echo "  — the floor a prefix can be taken at, when no column has to be counted —"
bare_slice() { FT_RET=${styled_row:0:60}; }
measure "\${styled_row:0:60}"          bare_slice
