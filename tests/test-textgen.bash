#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  TWO QUESTIONS, TWO COUNTERS.
#
#    _fti_<name>__writegen   did ANYTHING about this control change?
#    _fti_<name>__textgen    did this control's displayed TEXT change?
#
#  They were one counter serving both, bumped on every property write, and the comment
#  justifying that said "over-invalidating merely costs a recompute". For the one control that
#  holds a document, measured on 1200 lines:
#
#      repaint, nothing changed                       8 ms
#      repaint after `ft-modify f runlevel=editing` 199 ms
#      repaint after `ft-modify f runlevel=poised`  145 ms
#
#  Every Enter INTO the field and every Esc OUT of it re-wrapped a document that had not
#  changed — on this framework's keystone interaction. It never had to: _ft_textfield_layout's
#  memo key is "$name|$w|$wrap|$gen", so width and the wrap flag are already in it BY NAME.
#
#  THE ASSERTION THAT MATTERS MOST IS THE RETAIN TOKEN. A first attempt narrowed the single
#  counter and measured beautifully — and would have shipped a stale-paint bug, because
#  _ft_retain_token used that same counter as its catch-all for "did anything change", and says
#  so in as many words one line below the one being edited. The token check below is what makes
#  that mistake impossible to repeat quietly.
#
#  The narrowing is OPT-IN per class (`textProps=`). A class that declares nothing keeps exactly
#  the old behaviour, so the failure mode of forgetting to opt in is a recompute, never a lie.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=60; FT_ROWS=20; FT_USE_UTF8=1; FT_COLOR_MODE=256

DOC=$'alpha beta gamma delta epsilon zeta eta theta\nsecond line of the document\nthird line here'
ft-form name=app width=60 height=20 display=flex flexDirection=column
    # width=, not size=: a flex COLUMN stretches its children across, so `size=20` left the well
    # 58 columns wide and nothing wrapped — which is exactly what the anti-vacuity check below
    # caught on the first run.
    ft-textfield name=tf width=24 rows=3 value="$DOC"
    ft-label     name=lb text="a plain label"
end_ft_form
ft_layout app
FT_ROOT=app
# In this shell: a draw fills the retained block and the wrap memo, and $( ) would discard both.
FT_OUT=""; ft_dirty_subtree app >/dev/null 2>&1; _ft_redraw_walk app >/dev/null 2>&1; FT_OUT=""

_tg() { local v="_fti_${1}__textgen";  printf '%s' "${!v:-0}"; }
_wg() { local v="_fti_${1}__writegen"; printf '%s' "${!v:-0}"; }
_token() { _ft_clip_for "$1" >/dev/null 2>&1; _ft_retain_token "$1"; printf '%s' "$FT_RET"; }

note "the fixture really wraps, so the memo this guards is really in play"
_ft_textfield_textw tf; _w=$FT_RET
_ft_textfield_layout tf "$_w"
check "the value wraps to more rows than it has lines" "$(( ${#FT_TEXTFIELD_LINES_TEXT[@]} > 3 ))" 1
check "…and the memo has a key"  "$(( ${#_FT_TEXTFIELD_LINES_CACHE_KEY} > 0 ))" 1

note "a textfield declares which properties change its text, and only those move the text counter"
check "it declares them" "${FT_CLASS_TEXT_PROPS[textfield]:-<none>}" "value text"
_t0=$(_tg tf); _w0=$(_wg tf)
ft-modify tf borderColor=201
check "an unrelated write does NOT move the text generation" "$(_tg tf)" "$_t0"
check "…but it does move the write generation"               "$(( $(_wg tf) > _w0 ))" 1
_t1=$(_tg tf); _w1=$(_wg tf)
ft-modify tf runlevel=editing
check "runlevel — the Enter-to-edit write — does not either"  "$(_tg tf)" "$_t1"
check "…and still moves the write generation"                 "$(( $(_wg tf) > _w1 ))" 1
ft-modify tf runlevel=poised
_t2=$(_tg tf); _w2=$(_wg tf)
ft-modify tf value="$DOC and more words to wrap with"
check "a value write DOES move the text generation"           "$(( $(_tg tf) > _t2 ))" 1
check "…and the write generation too"                         "$(( $(_wg tf) > _w2 ))" 1

