#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — tests/test-displayscan.bash
#
#  ft_display_truncate walks a string and hands back a PREFIX of it. It used to
#  do that one character at a time; it now takes the same wholesale slices
#  ft_display_width takes — a pure-ASCII string in one parameter expansion, an
#  escape sequence in one slice, a run of text in one more. Two things have to
#  hold, and they fail in opposite directions:
#
#    1. THE ANSWERS DID NOT MOVE. Every path is a rewrite of a loop that was
#       correct, so the original body is kept below verbatim and the two are
#       compared over a corpus at EVERY width from -2 to length+2. This is the
#       shape tests/test-charwidth.bash already uses on ft_char_cols, for the
#       same reason: a restructured wall of index arithmetic is invisibly wrong
#       until a column lands in the wrong place.
#
#    2. THE FAST PATHS ARE ACTUALLY TAKEN. An answer that is right and slow
#       passes part 1 completely, and slow is what this change was for — a
#       118-column row cost 2 ms to truncate, and ft_fit reaches for it on every
#       string wider than its box. So the paths are gated on a STATEMENT COUNT
#       from a DEBUG trap rather than a clock: deterministic, no pty, nothing to
#       contend with. On the pre-change code the same three calls counted 833,
#       861 and 441 statements; they now count 7, 34 and 42.
#
#  Watched to fail, by sabotaging the SUBJECT three ways:
#
#    · the pre-change function body restored whole → part 1 still passed every
#      assertion and part 2's four checks all went red (7 steps became 833).
#      That is the old code, and that is the failure this file exists for.
#    · the `max <= 0` guard removed → four assertions red, including the corpus
#      counts, because ${s:0:-1} makes the fast path return nearly everything.
#    · ONLY the pure-ASCII fast path removed → this passed at first, and the
#      threshold below was wrong because of it. The middle path also slices
#      ASCII runs wholesale, so losing the fast path is a small loss, not a
#      cliff: 7 statements become 16 and the call goes 62 µs → 97 µs. The
#      118-column threshold is 12 to sit inside that gap rather than outside it.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source tests/_harness.bash
source fruity-tui.bash

