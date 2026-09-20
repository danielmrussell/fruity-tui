#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  demo/tree-demo.bash — the ft-tree control: a collapsible file browser.
#
#  ↑/↓ move · →/Enter expand a folder (or step in) · ← collapse (or step out) ·
#  Enter on a file "opens" it. The tree keeps `value` = the highlighted node's
#  key, so the status line just reads it in the on_change hook — the same value
#  model as every other control. This is the control the Save-As file dialog
#  will be built from.
#
#  Run:  bash demo/tree-demo.bash
# ─────────────────────────────────────────────────────────────────────────────
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./fruity-tui.bash
ft_init
ft_term_size

_status() { ft-modify status text="$1"; }
fs_on_change()   { _status "selected: $1"; }                 # $1 = node id
fs_on_activate() { _status "opened file → $1"; }             # Enter on a leaf
btnQuit_on_activate() { ft_quit; }

_build() {
    ft-empty app
        ft-frame name=win title=" Samba Mago — pick a file " \
                 display=flex flexDirection=column gap=1 padding=1 alignItems=stretch \
                 borderStyle=double
            ft-tree name=fs rows=12 onChange=fs_on_change onActivate=fs_on_activate
                ft-tree-node "project/"          id="project/"                depth=0 expanded=true
                ft-tree-node   "src/"            id="project/src/"            depth=1 expanded=true
                ft-tree-node     "ft-core.bash"  id="project/src/ft-core.bash" depth=2
                ft-tree-node     "ft-forms.bash" id="project/src/ft-forms.bash" depth=2
                ft-tree-node     "controls/"     id="project/src/controls/"   depth=2 expanded=false
                ft-tree-node       "ft-tree.bash"   id="project/src/controls/ft-tree.bash"   depth=3
                ft-tree-node       "ft-table.bash"  id="project/src/controls/ft-table.bash"  depth=3
                ft-tree-node       "ft-select.bash" id="project/src/controls/ft-select.bash" depth=3
                ft-tree-node   "tests/"          id="project/tests/"          depth=1 expanded=false
                ft-tree-node     "test-tree.bash" id="project/tests/test-tree.bash" depth=2
                ft-tree-node     "test-table.bash" id="project/tests/test-table.bash" depth=2
                ft-tree-node   "README.md"       id="project/README.md"       depth=1
                ft-tree-node   "LICENSE"         id="project/LICENSE"         depth=1
            end_ft_tree

            ft-label name=status text="selected: project/" color=notice width=40
            ft-div name=btnrow display=flex gap=2 justifyContent=center
                ft-button name=btnQuit Quit accessKey=Q onActivate=btnQuit_on_activate
            end_ft_div
        end_ft_frame
    end_ft_form
    ft_refresh
    ft_focus fs
}

ft-form name=app width="$FT_COLS" height="$FT_ROWS" \
        display=flex justifyContent=center alignItems=center \
        keymap '[Qq]'=ft_quit
end_ft_form
ft-run app _build
