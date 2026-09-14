#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  The retained display list: can it be stale?
#
#  ft_draw_one keeps the bytes each control painted (FT_RETAINED_BLOCK) and the conditions it
#  painted them under (FT_RETAINED_TOKEN), and a repaint whose token still matches is an append
#  instead of a derivation. Everything that can go wrong with that is one sentence:
#
#      a control whose BYTES would now be different, whose TOKEN still matches.
#
#  So this file measures exactly that. For a matrix of mutations driven through the framework's
#  own public routes, it asks each control two questions — "would you paint different bytes
#  now?" and "would the engine serve you from the block?" — and requires the answer never to be
#  yes and yes. That set is called a HAZARD here, and a hazard is a wrong pixel on somebody's
#  screen that no golden screenshot is looking at.
#
#  It also holds the property the whole design rests on (docs/rendering-spans-design.md §2.1):
#  A FRAME IS EXACTLY THE CONCATENATION OF ITS CONTROLS' BLOCKS, in paint order. That is true
#  today and a future painter that reads another control's paint state would break it silently —
#  the frame would still look right whenever everything is derived, and wrong only when
#  something is served. It is asserted here permanently, not as scaffolding.
#
#  TEETH (CONTRIBUTING §4), because "no hazards" is a negative and two blank screens agree:
#    · a mutation matrix that changes nothing would pass every check inside it, so the matrix
#      must be shown to have changed something;
#    · a probe that can never report a hazard would also pass, so an invalidation is defeated
#      on purpose — the entry is put back after a real ft-modify dropped it — and the hazard
#      must appear, by name;
#    · "the page is served" must be a real measurement: the derive count is taken at the
#      engine's own painter lookup, so an engine that never serves anything fails here rather
#      than passing every "nothing is stale" check for free.
#
#  CHECKED RATHER THAN ASSUMED — four sabotages of the ENGINE, one at a time, each applied to
#  ft-forms.bash and then reverted:
#    green  the first version of this file, under ALL FOUR   ← it carried its own copy of the
#           engine's serve rule, and ran the matrix with both mechanisms live so each covered
#           for the other. That is why the survey now defines a hazard by what reaches the
#           screen, and why the matrix runs a second time with ft_dirty's drop taken away.
#    RED    ft_dirty no longer drops the entry              1 FAIL
#    RED    the token forgets `_fti_<name>__textgen`        9 FAIL
#    RED    the token forgets FT_CLASS_PAINT_STATE          1 FAIL  ("a selection is made")
#    RED    overlays are served from their blocks           4 FAIL  ("the callout's target moves")
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_ROWS=30; FT_COLS=100; FT_USE_UTF8=1

# ── the scene ────────────────────────────────────────────────────────────────
# One of everything that carries state a repaint can see: text, a container that fills its
# background, a focusable button, a toggle, a field with a caret and a selection, and an
# overlay whose appearance depends on a control it does not own.
ft-form name=app width=100 height=30
    ft-frame name=win title=" Retain " width=90 height=24
        ft-label     name=head text="A heading" width=40
        ft-label     name=body text="Two lines of body text that the frame has to repair over." width=60
        ft-button    name=go   text="Go"
        ft-checkbox  name=cb   text="Read-only"
        ft-textfield name=fld  size=30 value="editable text"
    end_ft_frame
end_ft_form
FT_ROOT=app
ft_layout app
ft-beacon name=tip variant=callout target=head number=1 text="a callout over the page"
ft_layout app

RETAIN_CONTROLS=(app win head body go cb fld tip)

_paint() { FT_OUT=""; _ft_redraw_walk app; _ft_composite_overlays; }
# THREE paints, and the reason is worth writing down. A draw is allowed to write a DERIVED
# property — `_ft_draw_label` publishes `clientHeight` the first time it knows it — and every
# property write bumps the control's write counter, which the token carries. The token is taken
# BEFORE the draw (a token taken after would certify conditions the bytes were not made under),
# so a control's very first block is recorded already out of date. The second paint derives it
# again and records a token nothing has moved since; the third serves it. Measured on this
# scene: paint 1 derives all eight, paint 2 derives four, paint 3 onwards derives only the
# overlay — which is excluded from serving by design (see ft_draw_one). Every scene below
# starts settled, on purpose.
_settle() { _paint; _paint; _paint; }

