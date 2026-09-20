#!/usr/bin/env bash
# Tests for ft-filedialog.bash: path normalisation, directory scanning (folders
# first), the Places list, the dialog build, and the navigation hooks.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=80; FT_ROWS=24

note "path normalisation resolves . and .. , stays absolute"
_FT_FILE_DIALOG_DIR=/home/me
_ft_fd_norm "/a/b/../c";      check "/a/b/../c → /a/c"        "$FT_RET" "/a/c"
_ft_fd_norm "/a/./b/";        check "/a/./b/ → /a/b"          "$FT_RET" "/a/b"
_ft_fd_norm "/a/b/c/../../";  check "climb two → /a"          "$FT_RET" "/a"
_ft_fd_norm "/../..";         check "can't climb past root"   "$FT_RET" "/"
_ft_fd_norm "sub/dir";        check "relative → joined onto cwd" "$FT_RET" "/home/me/sub/dir"
_ft_fd_norm "/home/me/..";    check "up from home → /home"    "$FT_RET" "/home"

note "scan lists folders first, then files, hidden skipped, sorted"
D=$(mktemp -d)
mkdir "$D/zeta" "$D/alpha" "$D/.hidden"
: > "$D/banana.txt"; : > "$D/Apple.md"; : > "$D/.secret"
_ft_fd_scan "$D"
check "entry count (2 dirs + 2 files, hidden skipped)" "${#_FT_FILE_DIALOG_NAMES[@]}" "4"
check "first is a folder"      "${_FT_FILE_DIALOG_IS_DIR[0]}" "1"
check "folders sorted first"   "${_FT_FILE_DIALOG_NAMES[0]}"  "alpha"
check "second folder"          "${_FT_FILE_DIALOG_NAMES[1]}"  "zeta"
check "files follow"           "${_FT_FILE_DIALOG_IS_DIR[2]}"  "0"
check "files sorted (case-insensitive): Apple before banana" "${_FT_FILE_DIALOG_NAMES[2]}" "Apple.md"

note "the Windows profile picker skips SYSTEM profiles (Default.migrated sorts first!)"
if [[ -d /mnt/c/Users ]]; then
    _ft_fd_winhome
    case "${FT_RET##*/}" in
        Default|Default.*|Public|"All Users"|"Default User"|defaultuser*|WDAGUtilityAccount|systemprofile)
            check "winhome is a REAL profile, not a system one" "${FT_RET##*/}" "a real user" ;;
        *)  check "winhome is a REAL profile, not a system one" 1 1 ;;
    esac
else
    check "winhome check skipped (no /mnt/c on this host)" 1 1
fi

