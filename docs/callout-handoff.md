# Callout placement — where this stands

## The architecture (2026-08-13): allocator-first, one leader contract

The user's directive, verbatim requirements, all now implemented and measured:

> "There should be a system that reports all the rectangular regions it knows about that are not
> 'claimed' yet.. like a memory allocator. The callout should figure out whether it can fit itself
> in such a region outright, and do so, and if not … position itself where the space is most
> accommodating with a minimal of intersection … avoiding particularly the thing it's pointing at.
> Arrows should always connect with a straight orthogonal line away from one of the 4 borders of
> the callout … never cross over the callout itself … really hard not to cut across any controls …
> definitely not across the target (unless the screen is so small there is literally no choice).
> At the end of the line it must always connect to the arrowhead, and the arrowhead must always
> point to the control instance specified. Minimal turns. No band-aids. All auto. Must pass the test."

- **`ft_free_regions T L B R [minW minH]`** (ft-forms.bash, engine level) — the maximal empty
  rectangles inside the bounds, from the same obstacle list the router uses. Band decomposition ×
  downward intersection; `tests/test-freespace.bash` pins SOUND (no reported cell touches an
  obstacle) and COMPLETE (no empty cell missed, any fitting box is findable).
- **`_ft_beacon_leader`** (controls/ft-beacon.bash) — THE one definition of the leader a given box
  gets: side from largest clearance; head at the target edge pulled toward the box (so it slides
  along the target); exit slides along the facing edge toward the head, one cell clear of corners;
  a DEPARTURE cell forces the first segment perpendicular to the border; an APPROACH cell forces
  arrival along the arrowhead's axis; box and target are both obstacles; `ft_route_simplify`
  drops non-bends; `FT_LEADER_HEAD_INSIDE_BOX` reports a head swallowed by its own box. The placement search
  scores candidates BY CALLING THIS, so chosen and painted cannot diverge.
- **Placement** = shortlist of ~8 finalists from (free regions × 4 box shapes × alignments/slides
  + 4 target-adjacent fallbacks), judged on the real routed leader. Shapes matter: the text
  rewraps narrower→taller, and a slim box takes a margin column no wide one could.

## THE STRUCTURAL LESSON: the cheap filter must price what the judge prices

The recurring failure mode of this search, found three separate times by shortlist dumps:
**a two-stage search where the prefilter ranks by different terms than the judge quietly vetoes
the judge.** The finalists were picked by distance while the judge scored crossings (3000/cell)
and turns (3000 each) — so every slot filled with near-but-jogging candidates and the judge never
saw the clean straight one two rows further out. Fixed by making `_cand`'s cheap score estimate
the judge's own dominant terms, in the judge's own constants:

- straight-corridor crossings → `_CROSS_COST` (a rect scan, no routing)
- forced-Z misalignment → `2 × _TURN_COST` — whether a straight leader is even possible is pure
  geometry: the exit must be able to reach the head's column/row within the box's inner span
- short-leader shortfall → `_SHORT_LEADER_COST` (exact for the straight case)
- distance/narrowness → tie-breakers (×20, edge-separation not centre-to-centre; rows ×3)

Measured effect of the misalignment term alone: p6 s2 @118 went from a 2-turn jog (score 6365,
chosen) to a straight `◀────────` len 9 (score 849) that the filter had been discarding.

## Verified-by-measurement rules the test now encodes (tests/test-callout.bash)

Every leniency is EARNED by a measurement made with the same allocator the placer uses:

- **LENGTH** ≥ `_MIN_LEADER`, OR a short leader that is CLEAN AND STRAIGHT (≤1 turn, 0 crossings —
  the box tucked beside a hemmed target with a stub `▲` is what a person draws), OR the screen has
  no reachable room at all.
- **TURNS** ≤ 2 where a clean straight-reachable region exists; ≤ 4 where none does (the
  brute-forced optimum over EVERY zero-burial box position at 95×34 is exactly 4 turns).
- **REACHABLE** means: a free region fits box+leader, lines up with the target's span on the
  matching axis, AND the straight corridor from it to the target crosses nothing. "A big region
  exists in the far corner" earns no strictness — at 95×34 a region fits and aligns to the right
  of `inhColor` and every line from it still crosses the Bold checkbox.
- AXIS (head entered along its own axis, derived from the TARGET), NO-REVERSAL, and the
  chrome budget (keylegend/statusbar) as before.

Current: **260/260** default, **650/650** full sweep:

```bash
FT_CALLOUT_SIZES="80 30|95 34|120 40|170 50|171 45" bash tests/test-callout.bash
```

## Measured state of the demo (probes, since deleted — rebuild from git if needed)

- Crossing census (every page/step at 80/118/136/170): was 30/104 leaders crossing (99 cells),
  after the corridor-aware prefilter **17/104 (57 cells)**, and after the misalignment term the
  named user cases (p3 s2, p3 s3, p6 s2, p8 s2 at roomy sizes) are straight or one-turn clean.
- The residual crossings are measured least-bads: 80×30 (largest free rect 80×3 vs a 6-row box),
  and `p1 s3` at ≤118 (inhColor hemmed on all four sides: label left, Bold right, specimen above,
  step-nav below — judge table shows the 1-turn-with-2-cell-brush beats everything else).
- Brute-force ground truth (`_probe-simple` pattern): grid-scan every zero-burial box position,
  evaluate with the REAL leader contract, compare best-achievable to chosen. This is what proved
  "5 of 6 two-turn leaders had a 0-turn placement available" (prefilter bug) and later "at 95×34
  nothing better exists" (earned leniency). **This probe is the arbiter for any future dispute
  between the test's strictness and the placer's output.**

## Performance (measured, ft_now_ms → FT_RET — it does NOT echo; $(ft_now_ms) reads empty)

- `ft_route` built ~200 candidate strings before scoring any ("one scoring pass" was false);
  generation now follows the early exit: **106ms → ~10ms** per routed leader.
- `_ft_beacon_leader` bounds the detour hunt (`FT_ROUTE_MAX_SCAN=24` inside the contract): a
  leader that needs a 20-row escape is a bad PLACEMENT and should score badly, not be rescued.
- `ft_free_regions` hoists per-band runs (was O(bands²) rebuilds): ~39ms → ~20ms; region lists
  are requested with min sizes so undersized regions die during enumeration.
- One full placement + composite: **963ms → ~210ms**. Still cached per PKEY; per-frame composite
  untouched.

## Weights (controls/ft-beacon.bash, env-overridable)