# Draw one control and hand back its bytes, leaving the world as it was found — asking the
# question must not answer it. With drop=1 the retained entry is taken away first, so what
# comes back is a DERIVATION; with drop=0 the engine decides for itself.
#
# NOTHING HERE RE-IMPLEMENTS THE ENGINE'S RULE, and that is deliberate. The first version of
# this file asked "would ft_draw_one serve this?" by repeating its two conditions, and a
# sabotage of the engine — serving overlays, which puts a stale callout on the screen — left
# the file green, because the copy in the test was not sabotaged with it. A gate that carries
# its own copy of the subject cannot see the subject change.
_draw_block() {                 # name drop(0|1) → BLOCK_OUT
    local n=$1 drop=$2
    local had=0 keep_tok="" keep_blk="" keep_out=$FT_OUT
    local -a keep_damage=("${FT_DAMAGE[@]}")
    if [[ -n "${FT_RETAINED_TOKEN[$n]+set}" ]]; then
        had=1; keep_tok=${FT_RETAINED_TOKEN[$n]}; keep_blk=${FT_RETAINED_BLOCK[$n]}
    fi
    (( drop )) && unset "FT_RETAINED_TOKEN[$n]" "FT_RETAINED_BLOCK[$n]"
    FT_OUT=""
    ft_draw_one "$n"
    BLOCK_OUT=$FT_OUT
    FT_OUT=$keep_out
    FT_DAMAGE=("${keep_damage[@]}")
    if (( had )); then FT_RETAINED_TOKEN[$n]=$keep_tok; FT_RETAINED_BLOCK[$n]=$keep_blk
    else unset "FT_RETAINED_TOKEN[$n]" "FT_RETAINED_BLOCK[$n]"; fi
}
# A HAZARD is defined by what reaches the screen, not by what the engine was thinking: the
# bytes ft_draw_one produces with the retained list standing, against the bytes it produces
# with this control's entry taken away. If those differ, the list changed what the user sees.
_survey() {                     # → CHANGED, HAZARDS
    CHANGED=0; HAZARDS=""
    local n stale served derived
    for n in "${RETAIN_CONTROLS[@]}"; do
        [[ -n "${FT_TYPE[$n]:-}" ]] || continue
        stale=${FT_RETAINED_BLOCK[$n]:-}
        _draw_block "$n" 0; served=$BLOCK_OUT
        _draw_block "$n" 1; derived=$BLOCK_OUT
        [[ "$derived" != "$stale" ]] && CHANGED=$(( CHANGED + 1 ))
        [[ "$served"  != "$derived" ]] && HAZARDS+=" $n"
    done
}
# How many controls did a whole frame DERIVE? Counted at the engine's own painter lookup, which
# a served control never reaches — so this is the fast path being observed rather than assumed.
# Without it, "nothing is stale" would pass just as happily on an engine that never serves
# anything at all.
_RETAIN_DERIVES=0
eval "$(declare -f _ft_resolve_draw | sed '1s/^_ft_resolve_draw/_ft_resolve_draw_real/')"
_ft_resolve_draw() { _RETAIN_DERIVES=$(( _RETAIN_DERIVES + 1 )); _ft_resolve_draw_real "$@"; }
_derives_in_a_paint() { _RETAIN_DERIVES=0; _paint; DERIVES=$_RETAIN_DERIVES; }
# Each row of the matrix: settle (which fills every entry), mutate, survey.
MATRIX_CHANGED=0
row() {                         # description  command…
    local desc=$1; shift
    _settle
    "$@"
    _survey
    check "$desc" "$HAZARDS" ""
    MATRIX_CHANGED=$(( MATRIX_CHANGED + CHANGED ))
}
# PASS makes each mutation DIFFERENT from the one the previous pass left behind. A matrix run
# twice would otherwise spend its second pass setting values that are already set, every row
# would change nothing, and a sweep that changes nothing passes every check inside it.
PASS=0
_retain_resize() { FT_COLS=$(( 100 - PASS )); _ft_setprop app width "$FT_COLS"; ft_layout app; }
_retain_remove_attr() { ft-modify head color=blue; _paint; _paint; ft_remove_attribute head color; }
# A callout is placed against a control it does not own, so moving its TARGET changes what it
# paints while touching none of its own properties, geometry or class state. This is the row
# that earns the overlay exclusion in ft_draw_one: with overlays served from their blocks it
# reports `tip` as a hazard, and it is the only row here that does.
_retain_move_target() { ft-modify head width=$(( 40 - PASS * 6 )); ft_reflow_flush; }
_matrix() {
    PASS=$(( PASS + 1 ))
    MATRIX_CHANGED=0
    row "a label's text"           ft-modify body text="Rewritten body text, pass $PASS, longer than before."
    row "a label's colour"         ft-modify head color="$( (( PASS % 2 )) && echo red || echo lime )"
    row "a property removed"       _retain_remove_attr
    row "focus moves"              ft_focus go
    row "focus moves again"        ft_focus fld
    row "a checkbox toggles"       ft_checkbox_toggle cb
    row "the field is activated"   ft_textfield_activate fld
    row "a caret moves"            ft_textfield_right fld
    row "a selection is made"      ft_textfield_select_all fld
    row "typing"                   ft_textfield_insert_char fld "$PASS"
    row "a scroll"                 _ft_scroll_apply win "$(( PASS % 2 ))" ""
    row "a stylesheet registers"   ft_stylesheet name="__retainsheet$PASS" style='label { text-decoration: underline }'
    row "a runtime theme swap"     _ft_css_bump
    row "a control is hidden"      ft-modify go display=none
    row "…and shown again"         ft-modify go display=inline
    row "the callout's text"       ft-modify tip text="a different callout string, pass $PASS"
    row "the callout's target moves" _retain_move_target
    row "a resize"                 _retain_resize
    check "…and the pass was not a sweep over an empty list" "$(( MATRIX_CHANGED > 0 ))" "1"
}

