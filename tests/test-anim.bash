#!/usr/bin/env bash
# Tests for the animation engine (ft-forms.bash) and the animations built on it:
# the status bar's attention sweep, and a text field's two border animations —
# `beacon` (a wave of thickness, opt-in) and `sheen` (a subtle diagonal tone
# gradient + glow, the default active state). Covers the tick registry, per-animation
# pacing, the `animation=` property dispatch, the scrollbar handling, and cut-on-leave.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=80; FT_ROWS=24

_anim_reset() { FT_ANIM_PHASE=(); FT_ANIM_LENGTH=(); FT_ANIM_ACTIVE=0; }
_sb_reset()   { _anim_reset; FT_STATUSBAR_LAST_SYNOPSIS=(); }   # also forget the bar's last synopsis
_phase() { ft_anim_phase "$1"; echo "$FT_RET"; }
# Build the sheen ramps from 256 INDICES (the ramps now take rgb, since a theme may
# use a truecolor shade no index can name).
_ramps_idx() {  # accentidx bgidx depth glow
    ft_256_to_rgb "$1"; local ar=$FT_RGB_RED ag=$FT_RGB_GREEN ab=$FT_RGB_BLUE
    ft_256_to_rgb "$2"; local br=$FT_RGB_RED bg=$FT_RGB_GREEN bb=$FT_RGB_BLUE
    _ft_sheen_ramps "$ar" "$ag" "$ab" "$br" "$bg" "$bb" "$3" "$4" "$_FT_SHEEN_TONE_STEPS_DEFAULT"
}
# The FT_OUT chunk painted at screen cell (y,x): from its cursor-address to the next
# 48 bytes (SGR + glyph). Two cells with different tone yield different chunks.
_cellwin() { local a=$'\e['$(( $1 + 1 ))';'$(( $2 + 1 ))'H' r; r=${FT_OUT##*"$a"}
             [[ "$r" == "$FT_OUT" ]] && { FT_RET=""; return 1; }; FT_RET=${r:0:48}; }

note "the tick registry: start, advance one frame per tick, self-retire"
ft-form name=root width=80 height=6
  ft-statusbar name=bar status="Ready."
end_ft_form
ft_layout root
# Prime the bar's first paint: an unpainted bar sweeps itself the moment anything
# draws it, which would re-arm the registry underneath these assertions.
FT_OUT=""; _ft_draw_statusbar bar
_anim_reset                     # clear the registry but KEEP the bar primed

ft_anim_start bar $(( 3 * FT_ANIM_SPEED ))
check "starting an animation makes the loop poll fast" "$FT_ANIM_ACTIVE" "1"
check "a fresh animation opens at phase 0" "$(_phase bar)" "0"
ft_anim_step; check "one tick advances FT_ANIM_SPEED cells" "$(_phase bar)" "$FT_ANIM_SPEED"
ft_anim_step; check "and it keeps counting"   "$(_phase bar)" "$(( 2 * FT_ANIM_SPEED ))"
ft_anim_step
check "the last frame retires the animation"  "$(_phase bar)" "-1"
check "...and the loop drops back to the lazy poll" "$FT_ANIM_ACTIVE" "0"

note "a LOOPing animation wraps forever instead of retiring"
_anim_reset
ft_anim_start bar 10 20 4 1          # len=10, step=4, loop
ft_anim_step; check "phase 4"  "$(_phase bar)" "4"
ft_anim_step; check "phase 8"  "$(_phase bar)" "8"
ft_anim_step; check "12 wraps to 2 — the ring has no end" "$(_phase bar)" "2"
ok "a looping animation never retires on its own" test "$FT_ANIM_ACTIVE" -eq 1
ft_anim_stop bar
check "only an explicit stop ends it" "$FT_ANIM_ACTIVE" "0"

note "PERSISTENT phase: an effect can freeze on a frame and resume there on the next event"
_anim_reset                            # (leaves FT_ANIM_KEEP alone — that is the point)
ft_anim_start bar 100 20 4 1; ft_anim_step; ft_anim_step; ft_anim_step   # advance to 12
check "phase advanced to 12"                 "$(_phase bar)" "12"
ft_anim_stop bar                       # STOP mid-flight — the phase is remembered
check "stop remembers the phase"             "${FT_ANIM_KEEP[bar]}" "12"
ft_anim_resume bar 100 20 4 1
check "resume continues where it froze"      "$(_phase bar)" "12"
ft_anim_stop bar
ft_anim_start bar 100 20 4 1
check "a plain start still resets to 0"      "$(_phase bar)" "0"
ft_anim_stop bar
ft_anim_start bar 100 20 4 1 40        # explicit start_phase
check "an explicit start_phase seeds the frame" "$(_phase bar)" "40"
ft_anim_phase_set bar 8                 # drive the live phase directly
check "ft_anim_phase_set jumps the live phase"  "$(_phase bar)" "8"
ft_anim_stop bar
ft_anim_resume bar 100 20 4 1
check "the set phase is what resume restores"   "$(_phase bar)" "8"
ft_anim_stop bar
_anim_reset

note "each animation keeps its OWN pace; the poll runs at the fastest one's need"
_anim_reset
ft_anim_start bar 1000 100 1 1       # a slow, ambient 100ms animation
check "the poll follows the only animation" "$FT_ANIM_POLL_MS" "100"
check "...expressed as read -t seconds"     "$FT_ANIM_INTERVAL" "0.100"
ft_anim_step; check "one 100ms poll = one frame for it" "$(_phase bar)" "1"
# Add a fast one: the poll must speed up, and the slow one must NOT speed up with it.
ft-form name=root2 width=80 height=6
  ft-statusbar name=bar2 status="Other."
end_ft_form
ft_layout root2
FT_OUT=""; _ft_draw_statusbar bar2      # prime it: an unpainted bar re-arms itself
ft_anim_start bar2 1000 20 1 1
check "the poll drops to the fastest animation's need" "$FT_ANIM_POLL_MS" "20"
p0=$(_phase bar)
ft_anim_step; ft_anim_step; ft_anim_step; ft_anim_step   # 4 x 20ms = 80ms < 100ms
check "the fast one advanced 4 frames" "$(_phase bar2)" "4"
check "the slow one did NOT — it skips ticks, it is not dragged along" "$(_phase bar)" "$p0"
ft_anim_step                                             # 100ms reached
check "...and it advances on ITS interval" "$(_phase bar)" "$(( p0 + 1 ))"
ft_anim_stop bar; ft_anim_stop bar2

note "ft_anim_start refuses a control that does not exist"
_sb_reset
no "phantom control rejected" ft_anim_start nosuchcontrol 10
check "a phantom control never enters the registry" "$FT_ANIM_ACTIVE" "0"

note "a control destroyed mid-flight never leaves an animation ticking forever"
_sb_reset
ft_anim_start bar 999
saved=${FT_TYPE[bar]}; unset "FT_TYPE[bar]"      # the control goes away underneath it
ft_anim_step
check "step reaped the animation of a dead control" "$FT_ANIM_ACTIVE" "0"
FT_TYPE[bar]=$saved

note "status bar: a CHANGED synopsis sweeps; an unchanged one must not re-sweep"
_sb_reset
FT_OUT=""; _ft_draw_statusbar bar
ok "the first paint announces itself" test "$(_phase bar)" -ge 0
ft_anim_stop bar
FT_OUT=""; _ft_draw_statusbar bar
check "an unchanged synopsis does not re-sweep (or it would never stop)" "$(_phase bar)" "-1"
ft_set bar status="Saving report.txt…"
FT_OUT=""; _ft_draw_statusbar bar
ok "a new synopsis sweeps again" test "$(_phase bar)" -ge 0

note "the sweep bolds a moving WINDOW of the synopsis, and closes it again"
_sb_reset
FT_OUT=""; _ft_draw_statusbar bar          # registers the sweep
FT_ANIM_PHASE[bar]=12
FT_OUT=""; _ft_draw_statusbar bar
[[ "$FT_OUT" == *$'\e[1m'* ]]  && check "mid-sweep paint contains bold" 1 1 \
                               || check "mid-sweep paint contains bold" 0 1
[[ "$FT_OUT" == *$'\e[22m'* ]] && check "the crest is a WINDOW, not an endless tail" 1 1 \
                               || check "the crest is a WINDOW, not an endless tail" 0 1
ft_anim_stop bar
FT_OUT=""; _ft_draw_statusbar bar
[[ "$FT_OUT" == *$'\e[1m'* ]]  && check "a finished sweep leaves no bold behind" 0 1 \
                               || check "a finished sweep leaves no bold behind" 1 1

note "the sweep width is a PROPERTY, not a hardcoded constant"
_sb_reset
ft_set bar status="ab        cd"
FT_OUT=""; _ft_draw_statusbar bar
check "sweep sized to full row + the DEFAULT crest width" \
      "${FT_ANIM_LENGTH[bar]}" "$(( FT_MEASURED_WIDTH[bar] + _FT_STATUSBAR_SWEEP_WIDTH_DEFAULT ))"
ok "the default crest survives its per-frame step" test "$_FT_STATUSBAR_SWEEP_WIDTH_DEFAULT" -ge "$FT_ANIM_SPEED"
_sb_reset
ft_set bar sweepWidth=20 status="changed again"
FT_OUT=""; _ft_draw_statusbar bar
check "sweepWidth= overrides it per instance" "${FT_ANIM_LENGTH[bar]}" "$(( FT_MEASURED_WIDTH[bar] + 20 ))"

# ── the two field animations, selected by the `animation` property ────────────
ft_reset_tree 2>/dev/null || true
ft-form name=app width=40 height=14
  ft-textfield name=def   value="hello" activateBorderAnimation=sheen
  ft-textfield name=bcn   value="hello" activateBorderAnimation=beacon
  ft-textfield name=off   value="hello" activateBorderAnimation=none
  ft-textfield name=plain value="hello"
end_ft_form
ft_layout app

note "a field's active animation is the \`animation\` property (the calm sheen by default)"
_ft_border_anim_name plain; check "unset → the default sheen (an active field breathes)" "$FT_RET" "sheen"
_ft_border_anim_name def; check "activateBorderAnimation=sheen selects the calm gradient" "$FT_RET" "sheen"
_ft_border_anim_name bcn; check "activateBorderAnimation=beacon selects beacon" "$FT_RET" "beacon"
_ft_border_anim_name off; check "activateBorderAnimation=none → no animation" "$FT_RET" ""

_anim_reset
ft_focus off; check "focus alone starts nothing" "$(_phase off)" "-1"
ft_textfield_activate off
check "activateBorderAnimation=none stays silent even when active" "$(_phase off)" "-1"
ft_textfield_deactivate off

note "activate binds the routine + structure + typing debounce to the engine"
_anim_reset
ft_set def activateAnimationTypingDelay=2
ft_focus def; ft_textfield_activate def
check "the frame routine is bound"           "${FT_ANIM_FRAME[def]}"   "_ft_banim_sheen_frame"
check "...with the STRUCTURE it operates on"  "${FT_ANIM_STRUCT[def]}"  "border"
check "...and a 2-second typing debounce (ms)" "${FT_ANIM_DEBOUNCE[def]}" "2000"

note "typing-debounce: the border FREEZES while you type, resumes after the quiet delay"
p0=$(_phase def)
ft_now_ms; FT_LAST_INPUT_MS=$FT_RET          # "just typed"
FT_ANIM_ACCUMULATED_MS[def]=9999                         # otherwise this frame is due
ft_anim_step
check "just typed → the animation holds still (no per-keystroke flicker)" "$(_phase def)" "$p0"
FT_LAST_INPUT_MS=0                            # last input long ago → past the delay
FT_ANIM_ACCUMULATED_MS[def]=9999
ft_anim_step
ok "once quiet for the delay, it advances again" test "$(_phase def)" -gt "$p0"

note "the engine forwards (instance, structure) to the routine — no hand-forwarding"
_probe_is="" _probe_st=""
_banim_probe_frame() { _probe_is=$1; _probe_st=$2; }
FT_ANIM_FRAME[def]=_banim_probe_frame; FT_LAST_INPUT_MS=0; FT_ANIM_ACCUMULATED_MS[def]=9999; ft_anim_step
check "routine received the instance"  "$_probe_is" "def"
check "routine received the structure" "$_probe_st" "border"
ft_anim_stop def

note "TWO-PHASE: a HOLD structure animates DURING the typing window, the main after it"
# The glow (structure "borderGlow") shows the instant you activate and stays put while
# you type — the SAME routine, told to render a different structure. Once you pause,
# the engine switches to the main structure ("border") and the phase advances.
_anim_reset
_2p_seen=""
_banim_2p_frame() { _2p_seen=$2; }
ft_anim_start def 100 20 1 1
ft_anim_bind  def _banim_2p_frame border 2000 borderGlow    # main=border, hold=borderGlow
p0=$(_phase def)
ft_now_ms; FT_LAST_INPUT_MS=$FT_RET; FT_ANIM_ACCUMULATED_MS[def]=9999; ft_anim_step   # just typed → HOLD
check "within the typing window the HOLD structure is painted" "$_2p_seen" "borderGlow"
check "...and the main phase is held (not advanced)" "$(_phase def)" "$p0"
FT_LAST_INPUT_MS=0; FT_ANIM_ACCUMULATED_MS[def]=9999; ft_anim_step                    # quiet → MAIN
check "after the delay the MAIN structure is painted" "$_2p_seen" "border"
ok "...and now the phase advances" test "$(_phase def)" -gt "$p0"
ft_anim_stop def

note "beacon: entering the field circles crests of THICKNESS around the border"
_anim_reset
ft_focus bcn; check "merely focusing does not animate" "$(_phase bcn)" "-1"
ft_textfield_activate bcn
ok "entering starts the beacon" test "$(_phase bcn)" -ge 0
_ft_anim_beacon_params bcn
w=${FT_MEASURED_WIDTH[bcn]}; h=${FT_MEASURED_HEIGHT[bcn]}
_ft_textfield_wave_geom "$h" "$w" "$BEACON_CRESTS"
check "the perimeter is the box's four sides, corners counted once" \
      "$FT_TEXTFIELD_WAVE_PERIMETER" "$(( 2*w + 2*h - 4 ))"
check "the run is exactly one lap and WRAPS (it plays while you're in there)" \
      "${FT_ANIM_LENGTH[bcn]}" "$FT_TEXTFIELD_WAVE_PERIMETER"
check "...so it loops" "${FT_ANIM_LOOP[bcn]}" "1"
check "...at the beacon's own rate" "${FT_ANIM_FRAME_MS[bcn]}" "$BEACON_RATE"
ok "a crest is never narrower than its step (or it would strobe)" \
   test "$BEACON_CREST" -ge "$BEACON_STEP"
ok "more than one crest circles at once" test "$BEACON_CRESTS" -gt 1

note "beacon crests are heavy box glyphs, and only a small fraction is lit"
_heavy() { printf '%s' "$1" | grep -o $'\xe2\x94\x81\|\xe2\x94\x83\|\xe2\x94\x8f\|\xe2\x94\x93\|\xe2\x94\x97\|\xe2\x94\x9b\|\xe2\x96\x89' | wc -l; }
FT_ANIM_PHASE[bcn]=0
FT_OUT=""; ft_draw_one bcn
check "all crests are on the ring even at phase 0 (a loop has no ends)" \
      "$(_heavy "$FT_OUT")" "$(( BEACON_CRESTS * BEACON_CREST ))"
lit=$(( BEACON_CRESTS * BEACON_CREST ))
ok "under a third of the perimeter is lit at any moment" test "$(( lit * 3 ))" -lt "$FT_TEXTFIELD_WAVE_PERIMETER"
ft_anim_stop bcn
FT_OUT=""; ft_draw_one bcn
case "$FT_OUT" in
  *$'\xe2\x94\x81'*|*$'\xe2\x94\x83'*) check "a stopped beacon leaves the border thin" 0 1 ;;
  *)                                   check "a stopped beacon leaves the border thin" 1 1 ;;
