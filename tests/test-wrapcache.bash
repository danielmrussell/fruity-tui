#!/usr/bin/env bash
# Unit tests for ft_wrap_cached / _ft_text_extent_cached: memoizing wrap/extent
# per control NAME. Without this, a label paired with a scrollbar (demo/
# growth-demo.bash, demo/scrollbar-demo.bash) re-wraps and re-scans its ENTIRE
# text from scratch on every single Up/Down tick -- twice over (its own draw,
# plus ft_measure remeasuring it as part of a sibling status label's forced
# relayout) -- even though scrolling never changes text or width. For a
# genuinely large block of text that's tens of milliseconds of pure-bash
# looping PER keystroke, and arrow-key repeat fires faster than that: the
# "insane CPU" a user hits by holding Up/Down.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null

# Count real (uncached) recomputation without changing either function's own
# behavior: rename the original, then shim the public name to count + delegate.
eval "$(declare -f ft_wrap | sed '1s/ft_wrap/_real_ft_wrap/')"
WRAP_CALLS=0
ft_wrap() { (( WRAP_CALLS++ )); _real_ft_wrap "$@"; }

eval "$(declare -f _ft_text_extent | sed '1s/_ft_text_extent/_real_ft_text_extent/')"
EXTENT_CALLS=0
_ft_text_extent() { (( EXTENT_CALLS++ )); _real_ft_text_extent "$@"; }

note "ft_wrap_cached: first call actually wraps, matches plain ft_wrap"
LONG="one two three four five six seven eight nine ten eleven twelve"
ft_wrap_cached lbl1 "$LONG" 20
cached_lines=("${FT_WRAP_LINES[@]}")
_real_ft_wrap "$LONG" 20
check "cached result matches a direct ft_wrap call" "${cached_lines[*]}" "${FT_WRAP_LINES[*]}"
check "first call triggered exactly one real wrap" "$WRAP_CALLS" "1"

note "ft_wrap_cached: identical name/text/width is served from cache, not recomputed"
ft_wrap_cached lbl1 "$LONG" 20
check "no additional real wrap happened" "$WRAP_CALLS" "1"
ft_wrap_cached lbl1 "$LONG" 20
ft_wrap_cached lbl1 "$LONG" 20
check "still no additional real wrap after two more identical calls" "$WRAP_CALLS" "1"

note "ft_wrap_cached: a width change invalidates the cache"
ft_wrap_cached lbl1 "$LONG" 10
check "wrap re-ran for the new width" "$WRAP_CALLS" "2"
check "line count grew now that width shrank" "$(( ${#FT_WRAP_LINES[@]} > ${#cached_lines[@]} ))" "1"

note "ft_wrap_cached: a text change invalidates the cache"
ft_wrap_cached lbl1 "different text entirely now" 10
check "wrap re-ran for the new text" "$WRAP_CALLS" "3"

note "ft_wrap_cached: a different NAME never shares another control's cache"
ft_wrap_cached lbl2 "$LONG" 20
check "a fresh name always misses, even with args lbl1 already cached under" "$WRAP_CALLS" "4"
ft_wrap_cached lbl2 "$LONG" 20
check "but repeats for that same fresh name still hit its own cache" "$WRAP_CALLS" "4"

note "_ft_text_extent_cached: first call matches a direct _ft_text_extent call"
_ft_text_extent_cached ext1 "$LONG"
tw1=$FT_TEXT_WIDTH th1=$FT_TEXT_HEIGHT
_real_ft_text_extent "$LONG"
check "cached TW matches a direct call" "$tw1" "$FT_TEXT_WIDTH"
check "cached TH matches a direct call" "$th1" "$FT_TEXT_HEIGHT"
check "first call triggered exactly one real scan" "$EXTENT_CALLS" "1"

note "_ft_text_extent_cached: identical name/text is served from cache"
_ft_text_extent_cached ext1 "$LONG"
_ft_text_extent_cached ext1 "$LONG"
check "no additional real scan happened" "$EXTENT_CALLS" "1"

