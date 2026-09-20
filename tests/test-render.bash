#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  The render gate.
#
#  Everything else in tests/ checks state — properties, the cascade, layout numbers,
#  event dispatch — and all of it can pass while the screen is visibly broken. That
#  has happened three times in this project: a repaint narrowed too far, controls
#  silently stopped being drawn, and a fully green suite reported success.
#
#  So this suite checks the SCREEN. It drives the real application in a real pty and
#  asserts on what a person would actually see.
#
#  Two kinds of check:
#    · INVARIANTS  — things that must be true of every frame (the specimen is drawn,
#                    the control row is drawn, exactly one callout, no stray escapes).
#    · GOLDEN      — the exact screen, recorded under tests/screens/. Regenerate
#                    deliberately with:  bash tests/test-render.bash --accept
#
#  A golden mismatch is not automatically a failure of the code — it may be an
#  intended visual change — but it must always be looked at, never rubber-stamped.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"

renderer="$here/tests/render-screen.py"
screens_directory="$here/tests/screens"
accept_new_screens=0
[[ "${1:-}" == "--accept" ]] && accept_new_screens=1
mkdir -p "$screens_directory"

# render NAME SCRIPT KEYS [VAR=VALUE…] — capture one screen, cached per run so several checks
# share it. The trailing VAR=VALUE pairs set the app's environment: FT_TEST_QUITKEY="" keeps
# the harness from typing its own quit key (which would dismiss anything transient before the
# frame is read), FT_STATE_AUTOLOAD=1 launches an app the way a user's own shell would.
declare -A rendered_screen=()
render() {                      # name script keys [env…]
    local name=$1 script=$2 keys=$3; shift 3
    [[ -n "${rendered_screen[$name]:-}" ]] && return 0
    rendered_screen[$name]=$(env "$@" python3 "$renderer" "$script" "$keys" 2>/dev/null)
    [[ -n "${rendered_screen[$name]}" ]]
}

# screen_shows NAME LABEL TEXT — the frame must contain TEXT
screen_shows() {
    local name=$1 label=$2 text=$3
    case "${rendered_screen[$name]}" in
        *"$text"*) check "$label" 1 1 ;;
        *)         check "$label" 0 1 ;;
    esac
}

# screen_counts NAME LABEL PATTERN EXPECTED — how many rows match PATTERN
screen_counts() {
    local name=$1 label=$2 pattern=$3 expected=$4
    local actual
    actual=$(printf '%s\n' "${rendered_screen[$name]}" | grep -cE "$pattern")
    check "$label" "$actual" "$expected"
}

# golden NAME — compare against the recorded screen, or record it the first time
golden() {
    local name=$1                       # NB: separate lines — `local a=$1 b=$a` reads the OLD a
    local file="$screens_directory/$name.screen"
    if (( accept_new_screens )) || [[ ! -f "$file" ]]; then
        printf '%s\n' "${rendered_screen[$name]}" > "$file"
        note "recorded golden screen: $name"
        return 0
    fi
    if [[ "$(cat "$file")" == "${rendered_screen[$name]}" ]]; then
        check "screen matches golden ($name)" 1 1
    else
        check "screen matches golden ($name)" 0 1
        echo "    diff (recorded vs rendered), first lines:"
        diff <(cat "$file") <(printf '%s\n' "${rendered_screen[$name]}") | head -12 | sed 's/^/      /'
        echo "    if this change is intended: bash tests/test-render.bash --accept"
    fi
}

demo="$here/demo/css-demo.bash"

note "the CSS demo draws its first page"
render page1 "$demo" ""
check "the app rendered something" "$([[ -n "${rendered_screen[page1]:-}" ]] && echo yes)" yes
screen_shows page1 "the specimen text box is drawn"   "The quick brown fox"
screen_shows page1 "the control row is drawn"         "Parent colour"
screen_shows page1 "the code panes are drawn"         "The CSS"
screen_shows page1 "the step counter is drawn"        "Step 1 of"
screen_counts page1 "exactly one callout on screen"   "╭[①②③④⑤]" 1
screen_counts page1 "no raw escape sequences leaked"  "\[[0-9;]+m" 0

