#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  AN INHERITED COLOUR MUST REACH THE BYTES.
#
#  `color` is the canonical inherited property in CSS, and the cascade got it right —
#  `ft_style kid color` answered 196 for a label under a frame styled by a rule. The PAINT did
#  not: the label wrote the default foreground. The compose path asked a narrower question than
#  the cascade answers. _ft_color_override's fallback is ft_resolved_prop → ft_resolve, and that walk
#  inherits by reading ancestors' RAW PROPERTIES, so a value that came from a STYLESHEET RULE on
#  an ancestor is invisible to it. An inline `color=` on the same ancestor worked, which is why
#  this survived: the demos set colours inline.
#
#  THE NARROWNESS WAS LOAD-BEARING, and the fix must not undo it. `ft_style` also applies a
#  prototype's built-in default, so asking it for `backgroundColor` on an unstyled label answers 39
#  — a real colour where the engine requires NOTHING, because an unset background must stay a
#  HOLE that shows whatever is behind it (docs: the transparent-background rule). So the
#  cascade is consulted only for properties that actually INHERIT; background keeps the old
#  ladder and keeps its hole.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
cd "$here"
export FT_NO_WTFIX=1
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_USE_UTF8=1
FT_COLS=60; FT_ROWS=16

# the foreground a control actually painted ("" if it set none of its own)
painted_fg_of() {               # name → FT_RET
    FT_OUT=""; ft_draw_one "$1"; local f=$FT_OUT; FT_OUT=""
    local v=""
    [[ "$f" == *$'\e'"[38;5;"* ]] && { v=${f##*$'\e'"[38;5;"}; v=${v%%m*}; v=${v%%;*}; }
    FT_RET=$v
}
painted_bg_of() {               # name → FT_RET = the FIRST background it established
    # First, not last: the inherited-bg floor is emitted ahead of the control's own colours,
    # and the trailing sequence is the restore. Taking the last one reads the restore.
    FT_OUT=""; ft_draw_one "$1"; local f=$FT_OUT; FT_OUT=""
    local v=""
    [[ "$f" == *"[48;5;"* ]] && { v=${f#*"[48;5;"}; v=${v%%m*}; v=${v%%;*}; }
    FT_RET=$v
}

note "a colour inherited from a STYLESHEET RULE reaches the paint"
ft_stylesheet name=ip style='#ruled { color: 196; }'
ft-form name=app width="$FT_COLS" height="$FT_ROWS"
    ft-frame name=ruled
        ft-label name=kidR text="hello"
    end_ft_frame
    ft-frame name=inlined color=201
        ft-label name=kidI text="hello"
    end_ft_frame
    ft-frame name=plainbox
        ft-label name=kidP text="hello"
    end_ft_frame
end_ft_form
FT_ROOT=app; ft_layout app

ft_style kidR color
check "the cascade already knew it was 196" "$FT_RET" 196
painted_fg_of kidR
check "…and now the bytes say 196 too" "$FT_RET" 196

note "the inline case, which always worked, still does"
ft_style kidI color
check "the cascade says 201" "$FT_RET" 201
painted_fg_of kidI
check "…and so do the bytes" "$FT_RET" 201

note "a control with no colour anywhere is left alone"
ft_style kidP color
check "the cascade offers nothing" "$FT_RET" ""
painted_fg_of kidP
check "…so the paint sets no foreground of its own" "$FT_RET" ""

note "AN UNSET BACKGROUND IS STILL A HOLE"
# ft_style would answer a prototype default here; the compose path must not ask it. The label
# establishes only the background it INHERITS from an ancestor that actually declares one —
# never one of its own invention.
ft_style plainbox backgroundColor
check "no ancestor declares a background" "$FT_RET" ""
_ft_color_override kidP backgroundColor 48
check "the compose path claims no background for it" "$FT_RET" ""
_ft_color_override kidR backgroundColor 48
check "…nor for the one under a ruled ancestor" "$FT_RET" ""

note "an ancestor's background still floors the cell (that is a different mechanism)"
ft_stylesheet name=ip2 style='#ruled { color: 196; background-color: 52; }'
ft_layout app
painted_bg_of kidR
check "the inherited-bg floor still applies" "$FT_RET" 52
_ft_color_override kidR backgroundColor 48
check "…without the control claiming that background as its own" "$FT_RET" ""

note "and an inherited colour survives a deeper chain"
ft-label name=deep text="deep" parent=kidR
ft_layout app
ft_style deep color
check "two levels down the cascade still says 196" "$FT_RET" 196
painted_fg_of deep
check "…and so do its bytes" "$FT_RET" 196

summary
