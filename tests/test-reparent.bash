#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  MOVING A NODE CHANGES WHAT IT INHERITS — so the move must invalidate it.
#
#  Every other route into "this node's cascade inputs changed" invalidates: a property write
#  (_ft_setprop), ft_unset, a stylesheet registration. The DOM move mixins —
#  ft_append / ft_before / ft_after — rewrote FT_PARENT and FT_KIDS and bumped nothing, and
#  the style caches are keyed on the cascade EPOCH plus a per-node version. So after a move
#  the resolver served the OLD parent's inherited value from a warm cache, and the documented
#  follow-up ("call ft_refresh afterwards") repaints from that same warm cache — it cannot heal
#  what it re-reads.
#
#  _ft_css_inval's own safety argument — "an ancestor changing still reaches this node,
#  because that bump walks the ancestor's subtree" — holds only for a tree that does not move.
#  A move is exactly the case it does not cover.
#
#  Pinned at both altitudes: the resolved VALUE, and the CELLS actually painted.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
cd "$here"
export FT_NO_WTFIX=1
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_USE_UTF8=1; FT_COLOR_MODE=256
FT_COLS=60; FT_ROWS=16

ft_stylesheet name=rp style='
    #pRed   { color: 196; background-color: 52; }
    #pBlue  { color: 21;  background-color: 17; }
    #pGreen { color: 46;  background-color: 22; }
'
ft-form name=app width="$FT_COLS" height="$FT_ROWS"
    ft-div name=pRed
        ft-label name=kid text="which parent am I under?"
    end_ft_div
    ft-div name=pBlue
        ft-label name=anchor text="anchor"
    end_ft_div
    ft-div name=pGreen
        ft-label name=anchor2 text="anchor2"
    end_ft_div
end_ft_form
FT_ROOT=app; ft_layout app

note "the resolved value follows the move"
ft_style kid color
check "before the move it is red" "$FT_RET" 196

ok "ft_append moves it under the blue parent" ft_append pBlue kid
ft_style kid color
check "ft_append: the inherited colour follows" "$FT_RET" 21

ok "ft_before splices it beside the green anchor" ft_before anchor2 kid
ft_style kid color
check "ft_before: the inherited colour follows" "$FT_RET" 46

ok "ft_after splices it beside the blue anchor" ft_after anchor kid
ft_style kid color
check "ft_after: the inherited colour follows" "$FT_RET" 21

note "and so do the painted cells"
# The value can be right while the SCREEN is stale: the composed SGR is cached separately and
# keyed the same way. A label's own foreground does NOT carry the inherited `color` (the
# compose path reads a control's own colour only), so the observable used here is the
# BACKGROUND, which _ft_inherited_bg resolves by walking ancestors — a real ancestor-dependent
# value that reaches the terminal.
painted_bg_of() {               # name → FT_RET = the 256 index the cells were painted on
    FT_OUT=""; ft_draw_one "$1"; local f=$FT_OUT; FT_OUT=""
    local v=${f#*"[48;5;"}; v=${v%%m*}; v=${v%%;*}
    FT_RET=$v
}
ok "back under red" ft_append pRed kid
ft_layout app
painted_bg_of kid
check "painted on the red parent's background" "$FT_RET" 52

ok "move it to blue" ft_append pBlue kid
ft_layout app
painted_bg_of kid
check "painted on the blue parent's background" "$FT_RET" 17

note "a whole subtree follows, not just the moved node"
ft-label name=grandkid text="deep" parent=kid
ft_layout app
ft_style grandkid color
check "the grandchild starts blue with its parent" "$FT_RET" 21
ok "move the parent under red" ft_append pRed kid
ft_style grandkid color
check "the grandchild follows its moved ancestor" "$FT_RET" 196
ft_layout app
painted_bg_of grandkid
check "…and is painted on the red background" "$FT_RET" 52

summary