esac

note "beacon crest tunables are PROPERTIES, honoured per instance"
ft_reset_tree 2>/dev/null || true
ft-form name=appb width=40 height=6
  ft-textfield name=b2 value="x" activateBorderAnimation=beacon borderAnimationCrests=2 borderAnimationCrest=5
end_ft_form
ft_layout appb
_ft_anim_beacon_params b2
check "beaconCrests= read back" "$BEACON_CRESTS" "2"
check "beaconCrest= read back"  "$BEACON_CREST"  "5"

note "beacon on a VERTICAL scrollbar rides the thumb; never stamps a box glyph on it"
ft_reset_tree 2>/dev/null || true
long=""; for i in $(seq 1 40); do long+="line $i of text to force a vertical scrollbar"$'\n'; done
ft-form name=appv width=40 height=12
  ft-textfield name=big value="$long" activateBorderAnimation=beacon size=30 rows=8
end_ft_form
ft_layout appv
_anim_reset
ft_focus big; ft_textfield_activate big
FT_OUT=""; ft_draw_one big
ok "the field grew a vertical scrollbar" test -n "${FT_TEXTFIELD_VBAR[big]:-}"
vb=(${FT_TEXTFIELD_VBAR[big]}); vx=${vb[0]}; vy0=${vb[1]}; vy1=${vb[2]}
_ft_anim_beacon_params big
_ft_textfield_wave_geom "${FT_MEASURED_HEIGHT[big]}" "${FT_MEASURED_WIDTH[big]}" "$BEACON_CRESTS"
bad=0; rode=0
for (( p=0; p<FT_TEXTFIELD_WAVE_PERIMETER; p++ )); do
    FT_ANIM_PHASE[big]=$p
    FT_OUT=""; ft_draw_one big
    for (( yy=vy0; yy<=vy1; yy++ )); do
        _cellwin "$yy" "$vx" || continue
        case "$FT_RET" in
            *$'\xe2\x94\x81'*|*$'\xe2\x94\x83'*|*$'\xe2\x94\x8f'*|*$'\xe2\x94\x93'*|*$'\xe2\x94\x97'*|*$'\xe2\x94\x9b'*) bad=1 ;;
        esac
        case "$FT_RET" in *$'\xe2\x96\x89'*) rode=1 ;; esac    # ▉ = thumb thickened
    done
