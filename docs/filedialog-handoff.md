# The file dialog — implementation handoff

**Read this whole file before writing code.** It is a contract, not a wish list.

It supersedes `filedialog-brief.md` and `filedialog-brief 2.txt`, which are folded in here.

---

## 0. Why this document is shaped like this

Every feature below has been asked for before and silently not delivered. Not refused —
*not mentioned*. Work came back with some things done and the rest unremarked, and the author had
to re-ask. **That is the failure this document exists to make impossible.**

So the rule is: **a requirement is not done until an assertion fails when you remove it.** Prose
in a report is not evidence. A green suite that never tested the thing is not evidence.

And: **you may not silently drop anything.** Every REQ id must appear in your final report with
exactly one of:

- `DONE` — naming the assertion that proves it
- `DEFERRED` — with a *measured* reason (numbers, not opinion) and what it would take
- `BLOCKED` — naming the specific decision needed from the author

A REQ that appears in neither the code nor the report is the exact failure being prevented. If the
list is too big for one session, **say so at the start**, propose a cut, and get agreement — do
not decide silently by running out of time.

**What counts as an assertion.** It must either (a) call the real hook or API and compare returned
state, or a property the code *computed* — not one you set in the same test — or (b) drive the
dialog through `tests/render-screen.py` and match text on the painted screen. What does **not**
count: grepping the source file, `declare -F`, asserting a control merely exists, or reading back
a value you just wrote. There is exactly one sanctioned source-grep in the suite (the fork gate at
`tests/test-filedialog.bash:120`) and it stays the only one. A REQ whose only assertion is a
source grep is reported `DEFERRED`, not `DONE`.

---

## 1. How to read the goldens

The author's words: *"the goldens are flawed in some ways, but are just to give an idea of what
we're trying to do"* — and, on their provenance: *"the goldens were made by ChatGPT and it really
struggled."*

Treat them as a **sketch of intent by a tool that was struggling**, not as a specification. Where
a golden and this document's prose disagree, **the prose wins**. Where a golden looks internally
inconsistent, it is — see the measured flaws below.

So, precisely:

**The goldens ARE authoritative for:** which regions exist, their order and grouping, what is
left- vs right-aligned, which controls are adjacent to which, menu contents and their separators,
and the wording of labels.

**The goldens are NOT authoritative for:** exact column offsets, exact widths, row counts,
padding, or the 100-column canvas. Do not diff against them, and do not commit them as pixel
goldens. Your real gate is the render test at the sizes in §7.

### Flaws found by measurement (so you know what "flawed" means concretely)

Verified with a width-aware pass over the file:

- The primary golden **is** internally consistent at 100 columns across all 35 rows, and the three
  popups are internally consistent (30/30/31 wide). That part is sound.
- **The Details columns are misaligned in the golden itself.** The `Modified` header sits at
  column 75 and the folder rows' dates at 75, but `site.yml`'s `Jul 19` sits at **76**; the `Size`
  header is at 63 while `3.2 KB` is at **62**. Align data to the header — the golden's own file
  row is off by one in both columns.
- **The toolbar spacing in the golden cannot be taken literally.** Slots are 2–3 ASCII characters
  (`NF`, `CUT`, `VIEW`) standing in for glyphs that are 1–3 cells. Brief 2 says this itself; it
  means the toolbar's real gaps must be computed, never copied.
- **There is no responsive story at all.** The golden is 100 columns wide. **The author runs
  ~62×40.** See REQ-24 — this is the single biggest gap in the source material.

---

## 2. Working agreement

- **Write the test first.** For each REQ, add its assertion to `tests/test-filedialog.bash`
  before the implementation. A red test you then make green is proof; a green test written
  afterwards often just asserts what the code happens to do.
- **Fix the root, not the case.** If a fix needs repeating per file type, per pane, or per view
  mode, it is at the wrong layer. This codebase has been burned by that repeatedly.
- **Never weaken an assertion to make it pass.** If an assertion is wrong, say why *with a
  measurement*, in a comment beside it.
- **Measure before tuning.** Never adjust a constant because something "looks better" — dump the
  numbers, change one thing, dump again. Guesses at bash hot spots in this codebase have been
  wrong nearly every time.
- **Verify at the author's real size.** Grid sweeps that started at 80 columns have repeatedly
  "passed" while the thing was visibly broken on screen at 62.
- **Build composable widgets, not one monolithic draw routine.**
- **Driving the modal headlessly.** `ft_file_dialog` blocks in `ft_next_event`, so a unit test that
  calls it hangs. Stub `ft_next_event` to replay a scripted token list — each call pops a token,
  sets `FT_EVENT_TOKEN` (and `FT_EVENT_CHAR` for CHAR), returns 0, and returns 1 when the list is
  empty so the loop exits — then assert on `FT_OUT` and on control properties.
  `tests/test-filedialog.bash:90` already stubs it the crude way. **And factor every confirm
  decision into a callable predicate** (`_ft_fd_would_overwrite PATH` → status, `_ft_fd_confirm_text`
  → the message) so REQ-32's and REQ-26's checks are assertable without running a loop at all; the
  loop test then only proves the predicate is wired to the key.
- **Reuse the existing primitives** — this dialog is assembled from ordinary controls.

### Environment (violating these wastes hours)

- Edits happen from Windows; run everything through WSL:
  `wsl.exe -d rocky -- bash /tmp/yourscript.bash`
- **Never** put logic in `wsl.exe … bash -c '…'` — variables and loop bodies are silently
  stripped and heredocs are mangled. Write a `.bash` file and run the file.
- A headless probe that sources a demo must keep its copy **inside the repo tree** — demos derive
  their root from `BASH_SOURCE`, so a copy in `/tmp` silently loads nothing.
- Keep ownership `drussell:drussell` and `+x` on scripts after editing from Windows.
- Do not run other suites while `tests/run-all.bash` runs — pty tests fail spuriously under load,
  and that flake has been misdiagnosed as a real failure more than once.
- Review screens with `bash tools/capture-frame.bash <demo> p1:1` — renders frames in parallel
  into `/tmp/frame.txt` at the invoking tty's real size.

