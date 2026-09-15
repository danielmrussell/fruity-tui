# Fruity TUI

A small, dependency-free terminal-UI toolkit for **pure Bash**. No `tput`, no
ncurses — just raw ANSI, Unicode box-drawing (with an ASCII fallback), a
coproc-based input layer, and a themeable 256-colour palette.

Fruity TUI was extracted from the `samba-mago` setup wizard so its GUI machinery
could be reused across wizard pages and shared with the world.

> Status: **retained-mode engine.** Controls are declared as a tree of named
> elements with CSS-ish properties, laid out by flexbox and styled by a real
> cascade. The earlier positional/immediate-mode API is gone, as are the
> unimplemented scaffold controls — every control listed below is live.

## Layout

```
fruity-tui/
  ft-core.bash         # locale, glyphs, ANSI, palette, terminal lifecycle,
                       # resize, geometry, buffered draw primitives
  ft-inputlayer.bash   # the coproc input producer + ft_next_event consumer
  ft-forms.bash        # the engine: control tree, properties, flexbox layout,
                       # dirty/damage repaint, events, animation
  ft-css.bash          # the CSS cascade (stylesheets, selectors, var(), themes)
  ft-markdown.bash     # rich-text renderer for markdown=true fields
  controls/
    ft-frame.bash      # ft-frame        (bordered box; title= draws in the border)
    ft-boxheader.bash  # ft-boxheader    (3-row boxed section label)
    ft-heading.bash    # ft-heading      (1-row heading bar)
    ft-label.bash      # ft-label
    ft-keylegend.bash  # ft-keylegend    (the keycap row)
    ft-statusbar.bash  # ft-statusbar    (the status row)
    ft-button.bash     # ft-button
    ft-checkbox.bash   # ft-checkbox
    ft-radio.bash      # ft-radio        (group= makes a radio set)
    ft-multitoggle.bash# ft-multitoggle, ft-option
    ft-select.bash     # ft-select       (dropdown / listbox)
    ft-slider.bash     # ft-slider
    ft-scrollbar.bash  # ft-scrollbar
    ft-textfield.bash  # ft-textfield    (single line, textarea, markdown viewer)
    ft-table.bash      # ft-table, ft-table-column, ft-table-row
    ft-tabs.bash       # ft-tabs, ft-tab
    ft-tree.bash       # ft-tree, ft-treenode
    ft-beacon.bash     # ft-beacon       (floating callout / badge overlay)
  demo/
    hello-demo.bash    # the smallest complete program
    controls-demo.bash # non-interactive render of a full dialog
    css-demo.bash      # 10-page tour of the cascade
    runlevel-demo.bash # runlevels: inactive → scrolling → editing / perusing
```

## Layers & dependencies

1. **`ft-core.bash`** — depends on nothing. Safe to source first.
2. **`ft-inputlayer.bash`** — depends only on `FT_ESC_DELAY` from core (and
   tolerates being sourced first).
3. **`controls/*.bash`** — depend on core (draw primitives, palette, glyphs) and,
   where they handle keys, on the input layer's `ft_next_event`.

## Naming conventions

- **Public controls** use a hyphenated `ft-` prefix, e.g. `ft-button`,
  `ft-tree`, `ft-treenode`. (Bash allows hyphens in `name()` definitions.)
- **Public helpers / lifecycle** use `ft_` (underscore), e.g. `ft_init`,
  `ft_enter_tty`, `ft_next_event`, `ft_print_at`, `ft_fit`, `ft_wrap`.
- **Globals** use `FT_` — escapes `FT_ANSI_*`, colours `FT_COLOR_*`, glyphs `FT_GLYPH_*`,
  geometry `FT_ROWS`/`FT_COLS`/`FT_MEASURED_WIDTH`, draw buffer `FT_OUT`.
- **Internal** helpers use a leading `_ft_` and are not part of the API. This marks
  *internals*, so it never goes on something a user writes — a control class is declared
  by `ft_class_<type>`, with no underscore, because that is the authoring API.
- **Names are spelled out.** `FT_MEASURED_WIDTH`, not `FT_MW`; `FT_GLYPH_TOP_LEFT`, not
  `FT_G_TL`; `FT_COLOR_BORDER`, not `FT_C_BORDER`; `ft_textfield_select_end`, not
  `ft_tf_send`. If a name needs a comment to say what it holds, the name is wrong.
  The one deliberate exception is **`FT_RET`**, the return-value slot every helper writes
  — a single convention you learn once, not an abbreviation to decode each time.

This keeps the library from clobbering a host program's symbols when sourced.

## Quick start