note "stepping keeps every control on screen (the regression that shipped three times)"
render page1_stepped "$demo" "> 0.7,> 0.7"
screen_shows page1_stepped "the specimen survives a step change" "The quick brown fox"
screen_shows page1_stepped "the control row survives"            "Parent colour"
screen_counts page1_stepped "still exactly one callout"          "╭[①②③④⑤]" 1

note "typing into a wrapping textarea puts the right text on the right rows"
# The wrap is INCREMENTAL: a keystroke re-wraps only the logical line it landed in and splices
# those rows back into the cached layout (see tests/test-incwrap.bash, which proves the patched
# arrays equal a full rebuild's). That is state — this is the screen. Type a line long enough
# to soft-wrap, then Enter and a second line, and look at what a person would see.
# (The trailing `q` on the last row is the harness's own quit key, typed into the open field.)
# ONE Enter: the Notes box starts empty, so there is nothing to scroll and Enter goes
# straight to editing. A box that has actually OVERFLOWED stops at the scrolling rung
# first, where arrows scroll instead of moving focus — see tests/test-render's sibling
# probes and controls/ft-textfield.bash:_ft_textfield_can_scroll.
render notes "$here/demo/textfield-demo.bash" \
    "TAB TAB 0.6,ENTER 0.6,incremental SPACE wrapping SPACE keeps SPACE every SPACE row SPACE correct 1.2,ENTER 0.4,a SPACE second SPACE line 0.8"
screen_shows notes "the typed text reached the box"        "incremental wrapping keeps every row"
screen_shows notes "it soft-wrapped at the box edge"       "│correct "
screen_shows notes "Enter started a genuinely new row"     "│a second line"
screen_shows notes "the other fields are untouched"        "│admin  "

note "an overflowing textarea actually SHOWS its scrollbar, and the thumb tracks the scroll"
# This is the check that was missing, and a whole class of bug lived in the gap: every other
# scrollbar test reads FT_OUT from a DIRECT draw, which emitted the thumb correctly the whole
# time. On a real screen the border animation's frozen ring — cached before the field
# overflowed, and keyed without the thumb's position — was blitted straight over it, so the
# scrollbar was simply never visible. Assert the SCREEN, and assert the thumb MOVES: a thumb
# pinned at one position by a stale cache looks perfectly fine in a single frame.
_typed="TAB TAB 0.6,ENTER 0.5"
for _w in aaa bbb ccc ddd eee fff ggg hhh iii; do _typed+=",$_w 0.25,ENTER 0.25"; done
_typed+=",zzz 0.6"
render scroll_end "$here/demo/textfield-demo.bash" "$_typed"
render scroll_top "$here/demo/textfield-demo.bash" "$_typed,UP UP UP UP UP UP UP UP UP 0.8"
screen_shows scroll_end "the box really is scrolled (early lines gone)" "│fff"
screen_counts scroll_end "the thumb is on screen"                       "▊" 2
screen_shows scroll_end "…at the BOTTOM, where the caret is"            "│zzzq                                    ▊"
screen_shows scroll_top "scrolling back up shows the first line"        "│aaaq"
screen_shows scroll_top "…and the thumb moved to the TOP"               "│aaaq                                    ▊"

note "an onChange listener still sees the value, which is otherwise never materialised"
# A textfield's `value` is DEFERRED while typing: the line store is authoritative and the
# joined string is only built when something actually asks for it. onChange asks for it — its
# contract is (name, new value) — so this checks the one place the deferral could go wrong in
# a way no unit test would notice: the derived labels the demo computes from it.
# The trailing `q` is the harness's own quit key landing in the still-open field, so the value
# ends up "X" + "q" + "admin" — as in the `notes`/`scroll_*` scenarios. It only started showing
# up here once layout was coalesced across a burst and the repaint began landing inside the
# capture window; before that the frame was captured before the q was painted.
render onchange "$here/demo/textfield-demo.bash" "ENTER 0.8,X 0.8"
screen_shows onchange "the character reached the field"      "│Xqadmin"
screen_shows onchange "onChange fired with the WHOLE value"  'user = "Xqadmin"'
screen_shows onchange "…and the derived preview followed"    "login: Xqadmin@"

