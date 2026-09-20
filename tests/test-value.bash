#!/usr/bin/env bash
# Unit tests for the value/submit model: automatic value on checkbox/radio,
# activate/deactivate hooks, disabled (inert + unfocusable + inherits),
# submitting is just a button's own _on_activate reading values, slider (clamp/step/hook/cancel),
# select (single, multiple, dropdown open/close).
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null

note "checkbox: on_activate when CHECKED, on_deactivate when UNCHECKED"
ft-form name=app width=60 height=20
    ft-checkbox name=cb text="Beep" accessKey=P onActivate=cb_on_activate onDeactivate=cb_on_deactivate
    ft-radio name=r1 text="One" group=g disabled=true
    ft-button name=go Submit onActivate=go_on_activate
end_ft_form
ft_layout app
FT_ROOT=app
LOG=""
cb_on_activate()   { LOG+="+on"; ft-modify r1 disabled=false; }
cb_on_deactivate() { LOG+="+off"; ft-modify r1 disabled=true; }
ft_activate cb
ft_get cb value; check "checked: value=true, on_activate ran" "$FT_RET,$LOG" "true,+on"
ft_get r1 disabled; check "hook re-enabled the radio" "$FT_RET" "false"
ft_activate cb
ft_get cb value; check "unchecked: value=false, on_deactivate ran" "$FT_RET,$LOG" "false,+on+off"

note "disabled controls are inert and skipped by focus"
ft-modify r1 disabled=true
ft_activate r1
ft_radio_is_selected r1 && s=yes || s=no
check "disabled radio ignores activation (not selected)" "$s" "no"
ft_radio_value g; check "group has no selected value" "$FT_RET" ""
_ft_focus_skippable r1 && s=yes || s=no
check "disabled is unfocusable" "$s" "yes"

note "radio group value = selected option's value (ft_get-style, all options)"
ft-form name=grp width=60 height=20
    ft-radio name=gA group=comp value=none text="None"
    ft-radio name=gB group=comp value=fast text="Fast"
    ft-radio name=gC group=comp value=best text="Best"
end_ft_form
ft_layout grp
ft_radio_value comp v; check "nothing selected yet → empty" "$v" ""
ft_activate gB
ft_radio_value comp v; check "picking Fast reads 'fast' (not ignored)" "$v" "fast"
ft_activate gC
ft_radio_value comp v; check "switching to Best reads 'best'" "$v" "best"
ft_radio_is_selected gB && s=yes || s=no
check "previous radio deselected" "$s" "no"
ft-radio name=gD group=plain text="Plain"   # no explicit value → falls back to name
ft_activate gD
ft_radio_value plain; check "value defaults to the radio's name" "$FT_RET" "gD"

note "submit is just a button's own _on_activate reading live values"
SUBMITTED=""
go_on_activate() { ft_get cb value; SUBMITTED="cb=$FT_RET"; }
ft_activate go
check "the button handler saw the live value" "$SUBMITTED" "cb=false"

note "slider: clamp, step keys, cancelable on_change"
# value=15 with min=10 step=2 is OFF ITS OWN GRID — the reachable values are 10,12,…,20 — and
# HTML's value sanitization rounds it to 16 as it is written (ties round up). This used to be
# stored verbatim, so the slider sat where its own arrow keys could never put it: Right gave 17,
# 19, then 20. The fixture is left off-grid deliberately; it is the case worth pinning.
ft-form name=app2 width=60 height=20
    ft-slider name=sl min=10 max=20 value=15 step=2 width=12 onChange=sl_on_change
end_ft_form
ft_layout app2
ft_get sl value; check "an off-grid value snaps to the step" "$FT_RET" "16"
ft_slider_key_inc sl
ft_get sl value; check "step up" "$FT_RET" "18"
ft_slider_set sl 999
ft_get sl value; check "clamps to max" "$FT_RET" "20"
sl_on_change() { (( $1 >= 14 )); }   # $1=new value; refuse below 14
ft_slider_set sl 12
ft_get sl value; check "hook canceled: previous value stays" "$FT_RET" "20"
ft_slider_set sl 14
ft_get sl value; check "accepted change" "$FT_RET" "14"
unset -f sl_on_change

