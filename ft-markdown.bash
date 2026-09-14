#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Fruity TUI — ft-markdown.bash   (a small CommonMark-ish renderer)
#
#  ft_markdown SRC WIDTH  →  FT_MARKDOWN_LINES[]  — an array of ANSI-styled display
#  lines, each already fit to WIDTH columns, ready to paint verbatim. It is the
#  engine behind a text field's  markdown=true  read-only viewer (help windows,
#  READMEs, changelogs) — the one place a TUI needs *rich* text.
#
#  Supported, using only what a terminal can actually do:
#     • headings  # .. ######            → bold, with a rule under h1/h2
#     • GFM pipe tables (the point)       → box-drawn, per-column :--: alignment
#     • bullet / ordered lists            → •  or  1.  with a hanging indent
#     • block quotes  >                   → a │ rail
#     • fenced code  ``` … ```            → dim, verbatim (no inline parsing)
#     • thematic breaks  --- *** ___      → a full-width rule
#     • inline **bold*, *italic*, `code`, [text](url), and \escapes
#       links use OSC-8 hyperlinks (clickable in modern terminals; the text
#       still shows everywhere else).
#
#  Style is expressed with self-closing SGR *attribute* toggles (1/22, 3/23,
#  4/24, 7/27) and never a full \e[0m reset — so an embedded run can never wipe
#  the field's background colour. The caller supplies the base colour; every
#  line here returns to plain attributes at its end.
#
#  Depends on ft-core (glyphs, ft_display_width). No forks in the render path.
# ─────────────────────────────────────────────────────────────────────────────
[[ -n "${_FT_MARKDOWN_LOADED:-}" ]] && return 0
_FT_MARKDOWN_LOADED=1

FT_MARKDOWN_LINES=()
_MD_W=0                              # current render width (module-scoped)
FT_RET=""

# Turn off every attribute this renderer can switch on — appended at the end of
# any styled line so nothing (bold, italic, underline, reverse) leaks onward.
_MD_ATTROFF=$'\e[22m\e[23m\e[24m\e[27m'

