# Keys

## Keys have events, and controls listen to them

A key is not a command that one control owns. A key is an **event**, and a control that binds it
is **subscribing** to that event:

```bash
ft-button name=save "Save" key=CTRL+s keyCap="Save" onKey='save_now $this'
```

That reads the way `onActivate=` reads, because it is the same idea: `on` + the thing that
happened. `key=` says *which* event (it is HTML's `event.key` — `ENTER`, `CTRL+s`, `[[:alpha:]]`),
and `onKey=` is the code that runs when it arrives, with `$this` (the control) and `$key` (the
token) in scope.

`keyCode` is deliberately NOT used for that code. In the DOM `keyCode` is a deprecated **number**
(13 for Enter) and `code` is the physical key (`"KeyA"`); if this framework ever grows either, it
will mean what HTML means by it.

## The words

| word | what it is | its CSS twin |
|---|---|---|
| **keymap** | one named table of bindings — a prototype's, a runlevel's, a control's own | a stylesheet |
| **the key cascade** | the rule that decides, for one control, which binding wins | the cascade |
| **computed keymap** | what a control's keys actually ARE, after the cascade | computed style |
| **shortcut** | a key that works anywhere on the screen (`accessKey`) rather than only on the focused control | — |
| **control key** | a key that lives only while its control has focus | — |

A control's computed keymap is built from four keymaps, nearest first: its own bindings, the
maps its `keymap=` names (a list, last wins), the map for the runlevel it is in, and its
prototype's. That is a cascade in exactly the CSS sense: many sources, one answer per key.

## Many listeners, one key

Two axes, and they are different questions.

**Within one control**, the cascade picks exactly one action per key: your binding replaces the
prototype's, the way an inline style replaces a stylesheet's. One control, one answer.

**Between PEERS** — controls with no ancestral relationship — several may listen for the same
key, and every one of them responds. A screen can have five Save buttons on five pages all
claiming `s`; only one page is on screen, so only one answers. Two claimants that are *both*
visible both act. This is where the event model earns its name, and where the rule below applies.

**Between a control and its ANCESTORS** it is propagation, not multicast. An event reaches an
ancestor only if the control lets it: handling a key keeps it unless the handler calls
`ft_bubble`. That is not a special case, it is the only thing that could work — a form binds the
arrows to move focus and a focused text field binds them to move its caret, so "both respond"
would move the caret *and* jump the focus out of the field on every keystroke.

Each origin propagates independently. Two peers that both receive an event each decide, on their
own, whether their own ancestors see it.

### The rule, in the vocabulary of the field

Key dispatch is **multicast**: one event, zero or more subscribed handlers. Handlers are invoked
in an order the framework does not specify and you must not rely on. A set of handlers for one
key is therefore well-defined only if it is **order-independent** — formally, if the handlers
**commute**, which is guaranteed when their write sets are **disjoint** and neither reads state
the other writes. Handlers that confine their effects to their own control satisfy this trivially
(their write sets are disjoint by construction). Handlers that contend for a **shared exclusive
resource** — the focus, which only one control can hold; a shared variable; a file; the scroll
position of a common ancestor — do **not** commute, and the result is **unspecified behaviour**:
the framework will do *something*, it will do it consistently within one build, and nothing about
it is guaranteed or supported.

### The same rule, in plain words

Several controls can listen for the same key, and they all get to react. That works beautifully
as long as each one **minds its own business** — it changes itself, or it changes a part of the
app nobody else is touching. Then it does not matter who goes first: you get both effects, every
time.

It stops working when two of them **reach for the same thing**. Only one control can have the
focus. Only one value can end up in a variable. If two handlers both grab, the last one to run
wins — and which one runs last is not something we promise, not something you should test for,
and not something that will necessarily stay the same. It is your job to make sure that does not
happen, and the framework will tell you when it can see that it has.

A good way to keep out of trouble: **a handler should change the control it is on, or something
only it touches.** If you find yourself writing two handlers for one key that both move the
focus, you do not want two listeners — you want one.

### What the framework does about it

It reports what it can see, and it does not pretend to fix what it cannot:

* `FT_DEBUG_KEYS=1` prints, at startup, every advertised shortcut that cannot fire — a letter
  claimed by controls *and* bound to something else that wins outright, so the controls go on
  drawing an underline for a key that does something different.
* Shortcut letters keep a LIST of claimants and activate **every** one that is visible and
  enabled. That is how five pages share `s`: only one of them is on screen, so the ambiguity
  never arises — and when two really are on screen, both act, which is what you asked for by
  giving them the same letter.
* Two handlers that both take the focus are not refused. That is unspecified behaviour and it
  belongs to you; the last write wins, and which one runs last is not a promise.

One thing a listener cannot do yet: hold code. `onActivate=` takes a FUNCTION NAME, because the
listener store is a space-separated list and `onActivate='fn arg'` would split in two. Writing
one is refused out loud rather than stored and silently skipped. Keys take code; listeners will.

## Handling, eating and passing on

A control that handles a key KEEPS it. Everything else is ordinary code — there are no reserved
words in an action, because a word the parser has to recognise is a word that is not code:

* **`ft_bubble`** — call it from a handler to let the event keep travelling outward *after* you
  have done your work. Handling and passing on are separate decisions, which is why this is a
  verb and not a return value: "I acted, and my ancestors should see this too" is a sentence the
  old "decline the key" could not say.
* **`onKey=''`** — code that runs and does nothing, so the control handled the key and, having
  not called `ft_bubble`, ate it.
* **no `onKey=` at all** — not a binding. A legend-only cap: advertised here, handled by whoever
  really owns the key.
* **`defaultKeys=false`** — silence every key the PROTOTYPE provides, for this control and
  everything inside it. It inherits, so one word covers a subtree. The keys the app wrote stay.

```bash
ft-button name=save text="Save" key=CTRL+s onKey='save_now $this'           # handles, keeps
ft-div    name=log  key=CTRL+s onKey='note_it $this; ft_bubble'             # handles, passes on
ft-label  name=quiet key=CTRL+s onKey=''                                    # eats it
ft-label  name=hint  key=TAB keyCap="Next field"                            # advertises only
```

Event state is per event. A handler may dispatch another one — a key that opens a dialog which
handles keys of its own — and the inner event does not answer the outer one's question.

## Writing bindings

Fields are separate shell words, so bash quoting does all the escaping and nothing inside a
field ever needs any:

```bash
key=<pattern> [keyCap="<label>"] [keyImp=crucial|important|normal|minor|0-255] [onKey='<code>']
```

`key=` opens a group; the fields after it describe it until the next `key=`. A group with a
`keyCap` and no `onKey` is legend-only: advertised, handled by somebody else. `onKey=''` is
different — that is a binding that eats the event. `EQUALS` is the
pattern for the `=` key. They are accepted on any tag, in `ft_keymap_set`, in `ft_set` (which
rebinds a live control), and as `ft-key` rows inside a block:

```bash
ft-keymap ft_keymap_tabs_browsing
    ft-key key=LEFT  keyCap="Previous tab" keyImp=crucial onKey='ft_tabs_prev $this'
    ft-key key=RIGHT keyCap="Next tab"     keyImp=crucial onKey='ft_tabs_next $this'
end_ft_keymap
```

## The calls

| call | what it does |
|---|---|
| `ft_keymap NAME` | declare an empty keymap. A duplicate is an error — use `ft_keymap_clear` to empty one |
| `ft_keymap_set MAP <fields…>` | add or replace bindings, as many per call as you like |
| `ft_keymap_unset MAP PATTERN` | remove one |
| `ft_keymap_clear MAP` | empty it, keeping it declared |
| `ft_keymap_dump MAP` | its bindings, for debugging |
| `ft_keymap_default MAP bubble\|drop` | what an unmatched key does |
