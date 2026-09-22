#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — controls/ft-scrollbar.bash
#
#  The "scrollbar" prototype: a keyboard-driven track + proportional thumb. Its
#  properties are the DOM's own scroll vocabulary, axis-specific exactly as
#  CSSOM spells them:
#
#    vertical   (default)   scrollTop   scrollHeight   clientHeight
#    horizontal             scrollLeft  scrollWidth    clientWidth
#
#  scrollHeight/scrollWidth = total content extent (e.g. wrapped line count);
#  clientHeight/clientWidth = how much is visible at once — DEFAULTS TO THE
#  BAR'S OWN TRACK LENGTH, so most callers never set it; scrollTop/scrollLeft
#  = current offset. All of them are paint-only properties: scrolling
#  repaints the bar (and whatever the app syncs) and reflows nothing.
#
#  for=TARGET (HTML's <label for=…>) wires the bar to a scrollable control
#  with NO glue code at all: scrollHeight and clientHeight are derived from
#  the target's own wrapped content and box (never set them by hand), the
#  target's scrollTop is kept in sync automatically on every scroll, the
#  bar's auto height matches the target's, and when the content fits
#  entirely the bar draws nothing (CSS overflow:auto — it appears exactly
#  when the content outgrows the box). onScroll=fn still fires after.
#
#      ft-label     name=msg text="$LONG" width=50 maxHeight=8
#      ft-scrollbar name=msgBar for=msg width=4 indicator=percentage
#
#  indicator=none|percentage (default none; "fraction" is a reserved style
#  name). percentage shows how much of the document has been SEEN, based on
#  the last visible line: (scrollTop+clientHeight)*100/scrollHeight — 8 of 20
#  lines visible reads 40%, the bottom reads exactly 100%. A vertical bar
#  gives up its last track row for the readout (ignored when height < 2);
#  horizontal bars ignore the property. Size `width` to taste (e.g. width=4
#  fits "100%"); the readout is clipped to the bar's width like any text.
#
#  The prototype keymap binds UP/DOWN/LEFT/RIGHT/PGUP/PGDN/HOME/END — so a
#  focused scrollbar shadows the form's arrow-key focus bindings naturally
#  (the dispatch cascade consults the focused control first). After every
#  actual position change, onScroll=fn NAME NEWOFFSET is called if
#  defined — the app's one line of glue to scroll its paired content:
#
#      sb_on_scroll() { ft_set msg scrollTop="$1"; }   # $this=sb, $1=offset
#
#  Depends on ft-core.bash, ft-forms.bash, ft-keymap.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_SCROLLBAR_LOADED:-}" ]] && return 0
_FT_SCROLLBAR_LOADED=1

# Built once, by the prototype that declares `keymap=scrollbar`.
_ft_define_keymap_scrollbar() {
    # UP/DOWN carry the labels; LEFT/RIGHT are the same actions for a horizontal bar and
    # stay unlabelled, so the bar shows one "Scroll" pair rather than four rows of the
    # same thing. That is what a group with no keyCap= is FOR: bound, not advertised.
    ft_keymap_set ft_keymap_scrollbar \
        key=UP    keyCap="Scroll up"   keyImp=crucial   onKey='ft_scrollbar_key_prev $this' \
        key=DOWN  keyCap="Scroll down" keyImp=crucial   onKey='ft_scrollbar_key_next $this' \
        key=PGUP  keyCap="Page up"     keyImp=important onKey='ft_scrollbar_key_pgprev $this' \
        key=PGDN  keyCap="Page down"   keyImp=important onKey='ft_scrollbar_key_pgnext $this' \
        key=HOME  keyCap=Top           keyImp=normal    onKey='ft_scrollbar_key_home $this' \
        key=END   keyCap=Bottom        keyImp=normal    onKey='ft_scrollbar_key_end $this' \
        key=LEFT                                        onKey='ft_scrollbar_key_prev $this' \
        key=RIGHT                                       onKey='ft_scrollbar_key_next $this'
}
ft_prototype_scrollbar() {
    ft_prototype extends=ft_control \
        focusable=true \
        focusSkip=_ft_scrollbar_focus_skip \
        mouse=scrollbar \
        keymap=scrollbar \
        setProp=_ft_scrollbar_setprop \
        defaults="display=inline-block orientation=vertical step=1 indicator=none"
    # Prototype-owned property classifications (the engine already classifies the
    # CSSOM scroll properties as paint; these are scrollbar-specific).
    # NO `ft_prop_kind_set orientation paint` HERE ANY MORE. It decides which AXIS this bar
    # measures itself along, and it is the same global name ft-table calls layout because it
    # changes a table's size — so whichever of the two an app built first decided it for the
    # other. Unregistered, it takes the table's conservative default, which is layout.
    ft_prop_kind_set indicator paint
    ft_prop_kind_set step paint
    # `for` IS A LAYOUT PROPERTY, and it was registered paint. It decides the bar's intrinsic
    # height (_ft_height_scrollbar reads the TARGET's measured height) and it decides whether
    # the target draws its own gutter — which changes the width its text wraps at, and so its
    # line count. Two measurements, from a name classified as if it only chose a colour.
    ft_prop_kind_set for layout
}