---

## 3. What exists today (verified against the code, not remembered)

`ft-filedialog.bash`, 298 lines, at the **repo root** (not `controls/`).
`ft_file_dialog [property=value…]` → `FT_FILE_RESULT`; returns 0 on choose, 1 on cancel.
Properties today: `operation=open|save`, `path=`, `title=`, `submit=`.

Built from ordinary controls. **The panes are LIST BOXES (`ft-select`, `size>1`), not a tree.**
Option values are keyed `d:name`, `f:name`, `p:idx`. A real `ft-tree` appears **only** in Tree
view (REQ-11); the dialog as a whole must never become "a tree". `ft-select` fires `on_activate`
with the row's value, which is what lets a listbox behave like a file list.

Current controls: frame `__fdwin` → path label `__fdpath`, `__fdmain` (places `__fdplaces` +
list `__fdlist`), filename field `__fdname`, buttons `__fdsubmit`/`__fdcancel`/`__fdhelp`,
`__fdlegend`, `__fdstatus`.

`tests/test-filedialog.bash` — **50 assertions** (measured; an earlier draft of this document
said 46), all unit-level (path normalisation, scan order,
Places, hooks, Windows-profile picker). **There is no render gate**: nothing asserts on a painted
screen, which is exactly why layout regressions have gone unnoticed.

### 3b. Final property surface

One assertion per row, **including that an unknown key is reported rather than dropped** — today's
argument loop drops unknown keys on the floor.

| key | default | disposition |
|---|---|---|
| `operation` | `open` | unchanged |
| `title` / `submit` | derived from `operation` | unchanged — already single lowercase words, **do not "fix" them** |
| `startDirectory` | `$PWD` | new (REQ-21b) |
| `suggestedDirname` | unset | new |
| `suggestedFilename` | unset | new |
| `useAbsolutePaths` | `false` | new |
| `path` | unset | **RETAINED as a back-compatible alias** — splits to `suggestedDirname` + `suggestedFilename` by its dir/leaf rule exactly as today. All six assertions at `tests/test-filedialog.bash:88-99` and all four `path=~/…` call sites in `demo/tutorial-demo.bash` (lines 248, 265, 577, 585) must keep passing. |
| `name` | unset | alias for `suggestedFilename` (undocumented today, ft-filedialog.bash:229) |

**Precedence** when both an alias and its new name are given: the new name wins, and the collision
is reported on stderr at construction time — outside any test path, because `tests/run-all.bash`
fails any test file that emits a single line on stderr (run-all.bash:26-29).

**There is NO reusable menu in this framework.** There was one bespoke command palette
(`ft-menu.bash` — four `ft-button`s in a centred frame), and it has been deleted: nothing called it,
Esc's job became LEAVING rather than opening, and its own test asserted a flag its loop never read.
An anchored popup with separators, current-item marks and submenus does not exist here and is part
of this work.

**The listing is ALWAYS an `ft-select`, in every view mode** — activation, selection, scrolling and
Backspace get exactly ONE implementation across views. Details composes its columns into the option
text, fitted with the framework's column helpers. Do **not** swap in `ft-table` for one view mode:
that is the per-view-mode divergence §2 forbids.

### Two live traps, both already paid for once

- `_ft_fd_scan` relies on bash's own glob ordering plus a borrowed `LC_COLLATE` for
  case-insensitivity. **Do not "improve" it into a sort.** Measured: insertion sort of 2000
  entries **11.9 seconds**, merge sort 569ms, against 37ms for the fork it replaced. The shell
  cannot sort; it can only be asked to have sorted already.
- `_ft_fd_winhome` must keep skipping system profiles (`Default.*`, `defaultuser*`,
  `WDAGUtilityAccount`, `systemprofile`, `Public`, `All Users`) and prefer `$USER`/`$LOGNAME`.
  `Default.migrated` sorts before the real user and has a `Documents`, so this shipped once as
  *"I can't see my Windows files"*.

---

## 4. The goldens

### 4.1 Primary — Save / Details

