#!/usr/bin/env bash
# Tests for ft-css.bash: the CSS cascade engine — parsing (comments, selector lists,
# compound selectors, specificity, declarations), selector matching (type / #id /
# .class / :focus / :disabled / :root / descendant), and the 5-level resolver
# (inline > app sheets > inheritance > default sheet > class default) with custom
# properties + var(). M1 is invisible: this exercises the engine directly.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null

# ── Parsing ──────────────────────────────────────────────────────────────────
note "kebab-case and camelCase are the same property; custom properties pass through"
_ft_css_camel background-color; check "kebab→camel" "$FT_RET" "backgroundColor"
_ft_css_camel color;            check "plain stays"  "$FT_RET" "color"
_ft_css_camel --crucial-text;   check "custom property kept verbatim" "$FT_RET" "--crucial-text"

note "comments are stripped non-greedily (not first-/* to last-*/)"
_ft_css_strip_comments 'a /* one */ b /* two */ c'; check "two comments, text between kept" "$FT_RET" "a  b  c"

note "a compound selector splits into type / #id / .class / :pseudo / ::element"
_ft_css_compound 'textfield#user.primary.big:focus:disabled::selection'
check "type"            "$_FT_CSS_COMPOUND_TYPE"   "textfield"
check "id"              "$_FT_CSS_COMPOUND_ID"     "user"
check "classes"         "$_FT_CSS_COMPOUND_CLASS"  "primary big"
check "pseudo-classes"  "$_FT_CSS_COMPOUND_PSEUDO_CLASS" "focus disabled"
check "pseudo-element"  "$_FT_CSS_COMPOUND_PSEUDO_ELEMENT"     "selection"
_ft_css_compound '.only'; check "class-only has empty type" "$_FT_CSS_COMPOUND_TYPE" ""; check "...and the class" "$_FT_CSS_COMPOUND_CLASS" "only"

note "specificity is (ids·10000 + classes/pseudo·100 + types/elements)"
_ft_css_specificity 'textfield#user.primary'; check "id+class+type" "$FT_RET" "$((10000+100+1))"
_ft_css_specificity 'button';                 check "type only"     "$FT_RET" "1"
_ft_css_specificity '.a .b';                  check "two classes (descendant)" "$FT_RET" "200"

note "a stylesheet parses into flat rules; a comma list becomes several sharing decls"
ft_stylesheet name=s1 style='
    /* frag */ textfield, button { color: 255; background-color: 234; }
    textfield:focus { border-color: var(--accent); }
    keylegend .crucial { color: var(--crucial-text) }
'
check "flattened rule count"        "${FT_CSS_RULE_COUNT[s1]}"                 "4"
check "comma split: rule0 type"     "${FT_CSS_SELECTOR_TYPE[$'s1\t0']}"       "textfield"
check "comma split: rule1 type"     "${FT_CSS_SELECTOR_TYPE[$'s1\t1']}"       "button"
check "shared, normalised decls"    "${FT_CSS_DECLARATIONS[$'s1\t0']}"        "color:255;backgroundColor:234;"
check "focus pseudo recorded"       "${FT_CSS_SELECTOR_PSEUDO_CLASS[$'s1\t2']}"     "focus"
check "value keeps var() verbatim"  "${FT_CSS_DECLARATIONS[$'s1\t2']}"        "borderColor:var(--accent);"
check "descendant: key is .crucial" "${FT_CSS_SELECTOR_CLASS[$'s1\t3']}"      "crucial"
check "descendant: ancestor keylegend" "${FT_CSS_SELECTOR_ANCESTORS[$'s1\t3']}"      $' \x1fkeylegend\x1f\x1f\x1f\x1f\x1f\x1e'

# ── The cascade ──────────────────────────────────────────────────────────────
# synthetic tree: root(form) > panel > { tf(textfield), lbl(label) }
FT_TYPE[root]=form;    FT_PARENT[root]=""
FT_TYPE[panel]=div;  FT_PARENT[panel]=root
FT_TYPE[tf]=textfield; FT_PARENT[tf]=panel
FT_TYPE[lbl]=label;    FT_PARENT[lbl]=panel
FT_ROOT=root; FT_FOCUS=""

ft_stylesheet name=ua default=true style='
    *         { color: 250; }
    textfield { color: 244; background-color: 232; }
'
ft_stylesheet name=app style='
    :root           { --accent: 39; --danger: 203; color: 255; }
    textfield       { border-color: 250; }
    textfield:focus { border-color: var(--accent); }
    .danger         { color: var(--danger); }
    #special        { color: 111; }
    div textfield { background-color: 234; }
'

note "inheritance (level 3) beats the default sheet (level 4)"
ft_style tf color;            check "tf inherits :root color 255, not default-sheet 244" "$FT_RET" "255"
ft_style lbl color;           check "label inherits :root color too"                     "$FT_RET" "255"

note "non-inherited properties do not fall through to ancestors"
ft_style tf backgroundColor;  check "bg from 'panel textfield' app rule"  "$FT_RET" "234"
ft_style lbl backgroundColor; check "bg does NOT inherit → empty on label" "$FT_RET" ""

note "inline (level 1) beats every stylesheet"
_ft_setprop tf color 200
ft_style tf color;            check "inline wins" "$FT_RET" "200"
ft_remove_attribute tf color

note ":focus rule wins by specificity; var() resolves the custom property"
ft_style tf borderColor;      check "unfocused → textfield rule 250" "$FT_RET" "250"
FT_FOCUS=tf
ft_style tf borderColor;      check "focused → :focus rule var(--accent)=39" "$FT_RET" "39"
FT_FOCUS=""

note "a class rule + a custom property that itself cascades by inheritance"
_ft_setprop tf class danger
ft_style tf color;            check ".danger → var(--danger) inherited from :root = 203" "$FT_RET" "203"
ft_remove_attribute tf class

note "#id specificity (10000) beats a .class (100)"
FT_TYPE[special]=textfield; FT_PARENT[special]=panel
_ft_setprop special class danger
ft_style special color;       check "#special wins over .danger" "$FT_RET" "111"

note "var() fallback is used when the custom property is undefined"
ft_stylesheet name=app2 style='label { color: var(--missing, 99); }'
ft_style lbl color;           check "fallback when --missing unset" "$FT_RET" "99"

note "ft_sgr composes cascaded color + background-color + font-weight into ONE escape"
FT_TYPE[btnx]=button; FT_PARENT[btnx]=root
FT_TYPE[lblx]=label;  FT_PARENT[lblx]=root
ft_stylesheet name=sgr style='
    #btnx { background-color: 244; color: 16; font-weight: bold; }
    #lblx { color: 250; }
'
ft_sgr btnx; check "bg;fg;bold combined"        "$FT_RET" $'\e[48;5;244;38;5;16;1m'
ft_sgr lblx; check "fg only (no bg declared)"   "$FT_RET" $'\e[38;5;250m'

# ── Control integration: stylesheets actually restyle real controls ───────────
# _ft_color_override (used by label/button/frame/radio/…) now resolves through the
# cascade, so a stylesheet retints any of them — additively (unstyled = unchanged).
note "a stylesheet restyles real controls of different types, by type/class/id + :focus"
FT_FOCUS=""; FT_COLS=40; FT_ROWS=12
ft_stylesheet name=widgets style='
    label.warn    { color: 214; }
    label#loud    { color: 203; }
    button.go     { color: 40; }
    textfield:focus { color: 51; }
'
ft-form name=froot width=40 height=12
  ft-label     name=plainL "plain"
  ft-label     name=warnL  class=warn "warned"
  ft-label     name=loud   class=warn "loud"
  ft-label     name=inlL   class=warn color=45 "inline"
  ft-button    name=goB    class=go "Go"
  ft-textfield name=fld    value="hi"
end_ft_form
ft_layout froot
_vis2() { printf '%s' "$1"; }
_draw() { FT_OUT=""; ft_draw_one "$1"; printf '%s' "$FT_OUT"; }

