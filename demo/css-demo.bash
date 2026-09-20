#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — demo/css-demo.bash   (a guided tour of the CSS engine)
#
#  TEN pages, one CSS concept each. Every page has the SAME specimen — an
#  ordinary text box named `spec` — and the page's controls manipulate how that
#  text box is displayed, so you SEE the concept act on a real control:
#
#     1  Inheritance          6  Colour formats (#hex / rgb() / hsl() / names)
#     2  Selectors            7  Pseudo-elements (structures)
#     3  Specificity          8  Animation (@keyframes)
#     4  States (:focus …)    9  Combinators
#     5  Custom props+var()  10  Themes
#
#  Each page is WALKED IN STEPS. A number BEACON (①②③…) is parked on every
#  control the page talks about, so the CSS's #ids and .classes are never a
#  mystery — you can SEE which box is #spec and which control is which. "Okay"
#  advances to the next STEP on the page (its beacon lights up and the write-up
#  explains it); at the last step it moves to the next page. "Back" reverses.
#
#  Okay  next step/page  ·  Back  previous  ·  Tab move · Enter use a control · Q quit
#
#    bash demo/css-demo.bash
# ─────────────────────────────────────────────────────────────────────────────
set -o pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/fruity-tui.bash"
ft_init
ft_term_size
[[ -z "${FT_NO_WTFIX:-}" ]] && declare -F ft_wt_autofix_enter >/dev/null && ft_wt_autofix_enter

PAGE=${DEMO_PAGE:-1}    # DEMO_PAGE=N jumps straight to a page (handy for screenshots/tests)
STEP=1
LAST=10

# The specimen text — a long line that SOFT-wraps (shows ↩) plus a HARD newline
# (shows ¶), so both line indicators are visible on every page.
SPEC=$'The quick brown fox jumps over the lazy dog — a long line that soft-wraps.\nAnd this second line follows a hard newline.'
# Line indicators on #spec, toggled live with w / n (see _toggle_wrap/_toggle_nl).
SHOW_WRAP=true; SHOW_NL=true

# ── Per-page state (plain vars, so a page rebuild keeps your choices) ──────────
INH_COLOR=crimson; INH_BOLD=off                 # 1 inheritance
SEL_CLASS=none                                  # 2 selectors  (none|warning|ok)
SP_TYPE=on; SP_CLASS=off; SP_ID=off             # 3 specificity (which rules exist)
ST_DISABLED=off                                 # 4 states
VAR_ACCENT=crimson                              # 5 var()
CF_FMT="crimson"                                # 6 colour formats
STRUCT=border                                   # 7 pseudo-elements
AN_NAME=none; AN_DUR=2                           # 8 animation
CB_NEST=off                                     # 9 combinators
THEME_SEL=dark                                  # 10 themes

# ── Per-page STEP annotations ─────────────────────────────────────────────────
# _page_annotations fills three parallel arrays for the CURRENT page: the control
# each step points at, WHERE to place its callout (above/below/left/right/auto),
# and the short instruction the callout shows. Step N gets circled-number beacon N
# parked on its control AND a pop-up callout pointing at it; the step count per
# page is just ${#PA_TARGET[@]}.
declare -a PA_TARGET=() PA_PLACE=() PA_TEXT=()
_page_annotations() {
    PA_TARGET=(); PA_PLACE=(); PA_TEXT=()
    # _ann TARGET [PLACE] TEXT — PLACE only when the author actually has a preference. It used
    # to be mandatory, so every annotation named a side whether or not it meant anything, and
    # the placer honoured each one at _PLACE_BIAS (24000) — enough to outvote every other
    # consideration. The sides given were mechanical ("above" for the specimen, "below" for the
    # control row): they restated where the target already sat rather than expressing an intent,
    # and they pinned callouts to a side that could only reach the target with a long dog-leg.
    # An unset preference is not a missing value here; it is the author saying "you choose".
    _ann() { PA_TARGET+=("$1")
             if (( $# >= 3 )); then PA_PLACE+=("$2"); PA_TEXT+=("$3")
             else                   PA_PLACE+=(auto); PA_TEXT+=("$2"); fi; }
    # None of these ask for a side: every one of them just wants to point at its control without
    # covering it, which is the placer's job and not something a table should be second-guessing.
    case "$PAGE" in
    1)  _ann spec "#spec is the specimen text box every page restyles. On its own it sets NO colour of its own."
        _ann spec "Its crimson comes from #inhbox — the ft-div CONTAINER wrapping #spec (the dashed ghost outline). #spec INHERITS it; so does the label."
        _ann inhColor "Change #inhbox's colour here — #spec and the label follow. That is inheritance, live."
        _ann inhBold "Tick Bold: it sets font-weight on #inhbox, and #spec inherits that too." ;;
    2)  _ann spec "#spec is an editable ft-textfield. The .class you give it decides which rule below paints it."
        _ann selClass "Choose a class. .warning → crimson + bold; .ok → green. The bash pane shows the exact ft_set call." ;;
    3)  _ann spec "This one box, #spec, is matched by ALL three selectors at once: type (textfield), class (.hot), id (#spec)."
        _ann spType "textfield{} alone — specificity 1. Untick the others and it wins by default."
        _ann spClass ".hot{} — specificity 100. Tick it and it overrides the plain textfield rule."
        _ann spId "#spec{} — specificity 10000. Tick it and it beats every other rule, whatever else is on." ;;
    4)  _ann spec "#spec is an editable ft-textfield. Its LOOK follows its state — focus, edit, disabled."
        _ann stDisabled "Tick this to set disabled=true on #spec, so the textfield:disabled rule starts matching." ;;
    5)  _ann spec "#spec's colour is var(--accent) — it points at a custom property instead of a fixed colour."
        _ann varPick "Change --accent here; #spec (and anything else using var(--accent)) re-tints at once." ;;
    6)  _ann spec "#spec shows the chosen colour. The four modes below are the SAME colour, written differently."
        _ann cfFmt "Switch the syntax: a colour name, #hex, rgb(), or hsl(). Same result each time." ;;
    7)  _ann spec "#spec is an editable ft-textfield made of inner substructures you can style one at a time."
        _ann structPick "Pick a pseudo-element; only THAT part of #spec restyles. The demo sets up the state so you can see it." ;;
    8)  _ann spec "#spec plays a @keyframes animation on its colour, live."
        _ann animPick "Choose which @keyframes runs on #spec — or 'none' to stop it."
        _ann animDur "The slider is the DURATION — seconds for ONE cycle. Right = slower, left = faster." ;;
    9)  _ann spec "#spec is the box we can wrap in a .spotlight. The rule '.spotlight textfield' only matches inside a spotlight."
        _ann specOut "#specOut is an identical box that is NOT in the spotlight — so it can never match. That is the proof."
        _ann cbNest "Tick to wrap #spec in a .spotlight. Only #spec turns gold; #specOut stays put." ;;
    10) _ann spec "#spec is styled by the ACTIVE theme's palette — no rule of its own."
        _ann themePick "Switch the theme: it is just another stylesheet, and the whole page re-derives its colours." ;;
    esac
}