| term | value | why |
|---|---|---|
| burial (box over control) | 1000/cell | never cover content to prettify a line |
| `_TARGET_COVER_COST` | 100000/cell | covering the TARGET is a contradiction; also charged when the head lands inside the box |
| `_CROSS_COST` | 3000/cell | same harm as burial, same unit; swept over the demo (table in git history) |
| `_TURN_COST` | 3000 | a bend ≈ a crossed cell; swept — below this the 4-turn detour beat rewrapping |
| `_SHORT_LEADER_COST` | 3000/missing cell | stub pressure, exact for straight leaders |
| `_NARROW_BIAS` | 300 | tie-break toward the wide readable shape (was 3000 — dominated everything and pushed boxes far away to stay wide) |
| `_PLACE_BIAS` | 24000 | explicit `place=` honoured in BOTH the prefilter and the judge (it must bias the shortlist too, or free space starves the preferred side) |
| distance | (rowsep×3 + colsep)×20 | EDGE separation; centre-to-centre punished side placements beside wide targets |

## Environment gotchas that cost real time

- Run probes through a SCRIPT FILE — `wsl.exe … bash -c '…$var…'` strips variables/loops; heredocs
  written via `bash -c` mangle `$c` too. Bit again twice this session.
- `_resize` after setting FT_COLS/FT_ROWS, or every "size" tests the same 120×30 layout.
- After editing via the Windows path: `chown drussell:drussell`, `chmod +x` for new tests.
- Demo copies must live inside the tree (BASH_SOURCE-derived root).
- Don't run other suites while `run-all` is going — pty tests fail spuriously under load
  (test-notrace did exactly this; passed 6/6 standalone).

## Two bounds (2026-08-22): the placer searches the home frame, the drag parks anywhere

`boundBox=CONTROL` is the author's cage and answers both questions. Without it the placer
SEARCHES the nearest bordered ancestor's interior (the screen for a frameless app) and the drag
may PARK anywhere on screen (`FT_BEACON_BOUND` is the park bound). Searching the screen was built
and measured — see docs/placement-cost-model.md stage 6 — and lost: 17% of cramped-size
placements ended up half in the margin. What made the drag safe: a bordered container's ring is
now four obstacle strips (decoration tier, `_RT_CROSS` at the decoration rate), the router
compares candidates in the judge's currency (`FT_ROUTE_PRICE`/`FT_ROUTE_HARD`), and every cell is
scored once. The obstacle list is SEVEN arrays in lockstep — grow and shrink it only through
`_ft_obstacle_push` / `_ft_obstacle_pop` / `_ft_obstacles_clear`.

## Where a parked callout lives, and how to send it home

A drag PARKS a callout, and the park is two ordinary properties — `parkedTop` and `parkedLeft`.
Both unset means "never parked, place me automatically". Being properties rather than an engine
table is deliberate: `ft-state` saves and restores them with everything else, `ft_set` can
move a chip from app code, and a probe can read where a chip sits without reaching into this
file's private tables.

```bash
ft_set note parkedTop=4 parkedLeft=9   # park it exactly there
ft_beacon_unpark note                     # forget it; the placer chooses again
ft_beacon_side  note                      # → above|below|left|right, where it actually went
```

`ft_beacon_unpark` exists because "put it back" means removing BOTH properties, and knowing
that is not something an API should make a caller rediscover. Before it, demo/callout-demo.bash
unset `FT_BEACON_DRAG[…]` — a table this engine replaced with these properties and which has
not existed since — so the demo's advertised `R` key was inert while three separate places in
that file told the reader it worked. Its own test asserted on the same dead table and passed.

## The flight recorder: a user report is replayable from BYTES, not screenshots

`demo/callout-demo.bash` records every frame it ships to `FT_RECORD` (default
`/tmp/callout-last.rec`; `ft_flush` appends, `ft_term_size` writes `SIZE cols rows` to
`.meta`). The previous run is kept as `.prev` / `.prev.meta`. Replay with

    tools/rec-frame.py /tmp/callout-last.rec                 # the final frame, size from .meta
    tools/rec-frame.py … --pages                             # where each page's "(N/7)" was painted
    tools/rec-frame.py … --before-page 5                     # the last frame on the page before 5
    tools/rec-frame.py … --at 123456                         # after the first N bytes

Two things that cost a recording on 2026-08-21: (1) **every pty probe and gate launches the
demo, and the launch truncates the recording** — `tests/render-screen.py` now passes
`FT_RECORD=""` to the child unless the caller sets one, and `.prev` survives one stray launch,
but COPY THE FILE ASIDE before touching anything; (2) under damage narrowing the constant
title prefix is never repainted, so grep for the `(N/7)` counter or the step text, not the title.

## FIXED 2026-08-15: placement latency, 573ms -> 305ms per step change

The regression was real and it was ALL in the placement search — the stage repaint the demo
blames in its own comment is still ~75ms. What made it hard to see: the placement runs inside
`ft_draw_one` for the beacon, so timing `_ft_composite_overlays` afterwards measures a WARM
cache (17ms) and makes the redraw look guilty. Attribute `ft_redraw_dirty` by control type and
the beacon is 565ms of it.

Measured at 171x45 over all ten pages x every step, uninstrumented:

| | before | after |
|---|---|---|
| step change (as felt) | 573ms | **305ms** |
| one cold placement | 387ms | **153ms** |
| routed leaders per placement | 13 | 3 |

Four changes, each verified to leave the ANSWER alone by dumping the winning placement for all
120 page/step/size combinations and diffing:

1. **A REAL BUG, not a tuning knob.** The single shared region list asked `ft_free_regions` for
   the minimum size of the WIDEST shape, so every region narrower than the full-width box was
   dropped — including both margin columns, which is exactly the space a slim rewrap exists to
   use. At 95x34 page 4 the search was left with nothing but placements burying 45+ cells and
   returned a zero-length leader. The minimum is now the smallest box ANY shape could need
   (narrowest width, shortest height). This also fixed the last sweep failure.
2. **Bound the judge.** Every term after the cheap score is non-negative, so the partial score is
   an exact lower bound: a finalist that already exceeds the best complete answer cannot win and
   is never routed. Routing is ~7ms; the arithmetic above it is not. 13 routed leaders -> 3.
3. **Publish the cutoff (`_fCut`) and bound the generator with it.** Once the shortlist is full
   its last entry is the price of admission. Tested at three points — per REGION (the nearest
   box centre a region can produce bounds every candidate in it; prunes 61%), per position, and
   per slide group (all four slides score `_base + burial + 4`, so `_base + 4` bounds them).
   The dedupe moved to the top of `_cand` for the same reason: a hash lookup before the scans.
4. **`_ft_beacon_overlap`, the hottest loop in the framework** (~9000 executions per placement).
   One `(( ))` with four comparisons for the reject (most rects miss), the clipped area computed
   only for rects that overlap, and a counted loop instead of re-expanding `"${!_PT[@]}"` on
   every call. 275ms -> 167ms per step.

