# Fruity styling — the CSS cascade (reference)

A **theme is a set of stylesheets, written in actual CSS.** Fruity implements the core of
CSS — selectors, specificity, the cascade, custom properties, functions, pseudo-elements,
at-rules — dropping only what a terminal can't use. Every dynamic thing (colour, weight,
state, animation) flows through it; no control hand-writes terminal escapes.

Everything below is implemented and covered by `tests/test-css.bash`,
`tests/test-color-rgb.bash`, and `tests/test-theme.bash`.

---

## 1. Stylesheets

A stylesheet is an ordinary object; its `style=` property is a real CSS string.

```bash
ft_stylesheet name=app style='
    :root           { --accent: hsl(200,100%,60%); color: 255; }
    textfield       { border-color: 250; }
    textfield:focus { border-color: var(--accent); }
    .danger         { color: crimson; }
    #username       { color: 111; }
'
```

Re-registering a sheet under the same name **replaces** its rules in place (edit + re-apply
= live restyle). A theme is just a named stylesheet: `ft_theme name=… style='…'` registers
it; `ft_use_theme NAME` swaps it in as the default sheet and repaints.

**Editing a sheet repaints what it can style — the app writes zero repaint code.** This is
CSSOM's behaviour: replace a stylesheet's text and the style engine does selector-based
invalidation. On re-registration the engine collects the sheet's key selectors — from its
**old** rules and its new ones, because a removed rule must restyle the elements it used to
match — walks the tree once, and dirties every matching subtree (subtree, because inherited
properties and `var()` reach downward). A rule with no id/class/type key (`:root`, `*`) can
style anything, so the root repaints: the honest cost of editing a sheet that styles
everything.

Measured on the case that used to motivate app-side repaint lists (`demo/css-demo.bash`
page 3, a checkbox toggling a bare `textfield` rule): the app's three hand-picked subtrees
cost 23 ms — **and were wrong**, because the bare `textfield` rule styles the two code panes
too, and the hand list left them painted in the stale colour. Engine-side matching costs
63 ms and repaints everything the sheet actually reaches; the full repaint it replaces was
294 ms. A one-rule `:root` sheet queues a ~280 ms root repaint, which is why a hot path
should set a custom property on an element (`ft-modify n --x=v`) rather than re-registering
a `:root` sheet.

## 2. The cascade

Highest precedence first:

1. **inline** — a property set at the call site (`color=azure`) or via `ft-modify`.
2. **app stylesheets** — by CSS **specificity**, then source order.
3. **inheritance** — inherited properties (`color`, `visibility`, `cursor`, `text-align`,
   `font-weight`, `font-style`, and all `--custom` properties) take the parent's value —
   **unless the element's own class declares one** (see below).
4. **default stylesheet** — the theme (`ft-default`).
5. **class built-in default** — the control's last resort.

**A class default suppresses inheritance**, and that is CSS's own rule rather than a
convenience: an inherited value fills in only where the cascade produced nothing *for this
element*, and a class default is a declaration for this element. Without it a tree would take a
select's `cursor` — which is a **row index** to those controls and CSS's inherited `cursor` to a
stylesheet — and a button would stop centring its label inside a right-aligned container, which
its own class comment promises it does not. Exactly two of the 79 class-defaulted properties
inherit, and those are the two.

> **This list was aspirational until 2026-09.** Every default was *stamped onto the instance* at
> construction, which made it cascade level **1** — above every stylesheet — so the ladder ran
> in reverse end to end. Measured on an ordinary frame with `#fr { padding: 2; gap: 3; overflow:
> auto; flex-direction: column }` registered: padding 0, gap 0, overflow hidden, flex-direction
> row. All 79 properties that 26 classes default were unreachable from a stylesheet on every
> control; `border-color` worked only because nothing defaults it. Defaults now live in a
> per-class table and answer at level 5, where this list always said they did.
>
> **And the layout did not consult a stylesheet at all**, which was a second and independent
> fault — `#fr { width: 30 }` reached `ft_style` and not `ft_resolved_prop`, and `width` is not
> class-defaulted, so the inversion cannot explain it. The layout resolves through the cascade
> now, gated on whether any registered sheet declares the property (§9).

