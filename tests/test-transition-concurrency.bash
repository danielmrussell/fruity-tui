#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  TWO TRANSITIONS AT ONCE — the concurrency ft-transition.bash's header promises.
#
#  The header says a LIVE transition (one whose ground animates, so it re-reads every frame)
#  and a PRECOMPUTED one may run together. They share one run decomposition — _FT_RUN_* — and
#  an ownership sentinel, _FT_TRANSITION_RUNS_OWNER, tells the live path whether the arrays
#  still describe it: while the user is interacting, a live frame skips the ~90ms ground
#  re-read and re-blends whatever is loaded.
#
#  The sentinel was stamped on ONE of the two routes that rebuild those arrays. Arming a
#  second transition rebuilt them and left the tag naming the first, so the first control's
#  next yielded frame passed the guard and emitted the SECOND control's texts at the SECOND
#  control's cursor addresses — a frame for A painted entirely inside B's rectangle. "Same
#  predicate, every path", applied to shared state with an ownership tag.
#
#  Pinned by geometry, which cannot be argued with: A's frame must address A's rows.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
cd "$here"
export FT_NO_WTFIX=1
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_USE_UTF8=1; FT_COLOR_MODE=truecolor
FT_COLS=95; FT_ROWS=34

# rows a frame's cursor addresses touch, unique, in the order first seen. Split on ESC the
# way the transition's own parser does; a CUP is `<row>;<col>H` at the head of a chunk.
rows_of() {                     # bytes → FT_RET
    local s=$1 out="" chunk row
    local -a parts=()
    local IFS=$'\e'
    set -f; parts=($s); set +f
    IFS=$' \t\n'
    for chunk in "${parts[@]}"; do
        [[ "$chunk" == \[* ]] || continue
        chunk=${chunk:1}
        [[ "$chunk" =~ ^([0-9]+)\;([0-9]+)H ]] || continue
        row=${BASH_REMATCH[1]}
        case " $out " in *" $row "*) ;; *) out+="$row " ;; esac
    done
    FT_RET=$out
}

ft_stylesheet name=conc style='.morph { transition: opacity 400ms linear; }'
ft-form name=app width="$FT_COLS" height="$FT_ROWS"
    ft-frame name=win position=absolute left=1 top=1 width=80 height=30 title="Page" \
             display=flex flexDirection=column gap=1
        ft-label name=l1 text="The quick brown fox jumps over the lazy dog"
        ft-label name=l2 text="Compression: high   Beep: on   Retries: 3"
    end_ft_frame
end_ft_form
FT_ROOT=app; ft_layout app
FT_OUT=""; _ft_redraw_walk app; FT_OUT=""

# A sits high on the page; B sits low. Their rectangles do not overlap, so a frame that
# addresses the wrong rows is unambiguous.
ft-frame name=popA class=morph position=absolute left=6 top=4 width=30 height=8 \
         title="A" backgroundColor=57 color=231 borderColor=213 parent=app
    ft-label name=bodA text="alpha" color=231
end_ft_frame
ft-frame name=popB class=morph position=absolute left=6 top=20 width=30 height=8 \
         title="B" backgroundColor=22 color=231 borderColor=120 parent=app
    ft-label name=bodB text="bravo" color=231
end_ft_frame
ft_layout app

A_TOP=$(( FT_ABSOLUTE_Y[popA] + 1 )); A_BOT=$(( FT_ABSOLUTE_Y[popA] + FT_MEASURED_HEIGHT[popA] ))
B_TOP=$(( FT_ABSOLUTE_Y[popB] + 1 )); B_BOT=$(( FT_ABSOLUTE_Y[popB] + FT_MEASURED_HEIGHT[popB] ))
note "A owns rows $A_TOP-$A_BOT, B owns rows $B_TOP-$B_BOT (1-based, as a cursor address writes them)"

# Something animating under A forces it onto the LIVE path — the one that yields.
ft_anim_start win 240 120 1 1
ok "A arms" ft_transition_in popA
ok "…on the live path" ft_transition_live popA
ft_anim_stop win

# One full (non-yielded) frame, which is what stamps the ownership tag.
FT_ANIM_PHASE[popA]=2
FT_LAST_INPUT_MS=0                       # far in the past → no yield, take the full path
FT_OUT=""; _ft_transition_frame popA transition; baseline=$FT_OUT; FT_OUT=""
check "A's own frame is not a yielded one" "$FT_TRANSITION_LAST_YIELDED" 0
rows_of "$baseline"; base_rows=$FT_RET
note "  A's baseline frame addresses rows: $base_rows"
base_in_a=0; base_in_b=0
for r in $base_rows; do
    (( r >= A_TOP && r <= A_BOT )) && base_in_a=1
    (( r >= B_TOP && r <= B_BOT )) && base_in_b=1