note "Ctrl+S says so on the screen, and what it saved comes back next launch"
# THE BUG THIS EXISTS FOR: Ctrl+S wrote a perfectly good state file and the only honest
# description of the feature was "nothing seemed to happen" — no confirmation, and nothing
# read the file back. Both halves are only observable on a screen, so both are checked here.
# (XDG_STATE_HOME points at a throwaway directory — see tests/_harness.bash.)
state_file="$XDG_STATE_HOME/fruity-tui/textfield-demo.ftstate"
rm -f "$state_file"
render saved "$here/demo/textfield-demo.bash" 'ENTER,ZaphodB,CTRL+S 1.2' FT_TEST_QUITKEY=
screen_shows saved "the confirmation is on screen"        "Saved →"
screen_shows saved "…and it names the file it wrote"      "fruity-tui/textfield-demo.ftstate"
[[ -s "$state_file" ]] && check "…and that file really exists" 1 1 \
                       || check "…and that file really exists" 0 1
# Any key at all takes it down again — no timer, and the keypress repaints the row it covered.
# ASSERT THE WHOLE FRAME, NOT THE ACTIVE CONTROL. Taking the confirmation down damages the row
# it covered, and repairing that row used to enlist the root form, whose draw fills the screen
# and paints no children: the entire UI vanished and only the focused field — the one control
# still dirty — remained. Checking "the field is still there" passed the whole time. So the
# check is that a Ctrl+S in the middle of a session leaves NO trace: same keys with and without
# it must produce the same screen, control for control.
render dismissed "$here/demo/textfield-demo.bash" 'ENTER,ZaphodB,CTRL+S,ESC,TAB,TAB 1.0' FT_TEST_QUITKEY=
render untouched "$here/demo/textfield-demo.bash" 'ENTER,ZaphodB,ESC,TAB,TAB 1.0'        FT_TEST_QUITKEY=
screen_counts dismissed "the next keypress clears it away"   "Saved →" 0
check "the frame is what it would be without the save" \
      "${rendered_screen[dismissed]}" "${rendered_screen[untouched]}"
# …and named, in case the two ever go wrong together.
screen_shows dismissed "the form's border survives"   "╚════"
screen_shows dismissed "the heading survives"         "ft-textfield — readline text input"
screen_shows dismissed "the other fields survive"     "│e.g. dc1.example.com"
screen_shows dismissed "the buttons survive"          "Save    Clear    Quit"
screen_shows dismissed "the edited field survives"    "│ZaphodBadmin"
# …and a fresh launch is where the user left off, not an empty form.
render restored "$here/demo/textfield-demo.bash" "" FT_STATE_AUTOLOAD=1
screen_shows restored "a new run restores the typed text"   "│ZaphodBadmin"
screen_counts restored "…with no stale confirmation"        "Saved →" 0
rm -f "$state_file"

note "Tab in a one-line field moves focus; it does not type into it"
# Tab is the one navigation key every user already has in their fingers, and a single line has
# nothing to indent. This is a SCREEN check because the failure is visual: the caret stays put
# and four spaces appear in the middle of what you were typing.
render onelinetab "$here/demo/textfield-demo.bash" 'ENTER,ab,TAB 0.8'
screen_shows  onelinetab "the field kept exactly what was typed" "│abadmin"
screen_counts onelinetab "no soft tab landed in it"              "│ab    " 0

note "the rendered screen matches what was recorded"
golden page1
golden page1_stepped
golden notes
golden onchange
golden scroll_end
golden scroll_top

summary
