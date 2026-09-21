#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — demo/tutorial-demo.bash   (interactive tutorial)
#
#  A guided tour that builds a real TUI one step at a time. OK (K) advances,
#  Back (B) revisits, Q/Esc quits. Every step shows "What just happened" and
#  "The code you'd add", plus a live example. This file doubles as the
#  framework's cleanliness test: if tutorial code ever needs internals,
#  magic globals, or boilerplate, the API is wrong.
#
#  THE MENTAL MODEL
#  ----------------
#  `app` is the root FORM — think of it as the <body> of an HTML page. It is
#  exactly the size of the terminal and PAINTS THE SCREEN: its fill (the theme
#  screen colour, or a backgroundColor you set on it) is the backdrop behind
#  everything. A FRAME (ft-frame) is an ordinary bordered box that sits inside
#  the form — the visible grey box on screen. So: form = the whole screen,
#  frame = a panel drawn on it.
#
#  Sizing is CSS: with width/height UNSET a box grows to fit its content
#  (auto). The root form is the one box given an explicit size (the terminal),
#  because it must BE the screen. Set an explicit width/height on any box and
#  it becomes fixed — content that no longer fits is clipped or scrolled, not
#  spilled (again, CSS: an explicit height is a hard constraint).
#
#  Multi-step programs keep ONE form forever and rebuild its contents:
#  ft_empty app reopens it as the current container, you declare the same
#  stable names again, end_ft_form closes it (which rebuilds the Tab order),
#  ft_refresh repaints. Names are ids; state lives in plain shell variables;
#  <name>_on_activate hooks are your event listeners.
#
#    bash demo/tutorial-demo.bash
# ─────────────────────────────────────────────────────────────────────────────
set -o pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/fruity-tui.bash"
ft_init
ft_term_size

# Free Windows Terminal's Ctrl+Shift+Home/End/Up/Down for this run (auto-reverted
# on exit, self-heals after a kill -9). Idempotent, no-op off Windows. FT_NO_WTFIX=1
# opts out; toggle live from Settings.
[[ -z "${FT_NO_WTFIX:-}" ]] && declare -F ft_wt_autofix_enter >/dev/null && ft_wt_autofix_enter

STEP=1
LAST=14

# Page-12 (ft-table) live-experiment state: the chosen style and stripe survive
# a page rebuild (state lives in plain vars, as everywhere else in this demo).
TBL_STYLE_SEL=lines
TBL_STRIPE_SEL=true
# The applied theme, so the theme dropdown reopens on the CURRENT choice instead of
# snapping back to Dark every time the page rebuilds.
THEME_SEL=dark

# Settings the user builds up across pages, gathered on the final Review page.
# Like the table state above, they live in plain vars so they survive rebuilds —
# no store, no framework state, just the demo's own variables.
SET_NAME=admin; SET_WRAP=on; SET_MARKS=on; SET_LINES=on; SET_SUMMARY=""

# A titled panel. PROSE wraps to a fixed width; CODE never wraps (width unset
# → the box grows to the widest line, so snippets read exactly as written).
# Either scrolls itself (label default overflowY=auto) if it gets too tall.
_prose_panel() {                # name title text
    # A read-only text FIELD (Enter-to-edit model): it stays in the focus ring and
    # lights up its BORDER when focused, but merely focusing it does NOT trap the
    # keyboard — k / n / arrows keep driving the tutorial. Press Enter to drop into
    # cursor mode and scroll/select/copy the write-up; Esc leaves. rows=6 keeps the
    # box a fixed height so long prose (page 11) scrolls instead of shoving the demo
    # off-screen. The CODE panel below is the same, just not read-only-looking.
    ft-label name="${1}Title" color=accent text="$2"
    ft-textfield name="$1" value="$3" readOnly=true wrap=true size=58 rows=5
}
_code_panel() {                 # name title text
    # A read-only text field so you can SELECT AND COPY the snippet (people will
    # absolutely want to lift these into their own apps). wrap=false keeps each
    # code line intact and scrolls horizontally (arrow right) instead of wrapping,
    # so nothing gets mangled. Body colour, so it stays readable in every theme.
    ft-label name="${1}Title" color=accent text="$2"
    ft-textfield name="$1" value="$3" readOnly=true wrap=false size=58 rows=7
}

THIRTY_LINES=""
for i in $(seq 1 30); do
    THIRTY_LINES+="Line $i of thirty -- far more than fits on one screen."$'\n'
done
THIRTY_LINES=${THIRTY_LINES%$'\n'}

_show_step() {
    local explain="" code="" oktext=OK
    (( STEP == LAST )) && oktext=Finish

    case "$STEP" in
    1)  explain=\
"There are TWO boxes here. The FORM named app is the whole screen -- it paints the dark backdrop you see everywhere (that is the theme's screen colour; set backgroundColor on the form to change it). The grey bordered box in the middle is a FRAME, a panel sitting inside the form. The form is display=flex, centered, so the frame floats in the middle with zero coordinates. Tab moves focus in declaration order; Enter presses a button; underlined letters are accelerators."
        code='ft-form name=app width=$FT_COLS height=$FT_ROWS display=flex justifyContent=center alignItems=center
    ft-frame name=win title="Fruity TUI Tutorial"
        ...
    end_ft_frame
end_ft_form
ft_run app' ;;
    2)  explain=\
"A label was added. Controls NEST: anything between a constructor and its end_ statement is a child. The frame grew to fit it -- width/height are unset, so it is auto-sized to its content, exactly like an HTML block. Note the shorthand: a bare last argument IS the content, the same as text=..., so it reads like text between HTML tags."
        code='ft-label name=hello "Hello, terminal!"' ;;
    3)  explain=\
"Now the label has an explicit width=22. In CSS an explicit width is a hard cap, so the long sentence WRAPS to stay inside it instead of widening the box. Unset width would have let it grow on one line."
        code='ft-label name=hello width=22 "A long sentence wraps when its box cannot grow."' ;;
    4)  explain="(this text is filled in from the live layout -- see below)"
        code='ft-label name=big text="$THIRTY_LINES"    # thirty lines; nothing else' ;;
    5)  explain=\
