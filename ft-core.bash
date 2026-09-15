#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — ft-core.bash
#
#  The dependency-free foundation: locale & glyph selection, ANSI constants, a
#  themeable palette, terminal enter/restore, resize handling, screen geometry,
#  and the draw primitives every control is built on.
#
#  Everything here is namespaced under FT_ (globals) and ft_ (functions) so it
#  can be sourced into a host program without clobbering its symbols. Controls
#  live in controls/*.bash and depend only on this file and ft-inputlayer.bash.
#
#  Design notes:
#   - No `tput`/ncurses. We emit raw ANSI; terminals ignore what they can't do.
#   - All output is buffered into FT_OUT and flushed once per frame to fd FT_TTY,
#     so partial redraws never tear and stdout stays clean for captured results.
#   - All colour references go through the palette (ft_setup_palette). Nothing
#     downstream should hardcode an escape; that's what makes theming possible.
# ─────────────────────────────────────────────────────────────────────────────

# Guard against double-sourcing.
[[ -n "${_FT_CORE_LOADED:-}" ]] && return 0
_FT_CORE_LOADED=1

# ── Tunables ─────────────────────────────────────────────────────────────────
FT_MIN_COLS=${FT_MIN_COLS:-40}      # below this we refuse to draw
FT_MIN_ROWS=${FT_MIN_ROWS:-10}
FT_ESC_DELAY=${FT_ESC_DELAY:-0.05}  # seconds to wait for the rest of an escape seq

# Output file descriptor for all drawing. A host that calls ft_enter_tty gets
# fd 3 wired to /dev/tty; a test harness can point FT_TTY elsewhere.
FT_TTY=${FT_TTY:-3}

ft_die() { printf '%s\n' "$*" >&2; exit 1; }

# ── Locale ───────────────────────────────────────────────────────────────────
# We need character-counting (not byte-counting) for box drawing and width math.
# Pick a UTF-8 locale if one exists; otherwise fall back to ASCII line drawing.
FT_USE_UTF8=1
# A collation locale that orders case-INSENSITIVELY, or "" if the system has none. C and
# C.UTF-8 collate by CODEPOINT — every capital before every lowercase — so a listing under
# them reads Apple Date README Zebra apricot banana. This is NOT applied globally: the rest of
# the engine wants predictable byte comparisons, and LC_ALL stays whatever ft_setup_locale
# chose. It is set LOCALLY, for the length of one function, where the ORDER IS USER-VISIBLE —
# see _ft_fd_scan, where it replaces a `sort -f` fork per directory change.
FT_COLLATE=""
ft_setup_locale() {
    # ONE `locale -a`, matched in bash afterwards. This used to run the command inside the
    # candidate loop — up to five pipelines of two processes each, plus a sixth for the
    # fallback: a dozen forks before the first frame, to answer one question.
    local avail cand
    avail=$(locale -a 2>/dev/null)
    avail=$'\n'$avail$'\n'
    have() { [[ "$avail" == *$'\n'"$1"$'\n'* ]]; }
    # Case-insensitive collation: a real language locale. Prefer en_US, else any en_*, and
    # never C/POSIX (which are the codepoint-ordering ones we are trying to avoid).
    for cand in en_US.UTF-8 en_US.utf8 en_GB.UTF-8 en_GB.utf8; do
        have "$cand" && { FT_COLLATE=$cand; break; }
    done
    if [[ -z "$FT_COLLATE" ]]; then
        local line
        while IFS= read -r line; do
            [[ "$line" == [a-z][a-z]_*.[uU][tT][fF]* ]] || continue
            FT_COLLATE=$line; break
        done <<< "$avail"
    fi
    for cand in "${LC_ALL:-}" "${LC_CTYPE:-}" C.UTF-8 C.utf8 en_US.UTF-8; do
        [[ "$cand" == *[Uu][Tt][Ff]* ]] || continue
        if have "$cand" || have "${cand/UTF-8/utf8}"; then
            export LC_ALL="$cand"; unset -f have; return
        fi
    done
    while IFS= read -r cand; do
        [[ "$cand" == *[uU][tT][fF]?(-)8 ]] || continue
        export LC_ALL="$cand"; unset -f have; return
    done <<< "$avail"
    unset -f have
    FT_USE_UTF8=0
}

# ── Glyphs (chosen after locale is known) ────────────────────────────────────
# IMPORTANT: we use raw UTF-8 *byte* escapes ($'\xNN…') rather than $'\uXXXX'.
# bash only expands \u when the locale is UTF-8 at the instant the $'…' is
# evaluated; in a C-locale startup it leaves the literal text "\u250c" behind.
# Byte escapes always produce correct UTF-8 regardless of the current locale,
# which makes the library robust no matter how the host's environment is set.
ft_setup_glyphs() {
    # Overrides for terminals that mis-detect: FT_ASCII=1 forces the ASCII glyph
    # set (use this if box-drawing looks wrong, e.g. classic conhost with a raster
    # font that lacks line glyphs); FT_UTF8=1 forces UTF-8.
    [[ -n "${FT_ASCII:-}" ]] && FT_USE_UTF8=0
    [[ -n "${FT_UTF8:-}"  ]] && FT_USE_UTF8=1
    if (( FT_USE_UTF8 )); then
        FT_GLYPH_TOP_LEFT=$'\xe2\x94\x8c'; FT_GLYPH_TOP_RIGHT=$'\xe2\x94\x90'      # ┌ ┐
        FT_GLYPH_BOTTOM_LEFT=$'\xe2\x94\x94'; FT_GLYPH_BOTTOM_RIGHT=$'\xe2\x94\x98'      # └ ┘
        FT_GLYPH_HORIZONTAL=$'\xe2\x94\x80';  FT_GLYPH_VERTICAL=$'\xe2\x94\x82'       # ─ │
        # Heavy twins of the box set. Unicode gives a true HEAVY weight for every
        # straight and square-corner glyph, so a border can visibly fatten in place
        # — that is what borderWidth=thick draws, and what the activation wave
        # sweeps through one cell at a time.
        FT_GLYPH_HORIZONTAL_HEAVY=$'\xe2\x94\x81'; FT_GLYPH_VERTICAL_HEAVY=$'\xe2\x94\x83'      # ━ ┃
        FT_GLYPH_TOP_LEFT_HEAVY=$'\xe2\x94\x8f'; FT_GLYPH_TOP_RIGHT_HEAVY=$'\xe2\x94\x93'    # ┏ ┓
        FT_GLYPH_BOTTOM_LEFT_HEAVY=$'\xe2\x94\x97'; FT_GLYPH_BOTTOM_RIGHT_HEAVY=$'\xe2\x94\x9b'    # ┗ ┛
        FT_GLYPH_TEE_DOWN=$'\xe2\x94\xac'; FT_GLYPH_TEE_UP=$'\xe2\x94\xb4' # ┬ ┴
        FT_GLYPH_CROSS=$'\xe2\x94\xbc'                            # ┼
        FT_GLYPH_TEE_LEFT=$'\xe2\x94\x9c'; FT_GLYPH_TEE_RIGHT=$'\xe2\x94\xa4'      # ├ ┤
        FT_GLYPH_TREE_BRANCH=$'\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80'   # ├──
        FT_GLYPH_TREE_LAST=$'\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80'     # └──
        FT_GLYPH_CHECK_ON="[x]"; FT_GLYPH_CHECK_OFF="[ ]"
        FT_GLYPH_RADIO_ON=$'\xe2\x97\x8f'; FT_GLYPH_RADIO_OFF=$'\xe2\x97\x8b' # ● ○
        FT_GLYPH_ELLIPSIS=$'\xe2\x80\xa6'                              # …
        FT_GLYPH_TRIANGLE_RIGHT=$'\xe2\x96\xb8'; FT_GLYPH_TRIANGLE_LEFT=$'\xe2\x97\x82' # ▸ ◂
        FT_GLYPH_TRIANGLE_DOWN=$'\xe2\x96\xbe'                            # ▾
        FT_GLYPH_ARROW_UP=$'\xe2\x86\x91'; FT_GLYPH_ARROW_DOWN=$'\xe2\x86\x93'      # ↑ ↓
        FT_GLYPH_ARROW_LEFT_RIGHT=$'\xe2\x86\x94'                               # ↔
        FT_GLYPH_ARROW_LEFT=$'\xe2\x86\x90'; FT_GLYPH_ARROW_RIGHT=$'\xe2\x86\x92'      # ← →
    else
        FT_GLYPH_TOP_LEFT='+'; FT_GLYPH_TOP_RIGHT='+'; FT_GLYPH_BOTTOM_LEFT='+'; FT_GLYPH_BOTTOM_RIGHT='+'
        FT_GLYPH_HORIZONTAL='-';  FT_GLYPH_VERTICAL='|'
        # No heavy weight in ASCII — the heavy twins alias the light ones, so
        # thick borders and the activation wave degrade to no-ops, not mojibake.
        FT_GLYPH_HORIZONTAL_HEAVY='-'; FT_GLYPH_VERTICAL_HEAVY='|'
        FT_GLYPH_TOP_LEFT_HEAVY='+'; FT_GLYPH_TOP_RIGHT_HEAVY='+'; FT_GLYPH_BOTTOM_LEFT_HEAVY='+'; FT_GLYPH_BOTTOM_RIGHT_HEAVY='+'
        FT_GLYPH_TEE_DOWN='+'; FT_GLYPH_TEE_UP='+'; FT_GLYPH_CROSS='+'
        FT_GLYPH_TEE_LEFT='+'; FT_GLYPH_TEE_RIGHT='+'
        FT_GLYPH_TREE_BRANCH='+--'; FT_GLYPH_TREE_LAST='`--'
        FT_GLYPH_CHECK_ON="[x]"; FT_GLYPH_CHECK_OFF="[ ]"
        FT_GLYPH_RADIO_ON='(*)'; FT_GLYPH_RADIO_OFF='( )'
        FT_GLYPH_ELLIPSIS='...'
        FT_GLYPH_TRIANGLE_RIGHT='>'; FT_GLYPH_TRIANGLE_LEFT='<'; FT_GLYPH_TRIANGLE_DOWN='v'
        FT_GLYPH_ARROW_UP='Up'; FT_GLYPH_ARROW_DOWN='Dn'; FT_GLYPH_ARROW_LEFT_RIGHT='<>'; FT_GLYPH_ARROW_LEFT='<-'; FT_GLYPH_ARROW_RIGHT='->'
    fi
}

# ── ANSI constants ───────────────────────────────────────────────────────────
FT_ANSI_RESET=$'\e[0m'
FT_ANSI_BOLD=$'\e[1m';    FT_ANSI_DIM=$'\e[2m';     FT_ANSI_ITALIC=$'\e[3m'
FT_ANSI_UNDERLINE=$'\e[4m';      FT_ANSI_REVERSE=$'\e[7m'
FT_ANSI_ITALIC_OFF=$'\e[23m'; FT_ANSI_UNDERLINE_OFF=$'\e[24m';   FT_ANSI_BOLD_OFF=$'\e[22m'
FT_ANSI_CURSOR_HIDE=$'\e[?25l'; FT_ANSI_CURSOR_SHOW=$'\e[?25h'
# Synchronized output (DEC mode 2026): the terminal buffers everything between ON and
# OFF and presents it as ONE atomic update — no half-drawn frame, no cursor visibly
# skating across the cells as they paint. Supported by Windows Terminal, kitty, iTerm2,
# ghostty, wezterm, …; a terminal that does not know it simply ignores both sequences.
FT_ANSI_SYNC_ON=$'\e[?2026h'; FT_ANSI_SYNC_OFF=$'\e[?2026l'
FT_ANSI_ALT_SCREEN_ON=$'\e[?1049h'; FT_ANSI_ALT_SCREEN_OFF=$'\e[?1049l'
# DECAWM (auto-wrap). A full-screen TUI positions every cell absolutely and never
# relies on wrapping — and with auto-wrap ON, writing the BOTTOM-RIGHT cell makes
# the terminal SCROLL THE WHOLE SCREEN UP one line. Any control that paints the
# full width of the LAST row (the status bar!) would scroll itself away. ncurses
# turns this off for the same reason; we restore it on exit.
FT_ANSI_WRAP_OFF=$'\e[?7l'; FT_ANSI_WRAP_ON=$'\e[?7h'
FT_ANSI_BRACKETED_PASTE_ON=$'\e[?2004h'; FT_ANSI_BRACKETED_PASTE_OFF=$'\e[?2004l'   # bracketed paste on/off
# Mouse: button presses + drag motion, SGR-encoded coords (1006, unbounded x/y).
# With this on, the terminal sends us mouse events instead of doing its own
# line-selection — so our controls can hit-test and select WITHIN their bounds.
FT_ANSI_MOUSE_ON=$'\e[?1000h\e[?1002h\e[?1006h'; FT_ANSI_MOUSE_OFF=$'\e[?1006l\e[?1002l\e[?1000l'
FT_ANSI_CLEAR_SCREEN=$'\e[2J\e[H'  # clear visible screen + home (leaves scrollback alone)
FT_ANSI_ERASE_LINE=$'\e[K'        # erase cursor → end of line

# Position helper: sets FT_CURSOR_POSITION to the CUP escape for 0-based (row,col). No fork.
ft_cursor_position() { printf -v FT_CURSOR_POSITION '\e[%d;%dH' "$(( $1 + 1 ))" "$(( $2 + 1 ))"; }