# A for= bar whose content currently fits draws nothing — focus must skip it
# too, or Tab lands on an invisible control.
_ft_scrollbar_focus_skip() {    # name → 0 = skip
    _ft_ctl_prop "$1" for
    [[ -z "$FT_RET" ]] && return 1
    _ft_sb_state "$1"
    (( FT_SCROLLBAR_TOTAL <= FT_SCROLLBAR_CLIENT ))
}

# Reverse registry: which bar (if any) drives each target — labels consult
# this to stand their built-in gutter down when an external bar exists.
declare -A FT_SCROLLBAR_FOR_TARGET=()
ft-scrollbar() { ft_new scrollbar "$@"; }

# THE ONE WRITER of that registry, reached from the reconciler on every route a `for` can be
# written (the constructor, ft_set, a state restore) and from the destroy hook. It used to be
# written by the CONSTRUCTOR and nowhere else:
#
#     ft-scrollbar name=sb for=logA     logA→sb   logB→<none>
#     ft_set sb for=logB             logA→sb   logB→<none>    while ft_get sb for = logB
#     ft_remove sb                      logA→sb                  …naming a control that is gone
#
# So logA drew NO scrollbar at all — its own gutter stood down for a bar that had left — while
# logB drew its gutter AND had the external bar pointing at it. Two bars on one label, none on
# the other, and a dangling reference to a removed control left in an engine table.
#
# THE UNDO READS THE REGISTRY, NOT THE PROPERTY, because `for` is exactly what has just changed
# — the rule CONTRIBUTING §1 states for FT_ACCEL_LIST, for the same reason.
_ft_scrollbar_retarget() {      # name newTarget
    local name=$1 new=$2 t
    for t in "${!FT_SCROLLBAR_FOR_TARGET[@]}"; do
        [[ "${FT_SCROLLBAR_FOR_TARGET[$t]}" == "$name" ]] || continue
        unset "FT_SCROLLBAR_FOR_TARGET[$t]"
        [[ "$t" == "$new" || -z "${FT_TYPE[$t]:-}" ]] || ft_dirty "$t"   # its own gutter is back
    done
    # …AND THE PAINT DEPENDENCY, which is the other half of what `for=` means. The bar reads the
    # target's offset and extent at DRAW time, so a target that scrolls by any route — its own
    # keys, the wheel, an app writing scrollTop, its content shrinking — has to take the bar's
    # repaint with it. Without this the pull is correct and never called, and the bar's column
    # keeps showing where the document used to be. Registered here rather than in the
    # constructor for the same reason the registry itself is: this is the one place `for=`
    # changes, on every route in and on the way out.
    ft_paint_depends_none "$name"
    if [[ -n "$new" ]]; then
        FT_SCROLLBAR_FOR_TARGET[$new]=$name
        ft_paint_depends_on "$name" "$new"
        [[ -n "${FT_TYPE[$new]:-}" ]] && ft_dirty "$new"
    fi
    return 0
}
# A removed bar takes its registry entry with it — otherwise the target it drove is marked as
# driven by a control that no longer exists, forever. (ft_remove calls _ft_destroy_<type>.)
_ft_destroy_scrollbar() { _ft_scrollbar_retarget "$1" ""; }

