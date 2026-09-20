#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  STEPPING MUST LEAVE THE SCREEN A FRESH RENDER WOULD PRODUCE — colours included.
#
#  A step change goes down the incremental path: damage the old callout's extent, refill each
#  cell's ground, repaint what the rect touched, composite. Every bug in that chain shows up as
#  RESIDUE — glyphs of the previous step still standing, or a band of the wrong background
#  stamped where the refill guessed one ground for a rect that straddled two (the page-8 bug:
#  a callout extent half in the screen margin, half over the frame, refilled entirely with the
#  frame's body grey — a grey band across the black margin).
#
#  So: drive the app's own step path with every tty byte captured, replay the byte history into
#  a cell grid (glyph + fg + bg), and require it to equal a from-scratch render of the same end
#  state. The text-only pty harness cannot see the band (same glyphs, wrong colour); this can.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
export FT_NO_WTFIX=1
noloop="$here/demo/.css-demo-residue.bash"
sed '/^ft_run app/d' "$here/demo/css-demo.bash" > "$noloop"
tmp=$(mktemp -d); trap 'rm -rf "$tmp" "$noloop"' EXIT
source "$noloop"
FT_COLOR_MODE=256; FT_USE_UTF8=1
FT_ROOT=app                      # ft_run sets this in the real app; the damage repair needs it

# The default two sizes bound the run at ~90s; the four-size sweep is opt-in like test-callout's:
#     FT_RESIDUE_SIZES="80 30|95 34|120 40|170 50" bash tests/test-residue.bash
IFS='|' read -r -a _sizes <<< "${FT_RESIDUE_SIZES:-95 34|170 50}"
for size in "${_sizes[@]}"; do
    set -- $size; FT_COLS=$1; FT_ROWS=$2
    note "at ${FT_COLS}×${FT_ROWS}"
    steps_driven=0; thin_pages=""
    for PAGE in 1 2 3 4 5 6 7 8 9 10; do
        exec {FT_TTY}>"$tmp/stream"
        _resize >/dev/null 2>&1                    # full frame for STEP=1
        settle >/dev/null 2>&1   # ft_run settles the burst; a gate must too
        _page_annotations; nsteps=${#PA_TARGET[@]}
        (( nsteps >= 2 )) || thin_pages+=" p$PAGE($nsteps)"
        for (( s=2; s<=nsteps; s++ )); do
            STEP=$s; _goto_step                    # the app's own incremental path
            settle >/dev/null 2>&1   # ft_run settles the burst; a gate must too
            (( steps_driven++ ))
        done
        exec {FT_TTY}>&-; exec {FT_TTY}>/dev/null
        FT_OUT=""; _ft_redraw_walk app >/dev/null 2>&1; _ft_composite_overlays
        printf '%s' "$FT_OUT" > "$tmp/fresh"
        a=$(python3 "$here/tools/screen-cells.py" "$tmp/stream" "$FT_ROWS" "$FT_COLS")
        b=$(python3 "$here/tools/screen-cells.py" "$tmp/fresh"  "$FT_ROWS" "$FT_COLS")
        # THE INK GUARD. screen-cells.py emits one line per NON-BLANK cell, so two blank screens
        # compare equal and this verdict reports "no residue" for a page that never drew anything.
        # The corpus guard below asks whether the sweep took STEPS; this asks whether those steps
        # put INK on the screen, which is a different question and the one this comparison rests
        # on. Found by a mutation sweep, 2026-08-30: with ft_draw_one returning without drawing,
        # this file scored 24/24 — a full pass with the renderer lobotomised. Its sibling
        # test-stale.bash already answers "the scene painted NOTHING" as a failure; the lesson had
        # not been carried across.
        painted=$(printf '%s' "$b" | grep -c .)
        if (( painted < 40 )); then
            check "p$PAGE @${FT_COLS} the page actually painted (>=40 cells)" "$painted" ">=40"
        elif [[ "$a" == "$b" ]]; then check "p$PAGE @${FT_COLS} stepping leaves no residue" 1 1
        else
            check "p$PAGE @${FT_COLS} stepping leaves no residue" 0 1
            diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -6 | sed 's/^/         /'
        fi
    done
    # THE CORPUS, GUARDED — the ten verdicts above are only about STEPPING while there are steps
    # to take. `for (( s=2; s<=nsteps; s++ ))` runs zero times on a one-step page, and then the
    # captured byte stream holds nothing but the _resize full frame, which a fresh render
    # reproduces exactly: ten green verdicts for a walk that never entered the incremental path
    # at all. Proven by truncating the demo's per-page annotation table to one entry — zero
    # _goto_step calls, and every "stepping leaves no residue" check still reported green.
    #
    # css-demo's step counts are literal `_ann` calls in _page_annotations' `case "$PAGE"`, and
    # nothing outside this file pins them: tests/test-css-demo.bash only implies page 1 has two
    # or more. (test-callout.bash's twin sweep is at least partly backstopped externally —
    # test-callout-demo.bash:280 pins its tour at more than thirty steps and every page at one
    # or more. css-demo has no equivalent, which is why the guard has to live here.)
    #
    # Measured 2026-08-30: 26 annotations over the ten pages → 16 increments per size sweep.
    # A page gaining a teaching step is fine; a page LOSING its steps is the walk breaking.
    #
    # WATCHED FAILING, 2026-08-30: with _page_annotations overridden to keep one entry per page
    # (the collapse the prober used), the ten residue verdicts stayed GREEN — they always will,
    # there is nothing to compare — and these two went red: "every page had a step to take"
    # named all ten, and the increment count read 0. 10/12, exit 1.
    check "every page had a step to take" "${thin_pages:-none}" "none"
    check "the sweep drove the incremental path $steps_driven times (16 or more)" \
          "$(( steps_driven >= 16 ? 1 : 0 ))" 1
done

summary