done
check "no box-drawing glyph is ever stamped onto the vertical thumb" "$bad" "0"
check "the crest visibly thickens the vertical thumb (▊→▉)" "$rode" "1"

note "beacon on a HORIZONTAL scrollbar PASSES THROUGH — no █ blob below the bar"
# The fix: ▀→█ grew downward past the bar in the wrong colour. Now the crest paints
# the same heavy ━ as the rest of the bottom edge and the ▀ re-emerges behind it.
ft_reset_tree 2>/dev/null || true
wide="a very long single line that overflows the field horizontally for sure yes"
ft-form name=apph width=30 height=6
  ft-textfield name=hf value="$wide" activateBorderAnimation=beacon size=16
end_ft_form
ft_layout apph
_anim_reset
ft_focus hf; ft_textfield_activate hf
FT_OUT=""; ft_draw_one hf
ok "the field grew a horizontal scrollbar" test -n "${FT_TEXTFIELD_HBAR[hf]:-}"
hb=(${FT_TEXTFIELD_HBAR[hf]}); hy=${hb[0]}; hx0=${hb[1]}; hx1=${hb[2]}
_ft_anim_beacon_params hf
_ft_textfield_wave_geom "${FT_MEASURED_HEIGHT[hf]}" "${FT_MEASURED_WIDTH[hf]}" "$BEACON_CRESTS"
blob=0; through=0
for (( p=0; p<FT_TEXTFIELD_WAVE_PERIMETER; p++ )); do
    FT_ANIM_PHASE[hf]=$p
    FT_OUT=""; ft_draw_one hf
    for (( xx=hx0; xx<=hx1; xx++ )); do
        _cellwin "$hy" "$xx" || continue
        case "$FT_RET" in *$'\xe2\x96\x88'*) blob=1 ;; esac   # █ full block = the old bug
        case "$FT_RET" in *$'\xe2\x94\x81'*) through=1 ;; esac # ━ heavy border = passing through
    done
