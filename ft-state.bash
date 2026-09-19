#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — ft-state.bash   (save and reload the whole UI)
#
#  Ctrl+S saves. Not "the document" — the UI: every control's properties, which is where a
#  text field's typed value lives, plus the state that is NOT a property (a caret position, a
#  scroll offset, a selection anchor) and which control had focus. Reloading puts the user
#  back exactly where they were, mid-sentence and mid-scroll.
#
#  THE FORMAT IS LENGTH-PREFIXED, NOT QUOTED. A value can contain newlines, tabs, quotes,
#  escape sequences and NUL-free binary; the obvious `printf %q` + `eval` round-trip would
#  make reloading a state file equivalent to executing it, which is not a property a save file
#  should have. Every value here is written as a byte count followed by exactly those bytes,
#  so the reader never interprets anything:
#
#      ft-state 2
#      focus <name>
#      ctl <name> <type>
#      prop <name> <prop> <bytes>
#      <bytes bytes>\n
#      tf <name> <caret> <scroll> <vscroll> <anchor|->
#
#  BYTES MEANS BYTES, WHICH BASH ONLY COUNTS IN THE C LOCALE. `${#v}` and `read -N` both count
#  CHARACTERS in a UTF-8 locale — a count that agrees with itself and with nothing else. Version
#  1 wrote it that way, so a file saved by a run in one locale and read by a run in another
#  desynchronised at the first non-ASCII character: the value swallowed the record header that
#  followed it, and every value after that was garbage. It is not an exotic situation — an app
#  started from cron or a systemd unit lands in the C locale, the same app started from a
#  terminal does not, and a state file under XDG is meant to outlive both.
#
#  Version 2 counts bytes, through _ft_state_bytelen and _ft_state_readvalue and nowhere else.
#  Version 1 files are still read, with the character semantics they were written with — for
#  the ASCII files that is bit-identical, and for the rest it is what they already meant.
#
#  Restoring applies onto the tree the app has ALREADY built — it does not reconstruct
#  controls. That is deliberate: a control's behaviour lives in its prototype, its hooks and its
#  keymaps, none of which belong in a data file. The app builds its UI as usual and then asks
#  for the state back.
#
#  Depends on ft-forms.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_STATE_LOADED:-}" ]] && return 0
_FT_STATE_LOADED=1

