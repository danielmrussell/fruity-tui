#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — controls/ft-statusbar.bash
#
#  The STATUS ROW: a one-row block leaf showing what the app is doing or has just
#  done. One concern, one control.
#
#      ft-statusbar name=bar status="Ready."
#
#  Update it live:  ft-modify bar status="Deleting report.txt…"
#
#  It used to be a TWO-row control that also drew the key legend. The legend is now
#  its own control (controls/ft-keylegend.bash) so a handler updating the status can
#  never paint over the caps and vice-versa. Stack them for the classic two-row bar:
#
#      ft-keylegend name=legend keys="Enter=Open  Esc=Cancel"   # on top
#      ft-statusbar name=bar    status="Ready."                 # below
#
#  There is therefore no keys= here. It is rejected at construction rather than
#  silently stored — `keys` is a globally registered property, so an unguarded
#  statusbar would accept it, keep it, and never draw it.
#
#  Transient messages (ft_status_flash / ft_status_event / ft_emit_status) queue
#  through this control: each is shown for a MINIMUM time before the next may
#  replace it, and dropped if it waits past a MAXIMUM. See the queue section below.
#
#  A block leaf, exactly 1 row tall, never focusable. Colours resolve through the
#  cascade — `statusbar { … }` tints the strip, `statusbar::hint { … }` the text —
#  falling back to the theme roles FT_COLOR_STATUS / FT_COLOR_HINT.
#
#  Depends on ft-core.bash and ft-forms.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_STATUSBAR_LOADED:-}" ]] && return 0
_FT_STATUSBAR_LOADED=1

# How long the mode sweep waits between nags. It was 300 cells of padded animation length,
# which at step 3 and 25ms a frame is 100 frames — 2.5 seconds expressed in the wrong unit,
# and paid for at a wake and a full bar repaint per frame. Stated as time, it is free.
_FT_STATUSBAR_MODE_REST_MS=2500

_FT_STATUSBAR_SWEEP_WIDTH_DEFAULT=10              # default width, in cells, of the travelling bold
                                # crest — the `sweepWidth` property overrides it.
                                # MUST stay >= FT_ANIM_SPEED: a crest that advances
                                # farther per frame than it is wide leaves gaps and
                                # reads as flashing text, not a wave.

# Last synopsis painted per bar — a CHANGE is what fires the attention sweep.
# MUST be declare -A: a bare array would evaluate the control name as arithmetic
# and collapse every bar onto slot 0.
declare -A FT_STATUSBAR_LAST_SYNOPSIS=()

# ── Transient status queue ────────────────────────────────────────────────────
# "Copied", "Saved", … — a status the user must actually SEE, not a flash gone before
# the eye lands on it. Each transient is shown for a MINIMUM time before the next may
# replace it (a FIFO queue enforces that), and is dropped if it waits past a MAXIMUM
# without getting its turn. While a transient is up it out-ranks the mode hint and the
# base status; when the queue drains, the bar falls back to those. Entry format:
#   "deadlineMs<TAB>minMs<TAB>message"   (deadline = enqueue + max-alive)
declare -A FT_STATUSBAR_QUEUE=()    # name → newline-separated entries still waiting/showing
declare -A FT_STATUSBAR_HEAD=()     # name → the message currently being shown (or unset)

