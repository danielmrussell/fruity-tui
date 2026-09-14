#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  What does ONE PROPERTY READ cost?
#
#      bash tools/bench-resolve.bash [iterations]
#
#  WHY THIS EXISTS. `ft_resolved_prop` is the framework's hot read — 538 of them in one warm
#  layout of css-demo's 37-control page, 54 in every frame of a callout drag — and the whole
#  design of the resolved-property memo (ft-forms.bash, above _ft_resolve_inval) rests on three
#  numbers: what a read costs when the value is on the instance, what it costs when the property
#  INHERITS and the ancestors have to be walked, and what it costs served from the memo.
#
#  IT RUNS ON A TREE WITHOUT THE MEMO TOO, deliberately: drop this file into a checkout that
#  predates it and the memo lines simply do not print, so the before and after are the same
#  measurement of the same function rather than two tools argued against each other.
#
#  THE "MEMO REFUSES THIS ONE" LINE is the honest comparison on a single tree. A property whose
#  name carries a dash fails store-condition 2, so every call pays the probe, the full
#  resolution and the eligibility test and stores nothing — which is what a read costs with the
#  memo present and unable to help.
#
#  GUARDS, because a benchmark that measures nothing reports a beautiful number:
#    · the empty-function floor is measured first and printed, and subtracted in the right-hand
#      column — bash charges ~5µs for a call before it does anything, and a "33µs read" that is
#      really 6µs of call and 27µs of work should say so;
#    · the memoised read must actually HIT — asserted by planting a value no resolution could
#      produce and requiring the read to return it — because a probe that quietly misses would
#      look like a slow memo rather than a broken measurement;
#    · the "refuses this one" read must actually NOT be stored — asserted from the table;
#    · and the inheriting read must actually WALK — asserted by checking the value comes from an
#      ancestor and not from the control itself.
#  A run that fails a guard says so and exits nonzero instead of printing a time.
# ─────────────────────────────────────────────────────────────────────────────
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here" || exit 1
export FT_RECORD="" FT_NO_WTFIX=1
source fruity-tui.bash
ft_init
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
exec {FT_TTY}>"$work/stream"
FT_COLOR_MODE=256; FT_USE_UTF8=1; FT_COLS=100; FT_ROWS=30

iterations=${1:-4000}
has_memo=0
declare -p _FT_RESOLVED_PROP_MEMO >/dev/null 2>&1 && has_memo=1

ft-form name=app width=100 height=30
    ft-frame name=win width=60 height=20 color=201
        ft-label name=leaf text="a label" width=17
    end_ft_frame
end_ft_form
FT_ROOT=app
ft_layout app >/dev/null 2>&1

ft_resolved_prop leaf color
[[ "$FT_RET" == 201 ]] || {
    printf 'GUARD FAILED: leaf does not inherit win colour (got %q), so the inheriting\n  read below would not be walking anything.\n' "$FT_RET"; exit 1; }

memo_key="leaf"$'\x1f'"width"
if (( has_memo )); then
    ft_resolved_prop leaf width
    [[ -n "${_FT_RESOLVED_PROP_MEMO_AT[$memo_key]:-}" ]] \
        || { echo "GUARD FAILED: a warm read left no memo entry — the hit line would be a miss"; exit 1; }
    ft_resolved_prop leaf some-unstorable-name
    [[ -z "${_FT_RESOLVED_PROP_MEMO_AT["leaf"$'\x1f'"some-unstorable-name"]:-}" ]] \
        || { echo "GUARD FAILED: the memo stored a dashed name — the 'refuses' line is a hit"; exit 1; }
fi

empty_function() { :; }
floor=0
LAST=0
measure() {                     # label command…
    local label=$1; shift
    local index started finished
    started=${EPOCHREALTIME/./}
    for (( index = 0; index < iterations; index++ )); do "$@"; done
    finished=${EPOCHREALTIME/./}
    local nanoseconds_each=$(( (finished - started) * 1000 / iterations ))
    printf '  %-48s %5d.%01d us' "$label" $(( nanoseconds_each / 1000 )) $(( (nanoseconds_each % 1000) / 100 ))
    if (( floor )); then
        local over=$(( nanoseconds_each - floor ))
        printf '  %5d.%01d us of work' $(( over / 1000 )) $(( (over < 0 ? -over : over) % 1000 / 100 ))
    fi
    echo
    LAST=$nanoseconds_each
}

printf 'one property read, averaged over %d calls   (resolved-property memo: %s)\n\n' \
       "$iterations" "$( (( has_memo )) && echo present || echo absent )"
measure "an empty function call (the floor)" empty_function
floor=$LAST
echo
if (( has_memo )); then
    measure "ft_resolved_prop, served from the memo"       ft_resolved_prop leaf width
    measure "ft_resolved_prop, a name the memo refuses"    ft_resolved_prop leaf some-unstorable-name
else
    measure "ft_resolved_prop, value on the instance"      ft_resolved_prop leaf width
    measure "ft_resolved_prop, a name nothing resolves"    ft_resolved_prop leaf some-unstorable-name
fi
measure "ft_resolved_prop, INHERITED (ancestor walk)"      ft_resolved_prop leaf color
measure "ft_resolve alone, value on the instance"          ft_resolve leaf width
measure "ft_resolve alone, INHERITED (ancestor walk)"      ft_resolve leaf color
measure "ft_own_prop, value on the instance"               ft_own_prop leaf width
measure "_ft_get_raw, the shell variable and nothing else" _ft_get_raw leaf width
measure "_ft_disp"                                         _ft_disp leaf
measure "ft_style (the paint path, memoised already)"      ft_style leaf color

if (( has_memo )); then
    echo
    echo "the memo must have been HITTING, or its line above is a miss wearing its name:"
    ft_resolved_prop leaf width >/dev/null
    _FT_RESOLVED_PROP_MEMO[$memo_key]="planted"
    ft_resolved_prop leaf width
    if [[ "$FT_RET" == planted ]]; then
        printf '  ok — a planted answer was served\n'
        _ft_resolve_forget leaf width
    else
        printf '  GUARD FAILED: the read did not come from the memo (got %q)\n' "$FT_RET"
        exit 1
    fi
fi