# WHERE IT SAVES. `.ft-state` in the CURRENT DIRECTORY was wrong in the way that matters:
# the file an app saves to then depends on where it was launched from, so a save and the
# next run can disagree and the state appears to "reset entirely" — and a hidden file in
# a directory you have to guess is one the user cannot check. The default is now per-APP
# and absolute (same file whatever directory you start in), it follows the XDG state
# convention, and ft_state_save hands back the path so a confirmation can SAY where it
# went. An app that wants a state file of its own just sets FT_STATE_FILE.
: "${FT_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/fruity-tui}"
_ft_state_appid() {             # → FT_RET = a filename-safe id for the running app
    local a=${0##*/}; a=${a%.bash}; a=${a//[^A-Za-z0-9._-]/_}
    [[ -z "$a" || "$a" == .* ]] && a=app
    FT_RET=$a
}
if [[ -z "${FT_STATE_FILE:-}" ]]; then
    _ft_state_appid; FT_STATE_FILE="$FT_STATE_DIR/$FT_RET.ftstate"
fi

# RELOADING IS THE OTHER HALF OF SAVING. A save the app never reads back is a file, not a
# feature — "it resets entirely" is what the user sees. ft-run restores automatically when
# a state file for this app exists, after the app has built its UI and before the first
# paint, so the very first frame is where you left off. FT_STATE_AUTOLOAD=0 opts out (and
# an app that wants to ask first can set it to 0 and call ft_state_load itself).
: "${FT_STATE_AUTOLOAD:=1}"

# WHAT COMES BACK. The file holds every property of every control — a complete snapshot, which
# is what you want for inspecting or debugging one. Re-applying all of it is another matter: a
# control's width, display, colours and text are the APP's design, and restoring last week's
# copy of them would silently revert whatever the developer changed since. So the default
# restores only what the USER can alter through the UI, and the app opts into more.
#
#   FT_STATE_RESTORE_PROPS  the properties a restore re-applies (user state)
#   FT_STATE_RESTORE_ALL=1  re-apply everything in the file instead (exact snapshot)
#
# THIS LIST IS A CURATED ALLOWLIST AND CANNOT STOP BEING ONE — no rule distinguishes "the user
# changed it" from "the developer changed it" except somebody deciding. What it CAN stop being is
# silently incomplete: tests/test-roundtrip.bash drives every control with its own keys and
# demands a save and a reload reproduce the screen, so a control that grows a new piece of user
# state and is not added here turns that file red. `activeTab` was the standing proof that it was
# needed — a tabbed pane SAVED which tab you were on (the record is in the file) and the restore
# read it and threw it away, so an app left on its Settings tab came back on the first one.
: "${FT_STATE_RESTORE_PROPS:=value scrollTop scrollLeft selectedIndex checked cursor expanded activeTab parkedTop parkedLeft}"
: "${FT_STATE_RESTORE_ALL:=0}"
_ft_state_wanted() {            # prop → 0 if a restore should apply it
    (( FT_STATE_RESTORE_ALL )) && return 0
    case " $FT_STATE_RESTORE_PROPS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Per-control state that is NOT stored as a property and would otherwise be lost. Keyed by
# control TYPE, so a new control can opt in without this file knowing about it in advance.
_ft_state_extra_save() {        # name type → echoes any extra records
    local n=$1 t=$2
    case $t in
        textfield)
            # THE TWO OFFSETS ARE PROPERTIES NOW (scrollTop/scrollLeft, both already in
            # FT_STATE_RESTORE_PROPS), so the generic route carries them and these two fields are
            # redundant — kept, and kept TRUTHFUL, because the record is positional and a file
            # this build writes has to stay readable by one that predates the move. What is left
            # that only this record can carry is the caret and the selection anchor.
            local _tfv _tfh
            _ft_get_raw "$n" scrollTop;  _tfv=$FT_RET; case $_tfv in ''|*[!0-9]*) _tfv=0 ;; esac
            _ft_get_raw "$n" scrollLeft; _tfh=$FT_RET; case $_tfh in ''|*[!0-9]*) _tfh=0 ;; esac
            printf 'tf %s %s %s %s %s\n' "$n" \
                "${FT_TEXTFIELD_CARET[$n]:-0}" "$_tfh" "$_tfv" "${FT_TEXTFIELD_ANCHOR[$n]:--}"
            ;;
        # A RADIO USED TO NEED A RECORD HERE, and no longer does. Its selection lived only in
        # FT_RADIO_SELECTED[group], so saving properties saved everything about a radio except
        # which one the user picked. `checked` is now the property it always should have been —
        # already in FT_STATE_RESTORE_PROPS — so the generic route both saves and restores it,
        # and the restore goes through _ft_setprop, whose reconciler rebuilds the group index.
    esac
}
_ft_state_extra_load() {        # type name fields…
    case $1 in
        tf) local n=$2
            FT_TEXTFIELD_CARET[$n]=${3:-0}
            # Applied as PROPERTIES, not as table pokes — the same route everything else takes,
            # and the reason this arm still reads the two offset fields at all: a file written by
            # a build that predates the move has them nowhere else. Writing them again after the
            # generic restore has already done so costs one identical write.
            if [[ -n "${FT_TYPE[$n]:-}" ]]; then
                _ft_setprop "$n" scrollLeft "${4:-0}"
                _ft_setprop "$n" scrollTop  "${5:-0}"
            fi
            if [[ "${6:--}" == "-" ]]; then unset "FT_TEXTFIELD_ANCHOR[$n]"; else FT_TEXTFIELD_ANCHOR[$n]=$6; fi
            ;;
        # `rad` is no longer written (see above); kept so a file saved by an older build still
        # restores the user's choice. Applied as the property, not as a table poke, so it takes
        # the same route everything else does.
        rad) [[ -n "${2:-}" && -n "${FT_TYPE[${2}]:-}" ]] && _ft_setprop "$2" checked true ;;
    esac
}