# ── The per-page stylesheet ───────────────────────────────────────────────────
# _demo_css sets DCSS to the CSS for the CURRENT page; _register_sheet installs it as the `demo`
# sheet at build time. It is now essentially STATIC per page — every page styles the specimen with
# real CSS and drives it live by manipulating the ELEMENT (ft_set class / property / --custom-
# property / state), NOT by rewriting CSS. The ONE exception is page 3 (specificity), whose whole
# lesson is editing the stylesheet itself; it re-registers via _sp_restyle. (SP_TYPE etc. are the
# page's model — what the user last picked — so a page rebuild can restore it.)
DCSS=""
_demo_css() {
    case "$PAGE" in
    2)  DCSS='.warning { color: crimson; font-weight: bold; }
             .ok      { color: rgb(64, 200, 90); }' ;;
    3)  DCSS=""
        [[ "$SP_TYPE"  == on ]] && DCSS+=$'\n''textfield { color: 33; }'     # type  →1
        [[ "$SP_CLASS" == on ]] && DCSS+=$'\n''.hot      { color: 202; }'    # class →100
        [[ "$SP_ID"    == on ]] && DCSS+=$'\n''#spec     { color: 201; }' ;; # id    →10000
    4)  DCSS='textfield:focus    { border-color: dodgerblue; }
             textfield:disabled { color: 244; }
             textfield:editing     { border-color: gold; }' ;;
    5)  DCSS='#spec { color: var(--accent); }' ;;   # STATIC; the dropdown re-points --accent ON #spec
                                                     # itself (ft_set spec --accent=…), like the DOM's
                                                     # element.style.setProperty — no sheet rewrite.
    7)  # All five pseudo-element rules are STATIC and class-GATED (#spec.pe-caret::caret …). The
        # dropdown just sets #spec's class (ft_set spec class=pe-…), so exactly one is ever in
        # play — real CSS + a class toggle, no sheet rewrite.
        DCSS='#spec.pe-border::border           { border-color: magenta; }
              #spec.pe-selection::selection     { background-color: magenta; color: 16; }
              #spec.pe-scrollbar::scrollbar     { color: magenta; }
              #spec.pe-caret::caret             { background-color: magenta; color: 16; }
              #spec.pe-placeholder::placeholder { color: magenta; }' ;;
    8)  # The @keyframes are DEFINED in the sheet (they are fancy CSS — a stylesheet thing).
        # But PLAYING one is just a property: #spec's `animation` is set live with ft_set,
        # NOT by re-registering the sheet. So the sheet here is static; only the prop changes.
        DCSS=":root { --g1: crimson; --g2: gold; }
             @keyframes glow  { from, to { color: var(--g1); } 50% { color: var(--g2); } }
             @keyframes alarm { from, to { color: var(--g1); } 50% { color: 16; } }" ;;
    9)  DCSS='.spotlight textfield { color: gold; font-weight: bold; }' ;;
    *)  DCSS="" ;;     # 1, 6, 10 style the specimen inline / via the theme
    esac
}
# Registering a stylesheet bumps the CSS-cache epoch, forcing a full re-cascade of
# every control — expensive. So only (re)register when the page's CSS ACTUALLY changed
# (a page switch, or a control toggling a rule). Stepping through a page does NOT change
# the CSS, so the cache stays warm and rebuilds stay cheap.
_LAST_DCSS=$'\x00'          # a value DCSS can never equal, so the first apply registers
_register_sheet() { _demo_css; [[ "$DCSS" == "$_LAST_DCSS" ]] && return; _LAST_DCSS=$DCSS; ft_stylesheet name=demo style="$DCSS"; }
# NO REPAINT CODE. A `_repaint_spec` used to live here — three hand-picked subtrees dirtied
# after every style change, chosen to dodge the 0.3s full repaint the code panes cost. Both
# halves of that are the engine's job now, and the hand-picked list was also WRONG: page 3's
# bare `textfield` rule styles the code panes too (they are textfields), so a repaint list
# without them showed stale pane colours after every toggle. Measured: hand list 23ms/toggle
# but stale; engine 63ms and correct; full repaint 294ms. See docs/styling-model.md.
#   · editing the SHEET (page 3's checkboxes): ft_stylesheet restyles what the sheet's own
#     selectors can match, old rules and new — CSSOM behaviour, zero app repaint code;
#   · changing a PROPERTY (every other page): ft_set dirties by kind, subtree-wide when
#     the property inherits or is a --custom one.
# Page 3 (specificity) is the ONE page that edits the STYLESHEET at runtime: its checkboxes add and
# remove whole rules — you cannot toggle a type or #id rule via an element property. Every OTHER
# page manipulates the ELEMENT instead (class / property / --custom-property / state).
_sp_restyle() { _register_sheet; }
# Regenerate the CSS + bash code panes from the CURRENT state (so they SHOW the live rule/call the
# controls just made, not a stale generic example). Pages whose _page_content reads the state vars
# (7 substructures, 8 animation) get accurate, changing code; the rest re-render identically.
_refresh_code_panes() {
    [[ -n "${FT_TYPE[css]:-}" ]] || return 0
    local title CONCEPT CSS BASH
    _page_content
    ft_set css  value="$CSS"
    ft_set bash value="$BASH"
    return 0
}

