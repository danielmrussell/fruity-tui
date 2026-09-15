#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — controls/ft-label.bash
#
#  The "label" class: a text box. display=inline-block (labels are
#  inline-level in CSS), overflowY=auto by default — WHEN its content is
#  taller than its box, a label grows its own scrollbar gutter in its last
#  column, becomes focusable (Tab reaches it; otherwise focus skips it), and
#  scrolls with Up/Down/PgUp/PgDn/Home/End. The gutter thumb brightens while
#  the label has focus — that's how you can tell. No wiring needed: this is
#  CSS overflow:auto as a default. Opt out with overflowY=hidden (clip
#  silently) or overflowY=visible (spill — on a terminal that means painting
#  over whatever is below; the clip system confines it to the nearest
#  overflow-hidden ancestor's content box).
#
#  If an external ft-scrollbar declares for=THISLABEL, the built-in gutter
#  stands down automatically (one scrollbar, the caller's choice of style).
#
#  Depends on ft-core.bash and ft-forms.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_LABEL_LOADED:-}" ]] && return 0
_FT_LABEL_LOADED=1

# Does this label have anything to scroll ITSELF? (Its cached text extent is taller than its
# box.) When not, a wheel tick over it CHAINS to the enclosing scroll pane — browser-style.
_ft_label_wheel_probe() {       # name → 0 iff the label's own content overflows
    # Ask the SAME metrics the scrolling itself uses, not the extent cache: that cache is
    # only populated for an AUTO-SIZED label, so a label given an explicit width/height had
    # no entry and reported "nothing to scroll" however far it could actually scroll. It
    # went unnoticed because the wheel router listed `label` among the always-chain types,
    # so this answer was never consulted. _ft_label_focus_skip has always used these.
    _ft_label_metrics "$1"
    (( LBL_MAXSCROLL > 0 ))
}

# A scrollable label's job is scrolling — so Up/Down are CRUCIAL (they lead the legend), the
# page keys IMPORTANT, jump-to-ends and copy NORMAL. Run once, by `keymap=label` above.
_ft_define_keymap_label() {
    # A label only becomes focusable when it SCROLLS (_ft_label_focus_skip), so its ladder
    # only ever matters then — a scroll-less label is not a Tab stop and has no rungs to
    # climb. INACTIVE: Enter steps in. SCROLLING: the arrows are the label's and never eject.
    ft-bindkeys ft_keymap_label ENTER=ft_key_delve
    ft-keymap-cap ft_keymap_label ENTER ft_key_delve "$FT_IMPORTANCE_CRUCIAL" "Scroll"

    ft_keymap_once ft_keymap_label_scrolling
    ft-bindkeys ft_keymap_label_scrolling \
        LEFT=ft_label_key_up RIGHT=ft_label_key_down ESC=ft_key_undelve
    ft-keymap-cap ft_keymap_label_scrolling UP    ft_label_key_up   "$FT_IMPORTANCE_CRUCIAL"   "Scroll up"
    ft-keymap-cap ft_keymap_label_scrolling DOWN  ft_label_key_down "$FT_IMPORTANCE_CRUCIAL"   "Scroll down"
    ft-keymap-cap ft_keymap_label_scrolling PGUP  ft_label_key_pgup "$FT_IMPORTANCE_IMPORTANT" "Page up"
    ft-keymap-cap ft_keymap_label_scrolling PGDN  ft_label_key_pgdn "$FT_IMPORTANCE_IMPORTANT" "Page down"
    ft-keymap-cap ft_keymap_label_scrolling HOME  ft_label_key_home "$FT_IMPORTANCE_NORMAL"    "Top"
    ft-keymap-cap ft_keymap_label_scrolling END   ft_label_key_end  "$FT_IMPORTANCE_NORMAL"    "Bottom"
    ft-keymap-cap ft_keymap_label_scrolling ESC   ft_key_undelve    "$FT_IMPORTANCE_IMPORTANT" "Leave"
    # Alt+C was WRONG and was the source of the mistake spreading: the framework has exactly
    # two spellings of copy — Ctrl+C (taken from the tty on purpose, named in Settings) and
    # readline's Alt+W (the one that still arrives where no keyboard protocol was
    # negotiated). Alt+C was neither, so "copy" meant a third thing on labels alone.
    ft-bindkeys ft_keymap_label CTRL+c=ft_label_copy ALT+w=ft_label_copy
    ft-keymap-cap ft_keymap_label CTRL+c ft_label_copy "$FT_IMPORTANCE_NORMAL" "Copy all"
}
ft_class_label() {
    # draw/height/preferredWidth are bound by convention from _ft_draw_label,
    # _ft_height_label and _ft_preferred_width_label — see _ft_class_bind_by_convention,
    # which runs for EACH class in the chain as its constructor fires, so `button` inherits
    # label's height and overrides only the draw and width it has of its own.
    ft_runlevels scrolling=ft_keymap_label_scrolling
    ft_class extends=ft_control focusable=true keymap=label mouse=label \
        focusSkip=_ft_label_focus_skip \
        wheelProbe=_ft_label_wheel_probe \
        defaults="display=inline-block overflowY=auto" \
        defaults="importance=minor"
}

