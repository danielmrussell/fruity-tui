#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — demo/transition-demo.bash
#
#  Controls that MORPH INTO EXISTENCE out of the pixels underneath them.
#
#    bash demo/transition-demo.bash
#
#  Four notices appear over a settled form, each with a different easing, so the shapes of the
#  curves can be compared on one screen.
#
#  THE ENTIRE APPLICATION SURFACE IS THIS:
#
#      ft_set notice display=block      # it transitions in
#      ft_set notice display=none       # it goes away, and the ground repairs itself
#
#  Nothing in this file arms a transition, times one, cancels one, or repairs a cell. A
#  stylesheet says a control transitions, and changing `display` makes it happen — which is
#  how CSS behaves and, since this framework's law is to copy CSS verbatim, how it behaves
#  here. Everything below is declaration:
#
#      .notice        { transition: opacity 420ms ease-in-out; }
#      #slow          { transition-duration: 900ms; }
#      #snappy        { transition: opacity 260ms ease-out; }
#      #punch         { transition: opacity 480ms cubic-bezier(0.34, 1.56, 0.64, 1); }
#      :root          { --transition-schedule: contrast; }
#
#  Keys:  R replay all · 1 2 3 4 replay one · S switch schedule · T type into the field · Q quit
#
#  S is the point of the demo. It switches between the two ways of hiding the glyph swap:
#
#    contrast  the cell's foreground moves to the cell's own background, so at the midpoint
#              nothing is legible and the glyphs are exchanged in the dark.
#    average   the cell's foreground moves to the average of the two foregrounds instead.
#              The colours change; the text stays readable; the cut is plainly visible.
#
#  Watch the text inside the box as it arrives. On `contrast` the old text dissolves and the
#  new text surfaces. On `average` the old text is still legible at the instant it is
#  replaced, and you see the replacement happen. Measured numbers for both are in
#  docs/transitions.md — but this is the thing you are meant to look at, not read about.
# ─────────────────────────────────────────────────────────────────────────────
set -o pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/fruity-tui.bash"
ft_init
ft_term_size

SCHEDULE=contrast

ft_stylesheet name=transition-demo style='
    :root       { --transition-schedule: contrast; }
    .notice     { transition: opacity 420ms ease-in-out; }
    #slow       { transition-duration: 900ms; transition-timing-function: linear; }
    #snappy     { transition: opacity 260ms ease-out; }
    /* An OVERSHOOT curve. CSS has no keyword for one, so this is the cubic-bezier everyone
       means by "back" — spelled out here to show the long form works, though the alias
       ease-out-back is identical. The background sails PAST the target colour and settles
       back into it. (No apostrophes anywhere in this sheet: it is one single-quoted bash
       string, so a possessive closes it and the demo dies at parse time.) */
    #punch      { transition: opacity 480ms cubic-bezier(0.34, 1.56, 0.64, 1); }
    .notice     { background-color: 54; color: 231; border-color: 177; }
    #snappy     { background-color: 23; border-color: 87; }
    #slow       { background-color: 52; border-color: 210; }
    #punch      { background-color: 22; border-color: 120; }
    .cardtext   { color: 231; }
'

ft-form name=app width="$FT_COLS" height="$FT_ROWS" \
        key='[Qq]' onKey=ft_quit key='[Rr]' onKey=replay_all key='[Ss]' onKey=switch_schedule \
        key=1 onKey=replay_one key=2 onKey=replay_two key=3 onKey=replay_three key=4 onKey=replay_four
    ft-frame name=page position=absolute left=1 top=0 \
             width=$(( FT_COLS - 2 )) height=$(( FT_ROWS - 3 )) \
             title='Share \\mago\archive' display=flex flexDirection=column gap=1
        ft-label name=blurb text="A settled page. The notices below morph out of THESE pixels — the ground is whatever is really on the screen, read back through the same damage layer the engine repairs with."
        ft-label name=row1  text="Compression: high      Encryption: required     Retries: 3"
        ft-label name=row2  text="Guest access: denied   Browseable: yes          Quota: 40 GiB"
        ft-label name=row3  text="The quick brown fox jumps over the lazy dog, twice, for width."
        ft-label name=row4  text="Veto files: /.DS_Store/._*/Thumbs.db/   Hide dot files: yes"
        ft-label name=row5  text="Valid users: @staff, @archivists, mago-svc, backup-agent"
        ft-label name=hint  text="Press T to put the caret in the field, then type WHILE a notice arrives."
        ft-textfield name=entry width=54 value=""
    end_ft_frame
    ft-statusbar name=bar position=absolute left=0 top=$(( FT_ROWS - 1 )) width="$FT_COLS" \
                 status="R replay · 1 2 3 4 one · S schedule · T type · Q quit"
    # The notices. They live in the tree from the start, hidden, and the whole demo is
    # flipping their `display` — an app never has to think about what was underneath.
    ft-frame name=early class=notice position=absolute left=6 top=4 width=34 height=7 \
             title="ease-in-out 420ms" display=none
        ft-label name=earlyBody class=cardtext text="Ordinary. Symmetric. The cut lands in the middle."
    end_ft_frame
    ft-frame name=snappy class=notice position=absolute left=44 top=6 width=34 height=7 \
             title="ease-out 260ms" display=none
        ft-label name=snappyBody class=cardtext text="Quick off the mark, settles gently."
    end_ft_frame
    ft-frame name=slow class=notice position=absolute left=20 top=13 width=40 height=7 \
             title="linear 900ms" display=none
        ft-label name=slowBody class=cardtext text="Slow and even — the easiest one to watch the glyph swap in."
    end_ft_frame
    ft-frame name=punch class=notice position=absolute left=62 top=15 width=32 height=7 \
             title="overshoot 480ms" display=none
        ft-label name=punchBody class=cardtext text="cubic-bezier past 1.0 — the colour sails past and settles back."
    end_ft_frame
end_ft_form


# SHOWING AND HIDING IS THE WHOLE OF IT. Two ft_set calls: one puts the notices back, one
# takes them away. Nothing here arms a transition, times one, cancels one, or repairs a cell —
# the stylesheet said `transition:`, so changing `display` is the entire application surface,
# exactly as it is in a browser.
_replay() {                     # names…
    local n
    for n in "$@"; do ft_set "$n" display=none;  done
    for n in "$@"; do ft_set "$n" display=block; done
}

replay_all()   { _replay early snappy slow punch; }
replay_one()   { _replay early; }
replay_two()   { _replay snappy; }
replay_three() { _replay slow; }
replay_four()  { _replay punch; }

switch_schedule() {
    if [[ "$SCHEDULE" == contrast ]]; then SCHEDULE=average; else SCHEDULE=contrast; fi
    # A custom property on :root, re-applied by re-registering the sheet — the same live
    # restyle any theme change uses. Nothing in the transition code is told about it.
    ft_stylesheet name=transition-demo-schedule style=":root { --transition-schedule: $SCHEDULE; }"
    _status
    replay_all
}
_status() {
    local depth=truecolor
    ft_transition_supported || depth="256 — expect BANDING, not a melt"
    ft_set bar status="schedule: $SCHEDULE · $depth · R replay · 1 2 3 4 one · S schedule · T type · Q quit"
}

app_on_type() { ft_focus entry; ft_dispatch_event Enter; }

_setup() { ft_layout app; _status; }
# T is handled as a fallback so it still works while the field has focus in navigation mode.
_fallback() {
    case "$FT_EVENT_CHAR" in
        t|T) app_on_type ;;
    esac
}
ft_run app _setup "" _fallback