CSS `kebab-case` and constructor `camelCase` are the **same property** (`border-color` ≡
`borderColor`), normalised to one key.

## 3. Selectors

| Form | Example | Matches |
|------|---------|---------|
| type | `textfield` | controls of that type |
| class | `.primary` | the control's `class` property |
| id | `#username` | the control's `name` |
| pseudo-class | `:focus` `:disabled` `:enabled` `:checked` `:selected` `:editing` `:empty` `:root` | live state |
| attribute | `[type=text]` `[data~=x]` `[k^=v]` `[k$=v]` `[k*=v]` `[k|=v]` `[flag]` | a property's value |
| functional | `:is(a,b)` `:not(x)` `:where(x)` `:has(y)` | grouping / negation / relational |
| pseudo-element | `::border` `::selection` … (§6) | a structure inside the control |
| combinators | `a b` (descendant) `a > b` (child) `a + b` (adjacent) `a ~ b` (sibling) | structural relations |

The rest of the registered states, same syntax: `:unfocused` `:engaged` `:read-only`
`:read-write` `:visible` `:hidden` `:dragging`, and the textfield's other two runlevels
`:scrolling` and `:perusing`. A pseudo-class the state registry does not know NEVER matches,
and nothing warns you — so a name here must be one the code registers, which
`tests/test-docs.bash` now checks for every pseudo-class these docs advertise.

Specificity is CSS's (ids·10000 + classes/attrs/pseudo-classes·100 + types/elements);
`:is()/:not()/:has()` take their most-specific argument, `:where()` counts zero.

## 4. Colour values

Anywhere a colour is expected: an **xterm-256 index** (`203`), a **name** (`crimson`,
`dodgerblue`, `teal`, … — the 16 base names plus a curated slice of the extended CSS names),
**`#rgb`/`#rrggbb`** hex, **`rgb(r,g,b)`** / **`rgb(r g b)`** / **`rgba(…)`** (alpha ignored),
and **`hsl(h,s%,l%)`** / **`hsla(…)`**. Hex/rgb/hsl flow through the colour-depth pipeline
(24-bit on truecolor terminals, else the nearest 256/16/8 colour); names/indices stay 256.

`var(--name[, fallback])` resolves a custom property up the tree. Foreground role words
`accent` / `notice` / `muted` map to the theme's `--accent-text` / `--notice-text` /
`--muted-text` so text stays readable on any theme.

## 5. Properties

`color`, `background-color`, `border-color`, `border-style`, `font-weight: bold|normal`,
`text-decoration: underline`, and the animation properties (§7). A control paints its text
through one compose point, so `font-weight`/`text-decoration` work on any migrated control.

**`border-style` is one vocabulary for every control that draws a border**, normalized at the
write (`_ft_border_style`) so `ft_get borderStyle` can only ever answer a keyword something
draws:

| keyword | what it draws |
|---|---|
| `solid` (initial) | `─ │ ┌ ┐ └ ┘` |
| `double` | `═ ║ ╔ ╗ ╚ ╝` |
| `dashed` / `dotted` | `┄ ┆` / `┈ ┊` — matched pairs, so the two axes line up |
| `heavy` | `━ ┃ ┏ ┓ ┗ ┛` — the spelling of `border-width: thick` |
| `rounded` | `─ │ ╭ ╮ ╰ ╯` — the spelling of `border-radius: 1` |
| `none` / `hidden` | nothing, **and the box loses the cell** — CSS's used border-width of 0 |
| `groove` `ridge` `inset` `outset` | `solid`; a terminal has no bevel glyphs |
| anything else | `solid`; an unrecognised keyword reads back as the thing on screen |

**`border-width`** is the same shape. CSS takes `thin | medium | thick` or a `<length [0,∞]>`,
and a TUI border is always exactly ONE CELL — so a length answers only one question here, *is
there a border at all*:

| keyword | what it draws |
|---|---|
| `thin` (initial here) / `medium` | the light glyph set |
| `thick` | the heavy glyph set |
| `0` (also spelled `none`) | nothing, **and the box loses the cell** |
| any other positive length | `thin` — one cell is one cell |
| anything else | `thin` |

