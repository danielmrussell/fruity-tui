#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — controls/ft-tree.bash
#
#  A scrolling, collapsible tree of nodes with a focus cursor. Declared flat,
#  with a depth per node — a node is a BRANCH when the node after it is deeper:
#
#      ft-tree name=fs rows=10 width=30
#          ft-tree-node "src"           key=src   depth=0 expanded=true
#          ft-tree-node "ft-core.bash"  key=core  depth=1
#          ft-tree-node "controls"      key=ctl   depth=1 expanded=false
#          ft-tree-node "ft-tree.bash"  key=tree  depth=2
#          ft-tree-node "README.md"     key=rd    depth=0
#      end_ft_tree
#
#  Keys (while focused): ↑/↓ move the cursor over VISIBLE nodes; →/l expand a
#  branch (or step into its first child); ←/h collapse it (or step to the
#  parent); Enter/Space toggle a branch and "activate" a leaf; Home/End/PgUp/
#  PgDn jump. The tree keeps `value` = the cursor node's key, so a host reads the
#  current selection like any control; onChange=fn fires on cursor moves,
#  onActivate=fn on Enter over a leaf.
#
#  Depends on ft-core.bash and ft-forms.bash.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_TREE_LOADED:-}" ]] && return 0
_FT_TREE_LOADED=1