```bash
source fruity-tui/ft-core.bash
source fruity-tui/ft-inputlayer.bash

ft_init                 # locale → glyphs → palette
ft_enter_tty            # alt screen, hide cursor, fd 3 = /dev/tty
FT_ON_RESTORE=ft_stop_input   # stop the coproc during restore
ft_install_traps
ft_start_input
ft_term_size

# ... draw with ft_print_at / ft_fit / ft_wrap, then ft_flush ...

while ft_next_event; rc=$?; (( rc == 0 )); do
    case "$FT_EVENT_TOKEN" in
        UP|DOWN|ENTER|ESC) : ;;     # handle named keys
        CHAR) : ;;                  # FT_EVENT_CHAR holds the literal character
    esac
    # redraw as needed
done
ft_restore_tty
```

`ft_next_event` returns `2` when a resize is pending (recompute layout via
`ft_term_size` and redraw), and `1` when the input producer has gone away.

## The input layer in one paragraph

A coproc reads `/dev/tty`, decodes bytes into named tokens (`UP`, `ENTER`,
`CHAR …`) and drops anything malformed. The caller narrows what it wants with
declarative control lines — `ft_input_ctl 'keys UP DOWN ENTER ESC'` and
`ft_input_ctl 'chars glob:[0-9a-fA-F.:/]'` — so each screen only sees the keys it
cares about. The filter is best-effort; consumers still ignore irrelevant events.

## Theming

Call `ft_setup_palette`, then override any `FT_COLOR_*` to re-theme, or replace the
function entirely. Every control draws through these names; nothing hardcodes an
escape, so a new theme is a handful of variable assignments.

## Control API

Controls are **declared, not painted**. Every control takes `name=` plus CSS-ish
properties; the engine lays them out (flexbox) and the cascade colours them. There
are no row/column arguments anywhere — an earlier positional API (`ft-title ROW COL
WIDTH TEXT`) has been removed entirely.

A bare argument is the control's content property (`text=` for most, `title=` for a
frame), so `ft-button name=ok OK` and `ft-button name=ok text=OK` are the same.

```bash
ft-form name=app width="$FT_COLS" height="$FT_ROWS" display=flex flexDirection=column
    ft-frame name=win title="Add Interface Wildcard" \
             display=flex flexDirection=column gap=1 padding=1 flexGrow=1
        ft-boxheader name=hdr text="Interface Wildcards"
        ft-div name=row display=flex gap=1
            ft-label     name=lbl text="Pattern:"
            ft-textfield name=pat value="eth*" flexGrow=1
        end_ft_div
        ft-div name=bar display=flex gap=2
            ft-button name=ok   OK   accessKey=K onActivate=save
            ft-button name=quit Quit accessKey=Q onActivate=ft_quit
        end_ft_div
    end_ft_frame
    ft-keylegend name=legend keys="Enter=Save  Esc=Cancel"
    ft-statusbar name=status status="Ready."
end_ft_form
```

**Containers** (open a nesting scope, closed by `end_ft_*`):

