#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — ft-help.bash   (F1 help system)
#
#  Every control carries help text. F1 (unless a control rebinds it) opens a
#  modal window with one TAB per help entry, each a read-only, scrollable,
#  selectable text viewer. Help comes from three layers, most-specific first:
#     1. instance property    helpText (→ entry 0), helpText1, helpText2, …
#     2. prototype default    FT_PROTO_HELP[<type>:<n>]  (set by a control prototype)
#     3. the library basics   (entry 0 fallback for any control)
#  The FIRST LINE of each entry is its tab title; the rest is the body.
#
#  Convention: entry 0 is the control prototype's own help. A derived prototype or
#  an app instance adds entries 1, 2, …  (Text fields reserve 0=vi, 1=emacs, so
#  their extensions start at 2 — see the prototype defaults below.)
#
#  Depends on ft-core, ft-forms, ft-tabs, ft-frame, ft-textfield.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_HELP_LOADED:-}" ]] && return 0
_FT_HELP_LOADED=1

declare -A FT_PROTO_HELP=()     # [<type>:<index>] = "Title<newline>body…"
declare -A FT_PROTO_HELPLABEL=() FT_PROTO_HELPACCEL=() # [<type>:<index>] tab label / accessKey
# helpText<n> = a tab's body, helpLabel<n> = its header, helpAccel<n> = its accessKey.
# Register 0..9 (only registered props are stored by ft-modify / the DSL).
for _fh in "" 1 2 3 4 5 6 7 8 9; do
    ft_prop_kind_set "helpText$_fh"  paint
    ft_prop_kind_set "helpLabel$_fh" paint
    ft_prop_kind_set "helpAccel$_fh" paint
done; unset _fh

# The library-wide fallback for entry 0 (any control with no prototype help). The
# FIRST LINE is the tab title when no helpLabel is set.
_FT_HELP_BASE="Basics

**Tab** / **Shift+Tab** move between controls; the **arrow keys** move
*within* one and off its edges to the next. **Enter** or **Space**
activate buttons, checkboxes and menu items.

**Mouse:** click to focus, drag to select, wheel to scroll.
**F1** opens help on the focused control; **Esc** closes this window."

# Text fields: entry 0 = the Emacs/readline keys IN USE (shown first, since emacs
# is the default mode); entry 1 = Vi (reserved). Apps/extensions add from 2 up.
FT_PROTO_HELPLABEL[textfield:0]="Emacs"; FT_PROTO_HELPACCEL[textfield:0]="E"
FT_PROTO_HELP[textfield:0]="**Emacs / readline** keys — the default mode.

| Keys | Action |
|------|--------|
| Left / Right | move by character |
| Alt+Left / Right | move by word |
| Home / End | start / end of line |
| Ctrl+Home / End | start / end of document |
| Up / Down | line (off the ends: prev/next control) |
| Shift + motion | select |
| Alt+W / Ctrl+W | copy / cut (or kill word) |
| Ctrl+Y / Alt+Y | yank / yank-pop |
| Ctrl+K / Ctrl+U | kill to end / start of line |
| Insert | toggle insert / overwrite |

Paste is your terminal's own paste (**Ctrl+Shift+V**). A read-only
field allows move / select / copy but no edits."
FT_PROTO_HELPLABEL[textfield:1]="Vi"; FT_PROTO_HELPACCEL[textfield:1]="V"
FT_PROTO_HELP[textfield:1]="Vi-style modal editing is coming (\`keymode=vi\`).

Text fields are in **Emacs**/readline mode by default — see the Emacs tab."

# Per-control help (entry 0 for each type) so F1 is about the control you're ON,
# not a generic page. Apps still add their own entries 1,2,… on any instance via
# helpText<n>/helpLabel<n>/helpAccel<n>. Keys below match each prototype's keymap.
FT_PROTO_HELP[button:0]="**Button** — runs an action.

**Enter** or **Space** activates it. If it shows an underlined letter,
that **accelerator** activates it from anywhere on the form."
FT_PROTO_HELP[radio:0]="**Radio** — pick one of a group.

