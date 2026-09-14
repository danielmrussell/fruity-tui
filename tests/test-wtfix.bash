#!/usr/bin/env bash
# Tests for ft-wtfix.bash: the JSONC-safe install/uninstall/restore and the
# self-healing invisible lifecycle (apply on enter, restore on exit, heal on the
# next run after a kill -9). All against a throwaway file — never real settings.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/ft-wtfix.bash"

D=$(mktemp -d)
FAKE="$D/settings.json"
make_fresh() { printf '%s\n' '{' '    // JSONC comments + trailing commas' '    "actions": [' '        { "command": "copy", "keys": "ctrl+c" },' '    ],' '}' > "$FAKE"; cp "$FAKE" "$D/pristine"; }
ft_wt_find() { FT_RET="$FAKE"; return 0; }        # never touch real WT
unbinds() { grep -c '"command": "unbound"' "$FAKE"; }
same_as_pristine() { diff -q "$FAKE" "$D/pristine" >/dev/null && echo same || echo differ; }

note "install / uninstall / idempotency on a JSONC file"
make_fresh
ft_wt_install;   check "install adds 4 unbinds"          "$(unbinds)" "4"
ft_wt_install;   check "install idempotent (still 4)"    "$(unbinds)" "4"
check "original backup created"                          "$([[ -f "$FAKE.fruity-original.bak" ]] && echo y)" "y"
ft_wt_uninstall; check "uninstall removes them"          "$(unbinds)" "0"
check "unrelated keybinding preserved"                   "$(grep -c ctrl+c "$FAKE")" "1"

note "invisible lifecycle: enter applies, exit restores to EXACT pristine"
make_fresh; rm -f "$FAKE".fruity-*.bak; FT_WINDOWS_TERMINAL_APPLIED=0
ft_wt_autofix_enter
check "enter set the applied flag"     "$FT_WINDOWS_TERMINAL_APPLIED" "1"
check "enter freed the keys (4)"       "$(unbinds)"     "4"
ft_wt_autofix_exit
check "exit cleared the applied flag"  "$FT_WINDOWS_TERMINAL_APPLIED" "0"
check "exit restored pristine"         "$(same_as_pristine)" "same"
ft_wt_autofix_exit; check "exit is idempotent (still pristine)" "$(same_as_pristine)" "same"

note "kill -9 simulation: sentinel left behind → next run heals, then re-applies"
make_fresh; rm -f "$FAKE".fruity-*.bak; FT_WINDOWS_TERMINAL_APPLIED=0
ft_wt_autofix_enter            # run 1 applies…
FT_WINDOWS_TERMINAL_APPLIED=0                # …then is kill -9'd (no exit restore ran)
check "settings still carry our block after the 'crash'" "$(unbinds)" "4"
ft_wt_autofix_enter            # run 2 starts: should heal, not stack
check "next run did NOT double-apply (still 4, not 8)"   "$(unbinds)" "4"
check "next run re-set the applied flag"                 "$FT_WINDOWS_TERMINAL_APPLIED" "1"
ft_wt_autofix_exit
check "and its exit restores pristine again"             "$(same_as_pristine)" "same"

note "off Windows (no settings.json), everything is a safe no-op"
unset -f ft_wt_find; ft_wt_find() { FT_RET=""; return 1; }
FT_WINDOWS_TERMINAL_APPLIED=0
ft_wt_autofix_enter; check "enter no-ops off Windows"     "$FT_WINDOWS_TERMINAL_APPLIED" "0"
ft_wt_autofix_exit;  check "exit no-ops off Windows"      "$FT_WINDOWS_TERMINAL_APPLIED" "0"

rm -rf "$D"
summary