note "select: single cycles closed; multiple toggles; value auto"
ft-form name=app3 width=60 height=20
    ft-select name=one
        ft-option value=a text="A"
        ft-option value=b text="B"
    end_ft_select
    ft-select name=many size=2 multiple=true
        ft-option value=x text="X"
        ft-option value=y text="Y"
        ft-option value=z text="Z"
    end_ft_select
end_ft_form
ft_layout app3
ft_get one value; check "single: initial value" "$FT_RET" "a"
ft_select_key_down one              # a closed dropdown does NOT open on an arrow
ft_get one open; check "closed dropdown: Down does NOT open it" "$FT_RET" "false"
ft_select_key_commit one            # Enter/Space is what opens it
ft_get one open; check "Enter OPENS the dropdown" "$FT_RET" "true"
ft_select_key_down one              # now the cursor moves
ft_select_key_commit one            # commit cursor option, closes
ft_get one value; check "picked the next option" "$FT_RET" "b"
ft_get one open; check "closed again after commit" "$FT_RET" "false"
ft_select_key_commit many          # toggle X (cursor 0)
ft_select_key_down many
ft_select_key_down many
ft_select_key_commit many          # toggle Z
ft_get many value; check "multiple: value = selected set" "$FT_RET" "x z"
ft_select_key_commit many          # untoggle Z
ft_get many value; check "untoggled" "$FT_RET" "x"

note "label: scrollable → focusable with keys; fits → skipped"
ft-form name=app4 width=30 height=20
    ft-label name=tall text=$'1\n2\n3\n4\n5\n6\n7\n8' width=6 height=3
    ft-label name=short text="fits"
    ft-label name=clipped text=$'a\nb\nc\nd\ne\nf' width=6 height=2 overflowY=clip
end_ft_form
ft_layout app4
_ft_focus_skippable tall && s=yes || s=no
check "scrollable label is focusable" "$s" "no"
_ft_focus_skippable short && s=yes || s=no
check "fitting label is skipped" "$s" "yes"
ft_label_key_down tall
ft_get tall scrollTop; check "Down scrolled it" "$FT_RET" "1"
ft_label_key_end tall
ft_get tall scrollTop; check "End = max scroll" "$FT_RET" "5"
_ft_focus_skippable clipped && s=yes || s=no
check "overflowY=clip label is NOT focusable (hard clip, no scrolling)" "$s" "yes"

note "focus/accessKey skip a control inside a display=none or visibility=hidden ancestor"
ft-form name=app6 width=40 height=10
    ft-div name=hbox
        ft-button name=inbtn Go
    end_ft_div
end_ft_form
ft_layout app6
_ft_focus_skippable inbtn && s=yes || s=no
check "visible: button inside a shown div is focusable" "$s" "no"
ft-modify hbox display=none
_ft_focus_skippable inbtn && s=yes || s=no
check "hidden ancestor: button is skipped even though its OWN display is fine" "$s" "yes"
ft-modify hbox display=block
ft-modify hbox visibility=hidden
_ft_focus_skippable inbtn && s=yes || s=no
check "visibility=hidden ancestor: also skipped" "$s" "yes"

note "visibility=hidden keeps layout space (unlike display=none)"
ft-form name=appv width=40 height=10
    ft-div name=vrow display=flex gap=1 height=1
        ft-label name=vA text="aaaa"
        ft-label name=vB text="bbbb"
    end_ft_div
end_ft_form
ft_layout appv
xb=${FT_ABSOLUTE_X[vB]}
ft-modify vA visibility=hidden
ft_layout appv
check "hidden box keeps its size"       "${FT_MEASURED_WIDTH[vA]}" "4"
check "sibling did not move"            "${FT_ABSOLUTE_X[vB]}" "$xb"
_ft_focus_skippable vA && s=yes || s=no
check "hidden is unfocusable"           "$s" "yes"
ft-modify vA display=none
ft_layout appv
check "display=none DOES collapse the space" "$(( ${FT_ABSOLUTE_X[vB]} < xb ))" "1"

