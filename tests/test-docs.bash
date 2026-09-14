#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tests/test-docs.bash — a source file's own header must describe the code under it.
#
#  controls/ft-table.bash opened with a worked example written in `ft-column` and `ft-row`.
#  Neither has ever existed; the functions are ft-table-header and ft-table-row. Anyone
#  following the file's own documentation got "command not found". The same header
#  documented `style=grid` while the code reads `variant` — and `style` is the
#  framework-wide inline-CSS property, so that example would have been parsed as a CSS
#  declaration and quietly done nothing.
#
#  Documentation drifts silently because nothing executes it. These two checks do:
#
#    1. Every `ft-…` name in a file's leading comment block is a defined function.
#    2. Every `name=` attribute shown in one of those examples is a property the code
#       actually reads somewhere.
#
#  Both are deliberately narrow — the leading block only, and only names shaped like the
#  DSL — because a check that cries wolf gets deleted. What they catch is exactly the
#  mistake found: an example nobody could run.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null

# Instantiating one of each control runs every class constructor, so anything bound by
# convention rather than defined outright exists by the time the checks run.
ft-form name=docf width=40 height=20
    ft-label name=dl "x";  ft-button name=db "x";  ft-checkbox name=dc "x"
    ft-radio name=dr "x" group=g; ft-heading name=dh "x"; ft-boxheader name=dbh text=x
    ft-slider name=ds min=0 max=5 value=1
    ft-textfield name=dt size=6
    ft-select name=dsel size=1; ft-option value=a A; end_ft_select
    ft-multitoggle name=dm text=x; ft-option value=a glyph=A; end_ft_multitoggle
    ft-tree name=dtr rows=2; ft-tree-node "n" key=k depth=0; end_ft_tree
    ft-table name=dtb; ft-table-header "H"; ft-table-row "c"; end_ft_table
end_ft_form

# The leading comment block: everything from line 2 up to the first line that is not a
# comment. (A byte-oriented `sed` range on the ─ rule does not work — it is multibyte.)
_header_of() { awk 'NR==1{next} /^#/{print;next} {exit}' "$1"; }

