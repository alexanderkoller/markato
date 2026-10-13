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
<section><h1>Markato print test</h1><p>First page content.</p></section>
<section style="margin-top:900px"><h2>Second page</h2><p>Selectable PDF text.</p></section>
</main></body></html>
HTML
"$renderer" "$input" "$output" 595 842 54 54 54 54
pages="$(pdfinfo "$output" | awk '/^Pages:/ {print $2}')"
size="$(stat -f '%z' "$output")"
text="$(pdftotext "$output" -)"
[[ "$pages" == 2 ]]
[[ "$size" -lt 1000000 ]]
[[ "$text" == *"Markato print test"* ]]
[[ "$text" == *"Selectable PDF text."* ]]
echo "PRINT RENDERER: pages=$pages, bytes=$size, selectableText=true"
