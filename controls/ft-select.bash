#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — controls/ft-select.bash
#
#  The "select" prototype — HTML's <select> with ft-option children:
#
#      ft-select name=theme size=3
#          ft-option value=light text="Light"
#          ft-option value=dark  text="Dark"
#          ft-option value=auto  text="Auto"
#      end_ft_select
#
#    size=1 (default)  a DROPDOWN: closed it shows "▾ <selected>". Enter/Space
#                      DROPS IT OPEN, cursor on the current selection; then
#                      Up/Down move the cursor (clamped — no wraparound),
#                      Home/End jump to first/last, Enter/Space commit, Esc
#                      cancels. Up while the cursor is already at the top
#                      COLLAPSES it (a further Up then moves focus away). While
#                      CLOSED the arrows do NOT open it — they move focus like on
#                      any control, so tab/arrow navigation flows through it.
#                      (Esc is bound only while open, so it still quits the app
#                      when the list is closed.)
#    size>1            a LIST BOX size rows tall. Up/Down move the cursor
#                      (clamped; the window scrolls only if the options don't
#                      all fit), Home/End jump, Space selects.
#    multiple=true     (list box) Space toggles; many can be selected;
#                      value = space-separated selected values.
#
#  `value` is kept current automatically; your OK button's _on_activate just reads it.
#  Optional cancelable hook onChange=fn: $this is the select, $1 the newly
#  chosen value; return nonzero to reject the change.
#
#  Depends on ft-core.bash, ft-forms.bash, ft-keymap.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_SELECT_LOADED:-}" ]] && return 0
_FT_SELECT_LOADED=1

