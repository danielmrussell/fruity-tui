# The span renderer (design)

Supersedes the damage-rect sketch in `rendering-damage.md`. That design tried to repair the
screen by re-deriving what *should* be under a rectangle. This one never has to ask: the
renderer keeps a record of everything it drew, so "what is underneath" is a lookup.

## 1. The idea in one paragraph

Controls do not write to the terminal. They call a small drawing API, which records **spans** —
one row's worth of styled text at a column. The recorded spans form a **display list**: a
retained, sparse model of the screen, ordered so that things on top come later. To update the
screen, the renderer takes the rows whose spans changed, resolves overlaps within each row so
every cell has exactly one winner, and writes only those cells. Escape sequences exist in one
place: the emit step.

## 2. Vocabulary

| Term | Meaning |
|---|---|
| **run** | `(text, style)` — text with no escape sequences in it, and a style handle |
| **span** | `(row, column, runs…)` — one row's worth of drawing, produced by one call |
| **display list** | every span currently on screen, indexed by row and by owning control |
| **style handle** | a small id standing for a resolved SGR sequence; interned |
| **paint order** | the order spans are drawn in; later wins where they overlap |

The invariant that makes everything else cheap:

> **A run's text never contains escape sequences.**

Width is then a property of the text alone — no scanning past ANSI to count columns — and two
runs can be merged into one write whenever their style handles match.

## 3. The drawing API

Coordinates are **relative to the control's own content box**. The engine sets a paint context
(origin, clip rectangle, z, owner) before calling a control's draw function, so a control never
computes screen coordinates and never thinks about clipping.

```bash
ft_draw_text   row column text style
ft_draw_runs   row column  style text  [style text]…      # styles vary within the line
ft_draw_fill   row column width height style [character]
ft_draw_hline  row column width  style [character]
ft_draw_vline  row column height style [character]
ft_draw_box    row column width height style              # border box, honours border-radius
```

`ft_draw_runs` is what makes styled text work without turning text into a tree. The
accelerator underline, a markdown paragraph with a bold word, a selection highlight, a sheen
sweeping across a label — all of them are one call with several runs:

```bash
ft_draw_runs 0 0  "$label_style" "Sa"  "$accel_style" "v"  "$label_style" "e"
```

An animation changes *which* runs get *which* style each frame. Nothing is inserted into the
control tree, and nothing mutates except the style handles passed to the next draw call.

### Computed style

A control asks for its resolved style once, not once per property:

```bash
ft_computed_style "$control"            # → FT_RET = style handle
ft_computed_style "$control" selection  # → the ::selection pseudo-element's handle
```

This is memoised per frame and invalidated by the existing scoped cascade versioning, and it is
the single most important performance change in this document — but not for the reason first
assumed. Measured (`tools/bench-cascade.bash`, bash 5.2):

| | cost |
|---|---|
| `ft_style` on a cache hit | 30µs |
| `_ft_css_query` on a cache hit | 40µs |
| `_ft_get_raw` (one property read) | 19.6µs |
| **`_ft_compose_sgr`** — what a paint calls to get its colours | **810µs** |

Composing the drawing escape, not resolving a property, is the expensive act: one call costs as
much as twenty-seven cached property lookups. A style handle is precisely a memoised
`_ft_compose_sgr`, so interning styles is worth doing **first and on its own**, independent of
spans. (An earlier draft of this document put a cached lookup at ~200µs and blamed the property
resolver; that was an unmeasured guess and it was wrong by 6×.)

## 4. Data layout

Bash punishes per-cell work. Measured on bash 5.2 (`tools/bench-array-access.bash`): a plain
array read costs ~1.3µs, a read whose key is built on the spot ~3.3µs. Touching all 4,720 cells
of a 40×118 screen once is therefore ~6ms of pure array traffic before any logic, and a realistic
per-cell body several times that — far past the frame budget. Every structure below is
consequently **per span**, never per cell.

Everything is an **integer array indexed by span id**. No delimited strings, no lists encoded as
text, and therefore no splitting or re-parsing anywhere in the hot path — the only strings stored
are the span's own text and the interned escape sequences.

