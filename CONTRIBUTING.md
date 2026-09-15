# Contributing to Fruity TUI

This file is the engineering contract. It binds humans and agents equally, and it is the first
thing to read before changing a line.

It exists because this framework is trying to be the library people reach for when they write a
terminal application in bash — the one whose source a stranger can open, read, and trust. That
ambition is only met one commit at a time, and it is lost the same way.

---

## 0. The standard, in one paragraph

**Think the design through before typing it, and write it correct the first time.** Not "write it,
run the suite, chase what turns red." A test is how you *prove* a thing correct and how you stop
it rotting later; it is not how you *discover* what your code does. If you find yourself
submitting a change to the suite to learn whether it works, stop — you have skipped the part
where you understood the problem. Reason like a mathematician: state what must be true, convince
yourself it is true by construction, and only then reach for the keyboard. Code written this way
is shorter, and the reader can see why it is right.

Take pride in it. Somebody will read this at 2am trying to fix their own app, and what they find
should make them think *"ah — of course."*

---

## 1. Fix the root, never the symptom

- Do not make a missing value present; fix what *absent* **means**.
- A fix you find yourself repeating per case is at the wrong layer. Move it down.
- Deleting a superseded mechanism is part of the fix, not a follow-up. Two ways to do one thing
  is a bug with a delayed fuse.

**The recurring root cause in this codebase, by a distance: the same predicate on one route and
not its siblings.** Removing a control repaired the screen; hiding it did not. `ft-modify`
repainted; `ft_remove_attribute` did not. A class default was documented at cascade level 5 and
implemented at level 1. When you fix a guard, *enumerate every route into that state* and fix
them together, or write down why the others differ.

### The specific shape it keeps taking: a table fed from a property

Several engine tables are derived from an instance property at construction — and the runtime
route gets forgotten, because construction is where you are looking when you add one. Three
found this way, and the third was found only by going looking for the other two's shape:

| table | set at construction | followed by `ft-modify` |
|---|---|---|
| `FT_DRAW` | ✓ | ✓ |
| `FT_FOCUSABLE` | ✓ | ✗ — `focusable=false` at runtime was inert |
| `FT_ACCEL_LIST` | ✓ | ✗ — the underline moved, the key stayed on the old letter |

`FT_FOCUSABLE` had a second half to the same bug: the value was not normalised on the
construction route either, so `focusable=true` — the spelling every other boolean here uses —
stored the string and read as false.

**If you add a fourth, wire every route at once**, and put the rule in ONE function that all of
them call (`_ft_focusable_apply`, `_ft_accel_register` / `_ft_accel_unregister`) rather than
writing the table in each. And when the two halves disagree about what is registered, make the
*undo* read the REGISTRY, not the property — the property is exactly what has just changed.

### The same shape one level down: a property the CLASS has to act on

Sweeping the engine tables finds the properties above. Sweeping the *classes* finds the next
one. `activeTab` on `ft-tabs` was declared layout-kind, so writing it reflowed the subtree — and
the reflow faithfully re-laid out the wrong tab, because which body is visible is `display` on
each body and only `_ft_tabs_show_only` writes those. `ft-modify tabs activeTab=1` moved the
number and switched nothing.

A property *kind* says what the ENGINE owes a change: repaint, reflow, restyle. It cannot say
what the CLASS owes. That is `FT_CLASS_REPROP[type]` — before `ft-tabs`, only `ft-beacon`
declared one. **If a property names the control's own state — `activeTab`, `selectedIndex`,
`value` — writing it has to do the work, not merely record the intention.** In the DOM every one
of those is settable and acts.

Sweeping every control for that one question found five more, and they are worth reading as a
set, because each looks different and is the same bug:

| control | writing it | what the user saw |
|---|---|---|
| `select.selectedIndex` | moved the number | painted the third option, `value` still answered the first |
| `option` with no `value=` | — | `ft_get se value` was EMPTY however the select was set |
| `slider.max` | moved the range | knob and value text drew 4, `ft_get` answered 5 |
| `checkbox.value` | moved two of three names | drew unchecked, reported `checked=true` |
| `radio.checked` | nothing at all | drew an empty circle at construction and at runtime |
| `label.scrollTop` | stored verbatim | painted line 9 of 12, property said 99 |

