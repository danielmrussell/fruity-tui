# API naming — align with the DOM

Fruity TUI is "the CSS/DOM you already know, in bash." The public API follows the DOM's
**vocabulary** so a web dev can guess it, adapted to bash call-style (`fn name args`, no method
chains, `snake_case`, `ft_`/`ft-` prefix).

**The rule:** keep the DOM's noun/verb names **basically identical**. Deviate only when the DOM name
is genuinely painful (verbose or absent), never for taste. Don't invent novel names when a DOM one
fits. Don't import DOM verbosity. Lock names before apps depend on them — renaming later is churn.

## Mapping

| DOM | Fruity | Note |
|---|---|---|
| `createElement('label')` | `ft-label` (tag-as-command) | more HTML-like than `createElement` |
| `el.remove()` | `ft_remove name` | |
| `el.focus()` / `el.blur()` | `ft_focus name` / `ft_blur name` | |
| `el.classList.add/remove/toggle/contains` | `ft_classlist_add/remove/toggle/contains name cls` | |
| `el.matches(sel)` | `ft_matches name sel` | compound selectors |
| `el.closest(sel)` | `ft_closest name sel` → `FT_RET` | |
| `document.querySelector(sel)` / `All` | `ft_query sel [root]` / `ft_query_all sel [root]` → `FT_RET` | shortened — `querySelectorAll` is the DOM's own verbosity wart |
| `el.parentNode` / `el.children` | `ft_parent name` / `ft_children name` → `FT_RET` | |
| `getComputedStyle(el).p` | `ft_style name p` → `FT_RET` | DOM name is the verbose one; kept |
| `el.getAttribute(p)` / `el.p` | `ft_get name p` → `FT_RET` | |
| (no DOM equivalent — the resolver a control reads through) | `ft_resolved_prop name p [default]` → `FT_RET` | author value → app sheet → an ancestor's if the property inherits → class default → `default`, coerced. NOT called "computed": `ft_style` is the full five-level cascade and this deliberately is not it (was `ft_cprop`, where `c` meant "coerced") |
| `Object.hasOwnProperty` sense of *own* (not inherited) | `ft_own_prop name p` → `FT_RET` | the same read with the inheritance walk switched off; "own" is JS's own word for exactly this distinction (was `ft_cget`) |
| (no DOM equivalent — the resolver's raw half) | `ft_resolve name p` → `FT_RET` | the same walk with no default and no coercion. `ft_resolved_prop` **is** this plus those two steps, and is what controls call; `ft_resolve` is for a test or an engine path that wants the stored string exactly as resolved |
| (no DOM equivalent — the compositor is not exposed on the web) | `ft_publish_paint_rect name T L B R` | a draw that puts ink OUTSIDE its layout box says where, so `ft_damage_subtree` can give those cells back (was `ft_paint_rect`) |
| `el.classList.*` generalised (`DOMTokenList`) | `ft_tokenlist_add/remove/toggle/contains name prop token…` | any space-separated list property (`class`, a file dialog's `accept`); `ft_classlist_*` is this specialised to `class` (was `ft_plist_*`, which read as Apple's property-list format) |
| `el.setAttribute` / `className=` / `style.x=` | `ft-modify name p=v …` | three DOM setters merged; sets many at once |
| `el.style.setProperty('--x', v)` | `ft-modify name --x=v` | runtime custom properties |
| `new CSSStyleSheet()` / `replaceSync` | `ft_stylesheet name= style=` | whole-sheet register/replace |
| (no `deleteRule` equivalent) | re-register the sheet | the string-authored model covers it |

## Events

| DOM | Fruity | Note |
|---|---|---|
| `el.onactivate = fn` (on-property) | `onActivate=fn` at construction or `ft-modify` | SUGAR for add-listener: repeats accumulate (`onActivate=a onActivate=b` = two listeners); `onActivate=""` clears that event's listeners |
| `addEventListener('activate', fn)` | `ft_add_listener NAME activate fn` (or pair form `activate=fn`, variadic) | "listener" is the DOM noun; add/remove verbs for clarity |
| `removeEventListener` | `ft_remove_listener NAME activate fn` | |
| event object (`ev.target`, `ev.type`) | `$this`, `$FT_EVENT_TYPE`, `"$@"` = detail/value | bash-style: dynamic-scoped globals |
| `preventDefault()` | a listener returns NONZERO | all listeners still run; the action is cancelled |
| (storage) | the `eventListeners` plist (`activate=fn change=g …`) | our own list props are PLURAL; DOM-named ones (`class`) stay singular |

There is NO name-convention magic: a function named `<name>_on_<event>` is just a function —
wire it (`onEvent=fn` or `ft_add_listener`) or it never runs. (`<type>_on_children_complete`
is different: a CLASS-level lifecycle hook dispatched by type, part of defining a control class.)

## Property names

Constructor/`ft-modify` properties use the DOM's **camelCase** spelling (`accessKey`, `maxLength`,
`readOnly`, `selectedIndex`, `backgroundColor`); inside a stylesheet the same properties use CSS's
**kebab-case** (`background-color`) — `_ft_css_camel` maps between them, exactly like the DOM.

