#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — ft-filedialog.bash   (a convenient Open/Save file dialog)
#
#  ft_file_dialog [property=value …] → FT_FILE_RESULT (chosen path) or "" if
#  cancelled; returns 0 when a path was chosen, 1 on cancel. Same property=value
#  style as the rest of the API:
#     operation=open|save    which mode (sets the default submit label)
#     path=PATH              starting location — a directory, or a dir/file whose
#                            basename pre-fills the filename (default: $HOME)
#     title=TEXT             window title            (default: Open File / Save File)
#     submit=TEXT            submit-button label      (default: Open / Save)
#
#     e.g.  ft_file_dialog operation=save path=~/settings.conf submit=Save
#
#  Windows-like conveniences: a Places pane down the left (Home, Desktop, Documents,
#  Downloads, filesystem root — plus the Windows user's folders when running under
#  WSL), a live path header, a folders-first listing with “..”, a filename field,
#  and a Help button. Arrows move, Enter opens a folder / picks a file, Tab moves
#  between panes, Esc cancels.
#
#  The dialog is composed of ordinary controls — its file/places panes are LIST
#  BOXES (ft-select), NOT a tree; a real ft-tree is used only by the (future)
#  Tree view mode. Depends on ft-forms, ft-frame, ft-select, ft-textfield,
#  ft-button, ft-help.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_FILEDIALOG_LOADED:-}" ]] && return 0
_FT_FILEDIALOG_LOADED=1

FT_FILE_RESULT=""                 # chosen path (or "" if cancelled)
_FT_FILE_DIALOG_DIR=""                     # current directory
_FT_FILE_DIALOG_MODE=open                  # open | save
_FT_FILE_DIALOG_SUBMIT="Open"              # submit button label
_FT_FILE_DIALOG_TITLE=""                   # window title
_FT_FILE_DIALOG_NAME=""                    # filename-field value
_FT_FILE_DIALOG_ACTION=""                  # set by hooks: cd | submit | cancel | help | pick
_FT_FILE_DIALOG_TARGET=""                  # payload for the action (a path)

# ── Directory model ──────────────────────────────────────────────────────────
# _ft_fd_scan DIR → _FT_FILE_DIALOG_NAMES[] (basenames) / _FT_FILE_DIALOG_IS_DIR[] (1|0), folders
# first then files, case-insensitively sorted, hidden entries skipped. Fork-free.
_ft_fd_scan() {
    local dir=$1 e base
    _FT_FILE_DIALOG_NAMES=(); _FT_FILE_DIALOG_IS_DIR=()
    local -a dirs=() files=()
    # BASH ALREADY SORTED THIS. Pathname expansion returns its matches in LC_COLLATE order, done
    # in C inside the shell — so the listing arrives sorted for free, and partitioning it into
    # folders and files preserves that order within each group. What the old code bought with
    # two `sort -f` forks was only the CASE-INSENSITIVITY, because ft_setup_locale prefers
    # C.UTF-8, which collates by codepoint (every capital before every lowercase). Borrowing a
    # language locale for the length of this function buys the same thing for an assignment.
    #
    # Measured on this box: the two forks cost 7.4ms on a 20-entry directory against 0.5ms for
    # the whole walk — 94% of a directory change, and it is a keystroke the user waits on.
    # Sorting in bash instead is NOT the answer: an insertion sort of 2000 entries takes 11.9
    # SECONDS and a merge sort 569ms, against 37ms for the fork. The shell cannot sort; it can
    # only be asked to have sorted already.
    if [[ -n "${FT_COLLATE:-}" ]]; then local LC_ALL="" LC_COLLATE="$FT_COLLATE"; fi
    shopt -s nullglob
    for e in "$dir"/*; do
        base=${e##*/}
        if [[ -d "$e" ]]; then dirs+=("$base"); else files+=("$base"); fi
    done
    shopt -u nullglob
    for e in "${dirs[@]}";  do _FT_FILE_DIALOG_NAMES+=("$e"); _FT_FILE_DIALOG_IS_DIR+=(1); done
    for e in "${files[@]}"; do _FT_FILE_DIALOG_NAMES+=("$e"); _FT_FILE_DIALOG_IS_DIR+=(0); done
}