# ── The implementation as it stood before the wholesale slicing, verbatim ─────
# Not a paraphrase and not a simplification: this is the oracle, and an oracle
# that was tidied on the way in proves nothing about the code that replaced it.
_ref_display_truncate() {
    local s=$1 max=$2 i n ch w=0 out=""
    [[ "$s" == *$'\t'* ]] && { ft_expand_tabs "$s"; s=$FT_RET; }
    i=0; n=${#s}
    while (( i < n && w < max )); do
        ch="${s:i:1}"
        if [[ "$ch" == $'\e' ]]; then
            out+="$ch"; (( i++ ))
            if [[ "${s:i:1}" == "[" ]]; then
                out+="["; (( i++ ))
                while (( i < n )) && [[ "${s:i:1}" != [@-~] ]]; do out+="${s:i:1}"; (( i++ )); done
                (( i < n )) && { out+="${s:i:1}"; (( i++ )); }
            elif [[ "${s:i:1}" == "]" ]]; then
                out+="]"; (( i++ ))
                while (( i < n )); do
                    [[ "${s:i:1}" == $'\a' ]] && { out+=$'\a'; (( i++ )); break; }
                    [[ "${s:i:1}" == $'\e' && "${s:i+1:1}" == '\' ]] && { out+=$'\e\\'; (( i+=2 )); break; }
                    out+="${s:i:1}"; (( i++ ))
                done
            else
                (( i < n )) && { out+="${s:i:1}"; (( i++ )); }
            fi
            continue
        fi
        if [[ "$ch" == [[:ascii:]] ]]; then out+="$ch"; (( w++, i++ )); continue; fi
        ft_char_cols "$ch"
        (( w + FT_CHAR_WIDTH > max )) && break
        out+="$ch"; (( w += FT_CHAR_WIDTH, i++ ))
    done
    FT_DISPLAY_TRUNCATED="$out"
}

esc=$'\e'
# One entry per SHAPE the three paths distinguish, plus the shapes the paint path
# really hands it: a full-width plain row, the same row wrapped in one SGR, and a
# row carrying many short SGR runs (a key legend).
_corpus=(
  ""  "a"  "hello world"
  "The quick brown fox jumps over the lazy dog"
  "${esc}[1mbold${esc}[0m"
  "${esc}[48;5;16;38;5;250m          ${esc}[0m${esc}[48;5;234m"
  "plain${esc}[31mred${esc}[0mplain"
  "日本語テキスト"  "a日本語b"  "日本abc日本"
  "${esc}[1m日本語${esc}[0mtail"
  "e"$'́'"cole"                      # combining acute
  "ab"$'́'"cd"                       # …which can land exactly on the cut
  "${esc}[1mab"$'́'"cd${esc}[0m"     # …and again in the escape-carrying path
  "日"$'́'"本"
  "🙂🙂🙂🙂"                          # all wide, not one ASCII character in it
  "emoji 🙂 here"
  "${esc}[1memoji 🙂${esc}[0m here"
  $'tab\there'  $'a\tb\tc'
  $'\e]8;;http://example.com\aLINK\e]8;;\a'      # OSC hyperlink
  $'\e]0;title\e\\after'                          # OSC terminated by ST
  "trailing esc${esc}"  "${esc}[unterminated"  "${esc}"  "${esc}X"
  "—em dash first"  "…"
  "mixed 日本 abc — def 🙂 ghi"
)
_row=""; for (( _i=0; _i<118; _i++ )); do _row+="x"; done
_styled="${esc}[48;5;16m${_row}${esc}[0m"
_many=""; for (( _i=0; _i<8; _i++ )); do _many+="${esc}[1;38;5;214mF${_i}${esc}[0m lbl "; done
_corpus+=( "$_row" "$_styled" "$_many" )

# ── 1. The answers did not move ──────────────────────────────────────────────
note "every (string, width) pair answers exactly what the per-character loop answered"
_pairs=0; _differ=0; _cut=0; _whole=0; _firstdiff=""
for _s in "${_corpus[@]}"; do
    _n=${#_s}
    for (( _m=-2; _m<=_n+2; _m++ )); do
        _ref_display_truncate "$_s" "$_m"; _want=$FT_DISPLAY_TRUNCATED
        ft_display_truncate   "$_s" "$_m"; _got=$FT_DISPLAY_TRUNCATED
        (( _pairs++ ))
        if [[ "$_want" == "$_got" ]]; then
            # Companion counts, so "nothing differed" cannot be a sweep over
            # nothing: some pairs must really have cut, and some must not have.
            if [[ "$_got" == "$_s" ]]; then (( _whole++ )); else (( _cut++ )); fi
        else
            (( _differ++ ))
            [[ -z "$_firstdiff" ]] && printf -v _firstdiff 'max=%s src=%q want=%q got=%q' \
                "$_m" "$_s" "$_want" "$_got"
        fi
    done
done
check "no pair differs"                       "$_differ"                    "0"
check "…over a corpus that was really walked" "$(( _pairs > 800 ))"         "1"
check "…in which pairs were truncated"        "$(( _cut > 300 ))"           "1"
check "…and pairs were returned whole"        "$(( _whole > 100 ))"         "1"
[[ -n "$_firstdiff" ]] && printf '       first difference: %s\n' "$_firstdiff"

# ── 2. A negative width takes nothing ────────────────────────────────────────
# The fast path is ${s:0:max}, and bash reads a NEGATIVE length there as "all but
# the last |max| characters" — so an unguarded fast path hands back almost the
# whole string. ft_fit asks for (w - 1), which is -1 for a one-column box, so this
# is a width the engine really passes.
note "a width of zero or less takes nothing"
ft_display_truncate "abcdef" 0;   check "max 0"  "$FT_DISPLAY_TRUNCATED" ""
ft_display_truncate "abcdef" -1;  check "max -1" "$FT_DISPLAY_TRUNCATED" ""
ft_display_truncate "日本語"  -3;  check "max -3, wide glyphs" "$FT_DISPLAY_TRUNCATED" ""

# ── 3. What it hands back, pinned ────────────────────────────────────────────
# The oracle above proves the two implementations agree; these prove they agree
# on the RIGHT answer, which no comparison between them can establish.
note "the answers themselves"
ft_display_truncate "日本語テキスト" 5
check "stops before a glyph it cannot fit whole"  "$FT_DISPLAY_TRUNCATED" "日本"
ft_display_truncate "${esc}[31mred${esc}[0mtail" 3
check "escapes are carried through, and cost nothing" \
      "$FT_DISPLAY_TRUNCATED" "${esc}[31mred"
ft_display_truncate "abcdef" 99
check "a width past the end returns the whole string" "$FT_DISPLAY_TRUNCATED" "abcdef"
ft_display_truncate $'ab\tcd' 10
check "a tab is expanded before it is cut"  "$FT_DISPLAY_TRUNCATED" "ab      cd"

# ── 4. The fast paths are taken, not merely available ────────────────────────
# A correct-but-slow implementation passes everything above. The defect this file
# was written for WAS the slowness: ft_display_width had been taught wholesale
# slicing and its sibling had not, so a 118-column row cost 2 ms to cut and ft_fit
# reaches for it on every string wider than its box.
#
# Counted with a DEBUG trap instead of a clock, so the gate is deterministic and
# does not care what else is running (tests/test-render.bash and its pty siblings
# contend; this must not).
note "the wholesale paths are actually taken"
_steps=0
_count() {                      # fn args… → _steps
    _steps=0
    set -T
    trap '(( _steps++ ))' DEBUG
    "$@"
    trap - DEBUG
    set +T
    (( _steps -= 2 ))           # the trap counts its own teardown
}
# THE INSTRUMENT FIRST. A DEBUG trap that never fired would report 0 for
# everything and pass every threshold below by measuring nothing at all.
_canary_loop() { local _i; for (( _i=0; _i<100; _i++ )); do :; done; }
_count _canary_loop
check "the statement counter counts (100-iteration loop)" "$(( _steps > 200 ))" "1"

# 12, not 60: the pre-change loop counted 833 here, but the MIDDLE path would
# count 16, and a threshold that cannot tell 16 from 7 does not gate the fast
# path at all — it only gates the disaster. 7 is what the fast path costs.
_count ft_display_truncate "$_row" 118
check "118 plain ASCII is one slice (7 steps; 16 without the fast path, 833 before)" \
      "$(( _steps < 12 ))" "1"
_plain_steps=$_steps
_count ft_display_truncate "$_styled" 116
check "a row wrapped in one SGR takes runs whole (was 861)"   "$(( _steps < 150 ))" "1"
_count ft_display_truncate "The quick brown fox — jumps over the lazy dog, a long line of prose ok" 60
check "prose with one em-dash does not go per-character (was 441)" "$(( _steps < 150 ))" "1"

# The same string through the sibling it is supposed to match. If ft_display_width
# ever loses its fast path, or this one gains a detour, the two diverge here first.
_count ft_display_width "$_row"
check "ft_display_width answers the same string in the same handful of steps" \
      "$(( _steps < 60 && _plain_steps < 60 ))" "1"

summary
