#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  A three-page wizard: an app, one screen, a binder full of pages.
#
#  This is the whole program. There is no resize handler, no globals holding what the user
#  typed, and no rebuilding a page to show it again — the pages keep their own state because
#  they are still there when they are not on screen.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/fruity-tui.bash"
ft_init

summarise() {                   # read the fields and say what we would do
    local host user comp
    ft_get setup.host  value host
    ft_get setup.user  value user
    ft_radio_value comp comp
    ft_set review.blurb text="Join $host as $user, compression $comp."
}

ft-app name=installer
    ft-screen name=wiz
        ft-heading name=title text="Samba Mago — domain setup"

        ft-binder name=pages navigator=pager navigatorSide=bottom startPage=welcome
            ft-page name=welcome title="Welcome"
                ft-label name=intro text="This will join a machine to your domain."
                ft-label name=hint  text="Use ◀ and ▶ below, or Tab to the buttons."
            end_ft_page

            ft-page name=setup title="Details"
                ft-label     name=hostLabel text="Domain controller"
                ft-textfield name=host size=28 value="dc1.example.com"
                ft-label     name=userLabel text="Administrator"
                ft-textfield name=user size=28 value="administrator"
                ft-label     name=compLabel text="Compression"
                ft-radio name=none group=comp value=none text="None" accessKey=n
                ft-radio name=fast group=comp value=fast text="Fast" accessKey=f checked=true
                ft-radio name=best group=comp value=best text="Best" accessKey=b
            end_ft_page

            ft-page name=review title="Review"
                ft-label  name=blurb text="(nothing yet)"
                ft-button-ok name=go text="Join" onActivate='ft_set wiz.status status="Joining…"'
            end_ft_page
        end_ft_binder

        # Outside the binder, so it survives every page turn.
        ft-statusbar name=status status="Tab moves · Enter edits a field · Q quits"
    end_ft_screen
end_ft_app

# Recompute the review line whenever the binder lands on it. `onChange` on a binder is the page
# turn itself, and the handler is code, so there is no named function to invent for one line.
ft_set pages onChange='[[ "$1" == *review ]] && summarise'
ft_set wiz key='[Qq]' keyCap=Quit keyImp=normal onKey=ft_quit

ft_run installer
