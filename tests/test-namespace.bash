#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  The engine must stay out of the caller's variable namespace.
#
#  Bash is dynamically scoped: a `local` in the calling function is visible to every
#  function it calls. So if the engine stored a control's properties in plain
#  <control>_<property> globals, then a user writing
#
#      local log_rows=$1
#
#  would be writing directly into control `log`'s `rows` property — and ft_remove's
#  unset of that property would clear the user's local out from under them. That is
#  not hypothetical; it silently broke tests/test-growth.bash, where every rebuild
#  after the first one built an empty field.
#
#  Properties therefore live under _ftp_<control>_<property>. These tests use the
#  most natural, most collision-prone names an app author could pick.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null

ft-form name=app

note "a caller's local is not clobbered by a control of the same name"
build_with_local() {
    # `log_rows` is the collision: control `log`, property `rows`.
    local log_rows=$1
    ft-label name=log parent=app text=hi rows="$log_rows"
    ft_get log rows built_rows
    printf '%s %s' "$log_rows" "$built_rows"
}
check "the local survives being used as a property"  "$(build_with_local 42)" "42 42"

note "…and ft_remove unsets the PROPERTY, not the caller's local"
remove_with_local() {
    local log_rows=99
    ft_remove log
    printf '%s' "$log_rows"
}
check "the local still holds its own value afterwards" "$(remove_with_local)" "99"

note "a rebuild inside one scope keeps passing the caller's value"
# The exact shape that failed: release, then rebuild from a local whose name collides.
rebuild_twice() {
    local log_rows=$1 first second
    ft_remove log 2>/dev/null
    ft-label name=log parent=app text=hi rows="$log_rows"
    ft_get log rows first
    ft_remove log 2>/dev/null
    ft-label name=log parent=app text=hi rows="$log_rows"
    ft_get log rows second
    printf '%s %s' "$first" "$second"
}
check "both builds receive the same value" "$(rebuild_twice 7)" "7 7"

note "the storage variable is namespaced, and nothing leaks unprefixed"
ft_remove log 2>/dev/null
ft-label name=log parent=app text=hi rows=5
check "the property is readable through the API"  "$(ft_get log rows; printf '%s' "$FT_RET")" "5"
check "it is stored under _ftp_*"                 "${_ftp_log_rows-unset}" "5"
check "no unprefixed global was created"          "${log_rows+set}" ""
check "…nor for a property with a plain-word name" "${log_text+set}" ""

note "namespacing survives the whole property surface"
ft-textfield name=field parent=app value=hello
ft-modify field value=world
check "ft-modify writes through the namespace"  "$(ft_get field value; printf '%s' "$FT_RET")" "world"
check "…and only there"                         "${field_value+set}" ""
ft_remove_attribute field value
check "removeAttribute clears the namespaced var" "${_ftp_field_value+set}" ""

ft-label name=src parent=app text=cloned rows=3
ft_clone src dup
check "ft_clone copies through the namespace"   "$(ft_get dup rows; printf '%s' "$FT_RET")" "3"
check "…and creates no unprefixed global"       "${dup_rows+set}" ""

note "the engine's per-control SIDE TABLES are namespaced too (_fti_*)"
# Same hazard, different variables: the wrap/extent caches, table cells, tab signatures and
# keymap lists are all per-control arrays living in the global namespace.
ft_keymap kmns
ft_keymap_set kmns key=UP onKey='act_up $this'
check "a keymap list lives under _fti_*"      "${_fti_kmns__list+set}" "set"
check "…and not under the bare name"          "${kmns__list+set}"      ""
_ft_keymap_lookup kmns UP
check "lookup takes the keymap NAME, not the array" "$FT_RET" 'act_up $this'

ft-label name=wrapped parent=app text="a fairly long piece of prose that must wrap somewhere"
ft_wrap_cached wrapped "a fairly long piece of prose that must wrap somewhere" 12
check "the wrap cache is namespaced"          "${_fti_wrapped__wrapkey0+set}" "set"
check "…and leaks nothing unprefixed"         "${wrapped__wrapkey0+set}"      ""

# The collision this guards against, in side-table form: a caller whose local happens to be
# named like a control's cache must be left alone.
wrap_from_a_local() {
    local wrapped__wrapkey0="mine"
    ft_wrap_cached wrapped "different text entirely" 8
    printf '%s' "$wrapped__wrapkey0"
}
check "a caller's local of the same name survives" "$(wrap_from_a_local)" "mine"

