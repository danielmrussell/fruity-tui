#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tests/test-leak.bash — "this control is gone" applied to EVERY per-control table.
#
#  The engine keeps a dozen tables keyed by control name. ft_remove released the properties,
#  the side tables and the line store — and nothing in the STYLE caches, so ~4 entries per
#  control stayed forever. Correctness was never affected (a recycled name resolves its own
#  style, because the cache key carries a version), which is exactly why nobody noticed: an
#  app creating controls with fresh names — a log appending rows, a list refilling — grew
#  those tables without bound. Measured before the fix: +200 entries per 50 rows, linear.
#
#  This test does NOT hard-code which tables are per-control. It scans every associative array
#  in the process, so a table added later is covered without anyone remembering to add it here.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=100; FT_ROWS=30

ARRAYS=()
# HOW MANY TABLES THE THINNEST SCAN OF THIS RUN SAW. Every verdict below is "keys_for came back
# empty", and an ARRAYS that came back empty produces exactly that — a clean bill of health for a
# scan that looked at nothing. Proven: an injected FT_CSS_ANIMATION_ON[victim], the name-keyed
# style-cache class this file exists to catch, is found by the real 190-array scan and MISSED
# with ARRAYS emptied, and the growth gate reads +0 as well. (The blindness is partial rather
# than total: keys_for's second half, compgen -v _ftp_<name>_, does not go through ARRAYS and
# still bites a gross leak. The ARRAY half is what goes quiet.) So the count is watched, and the
# scan is shown at the foot of the file to be capable of finding something.
#
# WATCHED FAILING, 2026-08-30 (two sabotages, one at a time, both restored):
#   scan_arrays yields nothing        this file 22/27, 5 FAIL   the file as it stood BEFORE the
#                                                               guards: 20/20, exit 0
#   ft_remove leaves one style-cache
#   entry behind (a REAL leak)        this file 13/27, 14 FAIL
fewest_arrays_seen=999999
scan_arrays() {                 # one pass over `declare -p`; asking per-variable forks forever
    mapfile -t ARRAYS < <(declare -p 2>/dev/null | sed -n 's/^declare -A \([A-Za-z_][A-Za-z_0-9]*\).*/\1/p')
    (( ${#ARRAYS[@]} < fewest_arrays_seen )) && fewest_arrays_seen=${#ARRAYS[@]}
    return 0
}
keys_for() {                    # name → every array entry still keyed by it
    local want=$1 v k out=""
    for v in "${ARRAYS[@]}"; do
        local -n ref="$v"
        for k in "${!ref[@]}"; do
            [[ "$k" == "$want" || "$k" == "$want"$'\x1f'* ]] && out+="$v[${k//$'\x1f'/|}] "
        done
        unset -n ref
    done
    compgen -v "_ftp_${want}_" 2>/dev/null | while read -r p; do printf '%s ' "$p"; done
    printf '%s' "$out"
}
total_entries() {
    local v n=0
    for v in "${ARRAYS[@]}"; do local -n ref="$v"; n=$(( n + ${#ref[@]} )); unset -n ref; done
    printf '%s' "$n"
}

exercise() {                    # name type — populate the lazy per-control state
    local n=$1 t=$2
    ft_focus "$n" >/dev/null 2>&1
    ft_draw_one "$n" >/dev/null 2>&1
    case $t in
        textfield) ft_textfield_activate "$n" >/dev/null 2>&1
                   ft_textfield_insert_char "$n" a >/dev/null 2>&1
                   ft_textfield_undo "$n" >/dev/null 2>&1 ;;
        checkbox|radio|button) ft_dispatch_event ENTER >/dev/null 2>&1 ;;
        select|tree|table|tabs) ft_dispatch_event DOWN >/dev/null 2>&1 ;;
        slider|scrollbar)       ft_dispatch_event RIGHT >/dev/null 2>&1 ;;
        statusbar)              ft_status_flash "$n" hi 1 4 >/dev/null 2>&1 ;;
    esac
    ft_draw_one "$n" >/dev/null 2>&1
}

note "the scan itself — teeth before verdicts"
# A leak hunter that has never been shown finding a leak is a green light, not a gate. So before
# anything is asserted about a removed control, plant one entry of each shape keys_for claims to
# recognise and require it to come back. FT_CSS_ANIMATION_ON is the exact table the header is
# about: a name-keyed style cache that ft_remove used to leave behind.
scan_arrays
check "the scan enumerated the engine's tables (100 or more)" \
      "$(( ${#ARRAYS[@]} >= 100 ? 1 : 0 ))" 1
check "…including the style caches it is here to watch" \
      "$([[ " ${ARRAYS[*]} " == *" FT_CSS_ANIMATION_ON "* ]] && echo yes)" yes
_teeth_composite_key="teeth"$'\x1f'"color"     # the shape a style cache keys by: name<US>prop
FT_CSS_ANIMATION_ON[teeth]=1                   # a plain per-control key
_FT_STYLE_C[$_teeth_composite_key]=201         # a composite key
_ftp_teeth_color=201                           # a property variable, the other half of keys_for
_teeth_found=$(keys_for teeth)
check "a plain name-keyed entry is found"     "$([[ "$_teeth_found" == *"FT_CSS_ANIMATION_ON[teeth]"* ]] && echo yes)" yes
check "a composite name<US>prop key is too"   "$([[ "$_teeth_found" == *"_FT_STYLE_C[teeth|color]"* ]] && echo yes)" yes
check "and so is a leaked property variable"  "$([[ "$_teeth_found" == *"_ftp_teeth_color"* ]] && echo yes)" yes
unset "FT_CSS_ANIMATION_ON[teeth]" "_FT_STYLE_C[$_teeth_composite_key]" _ftp_teeth_color
check "…and with all three gone the same name reads clean" "$(keys_for teeth)" ""

note "removing a control releases its state, whatever its type"
# The style caches are swept in AMORTISED batches (scanning them on every removal would turn a
# 50-row refresh into 50 full scans of the table that exists to make painting fast), so force
# the sweep before looking. What must hold either way: nothing keyed by a dead node survives.
build_victim() {                # type — each control's own required arguments
    case $1 in
        label)     ft-label     name=victim "Some text" ;;
        heading)   ft-heading   name=victim "A heading" ;;
        button)    ft-button    name=victim "Press" accessKey=P ;;
        checkbox)  ft-checkbox  name=victim "Tick" ;;
        radio)     ft-radio     name=victim "One" group=grp ;;
        textfield) ft-textfield name=victim size=20 value="hello" ;;
        select)    ft-select    name=victim size=1
                   end_ft_select ;;
        slider)    ft-slider    name=victim min=0 max=10 value=5 ;;
        scrollbar) ft-scrollbar name=victim orientation=vertical ;;
        statusbar) ft-statusbar name=victim status="ready" ;;
        keylegend) ft-keylegend name=victim keys=auto ;;
        boxheader) ft-boxheader name=victim "Header" ;;
        frame)     ft-frame     name=victim title=T
                   end_ft_frame ;;
    esac
}
for t in label heading button checkbox radio textfield select slider scrollbar \
         statusbar keylegend boxheader frame; do
    ft-form name=host width=90 height=14
        build_victim "$t"
    end_ft_form
    ft_layout host; FT_ROOT=host
    exercise victim "$t"
    ft_remove victim
    _ft_css_compact
    scan_arrays
    leaked=$(keys_for victim)
    check "$t leaves nothing behind" "${leaked:-clean}" "clean"
    ft_remove host 2>/dev/null
