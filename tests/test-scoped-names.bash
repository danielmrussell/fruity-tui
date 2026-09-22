#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  A PAGE IS A NAMING SCOPE, SO TWO PAGES MAY LOOK ALIKE.
#
#  A control declared inside a page (or a screen) is qualified with its scope's name, and
#  because a scope's own name is already qualified the chain builds the full path by itself:
#
#      ft-screen name=main / ft-page name=login / ft-textfield name=email
#         → the control's real name is  main__login__email
#
#  You address it as `login.email`, as `email`, or by the full path. ONE RULE covers all three:
#  a name matches a control whose full name ENDS WITH IT on a segment boundary.
#
#    · FOR A VERB, exactly one control must answer. Two pages that both hold an `email` make a
#      bare `email` ambiguous, and an error naming the candidates is the only honest answer —
#      the alternative is acting on whichever happened to be declared first.
#    · FOR A SELECTOR, every match applies. `#email` styles the email field on every page and
#      `#login__email` styles one: less specific, more controls, which is what a selector is
#      for. Styling several is the point; addressing several is a bug.
#
#  THE SEPARATOR IS `__`, NOT `.`, wherever the framework stores or matches a name: a name
#  becomes part of a bash VARIABLE name (`_ftp_<name>_<prop>`) and a dot is not legal in one,
#  and in a selector a `.` starts a CLASS. The verbs accept either spelling.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=60; FT_ROWS=16
_E=$(mktemp "${TMPDIR:-/tmp}/ft-scope.XXXXXX"); trap 'rm -f "$_E"' EXIT
err() { "$@" 2>"$_E"; ERR=$(sed -n '1s/^ft: //p' "$_E"); }

ft_stylesheet name=sheet style='
  #email        { color: 200 }
  #login__email { color: 44 }
'
ft-app name=installer
    ft-screen name=main
        ft-binder name=wizard startPage=login
            ft-page name=login
                ft-textfield name=email size=10
                ft-button name=go text="Go"
            end_ft_page
            ft-page name=invite
                ft-textfield name=email size=10
            end_ft_page
        end_ft_binder
    end_ft_screen
    ft-screen name=other
        ft-button name=go text="Go"
    end_ft_screen
end_ft_app
FT_ROOT=installer; ft_layout installer

note "a scope qualifies the names declared inside it"
check "the field's real name is a path" "${FT_TYPE[main__login__email]:-missing}" "textfield"
check "…and so is its neighbour's"      "${FT_TYPE[main__invite__email]:-missing}" "textfield"
check "the page itself is qualified"    "${FT_TYPE[main__login]:-missing}" "page"
check "the screen is not (nothing above it is a scope)" "${FT_TYPE[main]:-missing}" "screen"
# The binder is NOT a scope — it holds pages, and the pages do the scoping.
check "a binder does not qualify"       "${FT_TYPE[main__wizard]:-missing}" "binder"

note "one rule addresses it: a tail of the path, on a segment boundary"
_ft_ctl main__login__email; check "the full path"      "$FT_RET" "main__login__email"
_ft_ctl login.email;        check "a tail, dotted"     "$FT_RET" "main__login__email"
_ft_ctl login__email;       check "a tail, underscored" "$FT_RET" "main__login__email"
_ft_ctl invite.email;       check "the other page's"   "$FT_RET" "main__invite__email"
_ft_ctl nosuchthing;        check "an unknown name is handed back" "$FT_RET" "nosuchthing"
# A tail must land on a boundary: `mail` is not a control, however much of `email` it spells.
_ft_ctl mail;               check "a partial segment matches nothing" "$FT_RET" "mail"

note "for a VERB, exactly one control must answer"
ft_set login.email value="admin"
check "the path wrote the right one"  "$(ft_get login.email value; printf '%s' "$FT_RET")" "admin"
check "…and not its namesake"         "$(ft_get invite.email value; printf '%s' "$FT_RET")" ""
err ft_set email value="oops"
check "a bare name that is ambiguous is refused" \
      "$(case "$ERR" in *'"email" names more than one control'*) echo refused ;; *) echo "${ERR:-silent}" ;; esac)" "refused"
check "…and it names the candidates" \
      "$(case "$ERR" in *main__invite__email*main__login__email*|*main__login__email*main__invite__email*) echo named ;; *) echo missing ;; esac)" "named"
check "…and wrote neither"            "$(ft_get login.email value; printf '%s' "$FT_RET")/$(ft_get invite.email value; printf '%s' "$FT_RET")" "admin/"
# The same letters in two SCREENS are just as ambiguous as in two pages.
err ft_focus go
check "two screens with a 'go' are ambiguous too" \
      "$(case "$ERR" in *'names more than one control'*) echo refused ;; *) echo "${ERR:-silent}" ;; esac)" "refused"
_ft_ctl other.go; check "…until you say which"  "$FT_RET" "other__go"

note "for a SELECTOR, every match applies — that is what a selector is for"
ft_style main__invite__email color; check "#email reached the page with no rule of its own" "$FT_RET" "200"
ft_style main__login__email  color; check "#login__email is more specific, and wins"        "$FT_RET" "44"

# SCOPING IS LEXICAL — a name is qualified by the scope it is WRITTEN inside, not by wherever
# `parent=` later attaches it. The name you wrote stays the name you can address.
note "parent= moves a control without renaming it"
ft-page name=stray parent=main__wizard
    ft-label name=inside text="written in a page"
end_ft_page
ft-label name=outside parent=main__login text="parented into one"
# `stray` is itself written at top level, so IT is bare — and it still scopes its own children.
check "written inside a page is qualified"  "${FT_TYPE[stray__inside]:-missing}" "label"
check "…parented into one is not"           "${FT_TYPE[outside]:-missing}" "label"

note "a control outside every scope is addressed exactly as before"
ft-form name=plain width=20 height=4
    ft-label name=solo text="x"
end_ft_form
check "its name is untouched"      "${FT_TYPE[solo]:-missing}" "label"
_ft_ctl solo; check "…and resolves to itself" "$FT_RET" "solo"
ft_set solo text="y"
check "…and the verbs reach it"    "$(ft_get solo text; printf '%s' "$FT_RET")" "y"

summary