# THE LABEL'S OWN SCROLLBAR TAKES THE MOUSE. A scrolling label paints its bar in its own last
# column (the draw below), and nothing handled a press there: the engine's gutter grab claims bars
# in RESERVED gutters, which a label does not use, so pressing the thumb only focused the label.
# Press anywhere on the bar and the thumb centres on the pointer; drag and it follows, and it keeps
# following off the bar column until release, as a desktop scrollbar does. The mapping is the
# scrollbar control's (ft_scrollbar_pos_from_point), which sizes the thumb exactly as the draw does.
# A grab also steps the label onto its `scrolling` rung (_ft_runlevel_grab), so the arrows go on
# scrolling what was just dragged.
declare -A _FT_LABEL_BAR_GRAB=()
_ft_destroy_label() { unset "_FT_LABEL_BAR_GRAB[$1]"; }    # removed mid-drag: forget the grab
_ft_mouse_label() {             # name action relx rely
    local n=$1 act=$2
    case $act in
        release) unset "_FT_LABEL_BAR_GRAB[$n]"; return 0 ;;
        drag)    [[ -n "${_FT_LABEL_BAR_GRAB[$n]:-}" ]] || return 0 ;;
        press)   unset "_FT_LABEL_BAR_GRAB[$n]"
                 _ft_label_metrics "$n"
                 (( LBL_GUTTER && $3 == ${FT_MEASURED_WIDTH[$n]:-0} - 1 )) || return 0
                 _FT_LABEL_BAR_GRAB[$n]=1
                 _ft_runlevel_grab "$n" ;;
        *)       return 0 ;;
    esac
    ft_get "$n" scrollHeight; local total=${FT_RET:-0}
    ft_get "$n" clientHeight; local client=${FT_RET:-0}
    (( total > client && client > 0 )) || return 0
    ft_scrollbar_pos_from_point "$n" "${FT_ABSOLUTE_Y[$n]:-0}" "$client" "$total" "$client" \
                                $(( ${FT_ABSOLUTE_Y[$n]:-0} + $4 ))
    ft-modify "$n" scrollTop="$FT_RET"
    return 0
}

# Alt+C on a focused (scrollable) label copies its whole text to the terminal
# clipboard — so read-only text is still copyable. Character-level shift-select
# in labels would need a caret model; whole-text copy covers the common need.
# …and says whether it worked, on the same three outcomes as every other copy — an empty
# label used to send the OSC 52 sequence with no payload, which CLEARS the clipboard rather
# than doing nothing, and then reported nothing at all.
ft_label_copy() {
    local n=$1; ft_resolved_prop "$n" text
    ft_clip_copy "$FT_RET"
    _ft_announce_copy $?
    return 0
}

