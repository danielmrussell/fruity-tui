#!/usr/bin/env bash
# Unit tests for keymap-centric event dispatch: the focused-leaf→root cascade
# over per-control keymap chains (instance overlay → shared keymap=NAME ref →
# prototype default), a focused scrollbar shadowing the form's arrows, actions
# with arguments, ft_activate + <name>_on_activate, accessKey= sugar (auto form
# binding + ft_remove cleanup), and drop defaults.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
# The form's Esc now opens the command menu, falling back to ft_quit when the menu
# module isn't present. These dispatch tests probe the "Esc reaches the form keymap"
# path via that quit fallback, so drop the menu here.
unset -f ft_command_menu 2>/dev/null || true

HIT=""
_hit() { HIT="$1:$2:$3"; }       # generic action: records its own args + name + token
_hitplain() { HIT="plain:$1:$2"; }

note "cascade: an unclaimed key bubbles from the focused control to the form"
ft-form name=app width=40 height=10
    ft-div name=mid
        ft-button name=btn text=" Go " onActivate=btn_on_activate
    end_ft_div
end_ft_form
FT_ROOT=app
QUITS=0; ft_quit() { (( QUITS++ )); FT_RUN_ACTIVE=0; return 0; }   # count instead of exiting
check "focus starts on the button" "$FT_FOCUS" "btn"
ft_dispatch_event TAB
check "TAB reached the form's class keymap (focus moved)" "$FT_FOCUS" "btn"   # single entry: wraps to itself
ft_dispatch_event ESC
check "ESC reached the form's class keymap (handled, a no-op boundary)" "$?" "0"
check "ESC no longer quits or opens a menu" "$QUITS" "0"

note "ENTER activates the focused button via its class keymap"
ACT=""
btn_on_activate() { ACT=yes; }
ft_dispatch_event ENTER
check "on_activate hook ran" "$ACT" "yes"

note "instance overlay beats shared ref beats class default"
ft-keymap sharedNav
ft-bindkeys sharedNav ENTER='_hit ref'
ft-form name=app2 width=40 height=10
    ft-button name=b2 text=" B " keymap=sharedNav keymap ENTER='_hit overlay'
    ft-button name=b3 text=" C " keymap=sharedNav
    ft-button name=b4 text=" D " onActivate=b4_on_activate
end_ft_form
FT_ROOT=app2
ft_focus b2; HIT=""
ft_dispatch_event ENTER
check "overlay wins on b2"        "$HIT" "overlay:b2:ENTER"
ft_focus b3; HIT=""
ft_dispatch_event ENTER
check "shared ref wins on b3"     "$HIT" "ref:b3:ENTER"
ft_focus b4; ACT2=""
b4_on_activate() { ACT2=yes; }
ft_dispatch_event ENTER
check "class default remains for b4" "$ACT2" "yes"

note "editing the SHARED keymap changes every control attached by reference"
ft-keymap-set sharedNav ENTER '_hitplain'
ft_focus b3; HIT=""
ft_dispatch_event ENTER
check "b3 sees the updated shared binding" "$HIT" "plain:b3:ENTER"

note "a focused scrollbar shadows the form's arrow keys"
ft-form name=app3 width=40 height=10
    ft-scrollbar name=sb width=1 height=5 scrollHeight=20 onScroll=sb_on_scroll
    ft-button name=ok3 text=" OK "
end_ft_form
ft_layout app3          # the bar's track (and so its default clientHeight) needs real geometry
FT_ROOT=app3
ft_focus sb
ft_dispatch_event DOWN
_ft_get_raw sb scrollTop
check "DOWN scrolled (not focus-moved)" "$FT_RET" "1"
check "focus stayed on the scrollbar"   "$FT_FOCUS" "sb"
ft_focus ok3
ft_dispatch_event DOWN
check "with a button focused, DOWN bubbles to the form = focus move" "$FT_FOCUS" "sb"

note "on_scroll fires with the new offset"
SCROLLED=""
sb_on_scroll() { SCROLLED=$1; }   # $this=sb, $1=new offset
ft_focus sb
ft_dispatch_event PGDN
check "page-down scrolled by clientHeight" "$SCROLLED" "6"

note "accessKey= sugar: an auto [Xx] binding on the ENCLOSING FORM"
ft-form name=app4 width=40 height=10
    ft-button name=bGrow text=" Grow " accessKey=G onActivate=bGrow_on_activate
    ft-button name=bOther text=" Other "
end_ft_form
FT_ROOT=app4
GACT=""
bGrow_on_activate() { GACT=$this; }     # $this is the control that fired the hook
ft_focus bOther                     # accessKey works regardless of focus
ft_dispatch_event g
check "lowercase accessKey activates the named button" "$GACT" "bGrow"
GACT=""
ft_dispatch_event G
check "uppercase too" "$GACT" "bGrow"

note "ft_remove unregisters a control's accessKey binding"
ft_remove bGrow
GACT=""
ft_dispatch_event g || true
check "destroyed accessKey no longer fires" "$GACT" ""