done
check "the full-block blob (█) never appears on the horizontal bar" "$blob" "0"
check "the crest passes through as heavy border (━) instead" "$through" "1"

note "sheen: entering starts a SUBTLE gradient — no thickness anywhere"
ft_reset_tree 2>/dev/null || true
ft-form name=apps width=30 height=6
  ft-textfield name=sf value="hello" activateBorderAnimation=sheen
end_ft_form
ft_layout apps
_anim_reset
ft_focus sf; ft_textfield_activate sf
ok "entering starts the sheen (the default)" test "$(_phase sf)" -ge 0
check "...and it loops" "${FT_ANIM_LOOP[sf]}" "1"
ok "...slower than the status bar's one-shot sweep" test "${FT_ANIM_FRAME_MS[sf]}" -gt "$FT_ANIM_FRAME_MS_DEFAULT"
FT_ANIM_PHASE[sf]=0
FT_OUT=""; ft_draw_one sf
case "$FT_OUT" in
  *$'\xe2\x94\x81'*|*$'\xe2\x94\x83'*|*$'\xe2\x94\x8f'*|*$'\xe2\x94\x93'*|*$'\xe2\x94\x97'*|*$'\xe2\x94\x9b'*|*$'\xe2\x96\x89'*|*$'\xe2\x96\x88'*)
      check "sheen NEVER thickens a glyph (no fatness at all)" 0 1 ;;
  *)  check "sheen NEVER thickens a glyph (no fatness at all)" 1 1 ;;
esac
case "$FT_OUT" in *$'\e[1m'*) check "sheen uses no bold either" 0 1 ;;
                  *)          check "sheen uses no bold either" 1 1 ;; esac

note "the sheen ramps: a foreground TONE ramp and a background GLOW ramp"
_cm=$FT_COLOR_MODE; FT_COLOR_MODE=truecolor      # exact shades, so distinctness is deterministic
_ramps_idx 39 234 14 16                          # accent azure over the dark border bg
check "the foreground ramp has one entry per tone step" "${#FT_SHEEN_FOREGROUND[@]}" "$_FT_SHEEN_TONE_STEPS_DEFAULT"
check "the background ramp matches it" "${#FT_SHEEN_BACKGROUND[@]}" "$_FT_SHEEN_TONE_STEPS_DEFAULT"
ok "the tone actually varies (dark end ≠ bright end)" test "${FT_SHEEN_FOREGROUND[0]}" != "${FT_SHEEN_FOREGROUND[$((_FT_SHEEN_TONE_STEPS_DEFAULT-1))]}"
ok "the glow actually varies (no tint ≠ most tint)"    test "${FT_SHEEN_BACKGROUND[0]}" != "${FT_SHEEN_BACKGROUND[$((_FT_SHEEN_TONE_STEPS_DEFAULT-1))]}"
# The zero-glow end is the border's own background untouched; the far end is mixed.
ft_256_to_rgb 234; ft_rgb_sgr "$FT_RGB_RED" "$FT_RGB_GREEN" "$FT_RGB_BLUE" 48
check "the glow starts from the border's own background (no tint at the trough)" "${FT_SHEEN_BACKGROUND[0]}" "$FT_RET"
# The glow colour bleeds toward the ACCENT (the state colour), so its crest is not
# the plain background — how MUCH is the theme's FT_SHEEN_GLOW.
ok "the glow crest carries accent colour (it is not the bare background)" \
   test "${FT_SHEEN_BACKGROUND[$((_FT_SHEEN_TONE_STEPS_DEFAULT-1))]}" != "$FT_RET"

