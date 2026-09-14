#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Overhang audit.
#
#  A control whose BORDER BOX sticks out past the clip rect its ancestors give it
#  is painted through `ft_display_truncate`, once per row, on every repaint —
#  the most expensive route in the draw path, taken to produce a string that
#  never changes. Usually it means a size is wrong somewhere, and it is invisible
#  on screen: the clip does its job and the app looks right.
#
#  This loads every demo headlessly, lays it out, and compares each control's box
#  against the rect `_ft_clip_for` hands its own painting.
#
#      bash tools/audit-overhang.bash              # every demo
#      bash tools/audit-overhang.bash css-demo 8   # one demo, one page
#      bash tools/audit-overhang.bash --teeth      # prove the audit can see one
#
#  THE SCREEN SIZE IS NEVER FORCED, and that is the point of the tool as much as
#  the audit is. A headless harness that assigns FT_COLS *after* sourcing a demo
#  has already let it run `ft-form name=app width="$FT_COLS"` against whatever
#  ft_term_size answered — so the form keeps the old width, the clip moves, and
#  every root-level control overhangs by the difference. That artefact is what
#  `--teeth` reproduces on purpose, and it is what once got written up as a real
#  finding worth 38% of a repaint (docs/rendering-spans-design.md §1.2).
# ─────────────────────────────────────────────────────────────────────────────
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# ── one demo, in its own process (each one builds a whole app) ────────────────
if [[ "${1:-}" == --one ]]; then
    shift
    export FT_NO_WTFIX=1 FT_COLOR_MODE=256
    demo=$1; page=${2:-}; teeth=${3:-}

    # Find the launch line, and remember its NUMBER. Deleting every line matching
    # /^ft-run / — which is what the other headless harnesses do — is wrong:
    # tutorial-demo has `ft-run app' ;;` at column 0 inside a single-quoted string,
    # the tail of a code sample it displays, and cutting that unbalances the quote
    # so the rest of the file becomes one string and not a single control is built.
    # It audited clean for exactly that reason until the "nothing was laid out"
    # guard below said so out loud.
    runline=$(grep -n -m1 "^ft-run [a-zA-Z_][a-zA-Z_0-9]* [a-zA-Z_]" "demo/$demo") \
        || { printf '  %-22s —    not an ft-run app (a headless render harness)\n' "${demo%.bash}"; exit 0; }
    runno=${runline%%:*}
    read -r _ root initfn _rest <<<"${runline#*:}"

    # The copy must live in demo/: every demo computes its repository root from
    # ${BASH_SOURCE[0]}/.., so a copy under /tmp resolves it to / and sources nothing.
    noloop="demo/.audit-overhang-noloop.bash"; sed "${runno}d" "demo/$demo" > "$noloop"
    [[ -n "$page" ]] && export DEMO_PAGE=$page
    source "$noloop" >/dev/null 2>&1
    rm -f "$noloop"
    exec {FT_TTY}>/dev/null
    [[ -n "$teeth" ]] && (( FT_COLS -= 2 ))     # the mistake, made on purpose

    if [[ -n "$initfn" && "$initfn" != "''" ]] && declare -F "$initfn" >/dev/null; then
        "$initfn" >/dev/null 2>&1
    fi
    FT_ROOT=$root
    ft_layout "$root" >/dev/null 2>&1
    # API-EXCEPTION: this tool AUDITS the paint geometry, so driving the repaint and
    # asking for a control's clip rect is the subject, not scaffolding.
    ft_dirty_subtree "$root" 2>/dev/null; ft_redraw_dirty >/dev/null 2>&1

    seen=0; laid=0; over=0; detail=""
    walk() {
        local n=$1 kid
        (( seen++ ))
        local x=${FT_ABSOLUTE_X[$n]:-0} y=${FT_ABSOLUTE_Y[$n]:-0}
        local w=${FT_MEASURED_WIDTH[$n]:-0} h=${FT_MEASURED_HEIGHT[$n]:-0}
        if (( w > 0 && h > 0 )); then
            ft_resolved_prop "$n" display block
            if [[ "$FT_RET" != none ]]; then
                (( laid++ ))
                _ft_clip_for "$n"       # API-EXCEPTION: the clip rect IS what is being audited
                local r=$(( x + w - 1 - FT_CLIP_C1 )) b=$(( y + h - 1 - FT_CLIP_R1 ))
                local l=$(( FT_CLIP_C0 - x ))         t=$(( FT_CLIP_R0 - y ))
                if (( r > 0 || b > 0 || l > 0 || t > 0 )); then
                    (( over++ ))
                    printf -v detail '%s      %-14s %-10s box=[%d..%d]x[%d..%d] clip=[%d..%d]x[%d..%d] R+%d B+%d L+%d T+%d\n' \
                      "$detail" "$n" "${FT_TYPE[$n]:-?}" "$x" $((x+w-1)) "$y" $((y+h-1)) \
                      "$FT_CLIP_C0" "$FT_CLIP_C1" "$FT_CLIP_R0" "$FT_CLIP_R1" \
                      $((r>0?r:0)) $((b>0?b:0)) $((l>0?l:0)) $((t>0?t:0))
                fi
            fi
        fi
        for kid in ${FT_KIDS[$n]:-}; do walk "$kid"; done
    }
    walk "$root"
    printf '  %-22s %-4s %3dx%-3d %3d controls (%3d laid out)  %d overhang\n' \
        "${demo%.bash}" "${page:-–}" "$FT_COLS" "$FT_ROWS" "$seen" "$laid" "$over"
    [[ -n "$detail" ]] && printf '%s' "$detail"
    # A demo that laid nothing out is not a clean demo, it is a demo that did not load.
    (( laid > 0 )) || echo "      NOTHING WAS LAID OUT — this row is not evidence"
    exit 0
fi

# ── the sweep ────────────────────────────────────────────────────────────────
me="$BASH_SOURCE"
if [[ -n "${1:-}" && "$1" != --teeth ]]; then
    bash "$me" --one "${1%.bash}.bash" "${2:-}"
    exit 0
fi

if [[ "${1:-}" == --teeth ]]; then
    echo "── FT_COLS shrunk by two behind the app's back: the audit MUST light up ──"
    bash "$me" --one css-demo.bash 8 teeth
    bash "$me" --one tabs-demo.bash "" teeth
    exit 0
fi

echo "── css-demo, every page ──"
for p in 1 2 3 4 5 6 7 8 9 10; do bash "$me" --one css-demo.bash "$p"; done
echo
echo "── every other demo ──"
for d in demo/*-demo.bash; do
    b=$(basename "$d")
    [[ "$b" == css-demo.bash ]] && continue
    bash "$me" --one "$b"
done
echo
echo "── teeth: the same audit on a deliberately mis-sized app ──"
bash "$me" --teeth
