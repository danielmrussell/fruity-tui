#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tests/test-accesskey.bash — an underlined letter must actually do something.
#
#  A control with accessKey=X draws an underlined X, which is a PROMISE. Nothing checked that
#  the promise could be kept, and it silently could not be in demo/css-demo.bash: a `Bold`
#  checkbox offered B on a page whose app-level `[Bb]` cap paged backwards. The checkbox
#  rendered perfectly, the key did something plausible, and every test passed.
#
#  SHARING a letter is a deliberate feature — the key activates the first sharer that is
#  enabled and visible — so this must not flag that. What it flags is a plain binding for the
#  same letter on the same keymap: lookup takes the LAST registration, so the override wins
#  outright and the "first enabled sharer wins" contract quietly stops holding.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=80; FT_ROWS=24

note "an accelerator nothing overrides is fine"
ft-form name=f1 width=60 height=8
    ft-button name=b1 "Save" accessKey=S
    ft-button name=b2 "Load" accessKey=L
end_ft_form
ft_layout f1; FT_ROOT=f1
ok "two distinct letters, both reachable" ft_accesskey_conflicts

note "SHARING a letter is a feature, not a conflict"
# "Hide" and "Unhide" may both own H — the key activates whichever is enabled and visible.
ft_remove f1
ft-form name=f2 width=60 height=8
    ft-button name=hide   "Hide"   accessKey=H
    ft-button name=unhide "Unhide" accessKey=H
end_ft_form
ft_layout f2; FT_ROOT=f2
ok "two controls sharing H is not reported" ft_accesskey_conflicts

note "…but a plain binding for the same letter silently wins, and that IS a conflict"
ft_keymap_set "${FT_KEYMAP[f2]}" key='[Hh]' onKey=ft_quit
no "an override on a SHARED letter is reported" ft_accesskey_conflicts
case "$FT_RET" in
    *"hide H ft_quit"*)   check "…naming the control that lost its shortcut" 1 1 ;;
    *)                    check "…naming the control that lost its shortcut" "$FT_RET" "hide H ft_quit" ;;
esac

note "an app relabelling its OWN button's key is not a conflict"
# The common, deliberate case: one control owns the letter and the app rebinds it to a
# labelled cap that does the same thing. Flagging that would make the check noise.
ft_remove f2
ft-form name=f3 width=60 height=8
    ft-button name=quit "Quit" accessKey=Q onActivate=ft_quit
end_ft_form
ft_layout f3; FT_ROOT=f3
ft_keymap_set "${FT_KEYMAP[f3]}" \
    key='[Qq]' keyCap="Quit" keyImp=40 onKey=ft_quit
ok "a single owner's relabelled cap passes" ft_accesskey_conflicts

note "the real app it was found in stays clean"
# css-demo, sourced with its run loop stripped, on the page that had the collision.
ft_remove f3
export FT_NO_WTFIX=1
noloop="$here/demo/.akey-css-demo.bash"
sed '/^ft-run app/d' "$here/demo/css-demo.bash" > "$noloop"
trap 'rm -f "$noloop"' EXIT
source "$noloop" >/dev/null 2>&1
FT_COLS=118; FT_ROWS=40
for page in 1 2 3 4; do
    PAGE=$page; _show_page >/dev/null 2>&1
    settle >/dev/null 2>&1   # ft-run settles the burst; a gate must too
    if ft_accesskey_conflicts; then
        check "css-demo page $page: every underlined letter works" 1 1
    else
        check "css-demo page $page: every underlined letter works" "${FT_RET//$'\n'/; }" ""
    fi
done

summary