`_REGION_CAP` 14 -> 10 is MEASURED, not chosen: caps 14/10/8/6/4 were dumped across all 120
placements; 10 answers identically to 14 and costs 39ms less, 8 changes two and 4 changes eleven.

One placement did change, and it is an improvement the bound exposed: 95x34 p4 s1 moved from the
right margin to the left, which the judge scores 723 against 740 — the old shortlist never
contained the better box.

Things that did NOT move it, recorded so they are not retried: hoisting the eight per-candidate
`local` declarations out of the loop (247ms vs 233ms, inside the noise), and the earlier list —
bounding Z-sweep generation, direct-arithmetic clamping, trimming finalists 16->8, per-shape
region lists. Measurement noise on this probe is about +/-20ms, so nothing under ~30ms is a
result. The search is now ~120 candidate evaluations and ~500 loop iterations per placement;
what remains is bash's per-iteration cost, not an algorithmic surplus.

## The anchor API: nine points, `auto` is the middle of a side

`anchor=` names WHICH POINT of the target the arrowhead lands on — `topLeft topCenter topRight
centerLeft centerCenter centerRight bottomLeft bottomCenter bottomRight`, or `auto` (the default).
`auto` resolves to the middle of whichever side the box ended up on, never a corner: a leader
meets the edge it faces, square on, at its midpoint.

**`centerCenter` is the only anchor allowed to cross the target.** Every other value names a point
on the boundary and the head stops clear of it (`arrowPadding` blank cells plus the glyph: one row
above/below, two columns left/right). For `centerCenter` the target is deliberately NOT an
obstacle for that leader — the box still is.

Proven twice over: `tests/test-beacon.bash` asserts the contract at the API (each anchor's head
lands on exactly the named point, and no anchor but `centerCenter` is inside the target), and
`tests/test-callout-demo.bash` asserts the same nine on a real page.

**Placement is `auto` in all real code.** The only `place=` in the tree outside tests is
`demo/callout-demo.bash` page 3, the page whose subject IS `place=`; `demo/css-demo.bash` passes
`place="${PA_PLACE[$i]}"` which its 2-argument `_ann` form always fills with `auto`.

## Fixed 2026-08-15 (small-screen pass) — four mispricings the wide screen hid

The user reviewed the teaching demo at ~84x34 and it fell apart: chips over the frame border,
leaders straight through their own target, four-turn wanders, arrowheads with no line. None of it
showed at 171x45. Reproduced with `/tmp/cdiag.bash COLS ROWS`, which walks every page and step and
flags XTGT (leader crosses its own target), CHROME, BORDER and SIDE.

**1. `boundBox` defaulted to the SCREEN, so nothing kept a chip inside its own container.** The
property exists precisely so a callout cannot spill past a border it can never be erased behind —
and then defaulted to the whole terminal. On a cramped screen the only "free" space is the margin
OUTSIDE the frame, which is not free at all: it is the frame's border column. Measured on the
demo at 84x34: **43 of 43 steps landed on a frame border**, and the ones squeezed into the margin
had no room left for a leader, so the arrowhead ended up jammed between box and target with no
line — the "arrowhead is where the line should be" report. The default is now the nearest
ancestor whose `_ft_border` is 1, screen if there is none. 43 -> 0.

Note the predicate is `_ft_border`, NOT `type == frame`: a borderless frame draws no ring, and
keying on the type reports false positives (it cost me one wrong diagnosis).

**2. A leader crossing THE TARGET was priced like crossing any other control.** The brief for this
system says "definitely not across the target (unless the screen is so small there is literally no
choice)", and at `_CROSS_COST` that was simply not true: `anchor=centerLeft` at 84x34 put the chip
in the RIGHT margin and ran **30 cells of line straight through the target** to reach its left
edge, because 30 crossings beat the burial every left-hand alternative paid. `FT_LEADER_CROSSES_TARGET` now counts
the polyline's cells inside the target rect and `_XTGT_COST` prices them at four buried cells
each. centerCenter is exempt — it names the middle, so its line ends inside by design.

**3. BENDS WERE PRICED LINEARLY, so a wandering line was cheap.** This is the one that had been
reported twice in the user's own words ("crazy routing", "the callout seems to be drunk") and
survived both times. css-demo p1 s4 at 80x30, from the judge's own table:

| candidate | leader | burial | judged |
|---|---|---|---|
| box=16,61 | 0 turns, 0 crossings, len 1 | 3 cells | 21681 |
| box=17,2 | **4 turns, 0 crossings, len 30** | none | **13250 — chosen** |

Three buried cells outranked four bends and thirty cells of line. One bend is an elbow and two is
a dog-leg — both read as a line that knows where it is going; beyond that it reads as wandering,
and the third bend is not "a bit more of the same". `_EXTRA_TURN_COST` charges each turn past the
second at four buried cells. The same pair now scores 21681 against 37250 and the clean one wins.

**4. A named anchor now implies a side for the BOX**, at `_PLACE_BIAS` strength: an arrow into the
middle of the left edge comes from the left, and a chip on the right has to cross the whole target
to arrive facing back at it. Still a bias, so a side with genuinely no room is overruled, and an
explicit `place=` still wins.

Sweep after all four, six sizes including the user's: **780/780**.

```bash
FT_CALLOUT_SIZES="80 30|84 34|95 34|120 40|170 50|171 45" bash tests/test-callout.bash
```

### …and three more the demo's variants page shook out

**5. Another overlay's ink was invisible to the search.** A `variant=frame` halo is painted
OUTSIDE any layout box — which is exactly why every beacon publishes `FT_BEACON_EXTENT` — so the
obstacle walk, which reads the layout tree, could not see a cell of it. Those extents are now
obstacles for a callout's placement (its own excluded).

**6. …and a RINGED TARGET's boundary is its ring.** With a halo round the very control a callout
points at, the anchor put the arrowhead on the target's own edge — which is the halo's border —
and the halo, composited afterwards, painted over it. The leader then arrived at a cell with no
arrow on it, which is precisely the "is that a bug or a feature" confusion a decorated page
produces. `_ft_beacon_rect` now grows the pointed-at rect to include any overlay drawn around the
target, so the head stops outside the ring. Page 6 step 2 at 84x34 went from a swallowed head to
a visible `◀────` at the ring's edge.

**7. `_NARROW_BIAS` per column — TRIED, MEASURED, REVERTED.** Worth recording as a dead end
because it looks obviously right. A flat fee cannot tell "one rung narrower" from "a third of the
width", and on the variants page a 16-column chip breaking `frameStyle=dashed` mid-word scored 744
against 3242 for a clean 42-column chip below the target. Pricing the penalty per column
surrendered fixed that — and pushed FOUR cells of leader through controls elsewhere, because the
narrow rungs exist to reach margins, wide shapes need room a cramped screen does not have, and the
leaders then go through whatever is in the way. Measured on css-demo at 118x40, cells of leader
crossing a control over all 24 steps:

| narrow penalty | crossed cells | chips under 24 cols @84x34 |
|---|---|---|
| **flat 600 (kept)** | **0** | 19 |
| per-column, 40 | 4 | 25 |
| per-column, 80 | 4 | 25 |
| per-column, 120 | 4 | 19 |

**Both suites stayed green at every one of those values**, which is exactly why it nearly shipped:
the readability metric I calibrated against did not count crossings, and no assertion forbids them
— they are traded, not banned. The failure was caught only by rendering the page and looking at
it, where the arrowhead had landed inside a label (`inher`+arrow+`ts`) and the line ran through
"Crimson". Instrument the term you are trading AGAINST, not just the one you are trying to
improve; a green suite is not evidence when the suite has no opinion about the thing you broke.

### The one knob that is NOT free: `_SHORT_LEADER_COST`

There is a real tension between two things the system wants, and it is worth writing down so the
next person does not rediscover it by tuning. The TEST accepts a short leader when it is clean and
straight ("≤1 turn, 0 crossings — what a person draws when a target is hemmed in"); the SCORE
charges 3000 per missing cell for exactly that shape. That charge is what pushes a readable
42-column chip aside for a 16-column one whose words break mid-token. Swept:

| cost | css-demo | callout-demo | chips under 24 cols @84x34 | @80x30 |
|---|---|---|---|---|
| **3000** | **936/936** | **152/152** | 23/43 | 26 |
| 1800 | 934/936 | 152/152 | 22/43 | 25 |
| 1000 | 933/936 | 152/152 | 15/43 | 25 |
| 500 | 933/936 | 152/152 | 15/43 | 25 |

Cheapening it buys real readability — 23 narrow chips down to 15 — and costs assertions that
encode a standing user requirement ("a callout without a line is a callout that points at
nothing"). 3000 is the only value where everything is green, so 3000 it stays. If the narrow-chip
count is ever the priority, this is the knob, and the price is listed above; do not move it
without re-reading which assertions fail and deciding they are wrong.

Note the readability count moved 19 -> 23 when the ringed-target fix (#6) landed, because a bigger
pointed-at rect shortens the leader a below-placement gets. That is correctness bought with
cosmetics, in that direction on purpose: a swallowed arrowhead is a bug, a narrow chip is ugly.

## `importance=` — one weight replacing a pile of special cases

The user's diagnosis was right: burial was counted in CELLS, uniformly, so every "never cover
THAT" requirement had to arrive as its own mechanism — a hard-coded `keylegend|statusbar` exemption
in the test with a magic budget of 112, a separate `_TARGET_COVER_COST`, a separate border
assertion, a separate chrome rule in the demo. Each was a patch over the same missing idea: a cell
of a button and a cell of a paragraph are not the same loss.

`importance` is now a control property on `ft_control`, using the framework's EXISTING scale —
A binding's `keyImp=` has taken an importance all along ("a raw 0-255 weight, or one of the
anchor KEYWORDS", modelled on CSS `font-weight: bold | 700`). Same keywords, same constants, one
resolver (`_ft_importance`) shared by both, so a key legend and a callout cannot disagree about
what "important" is worth. `FT_IMPORTANCE_MINOR` (30) was added below the three existing anchors
for content whose whole job is to be READ: a paragraph reads around an obstruction, a button does
not work around one.

Prototype defaults: button / checkbox / select / slider `important`, keylegend / statusbar `crucial`,
textfield and table `normal` (inherited), label `minor`. Any instance or stylesheet overrides it
like any other property.

`_ft_route_obstacles` now carries `_RT_I` beside the rects, and `_ft_beacon_overlap` returns
NORMAL-EQUIVALENT cells (`cells x importance / normal`), so `_BURY_COST` keeps its meaning and its
calibration. Measured over every step of the callout demo:

| | before | after |
|---|---|---|
| 84x34, cells covered | chips over buttons | **4, all label — 0 buttons, 0 checkboxes** |
| 80x30, cells covered | 212 (140 of them buttons) | 164 (73 buttons) |

80x30 stays imperfect because at that size no arrangement clears both the prose above and the nav
below on all 43 steps — but the search now spends its coverage on prose, which is the trade asked
for.

**The one trap, and it is the FT_RET clobber again.** `_ft_importance` returns through FT_RET, and
prototype constructors declare their key bindings in tables interleaved with other FT_RET-returning
calls — so calling it while folding a key group without restoring FT_RET silently corrupted whatever
the caller had in flight. The scrollbar's arrow bindings stopped dispatching entirely
(test-scrollbar 29/33, test-dispatch 44/47) while every importance VALUE was perfectly correct.
Borrow FT_RET and give it back; never duplicate the keyword table to dodge it.

## No line means no arrow either

When the screen leaves the chip hard against its target, the exit cell IS the arrowhead cell: the
polyline collapses to a point and what got painted was an arrow glyph wedged between two borders,
pointing at nothing, with no line behind it. The user's instruction: "I expect no line or arrow in
that case until the callout itself is clear enough to even draw them coherently."

`FT_LEADER_HEAD_INSIDE_BOX` already identified exactly this condition (head swallowed by its own box, or zero
length). The draw now paints neither the polyline nor the head, and publishes an empty
`FT_BEACON_LEADER`. Both suites treat a leaderless chip as a valid placement and assert instead
that it really is ADJACENT — the arithmetic is exact, not a fudge: the head sits `arrowPadding`
plus its own glyph clear (two columns), the exit one cell off the box, so the line collapses at a
horizontal gap of 2 and a vertical gap of 1. Further away than that, a leaderless chip points at
nothing and is still a failure.

## Fixed 2026-08-17 (exit-selection pass) — the drunk-line family, killed at its root

The user's terminal is ~62 columns; every earlier verification grid stopped at 72. A dense sweep
(52-74 cols x 30-44 rows, every page/step — /tmp/corpus.bash) found the whole family at once.
Four layered causes, each found by decoding one reproduced polyline, each fixed where it lives:

**1. An ALIGNED head got exactly one exit** — the facing-edge cell level with the arrowhead —
while the diagonal branch has always tried two. With a neighbour sitting in that one corridor,
ft_route dodged it in place: one cell up, along the obstacle, one cell down. Four turns, 1-cell
segments — the reported bracket (p6.s2, dodging Box A [21,23..21,29]) and hook (p7.s5, dodging
boundChk) are byte-for-byte the single-exit route (verified by replay). Now, when the picked line
is dirty (crossing or >2 turns), other exits along the same facing edge are routed for real and
the cheapest wins; the hunt stops at the first clean line. 68x38 p6.s2: 4-turn bracket -> 2-turn Z.

**2. Candidate polylines were compared LEXICOGRAPHICALLY** (crossings, then turns, then length) —
no notion of magnitude, so a zero-crossing forty-cell wrap with four bends outranked a three-cell
line brushing one cell. The judge's arithmetic prices that wrap 12x worse and never got a say: the
contract had already thrown the good line away. `FT_POLY_PRICE` (computed in _ft_beacon_poly_stats, the
judge's own leader terms, axis violation priced at 1e6) is now the ONE comparator everywhere.

**3. The diagonal bend clamped to the edge's MIDDLE** (`_ft_beacon_edge_point`'s fallback — right
for a plain facing exit, where mid-edge reads deliberate; wrong for a bend-through). At 62x42 an
anchored centerRight head below the box got its bend column clamped to the target's own centre
column, the approach cell landed INSIDE the target, the honest drop became unroutable, and the
wrap won by default. Bends now clamp to the NEAREST END of the span.

**4. The alternative exit's EDGE was hardcoded** to the nominal side (side=left => always the
right edge). With an anchor-forced side and the box parked elsewhere — above the target, spanning
its full width, which is what narrow screens produce — the hardcoded edge was the FAR one, and the
clamp from #3 could collapse the bend onto the head's own column (approach leg of zero, axis
violated, priced at 1e6), leaving the wrap as the only candidate. The alternative now exits by
whichever edge the APPROACH CELL lies on. 56x40 p2.s5: 38-cell wrap -> `10 15 10 14 18 14 18 17`,
out the left edge, down, bend into the head.