done
check "the baseline frame paints inside A" "$base_in_a" 1
check "…and nowhere near B" "$base_in_b" 0

# Now arm B. This rebuilds the shared decomposition; the tag must not still say "popA".
ok "B arms" ft_transition_in popB
if ft_transition_live popB; then check "B is the precomputed one" live precomputed
else check "B is the precomputed one" precomputed precomputed; fi

# A's next frame, with the user having just interacted, is the yield candidate.
ft_now_ms; FT_LAST_INPUT_MS=$FT_RET
FT_ANIM_PHASE[popA]=3
FT_OUT=""; _ft_transition_frame popA transition; after=$FT_OUT; FT_OUT=""
rows_of "$after"; after_rows=$FT_RET
note "  A's post-arm frame addresses rows: $after_rows"

in_a=0; in_b=0
for r in $after_rows; do
    (( r >= A_TOP && r <= A_BOT )) && in_a=1
    (( r >= B_TOP && r <= B_BOT )) && in_b=1
done
check "A's frame still paints inside A" "$in_a" 1
check "A's frame paints nothing inside B" "$in_b" 0

ft_transition_cancel popA >/dev/null 2>&1
ft_transition_cancel popB >/dev/null 2>&1

# ─────────────────────────────────────────────────────────────────────────────
note "two transitions, two different curves — each keeps its own plan"
# The eased plan and the cut frame were single globals: the last transition to arm owned them
# both. So `ft_transition_cut_frame A` answered with B's cut, and any frame blended after B
# armed — every live frame, and every caller of the public accessor — used B's curve for A.
# Different durations AND different timing functions, so the two plans cannot coincide.
ft_stylesheet name=conc2 style='
    #popC { transition: opacity 600ms linear; }
    #popD { transition: opacity 300ms ease-in-out; }
'
ft-frame name=popC class=morph position=absolute left=40 top=4 width=28 height=8 \
         title="C" backgroundColor=57 color=231 borderColor=213 parent=app
    ft-label name=bodC text="charlie" color=231
end_ft_frame
ft-frame name=popD class=morph position=absolute left=40 top=20 width=28 height=8 \
         title="D" backgroundColor=22 color=231 borderColor=120 parent=app
    ft-label name=bodD text="delta" color=231
end_ft_frame
ft_layout app

ok "C arms" ft_transition_in popC
ft_transition_frame_count popC; C_FRAMES=$FT_RET
ft_transition_cut_frame  popC; C_CUT=$FT_RET
note "  C: $C_FRAMES frames, cut at $C_CUT"

ok "D arms" ft_transition_in popD
ft_transition_frame_count popD; D_FRAMES=$FT_RET
ft_transition_cut_frame  popD; D_CUT=$FT_RET
note "  D: $D_FRAMES frames, cut at $D_CUT"
check "the two really do have different plans" "$(( C_CUT != D_CUT ))" 1

ft_transition_cut_frame popC
check "C's cut frame is still C's, with D armed" "$FT_RET" "$C_CUT"
ft_transition_frame_count popC
check "…and so is its frame count" "$FT_RET" "$C_FRAMES"

# The pixel claim the whole feature rests on: AT ITS OWN CUT, nothing is legible.
zero_contrast_runs() {          # name index → FT_RET "same different"
    ft_transition_frame "$1" "$2" || { FT_RET="0 0"; return 1; }
    local f=$FT_RET chunk body bg fg same=0 different=0
    local -a parts=()
    local IFS=$'\e'
    set -f; parts=($f); set +f
    IFS=$' \t\n'
    for chunk in "${parts[@]}"; do
        [[ "$chunk" == \[*m* ]] || continue
        body=${chunk%%m*}
        [[ "$body" == *";48;2;"*";38;2;"* ]] || continue
        bg=${body#*;48;2;}; bg=${bg%%;38;2;*}
        fg=${body#*;38;2;}
        if [[ "$bg" == "$fg" ]]; then (( same++ )); else (( different++ )); fi
    done
    FT_RET="$same $different"
}
ft_transition_cut_frame popC
zero_contrast_runs popC "$FT_RET"; read -r c_same c_diff <<< "$FT_RET"
note "  C at its reported cut: $c_same runs invisible, $c_diff legible"
check "C's reported cut frame really is the invisible one" "$(( c_same > 0 && c_diff == 0 ))" 1

ft_transition_cut_frame popD
zero_contrast_runs popD "$FT_RET"; read -r d_same d_diff <<< "$FT_RET"
note "  D at its reported cut: $d_same runs invisible, $d_diff legible"
check "D's reported cut frame really is the invisible one" "$(( d_same > 0 && d_diff == 0 ))" 1

ft_transition_cancel popC >/dev/null 2>&1
ft_transition_cancel popD >/dev/null 2>&1

summary
