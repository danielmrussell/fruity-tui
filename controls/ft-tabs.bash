#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — controls/ft-tabs.bash
#
#  A tabbed pane. Folder-style tab headers stick up above a bordered content
#  box; the ACTIVE tab's bottom edge opens into the box (its border merges with
#  the pane), exactly like a notebook / browser tab:
#
#      ╭─────────╮ ╭────────╮
#      │ Account │ │ Tuning │
#     ╭┴─────────┴─┴────────┴──────────────╮
#     │  ... the active tab's body ...      │
#     ╰─────────────────────────────────────╯
#
#      ft-tabs name=picker activeTab=0
#          ft-tab title="Account"  ... controls ...  end_ft_tab
#          ft-tab title="Tuning"   ... controls ...  end_ft_tab
#      end_ft_tabs
#
#  Focusable: ←/→ (or Home/End) switch the active tab. Only the active ft-tab is
#  displayed, so Tab flows into its controls (hidden tabs' controls are skipped).
#  Only the tab LABEL text is coloured for active/inactive — no background bar.
#
#  Layout: paddingTop=3 reserves the two tab-header rows + the content box's top
#  edge; paddingLeft/Right/Bottom=1 inset the body inside the box. The control
#  paints the tabs and the box itself in that margin.
#
#  Depends on ft-core.bash and ft-forms.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_TABS_LOADED:-}" ]] && return 0
_FT_TABS_LOADED=1

# Built once, by the prototype that declares `keymap=tabs`.
_ft_define_keymap_tabs() {
    # INACTIVE — Enter steps into the strip. Left/Right are not bound here: arrowing ACROSS
    # a form must not switch tabs under you, which reflows the whole page.
    ft-bindkeys ft_keymap_tabs ENTER=ft_key_delve
    ft-keymap-cap ft_keymap_tabs ENTER ft_key_delve crucial "Switch tabs"

    # BROWSING — inside the strip, every arrow is the strip's. Labelled, so they reach the
    # derived legend: switching tabs IS what a tab strip is for, and unlabelled these bound
    # fine but the bar showed nothing but "Locate", leaving it undiscoverable.
    ft_keymap_once ft_keymap_tabs_browsing
    ft-bindkeys ft_keymap_tabs_browsing \
        UP=ft_tabs_prev DOWN=ft_tabs_next ESC=ft_key_undelve
    ft-keymap-cap ft_keymap_tabs_browsing LEFT  ft_tabs_prev   crucial   "Previous tab"
    ft-keymap-cap ft_keymap_tabs_browsing RIGHT ft_tabs_next   crucial   "Next tab"
    ft-keymap-cap ft_keymap_tabs_browsing HOME  ft_tabs_first  normal    "First tab"
    ft-keymap-cap ft_keymap_tabs_browsing END   ft_tabs_last   normal    "Last tab"
    ft-keymap-cap ft_keymap_tabs_browsing ESC   ft_key_undelve important "Leave"
}
ft_prototype_tabs() {
    ft_runlevels browsing=ft_keymap_tabs_browsing
    # The tabs fill their whole background, so a repaint of the tabs NODE ALONE (a focus
    # change dirties only the focused control) would erase every child — fillsBackground
    # makes the engine dirty the whole SUBTREE instead. See the note by _ft_draw_tabs.
    ft_prototype extends=ft_control \
        focusable=true \
        fillsBackground=true \
        keymap=tabs \
        setProp=_ft_tabs_setprop \
        defaults="display=flex flexDirection=column activeTab=0 borderRadius=1 paddingTop=3 paddingLeft=1 paddingRight=1 paddingBottom=1"
    ft_prop_kind_set activeTab layout    # switching reflows the subtree
    # `activeTab` IS the state, so writing it must switch the tab. Reflowing the subtree is not
    # enough: which body is shown is decided by `display` on each body, and only
    # _ft_tabs_show_only writes those — so `ft-modify tabs activeTab=1` moved the number and
    # left tab 1 visible and tab 2 hidden. Programmatic tab switching did nothing at all, while
    # ft_tabs_select (the same work, reached another way) worked fine.
    # In the DOM an index property that names the state is settable and acts — select.selectedIndex
    # moves the selection — so this is the CLASS acting on a change.
    #
    # THROUGH setProp=, NOT FT_PROTO_REPROP, and the difference is a route. REPROP is told by
    # ft-modify and by nothing else; `activeTab` can also move through the construction DSL and
    # through a STATE RESTORE. The restore was the live one: a reloaded app came back with
    # activeTab=1 restored and tab one still on screen, because the number arrived through
    # _ft_setprop and nothing switched the bodies. CONTRIBUTING §1 gives the rule — prefer
    # setProp= whenever a route other than ft-modify can produce the bad state — and this was
    # that case all along. Found by tests/test-roundtrip.bash, which drives every control with
    # its own keys and demands a save and a reload reproduce the screen.
}
ft-tabs()     { ft_new tabs "$@" && FT_NEST_STACK+=("$FT_RET"); }
end_ft_tabs() { ft-end tabs; }