# Chrome the demo owns (registered ONCE, not per page): unfocused step-beacons are a
# muted grey; the ACTIVE step's beacon pulses the themed locator colour, so the eye
# lands on the control the current write-up is talking about.
ft_stylesheet name=demochrome style='beacon::number { color: 245; }
                                     #inhghost::border { color: subtext; }'
# The page-1 GHOST: a STATIC, neutral, dashed outline tracing #inhbox (a plain ft-div with no
# border of its own) — shown ONLY on step 2 (where the write-up talks about the container), gone
# on any other step. Static (effect=none) so it never animates over the callout; the callout,
# being z=10, always composites on top.
_place_ghost() {
    ft_remove inhghost 2>/dev/null
    # outset=1: the outline sits ONE cell OUTSIDE #inhbox, so it never coincides with (and tramples)
    # the specimen's own top border — it reads as a halo around the container, not a second border.
    [[ "$PAGE" == 1 && "$STEP" == 2 ]] && ft-beacon name=inhghost parent=lower target=inhbox \
        variant=frame effect=none frameStyle=dashed lifetime=persist outset=1
    return 0
}

# ── Titled read-only panels (Enter-to-edit: focus to scroll, never traps keys) ─
_code_panel() {                 # name title text — a titled read-only code box (a column)
    ft-div name="${1}Pane" display=flex flexDirection=column gap=0 alignItems=start
        ft-label name="${1}Title" color=accent text="$2"
        ft-textfield name="$1" value="$3" readOnly=true wrap=false size=42 rows=6
    end_ft_div
}

# ═══ Control hooks — every one manipulates how `spec` is displayed ═════════════

# 1 Inheritance — the CONTAINER carries color/font-weight; spec (and the labels)
# set none of their own, so they INHERIT it. Changing the parent flows down.
# Setting the property is the whole of it: color and font-weight INHERIT, so ft_set
# repaints the subtree that inherits them. (These three used to carry a ft_dirty_subtree each.)
inhColor_on_change()    { INH_COLOR=$1; ft_set inhbox color="$1";        return 0; }
inhBold_on_activate()   { INH_BOLD=on;  ft_set inhbox fontWeight=bold;   return 0; }
inhBold_on_deactivate() { INH_BOLD=off; ft_set inhbox fontWeight=normal; return 0; }

# 2 Selectors — a class on the specimen decides which rule matches it.
selClass_on_change() { SEL_CLASS=$1; ft_set spec class="${1/none/}"; return 0; }

# 3 Specificity — toggle whole RULES on/off; the most specific match always wins,
# whatever order they appear in. id(10000) > class(100) > type(1).
spType_on_activate()   { SP_TYPE=on;   _sp_restyle; }
spType_on_deactivate() { SP_TYPE=off;  _sp_restyle; }
spClass_on_activate()  { SP_CLASS=on;  _sp_restyle; }
spClass_on_deactivate(){ SP_CLASS=off; _sp_restyle; }
spId_on_activate()     { SP_ID=on;     _sp_restyle; }
spId_on_deactivate()   { SP_ID=off;    _sp_restyle; }

# 4 States — disabling the specimen makes textfield:disabled match; focusing it
# (Tab) makes :focus match; pressing Enter to edit makes :editing match. Live CSS.
stDisabled_on_activate()   { ST_DISABLED=on;  ft_set spec disabled=true;  return 0; }
stDisabled_on_deactivate() { ST_DISABLED=off; ft_set spec disabled=false; return 0; }

# 5 Custom properties — the select sets --accent as a PROPERTY on #spec itself (the engine's
# runtime custom-property support, like the DOM's element.style.setProperty('--accent', …)); spec's
# color is var(--accent), so it re-tints at once. No stylesheet rewrite — a real property change.
varPick_on_change() { VAR_ACCENT=$1; ft_set spec --accent="$1"; _refresh_code_panes; return 0; }

# 6 Colour formats — the same crimson, expressed four ways; each sets spec's
# color inline (the highest-precedence layer, so it always shows).
cfFmt_on_change() { CF_FMT=$1; ft_set spec color="$1"; return 0; }

# 7 Pseudo-elements — restyle ONE substructure of the box at a time. Each one is only VISIBLE in a
# particular state, so the demo puts #spec into it: caret ⇒ edit mode, selection ⇒ a live
# selection, placeholder ⇒ an EMPTY field, scrollbar ⇒ overflow (the long text already overflows).
_setup_struct_state() {
    [[ -n "${FT_TYPE[spec]:-}" ]] || return 0
    unset "FT_TEXTFIELD_MARK[spec]" 2>/dev/null
    [[ "$STRUCT" == placeholder ]] && ft_set spec value="" || ft_set spec value="$SPEC"
    case "$STRUCT" in
        caret)     ft_set spec runlevel=editing; FT_TEXTFIELD_CARET[spec]=6 ;;
        selection) ft_set spec runlevel=editing; FT_TEXTFIELD_MARK[spec]=4; FT_TEXTFIELD_CARET[spec]=19 ;;
        *)         ft_set spec runlevel=unfocused ;;
    esac
    return 0
}
structPick_on_change() { STRUCT=$1; ft_set spec class="pe-$STRUCT"; _setup_struct_state; _refresh_code_panes; return 0; }

# 8 Animation — pick a @keyframes (or none) and a duration; it runs on spec live.
# The keyframes live in the sheet; PLAYING one is a property — set #spec's `animation`
# with ft_set (name + duration), exactly what the bash code pane shows.
animPick_on_change() { AN_NAME=$1; ft_set spec animation="$AN_NAME ${AN_DUR}s"; _refresh_code_panes; return 0; }
animDur_on_change()  { AN_DUR=$1;  ft_set spec animation="$AN_NAME ${AN_DUR}s"; _refresh_code_panes; return 0; }