"overflow is the CSS choice for content that does not fit, and it has four values: auto (the default -- grow a scrollbar, what you saw on step 4), clip (cut it off cleanly, no scrollbar), hidden (same, but still programmatically scrollable), and visible (do not clip at all). THIS step deliberately picks visible, so the thirty lines paint over whatever is beneath them -- the ugly option, shown so you know it exists. (The clip system still confines the mess to this window.) NOTICE WHAT ELSE WENT: on step 4 you could Tab INTO the box and scroll it. Here you cannot, and that is not a separate rule -- a label is a focus stop only when it has a scrollbar to work, and visible never grows one. You can't scroll what has no bar. Reach for clip when you simply want overflow cut off. Press K to move on."
        code='ft-label name=big text="$THIRTY_LINES" overflowY=visible   # do not clip (the mess)
# vs the sane choices:
# overflowY=auto    # scrollbar when needed (default)
# overflowY=clip    # cut off cleanly, no scrollbar' ;;
    6)  explain=\
"A flex row of three frames: left grows 1 share, right grows 3, the middle is a fixed width. The labelled WIDTH and HEIGHT sliders reshape it live -- Tab to one, then Left/Right adjust (PgUp/PgDn jump, Home/End snap). A focused slider lights up in the theme's one focus colour; each one's one-line _on_change hook just feeds its value into ft_set. Two glyph styles are shown (fill, blocks); track and dots also exist. (The demo sits in a fixed-size box so a tick reflows only that region -- snappy.)"
        code='ft-label  Width
ft-slider name=rowW min=30 max=56 value=56 step=2 variant=fill   showValue=true onChange='rowW_on_change "$@"'
ft-label text=Height
ft-slider name=rowH min=3  max=6  value=3         variant=blocks showValue=true onChange='rowH_on_change "$@"'
...
rowW_on_change() { ft_set flexRow width="$1"; }   # flexRow = the container
rowH_on_change() { ft_set flexRow height="$1"; }' ;;
    7)  explain=\
"Every input keeps its own value automatically -- no handler needed just to remember what is set. Ticking Show advanced ENABLES the compression radios (its _on_activate); unticking disables them again (its _on_deactivate); disabled controls dim and drop out of Tab order. There is no special submit: Save is an ordinary button whose _on_activate reads the values and acts -- here it writes a one-line summary and, if Beep is on, rings the bell (audible only if your terminal's bell is enabled). Reading values on a button is exactly how Samba Mago will collect samba-tool settings. (The controls sit in a fixed-width box, so the growing status line never shoves them around.) Note: ft_get is fork-free -- it fills your variable, no \$(...) subshell."
        code='ft-checkbox name=cbAdvanced text="Show advanced" accessKey=A \
             onActivate=cbAdvanced_on_activate onDeactivate=cbAdvanced_on_deactivate
ft-div name=advBox
    ft-radio name=rNone group=comp value=none text="No compression" accessKey=N
    ft-radio name=rFast group=comp value=fast text="Fast" accessKey=F
    ft-radio name=rBest group=comp value=best text="Best" accessKey=T
end_ft_div
ft-checkbox name=cbBeep text="Beep on save" accessKey=P
ft-button name=btnSave text="Save" accessKey=S onActivate=btnSave_on_activate
...
btnSave_on_activate() {           # the "submit": just read the values
    local comp beep
    ft_radio_value comp comp      # one read: none|fast|best  (fork-free)
    ft_get cbBeep value beep      # fork-free: fills $beep
    ft_set status text="compression=$comp beep=$beep"
    [[ $beep == true ]] && ft_beep
}' ;;
    8)  explain=\
"Two select styles, both keeping value current for you to read on Save. The LIST BOX (size=4) shows every option; Up/Down move a cursor (the focus colour = what Space toggles), Home/End jump; selected rows get a ✓ and the theme's selection colour, distinct from the cursor colour. The THEME DROPDOWN (size=1) shows only the current pick; Down (or Enter) drops it open with the selected option marked ✓ in the selection colour and the cursor in the focus colour -- move with Up/Down (clamped -- no wraparound), Enter commits, Esc cancels. Picking a theme actually RE-THEMES this page via its _on_change hook: proof that colours are just palette variables you can swap live."
        code='ft-select name=perms size=4 multiple=true
    ft-option value=read text="Read"
    ft-option value=write text="Write"
    ft-option value=admin text="Administer"
end_ft_select
ft-select name=theme                 # size=1 -> dropdown onChange='theme_on_change "$@"'
    ft-option value=dark text="Dark"
    ft-option value=light text="Light"
    ft-option value=ocean text="Ocean"
end_ft_select
theme_on_change() { apply_theme "$1"; ft_refresh; }   # $1 = chosen theme' ;;
    9)  explain=\
"CSS has TWO ways to hide, and they differ -- both act on the SAME box below. Remove (R) sets display=none: the box AND its space vanish, so everything under it COLLAPSES up. Invisible (V) sets visibility=hidden: the box is blanked but KEEPS its space, so nothing else moves. Each is one TOGGLE button that reads the current state, flips it, and relabels itself (Remove⇄Restore, Invisible⇄Visible). The accelerator letter lives inside each label, so it shows underlined."
        code='# TWO ways to hide the SAME box -- one toggle button each:
btnDisp_on_activate() {                # display: remove it, space COLLAPSES
    ft_get hideBox display d
    [[ $d == none ]] && ft_set hideBox display=flex \
                     || ft_set hideBox display=none
}
btnVis_on_activate() {                 # visibility: blank it, space KEPT
    ft_get hideBox visibility v
    [[ $v == hidden ]] && ft_set hideBox visibility=visible \
                       || ft_set hideBox visibility=hidden
}' ;;
    10) explain=\
"Borders mirror CSS and are just paint properties you can ft_set live -- try the control in each frame. DOUBLE: the checkbox flips borderStyle solid⇄double and relabels the title. ROUNDED: the checkbox flips borderRadius 0⇄1 -- like CSS it takes a NUMBER of cells; any radius ≥1 draws the arc corners (bigger radii clamp to the terminal'\''s one arc glyph). DASHED: the checkbox toggles the border off and back on (border=false keeps the box, drops the lines). STARS: the dropdown retiles the whole border with any single glyph (borderGlyph) -- star, heart, diamond, dot. borderColor takes any theme colour; everything is orthogonal (rounded+dashed works)."
        code='# a border property is just another CSS property:
stDc_on_activate()   { ft_set stD borderStyle=double
                       ft_set stD title="Double"; }
stRad_on_activate()  { ft_set stR borderRadius=1; }
stHc_on_deactivate() { ft_set stH border=false; }   # hide border
stSsel_on_change()   { ft_set stS borderGlyph=$1; } # $this=stSsel, $1=glyph' ;;
    11) explain=\
"Text input is the ft-textfield class -- the SAME class scales from one line to
many. size sets the visible TEXT width; rows=1 (default) is a single-line field,
rows>1 a text box. ENTER TO EDIT: a merely-focused field just lights up its
BORDER and passes keys through, so Tab and k/n keep navigating. Press Enter to
drop INTO the field (a caret appears); now you type. Esc (or Tab) leaves it.
That is why focusing a field no longer 'traps' the keyboard.

Once inside: Enter makes a newline (in a text box); Insert flips the caret bar/
block; Shift+arrows SELECT (Shift+Ctrl+arrow by word); Ctrl+C copies, Ctrl+W
cuts; your terminal's own paste (Ctrl+Shift+V) drops text in. The text box adds
two gutters -- showLineNumbers down the left, wrapIndicator's ↩ on the right of
soft-wrapped rows. Toggle Wrap (W) and Line #s (L) from the buttons below."
        code='# One class, sized two ways -- rows makes the difference:
ft-textfield name=user  size=24 value="admin"      # rows=1: one line
ft-textfield name=notes size=34 rows=5 wrap=true text=\  # rows>1: a text box
             showLineNumbers=true \   # 1,2,3.. down the left gutter
             wrapIndicator=true       # ↩ marks a soft-wrapped row

# Same value model as everything else:
btnSave_on_activate() {
    ft_get user  value u
    ft_get notes value n      # n may contain newlines
}' ;;
    12) explain=\
"The editing keys, shown in an ft-table -- the toolkit's data grid, now LIVE.
You DECLARE it like everything else: ft-table-header headers describe the layout (each
sizes to its widest cell unless you pin width=), and every ft-table-row lists its
cells in column order. A table is styled by BORDER PROPERTIES, like any control
(borderStyle, borderColor, rowLines, colLines, headerLine); Style here is just a
shorthand -- grid/heavy box every cell, lines keeps the row rules without the
box, minimal drops to a header rule -- and the Striped toggle zebra-stripes any
of them. Both rewrite the grid instantly.
All colours are themed, so it reads correctly on Light and Ocean too. rows=7
caps the body, so the fourteen keys SCROLL: Tab to the table, then ↑/↓ PgUp/PgDn
(Home/End jump); the header row stays pinned. Tab first reaches this write-up."
        code='ft-table name=keys variant=minimal striped=true
    ft-table-header text="Keys" # auto-sizes; pin with width=N
    ft-table-header text="What it does"
    ft-table-row "Home Ctrl+A / End Ctrl+E" "Jump to line start / end"
    ft-table-row "Ctrl+W / Alt+D"           "Delete word left / right"
    ...
end_ft_table
# style= is shorthand; tables also take real border properties:
#   borderStyle=solid|heavy|double|rounded|dashed|none  borderColor=...
#   rowLines / colLines / headerLine / striped = true|false' ;;
    13) explain=\
"The finale: a REVIEW of everything you set during the tour. Your Name (page 11),
the wrap / line-number / wrap-mark toggles, and the table style (page 12) were
each stashed in a plain shell var by a one-line on_change hook as you went -- so
this page just reads them back into a table. No store, no framework state: the
'value is automatic' idea, taken across pages.

Save opens a real FILE DIALOG (ft_file_dialog operation=save) -- a Places pane, a
folders-first listing, a filename field and a customisable submit button, all
built from these same controls. Pick a location and it reports the path it would
write to (this tour doesn't touch your disk).

Press Save to open the dialog, or Finish to end the tour."
        code='# Settings accumulate in plain vars via on_change hooks:
tfName_on_change()   { SET_NAME=\"\$1\"; }
cbWrap_on_activate() { SET_WRAP=on; }        # ...one per toggle

# The Review table just reads those vars back:
ft-table name=revTbl variant=lines
    ft-table-row \"Name\"        \"\$SET_NAME\"
    ft-table-row \"Table style\" \"\$TBL_STYLE_SEL\"
end_ft_table

# Save opens the real file dialog (Save mode) and reports the chosen path:
btnSaveSettings_on_activate() {
    if ft_file_dialog operation=save path=~/settings.conf submit=Save; then
        ft_set saveStatus text=\"Would text=save text=to: text=\$FT_FILE_RESULT\"
    else
        ft_set saveStatus text=\"Save text=cancelled.\"
    fi
}' ;;
    14) explain=\
"The file dialog, on its own. ft_file_dialog opens a modal picker built from the
same controls you've met: a PLACES pane (Home, Documents, Downloads, the
filesystem root -- and, under WSL, your Windows folders), a FOLDERS-FIRST listing
you walk with the arrows (Enter opens a folder, or picks a file), a FILENAME
field, and a submit button whose label YOU choose. Every dialog has a Help button.

It's all property=value, like the rest of the API. It returns the chosen path in
FT_FILE_RESULT (and 0/1 for chose/cancelled). This tour only reports the path --
it never touches your disk. Open it below."
        code='# property=value, same as everything else:
if ft_file_dialog operation=save path=~/report.txt submit=Save; then
    printf "chose: %s\\n" \"\$FT_FILE_RESULT\"
else
    printf \"cancelled\\n\"
fi

