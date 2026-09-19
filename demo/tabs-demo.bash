#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  demo/tabs-demo.bash — the ft-tabs control holding REAL controls.
#
#  Proof that a composite control is just a control that arranges other
#  controls: each tab body is an ordinary subtree of text fields, checkboxes,
#  sliders, a table, radios and a dropdown — nothing tab-aware about any of
#  them. ←/→ (or Home/End) switch tabs while the tab strip is focused; Tab
#  flows focus INTO the active tab's controls (the hidden tabs' controls are
#  skipped automatically); Shift+Tab walks back out to the strip.
#
#  Run:  bash demo/tabs-demo.bash
# ─────────────────────────────────────────────────────────────────────────────
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./fruity-tui.bash
ft_init
ft_term_size

# Windows Terminal grabs Ctrl+Shift+Home/End/Up/Down for scrollback, so a TUI
# never sees them. Free them for the duration of this run (the fix is REVERSED
# automatically on exit — even on Ctrl+C/kill — and a kill -9'd run self-heals on
# next launch). Idempotent, backs up settings.json, no-op off Windows. Opt out
# with FT_NO_WTFIX=1; also toggleable live from Settings.
[[ -z "${FT_NO_WTFIX:-}" ]] && declare -F ft_wt_autofix_enter >/dev/null && ft_wt_autofix_enter

_status() { ft-modify status text="$1"; }

fUser_on_change() { _status "user = \"$1\""; }
fHost_on_change() { _status "host = \"$1\""; }
cbRemember_on_change() { _status "remember = $1"; }
volume_on_change() { _status "volume = $1"; }
bright_on_change() { _status "brightness = $1"; }
picker_on_change() { _status "switched to tab #$(( $1 + 1 ))"; }   # ft-tabs on_change → index

btnQuit_on_activate() { ft_quit; }

# Instance accelerators: keys 1..4 jump straight to a tab (NOT built into the
# ft-tabs prototype — just this demo's form keymap). A focused text field still
# eats the digit (types it), so this only fires when you're not editing a field.
_tab1() { ft_tabs_select picker 0; }
_tab2() { ft_tabs_select picker 1; }
_tab3() { ft_tabs_select picker 2; }
_tab4() { ft_tabs_select picker 3; }

# A working theme switch (the three palettes from the main tutorial).
apply_theme() {
    case "$1" in
        light)
            FT_COLOR_SCREEN=$'\e[48;5;250;38;5;240m';  FT_COLOR_BODY=$'\e[48;5;254;38;5;235m'
            FT_COLOR_TITLE=$'\e[48;5;254;38;5;25;1m';  FT_COLOR_BORDER=$'\e[48;5;254;38;5;244m'
            FT_COLOR_DIVIDER=$'\e[48;5;254;38;5;249m'; FT_COLOR_FOCUS=$'\e[48;5;25;38;5;255;1m'
            FT_COLOR_SELECTED=$'\e[48;5;29;38;5;255m'; FT_COLOR_INPUT=$'\e[48;5;252;38;5;235m'
            FT_COLOR_INPUT_FOCUS=$'\e[48;5;153;38;5;17m'; FT_COLOR_FADED=$'\e[48;5;252;38;5;245m'
            FT_COLOR_STRIPE=$'\e[48;5;251;38;5;235m'
            FT_COLOR_TEXT_NOTICE=$'\e[38;5;130m'; FT_COLOR_TEXT_ACCENT=$'\e[38;5;25m'; FT_COLOR_TEXT_MUTED=$'\e[38;5;245m'
            FT_COLOR_RESET="$FT_COLOR_BODY"; FT_CURSOR_COLOR='#005fd7' ;;
        ocean)
            FT_COLOR_SCREEN=$'\e[48;5;17;38;5;111m';   FT_COLOR_BODY=$'\e[48;5;23;38;5;231m'
            FT_COLOR_TITLE=$'\e[48;5;23;38;5;123;1m';  FT_COLOR_BORDER=$'\e[48;5;23;38;5;80m'
            FT_COLOR_DIVIDER=$'\e[48;5;23;38;5;66m';   FT_COLOR_FOCUS=$'\e[48;5;51;38;5;17;1m'
            FT_COLOR_SELECTED=$'\e[48;5;41;38;5;16;1m'; FT_COLOR_INPUT=$'\e[48;5;17;38;5;159m'
            FT_COLOR_INPUT_FOCUS=$'\e[48;5;31;38;5;231m'; FT_COLOR_FADED=$'\e[48;5;17;38;5;66m'
            FT_COLOR_STRIPE=$'\e[48;5;24;38;5;231m'
            FT_COLOR_TEXT_NOTICE=$'\e[38;5;222m'; FT_COLOR_TEXT_ACCENT=$'\e[38;5;51m'; FT_COLOR_TEXT_MUTED=$'\e[38;5;66m'
            FT_COLOR_RESET="$FT_COLOR_BODY"; FT_CURSOR_COLOR='#00d7ff' ;;
        *)  ft_setup_palette ;;   # dark: the default
    esac
}
theme_on_change() { apply_theme "$1"; ft_refresh; }

