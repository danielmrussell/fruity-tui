#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  THE TRANSITION, PINNED ON CELLS — glyph, foreground AND background.
#
#  A transition is exactly the kind of feature that passes every state assertion while looking
#  wrong, so the claims are checked the way the project checks rendering: the real bytes are
#  replayed into a cell grid by tools/screen-cells.py, which shares no code with the module
#  under test. If the blend arithmetic and the reader were the same code, a sign error would
#  agree with itself.
#
#  The three claims that matter:
#    · THE CUT IS INVISIBLE — at the cut frame every inked cell has fg == bg, so no glyph in
#      the region can be seen at the instant the two layers are exchanged.
#    · THE END IS THE REAL THING — the last frame is cell-identical to a from-scratch render
#      of the finished control, colours included, so nothing steps when the engine takes over.
#    · THE OTHER SCHEDULE DOES NOT — `average` never reaches zero contrast. That is the
#      measured refutation of the first design, and it is pinned so it cannot quietly become
#      true (or quietly stop being recorded).
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
cd "$here"
export FT_NO_WTFIX=1
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_USE_UTF8=1
FT_COLOR_MODE=truecolor
FT_COLS=95; FT_ROWS=34

work=$(mktemp -d); trap 'rm -rf "$work" demo/.tr-demo-gate.bash' EXIT

RUN_ID=0
APP=""; POP=""
build() {                       # schedule
    (( RUN_ID++ )); APP="app$RUN_ID"; POP="pop$RUN_ID"
    ft_stylesheet name=gate style="
        .morph { transition: opacity 330ms ease-in-out; --transition-schedule: $1; }
    "
    ft-form name="$APP" width="$FT_COLS" height="$FT_ROWS"
        ft-frame name="win$RUN_ID" position=absolute left=2 top=1 width=70 height=22 \
                 title="Settings" display=flex flexDirection=column gap=1
            ft-label name="a$RUN_ID" text="The quick brown fox jumps over the lazy dog"
            ft-label name="b$RUN_ID" text="Compression: high   Beep: on   Retries: 3"
            ft-label name="c$RUN_ID" text="A second paragraph of ordinary body text here."
        end_ft_frame
    end_ft_form
    FT_ROOT=$APP
    ft_layout "$APP"
    FT_OUT=""; _ft_redraw_walk "$APP"; FT_OUT=""
    ft-frame name="$POP" class=morph position=absolute left=8 top=4 width=40 height=8 \
             title="Notice" backgroundColor=57 color=231 borderColor=213 parent="$APP"
        ft-label name="body$RUN_ID" text="Compression finished." color=231
    end_ft_frame
    ft_layout "$APP"
}
# The ground as the engine itself resolves it — the base every frame is written on top of.
ground_bytes_for() {            # → FT_RET, and RECT holds the transitioning rect
    ft_transition_rect "$POP"; RECT=$FT_RET
    local top left bottom right
    read -r top left bottom right <<< "$RECT"
    # _ft_transition_capture_ground is engine instrumentation, like _ft_redraw_walk below:
    # there is no public "give me the cells under this rect", and there should not be.
    _ft_transition_capture_ground "$top" "$left" "$bottom" "$right"
}
# EVERY ARMED TRANSITION MUST BE CANCELLED. An armed one keeps an animation running, and the
# next section's rect is in the same place — so a leftover made _ft_transition_ground_animates
# say "the ground moves", every later transition silently took the LIVE path, and one
# assertion compared two garbage frames to each other and passed.
finish() { ft_transition_active "$POP" && ft_transition_cancel "$POP"; return 0; }
precomputed_or_fail() {         # label
    if ft_transition_live "$POP"; then check "$1: the precomputed path was taken" 0 1
    else check "$1: the precomputed path was taken" 1 1; fi
}
# one frame of whatever is armed on $POP, by index -> FT_RET
frame_of() { ft_transition_frame "$POP" "$1"; }
RECT=""
# Replay bytes into cells and keep only the transitioning rect. One line per inked cell:
# "row,col<TAB>glyph<TAB>fg=… bg=… flags".
# RECT IS PASSED IN, never read from the live table: ft_transition_cancel clears that entry,
# and the first version of this test filtered the "real render" cells through an EMPTY rect,
# matched nothing, and reported a cell-exact match as a total mismatch.
#
# COLOURS ARE COMPARED AS COLOURS, NOT AS BYTES. The theme's palette is authored as xterm-256
# INDICES and the engine emits `38;5;213`; the blend computes in RGB and emits `38;2;255;135;255`.
# On a truecolor terminal those are the same pixel, but a string compare called them different
# and reported a cell-exact final frame as 110/110 wrong. So both forms are reduced to r,g,b
# here, with xterm's own cube/grey rule written out independently of the framework's copy of it.
# Indices 0-15 are deliberately NOT converted: those are the terminal's own configurable
# palette and have no fixed RGB, which is a real limit of this feature (docs/transitions.md).
cells_in_rect() {               # rect ("t l b r"); reads $FILE → stdout
    local top left bottom right
    read -r top left bottom right <<< "$1"
    python3 tools/screen-cells.py "$FILE" "$FT_ROWS" "$FT_COLS" | awk -F'\t' -v t="$top" \
        -v l="$left" -v b="$bottom" -v r="$right" '
        function level(x) { return x == 0 ? 0 : 55 + 40*x }
        function rgb(spec,   n, v) {
            if (spec ~ /^2:/) return substr(spec, 3)
            if (spec !~ /^5:/) return spec
            n = substr(spec, 3) + 0
            if (n >= 232) { v = 8 + 10*(n-232); return v "," v "," v }
            if (n < 16) return spec                    # the terminal palette: no fixed RGB
            n -= 16
            return level(int(n/36)) "," level(int(n/6)%6) "," level(n%6)
        }
        {
            split($1, p, ","); rr = p[1]+0; cc = p[2]+0
            if (rr < t || rr > b || cc < l || cc > r) next
            fg = $3; sub(/^fg=/, "", fg); sub(/ .*$/, "", fg)
            rest = $3; sub(/^.*bg=/, "", rest); bg = rest; sub(/ .*$/, "", bg)
            flags = $3; if (flags ~ / [bdur]+$/) { sub(/^.* /, "", flags) } else { flags = "" }
            printf "%s\t%s\tfg=%s bg=%s %s\n", $1, $2, rgb(fg), rgb(bg), flags
        }'
}