# ft-tab — a titled panel. The enclosing ft-tabs shows one at a time.
ft_prototype_tab() {
    ft_prototype extends=ft_control defaults="display=flex flexDirection=column"
    # NO `ft_prop_kind_set title paint` HERE ANY MORE. A tab's title is drawn INTO its header, so
    # a longer one wants a wider tab — it was never paint-only even for a tab. And it is the same
    # global name ft-frame calls layout, so whichever of the two an app built first decided it for
    # the other. Left unregistered, it takes the table's conservative default, which is layout.
}
_FT_TAB_SEQ=0
ft-tab() {                      # [title=] ...  (name auto-generated from the tabs)
    local a hasname=0
    for a in "$@"; do [[ "$a" == name=* ]] && hasname=1; done
    if (( hasname )); then
        ft_new tab "$@" && FT_NEST_STACK+=("$FT_RET")
    else
        local owner=""
        (( ${#FT_NEST_STACK[@]} > 0 )) && owner="${FT_NEST_STACK[$(( ${#FT_NEST_STACK[@]} - 1 ))]}"
        ft_new tab name="${owner}_tab$(( ++_FT_TAB_SEQ ))" "$@" && FT_NEST_STACK+=("$FT_RET")
    fi
}
end_ft_tab() { ft-end tab; }

FT_TABS=()
_ft_tabs_tabs() { local k; FT_TABS=(); for k in ${FT_KIDS[$1]:-}; do [[ "${FT_TYPE[$k]:-}" == tab ]] && FT_TABS+=("$k"); done; }

tabs_on_children_complete() { _ft_tabs_apply "$1"; }
# ONE PLACE FLIPS THE PANELS — and hiding one is a promise about FOCUS, not just about paint.
#
# Both routes (the initial apply and every switch) ran their own identical flip loop, and
# neither asked the question the engine asks whenever anything else hides a control: is the
# focused control still one focus is allowed to sit on? ft-modify's display route sets
# touched_focus and then runs `_ft_focus_skippable FT_FOCUS && ft_focus_move 1` precisely so
# that hiding never strands focus — but a tab switch writes `display` with a raw _ft_setprop
# and skipped it, and the route is live: _ft_accel_target deliberately lets a tab's accessKey
# fire from ANYWHERE on the form, and ft-help gives every help tab one. Press another tab's
# accelerator while focus is inside the body and focus stayed on the now-hidden control — the
# keymap cascade, the derived legend and Enter with it, so Enter ACTIVATED AN INVISIBLE BUTTON.
#
# The predicate is not copied: _ft_focus_skippable is the engine's one answer to "may focus be
# here", the same call ft-modify, ft_focus_move and ft_focus_first each ask. What is fixed here
# is that this route did not ask it. (Routing the flips through ft-modify itself would drag in
# a full ft_reflow of the body per switch — exactly what _ft_tabs_relayout exists to avoid,
# since the tabs' own box never changes size — plus damage and transition arming: a much larger
# behaviour change than the stranding this is about.)
_ft_tabs_show_only() {          # idx — show FT_TABS[idx], hide the rest (caller filled FT_TABS)
    local idx=$1 i n=${#FT_TABS[@]}
    for (( i=0; i<n; i++ )); do
        if (( i == idx )); then _ft_setprop "${FT_TABS[$i]}" display flex
        else                    _ft_setprop "${FT_TABS[$i]}" display none; fi
    done
    [[ -n "${FT_FOCUS:-}" ]] && _ft_focus_skippable "$FT_FOCUS" && ft_focus_move 1
    return 0                    # the guard above must never decide this function's status
}
# setProp= hook, reached on EVERY route a property is written by — ft-modify, the construction
# DSL, and a state restore. Only `activeTab` needs the prototype to do anything; everything
# else is an ordinary repaint the engine has already scheduled. (At construction the bodies do not
# exist yet, so _ft_tabs_apply finds no tabs and returns; end_ft_tabs applies it once they do.)
_ft_tabs_setprop() {            # name prop value
    [[ "$2" == activeTab ]] || return 0
    _ft_tabs_apply "$1"
    return 0
}
_ft_tabs_apply() {              # name — show active tab, hide the rest
    local name=$1 n a
    _ft_tabs_tabs "$name"; n=${#FT_TABS[@]}
    (( n == 0 )) && return
    ft_resolved_prop "$name" activeTab 0; a=$FT_RET
    (( a < 0 )) && a=0; (( a >= n )) && a=$(( n - 1 ))
    _ft_tabs_show_only "$a"
    # STAMPED, not set: _ft_setprop is what calls us now, so writing the clamped index back
    # through it would re-enter this function on every switch and never stop.
    _ft_stamp_prop "$name" activeTab "$a"
}

# Lay out ONE tab body inside the tabs' (fixed) content box. A switch only needs
# this — not a full-subtree reflow — because the tabs' own size never changes, so
# nothing outside it moves; this is what keeps switching snappy.
_ft_tabs_relayout() {           # name body
    local name=$1 body=$2
    _ft_inset4 "$name"; local il=$FT_INSET_LEFT it=$FT_INSET_TOP ir=$FT_INSET_RIGHT ib=$FT_INSET_BOTTOM
    local bx=$(( ${FT_ABSOLUTE_X[$name]:-0} + il )) by=$(( ${FT_ABSOLUTE_Y[$name]:-0} + it ))
    local bw=$(( ${FT_MEASURED_WIDTH[$name]:-0} - il - ir )) bh=$(( ${FT_MEASURED_HEIGHT[$name]:-0} - it - ib ))
    (( bw < 0 )) && bw=0; (( bh < 0 )) && bh=0
    FT_AVAILABLE_HEIGHT[$body]=$bh
    _ft_pass_pref  "$body"
    FT_MEASURED_WIDTH[$body]=$bw                        # the tab body stretches to the box
    _ft_pass_width "$body"
    _ft_pass_height "$body" "$bh"
    _ft_pass_arrange "$body" "$bx" "$by"
}
# Switch: flip displays, relayout only the new body, repaint the tabs subtree
# (its bg fill clears the old body; the new body is dirtied on top).
_ft_tabs_set() {                # name idx
    local name=$1 idx=$2 n
    _ft_tabs_tabs "$name"; n=${#FT_TABS[@]}
    (( n == 0 )) && return
    (( idx < 0 )) && idx=0; (( idx >= n )) && idx=$(( n - 1 ))
    local cur; ft_resolved_prop "$name" activeTab 0; cur=$FT_RET
    (( cur == idx )) && return              # no-op: already on this tab
    _ft_tabs_show_only "$idx"
    _ft_setprop "$name" activeTab "$idx"
    # Lay the new body out only if it has not already been laid under the tabs'
    # CURRENT geometry — revisiting a tab is then a pure repaint (its controls'
    # positions are still valid), which is what makes repeat switches instant.
    local body="${FT_TABS[$idx]}"
    local sig="${FT_MEASURED_WIDTH[$name]:-}x${FT_MEASURED_HEIGHT[$name]:-}@${FT_ABSOLUTE_X[$name]:-}.${FT_ABSOLUTE_Y[$name]:-}"
    local sv="_fti_${body}__sig"
    if [[ "${!sv-}" != "$sig" ]]; then
        _ft_tabs_relayout "$name" "$body"
        printf -v "$sv" '%s' "$sig"
    fi
    ft_dirty_subtree "$name"
    _ft_hook "$name" on_change "$idx"
}
ft_tabs_next()  { ft_resolved_prop "$1" activeTab 0; _ft_tabs_set "$1" $(( FT_RET + 1 )); }
ft_tabs_prev()  { ft_resolved_prop "$1" activeTab 0; _ft_tabs_set "$1" $(( FT_RET - 1 )); }
ft_tabs_first() { _ft_tabs_set "$1" 0; }
ft_tabs_last()  { _ft_tabs_tabs "$1"; _ft_tabs_set "$1" $(( ${#FT_TABS[@]} - 1 )); }
# ft_tabs_select NAME IDX — for instance accelerators (e.g. keys 1..9). Clamps.
ft_tabs_select() { _ft_tabs_set "$1" "$2"; }

# Paints the folder tabs + the content box, then repaints the active body. That
# last step is essential: a repaint of the tabs node alone (a focus change
# dirties only this node) would otherwise fill over every child and blank it — a
# background-filling container must repaint its children with itself.
_ft_draw_tabs() {               # name
    local name=$1
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local cols=${FT_MEASURED_WIDTH[$name]:-0} rows=${FT_MEASURED_HEIGHT[$name]:-0}
    (( cols < 3 || rows < 4 )) && return

    _ft_color_override "$name" backgroundColor 48; local bgov=$FT_RET
    local sgr="$FT_COLOR_BODY$bgov" rst=$FT_COLOR_RESET r
    ft_fit "" "$cols"
    for (( r=0; r<rows; r++ )); do ft_print_at_width $(( row + r )) "$col" "$sgr$FT_FIT" "$cols"; done

    _ft_border_glyphs "$name"                 # BG_TL/TR/BL/BR/H/V (rounded)
    _ft_color_override "$name" borderColor 38; local bcov=$FT_RET
    local bd="$FT_COLOR_BORDER$bcov"
    # Junction glyphs (ASCII-safe): ┴ under a closed tab, ┘/└ flanking the open
    # (active) tab where the box edge lifts up into it.
    local TU=$FT_GLYPH_TEE_UP UL=$FT_GLYPH_BOTTOM_RIGHT UR=$FT_GLYPH_BOTTOM_LEFT   # ┴  ┘  └
    local hr2Row=$(( row + 2 )) bottomRow=$(( row + rows - 1 ))

    # ── The content box: sides + bottom (its top edge, row+2, is built below so
    #    the active tab can open into it). ──────────────────────────────────────
    local hr; printf -v hr '%*s' $(( cols - 2 )) ''; hr=${hr// /$BG_H}
    ft_print_at_width "$bottomRow" "$col" "$bd$BG_BL$hr$BG_BR" "$cols"
    for (( r=3; r<rows-1; r++ )); do
        ft_print_at_width $(( row + r )) "$col"              "$bd$BG_V" 1
        ft_print_at_width $(( row + r )) $(( col + cols-1 )) "$bd$BG_V" 1
    done

    _ft_tabs_tabs "$name"; local n=${#FT_TABS[@]}
    ft_resolved_prop "$name" activeTab 0; local a=$FT_RET
    local focused=0; [[ "${FT_FOCUS:-}" == "$name" ]] && focused=1

    # Build the content box TOP edge (row+2) as a per-column glyph array so the
    # active tab can punch an opening through it.
    local -a top=(); local k
    for (( k=0; k<cols; k++ )); do top[$k]=$BG_H; done
    top[0]=$BG_TL; top[$(( cols-1 ))]=$BG_TR

    # ── The tab headers (rows row+0 top, row+1 label). The FIRST tab is flush
    #    with the box's left edge, so its left wall IS the box border — the left
    #    edge is one straight vertical line, no overhang. ────────────────────────
    local LT=$FT_GLYPH_TEE_LEFT                                   # ├
    local i x=0 title iw bw lbl lw rw kk ac
    for (( i=0; i<n; i++ )); do
        ft_resolved_prop "${FT_TABS[$i]}" title ""; title=$FT_RET
        _ft_get_raw "${FT_TABS[$i]}" accessKey; ac=$FT_RET
        _ft_accel_text "$title" "$ac"; title=$FT_RET   # effective label (accessKey underlined below)
        ft_display_width " $title "; iw=$FT_DISPLAY_WIDTH      # inner width incl. its spaces
        bw=$(( iw + 2 ))                             # + the two side walls
        (( x + bw > cols - 1 )) && break             # keep clear of the right wall
        local ax=$(( col + x ))
        # top:  ╭───╮
        printf -v hr '%*s' "$iw" ''; hr=${hr// /$BG_H}
        ft_print_at_width "$row" "$ax" "$bd$BG_TL$hr$BG_TR" "$bw"
        # label: │ Title │ — the active tab's LABEL CELL (only the ` Title `,
        # never the walls) takes a background so you always know which tab you're
        # in: the bright FOCUS colour while the tab strip itself is focused
        # (highlighted), the calmer SELECTED colour once focus has moved into the
        # tab's body (activated). Inactive tabs are dim text on the plain body.
        if (( i == a )); then
            (( focused )) && lbl=$FT_COLOR_FOCUS || lbl=$FT_COLOR_SELECTED
            _ft_css_pe_or "$name" active "$lbl"; lbl=$FT_RET               # tabs::active
        else
            _ft_css_pe_or "$name" tab "$bd$FT_COLOR_TEXT_MUTED"; lbl=$FT_RET    # tabs::tab
        fi
        _ft_accel_markup "$title" "$ac" "$lbl"; local mtitle=$FT_RET   # underline the accessKey
        ft_print_at_width $(( row + 1 )) "$ax" "$bd$BG_V$lbl $mtitle $bd$BG_V$rst" "$bw"
        # merge onto the box top edge (row+2). The flush-left first tab (lw==0)
        # gets special left junctions so the box border runs straight down: │ for
        # the active (open) tab, ├ for a closed one.
        lw=$x; rw=$(( x + bw - 1 ))
        if (( i == a )); then
            (( lw == 0 )) && top[$lw]=$BG_V || top[$lw]=$UL
            top[$rw]=$UR
            for (( kk=lw+1; kk<rw; kk++ )); do top[$kk]=" "; done   # open into the pane
        else
            (( lw == 0 )) && top[$lw]=$LT || top[$lw]=$TU
            top[$rw]=$TU
        fi
        x=$(( x + bw + 1 ))                          # 1-col gap between tabs
    done

    local edge=""; for (( k=0; k<cols; k++ )); do edge+=${top[$k]}; done
    ft_print_at_width "$hr2Row" "$col" "$bd$edge$rst" "$cols"
}
# The tabs fill their whole background, so a repaint of the tabs NODE ALONE (a
# focus change dirties only the focused control) would erase every child. ft_redraw_dirty
# repairs the children of every dirty container it paints, so redraw puts the bodies back
# over the fill (and a tab SWITCH already dirties the subtree via its reflow). No per-draw
# child re-walk, so nothing is drawn twice.
