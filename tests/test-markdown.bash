#!/usr/bin/env bash
# Tests for ft-markdown.bash — the rich-text renderer behind markdown=true fields.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./fruity-tui.bash; ft_init 2>/dev/null || true

PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then (( PASS++ )); else (( FAIL++ )); echo "  FAIL $1: got [$2] want [$3]"; fi; }
note()  { echo "• $1"; }
# does any rendered line contain the (plain-text) needle?
has() { local needle=$1 ln; for ln in "${FT_MARKDOWN_LINES[@]}"; do [[ "$ln" == *"$needle"* ]] && return 0; done; return 1; }
# strip ANSI/OSC for plain-text matching
plain_has() { local needle=$1 ln p; for ln in "${FT_MARKDOWN_LINES[@]}"; do ft_display_width "$ln"; p=$(printf '%s' "$ln" | sed $'s/\e\\[[0-9;]*m//g; s/\e\\]8;;[^\a]*\a//g'); [[ "$p" == *"$needle"* ]] && return 0; done; return 1; }
widths_ok() { local ln bad=0; for ln in "${FT_MARKDOWN_LINES[@]}"; do ft_display_width "$ln"; (( FT_DISPLAY_WIDTH > _MD_W )) && bad=1; done; return $bad; }

note "headings: # → bold text + a rule underneath"
ft_markdown "# Title" 40
check "h1 line count (title + rule)" "${#FT_MARKDOWN_LINES[@]}" 2
case "${FT_MARKDOWN_LINES[0]}" in *$'\e[1m'*) check "h1 is bold" 1 1 ;; *) check "h1 is bold" 0 1 ;; esac
plain_has "Title" && check "h1 keeps its text" 1 1 || check "h1 keeps its text" 0 1

note "inline styles: bold / italic / code"
ft_markdown "a **b** c *d* e \`f\`" 40
case "${FT_MARKDOWN_LINES[0]}" in *$'\e[1m'b$'\e[22m'*)  check "**bold** → SGR 1/22"   1 1 ;; *) check "**bold** → SGR 1/22" 0 1 ;; esac
case "${FT_MARKDOWN_LINES[0]}" in *$'\e[3m'd$'\e[23m'*)  check "*italic* → SGR 3/23"   1 1 ;; *) check "*italic* → SGR 3/23" 0 1 ;; esac
case "${FT_MARKDOWN_LINES[0]}" in *$'\e[7m'f$'\e[27m'*)  check "\`code\` → reverse 7/27" 1 1 ;; *) check "code → reverse 7/27" 0 1 ;; esac

note "links: [text](url) → an OSC-8 hyperlink around the text"
ft_markdown "see [docs](https://x.io)" 40
case "${FT_MARKDOWN_LINES[0]}" in *$'\e]8;;https://x.io\e\\'*) check "OSC-8 open with the URL" 1 1 ;; *) check "OSC-8 open" 0 1 ;; esac
case "${FT_MARKDOWN_LINES[0]}" in *$'\e]8;;\e\\'*)             check "OSC-8 close (empty URL)" 1 1 ;; *) check "OSC-8 close" 0 1 ;; esac
plain_has "docs" && check "link text is visible" 1 1 || check "link text visible" 0 1

note "escapes: \\* is a literal asterisk, not emphasis"
ft_markdown 'a \*b\* c' 40
plain_has "*b*" && check "escaped asterisks stay literal" 1 1 || check "escaped asterisks" 0 1

note "thematic break --- → a full-width rule"
ft_markdown "---" 12
check "hr is one line"        "${#FT_MARKDOWN_LINES[@]}" 1
ft_display_width "${FT_MARKDOWN_LINES[0]}"; check "hr fills the width" "$FT_DISPLAY_WIDTH" 12

note "bullet list wraps with a hanging indent"
ft_markdown "- one two three four five six seven eight nine ten" 20
(( ${#FT_MARKDOWN_LINES[@]} >= 2 )) && check "long bullet wrapped" 1 1 || check "long bullet wrapped" 0 1
case "${FT_MARKDOWN_LINES[0]}" in '•'*) check "bullet marker on line 1" 1 1 ;; *) check "bullet marker" 0 1 ;; esac
case "${FT_MARKDOWN_LINES[1]}" in '  '*) check "continuation is indented" 1 1 ;; *) check "continuation indented" 0 1 ;; esac

note "ordered list keeps its number"
ft_markdown $'1. first\n2. second' 30
plain_has "1. first"  && check "ordered item 1" 1 1 || check "ordered item 1" 0 1
plain_has "2. second" && check "ordered item 2" 1 1 || check "ordered item 2" 0 1

note "block quote gets a │ rail"
ft_markdown "> quoted" 30
case "${FT_MARKDOWN_LINES[0]}" in "$FT_GLYPH_VERTICAL"*) check "quote rail" 1 1 ;; *) check "quote rail" 0 1 ;; esac

note "fenced code is verbatim + dim, no inline parsing"
ft_markdown $'```\nx = **not bold**\n```' 40
plain_has 'x = **not bold**' && check "code fence keeps raw markers" 1 1 || check "code fence raw" 0 1

note "TABLES — the headline feature: box-drawn, aligned, header ruled"
TBL='| Name | Qty | Price |
|:-----|:---:|------:|
| Apple | 3 | 1.20 |
| Fig | 12 | 9.00 |'
ft_markdown "$TBL" 40
has "$FT_GLYPH_TOP_LEFT" && check "table top-left corner"    1 1 || check "table top-left corner" 0 1
has "$FT_GLYPH_TEE_DOWN" && check "table top tee (columns)" 1 1 || check "table top tee" 0 1
has "$FT_GLYPH_CROSS" && check "table header-rule cross" 1 1 || check "table header cross" 0 1
has "$FT_GLYPH_BOTTOM_LEFT" && check "table bottom-left corner"   1 1 || check "table bottom-left corner" 0 1
plain_has "Name" && check "table header cell" 1 1 || check "table header cell" 0 1
plain_has "Apple" && check "table data cell"  1 1 || check "table data cell" 0 1
widths_ok && check "every table line is within width" 1 1 || check "table within width" 0 1

note "width contract: NO rendered line ever exceeds the requested width"
ft_markdown "$TBL"$'\n\n'"a very long paragraph that certainly must wrap several times at a narrow width to stay in bounds" 24
_MD_W=24; widths_ok && check "all lines <= width (narrow)" 1 1 || check "all lines <= width" 0 1

note "empty input still yields one (blank) line"
ft_markdown "" 10
check "empty → 1 blank line" "${#FT_MARKDOWN_LINES[@]}" 1

echo
echo "$PASS/$(( PASS + FAIL )) assertions passed"
(( FAIL == 0 ))