# How a control announces "my value changed", keyed by TYPE — the same hook the user's own
# action would fire, so an app needs no restore-specific code path.
_ft_state_notify() {            # name type
    case $2 in
        textfield|select)
            _ft_get_raw "$1" value; _ft_hook "$1" on_change "$FT_RET" ;;
        radio)
            # A RADIO IS NOT A CHECKBOX HERE, and sharing the arm made the restore announce the
            # opposite of what it restored. A checkbox's `value` IS its truth — false ↔ true, the
            # two option values. A radio's `value` is its OPTION value, "like <select>'s"
            # (controls/ft-radio.bash says so where it declines to touch it), which is its own
            # name unless the author set one — never the string `true`. So `value == true` was
            # false for every radio there has ever been, and a restore that had just selected one
            # fired on_deactivate at it.
            #
            # `checked` is the radio's selection, and a real property since it became one; that
            # is the thing to ask.
            _ft_get_raw "$1" checked
            if [[ "$FT_RET" == true ]]; then _ft_hook "$1" on_activate
            else _ft_hook "$1" on_deactivate; fi ;;
        checkbox|multitoggle)
            # These have no on_change: they report through activate/deactivate — and this route
            # must fire the SAME event with the SAME argument as ft_multitoggle_cycle, or a
            # restore tells the app something no ordinary interaction ever would.
            #
            # It did neither. `value == true` is the CHECKBOX's question, and a multitoggle's
            # options are not booleans — so a 3-state control restored to `high` was announced
            # with on_deactivate, the event the prototype header defines as "a checkbox
            # unchecking".
            # And the hook was called with NO ARGUMENT while the header documents "$1 is the new
            # value" and every other route passes it, so a handler written to that contract dies
            # on `$1: unbound variable` in the `set -u` apps this framework has.
            #
            # The predicate below is ft_multitoggle_cycle's, verbatim.
            _ft_get_raw "$1" value; local _v=$FT_RET
            local _ev=on_activate
            [[ "$_v" == false ]] && ft_has_listener "$1" deactivate && _ev=on_deactivate
            _ft_hook "$1" "$_ev" "$_v" ;;
        # FOUR TYPES WERE SIMPLY ABSENT, and each of them announces a change in ordinary use —
        # so a reload restored their state and told the app nothing, leaving every derived label
        # and enable/disable rule hanging off the hook stale on the screen the user came back to.
        # Measured: a slider restored to 7 and a tabs restored to its second tab, with neither
        # onChange fired, while the checkbox beside them (which has an arm) reported correctly.
        #
        # EACH ARM PASSES WHAT THAT CONTROL'S OWN VERB PASSES, which is the only contract a
        # handler is written against — ft_slider_set sends the value, _ft_tabs_select the index,
        # the tree its node KEY (not its cursor), ft_scrollbar_set the offset. That is also this
        # list's whole failure mode: it is a second copy of something each prototype already
        # knows, and it has now been wrong three times — the radio sharing the checkbox's arm, the
        # multitoggle called with no argument, and these four missing. tests/test-roundtrip.bash
        # gates the omission now, whoever writes the next control.
        slider)
            _ft_get_raw "$1" value; _ft_hook "$1" on_change "$FT_RET" ;;
        tabs)
            _ft_get_raw "$1" activeTab; _ft_hook "$1" on_change "${FT_RET:-0}" ;;
        tree)
            _ft_get_raw "$1" value; _ft_hook "$1" on_change "$FT_RET" ;;
        scrollbar)
            # A bar's offset is axis-specific, and for a `for=` bar it lives on the TARGET —
            # _ft_sb_state is the one place that knows both, so ask it rather than guess a name.
            _ft_sb_state "$1"; _ft_hook "$1" on_scroll "$FT_SCROLLBAR_POSITION" ;;
    esac
    return 0
}

