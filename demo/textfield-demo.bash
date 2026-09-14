#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  demo/textfield-demo.bash — the editable text input (ft-textfield).
#
#  Two fields with live readline editing, a mode indicator, and a Save button
#  that just READS the values (the framework's whole "submit"). Type to edit;
#  arrows / Ctrl chords move and kill; Insert flips insert⇄overwrite; Tab moves
#  between fields; Q or Ctrl+C is NOT bound while typing — use the Quit button.
#
#  Run:  bash demo/textfield-demo.bash
# ─────────────────────────────────────────────────────────────────────────────
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./fruity-tui.bash
ft_init          # sets up the palette (FT_COLOR_*) and input
ft_term_size     # fills FT_COLS / FT_ROWS

_echo() {                       # mirror both field values + the login line
    local user host
    ft_get fUser value user
    ft_get fHost value host
    ft-modify vUser text="user = \"$user\""
    ft-modify vHost text="host = \"$host\""
    ft-modify preview text="login: $user@$host"
}
fUser_on_change() { _echo; }
fHost_on_change() { _echo; }

fUser_on_activate() { ft_focus_next; }   # Enter in a field → next field
fHost_on_activate() { ft_focus_next; }

btnSave_on_activate() {
    local user host
    ft_get fUser value user; ft_get fHost value host
    ft-modify status text="saved:  $user @ $host"
}
btnClear_on_activate() {
    ft-modify fUser value=""; ft-modify fHost value=""
    FT_TEXTFIELD_CARET[fUser]=0; FT_TEXTFIELD_CARET[fHost]=0
    _echo; ft-modify status text="(cleared)"
}

_build() {
    ft-empty app
        ft-frame name=win title="ft-textfield — readline text input" \
                 display=flex flexDirection=column gap=1 padding=1 alignItems=start \
                 borderStyle=double
            ft-label name=help text=\
"Type to edit.  ←/→ or Ctrl+B/F move.  Home/End or Ctrl+A/E jump.
Backspace/Ctrl+H and Del/Ctrl+D delete.  Ctrl+K/U/W kill.
Insert toggles insert (bar caret) vs overwrite (block caret).
The Notes box (rows=5) is the SAME class: Enter makes a new line,
Up/Down walk the wrapped lines. Tab moves between fields." width=66

            ft-div name=rowU display=flex gap=1 alignItems=center
                ft-label name=lUser text="Username" width=9
                ft-textfield name=fUser size=24 value="admin" placeholder="username" onChange=fUser_on_change onActivate=fUser_on_activate
            end_ft_div
            ft-div name=rowH display=flex gap=1 alignItems=center
                ft-label name=lHost text="Hostname" width=9
                ft-textfield name=fHost size=24 placeholder="e.g. dc1.example.com" onChange=fHost_on_change onActivate=fHost_on_activate
            end_ft_div
            ft-div name=rowN display=flex gap=1 alignItems=start
                ft-label name=lNote text="Notes" width=9
                ft-textfield name=fNote size=40 rows=5 \
                             placeholder="A multi-line text box, same ft-textfield class. Type; Enter starts a new line; long lines wrap and it scrolls."
            end_ft_div

            # These mirror the fields on every keystroke, so they are given a WIDTH. An
            # auto-sized label re-measures to fit its text, so each change alters its box and
            # forces a re-layout of everything up to the nearest ancestor with a fixed size —
            # here the form itself. Measured: 115ms per label change auto-sized against 4ms
            # with a width, and a whole keystroke 133ms against 23ms. Anything that retypes
            # itself constantly wants a fixed box; `status` below already had one.
            ft-div name=vals display=flex flexDirection=column gap=0 alignItems=start
                ft-label name=vUser   text="user = \"admin\"" width=48
                ft-label name=vHost   text="host = \"\""      width=48
                ft-label name=preview text="login: admin@"    width=48 color=notice
            end_ft_div

            ft-label name=status text="(nothing saved yet)" width=48 color=notice

            ft-div name=btnrow display=flex gap=2 justifyContent=center
                ft-button name=btnSave  Save  accessKey=S onActivate=btnSave_on_activate
                ft-button name=btnClear Clear accessKey=C onActivate=btnClear_on_activate
                ft-button name=btnQuit  Quit  accessKey=Q onActivate=btnQuit_on_activate
            end_ft_div
        end_ft_frame
    end_ft_form
    ft_refresh
    ft_focus fUser
}

btnQuit_on_activate() { ft_quit; }

ft-form name=app width="$FT_COLS" height="$FT_ROWS" \
        display=flex justifyContent=center alignItems=center
end_ft_form
ft-run app _build