done

note "a message queued on a removed status bar does not surface on its replacement"
# What the leaked queue actually costs: a stale "Saved" popping up on a screen that saved
# nothing. The tutorial and the CSS demo rebuild their bars under the same name every page.
ft-form name=sbhost width=60 height=6
    ft-statusbar name=bar status="ready"
end_ft_form
ft_layout sbhost; FT_ROOT=sbhost
ft_status_flash bar "Saved" 5 30
check "the message is queued on the first bar" "${FT_STATUSBAR_QUEUE[bar]##*$'\t'}" "Saved"$'\n'
ft_remove bar
ft-form name=sbhost2 width=60 height=6
    ft-statusbar name=bar status="ready"
end_ft_form
ft_layout sbhost2; FT_ROOT=sbhost2
_ft_sb_transient bar
check "the rebuilt bar shows nothing"          "${FT_RET:-<nothing>}" "<nothing>"
ft_remove sbhost 2>/dev/null; ft_remove sbhost2 2>/dev/null

note "creating and dropping controls with FRESH names does not grow the engine"
ft_stylesheet name=leakdemo style=".row { color: 201; }"
ft-form name=app width=90 height=20
    ft-div name=list
    end_ft_div
end_ft_form
ft_layout app; FT_ROOT=app
scan_arrays; baseline=$(total_entries)
for round in 1 2 3 4; do
    for (( i=0; i<40; i++ )); do ft-label name="row_${round}_$i" class=row parent=list "Line $i"; done
    ft_layout app
    for (( i=0; i<40; i++ )); do ft_style "row_${round}_$i" color >/dev/null 2>&1; done
    for (( i=0; i<40; i++ )); do ft_remove "row_${round}_$i"; done
