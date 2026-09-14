# Damage-region compositing (design) — SUPERSEDED

> **Superseded by `rendering-spans.md`.** This design repairs the screen by re-deriving what
> *should* be under a damaged rectangle, which requires repainting controls — and an ancestor
> that fills its background repaints its whole box, wiping siblings the damage never covered.
> That flaw is described in §"Root cause" below and is what defeated three implementations.
> The span renderer avoids the question entirely by *remembering* what it drew.
> Kept for the failure analysis, which is still accurate and still worth reading.


## Why

Today the engine tracks **dirty controls** (`FT_DIRTY[name]`) — "this control must repaint". It has
no notion of **damage**: cells that are now wrong because something *left* them (an overlay moved,
a control was removed, a subtree shrank, a scroll shifted content).

Because the engine can't express that, apps hand-roll it. `demo/css-demo.bash:_goto_step` captures
a callout's published footprint, calls `_ft_erase_rect`, then guesses which controls to re-dirty.
That is rendering logic in an app — it does not belong there, and it has been wrong twice.

## Root cause of the two failed "narrow repaint" attempts

Erase the damaged rect, then repaint every *control* intersecting it → the specimen, its label and
the control row still came back **blank**.

The reason: the erased rect spans a **transparent container** (`ft-div`, `panel`). Containers paint
no background — only leaves paint. So repainting the intersecting leaves leaves every cell *between*
them (the container's own area) blank. A full-subtree repaint accidentally worked because the
enclosing `ft-frame` fills its background.

**So damage repair is not "repaint intersecting controls". It is:**

1. fill the damaged region from the nearest **opaque** ancestor (a frame/form background), then
2. repaint every control intersecting it, parents before children, then
3. re-composite overlays intersecting it, in z order.

That is a compositor, and it belongs in the engine.

## Model

```
FT_DAMAGE=( "T L B R" … )        # accumulated this frame, engine-wide
FT_PAINT_RECT[name]="T L B R"    # what NAME actually painted last frame (may exceed its box:
                                 #   a beacon's leader, a dropdown overlay, a focus ring)
```

`ft_damage T L B R` — public: "these cells are now wrong." Anything that paints outside its own
layout box records its real footprint via `ft_publish_paint_rect NAME T L B R` at the end of its draw
(beacons already compute exactly this as `FT_BEACON_EXTENT`).

### Automatic damage (the point — apps stop doing this)

The engine raises damage itself when:

| event | damage |
|---|---|
| `ft_remove NAME` | `FT_PAINT_RECT[NAME]` (and each descendant's) |
| `display:none` / `visibility:hidden` | its paint rect |
| layout moves/resizes a control | old paint rect (new one repaints anyway) |
| `ft_scroll_set` / `ft_scroll_to` | the viewport rect |
| an overlay repositions | its old paint rect |

`_goto_step` then reduces to: remove the callout, place the new one, dirty the counter/buttons.
No `_ft_erase_rect`, no rect bookkeeping, no guessing.

## The repair pass (inside `ft_redraw_dirty`)

```
1. coalesce FT_DAMAGE           # merge overlapping/adjacent rects; cap count, else union
2. for each damage rect D:
     a. _ft_opaque_ancestor_at(D) → the nearest ancestor that fills bg; paint its bg over D
        (clipped to D — never repaint the whole ancestor)
     b. ENLIST every control whose box intersects D          (FT_REPAIR, not FT_DIRTY)
3. paint the enlisted and the dirty together, parents first (existing depth sort)
4. re-composite overlays whose paint rect intersects (damage ∪ painted rects), z ascending
5. FT_DAMAGE=(); FT_DIRTY=(); FT_REPAIR=()
```

Step 2a is the piece both failed attempts lacked.

**Step 2b says ENLIST and not DIRTY, and the difference is the whole cost of a drag frame.**
"Your content changed" and "something painted over your cells" are different claims: the first
needs a derivation, the second needs the same ink put back, which the retained display list can
do with an append (`ft-forms.bash`, `FT_RETAINED_BLOCK`). `_ft_damage_enlist` fills `FT_REPAIR`;
`ft_dirty` fills `FT_DIRTY` **and drops the retained block**. Measured on `tools/bench-drag.bash`:
the four controls a dragged callout uncovers cost 11.25 ms a frame to re-derive and 1.9 ms to
re-emit, and they produce byte-identical output on 19 frames out of 20.

**Step 4 is the compositor, and `ft_redraw_dirty` owns it.** It flushes too. So a caller that wants
a frame calls `ft_redraw_dirty` and stops — compositing again afterwards is a second, identical
paint of *every* overlay on the screen, including ones nothing touched, and it is invisible:
the second paint lands on top of the first, so no screen comparison can ever see it. Five call
sites in `controls/ft-beacon.bash` followed the repair with a blanket `_ft_composite_overlays;
ft_flush` (a drag frame, a release, a close, and both bigarrow paths) and paid ~8 ms and one extra
full callout paint every time. `tests/test-composite-once.bash` counts the paints, because a
count is the only instrument that reads them.

## Cost

Damage repair is proportional to **changed area**, not to control count. A moved callout damages
~2 small rects instead of forcing an ~80ms full-stage repaint. This is the mechanism that puts
incremental updates (typing, animation ticks, a moving overlay) inside a ~15ms budget; a *full*
repaint of a busy screen stays ~65–80ms and always will, because that is bash string cost.

## Correctness gate (non-negotiable)

Damage compositing is exactly the class of change that fails silently and looks fine in unit tests.
Every change here must be gated on: **render the real app and diff the screen against a full
repaint, for every page and every step.** A "are the controls still on screen" grep of the live PTY
render is the minimum bar — it caught both previous regressions on the first run.

## Migration

1. Add `FT_PAINT_RECT` + `ft_damage`; have `ft_draw_one` record each control's paint rect.
2. Implement the repair pass; keep `_ft_dirty_subtree` working (a subtree dirty is just damage
   over its rect).
3. Auto-damage on remove/hide/move/scroll/overlay-move.
4. Delete the app-level erase juggling in `css-demo.bash:_goto_step`.
5. Beacons publish `ft_publish_paint_rect` instead of apps reading `FT_BEACON_EXTENT`.
