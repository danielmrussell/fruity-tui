# Unicode art: drawing a big arrow with smooth diagonals

The brief for `variant=bigarrow` was one sentence long and it was the whole job:

> *"Make sure it does its best to find a glyph that can be used to create long diagonal
> lines across the screen (versus the naive approach of just filling text cells with solid
> blocks and then creating a giant arrow with giant jaggies)."*

This is what was evaluated, what was measured, what was chosen, and — the part this
project cares about more — what was **refuted**. Two of the brief's own leading candidates
lost, and one of them lost by producing *no improvement at all*.

Everything below is a number off this machine. The probes live in `tools/glyph-probe/`.

---

## 0. The question is not "which glyph draws a diagonal"

It is: **a big arrow is a filled shape, and what you see is its BOUNDARY.**

A hairline diagonal and the shallow edge of a filled wedge are different drawing problems
and they want different glyphs. Almost every "smooth lines in a terminal" technique in the
wild (drawille and friends) is solving the first one. This is the second one. That single
distinction decides the entire evaluation, and getting it backwards is how you end up with
braille.

So the metric throughout is: **sample the true shape at 8×8 sub-cells per cell, ask each
technique for a glyph, and count how many of those 64 sub-cells it gets wrong** — averaged
over the cells on the boundary (interior and exterior cells are free for everyone). Call it
the *boundary error*. Solid blocks score 24.94/64. Perfect would be 0.

---

## 1. The aspect correction, measured rather than assumed

"A terminal cell is about 1:2" is the load-bearing constant of the whole exercise, so it
was read out of the actual font metrics (`hhea`/`head`/`hmtx`) rather than believed:

| font | advance | line height | **cell aspect w : h** |
|---|---|---|---|
| **CaskaydiaCove Nerd Font Mono** (this machine's Windows Terminal face) | 1200 | 2380 | **1 : 1.983** |
| Cascadia Mono / Cascadia Code | 1200 | 2380 | 1 : 1.983 |
| Consolas (what `ft-conhostfix` pins for classic conhost) | 1126 | 2398 | 1 : 2.130 |
| Lucida Console (conhost's default) | 1234 | 2048 | 1 : 1.660 |

**The correction applied:** every dimension of the arrow is defined in *visual units*,
where one unit is one cell **width**, and **one cell row is `FT_BIGARROW_ASPECT` units
tall** (default 2). The rasteriser multiplies every row delta by that factor before it
tests the shape. Nothing in the geometry is expressed in "cells" on both axes.

Concretely, this is the difference between an arrowhead with a 26° half-angle and one with
a 46° half-angle — a neat dart versus a blunt spade — and it is invisible until you put the
two side by side, which is exactly the failure mode the brief warned about ("wrong in a way
that is hard to name").

Lucida Console at 1:1.66 is off enough to matter, which is why the factor is a variable and
not a `* 2` in the middle of a loop.

---

## 2. Display width: measured on every candidate, believed

`ft_display_width` on every glyph of every candidate family, including all 256 braille
patterns and all 60 sextants:

```
  box diagonals            n=3    all-one-column=yes   ╱ ╲ ╳
  quadrants                n=15   all-one-column=yes   ▘ ▝ ▖ ▗ ▚ ▞ ▙ ▟ ▛ ▜ ▀ ▄ ▌ ▐ █
  left eighths             n=8    all-one-column=yes   ▏ ▎ ▍ ▌ ▋ ▊ ▉ █
  lower eighths            n=8    all-one-column=yes   ▁ ▂ ▃ ▄ ▅ ▆ ▇ █
  triangles (corner)       n=4    all-one-column=yes   ◢ ◣ ◤ ◥
  braille (all 256)        n=256  all-one-column=yes
  sextants (all 60)        n=60   all-one-column=yes
  -- the control --
  CJK / emoji              n=2    all-one-column=NO (2 wrong)   世 🙂
```

Every candidate measures one column. The control measures two, so the probe has teeth.

### …but the framework's table is not the terminal's

`ft_display_width` resolves East-Asian **Ambiguous** as narrow. A terminal configured
`ambiguous-width: double` will not. So the honest question is which candidates are
Ambiguous — from `unicodedata` 15.0:

| family | East-Asian class | if a terminal doubles Ambiguous |
|---|---|---|
| box diagonals `╱ ╲ ╳` U+2571–2573 | **A** | 2 columns — breaks |
| block elements U+2580–258F (halves, **eighths**) | **A** | 2 columns — breaks |
| corner triangles `◢◣◤◥` | **A** | 2 columns — breaks |
| quadrants U+2596–259F | N | safe |
| braille U+2800–28FF | N | safe |
| sextants U+1FB00– | N | safe |

This is *not* a reason to pick braille, and it took a minute to see why: **the framework
already draws every border it has ever drawn out of U+2500–257F, which is Ambiguous.**
112 of the 128 code points in that block are class A. Ambiguous-as-narrow is a standing,
project-wide assumption that every frame on screen already depends on. A technique that
inherits it adds no new risk; a technique that avoids it buys nothing back, because the
border around the arrow breaks anyway.

So width is **not** a discriminator here. It removes what looked like braille's advantage.

> **One correction to the brief, recorded because it is the kind of thing that gets
> repeated:** U+2612 ☒ measures class **N** (Neutral) in `unicodedata` 15.0, not Ambiguous.
> Whatever made the callout's close box render wrong yesterday, the East-Asian width table
> does not say it was its width class. Worth re-deriving before that reason is reused.

---

## 3. Font coverage: measured, not assumed

There is no `fontTools` on this box, so `tools/glyph-probe/cmap.py` is a small sfnt reader
(table directory → `cmap` formats 4 and 12). Counts are *code points actually present*:

| family | **CaskaydiaCove NF Mono** *(this machine's WT face)* | Cascadia Mono | **Consolas** *(what conhostfix pins)* | **Lucida Console** *(conhost default)* |
|---|---|---|---|---|
| box diagonals `╱╲╳` | 3/3 | 3/3 | 3/3 | **0/3** |
| halves `▀▄▌▐█` | 5/5 | 5/5 | 5/5 | 5/5 |
| lower eighths `▁▂▃▄▅▆▇` | **7/7** | 7/7 | **1/7** | **1/7** |
| left eighths `▏▎▍▌▋▊▉` | **7/7** | 7/7 | **1/7** | **1/7** |
| quadrants `▖▗▘▝▚▞▙▟▛▜` | 10/10 | 10/10 | **0/10** | **0/10** |
| braille U+2800–28FF | **256/256** | 256/256 | **0/256** | **0/256** |
| **sextants** U+1FB00–1FB3B | **0/60** | 0/60 | 0/60 | 0/60 |
| smooth mosaic U+1FB3C–1FB6B | **0/48** | 0/48 | 0/48 | 0/48 |
| **octants** U+1CD00–1CDE5 | **0/230** | 0/230 | 0/230 | 0/230 |

### What that settles immediately

**Sextants and octants are out, and not on a judgement call.** Zero of 338 code points
across all four fonts, including the 11,172-glyph Nerd Font. The brief said "check before
relying" — checked; there is nothing there. Windows Terminal does synthesise some box and
block glyphs itself when a font lacks them, but I could not verify from this side whether
that extends to U+1FB00, and a technique whose viability rests on an unverified terminal
feature is not a technique.

**Braille is present in Cascadia and absent from Consolas and Lucida Console.** Which means
it is exactly backwards from where this project needs robustness: it works on the modern
terminal that works anyway, and vanishes on the classic console `ft-conhostfix.bash` exists
to rescue. Same for quadrants and eighths, which is a real cost, not a free pass — see §7.

---

## 4. Braille, refuted on the picture

Braille has the best numbers on paper: 2×4 sub-cells, and on a 1:1.983 cell each dot is
0.5 × 0.5 units — **perfectly square sub-pixels**, the only family here that manages it.
That is a genuinely strong argument and it is why the technique is famous.

Here is the same arrow drawn with it, 30 cells long, aspect-corrected, next to quadrants:

```
BRAILLE 2x4                          QUADRANTS 2x2
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢠⣀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀                     ▗▄
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸⣿⣿⣷⣦⣄⡀⠀⠀⠀⠀⠀⠀                     ▐███▄▄
⣤⣤⣤⣤⣤⣤⣤⣤⣤⣤⣤⣤⣤⣤⣤⣤⣤⣼⣿⣿⣿⣿⣿⣿⣷⣦⣄⡀⠀⠀    ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▟███████▄▄
⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡷⠆    █████████████████████████████
⠛⠛⠛⠛⠛⠛⠛⠛⠛⠛⠛⠛⠛⠛⠛⠛⠛⢻⣿⣿⣿⣿⣿⣿⡿⠟⠋⠁⠀⠀    ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▜███████▀▀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸⣿⣿⡿⠟⠋⠁⠀⠀⠀⠀⠀⠀                     ▐███▀▀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠘⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀                     ▝▘
```

**Braille cannot draw a filled region.** `⣿` is all eight dots and it is still eight round
dots with gaps between them and a gap to the next cell — a halftone screen, not a fill. A
big arrow rendered in braille is a *stipple* of an arrow. Look at the shaft: quadrants give
you a solid bar, braille gives you corduroy. Look at the tip, `⡷⠆` — that is not a point,
it is two dots and a smudge.

And the edge is not even smooth: braille's dot pitch is *coarser than the glyph box*.
Measured edge profile of the top barb (how far the boundary jumps between adjacent
columns): braille `max jump 8 sub-rows, distinct steps [0, 1, 8]` versus quadrants
`max jump 4, steps [0, 1, 4]`. The 2×4 grid buys resolution that the round, separated dots
then throw away.

Braille is the right answer to *"draw me an arbitrary-angle hairline curve"*. It is the
wrong answer to *"fill me a wedge"*. Rejected on the picture, not on font support — the
font support is merely the second reason.

---

## 5. Box diagonals, refuted by producing literally no change

`╱ ╲ ╳` (U+2571–2573) was the brief's first candidate: one cell each, exactly one cell
across per cell down, tiles into a clean unbroken line.

Add them to a best-match palette and the boundary error **does not move**:

| palette | mean boundary error /64 |
|---|---|
| solid `█` only | 24.94 |
| + halves `▀▄▌▐` | 4.23 |
| + quadrants | 3.71 |
| **+ box diagonals `╱╲`** | **3.71** — *unchanged* |
| **+ corner triangles `◢◣◤◥`** | **3.71** — *unchanged* |
| + eighths | 2.84 |
| + eighths, fg/bg invertible | **1.97** |

Not "a small improvement". Zero. The best-match rasteriser was free to pick `╱` for any
cell on the arrow and **never once did**, at any size. Two independent reasons:

1. **A diagonal glyph is a stroke, not a fill.** Its ink covers ~8 of 64 sub-cells. Against
   a cell that is 60% filled it is wrong 50-odd times out of 64. It can only ever draw the
   *outline* of a shape, and then only where that outline happens to run at its one angle.
2. **It has exactly one angle, and it is the wrong one.** One cell across per cell down,
   aspect-corrected, is 63.2° on this machine's font. A big arrow's barbs are *shallow* —
   a head 12 cells long and 7 rows tall has barbs at about 30°. `╱` cannot draw 30°. It can
   draw 63.2° and nothing else, and a chain of `╱` at any other angle is a staircase of
   diagonal ticks: the same jaggies the brief is trying to avoid, wearing a diagonal hat.

The corner triangles `◢◣◤◥` fail identically and for reason 2 alone (they *are* fills, but
only at 45° in cell space = 63.2° on screen).

There is one arrow shape they would draw beautifully, and it is worth naming so the idea is
not re-attempted by accident: an **outline chevron** whose barbs are pinned to 63.2°, i.e.
a `»`. That is a different control from "a big filled arrow", it locks the head angle to
whatever the reader's font aspect happens to be, and it looked thin and incidental next to
a filled wedge at every size tried.

---

## 6. What won: one anchored eighth-block per cell, plus fg/bg inversion

### 6a. The insight

The arrow is convex on the cross-axis. For a horizontal arrow, **each column of the shape
is one continuous interval of rows** — top edge to bottom edge, nothing in between. Clip
that interval to one cell's eight sub-rows and you get a *contiguous run of sub-rows*, and

* a run anchored to the **bottom** of the cell **is** a lower-eighth block `▁▂▃▄▅▆▇`;
* a run anchored to the **top** of the cell is the *same glyph painted foreground/background
  swapped*.

So the whole rasteriser is: per column, compute two edge positions in eighths-of-a-row;
per cell, subtract; index a nine-entry table. **No per-cell search, no per-cell sampling,
eight integer operations.** Vertical arrows are the same thing transposed, with left-eighth
blocks `▏▎▍▌▋▊▉`.

That last point is not a detail. The exhaustive best-match that produced the table in §5 is
30 glyphs × 64 sub-cells × every cell — seconds of bash for one arrow. The scanline form is
affordable enough to build inside a paint.

### 6b. The gap in Unicode that makes inversion necessary

Unicode has **lower** eighths and **left** eighths. It has **no upper eighths and no right
eighths** in the Block Elements — only the ½ (`▀`, `▐`) and the ⅛ (`▔`, `▕`). So exactly
one of an arrow's two barbs gets 8 levels and the other gets 3, in *every* orientation:

| arrow points | top / left barb | bottom / right barb |
|---|---|---|
| right or left | fill is *below* the edge → `▁▂▃▄▅▆▇` ✔ 8 levels | fill is *above* → **missing** |
| up or down | fill is *right* of the edge → **missing** | fill is *left* → `▏▎▍▌▋▊▉` ✔ 8 levels |

An arrow with one crisp barb and one chunky one does not read as "slightly coarser". It
reads as **broken** — the eye finds the asymmetry instantly even though the mean error is
lower than the symmetric quadrant version. This is why the 2.84 row in §5's table is not
the answer despite beating quadrants' 3.71.

Unicode did eventually fix this: **U+1FB82–1FB86 are the upper eighths and U+1FB87–1FB8B
the right eighths**, added in Unicode 13's Symbols for Legacy Computing. Measured:

```
   middle vertical eighths U+1FB70-75   0 of 6      (all four fonts)
   middle horiz eighths    U+1FB76-7B   0 of 6      (all four fonts)
   UPPER eighths           U+1FB82-86   0 of 5      (all four fonts)
   RIGHT eighths           U+1FB87-8B   0 of 5      (all four fonts)
```

**0 of 22, in all four fonts, including the 11,172-glyph Nerd Font.** The glyphs that
would solve this exist and are in nothing.

So the missing family is synthesised the way terminal image viewers already synthesise
sub-cell colour: **paint the complement with the colours swapped.** "Top ⅜ in arrow colour"
is `▅` (lower ⅝) drawn `fg = ground, bg = arrow`. That restores all 8 levels in both
directions from one 7-glyph family, and it is what takes the error from 2.84 to 1.97 —
and, more importantly, makes the arrow symmetric.

### 6c. The one case that is still a lie

A run that touches **neither** edge of a cell — a thin bar floating in the middle — is
`U+1FB76–1FB7B` (horizontal) or `U+1FB70–1FB75` (vertical), and those are the same 0-of-12
as above. It happens where the arrow is thinner than one cell: at the very tip, and on
small arrows.

Two fallbacks, in order:

1. If the run is roughly **centred** and thin, use the box-drawing rule `━` / `┃` — those
   *are* centred in their cell by construction, and they are in every font measured
   (Lucida Console included). This is where box drawing finally earns a place: not for the
   diagonals it was nominated for, but for a centred thin bar.
2. Otherwise extend the run to the nearer edge and take the smaller lie.

Recorded so it is not re-attempted as a bug: the tip of a small arrow **is** approximate,
and no glyph in any of these fonts fixes it.

### 6d. The numbers it ships with

Boundary error, mean sub-cells wrong out of 64, aspect-corrected, several sizes. `SUB=8`
is what ships; `SUB=2` is the `smoothing=halves` rung; "exhaustive" is the unreachable
best-match ceiling from §5, shown so the shortcut in 6a is priced honestly:

| arrow | rows | solid `█` | `smoothing=halves` | **`smoothing=eighths` (ships)** | exhaustive ceiling |
|---|---|---|---|---|---|
| 10 cells | 3 | 14.14 | 13.57 | **8.43** | 7.57 |
| 14 cells | 3 | 17.80 | 13.00 | **8.20** | 7.00 |
| 20 cells | 5 | 16.30 | 14.80 | **3.60** | 2.50 |
| 30 cells | 7 | 24.94 | 5.00 | **3.45** | 1.97 |
| 44 cells | 11 | 17.81 | 12.10 | **8.38** | 3.71 |
| 60 cells | 13 | 19.52 | 8.58 | **2.64** | 1.76 |

**Solid → eighths is a 3× to 7× reduction in boundary error**, and the scanline shortcut
costs 1–5 sub-cells against a rasteriser that is three orders of magnitude slower.

Two honest dents in that table:

* **Small arrows stay coarse** (8.43 at 10 cells). Three rows is three rows; there is no
  glyph technique that rescues an arrowhead two rows tall. The variant enforces a floor and
  refuses to draw below it rather than drawing a bad one.
* **The 44-cell row is worse than its neighbours** (8.38 against 3.60 and 2.64). That is a
  *quantisation* artefact of that particular size — the shape's centre lands on a cell
  boundary instead of a cell centre, so every cell straddles the axis. Not fixed. It is a
  half-row phase term and belongs in the size chooser, not the rasteriser.

### 6d(i). And here it is

30 cells, `smoothing=eighths`. `~` marks a cell painted fg/bg swapped:

```
                 ▄▂                   :                 --           :
                 ███▇▅▃▁              :                 -------      :
▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄███████▇▅▃▁          :----------------------------  :
████████████████████████████▁▃        :----------------------------~~:
▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄███████▁▃▅▇          :~~~~~~~~~~~~~~~~~-------~~~~  :
                 ███▁▃▅▇              :                 ---~~~~      :
                 ▄▆                   :                 ~~           :
```

The top barb `▇▅▃▁` is drawn in native lower-eighths; the bottom barb `▁▃▅▇` is the same
four glyphs painted swapped. The shaft is ~2.1 rows thick and renders at eighth-of-a-row
precision, which is why it has a clean edge instead of a 2-or-3-row staircase.

---

## 7. The honest cost of the choice

**Eighth blocks are absent from Consolas and Lucida Console** (1 of 7 each — just the half).
Quadrants and braille are absent from both entirely. On the classic Windows console this
arrow degrades, and there is no way to detect it from inside the process: the framework's
only signal is `FT_USE_UTF8`, which says nothing about which glyphs the *font* has.

The mitigation is a declared quality ladder, one property, one constant, one table:

| `smoothing=` | sub-positions per cell | needs | boundary error @30 cells |
|---|---|---|---|
| `eighths` *(default)* | 8 | `▁▂▃▄▅▆▇` / `▏▎▍▌▋▊▉` | 3.45 |
| `halves` | 2 | `▀▄▌▐` only — **every font measured** | 5.00 |
| `solid` | 1 | `█` — the naive approach, kept so it can be looked at | 24.94 |
| *(no rung)* | 1 | `#`, forced when `FT_USE_UTF8=0` | 24.94 |

`smoothing=halves` is the Consolas/Lucida rung and it is not a token gesture: the fg/bg
inversion still applies, so it stays symmetric, and 5.00 against solid's 24.94 is most of
the win from the two glyphs every font on earth has.

This is the same failure mode the framework's heavy box borders already have on Lucida
Console, and it has the same fix — `bash tools/conhost-font.bash apply`. Note that even
that only reaches `halves`: Consolas has no eighths either.

---

## 8. Summary of the evaluation

| candidate | angles it can draw | width | in fonts here | carries colour | **verdict** |
|---|---|---|---|---|---|
| box diagonals `╱╲╳` | **one**: 63.2° on this font | 1 col (class A) | 3/4 | 1 fg | **rejected** — stroke not fill; added 0.00 to the palette |
| corner triangles `◢◣◤◥` | one: 45° in cell space | 1 col (class A) | 2/4 | 1 fg | **rejected** — same, added 0.00 |
| braille 2×4 | any | 1 col (class N) | 2/4 | 1 fg per cell | **rejected** — cannot fill; halftone shaft, no tip |
| quadrants 2×2 | any | 1 col (class N) | 2/4 | 1 fg | viable, 3.71 — beaten and needs a family Consolas lacks anyway |
| sextants / octants | any | 1 col (class N) | **0/4** | 1 fg | **rejected** — 0 of 338 code points present |
| half blocks + fg/bg | any | 1 col (class A) | **4/4** | **2 sub-cells** | **shipped as the `halves` rung** |
| **eighths + fg/bg inversion** | any | 1 col (class A) | 2/4 | **2 sub-cells** | **CHOSEN** — 3.45 vs 24.94, symmetric, O(1) per cell |
| box drawing `━ ┃` | n/a — a *centred* thin bar | 1 col (class A) | 4/4 | 1 fg | **kept**, for the one case §6c names |

The headline, stated the way the brief asked for it: the glyph that draws long smooth
diagonals across the screen is **not a diagonal glyph**. It is a horizontal one, chosen at
eighth-of-a-cell precision, with the colours swapped when the fill is on the wrong side.

---

## 9. Two things the implementation found that the analysis did not

### 9a. The cross-axis cell count decides whether the tip is exact

The row count of a horizontal arrow must be **EVEN**, and it is the tip that decides it.

With an **odd** number of rows the arrow's axis falls in the *middle* of a cell, so the
converging tip is a run touching neither edge of that cell — precisely the case §6c has no
glyph for — in the single most-looked-at cell of the whole arrow. Measured on a 30-cell arrow
at 7 rows: the last two cells of the tip were `▂` and `━`, the `▂` an "extend to the nearer
edge" lie that reads as the tip drifting upward.

With an **even** count the axis falls on a cell *boundary*, the tip straddles two cells, and
each half is an anchored run the eighth blocks draw **exactly** — down to one eighth above the
axis and one below, which is a point.

> **This was got wrong once, on purpose, and the author's eye caught it in a day.** When the
> shape stopped being solved (§12) the argument was made that an authored tip does not need
> the even count, because a person draws the tip rather than a rasteriser rounding to it — so
> the sprites were drawn ODD, to buy the shaft a true centre row. That is a misreading of what
> §9a is about. The even count is not about the *solver*; it is about the **glyph set**, which
> still cannot draw a run floating in the middle of a cell however the run got there. The odd
> sprites ended in a full cell followed by a mid-height `━` bar, and the report on them was
> "none of them look pointy at all". Even rows, and the tip converges.

### 9b. The available room is not a target

The first working version limited the arrow only by the space available. A target near the
right edge of a 100×30 screen therefore got an arrow **68 cells long and 14 rows tall** —
five sixths of the width and half the height. That is not a pointer, it *is* the screen.

A cap (`FT_BIGARROW_MAX_VISUAL = 30`) fixed the symptom and left the disease: the arrow was
still a different shape in every window. §12 is the fix.

---

## 10. Getting out of the way — two exits, built and compared

> *"Dude that's awesome. But it should fade out or something. It's in the way after a bit."*

A huge arrow is the right amount of emphasis for a second and the wrong amount after ten. So a
bigarrow **retires by default** — `lifetime=persist` is now the deliberate choice rather than
what you get by forgetting, which is the opposite of how the other beacon variants default and
is on purpose: a ring or a badge is one cell of chrome, this is two hundred.

Its life is `fly → hold → exit → gone`, and **each stage is its own animation**. That is not
tidiness either. One 20 fps animation spanning all three would tick ~85 frames of nothing
through a 2.4 s hold, at ~15 ms each — this framework's own definition of input lag. The hold is
a **two-frame animation whose single frame is the whole wait** (`animation-delay` item 2, less
the flight), so the entire wait costs *one wakeup*:

| stage | frame cost | wakeups |
|---|---|---|
| fly (20 frames) | 13.5–14.4 ms | 20 |
| **hold (2400 ms)** | **0.15 ms** | **1** |
| exit — retract (12 frames) | 17.8–21.6 ms | 12 |
| exit — fade (12 frames) | 6.2 ms | 12 |

Both exits were built. Here is each one's filmstrip, 30-column arrow, `│` marks the target:

```
exit=retract                                  exit=fade   (timing item 2: linear)
frame col  alpha                              frame col  alpha
 0    38   100     ███████████████│            0    38   100    ███████████████│
 2    40   100      ██████████████│            2    38    82    ███████████████│
 4    44   100       ████████████│██   ← leans 4    38    64    ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓│
 6    42   100      █████████████│█       IN    6    38    46    ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒│
 8    29   100  ███████████████   │            8    38    28    ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒│
10    -4   100 █████████████      │           10    38    10    ░░░░░░░░░░░░░░░│
11   -30   100                    │           11    38     0                   │
```

**Retract ships.** Three reasons, in order of weight:

1. **It clears the page.** A fade dissolves *in place*, so for its last third there is a large,
   dim, arrow-shaped smudge lying across the content — a milder version of the complaint it is
   supposed to answer. Retract's ink is gone from the page before it is gone from existence.
2. It is the grammar the arrow is already speaking. With an `-back` curve it leans a few cells
   **toward** the target and then whips out — the anticipation beat of a cartoon take, and it
   costs nothing: the same offset machinery as the bounce, the same vacated-strip damage, no
   colour arithmetic at all.
3. It needs no colour to be readable. The fade lerps through `_ft_sgr_rgb`/`ft_rgb_sgr` (the
   shimmer effect's technique) and needs a 256-or-truecolour foreground **and** background to
   look like anything; where either end cannot be read the fade is skipped rather than guessed.

Fade is kept, and is one property away (`exit=fade`) — it is the better choice over a busy
background, where a large object sliding across is more disruptive than one dimming out.

### Two things measured while building the exits

* **The last frame of a stage is spent transitioning, not painting.** With the animation exactly
  as long as its curve, the final *painted* frame was the second-to-last point on it. Invisible
  on the fly (the curve has flattened); not invisible on the retract, where the last frame
  anyone saw had the arrow at column −4 with **26 columns still on screen**, and then it
  vanished — the exact pop the graceful exit exists to avoid, one frame from the end. Both
  animations are one frame longer than their curve.
* **A fade wants `linear`.** The default exit curve — `animation-timing-function` item 2,
  `ease-in-back` — suits a retract
  and is wrong for a fade: an `-back` curve winds backward before it goes, which is anticipation
  when something is about to move and merely a pause when it is about to dissolve. Opacity over
  the twelve exit frames — `ease-in-back` spends six at full opacity, `ease-in` spends eight,
  `linear` is a fade.

### …and one bug that was not mine

Rebuilding a control under the same name — *the* rebuild idiom this framework documents, and
what the demo page does on every step — resolved the **dead** control's cascaded style.
`ft_remove` unset the node's cache version, so the replacement started at 0 again, climbed
through the same values as it applied the same number of style-affecting properties, and landed
on the token the previous incarnation's entry was stored under. Reproduced on a bare label:

```
ft-label name=lbl color=accent ; ft_style lbl color  →  accent   (version 3)
ft_remove lbl                                        →  version unset
ft-label name=lbl color=notice ; ft_style lbl color  →  accent   ← the dead one's
```

The comment above `ft_css_forget` explicitly claimed this could not happen. It is why stepping
from the retracting arrow to the fading one gave the fade the retract's timing curve. A
forgotten name now **keeps** its version and takes it one higher; compaction still reclaims it,
because that drops the composite entries in the same pass. Gated in `tests/test-css.bash`.

---

## 11. What is NOT settled

* **`smoothing=halves` is untested on the fonts it exists for.** The rung was built because
  the cmap probe says Consolas and Lucida Console have no eighths. Nothing here has *seen*
  it in either of those fonts — no font rendering happens on this side of the pty. What is
  verified is that it emits only `▀▄▌▐█`, which those fonts do have.
* **Windows Terminal's built-in glyph synthesis is unverified.** WT draws some box and block
  elements itself when the font lacks them, which would make the coverage table pessimistic
  for U+2500–259F. Whether it extends to U+1FB00 (which would resurrect sextants) I could
  not determine from here. Worth a look at a real terminal before the sextant rejection is
  treated as permanent.
* **The floating-run fallback is still a lie.** §6c: a thin bar centred in a cell has no
  glyph, and on a *small* arrow (10–14 cells, 3–4 rows) that case is not confined to the
  tip. The 8.43 and 8.20 rows in §6d's table are mostly this.
* **The tip is half a row off a target of odd height.** An even-row arrow cannot centre
  exactly on a 3-row control. Visible if you look for it; nobody has.
* **Colour is one resolution per paint, not per cell.** The reversed cells swap to
  `_ft_effective_bg` of the beacon, which is right over a uniform ground and wrong over a
  control with its own background. A per-cell ground probe exists in the engine
  (`_ft_damage_fill`'s run resolution) and was not wired up: it is a tree scan per run, and
  this is on the typing path. `exit=fade` inherits the same approximation.
* **The arrow and a callout negotiate by paint order, and I stopped rather than solved it.**
  Both avoid the other's published ink, so whoever places first takes the good lane. Measured at
  118×40 on the tour's arrow page: placed with no chip on screen the arrow takes a 30-column
  lane; re-placed after a resize with the chip already there, the same call yields a 9-row stub
  pointing up (the candidate dump has right/left burying 40–44 cells against up's 0). Both are
  correct answers to different questions. The page pins `place=left` so the picture is
  deterministic, which is a workaround at the page level, not a fix at the engine level. A real
  fix is a single placement pass that positions every overlay together.
* **`_BIGARROW_BURY` is calibrated on one page.** 200 hundredths-of-a-visual-unit per buried
  normal cell was swept over `0 50 100 200 400 800 1600` on a deliberately crowded layout: the
  choice does not move below 800 there, so 200 is inside a wide flat region rather than on a
  measured optimum. It is a knob with a plausible value, not a tuned one.
* **`exit=fade` over a control with its own background** blends toward the beacon's effective
  background, so the last frames will be the wrong colour there. Not seen, because the demo
  fades over a uniform stage.

---

## 12. The shape stopped being computed

> *"I don't know why the arrow is trying to shrink or whatever depending on window size. But I
> increased it just to see. Still got garbage. Just make the arrow consistent."*

Two screenshots of the same app at two widths. At ~80 columns the arrow was a stub that reads
as a bar with a bump on it; at ~190 it was recognisably an arrow with a notch bitten out of the
shaft and a stray block under the head. Both were the rasteriser doing exactly what §6 says it
should. **The defect was that it was inventing a shape at all.**

Everything in §1–§9 about *which glyphs* stands, and is still what the sprites are drawn out
of. What is gone is the part that chose the geometry per window: a head angle, a head fraction
and a shaft fraction in milli-visual units, fitted to whatever length the placer could find,
rasterised fresh at every size. A shape solved per size looks hand-drawn at one size and broken
at the rest, and the one thing this variant must do is look **deliberate**.

### 12a. Four sizes, drawn by hand

`FT_BIGARROW_SPRITE` is a sprite sheet in the source: rows of glyphs a human reads and edits.
Nothing is fitted, scaled or rounded at paint time. Three exact numbers give every size its
geometry, and all three are chosen so the pixels land on the grid:

* the head's edge falls **2 sub-rows per column** (horizontal) or widens **one cell per side
  per row** (vertical). Both are `atan(0.5) = 26.57°` once the 1:2 aspect is corrected, and
  both are exact runs — every step of the staircase is identical to every other, which is most
  of what makes a hand-drawn shape read as regular.
* the head is exactly **half** the arrow's length.
* the horizontal sizes have an **even** row count, so the tip converges (§9a); the vertical
  ones have an **odd** column count, so the apex is one centred cell (§12e).

| `size` | long | horizontal | vertical | across | shaft |
|---|---|---|---|---|---|
| `small`   | 20 | 20 cols × 4 rows |  9 cols × 10 rows |  8 / 9  | 3 |
| `medium`  | 28 | 28 × 6           | 13 × 14           | 12 / 13 | 4 |
| `large`   | 36 | 36 × 8           | 17 × 18           | 16 / 17 | 6 |
| `x-large` | 44 | 44 × 10          | 21 × 22           | 20 / 21 | 8 |

**The two axes are the same length and one unit apart across, and that unit is forced.** A
horizontal arrow needs an EVEN row count so its axis lands on a cell boundary and the tip can
converge (§9a); a vertical one needs an ODD column count so its apex is a single centred cell.
Even and odd cannot both be had. One column in seventeen, against a tip that would otherwise be
blunt on one axis or lopsided on the other.

**The horizontal sprites are authored as their top half.** §6b is why: there are no upper
eighths in any font measured, so the bottom barb can only be drawn by painting its complement
swapped — and there is therefore no character to *author* it with. Writing U+1FB86 into the
source shows a box in every editor. So a horizontal sprite is drawn down to and including its
centre row and the loader mirrors it, flipping the anchoring. That also makes every one of them
symmetric by construction. The vertical sprites need no such trick — their only partials are
`▌` and `▐`, both real characters everywhere — so they are authored whole.

`left` is `right` read backwards and `up` is `down` with the rows reversed. Neither touches an
anchoring, which is not luck: each axis is authored in the family whose anchor lies *across*
it, so the flip that reverses the sprite is the one the anchoring is invariant under.

### 12b. `size`, with CSS's ladder and not CSS's name

The ladder uses CSS's own absolute-size keywords, because `font-size` is the one CSS property
whose purpose is to pick from a small discrete ladder rather than take a length — which is
exactly the shape of the answer here. The PROPERTY is `size`, not `font-size`: what is being
sized is a drawing made of cells, and calling it a font size is a lie about what it is. HTML
gives several elements a `size` attribute meaning exactly this. `beacon { size: large }`
cascades and inherits like anything else. The seven CSS keywords map onto the four rungs
(anything below `small` is `small`; `xx-large` is `x-large`); `larger`/`smaller` are relative to
a parent's computed size and are not accepted, because a ladder of drawings has no meaning for
them. A bespoke `arrowSize` was rejected as a new word for a thing CSS has named, and a length
was rejected because it reopens the door to the resizing this replaced.

**Unset means fit**: the placer takes the largest rung that fits the free space. **Named means
named**: that rung or nothing. Nothing ever deforms, and suppression was already a supported
outcome. `size` is deliberately *not* a prototype default — a prototype default is applied as
an inline
property, i.e. cascade level 1, so baking `medium` in would make a stylesheet rule permanently
unreachable and turn every screen with no room for a medium arrow into a screen with no arrow.

### 12c. The silhouette border

A border on this shape is not a box around it — it is the **outermost layer of the arrow's own
cells**. A cell is on the outline when one of the four cells sharing an **edge** with it is not
inked.

**Four neighbours, not eight, and the diagonal is why.** Eight-neighbour erosion also marks
every cell that merely touches the outside at a *corner*, which on a barb's staircase is the
cell under each step: the outline comes out one cell thick along the straight runs and two at
every step. Measured on `medium`, 28 × 6 — 58 outline / 22 fill at four neighbours, 64 / 16 at eight — but
the count is not the argument, the picture is. Four neighbours, then eight (`o` a whole-cell
rim, `-` a one-eighth hairline, `█` fill):

```
···············oooo·········       ···············oooo·········
···············-███-ooo·····       ···············o██ooooo·····
o--------------████████-oooo       oooooooooooooooo██████oooooo
o--------------████████-oooo       oooooooooooooooo██████oooooo
···············-███-ooo·····       ···············o██ooooo·····
···············oooo·········       ···············oooo·········
```

The eight-neighbour rim beats in and out along the barb by a cell per step. That is the one
edge this whole variant exists to draw smoothly.

**A cell has two colours and an edge cell has already spent both.** An eighth-block edge cell
is the arrow's ink anchored against the ground showing past it; there is no third colour to put
an outline in, and — §6b again — no glyph to draw one *outside* the edge with. So a **partial**
edge cell is repainted whole in the border colour. That is the honest reading of "the outermost
layer" anyway: such a cell is half in and half out of the shape, and its ink thickness is
already proportional to how much of the shape reaches it, so the rim is thin exactly where the
shape's edge is thin.

**A full cell on the edge is the opposite case, and it is the common one.** Where the boundary
lands on a cell boundary the edge cell is a solid `█`: no ground shows, so its second colour is
free. Repainting it whole spends a full cell on a boundary of zero thickness — and a horizontal
arrow's shaft is bounded by exactly such rows, so whole-cell outlining recoloured the **entire
shaft** and left a bright blob at the head. The fix is this variant's own trick: draw `▇` with
the arrow as foreground and the rim as background and the cell is ⅞ arrow under a ⅛ rim line.
One exposed side gets that hairline; a corner has no single anchor and stays a whole cell, which
is what an end cap should look like anyway.

Six paint modes carry it, each the reverse of its neighbour: ink on ground, ground on ink (the
synthesised eighth family), rim on ground, ground on rim, rim on ink (the hairline), ink on rim.
They are baked into the art at load, so a frame costs one extra run split and no per-cell work.

### 12d. An arrow that costs more than it is worth is not drawn

The old placer could always shrink its way out of trouble: the burial term pushed the length
down until the arrow stopped covering things — which is the deforming this replaced. A rung
cannot shrink, so without a floor the least-bad candidate wins however bad it is, and on a dense
stage that is an arrow lying across a textfield. The floor is the cost model's own arithmetic:
a candidate whose score goes negative (burying more cells than half the arrow's visual length)
is not drawn at all.

Measured on the callout tour, which is the densest layout here: **outside its own arrow page —
whose layout is built around a lane for it — there is no step at any supported terminal size
where a `small` arrow buries nothing.** At 118×40 the cheapest side of each step costs between
0 and 74 covered cells; at 56×34 the cheapest is 34. That is a fact about the demo's stages
rather than about the arrow, and it is why the tour uses the arrow on one page instead of five.

### 12e. The tip, and how any of this is checked

**A glyph dump cannot be read as a picture of this variant.** An upper-anchored cell is drawn
as a LOWER block painted fg/bg reversed (§6b), so a row of `▁` sitting under a row of `▇` is a
mirror *pair* and reads, to anyone looking at the characters, as violent asymmetry. That is
exactly what happened: shapes that are provably mirrored were reported as "not correctly
mirroring the top … torn up … tons of inexplicable defects".

So the shapes are judged in **ink**: for every cell, how many eighths are actually inked and
from which edge, with the reverse applied. `tests/test-bigarrow.bash` computes that map and
asserts on it, and the two assertions are the two complaints:

* **the mirror.** Row *r* and row *rows−1−r* must carry the same coverage in every column,
  anchored to the opposite edge (and column *c* against *cols−1−c* for a vertical arrow).
  **Measured across all sixteen sprites: 0 differing cells in 1952 pairs.** The gate carries
  its own teeth — a hand-broken cell must be seen — and its own anti-vacuity check, because
  "0 differing cells in 0 pairs" is what a broken map returns.
* **the tip.** The cross-section must narrow monotonically from the head base to the tip, in
  steps no larger than the authored slope, and end in a point. What "a point" is differs by
  axis, and the reason is the resolution:

| | resolution across | resolution along | sharpest honest apex |
|---|---|---|---|
| horizontal | eighths | whole columns | **2 eighths** — one above the axis, one below |
| vertical | eighths | whole rows | **one whole cell**, centred |

A vertical arrow's apex row cannot taper *within itself*, because a cell has no sub-row
resolution. A quarter-cell sliver was drawn there and measured: sharper by the number, worse by
eye, because the step into it was 14 eighths where every other step is 16 — a spike on the end
of a triangle. The single centred cell is the classic block-arrow apex and it is what ships.
