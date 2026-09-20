#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tests/test-incremental.bash — after ONE action, the frame the incremental path paints must
#  leave the screen a full repaint would have made. Cell for cell, colour included, blanks
#  included, for every control, every property, every key and every public verb.
#
#  EVERY OTHER GATE IN THIS SUITE PAINTS FROM SCRATCH. test-roundtrip, test-stale, test-propkind
#  and the rest render with _ft_redraw_walk or ft_repaint_all, which asks every control to paint.
#  The running app does not: ft_redraw_dirty asks only the controls somebody marked — FT_DIRTY,
#  FT_REPAIR, the damage rects, the overlays they touch. So the defect "the wrong controls were
#  asked" is invisible to all of them, and it is not hypothetical: `ft-scrollbar for=doc` drew
#  its thumb where the content used to be for as long as nothing entered the bar in FT_DIRTY when
#  the document scrolled, and a full-repaint gate cannot see that, because a full repaint asks
#  the bar anyway. The class is "who gets asked", and only an incremental frame exercises it.
#
#  THE SHAPE OF ONE CASE:
#
#      the screen as a cold full repaint left it
#        → the action, inside a coalesced burst, exactly as ft-run dispatches one
#        → settle: ft_reflow_flush, ft_redraw_dirty                  (bytes → ID.inc)
#        → go_cold, ft_repaint_all                                    (bytes → ID.full)
#
#  tests/incremental-screens.py feeds ID.inc onto the previous full repaint and compares that
#  screen with ID.full by what a person would see (tools/screen-cells.py `appearance`).
#
#  THE ORACLE IS COLD, AND THAT IS THE INSTRUMENT, NOT THOROUGHNESS. A warm ft_repaint_all serves
#  every unchanged control its retained display block — so a control that should have repainted
#  and was not asked replays the same stale block in the "full" frame, and both sides agree on
#  the wrong picture. Measured with ft_dirty's dependency walk removed (the scrollbar defect put
#  back): a warm oracle scored 12 of 12 cases identical; a cold one failed exactly the four that
#  scroll the bar's target. go_cold lives in tests/_harness.bash, shared with test-stale, which
#  fails by name if a cache is ever added that it does not drop.
#
#  THE ORACLE ALSO RESETS THE BASE, and that is deliberate. Each case starts from a screen and a
#  set of caches that are true, so a defect is reported at the case that made it and is not
#  inherited by every case after it.
#
#  WHAT IS WRITTEN, AND WHY IT IS NOT A HAND LIST OF THINGS THAT MATTER. Every name in
#  FT_PROP_KIND — the table that says what the engine owes a change — is written with a sample
#  value on every fixture's subject, and then put back (by ft-modify when it had a value, by
#  ft_remove_attribute when it did not, so both routes are driven). A name with no sample must be
#  EXEMPTED here with a reason, and the file fails by name when a new property arrives without
#  either — so the corpus grows with the framework instead of with somebody's memory.
#
#  Fixtures run in parallel, one bash per control type, because each case costs a cold repaint
#  and there are a few thousand of them.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1 FT_RECORD=""
_INC_ROWS=22 _INC_COLS=70

_INC_DOC=$(for i in $(seq 1 14); do printf 'line %s\n' "$i"; done)
_INC_TYPES=(label textfield textviewer button checkbox radio multitoggle slider select table tree
            tabs scrollbar frame div heading boxheader keylegend statusbar beacon)
# The teeth below re-run this file on the one fixture that shows each injected defect.
[[ -n "${FT_INCREMENTAL_TYPES:-}" ]] && read -r -a _INC_TYPES <<< "$FT_INCREMENTAL_TYPES"

