#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tests/test-roundtrip.bash — whatever a user can DO to a control, a save and a reload must
#  bring back. Asserted against the SCREEN, for every control, with no per-control expectations.
#
#  ft-state.bash promises "Ctrl+S saves the whole UI". The way that promise has broken, four
#  times now, is always the same: a control keeps some piece of user-visible state in a private
#  engine table instead of in a property, the serialiser walks properties, and the state is
#  simply not there. A radio's selection lived in FT_RADIO_SELECTED, so saving every property
#  saved everything about a radio except which one the user picked. A textfield's scroll position
#  lived in FT_TEXTFIELD_VSCROLL, so a reloaded session came back at the top of a document the
#  user had scrolled. Each was found by someone noticing, months apart.
#
#  This file cannot be told which facts matter, because that list is exactly what keeps being
#  wrong. So it asks the only question that needs no list:
#
#      drive the control with ITS OWN KEYS until the screen changes,
#      save, tear the page down, rebuild it, reload,
#      and demand the screen is what it was.
#
#  The keys come from the control's own keymap by being dispatched at it, not from a table here —
#  a control that grows a new verb is covered the day it grows it. The screen is the oracle
#  because the screen is the promise; a property-by-property comparison would be another list to
#  get wrong, and would miss state that has no property at all, which is the entire bug class.
#
#  TRANSIENT MODE IS NORMALISED OUT, on both sides, and that is not a loophole. Enter puts a
#  field in `editing` and lights its border; focus tints whatever holds it. Neither is state a
#  reload is meant to restore — ft-state does not carry `runlevel` — so both sides are returned
#  to unfocused before the screen is read. What remains is the state that IS meant to survive:
#  scroll offsets, cursors, selections, expansions, values, checks.
#
#  AND THE SECOND HALF: A RELOAD THAT CHANGED SOMETHING MUST SAY SO. Restoring the user's input
#  is only half the promise — everything the app DERIVES from that input (a preview, a computed
#  label, an enabled button) is recomputed from a hook, and a silent restore leaves all of it
#  stale on the screen the user comes back to. _ft_state_notify is a case list keyed by control
#  TYPE and it has been wrong three times: the radio sharing the checkbox's arm, the multitoggle
#  called with no argument, and slider/tabs/tree/scrollbar simply absent. Wrapping _ft_hook is
#  what makes this checkable without a list of its own — every event in the framework goes
#  through that one function.
#
#  The invariant is SILENCE, not sameness, and both of its guards were paid for by a false
#  positive. Not "the same events": driving a select fires on_activate (an option was CHOSEN — an
#  action) as well as on_change, and a browser restoring a form fires change and not click, while
#  on_activate IS how a checkbox reports state because it has no on_change. And only when the
#  reload actually moved something: ENTER engages AND toggles a checkbox, SPACE toggles it back,
#  so that drive ends where it started and a reload correctly changes and says nothing.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=80; FT_ROWS=24; FT_USE_UTF8=1
_RT_D=$(mktemp -d); trap 'rm -rf "$_RT_D"' EXIT

# ── sabotage, for the teeth ──────────────────────────────────────────────────
# THE TEETH ARE MEASURED BY INJECTING THE CLASS, not by replaying history. Running this file at
# the parent of each of the fourteen defects fixed last week catches none of them, and that is
# not the indictment it looks like: those were found BY HAND precisely because no mechanism saw
# them, several arrived and departed inside one commit, and the state they lost was carried by
# bespoke records rather than dropped. What a prospective gate has to prove is that it sees the
# CLASS when the class is present — so put it there, both ways it is known to occur, and require
# red. Same idiom as tests/test-clip.bash's FT_CLIP_SABOTAGE, for the same reason.
_rt_sab=${FT_ROUNDTRIP_SABOTAGE:-}
case "$_rt_sab" in
    # A control's user state saved but left out of the restore allowlist — `activeTab` exactly
    # as it was found, the record written to the file and thrown away on the way back in.
    restorelist)
        FT_STATE_RESTORE_PROPS="value scrollTop scrollLeft selectedIndex checked cursor expanded parkedTop parkedLeft" ;;
    # …and the other half: the property restored, and no class reconciler on the restore route to
    # act on it, so the number comes back and the screen does not follow it.
    reconciler)
        ft_class_init tabs >/dev/null 2>&1; FT_CLASS_SETPROP[tabs]="" ;;
    # …and the third: one control TYPE missing from _ft_state_notify's case list, which is how
    # slider, tabs, tree and scrollbar were all found silent. Wrapped rather than rewritten, so
    # the injection is "this arm is gone" and not a stale copy of the whole function.
    notify)
        eval "_rt_orig_notify() $(declare -f _ft_state_notify | tail -n +2)"
        _ft_state_notify() { [[ "$2" == slider ]] && return 0; _rt_orig_notify "$@"; } ;;