note "numberOfTones is a PROPERTY now, not the _FT_SHEEN_N global — per-instance"
ft_reset_tree 2>/dev/null || true
ft-form name=appn width=30 height=6
  ft-textfield name=nf value="hi" numberOfTones=12 activateBorderAnimation=sheen
end_ft_form
ft_layout appn; ft_focus nf; ft_textfield_activate nf
FT_SHEEN_LIT_CELL=(); _FT_SHEEN_SIGNATURE=""; FT_OUT=""
_ft_anim_sheen_paint nf "${FT_ABSOLUTE_Y[nf]}" "${FT_ABSOLUTE_X[nf]}" "${FT_MEASURED_HEIGHT[nf]}" "${FT_MEASURED_WIDTH[nf]}" 0 1
check "the sheen builds exactly numberOfTones ramp steps" "${#FT_SHEEN_FOREGROUND[@]}" "12"
FT_COLOR_MODE=$_cm

note "the sheen reads a border colour whether it is a 256 index OR truecolor rgb"
# A theme may need a shade the 256 cube can't name (a dark WARM grey), so it sets a
# truecolor 48;2;r;g;b background. The sheen must read that, not silently switch off.
ft_sgr_rgb $'\e[48;2;52;45;37m\e[38;5;66m' 48
check "truecolor bg → r" "$FT_RGB_RED" "52"; check "truecolor bg → g" "$FT_RGB_GREEN" "45"; check "truecolor bg → b" "$FT_RGB_BLUE" "37"
ft_sgr_rgb $'\e[48;5;234;38;5;51m' 38; a_r=$FT_RGB_RED; ft_256_to_rgb 51
check "256 fg parses to the index's own rgb" "$a_r" "$FT_RGB_RED"
no "an absent channel returns failure" ft_sgr_rgb $'\e[38;5;51m' 48

note "the coloured-glow strength is a THEME variable, not a baked-in constant"
ft_setup_palette
ok "the dark theme defines a glow strength"   test -n "$FT_SHEEN_GLOW"
check "...at the tuned dark value" "$FT_SHEEN_GLOW" "18"

note "sheen is DIAGONAL: top and bottom edges are out of phase"
_cm=$FT_COLOR_MODE; FT_COLOR_MODE=truecolor
row=${FT_ABSOLUTE_Y[sf]}; col=${FT_ABSOLUTE_X[sf]}; rows=${FT_MEASURED_HEIGHT[sf]}; cols=${FT_MEASURED_WIDTH[sf]}
diag=0
FT_OUT=""; _ft_anim_sheen_paint sf "$row" "$col" "$rows" "$cols" 0
for (( xx=col+2; xx<col+cols-2; xx++ )); do
    _cellwin "$row" "$xx"; t=$FT_RET
    _cellwin "$(( row + rows - 1 ))" "$xx"; b=$FT_RET
    [[ -n "$t" && -n "$b" && "$t" != "$b" ]] && { diag=1; break; }
done
check "some column shows a different tone on the top edge than the bottom" "$diag" "1"

note "sheen MOVES: a fixed border cell changes tone as the phase advances"
FT_OUT=""; _ft_anim_sheen_paint sf "$row" "$col" "$rows" "$cols" 0; _cellwin "$row" "$(( col+3 ))"; a=$FT_RET
FT_OUT=""; _ft_anim_sheen_paint sf "$row" "$col" "$rows" "$cols" 4; _cellwin "$row" "$(( col+3 ))"; b=$FT_RET
ok "the same cell is painted differently at a later phase" test "$a" != "$b"
FT_COLOR_MODE=$_cm

note "sheen INTEGRATES the scrollbars — the thumb rides the sweep, not sits across it"
_cm=$FT_COLOR_MODE; FT_COLOR_MODE=truecolor
ft_reset_tree 2>/dev/null || true
ft-form name=apps2 width=40 height=12
  ft-textfield name=vs value="$long" size=30 rows=8 activateBorderAnimation=sheen
end_ft_form
ft_layout apps2
ft_focus vs; ft_textfield_activate vs
FT_ANIM_PHASE[vs]=4; FT_OUT=""; ft_draw_one vs         # draws body + scrollbar, publishes VBAR
vb2=(${FT_TEXTFIELD_VBAR[vs]}); vx2=${vb2[0]}; vy0b=${vb2[1]}
# Isolate a fresh sheen paint: the draw's frozen-frame overlay already primed the diff
# cache, so clear it and let the frame repaint the whole ring — it must ride the thumb.
unset "FT_SHEEN_LIT_CELL[vs]"
FT_OUT=""; _ft_banim_sheen_frame vs border
_cellwin "$vy0b" "$vx2"
[[ "$FT_RET" == *"38;2;"* ]]        && check "the thumb is painted by the sheen gradient" 1 1 \
                                    || check "the thumb is painted by the sheen gradient" 0 1
[[ "$FT_RET" == *$'\xe2\x96\x8a'* ]] && check "...and still shows the ▊ thumb glyph (reads as a bar)" 1 1 \
                                    || check "...and still shows the ▊ thumb glyph (reads as a bar)" 0 1
FT_COLOR_MODE=$_cm

note "a full DRAW paints the FROZEN sheen frame — the glow can't flicker off while navigating"
# The border freezes on its current frame while you move the caret (the debounce holds
# the phase); so every full draw must put that frozen frame back, or the glow strobes
# off on each keystroke. To keep that cheap, the frame is rendered ONCE and its bytes
# cached — a redraw at the same phase blits the cache instead of recomputing the ring.
_cm=$FT_COLOR_MODE; FT_COLOR_MODE=truecolor
ft_reset_tree 2>/dev/null || true
ft-form name=appk width=30 height=6
  ft-textfield name=kf value="hello" activateBorderAnimation=sheen
end_ft_form
ft_layout appk
ft_focus kf; ft_textfield_activate kf
FT_ANIM_PHASE[kf]=3; FT_OUT=""; ft_draw_one kf
case "$FT_OUT" in *"48;2;"*) check "the active field's draw paints the sheen ring" 1 1 ;;
                  *)          check "the active field's draw paints the sheen ring" 0 1 ;; esac