note "ft_wrap preserves hard line breaks (code stays code-shaped)"
ft_wrap $'short\nanother line here\nx' 50
check "3 physical lines stay 3 lines" "${#FT_WRAP_LINES[@]}" "3"
check "line 1 intact" "${FT_WRAP_LINES[0]}" "short"
ft_wrap $'one two three four five six\nz' 10
check "long line soft-wraps, hard break survives" "${FT_WRAP_LINES[-1]}" "z"

note "ft-modify of an explicit width really re-lays (the slider case)"
ft-form name=appw width=60 height=10
    ft-div name=wrow display=flex width=40 height=2
        ft-div name=wl flexGrow=1
        end_ft_div
        ft-div name=wr flexGrow=1
        end_ft_div
    end_ft_div
end_ft_form
ft_layout appw
check "before: halves of 40" "${FT_MEASURED_WIDTH[wl]},${FT_MEASURED_WIDTH[wr]}" "20,20"
ft-modify wrow width=30
check "after ft-modify width=30: halves of 30" "${FT_MEASURED_WIDTH[wl]},${FT_MEASURED_WIDTH[wr]}" "15,15"

note "bare last argument is the element's content (HTML-style)"
ft-label name=bare "Hello, terminal!"
ft_get bare text; check "label bare arg -> text"  "$FT_RET" "Hello, terminal!"
ft-frame name=barefr " My Title "
end_ft_frame
ft_get barefr title; check "frame bare arg -> title" "$FT_RET" " My Title "
ft-modify bare "New content"
ft_get bare text; check "ft-modify bare arg too"  "$FT_RET" "New content"

note "available height: auto boxes never exceed their context"
ft-form name=app5 width=40 height=10
    ft-frame name=w5 display=flex flexDirection=column
        ft-label name=big5 text=$'a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\no\np' width=10
    end_ft_frame
end_ft_form
ft_layout app5
check "window capped at the form's height" "$(( ${FT_MEASURED_HEIGHT[w5]} <= 10 ))" "1"
check "label capped inside it" "$(( ${FT_MEASURED_HEIGHT[big5]} <= 8 ))" "1"

note "a geometry value that is not a number is DROPPED, not fed to bash arithmetic"
# BASH ARITHMETIC IS NOT INERT. Layout puts these values inside (( … )), which resolves bare
# words as variables and EVALUATES ARRAY SUBSCRIPTS — so `width=q[$(cmd)]` RAN cmd (verified,
# with backticks too). Short of execution: `width=1e3` is "value too great for base",
# `width="3 4"` a syntax error, a twenty-digit width makes bash try to allocate 18 exabytes,
# and `width=abc` was silently 0 — each of them printing onto the alt screen. An app writes
# these itself, but in a samba tool it computes them from a config file.
# CSS's rule, applied here: an invalid declaration is dropped and the old value stands.
ft_remove numapp 2>/dev/null
ft-form name=numapp width=70 height=14
    ft-textfield name=numf size=10 value=x
end_ft_form
ft_layout numapp; FT_ROOT=numapp
_numerr=$(mktemp); trap 'rm -f "$_numerr"' EXIT
_numtry() {                     # spec → sets _NUM_STORED / _NUM_REFUSED
    : > "$_numerr"
    ft-modify numf "$1" 2>"$_numerr"      # NB a file, not $( ): a subshell would lose the write
    _ft_get_raw numf "${1%%=*}"; _NUM_STORED=$FT_RET
    _NUM_REFUSED=no; [[ -s "$_numerr" ]] && _NUM_REFUSED=yes
}
# The execution vectors, which must not run and must not store.
_MARKER=$(mktemp -u)
_numtry 'width=20'
for _bad in "width=q[\$(touch $_MARKER)]" "width=q[\`touch $_MARKER\`]"; do
    _numtry "$_bad"
    check "$(printf '%.28s' "$_bad")… is refused"  "$_NUM_REFUSED" "yes"
    check "…and nothing was executed"              "$([[ -e "$_MARKER" ]] && echo RAN || echo no)" "no"
    check "…and the previous width stands"         "$_NUM_STORED"  "20"
