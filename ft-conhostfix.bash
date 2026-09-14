#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — ft-conhostfix.bash   (conhost console-font fixer)
#
#  The classic Windows console (conhost) renders Unicode fine — IF its font has
#  the glyphs. The usual default, Lucida Console, carries the LIGHT box-drawing
#  set (─ │ ┌ ┐) and the doubles (═ ║ ╔) but NOT the HEAVY set (━ ┃ ┏ ┓ ┗ ┛), and
#  its block-element coverage is thin. So a border draws, and then every heavy
#  glyph — the whole thickening half of our shimmer — comes out as a missing-glyph
#  box. It reads as "conhost can't do Unicode" when the truth is narrower and
#  fixable: the FONT can't, and the console picks the font.
#
#  Consolas ships with every supported Windows, is fixed-pitch, and covers the
#  full box-drawing (U+2500–257F) and block-element (U+2580–259F) ranges. Pointing
#  conhost at it is the whole fix.
#
#  Console font lives in the registry (HKCU\Console — defaults, plus one subkey per
#  launched executable, keyed by its mangled path). We back the originals up on
#  first touch and can put them back exactly, byte for byte.
#
#  ── THE CATCH, up front ──────────────────────────────────────────────────────
#  conhost reads its font ONCE, when the window is created. Nothing we write here
#  can re-font a window that is already open: unlike Windows Terminal (which hot-
#  reloads settings.json, which is why ft-wtfix can apply live), this only takes
#  effect in the NEXT console window. Apply, then reopen. There is no API a WSL
#  process can call to change a live conhost window's font — SetCurrentConsoleFontEx
#  is Win32, callable only from a Windows process attached to that console.
#
#  Also: a console launched from a SHORTCUT (.lnk) takes its font from properties
#  stored inside the .lnk, which override the registry entirely. If you launch WSL
#  from a pinned taskbar/Start shortcut and this seems to do nothing, that is why —
#  fix it in the shortcut's Properties → Font, or launch from the Run dialog.
#
#  Every entry point sets FT_RET to a human message; mutating ones return 0 on
#  success. Usable from the CLI via tools/conhost-font.bash. Safe no-op off Windows.
#
#  This runs only on explicit user action (a button / a CLI call), never in a
#  render or input hot path, so forks here are fine.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_CONHOSTFIX_LOADED:-}" ]] && return 0
_FT_CONHOSTFIX_LOADED=1

FT_CONHOST_REG=""             # path to reg.exe ("" = not on Windows)
FT_CONHOST_FACE=""            # the face conhost will use for a new window
FT_CONHOST_KEY='HKCU\Console' # the defaults key: what a launcher with no subkey inherits
FT_CONHOST_APPLIED=0          # 1 when our font is in place
FT_CONHOST_GOOD_FACE="Consolas"
_FT_CONHOST_FF_TRUETYPE=54    # FontFamily: TrueType (raster fonts use 0/48)

# Faces known to LACK the heavy box-drawing set — the reason a border shimmer
# turns into a row of tofu. Not exhaustive; it is the "we know this one is bad"
# list, and anything unrecognised is left alone rather than second-guessed.
_FT_CONHOST_BAD_FACES='Terminal|Lucida Console|Courier|Fixedsys|MS Gothic|Raster Fonts'

_ft_ch_backup_dir() { FT_RET="${XDG_CONFIG_HOME:-$HOME/.config}/fruity-tui"; }

# ft_ch_find → FT_RET = reg.exe path, or "". Mirrors ft_wt_find's reach across the
# ways a POSIX shell sees Windows (WSL /mnt/c, Git Bash /c, Cygwin /cygdrive/c).
ft_ch_find() {
    FT_RET=""; FT_CONHOST_REG=""
    local c
    for c in /mnt/c/Windows/System32/reg.exe /c/Windows/System32/reg.exe \
             /cygdrive/c/Windows/System32/reg.exe "$(command -v reg.exe 2>/dev/null)"; do
        [[ -n "$c" && -x "$c" ]] && { FT_CONHOST_REG=$c; FT_RET=$c; return 0; }
    done
    return 1
}

# _ft_ch_get KEY VALUE → FT_RET = the data, or "" if unset. reg.exe prints
#   <tab>Name<tab>TYPE<tab>Data
# and (being a Windows program) terminates lines with CRLF, which will silently
# poison any comparison if it is not stripped.
_ft_ch_get() {              # key value
    FT_RET=""
    [[ -n "$FT_CONHOST_REG" ]] || return 1
    local line
    line=$("$FT_CONHOST_REG" query "$1" /v "$2" 2>/dev/null | grep -iE "[[:space:]]$2[[:space:]]") || return 1
    line=${line%$'\r'}
    # Data is everything after the type field; a face name may contain spaces.
    FT_RET=$(printf '%s' "$line" | sed -E 's/.*REG_(SZ|DWORD|EXPAND_SZ)[[:space:]]+//; s/[[:space:]]+$//')
    [[ -n "$FT_RET" ]]
}

_ft_ch_set() {              # key value type data
    [[ -n "$FT_CONHOST_REG" ]] || return 1
    "$FT_CONHOST_REG" add "$1" /v "$2" /t "$3" /d "$4" /f >/dev/null 2>&1
}