[[ -n "${FT_SHEEN_FROZEN[kf]:-}" ]] && check "...and caches the frozen frame" 1 1 \
                                    || check "...and caches the frozen frame" 0 1
FT_OUT=""; ft_draw_one kf                           # redraw at the SAME phase → served from cache
case "$FT_OUT" in *"48;2;"*) check "a same-phase redraw keeps the sheen lit (no flicker to plain)" 1 1 ;;
                  *)          check "a same-phase redraw keeps the sheen lit (no flicker to plain)" 0 1 ;; esac
# a phase advance (the delay elapsed) invalidates the cache so the border resumes moving
FT_ANIM_PHASE[kf]=7; FT_OUT=""; ft_draw_one kf
[[ "${FT_SHEEN_FROZEN_SIGNATURE[kf]}" == 7\|* ]] && check "a phase advance re-renders the frozen frame" 1 1 \
                                           || check "a phase advance re-renders the frozen frame" 0 1
FT_COLOR_MODE=$_cm

note "the scrollbar thumb wears the border's ACTIVE-STATE colour, not a fixed azure"
# A NON-animated (activateBorderAnimation=none) editing field: its GOLD border (FT_COLOR_TEXT_NOTICE =
# 38;5;220) and its scrollbar must match — the thumb used to be hardwired azure (39).
ft_reset_tree 2>/dev/null || true
ft-form name=appc width=40 height=12
  ft-textfield name=cf value="$long" size=30 rows=8 activateBorderAnimation=none
end_ft_form
ft_layout appc
ft_focus cf; ft_textfield_activate cf                  # editable field → editing → gold
check "the activated field is in editing mode" "$(ft_get cf runlevel; printf %s "$FT_RET")" "editing"
FT_OUT=""; ft_draw_one cf
cvb=(${FT_TEXTFIELD_VBAR[cf]}); cvx=${cvb[0]}; cvy0=${cvb[1]}
check "the scrollbar published its geometry" "$([[ -n "$cvx" && -n "$cvy0" ]] && echo yes)" yes
# Read the attributes IN EFFECT AT the thumb glyph, rather than assuming the thumb is addressed
# as its own write: a textarea now paints the border column as part of its row (one paint call
# instead of two), so there is no cursor-address at the thumb's own column any more. What this
# test is about — the colour the thumb ends up wearing — is unchanged either way.
_thumb_sgr=""; _vthumb=$'\xe2\x96\x8a'; (( FT_USE_UTF8 )) || _vthumb='|'
if [[ "$FT_OUT" == *"$_vthumb"* ]]; then _thumb_sgr=${FT_OUT%%"$_vthumb"*}; _thumb_sgr=${_thumb_sgr: -48}; fi
[[ "$_thumb_sgr" == *"38;5;220"* ]] && check "thumb is painted gold, matching the editing border" 1 1 \
                                    || check "thumb is painted gold, matching the editing border" 0 1
[[ "$_thumb_sgr" == *"38;5;39"* ]]  && check "thumb is NOT the old fixed azure" 0 1 \
                                    || check "thumb is NOT the old fixed azure" 1 1

note "sheen reads the THEME: brighten on a dark bg, DARKEN (a shadow) on a light bg"
_cm=$FT_COLOR_MODE; FT_COLOR_MODE=truecolor
_lum_of() { local rgb=$(printf '%s' "$1" | sed -E 's/.*38;2;([0-9]+;[0-9]+;[0-9]+).*/\1/'); local r g b
            IFS=';' read -r r g b <<<"$rgb"; echo $(( (30*r+59*g+11*b)/100 )); }
ft_256_to_rgb 234; bgd=$(( (30*FT_RGB_RED+59*FT_RGB_GREEN+11*FT_RGB_BLUE)/100 ))   # dark theme bg luminance
_ramps_idx 39 234 150 18                                       # azure accent on dark bg
dt=$(_lum_of "${FT_SHEEN_FOREGROUND[0]}"); dc=$(_lum_of "${FT_SHEEN_FOREGROUND[$((_FT_SHEEN_TONE_STEPS_DEFAULT-1))]}")
ok "dark bg → crest BRIGHTER than trough" test "$dc" -gt "$dt"
ok "dark bg → even the trough stays above the background (no hole)" test "$dt" -gt "$bgd"
ft_256_to_rgb 254; bgl=$(( (30*FT_RGB_RED+59*FT_RGB_GREEN+11*FT_RGB_BLUE)/100 ))   # light theme bg luminance
_ramps_idx 25 254 150 18                                       # blue accent on light bg
lt=$(_lum_of "${FT_SHEEN_FOREGROUND[0]}"); lc=$(_lum_of "${FT_SHEEN_FOREGROUND[$((_FT_SHEEN_TONE_STEPS_DEFAULT-1))]}")
ok "light bg → crest DARKER than trough (a shadow, not a glow)" test "$lc" -lt "$lt"
ok "light bg → even the trough stays below the background (visible)" test "$lt" -lt "$bgl"
_ramps_idx 51 23 150 18                                        # Ocean: bright cyan on teal
ot=$(_lum_of "${FT_SHEEN_FOREGROUND[0]}"); oc=$(_lum_of "${FT_SHEEN_FOREGROUND[$((_FT_SHEEN_TONE_STEPS_DEFAULT-1))]}")
ok "a near-bright accent (Ocean) still swings a clearly visible amount" \
   test "$(( oc>ot?oc-ot:ot-oc ))" -ge 60
FT_COLOR_MODE=$_cm

note "leaving the field CUTS the animation immediately (arrival, not presence)"
_anim_reset
ft_textfield_deactivate sf 2>/dev/null
ft_focus sf; ft_textfield_activate sf
ok "animation running while inside" test "$(_phase sf)" -ge 0
ft_textfield_deactivate sf
check "Esc out cut it dead" "$(_phase sf)" "-1"
check "...and nothing is left ticking" "$FT_ANIM_ACTIVE" "0"
_anim_reset
ft_textfield_activate sf
_ft_blur_textfield sf
check "losing focus cut it too" "$(_phase sf)" "-1"
_anim_reset
ft_textfield_deactivate sf                 # idle, never activated
ft_anim_start sf 999
_ft_blur_textfield sf
check "blur cuts an animation on an idle field too" "$FT_ANIM_ACTIVE" "0"