# operation=open|save  path=<dir or dir/file>  title=..  submit=<button label>' ;;
    esac

    ft_empty stage
        ft-frame name=win title="Fruity TUI Tutorial ($STEP/$LAST)" \
                 display=flex flexDirection=column gap=1 padding=1 alignItems=center \
                 borderStyle=double
            _prose_panel explain "What just happened" "$explain"
            _code_panel  code    "The code you'd add" "$code"

            case "$STEP" in
            2)  ft-label name=hello text="Hello, terminal!" ;;
            3)  ft-label name=hello width=22 text="A long sentence wraps when its box cannot grow." ;;
            4)  # maxHeight makes the box shorter than its 30 lines, so it
                # overflows → grows a scrollbar gutter → becomes focusable.
                ft-label name=big text="$THIRTY_LINES" width=56 maxHeight=10 ;;
            5)  ft-label name=big text="$THIRTY_LINES" width=56 overflowY=visible ;;
            6)  # A FIXED-size box around the live demo: an explicit width/height
                # here means a slider tick reflows only THIS region, not the
                # whole screen -- keeps adjustment snappy.
                ft-div name=demoBox width=58 height=10 display=flex flexDirection=column gap=1 alignItems=center
                    ft-div name=flexRow display=flex width=56 height=3
                        ft-frame name=lft title=grow-1 flexGrow=1
                        end_ft_frame
                        ft-frame name=mid title=fixed width=16
                        end_ft_frame
                        ft-frame name=rgt title=grow-3 flexGrow=3
                        end_ft_frame
                    end_ft_div
                    ft-div name=sliders display=flex gap=4
                        ft-div name=wCol display=flex flexDirection=column alignItems=center
                            ft-label name=wLbl text=Width
                            ft-slider name=rowW min=30 max=56 value=56 step=2 width=22 variant=fill showValue=true onChange='rowW_on_change "$@"'
                        end_ft_div
                        ft-div name=hCol display=flex flexDirection=column alignItems=center
                            ft-label name=hLbl text=Height
                            ft-slider name=rowH min=3 max=6 value=3 width=12 variant=blocks showValue=true onChange='rowH_on_change "$@"'
                        end_ft_div
                    end_ft_div
                end_ft_div ;;
            7)  # opts has NO fixed width, so it SHRINKS to its widest control
                # (~18 cols). alignItems=start keeps the controls left-aligned
                # to a common edge; the frame centres the now-narrow box, so the
                # controls read as centred. The wide status line lives OUTSIDE
                # opts (its own centred, fixed-width row) so it can grow on Save
                # without stretching the control box.
                ft-div name=opts display=flex flexDirection=column gap=0 alignItems=start
                    ft-checkbox name=cbAdvanced text="Show advanced" accessKey=A onActivate='cbAdvanced_on_activate "$@"' onDeactivate='cbAdvanced_on_deactivate "$@"'
                    ft-div name=advBox display=flex flexDirection=column gap=0 alignItems=start
                        ft-radio name=rNone group=comp value=none text="No compression" accessKey=N disabled=true
                        ft-radio name=rFast group=comp value=fast text="Fast" accessKey=F disabled=true
                        ft-radio name=rBest group=comp value=best text="Best" accessKey=T disabled=true
                    end_ft_div
                    ft-checkbox name=cbBeep text="Beep on save" accessKey=P
                end_ft_div
                ft-label name=status text="(nothing saved yet)" width=46 color=notice textAlign=center ;;
            8)  ft-div name=selrow display=flex gap=6 alignItems=start
                    ft-select name=perms size=4 multiple=true
                        ft-option value=read text="Read"
                        ft-option value=write text="Write"
                        ft-option value=admin text="Administer"
                    end_ft_select
                    local _ti=0
                    case "$THEME_SEL" in dark) _ti=0 ;; light) _ti=1 ;; ocean) _ti=2 ;; esac
                    ft-select name=theme selectedIndex="$_ti" onChange='theme_on_change "$@"'
                        ft-option value=dark text="Dark"
                        ft-option value=light text="Light"
                        ft-option value=ocean text="Ocean"
                    end_ft_select
                end_ft_div ;;
            9)  # ONE box, hidden two different ways by the two toggle buttons
                # below. Because the buttons sit under the box, you can SEE the
                # difference: Invisible keeps the box's space (buttons stay put),
                # Remove collapses it (buttons jump up).
                ft-frame name=hideBox title="a box" width=50 height=4 display=flex flexDirection=column alignItems=center gap=0
                    ft-label name=note text="I can be hidden two ways."
                    ft-label name=note2 text="Invisible keeps my space; Remove collapses it."
                end_ft_frame ;;
            10) # Each frame holds a LIVE control that mutates its OWN border --
                # a border property is just another CSS property you ft_set.
                ft-div name=styles display=flex gap=2 alignItems=start
                    ft-frame name=stD title=Double borderStyle=double borderColor=cyan width=18 height=6 display=flex flexDirection=column alignItems=center gap=0
                        ft-label name=stDt text="single ⇄ double"
                        ft-checkbox name=stDc text="Double" checked=true onActivate='stDc_on_activate "$@"' onDeactivate='stDc_on_deactivate "$@"'
                    end_ft_frame
                    ft-frame name=stR title=Rounded borderRadius=1 borderColor=green width=18 height=6 display=flex flexDirection=column alignItems=center gap=0
                        ft-label name=stRt text="round corners"
                        ft-checkbox name=stRad text="Rounded" checked=true onActivate='stRad_on_activate "$@"' onDeactivate='stRad_on_deactivate "$@"'
                    end_ft_frame
                    ft-frame name=stH title=Dashed borderStyle=dashed borderColor=orange width=18 height=6 display=flex flexDirection=column alignItems=center gap=0
                        ft-label name=stHt text="border on/off"
                        ft-checkbox name=stHc text="Border" checked=true onDeactivate='stHc_on_deactivate "$@"' onActivate='stHc_on_activate "$@"'
                    end_ft_frame
                    ft-frame name=stS title=Stars borderGlyph=★ borderColor=gold width=18 height=6 display=flex flexDirection=column alignItems=center gap=0
                        ft-label name=stSt text="pick a glyph"
                        ft-select name=stSsel size=1 onChange='stSsel_on_change "$@"'
                            ft-option value=★ text="Star"
                            ft-option value=♥ text="Heart"
                            ft-option value=◆ text="Diamond"
                            ft-option value=● text="Dot"
                        end_ft_select
                    end_ft_frame
                end_ft_div ;;
            11) # One ft-textfield prototype, two sizes: a single-line field and a
                # multi-line text box (rows=5). Both edit with readline keys.
                ft-div name=tbox display=flex flexDirection=column gap=1 alignItems=start
                    ft-div name=trowN display=flex gap=1 alignItems=center
                        ft-label     name=tlN text="Name" width=6
                        ft-textfield name=tfName size=30 value="admin" placeholder="username" onChange='tfName_on_change "$@"'
                    end_ft_div
                    ft-div name=trowD display=flex gap=1 alignItems=start
                        ft-label     name=tlD text="Notes" width=6
                        ft-textfield name=tfNotes size=34 rows=5 wrap=true \
                                     showLineNumbers=true wrapIndicator=true \
                                     placeholder="A multi-line text box -- type, press Enter for new lines. With Wrap on, long lines fold to the next row (a ↩ marks each folded row); turn Wrap off and a long line scrolls sideways instead (the caret drags the view)."
                    end_ft_div
                    ft-div name=trowT display=flex flexDirection=column alignItems=start
                        ft-checkbox name=cbWrap text="Wrap long lines" accessKey=W checked=true onActivate='cbWrap_on_activate "$@"' onDeactivate='cbWrap_on_deactivate "$@"'
                        ft-checkbox name=cbWrapInd text="  └ ↩ wrap marks" accessKey=M checked=true onActivate='cbWrapInd_on_activate "$@"' onDeactivate='cbWrapInd_on_deactivate "$@"'
                        ft-checkbox name=cbLineNo text="Line numbers" accessKey=L checked=true onActivate='cbLineNo_on_activate "$@"' onDeactivate='cbLineNo_on_deactivate "$@"'
                    end_ft_div
                end_ft_div ;;
            12) # The readline keys, rendered by ft-table -- and made LIVE: the
                # Style dropdown and Striped toggle rewrite the grid on the spot,
                # and rows=7 caps the body so the fourteen keys SCROLL (Tab to the
                # table, then ↑/↓/PgUp/PgDn -- the header stays pinned).
                local _si=3
                case "$TBL_STYLE_SEL" in grid) _si=0 ;; heavy) _si=1 ;; lines) _si=2 ;; minimal) _si=3 ;; esac
                ft-div name=tblCtl display=flex gap=3 alignItems=center justifyContent=center
                    ft-div name=tblStyleWrap display=flex gap=1 alignItems=center
                        ft-label name=tblStyleL text="Style"
                        ft-select name=tblStyle size=1 selectedIndex="$_si" onChange='tblStyle_on_change "$@"'
                            ft-option value=grid text="Grid"
                            ft-option value=heavy text="Heavy"
                            ft-option value=lines text="Lines"
                            ft-option value=minimal text="Minimal"
                        end_ft_select
                    end_ft_div
                    ft-checkbox name=tblStripe text="Striped" accessKey=T checked="$TBL_STRIPE_SEL" onChange='tblStripe_on_change "$@"'
                end_ft_div
                ft-table name=keys style="$TBL_STYLE_SEL" striped="$TBL_STRIPE_SEL" rows=7
                    ft-table-header text="Keys"
                    ft-table-header text="What it does"
                    ft-table-row "← / Ctrl+B"         "Move back one character"
                    ft-table-row "→ / Ctrl+F"         "Move forward one character"
                    ft-table-row "Alt+← / Alt+B"      "Move back one word"
                    ft-table-row "Alt+→ / Alt+F"      "Move forward one word"
                    ft-table-row "Home / Ctrl+A"      "Jump to start of line"
                    ft-table-row "End / Ctrl+E"       "Jump to end of line"
                    ft-table-row "Backspace / Ctrl+H" "Delete character on the left"
                    ft-table-row "Del / Ctrl+D"       "Delete character on the right"
                    ft-table-row "Ctrl+W"             "Delete the word on the left"
                    ft-table-row "Alt+D"              "Delete the word on the right"
                    ft-table-row "Ctrl+K"             "Kill to the end of the line"
                    ft-table-row "Ctrl+U"             "Kill to the start of the line"
                    ft-table-row "Insert"             "Toggle insert vs overwrite"
                    ft-table-row "Enter"              "New line (in a multi-line box)"
                end_ft_table ;;
            13) # A REVIEW of the settings accumulated across the tour, read straight
                # back out of the plain SET_*/TBL_* vars, plus a Save button that
                # opens the real file dialog (shown on its own on the next page).
                ft-div name=review display=flex flexDirection=column gap=1 alignItems=center
                    ft-table name=revTbl variant=lines
                        ft-table-header text="Setting" width=14
                        ft-table-header text="Value"
                        ft-table-row "Name"         "$SET_NAME"
                        ft-table-row "Wrap lines"   "$SET_WRAP"
                        ft-table-row "Wrap marks"   "$SET_MARKS"
                        ft-table-row "Line numbers" "$SET_LINES"
                        ft-table-row "Table style"  "$TBL_STYLE_SEL"
                        ft-table-row "Striped rows" "$TBL_STRIPE_SEL"
                    end_ft_table
                    ft-button name=btnSaveSettings text="Save to file..." accessKey=S onActivate='btnSaveSettings_on_activate "$@"'
                    ft-label  name=saveStatus color=notice textAlign=center width=64 \
                              text="Save opens the real file dialog to pick where these go."
                end_ft_div ;;
            14) # A page all about the file dialog itself.
                ft-div name=fdrow display=flex flexDirection=column gap=1 alignItems=center
                    ft-button name=btnOpenFD text="Open the file dialog..." accessKey=O onActivate='btnOpenFD_on_activate "$@"'
                    ft-label  name=fdResult color=notice textAlign=center width=64 \
                              text="Click to open it (Save mode). The path you pick shows here."
                end_ft_div ;;
            esac

            # Step 9's two TOGGLE buttons get their OWN row, above the nav row.
            # Each flips ONE box and relabels itself. The accelerator letter is
            # part of each label (the R in Remove/Restore, the V in Invisible/
            # Visible), so it shows underlined.
            if [[ "$STEP" == 9 ]]; then
                # FIXED width so relabelling (Invisible⇄Visible, Remove⇄Restore)
                # never resizes the button -- the text change is then a local
                # repaint, not a whole-frame reflow.
                ft-div name=actionrow display=flex gap=2 justifyContent=center
                    ft-button name=btnVis text="Invisible" accessKey=V width=11 onActivate='btnVis_on_activate "$@"'
                    ft-button name=btnDisp text="Remove" accessKey=R width=11 onActivate='btnDisp_on_activate "$@"'
                end_ft_div
            fi
            ft-div name=btnrow display=flex gap=2 justifyContent=center
                ft-button name=btnBack text=Back accessKey=B onActivate='btnBack_on_activate "$@"'
                [[ "$STEP" == 7 ]] && ft-button name=btnSave text=Save accessKey=S onActivate='btnSave_on_activate "$@"'
                ft-button name=btnOk text="$oktext" accessKey=K onActivate='btnOk_on_activate "$@"'
                ft-button name=btnQuit text=Quit accessKey=Q onActivate='btnQuit_on_activate "$@"'
            end_ft_div
        end_ft_frame
    end_ft_div
    ft_set navbar status="Step $STEP of $LAST  —  Tab to move, Enter to use a control, h for Help"

    (( STEP == 7 )) && ft_radio_select rNone
    (( STEP == 1 )) && ft_set btnBack display=none
    ft_refresh
    # Focus starts on the explanation panel -- the first scrollbar -- so you can
    # scroll the write-up with the arrow keys the instant a page loads, then Tab
    # down into the demo controls. ft_focus targets it by name directly
    # (ft_focus_first would fall through to the first *demo* control whenever the
    # write-up happens to fit without a scrollbar).
    ft_focus explain || ft_focus_first

    # Step 4's lesson adapts to the ACTUAL layout: on a tall terminal the
    # thirty lines may simply fit (no scrollbar); on a short one they overflow
    # and the box grows a scrollbar and becomes focusable. ft_run's resize
    # handler re-runs this builder, so the text flips live as you resize.
    if (( STEP == 4 )); then
        # The DOM's own question: is there more content than there is room for?
        ft_get big scrollHeight; local total=${FT_RET:-0}
        ft_get big clientHeight; local shown=${FT_RET:-0}
        if (( total > shown )); then
            ft_set explain text="SCROLLING (active): the thirty lines overflow the box, so it grew a scrollbar in its right edge and became Tab-focusable -- Tab to it and scroll. Two defaults did this with no wiring: auto heights never exceed the space actually available (a terminal cannot scroll your whole UI), and a too-tall label scrolls itself. Resize the terminal and this re-adapts live."
        else
            ft_set explain text="FITS (no scrollbar): your terminal is tall enough to show ALL thirty lines below, so overflow:auto shows no scrollbar at all. Make the window SMALLER and watch one appear the instant the text stops fitting -- the box becomes Tab-focusable and scrollable right then. You wired nothing; it is the default."
        fi
    fi
}