**Three mechanisms, and picking the wrong one is most of the work.** `FT_CLASS_REPROP` is told by
`ft-modify` and by nothing else — enough when the state can only change at runtime. `setProp=`
(`FT_CLASS_SETPROP`) is called from `_ft_setprop`, which is *every* route in: `ft-modify`, the
DSL, a state restore. Prefer it whenever **any route other than `ft-modify`** can produce the bad
state — `ft-slider value=50 max=10` writes the two in that order, and only the second one can fix
the first.

**"Construction is already handled" is not the test**, and reading it that way cost a real bug.
`ft-tabs` registered a REPROP for `activeTab` on exactly that reasoning: its children-complete
hook applies the index once the bodies exist, so construction was covered and `ft-modify` was
covered, and the mechanism looked sufficient. A STATE RESTORE is neither of those — it writes
through `_ft_setprop` — so a reloaded session came back with `activeTab=1` in the property and
tab one still on screen. Ask "can this state arrive any way but `ft-modify`", and remember that a
save file is one of the ways. And
when the rule belongs to no class at all — a scroll offset is bounded by the box's own published
`scrollHeight`/`clientHeight`, whatever kind of box it is — it belongs in `_ft_setprop` beside
the numeric validation.

**A reconciler READS the property that just changed**, so it runs at the END of `_ft_setprop`,
after the memo invalidation. Reconciling first, `ft-modify sl max=4` sanitized against a max of
100 out of the cache and changed nothing.

**And do not let the paint quietly fix it.** Every one of those bugs had a draw-time correction
keeping the picture right while the property lied — which is exactly why nobody noticed. When
you fix the write, delete the correction; when you cannot (a value that is only measurable at
paint time), say so where it stands. Assert the painted output beside the property in the test,
or the test proves half of it.

### And the shape below that: one property name, two vocabularies

The sweep above asks "does writing this name do the work?". The question after it is **"does
this name mean the same thing to everyone who reads it?"** — and `borderStyle` did not.
`ft-table` took `none|solid|heavy|double|rounded|dashed`; `ft-frame` took
`solid|double|dashed|dotted` and painted a plain light box for anything else while `ft_get`
reported the keyword back. `ft-help.bash` asks a *frame* for `rounded` and has been getting
square corners since it was written, by an author who had every reason to think it worked
because it does work one control over.

An enum belongs to the framework, not to whichever control drew it first. **Put the list in one
function and normalize AT THE WRITE** (`_ft_border_style`), so `ft_get` cannot answer a keyword
nothing draws — including a typo, which reads back as the thing on screen. Then make every
renderer answer for the whole list; a shared vocabulary is only shared if both ends know all of
it.

The same commit closed the plainest instance of the §1 headline there has been: `border=""`.
`_ft_draw_frame` read the empty string as false and drew no lines; `_ft_border` and `_ft_inset4`
read it as "nothing was set", fell through to the class default, and reserved the cell — so a
child sat one column inside a frame with no border to sit inside. **When a question already has
a function, a second reader may not answer it inline**, however short the inline version looks.

## 2. Copy CSS and the DOM verbatim

Selectors, specificity, the cascade, custom properties, `@keyframes`, `transition`,
`animation-timing-function`, event listeners, `preventDefault` semantics. Where CSS has a name,
use CSS's name — `font-size` is not the property that picks an arrow's size, but `size` is fine
and `arrowSize` is not. Where the terminal genuinely forces a deviation, **write the deviation
down** in `docs/styling-model.md` with the reason and the measurement.

Sketch the *user's* code first. If the demo needs an engine call to work, the feature is not
finished — `tests/test-api-surface.bash` enforces exactly that, and it may only go down.

## 3. Performance: the cost model is measured, not guessed

Bash charges roughly **5 µs per statement**, whatever the statement is. Measured on this machine:

| | |
|---|---|
| an indirect variable read | 3.3 µs |
| an associative-array read | 3.7 µs |
| an empty function call | 5.1 µs |
| a function call with one `local` | 7 µs |

So a six-statement function costs ~35 µs no matter how trivial it looks, and **you cannot make a
hot function meaningfully faster by tidying it — only by calling it less.** A frame that executes
6,000 statements takes 30 ms and there is no cleverness that changes that.