_build() {
    ft-empty app
        ft-frame name=win title="ft-tabs — a control full of controls" \
                 display=flex flexDirection=column gap=1 padding=1 alignItems=center \
                 borderStyle=double
            ft-tabs name=picker width=58 height=14 activeTab=0 onChange=picker_on_change
                # ── Tab 1: a little form (text fields + checkbox) ──────────────
                ft-tab title="Account (1)"
                    ft-div name=rowU display=flex gap=1 alignItems=center
                        ft-label name=lU text="User" width=6
                        ft-textfield name=fUser size=26 value="admin" placeholder="username" onChange=fUser_on_change \
                                     helpLabel2="Field" helpAccel2="F" \
                                     helpText2="The domain administrator account (e.g. Administrator). Press F1 on any control for its help; ← → or the accelerator letters switch tabs; Esc closes."
                    end_ft_div
                    ft-div name=rowH display=flex gap=1 alignItems=center
                        ft-label name=lH text="Host" width=6
                        ft-textfield name=fHost size=26 placeholder="dc1.example.com" onChange=fHost_on_change
                    end_ft_div
                    ft-checkbox name=cbRemember "Remember me" accessKey=R checked=true onChange=cbRemember_on_change
                end_ft_tab
                # ── Tab 2: sliders ────────────────────────────────────────────
                ft-tab title="Tuning (2)"
                    ft-div name=rowV display=flex gap=1 alignItems=center
                        ft-label name=lV text="Volume" width=11
                        ft-slider name=volume min=0 max=100 value=70 width=30 variant=fill showValue=true onChange=volume_on_change
                    end_ft_div
                    ft-div name=rowB display=flex gap=1 alignItems=center
                        ft-label name=lB text="Brightness" width=11
                        ft-slider name=bright min=0 max=100 value=40 width=30 variant=blocks showValue=true onChange=bright_on_change
                    end_ft_div
                end_ft_tab
                # ── Tab 3: a data table ───────────────────────────────────────
                ft-tab title="Plan (3)"
                    ft-table name=plan variant=grid striped=true
                        ft-table-header "Task" width=18
                        ft-table-header "When"
                        ft-table-row "Provision DC"  "today"
                        ft-table-row "Join domain"   "tomorrow"
                        ft-table-row "Set up shares"  "this week"
                    end_ft_table
                end_ft_tab
                # ── Tab 4: radios + a dropdown ────────────────────────────────
                ft-tab title="Choices (4)"
                    ft-label name=lC text="Compression:"
                    ft-radio name=cNone  group=comp text="None"  accessKey=N
                    ft-radio name=cGzip  group=comp text="gzip"  accessKey=G
                    ft-radio name=cZstd  group=comp text="zstd"  accessKey=Z
                    ft-div name=rowT display=flex gap=1 alignItems=center
                        ft-label name=lT text="Theme" width=6
                        ft-select name=theme size=1 onChange=theme_on_change
                            ft-option value=dark  "Dark"
                            ft-option value=light "Light"
                            ft-option value=ocean "Ocean"
                        end_ft_select
                    end_ft_div
                end_ft_tab
            end_ft_tabs

            ft-label name=status text="←/→ or 1-4 switch tabs · Tab enters · Esc = menu · Shift+Tab leaves" \
                     width=60 color=notice textAlign=center
            ft-div name=btnrow display=flex gap=2 justifyContent=center
                ft-button name=btnQuit Quit accessKey=Q onActivate=btnQuit_on_activate
            end_ft_div
        end_ft_frame
    end_ft_form
    ft_refresh
    ft_focus picker
}

ft-form name=app width="$FT_COLS" height="$FT_ROWS" \
        display=flex justifyContent=center alignItems=center \
        keymap '[Qq]'=ft_quit 1=_tab1 2=_tab2 3=_tab3 4=_tab4
end_ft_form
ft-run app _build