`none`/`hidden` and `border-width: 0` are answered in the BOX MODEL (`_ft_border`,
`_ft_inset4`), not in a draw function, which is why `border-style` and `border-width` are layout
properties while `border-radius` is paint-only — a TUI border is always exactly one cell, but
zero cells is still a size change.

**`border-glyph`** (`borderGlyph`, no CSS equivalent) tiles one decorative glyph across all four
sides and corners, one per cell — so it must be exactly **one column**. A two-column glyph would
paint twice the box, and there is no honest tiling of one into an arbitrary width, so it is the
one border value that cannot be corrected into something drawable: the declaration is dropped,
with a message.

## 6. Pseudo-elements (structures & item states)

Parts of a control that aren't separate controls. A `::pe` rule styles that structure only;
plain element selectors never see it.

- **Structures:** `::border`, `::caret`, `::caretro` (read-only caret), `::scrollbar`
  (thumb), `::selection`, `::keycap` / `::hint` (statusbar), `boxheader::border`.
- **Item states** (for list/grid controls): `::active` — the item the keyboard is on,
  spelled the same on every control that has one (`tabs::active`, `tree::active`,
  `textfield::active` = the caret's line) — plus `::selected`, `::tab` (tabs),
  `::header` / `::stripe` (table).

Each composes `background-color` + `color` + `font-weight`, and each can animate (§7).
Unstyled, a control is byte-identical to its built-in role.

`ft-boxheader` and `ft-heading` are ordinary controls, so they need no special case:
`boxheader { … }` and `heading { … }` style the text, `boxheader::border { … }` the
surrounding rule, and `#id { … }` out-specifies either.

> Historical note: these two were once *nameless immediate-mode painters* (along with
> `ft-title` and `ft-synopsis`), drawn at explicit row/column coordinates and given no
> identity in the tree. To let them obey `title { … }` at all, the engine carried a
> **detached type probe** — a synthetic off-tree element used purely to resolve a type
> rule. All four painters are gone (`ft-title` → `ft-frame title=`, `ft-synopsis` →
> `ft-statusbar status=`, the other two promoted to controls), and the probe went with
> them. Nothing in the framework styles by type without a real element any more.

## 7. Animation

**Everything is `@keyframes` — real CSS, no invented properties.** `animation: NAME` names a
`@keyframes`; runs live on the shared per-control loop; armed/disarmed automatically as the
cascade changes — so a **state-scoped** rule is per-event animation for free:

```css
button:focus { animation: pulse; }                 /* only while focused */
```

A `@keyframes` samples its per-property stops — `color`, `background-color`, `font-weight`,
and `opacity` — interpolating colours in RGB, stepping weight, dimming by opacity (toward the
element's background). `from`/`to`/`0%…100%`; a two-stop block glides; `0%==100%` loops.

```css
@keyframes glow { from, to { color: var(--glow-a); } 50% { color: var(--glow-b); } }
checkbox { animation: glow; }
```

**Themeable.** A stop may read a **custom property** with `var()`. The shared MECHANICS live
in one always-loaded base stylesheet; the THEMEABLE values are custom properties each theme
sets on `:root`; the ramps re-resolve when the theme changes. So an animation retints on a
theme swap without redefining it — and it *can* hardwire a colour, but usually shouldn't.

**Built-ins** (in that base stylesheet, so `animation: pulse|blink` is ordinary CSS):

- `pulse` — `@keyframes pulse { from,to { opacity: 1 } 50% { opacity: var(--pulse-min, 0.45) } }`.
  Uses **opacity**, so it dims whatever colour the element already has — adapts to any
  element/theme. The dim floor is themeable via `--pulse-min`.
- `blink` — an opacity on/off.
- `none` — an explicit off-switch (beats an inherited animation).

**`sheen` / `beacon`** are NOT `@keyframes` — they are the text-field border ROUTINES (they
animate glyph *geometry*, which colour keyframes can't express), referenced by name via
`textfield::border { animation: sheen }` (incl. per-event `:focus::border`).

**Speed:** `animation-duration: 2s` (or the shorthand `animation: glow 2s`) — `2s`, `1.5s`,
`500ms`. Structures animate the same way (`textfield::scrollbar { animation: glow }`,
`textfield::caret { animation: blink }`), sharing the control's loop.

---

## 8. The bigarrow's surface, and every deviation it makes

`variant=bigarrow` is the one control drawn out of *shapes* rather than text, so it is where
CSS's model has to be bent. Every bend is here with its reason.

| property | what it does to the arrow |
|---|---|
| `color` | the arrow's ink. Resolves through the ordinary cascade — inline, id, class, type, inheritance, colour names, `var()`, role words, a live `animation:` `@keyframes` — because the painter calls the same `_ft_color_override` every other control paints through. |
| `background-color` | the cell background the arrow states under itself, and the colour a swapped cell shows through its glyph. |
| `border-color` | the **silhouette** outline (docs/unicode-art.md §12c). |
| `border-width` | `0` / `none` removes the outline. |
| `border-style` | `none` removes the outline. |
| `size` | which of four authored shapes — `small`…`x-large` (§12b). |
| `animation-duration` / `-timing-function` / `-delay` | two-item lists: item 1 is the flight, item 2 is the exit. |

**Deviations, and why each one exists:**

1. **`border-color`'s initial value is `currentColor` *shaded*.** CSS says `currentColor`, and
   in a terminal an outline in exactly the fill's colour is not an outline. The initial value is
   therefore the arrow's own ink pulled back toward the ground behind it, which keeps CSS's real
   promise — the border follows the colour — in the only form the medium can show. Set
   `color: crimson` and you get a crimson arrow with a dark-crimson rim, not a crimson arrow
   wearing the theme's gold.
2. **`border-style` chooses nothing but on/off.** The outline's glyphs *are* the shape's own
   edge cells; there is no line to make dashed or dotted.
3. **`thin` / `medium` / `thick` all draw one cell**, which is the framework's existing border
   deviation ("a TUI border is always exactly one cell") applied unchanged — except that a full
   edge cell draws a **one-eighth** hairline rather than a whole cell, because it can.
4. **`border-width: 0`, `border-style: none` and `border-color: transparent` all work, from
   anywhere.** This entry used to record the opposite — that the first two were reachable only
   from a constructor argument or `ft-modify`, because `ft_control` class-defaults
   `borderWidth=thin` and `borderStyle=solid` and a class default outranked every stylesheet.
   That was true, it was measured (`#id { border-width: 0 }` registered, `ft_style id
   borderWidth` still `thin`), and it was a symptom of the inverted ladder in §2 rather than
   anything the arrow introduced. Fixed there; the workaround is gone with it.
5. **`size` is a keyword ladder, and a length is refused.** It takes CSS's absolute-size
   keywords (`small`…`x-large`) but is not called `font-size`: the thing being sized is a
   drawing made of cells, not type. A length is refused because it is what produced a
   different arrow in every window — see §12b.
6. **The theme's `--beacon-N` / `--locator-N` ramp is what `color` resolves to when nothing
   declares one**, so an unstyled arrow is byte-identical to before any of this. `effect=pulse`
   cycles *that ramp* while the arrow flies; a declared `color` holds on every frame instead,
   because the ramp is the default ink rather than an override of one.

**Deleted rather than layered on:** `beacon::arrow`. That pseudo-element existed for exactly one
reason — to give a per-instance colour to a control whose `color` did not work — and a structure
naming the whole element is a second word for `color` the moment `color` works. `::border`,
`::number` and the rest stay: those name a *part* of a beacon drawn in its own colour beside
other parts.

---

## 9. What the layout asks, and the gate

Painting resolves through the cascade. **Layout does too, but only for properties some
stylesheet actually declares** — `ft_resolved_prop`, `ft_own_prop` and the raw fast paths (`_ft_disp`,
`_ft_border`, `_ft_inset4`) consult cascade **level 2** when, and only when, the gate is open.

The gate is `_FT_CSS_DECLARED_PROPS`, accumulated by the stylesheet parser as rules register. It
exists because layout is nothing but property reads — `display` alone is asked **479 times** in
one layout of a 37-control page — and a cascade query on that path is not affordable. An app
with no layout rules has no layout properties in the table, so the gate never opens and a read
costs one associative lookup.

Three things worth knowing about it:

- **It adds level 2 only.** Levels 3, 4 and 5 are the inheritance walk and the class default
  that already follow it. Asking `ft_style` for all of them instead imported the **theme** for a
  control that declares no background of its own, and an unset background must stay a *hole*
  showing whatever is behind it (§ `_ft_color_override`, `tests/test-inheritpaint.bash`).
- **It is monotonic.** A property stays in the table once seen, even if the rule that mentioned
  it is replaced. That can only cost a memoised query that returns the same answer; it cannot be
  wrong.
- **`cursor` is excluded by name**, and it is the only exclusion. To a stylesheet it is CSS's
  inherited `cursor`; to a select, a table and a tree it is a **row index** that reaches
  arithmetic. That is a name collision, not a category — no other control-state default
  (`selectedIndex`, `open`, `scroll`, `expanded`, `activeTab`) shares a name with any CSS
  property, so the gate never opens for them. A *second* collision is the signal to split style
  properties from state properly, rather than to extend that exclusion.

**Cost, measured** (medians of 7; an unchanged tree measures ±20% run to run):

| | keystroke | css-demo step change | `ft_layout` alone |
|---|---|---|---|
| before | 5174 µs | 663 ms | 154.6 ms |
| class defaults at level 5 | 4924 µs | 413 ms | 230.5 ms |
| …plus the gated layout | 4848 µs | 451 ms | 258.2 ms |

The keystroke does not move. A step change is **32% faster**, because building a control no
longer stamps 24–79 properties through `_ft_setprop` and that saving outweighs the read cost.
`ft_layout` measured on its own is 67% slower — every defaulted property turned from a variable
hit into a miss — which is the number to watch, though it is a component of the step change
rather than an operation a user waits on.

### It *was* an operation a user waits on

That last sentence was wrong, and a reader found it before any instrument did: dragging a
callout stopped showing intermediate frames. A drag frame went 36ms → 44ms, and at 44ms the run
loop cannot keep up with a fast mouse. Neither committed benchmark could see it — a drag is not
a layout and not a property write — which is why `tools/bench-drag.bash` now exists.

The cause was not the price of a class-default read but the **number** of them. `_ft_inset4`
asked the table five times per control per pass, through five function calls, each with its own
sheet-gate read; it cost 115µs a call against 33µs before, forty calls a frame. The class's
answers cannot change once the class is registered, so they are now written down once, in the
order the readers consume them, and taken in a single read (`FT_CLASS_INSET_BOX` /
`FT_CLASS_MARGIN_BOX`). One flag replaces thirteen per-property gate reads while no sheet
declares a box property.

| | drag frame (median / max) | keystroke | css-demo step | `ft_layout` passes |
|---|---|---|---|---|
| before class defaults moved | 36 / 45 ms | — | — | 189 ms |
| the regression, as shipped | 43 / 54 ms | 1346 µs | 779 ms | 189 ms |
| with the box tuples | **41 / 51 ms** | 1346 µs | 778 ms | **162 ms** |

Every layout pass is 13–15% faster than before the fix, so a page step and a keystroke pay less
too. The drag does **not** return to 36ms, and the reason is worth writing down rather than
tuning at: a *memo* cannot help. Measured on this machine, an indirect variable read — the shape
any per-property memo takes — costs 6.07µs against the 6.66µs of the keyed read it would
replace. Nothing in bash makes a lookup cheap; only asking fewer times does, which is what the
tuple is. What remains is structural: the damage repair draws the dragged chip **five times in a
frame**, so 85 of the 148 property reads in one drag frame are a repeat of a (control, property)
already read in that same frame. Closing that means either not redrawing the overlay per damaged
rect, or a per-frame read cache — a new mechanism, whose invalidation surface is every property
write, every sheet registration, every class init, every reparent, and every state change a
selector can see.

---

## Status

The engine, cascade, selector set, colour formats, compose layer, pseudo-elements, and
animation above are implemented. **Every control and every structure** resolves through the
cascade — no control emits a raw theme colour. `@keyframes` animate arbitrary properties
(`color`, `background-color`, `font-weight`). The key legend and the status synopsis are two
separate one-row controls (`ft-keylegend` + `ft-statusbar`); stack them for the classic
two-row bar.