done
# The ones that merely corrupted the screen.
for _bad in width=abc width=1e3 'width=3 4' width=99999999999999999999; do
    _numtry "$_bad"
    check "$_bad is refused"                       "$_NUM_REFUSED" "yes"
    check "…and the previous width stands"         "$_NUM_STORED"  "20"
done
# …while everything an app legitimately writes still lands.
for _good in width=0 width=auto height=3 minWidth=5 maxWidth=40 left=0 top=12 \
             rows=5 maxLength=1000 padding=1 gap=2 flexGrow=1 scrollTop=999 \
             borderRadius=0 width=1000000 selectedIndex=3; do
    _numtry "$_good"
    check "$_good is accepted"                     "$_NUM_REFUSED" "no"
    check "…and stored"                            "$_NUM_STORED"  "${_good#*=}"
done

note "…and a length CSS types [0,∞] is dropped when it is negative"
# A negative length does not stay inside the control that asked for it. Measured on a flex row
# of three labels: `ft-modify b width=-6` moved the THIRD one from column 10 back to column 0,
# on top of the first, because the row summed a negative into its running offset. The control
# that asked for it vanishes too — every draw begins `(( rows < 1 || cols < 1 )) && return` —
# silently, while ft_get went on answering -6.
_numtry 'width=20'
for _neg in width=-6 height=-1 minWidth=-1 maxWidth=-1 minHeight=-1 maxHeight=-1 \
            padding=-1 paddingTop=-1 paddingRight=-1 paddingBottom=-1 paddingLeft=-1 \
            gap=-1 borderRadius=-1 flexGrow=-1 flexShrink=-1 size=-1 rows=-1 maxLength=-1 \
            scrollHeight=-1 clientHeight=-1; do
    _numtry "$_neg"
    check "$_neg is refused"                       "$_NUM_REFUSED" "yes"
done
_numtry 'width=30'
check "…and the last good width still stands"      "$_NUM_STORED"  "30"
# The ones CSS types <length> keep their sign, and each has a real negative meaning: margins
# pull a box back over its neighbour, left/top are offsets, min/max bound a range anywhere on
# the number line, and selectedIndex=-1 is HTML's "nothing is selected".
for _neg in margin=-1 marginTop=-2 marginRight=-3 marginBottom=-4 marginLeft=-5 \
            left=-1 top=-2 min=-50 max=-10 selectedIndex=-1; do
    _numtry "$_neg"
    check "$_neg keeps its sign"                   "$_NUM_REFUSED" "no"
    check "…and is stored"                         "$_NUM_STORED"  "${_neg#*=}"
done
# scrollTop is CLAMPED rather than dropped, which is what the DOM does with el.scrollTop = -5.
_numtry 'scrollTop=-5'
check "a negative scroll offset is clamped, not refused" "$_NUM_REFUSED" "no"
check "…to zero"                                         "$_NUM_STORED"  "0"
# The consequence itself, in the layout: a refused width leaves every sibling where it was.
ft_remove negrow 2>/dev/null
ft-form name=negrow width=60 height=10 display=flex flexDirection=row gap=1
    ft-label name=negA text=AAAA
    ft-label name=negB text=BBBB
    ft-label name=negC text=CCCC
end_ft_form
ft_layout negrow
_negwas="${FT_ABSOLUTE_X[negA]},${FT_ABSOLUTE_X[negB]},${FT_ABSOLUTE_X[negC]}"
ft-modify negB width=-6 2>/dev/null
ft_layout negrow
check "a refused width moves nobody (it used to put the third label on the first)" \
      "${FT_ABSOLUTE_X[negA]},${FT_ABSOLUTE_X[negB]},${FT_ABSOLUTE_X[negC]}" "$_negwas"