# ── App logic: plain hooks ───────────────────────────────────────────────────
# Navigation only CHANGES STATE and invalidates; ft_run's render callback
# (_show_step) rebuilds once per input burst. So holding K to fast-forward
# runs the cheap STEP++ many times but rebuilds+paints exactly once.
btnOk_on_activate()   { if (( STEP < LAST )); then (( STEP++ )); ft_invalidate; else ft_quit; fi; }
btnBack_on_activate() { (( STEP > 1 )) && { (( STEP-- )); ft_invalidate; }; }
btnQuit_on_activate() { ft_quit; }

# Step 7 — enable/disable the advanced radios from the checkbox's hooks.
cbAdvanced_on_activate() {
    ft_set rNone disabled=false
    ft_set rFast disabled=false
    ft_set rBest disabled=false
}
cbAdvanced_on_deactivate() {
    ft_set rNone disabled=true
    ft_set rFast disabled=true
    ft_set rBest disabled=true
}
# The "submit": an ordinary button that reads the current values (fork-free
# ft_get, no subshell) and acts.
btnSave_on_activate() {
    [[ -z "${FT_TYPE[cbAdvanced]:-}" ]] && return 0
    local comp beep adv
    ft_radio_value comp comp        # one ft_get-style read: none|fast|best|""
    [[ -z "$comp" ]] && comp=none
    ft_get cbBeep value beep
    ft_get cbAdvanced value adv
    # text= is explicit so the =-bearing summary is content, never mis-read as
    # a property assignment.
    ft_set status text="saved: advanced=$adv compression=$comp beep=$beep"
    [[ "$beep" == true ]] && ft_beep
}