```
┌─────────────────────────────────────────── Save File ────────────────────────────────────────────┐
│                                                                                                  │
│┌──────────────────────┐  ┌──────────────────────────────────────────────────────────────────────┐│
││ ~/subdir             │  │ NF   UP │ CUT CPY PST DEL SHR │ SRT SEL                         VIEW ││
│├──────────────────────┤  ├──────────────────────────────────────────────────────────────────────┤│
││ Home                 │  │ Name                              Size        Modified               ││
││ Win Home             │  │ .. (Up a level)                                                      ││
││ Win Desktop          │  │ roles/                                        Jul 20                 ││
││ Win Documents        │  │ inventory/                                    Jul 18                 ││
││ Win Downloads        │  │ site.yml                         3.2 KB        Jul 19                ││
││                      │  │                                                                      ││
│└──────────────────────┘  └──────────────────────────────────────────────────────────────────────┘│
│                                                                                                  │
│ Directory Path:                                                                                  │
│┌───────────────────────────────────────────────────────────────┐  ┌───┐  [x] Use suggested       │
││ ~/subdir                                                      │  │ C │                          │
│└───────────────────────────────────────────────────────────────┘  └───┘                          │
│                                                                                                  │
│ Filename:                                                                                        │
│┌───────────────────────────────────────────────────────────────┐  ┌───┐  [x] Use suggested       │
││ site.yml                                                      │  │ C │                          │
│└───────────────────────────────────────────────────────────────┘  └───┘                          │
│                                                                                                  │
│                                                                    Save    Cancel    Help        │
├──────────────────────────────────────────────────────────────────────────────────────────────────┤
│ S: Save   Enter: Open   Bksp: Up   Tab: Panes   Esc: Cancel                                      │
├──────────────────────────────────────────────────────────────────────────────────────────────────┤
│ ~/subdir   –   2 folders, 1 file                                                                 │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Sort popup

```
┌────────────────────────────┐
│ * Name                     │
│   Date modified            │
│   Type                     │
│   Size                     │
├────────────────────────────┤
│ ^ Ascending                │
│ v Descending               │
├────────────────────────────┤
│   Group by              >  │
└────────────────────────────┘
```

### 4.3 Selection popup

```
┌────────────────────────────┐
│ [x] Select all             │
│ [ ] Select none            │
│ [~] Invert selection       │
└────────────────────────────┘
```

### 4.4 View popup

```
┌─────────────────────────────┐
│   Extra large icons         │
│   Large icons               │
│   Medium icons              │
│   Small icons               │
├─────────────────────────────┤
│   List                      │
│ * Details                   │
│   Tiles                     │
│   Content                   │
├─────────────────────────────┤
│   Compact view              │
│   Show                  >   │
└─────────────────────────────┘
```

---

## 5. Icons

Slot IDs (`NF`, `UP`, …) exist **only** so the golden's geometry is width-stable. **Never render
a slot ID in the finished UI.**

Widths below are what **this framework's `ft_display_width` actually returns** — measured, not
assumed. Two glyph sets were supplied; brief 2's set is later and deliberately width-safer.

| slot | brief 2 glyph | width | chat-message glyph | width | meaning |
|---|---|---|---|---|---|
| NF | `🗀+` | **3** | `🗀︎＋` | **4** | New Folder |
| UP | `↥` | 1 | `↥` | 1 | Parent directory |
| CUT | `✂` | 1 | `✂︎` | 1 | Cut |
| CPY | `⧉` | 1 | `⧉` | 1 | Copy filesystem objects |
| PST | `⧈` | **1** | `📋︎` | **2** | Paste |
| DEL | `♲` | **1** | `🗑︎` | **2** | Trash |
| SHR | `⇱` | 1 | `⇱` | 1 | Share |
| SRT | `⇅⌄` | 2 | `⇅⌄` | 2 | Sort menu |
| SEL | `☑⌄` | 2 | `☑⌄` | 2 | Selection menu |
| VIEW | `⌗⌄` | 2 | `▦⌄` | 2 | View menu |
| C | `⧉` | 1 | — | — | Copy **field text** (not filesystem copy) |

**Recommendation: use brief 2's set.** Its Paste/Trash choices are BMP symbols of width 1, where
the chat set's are emoji the framework counts as 2. Several chat glyphs carry U+FE0E (text
presentation) on an emoji base — `🗑︎` is `U+1F5D1 U+FE0E` — and **the framework counts the base as
2 regardless of the selector**, while some terminals render such a glyph as 1. A one-column
disagreement shifts every cell after it on that row; that is precisely the class of bug that
produced smearing elsewhere in this codebase.

**The framework and the render harnesses disagree about `🗀`, and only about `🗀`.** `ft_char_cols`
(ft-core.bash) calls U+1F5C0 wide; `tests/render-screen.py` and `tools/screen-cells.py` both use
`unicodedata.east_asian_width`, where U+1F5C0 is `N`. Measured, so you need not re-measure: in
brief 2's set every slot is **ft = harness** — `↥`1/1 `✂`1/1 `⧉`1/1 `⧈`1/1 `♲`1/1 `⇱`1/1 `⇅⌄`2/2
`☑⌄`2/2 `⌗⌄`2/2 — **except `🗀+`, ft 3 / harness 2.** (In the chat set the same trap hits `✂︎`
ft 1 / harness 2 and `📋︎` ft 2 / harness 3.) This is known and measured; do **not** "fix" either
side, and do not adjust correct layout code to satisfy the harness.

**Rule: no toolbar or listing icon above U+FFFF.** Replace New Folder's `🗀` with a BMP glyph both
models agree on (`⊞` U+229E recommended) and say in the report which you chose. The same rule
governs every REQ-14 file-type icon.

**How to assert width:** `ft_display_width` returns through **`FT_DISPLAY_WIDTH`, not `FT_RET`**.
The REQ-03 assertion is: each glyph's `ft_display_width` equals the number written in the table
**and** equals the harness's model — a glyph on which the two differ is disqualified before use.

---

## 6. Requirements

### A. The harness this all gets tested through

- **REQ-00 — the render harness exists.** Everything in §7 depends on it and today it does not
  exist: `tests/render-screen.py` execs a *script*, `tools/capture-frame.bash` accepts only
  `demo/<name>.bash`, and `ft_file_dialog` is a function with no host app. Create
  **`demo/filedialog-demo.bash`**, a real app whose job is to open the dialog. It MUST: (a) open
  the dialog on its **first frame**, no keypress required — `capture-frame.bash` passes an empty
  key script, so a dialog needing a key can never be reached; (b) honour `DEMO_PAGE`/`DEMO_STEP`
  the way `demo/callout-demo.bash` does — page 1 Open, 2 Save, 3 Details, 4 List, 5 Tree, 6 Sort
  popup, 7 Selection popup, 8 View popup, 9 confirm modal; (c) take `startDirectory` from
  `FT_FD_DEMO_DIR`, defaulting to the fixture of REQ-21c. It lives in the repo tree — demos derive
  their root from `BASH_SOURCE`. Every screen assertion in §7 drives this file. DONE when a
  62-column capture shows the frame's title row.

### B. Toolbar

- **REQ-01** — the toolbar exists across the top of the file pane, in this order:
  New Folder, Parent │ Cut, Copy, Paste, Trash, Share │ Sort, Selection … View.
- **REQ-02** — **View is right-aligned**; everything else is left-aligned, with `│` separators
  between the three groups.
- **REQ-03** — **width correctness is a gate, not a hope.** Assert each glyph's
  `ft_display_width` with the expected number written down; assert the toolbar's total rendered
  width equals the sum of its parts plus its gaps; render through `tests/render-screen.py` and
  assert the row after the toolbar is undamaged and the frame's right border intact. If a glyph
  proves unsafe on the author's terminal, **report it with the measurement and propose an
  alternative** — never silently substitute.
- **REQ-04** — a `⌄` suffix means it opens a menu. Sort, Selection and View open overlays; the
  rest are immediate actions.
- **REQ-05** — every toolbar item is keyboard-reachable (not mouse-only) with a discoverable hint.
  `__fdlegend` is a hardcoded string today (`keys="S=Save Enter=Open …"`, ft-filedialog.bash:211);
  change it to **`keys=auto`** (controls/ft-keylegend.bash:11,93) and declare every toolbar key with
  `ft-keymap-cap MAP PATTERN ACTION IMPORTANCE LABEL` — note the FIRST argument is the keymap
  **name**, and importance is `crucial|important|normal|minor`. Once it is `auto` the legend's
  wording comes from your cap LABELs, so §4.1's golden legend line becomes a target for the labels
  you write, not a string to reproduce.
- **REQ-06** — disabled items **look** disabled: Paste with an empty clipboard, Parent at `/`,
  Trash with nothing selected (REQ-08b makes that state reachable). Dimmed and non-activating,
  never silently inert. **Three assertions per case.** (1) STATE: `ft_resolved_prop <item> disabled` is
  `true` exactly when the precondition holds. (2) INERT: dispatching its activate key leaves the
  action variable untouched. (3) LOOKS: capture the frame's byte stream and run it through
  **`tools/screen-cells.py`** (one line per cell: `row,col<TAB>glyph<TAB>attrs`, already used by
  `tests/test-residue.bash`) and assert the item's cells carry the disabled foreground —
  **`tests/render-screen.py` cannot see this, it discards every SGR sequence.** Set `disabled` on
  the individual item, never on its container: **`disabled` is an INHERITED property**
  (`FT_INHERITED_PROP`, ft-forms.bash:335-338), so disabling the toolbar silently disables
  everything in it.

### B. Menus (contents from the goldens)

- **REQ-07** — **Sort menu**: Name / Date modified / Type / Size, separator, Ascending /
  Descending, separator, `Group by >` submenu. Current sort marked (`*`), current direction
  marked. `Group by >` contains: None (default, marked) · Type · Date modified · Size — grouping
  inserts a non-focusable header row per group and does not change what Enter does.
  **The no-sort rule of §3/§9 governs the DEFAULT name ordering only.** `_ft_fd_scan`'s glob order
  stays exactly as it is for sort=Name and must remain fork-free; Name-descending is an array
  reverse and must not fork either. A **non-default** sort key is a user-initiated re-order that
  happens once per menu pick, not per keystroke — there **one** fork per directory change is
  permitted and expected. Budget: assert a sorted directory change on 2000 entries stays under
  **150ms**, and put that number in the report beside the 11.9s / 569ms / 37ms figures. If you
  cannot meet it, mark Date/Size/Type `DEFERRED` **with the number** — do not ship a Sort menu that
  draws, marks `* Name`, and does not sort. State whether the sort key survives a directory change,
  and whether direction applies to the folders-first grouping.
- **REQ-08** — **Selection menu**: Select all / Select none / Invert selection.
- **REQ-08b — MULTI-SELECT (DECIDED).** Four REQs depend on "the selection" and nothing defined it;
  the listing is built `multiple=false showSelected=false` today, which makes Select all/none/Invert
  meaningless no-ops that still satisfy REQ-08 and makes REQ-06's "Trash with nothing selected"
  unreachable. So: the file listing is multi-selectable — `multiple=true showSelected=true` on
  `__fdlist`. Space toggles the row under the cursor, selected rows are visibly marked, and
  **"nothing selected" is a reachable state**. A selection clears on navigation; it never spans
  directories. Multi-select is offered only when `operation=open`; in `save` mode the Selection menu
  carries REQ-06's disabled look, because Save targets one leaf.
  **Transport:** `FT_FILE_RESULT` always holds the single primary path (back-compatible); with more
  than one row selected, `FT_FILE_RESULTS` is a bash **array**. Do **not** use `ft-select`'s
  `multiple=true` value string — it is space-joined (`vals+="${vals:+ }$FT_RET"`,
  controls/ft-select.bash:137) and destroys any name containing a space. Read the per-option
  `selected` flags. Assert: Select all marks every row; Invert flips them; with zero selected Trash
  and Cut paint dimmed and pressing them changes nothing; and a fixture file named
  `My Documents.txt` round-trips intact.
- **REQ-09** — **View menu**: Extra large / Large / Medium / Small icons, separator, List /
  Details / Tiles / Content, separator, Compact view / `Show >` submenu. Current view marked.
  `Show >` contains: Hidden items (off) · Details column headers (on) · Status bar (on), each
  showing its state; turning Hidden items on sets `dotglob` for the scan and dotfiles interleave
  into glob order — that is correct and is **not** a reason to introduce a sort.
  **Activating a view item must change the listing observably**: assert the painted listing rows
  for List and for Details DIFFER, and that the `*` moves to the activated item.
  **Submenu mechanics:** Right or Enter opens; Left or Esc closes back to the parent popup; Esc
  again closes both. Anchored right of its parent item, flipping left when it would cross the frame
  border (mandatory at 56 columns). **Assert that Right/Enter on `Group by >` and on `Show >` opens
  the submenu and that its items are on the painted screen — a `>` glyph that opens nothing is a
  FAIL, not a partial DONE.**
- **REQ-10** — **overlays never reflow the file list.** Opening a popup must not move, resize or
  re-scroll the pane behind it. Assert **both**, neither alone counts. (a) STATE:
  `FT_ABSOLUTE_X/Y[__fdlist]`, `FT_MEASURED_WIDTH/HEIGHT[__fdlist]` and the select's `scroll` and
  `cursor` are identical before opening, with the popup open, and after closing — the same six for
  `__fdplaces`. (b) SCREEN: every cell **outside the popup's own rect** is byte-identical to the
  closed frame. Write (b) so it FAILS if the screen behind the popup is blank.
  **Build these as overlays, not centred modals:** `position=absolute` composited through
  `FT_OVERLAY` / `FT_OVERLAY_Z_ORDER` / `_ft_composite_overlays` (ft-forms.bash:3762-3784) — the
  mechanism `controls/ft-beacon.bash` and ft-select's own dropdown already use. Do **not** copy the
  pattern at `ft-help.bash:219` or `ft-filedialog.bash:253`: it emits
  `FT_ANSI_CLEAR_SCREEN` and repaints only itself, which *erases* the pane rather than reflowing it
  and makes this requirement vacuously true. If you do run a nested loop use the existing
  `ft_modal_push`/`ft_modal_pop` (ft-forms.bash:5079) — `ft_file_dialog` already calls them; do not
  hand-roll the save/restore, because `pop` deliberately rebuilds the focus ring from the tree.
  Each popup is anchored under its own toolbar button (View flush right), clamped inside the frame
  border.

### C. Views

- **REQ-11** — **Details view**: Name, Size, Modified columns. Align data to the header (the
  golden's own file row is off by one — see §1); assert Name/Size/Modified start at the SAME column
  in the header row and in every data row. Columns must survive a narrow terminal (REQ-24). A name
  too wide for its column truncates at the TAIL with `…`, measured in DISPLAY COLUMNS via
  `ft_display_width` — never characters or bytes; a truncation that would split a 2-column glyph
  drops that glyph and pads with a space. Assert with a 200-character name and with an all-CJK name.
- **REQ-11b — metadata acquisition and format (DECIDED).** One `stat --printf` invocation **per
  directory scan**, never per row, filling `_FT_FILE_DIALOG_SIZE[]` / `_FT_FILE_DIALOG_MTIME[]`
  alongside NAMES/IS_DIR — and only when Details or a non-name sort is active, so List view does not
  pay for it. **Format:** 1024-based units, one decimal below 10 units and none above (`3.2 KB`,
  `47 KB`, `1.4 GB`), bytes under 1 KB as `812 B`; a **directory's Size cell is empty**. Modified:
  `Mmm DD` within the last 12 months, `Mmm YYYY` beyond, right-aligned under a right-aligned header.
  A file whose stat fails (raced deletion, permission) shows `—` in both cells and is not an error.
  **Redirect stderr on every filesystem command** — `tests/run-all.bash` fails any test file that
  emits a single line on stderr (run-all.bash:26-29).
- **REQ-12** — **List view** (names only), and the icon-size variants exist as real modes or are
  explicitly reported `DEFERRED` with a reason. Tiles/Content likewise.
- **REQ-13** — **Tree view mode**, and *only* here is a real `ft-tree` composed. The dialog does
  not become a tree; the view swaps. **Tree view is reached from the View menu** — insert a `Tree`
  item into the group with List/Details/Tiles/Content. This deliberately ADDS to the golden, which
  has no Tree item; the prose wins (§1). The assertion must reach Tree view **through that menu item
  by key**, not by setting an internal variable, or REQ-29's "when not in Tree view" is untestable.
  Tree view keeps the toolbar and the fields and replaces the **file pane only**; the Places pane
  remains. ←/→ collapse/expand inside the tree, so Tab is the only pane switch there. Enter on a
  tree file behaves exactly as REQ-31. It carries REQ-14's icons and participates in REQ-08b's
  selection; it does not show Details columns. Children load **on expand**, never eagerly — assert
  that opening Tree view at a deep fixture scans exactly one directory.
- **REQ-14** — **per-type file and folder icons** in the listing, under the same width discipline
  as REQ-03: every icon's width asserted, and a listing row must never shift its neighbours. **This
  icon set does not exist anywhere in this document — add a table in §5's format** (slot, glyph,
  measured `ft_display_width`, measured harness width, meaning) covering at minimum: folder,
  folder-up, plain file, text, config/yaml, archive, image, executable, symlink. **No glyph above
  U+FFFF** (§5's rule). Every width written down before use.
- **REQ-15** — `.. (Up a level)` is the first row when not at the filesystem root.
  **EDGE CASES (asserted).** An EMPTY directory shows `..` plus a non-focusable `(empty)` row and
  `0 folders, 0 files`. An UNREADABLE directory is distinguished from an empty one — test
  readability before scanning and show `Permission denied` via REQ-23b rather than a blank pane;
  this applies to EVERY navigation, not only `startDirectory`. A symlink to a directory lists and
  navigates as a folder; a broken symlink lists as a file with `—` metadata; Cut/Copy/Delete act on
  the LINK, never the target. `..` is resolved LEXICALLY on purpose (REQ-19) — do not "fix" it.

### D. Fields and the path model

- **REQ-16** — **two separate editable fields**, never merged. The directory field is labelled
  **"Location:"** (DECIDED — this overrides the golden's "Directory Path:"); the other is
  **"Filename:"** and holds **only the leaf**. Target = Location + Filename. With no file
  activated, Filename is EMPTY and Location holds the whole path.
  **COMMIT SEMANTICS (DECIDED).** Location commits on Enter only — never per keystroke, never on
  blur. A commit resolving to an existing readable directory navigates the listing and auto-unchecks
  "Use suggested path". One that does not exist, is not a directory, or is unreadable leaves the
  listing untouched, shows REQ-23b's error, and **keeps the typed text so it can be corrected**. A
  separator typed into Filename moves the directory part into Location on commit, leaf only stays;
  an absolute path typed into Filename replaces Location. Assert all four.
- **REQ-17** — **three checkboxes** (DECIDED): **"Use suggested path"**, **"Use suggested
  filename"** — one per field, independent, never merged — and **"Resolve paths"**. The first two
  are checked by default when the corresponding property is supplied; navigating to a directory
  auto-unchecks the path one, activating a file auto-unchecks the filename one. "Resolve paths"
  is the live surface of `useAbsolutePaths` (REQ-20): ticking it resolves what is displayed and
  returned, and it must agree with that property in both directions. "Resolve paths" sits on its own
  row beneath the Filename row — it is deliberately in no golden. Re-checking "Use suggested path"
  NAVIGATES back to the suggested directory; likewise for filename. When the corresponding property
  was not supplied the checkbox renders DISABLED (REQ-06's look), never hidden. **ACCESSKEYS:**
  assign one to every new control here and assert no duplicates within the built dialog — note
  Cancel already holds `accessKey=C` (ft-filedialog.bash:204) while REQ-18's Copy buttons RENDER as
  "C"; those are different things and must not collide.
- **REQ-18** — **each field has an adjacent Copy-field-text button** (`C` → `⧉`). This copies the
  *field's text*; it is **not** filesystem copy (REQ-01's CPY). Do not conflate them.
- **REQ-19** — **relative paths by default.** `~` is preserved and displayed as `~`. Maintain
  `lexical_path` and `resolved_path` **separately**: display and return the lexical form, resolve
  only for filesystem access. Navigating from `~/subdir` into `roles` yields `~/subdir/roles`.
  **Never destructively expand `~` in the visible or returned value.** Rationale, in the author's
  words: portable settings generators that run on hosts with different real home directories.
  **This supersedes existing code and assertions, and saying so is required, not a weakening of
  §2:** the assertions at `tests/test-filedialog.bash:13-18`, `:93` and `:98` and the `~` expansion
  at `ft-filedialog.bash:235` (`path=${path/#\~/$HOME}`) encode the OLD resolved-only model.
  Update them and list them in the report under "superseded assertions". `_ft_fd_norm` stays the
  **resolved-side** helper and keeps returning absolute paths; write a lexical sibling
  (`_ft_fd_norm_lexical`) and state which one each call site uses. **Cosmetic `$HOME`→`~`
  re-abbreviation of a resolved path does NOT satisfy this.** Assert this exact table: `~` +
  activate `subdir` → `~/subdir`; `~/subdir` + activate `roles` → `~/subdir/roles`; + Up →
  `~/subdir`; a `startDirectory` given as a **relative** path stays relative; a directory reached
  through a **symlink** displays as the path you typed; Backspace from `~` shows the resolved parent
  of `$HOME` (because `~` has no lexical parent); and `FT_FILE_RESULT` is the lexical string byte
  for byte in every case, with the resolved form appearing only in the status bar.
- **REQ-20** — **`useAbsolutePaths`** property (default `false`) forces immediate resolution.
- **REQ-21** — suggested directory and suggested filename are **independent**; without a
  suggested filename, Filename starts empty. The panes auto-navigate to the suggestions.
- **REQ-21b** — **`startDirectory` property** (DECIDED). Where the dialog opens when no suggested
  directory is given is the CALLER's choice, not a guess: `startDirectory="$PWD"`,
  `startDirectory="$HOME"`, or any other directory. **Default when unspecified: `$PWD`.** (This
  replaces both sources — brief 2 said "fall back to CWD", the current code uses `$HOME`, and
  neither let the caller say.) A `startDirectory` that does not exist or is unreadable must fall
  back visibly, not silently: report it and open somewhere sane.
- **REQ-21c — every render scenario runs against a FIXTURE**, never `$PWD`, `$HOME` or the repo.
  `tests/render-screen.py` runs the app with cwd set to the **repo root**, so a `$PWD` default lists
  `fruity-tui/` — content that changes on the next unrelated commit and differs from the author's
  box, so "listing rows that do not shift" would pass the day it is written and then cry wolf. The
  demo/test creates the fixture under `mktemp -d`: directories `inventory/` and `roles/`, a file
  `site.yml` sized so `3.2 KB` is stable, a hidden `.git` to prove hidden entries are skipped, and
  all mtimes pinned with `touch -t 202507190000` so the Details columns are byte-stable. Pass it as
  `startDirectory=`. Assert the three fixture row texts by name.
- **REQ-22** — **sanitise typed input.** Reject or clamp beyond `PATH_MAX` / per-component
  `NAME_MAX`. **Expand `~` deliberately and nothing else** — never `eval` a typed path, no `$VAR`,
  no backticks. A typed path is untrusted text — **and so is every filename READ OFF DISK.** A name
  may contain newlines, tabs, ESC bytes and control characters; none may reach the renderer or any
  arithmetic context. Sanitise at the SCAN, once — a fix repeated per view mode is at the wrong
  layer. Test with a fixture holding names containing an embedded ESC, a tab, a newline, one 255
  bytes long, and one named `$(id)`.
- **REQ-23** — the **status bar** shows the path plus a summary (`~/subdir – 2 folders, 1 file`).
  The path it shows is the **RESOLVED** full one (decision 4 in §8) — this is the only place the
  resolved form appears, which is what lets the Location field stay short and lexical.
- **REQ-23b — ERROR SURFACE (DECIDED).** Four REQs demand visible failures and no error surface
  exists. The status bar has two states: resting, it shows REQ-23's resolved path + counts; on
  failure it shows the error, styled as an error, cleared by the next successful navigation,
  refresh, or keypress that changes the listing — **never by a timer**. Assert both: a forced
  `mkdir`/`rm`/copy failure puts its message in the status bar, and the next navigation restores the
  path+counts form. **Errors never open a modal — modals are for questions (REQ-26b), not news.**

### E. Responsiveness — the biggest gap in the source material

- **REQ-24** — **the dialog must work at 56–70 columns**, not just the golden's 100. The author
  runs **~62×40**. Define and implement the degradation: which columns drop first in Details,
  what the toolbar does when it cannot fit, how the Places pane narrows or collapses.
  **The degradation is DECIDED, not delegated:** below 90 columns Details drops Size first, then
  Modified, Name never. Below 70 the toolbar's group gaps shrink to one space; below 62 the middle
  group collapses behind a single `…` overflow item holding Cut/Copy/Paste/Trash/Share. The Places
  pane narrows to 12 columns below 70 and collapses below 62, reachable by an accelerator that
  opens it as a popup. A popup wider than the frame's inner width is clamped to it and anchored
  flush right.
  **Assert at 56×40, 62×40, 70×40, 100×40 and 62×24** — the author runs 62×**40**, `_ft_fd_build`
  caps the window at 24 rows and reserves 10 for chrome, and this document adds a toolbar row, a
  header row, two label+field+Copy rows, three checkboxes and a status bar to that budget, so
  nothing currently guarantees a single file row survives. At each size the painted screen must
  **contain, as literal text**: the `Name` column header, `Location:`, `Filename:`, both "Use
  suggested" labels, the submit / Cancel / Help labels, the status-bar counts, and **at least 6
  listing rows**. The toolbar must still be present — if it collapses, the overflow affordance is
  itself asserted and every collapsed item stays keyboard-reachable (REQ-05). Only then:
  (a) BORDER — every row of the frame has the same `ft_display_width` and carries the border glyph
  in its first and last column; (b) NO OVERLAP — for every pair of **siblings in the same
  container**, the rects from `FT_ABSOLUTE_X/Y` + `FT_MEASURED_WIDTH/HEIGHT` do not intersect
  (parents contain children legitimately; overlays are REQ-10's business); (c) NO MID-GLYPH CLIP —
  assert at the source: every truncation goes through `ft_display_index`/`ft_display_col`, and a
  grep of the new code finds no `${var:0:n}` used to fit text to a column budget.
  **Row budget:** state it in the report as a table (chrome rows + listing rows = 40). The dialog
  needs 22 rows minimum; below that the key legend goes first, then the status bar, then the
  checkboxes fold onto the field rows.

### F. Behaviour

- **REQ-25** — **New Folder actually works** (marked CRUCIAL previously). Creates `New folder` in
  the current directory (incrementing to `New folder (2)`… on collision) and immediately opens an
  inline editor on that row. **`ft-select` options are static text — there is no editable row
  anywhere in this framework. Implement the editor as a one-row `ft-textfield` positioned over the
  listing row (REQ-10's overlay mechanism), NOT by teaching `ft-select` to edit** — and say in the
  report exactly how you did it. Enter commits; **Esc or an empty name removes the directory just
  created, leaving no litter.** Reject `/` and NUL, reject `.` and `..`, reject names over
  `NAME_MAX`, trim trailing whitespace — reusing REQ-22's validator, which must therefore be a
  shared function and not path-field-specific. A `mkdir` failure shows REQ-23b's error and leaves
  the listing unchanged. After commit, re-scan and put the cursor on the new folder wherever the
  ordering placed it. **Four assertions: creates · inline editor opens · permission failure visible
  on screen · listing refreshed.**
- **REQ-26b — build ONE confirm modal, as a framework primitive.** No confirm primitive exists in
  this codebase (grep: zero hits for `ft_confirm`, `ft_alert`, `ft_prompt`, `ft_messagebox`), yet
  three REQs assume one. Build `ft-confirm.bash`, sourced from `fruity-tui.bash` — **not** a modal
  inside the dialog. Signature: `ft_confirm title=… message=… buttons='Delete|Cancel' default=Cancel
  [danger=true]` → `FT_CONFIRM_CHOICE` holds the chosen label; returns 0 for the first button, 1
  otherwise. A destructive confirm defaults focus to the **safe** button. REQ-26 (delete), REQ-32
  (overwrite) and REQ-27 (paste collision) all route through this one function — a second bespoke
  modal in the dialog is a defect, not a partial DONE. REQ-10's overlay rule applies. Also decide
  and state here: does Trash mean XDG trash or `unlink`; do non-empty directories delete
  recursively; what the message says for N selected items.
- **REQ-26** — **Delete → confirm modal.** The `Delete` key and the Trash item route to REQ-26b's
  one confirm. Permission/read-only failures surface as errors (REQ-23b), not silence.
- **REQ-27** — **Cut / Copy / Paste.** The file clipboard is **INTERNAL**
  (`_FT_FILE_DIALOG_CLIP_PATHS[]` + `_FT_FILE_DIALOG_CLIP_MODE=cut|copy`) and is **not** the OSC 52
  system clipboard REQ-28 writes to; the two never interact. It drives REQ-06's disabled look. Cut
  dims the source rows until the paste completes or the clipboard is cleared. Paste-after-Cut tries
  `mv` and **falls back to copy-then-remove on a cross-device failure — the WSL `$HOME`→`/mnt/c`
  case is common here, not an edge case, so test it.** Paste-after-Copy always copies; directories
  copy recursively. A destination collision opens REQ-26b's confirm with three answers — Overwrite /
  Skip / Keep both (` (2)`, incrementing) — plus "Apply to all" when more than one item is pasting.
  A Cut clipboard is cleared by its paste; a Copy clipboard survives and may be pasted repeatedly.
  Pasting a directory into itself or a descendant is refused with a visible error, never attempted.
  Cut/Copy on the `..` row or in the Places pane is a no-op with the disabled look. Every filesystem
  command redirects stderr. Operations are synchronous; if a paste exceeds 500ms in testing, report
  the measurement and propose the async design rather than shipping a frozen UI. **Four assertions:
  cut-then-paste moves · copy-then-paste duplicates · cross-device fallback · collision confirm.**
- **REQ-28** — **Share** (`⇱`) (DECIDED): open the OS share sheet where one exists, otherwise
  **copy the path to the clipboard**. In a terminal the fallback is the common case, so build the
  clipboard path first and treat the share sheet as the platform-specific enhancement. Use the
  framework's own `ft_clip_copy` (ft-core.bash) — **not** a hand-rolled OSC 52 write: it returns a
  status, and it caps at `FT_CLIP_MAX_BYTES` because a terminal silently drops or *prints* an
  oversized payload. **An empty payload CLEARS the clipboard**, so never send one; a failed copy
  must say so on screen, since a silent no-op is indistinguishable from a broken key. Which path
  form gets copied follows REQ-19 (lexical unless resolution is on). **Assert it the way
  `tests/test-clipboard.bash` does** — point `FT_TTY` at a file, invoke Share, decode the OSC 52
  payload. Four assertions: the payload equals the LEXICAL path (resolved when `useAbsolutePaths` is
  on); sharing with nothing selected emits **no bytes** ("untouched", never "cleared"); a non-zero
  `ft_clip_copy` status changes the status-bar text to a visible failure (assert the property, then
  the frame); and nothing on stderr.
- **REQ-29** — **←/→ switch panes** when not in Tree view; **Tab** moves between panes;
  **Backspace** goes up a level (per the golden's legend). This **collides with `ft-select`**, which
  binds `LEFT`/`RIGHT` to cursor movement in its `browsing` runlevel (`_ft_define_keymap_select`,
  controls/ft-select.bash:51) — and that keymap is **prototype-level, shared by every select in the
  host app, so you may not unbind it globally.** Resolve by deriving a prototype (`ft_prototype
  extends=select` for the listing and Places panes, each with its own keymap) or by scoping ←/→
  to the undelved rung. Assert **both**: ←/→ switches panes in the dialog, **and** a plain
  `ft-select` elsewhere in the same test still moves its cursor on ←/→.
- **REQ-30** — **the contextual Enter legend**: on a directory `Enter: cd`, on a file
  `Enter: Select file`, changing with the highlighted row. **`ft-select` fires nothing when the
  cursor moves** — `_ft_select_cursor_to` has no hook, and `on_change` fires only from the commit
  path (controls/ft-select.bash:262). Add `onCursorChange=fn`, fired from `_ft_select_cursor_to`
  with the newly-hovered value; assert it in `tests/test-select.bash` too, then re-run
  `tests/test-selection.bash` and `tests/test-scroll.bash`. Do **not** poll the cursor property from
  the dialog's event loop — that is the per-case fix §2 forbids, and it will not fire for the mouse
  or for Home/End. A keymap LABEL is static and prototype-scoped, so the legend text must come
  from `_ft_caps_<type>` (ft-forms.bash:5361) hung off a **derived prototype**; assert that a
  plain `ft-select` in the same test does not gain the `Enter: cd` cap. Assert directly: cursor on a directory row →
  legend reads `Enter: cd`; on a file row → `Enter: Select file`; and that the two DIFFER.
- **REQ-31** — **selecting a file populates Directory Path + Filename but does NOT submit.**
  Never auto-submit merely because a file was selected. (Activating a file previously did
  nothing at all.)
- **REQ-32** — **the save flow confirms overwrite** when the chosen name already exists.
- **REQ-33** — **same geometry for Open and Save**; only the title and the primary action label
  change with `operation=`.

---

## 7. Definition of done

1. `bash tests/test-filedialog.bash` passes. **Run it before writing a line** and paste its
   `N/N assertions passed` line into the report as the baseline — it was **50** when this was
   written; if you see a different number, use yours and say so. Growth rule: **one assertion per
   observable behaviour, not per REQ id.** A REQ whose text is a list of behaviours needs one
   assertion per item in that list — REQ-25 needs four, REQ-27 needs four, REQ-17 needs one per
   checkbox plus one per auto-uncheck rule. The report must say which assertion belongs to which
   REQ, by name.
2. **A render gate exists** — there is none today. Drive `demo/filedialog-demo.bash` (REQ-00)
   through `tests/render-screen.py` and assert on the painted screen at **56×40, 62×40, 70×40,
   100×40 and 62×24**, against the REQ-21c fixture: toolbar row, intact frame border, the literal
   texts REQ-24 lists, listing rows that do not shift, popups that do not reflow the pane. Resizes
   are driven in-run with `render-screen.py`'s own `RESIZE:62x40` step.
3. `bash tests/run-all.bash` — all test files pass, run with nothing else competing for the box.
   Remember it fails any test file that writes a single line to **stderr**.
4. **Frames captured at 62×40 and pasted into the report.** `tools/capture-frame.bash` has **no
   size argument** — it reads the tty via `stty size` and, headless, silently falls back to
   `${COLUMNS:-118}×${LINES:-40}`, i.e. 118×40 with only a stderr warning. From an agent shell go
   direct: `FT_TEST_COLS=62 FT_TEST_ROWS=40 python3 tests/render-screen.py demo/filedialog-demo.bash
   "<keys>"`. `capture-frame.bash` is for the AUTHOR to run from a real terminal. Quote the frame's
   `═══ … — 62x40 ═══` header — a header reading `118x40` is not evidence.
5. The report walks **every REQ id** with `DONE` / `DEFERRED` / `BLOCKED`, plus a "superseded
   assertions" list (REQ-19) and the row-budget table (REQ-24).

---

## 8. Decisions — all settled, do not re-litigate

The two source documents disagreed on six points. **The author has answered all six.** These are
closed; if you believe one is wrong, raise it before building, do not quietly choose otherwise.

| # | Question | **Decision** |
|---|---|---|
| 1 | Directory field label | **"Location:"** — *not* the golden's "Directory Path:" |
| 2 | How many checkboxes | **Three**: Use suggested path · Use suggested filename · Resolve paths |
| 3 | Property naming | **The codebase's own convention** — camelCase, DOM-aligned (`docs/api-naming.md`): `suggestedDirname`, `suggestedFilename`, `useAbsolutePaths`, `startDirectory`. **camelCase applies to PROPERTY names only** — functions, internal helpers and globals stay `snake_case` (`ft_file_dialog`, `_ft_fd_scan`, `FT_FILE_RESULT`); that is `api-naming.md`'s opening rule, not a violation of it. **Rename nothing that already exists** — see §3b. |
| 4 | Status bar content | **Resolved full path + counts** — the one place the resolved form appears, so the Location field can stay short and lexical |
| 5 | What Share does | **OS share sheet where one exists, else copy the path to the clipboard** (REQ-28) |
| 6 | Where the dialog opens | **`startDirectory` property**, caller's choice (`"$PWD"`, `"$HOME"`, anything). **Default `$PWD`** (REQ-21b) |

Everything else in this document the author has explicitly agreed with.

## 9. Do not

- Merge Directory Path and Filename, or the two "Use suggested" controls.
- Destructively expand `~` in the visible or returned value.
- Confuse field-text copy with filesystem copy.
- Auto-submit because a file was selected.
- Reflow the file pane when a popup opens.
- Hardcode Unicode icon widths into the layout, or use byte length / code-point count as width.
- Turn the dialog into an `ft-tree` (Tree view composes one; the dialog is not one).
- Replace `_ft_fd_scan`'s glob ordering with a bash sort.
