#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Save and reload the whole UI (ft-state.bash, bound to Ctrl+S).
#
#  The interesting cases are all about what a VALUE can contain and what a restore is allowed
#  to touch. A serialiser that quotes instead of length-prefixing breaks on the first newline;
#  a restore that re-applies everything silently reverts the app's own design.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=80; FT_ROWS=24
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT

# A textfield's scroll offsets are `scrollTop`/`scrollLeft` — the DOM's names, and ordinary
# properties — where they used to be two private tables. These read them the way an app would.
_voff() { _ft_get_raw "$1" scrollTop;  printf '%s' "${FT_RET:-0}"; }
_hoff() { _ft_get_raw "$1" scrollLeft; printf '%s' "${FT_RET:-0}"; }

_build() {                      # value-for-one value-for-lab
    ft-form name=ap width=60 height=16
        ft-textfield name=one  size=20 value="${1:-}"
        ft-textfield name=note size=20 rows=5 wrap=true value=""
        ft-label     name=lab  text="${2:-heading}" width=20
    end_ft_form
    ft_layout ap; FT_ROOT=ap
}

note "a value survives whatever it contains"
# Everything that breaks a quote-and-eval serialiser, plus the scripts that broke the widths.
NASTY=$'line one\nline two\ttabbed\n"quoted" \\backslash $(echo pwned) `id`'
WIDE=$'日本語のテキスト 😀\nsecond line'
_build
ft_set one  value="$NASTY"
ft_set note value="$WIDE"
ok "saving succeeds" ft_state_save "$D/s"
ft_remove ap; _build
ft_state_load "$D/s"
ft_get one  value; check "newlines/tabs/quotes/backslashes round-trip" "$FT_RET" "$NASTY"
ft_get note value; check "CJK + emoji + newline round-trip"            "$FT_RET" "$WIDE"

note "…and the file is DATA, not a script"
# The value above contains $(echo pwned) and `id`. If reloading ever evaluated it, the restored
# value would differ from what was written — which is exactly the bug a %q+eval format invites.
grep -aq 'pwned' "$D/s" && check "the file holds the text verbatim" 1 1 \
                        || check "the file holds the text verbatim" 0 1
ft_get one value
case "$FT_RET" in *'$(echo pwned)'*) check "…and it comes back unevaluated" 1 1 ;;
                  *)                 check "…and it comes back unevaluated" 0 1 ;; esac

note "state that is NOT a property comes back too"
ft_remove ap; _build "hello world"
FT_TEXTFIELD_CARET[one]=7; _ft_setprop one scrollLeft 2; _ft_setprop note scrollTop 1; FT_TEXTFIELD_ANCHOR[one]=3
ft_focus note
ft_state_save "$D/t" >/dev/null
ft_remove ap; _build
ft_state_load "$D/t"
check "caret"         "${FT_TEXTFIELD_CARET[one]:-unset}"    "7"
check "h-scroll"      "$(_hoff one)"   "2"
check "v-scroll"      "$(_voff note)" "1"
check "selection anchor" "${FT_TEXTFIELD_ANCHOR[one]:-unset}" "3"
check "which control had focus" "${FT_FOCUS:-none}"   "note"

note "a restore must not revert the APP's design"
# The user's text is theirs; a label's wording and width are the developer's, and last week's
# copy of them must not come back and undo whatever shipped since.
ft_remove ap; _build "typed by the user" "OLD heading"
ft_state_save "$D/u" >/dev/null
ft_remove ap; _build "" "NEW heading"        # a newer version of the app
ft_state_load "$D/u"
ft_get one value; check "the user's text is restored" "$FT_RET" "typed by the user"
ft_get lab text;  check "the app's new heading stays" "$FT_RET" "NEW heading"
# …with an escape hatch when an exact snapshot IS what you want.
ft_remove ap; _build "" "NEW heading"
FT_STATE_RESTORE_ALL=1 ft_state_load "$D/u"
ft_get lab text;  check "RESTORE_ALL=1 restores it exactly" "$FT_RET" "OLD heading"
FT_STATE_RESTORE_ALL=0

