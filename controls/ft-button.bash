#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — controls/ft-button.bash
#
#  The "button" class — the framework's showcase of constructor-chain
#  inheritance: its class-constructor calls label's (inheriting text sizing,
#  wrapping, and the inline-block default wholesale), then overrides only
#  what a button genuinely owns: its draw function (focus styling + accessKey
#  underline), focusability, and the shared ENTER/SPACE→ft_activate keymap.
#  Activating a button calls onActivate=fn if the app defined one.
#
#  Depends on ft-core.bash, ft-forms.bash, controls/ft-label.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_BUTTON_LOADED:-}" ]] && return 0
_FT_BUTTON_LOADED=1

ft_class_button() {
    # A button is a focusable label that activates. (draw and preferredWidth bind themselves
    # from _ft_draw_button / _ft_preferred_width_button; focusSkip=none clears label's
    # "skip me when I have nothing to scroll" — a button is always a focus stop.)
    # importance=crucial: a button is the one thing that must stay reachable, so anything deciding
    # "what may I cover?" ranks it top. It also has to OVERRIDE label's `minor` — a button extends
    # label, and declared defaults inherit down the chain.
    #
    # MEASURED, not assumed. Cells of button covered by a callout over every step of the callout
    # demo, at the sizes where coverage still happens:
    #        72x24  72x30  80x24  80x30  84x24  84x30
    #   120    158    287    109     85     67     35     (important)
    #   200     47     47     38     19     38      7     (crucial)   ← chosen
    #   255     45     47     38     19     38      7     (no further gain)
    # Prose absorbs what the buttons stop taking, which is the trade asked for: a paragraph reads
    # around an obstruction, a button does not work around one.
    # textAlign=center is the BUTTON'S OWN default, not an accident of the painter. A real
    # <button> centres its label from the UA stylesheet, which is why a page-level
    # `text-align: right` does not re-align one — the class default says exactly that here, and
    # says it where a reader looks for it. It also has to be a default rather than a constant in
    # the draw, because the whole point is that an author can override it: `textAlign=left` on
    # the instance is a sentence the framework already knows how to say.
    # (A class default is applied as an INLINE property, so a stylesheet's `button { text-align:
    # … }` cannot outrank it — the trade-off ft-beacon's class comment records. It costs nothing
    # today: ft_resolved_prop, which every control's painter reads through, does not consult the cascade
    # for any property on any control.)
    ft_class extends=label focusable=true focusSkip=none keymap=activate mouse=activate \
        defaults="importance=crucial textAlign=center"
}

# A button reserves 1 space of horizontal padding on EACH side automatically,
# so callers write   ft-button name=ok OK   and it renders as [ OK ] — no
# hand-typed padding spaces. (The draw centres text in the measured width, so
# textw+2 yields exactly one space per side.)
_ft_preferred_width_button() {            # name → FT_RET (content columns)
    ft_resolved_prop "$1" text; local text=$FT_RET
    ft_resolved_prop "$1" accessKey; _ft_accel_text "$text" "$FT_RET"   # may add " (X)"
    ft_display_width "$FT_RET"
    FT_RET=$(( FT_DISPLAY_WIDTH + 2 ))
}

ft-button() { ft_new button "$@"; }

_ft_draw_button() {                      # name
    local name=$1
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local cols=${FT_MEASURED_WIDTH[$name]:-0}
    (( cols < 1 )) && return

    ft_resolved_prop "$name" text;  local text=$FT_RET
    ft_resolved_prop "$name" accessKey; local accessKey=$FT_RET

    # Base = the button role (focus-aware); the compose layer adds the cascade's
    # background-color/color/font-weight/text-decoration + disabled dimming on top.
    local base; [[ "${FT_FOCUS:-}" == "$name" ]] && base="$FT_COLOR_FOCUS_BTN" || base="$FT_COLOR_BUTTON"
    _ft_compose_sgr "$name" "$base"; local sgr=$FT_RET

    # ONE FITTER, THE SAME ONE EVERY LABEL USES.
    #
    # This used to measure the text and lay its own padding — `lead=$(( pad/2 ))`, `trail=$((
    # pad - pad/2 ))` — which is ft_fit_align's centre branch written out by hand, and a hand
    # copy diverges: it always centred, so `textAlign=left` on a button was ACCEPTED and thrown
    # away (the property resolved on the control and nothing asked for it), and it clamped a
    # negative pad to zero and painted the whole label, so a button narrower than its text
    # overran into whatever sat beside it — 19 columns painted from an 8-column box, straight
    # across a sibling. ft_fit_align has answered all of that since before this copy was made:
    # alignment, an ellipsis when the text cannot fit, a tab expanded rather than sent to the
    # terminal, and the pad-back that keeps a truncation from landing a column short on a
    # double-width glyph.
    #
    # The centre branch is character-for-character what this did (lp=pad/2, rp=pad-lp), so a
    # centred button — every button in the tree — paints the identical string it did before.
    #
    # THE ACCESSKEY UNDERLINE GOES ON AFTERWARDS, on the FITTED text, because it is markup: it
    # adds SGR bytes and no columns, so it must not be measured, and it cannot be applied first
    # or the fitter would count the escapes as content. It is applied only if the letter
    # survived the fit — a label truncated past its accessKey simply loses the underline, where
    # _ft_accel_markup left to itself would append a " (X)" the box has no room for.
    _ft_accel_text "$text" "$accessKey"; local eff=$FT_RET   # plain label (may add " (X)")
    ft_resolved_prop "$name" textAlign center; local align=$FT_RET
    ft_fit_align "$eff" "$cols" "$align"
    local out=$FT_FIT
    if [[ -n "$accessKey" && "${out^^}" == *"${accessKey^^}"* ]]; then
        _ft_accel_markup "$out" "$accessKey" "$sgr"; out=$FT_RET
    fi
    ft_print_at "$row" "$col" "$sgr$out$FT_COLOR_RESET"
}