# A label is decorative far more often than it is referenced, so — like an HTML
# element that needs no id — it may be declared WITHOUT a name: one is generated.
# (A label you want to restyle later still gets a stable name by passing name=.)
# Auto-named labels are fine across rebuilds: they hold no focus or state, and a
# rebuild destroys and recreates them wholesale.
_FT_LABEL_AUTO=0
ft-label() {
    local a
    for a in "$@"; do [[ "$a" == name=* ]] && { ft_new label "$@"; return; }; done
    ft_new label "name=__lbl$(( ++_FT_LABEL_AUTO ))" "$@"
}

# A label's measured text IS its own `text` property, so every cache call here passes the
# control's generation counter. That turns each lookup from a compare of the whole text into
# an integer compare — the difference between a growing log costing O(n) per appended line
# and costing O(1). Controls whose text is COMPOSED must not do this (see the note on
# _ft_text_extent_cached).
_ft_preferred_width_label() {             # name → FT_RET (content columns)
    local genvar="_fti_${1}__textgen"; local gen=${!genvar:-0}
    _ft_lines_sync "$1" "$gen"                  # O(1) in sync; fetches the text only to rebuild
    _ft_lines_maxw "$1"                         # the running max — measured once per rebuild
    FT_TEXT_WIDTH=$FT_RET
}
_ft_height_label() {            # name contentwidth → FT_RET (content rows)
    local name=$1 cw=$2
    local genvar="_fti_${name}__textgen"; local gen=${!genvar:-0}
    _ft_lines_sync "$name" "$gen"
    local -n _ll="_fti_${name}__lines"
    _ft_lines_maxw "$name"
    FT_TEXT_WIDTH=$FT_RET; FT_TEXT_HEIGHT=${#_ll[@]}; (( FT_TEXT_HEIGHT )) || FT_TEXT_HEIGHT=1
    if (( FT_TEXT_WIDTH > cw && cw > 0 )); then
        _ft_lines_rows "$name" "$cw"
        local -n _rr="$FT_LINES_ROWS"
        FT_RET=${#_rr[@]}
        (( FT_RET < 1 )) && FT_RET=1
    else
        FT_RET=$FT_TEXT_HEIGHT
    fi
}

# _ft_label_metrics NAME — the label's current scroll situation:
#   LBL_TOTAL (content lines at the gutterless width), LBL_ROWS (box rows),
#   LBL_GUTTER (1 if the built-in gutter applies), LBL_MAXSCROLL.
_ft_label_metrics() {           # name
    local name=$1
    local cols=${FT_MEASURED_WIDTH[$name]:-0} rows=${FT_MEASURED_HEIGHT[$name]:-0}
    local genvar="_fti_${name}__textgen"; local gen=${!genvar:-0}
    _ft_lines_sync "$name" "$gen"               # never touches the text when in sync
    _ft_lines_maxw "$name"; local natw=$FT_RET
    local -n _mlines="_fti_${name}__lines"
    local total=${#_mlines[@]}; (( total )) || total=1
    FT_TEXT_WIDTH=$natw; FT_TEXT_HEIGHT=$total
    if (( natw > cols && cols > 0 )); then
        _ft_lines_rows "$name" "$cols"
        local -n _mrows="$FT_LINES_ROWS"
        total=${#_mrows[@]}
        unset -n _mrows
    fi
    LBL_TOTAL=$total; LBL_ROWS=$rows
    LBL_GUTTER=0
    if (( total > rows && rows > 0 && cols >= 2 )); then
        # The engine's one answer to "what is this box's overflow on this axis" — the axis
        # property if the cascade sets one, else the shorthand, else CSS's initial `auto`.
        # This function PRODUCES the scrollHeight/clientHeight that ft_has_scrollbar reads, so
        # it owns the other half of that question itself and shares only the mode.
        _ft_overflow_mode "$name" y
        local ovY=$FT_RET
        # Only auto/scroll grow a scrollbar gutter (and are scrollable).
        # hidden and clip HARD-CLIP with no scrollbar and no scrolling.
        if [[ "$ovY" == auto || "$ovY" == scroll ]]; then
            # An external for= bar owns scrolling UI for this label.
            [[ -z "${FT_SCROLLBAR_FOR_TARGET[$name]:-}" ]] && LBL_GUTTER=1
        fi
    fi
    # With a gutter the text lives in cols-1 — the REAL line count (and so
    # the real scroll range) must be measured at that width, or the last
    # soft-wrapped lines are unreachable and the bar never touches bottom.
    if (( LBL_GUTTER )) && (( natw > cols - 1 )); then
        _ft_lines_rows "$name" $(( cols - 1 ))
        local -n _grows="$FT_LINES_ROWS"
        LBL_TOTAL=${#_grows[@]}
        unset -n _grows
    fi
    LBL_MAXSCROLL=$(( LBL_TOTAL - rows )); (( LBL_MAXSCROLL < 0 )) && LBL_MAXSCROLL=0
    # PUBLISH THE DOM'S ANSWER TO "DID THIS OVERFLOW?". A container already publishes
    # scrollHeight/clientHeight every arrange (docs/api-naming.md promises both names); a label
    # did not, so an app asking whether its text overflowed had no public way to find out —
    # demo/tutorial-demo.bash called _ft_label_metrics and read LBL_MAXSCROLL, a dynamically
    # scoped internal. Written only when it CHANGES: this runs on the draw path, and an
    # unconditional property write per paint would churn the cascade cache for nothing.
    local _pub="_ftp_${name}_scrollHeight"
    [[ "${!_pub:-}" != "$LBL_TOTAL" ]] && _ft_setprop "$name" scrollHeight "$LBL_TOTAL"
    _pub="_ftp_${name}_clientHeight"
    [[ "${!_pub:-}" != "$rows" ]] && _ft_setprop "$name" clientHeight "$rows"
    # WITH THE EXTENT PUBLISHED, AN OLD OFFSET MAY NOW BE OUT OF RANGE — the text was replaced
    # with something shorter, or the box was resized taller. Writing the value back through the
    # setter clamps it against the pair just published (_ft_clamp_scroll), so the property an app
    # reads never outlives the document it was measured against, and the rule stays in one place.
    # Only when it is actually wrong: this runs on the draw path.
    _pub="_ftp_${name}_scrollTop"; local _cur=${!_pub:-0}
    case $_cur in
        ''|*[!0-9-]*|-*-*|-) : ;;
        *) (( _cur > LBL_MAXSCROLL || _cur < 0 )) && _ft_setprop "$name" scrollTop "$_cur" ;;
    esac
    return 0
}

# Only a label that ACTUALLY scrolls (auto/scroll overflow AND overflowing,
# with its own gutter) is focusable; a fitting, clipped, or hidden label is
# skipped by Tab — you can't scroll what has no scrollbar.
_ft_label_focus_skip() {        # name → 0 = skip
    _ft_label_metrics "$1"
    (( LBL_GUTTER == 0 || LBL_MAXSCROLL == 0 ))
}

ft_label_scroll_set() {        # name offset
    local name=$1 v=$2
    _ft_label_metrics "$name"
    (( v < 0 )) && v=0
    (( v > LBL_MAXSCROLL )) && v=$LBL_MAXSCROLL
    ft-modify "$name" scrollTop="$v"
}
_ft_label_scroll_by() {
    ft_resolved_prop "$1" scrollTop 0
    ft_label_scroll_set "$1" $(( FT_RET + $2 ))
}
# A label that has nothing left to scroll DECLINES the key (FT_KEY_BUBBLE=1) instead of
# swallowing it, so it reaches whatever encloses the label — an overflow=auto pane, or the
# app. This is what the wheel already did via FT_CLASS_WHEEL_PROBE ("chains to the enclosing
# scroll pane — browser-style") and what a textfield already did for the same six keys
# (ft_textfield_idle_*); a label kept them, so a log inside a scrolling pane could not be scrolled
# by keyboard at all — the pane scrolled by wheel and by nothing else.
#
# "Nothing left" is direction-aware, exactly as in a browser: pressing Down at the bottom
# hands the key on, while pressing Down anywhere above it scrolls the label itself.
_ft_label_can_scroll() {        # name direction(-1 up | 1 down) → 0 if this label can move
    _ft_label_metrics "$1"
    (( LBL_MAXSCROLL > 0 )) || return 1
    ft_resolved_prop "$1" scrollTop 0
    local at=${FT_RET:-0}
    if (( $2 < 0 )); then (( at > 0 )); else (( at < LBL_MAXSCROLL )); fi
}
ft_label_key_up() {
    _ft_label_can_scroll "$1" -1 || { FT_KEY_BUBBLE=1; return 1; }
    _ft_label_scroll_by "$1" -1
}
ft_label_key_down() {
    _ft_label_can_scroll "$1" 1 || { FT_KEY_BUBBLE=1; return 1; }
    _ft_label_scroll_by "$1" 1
}
ft_label_key_pgup() {
    _ft_label_can_scroll "$1" -1 || { FT_KEY_BUBBLE=1; return 1; }
    _ft_label_metrics "$1"; _ft_label_scroll_by "$1" $(( -LBL_ROWS ))
}
ft_label_key_pgdn() {
    _ft_label_can_scroll "$1" 1 || { FT_KEY_BUBBLE=1; return 1; }
    _ft_label_metrics "$1"; _ft_label_scroll_by "$1" "$LBL_ROWS"
}
ft_label_key_home() {
    _ft_label_can_scroll "$1" -1 || { FT_KEY_BUBBLE=1; return 1; }
    ft_label_scroll_set "$1" 0
}
ft_label_key_end() {
    _ft_label_can_scroll "$1" 1 || { FT_KEY_BUBBLE=1; return 1; }
    _ft_label_metrics "$1"; ft_label_scroll_set "$1" "$LBL_MAXSCROLL"
}

# ── What a label is WORTH, row by row (see ft_tier_rects in ft-forms.bash) ───
# A block of prose is mostly NOT text: the demo's labels measure 32% blank, and
# 129 of the 204 text cells a callout buried at 62x40 belonged to a label — the
# single biggest source of the one thing the user called the gravest sin. Those
# two facts are the same fact: with the whole rect priced as content, the placer
# cannot tell a paragraph's ragged right margin from its words, so it sits on
# the words as readily as on the gap beside them.
#
# CONSERVATIVE BY CONSTRUCTION. This may only ever OVER-price: calling an inked
# cell empty is what makes a callout land on text, and it is exactly the bug the
# first textfield hook shipped with. So every case this cannot be certain about
# — a non-left alignment, a wrap indicator, a scrolled or overflowing block —
# declines and keeps the whole rect at content weight. The rows it does price
# are held to 0% ink by the render probe, not by argument.
_ft_tiers_label() {                      # name t l b r
    local name=$1 t=$2 l=$3 b=$4 r=$5
    local rows=$(( b - t + 1 )) cols=$(( r - l + 1 ))
    ft_resolved_prop "$name" textAlign left;     local talign=$FT_RET
    ft_resolved_prop "$name" wrapIndicator false; local wrapInd=$FT_RET
    ft_resolved_prop "$name" scrollTop 0;        local scrollTop=$FT_RET
    ft_resolved_prop "$name" overflowY "";       local ovY=$FT_RET
    [[ -z "$ovY" ]] && { ft_resolved_prop "$name" overflow hidden; ovY=$FT_RET; }
    if [[ "$talign" != left || "$wrapInd" == true || "$ovY" == visible ]] \
       || (( scrollTop != 0 )); then
        ft_tier_add "$t" "$l" "$b" "$r" "$FT_TIER_CONTENT"; return 0
    fi
    # The same row source and text column the draw uses, chosen by the same test.
    _ft_label_metrics "$name"                       # → LBL_GUTTER, FT_TEXT_WIDTH
    local textw=$cols; (( LBL_GUTTER )) && textw=$(( cols - 1 ))
    local src
    if (( FT_TEXT_WIDTH > textw )); then
        _ft_lines_rows "$name" "$textw"; src=$FT_LINES_ROWS
    else
        src="_fti_${name}__lines"
    fi
    local -n _tlines="$src"
    # More drawn rows than the box holds means it is clipping, and the last visible row is not
    # the last logical one — the ragged tail this reasons about would be somewhere off-screen.
    if (( ${#_tlines[@]} > rows )); then
        ft_tier_add "$t" "$l" "$b" "$r" "$FT_TIER_CONTENT"; return 0
    fi
    local i w
    for (( i = 0; i < rows; i++ )); do
        w=0
        if (( i < ${#_tlines[@]} )) && (( ${#_tlines[i]} )); then
            ft_display_width "${_tlines[i]}"; w=$FT_DISPLAY_WIDTH
        fi
        (( w > cols )) && w=$cols
        (( w > 0 )) && ft_tier_add $(( t + i )) "$l" $(( t + i )) $(( l + w - 1 )) "$FT_TIER_CONTENT"
        (( w < cols )) && ft_tier_add $(( t + i )) $(( l + w )) $(( t + i )) "$r" "$FT_TIER_EMPTY_TEXT"
    done
}

_ft_draw_label() {                       # name
    local name=$1
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local cols=${FT_MEASURED_WIDTH[$name]:-0} rows=${FT_MEASURED_HEIGHT[$name]:-0}
    (( cols < 1 )) && return

    # Draw reads the LINE STORE, never the joined string: asking for `text` on a store-backed
    # label materialises every line into one buffer, which would put an O(total) cost on every
    # single frame. Emptiness is a property of the store, so even that test costs nothing.
    local dgenvar="_fti_${name}__textgen"; local dgen=${!dgenvar:-0}
    _ft_lines_sync "$name" "$dgen"
    local -n _dlines="_fti_${name}__lines"

    # ONE compose point: theme body + cascaded background-color/color/font-weight/
    # text-decoration + disabled dimming (see _ft_compose_sgr). Unstyled, this is exactly
    # $FT_COLOR_BODY as before; a stylesheet can now also bold/underline a label.
    _ft_compose_sgr "$name"; local sgr=$FT_RET

    if (( ${#_dlines[@]} == 0 )) || { (( ${#_dlines[@]} == 1 )) && [[ -z "${_dlines[0]}" ]]; }; then
        ft_fit "" "$cols"; ft_print_at_width "$row" "$col" "$sgr$FT_FIT$FT_COLOR_RESET" "$cols"
        return
    fi

    _ft_label_metrics "$name"
    local textw=$cols
    (( LBL_GUTTER )) && textw=$(( cols - 1 ))
    # wrapIndicator=true reserves ONE more column on the right, in which a
    # continuation glyph marks every line the text SOFT-wrapped onto the next.
    ft_resolved_prop "$name" wrapIndicator false; local wrapInd=$FT_RET
    local indCol=0
    [[ "$wrapInd" == true ]] && { indCol=1; textw=$(( textw - 1 )); (( textw < 1 )) && textw=1; }

    # Wrap decision mirrors measurement. When wrapIndicator is on we need the
    # per-line continuation flags, so wrap directly (opt-in, uncached);
    # otherwise use the cache.
    _ft_lines_maxw "$name"; FT_TEXT_WIDTH=$FT_RET
    # `lines` is a NAMEREF onto whichever store array applies — no copy, so a frame costs
    # what it paints rather than what the log holds.
    local -a _wrapped=() cont=()
    local lines_src
    if (( indCol )); then
        # wrapIndicator needs per-row continuation flags, which only a direct wrap produces.
        # This opt-in path is the one place the joined text is still required.
        ft_resolved_prop "$name" text; local text=$FT_RET
        ft_wrap "$text" "$textw"; _wrapped=("${FT_WRAP_LINES[@]}"); cont=("${FT_WRAP_CONT[@]}")
        lines_src=_wrapped
    elif (( FT_TEXT_WIDTH > textw )); then
        _ft_lines_rows "$name" "$textw"; lines_src=$FT_LINES_ROWS
    else
        lines_src="_fti_${name}__lines"         # fits: the logical lines ARE the rows
    fi
    local -n lines="$lines_src"

    ft_resolved_prop "$name" overflowY ""; local ovY=$FT_RET
    [[ -z "$ovY" ]] && { ft_resolved_prop "$name" overflow hidden; ovY=$FT_RET; }
    ft_resolved_prop "$name" overflowX ""; local ovX=$FT_RET
    [[ -z "$ovX" ]] && { ft_resolved_prop "$name" overflow hidden; ovX=$FT_RET; }

    ft_resolved_prop "$name" scrollTop 0; local scrollTop=$FT_RET
    local total=${#lines[@]}
    local maxscroll=$(( total - rows )); (( maxscroll < 0 )) && maxscroll=0
    (( scrollTop < 0 )) && scrollTop=0
    (( scrollTop > maxscroll )) && scrollTop=$maxscroll

    local start=0 n=$total
    if [[ "$ovY" != visible ]]; then
        start=$scrollTop
        n=$(( total - start )); (( n > rows )) && n=$rows
    fi

    local wrapGlyph=$'↩'; (( FT_USE_UTF8 )) || wrapGlyph='\'
    _ft_css_pe_or "$name" wrap "$FT_COLOR_DIVIDER"; local wrapsgr=$FT_RET   # `label::wrap` marker
    ft_resolved_prop "$name" textAlign left; local talign=$FT_RET   # CSS text-align
    local r
    for (( r=0; r<n; r++ )); do
        if [[ "$ovX" == visible ]]; then
            ft_print_at $(( row + r )) "$col" "$sgr${lines[$((start+r))]}$FT_COLOR_RESET"
        else
            ft_fit_align "${lines[$((start+r))]}" "$textw" "$talign"
            ft_print_at_width $(( row + r )) "$col" "$sgr$FT_FIT$FT_COLOR_RESET" "$textw"
        fi
        # continuation marker for a soft-wrapped line
        if (( indCol )); then
            if [[ "${cont[$((start+r))]:-0}" == 1 ]]; then
                ft_print_at $(( row + r )) $(( col + textw )) "$wrapsgr$wrapGlyph$FT_COLOR_RESET"
            else
                ft_print_at $(( row + r )) $(( col + textw )) "$sgr $FT_COLOR_RESET"
            fi
        fi
    done
    if [[ "$ovY" != visible ]]; then     # (string test OUT of the (( )) arithmetic)
        for (( r=n; r<rows; r++ )); do
            ft_fit "" "$(( textw + indCol ))"
            ft_print_at_width $(( row + r )) "$col" "$sgr$FT_FIT$FT_COLOR_RESET" "$(( textw + indCol ))"
        done
    fi

    # The built-in gutter: proportional thumb in the last column. The thumb
    # brightens while the label is focused — the focus indicator.
    if (( LBL_GUTTER )); then
        local track=$rows
        local thumbLen=$(( track * rows / total )); (( thumbLen < 1 )) && thumbLen=1
        local maxstart=$(( track - thumbLen )); (( maxstart < 0 )) && maxstart=0
        local thumbStart=0
        (( maxscroll > 0 )) && thumbStart=$(( maxstart * scrollTop / maxscroll ))
        local gcol=$(( col + cols - 1 )) tsgr tracksgr
        # Themed focus indicator: FT_COLOR_FOCUS accent while focused, plain
        # FT_COLOR_THUMB otherwise (never FT_COLOR_SEL — that's the selection colour).
        [[ "${FT_FOCUS:-}" == "$name" ]] && tsgr=$FT_COLOR_FOCUS || tsgr=$FT_COLOR_THUMB
        _ft_css_pe_or "$name" scrollbar "$tsgr";        tsgr=$FT_RET       # `label::scrollbar` (thumb)
        _ft_css_pe_or "$name" track "$FT_COLOR_DIVIDER"; tracksgr=$FT_RET      # `label::track` (groove)
        for (( r=0; r<track; r++ )); do
            if (( r >= thumbStart && r < thumbStart + thumbLen )); then
                ft_print_at $(( row + r )) "$gcol" "$tsgr $FT_COLOR_RESET"
            else
                ft_print_at $(( row + r )) "$gcol" "$tracksgr$FT_GLYPH_VERTICAL$FT_COLOR_RESET"
            fi
        done
    fi
}
