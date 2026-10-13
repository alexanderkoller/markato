#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
renderer="${1:-.build/debug/MarkatoPrintRenderer}"
if [[ ! -x "$renderer" ]]; then
    echo "Print renderer is not executable: $renderer" >&2
    exit 2
fi
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/markato-print-check.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
input="$work_dir/input.html"
output="$work_dir/output.pdf"
cat > "$input" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><style>body { font: 16px system-ui; }</style></head>
<body><main id="preview">
<section><h1>Markato print test</h1><p>First page content.</p>
<div style="height:620px"></div>
<table><thead><tr><th>Boundary table</th><th>Value</th></tr></thead>
<tbody><tr><td>Alpha</td><td>1</td></tr><tr><td>Beta</td><td>2</td></tr><tr><td>Gamma</td><td>3</td></tr></tbody></table></section>
<section><h2>Second page</h2><p>Selectable PDF text.</p></section>
<section><h2>Tall table</h2><table><tbody>
<tr><td><div style="height:370px;display:flex;flex-direction:column;justify-content:space-between"><span>Tall row one start</span><span>Tall row one end</span></div></td></tr>
<tr><td><div style="height:370px;display:flex;flex-direction:column;justify-content:space-between"><span>Tall row two start</span><span>Tall row two end</span></div></td></tr>
<tr><td><div style="height:370px;display:flex;flex-direction:column;justify-content:space-between"><span>Tall row three start</span><span>Tall row three end</span></div></td></tr>
<tr><td><div style="height:370px;display:flex;flex-direction:column;justify-content:space-between"><span>Tall row four start</span><span>Tall row four end</span></div></td></tr>
</tbody></table></section>
</main></body></html>
HTML
"$renderer" "$input" "$output" 595.275590551 841.88976378 42.5196850394 42.5196850394 42.5196850394 42.5196850394
metadata="$(pdfinfo "$output")"
pages="$(printf '%s\n' "$metadata" | awk '/^Pages:/ {print $2}')"
paper="$(printf '%s\n' "$metadata" | awk '/^Page size:/ {print $3 " x " $5 " pt"}')"
size="$(stat -f '%z' "$output")"
text="$(pdftotext "$output" -)"
second_page_text="$(pdftotext -f 2 -l 2 "$output" -)"
body_glyph_height="$(pdftotext -bbox "$output" - 2>/dev/null | awk -F'"' '/>First<\/word>/ {print $8-$4; exit}')"
font_xml="$(pdftohtml -xml -stdout "$output" 2>/dev/null)"
(( pages >= 3 && pages <= 6 ))
printf '%s\n' "$metadata" | awk '/^Page size:/ {exit !($3 > 595 && $3 < 596 && $5 > 841 && $5 < 842)}'
[[ "$size" -lt 1000000 ]]
[[ "$text" == *"Markato print test"* ]]
[[ "$text" == *"Selectable PDF text."* ]]
[[ "$second_page_text" == *"Boundary table"* ]]
[[ "$second_page_text" == *"Gamma"* ]]
for label in one two three four; do
    start_page="";end_page=""
    for ((page=1; page<=pages; page++)); do
        page_text="$(pdftotext -f "$page" -l "$page" "$output" -)"
        [[ "$page_text" == *"Tall row $label start"* ]] && start_page="$page"
        [[ "$page_text" == *"Tall row $label end"* ]] && end_page="$page"
    done
    [[ -n "$start_page" && "$start_page" == "$end_page" ]]
done
[[ "$font_xml" == *'size="11"'* ]]
awk -v height="$body_glyph_height" 'BEGIN {exit !(height >= 12 && height <= 13.5)}'
echo "PRINT RENDERER: pages=$pages, paper=$paper, margins=15mm, bodyFont=11pt, bodyGlyphBox=${body_glyph_height}pt, bytes=$size, selectableText=true"
