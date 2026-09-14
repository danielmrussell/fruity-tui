#!/usr/bin/env bash
# Unit tests for the F1 help system: F1 decode, per-control help gathering
# (instance property → class default → library basics), and first-line-as-title.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null

note "F1 decodes from SS3 (\\eOP), xterm (\\e[11~) and the Linux console (\\e[[A)"
export LC_ALL=C; : "${FT_ESC_DELAY:=0.05}"
for seq in $'\x1bOP' $'\x1b[11~' $'\x1b[[A'; do
    printf '%s' "$seq" > /tmp/fth.$$; exec 7< /tmp/fth.$$; _ft_decode_key 7; exec 7<&-
    check "F1 decodes" "$FT_KTOK" "F1"
done
rm -f /tmp/fth.$$

ft-form name=app width=80 height=24
  ft-textfield name=tf size=20 value="x"
  ft-button    name=bt OK
  ft-label     name=lbl "just text"
  ft-checkbox  name=cbx "Remember"
  ft-select    name=sel size=1
    ft-option value=a "Alpha"
    ft-option value=b "Beta"
  end_ft_select
  ft-tree name=trv rows=4
    ft-tree-node "Root" key=root depth=0
  end_ft_tree
end_ft_form
ft_layout app; FT_ROOT=app

note "a text field ships Emacs (entry 0, the default mode) then Vi (entry 1)"
_ft_help_texts tf
check "two entries"                 "${#FT_HELP_TITLE[@]}" "2"
check "entry 0 label = Emacs"       "${FT_HELP_TITLE[0]}"  "Emacs"
check "entry 0 accessKey = E"           "${FT_HELP_ACCEL[0]}"  "E"
check "entry 1 label = Vi"          "${FT_HELP_TITLE[1]}"  "Vi"
check "entry 1 accessKey = V"           "${FT_HELP_ACCEL[1]}"  "V"
case "${FT_HELP[0]}" in *"copy / cut"*) check "Emacs (entry 0) body lists the clipboard keys" 1 1 ;; *) check "Emacs (entry 0) body lists the clipboard keys" 0 1 ;; esac

note "a control WITH class help now shows its own (button → Button)"
_ft_help_texts bt
check "button one entry" "${#FT_HELP_TITLE[@]}" "1"
check "button title"     "${FT_HELP_TITLE[0]}"  "Button"

note "a control with no class help (a label) falls back to the library basics"
_ft_help_texts lbl
check "one entry"    "${#FT_HELP_TITLE[@]}" "1"
check "basics title" "${FT_HELP_TITLE[0]}"  "Basics"

note "instance helpText2 adds a tab; helpLabel/helpAccel name it; body kept whole"
ft-modify tf helpText2="Hostname
enter a fully-qualified name"
_ft_help_texts tf
check "helpText2 added a 3rd entry"     "${#FT_HELP_TITLE[@]}" "3"
check "no label → first line is title"  "${FT_HELP_TITLE[2]}"  "Hostname"
check "no label → body is the rest"     "${FT_HELP[2]}"        "enter a fully-qualified name"
ft-modify tf helpLabel2="Host" helpAccel2="H"
_ft_help_texts tf
check "helpLabel2 names the tab"        "${FT_HELP_TITLE[2]}"  "Host"
check "helpAccel2 sets the accessKey"       "${FT_HELP_ACCEL[2]}"  "H"
check "with a label, body is the WHOLE text" "${FT_HELP[2]}" $'Hostname\nenter a fully-qualified name'

note "sparse: a missing helpText index builds no tab (indices stay aligned)"
ft-modify tf helpText4="Extra
sparse is fine"
_ft_help_texts tf
check "helpText3 missing → skipped (4 entries, not 5)" "${#FT_HELP_TITLE[@]}" "4"
check "last entry is the helpText4 one"                "${FT_HELP_TITLE[-1]}" "Extra"

note "per-control class help: F1 is about the control you're on"
_ft_help_texts sel; check "select → Select tab"       "${FT_HELP_TITLE[0]}" "Select"
_ft_help_texts trv; check "tree → Tree tab"           "${FT_HELP_TITLE[0]}" "Tree"
_ft_help_texts cbx; check "checkbox → Toggle tab"     "${FT_HELP_TITLE[0]}" "Toggle"