note "Places always has Home and the filesystem root"
HOME=$D _ft_fd_places
have() { local x; for x in "${_FT_FILE_DIALOG_PLACE_LABEL[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }
have "Home"        && check "Home present"        1 1 || check "Home present" 0 1
have "/  (root)"   && check "root labelled '/'"    1 1 || check "root labelled '/'" 0 1
last=$(( ${#_FT_FILE_DIALOG_PLACE_PATH[@]} - 1 ))
check "root path is /" "${_FT_FILE_DIALOG_PLACE_PATH[$last]}" "/"

note "the dialog builds all its parts for a directory"
_FT_FILE_DIALOG_DIR=$D; _FT_FILE_DIALOG_TITLE="Open File"; _FT_FILE_DIALOG_SUBMIT="Open"; _FT_FILE_DIALOG_NAME=""
HOME=$D _ft_fd_build
ft_layout __fd
for c in __fdpath __fdplaces __fdlist __fdname __fdsubmit __fdcancel __fdhelp; do
  check "$c built" "${FT_TYPE[$c]:-none}" "$([[ $c == __fdpath || $c == __fdnl ]] && echo label || { [[ $c == __fd*list || $c == __fdplaces ]] && echo select || { [[ $c == __fdname ]] && echo textfield || echo button; }; })"
done
ft_resolved_prop __fdsubmit text ""; check "submit button shows the label" "$FT_RET" "Open"
check "status bar built" "${FT_TYPE[__fdstatus]:-none}" "statusbar"
ft_resolved_prop __fdlist   showSelected ""; check "listing is a navigation list (no persistent ✓)" "$FT_RET" "false"
ft_resolved_prop __fdplaces showSelected ""; check "places is a navigation list (no persistent ✓)"  "$FT_RET" "false"
check "key legend built"   "${FT_TYPE[__fdlegend]:-none}" "keylegend"
_ft_get_raw __fdlegend keys; [[ -n "$FT_RET" ]] && check "key legend has caps" 1 1 || check "key legend has caps" 0 1
_ft_get_raw __fdstatus status; [[ "$FT_RET" == *"folder"* ]] && check "status shows folder count" 1 1 || check "status shows folder count" 0 1

note "list hooks: Enter on a folder navigates, on a file picks it"
_FT_FILE_DIALOG_DIR=$D; _FT_FILE_DIALOG_ACTION=""
__fdlist_on_activate "d:alpha"
check "folder → cd action"   "$_FT_FILE_DIALOG_ACTION" "cd"
check "folder → target path" "$_FT_FILE_DIALOG_TARGET" "$D/alpha"
_FT_FILE_DIALOG_ACTION=""; __fdlist_on_activate "d:.."
check ".. → cd up"           "$_FT_FILE_DIALOG_TARGET" "$(dirname "$D")"
_FT_FILE_DIALOG_ACTION=""; __fdlist_on_activate "f:banana.txt"
check "file → pick action"   "$_FT_FILE_DIALOG_ACTION" "pick"
check "file → filename set"  "$_FT_FILE_DIALOG_NAME"   "banana.txt"

note "places hook navigates by index"
_FT_FILE_DIALOG_ACTION=""; HOME=$D _ft_fd_places; __fdplaces_on_activate "p:0"
check "place 0 → cd"         "$_FT_FILE_DIALOG_ACTION" "cd"
check "place 0 → Home path"  "$_FT_FILE_DIALOG_TARGET" "${_FT_FILE_DIALOG_PLACE_PATH[0]}"

note "submit/cancel hooks set the outcome flag"
_FT_FILE_DIALOG_ACTION=""; __fdsubmit_on_activate; check "submit"  "$_FT_FILE_DIALOG_ACTION" "submit"
_FT_FILE_DIALOG_ACTION=""; __fdcancel_on_activate; check "cancel"  "$_FT_FILE_DIALOG_ACTION" "cancel"
ft_remove __fd 2>/dev/null

note "property=value args: operation=, path= (dir/file split), submit="
mkdir -p "$D/proj"
ft_next_event() { return 1; }        # make the modal loop cancel immediately
ft_file_dialog operation=save path="$D/proj/notes.txt" submit=Store
check "operation= parsed"       "$_FT_FILE_DIALOG_MODE"    "save"
check "path= directory parsed"  "$_FT_FILE_DIALOG_DIR"     "$D/proj"
check "path= basename → name"   "$_FT_FILE_DIALOG_NAME"    "notes.txt"
check "submit= label parsed"    "$_FT_FILE_DIALOG_SUBMIT"  "Store"
check "cancel → empty result"   "$FT_FILE_RESULT" ""
ft_file_dialog operation=open path="$D"
check "path= plain dir (no name)" "$_FT_FILE_DIALOG_DIR"   "$D"
check "open default submit"       "$_FT_FILE_DIALOG_SUBMIT" "Open"
unset -f ft_next_event

rm -rf "$D"
note "the listing is sorted WITHOUT forking — bash's own glob order does it"
# `sort -f` twice per directory change cost 7.4ms on a 20-entry directory against 0.5ms for
# the whole walk: 94% of a keystroke the user waits on. Pathname expansion already returns
# matches in LC_COLLATE order, and partitioning preserves it — the fork only ever bought
# case-insensitivity, which a borrowed language locale gives for an assignment. (Sorting in
# bash instead is not an option: 2000 entries take 11.9s by insertion sort, 569ms by merge.)
_fdsort=$(mktemp -d); trap 'rm -rf "$_fdsort"' EXIT
for _n in banana Apple cherry Date apricot Zebra README notes.txt; do : > "$_fdsort/$_n"; done
mkdir -p "$_fdsort/Docs" "$_fdsort/archive" "$_fdsort/Bin"
_ft_fd_scan "$_fdsort"
check "folders first, then files"        "${_FT_FILE_DIALOG_IS_DIR[*]}" "1 1 1 0 0 0 0 0 0 0 0"
check "folders sorted case-insensitively" "${_FT_FILE_DIALOG_NAMES[0]} ${_FT_FILE_DIALOG_NAMES[1]} ${_FT_FILE_DIALOG_NAMES[2]}" \
                                          "archive Bin Docs"
check "files sorted case-insensitively"   "${_FT_FILE_DIALOG_NAMES[*]:3}" \
                                          "Apple apricot banana cherry Date notes.txt README Zebra"
# …and the scan really is fork-free. `$((` is arithmetic, not a subshell — the pattern has to
# tell them apart or it flags every clamp in the file.
_fdsrc=$(sed -n '/^_ft_fd_scan()/,/^}/p' "$here/ft-filedialog.bash" | sed 's/#.*//')
_fdforks=$(printf '%s\n' "$_fdsrc" | grep -nE '\$\([^(]|<\(|`|\bsort\b' || true)
check "no fork left in _ft_fd_scan" "${_fdforks:-none}" "none"

summary