# A bare track has no natural content — 1 cell each way; real size comes from
# the caller's width/height like any explicitly-sized box. With for=TARGET,
# the bar's natural height is the TARGET's height (measure runs bottom-up in
# declaration order, so a target declared before its bar is already sized).
_ft_preferred_width_scrollbar()  { FT_RET=1; }
_ft_height_scrollbar() {
    _ft_ctl_prop "$1" for
    if [[ -n "$FT_RET" && -n "${FT_MEASURED_HEIGHT[$FT_RET]:-}" ]]; then
        FT_RET=${FT_MEASURED_HEIGHT[$FT_RET]}
    else
        FT_RET=1
    fi
}

# _ft_sb_target_extent TARGET → FT_SCROLLBAR_TOTAL/FT_SCROLLBAR_CLIENT derived from the target:
# total = its wrapped line count (mirroring the label's own wrap decision,
# through the same caches), client = its content-box height.
_ft_sb_target_extent() {        # target
    local tgt=$1
    # ASK THE TARGET WHAT IT PUBLISHED. scrollHeight/clientHeight are the DOM's answer to "how
    # much content, how much viewport", and every scrollable control here publishes them — a
    # container from its arrange, a label and a textfield from their draw.
    #
    # This used to re-derive them instead, by resolving the target's `text` and re-wrapping it:
    # the LABEL's content model, and only the label's. A div's content is its children, a
    # table's is its rows, a textfield's is `value` — none of them has `text` at all. So the
    # derivation measured the empty string, the bar decided the content fitted, blanked its
    # rect, focus-skipped, and refused to drag. `for=` worked for exactly ONE kind of target
    # while this file's header promised it worked "with NO glue code at all". It also walked
    # into _ft_text_extent_cached with an empty string, which until this commit was a fatal
    # unbound variable in a `set -u` app.
    local sh ch
    _ft_get_raw "$tgt" scrollHeight; sh=$FT_RET
    _ft_get_raw "$tgt" clientHeight; ch=$FT_RET
    case $sh in ''|*[!0-9]*) sh="" ;; esac
    case $ch in ''|*[!0-9]*) ch="" ;; esac
    if [[ -n "$sh" && -n "$ch" ]] && (( ch > 0 )); then
        FT_SCROLLBAR_TOTAL=$sh; FT_SCROLLBAR_CLIENT=$ch
        return 0
    fi
    # …and the fallback, for a target asked about BEFORE its first paint — a label and a
    # textfield publish from the draw — or one that publishes nothing at all. Measuring the
    # target's own text is right for the control kind that has text, and no worse than what
    # this function always did for the ones that do not.
    ft_resolved_prop "$tgt" text; local ttext=$FT_RET
    _ft_text_extent_cached "$tgt" "$ttext"
    local tinset; _ft_inset "$tgt"; tinset=$FT_RET
    local tcw=$(( ${FT_MEASURED_WIDTH[$tgt]:-0} - 2*tinset )); (( tcw < 0 )) && tcw=0
    FT_SCROLLBAR_TOTAL=$FT_TEXT_HEIGHT
    if (( FT_TEXT_WIDTH > tcw && tcw > 0 )); then
        ft_wrap_cached "$tgt" "$ttext" "$tcw"
        FT_SCROLLBAR_TOTAL=${#FT_WRAP_LINES[@]}
    fi
    FT_SCROLLBAR_CLIENT=$(( ${FT_MEASURED_HEIGHT[$tgt]:-1} - 2*tinset ))
    (( FT_SCROLLBAR_CLIENT < 1 )) && FT_SCROLLBAR_CLIENT=1
}