note "a looping animation can REST between laps, and the rest costs no frames"
# A rest used to be expressed as DISTANCE — the status bar padded its length with 300 cells
# nobody draws, and paid a wake and a full repaint for every one of them. Stated as time, the
# engine simply does not run the animation until it elapses.
_anim_reset
ft_anim_start bar 6 20 3 1                 # two frames a lap: 0 → 3 → wrap
ft_anim_rest  bar 300
ft_anim_step; check "…first frame of the lap"          "$(_phase bar)" "3"
ft_anim_step; check "the lap ends and the rest begins" "$(_phase bar)" "0"
check "…and the engine records when it is due back"    "$(( ${FT_ANIM_REST_UNTIL_MS[bar]:-0} > 0 ))" "1"
ft_anim_step; ft_anim_step; ft_anim_step
check "resting frames do not advance the phase"        "$(_phase bar)" "0"
                                                       # (not FT_ANIM_ACTIVE: a redraw along the
                                                       # way arms the keycap pulse as well)
check "…and the animation is still registered"         "${FT_ANIM_PHASE[bar]+registered}" "registered"
sleep 0.4
ft_anim_step
check "once the rest elapses the next lap starts"      "$(_phase bar)" "3"
check "…and the rest deadline is cleared"              "${FT_ANIM_REST_UNTIL_MS[bar]:-cleared}" "cleared"

# TEETH: without a rest the very same sequence advances straight into the next lap, so the
# three checks above are about the rest and not about a phase that was never going to move.
_anim_reset
ft_anim_start bar 6 20 3 1                 # identical, minus ft_anim_rest
ft_anim_step; ft_anim_step
check "no rest: the lap wraps to 0 as before"          "$(_phase bar)" "0"
ft_anim_step
check "…and the next frame advances immediately"       "$(_phase bar)" "3"
_anim_reset

note "destroying a field kills its animation (no ticks for a dead control)"
_anim_reset
ft_anim_start sf 999
ft_remove sf
check "ft_remove stopped it" "$FT_ANIM_ACTIVE" "0"

note "hiding a control kills its animation too — a control that is not drawn is not animating"
# ft_anim_step's reaper collects DESTROYED controls and nothing else, so ft_remove stopped an
# animation and display:none did not: the control kept ticking, and FT_ANIM_ACTIVE never
# returned to 0, so the run loop never fell back to its lazy idle poll. Every tab body ever
# opened kept its animations for the life of the process.
ft-form name=hroot width=40 height=10
    ft-frame name=hbox width=30 height=6
        ft-label name=hkid text=inner width=20
    end_ft_frame
end_ft_form
ft_layout hroot
check "the fixture really is nested (else the subtree checks are vacuous)" \
      "${FT_PARENT[hkid]}" "hbox"

_anim_reset
ft_anim_start hbox 999
check "…armed (else the next check passes on an empty registry)" "$FT_ANIM_ACTIVE" "1"
ft_set hbox display=none
check "display:none stops it"                                    "$FT_ANIM_ACTIVE" "0"

# THE SUBTREE, not just the node: hiding a container hides everything under it, and a
# descendant's animation is just as invisible and just as expensive.
ft_set hbox display=block
_anim_reset
ft_anim_start hkid 999
check "…a DESCENDANT armed"                                      "$FT_ANIM_ACTIVE" "1"
ft_set hbox display=none
check "hiding the ancestor stops the descendant's animation too"  "$FT_ANIM_ACTIVE" "0"

# …and it must not be a blanket stop: an animation OUTSIDE the hidden subtree keeps running,
# or "hiding disarms" would just be "hiding disarms everything".
ft_set hbox display=block
_anim_reset
ft_anim_start hkid 999
ft_anim_start hroot 999
check "…two armed, one inside the subtree and one outside"       "$FT_ANIM_ACTIVE" "2"
ft_set hbox display=none
check "hiding a subtree leaves animations outside it alone"      "$FT_ANIM_ACTIVE" "1"
check "…and it is the one outside that survived"                 "${FT_ANIM_PHASE[hroot]:-gone}" "0"
_anim_reset

# THE SIBLING ROUTE, which is why the rule lives at the property write rather than in
# ft_set's `display` branch: switching tabs hides a body with a raw _ft_setprop and
# deliberately does not go through ft_set (see controls/ft-tabs.bash — routing it through
# would drag a full reflow into every switch). A rule that covered only the route someone
# happened to test is the exact bug this removes.
ft-form name=tabroot width=60 height=16
    ft-tabs name=picker width=44 height=12
        ft-tab title="One"
            ft-label name=inTabOne text="first"
        end_ft_tab
        ft-tab title="Two"
            ft-label name=inTabTwo text="second"
        end_ft_tab
    end_ft_tabs
end_ft_form
ft_layout tabroot
_anim_reset
ft_anim_start inTabOne 999
check "…armed inside the open tab"                               "$FT_ANIM_ACTIVE" "1"
ft_tabs_select picker 1
_ft_get_raw "${FT_PARENT[inTabOne]}" display
check "…switching tabs hid that body"                            "$FT_RET" "none"
check "switching tabs stops the hidden body's animation"         "$FT_ANIM_ACTIVE" "0"
_anim_reset

note "the sheen's frozen ring re-renders when a SCROLLBAR appears or moves"
# The sheen paints the scrollbar thumb as part of the ring, and caches the whole ring's bytes
# keyed by a signature. Leave the thumb's position OUT of that signature and a field activated
# while its content fits caches a ring with a plain border column — which is then blitted over
# the thumb on every later draw, so the scrollbar is never visible on screen at all. That
# shipped: the draw was right, the overlay put the old ring back on top of it.
ft_reset_tree 2>/dev/null || true
ft-form name=apps width=60 height=16
  ft-textfield name=sha size=20 rows=5 wrap=true value="short"
  ft-textfield name=shb size=20 value="short"