```bash
# ── The span records: parallel arrays, indexed by span id ──────────────────────
FT_SPAN_ROW=()   FT_SPAN_COLUMN=()   FT_SPAN_WIDTH=()   FT_SPAN_TEXT=()
FT_SPAN_STYLE=() FT_SPAN_Z=()        FT_SPAN_OWNER=()

# ── Membership, as STRIDE-ADDRESSED FLAT ARRAYS ───────────────────────────────
# Bash has no arrays of arrays, but it does not need them: a fixed stride turns a
# 2-D index into one multiply-add. Linked lists are the WRONG emulation here —
# every hop is a separate subscripted read (~5-6µs) with no locality, and an
# insert costs three or four writes. A stride bucket costs one of each.
FT_ROW_SPAN=()              # [row * FT_ROW_STRIDE + i] → span id
FT_ROW_SPAN_COUNT=()        # [row]                     → how many spans in that row
FT_ROW_OVERFLOWED=()        # [row] → 1 if it exceeded the stride (emit that row whole)
FT_ROW_STRIDE=32            # spans per row before overflow; rows normally hold 1-5

FT_CONTROL_SPAN=()          # [control_id * FT_CONTROL_STRIDE + i] → span id
FT_CONTROL_SPAN_COUNT=()    # [control_id]                         → how many
FT_CONTROL_STRIDE=64

FT_FREE_SPAN=()             # a STACK of recycled ids (an array used as a stack,
FT_FREE_SPAN_COUNT=0        #  not a chain — allocation is one read, one decrement)

# ── Interned styles ───────────────────────────────────────────────────────────
FT_STYLE_SEQUENCE=()               # handle     → the SGR string
declare -A FT_STYLE_HANDLE         # SGR string → handle (interning lookup)
```

Appending a span to a row is `FT_ROW_SPAN[row*FT_ROW_STRIDE + count]=id` and a count bump.
Iterating a row is a consecutive walk of `count` slots. Removing one is a scan of at most
`count` entries with a shift-down — a handful of integer operations, because rows are short.
Order within a row is irrelevant: the resolver sorts by `z`, and `k` is small.

**Controls keep their string names as keys.** An earlier draft proposed integer control ids on the
assumption that an integer subscript beats a hashed string key. `tools/bench-array-access.bash`
says otherwise: on bash 5.2, a read by ready string key is ~1275ns against ~1346ns for an integer
subscript — the string is *marginally faster*, reproducibly. Bash indexed arrays are sparse
structures, not contiguous memory, so there is nothing to win. The refactor would have been
invasive, risky, and slightly negative.

What the same benchmark shows *does* cost money, and what this design must therefore avoid:

| pattern | ns/op |
|---|---|
| string key **rebuilt** on every access (`arr[control$i]`) | 3340 |
| composite key (`arr["$a"$'\x1f'"$b"]` — the cascade cache pattern) | 2759 |
| arithmetic inside the subscript (`arr[row*32+i]`) | 2558 |
| plain read with a key already in a variable | ~1300 |

**The expense is building the key, not the lookup.** So: hoist the stride base out of inner loops
(`base=$(( row * FT_ROW_STRIDE ))` once, then `FT_ROW_SPAN[base+i]`), and never construct a key
inside a loop that could have been computed before it.

**Overflow.** A row exceeding `FT_ROW_STRIDE` sets `FT_ROW_OVERFLOWED[row]` and is emitted whole
rather than resolved interval by interval. Rows normally carry one to five spans; only pathological
style density (a syntax-highlighted line with dozens of runs) reaches 32, and paying a full-row
emit there is cheaper than making the common case dynamic.

**Multi-style lines record several adjacent single-run spans**, not one span containing a run
list. Bash has no nested arrays, so a run list would have to be an encoded string that is parsed
at every emit and every slice — precisely the "text nonsense" this layout exists to avoid.
`ft_draw_runs` stays as the API; it simply records N flat spans, and the emitter merges adjacent
same-style spans back into one write.

**z** is assigned during layout as `overlay_tier * 1000000 + depth_first_index`, so paint order
is a plain integer comparison, stable between frames, and overlays need no separate mechanism —
they are simply spans with a higher tier.

## 5. Repainting a control

```
1. walk the control's span bucket           — the spans it currently owns
2. record each span's extent as dirty, remove it from its row bucket, free the id
3. run the control's draw function, which records new spans
4. record each new span's extent as dirty too
```

