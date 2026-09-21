#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — fruity-tui.bash
#
#  Umbrella include. Sourcing this one file pulls in the whole toolkit in the
#  correct order: the non-optional layers (core, input layer, forms framework)
#  plus the bundled controls. A host that wants a minimal footprint can instead
#  source just the layers/controls it needs; every file is header-guarded and
#  pulls its own hard dependencies, so includes compose safely either way.
#
#    source /path/to/fruity-tui/fruity-tui.bash
#    ft_init
# ─────────────────────────────────────────────────────────────────────────────
_FT_LIBRARY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Non-optional layers.
source "$_FT_LIBRARY_DIR/ft-core.bash"
source "$_FT_LIBRARY_DIR/ft-keyboard.bash"     # terminal keyboard-protocol negotiation
source "$_FT_LIBRARY_DIR/ft-inputlayer.bash"
source "$_FT_LIBRARY_DIR/ft-keymap.bash"
source "$_FT_LIBRARY_DIR/ft-forms.bash"
source "$_FT_LIBRARY_DIR/ft-css.bash"          # CSS cascade engine (stylesheets, selectors, var())
source "$_FT_LIBRARY_DIR/ft-transition.bash"   # `transition:` — a control morphing in from the ground
source "$_FT_LIBRARY_DIR/ft-markdown.bash"     # rich-text renderer (markdown=true fields)
source "$_FT_LIBRARY_DIR/ft-wtfix.bash"        # Windows Terminal key-grab fixer (opt-in)

# Bundled controls (order-independent among themselves; all depend on core).
for _ft_ctl in frame boxheader heading label keylegend statusbar button multitoggle checkbox radio scrollbar slider select textfield tree table tabs binder beacon; do
    source "$_FT_LIBRARY_DIR/controls/ft-${_ft_ctl}.bash"
done
unset _ft_ctl

# F1 help system (depends on tabs + textfield being loaded above).
source "$_FT_LIBRARY_DIR/ft-help.bash"
source "$_FT_LIBRARY_DIR/ft-settings.bash"     # Settings modal (capabilities + toggles)
source "$_FT_LIBRARY_DIR/ft-filedialog.bash"   # Open/Save file dialog (ft_file_dialog)
source "$_FT_LIBRARY_DIR/ft-state.bash"        # Ctrl+S — serialise/reload the whole UI

# Tear the input coproc down cleanly during terminal restore.
FT_ON_RESTORE=ft_stop_input