end_ft_form
ft_layout apps
_sheen_sig_moves() {            # name newvalue → 0 when the cache invalidated
    local n=$1 nv=$2 s1 s2
    ft_focus "$n"; ft_textfield_activate "$n"
    FT_OUT=""; ft_draw_one "$n"; s1=${FT_SHEEN_FROZEN_SIGNATURE[$n]:-NONE}
    ft_set "$n" value="$nv"; FT_TEXTFIELD_CARET[$n]=${#nv}
    ft_layout apps
    FT_OUT=""; ft_draw_one "$n"; s2=${FT_SHEEN_FROZEN_SIGNATURE[$n]:-NONE}
    [[ "$s1" != "$s2" ]]
}
ok "a textarea growing a VERTICAL bar re-renders the ring" \
   _sheen_sig_moves sha $'a\nb\nc\nd\ne\nf\ng\nh'
check "…and the vertical bar exists to be painted" "$([[ -n "${FT_TEXTFIELD_VBAR[sha]:-}" ]] && echo yes)" yes
ok "a field growing a HORIZONTAL bar re-renders the ring" \
   _sheen_sig_moves shb "0123456789012345678901234567890123456789"
check "…and the horizontal bar exists to be painted" "$([[ -n "${FT_TEXTFIELD_HBAR[shb]:-}" ]] && echo yes)" yes

note "the event loop only polls fast WHILE something animates (idle costs nothing)"
# THIS IS TIMED, NOT GREPPED. It used to be two `grep -q` calls against ft-inputlayer.bash —
# one for the token FT_ANIM_ACTIVE, one for the literal `poll=0.25` — which assert that two
# strings occur in a file, not that the loop does anything with them. Proven blind: inverting
# ft_next_event's poll selection (idle 0.05s, animating 0.25s) while leaving both tokens
# textually present kept BOTH greps green, while the measured block time flipped to 50ms idle
# and 250ms animating — a 5x idle wakeup burn and 12x input lag on every animating frame.
#
# ft_next_event is observable headlessly after all. It blocks on `read -t $poll -u $FT_IN_RFD`,
# so point FT_IN_RFD at a fifo opened read-WRITE (never any data, never an EOF) and time the
# call. The one thing to arrange is an exit: on a timeout the function loops forever, but it
# checks FT_WINCH first, so setting FT_WINCH makes it return after exactly ONE poll.
_poll_pipe=$(mktemp -u "${TMPDIR:-/tmp}/ft-poll.XXXXXX"); mkfifo "$_poll_pipe"
exec {_poll_fd}<>"$_poll_pipe"; rm -f "$_poll_pipe"
_saved_in_rfd=${FT_IN_RFD:-}; FT_IN_RFD=$_poll_fd
_poll_ms() {                    # → FT_RET: ms that one ft_next_event poll blocked for
    local start end
    ft_now_ms; start=$FT_RET
    FT_WINCH=1
    ft_next_event >/dev/null 2>&1
    ft_now_ms; end=$FT_RET
    FT_WINCH=0
    FT_RET=$(( end - start ))
}
# The SHORTEST of several polls. A loaded machine can only make a timed read take LONGER, so a
# floor is the honest statistic: "it never woke sooner than this" is a claim load cannot fake.
_poll_floor() {                 # runs → FT_RET
    local runs=$1 i best=999999
    for (( i=0; i<runs; i++ )); do _poll_ms; (( FT_RET < best )) && best=$FT_RET; done
    FT_RET=$best
}
FT_ANIM_ACTIVE=0
_poll_floor 3; _idle_poll_ms=$FT_RET
check "an idle app really does wait out the lazy quarter second (${_idle_poll_ms}ms)" \
      "$(( _idle_poll_ms >= 200 ? 1 : 0 ))" 1
FT_ANIM_ACTIVE=1; FT_ANIM_INTERVAL=0.020
_poll_floor 3; _fast_poll_ms=$FT_RET
check "…and tightens to the frame interval while something animates (${_fast_poll_ms}ms)" \
      "$(( _fast_poll_ms <= 100 ? 1 : 0 ))" 1
FT_ANIM_INTERVAL=0.100
_poll_floor 3; _slow_poll_ms=$FT_RET
# Together with the one above this pins the poll to FT_ANIM_INTERVAL and nothing else: no single
# fixed rate can be both under 100ms at interval 0.020 and over 80ms at interval 0.100.
check "…and a slower animation gets a slower poll, not one fixed rate (${_slow_poll_ms}ms)" \
      "$(( _slow_poll_ms >= 80 ? 1 : 0 ))" 1
# The claim the comment above ft_next_event makes: animating fills dead time, it never delays
# you. A keystroke already queued must be returned at once, not at the end of the poll.
FT_ANIM_ACTIVE=0
printf 'CHAR 61\n' >&$_poll_fd
ft_now_ms; _keypress_start=$FT_RET
ft_next_event >/dev/null 2>&1
ft_now_ms; _keypress_ms=$(( FT_RET - _keypress_start ))
check "a waiting keystroke is returned, not held for the poll (${_keypress_ms}ms)" \
      "$FT_EVENT_TOKEN/$(( _keypress_ms < 50 ? 1 : 0 ))" "CHAR/1"
exec {_poll_fd}>&-; FT_IN_RFD=$_saved_in_rfd
# WATCHED FAILING, 2026-08-30: with ft_next_event's poll selection inverted (idle 0.05,
# animating 0.25) — the prober's mutant, on which BOTH old greps still printed PASS because
# `FT_ANIM_ACTIVE` and the literal `poll=0.25` are still in the file — this section measured
# idle 50ms and fast 250ms and went 2/4 (anim 121/123, exit 1). Restored afterwards.
# Timing note: the two bounds that could drift under load are the upper ones, and they carry
# 5x headroom over a floor of three polls. Re-run this file SOLO before believing a failure.

summary
