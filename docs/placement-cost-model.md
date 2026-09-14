# Placement cost — the action-density model (DIRECTION)

Status: **stage 0 built; the cost model itself not yet.** Dynamic importance — the *action
density* half — now works and is pinned by tests (see "Measured facts"). What remains is the
per-cell model: the engine still prices burial as `rect area × importance`, and this document
replaces that. Written from the author's own framing; the parts that were measured say so.

## The principle

**Importance is action density.** A button is an area you click — that is a lot of action per
cell. An unfocused textfield is nearly inert; the same textfield with the caret in it is the most
important thing on the screen. So `importance` is not a static label, it is *how much action lives
in this control right now*.

And the corollary that the current engine gets wrong: **what a callout may cover is a property of
CELLS, not of rectangles.** Today every cell of a control's rect is priced identically, so a
textfield holding ten characters in a 25-wide box reads as a solid wall — which is why chips flee
to the margins and end up over the navigation.

## What to preserve, in order

Most-preserved first. Each tier is a per-cell weight; the control's `importance` multiplies it.

| tier | cell contains | note |
|---|---|---|
| 1 | high-action-density area of a control | the click target itself |
| 2 | text content | |
| 3 | decorations | borders, rules, separators |
| 4 | padding / margins — spacing *between* controls | |
| 5 | whitespace within text content | |
| 6 | empty text area inside text content | past the end of the string |
| 7 | empty area inside a control | |
| 8 | **void space — outside every control** | **weight 0. Never preserved.** |

Tier 8 already behaves correctly (only control rects are obstacles). Tiers 1–7 are the change:
today they collapse into a single flat "occupied".

## Two terms, not one

The author's rule has two levels, and they need two mechanisms.

**1. Do not obliterate a control.** *"I'd choose not to block a button as an entire control
entirely."* This is about the FRACTION of a control covered, not the cell sum: a half-covered
button is still visible and partly clickable; a fully covered one is gone. So the cost carries a
**superlinear penalty in coverage fraction**, which rises steeply as coverage approaches 100%.
Without this term, covering all of a small button can cost less than clipping a big label.

**2. If you must intrude, intrude on the cheapest cells.** That is the tier table, summed per cell.

```
cost(candidate) = Σ over covered cells [ tier(cell) × importance(control) × caretHeat(cell) ]
                + coveragePenalty(fraction of each control covered)
```

## The caret gradient

Inside a focused/editing text control the tiers are not flat — the caret radiates influence:

- **The active line is the hottest thing in the control** and is avoided above all else.
- Beyond it, weight falls off **with distance from the caret** ("where the influence of the caret
  is less").
- Within equal distance, prefer covering **empty text** (beyond the string's end) over real text,
  and **whitespace** over non-whitespace.

The state needed already exists: `FT_TEXTFIELD_CARET`, `FT_TEXTFIELD_SCROLL`,
`FT_TEXTFIELD_VSCROLL`, `FT_TEXTFIELD_MODE` (controls/ft-textfield.bash:36) give the caret's
position, the viewport offsets that map it to screen cells, and whether the field is in edit mode.

## Making it fast — NOT a summed-area table. Weighted tier rects.

This section originally proposed a screen-sized weight grid plus a summed-area table: build once
per placement, then any candidate's burial is four lookups regardless of its size, and claimed it
would be *cheaper* than the existing per-obstacle loop. **That was built, and it is wrong.**

It worked — byte-identical placements across all 120 corpus cases — and it was slower:

| | grid | obstacles | build | 230 queries | total | the existing loop |
|---|---|---|---|---|---|---|
| 62×40 | 2583 cells | 17 | 50ms | 16ms | **66ms** | **46ms** |
| 171×45 | 7912 cells | 20 | 155ms | 19ms | **174ms** | **42ms** |

Per query the table really is ~2.5× cheaper. It just never earns its build: amortising 50ms at
62×40 needs ~380 queries, and 155ms at 171×45 needs ~1550, while a placement makes ~230. In bash
an O(screen-cells) pass dwarfs 230 × O(17) rect tests. Reverted; the lesson is recorded in
`controls/ft-beacon.bash` beside `_ft_beacon_overlap` so it is not re-attempted.

**The design that fits this language: MORE RECTS, not a grid.** Per-cell weighting is a statement
about *semantics*, not about the data structure. Decompose each control into a handful of weighted
rectangles — one per tier — and keep the existing loop:

```
a bordered textfield  →  border ring (4 thin rects, tier 3)
                      +  text span                (tier 2)
                      +  whitespace runs          (tier 5)
                      +  empty tail               (tier 6)
a button              →  text span                (tier 2, × its high importance)
                      +  padding                  (tier 4, × the same importance)
```

The build stays **O(controls)**, which is what the grid failed at. The query stays a walk, which
is what the grid was trying to fix — so make the walk hierarchical: test the control's **bounding
rect first** (~17 tests, exactly today's cost) and descend into its tier rects only for the two or
three controls a candidate actually touches. That keeps the common case at today's price and pays
only where the answer is genuinely more detailed.

Order the tier rects within a control cheapest-first so an early exit is possible once a candidate
is already priced out (`_fCut` already gives the search a live cutoff).

## Stage 2 — the tier rects are BUILT, VALIDATED, and INERT

Controls now declare their own tiers through `_ft_tiers_<type>` (ft-forms.bash dispatches;
`ft_tier_ring` and `ft_tier_add` are the shared building blocks), exactly alongside
`_ft_height_<type>` and `_ft_draw_<type>`. Two controls declare so far:

| control | tiers | validated against the rendered frame |
|---|---|---|
| textfield | ring / text span / empty tail | decoration 100% border, tail **0% ink**, text 100% ink |
| label | text span + ragged tail, per row | tail **0% ink** over 90 cells; content 68% → **84.8%** ink |

Both hold the partition invariant — every cell claimed once, none invented, none dropped —
gated in `tests/test-beacon.bash` and confirmed to BITE against three deliberate sabotages
(overlapping ring, gap, spill). Build cost is **1–2ms**, O(controls), versus the weight grid's
50–155ms.

**And it changes nothing.** Buried inked cells, measured against real pty renders with the
callout suppressed, over 43 placements at three sizes:

| | 62×40 | 80×30 | 100×40 |
|---|---|---|---|
| flat | TEXT=204 | TEXT=14 | TEXT=5 |
| tiers | TEXT=204 | TEXT=14 | TEXT=5 |

### Why — measured, not reasoned

| term | cost |
|---|---|
| **burial: the entire tier delta** | **4–38** |
| one crossing | 3 000 |
| one extra turn | 12 000 |
| leader crossing the target | 20 000 |
| covering the target | 100 000 |

Burial totals 43–113 for a whole box, and the tiers move it by 4–38. Against terms worth
3 000–100 000, burial is a tie-breaker of last resort: **the tiers cannot change a placement
unless two candidates are already tied on every leader term.** Repricing what the BOX sits on
was never going to matter, because the decision is made by what the LEADER crosses.

### What follows from that

The tier information has to reach the term that actually decides. `_ft_route_score` prices every
crossing at a flat 3 000 — a leader crossing a label's ragged margin is charged exactly what one
crossing a button's text is charged. That is the opposite of what was asked for: *"I wish they
would be more willing to intersect non-content like that … the decorative border, and the empty
text areas, are exactly where we want to be … the gravest sin is intersecting with text content
INSIDE controls."*

So: **price a crossing by the tier of the cell crossed.** Keep a text crossing at exactly 3 000
so nothing that currently avoids text starts accepting it, and discount decoration and empty-tail
crossings. The change is monotone — no crossing gets dearer — but it does change which candidate
wins, so it needs the full defect corpus and the size sweep before it lands, and the cramped case
watched specifically.

Note the corpus's `XCTRL` metric counts *any* control the leader touches, which after this change
is partly the DESIRED outcome. `/tmp/xink.bash` measures the right thing instead — inked cells
buried, split TEXT / DECOR / BLANK against a real render — and should be promoted into `tests/`
alongside it. Its one known blind spot: it reads a space as blank regardless of BACKGROUND
COLOUR, so a painted strip like the keylegend (which fills its whole width) reads as empty when
it is really chrome.

### Where the remaining mispricing is

Blank cells still priced at full content weight, and the buried text they correspond to, at 62×40:

| control | blank at full price | importance | buried text cells |
|---|---|---|---|
| keylegend | 115 | 200 | 0 |
| label | *(now tiered)* | 30 | **129** |
| table | — | 60 | 52 |
| statusbar | 23 | 200 | 0 |
| checkbox | 2 | 120 | 17 |
| button | 12 | 200 | 2 |
| textfield | **0** | 60 | 4 |

The two columns disagree, and the right-hand one is the one that matters: the keylegend has the
most mispriced blank space and causes no harm at all, while labels and the table are where the
damage is. Instrumenting by harm rather than by mispricing inverted the priority — the table is
the next hook worth writing, not the keylegend.

## Stage 3 — it was never the cost model. It was the CANDIDATES.

Two repricings in a row changed nothing measurable. That is itself a result, and it pointed
somewhere else: if what you charge makes no difference, the search may not be choosing between
the right things at all. So instead of a third weight, the question became **what could the
engine have picked?**

For every placement, slide a box of exactly the size the engine chose over every position on the
screen and take the least ink any position buries. Ignoring the leader entirely, so it is an
optimistic bound — but if the engine already matches it, no cost model can help:

|  | box-only buried text, 43 placements at 62×40 |
|---|---|
| the engine's choice | **190 cells** |
| best any position could do | **8 cells** |

And the damage is not spread out. **34 of 43 placements bury exactly zero**; nine bury the lot.
Seven of those nine are page 4.

### The picture that settled it

Rendering the worst case with the box drawn over the frame shows a 7×40 callout sitting squarely
on the page's prose while blank space sits to its right. The search's own `FT_BEACON_DEBUG`
shortlist shows why, and it is not the scorer: **every candidate offered buried at least as much**
— the twelve positions on offer were at three distinct columns. Meanwhile a dense sweep of the
engine's OWN four shapes found, for the narrowest, a position burying **nothing at all**.

The candidate was never generated. `ft_free_regions` reports MAXIMAL EMPTY rectangles, and the
minimum size it is asked for is the narrowest shape's own size — so the 14-column margin holding
the only zero-burial position for a 16-column box was filtered out before any shape could look at
it. No free region admitted ANY of the four shapes, the search fell back to its sparse
target-adjacent lattice, and the good position was simply not among the things being scored.

### The fix, and what it really cost

A region may now be a little too small (`_OVERHANG`), and the existing clamp — which pushes a box
until its edge meets the region's — turns that into a box overhanging by exactly that much. The
budget has to be applied in BOTH places: relaxing only the per-shape fit test did nothing at all,
because the region had already been filtered out of the list before any shape could look at it.
Same predicate, every path.

An overhanging box is the one region candidate that no longer buries nothing by construction, so
it pays for what it covers, charged after the distance cutoff so pruned candidates pay for no scan.

**The budget was swept, not chosen** — and the first value tried (4) turned out to be the worst of
the five, which is the whole argument for sweeping:

| `_OVERHANG` | buried TEXT | weighted burial | JOG | BENDS | XCTRL |
|---|---|---|---|---|---|
| 0 (before) | 204 | 244 | 59 | **0** | 393 |
| **1 — kept** | **190** | **176** | **59** | **0** | 406 |
| 4 — rejected | 163 | 159 | 95 | **9** | 403 |

`_OVERHANG=4` buries the least text of any setting and is still the wrong answer: it lifts JOG by
61% and takes BENDS off zero, where it had been pinned by a long earlier effort. A callout
covering two more blank cells is invisible; a wandering leader is not. `_OVERHANG=1` takes the
part of the win that costs nothing — buried text down 7%, weighted burial down 28%, decoration
crossings halved (59 → 30), JOG and BENDS both untouched, and every one of the 34 already-perfect
placements still perfect.

A caution about the harness: a 6-size corpus said `1` improved XCTRL (88 → 86); the full 28-size
corpus says it costs 13 (393 → 406). The small corpus is fine for ranking settings and not fine
for reporting one.

### What is still on the table

The zero-burial position on p4.s4 is still not reached — it needs an overhang of 2, which costs
more in leader quality than it returns. The real limit is narrower than "overhang": within a
region the box is placed adjacent to the target and slid only ±1/±2, so a region 22 columns wide
effectively offers one column. Sweeping a shape ACROSS the region it was given adds positions that
bury nothing by construction (no overlap scan needed, so nearly free), and unlike the overhang it
cannot trade burial against bends, because every position it adds is already inside the region.
That is the next thing to try.

Note also that the "best any position could do" bound above ignores the leader entirely, so the
gap it reports is an upper bound on what is recoverable, not a target. Part of what it counts is
positions whose leader would be unacceptable.

## Stage 4 — the rescue sweep: the generator that can finally see the tiers

Stage 3 ended with a correction that mattered: the "unreachable optimum" at p4.s4 was outside
the callout's boundBox the whole time (the `FREE bounds=` debug line is what caught it — kept
for exactly this). But recomputing the optimum WITHIN legal bounds barely moved it: a legal
position with weighted burial **15** existed against the engine's **35**, sitting on the `call`
paragraph's ragged right margin. That is cheap-tier space INSIDE a control — which no free
region can ever contain (regions exclude whole controls) and the fallback lattice never samples.
The tiers had a price for it since stage 2; nothing could generate a candidate on it.

So: a **rescue sweep**, the one generator that asks `_ft_beacon_overlap` directly. Gated on the
judged winner's own burial (`_RESCUE_AT`, default 4 normal-equivalent cells — the measured
distribution splits 0 vs 6..60, so the gate separates them with margin and the clean placements
never pay a single scan). It strides the boundBox per shape (`_RESCUE_SCAN` budget, stride
widens to fit), keeps the best six by the judge's own dominant terms, and hands them to the SAME
judge — extracted as `_ft_beacon_judge_finalists`, with the standing winner left as the bound,
so a rescue wins only by beating the incumbent on the full score, real routed leader included.
On p4.s4 it found (9,17) — the dense sweep's exact weighted optimum for that shape.

Its staircases then took BENDS off zero (exit and head on the SAME row, one control mid-run, no
even exit offset able to express the one-row shift), so the exit-exploration ladder gained
`1 -1` — tried first, gated to staircase leaders (`turns > 2`) because for a plain crossing a
one-cell shift almost never clears the control and measured +100ms paying for it anyway.

### The ledger, full 28-size corpus + 62×40 burial

| | JOG | BENDS | XCTRL | weighted burial | buried TEXT |
|---|---|---|---|---|---|
| baseline (pre-overhang) | 59 | 0 | 393 | 244 | 204 |
| + `_OVERHANG=1` | 59 | 0 | 406 | 176 | 190 |
| + rescue | 79 | 7 | 376 | 83 | 73 |
| + ±1 exits (**final**) | **100** | **0** | **364** | **83** | **73** |

Buried text down **64%**, weighted burial down **66%**, crossings at their session best, zero
multi-bend leaders, 36 of 43 placements burying nothing and every remaining offender on the
dense page 4. The honest cost: JOG 59 → 100 — staircases and rescued placements now thread past
controls with a single one-cell dogleg instead of sitting on paragraphs. That is the deliberate
trade, and reverting the ±1 exits is one line if the doglegs read badly in practice (it buys
back JOG=79 at the price of BENDS=7).

Latency: ~50ms on the 36 clean placements (the gate); ~240ms where the rescue fires, against
the 573ms this whole effort started from. `tests/test-burial.bash` pins TEXT ≤ 85 and
ANYTXT ≤ 17 so the level is protected; the pins carry their own re-pinning instructions.

### Lessons that transfer

- **When two repricings in a row change nothing, stop repricing.** The candidate set, not the
  cost model, was the limit — and the instrument that settled it was "what could the engine
  have picked", not another weight.
- **Check the constraint set before trusting an optimum.** The first "recoverable gap" was
  computed over positions the engine is forbidden to use.
- **pty gates lie under load.** test-render/test-notrace produced false failures three separate
  times when run concurrently with other pty work; both passed solo every time. Never conclude
  from a contended run.

## Stage 5 — the leader contract, in the user's words

Three rulings from live use, each traced to a mechanism and priced in the ONE comparator
(`FT_POLY_PRICE`, and `FT_LEADER_SCORE` where the judge reads it):

| ruling | mechanism found | change |
|---|---|---|
| "the line must never enter the arrowhead from the side" | the approach shrank to ONE cell to dodge whatever sat above the target, putting the last corner against the head | approach floor = `_MIN_LEADER`; `FT_POLY_AXIS_OK` also fails a final segment < 2 cells after a turn |
| "it should have come out the left side and looped" (p2:2, dragged, anchor=topLeft) | the diagonal bend's closing leg was drawn UNROUTED through the target; interior Z candidates burned the scan before the first outward one; through-target cells priced like any crossing (clean loop 21 024 vs through-target 21 023 — lost by one) | closing leg crossing-checked → approach back to head offset + wide scan; `FT_POLY_CROSSES_TARGET × (_XTGT_COST − _CROSS_COST)` in `FT_POLY_PRICE` |
| jogs ("drunk lines") | counted by the corpus for months, never priced | a 1-cell segment between two turns costs `_EXTRA_TURN_COST` |
| "p2:3 — the line should have routed around the control" (dragged below an anchor=topCenter target: straight up through "Nine po\|nts") | with collinear endpoints the router's "rows" Z family degenerates into the straight line and consumed half the scan; the first clean column was the 9th outward, beyond reach | `ft_route` drops the degenerate family; `_LEADER_SCAN_WIDE` 16 → 32; a first route through the target/own box triggers the wide re-route, kept only when cheaper (36 033 vs 60 009) |
| "p2:2 — the arrow line completely disappeared" (parked one free row above the target) | the padded head landed on the box's own border ⇒ HEADIN; a zero-length leader was ALSO treated as HEADIN, so line and head were both suppressed | zero padding retry for named anchors; a zero-length leader draws its head alone in the free row |
| "Those latencies are insane" — css-demo page 1, step 3, a 1 256ms settle (and a render golden timing out at step 2) | `STG place-candidates / place-judge / place-final-leader` under FT_BURST_LOG: the judge was spending 429ms exploring eight alternative exits and running wide re-routes on each of twelve finalists — lines it would never draw | **judge cheap, draw expensive**: `_FT_LEADER_JUDGING` turns exploration and the wide recoveries off while scoring; the winner's draw runs them all. Judge 429 → 231ms, settle 1 256 → 637ms — and the corpus IMPROVED: 434 → 427 defects, JOG 24 → 19, XCTRL 423 → 418, BENDS 0, burial/text identical. Judging on the first route favours boxes whose natural line is already clean |
| "page 2 step 2 — pure nonsense" (dragged straight below its target: the line ran up THROUGH the callout's own box) | two places derived the exit from the anchor's side instead of the head's position relative to the box (the aligned branch, and again in the exit exploration); the exploration's through-box candidate beat the clean loop on price because crossing one's own box cost a plain 3 000 a cell | facing-edge rule in both places; `FT_POLY_CROSSES_BOX` priced like `FT_POLY_CROSSES_TARGET`. Found only by capturing the pty app's stderr — the in-process probe had different geometry and "worked" |
| "p4:3 / p5:3 — the arrowhead doesn't connect to the callout… why doesn't it just crook upwards" (box directly above the head's row; p5:3 needs no drag) | NOT a placement defect: the winner was `poly=[13 52 13 49]` — exit one row under the box, `dp` a row further out, the route straight back, simplified to a bare `───` running PARALLEL to the edge. A perpendicular stem only ever looked attached because `│` happened to touch `─` | purely in the DRAW: the line starts ON the border with a T-junction (┬ ┴ ├ ┤), a one-cell stub and a real corner when it turns — `◀──╯` hanging from `┬`; the number badge and ▶ keep their cells. Contract, price, cache, corpus and erase footprint untouched; pinned by three shape cases in `test-dragleader` |

## Stage 6 — "not locked to the form frame" (2026-08-22): two bounds, and what the margin taught

The user hit the home frame as a wall while dragging. Opening it is one line; opening it SAFELY
took five root fixes, two reversals, and the same corpus before and after.

| step | what the measurement said | what stayed |
|---|---|---|
| bound = the screen for everything | the two reasons for the cage were obsolete (repair is the compositor's; the margin is now priced) — and at 62×40 buried TEXT went 93 → 57. But the rescue sweep's stride re-anchored at the screen origin shifted 4 of 43 placements (p4.s2 became a wide box over the prose with a zero-length leader: TEXT 116, burial gate FAILED), and at 56–68 columns **211 of 1 204 placements parked half in the 4-column margin**, across the frame's `║`, chopping the first letters off a field, a table and a slider row to save a few cells of prose | **reverted.** Two bounds, because they are two questions: the placer SEARCHES the home frame (boundBox, else nearest bordered ancestor, else the screen); the drag may PARK anywhere on screen. Auto placements byte-identical to before at 62×33, 62×40, 80×30, 120×40 (one leader at 84×34 leaves its box two rows higher) |
| a bordered container's ring as four obstacle strips + a decoration tier (`_ft_tiers_frame/form/div/tabs/box`) | before, a frame's `═` was neither obstacle nor tier — covering or crossing it cost NOTHING, which is the real reason the cage existed | kept: a dragged callout's leader now pays for the ring it crosses, inner bordered panes are priced like a field's box |
| the frame ring at 20× content (`FT_TIER_FRAME`) | stopped the straddling — and pushed css-demo page 1 at 80×30 off the code panes' top border onto a worse spot (an inner container's ring IS a good place to sit) | **reverted** once the search bound went back to the frame: no auto placement can straddle its home ring; a drag may |
| per-rect crossing weight (`_RT_CROSS`, hundredths; `FT_POLY_CROSSINGS`/`FT_LEADER_CROSSINGS` in hundredths, `/100` in the two prices) | with rings in the list at a uniform price, four cells along the `═` (12 000) lost to two cells through "Back" and the step counter (6 000) | kept — carried by obstacle push/pop HELPERS that replaced ~10 hand-rolled blocks, several of which left `_RT_N` one short |
| a head on another control's text priced like target cover (`LDR_HEADCOVER`) | its motivating case (css p1 s1 @80×30, head inside "inher▲ts") was cured by the two-bound design alone (flip point: cost 0); above ~10 000 it turned page 1's "…and ▲one of them" — the head on a caption's inter-word space, the demo's gag — into a three-turn leader from the right | **removed.** The head cell is already a crossed cell of whatever it sits on |
| the router compares candidates in the judge's currency (`FT_ROUTE_PRICE`: ink crossings dominant, ring cells at the decoration rate, a bend = a turn; "blocked" = ink crossed, `FT_ROUTE_HARD`) | the router dodged three ring cells (4 050 to the judge) with two bends (12 000 to the judge), and the judge then threw that line away for one through two buttons — crossings 10 000 : bends 8 was the router's own currency. A prefilter must price what the judge prices | kept; placements unchanged at five sizes, `test-route` 20/20 |
| every cell scored once (segments after the first are half-open) | a bend cell was counted by both segments that meet there; a corner on the `═` paid 1 350 more than the line it was compared with, and the left exit lost by 738 | kept: the dragged leader now runs along the frame's bottom edge into the box's left side (`╚═══╰───┤`), pinned in `test-dragleader` |
| the diagonal closing-leg "dirty" test | the leg ends on the head cell, which sits on the caption and is a crossing every candidate pays alike — every closing leg read as dirty and the wide recovery fired | keyed on ink crossed (`FT_ROUTE_HARD`) minus the head cell's own |
| the home frame's four strips in every placed callout's list | latency: page 4's judge 1 829 → 2 152ms, its final leader 383 → 507ms — four full-width rects in the hottest loops (18 rects instead of 14) for a ring no placed leader can reach (every candidate parks inside it) | the search and a placed draw exclude the home frame (`_ft_route_obstacles "$bb"`); a dragged, uncaged callout's draw keeps the strips — that is the one leader that can cross them |

After all of it: burial TEXT 93 / DECOR 41 (identical), corpus 427 defects in 1 204 (identical),
0 placements on a ring, 0 outside the frame; demo gate 167/167, test-callout 312/312,
test-route 32/32 (ring strips, lockstep arrays, once-per-cell pinned), test-dragleader 18/18
(the drag out of the frame pinned).

## Stage 7 — two things the search was doing to itself (2026-08-22, found by a debt sweep)

Neither is a weight. Both were found by asking a fleet of readers "what here is dead, duplicated,
or contradicts its own comment", and then verifying each claim with a probe before touching it.

**The allocator's own answer was never judged.** The region loop marked `_fSeen[t,l,sw]` and then
called `_cand`, whose FIRST statement rejects a key already in `_fSeen`. So every primary
free-region candidate — the box placed exactly where the allocator says there is room — was
generated, cheap-scored and silently dropped; measured at 62×40 page 1 step 1: **8 offered, 0 in
the shortlist**, all 12 finalists coming from the ±1/±2 slides and the target-adjacent fallbacks.
The pre-check was there to skip the corridor scan on a re-offered position, which is worth
keeping; the pre-MARK is what poisoned it. Check here, mark in `_cand`.
Measured after: corpus 427 → **426** defects, buried TEXT 93 → **91**, JOG 19 → 26, XCTRL 418 →
421, both placement gates green — a wash on quality — and latency the same or better (page 1's
judge 255 → **205ms**, because judging the aligned position early sets a tighter prune bound).
Kept for the correctness, not the numbers: a candidate that is generated must be judgeable.

**The winner's leader was routed twice.** The placement path called `_ft_beacon_leader` for the
winner and used exactly one field of the result (`place`); the draw then rebuilt the obstacle list
and routed the whole thing again, because nothing had populated the leader cache. Probe: **two
draw-mode routes per placement, byte-identical polys**. Worse, the placement's call ran BEFORE the
boundBox clamp, so it described a box the clamp could still move. Now it runs after the clamp and
stores into `FT_BEACON_LDRKEY`/`LDRC`, which the draw reads.
This also closes a real drift: the search's obstacle list includes other overlays' published ink
and the draw's did not, so on a multi-beacon page the two disagreed and the DRAW won. Page 6 at
62×33 changes because of it — the old head landed ON the ringed Box B's halo, which composites
afterwards and paints over it (the defect `_ft_beacon_rect`'s "a ringed control's boundary is its
ring" note describes); the leader now routes around and points at the ring's outer edge.
Judge 1 703 → **1 628ms** on page 4, plus a whole route per placement gone from the untimed draw.

**The four sides became two.** `_ft_beacon_leader_once`'s `case "$FT_LEADER_SIDE"` had four arms;
above/below and left/right are mirrors differing only by a sign and by which edge they fall back
to. That is the shape of every bug this function has produced — the facing-edge rule shipped wrong
in two arms because it was fixed in one — so the sign is now `_step` (-1 toward top/left, +1
toward bottom/right) and the fallback is a named `_fac_*` edge: THE EDGE FACING THE TARGET, which
is what each arm's `else` silently was (`above` fell through to the bottom edge, `below` to the
top, and neither said so). It is reached when the head sits inside the box's own row/column span,
where "the edge facing the head" has no answer. 112 lines → 76.
Proved equivalent rather than assumed: a differential probe loaded the pre-merge function under a
second name and compared every `LDR_*` output over **576 geometries** (9 anchors × a box swept all
around the target — aligned, diagonal, overlapping its span, clamped to the screen edges) —
**0 mismatches**; placements byte-identical at four sizes.
That grid is now a permanent gate, `tests/test-leader-table.bash`, which records the contract's
answer for all 640 rows and diffs against `tests/leader-table.txt` (`--accept` to re-record). Its
teeth are checked: flipping the vertical fallback edge, or one sign in the horizontal arm, fails it.

**And it earned its keep on the first run.** `centerCenter` was added to the grid because it is the
one anchor with its OWN code path (an early return pointing into the target's middle) — nine
anchors pinned and the separately-written tenth unguarded would have been the wrong trade. Two
defects fell out immediately:

| found | what was wrong | fix |
|---|---|---|
| the table's own invariant ("no row puts an undeclared arrowhead inside its own box") failed on 6 of 64 centerCenter geometries | `FT_LEADER_HEAD_INSIDE_BOX=0` was set unconditionally in that branch, reasoning that centerCenter's head belongs inside the TARGET — true, and beside the point: the field means "swallowed by its own BOX". Drag a centerCenter callout over the thing it points at and the draw paints an arrow glyph in the middle of its own text with no line to it | the same predicate every other anchor uses. Auto placement is unaffected (it prices covering its target at `_TARGET_COVER_COST`), so this is a drag-only path — which is why nothing had ever caught it |
| — | a `ft_route "$_ap_r" "$_ap_c" "$_ap_r" "$_ap_c"` routing the approach cell TO ITSELF, with the box pushed as an obstacle and the answer sent to `/dev/null`: a scan per centerCenter leader that could not affect anything, since the polyline is built from the explicit waypoints | removed, with its obstacle push/pop |

Corpus after both: **424** defects, JOG 24, XCTRL 421, BENDS 0, RING 0, OUT 0 — unmoved, as a
drag-only fix should be.

**"Cells of this polyline inside this rect" was written three times.** Twice in
`_ft_beacon_poly_stats` (`FT_POLY_CROSSES_TARGET` against the target, `FT_POLY_CROSSES_BOX` against the callout's own box)
and once in the leader contract (`FT_LEADER_CROSSES_TARGET`) — the third in a different idiom, clamping the span
and testing, where the others computed the overlap and tested. They agreed; nothing made them,
and each guards a price of `_XTGT_COST` a cell. One `_ft_beacon_poly_in_rect` now.
The finder that surfaced it filed it under HOT-PATH efficiency, and that part was wrong: counting
calls first (the standing rule) put `_ft_beacon_poly_stats` at **40 calls per placement** on the
demo's heaviest page, against **480** for `_ft_route_score` and **403** for `_ft_beacon_overlap`.
So this is written for one definition, not for speed, and the comment says so — otherwise the next
reader "optimises" a function that was never the cost. The leader table gained an `xtgt=` column
in the same change, because it is the one value these three copies produced that every other
column in the table could not see.

**The drag ghost had two painters.** `_ft_beacon_paint_callout` reaches the ghost from two places
— a fast path that skips the placement prelude when a placement is cached, and a fall-through for
a grab with no cache (a resize mid-drag drops it) — and each carried its own copy of the ring,
identical line for line except for the names of the four box coordinates. Same shape as the four
side arms: a fix to the ghost would land on one drag and not the other. One `_ft_beacon_paint_ghost`
now, called from both; `tests/test-beacon.bash` compares the CELLS the two paths emit (plus the
extent, the box, and that a ghost owns no leader and no ▶) rather than merely that each ran.

Full corpus after all three: **JOG 118 → 24, BENDS 0**, XCTRL 348 → 424 (a clean-but-crossing
line now beats a jog, as ruled), weighted burial 83 → 99, buried TEXT 73 → 93 of which the
+16 is leader stems through label text (box-buried text 73 → 77). The burial gate was re-pinned
85 → 105 with that reason in its ledger.

## Stage 8 (2026-09-07) — the search is fast enough; it is on the wrong side of the keystroke

Reported as "the callout demo is still really sluggish; tutorial-demo feels SIGNIFICANTLY
snappier." Measured, callout-demo page 4 at 118×40, one step press settled exactly as `ft-run`
settles it:

```
as shipped                                  690–790 ms per press
_ft_beacon_paint_callout stubbed out         47.8 ms per press     ← 93% of the press
tutorial-demo (no overlays, no beacons)      65 ms per Tab
```

**The demo is exonerated, and this is the measurement that does it.** Rewriting the step handler
the "clean" way — `ft-modify stepcallout target=X` instead of `ft_remove` + rebuild — is **not
cheaper** (171k–893k µs). Any app that moves a tooltip, coach-mark or onboarding callout pays
this, because the search runs inside `_ft_beacon_paint_callout`, inside `ft_draw_one`, inside
the settle for one keystroke. `ft_draw_one`'s own comment prices that re-derivation at 6 ms; on
a dense page it is two orders of magnitude out.

**The placement cache cannot help.** Its key carries the target rect *and* the text, and a step
change alters both, so every press legitimately misses.

**Shrinking the shortlist is not the lever, and the numbers say so.** 12 → 2 finalists saves
**17%** (760 → 632 ms) and **moves 20 of the 50 placements** in the demo. The cost is generating
and cheap-scoring the ~1000 candidates that arrive *before* the shortlist is consulted; the
finalists are what turn a shortlist into a good answer. Do not reach for `_FINALISTS`.

**Nothing could see a placement move until now.** `tests/test-callout.bash` (312 assertions) and
`tests/test-burial.bash` stayed fully green through every pool size above — they assert
PROPERTIES (on screen, not buried, leader leaves the facing edge) and a box can move a long way
without violating one. `tests/placement-table.txt` was written for this: 75 geometries, a scene
stated in the test rather than taken from a demo, accepted deliberately with `--accept`. Any
change to the search is now visible.

### What the fix has to be, and the obstacle in it

Take the search off the keystroke: paint from the cached placement (or a cheap first-fit from
`ft_free_regions`), schedule the full search, repaint when it lands.

The obstacle, found by reading rather than by trying it: **deferral needs a pump, and
`ft_anim_step` is the only one — it runs only when a poll loop exists.** Every callout test
drives paints directly with no loop, so a naive "defer to an idle tick" makes the callout never
appear, in tests and in any app that is not animating.

The shape that works:

- arm a **one-shot animation** on the beacon — which itself sets `FT_ANIM_ACTIVE`, so the run
  loop is guaranteed to poll and the tick is guaranteed to fire;
- have the tick call `ft_beacon_place` (the existing public, synchronous full search) and dirty
  the beacon;
- keep `ft_beacon_place` synchronous, so anything needing an answer *now* still gets one;
- drain pending searches in the harness `settle`, so headless tests stay synchronous and the
  ~600 existing callout assertions are unaffected.

Paint **nothing** for a beacon whose placement is not yet known, rather than its previous
placement: on a step change the old placement points at the old target, so drawing it is wrong,
and a callout appearing one tick later reads as an animation where a jump reads as a bug.

Gate: `tests/placement-table.txt` must be **unchanged** — the final placement is the same answer,
only later — plus a press-cost assertion against the 47.8 ms floor, with an anti-vacuity
companion that the callout was actually painted (`FT_BEACON_PC[…]` non-empty), or "fast" is
satisfied by drawing nothing.

### BUILT (2026-09-08), and simpler than the plan above

A cache miss inside a running app records the key it missed on in `FT_BEACON_PENDING` and paints
nothing for that beacon. `ft_next_event` pays the debt — `ft_beacon_drain_placements` — before it
blocks for input.

```
one press:  settle 606 ms, then the page          →  settle 121 ms, page, then 459 ms
four held:  4 × 606 = 2424 ms                     →  155 ms + one 566 ms drain = 722 ms
```

Time to the page the user asked for: **5×**. A held key: **3.4× less work**, because the table is
keyed by name and a burst leaves one debt per beacon rather than one per press. The **total is
unchanged** (580 vs 606 ms), and that is the honest half — bash is single-threaded and moving
work does not remove it. What changes is that the page is already on screen while the search runs.

**Neither the animation nor the harness drain was needed**, and both were in the plan because the
pump was mis-identified. `ft_anim_step` is not the only pump: `ft_next_event` is called by every
loop the framework has, and it is called *because* the loop wants its next event — so a tick is
guaranteed without arming anything. And `FT_RUN_ACTIVE` is a better gate than a drain: with no
loop, the search happens in place, so a headless caller never enters the deferred path at all
rather than being rescued out of it afterwards.

**In `ft_next_event`, not in `ft-run`'s loop.** Written in `ft-run` first, which was wrong:
`ft-run`'s is one of four — Help, Settings and the file dialog each run their own — so a callout
raised inside a modal owed a search nobody paid. Paying **before** the read is also a correctness
property rather than a preference: a deferred callout has no box yet and `_ft_beacon_hit_at`
answers from the box, so no click is ever tested against a placement that is about to change.

`tests/test-callout-defer.bash` (26 assertions) pins the deferred answer as identical to the
synchronous one, that the fixture really misses the cache the first time and hits it the second,
that `ft_beacon_place` still answers now, that a drag never defers, and that a beacon removed
mid-debt is dropped quietly. `tests/placement-table.txt` is unchanged, and a pty run of
callout-demo page 4 shows the same five callout-box rows after one press, two, and four held as
it does on arrival.

**What is NOT fixed: the search still costs 459 ms.** The next lever is the staging below, not
another deferral.

## Staging — one measurable step at a time

Each step ends with the 120-placement diff (`/tmp/capdiff.bash` pattern: dump the winning
placement for every page/step/size and compare), so every change's effect is visible.

1. ~~**Refactor only** — grid + summed-area table.~~ **DONE, and the answer was no.** Built,
   verified byte-identical across all 120, measured slower, reverted (see above). What survives
   from it and is now in the code: burial sums in **importance units and divides once**, where it
   used to divide per obstacle and truncate a `minor` control's single covered cell to zero. That
   change was verified byte-identical on the corpus too, and it is what makes any per-cell model
   representable at all. Next structural step is the hierarchical tier rects described above.
2. **Void space and emptiness.** Introduce tiers 7–8. Expect chips to start using empty regions
   inside controls; check the crossings and button-coverage counters move the right way.
3. **Tiers 2–6.** Text, decorations, padding, whitespace.
4. **Coverage penalty.** Tune only against the "don't obliterate" cases.
5. **Caret heat.** Last, because it needs the focused-control case in the demo to exercise it.

## Measured facts to build on

- **31–37% of what the placer calls "occupied" is blank**, counted against real painted glyphs on
  the rendered screen (callout demo at 62×40: page 1 → 811 cells of obstacle, 507 with ink, 37%
  blank; page 4 → 848 / 580, 31% blank). Two earlier attempts at this number were wrong — one used
  a `value`/`text` proxy that cannot see what a table, keylegend or slider draws, and one measured
  page-4 pixels inside page-1 rectangles because sourcing the demo runs `PAGE=${DEMO_PAGE:-1}` and
  clobbers a page set before it. Measure ink from the rendered screen, and set PAGE *after* the
  source.
- **Class-level importance resolves correctly** — a button is 200 (`crucial`) by class default.
- **SETTLED, AND NOW BUILT: a stylesheet rule DOES drive importance per state**, so the dynamic
  half needed no new API. Two bugs were in the way, both silent:
  1. **`importance` was a class default on `ft_control`** — and a class default is an
     instance-level write, which outranks every stylesheet rule exactly as inline style does. So
     `textfield:focus { importance: crucial }` was a no-op and no state could ever change a
     control's importance. Nothing failed; it just quietly never worked. The `normal` fallback
     lives at the READ now (`_ft_control_importance` passes it to the resolver), which gives the
     same answer when nothing styles a control and lets the cascade speak when something does.
  2. **`_ft_control_importance` asked `ft_resolved_prop`, which does not consult the stylesheet.** Even a
     working sheet never reached the placer. It asks `ft_style` now — once per obstacle when the
     obstacle list is built (~17 controls per placement), not per candidate.

  Measured across a focus toggle, end to end into the placer: **30 (minor) → 200 (crucial) → 30**,
  with a button's class default still resolving 200. Pinned by four assertions in
  `tests/test-beacon.bash`, checked for teeth: restoring *either* bug turns exactly those three
  state assertions red.

  `importance` is also now registered as a **paint**-kind property (it was falling through to
  `layout`, which would have made every importance change trigger a needless relayout).

## `push_importance` / `pop_importance`

**The cascade is the primary mechanism, and it now works** (see above) — a state-keyed rule is
declarative, self-restoring, needs no stack, and the theme already hangs per-tier colours off the
same importance scale. `textfield:focus { importance: crucial }` is the whole feature.

Push/pop remains worth building as the **escape hatch** for conditions that are not states — a
long-running operation, an app-specific mode — as a thin imperative API over the same property.
It is no longer on the critical path.

## Open

- Should a focused textfield's *empty* area be protected? Argument for: that is where the caret is
  about to go. The caret gradient probably answers this by itself.
- Does a control's padding inherit that control's importance, or count as generic spacing (tier
  4)? A button's padding is part of its click target, which argues for inheriting.
- The author's steer on both: *"whatever is more efficient and coherent — but borne out in
  reality."* Decide by measurement, not by argument.