# Inside every hook, $this is the control's OWN name and $1 is its new value
# (a slider's number, a checkbox's true/false, a select's chosen option value).
# The name is $this, never an argument -- so `ft_set "$this" ...` and
# `${this}_<prop>` both refer to the control that fired the event.
#
# Step 6 — sliders reshape the flex row live.
rowW_on_change() { ft_set flexRow width="$1"; }    # flexRow is the container
rowH_on_change() { ft_set flexRow height="$1"; }   # (a user name, not a keyword)

# Step 11 — the Wrap checkbox flips the text box between wrapping and
# horizontal-scroll. Off => long lines run past the right edge and the caret
# drags the view sideways (like a code editor with word-wrap disabled).
# Wrap marks only make sense while wrapping is on, so the sub-checkbox is enabled
# with Wrap and faded (disabled) when Wrap is off.
# Each toggle also stashes its state in a plain var (SET_*) so the final Review
# page (step 13) can read it back after this page has been torn down and rebuilt.
cbWrap_on_activate()   { ft_set tfNotes wrap=true;  ft_set cbWrapInd disabled=false; SET_WRAP=on;  }
cbWrap_on_deactivate() { ft_set tfNotes wrap=false; ft_set cbWrapInd disabled=true;  SET_WRAP=off; }
# Line #s toggles the left line-number gutter live. It is a LAYOUT property (the
# gutter widens the box), so ft_set reflows the field to make room.
cbLineNo_on_activate()   { ft_set tfNotes showLineNumbers=true;  SET_LINES=on;  }
cbLineNo_on_deactivate() { ft_set tfNotes showLineNumbers=false; SET_LINES=off; }
# ↩ marks toggles the right wrap-indicator gutter (also a layout property, so
# ft_set reflows the box to add or reclaim the column).
cbWrapInd_on_activate()   { ft_set tfNotes wrapIndicator=true;  SET_MARKS=on;  }
cbWrapInd_on_deactivate() { ft_set tfNotes wrapIndicator=false; SET_MARKS=off; }
# The Name field feeds the same settings bag as you type.
tfName_on_change() { SET_NAME="$1"; }

