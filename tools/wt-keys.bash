#!/usr/bin/env bash
# wt-keys.bash — CLI for the Windows Terminal key-grab fixer (see ../ft-wtfix.bash).
# Frees Ctrl+Shift+Home/End/Up/Down (WT binds them to scrollback) so a TUI sees them.
#
#   bash tools/wt-keys.bash status      # is it applied? where's settings.json?
#   bash tools/wt-keys.bash install     # free the four chords (backs up first)
#   bash tools/wt-keys.bash uninstall   # remove our block (WT defaults return)
#   bash tools/wt-keys.bash restore     # roll settings.json back to the pristine original
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ft-wtfix.bash"

case "${1:-status}" in
    status)    ft_wt_status; echo "$FT_RET"; [[ -n "$FT_WINDOWS_TERMINAL_PATH" ]] && echo "settings.json: $FT_WINDOWS_TERMINAL_PATH" ;;
    install)   ft_wt_install;          echo "$FT_RET" ;;
    uninstall) ft_wt_uninstall;        echo "$FT_RET" ;;
    restore)   ft_wt_restore_original; echo "$FT_RET" ;;
    *) echo "usage: bash tools/wt-keys.bash [status|install|uninstall|restore]"; exit 2 ;;
esac
