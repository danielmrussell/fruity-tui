#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  A BINDER SHOWS ONE PAGE AT A TIME, AND A PAGE KEEPS ITS STATE.
#
#  The pages that are not current are display=none, so their controls are still there with
#  everything the user typed in them. That is what makes pages worth having: no rebuild, so no
#  globals to stash a value in between turns, and no `[[ -n "${FT_TYPE[x]:-}" ]]` guards around
#  a page that may or may not exist yet. The same mechanism ft-tabs uses for its panels and
#  ft-app uses for screens.
#
#  And ANYTHING DECLARED OUTSIDE THE BINDER STAYS PUT: a status bar beside one is a sibling,
#  not a child, so turning a page does not touch it. That is the whole reason a binder is a
#  control and not a mode.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=60; FT_ROWS=16
_E=$(mktemp "${TMPDIR:-/tmp}/ft-binder.XXXXXX"); trap 'rm -f "$_E"' EXIT
err() { "$@" 2>"$_E"; ERR=$(sed -n '1s/^ft: //p' "$_E"); }

ft-app name=installer
    ft-screen name=main
        ft-binder name=wizard navigator=pager navigatorSide=bottom startPage=login
            ft-page name=welcome title="Welcome"
                ft-label name=hi text="Let's set up your domain."
            end_ft_page
            ft-page name=login title="Login"
                ft-textfield name=email size=20
            end_ft_page
            ft-page name=fin title="Done"
                ft-label name=bye text="All set."
            end_ft_page
        end_ft_binder
        ft-statusbar name=bar status="outside the binder"
    end_ft_screen
end_ft_app
FT_ROOT=installer; ft_layout installer

note "one page at a time, and startPage says which"
check "it opened where it was told"  "$(ft_get wizard currentPage; printf '%s' "$FT_RET")" "login"
check "…that page is shown"          "$(ft_get login display; printf '%s' "$FT_RET")" "flex"
check "…and the others are not"      "$(ft_get welcome display; printf '%s' "$FT_RET")/$(ft_get fin display; printf '%s' "$FT_RET")" "none/none"

note "a page KEEPS its state across a turn"
ft_set email value="admin@example.com"
ft_set wizard currentPage=fin
check "the page turned"              "$(ft_get fin display; printf '%s' "$FT_RET")" "flex"
ft_set wizard currentPage=login
check "…and the field still holds it" "$(ft_get email value; printf '%s' "$FT_RET")" "admin@example.com"

note "what is outside the binder is not the binder's business"
ft_set wizard currentPage=fin
check "the sibling is untouched"     "$(ft_get bar status; printf '%s' "$FT_RET")" "outside the binder"
check "…and still visible"           "$(ft_get bar display; printf '%s' "$FT_RET")" "block"
ft_set wizard currentPage=login

note "the pager says where you are, and clamps at the ends"
check "it counts"                    "$(ft_get wizard__nav_at text; printf '%s' "$FT_RET")" "2 of 3"
ft_binder_prev wizard
check "prev went back"               "$(ft_get wizard currentPage; printf '%s' "$FT_RET")" "welcome"
check "…and says so"                 "$(ft_get wizard__nav_at text; printf '%s' "$FT_RET")" "1 of 3"
check "…with prev now disabled"      "$(ft_get wizard__nav_prev disabled; printf '%s' "$FT_RET")" "true"
ft_binder_prev wizard
check "a binder is not a carousel"   "$(ft_get wizard currentPage; printf '%s' "$FT_RET")" "welcome"
ft_binder_next wizard; ft_binder_next wizard; ft_binder_next wizard
check "…at the other end either"     "$(ft_get wizard currentPage; printf '%s' "$FT_RET")" "fin"
check "…and next is disabled there"  "$(ft_get wizard__nav_next disabled; printf '%s' "$FT_RET")" "true"

note "the pager's buttons are ordinary controls running ordinary code"
ft_set wizard currentPage=login
ft_activate wizard__nav_prev
check "pressing ◀ turned the page"   "$(ft_get wizard currentPage; printf '%s' "$FT_RET")" "welcome"

note "naming a page that is not one is refused, and nothing moves"
ft_set wizard currentPage=login
no  "a page that does not exist"     ft_set wizard currentPage=nope
check "…and the binder did not move" "$(ft_get wizard currentPage; printf '%s' "$FT_RET")" "login"
err ft_set wizard currentPage=email
check "…a control that is not a page is named" "$ERR" "wizard: no page named email"
check "…and it still did not move"   "$(ft_get wizard currentPage; printf '%s' "$FT_RET")" "login"

note "every route that writes currentPage turns the page"
_ft_setprop wizard currentPage fin          # exactly what a state restore does
check "the restore turned it"        "$(ft_get fin display; printf '%s' "$FT_RET")" "flex"
ft-binder name=ctor currentPage=second parent=main
    ft-page name=first;  ft-label name=c1 text="1"; end_ft_page
    ft-page name=second; ft-label name=c2 text="2"; end_ft_page
end_ft_binder
check "…and so does the DSL"         "$(ft_get second display; printf '%s' "$FT_RET")" "flex"
ft_remove ctor

note "navigator=tabs marks where you are"
ft-binder name=tb navigator=tabs navigatorSide=top parent=main
    ft-page name=t1 title="One"; ft-button name=tb1 text="1"; end_ft_page
    ft-page name=t2 title="Two"; ft-button name=tb2 text="2"; end_ft_page
end_ft_binder
check "one button per page"          "$(ft_get tb__nav_t1 text; printf '%s' "$FT_RET")/$(ft_get tb__nav_t2 text; printf '%s' "$FT_RET")" "One/Two"
# The current page's button is where you already are, so it is not a place to go — and a
# disabled control drops out of the focus ring, which is exactly right for it.
check "the current one is not a destination" "$(ft_get tb__nav_t1 disabled; printf '%s' "$FT_RET")" "true"
ft_activate tb__nav_t2
check "pressing the other one goes there"    "$(ft_get tb currentPage; printf '%s' "$FT_RET")" "t2"
check "…and now IT is not a destination"     "$(ft_get tb__nav_t2 disabled; printf '%s' "$FT_RET")" "true"
check "…while the first one is"              "$(ft_get tb__nav_t1 disabled; printf '%s' "$FT_RET")" ""
# The tree's order is the layout's order, so a navigator at the TOP has to come first.
check "navigatorSide=top puts it first"      "${FT_KIDS[tb]%% *}" "tb__nav"
ft_remove tb

note "a binder with no pages says so"
err ft-binder name=empty parent=main
err end_ft_binder
check "the empty binder is named" \
      "$(case "$ERR" in *"holds pages, and this one holds none"*) echo named ;; *) echo "${ERR:-silent}" ;; esac)" "named"
ft_remove empty

summary