The lever that works, over and over in this project: **an expensive answer recomputed inside a
loop when it is constant across the loop.** The clip walk asked the same ancestors the same
question twenty-five times a frame about a tree that had not moved since layout. Look for that
shape first, always.

Rules for caches:
- **Establish the invalidation surface before writing the cache, and write it down.** Enumerate
  every route that can change the answer. If you cannot enumerate them, do not build it.
- **Invalidate by bumping a version, never by unsetting it** — an unset version and a fresh one
  compare equal, and a rebuilt control will read a dead one's answer.
- **Add the table to `go_cold` in `tests/_harness.bash`.** `tests/test-stale.bash` fails by name if you
  forget, because a cache the cold pass cannot drop is a cache it cannot test.
- **A property written FROM A DRAW must be written only when it changes.** The retained display
  list decides a block is stale from the control's write generation, and `_ft_setprop` bumps that
  on every write — so a draw that settles a value and stores it unconditionally makes a settled
  page re-derive that control forever. It costs nothing visible and never stops.
  `tests/test-retain.bash` counts derives per paint and is what catches it; `_ft_label_metrics`,
  `_ft_textfield_publish_metrics` and the textfield's two offset setters all carry the guard, and
  each one learned it the same way.
- **A cache that wins less than ~2 ms is not worth its invalidation risk.** Revert it and say so.
- Measure before and after with `tools/bench-drag.bash` (trust the *faithful* drive),
  `bench-layout`, `bench-modify`. Medians of enough runs to survive the noise, and report the
  spread.

Never `$(...)` in code the running app executes. Results come back in `FT_RET` or an out-variable,
and **any early return must leave `FT_RET` meaningful** — a stale `FT_RET` has frozen this
framework more than once.

## 4. Tests must be able to fail

A test that cannot fail is worse than no test, because it reads as coverage. Five were found in
this codebase in a single sweep; one had promised a "teeth check" since the initial import that
had never existed.

- **Every new gate gets its teeth checked**: sabotage the *subject* — the engine code, not the
  test — and watch it go red. Record what you sabotaged, next to the assertion.
- **Every "nothing bad happened" assertion needs a companion proving something happened.** Two
  blank screens compare equal. A sweep over an empty list passes every check inside it. If a
  gate reports "no residue" it must also report that ink was drawn; if it reports "clean" it must
  also report that the scan found something to look at.
- **Every fix lands with a test you watched fail on the old code**, and the commit says how you
  watched it fail.
- Fix the vacuity for the *class*, not the instance. `test-stale` learned that an unpainted scene
  is a failure; its sibling `test-residue` had the same hole for two more days.

## 5. Verify the instrument before believing it

**A probe that reports a defect is a claim, and it needs the same scrutiny as a fix.** Before
reporting a measurement, break the thing the probe is watching and confirm the probe notices. If
it cannot see a deliberate break, it cannot see a real one. Build the check into the harness: a
canary that must collapse, or a positive assertion that the sabotage landed.

Traps that have each produced a false bug report here:

- Reading `FT_OUT` after a settle — `ft_redraw_dirty` ends in `ft_flush`, which writes the buffer
  to the tty **and clears it**. It reads zero however much was painted. Capture the tty stream
  instead, as `tests/test-residue.bash` does.
- Sabotaging a **wrapper** and believing you disabled the work. `ft_layout` is four lines around
  `ft_measure` + `_ft_pass_arrange`, and other paths call the passes directly. A single-function
  stub of a pipeline is never the whole of it.
- A glyph dump is not a picture. The big arrow paints upper-anchored cells as *lower* blocks with
  fg/bg reversed, so a row of `▁` beneath a row of `▇` is a mirror pair that reads as violent
  asymmetry in text. Use `/tmp/ink-map.bash`, not your eyes on characters.
- Timing a pty gate while another one is running. They contend; re-run solo before believing a
  pixel-gate failure. And a timed-out command leaves its test **still running**.

## 6. Naming and shape