# Normalise a path: resolve "." / ".." segments; keep it absolute. Fork-free.
_ft_fd_norm() {                 # path → FT_RET
    local p=$1
    [[ "$p" != /* ]] && p="$_FT_FILE_DIALOG_DIR/$p"
    local oldifs=$IFS seg; local -a parts out=()
    IFS=/; parts=($p); IFS=$oldifs
    for seg in "${parts[@]}"; do
        case "$seg" in
            ''|.) ;;
            ..) (( ${#out[@]} > 0 )) && unset 'out[${#out[@]}-1]' ;;
            *)  out+=("$seg") ;;
        esac
    done
    if (( ${#out[@]} == 0 )); then FT_RET="/"
    else local IFS=/; FT_RET="/${out[*]}"; fi
}

# ── Places (the left shortcuts pane) ─────────────────────────────────────────
# _ft_fd_winhome → FT_RET: the Windows user profile dir under WSL (/mnt/c/Users/X),
# or "" if not on WSL / not found. Picks the first real user (skips Public/Default).
_ft_fd_winhome() {
    FT_RET=""
    local base d name
    for base in /mnt/c/Users /c/Users /cygdrive/c/Users; do
        [[ -d "$base" ]] || continue
        # PREFER the profile matching the current user — on WSL C:\Users\<you> is
        # almost always the same person, and guessing by scan picks the wrong one.
        for name in "${USER:-}" "${LOGNAME:-}"; do
            [[ -n "$name" && -d "$base/$name" ]] && { FT_RET="$base/$name"; return 0; }
        done
        # Otherwise take the first REAL profile. The skip list must cover Windows'
        # system profiles including the dotted variants (Default.migrated sorts
        # before a real user name and would otherwise win — the "no Windows files" bug).
        for d in "$base"/*/; do
            d=${d%/}; name=${d##*/}
            case "$name" in
                Public|Default|Default.*|"Default User"|"All Users"|defaultuser*|WDAGUtilityAccount|systemprofile) continue ;;
            esac
            [[ -d "$d/Desktop" || -d "$d/Documents" ]] && { FT_RET=$d; return 0; }
        done
    done
    return 1
}

# _ft_fd_places → parallel _FT_FILE_DIALOG_PLACE_LABEL[] / _FT_FILE_DIALOG_PLACE_PATH[] (only those
# that actually exist, in label/path pairs).
_ft_fd_places() {
    _FT_FILE_DIALOG_PLACE_LABEL=(); _FT_FILE_DIALOG_PLACE_PATH=()
    local -a want=( "Home" "$HOME" "Desktop" "$HOME/Desktop" \
                    "Documents" "$HOME/Documents" "Downloads" "$HOME/Downloads" )
    _ft_fd_winhome; local w=$FT_RET
    [[ -n "$w" ]] && want+=( "Win Home" "$w" "Win Desktop" "$w/Desktop" \
                             "Win Documents" "$w/Documents" "Win Downloads" "$w/Downloads" )
    want+=( "/  (root)" "/" )
    local i
    for (( i=0; i<${#want[@]}; i+=2 )); do
        [[ -d "${want[$((i+1))]}" ]] && { _FT_FILE_DIALOG_PLACE_LABEL+=("${want[$i]}"); _FT_FILE_DIALOG_PLACE_PATH+=("${want[$((i+1))]}"); }
    done
}

# ── Button / list hooks (live only while the dialog is up) ────────────────────
__fdcancel_on_activate() { _FT_FILE_DIALOG_ACTION=cancel; }
__fdhelp_on_activate()   { _FT_FILE_DIALOG_ACTION=help; }
__fdsubmit_on_activate() { _FT_FILE_DIALOG_ACTION=submit; }
_ft_fd_go() { _FT_FILE_DIALOG_ACTION=cd; _FT_FILE_DIALOG_TARGET=$1; }
# Backspace = up a level. Bound on the FORM, so it only fires when the LISTING
# (or another non-consuming control) has focus — the filename field's own
# Backspace (delete a char) shadows it while you're typing there.
__fd_up() { _ft_fd_norm "$_FT_FILE_DIALOG_DIR/.."; _FT_FILE_DIALOG_ACTION=cd; _FT_FILE_DIALOG_TARGET=$FT_RET; }
# The listing tree: Enter on a folder navigates in; on a file it picks it. The
# node's value is "d:name" or "f:name" so the hook knows which.
__fdlist_on_activate() {
    local v=$1
    if [[ "$v" == d:* ]]; then _FT_FILE_DIALOG_ACTION=cd; _ft_fd_norm "$_FT_FILE_DIALOG_DIR/${v#d:}"; _FT_FILE_DIALOG_TARGET=$FT_RET
    elif [[ "$v" == f:* ]]; then _FT_FILE_DIALOG_NAME=${v#f:}; ft-modify __fdname text="$_FT_FILE_DIALOG_NAME"; _FT_FILE_DIALOG_ACTION=pick; fi
}
# The Places tree: nodes keyed "p:<index>" into _FT_FILE_DIALOG_PLACE_PATH (indices dodge
# any spaces in the paths).
__fdplaces_on_activate() {
    local v=$1; [[ "$v" == p:* ]] && _ft_fd_go "${_FT_FILE_DIALOG_PLACE_PATH[${v#p:}]}"
}

# ── Build the dialog form for the current directory ──────────────────────────
_ft_fd_build() {
    _ft_fd_scan "$_FT_FILE_DIALOG_DIR"
    _ft_fd_places
    local ww=$(( FT_COLS - 6 )); (( ww > 76 )) && ww=76; (( ww < 40 )) && ww=40
    local wh=$(( FT_ROWS - 4 )); (( wh > 24 )) && wh=24; (( wh < 12 )) && wh=12
    # wh budget: title/border + path + list + name field + buttons + the 2-row
    # status bar at the very bottom. Reserve 10 rows of chrome for the listing.
    local placew=18 listrows=$(( wh - 10 )); (( listrows < 4 )) && listrows=4
    local listw=$(( ww - placew - 5 ))
    local i n=${#_FT_FILE_DIALOG_NAMES[@]}
    # counts for the status synopsis (folders vs files, the ".." row excluded)
    local nd=0 nf=0
    for (( i=0; i<n; i++ )); do (( _FT_FILE_DIALOG_IS_DIR[i] )) && (( nd++ )) || (( nf++ )); done
    local synopsis="$nd folder"; (( nd == 1 )) || synopsis+="s"
    synopsis+=", $nf file"; (( nf == 1 )) || synopsis+="s"

    ft-form name=__fd width="$FT_COLS" height="$FT_ROWS" \
            display=flex justifyContent=center alignItems=center \
            key=BACKSPACE keyCode=__fd_up key=ALT+up keyCode=__fd_up
        ft-frame name=__fdwin title=" $_FT_FILE_DIALOG_TITLE " borderStyle=double \
                 display=flex flexDirection=column gap=0 padding=1 width="$ww" height="$wh"

            local subaccel=${_FT_FILE_DIALOG_SUBMIT:0:1}
            ft-label name=__fdpath color=muted "$_FT_FILE_DIALOG_DIR"
            ft-div name=__fdmain display=flex gap=1 width=$(( ww - 4 )) height=$(( listrows + 2 ))

                # The dialog is NOT a tree — the panes are LIST BOXES (ft-select).
                # Enter fires each list's on_activate with the row's value, which is
                # how a folder opens / a file is picked. (A real ft-tree is composed
                # ONLY when the future Tree view mode is selected.)
                ft-select name=__fdplaces size="$listrows" width="$placew" showSelected=false onActivate=__fdplaces_on_activate
                    for (( i=0; i<${#_FT_FILE_DIALOG_PLACE_LABEL[@]}; i++ )); do
                        ft-option value="p:$i" "${_FT_FILE_DIALOG_PLACE_LABEL[$i]}"
                    done
                end_ft_select

                ft-select name=__fdlist size="$listrows" width="$listw" showSelected=false onActivate=__fdlist_on_activate
                    ft-option value="d:.." ".. (up a level)"
                    for (( i=0; i<n; i++ )); do
                        if (( _FT_FILE_DIALOG_IS_DIR[i] )); then
                            ft-option value="d:${_FT_FILE_DIALOG_NAMES[$i]}" "${_FT_FILE_DIALOG_NAMES[$i]}/"
                        else
                            ft-option value="f:${_FT_FILE_DIALOG_NAMES[$i]}" "${_FT_FILE_DIALOG_NAMES[$i]}"
                        fi
                    done
                end_ft_select
            end_ft_div

            ft-label name=__fdnl "File name:"
            ft-textfield name=__fdname size=$(( ww - 6 )) value="$_FT_FILE_DIALOG_NAME"
            ft-div name=__fdbtns display=flex gap=2 justifyContent=end width=$(( ww - 4 ))
                ft-button name=__fdsubmit accessKey="$subaccel" "$_FT_FILE_DIALOG_SUBMIT" onActivate=__fdsubmit_on_activate
                ft-button name=__fdcancel accessKey=C "Cancel" onActivate=__fdcancel_on_activate
                ft-button name=__fdhelp   accessKey=H "Help" onActivate=__fdhelp_on_activate
            end_ft_div

            # The bottom bar: what the keys do (top) + a live folder synopsis. Enter
            # opens a folder / picks a file; the submit button is its ACCELERATOR
            # (S for Save, O for Open) — so the legend reads "S: Save", not "Enter".
            ft-keylegend name=__fdlegend \
                keys="${subaccel^^}=$_FT_FILE_DIALOG_SUBMIT  Enter=Open  Bksp=Up  Tab=Panes  Esc=Cancel"
            ft-statusbar name=__fdstatus \
                status="$_FT_FILE_DIALOG_DIR  —  $synopsis"
        end_ft_frame
    end_ft_form
}

# ── The dialog itself ────────────────────────────────────────────────────────
ft_file_dialog() {
    _FT_FILE_DIALOG_MODE=open; _FT_FILE_DIALOG_SUBMIT=""; _FT_FILE_DIALOG_TITLE=""; _FT_FILE_DIALOG_NAME=""
    local a dir=$HOME path=""
    for a in "$@"; do
        case "$a" in
            operation=*) _FT_FILE_DIALOG_MODE=${a#*=} ;;
            path=*)      path=${a#*=} ;;
            title=*)     _FT_FILE_DIALOG_TITLE=${a#*=} ;;
            submit=*)    _FT_FILE_DIALOG_SUBMIT=${a#*=} ;;
            name=*)      _FT_FILE_DIALOG_NAME=${a#*=} ;;   # (also accepted; path= is the usual way)
        esac
    done
    [[ "$_FT_FILE_DIALOG_MODE" == save ]] || _FT_FILE_DIALOG_MODE=open
    # path= may be a directory (start there) or dir/file (start in the dir, pre-fill
    # the name). ~ is expanded.
    path=${path/#\~/$HOME}
    if [[ -n "$path" ]]; then
        if [[ -d "$path" ]]; then dir=$path
        else dir=${path%/*}; [[ "$dir" == "$path" ]] && dir=$PWD; _FT_FILE_DIALOG_NAME=${path##*/}; fi
    fi
    [[ -z "$_FT_FILE_DIALOG_SUBMIT" ]] && { [[ "$_FT_FILE_DIALOG_MODE" == save ]] && _FT_FILE_DIALOG_SUBMIT="Save" || _FT_FILE_DIALOG_SUBMIT="Open"; }
    [[ -z "$_FT_FILE_DIALOG_TITLE"  ]] && { [[ "$_FT_FILE_DIALOG_MODE" == save ]] && _FT_FILE_DIALOG_TITLE="Save File" || _FT_FILE_DIALOG_TITLE="Open File"; }
    [[ -d "$dir" ]] || dir=$HOME
    _ft_fd_norm "$dir"; _FT_FILE_DIALOG_DIR=$FT_RET
    FT_FILE_RESULT=""

    ft_modal_push
    local outcome=cancel
    while true; do
        _FT_FILE_DIALOG_ACTION=""
        _ft_fd_build
        FT_ROOT=__fd; FT_COALESCING=0
        ft_layout __fd; ft_focus __fdlist
        ft_repaint_all __fd

        local rc tok rebuild=0
        while true; do
            ft_next_event; rc=$?
            if (( rc == 2 )); then
                FT_WINCH=0; ft_term_size
                _ft_setprop __fd width "$FT_COLS"; _ft_setprop __fd height "$FT_ROWS"
                ft_layout __fd; ft_repaint_all __fd; continue
            fi
            (( rc != 0 )) && { outcome=cancel; break 2; }
            # Esc: if you're editing the filename field, leave edit mode; otherwise
            # Esc cancels the dialog. (It never opens a menu.)
            if [[ "$FT_EVENT_TOKEN" == ESC ]]; then
                local _f=${FT_FOCUS:-}
                if [[ "${FT_TYPE[$_f]:-}" == textfield ]] && _ft_textfield_engaged "$_f"; then
                    ft_dispatch_event ESC; ft_redraw_dirty; continue
                fi
                outcome=cancel; break 2
            fi
            if [[ "$FT_EVENT_TOKEN" == MOUSE ]]; then _ft_dispatch_mouse
            else tok=$FT_EVENT_TOKEN; [[ "$FT_EVENT_TOKEN" == CHAR ]] && tok=$FT_EVENT_CHAR; ft_dispatch_event "$tok"; fi

            case "$_FT_FILE_DIALOG_ACTION" in
                cd)     _FT_FILE_DIALOG_DIR=$_FT_FILE_DIALOG_TARGET; _FT_FILE_DIALOG_ACTION=""; rebuild=1; break ;;
                submit) outcome=submit; break 2 ;;
                cancel) outcome=cancel; break 2 ;;
                help)   _FT_FILE_DIALOG_ACTION=""; declare -F ft_help >/dev/null && ft_help ;;
                pick)   _FT_FILE_DIALOG_ACTION=""; ft_focus __fdname ;;   # filename filled; let them submit
            esac
            ft_redraw_dirty
        done
        (( rebuild )) && { ft_remove __fd; continue; }
    done

    # Pull the (possibly edited) filename before we tear the form down.
    [[ -n "${FT_TYPE[__fdname]:-}" ]] && { ft_get __fdname value; _FT_FILE_DIALOG_NAME=$FT_RET; }
    ft_remove __fd
    ft_modal_pop
    ft_repaint_all "$FT_ROOT"

    if [[ "$outcome" == submit && -n "$_FT_FILE_DIALOG_NAME" ]]; then
        _ft_fd_norm "$_FT_FILE_DIALOG_DIR/$_FT_FILE_DIALOG_NAME"; FT_FILE_RESULT=$FT_RET; return 0
    fi
    FT_FILE_RESULT=""; return 1
}