# _ft_sb_state NAME — resolve the axis-specific properties into one shape:
#   FT_SCROLLBAR_POSITION FT_SCROLLBAR_TOTAL FT_SCROLLBAR_CLIENT  (numbers)
#   FT_SCROLLBAR_POSITION_PROP                 (which property holds the offset)
#   FT_SCROLLBAR_TRACK                   (thumb track cells, after any indicator row)
#   FT_SCROLLBAR_INDICATOR_ROW                     (1 if an indicator row is reserved)
#   FT_SCROLLBAR_HORIZONTAL                   (1 if horizontal)
_ft_sb_state() {                # name
    local name=$1
    ft_resolved_prop "$name" orientation vertical
    local posP totP cliP len
    if [[ "$FT_RET" == horizontal ]]; then
        FT_SCROLLBAR_HORIZONTAL=1; posP=scrollLeft; totP=scrollWidth; cliP=clientWidth
        len=${FT_MEASURED_WIDTH[$name]:-0}
    else
        FT_SCROLLBAR_HORIZONTAL=0; posP=scrollTop; totP=scrollHeight; cliP=clientHeight
        len=${FT_MEASURED_HEIGHT[$name]:-0}
    fi
    FT_SCROLLBAR_INDICATOR_ROW=0
    ft_resolved_prop "$name" indicator none
    [[ "$FT_RET" == percentage ]] && (( ! FT_SCROLLBAR_HORIZONTAL )) && (( len >= 2 )) && FT_SCROLLBAR_INDICATOR_ROW=1
    FT_SCROLLBAR_TRACK=$(( len - FT_SCROLLBAR_INDICATOR_ROW ))
    (( FT_SCROLLBAR_TRACK < 1 )) && FT_SCROLLBAR_TRACK=1
    FT_SCROLLBAR_POSITION_PROP=$posP
    _ft_ctl_prop "$name" for; FT_SCROLLBAR_TARGET=$FT_RET
    if [[ -n "$FT_SCROLLBAR_TARGET" && -n "${FT_TYPE[$FT_SCROLLBAR_TARGET]:-}" ]]; then
        _ft_sb_target_extent "$FT_SCROLLBAR_TARGET"     # sets FT_SCROLLBAR_TOTAL / FT_SCROLLBAR_CLIENT
    else
        FT_SCROLLBAR_TARGET=""
        ft_resolved_prop "$name" "$totP" 0; FT_SCROLLBAR_TOTAL=${FT_RET:-0}
        ft_resolved_prop "$name" "$cliP" ""; FT_SCROLLBAR_CLIENT=$FT_RET
        [[ -z "$FT_SCROLLBAR_CLIENT" ]] && FT_SCROLLBAR_CLIENT=$FT_SCROLLBAR_TRACK
        (( FT_SCROLLBAR_CLIENT < 1 )) && FT_SCROLLBAR_CLIENT=1
    fi
    # A for= BAR HAS NO POSITION OF ITS OWN — it shows the target's. The target can scroll by
    # routes the bar never hears about (its own keys, the wheel, an app writing scrollTop on it),
    # and reading a private copy meant the thumb stayed wherever the bar was last dragged to
    # while the content moved underneath. The bar's own property is still where a WRITE lands;
    # the reconciler takes that value from the write itself and pushes it to the target, which
    # is what makes this the one number both of them read.
    if [[ -n "$FT_SCROLLBAR_TARGET" ]]; then
        _ft_get_raw "$FT_SCROLLBAR_TARGET" "$posP"
        case $FT_RET in ''|*[!0-9]*) FT_RET=0 ;; esac
        FT_SCROLLBAR_POSITION=$FT_RET
        # …and the bar's own copy is kept level with it, so `ft_get bar scrollTop` answers what
        # the bar is SHOWING rather than what was last written at it. Stamped rather than set —
        # this runs inside the reconciler too — and only when they differ, because this is also
        # on the draw path.
        local own="_ftp_${name}_${posP}"
        [[ "${!own:-}" == "$FT_SCROLLBAR_POSITION" ]] || _ft_stamp_prop "$name" "$posP" "$FT_SCROLLBAR_POSITION"
        return 0
    fi
    ft_resolved_prop "$name" "$posP" 0; FT_SCROLLBAR_POSITION=${FT_RET:-0}
}

# ft_scrollbar_percent NAME → FT_RET = 0-100, the share of the document SEEN
# (last visible line over total). Content that fits entirely reads 100.
ft_scrollbar_percent() {        # name
    local name=$1
    _ft_sb_state "$name"
    if (( FT_SCROLLBAR_TOTAL <= FT_SCROLLBAR_CLIENT || FT_SCROLLBAR_TOTAL <= 0 )); then FT_RET=100; return; fi
    local pct=$(( (FT_SCROLLBAR_POSITION + FT_SCROLLBAR_CLIENT) * 100 / FT_SCROLLBAR_TOTAL ))
    (( pct > 100 )) && pct=100
    FT_RET=$pct
}