# Step 13 — the Review page's Save button. The real action is to open a file
# dialog (a tree-view picker) and write the settings out; that picker is not
# built yet (it needs the tree control), so this is an honest STUB that shows
# exactly what it would write. _settings_summary builds the line fork-free.
_settings_summary() {
    printf -v SET_SUMMARY 'name=%s wrap=%s marks=%s line#=%s style=%s striped=%s' \
        "$SET_NAME" "$SET_WRAP" "$SET_MARKS" "$SET_LINES" "$TBL_STYLE_SEL" "$TBL_STRIPE_SEL"
}
btnSaveSettings_on_activate() {
    _settings_summary
    if ft_file_dialog operation=save path=~/.samba-mago.conf submit=Save; then
        ft_set saveStatus text="Would write {$SET_SUMMARY} to: $FT_FILE_RESULT"
    else
        ft_set saveStatus text="Save cancelled."
    fi
}
# Page 14: the file dialog on its own.
btnOpenFD_on_activate() {
    if ft_file_dialog operation=save path=~/report.txt submit=Save; then
        ft_set fdResult text="You chose: $FT_FILE_RESULT"
    else
        ft_set fdResult text="Cancelled -- nothing chosen."
    fi
}

# Step 10 — each frame's control mutates its OWN border property live.
stDc_on_activate()   { ft_set stD borderStyle=double; ft_set stD title="Double"; }
stDc_on_deactivate() { ft_set stD borderStyle=solid;  ft_set stD title="Single"; }
stRad_on_activate()  { ft_set stR borderRadius=1; }             # rounded corners on
stRad_on_deactivate(){ ft_set stR borderRadius=0; }           # square corners
stHc_on_activate()   { ft_set stH border=true;  }               # show the border
stHc_on_deactivate() { ft_set stH border=false; }               # hide it (keeps the box)
stSsel_on_change()   { ft_set stS borderGlyph="$1"; }           # $this=stSsel, $1=chosen glyph

# Step 8 — a few theme presets; the theme dropdown re-themes the page live by
# overriding palette variables and refreshing. (Colours are just variables.)
# A theme must set the WHOLE palette, not a few vars — leaving the rest at the
# previous theme's values is exactly how you get clashing (a light body with a
# dark scrollbar thumb, a black-on-cyan focus bar over white). Each preset below
# is internally coherent: layered backgrounds, ONE strong focus accent, a
# DISTINCT selection colour, muted borders. The light palette is a clean,
# genuinely high-contrast editor light (near-black text on white, deep-blue
# accent) — not the washed-out low-contrast one it replaces.
apply_theme() {
    case "$1" in
        light)
            # SOFT light: a light-GREY card (252, not glaring near-white) on a medium
            # grey desktop, dark-GREY text (236, not pure black), one deep-blue accent.
            # Dropped a couple of steps down the grey ramp — the old near-white card
            # was too bright to sit in front of.
            FT_COLOR_SCREEN=$'\e[48;5;246;38;5;238m';  FT_COLOR_BODY=$'\e[48;5;252;38;5;236m'
            FT_COLOR_PANE=$'\e[48;5;250;38;5;236m';    FT_COLOR_TITLE=$'\e[48;5;252;38;5;25;1m'
            FT_COLOR_BORDER=$'\e[48;5;252;38;5;245m';  FT_COLOR_DIVIDER=$'\e[48;5;252;38;5;248m'
            FT_COLOR_STRIPE=$'\e[48;5;250;38;5;236m'   # zebra: one shade below the card
            FT_COLOR_FOCUS=$'\e[48;5;25;38;5;255;1m';  FT_COLOR_FOCUS_BTN="$FT_COLOR_FOCUS"
            FT_COLOR_SEL="$FT_COLOR_FOCUS";                FT_COLOR_SEL_DIM=$'\e[48;5;248;38;5;240m'
            FT_COLOR_BUTTON=$'\e[48;5;248;38;5;236m';     FT_COLOR_INPUT=$'\e[48;5;254;38;5;236m'
            FT_COLOR_THUMB=$'\e[48;5;246m';            FT_COLOR_KNOB=$'\e[48;5;252;38;5;25m'
            FT_COLOR_SELECTED=$'\e[48;5;29;38;5;255m'; FT_COLOR_DISABLED_TXT=$'\e[38;5;247m'
            FT_COLOR_DISABLED=$'\e[48;5;251;38;5;248m'; FT_COLOR_RESET="$FT_COLOR_BODY"
            # Gutter rails (line numbers / wrap markers) — a light GREY on this card.
            FT_COLOR_FADED=$'\e[48;5;250;38;5;245m'
            FT_SHEEN_GLOW=6                        # only a whisper of accent in the glow here
            # notice/accent/muted text roles, tuned to read on the grey card
            FT_COLOR_TEXT_NOTICE=$'\e[38;5;130m'; FT_COLOR_TEXT_ACCENT=$'\e[38;5;25m'; FT_COLOR_TEXT_MUTED=$'\e[38;5;245m' ;;
        ocean)
            # CALM deep-water: dark WARM "dark-sand" dialogs floating on a deep-navy
            # desktop, cyan the one bright accent, warm gold notice. The sand is a
            # gentle red tinge over the old neutral grey — a warm-dark tone the 256
            # cube can't name, so the three background shades are built in truecolor
            # (ft_rgb_sgr falls back to the nearest grey on 256-only terminals). A
            # near-neutral body still lets the cyan/gold glow read (the hue contrast
            # the old all-teal palette never gave), so the sheen pops here.
            local _tx=$'\e[38;5;253m' _body _pane _well
            ft_rgb_sgr 52 45 37 48; _body=$FT_RET     # dark sand — the dialog body
            ft_rgb_sgr 68 59 48 48; _pane=$FT_RET     # a warmer step up — panes/zebra
            ft_rgb_sgr 40 34 27 48; _well=$FT_RET      # darker sand — inset wells/gutters
            FT_COLOR_SCREEN=$'\e[48;5;17;38;5;111m';   FT_COLOR_BODY="$_body$_tx"
            FT_COLOR_PANE="$_pane$_tx";                FT_COLOR_TITLE="$_body"$'\e[38;5;51;1m'
            # A muted slate border (66); focusing lights it to bright cyan (51) — a clear
            # jump in both hue and brightness against the warm body.
            FT_COLOR_BORDER="$_body"$'\e[38;5;66m';    FT_COLOR_DIVIDER="$_body"$'\e[38;5;240m'
            FT_COLOR_STRIPE="$_pane$_tx"               # zebra: the lighter sand
            FT_COLOR_FOCUS=$'\e[48;5;51;38;5;16;1m';   FT_COLOR_FOCUS_BTN="$FT_COLOR_FOCUS"
            FT_COLOR_SEL="$FT_COLOR_FOCUS";                FT_COLOR_SEL_DIM=$'\e[48;5;238;38;5;152m'
            FT_COLOR_BUTTON=$'\e[48;5;244;38;5;16m';      FT_COLOR_INPUT="$_well$_tx"
            FT_COLOR_THUMB=$'\e[48;5;245m';            FT_COLOR_KNOB="$_body"$'\e[38;5;51m'
            # Selection is a clear GREEN, a different HUE from the cyan cursor so the
            # two never blur together, and bright against the dark body.
            FT_COLOR_SELECTED=$'\e[48;5;29;38;5;255m'; FT_COLOR_DISABLED_TXT=$'\e[38;5;240m'
            FT_COLOR_DISABLED="$_body"$'\e[38;5;240m'; FT_COLOR_RESET="$FT_COLOR_BODY"
            FT_COLOR_FADED="$_well"$'\e[38;5;245m'     # gutter rails: the inset-well sand
            FT_SHEEN_GLOW=16                       # near-neutral body → the cyan/gold glow reads
            # notice/accent/muted text roles, tuned to read on the sand body
            FT_COLOR_TEXT_NOTICE=$'\e[38;5;222m'; FT_COLOR_TEXT_ACCENT=$'\e[38;5;51m'; FT_COLOR_TEXT_MUTED=$'\e[38;5;245m' ;;
        *)  ft_setup_palette ;;   # dark: the default theme
    esac
}
theme_on_change() { THEME_SEL=$1; apply_theme "$1"; ft_refresh; }   # $1 = chosen theme value; remember it