- `ft-form` — the root box.
- `ft-div` — a bare grouping box, no border or background (HTML's `<div>`). Set
  `display=flex` on it to lay its children out in a row or column.
- `ft-frame` — a bordered box; `title=` is drawn into the top border.
- `ft-tabs` / `ft-tab`, `ft-table` / `ft-table-column` / `ft-table-row`,
  `ft-tree` / `ft-treenode`, `ft-select` / `ft-option`.

**Leaves:**

- `ft-label text=` — static text; wraps, and scrolls when focusable.
- `ft-heading text=` — a one-row heading bar.
- `ft-boxheader text=` — a three-row boxed section label.
- `ft-button text= accessKey= onActivate=` — underlines the accelerator letter.
- `ft-checkbox`, `ft-radio group=` — a shared `group=` makes a radio set.
- `ft-multitoggle` — cycles through its `ft-option` children.
- `ft-slider min= max= value=`, `ft-scrollbar for=`.
- `ft-textfield value=` — single line; `rows=` makes it a textarea, `markdown=true`
  a scroll-only rich-text viewer.
- `ft-keylegend keys="K=Label  …"` — the keycap row; `keys=auto` derives the caps
  from the focused control's keymap.
- `ft-statusbar status=` — the status row. (It has no `keys=`; stack a
  `ft-keylegend` above it for the classic two-row bar.)
- `ft-beacon target= variant=` — a floating overlay drawn over the tree, pointing at
  a control. `variant=frame` rings it, `variant=number` badges it, `variant=callout`
  is a self-placing chip with a routed leader line, and `variant=bigarrow` is a giant
  arrow made of many cells that flies in along its own axis, holds for a beat, and then
  **retires** — `exit=retract|fade|none`, and the leaving is described by ITEM 2 of the CSS
  animation longhands it already reads item 1 of (`animation-duration: 560ms, 420ms`,
  `animation-timing-function: ease-out-back, ease-in-back`, `animation-delay: 0ms, 2960ms`) —
  two animations on one element is a comma-separated list in CSS, so this needs no new
  property names. `lifetime=persist` is the deliberate choice; leaving is the default.
  Its shape is one of **four sizes drawn by hand** in the source and never recomputed —
  `size: small | medium | large | x-large` — the property is `size` because the thing being
  sized is a drawing, not type, though the keyword ladder is CSS's — because a shape solved
  per window looks hand-drawn at one size and broken at the rest. Unset, it takes the
  largest rung that fits; named, it draws that rung or nothing. Its edges are drawn at
  eighth-of-a-cell precision (anchored block elements plus a foreground/background swap),
  which measures 3–7× smoother than filling cells with `█`, and `border-color` outlines the
  **silhouette** — the outermost cells of the shape itself, not a box around it — with a
  one-eighth hairline wherever the edge lands on a whole cell. See
  **`docs/unicode-art.md`**, which is also where box diagonals `╱╲` and braille are refuted
  with numbers. `bash demo/bigarrow-demo.bash` to look at it.

**Mutating and reading:** `ft-modify NAME prop=value`, `ft_get NAME prop`,
`ft_style NAME prop`. See `docs/api-naming.md` for the DOM-alignment convention and
`docs/styling-model.md` for the cascade.

## Writing a control class

A class is **declared**, in a constructor named `ft_class_<type>`. The first instance of
a type runs it once; `extends=` runs the superclass's constructor first, so the subclass
inherits a filled-in struct and overrides only what differs.

```bash
ft_class_button() {
    ft_class extends=label focusable=true focusSkip=none keymap=activate mouse=activate
}
ft-button() { ft_new button "$@"; }
```

That is the whole of `button`, and it reads as a sentence: *a button is a focusable label
that activates.* Three things keep it that short:

- **The target class is implicit.** There is no `$c` to thread down the chain, and so no way
  to fill the wrong class's struct by mistake.
- **`draw`, `preferredWidth` and `height` bind themselves** from `_ft_draw_<class>`,
  `_ft_preferred_width_<class>` and `_ft_height_<class>` when those exist. Every class in the
  chain binds its own, root first, so a subclass inherits what it does not define and
  overrides what it does. Naming one explicitly still wins.
- **A function value may be written short**: `keymap=activate` is `ft_keymap_activate`,
  `mouse=activate` is `_ft_mouse_activate`. A value already starting `ft_`/`_ft_` is taken
  verbatim, and `none` clears an entry inherited from a superclass.

Keys:

| key | what it names |
| --- | --- |
| `extends=` | superclass; runs first whatever its position, and must precede any other key |
| `draw=` | the draw function (unset = an undrawn container) |
| `preferredWidth=` / `height=` | intrinsic content size functions |
| `focusable=` | `true`/`false` — can it hold keyboard focus |
| `focusSkip=` | fn NAME → 0 to skip *this instance* (a label whose text fits) |
| `keymap=` | class-default keymap name |
| `mouse=` | fn NAME ACTION RELX RELY |
| `wheelProbe=` | fn NAME → 0 iff it has something of its own to scroll |
| `textProp=` | which property a bare DSL argument lands in (`text`, or `title` for a frame) |
| `noHit=` | `true` = `pointer-events:none`; clicks pass through |
| `setProp=` | fn NAME PROP VALUE — reconcile a late property write |
| `fillsBackground=` | `true` = its draw paints its whole box, so a damage repair skips it (the refill already restored its ground) |
| `borderSgr=` | fn NAME → the SGR its border wears |
| `defaults=` | property defaults applied before user args — **appends** to the inherited set |

An unknown key, an unknown superclass, a non-`true`/`false` boolean, or an `extends=`
arriving after another key is a hard error, and the class is not registered. Booleans are
stored as `1`/`0` and are always present, so a reader tests them arithmetically — never
with `-n`, which is true for `"0"`.

**Keymaps.** The class says *which* keymap it uses; a `_ft_define_keymap_<name>` function
says what is in it, and the engine runs that exactly once:

```bash
ft_class_label() { ft_class extends=ft_control keymap=label … ; }

_ft_define_keymap_label() {
    ft-keymap-cap ft_keymap_label UP ft_label_key_up "$FT_IMPORTANCE_CRUCIAL" "Scroll up"
    …
}
```

The once-ness matters because a class constructor runs once *per subclass* — building
button's struct runs label's constructor again — while a keymap is global. Every control
used to open with its own `if [[ -z "${_FT_KM_LABEL_READY:-}" ]]` guard, so the one line
that mattered (*which keymap am I?*) was buried under twenty binding lines.

**Runlevels** are declared at file scope, not in the constructor — `ft_class_runlevels`
registers the `<type>:<level>` CSS states, and stylesheets are parsed before any instance
exists. See `controls/ft-textfield.bash`.

## License

MIT — see [LICENSE](LICENSE).