Measured, every page/step at 56-68 cols x 34-42 rows (1204 placements): leaders with >2 turns
went from dozens (40-cell wraps included) to **2**, both 6-cell jogs where a sibling control abuts
the arrowhead cell and every approach on that row is walled (the mechanism agent proved no exit on
that edge can do better; the fix there would be anchor/placement-level). Zero orphans. The
remaining flags are 1-4-cell crossings on genuinely packed layouts and 1-cell FINAL legs — priced,
least-bad, not wanders.

Also fixed in this pass, from the same audit:
- **Ring overlays are obstacles only during the placement search, not at draw time** (a cached
  placement's leader can be painted through one). Recorded as OPEN; low harm since rings
  composite above.

## Fixed 2026-08-17: a ring beacon inflating to the TEXT CALLOUT's size

User report, correct on both counts: "the callout highlight on box a is huge... seems to be the
same size as the text callout, meaning SERIOUS bug." The ringed-target rule in `_ft_beacon_rect`
("a ringed control's boundary is its ring") grew the pointed-at rect by ANY overlapping overlay
extent — and a callout CHIP parked over the control qualified. The ring beacon around Box A then
drew itself around box-A-union-chip: rows of `┃` wrapping the text callout, with the callout's own
leader dying against it with no arrowhead. Mere overlap does not make an overlay part of a
control's edge; being drawn AROUND it as its ring does. The growth now requires variant=frame AND
the overlay's own target to BE this control. p6.s2 at 62x40: giant bracket ring -> normal one-cell
halo, leader `────▶` straight into Box B's dashed ring.

Batch frame capture for review: `bash tools/capture-frame.bash callout-demo p3:2,5 p6:2,5 p7:5`
writes every requested page:step frame to /tmp/frame.txt at the invoking tty's size.

## Fixed 2026-08-17 (fourth round): styled drag ghost, anchor rescue, honest promises

**`:dragging` is a real state.** `ft_state :dragging '[dragging=true]'` (global, generic — anything
draggable can set it). The beacon's grab sets `dragging=true`, release removes it, and the drag
ghost resolves its border through the CASCADE via `_ft_border_glyphs`: beacon prototype defaults say
`borderStyle=dashed borderRadius=1`, so the ghost is a dashed rounded outline restylable with
`beacon:dragging { borderStyle: double }` or an instance `borderStyle=`. The chip's own border
stays its hardcoded rounded look and does not consult these — the defaults exist for the ghost.

Caught in flight by tests/test-notrace.bash, worth remembering: `borderRadius=true` FAILS the
numeric-prop validation (legal: 0 square, >=1 rounded — 'true' is tolerated only at the frame's
read site), and the write-time error printed on every step change, leaking literal text like
`rRadius="tru` onto the pty screen. Both the notrace and render "failures" were that one leak.
A prototype default is a WRITE and goes through validation; the resolver's leniency does not.

**The degenerate anchor gets a second chance.** When anchor=auto produces no drawable line (zero
length or swallowed head — FT_LEADER_HEAD_INSIDE_BOX), `_ft_beacon_leader` is now a wrapper over
`_ft_beacon_leader_once` that retries the other three side-midpoints through the full contract
and keeps the first CLEAN line (<=2 turns, 0 crossings, nothing through the target). The
reported case: p4.s2 at 56x40, chip overlapping the button's row range — previously leaderless,
now `[12 34 12 30 15 30]`: off the chip's left edge, one turn down, arrowhead onto the button's
topCenter — the user's own sketch. A NAMED anchor stays suppressed rather than second-guessed;
nothing clean -> the honest suppression stands. The p4.s2 leaderless band (56-58 cols) is empty.

**Page 3 promises are hedged and overrules name both sides** (demo work): every side-naming step
says "space permitting", and an overrule reads "place=left asks for the left side, space
permitting — not enough room here, so it went above instead." The old refusal to name the
achieved side (the text->size->placement->side->text cycle) is solved BY CONSTRUCTION: every
wording a step can show wraps to the same line count at every rung of the shape ladder, asserted
with the engine's own ft_wrap, plus an empirical convergence gate (each step placed twice,
byte-identical). Page 1's stage is start-justified in line mode (fixes a pre-existing 80x30
mis-placement the agent proved predated its edits).

## Fixed 2026-08-17 (third round): border-hugging leaders, and the drag at ~10x

**The hug (p1.s3, "no turn coming out into a parallel line").** When the arrowhead lands exactly
one cell past a box edge (head col == boxR+1), the diagonal L's cross-leg is ZERO cells and the
whole leader is a vertical run one cell outside the border, overlapping the box's rows — on
screen a doubled border (`||`). By raw numbers that degenerate line was a PERFECT leader
(straight, 0 crossings, len 3 — priced 3, unbeatable), because nothing priced the adjacency.
`FT_LEADER_HUG` now counts cells of any segment running parallel to and directly against a box edge
while overlapping that edge's span, priced at a turn per cell in `_ft_beacon_score_leader`. The
same shortlist then picks the box ONE COLUMN OVER, whose head clears the edge and draws a real L
(p1.s3 at 62x40: `15 48 15 49 18 49`). Corpus effect beyond the reported case: >2-turn leaders
went 2 -> 0 and crossings 478 -> 368 over 1204 small-size placements — degenerate-adjacent heads
were distorting placements everywhere.