esac

_RT_DOC=$(for i in $(seq 1 14); do printf 'line %s\n' "$i"; done)

# THE LISTENER LEDGER. A restore puts the USER'S OWN INPUT back, so everything an app derives
# from it — a preview, a computed label, an enabled button — has to be recomputed, and the only
# way an app learns is the hook. _ft_state_notify is a case list keyed by control TYPE, and it
# has now been wrong three times: the radio sharing the checkbox's arm, the multitoggle called
# with no argument, and four types (slider, tabs, tree, scrollbar) simply absent — so a reload
# restored a slider to 7 and told nobody.
#
# Wrapping _ft_hook is what makes this checkable without a list of its own: EVERY event in the
# framework goes through that one function, so the wrapper records the whole stream and the gate
# never has to know which control fires what. That matters because the list is exactly the thing
# that keeps being wrong.
eval "_rt_orig_hook() $(declare -f _ft_hook | tail -n +2)"
_RT_EVENTS=""
_ft_hook() { _RT_EVENTS+="$1:$2 "; _rt_orig_hook "$@"; }
# Empty means EMPTY. `printf '%s\n'` with no arguments still prints one blank line, so the naive
# version handed back a single space — which is not the empty string, so every "did the keys
# announce anything" guard downstream read as yes and four fixtures that announce nothing were
# asked to prove a reload had spoken.
_rt_events() { [[ -n "${_RT_EVENTS// /}" ]] || return 0
               printf '%s\n' $_RT_EVENTS | LC_ALL=C sort -u | tr '\n' ' '; }

# One minimal scene per control type. A builder rather than a table of properties, because
# several of these need children to be anything at all — a select with no options and a table
# with no rows are not controls a user can do anything to, and a fixture that cannot be driven
# proves nothing. Every builder makes the SAME scene twice: once before the save, once after the
# teardown, so the reload has somewhere to land.
_rt_build() {                   # type
    ft-form name=rtapp width=80 height=24 display=flex flexDirection=column alignItems=start
    case $1 in
        label)       ft-label name=rtc text="$_RT_DOC" width=20 height=4 overflowY=auto ;;
        textfield)   ft-textfield name=rtc size=18 rows=4 height=4 value="$_RT_DOC" ;;
        textviewer)  ft-textfield name=rtc size=18 rows=4 height=4 readOnly=true value="$_RT_DOC" ;;
        button)      ft-button name=rtc "Press me" ;;
        checkbox)    ft-checkbox name=rtc "Tick me" ;;
        radio)       ft-radio name=rtc group=rtg "One"
                     ft-radio name=rtc2 group=rtg "Two" ;;
        multitoggle) ft-multitoggle name=rtc text="Priority"
                         ft-option value=low    glyph="Low"
                         ft-option value=medium glyph="Medium"
                         ft-option value=high   glyph="High"
                     end_ft_multitoggle ;;
        slider)      ft-slider name=rtc min=0 max=20 value=5 width=24 showValue=true ;;
        select)      ft-select name=rtc size=3
                         ft-option value=a "Alpha"
                         ft-option value=b "Bravo"
                         ft-option value=c "Charlie"
                         ft-option value=d "Delta"
                     end_ft_select ;;
        table)       ft-table name=rtc rows=3
                         ft-table-header "Key"
                         ft-table-row alpha; ft-table-row bravo;   ft-table-row charlie
                         ft-table-row delta; ft-table-row echo;    ft-table-row foxtrot
                     end_ft_table ;;
        tree)        ft-tree name=rtc rows=6 width=30
                         ft-tree-node "src"          key=src  depth=0 expanded=true
                         ft-tree-node "ft-core.bash" key=core depth=1
                         ft-tree-node "controls"     key=ctl  depth=1 expanded=false
                         ft-tree-node "ft-tree.bash" key=tree depth=2
                         ft-tree-node "README.md"    key=rd   depth=0
                     end_ft_tree ;;
        tabs)        ft-tabs name=rtc width=40 height=10
                         ft-tab name=rtt1 title=One
                             ft-label name=rtl1 text="first body"
                         end_ft_tab
                         ft-tab name=rtt2 title=Two
                             ft-label name=rtl2 text="second body"
                         end_ft_tab
                     end_ft_tabs ;;
        scrollbar)   ft-label name=rtdoc text="$_RT_DOC" width=20 height=4 overflowY=auto
                     ft-scrollbar name=rtc for=rtdoc height=4 ;;
        *)           ft-label name=rtc text="unbuilt: $1" ;;
    esac
    end_ft_form
    FT_ROOT=rtapp
    ft_layout rtapp
}