note "the token separates 'would paint the same' from 'would not'"

_derives_in_a_paint; _first_derives=$DERIVES
_survey
check "with nothing touched, nothing is stale"    "$HAZARDS" ""
check "…which is not a page of empty blocks"      "$(( ${#FT_RETAINED_BLOCK[body]} > 20 ))" "1"
_settle; _derives_in_a_paint
check "…once settled, only the overlay is derived" "$DERIVES" "1"
check "…while the first paint really did derive the page" "$(( _first_derives >= 6 ))" "1"
_survey
check "…and still nothing stale"                  "$HAZARDS" ""

note "the matrix, with both mechanisms live — no control may serve stale bytes"
_matrix

# ── EACH MECHANISM ON ITS OWN ────────────────────────────────────────────────
# Retention has two, and running the matrix with both live cannot tell them apart: whichever
# one is broken, the other covers for it, and the file scores 41/41 either way. (Measured:
# removing ft_dirty's drop, removing the write counter from the token, and removing the class
# paint-state hook — three separate sabotages of the engine — each left this file GREEN.)
#
# So the drop is asserted DIRECTLY, and then the matrix is run again with the drop taken away,
# which leaves the token holding the whole weight. Sabotage any component of the token now and
# the pass below goes red, by name.
note "the drop: ft_dirty forgets the block, on every route that says the content moved"
_settle
check "the label has a block to lose"     "$([[ -n "${FT_RETAINED_TOKEN[body]+set}" ]] && echo yes)" "yes"
ft_dirty body
check "…and ft_dirty took it"             "${FT_RETAINED_TOKEN[body]+set}" ""
_settle
check "the frame has one too"             "$([[ -n "${FT_RETAINED_TOKEN[win]+set}" ]] && echo yes)" "yes"
ft_dirty_subtree win
check "…and ft_dirty_subtree took the subtree's" \
      "${FT_RETAINED_TOKEN[win]+set}${FT_RETAINED_TOKEN[head]+set}${FT_RETAINED_TOKEN[body]+set}" ""

