#!/usr/bin/env bash
# Fruity TUI — controls render demo (non-interactive).
#
# Builds a real control TREE with the property DSL — ft-frame (title=), ft-boxheader,
# ft-label, ft-textfield, ft-heading, a flex row of ft-button, ft-keylegend and
# ft-statusbar — lays it out with the engine, renders one frame, and prints it
# ANSI-stripped.
#
# Nothing is hand-positioned: every row/column comes from the layout engine and every
# colour from the cascade. (This used to hand-draw the frame with ft_print_at and call
# positional painters — ft-title/ft-synopsis/ft-buttonbar. Those are gone.)
#
#   bash demo/controls-demo.bash
set -u
set -o pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/fruity-tui.bash"
ft_init

FT_ROWS=20; FT_COLS=70
out=$(mktemp); exec {FT_TTY}>"$out"
FT_OUT=""

ft-form name=app width="$FT_COLS" height="$FT_ROWS" display=flex flexDirection=column
    ft-frame name=win title="Add Interface Wildcard" \
             display=flex flexDirection=column gap=1 padding=1 flexGrow=1
        ft-boxheader name=hdr text="Interface Wildcards"

        ft-div name=row display=flex flexDirection=row gap=1
            ft-label     name=lbl text="Pattern:"
            ft-textfield name=pat value="eth*" flexGrow=1
        end_ft_div

        ft-heading name=adv text="Actions"

        ft-div name=bar display=flex flexDirection=row gap=2
            ft-button name=ok   OK   accessKey=K
            ft-button name=help Help accessKey=H
            ft-button name=quit Quit accessKey=Q
        end_ft_div
    end_ft_frame

    ft-keylegend name=legend flexShrink=0 keys="Enter=Save  Tab=Focus  Esc=Cancel"
    ft-statusbar name=status flexShrink=0 \
                 status="Wildcards are matched by interface name at Samba startup."
end_ft_form

# The old version exited 0 while three of its controls silently failed to draw. A
# control whose constructor rejected its arguments never enters FT_TYPE, so this is
# exactly the check that would have caught it.
rc=0
for c in app win hdr lbl pat adv ok help quit legend status; do
    [[ -n "${FT_TYPE[$c]:-}" ]] || { echo "controls-demo: control '$c' was never created" >&2; rc=1; }
done

ft_layout app
ft_redraw_all app
ft_flush
exec {FT_TTY}>&-

echo "=== rendered (ANSI stripped; _X_ marks underlined accelerator) ==="
render=$(python3 - "$out" <<'PY'
import re,sys
d=open(sys.argv[1],encoding="utf-8",errors="replace").read()
d=re.sub(r"\x1b\[\?[0-9]*[hl]","",d)
d=d.replace("\x1b[4m","_").replace("\x1b[24m","_")
parts=re.split(r"\x1b\[(\d+);(\d+)H",d); rows={}; i=1
while i+2<len(parts):
    r=int(parts[i]); c=int(parts[i+1]); t=re.sub(r"\x1b\[[0-9;]*m","",parts[i+2])
    rows.setdefault(r,[]).append((c,t)); i+=3
for r in sorted(rows):
    buf={}
    for c,s in rows[r]:
        for k,ch in enumerate(s): buf[c-1+k]=ch
    if buf:
        line="".join(buf.get(j," ") for j in range(max(buf)+1))
        # The ROUNDED corners belong here too: the keylegend's boxed caps draw ╭╮╰╯, and
        # folding only the square set printed "╭-------╮" — a box that looks broken in the
        # dump while the real screen is fine.
        for a,b in [("┌","+"),("┐","+"),("└","+"),("┘","+"),
                    ("╭","+"),("╮","+"),("╰","+"),("╯","+"),
                    ("─","-"),("│","|")]:
            line=line.replace(a,b)
        print(line.rstrip())
PY
)
printf '%s\n' "$render"
rm -f "$out"

# Every element the demo claims to show must actually reach the SCREEN. Checked against
# the stripped render, not the raw bytes: accessKey markup splits a label mid-word
# ("OK" is emitted as O·<underline>K</underline>), so a raw byte search would miss it.
# The stripper renders those underline toggles as "_", so drop them before matching.
plain=${render//_/}
# NB the legend is checked as two SEPARATE tokens, not the string "Enter: Save". The keylegend
# now defaults to capStyle=boxed, which draws the key inside a rounded box and puts its label
# beside it — so the flat "Enter: Save" spelling no longer appears anywhere on screen. This
# demo went on asserting the flat form and failed silently for exactly as long as it took
# someone to run it: demos are not in tests/run-all.bash.
for want in "Add Interface Wildcard" "Interface Wildcards" "Pattern:" "eth*" \
            "Actions" "OK" "Help" "Quit" "Enter" "Save" "Samba startup"; do
    [[ "$plain" == *"$want"* ]] || { echo "controls-demo: '$want' never rendered" >&2; rc=1; }
done
(( rc == 0 )) || echo "controls-demo: FAILED" >&2
exit $rc