check "…and the row is still laid out at all" "$_negwas" "0,5,10"
ft_remove negrow 2>/dev/null
# A non-numeric property is untouched by any of this — a field's value is arbitrary text.
_numtry 'value=q[$(id)]'
check "a textfield's value is not validated as a number" "$_NUM_REFUSED" "no"
check "…and is stored verbatim"                          "$_NUM_STORED"  'q[$(id)]'
ft_remove numapp 2>/dev/null

note "a radio declared WITHOUT group= is its own group, not an error"
# `ft-radio name=x "Label"` — forgetting one attribute — used to leave FT_RET empty at four
# separate sites that subscript FT_RADIO_SELECTED with it. An empty associative subscript is a
# bash ERROR on stderr, which in a TUI is the alt screen: select, is_selected, the draw and
# activate each scribbled one over the UI. HTML's answer is that a radio with no name is
# simply grouped with nothing, so its own name is its group — a group of one.
ft_remove rgap 2>/dev/null
ft-form name=rgap width=60 height=10
    ft-radio name=solo   "Solo"
    ft-radio name=solo2  "Also solo"
    ft-radio name=teamA  "A" group=team
    ft-radio name=teamB  "B" group=team
end_ft_form
ft_layout rgap; FT_ROOT=rgap
_rerr=$( { ft_radio_is_selected solo; } 2>&1 >/dev/null )
check "asking an ungrouped radio is silent"  "${_rerr:-clean}" "clean"
_rerr=$( { ft_draw_one solo; } 2>&1 >/dev/null )
check "drawing one is silent"                "${_rerr:-clean}" "clean"
ft_radio_select solo
ft_radio_is_selected solo  && check "it can be selected"           1 1 || check "it can be selected" 0 1
ft_radio_select solo2
ft_radio_is_selected solo  && check "…and does NOT deselect another ungrouped one" 1 1 \
                           || check "…and does NOT deselect another ungrouped one" 0 1
ft_radio_is_selected solo2 && check "…which is selected in its own right" 1 1 \
                           || check "…which is selected in its own right" 0 1
# …while a real group still behaves like a group.
ft_radio_select teamA
ft_radio_select teamB
ft_radio_is_selected teamA && check "a real group still deselects its sibling" 0 1 \
                           || check "a real group still deselects its sibling" 1 1
check "…and the group reports the new choice" "${FT_RADIO_SELECTED[team]:-none}" "teamB"
ft_remove rgap 2>/dev/null

note "a radio written without value= HAS one, and it is the same one the group reports"
# ft_radio_value has always said a radio's value is its name when it set none — but it said so
# by falling back at the READ, so the fact had two spellings and the property was the emptier:
#     ft-radio name=rA group=h "Alpha"    ft_get rA value = <nothing>, ft_radio_value h = rA
# A state save carried the empty one. Materialised once in ft-radio(), the way ft-slider()
# materialises a midpoint, so there is one answer and a save carries it.
ft_remove rval 2>/dev/null
ft-form name=rval width=60 height=10
    ft-radio name=vNone  group=h "None"
    ft-radio name=vSet   group=h value=beta "Beta"
    ft-radio name=vEmpty group=h value="" "Placeholder"
end_ft_form
ft_layout rval; FT_ROOT=rval
ft_get vNone value;  check "no value= → its own name"        "$FT_RET" "vNone"
ft_get vSet  value;  check "an explicit one is untouched"    "$FT_RET" "beta"
_ft_has_prop vEmpty value && check "an explicit EMPTY one is a value, not an absence" 1 1 \
                          || check "an explicit EMPTY one is a value, not an absence" 0 1
ft_get vEmpty value; check "…and stays empty"                "$FT_RET" ""
# One answer, whichever way it is asked.
ft_radio_select vNone; ft_radio_value h
check "the group reports what the radio reports"             "$FT_RET" "vNone"
ft_get vNone value;  check "…and the radio still says it"    "$FT_RET" "vNone"
ft_radio_select vSet;  ft_radio_value h
check "…for an explicit value too"                           "$FT_RET" "beta"
ft_radio_select vEmpty; ft_radio_value h
check "…and an explicit empty is reported empty, not as a name" "$FT_RET" ""
# It is a registered property, so ft-state carries it like any other.
case " ${FT_PROPS[vNone]} " in *" value "*) check "the materialised value is registered" 1 1 ;;
                              *) check "the materialised value is registered" 0 1 ;; esac