o=$(_draw plainL); case "$o" in *"48;5;234;38;5;255"*) check "plain label unchanged (body colour)" 1 1 ;; *) check "plain label unchanged (body colour)" 0 1 ;; esac
o=$(_draw warnL);  case "$o" in *"38;5;214"*) check "label.warn retinted 214" 1 1 ;; *) check "label.warn retinted 214" 0 1 ;; esac
o=$(_draw loud);   case "$o" in *"38;5;203"*) check "label#loud id beats .warn (203)" 1 1 ;; *) check "label#loud id beats .warn (203)" 0 1 ;; esac
o=$(_draw loud);   case "$o" in *"38;5;214"*) check "...and .warn colour is gone" 0 1 ;; *) check "...and .warn colour is gone" 1 1 ;; esac
o=$(_draw inlL);   case "$o" in *"38;5;45"*)  check "inline color=45 beats .warn" 1 1 ;; *) check "inline color=45 beats .warn" 0 1 ;; esac
o=$(_draw goB);    case "$o" in *"38;5;40"*)  check "button.go retinted 40 (different control type)" 1 1 ;; *) check "button.go retinted 40 (different control type)" 0 1 ;; esac
FT_FOCUS=fld; o=$(_draw fld); case "$o" in *"38;5;51"*) check "textfield:focus rule applies while focused" 1 1 ;; *) check "textfield:focus rule applies while focused" 0 1 ;; esac
FT_FOCUS=""

# ── Structures: the textfield border and pseudo-elements ─────────────────────
note "a textfield's BORDER (a state-driven structure) now honours the cascade"
ft_stylesheet name=borders style='
    textfield:focus { border-color: 51; }
    textfield.edged { border-color: 208; }
'
ft-form name=broot width=40 height=10 keymap x=x
  ft-textfield name=ba size=14 value="a"
  ft-textfield name=bb size=14 value="b" class=edged
end_ft_form
ft_layout broot
FT_FOCUS=bb
o=$(_draw ba); case "$o" in *"38;5;250"*) check "unfocused, unstyled border = theme 250" 1 1 ;; *) check "unfocused, unstyled border = theme 250" 0 1 ;; esac
o=$(_draw ba); case "$o" in *"38;5;51"*)  check "...and no :focus colour leaks to it" 0 1 ;; *) check "...and no :focus colour leaks to it" 1 1 ;; esac
o=$(_draw bb); case "$o" in *"38;5;208"*) check "textfield.edged → border 208 (unfocused)" 1 1 ;; *) check "textfield.edged → border 208 (unfocused)" 0 1 ;; esac
FT_FOCUS=ba
o=$(_draw ba); case "$o" in *"38;5;51"*)  check "textfield:focus → border 51 overrides the edit-state colour" 1 1 ;; *) check "textfield:focus → border 51 overrides the edit-state colour" 0 1 ;; esac
FT_FOCUS=""

note "pseudo-elements style STRUCTURES; element queries never see them"
ft_stylesheet name=pe style='
    textfield::scrollbar     { color: 201; }
    textfield.hot::scrollbar { color: 46; }
    textfield::selection     { background-color: 33; }
'
FT_TYPE[pex]=textfield; FT_PARENT[pex]=broot   # a parent, so :root doesn't match it
_ft_css_color_pe pex scrollbar color 38;        check "::scrollbar color → 201" "$FT_RET" $'\e[38;5;201m'
_ft_css_color_pe pex selection backgroundColor 48; check "::selection bg → 33" "$FT_RET" $'\e[48;5;33m'
_ft_setprop pex class hot
_ft_css_color_pe pex scrollbar color 38;        check ".hot::scrollbar (more specific) → 46" "$FT_RET" $'\e[38;5;46m'
ft_remove_attribute pex class
# isolation: on a unique element whose ONLY color declaration is inside ::scrollbar, an
# element `color` query must find nothing (pseudo-element rules never answer for the box)
FT_TYPE[iso]=widget99; FT_PARENT[iso]=broot
ft_stylesheet name=isosheet style='widget99::scrollbar { color: 199; }'
_ft_css_query iso color app;                    check "element query ignores the ::scrollbar rule" "$_QGOT" "0"
_ft_css_color_pe iso scrollbar color 38;        check "...but the pseudo-element query resolves it" "$FT_RET" $'\e[38;5;199m'
# a real scrolling field paints its thumb in the ::scrollbar colour
ft-form name=sroot width=40 height=12 keymap x=x
  ft-textfield name=sf value=$'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8' rows=4 size=16
end_ft_form
ft_layout sroot; ft_focus sf
o=$(_draw sf); case "$o" in *"38;5;201"*) check "the scrolling thumb wears ::scrollbar 201" 1 1 ;; *) check "the scrolling thumb wears ::scrollbar 201" 0 1 ;; esac

note "ft_sgr_pseudo_element composes a structure's bg+fg(+weight) — enough to reproduce theme defaults"
FT_TYPE[pz]=field2; FT_PARENT[pz]=broot
ft_stylesheet name=pe2 style='
    field2::selection { background-color: 22; color: 255; }
    field2::caret     { background-color: 220; color: 16; font-weight: bold; }
'
ft_sgr_pseudo_element pz selection; check "::selection → bg;fg"             "$FT_RET" $'\e[48;5;22;38;5;255m'
ft_sgr_pseudo_element pz caret;     check "::caret → bg;fg;bold"            "$FT_RET" $'\e[48;5;220;38;5;16;1m'
ft_sgr_pseudo_element pz border;    check "a structure with no rule → empty" "$FT_RET" ""

note "CSS-declarable animation: a @keyframes cycles a control's fg; armed/disarmed via the cascade"
ft_stylesheet name=animtest style='
  @keyframes acbcycle { from, to { color: 196; } 50% { color: 124; } }
  checkbox { color: 196; animation: acbcycle; }
'
ft-form name=af width=30 height=4; ft-checkbox name=acb "x"; end_ft_form
FT_FOCUS=""; FT_COLOR_MODE=256   # isolate from :focus leftovers; deterministic 256-index colours
ft_style acb animation; check "the cascade carries 'animation'" "$FT_RET" "acbcycle"
unset "FT_ANIM_PHASE[acb]" "FT_CSS_ANIMATION_ON[acb]" 2>/dev/null
_ft_color_override acb color 38; check "arms + returns the phase-0 stop (196)" "$FT_RET" $'\e[38;5;196m'
[[ -n "${FT_CSS_ANIMATION_ON[acb]:-}" ]] && check "the per-control loop is armed" 1 1 || check "the per-control loop is armed" 0 1
FT_ANIM_PHASE[acb]=6; _ft_color_override acb color 38; check "a later phase glided off 196" "$([[ "$FT_RET" != $'\e[38;5;196m' ]] && echo yes)" yes
ft_stylesheet name=animtest style='checkbox { color: 196; }'   # edit the CSS: turn animation OFF
_ft_color_override acb color 38; check "removing it → static colour again (196)" "$FT_RET" $'\e[38;5;196m'
[[ -z "${FT_CSS_ANIMATION_ON[acb]:-}" ]] && check "…and the loop is disarmed" 1 1 || check "…and the loop is disarmed" 0 1

note "the resolver is MEMOISED and invalidates on stylesheet edit / prop change / focus move"
FT_TYPE[memo]=button; FT_PARENT[memo]=""; FT_FOCUS=""
ft_stylesheet name=memosheet style='#memo { color: 100; }'
ft_style memo color; check "first resolve"          "$FT_RET" 100
ft_style memo color; check "cached resolve (same)"   "$FT_RET" 100
ft_stylesheet name=memosheet style='#memo { color: 200; }'
ft_style memo color; check "a stylesheet edit invalidates the cache" "$FT_RET" 200
_ft_setprop memo color 111    # an inline prop change bumps the epoch
ft_style memo color; check "an inline prop wins after its change"     "$FT_RET" 111
ft_remove_attribute memo color
ft_stylesheet name=memosheet style='#memo { color: 100; } #memo:focus { color: 55; }'
FT_FOCUS="";    ft_style memo color; check "unfocused → base 100"           "$FT_RET" 100
FT_FOCUS=memo;  ft_style memo color; check "focus change invalidates (:focus 55 wins)" "$FT_RET" 55
FT_FOCUS=""