# Step 9 — the SAME one box, hidden two ways. Each toggle button reads the box's
# current state, flips it, and relabels itself. display:none reflows (box AND
# space vanish -- the buttons jump up); visibility:hidden keeps the space (only
# the ink disappears). The accelerator letter lives inside each label so it
# shows underlined (R in Remove/Restore, V in inVisible/Visible).
btnDisp_on_activate() {
    local d; ft_get hideBox display d
    if [[ "$d" == none ]]; then ft_set hideBox display=flex; ft_set btnDisp text="Remove"
    else ft_set hideBox display=none; ft_set btnDisp text="Restore"; fi
}
btnVis_on_activate() {
    local v; ft_get hideBox visibility v
    if [[ "$v" == hidden ]]; then ft_set hideBox visibility=visible; ft_set btnVis text="Invisible"
    else ft_set hideBox visibility=hidden; ft_set btnVis text="Visible"; fi
}

# Page 12: live table experiments. Style changes the grid's SIZE (a reflow);
# striped is a pure repaint. Both persist in vars so a page rebuild keeps them.
tblStyle_on_change()  { TBL_STYLE_SEL=$1;  ft_set keys style="$1"; }
tblStripe_on_change() { TBL_STRIPE_SEL=$1; ft_set keys striped="$1"; }

# Rebuild the current step on terminal resize (also refreshes step 4's text).
_resize() {
    ft_set app width="$FT_COLS" height="$FT_ROWS"
    _show_step
}

# ── Run ──────────────────────────────────────────────────────────────────────
# setup builds the first page; render (5th arg) rebuilds a page once per input
# burst when a handler called ft_invalidate. Interactive handlers that only
# tweak controls (checkbox, slider, hide/show) skip invalidate and get a cheap
# partial repaint instead.
# The app is a COLUMN: a stage that fills the screen and centres each page, and a
# persistent two-line status bar pinned to the very bottom. Keeping the bar here
# (app level, not inside the page frame) means it never eats the page's height
# budget -- _show_step rebuilds the STAGE's contents, the bar stays put.
ft-form name=app width="$FT_COLS" height="$FT_ROWS" \
        display=flex flexDirection=column \
        key='[Qq]' onKey=ft_quit
    # overflow=hidden CLIPS an over-tall page to the stage so it can never paint
    # over the bar; minHeight=0 lets the stage actually shrink (a flex item's
    # default min-height is its content, which would otherwise shove the bar off).
    ft-div name=stage flexGrow=1 flexShrink=1 minHeight=0 overflow=hidden \
             display=flex justifyContent=center alignItems=center
    end_ft_div
    # flexShrink=0 pins the bar to its 2 rows no matter how tight the screen gets.
    # keys=auto: the legend is DERIVED from whatever the focused control can do right now,
    # sorted by importance — so on the scrolling page it leads with Up/Down, on a slider
    # with ←/→, etc. The app-level keys below are always available, so they are registered
    # as caps on the app's own keymap and fall in below the focused control's crucial ones.
    ft-keylegend name=navlegend flexShrink=0 keys=auto
    ft-statusbar name=navbar     flexShrink=0 \
        status="Loading…" \
        text[textCopied]="Selected text copied to the clipboard.,2,8"
end_ft_form
# App-level legend caps. The engine/accelerator keys are LEGEND-ONLY ("-"): they show in
# the strip but are handled elsewhere (Tab = focus traversal, Enter/Esc = the focused
# control, K/B = the OK/Back button accelerators), so declaring them here never shadows
# that. Q is a real binding (ft_quit) that also carries a label.
ft_set app \
    key='[Kk]' keyCap="Next page" keyImp=150 \
    key=ENTER keyCap="Edit / activate" keyImp=100 \
    key=TAB keyCap="Next field" keyImp=90 \
    key=ESC keyCap="Exit edit" keyImp=80 \
    key='[Bb]' keyCap="Back" keyImp=50 \
    key='[Qq]' keyCap="Quit" keyImp=40 onKey=ft_quit
ft_run app _show_step _resize "" _show_step