ft_remove rval 2>/dev/null

note "EVERY route that changes a field's text tells the app, with the value it now holds"
# A field's `value` is deferred (the line store is authoritative while editing), so onChange is
# the only way an app learns anything — every derived label, preview and enable/disable rule in
# a real app hangs off it. One route that edits silently leaves all of that stale with no way
# to notice, so the routes are enumerated rather than sampled.
_tf_seen=""; _tf_calls=0
tf_noticed() { _tf_seen=$1; (( _tf_calls++ )); }
_tf_fresh() {                   # value caret
    ft_remove tfapp 2>/dev/null
    ft-form name=tfapp width=90 height=14
        ft-textfield name=tf size=30 value="$1" onChange=tf_noticed
    end_ft_form
    ft_layout tfapp; FT_ROOT=tfapp; ft_focus tf
    ft_textfield_activate tf >/dev/null 2>&1
    FT_TEXTFIELD_CARET[tf]=$2; _tf_seen=""; _tf_calls=0
}
_tf_route() {                   # label expected-value
    ft_get tf value
    if (( _tf_calls == 0 )); then check "$1 announces the change" "no onChange (value is $FT_RET)" "$2"
    else check "$1 announces the change" "$_tf_seen" "$FT_RET"; fi
    check "…and the value is right"  "$FT_RET" "$2"
}
_tf_fresh "hello world" 5;  ft_textfield_kill_to_end tf   >/dev/null 2>&1; _tf_route "kill to end"   "hello"
_tf_fresh "hello world" 5;  ft_textfield_kill_to_start tf >/dev/null 2>&1; _tf_route "kill to start" " world"
_tf_fresh "hello world" 11; ft_textfield_ctrl_w tf        >/dev/null 2>&1; _tf_route "kill word back" "hello "
_tf_fresh "hello world" 0;  ft_textfield_kill_word_fwd tf >/dev/null 2>&1; _tf_route "kill word fwd" " world"
_tf_fresh "hello world" 5;  FT_PASTE="XY"; ft_textfield_paste tf >/dev/null 2>&1; unset FT_PASTE
                                                                    _tf_route "paste"         "helloXY world"
_tf_fresh "hello world" 0;  ft_textfield_select_all tf >/dev/null 2>&1; _tf_seen=""; _tf_calls=0
                            ft_textfield_ctrl_x tf        >/dev/null 2>&1; _tf_route "cut"            ""
_tf_fresh "hello world" 5;  ft_textfield_kill_to_end tf >/dev/null 2>&1; _tf_seen=""; _tf_calls=0
                            ft_textfield_yank tf          >/dev/null 2>&1; _tf_route "yank"           "hello world"
_tf_fresh "hello world" 0;  ft_textfield_select_all tf >/dev/null 2>&1; _tf_seen=""; _tf_calls=0
                            ft_textfield_insert_char tf Z >/dev/null 2>&1; _tf_route "type over a selection" "Z"
_tf_fresh "abc" 3;          ft_textfield_backspace tf     >/dev/null 2>&1; _tf_route "backspace"      "ab"
_tf_fresh "abc" 0;          ft_textfield_delete tf        >/dev/null 2>&1; _tf_route "delete forward" "bc"
_tf_fresh "abc" 1;          ft_textfield_insert_char tf X >/dev/null 2>&1; _tf_seen=""; _tf_calls=0
                            ft_textfield_undo tf          >/dev/null 2>&1; _tf_route "undo"           "abc"
_tf_fresh "abc" 1;          ft_textfield_insert_char tf X >/dev/null 2>&1; ft_textfield_undo tf >/dev/null 2>&1
                            _tf_seen=""; _tf_calls=0
                            ft_textfield_redo tf          >/dev/null 2>&1; _tf_route "redo"           "aXbc"
ft_remove tfapp 2>/dev/null

summary