note "…which is the whole point: an unrelated write must not re-wrap the document"
# Structural, not timed — a timing assertion on a loaded machine is a flake generator. The memo
# key IS the mechanism: same key means the next layout call is a hit and no re-wrap happens.
_ft_textfield_textw tf; _w=$FT_RET
_ft_textfield_layout tf "$_w"; _key0=$_FT_TEXTFIELD_LINES_CACHE_KEY
ft-modify tf borderColor=45
_ft_textfield_layout tf "$_w"
check "the wrap memo key survives an unrelated write" "$_FT_TEXTFIELD_LINES_CACHE_KEY" "$_key0"
ft-modify tf value="something else entirely"
_ft_textfield_textw tf; _w=$FT_RET
_ft_textfield_layout tf "$_w"
check "…and changes when the value does" \
      "$([[ "$_FT_TEXTFIELD_LINES_CACHE_KEY" != "$_key0" ]] && echo 1 || echo 0)" 1

note "THE RETAINED BLOCK MUST STILL INVALIDATE — the mistake this gate exists to prevent"
# _ft_retain_token's catch-all is __writegen, NOT __textgen. If it ever reads the narrowable
# counter again, a textfield serves a stale picture.
#
# THE PROPERTY HERE IS CHOSEN, NOT CONVENIENT. The first version of this section used
# borderColor and had NO TEETH: sabotaging the token to read the narrowable counter still passed
# 23/23, because a colour write moves the cascade version and the token is a composite that
# notices anyway. Measured across the textfield's registered paint properties, `wrapIndicator`
# is one that isolates the counter — the picture changes, and a token built on the narrowable
# counter would NOT move. (newlineIndicator, showLineNumbers and readOnly behave the same;
# cursorStyle and placeholder change no pixels in this fixture, so they cannot serve either.)
_shot() { FT_OUT=""; ft_dirty tf; ft_draw_one tf >/dev/null 2>&1; local p=$FT_OUT; FT_OUT=""; printf '%s' "$p"; }
_pic0=$(_shot); _tok0=$(_token tf)
_narrow0=$(v=_fti_tf__textgen; printf %s "${!v:-0}")
ft-modify tf wrapIndicator=true
check "the write really changes the picture (or the token check is vacuous)" \
      "$([[ "$_pic0" != "$(_shot)" ]] && echo 1 || echo 0)" 1
check "…and it is NOT a text property, so the narrowable counter stands still" \
      "$(v=_fti_tf__textgen; printf %s "${!v:-0}")" "$_narrow0"
check "…yet the retain token moves, so no stale block is served" \
      "$([[ "$(_token tf)" != "$_tok0" ]] && echo 1 || echo 0)" 1
_tok1=$(_token tf)
ft-modify tf value="a third value"
check "a text write moves it too"  "$([[ "$(_token tf)" != "$_tok1" ]] && echo 1 || echo 0)" 1
_tok2=$(_token tf)
check "…while changing nothing leaves it alone (or retention would be pointless)" \
      "$([[ "$(_token tf)" == "$_tok2" ]] && echo 1 || echo 0)" 1

note "a class that declares NOTHING is untouched — the two counters move together"
check "a label declares nothing" "${FT_CLASS_TEXT_PROPS[label]:-<none>}" "<none>"
_lt=$(_tg lb); _lw=$(_wg lb)
ft-modify lb color=201
check "…so an unrelated write moves its text generation too" "$(( $(_tg lb) > _lt ))" 1
check "…and its write generation"                            "$(( $(_wg lb) > _lw ))" 1

note "a REMOVAL is a write, and follows the same rule on both counters"
ft-modify tf borderColor=201            # give it something to remove
_rt=$(_tg tf); _rw=$(_wg tf)
ft_remove_attribute tf borderColor
check "removing a non-text property moves only the write generation" "$(_tg tf)" "$_rt"
check "…which it does move"                                          "$(( $(_wg tf) > _rw ))" 1
_rt2=$(_tg tf)
ft_remove_attribute tf value
check "removing the VALUE moves the text generation"                 "$(( $(_tg tf) > _rt2 ))" 1

note "a control rebuilt under a dead one's name starts both counters fresh"
# The retained block is filed under the token; a counter that restarted at 0 while the block
# survived would climb back through the dead control's token values.
ft-modify tf value="x"; ft-modify tf borderColor=1
check "the counters have moved" "$(( $(_wg tf) > 0 && $(_tg tf) > 0 ))" 1
ft_remove tf
check "removal clears the write generation" "$(_wg tf)" "0"
check "…and the text generation"            "$(_tg tf)" "0"

summary
