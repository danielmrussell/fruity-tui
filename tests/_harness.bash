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
# handlers directly instead of through ft_run.
#
# A demo handler does not paint: it changes properties, and `ft_run` settles the burst once
# (ft_reflow_flush, then ft_redraw_dirty) when the input drains. A gate that calls `_goto_step`
# by hand skips that, so nothing repaints and the gate reads a stale screen. Six demos used to
# carry a trailing `ft_redraw_dirty` for this — app code existing to satisfy the harness, and
# a NO-OP under ft_run at that, since ft_redraw_dirty returns immediately while FT_COALESCING
# is set. The scaffolding belongs here, where the harness can ask for a paint, not in an app.
# It mirrors ft_run's settle EXACTLY, including the deferred branch — `ft_refresh` does not
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

# go_cold — throw away everything the framework remembers between frames. NOT a framework
# function on purpose: it reaches into internals a control never should, and only a test wants it.
#
# SHARED, because two gates rest on it and a copy of it is a future disagreement between them.
# tests/test-stale.bash paints warm and then cold and demands the same frame — a cache that
# forgot an input. tests/test-incremental.bash repaints cold as the ORACLE for an incremental
# frame, and there the cold part is not thoroughness, it is the whole instrument: a WARM full
# repaint serves every control its retained block, so a control nobody told to repaint replays
# its stale block in the "full" frame too, and the two agree on the wrong picture. Measured with
# ft_dirty's dependency walk removed: a warm oracle scored 12 of 12 cases identical, a cold one
# caught the four that scroll a bar's target.
#
# test-stale enumerates every cache-shaped array in the framework and fails by name when this
# body does not mention one — which now protects both gates at once.
go_cold() {
    local n
    # A store-backed property may be DEFERRED (the line store is the only copy of the text).
    # Materialise those first: dropping the store while it is authoritative would not be a
    # cold cache, it would be data loss, and every scene would "differ" for the wrong reason.
    for n in "${!_FT_TEXT_STALE[@]}"; do _ft_text_join "$n"; done
    for n in "${!FT_TYPE[@]}"; do
        unset "_fti_${n}__wrapkey0" "_fti_${n}__wraplines0" "_fti_${n}__wrapkey1" \
              "_fti_${n}__wraplines1" "_fti_${n}__wrapnext" \
              "_fti_${n}__extkey" "_fti_${n}__exttw" "_fti_${n}__extth" "_fti_${n}__extgen" \
              "_fti_${n}__lines" "_fti_${n}__linesgen" "_fti_${n}__linesprop" \
              "_fti_${n}__maxw" "_fti_${n}__nchars" \
              "_fti_${n}__rows0" "_fti_${n}__rows1" "_fti_${n}__rowsw0" "_fti_${n}__rowsw1" \
              "_fti_${n}__rowsnext" "_fti_${n}__lochintidx" "_fti_${n}__lochintacc" \
              "_fti_${n}__lochintgen" "_fti_${n}__sig" \
              "_fti_${n}__fitw" "_fti_${n}__fitkey"
        # __fitw/__fitkey ARE a derivation — a table's column widths fitted to the box it
        # got — so they belong above. Everything the key forgets shows up here as a warm
        # frame that differs from the cold one: the box width, the natural widths, and
        # whether the width was the author's or the content's.
        #
        # NOT cleared, though they live under the same _fti_ prefix and look like caches:
        #   __cells  a table's row data — content, not a derivation
        #   __colw   a table's measured column widths. These are STATE despite the name: drop
        #            them and the table renders short forever, because nothing re-measures
        #            (verified — a re-layout does not restore them). Nothing in the framework
        #            unsets them either, so this is a note about the naming, not a live bug;
        #            a test that cleared them would be reporting its own damage as a finding.
    done
    # THE RETAINED DISPLAY LIST — the largest cache in the framework, and the one this file is
    # the natural gate for: warm serves each control's stored block, cold re-derives it, and
    # "identical cell by cell" is precisely the claim retention makes. Both tables go; the
    # entries ARE the values, so unsetting them is a miss and never a collision (the version
    # counters that must be BUMPED rather than unset are _FT_RESOLVE_VERSION's, below).
    FT_RETAINED_BLOCK=(); FT_RETAINED_TOKEN=()
    FT_SHEEN_FROZEN=(); FT_SHEEN_FROZEN_SIGNATURE=(); FT_SHEEN_LIT_CELL=()
    _FT_TEXTFIELD_LINES_CACHE_KEY=""; _FT_TEXTFIELD_EDIT_FIELD=""
    _FT_STYLE_C=(); _FT_CSS_Q_C=(); _FT_CSS_QPE_C=(); _FT_SGR_CACHE=(); FT_COERCED=()
    # The clip memo. Its generation counter is bumped by hand at every route that can move a
    # rect (tests/test-clip.bash drives each one), so the interesting question here is the one
    # this file asks of everything: does the frame come out the same with the table empty?
    _FT_CLIP_CACHE=()
    # The resolved-property memo. Its VALUES go and its VERSIONS stay: _FT_RESOLVE_VERSION and
    # _FT_RESOLVE_GENERATION are what stop a rebuilt control reading a dead one's answer, and
    # resetting them here would be this file manufacturing the very collision it exists to catch.
    _FT_RESOLVED_PROP_MEMO=(); _FT_RESOLVED_PROP_MEMO_AT=()
    # The animated foreground. It is asked twice a frame — once to NAME the frame so an
    # unchanged one is never drawn, once by the paint that draws it — and the memo is what
    # makes the second ask free. Values and token both go: the entries ARE the answers.
    _FT_CSS_ANIM_FG=(); _FT_CSS_ANIM_FG_AT=()
    # The two pure memos in ft-core. Neither can go stale — a character's width and a
    # colour's nearest index are functions of their inputs alone — so dropping them is not
    # about correctness of the CACHE, it is about making the cold pass actually COMPUTE.
    # Left in place, the "cold" frame would be measured entirely from the warm run's tables
    # and this file would be comparing a memo against itself.
    _FT_CHAR_COLS_MEMO=(); _FT_RGB256_MEMO=(); _FT_RGB256_MEMO_N=0
    _FT_CSS_EPOCH=$(( ${_FT_CSS_EPOCH:-0} + 1 ))
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