# The two places the file's byte counts are produced and consumed. Both switch the locale for
# exactly one operation — see the note at the top of this file — and nothing else in a save or
# a load runs under it, so an app hook fired by a restore still sees the locale it expects.
_ft_state_bytelen() {           # string → FT_RET (bytes, whatever the caller's locale is)
    local LC_ALL=C
    FT_RET=${#1}
}
_ft_state_readvalue() {         # fd len unit → FT_RET (exactly LEN, then the terminating \n)
    # `:-` because this is set by ft_state_load and read here through dynamic scope: called
    # from anywhere else — a test, a future caller — an unset name is a hard error under
    # `set -u`, which apps do run with. Empty is the right value anyway: no override.
    local LC_ALL=C; [[ "$3" == chars ]] && LC_ALL=${_FT_STATE_OUTER_LC:-}   # a version 1 file
    local _nl
    FT_RET=""
    (( $2 > 0 )) && IFS= read -r -N "$2" FT_RET <&"$1"
    IFS= read -r -N 1 _nl <&"$1"
}

_ft_state_walk() {              # name — emit this control and its descendants
    local n=$1 kid p v
    printf 'ctl %s %s\n' "$n" "${FT_TYPE[$n]:-}"
    for p in ${FT_PROPS[$n]:-}; do
        # Ask through the normal read so a DEFERRED value (a textfield mid-edit keeps its text
        # in the line store, not in the property) is materialised before it is written out.
        _ft_get_raw "$n" "$p"; v=$FT_RET
        _ft_state_bytelen "$v"
        printf 'prop %s %s %s\n' "$n" "$p" "$FT_RET"
        printf '%s\n' "$v"
    done
    _ft_state_extra_save "$n" "${FT_TYPE[$n]:-}"
    for kid in ${FT_KIDS[$n]:-}; do _ft_state_walk "$kid"; done
}

# ft_state_save [FILE] → FT_RET = the path written. Non-zero if it could not be written.
ft_state_save() {
    local file=${1:-$FT_STATE_FILE} root=${FT_ROOT:-}
    [[ -n "$root" && -n "${FT_TYPE[$root]:-}" ]] || { FT_RET=""; return 1; }
    # The state directory is created on demand. This forks, which running-app code never
    # does — but this is an explicit Ctrl+S, not a render or an input path, and a save that
    # fails because a directory is missing is not a save.
    local dir=${file%/*}
    [[ "$dir" != "$file" && -n "$dir" && ! -d "$dir" ]] && { mkdir -p "$dir" 2>/dev/null || { FT_RET=""; return 1; }; }
    { printf 'ft-state 2\n'
      printf 'focus %s\n' "${FT_FOCUS:-}"
      _ft_state_walk "$root"
    } > "$file" 2>/dev/null || { FT_RET=""; return 1; }
    FT_RET=$file
    return 0
}

# ft_state_load [FILE] → apply onto the tree that already exists. Controls in the file that
# are not in the tree are skipped (the app may have changed shape between runs); controls in
# the tree that are not in the file keep what they have.
ft_state_load() {
    local file=${1:-$FT_STATE_FILE}
    [[ -r "$file" ]] || return 1
    local line kind n p len v focus="" ver changed="" unit=bytes
    exec {_fts}< "$file" || return 1
    IFS= read -r line <&$_fts || { exec {_fts}<&-; return 1; }
    ver=${line#ft-state }
    [[ "$line" == "ft-state "* ]] || { exec {_fts}<&-; return 1; }
    case $ver in
        2) unit=bytes ;;
        1) unit=chars ;;        # written before the count was locale-independent
        *) exec {_fts}<&-; return 1 ;;
    esac
    local _FT_STATE_OUTER_LC=${LC_ALL:-}    # what a version 1 file's counts were measured in
    while IFS= read -r line <&$_fts; do
        kind=${line%% *}
        case $kind in
            focus) focus=${line#focus }; focus=${focus% } ;;
            ctl)   : ;;                 # structure is the app's; we only restore state
            prop)
                # `prop NAME PROP LEN` then exactly LEN bytes and a newline. read -N takes the
                # bytes verbatim, so a value containing newlines survives untouched.
                local rest=${line#prop }
                n=${rest%% *}; rest=${rest#* }
                p=${rest%% *}; len=${rest##* }
                _ft_state_readvalue "$_fts" "$len" "$unit"; v=$FT_RET
                if [[ -n "${FT_TYPE[$n]:-}" ]] && _ft_state_wanted "$p"; then
                    # Note the ones that actually CHANGE, so the app can be told afterwards.
                    _ft_get_raw "$n" "$p"
                    [[ "$FT_RET" != "$v" ]] && changed+=" $n"
                    _ft_setprop "$n" "$p" "$v"
                fi
                ;;
            # ANY other record is a control-kind extra (see _ft_state_extra_save). Routed
            # generically, not by a per-kind case here: the first extra record after `tf` was a
            # radio's group selection, it was written correctly, and this switch silently
            # dropped it — a save-and-restore that lost the user's choice with nothing to see.
            *)     local -a f=($line)
                   [[ -n "${f[1]:-}" && -n "${FT_TYPE[${f[1]}]:-}" ]] && _ft_state_extra_load "${f[@]}" ;;
        esac
    done
    exec {_fts}<&-
    [[ -n "$focus" && -n "${FT_TYPE[$focus]:-}" ]] && ft_focus "$focus"
    [[ -n "${FT_ROOT:-}" ]] && ft_layout "$FT_ROOT"
    # TELL THE APP WHAT CHANGED. A restore puts the USER'S OWN INPUT back, so the app has to
    # learn about it exactly as if they had typed it — anything derived from a field
    # (a preview, a computed label, an enabled/disabled button) is otherwise left showing what
    # the app built at startup while the field shows the restored text. demo/textfield-demo
    # displayed `user = "admin"` under a Username field reading `ZaphodBadmin`.
    # After the layout, so a hook sees a settled tree; deduplicated, so a control whose value
    # AND scroll were both restored is announced once.
    local seen=" " c
    for c in $changed; do
        [[ "$seen" == *" $c "* ]] && continue
        seen+="$c "
        [[ -n "${FT_TYPE[$c]:-}" ]] && _ft_state_notify "$c" "${FT_TYPE[$c]}"
    done
    return 0
}
