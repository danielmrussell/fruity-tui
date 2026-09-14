#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fork audit.
#
#  A fork costs milliseconds — thousands of times a bash builtin. In a TUI that
#  repaints on every keystroke, one `$(…)` on a hot path is felt immediately. The
#  rule for this framework is: NO command substitution, no pipelines to external
#  tools, no backticks in code that runs while an app is live.
#
#  This lists every candidate in the runtime (the framework and its controls), so
#  a hot-path fork cannot creep back in unnoticed.
#
#      bash tools/audit-forks.bash
# ─────────────────────────────────────────────────────────────────────────────
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

runtime_files=(ft-*.bash controls/*.bash fruity-tui.bash)

echo "── command substitution  \$( … )  and backticks ──"
grep -nE '\$\(|`' "${runtime_files[@]}" \
  | grep -vE '\$\(\(' \
  | grep -vE '^\s*[^:]+:[0-9]+:\s*#' \
  | sed 's/^/  /' || echo "  none"

echo
echo "── external commands often reached for by accident ──"
for command_name in sed awk grep cut tr sort head tail wc date cat expr bc printf-e; do
    hits=$(grep -nE "(^|[;&|( ])${command_name}( |$)" "${runtime_files[@]}" \
           | grep -vE '^\s*[^:]+:[0-9]+:\s*#' | grep -c .)
    (( hits > 0 )) && printf '  %-8s %d\n' "$command_name" "$hits"
done

echo
echo "(\$(( … )) is arithmetic, not a fork, and is excluded above.)"
