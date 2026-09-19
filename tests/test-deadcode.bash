#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  NOTHING IN controls/ IS DEFINED AND NEVER REACHED, OR WRITTEN AND NEVER READ.
#
#  Dead code in this tree is not litter, it is a LIE: a helper nobody calls still teaches a
#  maintainer the model it belonged to, and the table's superseded scroll-by helper went on
#  describing the panning model the cursor model replaced — every live key and wheel route
#  reaches the cursor helper, and reached that one zero times.
#
#  So this gate asks the general question instead of naming the departed: every _ft_… helper
#  defined in controls/ is either mentioned somewhere other than its own definition, or has
#  one of the shapes the engine BUILDS by convention.
#
#  ONE RULE THIS GATE LEARNED ABOUT ITSELF, the hard way: PROSE IS NOT A REFERENCE. The first
#  version named the dead helper in this very header, and that mention alone made the scan
#  call it reachable. Full-line comments are stripped before anything is counted, so neither
#  this gate nor a stale comment anywhere else can keep a corpse alive by talking about it.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
cd "$here" || exit 1

# Every .bash line in the tree with full-line comments removed — the corpus both scans read.
_CORPUS=$(mktemp "${TMPDIR:-/tmp}/ft-deadcode.XXXXXX")
grep -rn '' --include='*.bash' . 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#' > "$_CORPUS"

# The name shapes the framework CONSTRUCTS and calls without ever spelling them out. Each row
# names the line that builds it, so this allowlist cannot quietly grow:
#   _ft_draw_ / _ft_preferred_width_ / _ft_height_   ft-forms.bash _ft_prototype_bind_by_convention
#   _ft_mouse_                                        ft-forms.bash _FT_PROTO_SHORT_VALUE_PREFIX
#   _ft_define_keymap_                                ft-forms.bash _ft_prototype_resolve_value
#   _ft_destroy_ _ft_ink_ _ft_blur_ _ft_focusin_ _ft_tiers_ _ft_caps_   "_ft_<role>_${FT_TYPE[…]}"
#   _ft_banim_                                        the border-animation style hook
CONSTRUCTED='^_ft_(draw|preferred_width|height|mouse|define_keymap|destroy|ink|blur|focusin|tiers|caps|banim)_'

note "every private helper in controls/ is reachable"
unreached=""
for f in controls/*.bash; do
    while read -r fn; do
        [[ -z "$fn" ]] && continue
        [[ "$fn" =~ $CONSTRUCTED ]] && continue          # the engine builds this name
        uses=$(grep -E "\b${fn}\b" "$_CORPUS" | grep -vcE ":[0-9]+:[[:space:]]*${fn}\(\)")
        (( uses == 0 )) && unreached+="$fn "
    done < <(grep -oE '^_ft_[a-z0-9_]+\(\)' "$f" | sed 's/()//')
done
check "no helper is defined and never reached" "${unreached% }" ""

# A flag nobody reads is worse than a helper nobody calls, because it looks like STATE: the
# textfield's selection-extend flag carried a comment naming a consumer ("the up/down handlers
# read it to decide clamp+stay vs leave the field") that had been gone so long the behaviour it
# described is now the OPPOSITE of the contract — an arrow never leaves the field.
#
# A SECOND RULE THIS HALF LEARNED THE HARD WAY: A NAME PASSED AS A STRING IS A READ. ft-table
# hands a sequence counter's NAME to a helper that reads it by indirection, and the textfield's
# yank length is read inside a ${v:a:b} substring arithmetic — neither looks like `$NAME`, and
# a scan hunting for `$` calls both of them dead. So this counts per OCCURRENCE and asks only
# whether that mention is an assignment; anything else is a use.
note "every module global assigned in controls/ is read"
writeonly=""
for f in controls/*.bash; do
    while read -r nm; do
        [[ -z "$nm" ]] && continue
        uses=$(grep -oE "${nm}(\[[^]]*\])?=?" "$_CORPUS" | grep -vc '=$')
        (( uses == 0 )) && writeonly+="$nm "
    done < <(grep -oE '(^|[^$[:alnum:]_])_FT_[A-Z0-9_]+(\[[^]]*\])?=' "$f" \
             | grep -oE '_FT_[A-Z0-9_]+' | sort -u)
done
check "no module global is written and never read" "${writeonly% }" ""

rm -f "$_CORPUS"
summary