note "the token, alone: the same matrix with ft_dirty's drop taken away"
_retain_real_dirty=$(declare -f ft_dirty)
ft_dirty() { FT_DIRTY[$1]=1; }
_matrix
eval "$_retain_real_dirty"
FT_RETAINED_BLOCK=(); FT_RETAINED_TOKEN=()
_settle

note "a frame IS the concatenation of its controls' blocks, in paint order"
_ORDER=()
eval "$(declare -f ft_draw_one | sed '1s/^ft_draw_one/_ft_draw_one_real/')"
ft_draw_one() { _ft_draw_one_real "$@"; [[ -n "${FT_TYPE[$1]:-}" ]] && _ORDER+=("$1"); return 0; }
_ORDER=(); _paint; _FRAME=$FT_OUT
_join=""; for _n in "${_ORDER[@]}"; do _join+=${FT_RETAINED_BLOCK[$_n]:-}; done
check "the frame is non-empty"                   "$(( ${#_FRAME} > 100 ))" "1"
check "…and the blocks joined in paint order ARE the frame" \
      "$([[ "$_join" == "$_FRAME" ]] && echo yes || echo no)" "yes"
_rev=""; for (( _i=${#_ORDER[@]}-1; _i>=0; _i-- )); do _rev+=${FT_RETAINED_BLOCK[${_ORDER[_i]}]:-}; done
check "teeth: the SAME blocks in reverse order are not the frame" \
      "$([[ "$_rev" == "$_FRAME" ]] && echo yes || echo no)" "no"
unset -f ft_draw_one; eval "$(declare -f _ft_draw_one_real | sed '1s/^_ft_draw_one_real/ft_draw_one/')"

note "removal and reparenting drop the entry, because a name can be reused"
_settle
check "the button has a retained block"  "$([[ -n "${FT_RETAINED_BLOCK[go]:-}" ]] && echo yes)" "yes"
ft_remove go
check "…and ft_remove took it away"      "${FT_RETAINED_TOKEN[go]+set}" ""
_settle
check "the checkbox has one too"         "$([[ -n "${FT_RETAINED_BLOCK[cb]:-}" ]] && echo yes)" "yes"
ft_append win cb
check "…and reparenting took it away"    "${FT_RETAINED_TOKEN[cb]+set}" ""

note "ft_retain_inval is the escape hatch, and it works"
_settle
_derives_in_a_paint
check "a settled page derives only the overlay" "$DERIVES" "1"
_gen_before=$FT_RETAIN_GENERATION
ft_retain_inval
_derives_in_a_paint
check "the generation moved"             "$(( FT_RETAIN_GENERATION > _gen_before ))" "1"
check "…and the next frame derives everything again" "$(( DERIVES >= 5 ))" "1"

note "a modal opening and closing over the page: the case the design is built on"
_settle
_saved_root=$FT_ROOT; _saved_focus=${FT_FOCUS:-}
ft-form name=__rmodal width="$FT_COLS" height="$FT_ROWS" display=flex justifyContent=center alignItems=center
    ft-frame name=__rmodalwin title=" Modal " width=40 height=10
        ft-label name=__rmodaltext text="a modal over the page"
    end_ft_frame
end_ft_form
FT_ROOT=__rmodal; ft_layout __rmodal
FT_OUT=""; _ft_redraw_walk __rmodal; FT_OUT=""
ft_remove __rmodal
FT_ROOT=$_saved_root; [[ -n "$_saved_focus" ]] && FT_FOCUS=$_saved_focus
FT_DAMAGE=(); FT_DIRTY=(); FT_REPAIR=()
# Counted BEFORE the survey, which draws every control twice by itself and would be measuring
# its own footprints.
#
# TWO, not one: the overlay is never served (by design), and the control focus left and came
# back to has had a property written on it in between — the write counter only goes up, so its
# entry legitimately misses once. Everything else on the page comes back as an append.
_derives_in_a_paint
check "the page comes back served, all but two controls" "$(( DERIVES <= 2 ))" "1"
_survey
check "…and nothing under the modal went stale"   "$HAZARDS" ""
# …and the frame that comes back is the frame that went in. This is the assertion the 88ms → 10ms
# claim rests on: a repaint served from blocks must be byte-identical to one derived from nothing.
_paint; _served_frame=$FT_OUT
FT_RETAINED_BLOCK=(); FT_RETAINED_TOKEN=()
_paint; _derived_frame=$FT_OUT
check "a served repaint is byte-identical to a derived one" \
      "$([[ "$_served_frame" == "$_derived_frame" ]] && echo yes || echo no)" "yes"
check "…and it was not two empty frames"          "$(( ${#_served_frame} > 100 ))" "1"

note "the teeth: a token that forgot its inputs must show up as a hazard"
# SABOTAGE THE SUBJECT, not the probe (CONTRIBUTING §5). Retention rests on exactly two
# mechanisms — ft_dirty drops the entry, and the token carries what a write cannot be seen
# through — so break both and require the survey to notice. `_ft_retain_token` reduced to the
# control's own name is a token that forgot every input it has; ft_dirty without its drop is
# the invalidation that did not fire. Then make a REAL change through ft-modify.
#
# Restoring both and repainting must clear it again, or the teeth are only proving that the
# scene is unstable.
_settle
_teeth_dirty=$(declare -f ft_dirty)
_teeth_token=$(declare -f _ft_retain_token)
ft_dirty() { FT_DIRTY[$1]=1; }
_ft_retain_token() { FT_RET="$1"; }
# …AND THE REFLOW, which is a THIRD mechanism and was not one until now. `text` is layout-kind,
# so writing it schedules a reflow, and a reflow reaches this control's block by a route that has
# nothing to do with retention — it would tidy up after the two sabotages above and the hazard
# they are meant to expose would never appear. That door was shut in this fixture by accident
# rather than by design: the scene builds a callout, and ft-beacon used to register `text` as
# paint-kind for the entire framework, so this write never reflowed. With that bug fixed (see
# tests/test-propkind.bash) the door is open, and the sabotage has to close it deliberately.
_teeth_reflow=$(declare -f ft_reflow)
ft_reflow() { :; }
_paint
ft-modify body text="the text the retained block has never heard of"
_survey
check "a token that forgot its inputs is reported, by name" "$HAZARDS" " body"
eval "$_teeth_dirty"; eval "$_teeth_token"; eval "$_teeth_reflow"
FT_RETAINED_BLOCK=(); FT_RETAINED_TOKEN=()
_settle
_survey
check "…and the scene is clean again with the real ones back" "$HAZARDS" ""

note "the recorder is emptied by every frame, so stray ink cannot accumulate"
# Ink painted OUTSIDE any ft_draw_one — an app drawing straight onto the frame, a toast — lands
# in the recorder with no draw to claim it. Left there it would grow for the life of the
# session, and it would grow the cost of every append with it: measured, a print drifted from
# 68µs to 2.2ms across 2,000 unclaimed calls. ft_flush is where a frame ends and where it goes.
_settle; ft_flush
for _i in $(seq 1 60); do ft_print_at 0 "$_i" "x"; done
check "unclaimed ink really does land in the recorder" "$(( ${#FT_BLOCK_BEING_DRAWN} > 0 ))" "1"
ft_flush
check "…and the flush empties it"                      "${#FT_BLOCK_BEING_DRAWN}" "0"

note "memory: a block is bounded by the SCREEN, not by the document"
ft-form name=big width=100 height=30
    ft-textfield name=doc size=80 rows=20 wrap=true readOnly=true
end_ft_form
_docval=""
for _i in $(seq 1 2000); do _docval+="line $_i of a document that is much taller than the screen"$'\n'; done
ft-modify doc value="$_docval"
FT_ROOT=big; ft_layout big
FT_OUT=""; _ft_redraw_walk big; FT_OUT=""
check "the document is genuinely large"      "$(( ${#_docval} > 90000 ))" "1"
check "…and its retained block is not"       "$(( ${#FT_RETAINED_BLOCK[doc]} < 30000 ))" "1"
check "…but it is not empty either"          "$(( ${#FT_RETAINED_BLOCK[doc]} > 500 ))" "1"

summary