# ── the sample for each property ─────────────────────────────────────────────
# `!` means "the opposite of what the control has now", for booleans whose default differs by
# prototype. A TYPE:NAME entry overrides NAME for that control type.
declare -A _INC_SAMPLE=(
    [acceptsTab]=false         [accessKey]=z              [activateToEdit]='!'
    [activeTab]=1              [alignItems]=center        [alignSelf]=center
    [backgroundColor]=blue     [border]='!'               [borderColor]=red
    [borderGlyph]='#'          [borderRadius]=1           [borderStyle]=double
    [borderWidth]=2            [boxSizing]=content-box    [capStyle]=boxed
    [checkmarkVariant]=unicode [class]=hot                [colLines]='!'
    [color]=red                [currentLineHighlight]='!' [cursor]=3
    [cursorStyle]=bar          [depth]=1                  [disabled]=true
    [display]=none             [editHint]="edit hint"     [expanded]='!'
    [flexBasis]=8              [flexDirection]=column     [flexGrow]=1
    [flexShrink]=0             [focusable]='!'            [for]=""
    [gap]=1                    [glyph]='*'                [headerLine]='!'
    [height]=3                 [indicator]=check          [justifyContent]=center
    [keys]="Enter=Open  Del=Delete"                       [left]=2
    [margin]=1                 [markdown]='!'             [max]=3
    [maxHeight]=2              [maxLength]=3              [maxWidth]=6
    [min]=2                    [minHeight]=5              [minWidth]=30
    [multiple]='!'             [newlineIndicator]='!'     [open]='!'
    [orientation]=column       [overflow]=hidden          [overflowX]=auto
    [overflowY]=hidden         [padding]=1                [paddingBottom]=1
    [paddingLeft]=1            [paddingRight]=1           [paddingTop]=1
    [placeholder]="a hint"     [position]=absolute        [readOnly]='!'
    [rowLines]='!'             [rows]=2                   [scroll]=2
    [scrollLeft]=2             [scrollTop]=2              [scrollbar]='!'
    [selected]='!'             [selectedIndex]=2          [showLineNumbers]='!'
    [showSelected]='!'         [showValue]='!'            [size]=4
    [status]="busy now"        [step]=5                   [striped]='!'
    [style]=heavy              [text]="changed text"      [textAlign]=right
    [title]="Renamed"          [top]=1                    [value]="a new value"
    [variant]=track            [visibility]=hidden        [width]=12
    [wrap]='!'                 [wrapIndicator]='!'
    [slider:value]=9           [select:value]=c           [multitoggle:value]=high
    [checkbox:value]=true      [radio:value]=true         [scrollbar:value]=3
    [tabs:value]=1             [table:variant]=plain      [beacon:variant]=callout
    [statusbar:importance]=high
)
# Names that are NOT written, each with the reason. A name here is a claim about the framework,
# so it has to be true: re-read the reason before adding to this list.
declare -A _INC_EXEMPT=(
    [name]="identity — a control is renamed by rebuilding it"
    [parent]="refused by ft-modify; the tree moves by verb, and ft_append is driven below"
    [id]="a tree node's identity in the expansion record, not something it draws"
    [group]="a radio's identity; which radio is chosen is driven by its verbs below"
    [draw]="names a paint FUNCTION; what that function paints is the app's"
    [eventListeners]="listener bookkeeping; paints nothing"
    [keymap]="key bindings; paints nothing (the legend follows keys=, which is written)"
    [keymode]="reserved (emacs|vi) and read by no painter"
    [states]="declares the runlevel ladder at construction"
    [type]="a construction-time discriminator"
    [autofocus]="read once, when the focus ring is first built"
    [cursorStartAtCharacter]="read once, when a textfield is built"
    [cursorStartAtLine]="read once, when a textfield is built"
    [clientHeight]="published BY the draw — a measurement, not an input"
    [clientWidth]="published BY the draw — a measurement, not an input"
    [scrollHeight]="published BY the draw — a measurement, not an input"
    [scrollWidth]="published BY the draw — a measurement, not an input"
    [importance]="a statusbar message's priority; only statusbar:importance is sampled"
    [animation]="time: an animation's frames arrive by tick, not by one action"
    [animationDelay]="time: see animation"          [animationDuration]="time: see animation"
    [animationTimingFunction]="time: see animation" [numberOfTones]="time: see animation"
    [sweepWidth]="time: the statusbar sweep"
    [activateAnimationTypingDelay]="time: see animation"
    [activateBorderAnimation]="time: see animation"
    [transition]="time: a transition blends over frames (tests/test-transition.bash)"
    [transitionDuration]="time: see transition"     [transitionProperty]="time: see transition"
    [transitionTimingFunction]="time: see transition"
)
for _i in borderAnimationCrest borderAnimationCrests borderAnimationDepth borderAnimationGlow \
          borderAnimationRate borderAnimationShear borderAnimationStep; do
    _INC_EXEMPT[$_i]="time: the border shimmer runs by tick"