# ft_ch_status → FT_RET = a human summary; sets FT_CONHOST_FACE / FT_CONHOST_APPLIED.
ft_ch_status() {
    FT_CONHOST_FACE=""; FT_CONHOST_APPLIED=0
    if ! ft_ch_find; then
        FT_RET="Not on Windows — nothing to fix (conhost is a Windows console)."
        return 1
    fi
    _ft_ch_get "$FT_CONHOST_KEY" FaceName && FT_CONHOST_FACE=$FT_RET
    local ff=""; _ft_ch_get "$FT_CONHOST_KEY" FontFamily && ff=$FT_RET
    if [[ "$FT_CONHOST_FACE" == "$FT_CONHOST_GOOD_FACE" ]]; then
        FT_CONHOST_APPLIED=1
        FT_RET="conhost font is $FT_CONHOST_FACE — heavy box drawing will render."
        return 0
    fi
    if [[ -z "$FT_CONHOST_FACE" ]]; then
        # No face set at all: conhost falls back to its built-in default, which on
        # a legacy profile is the RASTER font (no box drawing worth the name). We
        # cannot read that fallback from here — only that nothing overrides it.
        FT_RET="conhost has NO font set (FontFamily=${ff:-0}) — it will use its built-in default, which may be the raster font. Apply to pin $FT_CONHOST_GOOD_FACE."
        return 0
    fi
    if [[ "$FT_CONHOST_FACE" =~ ^($_FT_CONHOST_BAD_FACES)$ ]]; then
        FT_RET="conhost font is '$FT_CONHOST_FACE', which has no HEAVY box drawing (━ ┃ ┏) — that is why borders look broken. Apply to switch to $FT_CONHOST_GOOD_FACE."
        return 0
    fi
    FT_RET="conhost font is '$FT_CONHOST_FACE' — unrecognised; leaving it alone. If glyphs look wrong, apply to switch to $FT_CONHOST_GOOD_FACE."
    return 0
}

# ft_ch_apply — pin Consolas + a UTF-8 codepage for NEW console windows.
# Saves the originals the first time so restore is exact.
ft_ch_apply() {
    ft_ch_find || { FT_RET="Not on Windows — nothing to do."; return 1; }
    local dir; _ft_ch_backup_dir; dir=$FT_RET
    mkdir -p "$dir" 2>/dev/null
    local orig="$dir/conhost-font.orig"
    if [[ ! -f "$orig" ]]; then          # pristine snapshot, taken exactly once
        local f="" ff="" cp="" fs=""
        _ft_ch_get "$FT_CONHOST_KEY" FaceName    && f=$FT_RET
        _ft_ch_get "$FT_CONHOST_KEY" FontFamily  && ff=$FT_RET
        _ft_ch_get "$FT_CONHOST_KEY" CodePage    && cp=$FT_RET
        _ft_ch_get "$FT_CONHOST_KEY" FontSize    && fs=$FT_RET
        {   printf 'FaceName=%s\n'   "$f"
            printf 'FontFamily=%s\n' "$ff"
            printf 'CodePage=%s\n'   "$cp"
            printf 'FontSize=%s\n'   "$fs"
        } > "$orig"
    fi
    _ft_ch_set "$FT_CONHOST_KEY" FaceName   REG_SZ    "$FT_CONHOST_GOOD_FACE"      || { FT_RET="Could not write the console font (reg.exe failed)."; return 1; }
    _ft_ch_set "$FT_CONHOST_KEY" FontFamily REG_DWORD "$_FT_CONHOST_FF_TRUETYPE"
    _ft_ch_set "$FT_CONHOST_KEY" CodePage   REG_DWORD 65001
    # A TrueType face with FontSize=0 lets conhost pick a size, and it sometimes
    # picks a silly one. Only set a size if none was chosen — never stomp a size
    # the user deliberately set.
    local fs=""; _ft_ch_get "$FT_CONHOST_KEY" FontSize && fs=$FT_RET
    if [[ -z "$fs" || "$fs" == "0x0" || "$fs" == "0" ]]; then
        _ft_ch_set "$FT_CONHOST_KEY" FontSize REG_DWORD 0x00100000   # hi word = 16px cell height
    fi
    FT_CONHOST_APPLIED=1
    FT_RET="Pinned $FT_CONHOST_GOOD_FACE + UTF-8 (65001) for new consoles. THIS WINDOW KEEPS ITS OLD FONT — conhost reads the font only at startup, so open a NEW console to see it."
    return 0
}

# ft_ch_restore — put back exactly what was there before we first touched it.
ft_ch_restore() {
    ft_ch_find || { FT_RET="Not on Windows — nothing to do."; return 1; }
    local dir; _ft_ch_backup_dir; dir=$FT_RET
    local orig="$dir/conhost-font.orig"
    [[ -f "$orig" ]] || { FT_RET="No backup found — we never changed anything."; return 1; }
    local line k v
    while IFS= read -r line; do
        k=${line%%=*}; v=${line#*=}
        if [[ -z "$v" ]]; then
            "$FT_CONHOST_REG" delete "$FT_CONHOST_KEY" /v "$k" /f >/dev/null 2>&1   # was unset → unset it
        else
            case "$k" in
                FaceName) _ft_ch_set "$FT_CONHOST_KEY" "$k" REG_SZ    "$v" ;;
                *)        _ft_ch_set "$FT_CONHOST_KEY" "$k" REG_DWORD "$v" ;;
            esac
        fi
    done < "$orig"
    rm -f "$orig"
    FT_CONHOST_APPLIED=0
    FT_RET="Restored the original console font settings. Open a new console to see it."
    return 0
}