# ── The general question: what does a REPAINT put in the namespace? ──────────
# Everything above names a shape the engine was known to get wrong. That is how the families
# below survived: BREC_T, LDR_SIDE, BA_DIR, AP_R, BEFX_VIS, SB_TOTAL — two- and three-letter
# globals used as multi-value return channels, none of them shaped like a control property, so
# not one of the assertions above could see them. They are real collisions, not stylistic ones:
# an app function that calls the PUBLIC ft_redraw_all with `local BA_DIR=north` had it silently
# overwritten to "right" by one repaint, because bash is dynamically scoped and the engine
# assigned a bare name.
#
# So this asks the whole question instead of a list of remembered ones: run a real repaint of a
# scene that exercises every control that publishes such a channel, and require that every
# variable the repaint CREATED is in a namespace the framework declares. A new family cannot be
# added without this going red, which is the only version of this test that keeps working.
note "a repaint creates nothing outside the framework's namespaces"
_ns_scene=$(cat <<'SCENE'
    ft-form name=nsapp width=80 height=24
        ft-label     name=nslab text="a caption long enough to wrap somewhere sensible" width=18
        ft-textfield name=nsfld size=12 value="typed"
        ft-button    name=nsbtn accessKey=o "OK"
        ft-table     name=nstab variant=grid
            ft-table-header "Key" width=8
            ft-table-row "Ctrl+A"
        end_ft_table
        ft-scrollbar name=nsbar for=nslab height=6
    end_ft_form
    FT_ROOT=nsapp
    ft_layout nsapp
    ft-beacon name=nshalo target=nsbtn variant=frame  effect=none
    ft-beacon name=nschip target=nsfld variant=callout effect=none number=1 text="a callout with a leader"
    ft-beacon name=nsarrow target=nslab variant=bigarrow effect=none
    ft_layout nsapp
SCENE
)
# TWO QUESTIONS, NOT ONE. A family can reach the namespace two ways: written on first use
# during a paint, or DECLARED when the file is sourced. The first version of this asked only
# what a repaint created, and the bigarrow's family — initialised at source time, one line of
# `BA_HOME_TOP=0` — walked straight through it. So the child shell samples the names three
# times: before sourcing, after sourcing, and after a real paint.
#
# Run in a child shell because both sets have to be honest, and this file has already sourced
# the framework and painted plenty.
_ns_run() {                     # which → the leaked names of that phase
    FT_NS_SCENE="$_ns_scene" FT_NS_WHICH=$1 bash -c '
        first=$(compgen -v | sort)
        export FT_NO_WTFIX=1 FT_RECORD="" FT_STATE_AUTOLOAD=0
        source "'"$here"'/fruity-tui.bash" >/dev/null 2>&1
        ft_init >/dev/null 2>&1
        exec {FT_TTY}>/dev/null
        FT_COLS=80; FT_ROWS=24; FT_COLOR_MODE=256; FT_USE_UTF8=1
        sourced=$(compgen -v | sort)
        eval "$FT_NS_SCENE" >/dev/null 2>&1
        painting=$(compgen -v | sort)
        FT_OUT=""; _ft_redraw_walk nsapp >/dev/null 2>&1; _ft_composite_overlays >/dev/null 2>&1
        _ft_beacon_frame nsarrow beacon >/dev/null 2>&1      # the arrow resolves its geometry here
        painted=$(compgen -v | sort)
        # The namespaces the framework declares: FT_/_FT_ (engine state), _ftp_/_fti_
        # (per-control), `this` (the event target a listener reads) — plus this script own
        # bookkeeping and bash own.
        # …plus every name that already carries a leading underscore, which is this tree file
        # -private marker. That concession is deliberate and it is NOT the hazard measured
        # here: the collision that bit was with names an APP AUTHOR WOULD PLAUSIBLY WRITE AS A
        # LOCAL — BA_DIR, SB_TOTAL, LDR_SIDE, BREC_T — and nobody writes `local _RT_T`. The
        # underscored population is real (47 at this commit: the router list _RT_*, the
        # placement tuning constants, _SEL_*, _MD_*, _KF_*) and mostly lives outside controls/;
        # tightening this to demand FT_/_FT_ of those too is a separate sweep, and this line is
        # where it would start.
        _keep() { grep -vE "^(FT_|_FT_|_|this$|first$|sourced$|painting$|painted$|BASH|COMP|PIPESTATUS|OPTIND|REPLY)"; }
        if [[ "$FT_NS_WHICH" == declared ]]; then
            comm -13 <(printf "%s\n" "$first")    <(printf "%s\n" "$sourced")  | _keep
        else
            comm -13 <(printf "%s\n" "$painting") <(printf "%s\n" "$painted")  | _keep
        fi
    ' 2>/dev/null | tr '\n' ' '
}
_ns_declared=$(_ns_run declared)
check "sourcing the framework declares no bare global" "${_ns_declared% }" ""
_ns_created=$(_ns_run painted)
check "a repaint creates no bare global"               "${_ns_created% }" ""

# …and the collision itself, kept by name, because a general rule is easy to weaken by accident
# and this is the frame it was measured in: an ordinary app function that calls the PUBLIC
# ft_redraw_all, with locals named the way those channels used to be. Every one of these came
# back changed before the rename — BA_DIR to "right", BREC_T to 0, LDR_SIDE to "below".
eval "$_ns_scene" >/dev/null 2>&1
_app_that_repaints() {
    local BA_DIR=north BREC_T=7 LDR_SIDE=mySide SB_TOTAL=99 PS_TURNS=3 BEFX_VIS=5
    ft_redraw_all nsapp >/dev/null 2>&1
    printf '%s %s %s %s %s %s' "$BA_DIR" "$BREC_T" "$LDR_SIDE" "$SB_TOTAL" "$PS_TURNS" "$BEFX_VIS"
}
check "an app's locals survive a public repaint" "$(_app_that_repaints)" "north 7 mySide 99 3 5"

summary