# 9 Combinators — giving the CONTAINER class="spotlight" makes the descendant rule
# `.spotlight textfield { … }` match spec; removing it stops the match. #specOut lives
# OUTSIDE the spotlight, so it never matches — that is the proof the combinator works.
cbNest_on_activate()   { CB_NEST=on;  ft_set combox class=spotlight; return 0; }
cbNest_on_deactivate() { CB_NEST=off; ft_set combox class="";   return 0; }

# 10 Themes — one call swaps the whole stylesheet and re-derives the palette.
themePick_on_change() { THEME_SEL=$1; ft_use_theme "ft-$1"; ft_refresh; }

# The current step's teaching CALLOUT — a pop-up box, declared as the LAST child of
# the frame so it paints ON TOP, with the instruction and a filled-triangle pointer
# aimed at the control it is about. Its leading circled number ①②③ IS the step
# number, so stepping walks the eye ①→②→③ through the page. (A callout that points
# and instructs replaced the old row of static number badges — one clear thing at a
# time, which is what a confused first-timer needs.)
# The step callout lives ENTIRELY in the screen margin (box + leader + arrowhead), with
# the arrowhead stopping just OUTSIDE the frame (boundRight = the frame's right edge) so it
# never overlaps any content — and so a step change can erase it by simply wiping the
# (otherwise empty) margin, with no page repaint. effect=none → static (idle event loop).
_place_callout() {
    local i=$(( STEP - 1 ))
    # Just name the TARGET and let the beacon place itself — place=auto scores the four sides
    # and parks the box in the emptiest one (never over the code panes or another control),
    # routing a leader to the exact target. The user can drag it aside; the arrow follows.
    # parent=lower keeps it in the stage subtree, and the engine composites overlays last so
    # nothing tramples it.
    # boundBox=win keeps the whole callout INSIDE the frame — never spilling past its border into
    # the screen margin, where a step change couldn't erase it (that was the residue). The scorer
    # still keeps it off the code panes + controls, so it lands in the frame's empty side margin.
    # onNext=btnStepNext_on_activate → the callout draws a clickable ▶ that walks to the next step
    # (except on the last step, where there is nothing to advance to).
    local onnext=""; (( STEP < ${#PA_TARGET[@]} )) && onnext="btnStepNext_on_activate"
    # PA_PLACE is the whole point of the annotation table — "above" for the specimen boxes so the
    # pointer comes DOWN onto them, "below" for the control row so it comes UP. It was collected
    # by _ann, documented, and then never passed: every callout silently took place=auto, which
    # parked the specimen's callout off to the RIGHT and ran its leader back across the box's own
    # scrollbar. An unused variable is not a harmless one when it is the author's intent.
    # NO boundBox: the callout may use the screen margin, which on a wide terminal is most of the
    # free space there is. It was pinned inside the frame because a rect STRADDLING the frame's
    # border enlisted the frame for repair, which repainted its whole interior and wiped the
    # prose and both code panes — they had never intersected the damaged rect, so nothing was
    # left to paint them back. That was a defect in the engine's damage repair (a container now
    # enlists the descendants it will paint over), not a reason to give up the margin, and
    # tests/test-notrace.bash — which caught the erase in the first place — is what says so.
    ft-beacon name=stepcallout parent=lower target="${PA_TARGET[$i]}" variant=callout number="$STEP" \
              place="${PA_PLACE[$i]}" \
              calloutWidth=44 effect=none outset=0 onNext="$onnext" \
              text="${PA_TEXT[$i]}"
}
# A STEP change (not a page change): the page is identical except the callout, the step
# counter and the arrow-button enable state — so update just those, no rebuild/relayout.
_goto_step() {
    _page_annotations; local nsteps=${#PA_TARGET[@]}
    (( STEP < 1 )) && STEP=1; (( STEP > nsteps )) && STEP=$nsteps
    # ft_remove gives back every cell each callout painted — box, leader and arrowhead, all
    # outside its own layout bounds. Capturing FT_BEACON_EXTENT here and handing it to
    # ft_damage was the app doing the engine's job.
    ft_remove stepcallout 2>/dev/null; ft_remove introcallout 2>/dev/null
    _place_ghost                         # show the dashed container outline ONLY on step 2
    ft_set stepcount text=" Step $STEP of $nsteps "
    (( STEP == 1 ))      && ft_set btnStepPrev disabled=true || ft_set btnStepPrev disabled=false
    (( STEP == nsteps )) && ft_set btnStepNext disabled=true || ft_set btnStepNext disabled=false
    # (the status bar is NOT touched here — changing its text re-triggers its sweep
    #  animation every step; the frame's own "Step S of N" is the live indicator.)
    _place_callout
    # NOTHING PAINTS HERE. ft_remove damaged what the callout covered and every ft_set above
    # dirtied what it changed; the run loop settles the burst and paints once. The stage-wide
    # repaint, four ft_dirty calls and a trailing ft_redraw_dirty that used to live here were
    # the app standing in for the engine's damage compositor — and the ft_redraw_dirty was a
    # no-op anyway, since it returns immediately while FT_COALESCING is set. A gate that drives
    # this function directly settles it itself (tests/_harness.bash: settle).
}

# ── Per-page teaching content ─────────────────────────────────────────────────
# title, CONCEPT (the big-picture "why", teacher voice), CSS (the stylesheet), and
# BASH (how the controls are CONSTRUCTED — this is where #ids and .classes come from).
_page_content() {
    case "$PAGE" in
    1)  title="1 · Inheritance"
        CONCEPT="CSS styles CONTROLS the same way it styles HTML elements: by a #id (unique) or a .class (shared). The first big idea is INHERITANCE — set a property once on a container and everything inside picks it up, so you never repeat yourself. Below, ONLY the outer box names a colour; the text box and label inside simply inherit it."
        # Page 1 is where we ESTABLISH the stylesheet — the one and only place the raw
        # ft_stylesheet call is shown. Everywhere after this, the sheet is a given, and the
        # code panes show the RELEVANT rule + the property (ft_set) that changes it live.
        CSS='/* the app stylesheet — authored once, like any .css file: */
#inhbox { color: crimson; }   /* the container names a colour */
#spec   { }                   /* the box names NONE → it INHERITS */'
        BASH='ft_stylesheet name=demo style="$DEMO_CSS"   # ← register it ONCE
ft-div name=inhbox                    # the #inhbox container
    ft-textfield name=spec value=…    # #spec sets no colour of its own
end_ft_div
# ── the dropdown changes the PARENT, live (a property, not CSS): ──
ft_set inhbox color=dodgerblue     #  ▸ the whole subtree re-tints' ;;
    2)  title="2 · Selectors — classes"
        CONCEPT="A selector decides WHICH controls a rule paints. Besides the #id, the workhorse is the .class: a label you can put on many controls and add or remove at runtime. Fruity supports almost all of real CSS this way. Below, the box's class chooses which of the two rules styles it."
        CSS='.warning { color: crimson; font-weight: bold; }
.ok      { color: rgb(64, 200, 90); }
/* whichever class #spec carries is the rule that paints it */'
        BASH='ft-textfield name=spec value=…       # no class yet → neither rule
# ── the dropdown sets the class live (like el.className): ──
ft_set spec class=warning         #  ▸ .warning matches
ft_set spec class=ok              #  ▸ .ok matches
ft_set spec class=""              #  ▸ no class → default look' ;;
    3)  title="3 · Specificity"
        CONCEPT="When several rules match the SAME control, which wins? CSS ranks them by specificity: an #id beats a .class beats a plain type name. That lets a specific rule override a general one without any fighting or ordering tricks. Below, one box matches all three rules at once — toggle them and watch the winner."
        CSS='textfield { color: 33;  }   /* type  · specificity     1 */
.hot      { color: 202; }   /* class · specificity   100 */
#spec     { color: 201; }   /* id    · specificity 10000 */
/* all three match #spec at once; the MOST SPECIFIC wins    */'
        BASH='# #spec matches all three rules — its type, its .hot class, its #id.
# THIS page edits the STYLESHEET: each checkbox adds/removes a rule, then
# re-registers it (a type or #id rule cannot be toggled per element):
ft_stylesheet name=demo style="textfield{color:33} #spec{color:201}"
#   ▸ specificity, not source order, always picks the winner.' ;;
    4)  title="4 · State pseudo-classes"
        CONCEPT="Pseudo-classes match on a control's LIVE state, not its markup — :focus while it's focused, :disabled when disabled, :editing while you're typing in it. The style follows the state automatically."
        CSS='textfield:focus    { border-color: dodgerblue; }
textfield:editing     { border-color: gold; }
textfield:disabled { color: 244; }
/* each matches on the box'"'"'s LIVE state — no markup change */'
        BASH='ft-textfield name=spec value=…       # editable by default
# ── change the STATE; the matching rule follows automatically: ──
ft_set spec disabled=true         #  ▸ :disabled now matches
#   Tab onto it → :focus      Enter to edit → :editing' ;;
    5)  title="5 · Custom properties + var()"
        CONCEPT="A custom property (--name) is a value you name once and reuse with var(). It's the CSS way to keep a colour or size in ONE place — change it there and everything re-tints, all without leaving CSS to write bash calls per control."
        CSS='#spec { color: var(--accent); }   /* read a custom property by reference */