note "the modal context stack restores the caller's screen (root/focus/ring)"
# REAL dialogs, not fabricated state: ft_modal_pop rebuilds the ring from the restored root's
# TREE rather than replaying a snapshot taken at push, because a dialog may add or remove the
# caller's controls while it is open (see tests/test-reach.bash). A synthetic FT_ROOT with no
# children therefore restores an empty ring — correctly, since nothing focusable is there.
root_before_modals=$FT_ROOT
# Build the dialogs FIRST: declaring a form ends by choosing a focus for it, which would
# otherwise clobber the caller's focus between the snapshot and the push.
ft-form name=__modal width=30 height=5
    ft-button name=__m_x "X"
    ft-button name=__m_y "Y"
    ft-button name=__m_z "Z"
end_ft_form
ft_layout __modal
ft-form name=__modal2 width=30 height=5
    ft-button name=__m_p "P"
    ft-button name=__m_q "Q"
end_ft_form
ft_layout __modal2

FT_ROOT=$root_before_modals
ft_focus_ring_build "$FT_ROOT"; ft_focus bt
ring0="${FT_FOCUS_RING[*]}"; root0=$FT_ROOT; focus0=$FT_FOCUS; idx0=$FT_FOCUS_INDEX

ft_modal_push                                   # open a modal that takes over the screen…
FT_ROOT=__modal; ft_focus_ring_build __modal; ft_focus __m_y
ft_modal_push                                   # …and a SECOND one on top of it
FT_ROOT=__modal2; ft_focus_ring_build __modal2; ft_focus __m_q
ft_modal_pop
check "pop 1 restores inner ring"  "${FT_FOCUS_RING[*]}" "__m_x __m_y __m_z"
check "pop 1 restores inner root"  "$FT_ROOT"            "__modal"
check "pop 1 restores inner focus" "$FT_FOCUS"           "__m_y"
ft_modal_pop
check "pop 2 restores caller ring"  "${FT_FOCUS_RING[*]}" "$ring0"
check "pop 2 restores caller root"  "$FT_ROOT"            "$root0"
check "pop 2 restores caller focus" "$FT_FOCUS"           "$focus0"
check "pop 2 restores caller idx"   "$FT_FOCUS_INDEX"       "$idx0"
ft_remove __modal 2>/dev/null; ft_remove __modal2 2>/dev/null

note "About: FT_HELP_ABOUT_FN overrides the default About box"
ABOUT_CALLED=0; myabout() { ABOUT_CALLED=1; }
FT_HELP_ABOUT_FN=myabout; ft_help_about; FT_HELP_ABOUT_FN=""
check "custom About function invoked" "$ABOUT_CALLED" "1"

note "wtfix module: install / uninstall / restore on a synthetic JSONC file"
WTDIR=$(mktemp -d); WTF="$WTDIR/settings.json"
printf '%s\n' '{' '    "actions": [' '        { "command": "copy", "keys": "ctrl+c" },' '    ],' '}' > "$WTF"
cp "$WTF" "$WTDIR/pristine"
ft_wt_find() { FT_RET="$WTF"; return 0; }         # point the fixer at our fake file
ft_wt_status; check "status: not applied initially" "$FT_WINDOWS_TERMINAL_INSTALLED" "0"
ft_wt_install; check "install adds 4 unbinds" "$(grep -c unbound "$WTF")" "4"
ft_wt_install; check "install is idempotent (still 4)" "$(grep -c unbound "$WTF")" "4"
check "original backup was saved" "$([[ -f "$WTF.fruity-original.bak" ]] && echo y)" "y"
ft_wt_uninstall; check "uninstall removes our block" "$(grep -c unbound "$WTF")" "0"
check "uninstall preserves other keys" "$(grep -c ctrl+c "$WTF")" "1"
printf 'GARBAGE\n' >> "$WTF"                        # simulate corruption
ft_wt_restore_original
check "restore_original == pristine" "$(diff -q "$WTF" "$WTDIR/pristine" >/dev/null && echo same)" "same"
rm -rf "$WTDIR"; unset -f ft_wt_find

note "the WT key fix now lives in the Settings modal, not a help tab"
_ft_help_texts tf; _ft_help_build; ft_layout __help
_ft_tabs_tabs __helptabs
LAST=${FT_TABS[-1]}; ft_resolved_prop "$LAST" title ""
check "help's last tab is NOT General anymore" "$([[ "$FT_RET" == General ]] && echo yes || echo no)" "no"
check "no stray General-tab button"            "${FT_TYPE[__helpwtapply]:-none}" "none"
ft_remove __help

summary