**The drag, 400ms -> ~40ms a frame (~25fps).** Three changes, each measured in the run loop's
own burst protocol (grab, three coalesced moves, settle — /tmp/dragsim.bash pattern):

1. **A grabbed callout drags as a GHOST**: border ring + badge, ~12 paint calls against ~200 for
   the full chip, and no leader — which also skips rebuilding the obstacle table every move. The
   user suggested exactly this. Release paints the real thing.
2. **Ring-complement damage**: the old ghost's long top/bottom rows are immediately repainted by
   the new ring one step over; filling them anyway cost a hit-test-per-run walk of ~41 columns
   twice a move (~18ms per fill). Only the ring cells the new ring does NOT cover are damaged —
   the two verticals (the far one lands INSIDE the hollow ghost, where nothing repaints), plus
   the row complements on a same-row move.
3. **One tree walk enlists ALL damage rects** (`_ft_damage_enlist`): the per-rect walk cost
   a full recursion per rect, 128 calls and ~86ms a settle. Same skip semantics, one walk.
   Plus: `_ft_damage_fill`'s column-cut list is built once per redraw pass (it is a property of
   the tree, not of the rect), and exact-duplicate damage rects are skipped per frame.

Journey: 400 (bounding-box refills) -> 90 (draw-what-was-drawn) -> 70 (single walk) -> ~40
(ghost + ring complements). What remains is enlisted-leaf repaints (a control under the ring
repaints whole) — the documented damage-compositor direction, not a bash hot path.

## Fixed 2026-08-17 (second drag round): the "insane" lag was the DAMAGE, not the paint

User: "the lag on dragging callouts is totally insane, like 50x higher than it should be." All
the earlier probes said ~90ms a move — because they drove the handler directly, one paint per
move. The run loop batches moves into COALESCED BURSTS, and replaying that exact protocol
headlessly (grab, three moves under FT_COALESCING=1, settle) measured **~400ms per settle**.
Profiling inside the settle: `_ft_damage_fill` 1862ms of a 2100ms drag, `_ft_damage_dirty` 600ms
in 841 tree recursions.

The cause: the per-move damage subtracted the new BOX from the old EXTENT — and the extent is
box ∪ leader as one bounding rect, mostly BLANK cells for a chip whose line runs to its target.
Every move re-damaged the leader's whole ~160-cell band; three moves a burst re-damaged it three
times; the fill is per-cell. Two fixes:

1. **Damage what was DRAWN**: the strip of box a move uncovers, plus the old leader's one-cell
   -wide segments, plus the head — never an extent bounding box. (First move still takes the
   whole old BOX: the reshape changes dims, so no subtraction is sound.)
2. **`ft_redraw_dirty` dedupes exact-duplicate damage rects per frame** — a burst reports the
   same old leader every event, and re-filling already-ground cells tripled the frame.

Measured in the same burst protocol: settle 400ms -> 70-120ms steady-state (~11fps with
latest-position coalescing — the pre-regression cadence, without the pre-regression smear).
All gates green after (residue/notrace/render/stale + all three callout suites + run-all).

Probe worth keeping: tests/render-screen.py now accepts `MOUSE:b;c;r;M` key tokens — one SGR
mouse event, the only way to drive a real drag through the real loop. And the measurement
lesson, again: the pty harness's own per-step pump costs ~0.4s, so wall-clock deltas through it
measure the HARNESS — instrument inside the app (dump on mouse RELEASE; the harness SIGKILLs
the child, so an EXIT trap never fires).

`tools/capture-frame.bash` renders batch entries (`p3:5 p6:2,5`) IN PARALLEL — each frame boots
the real app in its own pty and waits out keyboard negotiation (~4s), so serial batches took
~14s a frame and read as broken. Four frames now take ~14s total.

## The drag: the smear was HALF A FRAME, painted under coalescing

The run loop wraps every dispatch in FT_COALESCING=1, and ft_redraw_dirty defers under it — so
the drag handler's "repair, composite, flush" degenerated mid-burst into "composite, flush": the
chip painted at each new position, the vacated cells were NEVER repaired until the burst drained,
and the settle cleaned up only when the mouse paused. That is the reported "duplicates of the
border smearing the screen for a while, and then the ability to drag again", verbatim.

Now: under coalescing the handler only records the position and accumulates the vacated damage —
the burst's settle paints ONCE with the latest position, which also collapses an event backlog
into one frame instead of painting every stale one. Two supporting engine fixes: (a)
ft_redraw_dirty's pure-damage path (repair enlisted no controls) now recomposites overlays
touching the repaired region before flushing — previously it shipped the half-erased frame; (b)
FT_DAMAGE_NARROW is held for the drag's lifetime by grab/release rather than toggled per move.
The exit exploration is skipped while a beacon is mid-drag (transient frames; release does a full
refresh): 90ms/move, 2 controls repainted.

## Dragging a callout: 266ms -> 83ms per mouse-move

The drag was unusable and the cause was not the placement search — that path already skips it.
`_ft_beacon_mouse_drag` called `ft_refresh`, which re-lays the whole tree, CLEARS THE SCREEN and
repaints every control: 28 of them, 266ms, for a box that moved one cell. Nothing about the
layout changes when an overlay moves; a callout's layout box is zero-size.

Two changes, measured at each step:

1. **Damage instead of refresh, and only the cells actually vacated.** The chip is about to paint
   over the cells it still covers, so what is stale is the old extent MINUS the new box — a
   one-cell strip for a slow drag. On its own this did nothing (245ms still inside
   `ft_redraw_dirty`, 28 controls), which is the useful part of the measurement.
2. **The real cost: a damage rect that touches a container enlists its ENTIRE SUBTREE.** A 2x2
   rect in the middle of the demo's stage enlisted twenty-six controls, because `stage` is a
   borderless `div` spanning the screen. The existing skips covered "fills a background" and
   "frame, damage interior-only" — every plain `div` fell through. A container that neither fills
   nor draws a border paints NOTHING, so damage inside it has nothing of its to restore.

Result: 83ms per move, 2 controls drawn.

**`FT_DAMAGE_NARROW` is opt-in, and that is deliberate.** Enabled globally the second change is a
strict improvement in theory and a regression in practice, because narrowing the repair stops
covering for footprints that are UNDER-DECLARED elsewhere. It exposed exactly that:

> **OPEN — an overlay's removal does not erase what it painted.** `_ft_destroy_beacon` unsets
> `FT_BEACON_EXTENT`, which is the only record of an overlay's footprint (its layout box is
> zero-size, which is why the extent is published at all). css-demo's dashed ghost outline is
> placed on step 2 and removed on step 3, and with narrowed damage it leaves five cells of `─`
> behind at 95x34 (`tests/test-residue.bash` catches it). Damaging the extent inside
> `_ft_destroy_beacon` is the obvious fix and it did NOT work — residue stayed and `test-notrace`
> broke — so the ordering there needs understanding before it is touched again.

So the narrowing is held for the length of one drag rather than set globally: during a drag a
stray cell is transient (the next full repaint clears it), where residue after a step change is
permanent. The step-change path keeps its proven behaviour. Fix the under-declared footprints
first, then turn the flag on globally and delete this paragraph — it is worth roughly 3x on every
damage-repair path, not just dragging.

### Reported by the demo agent, CHECKED and not reproduced

"The shortlist and the judge disagree about what side means." I read all three derivations —
`_cand`, the generator, and `_ft_beacon_leader`'s auto branch — and they use the same rule
(largest clearance) over the same values in the same tie order, and `place=` never sets
`FT_LEADER_SIDE`. I could not construct a divergence. Left recorded rather than claimed fixed: if it
resurfaces, the fix is to factor the derivation into one helper all three call, which is worth
doing anyway.

Two other reports, both correct and both narrower than they look:
- `_ft_border` returns 0 for a textfield that draws `┌──┐`. True, but a textfield's whole rect is
  already an obstacle, so a chip landing on it is priced as burial; only a CONTAINER's border was
  invisible, and that is what the fix above addressed. It is a gap in the test's border assertion,
  not in the placer.
- The shape ladder's rungs (`maxw, ⅔, ½, ⅓`) are coarse enough that one `calloutWidth` must serve
  a short-wide band and a thin-tall one. Real, unfixed.

### What was NOT changed, and why

`FT_ROUTE_MAX_SCAN=6` inside the leader stays. It is deliberate: a leader needing a wide detour is
not cleverly routed, it is badly PLACED, and rescuing it in the router hides that from the search.
With crossings of the target now priced, such placements lose whenever an alternative exists.

The residual ugliness at 84x34 is the DEMO's layout, not the placer's judgement, and the shortlist
dump says so plainly: on the anchor page there is **no free rectangle above the target at all** —
the stacked code panes fill every row — so a `topCenter` anchor has nowhere to put its chip and
every candidate is bad. The engine is right when the layout gives it room: at 171x45 all nine
anchors draw 0 turns, 0 crossings, len 4. A page that teaches the nine compass points has to leave
a chip-sized band on all four sides of its target at every size it claims to support.

## Fixed 2026-08-15 (anchor pass), and what is still OPEN

Found by building the teaching demo, which exercises anchors the css-demo never does.

**Fixed — `anchor` was missing from the placement cache key.** `pkey` covered place, padding,
target rect, drag, screen size, width and text, but not anchor: `ft_set c anchor=topRight`
alone reused the box chosen for the OLD anchor while the end-of-paint leader recomputed the head
from the new one. The arrow moved, the box did not, and the box had been optimised for a
different arrow. Only a callout that also changed its text hid it.

**Fixed — the cheap filter was anchor-blind, and that was the four-turn corner bug.** A named
anchor FIXES the side (`_ft_beacon_anchor_point` hands the leader its side straight from the
anchor); `_cand` and the generator derived their own from box-vs-target clearance. The two then
disagreed exactly on the candidates a named anchor exists to produce — `anchor=topLeft` was
scored on a far-margin box's "left" clearance while the real leader comes DOWN from above, so the
shortlist filled with boxes the judge then paid four turns to connect. The forced side now flows
through all three paths. Measured on the demo's anchor page:

| | before | after |
|---|---|---|
| 171x45, all nine anchors | centerLeft/centerRight 1 turn len 10, topRight 4 turns | **all 0 turns, 0 crossings, len 4** |
| 80x30, topRight | 4 turns | 1 turn |
| 80x30, topLeft | len 52 | len 15 |

At 80x30 the top anchors now cross controls (5-10 cells) instead of wandering: with no room above
the target, an arrow into the TOP edge has nowhere clean to come from, and that is the honest
answer to a caller who named that edge. Straight and crossing beats long and bending.

**Fixed — `arrowPadding` had no declared default**, so `ft_get`/state could not see it though
`ft_resolved_prop … 1` supplied one. Now in `defaults=` beside place/anchor/calloutWidth/boundBox.

### OPEN, measured, not yet acted on

1. ~~**A bordered container's BORDER is not an obstacle.**~~ **DONE 2026-08-22**, exactly as this
   item proposed: `_ft_route_obstacles` contributes the four thin ring strips when a container
   actually draws a border, priced as decoration (`_RT_CROSS`), interior still see-through. The
   downside this item feared did not arise, because the placer searches the home frame's interior
   and can never straddle its own ring; the strips exist for a DRAGGED callout, which may. See
   "Two bounds" above and docs/placement-cost-model.md stage 6 for the placement diff.
2. **Leader length is priced at 1/cell and distance is measured box→TARGET, not box→HEAD.** A
   50-cell leader is 47 points worse than a 3-cell one, noise beside `_NARROW_BIAS` (600) or one
   turn (3000). With a corner anchor the head can sit on the far side of the target from the chip
   and nothing in the score notices.
3. **A corner anchor can put the approach cell inside the target.** In the diagonal branch
   `ap_r = ex_r`; when the box's rows overlap the target's, the approach lands at (target top row,
   target right column) — inside a routing obstacle, which the route then has to escape.
4. **`_ft_beacon_paint_callout` leaks its nested helpers** (`_shape`, `_cand`) into the global
   namespace, because a nested `fn() {}` in bash is global. A test defining its own `_shape` had
   it silently replaced on the first paint. (`_bpos` and `_sidew` were two more; the allocator
   replaced the four-sides search that used them and they were removed on 2026-08-22.)
5. `place=` values are lower-case while `anchor=` values are camelCase; and the `onNext` ▶ is
   silently dropped when `bw-2-numw < 4`, so a narrow chip can carry a live `next` listener with
   no visible affordance.

## The teaching demo

`demo/callout-demo.bash` — seven pages, one callout idea each (what a callout is; the nine
anchors; `place=` vs auto; any control as a target; the chip's own chrome; the other variants;
how the engine decides). Guarded by `tests/test-callout-demo.bash` (84 assertions).

```bash
bash demo/callout-demo.bash
```

Its layout is itself a finding: with the code panes STACKED above the stage (css-demo's
arrangement) the free band above the specimen is three or four rows, less than a chip is tall —
`anchor=topLeft` could not be placed above its target at all and the placer drew a 49-cell
2-turn leader from the far margin. Beside the stage, the same call draws a straight three-cell
line. A demo about placement has to leave the placer somewhere to place things.