note "a cascade-IRRELEVANT prop change (a textfield's value) does NOT invalidate — typing stays fast"
FT_TYPE[tv]=textfield; FT_PARENT[tv]=""
ft_stylesheet name=tvsheet style='#tv { color: 42; }'    # no :checked / [value] anywhere
ft_style tv color >/dev/null; v0=${_FT_CSS_VERSION[tv]:-0}
_ft_setprop tv value "typed some text"
check "setting value did NOT invalidate #tv" "${_FT_CSS_VERSION[tv]:-0}" "$v0"
check "value is not a match-prop here"       "${_FT_CSS_MATCH_PROPS[value]:-no}" no
note "…but once a rule uses :checked, value BECOMES cache-relevant and invalidates — SCOPED to the node"
ft_stylesheet name=chsheet style='checkbox:checked { color: 46; }'
check "value is now a match-prop"            "${_FT_CSS_MATCH_PROPS[value]:-no}" 1
v0=${_FT_CSS_VERSION[tv]:-0}; e0=$_FT_CSS_EPOCH; _ft_setprop tv value "x"
check "setting value NOW invalidates #tv (its version bumps)" "$([[ "${_FT_CSS_VERSION[tv]:-0}" != "$v0" ]] && echo yes)" yes
check "…but the GLOBAL epoch is untouched (scoped, not global)" "$_FT_CSS_EPOCH" "$e0"

note "the compose layer paints font-weight + text-decoration from the cascade (any control)"
FT_TYPE[cl]=label; FT_PARENT[cl]=""; FT_COLOR_MODE=256
ft_stylesheet name=compose style='#cl { color: 202; font-weight: bold; text-decoration: underline; }'
_ft_compose_sgr cl; composed=$FT_RET
case $composed in *$'\e[1m'*)      check "compose includes bold (\\e[1m)"      yes yes ;; *) check "compose includes bold (\\e[1m)"      no yes ;; esac
case $composed in *$'\e[4m'*)      check "compose includes underline (\\e[4m)" yes yes ;; *) check "compose includes underline (\\e[4m)" no yes ;; esac
case $composed in *'38;5;202'*)    check "compose includes the cascaded fg"    yes yes ;; *) check "compose includes the cascaded fg"    no yes ;; esac
ft_stylesheet name=compose style='#cl { color: 202; }'   # no weight → no bold
_ft_compose_sgr cl
case $FT_RET in *$'\e[1m'*) check "plain control is NOT bold" no yes ;; *) check "plain control is NOT bold" yes yes ;; esac