/* --accent is defined ON the element (or inherited); change it and
   every var(--accent) re-resolves — no rule is rewritten. */'
        BASH='ft-textfield name=spec --accent=crimson   # the property, set on #spec
# ── the dropdown re-points it live — a real property, like the DOM: ──
ft_set spec --accent=dodgerblue     #  ▸ el.style.setProperty("--accent", …)
#   ▸ #spec color = var(--accent) re-resolves to the new value at once' ;;
    6)  title="6 · Colour formats"
        CONCEPT="A colour can be written four ways — a CSS name, #rrggbb hex, rgb(), or hsl() — and they all resolve to the same pixels. Pick whichever reads best where you are; below, each mode drives its own little controls, but they all land on the same crimson."
        CSS='/* the SAME crimson, written four ways — identical pixels: */
color: crimson;              /* a CSS colour name */
color: #dc143c;              /* #rrggbb hex       */
color: rgb(220, 20, 60);     /* rgb() channels    */
color: hsl(348, 83%, 47%);   /* hsl() wheel       */'
        BASH='# the dropdown sets #spec'"'"'s colour inline — a PROPERTY, 4 notations:
ft_set spec color=crimson
ft_set spec color=#dc143c
ft_set spec color="rgb(220,20,60)"
ft_set spec color="hsl(348,83%,47%)"    #  ▸ all the same colour' ;;
    7)  title="7 · Pseudo-elements (substructures)"
        CONCEPT="A control is not one flat thing — it has inner substructures you can style on their own: its ::border, the ::selection highlight, the ::scrollbar, the ::caret, its ::placeholder. In real CSS these are pseudo-elements. Below, each choice styles just ONE part of the box and leaves the rest alone — and each part is only VISIBLE in a certain state, so the demo puts #spec into it."
        # Pseudo-elements can ONLY be styled from a stylesheet (there is no per-part property), so
        # every part's rule lives in the sheet, GATED by a class; the dropdown just sets #spec's
        # class. The bash pane shows that class toggle + the state that makes the part visible.
        local _rule _setup
        case "$STRUCT" in
            border)      _rule='#spec.pe-border::border { border-color: magenta; }'
                         _setup='# ::border is always on screen — no extra state needed.' ;;
            selection)   _rule='#spec.pe-selection::selection { background: magenta; color: 16; }'
                         _setup='FT_TEXTFIELD_MARK[spec]=4; FT_TEXTFIELD_CARET[spec]=19   # a live selection to show' ;;
            scrollbar)   _rule='#spec.pe-scrollbar::scrollbar { color: magenta; }'
                         _setup='# the value overflows 2 rows → a ::scrollbar shows on its own' ;;
            caret)       _rule='#spec.pe-caret::caret { background: magenta; color: 16; }'
                         _setup='ft_set spec runlevel=editing   # enter edit mode so the ::caret is drawn' ;;
            placeholder) _rule='#spec.pe-placeholder::placeholder { color: magenta; }'
                         _setup='ft-textfield name=spec placeholder="type here…"  # the placeholder TEXT