# Built once, by the class that declares `keymap=tree`.
_ft_define_keymap_tree() {
    # THE INACTIVE RUNG — merely focused. Almost nothing is bound: the arrows still belong
    # to focus navigation, so passing THROUGH a tree does not drive its cursor. Enter steps
    # inside. Copy is here too, because copying what you are standing next to needs no
    # permission (and at this rung it takes the WHOLE tree — see ft_tree_copy).
    ft-bindkeys ft_keymap_tree ENTER=ft_key_delve
    ft-keymap-cap ft_keymap_tree ENTER ft_key_delve "$FT_IMPORTANCE_CRUCIAL" "Open tree"

    # THE BROWSING RUNG — one Enter in. NOW the arrows are the tree's, all of them, and they
    # never bubble: once you have stepped into a control, exploring its keys must not be able
    # to throw you out of it. Esc leaves, Tab leaves.
    ft_keymap_once ft_keymap_tree_browsing
    ft-bindkeys ft_keymap_tree_browsing \
        UP=ft_tree_key_up      DOWN=ft_tree_key_down \
        LEFT=ft_tree_key_left  RIGHT=ft_tree_key_right \
        HOME=ft_tree_key_home  END=ft_tree_key_end \
        PGUP=ft_tree_key_pgup  PGDN=ft_tree_key_pgdn \
        ENTER=ft_tree_key_enter SPACE=ft_tree_key_enter \
        ESC=ft_key_undelve \
        CTRL+c=ft_tree_copy    ALT+w=ft_tree_copy
    ft-keymap-cap ft_keymap_tree_browsing UP    ft_tree_key_up    "$FT_IMPORTANCE_CRUCIAL"   "Up"
    ft-keymap-cap ft_keymap_tree_browsing DOWN  ft_tree_key_down  "$FT_IMPORTANCE_CRUCIAL"   "Down"
    # Backward before forward, so the legend reads ◀ Collapse then ▶ Expand — the same order
    # as the keys themselves on the keyboard.
    ft-keymap-cap ft_keymap_tree_browsing LEFT  ft_tree_key_left  "$FT_IMPORTANCE_IMPORTANT" "Collapse"
    ft-keymap-cap ft_keymap_tree_browsing RIGHT ft_tree_key_right "$FT_IMPORTANCE_IMPORTANT" "Expand"
    ft-keymap-cap ft_keymap_tree_browsing ENTER ft_tree_key_enter "$FT_IMPORTANCE_IMPORTANT" "Open"
    ft-keymap-cap ft_keymap_tree_browsing ESC   ft_key_undelve    "$FT_IMPORTANCE_IMPORTANT" "Leave"
    # COPY IS Ctrl+C, with Alt+W beside it — the pair the text field already uses, and the
    # only two spellings of copy this framework has. Ctrl+C is taken from the tty on purpose
    # (ft_enter_tty's `intr undef`, behind FT_CTRL_C_COPY) and Settings offers it by name, so
    # it is THE copy key; Alt+W is readline's copy-region-as-kill and is the one that works
    # on a terminal that never negotiated a keyboard protocol, where the tty still raises
    # SIGINT before Ctrl+C can arrive as a key. Bind both or the key works on some terminals
    # and not others.
    ft-bindkeys ft_keymap_tree CTRL+c=ft_tree_copy ALT+w=ft_tree_copy
    ft-keymap-cap ft_keymap_tree CTRL+c ft_tree_copy "$FT_IMPORTANCE_NORMAL" "Copy tree"
}
# Copy THE WHOLE TREE, drawn the way it is on screen — indentation and the same ▾/▸ glyphs,
# so what you paste looks like what you were looking at.
#
# Not the node under the cursor: a tree has no edit mode to distinguish "the item I have
# chosen" from "the thing I happen to be scrolled to", so the cursor is a position, not a
# selection. Landing on a control and pressing copy should hand you what is in it.
#
# ALL of it, not just the rows in view — the scroll window is where you happen to be looking,
# not what the tree contains. Collapsed branches keep their ▸ and their children stay hidden,
# because that IS the tree as it stands; expanding is how you ask for them.
ft_tree_copy() {                # name
    local n=$1
    _ft_tree_gather "$n"; _ft_tree_visible "$n"
    local expg=$'\xe2\x96\xbe' colg=$'\xe2\x96\xb8'      # ▾ expanded  ▸ collapsed
    (( FT_USE_UTF8 )) || { expg='v'; colg='>'; }         # …plain ASCII where UTF-8 is not on
    local out="" idx depth glyph indent
    for idx in "${FT_TREE_NODE_VISIBLE[@]}"; do
        depth=${FT_TREE_NODE_DEPTH[$idx]}
        if   (( FT_TREE_NODE_IS_BRANCH[idx] && FT_TREE_NODE_EXPANDED[idx] )); then glyph=$expg
        elif (( FT_TREE_NODE_IS_BRANCH[idx] )); then                               glyph=$colg
        else glyph=' '; fi
        printf -v indent '%*s' $(( depth * 2 )) ''
        out+="$indent$glyph ${FT_TREE_NODE_TEXT[$idx]}"$'\n'
    done
    out=${out%$'\n'}
    (( ${#out} == 0 )) && { ft_emit_status copyNothing; return 0; }
    ft_clip_copy "$out"; _ft_announce_copy $? itemCopied
    return 0
}
ft_class_tree() {
    # ONE RUNG IN. `browsing` is where the cursor lives and where the arrows are the tree's;
    # `unfocused` is standing next to it. Declaring the ladder also registers the CSS states
    # `tree:unfocused` / `tree:browsing`, so a theme can style the cursor row differently at
    # each — which is how the highlight is shown faded until you have actually stepped in.
    ft_runlevels browsing=ft_keymap_tree_browsing
    ft_class extends=ft_control \
        focusable=true \
        mouse=tree \
        keymap=tree \
        defaults="display=inline-block rows=10 cursor=0 scroll=0 value="
    ft_prop_kind_set cursor   paint
    ft_prop_kind_set scroll   paint
    ft_prop_kind_set expanded paint
    ft_prop_kind_set depth    layout
}
# Nodes are display=none data holders (never laid out or drawn on their own —
# the tree draws them), exactly like ft-table's rows.
ft_class_treenode() {
    ft_class extends=ft_control defaults="display=none depth=0 expanded=false key="
    # Register key/depth/expanded so the arg parser accepts them as PROPERTIES
    # even when the value contains a space — a file named "my report.txt" makes
    # key="f:my report.txt", and without this the parser would mistake the whole
    # `key=…` token for the node's text (you'd see "key=f:my report.txt" on screen).
    ft_prop_kind_set key      paint
    ft_prop_kind_set depth    layout
    ft_prop_kind_set expanded paint
}

ft-tree()     { ft_new tree "$@" && FT_NEST_STACK+=("$FT_RET"); }
end_ft_tree() { ft-end tree; }

_FT_TREE_SEQ=0
ft-tree-node() {                # [name=..] "label" [key=..] [depth=N] [expanded=true]
    # An explicit name= WINS, the way it does for ft-table-header and ft-table-row. This
    # used to prepend a generated name unconditionally, so `ft-tree-node name=mine …` was
    # accepted, ignored, and the node kept its generated name — leaving the caller holding
    # an identifier that addresses nothing, and `ft-modify mine expanded=false` a silent
    # no-op. A node with no name of its own still gets one; that part was always fine.
    local a
    for a in "$@"; do [[ "$a" == name=* ]] && { ft_new treenode "$@"; return; }; done
    local o=""; (( ${#FT_NEST_STACK[@]} > 0 )) && o="${FT_NEST_STACK[$(( ${#FT_NEST_STACK[@]} - 1 ))]}"
    ft_new treenode name="${o}_tn$(( ++_FT_TREE_SEQ ))" "$@"
}

# ── Model: flat node arrays + the visible-row projection ─────────────────────
_ft_tree_gather() {             # name → FT_TN_* arrays + FT_TREE_NODE_COUNT
    local name=$1 k
    FT_TREE_NODE_NAME=(); FT_TREE_NODE_TEXT=(); FT_TREE_NODE_KEY=(); FT_TREE_NODE_DEPTH=(); FT_TREE_NODE_EXPANDED=(); FT_TREE_NODE_IS_BRANCH=()
    for k in ${FT_KIDS[$name]:-}; do
        [[ "${FT_TYPE[$k]:-}" == treenode ]] || continue
        FT_TREE_NODE_NAME+=("$k")
        _ft_get_raw "$k" text;     FT_TREE_NODE_TEXT+=("$FT_RET")
        _ft_get_raw "$k" key;      FT_TREE_NODE_KEY+=("$FT_RET")
        _ft_get_raw "$k" depth;    FT_TREE_NODE_DEPTH+=("${FT_RET:-0}")
        _ft_get_raw "$k" expanded; [[ "$FT_RET" == true ]] && FT_TREE_NODE_EXPANDED+=(1) || FT_TREE_NODE_EXPANDED+=(0)
    done
    FT_TREE_NODE_COUNT=${#FT_TREE_NODE_NAME[@]}
    local i
    for (( i=0; i<FT_TREE_NODE_COUNT; i++ )); do           # branch = the NEXT node is deeper
        if (( i+1 < FT_TREE_NODE_COUNT )) && (( FT_TREE_NODE_DEPTH[i+1] > FT_TREE_NODE_DEPTH[i] )); then FT_TREE_NODE_IS_BRANCH+=(1); else FT_TREE_NODE_IS_BRANCH+=(0); fi
    done
}
# Visible node indices: a collapsed branch hides every following deeper node
# until the depth returns to its level.
_ft_tree_visible() {            # (after gather) → FT_TREE_NODE_VISIBLE[]
    FT_TREE_NODE_VISIBLE=(); local i hide=-1
    for (( i=0; i<FT_TREE_NODE_COUNT; i++ )); do
        (( hide >= 0 && FT_TREE_NODE_DEPTH[i] > hide )) && continue
        hide=-1
        FT_TREE_NODE_VISIBLE+=("$i")
        (( FT_TREE_NODE_IS_BRANCH[i] && ! FT_TREE_NODE_EXPANDED[i] )) && hide=${FT_TREE_NODE_DEPTH[i]}
    done
}
# Position of node index `idx` in FT_TREE_NODE_VISIBLE, snapping DOWN to the nearest visible
# ancestor if idx is currently hidden. → FT_RET (or -1 if the tree is empty).
_ft_tree_vispos() {             # idx → FT_RET
    local idx=$1 p=-1 i
    for (( i=0; i<${#FT_TREE_NODE_VISIBLE[@]}; i++ )); do
        (( FT_TREE_NODE_VISIBLE[i] <= idx )) && p=$i || break
    done
    FT_RET=$p
}

# ── Cursor + scroll ──────────────────────────────────────────────────────────
# Place the cursor on VISIBLE node `idx`, keep it on screen, refresh value, fire
# on_change, repaint.
_ft_tree_set_cursor() {         # name nodeidx
    local name=$1 idx=$2
    ft_resolved_prop "$name" rows 10; local rows=$FT_RET; (( rows < 1 )) && rows=1
    _ft_tree_gather "$name"; _ft_tree_visible "$name"
    local vn=${#FT_TREE_NODE_VISIBLE[@]}; (( vn == 0 )) && return 0
    _ft_tree_vispos "$idx"; local vp=$FT_RET; (( vp < 0 )) && vp=0
    idx=${FT_TREE_NODE_VISIBLE[$vp]}
    local sc; ft_resolved_prop "$name" scroll 0; sc=$FT_RET
    (( vp < sc )) && sc=$vp
    (( vp >= sc + rows )) && sc=$(( vp - rows + 1 ))
    (( sc > vn - rows )) && sc=$(( vn - rows )); (( sc < 0 )) && sc=0
    local newval=${FT_TREE_NODE_KEY[$idx]}
    ft-modify "$name" cursor="$idx" scroll="$sc" value="$newval"
    _ft_hook "$name" on_change "$newval"
    ft_dirty "$name"; return 0
}
_ft_tree_cursor_idx() {         # name → FT_RET (clamped to a visible node)
    local name=$1; ft_resolved_prop "$name" cursor 0; local cur=$FT_RET
    # Ensure the visible-node list exists. On a FRESHLY BUILT tree the cursor has
    # never moved, so nothing has populated FT_TREE_NODE_VISIBLE yet — without this, vispos
    # returns -1 and Enter/Left/Right silently do nothing until you first arrow.
    _ft_tree_visible "$name"
    _ft_tree_vispos "$cur"; local vp=$FT_RET
    (( vp < 0 )) && { FT_RET=-1; return 1; }
    FT_RET=${FT_TREE_NODE_VISIBLE[$vp]}; return 0
}
_ft_tree_move() {               # name delta
    local name=$1 delta=$2
    _ft_tree_gather "$name"; _ft_tree_visible "$name"
    local vn=${#FT_TREE_NODE_VISIBLE[@]}; (( vn == 0 )) && return 0
    ft_resolved_prop "$name" cursor 0; _ft_tree_vispos "$FT_RET"; local vp=$FT_RET; (( vp < 0 )) && vp=0
    vp=$(( vp + delta )); (( vp < 0 )) && vp=0; (( vp > vn - 1 )) && vp=$(( vn - 1 ))
    _ft_tree_set_cursor "$name" "${FT_TREE_NODE_VISIBLE[$vp]}"
}

ft_tree_key_up()   { _ft_tree_move "$1" -1; }
ft_tree_key_down() { _ft_tree_move "$1" 1; }
ft_tree_key_pgup() { local n=$1; ft_resolved_prop "$n" rows 10; _ft_tree_move "$n" $(( -(FT_RET>1?FT_RET-1:1) )); }
ft_tree_key_pgdn() { local n=$1; ft_resolved_prop "$n" rows 10; _ft_tree_move "$n" $(( FT_RET>1?FT_RET-1:1 )); }
ft_tree_key_home() { local n=$1; _ft_tree_gather "$n"; _ft_tree_visible "$n"; (( ${#FT_TREE_NODE_VISIBLE[@]} )) && _ft_tree_set_cursor "$n" "${FT_TREE_NODE_VISIBLE[0]}"; return 0; }
ft_tree_key_end()  { local n=$1; _ft_tree_gather "$n"; _ft_tree_visible "$n"; local m=${#FT_TREE_NODE_VISIBLE[@]}; (( m )) && _ft_tree_set_cursor "$n" "${FT_TREE_NODE_VISIBLE[m-1]}"; return 0; }

# Set a node's expanded flag by NODE index, then re-place the cursor (which also
# re-clamps scroll and value).
_ft_tree_set_exp() {            # name nodeidx 0|1
    local name=$1 idx=$2 val=$3
    _ft_tree_gather "$name"
    (( idx < 0 || idx >= FT_TREE_NODE_COUNT )) && return 1
    (( FT_TREE_NODE_IS_BRANCH[idx] )) || return 1
    [[ "$val" == 1 ]] && _ft_setprop "${FT_TREE_NODE_NAME[$idx]}" expanded true || _ft_setprop "${FT_TREE_NODE_NAME[$idx]}" expanded false
    return 0
}
ft_tree_key_right() {           # expand a collapsed branch, or step into it
    local n=$1; _ft_tree_gather "$n"; _ft_tree_cursor_idx "$n" || return 0; local i=$FT_RET
    if (( FT_TREE_NODE_IS_BRANCH[i] && ! FT_TREE_NODE_EXPANDED[i] )); then _ft_tree_set_exp "$n" "$i" 1; _ft_tree_set_cursor "$n" "$i"
    elif (( FT_TREE_NODE_IS_BRANCH[i] )); then _ft_tree_set_cursor "$n" $(( i + 1 )); fi   # into first child
    return 0
}
ft_tree_key_left() {            # collapse an expanded branch, or step to parent
    local n=$1; _ft_tree_gather "$n"; _ft_tree_cursor_idx "$n" || return 0; local i=$FT_RET
    if (( FT_TREE_NODE_IS_BRANCH[i] && FT_TREE_NODE_EXPANDED[i] )); then _ft_tree_set_exp "$n" "$i" 0; _ft_tree_set_cursor "$n" "$i"; return 0; fi
    local d=${FT_TREE_NODE_DEPTH[$i]} j                # find the nearest shallower ancestor
    for (( j=i-1; j>=0; j-- )); do (( FT_TREE_NODE_DEPTH[j] < d )) && { _ft_tree_set_cursor "$n" "$j"; break; }; done
    return 0
}
_ft_mouse_tree() {              # name action relx rely — click selects a row / toggles a glyph
    local n=$1 act=$2 rx=$3 ry=$4
    [[ "$act" == press ]] || return 0
    _ft_tree_gather "$n"; _ft_tree_visible "$n"
    local vn=${#FT_TREE_NODE_VISIBLE[@]}; (( vn == 0 )) && return 0
    ft_resolved_prop "$n" scroll 0; local sc=$FT_RET
    local vrow=$(( sc + ry ))
    (( vrow < 0 || vrow >= vn )) && return 0
    local idx=${FT_TREE_NODE_VISIBLE[$vrow]} depth=${FT_TREE_NODE_DEPTH[$idx]}
    if (( FT_TREE_NODE_IS_BRANCH[idx] )) && (( rx == depth*2 )); then   # clicked the ▸/▾ glyph → toggle
        (( FT_TREE_NODE_EXPANDED[idx] )) && _ft_tree_set_exp "$n" "$idx" 0 || _ft_tree_set_exp "$n" "$idx" 1
    fi
    _ft_tree_set_cursor "$n" "$idx"
    return 0
}
ft_tree_key_enter() {           # toggle a branch; activate a leaf
    local n=$1; _ft_tree_gather "$n"; _ft_tree_cursor_idx "$n" || return 0; local i=$FT_RET
    if (( FT_TREE_NODE_IS_BRANCH[i] )); then
        (( FT_TREE_NODE_EXPANDED[i] )) && _ft_tree_set_exp "$n" "$i" 0 || _ft_tree_set_exp "$n" "$i" 1
        _ft_tree_set_cursor "$n" "$i"
    else
        # Fire with the CURSOR NODE's key directly — the `value` prop is only
        # refreshed when the cursor MOVES, so on a freshly-built tree (cursor never
        # moved) it is still empty and Enter would activate nothing.
        _ft_hook "$n" on_activate "${FT_TREE_NODE_KEY[$i]}"
    fi
    return 0
}

# ── Metrics + draw ───────────────────────────────────────────────────────────
_ft_tree_maxw() {               # name → FT_RET widest node line (indent+glyph+label)
    _ft_tree_gather "$1"
    local i w=0 lw
    for (( i=0; i<FT_TREE_NODE_COUNT; i++ )); do
        ft_display_width "${FT_TREE_NODE_TEXT[$i]}"
        lw=$(( FT_TREE_NODE_DEPTH[i]*2 + 2 + FT_DISPLAY_WIDTH ))   # depth indent + glyph + space + text
        (( lw > w )) && w=$lw
    done
    FT_RET=$w
}
_ft_preferred_width_tree() {              # name → FT_RET (content columns incl. 1-col gutter)
    _ft_tree_maxw "$1"; local w=$FT_RET; (( w < 4 )) && w=4
    FT_RET=$(( w + 1 ))
}
_ft_height_tree() { ft_resolved_prop "$1" rows 10; (( FT_RET < 1 )) && FT_RET=1; }

_ft_draw_tree() {               # name
    local name=$1
    local row=${FT_ABSOLUTE_Y[$name]:-0} col=${FT_ABSOLUTE_X[$name]:-0}
    local cols=${FT_MEASURED_WIDTH[$name]:-0} rows=${FT_MEASURED_HEIGHT[$name]:-0}
    (( cols < 1 || rows < 1 )) && return
    _ft_tree_gather "$name"; _ft_tree_visible "$name"
    local vn=${#FT_TREE_NODE_VISIBLE[@]}
    local focused=0; [[ "${FT_FOCUS:-}" == "$name" ]] && focused=1
    local well; _ft_compose_sgr "$name" "$FT_COLOR_INPUT"; well=$FT_RET   # base rows: cascaded bg/fg

    local overflow=0; (( vn > rows )) && overflow=1
    local textw=$cols; (( overflow )) && textw=$(( cols - 1 ))
    local gcol=$(( col + cols - 1 ))

    ft_resolved_prop "$name" cursor 0; local cur=$FT_RET
    ft_resolved_prop "$name" scroll 0; local sc=$FT_RET
    (( sc > vn - rows )) && sc=$(( vn - rows )); (( sc < 0 )) && sc=0

    local expg=$'\xe2\x96\xbe' colg=$'\xe2\x96\xb8'      # ▾ expanded  ▸ collapsed
    (( FT_USE_UTF8 )) || { expg='v'; colg='>'; }

    local r vi idx depth glyph indent line sgr
    for (( r=0; r<rows; r++ )); do
        local vrow=$(( sc + r ))
        if (( vrow < vn )); then
            idx=${FT_TREE_NODE_VISIBLE[$vrow]}
            depth=${FT_TREE_NODE_DEPTH[$idx]}
            if   (( FT_TREE_NODE_IS_BRANCH[idx] && FT_TREE_NODE_EXPANDED[idx] )); then glyph=$expg
            elif (( FT_TREE_NODE_IS_BRANCH[idx] )); then                  glyph=$colg
            else glyph=' '; fi
            printf -v indent '%*s' $(( depth*2 )) ''
            line="$indent$glyph ${FT_TREE_NODE_TEXT[$idx]}"
            sgr=$well
            # the row the keyboard is on is a STATE pseudo-element: `tree::active { … }`.
            # `::active` means the same thing on every control that has a current item —
            # tabs, tree, table — so one rule spelling covers them all. (It was `::cursor`,
            # one colon away from the `cursor` CSS property and a near-synonym of ::caret.)
            # …and FADED until you have stepped in with Enter (see _ft_runlevel_active_sgr):
            # while you are only standing next to the tree the cursor is not yours to drive,
            # and Ctrl+C takes the whole tree rather than that row.
            (( focused && idx == cur )) && { _ft_runlevel_active_sgr "$name" "$FT_COLOR_FOCUS"; _ft_dim_if_disabled "$name" "$FT_RET"; sgr=$FT_RET; }
            ft_fit "$line" "$textw"
        else
            sgr=$well; ft_fit "" "$textw"
        fi
        ft_print_at $(( row + r )) "$col" "$sgr$FT_FIT$FT_COLOR_RESET"
        (( overflow )) && ft_print_at $(( row + r )) "$gcol" "$well $FT_COLOR_RESET"
    done

    # Proportional scrollbar in the reserved gutter.
    if (( overflow )); then
        local track=$rows thumb=$(( rows*rows/vn )); (( thumb < 1 )) && thumb=1
        local maxstart=$(( track - thumb )); (( maxstart < 0 )) && maxstart=0
        local maxsc=$(( vn - rows )); local tstart=0
        (( maxsc > 0 )) && tstart=$(( maxstart * sc / maxsc ))
        local tsgr; (( focused )) && tsgr=$FT_COLOR_FOCUS || tsgr=$FT_COLOR_THUMB
        _ft_css_pe_or "$name" scrollbar "$tsgr"; tsgr=$FT_RET      # `tree::scrollbar { … }`
        local tracksgr; _ft_css_pe_or "$name" track "$FT_COLOR_DIVIDER"; tracksgr=$FT_RET   # `tree::track`
        for (( r=0; r<track; r++ )); do
            if (( r >= tstart && r < tstart + thumb )); then ft_print_at $(( row + r )) "$gcol" "$tsgr $FT_COLOR_RESET"
            else ft_print_at $(( row + r )) "$gcol" "$tracksgr$FT_GLYPH_VERTICAL$FT_COLOR_RESET"; fi
        done
    fi
}