# ft_status_flash NAME MESSAGE [MIN_SECONDS] [MAX_SECONDS] — enqueue a transient status.
# MIN (default 2s) is how long it is guaranteed to stay up; MAX (default 8s) is how long
# it will wait in line before giving up. The bar starts ticking so the queue advances.
#
# A DURATION IS A NUMBER OR IT IS THE DEFAULT — it is never evaluated. These arrive from a
# bar's `text[EVENT]="message,minS,maxS"` property, which is app text, and app text reaching
# bash arithmetic is how a value gets EXECUTED: `text[saved]="Saved,q[$(cmd)],8"` ran the
# command, because `(( ))` evaluates an array subscript. `2 3` was a syntax error printed
# over the running UI. Same lesson as the geometry properties (_FT_NUMERIC_PROP); this path
# was missed because the PROPERTY is a string and only its middle fields are numbers.
_ft_sb_seconds() {              # value default → FT_RET (a plain integer, 0…9999)
    case "${1-}" in
        ''|*[!0-9]*) FT_RET=$2; return ;;       # not a non-negative integer (a negative
    esac                                        # duration is not a duration either)
    (( ${#1} > 4 )) && { FT_RET=$2; return; }   # …nor is two and a half hours
    FT_RET=$1
}
ft_status_flash() {             # name message [min_s] [max_s]
    [[ "${FT_TYPE[$1]:-}" == statusbar ]] || return 1
    ft_now_ms; local now=$FT_RET
    _ft_sb_seconds "${3-}" 2; local min=$(( FT_RET * 1000 ))
    _ft_sb_seconds "${4-}" 8; local max=$(( FT_RET * 1000 ))
    # The queue is TAB-and-newline framed, so a message carrying either would BE extra
    # fields and extra entries — the parse below would then read a fragment of a sentence
    # as a deadline. A status line is one line by definition; flatten it and the framing
    # cannot be broken by what an app chooses to say.
    local msg=${2//$'\n'/ }; msg=${msg//$'\t'/ }
    FT_STATUSBAR_QUEUE[$1]+="$(( now + max ))"$'\t'"$min"$'\t'"$msg"$'\n'
    ft_dirty "$1"; return 0
}
# WHAT AN EVENT SAYS WHEN NOBODY SAID. A bar that declares nothing for an event used to
# show nothing for it — so `text[saved]` existed as a registered property, no bar in the
# tree ever set it, and a successful save was silent everywhere. An app overriding the
# wording is the exception; having wording at all is the rule, so the wording lives here
# and `text[EVENT]` overrides it. Same format: "message,minSecs,maxSecs".
declare -A FT_STATUS_TEXT=(
    [saved]="Saved"
    [saveFailed]="Could not save"
    [textCopied]="Copied"
    [itemCopied]="Copied"
    # A copy the terminal would not take — nothing selected, no base64 to encode with, or
    # more than an OSC 52 string can carry. Saying "Copied" anyway is the same lie as a
    # silent save: the user pastes and gets whatever was there before.
    [copyFailed]="Could not copy"
    [copyTooLarge]="Too much to copy"
    # Ctrl+C pressed where there is nothing to copy. It used to QUIT here, which is the one
    # thing reaching for copy must never do; now it says what to do instead.
    [copyNothing]="Select something first, then copy"
)
# ft_status_event NAME EVENT — the DECLARATIVE path: flash whatever the bar declared for
# this event in its `text[EVENT]="message,minS,maxS"` property (min/max optional), else
# the framework default above. This is how a copy/save/etc. wires to the bar without the
# emitter knowing the wording.
ft_status_event() {             # name event
    _ft_get_raw "$1" "text[$2]"; local spec=$FT_RET
    [[ -z "$spec" ]] && spec=${FT_STATUS_TEXT[$2]:-}
    [[ -z "$spec" ]] && return 1
    local msg=${spec%%,*} rest=${spec#*,} min max
    # `message,minS,maxS` means rest is `minS,maxS` — ONE comma. The test was `*,*,*`, two
    # commas, which the documented three-field form never has, so maxS was silently dropped
    # and every message used the default 8s however long the app said to wait. The field was
    # documented, registered and parsed, and did nothing.
    [[ "$rest" != "$spec" ]] && { min=${rest%%,*}; [[ "$rest" == *,* ]] && max=${rest##*,}; }
    ft_status_flash "$1" "$msg" ${min:+"$min"} ${max:+"$max"}
}
# ft_emit_status EVENT [DETAIL] — broadcast: fire EVENT at EVERY status bar, so a control
# (a text field's copy, the engine's Ctrl+S) can announce without knowing which bar, or if
# any. WHEN THERE IS NO BAR IT STILL HAS TO SAY SOMETHING: an app is not required to have
# a status bar, and "the confirmation appears only if you added one" leaves the same
# silent-success hole. So the engine's own toast line is the floor — see ft_toast.
# DETAIL is appended to the fallback wording only (a bar's message is the bar's business);
# it is where a path or a count goes: "Saved → ~/.local/state/…".
ft_emit_status() {              # event [detail]
    local c shown=0
    for c in "${!FT_TYPE[@]}"; do
        [[ "${FT_TYPE[$c]}" == statusbar ]] && ft_status_event "$c" "$1" && shown=1
    done
    (( shown )) && return 0
    local msg=${FT_STATUS_TEXT[$1]:-}; msg=${msg%%,*}
    [[ -z "$msg" ]] && return 1
    [[ -n "${2:-}" ]] && msg="$msg → $2"
    declare -F ft_toast >/dev/null && ft_toast "$msg"
    return 0
}
# _ft_sb_transient NAME → FT_RET = the transient message to show (or ""), and
# _FT_STATUSBAR_TRANSIENT_HOLD = how many sweep-cells to hold it. Advances the queue: the head is
# held until its MIN time is up (its hold animation retires), then popped; entries that
# waited past their MAX are dropped unshown.
_FT_STATUSBAR_TRANSIENT_HOLD=0
_ft_sb_transient() {            # name
    FT_RET=""; _FT_STATUSBAR_TRANSIENT_HOLD=0
    local n=$1 now; ft_now_ms; now=$FT_RET
    if [[ -n "${FT_STATUSBAR_HEAD[$n]:-}" ]]; then
        ft_anim_phase "$n"
        (( FT_RET >= 0 )) && { FT_RET=${FT_STATUSBAR_HEAD[$n]}; return; }   # still within its min time
        FT_STATUSBAR_QUEUE[$n]=${FT_STATUSBAR_QUEUE[$n]#*$'\n'}                    # min elapsed → pop the head
        unset "FT_STATUSBAR_HEAD[$n]"
    fi
    local q=${FT_STATUSBAR_QUEUE[$n]:-} line deadline
    # THE LOOP CONDITION IS THE THING THAT MAKES IT SHRINK. It used to be `[[ -n "$q" ]]`
    # while the body advanced with `${q#*$'\n'}` — which returns the string UNCHANGED when
    # there is no newline in it. A queue holding a fragment with no terminator therefore
    # span forever, with the whole UI frozen behind it. Looping on "is there another line"
    # makes progress structural: the body cannot run unless the cut has something to cut.
    while [[ "$q" == *$'\n'* ]]; do          # drop entries that waited past their max-alive
        line=${q%%$'\n'*}; deadline=${line%%$'\t'*}
        # …and a deadline is only a deadline if it is a number. Anything else is a damaged
        # entry, not a time; drop it rather than hand it to (( )), which would evaluate it.
        case "$deadline" in
            ''|*[!0-9]*) q=${q#*$'\n'}; continue ;;
        esac
        (( deadline < now )) && { q=${q#*$'\n'}; continue; }
        break
    done
    [[ "$q" == *$'\n'* ]] || q=""             # a trailing fragment is not an entry
    FT_STATUSBAR_QUEUE[$n]=$q
    [[ -z "$q" ]] && { FT_RET=""; return; }   # queue drained — ft_now_ms left a stamp in FT_RET; clear it
    line=${q%%$'\n'*}; local rest=${line#*$'\t'}
    local min=${rest%%$'\t'*} msg=${rest#*$'\t'}
    case "$min" in ''|*[!0-9]*) min=0 ;; esac  # never reaches (( )) unvalidated
    FT_STATUSBAR_HEAD[$n]=$msg
    _FT_STATUSBAR_TRANSIENT_HOLD=$(( min * 8 / 20 ))        # hold cells (engine default 20ms/frame, step 8)
    FT_RET=$msg
}

ft_class_statusbar() {
    # A status bar is never a focus stop — Tab always skips it.
    ft_class extends=ft_control focusable=false defaults="display=block status= importance=crucial"
    # Register the custom prop so the arg parser accepts a value that CONTAINS SPACES (a
    # synopsis obviously does); otherwise `status="a b"` would be mistaken for bare content.
    # Paint-only — updating it repaints the bar without reflowing the page.
    ft_prop_kind_set status paint
    ft_prop_kind_set sweepWidth paint   # cells of the attention sweep's bold crest
    # Per-event transient messages: text[<event>]="message,minSecs,maxSecs" (the times
    # optional). Firing the event (ft_status_event / ft_emit_status) flashes the message
    # through the queue. Register the events we ship a default reaction for; a host can
    # register its own with ft_prop_kind_set "text[myEvent]" paint.
    ft_prop_kind_set "text[textCopied]" paint
    ft_prop_kind_set "text[itemCopied]" paint
    ft_prop_kind_set "text[saved]"      paint
}

# `keys` is registered globally (by the keylegend class), so a statusbar would happily
# accept, store and never draw it — the silent no-op this control's own docs used to
# recommend. Reject it at construction and name the replacement.
ft-statusbar() {
    local a
    for a in "$@"; do
        case "$a" in
            keys=*) printf 'ft: statusbar has no keys= — the key legend is a separate control.\n' >&2
                    printf '    Use: ft-keylegend name=<n> keys="…"  (stack it above the statusbar)\n' >&2
                    return 1 ;;
        esac
    done
    ft_new statusbar "$@"
}

_ft_destroy_statusbar() {       # release per-instance transient state on rebuild
    unset "FT_STATUSBAR_LAST_SYNOPSIS[$1]"      # a rebuilt bar re-announces its synopsis
    # …and the transient QUEUE, which this hook predates. A message enqueued on the old bar
    # would otherwise still be waiting on a bar rebuilt under the same name and pop up on it —
    # a stale "Saved" on a screen that saved nothing.
    unset "FT_STATUSBAR_QUEUE[$1]" "FT_STATUSBAR_HEAD[$1]"
    ft_anim_stop "$1"           # ...and no sweep outlives the control
}

# One row — the synopsis. (The key legend is now a separate control, ft-keylegend;
# stack one above a statusbar for the classic two-row bar.)
_ft_height_statusbar() { FT_RET=1; }

_ft_draw_statusbar() {          # name
    local name=$1
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local cols=${FT_MEASURED_WIDTH[$name]:-0}
    (( cols < 1 )) && return

    ft_resolved_prop "$name" status ""; local status=$FT_RET
    # A special MODE (edit/cursor) takes over the bar: the way OUT is the one thing a stuck
    # user needs, so the synopsis becomes the exit hint in the caution colour.
    local inmode=""; [[ -n "$FT_MODE_HINT" ]] && inmode=1
    # Colours through the cascade: `statusbar { … }` / `#bar { … }` restyle the strip,
    # `statusbar::hint { … }` the synopsis. Unstyled, byte-identical to the theme role.
    _ft_css_pe_or "$name" hint "$FT_COLOR_HINT"; local hintbase=$FT_RET

    # ── The synopsis ─────────────────────────────────────────────────────────
    # Whenever the text changes, a wave of bold sweeps left-to-right through it — the
    # bar lives far from a centred window, so the sweep is what pulls your eye to it.
    # In a MODE the synopsis is the exit hint in caution amber, and the sweep RE-PULSES
    # on a debounce: it holds still while you type and nags again once you have paused
    # (activateAnimationTypingDelay), which is exactly when a confused user is looking
    # for the way out. Outside a mode it is a plain one-shot on each content change.
    # Priority: a live TRANSIENT ("Copied") out-ranks the mode hint out-ranks the base
    # status — the thing that just happened is the thing to show, but only for its turn.
    _ft_sb_transient "$name"; local trans=$FT_RET
    local syn hintcol
    if   [[ -n "$trans" ]];  then syn=$trans;         hintcol="$hintbase"$'\e[38;5;120m'   # success green
    elif [[ -n "$inmode" ]]; then syn=$FT_MODE_HINT;  hintcol="$hintbase"$'\e[38;5;214m'   # caution amber
    else                          syn=$status;        hintcol=$hintbase; fi
    ft_fit "$syn" "$cols"; local srow=$FT_FIT
    _ft_get_raw "$name" sweepWidth; local wave=${FT_RET:-$_FT_STATUSBAR_SWEEP_WIDTH_DEFAULT}
    if [[ "${FT_STATUSBAR_LAST_SYNOPSIS[$name]-$'\x01'}" != "$syn" ]]; then      # content changed → (re)arm
        FT_STATUSBAR_LAST_SYNOPSIS[$name]=$syn
        if [[ -n "$trans" ]]; then
            # sweep once, then HOLD (retire) so it stays up for its guaranteed min time,
            # after which the draw pops it and the next transient / hint takes over.
            local len=$(( cols + wave )); (( _FT_STATUSBAR_TRANSIENT_HOLD > len )) && len=$_FT_STATUSBAR_TRANSIENT_HOLD
            ft_anim_start "$name" "$len"
        elif [[ -n "$inmode" ]]; then
            # sweep · long rest · sweep …, but only when the caret is quiet (debounced).
            # THE REST IS TIME, NOT DISTANCE. It used to be `+ 300` cells of length: 100 frames
            # that draw nothing new, each costing a wake at 25ms and a full repaint of a bar
            # that had not changed. Sitting in a mode with your hands still measured 12.2% of a
            # core against 0.6% outside one. ft_anim_rest says the same thing in the unit the
            # pause is actually in, and the engine then paints nothing for its duration.
            ft_anim_start "$name" $(( cols + wave )) 25 3 1
            ft_anim_bind  "$name" "" "" 2000
            ft_anim_rest  "$name" "$_FT_STATUSBAR_MODE_REST_MS"
        else
            ft_anim_start "$name" $(( cols + wave ))            # one-shot announcement
        fi
    fi
    ft_anim_phase "$name"; local ph=$FT_RET
    if (( ph >= 0 )); then
        local lo=$(( ph - wave )); (( lo < 0 )) && lo=0
        local hi=$ph; (( hi > cols )) && hi=$cols
        if (( hi > lo )); then
            ft_print_at_width "$row" "$col" \
                "$hintcol${srow:0:lo}$FT_ANSI_BOLD${srow:lo:hi-lo}$FT_ANSI_BOLD_OFF${srow:hi}$FT_COLOR_RESET" "$cols"
            return
        fi
    fi
    ft_print_at_width "$row" "$col" "$hintcol$srow$FT_COLOR_RESET" "$cols"
}