# The ink as it stands, engagement and all. Painted twice because the first paint of a scene
# legitimately publishes derived properties (a label learns its clientHeight), and a screen
# compared before it has settled is comparing the settling.
_rt_ink() {                     # → FT_RET = the whole app's ink, exactly as it is now
    FT_OUT=""; _ft_redraw_walk rtapp >/dev/null 2>&1; FT_OUT=""
    FT_OUT=""; _ft_redraw_walk rtapp >/dev/null 2>&1
    FT_RET=$FT_OUT; FT_OUT=""
}

# The screen with transient MODE normalised away, on both sides, which is not a loophole: a lit
# border and an editing rung are not what a reload is for, and ft-state does not carry
# `runlevel`. Sent through ft-modify rather than poked, so the rung's own exit script runs — that
# IS how a control leaves edit mode. What remains is the state that is meant to survive.
_rt_screen() {                  # → FT_RET = the comparable screen
    ft-modify rtc runlevel=unfocused >/dev/null 2>&1 || :
    FT_FOCUS=""
    _rt_ink
}

# Drive the control with its own keys and report which ones moved anything. ENTER COMES FIRST AND
# IS NOT OPTIONAL: in this framework focus never captures keys — a merely focused control bubbles
# arrows to focus navigation, which is the whole Enter-to-edit model. Driving without engaging is
# how the first run of this file found eight of thirteen fixtures "inert" while reporting nothing
# about the framework at all. The comparison inside the loop uses the RAW ink, because
# normalising here would disengage the control between every keystroke.
_rt_drive() {                   # → FT_RET = the keys that changed something, space separated
    local k before after moved=""
    FT_FOCUS=rtc
    ft_dispatch_event ENTER >/dev/null 2>&1 || :
    for k in DOWN DOWN RIGHT SPACE PGDN END; do
        _rt_ink; before=$FT_RET
        FT_FOCUS=rtc
        ft_dispatch_event "$k" >/dev/null 2>&1 || :
        _rt_ink; after=$FT_RET
        [[ "$before" != "$after" ]] && moved+="$k "
    done
    FT_RET=$moved
}