# THE OFFSET IS THE STATE, so writing it does the work — clamp to [0, max(0, total-client)],
# keep a for= target's own offset in sync, repaint, and call onScroll=fn. All of that lived in
# ft_scrollbar_set and only there, so the two spellings of one job disagreed completely:
#
#     ft_scrollbar_set sb 7      bar=7   target=7          onScroll fired
#     ft_set sb scrollTop=7   bar=7   target=<unset>    onScroll never fired
#
# …and the property route is the one an app reaches for, the one ft-state restores through, and
# the one the header of this file documents. Same shape as label.scrollTop, one control over.
_ft_scrollbar_setprop() {       # name prop value previous
    local name=$1 prop=$2
    case $prop in
        for)                  _ft_scrollbar_retarget "$name" "$3"; return 0 ;;
        scrollTop|scrollLeft) : ;;
        *)                    return 0 ;;
    esac
    # Before the first layout there is no track and no target geometry, and clamping against
    # that pins every offset to 0 — the same reason _ft_clamp_scroll skips an unknown pair.
    (( ${FT_MEASURED_HEIGHT[$name]:-0} > 0 || ${FT_MEASURED_WIDTH[$name]:-0} > 0 )) || return 0
    _ft_sb_state "$name"
    [[ "$prop" == "$FT_SCROLLBAR_POSITION_PROP" ]] || return 0   # the other axis's name is inert here
    local maxv=$(( FT_SCROLLBAR_TOTAL - FT_SCROLLBAR_CLIENT )); (( maxv < 0 )) && maxv=0
    # THE VALUE JUST WRITTEN, not what the state reports: for a for= bar FT_SCROLLBAR_POSITION is
    # the TARGET's offset, which is precisely the thing this write is about to change.
    local v=$3
    case $v in ''|*[!0-9-]*|-*-*|-) v=0 ;; esac
    (( v < 0 )) && v=0
    (( v > maxv )) && v=$maxv
    # UNCONDITIONALLY, AND AFTER _ft_sb_state: that call keeps a for= bar's own copy level with
    # its target, which for the duration of THIS write means level with where the target still
    # is. Stamping only "when the clamp changed something" left the write itself undone.
    _ft_stamp_prop "$name" "$prop" "$v"
    # DID IT ACTUALLY MOVE? `scrollTop=99` on a bar already at its maximum of 8 is a change to
    # everything upstream and no change at all here, and firing onScroll for it would be a
    # scroll event for a scroll that did not happen. Only the previous value can say, which is
    # why _ft_setprop hands it over.
    [[ "${4-}" == "$v" ]] && return 0
    ft_dirty "$name"
    # The target's offset is the SAME axis as the bar's, not always scrollTop — a horizontal bar
    # was syncing its target's vertical offset.
    [[ -n "$FT_SCROLLBAR_TARGET" ]] && ft_set "$FT_SCROLLBAR_TARGET" "$prop=$v"
    _ft_hook "$name" on_scroll "$v"        # $this=name, $1=new offset
    return 0
}

# ft_scrollbar_set NAME OFFSET — the verb, and now nothing but the property write it always
# should have been. The clamp, the sync and the hook live in the reconciler above, where every
# route reaches them.
ft_scrollbar_set() {
    _ft_sb_state "$1"
    ft_set "$1" "$FT_SCROLLBAR_POSITION_PROP=$2"
    return 0
}
ft_scrollbar_scroll() {         # name delta
    local name=$1 delta=$2
    _ft_sb_state "$name"
    ft_scrollbar_set "$name" "$(( FT_SCROLLBAR_POSITION + delta ))"
}

# Class keymap actions — invoked as `action NAME TOKEN` by dispatch.
ft_scrollbar_key_prev()   { ft_resolved_prop "$1" step 1; ft_scrollbar_scroll "$1" "-${FT_RET}"; }
ft_scrollbar_key_next()   { ft_resolved_prop "$1" step 1; ft_scrollbar_scroll "$1" "${FT_RET}"; }
ft_scrollbar_key_pgprev() { _ft_sb_state "$1"; ft_scrollbar_scroll "$1" "-${FT_SCROLLBAR_CLIENT}"; }
ft_scrollbar_key_pgnext() { _ft_sb_state "$1"; ft_scrollbar_scroll "$1" "${FT_SCROLLBAR_CLIENT}"; }
ft_scrollbar_key_home()   { ft_scrollbar_set "$1" 0; }
ft_scrollbar_key_end()    { _ft_sb_state "$1"; ft_scrollbar_set "$1" "$FT_SCROLLBAR_TOTAL"; }