# ── Inline scanner ───────────────────────────────────────────────────────────
# _md_scan TEXT  →  parallel _MDS_T[] (text) / _MDS_S[] (style p|b|i|c|l) /
# _MDS_U[] (link URL). Recognises **bold**, *italic*, `code`, [text](url) and
# backslash escapes. Underscores are left ALONE (technical help is full of
# snake_case); emphasis is asterisks only.
_MDS_T=(); _MDS_S=(); _MDS_U=()
_md_scan() {
    local t=$1 i=0 n=${#1} ch nx buf="" j close inner url
    _MDS_T=(); _MDS_S=(); _MDS_U=()
    while (( i < n )); do
        ch=${t:i:1}
        case $ch in
        '\')                                   # escape: a backslash before ASCII
            nx=${t:i+1:1}                        # punctuation makes it literal
            case $nx in
                ''|[a-zA-Z0-9]) buf+='\'; (( i++ )) ;;   # not an escape → literal backslash
                *)              buf+=$nx; (( i+=2 )) ;;   # escaped punctuation
            esac
            continue ;;
        '`')                                   # inline code: to the next backtick
            close=-1
            for (( j=i+1; j<n; j++ )); do [[ ${t:j:1} == '`' ]] && { close=$j; break; }; done
            if (( close < 0 )); then buf+='`'; (( i++ )); continue; fi
            [[ -n "$buf" ]] && { _MDS_T+=("$buf"); _MDS_S+=(p); _MDS_U+=(""); buf=""; }
            inner=${t:i+1:close-i-1}
            _MDS_T+=("$inner"); _MDS_S+=(c); _MDS_U+=("")
            i=$(( close + 1 )) ;;
        '*')
            if [[ ${t:i+1:1} == '*' ]]; then   # **bold** — find closing **
                close=-1
                for (( j=i+2; j<n-0; j++ )); do [[ ${t:j:1} == '*' && ${t:j+1:1} == '*' ]] && { close=$j; break; }; done
                if (( close < 0 )); then buf+='*'; (( i++ )); continue; fi
                [[ -n "$buf" ]] && { _MDS_T+=("$buf"); _MDS_S+=(p); _MDS_U+=(""); buf=""; }
                inner=${t:i+2:close-i-2}
                _MDS_T+=("$inner"); _MDS_S+=(b); _MDS_U+=("")
                i=$(( close + 2 ))
            else                               # *italic* — find closing *
                close=-1
                for (( j=i+1; j<n; j++ )); do [[ ${t:j:1} == '*' ]] && { close=$j; break; }; done
                if (( close < 0 )); then buf+='*'; (( i++ )); continue; fi
                [[ -n "$buf" ]] && { _MDS_T+=("$buf"); _MDS_S+=(p); _MDS_U+=(""); buf=""; }
                inner=${t:i+1:close-i-1}
                _MDS_T+=("$inner"); _MDS_S+=(i); _MDS_U+=("")
                i=$(( close + 1 ))
            fi ;;
        '[')                                   # [text](url)
            local rb=-1 lp rp
            for (( j=i+1; j<n; j++ )); do [[ ${t:j:1} == ']' ]] && { rb=$j; break; }; done
            if (( rb < 0 )) || [[ ${t:rb+1:1} != '(' ]]; then buf+='['; (( i++ )); continue; fi
            lp=$(( rb + 1 )); rp=-1
            for (( j=lp+1; j<n; j++ )); do [[ ${t:j:1} == ')' ]] && { rp=$j; break; }; done
            if (( rp < 0 )); then buf+='['; (( i++ )); continue; fi
            [[ -n "$buf" ]] && { _MDS_T+=("$buf"); _MDS_S+=(p); _MDS_U+=(""); buf=""; }
            inner=${t:i+1:rb-i-1}; url=${t:lp+1:rp-lp-1}
            _MDS_T+=("$inner"); _MDS_S+=(l); _MDS_U+=("$url")
            i=$(( rp + 1 )) ;;
        *)  buf+=$ch; (( i++ )) ;;
        esac
    done
    [[ -n "$buf" ]] && { _MDS_T+=("$buf"); _MDS_S+=(p); _MDS_U+=(""); }
}

# Style one word (no spaces) for a given span style. Attribute toggles only, so
# each word is self-contained and can sit anywhere on a wrapped line.
_md_style_word() {              # word style url → FT_RET
    case $2 in
        b) FT_RET=$'\e[1m'$1$'\e[22m' ;;
        i) FT_RET=$'\e[3m'$1$'\e[23m' ;;
        c) FT_RET=$'\e[7m'$1$'\e[27m' ;;
        l) FT_RET=$'\e]8;;'$3$'\e\\'$'\e[4m'$1$'\e[24m'$'\e]8;;\e\\' ;;
        *) FT_RET=$1 ;;
    esac
}