# Monotonic-ish wall clock in milliseconds, fork-free on bash 5+ (EPOCHREALTIME).
# Used for double-click timing and the animation typing-debounce.
ft_now_ms() {                   # → FT_RET
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        local e=${EPOCHREALTIME/,/.}          # some locales use a comma
        FT_RET=$(( ${e%.*} * 1000 + 10#${e#*.} / 1000 ))
    else
        FT_RET=$(( SECONDS * 1000 ))          # bash 4: 1s granularity
    fi
}
# Wall-clock ms of the last input event, stamped by the input layer. The animation
# engine debounces off this so a border stops animating WHILE you type and resumes
# only once you have paused (see ft_anim_step).
FT_LAST_INPUT_MS=0

# When a control puts the UI into a special MODE the user must deliberately leave
# (a text field's edit or cursor mode), it publishes here how to get out — e.g.
# "Press ESC to exit edit mode …". A status bar shows this loudly (see ft-statusbar):
# the way OUT is the one thing a stuck user needs, and the status bar is easy to miss,
# so we pull ESC to the front, colour it, and sweep the hint to catch the eye. Empty
# = navigation mode (no special exit). This is the mode-EXIT counterpart to the
# ambient border sheen that says "you are IN a control that eats your keystrokes".
FT_MODE_HINT=""

# ── Palette ──────────────────────────────────────────────────────────────────
# A 256-colour dark-slate theme with a monochrome fallback. A host can override
# any FT_COLOR_* after calling ft_setup_palette to re-theme, or replace this function
# wholesale. Backgrounds are carried through every pad so partial redraws don't
# punch holes in the backdrop.
FT_COLOR=1
# THE ATTRIBUTE PALETTE IS THE FLOOR, NOT THE ALTERNATIVE.
#
# These used to live inside the no-colour `else`, which made every FT_COLOR_* merely POSSIBLE
# rather than guaranteed: on the colour path a slot existed only if the active theme happened to
# produce one. _ft_theme_sync then reads some of them back unguarded — `FT_COLOR_FOCUS_BTN=
# $FT_COLOR_FOCUS` — so a theme that defines no focus accent leaves an unbound read, which is
# silent normally and fatal under `set -u` (five demos set it).
#
# Defaulting the one variable that was reported would have been the wrong layer: the hazard is
# not FOCUS, it is that "absent" had no meaning. So the floor is laid FIRST, always, and a theme
# overrides what it actually defines — which the built-in themes do for every slot, so the
# coloured palette is unchanged byte-for-byte (test-theme.bash pins it).
_ft_palette_attributes() {
        FT_COLOR_SCREEN=""; FT_COLOR_BODY=""; FT_COLOR_PANE=""; FT_COLOR_TITLE="$FT_ANSI_BOLD"
        FT_COLOR_BORDER=""; FT_COLOR_HEADING="$FT_ANSI_BOLD"; FT_COLOR_BOX_LINE=""
        FT_COLOR_BOX_TEXT="$FT_ANSI_BOLD"; FT_COLOR_SUBTEXT="$FT_ANSI_BOLD"; FT_COLOR_DIVIDER=""
        # One focus accent (reverse+bold) everywhere; selection is plain reverse.
        FT_COLOR_FOCUS="$FT_ANSI_REVERSE$FT_ANSI_BOLD"
        FT_COLOR_FOCUS_BTN="$FT_COLOR_FOCUS"; FT_COLOR_SEL="$FT_COLOR_FOCUS"; FT_COLOR_SEL_DIM="$FT_ANSI_DIM$FT_ANSI_REVERSE"
        FT_COLOR_BUTTON="$FT_ANSI_REVERSE"; FT_COLOR_THUMB="$FT_ANSI_REVERSE"
        FT_COLOR_INPUT=""; FT_COLOR_KNOB="$FT_ANSI_BOLD"; FT_COLOR_SELECTED="$FT_ANSI_REVERSE"
        FT_COLOR_INPUT_FOCUS="$FT_ANSI_REVERSE"; FT_CURSOR_COLOR=""
        FT_COLOR_STRIPE="$FT_ANSI_DIM"                  # no-color zebra: a dim row
        FT_COLOR_DISABLED_TXT="$FT_ANSI_DIM"
        FT_COLOR_DISABLED="$FT_ANSI_DIM"; FT_COLOR_FADED="$FT_ANSI_DIM"
        FT_COLOR_STATUS="$FT_ANSI_BOLD"; FT_COLOR_HINT="$FT_ANSI_DIM"; FT_COLOR_KEYCAP="$FT_ANSI_REVERSE$FT_ANSI_BOLD"
        FT_COLOR_CARET="$FT_ANSI_REVERSE"; FT_COLOR_CARET_RO="$FT_ANSI_REVERSE$FT_ANSI_DIM"; FT_COLOR_VIEW="$FT_ANSI_BOLD"; FT_COLOR_CAUTION="$FT_ANSI_BOLD"
        FT_COLOR_WARN="$FT_ANSI_BOLD"; FT_COLOR_FIELD="$FT_ANSI_REVERSE"; FT_COLOR_FIELD_LOCKED="$FT_ANSI_DIM"
        FT_COLOR_TEXT_NOTICE="$FT_ANSI_BOLD"; FT_COLOR_TEXT_ACCENT="$FT_ANSI_BOLD"; FT_COLOR_TEXT_MUTED="$FT_ANSI_DIM"
        FT_COLOR_SCROLLING="$FT_ANSI_BOLD"        # the scrolling rung; a theme gives it its own hue
        FT_SHEEN_GLOW=0                           # no colour to bleed without a palette
        FT_COLOR_RESET="$FT_ANSI_RESET"
}
ft_setup_palette() {
    [[ -n "$TERM" && "$TERM" != dumb ]] && FT_COLOR=1 || FT_COLOR=0
    _ft_palette_attributes                       # the floor — every slot has a value from here on
    if (( FT_COLOR )) && declare -F ft_use_theme >/dev/null; then
        # The palette is a STYLESHEET now — the `ft-dark` theme in ft-css.bash, authored in
        # real CSS, NOT a block of hand-written escape codes. ft_use_theme installs it as the
        # low-precedence default sheet AND derives every FT_COLOR_* global from it (_ft_theme_sync),
        # so there is a single source of truth (the CSS), a theme swap is one call, and nothing
        # can drift. `color=accent|notice|muted` and any app stylesheet cascade on top. The dark
        # values it produces are pinned byte-for-byte to the historical palette (test-theme.bash).
        FT_CURSOR_BLINK=1                        # DECSCUSR blink by default (a behaviour, not a colour)
        ft_use_theme ft-dark
    else
        FT_COLOR=0    # no colour — or no CSS engine loaded to theme with — so keep the attribute palette
    fi
}

# ── Named colours (backgroundColor/color/borderColor) ────────────────────────
# A small CSS-ish name → xterm-256 index table so controls can be recoloured
# without callers needing to know palette numbers. A bare integer 0-255 is
# also accepted directly (passthrough), for anyone who wants a specific
# xterm index the table doesn't name. Unknown names/out-of-range numbers are
# invalid — callers treat that the same as "unset" (fall back to the fixed
# palette) rather than crashing the draw path over a typo.
declare -A FT_COLOR_NAMES=(
    [black]=0 [red]=1 [green]=2 [yellow]=3 [blue]=4 [magenta]=5 [cyan]=6 [white]=7
    [gray]=8 [grey]=8
    [brightred]=9 [brightgreen]=10 [brightyellow]=11 [brightblue]=12
    [brightmagenta]=13 [brightcyan]=14 [brightwhite]=15
    [orange]=214 [pink]=213 [purple]=97 [teal]=80 [navy]=17 [gold]=220
    [lime]=46 [brown]=94
    # a curated slice of the extended CSS names (nearest xterm-256), so the common ones
    # a user reaches for resolve; anything not here still works as #hex or rgb().
    [crimson]=161 [tomato]=203 [coral]=209 [salmon]=209 [maroon]=52
    [dodgerblue]=33 [royalblue]=62 [steelblue]=67 [skyblue]=117 [slateblue]=62
    [seagreen]=29 [forestgreen]=28 [olive]=100 [indigo]=54 [violet]=213
    [orchid]=170 [hotpink]=205 [deeppink]=198 [khaki]=222 [tan]=180
    [chocolate]=166 [turquoise]=44 [aqua]=51 [cyan]=6 [fuchsia]=13
    [silver]=250 [darkgray]=240 [darkgrey]=240 [lightgray]=252 [lightgrey]=252
)
# TRUE CSS hex for the extended (non-terminal-palette) names, so `color: crimson` resolves to the
# SAME rgb as `#dc143c` / `rgb(220,20,60)` / `hsl(348,83%,47%)` — not a 256-palette approximation
# that looks different from its own hex. The basic 16 (red/green/…) stay palette indices on
# purpose (they follow the terminal theme). ft_color_sgr checks this FIRST for a name.
declare -A FT_CSS_HEX=(
    [crimson]=dc143c [tomato]=ff6347 [coral]=ff7f50 [salmon]=fa8072 [maroon]=800000
    [dodgerblue]=1e90ff [royalblue]=4169e1 [steelblue]=4682b4 [skyblue]=87ceeb [slateblue]=6a5acd
    [seagreen]=2e8b57 [forestgreen]=228b22 [olive]=808000 [indigo]=4b0082 [violet]=ee82ee
    [orchid]=da70d6 [hotpink]=ff69b4 [deeppink]=ff1493 [khaki]=f0e68c [tan]=d2b48c
    [chocolate]=d2691e [turquoise]=40e0d0 [gold]=ffd700 [orange]=ffa500 [pink]=ffc0cb
    [purple]=800080 [teal]=008080 [navy]=000080 [brown]=a52a2a [silver]=c0c0c0
)

# ft_color_index NAME → sets FT_RET to a 0-255 xterm index, FT_COLOR_OK=1.
# Invalid/empty input → FT_COLOR_OK=0 (FT_RET left stale; callers must check
# FT_COLOR_OK, not just FT_RET, since 0 is both "black" and "not found").
FT_COLOR_OK=0
ft_color_index() {
    local raw=$1 key=${1,,}
    # AN EMPTY NAME IS NOT A COLOUR — and bash cannot even look one up: `${assoc[]-}` is a
    # "bad array subscript" error, which printed to stderr (the terminal, in a TUI: straight
    # onto the alt screen) and then left the `[[ -n ]]` taking its TRUE branch. So an empty
    # value reported FT_COLOR_OK=1 with FT_RET holding whatever the previous caller left
    # there, and the contract two lines above — "Invalid/empty input → FT_COLOR_OK=0" — was
    # violated for precisely the case it names. An unresolved var() or a cleared property
    # produces an empty value routinely.
    [[ -z "$key" ]] && { FT_COLOR_OK=0; return; }
    if [[ -n "${FT_COLOR_NAMES[$key]-}" ]]; then
        FT_RET=${FT_COLOR_NAMES[$key]}; FT_COLOR_OK=1; return
    fi
    if [[ "$raw" =~ ^[0-9]+$ ]] && (( raw >= 0 && raw <= 255 )); then
        FT_RET=$raw; FT_COLOR_OK=1; return
    fi
    FT_COLOR_OK=0
}

# ── Colour depth & 24-bit RGB ────────────────────────────────────────────────
# FT_COLOR_MODE governs how an RGB / #hex colour is emitted:
#   truecolor  24-bit  \e[<ch>;2;r;g;b m
#   256        nearest xterm-256 cube/grey index   \e[<ch>;5;idx m
#   16 | 8     nearest of the base ANSI colours
# The fixed theme palette (FT_COLOR_*) is authored as 256 indices and is untouched;
# this only routes NEW colours (borderColor=#3af, the colour picker). Flipping
# FT_COLOR_MODE lets a picker preview how a colour degrades on a lesser
# terminal. Auto-detected once at init, always overridable.
# FT_COLOR_MODE IS THE WHOLE ANSWER. It used to be shadowed by a second global,
# FT_TRUECOLOR_AVAIL, set beside it on three of the five branches here and on none of the others
# — and read by nothing, anywhere: 5 writes, 0 reads across source, tests, tools and demos.
# Every real consumer already asks FT_COLOR_MODE (ft_transition_supported, ft_color_sgr). The
# drift a duplicate invites was not hypothetical but already present: detecting xterm-256color
# and then TERM=linux left the flag saying "truecolor" while the mode said 16.
FT_COLOR_MODE=256
ft_detect_color_mode() {
    # Explicit override, mirroring FT_UTF8/FT_ASCII for glyphs: FT_TRUECOLOR=0 forces
    # 256 on the rare terminal that truly lacks 24-bit; anything else forces it on.
    if [[ -n "${FT_TRUECOLOR:-}" ]]; then
        case "$FT_TRUECOLOR" in
            0|off|no|false) FT_COLOR_MODE=256 ;;
            *)              FT_COLOR_MODE=truecolor ;;
        esac
        return
    fi
    # An explicit yes from the environment.
    if [[ "${COLORTERM:-}" == *truecolor* || "${COLORTERM:-}" == *24bit* ]]; then
        FT_COLOR_MODE=truecolor; return
    fi
    # Otherwise ASSUME 24-bit. In current practice every terminal that advertises
    # xterm-256color — Windows Terminal, kitty, wezterm, alacritty, iTerm2, VS Code,
    # gnome-terminal — actually renders truecolor; COLORTERM just frequently isn't
    # exported (notably across the WSL boundary, where it is empty here). Guessing
    # 256 there quantised every computed shade (the whole sheen gradient) to the cube
    # for no reason. Only genuinely limited terminals are pinned lower; a real 256-
    # only terminal opts out with FT_TRUECOLOR=0.
    case "${TERM:-}" in
        ""|dumb)             FT_COLOR_MODE=8 ;;
        linux|*-16color|*-8color) FT_COLOR_MODE=16 ;;   # Linux VT console & 16-colour TERMs
        *) FT_COLOR_MODE=truecolor ;;
    esac
}

