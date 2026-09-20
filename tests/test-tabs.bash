#!/usr/bin/env bash
# Unit tests for controls/ft-tabs.bash — the tabbed container. Covers: tab
# children attach, the auto strip child is created and placed first, only the
# active tab is displayed, switching clamps and flips displays, and a render
# shows the strip titles plus only the active body.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
source "$here/fruity-tui.bash"
ft_init
exec {FT_TTY}>/dev/null
FT_COLS=60; FT_ROWS=16
_plain() { local s=$1; s=$(printf '%s' "$s" | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g'); printf '%s' "$s"; }

note "tabs attach and reserve the header rows"
ft-form name=app width=60 height=16
ft-tabs name=tb width=44 height=12 onChange=tb_on_change
    ft-tab title="One"
        ft-label name=b1 text="BODY-ONE"
    end_ft_tab
    ft-tab title="Two"
        ft-label name=b2 text="BODY-TWO"
    end_ft_tab
    ft-tab title="Three"
        ft-label name=b3 text="BODY-THREE"
    end_ft_tab
end_ft_tabs
end_ft_form

_ft_tabs_tabs tb; check "3 tab children" "${#FT_TABS[@]}" "3"
check "tabs reserve 3 header rows (paddingTop)" "$(ft_resolved_prop tb paddingTop; echo $FT_RET)" "3"

note "only the active tab is displayed"
ft_resolved_prop "${FT_TABS[0]}" display; check "tab 0 shown (flex)" "$FT_RET" "flex"
ft_resolved_prop "${FT_TABS[1]}" display; check "tab 1 hidden (none)" "$FT_RET" "none"
ft_resolved_prop "${FT_TABS[2]}" display; check "tab 2 hidden (none)" "$FT_RET" "none"

note "switching flips activeTab and the displays, clamped (no wrap)"
ft_tabs_next tb; ft_resolved_prop tb activeTab; check "next → 1" "$FT_RET" "1"
ft_resolved_prop "${FT_TABS[1]}" display; check "tab 1 now shown" "$FT_RET" "flex"
ft_resolved_prop "${FT_TABS[0]}" display; check "tab 0 now hidden" "$FT_RET" "none"
ft_tabs_last  tb; ft_resolved_prop tb activeTab; check "End → last (2)" "$FT_RET" "2"
ft_tabs_next  tb; ft_resolved_prop tb activeTab; check "next clamps at last" "$FT_RET" "2"
ft_tabs_first tb; ft_resolved_prop tb activeTab; check "Home → 0" "$FT_RET" "0"
ft_tabs_prev  tb; ft_resolved_prop tb activeTab; check "prev clamps at 0" "$FT_RET" "0"

note "render: strip shows all titles; body shows only the active tab"
ft_tabs_first tb
ft_layout app; FT_OUT=""; _ft_redraw_walk app
plain=$(_plain "$FT_OUT")
for t in One Two Three; do
    case "$plain" in *"$t"*) check "strip shows '$t'" 1 1 ;; *) check "strip shows '$t'" 0 1 ;; esac
done
case "$plain" in *"BODY-ONE"*)   check "active body One shown"   1 1 ;; *) check "active body One shown"   0 1 ;; esac
case "$plain" in *"BODY-TWO"*)   check "unfocused body Two hidden" 0 1 ;; *) check "unfocused body Two hidden" 1 1 ;; esac

note "the change hook fires with the new index"
GACT=""
tb_on_change() { GACT=$1; }
ft_tabs_next tb
check "on_change got new index (1)" "$GACT" "1"

# ── Switching tabs may not strand the focus in the panel it just hid ─────────
# A tab's accessKey fires from ANYWHERE on the form — _ft_accel_target keeps a hidden tab's
# accelerator live on purpose, because activating it is what un-hides it, and ft-help gives
# every help tab one. So the ordinary case is: focus is on a button INSIDE the open panel and
# the user presses another tab's letter. Every other way of hiding a control repairs focus
# (ft_set's display route runs `_ft_focus_skippable FT_FOCUS && ft_focus_move 1`); the tab
# switch wrote `display` directly and did not, so focus stayed on the hidden button, the
# keymap cascade and legend with it, and ENTER ACTIVATED SOMETHING INVISIBLE.
note "an accelerator switch never leaves focus on the panel it hid"
ft-form name=facc width=60 height=16
    ft-tabs name=tab2 width=44 height=12
        ft-tab title="Alpha" accessKey=A
            ft-button name=inAlpha text="Press me" onActivate=inAlpha_on_activate
        end_ft_tab
        ft-tab title="Beta" accessKey=B
            ft-button name=inBeta text="Other" onActivate=inBeta_on_activate
        end_ft_tab
    end_ft_tabs
end_ft_form
HIT=""
inAlpha_on_activate() { HIT+="alpha "; }
inBeta_on_activate()  { HIT+="beta ";  }
ft_layout facc; FT_ROOT=facc
ft_focus_ring_build facc
_ft_tabs_tabs tab2
ft_focus inAlpha
check "focus starts inside the open panel" "${FT_FOCUS}" "inAlpha"

_ft_accel_dispatch facc B                    # the user presses Beta's accelerator
ft_resolved_prop tab2 activeTab; check "the accelerator switched tabs" "$FT_RET" "1"
ft_resolved_prop "${FT_TABS[0]}" display; check "…and hid the Alpha panel" "$FT_RET" "none"
check "focus is NOT left on the hidden button" \
      "$(_ft_focus_skippable "${FT_FOCUS:-}" && echo stranded || echo ok)" "ok"
check "…it landed somewhere visible" \
      "$(_ft_hidden_anywhere "${FT_FOCUS:-}" && echo hidden || echo visible)" "visible"

HIT=""
ft_activate "$FT_FOCUS"                      # what Enter does with whatever focus is on now
case "$HIT" in *alpha*) check "Enter did not activate the invisible button" 0 1 ;;
               *)       check "Enter did not activate the invisible button" 1 1 ;; esac
ft_remove facc

summary