note "every ft-… name a file's own header uses is a function you can call"
shopt -s nullglob
files=("$here"/ft-*.bash "$here"/controls/*.bash)
checked=0
for f in "${files[@]}"; do
    base=${f#"$here"/}
    bad=""
    while IFS= read -r tok; do
        [[ -z "$tok" ]] && continue
        # A file NAME rather than a call — ft-core.bash, ft-forms.bash. Those are the
        # dependency lines every header ends with, and they are not DSL.
        [[ -e "$here/$tok.bash" || -e "$here/controls/$tok.bash" ]] && continue
        declare -F "$tok" >/dev/null 2>&1 && continue
        [[ " $bad " == *" $tok "* ]] && continue
        bad+="$tok "
    done < <(_header_of "$f" | grep -oE 'ft-[a-z][a-z0-9-]*' | sort -u)
    (( checked++ ))
    [[ -n "$bad" ]] && check "$base documents only real functions" "$bad" ""
done
check "…across every source file (checked $checked)" "$(( checked > 20 ))" "1"
# All clean is the pass; the loop above only emits an assertion for a file that fails, so
# prove the extraction is not silently finding nothing.
n=$(_header_of "$here/controls/ft-table.bash" | grep -coE 'ft-[a-z][a-z0-9-]*')
check "the table header really does name the DSL" "$(( n >= 4 ))" "1"

note "the table's header names the property the code reads"
# `style` is the inline-CSS property on every control; the table's look is `variant`.
hdr=$(_header_of "$here/controls/ft-table.bash")
check "the header documents variant=" \
      "$(case "$hdr" in *"variant="*) echo yes ;; *) echo no ;; esac)" "yes"
check "…and no longer offers style= as the table's look" \
      "$(case "$hdr" in *"style=  is"*|*"style= is"*) echo "still there" ;; *) echo gone ;; esac)" "gone"
_ft_table_style dtb
check "the code reads variant (not style) for the look" \
      "$(ft_resolved_prop dtb variant ''; echo "${FT_RET:-unset}")" "unset"
ft-modify dtb variant=minimal; _ft_table_style dtb
check "variant=minimal takes effect"  "$TBL_BOX/$TBL_VERT" "0/0"
ft-modify dtb variant=grid;    _ft_table_style dtb
check "variant=grid takes effect"     "$TBL_BOX/$TBL_VERT" "1/1"

note "the worked example in the table's header actually runs"
# The check that would have caught it outright: execute the documented declaration.
ft_remove exf 2>/dev/null
# stderr to a FILE, not `$( )`: a command substitution is a SUBSHELL, so the table would be
# built in a child and every assertion below would read an empty parent. That mistake has
# been made repeatedly in this codebase's tests — it always looks like the feature is broken.
errf="$XDG_STATE_HOME/doc-example.err"; mkdir -p "$XDG_STATE_HOME"
{
    ft-form name=exf width=60 height=10
        ft-table name=keys variant=grid striped=true
            ft-table-header "Key"    width=16
            ft-table-header "Action" align=left
            ft-table-row "Ctrl+A / Home"  "Move to start of line"
            ft-table-row "Ctrl+E / End"   "Move to end of line"
            ft-table-row "Ctrl+W"         "Delete the word before the cursor"
        end_ft_table
    end_ft_form
    ft_layout exf
} 2>"$errf" >/dev/null
check "it declares without complaint"     "$(<"$errf")" ""
check "…and the table really was built"   "${FT_TYPE[keys]:-none}" "table"
_ft_table_cols keys; check "…with the two columns it declares" "${#FT_TABLE_COLUMNS[@]}" "2"
_ft_table_rows keys; check "…and its three rows"               "$FT_TABLE_ROW_COUNT" "3"
FT_ROOT=exf; FT_OUT=""; ft_draw_one keys
check "…and paints something"             "$(( ${#FT_OUT} > 0 ))" "1"

note "every pseudo-class the docs advertise is one the cascade actually registers"
# THE THIRD SILENT DRIFT, and the nastiest, because the engine's answer to a name it does not
# know is "never matches" with no diagnostic at all: docs/styling-model.md's selector table
# offered `:edit` where the implemented state is `:editing`, so a rule written from the
# reference resolved to nothing and neither ft_stylesheet nor the cascade said a word. The
# preamble of that file asserts everything in it is implemented, and README.md points readers
# there. Same shape as the ft-column/ft-row example above — documentation nothing executes.
#
# The checks above are deliberately narrow (a source file's own header, DSL-shaped names), and
# they could NOT have caught this: they never open docs/*.md, and `:edit` is not an `ft-…`
# token. So this is the narrow check for the other half — a backticked `:pseudo` in the docs
# must be a name _ft_css_state can resolve, which means an entry in FT_STATE_TEST under its own
# name or under any TYPE-scoped key (`textfield:editing`).
_state_registered() {           # pseudo → 0 if the cascade knows it
    [[ -n "${FT_STATE_TEST[$1]:-}" ]] && return 0
    local key
    for key in "${!FT_STATE_TEST[@]}"; do [[ "$key" == *":$1" ]] && return 0; done
    return 1
}
_doc_pseudos=$(grep -rhoE '`:[a-z][a-z-]*`' "$here"/docs/*.md "$here"/README.md \
               | tr -d '`' | sort -u)
_unknown=""; _doc_pseudo_count=0
for _p in $_doc_pseudos; do
    (( _doc_pseudo_count++ ))
    _state_registered "${_p#:}" || _unknown+="$_p "
done
check "no doc names a pseudo-class the engine never matches" "${_unknown% }" ""
# …and the extraction is finding something: a scan that matched nothing would pass too.
check "the scan found the docs' pseudo-classes (checked $_doc_pseudo_count)" \
      "$(( _doc_pseudo_count >= 8 ? 1 : 0 ))" 1
# Teeth: the predicate must say no to a name nobody registered.
check "…and the registry lookup rejects an invented one" \
      "$(_state_registered nosuchstate && echo yes || echo no)" "no"

summary