note "EVERY kind of user state comes back, not just the ones stored as properties"
# Enumerated rather than sampled, because the gap was invisible: a radio's selection is
# GROUP-wide state (FT_RADIO_SELECTED[group]), not a property of the control, so saving every
# property saved everything about a radio except which one the user picked. A restart came back
# with nothing selected. The check has to be a REAL restart — clearing the group table — since
# that state outlives ft_remove inside one process and would otherwise mask itself.
ft_remove ap 2>/dev/null
_kinds_build() {
    ft-form name=kp width=80 height=20
        ft-textfield name=kfld size=20 value=""
        ft-checkbox name=kcb text="Tick"
        ft-radio name=kr1 text="One" group=kg
        ft-radio name=kr2 text="Two" group=kg
        ft-slider    name=ksl min=0 max=10 value=0 width=12
        ft-select    name=kse size=1
            ft-option value=alpha glyph="Alpha"
            ft-option value=beta  glyph="Beta"
        end_ft_select
    end_ft_form
    ft_layout kp; FT_ROOT=kp
}
_kinds_build
ft_set kfld value="typed text"
ft_checkbox_toggle kcb
FT_FOCUS=kr2; ft_activate kr2 >/dev/null 2>&1
ft_set ksl value=7
ft_set kse selectedIndex=1
FT_TEXTFIELD_CARET[kfld]=4
ft_state_save "$D/k" >/dev/null
ft_remove kp
FT_RADIO_SELECTED=()            # a restart is a NEW PROCESS: nothing in memory carries over
_kinds_build
ft_state_load "$D/k"
ft_get kfld value; check "a textfield's text"        "$FT_RET" "typed text"
check                      "…and its caret"          "${FT_TEXTFIELD_CARET[kfld]:-unset}" "4"
ft_checkbox_is_checked kcb && check "a checkbox's tick" 1 1 || check "a checkbox's tick" 0 1
check "a radio group's selection"                     "${FT_RADIO_SELECTED[kg]:-none}" "kr2"
ft_get ksl value; check "a slider's position"         "$FT_RET" "7"
_ft_get_raw kse selectedIndex; check "a dropdown's choice" "$FT_RET" "1"
ft_remove kp 2>/dev/null

note "…and a group's selection does not outlive its controls"
# Stored under the GROUP name, so ft_remove could not release it by control name and the leak
# scan could not see it: a rebuilt screen inherited a choice made on a previous one, pointing
# at a control that no longer existed.
ft-form name=gp width=60 height=8
    ft-radio name=gr1 text="One" group=gg
    ft-radio name=gr2 text="Two" group=gg
end_ft_form
ft_layout gp; FT_ROOT=gp
FT_FOCUS=gr2; ft_activate gr2 >/dev/null 2>&1
check "the user's choice is recorded" "${FT_RADIO_SELECTED[gg]:-none}" "gr2"
ft_remove gp
check "removing the controls clears it" "${FT_RADIO_SELECTED[gg]:-none}" "none"

note "restoring tells the app, the same way the user typing would"
# A restore puts the USER'S OWN INPUT back, so anything the app derives from a field — a
# preview, a computed label, an enabled/disabled button — has to be recomputed. Without this,
# demo/textfield-demo came back showing `user = "admin"` under a Username field reading
# `ZaphodBadmin`: the screen contradicting itself.
restored=""; restore_calls=0
saw_change() { restored=$1; (( restore_calls++ )); }
box_state=""
saw_check()   { box_state=on; }
saw_uncheck() { box_state=off; }
ft_remove ap 2>/dev/null
ft-form name=nap width=60 height=10
    ft-textfield name=fld size=20 value="" onChange=saw_change
    ft-checkbox name=box text="Tick" onActivate=saw_check onDeactivate=saw_uncheck
end_ft_form
ft_layout nap; FT_ROOT=nap
ft_set fld value="typed by hand"
ft_set box checked=true
ft_state_save "$D/n" >/dev/null
ft_remove nap
ft-form name=nap width=60 height=10
    ft-textfield name=fld size=20 value="" onChange=saw_change
    ft-checkbox name=box text="Tick" onActivate=saw_check onDeactivate=saw_uncheck
end_ft_form
ft_layout nap; FT_ROOT=nap
restored=""; restore_calls=0; box_state=""
ft_state_load "$D/n"
check "onChange fired for the restored field"  "$restored"   "typed by hand"
check "…exactly once"                          "$restore_calls" "1"
check "the checkbox reported itself too"       "$box_state"  "on"
# …and a value that did NOT change must not fire — a restore is not a change event storm.
restored=""; restore_calls=0
ft_state_load "$D/n"
check "re-loading the same state announces nothing" "$restore_calls" "0"

note "a state file from a DIFFERENT shape of app is harmless"
ft_remove ap
ft-form name=ap width=60 height=16
    ft-textfield name=one size=20 value=""      # `note` and `lab` no longer exist
