#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — controls/ft-beacon.bash
#
#  The "beacon" class: a floating OVERLAY that marks a spot on the screen. A
#  beacon does not live in the layout flow (position:absolute) and is never
#  focusable — it paints ON TOP of whatever is under it and animates itself.
#  Three things a beacon can be:
#
#    variant=frame  — a heavy ruled box drawn just OUTSIDE a target control (or
#                     at an absolute rect), so the eye is dragged to it. This is
#                     what the '.' focus-locator ("homing beacon") is built from.
#    variant=number — a circled number badge (①②③ … from the Unicode
#                     enclosed-alphanumerics block) parked at a corner of a
#                     target, so a tutorial can point "look at THIS control".
#    variant=callout — a rounded chip of `text` with a leader line and an
#                     arrowhead (▼▲◀▶) pointing at the target: "look here, and
#                     here is why". The chip PLACES ITSELF — an allocator finds
#                     the free space, a search judges each candidate on the real
#                     routed line it would get, and the reader can drag the chip
#                     anywhere. This is most of this file; the cost model it is
#                     judged by is docs/placement-cost-model.md.
#    variant=bigarrow — a GIANT arrow drawn out of many cells, which flies in
#                     along its own axis, overshoots, settles — and then LEAVES
#                     again, because a huge arrow is the right amount of
#                     emphasis for a second and the wrong amount after ten.
#                     Unmissable where a one-cell ▶ is not. Its SHAPE is one of four
#                     drawn by hand in the sprite sheet below and never recomputed —
#                     `size: small|medium|large|x-large`, CSS's own keyword
#                     ladder — because a shape solved per window is a different
#                     arrow in every window. Its edges are at EIGHTH-of-a-cell
#                     precision using anchored block elements plus a foreground/
#                     background swap, which is 3–7× smoother than filling cells
#                     with █; `border-color` outlines the SILHOUETTE (the shape's
#                     own outermost cells, not a box round it) with the same
#                     technique. All of it is measured, and the two obvious glyph
#                     candidates it beat (box diagonals ╱╲, braille) are refuted
#                     with numbers, in docs/unicode-art.md. Read that before
#                     changing a glyph here.
#
#  A callout's own chrome, all of it optional and all of it a property:
#    number=N       a circled ①..⑳ badge stamped into the top border
#    onNext=fn      a clickable ▶ in the top-right border, wired to the `next` event
#    closable=      a clickable ⊠ close box in the corner (ON by default). Clicking it
#                   fires the `close` event and then removes the callout — unless a
#                   listener returns nonzero, which cancels the default action the way
#                   preventDefault does in the DOM.
#    calloutWidth=  where the TEXT wraps (the box comes out four columns wider)
#    arrowPadding=  blank cells the head keeps from the target
#    outset=        grows the rect being pointed at, so the head stands further out
#
#  Public API beyond the DSL (`ft-beacon name=… variant=callout target=… text=…`):
#    ft_beacon_side NAME   → FT_RET = the side `place=auto` actually chose
#                            (above|below|left|right), "" before the first paint.
#                            Ask this rather than reading the placement cache.
#    ft_beacon_place NAME  → decide that placement NOW, with no frame; 1 if the
#                            beacon has nothing to point at yet. The paint that
#                            follows reuses the answer rather than searching again.
#                            Place a target's RING before a callout aimed at the
#                            same target — the ring is part of what the callout
#                            measures (see ft_beacon_place's own note).
#
#  Placement is either TARGET-relative (target=someControl → the beacon tracks
#  that control's box every frame, so it follows a moved/rebuilt target) or an
#  absolute rect (no target → its own laid-out left/top/width/height).
#
#  Lifetime:
#    lifetime=oneshot — plays `cycles` laps of its effect then DESTROYS itself
#                       and repaints the ground it covered (the homing beacon).
#    lifetime=persist — loops forever until something ft_remove's it (a tutorial
#                       step's marker; a 'downcycle' effect like blink makes it
#                       appear to come and go while it is really still there).
#
#  Everything visible is THEMED and styleable through the cascade, never a
#  constant baked in code:
#    • the pulsing colour ramp is the theme's --beacon-1/-2/-3 (falling back to
#      --locator-1/-2/-3, the locator triple every bundled theme already sets),
#    • a static override is just CSS — `beacon::border { color: … }` for the
#      frame, `beacon::number { color: … }` for the badge (the ::structure /
#      pseudo-element model).
#
#  Depends on ft-core.bash and ft-forms.bash (uses the shared animation engine).
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_BEACON_LOADED:-}" ]] && return 0
_FT_BEACON_LOADED=1

# One lap of any beacon effect is FT_BEACON_PERIOD phase-cells long. The colour
# ramp and the blink/pop envelopes are all expressed as fractions of a lap, so
# the pace is one knob (ms-per-frame) and the shape never has to know the rate.
FT_BEACON_PERIOD=12
FT_BEACON_MS=60                 # ms per frame — a slow breath, not a strobe
# SHIMMER — a "ghost" effect for a borderless container: a barely-there outline that fades in
# and out ONCE (a smooth sinusoidal low-alpha bell), then STOPS — a single reminder that an
# invisible thing is there, never a perpetual animation (which would keep the loop hot = lag).
FT_BEACON_SHIMMER_PERIOD=30     # frames for the single fade-in-and-out
FT_BEACON_SHIMMER_MS=90         # ms per frame — a slow, smooth drift (~2.7s total)
FT_BEACON_SHIMMER_PEAK=30       # peak alpha % — well under half, so it's a faint hint, not a line
declare -A FT_BEACON_EXTENT=()  # name → "top left bottom right": the ACTUAL painted footprint
                                # (box + leader + arrowhead), which a callout draws OUTSIDE its
                                # own bounds — callers erase this rect to clear a moved callout.
declare -A FT_BEACON_BOX=()     # name → "top left bottom right" of just the CHIP box (drag hit-area)
# WHERE THE READER PARKED THE CHIP IS THE READER'S, SO IT IS A PROPERTY.
#
# It used to live in a `FT_BEACON_DRAG[name]` array beside every other cache in this file, and
# that is the one thing it is NOT: a cache is something the control can recompute, and nobody
# can recompute a decision a person made with a mouse. The consequence was exactly what a
# parallel array costs — ft_state_save walks a control's PROPERTIES, so it wrote 42 of them for
# a parked callout and no record of the park, and the reload put the chip back where the placer
# would have put it. "Parking is the feature" (see the grab, below) and the feature did not
# survive a restart.
#
# parkedTop / parkedLeft: both unset = never parked, place me automatically. They are ordinary
# numeric properties, so ft-state saves them with everything else and restores them with the
# user's other state, ft-modify can move a chip from app code, and a stylesheet or a probe can
# read where a chip sits without knowing this file's private tables.
_ft_beacon_park() {             # name → FT_RET = "top left", or "" (status 1) if auto-placed
    ft_get "$1" parkedTop
    local top=$FT_RET
    (( ${#top} )) || { FT_RET=""; return 1; }        # never parked — FT_RET must not go stale
    ft_get "$1" parkedLeft
    (( ${#FT_RET} )) || { FT_RET=""; return 1; }
    FT_RET="$top $FT_RET"
    return 0
}
# ft_beacon_unpark NAME — forget a parked position and let the placer choose again.
#
# THE MISSING HALF OF THE PARK. Parking is a property write, so an app could always DO it; but
# "put it back" is removing two properties at once and knowing that BOTH must go, which is
# exactly the kind of thing an API should not make a caller rediscover. Without it,
# demo/callout-demo.bash's advertised R key unset `FT_BEACON_DRAG[…]` — a table this file
# deliberately replaced with these two properties, and which has not existed since — so the key
# was inert, and three separate places in that demo told the reader it worked.
ft_beacon_unpark() {            # name
    [[ -n "${FT_TYPE[$1]:-}" ]] || return 1
    ft_remove_attribute "$1" parkedTop
    ft_remove_attribute "$1" parkedLeft
    ft_dirty "$1"
    return 0
}
declare -A FT_BEACON_PKEY=() FT_BEACON_PC=() FT_BEACON_LN=() # placement cache: key, scalars, wrapped lines
# THE SEARCH IS OWED, NOT SKIPPED. A cache miss inside a running app records the key it missed
# on here and paints nothing for that beacon; the run loop drains this table immediately after
# the frame reaches the screen (ft_beacon_drain_placements). Measured on demo/callout-demo.bash
# page 4 at 118×40, one step press: 687 ms, of which 560 ms was the search inside
# _ft_beacon_paint_callout, inside ft_draw_one, inside the settle for one keypress. The page the
# user is waiting for is correct without the callout — so show it, then place.
declare -A FT_BEACON_PENDING=()
_FT_BEACON_PLACE_NOW=0          # 1 while the drain (or ft_beacon_place) demands an answer NOW
declare -A FT_BEACON_NEXT=()     # name → "row col fn": the clickable ▶ cell + the fn a click runs
# name → "row col": the clickable ⊠ close cell, top-right of the chip, like a window's close box.
# ⊠ is U+22A0 SQUARED TIMES, chosen over the more obvious ☒ (U+2612 BALLOT BOX WITH X) because
# U+2612 is East-Asian-Ambiguous: terminals are free to render it two columns wide, which would
# push the top border a cell past its own corner. ⊠ is neutral width. (See the tabs/wide-glyph
# note in ft-core: a "one character" assumption is how borders end up one cell too long.)
declare -A FT_BEACON_CLOSE=()
declare -A FT_BEACON_LEADER=()   # name → routed leader polyline "r c r c …" (see ft_route)
declare -A FT_BEACON_WASVIS=()   # name → last frame's visibility (to erase on a fade-out transition)

# Circled-number glyphs, indexed by value: ⓪ at 0, ①..⑳ at 1..20. Kept as a
# real array (not string slicing) so the lookup is unambiguous and fork-free.
# Anything outside 0..20, or a non-UTF-8 terminal, falls back to "(n)".
_FT_BEACON_CIRCLED=(⓪ ① ② ③ ④ ⑤ ⑥ ⑦ ⑧ ⑨ ⑩ ⑪ ⑫ ⑬ ⑭ ⑮ ⑯ ⑰ ⑱ ⑲ ⑳)
_ft_beacon_glyph() {            # n → FT_RET (the badge glyph)
    local n=$1
    if (( FT_USE_UTF8 )) && (( n >= 0 && n <= 20 )); then FT_RET=${_FT_BEACON_CIRCLED[$n]}
    else FT_RET="($n)"; fi
}

ft_class_beacon() {
    # A beacon floats: absolute (out of flow), never focusable, no border of its
    # own (it paints its own rules). Its behaviour props default to a persistent
    # frame — the homing-beacon caller opts into oneshot explicitly.
    ft_class extends=ft_control \
        focusable=false \
        noHit=true \
        defaults="position=absolute variant=frame target= outset=1" \
        defaults="number=1 corner=topleft effect=pulse lifetime=persist cycles=2" \
        defaults="text= place=auto anchor=auto calloutWidth=40 boundBox= arrowPadding=1 closable=true" \
        defaults="borderStyle=dashed borderRadius=1" \
        defaults="arrowGap=1 smoothing=eighths bounceTravel=auto" \
        keywordProps="size"
        # ^ …and NOT size. A bigarrow's size is one of four authored shapes, named with
        #   CSS's own `size` keyword ladder, and leaving it out of the class defaults is
        #   what lets `beacon { size: large }` in a stylesheet reach it at all (a class
        #   default is applied INLINE, cascade level 1 — see the note below). Unset means "the
        #   largest rung that fits"; see _ft_bigarrow_size.
        #   arrowLength / headAngle / headFraction / shaftFraction are GONE with the rasteriser
        #   that read them: there is no longer a shape to parameterise.
    FT_CLASS_REPROP[beacon]=_ft_beacon_reprop   # effect=/lifetime=/variant= must RE-ARM, not just repaint
        # ^ the bigarrow's share of the class. Note what is NOT here: animationTimingFunction
        #   and animationDuration. A class default is APPLIED AS AN INLINE PROPERTY at
        #   construction (see _ft_apply_args), and inline is cascade level 1 — so defaulting
        #   them here would make `beacon { animation-timing-function: … }` in a stylesheet
        #   permanently unreachable, which is the opposite of the point. Those two are the
        #   CSS-named properties, they resolve through ft_style, and their fallback is a
        #   constant in code (FT_BIGARROW_EASING / FT_BIGARROW_MS) that nothing shadows.
        # ^ borderStyle/borderRadius are read ONLY by the drag GHOST (the chip's own border is
        #   its signature rounded look and does not consult them), so these defaults define the
        #   ghost: dashed, rounded. Restyle it like anything else: beacon:dragging { borderStyle:
        #   double } in a stylesheet, or borderStyle= on the instance.
    # `text` NEEDED NO REGISTRATION HERE. The line that used to stand here was
    # `ft_prop_kind_set text paint  # a callout's text may contain spaces` — reaching for the
    # kind table to get a PARSING side effect, because a registered name is how the DSL knows
    # `text="two words"` is an assignment rather than bare content. But `text` is registered by
    # the base list already, so the parse was never in question; all the line did was tell the
    # whole framework that a text change repaints and does not re-measure. One callout anywhere
    # in an app and every label in it stopped growing with its string. See ft_prop_kind_set.
}
ft-beacon() {                   # ft-beacon name=… [target=… | left/top/width/height] … → arms it
    ft_new beacon "$@" || return 1
    # Register as an OVERLAY so the engine re-composites it on top after EVERY repaint —
    # a beacon paints outside its bounds and would otherwise be trampled by a sibling
    # redraw or an animation frame beneath it (see _ft_composite_overlays).
    local bn=$FT_RET
    FT_OVERLAY[$bn]=1
    # (The z-tier is derived in _ft_beacon_arm, below — the one place BOTH routes into a
    # variant pass. Deriving it here made `ft-modify b variant=callout` a callout at z=0.)
    ft_resolved_prop "$bn" variant frame; local _bv=$FT_RET
    # A BIGARROW RETIRES UNLESS YOU SAY OTHERWISE. `lifetime` is a class default shared with
    # every other variant, and a class default is APPLIED AS AN INLINE PROPERTY — so by the time
    # _ft_beacon_arm reads it, "the author asked for persist" and "the author said nothing" are
    # the same string and no reader of the property can tell them apart. The only place that CAN
    # is here, where the constructor's own words are still in "$@". A ring or a badge is one cell
    # of chrome and may sit there all day; two hundred cells of arrow may not, and the reported
    # complaint was exactly that it stayed.
    if [[ "$_bv" == bigarrow ]]; then
        local _a _said=0
        for _a in "$@"; do [[ "$_a" == lifetime=* ]] && { _said=1; break; }; done
        (( _said )) || ft-modify "$bn" lifetime=oneshot
    fi
    _ft_beacon_arm "$bn"
}
# Releasing a beacon must also stop its animation, or the engine keeps ticking a
# ghost phase for a destroyed name. (ft_remove calls _ft_destroy_<type>.)
# THE CELLS ARE GIVEN BACK BY _ft_ink_beacon ABOVE, not here. A beacon paints OUTSIDE its
# layout box — a chip's leader and arrowhead, a bigarrow's whole shape — so when it goes,
# nothing else on the screen knows those cells were ever occupied. This used to just DISCARD
# the record (`unset FT_BIGARROW_AT`) and leave the repair to whoever called ft_remove, so
# every app hand-rolled it:
#
#     local ext=${FT_BEACON_EXTENT[c]:-}      # the callout demo, three times over
#     ft_remove c; [[ -n "$ext" ]] && ft_damage $ext
#     _ft_bigarrow_damage_all specArrow       # …and a PRIVATE call, because an arrow's ink
#     ft_remove specArrow                     #    is not its extent and an app cannot know that
#
# An app cannot be expected to know what a control painted; the control knows. The bigarrow's
# erase record is exact (its per-row spans at the position it really drew), and the extent covers
# every other variant.
#
# THIS BRANCH AND `main` FIXED THAT INDEPENDENTLY, AND ONLY ONE COPY MAY SURVIVE — two would
# damage every beacon removal twice. The one kept is `_ft_ink_beacon` (above), because it is
# reached through the ENGINE'S general rule (ft_damage_subtree asks a class where its ink is),
# which means it also serves `display: none` — a control can go away without being destroyed,
# and a give-back that only lives in the destroy hook misses that entirely. Destroying is now
# only teardown again.
_ft_destroy_beacon() { ft_anim_stop "$1" 2>/dev/null
                       unset "FT_BEACON_PENDING[$1]" "FT_BEACON_EXTENT[$1]" "FT_BEACON_BOX[$1]" "FT_BEACON_PKEY[$1]" "FT_BEACON_PC[$1]" "FT_BEACON_LN[$1]" "FT_BEACON_WASVIS[$1]" "FT_BEACON_NEXT[$1]" "FT_BEACON_CLOSE[$1]" "FT_BEACON_LEADER[$1]" "FT_BEACON_LDRKEY[$1]" "FT_BEACON_LDRC[$1]" "FT_BEACON_BOUND[$1]" "FT_BIGARROW_AT[$1]" "FT_BIGARROW_EASE[$1]" "FT_BIGARROW_XEASE[$1]" "FT_BIGARROW_STAGE[$1]" "FT_BIGARROW_PKEY[$1]" "FT_BIGARROW_PC[$1]" "FT_OVERLAY[$1]" "FT_OVERLAY_EXTRA[$1]" "FT_OVERLAY_Z_ORDER[$1]"; [[ "${_FT_BEACON_GRAB%% *}" == "$1" ]] && _FT_BEACON_GRAB=""; }
declare -A FT_BEACON_BOUND=()   # "t l b r" interior the callout may park in (boundBox, or the screen)
declare -A FT_BEACON_LDRKEY=()  # placement-key|layout-epoch the cached leader was routed under
declare -A FT_BEACON_LDRC=()    # "side ar_r ar_c len headin" \x1f poly — see the cache note at the paint tail

# ── Mouse drag ───────────────────────────────────────────────────────────────
# A callout can be dragged aside by its CHIP box (only the box — the leader stays
# click-through). The engine's hit-test skips overlays (NOHIT), so the run loop
# pre-checks these before normal hit-testing (guarded by `declare -F`).
# THE PLACEMENT CACHE HAS ONE READER. `FT_BEACON_PC[name]` packs what the search decided —
# "side T L B R boxWidth boxHeight interiorWidth lineCount" — and four places unpacked it
# positionally, two of them into `_c1 _c2 _c3 _c4` and `_p1 … _p7`: names that say nothing, in a
# file whose recurring failure is the same thing written more than once. Add a field and every
# one of those `read -r` lines has to change in lockstep, silently reading the wrong column if it
# does not. This is the only place that knows the order.
FT_PLACED_SIDE=""; FT_PLACED_T=0; FT_PLACED_L=0; FT_PLACED_B=0; FT_PLACED_R=0
FT_PLACED_W=0; FT_PLACED_H=0; FT_PLACED_INNER_W=0; FT_PLACED_LINES=0
_ft_beacon_placement() {        # name → FT_PLACED_* ; 1 (and side="") if nothing is cached yet
    local _pc=${FT_BEACON_PC[$1]:-}
    if (( ${#_pc} == 0 )); then FT_PLACED_SIDE=""; return 1; fi
    read -r FT_PLACED_SIDE FT_PLACED_T FT_PLACED_L FT_PLACED_B FT_PLACED_R \
            FT_PLACED_W FT_PLACED_H FT_PLACED_INNER_W FT_PLACED_LINES <<< "$_pc"
    return 0
}
# …and the PUBLIC question that cache was being read for: which side did `place=auto` actually
# choose? The demo asks it to keep its own prose honest, and three tests ask it to assert on the
# achieved side; all of them were parsing the internal packed string, which makes an implementation
# detail into an API. This is the API.
ft_beacon_side() {              # name → FT_RET = above|below|left|right ("" if not placed yet)
    _ft_beacon_placement "$1"; FT_RET=$FT_PLACED_SIDE
    (( ${#FT_RET} > 0 ))
}
# ── …and the answer to "where WILL it go", which needs no frame ──────────────
# PLACEMENT IS COMPUTED AT PAINT. The search prices every candidate against the obstacle list and
# wraps the text at four widths, which is far too costly to redo per repaint — so it runs once
# and caches (FT_BEACON_PKEY / FT_BEACON_PC), and everything wanting to know where a callout went
# has had to drive a frame first. That gap shipped a bug: demo/callout-demo.bash's page 3 reads
# the side back so its sentence cannot claim `place=left` while sitting ABOVE the target with a
# ▼ — a reader's verdict on that was "all lies" — and it asks from the STEP HANDLER, which
# deliberately does not paint. `ft_beacon_side` answered "" every time and the reconcile took its
# `|| return 0`. The fix it was, ran, and never fired.
#
# THIS IS THE BEACON'S OWN DRAW, INTO A DISCARDED BUFFER — deliberately not a second copy of the
# search reached another way, because two paths to a placement are two placements that can
# disagree, and this file's recurring failure is the same thing written twice. Every variant is
# served: a callout fills FT_BEACON_PC, a bigarrow fills FT_BIGARROW_PC, each through the painter
# that already owns it.
#
# IT COSTS ONE EXTRA DRAW, NOT ONE EXTRA SEARCH. The placement key carries no animation phase and
# no layout epoch, so a paint that follows with the same inputs is a cache HIT and the search runs
# once. Measured over every page and step of the callout tour at five terminal sizes: 230 hits, 20
# misses, and every miss had a cause worth knowing rather than being noise —
#
#   · the app changed the TEXT in between (page 3 does exactly this). That is an input changing;
#     re-searching is the right answer, not a miss.
#   · ASKED TOO EARLY IN THE ORDER. _ft_beacon_rect grows a callout's target rect to include a
#     frame-variant beacon ringing that same target — "if the target is already ringed, the ring is
#     its visible edge" — and a ring publishes its extent when it PAINTS. Place the callout first
#     and it measures the bare target; the real frame then paints the ring first and the callout
#     re-measures. All 12 of page 6's misses were this, and placing that page's three rings before
#     the callout took them to 0. So: PLACE A RING BEFORE A CALLOUT AIMED AT THE SAME TARGET.
#     Not a defect to fix but a property to state — a forced placement sees the world as it is when
#     asked, which is the only thing it honestly can do.
#
# Callers should not need to know, but for the record: a callout's paint schedules no damage and
# no dirty, so forcing one is inert beyond the cache. A bigarrow's may give back cells it can no
# longer draw, which is a repaint request the following paint would have made anyway.
#
# → 0 with the placement cached; 1 if the beacon has no rect to be placed against yet (no target,
#   or a target that has not been laid out), which is the same "not placeable" a paint would hit.
ft_beacon_place() {             # name
    [[ -n "${FT_TYPE[$1]:-}" ]] || return 1
    # The block accumulator is thrown away with the bytes. This paint is a MEASUREMENT — it
    # exists to fill the placement cache — so its ink must not end up in the retained block of
    # whatever control happens to be drawing when an app calls this (see FT_BLOCK_BEING_DRAWN).
    # …and it must not DEFER: the whole contract of this function is that the answer is in the
    # cache when it returns, so it is the one caller that always pays the search.
    local _keep=$FT_OUT _keep_block=$FT_BLOCK_BEING_DRAWN _keep_now=$_FT_BEACON_PLACE_NOW
    _FT_BEACON_PLACE_NOW=1
    _ft_draw_beacon "$1"
    _FT_BEACON_PLACE_NOW=$_keep_now
    FT_OUT=$_keep; FT_BLOCK_BEING_DRAWN=$_keep_block
    unset "FT_BEACON_PENDING[$1]"          # …and it settles any debt this beacon had
    (( FT_BEACON_RECT_OK ))
}
# ft_beacon_drain_placements — pay every placement search the last frame put off, and repaint
# the beacons that were waiting on one. Called by ft-run right after the frame reaches the
# screen, so the cost lands where nobody is watching a half-drawn page.
#
# A BURST LEAVES ONE DEBT PER BEACON, NOT ONE PER PRESS. The table is keyed by name, so holding
# the step key down coalesces N searches into one — which is the case the sluggishness was
# reported from.
#
# Painted and flushed exactly as _ft_beacon_frame does it: the tree-walk draw path lets an
# outer redraw flush, but a standalone paint has to push its own bytes.
ft_beacon_drain_placements() {
    (( ${#FT_BEACON_PENDING[@]} )) || return 0
    local n painted=0
    for n in "${!FT_BEACON_PENDING[@]}"; do
        unset "FT_BEACON_PENDING[$n]"
        [[ -n "${FT_TYPE[$n]:-}" ]] || continue     # removed while the debt was outstanding
        _FT_BEACON_PLACE_NOW=1
        _ft_draw_beacon "$n"
        _FT_BEACON_PLACE_NOW=0
        painted=1
    done
    (( painted )) && ft_flush
    return 0
}
_FT_BEACON_GRAB=""              # "name grabRow grabCol" while a callout is being dragged
_FT_BEACON_GESTURE_NEW=0        # armed by each grab, consumed by that gesture's first real move
# Which callout's box covers screen cell (x,y)? → FT_RET=name (0 if hit).
_ft_beacon_hit_at() {           # x y → FT_RET
    local x=$1 y=$2 n bt bl bB bR
    for n in "${!FT_BEACON_BOX[@]}"; do
        [[ -n "${FT_TYPE[$n]:-}" ]] || continue
        set -- ${FT_BEACON_BOX[$n]}; bt=$1; bl=$2; bB=$3; bR=$4
        (( x>=bl && x<=bR && y>=bt && y<=bB )) && { FT_RET=$n; return 0; }
    done
    FT_RET=""; return 1
}
# The run loop calls these on press-in-box / drag / release (see _ft_dispatch_mouse). Because a
# callout overlaps transparent chrome (frame borders, the screen margin) that a targeted erase
# can't cleanly restore, a drag repaints the whole root — deferred under coalescing, so a burst
# of motion events settles in ONE redraw, with the callout composited on top at its new spot.
# A click on a callout's ▶ "next" glyph dispatches the callout's `next` EVENT (its listeners were
# registered via onNext=fn / ft_add_listener). The ▶ is the callout's OWN chrome, drawn above
# everything, so it always claims — the run loop checks it BEFORE hit-testing controls.
_ft_beacon_next_at() {          # x y → 0 if a ▶ was clicked (its `next` event dispatched)
    local px=$1 py=$2 nx nr nc
    for nx in "${!FT_BEACON_NEXT[@]}"; do
        set -- ${FT_BEACON_NEXT[$nx]}; nr=$1; nc=$2
        if (( px == nc && py == nr )); then _ft_hook "$nx" on_next; return 0; fi
    done
    return 1
}
# A click on the ⊠ closes the callout. Same claim-before-hit-testing rule as the ▶: the chip's own
# chrome is painted above everything, so it answers for its own cells.
#
# CLOSING IS A CANCELLABLE DEFAULT ACTION, exactly as the DOM has it and as this framework's
# dispatch already implements: `_ft_hook` runs EVERY `close` listener and returns nonzero iff one
# of them cancelled (see the note above _ft_hook — "any listener returning NONZERO cancels the
# action (preventDefault)"). So the event always fires, and the chip closes unless a listener
# says otherwise. A listener that merely wants to KNOW (log it, advance a tutorial's state)
# returns 0 and the chip still goes, which is what its reader just asked for by clicking; one
# that wants to keep it — an unsaved-changes hint, a step that must be acknowledged — returns
# nonzero and nothing is removed.
#
# (This first shipped as "any listener at all suppresses the close", which quietly made every
# observer into a veto and left `closable` with no way to observe-and-still-close.)
#
# The default action is a real removal: the cells the chip owned are damaged so the ground under
# it is repaired, because an overlay paints OUTSIDE its layout box and nothing else knows to
# repaint those cells. That is the same extent a step change hands to ft_damage.
_ft_beacon_close_at() {         # x y → 0 if a ⊠ was clicked
    local px=$1 py=$2 nx nr nc
    for nx in "${!FT_BEACON_CLOSE[@]}"; do
        set -- ${FT_BEACON_CLOSE[$nx]}; nr=$1; nc=$2
        (( px == nc && py == nr )) || continue
        if _ft_hook "$nx" on_close; then           # not cancelled → do the default action
            local _ext=${FT_BEACON_EXTENT[$nx]:-}
            ft_remove "$nx" 2>/dev/null
            [[ -n "$_ext" ]] && ft_damage $_ext
            # composites and flushes — see _ft_beacon_mouse_drag. It also DEFERS under
            # coalescing, which this route wanted all along: the blanket composite it used to
            # make ran straight through FT_COALESCING and painted every overlay mid-burst,
            # on top of a ground the settle had not repaired yet — the smear the drag path
            # was fixed for, on the close path.
            ft_redraw_dirty
        fi
        return 0                                   # the click was ours either way
    done
    return 1
}
# Start dragging a callout by its box. The run loop calls this ONLY as a fallback — after hit-
# testing found NO interactive control under the click. So a callout whose box happens to overlap
# a dropdown/slider NEVER steals that control's click (the control wins); you can still drag the
# callout from any cell where it covers inert background (its usual home, the empty stage margin).
_ft_beacon_grab_at() {          # x y → 0 if a drag was started
    local px=$1 py=$2
    _ft_beacon_hit_at "$px" "$py" || return 1
    local n=$FT_RET bt bl; set -- ${FT_BEACON_BOX[$n]}; bt=$1; bl=$2
    _FT_BEACON_GRAB="$n $(( py - bt )) $(( px - bl ))"
    # EVERY GESTURE'S FIRST MOVE ERASES THE FULL CHIP. The first-move test used to be "has this
    # callout ever been dragged" — and the park persists across releases because parking is the
    # feature. So the second gesture's first move took
    # the ring-only branch and the full callout its own release had just painted (interior text,
    # leader, arrowhead) was never erased — it stood at the first parking spot exactly as the
    # user reported. The old release's blanket ft_refresh had been repainting over the bug;
    # making release a drag frame exposed it. Gated by test-notrace's two-hops-vs-one case.
    _FT_BEACON_GESTURE_NEW=1
    # THE LEADER DIES AT THE GRAB, so the grab buries it. The grab dirties the callout
    # (dragging=true) and the settle draws it as a GHOST — which sets FT_BEACON_LEADER=""
    # without painting over the leader's ink. The first move's erase then reads that empty
    # string, and the whole arrow line stands wherever it was: the reported "broken line
    # segments" residue, present from the very first gesture. (Every differential gate missed
    # it because BOTH runs of a comparison carry the identical original-leader residue.)
    # Damaging it here, before the ghost can forget it, means the same settle that paints the
    # ghost repairs the line. The first move's own _lp loop stays: grab and move can share one
    # burst, where the ghost has not painted yet and the leader record is still live there.
    local _glp=${FT_BEACON_LEADER[$n]:-}
    if [[ -n "$_glp" ]]; then
        local -a _glw=($_glp); local _gli _glr0 _glc0 _glr1 _glc1
        for (( _gli=0; _gli+3 < ${#_glw[@]}; _gli+=2 )); do
            _glr0=${_glw[_gli]}; _glc0=${_glw[_gli+1]}
            _glr1=${_glw[_gli+2]}; _glc1=${_glw[_gli+3]}
            if (( _glr0 == _glr1 )); then
                ft_damage "$_glr0" $(( _glc0 < _glc1 ? _glc0 : _glc1 )) \
                          "$_glr0" $(( _glc0 > _glc1 ? _glc0 : _glc1 ))
            else
                ft_damage $(( _glr0 < _glr1 ? _glr0 : _glr1 )) "$_glc0" \
                          $(( _glr0 > _glr1 ? _glr0 : _glr1 )) "$_glc0"
            fi
        done
    fi
    # For the drag's whole lifetime, damage repairs only what it touches instead of enlisting a
    # container subtree — that is the difference between ~80ms and ~250ms a frame. A stray cell
    # under narrowed repair is transient here: release does a full refresh.
    FT_DAMAGE_NARROW=1
    # …and the :dragging state, so the ghost resolves its border through the cascade and any
    # `beacon:dragging { … }` rules apply while the grab lives.
    ft-modify "$n" dragging=true
    return 0
}
_ft_beacon_mouse_drag() {       # x y → 0 if handled
    [[ -z "$_FT_BEACON_GRAB" ]] && return 1
    local x=$1 y=$2 n gr gc; set -- $_FT_BEACON_GRAB; n=$1; gr=$2; gc=$3
    [[ -n "${FT_TYPE[$n]:-}" ]] || { _FT_BEACON_GRAB=""; return 1; }
    local nt=$(( y - gr )) nl=$(( x - gc )); (( nt<0 )) && nt=0; (( nl<0 )) && nl=0
    # CLAMP TO WHERE IT CAN PARK, so the ghost and the parked box are the same thing. The
    # left/top clamps above existed; the right/bottom did not — the ghost ran off past the
    # frame and the screen, the release clamped the park back inside ("snapped back"), and
    # the ring the ghost had painted out there was left behind.
    if [[ -n "${FT_BEACON_BOUND[$n]:-}" ]] && _ft_beacon_placement "$n"; then
        local _cbt _cbl _cbb _cbr
        read -r _cbt _cbl _cbb _cbr <<< "${FT_BEACON_BOUND[$n]}"
        (( nl + FT_PLACED_W - 1 > _cbr )) && nl=$(( _cbr - FT_PLACED_W + 1 )); (( nl < _cbl )) && nl=$_cbl
        (( nt + FT_PLACED_H - 1 > _cbb )) && nt=$(( _cbb - FT_PLACED_H + 1 )); (( nt < _cbt )) && nt=$_cbt
    fi
    _ft_beacon_park "$n"
    [[ "$FT_RET" == "$nt $nl" ]] && return 0                   # same cell: nothing to redraw
    # per GESTURE, not per callout — see the note at the grab. Consumed on the first real move
    # (a same-cell no-op above leaves it armed).
    local _first=${_FT_BEACON_GESTURE_NEW:-0}; _FT_BEACON_GESTURE_NEW=0
    local _vacated=${FT_BEACON_EXTENT[$n]:-}
    ft-modify "$n" parkedTop="$nt" parkedLeft="$nl"
    # A DRAG IS A MOVE, NOT A NEW FRAME. `ft_refresh` re-lays the tree, CLEARS THE SCREEN and
    # repaints every control on the page — measured at 233ms and 26 controls for a box that moved
    # one cell, which is the whole of why dragging reads as unusable. Nothing about the LAYOUT
    # changed: a callout is an overlay with a zero-size layout box, so the only stale cells on the
    # screen are the ones it just vacated. Damage those, let the engine repair exactly them, and
    # composite the overlay at its new home.
    # DAMAGE WHAT WAS DRAWN, NOT A BOUNDING BOX. The extent is box ∪ leader as one rect, and for
    # a chip whose line runs up to its target that rect is mostly BLANK cells — subtracting only
    # the new box left the leader's whole band inside the damage every single move. Profiled in
    # the run loop's own burst protocol: ~160 redundant cells refilled per move, three moves a
    # burst, `_ft_damage_fill` 1862ms of a 2100ms drag — the entire reported "insane" lag. What
    # the chip actually vacates is thin: the strip of BOX the move uncovered, the old LEADER's
    # one-cell-wide segments, and the arrowhead. Damage exactly those.
    if [[ -n "$_vacated" ]]; then
        local _oT _oL _oB _oR _r0 _r1
        # the real drawn box, not the extent bounding box
        if [[ -n "${FT_BEACON_BOX[$n]:-}" ]]; then
            read -r _oT _oL _oB _oR <<< "${FT_BEACON_BOX[$n]}"
        else
            read -r _oT _oL _oB _oR <<< "$_vacated"
        fi
        if (( _first )); then
            # the first move erases the FULL chip (interior text and all) — the ghost that
            # replaces it paints only a ring, so everything under the old interior must be
            # restored once, here
            ft_damage "$_oT" "$_oL" "$_oB" "$_oR"
        else
            # after the first move the old ink is just the GHOST'S RING — and most of the ring's
            # long rows are immediately repainted by the NEW ring one step over. Filling the full
            # old top and bottom rows cost a hit-test-per-run walk of ~41 columns twice a move,
            # measured at ~18ms per fill; the cells that are genuinely stale are the ring cells
            # the new ring does NOT cover — a few per move. The two verticals are always stale
            # (the new ones sit at different columns; the old far one lands INSIDE the hollow
            # ghost, where nothing repaints it). The long rows are stale only outside the new
            # row's span when the row is unchanged; a diagonal move falls back to whole rows.
            if (( _oB > _oT + 1 )); then
                ft_damage $(( _oT + 1 )) "$_oL" $(( _oB - 1 )) "$_oL"
                ft_damage $(( _oT + 1 )) "$_oR" $(( _oB - 1 )) "$_oR"
            fi
            local _nR=$(( nl + _oR - _oL ))
            if (( nt == _oT )); then       # horizontal move: rows unchanged, damage complements
                if (( nl > _oL )); then
                    ft_damage "$_oT" "$_oL" "$_oT" $(( nl - 1 < _oR ? nl - 1 : _oR ))
                    ft_damage "$_oB" "$_oL" "$_oB" $(( nl - 1 < _oR ? nl - 1 : _oR ))
                elif (( nl < _oL )); then
                    ft_damage "$_oT" $(( _nR + 1 > _oL ? _nR + 1 : _oL )) "$_oT" "$_oR"
                    ft_damage "$_oB" $(( _nR + 1 > _oL ? _nR + 1 : _oL )) "$_oB" "$_oR"
                fi
            else
                ft_damage "$_oT" "$_oL" "$_oT" "$_oR"
                ft_damage "$_oB" "$_oL" "$_oB" "$_oR"
            fi
        fi
        # the old leader's ink: each polyline segment is a one-cell-wide rect, the head one cell
        local _lp=${FT_BEACON_LEADER[$n]:-}
        if [[ -n "$_lp" ]]; then
            local -a _lw=($_lp); local _li _lr0 _lc0 _lr1 _lc1
            for (( _li=0; _li+3 < ${#_lw[@]}; _li+=2 )); do
                _lr0=${_lw[_li]}; _lc0=${_lw[_li+1]}; _lr1=${_lw[_li+2]}; _lc1=${_lw[_li+3]}
                if (( _lr0 == _lr1 )); then
                    ft_damage "$_lr0" $(( _lc0 < _lc1 ? _lc0 : _lc1 )) "$_lr0" $(( _lc0 > _lc1 ? _lc0 : _lc1 ))
                else
                    ft_damage $(( _lr0 < _lr1 ? _lr0 : _lr1 )) "$_lc0" $(( _lr0 > _lr1 ? _lr0 : _lr1 )) "$_lc0"
                fi
            done
        fi
    fi
    # UNDER COALESCING, RECORD AND STOP — never paint half a frame. The run loop wraps every
    # dispatch in FT_COALESCING=1, and ft_redraw_dirty defers under it, so the old path here
    # ("repair, composite, flush") degenerated mid-burst into "composite, flush": the chip painted
    # at each new position while the vacated cells were NEVER repaired until the burst drained.
    # That is the reported smear — duplicated borders trailing the chip while the mouse moves,
    # cleaned up only when it pauses ("and then the ability to drag again"). The position and the
    # damage are recorded; the burst's settle repaints ONCE with the latest position, which also
    # collapses a backlog of mouse events into one frame instead of painting every stale one.
    (( FT_COALESCING )) && return 0
    # …AND ft_redraw_dirty IS THE WHOLE FRAME. It skips overlays in its depth-ordered draw loop
    # and hands them to _ft_composite_overlays_touching — which repaints an overlay that is
    # dirty, that overlaps a control painted this pass, or that sits over a repaired damage rect
    # — and then flushes. So the `_ft_composite_overlays; ft_flush` that used to follow this line
    # (and four of its siblings in this file) was a SECOND, identical paint of every live overlay
    # on the screen, including ones nothing had touched: measured on tools/bench-drag.bash's
    # scene at one extra full callout paint and 8ms per call, and one extra paint of every other
    # callout on the page. ft_redraw_dirty's own comment prices the same mistake made one level
    # down, and ft_anim_step's says "composites overlays itself"; this file had not been told.
    # The screens are identical cell-for-cell — checked by replaying the tty stream, and gated by
    # tests/test-composite-once.bash, which counts the paints because no picture can see them.
    ft_redraw_dirty                 # FT_DAMAGE_NARROW is held on for the drag by the grab
    return 0
}
# RELEASE IS A DRAG FRAME, NOT A PAGE CHANGE. This used to call ft_refresh — clear the whole
# screen, re-lay the tree, repaint every control — as a safety blanket after narrowed repairs.
# Measured in the real run loop (FT_BURST_LOG over 30 consecutive drags): EVERY drag paid a
# ~230ms settle at 62x40, all of it that refresh, for a gesture that moved one overlay and
# changed no layout at all. On a big terminal it scales with the whole screen's area, and
# consecutive quick drags queue these refreshes up — the reported multi-second "catching up"
# freezes. What release actually has to do is exactly one more drag frame: swap the ghost ring
# for the full callout at the parked position and re-route its leader. The ghost's ring cells
# are covered by the callout's own box; the interior was restored on the first move; the leader
# is overlay ink the compositor places. Residue stays gated by test-notrace/test-residue, which
# is the honest check — a blanket refresh was hiding nothing they don't cover.
_ft_beacon_mouse_release() { [[ -z "$_FT_BEACON_GRAB" ]] && return 1
                             local _rn=${_FT_BEACON_GRAB%% *}; _FT_BEACON_GRAB=""
                             if [[ -n "${FT_TYPE[$_rn]:-}" ]]; then
                                 ft_remove_attribute "$_rn" dragging
                                 # the parked box replaces the ghost ring cell-for-cell; the
                                 # leader's new cells are the overlay's own ink. The one region
                                 # that can be stale is the ghost's ring if the final placement
                                 # SHIFTS the box (boundBox clamping) — damage the ring now so
                                 # the settle repairs it whatever the placement decides.
                                 if [[ -n "${FT_BEACON_BOX[$_rn]:-}" ]]; then
                                     local _gT _gL _gB _gR
                                     read -r _gT _gL _gB _gR <<< "${FT_BEACON_BOX[$_rn]}"
                                     ft_damage "$_gT" "$_gL" "$_gT" "$_gR"
                                     ft_damage "$_gB" "$_gL" "$_gB" "$_gR"
                                     (( _gB > _gT + 1 )) && {
                                         ft_damage $(( _gT + 1 )) "$_gL" $(( _gB - 1 )) "$_gL"
                                         ft_damage $(( _gT + 1 )) "$_gR" $(( _gB - 1 )) "$_gR"; }
                                 fi
                                 ft_dirty "$_rn"
                             fi
                             if (( FT_COALESCING )); then
                                 # the burst settle paints once; narrow repair stays on until
                                 # then so the settle repairs only what the drag touched
                                 FT_BEACON_NARROW_OFF_AFTER=1
                             else
                                 ft_redraw_dirty   # composites and flushes — see _ft_beacon_mouse_drag
                                 FT_DAMAGE_NARROW=0
                             fi
                             return 0; }

# ── Geometry ─────────────────────────────────────────────────────────────────
# _ft_beacon_rect NAME → FT_BEACON_RECT_OK + inclusive screen-cell box FT_BEACON_RECT_LEFT/T/R/B. Either
# derived from a live target (+ outset, so the frame sits OUTSIDE it) or the
# beacon's own absolute rect. FT_BEACON_RECT_OK=0 when the target has not been laid out yet
# (nothing to point at) — the caller skips the frame.
_ft_beacon_rect() {             # name
    local n=$1 t o x y w h
    FT_BEACON_RECT_OK=0
    ft_resolved_prop "$n" target ""; t=$FT_RET
    if [[ -n "$t" ]]; then
        [[ -z "${FT_ABSOLUTE_X[$t]:-}" ]] && return
        ft_resolved_prop "$n" outset 1; o=$FT_RET
        x=${FT_ABSOLUTE_X[$t]}; y=${FT_ABSOLUTE_Y[$t]}; w=${FT_MEASURED_WIDTH[$t]:-1}; h=${FT_MEASURED_HEIGHT[$t]:-1}
        FT_BEACON_RECT_LEFT=$(( x - o )); FT_BEACON_RECT_TOP=$(( y - o ))
        FT_BEACON_RECT_RIGHT=$(( x + w - 1 + o )); FT_BEACON_RECT_BOTTOM=$(( y + h - 1 + o ))
        # IF THE TARGET IS ALREADY RINGED, THE RING IS ITS VISIBLE EDGE. Another beacon's halo is
        # painted outside the target's layout box, so pointing at "the control" without it lands
        # the arrowhead ON the halo — and the halo, composited after, paints straight over the
        # head. The line then arrives at a cell with no arrow on it, which is exactly the "is that
        # a bug or a feature" confusion a decorated page produces. A ringed control's boundary is
        # its ring, so the rect being pointed at grows to include any overlay drawn around it.
        # …and ONLY a ring counts as a boundary: a frame-variant beacon whose own target IS this
        # control. The first cut grew by ANY overlapping overlay extent — and a callout CHIP
        # parked over the control qualified, so the ring beacon pointing at that control then
        # inflated to the chip's whole footprint: Box A's halo rendered the size of the text
        # callout (rows of ┃ wrapping the chip) and the chip's own leader died against it with
        # no arrowhead. Mere overlap does not make an overlay part of a control's edge; being
        # drawn AROUND it, as its ring, does.
        local _hb _hT _hL _hB _hR
        for _hb in "${!FT_BEACON_EXTENT[@]}"; do
            [[ "$_hb" == "$n" ]] && continue
            [[ -n "${FT_TYPE[$_hb]:-}" ]] || continue
            ft_resolved_prop "$_hb" variant frame; [[ "$FT_RET" == frame ]] || continue
            ft_resolved_prop "$_hb" target "";     [[ "$FT_RET" == "$t" ]] || continue
            read -r _hT _hL _hB _hR <<< "${FT_BEACON_EXTENT[$_hb]}"
            [[ -n "$_hR" ]] || continue
            (( _hT < FT_BEACON_RECT_TOP )) && FT_BEACON_RECT_TOP=$_hT; (( _hL < FT_BEACON_RECT_LEFT )) && FT_BEACON_RECT_LEFT=$_hL
            (( _hB > FT_BEACON_RECT_BOTTOM )) && FT_BEACON_RECT_BOTTOM=$_hB; (( _hR > FT_BEACON_RECT_RIGHT )) && FT_BEACON_RECT_RIGHT=$_hR
        done
    else
        [[ -z "${FT_ABSOLUTE_X[$n]:-}" ]] && return
        x=${FT_ABSOLUTE_X[$n]}; y=${FT_ABSOLUTE_Y[$n]}; w=${FT_MEASURED_WIDTH[$n]:-1}; h=${FT_MEASURED_HEIGHT[$n]:-1}
        FT_BEACON_RECT_LEFT=$x; FT_BEACON_RECT_TOP=$y; FT_BEACON_RECT_RIGHT=$(( x + w - 1 )); FT_BEACON_RECT_BOTTOM=$(( y + h - 1 ))
    fi
    (( FT_BEACON_RECT_LEFT < 0 )) && FT_BEACON_RECT_LEFT=0
    (( FT_BEACON_RECT_TOP < 0 )) && FT_BEACON_RECT_TOP=0
    (( FT_BEACON_RECT_RIGHT < FT_BEACON_RECT_LEFT )) && FT_BEACON_RECT_RIGHT=$FT_BEACON_RECT_LEFT
    (( FT_BEACON_RECT_BOTTOM < FT_BEACON_RECT_TOP )) && FT_BEACON_RECT_BOTTOM=$FT_BEACON_RECT_TOP
    FT_BEACON_RECT_OK=1
}
# What subtree to repaint to ERASE the beacon: the target's enclosing form (so a
# transient locator wipes clean over exactly the controls it framed), else root.
_ft_beacon_ground() {           # name → FT_RET (a subtree root to redraw)
    local n=$1 t; ft_resolved_prop "$n" target ""; t=$FT_RET
    if [[ -n "$t" ]]; then _ft_enclosing_form_of "$t"; [[ -n "$FT_RET" ]] && return; fi
    FT_RET=${FT_ROOT:-}
}

# ── Colour ───────────────────────────────────────────────────────────────────
# ONE ALPHA BLEND, FOUR USERS: the shimmer effect, exit=fade, the arrow's default outline
# colour, and a fading outline. All four are "PERCENT of the way from the ground to the ink",
# which is what an alpha IS, and all four were the same three lines of arithmetic — the shimmer
# open-coded it and the arrow had it in a bigarrow-private `_ft_bigarrow_mix`. docs/transitions.md
# §6a called that out and predicted the deletion; this is it.
#
# Both ends go through ft_sgr_rgb and the result back through ft_rgb_sgr, so it lands in
# whatever colour depth is in force. If an end is a colour that cannot be read — a bare
# attribute, mono mode — the caller decides: pass a SUBSTITUTE triple and it is used (the
# shimmer has always preferred a plausible ghost to no ghost), pass none and this fails so the
# caller can keep its solid colour, because a wrong colour is worse than no blend.
_ft_alpha_blend() {             # groundSgr inkSgr pct [inkFallbackRGB] [groundFallbackRGB] → FT_RET; 1 if unreadable
    local gr gg gb ir ig ib
    if ft_sgr_rgb "$2" 38; then ir=$FT_RGB_RED; ig=$FT_RGB_GREEN; ib=$FT_RGB_BLUE
    elif [[ -n "${4:-}" ]]; then IFS=, read -r ir ig ib <<< "$4"
    else FT_RET=""; return 1; fi
    if ft_sgr_rgb "$1" 48; then gr=$FT_RGB_RED; gg=$FT_RGB_GREEN; gb=$FT_RGB_BLUE
    elif [[ -n "${5:-}" ]]; then IFS=, read -r gr gg gb <<< "$5"
    else FT_RET=""; return 1; fi
    ft_rgb_sgr $(( gr + (ir-gr)*$3/100 )) $(( gg + (ig-gg)*$3/100 )) $(( gb + (ib-gb)*$3/100 )) 38
}
# The pulse ramp: the theme's --beacon-N (or --locator-N) triple, read through
# the cascade off the beacon so a stylesheet can override it per instance/class.
# Returns a BOLD, bright SGR for phase $1. No colour is hardcoded that suits only
# one theme — an unthemed run still lands on the palette accent.
_ft_beacon_pulsecolor() {       # name phase → FT_RET
    local n=$1 idx=$(( ($2 / 4) % 3 + 1 )) v=""
    if [[ -n "${_FT_CSS_LOADED:-}" ]]; then
        ft_style "$n" "--beacon-$idx";  v=$FT_RET
        [[ -z "$v" ]] && { ft_style "$n" "--locator-$idx"; v=$FT_RET; }
    fi
    if [[ -n "$v" ]]; then
        ft_color_sgr "$v" 38; [[ -n "$FT_RET" ]] && { FT_RET="${FT_RET%m};1m"; return; }
    fi
    FT_RET="${FT_COLOR_TEXT_ACCENT:-$FT_ANSI_BOLD}"$'\e[1m'
}
# The steady base colour when an effect does not cycle colour: an explicit
# `beacon::border`/`beacon::number` rule wins; otherwise ramp colour 1.
_ft_beacon_basecolor() {        # name pe → FT_RET
    _ft_css_pe_or "$1" "$2" ""; [[ -n "$FT_RET" ]] && return
    _ft_beacon_pulsecolor "$1" 0
}

# ── Effect envelope ──────────────────────────────────────────────────────────
# For a phase, decide: is the beacon VISIBLE this frame, its colour, and a small
# vertical offset. Effects are named and real, driven off the lap fraction so
# they never depend on the frame rate:
#   pulse — colour breathes through the ramp (always visible).       [default]
#   blink — toggles off for the back half of every lap (the "downcycle").
#   bob   — hops up one row for the back half of the lap (a number badge only).
#   none  — steady base colour, no motion (static:… is an alias).
# Sets FT_BEACON_EFFECT_VISIBLE (0/1), FT_BEACON_EFFECT_SGR, and FT_BEACON_EFFECT_DY (rows to shift up, 0 or 1).
_ft_beacon_effect() {           # name pe phase → FT_BEACON_EFFECT_VISIBLE/FT_BEACON_EFFECT_SGR/FT_BEACON_EFFECT_DY
    local n=$1 pe=$2 ph=$3 eff
    ft_resolved_prop "$n" effect pulse; eff=$FT_RET
    local lap=$(( ph % FT_BEACON_PERIOD )) half=$(( FT_BEACON_PERIOD / 2 ))
    FT_BEACON_EFFECT_VISIBLE=1; FT_BEACON_EFFECT_DY=0
    case "$eff" in
        blink)
            (( lap >= half )) && FT_BEACON_EFFECT_VISIBLE=0
            _ft_beacon_basecolor "$n" "$pe" ;;
        bob)
            (( lap >= half )) && FT_BEACON_EFFECT_DY=1
            _ft_beacon_pulsecolor "$n" "$ph" ;;
        shimmer)
            # A barely-there GHOST. Blend the outline colour toward the BACKGROUND by a LOW alpha
            # that rises and falls on a smooth bell (a sine, approximated by a parabola) across the
            # single play — fades in gently, peaks faint, fades out. Peak alpha stays well under
            # half, so it reads like a low-opacity hint of a border, never a drawn line. At the
            # ends the colour IS the background (invisible), so no on/off pop and nothing to erase
            # mid-play; the one-shot's final frame clears it.
            local len=${FT_ANIM_LENGTH[$n]:-28} peak=${FT_BEACON_SHIMMER_PEAK:-30} t bell a
            t=$(( ph % len )); (( t < 0 )) && t=0
            bell=$(( 400 * t * (len - t) / (len * len) ))     # 0→100→0 across the play
            a=$(( bell * peak / 100 ))                        # effective alpha %, 0..peak
            _ft_beacon_basecolor "$n" "$pe"; local ink=$FT_RET
            _ft_effective_bg "$n"
            # The two substitutes are this effect's own: an unreadable end still gets a ghost,
            # because a shimmer that silently does not appear is indistinguishable from a bug.
            _ft_alpha_blend "$FT_RET" "$ink" "$a" 200,200,200 20,20,20 ;;
        none|static|"")
            _ft_beacon_basecolor "$n" "$pe" ;;
        *) # pulse → colour cycle
            _ft_beacon_pulsecolor "$n" "$ph" ;;
    esac
    FT_BEACON_EFFECT_SGR=$FT_RET
}

# ── Paint ────────────────────────────────────────────────────────────────────
# Shared by the normal redraw walk AND the per-frame animation routine, so a
# beacon looks identical however it was repainted. Reads the live phase (0 when
# not animating) and paints on top at the resolved rect.
_ft_draw_beacon() {             # name
    local name=$1 variant ph
    ft_resolved_prop "$name" variant frame; variant=$FT_RET
    # -1 means NOT ANIMATING, and for one variant that is a different picture from phase 0.
    # A bigarrow's phase is a POSITION on its flight path, so phase 0 is "fully retracted,
    # about to fly in" — and ft_anim_step UNSETS the phase when a one-shot flight lands, then
    # marks the control dirty for a clean final frame. Collapsing that to 0 (which every other
    # variant is happy with, phase 0 being a perfectly good pulse phase) snapped the landed
    # arrow back to its launch position on the very next repaint. The distinction is made once,
    # here, rather than by each painter guessing from FT_ANIM_PHASE behind the caller's back.
    ph=${FT_ANIM_PHASE[$name]:--1}
    # …AND A PHASE THAT BELONGS TO SOMEONE ELSE IS NOT A FLIGHT POSITION. Routing the arrow's ink
    # through `_ft_color_override` bought it CSS `animation:` for free — a @keyframes on a beacon
    # now cycles its colour like any other control — and brought this with it: that engine arms
    # its OWN 240-frame loop on the same control, and a landed arrow then read those ticks as
    # positions on its flight path and flew in again, forever. Measured: `#a { animation: glow }`
    # on a landed arrow put it at column -34, -25, -18 on successive ticks of a colour loop.
    # The loop's owner is recorded, so ask rather than guess.
    [[ -n "${FT_CSS_ANIMATION_ON[$name]:-}" ]] && ph=-1
    # A beacon is an overlay: it paints screen-absolute, on TOP, never confined to
    # an ancestor's content box — so a frame drawn OUTSIDE a target is not clipped.
    ft_clip_reset
    _ft_beacon_rect "$name"; (( FT_BEACON_RECT_OK )) || return
    case "$variant" in
        bigarrow) _ft_beacon_paint_bigarrow "$name" "$ph" ;;   # -1 = landed
        number)   (( ph < 0 )) && ph=0; _ft_beacon_paint_number  "$name" "$ph" ;;
        callout)  (( ph < 0 )) && ph=0; _ft_beacon_paint_callout "$name" "$ph" ;;
        *)        (( ph < 0 )) && ph=0; _ft_beacon_paint_frame   "$name" "$ph" ;;
    esac
}
_ft_beacon_paint_frame() {      # name phase
    local name=$1 ph=$2 eff
    _ft_beacon_effect "$name" border "$ph"
    (( FT_BEACON_EFFECT_VISIBLE )) || return                      # blink/shimmer downcycle: paint nothing
    ft_resolved_prop "$name" effect pulse;      eff=$FT_RET
    ft_resolved_prop "$name" frameStyle solid;  local fstyle=$FT_RET
    local c=$FT_BEACON_EFFECT_SGR l=$FT_BEACON_RECT_LEFT tp=$FT_BEACON_RECT_TOP r=$FT_BEACON_RECT_RIGHT b=$FT_BEACON_RECT_BOTTOM
    local bw=$(( r - l + 1 )) i
    (( bw < 2 )) && return
    # A GHOST outline (frameStyle=dashed, or the shimmer effect): a light, DASHED, rounded box —
    # a faint suggestion of a border. Everything else gets the HEAVY rule that shouts "over here!"
    local tl tr bl br hz vt
    if [[ "$fstyle" == dashed || "$eff" == shimmer ]] && (( FT_USE_UTF8 )); then tl="╭" tr="╮" bl="╰" br="╯" hz="┈" vt="┊"
    elif (( FT_USE_UTF8 ));                              then tl="┏" tr="┓" bl="┗" br="┛" hz="━" vt="┃"
    else                                                     tl="+" tr="+" bl="+" br="+" hz="-" vt="|"; fi
    # Draw CELL BY CELL, skipping any cell a HIGHER-Z overlay covers — a callout (z=10) must NEVER
    # be painted over, not even by another beacon's outline. This is the hard guarantee (belt to
    # the composite's z-order suspenders): the ghost simply does not draw where the callout is.
    local g
    for (( i=l; i<=r; i++ )); do
        g=$hz; (( i==l )) && g=$tl; (( i==r )) && g=$tr
        _ft_beacon_cell_blocked "$name" "$tp" "$i" || ft_print_at "$tp" "$i" "$c$g$FT_COLOR_RESET"
        g=$hz; (( i==l )) && g=$bl; (( i==r )) && g=$br
        _ft_beacon_cell_blocked "$name" "$b"  "$i" || ft_print_at "$b"  "$i" "$c$g$FT_COLOR_RESET"
    done
    for (( i=tp+1; i<b; i++ )); do
        _ft_beacon_cell_blocked "$name" "$i" "$l" || ft_print_at "$i" "$l" "$c$vt$FT_COLOR_RESET"
        _ft_beacon_cell_blocked "$name" "$i" "$r" || ft_print_at "$i" "$r" "$c$vt$FT_COLOR_RESET"
    done
    # An overlay's layout box is ZERO-SIZE (position:absolute, no width/height), so the engine
    # cannot infer what it painted — it must SAY so, or removing/moving it raises no damage and
    # leaves its glyphs orphaned on screen. (This is why the ghost outline had no paint rect.)
    FT_BEACON_EXTENT[$name]="$tp $l $b $r"
    ft_publish_paint_rect "$name" "$tp" "$l" "$b" "$r"
}
# Is screen cell (r,c) covered by an overlay of HIGHER z than NAME? Then NAME must not paint it.
_ft_beacon_cell_blocked() {     # name row col → 0 (blocked) / 1 (clear)
    local self=$1 r=$2 c=$3 myz=${FT_OVERLAY_Z_ORDER[$1]:-0} o oz rect ot ol ob orr
    for o in "${!FT_OVERLAY[@]}"; do
        [[ "$o" == "$self" ]] && continue
        oz=${FT_OVERLAY_Z_ORDER[$o]:-0}; (( oz <= myz )) && continue
        rect=${FT_OVERLAY[$o]}; [[ "$rect" == 1 || -z "$rect" ]] && continue
        IFS=' ' read -r ot ol ob orr <<< "$rect"
        (( r>=ot && r<=ob && c>=ol && c<=orr )) && return 0
    done
    return 1
}
_ft_beacon_paint_number() {     # name phase
    local name=$1 ph=$2 num corner
    ft_resolved_prop "$name" number 1;        num=$FT_RET
    ft_resolved_prop "$name" corner topleft;  corner=$FT_RET
    _ft_beacon_effect "$name" number "$ph"
    (( FT_BEACON_EFFECT_VISIBLE )) || return
    local c=$FT_BEACON_EFFECT_SGR g; _ft_beacon_glyph "$num"; g=$FT_RET
    local row col
    case "$corner" in
        topright)    row=$FT_BEACON_RECT_TOP; col=$FT_BEACON_RECT_RIGHT ;;
        bottomleft)  row=$FT_BEACON_RECT_BOTTOM; col=$FT_BEACON_RECT_LEFT ;;
        bottomright) row=$FT_BEACON_RECT_BOTTOM; col=$FT_BEACON_RECT_RIGHT ;;
        center)      row=$(( (FT_BEACON_RECT_TOP + FT_BEACON_RECT_BOTTOM) / 2 )); col=$(( (FT_BEACON_RECT_LEFT + FT_BEACON_RECT_RIGHT) / 2 )) ;;
        *)           row=$FT_BEACON_RECT_TOP; col=$FT_BEACON_RECT_LEFT ;;   # topleft
    esac
    (( row -= FT_BEACON_EFFECT_DY )); (( row < 0 )) && row=0    # bob: hop up a row
    ft_print_at "$row" "$col" "$c$g$FT_COLOR_RESET"
}
# A CALLOUT: a little rounded pop-up box holding `text`, with a filled triangle
# tail (▼▲◀▶) that points AT the target — a "look here, do this" bubble. The box
# is a legible chip (themed fill); its border + pointer take the effect colour so
# they can pulse. `place`=above|below|left|right|auto (auto picks a side with room
# based on where the target sits). `calloutWidth` caps the text before it wraps.
# What a candidate box rect would bury, in NORMAL-EQUIVALENT cells: every leaf control
# (labels/fields/buttons/checkboxes/selects/…) plus a bordered container's four ring strips and
# any other overlay's published ink, each weighted by importance; off-screen cells count heavily.
# The arrow's own target is NOT excluded here — covering it is priced separately and far higher
# by `_ft_beacon_target_cover`, so the two are never confused. Drives the placement search: every
# candidate position is scored through this, ~550 times per placement.
# Scores against the TIER rects built by ft_tier_rects rather than one flat rect per control:
# what a candidate buries matters as much as how much, so a border ring and a field's empty tail
# are priced far below the text beside them. See ft-forms.bash for the machinery and each
# control's own _ft_tiers_<type> for what it declares about itself.
# WHY THERE IS NO WEIGHT GRID HERE — measured, so it is not re-attempted.
# docs/placement-cost-model.md wants per-CELL weights (text vs decoration vs padding vs empty,
# and a caret gradient). The obvious structure is a screen-sized weight grid plus a summed-area
# table: build once per placement, then any candidate's burial is four lookups regardless of its
# size. It was built, it produced byte-identical placements for all 120 corpus cases — and it is
# SLOWER, because in bash an O(screen-cells) build dwarfs what O(1) queries save:
#
#              grid    obstacles   build    230 queries    total     the loop below
#   62x40    2583 cells    17       50ms       16ms         66ms         46ms
#   171x45   7912 cells    20      155ms       19ms        174ms         42ms
#
# Per query the table really is ~2.5x cheaper; it needs ~380 queries at 62x40 (~1550 at 171x45)
# to amortise its build, and a placement makes ~230. THE FIX IS NOT A GRID, IT IS MORE RECTS:
# decompose a control into one weighted rect per tier (border ring, text span, empty tail) and
# keep this loop. The build stays O(controls) and the query stays a short walk.
_ft_beacon_overlap() {          # bt bl bw bh → FT_RET = buried content cells (+ off-screen)
    local bt=$1 bl=$2 bw=$3 bh=$4
    local bR=$(( bl+bw-1 )) bB=$(( bt+bh-1 )) area=0 j
    (( bl < 0 )) && (( area += -bl * bh ))                       # off-screen penalties
    (( bt < 0 )) && (( area += -bt * bw ))
    (( bR >= FT_COLS )) && (( area += (bR-FT_COLS+1) * bh ))
    (( bB >= FT_ROWS )) && (( area += (bB-FT_ROWS+1) * bw ))
    # THE HOTTEST LOOP IN THE FRAMEWORK. A placement scores ~550 rects against ~16 pruned
    # obstacles, so this body runs ~9000 times per step change and its SHAPE is the cost —
    # measured at 275ms of a 442ms placement. Three things earn that back:
    #   · the reject test is ONE `(( ))` with four comparisons, not two assignments plus two
    #     tests. Most rects miss, so the miss path is what matters.
    #   · the clipped area is computed only for rects that actually overlap.
    #   · a counted loop instead of `for j in "${!FT_TIER_TOP[@]}"`, which rebuilds a 16-word index
    #     list on every call.
    # WEIGHTED BY WHAT IS UNDER IT, not just how much. A covered cell of a button is a control the
    # user cannot reach; a covered cell of a paragraph is a sentence they can read around. Counting
    # both as "one cell" is why every "never cover THAT" requirement had to be bolted on as its own
    # rule — a hard-coded keylegend/statusbar exemption in the test, a separate target-cover cost, a
    # separate border assertion. One weight replaces them: cells x importance, expressed in
    # NORMAL-EQUIVALENT cells so `_BURY_COST` keeps its meaning and its calibration.
    # SUMMED IN IMPORTANCE UNITS, DIVIDED ONCE. The division used to sit inside the loop, so it
    # truncated PER OBSTACLE: a single covered cell of a `minor` control scored 30/60 = 0, and two
    # obstacles rounded away twice. That is not a rounding nicety — it is the difference between
    # "some of this is free" and "this is free", and it also makes the per-cell weight grid this is
    # about to become impossible to match exactly, because a grid necessarily sums before dividing.
    # FORWARD, AND STOP AT THE FIRST RECT BELOW THE BOX. ft_tier_rects leaves the list sorted by
    # top row precisely so this can end early: once a rect starts below the box's bottom edge, so
    # does every rect after it. This used to walk the whole list backwards, testing every rect on
    # the screen against a box six rows tall — the walk that made a heavy placement 800ms.
    local wsum=0
    for (( j = 0; j < FT_TIER_COUNT; j++ )); do
        (( FT_TIER_TOP[j] > bB )) && break
        (( FT_TIER_LEFT[j] > bR || FT_TIER_RIGHT[j] < bl || FT_TIER_BOTTOM[j] < bt )) && continue
        (( wsum += ((bR < FT_TIER_RIGHT[j]  ? bR : FT_TIER_RIGHT[j])
                  - (bl > FT_TIER_LEFT[j]   ? bl : FT_TIER_LEFT[j]) + 1) *
                   ((bB < FT_TIER_BOTTOM[j] ? bB : FT_TIER_BOTTOM[j])
                  - (bt > FT_TIER_TOP[j]    ? bt : FT_TIER_TOP[j]) + 1)
                 * FT_TIER_WEIGHT[j] ))
    done
    FT_RET=$(( area + wsum / FT_IMPORTANCE_NORMAL ))
}
# How much a NON-preferred side must save before it overrides an explicit `place`. Read it in the
# score's own unit — a buried normal-importance cell costs `_BURY_COST` (5000) — so this is
# "worth about five buried cells". Below that the author's chosen side stands; above it,
# honouring the request would cover more of the screen than the request is worth. (It was written
# when burial was 1000 a cell and read "worth 24 cells"; the number here did not move when that
# one did, so the bias quietly got five times cheaper relative to what it trades against.)
# Overridable so a test can force the extremes: 0 makes an explicit `place` no stronger than a
# suggestion (i.e. auto), a huge value makes it absolute (the old behaviour, which buries).
: "${_PLACE_BIAS:=24000}"
# Same idea for the box SHAPE: what a slim box must save before it beats the full-width one.
# Deliberately SMALL — a fraction of one buried cell (`_BURY_COST` is 5000). The rule is "open up
# when it is free, cramp the moment it is not": on a roomy screen both shapes bury nothing, so
# the wide one wins the tie and you get the short, readable box; the moment the wide one would
# actually cover something, this is nowhere near enough to buy that, and the slim shape takes
# over. (Written as "three cells" when it was 3000 against a 1000/cell burial.) Set high (12+) it started paying
# for width with a buried step-nav row, which is exactly the disruption slimming exists to
# avoid — a big screen must never be an excuse to cover a control.
# Recalibrated once burial stopped being the dominant term: at 3000 this outweighed everything
# else the search now measures, so a callout would drift far from its target rather than rewrap
# one step narrower to sit right beside it. It still breaks ties toward the wide, readable shape;
# it no longer decides placements on its own.
# FLAT, AND IT STAYS FLAT. Pricing it PER COLUMN SURRENDERED is the obvious improvement — a
# single constant cannot tell "one rung narrower" from "a third of the width" — and it is wrong,
# which is worth recording so it is not re-attempted. The narrow rungs exist to reach margins;
# charging by the column pushes the search back toward wide shapes, wide shapes need room the
# cramped screens do not have, and the leaders then go THROUGH controls to reach them. Measured
# on css-demo at 118×40, cells of leader crossing a control over all 24 steps:
#
#   flat 600 (this)   0 crossed cells        19 chips under 24 cols @84×34
#   per-column, 40    4                      25
#   per-column, 80    4                      25
#   per-column, 120   4                      19
#
# Both suites stayed green at every one of those values, which is exactly why this nearly shipped:
# the readability metric I calibrated against did not count crossings, and no assertion forbids
# them (they are traded, not banned). A cheaper chip is not worth a line drawn through the page —
# the standing rule from every screenshot review. Instrument the term you are trading AGAINST.
: "${_NARROW_BIAS:=600}"
# A CALLOUT WITHOUT A LINE IS A CALLOUT THAT POINTS AT NOTHING.
#
# The leader lives in the gap between the box and its target, so how long it is IS a property
# of where the box was put — and the scorer had no opinion about it. Worse, it actively closed
# the gap: `extra` (the step-away from the target) was the only thing that opens one, and it was
# penalised, so every candidate that could hug the target did. Measured across the ten css-demo
# pages: five of ten callouts drew a leader of two cells or fewer, one of them zero. A box
# sitting flush against its target with a single stub of line between them does not read as
# "this box is about that thing" — it reads as a box that happens to be nearby, which is exactly
# the complaint. Placement that leaves no room for a line is BAD PLACEMENT, so it is scored as
# such here rather than patched at draw time, where the position is already decided.
#
# TIERED, because "short" and "absent" are not the same defect.
#
# No line at all is unshippable: the box just sits near the target saying nothing about it, so
# that outranks even an explicit `place=` (_PLACE_BIAS). A line that is merely SHORT is a
# lesser sin than moving a callout to a side its author did not ask for, so it is charged well
# below the bias and only wins where the side is free to change anyway.
#
# Neither can make a cramped screen worse — the property that matters. When NO side can fit a
# leader every candidate carries the same charge, it cancels, and the preferred side wins
# exactly as before. It only ever reorders when some other side genuinely has the room.
#
# Both stay below a corridor crossing (_CROSS_COST): a line that skewers a control is worse than
# a short one, and no amount of leader is worth spearing something to get it.
#
# This is also what the box distance reserves (see hgap/vgap), so the IDEAL position on every
# side already satisfies it. That matters: the scorer then never has to move a callout off the
# side its author asked for in order to find a line — the two requirements stopped competing
# once the real cause (vertical placements reserving no room at all) was fixed.
: "${_MIN_LEADER:=3}"            # cells of visible line below which it stops reading as a leader
: "${_SHORT_LEADER_COST:=3000}"  # …charged per cell short of that
: "${_NO_LEADER_COST:=40000}"    # …and a flat charge on top when there is no line at all
# A LEADER CROSSING AND A BURIED CELL ARE THE SAME HARM, MEASURED IN THE SAME UNIT: one cell of a
# control the callout obscured. The box obscures by covering it, the leader by drawing over it.
#
# This was 500000 against 1000 per buried cell — one crossed cell priced at FIVE HUNDRED covered
# ones. It was never calibrated, because when it was chosen the measured leader-crossing count
# across all 26 demo callouts was ZERO: the term could not fire, so its magnitude was never
# tested. Once placements got tight it started firing and then decided everything. Measured on
# page 3 step 2 at 136×39: the placer covered 82 cells of the key legend and status bar rather
# than let a thin line cross 4 cells — while a position that covered NOTHING sat available.
#
# So a crossing stays worse per cell — a line through a control reads as a rendering fault, not
# as an overlay — but within the same order of magnitude. Swept over the whole demo (104
# placements: 10 pages × every step × four REAL screen sizes), counting cells the box covers,
# how many of those are the docked chrome, and cells the drawn leader crosses:
#
#   cross   buried  chrome (worst/where)   leader crossings (worst/where)
#   500000    2930  1749 (132 in 16)         2 (1 in  2)   ← was: 16 placements wipe the legend
#    30000    1519   257 (132 in  5)        36 (4 in 14)
#    10000    1454    77 ( 39 in  3)        40 (4 in 15)
#     5000    1454    77 ( 39 in  3)        66 (4 in 23)   ← dominated by 10000
#     3000    1426    39 ( 39 in  1)        76 (5 in 25)   ← chosen
#
# 3000 is the first value at which the box stops covering the docked chrome ANYWHERE it had a
# choice: the one placement left is 80×30, where every side buries ≥39 cells because the app
# fills all thirty rows and the callout must go somewhere. The case that decided it is page 4
# step 2 at 95×34 — a position covering NOTHING was available and lost to one covering 14 cells
# of the key legend, purely because its leader clipped 4 cells. Hiding a chunk of the app's
# permanent UI is a far louder defect than a thin line crossing four characters.
#
# The cost is 36 more crossed cells spread over 10 more placements, none worse than 5 cells.
: "${_CROSS_COST:=3000}"
# The corridor between box and target holds the leader, but it is NOT all line: the arrowhead
# sits `apad` cells clear of the target, and the exit starts one cell off the box, so the drawn
# run is the corridor MINUS (apad+1) on either axis. Charging against the raw corridor is the
# mistake that hid this: `hgap` is apad+3, so every left/right placement already cleared a
# three-cell corridor minimum while drawing two cells of actual line — the measurement passed
# and the screen still showed a stub. What the eye counts is what gets charged.
#
# A function rather than two copies of the arithmetic: both scoring passes have to charge this
# identically or the sweep would optimise for something phase 1 never measured.
# (A forced-bend term and a short-leader term used to live here as `_ft_beacon_bend_cost` /
# `_BEND_COST` and `_ft_beacon_leader_cost`, from when the search scored a MODEL of the leader.
# Both were superseded when the search moved to judging the real routed line: a forced turn is
# priced by the candidate generator in the judge's own currency (`_TURN_COST`, see `_cand`), and
# a short line by `FT_LEADER_SCORE_SHORT` inside `_ft_beacon_score_leader`. The functions outlived their
# callers by months, and their narrative — a `pos` term, burial at 1000 a cell — described a
# scorer this file no longer has.)
# ── THE OBSTACLE LIST'S MISSING HALF ─────────────────────────────────────────
# _ft_route_obstacles walks the LAYOUT TREE, and it skips beacons outright ("empty|beacon)
# continue", ft-forms.bash) because a beacon's layout box is not what it paints — a frame's
# ring, a badge, a chip's leader and arrowhead all reach outside it, which is precisely why
# every beacon publishes FT_BEACON_EXTENT. So a router fed _ft_route_obstacles ALONE cannot
# see one cell of another overlay's ink, and both reported symptoms are that: the search
# parked a callout's arrowhead under the dashed halo of a neighbouring control and the
# compositor painted the halo over it (a leader arriving at a cell with no head on it), and
# a bigarrow drew straight through a step callout's chip.
#
# IT WAS FIXED TWICE AND MISSED ONCE — the search's copy and the arrow placer's copy, while
# the draw's own cache-miss re-route kept routing blind. That third preamble is not a corner:
# a DRAGGED callout's leader never comes through the search at all, and every layout-epoch
# bump re-routes a parked one there too, so both went back through the neighbour's halo. One
# concept, one function. Every preamble that builds an obstacle list for a beacon now calls
# _ft_route_obstacles and then this, in that order.
_ft_beacon_push_overlay_ink() { # name — push every OTHER beacon's published ink as an obstacle
    local self=$1 ob obT obL obB obR
    for ob in "${!FT_BEACON_EXTENT[@]}"; do
        [[ "$ob" == "$self" ]] && continue          # our own last frame is not an obstacle
        [[ -n "${FT_TYPE[$ob]:-}" ]] || continue    # a destroyed beacon paints nothing
        read -r obT obL obB obR <<< "${FT_BEACON_EXTENT[$ob]}"
        [[ -n "$obR" ]] || continue
        # another overlay's published ink — opaque, nothing to look inside (no name)
        _ft_obstacle_push "$obT" "$obL" "$obB" "$obR" "$FT_IMPORTANCE_NORMAL" ""
    done
    return 0
}

# ── THE LEADER CONTRACT ──────────────────────────────────────────────────────
# _ft_beacon_leader BOXT BOXL BOXB BOXR APAD VPAD → the leader that box WOULD get:
#   FT_LEADER_SIDE          which side of the target the box sits on (= which way the arrowhead points)
#   FT_LEADER_ARROW_ROW/FT_LEADER_ARROW_COLUMN the arrowhead cell, parked clear of the target on that side
#   FT_LEADER_POLYLINE          the routed polyline, ending ON the arrowhead
#   FT_LEADER_TURNS / FT_LEADER_CROSSINGS / FT_LEADER_LENGTH
#
# ONE function, used by the placement search AND by the draw. That is the point of it: the
# scorer used to model the leader as a straight strip from box to target while the drawer ran an
# obstacle-avoiding router, so the two disagreed exactly when it mattered — the moment the strip
# was blocked — and the placer optimised a line nobody would ever see. A candidate is now scored
# on the polyline that will actually be painted, because it is literally the same call.
#
# The guarantees it builds in, rather than hoping the router produces them:
#   · the line LEAVES one of the four borders straight, perpendicular to it — a DEPARTURE cell one
#     step beyond the exit makes that first segment perpendicular by construction;
#   · it ARRIVES along the arrowhead's own axis — an APPROACH cell _MIN_LEADER back along that
#     axis does the same at the far end;
#   · it never crosses the callout's own box, nor the target — both are obstacles for the route;
#   · the head points at a NAMED POINT of the target — see the anchor table below.
#
# THE ANCHOR IS WHICH POINT OF THE TARGET THE ARROW POINTS AT, and it is the callout's own
# property (`anchor=`), one of the nine compass points a box has:
#
#       topLeft      topCenter      topRight
#       centerLeft   centerCenter   centerRight
#       bottomLeft   bottomCenter   bottomRight
#
# `auto` (the default) resolves to the MIDDLE OF WHICHEVER SIDE the box ended up on —
# topCenter / bottomCenter / centerLeft / centerRight. That is the pointing a person draws:
# an arrow into the middle of an edge reads as "this whole control", where one into a corner
# reads as "this corner", and a head that slid along the edge toward the box (what this used to
# do, to shorten the line) reads as neither. Two reported frames were exactly that — an arrow at
# the specimen's top-left corner instead of the middle of its left edge.
#
# centerCenter is the ONE anchor that may sit on the target: it points INTO the control rather
# than at an edge, so the head lands inside it by definition. Every other anchor keeps the head
# clear, and the leader keeps the target as a routing obstacle, so nothing crosses it.
_ft_beacon_anchor_point() {     # anchor → FT_LEADER_SIDE + FT_ANCHOR_ROW/FT_ANCHOR_COLUMN (the target cell being pointed at)
    local a=$1
    local mcx=$(( (FT_BEACON_RECT_LEFT+FT_BEACON_RECT_RIGHT)/2 )) mcy=$(( (FT_BEACON_RECT_TOP+FT_BEACON_RECT_BOTTOM)/2 ))
    case "$a" in
        topLeft)      FT_LEADER_SIDE=above; FT_ANCHOR_ROW=$FT_BEACON_RECT_TOP; FT_ANCHOR_COLUMN=$FT_BEACON_RECT_LEFT ;;
        topCenter)    FT_LEADER_SIDE=above; FT_ANCHOR_ROW=$FT_BEACON_RECT_TOP; FT_ANCHOR_COLUMN=$mcx ;;
        topRight)     FT_LEADER_SIDE=above; FT_ANCHOR_ROW=$FT_BEACON_RECT_TOP; FT_ANCHOR_COLUMN=$FT_BEACON_RECT_RIGHT ;;
        bottomLeft)   FT_LEADER_SIDE=below; FT_ANCHOR_ROW=$FT_BEACON_RECT_BOTTOM; FT_ANCHOR_COLUMN=$FT_BEACON_RECT_LEFT ;;
        bottomCenter) FT_LEADER_SIDE=below; FT_ANCHOR_ROW=$FT_BEACON_RECT_BOTTOM; FT_ANCHOR_COLUMN=$mcx ;;
        bottomRight)  FT_LEADER_SIDE=below; FT_ANCHOR_ROW=$FT_BEACON_RECT_BOTTOM; FT_ANCHOR_COLUMN=$FT_BEACON_RECT_RIGHT ;;
        centerLeft)   FT_LEADER_SIDE=left;  FT_ANCHOR_ROW=$mcy;    FT_ANCHOR_COLUMN=$FT_BEACON_RECT_LEFT ;;
        centerRight)  FT_LEADER_SIDE=right; FT_ANCHOR_ROW=$mcy;    FT_ANCHOR_COLUMN=$FT_BEACON_RECT_RIGHT ;;
        centerCenter) FT_LEADER_SIDE=center; FT_ANCHOR_ROW=$mcy;   FT_ANCHOR_COLUMN=$mcx ;;
        *)            FT_LEADER_SIDE=""; FT_ANCHOR_ROW=$mcy; FT_ANCHOR_COLUMN=$mcx ;;      # auto — caller picks the side
    esac
    return 0
}
# Where along an edge the leader leaves. Aligned with the head → exactly there, so the line is
# straight. Outside the edge entirely → the edge's MIDDLE, never its corner: a leader hooking out
# of a box's top-right corner reads as snagged on it, where one leaving the middle of the facing
# side reads as deliberate (both reported frames were corner exits). One cell clear of the ends,
# so it never draws against a `╭`, which has no stub on that side.
_ft_beacon_edge_point() {       # want lo hi → FT_RET
    local want=$1 lo=$2 hi=$3
    (( hi - lo >= 2 )) && { (( lo++ )); (( hi-- )); }
    if   (( want < lo || want > hi )); then FT_RET=$(( (lo + hi) / 2 ))
    else FT_RET=$want; fi
    return 0
}
# THE DEGENERATE CASE HAS A SECOND CHANCE. When the box ends up so entangled with its target
# that the auto anchor's own side produces no drawable line (zero length, or a head swallowed by
# the box — FT_LEADER_HEAD_INSIDE_BOX), the callout used to go silent. But a target that pokes out PAST the box
# on some other side is still cleanly pointable-at: the reported case is a chip overlapping a
# button's row range where the button's topCenter sits left of the box — an arrow off the box's
# left edge, one turn down, says everything ("come off its left side and turn downward", the
# user's own sketch). So: for anchor=auto only — a NAMED anchor is the author's word and stays
# suppressed rather than second-guessed — the other three side-midpoints are tried through the
# full contract, and the first CLEAN line (drawable, no crossings, nothing through the target,
# at most two turns) wins. Nothing clean → the honest suppression stands, recomputed so every
# LDR_* field describes the original anchor again.
_ft_beacon_leader() {           # boxT boxL boxB boxR apad vpad [anchor] → LDR_*
    _ft_beacon_leader_once "$@"
    # THERE IS NO WIDE-SCAN RETRY HERE — measured, so it is not re-attempted. Two versions were
    # built: priced (keep the cheaper FT_LEADER_SCORE), which changed nothing because a one-cell brush at
    # 3000 always beats a clean detour at 6000-plus-length; and categorical (take any clean
    # ≤2-turn line), which also changed nothing because the crossing leaders are mostly
    # STRAIGHT — collinear exit and head — and the only clean route between collinear endpoints
    # is the four-turn out-along-back, which no sane rule accepts. The place where clean
    # alternatives genuinely exist is the EXIT EXPLORATION below (a shifted exit turns a blocked
    # straight into a clean L), and that is where the clean-over-brush rule now lives.
    local _wa=${7:-auto}
    if (( FT_LEADER_HEAD_INSIDE_BOX )) && [[ "$_wa" == auto || -z "$_wa" ]]; then
        local _ra
        for _ra in topCenter bottomCenter centerLeft centerRight; do
            _ft_beacon_leader_once "$1" "$2" "$3" "$4" "$5" "$6" "$_ra"
            if (( ! FT_LEADER_HEAD_INSIDE_BOX && FT_LEADER_CROSSINGS == 0 && FT_LEADER_CROSSES_TARGET == 0 && FT_LEADER_TURNS <= 2 && FT_LEADER_LENGTH >= 1 )); then
                return 0
            fi
        done
        _ft_beacon_leader_once "$@"
    fi
    # THE HEAD STILL HAS TO SHOW. A box parked one row above its target (p2:2, dragged) put the
    # padded head cell ON the box's own bottom border, and "no room for a line" suppressed the
    # line AND the arrowhead — the callout simply stopped pointing at anything. A named anchor
    # is the author's word, so its SIDE is never second-guessed — but its padding is ours. With
    # the padding pulled to zero the head sits in the one free row, directly against the target:
    # a zero-length leader with a visible head beats a callout that points at nothing.
    if (( FT_LEADER_HEAD_INSIDE_BOX )); then
        _ft_beacon_leader_once "$1" "$2" "$3" "$4" 0 0 "$_wa"
        (( FT_LEADER_HEAD_INSIDE_BOX )) && _ft_beacon_leader_once "$@"   # still swallowed: honest suppression
    fi
    return 0
}
_ft_beacon_leader_once() {      # boxT boxL boxB boxR apad vpad [anchor] → LDR_*
    local boxT=$1 boxL=$2 boxB=$3 boxR=$4 apad=$5 vpad=$6 _anch=${7:-auto}
    local bcx=$(( (boxL+boxR)/2 )) bcy=$(( (boxT+boxB)/2 ))
    # The side is WHERE THE BOX IS, measured as how far clear of the target it sits on each axis.
    # Taking the largest keeps a box that is both above and to the left pointing the way it is
    # genuinely further out, instead of the way some fixed preference order happened to list.
    local FT_ANCHOR_ROW FT_ANCHOR_COLUMN
    _ft_beacon_anchor_point "$_anch"
    if [[ "$FT_LEADER_SIDE" == center ]]; then
        # centerCenter: the head sits ON the target's middle — the one anchor that may. The line
        # still comes from outside, so pick the approach side the box is on and let it run in.
        local _dA=$(( FT_BEACON_RECT_TOP - boxB )) _dB=$(( boxT - FT_BEACON_RECT_BOTTOM ))
        local _dL=$(( FT_BEACON_RECT_LEFT - boxR )) _dR=$(( boxL - FT_BEACON_RECT_RIGHT ))
        local _mm=$_dB; FT_LEADER_SIDE=below
        (( _dA > _mm )) && { _mm=$_dA; FT_LEADER_SIDE=above; }
        (( _dL > _mm )) && { _mm=$_dL; FT_LEADER_SIDE=left; }
        (( _dR > _mm )) && {           FT_LEADER_SIDE=right; }
        FT_LEADER_ARROW_ROW=$FT_ANCHOR_ROW; FT_LEADER_ARROW_COLUMN=$FT_ANCHOR_COLUMN
        local _ex_r _ex_c _ap_r=$FT_ANCHOR_ROW _ap_c=$FT_ANCHOR_COLUMN
        case "$FT_LEADER_SIDE" in
            above) _ap_r=$(( FT_ANCHOR_ROW - _MIN_LEADER )); _ex_r=$(( boxB+1 ))
                   _ft_beacon_edge_point "$FT_ANCHOR_COLUMN" "$boxL" "$boxR"; _ex_c=$FT_RET ;;
            below) _ap_r=$(( FT_ANCHOR_ROW + _MIN_LEADER )); _ex_r=$(( boxT-1 ))
                   _ft_beacon_edge_point "$FT_ANCHOR_COLUMN" "$boxL" "$boxR"; _ex_c=$FT_RET ;;
            left)  _ap_c=$(( FT_ANCHOR_COLUMN - _MIN_LEADER )); _ex_c=$(( boxR+1 ))
                   _ft_beacon_edge_point "$FT_ANCHOR_ROW" "$boxT" "$boxB"; _ex_r=$FT_RET ;;
            *)     _ap_c=$(( FT_ANCHOR_COLUMN + _MIN_LEADER )); _ex_c=$(( boxL-1 ))
                   _ft_beacon_edge_point "$FT_ANCHOR_ROW" "$boxT" "$boxB"; _ex_r=$FT_RET ;;
        esac
        (( _ex_r < 0 )) && _ex_r=0; (( _ex_r >= FT_ROWS )) && _ex_r=$(( FT_ROWS-1 ))
        (( _ex_c < 0 )) && _ex_c=0; (( _ex_c >= FT_COLS )) && _ex_c=$(( FT_COLS-1 ))
        (( _ap_r < 0 )) && _ap_r=0; (( _ap_r >= FT_ROWS )) && _ap_r=$(( FT_ROWS-1 ))
        (( _ap_c < 0 )) && _ap_c=0; (( _ap_c >= FT_COLS )) && _ap_c=$(( FT_COLS-1 ))
        # (A `ft_route "$_ap_r" "$_ap_c" "$_ap_r" "$_ap_c"` sat here, routing the approach cell to
        # ITSELF with the box pushed as an obstacle and the answer sent to /dev/null. It cost a
        # scan per centerCenter leader and could not affect anything: the polyline below is built
        # from the explicit waypoints, not from that route. The obstacle push/pop went with it.)
        ft_route_simplify "$_ex_r $_ex_c $_ap_r $_ap_c $FT_LEADER_ARROW_ROW $FT_LEADER_ARROW_COLUMN"; FT_LEADER_POLYLINE=$FT_RET
        local _wa=v; case "$FT_LEADER_SIDE" in left|right) _wa=h ;; esac
        _ft_beacon_poly_stats "$FT_LEADER_POLYLINE" "$_wa"
        FT_LEADER_CROSSINGS=$FT_POLY_CROSSINGS; FT_LEADER_JOG=$FT_POLY_JOG; FT_LEADER_TURNS=$FT_POLY_TURNS; FT_LEADER_LENGTH=$FT_POLY_LENGTH
        # THE SAME HEAD RULE AS EVERY OTHER ANCHOR. This set FT_LEADER_HEAD_INSIDE_BOX=0 unconditionally, on the
        # reasoning that centerCenter's head belongs inside the TARGET — true, and beside the
        # point: the field means "swallowed by its own BOX". Drag a centerCenter callout over the
        # thing it points at and the head lands inside the chip, where the draw painted an arrow
        # glyph in the middle of its own text with no line to it — the same incoherence the
        # contract suppresses for every other anchor ("better to say nothing than to say it
        # incoherently"). Found by tests/test-leader-table.bash the moment centerCenter was added
        # to its grid: six of sixty-four geometries.
        FT_LEADER_HEAD_INSIDE_BOX=0
        (( FT_LEADER_ARROW_ROW >= boxT && FT_LEADER_ARROW_ROW <= boxB && FT_LEADER_ARROW_COLUMN >= boxL && FT_LEADER_ARROW_COLUMN <= boxR )) && FT_LEADER_HEAD_INSIDE_BOX=1
        # centerCenter's line ends inside the target by design, so it never owes the crossing
        # charge — but the field must still be SET, or the next candidate scores against the
        # previous one's leftover (the FT_RET-leak shape of bug, one field over).
        FT_LEADER_CROSSES_TARGET=0
        FT_LEADER_HUG=0
        return 0
    fi
    if [[ -z "$FT_LEADER_SIDE" ]]; then          # auto: the side the box is furthest clear on…
        local dA=$(( FT_BEACON_RECT_TOP - boxB )) dB=$(( boxT - FT_BEACON_RECT_BOTTOM ))
        local dL=$(( FT_BEACON_RECT_LEFT - boxR )) dR=$(( boxL - FT_BEACON_RECT_RIGHT ))
        local m=$dB; FT_LEADER_SIDE=below
        (( dA > m )) && { m=$dA; FT_LEADER_SIDE=above; }
        (( dL > m )) && { m=$dL; FT_LEADER_SIDE=left; }
        (( dR > m )) && {        FT_LEADER_SIDE=right; }
        case "$FT_LEADER_SIDE" in                # …then the MIDDLE of that side
            above) _ft_beacon_anchor_point topCenter ;;
            below) _ft_beacon_anchor_point bottomCenter ;;
            left)  _ft_beacon_anchor_point centerLeft ;;
            *)     _ft_beacon_anchor_point centerRight ;;
        esac
    fi
    # WHICH EDGE THE LINE LEAVES BY depends on where the head is RELATIVE TO THE BOX, not only
    # on which side of the target the box sits. Aligned (the head within the box's cross-span,
    # or nearly): leave by the facing edge, straight line. DIAGONAL (the head beyond the box's
    # span — a box below-right pointing at a target up-left): leaving by the facing edge made
    # the line exit the box's side, hug its corner, and thread whatever sat en route — the
    # "crazy routing" the user sketched the correction for. Their sketch is the natural pen
    # stroke: leave by the PERPENDICULAR edge nearest the head, AT THE APPROACH's column (or
    # row), so the whole leader is one leg out of the box, one bend at the approach, and the
    # final leg straight into the head along its axis.
    #
    # A DIAGONAL head has TWO honest one-bend exits, and which is cleaner depends on what
    # happens to sit in each dog-leg — something this geometry cannot know. A box below-right
    # of its target can leave by its TOP edge (up, then across into the head) or by its FACING
    # edge (across, then up into the head); the first brushes whatever sits beside the target,
    # the second threads the empty band under it, or vice versa on another page. So the
    # diagonal branches ALSO record the alternative exit (ex2/dp2/ap2), both get routed, and
    # the cheaper polyline wins, priced in the judge's own currency (FT_POLY_PRICE). One extra route
    # on diagonal candidates only; a dirty aligned head explores other exits further down.
    #
    # THE DIAGONAL BEND CLAMPS TO THE NEAREST END OF THE EDGE, never the middle. These exits
    # bend AT the exit point and run straight into the head, so the exit must sit on the HEAD'S
    # side of the span. The middle fallback (`_ft_beacon_edge_point`, right for a plain facing
    # exit, where mid-edge reads deliberate) is wrong here: at 62×42 an anchored centerRight
    # head below the box got its bend column clamped to the edge's MIDDLE — which was the
    # target's own centre column — so the approach cell landed INSIDE the target, the honest
    # drop-and-turn became unroutable, and a forty-cell wrap around the screen won by default.
    local ex_r ex_c dp_r dp_c ap_r ap_c
    local _diag=0 ex2_r=0 ex2_c=0 dp2_r=0 dp2_c=0 ap2_r=0 ap2_c=0
    # THE APPROACH SHORTENS PAST AN OBSTACLE. The approach cell sits _MIN_LEADER back along the
    # head's axis — and when a sibling control sits that close beside the target (the Bold
    # checkbox, two cells from the select), the full offset lands the approach ON it, so every
    # exit was forced to cross it. A person bends in the gap that exists; so does this now:
    # the offset pulls in (3 → 2 → 1) until the approach cell is free. The final leg into the
    # head stays axis-aligned whatever the offset.
    # …AND THE SHRINK IS GONE, NOT MERELY BOUNDED. Pulling the approach in to ONE cell put the
    # last corner directly against the arrowhead, so the line visibly entered the head from the
    # side — a ▼ fed by a horizontal run ("why is the line entering the arrow on the side of the
    # arrow!? That should NEVER happen"). The shrink existed for a sibling sitting in the
    # approach cell; the ruling is that a straight stem through whatever is there beats any
    # dogleg at the head, and a crossing is priced, so the stem always keeps its full length.
    # (The loop that walked 3 → 2 → 1 survived the ruling as `while (( _apoff > _MIN_LEADER ))`
    # under `_apoff=$_MIN_LEADER` — a body that could never execute, above a comment that
    # described the shrink in the present tense. Removed; the offset is the floor, always.)
    local _apoff=$_MIN_LEADER
    # THE FOUR SIDES ARE TWO MIRROR PAIRS, AND THEY ARE WRITTEN AS TWO.
    #
    # above/below (and left/right) differed only by a sign — which way the approach steps off the
    # head, which way `dp` steps off the exit — and by which edge they fall back to when the head
    # gives no direction. Written out four times, that made every fix a four-place edit, and this
    # engine's recurring root cause is a guard applied to one route and not its siblings: the
    # facing-edge rule had to be fixed twice, in two arms, after shipping wrong in both.
    #
    # `_step` is that sign (-1 toward the top/left, +1 toward the bottom/right). The fallback edge
    # is named `_fac_*` — THE EDGE FACING THE TARGET — and it is what each arm's `else` silently
    # was: `above` fell through to the bottom edge, `below` to the top, and neither said so. It is
    # reached when the head sits inside the box's own span, where "the edge facing the head" has
    # no answer.
    local _step _fac_r _fac_c _fac_dp
    case "$FT_LEADER_SIDE" in
        above|below)
               if [[ "$FT_LEADER_SIDE" == above ]]; then FT_LEADER_ARROW_ROW=$(( FT_BEACON_RECT_TOP-1-vpad )); _step=-1
               else                                FT_LEADER_ARROW_ROW=$(( FT_BEACON_RECT_BOTTOM+1+vpad )); _step=1; fi
               FT_LEADER_ARROW_COLUMN=$FT_ANCHOR_COLUMN
               ap_r=$(( FT_LEADER_ARROW_ROW + _step*_apoff )); ap_c=$FT_LEADER_ARROW_COLUMN
               if (( _step < 0 )); then _fac_r=$(( boxB+1 )); else _fac_r=$(( boxT-1 )); fi
               _fac_dp=$(( _fac_r - _step ))
               if (( FT_LEADER_ARROW_COLUMN < boxL || FT_LEADER_ARROW_COLUMN > boxR )); then
                   # head off one SIDE of the box: leave by that edge, bending AT the exit row so
                   # the out-leg is one straight run
                   if (( FT_LEADER_ARROW_COLUMN < boxL )); then ex_c=$(( boxL-1 )); dp_c=$(( ex_c-1 )); ex2_c=$(( boxL+1 ))
                   else                           ex_c=$(( boxR+1 )); dp_c=$(( ex_c+1 )); ex2_c=$(( boxR-1 )); fi
                   ex_r=$ap_r; (( ex_r < boxT+1 )) && ex_r=$(( boxT+1 )); (( ex_r > boxB-1 )) && ex_r=$(( boxB-1 ))
                   ap_r=$ex_r; dp_r=$ex_r
                   _diag=1           # alternative: the facing edge, then across
                   ex2_r=$_fac_r; dp2_r=$_fac_dp; dp2_c=$ex2_c
                   ap2_r=$(( FT_LEADER_ARROW_ROW + _step*_apoff )); ap2_c=$FT_LEADER_ARROW_COLUMN
               else
                   # ALIGNED: leave by the edge FACING THE HEAD — not the edge the anchor's side
                   # implies. side=above means the head is above the TARGET; it says nothing about
                   # where the BOX is. A box dragged BELOW its target with anchor=topLeft exited its
                   # bottom edge, away from the head, and the router's only way back was straight up
                   # through the callout's own box (p2:2, "pure nonsense").
                   ex_c=$FT_LEADER_ARROW_COLUMN
                   (( ex_c < boxL+1 )) && ex_c=$(( boxL+1 )); (( ex_c > boxR-1 )) && ex_c=$(( boxR-1 ))
                   if   (( FT_LEADER_ARROW_ROW < boxT )); then ex_r=$(( boxT-1 )); dp_r=$(( ex_r-1 ))
                   elif (( FT_LEADER_ARROW_ROW > boxB )); then ex_r=$(( boxB+1 )); dp_r=$(( ex_r+1 ))
                   else                             ex_r=$_fac_r;      dp_r=$_fac_dp; fi
                   dp_c=$ex_c
               fi ;;
        *)     # left|right — the same shape transposed
               if [[ "$FT_LEADER_SIDE" == left ]]; then FT_LEADER_ARROW_COLUMN=$(( FT_BEACON_RECT_LEFT-1-apad )); _step=-1
               else                               FT_LEADER_ARROW_COLUMN=$(( FT_BEACON_RECT_RIGHT+1+apad )); _step=1; fi
               FT_LEADER_ARROW_ROW=$FT_ANCHOR_ROW
               ap_c=$(( FT_LEADER_ARROW_COLUMN + _step*_apoff )); ap_r=$FT_LEADER_ARROW_ROW
               if (( _step < 0 )); then _fac_c=$(( boxR+1 )); else _fac_c=$(( boxL-1 )); fi
               _fac_dp=$(( _fac_c - _step ))
               if (( FT_LEADER_ARROW_ROW < boxT || FT_LEADER_ARROW_ROW > boxB )); then
                   # head ABOVE or BELOW the box: leave by that edge, bending AT the exit column
                   if (( FT_LEADER_ARROW_ROW < boxT )); then ex_r=$(( boxT-1 )); dp_r=$(( ex_r-1 )); ex2_r=$(( boxT+1 ))
                   else                           ex_r=$(( boxB+1 )); dp_r=$(( ex_r+1 )); ex2_r=$(( boxB-1 )); fi
                   ex_c=$ap_c; (( ex_c < boxL+1 )) && ex_c=$(( boxL+1 )); (( ex_c > boxR-1 )) && ex_c=$(( boxR-1 ))
                   ap_c=$ex_c; dp_c=$ex_c
                   _diag=1           # alternative: out the edge on the APPROACH's side, then across
                   ap2_c=$(( FT_LEADER_ARROW_COLUMN + _step*_apoff )); ap2_r=$FT_LEADER_ARROW_ROW
                   if (( _step < 0 ? ap2_c < boxL : ap2_c > boxR )); then
                       if (( _step < 0 )); then ex2_c=$(( boxL-1 )); else ex2_c=$(( boxR+1 )); fi
                       dp2_c=$(( ex2_c + _step ))
                   else
                       ex2_c=$_fac_c; dp2_c=$_fac_dp
                   fi
                   dp2_r=$ex2_r
               else
                   ex_r=$FT_LEADER_ARROW_ROW                      # facing-edge rule, see the vertical arm
                   (( ex_r < boxT+1 )) && ex_r=$(( boxT+1 )); (( ex_r > boxB-1 )) && ex_r=$(( boxB-1 ))
                   if   (( FT_LEADER_ARROW_COLUMN < boxL )); then ex_c=$(( boxL-1 )); dp_c=$(( ex_c-1 ))
                   elif (( FT_LEADER_ARROW_COLUMN > boxR )); then ex_c=$(( boxR+1 )); dp_c=$(( ex_c+1 ))
                   else                             ex_c=$_fac_c;      dp_c=$_fac_dp; fi
                   dp_r=$ex_r
               fi ;;
    esac
    # THE DIAGONAL BEND'S CLOSING LEG IS AN ASSUMPTION, AND IT HAS TO BE CHECKED. The bend-at-
    # the-exit shape ("one leg out of the box, one bend, one straight run into the head") pins
    # the approach to the EXIT's row/column — and the straight run from that bend to the head is
    # never routed, on the belief that nothing sits along it. When the TARGET ITSELF lies
    # between (a box dragged below-right of its target, anchor=topLeft: the bend lands level
    # with the box and the "straight run" climbs twelve cells THROUGH the target's own border
    # to reach the head — the reported p2:2 line, the user's sketch of the correct one is the
    # loop this enables). One crossing test on the closing leg; dirty ⇒ the approach goes back
    # to the head's own offset and the ROUTER earns the path — its outward scan finds the
    # clean S around the target two candidates in.
    local _recover_scan=$_LEADER_SCAN
    if (( _diag )); then
        # …MINUS THE HEAD CELL. The leg ends ON the arrowhead cell, and when that cell sits on a
        # control (page 1's caption, "…and ▲one of them") it is a crossing every candidate pays
        # alike — it said nothing about the leg, yet it made every closing leg read as dirty, so
        # the wide recovery fired and a clean one-bend line (4 ring cells along the frame's `═`)
        # came back with three turns and lost to a line through two buttons. Score the head cell
        # alone and take it out.
        # "Dirty" is INK crossed (FT_ROUTE_HARD): a leg along a frame's ring is not dirty.
        _ft_route_score "$ap_r $ap_c $FT_LEADER_ARROW_ROW $FT_LEADER_ARROW_COLUMN"; local _leg_hard=$FT_ROUTE_HARD
        _ft_route_score "$FT_LEADER_ARROW_ROW $FT_LEADER_ARROW_COLUMN $FT_LEADER_ARROW_ROW $FT_LEADER_ARROW_COLUMN"
        if (( _leg_hard - FT_ROUTE_HARD > 0 )); then
            case "$FT_LEADER_SIDE" in
                above) ap_r=$(( FT_LEADER_ARROW_ROW-_apoff )); ap_c=$FT_LEADER_ARROW_COLUMN ;;
                below) ap_r=$(( FT_LEADER_ARROW_ROW+_apoff )); ap_c=$FT_LEADER_ARROW_COLUMN ;;
                left)  ap_c=$(( FT_LEADER_ARROW_COLUMN-_apoff )); ap_r=$FT_LEADER_ARROW_ROW ;;
                *)     ap_c=$(( FT_LEADER_ARROW_COLUMN+_apoff )); ap_r=$FT_LEADER_ARROW_ROW ;;
            esac
            # …and the route around the target needs the WIDE scan: the router tries the
            # corridor's INTERIOR candidates first, and with the target spanning the corridor
            # every one of them is doomed — measured on the p2:2 park, six interior candidates
            # burned the whole default budget while the clean outward column (score 41 against
            # 50039) was two slots further down the ladder. Confined to this recovery, so a
            # normal leader still pays the short scan.
            (( _FT_LEADER_JUDGING )) || _recover_scan=$_LEADER_SCAN_WIDE   # the draw pays, not the judge
        fi
    fi
    # Clamped by direct arithmetic, not a `${!v}` / `printf -v` loop. The indirection was two
    # indirect expansions and up to two printfs per variable across fourteen of them, and it
    # measured as the single largest slice of a leader evaluation — more than the routing it
    # exists to support. This runs for every candidate the search judges.
    local _mr=$(( FT_ROWS-1 )) _mc=$(( FT_COLS-1 ))
    (( ex_r  < 0 )) && ex_r=0;  (( ex_r  > _mr )) && ex_r=$_mr
    (( dp_r  < 0 )) && dp_r=0;  (( dp_r  > _mr )) && dp_r=$_mr
    (( ap_r  < 0 )) && ap_r=0;  (( ap_r  > _mr )) && ap_r=$_mr
    (( FT_LEADER_ARROW_ROW < 0 )) && FT_LEADER_ARROW_ROW=0; (( FT_LEADER_ARROW_ROW > _mr )) && FT_LEADER_ARROW_ROW=$_mr
    (( ex_c  < 0 )) && ex_c=0;  (( ex_c  > _mc )) && ex_c=$_mc
    (( dp_c  < 0 )) && dp_c=0;  (( dp_c  > _mc )) && dp_c=$_mc
    (( ap_c  < 0 )) && ap_c=0;  (( ap_c  > _mc )) && ap_c=$_mc
    (( FT_LEADER_ARROW_COLUMN < 0 )) && FT_LEADER_ARROW_COLUMN=0; (( FT_LEADER_ARROW_COLUMN > _mc )) && FT_LEADER_ARROW_COLUMN=$_mc
    if (( _diag )); then
        (( ex2_r < 0 )) && ex2_r=0; (( ex2_r > _mr )) && ex2_r=$_mr
        (( dp2_r < 0 )) && dp2_r=0; (( dp2_r > _mr )) && dp2_r=$_mr
        (( ap2_r < 0 )) && ap2_r=0; (( ap2_r > _mr )) && ap2_r=$_mr
        (( ex2_c < 0 )) && ex2_c=0; (( ex2_c > _mc )) && ex2_c=$_mc
        (( dp2_c < 0 )) && dp2_c=0; (( dp2_c > _mc )) && dp2_c=$_mc
        (( ap2_c < 0 )) && ap2_c=0; (( ap2_c > _mc )) && ap2_c=$_mc
    fi
    # ROUTE AGAINST ONLY THE OBSTACLES A LEADER COULD REACH.
    #
    # `_ft_route_score` walks EVERY obstacle rect for every segment of every candidate it scores,
    # and a blocked route scores up to FT_ROUTE_MAX_SCAN of them — so the full-list walk is the
    # innermost loop of the whole placement search, and it was measured as its largest single
    # cost. A leader lives in the neighbourhood of its box and its target, and the detour hunt is
    # bounded, so a rect further away than that bound cannot be touched by any route considered
    # here. Restricting the list to that neighbourhood is exact, not an approximation — expanded
    # by the scan bound precisely so no reachable rect is dropped and the crossing counts stay
    # true. Swapped in around the routing and restored after, since the caller owns _RT_*.
    local _pT=$boxT _pL=$boxL _pB=$boxB _pR=$boxR
    (( FT_BEACON_RECT_TOP < _pT )) && _pT=$FT_BEACON_RECT_TOP; (( FT_BEACON_RECT_LEFT < _pL )) && _pL=$FT_BEACON_RECT_LEFT
    (( FT_BEACON_RECT_BOTTOM > _pB )) && _pB=$FT_BEACON_RECT_BOTTOM; (( FT_BEACON_RECT_RIGHT > _pR )) && _pR=$FT_BEACON_RECT_RIGHT
    # THE PAD IS THE WIDEST SCAN THIS CALL WILL RUN, not the caller's FT_ROUTE_MAX_SCAN. That
    # global is still the router's default (120) here — the leader's own bound is installed a
    # few lines down — so the pad was 123 cells and the "measured saving" pruned nothing on any
    # screen narrower than that. While JUDGING only the short scan and the recovery scan run;
    # the drawn winner may also re-route around the target at _LEADER_SCAN_AROUND.
    local _pad=$_LEADER_SCAN
    (( _recover_scan > _pad )) && _pad=$_recover_scan
    (( ! _FT_LEADER_JUDGING && _LEADER_SCAN_AROUND > _pad )) && _pad=$_LEADER_SCAN_AROUND
    (( _pad += 3 ))
    (( _pT -= _pad )); (( _pL -= _pad )); (( _pB += _pad )); (( _pR += _pad ))
    # _RT_N IS PART OF THE LIST AND MUST BE PRUNED WITH IT. It is indexed in lockstep with the
    # four coordinates, so filtering them and not it silently re-points every name at a different
    # rect — the tiers would then describe one control while sitting on another's cells.
    local -a _svT=("${_RT_T[@]}") _svL=("${_RT_L[@]}") _svB=("${_RT_B[@]}") _svR=("${_RT_R[@]}") \
             _svI=("${_RT_I[@]}") _svN=("${_RT_N[@]}") _svCROSS=("${_RT_CROSS[@]}")
    local _nn=${#_RT_T[@]} _q
    _ft_obstacles_clear
    for (( _q=0; _q<_nn; _q++ )); do            # inline, not _ft_obstacle_push: per judged candidate
        (( _svB[_q] < _pT || _svT[_q] > _pB || _svR[_q] < _pL || _svL[_q] > _pR )) && continue
        _RT_T+=("${_svT[_q]}"); _RT_L+=("${_svL[_q]}"); _RT_B+=("${_svB[_q]}"); _RT_R+=("${_svR[_q]}")
        _RT_I+=("${_svI[_q]:-$FT_IMPORTANCE_NORMAL}"); _RT_N+=("${_svN[_q]:-}"); _RT_CROSS+=("${_svCROSS[_q]:-100}")
    done
    # The box is an obstacle for its own leader; the target already is one (it is a control), so
    # the route rounds both.
    _ft_obstacle_push "$boxT" "$boxL" "$boxB" "$boxR" "$FT_IMPORTANCE_NORMAL" ""
    local _sv=$FT_ROUTE_PREBUILT; FT_ROUTE_PREBUILT=1
    # A LEADER IS A SHORT POINTER, NOT A WIRE. The router will happily escape through a margin
    # twenty rows away to find a crossing-free corridor, and for a diagram connector that is the
    # right instinct — but a callout that needs one is not cleverly routed, it is badly PLACED,
    # and rescuing it here would hide that from the search. Bounding the detour hunt makes such a
    # placement score badly and lose, which is the outcome we actually want. (It is also what
    # makes judging every candidate on its real leader affordable at all: the scan is the entire
    # cost, ~9µs per rect test, and this is the same bound the draw uses so the two still agree.)
    local _svscan=$FT_ROUTE_MAX_SCAN; FT_ROUTE_MAX_SCAN=$_recover_scan
    [[ -n "${FT_BEACON_DEBUG:-}" ]] && printf 'LDRX side=%s box=%s,%s..%s,%s head=%s,%s ex=%s,%s dp=%s,%s ap=%s,%s diag=%s scan=%s\n' \
        "$FT_LEADER_SIDE" "$boxT" "$boxL" "$boxB" "$boxR" "$FT_LEADER_ARROW_ROW" "$FT_LEADER_ARROW_COLUMN" "$ex_r" "$ex_c" \
        "$dp_r" "$dp_c" "$ap_r" "$ap_c" "$_diag" "$_recover_scan" >&2
    ft_route "$dp_r" "$dp_c" "$ap_r" "$ap_c"
    local poly="$ex_r $ex_c $FT_RET $FT_LEADER_ARROW_ROW $FT_LEADER_ARROW_COLUMN" poly2=""
    if (( _diag )); then
        ft_route "$dp2_r" "$dp2_c" "$ap2_r" "$ap2_c"
        poly2="$ex2_r $ex2_c $FT_RET $FT_LEADER_ARROW_ROW $FT_LEADER_ARROW_COLUMN"
    fi
    FT_ROUTE_MAX_SCAN=$_svscan
    FT_ROUTE_PREBUILT=$_sv
    _ft_obstacle_pop
    local _wantax=v; case "$FT_LEADER_SIDE" in left|right) _wantax=h ;; esac
    ft_route_simplify "$poly"; FT_LEADER_POLYLINE=$FT_RET
    _ft_beacon_poly_stats "$FT_LEADER_POLYLINE" "$_wantax"
    FT_LEADER_CROSSINGS=$FT_POLY_CROSSINGS; FT_LEADER_JOG=$FT_POLY_JOG; FT_LEADER_TURNS=$FT_POLY_TURNS; FT_LEADER_LENGTH=$FT_POLY_LENGTH
    local _axok=$FT_POLY_AXIS_OK _lprice=$FT_POLY_PRICE
    [[ -n "${FT_BEACON_DEBUG:-}" ]] && printf 'LDR1 poly=[%s] cross=%s turns=%s price=%s\n' \
        "$FT_LEADER_POLYLINE" "$FT_POLY_CROSSINGS" "$FT_POLY_TURNS" "$FT_POLY_PRICE" >&2
    # A LINE THROUGH THE TARGET OR THROUGH ITS OWN BOX GETS ONE WIDER LOOK. With the exit and the
    # head on the same column (a box parked straight below an anchor=topCenter target), the
    # router's candidates are the straight line and Z detours ordered nearest-first — and the
    # first clean column sits just outside the target's span, further out than the short scan
    # reaches. So it drew the straight line through "Nine po|nts" and priced it honestly at
    # 60 000, having never seen the loop that costs 36 000. The wide scan runs only when the
    # first answer crosses the target or the box, and the wide answer replaces it only when the
    # one comparator says it is cheaper.
    if (( (FT_POLY_CROSSES_TARGET + FT_POLY_CROSSES_BOX) > 0 && _recover_scan < _LEADER_SCAN_AROUND && ! _FT_LEADER_JUDGING )); then
        _ft_obstacle_push "$boxT" "$boxL" "$boxB" "$boxR" "$FT_IMPORTANCE_NORMAL" ""
        local _wsvp=$FT_ROUTE_PREBUILT _wsvs=$FT_ROUTE_MAX_SCAN
        FT_ROUTE_PREBUILT=1; FT_ROUTE_MAX_SCAN=$_LEADER_SCAN_AROUND
        ft_route "$dp_r" "$dp_c" "$ap_r" "$ap_c"
        local _wpoly="$ex_r $ex_c $FT_RET $FT_LEADER_ARROW_ROW $FT_LEADER_ARROW_COLUMN"
        FT_ROUTE_PREBUILT=$_wsvp; FT_ROUTE_MAX_SCAN=$_wsvs
        _ft_obstacle_pop
        ft_route_simplify "$_wpoly"; _wpoly=$FT_RET
        local _wsv_price=$_lprice _wsv_poly=$FT_LEADER_POLYLINE _wsv_cross=$FT_LEADER_CROSSINGS _wsv_turns=$FT_LEADER_TURNS
        local _wsv_len=$FT_LEADER_LENGTH _wsv_axok=$_axok _wsv_jog=${FT_LEADER_JOG:-0}
        _ft_beacon_poly_stats "$_wpoly" "$_wantax"
        [[ -n "${FT_BEACON_DEBUG:-}" ]] && printf 'LDRW poly=[%s] cross=%s turns=%s price=%s\n' \
            "$_wpoly" "$FT_POLY_CROSSINGS" "$FT_POLY_TURNS" "$FT_POLY_PRICE" >&2
        if (( FT_POLY_PRICE < _wsv_price )); then
            FT_LEADER_POLYLINE=$_wpoly; FT_LEADER_CROSSINGS=$FT_POLY_CROSSINGS; FT_LEADER_JOG=$FT_POLY_JOG; FT_LEADER_TURNS=$FT_POLY_TURNS; FT_LEADER_LENGTH=$FT_POLY_LENGTH
            _axok=$FT_POLY_AXIS_OK; _lprice=$FT_POLY_PRICE
        else
            FT_LEADER_POLYLINE=$_wsv_poly; FT_LEADER_CROSSINGS=$_wsv_cross; FT_LEADER_TURNS=$_wsv_turns; FT_LEADER_LENGTH=$_wsv_len
            _axok=$_wsv_axok; FT_LEADER_JOG=$_wsv_jog; _lprice=$_wsv_price
        fi
    fi
    if (( _diag )); then
        # captured BEFORE the stats call: _ft_beacon_poly_stats routes through _ft_route_score,
        # which sets FT_RET to the SCORE — assigning $FT_RET afterwards stored a number where
        # the polyline belongs (the classic FT_RET clobber; it drew nothing, silently)
        ft_route_simplify "$poly2"; local _p2=$FT_RET
        _ft_beacon_poly_stats "$_p2" "$_wantax"
        [[ -n "${FT_BEACON_DEBUG:-}" ]] && printf 'LDR2 poly=[%s] cross=%s turns=%s price=%s\n' \
            "$_p2" "$FT_POLY_CROSSINGS" "$FT_POLY_TURNS" "$FT_POLY_PRICE" >&2
        # Compared by FT_POLY_PRICE — the judge's own arithmetic — so a shorter line with one brush
        # can beat a wandering clean one, exactly as the final judging would decide it.
        if (( FT_POLY_PRICE < _lprice )); then
            FT_LEADER_POLYLINE=$_p2; FT_LEADER_CROSSINGS=$FT_POLY_CROSSINGS; FT_LEADER_JOG=$FT_POLY_JOG; FT_LEADER_TURNS=$FT_POLY_TURNS; FT_LEADER_LENGTH=$FT_POLY_LENGTH
            _axok=$FT_POLY_AXIS_OK; _lprice=$FT_POLY_PRICE
        fi
    fi
    # THE EXIT IS NOT PINNED TO THE HEAD'S ROW. An aligned head used to get exactly ONE exit — the
    # facing-edge cell level with the arrowhead — and when a neighbouring control sat in that
    # corridor, the router dodged it IN PLACE: one cell up, along the obstacle, one cell back
    # down. Four turns, segments one cell long, and it reads as the line being drunk — three
    # separate screenshot reports are this one shape (the p6 bracket around Box A, the p7 hook
    # over the second checkbox, "crazy routing"). The dodge is the router doing its job from a
    # bad start, so the fix belongs where the start is chosen, exactly as the DIAGONAL branch
    # already does with its two candidate exits. When the picked line is dirty — it crosses
    # something, or bends more than twice — other exits along the SAME facing edge are tried,
    # each routed for real, and the cleanest line wins by the same comparator (axis, crossings,
    # turns, length). A clear exit row two cells over turns the four-turn dodge into the two-turn
    # Z a person draws. Only a dirty leader pays for the extra routes, and the hunt stops at the
    # first clean line.
    # …but NOT while this beacon is mid-drag: every frame's leader is torn down by the next
    # mouse-move, and the release does a full refresh that recomputes with the exploration on.
    # Exploring each transient frame measured 164ms a move against 79 — all spent on lines
    # nobody will see for more than one frame. (`name` reaches here by bash dynamic scoping from
    # the paint path; the guard requires an ACTIVE grab naming it, so a bare call — no grab, no
    # name — still explores.)
    # …AND NOT WHEN THE DIRT IS IN THE STEM. Exploring moves the EXIT; the stem (approach →
    # head) is the same cells for every exit, so a crossing that lives there cannot be explored
    # away — and since the stem stopped shrinking past a sibling (the user's ruling), a target
    # with a control beside it makes EVERY candidate's stem dirty. On css-demo page 1 that ran
    # eight futile routes per finalist and took a step change from ~350ms to ~800ms. One
    # route-score tells whether a different exit could possibly help.
    local _stem_dirt=0
    if (( FT_LEADER_CROSSINGS > 0 && FT_LEADER_TURNS <= 2 && ! _FT_LEADER_JUDGING )); then   # judge never explores
        _ft_route_score "$ap_r $ap_c $FT_LEADER_ARROW_ROW $FT_LEADER_ARROW_COLUMN"; _stem_dirt=$FT_ROUTE_CROSS   # hundredths, like FT_LEADER_CROSSINGS
    fi
    # …AND NOT WHILE JUDGING. Measured on css-demo page 1, step 3: place-judge 429ms against
    # step 2's 67ms — twelve finalists, each exploring eight exits it would never draw. The
    # judge prices each candidate's first route (pessimistic, never optimistic); the winner's
    # draw explores, so the line on screen is exactly as good as before. Same split as the
    # wide re-routes: cost follows the one line that is painted.
    if (( FT_LEADER_CROSSINGS > _stem_dirt || FT_LEADER_TURNS > 2 )) && (( ! _FT_LEADER_JUDGING )) && \
       ! { [[ -n "$_FT_BEACON_GRAB" ]] && [[ "${_FT_BEACON_GRAB%% *}" == "${name:-}" ]]; }; then
        local _xo _xer _xec _xdr _xdc _xap_r=$FT_LEADER_ARROW_ROW _xap_c=$FT_LEADER_ARROW_COLUMN _xpa
        case "$FT_LEADER_SIDE" in                 # the axis-aligned approach (diag overwrote ap_*)
            above) _xap_r=$(( FT_LEADER_ARROW_ROW - _apoff )) ;;
            below) _xap_r=$(( FT_LEADER_ARROW_ROW + _apoff )) ;;
            left)  _xap_c=$(( FT_LEADER_ARROW_COLUMN - _apoff )) ;;
            *)     _xap_c=$(( FT_LEADER_ARROW_COLUMN + _apoff )) ;;
        esac
        _ft_obstacle_push "$boxT" "$boxL" "$boxB" "$boxR" "$FT_IMPORTANCE_NORMAL" ""
        local _xsvp=$FT_ROUTE_PREBUILT _xsvs=$FT_ROUTE_MAX_SCAN
        FT_ROUTE_PREBUILT=1; FT_ROUTE_MAX_SCAN=$_LEADER_SCAN
        # +-1 FIRST: the smallest shift is the likeliest fix and reads least like a dodge. The
        # ladder began at +-2 and the corpus showed exactly what that misses — exit and head on
        # the SAME row with one control mid-run, where a one-row shift turns a four-turn
        # staircase into a plain L, and no even offset can ever find it.
        local _xstair=0; (( FT_LEADER_TURNS > 2 )) && _xstair=1
        for _xo in 1 -1 2 -2 4 -4 6 -6; do
            # +-1 exists for the STAIRCASE family only (exit and head one row apart around a
            # mid-run control). For a plain crossing a one-cell shift almost never clears the
            # control that is in the way, so paying two routes for it on every dirty leader
            # measured +100ms on a rescue page — the offsets are gated on the defect they fix.
            [[ "${_xo#-}" == 1 ]] && (( ! _xstair )) && continue
            # THE EXPLORED EXITS LEAVE BY THE EDGE FACING THE HEAD — the same rule as the main
            # branch, which this used to contradict: for side=above it hardcoded the BOTTOM edge
            # (box-above-target assumed), so a box dragged below its target explored exits on the
            # far side and its best find ran straight up through the callout's own box — and WON
            # on price, because nothing priced crossing one's own box above an ordinary crossing.
            case "$FT_LEADER_SIDE" in
                above|below)
                       _xec=$(( FT_LEADER_ARROW_COLUMN + _xo ))
                       (( _xec < boxL+1 || _xec > boxR-1 )) && continue
                       if (( FT_LEADER_ARROW_ROW < boxT )); then _xer=$(( boxT-1 )); _xdr=$(( _xer-1 ))
                       else                            _xer=$(( boxB+1 )); _xdr=$(( _xer+1 )); fi
                       _xdc=$_xec ;;
                *)     _xer=$(( FT_LEADER_ARROW_ROW + _xo ))
                       (( _xer < boxT+1 || _xer > boxB-1 )) && continue
                       if (( FT_LEADER_ARROW_COLUMN < boxL )); then _xec=$(( boxL-1 )); _xdc=$(( _xec-1 ))
                       else                            _xec=$(( boxR+1 )); _xdc=$(( _xec+1 )); fi
                       _xdr=$_xer ;;
            esac
            (( _xdr < 0 || _xdr >= FT_ROWS || _xdc < 0 || _xdc >= FT_COLS )) && continue
            ft_route "$_xdr" "$_xdc" "$_xap_r" "$_xap_c"
            _xpa="$_xer $_xec $FT_RET $FT_LEADER_ARROW_ROW $FT_LEADER_ARROW_COLUMN"
            ft_route_simplify "$_xpa"; _xpa=$FT_RET
            _ft_beacon_poly_stats "$_xpa" "$_wantax"
            # FT_POLY_PRICE, the judge's currency — a wrap that avoids one crossed cell by taking four
            # bends and forty cells of line loses here, as it would in the final judging.
            # …WITH ONE CATEGORICAL EXCEPTION, in the user's own words: "cutting through bits of
            # controls when it had a clear path" is wrong, full stop. Priced, a clean two-turn L
            # (6000 + length) always lost to a one-cell brush (3000 + length), so the clean exit
            # two columns over was found, scored, and thrown away — 49 of 107 crossing leaders
            # on the corpus had exactly that shape. So: a clean line with at most two turns
            # DISPLACES a crossing one whenever it is not a wander (no more than
            # _CLEAN_DETOUR_EXTRA cells longer). Between two cleans, or two crossers, the price
            # still decides, and the judge prices whatever line results as always.
            if (( FT_POLY_CROSSINGS == 0 && FT_POLY_TURNS <= 2 && FT_LEADER_CROSSINGS > 0 \
                  && FT_POLY_AXIS_OK && FT_POLY_LENGTH <= FT_LEADER_LENGTH + _CLEAN_DETOUR_EXTRA )); then
                FT_LEADER_POLYLINE=$_xpa; FT_LEADER_CROSSINGS=$FT_POLY_CROSSINGS; FT_LEADER_JOG=$FT_POLY_JOG; FT_LEADER_TURNS=$FT_POLY_TURNS; FT_LEADER_LENGTH=$FT_POLY_LENGTH
                _axok=$FT_POLY_AXIS_OK; _lprice=$FT_POLY_PRICE
            elif (( FT_POLY_PRICE < _lprice )); then
                FT_LEADER_POLYLINE=$_xpa; FT_LEADER_CROSSINGS=$FT_POLY_CROSSINGS; FT_LEADER_JOG=$FT_POLY_JOG; FT_LEADER_TURNS=$FT_POLY_TURNS; FT_LEADER_LENGTH=$FT_POLY_LENGTH
                _axok=$FT_POLY_AXIS_OK; _lprice=$FT_POLY_PRICE
            fi
            (( FT_LEADER_CROSSINGS == 0 && FT_LEADER_TURNS <= 2 )) && break
        done
        FT_ROUTE_PREBUILT=$_xsvp; FT_ROUTE_MAX_SCAN=$_xsvs
        _ft_obstacle_pop
    fi
    # THE ARROWHEAD MUST BE OUTSIDE THE BOX. The box is placed at a gap from the target, but a
    # clamp against the screen edge can slide it back over the very cell the head occupies — and
    # then the leader has to leave the box and come back inside it, which is where four-turn
    # leaders that end underneath their own callout came from. Reported so the search can price
    # it; nothing downstream can repair it, because by then the box is already there.
    FT_LEADER_HEAD_INSIDE_BOX=0
    (( FT_LEADER_ARROW_ROW >= boxT && FT_LEADER_ARROW_ROW <= boxB && FT_LEADER_ARROW_COLUMN >= boxL && FT_LEADER_ARROW_COLUMN <= boxR )) && FT_LEADER_HEAD_INSIDE_BOX=1
    # (A head landing on ANOTHER control's cell — "inher▲ts" — was priced as its own defect for a
    # day, at the target-cover rate. Measured and removed: the case that motivated it (css-demo
    # page 1 at 80×30) was cured by searching the home frame instead of the screen, and at any
    # cost above ~10 000 the term pushed page 1's "…and ▲one of them" — the head on a caption's
    # inter-word space, the demo's own gag — into a three-turn leader from the right. The head
    # cell is already a crossed cell of whatever it sits on, and that is the honest price.)
    # A LEADER OF ZERO LENGTH IS NOT A LEADER. When the box sits so close that its exit cell IS
    # the arrowhead cell, the polyline collapses to a single point: nothing to draw, no axis to
    # arrive along, an arrowhead sitting on the box's own edge. That is the same defect as a head
    # swallowed by the box, so it is priced the same and loses to any placement with a real line.
    # A ZERO-LENGTH LEADER USED TO COUNT AS A SWALLOWED HEAD, which suppressed line AND head. The
    # placement search still prices it (_NO_LEADER_COST) so it never WINS a placement — but a
    # box the user parked one free row above its target (p2:2, dragged) then showed nothing at
    # all. A visible head with no line, sitting in that free row against the target, is the
    # honest picture of where the box is; only a head inside the box itself is still suppressed.
    # HOW MUCH OF THE LINE LIES ACROSS THE TARGET ITSELF. Counted apart from FT_LEADER_CROSSINGS because it
    # is not the same defect: crossing some other control is a cost to be traded, while cutting
    # through the very thing the arrow points at destroys the callout's whole claim — the brief
    # for this system says "definitely not across the target (unless the screen is so small there
    # is literally no choice)", and priced at the ordinary crossing rate it was simply not true.
    # Measured on the demo's anchor page at 84×34: anchor=centerLeft put the chip in the RIGHT
    # margin and ran 30 cells of line straight through the target to reach its left edge, because
    # 30 crossings at _CROSS_COST beat the burial the left-hand alternatives paid.
    #
    # centerCenter is exempt: it names the middle, so its line ends inside the target BY DESIGN.
    FT_LEADER_CROSSES_TARGET=0
    if [[ "$_anch" != centerCenter ]]; then
        _ft_beacon_poly_in_rect "$FT_LEADER_POLYLINE" "$FT_BEACON_RECT_TOP" "$FT_BEACON_RECT_LEFT" "$FT_BEACON_RECT_BOTTOM" "$FT_BEACON_RECT_RIGHT"; FT_LEADER_CROSSES_TARGET=$FT_RET
    fi
    # …AND HOW MUCH OF IT HUGS THE BOX'S OWN BORDER. When the head lands exactly one cell past a
    # box edge, the diagonal L's cross-leg is ZERO cells and the whole "line" is a vertical run
    # one cell outside the border, overlapping the box's rows — on screen it reads as a doubled
    # border (`││`), the reported "no turn coming out into a parallel line". By raw numbers that
    # degenerate line is a PERFECT leader (straight, zero crossings, three cells — priced 3, so
    # nothing could ever outbid it) because nothing priced the adjacency. Counted here: cells of
    # any segment running parallel to and directly against a box edge while overlapping that
    # edge's span. Priced like a turn per cell, the same shortlist then prefers the box one
    # column over — whose head clears the edge and gets a real L.
    FT_LEADER_HUG=0
    local -a _hw=($FT_LEADER_POLYLINE); local _hn=${#_hw[@]} _hi _hr0 _hc0 _hr1 _hc1 _hlo _hhi
    for (( _hi=0; _hi+3<_hn; _hi+=2 )); do
        _hr0=${_hw[_hi]}; _hc0=${_hw[_hi+1]}; _hr1=${_hw[_hi+2]}; _hc1=${_hw[_hi+3]}
        if (( _hc0 == _hc1 )) && (( _hc0 == boxR+1 || _hc0 == boxL-1 )); then
            _hlo=$(( _hr0<_hr1?_hr0:_hr1 )); _hhi=$(( _hr0>_hr1?_hr0:_hr1 ))
            (( _hlo < boxT )) && _hlo=$boxT; (( _hhi > boxB )) && _hhi=$boxB
            (( _hhi >= _hlo )) && (( FT_LEADER_HUG += _hhi - _hlo + 1 ))
        elif (( _hr0 == _hr1 )) && (( _hr0 == boxB+1 || _hr0 == boxT-1 )); then
            _hlo=$(( _hc0<_hc1?_hc0:_hc1 )); _hhi=$(( _hc0>_hc1?_hc0:_hc1 ))
            (( _hlo < boxL )) && _hlo=$boxL; (( _hhi > boxR )) && _hhi=$boxR
            (( _hhi >= _hlo )) && (( FT_LEADER_HUG += _hhi - _hlo + 1 ))
        fi
    done
    # Hand the caller back the list it lent us. (The stats above ran against the pruned one on
    # purpose: every rect a leader could touch is in it, so the crossing counts are the same.)
    _RT_T=("${_svT[@]}"); _RT_L=("${_svL[@]}"); _RT_B=("${_svB[@]}"); _RT_R=("${_svR[@]}")
    _RT_I=("${_svI[@]}"); _RT_N=("${_svN[@]}"); _RT_CROSS=("${_svCROSS[@]}")
    return 0
}
# HOW MANY CELLS OF A POLYLINE LIE INSIDE A RECT — written once, asked three times.
#
# "Does this line cut through the thing it points at?" and "does it cut through its own box?" are
# the same question about different rects, and the answer was computed in three places: twice in
# `_ft_beacon_poly_stats` (FT_POLY_CROSSES_TARGET, FT_POLY_CROSSES_BOX) and once in the leader contract (FT_LEADER_CROSSES_TARGET), the third
# in a different idiom — clamp the span then test, rather than compute the overlap then test. They
# agreed, but nothing made them: this is the file's recurring failure mode (the facing-edge rule,
# the four arms, the two ghost painters) in miniature, and it guards a price of _XTGT_COST a cell.
#
# NOT a hot path, despite looking like one: measured at 40 calls per placement on the demo's
# heaviest page, against 480 for `_ft_route_score` and 403 for `_ft_beacon_overlap`. Written for
# one definition, not for speed.
_ft_beacon_poly_in_rect() {     # poly T L B R → FT_RET = cells of the polyline inside the rect
    local -a p=($1); local t=$2 l=$3 b=$4 r=$5
    local n=${#p[@]} i r0 c0 r1 c1 lo hi ov total=0
    for (( i=0; i+3 < n; i+=2 )); do
        r0=${p[i]}; c0=${p[i+1]}; r1=${p[i+2]}; c1=${p[i+3]}
        if (( r0 == r1 )); then                       # horizontal segment
            (( t <= r0 && r0 <= b )) || continue
            lo=$(( c0<c1?c0:c1 )); hi=$(( c0<c1?c1:c0 ))
            ov=$(( (hi < r ? hi : r) - (lo > l ? lo : l) + 1 ))
        else                                          # vertical segment
            (( l <= c0 && c0 <= r )) || continue
            lo=$(( r0<r1?r0:r1 )); hi=$(( r0<r1?r1:r0 ))
            ov=$(( (hi < b ? hi : b) - (lo > t ? lo : t) + 1 ))
        fi
        (( ov > 0 )) && (( total += ov ))
    done
    FT_RET=$total
}
# Crossings (of the caller's CURRENT obstacle list), turns and drawn length of a polyline —
# the three numbers every leader decision runs on, computed the same way for every candidate.
_ft_beacon_poly_stats() {       # poly [wantaxis] → FT_POLY_CROSSINGS / FT_POLY_TURNS / FT_POLY_LENGTH / FT_POLY_AXIS_OK
    _ft_route_score "$1"
    # In HUNDREDTHS of a crossing: a control cell is 100, a container's ring cell is
    # FT_TIER_DECORATION. Flooring to whole crossings here would make a line across a frame's
    # border free to the judge; the price divides by 100 instead.
    FT_POLY_CROSSINGS=$FT_ROUTE_CROSS
    # …AND HOW MANY OF THOSE CELLS ARE THE TARGET ITSELF. The obstacle list prices every rect
    # alike, so a line through the very control the arrow points at cost the same 3000 a cell as
    # brushing anything else — and the p2:2 dragged leader proved what that buys: the clean loop
    # around the target priced 21024, the line straight THROUGH it 21023, and the exploration
    # took the through line by one point. FT_LEADER_SCORE always knew about _XTGT_COST; every comparison
    # made from FT_POLY_PRICE did not. Counted here so ONE comparator prices it everywhere.
    FT_POLY_CROSSES_TARGET=0
    if [[ -n "${FT_BEACON_RECT_TOP:-}" ]]; then
        _ft_beacon_poly_in_rect "$1" "$FT_BEACON_RECT_TOP" "$FT_BEACON_RECT_LEFT" "$FT_BEACON_RECT_BOTTOM" "$FT_BEACON_RECT_RIGHT"; FT_POLY_CROSSES_TARGET=$FT_RET
    fi
    # …AND THROUGH ITS OWN BOX. boxT/boxL/boxB/boxR are the leader computation's locals, reached
    # by dynamic scope exactly as BREC_* are. A line drawn across the callout it belongs to is
    # nonsense at any price — it is priced like a line through the target.
    FT_POLY_CROSSES_BOX=0
    if [[ -n "${boxT:-}" && -n "${boxR:-}" ]]; then
        _ft_beacon_poly_in_rect "$1" "$boxT" "$boxL" "$boxB" "$boxR"; FT_POLY_CROSSES_BOX=$FT_RET
    fi
    local -a p=($1)
    local i pr="" pc="" r c dr dc last="" ax
    FT_POLY_TURNS=0; FT_POLY_LENGTH=0; FT_POLY_JOG=0
    # A JOG is a one-cell segment BETWEEN two turns — the drunk dodge: out one cell, along,
    # back one cell. The corpus counted them for years because the user hates them on sight,
    # and nothing ever priced them, so a jogging line with one crossing fewer beat a clean L
    # every time. Priced here at an extra turn's worth, in the one comparator.
    local _nseg=$(( ${#p[@]} / 2 - 1 )) _si=0
    for (( i=0; i+1 < ${#p[@]}; i+=2 )); do
        r=${p[i]}; c=${p[i+1]}
        if [[ -n "$pr" ]]; then
            dr=$(( r>pr ? r-pr : pr-r )); dc=$(( c>pc ? c-pc : pc-c ))
            (( FT_POLY_LENGTH += dr + dc ))
            (( _si++ ))
            (( dr + dc == 1 && _si > 1 && _si < _nseg )) && (( FT_POLY_JOG++ ))
            if   (( dr > 0 && dc == 0 )); then ax=v
            elif (( dc > 0 && dr == 0 )); then ax=h
            else ax=$last; fi
            [[ -n "$ax" && -n "$last" && "$ax" != "$last" ]] && (( FT_POLY_TURNS++ ))
            [[ -n "$ax" ]] && last=$ax
        fi
        pr=$r; pc=$c
    done
    # DOES IT ARRIVE ALONG THE ARROWHEAD'S AXIS? The approach cell is meant to guarantee that by
    # construction, but a degenerate diagonal (head level with the box's own edge) can collapse
    # the L so the final leg runs across the head instead of into it. A path that breaks the
    # contract must never be SELECTED over one that keeps it, whatever its other numbers.
    FT_POLY_AXIS_OK=1
    [[ -n "${2:-}" && -n "$last" && "$last" != "$2" ]] && FT_POLY_AXIS_OK=0
    # …AND ARRIVE WITH A STEM. Axis alone is not the contract: a corner one cell before the head
    # has the right axis and still reads as the line entering the arrowhead from the side. After
    # any turn, the final straight run must be at least two cells (one visible stem cell plus
    # the head) — shorter is priced exactly like the wrong axis, so it can never be SELECTED
    # over a line that keeps the contract.
    (( FT_POLY_TURNS >= 1 && ${#p[@]} >= 4 )) && {
        local _lr0=${p[${#p[@]}-4]} _lc0=${p[${#p[@]}-3]} _lr1=${p[${#p[@]}-2]} _lc1=${p[${#p[@]}-1]}
        local _lseg=$(( (_lr1 > _lr0 ? _lr1 - _lr0 : _lr0 - _lr1) + (_lc1 > _lc0 ? _lc1 - _lc0 : _lc0 - _lc1) ))
        (( _lseg < 2 )) && FT_POLY_AXIS_OK=0
    }
    # …AND ITS PRICE, IN THE JUDGE'S OWN CURRENCY. Every place that must choose between two
    # candidate polylines used to rank them lexicographically — crossings first, then turns, then
    # length — which has no notion of MAGNITUDE: a zero-crossing line that wraps forty cells
    # around the screen with four bends outranked a three-cell line that brushes one cell.
    # Measured doing exactly that (p2.s5 at 62×42: the exit exploration offered the wrap, the
    # lexicographic pick took it, and the judge — which prices the wrap 12× worse — never got a
    # say, because the contract had already thrown the good line away). One currency everywhere:
    # this is the leader slice of _ft_beacon_score_leader's arithmetic, so an internal pick and
    # the final judging cannot disagree about which line is better. An axis violation is priced,
    # not gated — effectively infinite against any real alternative, but two violations can
    # still be compared.
    FT_POLY_PRICE=$(( FT_POLY_CROSSINGS * _CROSS_COST / 100 + FT_POLY_TURNS * _TURN_COST
                 + (FT_POLY_TURNS > 2 ? (FT_POLY_TURNS - 2) * _EXTRA_TURN_COST : 0)
                 + FT_POLY_CROSSES_TARGET * (_XTGT_COST - _CROSS_COST)
                 + FT_POLY_CROSSES_BOX * (_XTGT_COST - _CROSS_COST)
                 + FT_POLY_JOG * _EXTRA_TURN_COST
                 + FT_POLY_LENGTH + (FT_POLY_AXIS_OK ? 0 : 1000000) ))
    return 0
}
# A TURN COSTS ABOUT WHAT A CROSSED CELL COSTS. In the same unit as everything else here: cells
# of a control obscured. That sounds steep for a bend until you see what a bend actually is —
# when the straight corridor is blocked and the endpoints are collinear, the router's only detour
# is out, along and back, which is FOUR turns, and it reads as the line wandering rather than
# pointing. Priced this way the search prefers to move the box (or rewrap it narrower and take a
# clear column) over accepting the detour, which is the outcome that looks right.
#
# Swept over the callout suite; the failures are leaders needing more than two turns:
#   600 → 3 failures    1200 → 2    2000 → 2    3000 → 0
# Below ~3000 a four-turn detour is cheaper than the _NARROW_BIAS of rewrapping into a free
# column, so the placer keeps choosing the wandering line.
: "${_TURN_COST:=3000}"
# …AND BENDS DO NOT ADD UP LINEARLY, because badness does not. One bend is an elbow, two is a
# dog-leg round something — both read as a line that knows where it is going. Three or four is a
# line WANDERING, and no number of bends after the second is "a bit more of the same": it is a
# different, worse thing. Priced linearly at 3000 the search made exactly that trade and it is
# what the user has now called out twice ("crazy routing", "the callout seems to be drunk").
#
# Measured, css-demo p1 s4 at 80×30 — a clean placement LOSING to a wandering one:
#   box=16,61  0 turns, 0 crossings, len 1, brushes 3 cells  → judged 21681
#   box=17,2   4 turns, 0 crossings, len 30, buries nothing  → judged 13250   ← chosen
# Three buried cells (15000) outranked four bends and thirty cells of line (12030). At four
# buried cells per extra bend the same pair scores 21681 against 37250 and the clean one wins,
# which is the outcome every screenshot of this has asked for.
: "${_EXTRA_TURN_COST:=12000}"
# A COVERED CELL OUTRANKS A BEND — the user's standing rule, stated twice from screenshots:
# "never cover a control to make a line prettier" and "it unnecessarily obscures controls when
# it could easily be raised or pushed right". At the old implicit 1000/cell, one bend (3000)
# was "worth" three covered cells, so the judge parked a box over the ▶ and Quit buttons
# (3 cells, 3000) rather than take a clean 2-turn line or a raised short-leader placement
# (both 6000). Priced above a turn, the box moves and the buttons stay visible; a 1-cell brush
# can still beat a wandering 2-turn line, which matches how the hemmed cases were accepted.
: "${_BURY_COST:=5000}"
# HOW FAR A BOX MAY EXTEND BEYOND THE FREE REGION IT WAS OFFERED. A region is a MAXIMAL EMPTY
# rectangle, so a shape one column too wide for every region is refused by all of them and the
# search falls back to its sparse target-adjacent lattice — which is how a callout ends up on a
# paragraph while a blank column sits two cells to the side. Measured on p4.s4 at 62x40: no free
# region admitted ANY of the four shapes, the fallback offered twelve positions at three distinct
# columns, and the engine buried 35 normal-equivalent cells — while a dense sweep of the SAME
# shapes found a position burying NOTHING, two columns wider than the nearest region.
#
# So a region is allowed to be a little too small, and the existing clamp — which pushes a box
# until its edge meets the region's — turns that into a box overhanging by exactly this much. An
# overhanging box no longer buries nothing by construction, so unlike every other region candidate
# it pays for what it covers, which is what keeps this from being a licence to sit on things.
# SWEPT, not chosen: 0/1/2/3/4 measured against the defect corpus AND burial together, because
# this budget trades one for the other. 1 is better than 0 on every axis at once — JOG 16→15,
# XCTRL 88→86, BENDS still 0, burial 244→176, and all 34 already-perfect placements untouched.
# Wider budgets keep buying burial with leader quality (4 gave JOG 24 and BENDS 2, and BENDS had
# been pinned at ZERO), which is the wrong trade: a callout covering two more blank cells is
# invisible, a wandering leader is not. The first value tried was 4, and it was the worst of the
# five — which is the whole argument for sweeping a constant instead of picking one.
: "${_OVERHANG:=1}"
# WHEN THE WINNER IS STILL BURIED, GO LOOKING. Weighted burial (normal-equivalent cells, the same
# number _ft_beacon_overlap returns) above which the rescue sweep runs. Measured distribution at
# 62x40: 34 of 43 placements bury 0, the bad nine bury 6-60 — so 4 separates them with margin,
# and the good placements never pay a single rescue scan.
: "${_RESCUE_AT:=4}"
# Per-shape position budget for the sweep; the stride widens until a shape fits its budget, so a
# full-screen boundBox costs the same as a cramped frame interior.
: "${_RESCUE_SCAN:=150}"
# The router's detour bound while judging and drawing leaders. Deliberately SHORT: a callout that
# needs a long escape is badly placed, and rescuing it during judging would hide that from the
# search (see the note at the ft_route call). The WIDE bound below is a second chance for a
# leader that still crosses — measured over 344 placements: 107 leaders crossed something and 49
# of those had a clean route that only a wider detour could reach. The retry is priced, not
# gated: the wide line replaces the crossing one only when FT_LEADER_SCORE — crossings, turns, extra-turn
# and length in one currency — says it is actually cheaper, so a clean-but-wandering Z never
# displaces a one-cell brush the model prefers.
: "${_LEADER_SCAN:=6}"
: "${_LEADER_SCAN_WIDE:=16}"    # the diagonal closing-leg recovery — this fires for MOST
                                # diagonal candidates on a busy page, twice each, so it must stay
                                # cheap: at 32 the css-demo's step-3 placement took 1256ms and the
                                # render golden timed out at step 2
: "${_LEADER_SCAN_AROUND:=32}"  # the re-route after a first answer THROUGH the target or own
                                # box — rare, and it must reach past a target's half-width (a box
                                # centred under an 18-wide control needs the 9th outward column)
# How many cells LONGER a clean detour may be than the crossing line it replaces. Bounds the
# categorical clean-over-brush rule so it can never trade a brush for a march across the page.
: "${_CLEAN_DETOUR_EXTRA:=12}"
# How many free regions (nearest first) the search will consider per box shape. The enumeration
# is exhaustive and redundant — a sparse screen gives ~64 maximal rectangles describing far fewer
# distinct places to stand — so this bounds the work without bounding the answer.
# MEASURED, not chosen: dumping the winning placement for all 120 page/step/size combinations at
# caps 14, 10, 8, 6 and 4 showed 10 answering identically to 14 while costing 39ms less per
# placement; 8 changes two placements and 4 changes eleven. Ten is the point where the cap stops
# being free, so it is where the cap sits.
: "${_REGION_CAP:=10}"
# NEVER SIT ON THE THING YOU ARE POINTING AT. Covering any other control is a cost to be traded;
# covering the TARGET is a contradiction — the callout hides the one thing it exists to indicate,
# and the leader then has to escape the box and come back inside it, which is where the wandering
# four-turn leaders came from. Priced far above any amount of ordinary burial so it only ever
# happens on a screen with literally nowhere else, rather than made impossible: on a small enough
# terminal something has to give, and a covered target beats no callout at all.
: "${_TARGET_COVER_COST:=100000}"
# …and the LINE across the target, which is a different (lesser) crime than the BOX sitting on it:
# a one-cell-wide leader still leaves the control readable, where a chip on top of it does not. But
# it is far worse than crossing any other control, because the target is the one thing the callout
# exists to indicate — so it is priced at four buried cells per crossed cell: enough that no amount
# of ordinary burial buys a line through the target, and still finite, so a terminal with literally
# nowhere else to go degrades instead of failing.
: "${_XTGT_COST:=20000}"
_ft_beacon_target_cover() {     # boxT boxL bw bh → FT_RET = cells of the TARGET the box covers
    local t=$1 l=$2 b=$(( $1 + $4 - 1 )) r=$(( $2 + $3 - 1 ))
    local ot=$(( t > FT_BEACON_RECT_TOP ? t : FT_BEACON_RECT_TOP )) ol=$(( l > FT_BEACON_RECT_LEFT ? l : FT_BEACON_RECT_LEFT ))
    local ob=$(( b < FT_BEACON_RECT_BOTTOM ? b : FT_BEACON_RECT_BOTTOM )) orr=$(( r < FT_BEACON_RECT_RIGHT ? r : FT_BEACON_RECT_RIGHT ))
    if (( ot > ob || ol > orr )); then FT_RET=0; else FT_RET=$(( (ob-ot+1)*(orr-ol+1) )); fi
    return 0
}
# _ft_beacon_score_leader BOXT BOXL BW BH APAD VPAD → FT_LEADER_SCORE (total) + FT_LEADER_SCORE_SHORT (the stub part)
#
# EVERY phase prices a leader through here, so "which candidate is best" is asked in one language.
# Each phase used to carry its own copy of the arithmetic — a straight-corridor overlap plus a
# flat bend charge — and those copies disagreed both with each other and with the drawing code,
# which is how a placement could win a search and then render as something nobody scored.
declare -i _FT_LEADER_JUDGING=0 # 1 while the placement search scores candidates (see below)
_ft_beacon_score_leader() {     # boxT boxL bw bh apad vpad (reads `anchor` from the caller) → FT_LEADER_SCORE
    # THE JUDGE SCORES WITH THE CHEAP ROUTE; THE DRAW GETS THE RECOVERIES. The wide re-routes
    # (a diagonal whose closing leg is dirty; a first answer through the target or the box)
    # cost up to 32 route-scores each, and a finalist pays them TWICE (both diagonal exits).
    # Run inside the judge, on a busy page, that was every finalist — css-demo page 1's step 3
    # went from ~350ms to 1256ms and the render golden timed out before the step landed. The
    # judge still prices what the cheap route finds (a through-target line carries its full
    # _XTGT_COST and loses), and only the WINNER — the one line that gets drawn — pays for the
    # better line. The judge can be pessimistic about a candidate; it cannot draw a worse one.
    _FT_LEADER_JUDGING=1
    _ft_beacon_leader "$1" "$2" $(( $1 + $4 - 1 )) $(( $2 + $3 - 1 )) "$5" "$6" "$anchor"
    _FT_LEADER_JUDGING=0
    FT_LEADER_SCORE_SHORT=0
    if (( FT_LEADER_LENGTH < _MIN_LEADER )); then
        FT_LEADER_SCORE_SHORT=$(( (_MIN_LEADER - FT_LEADER_LENGTH) * _SHORT_LEADER_COST ))
        (( FT_LEADER_LENGTH == 0 )) && (( FT_LEADER_SCORE_SHORT += _NO_LEADER_COST ))
    fi
    FT_LEADER_SCORE=$(( FT_LEADER_CROSSINGS * _CROSS_COST / 100 + FT_LEADER_TURNS * _TURN_COST + FT_LEADER_LENGTH + FT_LEADER_SCORE_SHORT
              + ${FT_LEADER_JOG:-0} * _EXTRA_TURN_COST
              + (FT_LEADER_TURNS > 2 ? (FT_LEADER_TURNS - 2) * _EXTRA_TURN_COST : 0)
              + FT_LEADER_HEAD_INSIDE_BOX * _TARGET_COVER_COST + FT_LEADER_CROSSES_TARGET * _XTGT_COST
              + FT_LEADER_HUG * _TURN_COST ))
    return 0
}
# ── Judge the finalists on the line each would really get ──────────────────────────────────
# CALLED ONLY FROM _ft_beacon_paint_callout: bash's dynamic scoping is the contract — this reads
# the caller's finalist arrays (_fT/_fL/_fBW/_fBH/_fSW/_fS), BREC_*, apad/vpad/_pref/maxw, and
# updates the caller's _bestsc/_bestT/_bestL/_bestW in place. A named block, not an API.
# Extracted so the rescue pass can re-judge a SECOND finalist set against the standing winner:
# _bestsc is not reset between calls, so the bound-skip inside makes "only replace the winner if
# a rescue beats its full score" automatic rather than a second copy of the comparison.
_ft_beacon_judge_finalists() {
    local _i _sc _dist _k2
    for _i in "${!_fT[@]}"; do
        _shape "${_fSW[_i]}"
        _ft_beacon_overlap "${_fT[_i]}" "${_fL[_i]}" "${_fBW[_i]}" "${_fBH[_i]}"
        _sc=$(( FT_RET * _BURY_COST ))
        _ft_beacon_target_cover "${_fT[_i]}" "${_fL[_i]}" "${_fBW[_i]}" "${_fBH[_i]}"
        (( _sc += FT_RET * _TARGET_COVER_COST ))
        # HOW FAR THE BOX SAT FROM ITS TARGET. Not the leader's length — a box parked in
        # the far corner can still have a short line if it happens to line up, and it
        # still reads as belonging to nothing. Rows count triple: a cell is about twice as
        # tall as it is wide, and vertical separation is what actually breaks the visual
        # link. Without this the search treated "anywhere it fits" as equally good and
        # drifted a callout to the bottom of the screen to keep a wide shape.
        # EDGE separation, not centre-to-centre. The specimen box is 47 columns wide, so
        # measuring to its centre said a callout tucked against its right-hand side was
        # 24 columns "away" — further than one parked below the whole thing — and the
        # search duly parked it below. What a reader sees is the GAP between the two.
        _dist=$(( FT_BEACON_RECT_TOP - (_fT[_i] + _fBH[_i] - 1) ))
        (( _fT[_i] > FT_BEACON_RECT_BOTTOM )) && _dist=$(( _fT[_i] - FT_BEACON_RECT_BOTTOM ))
        (( _dist < 0 )) && _dist=0
        _k2=$(( FT_BEACON_RECT_LEFT - (_fL[_i] + _fBW[_i] - 1) ))
        (( _fL[_i] > FT_BEACON_RECT_RIGHT )) && _k2=$(( _fL[_i] - FT_BEACON_RECT_RIGHT ))
        (( _k2 < 0 )) && _k2=0
        (( _sc += (_dist*3 + _k2) * 20 ))
        (( _fSW[_i] < maxw )) && (( _sc += _NARROW_BIAS ))
        # EVERY REMAINING TERM IS NON-NEGATIVE, so `_sc` is now an exact LOWER BOUND on
        # this candidate's final score: the leader can only add (crossings, turns, length,
        # a buried head) and so can the place bias. A candidate already worse than the
        # best complete answer therefore cannot win, and routing it is work done to be
        # thrown away — routing is ~7ms and everything above it is arithmetic. The
        # shortlist arrives sorted by cheap score, so the first few candidates set a tight
        # bound and most of the tail never routes. This is a bound, NOT a heuristic: it
        # picks exactly the same placement as judging all twelve.
        if (( _bestsc >= 0 && _sc >= _bestsc )); then
            [[ -n "${FT_BEACON_DEBUG:-}" ]] && printf '  #%s box=%s,%s sw=%s %sx%s cheap=%s bound=%s >= best=%s, not routed\n' \
                "$_i" "${_fT[_i]}" "${_fL[_i]}" "${_fSW[_i]}" "${_fBW[_i]}" "${_fBH[_i]}" \
                "${_fS[_i]}" "$_sc" "$_bestsc" >&2
            continue
        fi
        _ft_beacon_score_leader "${_fT[_i]}" "${_fL[_i]}" "${_fBW[_i]}" "${_fBH[_i]}" "$apad" "$vpad"
        (( _sc += FT_LEADER_SCORE ))
        [[ -n "$_pref" && "$FT_LEADER_SIDE" != "$_pref" ]] && (( _sc += _PLACE_BIAS ))
        [[ -n "${FT_BEACON_DEBUG:-}" ]] && printf '  #%s box=%s,%s sw=%s %sx%s cheap=%s turns=%s cross=%s len=%s headin=%s => %s\n' \
            "$_i" "${_fT[_i]}" "${_fL[_i]}" "${_fSW[_i]}" "${_fBW[_i]}" "${_fBH[_i]}" \
            "${_fS[_i]}" "$FT_LEADER_TURNS" "$FT_LEADER_CROSSINGS" "$FT_LEADER_LENGTH" "$FT_LEADER_HEAD_INSIDE_BOX" "$_sc" >&2
        (( _bestsc < 0 || _sc < _bestsc )) && {
            _bestsc=$_sc; _bestT=${_fT[_i]}; _bestL=${_fL[_i]}; _bestW=${_fSW[_i]}; }
    done
}

# THE DRAG GHOST, PAINTED IN ONE PLACE. A grabbed callout drags as a ghost: the border ring and
# the badge, nothing else. The interior text and the routed leader are per-frame costs a transient
# frame cannot justify — the ring is ~12 paint calls against ~200 for the full chip, and skipping
# the leader also skips rebuilding the obstacle table on every move. What a person tracks while
# dragging is WHERE the box is, which the ring shows better than a wall of text; the release
# paints the real thing, line and all.
#
# `_ft_beacon_paint_callout` reaches this from TWO places — the fast path that skips the placement
# prelude entirely, and the fall-through for a grab with no cached placement — and until now each
# carried its own copy of the ring, identical line for line except for the names of the four box
# coordinates. That is the shape of bug this file keeps producing: a fix to the ghost that lands
# on one drag and not the other.
#
# The look comes from the CASCADE, not from here: `_ft_border_glyphs` reads this control's
# borderStyle/borderWidth/borderRadius, the grab set `dragging=true`, and the class defaults say
# dashed+rounded — so `beacon:dragging { borderStyle: double }`, or an instance `borderStyle=`,
# restyles the drag ghost like any other styled thing.
_ft_beacon_paint_ghost() {      # name T L B R edgeSGR badgeGlyph badgeWidth
    local n=$1 t=$2 l=$3 b=$4 r=$5 edge=$6 nglyph=$7 numw=$8
    local w=$(( r - l + 1 )) i mid=""
    _ft_border_glyphs "$n"
    for (( i=0; i<w-2-numw; i++ )); do mid+="$BG_H"; done
    ft_print_at "$t" "$l" "${edge}${BG_TL}${nglyph}${mid}${BG_TR}${FT_COLOR_RESET}"
    for (( i=t+1; i<b; i++ )); do
        ft_print_at "$i" "$l" "${edge}${BG_V}${FT_COLOR_RESET}"
        ft_print_at "$i" "$r" "${edge}${BG_V}${FT_COLOR_RESET}"
    done
    local bot=""; for (( i=0; i<w-2; i++ )); do bot+="$BG_H"; done
    ft_print_at "$b" "$l" "${edge}${BG_BL}${bot}${BG_BR}${FT_COLOR_RESET}"
    # A ghost owns no leader, no ▶ and no extra overlay rects — it is the ring and the badge, and
    # the published footprint has to say so or the next repair looks for ink that is not there.
    unset "FT_BEACON_NEXT[$n]" "FT_BEACON_CLOSE[$n]" "FT_OVERLAY_EXTRA[$n]"
    FT_BEACON_LEADER[$n]=""
    FT_BEACON_EXTENT[$n]="$t $l $b $r"
    ft_publish_paint_rect "$n" "$t" "$l" "$b" "$r"
    FT_BEACON_BOX[$n]="$t $l $b $r"
    FT_OVERLAY[$n]="$t $l $b $r"
}
_ft_beacon_paint_callout() {    # name phase
    local name=$1 ph=$2 text place maxw
    ft_resolved_prop "$name" text ""; text=$FT_RET
    [[ -z "$text" ]] && return
    ft_resolved_prop "$name" place auto;        place=$FT_RET
    ft_resolved_prop "$name" anchor auto;       local anchor=$FT_RET
    ft_resolved_prop "$name" calloutWidth 40;   maxw=$FT_RET; (( maxw < 6 )) && maxw=6
    ft_resolved_prop "$name" arrowPadding 1;    local apad=$FT_RET   # blank cells between arrowhead & target
    # TWO BOUNDS, BECAUSE THEY ARE TWO QUESTIONS. Where does the placer LOOK (bl_*, the search
    # bound), and where may the user PUT it (the park bound, published for the drag)?
    #   · boundBox=CONTROL answers both: the author's cage, that control's interior.
    #   · Otherwise the placer searches the callout's HOME — the nearest bordered ancestor's
    #     interior (the screen for a frameless app) — and the drag may park ANYWHERE ON SCREEN.
    # The home frame was the default for everything until 2026-08-22, and the user hit it as a
    # wall while dragging: "locked to the form frame". Opening the SEARCH to the screen as well
    # was built and measured, and lost: the rescue sweep's grid re-anchored at the screen origin
    # shifted four of 43 placements at 62×40 (buried TEXT 93 → 116, the burial gate failed), and
    # at 56–68 columns 211 of 1 204 placements parked half in the 4-column margin, across the
    # frame's `║`, chopping the first letters off a field, a table and a slider row to save a
    # few cells of prose. A callout belongs to the form it annotates; the reader's hand does not.
    # Read at DRAW time so both track live geometry; rects are inclusive.
    # (The two reasons the cage once existed — erase-ability past the frame, and a free margin the
    # placer could not price — are gone regardless: repair is the damage compositor's, and a
    # bordered container's ring is now an obstacle and a tier, see _ft_route_obstacles.)
    local bl_l=0 bl_t=0 bl_r=$(( FT_COLS - 1 )) bl_b=$(( FT_ROWS - 1 )) bb
    local park_l=0 park_t=0 park_r=$(( FT_COLS - 1 )) park_b=$(( FT_ROWS - 1 ))
    ft_resolved_prop "$name" boundBox ""; bb=$FT_RET
    local caged=$bb
    if [[ -z "$bb" ]]; then
        local _anc=${FT_PARENT[$name]:-}
        while [[ -n "$_anc" ]]; do
            _ft_border "$_anc"
            (( FT_RET )) && [[ -n "${FT_ABSOLUTE_X[$_anc]:-}" ]] && { bb=$_anc; break; }
            _anc=${FT_PARENT[$_anc]:-}
        done
    fi
    if [[ -n "$bb" && -n "${FT_ABSOLUTE_X[$bb]:-}" ]]; then
        bl_l=$(( ${FT_ABSOLUTE_X[$bb]} + 1 )); bl_r=$(( ${FT_ABSOLUTE_X[$bb]} + ${FT_MEASURED_WIDTH[$bb]:-0} - 2 ))
        bl_t=$(( ${FT_ABSOLUTE_Y[$bb]} + 1 )); bl_b=$(( ${FT_ABSOLUTE_Y[$bb]} + ${FT_MEASURED_HEIGHT[$bb]:-0} - 2 ))
        [[ -n "$caged" ]] && { park_l=$bl_l; park_r=$bl_r; park_t=$bl_t; park_b=$bl_b; }
    fi
    # Published for the DRAG: the ghost must never show a position the box cannot park in. It
    # used to follow the pointer past the frame's border, then snap back inside on release —
    # "refusing to stay where I put it" — and a ring painted outside the bound is also the
    # only ink the narrowed repair has no owner for.
    FT_BEACON_BOUND[$name]="$park_t $park_l $park_b $park_r"

    # The EDGE (border + leader + arrowhead + the circled number) is the `::border` structure
    # and takes the effect colour; the interior chip is the distinct `::callout` structure.
    _ft_beacon_effect "$name" border "$ph"
    (( FT_BEACON_EFFECT_VISIBLE )) || return
    local edge=$FT_BEACON_EFFECT_SGR
    _ft_css_pe_or "$name" callout "${FT_COLOR_PANE:-}"; local chip=$FT_RET   # legible interior
    local num nglyph="" numw=0
    ft_resolved_prop "$name" number 0; num=$FT_RET
    # numw is the badge's WIDTH IN CELLS — a circled digit is one cell, but the ASCII fallback
    # "(2)" is three, and a hard-coded 1 made the ASCII top border two cells longer than the
    # box (seen as `+(2)------+` running past the right corner in a FT_USE_UTF8=0 probe).
    (( num > 0 )) && { _ft_beacon_glyph "$num"; nglyph=$FT_RET; numw=${#nglyph}; }   # drawn in the EDGE colour

    # THE GHOST NEEDS NONE OF WHAT FOLLOWS. Mid-drag, every frame's pkey differs (the drag
    # position is in it), so the cache missed and each ghost repaint ran the whole placement
    # prelude — rewrapping the text (_shape), re-deriving bounds, re-writing the caches — to
    # then draw twelve ring cells and return. Measured at 30-44ms of every drag settle, ~5× the
    # ring itself. The ghost's inputs are the drag position and the box's cached dimensions,
    # both already known; take them and go.
    if [[ -n "$_FT_BEACON_GRAB" && "${_FT_BEACON_GRAB%% *}" == "$name" ]] \
       && _ft_beacon_placement "$name"; then
        local _gt=$FT_PLACED_T _gl=$FT_PLACED_L
        if _ft_beacon_park "$name"; then set -- $FT_RET; _gt=$1; _gl=$2; fi
        local _gB=$(( _gt + FT_PLACED_H - 1 )) _gR=$(( _gl + FT_PLACED_W - 1 ))
        _ft_beacon_paint_ghost "$name" "$_gt" "$_gl" "$_gB" "$_gR" "$edge" "$nglyph" "$numw"
        return
    fi

    local tcx=$(( (FT_BEACON_RECT_LEFT + FT_BEACON_RECT_RIGHT) / 2 )) tcy=$(( (FT_BEACON_RECT_TOP + FT_BEACON_RECT_BOTTOM) / 2 ))
    # Box buffer must clear the arrowhead: the arrow sits `apad` cells off the target, so the
    # box has to start beyond THAT (else the arrowhead lands on the box's own border).
    # A CELL IS NOT SQUARE. It is about twice as tall as it is wide, so the same `apad` spent
    # vertically reads roughly twice as big as spent horizontally: the sideways arrows sat
    # snugly one column off their target while the up/down ones appeared to float a mile below
    # theirs. Vertical padding is therefore one step tighter — apad=1 (the default) means one
    # clear column beside the target, and none above or below it.
    local vpad=$(( apad > 0 ? apad - 1 : 0 ))
    # …but that argument is about the ARROWHEAD — how close the head sits to the target. It was
    # also being used for the BOX distance, and the box distance is where the LINE lives. The
    # drawn run is `gap - 1 - apad` (the exit sits one cell off the box, the head `apad` cells
    # off the target), so `vgap = vpad+1 = apad` left vertical leaders exactly ZERO cells long —
    # a callout placed above or below its target could never draw a line, on any page, at any
    # screen size. Horizontal ones got `apad+3`, i.e. two cells, which is why every leader that
    # survived was a sideways one and the vertical ones looked like an aversion. They were.
    #
    # So the two concerns are separated: `apad`/`vpad` still set how close the HEAD sits (the
    # aspect-ratio reasoning above is untouched), and the box distance additionally reserves the
    # line itself — _MIN_LEADER cells of it. The horizontal axis reserves one more, because a
    # cell is twice as tall as it is wide and three rows already read as long as four columns.
    local hgap=$(( apad + 2 + _MIN_LEADER )) vgap=$(( apad + 1 + _MIN_LEADER ))

    local tl tr bl br hz vt dn up rt lf
    if (( FT_USE_UTF8 )); then tl="╭" tr="╮" bl="╰" br="╯" hz="─" vt="│" dn="▼" up="▲" rt="▶" lf="◀"
    else                       tl="+" tr="+" bl="+" br="+" hz="-" vt="|" dn="v" up="^" rt=">" lf="<"; fi

    # Shape the message box at interior text width W → lines/iw/nlin/bw/bh. Wrapping at a
    # NARROWER width makes the box taller — which is how a side-parked callout fits a slim
    # screen margin that a full-width box never could.
    local -a lines=(); local iw nlin bw bh l
    # The placement search re-shapes at a handful of widths, and several sides ask for the SAME
    # width — so memoise per width (ft_wrap + a display-width pass over every line is by far the
    # most expensive thing in a candidate). Memo lives for this paint only.
    local -A _shmemo=()
    _shape() { local w=$1; (( w < 6 )) && w=6
        if [[ -n "${_shmemo[$w]:-}" ]]; then
            IFS=$'\x1e' read -r iw nlin bw bh _shln <<< "${_shmemo[$w]}"
            IFS=$'\x1f' read -r -a lines <<< "$_shln"
            return
        fi
        ft_wrap "$text" "$w"; lines=("${FT_WRAP_LINES[@]}")
        iw=0; for l in "${lines[@]}"; do ft_display_width "$l"; (( FT_DISPLAY_WIDTH > iw )) && iw=$FT_DISPLAY_WIDTH; done
        nlin=${#lines[@]}; bw=$(( iw + 4 )); bh=$(( nlin + 2 ))
        local _j=""; printf -v _j '%s\x1f' "${lines[@]}"
        _shmemo[$w]="${iw}"$'\x1e'"${nlin}"$'\x1e'"${bw}"$'\x1e'"${bh}"$'\x1e'"${_j%$'\x1f'}"; }
    local _shln
    # (`_sidew` — the interior width a side could give the box — and `_bpos` — the box top-left
    # for a candidate side — lived here until the allocator replaced the four-sides search. Both
    # were defined on every callout paint, leaked into the global namespace under generic names,
    # and called by nothing: the region loop derives its own positions and `_shape` its own
    # widths. Removed with the search that used them.)
    # PLACEMENT CACHE — the scoring (4× iterate-all-controls + 4× wrap) is far too costly to
    # redo on every repaint, and a callout is composited on top after EVERY frame (incl. each
    # border-animation tick). So compute placement only when an INPUT changes (target geometry,
    # text, drag, screen size); a mere repaint reuses the cached box + wrapped lines. This also
    # keeps placement STABLE frame-to-frame (re-scoring each frame made the box drift + smear).
    # (`cbt`/`cbl` were declared here for `_bpos`, which went with the four-sides search.)
    _ft_beacon_park "$name"                     # …separate statement: `drag` reads FT_RET
    local boxL boxT boxB boxR _searched=0 drag=$FT_RET
    # ANCHOR BELONGS IN THE KEY. It is an INPUT to the search — a named anchor fixes which side
    # the leader leaves by, so it changes which box is best — and the end-of-paint leader recomputes
    # the head from the current anchor regardless. Left out, `ft-modify c anchor=topRight` moved
    # the arrow while the box stayed where it was chosen for the OLD anchor. Only a callout that
    # changed its text at the same time hid this.
    local pkey="${place}|${anchor}|${apad}|${FT_BEACON_RECT_TOP}_${FT_BEACON_RECT_LEFT}_${FT_BEACON_RECT_RIGHT}_${FT_BEACON_RECT_BOTTOM}|${drag}|${FT_COLS}x${FT_ROWS}|${maxw}|${text}"
    if [[ "${FT_BEACON_PKEY[$name]:-}" == "$pkey" ]]; then
        _ft_beacon_placement "$name"
        place=$FT_PLACED_SIDE; boxT=$FT_PLACED_T; boxL=$FT_PLACED_L
        boxB=$FT_PLACED_B; boxR=$FT_PLACED_R
        bw=$FT_PLACED_W; bh=$FT_PLACED_H; iw=$FT_PLACED_INNER_W; nlin=$FT_PLACED_LINES
        IFS=$'\x1f' read -r -a lines <<< "${FT_BEACON_LN[$name]}"
    elif (( ${FT_RUN_ACTIVE:-0} && ! _FT_BEACON_PLACE_NOW )) && [[ -z "$drag" ]]; then
        # OWED, NOT SKIPPED — see FT_BEACON_PENDING. The search below is 560 ms of a 687 ms
        # keypress on a dense page; the rest of the frame is correct without it, so hand the
        # frame over and let the run loop place the callout the moment it is on the screen.
        #
        # ONLY INSIDE A RUNNING APP, and that predicate is the whole reason this is safe: a
        # deferral needs a pump, and ft-run's loop is the pump. Headless — every test in
        # tests/, ft_beacon_place, any app driving paints itself — FT_RUN_ACTIVE is 0 and the
        # search happens right here, synchronously, exactly as it always did. A drag is
        # excluded because it has no search to do (the box is where the user left it) and
        # because a callout that vanished mid-drag would be unusable.
        #
        # NOTHING IS PAINTED for a beacon whose placement is not yet known — not its PREVIOUS
        # placement, which points at the old target and would read as the box jumping to the
        # wrong place and back. One frame later is an animation; a jump is a bug.
        FT_BEACON_PENDING[$name]=$pkey
        return
    else
        if [[ -n "$drag" ]]; then
            # DRAGGED: box parked where the user left it (wide shape). Attach the arrow to
            # whichever target edge the box now sits past — the head scoots AROUND the target
            # as you drag (left→top→right), never cutting across it.
            # THE BOX YOU GRABBED IS THE BOX YOU DROP. This used to force the wide shape on
            # release, so the first drag of a narrow (rescued) callout showed a narrow ghost and
            # parked a wide box — and the drag clamp above reasons in the ghost's dimensions.
            # The placed shape's interior width is in the cache; re-wrap at that width.
            local _pshape=$maxw
            if _ft_beacon_placement "$name"; then
                (( FT_PLACED_INNER_W > 0 && FT_PLACED_INNER_W <= maxw )) && _pshape=$FT_PLACED_INNER_W
            fi
            _shape "$_pshape"
            set -- $drag; boxT=$1; boxL=$2
            local sA=$(( FT_BEACON_RECT_TOP - (boxT+bh) )) sBl=$(( boxT - FT_BEACON_RECT_BOTTOM )) \
                  sL=$(( FT_BEACON_RECT_LEFT - (boxL+bw) )) sR=$(( boxL - FT_BEACON_RECT_RIGHT ))
            place=above; local sbest=$sA
            (( sBl > sbest )) && { sbest=$sBl; place=below; }
            (( sL  > sbest )) && { sbest=$sL;  place=left; }
            (( sR  > sbest )) && {              place=right; }
        else
            # ── PLACEMENT: ASK WHERE THERE IS ROOM, THEN JUDGE THE LINE ──────────────────
            #
            # The old search was three phases of "guess a position near the target, score what it
            # landed on". That is backwards, and it is why callouts kept covering things: the four
            # sides of a target are a GUESS about where space might be, and a slide ladder is a
            # guess about how far to shuffle along. What a floating box actually needs is the list
            # of places it CAN go, which is a question about free space, not about the target.
            #
            # So: ft_free_regions reports the screen's unclaimed rectangles the way an allocator
            # reports free blocks; a box that fits in one lands there and covers NOTHING. The box's
            # SHAPE is negotiable too — the same text rewraps narrower and taller — so each shape
            # gets to ask the same question, and a slim box can take a free column that no
            # full-width one could. Target-adjacent positions stay in the running as the answer for
            # when nothing fits, which on a small enough screen is the honest answer.
            #
            # Every candidate is then judged on THE LEADER IT WOULD REALLY GET, by the same call
            # that draws it. Routing is far too slow to run on every candidate, so a cheap filter
            # (burial, distance, shape) picks the finalists and only those are routed. That is the
            # one thing this must never go back to: scoring a model of the line instead of the line.
            local _tpl=""
            [[ -n "${FT_BURST_LOG:-}" ]] && { ft_now_ms; _tpl=$FT_RET; }
            local _sv_extra=$FT_ROUTE_EXTRA; FT_ROUTE_EXTRA=""
            # THE HOME FRAME'S RING IS NOT IN THE SEARCH'S LIST. Every candidate parks inside
            # that frame, so its ring can only ever be SCANNED by the search, never crossed or
            # covered — and the scan is the hottest loop there is: four full-width strips made
            # every route score and every burial walk 18 rects instead of 14, measured as the
            # judge going 1 829 → 2 152ms over page 4's four steps. The strips matter for a
            # DRAGGED callout, which may sit outside; that list is built at the draw, below.
            _ft_route_obstacles "$bb"; FT_ROUTE_EXTRA=$_sv_extra
            # EVERY OTHER OVERLAY IS REAL INK TOO, and the layout walk cannot see any of it.
            # See _ft_beacon_push_overlay_ink — one function, called by every preamble.
            _ft_beacon_push_overlay_ink "$name"
            # Burial reads TIER rects, routing keeps the plain ones. A leader crossing a border is
            # still one crossing; only what it costs to SIT on that border changes.
            ft_tier_rects
            local _pref=""; [[ "$place" != auto ]] && _pref=$place
            # A NAMED ANCHOR FIXES THE SIDE, so the filter must measure that side and not the one
            # the box happens to be nearest on. `_ft_beacon_anchor_point` gives the leader its side
            # straight from the anchor; the cheap score derived its own from box-vs-target
            # clearance, and the two then disagreed exactly on the candidates a named anchor
            # exists to produce — `anchor=topLeft` scored a far-margin box on its "left" clearance
            # while the leader it would really get comes DOWN from above, so the filter kept boxes
            # the judge then paid four turns to connect. Same predicate on every path, which is
            # what the leader contract is for. centerCenter is excluded on purpose: it points into
            # the middle, so the box may legitimately sit on any side and the clearance rule is
            # still the right one.
            local _asd=""
            case "$anchor" in
                topLeft|topCenter|topRight)          _asd=above ;;
                bottomLeft|bottomCenter|bottomRight) _asd=below ;;
                centerLeft)                          _asd=left ;;
                centerRight)                         _asd=right ;;
            esac
            # …and it IMPLIES A SIDE FOR THE BOX, at exactly the strength `place=` has. An arrow
            # into the middle of the left edge comes from the left; put the chip on the right and
            # the line has to travel the whole width of the target to arrive facing back at it.
            # This is a BIAS, not an order — same _PLACE_BIAS, so a side with no room is still
            # overruled — and an explicit `place=` still wins, because the author said it out loud.
            [[ -z "$_pref" ]] && _pref=$_asd

            # The finalists: a bounded, cheap-scored shortlist. Bounded because each one costs a
            # real route, and a route is milliseconds.
            # The SHAPE width is carried separately from the box width: _shape() takes the text
            # wrap width, and the box comes out wider than that. Re-shaping a finalist by its box
            # width would silently give it different geometry from the one that was scored.
            local -a _fT=() _fL=() _fSW=() _fBW=() _fBH=() _fS=()
            local -A _fSeen=()          # position→seen, so dedupe is a lookup not a scan
            local _fCut=-1              # price of admission once the list is full (see _cand)
            # WIDE ENOUGH THAT CHEAP-SCORE NOISE CANNOT EVICT THE WINNER. Once the dominant term
            # (corridor or misalignment) is equal, candidates cluster within a handful of points
            # and the ordering among them is raw distance — which does not predict quality at all.
            # Measured: the placement that finally scored 385 sat at cheap 3053 against a cutoff of
            # 3048, i.e. lost its slot by five points of noise while being 30× better. The judge
            # can tell them apart; the filter cannot, so its only real job is not to lose them.
            # ~10ms per finalist on the CACHED placement path (a step or page change, never a
            # frame), which is what buys the right to be generous here.
            #
            # THAT PRICE WAS MEASURED WRONG, and the assumption under it does not hold. A step
            # change is not rare in an app built around stepping: demo/callout-demo.bash makes
            # one on every arrow press, and a press costs ~790ms, not the ~120ms twelve
            # finalists were budgeted at.
            #
            # BUT THE POOL IS NOT WHERE THE TIME IS, so do not reach for this number. Measured
            # across all 50 page/step placements in that demo: 12 -> 2 finalists saves 17%
            # (760ms -> 632ms) and MOVES 20 OF THE 50 placements. The cost is in generating and
            # cheap-scoring the ~1000 candidates that arrive before the pool is consulted; the
            # finalists are what turn a shortlist into a good answer. Shrinking it pays almost
            # nothing and spends placement quality to do it.
            local _FINALISTS=12
            _cand() {           # T L shapeW boxW boxH cheapscore [corridorcost] — best _FINALISTS
                local t=$1 l=$2 sw=$3 w=$4 h=$5 s=$6 corr=${7:-0} i j n=${#_fS[@]}
                (( t < bl_t || l < bl_l || t + h - 1 > bl_b || l + w - 1 > bl_r )) && return 0
                # DEDUPE. Regions overlap and the alignments/slides converge, so the same box was
                # offered many times — the dumps showed shortlists of eight entries holding three
                # distinct positions. Duplicates cost the judge nothing to re-evaluate but they
                # OCCUPY SLOTS, and with the cheap scores now clustered around one dominant term,
                # a genuinely better candidate was evicted by nine points of raw-distance noise
                # between two copies of the same box. Distinct positions only.
                # FIRST, because it is a hash lookup and everything below it is a scan: the key is
                # (position, shape) and none of the scoring below can change it.
                [[ -n "${_fSeen[$t,$l,$sw]:-}" ]] && return 0
                _fSeen[$t,$l,$sw]=1
                # AND THE SAME BOUND THE JUDGE USES. Every term added below — burial of the target,
                # the forced turn, the corridor, the place bias — is non-negative, so `s` is already
                # a lower bound on what this candidate would score. Once the shortlist is full, a
                # candidate that cannot beat its last entry cannot join it, and scoring it properly
                # is work done to be discarded. ~1000 candidates are offered per placement and most
                # arrive after the list is full.
                (( _fCut >= 0 && s >= _fCut )) && return 0
                _ft_beacon_target_cover "$t" "$l" "$w" "$h"; (( s += FT_RET * _TARGET_COVER_COST ))
                # PRICE THE TURNS THIS POSITION WILL FORCE, in the judge's own currency. Whether
                # the leader can be straight is pure geometry: the head sits at the target's edge
                # pulled toward the box's centre, the exit slides along the facing edge toward the
                # head, and the line is straight exactly when the exit can reach the head's column
                # (row). A box whose span cannot reach it gets a Z — two turns — by construction.
                #
                # The cheap filter not knowing this was the bug that kept jogs winning: a candidate
                # with a short straight line carried a 3000 penalty here while the jog candidates
                # carried none, so the shortlist filled with jogs — and the judge, which prices a
                # jog at 6000, never saw the alternative it would have preferred. The two rankings
                # must agree on what is expensive, or the filter quietly vetoes the judge.
                local br=$(( t + h - 1 )) rr=$(( l + w - 1 )) hc
                local dA=$(( FT_BEACON_RECT_TOP - br )) dB=$(( t - FT_BEACON_RECT_BOTTOM ))
                local dL=$(( FT_BEACON_RECT_LEFT - rr )) dR=$(( l - FT_BEACON_RECT_RIGHT )) mm=$dB sd=below
                (( dA > mm )) && { mm=$dA; sd=above; }
                (( dL > mm )) && { mm=$dL; sd=left; }
                (( dR > mm )) && {         sd=right; }
                [[ -n "$_asd" ]] && sd=$_asd     # a named anchor decides the side; see `_asd`
                # The misalignment charge and the corridor charge describe the SAME detour, not
                # two: a diagonal box's leader leaves by a perpendicular edge and goes AROUND
                # whatever sits on the straight line — it does not also cross it. Summing both
                # (the corridor estimate is added by the caller) double-priced exactly the
                # placement the user keeps sketching (box in the band beside the target, one
                # turn) to ~12000 while its real routed cost is ~6000, so it never reached the
                # judge. The caller adds max(corridor, _CAND_MISALIGN) instead.
                # ONE turn, not two: the leader contract's diagonal exit leaves by whichever edge
                # makes an L (and tries both), so a misaligned box costs a single bend by
                # construction. Charging two was honest before that existed; kept at two it held
                # every diagonal candidate at the same 6000-plateau as the corridor-crossing ones,
                # and the tie-breakers (raw distance) then decided against exactly the band
                # placement the user keeps drawing.
                local mis=0
                case "$sd" in
                    above|below)
                        hc=$(( l + w/2 )); (( hc < FT_BEACON_RECT_LEFT )) && hc=$FT_BEACON_RECT_LEFT; (( hc > FT_BEACON_RECT_RIGHT )) && hc=$FT_BEACON_RECT_RIGHT
                        (( hc >= l+1 && hc <= rr-1 )) || mis=$_TURN_COST ;;
                    *)  hc=$(( t + h/2 )); (( hc < FT_BEACON_RECT_TOP )) && hc=$FT_BEACON_RECT_TOP; (( hc > FT_BEACON_RECT_BOTTOM )) && hc=$FT_BEACON_RECT_BOTTOM
                        (( hc >= t+1 && hc <= br-1 )) || mis=$_TURN_COST ;;
                esac
                # ALIGNED → the straight corridor IS the path, so charge what sits in it.
                # DIAGONAL → the leader is an L that goes AROUND the corridor and never enters it,
                # so charging the corridor is charging for cells the line does not touch. That is
                # what kept p1 s3 threading down past the step nav: the empty band beside the
                # target was billed 9000 for a corridor its L would have side-stepped, lost the
                # shortlist to a 3061 candidate, and was never routed. A prefilter may be wrong,
                # but only in the direction of KEEPING a candidate for the judge to settle.
                (( s += mis > 0 ? mis : corr ))
                # An explicit `place=` has to bias the SHORTLIST, not just the final judging.
                # Free space is plentiful, so region candidates score far below the target-adjacent
                # ones and filled every finalist slot — the preferred side was cut before anything
                # looked at it, and a callout told to sit above its target drew an arrow from the
                # side. Same derivation the leader uses: whichever axis the box is furthest clear on.
                if [[ -n "$_pref" ]]; then
                    local dA=$(( FT_BEACON_RECT_TOP - (t+h-1) )) dB=$(( t - FT_BEACON_RECT_BOTTOM ))
                    local dL=$(( FT_BEACON_RECT_LEFT - (l+w-1) )) dR=$(( l - FT_BEACON_RECT_RIGHT )) mm sd
                    mm=$dB; sd=below
                    (( dA > mm )) && { mm=$dA; sd=above; }
                    (( dL > mm )) && { mm=$dL; sd=left; }
                    (( dR > mm )) && {         sd=right; }
                    [[ "$sd" == "$_pref" ]] || (( s += _PLACE_BIAS ))
                fi
                for (( i=0; i<n; i++ )); do (( s < _fS[i] )) && break; done
                (( i >= _FINALISTS )) && return 0
                for (( j=n<_FINALISTS?n:_FINALISTS-1; j>i; j-- )); do
                    _fT[j]=${_fT[j-1]}; _fL[j]=${_fL[j-1]}; _fSW[j]=${_fSW[j-1]}
                    _fBW[j]=${_fBW[j-1]}; _fBH[j]=${_fBH[j-1]}; _fS[j]=${_fS[j-1]}
                done
                _fT[i]=$t; _fL[i]=$l; _fSW[i]=$sw; _fBW[i]=$w; _fBH[i]=$h; _fS[i]=$s
                # THE CUTOFF, PUBLISHED. Once the list is full the last entry's score is the price
                # of admission, and every term the generator adds below its running total is
                # non-negative — so a caller holding a partial score already knows whether the
                # candidate is hopeless. It costs one comparison there and saves a burial scan and
                # a function call here, ~800 times per placement. Maintained in this one place so
                # there is a single definition of what the cutoff is; -1 means "not full yet".
                (( ${#_fS[@]} >= _FINALISTS )) && _fCut=${_fS[_FINALISTS-1]}
                return 0
            }
            local _wtry _narrowpen _k _k2 _rw _rh _cT _cL _dist _side
            # Declared once rather than per candidate. MEASURED AT NO GAIN (247ms vs 233ms, inside
            # the noise) — the loop's cost is the arithmetic, not the declarations. Kept only
            # because the names are now used across the whole candidate body; do not repeat this
            # experiment expecting a win.
            local _dA _dB _dL _dR _mm _sdd _drawn _short _base _ccost _alx
            local _ccr _ccl _ccw _cch _nb _st _sl2 _sb2
            local _cyLo _cyHi _cxLo _cxHi _dy _dx
            # One region list serves every shape: ask for the SMALLEST box any shape could need,
            # so the answer is a superset, and let each shape filter it.
            # The SMALLEST box ANY shape could need — narrowest width from the slimmest shape,
            # shortest height from the widest one. Taking the width from the WIDEST shape (as this
            # briefly did) excluded every narrow side-column region, which is exactly the space a
            # slim rewrap exists to use: at 95×34 page 4 it removed both margin columns and left
            # the search nothing but placements burying 45+ cells.
            _shape $(( maxw/3 < 12 ? 12 : maxw/3 )); local _minw=$bw _minh=$bh
            _shape "$maxw"; (( bh < _minh )) && _minh=$bh
            (( _minw -= _OVERHANG )); (( _minw < 4 )) && _minw=4
            (( _minh -= _OVERHANG )); (( _minh < 3 )) && _minh=3
            ft_free_regions "$bl_t" "$bl_l" "$bl_b" "$bl_r" "$_minw" "$_minh"
            # The bounds line has already earned its keep once: it is what revealed that the
            # "unreachable" optimum was outside the boundBox the whole time.
            [[ -n "${FT_BEACON_DEBUG:-}" ]] && printf 'FREE bounds=%s,%s..%s,%s min=%sx%s obstacles=%s -> %s regions\n' \
                "$bl_t" "$bl_l" "$bl_b" "$bl_r" "$_minw" "$_minh" "${#_RT_T[@]}" "${#FT_FREE_T[@]}" >&2
            local -a _frT=("${FT_FREE_T[@]}") _frL=("${FT_FREE_L[@]}") \
                     _frB=("${FT_FREE_B[@]}") _frR=("${FT_FREE_R[@]}")
            # The SHAPE is negotiable: the same text rewrapped narrower is a taller box, and a
            # slim one can take a free column that no wide one could. On a cramped screen that is
            # often the only placement that covers nothing, so the ladder has to reach genuinely
            # narrow — stopping at 1/2 left the tall margin column unreachable. _NARROW_BIAS keeps
            # the wide, readable shape winning whenever it is equally free.
            for _wtry in "$maxw" $(( maxw*2/3 )) $(( maxw/2 )) $(( maxw/3 )); do
                (( _wtry < 12 )) && continue
                _shape "$_wtry"
                _narrowpen=0; (( _wtry < maxw )) && _narrowpen=$_NARROW_BIAS
                # The region list is built ONCE for every shape (above), with the smallest box any
                # shape could need as the minimum, and each shape filters it. Enumerating per
                # shape cost 25ms × 4 for an answer that barely differs — the four lists overlap
                # almost entirely, because a region big enough for the widest box is big enough
                # for all of them.
                # THE NEAREST REGIONS ONLY. Maximal empty rectangles are redundant by nature — a
                # sparse screen yields ~64 of them, and enumerating every one at four alignments
                # and four shapes is ~1000 candidate positions per placement, which is the whole
                # of the remaining cost. A callout parked further from its target than these loses
                # on the distance term regardless, so the far ones are work done to be discarded.
                # Ranked by EDGE separation (rows ×3, a cell being twice as tall as wide), same
                # measure the judge uses, so this cannot drop a region the judge would have picked
                # over the ones kept.
                local -a _rk=() _rd=(); local _nr=0 _rdist _ri _rj _rv _rw2 _rh2
                for _k in "${!_frT[@]}"; do
                    (( _frR[_k] - _frL[_k] + 1 >= bw - _OVERHANG
                       && _frB[_k] - _frT[_k] + 1 >= bh - _OVERHANG )) || continue
                    _rdist=$(( FT_BEACON_RECT_TOP - _frB[_k] ))
                    (( _frT[_k] > FT_BEACON_RECT_BOTTOM )) && _rdist=$(( _frT[_k] - FT_BEACON_RECT_BOTTOM ))
                    (( _rdist < 0 )) && _rdist=0
                    _rv=$(( FT_BEACON_RECT_LEFT - _frR[_k] ))
                    (( _frL[_k] > FT_BEACON_RECT_RIGHT )) && _rv=$(( _frL[_k] - FT_BEACON_RECT_RIGHT ))
                    (( _rv < 0 )) && _rv=0
                    _rdist=$(( _rdist*3 + _rv ))
                    for (( _ri=0; _ri<_nr; _ri++ )); do (( _rdist < _rd[_ri] )) && break; done
                    (( _ri >= _REGION_CAP )) && continue
                    for (( _rj = _nr < _REGION_CAP ? _nr : _REGION_CAP-1; _rj > _ri; _rj-- )); do
                        _rk[_rj]=${_rk[_rj-1]}; _rd[_rj]=${_rd[_rj-1]}
                    done
                    _rk[_ri]=$_k; _rd[_ri]=$_rdist
                    (( _nr < _REGION_CAP )) && (( _nr++ ))
                done
                [[ -n "${FT_BEACON_DEBUG:-}" ]] && printf 'REGIONS sw=%s kept=%s of %s\n' \
                    "$_wtry" "$_nr" "${#_frT[@]}" >&2
                # ── candidates that FIT a free region: burial is zero by construction, so no
                #    overlap scan is needed for them at all (which is what keeps this affordable).
                for _k in "${_rk[@]}"; do
                    [[ -n "${FT_BEACON_DEBUG:-}" ]] && printf '  region %s: %s-%s/%s-%s\n' \
                        "$_k" "${_frT[_k]}" "${_frB[_k]}" "${_frL[_k]}" "${_frR[_k]}" >&2
                    local _isover=0
                    (( _frR[_k] - _frL[_k] + 1 < bw || _frB[_k] - _frT[_k] + 1 < bh )) && _isover=1
                    # BOUND THE WHOLE REGION BEFORE ENTERING IT. Every candidate this region can
                    # produce is a box CLAMPED INSIDE it, so the closest its centre can come to the
                    # target is fixed by the region's own edges — and the distance term alone is
                    # already a lower bound on the cheap score (the short-leader charge, the
                    # corridor and a slide's burial only add; a slide inherits this position's
                    # distance and pays a further +4). Once the shortlist is full, a region that
                    # cannot reach the cutoff even at its nearest point cannot contribute anything,
                    # and skipping it here drops its four alignments, four corridor scans and
                    # sixteen slides in one test. Regions arrive nearest-first, so this fires on
                    # the tail — where the work was, and where nothing was ever going to be found.
                    _cyLo=$(( _frT[_k] + bh/2 )); _cyHi=$(( _frB[_k] - bh + 1 + bh/2 ))
                    _cxLo=$(( _frL[_k] + bw/2 )); _cxHi=$(( _frR[_k] - bw + 1 + bw/2 ))
                    _dy=0; (( tcy < _cyLo )) && _dy=$(( _cyLo - tcy )); (( tcy > _cyHi )) && _dy=$(( tcy - _cyHi ))
                    _dx=0; (( tcx < _cxLo )) && _dx=$(( _cxLo - tcx )); (( tcx > _cxHi )) && _dx=$(( tcx - _cxHi ))
                    (( _fCut >= 0 && _dy*3 + _dx + _narrowpen >= _fCut )) && continue
                    # Aligned with the target on each axis, plus a slide to each end of the region.
                    # The slides are not padding: the arrowhead rides along the target's edge with
                    # the box, so moving the box MOVES THE CORRIDOR — and when the aligned column
                    # happens to be blocked, an otherwise identical placement a few columns over
                    # has a clear straight run. Without them the search had one corridor per region
                    # and had to accept a Z detour around whatever sat in it.
                    for _side in align-x align-y slide-lo slide-hi; do
                        # Sit at the GAP distance from the target, not flush against it — a box
                        # that hugs its target leaves nowhere for the line to be.
                        if [[ $_side != align-y ]]; then
                            case "$_side" in
                                align-x)  _cL=$(( (FT_BEACON_RECT_LEFT + FT_BEACON_RECT_RIGHT)/2 - bw/2 )) ;;
                                slide-lo) _cL=${_frL[_k]} ;;
                                *)        _cL=$(( _frR[_k] - bw + 1 )) ;;
                            esac
                            if   (( FT_BEACON_RECT_TOP > _frB[_k] )); then
                                _cT=$(( FT_BEACON_RECT_TOP - vgap - bh ))
                                (( _cT > _frB[_k] - bh + 1 )) && _cT=$(( _frB[_k] - bh + 1 ))
                            elif (( FT_BEACON_RECT_BOTTOM < _frT[_k] )); then
                                _cT=$(( FT_BEACON_RECT_BOTTOM + vgap + 1 ))
                                (( _cT < _frT[_k] )) && _cT=${_frT[_k]}
                            else _cT=$(( (FT_BEACON_RECT_TOP + FT_BEACON_RECT_BOTTOM)/2 - bh/2 )); fi
                        else
                            _cT=$(( (FT_BEACON_RECT_TOP + FT_BEACON_RECT_BOTTOM)/2 - bh/2 ))
                            if   (( FT_BEACON_RECT_LEFT > _frR[_k] )); then
                                _cL=$(( FT_BEACON_RECT_LEFT - hgap - bw ))
                                (( _cL > _frR[_k] - bw + 1 )) && _cL=$(( _frR[_k] - bw + 1 ))
                            elif (( FT_BEACON_RECT_RIGHT < _frL[_k] )); then
                                _cL=$(( FT_BEACON_RECT_RIGHT + hgap + 1 ))
                                (( _cL < _frL[_k] )) && _cL=${_frL[_k]}
                            else _cL=$(( (FT_BEACON_RECT_LEFT + FT_BEACON_RECT_RIGHT)/2 - bw/2 )); fi
                        fi
                        (( _cL < _frL[_k] )) && _cL=${_frL[_k]}
                        (( _cL + bw - 1 > _frR[_k] )) && _cL=$(( _frR[_k] - bw + 1 ))
                        (( _cT < _frT[_k] )) && _cT=${_frT[_k]}
                        (( _cT + bh - 1 > _frB[_k] )) && _cT=$(( _frB[_k] - bh + 1 ))
                        # ROOM FOR THE ARROWHEAD AND AT LEAST ONE CELL OF LINE — no more than that.
                        #
                        # The IDEAL gap (vgap/hgap, which reserves a full _MIN_LEADER) is set
                        # above, and where there is room the box takes it. Requiring it HERE, as a
                        # filter, was the mistake: it threw away every position in the empty band
                        # just past the target — the obvious, no-crossing, everybody-can-see-it
                        # spot — because that band was five rows deep instead of six. The placer
                        # then went looking for room far enough away to satisfy the rule and came
                        # back with a long line threading between the controls in between.
                        #
                        # A short line beside the target beats a long one across the page, so the
                        # only hard requirement is that a line can EXIST; _SHORT_LEADER_COST then
                        # prices "shorter than ideal" against everything else, which is a trade the
                        # search can make rather than a door closed before it looks.
                        # How many cells of line this position actually leaves room for. The exit
                        # sits one cell off the box and the head `apad`/`vpad` off the target, so
                        # this is exact for the straight case — the same number the finished leader
                        # will report, computed without routing anything.
                        # DEDUPE BEFORE PAYING FOR THE CANDIDATE, not after. Maximal empty
                        # rectangles overlap heavily — on a sparse screen ~64 of them clamp to the
                        # same handful of box positions — so the identical position was costing a
                        # corridor scan and a full cheap-score every time it was re-offered, then
                        # being discarded at the end. Same key `_cand` uses; it keeps its own check
                        # for the fallback paths.
                        # CHECK HERE, MARK IN `_cand`. Marking it here armed the dedupe against
                        # the very candidate this block was about to offer: `_cand` tests the
                        # SAME key (position, shape) first thing and returned immediately, so
                        # EVERY primary region candidate was generated, cheap-scored, and then
                        # silently dropped — measured at 62×40 page 1 step 1: 8 offered, 0 in
                        # the shortlist, all 12 finalists coming from the ±1/±2 slides and the
                        # target-adjacent fallbacks. The best-aligned position in each free
                        # region — the whole point of the allocator — was never judged.
                        [[ -n "${_fSeen[$_cT,$_cL,$_wtry]:-}" ]] && continue
                        # HOW FAR IT SITS IS THE CHEAPEST THING TO KNOW, so it is the first thing
                        # asked. Every other term the cheap score adds — the short-leader charge,
                        # the corridor, the burial of a slide — only ever adds, so a position this
                        # far out that already cannot buy a shortlist slot is finished here, before
                        # the side derivation, the corridor scan or any call.
                        _dist=$(( (_cT + bh/2) - tcy )); (( _dist < 0 )) && _dist=$(( -_dist ))
                        _k2=$(( (_cL + bw/2) - tcx )); (( _k2 < 0 )) && _k2=$(( -_k2 ))
                        _base=$(( _dist*3 + _k2 + _narrowpen ))
                        (( _fCut >= 0 && _base >= _fCut )) && continue
                        # AN OVERHANGING BOX PAYS FOR WHAT IT COVERS. Every other region candidate
                        # skips the overlap scan because it cannot be covering anything; this one
                        # can, so it is priced like any candidate rather than smuggled in at zero.
                        # Charged AFTER the distance cutoff above, so a position that was never
                        # going to buy a slot does not pay for a scan to find that out.
                        if (( _isover )); then
                            _ft_beacon_overlap "$_cT" "$_cL" "$bw" "$bh"
                            (( _base += FT_RET * _BURY_COST ))
                            (( _fCut >= 0 && _base >= _fCut )) && continue
                        fi
                        # WHICH SIDE — by largest clearance, exactly as _ft_beacon_leader decides it.
                        # Testing the axes in a fixed order instead (vertical, then horizontal)
                        # judged a DIAGONAL box on the axis it happens to be nearest on: the band
                        # right of the target, two rows below it and seven columns clear, was
                        # measured as a "below" placement with 0 rows of gap and thrown out — while
                        # the leader it would really get comes in HORIZONTALLY, with room to spare.
                        # That is the whole reason p1 s3 kept threading down past the step nav
                        # instead of sitting in the empty band beside its target: the obvious
                        # placement was never a candidate. One predicate, both paths.
                        # …unless the ANCHOR has already named the side, in which case that is the
                        # side, and a box that leaves no room for a line on it prices itself out
                        # through `_drawn` below — which is the honest answer for a caller who
                        # asked for an arrow into that particular edge.
                        if [[ -n "$_asd" ]]; then _sdd=$_asd; else
                        _dA=$(( FT_BEACON_RECT_TOP - (_cT + bh - 1) )) _dB=$(( _cT - FT_BEACON_RECT_BOTTOM ))
                        _dL=$(( FT_BEACON_RECT_LEFT - (_cL + bw - 1) )) _dR=$(( _cL - FT_BEACON_RECT_RIGHT ))
                        _mm=$_dB _sdd=below
                        (( _dA > _mm )) && { _mm=$_dA; _sdd=above; }
                        (( _dL > _mm )) && { _mm=$_dL; _sdd=left; }
                        (( _dR > _mm )) && {           _sdd=right; }
                        fi

                        case "$_sdd" in
                            above) _drawn=$(( FT_BEACON_RECT_TOP - vpad - 1 - _cT - bh )) ;;
                            below) _drawn=$(( _cT - FT_BEACON_RECT_BOTTOM - 2 - vpad )) ;;
                            left)  _drawn=$(( FT_BEACON_RECT_LEFT - apad - 1 - _cL - bw )) ;;
                            *)     _drawn=$(( _cL - FT_BEACON_RECT_RIGHT - 2 - apad )) ;;
                        esac
                        (( _drawn >= 1 )) || continue  # no room for a line at all
                        # THE CHEAP FILTER HAS TO PREDICT LEADER QUALITY, NOT JUST NEARNESS.
                        # Ranking candidates by distance alone kept the CLOSEST ones — which are
                        # precisely the ones squeezed hardest against the target, with a one-cell
                        # stub for a line — and discarded the position two rows further out that
                        # had room for a proper one. The finalists were the worst of each region.
                        _short=0
                        (( _drawn < _MIN_LEADER )) && _short=$(( (_MIN_LEADER - _drawn) * _SHORT_LEADER_COST ))
                        (( _base += _short ))                  # …and again now that it is known
                        (( _fCut >= 0 && _base >= _fCut )) && continue
                        # …AND IT HAS TO SEE CROSSINGS, which are the term that dominates the real
                        # score. Without them the shortlist was chosen on nearness alone, so a box
                        # tucked just above the specimen beat one further down with a clear run —
                        # and the clean candidate was gone before anything routed it. Measured: 30
                        # of 104 leaders crossed a control, nearly all of them a box parked above
                        # the specimen pointing at something below it.
                        # The straight corridor is an approximation (the router may bend around),
                        # which is exactly what a prefilter should be: cheap, and wrong only in the
                        # direction of keeping a candidate the finalists then judge properly.
                        # …AND ONLY WHEN IT WILL BE USED. `_cand` charges the corridor for an
                        # ALIGNED box and the one-turn misalignment for a diagonal one — never
                        # both — so scanning the corridor for a diagonal candidate computes a
                        # number that is then discarded. That discarded scan was the placement's
                        # entire cost: 1181 rect scans, ~1.5s a step change. Same span test as
                        # `_cand` uses, so the two agree about which candidates are aligned.
                        _ccost=0
                        case "$_sdd" in
                            above|below)
                                _alx=$(( _cL + bw/2 ))
                                (( _alx < FT_BEACON_RECT_LEFT )) && _alx=$FT_BEACON_RECT_LEFT; (( _alx > FT_BEACON_RECT_RIGHT )) && _alx=$FT_BEACON_RECT_RIGHT
                                (( _alx >= _cL+1 && _alx <= _cL+bw-2 )) || _alx=-1 ;;
                            *)  _alx=$(( _cT + bh/2 ))
                                (( _alx < FT_BEACON_RECT_TOP )) && _alx=$FT_BEACON_RECT_TOP; (( _alx > FT_BEACON_RECT_BOTTOM )) && _alx=$FT_BEACON_RECT_BOTTOM
                                (( _alx >= _cT+1 && _alx <= _cT+bh-2 )) || _alx=-1 ;;
                        esac
                        # The corridor is one cell wide, running from the box's edge to the
                        # target's along the line the leader would take — and that line IS `_alx`,
                        # the aligned exit the span test above just computed and clamped. Each of
                        # these four arms used to recompute it under the name `_ccx` with the
                        # identical arithmetic (and the guard guarantees `_alx` is that value and
                        # not -1), four string comparisons and four clamps deep in the search's
                        # hottest loop.
                        if (( _alx >= 0 )); then
                            case "$_sdd" in
                                above) _ccr=$(( _cT + bh ));   _ccl=$_alx; _ccw=1; _cch=$(( FT_BEACON_RECT_TOP - _ccr )) ;;
                                below) _ccr=$(( FT_BEACON_RECT_BOTTOM + 1 )); _ccl=$_alx; _ccw=1; _cch=$(( _cT - _ccr )) ;;
                                left)  _ccr=$_alx; _ccl=$(( _cL + bw ));   _cch=1; _ccw=$(( FT_BEACON_RECT_LEFT - _ccl )) ;;
                                *)     _ccr=$_alx; _ccl=$(( FT_BEACON_RECT_RIGHT + 1 )); _cch=1; _ccw=$(( _cL - _ccl )) ;;
                            esac
                            (( _ccw > 0 && _cch > 0 )) && {
                                _ft_beacon_overlap "$_ccr" "$_ccl" "$_ccw" "$_cch"; _ccost=$(( FT_RET * _CROSS_COST )); }
                        fi
                        [[ -n "${FT_BEACON_DEBUG:-}" ]] && printf '  CAND k=%s %s sw=%s -> %s,%s base=%s ccost=%s\n' \
                            "$_k" "$_side" "$_wtry" "$_cT" "$_cL" "$_base" "$_ccost" >&2
                        _cand "$_cT" "$_cL" "$_wtry" "$bw" "$bh" "$_base" "$_ccost"
                        # ±1/±2 NEIGHBOUR SLIDES along the region. One column decides whether the
                        # leader's bend lands in the clean gap between two controls or brushes the
                        # first character of the next one — and every prior generator (region
                        # edges, target-centre alignment) moves in strides far coarser than that.
                        # "The good candidate was never generated" has been this search's root
                        # cause three times; these are the finest teeth. Cheap-scored like any
                        # candidate, so they only reach the judge when they earn a slot.
                        # A SLID BOX LEAVES THE REGION'S GUARANTEE. Region candidates bury nothing
                        # by construction — but a ±2 slide steps outside the empty rectangle, and
                        # unpriced it did exactly that: slid two columns onto the ▶ and Quit
                        # buttons, kept its region-candidate cheap score of ~57, set the shortlist
                        # cutoff there, and every clean alternative was cut before judging. A
                        # slide pays for what it now covers, like any other candidate.
                        # All four slides score `_base + burial + 4` — they inherit this position's
                        # distance terms rather than recomputing them — so `_base + 4` is exactly
                        # the cheapest any of them can be. When that cannot buy a slot, none of the
                        # four can, and their burial scans and calls are skipped as a group.
                        (( _fCut >= 0 && _base + 4 >= _fCut )) && continue

                        for _nb in -2 -1 1 2; do
                            if [[ $_side != align-y ]]; then    # align-x and both slides move by column
                                _st=$_cT; _sl2=$(( _cL + _nb ))
                            else
                                _st=$(( _cT + _nb )); _sl2=$_cL
                            fi
                            # Still inside the free region ⇒ buries NOTHING, by construction —
                            # no scan needed. Only a slide that poked outside pays for a look,
                            # and those are rare. (Scanning every slide unconditionally cost
                            # ~3200 rect scans per placement and took a step change to 1.7s.)
                            if (( _st >= _frT[_k] && _sl2 >= _frL[_k] &&
                                  _st + bh - 1 <= _frB[_k] && _sl2 + bw - 1 <= _frR[_k] )); then
                                _sb2=0
                            else
                                _ft_beacon_overlap "$_st" "$_sl2" "$bw" "$bh"; _sb2=$(( FT_RET * _BURY_COST ))
                            fi
                            _cand "$_st" "$_sl2" "$_wtry" "$bw" "$bh" \
                                  $(( _dist*3 + _k2 + _narrowpen + _short + _sb2 + 4 )) "$_ccost"
                        done
                    done
                done
                # ── target-adjacent fallbacks: what to do when nothing fits. These CAN bury, so
                #    they pay for an overlap scan — there are only four of them per shape.
                for _side in above below left right; do
                    case "$_side" in
                        above) _cT=$(( FT_BEACON_RECT_TOP - vgap - bh )); _cL=$(( tcx - bw/2 )) ;;
                        below) _cT=$(( FT_BEACON_RECT_BOTTOM + vgap + 1 ));  _cL=$(( tcx - bw/2 )) ;;
                        left)  _cL=$(( FT_BEACON_RECT_LEFT - hgap - bw )); _cT=$(( tcy - bh/2 )) ;;
                        *)     _cL=$(( FT_BEACON_RECT_RIGHT + hgap + 1 ));  _cT=$(( tcy - bh/2 )) ;;
                    esac
                    (( _cL < bl_l )) && _cL=$bl_l
                    (( _cL + bw - 1 > bl_r )) && _cL=$(( bl_r - bw + 1 )); (( _cL < bl_l )) && _cL=$bl_l
                    (( _cT < bl_t )) && _cT=$bl_t
                    (( _cT + bh - 1 > bl_b )) && _cT=$(( bl_b - bh + 1 )); (( _cT < bl_t )) && _cT=$bl_t
                    _ft_beacon_overlap "$_cT" "$_cL" "$bw" "$bh"
                    _cand "$_cT" "$_cL" "$_wtry" "$bw" "$bh" $(( FT_RET*_BURY_COST + _narrowpen + 40 ))
                done
            done

            # ── judge the finalists on the line they would really get ────────────────────
            # FT_BEACON_DEBUG=1 dumps the finalists and the judge's verdict on each to stderr.
            # KEPT, not a temporary probe: every placement dispute this search has had was
            # settled by reading this table (four times now), and re-adding it by hand each
            # time is how blind weight-tuning starts. Costs one [[ -n ]] per placement.
            [[ -n "${_tpl:-}" ]] && { ft_now_ms; printf 'STG place-candidates %s finalists=%s\n' $(( FT_RET - _tpl )) "${#_fT[@]}" >> "$FT_BURST_LOG"; _tpl=$FT_RET; }
            local _bestsc=-1 _bestT=0 _bestL=0 _bestW=$maxw _i _sc
            [[ -n "${FT_BEACON_DEBUG:-}" ]] && printf 'SHORTLIST %s tgt=%s,%s..%s,%s\n' \
                "$name" "$FT_BEACON_RECT_TOP" "$FT_BEACON_RECT_LEFT" "$FT_BEACON_RECT_BOTTOM" "$FT_BEACON_RECT_RIGHT" >&2
_ft_beacon_judge_finalists
            # ── RESCUE: when the winner is still buried, sweep for what no generator offered ──
            # A free region cannot contain a single content cell, and the fallback lattice
            # samples a handful of columns — so a position on a paragraph's ragged margin (cheap
            # by tier, invisible to both) is never on the shortlist. Measured on p4.s4 at 62x40:
            # the judge chose weighted burial 35 while a legal position at 15 existed, and no
            # candidate within ten columns of it was ever generated. The sweep asks
            # _ft_beacon_overlap directly at a stride, keeps the few best, and hands them to the
            # SAME judge — so a rescue wins only by beating the standing winner on the full
            # score, real routed leader and all. The tiers built for the cost model finally act
            # here: this is the one generator that can SEE cheap interior space.
            if (( _bestsc >= 0 )); then
                _shape "$_bestW"
                _ft_beacon_overlap "$_bestT" "$_bestL" "$bw" "$bh"
                local _winner_buries=$FT_RET      # the sweep below reuses FT_RET per candidate
                if (( _winner_buries > _RESCUE_AT )); then
                    _fT=(); _fL=(); _fBW=(); _fBH=(); _fSW=(); _fS=()
                    local _rsw _rt _rl _rstep _rsc _rn _rj
                    for _rsw in "$maxw" $(( maxw*2/3 )) $(( maxw/2 )) $(( maxw/3 )); do
                        (( _rsw < 12 )) && continue
                        _shape "$_rsw"
                        local _rrows=$(( bl_b - bl_t + 1 - bh + 1 )) _rcols=$(( bl_r - bl_l + 1 - bw + 1 ))
                        (( _rrows < 1 || _rcols < 1 )) && continue
                        _rstep=2
                        while (( ((_rrows + _rstep - 1) / _rstep) * ((_rcols + _rstep - 1) / _rstep) > _RESCUE_SCAN )); do
                            (( _rstep++ ))
                        done
                        # (SWEEPING OUTWARD FROM THE TARGET was built here and measured as exactly
                        # nothing — 403 overlap scans before, 403 after — so it was removed. The
                        # reasoning was that the distance pre-cut below would bite sooner if the
                        # near positions filled the six slots first. The cut cannot bite at all:
                        # it compares a DISTANCE-ONLY score against shortlist entries that already
                        # include BURIAL, which runs to thousands, so the bound is sound and far
                        # too loose to ever fire. Ordering cannot help a test that never triggers.
                        # The same lesson as the leader prefilter: a cheap filter has to be priced
                        # in the terms the thing it feeds actually uses.)
                        for (( _rt = bl_t; _rt + bh - 1 <= bl_b; _rt += _rstep )); do
                            _dist=$(( FT_BEACON_RECT_TOP - (_rt + bh - 1) ))
                            (( _rt > FT_BEACON_RECT_BOTTOM )) && _dist=$(( _rt - FT_BEACON_RECT_BOTTOM ))
                            (( _dist < 0 )) && _dist=0
                            for (( _rl = bl_l; _rl + bw - 1 <= bl_r; _rl += _rstep )); do
                                # distance first — it is two subtractions, the burial scan is a
                                # walk over every obstacle, and burial only ever ADDS. When six
                                # candidates are already held, a position whose distance term
                                # alone cannot displace the sixth needs no scan at all.
                                _k2=$(( FT_BEACON_RECT_LEFT - (_rl + bw - 1) ))
                                (( _rl > FT_BEACON_RECT_RIGHT )) && _k2=$(( _rl - FT_BEACON_RECT_RIGHT ))
                                (( _k2 < 0 )) && _k2=0
                                _rsc=$(( (_dist*3 + _k2) * 20 ))
                                (( _rsw < maxw )) && (( _rsc += _NARROW_BIAS ))
                                _rn=${#_fS[@]}
                                (( _rn >= 6 && _rsc >= _fS[_rn-1] )) && continue
                                _ft_beacon_overlap "$_rt" "$_rl" "$bw" "$bh"
                                (( _rsc += FT_RET * _BURY_COST ))
                                # sorted insertion, capacity 6 — the judge prunes with the
                                # standing winner as the bound, so order only buys pruning
                                _rn=${#_fS[@]}
                                (( _rn >= 6 && _rsc >= _fS[_rn-1] )) && continue
                                for (( _rj=0; _rj<_rn; _rj++ )); do (( _rsc < _fS[_rj] )) && break; done
                                _fT=("${_fT[@]:0:_rj}" "$_rt" "${_fT[@]:_rj}")
                                _fL=("${_fL[@]:0:_rj}" "$_rl" "${_fL[@]:_rj}")
                                _fBW=("${_fBW[@]:0:_rj}" "$bw" "${_fBW[@]:_rj}")
                                _fBH=("${_fBH[@]:0:_rj}" "$bh" "${_fBH[@]:_rj}")
                                _fSW=("${_fSW[@]:0:_rj}" "$_rsw" "${_fSW[@]:_rj}")
                                _fS=("${_fS[@]:0:_rj}" "$_rsc" "${_fS[@]:_rj}")
                                (( ${#_fS[@]} > 6 )) && {
                                    _fT=("${_fT[@]:0:6}"); _fL=("${_fL[@]:0:6}")
                                    _fBW=("${_fBW[@]:0:6}"); _fBH=("${_fBH[@]:0:6}")
                                    _fSW=("${_fSW[@]:0:6}"); _fS=("${_fS[@]:0:6}"); }
                            done
                        done
                    done
                    [[ -n "${FT_BEACON_DEBUG:-}" ]] && printf 'RESCUE fired: winner buries %s, %s sweep candidates\n' \
                        "$_winner_buries" "${#_fS[@]}" >&2
                    _ft_beacon_judge_finalists
                fi
            fi
            [[ -n "${_tpl:-}" ]] && { ft_now_ms; printf 'STG place-judge %s\n' $(( FT_RET - _tpl )) >> "$FT_BURST_LOG"; _tpl=$FT_RET; }
            _shape "$_bestW"; boxT=$_bestT; boxL=$_bestL
            _searched=1
        fi
        # Keep the whole box inside its bound: a placed box inside the SEARCH bound, a dragged
        # one inside the PARK bound (see the two bounds above) — the same rect the ghost clamped
        # to, so what you drop is what you get.
        local cl_t=$bl_t cl_l=$bl_l cl_b=$bl_b cl_r=$bl_r
        [[ -n "$drag" ]] && { cl_t=$park_t; cl_l=$park_l; cl_b=$park_b; cl_r=$park_r; }
        (( boxL < cl_l )) && boxL=$cl_l; (( boxL + bw - 1 > cl_r )) && boxL=$(( cl_r - bw + 1 )); (( boxL < cl_l )) && boxL=$cl_l
        (( boxT < cl_t )) && boxT=$cl_t; (( boxT + bh - 1 > cl_b )) && boxT=$(( cl_b - bh + 1 )); (( boxT < cl_t )) && boxT=$cl_t
        boxB=$(( boxT + bh - 1 )); boxR=$(( boxL + bw - 1 ))
        # THE WINNER'S LEADER IS COMPUTED ONCE, HERE, AND HANDED TO THE DRAW.
        #
        # It used to run just after the judge, BEFORE the clamp above — for a box the clamp could
        # still move — and its only surviving output was `place`. The draw then rebuilt the
        # obstacle list and routed the whole thing again, because nothing had populated the leader
        # cache: measured at TWO draw-mode routes per placement returning byte-identical polys,
        # and the wasted one is the entire `STG place-final-leader` line (383ms of page 4's four
        # steps). Run after the clamp it describes the box that will actually be painted, and
        # stored under the key the draw looks up, it is the line the draw draws — which is also
        # the invariant this engine is built on: what was judged and what is painted are one
        # thing. (A DRAG does not come through here; its leader belongs to the draw, whose
        # obstacle list carries the frame's ring strips the dragged box may cross.)
        if (( _searched )); then
            _ft_beacon_leader "$boxT" "$boxL" "$boxB" "$boxR" "$apad" "$vpad" "$anchor"
            place=$FT_LEADER_SIDE
            FT_BEACON_LDRKEY[$name]="${pkey}|${FT_LAYOUT_EPOCH}"
            FT_BEACON_LDRC[$name]="$place $FT_LEADER_ARROW_ROW $FT_LEADER_ARROW_COLUMN $FT_LEADER_LENGTH $FT_LEADER_HEAD_INSIDE_BOX"$'\x1f'"$FT_LEADER_POLYLINE"
            [[ -n "${_tpl:-}" ]] && { ft_now_ms; printf 'STG place-final-leader %s\n' $(( FT_RET - _tpl )) >> "$FT_BURST_LOG"; }
        fi
        FT_BEACON_PKEY[$name]=$pkey
        FT_BEACON_PC[$name]="$place $boxT $boxL $boxB $boxR $bw $bh $iw $nlin"
        local _ln=""; printf -v _ln '%s\x1f' "${lines[@]}"; FT_BEACON_LN[$name]=${_ln%$'\x1f'}
    fi

    # A GRABBED CALLOUT DRAGS AS A GHOST: the border ring and the badge, nothing else. The
    # interior text and the routed leader are per-frame costs a transient frame cannot justify —
    # the ring is ~12 paint calls against ~200 for the full chip, and skipping the leader also
    # skips rebuilding the obstacle table every move. What the user tracks while dragging is
    # WHERE the box is, which the ring shows better than a wall of text; release does a full
    # refresh that paints the real thing, line and all.
    # …the fall-through: a grabbed callout with NO cached placement (a resize mid-drag drops the
    # caches), which has just paid for the full search above. Same ghost, one painter.
    if [[ -n "$_FT_BEACON_GRAB" && "${_FT_BEACON_GRAB%% *}" == "$name" ]]; then
        _ft_beacon_paint_ghost "$name" "$boxT" "$boxL" "$boxB" "$boxR" "$edge" "$nglyph" "$numw"
        return
    fi
    local i mid=""; for (( i=0; i<bw-2; i++ )); do mid+="$hz"; done
    # Top border: circled number right after the left corner (╭①───╮), in the EDGE colour so it
    # matches the border/arrow. Optionally a clickable ▶ "next" glyph before the right corner
    # (╭①────▶╮) when a `next` listener is registered (onNext=<fn> sugar, or ft_add_listener) —
    # a click on that cell dispatches the control's `next` event (_ft_hook … on_next).
    local nextg="" nextw=0
    if ft_has_listener "$name" next && (( bw-2-numw >= 4 )); then nextw=1; nextg="▶"; (( FT_USE_UTF8 )) || nextg=">"; fi
    # …and a ⊠ CLOSE BOX in the corner itself, the rightmost chrome, where a window puts it.
    # `closable` is a property so an author can refuse it (a tutorial step that must be read, a
    # callout the app dismisses on its own); it defaults ON, because a floating thing over your
    # work that offers no way to dismiss it is the complaint, not the feature. Dropped without
    # comment when the chip is too narrow to hold it, exactly as the ▶ is — chrome never wins an
    # argument with the text it decorates.
    local closeg="" closew=0
    ft_resolved_prop "$name" closable true
    if [[ "$FT_RET" == true || "$FT_RET" == 1 ]] && (( bw-2-numw-nextw >= 3 )); then
        closew=1; closeg="⊠"; (( FT_USE_UTF8 )) || closeg="x"
    fi
    local topmid=""; for (( i=0; i<bw-2-numw-nextw-closew; i++ )); do topmid+="$hz"; done
    # `bw` COLUMNS, SAID OUT LOUD. Every row of this box is built to the box width, and ft_print_at's
    # cheap clip test is BYTE length — which a row carrying both SGR colour and box glyphs always
    # exceeds, so each of these forced a per-character scan of the whole row on every draw, and a
    # drag redraws the box every frame. ft_print_at_width takes the width the box was built to and only
    # measures when the row genuinely overhangs the clip. Verified against the painted rows at
    # every size and mid-drag: bw is exactly the display width of all three.
    ft_print_at_width "$boxT" "$boxL" "${edge}${tl}${nglyph}${topmid}${nextg}${closeg}${tr}${FT_COLOR_RESET}" "$bw"
    # The chrome cells, right to left: ⊠ hard against the corner, then ▶ inside it.
    if (( closew )); then FT_BEACON_CLOSE[$name]="$boxT $(( boxL + bw - 2 ))"; else unset "FT_BEACON_CLOSE[$name]"; fi
    if (( nextw )); then FT_BEACON_NEXT[$name]="$boxT $(( boxL + bw - 2 - closew ))"; else unset "FT_BEACON_NEXT[$name]"; fi
    for (( i=0; i<nlin; i++ )); do
        ft_fit_align "${lines[$i]}" "$iw" left            # pad the line to the box interior
        ft_print_at_width $(( boxT + 1 + i )) "$boxL" "${edge}${vt}${chip} ${FT_FIT} ${FT_COLOR_RESET}${edge}${vt}${FT_COLOR_RESET}" "$bw"
    done
    ft_print_at_width "$boxB" "$boxL" "${edge}${bl}${mid}${br}${FT_COLOR_RESET}" "$bw"

    # THE LEADER IS NOT DERIVED HERE. _ft_beacon_leader is the single definition of what line a
    # given box gets, and the placement search scored this box using that very call — so what was
    # chosen and what is painted cannot drift apart. (They used to: the search modelled a straight
    # corridor while this code ran the router, and every disagreement between them was a callout
    # that looked nothing like the one that won.) The obstacle list must be the live one, since a
    # cached placement skips the search entirely.
    local exT=$boxT exL=$boxL exB=$boxB exR=$boxR ar_r ar_c ar_g
    # THE LEADER IS A PURE FUNCTION OF (placement, layout) — so it is CACHED on exactly those:
    # the placement key plus the layout epoch. Recomputing it every draw meant every recomposite
    # of a parked callout paid an obstacle rebuild and a routing pass — 20 of the 25ms a single
    # parked-callout draw cost, run on every release settle and every animation frame that
    # touched the box. A relayout bumps the epoch and the next draw re-routes; the drag path
    # changes the pkey per park, so a dragged callout re-routes at each release exactly as
    # before.
    local _ldrkey="${pkey}|${FT_LAYOUT_EPOCH}"
    if [[ "${FT_BEACON_LDRKEY[$name]:-}" == "$_ldrkey" && -n "${FT_BEACON_LDRC[$name]:-}" ]]; then
        read -r place ar_r ar_c FT_LEADER_LENGTH FT_LEADER_HEAD_INSIDE_BOX <<< "${FT_BEACON_LDRC[$name]%%$'\x1f'*}"
        FT_LEADER_POLYLINE=${FT_BEACON_LDRC[$name]#*$'\x1f'}
        FT_LEADER_SIDE=$place; FT_LEADER_ARROW_ROW=$ar_r; FT_LEADER_ARROW_COLUMN=$ar_c
    else
        local _prev_extra=$FT_ROUTE_EXTRA; FT_ROUTE_EXTRA=""
        # A DRAGGED, uncaged callout may sit outside its home frame, and its leader then has to
        # cross the ring — so the ring's strips are in this list. A placed (or caged) one is
        # inside the frame and its list is the search's: the ring excluded (see the search).
        if [[ -n "$drag" && -z "$caged" ]]; then _ft_route_obstacles
        else                                      _ft_route_obstacles "$bb"; fi
        # …AND EVERY OTHER OVERLAY'S PUBLISHED INK, which the layout walk never reports. This
        # is the preamble the fix originally missed: a dragged callout's leader is computed
        # HERE and nowhere else, so it was the one leader routed through a neighbour's halo.
        _ft_beacon_push_overlay_ink "$name"
        FT_ROUTE_EXTRA=$_prev_extra
        _ft_beacon_leader "$boxT" "$boxL" "$boxB" "$boxR" "$apad" "$vpad" "$anchor"
        place=$FT_LEADER_SIDE; ar_r=$FT_LEADER_ARROW_ROW; ar_c=$FT_LEADER_ARROW_COLUMN
        FT_BEACON_LDRKEY[$name]=$_ldrkey
        FT_BEACON_LDRC[$name]="$place $ar_r $ar_c $FT_LEADER_LENGTH $FT_LEADER_HEAD_INSIDE_BOX"$'\x1f'"$FT_LEADER_POLYLINE"
    fi
    case "$place" in above) ar_g=$dn ;; below) ar_g=$up ;; left) ar_g=$rt ;; *) ar_g=$lf ;; esac
    local _poly=$FT_LEADER_POLYLINE
    # NO ROOM FOR A LINE MEANS NO LINE — AND NO ARROWHEAD EITHER. When the chip ends up hard
    # against its target, the exit cell IS the arrowhead cell: the polyline collapses to a single
    # point and what gets painted is an arrow glyph wedged between two borders, pointing at
    # nothing, with no line behind it. That reads as a rendering fault, and it is the one thing a
    # reader cannot interpret — better to say nothing than to say it incoherently. A chip sitting
    # against the thing it describes is already unambiguous without a one-cell arrow.
    #
    # FT_LEADER_HEAD_INSIDE_BOX is exactly this condition: the head swallowed by its own box. The placement
    # search prices it at _TARGET_COVER_COST so it only ever happens where the screen left no
    # alternative. (A ZERO-LENGTH leader used to set it too, which suppressed the head of a box
    # parked one free row above its target — it now draws its head alone in that row; see the
    # contract.)
    if (( FT_LEADER_HEAD_INSIDE_BOX )); then
        _poly=""
        FT_BEACON_LEADER[$name]=""
    else
        # THE LINE IS ATTACHED TO THE BOX — VISIBLY. The routed polyline begins at the exit cell,
        # one cell OUTSIDE the border. When its first run is perpendicular to that edge the stem
        # happens to touch the border and reads as joined; but when the head sits on the very row
        # beside the box, the first run is PARALLEL to the edge and the whole line floated one row
        # under the box with nothing holding it ("the arrowhead doesn't connect to the callout" —
        # p4:3 and p5:3 at 62×33, winner poly=[13 52 13 49]: exit, a one-cell dp out, the route
        # straight back, simplified to a bare ───). So the DRAWN line begins ON the border: a
        # T-junction glyph in the border cell the exit leaves from (┬ ┴ ├ ┤), the one-cell stub,
        # and — when the line then turns — a real corner at the exit cell: ◀──╯ hanging from ┬.
        # The leader's contract, price, cache and erase footprint are untouched; this is only how
        # the winner is painted, and the junction cell is inside the box rect the erase already
        # covers.
        local _jr=-1 _jc=-1 _jg="" _p0r _p0c
        set -- $_poly; _p0r=${1:-}; _p0c=${2:-}     # a head drawn alone has NO poly (set -u)
        if   (( _p0r == boxB+1 && _p0c > boxL && _p0c < boxR )); then _jr=$boxB; _jc=$_p0c; _jg=$'┬'
        elif (( _p0r == boxT-1 && _p0c > boxL && _p0c < boxR )); then _jr=$boxT; _jc=$_p0c; _jg=$'┴'
        elif (( _p0c == boxR+1 && _p0r > boxT && _p0r < boxB )); then _jr=$_p0r; _jc=$boxR; _jg=$'├'
        elif (( _p0c == boxL-1 && _p0r > boxT && _p0r < boxB )); then _jr=$_p0r; _jc=$boxL; _jg=$'┤'
        fi
        if (( _jr >= 0 )); then
            (( FT_USE_UTF8 )) || _jg=+
            ft_route_draw "$_jr $_jc $_poly" "$edge"
            # The top border carries chrome — the number badge after the left corner, then the ▶
            # and the ⊠ against the right one. A junction landing on a chrome cell keeps the
            # chrome: the stub still touches the border, the badge is the thing the reader finds
            # the box by, and a close box you cannot see is a close box you cannot click.
            if   (( _jr == boxT && numw > 0 && _jc > boxL && _jc <= boxL+numw )); then _jg=$nglyph; _jc=$(( boxL+1 ))
            elif (( _jr == boxT && closew && _jc == boxR-1 )); then _jg=$closeg
            elif (( _jr == boxT && nextw && _jc == boxR-1-closew )); then _jg=$nextg; fi
            ft_print_at "$_jr" "$_jc" "${edge}${_jg}${FT_COLOR_RESET}"
        else
            ft_route_draw "$_poly" "$edge"
        fi
        FT_BEACON_LEADER[$name]=$_poly    # the routed waypoints, for precise erase/inspection
        ft_print_at "$ar_r" "$ar_c" "${edge}${ar_g}${FT_COLOR_RESET}"
    fi

    # Publish the painted footprint (box ∪ the WHOLE routed polyline, which may detour outside
    # box∪arrow) so a caller replacing this callout can erase it, and the box rect so the mouse
    # handler knows the draggable region.
    local _wr _wc _wi=0
    for _wr in $_poly; do
        if (( _wi % 2 == 0 )); then _wc=$_wr
        else (( _wc<exT )) && exT=$_wc; (( _wc>exB )) && exB=$_wc
             (( _wr<exL )) && exL=$_wr; (( _wr>exR )) && exR=$_wr; fi
        (( _wi++ ))
    done
    (( ar_r<exT )) && exT=$ar_r; (( ar_r>exB )) && exB=$ar_r
    (( ar_c<exL )) && exL=$ar_c; (( ar_c>exR )) && exR=$ar_c
    FT_BEACON_EXTENT[$name]="$exT $exL $exB $exR"
    # Publish each leader segment (plus the arrowhead cell) as overlay-extra rects: the per-frame
    # recomposite tests the BOX rect only, so an animated control repainting cells under the LINE
    # — the pulsing ghost outline's dashed border is the live case — wiped it for a frame and the
    # leader flickered. With the segments published, that repaint recomposites this callout; a
    # margin-parked callout still costs nothing, because nothing animated intersects its line.
    local _sr0 _sc0 _sr1 _sc1 _si=0 _sx=""
    set -- $_poly
    while (( $# >= 4 )); do
        _sr0=$1; _sc0=$2; _sr1=$3; _sc1=$4; shift 2
        _sx+="$(( _sr0<_sr1?_sr0:_sr1 )) $(( _sc0<_sc1?_sc0:_sc1 )) $(( _sr0<_sr1?_sr1:_sr0 )) $(( _sc0<_sc1?_sc1:_sc0 ));"
    done
    _sx+="$ar_r $ar_c $ar_r $ar_c"
    FT_OVERLAY_EXTRA[$name]=$_sx
    # Tell the compositor what we ACTUALLY painted — a callout's box+leader+arrowhead reach far
    # outside its layout box, so this is what must be damaged when it moves or is removed.
    ft_publish_paint_rect "$name" "$exT" "$exL" "$exB" "$exR"
    FT_BEACON_BOX[$name]="$boxT $boxL $boxB $boxR"
    # The anim path recomposites us only if a repainted control touches this rect. Use the BOX,
    # NOT the full extent: the thin leader/arrow sit just OUTSIDE the target, which the target's
    # own animation never repaints — so a callout parked in the margin is skipped every frame
    # (this was recompositing the callout ~10×/s during a target's @keyframes animation = lag).
    FT_OVERLAY[$name]="$boxT $boxL $boxB $boxR"
}

# ── Lifecycle ────────────────────────────────────────────────────────────────
# _ft_beacon_arm NAME — start the beacon's animation. persist loops forever;
# oneshot runs `cycles` laps then the frame routine destroys it. Called by the
# ft-beacon constructor, and re-callable to restart.
# Properties that decide whether this beacon animates at all, and therefore need it re-armed
# rather than merely repainted. Registered in FT_CLASS_REPROP so ft-modify tells us; nothing in
# the engine knows what `effect` means. demo/callout-demo.bash used to call _ft_beacon_arm
# itself after every `ft-modify … effect=…`, which is the app doing the class's job.
_ft_beacon_reprop() {           # name "key key …"
    # ANY WRITE MAY MOVE ALL OF IT. A beacon finds its placement by searching during the draw —
    # a longer text, another number, a different variant each land the box and leader somewhere
    # else — so nothing before the draw can say which cells it will leave. Give back the whole
    # footprint it last inked; the settle refills it and repaints what was underneath, and the
    # beacon composites on top.
    #
    # EXCEPT WHILE A DRAG HOLDS IT. The drag writes parkedTop/parkedLeft through ft-modify on
    # every move and then damages exactly the cells it vacated — a bounding box per move is what
    # once cost 1862ms of a 2100ms drag — so for the gesture's lifetime the drag owns this
    # beacon's damage. Measured before this guard existed (tools/bench-drag.bash, four runs):
    # the worst frame 31ms → 42ms, every run.
    [[ "${_FT_BEACON_GRAB%% *}" == "$1" ]] || _ft_ink_beacon "$1"
    case " $2 " in
        *" effect "*|*" lifetime "*|*" variant "*) _ft_beacon_arm "$1" ;;
    esac
    return 0
}
_ft_beacon_arm() {              # name
    local n=$1 life cyc loop len eff
    [[ -z "${FT_TYPE[$n]:-}" ]] && return 1
    ft_resolved_prop "$n" variant frame
    # Z-ORDER AMONG OVERLAYS, DERIVED WHERE BOTH ROUTES PASS. A CALLOUT is the most on-top of
    # all — it must never be painted over, not even by another beacon (a frame/number/ghost) —
    # so callouts get z=10 and everything else z=0, and the two-pass composite paints callouts
    # LAST. Changing `variant` at runtime is a supported route (that is what FT_CLASS_REPROP is
    # for, and it lists `variant`), but the tier was derived in the CONSTRUCTOR alone: after
    # `ft-modify b variant=callout` the property said callout and the cached tier still said 0,
    # so a runtime-made callout was painted in the tier-0 pass and any frame beacon could paint
    # over it — the contract above, broken by the sibling route. Both routes call this function;
    # the derivation belongs to it, not to one of its callers. (Nothing here re-reads FT_RET,
    # so the variant the bigarrow branch tests below is still the one just resolved.)
    [[ "$FT_RET" == callout ]] && FT_OVERLAY_Z_ORDER[$n]=10 || FT_OVERLAY_Z_ORDER[$n]=0
    [[ "$FT_RET" == bigarrow ]] && { _ft_bigarrow_arm "$n"; return $?; }
    ft_resolved_prop "$n" lifetime persist; life=$FT_RET
    ft_resolved_prop "$n" effect pulse;     eff=$FT_RET
    # A STATIC, persistent beacon needs no animation at all — the normal redraw paints
    # it (it is a tree child) and it never changes. Arming a per-frame loop for it would
    # keep the whole event loop polling fast and re-drawing every frame for nothing (the
    # cause of the demo's input lag). Motion effects (pulse/blink/bob) still arm.
    if [[ "$life" == persist && ( "$eff" == none || "$eff" == static || -z "$eff" ) ]]; then
        ft_dirty "$n"; return 0
    fi
    if [[ "$eff" == shimmer ]]; then    # a SINGLE gentle fade, then self-destruct — loop=0 so the
        ft_anim_start "$n" "$FT_BEACON_SHIMMER_PERIOD" "$FT_BEACON_SHIMMER_MS" 1 0   # loop stops (no lag)
        ft_anim_bind  "$n" _ft_beacon_frame beacon
        return 0
    fi
    ft_resolved_prop "$n" cycles 2;         cyc=$FT_RET
    (( cyc < 1 )) && cyc=1
    if [[ "$life" == oneshot ]]; then loop=0; len=$(( cyc * FT_BEACON_PERIOD ))
    else loop=1; len=$FT_BEACON_PERIOD; fi
    ft_anim_start "$n" "$len" "$FT_BEACON_MS" 1 "$loop"
    ft_anim_bind  "$n" _ft_beacon_frame beacon
    return 0
}
# The engine calls this every due frame as  FRAME NAME STRUCT. It owns the
# lifecycle: a oneshot's final frame erases the ground it covered and destroys
# the beacon; otherwise it repaints the beacon on top at the new phase.
_ft_beacon_frame() {            # name struct
    local name=$1
    [[ -z "${FT_TYPE[$name]:-}" ]] && return
    local ph=${FT_ANIM_PHASE[$name]:-0} life len
    ft_resolved_prop "$name" lifetime persist; life=$FT_RET
    len=${FT_ANIM_LENGTH[$name]:-$FT_BEACON_PERIOD}
    if [[ "$life" == oneshot ]] && (( ph >= len - 1 )); then
        _ft_beacon_ground "$name"; local g=$FT_RET
        ft_remove "$name"
        [[ -n "$g" ]] && { ft_dirty_subtree "$g"; ft_redraw_dirty; }
        ft_flush
        return
    fi
    # A beacon that FADES OUT (shimmer/blink going invisible) leaves its last outline behind —
    # paint doesn't erase. On the visible→invisible transition, repaint the ground it framed so
    # the outline clears; the overlay composite then puts any callout back on top. Only at the
    # transition (once per cycle), never every invisible frame.
    _ft_beacon_rect "$name"
    if (( FT_BEACON_RECT_OK )); then
        _ft_beacon_effect "$name" border "$ph"
        if (( ! FT_BEACON_EFFECT_VISIBLE )) && [[ "${FT_BEACON_WASVIS[$name]:-0}" == 1 ]]; then
            _ft_beacon_ground "$name"; local g=$FT_RET
            [[ -n "$g" ]] && { ft_dirty_subtree "$g"; ft_redraw_dirty; }
        fi
        FT_BEACON_WASVIS[$name]=$FT_BEACON_EFFECT_VISIBLE
    fi
    # The tree-walk draw path paints into the buffer and lets the outer redraw
    # flush; the standalone animation frame must push its own paint to the tty.
    _ft_draw_beacon "$name"
    ft_flush
}

# ═════════════════════════════════════════════════════════════════════════════
#  variant=bigarrow — a giant arrow, drawn as unicode art, that bounces in
# ═════════════════════════════════════════════════════════════════════════════
#
#  WHY THESE GLYPHS. docs/unicode-art.md is the evaluation and it is not optional reading
#  before touching the tables below. The short version, with the numbers, because the two
#  obvious candidates both LOSE:
#
#    · box diagonals ╱ ╲ ╳ — the first thing anyone reaches for — added EXACTLY 0.00 to the
#      rendering accuracy of a big arrow. A best-match rasteriser was free to choose them for
#      any cell and never once did, at any size: a diagonal glyph is a one-cell STROKE (~8 of
#      64 sub-cells of ink), and it has exactly ONE angle — 63.2° on this machine's font once
#      the aspect is corrected — where an arrow's barbs want about 30°. Corner triangles
#      ◢◣◤◥ failed identically, also 0.00.
#    · braille has the best sub-pixel geometry of anything here (2×4 dots on a 1:2 cell are
#      the only SQUARE sub-pixels in the running) and still loses, because it CANNOT FILL.
#      ⣿ is eight separated dots: the shaft renders as corduroy and the tip as ⡷⠆. Braille is
#      the right tool for a hairline curve and the wrong one for a wedge.
#    · sextants / octants: 0 of 338 code points present across the four fonts on this machine,
#      an 11,172-glyph Nerd Font included. Not a judgement call.
#
#  WHAT WON. Per column (per row for a vertical arrow) the arrow occupies ONE continuous
#  interval — the shape is convex on its cross-axis — so a cell's coverage is a contiguous run
#  of sub-rows, and a run anchored to the bottom of a cell IS a lower-eighth block ▁▂▃▄▅▆▇.
#  Eight sub-positions per cell, chosen by eight integer operations and a table index, with no
#  per-cell search at all. (The exhaustive best-match that produced the numbers above is
#  30 glyphs × 64 sub-cells × every cell: right answer, impossible algorithm.)
#
#  …AND WHAT IS NO LONGER COMPUTED AT ALL. Everything above is about WHICH GLYPH, and it all
#  stands. What used to sit on top of it — an angle, a head fraction and a shaft fraction fitted
#  to whatever length the placer could find, rasterised fresh at every size — does not. A shape
#  solved per size looks hand-drawn at one size and broken at the rest, which is what two
#  screenshots of the same app at two widths showed. The shape is now AUTHORED: four sizes in
#  the sprite sheet below, chosen with `size`, drawn exactly as written every time. See
#  docs/unicode-art.md §12, and §12c for the silhouette border, which is the same technique
#  again — an anchored eighth is how a border one eighth of a cell thick exists at all.
#
#  Unicode has lower eighths and left eighths and NO upper or right eighths. The glyphs that
#  would fix that exist — U+1FB82–1FB8B — and are 0-of-22 in all four fonts. Without them one
#  barb of every arrow would be crisp and the other chunky, which reads as BROKEN rather than
#  as "slightly coarser". So the missing family is synthesised by painting the complement with
#  the colours swapped (FT_ANSI_REVERSE): "top ⅜ in arrow colour" is ▅ drawn fg/bg reversed.
#  Mean boundary error 3.45 sub-cells of 64, against solid █'s 24.94, on a 30-cell arrow.
#
#  THE ASPECT IS A VARIABLE, NOT A `* 2` IN A LOOP. Measured out of hhea/hmtx rather than
#  assumed: 1:1.983 for Cascadia/CaskaydiaCove, 1:2.130 Consolas, 1:1.660 Lucida Console.
#  Every dimension below is in VISUAL units (one unit = one cell WIDTH) and a cell row is
#  FT_BIGARROW_ASPECT units tall. Skip the correction and a 26° arrowhead draws as a 46° spade
#  — wrong in exactly the way that is hard to name when you look at it.
#
FT_BIGARROW_ASPECT=2            # cell height ÷ cell width — see above
FT_BIGARROW_FRAMES=20           # frames in one flight
FT_BIGARROW_MS=560              # ms for the whole flight, when nothing in the cascade says
FT_BIGARROW_EASING=ease-out-back   # …and its timing function. Both are only the FLOOR: an
                                   # instance property or a stylesheet rule outranks them,
                                   # which is why neither is a class default.
# The two anchored eighth families, indexed 0..8 by eighths filled. Index 0 is a space and is
# never emitted — a blank cell is skipped, not painted, so an arrow never stamps its bounding
# box onto the screen. `smoothing=halves` reuses the same tables at a coarser step (index 0/4/8
# is exactly ▀▄▌▐█), which is the whole of the Consolas/Lucida rung: one table, three rungs.
_FT_BIGARROW_LOWER=(" " "▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")   # filled from the BOTTOM
_FT_BIGARROW_LEFT=(" " "▏" "▎" "▍" "▌" "▋" "▊" "▉" "█")    # filled from the LEFT
# A run touching NEITHER edge of its cell is U+1FB70-7B, which no font measured has. When such
# a run is thin AND roughly centred, box drawing finally earns a place here: ━ and ┃ are
# centred in their cell by construction and are in every font measured, Lucida Console
# included. This is the one job the box-drawing block gets in this variant, and it is not the
# one it was nominated for.
_FT_BIGARROW_BAR_H="━"; _FT_BIGARROW_BAR_V="┃"
# A run of full cells, grown on demand and sliced. Only the no-hairline fallback needs it (a
# terminal whose ink colour cannot be read back as RGB), and building it there would be a
# string built per run per frame.
_FT_BIGARROW_SOLID_RUN=""

# ═════════════════════════════════════════════════════════════════════════════
#  THE SPRITE SHEET — four sizes, drawn by hand, never recomputed
# ═════════════════════════════════════════════════════════════════════════════
#
# WHAT THIS REPLACED, AND WHY. This variant used to SOLVE its shape: an angle, a head fraction
# and a shaft fraction in milli-visual units, fitted to whatever length the placer could find,
# rasterised fresh per size. It is a defensible piece of code and it produced a different arrow
# in every window. The reported verdict on two screenshots of the same app at two widths was
# "that's unusable" — at 80 columns a stub that reads as a bar with a bump on it, at 190 a
# recognisable arrow with a notch bitten out of the shaft. Both were the rasteriser doing
# exactly what it was told; the defect was that it was told to invent a shape at all.
#
# A shape solved per size looks hand-drawn at one size and broken at the rest. So the shape is
# now AUTHORED: four sizes, each checked by eye, each drawn exactly as authored every time.
# Nothing here is fitted, scaled or rounded at paint time.
#
# THE ARITHMETIC EACH SIZE LANDS ON. The cell is 1:2, so one visual unit is one column across
# and half a row down; the glyph set gives EIGHTHS along a cell's height and along its width.
# Every size is built from the same three exact numbers:
#
#   · the head's edge falls 2 SUB-ROWS PER COLUMN (horizontal) or widens ONE CELL PER SIDE PER
#     ROW (vertical). Both are the same angle once the aspect is corrected — atan(0.5) = 26.57°
#     — and both are exact runs, so every step of the staircase is identical to every other.
#     That regularity is the whole reason a hand-drawn shape reads as deliberate.
#   · the head is exactly HALF the arrow's length.
#   · the horizontal sizes have an EVEN row count, so the axis falls on a cell BOUNDARY and
#     the converging tip is two anchored runs — one eighth above it and one eighth below —
#     instead of a run floating in the middle of a cell, which is the one case no font here
#     has a glyph for (§6c). An odd count buys the shaft a true centre row and pays for it
#     with a BLUNT TIP: measured, the head's last full cell followed by a mid-height `━` bar,
#     which is what "none of them look pointy" was looking at. §9a said this first.
#
#   size      long   horizontal        across   vertical          across   shaft
#   small     20     20 cols × 4 rows   8        9 cols × 10 rows   9       3 visual
#   medium    28     28 × 6            12       13 × 14           13       4
#   large     36     36 × 8            16       17 × 18           17       6
#   x-large   44     44 × 10           20       21 × 22           21       8
#
# THE TWO AXES ARE THE SAME LENGTH AND ONE UNIT APART ACROSS, and that one unit is forced. A
# horizontal arrow needs an EVEN row count so its axis lands on a cell boundary and the tip can
# converge; a vertical one needs an ODD column count so its apex is a single centred cell. Even
# and odd cannot both be had, so `size: large` is 36×16 pointing sideways and 36×17 pointing
# down. One column in seventeen, against a tip that would otherwise be blunt on one axis or
# lopsided on the other.
#
# The two axes of one size are the SAME visual size — 4R visual long by 2R across, whichever
# way it points — so `size: large` means one thing however the placer turns it.
#
# ── The authoring alphabet ───────────────────────────────────────────────────
#   .            an empty cell (never painted, so an arrow never stamps its box on the screen)
#   █            a full cell
#   ▁▂▃▄▅▆▇      that many eighths, filled from the cell's BOTTOM
#   ▏▎▍▌▋▊▉      …from the cell's LEFT
#   ▐            filled from the cell's RIGHT. With ▀ it is one of only two right/upper block
#                characters Unicode has (§6b), and it is the one a vertical arrow's shaft edge
#                needs. SYNTHESISED at paint time from the left family, like everything else
#                anchored to an edge Unicode forgot.
#   ━            a thin bar centred in the cell — the tip, where the shape is under a
#                quarter-cell thick and no anchored glyph is honest
#
# ── Why the horizontal sprites are authored as their TOP HALF ────────────────
# Unicode has lower eighths and left eighths and no UPPER or RIGHT ones (§6b: U+1FB82–8B are
# 0-of-22 in every font measured), so the bottom barb of a horizontal arrow can only be drawn
# by painting its complement with the colours swapped. There is therefore no character to
# AUTHOR it with — writing U+1FB86 in this file would show a box in every editor. So a
# horizontal sprite is authored down to and including its centre row and the loader mirrors it,
# flipping the anchoring as it goes. That also makes each one symmetric by construction, which
# is half of "looks deliberate".
#
# The vertical sprites need no such trick: their only partial glyphs are the two HALF blocks
# ▌ and ▐, both of which are real characters in every font measured, so they are authored
# whole and read as the picture they are.
declare -A FT_BIGARROW_SPRITE=()
# ── The four horizontal sizes, authored as their TOP HALF ───────────────────
# Read a row as: `.` empty, `█` a full cell, and ▁▂▃▄▅▆▇ that many eighths filled from the
# cell's BOTTOM. The head's top edge therefore steps down two eighths per column all the way
# from the head base to the tip — one exact, unvarying run — and the last column is a single
# eighth on each side of the axis, which is the point.
FT_BIGARROW_SPRITE[small|h]='...........█▆▄▂.....
▆▆▆▆▆▆▆▆▆▆▆█████▆▄▂▁'
FT_BIGARROW_SPRITE[medium|h]='...............█▆▄▂.........
...............█████▆▄▂.....
████████████████████████▆▄▂▁'
FT_BIGARROW_SPRITE[large|h]='...................█▆▄▂.............
...................█████▆▄▂.........
▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄█████████▆▄▂.....
████████████████████████████████▆▄▂▁'
FT_BIGARROW_SPRITE[x-large|h]='.......................█▆▄▂.................
.......................█████▆▄▂.............
.......................█████████▆▄▂.........
████████████████████████████████████▆▄▂.....
████████████████████████████████████████▆▄▂▁'
# ── …and the same four pointing DOWN, authored whole ────────────────────────
# These need no mirroring: the only partial glyphs a vertical arrow uses are ▌ and ▐, and both
# are real characters. The head is the classic block-arrow staircase — one cell wider on each
# side per row, an exact run at the same 26.57° once the aspect is corrected — ending in a
# SINGLE CELL. That single cell is the sharpest apex the glyph set allows on this axis, and the
# reason is worth knowing: a cell has eighth resolution ACROSS a vertical arrow and NONE along
# it, so the apex row cannot taper within itself. An earlier draft ended with a quarter-cell
# sliver instead; it was sharper by measurement and worse by eye, because the step into it was
# fourteen eighths where every other step is sixteen — a spike on the end of a triangle.
FT_BIGARROW_SPRITE[small|v]='...███...
...███...
...███...
...███...
...███...
█████████
.███████.
..█████..
...███...
....█....'
FT_BIGARROW_SPRITE[medium|v]='....▐███▌....
....▐███▌....
....▐███▌....
....▐███▌....
....▐███▌....
....▐███▌....
....▐███▌....
█████████████
.███████████.
..█████████..
...███████...
....█████....
.....███.....
......█......'
FT_BIGARROW_SPRITE[large|v]='.....▐█████▌.....
.....▐█████▌.....
.....▐█████▌.....
.....▐█████▌.....
.....▐█████▌.....
.....▐█████▌.....
.....▐█████▌.....
.....▐█████▌.....
.....▐█████▌.....
█████████████████
.███████████████.
..█████████████..
...███████████...
....█████████....
.....███████.....
......█████......
.......███.......
........█........'
FT_BIGARROW_SPRITE[x-large|v]='......▐███████▌......
......▐███████▌......
......▐███████▌......
......▐███████▌......
......▐███████▌......
......▐███████▌......
......▐███████▌......
......▐███████▌......
......▐███████▌......
......▐███████▌......
......▐███████▌......
█████████████████████
.███████████████████.
..█████████████████..
...███████████████...
....█████████████....
.....███████████.....
......█████████......
.......███████.......
........█████........
.........███.........
..........█..........'
# THE LADDER, smallest first. `size` names a rung; nothing else does.
_FT_BIGARROW_SIZES=(small medium large x-large)
# …and the one number per size the authored art does not already state: how thick the shaft
# is, in VISUAL units, which the burial score needs and no reader should have to count.
declare -A FT_BIGARROW_SHAFT_VISUAL=([small]=3 [medium]=4 [large]=6 [x-large]=8)

declare -A FT_BIGARROW_ART=()      # shape key → "row col paint width glyphs" ×N, space
                                   #   separated. See the paint-mode table in the loader.
declare -A FT_BIGARROW_ROWSPAN=()  # …same key → "row lo hi" ×rows: each row's painted interval,
                                   #   RELATIVE to the origin, so a move damages exactly the
                                   #   cells it vacates instead of a bounding box
declare -A FT_BIGARROW_SPAN=()     # …same key → "cols rows" of the sprite as drawn
declare -A FT_BIGARROW_AT=()       # name → "top left key" of the last paint (the erase record)
declare -A FT_BIGARROW_EASE=()     # name → the precomputed fly-in curve, thousandths per frame
declare -A FT_BIGARROW_XEASE=()    # name → …and the exit curve
declare -A FT_BIGARROW_STAGE=()    # name → fly | hold | exit — see the lifecycle note below
declare -A FT_BIGARROW_PKEY=()     # name → the placement question, incl. FT_LAYOUT_EPOCH
declare -A FT_BIGARROW_PC=()       # name → "dir len rows cols top left key" the answer to it

# ── Getting out of the way ───────────────────────────────────────────────────
# A HUGE ARROW IS THE RIGHT AMOUNT OF EMPHASIS FOR A SECOND AND THE WRONG AMOUNT AFTER TEN.
# That was the first thing said about it after looking at one, and it is the difference between
# a pointer and an obstruction. So a bigarrow RETIRES BY DEFAULT — `lifetime=persist` is now a
# deliberate choice rather than what you get by forgetting, which is the opposite of the way
# the other variants default and is on purpose (a ring or a badge is one cell of chrome; this
# is two hundred cells sitting on the page).
#
# Its life is three stages, and each is its own animation so that WAITING IS FREE. Running one
# 20fps animation through the hold would tick ~85 frames of nothing, at ~15ms each, for two and
# a half seconds — which is exactly the "a perpetual animation is what turns into input lag"
# rule this framework already has. The hold is therefore a TWO-FRAME animation whose frame IS
# the whole wait: one wakeup, then the exit.
#
# TWO ANIMATIONS ON ONE ELEMENT IS A LIST, which is CSS's own answer and needs no new property
# names — see _ft_bigarrow_styled_nth. `exitDuration`, `exitTimingFunction` and `holdDuration`
# were invented names for animation-duration, animation-timing-function and animation-delay.
#
#   fly    the bounce, animation-duration / animation-timing-function ITEM 1
#   hold   landed and still, until animation-delay ITEM 2      (one wakeup)
#   exit   animation-duration / animation-timing-function ITEM 2, then it destroys itself and
#          damages every cell it drew, because an overlay paints outside its
#          layout box and nothing else knows those cells were ever touched
#
# TWO EXITS, BOTH BUILT, BOTH LOOKED AT — see docs/unicode-art.md §11 for the pictures:
#   exit=retract  it whips back out the way it came in. Free: the same offset machinery as the
#                 bounce, the same vacated-strip damage, no colour maths at all. With an -back
#                 curve it leans a cell TOWARD the target first and then goes, which is the
#                 cartoon grammar the arrow is already speaking.  ← SHIPPED DEFAULT
#   exit=fade     it blends toward the ground over the same frames (the shimmer effect's
#                 technique: ft_sgr_rgb both ends, lerp, ft_rgb_sgr). Honest, and it works —
#                 but it dissolves IN PLACE, so for the last third of it there is a large
#                 dim arrow-shaped smudge over the page, which is a milder version of the
#                 complaint. It also needs a truecolor-or-256 fg AND bg to look right.
#   exit=none     it vanishes on the frame it retires. Kept as the control.
FT_BIGARROW_EXIT=retract        # …all four are only the FLOOR: an instance property or a
FT_BIGARROW_HOLD_MS=2400        #    stylesheet rule outranks them (see _ft_bigarrow_styled_nth);
FT_BIGARROW_EXIT_MS=420         #    which is why none of them is a class default.
FT_BIGARROW_EXIT_EASING=ease-in-back
FT_BIGARROW_EXIT_FRAMES=12      # frames in the exit — its own count, because a retract is a
                                # shorter move than the fly-in and does not need as many

# A property whose NAME comes from CSS resolves through the cascade; one that is ours resolves
# through the class. Both surfaces exist for a reason and mixing them is how a stylesheet rule
# becomes silently unreachable — see the note on the class defaults above.
_ft_bigarrow_styled() {         # name prop fallback → FT_RET
    if [[ -n "${_FT_CSS_LOADED:-}" ]]; then
        ft_style "$1" "$2"; (( ${#FT_RET} > 0 )) && return 0
    else
        ft_own_prop "$1" "$2"; (( ${#FT_RET} > 0 )) && return 0
    fi
    FT_RET=$3; return 0
}
# …and the SECOND ITEM of it, which is how CSS says "and this one is for the other animation".
# An arrow is two animations on one element — it flies, then it leaves — and CSS already spells
# that as a comma-separated list per longhand, so the leaving reads item 2 of the very
# properties the flight reads item 1 of:
#
#     beacon[variant=bigarrow] {
#         animation-duration:        560ms, 420ms;    /* fly, leave                  */
#         animation-timing-function: ease-out-back, ease-in-back;
#         animation-delay:           0ms, 2960ms;     /* leave starts at 2960ms      */
#     }
#
# This replaced `exitDuration`, `exitTimingFunction` and `holdDuration` — three names for
# things CSS had already named. A one-item list still means "both", per CSS's repeat rule.
_ft_bigarrow_styled_nth() {     # name prop index fallback → FT_RET
    local fallback=$4
    _ft_bigarrow_styled "$1" "$2" ""
    if (( ${#FT_RET} == 0 )); then FT_RET=$fallback; return 0; fi
    ft_css_list_nth "$FT_RET" "$3"
    (( ${#FT_RET} == 0 )) && FT_RET=$fallback
    return 0
}
# …and the shape properties, read straight from their property variables. Same reason
# _ft_border and _ft_padding do it (see ft-forms.bash): ft_resolved_prop is ~62µs against ~10µs here,
# and the geometry reads them EVERY PAINT — a keystroke recomposites every overlay, so these
# are on the typing path, not just the animation path. Safe because every one of them is
# a class default, so it is always set on the instance and the ancestor walk ft_resolved_prop does can
# only ever find the same answer. None of them coerce.
_ft_bigarrow_prop() {           # name prop default → FT_RET
    local v="_ftp_${1}_${2}"; v=${!v-}
    (( ${#v} == 0 )) && v=$3
    FT_RET=$v
}
# …and the NUMERIC ones, which is a separate function because a geometry value that reaches
# `(( ))` is not merely a wrong number if it is not a number: `(( ${arr[$(id)]} ))` EXECUTES.
# arrowGap and bounceTravel are app-supplied and both land in arithmetic below. The framework
# validates the numeric properties it KNOWS about at write time; these are new, so they are
# validated here, at the only place that reads them. `auto` is allowed through for the one that
# accepts it and is never itself put in arithmetic (the caller tests for it first).
_ft_bigarrow_num() {            # name prop default [allowAuto] → FT_RET
    local v="_ftp_${1}_${2}"; v=${!v-}
    (( ${#v} == 0 )) && { FT_RET=$3; return 0; }
    [[ -n "${4:-}" && "$v" == auto ]] && { FT_RET=auto; return 0; }
    # A glob, not extglob — this file must not depend on a shell option an app may not have set.
    case "$v" in *[!0-9]*|"") FT_RET=$3 ;; *) FT_RET=$v ;; esac
}
# ── `size`, which is the ONLY thing that chooses a shape ────────────────────
# THE NAME IS `size` BECAUSE IT IS NOT A FONT. This was `font-size` for one wave, on the
# reasoning that CSS already had the exact problem — a property whose whole purpose is to pick
# from a small absolute ladder rather than take a length — and that reasoning is still why the
# VALUES are CSS's: small | medium | large | x-large. But the thing being sized is a drawing
# made of cells, not type, and a property called font-size on it is a lie about what it is.
# `size` says what it means, and has precedent: HTML gives several elements a `size` attribute
# meaning exactly this, a discrete choice rather than a measurement.
#
# A length was rejected too, and that is the load-bearing half: a length reopens the door to
# the per-window resizing this whole sprite sheet replaced.
#
# THE SEVEN CSS KEYWORDS MAP ONTO FOUR RUNGS. Anything below `small` is `small` — there is no
# smaller arrow worth drawing, which is the same judgement the old MIN_VISUAL floor made — and
# `xx-large` is `x-large`. `larger`/`smaller` are relative to a parent's computed size, which a
# ladder of four authored shapes has no meaning for, so they are not accepted.
#
# UNSET MEANS FIT, AND THAT IS DELIBERATELY NOT A CLASS DEFAULT. A class default is applied as
# an INLINE property at construction (see _ft_apply_args), i.e. cascade level 1 — measured, and
# the reason animationTimingFunction is not one either — so baking `medium` in would make
# `beacon { size: large }` in a stylesheet permanently unreachable, and would turn every screen
# with no room for a medium arrow into a screen with no arrow. Unset, the placer takes the
# LARGEST rung that fits; named, it takes that rung or nothing.
#
# `size` is already a paint-kind property in the engine's own table (ft-forms `_ft_pk`), where
# a textfield's column count lives — so nothing is registered here. One property name, one
# classification, whatever a class means by it.
_ft_bigarrow_size() {           # name → FT_RET = a rung name, or "" for "fit the largest"
    _ft_bigarrow_styled "$1" size ""
    case "$FT_RET" in
        xx-small|x-small|small) FT_RET=small ;;
        medium)                 FT_RET=medium ;;
        large)                  FT_RET=large ;;
        x-large|xx-large)       FT_RET=x-large ;;
        *)                      FT_RET="" ;;
    esac
    return 0
}

# ── The loader: authored art → the span records a frame re-emits ─────────────
# BUILT ONCE PER (size, direction, smoothing) AND THEN NEVER AGAIN. Every frame of a flight
# paints the SAME art at a different origin, because the bounce is a translation along the axis
# and nothing else. That is what makes a frame affordable: the frame does not rasterise, it
# re-emits.
#
# THE PAINT MODES. A cell carries one foreground and one background, and this variant spends
# both: the arrow's ink against the ground behind it, or — on the silhouette — the border
# colour against one of the two. Six combinations, each the reverse of its neighbour:
#
#   0  ink on the ground          the ordinary fill
#   1  the ground on the ink      the fill again, fg/bg swapped: this is the missing eighth
#                                 family (§6b), synthesised by painting the complement
#   2  rim on the ground          an edge cell repainted whole in the border colour
#   3  the ground on the rim      …the same, swapped
#   4  rim on the ink             a HAIRLINE: the glyph is a one-eighth sliver in the border
#                                 colour and the rest of the cell is arrow
#   5  ink on the rim             …the same, swapped: the glyph is the arrow, the sliver is rim
_ft_bigarrow_build() {          # key size dir sub
    local key=$1 size=$2 dir=$3 sub=$4
    local axis=h; [[ "$dir" == up || "$dir" == down ]] && axis=v
    local src=${FT_BIGARROW_SPRITE[$size|$axis]:-}
    (( ${#src} == 0 )) && return 1
    local -a authored=() row_chars=() row_mirror=()
    local line
    while IFS= read -r line; do authored+=("$line"); done <<< "$src"
    local nauth=${#authored[@]} rows cols i r c
    # ── Assemble the full picture from the authored half ────────────────────
    # A horizontal sprite is authored down to and including its centre row; the rows below it
    # are that half reflected, with every partial glyph re-anchored to the opposite edge (which
    # is what `mirror` says). A vertical sprite is authored whole.
    if [[ "$axis" == h ]]; then
        # EVEN, so there is no shared centre row: the axis is the boundary between authored row
        # nauth-1 and its mirror. That is what lets the tip converge (see the note on the sizes).
        rows=$(( 2 * nauth ))
        for (( r=0; r<nauth; r++ )); do row_chars[r]=${authored[r]}; row_mirror[r]=0; done
        for (( r=nauth; r<rows; r++ )); do row_chars[r]=${authored[2*nauth-1-r]}; row_mirror[r]=1; done
    else
        rows=$nauth
        for (( r=0; r<rows; r++ )); do row_chars[r]=${authored[r]}; row_mirror[r]=0; done
    fi
    cols=${#row_chars[0]}
    # ── Point it the other way ──────────────────────────────────────────────
    # `left` is `right` with every row read backwards, and `up` is `down` with the rows in the
    # other order. Neither touches a glyph's ANCHORING: a horizontal sprite's partials are
    # anchored top/bottom and a horizontal flip cannot move that, and a vertical sprite's are
    # anchored left/right, which a vertical flip cannot move either. That is not luck — it is
    # why each axis is authored in the family whose anchor lies across it.
    local -a flipped=() flipmir=()
    if [[ "$dir" == left ]]; then
        local rev j
        for (( r=0; r<rows; r++ )); do
            rev=""; line=${row_chars[r]}
            for (( j=cols-1; j>=0; j-- )); do rev+=${line:j:1}; done
            flipped[r]=$rev; flipmir[r]=${row_mirror[r]}
        done
    elif [[ "$dir" == up ]]; then
        for (( r=0; r<rows; r++ )); do flipped[r]=${row_chars[rows-1-r]}; flipmir[r]=${row_mirror[rows-1-r]}; done
    else
        for (( r=0; r<rows; r++ )); do flipped[r]=${row_chars[r]}; flipmir[r]=${row_mirror[r]}; done
    fi
    # ── Pass 1: one authored character → one glyph and one fg/bg swap ───────
    # …at the smoothing rung in force. The rungs are NOT separate art: an authored eighth is
    # rounded to the nearest level the rung can express (`halves` has three, `solid` two), which
    # is what makes one hand-drawn sprite serve a terminal whose font has the eighth blocks and
    # one whose font has only the halves. FT_USE_UTF8=0 has no sub-cell resolution at all and
    # gets whole cells of '#', jaggies and all.
    local -a cell_glyph=() cell_swapped=() cell_inked=()
    local ch n q mir
    for (( r=0; r<rows; r++ )); do
        line=${flipped[r]}; mir=${flipmir[r]}
        for (( c=0; c<cols; c++ )); do
            i=$(( r * cols + c )); ch=${line:c:1}
            cell_glyph[i]=""; cell_swapped[i]=0; cell_inked[i]=0
            [[ "$ch" == "." || -z "$ch" ]] && continue
            cell_inked[i]=1
            if (( ! FT_USE_UTF8 )); then cell_glyph[i]="#"; continue; fi
            case "$ch" in
                "█")     cell_glyph[i]="█" ;;
                "━"|"┃") cell_glyph[i]=$ch ;;
                *)  # an anchored eighth: which family, how many eighths, and from which edge
                    n=0
                    for (( q=1; q<=7; q++ )); do
                        [[ "$ch" == "${_FT_BIGARROW_LOWER[q]}" ]] && { n=$q; ch=lower; break; }
                        [[ "$ch" == "${_FT_BIGARROW_LEFT[q]}"  ]] && { n=$q; ch=left;  break; }
                    done
                    if (( n == 0 )); then
                        [[ "$ch" == "▐" ]] && { n=4; ch=right; } || { cell_glyph[i]="█"; continue; }
                    fi
                    # the rung: round n/8 to the nearest 1/sub, then back to eighths
                    q=$(( (n * sub + 4) / 8 )); n=$(( q * 8 / sub ))
                    if (( n <= 0 )); then cell_glyph[i]=""; cell_inked[i]=0; continue; fi
                    if (( n >= 8 )); then cell_glyph[i]="█"; continue; fi
                    # `right` is `left` complemented and swapped, and the mirror of a horizontal
                    # sprite's row does the same to `lower` — the two are one rule.
                    case "$ch" in
                        lower) if (( mir )); then cell_glyph[i]=${_FT_BIGARROW_LOWER[8-n]}; cell_swapped[i]=1
                               else               cell_glyph[i]=${_FT_BIGARROW_LOWER[n]}; fi ;;
                        left)  if (( mir )); then cell_glyph[i]=${_FT_BIGARROW_LEFT[8-n]};  cell_swapped[i]=1
                               else               cell_glyph[i]=${_FT_BIGARROW_LEFT[n]};  fi ;;
                        right) if (( mir )); then cell_glyph[i]=${_FT_BIGARROW_LEFT[n]}
                               else               cell_glyph[i]=${_FT_BIGARROW_LEFT[8-n]}; cell_swapped[i]=1; fi ;;
                    esac ;;
            esac
        done
    done
    # ── Pass 2: the SILHOUETTE, and how thick it can afford to be ───────────
    # FOUR NEIGHBOURS, NOT EIGHT, and the diagonal is exactly why. An inked cell is on the
    # outline when one of the four cells sharing an EDGE with it is not inked (a cell off the
    # sprite counts as not inked). Eight-neighbour erosion also marks every cell that merely
    # touches the outside at a CORNER, which on a barb's staircase is the cell under each step:
    # the outline comes out one cell thick on the straight runs and two at every step, so it
    # beats visibly along the diagonal the variant exists to draw well. Both pictures, and the
    # counts, are in docs/unicode-art.md §12.
    #
    # A CELL HAS TWO COLOURS AND AN EDGE CELL HAS ALREADY SPENT BOTH. An eighth-block edge cell
    # is the arrow's ink anchored against the ground showing past it; there is no third colour
    # to put an outline in, and no glyph to draw one OUTSIDE the edge with either (§6b again).
    # So a PARTIAL edge cell is repainted whole in the border colour — which is the honest
    # reading of "the outermost layer" anyway: that cell is half in and half out of the shape.
    #
    # A FULL CELL ON THE EDGE IS THE OPPOSITE CASE, AND IT IS THE COMMON ONE. Where the shape's
    # boundary lands exactly on a cell boundary the edge cell is a solid █: it has no ground
    # showing, so its second colour is free, and repainting it whole would spend a full cell on
    # a boundary of zero thickness. On the horizontal sizes the shaft is bounded by exactly such
    # rows, so whole-cell outlining recoloured the ENTIRE shaft. The fix is the trick the whole
    # variant is built on — draw ▇ with the arrow as its foreground and the rim as its
    # background and the cell is 7/8 arrow under a 1/8 rim line. One exposed side gets that
    # hairline; a corner has no single anchor and stays a whole cell, which is what an end cap
    # should look like anyway.
    local -a cell_edge=() cell_paint=()
    local up down lft rgt sides thin=0
    (( FT_USE_UTF8 && sub >= 2 )) && thin=1     # no sub-cell resolution ⇒ no hairline
    for (( r=0; r<rows; r++ )); do
        for (( c=0; c<cols; c++ )); do
            i=$(( r * cols + c )); cell_edge[i]=0
            if (( ! cell_inked[i] )); then cell_paint[i]=0; continue; fi
            up=1; down=1; lft=1; rgt=1
            (( r > 0        )) && up=${cell_inked[i - cols]}
            (( r < rows - 1 )) && down=${cell_inked[i + cols]}
            (( c > 0        )) && lft=${cell_inked[i - 1]}
            (( c < cols - 1 )) && rgt=${cell_inked[i + 1]}
            (( r == 0 )) && up=0; (( r == rows - 1 )) && down=0
            (( c == 0 )) && lft=0; (( c == cols - 1 )) && rgt=0
            sides=$(( (1 - up) + (1 - down) + (1 - lft) + (1 - rgt) ))
            if (( sides == 0 )); then cell_paint[i]=${cell_swapped[i]}; continue; fi
            cell_edge[i]=1
            if (( thin && sides == 1 )) && [[ "${cell_glyph[i]}" == "█" ]]; then
                if   (( ! up   )); then cell_glyph[i]=${_FT_BIGARROW_LOWER[(sub - 1) * 8 / sub]}; cell_paint[i]=5
                elif (( ! down )); then cell_glyph[i]=${_FT_BIGARROW_LOWER[8 / sub]};             cell_paint[i]=4
                elif (( ! lft  )); then cell_glyph[i]=${_FT_BIGARROW_LEFT[8 / sub]};              cell_paint[i]=4
                else                    cell_glyph[i]=${_FT_BIGARROW_LEFT[(sub - 1) * 8 / sub]};  cell_paint[i]=5
                fi
                continue
            fi
            cell_paint[i]=$(( 2 + cell_swapped[i] ))
        done
    done
    # ── Pass 3: emit runs, broken wherever the PAINT MODE changes ───────────
    local art="" rowspan="" seg_c seg_w seg_g seg_paint rlo rhi
    for (( r=0; r<rows; r++ )); do
        seg_c=-1; seg_w=0; seg_g=""; seg_paint=0; rlo=-1; rhi=-1
        for (( c=0; c<cols; c++ )); do
            i=$(( r * cols + c ))
            if (( ! cell_inked[i] )); then
                if (( seg_w > 0 )); then art+="$r $seg_c $seg_paint $seg_w $seg_g "; seg_w=0; seg_g=""; fi
                continue
            fi
            (( rlo < 0 )) && rlo=$c; rhi=$c
            if (( seg_w > 0 && seg_paint == cell_paint[i] )); then
                seg_g+=${cell_glyph[i]}; (( seg_w++ ))
            else
                (( seg_w > 0 )) && art+="$r $seg_c $seg_paint $seg_w $seg_g "
                seg_c=$c; seg_w=1; seg_g=${cell_glyph[i]}; seg_paint=${cell_paint[i]}
            fi
        done
        (( seg_w > 0 )) && art+="$r $seg_c $seg_paint $seg_w $seg_g "
        (( rlo >= 0 )) && rowspan+="$r $rlo $rhi "
    done
    FT_BIGARROW_ART[$key]=$art
    FT_BIGARROW_ROWSPAN[$key]=$rowspan
    FT_BIGARROW_SPAN[$key]="$cols $rows"
    return 0
}
# The sprite's footprint, built if it has not been built yet. → FT_RET = "cols rows".
_ft_bigarrow_span() {           # size dir sub → FT_RET = "cols rows"; 1 if there is no such sprite
    local key="$1|$2|$3|${FT_USE_UTF8:-1}"
    if [[ -z "${FT_BIGARROW_SPAN[$key]:-}" ]]; then
        _ft_bigarrow_build "$key" "$1" "$2" "$3" || { FT_RET=""; return 1; }
    fi
    FT_RET=${FT_BIGARROW_SPAN[$key]}
    return 0
}

# ── Geometry: which way, how big, and where on the screen ────────────────────
# _ft_bigarrow_geometry NAME PHASE → 0 and BA_* set, or 1 if there is no arrow worth drawing.
# Requires BREC_* (the target rect) — every caller runs _ft_beacon_rect first, exactly as the
# other variants do.
FT_BIGARROW_DIRECTION=""; FT_BIGARROW_LENGTH=0; FT_BIGARROW_ROWS=0; FT_BIGARROW_COLUMNS=0; FT_BIGARROW_TOP=0; FT_BIGARROW_LEFT=0; FT_BIGARROW_SHAPE_KEY=""; FT_BIGARROW_ALPHA=100
FT_BIGARROW_SIZE=""
# WHERE IT LANDS, as distinct from where it is THIS frame. Everything that has to reason about
# an arrow — another beacon deciding where to put itself, most of all — must reason about the
# landed rect, because the flying one is a fact with a half-life of 28ms. Publishing the flying
# rect was the reported picture: the step callout dutifully avoided the arrow's LAUNCH position,
# thirty columns further out, and the arrow then flew in and landed on top of it.
FT_BIGARROW_HOME_TOP=0; FT_BIGARROW_HOME_LEFT=0
_ft_bigarrow_geometry() {       # name phase → BA_*
    local name=$1 ph=$2
    FT_BIGARROW_ALPHA=100
    local bT=0 bL=0 bB=$(( FT_ROWS - 1 )) bR=$(( FT_COLS - 1 ))
    local bb; _ft_bigarrow_prop "$name" boundBox ""; bb=$FT_RET
    if [[ -n "$bb" && -n "${FT_ABSOLUTE_X[$bb]:-}" ]]; then
        bT=${FT_ABSOLUTE_Y[$bb]}; bL=${FT_ABSOLUTE_X[$bb]}
        bB=$(( bT + ${FT_MEASURED_HEIGHT[$bb]:-1} - 1 )); bR=$(( bL + ${FT_MEASURED_WIDTH[$bb]:-1} - 1 ))
    fi
    local gap sub sm place want
    _ft_bigarrow_num  "$name" arrowGap 1;        gap=$FT_RET
    _ft_bigarrow_prop "$name" smoothing eighths; sm=$FT_RET
    # The quality ladder, and the reason it exists is measured: eighth blocks are in 1 of 7 in
    # BOTH Consolas and Lucida Console — the two fonts the classic Windows console offers, and
    # the very ones ft-conhostfix.bash exists to steer people onto. `halves` is that rung and
    # it is not a token gesture: ▀▄ are in every font measured, the fg/bg inversion still
    # applies so the arrow stays symmetric, and the authored art is simply rounded to it.
    # `solid` is whole cells only — the honest picture of what the brief called the naive
    # approach, kept so it can be looked at rather than argued about.
    case "$sm" in halves) sub=2 ;; solid) sub=1 ;; *) sub=8 ;; esac
    (( FT_USE_UTF8 )) || sub=1
    _ft_bigarrow_prop "$name" place auto; place=$FT_RET
    _ft_bigarrow_size "$name";            want=$FT_RET

    # ── The placement cache ──────────────────────────────────────────────────
    # THE SEARCH BELOW IS NOT AFFORDABLE PER PAINT. It builds the obstacle list, decomposes it
    # into weighted tiers and scores every side against it — the callout's own machinery, and
    # the callout runs it once per STEP for exactly this reason. A bigarrow is repainted by
    # every keystroke (a keystroke recomposites every overlay), so without this the
    # burial-aware placement would land squarely on the typing path. The question it answers is
    # "where does this arrow go", and that question changes only when the target moves, the
    # bounds move, the screen resizes, the size or smoothing changes — or the layout epoch
    # turns over.
    local pkey="$place|$want|$gap|$sub|${FT_BEACON_RECT_TOP}_${FT_BEACON_RECT_LEFT}_${FT_BEACON_RECT_BOTTOM}_${FT_BEACON_RECT_RIGHT}"
    pkey+="|${bT}_${bL}_${bB}_${bR}|${FT_COLS}x${FT_ROWS}|${FT_LAYOUT_EPOCH:-0}"
    if [[ "${FT_BIGARROW_PKEY[$name]:-}" == "$pkey" ]]; then
        # A MISS IS CACHED TOO — an empty answer, so a suppressed arrow does not re-run the
        # whole search on every repaint just to fail again.
        read -r FT_BIGARROW_DIRECTION FT_BIGARROW_LENGTH FT_BIGARROW_ROWS FT_BIGARROW_COLUMNS FT_BIGARROW_TOP FT_BIGARROW_LEFT FT_BIGARROW_SIZE FT_BIGARROW_SHAPE_KEY <<< "${FT_BIGARROW_PC[$name]}"
        (( ${#FT_BIGARROW_DIRECTION} == 0 )) && return 1
    else
        # BA_* ARE GLOBALS, SO A FAILED SEARCH MUST CLEAR THEM. Without this line a placement
        # that found nothing left the PREVIOUS arrow's direction and size standing in
        # FT_BIGARROW_DIRECTION, the "did we get an answer" test below read that stale value as
        # an answer, and the geometry returned success for an arrow it had just decided could
        # not be drawn. Same shape as this codebase's FT_RET-leak bug, one variable over.
        FT_BIGARROW_DIRECTION=""; FT_BIGARROW_SIZE=""
        if _ft_bigarrow_place "$name"; then
            FT_BIGARROW_PC[$name]="$FT_BIGARROW_DIRECTION $FT_BIGARROW_LENGTH $FT_BIGARROW_ROWS $FT_BIGARROW_COLUMNS $FT_BIGARROW_TOP $FT_BIGARROW_LEFT $FT_BIGARROW_SIZE $FT_BIGARROW_SHAPE_KEY"
        else
            FT_BIGARROW_PC[$name]=""
        fi
        FT_BIGARROW_PKEY[$name]=$pkey
        (( ${#FT_BIGARROW_DIRECTION} == 0 )) && return 1
    fi

    # ── The bounce, and the only place the phase is read ─────────────────────
    # The curves were solved at arm time (ft_ease_table); a frame does one array index and one
    # multiply. Offset is measured ALONG THE AXIS, AWAY FROM THE TARGET — so a left-pointing
    # arrow starts to the right of where it lands and slides left, a NEGATIVE offset is the
    # overshoot carrying it past the landing spot and into the target (the whole cartoon), and
    # the exit runs the same number back out again.
    local off=0 stage=${FT_BIGARROW_STAGE[$name]:-fly}
    if (( ph >= 0 )) && [[ "$stage" != hold ]]; then
        local -a curve
        if [[ "$stage" == exit ]]; then curve=(${FT_BIGARROW_XEASE[$name]:-})
        else                            curve=(${FT_BIGARROW_EASE[$name]:-}); fi
        local nf=${#curve[@]}
        if (( nf > 0 )); then
            local idx=$ph; (( idx >= nf )) && idx=$(( nf - 1 ))
            local travel; _ft_bigarrow_num "$name" bounceTravel auto auto; travel=$FT_RET
            [[ "$travel" == auto ]] && travel=$FT_BIGARROW_LENGTH
            if [[ "$stage" == exit ]]; then
                # THE EXIT IS THE FLY-IN READ THE OTHER WAY. 0 → travel instead of travel → 0,
                # which is why an -back curve on the exit leans the arrow a cell TOWARD the
                # target before it goes: the anticipation beat a cartoon take needs.
                local xexit; _ft_bigarrow_prop "$name" exit "$FT_BIGARROW_EXIT"; xexit=$FT_RET
                if [[ "$xexit" == retract ]]; then
                    # …BUT IT HAS TO GET ALL THE WAY OUT. Retracting by the fly-in's travel put
                    # the arrow back at its launch position — which is ON the screen — and then
                    # destroyed it there, so the graceful exit ended in exactly the pop it
                    # exists to avoid. The exit travels far enough to clear the bound it flew
                    # in across, whichever is further.
                    local clear=$travel
                    case "$FT_BIGARROW_DIRECTION" in
                        right) (( clear = FT_BIGARROW_LEFT - bL + FT_BIGARROW_COLUMNS )) ;;
                        left)  (( clear = bR - FT_BIGARROW_LEFT + 1 )) ;;
                        down)  (( clear = FT_BIGARROW_TOP - bT + FT_BIGARROW_ROWS )) ;;
                        up)    (( clear = bB - FT_BIGARROW_TOP + 1 )) ;;
                    esac
                    (( clear > travel )) && travel=$clear
                    off=$(( travel * curve[idx] / 1000 ))
                elif [[ "$xexit" == fade ]]; then
                    off=0
                    FT_BIGARROW_ALPHA=$(( 100 - 100 * curve[idx] / 1000 ))
                    (( FT_BIGARROW_ALPHA < 0 )) && FT_BIGARROW_ALPHA=0; (( FT_BIGARROW_ALPHA > 100 )) && FT_BIGARROW_ALPHA=100
                fi
            else
                off=$(( travel * (1000 - curve[idx]) / 1000 ))
            fi
        fi
    fi
    FT_BIGARROW_HOME_TOP=$FT_BIGARROW_TOP; FT_BIGARROW_HOME_LEFT=$FT_BIGARROW_LEFT
    case "$FT_BIGARROW_DIRECTION" in
        right) (( FT_BIGARROW_LEFT -= off )) ;;
        left)  (( FT_BIGARROW_LEFT += off )) ;;
        down)  (( FT_BIGARROW_TOP  -= off )) ;;
        up)    (( FT_BIGARROW_TOP  += off )) ;;
    esac
    return 0
}

# ── Choosing a side and a rung, against what each would BURY ─────────────────
# CALLED ONLY FROM _ft_bigarrow_geometry: bash's dynamic scoping is the contract, exactly as it
# is for the callout's `_shape`/`_cand` helpers, so this reads bT/bL/bB/bR, gap, sub, want and
# place out of its caller's locals rather than taking nine arguments.
#
# WHAT IT NO LONGER DOES IS THE INTERESTING PART. It used to choose a LENGTH — four rungs of
# whatever the room happened to be — and that freedom is what produced a different arrow in
# every window. It now chooses only a SIDE and a RUNG OF THE AUTHORED LADDER, and a rung either
# fits where it is going or it does not. Nothing deforms.
#
# WHY IT SCORES BURIAL AT ALL. The first cut picked the roomiest side and the biggest arrow that
# fitted, and on a page built around the arrow that is fine. On a TEACHING page it is not: the
# settled arrow crossed the panel border and covered part of its content, which is the difference
# between a pointer and vandalism. The callout already has the machinery for exactly this
# question — _ft_route_obstacles builds the obstacle list, ft_tier_rects decomposes it into
# weighted regions (a border ring is cheaper than a sentence), _ft_beacon_overlap prices a rect
# against it — so this asks the same question with the same weights and does not invent a
# second cost model.
#
# THE SHAPE IS SCORED AS TWO RECTS, NOT ONE. An arrow's bounding box is roughly half air — the
# two corners behind the head — and pricing that air as if it were ink made the arrow shrink
# away from text it would never have touched. Head (full cross extent, over the head's length)
# plus shaft (thin, over the rest) is two overlap calls and is close enough that the shrink
# only happens when something is genuinely under the ink.
: "${_BIGARROW_BURY:=200}"      # what one buried NORMAL-importance cell costs, in hundredths of
                                # a visual unit of arrow. 200 = "a buried cell is worth two
                                # units of length", so a 30-unit arrow burying ten cells loses
                                # to a 20-unit arrow burying none, and an arrow that would sit
                                # on a paragraph drops a rung until it does not.
_ft_bigarrow_place() {          # name → BA_* (0), or 1 if nothing is worth drawing
    local name=$1
    local roomR=$(( FT_BEACON_RECT_LEFT - gap - bL )) roomL=$(( bR - FT_BEACON_RECT_RIGHT - gap ))
    local roomD=$(( FT_BEACON_RECT_TOP - gap - bT )) roomU=$(( bB - FT_BEACON_RECT_BOTTOM - gap ))
    local crossH=$(( bB - bT + 1 )) crossV=$(( bR - bL + 1 ))
    # The obstacle list, built once for this placement. Guarded by `declare -F` so a caller that
    # sourced only ft-core/ft-forms without the placement machinery still gets an arrow — it just
    # gets the roomiest one, which is what the first version always did.
    local scoring=0
    if declare -F ft_tier_rects >/dev/null && declare -F _ft_route_obstacles >/dev/null; then
        _ft_route_obstacles "$name"
        # …AND EVERY OTHER OVERLAY'S PUBLISHED INK: without it the arrow could not see the step
        # callout AT ALL and drew straight through its chip, which is what the reader reported.
        _ft_beacon_push_overlay_ink "$name"
        ft_tier_rects; scoring=1
    fi
    # THE RUNGS TO TRY. An explicit `size` gets exactly one — the author named a size, and
    # quietly drawing a different one is the very thing this replaced. Unset gets the whole
    # ladder, largest first.
    local -a rungs
    if [[ -n "$want" ]]; then rungs=("$want")
    else                      rungs=(x-large large medium small); fi
    local bestDir="" bestSize="" bestRows=0 bestCols=0 bestTop=0 bestLeft=0 bestKey="" bestVisual=0
    local bestScore=-999999999
    local d size key span cols rows top left cy cx bury sc visual room across
    local headMajor shaftMinor
    cy=$(( (FT_BEACON_RECT_TOP + FT_BEACON_RECT_BOTTOM) / 2 )); cx=$(( (FT_BEACON_RECT_LEFT + FT_BEACON_RECT_RIGHT) / 2 ))
    for d in right left down up; do
        case "$place" in
            left)  [[ "$d" == right ]] || continue ;;
            right) [[ "$d" == left  ]] || continue ;;
            above) [[ "$d" == down  ]] || continue ;;
            below) [[ "$d" == up    ]] || continue ;;
        esac
        case $d in
            right) room=$roomR; across=$crossH ;;
            left)  room=$roomL; across=$crossH ;;
            down)  room=$roomD; across=$crossV ;;
            up)    room=$roomU; across=$crossV ;;
        esac
        (( room < 1 )) && continue
        for size in "${rungs[@]}"; do
            _ft_bigarrow_span "$size" "$d" "$sub" || continue
            span=$FT_RET; cols=${span%% *}; rows=${span##* }
            key="$size|$d|$sub|${FT_USE_UTF8:-1}"
            if [[ "$d" == right || "$d" == left ]]; then
                (( cols > room || rows > across )) && continue
                visual=$cols
                headMajor=$(( cols / 2 )); shaftMinor=$(( FT_BIGARROW_SHAFT_VISUAL[$size] / FT_BIGARROW_ASPECT ))
            else
                (( rows > room || cols > across )) && continue
                visual=$(( rows * FT_BIGARROW_ASPECT ))
                headMajor=$(( rows / 2 )); shaftMinor=${FT_BIGARROW_SHAFT_VISUAL[$size]}
            fi
            (( shaftMinor < 1 )) && shaftMinor=1
            case "$d" in
                right) left=$(( FT_BEACON_RECT_LEFT - gap - cols ));  top=$(( cy - rows / 2 )) ;;
                left)  left=$(( FT_BEACON_RECT_RIGHT + gap + 1 ));    top=$(( cy - rows / 2 )) ;;
                down)  top=$(( FT_BEACON_RECT_TOP - gap - rows ));    left=$(( cx - cols / 2 )) ;;
                up)    top=$(( FT_BEACON_RECT_BOTTOM + gap + 1 ));    left=$(( cx - cols / 2 )) ;;
            esac
            if [[ "$d" == right || "$d" == left ]]; then
                (( top < bT )) && top=$bT
                (( top + rows - 1 > bB )) && top=$(( bB - rows + 1 ))
            else
                (( left < bL )) && left=$bL
                (( left + cols - 1 > bR )) && left=$(( bR - cols + 1 ))
            fi
            bury=0
            if (( scoring )); then
                # head: the portion nearest the TARGET, at full cross extent
                # shaft: the rest, only as thick as the shaft actually is
                if [[ "$d" == right ]]; then
                    _ft_beacon_overlap "$top" $(( left + cols - headMajor )) "$headMajor" "$rows"; bury=$FT_RET
                    _ft_beacon_overlap $(( top + (rows-shaftMinor)/2 )) "$left" $(( cols - headMajor )) "$shaftMinor"; (( bury += FT_RET ))
                elif [[ "$d" == left ]]; then
                    _ft_beacon_overlap "$top" "$left" "$headMajor" "$rows"; bury=$FT_RET
                    _ft_beacon_overlap $(( top + (rows-shaftMinor)/2 )) $(( left + headMajor )) $(( cols - headMajor )) "$shaftMinor"; (( bury += FT_RET ))
                elif [[ "$d" == down ]]; then
                    _ft_beacon_overlap $(( top + rows - headMajor )) "$left" "$cols" "$headMajor"; bury=$FT_RET
                    _ft_beacon_overlap "$top" $(( left + (cols-shaftMinor)/2 )) "$shaftMinor" $(( rows - headMajor )); (( bury += FT_RET ))
                else
                    _ft_beacon_overlap "$top" "$left" "$cols" "$headMajor"; bury=$FT_RET
                    _ft_beacon_overlap $(( top + headMajor )) $(( left + (cols-shaftMinor)/2 )) "$shaftMinor" $(( rows - headMajor )); (( bury += FT_RET ))
                fi
            fi
            # A BIGGER ARROW IS BETTER AND A BURIED CELL IS WORSE, in the same units the callout
            # prices coverage in. Comparing a row against a column without the visual unit would
            # hand every placement to the horizontal axis.
            sc=$(( visual * 100 - bury * _BIGARROW_BURY ))
            # FT_BIGARROW_LOG=<file> dumps every candidate with its two terms. Four plausible
            # weight changes once moved nothing in this project because nobody had printed the
            # candidates first; this is that printout, and it costs one `[[ -n ]]` when unset.
            [[ -n "${FT_BIGARROW_LOG:-}" ]] && \
                printf 'CAND %-5s %-7s %2sx%-3s at %2s,%-3s  visual=%-4s bury=%-5s score=%s\n' \
                       "$d" "$size" "$rows" "$cols" "$top" "$left" "$visual" "$bury" "$sc" >> "$FT_BIGARROW_LOG"
            # Strictly greater keeps the first, largest candidate on a tie — deterministic, so a
            # placement never flickers between two equally good answers.
            if (( sc > bestScore )); then
                bestScore=$sc; bestDir=$d; bestSize=$size; bestVisual=$visual
                bestRows=$rows; bestCols=$cols; bestTop=$top; bestLeft=$left; bestKey=$key
            fi
        done
    done
    [[ -n "$bestDir" ]] || return 1
    # AN ARROW THAT COSTS MORE THAN IT IS WORTH IS NOT DRAWN, and this floor only became
    # possible — and necessary — with the authored ladder. The old placer could always shrink
    # its way out of trouble: burial pushed the length down until the arrow stopped covering
    # things, which is precisely the deforming this replaced. A rung cannot shrink, so without a
    # floor the least-bad candidate wins however bad it is, and on a dense stage that is an
    # arrow lying across a textfield — "the difference between a pointer and vandalism", which
    # is the sentence this file already uses about exactly this.
    #
    # The threshold is the cost model's own: score < 0 is `bury * _BIGARROW_BURY` exceeding the
    # arrow's visual length in hundredths, i.e. burying more cells than half the arrow's length.
    # Nothing new is invented to express it. Suppression is a supported outcome (a target with
    # no room on any side has always produced it), so every caller already handles it.
    (( bestScore < 0 )) && return 1
    FT_BIGARROW_DIRECTION=$bestDir; FT_BIGARROW_LENGTH=$bestVisual
    FT_BIGARROW_ROWS=$bestRows; FT_BIGARROW_COLUMNS=$bestCols
    FT_BIGARROW_TOP=$bestTop; FT_BIGARROW_LEFT=$bestLeft
    FT_BIGARROW_SIZE=$bestSize; FT_BIGARROW_SHAPE_KEY=$bestKey
    return 0
}

# ── Erase: damage exactly the cells the move vacated ─────────────────────────
# A flight is twenty repaints a second of a shape that can be a couple of hundred cells, so
# what it costs is decided here and not in the painter. The move is a TRANSLATION of a fixed
# shape, so per row the vacated cells are the part of the old interval the new one does not
# cover — one strip of |delta| cells for an axial step, and never a bounding box. (The callout
# drag learned this the expensive way: damaging box ∪ leader as one rect refilled ~160 blank
# cells a move and was 1862ms of a 2100ms drag.)
_ft_bigarrow_damage_move() {    # name newTop newLeft newKey
    local name=$1 nT=$2 nL=$3 nK=$4
    local at=${FT_BIGARROW_AT[$name]:-}
    (( ${#at} == 0 )) && return 0
    local oT oL oK; read -r oT oL oK <<< "$at"
    local spans=${FT_BIGARROW_ROWSPAN[$oK]:-}
    (( ${#spans} == 0 )) && return 0
    local same=1; [[ "$oK" == "$nK" ]] || same=0
    local r rl rh orow olo ohi nrow nlo nhi
    set -- $spans
    while (( $# >= 3 )); do
        r=$1; rl=$2; rh=$3; shift 3
        orow=$(( oT + r )); olo=$(( oL + rl )); ohi=$(( oL + rh ))
        if (( ! same )); then ft_damage "$orow" "$olo" "$orow" "$ohi"; continue; fi
        nrow=$(( nT + r ))
        if (( nrow != orow )); then ft_damage "$orow" "$olo" "$orow" "$ohi"; continue; fi
        nlo=$(( nL + rl )); nhi=$(( nL + rh ))
        if (( nlo > ohi || nhi < olo )); then ft_damage "$orow" "$olo" "$orow" "$ohi"; continue; fi
        (( nlo > olo )) && ft_damage "$orow" "$olo" "$orow" $(( nlo - 1 ))
        (( nhi < ohi )) && ft_damage "$orow" $(( nhi + 1 )) "$orow" "$ohi"
    done
    return 0
}
# _ft_ink_beacon NAME — WHERE THIS BEACON'S INK ACTUALLY IS, for the engine's general
# give-back rule (ft_damage_subtree in ft-forms.bash, used by ft_remove and `display: none`).
# The engine's default answer is FT_PAINT_RECT, and for a ring, a chip or a callout that is
# exactly right — the extent is published there and it is what was inked.
#
# A BIGARROW IS THE EXCEPTION THIS HOOK EXISTS FOR. It publishes its LANDED rect, because
# other placements have to avoid where it will come to rest, and mid-flight that is not where
# it is painting. Its own erase record — the shape's per-row spans at the position it really
# drew — is exact. demo/callout-demo.bash used to call _ft_bigarrow_damage_all itself, a
# private function, precisely because no application could know this.
_ft_ink_beacon() {              # name
    ft_resolved_prop "$1" variant frame
    if [[ "$FT_RET" == bigarrow ]]; then _ft_bigarrow_damage_all "$1"; return 0; fi
    local rect=${FT_PAINT_RECT[$1]:-${FT_BEACON_EXTENT[$1]:-}}
    [[ -n "$rect" ]] && ft_damage $rect
    # A leader's thin segments are the beacon's pixels too and can reach outside the box rect.
    local seg rest=${FT_OVERLAY_EXTRA[$1]:-}
    while [[ -n "$rest" ]]; do
        seg=${rest%%;*}; [[ "$seg" == "$rest" ]] && rest="" || rest=${rest#*;}
        [[ -n "$seg" ]] && ft_damage $seg
    done
    return 0
}
# Everything it last painted — for a beacon that is going away, or one that has stopped being
# drawable at all.
_ft_bigarrow_damage_all() {     # name
    # THE NAME IS COPIED BEFORE `set --`, and that is not style. `set -- $spans` REPLACES the
    # positional parameters, so `$1` after it is a leftover span number, not the control — the
    # first cut ended with `unset "FT_BIGARROW_AT[]"`, which is a bad-subscript error written
    # to stderr (i.e. onto the alt screen) and left the erase record standing, so the next
    # paint damaged cells the arrow no longer occupied. Caught by the suppression assertion in
    # tests/test-bigarrow.bash, which is the only reason it is not still here.
    local name=$1
    local at=${FT_BIGARROW_AT[$name]:-}
    (( ${#at} == 0 )) && return 0
    local oT oL oK; read -r oT oL oK <<< "$at"
    local spans=${FT_BIGARROW_ROWSPAN[$oK]:-}
    unset "FT_BIGARROW_AT[$name]"
    (( ${#spans} == 0 )) && return 0
    local r rl rh
    set -- $spans
    while (( $# >= 3 )); do
        r=$1; rl=$2; rh=$3; shift 3
        ft_damage $(( oT + r )) $(( oL + rl )) $(( oT + r )) $(( oL + rh ))
    done
    return 0
}

# ── Paint ────────────────────────────────────────────────────────────────────
# The arrow's three alpha users — exit=fade, the default outline colour and a fading outline —
# call _ft_alpha_blend up in the Colour section, which is the shimmer's blend too. It used to be
# `_ft_bigarrow_mix`, a bigarrow-private copy of the same three lines.
# THE ARROW'S INK IS `color`, RESOLVED THE WAY EVERY OTHER CONTROL RESOLVES IT — _ft_color_override,
# which is inline → app stylesheets → inheritance, with the named colours, the role words and a
# live `animation:` @keyframes all coming along for free. It used to be a beacon-private role
# lookup (`_ft_beacon_basecolor NAME arrow`, i.e. a `beacon::arrow` pseudo-element) and NOTHING
# else: `color=196`, `#ar { color: 82 }`, `.loud { color: 201 }` and `color: crimson` were all
# silently ignored, which is four of the six things a user would try first.
#
# THE `::arrow` PSEUDO-ELEMENT IS GONE, not layered under this. It existed for exactly one
# reason — to give a per-instance colour override to a control whose `color` did not work — and
# a structure pseudo-element for "the whole element" is a second name for `color` the moment
# `color` works. (`::border`, `::number` and the rest stay: those name a PART of a beacon that
# is drawn in its own colour beside other parts. A bigarrow's arrow is not a part of it.)
#
# The theme's --beacon-N / --locator-N ramp is what `color` resolves to when nothing declares
# one, and effect=pulse cycles that ramp while the arrow is still FLYING. So the ramp is the
# DEFAULT ink, not an override of one: declare a colour and you get that colour on every frame,
# rather than a cycle for 560ms and then your colour. An unstyled arrow is byte-identical to
# before — landed, it is still ramp colour 1.
_ft_bigarrow_color() {          # name phase groundSgr → FT_RET (a foreground SGR)
    _ft_color_override "$1" color 38
    if (( ${#FT_RET} == 0 )); then
        local eff; ft_resolved_prop "$1" effect pulse; eff=$FT_RET
        if (( $2 >= 0 )) && [[ "$eff" == pulse ]]; then _ft_beacon_pulsecolor "$1" "$2"
        else                                            _ft_beacon_pulsecolor "$1" 0; fi
    fi
    (( FT_BIGARROW_ALPHA >= 100 )) && return 0
    # exit=fade: blend the ink toward the ground. It composes with the fg/bg swap for free — a
    # reversed cell shows this colour as its BACKGROUND, so fading the foreground fades both
    # kinds of cell by the same amount without a second lookup.
    local solid=$FT_RET
    _ft_alpha_blend "$3" "$solid" "$FT_BIGARROW_ALPHA" || FT_RET=$solid
    return 0
}
# ── The silhouette outline ───────────────────────────────────────────────────
# CSS's initial `border-color` is `currentColor`, and in a terminal an outline in exactly the
# fill's colour is not an outline at all — so the initial value here is currentColor SHADED:
# the arrow's own ink, pulled this far back toward the ground behind it. That keeps CSS's
# actual promise (the border follows the colour) in the only form the medium can show: set
# `color: crimson` and you get a crimson arrow with a dark-crimson rim, not a crimson arrow
# wearing last week's gold.
FT_BIGARROW_OUTLINE_MIX=55      # % of the way from the ground to the ink for the DEFAULT rim.
                                # A floor only: `border-color` outranks it, like every other
                                # constant in this file.
# _ft_bigarrow_outline_color NAME INKSGR GROUNDSGR → FT_RET = the rim's SGR (0), or 1 = no outline.
# Deviations from CSS, all of them forced by the medium and all of them written down in
# docs/styling-model.md §8:
#   · border-style is not consulted. The outline's glyphs ARE the shape's own edge cells;
#     there is no line to make dashed or dotted.
#   · thin/medium/thick all draw ONE cell, which is the framework's existing border deviation
#     (a TUI border is always exactly one cell) applied unchanged.
#   · `border-width: 0` and `border-style: none` are CSS's own removal spellings and both work
#     — but only from INLINE (a constructor argument or ft-modify), because ft_control makes
#     both of them class defaults and a class default is applied as an inline property, which
#     is cascade level 1. `border-color: transparent` is the spelling a STYLESHEET can reach,
#     because borderColor is the one border property no class defaults.
_ft_bigarrow_outline_color() {  # name inkSgr groundSgr → FT_RET (rim SGR); 1 = no outline
    _ft_bigarrow_styled "$1" borderWidth thin
    case "$FT_RET" in 0|none|"") FT_RET=""; return 1 ;; esac
    _ft_bigarrow_styled "$1" borderStyle solid
    [[ "$FT_RET" == none ]] && { FT_RET=""; return 1; }
    local declared; _ft_bigarrow_styled "$1" borderColor ""; declared=$FT_RET
    case "$declared" in
        transparent|none) FT_RET=""; return 1 ;;
        "") _ft_alpha_blend "$3" "$2" "$FT_BIGARROW_OUTLINE_MIX" || { FT_RET=""; return 1; }
            return 0 ;;                          # …and it is already faded: the ink was
    esac                                         #    faded before it got here, and a mix of a
    _ft_color_override "$1" borderColor 38       #    faded end is the same as fading the mix.
    (( ${#FT_RET} == 0 )) && { FT_RET=""; return 1; }
    # A DECLARED rim has to fade with the arrow too, or exit=fade dissolves the fill and leaves
    # a bright wireframe hanging over the page for the last third of the exit.
    (( FT_BIGARROW_ALPHA >= 100 )) && return 0
    local solid=$FT_RET
    _ft_alpha_blend "$3" "$solid" "$FT_BIGARROW_ALPHA" || FT_RET=$solid
    return 0
}
_ft_beacon_paint_bigarrow() {   # name phase   (phase -1 = landed)
    local name=$1 ph=$2
    # AN ARROW THAT STOPS BEING DRAWABLE MUST TAKE ITS INK WITH IT. Suppression used to just
    # forget where it had painted, so a target that moved somewhere with no room on any side
    # left a whole arrow standing on the screen forever. Damaging here does not repair it in
    # THIS frame — the fill has already run by the time a paint happens — but the damage
    # survives to the next redraw, which turns permanent residue into one stale frame.
    _ft_bigarrow_geometry "$name" "$ph" || { _ft_bigarrow_damage_all "$name"; return 0; }
    local art=${FT_BIGARROW_ART[$FT_BIGARROW_SHAPE_KEY]:-}
    (( ${#art} == 0 )) && { _ft_bigarrow_damage_all "$name"; return 0; }
    # The cell UNDER an arrow cell is overwritten, so its background has to be stated or the
    # old content's background shows through half a glyph. One resolution per paint, not one
    # per cell — and it is also the colour the REVERSED cells swap to, which is why the
    # inversion needs no second colour lookup and no per-cell ground probe. Resolved BEFORE the
    # ink, because exit=fade blends the ink toward it.
    _ft_effective_bg "$name"; local bg=$FT_RET
    _ft_bigarrow_color "$name" "$ph" "$bg"; local fg=$FT_RET
    # …and the rim. With no outline the rim IS the ink, so the four prefixes collapse to two and
    # the emitted bytes are identical to an arrow that never heard of a border — which is what
    # makes `border-width: 0` a true removal rather than a border painted in the fill's colour.
    local rim=$fg
    _ft_bigarrow_outline_color "$name" "$fg" "$bg" && rim=$FT_RET
    # The six paint modes of the art, as escapes. Modes 4/5 need the ARROW's colour as a
    # BACKGROUND, which is one conversion per paint; where the ink is a colour that cannot be
    # read back (a bare attribute, mono mode) there is no hairline to draw, and those runs fall
    # back to whole cells of rim — the same picture the outline had before the hairline existed.
    local inkbg=""
    if ft_sgr_rgb "$fg" 38; then ft_rgb_sgr "$FT_RGB_RED" "$FT_RGB_GREEN" "$FT_RGB_BLUE" 48; inkbg=$FT_RET; fi
    local -a mode_sgr=("$bg$fg" "$bg$fg$FT_ANSI_REVERSE" "$bg$rim" "$bg$rim$FT_ANSI_REVERSE")
    if [[ -n "$inkbg" ]]; then mode_sgr[4]="$inkbg$rim"; mode_sgr[5]="$inkbg$rim$FT_ANSI_REVERSE"
    else                       mode_sgr[4]="$bg$rim";    mode_sgr[5]="$bg$rim$FT_ANSI_REVERSE"; fi
    local r c paint w g row col
    local exT=$FT_ROWS exL=$FT_COLS exB=-1 exR=-1
    set -- $art
    while (( $# >= 5 )); do
        r=$1; c=$2; paint=$3; w=$4; g=$5; shift 5
        row=$(( FT_BIGARROW_TOP + r )); col=$(( FT_BIGARROW_LEFT + c ))
        (( row < 0 || row >= FT_ROWS )) && continue
        if (( paint >= 4 )) && [[ -z "$inkbg" ]]; then
            # No hairline available: give the run back its solid cells, in the rim colour.
            while (( ${#_FT_BIGARROW_SOLID_RUN} < w )); do _FT_BIGARROW_SOLID_RUN+="████████"; done
            g=${_FT_BIGARROW_SOLID_RUN:0:w}
        fi
        if (( col < 0 )); then                  # flying in from off the left edge
            local drop=$(( -col ))
            (( drop >= w )) && continue
            g=${g:drop}; (( w -= drop )); col=0     # character indexing: ${s:n} is not bytes
        fi
        (( col >= FT_COLS )) && continue
        ft_print_at_width "$row" "$col" "${mode_sgr[paint]}$g$FT_COLOR_RESET" "$w"
        (( row < exT )) && exT=$row; (( row > exB )) && exB=$row
        (( col < exL )) && exL=$col; (( col + w - 1 > exR )) && exR=$(( col + w - 1 ))
    done
    if (( exB < 0 )); then _ft_bigarrow_damage_all "$name"; return 0; fi   # entirely off-screen
    (( exR >= FT_COLS )) && exR=$(( FT_COLS - 1 ))
    FT_BIGARROW_AT[$name]="$FT_BIGARROW_TOP $FT_BIGARROW_LEFT $FT_BIGARROW_SHAPE_KEY"
    # THE PUBLISHED EXTENT IS WHERE IT LANDS, NOT WHERE IT IS. Everything that reads
    # FT_BEACON_EXTENT is deciding where to put something else, and the answer has to hold for
    # longer than one 28ms frame — see the note on FT_BIGARROW_HOME_*. The precise, per-frame footprint
    # this variant erases with is FT_BIGARROW_AT + the shape's row spans, which is exact and is
    # not this. ft_publish_paint_rect and FT_OVERLAY DO take the painted rect: they are about what is on
    # the screen right now (damage on removal, and whether an animation elsewhere touched us).
    FT_BEACON_EXTENT[$name]="$FT_BIGARROW_HOME_TOP $FT_BIGARROW_HOME_LEFT $(( FT_BIGARROW_HOME_TOP + FT_BIGARROW_ROWS - 1 )) $(( FT_BIGARROW_HOME_LEFT + FT_BIGARROW_COLUMNS - 1 ))"
    ft_publish_paint_rect "$name" "$exT" "$exL" "$exB" "$exR"
    FT_OVERLAY[$name]="$exT $exL $exB $exR"
    return 0
}

# ── Lifecycle ────────────────────────────────────────────────────────────────
# Arm the FLY-IN. THE CURVES ARE SOLVED HERE, ONCE. ft_ease bisects a cubic bezier — ~340µs a
# call, measured — which is fine twenty times at arm time and is not fine inside a frame, so the
# frames get a table of integers and never see a bezier. Both curves are solved now rather than
# at the stage transition, so the transition itself is free.
_ft_bigarrow_arm() {            # name
    local n=$1 spec ms frames life fms xspec xms
    [[ -z "${FT_TYPE[$n]:-}" ]] && return 1
    frames=$FT_BIGARROW_FRAMES
    _ft_bigarrow_styled_nth "$n" animationTimingFunction 1 "$FT_BIGARROW_EASING"; spec=$FT_RET
    _ft_bigarrow_styled_nth "$n" animationDuration 1 "$FT_BIGARROW_MS";           ms=$FT_RET
    _ft_bigarrow_ms "$ms" "$FT_BIGARROW_MS"; ms=$FT_RET
    ft_ease_table "$spec" "$frames"; FT_BIGARROW_EASE[$n]=$FT_RET
    # …and the exit's, whichever exit it turns out to be. Solving a curve for an exit that never
    # runs costs 5ms once; branching here would put the cost on the transition, which is a frame.
    _ft_bigarrow_styled_nth "$n" animationTimingFunction 2 "$FT_BIGARROW_EXIT_EASING"; xspec=$FT_RET
    ft_ease_table "$xspec" "$FT_BIGARROW_EXIT_FRAMES"; FT_BIGARROW_XEASE[$n]=$FT_RET
    fms=$(( ms / frames )); (( fms < 12 )) && fms=12
    FT_BIGARROW_STAGE[$n]=fly
    # ONE FRAME LONGER THAN THE CURVE, and the extra frame is not padding — it is where the
    # STAGE TRANSITION happens. _ft_bigarrow_frame spends its last frame switching stages and
    # returns without painting, so with the length equal to the curve the final PAINTED frame
    # was the second-to-last point on it, not the endpoint. On the fly that is invisible (the
    # curve has flattened by then); on the retract it was not — the last frame anyone saw had
    # the arrow at column -4 with twenty-six columns still on screen, and then it vanished.
    # Exactly the pop the exit exists to avoid, one frame from the end.
    ft_anim_start "$n" $(( frames + 1 )) "$fms" 1 0
    ft_anim_bind  "$n" _ft_bigarrow_frame bigarrow
    return 0
}
# CSS spells a duration `0.42s` or `420ms`; a call site is as likely to write a bare number.
# ft-css already knows how to read the first two and is not always loaded.
_ft_bigarrow_ms() {             # value fallback → FT_RET (ms)
    local v=$1
    if [[ "$v" == *s && "$v" != *ms ]] && declare -F _ft_css_duration_ms >/dev/null 2>&1; then
        _ft_css_duration_ms "$v"; v=$FT_RET
    else v=${v%ms}; fi
    case "$v" in *[!0-9]*|"") v=$2 ;; esac
    (( v < 1 )) && v=$2
    FT_RET=$v
}
# ── The stage machine ────────────────────────────────────────────────────────
# fly → hold → exit → gone. Each stage is its OWN animation, which is what makes waiting free:
# the hold is two frames at holdDuration ms, so the whole wait costs one wakeup instead of the
# ~85 no-op repaints a single 20fps animation spanning all three stages would have cost.
_ft_bigarrow_enter_hold() {     # name
    local n=$1 hold delay flyms
    # CSS MEASURES A DELAY FROM WHEN THE ELEMENT STARTS ANIMATING, not from when the previous
    # animation ended, so the wait this stage has to sit out is (delay - the flight). Honouring
    # that is what makes `animation-delay` the real property rather than `holdDuration` wearing
    # its name: an author who writes 2960ms gets the leave at 2960ms, whatever the flight costs.
    # The class default is still expressed as a HOLD (FT_BIGARROW_HOLD_MS) because that is the
    # thing that was tuned by looking at it — the default delay is the flight plus the hold, so
    # the shipped timing is unchanged to the millisecond.
    _ft_bigarrow_styled_nth "$n" animationDuration 1 "$FT_BIGARROW_MS"; flyms=$FT_RET
    _ft_bigarrow_ms "$flyms" "$FT_BIGARROW_MS"; flyms=$FT_RET
    _ft_bigarrow_styled_nth "$n" animationDelay 2 "$(( flyms + FT_BIGARROW_HOLD_MS ))"; delay=$FT_RET
    _ft_bigarrow_ms "$delay" "$(( flyms + FT_BIGARROW_HOLD_MS ))"; delay=$FT_RET
    hold=$(( delay - flyms )); (( hold < 1 )) && hold=1
    FT_BIGARROW_STAGE[$n]=hold
    # length 2, not 1: ft_anim_step retires an animation the moment its phase REACHES the
    # length, and it retires it WITHOUT calling the bound routine ("clean final frame"). A
    # one-frame hold would therefore expire with nobody to start the exit.
    ft_anim_start "$n" 2 "$hold" 1 0
    ft_anim_bind  "$n" _ft_bigarrow_frame bigarrow
    return 0
}
_ft_bigarrow_enter_exit() {     # name
    local n=$1 xms fms
    _ft_bigarrow_styled_nth "$n" animationDuration 2 "$FT_BIGARROW_EXIT_MS"; xms=$FT_RET
    _ft_bigarrow_ms "$xms" "$FT_BIGARROW_EXIT_MS"; xms=$FT_RET
    FT_BIGARROW_STAGE[$n]=exit
    fms=$(( xms / FT_BIGARROW_EXIT_FRAMES )); (( fms < 12 )) && fms=12
    ft_anim_start "$n" $(( FT_BIGARROW_EXIT_FRAMES + 1 )) "$fms" 1 0   # +1: see _ft_bigarrow_arm
    ft_anim_bind  "$n" _ft_bigarrow_frame bigarrow
    return 0
}
# THE WAY OUT, and the ground repair that has to go with it. An overlay paints OUTSIDE its
# layout box, so when it goes, nothing else on the page knows those cells were ever touched —
# damaging its published footprint is the only thing that brings them back. Same shape as the
# '.' locator's oneshot retirement, which is where the idiom comes from.
_ft_bigarrow_retire() {         # name
    local n=$1
    _ft_bigarrow_damage_all "$n"
    ft_remove "$n"
    # NOT narrowed. FT_DAMAGE_NARROW repairs only what a damage rect literally covers and leans
    # on a later full refresh to sweep up any stray; a retiring beacon has no later refresh, so
    # this one takes the full repair path. It happens once in the arrow's life.
    ft_redraw_dirty                 # composites and flushes — see _ft_beacon_mouse_drag
    return 0
}
# One frame. Repair what the last position vacated, then re-emit the same art at the new one —
# deliberately the DRAG's shape (damage → ft_redraw_dirty → composite → flush) and not
# ft_refresh's: nothing about the LAYOUT changes when an overlay slides, and a full refresh for
# a moved overlay was measured at ~230ms a frame on a 62×40 screen.
_ft_bigarrow_frame() {          # name struct
    local name=$1
    [[ -z "${FT_TYPE[$name]:-}" ]] && return 0
    local ph=${FT_ANIM_PHASE[$name]:--1} life len stage=${FT_BIGARROW_STAGE[$name]:-fly}
    ft_resolved_prop "$name" lifetime persist; life=$FT_RET
    len=${FT_ANIM_LENGTH[$name]:-$FT_BIGARROW_FRAMES}
    # ── stage transitions ────────────────────────────────────────────────────
    if (( ph >= len - 1 )); then
        case "$stage" in
            fly)
                # A persist arrow simply lands: the animation retires itself on the next tick and
                # the phase-is-unset case in _ft_draw_beacon paints the settled frame from then on.
                [[ "$life" == oneshot ]] || return 0
                _ft_bigarrow_enter_hold "$name"; return 0 ;;
            hold)
                local xk; _ft_bigarrow_prop "$name" exit "$FT_BIGARROW_EXIT"; xk=$FT_RET
                if [[ "$xk" == none ]]; then _ft_bigarrow_retire "$name"; return 0; fi
                _ft_bigarrow_enter_exit "$name"; return 0 ;;
            exit)
                _ft_bigarrow_retire "$name"; return 0 ;;
        esac
    fi
    # A hold frame that is not the last one has nothing to draw — the arrow has not moved and
    # its colour has not changed. Returning here is the whole reason the hold is affordable.
    [[ "$stage" == hold ]] && return 0
    ft_clip_reset
    _ft_beacon_rect "$name"; (( FT_BEACON_RECT_OK )) || return 0
    _ft_bigarrow_geometry "$name" "$ph" || return 0
    _ft_bigarrow_damage_move "$name" "$FT_BIGARROW_TOP" "$FT_BIGARROW_LEFT" "$FT_BIGARROW_SHAPE_KEY"
    # UNDER COALESCING, RECORD AND STOP — never paint half a frame. The run loop wraps every
    # dispatch in FT_COALESCING=1 and ft_redraw_dirty defers under it, so painting here would
    # put the arrow at its new position with the vacated cells unrepaired until the burst
    # drained. A dropped animation frame beats a smear, and beats a late keystroke.
    (( FT_COALESCING )) && return 0
    local keep=$FT_DAMAGE_NARROW; FT_DAMAGE_NARROW=1
    ft_redraw_dirty                 # composites and flushes — see _ft_beacon_mouse_drag
    FT_DAMAGE_NARROW=$keep
    return 0
}