note "_ft_text_extent_cached: a text change invalidates the cache"
_ft_text_extent_cached ext1 "shorter"
check "scan re-ran for the new text" "$EXTENT_CALLS" "2"
check "TW updated to match the new (shorter) text" "$FT_TEXT_WIDTH" "7"

note "ft_wrap_cached retains TWO widths per name (gutter labels wrap at cols and cols-1)"
ft_wrap_cached twoslot "$LONG" 40      # miss → slot 0
ft_wrap_cached twoslot "$LONG" 39      # miss → slot 1 (both widths now cached)
c_after=$WRAP_CALLS
ft_wrap_cached twoslot "$LONG" 40      # width 40 must still be a HIT (not evicted)
check "re-wrap at width 40 served from cache (no new scan)" "$WRAP_CALLS" "$c_after"
ft_wrap_cached twoslot "$LONG" 39      # width 39 must still be a HIT too
check "re-wrap at width 39 served from cache (no new scan)" "$WRAP_CALLS" "$c_after"
ft_remove twoslot

note "ft_remove cleans up both caches' backing variables"
ft-form name=app
ft-label name=cachedLbl parent=app text="$LONG"
ft_wrap_cached cachedLbl "$LONG" 10
_ft_text_extent_cached cachedLbl "$LONG"
ft_remove cachedLbl
check "wrap cache key slot 0 var is gone"    "${_fti_cachedLbl__wrapkey0+set}" ""
check "wrap cache lines slot 0 array is gone" "${_fti_cachedLbl__wraplines0+set}" ""
check "extent cache key var is gone"  "${_fti_cachedLbl__extkey+set}" ""
check "extent cache TW var is gone"   "${_fti_cachedLbl__exttw+set}" ""
check "extent cache TH var is gone"   "${_fti_cachedLbl__extth+set}" ""

note "ft_wrap preserves whitespace (pre-wrap, NOT collapsed)"
CODE=$'ft-div name=box\n    ft-radio one\n        deeper'
_real_ft_wrap "$CODE" 40         # all lines fit → verbatim
check "leading indentation kept (4 spaces)"  "${FT_WRAP_LINES[1]}" "    ft-radio one"
check "deeper indentation kept (8 spaces)"   "${FT_WRAP_LINES[2]}" "        deeper"
_real_ft_wrap "a   b   c" 40     # internal multi-space runs kept
check "internal multi-space runs kept"       "${FT_WRAP_LINES[0]}" "a   b   c"

note "ft_wrap still soft-wraps genuinely-too-long physical lines"
_real_ft_wrap "    alpha beta gamma delta" 12   # indented, wider than 12
check "first wrapped line keeps its indent"  "${FT_WRAP_LINES[0]}" "    alpha"
check "wrapped into more than one line"       "$(( ${#FT_WRAP_LINES[@]} > 1 ))" "1"
check "no visual line exceeds the width"      "$(w=12; ok=1; for l in "${FT_WRAP_LINES[@]}"; do ft_display_width "$l"; (( FT_DISPLAY_WIDTH > w )) && ok=0; done; echo $ok)" "1"

note "ft_wrap hard-breaks a single token wider than the whole line"
_real_ft_wrap "abcdefghijklmnop" 5
check "long token split into ceil(16/5)=4 pieces" "${#FT_WRAP_LINES[@]}" "4"
check "first piece is exactly width-wide"          "${FT_WRAP_LINES[0]}" "abcde"

note "ft_fit_align distributes padding per CSS text-align"
ft_fit_align "hi" 6 left;   check "left keeps text at the start"   "$FT_FIT" "hi    "
ft_fit_align "hi" 6 right;  check "right pushes it to the end"     "$FT_FIT" "    hi"
ft_fit_align "hi" 6 center; check "center splits the padding"      "$FT_FIT" "  hi  "
ft_fit_align "hi" 7 center; check "center biases extra pad right"  "$FT_FIT" "  hi   "

summary