ft_set spec value=""            #  ▸ empty the field so the ::placeholder shows' ;;
            *)           _rule='#spec.pe-border::border { border-color: magenta; }'; _setup='#' ;;
        esac
        CSS="/* one static rule per part, GATED by a class — the box's current
   class picks the one in play; the rest are untouched: */
$_rule"
        BASH="# the dropdown sets #spec's class — real CSS, no sheet rewrite:
ft_set spec class=pe-$STRUCT
# …and put the box in the state where that part is visible:
$_setup" ;;
    8)  title="8 · Animation (@keyframes)"
        CONCEPT="@keyframes describes how a property changes OVER TIME. The keyframes are defined in the stylesheet, but PLAYING one is just a property: set a control's animation to a name + duration. Below, pick a keyframes set and a duration and watch #spec tween its colour live."
        CSS="/* two @keyframes DEFINED in the sheet (fancy CSS, so it's shown): */
@keyframes glow  { from,to { color: crimson } 50% { color: gold } }
@keyframes alarm { from,to { color: crimson } 50% { color: 16   } }"
        BASH="# playing an animation is a PROPERTY — a @keyframes name + a duration.
# the dropdown and slider just set it on #spec, live:
ft_set spec animation=\"$AN_NAME ${AN_DUR}s\"
#   ▸ animation=\"none …\" stops it;  ${AN_DUR}s = seconds PER cycle (slider)" ;;
    9)  title="9 · Combinators"
        CONCEPT="A combinator matches by RELATIONSHIP. The descendant combinator '.spotlight textfield' matches a text field only when it sits INSIDE a .spotlight. Below there are two identical boxes — the proof is that only the one wrapped in a .spotlight ever changes."
        CSS='.spotlight textfield { color: gold; font-weight: bold; }
/* matches a textfield ONLY inside a .spotlight ancestor */'
        BASH='ft-div name=combox                    # the wrapper around #spec
    ft-textfield name=spec text=… # INSIDE → can match
end_ft_div
ft-textfield name=specOut text=… # OUTSIDE → never matches (the proof)
# ── the checkbox toggles the wrapper'"'"'s class, live: ──
ft_set combox class=spotlight      #  ▸ only #spec turns gold' ;;
    10) title="10 · Themes"
        CONCEPT="A theme is nothing special — it is just a stylesheet that owns the palette. Swap the active theme and every control re-derives its colours from the new one; your own rules keep riding on top. Below, switch themes and watch the whole page repaint."
        CSS='/* a theme is a normal stylesheet of :root variables + rules: */
:root { --accent-text: 39;  --surface: … ;  … }'
        BASH='# one call swaps the whole active stylesheet; controls re-derive:
ft_use_theme ft-dark
ft_use_theme ft-ocean      #  ▸ the page repaints from the new palette
# your own #id / .class rules keep riding on top, unchanged.' ;;
    esac
}