# Built once, by the prototype that declares `keymap=select`.
_ft_define_keymap_select() {
    # INACTIVE — Enter steps in. For a dropdown, stepping in IS opening the list; the rung's
    # enter/exit scripts do that (select_runlevel_browsing_enter/_exit below), so `open` and
    # the runlevel can never disagree. Arrows stay with focus navigation out here: a closed
    # select used to change its VALUE when you arrowed past it.
    ft-bindkeys ft_keymap_select ENTER=ft_key_delve SPACE=ft_key_delve
    ft-keymap-cap ft_keymap_select ENTER ft_key_delve "$FT_IMPORTANCE_CRUCIAL" "Choose"

    # BROWSING — inside the list. Every arrow is the select's and none of them eject.
    ft_keymap_once ft_keymap_select_browsing
    ft-bindkeys ft_keymap_select_browsing \
        UP=ft_select_key_up DOWN=ft_select_key_down \
        LEFT=ft_select_key_up RIGHT=ft_select_key_down \
        HOME=ft_select_key_home END=ft_select_key_end \
        PGUP=ft_select_key_pgup PGDN=ft_select_key_pgdn \
        ENTER=ft_select_key_commit SPACE=ft_select_key_commit \
        ESC=ft_key_undelve \
        CTRL+c=ft_select_copy ALT+w=ft_select_copy
    ft-keymap-cap ft_keymap_select_browsing UP   ft_select_key_up     "$FT_IMPORTANCE_CRUCIAL"   "Previous"
    ft-keymap-cap ft_keymap_select_browsing DOWN ft_select_key_down   "$FT_IMPORTANCE_CRUCIAL"   "Next"
    ft-keymap-cap ft_keymap_select_browsing ENTER ft_select_key_commit "$FT_IMPORTANCE_IMPORTANT" "Choose"
    ft-keymap-cap ft_keymap_select_browsing PGUP ft_select_key_pgup   "$FT_IMPORTANCE_NORMAL"    "Page up"
    ft-keymap-cap ft_keymap_select_browsing PGDN ft_select_key_pgdn   "$FT_IMPORTANCE_NORMAL"    "Page down"
    ft-keymap-cap ft_keymap_select_browsing HOME ft_select_key_home   "$FT_IMPORTANCE_NORMAL"    "First"
    ft-keymap-cap ft_keymap_select_browsing END  ft_select_key_end    "$FT_IMPORTANCE_NORMAL"    "Last"
    ft-keymap-cap ft_keymap_select_browsing ESC  ft_key_undelve       "$FT_IMPORTANCE_IMPORTANT" "Leave"
    # Ctrl+C, with Alt+W beside it — see the note in ft-tree.bash: Ctrl+C is the framework's
    # copy key (taken from the tty on purpose, named in Settings), Alt+W is the one that
    # still arrives on a terminal with no keyboard-protocol negotiation.
    ft-bindkeys ft_keymap_select CTRL+c=ft_select_copy ALT+w=ft_select_copy
    ft-keymap-cap ft_keymap_select CTRL+c ft_select_copy "$FT_IMPORTANCE_NORMAL" "Copy option"
}
# Stepping in OPENS a dropdown, stepping out closes it — one fact, in one place, so `open`
# and the runlevel cannot drift apart. A list box (size>1) is always open; there is nothing
# to unfold, and delving just gives it the arrows.
select_runlevel_browsing_enter() {      # name
    ft_resolved_prop "$1" size 1; (( FT_RET > 1 )) && return 0
    ft_resolved_prop "$1" selectedIndex 0; ft-modify "$1" open=true cursor="${FT_RET:-0}"
    return 0
}
select_runlevel_browsing_exit() {       # name
    ft_resolved_prop "$1" size 1; (( FT_RET > 1 )) && return 0
    ft-modify "$1" open=false
    return 0
}
# Copy WHAT YOU ARE LOOKING AT: the option under the cursor while the list is open,
# otherwise the one that is chosen. A multiple-select copies every chosen option, one per
# line, which is the shape you want when pasting a set somewhere else.
ft_select_copy() {              # name
    local n=$1 txt="" o
    _ft_options "$n"
    ft_resolved_prop "$n" multiple false
    if [[ "$FT_RET" == true ]]; then
        for o in "${FT_OPTS[@]}"; do
            _ft_get_raw "$o" selected
            [[ "$FT_RET" == true ]] || continue
            _ft_get_raw "$o" text; txt+="${txt:+$'\n'}$FT_RET"
        done
    else
        local idx
        ft_resolved_prop "$n" open false
        if [[ "$FT_RET" == true ]]; then ft_resolved_prop "$n" cursor 0; else ft_resolved_prop "$n" selectedIndex 0; fi
        idx=${FT_RET:-0}
        (( idx >= 0 )) && [[ -n "${FT_OPTS[$idx]:-}" ]] && { _ft_get_raw "${FT_OPTS[$idx]}" text; txt=$FT_RET; }
    fi
    ft_clip_copy "$txt"; _ft_announce_copy $? itemCopied
    return 0
}
ft_prototype_select() {
    ft_runlevels browsing=ft_keymap_select_browsing
    ft_prop_kind_set scrollbar paint     # true → draw a scrollbar; default is the ⋯ affordance
    ft_prototype extends=ft_control \
        defaults="importance=important" \
        focusable=true \
        mouse=select \
        keymap=select \
        setProp=_ft_select_setprop \
        defaults="display=inline-block size=1 multiple=false selectedIndex=0 open=false cursor=0 scroll=0 showSelected=true scrollbar=false"
    ft_prop_kind_set cursor paint
    ft_prop_kind_set scroll paint
    ft_prop_kind_set selected paint
    ft_prop_kind_set showSelected paint   # false = a NAVIGATION/action list: only the
                                          # cursor is highlighted, no persistent ✓/tint
}

ft-select()     { ft_new select "$@" && FT_NEST_STACK+=("$FT_RET"); }
end_ft_select() { ft-end select; }