note "a drop default swallows keys instead of bubbling"
ft-form name=app5 width=40 height=10
    ft-button name=b5 text=" B " keymap default=drop
end_ft_form
FT_ROOT=app5
QUITS=0
ft_focus b5
ft_dispatch_event ESC
check "ESC swallowed before the form could quit" "$QUITS" "0"

note "\$this is per-hook and unwinds across NESTED hooks (no reentrancy hazard)"
ft-form name=app6 width=40 height=8
    ft-button name=outer text=Outer onActivate=outer_on_activate
    ft-button name=inner text=Inner onActivate=inner_on_activate
end_ft_form
FT_ROOT=app6
TB=""; TA=""; TI=""
inner_on_activate() { TI=$this; }
outer_on_activate() { TB=$this; ft_activate inner; TA=$this; }   # nest a hook mid-hook
this=""
ft_activate outer
check "outer hook sees \$this=outer"                  "$TB" "outer"
check "nested inner hook sees \$this=inner"           "$TI" "inner"
check "\$this restored to outer after inner returns"  "$TA" "outer"
check "\$this cleared to empty back at top level"     "$this" ""

# ─────────────────────────────────────────────────────────────────────────────
note "a binding's ACTION reaches a command position — so what may be in it"
# Both dispatch paths used to expand the stored action and invoke it directly, and both
# had the same four faults. A keymap is authored data; none of it should be able to run
# something the author did not write.
ft_remove ka 2>/dev/null
KA_OUTER=0; KA_INNER=0
ka_outer() { KA_OUTER=1; }
ka_inner() { KA_INNER=1; }
ka_args()  { KA_ARGS="$*"; }
ft-keymap ka_outer_map; ft-keymap-set ka_outer_map X ka_outer
_ka_build() {                   # innermap
    ft_remove ka 2>/dev/null
    KA_OUTER=0; KA_INNER=0; KA_ARGS=""
    ft-form name=ka width=40 height=8
        ft-div name=kadiv keymap=ka_outer_map
            ft-button name=kabtn "Go" keymap="$1"
        end_ft_div
    end_ft_form
    ft_layout ka; FT_ROOT=ka; ft_focus kabtn
}
_ka_err() {                     # → FT_RET: whatever dispatch wrote to stderr
    local f=$XDG_STATE_HOME/ka.err
    ft_dispatch_event X 2>"$f" >/dev/null
    FT_RET=$(<"$f")
}

note "…the reserved words the keymap docs promise"
# "An ACTION is a function name, or the reserved words bubble / drop." Neither was
# implemented: `bubble` announced "bubble: command not found" on the alt screen and then
# SWALLOWED the key — the exact opposite of what it says on the tin.
ft-keymap ka_bub; ft-keymap-set ka_bub X bubble
_ka_build ka_bub; _ka_err
check "bubble declines, so the ancestor gets the key" "$KA_OUTER" "1"
check "…in silence"                                   "${FT_RET:-clean}" "clean"
ft-keymap ka_drop; ft-keymap-set ka_drop X drop
_ka_build ka_drop; _ka_err
check "drop swallows it here"                         "$KA_OUTER" "0"
check "…in silence"                                   "${FT_RET:-clean}" "clean"

note "…an action naming a function that is not there"
ft-keymap ka_gone; ft-keymap-set ka_gone X ka_no_such_function
_ka_build ka_gone; _ka_err
check "nothing is announced on the screen the user is looking at" "${FT_RET:-clean}" "clean"
check "and the key is NOT claimed — it bubbles to something that works" "$KA_OUTER" "1"
ft_unresolved_actions
check "…but it IS recorded, so a test can see it" \
      "$(case "$FT_RET" in *"kabtn ka_no_such_function"*) echo yes ;; *) echo "${FT_RET:-empty}" ;; esac)" "yes"