# ═══ The page builder ═════════════════════════════════════════════════════════
_show_page() {
    _page_annotations
    local nsteps=${#PA_TARGET[@]}
    (( STEP < 1 )) && STEP=1
    (( STEP > nsteps )) && STEP=$nsteps
    local oktext=Okay; (( PAGE == LAST )) && oktext=Done   # Okay = next page; the last page finishes
    local title CONCEPT CSS BASH
    _page_content   # fills title / CONCEPT (teacher prose) / CSS / BASH for this page

    _register_sheet    # ensure this page's stylesheet is current BEFORE building (no layout
                       # here — the ft_refresh at the end lays out the rebuilt tree once)

    ft_empty stage
        ft-frame name=win title="The Fruity CSS engine — $title  ($PAGE/$LAST)" \
                 display=flex flexDirection=column gap=1 padding=1 alignItems=center \
                 borderStyle=double
            # ── 1. The BIG PICTURE — a borderless label of teacher prose (why, first) ──
            ft-label name=concept width=88 color=subtext text="$CONCEPT"

            # ── 2. The two code panes, side by side: the CSS, and the bash that builds it ─
            ft-div name=panes display=flex gap=3 alignItems=start justifyContent=center
                _code_panel css  "The CSS"                  "$CSS"
                _code_panel bash "The bash — how it's built" "$BASH"
            end_ft_div

            # ── 3. The STAGE — a roomy borderless frame (fills its bg, so a step change can
            #       repaint it to wipe the old callout). Content is centred, leaving margins
            #       above and below for the callouts to point into without covering anything. ─
            ft-frame name=lower border=false alignSelf=stretch display=flex flexDirection=column gap=1 \
                     alignItems=center justifyContent=center height=15
            case "$PAGE" in
            1)  ft-div name=inhbox color="$INH_COLOR" display=flex flexDirection=column gap=0 alignItems=center
                    ft-textfield name=spec value="$SPEC" size=44 rows=2 wrap=true
                    ft-label name=inhNote text="↑ this label inherits the same crimson"
                end_ft_div
                ft-div name=ctl1 display=flex gap=4 alignItems=center
                    ft-div name=grp381 display=flex gap=1 alignItems=center
                        ft-label text="Parent colour:"
                        ft-select name=inhColor size=1 onChange=inhColor_on_change
                            ft-option value=crimson text="Crimson"
                            ft-option value=dodgerblue text="Blue"
                            ft-option value=46 text="Green"
                            ft-option value=gold text="Gold"
                        end_ft_select
                    end_ft_div
                    # accessKey=O, not B: the app-level '[Bb]' cap below (Back ← page) is
                    # registered last and wins the form keymap outright, so a B here would
                    # underline a letter that pages backwards instead of ticking the box.
                    # ft_accesskey_conflicts catches exactly this.
                    ft-checkbox name=inhBold text="Bold" accessKey=O onActivate=inhBold_on_activate onDeactivate=inhBold_on_deactivate
                end_ft_div ;;
            2)  ft-textfield name=spec value="$SPEC" size=44 rows=2 wrap=true class="${SEL_CLASS/none/}"
                ft-div name=ctl2 display=flex gap=1 alignItems=center
                    ft-label "#spec class ="
                    ft-select name=selClass size=1 onChange=selClass_on_change
                        ft-option value=none text="(none)"
                        ft-option value=warning text=".warning"
                        ft-option value=ok text=".ok"
                    end_ft_select
                end_ft_div ;;
            3)  ft-textfield name=spec value="$SPEC" size=44 rows=2 wrap=true class=hot
                ft-div name=ctl3 display=flex gap=2 alignItems=center
                    ft-label text="Rules on:"
                    ft-checkbox name=spType text="textfield" accessKey=T checked=true onActivate=spType_on_activate onDeactivate=spType_on_deactivate
                    ft-checkbox name=spClass text=".hot" accessKey=C onActivate=spClass_on_activate onDeactivate=spClass_on_deactivate
                    ft-checkbox name=spId text="#spec" accessKey=I onActivate=spId_on_activate onDeactivate=spId_on_deactivate
                end_ft_div ;;
            4)  ft-textfield name=spec value="$SPEC" size=44 rows=2 wrap=true
                ft-div name=ctl4 display=flex gap=2 alignItems=center
                    ft-checkbox name=stDisabled text="Disable the box" accessKey=D onActivate=stDisabled_on_activate onDeactivate=stDisabled_on_deactivate
                    ft-label color=muted "· Tab = :focus · Enter = :editing"
                end_ft_div ;;
            5)  ft-textfield name=spec value="$SPEC" size=44 rows=2 wrap=true --accent="$VAR_ACCENT"
                ft-div name=ctl5 display=flex gap=1 alignItems=center
                    ft-label "--accent ="
                    ft-select name=varPick size=1 onChange=varPick_on_change
                        ft-option value=crimson text="crimson"
                        ft-option value=dodgerblue text="dodgerblue"
                        ft-option value=46 text="green"
                        ft-option value=201 text="magenta"
                    end_ft_select
                end_ft_div ;;
            6)  ft-textfield name=spec value="$SPEC" size=44 rows=2 wrap=true color="$CF_FMT"
                ft-div name=ctl6 display=flex gap=1 alignItems=center
                    ft-label text="color:"
                    ft-select name=cfFmt size=1 onChange=cfFmt_on_change
                        ft-option value=crimson text="crimson (name)"
                        ft-option value=#dc143c text="#dc143c (hex)"
                        ft-option value="rgb(220,20,60)" text="rgb(220,20,60)"
                        ft-option value="hsl(348,83%,47%)" text="hsl(348,83%,47%)"
                    end_ft_select
                end_ft_div ;;
            7)  ft-textfield name=spec value="$SPEC" size=44 rows=2 wrap=true class="pe-$STRUCT" placeholder="#spec is empty — so you see its ::placeholder"
                ft-div name=ctl7 display=flex gap=1 alignItems=center
                    ft-label text="Pseudo-element:"
                    ft-select name=structPick size=1 onChange=structPick_on_change
                        ft-option value=border text="::border"
                        ft-option value=selection text="::selection"
                        ft-option value=scrollbar text="::scrollbar"
                        ft-option value=caret text="::caret"
                        ft-option value=placeholder text="::placeholder"
                    end_ft_select
                end_ft_div ;;
            8)  ft-textfield name=spec value="$SPEC" size=44 rows=2 wrap=true animation="$AN_NAME ${AN_DUR}s"
                ft-div name=ctl8 display=flex gap=4 alignItems=center
                    ft-div name=grp446 display=flex gap=1 alignItems=center
                        ft-label text="animation:"
                        ft-select name=animPick size=1 onChange=animPick_on_change
                            ft-option value=none text="none"
                            ft-option value=glow text="glow"
                            ft-option value=alarm text="alarm"
                        end_ft_select
                    end_ft_div
                    ft-div name=grp455 display=flex gap=1 alignItems=center
                        ft-label text="duration:"
                        ft-slider name=animDur min=1 max=8 value="$AN_DUR" step=1 width=14 variant=fill showValue=true onChange=animDur_on_change
                        ft-label color=muted text="s"
                    end_ft_div
                end_ft_div ;;
            9)  ft-div name=combox display=flex flexDirection=column gap=0 alignItems=center
                    ft-textfield name=spec value="$SPEC" size=44 rows=1 wrap=true
                end_ft_div
                ft-textfield name=specOut value="$SPEC" size=44 rows=1 wrap=true
                ft-div name=ctl9 display=flex gap=1 alignItems=center
                    ft-checkbox name=cbNest text="Wrap the first box in a .spotlight" accessKey=C onActivate=cbNest_on_activate onDeactivate=cbNest_on_deactivate
                end_ft_div ;;
            10) ft-textfield name=spec value="$SPEC" size=44 rows=2 wrap=true
                ft-div name=ctl10 display=flex gap=1 alignItems=center
                    ft-label text="Theme:"
                    local _ti=0; case "$THEME_SEL" in dark) _ti=0 ;; light) _ti=1 ;; ocean) _ti=2 ;; esac
                    ft-select name=themePick size=1 selectedIndex="$_ti" onChange=themePick_on_change
                        ft-option value=dark text="Dark"
                        ft-option value=light text="Light"
                        ft-option value=ocean text="Ocean"
                    end_ft_select
                end_ft_div ;;
            esac
            end_ft_frame

            # ── STEP through THIS page's lesson (◀ ▶); the bottom buttons move PAGES ──
            ft-div name=stepnav display=flex gap=2 alignItems=center justifyContent=center
                ft-button name=btnStepPrev text="◀" onActivate=btnStepPrev_on_activate
                ft-label name=stepcount color=accent text=" Step $STEP of $nsteps "
                ft-button name=btnStepNext text="▶" onActivate=btnStepNext_on_activate
            end_ft_div

            # PAGE navigation lives at the very bottom (orthogonal to the ◀▶ step arrows).
            ft-div name=btnrow display=flex gap=2 justifyContent=center
                ft-button name=btnBack text="Back" accessKey=B onActivate=btnBack_on_activate
                ft-button name=btnOk text="$oktext" accessKey=K onActivate=btnOk_on_activate
                ft-button name=btnQuit text="Quit" accessKey=Q onActivate=btnQuit_on_activate
            end_ft_div

            _place_callout    # the CURRENT step's numbered pop-up instruction, pointing at its control
            _place_ghost      # the step-2 dashed outline of the borderless #inhbox container
            [[ "$PAGE" == 7 ]] && _setup_struct_state   # put #spec in the state that shows the pseudo-element
        end_ft_frame
    end_ft_div

    (( PAGE == 1 ))       && ft_set btnBack     disabled=true    # first page → no previous page
    (( STEP == 1 ))       && ft_set btnStepPrev disabled=true    # first step → no previous step
    (( STEP == nsteps ))  && ft_set btnStepNext disabled=true    # last step → nothing more to step to
    [[ "$PAGE" == 4 && "$ST_DISABLED" == on ]] && ft_set spec disabled=true
    # #spec carries the line indicators on every page — ↩ where a long line soft-wraps,
    # ¶ where a hard newline ends one — toggled live with w / n.
    ft_set spec wrapIndicator="$SHOW_WRAP" newlineIndicator="$SHOW_NL"
    # The status bar shows the PAGE (set once here); the frame's "Step S of N" is the live
    # per-step indicator, so stepping needn't retouch the bar (which would re-trigger its sweep).
    ft_set navbar status="Page $PAGE of $LAST — $title    ·    ◀ ▶ step through · Okay / Back = page · Q quit"
    # App-level legend caps, registered LAST so the buttons' accessKey= rebinds can't clobber
    # our LABELLED versions (same keymap → last wins). STEP arrows on < > (IMPORTANT, so they
    # rank BELOW a control's own crucial mode keys like Esc/Enter, but still lead the globals);
    # PAGE nav on K (Okay) / B (Back).
    # BACKWARD BEFORE FORWARD. The legend sorts by importance and is STABLE, so equal-weight
    # caps appear in declaration order — declaring Next first put "▶ Next step" to the LEFT of
    # "◀ Prev step", which reads backwards against the very buttons it describes.
    ft_set app \
        key='<' keyCap="Prev step" keyImp=important onKey=btnStepPrev_on_activate \
        key='>' keyCap="Next step" keyImp=important onKey=btnStepNext_on_activate \
        key='[Bb]' keyCap="Back ← page" keyImp=normal onKey=btnBack_on_activate \
        key='[Kk]' keyCap="Okay → next page" keyImp=normal onKey=btnOk_on_activate \
        key='[Ww]' keyCap="↩ wrap marks" keyImp=normal onKey=_toggle_wrap \
        key='[Nn]' keyCap="¶ newline marks" keyImp=normal onKey=_toggle_nl \
        key='[Qq]' keyCap="Quit" keyImp=40 onKey=ft_quit
    ft_refresh
    ft_focus css || ft_focus_first
}