Nothing else. "What was underneath" is answered by the rows' remaining spans, which are still
in the display list. No erase, no re-derivation, and no caller-side footprint bookkeeping —
which is exactly the class of bug that broke three previous attempts.

Removing a control is step 1–2 with no step 3. Moving one is the same, since its new spans land
in different rows.

## 5a. The dirty set: column intervals, never whole rows

Bytes on the wire are the slowest part of the pipeline, so the dirty set is tracked at the
precision the data already has — a span's own extent:

```bash
FT_DIRTY_ROW=()   FT_DIRTY_FROM=()   FT_DIRTY_TO=()    # flat, parallel, appended
FT_DIRTY_COUNT=0
```

Every span added or removed appends one interval. Before emitting:

1. **Sort** by `(row, from)` — the list is small for an incremental update, which is the case
   that must be fast.
2. **Merge** overlapping intervals *and* intervals separated by a small gap. The gap threshold is
   the cost of a cursor jump: an absolute reposition (`\e[22;41H`) is ~8 bytes, so two intervals
   less than ~8 columns apart are cheaper emitted as one run than as two addressed writes.
3. **Emit** each merged interval: resolve only that row, clipped to those columns.

Rewriting a whole 118-column row to change one character would cost ~120 bytes plus styles;
this emits the changed cells plus one cursor move. That difference is the whole point.

**Escape hatch:** if `FT_DIRTY_COUNT` exceeds a threshold (a full rebuild appends hundreds of
intervals, and an O(n²) insertion sort on hundreds of entries in bash is worse than the thing it
saves), skip sorting and emit every row in full. Small changes stay surgical; wholesale changes
take the simple path.

## 6. Resolving a row

For each row in `FT_ROWS_TO_EMIT`, walk its spans **top-down** (highest z first), carrying a
small set of claimed column intervals:

```
claimed = ()
for span in row_spans sorted by z descending:
    visible = span.columns − claimed
    if visible is empty:            skip                  # fully covered
    else if visible == span.columns: emit whole span       # fast path, no slicing
    else:                            emit the visible pieces
    claimed = merge(claimed, span.columns)
```

Interval subtraction on one row produces at most two remainders per claimed interval, and a row
typically holds one to five spans, so this is arithmetic on a handful of integers.

**Slicing text by display column is the only expensive operation** — it walks characters,
because a column is not a byte or a character (wide CJK glyphs are two columns, combining marks
are zero). The two fast paths above exist so that only a *partially* covered span pays for it,
which happens at the edge of an overlay and nowhere else.

If a slice would cut a double-width glyph in half, that column is emitted as a space: a terminal
cell cannot show half a glyph. The character is untouched in the display list, and it renders in
full as soon as it is wholly visible.

## 7. Emitting a row

Collect the visible pieces, sort by column ascending (they are few), then write:

- **Cursor**: one absolute position per contiguous group; adjacent pieces continue without a
  new position.
- **Style**: track the sequence currently in effect and emit only what changes — a span whose
  style matches the previous one costs zero style bytes.
- **Frame boundaries**: wrap the whole frame in synchronised output (`\e[?2026h` … `\e[?2026l`)
  so the terminal shows no partial frame, and hide the cursor for the duration.
- **The caret goes last**: after every span, position the real terminal cursor where the focused
  control wants it, and show it again.
- **One write per frame.** The emit step is the only code in the framework that talks to the
  terminal.

## 8. Cost model

Measured primitives this budget is built from (`tools/bench-render-primitives.bash`):

| primitive | cost |
|---|---|
| bare function call | 2.6µs |
| call unpacking four arguments into locals | 11.1µs — **each assignment is ~2µs** |
| `buffer+="text"` on a growing string | 0.2µs — cheap, use it |
| `printf -v` then append | 4.5µs — avoid in the emit path |
| building one positioned, styled span string | 5.0µs |

The argument-unpacking figure shapes the API: `ft_draw_text` should read `$1 $2 $3` directly in
its hot path rather than copying them into named locals, and callers should batch where a single
call can express several spans. Ten spans per control across fourteen controls is ~150 calls —
1.7ms if each unpacks four arguments, 0.4ms if it does not.