n1=${#FT_UNRESOLVED_ACTIONS[@]}
_ka_build ka_gone; _ka_err; _ka_build ka_gone; _ka_err
check "…once, not once per keypress" "${#FT_UNRESOLVED_ACTIONS[@]}" "$n1"

note "…an EMPTY action, which used to run the CONTROL'S OWN NAME"
# `ft-keymap-set map X` with the action left off stored nothing, and the invocation
# `"${words[@]}" "$name" "$tok"` then had the control name in the command position. Names
# are identifiers, so a control called `rm` or `clear` ran rm or clear.
no "ft-keymap-set refuses a binding with no action" ft-keymap-set ka_empty_map X
ft-keymap ka_empty
_ft_keymap_put ka_empty X $'X\t'          # …and forced past that, dispatch still refuses
_ka_build ka_empty; _ka_err
check "an empty action runs nothing"      "${FT_RET:-clean}" "clean"
check "…and does not claim the key"       "$KA_OUTER" "1"
# The dangerous shape, end to end: a control whose NAME is a real command.
ft_remove kb 2>/dev/null
ft-keymap ka_empty2; _ft_keymap_put ka_empty2 X $'X\t'
ft-form name=kb width=40 height=8
    ft-button name=touch "Go" keymap=ka_empty2
end_ft_form
ft_layout kb; FT_ROOT=kb; ft_focus touch
marker=$XDG_STATE_HOME/ka-name-ran
rm -f "$marker" X
( cd "$XDG_STATE_HOME" && ft_dispatch_event X >/dev/null 2>&1 )
check "a control named after a real command does not run it" \
      "$([[ -e "$XDG_STATE_HOME/X" ]] && echo RAN || echo no)" "no"

note "…and a GLOB, which was expanded against the current directory"
ft-keymap ka_glob; ft-keymap-set ka_glob X 'ka_args *'
_ka_build ka_glob
mkdir -p "$XDG_STATE_HOME/globdir"; : > "$XDG_STATE_HOME/globdir/aaa"; : > "$XDG_STATE_HOME/globdir/bbb"
( cd "$XDG_STATE_HOME/globdir" && ft_dispatch_event X >/dev/null 2>&1 )
# Same directory, run again inside the test's own process so KA_ARGS survives.
pushd "$XDG_STATE_HOME/globdir" >/dev/null
ft_dispatch_event X >/dev/null 2>&1
popd >/dev/null
check "the argument stays an asterisk, not the directory listing" "$KA_ARGS" "* kabtn X"

note "…while ft-bindkeys catches the typo that made an empty action in the first place"
err=$( ft-bindkeys ka_bk X 2>&1 )
check "a pair with no = is reported" \
      "$(case "$err" in *"not PATTERN=ACTION"*) echo yes ;; *) echo "${err:-silent}" ;; esac)" "yes"

note "the back-compat single-control path resolves actions the SAME way"
# It had every one of these faults too, in its own copy of the invocation.
_ka_build ka_bub
no "ft_dispatch_keymap: bubble declines"    ft_dispatch_keymap kabtn X
_ka_build ka_drop
ok "ft_dispatch_keymap: drop claims"        ft_dispatch_keymap kabtn X
_ka_build ka_gone
f=$XDG_STATE_HOME/ka2.err
ft_dispatch_keymap kabtn X 2>"$f" >/dev/null
check "ft_dispatch_keymap: an absent function is silent" "$(<"$f")" ""

note "a LISTENER is still resolved the way it always was (the path this borrowed from)"
LIS=0
ka_listener() { LIS=1; }
ft_remove kl 2>/dev/null
ft-form name=kl width=40 height=8
    ft-button name=klb "Go" onActivate=ka_listener
end_ft_form
ft_layout kl; FT_ROOT=kl; ft_focus klb
ft_activate klb
check "a real handler fires" "$LIS" "1"
ft_remove kl2 2>/dev/null
ft-form name=kl2 width=40 height=8
    ft-button name=klb2 "Go" onActivate="touch $XDG_STATE_HOME/listener-ran"
end_ft_form
ft_layout kl2; FT_ROOT=kl2
rm -f "$XDG_STATE_HOME/listener-ran"
f=$XDG_STATE_HOME/ka3.err
ft_activate klb2 2>"$f" >/dev/null
check "a listener naming a COMMAND runs nothing" \
      "$([[ -e "$XDG_STATE_HOME/listener-ran" ]] && echo RAN || echo no)" "no"
check "…and says nothing on screen" "$(<"$f")" ""

note "LEAVING a control ends its activation — for every class, not just ones that opted in"
# Runlevel decides what the arrows MEAN: at rest they move between controls, activated they
# belong to the control. _ft_focus_blur only ever called an optional _ft_blur_<type> hook and
# no prototype defined one, so activation survived Tabbing away: come back to a slider and the
# arrows still dragged it, come back to a field and you were still mid-edit — with nothing on
# screen saying so. The reset is the ENGINE's now, and because runlevel is an ordinary
# property it fires each prototype's runlevel-exit script for free.
ft-form name=blurapp width=60 height=14 display=flex flexDirection=column
    ft-slider    name=blSlider min=0 max=100 value=40
    ft-textfield name=blField  value="hello"
    ft-select    name=blSelect
        ft-option value=a "Alpha"
        ft-option value=b "Beta"
    end_ft_select
end_ft_form
FT_ROOT=blurapp; ft_layout blurapp
_rl() { ft_get "$1" runlevel; printf '%s' "${FT_RET:-unfocused}"; }   # no rung set = at rest
for _c in blSlider blField blSelect; do
    _away=blField; [[ "$_c" == blField ]] && _away=blSlider   # must be a DIFFERENT control
    ft_focus "$_c"; ft_dispatch_event ENTER >/dev/null 2>&1
    check "$_c activates on Enter" "$([[ "$(_rl "$_c")" != unfocused ]] && echo yes)" yes
    ft_focus "$_away"
    check "…and is back at rest once focus leaves" "$(_rl "$_c")" unfocused
done

summary