done
for _i in '' 1 2 3 4 5 6 7 8 9; do
    _INC_EXEMPT[helpAccel$_i]="the F1 help screen's text, painted by the help modal and not the form"
    _INC_EXEMPT[helpLabel$_i]=${_INC_EXEMPT[helpAccel$_i]}
    _INC_EXEMPT[helpText$_i]=${_INC_EXEMPT[helpAccel$_i]}
done
for _i in itemCopied saved textCopied; do
    _INC_EXEMPT[text__$_i]="a message template, shown by ft_emit_status and not stored on screen"
done

# ── sabotage, for the teeth ──────────────────────────────────────────────────
# Each injection puts back one way the incremental path has asked the wrong controls, and the
# file must go red FOR THAT REASON. Applied in the fixture process, before anything is built.
_inc_sabotage() {
    case "${FT_INCREMENTAL_SABOTAGE:-}" in
        # ft_dirty stops walking the paint-dependency table: the bound scrollbar, as it shipped.
        nowalk)  ft_dirty() { FT_DIRTY[$1]=1; unset "FT_RETAINED_TOKEN[$1]" "FT_RETAINED_BLOCK[$1]"; } ;;
        # A removed or hidden subtree stops giving back the cells it inked. (Hiding has other
        # ways to erase — a reflow, a beacon's own reprop — so it is removal that shows it.)
        hidedamage) ft_damage_subtree() { :; } ;;
        # An inherited property repaints the node and not the subtree that inherits it — the
        # hand-rolled `ft_dirty_subtree` css-demo used to carry on three handlers.
        inherit) ft_dirty_subtree() { ft_dirty "$1"; } ;;
        # A repainted container stops repairing the children it paints over: a frame's
        # borderColor blanked its contents.
        container) _ft_repair_subtree() { FT_REPAIR[$1]=1; } ;;
        # The partial redraw's order goes back to a depth sort that paints inside hidden
        # subtrees: switching tabs painted the hidden body over the one just shown.
        paintorder) _ft_paint_order() {
                        local -a names=() depths=(); local name n d i j tn td
                        for name in "$@"; do
                            d=0; n=${FT_PARENT[$name]:-}
                            while [[ -n "$n" ]]; do (( d++ )); n=${FT_PARENT[$n]:-}; done
                            names+=("$name"); depths+=("$d")
                        done
                        for (( i=1; i<${#names[@]}; i++ )); do
                            tn=${names[i]}; td=${depths[i]}; j=$(( i-1 ))
                            while (( j >= 0 )) && (( depths[j] > td )); do
                                names[j+1]=${names[j]}; depths[j+1]=${depths[j]}; (( j-- ))
                            done
                            names[j+1]=$tn; depths[j+1]=$td
                        done
                        FT_PAINT_ORDER=("${names[@]}"); } ;;
        # ft_remove_attribute forgets that leaving or rejoining the flow MOVES the siblings —
        # the `position` arm its private copy of ft-modify's dispatch never had.
        removeroute) eval "_inc_owed_original() $(declare -f _ft_prop_owed | tail -n +2)"
                     _ft_prop_owed() {
                         [[ "${FUNCNAME[1]}" == ft_remove_attribute && "$2" == position ]] && return 0
                         _inc_owed_original "$@"; } ;;
    esac
}
# injection → the fixture that shows it → the item that must fail
_INC_TEETH=("nowalk scrollbar verb"          "hidedamage label tree"
            "inherit div color"              "container frame borderColor"
            "paintorder tabs verb"           "removeroute label position")

# ── one fixture, in its own process ──────────────────────────────────────────
if [[ "${1:-}" == --fixture ]]; then
    _INC_TYPE=$2 _INC_DIR=$3
    source "$here/fruity-tui.bash"
    ft_init
    exec {FT_TTY}>/dev/null
    FT_COLOR_MODE=256; FT_USE_UTF8=1; FT_ROWS=$_INC_ROWS; FT_COLS=$_INC_COLS
    _inc_sabotage
    mkdir -p "$_INC_DIR"; : > "$_INC_DIR/cases"
    _INC_N=0

    # A stylesheet, so `class=` and a rule edit have something to change.
    ft_stylesheet name=incsheet style='.hot { color: red; background-color: blue; }'

    # THE SCENE AROUND THE SUBJECT IS PART OF THE TEST. A sibling beside it and a label below it
    # are what a resize, a move or a hide uncovers, and a keys=auto legend derives its paint from
    # whichever control has focus.
    _inc_build() {
        ft-form name=app width=$_INC_COLS height=$_INC_ROWS display=flex flexDirection=column alignItems=start
            ft-div name=row display=flex flexDirection=row alignItems=start gap=1
            _INC_SUBJECTS=sub
            case $_INC_TYPE in
                label)       ft-label name=sub text="$_INC_DOC" width=20 height=4 overflowY=auto ;;
                textfield)   ft-textfield name=sub size=18 rows=4 height=4 value="$_INC_DOC" ;;
                textviewer)  ft-textfield name=sub size=18 rows=4 height=4 readOnly=true value="$_INC_DOC" ;;
                button)      ft-button name=sub "Press me" ;;
                checkbox)    ft-checkbox name=sub "Tick me" ;;
                radio)       ft-radio name=sub group=incg "One"
                             ft-radio name=sub2 group=incg "Two" ;;
                multitoggle) ft-multitoggle name=sub text="Priority"
                                 ft-option value=low    glyph="Low"
                                 ft-option value=medium glyph="Medium"
                                 ft-option value=high   glyph="High"
                             end_ft_multitoggle ;;
                slider)      ft-slider name=sub min=0 max=20 value=5 width=24 showValue=true ;;
                select)      ft-select name=sub size=3
                                 ft-option value=a "Alpha"
                                 ft-option value=b "Bravo"
                                 ft-option value=c "Charlie"
                                 ft-option value=d "Delta"
                             end_ft_select ;;
                table)       ft-table name=sub rows=3
                                 ft-table-header "Key"
                                 ft-table-row alpha; ft-table-row bravo;   ft-table-row charlie
                                 ft-table-row delta; ft-table-row echo;    ft-table-row foxtrot
                             end_ft_table ;;
                tree)        ft-tree name=sub rows=5 width=24
                                 ft-tree-node "src"          id=src  depth=0 expanded=true
                                 ft-tree-node "ft-core.bash" id=core depth=1
                                 ft-tree-node "controls"     id=ctl  depth=1 expanded=false
                                 ft-tree-node "ft-tree.bash" id=tree depth=2
                                 ft-tree-node "README.md"    id=rd   depth=0
                             end_ft_tree ;;
                tabs)        ft-tabs name=sub width=30 height=7
                                 ft-tab name=tab1 title=One
                                     ft-label name=body1 text="first body"
                                 end_ft_tab
                                 ft-tab name=tab2 title=Two
                                     ft-label name=body2 text="second body"
                                 end_ft_tab
                             end_ft_tabs ;;
                scrollbar)   ft-label name=doc text="$_INC_DOC" width=20 height=4 overflowY=auto
                             ft-scrollbar name=sub for=doc height=4
                             _INC_SUBJECTS="sub doc" ;;
                frame)       ft-frame name=sub title="A frame" width=24 height=5
                                 ft-label name=inner text="inside the frame"
                             end_ft_frame ;;
                # A container with NO DRAW of its own: nothing repaints its children for it, so
                # an inherited property is the whole of what reaches them.
                div)         ft-div name=sub display=flex flexDirection=column
                                 ft-label name=inner text="inside the div"
                                 ft-button name=inner2 "Inner"
                             end_ft_div ;;
                heading)     ft-heading name=sub "Section" ;;
                boxheader)   ft-boxheader name=sub text="Interface" ;;
                keylegend)   ft-keylegend name=sub keys="Enter=Open  Del=Delete" ;;
                statusbar)   ft-statusbar name=sub status="ready" width=30 ;;
                # The TARGET is a subject too: a callout's whole job is to follow what it points
                # at, and writes to the beacon alone moved the screen five times in 142 cases.
                beacon)      ft-button name=target "Aim here"
                             ft-beacon name=sub target=target variant=callout number=1 effect=none text="Look"
                             _INC_SUBJECTS="sub target" ;;
            esac
                ft-label name=beside text="beside"
            end_ft_div
            ft-label name=below text="below the row"
            ft-keylegend name=legend keys=auto flexShrink=0
        end_ft_form
        FT_ROOT=app
        ft_layout app
    }

    _inc_full() {               # id item command → ID.full, and the case line
        exec {FT_TTY}>&-; exec {FT_TTY}>"$_INC_DIR/$1.full"
        go_cold
        ft_repaint_all app
        exec {FT_TTY}>&-; exec {FT_TTY}>/dev/null
        # The manifest is one line per case with tab-separated fields, and a command's arguments
        # carry both (a fourteen-line document is a text= value).
        local command=${3//$'\n'/⏎}
        printf '%s\t%s\t%s\n' "$1" "$2" "${command//$'\t'/⇥}" >> "$_INC_DIR/cases"
    }
    # One case: the action inside a burst, the settle ft-run does after it, the oracle.
    # STDERR IS NOT SWALLOWED. An action that makes the framework complain is a failure of this
    # file under tests/run-all.bash, which is the right verdict for it.
    _inc_case() {               # item command…
        local id item=$1; shift
        printf -v id '%04d' $(( ++_INC_N ))
        exec {FT_TTY}>&-; exec {FT_TTY}>"$_INC_DIR/$id.inc"
        FT_COALESCING=1; FT_DEFER_ROOT=""
        "$@" >/dev/null
        FT_COALESCING=0
        settle
        _inc_full "$id" "$item" "$*"
    }

    # Where every RENDERED control is, as one string — what a restore has to bring back. The walk
    # stops at display:none exactly as the paint walk does: a hidden subtree keeps whatever
    # geometry it last had, and a tab body that was shown once and hidden again is not a layout
    # that failed to come back.
    _inc_geometry() {           # → _INC_GEOMETRY_NOW
        _INC_GEOMETRY_NOW=""
        _inc_geometry_walk app
    }
    _inc_geometry_walk() {      # node
        local n=$1 kid
        _ft_disp "$n"; [[ "$FT_RET" == none ]] && return 0
        _INC_GEOMETRY_NOW+="$n ${FT_ABSOLUTE_X[$n]:-} ${FT_ABSOLUTE_Y[$n]:-} ${FT_MEASURED_WIDTH[$n]:-} ${FT_MEASURED_HEIGHT[$n]:-};"
        for kid in ${FT_KIDS[$n]:-}; do _inc_geometry_walk "$kid"; done
    }
    # A fresh scene, and the screen the next case starts from. The scene settles first: a first
    # paint publishes measurements (a label learns its clientHeight), and a base taken before
    # that is a base still moving.
    _inc_base() {               # why
        local id
        [[ -n "${FT_TYPE[app]:-}" ]] && ft_remove app
        FT_RADIO_SELECTED=(); FT_FOCUS=""
        _inc_build
        exec {FT_TTY}>&-; exec {FT_TTY}>/dev/null
        ft_repaint_all app; settle
        _inc_geometry; _INC_GEOMETRY=$_INC_GEOMETRY_NOW
        printf -v id '%04d' $(( ++_INC_N ))
        _inc_full "$id" base "$1"
    }
    _inc_base "build the $_INC_TYPE fixture"

    # ── every property, written and put back ──
    # EVERY prototype initialised first: a constructor runs lazily at its first instance, so the
    # kinds table of a process that built only a slider holds only the names a slider's scene
    # registered — and "every property on every subject" would quietly mean "the ones this
    # fixture happened to meet".
    for _class in $(declare -F | sed -n 's/^declare -f ft_prototype_//p'); do
        ft_prototype_init "$_class" >/dev/null 2>&1
    done
    mapfile -t _INC_NAMES < <(printf '%s\n' "${!FT_PROP_KIND[@]}" | LC_ALL=C sort)
    for _subject in $_INC_SUBJECTS; do
        for _name in "${_INC_NAMES[@]}"; do
            [[ -n "${_INC_EXEMPT[$_name]+set}" ]] && continue
            _sample=${_INC_SAMPLE[$_INC_TYPE:$_name]-${_INC_SAMPLE[$_name]-}}
            _ft_get_raw "$_subject" "$_name"; _original=$FT_RET
            _had=0; _ft_has_prop "$_subject" "$_name" && _had=1
            if [[ "$_sample" == '!' ]]; then
                ft_get "$_subject" "$_name"
                [[ "$FT_RET" == true ]] && _sample=false || _sample=true
            fi
            (( _had )) && [[ "$_sample" == "$_original" ]] && continue
            _inc_case "$_name" ft-modify "$_subject" "$_name=$_sample"
            if (( _had )); then _inc_case "$_name" ft-modify "$_subject" "$_name=$_original"
            else                _inc_case "$_name" ft_remove_attribute "$_subject" "$_name"
            fi
            # PUTTING IT BACK MUST PUT THE LAYOUT BACK. When it does not, every later case paints
            # over controls that now overlap, and which one wins depends on paint order — so a
            # single bad restore used to turn into a failure for every property after it in the
            # alphabet. Recorded under its own name, and the scene is rebuilt so it stays one.
            _inc_geometry
            if [[ "$_INC_GEOMETRY_NOW" != "$_INC_GEOMETRY" ]]; then
                printf '%s\t%s\n' "$_name" "$_subject" >> "$_INC_DIR/unrestored"
                _inc_base "rebuilt after $_name on $_subject did not restore the layout"
            fi
        done
    done

    # ── the prototype's own public verbs ──
    case $_INC_TYPE in
        label)       _inc_case "verb" ft_label_scroll_set sub 3 ;;
        textfield)   _inc_case "verb" ft_textfield_select_all sub
                     _inc_case "verb" ft_append_data sub " and more"
                     _inc_case "verb" ft_insert_data sub 0 "before "
                     _inc_case "verb" ft_replace_data sub 0 7 "after " ;;
        checkbox)    _inc_case "verb" ft_checkbox_toggle sub ;;
        radio)       _inc_case "verb" ft_radio_select sub2
                     _inc_case "verb" ft_radio_select sub
                     _inc_case "verb" ft_radio_deselect sub ;;
        multitoggle) _inc_case "verb" ft_multitoggle_cycle sub ;;
        slider)      _inc_case "verb" ft_slider_set sub 11 ;;
        select)      _inc_case "verb" ft_select_open sub
                     _inc_case "verb" ft_select_close sub ;;
        table)       _inc_case "verb" ft_table_cursor_set sub 4
                     _inc_case "verb" ft_table_scroll_set sub 2 ;;
        tabs)        _inc_case "verb" ft_tabs_select sub 1 ;;
        scrollbar)   _inc_case "verb" ft_scrollbar_set sub 5
                     _inc_case "verb" ft_scrollbar_scroll sub -2
                     _inc_case "verb" ft_label_scroll_set doc 7 ;;
    esac
    _inc_case "verb" ft_classlist_toggle sub hot
    _inc_case "verb" ft_classlist_toggle sub hot
    _inc_case "stylesheet" ft_stylesheet name=incsheet style='.hot { color: green; }'
    _inc_case "stylesheet" ft_classlist_toggle sub hot
    _inc_case "stylesheet" ft_stylesheet name=incsheet style='.hot { color: red; background-color: blue; }'

    # ── focus, and the control's own keys ──
    # ENTER FIRST: focus alone never captures keys in this framework (Enter-to-edit), so an
    # un-entered control bubbles every arrow to focus navigation and the keys drive nothing.
    _inc_case "focus" ft_focus sub
    for _key in ENTER DOWN DOWN RIGHT LEFT UP SPACE x PGDN PGUP END HOME BACKSPACE ESC TAB BTAB; do
        _inc_case "key $_key" ft_dispatch_event "$_key"
    done

    # ── the tree itself moves ──
    _inc_case "tree" ft_append app beside
    _inc_case "tree" ft_remove sub

    exec {FT_TTY}>&-
    python3 "$here/tests/incremental-screens.py" "$_INC_ROWS" "$_INC_COLS" "$_INC_DIR" \
        > "$_INC_DIR/verdicts"
    exit 0