| HTML/DOM/CSS | Fruity | Note |
|---|---|---|
| `accesskey` / `el.accessKey` | `accessKey=K` | was `accel` — renamed |
| `style="color: red; …"` | `style="color: 201; font-weight: bold"` | inline declarations, parsed like `el.style.cssText`; custom props (`--x: v`) work |
| `border-radius` | `borderRadius=N` (cells) | was `borderRounded`; numeric like CSS — 0 square, ≥1 arc corners; radii >1 clamp to the terminal's one arc glyph (a richer glyph set could honour them later) |
| (n/a — variant look) | `variant=` (slider track/fill/blocks/dots; table grid/lines/minimal; beacon frame/number/callout) | freed `style` for its HTML meaning |
| `el.cloneNode(deep)` | `ft_clone SRC DST [deep]` → detached | descendants of a deep clone get generated names; listeners copy (deviation, documented) |
| `el.removeAttribute(p)` | `ft_remove_attribute NAME PROP` | truly unsets (≠ setting ""); falls back to sheet/class default |
| `overflow: auto\|scroll` on a container | `overflow=auto\|scroll` (vertical) · `overflowX=auto\|scroll` (horizontal) | children keep natural size; a viewport (scrollTop/scrollLeft) slides over them; scrollHeight/Width + clientHeight/Width published; a STABLE gutter (right column / bottom row) holds the proportional bar, drawn only while content overflows (NB: `overflowY` is the per-control own-scrollbar convention, not container scrolling) |
| `el.scrollTop = n` | `ft_scroll_set NAME N` | clamped; incremental subtree shift, no relayout (the fast wheel path) |
| `el.scrollTo(x, y)` | `ft_scroll_to NAME X Y` | both axes, same incremental path |
| `el.scrollIntoView()` | `ft_scroll_into_view NAME` | both axes, 'nearest'; runs automatically when focus lands on a control (like browser keyboard nav) |
| wheel scroll chaining | automatic | wheel over an inert spot scrolls the nearest pane; over a control whose class wheel-probe says "content fits" (label, textfield) it CHAINS to the pane, browser-style |

## Deliberate keeps (DOM name is worse or absent)

`ft-modify`, `ft_get`, `ft_style`, `ft_stylesheet`, `ft_refresh`, `ft-<type>` — kept because the DOM
equivalent is verbose (`getComputedStyle`, `getElementById`), absent, or the Fruity idiom is already
closer to the underlying markup model.

## Abbreviations: terms of art only

An abbreviation earns its place only when it is the **real name of the thing** in the domain the
reader is already in. `ft_sgr` is ECMA-48's Select Graphic Rendition, `ft_ease` is CSS's timing
function, `ft_hrule` is `<hr>`, `ft_kbd_*` is `<kbd>`, `ft_die` is the unix idiom — a reader of
terminal, CSS or shell code knows all of them on sight. `ft_pp`, `ft_ppw`, `ft_cprop`, `ft_cget`,
`ft_sgr_pe` and `ft_plist_*` were not names of anything; they were this codebase's own private
shorthand, and they are gone. **If explaining the name takes a sentence, the name is wrong**
(CONTRIBUTING §6).

## Verbs must be honest

An abbreviation makes a reader look the name up. **A verb that describes the wrong action makes
them not look it up at all**, which is worse, and no amount of surrounding comment repairs it.

`ft_paint_rect` painted nothing. It is a one-line setter recording where a draw had ALREADY put
ink, and it sat between `ft_damage` and `ft_damage_subtree`, which really do act — so the company
it kept argued for the reading that was wrong. It is `ft_publish_paint_rect` now: `publish` is the
verb its four call sites and `docs/rendering-damage.md` were already using in their prose, and it
names the audience (the compositor) as well as the act.

Rejected on the way there:

- **`ft_declare_paint_rect`** — `declare` is bash's own keyword for bringing a variable into
  existence, and `declare -A FT_PAINT_RECT=()` is literally a few lines above the definition. In
  a bash framework that word is spoken for.
- **`ft_published_ink`** — a noun phrase reads as a getter, which is the same disease in the
  other direction. And `ink` is already load-bearing elsewhere: `_ft_ink_<type>` is the hook a
  class defines when its ink is **not** its paint rect (a bigarrow publishes where it will land,
  not where it is mid-flight). Two names for two different things must not share the word that
  distinguishes them.
- **`ft_set_paint_rect`** — accurate, and it would have been fine. It says only that a variable
  moved, where `publish` also says who is listening and why anyone would call it.

## When `scrollHeight` / `clientHeight` are actually true

The pair is the DOM's own "did this overflow?", and the table above promises it for a
scrolling container. **When it becomes correct is not the same for every control**, and an app
that asks too early gets the previous frame's numbers rather than an error. Measured, on a
30-line body:

| control | after `end_ft_form` | after `ft_layout` | after a paint |
|---|---|---|---|
| container (`overflow=auto`) | *unset* | **30 / 6** | 30 / 6 |
| label (`maxHeight=6`) | 30 / 0 | 30 / **0** | 30 / 6 |
| textfield | *unset* | *unset* | 30 / 6 |

A container publishes them from its **arrange**, which is why it is right as soon as layout
has run — that is the behaviour to copy. A label publishes them from `_ft_label_metrics`, which
runs on the **draw**: its `scrollHeight` is right early because the text is measured early, but
its `clientHeight` is whatever the box was when the metrics last ran, and before the first
paint that is `0`. A textfield publishes from its draw too, and only from there.

So today: **ask after a paint, or ask a container.** `demo/tutorial-demo.bash` asks a label at
build time and reads the previous frame.

Fixing it properly means publishing from layout for every control that can overflow, and the
obvious shape — a per-class hook called from `_ft_pass_arrange` — is the one thing that
function's own comments rule out (*"a call is ~25µs and this is per control per pass"*). So it
wants a measurement first, not a patch.

**The pair is now load-bearing**, which raises the stakes on that row. `_ft_setprop` clamps
`scrollTop`/`scrollLeft` against it (`_ft_clamp_scroll`), so a control that publishes the pair
gets its offsets bounded on every route in and a control that does not gets none of it. That
is also why a childless control never takes the container branch of `_ft_pass_arrange` any
more: it published a `scrollHeight` of 0 — computed from children there are none of — over a
label's own answer.

### A textfield IS a scroll surface (closed)

It used not to be, in two halves. The first was the pair above: a 12-line value in a 4-row
`ft-textfield` painted a vertical bar while `ft_has_scrollbar tf` answered **no**, because that
function reads the published pair and a textfield published nothing — a control that draws a bar
and denies having one, which is precisely the disagreement `ft_has_scrollbar` exists to end.
That half closed when `for=` learned to read the pair: the draw publishes it now
(`_ft_textfield_publish_metrics`).

The second half was the offsets. They lived in two private tables, `FT_TEXTFIELD_VSCROLL` and
`FT_TEXTFIELD_SCROLL`, so the public names were inert:

    ft-modify tf scrollTop=5      the view stayed on line 1, while ft_get answered 5
    ft-scrollbar for=tf           steered nothing at all
    ft_state_save                 carried an offset nothing would restore from

They are `scrollTop` and `scrollLeft` now — ordinary properties, read through two accessors
(`_ft_tf_voff` / `_ft_tf_hoff`) and written through two more that go via `_ft_setprop`, which is
what bounds them against the published pair on every route in. The tables are gone rather than
kept beside them. What that buys, all of it measured in `tests/test-scrollbar-for.bash`:
`ft-modify tf scrollTop=5` moves the view, an out-of-range write clamps to the last page,
`ft-scrollbar for=tf` steers the field with no glue code at all, the field's own keys move the
same number the bar reads, and a state save carries the position like any other property.

Two things had to be got right on the way, and both are worth knowing:

- **Extent before offset.** `_ft_clamp_scroll` bounds an offset against the published pair, so
  a draw that wrote the offset before republishing the extent would clamp against the
  measurement it was replacing.
- **Write only when it changes.** The draw settles the offset every paint, and an unconditional
  property write bumps the control's write generation — which is what the retained display list
  reads to decide a block is stale, so a settled page would re-derive the field forever.
  `tests/test-retain.bash` counts derives per paint and caught exactly that.

The duplicate-bar hazard this section used to warn about does not arise: `_ft_inset4` reserves a
gutter for the `overflow` shorthand and `overflowX`, and a textfield declares the AXIS property
`overflowY`, so no container gutter is reserved beside the bar it draws itself.

### A `for=` scrollbar has no position of its own

It shows the target's. `_ft_sb_state` reads the offset off the target when `for=` names one, and
keeps the bar's own copy level with it, because the target can scroll by routes the bar never
hears about — its own keys, the wheel, an app writing `scrollTop` on it. Reading a private copy
meant the thumb stayed wherever the bar was last dragged to while the content moved underneath.

## Deliberate removals

`ft_prop NAME PROP [DEFAULT]` was `ft_resolve` plus a default — the uncoerced sibling of
`ft_resolved_prop`. When `ft_resolved_prop` inlined its body for speed, the wrapper stayed
public and stopped being called: three call sites survived, all in `tests/test-layout.bash`, all
passing `""` as the default, i.e. using nothing it added over `ft_resolve`. It is deleted, and
those three now read through `ft_resolve` directly.

Keeping it would have meant *documenting* a second, uncoerced way to read a property — and an
uncoerced read is the one that lets a colour name reach the screen unresolved and a text value
reach `(( ))`. Making it private (`_ft_prop`) would only have put an underscore on something no
engine path calls. It also carried an inverted exit status — measured at **1 when the property
was non-empty**, 0 when it was empty, where `ft_resolve` and `ft_resolved_prop` both return 0 in
every case. Three near-identical readers, one of them disagreeing silently about what success
means, is CONTRIBUTING §6's "bug with a delayed fuse" written out in full.