# ft_scrollbar_paint NAME ROW COL TRACKLEN HORIZ TOTAL CLIENT POS — paint a proportional
# thumb on a track. THE one place a scrollbar is drawn: the scrollbar CONTROL calls it, and
# so does the scroll gutter a container reserves for overflow=auto (_ft_scroll_gutter_draw).
# Before this existed the gutter had its own private renderer with different glyphs and
# colours, so the same app showed two different-looking scrollbars — and only one of them
# answered to the theme or to `::scrollbar` / `::track`.
#
# NAME is used only to resolve those pseudo-elements and the focus accent, so a container
# styles its gutter exactly as a scrollbar control styles its bar.
ft_scrollbar_paint() {          # name row col tracklen horiz total client pos
    local name=$1 row=$2 col=$3 track=$4 horiz=$5 total=$6 client=$7 pos=$8
    (( track > 0 )) || return 0

    local maxv=$(( total - client )); (( maxv < 0 )) && maxv=0
    local value=$pos
    (( value < 0 )) && value=0
    (( value > maxv )) && value=$maxv
    local thumbLen thumbStart
    if (( total <= client )); then
        thumbLen=$track; thumbStart=0
    else
        thumbLen=$(( track * client / total )); (( thumbLen < 1 )) && thumbLen=1
        local maxstart=$(( track - thumbLen )); (( maxstart < 0 )) && maxstart=0
        thumbStart=$(( maxv > 0 ? maxstart * value / maxv : 0 ))
    fi

    local trackGlyph=$FT_GLYPH_VERTICAL; (( horiz )) && trackGlyph=$FT_GLYPH_HORIZONTAL
    # Themed focus indicator: FT_COLOR_FOCUS accent while focused, FT_COLOR_THUMB otherwise —
    # visibly different states, both theme-overridable.
    local thumbsgr=$FT_COLOR_THUMB
    [[ "${FT_FOCUS:-}" == "$name" ]] && thumbsgr=$FT_COLOR_FOCUS
    _ft_css_pe_or "$name" scrollbar "$thumbsgr"; thumbsgr=$FT_RET   # `::scrollbar` (the thumb)
    local tracksgr; _ft_css_pe_or "$name" track "$FT_COLOR_DIVIDER"; tracksgr=$FT_RET   # `::track`

    # The thumb is a BACKGROUND-COLOURED CELL where colour exists: it fills the cell edge to
    # edge, so a horizontal bar reads exactly as thick as a vertical one — which the old
    # █ / ━ pair never did (━ is a thin rule, █ a full block).
    # Without colour that cell would be an invisible space, so fall back to the solid glyphs
    # already chosen for this job. Same geometry either way; only the ink changes.
    local thumbGlyph=' '
    if [[ -z "$thumbsgr" ]]; then
        if (( horiz )); then thumbGlyph='━'; else thumbGlyph='█'; fi
    fi
    local i sgr ch
    for (( i=0; i<track; i++ )); do
        if (( i >= thumbStart && i < thumbStart + thumbLen )); then sgr=$thumbsgr; ch=$thumbGlyph
        else sgr=$tracksgr; ch=$trackGlyph; fi
        if (( horiz )); then ft_print_at_width "$row" $(( col + i )) "$sgr$ch$FT_COLOR_RESET" 1
        else                 ft_print_at_width $(( row + i )) "$col" "$sgr$ch$FT_COLOR_RESET" 1; fi
    done
}

# ft_scrollbar_pos_from_point NAME TRACKSTART TRACKLEN TOTAL CLIENT POINT → FT_RET = the
# scroll offset that puts the thumb under POINT (a screen row for a vertical bar, a column
# for a horizontal one). Shared by the control's mouse handler and a container's gutter, so
# grabbing either behaves identically.
ft_scrollbar_pos_from_point() { # name trackstart tracklen total client point
    local start=$2 track=$3 total=$4 client=$5 point=$6
    local maxv=$(( total - client )); (( maxv < 0 )) && maxv=0
    local thumbLen=$track
    (( total > client )) && { thumbLen=$(( track * client / total )); (( thumbLen < 1 )) && thumbLen=1; }
    # Centre the thumb on the pointer, then map its travel back to a scroll offset.
    local travel=$(( track - thumbLen )); (( travel < 1 )) && { FT_RET=0; return 0; }
    local at=$(( point - start - thumbLen / 2 ))
    (( at < 0 )) && at=0
    (( at > travel )) && at=$travel
    FT_RET=$(( at * maxv / travel ))
}