note "the cut frame: every inked cell in the region has fg == bg"
build contrast
ok "the cascade arms the transition" ft_transition_in "$POP"
ok "...and it reports itself active" ft_transition_active "$POP"
ft_transition_cut_frame "$POP"; CUT=$FT_RET
ft_transition_frame_count "$POP"; FRAMES=$FT_RET
precomputed_or_fail "cut"
check "there are frames to look at" "$(( FRAMES > 4 ))" 1
ground_bytes_for; GROUND=$FT_RET
FILE="$work/cut"
frame_of "$CUT"; printf '%s%s' "$GROUND" "$FT_RET" > "$FILE"
same=0; diff=0
while IFS=$'\t' read -r pos glyph attrs; do
    [[ -z "$attrs" ]] && continue
    fg=${attrs#fg=}; fg=${fg%% *}
    bg=${attrs#*bg=}; bg=${bg%% *}
    if [[ "$fg" == "$bg" ]]; then (( same++ )); else (( diff++ )); fi
done < <(cells_in_rect "$RECT")
check "cut frame: inked cells found at all" "$(( same + diff > 0 ))" 1
check "cut frame: cells whose glyph is visible" "$diff" 0
note "  ($same inked cells in the region, all with foreground == background)"

note "the last frame is a from-scratch render of the finished control"
FILE="$work/last"
frame_of $(( FRAMES - 1 )); printf '%s%s' "$GROUND" "$FT_RET" > "$FILE"
cells_in_rect "$RECT" > "$work/last.cells"
ft_transition_cancel "$POP"
FT_OUT=""; _ft_redraw_walk "$POP"; REAL=$FT_OUT; FT_OUT=""
FILE="$work/real"
printf '%s%s' "$GROUND" "$REAL" > "$FILE"
cells_in_rect "$RECT" > "$work/real.cells"
if diff -q "$work/last.cells" "$work/real.cells" >/dev/null; then
    check "last frame == real render, cell for cell, colours included" 1 1
else
    check "last frame == real render, cell for cell, colours included" 0 1
    diff "$work/real.cells" "$work/last.cells" | head -6 | sed 's/^/       /'
fi
check "the region was not empty" "$(( $(grep -c . "$work/real.cells") > 100 ))" 1

note "the other schedule: averaging the two FOREGROUNDS never hides the glyph"
build average
ok "the average schedule arms" ft_transition_in "$POP"
ft_transition_cut_frame "$POP"; ACUT=$FT_RET
ground_bytes_for; AGROUND=$FT_RET
FILE="$work/acut"
frame_of "$ACUT"; printf '%s%s' "$AGROUND" "$FT_RET" > "$FILE"
visible=0
while IFS=$'\t' read -r pos glyph attrs; do
    [[ -z "$attrs" ]] && continue
    fg=${attrs#fg=}; fg=${fg%% *}
    bg=${attrs#*bg=}; bg=${bg%% *}
    [[ "$fg" != "$bg" ]] && (( visible++ ))
done < <(cells_in_rect "$RECT")
check "average: the glyphs are still visible at its own cut" "$(( visible > 50 ))" 1
note "  ($visible cells legible at the instant the glyphs are exchanged — this is the refutation)"
finish

note "the two schedules differ ONLY in the foreground"
# Algebra says so: `average`'s background goes bottom → (bottom+top)/2 → top with each half
# taking half the time, and the midpoint of a linear interpolation lies ON the line, so that
# is the same curve as `contrast`'s single bottom → top. Worth pinning, because it means the
# whole of the visible difference is the foreground rule — the part he accepted.
build contrast; ft_transition_in "$POP" >/dev/null
precomputed_or_fail "schedule compare (contrast)"
ground_bytes_for; G2=$FT_RET
bgs_of() {                      # base index → stdout (bg per cell)
    FILE="$work/bgsample"
    ft_transition_frame "$POP" "$1"
    printf '%s%s' "$G2" "$FT_RET" > "$FILE"
    cells_in_rect | awk -F'\t' '{ split($3, a, "bg="); split(a[2], b, " "); print $1, b[1] }'
}
bgs_of 2 > "$work/bg-contrast"
ft_transition_cancel "$POP"
build average; ft_transition_in "$POP" >/dev/null
precomputed_or_fail "schedule compare (average)"
ground_bytes_for; G2=$FT_RET
bgs_of 2 > "$work/bg-average"
if diff -q "$work/bg-contrast" "$work/bg-average" >/dev/null; then
    check "identical backgrounds at the same frame" 1 1
else
    check "identical backgrounds at the same frame" 0 1
    diff "$work/bg-contrast" "$work/bg-average" | head -4 | sed 's/^/       /'
fi
ft_transition_cancel "$POP"

note "batching: the unit of work is a run, not a cell"
build contrast; ft_transition_in "$POP" >/dev/null
precomputed_or_fail "batching"
check "a 40x8 rect reduces to far fewer runs than cells" \
    "$(( FT_TRANSITION_LAST_RUNS < 60 && FT_TRANSITION_LAST_RUNS > 0 ))" 1
check "runs share a handful of blend classes" \
    "$(( FT_TRANSITION_LAST_CLASSES <= 12 && FT_TRANSITION_LAST_CLASSES > 0 ))" 1
note "  ($FT_TRANSITION_LAST_RUNS runs, $FT_TRANSITION_LAST_CLASSES classes, for 320 cells)"

note "a control in transition does not paint itself"
FT_OUT=""; ft_draw_one "$POP"; drew=${#FT_OUT}; FT_OUT=""
check "ft_draw_one is a no-op while the transition owns the cells" "$drew" 0
FT_OUT=""; ft_draw_one "body$RUN_ID"; drew=${#FT_OUT}; FT_OUT=""
check "…and so is a child of it" "$drew" 0
_ft_composite_overlays; FT_OUT=""
ft_transition_cancel "$POP"
FT_OUT=""; ft_draw_one "$POP"; drew=${#FT_OUT}; FT_OUT=""
check "after cancelling, it paints normally again" "$(( drew > 0 ))" 1

note "playback is a write, not a computation"
build contrast; ft_transition_in "$POP" >/dev/null
precomputed_or_fail "playback"
ft_transition_frame_count "$POP"; PN=$FT_RET
ft_now_ms; t0=$FT_RET
for rep in 1 2 3 4 5 6 7 8 9 10; do
    for (( i=0; i<PN; i++ )); do frame_of "$i"; printf '%s' "$FT_RET" >&"$FT_TTY"; done
done
ft_now_ms; per=$(( (FT_RET - t0) * 1000 / (PN*10) ))
# A budget, not a benchmark: measured at 63-100us, so 2000us catches a 20x regression (the
# kind a per-cell loop creeping back in would produce) without failing on a loaded machine.
check "under 2000us per frame (measured ${per}us)" "$(( per < 2000 ))" 1
ft_transition_cancel "$POP"

note "the live path is chosen when, and only when, the ground animates"
build contrast
ft_transition_in "$POP" >/dev/null
if ft_transition_live "$POP"; then check "static ground → precomputed" 0 1
else check "static ground → precomputed" 1 1; fi
ft_transition_cancel "$POP"
ft_anim_start "win$RUN_ID" 240 120 1 1
ft_transition_in "$POP" >/dev/null
ok "animating ground → live" ft_transition_live "$POP"
ft_transition_cancel "$POP"
ft_anim_stop "win$RUN_ID"

note "one easing solver: transitions use ft_ease, so cubic-bezier() and overshoot work"
# The private `case` this replaced knew five keywords and hand-rolled quadratics for them. It
# also aliased `ease` to ease-in-out, which is simply not what CSS's `ease` is.
ft_ease_table ease 11; check "ease is CSS's ease, not ease-in-out" "${FT_RET%% *}" 0
ft_ease_table ease 11; read -r -a _e <<< "$FT_RET"
check "…which is fast out of the gate (f1 > 60)" "$(( _e[1] > 60 ))" 1
ft_ease_table ease-in-out 11; read -r -a _e <<< "$FT_RET"
check "…and ease-in-out is not (f1 < 30)" "$(( _e[1] < 30 ))" 1
# AN OVERSHOOT CURVE RETURNS VALUES OUTSIDE 0..1000 ON PURPOSE, which is the whole reason
# channels are clamped in the blend: 38;2;-14;… is not a colour, and a frame carrying one
# would be emitted as literal text on the screen.
(( RUN_ID++ )); APP="app$RUN_ID"; POP="pop$RUN_ID"
ft_stylesheet name=gate style='.morph { transition: opacity 400ms cubic-bezier(0.34, 1.56, 0.64, 1); }'
ft-form name="$APP" width="$FT_COLS" height="$FT_ROWS"
    ft-frame name="w$RUN_ID" position=absolute left=2 top=1 width=70 height=20 title="S" \
             display=flex flexDirection=column gap=1
        ft-label name="q$RUN_ID" text="The quick brown fox jumps over the lazy dog"
    end_ft_frame
end_ft_form
FT_ROOT=$APP; ft_layout "$APP"; FT_OUT=""; _ft_redraw_walk "$APP"; FT_OUT=""
ft-frame name="$POP" class=morph position=absolute left=8 top=4 width=40 height=8 \
         title="Notice" backgroundColor=57 color=231 borderColor=213 parent="$APP"
    ft-label name="bod$RUN_ID" text="Overshoot." color=231
end_ft_frame
ft_layout "$APP"
ok "a cubic-bezier() shorthand arms" ft_transition_in "$POP"
precomputed_or_fail "overshoot"
ft_transition_frame_count "$POP"; ON=$FT_RET
# the curve is public: ask the solver, not the transition's own copy of the answer
ft_ease_table "cubic-bezier(0.34, 1.56, 0.64, 1)" "$ON"; read -r -a _oc <<< "$FT_RET"
over=0; for v in "${_oc[@]}"; do (( v > 1000 )) && over=1; done
check "the curve really does overshoot past 1000" "$over" 1
bad=0
for (( i=0; i<ON; i++ )); do
    frame_of "$i"
    case "$FT_RET" in *";-"*|*";2;-"*) bad=1 ;; esac
    case "$FT_RET" in *";256"*|*";3[0-9][0-9]m"*) bad=1 ;; esac
done
check "no frame carries an out-of-gamut channel" "$bad" 0
ground_bytes_for; OGROUND=$FT_RET
FILE="$work/ocut"
ft_transition_cut_frame "$POP"; frame_of "$FT_RET"
printf '%s%s' "$OGROUND" "$FT_RET" > "$FILE"
vis=0; inked=0
while IFS=$'\t' read -r pos glyph attrs; do
    [[ -z "$attrs" ]] && continue
    (( inked++ ))
    fg=${attrs#fg=}; fg=${fg%% *}
    bg=${attrs#*bg=}; bg=${bg%% *}
    [[ "$fg" != "$bg" ]] && (( vis++ ))
done < <(cells_in_rect "$RECT")
check "the cut is still invisible under an overshoot curve" "$vis" 0
check "…and there was something there to hide" "$(( inked > 50 ))" 1
finish

note "an application changes display, and that is the whole API"
# THE POINT OF THE FEATURE. No ft_transition_in, no ft_dirty, no ft_damage, no private name:
# a stylesheet says the control transitions, and `ft-modify display=block` makes it happen.
build contrast
ft-modify "$POP" display=none          # start from hidden, the demo's own initial state
FT_DIRTY=(); FT_DAMAGE=()
ft-modify "$POP" display=block
check "showing it does not arm before layout has settled" \
      "$(ft_transition_active "$POP" && echo armed || echo pending)" pending
ft_reflow_flush
ft_redraw_dirty                        # …the engine arms here, once the box is known
ok   "…and after the settle it is transitioning, with no app-side call" ft_transition_active "$POP"
ft_transition_frame_count "$POP"; check "…with real frames" "$(( FT_RET > 4 ))" 1
AUTOCUT=0; ft_transition_cut_frame "$POP"; AUTOCUT=$FT_RET
ground_bytes_for; AGR=$FT_RET
FILE="$work/autocut"
frame_of "$AUTOCUT"; printf '%s%s' "$AGR" "$FT_RET" > "$FILE"
vis=0
while IFS=$'\t' read -r pos glyph attrs; do
    [[ -z "$attrs" ]] && continue
    fg=${attrs#fg=}; fg=${fg%% *}; bg=${attrs#*bg=}; bg=${bg%% *}
    [[ "$fg" != "$bg" ]] && (( vis++ ))
done < <(cells_in_rect "$RECT")
check "…and it is a real transition — its cut is invisible" "$vis" 0

note "the SCREEN, not the buffer: every byte replayed into cells"
# WHY THIS IS WRITTEN THE HARD WAY, TWICE OVER.
#
# The first version of this section did:
#     BEFORE=$(_ft_redraw_walk app)  …show, tick, hide…  AFTER=$(_ft_redraw_walk app)
# Both sides are from-scratch walks of the same tree and the incremental paint's output is in
# neither, so it compared a render with itself and could not fail.
#
# The second version fixed the SHAPE — capture every byte (exec {FT_TTY}>file), replay it with
# tools/screen-cells.py, compare to a fresh render, the way tests/test-residue.bash does — and
# STILL could not fail: sabotaging the damage on hide, and corrupting the last transition
# frame, both passed. Two reasons, and they are worth knowing before trusting this file:
#   · hiding an absolutely-positioned control REFLOWS, and the reflow dirties the root form,
#     whose draw fills the screen. So the whole page repaints and no stale cell can survive to
#     the end state. `ft_damage_subtree` is therefore REDUNDANT IN THIS SHAPE — it is kept
#     because it is correct and because it stops being redundant the moment repair narrows,
#     but this test does not prove it does anything, and it should not claim to.
#   · an end-state comparison cannot see a bad MIDDLE frame at all: the transition retires,
#     the real control paints, and the end state is right however wrong the melt looked.
#
# So the assertion that bites is on the screen MID-TRANSITION, which is the only time the
# transition owns those cells and the only place its central claim is observable: at the cut
# frame, every inked cell in the region must have foreground == background. That goes through
# arming, the ground capture, the blend, the animation tick, compositing and ft_flush.
#
# THE TEETH, CHECKED RATHER THAN ASSUMED (seven deliberate sabotages, tools/, one at a time):
#   RED   the cut frame jumps to the top layer's foreground        → cut assertion fails
#   RED   the transition emits empty frames                        → cut assertion fails
#   green removing ft_draw_one's transition guard                  ─┐
#   green dropping the eased[cut]=500 snap                          │ the code is robust
#   green capturing the ground WITH the incoming control in it      │ against these; each is
#   green retire not re-dirtying at all                             │ still a real bug in
#   green retire dirtying the control but not its children         ─┘ some other shape
#
# The five greens are honest and worth naming. The snap one is green because the overshoot
# CLAMP (half < 0 → 0) independently forces fg == bg at the cut, so two mechanisms guarantee
# it. The last three are green because hiding or showing an absolutely-positioned control
# REFLOWS, the reflow dirties the root form, and the root's draw fills the screen — so the
# page repaints wholesale and no stale cell can reach the end state. That also means
# `ft_damage_subtree` on display:none is REDUNDANT IN THIS SHAPE. It is kept because it is
# correct and stops being redundant the moment repair narrows, but this test does not prove it
# does anything and must not claim to. The end-state comparisons below are kept as cheap
# regression cover, labelled as the weaker check they are.
stream_begin() { exec {FT_TTY}>"$work/stream"; }
stream_close() { exec {FT_TTY}>&-; exec {FT_TTY}>/dev/null; }
stream_vs_fresh() {             # label — the captured screen against a from-scratch render
    stream_close
    FT_OUT=""; _ft_redraw_walk "$APP" >/dev/null 2>&1; _ft_composite_overlays
    printf '%s' "$FT_OUT" > "$work/fresh"; FT_OUT=""
    local streamed fresh
    streamed=$(python3 tools/screen-cells.py "$work/stream" "$FT_ROWS" "$FT_COLS")
    fresh=$(python3 tools/screen-cells.py "$work/fresh" "$FT_ROWS" "$FT_COLS")
    # Nothing captured would compare equal to nothing rendered and pass for exactly the reason
    # the first version of this test passed. An empty stream is never a pass.
    if [[ -z "$streamed" ]]; then check "$1" "nothing was captured" "cells"; return; fi
    if [[ "$streamed" == "$fresh" ]]; then check "$1" 1 1
    else
        check "$1" 0 1
        diff <(printf '%s\n' "$fresh") <(printf '%s\n' "$streamed") | head -8 | sed 's/^/       /'
    fi
}

# ── the cut, on the real screen ──────────────────────────────────────────────
ft-modify "$POP" display=none; ft_reflow_flush; ft_redraw_dirty     # settle hidden, uncaptured
stream_begin
FT_OUT=""; _ft_redraw_walk "$APP"; _ft_composite_overlays; ft_flush          # opening frame
ft-modify "$POP" display=block
ft_reflow_flush
ft_redraw_dirty                                                     # arms; paints everything else
ok "showing it armed a transition, with no app-side call" ft_transition_active "$POP"
ft_transition_cut_frame "$POP"; CUT=$FT_RET
ft_transition_rect "$POP";      RECT=$FT_RET
# one tick per frame (the poll interval is this animation's frame time), so CUT+1 ticks lands
# the cut frame on the screen and stops there
for (( i=0; i<=CUT; i++ )); do ft_anim_step; done
ok "…and we stopped mid-flight, with the transition still running" ft_transition_active "$POP"
stream_close
FILE="$work/stream"
vis=0; inked=0
while IFS=$'\t' read -r pos glyph attrs; do
    [[ -z "$attrs" ]] && continue
    (( inked++ ))
    fg=${attrs#fg=}; fg=${fg%% *}
    bg=${attrs#*bg=}; bg=${bg%% *}
    [[ "$fg" != "$bg" ]] && (( vis++ ))
done < <(cells_in_rect "$RECT")
check "the region has ink on the real screen" "$(( inked > 50 ))" 1
check "…and at the cut frame not one glyph of it is legible" "$vis" 0

# ── the end states ───────────────────────────────────────────────────────────
# Weaker, as explained above: a root reflow repaints the page, so these mostly prove that
# nothing catastrophic happened. Kept because they are nearly free and they would catch a
# transition that never handed its cells back.
stream_begin
FT_OUT=""; _ft_redraw_walk "$APP"; _ft_composite_overlays; ft_flush
spin=0
while ft_transition_active "$POP" && (( spin < 60 )); do ft_anim_step; (( spin++ )); done
no "the transition retired on its own" ft_transition_active "$POP"
stream_vs_fresh "when it finishes, the streamed screen equals a fresh render"

ft-modify "$POP" display=none; ft_reflow_flush; ft_redraw_dirty     # settle hidden, uncaptured
stream_begin
FT_OUT=""; _ft_redraw_walk "$APP"; _ft_composite_overlays; ft_flush
ft-modify "$POP" display=block; ft_reflow_flush; ft_redraw_dirty
ok "it is up again" ft_transition_active "$POP"
ft_anim_step; ft_anim_step; ft_anim_step        # a few blended frames really land on screen
FT_DAMAGE=()
ft-modify "$POP" display=none                   # …pulled away MID-FLIGHT
check "hiding cancels the transition, unasked" \
      "$(ft_transition_active "$POP" && echo still-running || echo stopped)" stopped
check "…and damages the cells it owned" "$(( ${#FT_DAMAGE[@]} > 0 ))" 1
ft_reflow_flush; ft_redraw_dirty
stream_vs_fresh "after hiding, the streamed screen equals a fresh render without it"
finish

note "ft_transition_in never silently does nothing"
# It used to return 1 when the cascade asked for no transition, which pushed `|| ft_dirty` onto
# every call site: forget the `||` and the control simply never appeared.
(( RUN_ID++ )); APP="app$RUN_ID"; POP="pop$RUN_ID"
ft_stylesheet name=gate style='.morph { transition: none; }'
ft-form name="$APP" width="$FT_COLS" height="$FT_ROWS"
    ft-label name="pl$RUN_ID" text="under"
end_ft_form
FT_ROOT=$APP; ft_layout "$APP"
ft-frame name="$POP" class=morph position=absolute left=4 top=4 width=20 height=4 parent="$APP"
    ft-label name="pb$RUN_ID" text="plain"
end_ft_frame
ft_layout "$APP"
FT_DIRTY=()
ok "it succeeds even when the cascade says no transition" ft_transition_in "$POP"
no "…without arming one" ft_transition_active "$POP"
check "…and the control is queued to paint anyway" "${FT_DIRTY[$POP]:-0}" 1
check "…children too, so a frame does not appear empty" "${FT_DIRTY[pb$RUN_ID]:-0}" 1

note "the demo, driven in a real pty"
demo_screen=$(FT_TEST_COLS=100 FT_TEST_ROWS=34 FT_TEST_QUITKEY= \
    timeout 60 python3 tests/render-screen.py demo/transition-demo.bash 'r 3.0' 2>/dev/null)
check "the demo rendered something" "$(( ${#demo_screen} > 200 ))" 1
for want in "ease-in-out 420ms" "ease-out 260ms" "linear 900ms" "overshoot 480ms" \
            "Ordinary. Symmetric." "Quick off the mark" "Slow and even" "sails past"; do
    case "$demo_screen" in
        *"$want"*) check "the finished notice shows: $want" 1 1 ;;
        *)         check "the finished notice shows: $want" 0 1 ;;
    esac
done
case "$demo_screen" in
    *"schedule: contrast"*) check "the demo reports what it measured" 1 1 ;;
    *)                      check "the demo reports what it measured" 0 1 ;;
esac
# Nothing may leak raw escapes onto the screen — the classic symptom of a frame whose SGR
# was built wrong.
leaked=$(printf '%s\n' "$demo_screen" | grep -cE '\[[0-9;]+m')
check "no escape sequences leaked as text" "$leaked" 0

summary