end_ft_form
ft_layout ap; FT_ROOT=ap
ok "loading skips controls that are gone" ft_state_load "$D/u"
ft_get one value; check "…and still restores the ones that remain" "$FT_RET" "typed by the user"

note "refusals"
ft_remove ap
FT_ROOT=""
no "saving with no tree fails rather than writing rubbish" ft_state_save "$D/v"
no "loading a missing file fails"                          ft_state_load "$D/nope"
printf 'not a state file\n' > "$D/bad"
no "loading a file that is not one fails"                  ft_state_load "$D/bad"

note "where it saves does NOT depend on where you launched from"
# A CWD-relative default means the file an app saves to changes with the directory it was
# started in — so the next run reads a different file and the state "resets entirely",
# and the user cannot find the file to check. The default must be absolute and per-app.
case "$FT_STATE_FILE" in
    /*) check "the default state path is absolute" 1 1 ;;
    *)  check "the default state path is absolute" "$FT_STATE_FILE" "/…" ;;
esac
case "$FT_STATE_FILE" in
    *"/fruity-tui/"*.ftstate) check "…and names the app under an XDG state dir" 1 1 ;;
    *) check "…and names the app under an XDG state dir" "$FT_STATE_FILE" "…/fruity-tui/<app>.ftstate" ;;
esac
_ft_state_appid; case "$FT_RET" in *[!A-Za-z0-9._-]*) check "the app id is filename-safe" 0 1 ;;
                                  "")                check "the app id is filename-safe" 0 1 ;;
                                  *)                 check "the app id is filename-safe" 1 1 ;; esac
# …and a save creates the directory rather than failing because it isn't there yet.
_build "made a dir"
ok "saving into a missing directory creates it" ft_state_save "$D/deep/er/still/s"
[[ -f "$D/deep/er/still/s" ]] && check "…and the file really is there" 1 1 \
                              || check "…and the file really is there" 0 1

note "reloading is the other half of saving"
grep -q 'FT_STATE_AUTOLOAD' "$here/ft-forms.bash" \
  && check "ft_run restores the saved state on start" 1 1 \
  || check "ft_run restores the saved state on start" 0 1
check "…and it is on by default" "${FT_STATE_AUTOLOAD:-unset}" "1"

note "a save the user cannot see is indistinguishable from a broken key"
# The confirmation goes to a status bar when there is one…
ft_remove ap
ft-form name=ap2 width=60 height=6
    ft-statusbar name=sb status="ready"
end_ft_form
ft_layout ap2; FT_ROOT=ap2
ok "an event with no text[…] declared still says something" ft_status_event sb saved
check "…using the framework's default wording" "${FT_STATUSBAR_QUEUE[sb]##*$'\t'}" "Saved"$'\n'
FT_STATUSBAR_QUEUE=(); FT_STATUSBAR_HEAD=()
ft_set sb "text[saved]"="Stored it,1,4"
ft_status_event sb saved
check "a bar's own wording still wins" "${FT_STATUSBAR_QUEUE[sb]##*$'\t'}" "Stored it"$'\n'
# …and to the engine's own line when there is NOT one, which is the case that was silent.
ft_remove ap2
ft-form name=ap3 width=60 height=6
    ft-textfield name=one size=20 value=""
end_ft_form
ft_layout ap3; FT_ROOT=ap3
_FT_TOAST_MSG=""; FT_TOAST_FN=""
ok "emitting with no status bar in the tree still reports" ft_emit_status saved "~/x.ftstate"
check "…on the engine's toast line" "$_FT_TOAST_MSG" "Saved → ~/x.ftstate"
# It paints LAST (over anything, including overlays) and only on the bottom row.
FT_OUT=""; FT_COLS=40; FT_ROWS=10
_ft_toast_paint
case "$FT_OUT" in *"Saved → ~/x.ftstate"*) check "the toast paints its message" 1 1 ;;
                  *)                       check "the toast paints its message" 0 1 ;; esac
case "$FT_OUT" in $'\e[10;'*) check "…on the bottom screen row" 1 1 ;;
                  *)          check "…on the bottom screen row" "${FT_OUT:0:8}" "row 10" ;; esac
set -- $_FT_TOAST_RECT
check "the repair rect is that one row"  "$1/$3"  "9/9"
check "…ending one cell inside the edge" "$4"     "38"
# Dismissing it damages exactly those cells, so the next frame repairs the row.
rect=$_FT_TOAST_RECT
FT_DAMAGE=()
ok "clearing reports that a toast was up" ft_toast_clear
check "…and queues its cells for repair" "${FT_DAMAGE[0]:-none}" "$rect"
no "clearing again reports there was nothing" ft_toast_clear

note "Ctrl+S is wired at the TUI level"
grep -q 'ft_state_save' "$here/ft-forms.bash" \
  && check "the run loop saves on an unclaimed Ctrl+S" 1 1 \
  || check "the run loop saves on an unclaimed Ctrl+S" 0 1
_ft_tty_flags
case "$FT_RET" in *"-ixon"*) check "…and the tty releases Ctrl+S for it" 1 1 ;;
                  *)         check "…and the tty releases Ctrl+S for it" 0 1 ;; esac

note "the file means the same thing in every locale"
# The length prefix is documented as BYTES, and bash counts bytes only in the C locale:
# `${#v}` and `read -N` both count CHARACTERS in a UTF-8 one. So a file written by a run in
# one locale and read by a run in another desynchronised at the first non-ASCII character —
# the value swallowed the record header after it, and every value from there on was garbage.
# Not exotic: an app started from cron or a systemd unit is in the C locale, the same app
# started from a terminal is not, and a state file under XDG outlives both.
_L_CJK="設定オプション"
_L_MIX="mixed 設定 x🎉y"
_L_MULTI=$'第一行\n第二行\tタブ'
_lbuild() {
    ft_remove lapp 2>/dev/null
    ft-form name=lapp width=60 height=16
        ft-textfield name=la size=20 value="$1"
        ft-textfield name=lb size=20 value="$2"
        ft-textfield name=lc size=20 rows=3 value="$3"
    end_ft_form
    ft_layout lapp; FT_ROOT=lapp; ft_focus la
}
_lcheck() {                     # label
    local label=$1 n
    for n in la:"$_L_CJK" lb:"$_L_MIX" lc:"$_L_MULTI"; do
        _ft_get_raw "${n%%:*}" value
        check "$label — ${n%%:*} came back verbatim" "$FT_RET" "${n#*:}"
    done
}
_lfile="$XDG_STATE_HOME/locale-round-trip.ftstate"
for _wl in "C" "en_US.UTF-8" ""; do
    _lbuild "$_L_CJK" "$_L_MIX" "$_L_MULTI"
    ( : )                                  # (no subshell for the save — it must reach the file)
    LC_ALL=$_wl ft_state_save "$_lfile" >/dev/null
    _lbuild "" "" ""
    ft_state_load "$_lfile"
    _lcheck "saved under LC_ALL=${_wl:-unset}"
done

note "…and a version 1 file is still read the way it was written"
# Version 1 counted characters. Those files are only wrong across a locale change, which is
# what version 2 fixes — rejecting them outright would throw away state that reads fine.
_lbuild "$_L_CJK" "$_L_MIX" "$_L_MULTI"
ft_state_save "$_lfile" >/dev/null
python3 - "$_lfile" <<'PY'
import io, sys
# Rewrite the version 2 file as a version 1 one: same records, counts in CHARACTERS.
raw = open(sys.argv[1], 'rb').read()
out, i = bytearray(), 0
lines = raw.split(b'\n')
out += b'ft-state 1\n'
i = 1
while i < len(lines):
    line = lines[i]
    if line.startswith(b'prop '):
        head, n = line.rsplit(b' ', 1)
        nbytes = int(n)
        rest = b'\n'.join(lines[i+1:])
        value = rest[:nbytes]
        out += head + b' ' + str(len(value.decode('utf-8'))).encode() + b'\n' + value + b'\n'
        consumed = rest[:nbytes+1]
        lines = [b''] + rest[nbytes+1:].split(b'\n')
        i = 1
        continue
    out += line + b'\n'
    i += 1
open(sys.argv[1], 'wb').write(bytes(out).rstrip(b'\n') + b'\n')
PY
head -1 "$_lfile" | grep -q 'ft-state 1' \
  && check "the fixture really is a version 1 file" 1 1 \
  || check "the fixture really is a version 1 file" 0 1
_lbuild "" "" ""
ok  "a version 1 file still loads" ft_state_load "$_lfile"
_lcheck "version 1"
printf 'ft-state 99\n' > "$_lfile"
no "a version it does not know is refused, not guessed at" ft_state_load "$_lfile"

# ── Where the reader dragged a callout to is state, and state is saved ───────
# A save walks each control's PROPERTIES, so anything a control keeps in a private parallel
# array is invisible to it — and a parked callout's position was kept in exactly such an array.
# The user moves a chip out of their way, quits, comes back, and it is back over the thing they
# moved it off. This is the general shape of the law, not one control's bug: observable
# per-control state is a property.
note "a callout parked by the reader comes back where they left it"
source "$here/controls/ft-beacon.bash"
ft_remove pk 2>/dev/null; ft_remove pkapp 2>/dev/null
ft-form name=pkapp width=60 height=16
    ft-label name=pktgt text="the target" width=20
end_ft_form
ft_layout pkapp; FT_ROOT=pkapp
ft-beacon name=pk target=pktgt variant=callout number=1 effect=none parent=pkapp \
          text="drag me out of the way"
ft_layout pkapp; FT_OUT=""; _ft_redraw_walk pkapp >/dev/null 2>&1; _ft_composite_overlays
_ft_beacon_placement pk; _auto="$FT_PLACED_T $FT_PLACED_L"    # where the PLACER put it

# …parked through the real gesture: grab the chip, move, release.
set -- ${FT_BEACON_BOX[pk]}; _gT=$1; _gL=$2
ok "the chip can be grabbed"  _ft_beacon_grab_at "$_gL" "$_gT"
ok "…and dragged"             _ft_beacon_mouse_drag $(( _gL + 6 )) $(( _gT + 4 ))
ok "…and released"            _ft_beacon_mouse_release $(( _gL + 6 )) $(( _gT + 4 ))
ft_get pk parkedTop;  _pT=$FT_RET
ft_get pk parkedLeft; _pL=$FT_RET
check "the park is a property, not a private array" "$([[ -n "$_pT$_pL" ]] && echo yes || echo no)" yes
# Where the chip actually SITS after that gesture — the park as the mouse asked for it, then
# clamped to the bound it may park in, which is the painter's job and not the property's.
FT_OUT=""; _ft_redraw_walk pkapp >/dev/null 2>&1; _ft_composite_overlays
_ft_beacon_placement pk; _live="$FT_PLACED_T $FT_PLACED_L"

ok "saving succeeds with a parked callout" ft_state_save "$D/park"
grep -q "parkedTop" "$D/park" \
  && check "the saved file records the park" 1 1 \
  || check "the saved file records the park" 0 1

# …and a fresh build of the same UI comes back parked, not auto-placed.
ft_remove pk; ft_remove pkapp
ft-form name=pkapp width=60 height=16
    ft-label name=pktgt text="the target" width=20
end_ft_form
ft_layout pkapp; FT_ROOT=pkapp
ft-beacon name=pk target=pktgt variant=callout number=1 effect=none parent=pkapp \
          text="drag me out of the way"
ft_layout pkapp
ft_state_load "$D/park"
ft_get pk parkedTop;  check "parkedTop restored"  "$FT_RET" "$_pT"
ft_get pk parkedLeft; check "parkedLeft restored" "$FT_RET" "$_pL"
FT_OUT=""; _ft_redraw_walk pkapp >/dev/null 2>&1; _ft_composite_overlays
_ft_beacon_placement pk
check "…and the chip comes back on the row the reader left it on" "$FT_PLACED_T" "$_pT"
# The claim needs its control: without the park the placer puts the chip somewhere else
# entirely, so "it came back parked" is not "the placer happens to choose that spot".
check "…which is NOT where the placer puts an unparked one" \
      "$([[ "$FT_PLACED_T $FT_PLACED_L" == "$_auto" ]] && echo same || echo different)" different
# WHAT IS RESTORED IS THE PARK, NOT THE PLACER'S SEARCH. The chip's parked COLUMN is the park
# clamped to the bound it may sit in, and that clamp depends on how wide the chip is — which is
# the placement search's answer (it may rescue a narrower, taller shape) and a cache, not user
# state. So a chip that had been rescued narrow can come back at its default width and clamp a
# few columns further in. The park is honoured; the search is redone. Recorded here rather than
# asserted away, because the alternative — persisting a cache — is the law this fix is about,
# backwards.
_lclamped=different; [[ "$FT_PLACED_T $FT_PLACED_L" == "$_live" ]] && _lclamped=identical
note "  (restored placement vs the live one: $_lclamped — live $_live, restored $FT_PLACED_T $FT_PLACED_L)"
ft_remove pk; ft_remove pkapp

# ─────────────────────────────────────────────────────────────────────────────
#  A RESTORE MUST ANNOUNCE WHAT IT RESTORED.
#
#  _ft_state_notify shared one arm across checkbox|radio|multitoggle and asked `value == true`.
#  A checkbox's value IS its truth. A RADIO's value is its OPTION value — its own name unless the
#  author set one — so that test was false for every radio there has ever been, and a restore
#  that had just selected one fired on_deactivate at it. An app whose handler disables a section
#  on deactivate would switch it off immediately after restoring the state that says it should
#  be on.
# ─────────────────────────────────────────────────────────────────────────────
note "restoring a selected radio announces that it is ON, not OFF"
_NFIRED=""
nr2_on_activate()   { _NFIRED+="r2:activate "; }
nr2_on_deactivate() { _NFIRED+="r2:deactivate "; }
ncb_on_activate()   { _NFIRED+="cb:activate "; }
ncb_on_deactivate() { _NFIRED+="cb:deactivate "; }
ft-form name=nap width=60 height=12 display=flex flexDirection=column
    ft-radio    name=nr1 text="One" group=ng
    ft-radio    name=nr2 text="Two" group=ng onActivate=nr2_on_activate onDeactivate=nr2_on_deactivate
    ft-checkbox name=ncb text="Box" onActivate=ncb_on_activate onDeactivate=ncb_on_deactivate
end_ft_form
FT_ROOT=nap; ft_layout nap
ft_radio_select nr2
ft_set ncb checked=true
# ANTI-VACUITY: the branch used to test `value`, and the whole point is that a radio's value is
# not its selection. Show that it is not, or "asks the right property" proves nothing. It used
# to be EMPTY here; a radio written without value= now carries its own name (ft-radio
# materialises it, so the property and ft_radio_value stop disagreeing) — which is still not
# `true`, and the branch that asks `value` would still be wrong for every radio.
check "a radio's value is NOT its selection" \
      "$(ft_get nr2 value; printf '[%s]' "$FT_RET")" "[nr2]"
check "…while its checked is"  "$(ft_get nr2 checked; printf %s "$FT_RET")" "true"
_nf=$(mktemp)
ft_state_save "$_nf" >/dev/null 2>&1
ft_radio_select nr1; ft_set ncb checked=false
_NFIRED=""
ft_state_load "$_nf" >/dev/null 2>&1
check "the radio came back selected"        "$(ft_get nr2 checked; printf %s "$FT_RET")" "true"
check "…and the restore said so"            "$([[ "$_NFIRED" == *"nr2:activate"* || "$_NFIRED" == *"r2:activate"* ]] && echo 1 || echo 0)" 1
check "…and did NOT announce the opposite"  "$([[ "$_NFIRED" == *"r2:deactivate"* ]] && echo 1 || echo 0)" 0
check "a checkbox still reports through its value" \
      "$([[ "$_NFIRED" == *"cb:activate"* ]] && echo 1 || echo 0)" 1
rm -f "$_nf"
ft_remove nap

note "a restore fires the SAME event with the SAME argument as an ordinary interaction"
# The arm asked `value == true` — the CHECKBOX's question — of a multitoggle whose options are
# not booleans, so a 3-state control restored to `high` was announced with on_deactivate, the
# event the prototype header defines as "a checkbox unchecking". And it called the hook with NO
# ARGUMENT while the header documents "$1 is the new value" and every other route passes it, so
# a handler written to that contract dies on `$1: unbound variable` in a `set -u` app.
_MSEEN=""
mstate_on_activate()   { _MSEEN+="activate(${1-<NO ARG>}) "; }
mstate_on_deactivate() { _MSEEN+="deactivate(${1-<NO ARG>}) "; }
ft-form name=msap width=60 height=12 display=flex flexDirection=column
    ft-multitoggle name=mstate text="Pri" onActivate=mstate_on_activate onDeactivate=mstate_on_deactivate
        ft-option value=low  glyph="[L]"
        ft-option value=high glyph="[H]"
    end_ft_multitoggle
end_ft_form
FT_ROOT=msap; ft_layout msap
_MSEEN=""; ft_multitoggle_cycle mstate
_ordinary=$_MSEEN
check "the ordinary route passes the new value" "$_ordinary" "activate(high) "
_msf=$(mktemp)
ft_state_save "$_msf" >/dev/null 2>&1
ft_set mstate selectedIndex=0
_MSEEN=""
ft_state_load "$_msf" >/dev/null 2>&1
check "…and the restore route says exactly the same thing" "$_MSEEN" "$_ordinary"
check "…so it carried an argument at all" \
      "$([[ "$_MSEEN" == *"<NO ARG>"* ]] && echo 0 || echo 1)" 1
rm -f "$_msf"
ft_remove msap

summary