# ── Navigation — TWO orthogonal axes ─────────────────────────────────────────
# ◀ ▶ (btnStepPrev/Next) walk the teaching STEPS within the current page; Okay/Back
# (btnOk/btnBack) move between PAGES (each page starts fresh at step 1).
# Stepping does a CHEAP in-place update (_goto_step), NOT a full page rebuild — that is
# what keeps the arrows snappy (a rebuild+relayout of this page is ~230ms in pure bash).
btnStepNext_on_activate() { _page_annotations; (( STEP < ${#PA_TARGET[@]} )) && { (( STEP++ )); _goto_step; }; }
btnStepPrev_on_activate() { (( STEP > 1 )) && { (( STEP-- )); _goto_step; }; }
btnOk_on_activate()   { if (( PAGE < LAST )); then (( PAGE++ )); STEP=1; ft_invalidate; else ft_quit; fi; }
btnBack_on_activate() { (( PAGE > 1 )) && { (( PAGE-- )); STEP=1; ft_invalidate; }; }
btnQuit_on_activate() { ft_quit; }
# Live toggles for #spec's line indicators (shown off on every page). ft_set
# reflows+dirties #spec, so the loop's post-burst ft_redraw_dirty repaints it — no
# ft_refresh (a full-app redraw that defers to FT_DEFER_ROOT and paints a frame late).
_toggle_wrap() { [[ "$SHOW_WRAP" == true ]] && SHOW_WRAP=false || SHOW_WRAP=true; ft_set spec wrapIndicator="$SHOW_WRAP"; }
_toggle_nl()   { [[ "$SHOW_NL"   == true ]] && SHOW_NL=false   || SHOW_NL=true;   ft_set spec newlineIndicator="$SHOW_NL"; }

_resize() { ft_set app width="$FT_COLS" height="$FT_ROWS"; _show_page; }

# ── App scaffold ──────────────────────────────────────────────────────────────
ft-form name=app width="$FT_COLS" height="$FT_ROWS" \
        display=flex flexDirection=column \
        key='[Qq]' onKey=ft_quit
    ft-div name=stage flexGrow=1 flexShrink=1 minHeight=0 overflow=hidden \
             display=flex justifyContent=center alignItems=center
    end_ft_div
    ft-keylegend name=navlegend flexShrink=0 keys=auto
    ft-statusbar name=navbar     flexShrink=0 status="Loading…"
end_ft_form
# The nav-key legend caps are (re)registered at the END of _show_page — see there
# for why they can't live out here (the buttons' accessKey= would clobber them).

ft_run app _show_page _resize '' _show_page
