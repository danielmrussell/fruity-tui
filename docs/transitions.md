# Transitions — a control that morphs in from the pixels underneath

> Prototype, on the branch `compositing-transitions`. Everything below is measured; the things
> that did not work are here too, because that is the only part of a document like this that
> saves anyone any time.

```css
#notice   { transition: opacity 320ms ease-in-out; }
.callout  { transition: opacity 260ms ease-out; }
#punch    { transition: opacity 480ms cubic-bezier(0.34, 1.56, 0.64, 1); }
:root     { --transition-schedule: contrast; }        /* contrast | average */
```

The timing function is CSS's whole set, because it is CSS's own solver: `linear | ease |
ease-in | ease-out | ease-in-out | cubic-bezier(x1,y1,x2,y2)`, plus `ease-out-back` /
`ease-in-back` / `ease-in-out-back` (see §3).

**And that is the whole of the application's side of it.** There is no call to make:

```bash
ft-modify notice display=block      # it transitions in
ft-modify notice display=none       # it goes away, and the ground repairs itself
```

A stylesheet says a control transitions; changing `display` makes it happen. `transition` is a
paint-kind property registered like `animation`, resolved through the ordinary cascade
(`ft_style`), and the transition rides the shared per-control animation loop.

### What CSS calls this, and the one thing a terminal has that a browser does not

Transitioning an element that is **appearing** is the awkward corner of CSS's model, because
`display` is a *discrete* property: there is no "half displayed" to interpolate through, and
before the element existed there was no old value to interpolate *from*. A browser needs two
opt-ins to express it — `transition-behavior: allow-discrete`, which lets a discrete property
participate at all, and `@starting-style`, which declares what the element looked like
immediately before it existed.

A terminal needs neither, and the reason is the whole idea of this file: **the starting style is
not a declaration, it is the ground.** The cells were already showing something real, so "what it
looked like before it existed" is a question the screen has already answered. `display: none →
block` therefore behaves as though `allow-discrete` were always on and `@starting-style` were
always "whatever is underneath". If the engine ever grows more transitionable properties, the
`allow-discrete` opt-in is the thing to copy; `@starting-style` should stay unnecessary.

### The escape hatches, for the two cases that need more

```bash
ft_transition_in NAME       # force one now. ALWAYS SUCCEEDS: if the cascade asks for no
                            # transition it marks NAME (and its children) dirty and returns 0,
                            # so the control appears either way — no `|| ft_dirty` needed
ft_transition_cancel NAME   # stop one and hand the cells back
ft_transition_supported     # → 0 truecolor, 1 "this will band, not melt"

