#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — controls/ft-textfield.bash
#
#  The "textfield" prototype: a single-line editable text input — CSS's
#  <input type=text>. It sits in an input WELL (FT_COLOR_INPUT, like select/
#  listbox), keeps its own `value` (a button's _on_activate just reads it, same
#  as every other value-bearing control), and carries a visible CARET.
#
#  Editing is readline-flavoured. Motion and deletion, by named key AND by the
#  classic Emacs/readline control chords the input layer now delivers:
#     ← / Ctrl+B  back a char        → / Ctrl+F  forward a char
#     Home/Ctrl+A start of line      End/Ctrl+E  end of line
#     Backspace/Ctrl+H delete left   Del/Ctrl+D  delete right
#     Ctrl+K kill to end             Ctrl+U kill to start        Ctrl+W kill word
#     Insert   toggle insert⇄overwrite
#  Printable characters (including space) type into the field.
#
#  Cursor: insert mode shows a bar/underline caret, overwrite mode a solid
#  block; the Insert key flips between them. Override explicitly with
#  cursorStyle=bar|underline|block. The value scrolls HORIZONTALLY so the caret
#  is always on screen even when the text is longer than the box.
#
#  Properties: value, placeholder (dim hint when empty), size (visible columns,
#  default 20), maxLength (0 = unlimited), cursorStyle. Hook: onChange=fn
#  fires with (name, newvalue) after any edit.
#
#  Depends on ft-core.bash and ft-forms.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_TEXTFIELD_LOADED:-}" ]] && return 0
_FT_TEXTFIELD_LOADED=1

# Per-field state, keyed by control name. ALL must be associative — a plain array
# would evaluate the string key as an arithmetic index (name→0), silently sharing
# one slot across every field and crashing under `set -u`.
declare -A FT_TEXTFIELD_CARET=() FT_TEXTFIELD_MODE=() FT_TEXTFIELD_ANCHOR=() FT_TEXTFIELD_TABESC=() FT_TEXTFIELD_MARK=() FT_TEXTFIELD_SBDRAG=() # caret / mode / selection anchor / one-shot tab-release / emacs mark active / scrollbar-drag capture

# …BUT NOT THE SCROLL OFFSETS. Those were FT_TEXTFIELD_SCROLL and FT_TEXTFIELD_VSCROLL, two
# private tables holding a fact the DOM has public names for — and docs/api-naming.md wrote down
# what that cost:
#
#     ft-modify tf scrollTop=5      the view stayed on line 1, ft_get answered 5
#     ft-scrollbar for=tf           steered nothing at all
#     ft_state_save                 carried an offset nothing restored from
#
# They are `scrollTop` and `scrollLeft` now. Two accessors rather than thirty inline reads,
# because the value needs coercing once (an absent offset is 0) and because the WRITE has to go
# through _ft_setprop: that is what bounds it against the pair the draw publishes
# (_ft_clamp_scroll), what bumps the write generation the retained display list watches, and
# what a state restore already travels down. Read RAW — an offset is instance state, never
# inherited and never styled, so the cascade has nothing to add and costs ~50µs to say so.
_ft_tf_voff()     { _ft_get_raw "$1" scrollTop;  case $FT_RET in ''|*[!0-9]*) FT_RET=0 ;; esac; }
_ft_tf_hoff()     { _ft_get_raw "$1" scrollLeft; case $FT_RET in ''|*[!0-9]*) FT_RET=0 ;; esac; }
# WRITTEN ONLY WHEN IT CHANGES, and that is not an optimisation. The draw settles the offset on
# every paint, so an unconditional write would bump the control's write generation every frame —
# and that counter is what the retained display list uses to decide a block is stale, so a
# settled page would re-derive this field forever. tests/test-retain.bash counts exactly that,
# and caught it. (The same reason _ft_textfield_publish_metrics guards its own two writes.)
_ft_tf_voff_set() { local v="_ftp_${1}_scrollTop"
                    [[ "${!v:-}" == "$2" ]] || _ft_setprop "$1" scrollTop  "$2"; return 0; }
_ft_tf_hoff_set() { local v="_ftp_${1}_scrollLeft"
                    [[ "${!v:-}" == "$2" ]] || _ft_setprop "$1" scrollLeft "$2"; return 0; }
# …and this is the half of that state a REPAINT can see: where the caret sits, what is
# selected, and how far the view has scrolled. It is not properties, so the retained display
# list's per-control write counter cannot see it move; a prototype declares its own paint state
# instead (FT_PROTO_PAINT_STATE, ft-forms.bash). Registered at load time beside the arrays it
# names, so a new one added above is added here in the same edit.
#
# MODE is in it because the block cursor and the bar cursor are different pixels, and the
# scrollbar drag is not: it captures the mouse, it does not change a cell.
#
# The two OFFSETS are no longer in it, and deliberately: they are properties now, so the write
# counter this signature exists to supplement already sees them move. Listing them here as well
# would only be a second, slower way to notice the same thing.
_ft_textfield_paint_state() {   # name → FT_RET
    FT_RET="${FT_TEXTFIELD_CARET[$1]:-}:${FT_TEXTFIELD_ANCHOR[$1]:-}:${FT_TEXTFIELD_MARK[$1]:-}"
    FT_RET+=":${FT_TEXTFIELD_MODE[$1]:-}"
}
# ── Runlevels: how engaged the field is ──────────────────────────────────────
# A focused field is NOT automatically editing: it is merely highlighted (a lit
# border), and bare keys BUBBLE so k/n/accelerators keep driving the app and
# arrows/Tab keep moving focus — navigation stays slick. ENTER drops INTO edit
# mode (`runlevel=editing`), and the full editing keymap (ft_keymap_textfield) is
# installed as this instance's overlay. ESC (or Tab away) returns to `unfocused`.
#
# The runlevel is an ORDINARY PROPERTY, so `:editing` cascades, `ft-modify f
# runlevel=editing` works from anywhere, and changing it invalidates the style
# cache by itself — this used to be a private FT_TF_EDIT array that the CSS
# engine reached into, with two hand-written _ft_css_inval calls to compensate.
#
# This is declared at LOAD TIME, not inside ft_prototype_textfield with the rest of the
# prototype, and it has to be: ft_runlevels registers the `textfield:editing` STATE, and a
# stylesheet naming `:editing` is parsed long before the first field is ever constructed.
# Deferring it to the prototype constructor makes the rule silently fail to match — the field
# stays at the :focused colour with nothing to indicate why.
#
# Being outside a constructor is exactly why it names its prototype with `for=`: there is
# no prototype under construction to infer one from.
ft_runlevels for=textfield \
    scrolling=ft_keymap_textfield_scrolling \
    perusing=ft_keymap_textfield_perusing \
    editing=ft_keymap_textfield

# The hot predicate. Reads the property VARIABLE directly rather than through
# ft_resolved_prop: `runlevel` is never subscripted and never text/value, so a raw read
# is exact — and this sits in the draw path, where a property call would not.
# ENGAGED = a caret is live and a selection is possible: `editing` OR `perusing`. Almost
# everything that used to ask "is it editing?" meant this — the caret drawn, the view
# following it, a mouse press placing it, ESC belonging to the field. Whether the value may
# be CHANGED is not asked at runtime at all: the mutating keys are simply absent from the
# perusing keymap, which is a stronger guarantee than a check inside every handler.
_ft_textfield_engaged() {
    local v="_ftp_${1}_runlevel" r
    r=${!v-}
    [[ "$r" == editing || "$r" == perusing ]]
}
# …and the narrower question: may the VALUE change? Only `editing` binds the mutating keys.
# Used by the derived legend, which must not advertise Cut/Paste/Undo/New-line at a runlevel
# where those keys are not bound at all.
_ft_textfield_can_mutate() { local v="_ftp_${1}_runlevel"; [[ "${!v-}" == editing ]]; }

# Where each field's scrollbars ended up, published by the draw that painted them:
#   FT_TEXTFIELD_VBAR[name] = "x thumbY0 thumbY1 trackY0 trackN maxScroll"
#   FT_TEXTFIELD_HBAR[name] = "y thumbX0 thumbX1 trackX0 trackN maxScroll"
# The thumb's geometry is worked out during the draw (it needs the wrapped line
# count and the resolved scroll offsets), and TWO other things need it afterwards:
# the shimmer, which must ride the thumb instead of painting over it, and the
# mouse, which must know what it grabbed. Recomputing it in each of them would be
# three copies of the same arithmetic drifting apart. Empty/absent = no scrollbar
# on that axis. MUST be declare -A (a bare array evaluates the name as arithmetic).
declare -A FT_TEXTFIELD_VBAR=() FT_TEXTFIELD_HBAR=()

# Built once, by the prototype that declares `keymap=textfield_idle`.
#
# A textfield has FOUR keymaps — idle, scrolling, perusing, editing — and they are one family
# built together: perusing is literally the editing map minus every mutation, so they have to
# be read (and changed) side by side. They are defined here, under the name of the one
# the prototype starts in; the other three are reached through the runlevel ladder.
_ft_define_keymap_textfield_idle() {
    # The EDITING keymap — the map `editing=ft_keymap_textfield` names at the top of this file.
    # It is a RUNLEVEL map, and it used to be the one map nobody declared: the old positional
    # binding call brought it into being as a side effect, through a nameref. Declared here now.
    ft-keymap ft_keymap_textfield
        ft-key key=LEFT onKey='ft_textfield_move_left $this'  key=RIGHT onKey='ft_textfield_move_right $this'
        ft-key key=UP onKey='ft_textfield_move_up $this'  key=DOWN onKey='ft_textfield_move_down $this'
        ft-key key=HOME onKey='ft_textfield_move_home $this'  key=END onKey='ft_textfield_move_end $this'
        ft-key key=SHIFT+left onKey='ft_textfield_select_left $this'  key=SHIFT+right onKey='ft_textfield_select_right $this'
        ft-key key=SHIFT+up onKey='ft_textfield_select_up $this'  key=SHIFT+down onKey='ft_textfield_select_down $this'
        ft-key key=SHIFT+home onKey='ft_textfield_select_home $this'  key=SHIFT+end onKey='ft_textfield_select_end $this'
        ft-key key=ENTER onKey='ft_textfield_enter $this'
        ft-key key=BACKSPACE onKey='ft_textfield_backspace $this'  key=DEL onKey='ft_textfield_delete $this'
        ft-key key=INS onKey='ft_textfield_toggle_mode $this'  key=SPACE onKey='ft_textfield_space $this'
        ft-key key=CTRL+b onKey='ft_textfield_move_left $this'  key=CTRL+f onKey='ft_textfield_move_right $this'
        ft-key key=CTRL+a onKey='ft_textfield_move_home $this'  key=CTRL+e onKey='ft_textfield_move_end $this'
        ft-key key=CTRL+h onKey='ft_textfield_backspace $this'  key=CTRL+d onKey='ft_textfield_delete $this'
        ft-key key=CTRL+k onKey='ft_textfield_kill_to_end $this'  key=CTRL+u onKey='ft_textfield_kill_to_start $this'
        ft-key key=CTRL+w onKey='ft_textfield_ctrl_w $this'  key=ALT+w onKey='ft_textfield_copy $this'  key=CTRL+c onKey='ft_textfield_ctrl_c $this'  key=ALT+a onKey='ft_textfield_select_all $this'
        ft-key key=CTRL+x onKey='ft_textfield_ctrl_x $this'  key=CTRL+v onKey='ft_textfield_yank $this'
        ft-key key=CTRL+SPACE onKey='ft_textfield_set_mark $this'  key=CTRL+g onKey='ft_textfield_keyboard_quit $this'
        ft-key key=CTRL+y onKey='ft_textfield_yank $this'  key=ALT+y onKey='ft_textfield_yank_pop $this'
        ft-key key='CTRL+/' onKey='ft_textfield_undo $this'  key=CTRL+r onKey='ft_textfield_redo $this'
        ft-key key=CTRL+z onKey='ft_textfield_undo $this'
        ft-key key=PASTE onKey='ft_textfield_paste $this'
        ft-key key=ALT+b onKey='ft_textfield_move_word_back $this'  key=ALT+f onKey='ft_textfield_move_word_fwd $this'  key=ALT+d onKey='ft_textfield_kill_word_fwd $this'
        ft-key key=ALT+left onKey='ft_textfield_move_word_back $this'  key=ALT+right onKey='ft_textfield_move_word_fwd $this'
        ft-key key=SHIFT+ALT+left onKey='ft_textfield_select_word_back $this'  key=SHIFT+ALT+right onKey='ft_textfield_select_word_fwd $this'
        ft-key key=CTRL+home onKey='ft_textfield_move_doc_home $this'  key=CTRL+end onKey='ft_textfield_move_doc_end $this'
        ft-key key=SHIFT+CTRL+home onKey='ft_textfield_select_doc_home $this'  key=SHIFT+CTRL+end onKey='ft_textfield_select_doc_end $this'
        ft-key key='ALT+<' onKey='ft_textfield_move_doc_home $this'  key='ALT+>' onKey='ft_textfield_move_doc_end $this'
        ft-key key=PGUP onKey='ft_textfield_pgup $this'  key=PGDN onKey='ft_textfield_pgdn $this'
        ft-key key=TAB onKey='ft_textfield_tab $this'  key=BTAB onKey='ft_textfield_btab $this'  key=ESC onKey='ft_textfield_esc $this'
        ft-key key='?' onKey='ft_textfield_insert_char $this $key'        # catch-all: any single typed character
    end_ft_keymap
    # A field's legend is STATE-DEPENDENT (idle vs editing, a selection to copy, a
    # kill-ring to paste), so its caps come from _ft_caps_textfield (below), not from
    # static keyCap= fields here — those would show "Enter: Edit" even mid-edit.
    # The INACTIVE keymap — merely focused, and deliberately almost empty. Movement
    # keys are NOT bound here: arrows keep moving FOCUS while a field is only focused,
    # which is the whole reason the scrolling runlevel exists. Printable keys are
    # unbound too, so k/n and accelerators keep driving the app. It is this prototype's OWN
    # map, so the engine has already declared it — this only fills it.
    ft_keymap_set ft_keymap_textfield_idle \
        key=ENTER onKey='ft_textfield_engage $this' \
        key='CTRL+/' onKey='ft_textfield_undo $this'  key=CTRL+r onKey='ft_textfield_redo $this' \
        key=CTRL+z onKey='ft_textfield_undo $this' \
        key=CTRL+c onKey='ft_textfield_ctrl_c $this'  key=ALT+w onKey='ft_textfield_ctrl_c $this'
        # …copy IS bound here, though almost nothing else is: landing on a field and
        # pressing copy should give you what is in it. Unbound, Ctrl+C fell through to the
        # run loop, which used to quit — the worst possible answer to "copy this".

    # The SCROLLING keymap — one Enter in. The movement keys that used to live in the
    # idle map are here, so they capture only once you have asked for them. Each still
    # bubbles when there is nothing left to scroll, so you fall out of the far edge
    # into focus navigation rather than getting stuck.
    ft-keymap ft_keymap_textfield_scrolling
        ft-key key=LEFT onKey='ft_textfield_idle_left $this'  key=RIGHT onKey='ft_textfield_idle_right $this'
        ft-key key=HOME onKey='ft_textfield_idle_home $this'  key=END onKey='ft_textfield_idle_end $this'
        ft-key key=PGUP onKey='ft_textfield_idle_pgup $this'  key=PGDN onKey='ft_textfield_idle_pgdn $this'
        ft-key key='CTRL+/' onKey='ft_textfield_undo $this'  key=CTRL+r onKey='ft_textfield_redo $this'
        ft-key key=CTRL+z onKey='ft_textfield_undo $this'
        # The headline keys carry LEGEND metadata (the keyCap=/keyImp= the rows above omit):
        # this rung is new, and a mode that announces nothing is a trap — you press Enter, land
        # somewhere you have never been, and nothing on screen says what changed or how to get out.
        ft-key key=UP    keyCap=Scroll keyImp=crucial   onKey='ft_textfield_idle_up $this'
        ft-key key=DOWN  keyCap=Scroll keyImp=crucial   onKey='ft_textfield_idle_down $this'
        ft-key key=ENTER keyCap=Edit   keyImp=crucial   onKey='ft_textfield_activate $this'
        ft-key key=ESC   keyCap=Leave  keyImp=important onKey='ft_textfield_leave $this'
    end_ft_keymap

    # The PERUSING keymap — a caret you drive through content you cannot change: move,
    # select, copy. It is the editing map MINUS every mutation. Nothing here has to
    # check read-only-ness at runtime: the keys that would alter the value are simply
    # not bound, which is a stronger guarantee than a guard inside each handler.
    ft-keymap ft_keymap_textfield_perusing
        ft-key key=LEFT onKey='ft_textfield_move_left $this'  key=RIGHT onKey='ft_textfield_move_right $this'
        ft-key key=UP onKey='ft_textfield_move_up $this'  key=DOWN onKey='ft_textfield_move_down $this'
        ft-key key=HOME onKey='ft_textfield_move_home $this'  key=END onKey='ft_textfield_move_end $this'
        ft-key key=PGUP onKey='ft_textfield_pgup $this'  key=PGDN onKey='ft_textfield_pgdn $this'
        ft-key key=SHIFT+left onKey='ft_textfield_select_left $this'  key=SHIFT+right onKey='ft_textfield_select_right $this'
        ft-key key=SHIFT+up onKey='ft_textfield_select_up $this'  key=SHIFT+down onKey='ft_textfield_select_down $this'
        ft-key key=SHIFT+home onKey='ft_textfield_select_home $this'  key=SHIFT+end onKey='ft_textfield_select_end $this'
        ft-key key=CTRL+b onKey='ft_textfield_move_left $this'  key=CTRL+f onKey='ft_textfield_move_right $this'
        ft-key key=CTRL+a onKey='ft_textfield_move_home $this'  key=CTRL+e onKey='ft_textfield_move_end $this'
        ft-key key=ALT+b onKey='ft_textfield_move_word_back $this'  key=ALT+f onKey='ft_textfield_move_word_fwd $this'
        ft-key key=ALT+left onKey='ft_textfield_move_word_back $this'  key=ALT+right onKey='ft_textfield_move_word_fwd $this'
        ft-key key=SHIFT+ALT+left onKey='ft_textfield_select_word_back $this'  key=SHIFT+ALT+right onKey='ft_textfield_select_word_fwd $this'
        ft-key key=CTRL+home onKey='ft_textfield_move_doc_home $this'  key=CTRL+end onKey='ft_textfield_move_doc_end $this'
        ft-key key=SHIFT+CTRL+home onKey='ft_textfield_select_doc_home $this'  key=SHIFT+CTRL+end onKey='ft_textfield_select_doc_end $this'
        ft-key key='ALT+<' onKey='ft_textfield_move_doc_home $this'  key='ALT+>' onKey='ft_textfield_move_doc_end $this'
        ft-key key=ALT+w onKey='ft_textfield_copy $this'  key=CTRL+c onKey='ft_textfield_ctrl_c $this'  key=ALT+a onKey='ft_textfield_select_all $this'
        ft-key key=CTRL+SPACE onKey='ft_textfield_set_mark $this'  key=CTRL+g onKey='ft_textfield_keyboard_quit $this'
        ft-key key=TAB onKey='ft_textfield_tab $this'  key=BTAB onKey='ft_textfield_btab $this'  key=ESC onKey='ft_textfield_esc $this'
    end_ft_keymap
}
ft_prototype_textfield() {
    # What a repaint can see that is not a property (see _ft_textfield_paint_state).
    FT_PROTO_PAINT_STATE[textfield]=_ft_textfield_paint_state
    # Register this prototype's own properties (paint-only; they never reflow — the
    # box is a fixed `size`). Registering them also lets the positional DSL take
    # e.g. placeholder="Type here" as a property even though its value has
    # spaces (a known key always assigns).
    ft_prop_kind_set placeholder paint
    ft_prop_kind_set cursorStyle paint
    ft_prop_kind_set maxLength   paint
    ft_prop_kind_set wrap        paint     # textarea: wrap long lines vs scroll H
    ft_prop_kind_set rows        layout    # >1 turns the field into a textarea
    ft_prop_kind_set wrapIndicator  layout # textarea: ↩ glyph on soft-wrapped lines
    ft_prop_kind_set newlineIndicator layout # textarea: ¶ glyph where a hard \n ends a line
    ft_prop_kind_set showLineNumbers layout  # textarea: line numbers down the left
    ft_prop_kind_set currentLineHighlight paint # textarea: lift the row the caret is on
    ft_prop_kind_set acceptsTab     paint   # auto (default) | true | false — see _ft_textfield_tab_inserts
    ft_prop_kind_set keymode        paint   # emacs (default, readline keys) | vi (reserved)
    ft_prop_kind_set readOnly       paint   # true → a text VIEWER: navigate/select/copy, no edits
    ft_prop_kind_set markdown       paint   # true → a rich-text VIEWER: render value as markdown
    ft_prop_kind_set activateToEdit paint   # true (default): Enter to edit; false: editable on focus
    ft_prop_kind_set editHint       paint   # custom status-bar hint shown while editing (spaces ok)
    # Where the caret lands the FIRST time a field is entered. Negative counts back
    # from the end, -1-based like array APIs (-1 = the very end). ...AtCharacter is an
    # index into the value and SUPERSEDES ...AtLine (a 0-based logical line).
    ft_prop_kind_set cursorStartAtCharacter paint
    ft_prop_kind_set cursorStartAtLine      paint
    # BORDER ANIMATION — a border-level capability (see "border animation"), so the
    # property kinds are registered generically once. activateBorderAnimation picks the
    # animation for the activate event (default none/off); activateAnimationTypingDelay is
    # the debounce; borderAnimation* are the shared tunables. Property kinds are global,
    # so registering here makes any control accept `borderAnimationGlow=24` etc.
    _ft_border_anim_register_props
    # A text field's border carries its edit-state colour, so animations shade THAT.
    ft_prototype extends=ft_control borderSgr=_ft_textfield_border_sgr focusable=true
    # keymode is left ALONE by default → emacs/readline (the keymap below). It is
    # reserved for an opt-in `vi` mode (modal editing) added later; apps set it
    # per field and can persist the user's preference.
    # NB: cursorStartAtCharacter is deliberately NOT in the defaults. Its default of 0
    # is a FALLBACK inside _ft_textfield_start_caret — setting it here would mean every field
    # has it, and it would then always supersede cursorStartAtLine.
    # (the per-frame paint routine is bound to the engine per-instance on activate via
    # ft_anim_bind, so it can carry the instance+structure — no prototype hook needed)
    # overflowY=auto BECAUSE THAT IS WHAT IT DOES. A textarea taller than its box scrolls, and
    # paints its own bar down its right edge — and it was declaring `overflow: hidden` the whole
    # time, inherited from the base control. So ft_has_scrollbar, the framework's one answer to
    # "does this box present a scrollbar", said NO about a field with a visible thumb, and an
    # ft-scrollbar bound with for= had nothing to bind to. Same declaration ft-label carries,
    # for the same reason, and gated the same way: the published scrollHeight/clientHeight pair
    # decides, so a field that fits still answers no.
    #
    # The AXIS property, never the `overflow` shorthand: _ft_inset4 reserves a stable gutter
    # column from the shorthand (and a row from overflowX), and a textfield draws its bars
    # INSIDE its own border rather than in a reserved lane. Declaring the shorthand here would
    # silently take a column off every field on screen. overflowX is left unset for exactly
    # that reason — see the note on _ft_textfield_publish_metrics.
    # WHICH PROPERTIES CAN CHANGE WHAT THIS FIELD DISPLAYS: its value, and the `text` alias the
    # DSL's bare content lands in. Nothing else — and saying so is worth ~150 ms per Enter on a
    # 1200-line document, because the text generation is what invalidates the wrap memo and that
    # memo's key already carries the width and the wrap flag BY NAME
    # (_ft_textfield_layout: "$name|$w|$wrap|$gen").
    #
    # `placeholder` is deliberately absent: it is drawn INSTEAD of a value, never wrapped by the
    # layout this generation guards. `rows`, `size` and `showLineNumbers` are absent because they
    # change the WIDTH or the row count, both of which the key carries itself.
    ft_prototype keymap=textfield_idle mouse=textfield wheelProbe=_ft_textfield_wheel_probe \
        textProps="value text" \
        defaults="display=inline-block size=20 rows=1 maxLength=0 wrap=true wrapIndicator=false newlineIndicator=false showLineNumbers=false acceptsTab=auto keymode=emacs readOnly=false markdown=false activateToEdit=true overflowY=auto"
}

# _ft_textfield_publish_metrics NAME TOTAL VISIBLE — the DOM's answer to "did this overflow?",
# for a field whose draw has just worked out both numbers.
#
# Every variant of the draw already computes them (the wrapped/rendered line count and the rows
# inside the border) in order to clamp its own scroll, so the numbers are free here; what was
# missing was publishing them. Without that, ft_has_scrollbar read nothing and answered no about
# a field that was visibly scrolling, and `ft-scrollbar for=thatfield` — documented as needing
# no glue at all — had nothing to read.
#
# WRITTEN ONLY WHEN THEY CHANGE. This is the draw path, and an unconditional property write per
# paint would churn the cascade cache for nothing (the same reason _ft_label_metrics guards its
# two writes). EXTENT BEFORE VIEWPORT, and both before anything reads them: _ft_clamp_scroll in
# _ft_setprop bounds a scroll offset against this pair, so a publish that landed in the other
# order would clamp against the measurement it is replacing.
#
# THE HORIZONTAL PAIR IS DELIBERATELY NOT PUBLISHED. scrollWidth for a non-wrapping field is the
# widest line's DISPLAY width, which means walking every line of the document on every paint —
# and a textfield is the one control here that holds a thousand-line document (see
# docs/… the line store). The vertical pair is what a textarea's scrollbar is; the horizontal
# one wants a cached measurement first, and is written up rather than half-done.
_ft_textfield_publish_metrics() {      # name total visible
    local n=$1 v="_ftp_${1}_scrollHeight"
    [[ "${!v:-}" != "$2" ]] && _ft_setprop "$n" scrollHeight "$2"
    v="_ftp_${1}_clientHeight"
    [[ "${!v:-}" != "$3" ]] && _ft_setprop "$n" clientHeight "$3"
    return 0
}

