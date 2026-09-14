#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — tests/_harness.bash
#
#  Minimal shared test harness sourced by every tests/test-*.bash file.
#  API: note (section header), check (compare actual/expected), ok/no (assert
#  a command's exit status), summary (print totals, exit non-zero on failure).
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_HARNESS_LOADED:-}" ]] && return 0
_FT_HARNESS_LOADED=1

_H_PASS=0
_H_FAIL=0
# SUBSHELL CHECKS COUNT. `( FT_USE_UTF8=0; …; check … )` is the natural way to scope a setting
# to one assertion, and a `check` inside it used to bump _H_PASS/_H_FAIL in the SUBSHELL only:
# its FAIL line printed, then vanished — summary still said "all passed" and exited 0. Every
# verdict is therefore also appended to a tally file, and summary counts the FILE.
_H_TALLY=$(mktemp "${TMPDIR:-/tmp}/ft-tally.XXXXXX")
_h_pass() { (( _H_PASS++ )); printf 'P\n' >> "$_H_TALLY"; }
_h_fail() { (( _H_FAIL++ )); printf 'F\n' >> "$_H_TALLY"; }

# A test must never read or write the developer's own saved UI state (ft-state.bash puts it
# under XDG_STATE_HOME). Point that at a throwaway directory before fruity-tui.bash computes
# the default path, so a stray ft_state_save in a test cannot land in a real home directory
# and a real save cannot decide what a test sees.
# (One fixed directory, and no EXIT trap — a test file that installs its own would replace
# ours and the cleanup would silently stop happening.)
export XDG_STATE_HOME="${TMPDIR:-/tmp}/ft-test-state"

if [[ -t 1 ]]; then
    _H_GREEN=$'\e[32m'; _H_RED=$'\e[31m'; _H_DIM=$'\e[2m'; _H_BOLD=$'\e[1m'; _H_RESET=$'\e[0m'
else
    _H_GREEN=''; _H_RED=''; _H_DIM=''; _H_BOLD=''; _H_RESET=''
fi

note() { printf '\n%s%s%s\n' "${_H_BOLD}" "$1" "${_H_RESET}"; }

check() { # desc actual expected
    local desc=$1 actual=$2 expected=$3
    if [[ "$actual" == "$expected" ]]; then
        _h_pass
        printf '  %sok%s   %s\n' "${_H_GREEN}" "${_H_RESET}" "$desc"
    else
        _h_fail
        printf '  %sFAIL%s %s\n' "${_H_RED}" "${_H_RESET}" "$desc"
        printf '       %sexpected:%s %q\n' "${_H_DIM}" "${_H_RESET}" "$expected"
        printf '       %sactual:  %s %q\n' "${_H_DIM}" "${_H_RESET}" "$actual"
    fi
}

ok() { # desc cmd args...
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then
        _h_pass
        printf '  %sok%s   %s\n' "${_H_GREEN}" "${_H_RESET}" "$desc"
    else
        _h_fail
        printf '  %sFAIL%s %s (expected success: %s)\n' "${_H_RED}" "${_H_RESET}" "$desc" "$*"
    fi
}

no() { # desc cmd args...
    local desc=$1; shift
    if ! "$@" >/dev/null 2>&1; then
        _h_pass
        printf '  %sok%s   %s\n' "${_H_GREEN}" "${_H_RESET}" "$desc"
    else
        _h_fail
        printf '  %sFAIL%s %s (expected failure: %s)\n' "${_H_RED}" "${_H_RESET}" "$desc" "$*"
    fi
}

# settle — DO WHAT THE RUN LOOP DOES AT THE END OF A BURST, for a gate that drives an app's
# handlers directly instead of through ft-run.
#
# A demo handler does not paint: it changes properties, and `ft-run` settles the burst once
# (ft_reflow_flush, then ft_redraw_dirty) when the input drains. A gate that calls `_goto_step`
# by hand skips that, so nothing repaints and the gate reads a stale screen. Six demos used to
# carry a trailing `ft_redraw_dirty` for this — app code existing to satisfy the harness, and
# a NO-OP under ft-run at that, since ft_redraw_dirty returns immediately while FT_COALESCING
# is set. The scaffolding belongs here, where the harness can ask for a paint, not in an app.
# It mirrors ft-run's settle EXACTLY, including the deferred branch — `ft_refresh` does not
# paint, it sets FT_DEFER_ROOT and lets the loop lay out and redraw once at the end of the
# burst. A settle that only called ft_redraw_dirty would leave a demo that ends in ft_refresh
# (every _show_page does) unpainted, which is a different stale screen for the same reason.
settle() {
    ft_reflow_flush
    if [[ -n "${FT_DEFER_ROOT:-}" ]]; then
        ft_layout "$FT_DEFER_ROOT"
        ft_repaint_all "$FT_DEFER_ROOT"
        FT_DEFER_ROOT=""
    else
        ft_redraw_dirty
    fi
    return 0
}

summary() {
    # Counted from the tally, not the variables — a verdict reached inside a subshell is in
    # the file and nowhere else. (_H_PASS/_H_FAIL stay as the in-process view.)
    local pass=0 fail=0 v
    if [[ -r "$_H_TALLY" ]]; then
        while read -r v; do case $v in P) (( pass++ )) ;; F) (( fail++ )) ;; esac; done < "$_H_TALLY"
        rm -f "$_H_TALLY"
    else
        pass=$_H_PASS; fail=$_H_FAIL
    fi
    printf '\n%s%d/%d assertions passed%s\n' "${_H_BOLD}" "$pass" "$(( pass + fail ))" "${_H_RESET}"
    (( fail == 0 )) || exit 1
}