## Fixed 2026-08-13 (fourth pass — the p1 s3 "crazy routing", from the user's hand-drawn sketch)

The user drew the placement they wanted: box in the band beside the target, ONE bend. Three
mechanisms stood between the search and that drawing, found via the (now permanent)
`FT_BEACON_DEBUG` shortlist dump:

1. **The prefilter double-priced the diagonal.** A misaligned box was charged BOTH its
   straight-corridor estimate (+6000, through the Bold checkbox) AND a 2-turn misalignment
   (+6000), when the real routed leader pays one or the other — the L goes AROUND. The cheap
   score now adds `max(corridor, misalign)`, and misalign is ONE `_TURN_COST` because the
   diagonal exit makes an L by construction. (Kept at two turns it held every diagonal
   candidate on the same 6000-plateau as the corridor-crossers, and raw-distance tie-breakers
   decided against exactly the sketch's placement.)
2. **The diagonal exit now tries BOTH one-bend edges** — perpendicular (up, then across into
   the head) and facing (across, then up) — routes both, and keeps the cleaner (crossings,
   then turns, then length). Which dog-leg is clean depends on what sits in each, which the
   geometry cannot know without routing. One extra route on diagonal candidates only.
3. **The approach shortens past an obstacle** (3→2→1): with Bold two cells from the select,
   the full `_MIN_LEADER` approach cell landed ON it, forcing every exit to cross. A person
   bends in the gap that exists; the approach now does the same. The final leg into the head
   stays axis-aligned at any offset.

Result at 170×50: head `◀` at the select, straight down the empty gap column between
"Step 3 of 4" and `▶`, elbow into the box — 2 turns, ZERO crossings (the sketch's own line
brushed Bold; this threads clear channels the whole way). Verified in the pty render, goldens
re-recorded after review. **Watch for the FT_RET clobber** when composing these helpers:
`_ft_beacon_poly_stats` routes through `_ft_route_score`, which overwrites FT_RET — capture a
simplified polyline into a local BEFORE calling stats, or you store a score where a polyline
belongs and the callout silently draws nothing (found live, poly=[27] = 2 bends×8 + len 11).

## Fixed 2026-08-13 (third pass, from user screenshots)

- **"Bottom of the textfields cut off" (small windows).** Flex shrink reduced a container
  (`panes` 9→7 at 67×30) and walked away — the children kept their full heights, overflowed the
  shrunken parent, and the clip took their bottom borders off. The column-flex shrink now
  re-runs `_ft_pass_height kid newh` for a shrunk kid that has children (then re-pins the flex
  decision), so the subtree re-caps: divs redistribute, explicit-height children are shrunk by
  their own parent's flex one level down, and every bottom border lands inside its box. Bonus:
  `win` stopped overlapping the keylegend at small sizes (it was flowing one row under it).
- **Leader wiped by a focused pane's sheen (the "broken line" screenshot).** The ANIM composite
  path (`_ft_composite_overlays_animating`) tested only the callout's BOX against the animating
  control — and a leader routinely runs down the very border column a focused pane's sheen
  repaints every tick. Extended with the same `FT_OVERLAY_EXTRA` segment rects as the dirty
  path, same per-segment border-interior exemption. (The dirty-path fix alone was not enough;
  BOTH composite paths must know the leader's cells.)
- **`FT_BEACON_DEBUG=1` is now a PERMANENT shortlist/judge dump** (stderr, one guard test per
  placement). Four separate disputes were settled by reading this table; re-adding it by hand
  each time is how blind weight-tuning starts.
- **test-callout's chrome budget keys on `reachable`,** not "roomy": p9 s3 @80 has two regions
  that FIT the box but sit flush under the target's own row — box-plus-line cannot exist in
  them, and the judge's table shows every alternative buries more content than the chrome
  placement (116 vs 100 cells). Room that cannot host box+line earns no strictness.

## Fixed 2026-08-13 (second pass, from user screenshots)

- **Page-8 residue (grey band / old callout left behind).** `_ft_damage_fill` did ONE hit-test at
  the damaged rect's centre and painted that single background across the whole rect — and a
  callout extent routinely STRADDLES the frame border, half margin, half body. Whichever side the
  centre hit, the other side got the wrong ground (body-grey band across the black margin);
  headless, with `FT_ROOT` unset, it was a silent NO-OP (old glyphs stood). Now filled PER RUN:
  hit-test per cell, runs extend while the deepest covering node stays the same, no cover ⇒ the
  cleared screen (`FT_COLOR_SCREEN`). **tests/test-residue.bash** is the new gate: drive the
  app's own `_goto_step` path with every tty byte captured, replay into cells (glyph+fg+bg via
  tools/screen-cells.py), require equality with a from-scratch render — all 10 pages × 2 sizes
  (four opt-in via `FT_RESIDUE_SIZES`). Teeth-checked: a sabotaged fill fails 4 pages.
  Note for probes: `FT_ROOT=app` must be set headless or the repair path silently skips.
- **Leader flicker over an animated control.** The per-frame recomposite tests only the callout's
  BOX rect (deliberate: keeps a margin-parked callout from recompositing on every animation
  tick), so a control repainting cells under the LINE wiped it for a frame. The beacon now
  publishes its leader segments + arrowhead as `FT_OVERLAY_EXTRA[$name]` ("T L B R;…" thin
  rects), and `_ft_composite_overlays_touching` tests those only when the box test misses. The
  margin-parked case still costs nothing — nothing animated intersects its line.
- **"Text boxes cut off at the bottom."** The border-embedded horizontal scrollbar thumb was `▀`
  (upper half block), which floats above the border baseline and detaches from the `└ ┘` corners
  — the box read as torn open. Now `━` (heavy rule) over the border's light `─`: a thickened
  stretch of the border, and exactly the sheen crest's vocabulary on that edge, so the crest
  passing through stays seamless. ASCII fallback unchanged ('=' vs '-').

## Also open, unrelated to callouts

- `test-render` goldens: re-recorded 2026-08-13 (placement changes reviewed frame-by-frame, then
  the thumb glyph). page1 shows a below-left placement (side margins at 118 only fit the narrow
  shape + its bias), page1_stepped the measured least-bad 2-cell brush past Bold. If taste says
  otherwise the dials are `_NARROW_BIAS` vs the distance scale, with the brute-force probe
  pattern (git history: `_probe-simple`) as arbiter.
- The user reported "flashing" of the arrowhead at a cramped size (p1 s2, head sitting on the
  inherits-label row). The overlay-extra fix above heals any repaint-under-the-line within the
  same flush; if flashing persists interactively, the remaining suspect is cursor parking after
  the composite (needs a live tty to verify — headless captures cannot see the cursor).
