# The retained display list — a design, and the arithmetic behind it

---

## STATUS, 2026-09-05 — re-measured, and built

Everything below was written before the resolved-property memo (8b4a0de). **Every number in §1
and §8 was taken again on current HEAD before a line was written**, because a design whose
arithmetic has moved is a sales pitch too. The short version:

> **The conclusion holds. The reasoning that reached it does not.**
>
> §1.3 says a control repaint is "~92% asking questions", of which twelve `ft_resolved_prop`
> calls at ~150 µs are most. Re-measured, a 97-byte label on css-demo page 1 costs **2,475 µs**
> and makes **seven** `ft_resolved_prop` calls, **all seven served from the memo at 33 µs** —
> about 230 µs, under 10% of the repaint. The property reads are no longer the story.
>
> **What matters is the number either version implies, and it did not move**: `ft_print_at_width`
> — the part that actually produces the bytes — is **65 µs of 2,475, or 2%**. A repaint is 98%
> deciding what to paint, and retention does not care *why* deciding is expensive. So the design
> stands on a measurement that is, if anything, cleaner than the one it was written from.
>
> The predicted *ratios* moved a lot, and downwards. They are restated below.

**Re-measured baseline, current HEAD, this machine, run solo:**

| | doc's figure | now |
|---|---:|---:|
| `bench-drag`, faithful drive | 27 ms median / 36 max | **25 ms / 36 max** |
| …its `draw` stage (four unchanged controls) | 15.0 ms | **11.25 ms** |
| …its `composite` stage (the chip) | 7.6 ms | **4.75 ms** |
| …`fill` + `fillbuild` + `enlist` | 5.6 ms | **4.4 ms** |
| …the part retention cannot touch (mouse, reflow, flush) | "1.6 ms" | **4.7 ms** |
| css-demo page 1, warm full repaint | 199–229 ms | **88 ms** |
| …the same frame re-emitted from stored blocks | 1.7–2.0 ms | **0.44–0.65 ms** |
| one label repaint (`bashTitle`) | 3,396 µs | **2,475 µs** |
| …of which `ft_print_at_width` | 47 µs (1.7%) | **65 µs (2%)** |
| a warm `ft_resolved_prop` | 86–199 µs | **33 µs** memoised, 126–201 µs when the memo refuses |

§2.1 was re-run and still holds exactly: css-demo page 1 is 24,280 bytes and the concatenation
of its 32 controls' blocks is the same 24,280 bytes, byte for byte, with the reversed join
differing. §2.2 was re-run and still holds: over 20 faithful drag frames, four of the five
controls produce byte-identical output 19 times out of 20 and the chip produces translated ink
19 times out of 20.

**What was built** — §7 steps 1, 2 and 3, plus the damage-repair half of step 4 that falls out
of them:

* `ft_repaint_all ROOT` (step 1). Fourteen copies of `clear + ft_redraw_all` became one call.
* The recorder (step 2) is **not** a slice of `FT_OUT`. `${FT_OUT:offset}` is charged by the
  offset, not by the slice — measured, a 100-byte block costs 6 µs with an empty frame in front
  of it and **365 µs with 24 KB in front of it** — so the last control on a page would pay sixty
  times what the first one did. The two print primitives append to `FT_BLOCK_BEING_DRAWN`
  instead: ~6 µs a piece, independent of the frame.
* Serving (step 3) happens in `ft_draw_one` itself, so **every** repaint route gets it: the full
  walk, both overlay compositors, and the damage repair. That last one is where the drag win is,
  and it needed one distinction the engine did not have — `FT_REPAIR` beside `FT_DIRTY`, because
  "your cells were painted over" is not "your content changed".

**What was not built, and why** — §7 steps 4 (the row index and the closure, deleting
`_ft_damage_fill`), 5 (the move hint) and most of §10's deletions. The measured budget of a drag
frame after this work is ~14 ms, of which the fill is 4.0 ms and the chip's own re-derivation is
4.75 ms. Those are the two prizes left and they are the two riskiest changes in the plan —
`_ft_damage_fill`'s three skip rules each began as a reported residue bug, and the move hint is
§12.1's open question. They are worth ~9 ms on one frame type against the ~87 ms and ~11 ms
already taken, and they should be measured again from here rather than from this document.

**Measured result** (medians of three solo runs):

| | before | after |
|---|---:|---:|
| `bench-drag`, faithful drive | 25 ms median / 36 max | **14–15 ms / 33–36 max** |
| …its `draw` stage | 11.25 ms | **1.90 ms** |
| …its `composite`, `fill`, `enlist` stages | 4.75 / 4.00 / 0.40 ms | 4.65 / 3.85 / 0.35 ms |
| …the release | 60 ms | **49 ms** |
| css-demo page 1, warm full repaint | 88 ms | **10 ms** |
| `bench-modify`, keystroke | 1,384–1,461 µs | 1,384–1,461 µs |
| `bench-modify`, css-demo step | 728 ms | 709–720 ms |
| `bench-layout`, `ft_layout` | 200.0 ms | 201.6 ms |
| `ft_print_at_width`, one full-width coloured row | 43.1 µs | **49.3 µs** (the recorder) |

**THE MEDIAN MOVED AND THE MAX DID NOT, and that is worth explaining rather than burying.** Timed
frame by frame, the drag is now 33 ms for frame 1 and 14–16 ms for frames 2–20; before it was
35 ms and 22–25 ms. Frame 1 is the max, and 11 ms of it is a one-time cost this design creates:
`_ft_label_metrics` publishes `clientHeight` *during a draw*, that is a property write, and a
property write bumps the counter the token carries — so a control's very first block is recorded
already out of date and its next repaint derives once more. Painting the bench's scene three
times instead of once before the grab takes frame 1 from 33 ms to **22 ms**, with every later
frame unchanged. `tools/bench-drag.bash` was deliberately left alone: a benchmark edited to
flatter a change is not a measurement. The lever, if someone wants that 11 ms, is to let a draw
publish a *derived measurement* without it reading as an authorial write.

**The bypasses (§4), classified on current HEAD.** Twenty-three sites append to `FT_OUT` without
going through the two print primitives:

| # | site | what was done |
|---:|---|---|
| 12 | ft-help ×6, ft-settings ×3, ft-filedialog ×3 | `ft_repaint_all` |
| 2 | `ft_refresh`, `ft-run`'s deferred-refresh settle | `ft_repaint_all` |
| 1 | `ft-run`'s resize path | `ft_repaint_all` |
| 1 | `tests/_harness.bash`'s `settle` | `ft_repaint_all` |
| 1 | `_ft_damage_fill`'s inlined print | **left alone, and it is correct that it is**: the refill lays GROUND, which belongs to no control's block. The controls then put their ink back on top of it, now as an append |
| 1 | `ft-textfield`'s frozen-sheen blit | **routed through `_ft_print_bytes`**, which records as well as prints. This was the one bypass that could have shipped a wrong pixel: the ring would have gone on the screen and not into the block, so a later re-emit would have painted the field with no border |
| 2 | `ft-transition`'s blends | left as declared layer bypasses, outside any draw. A control in transition already returns from `ft_draw_one` before the list is touched |
| 5 | `_ft_place_caret` | legitimate, permanently: cursor position, shape, colour. No cell |
| 1 | `ft_beep` | legitimate. BEL puts no glyph anywhere |

and four places swap `FT_OUT` out from under a paint (`ft_beacon_place`, `_ft_transition_*`).
Only `ft_beacon_place` can run inside a draw, and it now swaps the recorder with it.

Two corrections to this document's own text, both found by re-measuring:

* **§8.1's "1.6 ms of run-loop work this design does not touch" is wrong; it is 4.7 ms.** That
  figure was 30 ms minus the stage timers, and the stage timers were inflated by the counters
  the same run was carrying. Timed directly, a faithful frame is `_ft_beacon_mouse_drag`
  1.50 ms + `ft_reflow_flush` 2.62 ms + `ft_flush` 0.57 ms + the paint. The floor is three times
  what §8.1 assumed, which is most of why "~11×" is not available on this frame at any price.