- **Spell names out.** `BA_DIR` and `LDR_SIDE` were engine globals that silently clobbered an
  *app's* local variables through dynamic scoping. Prefix everything the framework owns.

  **This rule was written down, and then not applied to the API it was written for.** The
  most-called public function in the framework was `ft_pp`, with `ft_ppw` beside it — listed in
  README's naming conventions six lines above the bullet that says *"if a name needs a comment
  to say what it holds, the name is wrong"*. `ft_cprop` and `ft_cget` hid a `c` for "coerced"; `ft_plist_*` read as
  Apple's property-list format and meant the DOM's token list. They are now `ft_print_at`,
  `ft_print_at_width`, `ft_resolved_prop`, `ft_own_prop`, `ft_tokenlist_*`.

  **The test: if explaining the name takes a sentence, the name is wrong.** `sgr` is ECMA-48's
  own word for the thing and passes it; `pp` explains as "print at a position, honouring the
  clip rect" and does not. Terms of art survive — `ft_sgr`, `ft_die`, `ft_ease`, `ft_hrule`,
  `ft_kbd_*` — abbreviations of ordinary words do not.

  **A name is not exempt because it is hot.** That was the unspoken excuse, and it is arithmetic
  that does not work: bash charges per statement, not per character (§3), so the long name costs
  exactly nothing at run time. The abbreviation bought a shorter source line and sold the
  framework's readability to do it.

  And name a helper for the global it fills, the way `ft_fit`→`FT_FIT`, `ft_hrule`→`FT_HRULE`
  and `ft_display_width`→`FT_DISPLAY_WIDTH` already do. `ft_pos` filled `FT_CURSOR_POSITION`;
  it is `ft_cursor_position` now, and the pattern is a rule rather than a coincidence.
- **Observable per-control state is a property, not a parallel array.** If `ft_state_save` should
  persist it, or an app should be able to read it, it is a property. A parallel array is for
  derived state the app has no business seeing.
- Private names carry `_`. If an app or a demo needs one, that is a **missing public API** — add
  it with a documented name rather than letting the underscore leak.
- One concept, one function. Three near-copies of a blend, two ghost painters, four side-arms
  differing in one silent line — each of those was a bug waiting for the day someone fixed one
  copy.

  **But measure before you merge: near-identical bodies are not proof of one concept.**
  `ft_print_at` and `ft_print_at_width` differ by one argument and read like one function with
  an optional detail. On the same full-width coloured row they measure **368 µs and 44 µs**
  (`tools/bench-draw-primitive.bash`). The second is not a shortcut through the first; it is a
  different question — *has the caller already answered "how wide is this?"* — and 8× is what
  the question costs. It carries a different promise, too: the width form is exempt from the tab
  guard because its callers came through `ft_fit`. **An optional argument cannot express a
  different promise; it conceals one.** The merge was priced anyway and was affordable (one
  branch, +6.3 µs a call, +0.95 ms on a page build, ~1% of a repaint) — and still wrong. Two
  promises, two names, and the names now say which is which.

## 7. Comments explain *why*

The code says what it does. A comment earns its place by saying what a reader cannot recover:
the measurement that settled a choice, the alternative that was tried and was worse, the trap
that will look like a bug to the next person. Several comments in this codebase record a number
that took an hour to obtain — that is the standard.

Do not narrate. Do not apologise. Do not leave a comment describing a workaround for a bug you
could have fixed.

## 8. Practical hazards on this machine

- Edit through the UNC path, then `wsl.exe -d rocky -- bash -lc 'chown drussell:drussell FILE'`.
- Put probes in **script files**. Inline `wsl.exe bash -lc '…$var…'` silently strips variables and
  loops; an unquoted heredoc eats `${...}`.
- `source X | head` runs `source` in a **subshell** — every function it defines is discarded. So
  does warming a cache inside `$(…)`.
- Backticks inside a double-quoted string are command substitution. One in a test's prose ran a
  command and put a line on stderr, which fails a whole suite file.
- `local a=$1 b=${arr[$a]}` on one line reads the **old** `a`. Split dependent initialisers.
- Long commit messages: `git commit -F /tmp/msg.txt`. Passing them inline through `wsl.exe`
  breaks on quoting and the commit silently fails.
- Run the full suite **solo** — `tests/run-all.bash`, after killing strays.

## 9. Commits

One commit per coherent change. The message explains **why**, records what was measured, and
names what was rejected and on what evidence. Read `git log` for the voice; it is part of the
project's documentation and several entries have already saved someone a day.