# The 16 base ANSI colours as RGB (xterm's values), for nearest-colour mapping.
_FT_ANSI16=(0,0,0 205,0,0 0,205,0 205,205,0 0,0,238 205,0,205 0,205,205 229,229,229
            127,127,127 255,0,0 0,255,0 255,255,0 92,92,255 255,0,255 0,255,255 255,255,255)

# _ft_hsl_to_rgb H S L → FT_RGB_RED/FT_RGB_GREEN/FT_RGB_BLUE. H in degrees (any int), S/L as 0-100 percentages.
# Integer arithmetic in thousandths; result is the terminal-close RGB (further quantised by
# the colour-depth pipeline anyway).
_ft_hsl_to_rgb() {              # h s l
    local h=$1 s=$2 l=$3
    (( h %= 360 )); (( h < 0 )) && (( h += 360 ))
    (( s < 0 )) && s=0; (( s > 100 )) && s=100
    (( l < 0 )) && l=0; (( l > 100 )) && l=100
    local S=$(( s*10 )) L=$(( l*10 ))                  # 0..1000
    local twoL=$(( 2*L )); local absd=$(( twoL>1000 ? twoL-1000 : 1000-twoL ))
    local c=$(( (1000 - absd) * S / 1000 ))            # chroma, 0..1000
    local hmod=$(( (h*1000/60) % 2000 ))
    local d=$(( hmod>1000 ? hmod-1000 : 1000-hmod ))
    local x=$(( c * (1000 - d) / 1000 ))
    local m=$(( L - c/2 )) seg=$(( h/60 )) r1 g1 b1
    case $seg in
        0) r1=$c; g1=$x; b1=0 ;;   1) r1=$x; g1=$c; b1=0 ;;
        2) r1=0; g1=$c; b1=$x ;;   3) r1=0; g1=$x; b1=$c ;;
        4) r1=$x; g1=0; b1=$c ;;   *) r1=$c; g1=0; b1=$x ;;
    esac
    FT_RGB_RED=$(( (r1+m)*255/1000 )); FT_RGB_GREEN=$(( (g1+m)*255/1000 )); FT_RGB_BLUE=$(( (b1+m)*255/1000 ))
    (( FT_RGB_RED<0 )) && FT_RGB_RED=0; (( FT_RGB_RED>255 )) && FT_RGB_RED=255
    (( FT_RGB_GREEN<0 )) && FT_RGB_GREEN=0; (( FT_RGB_GREEN>255 )) && FT_RGB_GREEN=255
    (( FT_RGB_BLUE<0 )) && FT_RGB_BLUE=0; (( FT_RGB_BLUE>255 )) && FT_RGB_BLUE=255
}