# A scrollbar you cannot grab is barely a scrollbar. press and drag both map the pointer to
# a position through the shared helper, so dragging the thumb and clicking the bare track do
# the same thing — as in every desktop scrollbar.
_ft_mouse_scrollbar() {         # name action absx absy
    local name=$1 action=$2 x=$3 y=$4
    case "$action" in press|drag) : ;; *) return 0 ;; esac
    _ft_sb_state "$name"
    (( FT_SCROLLBAR_TOTAL > FT_SCROLLBAR_CLIENT )) || return 0          # nothing to scroll: let the click be
    local start point
    if (( FT_SCROLLBAR_HORIZONTAL )); then start=${FT_ABSOLUTE_X[$name]:-0}; point=$x
    else                    start=${FT_ABSOLUTE_Y[$name]:-0}; point=$y; fi
    ft_scrollbar_pos_from_point "$name" "$start" "$FT_SCROLLBAR_TRACK" "$FT_SCROLLBAR_TOTAL" "$FT_SCROLLBAR_CLIENT" "$point"
    local target=$FT_RET        # SAVE IT: ft_focus sets FT_RET, so reading it after is too late
    ft_focus "$name"
    ft_scrollbar_set "$name" "$target"
    return 0
}

_ft_draw_scrollbar() {                   # name
    local name=$1
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local cols=${FT_MEASURED_WIDTH[$name]:-0} rows=${FT_MEASURED_HEIGHT[$name]:-0}
    (( cols < 1 || rows < 1 )) && return

    _ft_sb_state "$name"
    # AN OLD OFFSET MAY NOW BE OUT OF RANGE. The offset is clamped at the write, but nothing
    # writes it when the DOCUMENT UNDER IT changes: replace a 20-line target's text with one
    # line and the bar went on holding 16 against a maximum of 0, while the target — which
    # re-clamps its own on this same path — had gone back to 0. Two numbers for one scroll
    # position, disagreeing. Written back through the setter rather than corrected here, so the
    # clamp, the target sync and onScroll stay in the one place that owns them (the shape
    # _ft_label_metrics already uses), and through _ft_setprop rather than ft_set because the
    # value being written is the stale one and ft_set skips a write it thinks is a no-op.
    # Only when it is actually wrong: this runs on the draw path. The scroll event that follows
    # is a real one — the view moved, because the content did.
    local _sbmax=$(( FT_SCROLLBAR_TOTAL - FT_SCROLLBAR_CLIENT )); (( _sbmax < 0 )) && _sbmax=0
    if (( FT_SCROLLBAR_POSITION > _sbmax || FT_SCROLLBAR_POSITION < 0 )); then
        _ft_setprop "$name" "$FT_SCROLLBAR_POSITION_PROP" "$FT_SCROLLBAR_POSITION"
        _ft_sb_state "$name"
    fi
    local track=$FT_SCROLLBAR_TRACK

    # for= bars are overflow:auto — content that fits entirely means no bar
    # at all: blank the rect (keeping the reserved column, so layout is
    # stable when it appears) and draw nothing else.
    if [[ -n "$FT_SCROLLBAR_TARGET" ]] && (( FT_SCROLLBAR_TOTAL <= FT_SCROLLBAR_CLIENT )); then
        ft_fit "" "$cols"
        local rr
        for (( rr=0; rr<rows; rr++ )); do
            ft_print_at $(( row + rr )) "$col" "$FT_COLOR_BODY$FT_FIT$FT_COLOR_RESET"
        done
        return
    fi

    ft_scrollbar_paint "$name" "$row" "$col" "$track" "$FT_SCROLLBAR_HORIZONTAL" \
                       "$FT_SCROLLBAR_TOTAL" "$FT_SCROLLBAR_CLIENT" "$FT_SCROLLBAR_POSITION"

    if (( FT_SCROLLBAR_INDICATOR_ROW )); then
        ft_scrollbar_percent "$name"
        ft_fit "${FT_RET}%" "$cols"
        ft_print_at $(( row + track )) "$col" "$FT_COLOR_BODY$FT_FIT$FT_COLOR_RESET"
    fi
}
