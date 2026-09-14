#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — ft-wtfix.bash   (Windows Terminal key-grab fixer)
#
#  Windows Terminal (and conhost) bind Ctrl+Shift+Home/End/Up/Down to scrollback,
#  so those chords never reach a TUI. This module frees them by adding four
#  `"command":"unbound"` entries to the user's settings.json — safely: it keeps a
#  pristine ORIGINAL backup the very first time it touches the file, tags its own
#  block with sentinels (idempotent, cleanly removable), and tolerates the JSONC
#  (comments + trailing commas) WT allows. WT hot-reloads, so edits apply live.
#
#  Every entry point sets FT_RET to a human message; the mutating ones return 0 on
#  success. Also usable from the CLI via tools/wt-keys.bash. Safe no-op off Windows.
#
#  This runs only on explicit user action (a button / a CLI call), never in a
#  render or input hot path, so cp/grep/awk forks here are fine.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_WTFIX_LOADED:-}" ]] && return 0
_FT_WTFIX_LOADED=1

FT_WINDOWS_TERMINAL_PATH=""            # settings.json location (set by ft_wt_status)
FT_WINDOWS_TERMINAL_INSTALLED=0        # 1 when our unbind block is present
_FT_WINDOWS_TERMINAL_OPEN='// >>> fruity-tui unbind (Ctrl+Shift nav) — managed, do not edit inside'
_FT_WINDOWS_TERMINAL_CLOSE='// <<< fruity-tui unbind'
_FT_WINDOWS_TERMINAL_BLOCK="        $_FT_WINDOWS_TERMINAL_OPEN
        { \"command\": \"unbound\", \"keys\": \"ctrl+shift+home\" },
        { \"command\": \"unbound\", \"keys\": \"ctrl+shift+end\" },
        { \"command\": \"unbound\", \"keys\": \"ctrl+shift+up\" },
        { \"command\": \"unbound\", \"keys\": \"ctrl+shift+down\" },
        $_FT_WINDOWS_TERMINAL_CLOSE"

# ft_wt_find → FT_RET = settings.json path, or "". Works across the ways a POSIX
# shell reaches the Windows filesystem: WSL (/mnt/c), Git Bash/MSYS (/c + the
# Windows $LOCALAPPDATA env var, which those shells DO expose), and Cygwin
# (/cygdrive/c). We build candidate LocalAppData dirs from all of them.
ft_wt_find() {
    FT_RET=""
    local -a bases=()
    # $LOCALAPPDATA is set in Git Bash/MSYS/Cygwin (a Windows env), e.g.
    # C:\Users\me\AppData\Local — map it to this shell's mount style.
    if [[ -n "${LOCALAPPDATA:-}" ]]; then
        local la=${LOCALAPPDATA//\\//}                    # backslashes → slashes
        local drv=${la%%:*} rest=${la#*:}                 # C , /Users/me/AppData/Local
        bases+=( "$la" "/${drv,,}$rest" "/mnt/${drv,,}$rest" "/cygdrive/${drv,,}$rest" )
    fi
    bases+=( /mnt/c/Users/*/AppData/Local /c/Users/*/AppData/Local /cygdrive/c/Users/*/AppData/Local )
    local base p
    for base in "${bases[@]}"; do
        [[ -d "$base" ]] || continue
        for p in \
            "$base"/Packages/Microsoft.WindowsTerminal_*/LocalState/settings.json \
            "$base"/Packages/Microsoft.WindowsTerminalPreview_*/LocalState/settings.json \
            "$base/Microsoft/Windows Terminal/settings.json"; do
            [[ -f "$p" ]] && { FT_RET=$p; return 0; }
        done
    done
    return 1
}

# ft_wt_status → sets FT_WINDOWS_TERMINAL_PATH / FT_WINDOWS_TERMINAL_INSTALLED, FT_RET = message. 1 if no WT.
ft_wt_status() {
    if ! ft_wt_find; then
        FT_WINDOWS_TERMINAL_PATH=""; FT_WINDOWS_TERMINAL_INSTALLED=0
        FT_RET="Windows Terminal not detected — nothing to fix here."
        return 1
    fi
    FT_WINDOWS_TERMINAL_PATH=$FT_RET
    if grep -qF "$_FT_WINDOWS_TERMINAL_OPEN" "$FT_WINDOWS_TERMINAL_PATH"; then
        FT_WINDOWS_TERMINAL_INSTALLED=1; FT_RET="Applied — Ctrl+Shift+Home/End/Up/Down reach the app."
    else
        FT_WINDOWS_TERMINAL_INSTALLED=0; FT_RET="Not applied — WT still owns Ctrl+Shift+Home/End/Up/Down."
    fi
    return 0
}

# Save a pristine, once-only backup of the untouched file (for "restore original").
_ft_wt_save_original() {
    local f=$1 orig="$1.fruity-original.bak"
    [[ -f "$orig" ]] || cp -p "$f" "$orig" 2>/dev/null
}

# ft_wt_install → add the unbind block (idempotent). FT_RET = message.
ft_wt_install() {
    ft_wt_status || return 1
    local f=$FT_WINDOWS_TERMINAL_PATH
    if (( FT_WINDOWS_TERMINAL_INSTALLED )); then FT_RET="Already applied. ($f)"; return 0; fi
    _ft_wt_save_original "$f"
    local keyline broff line
    keyline=$(grep -nE '"(actions|keybindings)"[[:space:]]*:' "$f" | head -1 | cut -d: -f1)
    if [[ -n "$keyline" ]]; then
        broff=$(tail -n +"$keyline" "$f" | grep -nE '\[' | head -1 | cut -d: -f1)
        [[ -n "$broff" ]] && line=$(( keyline + broff - 1 ))
    fi
    if [[ -z "${line:-}" ]]; then
        FT_RET="Couldn't find an \"actions\" array in settings.json — edit it by hand."
        return 1
    fi
    cp -p "$f" "$f.fruity-$(date +%Y%m%d-%H%M%S).bak" 2>/dev/null
    if { head -n "$line" "$f"; printf '%s\n' "$_FT_WINDOWS_TERMINAL_BLOCK"; tail -n +"$((line+1))" "$f"; } > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"; then
        FT_WINDOWS_TERMINAL_INSTALLED=1
        FT_RET="Done — Ctrl+Shift+Home/End/Up/Down now reach the app."
        return 0
    fi
    rm -f "$f.tmp"; FT_RET="Write failed (permissions?)."; return 1
}

# ft_wt_uninstall → remove ONLY our block (WT's scrollback bindings return).
ft_wt_uninstall() {
    ft_wt_status || return 1
    local f=$FT_WINDOWS_TERMINAL_PATH
    if (( ! FT_WINDOWS_TERMINAL_INSTALLED )); then FT_RET="Nothing of ours to remove."; return 0; fi
    cp -p "$f" "$f.fruity-$(date +%Y%m%d-%H%M%S).bak" 2>/dev/null
    if awk -v o="$_FT_WINDOWS_TERMINAL_OPEN" -v c="$_FT_WINDOWS_TERMINAL_CLOSE" '
            index($0,o){skip=1} skip{ if(index($0,c)){skip=0}; next } {print}
         ' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"; then
        FT_WINDOWS_TERMINAL_INSTALLED=0
        FT_RET="Restored — Windows Terminal's default scrollback keys are back."
        return 0
    fi
    rm -f "$f.tmp"; FT_RET="Write failed (permissions?)."; return 1
}

# ft_wt_restore_original → overwrite settings.json with the pristine first backup,
# for when a crash/power-off left things in a weird state.
ft_wt_restore_original() {
    if ! ft_wt_find; then FT_RET="Windows Terminal not detected."; return 1; fi
    local f=$FT_RET orig="$FT_RET.fruity-original.bak"
    if [[ ! -f "$orig" ]]; then FT_RET="No saved original backup found (we never modified this file)."; return 1; fi
    cp -p "$f" "$f.fruity-$(date +%Y%m%d-%H%M%S).bak" 2>/dev/null
    if cp -p "$orig" "$f" 2>/dev/null; then
        FT_WINDOWS_TERMINAL_INSTALLED=0
        FT_RET="Restored settings.json to the exact state before we first touched it."
        return 0
    fi
    FT_RET="Write failed (permissions?)."; return 1
}

# ── Self-healing invisible lifecycle ─────────────────────────────────────────
# The "invisible" contract: while our app runs, the keys are freed; the moment it
# exits (any catchable signal), settings.json is put back exactly as it was. The
# sentinel comment IN the file is the flag — it can't drift from reality — and the
# pristine copy lives in the sibling *.fruity-original.bak. If a run is `kill -9`'d
# (SIGKILL is uncatchable) the sentinel survives; the NEXT run sees it and heals
# from the backup before re-applying, so the dirty window closes on relaunch.
FT_WINDOWS_TERMINAL_APPLIED=0                 # 1 ⇒ THIS process applied the fix and owes a restore

# Call once at startup (opt-in by the app). Heals a crashed prior run, then applies.
ft_wt_autofix_enter() {
    ft_wt_status || return 0                    # not Windows Terminal → no-op
    (( FT_WINDOWS_TERMINAL_INSTALLED )) && ft_wt_restore_original >/dev/null 2>&1   # stale sentinel ⇒ heal
    if ft_wt_install >/dev/null 2>&1; then FT_WINDOWS_TERMINAL_APPLIED=1; fi
    return 0
}

# Call from the restore path (EXIT + every catchable termination). Idempotent.
ft_wt_autofix_exit() {
    (( FT_WINDOWS_TERMINAL_APPLIED )) || return 0
    FT_WINDOWS_TERMINAL_APPLIED=0
    ft_wt_restore_original >/dev/null 2>&1 || ft_wt_uninstall >/dev/null 2>&1
    return 0
}