ft_transition_active NAME       # → 0 while a transition owns NAME's cells
ft_transition_live NAME         # → 0 if it is re-reading the ground every frame (§4)
ft_transition_frame_count NAME  # → FT_RET
ft_transition_cut_frame NAME    # → FT_RET, the frame where the glyphs are exchanged
ft_transition_frame NAME INDEX  # → FT_RET, that frame's bytes
ft_transition_rect NAME         # → FT_RET, "top left bottom right"
```

The read-only five exist because `tests/test-transition.bash` has to look at frames, and a test
that reaches into `_FT_TRANSITION_*` is a test that teaches the wrong thing. Nothing in
`demo/transition-demo.bash` uses any of them.

> **This is the second version of this API.** The first required `ft_transition_in "$n" ||
> ft_dirty "$n"` at every call site and left an app hiding a box by reading `FT_PAINT_RECT`,
> setting `display=none` and calling `ft_damage` itself — with `_FT_TRANSITION_ACTIVE`, a
> private name, in the demo. That is not a rough edge: an imperative arm call is a deviation
> from "copy CSS/CSSOM verbatim" that nobody chose, it just fell out of building the machinery
> bottom-up. The failure mode was silent, too — forget the `||` and the control never appears.
> The fix was to make the engine notice the `display` change (`ft-modify`) and arm after layout
> settles (`ft_redraw_dirty`), and to make hiding damage its own cells, which is something
> `rendering-damage.md` always said `display: none` owed and is a bug with or without
> transitions.

---

## 1. Why the colours move the way they do

A terminal cell is `(glyph, foreground, background)`. Two layers' glyphs are **mutually
exclusive**: a cell shows one or the other, never a blend. So the glyph must be *swapped* at some
instant, and the entire job of the schedule is to make that instant unobservable.

A glyph is unobservable exactly when **its foreground equals its background**. Not when the
colours are "close", not when they have "met in the middle" — when they are the same colour.
So the schedule is:

| | first half | at the cut | second half |
|---|---|---|---|
| background | bottom → top, monotonically, across the **whole** transition | | |
| foreground | bottom's fg → **the background at that moment** | `fg == bg`, glyph swapped | the background → top's fg |

The text sinks into its own background, the exchange happens in the dark, and the new text
surfaces out of the background it is going to sit on.

One sampled frame is **forced** to land exactly on the cut (`_ft_transition_plan` snaps the
nearest frame's eased value to 500). Without that, the swap happens between two frames that both
have contrast — which is the visible cut the whole scheme exists to hide. Snapping moves a
colour, not a time: the frame still shows when it was always going to, so the pacing is unchanged.

### The other schedule, and what measuring it showed

The framework's author proposed a different one: average the two backgrounds, average the two
foregrounds, travel to those averages and back out. It is implemented (`--transition-schedule:
average`) because he asked for the screen to decide. **The averaging is per cell, between that
cell's own two layers** — nothing is ever pooled across different cells, and this document is not
claiming otherwise.

Measured as the worst per-cell `|fg−bg|` over the inked cells of each frame (0 = the glyph cannot
be seen at all, 765 = maximum), on the bench's own 40×8 rect:

```
contrast   630 606 531 405 228   0  243 435 570 651 681
average    630 628 624 616 607 654  663 669 675 678 681
```

`average` never drops below 607. The outgoing text is **fully legible at the instant it is
replaced**, so the cut is exactly as visible as a hard replace: the averaging changes the colours
but not the thing it was meant to hide. `tests/test-transition.bash` pins this — 110 of 110 inked
cells are still legible at `average`'s own cut frame, and 0 of 110 at `contrast`'s.

The reason is arithmetic, not taste. Averaging fg and bg *independently* produces two different
midpoints, and the distance between two different colours is precisely what the eye reads as text.

### The two schedules' backgrounds are the same curve

Worth stating because it narrows the disagreement to one line of code. `average`'s background goes
bottom → `(bottom+top)/2` → top, each half taking half the time. The midpoint of a linear
interpolation lies **on** the line, so at eased progress *e*:

```
first half:   bottom + (mid − bottom)·2e        = bottom + (top − bottom)·e
second half:  mid + (top − mid)·(2e − 1)        = bottom + (top − bottom)·e
```

— identical to `contrast`'s single monotonic bottom → top. The test asserts this on real cells, and
it means **the whole of the visible difference between the two proposals is the foreground rule**.
That is also the half the author accepted: the text moves toward that cell's own background.

---

## 2. Why it is fast

Per-cell work per frame is impossible in bash. A 40×8 callout is 320 cells and a plain array read
alone is ~1.3µs (`tools/bench-array-access.bash`), before any colour arithmetic. So nothing here is
per cell.

**Batch by style run, not by cell.** This is the author's idea and it is the whole of the
performance story: a *run* is a maximal horizontal stretch whose `(fg, bg)` pair is the same in the
bottom layer **and** the same in the top layer, so every cell in it blends identically. One colour
computation per run per frame, one emitted string per run. The engine already thinks this way —
`ft_print_at_width` takes a known display width and emits a whole coloured row in one write, and
`_ft_damage_fill` resolves ground per run rather than per cell.

Measured on the gate's rect: **320 cells → 29 runs → 4 blend classes.** Runs that share a style
*pair* share a class, and the arithmetic is done per class per frame, so the blend is 4×11
computations rather than 320×11.

**Read the layers back as spans, not cells.** The framework keeps no retained cell buffer, so
"what glyph is underneath" cannot be looked up — but the bytes we emitted *are* the answer, and
their escape vocabulary is ours and tiny (CUP, SGR, text). Each text chunk is one `(row, column,
text, style)` piece; overlaps within a row are resolved by walking the row's pieces backwards
against a claimed-column set; the two layers' interval lists are then intersected. Work is
proportional to pieces (tens), never to cells.

**Precompute the whole transition.** At kick-off every frame is reduced to one ready-to-emit
string. A frame is then a `printf`.

### The numbers

`tools/bench-transition.bash`, at 95×34 and 140×44, 40×8 rect, 11 frames, both schedules, both
colour modes. Bash 5.2, WSL2.

| | |
|---|---|
| **playback** | **54–100 µs per frame** |
| bytes per frame | 1290 (256) – 1760 (truecolor) |
| kick-off | 118–123 ms on an idle machine; 165 ms was the worst seen under load |
| last frame vs a from-scratch render | 0 of 320 cells differ, in all 8 configurations |

Kick-off, broken down (`FT_TRANSITION_PROFILE=1`):

| phase | ms | what it is |
|---|---|---|
| paint the incoming layer | 17–43 | an ordinary engine paint of the control and its children |
| capture the ground | 40–65 | an ordinary engine damage repair over the rect |
| read both layers back | 40–60 | the parse — **exists only because there is no cell buffer** |
| build runs | 8–42 | interval intersection |
| blend every frame | 11–18 | 4 classes × 11 frames |

Two thirds of that is work any appearing control already costs (a repair plus a paint). The
transition adds the read-back and the blend. **Arming a transition roughly doubles the cost of
making the control appear**, and it is a one-off.

---

## 2a. One easing solver

This branch and the `variant=bigarrow` work were written in parallel from the same commit and
neither knew about the other, so both grew a way to bend a linear phase through a curve. The
arrow's is a real cubic-bezier solver behind CSS's own `animation-timing-function`
(`ft_ease` / `ft_ease_points` / `ft_ease_table` in `ft-forms.bash`); this file's was a private
`case` over five keywords with hand-rolled quadratics. The private one is gone.

That is strictly a gain — transitions get `cubic-bezier()` and the three overshoot curves for
free — but it moved some frames, so here is exactly which, at eleven frames, in thousandths:

| curve | what moved |
|---|---|
| `linear` | **nothing** — identical |
| `ease-in-out` | ≤ 12/1000 on six frames; imperceptible |
| `ease-in` | up to 68/1000 (f6) — my quadratic was not the curve CSS names |
| `ease-out` | up to 70/1000 (f4) — same |
| **`ease`** | **up to 362/1000 (f4)** — a correction, not a drift: the old code *aliased* `ease` to `ease-in-out`, and CSS's `ease` is `cubic-bezier(0.25,0.1,0.25,1)`, a fast-start curve. Anything that asked for `ease` was silently given something else. |

Two things the solver forced, both of which are now gated:

**Channels are clamped; the curve is not.** An `-back` curve returns values below 0 and above
1000 *on purpose* — `ease-out-back` peaks at 1096 — so a blended channel leaves 0..255 and
`38;2;-14;…` is not a colour. Clamping the *curve* would delete the overshoot, which is the
effect; clamping the *channel* is what CSS does to interpolated colours anyway. The background
therefore sails past the target colour and settles back into it, which is the visible payoff
and is what the demo's fourth card shows.

**The glyph swaps on a frame index, not on a value.** The cut used to be "the frame whose eased
value is 500". Any cubic-bezier may cross 500 more than once, and the text would swap back and
forth. The swap is now chosen by `frame >= cut_frame`, so it happens exactly once for every
curve — and because one frame is still snapped to exactly 500, that frame still has zero
contrast. `tests/test-transition.bash` proves it under `cubic-bezier(0.34, 1.56, 0.64, 1)`:
0 of 110 inked cells legible at the cut.

---

## 3. The bar is input latency, not frame rate

"If a pop-up appears while I'm typing in a text field, I shouldn't feel a slowdown."

The run loop blocks in `read -t $FT_ANIM_INTERVAL`; a real keystroke wins that read the instant it
arrives. So an animation adds latency **only** when the key lands while a tick is executing, and
the worst-case added latency is exactly the cost of one tick. `tools/bench-transition-latency.bash`
types twenty characters into a focused text field and measures the whole keystroke path — dispatch,
settle, repaint — with a transition in flight:

| | animation tick (the added latency) | keystroke |
|---|---|---|
| nothing running | — | median **2 ms** |
| precomputed transition running | median 1 ms, **max 7 ms** | median 2 ms |
| live ground, yielding | median 7 ms, max 103 ms | median 2 ms |
| live ground, **no** yielding | median 105 ms, **max 126 ms** | median 2 ms |
| bigarrow alone | median 5 ms, max 49 ms (first tick) | — |
| **transition + bigarrow** | median 6 ms, max 17 ms | median 2 ms, **max 6 ms** |

**The precomputed path meets the bar with room to spare.** Six milliseconds is not perceptible.

The last row is the merged state: this branch's transition and the `variant=bigarrow` work now
tick from the same `ft_anim_step`, so the honest question is what a keystroke costs with both
running. It is unchanged — median 2 ms, max 6 ms, the same bar as before the merge. The arrow
contributes ~5 ms a tick of its own and one ~49 ms spike on its first tick, where it rasterises
its art for a shape it has not drawn before; the series (`49 6 6 9 5 5 5 8 5 14 …`) shows that
is a build, not a stall. Attributed by measuring the arrow alone, not by assuming.

The live path does not, and that is the honest headline of section 4.

The remaining cost a user can feel is the **kick-off hitch**: 130–165 ms in the event that makes
the control appear. If a notice arrives while you are typing, you feel it once. It is bounded, it
is one-off, and section 6 says what would remove it.

---

## 4. When the ground is moving

Precomputed frames assume both layers are static. If something under the rect animates, they are
photographs of a moment that has passed. The engine already knows which controls animate —
`FT_ANIM_PHASE` — and where their boxes are, so `_ft_transition_ground_animates` asks the registry
rather than inventing a flag, and the transition takes a **live path**: re-capture the ground,
re-read it, rebuild runs, blend one frame. Everything the layers did that frame, including their
own animations, is what gets blended. That is the behaviour asked for, and it works.

It costs **88–104 ms per frame**, which is ~10 fps and, worse, 88–104 ms of added input latency
every tick. Unusable as it stands.

So the live path **yields**. While the user has done something within `FT_TRANSITION_YIELD_MS`
(250 ms by default — `FT_LAST_INPUT_MS` is stamped by the input layer, so this asks the engine
when the user last acted rather than inventing its own signal), the ground is *not* re-read: the
previous frame's run decomposition is reused and only the colours are recomputed, ~1 ms. The
transition keeps moving, an animation underneath it holds still for a frame, and typing does not
stutter. A coarse frame beats a late character.

**What I would do next, in order:** (a) make the live path re-read the ground only every *k*-th
frame even when idle, since a background animation at 8 fps under a 400 ms transition is
indistinguishable from one at 30; (b) if that is not enough, restrict the live path to transitions
shorter than ~250 ms; (c) do not "pause the animations underneath" — it was tempting and it is
wrong, because the whole point of compositing last is that the lower layer keeps living.

**Known limit:** the live path uses one shared run decomposition, so it supports one live
transition at a time. Concurrent transitions on the *precomputed* path are fine — their frames are
stored per control.

---

## 4a. One blend — and why `exit=fade` is not this one

`variant=bigarrow` retires with `exit=fade`, described in its own source as "the shimmer
effect's technique … blends toward the ground". That reads like a second copy of this file, and
the first instruction after the merge was to make it *this* file running in reverse. It should
not be, and the reason is worth writing down because the duplication is real but it is a
different duplication.

**`exit=fade` does not blend toward the ground. It blends toward one colour.**
`_ft_bigarrow_color` resolves `_ft_effective_bg` once per paint — the arrow's own *cascaded*
background — and lerps the arrow's ink toward it by an alpha. It never reads a single cell of
what is underneath and never restores an underlying glyph; at alpha 0 the arrow's glyphs are
still there, invisible against an assumed backdrop, and the page comes back only when the
beacon destroys itself and damages the cells. That is **CSS `opacity`**, exactly, and it is the
right primitive for an arrow that mostly sits on a flat background.

So the actual duplication is *three copies of the opacity blend*, and they are the same formula
with the same operand roles:

| | the blend |
|---|---|
| `_ft_css_kf_compose` (ft-css.bash) | `_ft_css_blend basebg fg opacity%` |
| the beacon shimmer | ink toward the resolved background by an alpha |
| `_ft_bigarrow_color` | `br + (fr-br)*FT_BIGARROW_ALPHA/100` per channel |

and **one** implementation of "blend toward the real pixels underneath" — this file. Collapsing
the three onto `@keyframes … { opacity }` is the unification that removes a fork. Putting the
arrow's exit onto the transition machinery would not remove one; it would replace a cheap
correct thing with an expensive different thing.

**Measured, which is what settled it.** A transition's cost is dominated by arming — capture
the ground, read both layers back, build runs — and that scales with the rect:

| rect | cells | kick-off | playback |
|---|---|---|---|
| 20×5 | 100 | 129 ms | 54 µs |
| 40×8 | 320 | 187 ms | 109 µs |
| 40×15 | 600 | 228 ms | 163 µs |
| 60×15 | 900 | 295 ms | 272 µs |
| 80×20 | 1600 | 363 ms | 290 µs |

A bigarrow's extent is 30 visual units across and roughly half that in rows — 40×15 to 60×15 —
so arming a true transition-out for one costs **228–295 ms**. The arrow's exit fires 2.4 s
after it lands, *unprompted*: the user did not press anything, and the whole point of §3 is
that a tick over ~6 ms is where "no slowdown" stops being true. 250 ms is forty times the bar,
spent at a moment nobody asked for anything, to improve an exit that is not even the default
(`retract` is). Against ~0 ms for the opacity fade.

**So it was not forced, and here is what would change that.** A true transition-out *is*
implementable now — the lifecycle objection I recorded earlier ("`ft_remove` tears a control
out immediately") is answered by the arrow itself, which already survives its own exit through
a fly → hold → exit → destroy stage machine. What is missing is not lifecycle, it is cost:

1. **Arm the exit during the hold.** The hold is a 2.4 s wait with one wakeup, and both layers
   are static throughout it. Precomputing there moves the 250 ms off the exit entirely — but it
   moves it *into* the hold, which is also unprompted, so this only helps if the arming itself
   gets cheap.
2. **The span renderer makes it cheap.** Two thirds of arming is capturing the ground and
   parsing both layers back, and both exist only because there is no retained cell buffer
   (§7). With one, arming is a lookup and this whole objection evaporates.

Until (2), `exit=fade` should become `@keyframes fade-out { to { opacity: 0 } }` on the shared
opacity path — deleting the third copy of the alpha blend — and a ground-restoring dissolve
should wait for the renderer that can afford it.

---

## 4b. CSS names where CSS has them

The arrow shipped with `holdDuration`, `exitDuration` and `exitTimingFunction`. All three are
names for things CSS had already named, and the standing rule here is copy CSS verbatim and
write down any deviation. They are gone.

**Two animations on one element is a comma-separated list.** That is CSS's own answer, and it
needs no new property names at all: the leaving reads *item 2* of the longhands the flight
reads item 1 of.

```css
beacon[variant=bigarrow] {
    animation-duration:        560ms, 420ms;              /* fly, leave */
    animation-timing-function: ease-out-back, ease-in-back;
    animation-delay:           0ms, 2960ms;               /* the leave starts at 2960ms */
}
```

| was | is |
|---|---|
| `exitDuration=420ms` | `animation-duration` item 2 |
| `exitTimingFunction=linear` | `animation-timing-function` item 2 |
| `holdDuration=2400ms` | `animation-delay` item 2 |

A one-item list still means "both", which is CSS's own repeat rule. `ft_css_list_nth` does the
split, tracking parenthesis depth — `cubic-bezier()` contains commas of its own, and a naive
split handed `cubic-bezier(0.34` to the solver, which fell back to linear without complaining.

**One deviation, deliberate, and it is in the delay's *default*, not its meaning.** CSS measures
`animation-delay` from when the element starts animating, and that is honoured: the hold is
`delay − flight`, so an author who writes `2960ms` gets the leave at 2960 ms whatever the flight
costs. But the *class default* is still expressed as a hold (`FT_BIGARROW_HOLD_MS=2400`), and
the default delay is computed as flight + hold — because 2400 ms is the number that was tuned by
looking at the thing, and a rename must not silently retime it. Verified: the shipped default
hold is still 2400 ms to the millisecond.

**Where CSS has no name, the concept stays and the mapping is written down.** `exit=retract`
animates glyph *geometry* — the arrow slides back out along its own axis — and this framework
has an explicit boundary there: `sheen` and `beacon` are animation *routines* referenced by
name precisely because "`@keyframes` sample colour properties" cannot express a moving glyph
(`docs/styling-model.md` §7). `exit=` is the same kind of thing: it names a routine, not a
property list. The CSS construct it corresponds to is a second `animation` on the element whose
keyframes move a transform; the bespoke name was unavoidable because the engine has no
transform to keyframe. If it ever gains one, `exit=retract` becomes
`@keyframes retract { to { transform: translate(...) } }` and the name can go.

---

## 5. Colour

Interpolation is a straight per-channel lerp on 0–255 sRGB values — the same space `_ft_css_blend`
and every `@keyframes` ramp in this framework already use. It is not perceptually uniform (a
gamma-correct blend would square, average and take a root, which integer bash cannot do without a
table), and a mid-grey step is therefore slightly darker than the eye expects. That was a
deliberate choice: **consistency with the rest of the engine matters more here than
correctness-in-principle**, because a transition that landed on a subtly different colour from the
keyframe ramp beside it would read as a bug. If the ramps ever move to a gamma-correct space, this
should move with them, not before them.

**256-colour terminals band, and that is not fixable here.** Every intermediate is quantised to the
xterm cube, whose levels are 40 apart in each channel, so an 11-frame ramp between two nearby
colours collapses to two or three distinct steps. Measured, the same rect in both modes:

```
truecolor  contrast   630 606 531 405 228   0 243 435 570 651 681
256        contrast   630 600 540 420 240   0 240 441 570 630 681
256        average    630 630 630 641 641 630 681 681 681 681 681
```

`contrast` still reaches exactly 0 at the cut (fg and bg quantise to the same cube entry, which is
the one property that must survive), so the *swap* is still hidden — it is the smoothness that is
lost. `average` in 256 is visibly stepped: five frames at 630, then a jump.

**No dithering.** A checkerboard of two cube entries reads as *texture* on text, not as a blend —
it makes glyphs look damaged rather than faded. `ft_transition_supported` reports the situation and
the demo says so on screen; an app that cares can shorten the duration (fewer frames, so fewer
visibly repeated steps) or decline.

**Indices 0–15 are the terminal's own configurable palette and have no fixed RGB.** A transition
ending on one lands on xterm's canonical value for it, which may not be what the user's terminal
draws. The theme's colours are cube/grey indices, so this does not bite in practice, but an app
that writes `color: red` is exposed.

**A cell nothing painted** has no colour of its own; it is assumed to be the theme surface
(`FT_COLOR_BODY`'s background). A terminal whose default background differs from the theme's will
start such a cell slightly wrong.

---

## 6. What did not work

**A cell grid was the wrong data structure — twice as slow as the spans that replaced it.** The
first working version rasterised both layers into per-cell arrays of glyph/fg/bg. Correct, and
**55 ms** for 320 cells. The bytes already arrive as `(row, column, text, style)` pieces; parsing
them as pieces and intersecting interval lists does the same job in ~20 ms and stops caring how
big the rect is. If you find yourself writing `for cell in rect` in this framework, stop.

**Three performance guesses in a row were wrong, and each cost a round trip.** In order: "the SGR
decode is the hot spot" (it was 3 ms of 19); "the chunk splitting is the hot spot" (0.5 ms); "the
pen cache will fix it" (19 → 16 ms). The actual answer, found by ablating the loop one stage at a
time, was that `ft_display_width` on a 34-cell box-drawing string costs **2065 µs**, because
`ft_char_cols` runs a `printf` builtin per glyph at ~60 µs and a border is 34 of them. Memoising
character widths took the top layer's parse from 43 ms to 19 ms. *Profile, do not guess.*

**Column clipping the ground capture is unsafe.** The obvious way to shrink the parse is to make
the engine emit only the rect's columns. It cannot: `ft_print_at`'s column guard **drops** a call whose
start column is left of the clip rather than left-truncating it, so a label beginning outside the
band and reaching into it would silently vanish. Only the *rows* are clamped (`ft_clip_band`),
which is exact because a paint call is one row. The ground bytes went 8354 → 2177 on rows alone.

**The ground fill counted the incoming control as scenery.** `_ft_damage_fill` resolves each run's
background from the deepest covering node — and the control being transitioned *in* is a covering
node. The first integrated version therefore morphed from purple to purple: it asked the incoming
notice for the background of its own cells. Fixed by excluding a transitioning subtree from
`_ft_dfill_hit_build`, the same predicate `ft_draw_one` uses.

**An escape that sets only colours lets the previous run's attributes leak on.** A frame is a chain
of runs with no resets between them, so the first version's final frame came out **bold across a
whole title bar** and matched no real render. Every run's escape now states the whole pen
(`22;24` first, then what the class wants) — six bytes a run, and a frame becomes
position-independent.

**Retiring dirtied the control but not its children.** Every caller of `ft_anim_stop` follows it
with `ft_dirty NAME`, which repaints that control alone — and a frame's draw fills its box, so the
real paint that lands after the last blended frame *erased the label the transition had just
finished melting in*. The demo's notices came out empty and the unit assertions were all green.
`_ft_transition_retire` dirties the subtree.

**Rows stayed absolute where everything else went relative.** The port from probe to module lost
one `- top`, so half of each layer addressed past the end of the rect and the other half painted
four rows low. Caught by the "last frame equals a real render" check, which is exactly the check
that is worth having.

**Two benches lied before they told the truth.** One reused a control name, so a container left
open by a missing `end_ft_frame` nested run 2's whole tree inside run 1's popup and every later
draw was clipped to nothing. The other leaked a running animation, so every configuration after
the first silently took the live path, read `_FT_TRANSITION_FRAME[-1+i]`, and printed a full page
of plausible, wrong numbers. Both now assert the path they think they are measuring. A bench that
cannot fail loudly is not evidence.

**A test compared colours as bytes.** The engine emits palette *indices* (`38;5;213`), the blend
emits RGB (`38;2;255;135;255`). Same pixel on a truecolor terminal; a string compare called a
cell-exact final frame 110/110 wrong. The gate now reduces both forms to `r,g,b` with xterm's cube
rule written out independently of the framework's copy of it.

**One layout per notice, in the demo.** Showing three notices with an `ft_layout app` between each
was **880 ms of the 1500 ms** a replay took — reflowing a fifteen-control page three times to learn
the same three boxes. The framework's own rule is one layout per burst; the demo was breaking it.
(Both `ft_layout` calls are now gone anyway: `ft-modify display=` requests a reflow and the run
loop's own `ft_reflow_flush` settles it once for the burst, which is what should have happened
from the start.)

**The API was built bottom-up, and it showed.** The demo's `_show`/`_hide` pair — nine lines,
`FT_PAINT_RECT` bookkeeping, an explicit `ft_damage`, an `|| ft_dirty` fallback and a read of
`_FT_TRANSITION_ACTIVE` — was the honest output of writing the machinery first and the surface
last. Every one of those lines was the application doing the engine's job. The whole thing is now
`ft-modify n display=block`. The lesson is not "write the demo earlier", it is that **a demo that
needs a private name is a bug report about the API**, and it was sitting there being read as
documentation.

---

## 6a. The end state: three mechanisms, and which should survive

Four things on this branch now animate, and they arrived from three directions. Stating where
they should end up is worth doing while both halves are fresh, even though none of this
migration is done here.

| today | what it really is | should become |
|---|---|---|
| `@keyframes` + `animation:` | colour/weight/opacity over time | **survives — this is the trunk** |
| beacon `effect=pulse\|blink` | ~~an opacity ramp, hand-rolled~~ — **wrong, see below** | *not* the built-ins they were said to duplicate |
| beacon `effect=shimmer`, bigarrow `exit=fade` | ink → a resolved background by an alpha | **one shared blend — done**; `@keyframes` is *not* available, see below |
| beacon `effect=bob`, bigarrow `exit=retract`, textfield `sheen` | **glyph geometry over time** | stays a routine until the engine has a transform to keyframe |
| `transition:` (this file) | ink → **the real pixels underneath** | survives; it is the only thing that reads the ground |

> **Rule 1 was executed, and half of it was wrong.** Two of the five rows above were mis-read
> when this table was written; the corrections are §6b. What survived contact: the blend really
> was the same arithmetic in two places, and it is one function now (`_ft_alpha_blend`), with
> the painted bytes of every shimmer phase and every `exit=fade` frame byte-identical across the
> change. What did not: "`@keyframes … { opacity }` on the shared path" cannot express either
> effect, and `effect=pulse|blink` are not opacity ramps at all.

Three rules fall out of that table, and they are the design:

**1. `@keyframes` is the trunk, and anything expressible as a property ramp belongs on it.**
The tell for "this belongs on keyframes" is simple: if the effect can be described as *some
property, over time*, it is a keyframe. **The claim that `shimmer` and `exit=fade` satisfy that
tell was wrong** — they are described as *some property over their OWN clock, on a curve this
engine's keyframes cannot draw*. §6b has the numbers. The half of the claim that held — that
they are "the same arithmetic open-coded", and that merging them deletes a copy of the opacity
blend — is done.

### 6b. Why `shimmer` and `exit=fade` are not keyframes — measured

Rule 1 said the migration was "mechanical". It is not, and the reasons are structural rather
than a matter of effort. All three were measured against the real machinery
(`_ft_css_kf_num_ramp`, `_ft_css_kf_compose`) rather than read off the source.

**1. A keyframe ramp is sampled on its own clock, not the animation's.** `_ft_css_kf_compose`
indexes every ramp as `phase % length`, where the length comes from `FT_CSS_KEYFRAME_DENSITY`
(24) and the stop offsets — *not* from the animation's frame count. A two-stop opacity keyframe
produces **25 samples**. The shimmer runs **30 frames** and the arrow's exit runs **12**. The
shimmer therefore wraps to the start of its ramp at phase 25 and brightens again while the
effect believes it is fading out.

**2. Keyframe ramps are piecewise linear; neither effect is.** The shimmer is a parabola
(`400·t·(len−t)/len²`), the fade is whatever `animation-timing-function` item 2 says — an
easing table from `ft_ease_table`, `ease-in-back` by default. Alpha per phase, shimmer against
the closest keyframe (`from,to { opacity: 0 } 50% { opacity: 0.30 }`):

```
phase   0    5    10   15   20   24   25   29
shimmer 0    16   26   30   26   19   16   3
keyframe0    12   25   23   10   0    0    10      ← wrapped at 25
worst divergence: 19 percentage points of opacity
```

And `exit=fade`, which holds full opacity for two thirds of its run and then drops away —
the anticipation beat that makes it read as a departure rather than a dissolve:

```
frame   0    4    7    8    9    10   11
fade    100  100  100  87   66   38   0
linear  100  84   71   67   63   59   55       ← never reaches 0 in 12 frames
```

**3. The alpha has two consumers, and a keyframe publishes none.** `FT_BIGARROW_ALPHA` is read
by the arrow's ink *and* by `_ft_bigarrow_outline_color`, so the silhouette border fades with
the arrow instead of lingering as a bright wireframe (`tests/test-bigarrow.bash` asserts it).
`_ft_css_kf_compose` returns a composed SGR for one element; there is no alpha for a second
resolution to read. Publishing one would be adding a mechanism, not deleting one.

A fourth, specific to the arrow: `exit=fade` is one *stage* of a three-stage animation
(fly → hold → exit), each with its own frame count and easing, driven through `FT_ANIM_PHASE`.
The CSS animation engine arms its own 240-frame loop on that same slot — the collision
`_ft_draw_beacon` already guards against.

**What would change the answer.** A keyframe whose ramp is sampled over the *animation's* length
rather than a fixed density, an easing applied to keyframe sampling, and a way for a keyframe to
publish its sampled value rather than only a composed SGR. All three are real features; none is
a migration.

### 6c. What `effect=pulse|blink` actually are

The table's second row is wrong too. Neither is "an opacity ramp, hand-rolled":

* **`effect=pulse`** cycles the theme's `--beacon-1/-2/-3` triple — `(phase / 4) % 3 + 1`, a
  three-stop *colour* cycle. The built-in `@keyframes pulse` it was said to duplicate ramps
  **opacity** instead. They share a name and nothing else.
* **`effect=blink`** sets `FT_BEACON_EFFECT_VISIBLE=0` for half of every lap: the beacon paints
  *nothing*, which is not the same as painting at opacity 0 (nothing to erase, and the frame
  variant's cell-by-cell skip depends on it).

Both could *become* keyframes — a colour ramp and an opacity one — but that is a behaviour
change to design, not a duplicate to delete, and it inherits problem 1 above.

**2. A routine is for geometry, and that boundary is already documented.** `bob`, `retract` and
`sheen` move *glyphs*, and `@keyframes` in this engine sample colour, weight and opacity. That
is not an oversight, it is the stated limit (`styling-model.md` §7). They stay routines named
from CSS (`animation: sheen`) until there is a transform to keyframe — and if that ever lands,
all three collapse onto keyframes and `effect=`/`exit=` can be retired together.

**3. `transition:` is not one of the above and should not be merged into them.** Everything
else animates *an element against an assumption* about what is behind it. This animates an
element against **what is actually behind it**, read back through the damage layer. That is a
different capability, not a different spelling, and §4a is the case study: the two looked like
duplicates and are not. It stays separate, and it stays the thing that gets built properly when
the span renderer makes reading the ground free.

**The migration, in order.** (a) ~~`shimmer` and `exit=fade` → `@keyframes … { opacity }`~~ —
**done as far as it goes**: one blend, two copies collapsed into `_ft_alpha_blend`. The keyframe
half is blocked on the three engine gaps in §6b. (b) `effect=pulse|blink` → the built-in `@keyframes` they
already duplicate. (c) build the span renderer. (d) with the ground free to read, revisit
whether a ground-restoring dissolve should replace `exit=fade` — §4a says the answer today is
no, and says exactly what would change it. (e) if a transform ever exists, fold the geometry
routines onto keyframes and delete `effect=` and `exit=`.

Nothing above requires `transition:` to change.

---

## 7. What we did not change, and should

**`ft_char_cols` should memoise, framework-wide.** Measured at ~60 µs a glyph against ~2 µs for a
lookup, and it is called from `ft_display_width`, `ft_display_index`, `ft_display_truncate`,
`ft_wrap` — every width scan in the toolkit. This branch memoises it *locally* in the transition
module rather than smuggling a hot-path change into a compositing prototype, but the win looks
large and general and the function is pure. Same for `ft_rgb_to_256`, which is six calls of
cube-versus-grey arithmetic per conversion and took this module's 256-mode blend from 30 ms to
11 ms once remembered.

**The span renderer would delete half of this file.** Two thirds of the kick-off cost — capturing
the ground and reading both layers back — exists **only** because the framework has no retained
cell buffer. `docs/rendering-spans.md` describes exactly the structure that would make "what is
underneath" a lookup and the parse disappear entirely, and this feature is the strongest argument
for it yet: it independently reinvented that document's data model (spans, per-row interval
resolution, style interning as blend classes) because there was no other shape that fit the budget.
If transitions are wanted properly, build the span renderer first and this becomes a small file.

**Batch the arming of several transitions.** Three notices cost three separate ground captures and
three separate `_ft_damage_fill` builds. The engine already amortises that build across a frame's
rects (`_FT_DFILL_BUILT`); a batch-arm entry point could do the same. Measured potential: the build
itself is only ~5 ms of a 50 ms capture, so this is worth perhaps 10 ms of 500 — real but small.
The bigger win is not repainting the ground three times.

**Transitions OUT are not implemented.** Only `ft_transition_in`. I first recorded the reason as
a lifecycle problem — "a control being removed has to survive until its transition ends, and
`ft_remove` tears it out of the tree immediately" — and **that was wrong**: `variant=bigarrow`
had already solved exactly that, with a fly → hold → exit → destroy stage machine that keeps the
control alive through its own exit. The real obstacle is cost, it is measured, and it is in
§4a: 228–295 ms to arm at arrow size, spent at a moment the user did not initiate. The
arithmetic is symmetric (the "top" layer would be the ground and vice versa) and would be a
small change; what it needs is a cheap way to read the ground, i.e. the span renderer.

---

## 8. Files

| | |
|---|---|
| `ft-transition.bash` | the mechanism |
| `demo/transition-demo.bash` | three easings side by side; `S` switches schedule live |
| `tests/test-transition.bash` | the gate — cells, not state |
| `tools/bench-transition.bash` | cost and the contrast curves, two sizes × two modes × two schedules |
| `tools/bench-transition-latency.bash` | the keystroke, which is the real bar |

Engine changes, all guarded so an ordinary frame is byte-identical: `ft_clip_band` in
`_ft_clip_for`; a "this control is in transition" early return in `ft_draw_one`; the same predicate
in `_ft_dfill_hit_build`; a retire hook in `ft_anim_stop`.