fi

# ── the file proper ──────────────────────────────────────────────────────────
_INC_WORK=$(mktemp -d); trap 'rm -rf "$_INC_WORK"' EXIT

note "every property FT_PROP_KIND knows has a sample or a stated reason not to"
# The kinds table is only complete once every prototype has been initialised — constructors run
# lazily — so ask a fresh interpreter that has built one of each.
_inc_names=$(bash -c '
    cd "$1" && source ./fruity-tui.bash && ft_init >/dev/null 2>&1; exec {FT_TTY}>/dev/null
    for c in $(declare -F | sed -n "s/^declare -f ft_prototype_//p"); do ft_prototype_init "$c" >/dev/null 2>&1; done
    printf "%s\n" "${!FT_PROP_KIND[@]}" | LC_ALL=C sort' _ "$here")
_inc_unsampled=""
for _i in $_inc_names; do
    [[ -n "${_INC_SAMPLE[$_i]+set}" || -n "${_INC_EXEMPT[$_i]+set}" ]] || _inc_unsampled+=" $_i"
done
check "no property is left out of the corpus unexplained" "${_inc_unsampled# }" ""
# ANTI-VACUITY: a table read from an interpreter that failed to source anything is empty, and an
# empty table has nothing unsampled. Known answers, not a count copied from prose.
check "…and the table it checked is the real one" \
      "$(printf '%s\n' $_inc_names | grep -cxE 'width|text|scrollTop|backgroundColor')" "4"

note "the incremental frame equals a cold full repaint, after every action"
_inc_pids=()
for _t in "${_INC_TYPES[@]}"; do
    bash "$here/tests/test-incremental.bash" --fixture "$_t" "$_INC_WORK/$_t" &
    _inc_pids+=($!)
    # A dozen at a time is the machine's cores and not more: past that they only contend.
    (( ${#_inc_pids[@]} % 12 == 0 )) && wait "${_inc_pids[@]}"
done
wait
_inc_fixture_failed=""
for _t in "${_INC_TYPES[@]}"; do
    [[ -s "$_INC_WORK/$_t/verdicts" ]] || _inc_fixture_failed+=" $_t"
done
check "every fixture ran to completion" "${_inc_fixture_failed# }" ""
cat "$_INC_WORK"/*/verdicts > "$_INC_WORK/verdicts" 2>/dev/null

# ONE ASSERTION PER ITEM — a property, a key, a verb — naming every fixture it failed in, so a
# failure says what broke and where, and a fix shows up as one line turning green.
declare -A _inc_bad=() _inc_detail=() _inc_items=()
_inc_changed=0 _inc_cases=0
while IFS=$'\t' read -r _dir _id _item _verdict _command _detail; do
    (( _inc_cases++ ))
    _inc_items[$_item]=1
    case $_verdict in
        changed) (( _inc_changed++ )) ;;
        differ|blank)
            _t=${_dir##*/}
            [[ " ${_inc_bad[$_item]:-} " == *" $_t "* ]] || _inc_bad[$_item]+=" $_t"
            [[ -n "${_inc_detail[$_item]:-}" ]] || _inc_detail[$_item]="$_t: $_command → $_verdict $_detail"
            ;;
    esac
done < "$_INC_WORK/verdicts"
# `while read`, not `for … in $(…)`: an item is "key DOWN", and word splitting made that two
# items with no verdicts at all — sixteen key assertions passing without looking at a frame.
while IFS= read -r _item; do
    check "$_item — no fixture's incremental frame differs from a full repaint" "${_inc_bad[$_item]# }" ""
    [[ -n "${_inc_bad[$_item]:-}" ]] && printf '       %s\n' "${_inc_detail[$_item]}"
done < <(printf '%s\n' "${!_inc_items[@]}" | LC_ALL=C sort)

note "…and writing a property, then putting it back, puts the layout back"
declare -A _inc_unrestored=()
for _t in "${_INC_TYPES[@]}"; do
    [[ -s "$_INC_WORK/$_t/unrestored" ]] || continue
    while IFS=$'\t' read -r _item _subject; do
        _inc_unrestored[$_item]+=" $_t"
    done < "$_INC_WORK/$_t/unrestored"
done
while IFS= read -r _item; do
    [[ -n "$_item" ]] && check "$_item — putting it back puts the layout back" "${_inc_unrestored[$_item]# }" ""
done < <(printf '%s\n' "${!_inc_unrestored[@]}" | LC_ALL=C sort)
# (No companion here proves this comparison can fail: the `removeroute` tooth below does, by
# putting back the one restore defect it found and requiring `position` to fail.)

# ANTI-VACUITY. Agreement is only evidence where the action changed the screen, so demand that
# most of the corpus did — and that the cases which must, did. The known answers are chosen so a
# fixture that never painted, a write that never landed, or a driver that never engaged a
# control would each turn one of them red.
note "…and the corpus actually moved the screen"
# Most cases legitimately change nothing — `multiple` means nothing to a label — so the floor is
# per fixture and conservative: the thinnest real fixture changed the screen 26 times when this
# was written, and one that never painted, or whose subject was never built, changes it zero.
_inc_thin=""
for _t in "${_INC_TYPES[@]}"; do
    _n=$(awk -F'\t' '$4 == "changed"' "$_INC_WORK/$_t/verdicts" 2>/dev/null | grep -c .)
    (( _n >= 20 )) || _inc_thin+=" $_t($_n)"
done
check "every fixture changed the screen at least 20 times ($_inc_changed changes in $_inc_cases cases)" \
      "${_inc_thin# }" ""
_inc_moved() {                  # fixture item command-prefix → changed|unchanged|missing
    awk -F'\t' -v d="$_INC_WORK/$1" -v i="$2" -v c="$3" \
        '$1 == d && $3 == i && index($5, c) == 1 { print $4; found = 1; exit } END { if (!found) print "missing" }' \
        "$_INC_WORK/verdicts"
}
# Known answers name their fixtures, so they are asked only of a run that built all of them.
if [[ -z "${FT_INCREMENTAL_TYPES:-}" ]]; then
    check "a label's text write reached the screen"     "$(_inc_moved label text 'ft-modify sub text=')" "changed"
    check "scrolling a bar's target reached the screen" "$(_inc_moved scrollbar verb 'ft_label_scroll_set doc')" "changed"
    check "a stylesheet edit reached the screen" \
          "$(_inc_moved button stylesheet 'ft_stylesheet name=incsheet style=.hot { color: red')" "changed"
    check "an engaged slider's arrow reached the screen" "$(_inc_moved slider 'key RIGHT' 'ft_dispatch_event')" "changed"
fi

# ── TEETH ────────────────────────────────────────────────────────────────────
# Not "the file went red": a run restricted to one fixture can fail for reasons of its own, so
# each injection must fail the ITEM it breaks. The unsabotaged run above is the positive control —
# every one of these items passed there.
if [[ -z "${FT_INCREMENTAL_SABOTAGE:-}${FT_INCREMENTAL_TYPES:-}" ]]; then
    note "teeth: each injected defect fails the item it breaks"
    for _tooth in "${_INC_TEETH[@]}"; do          # independent runs, so all at once
        read -r _s _fixture _item <<< "$_tooth"
        FT_INCREMENTAL_SABOTAGE=$_s FT_INCREMENTAL_TYPES=$_fixture \
            bash "$here/tests/test-incremental.bash" > "$_INC_WORK/teeth-$_s" 2>/dev/null &
    done
    wait
    for _tooth in "${_INC_TEETH[@]}"; do
        read -r _s _fixture _item <<< "$_tooth"
        if grep -qF "  FAIL $_item — " "$_INC_WORK/teeth-$_s"; then _verdict=caught; else _verdict="BLIND"; fi
        check "injected '$_s' fails '$_item' on the $_fixture fixture" "$_verdict" "caught"
    done
fi

summary