| Stage | Complexity | Notes |
|---|---|---|
| record a span | O(1) | ~3–11µs depending on argument handling |
| repaint a control | O(spans it owns) | typically 1–10 spans |
| resolve a row | O(k²), k = spans in row | k is 1–5 |
| slice a span | O(characters) | partial overlap only |
| emit a row | O(visible pieces) | one write per contiguous group |
| **layout** | O(nodes), ~4ms per control | **not addressed here — see below** |

Targets, against today's measurements:

- **Incremental update** (an overlay moves, a character is typed): a handful of rows, a handful
  of spans — comfortably under 10ms, which is the regime the "15ms, no stuttering" goal lives in.
- **Full repaint** of a busy screen: ~25–30ms, down from ~82ms, mostly by eliminating the
  per-property cascade cost. Not 15ms, and it never will be — that is bash string throughput.

The honest caveat: **layout is untouched by this design** and still costs ~4ms per control, so a
page rebuild stays expensive. Layout caching (skip subtrees whose inputs are unchanged) is a
separate piece of work and is the thing that decides whether *page changes* ever get fast.

## 9. Code standards for this subsystem

The recent code in this repository is not good enough to learn from, and this subsystem is
where that stops.

- **Names spell the concept.** `column`, `visible_pieces`, `claimed_intervals` — not `cbl2`,
  `vp`, `cl`. Abbreviate only what is universal in this domain: `row`, `col` in tight numeric
  loops, `min`, `max`.
- **One job per function**, and the name says the job. A function that both computes and emits
  is two functions.
- **Comments say why, not what.** The code already says what.
- **No four-deep nested loops with flag-and-break control flow.** Extract the inner search.
- **Public `ft_…`, internal `_ft_…`**, with no exceptions, so a reader can tell the API surface
  from the machinery at a glance.

## 10. Migration

0. **Automate the render gate first.** A test that renders real pages and compares against
   recorded screens. Three rendering regressions in this project passed a fully green unit suite
   and were caught only by looking at a rendered frame by hand. The renderer rewrite is the
   change most likely to break rendering silently; doing it while the gate is manual would be
   choosing to repeat the same failure.
1. Style interning + `ft_computed_style` (the 810µs `_ft_compose_sgr` — the largest measured win,
   and it stands alone whether or not the rest of this design is ever built).
2. The span recorder, the display list, resolve, and emit — behind the existing paint path, so
   both can run and be compared.
3. Move controls onto `ft_draw_*` one at a time, simplest first (label, button), each one
   verified by rendering the real app and diffing against the previous renderer.
4. Delete the old paint path, `FT_OVERLAY` compositing, and the app-level erase juggling in
   `demo/css-demo.bash`.
5. Rewrite the demos as showcases of the declarative DSL, which is what they were always for.

## 11. Gate

Every step is verified by **rendering the real application and diffing the screen against the
previous renderer**, per page and per interaction — not by unit tests alone. The unit suite
passed at 43/43 while the screen was visibly broken, three times. A rendering change that is not
gated on a rendered screen is not verified.

## 12. Resolved design questions

**Multi-style lines record adjacent single-run spans** (§4), not one span holding a run list.
Bash has no nested arrays, so a run list is an encoded string that must be parsed at every emit
and every slice. Flat spans cost one record per style change; the emitter merges them back.
Stress case to measure when it lands: the markdown renderer, the most style-dense code we have.

**The dirty set is column intervals, not rows** (§5a). Row granularity would rewrite a whole
118-column line to change one character, and bytes on the wire are the slowest stage — the thing
to minimise, not the thing to be casual about. Intervals are merged when closer together than the
cost of a cursor jump (~8 columns), with a full-emit escape hatch for wholesale changes.

**Terminal scroll regions are rejected.** `DECSTBM` shifts *full-width* row bands, so it cannot
express a pane narrower than the screen (`DECLRMM` adds left/right margins but support is
inconsistent); it would drag any overlay crossing the pane along with the content; and it would
leave the terminal holding content at coordinates the display list believes are elsewhere —
reintroducing the "screen and model disagree" failure this design exists to eliminate. The saving
only applies to full-width, overlay-free panes, and we already emit just what changed.