* **§5's clip question is settled the way §5 recommends** — store clipped — but for a reason
  the section does not give: the token carries the control's **resolved clip rect** rather than
  `_FT_CLIP_GEN`. Building any modal bumps that counter, so a token carrying it would never
  validate on precisely the frame this design wins most.

---

`docs/rendering-spans.md` says what a span renderer would look like. This document asks the
prior question: **is it worth building, what exactly would be retained, and what does the
measurement say the win is?** It is written to be checked, not followed. Every number in it was
measured in this session on this machine; where a measurement contradicts something already
written down in this repository, it says so and gives the probe.

The short answer, up front, because a design document that buries its conclusion is a sales
pitch:

> **Build it — but not the design in `rendering-spans.md`, and not first.**
>
> The measured shape of the problem is not the one that document assumes. A control repaint is
> **~92% asking questions and ~8% producing bytes**: a label that emits one 67-byte piece costs
> 2.7 ms, of which about 1.8 ms is twelve `ft_resolved_prop` calls at ~150 µs each. So the value of
> retention is not that re-emitting bytes is cheaper than emitting them — it is that **an
> unchanged control need not ask the cascade twelve questions.**
>
> That reframing collapses most of `rendering-spans.md`. Runs without escapes, interned style
> handles, interval subtraction and column-precise slicing are apparatus for making *emission*
> cheap, and emission is already 8% of the cost. The cheapest thing that
> retains a control's appearance is **the argument list of the `ft_print_at` calls it already makes** —
> four values, recorded by the two functions every painter already goes through, with no painter
> changed and no invariant to police.
>
> The honest win: **~120× on a forced repaint of unchanged content** (closing a modal), **~11× on
> a drag frame** if the mover declares that it only moved and ~3× if it does not, **~1.4–2.6× on
> a page tour**, and **~1× on typing**. It is an order of magnitude on the frames that are pure
> re-derivation and it is not an order of magnitude on average. Anyone told otherwise should ask
> for the arithmetic in §8.
>
> And one thing should be done **before** any of it, because it is smaller, safer, helps frames
> that retention cannot help, and helps layout too: §11.

---

## 1. What a frame costs today

### 1.1 The frame the run loop actually paints

`tools/bench-drag.bash`, faithful drive, three consecutive solo runs (118×40, a callout dragged
over content it must repair):

| | median | max | min |
|---|---|---|---|
| run 1 | 27 ms | 38 ms | 26 ms |
| run 2 | 27 ms | 37 ms | 26 ms |
| run 3 | 27 ms | 36 ms | 26 ms |

Where those 27 ms go. `FT_BURST_LOG`'s own stage timers, over 20 frames (the instrumented run
measures 30 ms/frame — the counters cost ~3 ms — so read these as proportions, not absolutes):

| stage | ms/frame | what it is |
|---|---|---|
| `draw` | 15.0 | `ft_draw_one` for the five controls the repair enlisted |
| `composite` | 7.6 | the chip itself (`comp-draw` 7.15 of it) |
| `fill` | 4.0 | `_ft_damage_fill` — re-deriving the ground under the vacated cells |
| `fillbuild` | 1.1 | the hit-test list and column cuts that fill needs |
| `enlist` | 0.5 | `_ft_damage_dirty_multi` — deciding who must repaint |
| | **28.2** | (of a 30 ms instrumented frame; the remaining ~1.8 ms is mouse handling, damage bookkeeping and the flush) |

Per frame the same run counts: `ft_draw_one` 5, `ft_resolved_prop` **58**, `_ft_clip_for` 8,
`_ft_compose_sgr` 4, 53 paint calls, and 8,188 bytes written to the tty.

That 53 needs a footnote, because a second probe that attributes every paint call to the control
being drawn finds **44** per frame, steadily, from frame 2 to frame 34. The gap is the
**release**, which is outside the timed frames but inside the counter's window. Every per-frame
figure below uses the attributed 44.

> **CORRECTION, 2026-09-05.** This footnote used to read: the release "alone emits **248
> pieces** — 210 of them the chip's, which is five full callout paints for one release." Neither
> half survived being measured again.
>
> `bench-drag` calls `run_drag` **twice**, and each call ends in a release, so the counter's
> window holds two of them. Attributed per release on that scene (118×40, 20 frames): 192 and 260
> pieces, of which the chip's are **154 and 222 — two paints each**, not five. The divisor was
> wrong too: "a parked callout draws ~39 pieces" was measured at a park position with a short
> leader, and the chip at the end of a 20-frame drag draws 77–111. Two paints divided by a
> too-small paint is where "five" came from.
>
> The two paints were real, and they were this: `_ft_beacon_mouse_release`'s non-coalescing
> branch ran `ft_redraw_dirty; _ft_composite_overlays; ft_flush`, and `ft_redraw_dirty` had
> **already** composited (it skips overlays in its draw loop precisely so
> `_ft_composite_overlays_touching` can place them on top, then flushes). The trailing blanket
> composite was a second identical paint of every live overlay on the screen. Four siblings in
> `controls/ft-beacon.bash` carried the same three statements; all five are gone, the screens are
> identical cell-for-cell, and `tests/test-composite-once.bash` now counts the paints.
>
> What the release costs today, on the same scene (medians of 12 gestures): a drag frame 14 ms,
> **the release 21 ms** on `ft_run`'s path — which draws the chip exactly once, because a
> coalesced release always did. The release is one and a half drag frames, and the extra half is
> the ghost ring (6 pieces) becoming the whole callout (77), which is what a release *is*. It is
> still a place retention would help; it was never five paints.
>
> `tools/bench-drag.bash` now times and counts the release on its own line, so the next person
> reads the number instead of inferring it.

Counted with a DEBUG trap (counting only — the trap makes timing meaningless), one faithful drag
frame executes **3,131 simple commands**. The trap fires once per simple command and also for the
arithmetic in a `for (( ))` header — a 1,000-iteration empty loop counts 3,005 — so this is an
upper-ish bound in trap events, and at 27 ms it prices a trap event at ~8.6 µs, consistent with
CONTRIBUTING's ~5 µs per statement. (A figure of ~6,000 statements per frame is in circulation;
this scene measures 3,131, so the two are describing different pages. Where the distinction
matters below, the count used is this one.)

### 1.2 A whole page

`demo/css-demo.bash` page 8, driven headlessly the way `demo/_perf.bash` drives it:

```
controls in tree 37 · ft_draw_one calls 33 (24 put ink on the screen, 9 are transparent containers)
paint calls      139 (ft_print_at 27, ft_print_at_width 112) · frame 18,332 bytes
warm full repaint  221 ms / 206 ms / 202 ms
```

Page 1 is the same to within 5%: 142 pieces, 18,512 bytes, ~200 ms.

Per control, the mean of ten warm repaints (page 8, the top of the list):

| µs | pieces | bytes | control | type |
|---:|---:|---:|---|---|
| 80,952 | 30 | 4,431 | `app` | form |
| 20,705 | 6 | 1,761 | `navlegend` | keylegend |
| 7,041 | 15 | 1,087 | `stepcallout` | beacon |
| 6,351 | 9 | 729 | `concept` | label |
| 4,636 | 27 | 4,525 | `win` | frame |
| 3,396 | 1 | 97 | `bashTitle` | label |
| 3,180 | 1 | 73 | `__lbl1` | label |
| 1,576 | 1 | 65 | `btnStepNext` | button |
| 274–362 | 0 | 0 | nine `div`s | (paint nothing) |

Two things jump out and both matter to the design.

**The unit of cost is the control, not the piece.** A label that emits one 73-byte piece costs
3.2 ms; a frame that emits 27 pieces and 4,525 bytes costs 4.6 ms. Cost is nearly flat in output.

**The root form costs 81 ms, and that is a bug, not a cost model.** `_ft_draw_form` is a
30-iteration loop over `ft_print_at_width` with an identical string; nothing in it should cost 2.7 ms a row.
It does because the form's border box measures **120 columns on a 118-column screen** — CSS
`width` is the content box, and this demo writes `width="$FT_COLS"` on a form the stylesheet gives
a border — so every row overhangs the clip by two columns and `ft_print_at_width` calls `ft_display_truncate`
on a 163-byte styled row, thirty times, every repaint. Isolated: the same loop with the clip open
costs 2.6 ms; with the clip at column 117 it costs 77.5 ms. **38% of that page's full repaint is
one control being two columns too wide.** It is not this design's business to fix, but it is in
the numbers, so it is named here rather than quietly inflating a ratio later. (Retention does
elide it after the first frame, which is a lucky side effect and not an argument.)