note "whatever the keyboard can change, a save and a reload brings back"
_rt_types=(label textfield textviewer button checkbox radio multitoggle slider select table tree tabs scrollbar)
_rt_inert=""
for _ty in "${_rt_types[@]}"; do
    ft_remove rtapp 2>/dev/null
    FT_RADIO_SELECTED=()
    _rt_build "$_ty"
    _rt_drive; _rt_moved=$FT_RET
    if [[ -z "$_rt_moved" ]]; then
        # NOT SILENTLY SKIPPED. A control nothing moved is a control this file did not test, and
        # saying so is the difference between coverage and the appearance of it.
        _rt_inert+="$_ty "
        continue
    fi
    _rt_screen; _rt_want=$FT_RET
    _rt_drove=$(_rt_events)                     # what the user's own keys announced
    ft_state_save "$_RT_D/$_ty" >/dev/null 2>&1
    ft_remove rtapp 2>/dev/null
    FT_RADIO_SELECTED=()
    _rt_build "$_ty"
    _rt_screen; _rt_fresh=$FT_RET               # the rebuilt page, before anything is restored
    _RT_EVENTS=""
    ft_state_load "$_RT_D/$_ty" >/dev/null 2>&1
    _rt_told=" $(_rt_events)"                   # …and what the reload announced
    _rt_screen; _rt_got=$FT_RET
    check "$_ty: the screen comes back as it was left (moved by: ${_rt_moved% })" \
          "$([[ "$_rt_want" == "$_rt_got" ]] && echo same || echo DIFFERENT)" "same"
    # …AND A RELOAD THAT CHANGED SOMETHING MUST SAY SO. Not "the same events": driving a select
    # fires on_activate (an option was CHOSEN — an action) as well as on_change, and a browser
    # restoring a form fires change and not click, so demanding equality would be demanding a
    # defect. And on_activate IS how a checkbox reports state, because it has no on_change — so
    # which events count as state is per-type, which is precisely the sort of list that keeps
    # being wrong here. The list-free question is SILENCE:
    #
    #     if the user's own keys announced something at this control, and the reload actually
    #     changed the screen, the reload must announce something at this control too.
    #
    # Both guards earn their place. Without the first, a label — whose scroll position is
    # restored and which has no hook to report it — would fail. Without the second, a checkbox
    # would: ENTER engages AND toggles it, SPACE toggles it back, so the drive ends where it
    # started and a reload that correctly changes nothing correctly says nothing.
    _rt_ctl=${_rt_drove%%:*}
    if [[ -n "$_rt_drove" && "$_rt_fresh" != "$_rt_got" ]]; then
        check "$_ty: …and a reload that changed something told the app (keys said: ${_rt_drove% })" \
              "$(case "$_rt_told" in *" $_rt_ctl:"*) echo told ;; *) echo SILENT ;; esac)" "told"
    fi
    _RT_EVENTS=""
done

note "…and the fixtures that no key moved, named rather than quietly passed"
# ANTI-VACUITY. Every assertion above needs a control the keys actually changed; a fixture that
# cannot be driven contributes a silent nothing. If this list grows, the file is covering less
# than its name claims, and the number below is what says so.
note "  inert fixtures: ${_rt_inert:-none}"
check "most control types were actually driven" \
      "$(( ${#_rt_types[@]} - $(printf '%s\n' $_rt_inert | grep -c .) >= 8 ))" "1"
# …and the screens being compared are real screens, not two empty strings agreeing.
ft_remove rtapp 2>/dev/null; _rt_build textfield; _rt_screen
check "a screen is a real one"  "$(( ${#FT_RET} > 200 ))" "1"

# ── TEETH ────────────────────────────────────────────────────────────────────
# Everything above passes on the shipped code. Does any of it FAIL when the class of defect this
# file exists for is put back? If not, it is decoration. Re-run ourselves with each injection and
# require red — the same shape tests/test-clip.bash uses, and the same reason.
if [[ -z "$_rt_sab" ]]; then
    note "teeth: each injected defect must turn this file red"
    for _s in restorelist reconciler notify; do
        if FT_ROUNDTRIP_SABOTAGE=$_s bash "$here/tests/test-roundtrip.bash" >/dev/null 2>&1; then
            check "injected '$_s' is caught" "PASSED (blind)" "failed"
        else
            check "injected '$_s' is caught" "failed" "failed"
        fi
    done
fi

summary
