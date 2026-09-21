#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — controls/ft-binder.bash
#
#  A BINDER shows one PAGE at a time, and a page is a naming scope.
#
#      ft-binder name=wizard navigator=pager navigatorSide=bottom startPage=welcome
#          ft-page name=welcome
#              ft-label name=hi text="Let's set up your domain."
#          end_ft_page
#          ft-page name=login
#              ft-form name=creds
#                  ft-textfield name=email
#              end_ft_form
#          end_ft_page
#      end_ft_binder
#
#      ft_set wizard currentPage=login          # navigation is a property, not a verb
#
#  ANYTHING DECLARED OUTSIDE THE BINDER STAYS PUT. A status bar beside one is a sibling, not a
#  child, so turning a page does not touch it — that is the whole reason a binder is a control
#  and not a mode.
#
#  A PAGE KEEPS ITS STATE. The pages that are not current are display=none, so their controls
#  are still there with everything the user typed in them: no rebuild, no globals to stash a
#  value in, no guards around a page that may not exist. The mechanism ft-tabs has always used
#  for its panels, and ft-app now uses for screens.
#
#  navigator=  what a person uses to turn the page:
#      none    nothing; the app drives currentPage itself
#      pager   ◀ / 2 of 5 / ▶
#      tabs    one button per page, the current one marked
#  navigatorSide=top|bottom|left|right — where that chrome sits.
#
#  Depends on ft-core.bash, ft-forms.bash, controls/ft-button.bash, controls/ft-label.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_BINDER_LOADED:-}" ]] && return 0
_FT_BINDER_LOADED=1

declare -A _FT_BINDER_PAGE=()   # binder → the current page, as last set SUCCESSFULLY

# _ft_binder_pages NAME → FT_BINDER_PAGES, in declaration order. The navigator is a child too,
# and it is not a page.
FT_BINDER_PAGES=()
_ft_binder_pages() {            # name
    FT_BINDER_PAGES=()
    local kid
    for kid in ${FT_KIDS[$1]:-}; do
        [[ "${FT_TYPE[$kid]:-}" == page ]] && FT_BINDER_PAGES+=("$kid")
    done
}

# _ft_binder_show BINDER PAGE — make PAGE the one on screen.
_ft_binder_show() {             # binder page
    local b=$1 want=$2 p
    [[ -n "$want" && "${FT_TYPE[$want]:-}" == page ]] || {
        printf 'ft: %s: no page named %s\n' "$b" "${want:-<nothing>}" >&2; return 1; }
    _ft_binder_pages "$b"
    local mine=0
    for p in "${FT_BINDER_PAGES[@]}"; do [[ "$p" == "$want" ]] && { mine=1; break; }; done
    (( mine )) || { printf 'ft: %s: %s is not one of its pages\n' "$b" "$want" >&2; return 1; }
    # BEFORE the write, for the reason ft-app's does: _ft_setprop fires the setProp hook, which
    # calls back into here, and a guard set afterwards never stops the second trip.
    _FT_BINDER_PAGE[$b]=$want
    for p in "${FT_BINDER_PAGES[@]}"; do
        if [[ "$p" == "$want" ]]; then _ft_setprop "$p" display flex
        else                           _ft_setprop "$p" display none; fi
    done
    _ft_setprop "$b" currentPage "$want"
    _ft_binder_navigator "$b"
    # The focused control may have just been hidden with the page it was on.
    [[ -n "${FT_FOCUS:-}" ]] && _ft_focus_skippable "$FT_FOCUS" && ft_focus_move 1
    # The ring belongs to the SCOPE (the screen, or a legacy root form), and the pages that just
    # changed visibility are in it — so the scope is the thing to rebuild, not the binder.
    _ft_focus_scope_of "$b"
    [[ -n "$FT_RET" ]] && ft_focus_ring_build "$FT_RET"
    # A REFLOW, NOT A DIRTY. `display` is a LAYOUT property, and the page that just went away
    # leaves its cells on the screen — dirtying the binder marks what is THERE to be redrawn
    # and says nothing about what is not. ft-tabs gets away with the same two _ft_setprop calls
    # only because it declares fillsBackground and paints over its whole box; a binder has no
    # background of its own, so the vacated cells have to be erased by the reflow that
    # re-arranges them. (Found by test-incremental: 42 cells of the old page still standing
    # after an incremental repaint that a full one did not draw.)
    ft_reflow "$b"
    return 0
}