> **CORRECTION, 2026-09-05.** The 81 ms form is an artefact of the harness, not of the demo,
> and every repaint figure in this section is inflated by it.
>
> There is no border. `ft_own_prop app width` answers **120**, `_ft_css_query app border`
> answers nothing, and `_ft_inset4 app` is zero on all four sides. The form is 120 columns
> because it was *built* 120 columns wide: `demo/_perf.bash` sources the demo — which runs
> `ft-form name=app width="$FT_COLS"` against whatever `ft_term_size` answered, 120×30 on this
> machine — and only then assigns `FT_COLS=118`. That moves the clip and leaves the form where
> it was. The two columns are the harness disagreeing with itself; a real terminal sizes the
> form to the screen it actually has.
>
> Run the demo's own `_resize` first, as a WINCH does, and page 8 measures **95 ms** and calls
> `ft_display_truncate` **zero** times. `tools/audit-overhang.bash` extends that to the whole
> shipping surface — all ten css-demo pages and every other `ft-run` demo, comparing each
> control's border box against the rect `_ft_clip_for` hands its own painting — and finds **not
> one overhanging control anywhere**. Its `--teeth` mode makes the harness's mistake on purpose
> and reproduces the four mis-sized controls exactly, so the clean result is a measurement and
> not a silence. So: the demo was never wrong, `width` as the content box was never implicated,
> and the case this paragraph made for `box-sizing: border-box` rests on nothing. `demo/_perf.bash`
> now calls `_resize` and **refuses to print timings** if the form's declared width, its measured
> width and `FT_COLS` are not all the same number.
>
> One real thing came out of it. `ft_display_truncate` genuinely did cost 2 ms on a 118-column
> row, because it walked the string one `${s:i:1}` at a time while its sibling `ft_display_width`
> had twice been taught to take slices wholesale — CONTRIBUTING §1's "same predicate on one route
> and not its siblings", again. That is fixed and gated (`tests/test-displayscan.bash`,
> `tools/bench-display-scan.bash`): 1,959 µs → 69 µs on a plain row, 2,281 → 225 on a styled one.
> It does nothing for page 8, which truncates nothing; it is worth 64 ms → 51 ms on a table whose
> cells overflow their columns, which is where `ft_fit` reaches for it in ordinary use.

### 1.3 The anatomy of one repaint

`ft_draw_one tgt` — one label, one piece, 67 bytes, 2.74 ms, 592 trap events. What it calls:

| calls | function | warm cost each |
|---:|---|---:|
| 12 | `ft_resolved_prop` | 86–199 µs |
| 8 | `_ft_css_query` | 42.5 µs (`tools/bench-cascade.bash`) |
| 4 | `ft_style` | 32.9 µs |
| 4 | `_ft_color_override` | — |
| 4 | `_ft_get_raw` | 15.4–37 µs |
| 2 | `_ft_clip_for` | 90.6 µs (memoised) |
| 1 each | `_ft_inset4` 182.6 µs · `ft_fit` 83.9 µs · `_ft_disp` 48.6 µs · `_ft_compose_sgr` 43.5 µs · `ft_print_at_width` 47.3 µs | |

Those add to ~2.4–2.7 ms. **The model closes**: a label repaint is its property reads.
`ft_print_at_width` — the part that actually produces the bytes — is 47 µs of 2,740, or **1.7%**. Adding
`ft_fit`, the whole string-production half is under 8%.

Two corrections to numbers already written down in this repository, both verified with the
repository's own instruments:

* **`_ft_compose_sgr` is 43.5 µs, not 810 µs.** `tools/bench-cascade.bash` reports it beside
  `ft_style` (32.9 µs) and `_ft_css_query` (42.5 µs). It was memoised (`_FT_SGR_CACHE`, ft-forms
  ~2469) and the win was taken. `rendering-spans.md` §3 still calls it "the single most important
  performance change in this document… worth doing **first and on its own**", and
  `_ft_compose_sgr`'s own header comment still quotes 810 µs. Both are stale, and §10 of that
  document's migration plan therefore begins with work that is already done.
* **A warm `ft_resolved_prop` is 86–199 µs, not 62 µs.** Its own comment records "101µs → 62µs per read",
  which matches my measurement of `ft_resolve` alone (53 µs) — the comment is measuring the
  narrower thing its sentence is about. The spread is structural, not noise, and reproduces in two
  different scenes:

  | property | bare app | css-demo | why |
  |---|---:|---:|---|
  | `text` | 73 µs | 93 µs | own value, present, no walk |
  | `overflow` | 86 µs | 89 µs | non-inheriting, no hook |
  | `textAlign` | 139 µs | 169 µs | **inherits** → walks the ancestor chain |
  | `visibility` | 146 µs | 174 µs | inherits |
  | `color` | 199 µs | 73 µs | inherits *and* has a coercion hook |

  An inheriting property with no local value **walks its ancestors on every single call**, and a
  control's draw makes a dozen such calls. That is CONTRIBUTING §3's canonical shape — "an
  expensive answer recomputed inside a loop when it is constant across the loop" — sitting
  unharvested in the hottest function in the framework. §11.

---

## 2. The two facts the design rests on

### 2.1 A frame is exactly the concatenation of its controls' byte blocks

If retention is to re-emit recorded bytes instead of re-deriving them, a frame must *be* the
concatenation of per-control blocks in paint order — no cross-control state in `ft_draw_one`, no
interleaving. That is testable today. Intercepting every `ft_draw_one` during a real full repaint,
capturing each call's block separately, and concatenating:

```
drag scene   6 controls   frame 15,368 bytes   concatenated blocks 15,368   → identical
css-demo p8 33 controls   frame 18,332 bytes   concatenated blocks 18,332   → identical
css-demo p1 32 controls   frame 18,512 bytes   concatenated blocks 18,512   → identical
```

**Teeth** (CONTRIBUTING §4): the same blocks concatenated in reverse order must *not* match, and
do not. And a second identical full repaint is byte-identical to the first, so "derive" is a
repeatable quantity and the ratios below are ratios of the same thing.

This is the licence for the whole design. It also says something the span model does not need to
be told: paint order is a plain integer — the index of the control in the walk.

### 2.2 A drag frame spends 94% of its draw time reproducing bytes it already produced

Same faithful drive, 20 frames, every `ft_draw_one` block compared with the block that control
produced on the previous frame. Three outcomes: **identical**, **translated** (the same ink with
every cursor address shifted — a pure move), **new**.

| control | draws | identical | translated | new | total ms | of which waste |
|---|---:|---:|---:|---:|---:|---:|
| `page` | 20 | 19 | 0 | 0 | 80 | 76 |
| `filler1` | 20 | 19 | 0 | 0 | 65 | 62 |
| `filler2` | 20 | 19 | 0 | 0 | 62 | 59 |
| `tgt` | 20 | 19 | 0 | 0 | 63 | 60 |
| `chip` | 20 | 0 | **19** | 0 | 102 | 96 |
| | | | | | **374** | **355 (94%)** |

Four of the five controls a drag frame repaints produce **byte-identical output every frame**. The
fifth — the thing that is actually moving — produces *the same ink at a different address* every
frame, because a grabbed callout drags as a ghost ring (`_ft_beacon_paint_ghost`) and the ring's
glyphs do not change as it slides.

**Teeth**: the chip must never be classified identical (it visibly moves); measured 0 identical,
19 translated. A classifier that said "identical" here would be broken.

### 2.3 …but a page tour is a much soberer 27%

The same question over a realistic session — thirteen page loads, four step changes each,
simulating the list honestly (an entry is remembered when a control is drawn and **forgotten when
the control is removed**, 395 forgettings):

```
ft_draw_one calls 2,301   hits 1,757 (76%)   misses 544
time in draws  29,166 ms  of which hits (pure waste) 7,950 ms (27%)
```