# ft_parse_rgb VALUE → FT_RGB_RED/FT_RGB_GREEN/FT_RGB_BLUE (0-255), FT_COLOR_OK. Accepts #rgb,
# #rrggbb, rgb:r,g,b, bare r,g,b, and the CSS rgb()/rgba()/hsl()/hsla() functions.
FT_RGB_RED=0; FT_RGB_GREEN=0; FT_RGB_BLUE=0
ft_parse_rgb() {
    local s=$1; FT_COLOR_OK=0
    # CSS function forms. rgb()/rgba(): the alpha is ignored (no compositing on a terminal).
    # hsl()/hsla(): converted to RGB. Commas OR spaces separate args; % on S/L is optional.
    if [[ "$s" == hsl\(* || "$s" == hsla\(* ]]; then
        s=${s#hsla}; s=${s#hsl}; s=${s#\(}; s=${s%\)}; s=${s//%/}; s=${s//,/ }
        local -a f=($s)
        if (( ${#f[@]} >= 3 )) && [[ "${f[0]}${f[1]}${f[2]}" =~ ^-?[0-9]+$ ]]; then
            _ft_hsl_to_rgb "${f[0]}" "${f[1]}" "${f[2]}"; FT_COLOR_OK=1
        fi
        return
    fi
    if [[ "$s" == rgb\(* || "$s" == rgba\(* ]]; then
        s=${s#rgba}; s=${s#rgb}; s=${s#\(}; s=${s%\)}
        s=${s//,/ }; local -a f=($s)                 # commas OR spaces separate the channels
        if (( ${#f[@]} >= 3 )); then
            FT_RGB_RED=${f[0]}; FT_RGB_GREEN=${f[1]}; FT_RGB_BLUE=${f[2]}
            [[ "$FT_RGB_RED$FT_RGB_GREEN$FT_RGB_BLUE" =~ ^[0-9]+$ ]] && (( FT_RGB_RED<=255 && FT_RGB_GREEN<=255 && FT_RGB_BLUE<=255 )) && FT_COLOR_OK=1
        fi
        return
    fi
    s=${s#rgb:}
    if [[ "$s" == \#* ]]; then
        s=${s#\#}
        if [[ "$s" =~ ^[0-9a-fA-F]{3}$ ]]; then
            FT_RGB_RED=$(( 16#${s:0:1} * 17 )); FT_RGB_GREEN=$(( 16#${s:1:1} * 17 )); FT_RGB_BLUE=$(( 16#${s:2:1} * 17 ))
            FT_COLOR_OK=1; return
        fi
        if [[ "$s" =~ ^[0-9a-fA-F]{6}$ ]]; then
            FT_RGB_RED=$(( 16#${s:0:2} )); FT_RGB_GREEN=$(( 16#${s:2:2} )); FT_RGB_BLUE=$(( 16#${s:4:2} ))
            FT_COLOR_OK=1; return
        fi
        return
    fi
    if [[ "$s" =~ ^([0-9]+),([0-9]+),([0-9]+)$ ]]; then
        FT_RGB_RED=${BASH_REMATCH[1]}; FT_RGB_GREEN=${BASH_REMATCH[2]}; FT_RGB_BLUE=${BASH_REMATCH[3]}
        (( FT_RGB_RED<=255 && FT_RGB_GREEN<=255 && FT_RGB_BLUE<=255 )) && FT_COLOR_OK=1
    fi
}

_ft_cube6() {                   # channel 0-255 → FT_RET nearest cube LEVEL 0-5
    local v=$1
    if   (( v < 48 ));  then FT_RET=0
    elif (( v < 115 )); then FT_RET=1
    else FT_RET=$(( (v - 35) / 40 )); fi
    (( FT_RET > 5 )) && FT_RET=5
}
_ft_cubeval() { local l=$1; (( l == 0 )) && FT_RET=0 || FT_RET=$(( 55 + 40*l )); }   # level → 0-255

# ft_rgb_to_256 R G B → FT_RET nearest xterm-256 index (cube vs grey ramp).
#
# MEMOISED for the same reason as ft_char_cols: pure arithmetic on three numbers, no state,
# no locale. Six nested function calls and a dozen multiplications become one table lookup —
# measured 129µs → 25µs for a repeated colour, 136µs → 34µs over a 64-colour sweep. (As
# there, the floor is bash's own call overhead, not the lookup.) It is on the paint path
# whenever FT_COLOR_MODE is 256 (ft_rgb_sgr), so every themed cell of every frame asks it,
# and a blend or a fade asks it once per step per colour.
#
# The table is capped, which ft_char_cols does not need to be: a character memo is bounded by
# the alphabet on screen, but this one is keyed on arbitrary RGB, and a long truecolour
# gradient played into a 256-colour terminal would grow it without limit. At the cap the
# whole table is dropped rather than evicted by age — the entries are pure, so a wrong guess
# about which to keep costs one recomputation and nothing else, and the counter keeps the
# hot path free of a size query.
declare -A _FT_RGB256_MEMO=()
_FT_RGB256_MEMO_N=0
: "${FT_RGB256_MEMO_MAX:=4096}"
ft_rgb_to_256() {
    local key=$1,$2,$3
    FT_RET=${_FT_RGB256_MEMO["$key"]-}
    [[ -n "$FT_RET" ]] && return
    local r=$1 g=$2 b=$3 lr lg lb cr cg cb cd gi gv gd
    _ft_cube6 "$r"; lr=$FT_RET; _ft_cubeval "$lr"; cr=$FT_RET
    _ft_cube6 "$g"; lg=$FT_RET; _ft_cubeval "$lg"; cg=$FT_RET
    _ft_cube6 "$b"; lb=$FT_RET; _ft_cubeval "$lb"; cb=$FT_RET
    cd=$(( (r-cr)*(r-cr) + (g-cg)*(g-cg) + (b-cb)*(b-cb) ))
    local avg=$(( (r+g+b)/3 ))
    gi=$(( (avg - 8 + 5) / 10 )); (( gi < 0 )) && gi=0; (( gi > 23 )) && gi=23
    gv=$(( 8 + 10*gi ))
    gd=$(( (r-gv)*(r-gv) + (g-gv)*(g-gv) + (b-gv)*(b-gv) ))
    if (( gd < cd )); then FT_RET=$(( 232 + gi )); else FT_RET=$(( 16 + 36*lr + 6*lg + lb )); fi
    if (( ++_FT_RGB256_MEMO_N > FT_RGB256_MEMO_MAX )); then
        _FT_RGB256_MEMO=(); _FT_RGB256_MEMO_N=1
    fi
    _FT_RGB256_MEMO["$key"]=$FT_RET
}

# ft_rgb_to_ansi R G B N(16|8) → FT_RET nearest base-ANSI index.
ft_rgb_to_ansi() {
    local r=$1 g=$2 b=$3 n=$4 i best=0 bd=999999999 pr pg pb d
    for (( i=0; i<n; i++ )); do
        IFS=, read -r pr pg pb <<<"${_FT_ANSI16[$i]}"
        d=$(( (r-pr)*(r-pr) + (g-pg)*(g-pg) + (b-pb)*(b-pb) ))
        (( d < bd )) && { bd=$d; best=$i; }
    done
    FT_RET=$best
}

# ft_256_to_rgb IDX → FT_RGB_RED/FT_RGB_GREEN/FT_RGB_BLUE. Inverse of the cube/grey mapping (and the
# base-16 table), for painting a 256-palette swatch grid or downgrading.
ft_256_to_rgb() {
    local idx=$1
    if (( idx < 16 )); then
        IFS=, read -r FT_RGB_RED FT_RGB_GREEN FT_RGB_BLUE <<<"${_FT_ANSI16[$idx]}"; return
    fi
    if (( idx >= 232 )); then
        local v=$(( 8 + 10*(idx-232) )); FT_RGB_RED=$v; FT_RGB_GREEN=$v; FT_RGB_BLUE=$v; return
    fi
    local n=$(( idx - 16 )) lr lg lb
    lr=$(( n / 36 )); lg=$(( (n / 6) % 6 )); lb=$(( n % 6 ))
    _ft_cubeval "$lr"; FT_RGB_RED=$FT_RET; _ft_cubeval "$lg"; FT_RGB_GREEN=$FT_RET; _ft_cubeval "$lb"; FT_RGB_BLUE=$FT_RET
}

# ft_rgb_sgr R G B CHANNEL(38|48) → FT_RET the SGR body for the current
# FT_COLOR_MODE (24-bit, or nearest 256/16/8 index).
ft_rgb_sgr() {
    local r=$1 g=$2 b=$3 ch=$4
    case "$FT_COLOR_MODE" in
        truecolor) printf -v FT_RET '\e[%s;2;%d;%d;%dm' "$ch" "$r" "$g" "$b" ;;
        16) ft_rgb_to_ansi "$r" "$g" "$b" 16
            if (( FT_RET < 8 )); then printf -v FT_RET '\e[%dm' $(( ch==38 ? 30+FT_RET : 40+FT_RET ))
            else printf -v FT_RET '\e[%dm' $(( ch==38 ? 90+FT_RET-8 : 100+FT_RET-8 )); fi ;;
        8)  ft_rgb_to_ansi "$r" "$g" "$b" 8
            printf -v FT_RET '\e[%dm' $(( ch==38 ? 30+FT_RET : 40+FT_RET )) ;;
        *)  ft_rgb_to_256 "$r" "$g" "$b"; printf -v FT_RET '\e[%s;5;%dm' "$ch" "$FT_RET" ;;
    esac
}

# ft_sgr_rgb SGR CHANNEL(38|48) → FT_RGB_RED/FT_RGB_GREEN/FT_RGB_BLUE; returns 1 if that
# channel is not set in the sequence. The inverse of ft_rgb_sgr above, and it belongs beside
# it: reading a colour back out of an SGR is how anything blends against what is already on
# screen — a sheen shading a border toward its own theme colour, a beacon lerping its ink
# toward the ground, an opacity ramp dimming toward the surface it sits on.
#
# Handles BOTH forms a palette colour can take: a truecolor `CH;2;r;g;b` (themes reaching for
# a shade the 256 cube cannot express — a dark WARM grey, say) and a 256-index `CH;5;N`. The
# LAST occurrence wins, because that is the one the terminal is showing.
ft_sgr_rgb() {                  # sgr channel → FT_RGB_RED FT_RGB_GREEN FT_RGB_BLUE ; 1 if absent
    local sgr=$1 channel=$2 tail
    if [[ "$sgr" == *"$channel;2;"* ]]; then         # truecolor: r;g;b
        tail=${sgr##*$channel;2;}; tail=${tail%%m*}
        IFS=';' read -r FT_RGB_RED FT_RGB_GREEN FT_RGB_BLUE _ <<<"$tail"
        [[ -n "$FT_RGB_RED" && -n "$FT_RGB_GREEN" && -n "$FT_RGB_BLUE" ]] && return 0
    fi
    if [[ "$sgr" == *"$channel;5;"* ]]; then         # 256 index → its palette rgb
        tail=${sgr##*$channel;5;}; tail=${tail%%[!0-9]*}
        [[ -n "$tail" ]] && { ft_256_to_rgb "$tail"; return 0; }
    fi
    return 1
}

# ft_color_sgr VALUE CHANNEL(38|48) → FT_RET SGR (or "" with FT_COLOR_OK=0).
# Routes #hex / rgb:/ r,g,b through the depth pipeline; falls back to the named/
# indexed 256 colour otherwise. The one entry point drawing code should use for
# an arbitrary colour value.
ft_color_sgr() {
    local val=$1 ch=$2
    if [[ "$val" == \#* || "$val" == rgb:* || "$val" == rgb\(* || "$val" == rgba\(* \
          || "$val" == hsl\(* || "$val" == hsla\(* || "$val" == *,*,* ]]; then
        ft_parse_rgb "$val"
        (( FT_COLOR_OK )) || { FT_RET=""; return; }
        ft_rgb_sgr "$FT_RGB_RED" "$FT_RGB_GREEN" "$FT_RGB_BLUE" "$ch"; return
    fi
    # An extended CSS colour NAME with a true hex → resolve through the RGB path, so it matches
    # the identical colour written as #hex/rgb()/hsl() (this is why `crimson` looked "different").
    local _hx=""; [[ -n "$val" ]] && _hx=${FT_CSS_HEX[${val,,}]-}
    if [[ -n "$_hx" ]]; then
        ft_parse_rgb "#$_hx"
        (( FT_COLOR_OK )) && { ft_rgb_sgr "$FT_RGB_RED" "$FT_RGB_GREEN" "$FT_RGB_BLUE" "$ch"; return; }
    fi
    ft_color_index "$val"
    (( FT_COLOR_OK )) || { FT_RET=""; return; }
    printf -v FT_RET '\e[%s;5;%dm' "$ch" "$FT_RET"
}

# ── Terminal enter / restore (idempotent, trap-safe) ─────────────────────────
_FT_TERM_ENTERED=0
_FT_RESTORED=0

# ft_enter_tty: open /dev/tty on fd 3, put it in raw-ish mode, switch to the
# alt screen, hide the cursor. Pairs with ft_restore_tty (which calls
# `stty sane` — this is the call that makes that pairing correct: without it
# the tty stays in canonical/echo mode, so keystrokes get echoed onto the
# alt-screen by the terminal itself and stay line-buffered until Enter, which
# then delivers a burst of buffered bytes at once. `-icanon -echo` fixes both;
# `isig` is left ON (the default) so Ctrl-C/Ctrl-\ still raise real signals
# for the traps in ft_install_traps rather than arriving as ordinary bytes.
# If a host has its own input layer it should start it before drawing and
# stop it on restore (see ft_restore_tty's hook below).
# ── Ctrl+C: copy where copying makes sense, kill everywhere else ─────────────
# A SETTING, because it trades one thing for another and the user owns that trade.
#
#   on  (default) — the tty stops taking Ctrl+C, so it arrives as a key. A control with a
#                   SELECTION copies it (the thing everyone's fingers expect). Anything else
#                   — no selection, not a text control, not a field at all — falls through the
#                   run loop and quits, exactly as SIGINT did.
#   off           — the tty keeps it: Ctrl+C is always an immediate kill, and the copy binding
#                   simply never fires.
#
# Turning it on does NOT remove the emergency escape: only `intr` is released, so Ctrl+\
# (SIGQUIT) still terminates even an app that has stopped servicing its event loop. That is
# what makes the default defensible; without it the honest default would be off.
: "${FT_CTRL_C_COPY:=1}"
_ft_tty_flags() {               # → FT_RET: the stty settings for raw mode, per the setting
    # -ixon: turn OFF software flow control. With it on, Ctrl+S is XOFF and the terminal stops
    # showing output entirely — the app looks hung, forever, until Ctrl+Q. Ctrl+S is also the
    # most reflexive "save" chord there is, so an app that wants it could never have it and a
    # user who presses it out of habit thinks the program crashed. Measured: after Ctrl+S the
    # app emitted 0 further bytes. Off, both Ctrl+S and Ctrl+Q arrive as ordinary keys.
    FT_RET="-icanon -echo -ixon min 1 time 0 susp undef"
    (( FT_CTRL_C_COPY )) && FT_RET+=" intr undef"
}
# Live toggle, so the Settings modal can flip it without a restart.
ft_ctrl_c_copy_set() {          # 0|1
    FT_CTRL_C_COPY=$1
    (( _FT_TERM_ENTERED )) || return 0
    _ft_tty_flags; stty $FT_RET <&3 2>/dev/null
}
ft_enter_tty() {
    exec 3<>/dev/tty || ft_die "cannot open /dev/tty"
    FT_TTY=3
    # `susp undef` frees Ctrl+Z. It is THE undo key everywhere outside a terminal, and while
    # the tty owns it as the suspend character the app never sees the byte at all — the key
    # simply does nothing in a text field, which is what it looked like. Suspend is not lost:
    # an unclaimed CTRL+z falls through to _ft_on_tstp in the run loop, so Ctrl+Z still
    # suspends anywhere that is not editing text. `isig` stays ON, so Ctrl+C keeps its signal
    # and a wedged app can always be killed from the keyboard.
    _ft_tty_flags; stty $FT_RET <&3 2>/dev/null
    if [[ -n "${FT_DEBUG_NOALT:-}" ]]; then
        # Debug mode: stay on the primary screen (no alt buffer), keep the cursor
        # visible, just clear. Lets you see output even if the program exits.
        printf '%s%s%s' "$FT_ANSI_WRAP_OFF" "$FT_COLOR_SCREEN" "$FT_ANSI_CLEAR_SCREEN" >&3
    else
        printf '%s%s%s%s%s%s%s' "$FT_ANSI_ALT_SCREEN_ON" "$FT_ANSI_WRAP_OFF" "$FT_ANSI_BRACKETED_PASTE_ON" "$FT_ANSI_MOUSE_ON" "$FT_ANSI_CURSOR_HIDE" "$FT_COLOR_SCREEN" "$FT_ANSI_CLEAR_SCREEN" >&3
    fi
    _FT_TERM_ENTERED=1
    # Negotiate + turn on an enhanced keyboard protocol (Ctrl+Space, full modified
    # keys) BEFORE the input coproc grabs the tty, so the query round-trip is clean.
    if declare -F ft_kbd_negotiate >/dev/null; then ft_kbd_negotiate; ft_kbd_enable; fi
}

# A host may set FT_ON_RESTORE to the name of a function to run during restore
# (e.g. to stop its input coproc). Kept as a hook so ft-core has no hard
# dependency on the input layer.
FT_ON_RESTORE=""
ft_restore_tty() {
    (( _FT_RESTORED )) && return
    _FT_RESTORED=1
    [[ -n "$FT_ON_RESTORE" ]] && "$FT_ON_RESTORE" 2>/dev/null
    declare -F ft_wt_autofix_exit >/dev/null && ft_wt_autofix_exit   # un-fix WT keys (if we fixed them)
    (( _FT_TERM_ENTERED )) || { exec 3>&- 2>/dev/null; return; }
    declare -F ft_kbd_disable >/dev/null && ft_kbd_disable   # pop the keyboard protocol
    stty sane <&3 2>/dev/null
    # \e[0 q resets the cursor SHAPE (a field may have set it to a bar) back to
    # the terminal default, alongside the usual attribute/cursor-visibility reset.
    printf '%s%s%s%s%s%s%s%s%s' "$FT_ANSI_RESET" $'\e[0 q' $'\e]112\e\\' "$FT_ANSI_MOUSE_OFF" "$FT_ANSI_BRACKETED_PASTE_OFF" "$FT_ANSI_WRAP_ON" "$FT_ANSI_CURSOR_SHOW" "$FT_ANSI_CLEAR_SCREEN" "$FT_ANSI_ALT_SCREEN_OFF" >&3 2>/dev/null
    exec 3>&- 2>/dev/null
}

# ── Suspend / resume (Ctrl-Z) ────────────────────────────────────────────────
# Ctrl-Z stops the whole foreground group; when the shell takes over it puts the
# tty back in COOKED mode. Nothing re-applies our raw mode on `fg`, so without
# this the resumed app reads line-buffered, echoed input (arrow keys arrive as
# literal escape bytes, buffered until Enter) and the cursor is stranded at the
# shell prompt. We hand the terminal back cleanly on suspend and re-take it on
# resume, then force a full repaint so the cursor lands back in the UI.
ft_suspend_tty() {              # give the terminal back to the shell (sane + primary screen)
    (( _FT_TERM_ENTERED )) || return 0
    declare -F ft_kbd_disable >/dev/null && ft_kbd_disable
    stty sane <&3 2>/dev/null
    printf '%s%s%s%s%s%s%s' "$FT_ANSI_RESET" $'\e[0 q' "$FT_ANSI_MOUSE_OFF" "$FT_ANSI_BRACKETED_PASTE_OFF" "$FT_ANSI_CURSOR_SHOW" "$FT_ANSI_CLEAR_SCREEN" "$FT_ANSI_ALT_SCREEN_OFF" >&3 2>/dev/null
}
ft_resume_tty() {               # re-take the terminal (raw + alt screen, cursor hidden)
    (( _FT_TERM_ENTERED )) || return 0
    _ft_tty_flags; stty $FT_RET <&3 2>/dev/null   # susp/intr: see ft_enter_tty
    # Re-assert auto-wrap OFF too: `stty sane`/the shell will have turned DECAWM back
    # on while we were suspended, and a full-width last row would then scroll us.
    [[ -n "${FT_DEBUG_NOALT:-}" ]] && printf '%s' "$FT_ANSI_WRAP_OFF" >&3 2>/dev/null \
        || printf '%s%s%s%s%s' "$FT_ANSI_ALT_SCREEN_ON" "$FT_ANSI_WRAP_OFF" "$FT_ANSI_BRACKETED_PASTE_ON" "$FT_ANSI_MOUSE_ON" "$FT_ANSI_CURSOR_HIDE" >&3 2>/dev/null
    printf '%s' "$FT_COLOR_SCREEN" >&3 2>/dev/null
    declare -F ft_kbd_enable >/dev/null && ft_kbd_enable    # re-arm the keyboard protocol
}
# SIGTSTP hands the terminal back and re-raises with the default action so the
# process actually stops; SIGCONT (fg) re-takes the terminal and flags a full
# relayout+repaint (the resize path — it repaints AND repositions the cursor).
# Split across two traps so the resume does NOT depend on execution continuing
# mid-`kill`, which is unreliable for a stopped process.
_ft_on_tstp() {
    ft_suspend_tty
    trap - TSTP; kill -s TSTP "$$"    # stop for real
}
_ft_on_cont() {
    trap '_ft_on_tstp' TSTP           # re-arm the suspend trap
    ft_resume_tty
    FT_WINCH=1                        # force the run loop to relayout + repaint
}

ft_install_traps() {
    trap 'ft_restore_tty' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    trap 'exit 131' QUIT
    trap 'ft_on_winch' WINCH
    trap '_ft_on_tstp' TSTP
    trap '_ft_on_cont' CONT
}

FT_WINCH=0
ft_on_winch() { FT_WINCH=1; }   # flag; the host loop recomputes layout + redraws

# ── Geometry ─────────────────────────────────────────────────────────────────
# Size detection is the one place we shell out (stty size), at startup and on
# resize only — never in the draw path.
FT_ROWS=24; FT_COLS=80
ft_term_size() {
    local sz; sz=$(stty size 2>/dev/null </dev/tty)   # stderr FIRST: a failed </dev/tty is reported before a later 2> applies
    if [[ "$sz" =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
        FT_ROWS=${BASH_REMATCH[1]}; FT_COLS=${BASH_REMATCH[2]}
    else
        FT_ROWS=${LINES:-24}; FT_COLS=${COLUMNS:-80}
    fi
    # The flight recorder's byte stream is replayed through a cell grid whose dimensions must be
    # KNOWN — a recording that doesn't say its own size is evidence with the axes unlabeled. The
    # stream itself must stay pure terminal bytes (anything injected corrupts replay), so sizes
    # go to a sidecar: one line per query, so resizes mid-session are captured too.
    [[ -n "${FT_RECORD:-}" ]] && printf 'SIZE %s %s\n' "$FT_COLS" "$FT_ROWS" >> "$FT_RECORD.meta"
}

# ── Display width (the samba-mago lesson) ────────────────────────────────────
# The DISPLAY width of a string is not its byte length and not even its
# character length once ANSI escapes are embedded: `\e[31m` is 5 bytes / 0
# columns, and a box glyph like ─ is 3 bytes / 1 column. All sizing MUST go
# through ft_display_width, which skips CSI escape sequences (counts them 0) and
# counts each remaining character as one column. Raw ${#var} is only safe for
# strings known to be plain ASCII/escape-free.
#
# ft_display_width STRING → sets FT_DISPLAY_WIDTH to the column width. (No fork.)
# ft_char_cols CHAR → FT_CHAR_WIDTH, the terminal columns ONE character occupies: 2 for East-Asian
# Wide/Fullwidth (CJK, Hangul, fullwidth forms, most emoji), 0 for combining marks and
# zero-width joiners/selectors, 1 for everything else. This is wcwidth(3) reduced to the ranges
# that actually matter; bash yields a character's code point directly with `'$ch` in an
# arithmetic context, in a UTF-8 locale, with no fork.
#
# MEMOISED, because the answer cannot change. A character's width depends on its code point
# and on LC_CTYPE, and LC_CTYPE is fixed for the process by ft_setup_locale before the first
# frame — so the first answer is the only answer. `printf -v cp '%d' "'$ch"` is what this
# function is made of, and it is what the memo removes.
#
# MEASURED (bash 5.2 / WSL2), and worth reading before expecting more from it: the call goes
# 47µs → 18µs, not to nothing, because ~8µs of what is left is bash's own cost for CALLING a
# one-argument function (an empty loop iterates in 3.0µs, a bare call in 5.0µs, a call with
# one argument in 8.3µs) and the rest is the guard, the lookup and the return. The lookup
# ITSELF is ~2µs. A 34-cell box border therefore goes 2565µs → 1473µs and a mixed CJK line
# 1178µs → 740µs — a 1.6-1.7× on the scan, not the 20× the per-call figures suggest.
#   Reading the table at the four call sites instead of calling this function is worth a
# further 26-33% (measured), at the price of spreading _FT_CHAR_COLS_MEMO across them.
# Deliberately not done here — the memo is the change, inlining is a separate decision.
#
# Every width scan in the toolkit — ft_display_width, ft_display_index, ft_display_truncate,
# ft_wrap — is a loop around this call, so this is the whole non-ASCII path. Pure ASCII never
# reaches it (each caller shortcuts first) and is unaffected: verified by counting entries,
# which is zero for an all-ASCII resize.
#   The locale premise, checked rather than assumed: the one `export LC_ALL=C` in the engine
# is inside _ft_input_producer, which is a COPROC — a separate process, whose environment
# cannot reach this table. ft-state's two `local LC_ALL=C` scopes are a `${#1}` and a `read`;
# neither measures a width. ft-filedialog borrows LC_COLLATE only. tests/test-charwidth.bash
# pins all of that, and go_cold in tests/_harness.bash drops this table so the warm/cold
# comparison proves a hit renders the same pixels as a compute.
FT_CHAR_WIDTH=1
declare -A _FT_CHAR_COLS_MEMO=()
ft_char_cols() {
    # THE EMPTY STRING NEVER REACHES THE TABLE. An empty associative-array subscript is not a
    # miss in bash, it is a fatal `bad array subscript` — and under `set -e`, which apps run
    # with, it kills the shell. ft_char_cols "" is legal today and answers 1 (printf gives
    # cp=0, which lands in the ASCII branch below), so this returns the same 1 it always did.
    (( ${#1} == 0 )) && { FT_CHAR_WIDTH=1; return; }
    # One lookup serves as both the test and the fetch. A stored 0 (combining marks) is a HIT:
    # "0" is a non-empty string. Only a miss yields "".
    FT_CHAR_WIDTH=${_FT_CHAR_COLS_MEMO["$1"]-}
    [[ -n "$FT_CHAR_WIDTH" ]] && return
    local cp
    # Unreachable in practice on bash 5.2 — `'` alone gives 0, a multi-byte or invalid byte
    # gives its first byte — but if it ever does fire it must still leave a width behind, and
    # it deliberately does NOT memoise: a computed answer is cached, a failure is retried.
    printf -v cp '%d' "'$1" 2>/dev/null || { FT_CHAR_WIDTH=1; return; }
    if   (( cp < 0x0300 )); then FT_CHAR_WIDTH=1                              # ASCII + Latin-1: always 1
    elif (( cp <= 0x036f )); then FT_CHAR_WIDTH=0                             # combining diacriticals
    elif (( cp == 0x200b || cp == 0x200d )); then FT_CHAR_WIDTH=0             # ZWSP / zero-width joiner
    elif (( cp >= 0xfe00 && cp <= 0xfe0f )); then FT_CHAR_WIDTH=0             # variation selectors
    elif (( (cp >= 0x1100 && cp <= 0x115f)      ||  \
            (cp >= 0x2e80 && cp <= 0x303e)      ||  \
            (cp >= 0x3041 && cp <= 0xa4cf)      ||  \
            (cp >= 0xac00 && cp <= 0xd7a3)      ||  \
            (cp >= 0xf900 && cp <= 0xfaff)      ||  \
            (cp >= 0xfe10 && cp <= 0xfe19)      ||  \
            (cp >= 0xfe30 && cp <= 0xfe6f)      ||  \
            (cp >= 0xff00 && cp <= 0xff60)      ||  \
            (cp >= 0xffe0 && cp <= 0xffe6)      ||  \
            (cp >= 0x1f300 && cp <= 0x1f64f)    ||  \
            (cp >= 0x1f680 && cp <= 0x1f6ff)    ||  \
            (cp >= 0x1f900 && cp <= 0x1f9ff)    ||  \
            (cp >= 0x20000 && cp <= 0x3fffd) )); then FT_CHAR_WIDTH=2
    else FT_CHAR_WIDTH=1; fi
    _FT_CHAR_COLS_MEMO["$1"]=$FT_CHAR_WIDTH
}
# ── Tabs ─────────────────────────────────────────────────────────────────────
# A TAB has no meaning in a fixed-cell grid: the terminal advances to its OWN next tab stop,
# which is measured from the screen edge and has nothing to do with a control's box. Every
# width fast path counted it as one ASCII column, so a label reading $'ab\tcd' measured 5 and
# painted 10 — the cursor jumped clear of the box and the neighbouring control overwrote the
# tail. The "cd" simply vanished. Text arriving from outside (a config file, command output)
# contains tabs routinely.
#
# So the framework never lets a tab reach the terminal: it expands to spaces at DISPLAY time,
# with stops measured from the start of the string, which is the only origin both the measurer
# and the painter can agree on. Expanding at STORAGE time would be wrong — a text field holding
# a samba config must give back the tabs it was given.
# (Distinct from a text field's _FT_TAB_WIDTH, which is how far the Tab KEY indents.)
: "${FT_TAB_COLUMNS:=8}"
ft_expand_tabs() {              # string → FT_RET with tabs replaced by spaces to the next stop
    local s=$1
    if [[ "$s" != *$'\t'* ]]; then FT_RET=$s; return; fi
    local out="" seg col=0 pad
    while [[ "$s" == *$'\t'* ]]; do
        seg=${s%%$'\t'*}; s=${s#*$'\t'}
        ft_display_width "$seg"; (( col += FT_DISPLAY_WIDTH ))
        pad=$(( FT_TAB_COLUMNS - (col % FT_TAB_COLUMNS) ))
        printf -v out '%s%s%*s' "$out" "$seg" "$pad" ''
        (( col += pad ))
    done
    FT_RET="$out$s"
}

FT_DISPLAY_WIDTH=0
ft_display_width() {
    local s=$1
    # A tab is not one column — route it to the slow path, which advances to the next stop.
    [[ "$s" == *$'\t'* ]] && { ft_expand_tabs "$s"; s=$FT_RET; }
    # Fast path (the common case): PURE ASCII → the code-point count IS the column width, and
    # the per-character scan is skipped entirely. Anything else — an escape sequence, a
    # combining mark, a double-width glyph — takes the loop below, which asks ft_char_cols.
    # It used to be enough for the string to be escape-free, which silently assumed every
    # glyph was one column: a CJK or emoji character then measured 1 where the terminal drew
    # 2, so wrapping, truncation and padding were all short and controls overflowed their box.
    # BOTH conditions, and ESC is itself an ASCII character — testing only for ASCII lets a
    # string full of SGR escapes take this path and counts the escape bytes as columns.
    if [[ "$s" != *$'\e'* && "$s" != *[![:ascii:]]* ]]; then FT_DISPLAY_WIDTH=${#s}; return; fi
    # MIDDLE PATH — no escapes, but not pure ASCII. ONE em-dash, curly quote or accent in a
    # line used to send all 36 of its characters through the per-character loop below, and
    # `${s:i:1}` is the expensive part: measuring a 4000-line document cost ~2.5s, nearly all
    # of it here, because ordinary English prose is full of "—" and "…". Ranges of ASCII are
    # counted WHOLESALE with ${#run}; ft_char_cols is still asked about every non-ASCII
    # character, so wide (CJK/emoji) and zero-width (combining) glyphs measure exactly as
    # before — the correctness this function exists for is untouched.
    if [[ "$s" != *$'\e'* ]]; then
        local rest=$s run w=0 ch
        while [[ -n "$rest" ]]; do
            run=${rest%%[![:ascii:]]*}                 # the leading ASCII run (may be empty)
            if [[ -n "$run" ]]; then (( w += ${#run} )); rest=${rest#"$run"}; fi
            [[ -z "$rest" ]] && break
            ch=${rest:0:1}
            ft_char_cols "$ch"; (( w += FT_CHAR_WIDTH ))
            rest=${rest:1}
        done
        FT_DISPLAY_WIDTH=$w; return
    fi
    # `${#s}`, NOT `${#1}`: the tab expansion at the top of this function REPLACED s, and a string
    # with a tab is longer afterwards. Measuring the original argument's length stopped this loop
    # early, so a string carrying both a tab and an escape measured short — $'a\tbcd\e[0m' came
    # back 9 where the identical text without the escape came back 11. Only this path had it: the
    # two paths above measure `s` itself.
    local i=0 n=${#s} ch w=0 seg run
    while (( i < n )); do
        ch="${s:i:1}"
        if [[ "$ch" == $'\e' ]]; then
            # Skip an escape sequence: ESC [ ... <final byte in @-~> (CSI), ESC ] …
            # ST/BEL (OSC — e.g. hyperlinks), or a bare ESC <byte>.
            (( i++ ))
            if [[ "${s:i:1}" == "[" ]]; then
                # THE SEQUENCE IN ONE SLICE, not a byte at a time. An SGR run like
                # `\e[48;5;238;38;5;231m` is twenty bytes, and walking it with `${s:i:1}` cost
                # more than the text around it: after the text runs below were made wholesale,
                # THIS was 85% of what remained on a coloured row. Everything up to the first
                # final byte (@-~) is parameters and intermediates, so the length of that prefix
                # plus one IS the sequence.
                (( i++ ))                           # consume the '['
                seg=${s:i}; run=${seg%%[@-~]*}
                if [[ "$run" == "$seg" ]]; then i=$n            # unterminated → it is all escape
                else (( i += ${#run} + 1 )); fi                 # params + the final byte
            elif [[ "${s:i:1}" == "]" ]]; then      # OSC: run to BEL or ST (ESC \)
                (( i++ ))
                while (( i < n )); do
                    [[ "${s:i:1}" == $'\a' ]] && { (( i++ )); break; }
                    [[ "${s:i:1}" == $'\e' && "${s:i+1:1}" == '\' ]] && { (( i+=2 )); break; }
                    (( i++ ))
                done
            else
                (( i < n )) && (( i++ ))            # ESC + single byte (e.g. ESC-O)
            fi
            continue
        fi
        # A RUN OF TEXT, NOT ONE CHARACTER AT A TIME. `${s:i:1}` is what this loop spends its life
        # in — ~22µs a character, so a 545-byte coloured row cost 12ms to measure. That is not a
        # rare shape: every string with SGR colour AND a non-ASCII glyph lands here, and the key
        # legend is 25 of them. Measured on the callout demo, one repaint of the legend was 42ms,
        # 32ms of it inside this function, and the keycap pulse repaints the legend on every tick
        # — 95% of an idle app's entire paint budget, and the reason a drag cannot get a frame in.
        #
        # This is the same wholesale counting the escape-free path above already does; only this
        # path never got it. Take everything up to the next escape in one slice, count its ASCII
        # runs with `${#run}`, and ask ft_char_cols only about the characters that are not ASCII,
        # so wide and combining glyphs still measure exactly as they did. `seg` is never empty
        # here — `ch` is not an escape, so it is at least that one character — which is what
        # stops this from spinning without advancing `i`.
        seg=${s:i}; seg=${seg%%$'\e'*}
        (( i += ${#seg} ))
        while [[ -n "$seg" ]]; do
            run=${seg%%[![:ascii:]]*}                  # the leading ASCII run (may be empty)
            if [[ -n "$run" ]]; then (( w += ${#run} )); seg=${seg#"$run"}; fi
            [[ -z "$seg" ]] && break
            ft_char_cols "${seg:0:1}"; (( w += FT_CHAR_WIDTH ))   # 2 wide, 0 combining, else 1
            seg=${seg:1}
        done
    done
    FT_DISPLAY_WIDTH=$w
}

# ft_display_truncate STRING MAXCOLS → sets FT_DISPLAY_TRUNCATED to STRING truncated to MAXCOLS
# display columns, preserving (not counting) any ANSI escapes encountered. Does
# not append an ellipsis (callers decide). Used by ft_fit.
#
# THIS IS ft_display_width's WALK, and it must stay that walk: same three paths, same
# predicates, same wholesale slicing. It answers a different question — width returns a
# COUNT, this returns the PREFIX — but it counts the same columns to get there, and when
# the two disagree about where column N falls, a row claims a width it does not paint.
#
# That is also why it is here rather than expressed as `${s:0:$(ft_display_index …)}`:
# ft_display_index snaps FORWARD over a double-width glyph straddling the cut, and this
# must stop BEFORE it (see the comment at the wide-glyph test below). Two different
# promises about the same boundary; the near-identical bodies are not one concept.
#
# It did not stay that walk. ft_display_width was taught wholesale slicing twice — ASCII
# runs counted with ${#run}, then an escape sequence taken in one slice — and its sibling
# here was left walking one `${s:i:1}` at a time, which is CONTRIBUTING §1's recurring root
# cause exactly: the same predicate on one route and not its sibling. Both columns below
# are tools/bench-display-scan.bash, bash 5.2, 400 calls, empty-loop floor subtracted:
#
#                                      before     after
#     118 plain ASCII → 118          1,959 µs     69 µs      28×
#     118 columns in one SGR → 116   2,281 µs    225 µs      10×
#     91-char prose, one em-dash      1,042 µs    211 µs     4.9×
#     20 short SGR runs → 60         4,814 µs  2,473 µs     1.9×
#     40 CJK glyphs → 80             1,641 µs  1,464 µs     1.1×
#
# A 2 ms primitive is a cliff, and ft_fit walks off it for every string wider than its
# box — the ordinary case, not a corner. The same tool's `scene` mode builds an app that
# does it for real: a table of 18 rows whose paths overflow their column makes 73 of these
# calls in ONE repaint, and the repaint goes 64 ms → 51 ms. A fifth of a frame, in a
# function that only ever cut a string.
#
# ft_display_index shares the defect and is deliberately left alone, on measurement rather
# than on taste: its callers hand it DOCUMENT text — a text field's stored line, never a
# painted row — so it has no escapes to skip, and a 40-line prose document measures ONE
# call per repaint against this function's 73. Below CONTRIBUTING §3's ~2 ms bar, so it
# keeps the simpler loop, and this note is here so the next person does not have to
# re-derive that it was considered.
FT_DISPLAY_TRUNCATED=""
ft_display_truncate() {
    local s=$1 max=$2
    # Same reason as ft_fit: the result is painted, so it must carry no raw tab.
    [[ "$s" == *$'\t'* ]] && { ft_expand_tabs "$s"; s=$FT_RET; }
    # Nothing fits in nothing. This is not defensive tidiness: ft_fit asks for (w - 1),
    # which is -1 for a one-column box, and the fast path below is `${s:0:max}` — where
    # bash reads a NEGATIVE length as "all but the last |max| characters" and would hand
    # back nearly the whole string. The old loop returned "" here by never entering.
    (( max <= 0 )) && { FT_DISPLAY_TRUNCATED=""; return; }
    # FAST PATH: pure ASCII, no escape → a column IS a character, so the truncation is one
    # parameter expansion. Same three-part test as ft_display_width's fast path, tab already
    # routed away above — it has to be the same test, or a string one of them calls simple
    # takes the other's slow road and the two can disagree about where column N is.
    #   On a 118-column row this is 69 µs against the 1,959 µs the per-character loop cost.
    # It is worth keeping even though the middle path below would also take that row in one
    # slice: deleting only this test costs 97 µs, and 7 statements become 16. Small, and it
    # is the shape ft_fit hands this function most often, so tests/test-displayscan.bash
    # gates it at 12 statements rather than at the disaster.
    if [[ "$s" != *$'\e'* && "$s" != *[![:ascii:]]* ]]; then
        FT_DISPLAY_TRUNCATED=${s:0:max}; return
    fi
    local out="" w=0 run wide ch k kn
    # MIDDLE PATH — no escapes, but not pure ASCII. ft_display_width's reasoning applies
    # unchanged: one em-dash in a line of prose must not send all 91 of its characters
    # through a per-character slice. Ranges of ASCII are taken WHOLESALE, and ft_char_cols
    # is still asked about every non-ASCII character, so wide and combining glyphs cut
    # exactly where they did before.
    #
    # BOTH runs are peeled, and the second one is the interesting half. Peeling only the
    # ASCII run — which is all ft_display_width does — leaves a line with no ASCII in it
    # paying a whole-remainder `%%` match per glyph just to be told the ASCII run is empty,
    # and then copying the remainder again to advance one character. Three implementations
    # of this loop, timed against each other in one sitting on the same 40-glyph Japanese
    # line: the per-character loop 599 µs, the ASCII-only peel 986 µs, both runs peeled
    # 630 µs. The "optimisation" was 1.6× SLOWER than the code it replaced on the one shape
    # that has no ASCII in it at all, and it would have shipped that way — the corpus it
    # was measured on was all English. Walking the non-ASCII run BY INDEX copies the tail
    # once per run instead of once per glyph, which buys the CJK line back while prose
    # keeps its 5×.
    if [[ "$s" != *$'\e'* ]]; then
        local rest=$s
        while (( w < max )) && [[ -n "$rest" ]]; do
            run=${rest%%[![:ascii:]]*}                 # the leading ASCII run (may be empty)
            if [[ -n "$run" ]]; then
                # In an ASCII run a column IS a character, so the cut inside it is a slice.
                (( w + ${#run} >= max )) && { out+=${run:0:max-w}; break; }
                out+=$run; (( w += ${#run} )); rest=${rest#"$run"}
                [[ -z "$rest" ]] && break
            fi
            # `rest` now starts non-ASCII, so this run is never empty — that is what stops
            # the outer loop from spinning without advancing.
            wide=${rest%%[[:ascii:]]*}; rest=${rest#"$wide"}
            k=0; kn=${#wide}
            while (( k < kn && w < max )); do
                ch=${wide:k:1}
                ft_char_cols "$ch"
                # A double-width glyph must not be cut in HALF: if it does not fit in what
                # is left, stop before it. The caller pads the one spare column, so the row
                # still measures exactly MAXCOLS and the next cell starts where it should.
                # This is the boundary ft_display_index answers the other way — it snaps
                # FORWARD over the straddling glyph — and the reason these are two functions.
                (( w + FT_CHAR_WIDTH > max )) && break 2
                out+=$ch; (( w += FT_CHAR_WIDTH, k++ ))
            done
        done
        FT_DISPLAY_TRUNCATED=$out; return
    fi
    # SLOW PATH — the string carries escapes. They are COPIED THROUGH and cost no columns:
    # they are what makes the row coloured, and a truncation that dropped them would paint
    # the tail of the row in whatever attributes the last one left standing.
    local i=0 n=${#s} seg
    while (( i < n && w < max )); do
        ch=${s:i:1}
        if [[ "$ch" == $'\e' ]]; then
            (( i++ ))
            if [[ "${s:i:1}" == "[" ]]; then
                # THE SEQUENCE IN ONE SLICE, not a byte at a time — ft_display_width's
                # note applies here too: everything up to the first final byte (@-~) is
                # parameters and intermediates, so that prefix plus one IS the sequence.
                (( i++ ))
                seg=${s:i}; run=${seg%%[@-~]*}
                if [[ "$run" == "$seg" ]]; then out+=$'\e['"$seg"; i=$n          # unterminated
                else out+=$'\e['"$run${seg:${#run}:1}"; (( i += ${#run} + 1 )); fi
            elif [[ "${s:i:1}" == "]" ]]; then      # OSC: copy through BEL or ST (ESC \)
                out+=$'\e]'; (( i++ ))
                while (( i < n )); do
                    [[ "${s:i:1}" == $'\a' ]] && { out+=$'\a'; (( i++ )); break; }
                    [[ "${s:i:1}" == $'\e' && "${s:i+1:1}" == '\' ]] && { out+=$'\e\\'; (( i+=2 )); break; }
                    out+="${s:i:1}"; (( i++ ))
                done
            else
                out+=$'\e'"${s:i:1}"; (( i < n )) && (( i++ ))   # ESC + single byte
            fi
            continue
        fi
        # A RUN OF TEXT BETWEEN TWO ESCAPES, not one character at a time — the middle
        # path's loop verbatim, over the segment instead of the whole string. `seg` is
        # never empty (ch is not an escape, so it is at least that character), which is
        # what stops this from spinning without advancing i.
        seg=${s:i}; seg=${seg%%$'\e'*}
        (( i += ${#seg} ))
        # `w < max` guards every level, exactly as it guards the middle path and as the
        # single loop it replaces did. A zero-width combining mark passes the half-glyph
        # test at any width, so without it a mark sitting on the cut would be copied into
        # a row that is already full.
        while (( w < max )) && [[ -n "$seg" ]]; do
            run=${seg%%[![:ascii:]]*}
            if [[ -n "$run" ]]; then
                # Filled the width inside this run: nothing after it can be reached, so
                # leave every loop rather than walking the rest of the string to find out.
                (( w + ${#run} >= max )) && { out+=${run:0:max-w}; break 2; }
                out+=$run; (( w += ${#run} )); seg=${seg#"$run"}
                [[ -z "$seg" ]] && break
            fi
            wide=${seg%%[[:ascii:]]*}; seg=${seg#"$wide"}
            k=0; kn=${#wide}
            while (( k < kn && w < max )); do
                ch=${wide:k:1}
                ft_char_cols "$ch"
                (( w + FT_CHAR_WIDTH > max )) && break 3      # the half-glyph rule, as above
                out+=$ch; (( w += FT_CHAR_WIDTH, k++ ))
            done
        done
    done
    FT_DISPLAY_TRUNCATED=$out
}

# ── Columns ↔ characters ─────────────────────────────────────────────────────
# A string has TWO coordinate systems and they are not the same one. A caret, a
# selection endpoint and a line offset are CHARACTER indices — that is the document.
# A scroll offset, a click and the width of a well are COLUMNS — that is the screen.
# In pure ASCII the two coincide exactly, which is why one variable served as both
# everywhere for so long. One CJK glyph (ONE character, TWO columns) pulls them
# apart, and from then on every mixed calculation is wrong by one column per glyph.
#
# These are the conversions, and they are the exact inverse of ft_display_width —
# same escape skipping, same tab stops — so a width measured one way and an index
# taken the other always agree.
#
#   ft_display_col   STRING NCHARS → FT_RET = the COLUMN at which character NCHARS begins
#   ft_display_index STRING COL    → FT_RET = the CHARACTER INDEX at column COL
#                                    FT_DISPLAY_COL = the column that index really sits at
#
# ft_display_index snaps FORWARD: when a double-width glyph straddles the requested
# column it returns the index PAST it, and reports the column it landed on. A left
# edge must never be half a glyph, and the caller needs to know where it ended up —
# hence the second output rather than a silent adjustment.
ft_display_col() {              # string nchars → FT_RET (columns)
    ft_display_width "${1:0:$2}"
    FT_RET=$FT_DISPLAY_WIDTH
}
FT_DISPLAY_COL=0
ft_display_index() {            # string col → FT_RET (character index), FT_DISPLAY_COL
    local s=$1 max=$2
    (( max < 0 )) && max=0
    # Fast path, and the reason this costs nothing in the ordinary case: with no wide
    # glyph, no escape and no tab, a column IS an index. Same three-part test as
    # ft_display_width's fast path — it has to be, or the two disagree.
    if [[ "$s" != *$'\e'* && "$s" != *[![:ascii:]]* && "$s" != *$'\t'* ]]; then
        (( max > ${#s} )) && max=${#s}
        FT_RET=$max; FT_DISPLAY_COL=$max; return
    fi
    local i=0 n=${#s} ch w=0 pad
    while (( i < n && w < max )); do
        ch="${s:i:1}"
        if [[ "$ch" == $'\e' ]]; then           # escapes occupy no columns (see ft_display_width)
            (( i++ ))
            if [[ "${s:i:1}" == "[" ]]; then
                (( i++ ))
                while (( i < n )) && [[ "${s:i:1}" != [@-~] ]]; do (( i++ )); done
                (( i < n )) && (( i++ ))
            elif [[ "${s:i:1}" == "]" ]]; then
                (( i++ ))
                while (( i < n )); do
                    [[ "${s:i:1}" == $'\a' ]] && { (( i++ )); break; }
                    [[ "${s:i:1}" == $'\e' && "${s:i+1:1}" == '\' ]] && { (( i+=2 )); break; }
                    (( i++ ))
                done
            else
                (( i < n )) && (( i++ ))
            fi
            continue
        fi
        if [[ "$ch" == $'\t' ]]; then           # one character, several columns — to the next stop
            pad=$(( FT_TAB_COLUMNS - (w % FT_TAB_COLUMNS) ))
            (( w += pad, i++ )); continue
        fi
        if [[ "$ch" == [[:ascii:]] ]]; then (( w++, i++ )); continue; fi
        ft_char_cols "$ch"; (( w += FT_CHAR_WIDTH, i++ ))
    done
    FT_RET=$i; FT_DISPLAY_COL=$w
}

# ── Draw primitives ──────────────────────────────────────────────────────────
# Everything appends to FT_OUT; ft_flush writes it once. ft_print_at places text at a
# 0-based (row,col). ft_fit pads/truncates to a DISPLAY width (ANSI-safe, so
# colour/bold inside text is fine). ft_wrap word-wraps by display width.
FT_OUT=""
# ── The recording half of the retained display list ──────────────────────────
# Every byte a painter emits goes into the frame AND into the block for the control currently
# being drawn. ft_draw_one empties this before it dispatches a painter and keeps what comes
# back (ft-forms.bash, FT_RETAINED_BLOCK); nothing else reads it, and bytes appended outside a
# draw — the damage refill, a transition's blend, the caret — land in a block nobody harvests.
#
# WHY HERE AND NOT A SLICE OF FT_OUT. `${FT_OUT:offset}` is the obvious recorder and it is the
# wrong one: bash charges that by the OFFSET, not by the slice. Measured on this machine, taking
# a 100-byte block costs 6µs when the frame in front of it is empty and 365µs when it is 24KB —
# so the last control on a page would pay sixty times what the first one did, for the same
# block, and a keystroke would be charged for the size of the frame it happens to land in.
# Appending here is charged by the PIECE: ~6µs for a 129-byte piece, whatever the frame holds.
# (`${#FT_OUT}`, needed to find the offset, is the same O(frame) scan and goes with it.)
FT_BLOCK_BEING_DRAWN=""
# _ft_print_bytes BYTES — put frame bytes that were rendered EARLIER back into the frame.
#
# The one legitimate way for a painter to append to FT_OUT without going through ft_print_at:
# a control that has already rendered part of itself and cached the exact bytes (the textfield's
# frozen sheen ring). A raw `FT_OUT+=` there would put ink on the screen that the block does not
# contain, and the next time that block were re-emitted the ring would simply be missing.
_ft_print_bytes() { FT_OUT+=$1; FT_BLOCK_BEING_DRAWN+=$1; }
# Paint clipping: draws outside [FT_CLIP_R0..R1] x [FT_CLIP_C0..C1] are
# skipped/truncated. The engine (ft_draw_one) sets these to the intersection
# of the control's ancestors' content boxes (overflow != visible), so a child
# can never paint over its container's border or its siblings — the CSS
# overflow-clipping model. Defaults are wide open for standalone ft-core use.
FT_CLIP_R0=0; FT_CLIP_R1=999999; FT_CLIP_C0=0; FT_CLIP_C1=999999
ft_clip_reset() { FT_CLIP_R0=0; FT_CLIP_R1=999999; FT_CLIP_C0=0; FT_CLIP_C1=999999; }
ft_print_at() {
    local row=$1 col=$2 s=$3
    # NO NEWLINE MAY REACH THE TERMINAL, for the reason the tab guard below gives and with a
    # worse consequence: a newline sends the cursor to column 1 of the NEXT row — outside the
    # clip, outside the control's box, over whatever is there — and on the last row it SCROLLS
    # THE WHOLE SCREEN. A control's label may legitimately contain one, and the layout already
    # knows it does: _ft_height_radio answers FT_TEXT_HEIGHT, so the second row is measured and
    # reserved. It was only the DRAW that had no way to reach it, so a radio, a checkbox and a
    # button each emitted the byte raw and put their second line at terminal column 1 while the
    # label control — which splits the lines itself — was correct all along.
    #
    # Each line is positioned at THIS call's own column, which is the one the box reserved.
    # Split before the clip test, not after, so a first line above the clip cannot take a second
    # line that is inside it. One test per call, on a string this function already scans.
    if [[ "$s" == *$'\n'* ]]; then
        local _pline _prow=$row
        while [[ "$s" == *$'\n'* ]]; do
            _pline=${s%%$'\n'*}; s=${s#*$'\n'}
            ft_print_at "$_prow" "$col" "$_pline"
            (( _prow++ ))
        done
        ft_print_at "$_prow" "$col" "$s"
        return 0
    fi
    (( row < FT_CLIP_R0 || row > FT_CLIP_R1 || col > FT_CLIP_C1 || col < FT_CLIP_C0 )) && return 0
    # NO TAB MAY REACH THE TERMINAL. This is the last gate before bytes go out, and a tab here
    # moves the cursor by an amount only the terminal knows — past the clip, past the control's
    # box, over whatever is next. Controls that build their own string (a button centring its
    # label) never pass through ft_fit, so guarding only there left them broken. One test per
    # call on a string this function already scans; ft_print_at_width is exempt because its
    # callers build their row with ft_fit, which has already expanded.
    [[ "$s" == *$'\t'* ]] && { ft_expand_tabs "$s"; s=$FT_RET; }
    # Byte length >= display width, so this cheap test only forces the exact
    # (per-character) width scan when the string MIGHT cross the right edge.
    if (( col + ${#s} > FT_CLIP_C1 )); then
        local maxw=$(( FT_CLIP_C1 - col + 1 ))
        ft_display_width "$s"
        # Truncation can cut a string's own trailing attribute resets off —
        # restore a clean slate so no underline/bold ever leaks past a clip.
        if (( FT_DISPLAY_WIDTH > maxw )); then ft_display_truncate "$s" "$maxw"; s="$FT_DISPLAY_TRUNCATED"$'\e[0m'; fi
    fi
    # ft_cursor_position inlined (this is the hottest call in the draw path — hundreds per
    # frame; the saved function call + FT_CURSOR_POSITION round-trip is measurable).
    printf -v FT_CURSOR_POSITION '\e[%d;%dH' "$(( row + 1 ))" "$(( col + 1 ))"
    FT_OUT+="$FT_CURSOR_POSITION$s"
    FT_BLOCK_BEING_DRAWN+="$FT_CURSOR_POSITION$s"       # …and into the block (see FT_BLOCK_BEING_DRAWN)
}
# ft_print_at_width ROW COL STR DISPWIDTH — ft_print_at for when the caller ALREADY KNOWS the
# string's display width (the common case: it was just built to fill an exact
# column count via ft_fit / a hrule / a fixed-width row). ft_print_at's cheap clip
# test is byte length, which for a colour-coded full-width row ALWAYS exceeds
# the right edge (SGR escapes inflate the byte count), forcing a per-character
# ft_display_width scan of that row on every single frame — the dominant cost
# of painting a large bordered window or a multi-row label. Passing the known
# width skips the scan entirely and only truncates when the row genuinely
# overhangs the clip. A page build makes 166–207 draw calls, ~85% of them here.
#
# WHY THIS IS A SECOND FUNCTION AND NOT AN OPTIONAL FOURTH ARGUMENT. It reads like
# one function with a detail you may omit, and that is not what it is. Measured on
# the same full-width coloured row (tools/bench-draw-primitive.bash, bash 5.2):
#
#     ft_print_at_width   44 µs        ft_print_at   368 µs
#
# They are not two spellings of one operation; the second asks a question the first
# has already been handed the answer to, and 8× is what the question costs. The
# split also carries a promise an optional argument cannot express: the caller of
# THIS function asserts its string is already tab-expanded, which is why the tab
# guard above is not repeated here (adding it back costs 8.4 µs a call, more than
# the merge it would be defending). Merging was priced too — one branch, +6.3 µs a
# width call, +0.95 ms on a page build and ~1% of a repaint, so it was affordable
# and still wrong. Two promises, two names.
ft_print_at_width() {
    local row=$1 col=$2 s=$3 w=$4
    (( row < FT_CLIP_R0 || row > FT_CLIP_R1 || col > FT_CLIP_C1 || col < FT_CLIP_C0 )) && return 0
    if (( col + w - 1 > FT_CLIP_C1 )); then
        # Overhang: cut to the clip and restore a clean slate (a truncated row
        # can lose its own trailing reset, which would leak attributes onward).
        ft_display_truncate "$s" $(( FT_CLIP_C1 - col + 1 )); s="$FT_DISPLAY_TRUNCATED"$'\e[0m'
    fi
    printf -v FT_CURSOR_POSITION '\e[%d;%dH' "$(( row + 1 ))" "$(( col + 1 ))"
    FT_OUT+="$FT_CURSOR_POSITION$s"
    FT_BLOCK_BEING_DRAWN+="$FT_CURSOR_POSITION$s"       # …and into the block (see FT_BLOCK_BEING_DRAWN)
}
# A control may set FT_CARET_FN to a function that appends a REAL terminal-
# cursor move to the frame (used by text fields: block cursor = overwrite, bar =
# insert). It runs just before the buffer is written, so the cursor lands on top
# of the painted frame; when nothing wants a caret it hides the cursor.
FT_CARET_FN=""
# Likewise a LAST-RESORT confirmation line (see ft_toast). It paints after everything
# else in the frame — including overlays — because its whole job is to be seen, and
# before the caret so the cursor still lands where the user is typing.
FT_TOAST_FN=""
ft_flush() {
    [[ -n "$FT_TOAST_FN" ]] && "$FT_TOAST_FN"
    [[ -n "$FT_CARET_FN" ]] && "$FT_CARET_FN"
    # Present the frame ATOMICALLY and with the cursor hidden the whole time it paints.
    # Otherwise the terminal applies every cursor-address as it arrives, so the cursor
    # skates across the frame before landing at the caret — the "flicker" that no amount
    # of animation-throttling could remove, because it is the DRAW itself, not the sheen.
    # ?2026 batches the update where supported; ?25l hides the cursor everywhere for the
    # duration (FT_CARET_FN already appended the show/park at the very end, inside FT_OUT).
    # FT_RECORD=<file>: append every frame's bytes as they ship — a flight recorder. Replaying
    # the file through tools/screen-cells.py reconstructs the exact screen a live session built
    # up, colours included, which is how a residue report from a REAL terminal becomes
    # cell-exact evidence (the test-residue technique, aimed at the field). One test-and-append
    # per flush when set; one [[ -z ]] when not.
    [[ -n "${FT_RECORD:-}" ]] && printf '%s' "$FT_OUT" >> "$FT_RECORD"
    printf '%s' "$FT_ANSI_SYNC_ON$FT_ANSI_CURSOR_HIDE$FT_OUT$FT_ANSI_SYNC_OFF" >&"$FT_TTY"; FT_OUT=""
    # …AND THE BLOCK NOBODY HARVESTED. ft_draw_one empties the recorder before each painter and
    # takes what comes back, so ink drawn INSIDE a draw is always claimed — but a print made
    # outside one (an app calling ft_print_at directly, a toast) has no draw to claim it and
    # would simply accumulate. Measured before this line existed: tools/bench-draw-primitive.bash
    # drives 2,000 prints with no draw around them and ft_print_at_width drifted from 68µs to
    # 2.2ms as the string grew. One frame is the natural bound, and this is where a frame ends.
    #
    # It cannot truncate a block that is still being recorded, because a PAINTER MAY NOT FLUSH:
    # this function writes FT_OUT to the tty and empties it, so a painter calling it mid-draw
    # would already be shipping half of the frame its caller was assembling. That invariant is
    # older than this line and this line only depends on it.
    FT_BLOCK_BEING_DRAWN=""
}

# ft_beep — ring the terminal bell (BEL). Buffered like any other output.
ft_beep() { FT_OUT+=$'\a'; ft_flush; }

# ft_clip_copy TEXT — put TEXT on the terminal's clipboard via OSC 52 (base64).
# base64 forks, but this only runs on an explicit user copy keystroke, never in a
# render or input hot path, and bash has no base64 builtin.
#
# Returns 0 if the clipboard was written, non-zero if it was left alone — and it is left
# alone in every case where the write would be wrong:
#
#   · NOTHING TO COPY. `\e]52;c;\a` — the sequence with an empty payload — does not mean
#     "do nothing", it means SET THE CLIPBOARD TO EMPTY. Copying an empty selection
#     therefore DESTROYED whatever the user had on their clipboard. In every other program
#     copying nothing does nothing, and that is now what this does.
#   · THE ENCODE FAILED. `base64` missing (or `tr`, whose stderr was not even redirected —
#     "tr: command not found" went to the alt screen) left the payload empty, and the same
#     empty-payload sequence went out. A failed copy wiped the clipboard. Worse than doing
#     nothing, and silent.
#   · TOO LARGE. A terminal parsing an OSC string has a ceiling — xterm's default is 74994
#     bytes — and past it the sequence is dropped, or parsing stops mid-string and the rest
#     of the base64 is printed as TEXT all over the UI. Refusing is honest; truncating would
#     hand back half a config file with no sign that it was cut. Raise FT_CLIP_MAX_BYTES if
#     your terminal takes more.
: "${FT_CLIP_MAX_BYTES:=74994}"
ft_clip_copy() {
    (( ${#1} == 0 )) && return 1                     # nothing to copy: leave the clipboard be
    local b64
    b64=$( { printf '%s' "$1" | base64 | tr -d '\n'; } 2>/dev/null )
    (( ${#b64} == 0 )) && return 1                   # encode failed — never send an empty payload
    (( ${#b64} > FT_CLIP_MAX_BYTES )) && return 2    # the terminal would drop it or print it
    [[ -n "${FT_TTY:-}" ]] || return 3
    printf '\e]52;c;%s\a' "$b64" >&"$FT_TTY" 2>/dev/null
}

# _ft_announce_copy RC [event-on-success] — say what the copy above actually did. Every
# copy in the framework goes through here, so "Copied" is never printed over a copy that
# did not happen. Here rather than in a control, because it reports ft_clip_copy's status
# and both a label and a text field need it — it started life in ft-textfield.bash, which
# made a LABEL's copy quietly depend on the text field having been sourced.
_ft_announce_copy() {           # rc [event]
    declare -F ft_emit_status >/dev/null || return 0    # no status bar in this app
    case $1 in
        0) ft_emit_status "${2:-textCopied}" ;;
        2) ft_emit_status copyTooLarge ;;
        *) ft_emit_status copyFailed ;;
    esac
    return 0
}

FT_FIT=""
ft_fit() {                              # FT_FIT = $1 fitted to display width $2
    local s=$1 w=$2
    # Expand here, not just when measuring: this is the string that gets PAINTED, and a raw tab
    # in it makes the terminal jump past the box (see ft_expand_tabs).
    [[ "$s" == *$'\t'* ]] && { ft_expand_tabs "$s"; s=$FT_RET; }
    ft_display_width "$s"
    if (( FT_DISPLAY_WIDTH > w )); then
        ft_display_truncate "$s" $(( w - 1 )); FT_FIT="${FT_DISPLAY_TRUNCATED}$FT_GLYPH_ELLIPSIS"
        # The truncation stops BEFORE a double-width glyph it cannot fit whole, so the result
        # can land a column short. Pad it back, or the row is narrower than it claims.
        ft_display_width "$FT_FIT"
        (( FT_DISPLAY_WIDTH < w )) && printf -v FT_FIT '%s%*s' "$FT_FIT" $(( w - FT_DISPLAY_WIDTH )) ''
    else
        local p=$(( w - FT_DISPLAY_WIDTH )); printf -v FT_FIT '%s%*s' "$s" "$p" ''
    fi
}
# ft_fit_align TEXT WIDTH ALIGN — like ft_fit but distributes the padding per
# CSS text-align (left | center | right). Left is the default and matches ft_fit.
ft_fit_align() {                        # text width align → FT_FIT
    local s=$1 w=$2 align=$3
    [[ "$align" == center || "$align" == right ]] || { ft_fit "$s" "$w"; return; }
    # Both of these are ft_fit's, and both were missing here — the guard had been added to
    # one route and not its sibling. A tab reaching the terminal makes it jump clear of the
    # box; a truncation that stops before a double-width glyph it cannot fit whole lands a
    # column SHORT, so a centred or right-aligned wide-glyph label claimed a width it did
    # not paint and everything after it on the row shifted a cell left.
    [[ "$s" == *$'\t'* ]] && { ft_expand_tabs "$s"; s=$FT_RET; }
    ft_display_width "$s"
    if (( FT_DISPLAY_WIDTH > w )); then
        ft_display_truncate "$s" $(( w - 1 )); FT_FIT="${FT_DISPLAY_TRUNCATED}$FT_GLYPH_ELLIPSIS"
        ft_display_width "$FT_FIT"
        (( FT_DISPLAY_WIDTH < w )) && printf -v FT_FIT '%s%*s' "$FT_FIT" $(( w - FT_DISPLAY_WIDTH )) ''
        return
    fi
    local pad=$(( w - FT_DISPLAY_WIDTH )) lp rp
    if [[ "$align" == center ]]; then lp=$(( pad / 2 )); rp=$(( pad - lp ))
    else lp=$pad; rp=0; fi
    printf -v FT_FIT '%*s%s%*s' "$lp" '' "$s" "$rp" ''
}

FT_WRAP_LINES=()
# fills FT_WRAP_LINES[] with $1 wrapped to display width $2. Tracks the
# current line's width INCREMENTALLY (line_w) rather than recomputing
# ft_display_width on the whole accumulated line every single word — the
# original version rescanned an up-to-`width`-character string on every one
# of a text's words, making it O(words * width) instead of O(total
# characters). For a genuinely large block of text (demo/growth-demo.bash's
# "large vertical text" scenario: ~1400 characters at width 50) that alone
# was ~90ms of a ~420ms rebuild — measurable, human-noticeable lag from an
# algorithmic issue, not a leak.
# Also fills FT_WRAP_CONT[] parallel to FT_WRAP_LINES: 1 if that visual line
# was SOFT-wrapped (it continues onto the next line), 0 if it ends a physical
# line. Labels with wrapIndicator=true draw a glyph on the continued ones.
FT_WRAP_CONT=()
ft_wrap() {
    FT_WRAP_LINES=(); FT_WRAP_CONT=()
    local text=$1 width=$2 phys line line_w tok tw rest
    (( width < 1 )) && width=1
    # Hard line breaks are sacred: wrap each embedded line separately, so
    # multi-line text (code snippets, paragraphs with \n) keeps its shape and
    # only genuinely-too-long lines soft-wrap.
    #
    # We do NOT collapse whitespace (that's the one CSS rule we reject on
    # purpose): this behaves like white-space:pre-wrap. Leading indentation and
    # multi-space gaps survive verbatim; wrapping only happens when a physical
    # line is genuinely wider than the box, and it breaks at word boundaries
    # (or hard-breaks a single token longer than the whole line).
    while IFS= read -r phys; do
        if [[ -z "$phys" ]]; then
            FT_WRAP_LINES+=(""); FT_WRAP_CONT+=(0)
            continue
        fi
        # Fast path: the whole physical line fits — emit it verbatim, every
        # space intact, no tokenising. This is also the hot path for prose.
        ft_display_width "$phys"
        if (( FT_DISPLAY_WIDTH <= width )); then
            FT_WRAP_LINES+=("$phys"); FT_WRAP_CONT+=(0)
            continue
        fi
        # Peel alternating runs of spaces / non-spaces off the front. Space
        # runs and word runs are both "tokens"; appending them rebuilds the
        # exact spacing. A space run that would overflow the end of a line is
        # swallowed at the break (trailing wrap-space hangs off-screen, as in
        # every editor); a word run that overflows moves to the next line; a
        # word run wider than the whole line is hard-broken.
        line=""; line_w=0; rest=$phys
        while [[ -n "$rest" ]]; do
            if [[ "$rest" == ' '* ]]; then tok=${rest%%[! ]*}; else tok=${rest%%[ ]*}; fi
            rest=${rest#"$tok"}
            ft_display_width "$tok"; tw=$FT_DISPLAY_WIDTH
            while (( tw > width )); do                 # token longer than a line
                if (( line_w > 0 )); then
                    FT_WRAP_LINES+=("$line"); FT_WRAP_CONT+=(1); line=""; line_w=0
                fi
                ft_display_truncate "$tok" "$width"
                FT_WRAP_LINES+=("$FT_DISPLAY_TRUNCATED"); FT_WRAP_CONT+=(1)
                tok=${tok#"$FT_DISPLAY_TRUNCATED"}; ft_display_width "$tok"; tw=$FT_DISPLAY_WIDTH
            done
            if (( line_w + tw <= width )); then
                line="$line$tok"; line_w=$(( line_w + tw ))
            else
                line="${line%"${line##*[! ]}"}"      # drop the space run left at the break
                FT_WRAP_LINES+=("$line"); FT_WRAP_CONT+=(1)
                if [[ "$tok" == ' '* ]]; then line=""; line_w=0       # swallow wrap-space
                else line="$tok"; line_w=$tw; fi
            fi
        done
        FT_WRAP_LINES+=("$line"); FT_WRAP_CONT+=(0)
    done <<< "$text"
}

# _ft_wrap_cached NAME TEXT WIDTH → same result as ft_wrap (FT_WRAP_LINES),
# but skips the recompute when NAME's text/width match the last call. Without
# this, a label with a scrollbar (demo/growth-demo.bash, demo/scrollbar-
# demo.bash) re-wraps its ENTIRE text from scratch on every single Up/Down
# tick, twice over (once in its own draw, once in ft_measure's remeasure of
# the bound subtree during a sibling status label's relayout) — scrollY never
# changes text or width, so both recomputes are pure waste. For ~20 lines of
# text that's tens of milliseconds of pure-bash looping PER keystroke, and
# arrow-key repeat fires faster than that — exactly the "insane CPU" a user
# hits by holding Up/Down. Cached per NAME (not globally) so distinct labels
# never collide; invalidated automatically the moment text or width differs.
#
# TWO slots per name, not one: a label with a scrollbar gutter wraps at BOTH
# `cols` (the gutter-decision measurement) and `cols-1` (the real text width)
# on every single draw. A single-slot cache thrashes between the two widths and
# re-wraps the entire text TWICE per frame — the dominant cost of a page draw
# (measured: a 6-row prose label spent ~30ms of a frame purely re-wrapping ~400
# chars it had already wrapped). A 2-slot round-robin retains both widths, so
# after warmup a static label re-wraps zero times.
# _ft_wrap_cache_extend NAME OLDTEXT NEWTEXT ADDED — after text was APPENDED, carry each
# live wrap slot forward instead of throwing it away. Word wrapping never crosses a newline,
# so the rows already computed for OLDTEXT stay valid verbatim and only ADDED needs wrapping:
# O(added) instead of O(whole text). This is what stops a growing log from re-wrapping
# everything it has ever printed on every single line that arrives.
# Slots whose key does not match OLDTEXT are left alone (they simply miss later, as before).
_ft_wrap_cache_extend() {       # name oldtext newtext added [oldgen newgen]
    local name=$1 old=$2 new=$3 added=$4 oldgen=${5-} newgen=${6-}
    local slot keyvar key width head newkey
    for slot in 0 1; do
        keyvar="_fti_${name}__wrapkey${slot}"
        key=${!keyvar-}
        [[ -n "$key" ]] || continue
        width=${key##*$'\x1c'}
        head=${key%$'\x1c'*}
        # A slot is ours to extend if it holds the OLD text — under either key form.
        if [[ -n "$oldgen" && "$head" == $'\x1d'"$oldgen" ]]; then
            newkey=$'\x1d'"$newgen"$'\x1c'"$width"
        elif [[ "$head" == "$old" ]]; then
            newkey="$new"$'\x1c'"$width"
        else
            continue                                    # a different text: leave it be
        fi
        local -n _ft_we="_fti_${name}__wraplines${slot}"
        # The appended chunk begins a fresh line, so its rows simply follow. Append IN PLACE:
        # ft_wrap writes FT_WRAP_LINES, a different array, so there is nothing to copy out of
        # the way first — and copying a 1000-row cache aside and back on every appended line
        # was itself O(n) per append, which is the whole thing this is meant to avoid.
        ft_wrap "$added" "$width"
        _ft_we+=("${FT_WRAP_LINES[@]}")
        printf -v "$keyvar" '%s' "$newkey"
    done
    return 0
}
# GEN (optional) — see _ft_text_extent_cached. Pass it only when TEXT is the control's own
# text/value property; the key then becomes gen+width, so a hit is an integer compare rather
# than a compare of the whole text (14ms on a 1000-line log, twice per frame).
ft_wrap_cached() {              # name text width [gen] → sets FT_WRAP_LINES
    local name=$1 text=$2 width=$3 gen=${4-}
    local key
    if [[ -n "$gen" ]]; then key=$'\x1d'"$gen"$'\x1c'"$width"   # \x1d marks a generation key
    else                     key="$text"$'\x1c'"$width"; fi
    # _fti_ = the engine's per-control side tables, namespaced for the same reason properties
    # are (_ftp_): bash's dynamic scoping would otherwise let a caller's local alias one.
    local k0="_fti_${name}__wrapkey0" k1="_fti_${name}__wrapkey1"
    if [[ "${!k0-}" == "$key" ]]; then
        local -n _ft_wc="_fti_${name}__wraplines0"; FT_WRAP_LINES=("${_ft_wc[@]}"); return
    fi
    if [[ "${!k1-}" == "$key" ]]; then
        local -n _ft_wc="_fti_${name}__wraplines1"; FT_WRAP_LINES=("${_ft_wc[@]}"); return
    fi
    ft_wrap "$text" "$width"
    # Evict the older slot (round-robin via a per-name toggle).
    local tvar="_fti_${name}__wrapnext"; local slot=${!tvar:-0}
    printf -v "$tvar" '%s' $(( slot ^ 1 ))
    printf -v "_fti_${name}__wrapkey${slot}" '%s' "$key"
    declare -ga "_fti_${name}__wraplines${slot}=()"
    local -n _ft_wc="_fti_${name}__wraplines${slot}"
    _ft_wc=("${FT_WRAP_LINES[@]}")
}

# Horizontal rule of width $1 using the box H glyph → FT_HRULE.
FT_HRULE=""
ft_hrule() { printf -v FT_HRULE '%*s' "$1" ''; FT_HRULE=${FT_HRULE// /$FT_GLYPH_HORIZONTAL}; }

# Convenience: run the standard startup sequence (locale → glyphs → palette).
ft_init() { ft_setup_locale; ft_setup_glyphs; ft_setup_palette; ft_detect_color_mode; }