# ft_binder_next / ft_binder_prev — the pager's two buttons, and anything else that wants to
# turn a page without naming it. They CLAMP: a binder is not a carousel, and arriving back at
# page one from page five is never what the person pressing ▶ meant.
ft_binder_go() {                # binder delta
    local b=$1 d=$2 i
    _ft_binder_pages "$b"
    local n=${#FT_BINDER_PAGES[@]}
    (( n )) || return 0
    _ft_get_raw "$b" currentPage; local cur=$FT_RET
    local idx=0
    for i in "${!FT_BINDER_PAGES[@]}"; do [[ "${FT_BINDER_PAGES[$i]}" == "$cur" ]] && { idx=$i; break; }; done
    idx=$(( idx + d ))
    (( idx < 0 )) && idx=0
    (( idx >= n )) && idx=$(( n - 1 ))
    _ft_binder_show "$b" "${FT_BINDER_PAGES[$idx]}"
}
ft_binder_next() { ft_binder_go "$1" 1; }
ft_binder_prev() { ft_binder_go "$1" -1; }

# ── The navigator ────────────────────────────────────────────────────────────
# The chrome is BUILT, not drawn: it is ordinary controls in an ordinary container, so it
# inherits the theme, the focus ring, the accelerator rules and the legend for free — and an
# app can style it with a selector like anything else.
_ft_binder_navigator() {        # binder
    local b=$1
    ft_resolved_prop "$b" navigator none; local kind=$FT_RET
    local nav="${b}__nav"
    [[ "$kind" == none ]] && { [[ -n "${FT_TYPE[$nav]:-}" ]] && ft_remove "$nav"; return 0; }
    _ft_binder_pages "$b"
    local n=${#FT_BINDER_PAGES[@]}
    (( n )) || return 0
    _ft_get_raw "$b" currentPage; local cur=$FT_RET
    local idx=1 i
    for i in "${!FT_BINDER_PAGES[@]}"; do [[ "${FT_BINDER_PAGES[$i]}" == "$cur" ]] && { idx=$(( i + 1 )); break; }; done

    # Rebuilt from scratch on every page turn: the chrome is small, and a navigator that is
    # rebuilt cannot disagree with the pages about which one is current.
    [[ -n "${FT_TYPE[$nav]:-}" ]] && ft_remove "$nav"
    ft_resolved_prop "$b" navigatorSide bottom; local side=$FT_RET
    local dir=row
    case $side in left|right) dir=column ;; esac
    ft-div name="$nav" parent="$b" display=flex flexDirection="$dir" gap=1 flexShrink=0
        if [[ "$kind" == tabs ]]; then
            local p title
            for p in "${FT_BINDER_PAGES[@]}"; do
                _ft_get_raw "$p" title; title=$FT_RET
                [[ -n "$title" ]] || title=$p
                # The current page's button is DISABLED: it is where you already are, so it is
                # not a place to go — and disabled controls drop out of the focus ring, which
                # is exactly right for the one you are on.
                if [[ "$p" == "$cur" ]]; then
                    ft-button name="${nav}_$p" text="$title" disabled=true
                else
                    ft-button name="${nav}_$p" text="$title" onActivate="ft_set $b currentPage=$p"
                fi
            done
        else
            ft-button name="${nav}_prev" text="◀" onActivate="ft_binder_prev $b" \
                      disabled=$( (( idx <= 1 )) && echo true || echo false )
            ft-label  name="${nav}_at"   text="$idx of $n"
            ft-button name="${nav}_next" text="▶" onActivate="ft_binder_next $b" \
                      disabled=$( (( idx >= n )) && echo true || echo false )
        fi
    end_ft_div
    # The navigator goes FIRST when it sits at the top or the left — the tree's order is the
    # layout's order, and a "bottom" pager drawn above the page is a lie about where it is.
    case $side in
        top|left) local kids="${FT_KIDS[$b]}"
                  FT_KIDS[$b]="$nav ${kids% $nav}" ;;
    esac
    return 0
}

# ── The prototypes ───────────────────────────────────────────────────────────
_ft_binder_setprop() {          # name prop value  (see ft-app's: every route must switch)
    [[ "$2" == currentPage ]] || return 0
    [[ "${FT_TYPE[$1]:-}" == binder ]] || return 0
    local want=$3
    [[ -n "$want" ]] || return 0
    [[ "${_FT_BINDER_PAGE[$1]:-}" == "$want" ]] && return 0
    # No pages yet — `ft-binder name=w currentPage=login` names one further down the file.
    # Store it; binder_on_children_complete applies it.
    _ft_binder_pages "$1"
    (( ${#FT_BINDER_PAGES[@]} )) || return 0
    if ! _ft_binder_show "$1" "$want"; then
        _ft_setprop "$1" currentPage "${_FT_BINDER_PAGE[$1]:-}"
        _FT_SETPROP_REFUSED="$1 currentPage"    # ft_set reports it; see ft-forms.bash
        return 1
    fi
    return 0
}
ft_prototype_binder() {
    ft_prototype extends=ft_control \
        setProp=_ft_binder_setprop \
        defaults="display=flex flexDirection=column navigator=none navigatorSide=bottom"
    ft_prop_kind_set currentPage layout        # turning a page re-lays what appears
    ft_prop_kind_set startPage   layout
    ft_prop_kind_set navigator   layout
    ft_prop_kind_set navigatorSide layout
}
ft_prototype_page() {
    ft_prototype extends=ft_control defaults="display=flex flexDirection=column flexGrow=1"
}
ft-binder()     { ft_new binder "$@" && FT_NEST_STACK+=("$FT_RET"); }
end_ft_binder() { ft_end binder; }
ft-page()       { ft_new page "$@" && FT_NEST_STACK+=("$FT_RET"); }
end_ft_page()   { ft_end page; }

binder_on_children_complete() { # binder
    local b=$1
    _ft_binder_pages "$b"
    (( ${#FT_BINDER_PAGES[@]} )) || {
        printf 'ft: %s: a binder holds pages, and this one holds none\n' "$b" >&2; return 0; }
    # startPage names where to open; currentPage is where you are. An app may write either.
    _ft_get_raw "$b" currentPage; local want=$FT_RET
    [[ -n "$want" ]] || { _ft_get_raw "$b" startPage; want=$FT_RET; }
    [[ -n "$want" && "${FT_TYPE[$want]:-}" == page ]] || want="${FT_BINDER_PAGES[0]}"
    _ft_binder_show "$b" "$want"
    return 0
}