76% of *calls* are waste but only 27% of *time*, because the expensive draws are the ones that
change. The per-control breakdown says exactly where:

| control | hits | hit ms | misses | miss ms |
|---|---:|---:|---:|---:|
| `stepcallout` | 39 | 430 | 65 | **16,319** |
| `concept` | 65 | 486 | 13 | 410 |
| `spec` | 65 | 557 | 13 | 409 |
| `stepcount` | 27 | 93 | 51 | 402 |
| `navlegend` | 16 | 399 | 10 | 324 |
| everything else | … | … | … | ≤ 378 each |

`stepcallout` alone is 16.3 s of the 21.2 s of miss time — **77%** — and that is the callout
placement search and leader route (`demo/_perf.bash`: "PAINT callout (placement search + route)
442 ms", against 11 ms with the placement cached). That is a geometry problem, documented in
`docs/placement-cost-model.md`, and **this design does nothing for it.** Excluding it, the tour's
paint work is 12.9 s of which 7.95 s is waste — **62%**.

**Teeth**: draw a control, change its text, draw it again → the probe must record one hit and one
miss. It does.

---

## 3. What is retained, and keyed on what

### 3.1 The unit: a *piece*, which is the `ft_print_at` argument list

```
FT_PIECE_ROW[]  FT_PIECE_COLUMN[]  FT_PIECE_TEXT[]  FT_PIECE_WIDTH[]
```

That is all. `ft_print_at ROW COL STRING` and `ft_print_at_width ROW COL STRING WIDTH` already receive exactly
these values, after clipping and tab expansion, immediately before they build a cursor address and
append. Recording is a handful of array writes at the point the bytes are already computed.

Per control, three more things:

```
FT_CONTROL_PIECE_FIRST[name] FT_CONTROL_PIECE_COUNT[name]   its slice of the piece arrays
FT_CONTROL_BLOCK[name]                                       the concatenated bytes (§2.1)
FT_CONTROL_TOKEN[name]                                       the validity key (§3.3)
FT_CONTROL_ORDER[name]                                       its index in the paint walk (§2.1)
```

`FT_CONTROL_BLOCK` is redundant with the pieces — it is their concatenation — and it is kept
anyway, because the full-repaint route (§7 step 3) is one append per control and that is measured
at 32–38 ns/byte against ~10 µs per piece re-emitted individually: 0.55 ms versus 1.7 ms for a
whole page. Redundancy that is derived at record time and never diverges is a different thing from
two sources of truth; the pieces are authoritative and the block is a cached join of them.

and one membership index so a cell can be traced to the pieces over it:

```
FT_ROW_PIECE[row * FT_ROW_STRIDE + i]   FT_ROW_PIECE_COUNT[row]
```

Measured: a busy page holds **139–142 pieces over 30 rows** — typically 2–6 per row, one row with
22 (the key legend), mean piece length 129 bytes. This is a small structure. `FT_ROW_STRIDE = 32`
with a per-row overflow flag, as `rendering-spans.md` §4 proposes, is right and is the only part
of that document's data layout this design keeps.

### 3.2 Why *not* runs, style handles and the no-escapes invariant

`rendering-spans.md` builds runs of plain text with interned style handles so that a run can be
sliced by display column cheaply. The measurement that motivates it is real:

| operation on one 118-column row | cost | after 2026-09-05 |
|---|---:|---:|
| `${row:10:40}` — legal only if the text has no escapes and no wide glyphs | **5.6 µs** | 7 µs |
| `ft_display_truncate`, plain ASCII | 744 µs | **69 µs** |
| `ft_display_truncate`, the same row with its SGR inside | **1.04–2.42 ms** | **225 µs** |
| `ft_display_width`, plain / with SGR / with CJK | 78 / 332 / 553 µs | 55 / 350 / 1875 µs |

> **The right-hand column is new.** `ft_display_truncate` was walking one character at a time
> where `ft_display_width` sliced wholesale; it now takes the same slices (`ft-core.bash`,
> `tools/bench-display-scan.bash`). The gap this section is built on **narrows from ~200–400×
> to ~3–32×**, which cuts the same way the section's own argument does — it makes the
> no-escapes invariant a smaller prize, not a larger one — so the conclusion below stands on
> firmer ground than when it was written, not weaker. The absolute numbers in §6 and §7 that
> quote **1.04–2.42 ms** should be read as **225 µs**.

Slicing a styled row is ~3× slicing a plain one, and ~32× a bare parameter expansion. That is
still a real fact, and it justifies the invariant **if you need to slice**. §6 argues that damage repair does not need to
slice, ever. Once slicing is off the table, the invariant buys nothing and costs a great deal: it
requires every one of the 104 `ft_print_at`/`ft_print_at_width` call sites in the engine and controls to be rewritten
into `ft_draw_*` calls that separate text from style, and it requires each of those painters to
stop hand-assembling SGR into its strings — which is most of what they do.

The other justification given for interning was `_ft_compose_sgr` at 810 µs. It is 43.5 µs now
(§1.3). **That lever has already been pulled**, and pulling it again is worth 4 calls × 43.5 µs =
0.17 ms per drag frame.

So: pieces carry their escapes, exactly as they are emitted today. The design is a *cache in front
of the existing painters*, not a new drawing API. Seventeen painters change by zero lines; the
eighteenth (ft-textfield) changes by one deletion (§4).

### 3.3 The key, and why its enumeration is bounded

This is the whole risk of the design, and it deserves the same treatment `_ft_clip_for`'s memo
already got — a token, bumped by hand at every route that can change the answer, with a test that
drives each route and fails if its bump is removed.

The structural argument first, because it is what makes the enumeration finite:

> **The retained entry is consulted only for controls the engine did *not* mark dirty.** A control
> the engine marks dirty is re-derived, exactly as today. So retention cannot be stale in any way
> that today's incremental repaint is not *already* stale — with two exceptions, which are
> precisely what the token must cover:
>
> 1. **State a full repaint used to launder.** Today `ft_refresh` re-derives everything, so a
>    missing dirty mark is invisible whenever a full repaint follows. Under retention a full
>    repaint would re-emit the stale entry and the bug becomes visible. This is the real hazard,
>    and it is why the token must carry the *global* paint inputs rather than trusting `FT_DIRTY`.
> 2. **Paint that does not go through `ft_draw_one`.** The bypasses. §4.

Is that claim true, or merely tidy? It is testable, so it was tested. For a matrix of mutations on
a real page, compare **CHANGED** (controls whose `ft_draw_one` output differs before vs after)
against **DRAWN** (controls the engine actually repainted during its own settle). `CHANGED \ DRAWN`
is the hazard set:

| mutation | changed | drawn | hazard |
|---|---:|---:|---|
| a label's text via `ft-modify` | 1 | 1 | none |
| focus moves to another control | 3 | 3 | none — and the three are `css`, `btnOk` **and `navlegend`**, the legend that derives its content from *another* control |
| a button's own colour | 1 | 1 | none |
| a select's value / a checkbox toggled | 0 | 1 | none |
| a stylesheet registered at runtime | 2 | 6 | none |
| a control removed | 0 | 33 | none |
| resize through `ft-run`'s own route | 22 | 31 | none |
| **resize by calling `ft_layout` alone** | 4 | 0 | `app cssTitle navlegend navbar` |
| **SABOTAGE: change a label, then clear `FT_DIRTY`** | 1 | 0 | `concept` |

**Teeth**: the sabotage must appear, or the probe is blind. It does. (An earlier version of the
sabotage — poking `_ftp_bashTitle_text` directly — produced *no* hazard, because the cascade's own
memo absorbed it. That is worth recording: a probe at the wrong layer reports a clean bill of
health for a mechanism it never reached. CONTRIBUTING §5, earned again.)

Two hazards, and both are informative. The resize-by-`ft_layout` row is not a bug: `ft-run` resizes
by clearing the screen and calling `ft_redraw_all`, and the faithful route shows no hazard. It is
a demonstration that *changing global paint inputs without a repaint is exactly what breaks
retention*, which is the point of the token. The sabotage is the shape of every real failure this
design can have.

So the token, modelled on `_FT_SGR_CACHE`'s and `_FT_CLIP_CACHE`'s, both of which already exist
and are already gated:

```
_FT_CSS_EPOCH               a sheet registered, a theme swapped
_FT_CSS_VERSION[name]       this control's scoped cascade version (already per-node, already
                            invalidated per subtree by _ft_css_inval)
_FT_CLIP_GEN                every route that moves an ancestor's overflow, inset, absolute
                            geometry or parent link — already enumerated at _ft_clip_inval's
                            callers and already driven by tests/test-clip.bash
FT_LAYOUT_EPOCH             a layout pass ran
FT_ROWS : FT_COLS           the terminal size
FT_FOCUS                    :focus changes appearance and deliberately bumps nothing else
FT_ROOT                     :root resolution
FT_CLIP_BAND_R0 : R1        the transition machinery narrows the band mid-paint
FT_COLOR_MODE               8/256/truecolour
FT_ANIM_PHASE[name]         only when FT_CSS_ANIMATION_ON[name] — as _ft_compose_sgr already does
_FT_TRANSITION_ACTIVE[name] a control in transition does not paint itself
FT_ABSOLUTE_X/Y[name]       the control's own origin (a move is a new answer)
FT_MEASURED_WIDTH/HEIGHT
```

Every line of that is a token component that already exists in the framework for the same reason.
The design does not invent an invalidation surface; it takes the union of two that are already
maintained and gated, and adds the control's own geometry.

**What it must not do is trust the token alone.** The token cannot see a property write, and it
must not have to: a property write already calls `ft_dirty`, and a dirty control re-derives. The
token exists for the things that change appearance *without* a write.

**The gate.** The invalidation probe above becomes `tests/test-retain.bash`: for a matrix of
mutations, assert `CHANGED ⊆ DRAWN ∪ INVALIDATED`. Its teeth are the sabotage, and it must also
assert that the matrix found something to look at (CONTRIBUTING §4: a sweep over an empty list
passes every check inside it). Without this gate the design should not be started.

### 3.4 What invalidates an entry — every route

| route | what happens | already exists? |
|---|---|---|
| a property write (`ft_set`, `ft-modify`, `ft_remove_attribute`) | `ft_dirty` → re-derive | yes |
| a prototype default / stylesheet change | `_ft_css_inval` bumps `_FT_CSS_VERSION` per subtree; `_ft_css_bump` bumps the epoch | yes |
| focus / state change | in the token (`FT_FOCUS`) | yes (`_FT_SGR_CACHE`) |
| layout, reflow, scroll | `FT_LAYOUT_EPOCH`, `_FT_CLIP_GEN`, the control's own absolute box | yes |
| overflow / padding / border on an ancestor | `_FT_CLIP_GEN` — the one counter that exists *because* neither the layout epoch nor the cascade token covers these | yes, with a gate |
| terminal resize, colour-mode change | in the token | new |
| animation tick | `FT_ANIM_PHASE`, gated on `FT_CSS_ANIMATION_ON` | yes (`_FT_SGR_CACHE`) |
| transition arm/retire | `_FT_TRANSITION_ACTIVE` | yes (`ft_draw_one` already guards) |
| `ft_remove` | drop the entry and its descendants'; the cells become damage | new, and mandatory |
| reparent | drop the entry (paint order changed) | new |
| a bypass writing to `FT_OUT` | §4 | new |

The two "new" rows that are not merely token components — removal and reparenting — are the ones
worth writing a test for by name, because they are the ones where an entry can outlive its
control. The probe in §2.3 already models removal (395 forgettings across a tour) and the hit rate
survives it.

---

## 4. The twenty-eight bypasses

Everything that appends to `FT_OUT` without going through `ft_print_at`/`ft_print_at_width`. Counted in the engine
and controls (not tests, tools or demos): 26 sites, plus `ft_print_at` and `ft_print_at_width` themselves = 28.

**Sixteen of the twenty-six are the same two statements.**

```bash
FT_OUT+="$FT_COLOR_SCREEN$FT_ANSI_CLEAR_SCREEN"; ft_redraw_all "$root"
```

| # | site | verdict |
|---:|---|---|
| 2 | `ft-core.bash:1026, 1046` — `ft_print_at`, `ft_print_at_width` | **become the recorders.** They keep their signatures; they append to the piece arrays and to the current control's block as well as to `FT_OUT`. No painter changes. |
| 1 | `ft-core.bash:1076` — `ft_beep` | **legitimate.** BEL puts no glyph on any cell and cannot desynchronise a cell model. |
| 16 | `ft-forms:3706, 6945, 7034` · `ft-help:219, 227, 241, 293, 301, 316` · `ft-settings:106, 114, 126` · `ft-filedialog:253, 261, 292` · `tests/_harness:90` | **must be fixed first, and the fix is a missing public API.** Sixteen copies of "clear the screen and repaint everything" is CONTRIBUTING §1's "a fix you find yourself repeating per case is at the wrong layer", and CONTRIBUTING §6's "if a demo needs an engine call, that is a missing public API". Replace all sixteen with one `ft_repaint_all ROOT`, which under retention is the single place that **drops the display list and rebuilds it**. Until they are one call, retention has sixteen places where the screen is blanked and the list does not know. This refactor is worth doing on its own merits and is a prerequisite. |
| 5 | `ft-textfield:1876, 1878, 1880, 1884, 1885` — `_ft_place_caret` | **legitimate, permanently.** Cursor position, shape, colour (OSC 12/112) and visibility. It writes no cell. It runs from `ft_flush`, after the frame, and `FT_CARET_FN` is the documented hook for exactly this. It cannot corrupt the list because the list models cells and this changes none. |
| 1 | `ft-textfield:2521` — `FT_SHEEN_FROZEN` blit | **delete it — the design subsumes it.** This is already a retained display list for one control's border ring, keyed on a hand-built signature (`phase\|row\|col\|rows\|cols\|borderSGR\|vbar\|hbar`). Its own comment records the bug that taught it the signature must name the scrollbar thumb: a cached ring blitted over a thumb the draw had just painted, so an overflowing textarea showed no thumb at all. That is precisely the failure mode of a retained cache with an under-specified key, in production, already paid for. |
| 2 | `ft-transition:1013, 1065` | **the one genuine layer bypass, and the design's biggest customer.** A transition appends a pre-blended frame over a rect the list believes belongs to controls. Keep it as a bypass, but declare its rect as an opaque layer owned by the transition so repair does not try to serve those cells from the list. In exchange, §10: `_ft_transition_capture_ground` + `_ft_transition_parse` — ~90 ms of re-deriving and re-parsing the ground on the live path — becomes a lookup. |
| 1 | `ft-forms:4859` — `_ft_damage_fill`'s inlined `ft_print_at_width` | **deleted with the fill** (§6). |

The count that matters: after the sixteen become one call and the sheen blit is deleted, the
bypasses that can put a glyph on a cell without the list knowing are **two** (the transition's,
both declared), and the ones that put no glyph anywhere are **six** (beep and the caret).

---

## 5. How clipping composes with retention

`_ft_clip_for` is memoised per `(parent, token)` — keyed on the *parent* because the rect is built
by walking from the control's parent upward, so every child of a container computes the identical
answer. Warm, it costs 90.6 µs.

The question `rendering-spans.md` leaves open is whether a retained piece stores its clipped text
or stores the text unclipped and clips at emission. Costed both ways:

**Store clipped (recommended).** `ft_print_at` clips *before the bytes exist* — it truncates the string
and appends `\e[0m`, and only then builds the cursor address. So the clipped result is what the
recorder naturally has, at zero extra cost. The clip becomes part of the key by including
`_FT_CLIP_GEN`, `FT_CLIP_BAND_R0/R1`, `FT_LAYOUT_EPOCH` and `FT_ROWS:FT_COLS` in the token — all of
which the clip memo already maintains for its own key, so it is free to ride along. A clip change
invalidates the entry and the control re-derives, which is correct: a clip change genuinely
changes what the control paints.

**Store unclipped, clip at emit.** Each emission of a piece that crosses the clip must slice it.
Our pieces carry their SGR inside, so that slice is `ft_display_truncate` on a styled string:
**1.04–2.42 ms** measured on a 118-column row. The root form alone would pay it thirty times a
frame. Rejected on the measurement.

> **Re-price this, 2026-09-05.** Both halves of that rejection moved. The slice is now **225 µs**
> (§3.2), and the "root form paying it thirty times a frame" was the mis-sized harness, not a
> real screen (§1.2) — a correctly-sized page 8 emits no clipped piece at all. What remains is
> 225 µs per genuinely-overhanging piece, which is a different decision from 2.42 ms and is not
> re-made here. Whoever implements §7 should decide it on the new number rather than inherit
> this paragraph.

The asymmetry only disappears under the runs-without-escapes invariant, where the slice is
`${text:a:b}` at 5.6 µs — which is the honest case *for* `rendering-spans.md`'s model and the
reason it is not dismissed here, only deferred. If a future need forces column-precise emission,
that invariant is how to pay for it. §6 argues the need does not arise.

**One trap worth writing down.** `_ft_clip_for`'s band (`ft_clip_band`) is set *by the transition
machinery around a nested paint*, with no property change at all. A piece recorded inside a
narrowed band is not a piece valid outside it. The band is already in the clip memo's token for
exactly this reason; it must be in the retained token too, and `tests/test-clip.bash` is the
pattern for gating it.

---

## 6. How damage repair composes — and why it gets *simpler*

`docs/rendering-damage.md` is a post-mortem of three failed attempts, and its diagnosis is exact:
repair is not "repaint the controls that intersect the rect", because the rect crosses transparent
containers that paint no background, so the cells *between* the controls stay blank. The engine's
answer today is `_ft_damage_fill` — resolve the ground per run with a flattened hit test, refill
it, then enlist every control that overlaps, skipping background-fillers and draw-less containers
so an ancestor does not wipe its siblings. It works, it is heavily commented, and it costs 4.0 ms
of fill + 1.1 ms of fill-build + 0.5 ms of enlist per drag frame, plus the 13.5 ms of re-derivation
it enlists.

**Under retention the question does not arise.** "What is underneath" is a lookup. The repair is:

```
for each damaged interval (row, from..to):
    for each piece in FT_ROW_PIECE[row], in paint order:
        if it overlaps [from..to]: emit it WHOLE
```

Three claims, each of which needs defending.

**(a) Emitting a piece whole, rather than sliced to the interval, is correct.** The piece's bytes
are what is on those cells. Re-emitting them over cells that were already correct writes the same
content to the same cells. It is redundant, not wrong — *provided* anything painted above those
extra cells is re-emitted too, which is (b). And the closure is exactly row-local, because a piece
occupies one row and can only be covered by pieces in that row. There is no transitive walk across
rows and no ordering problem between rows.

**(b) The closure is bounded.** If you re-emit piece *P*, you must also re-emit every piece later
in paint order that overlaps *P*'s columns on that row, or a lower piece will cover a higher one.
That closure is bounded by the pieces in the row: measured **2–6 typically, 22 at the worst row**
of a busy page. Note what this dissolves: the "an ancestor that fills its background wipes its
siblings" failure that defeated three implementations is now *automatic* — you re-emit the form's
row and then everything above it on that row, in order, from a record. There is nothing to reason
about and nothing for `_ft_damage_dirty_multi`'s three carefully-argued skip rules to get wrong.

**(c) The bytes are affordable.** Emitting whole pieces ships more bytes than emitting exact
intervals. A drag frame today ships 8,188 bytes; the exposed region is ~8 rows and a row holds
2–6 pieces of ~129 bytes, so a whole-piece repair is ~1.5–4 KB — *fewer* bytes than today, because
today the fill writes ground runs *and then* the enlisted controls repaint over them.

So `_ft_damage_fill`, `_ft_dfill_hit_build`, `_FT_DFILL_CUTS`, `_FT_DFILL_HIT`, `_FT_DFILL_BG`,
`_ft_damage_dirty_multi` and `FT_DAMAGE_NARROW` are all replaced by a row lookup. §10.

What `ft_damage` still means: "these cells are now wrong". The engine raises it from the same
events (remove, hide, move, scroll, overlay reposition) and `FT_PAINT_RECT` still records what a
control actually covered. The interval merging in `ft_redraw_dirty` stays — it is what keeps a
burst's overlapping strips from being repaired sixteen times.

---

## 7. Migration — incremental, with the suite green at every step

It can land incrementally, and it must. Nothing here is a flag day.

**0. The gate first.** `tests/test-retain.bash` (§3.3) and a green `tests/test-render.bash`.
`rendering-spans.md` §10 puts the render gate first for the right reason — three rendering
regressions passed a fully green unit suite — and that gate now exists, so this step is: make sure
it covers the pages this work will touch, and add the invalidation matrix. **The design should not
be started without a gate that fails on the sabotage in §3.3.**

**1. `ft_repaint_all ROOT`.** Collapse the sixteen `clear + ft_redraw_all` copies (§4) into one
public call. No behaviour change, sixteen call sites deleted, `tests/test-api-surface.bash`
unaffected or improved. Independently worth doing.

**2. Record beside the buffer — a shadow list that nothing reads.** `ft_print_at`/`ft_print_at_width` append to the
piece arrays as well as to `FT_OUT`; `ft_draw_one` brackets each control's pieces and stores the
block. Nothing consults it. The gate at this step is an *equality assertion*: the concatenation of
the blocks must equal `FT_OUT`, byte for byte, on every page of the render gate — which is exactly
the probe in §2.1, promoted to a test. Cost: one array write set per piece (~10 µs measured), ~139
pieces on a full page = ~1.4 ms, 44 pieces on a drag frame = ~0.4 ms. **This step makes frames
slower**, and that is fine because the next two take it back many times over.

**3. Serve the full-repaint route from the list.** `ft_repaint_all` emits the stored blocks in
paint order for every control whose token still validates, and derives the rest. This is the
single highest-value step and the one with the least new machinery: no row index, no interval
resolution, no closure — just "for each control in walk order, block or derive". It is worth
~120× on a modal close (§8) and it is verified by the equality assertion from step 2, still
running.

**4. Serve damage repair from the list** (§6). Add the row index and the closure. Delete
`_ft_damage_fill` and its apparatus behind a flag for one release, compare frames, then delete the
flag. This is the step that needs the byte-replay technique `tests/test-residue.bash` already uses.

**5. The move hint.** A control that only moved re-addresses its pieces instead of re-deriving.
`ft_reflow` already distinguishes a pure move (`_ft_reflow_now`'s `moved` branch); the beacon's
drag handler is the other place that knows. This is the step that turns ~3× into ~11× on a drag,
and it is the step most likely to be wrong, so it goes last and behind its own gate.

**6. Delete** (§10).

Steps 1–4 each leave the suite green and each stand alone. Step 3 alone is a defensible place to
stop.

---

## 8. The predicted win, with the arithmetic shown

### 8.1 A drag frame: 27 ms → ~2.3 ms (**~11×**), or ~9 ms (~3×) without the move hint

First, what the frame actually emits. Attributing every `ft_print_at`/`ft_print_at_width` call to the control whose
`ft_draw_one` is on the stack, over the same faithful drive:

```
frame 17  27112 us  pieces 44  [page=35 filler1=1 filler2=1 tgt=1 chip=6]  damage rects 4
frame 18  27376 us  pieces 44  [page=35 filler1=1 filler2=1 tgt=1 chip=6]  damage rects 4
…identical through frame 34
```

**The dragged chip emits six pieces and ~260 bytes, and costs 6.8 ms to derive them** — 1.1 ms per
piece. `page` re-emits thirty-five identical pieces at 5.4 ms. That asymmetry is the design in one
line: cost lives in derivation, not in output.

(A caution for anyone re-running this: the frame is only 27 ms while the chip is *over content*.
Driven without `bench-drag`'s clamps the chip walks off the labels, nothing is enlisted, and the
frame is 13–14 ms with the chip alone. `tools/bench-drag.bash` clamps deliberately — "a chip
dragged across blank cells would flatter every candidate fix" — and the clamped regime is the one
every number here uses.)

Today, scaled from the instrumented breakdown (§1.1) by 27/30:

```
draw, four unchanged controls  13.5 ms   (page 35 pieces, three labels 1 each)
composite, the chip             6.8 ms   (6 pieces)
fill + fillbuild + enlist       5.1 ms
mouse, damage, flush            1.6 ms
                               ─────── 27.0 ms
```

Under retention:

| | cost | how it is derived |
|---|---:|---|
| four unchanged controls | **0 ms** | not drawn at all; their cells are served by the repair below |
| repair | **~0.5 ms** | measured 4 damage rects / 8.3 exposed runs per frame; ~8 intervals × 2–6 pieces per row (§3.1) = 16–48 whole-piece emits at ~10 µs (4 array reads + `printf -v` + append, 7.4 µs measured), plus ~0.3 ms of interval bookkeeping |
| the chip, **with** a move hint | **~0.2 ms** | 6 pieces re-addressed at ~20 µs, plus 12 row-bucket writes |
| the chip, **without** one | 6.8 ms | re-derived, exactly as today (measured) |
| mouse, damage, flush | 1.6 ms | untouched — this design does not go near it |
| | **~2.3 ms** | **~11×** |

Without the move hint: 0.5 + 6.8 + 1.6 = **~8.9 ms**, **~3×**.

Two honesty notes on this table. The repair figure is the softest number in this document — it is
an estimate from measured piece density and measured per-emit cost, not a measurement of a thing
that exists. Its sensitivity is mild: at **five times** my estimate the frame is 4.4 ms and the win
is still 6×. And the floor is 1.6 ms of run-loop work this design does not touch, so no emitter,
however perfect, beats ~17× on this frame.

### 8.2 A modal close: ~200 ms → ~1.7 ms (**~120×**)

`ft_help`, `ft_settings` and `ft_filedialog` all end the same way: `clear screen; ft_redraw_all
"$FT_ROOT"`. The application underneath **has not changed** — the modal ran a nested event loop
over a different root. So every entry validates.

```
derive : css-demo page 1, warm full repaint            199–229 ms   (measured, three runs)
re-emit: 33 stored blocks appended in paint order        1.7–2.0 ms (measured)
         the same frame as one concatenated string       0.55–0.70 ms
```

The append cost is linear and measured at **32–38 ns/byte**; an 18 KB frame is ~0.6 ms of pure
string work. This is where the order of magnitude actually is, and it is not a corner case: open
help, close help; open settings, close settings; dismiss a file dialog; dismiss a toast.

### 8.3 A page tour: 29.2 s → 21.3 s (1.37×), or 12.9 s → 4.9 s (2.6×) excluding placement

From §2.3 directly. The unflattering number is the true one for "browsing an app": most of the
remaining cost is the callout's placement search, which is `docs/placement-cost-model.md`'s
problem, not this one.

### 8.4 Typing: ~1×

The field genuinely changes and re-derives; its neighbours were never being repainted. Retention
neither helps nor hurts. (The one part that was already retained — the frozen sheen ring — stays
retained, just by a general mechanism instead of a bespoke one.)

### 8.5 The honest summary

> An order of magnitude on frames that are pure re-derivation of unchanged content: ~120× on a
> modal close, ~11× on a drag frame if the mover declares a move and ~3× if it does not.
> One-and-a-half to two-and-a-half times on ordinary page navigation. Nothing on typing.
>
> Not 10× on average, and anyone who quotes the 120× as the headline is quoting the best case.
> The two figures a sceptic should press on are the drag repair estimate (§8.1, the only
> number here that is not a measurement) and whether the move hint is obtainable (§12.1).

---

## 9. What it costs, and what a test would not catch

**The complexity, plainly.** One more cache with a hand-maintained token, joining `_FT_SGR_CACHE`,
`_FT_CLIP_CACHE`, `ft_wrap_cached`, `FT_SHEEN_FROZEN` and `_FT_TRANSITION_FRAME`. CONTRIBUTING §1
says two ways to do one thing is a bug with a delayed fuse, and *six* memoised paint caches with
six tokens is worse than one. The defence is only good if the design **subsumes** rather than
joins: `FT_SHEEN_FROZEN` and `_FT_TRANSITION_FRAME`'s live path must be deleted (§10), and
`_FT_SGR_CACHE`/`ft_wrap_cached` become inner caches consulted only on a miss, which is a
demotion. If a reviewer finds all six still standing after this work, the work failed.

**Four things that would go wrong and that a test would not catch:**

1. **A frozen animation matches a static screenshot.** `_ft_compose_sgr`'s comment already says
   this: leave the animation phase out of the key and every animation freezes, and a golden
   screenshot happily passes. The retained token must carry `FT_ANIM_PHASE` for animating controls
   and the gate must be a *sequence* of frames that must differ, not a frame that must match.
2. **Two blank screens compare equal.** CONTRIBUTING §4. A retention bug that emits nothing looks
   exactly like a page with nothing on it. Every retention assertion needs a companion proving ink
   was drawn — the `test-residue`/`test-stale` lesson, which took two extra days the first time.
3. **The stale entry that a full repaint used to launder.** §3.3's hazard class. Today a missing
   dirty mark is invisible after the next `ft_refresh`; under retention it becomes a screen that
   is wrong until something else touches the control. This is the failure users will report as
   "it sometimes shows the old value" and it is the hardest to reproduce.
4. **Order drift.** §2.1 holds *today*. A future painter that reads another control's paint state,
   or an overlay compositor that interleaves, breaks the concatenation property silently — the
   frame still looks right when everything is derived, and wrong only when something is served
   from cache. The equality assertion from migration step 2 must stay in the suite permanently,
   not be scaffolding that is removed once step 3 lands.

**And one thing that is simply unknown**: memory. 139 pieces × ~129 bytes of text, plus a block per
control, is ~40 KB for a page — trivial. A 4,000-line markdown viewer is not a page; a textfield
that paints 40 rows of a large document holds 40 pieces, not 4,000, because it only paints what is
visible. I believe the structure is bounded by the *screen*, not by the document, but I have not
measured a pathological case and it should be measured before step 3.

---

## 10. What I would delete

A design that only adds is suspect. Retention makes the following unnecessary:

| deleted | why | measured value |
|---|---|---|
| `_ft_damage_fill`, `_ft_dfill_hit_build`, `_FT_DFILL_CUTS/HIT/BG/PAD`, `_FT_DHIT_*` | "what is underneath" is a lookup, not a re-derivation | 4.0 ms + 1.1 ms per drag frame (8.3 ground runs a frame here; ~130 per settle by its own comment) |
| `_ft_damage_dirty_multi` and `FT_DAMAGE_NARROW` | nothing needs to decide *which controls* to repaint over a refill; the row index answers directly | 0.5 ms/frame, and three carefully-argued skip rules that each began as a reported residue bug |
| `_ft_erase_rect` and `_ft_effective_bg`'s use by it | same reason | 69.4 ms → 0.6 ms was a fix; 0 ms is better |
| `FT_SHEEN_FROZEN` + `FT_SHEEN_FROZEN_SIGNATURE` | a bespoke retained list for one control's border ring, with a bespoke key | one raw `FT_OUT` bypass, and one class of key-omission bug already paid for |
| `_ft_transition_capture_ground` + `_ft_transition_parse` on the **live** path | the ground is in the list; there is no need to re-paint it into bytes and parse the bytes back into spans | its own comments: ~90 ms per ground read; 8,354 ground bytes → 1,841 and a 91 ms → 12 ms parse were the *optimisation* |
| fifteen of the sixteen `clear + ft_redraw_all` copies | one `ft_repaint_all` | 16 call sites → 1 |

The transition entry is the one to dwell on. `ft-transition.bash` already contains a span model —
`_FT_SPAN_ROW_START`, `_FT_SPAN_COLUMN`, `_FT_SPAN_WIDTH`, `_FT_SPAN_TEXT`, `_FT_SPAN_STYLE`, a
top-down resolve with claimed intervals, and a display-width-aware slice — and it exists *only
because the renderer keeps no record of what it drew*, so a layer's appearance has to be
reconstructed by parsing the escape stream back into cells. Its own comment says so: "The
framework keeps no cell buffer (the span renderer of docs/rendering-spans.md is a design, not
code), so what a layer looks like cannot be looked up. But the bytes we emit ARE the answer."

That is the strongest single argument in this document. The span model is not speculative here.
It was built, measured, and shipped — backwards, from the bytes — because the forward version did
not exist.

---

## 11. What I would do first, and it is not this

§1.3: a control repaint is ~92% property resolution. `ft_resolve` — the framework's most-called
function, 596 calls in one layout pass of a 21-control tree by its own comment — **has no memo of
its computed value.** It has fast paths (a `[[ -v ]]` probe for a local value, a gate that keeps
non-declared properties out of the cascade, an inlined property-key normalisation), and they are
good, but every call for an inheriting property with no local value walks the ancestor chain from
scratch. Measured: 139–174 µs for `textAlign`/`visibility` against 86–89 µs for `overflow`, which
does not inherit.

The lever is `rendering-spans.md`'s own `ft_computed_style` idea, minus the spans: **memoise the
resolved value per `(control, property)` under the token the cascade already maintains.** The
invalidation surface is the cascade's own, which is already per-node, already subtree-scoped
(`_ft_css_inval`), already gated, and already documented — the same machinery `_FT_SGR_CACHE` uses
one layer up.

Why it should come first:

* It helps **every** frame, including the ones retention cannot help — a control that genuinely
  changed still asks twelve questions.
* It helps **layout**, which retention does not touch at all and which is the thing that decides
  whether page changes ever get fast (`rendering-spans.md` §8's honest caveat, still true).
* Its invalidation surface is strictly smaller than retention's: it is a subset of the cascade's,
  with no geometry, no clip, no paint order, no bypasses.
* Rough arithmetic: if a warm read went from ~145 µs to ~15 µs (one composite-key hash read plus
  the call, measured at 2.2 µs and 2.5 µs respectively), a label repaint goes 2.74 ms → ~1.0 ms
  and a drag frame's 58 `ft_resolved_prop` calls go 8.4 ms → 0.9 ms. Call it **2–2.5× on everything**, for
  a fraction of the risk.

It also composes: with both, a drag frame's un-hinted chip re-derive falls from 6.8 ms to ~2.5 ms
and §8.1's pessimistic case improves from ~3× to ~5×.

If there is budget for one piece of work, it is this one. If there is budget for two, do this one
first and retention second, because retention's ceiling is higher but its floor is set by exactly
the work this removes.

---

## 12. Open questions I could not close

1. **Does the move hint survive contact with the beacon?** §8.1's ~11× depends on a moving control
   declaring "my ink is unchanged, only my origin moved". The measurement (§2.2) says the drag
   ghost's ink *is* unchanged, but that is observed after the fact, from the bytes. Whether
   `_ft_beacon_mouse_drag` can assert it *before* the draw — and whether any other mover can — I
   did not establish. If it cannot, the drag win is ~3×, not ~11×.
2. **Is 92% property resolution universal, or a property of small controls?** It is measured on a
   label, a frame and a form. A table or a markdown viewer may be dominated by its own text
   handling. `tools/bench-textfield.bash` exists and I did not run this decomposition against it.
3. **The 22-piece row.** One row of the css-demo carries 22 pieces (the key legend). The closure in
   §6 is bounded by pieces-per-row, so a pathological row — a syntax-highlighted line, a dense
   table — could make repair on that row expensive. `FT_ROW_STRIDE` overflow (emit the row whole)
   is the escape hatch `rendering-spans.md` §4 already proposes, and I have not costed the
   threshold.
4. **`ft_resolved_prop` at 145 µs versus its comment's 62 µs.** I am confident in the measurement (it
   reproduces in two scenes, and the decomposition of a label repaint closes to within 10% using
   it), and I believe the comment is measuring `ft_resolve` alone — which I measure at 53 µs, very
   close to its 62. But the two should be reconciled by whoever owns that function before §11 is
   costed for real.
5. ~~**The 120-column form.**~~ **SETTLED, 2026-09-05 — and it was the harness.** The form was
   120 columns because `demo/_perf.bash` set `FT_COLS` *after* sourcing the demo that had already
   built it; the demo is correct, there is no border, and `box-sizing` is not implicated. See the
   correction in §1.2. What was real underneath it: `ft_display_truncate` walked one character at
   a time where `ft_display_width` sliced wholesale, which cost 2 ms on a 118-column row and 64 ms
   → 51 ms on a repaint that truncates for real. Fixed; `tests/test-displayscan.bash` holds it,
   `tools/bench-display-scan.bash` prices all three scans side by side so the next divergence
   between them shows up as three numbers that stopped matching.

   The lesson worth keeping is about the instrument, not the form. **A headless harness that
   writes `FT_COLS` down instead of telling the app is measuring a screen the app has never
   heard of**, and it will keep producing plausible, reproducible, wrong numbers — this one was
   reproduced twice by independent probes, and both inherited the same line ordering.
6. **Memory under a large document.** §9's last paragraph. Believed bounded by the screen; not
   measured.

---

## Appendix — how to reproduce every number

All probes were run under WSL (`rocky`), bash 5.2.26, from the repository root, one at a time.
The repository's own instruments (`tools/bench-drag.bash`, `tools/bench-cascade.bash`,
`tools/bench-render-primitives.bash`, `demo/_perf.bash`) supply the calibration; the rest were
written for this document as standalone scripts in `/tmp` and are described here precisely enough
to be rebuilt.

| § | probe | method | teeth |
|---|---|---|---|
| 1.1 | stage breakdown | the drag bench's drive with `FT_BURST_LOG` set; counting wrappers around `ft_print_at`, `ft_print_at_width`, `ft_draw_one`, `ft_resolved_prop`, `_ft_clip_for`, `_ft_compose_sgr` | the bench's own guards: the chip must move and each frame must paint |
| 1.1 | statement count | a `DEBUG` trap with `set -T` | a 1,000-iteration empty loop must count ~3,000 |
| 1.1, 8.1 | pieces per control per frame | set a `CURRENT` marker in an `ft_draw_one` wrapper and tally every `ft_print_at`/`ft_print_at_width` against it, with an "(outside any draw)" bucket | the bucket must stay empty, or the attribution is incomplete — and it is what found the release's 248 pieces |
| 1.2 | per-control derive | capture the walk order, then time N repaints of each control alone | three warm full repaints reported first, so a first-paint placement search cannot pass as steady state |
| 1.2 | the 81 ms form | count every call `ft_draw_one app` makes; time `_ft_draw_form` with the clip open and closed | the two timings must differ by exactly the truncation — **and this teeth check passed while the finding was wrong**: it proved the clip caused the cost, which was true, and never asked whether the clip was where the screen actually is. Add: `ft_own_prop app width` must equal `FT_COLS`, and `_ft_clip_for app` must end at `FT_COLS - 1` |
| 1.3, 11 | property costs | 2,000 warm calls per property, empty-loop floor subtracted, in two scenes | measured in a bare app *and* under css-demo's sheets, because `ft_resolve` routes differently |
| 2.1 | concatenation | intercept `ft_draw_one`, capture each block, compare the join with the frame | the reversed join must differ; a second repaint must be byte-identical |
| 2.2 | drag waste | classify each frame's block against the previous one as identical / translated / new | the chip must never classify identical |
| 2.3 | hit rate | a `STORE` keyed by name, forgotten on `ft_remove`, over a 13-page tour with 4 step changes each | draw, change the text, draw again → exactly one hit and one miss |
| 3.3 | invalidation | snapshot every control's would-be bytes, mutate, run the engine's own settle, snapshot again; `CHANGED \ DRAWN` | a deliberate "change it, then clear `FT_DIRTY`" must appear as a hazard — and an earlier sabotage that poked the property variable did **not**, because the cascade memo absorbed it |
| 3.1, 6 | row density | count pieces per row over a full page repaint | — |
| 5 | slicing | 118-column row, plain / styled / CJK, through `${s:i:n}`, `ft_display_truncate`, `ft_display_width` | the empty-loop floor is printed beside the results |
