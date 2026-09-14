#!/usr/bin/env bash
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
export FT_NO_WTFIX=1
noloop="demo/.css-demo-noloop.bash"; sed '/^ft-run app/d' demo/css-demo.bash > "$noloop"; source "$noloop"; rm -f "$noloop"
exec {FT_TTY}>/dev/null
FT_COLOR_MODE=256; FT_ROWS=40; FT_COLS=118
ms() { ft_now_ms; echo "$FT_RET"; }

# TELL THE APP THE SIZE, DO NOT JUST WRITE IT DOWN. Sourcing the demo above already ran its
# `ft-form name=app width="$FT_COLS"`, using whatever ft_term_size answered — the real
# terminal if this has a tty (120x30 here), $LINES/$COLUMNS if not. Assigning FT_COLS
# afterwards moves the CLIP and leaves the form at its old width, and the app is then two
# columns wider than the screen it is being measured against. That is not a small error: this
# file reported page 8 at ~200 ms, of which ~77 ms was ft_display_truncate cutting two columns
# off all 30 rows of a root form overhanging a screen edge no user has. Told the size, the same
# page is ~95 ms and truncates nothing at all — and the "38% of a repaint" finding written up
# from the old numbers in docs/rendering-spans-design.md §1.2 was an artefact of this one line
# ordering. `_resize` is the demo's own WINCH handler; calling it is what a real terminal does.
_resize >/dev/null 2>&1
# And then CHECK, because the failure above was silent for as long as it existed. A probe that
# cannot see its own subject mis-set has no business printing timings. The question is not what
# the clip does — that was the proxy this was first written with, and it needed a private engine
# call to ask — it is whether the form was BUILT to the screen it is being measured against.
ft_own_prop app width; _perf_declared=$FT_RET
_perf_measured=${FT_MEASURED_WIDTH[app]:-unset}; _perf_x=${FT_ABSOLUTE_X[app]:-unset}
if [[ "$_perf_declared" != "$FT_COLS" || "$_perf_measured" != "$FT_COLS" || "$_perf_x" != 0 ]]; then
    echo "REFUSING TO REPORT: the screen is $FT_COLS columns but the root form declares" \
         "$_perf_declared, measures $_perf_measured and sits at x=$_perf_x. The app and the" \
         "screen disagree, so every number below would be measuring that mismatch rather" \
         "than the framework." >&2
    exit 2
fi

PAGE=8; STEP=1; AN_NAME=glow; AN_DUR=4; _show_page >/dev/null 2>&1
FT_ROOT=app; ft_layout app >/dev/null 2>&1
STEP=2; _goto_step >/dev/null 2>&1; STEP=1; _goto_step >/dev/null 2>&1   # warm

echo "── step change (the frequent interaction) ──"
for s in 2 3 2 3; do STEP=$s; a=$(ms); _goto_step >/dev/null 2>&1; b=$(ms); echo "  _goto_step → $s : $(( b - a )) ms"; done

echo "── inside a step change ──"
STEP=2
a=$(ms); ft_remove stepcallout >/dev/null 2>&1; b=$(ms); echo "  destroy callout : $(( b - a )) ms"
a=$(ms); _place_callout >/dev/null 2>&1; b=$(ms); echo "  create callout  : $(( b - a )) ms"
a=$(ms); ft_draw_one stepcallout >/dev/null 2>&1; b=$(ms); echo "  PAINT callout (placement search + route) : $(( b - a )) ms"
a=$(ms); ft_draw_one stepcallout >/dev/null 2>&1; b=$(ms); echo "  PAINT callout (cached placement)        : $(( b - a )) ms"
a=$(ms); ft_dirty_subtree lower; ft_redraw_dirty >/dev/null 2>&1; b=$(ms); echo "  stage repaint   : $(( b - a )) ms"   # API-EXCEPTION: this probe MEASURES the repaint pipeline; invoking it is the subject, not scaffolding