**Space** or **Enter** selects this option (clearing the others in its
group). **Tab** / arrows move between the group's buttons."
# A checkbox IS a two-state multitoggle (\`[ ]\` / \`[x]\`), so both share this.
FT_PROTO_HELP[multitoggle:0]="**Toggle** — steps through a set of values; a
**checkbox** is just the two-state case (\`[ ]\` / \`[x]\`).

**Space** or **Enter** advances to the next value (and back to the first
after the last); the accelerator does the same."
FT_PROTO_HELP[select:0]="**Select** — a drop-down / list picker.

| Keys | Action |
|------|--------|
| Down / Enter / Space | open the list |
| Up / Down | move the highlight |
| Enter | choose the highlighted item |
| Home / End | first / last item |
| Esc | close without changing |"
FT_PROTO_HELP[slider:0]="**Slider** — pick a number on a range.

| Keys | Action |
|------|--------|
| Left / Right (or Up / Down) | step by one |
| PgUp / PgDn | step by a larger amount |
| Home / End | jump to the minimum / maximum |"
FT_PROTO_HELP[tree:0]="**Tree** — a collapsible hierarchy.

| Keys | Action |
|------|--------|
| Up / Down | move to the previous / next row |
| Right | expand a branch (or step in) |
| Left | collapse (or step out to the parent) |
| Enter / Space | toggle a branch · activate a leaf |
| Home / End | first / last row |
| PgUp / PgDn | move by a page |"
FT_PROTO_HELP[table:0]="**Table** — a scrollable grid.

| Keys | Action |
|------|--------|
| Up / Down | move by a row |
| PgUp / PgDn | move by a page |
| Home / End | jump to the first / last row |"
FT_PROTO_HELP[tabs:0]="**Tabs** — switch between panels.

| Keys | Action |
|------|--------|
| Left / Right | previous / next tab |
| Home / End | first / last tab |
| accelerator | the underlined letter jumps straight to a tab |

**Tab** moves focus into the active panel's contents."
# Clean one-word tab titles for the per-control help (the body keeps its heading).
FT_PROTO_HELPLABEL[button:0]="Button"
FT_PROTO_HELPLABEL[radio:0]="Radio"
FT_PROTO_HELPLABEL[multitoggle:0]="Toggle"
# A checkbox is now its own type but IS a two-state multitoggle — share its Toggle help.
FT_PROTO_HELP[checkbox:0]=${FT_PROTO_HELP[multitoggle:0]}
FT_PROTO_HELPLABEL[checkbox:0]=${FT_PROTO_HELPLABEL[multitoggle:0]}
FT_PROTO_HELPLABEL[select:0]="Select"
FT_PROTO_HELPLABEL[slider:0]="Slider"
FT_PROTO_HELPLABEL[tree:0]="Tree"
FT_PROTO_HELPLABEL[table:0]="Table"
FT_PROTO_HELPLABEL[tabs:0]="Tabs"

# Gather a control's help into parallel FT_HELP_TITLE[] / FT_HELP[] / FT_HELP_ACCEL[]
# arrays (one slot per BUILT tab). A missing helpText entry is SPARSE — skipped,
# with no tab and no slot — but helpLabel/helpAccel stay aligned by using the
# same index i for all three.
_ft_help_texts() {              # name
    local name=$1
    local t=${FT_TYPE[$name]:-} i txt title body lbl acc prop
    FT_HELP_TITLE=(); FT_HELP=(); FT_HELP_ACCEL=()
    for (( i=0; i<=9; i++ )); do
        prop=helpText; (( i > 0 )) && prop=helpText$i
        _ft_get_raw "$name" "$prop"; txt=$FT_RET
        [[ -z "$txt" ]] && txt=${FT_PROTO_HELP[$t:$i]:-}
        (( i == 0 )) && [[ -z "$txt" ]] && txt=$_FT_HELP_BASE
        [[ -z "$txt" ]] && continue                       # sparse → no tab for this index
        prop=helpLabel; (( i > 0 )) && prop=helpLabel$i
        _ft_get_raw "$name" "$prop"; lbl=$FT_RET
        [[ -z "$lbl" ]] && lbl=${FT_PROTO_HELPLABEL[$t:$i]:-}
        if [[ -n "$lbl" ]]; then title=$lbl; body=$txt     # explicit label → full body
        else                                               # else the first line IS the title
            title=${txt%%$'\n'*}
            if [[ "$txt" == *$'\n'* ]]; then body=${txt#*$'\n'}; body=${body#$'\n'}; else body=""; fi
        fi
        prop=helpAccel; (( i > 0 )) && prop=helpAccel$i
        _ft_get_raw "$name" "$prop"; acc=$FT_RET
        [[ -z "$acc" ]] && acc=${FT_PROTO_HELPACCEL[$t:$i]:-}
        FT_HELP_TITLE+=("$title"); FT_HELP+=("$body"); FT_HELP_ACCEL+=("$acc")
    done
}

# About — its own little modal world, so an app can make it anything: a splash,
# ASCII art, credits, a version table. Two override points:
#   • FT_HELP_ABOUT      — markdown shown by the DEFAULT About box (set to taste)
#   • FT_HELP_ABOUT_FN   — a function name; if defined, the About button calls IT
#                          instead of the default box. It owns the screen fully
#                          (push/pop a modal, animate, whatever) and returns when
#                          done. This is where a programmer wires a custom About.
FT_HELP_ABOUT="# Fruity TUI

A pure-Bash **retained-mode** terminal UI toolkit — no ncurses, no
tput, just ANSI and one flushed frame buffer.

Press **Esc** or **Enter** to return."
FT_HELP_ABOUT_FN=""

# Button hooks (live only while the help modal is up). Quit closes the window;
# About opens the About box (or the app's FT_HELP_ABOUT_FN) on top of it. (The
# Windows-Terminal key fix moved to the Settings modal — see ft-settings.bash.)
_FT_HELP_QUIT=0
__helpquit_on_activate()  { _FT_HELP_QUIT=1; }
__helpabout_on_activate() { ft_help_about; }

# ft_help_about — open the About box. Delegates to the app's FT_HELP_ABOUT_FN if
# one is defined, else runs the built-in modal. Safe to call from anywhere.
ft_help_about() {
    if [[ -n "$FT_HELP_ABOUT_FN" ]] && declare -F "$FT_HELP_ABOUT_FN" >/dev/null; then
        "$FT_HELP_ABOUT_FN"
    else
        _ft_help_about_run
    fi
}

# The default About box: a small centered modal showing FT_HELP_ABOUT as markdown.
# Any key (Esc / Enter / Space / click) dismisses it. Stacks cleanly on top of the
# help window via the modal context stack.
_ft_help_about_run() {
    ft_modal_push
    local ww=$(( FT_COLS - 12 )); (( ww > 54 )) && ww=54; (( ww < 22 )) && ww=22
    local wh=$(( FT_ROWS - 6 )); (( wh > 14 )) && wh=14; (( wh < 7 )) && wh=7
    local fw=$(( ww - 4 )) fr=$(( wh - 4 )); (( fr < 3 )) && fr=3
    ft-form name=__about width="$FT_COLS" height="$FT_ROWS" \
            display=flex justifyContent=center alignItems=center
        ft-frame name=__aboutwin title=" About " borderStyle=rounded \
                 display=flex flexDirection=column padding=1 width="$ww" height="$wh"
            ft-textfield name=__abouttext readOnly=true markdown=true \
                         size="$fw" rows="$fr" value="$FT_HELP_ABOUT"
        end_ft_frame
    end_ft_form
    FT_ROOT=__about; FT_COALESCING=0
    ft_layout __about; ft_focus __abouttext
    ft_repaint_all __about

    local rc
    while true; do
        ft_next_event; rc=$?
        if (( rc == 2 )); then
            FT_WINCH=0; ft_term_size
            _ft_setprop __about width "$FT_COLS"; _ft_setprop __about height "$FT_ROWS"
            ft_layout __about; ft_repaint_all __about; continue
        fi
        (( rc != 0 )) && break
        # Any key or click dismisses; arrows still scroll the text first, though.
        case "$FT_EVENT_TOKEN" in
            UP|DOWN|PGUP|PGDN|HOME|END|MOUSE)
                if [[ "$FT_EVENT_TOKEN" == MOUSE ]]; then _ft_dispatch_mouse; else ft_dispatch_event "$FT_EVENT_TOKEN"; fi
                ft_redraw_dirty ;;
            *) break ;;
        esac
    done

    ft_remove __about
    ft_modal_pop
    ft_repaint_all "$FT_ROOT"    # repaint whatever was underneath
}

# ft_help — open the help window for the focused control (or the root).
ft_help() {
    local target=${FT_FOCUS:-$FT_ROOT}
    [[ -z "$target" || -z "${FT_TYPE[$target]:-}" ]] && return 0
    _ft_help_texts "$target"
    (( ${#FT_HELP_TITLE[@]} == 0 )) && return 0
    _ft_help_run
    return 0
}

# Build the __help modal form from the gathered FT_HELP_* arrays. Split out from
# the run loop so it can be exercised without a live tty. Adds an always-present
# "About" tab (last) and a Quit/About button row at the bottom.
_ft_help_build() {
    local ww=$(( FT_COLS - 8 )); (( ww > 72 )) && ww=72; (( ww < 24 )) && ww=24
    local wh=$(( FT_ROWS - 4 )); (( wh > 22 )) && wh=22; (( wh < 8 )) && wh=8
    local tabw=$(( ww - 4 )) tabh=$(( wh - 6 )) fieldrows=$(( wh - 10 ))
    (( tabh < 5 )) && tabh=5
    (( fieldrows < 3 )) && fieldrows=3
    local i n=${#FT_HELP_TITLE[@]}
    _FT_HELP_QUIT=0
    ft-form name=__help width="$FT_COLS" height="$FT_ROWS" \
            display=flex justifyContent=center alignItems=center
        ft-frame name=__helpwin title=" Help — Esc to close " borderStyle=double \
                 display=flex flexDirection=column gap=1 padding=1 width="$ww" height="$wh"
            ft-tabs name=__helptabs width="$tabw" height="$tabh"
                for (( i=0; i<n; i++ )); do
                    ft-tab title="${FT_HELP_TITLE[$i]}" accessKey="${FT_HELP_ACCEL[$i]}"
                        ft-textfield name="__helptext$i" readOnly=true markdown=true \
                                     size=$(( tabw - 4 )) rows="$fieldrows" \
                                     value="${FT_HELP[$i]}"
                    end_ft_tab
                done
            end_ft_tabs
            ft-div name=__helpbtns display=flex gap=2 justifyContent=center width="$tabw"
                ft-button name=__helpabout accessKey=A About onActivate=__helpabout_on_activate
                ft-button name=__helpquit  accessKey=Q Quit onActivate=__helpquit_on_activate
            end_ft_div
        end_ft_frame
    end_ft_form
}

# Build the modal + run a nested event loop until Esc/F1/Quit, then restore.
_ft_help_run() {
    ft_modal_push
    _ft_help_build

    FT_ROOT=__help; FT_COALESCING=0
    ft_layout __help; ft_focus __helptabs
    ft_repaint_all __help

    local rc tok
    while true; do
        ft_next_event; rc=$?
        if (( rc == 2 )); then
            FT_WINCH=0; ft_term_size
            _ft_setprop __help width "$FT_COLS"; _ft_setprop __help height "$FT_ROWS"
            ft_layout __help; ft_repaint_all __help; continue
        fi
        (( rc != 0 )) && break
        [[ "$FT_EVENT_TOKEN" == ESC || "$FT_EVENT_TOKEN" == F1 ]] && break
        # Tab accelerators (helpAccel) route through the normal form accessKey path —
        # __help's keymap binds each letter to _ft_accel_dispatch, which switches
        # to the tab. So a plain ft_dispatch_event handles them.
        if [[ "$FT_EVENT_TOKEN" == MOUSE ]]; then _ft_dispatch_mouse
        else tok=$FT_EVENT_TOKEN; [[ "$FT_EVENT_TOKEN" == CHAR ]] && tok=$FT_EVENT_CHAR; ft_dispatch_event "$tok"; fi
        (( _FT_HELP_QUIT )) && break               # Quit button
        ft_redraw_dirty
    done

    ft_remove __help
    ft_modal_pop                                      # restore root/focus/ring/coalescing
    ft_repaint_all "$FT_ROOT"
}
