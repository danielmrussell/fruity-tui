#!/usr/bin/env bash
# Unit tests for controls/ft-tree.bash — the collapsible tree: flat depth model,
# visible-row projection, cursor navigation over visible nodes, expand/collapse,
# left-to-parent / right-into-child, Enter (toggle branch / activate leaf), and
# that a render emits the labels, indent and expand glyphs.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=80; FT_ROWS=40
_plain() { printf '%s' "$1" | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g'; }

ft-form name=app width=80 height=40
ft-tree name=t rows=6 onActivate=t_on_activate
    ft-tree-node "src"            key=src  depth=0 expanded=true
    ft-tree-node "ft-core.bash"   key=core depth=1
    ft-tree-node "controls"       key=ctl  depth=1 expanded=false
    ft-tree-node "ft-tree.bash"   key=tree depth=2
    ft-tree-node "ft-select.bash" key=sel  depth=2
    ft-tree-node "README.md"      key=rd   depth=0
end_ft_tree
end_ft_form
ft_layout app; FT_ROOT=app; FT_FOCUS=t

note "model: flat nodes, depth, branch = next node is deeper"
_ft_tree_gather t
check "6 nodes gathered"          "$FT_TREE_NODE_COUNT"            "6"
check "keys in order"             "${FT_TREE_NODE_KEY[*]}"     "src core ctl tree sel rd"
check "src is a branch"           "${FT_TREE_NODE_IS_BRANCH[0]}"  "1"
check "core (leaf) is not"        "${FT_TREE_NODE_IS_BRANCH[1]}"  "0"
check "controls is a branch"      "${FT_TREE_NODE_IS_BRANCH[2]}"  "1"
check "README (leaf) is not"      "${FT_TREE_NODE_IS_BRANCH[5]}"  "0"

note "visible projection: a collapsed branch hides its deeper descendants"
_ft_tree_visible t
check "controls collapsed → tree/sel hidden" "${FT_TREE_NODE_VISIBLE[*]}" "0 1 2 5"

note "cursor nav moves over VISIBLE nodes only, clamped; value tracks the key"
_ft_tree_set_cursor t 0
ft_get t value; check "cursor 0 → value=src" "$FT_RET" "src"
ft_tree_key_down t; ft_resolved_prop t cursor 0; check "down → node 1 (core)" "$FT_RET" "1"
ft_tree_key_down t; ft_resolved_prop t cursor 0; check "down → node 2 (controls)" "$FT_RET" "2"
ft_tree_key_down t; ft_resolved_prop t cursor 0; check "down skips hidden → node 5 (README)" "$FT_RET" "5"
ft_tree_key_down t; ft_resolved_prop t cursor 0; check "down at bottom clamps (stays 5)" "$FT_RET" "5"
ft_get t value; check "value = rd at bottom" "$FT_RET" "rd"
ft_tree_key_home t; ft_resolved_prop t cursor 0; check "Home → first (0)" "$FT_RET" "0"

note "right expands a collapsed branch / steps into it; left collapses / to parent"
_ft_tree_set_cursor t 2                       # on 'controls' (collapsed)
ft_tree_key_right t                           # expand it
_ft_tree_gather t; check "controls expanded" "${FT_TREE_NODE_EXPANDED[2]}" "1"
_ft_tree_visible t; check "now tree/sel visible" "${FT_TREE_NODE_VISIBLE[*]}" "0 1 2 3 4 5"
ft_tree_key_right t; ft_resolved_prop t cursor 0; check "right again → into first child (tree, node 3)" "$FT_RET" "3"
ft_tree_key_left t;  ft_resolved_prop t cursor 0; check "left on a leaf → to parent (controls, node 2)" "$FT_RET" "2"
ft_tree_key_left t                            # collapse controls
_ft_tree_gather t; check "controls collapsed again" "${FT_TREE_NODE_EXPANDED[2]}" "0"

note "Enter toggles a branch; activates a leaf (fires on_activate with the key)"
ACT=""
t_on_activate() { ACT="$1"; }
_ft_tree_set_cursor t 0                        # 'src' branch, expanded
ft_tree_key_enter t; _ft_tree_gather t; check "Enter collapsed src" "${FT_TREE_NODE_EXPANDED[0]}" "0"
ft_tree_key_enter t; _ft_tree_gather t; check "Enter re-expanded src" "${FT_TREE_NODE_EXPANDED[0]}" "1"
_ft_tree_set_cursor t 1                        # 'core' leaf
ft_tree_key_enter t; check "Enter on a leaf fired on_activate(core)" "$ACT" "core"

note "Enter works on a FRESHLY built tree — no arrow-move needed first (regression)"
ft-form name=fr width=40 height=10
  ft-tree name=tfresh rows=6 onActivate=tfresh_on_activate
    ft-tree-node "one" key=k1 depth=0
    ft-tree-node "two" key=k2 depth=0
  end_ft_tree
end_ft_form
ft_layout fr
ACT=""; tfresh_on_activate() { ACT="$1"; }
ft_tree_key_enter tfresh                        # cursor still at its default 0, never moved
check "fresh-tree Enter fired on_activate(k1)" "$ACT" "k1"

note "metrics: width = deepest indent + glyph + widest label (+gutter); height = rows"
_ft_preferred_width_tree t
# widest line: 'ft-select.bash' at depth 2 → 4 indent + 2 (glyph+space) + 14 = 20, +1 gutter
check "prefw = 21" "$FT_RET" "21"
_ft_height_tree t; check "height = rows (6)" "$FT_RET" "6"

note "render: labels, indentation and expand glyphs present"
ft_layout app; FT_OUT=""; _ft_redraw_walk app
pl=$(_plain "$FT_OUT")
for want in "src" "ft-core.bash" "controls" "README.md"; do
    case "$pl" in *"$want"*) check "render contains '$want'" 1 1 ;; *) check "render contains '$want'" 0 1 ;; esac
done
case "$pl" in *"▾"*) check "expanded branch shows ▾" 1 1 ;; *) check "expanded branch shows ▾" 0 1 ;; esac
case "$pl" in *"▸"*) check "collapsed branch shows ▸" 1 1 ;; *) check "collapsed branch shows ▸" 0 1 ;; esac

note "scrolling: more visible nodes than rows → scrollbar gutter + windowing"
ft-empty app
ft-tree name=t2 rows=3
    for _i in 1 2 3 4 5 6 7 8; do ft-tree-node "item $_i" key="k$_i" depth=0; done
end_ft_tree
end_ft_form
ft_layout app; FT_FOCUS=t2
_ft_tree_gather t2; _ft_tree_visible t2; check "8 visible nodes" "${#FT_TREE_NODE_VISIBLE[@]}" "8"
ft_tree_key_end t2; ft_resolved_prop t2 scroll 0; check "End scrolls to show last (scroll=5)" "$FT_RET" "5"
FT_OUT=""; _ft_redraw_walk app; pl=$(_plain "$FT_OUT")
case "$pl" in *"item 8"*) check "scrolled view shows item 8" 1 1 ;; *) check "scrolled view shows item 8" 0 1 ;; esac
case "$pl" in *"item 1"[^0-9]*) check "item 1 scrolled out" 0 1 ;; *) check "item 1 scrolled out" 1 1 ;; esac

note "ft_remove tears the tree down cleanly"
ft-empty app
_ft_tree_gather t   # t destroyed; expect zero nodes
check "destroyed tree has no nodes" "$FT_TREE_NODE_COUNT" "0"

summary