done
_ft_css_compact
scan_arrays; grown=$(( $(total_entries) - baseline ))
# Before the fix this was +640 for these 160 rows. A small residue is fine; proportional is not.
if (( grown < 40 )); then
    check "160 rows made and removed → engine back to size (+$grown entries)" 1 1
else
    check "160 rows made and removed → engine back to size" "+$grown entries" "under +40"
fi

note "…and a recycled name still gets its OWN style and keys, not the dead one's"
# The reason the leak was invisible: correctness never depended on the release. Keep it that way.
ft_stylesheet name=leak2 style=".hot { color: 201; } .cool { color: 33; }"
ft_remove app 2>/dev/null
ft-form name=p1 width=80 height=8
    ft-label name=spec class=hot "Specimen"
end_ft_form
ft_layout p1; FT_ROOT=p1
ft_style spec color; check "first build resolves .hot" "$FT_RET" 201
ft_remove spec
ft-form name=p2 width=80 height=8
    ft-label name=spec class=cool "Specimen"
end_ft_form
ft_layout p2; FT_ROOT=p2
ft_style spec color; check "same name rebuilt as .cool resolves .cool" "$FT_RET" 33

pressed=""
hit_x() { pressed+="X "; }
ft_keymap km_leak; ft_keymap_set km_leak key=x onKey='hit_x $this'
ft_remove p2 2>/dev/null
ft-form name=p3 width=80 height=8
    ft-button name=btn "Press" keymap=km_leak
end_ft_form
ft_layout p3; FT_ROOT=p3; ft_focus btn
pressed=""; ft_dispatch_event x >/dev/null 2>&1
check "a control with keymap=… responds to it" "$pressed" "X "
ft_remove btn
ft-form name=p4 width=80 height=8
    ft-button name=btn "Press"
end_ft_form
ft_layout p4; FT_ROOT=p4; ft_focus btn
pressed=""; ft_dispatch_event x >/dev/null 2>&1
check "rebuilt without one does NOT inherit it" "${pressed:-none}" "none"

# Every "clean" above was read off ARRAYS. If any scan in this run had come back thin, those
# verdicts would have been the enumeration going quiet rather than the engine coming clean.
# Measured 2026-08-30: 190 tables at the thinnest point of the run.
check "no scan in this run came up short ($fewest_arrays_seen tables at its thinnest)" \
      "$(( fewest_arrays_seen >= 100 ? 1 : 0 ))" 1

summary