# _md_inline TEXT → FT_MARKDOWN_INLINE (fully styled, unwrapped) and FT_MARKDOWN_PLAIN (plain text, for
# width/measurement). One scan feeds both.
FT_MARKDOWN_INLINE=""; FT_MARKDOWN_PLAIN=""
_md_inline() {
    _md_scan "$1"
    local k s="" p="" seg
    for (( k=0; k<${#_MDS_T[@]}; k++ )); do
        seg=${_MDS_T[k]}; p+=$seg
        _md_style_word "$seg" "${_MDS_S[k]}" "${_MDS_U[k]}"; s+=$FT_RET
    done
    FT_MARKDOWN_INLINE=$s; FT_MARKDOWN_PLAIN=$p
}
_md_plain_of() { _md_inline "$1"; }   # convenience: leaves FT_MARKDOWN_PLAIN set

# ── Line emit helpers ────────────────────────────────────────────────────────
# Push STYLED, padded with plain spaces to the render width (never truncates —
# callers wrap/fit first).
_md_push() {
    local s=$1 pad
    ft_display_width "$s"; pad=$(( _MD_W - FT_DISPLAY_WIDTH )); (( pad < 0 )) && pad=0
    printf -v s '%s%*s' "$s" "$pad" ''
    FT_MARKDOWN_LINES+=("$s")
}
_md_blank() { local b; printf -v b '%*s' "$_MD_W" ''; FT_MARKDOWN_LINES+=("$b"); }
_md_rule()  { local r; printf -v r '%*s' "$_MD_W" ''; FT_MARKDOWN_LINES+=("${r// /$FT_GLYPH_HORIZONTAL}"); }

# ── Paragraph / wrapped-text emit ────────────────────────────────────────────
# _md_para TEXT FIRSTPREFIX CONTPREFIX — inline-style TEXT, word-wrap to the
# render width, and push. FIRSTPREFIX leads the first line (e.g. "• "), CONTPREFIX
# every continuation (e.g. "  "); both are plain and counted by display width.
_md_para() {
    local text=$1 fp=$2 cp=$3
    _md_scan "$text"
    local -a WS=() WW=()                 # styled words + their display widths
    local k seg sty url piece
    local -a pcs=()
    for (( k=0; k<${#_MDS_T[@]}; k++ )); do
        seg=${_MDS_T[k]}; sty=${_MDS_S[k]}; url=${_MDS_U[k]}
        pcs=(); read -ra pcs <<< "$seg"           # split on whitespace (here-string, no fork)
        for piece in "${pcs[@]}"; do
            _md_style_word "$piece" "$sty" "$url"
            WS+=("$FT_RET"); WW+=("${#piece}")
        done
    done
    ft_display_width "$fp"; local fpw=$FT_DISPLAY_WIDTH
    ft_display_width "$cp"; local cpw=$FT_DISPLAY_WIDTH
    if (( ${#WS[@]} == 0 )); then _md_push "$fp"; return; fi
    local line=$fp lw=0 first=1 i ww avail
    for (( i=0; i<${#WS[@]}; i++ )); do
        ww=${WW[i]}
        (( first )) && avail=$(( _MD_W - fpw )) || avail=$(( _MD_W - cpw ))
        if (( lw == 0 )); then line+=${WS[i]}; lw=$ww
        elif (( lw + 1 + ww <= avail )); then line+=" ${WS[i]}"; lw=$(( lw + 1 + ww ))
        else _md_push "$line$_MD_ATTROFF"; line="$cp${WS[i]}"; lw=$ww; first=0
        fi
    done
    _md_push "$line$_MD_ATTROFF"
}

# ── Tables ───────────────────────────────────────────────────────────────────
# _md_row_cells ROW → _MD_CELLS[] : split a pipe row into trimmed cells.
_MD_CELLS=()
_md_row_cells() {
    local row=$1 i n ch cur=""
    row=${row#"${row%%[![:space:]]*}"}; row=${row%"${row##*[![:space:]]}"}   # trim ends
    [[ $row == '|'* ]] && row=${row:1}
    [[ $row == *'|' ]] && row=${row%?}
    _MD_CELLS=(); n=${#row}
    for (( i=0; i<n; i++ )); do
        ch=${row:i:1}
        if [[ $ch == '\' && ${row:i+1:1} == '|' ]]; then cur+='|'; (( i++ )); continue; fi
        if [[ $ch == '|' ]]; then
            cur=${cur#"${cur%%[![:space:]]*}"}; cur=${cur%"${cur##*[![:space:]]}"}
            _MD_CELLS+=("$cur"); cur=""
        else cur+=$ch; fi
    done
    cur=${cur#"${cur%%[![:space:]]*}"}; cur=${cur%"${cur##*[![:space:]]}"}
    _MD_CELLS+=("$cur")
}
# A separator row: only | : - and spaces, and at least one dash.
_md_is_sep() { local s=${1//[|: $'\t'-]/}; [[ -z $s && $1 == *-* ]]; }

# One padded, aligned, styled table cell body of exactly CW+2 columns (a space
# on each side of a CW-wide field). Overflowing content is truncated with an
# ellipsis (and loses inline styling — a cropped run can't be trusted to close).
_md_cell() {                    # raw cw align(l|c|r) bold → FT_RET
    local raw=$1 cw=$2 al=$3 bold=$4
    # A cell is CW COLUMNS wide, not CW characters. Measuring and cutting by character made
    # a table of CJK cells come apart: the borders were built from the character counts and
    # the cells painted twice that, so no vertical rule met the ┬ above it.
    _md_inline "$raw"; local styled=$FT_MARKDOWN_INLINE plain=$FT_MARKDOWN_PLAIN
    ft_display_width "$plain"; local pw=$FT_DISPLAY_WIDTH
    if (( pw > cw )); then
        if (( cw >= 1 )); then
            ft_display_truncate "$plain" $(( cw - 1 )); styled=$FT_DISPLAY_TRUNCATED$FT_GLYPH_ELLIPSIS
            # The cut stops BEFORE a double-width glyph it cannot fit whole, so this can land
            # a column short — the padding below makes it up rather than the row being narrow.
            ft_display_width "$styled"; pw=$FT_DISPLAY_WIDTH
        else styled=""; pw=0; fi
    elif [[ $bold == 1 ]]; then styled=$'\e[1m'$styled$'\e[22m'
    fi
    local padtot=$(( cw - pw )) lp rp
    (( padtot < 0 )) && padtot=0
    case $al in
        c) lp=$(( padtot / 2 )); rp=$(( padtot - lp )) ;;
        r) lp=$padtot; rp=0 ;;
        *) lp=0; rp=$padtot ;;
    esac
    printf -v FT_RET ' %*s%s%*s ' "$lp" '' "$styled$_MD_ATTROFF" "$rp" ''
}

# _md_table ROWS…  — render a GFM pipe table (header, separator, data rows).
_md_table() {
    local -a rows=("$@"); local nr=${#rows[@]}
    (( nr < 2 )) && { local r; for r in "${rows[@]}"; do _md_para "$r" "" ""; done; return; }
    local -a header=() sep=() align=() cw=()
    _md_row_cells "${rows[0]}"; header=("${_MD_CELLS[@]}"); local nc=${#header[@]}
    _md_row_cells "${rows[1]}"; sep=("${_MD_CELLS[@]}")
    local c spec
    for (( c=0; c<nc; c++ )); do
        spec=${sep[c]:-}
        if   [[ $spec == :*: ]]; then align[c]=c
        elif [[ $spec == *:  ]]; then align[c]=r
        else align[c]=l; fi
    done
    # Natural column widths from header + data (plain text), in COLUMNS — the same unit the
    # border below is drawn in, and the unit the terminal advances by.
    for (( c=0; c<nc; c++ )); do
        cw[c]=1; _md_plain_of "${header[c]}"
        ft_display_width "$FT_MARKDOWN_PLAIN"; (( FT_DISPLAY_WIDTH > cw[c] )) && cw[c]=$FT_DISPLAY_WIDTH
    done
    local r
    for (( r=2; r<nr; r++ )); do
        _md_row_cells "${rows[r]}"
        for (( c=0; c<nc; c++ )); do
            _md_plain_of "${_MD_CELLS[c]:-}"
            ft_display_width "$FT_MARKDOWN_PLAIN"; (( FT_DISPLAY_WIDTH > cw[c] )) && cw[c]=$FT_DISPLAY_WIDTH
        done
    done
    # Fit to width:  total = 1 + Σ(cw+3).  Shrink the widest column until it fits.
    local total guard=0 widest wi
    _md_table_total() { total=1; local k; for (( k=0; k<nc; k++ )); do total=$(( total + cw[k] + 3 )); done; }
    _md_table_total
    while (( total > _MD_W && guard < 4000 )); do
        widest=0; wi=0; for (( c=0; c<nc; c++ )); do (( cw[c] > widest )) && { widest=${cw[c]}; wi=$c; }; done
        (( widest <= 3 )) && break
        cw[wi]=$(( widest - 1 )); _md_table_total; (( guard++ ))
    done
    # Border builder over the resolved column widths.
    local out seg
    _md_tborder() {                     # leftG midG rightG → FT_RET
        local k; out=$1
        for (( k=0; k<nc; k++ )); do
            printf -v seg '%*s' $(( cw[k] + 2 )) ''; out+=${seg// /$FT_GLYPH_HORIZONTAL}
            (( k < nc-1 )) && out+=$2
        done
        out+=$3; FT_RET=$out
    }
    _md_tborder "$FT_GLYPH_TOP_LEFT" "$FT_GLYPH_TEE_DOWN" "$FT_GLYPH_TOP_RIGHT"; _md_push "$FT_RET"       # top
    local line
    line=$FT_GLYPH_VERTICAL; for (( c=0; c<nc; c++ )); do _md_cell "${header[c]}" "${cw[c]}" "${align[c]}" 1; line+=$FT_RET$FT_GLYPH_VERTICAL; done
    _md_push "$line"                                                          # header
    _md_tborder "$FT_GLYPH_TEE_LEFT" "$FT_GLYPH_CROSS" "$FT_GLYPH_TEE_RIGHT"; _md_push "$FT_RET"       # header rule
    for (( r=2; r<nr; r++ )); do
        _md_row_cells "${rows[r]}"
        line=$FT_GLYPH_VERTICAL
        for (( c=0; c<nc; c++ )); do _md_cell "${_MD_CELLS[c]:-}" "${cw[c]}" "${align[c]}" 0; line+=$FT_RET$FT_GLYPH_VERTICAL; done
        _md_push "$line"
    done
    _md_tborder "$FT_GLYPH_BOTTOM_LEFT" "$FT_GLYPH_TEE_UP" "$FT_GLYPH_BOTTOM_RIGHT"; _md_push "$FT_RET"       # bottom
}

# ── Block driver ─────────────────────────────────────────────────────────────
ft_markdown() {                 # src width → FT_MARKDOWN_LINES[]
    local src=$1
    _MD_W=$2; (( _MD_W < 1 )) && _MD_W=1
    FT_MARKDOWN_LINES=()
    # Split into raw lines (finite walk — a trailing newline can't loop).
    local -a L=(); local rest=$src
    while :; do L+=("${rest%%$'\n'*}"); [[ $rest == *$'\n'* ]] || break; rest=${rest#*$'\n'}; done
    local nn=${#L[@]} i=0 line lead body level j
    local bullet='•'; (( FT_USE_UTF8 )) || bullet='*'
    while (( i < nn )); do
        line=${L[i]}
        # leading spaces → lead count, body = trimmed-left
        body=${line#"${line%%[![:space:]]*}"}; lead=$(( ${#line} - ${#body} ))

        # blank line
        if [[ -z $body ]]; then _md_blank; (( i++ )); continue; fi

        # fenced code ``` or ~~~
        if [[ $body == '```'* || $body == '~~~'* ]]; then
            (( i++ ))
            while (( i < nn )); do
                local cl=${L[i]}; local clt=${cl#"${cl%%[![:space:]]*}"}
                [[ $clt == '```'* || $clt == '~~~'* ]] && { (( i++ )); break; }
                ft_fit "$cl" "$_MD_W"; FT_MARKDOWN_LINES+=($'\e[2m'"$FT_FIT"$'\e[22m')
                (( i++ ))
            done
            continue
        fi

        # table: a pipe row followed by a separator row
        if [[ $body == *'|'* ]] && (( i+1 < nn )) && _md_is_sep "${L[i+1]}"; then
            local -a trows=("$body")
            (( i++ )); trows+=("${L[i]}")            # separator
            while (( i+1 < nn )); do
                local nx=${L[i+1]}; local nxt=${nx#"${nx%%[![:space:]]*}"}
                [[ $nxt == *'|'* && -n $nxt ]] || break
                trows+=("$nxt"); (( i++ ))
            done
            (( i++ ))
            _md_table "${trows[@]}"
            continue
        fi

        # thematic break: --- *** ___  (3+ of one char, only that char + spaces)
        if [[ ${body//[- ]/} == '' && $body == *---* ]] \
        || [[ ${body//[* ]/} == '' && $body == *'***'* ]] \
        || [[ ${body//[_ ]/} == '' && $body == *___* ]]; then
            _md_rule; (( i++ )); continue
        fi

        # ATX heading  # .. ######
        if [[ $body == '#'* ]]; then
            level=0; for (( j=0; j<${#body}; j++ )); do [[ ${body:j:1} == '#' ]] || break; (( level++ )); done
            if (( level >= 1 && level <= 6 )) && [[ ${body:level:1} == ' ' || ${body:level:1} == '' ]]; then
                local htext=${body:level}; htext=${htext#"${htext%%[![:space:]]*}"}
                htext=${htext%"${htext##*[![:space:]]}"}; htext=${htext%%#}     # optional trailing #
                htext=${htext%"${htext##*[![:space:]]}"}
                ft_fit "$htext" "$_MD_W"
                FT_MARKDOWN_LINES+=($'\e[1m'"$FT_FIT"$'\e[22m')
                (( level <= 2 )) && _md_rule
                (( i++ )); continue
            fi
        fi

        # block quote  >
        if [[ $body == '>'* ]]; then
            local q=${body#>}; q=${q# }
            _md_para "$q" "$FT_GLYPH_VERTICAL " "$FT_GLYPH_VERTICAL "
            (( i++ )); continue
        fi

        # unordered list  - * +
        if [[ $body == '- '* || $body == '* '* || $body == '+ '* ]]; then
            local it=${body:2}
            # gather continuation (subsequent more-indented, non-blank, non-marker lines)
            while (( i+1 < nn )); do
                local c2=${L[i+1]}; [[ -z ${c2//[[:space:]]/} ]] && break
                local c2b=${c2#"${c2%%[![:space:]]*}"}
                [[ $c2b == '- '* || $c2b == '* '* || $c2b == '+ '* ]] && break
                [[ $c2 == ' '* ]] || break
                it+=" $c2b"; (( i++ ))
            done
            _md_para "$it" "$bullet " "  "
            (( i++ )); continue
        fi
        # ordered list  1.  2)  …
        if [[ $body =~ ^([0-9]+)[.\)][[:space:]]+(.*)$ ]]; then
            local num=${BASH_REMATCH[1]} it=${BASH_REMATCH[2]}
            local pfx="$num. "; local pw=${#pfx} cpfx
            printf -v cpfx '%*s' "$pw" ''
            while (( i+1 < nn )); do
                local c2=${L[i+1]}; [[ -z ${c2//[[:space:]]/} ]] && break
                local c2b=${c2#"${c2%%[![:space:]]*}"}
                [[ $c2b =~ ^[0-9]+[.\)][[:space:]] ]] && break
                [[ $c2 == ' '* ]] || break
                it+=" $c2b"; (( i++ ))
            done
            _md_para "$it" "$pfx" "$cpfx"
            (( i++ )); continue
        fi

        # paragraph: gather consecutive "plain" lines, join with a space
        local para=$body
        while (( i+1 < nn )); do
            local c2=${L[i+1]}; local c2b=${c2#"${c2%%[![:space:]]*}"}
            [[ -z $c2b ]] && break
            [[ $c2b == '#'* || $c2b == '>'* || $c2b == '```'* || $c2b == '~~~'* ]] && break
            [[ $c2b == '- '* || $c2b == '* '* || $c2b == '+ '* ]] && break
            [[ $c2b =~ ^[0-9]+[.\)][[:space:]] ]] && break
            [[ $c2b == *'|'* ]] && (( i+2 < nn )) && _md_is_sep "${L[i+2]}" && break
            para+=" $c2b"; (( i++ ))
        done
        _md_para "$para" "" ""
        (( i++ ))
    done
    (( ${#FT_MARKDOWN_LINES[@]} == 0 )) && _md_blank
}