# ── Idle-mode movement (a READ-ONLY field scrolls; editable bubbles to nav) ──
# Merely focused, a read-only field scrolls its VIEW directly with the arrows —
# every press moves the content by one line (no hidden caret to chase, so it never
# feels stuck). An editable field declines (FT_KEY_BUBBLE=1) so the same key moves
# focus instead. Enter is what turns an editable field into an editor / RO cursor.
_ft_textfield_view_maxv() {            # name → FT_RET = max vertical scroll (total - visible)
    local n=$1
    local vh=$(( ${FT_MEASURED_HEIGHT[$n]:-3} - 2 )); (( vh < 1 )) && vh=1
    _ft_textfield_textw "$n"; _ft_textfield_layout "$n" "$FT_RET"
    FT_RET=$(( ${#FT_TEXTFIELD_LINES_TEXT[@]} - vh )); (( FT_RET < 0 )) && FT_RET=0
}
_ft_textfield_vscroll_by() {           # name delta — scroll a viewer vertically, clamped
    local n=$1 d=$2
    _ft_textfield_md "$n" && { _ft_textfield_md_scroll "$n" "$d"; return 0; }
    _ft_textfield_view_maxv "$n"; local maxv=$FT_RET
    _ft_tf_voff "$n"; local v=$(( FT_RET + d ))
    (( v < 0 )) && v=0; (( v > maxv )) && v=$maxv
    _ft_tf_voff_set "$n" "$v"; ft_dirty "$n"; return 0
}
_ft_textfield_hscroll_by() {           # name delta — pan the view sideways, clamped
    local n=$1 d=$2
    _ft_textfield_hscroll_max "$n"; local max=$FT_RET               # a pan is COLUMNS
    _ft_tf_hoff "$n"; local v=$(( FT_RET + d ))
    (( v > max )) && v=$max; (( v < 0 )) && v=0
    _ft_tf_hoff_set "$n" "$v"; ft_dirty "$n"; return 0
}
_ft_textfield_pagerows()  { local n=$1; local vh=$(( ${FT_MEASURED_HEIGHT[$n]:-3} - 2 )); (( vh < 2 )) && vh=2; FT_RET=$(( vh - 1 )); }
_ft_textfield_multiline() { ft_resolved_prop "$1" rows 1; (( FT_RET > 1 )); }   # a text BOX, not one line
_ft_textfield_wrapping()  { ft_resolved_prop "$1" wrap true; [[ "$FT_RET" == true ]]; }
# ── The SCROLLING runlevel's arrows ──────────────────────────────────────────
# ONCE YOU HAVE ENTERED A CONTROL, THE ARROWS BELONG TO IT — all four of them, on both
# axes, whether or not that axis has anything to scroll. They are only bound at this
# runlevel (Enter got you here; ft_textfield_engage skips the rung entirely for a field
# with nothing to scroll), and leaving is Tab or Esc.
#
# They used to bubble whenever the axis could not move: at the top of a document, at the
# end of a line, and — the case that made it obvious — pressing Up in a panel that only
# scrolls SIDEWAYS. You asked to look inside a control and a stray arrow threw you out of
# it into a neighbour, so exploring the keys of a control you had deliberately entered was
# something you had to do carefully. Entering a thing should mean you can press keys in it
# without thinking; the way out should be a key you chose, not one you got caught by.
#
# (The `idle_` names predate the runlevel ladder — these are the SCROLLING rung's handlers.
# Renaming them would touch the keymap tables, the legend caps and ft-label's note about
# them for no behavioural gain, so the names stay and this comment says what they are.)
_ft_textfield_can_vscroll() { _ft_textfield_multiline "$1"; }
ft_textfield_idle_up()   { local n=$1; _ft_tf_voff "$n"
                           if _ft_textfield_can_vscroll "$n" && (( FT_RET > 0 )); then _ft_textfield_vscroll_by "$n" -1; fi; return 0; }
ft_textfield_idle_down() { local n=$1
                           if _ft_textfield_can_vscroll "$n"; then _ft_textfield_view_maxv "$n"; local m=$FT_RET
                               _ft_tf_voff "$n"; (( FT_RET < m )) && _ft_textfield_vscroll_by "$n" 1; fi; return 0; }
ft_textfield_idle_pgup() { local n=$1; _ft_tf_voff "$n"
                           if _ft_textfield_can_vscroll "$n" && (( FT_RET > 0 )); then _ft_textfield_pagerows "$n"; _ft_textfield_vscroll_by "$n" $(( -FT_RET )); fi; return 0; }
ft_textfield_idle_pgdn() { local n=$1
                           if _ft_textfield_can_vscroll "$n"; then _ft_textfield_view_maxv "$n"; local m=$FT_RET
                               _ft_tf_voff "$n"
                               (( FT_RET < m )) && { _ft_textfield_pagerows "$n"; _ft_textfield_vscroll_by "$n" "$FT_RET"; }; fi; return 0; }
ft_textfield_idle_home() { local n=$1; _ft_tf_voff "$n"
                           if _ft_textfield_can_vscroll "$n" && (( FT_RET > 0 )); then
                               _ft_tf_voff_set "$n" 0; _ft_tf_hoff_set "$n" 0; ft_dirty "$n"; fi; return 0; }
ft_textfield_idle_end()  { local n=$1
                           if _ft_textfield_can_vscroll "$n"; then _ft_textfield_view_maxv "$n"; local m=$FT_RET
                               _ft_tf_voff "$n"; (( FT_RET < m )) && _ft_textfield_vscroll_by "$n" 999999; fi; return 0; }
# Horizontal: a non-wrapping box pans sideways. Consumed at the ends for the same reason
# as the vertical pair — a wrapping box has no sideways to go, and Left/Right there must
# still not eject you from a control you asked to be inside.
ft_textfield_idle_left()  { _ft_textfield_hscroll_by "$1" -1; }     # the clamp is the whole rule:
ft_textfield_idle_right() { _ft_textfield_hscroll_by "$1" 1; }      # nothing to pan → nothing moves

_ft_destroy_textfield() {       # release per-instance transient state on rebuild
    local n=$1
    # The two offsets are not here any more: they are properties, and ft_remove clears a
    # control's properties itself. A rebuild under the same name reaches this through ft_remove
    # too, so both halves still start clean.
    unset "FT_TEXTFIELD_CARET[$n]" "FT_TEXTFIELD_MODE[$n]" "FT_TEXTFIELD_SBDRAG[$n]" \
          "FT_TEXTFIELD_ANCHOR[$n]" "FT_TEXTFIELD_TABESC[$n]" "FT_TEXTFIELD_MARK[$n]" \
          "FT_SHEEN_LIT_CELL[$n]" "FT_SHEEN_FROZEN[$n]" "FT_SHEEN_FROZEN_SIGNATURE[$n]"
    _ft_textfield_undo_forget "$n"     # a rebuilt field with the same name starts with clean history
    ft_anim_stop "$n"           # a wave in flight must not outlive the control
}

# Focus-IN hook (dispatched generically when a control GAINS focus). An editable
# field with activateToEdit=false is editable the instant you land on it — no
# Enter needed (the classic model). activateToEdit=true (default) stays idle until
# Enter; read-only always stays idle (Enter → cursor mode).
_ft_focusin_textfield() {
    local n=$1
    if _ft_textfield_ro "$n"; then
        # A viewer should open at the TOP, not scrolled to the end. Seed the
        # (hidden) caret to 0 on the FIRST focus only, so Down scrolls downward
        # and a later re-focus keeps wherever you'd scrolled to.
        [[ -z "${FT_TEXTFIELD_CARET[$n]:-}" ]] && { FT_TEXTFIELD_CARET[$n]=0; _ft_tf_voff_set "$n" 0; }
        return 0
    fi
    ft_resolved_prop "$n" activateToEdit true
    [[ "$FT_RET" == false ]] && ft_textfield_activate "$n"
}

# ── Enter / leave edit mode ──────────────────────────────────────────────────
# ft_textfield_activate — enter edit (editable) or cursor (read-only) mode: install the
# full editing keymap as this instance's overlay, show the caret, put it at the
# end so you can append. Disabled fields can't be entered.
# Can this field scroll at all? A field with nothing to scroll has no use for the
# `scrolling` runlevel — stopping there would be an empty rung and a second Enter for
# no reason, so ft_textfield_engage skips it. (Mirrors the gates in the ft_textfield_idle_* handlers.)
# NB this asks whether there is ACTUALLY something to scroll right now, not whether the
# field is the sort of thing that could. `_ft_textfield_can_vscroll` is only "is it multiline", so
# using it alone put a 3-row box holding one short line through a scrolling rung with
# nothing to scroll — the empty stop this is supposed to avoid. Overflow is the real test.
# Is there ANYTHING to scroll — on EITHER axis? This decides whether ENTER stops at the
# `scrolling` rung, so it has to answer the same question the DRAW answers when it decides to
# put a scrollbar on the box. It used to ask only about VERTICAL overflow, behind a
# `multiline` gate — so a read-only non-wrapping panel that pans sideways (the code panel;
# see ft_textfield_idle_left/right below) showed a horizontal scrollbar and STILL skipped
# straight past `scrolling`, which is the "it has a scroll bar but Enter jumps to perusing"
# case. A one-line field with nothing overflowing still answers no, so it goes straight to
# editing exactly as before.
_ft_textfield_can_scroll() {           # name → 0 if the content exceeds the view on either axis
    local n=$1
    if _ft_textfield_can_vscroll "$n"; then
        _ft_textfield_view_maxv "$n"
        (( FT_RET > 0 )) && return 0
    fi
    _ft_textfield_can_hscroll "$n"
}
# _ft_textfield_hscroll_max NAME → FT_RET: how far the view can pan sideways, in display COLUMNS
# (a CJK value is twice as wide as its length) — 0 when nothing is wider than the text well.
# ONE ANSWER for the three places that ask: ENTER deciding whether to stop at `scrolling`, the
# arrows panning there, and — through the same measures — the draws deciding to put a bar on
# the box. Each used to answer for itself, and they disagreed twice:
#
#  · A TEXT BOX IS AS WIDE AS ITS WIDEST LINE, NOT AS LONG AS ITS VALUE. The value was measured
#    whole, newlines and all, so a non-wrapping box of three short lines counted as overflow and
#    ENTER stopped at `scrolling` on a box with no bar.
#  · A ONE-LINE FIELD HAS NOTHING TO WRAP. Its draw puts a bar on the bottom border whenever the
#    value is wider than the well, whatever `wrap` says; ENTER asked `wrap` first and skipped
#    `scrolling` on a field showing a bar — and the arrows there refused to pan it at all.
_ft_textfield_hscroll_max() {          # name → FT_RET
    local n=$1
    _ft_textfield_textw "$n"; local well=$FT_RET
    if _ft_textfield_multiline "$n"; then
        if _ft_textfield_wrapping "$n"; then FT_RET=0; return 0; fi    # a wrapping box reflows
        _ft_textfield_layout "$n" "$well"; _ft_textfield_widest_line
    else
        ft_resolved_prop "$n" value ""; ft_display_width "$FT_RET"; FT_RET=$FT_DISPLAY_WIDTH
    fi
    FT_RET=$(( FT_RET - well )); (( FT_RET < 0 )) && FT_RET=0
    return 0
}
_ft_textfield_can_hscroll() {          # name → 0 if something is wider than the well
    _ft_textfield_hscroll_max "$1"; (( FT_RET > 0 ))
}
# _ft_textfield_widest_line → FT_RET: the widest line of the CURRENT layout
# (FT_TEXTFIELD_LINES_TEXT, filled by _ft_textfield_layout), in display columns. One answer for
# the draw that sizes the horizontal bar and the predicate that decides ENTER's rung. The ASCII
# test is inlined rather than calling ft_display_width per line: that call is ~25µs, and a
# thousand-line document cannot afford it on every frame.
_ft_textfield_widest_line() {          # → FT_RET
    local i line width widest=0
    for (( i=0; i<${#FT_TEXTFIELD_LINES_TEXT[@]}; i++ )); do
        line=${FT_TEXTFIELD_LINES_TEXT[i]}
        if [[ "$line" == *[![:ascii:]]* || "$line" == *$'\t'* || "$line" == *$'\e'* ]]; then
            ft_display_width "$line"; width=$FT_DISPLAY_WIDTH
        else width=${#line}; fi
        (( width > widest )) && widest=$width
    done
    FT_RET=$widest
}
# ENTER while poised: climb ONE rung. Into `scrolling` when there is something to
# scroll, otherwise straight into editing — an ordinary one-line field still takes a
# single Enter, which is what makes the extra rung affordable on the fields that need it.
ft_textfield_engage() {                # ENTER (focused)
    local n=$1
    ft_resolved_prop "$n" disabled false; [[ "$FT_RET" == true ]] && return 0
    if _ft_textfield_can_scroll "$n"; then _ft_setprop "$n" runlevel scrolling
    else                            ft_textfield_activate "$n"; fi
}
# ESC from any rung goes ALL the way out, not one rung down. Leaving is a single,
# always-available gesture; a partial exit would make "how many Escs?" the same question
# the ladder is trying to remove on the way in.
#
# WHERE "out" LANDS IS THE FOCUS MACHINERY'S ANSWER, not a literal. This wrote `unfocused`
# while the field was still the focused control, so leaving a text box put it two rungs down
# while leaving every other control put it one — `ft_runlevel_out` asks _ft_runlevel_resting,
# which says `poised` when you are still standing on the control and `unfocused` when you are
# not. Same question, one route answering it differently.
ft_textfield_leave() { _ft_runlevel_resting "$1"; _ft_setprop "$1" runlevel "$FT_RET"; }

ft_textfield_activate() {              # ENTER (scrolling) / mouse press / auto (activateToEdit=false)
    local n=$1
    ft_resolved_prop "$n" disabled false; [[ "$FT_RET" == true ]] && return 0
    _ft_textfield_engaged "$n" && return 0
    # Setting the runlevel IS the transition: it invalidates the cascade (the state declares
    # it reads `runlevel`), selects that level's keymap as layer 3, and runs its enter script.
    # WHICH level is the capability axis, not a mode flag — a field you cannot type into goes
    # to `perusing`, where the mutating keys are simply not bound.
    if _ft_textfield_ro "$n"; then _ft_setprop "$n" runlevel perusing
    else                    _ft_setprop "$n" runlevel editing; fi
}

# ── Runlevel scripts ─────────────────────────────────────────────────────────
# Entry/exit work lives in one function per runlevel per direction, dispatched by name from
# _ft_setprop. Anything that sets the runlevel — a keymap action, a parent, a sibling button,
# `ft-modify f runlevel=editing` — gets this for free, so there is exactly one way in.
# Arriving in `scrolling` — say so. Same reasoning as the keycaps: the rung is new, and the
# user needs to be told both that they are in it and how to go further or come back.
textfield_runlevel_scrolling_enter() {
    ft_set_mode_hint "Scrolling — ENTER to edit, ESC to leave."
    ft_dirty "$1"
}
textfield_runlevel_scrolling_exit() { ft_set_mode_hint ""; ft_dirty "$1"; }

# `editing` and `perusing` are the two CARET modes — same arrival and departure work, they
# differ only in which keys are bound. One implementation, two thin scripts, so the pair can
# never drift apart the way a copied body would.
textfield_runlevel_perusing_enter() { textfield_runlevel_editing_enter "$1"; }
textfield_runlevel_perusing_exit()  { textfield_runlevel_editing_exit  "$1"; }

textfield_runlevel_editing_enter() {
    local n=$1
    # The caret REMEMBERS where you left it; only a field that has never had one gets
    # the configured start position (default: the very start of the document).
    [[ -z "${FT_TEXTFIELD_CARET[$n]:-}" ]] && { _ft_textfield_start_caret "$n"; FT_TEXTFIELD_CARET[$n]=$FT_RET; }
    # Play the field's active-state animation for as long as you are in it (a LOOP,
    # not a one-shot). Which animation, and every knob it has, is the `animation`
    # property and its friends — default is none (opt in with activateBorderAnimation
    # or textfield::border{animation:sheen}); a no-op begin when off.
    _ft_border_anim_begin "$n"
    # Tell the status bar how to GET OUT. This is the safety net for the user who
    # Tab/Enters expecting to escape and instead inserts tabs/newlines.
    # A field may spell out its own exit hint (editHint=) — e.g. when leaving edit mode
    # also commits/applies something, so the way out isn't merely "exit". Read instance-
    # only (not ft_resolved_prop) so a parent's hint can't leak in (property-inheritance gotcha).
    _ft_get_raw "$n" editHint; local eh=$FT_RET
    # The hint NAMES THE RUNLEVEL, in the same voice as the scrolling one above. These two said
    # "cursor mode" and "edit mode" — the vocabulary from before the runlevels were named, so
    # the bar announced a state that appears nowhere else in the framework, the docs or the CSS.
    if   [[ -n "$eh" ]];  then ft_set_mode_hint "$eh"
    elif _ft_textfield_ro "$n"; then ft_set_mode_hint "Perusing — move and select; ESC to leave."
    else                    ft_set_mode_hint "Editing — ESC to leave."; fi
    ft_dirty "$n"
}
# _ft_textfield_start_caret NAME → FT_RET = the caret index to open at, from
# cursorStartAtCharacter (an index into the value; supersedes the line form) or
# cursorStartAtLine (a 0-based logical line). NEGATIVE counts back from the end,
# -1-based like array APIs: -1 = the very end, -2 = one before it.
_ft_textfield_start_caret() {          # name → FT_RET
    local n=$1 v ch ln
    ft_resolved_prop "$n" value ""; v=$FT_RET
    ft_resolved_prop "$n" cursorStartAtCharacter ""; ch=$FT_RET
    if [[ -n "$ch" ]]; then
        if (( ch < 0 )); then FT_RET=$(( ${#v} + ch + 1 )); else FT_RET=$ch; fi
        (( FT_RET < 0 )) && FT_RET=0; (( FT_RET > ${#v} )) && FT_RET=${#v}
        return 0
    fi
    ft_resolved_prop "$n" cursorStartAtLine ""; ln=$FT_RET
    if [[ -n "$ln" ]]; then
        local -a lines=(); local l
        while IFS= read -r l; do lines+=("$l"); done <<< "$v"
        local nl=${#lines[@]}
        (( ln < 0 )) && ln=$(( nl + ln ))          # -1 = last line
        (( ln < 0 )) && ln=0; (( ln >= nl )) && ln=$(( nl - 1 )); (( ln < 0 )) && ln=0
        local i off=0
        for (( i=0; i<ln; i++ )); do off=$(( off + ${#lines[$i]} + 1 )); done
        (( off > ${#v} )) && off=${#v}
        FT_RET=$off; return 0
    fi
    FT_RET=0                                        # prototype default: start of document
}
# ft_textfield_deactivate — leave edit/cursor mode: drop the editing overlay, clear any
# selection/mark, hide the caret. Idempotent (safe to call on a non-editing field).
ft_textfield_deactivate() {           # ESC / Tab away / blur
    local n=$1
    _ft_textfield_engaged "$n" || return 0
    # …to `poised` while this field still has focus, `unfocused` once it does not — see
    # ft_textfield_leave. _ft_blur_textfield sets `unfocused` explicitly AFTER calling this,
    # so the blur route still lands where it always did.
    _ft_runlevel_resting "$n"
    _ft_setprop "$n" runlevel "$FT_RET"     # runs textfield_runlevel_editing_exit below
}
# Leaving editing. Fires while `editing` is still the current runlevel, so this sees the
# world it is tearing down. NB the caret, mark and undo history deliberately SURVIVE — they
# are per-control document state, not per-runlevel, so re-entering resumes where you were.
textfield_runlevel_editing_exit() {
    local n=$1
    unset "FT_TEXTFIELD_MARK[$n]"
    _ft_textfield_sel_clear "$n" 2>/dev/null
    ft_anim_stop "$n"           # leaving CUTS the wave dead: it announces ARRIVAL, and
                                # one still circling a field you have left points at the
                                # wrong place — worse than no animation at all.
    ft_set_mode_hint ""         # back to navigation mode — the exit hint goes away
    # Commit-on-leave: fire on_deactivate now that edit mode is fully torn down, so a
    # handler sees the final value. Runs on ESC, Tab-away, or blur — any way OUT.
    _ft_hook "$n" on_deactivate
    ft_dirty "$n"
}
# Blur hook (dispatched generically by the focus machinery when this field loses
# focus) — always drop edit mode so Tabbing back in starts idle, not editing.
# Losing focus kills the wave even if the field was never in edit mode (deactivate
# bails early on an idle field, so it cannot be the only thing that stops it).
# …and drop to `unfocused` from ANY rung, not just editing — a field left in `scrolling`
# would keep its arrow bindings while unfocused.
_ft_blur_textfield() { ft_anim_stop "$1"; ft_textfield_deactivate "$1"; _ft_setprop "$1" runlevel unfocused; }

# Mouse → caret. A click places the caret (and drops a selection anchor there); a
# drag extends the selection to the pointer — clamped to the field's own text, so
# it can never run off into the padding/next control (the reason for taking over
# the mouse in the first place).
_ft_textfield_caret_at() {             # name relx rely → FT_RET (value index)
    local name=$1 rx=$2 ry=$3
    _ft_textfield_rows "$name"; local nrows=$FT_RET
    _ft_textfield_textw "$name"; local textw=$FT_RET        # sets FT_TEXTFIELD_LEFT_BORDER/FT_TEXTFIELD_LINE_NUMBER_WIDTH/...
    local xin=$(( FT_TEXTFIELD_LEFT_BORDER + FT_TEXTFIELD_LINE_NUMBER_WIDTH )) col
    ft_resolved_prop "$name" value ""; local v=$FT_RET
    # A click arrives as a COLUMN; a caret is a CHARACTER index. ft_display_index is the
    # conversion (and does the clamping — it stops at the end of the string). Adding the
    # column straight onto a character offset put the caret at roughly half the intended
    # place in any field holding wide glyphs.
    if (( nrows <= 1 )); then
        _ft_tf_hoff "$name"; local scroll=$FT_RET
        col=$(( rx - xin + scroll )); (( col < 0 )) && col=0
        ft_display_index "$v" "$col"; return 0
    fi
    _ft_tf_voff "$name"; local vscroll=$FT_RET
    _ft_tf_hoff "$name"; local hscroll=$FT_RET
    _ft_textfield_layout "$name" "$textw"; local total=${#FT_TEXTFIELD_LINES_TEXT[@]}
    local vr=$(( ry - 1 + vscroll ))                 # -1 for the top border row
    (( vr < 0 )) && vr=0; (( vr >= total )) && vr=$(( total - 1 )); (( vr < 0 )) && vr=0
    local off=${FT_TEXTFIELD_LINES_OFFSET[$vr]}
    col=$(( rx - xin + hscroll )); (( col < 0 )) && col=0
    ft_display_index "${FT_TEXTFIELD_LINES_TEXT[$vr]}" "$col"
    FT_RET=$(( off + FT_RET ))
}
# Single click SELECTS the field (focus only — the framework already focused it on
# the hit); DOUBLE click enters edit/cursor mode, like a desktop list. A double click
# is a second press on the SAME field within _FT_TEXTFIELD_DOUBLE_CLICK_MS milliseconds.
_FT_TEXTFIELD_DOUBLE_CLICK_MS=400
declare -A _FT_TEXTFIELD_LASTCLICK=()
_ft_textfield_now_ms() {               # → FT_RET (monotonic-ish ms; fork-free on bash 5+)
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        local e=${EPOCHREALTIME/,/.}          # some locales use a comma
        FT_RET=$(( ${e%.*} * 1000 + 10#${e#*.} / 1000 ))
    else
        FT_RET=$(( SECONDS * 1000 ))          # bash 4: 1s granularity (double-click still works)
    fi
}
# Apply a captured scrollbar drag: keep the grabbed point of the thumb under the cursor.
# FT_TEXTFIELD_SBDRAG = "axis grab track0 trackN thumbLen maxScroll".
_ft_textfield_sbdrag() {               # name absx absy
    local n=$1 ax=$2 ay=$3
    local -a d=(${FT_TEXTFIELD_SBDRAG[$n]})
    local axis=${d[0]} grab=${d[1]} t0=${d[2]} tn=${d[3]} tlen=${d[4]} maxs=${d[5]}
    local span=$(( tn - tlen )); (( span < 1 )) && span=1     # thumb travel range, in cells
    local pos thumbTop s
    [[ "$axis" == v ]] && pos=$ay || pos=$ax
    thumbTop=$(( pos - grab ))                                # the grabbed cell stays under the cursor
    s=$(( (thumbTop - t0) * maxs / span ))
    (( s < 0 )) && s=0; (( s > maxs )) && s=$maxs
    if [[ "$axis" == v ]]; then _ft_tf_voff_set "$n" "$s"; else _ft_tf_hoff_set "$n" "$s"; fi
    ft_dirty "$n"
}
# Wheel probe: the draw publishes FT_TEXTFIELD_VBAR only when the content overflows vertically —
# no bar means nothing to scroll here, so a wheel tick chains to the enclosing pane.
_ft_textfield_wheel_probe() { [[ -n "${FT_TEXTFIELD_VBAR[$1]:-}" ]]; }
_ft_mouse_textfield() {         # name action relx rely
    local n=$1 act=$2
    local ax=$(( ${FT_ABSOLUTE_X[$n]:-0} + $3 )) ay=$(( ${FT_ABSOLUTE_Y[$n]:-0} + $4 ))
    # SCROLLBAR GRAB — a proper DRAG CAPTURE. On press over a bar we remember which bar and
    # WHERE in the thumb you grabbed (the offset); every drag after that keeps that exact
    # point of the thumb under the cursor, and keeps scrolling even if the cursor drifts off
    # the bar column — so it never "drops". Release ends the capture. The draw publishes each
    # bar's geometry in FT_TEXTFIELD_VBAR/HBAR = "pos thumb0 thumb1 track0 trackN maxScroll" (cells).
    [[ "$act" == release ]] && unset "FT_TEXTFIELD_SBDRAG[$n]"
    if [[ "$act" == drag && -n "${FT_TEXTFIELD_SBDRAG[$n]:-}" ]]; then
        _ft_textfield_sbdrag "$n" "$ax" "$ay"; return 0    # captured: keep scroll-dragging, even off the bar
    fi
    if [[ "$act" == press ]]; then
        unset "FT_TEXTFIELD_SBDRAG[$n]"                     # a fresh press starts a fresh capture
        local -a vb=(${FT_TEXTFIELD_VBAR[$n]:-}) hb=(${FT_TEXTFIELD_HBAR[$n]:-}); local tl grab
        local onbar=""
        if   (( ${#vb[@]} == 6 )) && (( ax == vb[0] && ay >= vb[3] && ay < vb[3] + vb[4] )); then onbar=v
        elif (( ${#hb[@]} == 6 )) && (( ay == hb[0] && ax >= hb[3] && ax < hb[3] + hb[4] )); then onbar=h
        fi
        # Either bar, grabbed directly, steps the field in (_ft_runlevel_grab says why).
        [[ -n "$onbar" ]] && _ft_runlevel_grab "$n"
        if [[ "$onbar" == v ]]; then
            tl=$(( vb[2] - vb[1] + 1 )); grab=$(( ay - vb[1] )); (( grab < 0 )) && grab=0; (( grab >= tl )) && grab=$(( tl - 1 ))
            FT_TEXTFIELD_SBDRAG[$n]="v $grab ${vb[3]} ${vb[4]} $tl ${vb[5]}"
            _ft_textfield_sbdrag "$n" "$ax" "$ay"; return 0
        fi
        if [[ "$onbar" == h ]]; then
            tl=$(( hb[2] - hb[1] + 1 )); grab=$(( ax - hb[1] )); (( grab < 0 )) && grab=0; (( grab >= tl )) && grab=$(( tl - 1 ))
            FT_TEXTFIELD_SBDRAG[$n]="h $grab ${hb[3]} ${hb[4]} $tl ${hb[5]}"
            _ft_textfield_sbdrag "$n" "$ax" "$ay"; return 0
        fi
        # Not on either bar, so this is an ordinary press: caret, double-click, anchor.
        _ft_textfield_caret_at "$n" "$3" "$4"; local car=$FT_RET
        _ft_textfield_now_ms; local now=$FT_RET
        local last=${_FT_TEXTFIELD_LASTCLICK[$n]:-0}
        _FT_TEXTFIELD_LASTCLICK[$n]=$now
        if (( now - last <= _FT_TEXTFIELD_DOUBLE_CLICK_MS )); then
            ft_textfield_activate "$n"                       # DOUBLE click → edit / cursor mode
            FT_TEXTFIELD_CARET[$n]=$car                      # ...at the spot you clicked
        fi
        _FT_YANK_ACTIVE=0
        # Only place the caret/anchor once we're actually in the field; a single click
        # on an idle field just selects it and leaves its remembered caret alone.
        _ft_textfield_engaged "$n" && { FT_TEXTFIELD_ANCHOR[$n]=$car; FT_TEXTFIELD_CARET[$n]=$car; }
    else                                              # drag → extend from the anchor
        _ft_textfield_engaged "$n" && { _ft_textfield_caret_at "$n" "$3" "$4"; FT_TEXTFIELD_CARET[$n]=$FT_RET; }
    fi
    ft_dirty "$n"; return 0
}

# _ft_textfield_rows NAME → FT_RET (row count; >1 means textarea/multi-line)
_ft_textfield_rows() { ft_resolved_prop "$1" rows 1; (( FT_RET < 1 )) && FT_RET=1; }

ft-textfield() { ft_new textfield "$@"; }

# ── The value, as LOGICAL LINES ──────────────────────────────────────────────
# A textarea asks "how many lines is this?" and "what is line N?" constantly — from the
# chrome (the line-number gutter's width), from the wrap layout, from the caret map. Answering
# either by walking the string is O(n²): every `${t#*$'\n'}` copies the rest of the document.
# The LINE STORE (ft-forms.bash) splits once per text generation, in one pass, and every
# caller reads `_fti_<name>__lines` by nameref — no copy at all.
_ft_textfield_lines() {                # name — ensure _fti_<name>__lines describes the value
    local genvar="_fti_${1}__textgen"
    _ft_lines_sync "$1" "${!genvar:-0}" value
}

# ── Chrome: the non-text cells a field reserves ──────────────────────────────
# Every text field is fully BOXED: a thin border on all four sides (FT_TEXTFIELD_LEFT_BORDER/FT_TEXTFIELD_RIGHT_BORDER
# are the left/right border columns; the top/bottom border rows are added by the
# height function). The border is the FOCUS indicator — dim when idle, highlight-
# coloured all the way around when the field is focused — replacing the old
# whole-well recolour, which would have fought future coloured-text editing. A
# textarea can additionally reserve a left LINE-NUMBER gutter (showLineNumbers)
# and a right WRAP-INDICATOR column (wrapIndicator), both inside the border. The
# text well keeps its full `size` width regardless — chrome grows the box, it
# never eats the text. FT_TEXTFIELD_LINE_NUMBER_WIDTH/FT_TEXTFIELD_WRAP_INDICATOR_WIDTH are 0 on single-line fields.
FT_TEXTFIELD_LEFT_BORDER=1; FT_TEXTFIELD_RIGHT_BORDER=1; FT_TEXTFIELD_LINE_NUMBER_WIDTH=0; FT_TEXTFIELD_WRAP_INDICATOR_WIDTH=0
_ft_textfield_chrome() {               # name → FT_TEXTFIELD_LEFT_BORDER FT_TEXTFIELD_RIGHT_BORDER FT_TEXTFIELD_LINE_NUMBER_WIDTH FT_TEXTFIELD_WRAP_INDICATOR_WIDTH
    local name=$1
    _ft_textfield_rows "$name"; local nrows=$FT_RET
    FT_TEXTFIELD_LEFT_BORDER=1; FT_TEXTFIELD_RIGHT_BORDER=1; FT_TEXTFIELD_LINE_NUMBER_WIDTH=0; FT_TEXTFIELD_WRAP_INDICATOR_WIDTH=0
    (( nrows <= 1 )) && return
    _ft_get_raw "$name" showLineNumbers
    if [[ "$FT_RET" == true ]]; then
        # How many logical lines? From the LINE STORE, which split them once for this
        # generation. Counting them by chopping the string (`t=${t#*$'\n'}` in a loop) copies
        # the whole remaining document once per line — O(n²), and this runs from _ft_textfield_textw,
        # which nearly everything calls. It was ~1s per keystroke on a 1000-line box.
        _ft_textfield_lines "$name"
        local -n _cll="_fti_${name}__lines"
        local nl=${#_cll[@]}; (( nl )) || nl=1
        FT_TEXTFIELD_LINE_NUMBER_WIDTH=$(( ${#nl} + 1 ))          # digits of the last line number + a space
    fi
    # The right gutter is TWO cells wide (matching the line-number rail): the ↩ / ¶
    # glyphs can render double-width on some terminals, so a one-cell column would
    # spill into the border. Two cells + width-fit keeps it clean either way. It
    # appears when EITHER indicator is on — both share the one rail (a visual line is
    # either a soft-wrap ↩ or a hard-newline ¶, never both).
    _ft_get_raw "$name" wrapIndicator;    [[ "$FT_RET" == true ]] && FT_TEXTFIELD_WRAP_INDICATOR_WIDTH=2
    _ft_get_raw "$name" newlineIndicator; [[ "$FT_RET" == true ]] && FT_TEXTFIELD_WRAP_INDICATOR_WIDTH=2
}

# Content (text) width = the measured box minus all chrome columns. Used by the
# wrap layout, caret mapping and both draws so they agree to the cell. Before the
# field has been measured (FT_MEASURED_WIDTH unset — e.g. a not-yet-laid-out field), fall back
# to its intrinsic `size`, so the well is exactly `size` wide unless a narrow
# parent has since squeezed the box.
_ft_textfield_textw() {                # name → FT_RET (text columns), also sets TF_*
    local name=$1
    _ft_textfield_chrome "$name"
    local chrome=$(( FT_TEXTFIELD_LEFT_BORDER + FT_TEXTFIELD_LINE_NUMBER_WIDTH + FT_TEXTFIELD_WRAP_INDICATOR_WIDTH + FT_TEXTFIELD_RIGHT_BORDER ))
    local mw=${FT_MEASURED_WIDTH[$name]:-0}
    (( mw <= 0 )) && { ft_resolved_prop "$name" size 20; mw=$(( FT_RET + chrome )); }
    FT_RET=$(( mw - chrome ))
    (( FT_RET < 1 )) && FT_RET=1
}

# Intrinsic width = the visible text columns (`size`) PLUS the chrome the field
# frames it with, so the well itself always gets the full requested `size`.
_ft_preferred_width_textfield() {         # name → FT_RET (total columns incl. chrome)
    local name=$1
    ft_resolved_prop "$name" size 20; local size=$FT_RET
    _ft_textfield_chrome "$name"
    FT_RET=$(( size + FT_TEXTFIELD_LEFT_BORDER + FT_TEXTFIELD_LINE_NUMBER_WIDTH + FT_TEXTFIELD_WRAP_INDICATOR_WIDTH + FT_TEXTFIELD_RIGHT_BORDER ))
}
# Height = the text rows PLUS the top and bottom border rows (the field is fully
# boxed). A single-line field is therefore 3 rows tall; a rows=N textarea N+2.
_ft_height_textfield() { _ft_textfield_rows "$1"; FT_RET=$(( FT_RET + 2 )); }

# ── What a field is WORTH, region by region (see ft_tier_rects in ft-forms.bash) ──
# A one-line field is a decorative ring around a well that is usually mostly empty,
# and the user ranked those two very differently from its text: "I'd rather block
# empty text (beyond the current end of the string) than non-empty text". Nothing
# outside this file can work that out — the box is intrinsic, so the `border`
# property is 0 — which is why the tiers are declared here.
#
# Only the SINGLE-LINE case splits the well. A textarea has a different tail on
# every row, and a horizontally scrolled field is not showing its string from
# column 0, so its width says nothing about where the text ends; both keep a whole
# well at content weight, which is the honest answer rather than a guessed one.
_ft_tiers_textfield() {                # name t l b r
    local name=$1
    ft_tier_ring "$2" "$3" "$4" "$5"
    local it=$FT_TIER_IN_T il=$FT_TIER_IN_L ib=$FT_TIER_IN_B ir=$FT_TIER_IN_R
    _ft_tf_hoff "$name"
    if ! _ft_textfield_multiline "$name" && (( FT_RET == 0 )); then
        # ASK WHAT THE DRAW ASKS. The first cut read `text`, which a field does not have — its
        # string is `value` — so every field looked empty, and it then missed that an EMPTY field
        # still paints its dim `placeholder` right across the well. Both together made a fully
        # inked field read as 100% blank, and the frame said so: 65% ink in a region priced as
        # nothing. Whatever the well shows is what is in the way.
        ft_resolved_prop "$name" value ""; local shown=$FT_RET
        (( ${#shown} )) || { ft_resolved_prop "$name" placeholder ""; shown=$FT_RET; }
        local tw=0
        (( ${#shown} )) && { ft_display_width "$shown"; tw=$FT_DISPLAY_WIDTH; }
        if (( tw <= ir - il )); then                       # strictly narrower ⇒ there is a tail
            ft_tier_add "$it" "$il" "$ib" $(( il + tw - 1 )) "$FT_TIER_CONTENT"
            ft_tier_add "$it" $(( il + tw )) "$ib" "$ir"    "$FT_TIER_EMPTY_TEXT"
            return 0
        fi
    fi
    ft_tier_add "$it" "$il" "$ib" "$ir" "$FT_TIER_CONTENT"
}

# ── State helpers ────────────────────────────────────────────────────────────
# Caret defaults to the end of the current value the first time it's touched, so
# a field seeded with value=... starts with the cursor after the text.
# How long the value is, in characters, WITHOUT fetching it — from the line store, which keeps
# the count exact through every edit. `${#value}` means materialising the whole document first,
# and this is asked on every motion, every edit and every frame.
_ft_textfield_len() {                  # name → FT_RET (characters in the value)
    _ft_textfield_lines "$1"; _ft_lines_nchars "$1"
}
_ft_textfield_caret() {                # name → FT_RET (caret index, clamped to value)
    local name=$1
    _ft_textfield_len "$name"; local vlen=$FT_RET
    local car=${FT_TEXTFIELD_CARET[$name]-}
    # A field that has never had a caret opens at its CONFIGURED start (default: the
    # very beginning) — NOT at the end. This runs from the DRAW too, and it writes the
    # value back, so defaulting to the end here silently pinned every fresh field's
    # caret to the end before the user ever entered it (cursorStartAtCharacter=-1 is
    # how you ask for the end).
    [[ -z "$car" ]] && { _ft_textfield_start_caret "$name"; car=$FT_RET; }
    (( car > vlen )) && car=$vlen
    (( car < 0 )) && car=0
    FT_TEXTFIELD_CARET[$name]=$car; FT_RET=$car
}
_ft_textfield_mode() {                 # name → FT_RET (insert|overwrite)
    FT_RET=${FT_TEXTFIELD_MODE[$1]:-insert}
}
# 0 (true) when the field is a read-only VIEWER — edits are inert, but motion,
# selection and copy all still work (so read-only text is never a dead end).
_ft_textfield_ro() { ft_resolved_prop "$1" readOnly false; [[ "$FT_RET" == true ]]; }
# The well's base colour: an EDITABLE field uses the input colour (FT_COLOR_INPUT); a READ-ONLY
# viewer uses the calmer view colour (FT_COLOR_VIEW), so at a glance you can tell which fields you
# can type in and which are just for reading. A stylesheet can still override either.
_ft_textfield_wellbase() { _ft_textfield_ro "$1" && FT_RET=${FT_COLOR_VIEW:-$FT_COLOR_INPUT} || FT_RET=$FT_COLOR_INPUT; }
# 0 (true) when the field is a rich MARKDOWN viewer: value is rendered as
# markdown, there is no caret, and the arrows scroll the rendered document.
_ft_textfield_md() { ft_resolved_prop "$1" markdown false; [[ "$FT_RET" == true ]]; }
# Commit a new value + caret, fire on_change, repaint. No reflow: a textfield's
# box is fixed (size), so editing is paint-only.
# _ft_textfield_edit NAME OFFSET DELCOUNT INSTEXT NEWCARET — the DOM-shaped primitive: say WHAT
# changed and where. Every edit site should describe its edit this way; the history then
# stores that description rather than a copy of the whole document.
_ft_textfield_edit() {                 # name offset delcount instext newcaret
    local name=$1 off=$2 dc=$3 ins=$4 nc=$5 v
    _ft_textfield_apply "$name" "$off" "$dc" "$ins" "$nc" && return 0
    ft_resolved_prop "$name" value ""; v=$FT_RET
    _ft_textfield_commit "$name" "${v:0:off}$ins${v:off+dc}" "$nc" "$off" "${v:off:dc}" "$ins"
}
# ── The edit that never builds the new value ─────────────────────────────────
# _ft_textfield_commit takes the WHOLE new value, so every caller first constructs it: `${v:0:c}$ch
# ${v:c}` on a 150KB document, then hands it through a function argument, a `local`, _ft_setprop
# and the change hook. Those copies were 40ms of a 55ms keystroke on a 4000-line field, and not
# one of them is work — the document did not change, one character did.
#
# So: apply the edit to the LINE STORE, which is authoritative, and leave the `value` property
# DEFERRED (_FT_TEXT_STALE) exactly as a growing log leaves its `text`. The string is joined
# again the moment anything actually asks for it — ft_get, a word motion, an onChange listener
# — and never on the typing path, which now reads only the caret, the length and one line.
#
# Returns 1 WITHOUT touching anything when it cannot do this safely (the store is not
# authoritative for this field, or maxLength would reshape the edit so that the caller's
# description no longer matches what lands). The caller then takes the whole-value path, which
# is what every edit did before and is always correct.
_FT_TEXTFIELD_APPLIED=0                # store-only edits taken; declining is correct but slow, so
                                # tests/test-incwrap.bash asserts this actually moves
_ft_textfield_apply() {                # name off delcount instext newcaret → 1 = declined
    local name=$1 off=$2 dc=$3 ins=$4 nc=$5
    local lgv="_fti_${name}__linesgen" tgv="_fti_${name}__textgen" lpv="_fti_${name}__linesprop"
    [[ "${!lpv-}" == value && "${!lgv-}" == "${!tgv:-0}" ]] || return 1
    _ft_lines_nchars "$name"; local vlen=$FT_RET
    (( off < 0 )) && off=0; (( off > vlen )) && off=$vlen
    (( dc > vlen - off )) && dc=$(( vlen - off ))
    ft_resolved_prop "$name" maxLength 0; local max=$FT_RET
    (( max > 0 && vlen - dc + ${#ins} > max )) && return 1   # clipping reshapes it: decline

    _FT_TEXTFIELD_APPLIED=$(( _FT_TEXTFIELD_APPLIED + 1 ))
    _FT_YANK_ACTIVE=0                       # any edit ends the yank/yank-pop cycle
    unset "FT_TEXTFIELD_MARK[$name]"               # …and deactivates the emacs mark (region consumed)
    _ft_lines_substr "$name" "$off" "$dc"; local del=$FT_RET   # what the edit removes, for undo
    local oc=${FT_TEXTFIELD_CARET[$name]:-0}
    _ft_textfield_undo_record "$name" "$off" "$del" "$ins" "$oc" "$nc"   # history BEFORE it lands

    local fromgen=${!tgv:-0} nextgen=$(( ++_FT_GENERATION_CLOCK ))   # see _FT_GENERATION_CLOCK
    printf -v "$tgv" '%s' "$nextgen"        # the generation every cache is keyed on
    _ft_lines_splice "$name" "$off" "$dc" "$ins"
    printf -v "$lgv" '%s' "$nextgen"
    _ft_lines_hint "$name" "$FT_LINES_FROM" "$FT_LINES_BASE"
    _FT_TEXT_STALE[$name]=value             # the string is now owed, not stored
    # Keep `value` REGISTERED even though its content is deferred, so ft_remove still tears it
    # down and ft_matches / the cascade still see that the field has a value.
    local props=${FT_PROPS[$name]:-}
    case " $props " in *" value "*) : ;; *) FT_PROPS[$name]="${props:+$props }value" ;; esac
    # _ft_setprop would have done this; a selector CAN be written against `value`.
    if declare -F ft_css_prop_affects_style >/dev/null && ft_css_prop_affects_style value value; then
        declare -F _ft_css_inval >/dev/null && _ft_css_inval "$name"
    fi
    _ft_textfield_layout_edited "$name" "$fromgen" "$nextgen" \
        "$FT_LINES_FROM" "$FT_LINES_NDEL" "$FT_LINES_NINS" $(( ${#ins} - dc ))
    FT_TEXTFIELD_CARET[$name]=$nc
    ft_dirty "$name"
    # onChange's contract is (name, new value) — so the string IS built here, but only for a
    # field someone is actually listening to, instead of on every keystroke of every field.
    if ft_has_listener "$name" change; then
        ft_resolved_prop "$name" value ""; _ft_hook "$name" on_change "$FT_RET"
    fi
    return 0
}
# OLD_OFF/OLD_DEL/OLD_INS are optional: when a caller already knows its edit it passes it
# through and nothing has to be inferred. Without them the change is recorded as a whole-value
# replacement — always correct, just not compact — so every unconverted call site keeps
# working exactly as it did.
_ft_textfield_commit() {               # name newvalue newcaret [off del ins]
    local name=$1 nv=$2 nc=$3 max ov oc
    ft_resolved_prop "$name" value ""; ov=$FT_RET          # capture the PRE-edit state for undo
    oc=${FT_TEXTFIELD_CARET[$name]:-0}
    _FT_YANK_ACTIVE=0           # any edit ends the yank/yank-pop cycle
    unset "FT_TEXTFIELD_MARK[$name]"   # …and deactivates the emacs mark (region consumed)
    ft_resolved_prop "$name" maxLength 0; max=$FT_RET
    local clipped=0
    if (( max > 0 && ${#nv} > max )); then nv=${nv:0:max}; (( nc > max )) && nc=$max; clipped=1; fi
    local eoff=${4-} edel=${5-} eins=${6-} exact=1
    if [[ -z "${4+set}" ]] || (( clipped )); then  # unknown edit (or maxLength reshaped it)
        eoff=0; edel=$ov; eins=$nv; exact=0
    fi
    # Can the LINE STORE be edited in place rather than re-split from the new value? Only when
    # it currently describes the OLD value and this caller said exactly what it changed. That
    # is the difference between a keystroke costing one line and costing the whole document:
    # re-splitting 1000 lines was ~37ms of every key, before any wrapping happened.
    local lgv="_fti_${name}__linesgen" tgv="_fti_${name}__textgen" lpv="_fti_${name}__linesprop"
    local fromgen=${!tgv:-0} instore=0
    (( exact )) && [[ "${!lpv-}" == value && "${!lgv-}" == "$fromgen" ]] && instore=1
    _ft_textfield_undo_record "$name" "$eoff" "$edel" "$eins" "$oc" "$nc"   # history BEFORE it lands
    _ft_setprop "$name" value "$nv"
    if (( instore )); then
        _ft_lines_splice "$name" "$eoff" "${#edel}" "$eins"
        printf -v "$lgv" '%s' "${!tgv:-0}"
        # An edit inside a line does not move that line's start, so the next lookup can begin
        # exactly there — which is what keeps typing at O(1) instead of O(lines) per key.
        _ft_lines_hint "$name" "$FT_LINES_FROM" "$FT_LINES_BASE"
        # …and tell the wrap which logical lines to redo. It verifies the generations itself.
        _ft_textfield_layout_edited "$name" "$fromgen" "${!tgv:-0}" \
            "$FT_LINES_FROM" "$FT_LINES_NDEL" "$FT_LINES_NINS" $(( ${#eins} - ${#edel} ))
    fi
    FT_TEXTFIELD_CARET[$name]=$nc
    ft_dirty "$name"
    _ft_hook "$name" on_change "$nv"       # $this=name, $1=new text
    return 0
}

# ── Undo / redo ──────────────────────────────────────────────────────────────
# A per-field edit history. Every value change funnels through _ft_textfield_commit, so
# that ONE place records it. Snapshots (value + caret) live on two index stacks
# per field; keys are "$name<US>$i", and each stack tracks a base + count so the
# oldest entry can be dropped in O(1) at the cap. Ctrl+/ (the emacs undo key)
# steps back a group; Ctrl+R redoes. Undo/redo restore the value WITHOUT going
# through _ft_textfield_commit, so they never record themselves.
#
# COALESCING: peeling one character per undo is maddening, so a run of ordinary
# typing collapses into a single undo group. A commit joins the open group only
# when it is a single-character, contiguous, NON-boundary insertion; a delete, a
# paste, a caret jump, or a typed space/newline breaks the group so undo comes
# off in word-ish chunks. FT_TEXTFIELD_UNDO_OPEN_GROUP_CARET[name] holds the caret at which the open
# group ends (unset = no open group).
# The history stores EDITS, not snapshots of the whole value. An entry is
#     OFF   where it happened
#     DEL   the text that was removed there
#     INS   the text that was put in its place
#     C/NC  the caret before and after
# so undoing is "put DEL back where INS is" and redoing is its mirror. Typing a character
# into a 100KB document used to push a 100KB copy per keystroke — 200 of those per field at
# the cap. Now it pushes one character.
#
# It also makes coalescing exact rather than inferred: a run of typing is a run of pure
# single-character inserts whose offsets touch, which the entry already says outright, where
# the old code had to reconstruct that fact by comparing two whole values.
declare -A FT_TEXTFIELD_UNDO_OFFSET=() FT_TEXTFIELD_UNDO_REMOVED=() FT_TEXTFIELD_UNDO_INSERTED=() FT_TEXTFIELD_UNDO_CARET_BEFORE=() FT_TEXTFIELD_UNDO_CARET_AFTER=()
declare -A FT_TEXTFIELD_UNDO_COUNT=() FT_TEXTFIELD_UNDO_OLDEST_INDEX=() FT_TEXTFIELD_UNDO_OPEN_GROUP_CARET=()
declare -A FT_TEXTFIELD_REDO_OFFSET=() FT_TEXTFIELD_REDO_REMOVED=() FT_TEXTFIELD_REDO_INSERTED=() FT_TEXTFIELD_REDO_CARET_BEFORE=() FT_TEXTFIELD_REDO_CARET_AFTER=()
declare -A FT_TEXTFIELD_REDO_COUNT=() FT_TEXTFIELD_REDO_OLDEST_INDEX=()
FT_TEXTFIELD_UNDO_MAX_ENTRIES=200              # edits kept per field before the oldest is dropped
_FT_KEY_SEPARATOR=$'\x1f'

# NB: these read per-field state keyed by $n, so $n must be resolved on its OWN
# line BEFORE any array subscript uses it — a `local n=$1 base=${arr[$n]}` reads
# the stale $n (bash evaluates the RHS with the pre-assignment value).
_ft_textfield_redo_clear() {           # name — a real edit invalidates the redo stack
    local n=$1; local i cnt=${FT_TEXTFIELD_REDO_COUNT[$n]:-0} base=${FT_TEXTFIELD_REDO_OLDEST_INDEX[$n]:-0} k
    for (( i=0; i<cnt; i++ )); do
        k="$n$_FT_KEY_SEPARATOR$((base+i))"
        unset "FT_TEXTFIELD_REDO_OFFSET[$k]" "FT_TEXTFIELD_REDO_REMOVED[$k]" "FT_TEXTFIELD_REDO_INSERTED[$k]" \
              "FT_TEXTFIELD_REDO_CARET_BEFORE[$k]" "FT_TEXTFIELD_REDO_CARET_AFTER[$k]"
    done
    FT_TEXTFIELD_REDO_COUNT[$n]=0; FT_TEXTFIELD_REDO_OLDEST_INDEX[$n]=0
}
_ft_textfield_undo_pushraw() {         # name off del ins oldcaret newcaret — no coalescing/redo-clear
    local n=$1; local base=${FT_TEXTFIELD_UNDO_OLDEST_INDEX[$n]:-0} cnt=${FT_TEXTFIELD_UNDO_COUNT[$n]:-0} i k
    i=$(( base + cnt )); k="$n$_FT_KEY_SEPARATOR$i"
    FT_TEXTFIELD_UNDO_OFFSET[$k]=$2; FT_TEXTFIELD_UNDO_REMOVED[$k]=$3; FT_TEXTFIELD_UNDO_INSERTED[$k]=$4
    FT_TEXTFIELD_UNDO_CARET_BEFORE[$k]=$5;   FT_TEXTFIELD_UNDO_CARET_AFTER[$k]=$6
    (( cnt++ )); FT_TEXTFIELD_UNDO_COUNT[$n]=$cnt
    if (( cnt > FT_TEXTFIELD_UNDO_MAX_ENTRIES )); then      # drop the oldest, O(1)
        k="$n$_FT_KEY_SEPARATOR$base"
        unset "FT_TEXTFIELD_UNDO_OFFSET[$k]" "FT_TEXTFIELD_UNDO_REMOVED[$k]" "FT_TEXTFIELD_UNDO_INSERTED[$k]" \
              "FT_TEXTFIELD_UNDO_CARET_BEFORE[$k]" "FT_TEXTFIELD_UNDO_CARET_AFTER[$k]"
        FT_TEXTFIELD_UNDO_OLDEST_INDEX[$n]=$(( base + 1 )); FT_TEXTFIELD_UNDO_COUNT[$n]=$(( cnt - 1 ))
    fi
}
_ft_textfield_redo_pushraw() {         # name off del ins oldcaret newcaret
    local n=$1; local base=${FT_TEXTFIELD_REDO_OLDEST_INDEX[$n]:-0} cnt=${FT_TEXTFIELD_REDO_COUNT[$n]:-0} i k
    i=$(( base + cnt )); k="$n$_FT_KEY_SEPARATOR$i"
    FT_TEXTFIELD_REDO_OFFSET[$k]=$2; FT_TEXTFIELD_REDO_REMOVED[$k]=$3; FT_TEXTFIELD_REDO_INSERTED[$k]=$4
    FT_TEXTFIELD_REDO_CARET_BEFORE[$k]=$5;   FT_TEXTFIELD_REDO_CARET_AFTER[$k]=$6
    FT_TEXTFIELD_REDO_COUNT[$n]=$(( cnt + 1 ))
}
# Record one edit. Coalescing is now a statement about the entries themselves: the open group
# continues iff this edit is a single non-boundary character inserted exactly where the last
# insertion ended. A delete, a paste, a caret jump or a typed space/newline all fail that test
# and start a new group, so undo still comes off in word-ish chunks.
_ft_textfield_undo_record() {          # name off del ins oldcaret newcaret
    local n=$1 off=$2 del=$3 ins=$4 oc=$5 nc=$6
    _ft_textfield_redo_clear "$n"                                 # a real edit kills redo
    local groupable=0
    if [[ -z "$del" && ${#ins} -eq 1 && "$ins" != ' ' && "$ins" != $'\n' ]]; then groupable=1; fi
    if (( groupable )) && [[ "${FT_TEXTFIELD_UNDO_OPEN_GROUP_CARET[$n]:-}" == "$off" ]]; then
        local base=${FT_TEXTFIELD_UNDO_OLDEST_INDEX[$n]:-0} cnt=${FT_TEXTFIELD_UNDO_COUNT[$n]:-0}
        if (( cnt > 0 )); then
            local k="$n$_FT_KEY_SEPARATOR$(( base + cnt - 1 ))"
            if [[ -z "${FT_TEXTFIELD_UNDO_REMOVED[$k]}" ]]; then
                FT_TEXTFIELD_UNDO_INSERTED[$k]+=$ins                   # extend the open typing group
                FT_TEXTFIELD_UNDO_CARET_AFTER[$k]=$nc
                FT_TEXTFIELD_UNDO_OPEN_GROUP_CARET[$n]=$nc
                return 0
            fi
        fi
    fi
    _ft_textfield_undo_pushraw "$n" "$off" "$del" "$ins" "$oc" "$nc"
    if (( groupable )); then FT_TEXTFIELD_UNDO_OPEN_GROUP_CARET[$n]=$nc; else unset "FT_TEXTFIELD_UNDO_OPEN_GROUP_CARET[$n]"; fi
    return 0
}
# Restore a snapshot without recording it (undo/redo bypass _ft_textfield_commit).
_ft_textfield_restore() {              # name value caret
    local n=$1 v=$2 c=$3
    unset "FT_TEXTFIELD_MARK[$n]"; _ft_textfield_sel_clear "$n"
    _FT_YANK_ACTIVE=0
    _ft_setprop "$n" value "$v"
    (( c > ${#v} )) && c=${#v}; (( c < 0 )) && c=0
    FT_TEXTFIELD_CARET[$n]=$c
    ft_dirty "$n"; _ft_legend_dirty
    _ft_hook "$n" on_change "$v"
    return 0
}
ft_textfield_undo() {                  # Ctrl+/ — step back one edit group
    local n=$1 cnt base i k off del ins oc nc cv
    _ft_textfield_ro "$n" && return 0
    cnt=${FT_TEXTFIELD_UNDO_COUNT[$n]:-0}; (( cnt == 0 )) && return 0     # nothing to undo
    base=${FT_TEXTFIELD_UNDO_OLDEST_INDEX[$n]:-0}; i=$(( base + cnt - 1 )); k="$n$_FT_KEY_SEPARATOR$i"
    off=${FT_TEXTFIELD_UNDO_OFFSET[$k]}; del=${FT_TEXTFIELD_UNDO_REMOVED[$k]}; ins=${FT_TEXTFIELD_UNDO_INSERTED[$k]}
    oc=${FT_TEXTFIELD_UNDO_CARET_BEFORE[$k]};    nc=${FT_TEXTFIELD_UNDO_CARET_AFTER[$k]}
    unset "FT_TEXTFIELD_UNDO_OFFSET[$k]" "FT_TEXTFIELD_UNDO_REMOVED[$k]" "FT_TEXTFIELD_UNDO_INSERTED[$k]" \
          "FT_TEXTFIELD_UNDO_CARET_BEFORE[$k]" "FT_TEXTFIELD_UNDO_CARET_AFTER[$k]"
    FT_TEXTFIELD_UNDO_COUNT[$n]=$(( cnt - 1 )); unset "FT_TEXTFIELD_UNDO_OPEN_GROUP_CARET[$n]"
    _ft_textfield_redo_pushraw "$n" "$off" "$del" "$ins" "$oc" "$nc"  # the same edit, to redo
    ft_resolved_prop "$n" value ""; cv=$FT_RET
    _ft_textfield_restore "$n" "${cv:0:off}$del${cv:off+${#ins}}" "$oc"   # put DEL back where INS is
    return 0
}
ft_textfield_redo() {                  # Ctrl+R — reapply the last undone group
    local n=$1 cnt base i rv rc cv cc
    _ft_textfield_ro "$n" && return 0
    cnt=${FT_TEXTFIELD_REDO_COUNT[$n]:-0}; (( cnt == 0 )) && return 0     # nothing to redo
    base=${FT_TEXTFIELD_REDO_OLDEST_INDEX[$n]:-0}; i=$(( base + cnt - 1 )); local k="$n$_FT_KEY_SEPARATOR$i"
    local off=${FT_TEXTFIELD_REDO_OFFSET[$k]} del=${FT_TEXTFIELD_REDO_REMOVED[$k]} ins=${FT_TEXTFIELD_REDO_INSERTED[$k]}
    local oc=${FT_TEXTFIELD_REDO_CARET_BEFORE[$k]} nc=${FT_TEXTFIELD_REDO_CARET_AFTER[$k]}
    unset "FT_TEXTFIELD_REDO_OFFSET[$k]" "FT_TEXTFIELD_REDO_REMOVED[$k]" "FT_TEXTFIELD_REDO_INSERTED[$k]" \
          "FT_TEXTFIELD_REDO_CARET_BEFORE[$k]" "FT_TEXTFIELD_REDO_CARET_AFTER[$k]"
    FT_TEXTFIELD_REDO_COUNT[$n]=$(( cnt - 1 )); unset "FT_TEXTFIELD_UNDO_OPEN_GROUP_CARET[$n]"
    _ft_textfield_undo_pushraw "$n" "$off" "$del" "$ins" "$oc" "$nc"   # back onto undo
    ft_resolved_prop "$n" value ""; cv=$FT_RET
    _ft_textfield_restore "$n" "${cv:0:off}$ins${cv:off+${#del}}" "$nc"   # re-apply INS over DEL
    return 0
}
# Release a field's history (called from _ft_destroy_textfield so a rebuilt field
# with the same name starts clean).
_ft_textfield_undo_forget() {          # name
    local n=$1 i base cnt
    base=${FT_TEXTFIELD_UNDO_OLDEST_INDEX[$n]:-0}; cnt=${FT_TEXTFIELD_UNDO_COUNT[$n]:-0}
    local k
    for (( i=0; i<cnt; i++ )); do
        k="$n$_FT_KEY_SEPARATOR$((base+i))"
        unset "FT_TEXTFIELD_UNDO_OFFSET[$k]" "FT_TEXTFIELD_UNDO_REMOVED[$k]" "FT_TEXTFIELD_UNDO_INSERTED[$k]" \
              "FT_TEXTFIELD_UNDO_CARET_BEFORE[$k]" "FT_TEXTFIELD_UNDO_CARET_AFTER[$k]"
    done
    _ft_textfield_redo_clear "$n"
    unset "FT_TEXTFIELD_UNDO_COUNT[$n]" "FT_TEXTFIELD_UNDO_OLDEST_INDEX[$n]" "FT_TEXTFIELD_UNDO_OPEN_GROUP_CARET[$n]" "FT_TEXTFIELD_REDO_COUNT[$n]" "FT_TEXTFIELD_REDO_OLDEST_INDEX[$n]"
}

# ── Editing operations (bound in the keymap; each gets NAME TOKEN) ────────────
ft_textfield_left()  { local n=$1; _ft_textfield_caret "$n"; (( FT_RET > 0 )) && { FT_TEXTFIELD_CARET[$n]=$((FT_RET-1)); ft_dirty "$n"; }; return 0; }
ft_textfield_right() { local n=$1 v; ft_resolved_prop "$n" value ""; v=$FT_RET; _ft_textfield_caret "$n"; (( FT_RET < ${#v} )) && { FT_TEXTFIELD_CARET[$n]=$((FT_RET+1)); ft_dirty "$n"; }; return 0; }
# Home/End go to the start/end of the current LOGICAL line (between \n's) — for
# a single-line field that is simply the whole value.
ft_textfield_home() {
    local n=$1 v c pfx
    _ft_textfield_md "$n" && { _ft_tf_voff_set "$n" 0; ft_dirty "$n"; return 0; }
    ft_resolved_prop "$n" value ""; v=$FT_RET; _ft_textfield_caret "$n"; c=$FT_RET
    pfx=${v:0:c}; pfx=${pfx##*$'\n'}
    FT_TEXTFIELD_CARET[$n]=$(( c - ${#pfx} )); ft_dirty "$n"; return 0
}
ft_textfield_end() {
    local n=$1 v c suf
    _ft_textfield_md "$n" && { _ft_textfield_md_scroll "$n" 999999; return 0; }
    ft_resolved_prop "$n" value ""; v=$FT_RET; _ft_textfield_caret "$n"; c=$FT_RET
    suf=${v:c}; suf=${suf%%$'\n'*}
    FT_TEXTFIELD_CARET[$n]=$(( c + ${#suf} )); ft_dirty "$n"; return 0
}
# Document start/end: the very first/last position in the whole value, across all
# logical lines (Ctrl+Home/End, and the emacs M-< / M-> keys). In a markdown
# viewer these scroll to the top/bottom of the rendered document.
ft_textfield_doc_home() { local n=$1; _ft_textfield_md "$n" && { _ft_tf_voff_set "$n" 0; ft_dirty "$n"; return 0; }; FT_TEXTFIELD_CARET[$n]=0; ft_dirty "$n"; return 0; }
ft_textfield_doc_end()  { local n=$1 v; _ft_textfield_md "$n" && { _ft_textfield_md_scroll "$n" 999999; return 0; }; ft_resolved_prop "$n" value ""; v=$FT_RET; FT_TEXTFIELD_CARET[$n]=${#v}; ft_dirty "$n"; return 0; }

# ── Multi-line layout: wrap the value into visual lines, offset-tracked ───────
# Fills FT_TEXTFIELD_LINES_TEXT[] (visual line text) and FT_TEXTFIELD_LINES_OFFSET[] (each line's START
# index into the value). Hard breaks on '\n'; long logical lines soft-wrap at
# word boundaries WITHOUT dropping any character, so every value index maps to
# exactly one cell and the caret round-trips through Up/Down cleanly.
# FT_TEXTFIELD_LINES_CONT[i] = 1 when visual line i SOFT-wrapped (the text continues onto the
# next visual line within the same logical line); 0 when it ENDS a logical line
# (hard '\n' or the last piece). Drives the wrap-indicator glyph and line numbers
# (a continuation line gets no new number).
# FT_TEXTFIELD_LINES_HARD[i] = 1 when visual line i ends a logical line that was terminated by a
# HARD '\n' (i.e. it is not the final logical line) — drives the ¶ newline indicator.
FT_TEXTFIELD_LINES_TEXT=(); FT_TEXTFIELD_LINES_OFFSET=(); FT_TEXTFIELD_LINES_CONT=(); FT_TEXTFIELD_LINES_HARD=(); FT_TEXTFIELD_LINES_NUMBER=(); _FT_TEXTFIELD_LINES_CACHE_KEY=""
# FT_TEXTFIELD_LINES_ROW_COUNT[li] = how many visual rows LOGICAL line li produced. This is the index that
# makes an edit patchable: it says exactly which slice of the flat arrays each logical line
# owns, so re-wrapping one line means replacing one contiguous run of rows.
FT_TEXTFIELD_LINES_ROW_COUNT=()
# A remembered (logical line → its first row) pair for the CURRENT FT_TEXTFIELD_LINES_ROW_COUNT, so an edit
# does not have to re-sum the whole index to find where its line's rows begin. Reset to (0,0)
# by every rebuild; moved to the edited line by every patch.
_FT_TEXTFIELD_LINES_MEMO_LOGICAL_LINE=0; _FT_TEXTFIELD_LINES_MEMO_FIRST_ROW=0
# Where a wrapped line's rows come back: _ft_textfield_wrapline REPLACES these with the rows of the
# one line it was given. Both the full rebuild and the incremental patch then append them to
# whichever arrays they are filling — which is why the wrapper does not write to the flat
# arrays itself, and why the line that FITS (much the commoner case, and just four appends)
# is handled by the callers inline: a bash function call is ~25µs, so routing every logical
# line through one cost 25ms per 1000 lines on the rebuild path for no work in return.
_FT_TEXTFIELD_WRAP_TEXT=(); _FT_TEXTFIELD_WRAP_OFFSET=(); _FT_TEXTFIELD_WRAP_CONT=(); _FT_TEXTFIELD_WRAP_HARD=()

# Soft-wrap ONE logical line that is KNOWN to be wider than the box, into visual rows.
# `base` is the line's character offset into the value; `hard` is 1 when a '\n' followed it in
# the document. Wrapping never drops a character, so every value index maps to exactly one cell.
_ft_textfield_wrapline() {             # line base hard width
    local L=$1 base=$2 hard=$3 w=$4
    local off line lw tok tw restL piece
    _FT_TEXTFIELD_WRAP_TEXT=(); _FT_TEXTFIELD_WRAP_OFFSET=(); _FT_TEXTFIELD_WRAP_CONT=(); _FT_TEXTFIELD_WRAP_HARD=()
    off=$base line="" lw=0 restL=$L
    # The line-level loop in _ft_textfield_layout takes ft_display_width's own fast path inline
    # rather than paying a function call to be told a plain string's length. The SAME trick
    # belongs here and mattered ~20× more: this runs per TOKEN, not per line, so a 4000-line
    # rebuild was ~80,000 function calls at ~11-25µs each — seconds of a resize spent entering
    # and leaving a function. The condition must match ft_display_width's EXACTLY: ESC and TAB
    # are both ASCII and neither is one column (a sequence is zero, a tab jumps to the stop).
    while [[ -n "$restL" ]]; do
        if [[ "$restL" == ' '* ]]; then tok=${restL%%[! ]*}; else tok=${restL%%[ ]*}; fi
        restL=${restL#"$tok"}
        if [[ "$tok" == *$'\e'* || "$tok" == *[![:ascii:]]* || "$tok" == *$'\t'* ]]; then
            ft_display_width "$tok"; tw=$FT_DISPLAY_WIDTH
        else tw=${#tok}; fi
        while (( tw > w )); do
            if (( lw > 0 )); then _FT_TEXTFIELD_WRAP_TEXT+=("$line"); _FT_TEXTFIELD_WRAP_OFFSET+=("$off"); _FT_TEXTFIELD_WRAP_CONT+=(1); _FT_TEXTFIELD_WRAP_HARD+=(0); off=$(( off + ${#line} )); line=""; lw=0; fi
            ft_display_truncate "$tok" "$w"; piece=$FT_DISPLAY_TRUNCATED
            [[ -z "$piece" ]] && piece=${tok:0:1}          # never make no progress
            _FT_TEXTFIELD_WRAP_TEXT+=("$piece"); _FT_TEXTFIELD_WRAP_OFFSET+=("$off"); _FT_TEXTFIELD_WRAP_CONT+=(1); _FT_TEXTFIELD_WRAP_HARD+=(0); off=$(( off + ${#piece} ))
            tok=${tok#"$piece"}
            if [[ "$tok" == *$'\e'* || "$tok" == *[![:ascii:]]* || "$tok" == *$'\t'* ]]; then
                ft_display_width "$tok"; tw=$FT_DISPLAY_WIDTH
            else tw=${#tok}; fi
        done
        if (( lw + tw <= w )); then line="$line$tok"; lw=$(( lw + tw ))
        else _FT_TEXTFIELD_WRAP_TEXT+=("$line"); _FT_TEXTFIELD_WRAP_OFFSET+=("$off"); _FT_TEXTFIELD_WRAP_CONT+=(1); _FT_TEXTFIELD_WRAP_HARD+=(0); off=$(( off + ${#line} )); line="$tok"; lw=$tw; fi
    done
    _FT_TEXTFIELD_WRAP_TEXT+=("$line"); _FT_TEXTFIELD_WRAP_OFFSET+=("$off"); _FT_TEXTFIELD_WRAP_CONT+=(0); _FT_TEXTFIELD_WRAP_HARD+=("$hard")
    return 0
}

# ── The one edit the layout is allowed to patch instead of redo ──────────────
# _ft_textfield_commit publishes the edit it just made: which generations it moved the field
# between, which logical lines it replaced, and by how many characters the value grew. The
# layout applies it only when its cached arrays are EXACTLY the "before" of that edit — same
# field, same width, same wrap flag, same generation — and the store is EXACTLY the "after".
# Anything else (an ft-modify, an undo, a second field, a width change) fails that test and
# gets the full rebuild, which is what it always got. There is no way to patch stale rows.
_FT_TEXTFIELD_EDIT_FIELD=""; _FT_TEXTFIELD_EDIT_FROM_GENERATION=0; _FT_TEXTFIELD_EDIT_TO_GENERATION=0
_FT_TEXTFIELD_EDIT_FIRST_LINE=0; _FT_TEXTFIELD_EDIT_LINES_DELETED=0; _FT_TEXTFIELD_EDIT_LINES_INSERTED=0; _FT_TEXTFIELD_EDIT_CHAR_DELTA=0
# How many layouts were PATCHED rather than rebuilt. A silent fall-back to the rebuild is
# still correct, which is exactly why it needs a number: tests/test-incwrap.bash asserts the
# fast path was actually taken, or the whole suite would pass with it disabled.
_FT_TEXTFIELD_LINES_PATCHED=0
_ft_textfield_layout_edited() {        # name fromgen togen firstline ndel nins dchar
    _FT_TEXTFIELD_EDIT_FIELD=$1; _FT_TEXTFIELD_EDIT_FROM_GENERATION=$2; _FT_TEXTFIELD_EDIT_TO_GENERATION=$3
    _FT_TEXTFIELD_EDIT_FIRST_LINE=$4;   _FT_TEXTFIELD_EDIT_LINES_DELETED=$5; _FT_TEXTFIELD_EDIT_LINES_INSERTED=$6; _FT_TEXTFIELD_EDIT_CHAR_DELTA=$7
}
# Re-wrap only the logical lines the published edit touched and splice their rows into the
# cached layout. Returns 1 (and changes nothing) whenever that is not provably safe.
_ft_textfield_layout_patch() {         # name w wrap gen → 0 when the cached arrays were patched
    local name=$1 w=$2 wrap=$3 gen=$4
    [[ "$_FT_TEXTFIELD_EDIT_FIELD" == "$name" && "$_FT_TEXTFIELD_EDIT_TO_GENERATION" == "$gen" ]] || return 1
    [[ "$_FT_TEXTFIELD_LINES_CACHE_KEY" == "$name|$w|$wrap|$_FT_TEXTFIELD_EDIT_FROM_GENERATION" ]] || return 1
    (( ${#FT_TEXTFIELD_LINES_ROW_COUNT[@]} )) || return 1

    local -n LL="_fti_${name}__lines"
    local p=$_FT_TEXTFIELD_EDIT_FIRST_LINE ndel=$_FT_TEXTFIELD_EDIT_LINES_DELETED nins=$_FT_TEXTFIELD_EDIT_LINES_INSERTED
    local nNew=${#LL[@]}
    (( p + ndel <= ${#FT_TEXTFIELD_LINES_ROW_COUNT[@]} && p + nins <= nNew )) || return 1

    # Where the replaced lines' rows start, and end, in the flat arrays. NROWS has to be summed
    # to turn a logical line into a row index, and typing at the bottom of a document means
    # summing all of it — so the last answer is kept and consecutive edits resume from it.
    # Typing stays in one line, so this is normally zero additions.
    local i rowFrom=0 rowOldEnd start=0
    if (( _FT_TEXTFIELD_LINES_MEMO_LOGICAL_LINE <= p )); then start=$_FT_TEXTFIELD_LINES_MEMO_LOGICAL_LINE; rowFrom=$_FT_TEXTFIELD_LINES_MEMO_FIRST_ROW; fi
    for (( i=start; i<p; i++ )); do rowFrom=$(( rowFrom + FT_TEXTFIELD_LINES_ROW_COUNT[i] )); done
    _FT_TEXTFIELD_LINES_MEMO_LOGICAL_LINE=$p; _FT_TEXTFIELD_LINES_MEMO_FIRST_ROW=$rowFrom
    rowOldEnd=$rowFrom
    for (( i=p; i<p+ndel; i++ )); do rowOldEnd=$(( rowOldEnd + FT_TEXTFIELD_LINES_ROW_COUNT[i] )); done

    # Re-wrap just those lines. Their first row's offset is the line's own base, which the
    # cached OFF already holds — everything before the edit keeps the offsets it had.
    local b=${FT_TEXTFIELD_LINES_OFFSET[rowFrom]:-0} lastLL=$(( nNew - 1 )) L hard
    local -a newnrows=() nTXT=() nOFF=() nCONT=() nHARD=()
    for (( i=p; i<p+nins; i++ )); do
        L=${LL[i]}; hard=$(( i < lastLL ? 1 : 0 ))
        # Must match ft_display_width's fast-path condition EXACTLY: ESC and TAB are both
        # ASCII, and neither is one column (a sequence is zero, a tab jumps to the next stop).
        if [[ "$L" == *$'\e'* || "$L" == *[![:ascii:]]* || "$L" == *$'\t'* ]]; then ft_display_width "$L"; else FT_DISPLAY_WIDTH=${#L}; fi
        if [[ "$wrap" != true ]] || (( FT_DISPLAY_WIDTH <= w )); then
            nTXT+=("$L"); nOFF+=("$b"); nCONT+=(0); nHARD+=("$hard"); newnrows+=(1)
        else
            _ft_textfield_wrapline "$L" "$b" "$hard" "$w"
            nTXT+=("${_FT_TEXTFIELD_WRAP_TEXT[@]}");   nOFF+=("${_FT_TEXTFIELD_WRAP_OFFSET[@]}")
            nCONT+=("${_FT_TEXTFIELD_WRAP_CONT[@]}"); nHARD+=("${_FT_TEXTFIELD_WRAP_HARD[@]}")
            newnrows+=(${#_FT_TEXTFIELD_WRAP_TEXT[@]})
        fi
        b=$(( b + ${#L} + 1 ))
    done
    # Line numbers for the new rows: the first row of each logical line carries its number,
    # soft-wrap continuations carry 0 (a blank gutter cell).
    local -a newlnum=(); local k r
    for k in "${!newnrows[@]}"; do
        newlnum+=($(( p + 1 + k )))
        for (( r=1; r<newnrows[k]; r++ )); do newlnum+=(0); done
    done

    local nNewRows=${#nTXT[@]} nOldRows=$(( rowOldEnd - rowFrom ))
    if (( nNewRows == nOldRows )); then          # same shape — overwrite the rows in place
        local j=0
        for (( i=rowFrom; i<rowOldEnd; i++ )); do
            FT_TEXTFIELD_LINES_TEXT[i]=${nTXT[j]};   FT_TEXTFIELD_LINES_OFFSET[i]=${nOFF[j]}
            FT_TEXTFIELD_LINES_CONT[i]=${nCONT[j]}; FT_TEXTFIELD_LINES_HARD[i]=${nHARD[j]}
            FT_TEXTFIELD_LINES_NUMBER[i]=${newlnum[j]}
            (( j++ ))
        done
    else
        FT_TEXTFIELD_LINES_TEXT=("${FT_TEXTFIELD_LINES_TEXT[@]:0:rowFrom}"   "${nTXT[@]}"   "${FT_TEXTFIELD_LINES_TEXT[@]:rowOldEnd}")
        FT_TEXTFIELD_LINES_OFFSET=("${FT_TEXTFIELD_LINES_OFFSET[@]:0:rowFrom}"   "${nOFF[@]}"   "${FT_TEXTFIELD_LINES_OFFSET[@]:rowOldEnd}")
        FT_TEXTFIELD_LINES_CONT=("${FT_TEXTFIELD_LINES_CONT[@]:0:rowFrom}" "${nCONT[@]}"  "${FT_TEXTFIELD_LINES_CONT[@]:rowOldEnd}")
        FT_TEXTFIELD_LINES_HARD=("${FT_TEXTFIELD_LINES_HARD[@]:0:rowFrom}" "${nHARD[@]}"  "${FT_TEXTFIELD_LINES_HARD[@]:rowOldEnd}")
        FT_TEXTFIELD_LINES_NUMBER=("${FT_TEXTFIELD_LINES_NUMBER[@]:0:rowFrom}" "${newlnum[@]}" "${FT_TEXTFIELD_LINES_NUMBER[@]:rowOldEnd}")
    fi
    if (( nins == ndel )); then
        for (( k=0; k<nins; k++ )); do FT_TEXTFIELD_LINES_ROW_COUNT[p+k]=${newnrows[k]}; done
    else
        FT_TEXTFIELD_LINES_ROW_COUNT=("${FT_TEXTFIELD_LINES_ROW_COUNT[@]:0:p}" "${newnrows[@]}" "${FT_TEXTFIELD_LINES_ROW_COUNT[@]:p+ndel}")
    fi

    # Everything AFTER the edit keeps its rows verbatim; only two numbers on them moved —
    # every character offset by the edit's length change, every line number by its line
    # change. Typing at the end of a document (the common case) has no rows after it at all.
    local dchar=$_FT_TEXTFIELD_EDIT_CHAR_DELTA dl=$(( nins - ndel ))
    if (( dchar != 0 || dl != 0 )); then
        local total=${#FT_TEXTFIELD_LINES_TEXT[@]} rowNewEnd=$(( rowFrom + nNewRows ))
        for (( i=rowNewEnd; i<total; i++ )); do
            if (( dchar )); then FT_TEXTFIELD_LINES_OFFSET[i]=$(( FT_TEXTFIELD_LINES_OFFSET[i] + dchar )); fi
            if (( dl && FT_TEXTFIELD_LINES_NUMBER[i] > 0 )); then FT_TEXTFIELD_LINES_NUMBER[i]=$(( FT_TEXTFIELD_LINES_NUMBER[i] + dl )); fi
        done
    fi
    # HARD needs no fix-up outside the re-wrapped range: a splice always re-wraps the line the
    # edit landed in, so any line before it is still followed by one (hard=1, as it was), and
    # any line after it is still followed by whatever followed it before.
    _FT_TEXTFIELD_LINES_PATCHED=$(( _FT_TEXTFIELD_LINES_PATCHED + 1 ))
    return 0
}

_ft_textfield_layout() {               # name width
    local name=$1 w=$2
    ft_resolved_prop "$name" wrap true; local wrap=$FT_RET
    (( w < 1 )) && w=1
    # Memoize: the wrap is recomputed ONLY when the name, width, wrap-flag or
    # text actually change. A keystroke re-enters this from the gutter check,
    # the caret map AND the draw with identical args — without this it re-wrapped
    # the whole value 3-4x per key, which is what made the box crawl.
    #
    # The key carries the control's TEXT GENERATION, not the value itself. Embedding the
    # value meant every one of those calls COPIED the whole document to build the key and
    # then SCANNED it to compare — so the memo cost O(document) even when it hit, on a path
    # that runs several times per keystroke. The generation is bumped by _ft_setprop on any
    # property write, so it changes exactly when the value can have changed.
    local genvar="_fti_${name}__textgen"
    local gen=${!genvar:-0}
    local key="$name|$w|$wrap|$gen"
    [[ "$key" == "$_FT_TEXTFIELD_LINES_CACHE_KEY" ]] && return 0
    # The logical lines come from the LINE STORE, by nameref — split ONCE per generation, in
    # one pass. This used to chop the value apart here (`rest=${rest#*$'\n'}` per line), which
    # copies the whole remaining document every time: O(n²), and re-done on every keystroke.
    _ft_textfield_lines "$name"
    # A single described edit since the cached wrap? Then re-wrap its lines, not the document.
    if _ft_textfield_layout_patch "$name" "$w" "$wrap" "$gen"; then _FT_TEXTFIELD_LINES_CACHE_KEY=$key; return 0; fi
    _FT_TEXTFIELD_LINES_CACHE_KEY=$key
    local -n LL="_fti_${name}__lines"
    local lastLL=$(( ${#LL[@]} - 1 ))          # every logical line but this one ended in '\n'
    local base=0 li L hard
    FT_TEXTFIELD_LINES_TEXT=(); FT_TEXTFIELD_LINES_OFFSET=(); FT_TEXTFIELD_LINES_CONT=(); FT_TEXTFIELD_LINES_HARD=(); FT_TEXTFIELD_LINES_ROW_COUNT=()
    _FT_TEXTFIELD_LINES_MEMO_LOGICAL_LINE=0; _FT_TEXTFIELD_LINES_MEMO_FIRST_ROW=0     # the row index is being rebuilt from the top
    for li in "${!LL[@]}"; do
        L=${LL[li]}; hard=$(( li < lastLL ? 1 : 0 ))
        # ft_display_width's own fast path is `no ESC in the string → ${#s}`, and that is what
        # every ordinary line of text takes. Asking it costs a bash function CALL (~25µs), which
        # over 4000 lines is ~100ms of a rebuild spent entering and leaving a function to be
        # told the length. Take its fast path here and call it only for the strings it is for.
        # Must match ft_display_width's fast-path condition EXACTLY: ESC and TAB are both
        # ASCII, and neither is one column (a sequence is zero, a tab jumps to the next stop).
        if [[ "$L" == *$'\e'* || "$L" == *[![:ascii:]]* || "$L" == *$'\t'* ]]; then ft_display_width "$L"; else FT_DISPLAY_WIDTH=${#L}; fi
        # wrap=false: each logical line is ONE visual line (possibly wider than the box) — the
        # draw scrolls it horizontally instead of wrapping.
        if [[ "$wrap" != true ]] || (( FT_DISPLAY_WIDTH <= w )); then
            FT_TEXTFIELD_LINES_TEXT+=("$L"); FT_TEXTFIELD_LINES_OFFSET+=("$base"); FT_TEXTFIELD_LINES_CONT+=(0); FT_TEXTFIELD_LINES_HARD+=("$hard")
            FT_TEXTFIELD_LINES_ROW_COUNT+=(1)
        else
            _ft_textfield_wrapline "$L" "$base" "$hard" "$w"
            FT_TEXTFIELD_LINES_TEXT+=("${_FT_TEXTFIELD_WRAP_TEXT[@]}");   FT_TEXTFIELD_LINES_OFFSET+=("${_FT_TEXTFIELD_WRAP_OFFSET[@]}")
            FT_TEXTFIELD_LINES_CONT+=("${_FT_TEXTFIELD_WRAP_CONT[@]}"); FT_TEXTFIELD_LINES_HARD+=("${_FT_TEXTFIELD_WRAP_HARD[@]}")
            FT_TEXTFIELD_LINES_ROW_COUNT+=(${#_FT_TEXTFIELD_WRAP_TEXT[@]})
        fi
        base=$(( base + ${#L} + 1 ))           # + the '\n' that followed this line
    done
    if (( ${#FT_TEXTFIELD_LINES_TEXT[@]} == 0 )); then      # an empty value is still one (empty) row
        FT_TEXTFIELD_LINES_TEXT=(""); FT_TEXTFIELD_LINES_OFFSET=(0); FT_TEXTFIELD_LINES_CONT=(0); FT_TEXTFIELD_LINES_HARD=(0); FT_TEXTFIELD_LINES_ROW_COUNT=(1)
    fi
    # The LOGICAL line number for each visual line: a line that begins a logical line carries
    # its number; soft-wrap continuations carry 0 (blank in the gutter). NROWS says which is
    # which without re-deriving it from the continuation flags.
    FT_TEXTFIELD_LINES_NUMBER=(); local _k _i
    for _k in "${!FT_TEXTFIELD_LINES_ROW_COUNT[@]}"; do
        FT_TEXTFIELD_LINES_NUMBER+=($(( _k + 1 )))
        for (( _i=1; _i<FT_TEXTFIELD_LINES_ROW_COUNT[_k]; _i++ )); do FT_TEXTFIELD_LINES_NUMBER+=(0); done
    done
}

# caret index → visual (row,col) against the current FT_TEXTFIELD_LINES_OFFSET/TXT layout.
_ft_textfield_rowcol() {               # caret → sets FT_TEXTFIELD_LINES_CARET_ROW / FT_TEXTFIELD_LINES_CARET_COLUMN
    # Every row starts after the one before it, so FT_TEXTFIELD_LINES_OFFSET is ascending and the row holding
    # the caret is a BINARY search. Walking it was 25ms of every frame on a 4000-line document
    # — the caret is near the bottom exactly when the walk is longest.
    local caret=$1 lo=0 hi=$(( ${#FT_TEXTFIELD_LINES_OFFSET[@]} - 1 )) mid r=0
    while (( lo <= hi )); do
        mid=$(( (lo + hi) / 2 ))
        if (( FT_TEXTFIELD_LINES_OFFSET[mid] <= caret )); then r=$mid; lo=$(( mid + 1 )); else hi=$(( mid - 1 )); fi
    done
    FT_TEXTFIELD_LINES_CARET_ROW=$r
    FT_TEXTFIELD_LINES_CARET_COLUMN=$(( caret - FT_TEXTFIELD_LINES_OFFSET[r] ))
    local llen=${#FT_TEXTFIELD_LINES_TEXT[$r]}
    (( FT_TEXTFIELD_LINES_CARET_COLUMN > llen )) && FT_TEXTFIELD_LINES_CARET_COLUMN=$llen
}

# Move the caret one visual line up/down keeping the column, in a textarea.
_ft_textfield_vmove() {                # name dir(-1|1)
    local name=$1 dir=$2 w
    _ft_textfield_rows "$name"; local rows=$FT_RET
    _ft_textfield_textw "$name"; w=$FT_RET
    _ft_textfield_layout "$name" "$w"
    _ft_textfield_caret "$name"; _ft_textfield_rowcol "$FT_RET"
    local tr=$(( FT_TEXTFIELD_LINES_CARET_ROW + dir )) n=${#FT_TEXTFIELD_LINES_TEXT[@]} v
    # At the top/bottom edge the caret CLAMPS to the document start/end and STAYS —
    # arrows never fall out of a text box (you leave with Tab or Esc). Shift-arrows
    # do the same, just keeping the anchor so the clamp also selects to the edge.
    if (( tr < 0 )); then
        FT_TEXTFIELD_CARET[$name]=0; ft_dirty "$name"; return 0
    fi
    if (( tr >= n )); then
        ft_resolved_prop "$name" value ""; v=$FT_RET; FT_TEXTFIELD_CARET[$name]=${#v}; ft_dirty "$name"; return 0
    fi
    local col=$FT_TEXTFIELD_LINES_CARET_COLUMN llen=${#FT_TEXTFIELD_LINES_TEXT[$tr]}
    (( col > llen )) && col=$llen
    FT_TEXTFIELD_CARET[$name]=$(( FT_TEXTFIELD_LINES_OFFSET[tr] + col ))
    ft_dirty "$name"; return 0
}

# Up/Down: a textarea moves between visual lines; a one-line field has no line to
# move to, so Up jumps the caret to the start and Down to the end — the caret NEVER
# leaves the field (Tab/Esc do that). Shift keeps the anchor, so the same motion
# selects to the beginning/end.
ft_textfield_up() {
    local n=$1 v
    _ft_textfield_md "$n" && { _ft_textfield_md_scroll "$n" -1; return 0; }
    _ft_textfield_rows "$n"
    if (( FT_RET > 1 )); then _ft_textfield_vmove "$n" -1
    else FT_TEXTFIELD_CARET[$n]=0; ft_dirty "$n"; fi        # one line: to start, stay put
    return 0
}
ft_textfield_down() {
    local n=$1 v
    _ft_textfield_md "$n" && { _ft_textfield_md_scroll "$n" 1; return 0; }
    _ft_textfield_rows "$n"
    if (( FT_RET > 1 )); then _ft_textfield_vmove "$n" 1
    else ft_resolved_prop "$n" value ""; v=$FT_RET; FT_TEXTFIELD_CARET[$n]=${#v}; ft_dirty "$n"; fi   # one line: to end
    return 0
}
# Page + document scroll for the markdown viewer (bound to PgUp/PgDn; Home/End
# and Ctrl+Home/End also jump the document when markdown=true).
ft_textfield_pgup() { local n=$1; _ft_textfield_md "$n" || return 0; _ft_textfield_rows "$n"; _ft_textfield_md_scroll "$n" $(( -(FT_RET-1) )); }
ft_textfield_pgdn() { local n=$1; _ft_textfield_md "$n" || return 0; _ft_textfield_rows "$n"; _ft_textfield_md_scroll "$n" $(( FT_RET-1 )); }

# Enter (in EDIT mode): newline in a textarea; in a single-line field it fires the
# field's `activate` event ("submit") if anything is LISTENING for it, else just
# LEAVES edit mode — Enter to edit, Enter to commit. (Idle Enter is handled by
# ft_textfield_activate, not here.)
#
# WHAT IT ASKS, AND WHY IT MATTERS WHICH. This used to decide by probing for a FUNCTION NAMED
# <name>_on_activate, while _ft_hook — the very next call — dispatches from the eventListeners
# plist. Two registries on one route, and docs/api-naming.md promises there is exactly one:
# "There is NO name-convention magic: a function named <name>_on_<event> is just a function —
# wire it … or it never runs" (pinned by tests/test-domapi.bash). Both halves of that mismatch
# were real. A field wired the documented way, `onActivate=submit_fn`, fired NOTHING on Enter
# unless the handler happened to be called <name>_on_activate — the demos all name them that
# way, which is why nothing noticed. And a merely DEFINED, unwired <name>_on_activate made
# Enter inert: the probe passed, _ft_hook found no listener to run, and the early return
# skipped the deactivate, stranding the field in edit mode.
#
# Every other control fires _ft_hook unconditionally; the only reason this one asks first is to
# tell "submit" from "commit and leave", which is a question about LISTENERS. So it asks the
# registry — the same registry _ft_hook reads, and the same accessor a callout's ▶ uses to
# decide whether to draw itself.
ft_textfield_enter() {
    local n=$1
    # A READ-ONLY viewer has no newline to type, so Enter is free: it LEAVES cursor
    # mode — Enter in, Enter out, symmetric and what everyone reaches for. (No emacs
    # /vi binding we offer needs a bare Enter inside a read-only viewer.)
    _ft_textfield_ro "$n" && { ft_textfield_deactivate "$n"; return 0; }
    _ft_textfield_rows "$n"
    if (( FT_RET > 1 )); then _ft_textfield_type "$n" $'\n'; return 0; fi
    ft_has_listener "$n" activate && { _ft_hook "$n" on_activate; return 0; }
    ft_textfield_deactivate "$n"; return 0
}

ft_textfield_backspace() {             # delete the selection, else the char left of caret
    local n=$1 c
    _ft_textfield_ro "$n" && return 0
    _ft_textfield_delsel "$n" && return 0
    _ft_textfield_caret "$n"; c=$FT_RET
    (( c == 0 )) && return 0
    # Soft-tab aware: if the run back to the previous tab stop is ALL SPACES, one
    # Backspace removes the whole soft tab (the caret jumps a tab width), so
    # deleting indentation feels like real tabs. Otherwise delete a single char.
    # The caret's COLUMN comes from the line store: this used to slice the value at the caret
    # and strip back to the last newline — two copies of the document to count one column.
    _ft_textfield_lines "$n"; _ft_lines_locate "$n" "$c"
    local col=$FT_LINE_COL nback seg
    nback=$(( col % _FT_TAB_WIDTH )); (( nback == 0 )) && nback=$_FT_TAB_WIDTH
    (( nback > c )) && nback=$c
    _ft_lines_substr "$n" $(( c - nback )) "$nback"; seg=$FT_RET
    if (( nback > 1 )) && [[ -z "${seg// /}" ]]; then      # the whole run is spaces
        _ft_textfield_edit "$n" $(( c - nback )) "$nback" "" $(( c - nback ))
    else
        _ft_textfield_edit "$n" $(( c - 1 )) 1 "" $(( c - 1 ))
    fi
}
ft_textfield_delete() {                # delete the selection, else the char under caret
    local n=$1 c
    _ft_textfield_ro "$n" && return 0
    _ft_textfield_delsel "$n" && return 0
    _ft_textfield_caret "$n"; c=$FT_RET
    _ft_textfield_len "$n"; (( c >= FT_RET )) && return 0
    _ft_textfield_edit "$n" "$c" 1 "" "$c"
}
# Ctrl+K / Ctrl+U kill to the end / start of the LINE, not of the document.
#
# They used to slice the whole value at the caret, which on a one-line field is the same thing
# — and every test was a one-line field. In a textarea it meant ONE keystroke destroyed
# everything below (or above) the caret. It also contradicted this control's own model: Home
# and End are already line-local. As in emacs, a kill with nothing left on that side takes the
# LINE ENDING instead, joining the two lines, so the key is never simply inert.
ft_textfield_kill_to_end() {           # Ctrl+K — to the end of this line, else swallow the newline
    local n=$1 c
    _ft_textfield_ro "$n" && return 0
    _ft_textfield_caret "$n"; c=$FT_RET
    _ft_textfield_lines "$n"; _ft_lines_locate "$n" "$c"
    local -n _kl="_fti_${n}__lines"
    local cnt=$(( FT_LINE_BASE + ${#_kl[FT_LINE_IDX]} - c ))
    (( cnt == 0 )) && cnt=1                     # at the line end → join the next line
    _ft_textfield_len "$n"; (( c + cnt > FT_RET )) && cnt=$(( FT_RET - c ))
    (( cnt <= 0 )) && return 0
    _ft_lines_substr "$n" "$c" "$cnt"; _ft_kill_push "$FT_RET"
    _ft_textfield_edit "$n" "$c" "$cnt" "" "$c"
}
ft_textfield_kill_to_start() {         # Ctrl+U — to the start of this line, else swallow the newline
    local n=$1 c
    _ft_textfield_ro "$n" && return 0
    _ft_textfield_caret "$n"; c=$FT_RET
    _ft_textfield_lines "$n"; _ft_lines_locate "$n" "$c"
    local start=$FT_LINE_BASE
    (( start == c && c > 0 )) && start=$(( c - 1 ))   # at the line start → join the previous
    local cnt=$(( c - start ))
    (( cnt <= 0 )) && return 0
    _ft_lines_substr "$n" "$start" "$cnt"; _ft_kill_push "$FT_RET"
    _ft_textfield_edit "$n" "$start" "$cnt" "" "$start"
}
ft_textfield_kill_word() {             # delete the word (and preceding spaces) left of caret
    local n=$1 v c; _ft_textfield_ro "$n" && return 0; ft_resolved_prop "$n" value ""; v=$FT_RET; _ft_textfield_caret "$n"; c=$FT_RET
    (( c == 0 )) && return 0
    local left=${v:0:c} rest=${v:c}
    while [[ -n "$left" && "${left: -1}" == [[:space:]] ]]; do left=${left:0:${#left}-1}; done
    while [[ -n "$left" && "${left: -1}" != [[:space:]] ]]; do left=${left:0:${#left}-1}; done
    _ft_kill_push "${v:${#left}:c-${#left}}"
    _ft_textfield_commit "$n" "$left$rest" "${#left}" "${#left}" "${v:${#left}:c-${#left}}" ""
}
# Word motions (readline Meta/Alt, and Ctrl+arrow, which the input layer maps to the same
# tokens): a "word" is a run of non-WHITESPACE characters.
#
# Whitespace, not just a space. A newline is not a space, so testing for ' ' alone let the scan
# run straight THROUGH line endings: in a textarea whose lines have no spaces in them, one
# Ctrl+Left skipped every line at once and landed at the very start of the document. `[[:space:]]`
# is the class — space, tab and newline — so a line ending now bounds a word like any other gap,
# and the motion crosses at most one of them per press.
ft_textfield_word_back() {             # Alt+B — to the start of the previous word
    local n=$1 v c; ft_resolved_prop "$n" value ""; v=$FT_RET; _ft_textfield_caret "$n"; c=$FT_RET
    while (( c > 0 )) && [[ "${v:c-1:1}" == [[:space:]] ]]; do (( c-- )); done
    while (( c > 0 )) && [[ "${v:c-1:1}" != [[:space:]] ]]; do (( c-- )); done
    FT_TEXTFIELD_CARET[$n]=$c; ft_dirty "$n"; return 0
}
ft_textfield_word_fwd() {              # Alt+F — past the end of the next word
    local n=$1 v c len; ft_resolved_prop "$n" value ""; v=$FT_RET; len=${#v}; _ft_textfield_caret "$n"; c=$FT_RET
    while (( c < len )) && [[ "${v:c:1}" == [[:space:]] ]]; do (( c++ )); done
    while (( c < len )) && [[ "${v:c:1}" != [[:space:]] ]]; do (( c++ )); done
    FT_TEXTFIELD_CARET[$n]=$c; ft_dirty "$n"; return 0
}
ft_textfield_kill_word_fwd() {         # Alt+D — delete the word forward from the caret
    local n=$1 v c len e; _ft_textfield_ro "$n" && return 0; ft_resolved_prop "$n" value ""; v=$FT_RET; len=${#v}; _ft_textfield_caret "$n"; c=$FT_RET; e=$c
    while (( e < len )) && [[ "${v:e:1}" == [[:space:]] ]]; do (( e++ )); done
    while (( e < len )) && [[ "${v:e:1}" != [[:space:]] ]]; do (( e++ )); done
    _ft_kill_push "${v:c:e-c}"
    _ft_textfield_commit "$n" "${v:0:c}${v:e}" "$c" "$c" "${v:c:e-c}" ""
}
ft_textfield_toggle_mode() {           # Insert key: flip insert ⇄ overwrite
    local n=$1; _ft_textfield_mode "$n"
    [[ "$FT_RET" == insert ]] && FT_TEXTFIELD_MODE[$n]=overwrite || FT_TEXTFIELD_MODE[$n]=insert
    ft_dirty "$n"; return 0
}
# Insert/overwrite a literal character. SPACE arrives as its own token, so it
# routes here too.
ft_textfield_insert_char() { _ft_textfield_type "$1" "$2"; }
ft_textfield_space()       { _ft_textfield_type "$1" ' '; }
_ft_textfield_type() {                 # name text  (text may be MULTIPLE chars — a soft tab)
    local n=$1 ch=$2 v c
    local len=${#ch}            # advance the caret by the inserted LENGTH, not by 1
    _ft_textfield_ro "$n" && return 0  # read-only viewer: no typing
    unset "FT_TEXTFIELD_TABESC[$n]"    # typing cancels a pending Esc→Tab focus release
    _ft_textfield_delsel "$n"          # typing replaces an active selection
    _ft_textfield_caret "$n"; c=$FT_RET
    _ft_textfield_mode "$n"; local mode=$FT_RET
    # OVERWRITE replaces the same number of characters it types, clipped at the end of the
    # document (typing past the end appends). INSERT deletes nothing.
    local dc=0
    if [[ "$mode" == overwrite ]]; then
        _ft_textfield_len "$n"
        dc=$len; (( c + dc > FT_RET )) && dc=$(( FT_RET - c )); (( dc < 0 )) && dc=0
    fi
    # The store-only path first: typing is the one edit that happens thousands of times, so it
    # is the one that must never touch the whole document. It declines (and nothing has
    # happened) when it cannot, and the original whole-value edit runs instead.
    _ft_textfield_apply "$n" "$c" "$dc" "$ch" $(( c + len )) && return 0
    ft_resolved_prop "$n" value ""; v=$FT_RET
    _ft_textfield_commit "$n" "${v:0:c}$ch${v:c+dc}" $(( c + len )) "$c" "${v:c:dc}" "$ch"
}

# ── Selection: Shift+motion extends, plain motion collapses ───────────────────
# A field remembers a selection ANCHOR (FT_TEXTFIELD_ANCHOR[name]); the live selection
# runs between it and the caret. Shift-motions set the anchor once and keep it as
# the caret moves; any plain motion clears it; typing/backspace replace it.
FT_SELECTION_START=0; FT_SELECTION_END=0
_ft_textfield_selrange() {             # name → FT_SELECTION_START/FT_SELECTION_END; returns 1 if no selection
    local n=$1 a c
    a=${FT_TEXTFIELD_ANCHOR[$n]:-}; [[ -z "$a" ]] && return 1
    _ft_textfield_caret "$n"; c=$FT_RET
    (( a == c )) && return 1
    if (( a < c )); then FT_SELECTION_START=$a FT_SELECTION_END=$c; else FT_SELECTION_START=$c FT_SELECTION_END=$a; fi
    return 0
}
_ft_textfield_sel_begin() { local n=$1; [[ -z "${FT_TEXTFIELD_ANCHOR[$n]:-}" ]] && { _ft_textfield_caret "$n"; FT_TEXTFIELD_ANCHOR[$n]=$FT_RET; }; }
_ft_textfield_sel_clear() { unset "FT_TEXTFIELD_ANCHOR[$1]"; }
_ft_textfield_delsel() {               # name → 0 if a non-empty selection existed and was cut out
    local n=$1; _ft_textfield_selrange "$n" || { unset "FT_TEXTFIELD_ANCHOR[$n]"; return 1; }
    unset "FT_TEXTFIELD_ANCHOR[$n]"
    _ft_textfield_edit "$n" "$FT_SELECTION_START" $(( FT_SELECTION_END - FT_SELECTION_START )) "" "$FT_SELECTION_START"
    return 0
}
# ── Emacs mark / region ──────────────────────────────────────────────────────
# Ctrl+Space sets the MARK at the caret and activates a sticky region; from then
# on ANY motion (shifted or not) extends the region — exactly emacs transient-mark
# mode — until Ctrl+G cancels it, an edit consumes it, or Ctrl+Space toggles it
# off. This is the terminal-independent way to select (Ctrl+Space is NUL, which no
# terminal steals), so it works where Shift+Ctrl+arrows are eaten by the terminal.
_ft_textfield_mark_active() { [[ -n "${FT_TEXTFIELD_MARK[$1]:-}" ]]; }
ft_textfield_set_mark() {              # Ctrl+Space — toggle the mark at the caret
    local n=$1
    if _ft_textfield_mark_active "$n"; then unset "FT_TEXTFIELD_MARK[$n]"; _ft_textfield_sel_clear "$n"   # 2nd press cancels
    else _ft_textfield_caret "$n"; FT_TEXTFIELD_ANCHOR[$n]=$FT_RET; FT_TEXTFIELD_MARK[$n]=1; fi
    _FT_YANK_ACTIVE=0; ft_dirty "$n"; _ft_legend_dirty; return 0
}
ft_textfield_keyboard_quit() {         # Ctrl+G — cancel the region / mark
    local n=$1
    unset "FT_TEXTFIELD_MARK[$n]"; _ft_textfield_sel_clear "$n"; _FT_YANK_ACTIVE=0; ft_dirty "$n"; _ft_legend_dirty; return 0
}

# Dynamic key legend for a text field: what you can do depends on LIVE state — idle vs
# editing, whether a selection/region exists (copy/cut), whether anything is on the
# kill-ring (paste). Called by _ft_legend_caps before the static keymap caps, so these
# win the nearest-wins dedup (e.g. "New line" replaces the idle "Edit" on ENTER mid-edit).
_ft_caps_textfield() {          # name
    local n=$1
    if ! _ft_textfield_engaged "$n"; then
        # Name the rung this Enter actually reaches. A scrollable field stops at `scrolling`
        # first, and a read-only one is never going to "Edit" — promising either would be a
        # lie the very next keypress exposes.
        local _what=Edit
        _ft_textfield_ro "$n" && _what=Peruse           # same word the runlevel and the help use
        _ft_textfield_can_scroll "$n" && _what=Scroll
        _ft_caps_add "$FT_IMPORTANCE_CRUCIAL" ENTER "$_what"
        return
    fi
    _ft_caps_add "$FT_IMPORTANCE_CRUCIAL" ESC "Done"                # editing → the way out
    # Show the HUMAN-FRIENDLY keys by default (Ctrl+C/X/V — GUI muscle memory). Only once
    # the user is working emacs-style (an active mark) do we switch to the emacs keys, so
    # they can complete THAT operation in kind (Alt+W / Ctrl+W / Ctrl+Y). A settings/keymode
    # change (window/mac/emacs/vim) will let a user pin either vocabulary.
    local emacs=0; _ft_textfield_mark_active "$n" && emacs=1
    # Only `editing` binds the mutating keys — `perusing` is the same caret over content you
    # cannot change, so Cut/Paste/Undo/Redo/New-line are NOT bound there. Advertising them
    # anyway is the one thing this legend must never do; a read-only viewer was offering
    # "Enter: New line" for a key that does nothing.
    local mutable=0; _ft_textfield_can_mutate "$n" && mutable=1
    if _ft_textfield_selrange "$n" || _ft_textfield_mark_active "$n"; then  # a selection/region is live
        if (( emacs )); then _ft_caps_add "$FT_IMPORTANCE_CRUCIAL" ALT+w  "Copy"
                             (( mutable )) && _ft_caps_add "$FT_IMPORTANCE_CRUCIAL" CTRL+w "Cut"
        else                 _ft_caps_add "$FT_IMPORTANCE_CRUCIAL" CTRL+c "Copy"
                             (( mutable )) && _ft_caps_add "$FT_IMPORTANCE_CRUCIAL" CTRL+x "Cut"; fi
    fi
    if (( mutable && ${#FT_KILL_RING[@]} > 0 )); then         # something to paste back
        (( emacs )) && _ft_caps_add "$FT_IMPORTANCE_IMPORTANT" CTRL+y "Paste" \
                    || _ft_caps_add "$FT_IMPORTANCE_IMPORTANT" CTRL+v "Paste"
    fi
    (( mutable && ${FT_TEXTFIELD_UNDO_COUNT[$n]:-0} > 0 )) && _ft_caps_add "$FT_IMPORTANCE_NORMAL" 'CTRL+/' "Undo"
    (( mutable && ${FT_TEXTFIELD_REDO_COUNT[$n]:-0} > 0 )) && _ft_caps_add "$FT_IMPORTANCE_NORMAL" CTRL+r "Redo"
    if (( mutable )); then
        _ft_get_raw "$n" rows; (( ${FT_RET:-1} > 1 )) && _ft_caps_add "$FT_IMPORTANCE_NORMAL" ENTER "New line"
    fi
    return 0
}

# (A module flag used to be set here saying "this motion is EXTENDING a selection", for up/down
# to read when deciding "clamp+stay" vs "leave the field". Nothing has read it in the history of
# this file, and the decision it was for is no longer anyone's to make: an arrow NEVER leaves
# the field — see ft_textfield_up/down above, where a one-line field's Up goes to the start and
# stays. Removed rather than kept as documentation of a model that lost.)
# Selection-aware nav wrappers the keymaps bind, one pair per motion: `move_*` COLLAPSES the
# selection first, `select_*` EXTENDS it first, then both run the plain motion. When the emacs
# mark is active the `move_*` ones extend too — the region is sticky, so the anchor is kept
# rather than cleared. (These were `n<motion>` and `s<motion>`, which made the Shift+End
# handler `ft_tf_send` and the Shift+Up one `ft_tf_sup` — English words meaning nothing of
# the kind.)
for _m in left right home end up down word_back word_fwd doc_home doc_end; do
    eval "ft_textfield_move_${_m}() { _FT_YANK_ACTIVE=0; _ft_textfield_mark_active \"\$1\" || _ft_textfield_sel_clear \"\$1\"; ft_textfield_${_m} \"\$1\"; _ft_legend_dirty; }"
    eval "ft_textfield_select_${_m}() { _FT_YANK_ACTIVE=0; _ft_textfield_sel_begin \"\$1\"; ft_textfield_${_m} \"\$1\"; _ft_legend_dirty; }"
done; unset _m

# Clipboard, on the readline scheme (one vocabulary with the rest of the keys):
#   Alt+W  copy-region-as-kill   → put the selection on the SYSTEM clipboard
#   Ctrl+W kill-region/word      → cut the selection (or kill the word if none)
# Both write the system clipboard with OSC 52 (ft_clip_copy). PASTE is always the
# terminal's own paste (bracketed paste) — the OS owns the clipboard; we only
# help populate it.
# A small internal kill-ring backs C-y (yank) and M-y (yank-pop). Every kill/copy
# pushes onto it AND mirrors to the SYSTEM clipboard (OSC 52) — so C-y yanks the
# ring while the terminal's own paste brings in the system clipboard, and the two
# agree (the top of the ring IS what we put on the clipboard).
FT_KILL_RING=(); _FT_KILL_CAP=60
# Returns ft_clip_copy's status, so a caller announces what actually happened rather than
# what it hoped: the ring always takes the text (C-y still works), but the SYSTEM clipboard
# can refuse it, and then "Copied" is a lie the user only discovers when they paste.
_ft_kill_push() {               # text — onto the ring, mirror to the clipboard
    local t=$1; [[ -z "$t" ]] && return 0
    _FT_YANK_ACTIVE=0           # a fresh kill/copy restarts the yank cycle
    FT_KILL_RING=("$t" "${FT_KILL_RING[@]}")
    (( ${#FT_KILL_RING[@]} > _FT_KILL_CAP )) && FT_KILL_RING=("${FT_KILL_RING[@]:0:_FT_KILL_CAP}")
    ft_clip_copy "$t"; local rc=$?
    _ft_legend_dirty            # a paste ("^Y") is now offered — refresh the legend
    return $rc
}
# (_ft_announce_copy — the shared "say what really happened" — lives in ft-core.bash beside
# ft_clip_copy, whose status it reports. It was here first, which made a LABEL's copy depend
# on the text field having been loaded.)
# M-y (yank-pop) is valid only right after a yank/yank-pop; any other command
# clears _FT_YANK_ACTIVE (in _ft_textfield_commit + the nav wrappers). _FT_YANK_AT/LEN
# mark the span the last yank inserted, so yank-pop can replace it in place.
_FT_YANK_ACTIVE=0; _FT_YANK_NAME=""; _FT_YANK_AT=0; _FT_YANK_LEN=0; _FT_YANK_IDX=0

ft_textfield_copy() {                  # Alt+W — copy selection onto the ring/clipboard
    local n=$1 v; _ft_textfield_selrange "$n" || return 0
    ft_resolved_prop "$n" value ""; v=$FT_RET
    _ft_kill_push "${v:FT_SELECTION_START:FT_SELECTION_END-FT_SELECTION_START}"
    # Announce what HAPPENED so the user actually sees it — the status bar flashes whatever
    # it declared for text[textCopied]. A bar with no such property is a silent no-op.
    _ft_announce_copy $?; return 0
}
ft_textfield_cut() {                   # copy the selection, then delete it
    local n=$1; ft_textfield_copy "$n"; _ft_textfield_delsel "$n"; return 0
}
ft_textfield_ctrl_w() {                # Ctrl+W — cut the selection if any, else kill the word
    local n=$1
    _ft_textfield_ro "$n" && { _ft_textfield_selrange "$n" && ft_textfield_copy "$n"; return 0; }  # read-only: copy, don't cut
    if _ft_textfield_selrange "$n"; then ft_textfield_cut "$n"; else ft_textfield_kill_word "$n"; fi
    return 0
}
ft_textfield_ctrl_x() {                # Ctrl+X (edit mode) — CUT the selection (GUI muscle memory);
    local n=$1                  # with nothing selected it does nothing (never kills a word).
    _ft_textfield_ro "$n" && return 0
    _ft_textfield_selrange "$n" && ft_textfield_cut "$n"
    return 0
}
# Ctrl+C — copy. What it copies depends on where you are, and it NEVER quits:
#
#   editing, with a selection   → the selection
#   editing, nothing selected   → nothing, and a hint saying to select something. It used to
#                                 bubble to the run loop, which QUIT: a user reaching for
#                                 copy whose selection had never been made — or had been
#                                 silently unmade by a stray arrow key — lost everything they
#                                 were working on, from the chord that means "copy".
#   focused, not editing        → the WHOLE value. Landing on a control and pressing copy
#                                 should give you what is in it; you have not told it about
#                                 any smaller part yet.
ft_textfield_ctrl_c() {                # name
    local n=$1
    if _ft_textfield_selrange "$n"; then ft_textfield_copy "$n"; return 0; fi
    if ! _ft_textfield_engaged "$n"; then ft_textfield_copy_all "$n"; return 0; fi
    ft_emit_status copyNothing
    return 0
}
# The whole field, as it stands — the same text a paste target would want.
ft_textfield_copy_all() {              # name
    local n=$1 v
    ft_resolved_prop "$n" value ""; v=$FT_RET
    # An empty field is not a copy — _ft_kill_push returns 0 for empty text, so announcing
    # its status would print "Copied" over a clipboard that was deliberately left alone.
    (( ${#v} == 0 )) && { ft_emit_status copyNothing; return 0; }
    _ft_kill_push "$v"
    _ft_announce_copy $?
    return 0
}
# REACHABILITY, measured 2026-08-02: this only fires where the terminal delivers Ctrl+C as a
# KEY. `isig` is left on (see ft_enter_tty), so on a legacy terminal the tty raises SIGINT and
# the app exits before the byte arrives — verified in a pty: selecting text and pressing Ctrl+C
# killed the demo. That is deliberate and is NOT the same trade as Ctrl+Z: freeing `susp` still
# leaves Ctrl+C as the way to kill a wedged app, whereas freeing `intr` too would leave a wedge
# with no keyboard escape at all. Where the keyboard protocol is negotiated (kitty CSI-u) the
# key does arrive and this runs. `Alt+W` is the binding that copies on every terminal.
ft_textfield_select_all() {            # Alt+A (Ctrl+A is emacs start-of-line) — select the whole
    local n=$1 v                # field; then Ctrl+C copies it, or Delete/typing clears it.
    ft_resolved_prop "$n" value ""; v=$FT_RET
    (( ${#v} == 0 )) && return 0
    FT_TEXTFIELD_ANCHOR[$n]=0; FT_TEXTFIELD_CARET[$n]=${#v}; ft_dirty "$n"; return 0
}
ft_textfield_yank() {                  # Ctrl+Y — insert the top of the ring (replaces selection)
    local n=$1 txt=${FT_KILL_RING[0]:-} v c
    _ft_textfield_ro "$n" && return 0
    (( ${#FT_KILL_RING[@]} == 0 )) && return 0
    _ft_textfield_delsel "$n"
    ft_resolved_prop "$n" value ""; v=$FT_RET; _ft_textfield_caret "$n"; c=$FT_RET
    _ft_textfield_rows "$n"; (( FT_RET <= 1 )) && txt=${txt//$'\n'/ }
    _ft_textfield_commit "$n" "${v:0:c}$txt${v:c}" $(( c + ${#txt} )) "$c" "" "$txt"
    _FT_YANK_ACTIVE=1; _FT_YANK_NAME=$n; _FT_YANK_AT=$c; _FT_YANK_LEN=${#txt}; _FT_YANK_IDX=0
    return 0
}
ft_textfield_yank_pop() {              # Alt+Y — replace the just-yanked text with the next ring entry
    local n=$1
    _ft_textfield_ro "$n" && return 0
    { (( _FT_YANK_ACTIVE )) && [[ "$_FT_YANK_NAME" == "$n" ]]; } || return 0
    local nr=${#FT_KILL_RING[@]}; (( nr <= 1 )) && return 0
    local idx=$(( (_FT_YANK_IDX + 1) % nr )) v       # NOTE: separate line — a same-
    local txt=${FT_KILL_RING[$idx]}                  # statement $idx reads the OLD value
    ft_resolved_prop "$n" value ""; v=$FT_RET
    _ft_textfield_rows "$n"; (( FT_RET <= 1 )) && txt=${txt//$'\n'/ }
    _ft_textfield_commit "$n" "${v:0:_FT_YANK_AT}$txt${v:_FT_YANK_AT+_FT_YANK_LEN}" $(( _FT_YANK_AT + ${#txt} )) \
        "$_FT_YANK_AT" "${v:_FT_YANK_AT:_FT_YANK_LEN}" "$txt"
    _FT_YANK_ACTIVE=1; _FT_YANK_NAME=$n; _FT_YANK_LEN=${#txt}; _FT_YANK_IDX=$idx
    return 0
}
# PASTE — the terminal's bracketed paste, delivered as one event. Replaces any
# selection; a single-line field flattens newlines to spaces (it is one line).
ft_textfield_paste() {
    local n=$1 txt=${FT_PASTE:-} v c
    _ft_textfield_ro "$n" && return 0
    [[ -z "$txt" ]] && return 0
    txt=${txt//$'\r'/}
    _ft_textfield_rows "$n"; (( FT_RET <= 1 )) && txt=${txt//$'\n'/ }
    _ft_textfield_delsel "$n"
    ft_resolved_prop "$n" value ""; v=$FT_RET; _ft_textfield_caret "$n"; c=$FT_RET
    _ft_textfield_commit "$n" "${v:0:c}$txt${v:c}" $(( c + ${#txt} )) "$c" "" "$txt"
    return 0
}

# ── Tab handling (edit mode) ─────────────────────────────────────────────────
# TAB BELONGS TO FOCUS. Moving between fields with Tab is the one navigation key every
# user already has in their fingers, and a ONE-LINE field has nothing to indent — taking
# Tab there strands the user in a box for no gain. So a single line always lets Tab and
# Shift+Tab move focus, even mid-edit. A multi-line text BOX is the opposite case: it is
# a small editor, indentation is real work, and Esc is the documented way out — so a text
# box you EXPLICITLY entered (activateToEdit=true) indents with Tab.
#
# `acceptsTab` overrides that judgement per field:
#     auto (default) — a text box indents, a single line moves focus  ← the rule above
#     true           — Tab always types a soft tab (a one-line code/path field that
#                      really does want completion-style indentation)
#     false          — Tab always moves focus, even in a text box
_ft_textfield_tab_inserts() {          # name → 0 (true) if Tab should type a literal tab here
    _ft_textfield_ro "$1" && return 1                      # a viewer never types anything
    ft_resolved_prop "$1" acceptsTab auto
    case "$FT_RET" in
        false) return 1 ;;
        true)  ;;                                   # forced on — skip the auto rule
        *)     _ft_textfield_multiline "$1" || return 1 ;; # auto: only a text BOX indents
    esac
    # Still only while EDITING: an always-edit field (activateToEdit=false) is one you
    # merely landed on, and Tab there is how you land on the next one.
    ft_resolved_prop "$1" activateToEdit true; [[ "$FT_RET" != false ]]
}
# A "tab" here is a SOFT tab — spaces to the next 4-column stop. A literal \t byte
# can't be rendered in a fixed-cell field (the terminal would jump to its own tab
# stop and smear the row), so we expand it, exactly like a code editor's soft tabs.
_FT_TAB_WIDTH=4
ft_textfield_tab() {
    local n=$1 pad sp
    if _ft_textfield_tab_inserts "$n"; then
        _ft_textfield_caret "$n"; pad=$(( _FT_TAB_WIDTH - (FT_RET % _FT_TAB_WIDTH) ))
        printf -v sp '%*s' "$pad" ''; _ft_textfield_type "$n" "$sp"; return 0
    fi
    ft_focus_next; return 0
}
# In a tab-accepting field, Shift+Tab UNINDENTS the current line (removes up to one
# soft tab of leading spaces); everywhere else it moves focus to the previous control.
ft_textfield_btab() { local n=$1; if _ft_textfield_tab_inserts "$n"; then _ft_textfield_unindent "$n"; return 0; fi; ft_focus_prev; return 0; }
_ft_textfield_unindent() {             # Shift+Tab — remove a soft tab (before the caret, or leading)
    local n=$1 v c
    _ft_textfield_ro "$n" && return 0
    ft_resolved_prop "$n" value ""; v=$FT_RET; _ft_textfield_caret "$n"; c=$FT_RET
    local head=${v:0:c} linestart
    # linestart = index of the first char on the caret's logical line. NB: ${#head##…}
    # is a BAD SUBSTITUTION (length and strip can't combine in one expansion) — it must
    # be two steps, or this whole handler dies with a runtime error the moment `head`
    # spans a newline (Shift+Tab after Enter used to crash the program right here).
    if [[ "$head" == *$'\n'* ]]; then
        local _curline=${head##*$'\n'}; linestart=$(( c - ${#_curline} ))
    else linestart=0; fi
    # (1) Soft-tab BACKSPACE: eat up to a tab's worth of spaces immediately LEFT of the
    # caret (bounded to this line), so Shift+Tab dedents wherever the caret sits — not only
    # when the run of spaces begins at column 0. This is the case the user hit: spaces that
    # don't start at the very beginning of the line couldn't be removed.
    local back=0
    while (( back < _FT_TAB_WIDTH )) && (( c-back-1 >= linestart )) && [[ "${v:c-back-1:1}" == ' ' ]]; do (( back++ )); done
    if (( back > 0 )); then
        _ft_textfield_commit "$n" "${v:0:c-back}${v:c}" $(( c-back )) $(( c-back )) "${v:c-back:back}" ""
        return 0
    fi
    # (2) Nothing to eat before the caret → dedent the line's LEADING indentation instead
    # (Shift+Tab with the caret sitting after content on an indented line).
    local lead=0
    while (( lead < _FT_TAB_WIDTH )) && [[ "${v:linestart+lead:1}" == ' ' ]]; do (( lead++ )); done
    (( lead == 0 )) && return 0
    local newc=$c; (( c > linestart )) && newc=$(( c - lead )); (( newc < linestart )) && newc=$linestart
    _ft_textfield_commit "$n" "${v:0:linestart}${v:linestart+lead}" "$newc" \
        "$linestart" "${v:linestart:lead}" ""
}
ft_textfield_esc() {                   # ESC (edit mode) — clear a selection/mark if there is
    local n=$1                  # one, else LEAVE edit mode. (Idle Esc isn't bound here,
                                # so it bubbles to cancel the dialog.)
    if _ft_textfield_mark_active "$n"; then unset "FT_TEXTFIELD_MARK[$n]"; _ft_textfield_sel_clear "$n"; ft_dirty "$n"; return 0; fi
    if _ft_textfield_selrange "$n"; then _ft_textfield_sel_clear "$n"; ft_dirty "$n"; return 0; fi
    # An always-edit field (activateToEdit=false) has no idle state to fall back to,
    # so its Esc bubbles (to cancel a dialog); everyone else drops to plain focus.
    if ! _ft_textfield_ro "$n"; then
        ft_resolved_prop "$n" activateToEdit true
        [[ "$FT_RET" == false ]] && { FT_KEY_BUBBLE=1; return 1; }
    fi
    ft_textfield_deactivate "$n"; return 0
}

# ── Cursor: the REAL terminal cursor (block=overwrite, bar=insert) ───────────
# We drive the terminal's own cursor via DECSCUSR (\e[N q) instead of painting a
# caret into the buffer. Same colour for both shapes (the terminal's cursor
# colour), distinguished only by shape — a fat block for overwrite, a thin bar
# for insert. cursorStyle can force block|bar|underline. FT_CARET_FN (below)
# positions it after every paint.
_ft_textfield_cursor_shape() {         # name → FT_RET = DECSCUSR code
    local name=$1 style
    ft_resolved_prop "$name" cursorStyle ""; style=$FT_RET
    # A read-only viewer shows an UNDERLINE (a position marker), not an insert bar.
    [[ -z "$style" ]] && _ft_textfield_ro "$name" && style=underline
    if [[ -z "$style" ]]; then _ft_textfield_mode "$name"; [[ "$FT_RET" == overwrite ]] && style=block || style=bar; fi
    # DECSCUSR: odd codes BLINK, even codes are steady. FT_CURSOR_BLINK (a theme
    # flag, on by default) picks blink so the caret is easy to spot.
    local blink=${FT_CURSOR_BLINK:-1}
    case "$style" in
        block)     (( blink )) && FT_RET=1 || FT_RET=2 ;;   # block     → overwrite
        underline) (( blink )) && FT_RET=3 || FT_RET=4 ;;   # underline
        *)         (( blink )) && FT_RET=5 || FT_RET=6 ;;   # bar       → insert (default)
    esac
}

# _ft_textfield_caret_screen NAME → FT_CARET_R / FT_CARET_C (absolute screen cell of the
# caret) and FT_CARET_SHAPE (DECSCUSR code); FT_CARET_R=-1 if it can't be placed.
# Reuses the scroll offsets the draw just stored, so it costs a cache-hit layout.
FT_CARET_R=-1; FT_CARET_C=-1; FT_CARET_SHAPE=6
_ft_textfield_caret_screen() {         # name
    local name=$1
    local ax=${FT_ABSOLUTE_X[$name]:-0} ay=${FT_ABSOLUTE_Y[$name]:-0}
    local cols=${FT_MEASURED_WIDTH[$name]:-0} rows=${FT_MEASURED_HEIGHT[$name]:-1}
    FT_CARET_R=-1
    _ft_textfield_md "$name" && return                 # markdown viewer: no editing caret
    (( cols < 1 )) && return
    _ft_textfield_cursor_shape "$name"; FT_CARET_SHAPE=$FT_RET
    _ft_textfield_rows "$name"; local nrows=$FT_RET
    _ft_textfield_caret "$name"; local caret=$FT_RET
    _ft_textfield_textw "$name"; local textw=$FT_RET   # also sets FT_TEXTFIELD_LEFT_BORDER/FT_TEXTFIELD_LINE_NUMBER_WIDTH/… chrome
    local xin=$(( FT_TEXTFIELD_LEFT_BORDER + FT_TEXTFIELD_LINE_NUMBER_WIDTH ))             # text well starts after left chrome
    local yin=1                                 # ...and one row below the top border
    if (( nrows <= 1 )); then                                   # single line
        # The terminal cursor is placed in CELLS, so the caret's character index has to be
        # converted to a column first — otherwise it sat left of the block caret the draw
        # painted, by one cell per wide glyph before it.
        ft_resolved_prop "$name" value ""; ft_display_col "$FT_RET" "$caret"
        local ccol=$FT_RET
        _ft_tf_hoff "$name"
        local cpos=$(( ccol - FT_RET ))
        (( cpos < 0 )) && cpos=0; (( cpos > textw - 1 )) && cpos=$(( textw - 1 ))
        FT_CARET_R=$(( ay + yin )); FT_CARET_C=$(( ax + xin + cpos ))
        return
    fi
    # textarea: map caret → visual (row,col) via the (cached) layout
    _ft_textfield_layout "$name" "$textw"
    _ft_textfield_rowcol "$caret"
    _ft_tf_voff "$name"; local vscroll=$FT_RET
    _ft_tf_hoff "$name"; local hscroll=$FT_RET
    local vr=$(( FT_TEXTFIELD_LINES_CARET_ROW - vscroll )) vc
    ft_display_col "${FT_TEXTFIELD_LINES_TEXT[$FT_TEXTFIELD_LINES_CARET_ROW]:-}" "$FT_TEXTFIELD_LINES_CARET_COLUMN"
    vc=$(( FT_RET - hscroll ))                                 # caret column, not caret character
    (( vr < 0 || vr >= nrows )) && return                      # scrolled out of view
    (( vc < 0 )) && vc=0; (( vc > textw - 1 )) && vc=$(( textw - 1 ))
    FT_CARET_R=$(( ay + yin + vr )); FT_CARET_C=$(( ax + xin + vc ))
}

# FT_CARET_FN: after every flush, park the terminal cursor on the focused text
# field (or hide it). Set once, at load.
# Tracks whether we tinted the terminal cursor (OSC 12), so we reset it (OSC
# 112) exactly once when focus leaves a field — never spamming the reset.
_FT_CURSOR_TINTED=0
_ft_place_caret() {
    local n=${FT_FOCUS:-}
    # Only show the terminal caret when the focused field is actually in EDIT mode;
    # a merely-focused (idle) field shows its lit border but no caret.
    if [[ -n "$n" && "${FT_TYPE[$n]:-}" == textfield ]] && _ft_textfield_engaged "$n"; then
        _ft_textfield_caret_screen "$n"
        if (( FT_CARET_R >= 0 )); then
            ft_cursor_position "$FT_CARET_R" "$FT_CARET_C"
            FT_OUT+="$FT_CURSOR_POSITION"
            if [[ -n "${FT_CURSOR_COLOR:-}" ]]; then
                FT_OUT+=$'\e]12;'"$FT_CURSOR_COLOR"$'\e\\'; _FT_CURSOR_TINTED=1
            fi
            FT_OUT+=$'\e['"$FT_CARET_SHAPE"' q'"$FT_ANSI_CURSOR_SHOW"
            return
        fi
    fi
    (( _FT_CURSOR_TINTED )) && { FT_OUT+=$'\e]112\e\\'; _FT_CURSOR_TINTED=0; }  # un-tint
    FT_OUT+="$FT_ANSI_CURSOR_HIDE"      # nothing to edit → keep the cursor hidden
}
FT_CARET_FN=_ft_place_caret

_ft_draw_textfield() {          # name — dispatch on markdown / textarea / single
    _ft_textfield_md "$1" && { _ft_draw_textfield_md "$1"; return; }
    _ft_textfield_rows "$1"
    if (( FT_RET > 1 )); then _ft_draw_textfield_multi "$1"; else _ft_draw_textfield_single "$1"; fi
}

# Compose a visible text row with an optional highlighted span at columns
# [vlo,vhi) (the live selection). Clamped spans outside the row leave it plain.
_ft_textfield_rowspan() {              # sgr selsgr paddedwindow vlo vhi → FT_RET
    local sgr=$1 sel=$2 w=$3 vlo=$4 vhi=$5
    if (( vhi <= vlo )); then FT_RET="$sgr$w"; return; fi
    # The caret/selection SGR can carry bold (.caret / .selected font-weight); $sgr is a
    # colours-only pair that cannot clear it, so close the span with a full reset before
    # returning to the field colours — otherwise bold leaks to the rest of the row.
    FT_RET="$sgr${w:0:vlo}$sel${w:vlo:vhi-vlo}$FT_ANSI_RESET$sgr${w:vhi}"
}

# ── Border animations ────────────────────────────────────────────────────────
# A field plays a looping animation on its border for as long as you are IN it
# (ft_textfield_activate → blur/deactivate). WHICH one is the `animation` property:
#
#   sheen   (default) a very, very subtle diagonal tone gradient that drifts
#           left→right, plus a faint background GLOW of the border's own colour.
#           Calm — for the ordinary "you're editing this" state, where anything
#           flashy would grate by the twentieth minute.
#   beacon  a wave of THICKNESS: crests of heavy box glyphs circling the border
#           (─→━, │→┃). Loud on purpose — for CALLING SOMETHING OUT, not for
#           sitting in. Opt in with animation=beacon.
#   none    no animation.
#
# Animations are a tiny registry keyed by name — three functions each:
#   _ft_anim_<name>_begin NAME                    arm it (compute length, pace)
#   _ft_anim_<name>_frame NAME                    ONE cheap partial repaint (the
#                                                 FT_PROTO_ANIM hook fires this)
#   _ft_anim_<name>_overlay NAME row col rows cols sgr   lay it over a full draw
# Adding another animation is three functions and a name; nothing else changes.
#
# Every tunable is a PROPERTY (beaconRate=…, sheenDepth=…), namespaced by the
# animation so names never collide, and read per-instance with _ft_get_raw so a
# container can never leak one onto an unrelated child (the ft_resolved_prop inheritance
# trap). There are no animation-specific ALL-CAPS globals to tune.
# The number of tone steps the sheen gradient is quantised to is the `numberOfTones`
# PROPERTY (default below), never a global you edit — the glow rides the same ramp, so
# too few steps show as visible BANDING (finer = smoother; truecolor gets every step,
# 256/16 re-quantise down). Read per instance via _ft_get_raw.
_FT_SHEEN_TONE_STEPS_DEFAULT=30

# _ft_textfield_wave_geom ROWS COLS [CRESTS] → FT_TEXTFIELD_WAVE_PERIMETER (perimeter), FT_TEXTFIELD_WAVE_CREST_GAP (crest
# spacing). ONE definition, because the begin that sizes a run and the draw that
# paints it must agree — if they drift, crests land in the wrong places.
_ft_textfield_wave_geom() {            # rows cols [crests]
    local rows=$1 cols=$2 crests=${3:-1}
    (( crests < 1 )) && crests=1
    FT_TEXTFIELD_WAVE_PERIMETER=$(( 2*cols + 2*rows - 4 ))          # cells once around the box
    FT_TEXTFIELD_WAVE_CREST_GAP=$(( FT_TEXTFIELD_WAVE_PERIMETER / crests )); (( FT_TEXTFIELD_WAVE_CREST_GAP < 1 )) && FT_TEXTFIELD_WAVE_CREST_GAP=1
}

# The thumbs. The vertical rides the LEFT block ramp (▏▎▍▌▋▊▉█), so ▊→▉ is a true
# eighth fatter. The HORIZONTAL thumb is the HEAVY RULE, ━ over the border's light ─:
# a thumb that lives IN the bottom border must read as a thickened stretch of that
# border. It used to be ▀ (upper half block), which floats above the border's
# baseline and detaches from the └ ┘ corners — the box read as CUT OFF along the
# bottom, reported twice from screenshots. ━ is also exactly the sheen crest's
# vocabulary on that edge, so the crest passing through the thumb stays seamless.
# Its "thicker" step stays █ but is never painted (the crest passes through the
# horizontal bar rather than riding it — see the wave paint below).
_FT_TEXTFIELD_VERTICAL_THUMB=$'\xe2\x96\x8a'; _FT_TEXTFIELD_VERTICAL_THUMB_THICK=$'\xe2\x96\x89'     # ▊ → ▉
_FT_TEXTFIELD_HORIZONTAL_THUMB=$'\xe2\x94\x81'; _FT_TEXTFIELD_HORIZONTAL_THUMB_THICK=$'\xe2\x96\x88'     # ━ (thick: █, unused)
# The ASCII fallbacks, chosen against the glyph each one REPLACES rather than in isolation.
# A thumb sits IN the border it scrolls, so the vertical one has to differ from the vertical
# rule and the horizontal one from the horizontal rule. '|' failed that: it is exactly
# ft-core's ASCII FT_GLYPH_VERTICAL, so on a non-UTF-8 terminal the scrollbar vanished into the frame —
# present, correctly positioned, and completely invisible.
#
# Not the CP437 block bytes (176-178 ░▒▓, 219 █): those are blocks only if the terminal is
# actually using CP437. Under Latin-1 — the far likelier non-UTF-8 case on Linux — they are
# °±²Û. A 7-bit glyph is the only choice that is right on every terminal, and '#' reads as a
# thumb and can never be mistaken for a rule.
_FT_TEXTFIELD_VERTICAL_THUMB_ASCII='#'; _FT_TEXTFIELD_VERTICAL_THUMB_THICK_ASCII='#'                         # vs FT_GLYPH_VERTICAL '|'
_FT_TEXTFIELD_HORIZONTAL_THUMB_ASCII='='; _FT_TEXTFIELD_HORIZONTAL_THUMB_THICK_ASCII='#'                         # vs FT_GLYPH_HORIZONTAL '-'
# FT_TEXTFIELD_THUMB_VERTICAL/FT_TEXTFIELD_THUMB_VERTICAL_THICK/FT_TEXTFIELD_THUMB_HORIZONTAL/FT_TEXTFIELD_THUMB_HORIZONTAL_THICK — the thumb glyphs for the CURRENT rendering mode. ONE place, because
# three separate call sites (the draw, the thumb cache, the sheen) were each choosing their own
# fallback inline and could disagree — and did.
FT_TEXTFIELD_THUMB_VERTICAL=""; FT_TEXTFIELD_THUMB_VERTICAL_THICK=""; FT_TEXTFIELD_THUMB_HORIZONTAL=""; FT_TEXTFIELD_THUMB_HORIZONTAL_THICK=""
_ft_textfield_thumb_glyphs() {
    if (( FT_USE_UTF8 )); then
        FT_TEXTFIELD_THUMB_VERTICAL=$_FT_TEXTFIELD_VERTICAL_THUMB;   FT_TEXTFIELD_THUMB_VERTICAL_THICK=$_FT_TEXTFIELD_VERTICAL_THUMB_THICK
        FT_TEXTFIELD_THUMB_HORIZONTAL=$_FT_TEXTFIELD_HORIZONTAL_THUMB;   FT_TEXTFIELD_THUMB_HORIZONTAL_THICK=$_FT_TEXTFIELD_HORIZONTAL_THUMB_THICK
    else
        FT_TEXTFIELD_THUMB_VERTICAL=$_FT_TEXTFIELD_VERTICAL_THUMB_ASCII; FT_TEXTFIELD_THUMB_VERTICAL_THICK=$_FT_TEXTFIELD_VERTICAL_THUMB_THICK_ASCII
        FT_TEXTFIELD_THUMB_HORIZONTAL=$_FT_TEXTFIELD_HORIZONTAL_THUMB_ASCII; FT_TEXTFIELD_THUMB_HORIZONTAL_THICK=$_FT_TEXTFIELD_HORIZONTAL_THUMB_THICK_ASCII
    fi
}

# The field's ACTIVE-state accent colour — azure merely focused, gold while editing,
# cyan for a read-only viewer. ONE definition, because the border, the scrollbar
# thumbs, and the beacon all colour themselves by state and must never disagree
# (the thumbs used to be hardwired azure, so an editing field had a gold border and
# blue scrollbars — the mismatch this centralises away).
# ONE COLOUR PER RUNG. This used to ask only "engaged?", which lumped `scrolling` in with
# `unfocused` and gave them the SAME azure — so climbing the first rung changed nothing you
# could see. Each rung now gets its own hue, spread around the wheel rather than crowded into
# the blues: azure (focused) · violet (scrolling) · gold (editing) · cyan (perusing).
_ft_textfield_statefg() {              # name → FT_RET (accent for the current runlevel)
    local _rv="_ftp_${1}_runlevel"
    case "${!_rv-}" in
        editing)   FT_RET=$FT_COLOR_TEXT_NOTICE ;;
        perusing)  FT_RET=$FT_COLOR_VIEW ;;
        scrolling) FT_RET=${FT_COLOR_SCROLLING:-$FT_COLOR_TEXT_ACCENT} ;;
        *)         FT_RET=$FT_COLOR_TEXT_ACCENT ;;
    esac
}
# _ft_textfield_border_sgr NAME → FT_RET — the border's SGR for this field's state. The draw and
# every animation frame call it, so the shimmer can never repaint the ring in a
# different colour than the draw that laid it down.
_ft_textfield_border_sgr() {               # name
    # A CSS border-color (inline or a stylesheet rule — e.g. `textfield:focus
    # { border-color: … }`) wins over the built-in edit-state colour. Resolved via
    # _ft_css_color, which does NOT walk legacy container inheritance, so a field never
    # accidentally inherits an ancestor frame's border. No rule ⇒ the state logic below,
    # byte-for-byte as before.
    # `::border { border-color: … }` — the border is a STRUCTURE (pseudo-element), the CSS-idiomatic
    # way to recolour just the ring — wins first; then the element's own border-color; then state.
    _ft_css_color_pe "$1" border borderColor 38; local pev=$FT_RET
    [[ -n "$pev" ]] && { FT_RET="$FT_COLOR_BORDER$pev"; return; }
    _ft_css_color "$1" borderColor 38; local ov=$FT_RET
    if [[ -n "$ov" ]]; then FT_RET="$FT_COLOR_BORDER$ov"; return; fi
    if [[ "${FT_FOCUS:-}" == "$1" ]]; then _ft_textfield_statefg "$1"; FT_RET="$FT_COLOR_BORDER$FT_RET"
    else FT_RET=$FT_COLOR_BORDER; fi
}
# _ft_textfield_thumbfg NAME → FT_RET — a scrollbar thumb's foreground: the active-state
# accent when focused (so it matches the border), muted grey otherwise.
_ft_textfield_thumbfg() {              # name
    # A `::scrollbar { color: … }` rule colours the thumb; else the built-in behaviour
    # (active-state accent when focused, muted grey otherwise).
    _ft_css_color_pe "$1" scrollbar color 38; [[ -n "$FT_RET" ]] && return
    if [[ "${FT_FOCUS:-}" == "$1" ]]; then _ft_textfield_statefg "$1"; else FT_RET=$FT_COLOR_TEXT_MUTED; fi
}
# The selection band and the block caret are STRUCTURES: `::selection` / `::caret` rules
# colour them; otherwise the theme defaults (the caret's default depends on edit/RO state).
_ft_textfield_selsgr() {               # name → FT_RET
    ft_sgr_pseudo_element "$1" selection; [[ -n "$FT_RET" ]] && return; FT_RET=$FT_COLOR_SELECTED
}
_ft_textfield_caretsgr() {             # name → FT_RET
    ft_sgr_pseudo_element "$1" caret; [[ -n "$FT_RET" ]] && return
    _ft_textfield_ro "$1" && FT_RET=$FT_COLOR_CARET_RO || FT_RET=$FT_COLOR_CARET
}
# The ACTIVE LINE — the row the caret is on, lifted a shade so you can see where you are in a
# tall box. A STRUCTURE like the others: `textfield::active { background-color: … }` themes
# it, and a theme (or an app) that says nothing turns it off, because the fallback is "" and an
# empty SGR means "paint the row exactly as before". `currentLineHighlight=false` switches it
# off per field without touching the stylesheet. Composed over the WELL, so it lifts from
# whatever that field's well actually is — an editable input and a read-only viewer differ.
_ft_textfield_activelinesgr() {        # name → FT_RET ("" = no highlight)
    ft_resolved_prop "$1" currentLineHighlight true
    [[ "$FT_RET" == true ]] || { FT_RET=""; return; }
    _ft_css_pe_or "$1" active "${FT_COLOR_ACTIVELINE:-}"
}

# _ft_textfield_wave_cell IDX row col rows cols → FT_TEXTFIELD_WAVE_ROW FT_TEXTFIELD_WAVE_COLUMN (the cell) + FT_TEXTFIELD_WAVE_GLYPH_HEAVY / FT_TEXTFIELD_WAVE_GLYPH_LIGHT
# (its glyph, heavy and light). Ring index 0 is the top-left corner, clockwise.
# Both weights come out together so a cell can be lit and later put back without a
# second mapping that might disagree with this one.
_ft_textfield_wave_cell() {            # idx row col rows cols
    local i=$1 row=$2 col=$3 rows=$4 cols=$5
    if (( i < cols )); then                                     # top, left→right
        FT_TEXTFIELD_WAVE_ROW=$row; FT_TEXTFIELD_WAVE_COLUMN=$(( col + i )); FT_TEXTFIELD_WAVE_GLYPH_HEAVY=$FT_GLYPH_HORIZONTAL_HEAVY; FT_TEXTFIELD_WAVE_GLYPH_LIGHT=$FT_GLYPH_HORIZONTAL
    elif (( i < cols + rows - 2 )); then                        # right, top→bottom
        FT_TEXTFIELD_WAVE_ROW=$(( row + 1 + i - cols )); FT_TEXTFIELD_WAVE_COLUMN=$(( col + cols - 1 )); FT_TEXTFIELD_WAVE_GLYPH_HEAVY=$FT_GLYPH_VERTICAL_HEAVY; FT_TEXTFIELD_WAVE_GLYPH_LIGHT=$FT_GLYPH_VERTICAL
    elif (( i < 2*cols + rows - 2 )); then                      # bottom, right→left
        FT_TEXTFIELD_WAVE_ROW=$(( row + rows - 1 )); FT_TEXTFIELD_WAVE_COLUMN=$(( col + 2*cols + rows - 3 - i )); FT_TEXTFIELD_WAVE_GLYPH_HEAVY=$FT_GLYPH_HORIZONTAL_HEAVY; FT_TEXTFIELD_WAVE_GLYPH_LIGHT=$FT_GLYPH_HORIZONTAL
    else                                                        # left, bottom→top
        FT_TEXTFIELD_WAVE_ROW=$(( row + 2*cols + 2*rows - 4 - i )); FT_TEXTFIELD_WAVE_COLUMN=$col; FT_TEXTFIELD_WAVE_GLYPH_HEAVY=$FT_GLYPH_VERTICAL_HEAVY; FT_TEXTFIELD_WAVE_GLYPH_LIGHT=$FT_GLYPH_VERTICAL
    fi
    case "$FT_TEXTFIELD_WAVE_ROW,$FT_TEXTFIELD_WAVE_COLUMN" in                     # corners take the elbow
        "$row,$col")                                   FT_TEXTFIELD_WAVE_GLYPH_HEAVY=$FT_GLYPH_TOP_LEFT_HEAVY; FT_TEXTFIELD_WAVE_GLYPH_LIGHT=$FT_GLYPH_TOP_LEFT ;;
        "$row,$(( col + cols - 1 ))")                  FT_TEXTFIELD_WAVE_GLYPH_HEAVY=$FT_GLYPH_TOP_RIGHT_HEAVY; FT_TEXTFIELD_WAVE_GLYPH_LIGHT=$FT_GLYPH_TOP_RIGHT ;;
        "$(( row + rows - 1 )),$col")                  FT_TEXTFIELD_WAVE_GLYPH_HEAVY=$FT_GLYPH_BOTTOM_LEFT_HEAVY; FT_TEXTFIELD_WAVE_GLYPH_LIGHT=$FT_GLYPH_BOTTOM_LEFT ;;
        "$(( row + rows - 1 )),$(( col + cols - 1 ))") FT_TEXTFIELD_WAVE_GLYPH_HEAVY=$FT_GLYPH_BOTTOM_RIGHT_HEAVY; FT_TEXTFIELD_WAVE_GLYPH_LIGHT=$FT_GLYPH_BOTTOM_RIGHT ;;
    esac
}

# _ft_textfield_ring_print — paint ONE ring cell, lit (a crest is on it) or normal. The only
# place that knows a ring cell might be a SCROLLBAR and not a border glyph: a crest
# reaching a thumb THICKENS the thumb in place. Stamping box drawing over it was
# the old bug — the scrollbar visibly broke apart on every lap.
_ft_textfield_ring_print() {           # idx row col rows cols barsgr lit
    local i=$1 row=$2 col=$3 rows=$4 cols=$5 sgr=$6 lit=$7
    _ft_textfield_wave_cell "$i" "$row" "$col" "$rows" "$cols"
    # Every glyph here is exactly ONE cell wide, so paint with ft_print_at_width (known width)
    # NOT ft_print_at: ft_print_at's clip test compares BYTE length to the clip edge, and a
    # coloured single glyph is a ~45-byte string (two SGRs), which trips the test on
    # nearly every cell of a narrow field and forces an O(n²) per-character width scan.
    # That scan — not truecolor itself — was the animation's real cost. ft_print_at_width skips it.
    # (Bold IS the "subtle colour change": on box/block glyphs terminals brighten.)
    if   (( FT_TEXTFIELD_WAVE_COLUMN == FT_TEXTFIELD_FRAME_THUMB_VERTICAL_COLUMN && FT_TEXTFIELD_WAVE_ROW >= FT_TEXTFIELD_FRAME_THUMB_VERTICAL_TOP && FT_TEXTFIELD_WAVE_ROW <= FT_TEXTFIELD_FRAME_THUMB_VERTICAL_BOTTOM )); then
        # VERTICAL thumb: RIDE it. ▊→▉ is an honest step fatter — same lean, same
        # place, just wider — so the crest thickens the bar without disfiguring it.
        if (( lit )); then ft_print_at_width "$FT_TEXTFIELD_WAVE_ROW" "$FT_TEXTFIELD_WAVE_COLUMN" "$FT_TEXTFIELD_FRAME_THUMB_SGR$FT_ANSI_BOLD$FT_TEXTFIELD_FRAME_THUMB_VERTICAL_GLYPH_THICK$FT_COLOR_RESET" 1
        else               ft_print_at_width "$FT_TEXTFIELD_WAVE_ROW" "$FT_TEXTFIELD_WAVE_COLUMN" "$FT_TEXTFIELD_FRAME_THUMB_SGR$FT_TEXTFIELD_FRAME_THUMB_VERTICAL_GLYPH$FT_COLOR_RESET" 1; fi
    elif (( ! lit && FT_TEXTFIELD_WAVE_ROW == FT_TEXTFIELD_FRAME_THUMB_HORIZONTAL_ROW && FT_TEXTFIELD_WAVE_COLUMN >= FT_TEXTFIELD_FRAME_THUMB_HORIZONTAL_LEFT && FT_TEXTFIELD_WAVE_COLUMN <= FT_TEXTFIELD_FRAME_THUMB_HORIZONTAL_RIGHT )); then
        # HORIZONTAL thumb, crest gone: put the ▀ thumb back.
        ft_print_at_width "$FT_TEXTFIELD_WAVE_ROW" "$FT_TEXTFIELD_WAVE_COLUMN" "$FT_TEXTFIELD_FRAME_THUMB_SGR$FT_TEXTFIELD_FRAME_THUMB_HORIZONTAL_GLYPH$FT_COLOR_RESET" 1
    else
        # A plain border cell — AND a horizontal-thumb cell the crest is ON. The
        # horizontal bar has no honest "fatter" glyph (▀→█ grows DOWNWARD, past the
        # bar, and in the bar's colour — which read as a blob dropping below the
        # edge). So the crest does not ride it; it PASSES THROUGH: the cell shows
        # the same heavy ━ as its neighbours, one continuous band of fatness pumping
        # along the bottom, and the ▀ re-emerges the instant the crest moves on.
        if (( lit )); then ft_print_at_width "$FT_TEXTFIELD_WAVE_ROW" "$FT_TEXTFIELD_WAVE_COLUMN" "$sgr$FT_ANSI_BOLD$FT_TEXTFIELD_WAVE_GLYPH_HEAVY$FT_COLOR_RESET" 1
        else               ft_print_at_width "$FT_TEXTFIELD_WAVE_ROW" "$FT_TEXTFIELD_WAVE_COLUMN" "$sgr$FT_TEXTFIELD_WAVE_GLYPH_LIGHT$FT_COLOR_RESET" 1; fi
    fi
}

# _ft_textfield_thumb_cache NAME — hoist this field's thumb spans and glyphs into globals
# ONCE per frame. They are loop-invariant, and the per-cell function runs ~24 times
# a frame on a path whose entire reason to exist is being cheap: re-splitting the
# published geometry inside it cost more than everything else here put together.
_ft_textfield_thumb_cache() {          # name
    local -a v=(${FT_TEXTFIELD_VBAR[$1]:-}) h=(${FT_TEXTFIELD_HBAR[$1]:-})
    FT_TEXTFIELD_FRAME_THUMB_VERTICAL_COLUMN=${v[0]:--1}; FT_TEXTFIELD_FRAME_THUMB_VERTICAL_TOP=${v[1]:-0}; FT_TEXTFIELD_FRAME_THUMB_VERTICAL_BOTTOM=${v[2]:--1}
    FT_TEXTFIELD_FRAME_THUMB_HORIZONTAL_ROW=${h[0]:--1}; FT_TEXTFIELD_FRAME_THUMB_HORIZONTAL_LEFT=${h[1]:-0}; FT_TEXTFIELD_FRAME_THUMB_HORIZONTAL_RIGHT=${h[2]:--1}
    _ft_textfield_thumbfg "$1"; FT_TEXTFIELD_FRAME_THUMB_SGR="$FT_COLOR_BORDER$FT_RET"
    _ft_textfield_thumb_glyphs
    FT_TEXTFIELD_FRAME_THUMB_VERTICAL_GLYPH=$FT_TEXTFIELD_THUMB_VERTICAL; FT_TEXTFIELD_FRAME_THUMB_VERTICAL_GLYPH_THICK=$FT_TEXTFIELD_THUMB_VERTICAL_THICK; FT_TEXTFIELD_FRAME_THUMB_HORIZONTAL_GLYPH=$FT_TEXTFIELD_THUMB_HORIZONTAL; FT_TEXTFIELD_FRAME_THUMB_HORIZONTAL_GLYPH_THICK=$FT_TEXTFIELD_THUMB_HORIZONTAL_THICK
}

# Every crest at one phase, lit or erased. Reads the beacon params set by
# _ft_anim_beacon_params, and needs _ft_textfield_wave_geom run first.
_ft_textfield_crests() {               # phase name row col rows cols sgr lit
    local ph=$1 name=$2 row=$3 col=$4 rows=$5 cols=$6 sgr=$7 lit=$8
    _ft_textfield_thumb_cache "$name"
    local per=$FT_TEXTFIELD_WAVE_PERIMETER c k i
    for (( c=0; c<BEACON_CRESTS; c++ )); do     # each crest trails the one ahead
        for (( k=0; k<BEACON_CREST; k++ )); do
            i=$(( (ph - c*FT_TEXTFIELD_WAVE_CREST_GAP - k) % per )) # looping: the ring has no ends, so
            (( i < 0 )) && (( i += per ))       # every crest is always somewhere on it
            _ft_textfield_ring_print "$i" "$row" "$col" "$rows" "$cols" "$sgr" "$lit"
        done
    done
}

# ── border animation: a reusable BORDER capability, not a textfield feature ───
# The border of any control can be animated. `activateBorderAnimation` picks WHICH
# animation runs when the control is activated (none/unset = off). Every animation
# is a set of routines named _ft_banim_<name>_<phase>, and the engine always calls
# them as  INSTANCE STRUCTURE …  — the structure being "border" here. That second
# argument is the whole point of the design: the same routine name ("sheen") can one
# day animate a label's TEXT (structure "text") by branching on it, and no caller
# ever hand-forwards the instance/structure pair.
_ft_border_anim_name() {        # name → FT_RET (animation to play, or "")
    # CSS drives the border animation as a STRUCTURE: `textfield::border { animation: sheen }`
    # (or beacon / none). A pseudo-element rule wins over the legacy activateBorderAnimation
    # property; with no ::border rule we fall back to that property (default: the calm sheen).
    if [[ -n "${_FT_CSS_LOADED:-}" ]]; then
        _ft_css_query_pe "$1" border animation
        if (( _QGOT )); then
            [[ "$FT_RET" == none || -z "$FT_RET" ]] && FT_RET="" || FT_RET=${FT_RET%% *}
            return
        fi
    fi
    # Default is the calm SHEEN — a field you are editing/scrolling breathes a subtle border
    # sheen so the active field is unmistakable. Opt out per-instance with
    # activateBorderAnimation=none, or in CSS with textfield::border{animation:none}.
    _ft_get_raw "$1" activateBorderAnimation; FT_RET=${FT_RET:-sheen}
    [[ "$FT_RET" == none ]] && FT_RET=""
}
_ft_border_anim_begin() {       # name — arm the control's activate-border animation
    _ft_border_anim_name "$1"; local a=$FT_RET
    [[ -n "$a" ]] && declare -F "_ft_banim_${a}_begin" >/dev/null && "_ft_banim_${a}_begin" "$1" border
}
# Laid over the END of a full draw (so the effect is right before the first tick).
_ft_border_anim_overlay() {     # name row col rows cols barsgr
    # Paint the border animation ONLY when this control's loop is actually running a border
    # animation — i.e. a `_ft_banim_*` FRAME is bound. A CSS structure animation (e.g. a
    # pulsing scrollbar) arms the SAME per-control loop but binds NO frame, so without this
    # guard its phase would drive the sheen and make it "play on focus" (and cost a full ring
    # repaint every frame). Frame bound ⇒ the sheen/beacon was begun on activate.
    [[ "${FT_ANIM_FRAME[$1]:-}" == _ft_banim_* ]] || return 0
    _ft_border_anim_name "$1"; local a=$FT_RET n=$1; shift
    [[ -n "$a" ]] && declare -F "_ft_banim_${a}_overlay" >/dev/null && "_ft_banim_${a}_overlay" "$n" border "$@"
}

# The border SGR a border animation shades — resolved through a per-PROTOTYPE accessor so
# this generalises past text fields. A text field's border carries its EDIT-STATE
# colour (azure focused / gold editing / cyan read-only), so it overrides with
# _ft_textfield_border_sgr; anything else falls back to the theme border (+ any borderColor).
# (FT_PROTO_BORDER_SGR is declared with the rest of the prototype struct in ft-forms.bash — it
# is a struct slot like any other, written as `borderSgr=` by ft_prototype.)
_ft_default_border_sgr() { _ft_color_override "$1" borderColor 38; FT_RET="$FT_COLOR_BORDER$FT_RET"; }
_ft_border_sgr() {              # name → FT_RET
    local _ty=${FT_TYPE[$1]:-} fn=""    # empty once the control is removed
    [[ -n "$_ty" ]] && fn=${FT_PROTO_BORDER_SGR[$_ty]:-}
    "${fn:-_ft_default_border_sgr}" "$1"
}

# Register the border-animation property kinds. Kinds are GLOBAL, so one call makes
# every control accept them — this is what makes border animation reusable, not a
# text-field feature. activateBorderAnimation = which animation on activate;
# activateAnimationTypingDelay = the typing debounce (seconds); borderAnimation* =
# the shared tunables (rate/step/depth/shear/glow, plus beacon's crest width/count).
_ft_border_anim_register_props() {
    ft_prop_kind_set activateBorderAnimation      paint
    ft_prop_kind_set activateAnimationTypingDelay paint
    ft_prop_kind_set borderAnimationRate  paint; ft_prop_kind_set borderAnimationStep   paint
    ft_prop_kind_set borderAnimationShear paint; ft_prop_kind_set borderAnimationDepth  paint
    ft_prop_kind_set borderAnimationGlow  paint
    ft_prop_kind_set borderAnimationCrest paint; ft_prop_kind_set borderAnimationCrests paint
    ft_prop_kind_set numberOfTones        paint   # sheen gradient smoothness (was a global)
}

# ── beacon: a wave of thickness circling the border (calls things out) ────────
# Tunables are the shared borderAnimation* properties; beacon's own knobs are the
# crest width/count. Its begin BINDS _ft_banim_beacon_frame to the engine so every
# tick arrives as `_ft_banim_beacon_frame INSTANCE STRUCTURE`.
_ft_anim_beacon_params() {      # name → BEACON_CREST/CRESTS/STEP/RATE
    _ft_get_raw "$1" borderAnimationCrest;  BEACON_CREST=${FT_RET:-3}
    _ft_get_raw "$1" borderAnimationCrests; BEACON_CRESTS=${FT_RET:-4}
    _ft_get_raw "$1" borderAnimationStep;   BEACON_STEP=${FT_RET:-2}
    _ft_get_raw "$1" borderAnimationRate;   BEACON_RATE=${FT_RET:-80}
    (( BEACON_CRESTS < 1 )) && BEACON_CRESTS=1
    # A crest narrower than the per-frame step would skip cells and strobe.
    (( BEACON_CREST < BEACON_STEP )) && BEACON_CREST=$BEACON_STEP
}
_ft_banim_beacon_begin() {      # instance structure
    local n=$1; [[ "$2" == border ]] || return 0
    local r=${FT_MEASURED_HEIGHT[$n]:-3} c=${FT_MEASURED_WIDTH[$n]:-0}
    (( c > 1 && r > 1 )) || return 0
    _ft_anim_beacon_params "$n"
    _ft_textfield_wave_geom "$r" "$c" "$BEACON_CRESTS"
    ft_anim_start "$n" "$FT_TEXTFIELD_WAVE_PERIMETER" "$BEACON_RATE" "$BEACON_STEP" 1   # one lap, looping
    _ft_banim_bind "$n"                                            # frame + typing debounce
}
_ft_banim_beacon_overlay() {    # instance structure row col rows cols barsgr
    local name=$1 row=$3 col=$4 rows=$5 cols=$6 sgr=$7
    ft_anim_phase "$name"; local ph=$FT_RET
    (( ph < 0 || rows < 2 || cols < 2 )) && return
    _ft_anim_beacon_params "$name"
    _ft_textfield_wave_geom "$rows" "$cols" "$BEACON_CRESTS"
    _ft_textfield_crests "$ph" "$name" "$row" "$col" "$rows" "$cols" "$sgr" 1
}
_ft_banim_beacon_frame() {      # instance structure — erase old crests, light new
    local name=$1; [[ "$2" == border ]] || return 0
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local rows=${FT_MEASURED_HEIGHT[$name]:-0} cols=${FT_MEASURED_WIDTH[$name]:-0}
    (( rows < 2 || cols < 2 )) && return 0
    ft_anim_phase "$name"; local ph=$FT_RET; (( ph < 0 )) && return 0
    _ft_border_sgr "$name"; local sgr=$FT_RET
    _ft_anim_beacon_params "$name"
    _ft_textfield_wave_geom "$rows" "$cols" "$BEACON_CRESTS"
    local per=$FT_TEXTFIELD_WAVE_PERIMETER
    local prev=$(( (ph - BEACON_STEP) % per )); (( prev < 0 )) && (( prev += per ))
    _ft_clip_for "$name"        # a partial paint must respect ancestors' overflow
    _ft_textfield_crests "$prev" "$name" "$row" "$col" "$rows" "$cols" "$sgr" 0   # erase
    _ft_textfield_crests "$ph"   "$name" "$row" "$col" "$rows" "$cols" "$sgr" 1   # relight
    return 0
}

# Bind a just-started border animation's FRAME routine + typing debounce. Shared by
# both animations: the engine will call `_ft_banim_<name>_frame INSTANCE border`, and
# hold it frozen until the caret has been still for activateAnimationTypingDelay
# seconds (default 2) — so typing never fights the sweep.
_ft_banim_bind() {              # name [hold_struct]
    local n=$1 anim delay
    _ft_border_anim_name "$n"; anim=$FT_RET
    _ft_get_raw "$n" activateAnimationTypingDelay; delay=${FT_RET:-2}
    ft_anim_bind "$n" "_ft_banim_${anim}_frame" border $(( delay * 1000 )) "${2:-}"
}

# ── sheen: a barely-there diagonal tone gradient + glow (the resting state) ────
# No thickness at all — the glyphs never change shape. Only their TONE shifts, in a
# soft band that crosses the box diagonally and drifts left→right, and the border's
# own background is tinted a hair toward the glyph colour under the band, so the
# lit stretch appears to GLOW faintly rather than just brighten. Top and bottom
# edges are out of phase (the diagonal), and the verticals carry the band between
# them so the whole box reads as one gradient, not four independent edges.
#
# Both effects need real shades of the theme colour, so this works in RGB: parse
# the border's foreground (the state colour) and background out of the palette,
# and build two ramps — a foreground tone ramp and a background glow ramp — with
# ft_rgb_sgr, which re-quantises to whatever the terminal actually supports. With
# no colour at all there are no shades to make, so sheen is simply a no-op: it is
# meant to be barely perceptible, and "absent" is the honest low end of that.
# Reading a colour back out of an SGR is ft_sgr_rgb, in ft-core.bash beside its inverse
# ft_rgb_sgr. This file used to carry a private copy of it and of the 256→rgb mapping; the
# copy's 0-15 branch answered a flat grey 128 ("not used by our palette"), which stopped being
# true the moment a theme reached for a base-16 index. ft_256_to_rgb has always had the real
# table.
_ft_clamp255() { (( $1 < 0 )) && FT_RET=0 || { (( $1 > 255 )) && FT_RET=255 || FT_RET=$1; }; }
_ft_lum() { FT_RET=$(( (30*$1 + 59*$2 + 11*$3)/100 )); }   # perceived luminance 0-255
# Re-shade a colour to a TARGET luminance by lerping it toward white (to lighten)
# or black (to darken), keeping its hue as far as the endpoints allow. This is how
# the sheen stays theme-correct: it moves the border colour along the light↔dark
# axis by a chosen amount, whatever that colour is.
_ft_shade_to_lum() {            # r g b targetL → FT_RGB_RED FT_RGB_GREEN FT_RGB_BLUE
    local r=$1 g=$2 b=$3 lt=$4 lb f
    _ft_lum "$r" "$g" "$b"; lb=$FT_RET
    if (( lt >= lb )); then f=$(( (lt-lb)*1000/(255-lb+1) ))   # toward white
        FT_RGB_RED=$(( r+(255-r)*f/1000 )); FT_RGB_GREEN=$(( g+(255-g)*f/1000 )); FT_RGB_BLUE=$(( b+(255-b)*f/1000 ))
    else f=$(( (lb-lt)*1000/(lb+1) ))                          # toward black
        FT_RGB_RED=$(( r-r*f/1000 )); FT_RGB_GREEN=$(( g-g*f/1000 )); FT_RGB_BLUE=$(( b-b*f/1000 )); fi
}
# Build FT_SHEEN_FOREGROUND[] (border tones, trough→crest) and FT_SHEEN_BACKGROUND[] (the glow/shadow).
# Two rules make it read on every theme:
#   • DIRECTION comes from the background. Dark bg → the crest BRIGHTENS (a glint);
#     light bg → it DARKENS (a shadow). Brightening toward white on white just erases
#     the border, which is why light mode looked broken.
#   • The TROUGH is always the resting accent — never pushed lighter or darker to
#     manufacture swing. Moving it made light mode's border wash out to "too bright".
#     The swing is the crest's alone; a theme whose accent already sits bright
#     (Ocean's cyan) simply gets a shorter — but honest — sweep.
# The glow is a hue-PRESERVING luminance shift of the background (lighter on dark
# themes, darker on light ones), NOT a mix toward the accent. A hue mix turned the
# border background into a saturated cyan patch on Ocean that appeared and cut off
# abruptly; a gentle brightness halo stays subtle and smooth in any palette.
_ft_sheen_ramps() {             # accentR accentG accentB  bgR bgG bgB  depth glow n
    local ar=$1 ag=$2 ab=$3 br=$4 bgc=$5 bb=$6 depth=$7 glow=$8 n=$9 i r g b Lt
    _ft_lum "$ar" "$ag" "$ab"; local La=$FT_RET
    _ft_lum "$br" "$bgc" "$bb"; local Lb=$FT_RET
    local dir=1 margin=45 minswing=110; (( Lb >= 128 )) && dir=-1   # brighten on dark, darken on light
    local crestL troughL=$La                     # trough defaults to the resting accent
    if (( dir > 0 )); then
        crestL=$(( La + depth )); (( crestL > 248 )) && crestL=248
        # DARK themes only: when a near-white accent (Ocean's cyan) leaves too little
        # room to brighten, DIM the trough — down toward the bg but never into it — so
        # the sweep keeps real contrast. Light themes never do this: dimming their
        # trough means LIGHTENING it, which washed the border out ("too bright").
        (( crestL - troughL < minswing )) && troughL=$(( crestL - minswing ))
        (( troughL < Lb + margin )) && troughL=$(( Lb + margin ))
        (( crestL <= troughL )) && crestL=$(( troughL + 30 )); (( crestL > 255 )) && crestL=255
    else
        crestL=$(( La - depth )); (( crestL < 8 )) && crestL=8
    fi
    FT_SHEEN_FOREGROUND=(); FT_SHEEN_BACKGROUND=()
    for (( i=0; i<n; i++ )); do
        Lt=$(( troughL + (crestL - troughL)*i/(n-1) ))
        _ft_shade_to_lum "$ar" "$ag" "$ab" "$Lt"
        _ft_clamp255 "$FT_RGB_RED"; r=$FT_RET; _ft_clamp255 "$FT_RGB_GREEN"; g=$FT_RET; _ft_clamp255 "$FT_RGB_BLUE"; b=$FT_RET
        ft_rgb_sgr "$r" "$g" "$b" 38; FT_SHEEN_FOREGROUND+=("$FT_RET")
        # glow: lerp the border background toward the ACCENT — 0 at the trough, glow%
        # at the crest. The accent IS the state colour, so the glow is gold while
        # editing, azure while focused. HOW MUCH bleeds is the theme's call (glow, from
        # FT_SHEEN_GLOW): full on a dark neutral background where it reads as a lovely
        # coloured halo, a whisper on saturated/light themes where more looks chunky.
        _ft_clamp255 $(( br  + (ar-br)*glow*i/((n-1)*100) )); r=$FT_RET
        _ft_clamp255 $(( bgc + (ag-bgc)*glow*i/((n-1)*100) )); g=$FT_RET
        _ft_clamp255 $(( bb  + (ab-bb)*glow*i/((n-1)*100) )); b=$FT_RET
        ft_rgb_sgr "$r" "$g" "$b" 48; FT_SHEEN_BACKGROUND+=("$FT_RET")
    done
}
# The band's spatial length (diagonal corner to corner): one full tone cycle spans
# it, so exactly one soft highlight crosses the box at a time. begin and paint MUST
# compute it identically or the loop wraps at the wrong point and the band jumps.
_ft_sheen_band() {              # rows cols shear → FT_RET
    local band=$(( $2 + $3*($1-1) )); (( band < 2 )) && band=2; FT_RET=$band
}

# Cached ring geometry for the ACTIVE field: each cell's screen position, its light
# glyph, and its diagonal coordinate — all invariant between frames, so they are
# built ONCE per size and then just read. Without this the per-frame loop's real
# cost is 164 _ft_textfield_wave_cell calls (~20ms on a tall field), swamping the diff; with
# it the loop is bare arithmetic. Only one field animates at a time, so a single
# global cache guarded by a signature is enough — a field switch just rebuilds it.
_FT_SHEEN_SIGNATURE=""; _FT_SHEEN_PERIMETER=0
_FT_SHEEN_RING_ROW=(); _FT_SHEEN_RING_COLUMN=(); _FT_SHEEN_RING_GLYPH=(); _FT_SHEEN_RING_DIAGONAL=()
_ft_sheen_geo() {               # name row col rows cols shear
    local sig="$1:$2:$3:$4:$5:$6"
    [[ "$sig" == "$_FT_SHEEN_SIGNATURE" ]] && return
    _FT_SHEEN_SIGNATURE=$sig
    local row=$2 col=$3 rows=$4 cols=$5 shear=$6
    local per=$(( 2*cols + 2*rows - 4 )) i
    _FT_SHEEN_RING_ROW=(); _FT_SHEEN_RING_COLUMN=(); _FT_SHEEN_RING_GLYPH=(); _FT_SHEEN_RING_DIAGONAL=(); _FT_SHEEN_PERIMETER=$per
    for (( i=0; i<per; i++ )); do
        _ft_textfield_wave_cell "$i" "$row" "$col" "$rows" "$cols"
        _FT_SHEEN_RING_ROW[i]=$FT_TEXTFIELD_WAVE_ROW; _FT_SHEEN_RING_COLUMN[i]=$FT_TEXTFIELD_WAVE_COLUMN; _FT_SHEEN_RING_GLYPH[i]=$FT_TEXTFIELD_WAVE_GLYPH_LIGHT
        _FT_SHEEN_RING_DIAGONAL[i]=$(( (FT_TEXTFIELD_WAVE_COLUMN - col) + shear*(FT_TEXTFIELD_WAVE_ROW - row) ))   # the diagonal, baked in
    done
}
_ft_banim_sheen_begin() {       # instance structure
    local n=$1; [[ "$2" == border ]] || return 0
    local r=${FT_MEASURED_HEIGHT[$n]:-3} c=${FT_MEASURED_WIDTH[$n]:-0}
    (( c > 1 && r > 1 )) || return 0
    local shear rate step
    _ft_get_raw "$n" borderAnimationShear; shear=${FT_RET:-2}   # MUST match the paint's default
    _ft_get_raw "$n" borderAnimationRate;  rate=${FT_RET:-120}  # ms/frame (~8fps): calm, and
                                                        # cheap even on a tall field,
                                                        # where each frame walks the
                                                        # whole ring (~164 cells)
    _ft_get_raw "$n" borderAnimationStep;  step=${FT_RET:-1}    # 1 band-cell/frame — slow drift
    _ft_sheen_band "$r" "$c" "$shear"
    ft_anim_start "$n" "$FT_RET" "$rate" "$step" 1
    # Two phases via the ONE routine, driven by the debounce as pre/post events:
    #   activated  → HOLD phase: render the border STATIC, at the phase the motion will
    #                start from — so the field says "you're active" AND already looks
    #                like its animated self. When motion begins it just … begins; there
    #                is no jarring "it suddenly turned into a different thing".
    #   typingDelay→ MAIN phase: the same "border", now advancing.
    # Both are the "border" structure — the pre is not a different look, just a still
    # frame of the SAME one, in phase. (The distinct "borderGlow" structure is kept in
    # the routine for callers who do want a separate glow-in preview.)
    _ft_banim_bind "$n" border
}
# Last tone index painted per ring cell, one field per key ("k0 k1 …", -1 = a
# skipped scrollbar cell). The gradient only DRIFTS, so from one frame to the next
# almost every cell keeps the same quantised tone: diffing against this lets a frame
# repaint only the handful of cells that actually crossed a tone boundary, the same
# touch-only-what-changed rule that makes beacon cheap. Whole-ring repaints (~164
# cells on a tall field) would otherwise cost ~23ms/frame — a quarter of a core, for
# as long as the caret sits there. MUST be declare -A (name key evaluates as maths).
declare -A FT_SHEEN_LIT_CELL=()
# Frozen-frame cache. A full draw of the field (every keystroke / cursor move) repaints
# the border in its PLAIN state colour, clobbering the sheen — so the overlay must put
# the sheen back, or the glow flickers off while you navigate. Re-rendering the whole
# ring each keystroke is ~14ms (what once "destroyed typing"), so instead we render the
# CURRENT frozen frame ONCE and cache the exact bytes; while the phase (and geometry and
# state colour) are unchanged — which is the whole time you are typing/navigating, since
# the debounce holds the phase still — every later redraw just BLITS those bytes back.
# Keyed by a signature so a phase advance, a move, or an edit-state colour change forces
# a fresh render. This is what makes the border "freeze on the frame it's on".
declare -A FT_SHEEN_FROZEN=() FT_SHEEN_FROZEN_SIGNATURE=()
_ft_anim_sheen_paint() {        # name row col rows cols phase [force] [structure]
    local name=$1 row=$2 col=$3 rows=$4 cols=$5 ph=$6 force=${7:-1} struct=${8:-border}
    (( rows < 2 || cols < 2 )) && return 0
    _ft_border_sgr "$name"; local base=$FT_RET          # the control's border SGR (bg + fg)
    ft_sgr_rgb "$base" 38 || return 0; local far=$FT_RGB_RED fag=$FT_RGB_GREEN fab=$FT_RGB_BLUE  # accent (fg) rgb
    ft_sgr_rgb "$base" 48 || return 0; local bbr=$FT_RGB_RED bbg=$FT_RGB_GREEN bbb=$FT_RGB_BLUE  # border  (bg) rgb
    # (no colour to read → no-op; sheen is meant to be barely-there, "absent" is fine)
    local depth glow shear n
    _ft_get_raw "$name" numberOfTones; n=${FT_RET:-$_FT_SHEEN_TONE_STEPS_DEFAULT}   # a PROPERTY, not a global
    _ft_get_raw "$name" borderAnimationDepth; depth=${FT_RET:-150} # crest LUMINANCE swing
                                                        # (0-255): how far the border glyph
                                                        # moves along the light↔dark axis.
    # Glow strength is the THEME's, via FT_SHEEN_GLOW — the colour that bleeds into the
    # border belongs to the palette, not a hardcoded number that only ever suited the
    # dark theme. A per-instance borderAnimationGlow still overrides it.
    _ft_get_raw "$name" borderAnimationGlow;  glow=${FT_RET:-${FT_SHEEN_GLOW:-18}}  # % toward accent
    _ft_get_raw "$name" borderAnimationShear; shear=${FT_RET:-2}  # horiz cells of skew per
                                                        # row — more tilt = more diagonal
    _ft_sheen_ramps "$far" "$fag" "$fab" "$bbr" "$bbg" "$bbb" "$depth" "$glow" "$n"
    _ft_sheen_band "$rows" "$cols" "$shear"; local band=$FT_RET
    local half=$(( band/2 )); (( half < 1 )) && half=1
    _ft_sheen_geo "$name" "$row" "$col" "$rows" "$cols" "$shear"
    _ft_textfield_thumb_cache "$name"
    # "borderGlow": paint the GLOW band but hold every glyph at its plain (trough)
    # colour — the glow appears, the busy fg gradient does not, yet it is the SAME
    # band at the same phase so it flows straight into the full "border" sweep.
    local glowonly=0; [[ "$struct" == borderGlow ]] && glowonly=1
    _ft_textfield_thumb_glyphs; local vt=$FT_TEXTFIELD_THUMB_VERTICAL ht=$FT_TEXTFIELD_THUMB_HORIZONTAL
    local per=$_FT_SHEEN_PERIMETER
    local -a prev=(); (( ! force )) && read -ra prev <<< "${FT_SHEEN_LIT_CELL[$name]:-}"
    local newidx="" i y x g t m k
    for (( i=0; i<per; i++ )); do
        y=${_FT_SHEEN_RING_ROW[i]}; x=${_FT_SHEEN_RING_COLUMN[i]}; g=${_FT_SHEEN_RING_GLYPH[i]}
        # A scrollbar thumb is part of the sweep too, not a static bar sitting across
        # it: paint the THUMB glyph (▊/▀) in the gradient's colour so the light rides
        # over it like any other border cell. It still reads as a scrollbar — the
        # block glyph is unmistakable — it just stops breaking the effect.
        if   (( x == FT_TEXTFIELD_FRAME_THUMB_VERTICAL_COLUMN && y >= FT_TEXTFIELD_FRAME_THUMB_VERTICAL_TOP && y <= FT_TEXTFIELD_FRAME_THUMB_VERTICAL_BOTTOM )); then g=$vt
        elif (( y == FT_TEXTFIELD_FRAME_THUMB_HORIZONTAL_ROW && x >= FT_TEXTFIELD_FRAME_THUMB_HORIZONTAL_LEFT && x <= FT_TEXTFIELD_FRAME_THUMB_HORIZONTAL_RIGHT )); then g=$ht; fi
        t=$(( (_FT_SHEEN_RING_DIAGONAL[i] - ph) % band )); (( t < 0 )) && (( t += band ))
        m=$t; (( m > half )) && m=$(( band - t ))       # triangle: bright at band centre
        (( m < 0 )) && m=0; (( m > half )) && m=half
        k=$(( m*(n-1)/half ))
        # force = full repaint (a fresh draw); otherwise only cells whose tone moved.
        # ft_print_at_width (known width 1), NOT ft_print_at — see _ft_textfield_ring_print: the byte-length clip
        # test would force an O(n²) width scan on every one of these coloured glyphs.
        # glow-only holds the fg at the trough (index 0) so only the bg glow shows.
        local fk=$k; (( glowonly )) && fk=0
        if (( force )) || (( ${prev[i]:--2} != k )); then
            ft_print_at_width "$y" "$x" "${FT_SHEEN_BACKGROUND[k]}${FT_SHEEN_FOREGROUND[fk]}$g$FT_COLOR_RESET" 1
        fi
        newidx+="$k "
    done
    FT_SHEEN_LIT_CELL[$name]=$newidx
}
_ft_banim_sheen_frame() {       # instance structure — repaint only cells whose tone moved
    local name=$1 glowonly
    # ONE routine, TWO structures. "borderGlow" (shown while you type / on activation)
    # paints ONLY the glow band, in phase with the main, with the border glyph in its
    # plain state colour — so the field says "you're active" instantly without the busy
    # gradient. "border" (after the typing delay) is the full moving sheen.
    case "$2" in border|borderGlow) ;; *) return 0 ;; esac    # the STRUCTURE is the switch
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local rows=${FT_MEASURED_HEIGHT[$name]:-0} cols=${FT_MEASURED_WIDTH[$name]:-0}
    ft_anim_phase "$name"; local ph=$FT_RET; (( ph < 0 )) && return 0
    _ft_clip_for "$name"        # a partial paint must respect ancestors' overflow
    _ft_anim_sheen_paint "$name" "$row" "$col" "$rows" "$cols" "$ph" 0 "$2"
}
_ft_banim_sheen_overlay() {     # instance structure row col rows cols barsgr — END of a full draw
    local name=$1; [[ "$2" == border ]] || return 0
    ft_anim_phase "$name"; local ph=$FT_RET
    if (( ph < 0 )); then unset "FT_SHEEN_FROZEN[$name]" "FT_SHEEN_FROZEN_SIGNATURE[$name]"; return; fi
    local row=$3 col=$4 rows=$5 cols=$6
    (( rows < 2 || cols < 2 )) && return
    # The frozen frame is valid while nothing that would change its pixels has changed:
    # the phase, the box geometry, and the border's edit-state colour. Same signature →
    # blit the cached bytes (a few hundred bytes appended to FT_OUT — negligible). This
    # is the fast path taken on every keystroke while the debounce holds the phase.
    # The signature must include WHERE THE THUMB IS, because the sheen paints the thumb as part
    # of the ring (see _ft_anim_sheen_paint). Without it, a field activated while its content
    # fits caches a ring with a plain border column — and then every later draw blits that
    # cached ring straight over the scrollbar the draw had just painted, so an overflowing
    # textarea showed NO thumb at all, and a scrolling one showed it frozen at the old rows.
    # Only the painted cells go in (x/y0/y1), not the track and maxScroll that follow them:
    # those change whenever a line is added, which would re-render the whole ring per keystroke.
    local vb=${FT_TEXTFIELD_VBAR[$name]:-} hb=${FT_TEXTFIELD_HBAR[$name]:-}
    _ft_border_sgr "$name"
    local sig="$ph|$row|$col|$rows|$cols|$FT_RET|${vb% * * *}|${hb% * * *}"
    if [[ "${FT_SHEEN_FROZEN_SIGNATURE[$name]:-}" == "$sig" ]]; then
        # Through _ft_print_bytes, not a raw FT_OUT+=: these bytes are part of what this control
        # painted, so they belong in its block. A raw append would put the ring on the screen and
        # leave it out of the record, and the next time that block was re-emitted — a modal
        # closing over a field that had been typed in — the border would come back without it.
        _ft_print_bytes "${FT_SHEEN_FROZEN[$name]}"
        return
    fi
    # Miss: render the ring ONCE at this phase (force = whole ring) and capture the exact
    # bytes it appended, so subsequent redraws at this phase are free. A force paint also
    # refreshes FT_SHEEN_LIT_CELL, keeping the idle diff-frame consistent.
    _ft_clip_for "$name"
    local before=${#FT_OUT}
    _ft_anim_sheen_paint "$name" "$row" "$col" "$rows" "$cols" "$ph" 1 border
    FT_SHEEN_FROZEN[$name]=${FT_OUT:before}
    FT_SHEEN_FROZEN_SIGNATURE[$name]=$sig
}

# A horizontal border row (top or bottom) `cols` wide, corners + rule between.
_ft_textfield_hborder() {              # screenrow col cols barsgr leftcorner rightcorner
    local r=$1 c=$2 cols=$3 sgr=$4 lc=$5 rc=$6 inner=$(( $3 - 2 )) rule
    (( inner < 0 )) && inner=0
    printf -v rule '%*s' "$inner" ''; rule=${rule// /$FT_GLYPH_HORIZONTAL}
    ft_print_at_width "$r" "$c" "$sgr$lc$rule$rc$FT_COLOR_RESET" "$cols"
}

_ft_draw_textfield_single() {   # name — a one-line field inside a thin box
    local name=$1
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local cols=${FT_MEASURED_WIDTH[$name]:-0}
    (( cols < 3 )) && return
    _ft_textfield_textw "$name"; local textw=$FT_RET   # sets FT_TEXTFIELD_LEFT_BORDER/FT_TEXTFIELD_RIGHT_BORDER (1/1 here)
    # A one-line field has exactly one row of content in exactly one row of viewport, and saying
    # so is not a formality: with overflowY=auto declared on the prototype, a field that
    # published NOTHING would leave ft_has_scrollbar reading 0 and 0, and the answer to "does this
    # have a bar" would depend on a property never being written rather than on the field being
    # full.
    _ft_textfield_publish_metrics "$name" 1 1

    ft_resolved_prop "$name" value "";       local val=$FT_RET   # a one-line field paints the string
    ft_resolved_prop "$name" placeholder ""; local ph=$FT_RET

    local focused=0; [[ "${FT_FOCUS:-}" == "$name" ]] && focused=1

    # The well stays a NEUTRAL input colour whether or not the field is focused —
    # focus is shown by the whole BORDER lighting up, not by recolouring the well
    # (which would clash with future coloured-text editing).
    _ft_textfield_wellbase "$name"; _ft_compose_sgr "$name" "$FT_RET"; local sgr=$FT_RET   # well: read-only viewers get the calmer view colour
    # Thin border: the box glyphs sit on the container background (FT_COLOR_BORDER's
    # bg) so all four sides read as ONE-cell lines, not filled blocks. Focus just
    # brightens the glyph foreground to the accent colour — a thin highlight box.
    _ft_textfield_border_sgr "$name"; local barsgr=$FT_RET   # RO cursor→cyan, editing→gold, focused→azure
    local bar="$barsgr$FT_GLYPH_VERTICAL"

    _ft_textfield_hborder "$row"        "$col" "$cols" "$barsgr" "$FT_GLYPH_TOP_LEFT" "$FT_GLYPH_TOP_RIGHT"   # top

    local body
    if [[ -z "$val" ]]; then                    # dim placeholder in the well
        _ft_css_pe_or "$name" placeholder "$FT_COLOR_INPUT$FT_COLOR_FADED"; local phsgr=$FT_RET   # `::placeholder`
        ft_fit "$ph" "$textw"; body="$phsgr$FT_FIT"
    else
        _ft_textfield_caret "$name"; local caret=$FT_RET
        # Horizontal scroll: keep the caret inside [scroll, scroll+textw), one
        # column of slack at the right so a caret past the last char still shows.
        #
        # `scroll` is COLUMNS and `caret` is CHARACTERS — the two are only the same number
        # while the value is ASCII. Comparing them directly meant that in a field holding
        # CJK the caret walked off the right edge and STAYED off: the window was sliced
        # `textw` characters wide (twice as many columns as fit), truncation threw the
        # second half away, and the caret cell landed in what had been thrown away. You
        # could not see what you were typing. See ft_display_col / ft_display_index.
        ft_display_col "$val" "$caret"; local caretcol=$FT_RET
        _ft_tf_hoff "$name"; local scroll=$FT_RET
        if _ft_textfield_engaged "$name"; then     # follow caret only while editing
            (( caretcol < scroll )) && scroll=$caretcol
            (( caretcol > scroll + textw - 1 )) && scroll=$(( caretcol - textw + 1 ))
        fi
        (( scroll < 0 )) && scroll=0
        # Back to a CHARACTER index to slice at, and to the column that index really sits
        # at — a wide glyph straddling the left edge is skipped whole, never halved.
        ft_display_index "$val" "$scroll"; local start=$FT_RET; scroll=$FT_DISPLAY_COL
        _ft_tf_hoff_set "$name" "$scroll"
        local window=${val:start:textw}   # ≥1 column per character, so textw chars always covers the well
        ft_display_width "$window"      # pad to COLUMNS, not characters (see the textarea draw)
        if (( FT_DISPLAY_WIDTH > textw )); then ft_display_truncate "$window" "$textw"; window=$FT_DISPLAY_TRUNCATED; ft_display_width "$window"; fi
        local wchars=${#window}         # characters actually shown — where the padding begins
        local pad=$(( textw - FT_DISPLAY_WIDTH )); (( pad < 0 )) && pad=0
        printf -v window '%s%*s' "$window" "$pad" ''
        # From here on everything indexes the WINDOW, which is a contiguous run of the
        # value starting at character `start` — so a document index maps by subtraction,
        # and _ft_textfield_rowspan's character slicing highlights whole glyphs.
        local vlo=0 vhi=0; _ft_textfield_selsgr "$name"; local spansgr=$FT_RET
        if _ft_textfield_selrange "$name"; then        # highlight the selected span
            vlo=$(( FT_SELECTION_START - start )); (( vlo < 0 )) && vlo=0; (( vlo > wchars )) && vlo=$wchars
            vhi=$(( FT_SELECTION_END - start )); (( vhi < 0 )) && vhi=0; (( vhi > wchars )) && vhi=$wchars
        elif _ft_textfield_engaged "$name"; then   # no selection, editing → BLOCK caret cell
            local ccol=$(( caret - start )); (( ccol < 0 )) && ccol=0
            (( ccol > ${#window} - 1 )) && ccol=$(( ${#window} - 1 ))
            vlo=$ccol; vhi=$(( ccol + 1 ))
            _ft_textfield_caretsgr "$name"; spansgr=$FT_RET      # ::caret, or the state's default block
        fi
        _ft_textfield_rowspan "$sgr" "$spansgr" "$window" "$vlo" "$vhi"; body=$FT_RET
    fi
    ft_print_at        $(( row+1 ))    "$col" "$bar$body$bar$FT_COLOR_RESET"                 # well
    _ft_textfield_hborder $(( row+2 ))  "$col" "$cols" "$barsgr" "$FT_GLYPH_BOTTOM_LEFT" "$FT_GLYPH_BOTTOM_RIGHT"    # bottom
    # A long value overflowing the well grows a horizontal scrollbar on the bottom
    # border (thumb sized/positioned from the h-scroll) — Left/Right scroll it.
    ft_display_width "$val"; local valcols=$FT_DISPLAY_WIDTH   # the bar measures the SCREEN, so columns
    if (( valcols > textw )); then
        local hmax=$valcols htrack=$textw
        local hthumbLen=$(( htrack * textw / hmax )); (( hthumbLen < 1 )) && hthumbLen=1
        local hmaxstart=$(( htrack - hthumbLen )); (( hmaxstart < 0 )) && hmaxstart=0
        local hmaxscroll=$(( hmax - textw )); (( hmaxscroll < 1 )) && hmaxscroll=1
        # THE THUMB MAY NOT LEAVE ITS TRACK. The draw deliberately allows one column of
        # slack past the last character so a caret sitting at the very end still shows, so
        # `scroll` can exceed hmaxscroll by design — and the thumb was then placed past the
        # right edge of the field, painting a cell over whatever control sits beside it.
        # (Reachable in ASCII too: it was integer division that happened to hide it.)
        local hthumbStart=$(( hmaxstart * scroll / hmaxscroll ))
        (( hthumbStart > hmaxstart )) && hthumbStart=$hmaxstart
        (( hthumbStart < 0 )) && hthumbStart=0
        local hxin=$(( col + FT_TEXTFIELD_LEFT_BORDER )) hc            # single-line well starts after the left border
        # ▀ (upper half) thumb in the accent colour: the partner of the vertical ▊ —
        # both hug the TOP-LEFT and lean toward the content. Never reads as the border
        # rule (which sits lower in the cell). Track stays the border's ─.
        local hthumb hfg; _ft_textfield_thumb_glyphs; hthumb=$FT_TEXTFIELD_THUMB_HORIZONTAL
        _ft_textfield_thumbfg "$name"; hfg=$FT_RET     # thumb matches the border's state colour
        for (( hc=hthumbStart; hc<hthumbStart+hthumbLen; hc++ )); do
            ft_print_at $(( row+2 )) $(( hxin + hc )) "$FT_COLOR_BORDER$hfg$hthumb$FT_COLOR_RESET"
        done
        FT_TEXTFIELD_HBAR[$name]="$(( row+2 )) $(( hxin + hthumbStart )) $(( hxin + hthumbStart + hthumbLen - 1 )) $hxin $htrack $hmaxscroll"
    else
        unset "FT_TEXTFIELD_HBAR[$name]"
    fi
    unset "FT_TEXTFIELD_VBAR[$name]"       # a one-line field never has a vertical bar

    _ft_border_anim_overlay "$name" "$row" "$col" 3 "$cols" "$barsgr"
}

_ft_draw_textfield_multi() {    # name — a word-wrapping textarea
    local name=$1
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local cols=${FT_MEASURED_WIDTH[$name]:-0} outerH=${FT_MEASURED_HEIGHT[$name]:-1}
    (( cols < 3 || outerH < 3 )) && return
    local vh=$(( outerH - 2 ))                   # visible text rows (inside the box)
    local top=$row bot=$(( row + outerH - 1 )) crow0=$(( row + 1 ))
    local gcol=$(( col + cols - 1 ))

    # The value is NOT fetched here. A textarea paints from the WRAPPED ROWS, and the only
    # thing it ever asked the whole string was "are you empty?" — for which it fetched a 150KB
    # document (~4ms) and then `[[ -z "$val" ]]` expanded it AGAIN to look (~5ms). The store
    # knows the length without materialising anything.
    _ft_textfield_len "$name"; local vlen=$FT_RET
    ft_resolved_prop "$name" placeholder ""; local ph=$FT_RET
    local focused=0; [[ "${FT_FOCUS:-}" == "$name" ]] && focused=1

    _ft_textfield_wellbase "$name"; _ft_compose_sgr "$name" "$FT_RET"; local sgr=$FT_RET   # well: read-only viewers get the calmer view colour
    # Thin border (see single-line draw): glyphs on the container bg, accent fg
    # when focused, so the box is a one-cell line on every side.
    _ft_textfield_border_sgr "$name"; local barsgr=$FT_RET   # RO cursor→cyan, editing→gold, focused→azure
    local lbar="$barsgr$FT_GLYPH_VERTICAL"                 # left border column
    local rbar="$barsgr$FT_GLYPH_VERTICAL$FT_COLOR_RESET"      # right border column (own write)

    _ft_textfield_textw "$name"; local textw=$FT_RET   # sets FT_TEXTFIELD_LEFT_BORDER/FT_TEXTFIELD_RIGHT_BORDER/FT_TEXTFIELD_LINE_NUMBER_WIDTH/FT_TEXTFIELD_WRAP_INDICATOR_WIDTH
    # EVERYTHING that only some fields need is now worked out only by the fields that need it.
    # A style lookup is ~0.4ms and this draw was making seven of them unconditionally — the
    # wrap/newline markers for a field with no rail, the placeholder for a field with text, the
    # selection colour with nothing selected. That was ~2ms of a 9ms frame, every frame,
    # computing things that were then thrown away.
    local wrapcell="" nlcell="" wiblank="" wrapsgr="" nlsgr="" showwrap=0 shownl=0
    if (( FT_TEXTFIELD_WRAP_INDICATOR_WIDTH > 0 )); then
        # The gutter exists for EITHER indicator, so each glyph is gated on its own flag
        # (a ↩ must not appear when only ¶ is on, and vice-versa).
        _ft_get_raw "$name" wrapIndicator;    [[ "$FT_RET" == true ]] && showwrap=1
        _ft_get_raw "$name" newlineIndicator; [[ "$FT_RET" == true ]] && shownl=1
        local wrapg=$'\xe2\x86\xa9'; (( FT_USE_UTF8 )) || wrapg='\'   # ↩ soft-wrap marker
        ft_fit "$wrapg" "$FT_TEXTFIELD_WRAP_INDICATOR_WIDTH"; wrapcell="$FT_FIT"                 # glyph fit to the column
        local nlg=$'\xc2\xb6'; (( FT_USE_UTF8 )) || nlg='<'           # ¶ hard-newline marker
        ft_fit "$nlg" "$FT_TEXTFIELD_WRAP_INDICATOR_WIDTH"; nlcell="$FT_FIT"
        printf -v wiblank '%*s' "$FT_TEXTFIELD_WRAP_INDICATOR_WIDTH" ''
        _ft_css_pe_or "$name" wrap   "$FT_COLOR_FADED$FT_COLOR_TEXT_NOTICE";  wrapsgr=$FT_RET   # `::wrap`
        _ft_css_pe_or "$name" newline "$FT_COLOR_FADED$FT_COLOR_TEXT_NOTICE"; nlsgr=$FT_RET     # `::newline`
    fi
    # Both gutters (line numbers left, wrap markers right) share ONE faded
    # background so they read as matching side rails; the ↩ keeps the notice
    # colour for its glyph, the numbers the muted faded fg.
    local lnblank=""; (( FT_TEXTFIELD_LINE_NUMBER_WIDTH > 0 )) && printf -v lnblank '%*s' "$FT_TEXTFIELD_LINE_NUMBER_WIDTH" ''
    _ft_css_pe_or "$name" gutter "$FT_COLOR_FADED"; local guttersgr=$FT_RET               # `::gutter`

    _ft_textfield_hborder "$top" "$col" "$cols" "$barsgr" "$FT_GLYPH_TOP_LEFT" "$FT_GLYPH_TOP_RIGHT"          # top
    _ft_textfield_hborder "$bot" "$col" "$cols" "$barsgr" "$FT_GLYPH_BOTTOM_LEFT" "$FT_GLYPH_BOTTOM_RIGHT"          # bottom

    # Empty → dim placeholder wrapped across the rows, still boxed (blank gutters).
    if (( vlen == 0 )); then
        _ft_css_pe_or "$name" placeholder "$FT_COLOR_INPUT$FT_COLOR_FADED"; local phsgr=$FT_RET # `::placeholder`
        ft_wrap "$ph" "$textw"
        local r pline
        for (( r=0; r<vh; r++ )); do
            pline=${FT_WRAP_LINES[$r]:-}
            ft_fit "$pline" "$textw"
            ft_print_at $(( crow0+r )) "$col" "$lbar$guttersgr$lnblank$phsgr$FT_FIT$guttersgr$wiblank$FT_COLOR_RESET"
            ft_print_at $(( crow0+r )) "$gcol" "$rbar"
        done
        return
    fi

    _ft_textfield_layout "$name" "$textw"
    local total=${#FT_TEXTFIELD_LINES_TEXT[@]}
    local overflow=0; (( total > vh )) && overflow=1

    _ft_textfield_caret "$name"; local caret=$FT_RET
    _ft_textfield_rowcol "$caret"; local cr=$FT_TEXTFIELD_LINES_CARET_ROW cc=$FT_TEXTFIELD_LINES_CARET_COLUMN

    # Vertical scroll: while EDITING, keep the caret row on screen; while merely
    # focused (idle read-only viewer) the arrows set `scrollTop` directly, so we
    # must NOT recompute it from the (hidden) caret or the view would never move.
    _ft_tf_voff "$name"; local vscroll=$FT_RET
    if _ft_textfield_engaged "$name"; then
        (( cr < vscroll )) && vscroll=$cr
        (( cr >= vscroll + vh )) && vscroll=$(( cr - vh + 1 ))
    fi
    local maxv=$(( total - vh )); (( maxv < 0 )) && maxv=0
    (( vscroll > maxv )) && vscroll=$maxv
    (( vscroll < 0 )) && vscroll=0
    # EXTENT BEFORE OFFSET. _ft_setprop bounds a scroll offset against the published pair, so
    # writing the offset first would clamp it against the measurement it is about to replace —
    # the very ordering _ft_textfield_publish_metrics documents for its own two writes.
    _ft_textfield_publish_metrics "$name" "$total" "$vh"
    _ft_tf_voff_set "$name" "$vscroll"

    # Horizontal scroll: only when NOT wrapping (a line can then be wider than
    # the box). Keep the caret's COLUMN in view, exactly like a single-line
    # field; every row shares the one offset, like a code editor.
    ft_resolved_prop "$name" wrap true; local wrap=$FT_RET
    local hscroll=0 hmax=0 hmaxscroll=0
    if [[ "$wrap" != true ]]; then
        # The widest line, and the caret's place in its own line, are both wanted in
        # COLUMNS — hscroll is a column offset (Left/Right pan it, the scrollbar thumb
        # measures it), while `cc` is a character offset. The inlined ASCII test is the
        # same one ft_display_width uses: a per-line function call is ~25µs, which a
        # thousand-line document cannot afford on every frame.
        _ft_textfield_widest_line; hmax=$FT_RET       # widest line drives the h-scrollbar
        hmaxscroll=$(( hmax - textw )); (( hmaxscroll < 0 )) && hmaxscroll=0
        _ft_tf_hoff "$name"; hscroll=$FT_RET
        ft_display_col "${FT_TEXTFIELD_LINES_TEXT[$cr]:-}" "$cc"; local cccol=$FT_RET
        if _ft_textfield_engaged "$name"; then    # follow caret only while editing
            (( cccol < hscroll )) && hscroll=$cccol
            (( cccol > hscroll + textw - 1 )) && hscroll=$(( cccol - textw + 1 ))
        fi
        (( hscroll < 0 )) && hscroll=0
        (( hscroll > hmaxscroll )) && hscroll=$hmaxscroll   # never past the last column
        _ft_tf_hoff_set "$name" "$hscroll"
    fi

    # Selection span (value indices), if any — highlighted per visible row below.
    local hassel=0 slo=0 shi=0
    _ft_textfield_selrange "$name" && { hassel=1; slo=$FT_SELECTION_START; shi=$FT_SELECTION_END; }

    # The RIGHT EDGE of each row — plain border, or a scrollbar thumb when the content
    # overflows — is worked out HERE rather than in a second pass, because it is painted as
    # part of its row. Two writes per row (row, then the one cell beside it) cost twice the
    # cursor-address and twice the append for a single extra column, and a paint call is ~120µs
    # whatever it paints: on a 30-row textarea that was 3.5ms of a 10ms frame, every frame.
    local thumbStart=0 thumbLen=0 vthumb="" tsgr=""
    if (( overflow )); then
        thumbLen=$(( vh * vh / total )); (( thumbLen < 1 )) && thumbLen=1
        local maxstart=$(( vh - thumbLen )); (( maxstart < 0 )) && maxstart=0
        (( maxv > 0 )) && thumbStart=$(( maxstart * vscroll / maxv ))
        # Thumb = ▊ (left three-quarters), the partner of the horizontal bar's ▀ (upper
        # half): both hug the TOP-LEFT, i.e. both lean toward the content they scroll.
        # Top-left is the only corner that works — Unicode gives LEFT blocks a full
        # ⅛…full range (so the vertical can be thickened to visually match a cell that
        # is ~2× taller than wide), while RIGHT/UPPER only offer a half block.
        _ft_textfield_thumb_glyphs; vthumb=$FT_TEXTFIELD_THUMB_VERTICAL
        _ft_textfield_thumbfg "$name"; tsgr="$FT_COLOR_BORDER$FT_RET"   # matches border state colour
    fi

    # Paint each visible row: [left border][line-number gutter][text well][wrap
    # gutter][right border or scrollbar thumb] — one write.
    local editing=0; _ft_textfield_engaged "$name" && editing=1
    local caretsgr="" selsgr="" alsgr=""               # …and none of these unless they apply
    (( editing )) && { _ft_textfield_caretsgr "$name"; caretsgr=$FT_RET; }  # ::caret, or the state block
    (( hassel ))  && { _ft_textfield_selsgr "$name";   selsgr=$FT_RET; }    # ::selection, or the theme
    # Composed OVER the well, so the caret row lifts from this field's own background and keeps
    # its own text colour — the highlight is a background, not a repaint of the line.
    (( editing )) && { _ft_textfield_activelinesgr "$name"; [[ -n "$FT_RET" ]] && alsgr="$sgr$FT_RET"; }
    local r li pad window lnseg wiseg num textseg base vlo vhi vis ccol edge lstart wchars
    # Every painted row is exactly this wide: border + line-number gutter + text well + rail.
    # lnseg is padded to FT_TEXTFIELD_LINE_NUMBER_WIDTH, window to textw, and all three wiseg variants are ft_fit to
    # FT_TEXTFIELD_WRAP_INDICATOR_WIDTH — so the width is known, and the row can skip ft_print_at's per-character rescan (its
    # cheap clip test is BYTE length, which the SGR escapes always push past the right edge).
    local roww=$(( 1 + FT_TEXTFIELD_LINE_NUMBER_WIDTH + textw + FT_TEXTFIELD_WRAP_INDICATOR_WIDTH ))
    for (( r=0; r<vh; r++ )); do
        li=$(( vscroll + r ))
        if (( FT_TEXTFIELD_LINE_NUMBER_WIDTH > 0 )); then           # right-justified logical line number
            num=""; (( li < total )) && (( ${FT_TEXTFIELD_LINES_NUMBER[li]:-0} > 0 )) && num=${FT_TEXTFIELD_LINES_NUMBER[li]}
            printf -v lnseg '%*s ' $(( FT_TEXTFIELD_LINE_NUMBER_WIDTH - 1 )) "$num"; lnseg="$guttersgr$lnseg"
        else lnseg=""; fi
        # hscroll is a COLUMN offset; the slice needs the CHARACTER index that column falls
        # on. Slicing at the column itself skipped two characters per wide glyph already
        # scrolled past, so a panned CJK line showed the wrong part of itself. (hscroll=0 —
        # the overwhelmingly common case — needs no conversion at all.)
        lstart=0
        if (( li < total )); then
            (( hscroll )) && { ft_display_index "${FT_TEXTFIELD_LINES_TEXT[$li]}" "$hscroll"; lstart=$FT_RET; }
            window=${FT_TEXTFIELD_LINES_TEXT[$li]:$lstart:$textw}   # ≥1 column per char covers the well
        else window=""; fi
        # Pad to textw DISPLAY COLUMNS. A double-width glyph is one character and two columns,
        # so counting characters over-padded the row and pushed the right border out one cell
        # per wide glyph. The slice above is by characters, so it can also carry more columns
        # than fit when the field scrolls sideways — truncate by width first.
        ft_display_width "$window"
        if (( FT_DISPLAY_WIDTH > textw )); then ft_display_truncate "$window" "$textw"; window=$FT_DISPLAY_TRUNCATED; ft_display_width "$window"; fi
        wchars=${#window}               # characters actually shown — where the padding begins
        pad=$(( textw - FT_DISPLAY_WIDTH )); (( pad < 0 )) && pad=0
        printf -v window '%s%*s' "$window" "$pad" ''
        if (( hassel && li < total )); then     # map the selection onto this row,
            # The window is a contiguous run of this line starting at character `lstart`, and
            # _ft_textfield_rowspan slices by character — so a document index maps by plain
            # subtraction, and a wide glyph is highlighted whole rather than half.
            base=$(( FT_TEXTFIELD_LINES_OFFSET[li] + lstart ))           # clamped to THIS line's own
            vis=$wchars                                                # visible text so a
            vlo=$(( slo - base )); (( vlo < 0 )) && vlo=0; (( vlo > vis )) && vlo=$vis   # multi-line
            vhi=$(( shi - base )); (( vhi < 0 )) && vhi=0; (( vhi > vis )) && vhi=$vis   # span never
            _ft_textfield_rowspan "$sgr" "$selsgr" "$window" "$vlo" "$vhi"; textseg=$FT_RET
        elif (( editing )) && (( li == cr )); then      # caret's row, no selection → BLOCK caret
            ccol=$(( cc - lstart )); (( ccol < 0 )) && ccol=0
            (( ccol > ${#window} - 1 )) && ccol=$(( ${#window} - 1 ))
            # …on the ACTIVE-LINE background when one is themed: the row the caret is on is
            # lifted a shade so you can see where you are in a tall box. It is the row's base,
            # so the caret cell still paints over it exactly as before.
            _ft_textfield_rowspan "${alsgr:-$sgr}" "$caretsgr" "$window" "$ccol" $(( ccol + 1 )); textseg=$FT_RET
        else textseg="$sgr$window"; fi
        if (( FT_TEXTFIELD_WRAP_INDICATOR_WIDTH > 0 )); then           # right rail: ↩ soft-wrap · ¶ hard newline · blank
            if   (( showwrap && li < total )) && (( ${FT_TEXTFIELD_LINES_CONT[li]:-0} == 1 )); then wiseg="$wrapsgr$wrapcell"
            elif (( shownl && li < total ))   && (( ${FT_TEXTFIELD_LINES_HARD[li]:-0} == 1 )); then wiseg="$nlsgr$nlcell"
            else wiseg="$guttersgr$wiblank"; fi
        else wiseg=""; fi
        if (( overflow )); then                 # the border column IS the scrollbar
            if (( r >= thumbStart && r < thumbStart + thumbLen )); then edge="$tsgr$vthumb$FT_COLOR_RESET"
            else edge="$barsgr$FT_GLYPH_VERTICAL$FT_COLOR_RESET"; fi
        else edge="$rbar"; fi
        ft_print_at_width $(( crow0+r )) "$col" "$lbar$lnseg$textseg$wiseg$FT_COLOR_RESET$edge" $(( roww + 1 ))
    done

    if (( overflow )); then
        FT_TEXTFIELD_VBAR[$name]="$gcol $(( crow0 + thumbStart )) $(( crow0 + thumbStart + thumbLen - 1 )) $crow0 $vh $maxv"
    else
        unset "FT_TEXTFIELD_VBAR[$name]"
    fi

    # Horizontal scrollbar along the BOTTOM border when a non-wrapping line spills
    # sideways (the code panel): a heavier thumb overlaid on the border rule, sized
    # and positioned from the h-scroll. Left/Right scroll it; it just shows position.
    if (( hmaxscroll > 0 )); then
        local htrack=$textw
        local hthumbLen=$(( htrack * textw / hmax )); (( hthumbLen < 1 )) && hthumbLen=1
        (( hthumbLen > htrack )) && hthumbLen=$htrack
        local hmaxstart=$(( htrack - hthumbLen )); (( hmaxstart < 0 )) && hmaxstart=0
        local hthumbStart=$(( hmaxstart * hscroll / hmaxscroll ))
        local hxin=$(( col + FT_TEXTFIELD_LEFT_BORDER + FT_TEXTFIELD_LINE_NUMBER_WIDTH ))    # bottom border's text-well start
        # ▀ (upper half) thumb — partner of the vertical ▊; both hug the TOP-LEFT and
        # lean toward the content. Track = the border's ─ (which sits lower, so the
        # thumb never reads as the rule).
        local hthumb hfg hc; _ft_textfield_thumb_glyphs; hthumb=$FT_TEXTFIELD_THUMB_HORIZONTAL
        _ft_textfield_thumbfg "$name"; hfg=$FT_RET     # thumb matches the border's state colour
        # The thumb is a contiguous run on ONE row, so it is ONE write. Painting it cell by
        # cell paid a cursor-address and a paint call per column for a solid bar.
        local hrun=""
        for (( hc=0; hc<hthumbLen; hc++ )); do hrun+="$hthumb"; done
        ft_print_at_width "$bot" $(( hxin + hthumbStart )) "$FT_COLOR_BORDER$hfg$hrun$FT_COLOR_RESET" "$hthumbLen"
        FT_TEXTFIELD_HBAR[$name]="$bot $(( hxin + hthumbStart )) $(( hxin + hthumbStart + hthumbLen - 1 )) $hxin $htrack $hmaxscroll"
    else
        unset "FT_TEXTFIELD_HBAR[$name]"
    fi

    _ft_border_anim_overlay "$name" "$top" "$col" "$outerH" "$cols" "$barsgr"
}

# ── Markdown viewer (markdown=true) ──────────────────────────────────────────
# A read-only rich-text pane: the value is rendered once (memoised) by
# ft_markdown into pre-styled, width-fit lines and shown in a bordered, vertically
# scrollable box. No caret, no wrap-gutter, no line numbers — the arrows scroll.
_FT_TEXTFIELD_MARKDOWN_CACHE_KEY=""
FT_MARKDOWN_TOTAL=0
_ft_textfield_md_render() {            # name → FT_MARKDOWN_LINES[], FT_MARKDOWN_TOTAL (memoised)
    local name=$1 w v
    _ft_textfield_textw "$name"; w=$FT_RET
    ft_resolved_prop "$name" value ""; v=$FT_RET
    local key="$name|$w|$v"
    [[ "$key" == "$_FT_TEXTFIELD_MARKDOWN_CACHE_KEY" ]] && { FT_MARKDOWN_TOTAL=${#FT_MARKDOWN_LINES[@]}; return; }
    _FT_TEXTFIELD_MARKDOWN_CACHE_KEY=$key
    ft_markdown "$v" "$w"
    FT_MARKDOWN_TOTAL=${#FT_MARKDOWN_LINES[@]}
}

# Scroll the rendered document by DELTA visual lines (clamped). vh (visible rows)
# is the field's configured `rows`, which is exactly the box interior.
_ft_textfield_md_scroll() {            # name delta
    local name=$1 delta=$2 vh
    _ft_textfield_md_render "$name"
    _ft_textfield_rows "$name"; vh=$FT_RET
    local maxv=$(( FT_MARKDOWN_TOTAL - vh )); (( maxv < 0 )) && maxv=0
    _ft_tf_voff "$name"; local vs=$(( FT_RET + delta ))
    (( vs > maxv )) && vs=$maxv; (( vs < 0 )) && vs=0
    _ft_tf_voff_set "$name" "$vs"; ft_dirty "$name"; return 0
}

_ft_draw_textfield_md() {       # name — a bordered, scrollable markdown pane
    local name=$1
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local cols=${FT_MEASURED_WIDTH[$name]:-0} outerH=${FT_MEASURED_HEIGHT[$name]:-1}
    (( cols < 3 || outerH < 3 )) && return
    local vh=$(( outerH - 2 )) top=$row bot=$(( row + outerH - 1 )) crow0=$(( row + 1 ))
    local gcol=$(( col + cols - 1 ))
    local focused=0; [[ "${FT_FOCUS:-}" == "$name" ]] && focused=1

    _ft_textfield_wellbase "$name"; _ft_compose_sgr "$name" "$FT_RET"; local sgr=$FT_RET   # well: read-only viewers get the calmer view colour
    _ft_textfield_border_sgr "$name"; local barsgr=$FT_RET   # RO cursor→cyan, editing→gold, focused→azure
    local lbar="$barsgr$FT_GLYPH_VERTICAL" rbar="$barsgr$FT_GLYPH_VERTICAL$FT_COLOR_RESET"

    _ft_textfield_textw "$name"; local textw=$FT_RET
    _ft_textfield_hborder "$top" "$col" "$cols" "$barsgr" "$FT_GLYPH_TOP_LEFT" "$FT_GLYPH_TOP_RIGHT"
    _ft_textfield_hborder "$bot" "$col" "$cols" "$barsgr" "$FT_GLYPH_BOTTOM_LEFT" "$FT_GLYPH_BOTTOM_RIGHT"

    _ft_textfield_md_render "$name"
    local total=$FT_MARKDOWN_TOTAL overflow=0; (( total > vh )) && overflow=1
    _ft_tf_voff "$name"; local vscroll=$FT_RET
    local maxv=$(( total - vh )); (( maxv < 0 )) && maxv=0
    (( vscroll > maxv )) && vscroll=$maxv; (( vscroll < 0 )) && vscroll=0
    _ft_textfield_publish_metrics "$name" "$total" "$vh"   # extent before offset — see the textarea draw
    _ft_tf_voff_set "$name" "$vscroll"

    local r li seg blank; printf -v blank '%*s' "$textw" ''
    for (( r=0; r<vh; r++ )); do
        li=$(( vscroll + r ))
        if (( li < total )); then seg=${FT_MARKDOWN_LINES[$li]}; else seg=$blank; fi
        ft_print_at_width $(( crow0+r )) "$col" "$lbar$sgr$seg$FT_COLOR_RESET" "$cols"
        (( overflow )) || ft_print_at $(( crow0+r )) "$gcol" "$rbar"
    done
    if (( overflow )); then
        local thumbLen=$(( vh * vh / total )); (( thumbLen < 1 )) && thumbLen=1
        local maxstart=$(( vh - thumbLen )); (( maxstart < 0 )) && maxstart=0
        local thumbStart=0; (( maxv > 0 )) && thumbStart=$(( maxstart * vscroll / maxv ))
        # Thumb = ▊ (left three-quarters), the partner of the horizontal bar's ▀ (upper
        # half): both hug the TOP-LEFT, i.e. both lean toward the content they scroll.
        # Top-left is the only corner that works — Unicode gives LEFT blocks a full
        # ⅛…full range (so the vertical can be thickened to visually match a cell that
        # is ~2× taller than wide), while RIGHT/UPPER only offer a half block.
        local vthumb; _ft_textfield_thumb_glyphs; vthumb=$FT_TEXTFIELD_THUMB_VERTICAL
        local tsgr; _ft_textfield_thumbfg "$name"; tsgr="$FT_COLOR_BORDER$FT_RET"   # matches border state colour
        for (( r=0; r<vh; r++ )); do
            if (( r >= thumbStart && r < thumbStart + thumbLen )); then
                ft_print_at $(( crow0+r )) "$gcol" "$tsgr$vthumb$FT_COLOR_RESET"
            else
                ft_print_at $(( crow0+r )) "$gcol" "$barsgr$FT_GLYPH_VERTICAL$FT_COLOR_RESET"
            fi
        done
    fi
}
