#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — tests/test-charwidth.bash
#
#  ft_char_cols is MEMOISED (see ft-core.bash). A memo is a promise that the
#  answer cannot change; this file is where that promise is kept honest.
#
#  Three things have to hold, and each is a different kind of failure:
#
#    1. The memoised function answers EXACTLY what the pre-memo one answered,
#       for every code point. The classification is a wall of hand-written
#       ranges that was RESTRUCTURED to reach a single store point (four early
#       `return`s folded into one if/elif chain), and a mistyped boundary there
#       is invisible until a CJK column is off by one. So the original body is
#       kept below, verbatim, and the two are compared point by point.
#
#    2. The table's KEY is a character, and bash associative arrays have teeth.
#       An EMPTY subscript is not a miss, it is a fatal `bad array subscript`
#       that kills the shell under `set -e` — which apps run with. `@` and `*`
#       are the all-elements sigils. A stored 0 (combining marks) must read
#       back as a HIT, not as a miss.
#
#    3. LC_CTYPE must not move under the memo's feet. The width of a glyph is a
#       function of the code point AND the locale; if any engine path measured
#       text under a different LC_CTYPE, the first caller would decide the
#       answer for every later one.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source tests/_harness.bash
source ./ft-core.bash

# ── The pre-memo implementation, verbatim ────────────────────────────────────
# Copied from ft-core.bash as it stood before the memo. Do not "tidy" it: its
# value is that it is the OLD code, not that it is good code.
_REF_WIDTH=1
_ref_char_cols() {
    local cp
    printf -v cp '%d' "'$1" 2>/dev/null || { _REF_WIDTH=1; return; }
    if   (( cp < 0x0300 )); then _REF_WIDTH=1; return
    elif (( cp <= 0x036f )); then _REF_WIDTH=0; return
    elif (( cp == 0x200b || cp == 0x200d )); then _REF_WIDTH=0; return
    elif (( cp >= 0xfe00 && cp <= 0xfe0f )); then _REF_WIDTH=0; return
    fi
    if (( (cp >= 0x1100 && cp <= 0x115f)      ||  \
          (cp >= 0x2e80 && cp <= 0x303e)      ||  \
          (cp >= 0x3041 && cp <= 0xa4cf)      ||  \
          (cp >= 0xac00 && cp <= 0xd7a3)      ||  \
          (cp >= 0xf900 && cp <= 0xfaff)      ||  \
          (cp >= 0xfe10 && cp <= 0xfe19)      ||  \
          (cp >= 0xfe30 && cp <= 0xfe6f)      ||  \
          (cp >= 0xff00 && cp <= 0xff60)      ||  \
          (cp >= 0xffe0 && cp <= 0xffe6)      ||  \
          (cp >= 0x1f300 && cp <= 0x1f64f)    ||  \
          (cp >= 0x1f680 && cp <= 0x1f6ff)    ||  \
          (cp >= 0x1f900 && cp <= 0x1f9ff)    ||  \
          (cp >= 0x20000 && cp <= 0x3fffd) )); then _REF_WIDTH=2; else _REF_WIDTH=1; fi
}

# ── 1. Differential sweep ────────────────────────────────────────────────────
# Every boundary of every range, ±1 — that is where a transcription error lands
# — plus an exhaustive walk of the low plane and a stride across the rest.
note "ft_char_cols == the pre-memo implementation, code point by code point"

_BOUNDS=(0x0300 0x036f 0x200b 0x200d 0xfe00 0xfe0f 0x1100 0x115f 0x2e80 0x303e
         0x3041 0xa4cf 0xac00 0xd7a3 0xf900 0xfaff 0xfe10 0xfe19 0xfe30 0xfe6f
         0xff00 0xff60 0xffe0 0xffe6 0x1f300 0x1f64f 0x1f680 0x1f6ff 0x1f900
         0x1f9ff 0x20000 0x3fffd)

_points=()
for b in "${_BOUNDS[@]}"; do _points+=( $(( b - 1 )) "$b" $(( b + 1 )) ); done
for (( c = 1; c < 0x1000; c++ )); do _points+=( "$c" ); done          # exhaustive low plane
for (( c = 0x1000; c < 0x10000; c += 37 )); do _points+=( "$c" ); done
for (( c = 0x10000; c < 0x40100; c += 211 )); do _points+=( "$c" ); done