select_on_children_complete() { _ft_select_sync "$1"; }
_ft_select_sync() {             # name — value := selection (single or multiple)
    local name=$1
    _ft_options "$name"
    (( ${#FT_OPTS[@]} == 0 )) && return 0
    ft_resolved_prop "$name" multiple false
    if [[ "$FT_RET" == true ]]; then
        local o vals=""
        for o in "${FT_OPTS[@]}"; do
            _ft_get_raw "$o" selected
            if [[ "$FT_RET" == true ]]; then
                _ft_option_value "$o"
                vals+="${vals:+ }$FT_RET"
            fi
        done
        _ft_setprop "$name" value "$vals"
    else
        ft_resolved_prop "$name" selectedIndex 0; local idx=${FT_RET:-0}
        (( idx >= ${#FT_OPTS[@]} )) && idx=0
        _ft_option_value "${FT_OPTS[$idx]}"
        _ft_setprop "$name" value "$FT_RET"
    fi
}

# THE SELECTION IS THE TRUTH, and `value` is the friendly name for the same fact — exactly as in
# ft-multitoggle, for exactly the same reason. `_ft_select_sync` derived `value` from
# `selectedIndex` when the children were complete and nowhere else, so `ft-modify se
# selectedIndex=2` PAINTED the third option while `ft_get se value` still answered the first
# one's: the control told the app one thing and the user another, at the same time. In the DOM
# both directions act — `select.selectedIndex = 2` moves `.value`, and `select.value = "c"`
# moves the selection.
#
# Reconciling here rather than in FT_PROTO_REPROP because _ft_setprop is EVERY route in —
# ft-modify, the DSL, a state restore — and REPROP is only the first of them.
#
# A MULTIPLE SELECT IS NOT THIS SHAPE: its value is the joined list of every option carrying
# selected=true, so `selectedIndex` does not determine it and must not overwrite it.
# Writes go through _ft_stamp_prop, not _ft_setprop: the setter is our caller.
_ft_select_setprop() {          # name prop value
    local name=$1 prop=$2 val=$3 idx i
    case $prop in cursor|selectedIndex|value) : ;; *) return 0 ;; esac
    _ft_options "$name"
    (( ${#FT_OPTS[@]} == 0 )) && return 0     # still being built; children_complete syncs it
    # `cursor` — the option an OPEN dropdown is over — is answered first, because it is bounded
    # whether the select takes one choice or many, and because it belongs to the same rule as
    # the table's: the row you move to has to be a row, and it has to be visible.
    [[ "$prop" == cursor ]] && { _ft_select_place_cursor "$name" "$val"; return 0; }
    ft_resolved_prop "$name" multiple false
    [[ "$FT_RET" == true ]] && return 0
    case $prop in
        selectedIndex)
            (( val >= 0 && val < ${#FT_OPTS[@]} )) || return 0
            _ft_option_value "${FT_OPTS[$val]}"
            _ft_stamp_prop "$name" value "$FT_RET"
            ;;
        value)
            # Setting `value` to what the selection ALREADY answers must not move the selection.
            # _ft_select_sync writes the derived value back through _ft_setprop, so it arrives
            # here; a blind search would then snap the index to the first option sharing that
            # value, silently re-selecting an earlier duplicate.
            ft_resolved_prop "$name" selectedIndex 0; idx=${FT_RET:-0}
            if [[ -n "${FT_OPTS[$idx]:-}" ]]; then
                _ft_option_value "${FT_OPTS[$idx]}"
                [[ "$FT_RET" == "$val" ]] && return 0
            fi
            for i in "${!FT_OPTS[@]}"; do
                _ft_option_value "${FT_OPTS[$i]}"
                [[ "$FT_RET" == "$val" ]] || continue
                _ft_stamp_prop "$name" selectedIndex "$i"
                ft_dirty "$name"
                return 0
            done
            ;;
    esac
    return 0
}

_ft_select_optw() {             # name → FT_RET widest option text width
    _ft_options "$1"
    local o w=0
    for o in "${FT_OPTS[@]}"; do
        _ft_get_raw "$o" text
        ft_display_width "$FT_RET"
        (( FT_DISPLAY_WIDTH > w )) && w=$FT_DISPLAY_WIDTH
    done
    FT_RET=$w
}
_ft_preferred_width_select() {            # name → FT_RET (content columns)
    _ft_select_optw "$1"; local w=$FT_RET
    FT_RET=$(( w + 2 ))          # 1-col marker (▾ or ✓) + space + widest text
}
_ft_height_select() {           # name contentwidth → FT_RET (content rows)
    ft_resolved_prop "$1" size 1; local size=$FT_RET
    (( size <= 1 )) && FT_RET=1 || FT_RET=$size
}

# Where an OPEN dropdown goes, and how tall. Prefer dropping BELOW the closed line; flip
# ABOVE when there isn't room below; and when NEITHER side fits every option, take the
# taller side and SCROLL within it (so a list longer than the screen still works). Sets
# _SEL_VIS (visible rows), _SEL_TOP (absolute first overlay row), _SEL_DIR (up|down).
_SEL_VIS=1; _SEL_TOP=0; _SEL_DIR=down
_ft_select_geom() {             # name
    _ft_options "$1"; local n=${#FT_OPTS[@]}
    local y=${FT_ABSOLUTE_Y[$1]:-0} scr=${FT_ROWS:-24}
    local below=$(( scr - y - 1 )); (( below < 0 )) && below=0
    local above=$y
    if   (( n <= below ));      then _SEL_VIS=$n;     _SEL_DIR=down; _SEL_TOP=$(( y + 1 ))
    elif (( n <= above ));      then _SEL_VIS=$n;     _SEL_DIR=up;   _SEL_TOP=$(( y - n ))
    elif (( below >= above ));  then _SEL_VIS=$below; _SEL_DIR=down; _SEL_TOP=$(( y + 1 ))
    else                             _SEL_VIS=$above; _SEL_DIR=up;   _SEL_TOP=$(( y - above )); fi
    (( _SEL_VIS < 1 )) && _SEL_VIS=1
}

# ── Keyboard ─────────────────────────────────────────────────────────────────
# _ft_select_cursor_to NAME NEWCUR — move the cursor. Nothing but the property write: placing
# it (clamp, and scroll the window only as far as needed to keep it in view) is
# _ft_select_place_cursor, which _ft_setprop calls for every route in. It used to demand an
# ALREADY-CLAMPED index and every caller obliged — except an app writing `cursor=` itself, which
# is the one caller that could not know.
_ft_select_cursor_to() { ft-modify "$1" cursor="$2"; }

# The placement itself. Stamped, not written back through ft-modify: the setter is our caller.
_ft_select_place_cursor() {     # name newcur
    local name=$1 cur=$2
    case $cur in ''|*[!0-9-]*|-*-*|-) return 0 ;; esac
    _ft_options "$name"
    local n=${#FT_OPTS[@]}
    (( n == 0 )) && return 0
    (( cur < 0 )) && cur=0
    (( cur > n - 1 )) && cur=$(( n - 1 ))
    ft_resolved_prop "$name" size 1; local rows=$FT_RET; (( rows < 1 )) && rows=1
    # An OPEN dropdown is only as tall as it can FIT (geometry), not the whole option list —
    # so a long menu scrolls instead of running off the screen.
    ft_resolved_prop "$name" open false; [[ "$FT_RET" == true ]] && { _ft_select_geom "$name"; rows=$_SEL_VIS; }
    local sc=0
    if (( n > rows )); then                 # only a genuinely overflowing list scrolls
        ft_resolved_prop "$name" scroll 0; sc=$FT_RET
        case $sc in ''|*[!0-9-]*|-*-*|-) sc=0 ;; esac
        (( cur < sc )) && sc=$cur
        (( cur >= sc + rows )) && sc=$(( cur - rows + 1 ))
        (( sc > n - rows )) && sc=$(( n - rows ))
        (( sc < 0 )) && sc=0
    fi
    _ft_stamp_prop "$name" cursor "$cur"
    _ft_stamp_prop "$name" scroll "$sc"
    # Moving the cursor just repaints THIS select. Its draw repaints the whole overlay every
    # time, so the old cursor row is overwritten — no residue, and no full-screen flash. (The
    # gap-residue that needs a heavier repaint only happens on CLOSE, in ft_select_close.)
    ft_dirty "$name"
    return 0
}

_ft_select_move() {             # name delta
    local name=$1 delta=$2
    _ft_options "$name"
    local n=${#FT_OPTS[@]}
    (( n == 0 )) && return 0
    ft_resolved_prop "$name" size 1; local size=$FT_RET
    ft_resolved_prop "$name" open false; local open=$FT_RET
    if (( size <= 1 )) && [[ "$open" != true ]]; then
        # A CLOSED dropdown does NOT open on an arrow — the arrows belong to focus
        # navigation. Decline so the key bubbles to the form (ENTER/SPACE opens it).
        FT_KEY_BUBBLE=1; return 1
    fi
    ft_resolved_prop "$name" cursor 0; local cur=$FT_RET
    # An OPEN dropdown: Up while the cursor is ALREADY at the top COLLAPSES it
    # (the list closes but keeps focus; a further Up then bubbles to focus nav —
    # so Up flows out of the control instead of trapping you). Only the Up ARROW
    # collapses (delta -1), not Page-Up; a list box (size>1) never collapses.
    if (( size <= 1 && delta == -1 && cur == 0 )); then
        ft_select_close "$name"
        return 0
    fi
    cur=$(( cur + delta ))
    (( cur < 0 )) && cur=0                   # clamp — no wraparound
    (( cur > n - 1 )) && cur=$(( n - 1 ))    # bottom just sticks
    _ft_select_cursor_to "$name" "$cur"
}
ft_select_key_up()   { _ft_select_move "$1" -1; }
ft_select_key_down() { _ft_select_move "$1" 1; }
ft_select_key_home() { _ft_select_cursor_to "$1" 0; }
ft_select_key_end()  { _ft_options "$1"; _ft_select_cursor_to "$1" $(( ${#FT_OPTS[@]} - 1 )); }
# Page = one visible window's worth (the fit height for a dropdown, `size` for a list box).
_ft_select_page() {             # name → FT_RET (rows per page, ≥1)
    ft_resolved_prop "$1" open false
    if [[ "$FT_RET" == true ]]; then _ft_select_geom "$1"; FT_RET=$_SEL_VIS
    else ft_resolved_prop "$1" size 1; (( FT_RET < 1 )) && FT_RET=1; fi
    (( FT_RET < 1 )) && FT_RET=1
}
ft_select_key_pgup() { _ft_select_page "$1"; _ft_select_move "$1" $(( -FT_RET )); }
ft_select_key_pgdn() { _ft_select_page "$1"; _ft_select_move "$1" "$FT_RET"; }

# Only `selectedIndex` is written, here and on the cancel: `value` follows it in
# _ft_select_setprop now, on every route in, so writing both would be two ways to do one thing —
# and the on_change handler already reads the new value through the property because the
# reconciler ran inside the ft-modify above it.
_ft_select_commit_index() {     # name idx — single-select commit + hook/cancel
    local name=$1 idx=$2
    _ft_options "$name"
    ft_resolved_prop "$name" selectedIndex 0; local old=$FT_RET
    _ft_option_value "${FT_OPTS[$idx]}"; local newval=$FT_RET
    ft-modify "$name" selectedIndex="$idx"
    _ft_hook "$name" on_change "$newval" || ft-modify "$name" selectedIndex="$old"
    return 0
}

# ft_select_open NAME — drop a closed dropdown down, cursor on the current
# selection, Esc bound (only while open) to cancel.
ft_select_open() {
    local name=$1
    ft_resolved_prop "$name" selectedIndex 0; local sel=$FT_RET   # SAVE it: ft-modify below
                                                          # clobbers FT_RET, and the
                                                          # cursor must START on the
                                                          # currently-selected option.
    ft-modify "$name" open=true cursor="$sel" scroll=0
    local km="${FT_KEYMAP[$name]}"
    [[ -z "$km" ]] && { km="${name}__km"; FT_KEYMAP[$name]="$km"; ft-keymap "$km"; }
    ft-keymap-set "$km" ESC ft_select_close
    # The dropdown is an OVERLAY: mark one open and suspend the keycap pulse right away, so
    # the status bar's animation stops repainting over the list (which caused it to glitch).
    (( FT_OVERLAY_DEPTH++ )); declare -F _ft_kcpulse_disarm >/dev/null && _ft_kcpulse_disarm
    FT_OPEN_SELECT=$name       # so a mouse click in the overlay can be routed back to us
    _ft_select_cursor_to "$name" "$sel"
}
# ── Mouse ────────────────────────────────────────────────────────────────────
# Click behaviour: a CLOSED dropdown opens; clicking its (open) line closes it; a
# list box selects the clicked row. Clicking an OPTION in the open OVERLAY is
# routed here from the mouse dispatch (the overlay is outside the control's box)
# via _ft_select_overlay_at → _ft_select_commit_index.
FT_OPEN_SELECT=""
_ft_mouse_select() {            # name action relx rely
    local name=$1 act=$2 rely=$4
    [[ "$act" == release ]] || return 0        # act on click-up, like a button
    ft_resolved_prop "$name" size 1; local size=$FT_RET
    if (( size > 1 )); then                    # list box: pick the clicked row
        ft_resolved_prop "$name" scroll 0; local sc=$FT_RET
        local idx=$(( sc + rely ))
        _ft_options "$name"
        (( idx >= 0 && idx < ${#FT_OPTS[@]} )) && { _ft_select_cursor_to "$name" "$idx"; ft_select_key_commit "$name"; }
        return 0
    fi
    ft_resolved_prop "$name" open false
    if [[ "$FT_RET" == true ]]; then ft_select_close "$name"   # click the open line → close
    else ft_select_open "$name"; fi                            # click the closed line → open
    return 0
}
# _ft_select_overlay_at X Y → FT_RET = the option index the open dropdown draws at that
# screen cell, or "" if (x,y) is not inside the open overlay. Called by the mouse dispatch
# so a click on an option (which lands OUTSIDE the select's own box) still selects it.
_ft_select_overlay_at() {       # x y → FT_RET
    FT_RET=""
    local os=${FT_OPEN_SELECT:-}; [[ -z "$os" || -z "${FT_TYPE[$os]:-}" ]] && return
    local ox=${FT_ABSOLUTE_X[$os]:-0} ow=${FT_MEASURED_WIDTH[$os]:-0}
    (( $1 >= ox && $1 < ox + ow )) || return
    _ft_select_geom "$os"
    (( $2 >= _SEL_TOP && $2 < _SEL_TOP + _SEL_VIS )) || return
    ft_resolved_prop "$os" scroll 0; local sc=$FT_RET
    local idx=$(( sc + $2 - _SEL_TOP ))
    _ft_options "$os"
    (( idx >= 0 && idx < ${#FT_OPTS[@]} )) && FT_RET=$idx
}

ft_select_key_commit() {        # name — open/commit dropdown, or toggle in a listbox
    local name=$1
    _ft_options "$name"
    local n=${#FT_OPTS[@]}
    (( n == 0 )) && return 0
    ft_resolved_prop "$name" size 1; local size=$FT_RET
    if (( size <= 1 )); then
        ft_resolved_prop "$name" open false
        if [[ "$FT_RET" != true ]]; then
            ft_select_open "$name"
        else
            ft_resolved_prop "$name" cursor 0
            _ft_select_commit_index "$name" "$FT_RET"
            ft_select_close "$name"
        fi
        return 0
    fi
    # list box: SPACE/ENTER acts on the cursor row
    ft_resolved_prop "$name" cursor 0; local cur=$FT_RET
    ft_resolved_prop "$name" multiple false
    if [[ "$FT_RET" == true ]]; then
        local opt=${FT_OPTS[$cur]}
        _ft_get_raw "$opt" selected
        [[ "$FT_RET" == true ]] && _ft_setprop "$opt" selected false || _ft_setprop "$opt" selected true
        _ft_select_sync "$name"
        ft_dirty "$name"
    else
        _ft_select_commit_index "$name" "$cur"
        # An ACTION list (a single-select listbox used like a menu — e.g. a file
        # listing) fires on_activate with the chosen row's value, so Enter can DO
        # something (open a folder) rather than only record a selection.
        _ft_option_value "${FT_OPTS[$cur]}"
        _ft_hook "$name" on_activate "$FT_RET"
    fi
    return 0
}

ft_select_close() {             # name — close the dropdown, repaint what it covered
    local name=$1
    # The overlay dropped BELOW the closed line, covering cells that belong to
    # other controls AND to gaps between them. ERASE that exact rectangle to the
    # form background first (so gap residue is cleared), then repaint the form's
    # controls on top. No full-screen clear -> no flash.
    ft_resolved_prop "$name" open false; local was=$FT_RET      # was it actually open?
    _ft_options "$name"; local n=${#FT_OPTS[@]}
    local col=${FT_ABSOLUTE_X[$name]:-0} cols=${FT_MEASURED_WIDTH[$name]:-0}
    _ft_select_geom "$name"; local etop=$_SEL_TOP evis=$_SEL_VIS   # the exact overlay rectangle
    ft-modify "$name" open=false
    # Balance the overlay depth we took on open, so the keycap pulse resumes once the last
    # overlay closes. Guarded by `was` so a redundant close can't underflow it.
    [[ "$was" == true ]] && (( FT_OVERLAY_DEPTH > 0 )) && (( FT_OVERLAY_DEPTH-- ))
    [[ "${FT_OPEN_SELECT:-}" == "$name" ]] && FT_OPEN_SELECT=""
    [[ -n "${FT_KEYMAP[$name]:-}" ]] && ft-keymap-unset "${FT_KEYMAP[$name]}" ESC
    _ft_enclosing_form_of "$name"; local form=${FT_RET:-$FT_ROOT}
    (( n > 0 )) && _ft_erase_rect "$col" "$etop" "$cols" "$evis" "$form"
    ft_dirty_subtree "$form"
    return 0
}

# Blur hook — the focus machinery calls _ft_blur_<type> when a control loses focus.
# A dropdown that is OPEN must CLOSE when focus leaves it (Tab or Left/Right bubbling to
# the form's nav), or its overlay stays painted over whatever is now focused. The control
# grabs keys while focused and decides when to pass focus on; leaving is exactly when it
# also has to "close shop". (An inline list box has no overlay, so this is a no-op there.)
_ft_blur_select() {             # name losing focus
    ft_resolved_prop "$1" open false
    [[ "$FT_RET" == true ]] && ft_select_close "$1"
}

# ── Draw ─────────────────────────────────────────────────────────────────────
_ft_draw_select() {                      # name
    local name=$1
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local cols=${FT_MEASURED_WIDTH[$name]:-0} rows=${FT_MEASURED_HEIGHT[$name]:-0}
    (( cols < 1 )) && return
    _ft_options "$name"
    local n=${#FT_OPTS[@]}

    # Idle rows sit in the input-well colour so the control reads as a control
    # (both the dropdown's closed line and every list-box row), distinct from
    # the surrounding body. The whole closed dropdown flips to the focus accent
    # when focused; a list box keeps the well and shows focus on the CURSOR row.
    local well; _ft_compose_sgr "$name" "$FT_COLOR_INPUT"; well=$FT_RET   # cascaded bg/fg/weight
    local base=$well
    [[ "${FT_FOCUS:-}" == "$name" ]] && { _ft_dim_if_disabled "$name" "$FT_COLOR_SEL"; base=$FT_RET; }
    local mark=$'▾'; (( FT_USE_UTF8 )) || mark="v"

    ft_resolved_prop "$name" size 1; local size=$FT_RET
    ft_resolved_prop "$name" selectedIndex 0; local sel=$FT_RET
    ft_resolved_prop "$name" cursor 0; local cur=$FT_RET
    ft_resolved_prop "$name" scroll 0; local sc=$FT_RET
    ft_resolved_prop "$name" multiple false; local multi=$FT_RET
    ft_resolved_prop "$name" showSelected true; local showsel=$FT_RET
    ft_resolved_prop "$name" open false; local open=$FT_RET

    if (( size <= 1 )); then
        local seltext=""
        (( n > 0 )) && { _ft_get_raw "${FT_OPTS[$sel]:-}" text; seltext=$FT_RET; }
        # Closed + focused → the whole line wears the FOCUS colour (this control
        # has focus). But once it's OPEN, focus conceptually moves INTO the list,
        # so the closed line drops to the SELECTED colour -- the same colour the
        # chosen option shows in the menu below, so "selected" reads identically
        # in both places. The only focus-coloured thing while open is the cursor.
        local closed=$base
        [[ "$open" == true ]] && { _ft_dim_if_disabled "$name" "$FT_COLOR_SELECTED"; closed=$FT_RET; }
        ft_fit "$mark $seltext" "$cols"
        ft_print_at "$row" "$col" "$closed$FT_FIT$FT_COLOR_RESET"
        if [[ "$open" == true ]]; then
            # The overlay escapes this control's small box on purpose —
            # widen the clip to the enclosing form (still never off-screen).
            local s0=$FT_CLIP_R0 s1=$FT_CLIP_R1 s2=$FT_CLIP_C0 s3=$FT_CLIP_C1
            _ft_enclosing_form_of "$name"; local form=${FT_RET:-$FT_ROOT}
            if [[ -n "$form" ]]; then
                FT_CLIP_R0=${FT_ABSOLUTE_Y[$form]:-0}
                FT_CLIP_R1=$(( ${FT_ABSOLUTE_Y[$form]:-0} + ${FT_MEASURED_HEIGHT[$form]:-0} - 1 ))
                FT_CLIP_C0=${FT_ABSOLUTE_X[$form]:-0}
                FT_CLIP_C1=$(( ${FT_ABSOLUTE_X[$form]:-0} + ${FT_MEASURED_WIDTH[$form]:-0} - 1 ))
            fi
            _ft_select_geom "$name"                      # fit height + open direction + top row
            local vis=$_SEL_VIS top=$_SEL_TOP
            # keep the cursor inside the visible window (defensive — cursor moves maintain this)
            (( sc > n - vis )) && sc=$(( n - vis )); (( sc < 0 )) && sc=0
            (( cur < sc )) && sc=$cur
            (( cur >= sc + vis )) && sc=$(( cur - vis + 1 ))
            (( sc < 0 )) && sc=0
            local moreAbove=0 moreBelow=0
            (( sc > 0 ))        && moreAbove=1
            (( sc + vis < n ))  && moreBelow=1
            ft_resolved_prop "$name" scrollbar false; local sbon=0
            [[ "$FT_RET" == true ]] && (( n > vis )) && sbon=1     # scrollbar is OPT-IN (default: ⋯)
            local optw=$cols; (( sbon )) && optw=$(( cols - 1 ))
            local sbcol=$(( col + cols - 1 )) tbtop=0 tbbot=-1 tbh
            if (( sbon )); then
                tbh=$(( (vis*vis + n - 1) / n )); (( tbh < 1 )) && tbh=1
                tbtop=$(( sc * (vis - tbh) / (n - vis) )); (( tbtop < 0 )) && tbtop=0
                tbbot=$(( tbtop + tbh - 1 )); (( tbbot > vis-1 )) && tbbot=$((vis-1))
            fi
            # Two independent signals: the SELECTED option keeps a ✓ + selection colour;
            # the CURSOR (what Enter picks) shows the focus accent. A boundary row with
            # hidden content beyond it — and no cursor on it — shows "⋯" (the default, no-
            # scrollbar affordance) so you can tell there's more, above and/or below.
            local ell=$'⋯'; (( FT_USE_UTF8 )) || ell="..."
            local checkmark=$'✓'; (( FT_USE_UTF8 )) || checkmark="*"
            local j i osgr t mk txt
            for (( j=0; j<vis; j++ )); do
                i=$(( sc + j ))
                if   (( sbon == 0 && j == 0       && moreAbove && i != cur )); then txt=" $ell"; osgr=$FT_COLOR_BUTTON
                elif (( sbon == 0 && j == vis - 1 && moreBelow && i != cur )); then txt=" $ell"; osgr=$FT_COLOR_BUTTON
                else
                    _ft_get_raw "${FT_OPTS[$i]}" text; t=$FT_RET
                    (( i == sel )) && mk=$checkmark || mk=" "
                    if   (( i == cur )); then osgr=$FT_COLOR_FOCUS
                    elif (( i == sel )); then osgr=$FT_COLOR_SELECTED
                    else osgr=$FT_COLOR_BUTTON; fi
                    txt="$mk $t"
                fi
                ft_fit "$txt" "$optw"
                ft_print_at $(( top + j )) "$col" "$osgr$FT_FIT$FT_COLOR_RESET"
                if (( sbon )); then
                    local sg
                    if (( FT_USE_UTF8 )); then (( j >= tbtop && j <= tbbot )) && sg=$'█' || sg=$'░'
                    else                       (( j >= tbtop && j <= tbbot )) && sg="#"   || sg=":"; fi
                    ft_print_at $(( top + j )) "$sbcol" "$osgr$sg$FT_COLOR_RESET"
                fi
            done
            FT_CLIP_R0=$s0; FT_CLIP_R1=$s1; FT_CLIP_C0=$s2; FT_CLIP_C1=$s3
        fi
        return
    fi

    # List box: `rows` visible option rows, window scrolled by `scroll`.
    # Three independent, themeable signals: a ✓ marker + FT_COLOR_SELECTED tint
    # for SELECTED rows, and the FT_COLOR_FOCUS accent on the CURSOR row (only
    # while this control has focus — that row is what Space will act on).
    local checkmark=$'✓'; (( FT_USE_UTF8 )) || checkmark="*"
    local i r=0 t osgr issel
    for (( i=sc; i<n && r<rows; i++, r++ )); do
        _ft_get_raw "${FT_OPTS[$i]}" text; t=$FT_RET
        if [[ "$multi" == true ]]; then
            _ft_get_raw "${FT_OPTS[$i]}" selected
            [[ "$FT_RET" == true ]] && issel=1 || issel=0
        else
            (( i == sel )) && issel=1 || issel=0
        fi
        local markglyph=" "
        osgr=$well                              # the input-well background
        # A navigation list (showSelected=false) never marks the committed row — the
        # persistent ✓/tint only makes sense when a selection is a lasting choice.
        if [[ "$showsel" != false ]]; then
            (( issel )) && markglyph=$checkmark
            (( issel )) && { _ft_dim_if_disabled "$name" "$FT_COLOR_SELECTED"; osgr=$FT_RET; }
        fi
        [[ "${FT_FOCUS:-}" == "$name" ]] && (( i == cur )) && { _ft_dim_if_disabled "$name" "$FT_COLOR_FOCUS"; osgr=$FT_RET; }
        ft_fit "$markglyph $t" "$cols"
        ft_print_at $(( row + r )) "$col" "$osgr$FT_FIT$FT_COLOR_RESET"
    done
    for (( ; r<rows; r++ )); do             # pad short lists with the well too
        ft_fit "" "$cols"
        ft_print_at $(( row + r )) "$col" "$well$FT_FIT$FT_COLOR_RESET"
    done
}
