#!/usr/bin/env bash
# Tests for controls/ft-statusbar.bash: the one-row SYNOPSIS bar (the key legend is now a
# separate control, ft-keylegend). Covers the 1-row height, non-focusable, a status= that
# accepts spaces, the mode-hint takeover, and the transient "Copied" queue.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=80; FT_ROWS=24

# strip CSI/OSC so we can assert on the visible glyphs a row paints
_vis() { LC_ALL=C sed -E $'s/\x1b\\][^\x07]*\x07//g; s/\x1b\\[[0-9;]*[A-Za-z]//g' ; }

note "the control is a one-row, non-focusable block"
ft_prototype_init statusbar          # lazy init otherwise waits for the first instance
check "height is 1"     "$(_ft_height_statusbar; echo "$FT_RET")" "1"
check "class not focusable" "${FT_PROTO_FOCUSABLE[statusbar]}" "0"

note "status= accepts a value containing spaces (registered prop)"
ft-form name=root width=80 height=6
  ft-statusbar name=bar status="Ready.  3 items."
end_ft_form
ft_layout root
_ft_get_raw bar status; check "status stored with spaces" "$FT_RET" "Ready.  3 items."
check "bar laid out 1 tall" "${FT_MEASURED_HEIGHT[bar]}" "1"

note "the synopsis paints its text"
FT_OUT=""; _ft_draw_statusbar bar
vis=$(printf '%s' "$FT_OUT" | _vis)
[[ "$vis" == *"Ready.  3 items."* ]] && check "status painted" 1 1 || check "status painted" 0 1

note "ft_set updates the synopsis live (paint-only, no reflow)"
ft_set bar status="Deleting report.txt…"
_ft_get_raw bar status; check "status updated" "$FT_RET" "Deleting report.txt…"
FT_OUT=""; _ft_draw_statusbar bar
vis=$(printf '%s' "$FT_OUT" | _vis)
[[ "$vis" == *"Deleting report.txt…"* ]] && check "new status painted" 1 1 || check "new status painted" 0 1

note "a MODE (FT_MODE_HINT) makes the synopsis become the exit hint, in caution amber"
ft_set bar status="Ready."
FT_MODE_HINT="Press ESC to exit edit mode and return to navigation."
FT_OUT=""; _ft_draw_statusbar bar
vis=$(printf '%s' "$FT_OUT" | _vis | tr -s ' ')
[[ "$vis" == *"Press ESC to exit edit mode"* ]] && check "the synopsis becomes the exit hint" 1 1 \
                                                || check "the synopsis becomes the exit hint" 0 1
[[ "$FT_OUT" == *"38;5;214"* ]] && check "the hint is painted in caution amber" 1 1 \
                                || check "the hint is painted in caution amber" 0 1
FT_MODE_HINT=""   # back to navigation

note "ft_set_mode_hint publishes the hint and dirties the status bar(s)"
ft_clean bar; ft_set_mode_hint "in a mode"
ft_is_dirty bar && check "setting a hint dirties the bar" 1 1 || check "setting a hint dirties the bar" 0 1
check "...and publishes it" "$FT_MODE_HINT" "in a mode"
ft_clean bar; ft_set_mode_hint "in a mode"    # unchanged
ft_is_dirty bar && check "an unchanged hint does NOT re-dirty" 0 1 || check "an unchanged hint does NOT re-dirty" 1 1
ft_set_mode_hint ""

# ── Transient status queue (the "Copied" feedback) ───────────────────────────
note "a bar declares per-event messages with the SUBSCRIPTED text[event] property"
ft-form name=root2 width=80 height=6
  ft-statusbar name=sb status="Ready." \
      text[textCopied]="Selected text copied to clipboard.,2,8" \
      text[saved]="Saved."
end_ft_form
ft_layout root2
_ft_get_raw sb "text[textCopied]"; check "subscripted prop round-trips through the DSL" \
    "$FT_RET" "Selected text copied to clipboard.,2,8"
check "and lands in a bash-safe storage var" "${_ftp_sb_text__textCopied:-MISSING}" \
    "Selected text copied to clipboard.,2,8"

note "an empty queue yields NO transient (ft_now_ms must not leak a stamp into FT_RET)"
_ft_sb_transient sb; check "drained queue → empty message" "$FT_RET" ""

note "firing the event enqueues its declared message; a transient out-ranks the base status"
FT_STATUSBAR_LAST_SYNOPSIS=()   # forget any prior synopsis so the change is seen
ft_status_event sb textCopied
check "the event enqueued one entry" "${FT_STATUSBAR_QUEUE[sb]:+queued}" "queued"
FT_OUT=""; _ft_draw_statusbar sb
vis=$(printf '%s' "$FT_OUT" | _vis)
[[ "$vis" == *"Selected text copied to clipboard."* ]] && check "transient painted over the base status" 1 1 \
                                                       || check "transient painted over the base status" 0 1
[[ "$FT_OUT" == *"38;5;120"* ]] && check "transient painted in success green" 1 1 \
                                || check "transient painted in success green" 0 1
[[ "$vis" != *"Ready."* ]] && check "the base status is suppressed while the transient shows" 1 1 \
                           || check "the base status is suppressed while the transient shows" 0 1

note "an unknown event, or a bar that never declared it, is a silent no-op"
ft_status_event sb neverDeclared && check "undeclared event returns non-zero" 0 1 \
                                 || check "undeclared event returns non-zero" 1 1

note "ft_emit_status broadcasts to every bar that declared the event"
FT_STATUSBAR_QUEUE=(); FT_STATUSBAR_HEAD=()
ft_emit_status saved
_ft_get_raw dummy x >/dev/null 2>&1
[[ "${FT_STATUSBAR_QUEUE[sb]:-}" == *"Saved."* ]] && check "broadcast reached the declaring bar" 1 1 \
                                           || check "broadcast reached the declaring bar" 0 1

note "the queue drops entries that waited past their max-alive, and shows the next in FIFO order"
FT_STATUSBAR_QUEUE=(); FT_STATUSBAR_HEAD=()
ft_now_ms; past=$(( FT_RET - 1000 )); future=$(( FT_RET + 60000 ))
printf -v 'FT_STATUSBAR_QUEUE[sb]' '%s\t2000\tStale.\n%s\t2000\tFresh.\n' "$past" "$future"
_ft_sb_transient sb
check "the expired entry is skipped, the live one shows" "$FT_RET" "Fresh."
check "...and becomes the held head"                     "${FT_STATUSBAR_HEAD[sb]}" "Fresh."
[[ "${FT_STATUSBAR_QUEUE[sb]}" != *"Stale."* ]] && check "the expired entry was removed from the queue" 1 1 \
                                         || check "the expired entry was removed from the queue" 0 1

note "a host can register its OWN event with ft_prop_kind_set on a subscripted name"
ft_prop_kind "text[myEvent]"; check "unregistered subscripted prop defaults to layout" "$FT_RET" "layout"
ft_prop_kind_set "text[myEvent]" paint
ft_prop_kind "text[myEvent]"; check "...and registers as paint once set" "$FT_RET" "paint"

summary