_diff=0; _checked=0; _first=""
for cp in "${_points[@]}"; do
    (( cp < 1 || cp > 0x10FFFF )) && continue
    (( cp >= 0xD800 && cp <= 0xDFFF )) && continue     # surrogates are not characters
    printf -v ch "\\U$(printf '%08x' "$cp")"
    (( ${#ch} == 0 )) && continue                      # printf declined it; nothing to compare
    _ref_char_cols "$ch"
    ft_char_cols "$ch"
    (( _checked++ ))
    if [[ "$FT_CHAR_WIDTH" != "$_REF_WIDTH" ]]; then
        (( _diff++ ))
        [[ -z "$_first" ]] && printf -v _first 'U+%04X: memo=%s ref=%s' "$cp" "$FT_CHAR_WIDTH" "$_REF_WIDTH"
    fi
done
check "no disagreement over $_checked code points" "$_diff${_first:+ ($_first)}" "0"
# Teeth: the sweep must actually have covered the interesting widths, or a
# comparison of two constant 1s would pass forever.
_saw0=0; _saw2=0
for ch in $'́' $'️' $'​'; do ft_char_cols "$ch"; (( FT_CHAR_WIDTH == 0 )) && _saw0=1; done
for ch in 'あ' '한' 'Ａ' '🙂'; do ft_char_cols "$ch"; (( FT_CHAR_WIDTH == 2 )) && _saw2=1; done
check "sweep exercised zero-width and wide glyphs" "$_saw0$_saw2" "11"

# ── 2. Warm answers the same as cold ─────────────────────────────────────────
note "a memo HIT returns what the COMPUTE returned"
_mismatch=""
for ch in 'a' 'あ' '─' '—' '🙂' $'́' $'️' 'Ａ' '한' '│' 'é' '…'; do
    _FT_CHAR_COLS_MEMO=()                       # cold
    ft_char_cols "$ch"; cold=$FT_CHAR_WIDTH
    ft_char_cols "$ch"; warm=$FT_CHAR_WIDTH     # hit
    ft_char_cols "$ch"; warm2=$FT_CHAR_WIDTH
    [[ "$cold" == "$warm" && "$warm" == "$warm2" ]] || _mismatch+="$ch($cold/$warm/$warm2) "
done
check "cold == warm == warm again" "${_mismatch:-clean}" "clean"

# A stored ZERO is the trap: "0" must read back as a hit, not as an empty miss.
_FT_CHAR_COLS_MEMO=()
ft_char_cols $'́'
check "combining mark memoised as 0"        "${_FT_CHAR_COLS_MEMO[$'́']-unset}" "0"
FT_CHAR_WIDTH=99; ft_char_cols $'́'
check "…and the 0 comes back on the hit"    "$FT_CHAR_WIDTH" "0"

# The table must really be filling — otherwise every assertion above passes on a
# function that memoises nothing.
_FT_CHAR_COLS_MEMO=()
ft_char_cols 'あ'; ft_char_cols '─'; ft_char_cols 'あ'
check "memo stores one entry per distinct char" "${#_FT_CHAR_COLS_MEMO[@]}" "2"

# ── 3. Key hazards ───────────────────────────────────────────────────────────
note "characters that are hostile as array subscripts"

# THE EMPTY STRING. Legal input, answers 1, and must not touch the table: an
# empty subscript aborts the shell under `set -e`. Run it in a subshell that
# would DIE if the guard were removed — the echo is the proof of survival.
_out=$(set -e; source ./ft-core.bash; ft_char_cols ""; echo "survived:$FT_CHAR_WIDTH" 2>&1)
check "empty string under set -e: survives, width 1" "$_out" "survived:1"
_out=$(set -eu; source ./ft-core.bash; ft_char_cols ""; ft_char_cols ""; echo "survived:$FT_CHAR_WIDTH")
check "empty string twice under set -eu"            "$_out" "survived:1"

# @ and * are the all-elements sigils; ] and \ are subscript/quoting hazards.
_bad=""
for ch in '@' '*' ']' '[' '\' '$' ' ' $'\n' $'\t' $'\e' '!' '#' '%' "'" '"' '`'; do
    ft_char_cols "$ch"; got=$FT_CHAR_WIDTH
    _ref_char_cols "$ch"
    [[ "$got" == "$_REF_WIDTH" ]] || _bad+="$(printf '%q' "$ch")=$got/$_REF_WIDTH "
    ft_char_cols "$ch"                                   # again, through the memo
    [[ "$FT_CHAR_WIDTH" == "$_REF_WIDTH" ]] || _bad+="warm:$(printf '%q' "$ch") "
done
check "punctuation/sigil keys memoise correctly" "${_bad:-clean}" "clean"

# ── Hostile input runs in a SUBSHELL, and here is why ────────────────────────
# `printf '%d' "'X"` is bash's only fork-free way to a code point, and its
# multibyte decoder carries state ACROSS CALLS. Hand it one byte that is not a
# valid UTF-8 character — $'\xff', or the front half of a three-byte sequence —
# and every later decode in that shell returns the leading BYTE instead of the
# code point: あ measures 1 instead of 2, a combining mark 1 instead of 0. It
# does not resynchronise. This is NOT the memo — it reproduces exactly on
# _ref_char_cols above, which is the pre-memo function verbatim — and it is the
# reason these assertions are fenced off: run them inline and they corrupt every
# width measured afterwards in this file. (Which they did, first time out.)
#
# The memo's effect on this hazard is to REDUCE it: a character measured before
# the bad byte arrives keeps its correct cached answer instead of being
# re-decoded wrongly on every later frame. It does not cure it. Pinned here so
# the behaviour is on record rather than rediscovered.
# Reproduction, for the record (bash 5.2, en_US.UTF-8), as a standalone shell:
#     f() { local cp; printf -v cp '%d' "'$1"; echo "$cp"; }
#     f $'\xff'      # 255
#     f 'あ'         # 227  ← the leading byte, not 12354. Never recovers.
# Exactly when it trips depends on bash's internal decoder state and on call
# order, so this file does NOT assert the symptom — that would be a test of
# bash's internals, and a flaky one. What it asserts is the memo's own contract,
# which is stronger and deterministic: a character measured while the decoder
# was healthy keeps that answer for the rest of the session, no matter what
# arrives afterwards. This is the ONE place the memo is not bit-identical to the
# pre-memo function, and it differs by being RIGHT where the old code drifts.
( declare -A _truth=()
  for _c in 'あ' '日' '─' $'́' 'a'; do            # clean-state truth, taken first
      ft_char_cols "$_c"; _truth["$_c"]=$FT_CHAR_WIDTH
  done
  _wrong=""
  for _seq in 'あ' $'\xff' 'あ' $'\xc3' '日' $'\xe2\x94' '─' $'́' 'a' 'あ'; do
      [[ -n "${_truth["$_seq"]-}" ]] || continue       # the bad bytes have no truth
      ft_char_cols "$_seq"
      [[ "$FT_CHAR_WIDTH" == "${_truth["$_seq"]}" ]] \
          || _wrong+="$(printf '%q' "$_seq"):$FT_CHAR_WIDTH!=${_truth["$_seq"]} "
  done
  check "memo holds the clean-state answer through a desyncing sequence" "${_wrong:-held}" "held" )

( # A character already in the table is immune, because it never reaches printf.
  ft_char_cols 'あ'; _before=$FT_CHAR_WIDTH
  ft_char_cols $'\xff'
  ft_char_cols 'あ'; _after=$FT_CHAR_WIDTH
  check "memo shields an already-measured glyph from the desync" "$_before/$_after" "2/2" )

( # Bytes that are not valid UTF-8 on their own — what a corrupt file or a
  # half-read paste puts into a string. The old code answered 1; so must this.
  # Each byte gets its OWN subshell: the desync above means one of them would
  # otherwise decide the answer for the next.
  _bad=$(
    for ch in $'\xff' $'\x80' $'\xc3' $'\xe2\x94'; do
        ( _ref_char_cols "$ch"; ref=$_REF_WIDTH
          ft_char_cols "$ch"; cold=$FT_CHAR_WIDTH
          ft_char_cols "$ch"; warm=$FT_CHAR_WIDTH
          [[ "$cold" == "$ref" && "$warm" == "$ref" ]] || printf '%q ' "$ch" )
    done )
  check "invalid UTF-8 bytes: unchanged, and safe as keys" "${_bad:-clean}" "clean" )

# Multi-character input: whatever the old code did, this must do. (It reads the
# first character — but the same decoder state decides that, so the assertion is
# a COMPARISON, never a hardcoded number.)
( ft_char_cols 'ab';  _ref_char_cols 'ab'
  check "multi-char input matches the original" "$FT_CHAR_WIDTH" "$_REF_WIDTH" )
( ft_char_cols 'あa'; _got=$FT_CHAR_WIDTH; _ref_char_cols 'あa'
  check "multi-char input, wide first, matches the original" "$_got" "$_REF_WIDTH" )

# Not an indexed array by accident: with `declare -A` missing, bash evaluates the
# subscript ARITHMETICALLY and every character collides in slot 0.
check "memo is associative"  "$(declare -p _FT_CHAR_COLS_MEMO 2>/dev/null | cut -d' ' -f2)" "-A"

# ── 4. The width scans built on it ───────────────────────────────────────────
note "the callers still measure what they measured"
ft_display_width "──────────────────────────────────"; check "34 box glyphs"     "$FT_DISPLAY_WIDTH" "34"
ft_display_width "日本語";                              check "3 CJK = 6 columns" "$FT_DISPLAY_WIDTH" "6"
ft_display_width "abc";                                 check "pure ASCII"        "$FT_DISPLAY_WIDTH" "3"
ft_display_width $'\e[31mred\e[0m';                     check "escapes are free"  "$FT_DISPLAY_WIDTH" "3"
ft_display_width "e"$'́';                          check "combining mark"    "$FT_DISPLAY_WIDTH" "1"
ft_display_truncate "日本語テキスト" 5
check "truncate stops before a split glyph" "$FT_DISPLAY_TRUNCATED" "日本"
ft_display_index "日本語" 4
check "index at column 4"        "$FT_RET" "2"
check "…lands on column 4"       "$FT_DISPLAY_COL" "4"

# The same measurements again, now that every glyph above is memoised. A width
# scan that reads a stale or wrongly-keyed entry shows up here.
ft_display_width "──────────────────────────────────"; check "34 box glyphs (warm)"     "$FT_DISPLAY_WIDTH" "34"
ft_display_width "日本語";                              check "3 CJK = 6 columns (warm)" "$FT_DISPLAY_WIDTH" "6"
ft_display_truncate "日本語テキスト" 5
check "truncate (warm)" "$FT_DISPLAY_TRUNCATED" "日本"

# ── 5. The locale premise ────────────────────────────────────────────────────
# The memo is only sound because LC_CTYPE is fixed for the process. Two engine
# paths do touch the locale; neither may leak into a width.
note "LC_CTYPE does not move under the memo"
_lc_before=${LC_ALL:-}
source ./ft-state.bash 2>/dev/null || true
if declare -F _ft_state_bytelen >/dev/null; then
    _ft_state_bytelen "日本語"
    check "ft-state's LC_ALL=C is function-local" "${LC_ALL:-}" "$_lc_before"
    ft_char_cols 'あ'
    check "…and a width after it is still 2"      "$FT_CHAR_WIDTH" "2"
fi
# A width measured under a C-locale LC_CTYPE would be a DIFFERENT number (printf
# yields the first byte, not the code point). Prove that is the case, so the
# claim "nothing measures under another locale" is a claim with content.
_c_answer=$(LC_ALL=C bash -c 'source ./ft-core.bash; ft_char_cols "あ"; echo "$FT_CHAR_WIDTH"')
check "a C-locale answer really would differ (so the premise matters)" \
    "$( [[ "$_c_answer" == "2" ]] && echo same || echo differs )" "differs"
check "…and this process is not in that locale" \
    "$( [[ "${LC_ALL:-$LANG}" == *[Uu][Tt][Ff]* ]] && echo utf8 || echo "${LC_ALL:-$LANG}" )" "utf8"

note "an escape does not change how wide the text around it is"
# ft_display_width has three paths — pure ASCII, no-escapes, and everything else — and adding an
# escape to a string moves it onto the third without changing a single visible column. Anything
# the third path measures differently from the second is a bug in the third, and there WAS one:
# it measured `${#1}`, the length of the ORIGINAL argument, while the tab expansion at the top of
# the function had already made `s` longer. So a string with a tab AND an escape stopped short —
# $'a\tbcd\e[0m' came back 9 where the same text without the escape came back 11.
_esc=$'\e[0m'
for _sample in $'a\tbcd' $'a\tbcd\tx' "plain text" "wide あ here" $'tab\tthen ↑ arrow'; do
    ft_display_width "$_sample";        _w_plain=$FT_DISPLAY_WIDTH
    ft_display_width "$_sample$_esc";   _w_esc=$FT_DISPLAY_WIDTH
    check "a trailing reset does not change the width of ${_sample@Q}" "$_w_esc" "$_w_plain"
    ft_display_width "$_esc$_sample";   _w_lead=$FT_DISPLAY_WIDTH
    check "…nor does a leading one"                                    "$_w_lead" "$_w_plain"
done
# TEETH: the samples must actually exercise the paths this is about — a set of pure-ASCII,
# tab-free strings would pass the loop above no matter what the escape path did.
ft_display_width $'a\tbcd'; _w_tab=$FT_DISPLAY_WIDTH
check "the tab samples really do expand (else the loop proves nothing)" "$(( _w_tab > 5 ))" "1"
ft_display_width "wide あ here"; _w_wide=$FT_DISPLAY_WIDTH
check "…and the wide sample really is wider than its characters"       "$_w_wide" "12"

summary