note "@keyframes compiles to an interpolated colour ramp; animation: NAME drives it"
FT_TYPE[kfb]=button; FT_PARENT[kfb]=""; FT_COLOR_MODE=256; FT_FOCUS=""
ft_stylesheet name=kf1 style='
  @keyframes glow { from { color: #ff0000; } 50% { color: #ffff00; } to { color: #ff0000; } }
  #kfb { animation: glow; }
'
kfr=(${FT_CSS_KEYFRAMES[glow]})
check "@keyframes stored a multi-stop ramp"  "$([[ ${#kfr[@]} -gt 3 ]] && echo yes)" yes
check "ramp starts on the first stop (red)"  "${kfr[0]}"                    "255,0,0"
check "ramp loops: last stop == first stop"  "${kfr[$((${#kfr[@]}-1))]}"    "${kfr[0]}"
unset "FT_ANIM_PHASE[kfb]" "FT_CSS_ANIMATION_ON[kfb]" 2>/dev/null
FT_ANIM_PHASE[kfb]=0; _ft_css_anim_fg kfb; check "phase 0 → red 196"       "$FT_RET" $'\e[38;5;196m'
FT_ANIM_PHASE[kfb]=6; _ft_css_anim_fg kfb; check "phase 6 glided off red"  "$([[ "$FT_RET" != $'\e[38;5;196m' ]] && echo yes)" yes
_ft_css_anim_disarm kfb

note "@keyframes animates ARBITRARY properties: color + background-color + font-weight"
FT_TYPE[mkf]=button; FT_PARENT[mkf]=""
ft_stylesheet name=mkfsheet style='
  @keyframes flash { from { color: 16; background-color: 196; font-weight: bold; }
                     to   { color: 231; background-color: 21; font-weight: normal; } }
  #mkf { animation: flash; }
'
check "keyframe built a background-color ramp" "$([[ -n "${FT_CSS_KEYFRAMES_BACKGROUND[flash]}" ]] && echo yes)" yes
check "keyframe built a font-weight ramp"      "$([[ -n "${FT_CSS_KEYFRAMES_WEIGHT[flash]}" ]] && echo yes)" yes
unset "FT_ANIM_PHASE[mkf]" "FT_CSS_ANIMATION_ON[mkf]" 2>/dev/null
_ft_css_anim_fg mkf; check "phase 0 → bg196+fg16+bold (the 'from' stop)"  "$FT_RET" $'\e[48;5;196;38;5;16;1m'
_ft_css_kf_for mkf flash; _ft_css_kf_len; FT_ANIM_PHASE[mkf]=$(( FT_RET - 1 )); _ft_css_anim_fg mkf
check "phase last → bg21+fg231, no bold (the 'to' stop)"                  "$FT_RET" $'\e[48;5;21;38;5;231m'
_ft_css_anim_disarm mkf

note "the built-in animations are REAL @keyframes (pulse/blink), not invented names"
FT_TYPE[kfprobe]=button; FT_PARENT[kfprobe]=""
check "pulse is a defined @keyframes"        "$([[ -n "${FT_CSS_KEYFRAMES_SOURCE[pulse]}" ]] && echo yes)" yes
# pulse's floor is var(--pulse-min) ⇒ it resolves PER-ELEMENT (no shared global ramp)
_ft_css_kf_for kfprobe pulse
check "pulse animates opacity (not a colour)" "$([[ -n "$_KF_OP" && -z "$_KF_FG" ]] && echo yes)" yes
check "blink is a defined @keyframes"        "$([[ -n "${FT_CSS_KEYFRAMES_SOURCE[blink]}" ]] && echo yes)" yes
check "sheen is NOT a @keyframes (a border routine)" "$([[ -z "${FT_CSS_KEYFRAMES_SOURCE[sheen]:-}" ]] && echo yes)" yes

note "@keyframes are THEMEABLE: var() in a stop reads :root custom properties, re-resolved on change"
FT_TYPE[vkf]=button; FT_PARENT[vkf]=""; FT_COLOR_MODE=256
ft_stylesheet name=vksheet style='
  :root { --anim-a: 196; --anim-b: 226; }
  @keyframes themed { from, to { color: var(--anim-a); } 50% { color: var(--anim-b); } }
  #vkf { animation: themed; }
'
_ft_css_kf_for vkf themed
vkr=($_KF_FG)
check "keyframe resolved var(--anim-a)=196 → red"     "${vkr[0]}" "255,0,0"
ft_stylesheet name=vksheet2 style=':root { --anim-a: 21; }'   # a later :root re-colours it
_ft_css_kf_for vkf themed
vkr=($_KF_FG)
check "re-resolves after the custom property changes" "${vkr[0]}" "0,0,255"
# the built-in pulse floor is itself themeable via var(--pulse-min)
ft_stylesheet name=vkpulse style=':root { --pulse-min: 0.2; }'
_ft_css_kf_for vkf pulse; pop=($_KF_OP)
check "var(--pulse-min) re-tunes the pulse floor (0.2 → 20)" "${pop[$(( ${#pop[@]}/2 ))]}" 20

note "var() in @keyframes resolves PER-ELEMENT: an element's own --x beats the inherited :root"
FT_TYPE[pe_a]=button; FT_PARENT[pe_a]=""; FT_TYPE[pe_b]=button; FT_PARENT[pe_b]=""
FT_COLOR_MODE=256
ft_stylesheet name=pesheet style='
  :root  { --spot: 196; }
  @keyframes spotlight { from, to { color: var(--spot); } 50% { color: 15; } }
  #pe_a  { --spot: 21; animation: spotlight; }
  #pe_b  { animation: spotlight; }
'
_ft_css_kf_for pe_a spotlight; a0=($_KF_FG)
_ft_css_kf_for pe_b spotlight; b0=($_KF_FG)
check "#pe_a overrides --spot=21 → its ramp starts blue" "${a0[0]}" "0,0,255"
check "#pe_b inherits :root --spot=196 → red, same keyframe" "${b0[0]}" "255,0,0"

note "animation: none is an explicit off-switch (a later rule beats an earlier pulse)"
FT_TYPE[nob]=button; FT_PARENT[nob]=""
ft_stylesheet name=kf2 style='#nob { color: 45; animation: pulse; } #nob { animation: none; }'
ft_style nob animation; check "cascade resolves animation to none" "$FT_RET" none
if _ft_css_anim_fg nob; then check "animation:none → not animating" running stopped
else check "animation:none → not animating" stopped stopped; fi

note "state-scoped animation: :focus arms the loop, blur disarms it — per-event, no wiring"
FT_TYPE[foc]=button; FT_PARENT[foc]=""
ft_stylesheet name=kf3 style='#foc { color: 45; } #foc:focus { animation: pulse; }'
paintkf(){ _ft_css_anim_fg foc || _ft_css_anim_disarm foc; }
FT_FOCUS="";  paintkf; check "unfocused → loop idle" "${FT_CSS_ANIMATION_ON[foc]:-off}" off
FT_FOCUS=foc; paintkf; check "focused → loop armed"  "${FT_CSS_ANIMATION_ON[foc]:-off}" 1
FT_FOCUS="";  paintkf; check "blurred → loop idle"   "${FT_CSS_ANIMATION_ON[foc]:-off}" off
FT_FOCUS=""

note "built-in 'pulse' is a real @keyframes using OPACITY — it dims the element's OWN colour"
FT_TYPE[pb]=button; FT_PARENT[pb]=""; FT_COLOR_MODE=256
_reset_pb(){ ft_anim_stop pb 2>/dev/null; unset "FT_ANIM_PHASE[pb]" "FT_CSS_ANIMATION_ON[pb]" 2>/dev/null; }
_ft_css_kf_for pb pulse
check "pulse is a defined @keyframes (opacity ramp)" "$([[ -n "$_KF_OP" ]] && echo yes)" yes
ft_stylesheet name=pul style='#pb { color: 39; background-color: 0; animation: pulse; }'   # azure on black
_reset_pb; _ft_css_anim_fg pb >/dev/null
check "pulse arms a loop from the element's colour" "${FT_CSS_ANIMATION_ON[pb]:-off}" 1
FT_ANIM_PHASE[pb]=0; _ft_css_anim_fg pb; check "phase 0 (opacity 1) = the FULL colour (39)" "$FT_RET" $'\e[38;5;39m'
FT_ANIM_PHASE[pb]=0; _ft_css_anim_fg pb; b0=$FT_RET
_ft_css_kf_for pb pulse; _ft_css_kf_len; FT_ANIM_PHASE[pb]=$(( FT_RET/2 )); _ft_css_anim_fg pb; bmid=$FT_RET
check "the dimmest phase differs from full (opacity < 1)" "$([[ "$b0" != "$bmid" ]] && echo yes)" yes

note "animation-duration (and the shorthand <time>) set the cycle speed → per-frame ms"
_ft_css_kf_for pb pulse; _ft_css_kf_len; plen=$FT_RET
_reset_pb; ft_stylesheet name=pul style='#pb { color: 39; animation: pulse; animation-duration: 2s; }'
_ft_css_anim_fg pb >/dev/null; check "2s over the pulse ramp → 2000/len ms/frame" "${FT_ANIM_FRAME_MS[pb]}" "$(( 2000/plen ))"
_reset_pb; ft_stylesheet name=pul style='#pb { color: 39; animation: pulse; }'
_ft_css_anim_fg pb >/dev/null; check "no duration → the 120ms default" "${FT_ANIM_FRAME_MS[pb]}" 120
_ft_css_duration_ms "1.5s";  check "duration parse 1.5s → 1500ms"  "$FT_RET" 1500
_ft_css_duration_ms "500ms"; check "duration parse 500ms → 500ms"  "$FT_RET" 500
_ft_css_anim_disarm pb

note "structure animation: control::PE { animation: @keyframes } cycles a STRUCTURE on the shared loop"
FT_TYPE[spe]=textfield; FT_PARENT[spe]=""; FT_COLOR_MODE=256
unset "FT_ANIM_PHASE[spe]" "FT_CSS_ANIMATION_ON[spe]" 2>/dev/null
ft_stylesheet name=peanim style='
  @keyframes scrcyc { from, to { color: 196; } 50% { color: 124; } }
  textfield::scrollbar { animation: scrcyc; }
'
_ft_css_color_pe spe scrollbar color 38; check "structure phase 0 → first stop 196" "$FT_RET" $'\e[38;5;196m'
check "the structure armed the control's loop" "${FT_CSS_ANIMATION_ON[spe]:-off}" 1
_ft_css_kf_for spe scrcyc; _ft_css_kf_len; FT_ANIM_PHASE[spe]=$(( FT_RET/2 )); _ft_css_color_pe spe scrollbar color 38
check "a mid phase glided off 196" "$([[ "$FT_RET" != $'\e[38;5;196m' ]] && echo yes)" yes
check "wants_anim counts a structure animation" "$(_ft_css_wants_anim spe && echo yes)" yes
_ft_color_override spe color 38 >/dev/null
check "element repaint does NOT disarm a live structure" "${FT_CSS_ANIMATION_ON[spe]:-off}" 1
ft_stylesheet name=peanim style='textfield::scrollbar { color: 245; }'      # animation off
_ft_color_override spe color 38 >/dev/null
check "structure animation off → loop disarms" "${FT_CSS_ANIMATION_ON[spe]:-off}" off
_ft_css_color_pe spe scrollbar color 38; check "static structure colour returns (245)" "$FT_RET" $'\e[38;5;245m'
# blink (opacity) on a structure: full colour ↔ its background (invisible), via ft_sgr_pseudo_element
unset "FT_ANIM_PHASE[spe]" "FT_CSS_ANIMATION_ON[spe]" 2>/dev/null
ft_stylesheet name=peanim style='textfield::caret { color: 231; background-color: 16; animation: blink; }'
ft_sgr_pseudo_element spe caret; check "::caret{animation:blink} phase 0 (opacity 1) → bg16 fg231" "$FT_RET" $'\e[48;5;16;38;5;231m'
_ft_css_kf_for spe blink; _ft_css_kf_len; FT_ANIM_PHASE[spe]=$(( FT_RET-1 )); ft_sgr_pseudo_element spe caret
check "blink last phase (opacity 0) → fg fades to the bg (16)" "$FT_RET" $'\e[48;5;16;38;5;16m'
_ft_css_anim_disarm spe

note "STATE pseudo-elements: ::active / table::header|stripe restyle per-item states"
FT_TYPE[str]=tree; FT_PARENT[str]=""; FT_TYPE[stb]=table; FT_PARENT[stb]=""; FT_TYPE[sts]=tabs; FT_PARENT[sts]=""; FT_COLOR_MODE=256
ft_stylesheet name=states style='
  tree::active  { background-color: 27; color: 231; }
  table::header { color: 190; font-weight: bold; }
  table::stripe { background-color: 236; }
  tabs::active  { background-color: 33; color: 16; }
'
_ft_css_pe_or str active  FB; check "tree::active composes bg+fg"     "$FT_RET" $'\e[48;5;27;38;5;231m'
_ft_css_pe_or stb header  FB; check "table::header composes fg+bold"  "$FT_RET" $'\e[38;5;190;1m'
_ft_css_pe_or stb stripe  FB; check "table::stripe composes bg"       "$FT_RET" $'\e[48;5;236m'
_ft_css_pe_or sts active  FB; check "tabs::active composes bg+fg"     "$FT_RET" $'\e[48;5;33;38;5;16m'
_ft_css_pe_or str selected FB; check "an unstyled state → the role fallback" "$FT_RET" FB
# `::active` is spelled the same on every control, so the TYPE has to keep the rules apart:
# tree's active row must not pick up tabs' colours and vice versa.
_ft_css_pe_or stb active FB; check "::active on a type that declares none → fallback" "$FT_RET" FB
# a state animates too: the declared bg is kept, the fg cycles on the control's shared loop
ft_stylesheet name=states2 style='
  @keyframes curcyc { from, to { color: 196; } 50% { color: 124; } }
  tree::active { background-color: 27; animation: curcyc; }
'
unset "FT_ANIM_PHASE[str]" "FT_CSS_ANIMATION_ON[str]" 2>/dev/null
_ft_css_pe_or str active FB; check "tree::active animated: bg kept, fg is the phase-0 stop 196" "$FT_RET" $'\e[48;5;27;38;5;196m'
check "the state animation armed the loop" "${FT_CSS_ANIMATION_ON[str]:-off}" 1
_ft_css_anim_disarm str

note "EVERY structure is a pseudo-element: ::track ::placeholder ::gutter ::wrap (no raw roles)"
FT_TYPE[strf]=textfield; FT_PARENT[strf]=""; FT_TYPE[strs]=scrollbar; FT_PARENT[strs]=""; FT_COLOR_MODE=256
ft_stylesheet name=structs style='
  textfield::placeholder { color: 244; font-weight: bold; }
  textfield::gutter      { color: 240; }
  textfield::wrap        { color: 208; }
  scrollbar::track       { color: 236; }
'
_ft_css_pe_or strf placeholder FB; check "::placeholder composes fg+bold" "$FT_RET" $'\e[38;5;244;1m'
_ft_css_pe_or strf gutter FB;      check "::gutter composes fg"           "$FT_RET" $'\e[38;5;240m'
_ft_css_pe_or strf wrap   FB;      check "::wrap composes fg"             "$FT_RET" $'\e[38;5;208m'
_ft_css_pe_or strs track  FB;      check "::track composes fg"            "$FT_RET" $'\e[38;5;236m'
_ft_css_pe_or strf track  FALLBACK; check "an unstyled structure → the role fallback" "$FT_RET" FALLBACK

note "keylegend, statusbar, boxheader & heading obey the cascade (no more baked theme roles)"
hasc(){ [[ "$1" == *"$2"* ]] && FT_RET=yes || FT_RET=no; }
ft-form name=sbf width=40 height=6; ft-keylegend name=sleg keys="Enter=Open"; ft-statusbar name=sbar status="Ready."; end_ft_form
ft_stylesheet name=barsheet style='keylegend { color: 205; } keylegend::keycap { color: 231; } statusbar::hint { color: 244; }'
_ft_compose_sgr sleg "$FT_COLOR_STATUS"; hasc "$FT_RET" "38;5;205"; check "keylegend legend obeys 'keylegend{color}'" "$FT_RET" yes
_ft_css_pe_or sleg keycap FB; check "keylegend::keycap styles the caps"      "$FT_RET" $'\e[38;5;231m'
_ft_css_pe_or sbar hint   FB; check "statusbar::hint styles the synopsis"    "$FT_RET" $'\e[38;5;244m'

# boxheader/heading are REAL controls now (they were nameless immediate-mode painters styled
# through a detached type probe). So they style exactly like every other control: build them
# in a form and compose against the live element — no probe, no special case.
ft-form name=hdf width=40 height=8; ft-boxheader name=hbox text="Wildcards"; ft-heading name=hhead text="Advanced"; end_ft_form
ft_stylesheet name=hdrsheet style='heading { color: 154; } boxheader { color: 45; } boxheader::border { color: 240; }'
_ft_compose_sgr hhead "$FT_COLOR_HEADING";  hasc "$FT_RET" "38;5;154"; check "ft-heading obeys 'heading { color }'"           "$FT_RET" yes
_ft_compose_sgr hbox  "$FT_COLOR_BOX_TEXT"; hasc "$FT_RET" "38;5;45";  check "ft-boxheader label obeys 'boxheader { color }'" "$FT_RET" yes
_ft_css_pe_or   hbox  border "$FT_COLOR_BOX_LINE"; check "ft-boxheader frame obeys 'boxheader::border'" "$FT_RET" $'\e[38;5;240m'
# ...and being real controls, an #id beats the type rule (level 2 specificity), which the old
# probe could never demonstrate because it carried no identity.
ft_stylesheet name=hdrid style='#hhead { color: 99; }'
_ft_compose_sgr hhead "$FT_COLOR_HEADING"; hasc "$FT_RET" "38;5;99"; check "#id out-specifies 'heading { … }'" "$FT_RET" yes
_ft_height_boxheader; check "a boxheader is 3 rows tall" "$FT_RET" 3
_ft_height_heading;   check "a heading is 1 row tall"    "$FT_RET" 1
check "neither is a focus stop" "${FT_CLASS_FOCUSABLE[boxheader]}${FT_CLASS_FOCUSABLE[heading]}" "00"

# ── Attribute selectors (the six operators + presence) ───────────────────────
note "attribute selectors: [a] [a=v] [a^=] [a\$=] [a*=] [a~=] [a|=]"
FT_TYPE[t_a]=button; FT_PARENT[t_a]=""
_ft_setprop t_a data "en-US"
_ft_setprop t_a list "red green blue"
mt(){ if _ft_css_attr_match "$1" "$2"; then FT_RET=yes; else FT_RET=no; fi; }
mt t_a 'data';        check "[a] present"        "$FT_RET" yes
mt t_a 'nope';        check "[a] absent"         "$FT_RET" no
mt t_a 'data=en-US';  check "[a=v] exact"        "$FT_RET" yes
mt t_a 'data=en';     check "[a=v] not exact"    "$FT_RET" no
mt t_a 'data^=en';    check "[a^=v] prefix"      "$FT_RET" yes
mt t_a 'data$=US';    check "[a\$=v] suffix"     "$FT_RET" yes
mt t_a 'data*=n-U';   check "[a*=v] substring"   "$FT_RET" yes
mt t_a 'data|=en';    check "[a|=v] dash-list"   "$FT_RET" yes
mt t_a 'list~=green'; check "[a~=v] word match"  "$FT_RET" yes
mt t_a 'list~=gre';   check "[a~=v] not a word"  "$FT_RET" no

# ── Combinators, functional pseudo-classes, and the new state pseudos ─────────
# tree: q_form > q_row > { q_b1(.hero,variant=primary), q_b2, q_lbl, q_tf > q_gb }
FT_TYPE[q_form]=form;     FT_PARENT[q_form]="";      FT_KIDS[q_form]="q_row"
FT_TYPE[q_row]=div;     FT_PARENT[q_row]=q_form;   FT_KIDS[q_row]="q_b1 q_b2 q_lbl q_tf"
FT_TYPE[q_b1]=button;     FT_PARENT[q_b1]=q_row;     _ft_setprop q_b1 variant primary; _ft_setprop q_b1 class hero
FT_TYPE[q_b2]=button;     FT_PARENT[q_b2]=q_row
FT_TYPE[q_lbl]=label;     FT_PARENT[q_lbl]=q_row
FT_TYPE[q_tf]=textfield;  FT_PARENT[q_tf]=q_row;     FT_KIDS[q_tf]="q_gb"
FT_TYPE[q_gb]=button;     FT_PARENT[q_gb]=q_tf
_qn=0
qm(){ # selector control expected — matches via a throw-away one-rule sheet
    local nm="qs$((++_qn))"
    ft_stylesheet name="$nm" style="$1 { color: 1; }"
    if _ft_css_matches "$nm"$'\t'0 "$2"; then FT_RET=yes; else FT_RET=no; fi
    check "$1  →  $2" "$FT_RET" "$3"
}
note "combinators: child > , descendant (space), adjacent + , general ~"
qm '#q_row > button' q_b1 yes           # direct child
qm '#q_row > button' q_gb no            # q_gb is a grandchild, not a child
qm '#q_row button'   q_gb yes           # …but it IS a descendant
qm '#q_b1 + button'  q_b2 yes           # q_b2 is the adjacent sibling after q_b1
qm '#q_b1 + label'   q_lbl no           # q_b1's next sibling is q_b2, not a label
qm '#q_b1 ~ label'   q_lbl yes          # q_lbl follows q_b1 among siblings
qm '#q_lbl ~ button' q_b1 no            # q_b1 precedes q_lbl → not a following sibling

note "functional pseudo-classes: :not() :is() :where() :has()"
qm ':not(.hero)'            q_b2 yes
qm ':not(.hero)'            q_b1 no
qm 'button:is(.hero, label)' q_b1 yes
qm 'button:is(.hero, label)' q_b2 no
qm ':where(.hero)'         q_b1 yes
qm ':has(button)'          q_tf  yes    # q_tf contains q_gb
qm ':has(button)'          q_lbl no     # a leaf has nothing
qm 'label:not(.hero)'      q_lbl yes

note "state pseudo-classes drive per-event styling: :checked :selected :empty :enabled/:disabled :editing"
_ft_setprop q_b2 value true;  qm ':checked'  q_b2 yes
_ft_setprop q_lbl value false; qm ':checked' q_lbl no
_ft_setprop q_b1 selected true; qm ':selected' q_b1 yes
qm ':empty'   q_lbl yes                  # no children
qm ':empty'   q_row no                   # has children
_ft_setprop q_gb disabled true
qm ':disabled' q_gb yes
qm ':enabled'  q_b1 yes
ft-modify q_tf runlevel=editing;  qm ':editing' q_tf yes
ft-modify q_tf runlevel=unfocused;  qm ':editing' q_tf no

note "specificity: [attr] & :is()/:not() count like a class; :where() counts 0"
_ft_css_specificity 'button';            check "type = 1"                 "$FT_RET" 1
_ft_css_specificity 'button[data]';      check "type + attr = 101"        "$FT_RET" 101
_ft_css_specificity 'button:not(.a.b)';  check ":not() = max arg (2 cls)" "$FT_RET" 201
_ft_css_specificity 'button:where(.a.b)';check ":where() adds 0"          "$FT_RET" 1
_ft_css_specificity '#x:is(.a, p)';      check ":is() = most-specific arg (.a)" "$FT_RET" 10100

note "a @keyframes block does not swallow the rules around it"
# The parser splits on braces (it used to walk character by character, which made it quadratic
# in the length of the sheet — 320 rules took 3.7s). @keyframes is the one place braces NEST,
# so it is the one place the split has to count depth. Getting that wrong ate everything after
# the block, and a theme's animations are usually declared in the middle of the sheet.
_ft_css_parse kfa '.before { color: 33; } .after { color: 202; }'
check "two plain rules"                    "${FT_CSS_RULE_COUNT[kfa]}" 2
_ft_css_parse kfb '@keyframes spin { from { color: 196; } to { color: 21; } }'
check "a keyframes block is not a rule"    "${FT_CSS_RULE_COUNT[kfb]}" 0
_ft_css_parse kfc '.before { color: 33; } @keyframes spin { from { color: 196; } to { color: 21; } } .after { color: 202; }'
check "rule, keyframes, rule → both rules" "${FT_CSS_RULE_COUNT[kfc]}" 2
_ft_css_parse kfd '@keyframes spin { from { color: 196; } to { color: 21; } } .after { color: 202; }'
check "keyframes first → the rule survives" "${FT_CSS_RULE_COUNT[kfd]}" 1
_ft_css_parse kfe '.a { color: 1; } @keyframes p { from { color: 2; } } .b { color: 3; } @keyframes q { to { color: 4; } } .c { color: 5; }'
check "two blocks interleaved → three rules" "${FT_CSS_RULE_COUNT[kfe]}" 3
[[ -n "${FT_CSS_KEYFRAMES_SOURCE[p]:-}" && -n "${FT_CSS_KEYFRAMES_SOURCE[q]:-}" ]] \
    && check "…and both keyframes were stored" 1 1 \
    || check "…and both keyframes were stored" 0 1
# An unbalanced sheet must not hang or take the rest of the file with it.
_ft_css_parse kff '.a { color: 1; } @keyframes bad { from { color: 2; }'
check "an unterminated block does not hang" "${FT_CSS_RULE_COUNT[kff]}" 1

note "a var() CYCLE resolves to nothing — it must not hang the app"
# The recursion is MUTUAL, not a loop: _ft_css_resolve_value asks ft_style for the referenced
# property, ft_style computes its value, and that value is another var() back here. The local
# `guard` counter is reset on every entry and never sees it, so `--a: var(--a)` — one typo in a
# stylesheet — simply FROZE the app. CSS calls this "invalid at computed-value time".
_cssrun() {                     # body → "returned" | "HUNG" | "CRASHED"
    local out rc
    out=$(timeout 6 bash -c "
        cd '$here'
        source ./fruity-tui.bash; ft_init; exec {FT_TTY}>/dev/null
        FT_COLS=60; FT_ROWS=12
        $1
        printf 'RETURNED:%s' \"\$FT_RET\"
    " 2>&1); rc=$?
    if   (( rc == 124 )); then printf 'HUNG'
    elif (( rc == 139 )); then printf 'CRASHED'
    elif [[ "$out" == *RETURNED:* ]]; then printf 'returned'
    else printf 'died rc=%s' "$rc"; fi
}
_mkcss() {                      # css → body that resolves label `l`'s colour
    printf '%s' "ft_stylesheet name=s style='$1'
        ft-form name=f width=60 height=10
            ft-label name=l 'x'
        end_ft_form
        ft_layout f; FT_ROOT=f
        ft_style l color"
}
check "a property referencing ITSELF" \
      "$(_cssrun "$(_mkcss ':root { --a: var(--a); } label { color: var(--a); }')")" "returned"
check "two properties referencing each other" \
      "$(_cssrun "$(_mkcss ':root { --a: var(--b); --b: var(--a); } label { color: var(--a); }')")" "returned"
check "a cycle reached through a FALLBACK" \
      "$(_cssrun "$(_mkcss ':root { --a: var(--b, var(--a)); } label { color: var(--a); }')")" "returned"
# …and an ordinary var(), including a fallback and a legitimate one-deep chain, still resolves.
# NB an #id selector: this file has registered a dozen sheets by now, several of which style
# `label`, and a bare type rule here loses to them — which reads exactly like a broken var().
ft_stylesheet name=vok style=':root { --good: 201; } #vl { color: var(--good); }'
ft-form name=vf width=60 height=10
    ft-label name=vl "x"
end_ft_form
ft_layout vf; FT_ROOT=vf
ft_style vl color;  check "a plain var() still resolves"      "$FT_RET" "201"
ft_stylesheet name=vok2 style='#vl { color: var(--nope, 42); }'
_ft_css_bump; ft_style vl color
check "…and an unset var() still takes its fallback"          "$FT_RET" "42"
ft_stylesheet name=vok3 style=':root { --x: var(--y); --y: 7; } #vl { color: var(--x); }'
_ft_css_bump; ft_style vl color
check "…and a var() chained one deep still resolves"          "$FT_RET" "7"
ft_remove vf 2>/dev/null

note "an attribute tested INSIDE :not() invalidates the style cache when it changes"
# The nastiest kind of cache bug: the rule parses, matches and cascades perfectly, and every
# direct query gives the right answer — but a write to the attribute is not recognised as
# affecting anything, so the CACHED style outlives the change. The state is then correct
# everywhere except on screen. Only BARE attributes were scanned for dependencies; ones inside
# :not()/:is()/:has() were not, which is the exact shape of both the activated-control marker
# (:not([runlevel=unfocused])) and the built-in :enabled state (:not([disabled=true])).
# A CUSTOM property, so none of the many sheets this suite already installs can reach it —
# with `color` the answer came back from an unrelated rule and the test measured that instead.
FT_TYPE[nq]=slider; FT_PARENT[nq]=""
# A PLAIN attribute, not `runlevel`: a runlevel value is validated against the class that
# declared it, and this control is synthetic (FT_TYPE poked in, no class ever built), so the
# write would be refused and the test would measure the refusal instead of the cache.
ft_stylesheet name=notdep style=':not([mode=rest]) { --nq-mark: 99; }'
_ft_setprop nq mode rest
ft_style nq --nq-mark; check "at rest the rule does not apply"        "${FT_RET:-none}" none
_ft_setprop nq mode busy
ft_style nq --nq-mark; check "changed, it does"                       "${FT_RET:-none}" 99
_ft_setprop nq mode rest
ft_style nq --nq-mark; check "and back at rest it stops — not cached" "${FT_RET:-none}" none
# the same shape the built-in :enabled state is written in
ft_stylesheet name=notdep2 style=':not([disabled=true]) { --nq-en: 88; }'
_ft_setprop nq disabled false
ft_style nq --nq-en; check "enabled → the :not([disabled]) rule applies" "${FT_RET:-none}" 88
_ft_setprop nq disabled true
ft_style nq --nq-en; check "disabled → it stops applying"               "${FT_RET:-none}" none

note ":engaged — the one question every class answers the same way"
# `runlevel` is per-class: a slider adjusts, a textfield edits, a tree browses. So a
# stylesheet cannot ask "is this control activated?" by VALUE without naming every level
# every class might invent. :engaged asks the question that is class-independent — is it off
# the universal zero rung? It is a predicate rather than the obvious `:not([runlevel=unfocused])`
# because an attribute test is TRUE when the attribute is ABSENT: every control that has no
# runlevel at all (a label, a form, the theme's probe control) would read as activated.
# The rules are TYPE-scoped on purpose. Custom properties inherit, so an unscoped `:poised`
# would match the enclosing FORM — which has no runlevel and so is always at rest — and
# cascade down onto the engaged slider, hiding the very thing under test.
ft-form name=eg width=40 height=8
    ft-slider name=egs  min=0 max=100 value=40
    ft-slider name=egs2 min=0 max=100 value=40
    ft-label  name=egl  text="a class with no runlevel at all"
end_ft_form
FT_ROOT=eg; ft_layout eg
ft_stylesheet name=egsheet style='
    slider:engaged { --eg-mark: 77; }  slider:poised { --eg-rest: 66; }
    label:engaged  { --eg-lmark: 55; } label:unfocused { --eg-lrest: 44; }'
ft_style egs --eg-mark; check "at rest → :engaged does not match"           "${FT_RET:-none}" none
ft_style egs --eg-rest; check "…and :poised does"                          "${FT_RET:-none}" 66
_ft_setprop egs runlevel adjusting
ft_style egs --eg-mark; check "adjusting → :engaged matches"                "${FT_RET:-none}" 77
ft_style egs --eg-rest; check "…and :poised stops"                         "${FT_RET:-none}" none
ft_style egs2 --eg-mark; check "…and the sibling is untouched"              "${FT_RET:-none}" none
_ft_setprop egs runlevel unfocused
ft_style egs --eg-mark; check "back to unfocused → it stops (not cached)"    "${FT_RET:-none}" none
ft_style egl --eg-lmark; check "a class with no runlevel is never engaged"  "${FT_RET:-none}" none
ft_style egl --eg-lrest; check "…it is unfocused, which is the truth"         "${FT_RET:-none}" 44
# Blur must put it back. A control left on a live rung would go on claiming it owns the
# arrows after they had already moved somewhere else.
_ft_setprop egs runlevel adjusting
ft_focus egs; ft_focus egs2
ft_style egs --eg-mark; check "blur returns it to the zero rung"            "${FT_RET:-none}" none
ft_remove eg 2>/dev/null

note "a name REBUILT is a different element, and resolves its own style"
# ft_remove used to UNSET a node's cache version, so the next control of the same name started
# at 0 again, climbed through the same values as it applied the same number of style-affecting
# properties, and hit the token the DEAD one's entry was stored under. It then resolved the dead
# control's style — silently, and for the rest of the session. Rebuilding under the same name is
# THE rebuild idiom this framework documents, so this is not a corner: the callout tour's arrow
# page raises `specArrow` fresh on every step, and stepping from a retracting arrow to a fading
# one gave the fade the retract's timing curve.
ft_remove rcy 2>/dev/null
ft-label name=rcy parent=cssroot text=one color=accent
ft_style rcy color; check "first incarnation resolves its own colour"  "$FT_RET" accent
ft_remove rcy
ft-label name=rcy parent=cssroot text=two color=notice
ft_style rcy color; check "…and so does the one that replaced it"      "$FT_RET" notice
# The same trap on a property the CASCADE supplies rather than the call site, since those take
# a different route through _ft_style_compute.
ft_stylesheet name=ft-test-recycle style='#rcy2 { color: 51 }'
ft_remove rcy2 2>/dev/null
ft-label name=rcy2 parent=cssroot text=one
ft_style rcy2 color; check "a stylesheet colour resolves"              "$FT_RET" 51
ft_remove rcy2
ft-label name=rcy2 parent=cssroot text=two color=notice
ft_style rcy2 color; check "…and an inline override on the rebuild wins" "$FT_RET" notice
# …and the version really is kept rather than unset, which is the mechanism.
ft_remove rcy2
check "a forgotten name keeps a version, bumped" "$(( ${_FT_CSS_VERSION[rcy2]:-0} > 0 ))" "1"
# …and a compaction pass is still allowed to reclaim it, because it drops the composite
# entries in the same sweep. Nothing stale can survive that.
_ft_css_compact
check "…and compaction may then reclaim it"      "${_FT_CSS_VERSION[rcy2]:-gone}" "gone"
ft_remove rcy 2>/dev/null

note "the three keyframe ramps stay in lockstep — one stop table, one sampling rule"
# _ft_css_kf_compose indexes EVERY ramp of one @keyframes block as `phase % length`, so the
# colour, numeric and stepped builders have to produce the same number of samples for the same
# stop offsets. They used to guarantee that by carrying three character-for-character copies of
# the stop sort and the density rule; they now share one of each. Measured while the copies were
# still there: change the density in the colour builder alone and at phase 24 the colour has
# wrapped round to sample 11 while the weight is still sitting on its last one. This asserts the
# property those two shared functions exist to keep — it is an invariant, not a regression pin,
# and it passed before the extraction too.
_ramp_lengths() {               # "offsets" → FT_RET = "colour numeric stepped", FT_RAMP_LEN
    local -a stops=($1)
    local -a colour_offsets=() colour_values=() number_offsets=() number_values=()
    local -a step_offsets=() step_values=()
    local i
    for (( i=0; i<${#stops[@]}; i++ )); do
        colour_offsets+=("${stops[i]}"); colour_values+=("$(( 16 + i * 20 ))")
        number_offsets+=("${stops[i]}"); number_values+=("$(( i * 25 ))")
        step_offsets+=("${stops[i]}")
        (( i % 2 )) && step_values+=(bold) || step_values+=(normal)
    done
    local -a samples
    _ft_css_kf_ramp     colour_offsets colour_values; samples=($FT_RET); local colour=${#samples[@]}
    _ft_css_kf_num_ramp number_offsets number_values; samples=($FT_RET); local number=${#samples[@]}
    _ft_css_kf_step     step_offsets   step_values;   samples=($FT_RET); local stepped=${#samples[@]}
    FT_RAMP_LEN=$colour
    FT_RET="$colour $number $stepped"
}
for _stops in "0 100" "0 50 100" "0 33 100" "0 50 50 100" "100 0" "0 0 100"; do
    _ramp_lengths "$_stops"
    check "stops [$_stops] → all three ramps are $FT_RAMP_LEN samples" \
          "$FT_RET" "$FT_RAMP_LEN $FT_RAMP_LEN $FT_RAMP_LEN"
done
# …and the two shared halves really are shared, not re-copied: a density change must move all
# three at once. (Restored immediately — nothing below may see a different density.)
_saved_density=$FT_CSS_KEYFRAME_DENSITY
FT_CSS_KEYFRAME_DENSITY=12
_ramp_lengths "0 100"; _halved=$FT_RAMP_LEN
FT_CSS_KEYFRAME_DENSITY=$_saved_density
_ramp_lengths "0 100"; _full=$FT_RAMP_LEN
check "one density governs all three ramps (12 → $_halved samples, 24 → $_full)" \
      "$(( _halved < _full ? 1 : 0 ))" 1

# ── The origin split, for STRUCTURES as well as boxes ────────────────────────
# LAST IN THE FILE ON PURPOSE: ft_use_theme installs `ft-default` as the default sheet, which
# would displace the `ua` sheet every assertion above is written against.
#
# `_ft_css_query_pe_compute` used to have no origin filter at all while its element twin
# enforced one, so a theme's `::caret` rule was pooled with the app's and ranked on specificity
# and source order alone — the app's own `color` on the very same control resolving one way and
# its `::caret` colour the other. Neither of the two ways that bites can be fixed by writing the
# sheets in a different order: ft_use_theme RE-REGISTERS the default sheet at runtime, so its
# rules take fresh and higher source orders, and a theme rule may simply be more specific.
#
# Pinned with a theme that really does style pseudo-elements, which is the case that arms it.
# The three bundled themes carry no `::` rules today, so nothing shipped can trip it — but
# docs/styling-model.md §6 invites precisely this theme.
note "a theme's ::pseudo-element rule does not outrank the app's"
FT_TYPE[oc1]=caretbox;  FT_PARENT[oc1]=broot
FT_TYPE[oc2]=caretbox2; FT_PARENT[oc2]=broot
FT_TYPE[oc3]=caretbox3; FT_PARENT[oc3]=broot
# borderColor rather than color for the element half: the combinator section above leaves a
# trail of throw-away one-rule sheets that all declare `color: 1`, and some of their selectors
# match anything — a contaminated baseline would make the element half read 1 whatever the
# origins did. Nothing in this file declares borderColor on a type this section invents.
ft_stylesheet name=originapp style='
    caretbox              { border-color: 100; }
    caretbox::caret       { color: 100; }
    caretbox2::caret      { color: 101; }
'
ft_theme name=origin-theme style='
    caretbox              { border-color: 200; }
    caretbox::caret       { color: 200; }
    #oc2::caret           { color: 201; }
    caretbox3::caret      { color: 202; }
'
ft_use_theme origin-theme
check "the theme really is the default sheet now" "$FT_CSS_DEFAULT_SHEET" "ft-default"
ft_style oc1 borderColor
check "element: the app's value wins over the theme's"         "$FT_RET" "100"
_ft_css_query_pe oc1 caret color
check "::caret: the app's colour wins too (equal specificity, theme registered later)" \
      "$FT_RET" "100"
_ft_css_query_pe oc2 caret color
check "…and still wins when the theme rule is FAR more specific (#id vs type)" "$FT_RET" "101"
# The other half of the split: the default sheet is outranked, not ignored.
_ft_css_query_pe oc3 caret color
check "a structure the app says nothing about keeps the theme's colour" "$FT_RET" "202"
# …and it reaches paint the same way, since that is where the divergence was visible.
_ft_css_color_pe oc1 caret color 38
check "the SGR the painter gets carries the app's colour" "$FT_RET" $'\e[38;5;100m'


# ═══ THE LAYOUT ASKS THE CASCADE ═════════════════════════════════════════════
# Second of the two faults behind "a stylesheet cannot set padding". The first was that a class
# default outranked every sheet; this is that the LAYOUT never consulted a sheet at all. It
# resolves through ft_resolved_prop and the raw fast paths, and ft_style is the PAINT path — 49 calls to
# the one against 9 to the other in ft-forms.bash. Proven on a property NO class defaults, so
# the level fix cannot be the cause: with `#lfr { width: 30; height: 7 }` registered, ft_style
# answered 30 and 7, ft_resolved_prop answered nothing, and the frame laid out 90x3.
note "a stylesheet reaches the LAYOUT, not just the paint"
ft-form name=lapp width=90 height=30
    ft-frame name=lfr title="L"
        ft-button name=lbtn "Go"
    end_ft_frame
end_ft_form
FT_ROOT=lapp; ft_layout lapp >/dev/null 2>&1
ft_stylesheet name=layoutgate style='#lfr { width: 30; height: 7; padding: 2; gap: 3 }'
ft_resolved_prop lfr width  "?"; check "ft_resolved_prop sees a sheet's width"   "$FT_RET" "30"
ft_resolved_prop lfr height "?"; check "…and its height"                "$FT_RET" "7"
ft_resolved_prop lfr padding "?"; check "…and a class-defaulted padding" "$FT_RET" "2"
_ft_padding lfr;          check "…and so does the raw fast path" "$FT_RET" "2"
ft_layout lapp >/dev/null 2>&1
check "…and the box is actually laid out that way" \
      "${FT_MEASURED_WIDTH[lfr]}x${FT_MEASURED_HEIGHT[lfr]}" "30x7"

note "the gate is SHUT for properties no stylesheet mentions"
# The gate is _FT_CSS_DECLARED_PROPS, accumulated by the parser. It is what keeps the cascade
# off the hottest path in the framework for an app with no layout rules: `display` is asked 479
# times in one layout of a 37-control page, and this is what those 479 reads cost nothing extra.
check "a declared property is in the gate"      "${_FT_CSS_DECLARED_PROPS[padding]:-no}" "1"
check "…and an undeclared one is not"           "${_FT_CSS_DECLARED_PROPS[flexBasis]:-no}" "no"
ft_stylesheet name=layoutgate style=''
ft_resolved_prop lfr width "?"; check "…and removing the rule hands the answer back" "$FT_RET" "?"

# SINGLE quotes: backticks inside a double-quoted string are command substitution, so this line
# ran `cursor` as a command and put "cursor: command not found" on STDERR — which run-all.bash
# fails a file for, because stderr in this framework lands on the alt screen. 232/232 assertions
# passed while the file failed.
note '…and the gate never opens for `cursor`'
# CSS's inherited `cursor` is a ROW INDEX on a select, a table and a tree. A sheet saying
# `cursor: pointer` must not become a tree's cursor, because that value reaches arithmetic.
# It is the one name collision between CSS's vocabulary and control state, and it is excluded
# by name; a SECOND collision is the signal to split style from state properly.
ft-tree name=lt parent=lapp
ft_stylesheet name=layoutgate style='* { cursor: pointer }'
ft_resolved_prop lt cursor "?"
check "a sheet's cursor never becomes a tree's row index" \
      "$(case "$FT_RET" in pointer) echo leaked ;; *) echo "$FT_RET" ;; esac)" "0"
ft_stylesheet name=layoutgate style=''

# …and an unset background is STILL A HOLE. The gate's first cut asked ft_style, which answers
# from levels 3, 4 and 5 as well — importing the THEME for a control that declares no
# background of its own, which `_ft_color_override` refuses to do on purpose. Measured as a
# control claiming 48;5;39 as its own; the gate adds cascade level 2 and nothing else. The
# gate on that rule is tests/test-inheritpaint.bash, which owns the question and asks it on a
# clean stage — asking it here would be asking it of a button under six registered sheets.

summary
