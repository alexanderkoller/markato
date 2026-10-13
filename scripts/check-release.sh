#!/bin/bash
# Inspect the packaged artifact, rather than trusting build configuration alone.
set -euo pipefail
app_path="${1:?Usage: bash scripts/check-release.sh /path/to/Markato.app}"
binary="$app_path/Contents/MacOS/Markato"
for inspect in symbols strings; do
    if [[ "$inspect" == symbols ]]; then
        captured="$(nm -j "$binary")"
    else
        captured="$(strings -a "$binary")"
    fi
    if printf '%s\n' "$captured" | rg 'astra_timing_|IntegrationCheck|TimingDiagnostics|INTEGRATION FAILED|MERMAID INTEGRATION|HIGHLIGHT INTEGRATION|SMOKE:|STARTUP:|SECOND OPEN:|MARKATO_INTEGRATION_DEFAULT_STARTUP|--integration-test|--integration-startup|--integration-finder-document|--integration-second-document|--integration-mermaid|--integration-highlighting|--integration-preview-jump|--smoke-test|--diagnostics|debugGeometry|patchCount|debugMeasuredPosition'; then
        echo "Release contains development $inspect" >&2
        exit 1
    fi
done
if otool -L "$binary" | rg '/(XCTest|Testing)\.framework/|lib(XCTest|Testing)'; then
    echo "Release links a testing framework" >&2
    exit 1
fi
if find "$app_path" -type f | rg '\.(swift|json|o)$|\.(xctest|dSYM)(/|$)|/(Tests|research|outputs)/'; then
    echo "Release contains development files" >&2
    exit 1
fi
while IFS= read -r resource; do
    relative="${resource#"$app_path/Contents/Resources/"}"
    case "$relative" in
        Example.md|ExampleImage.png|Markato.icns|ThirdPartyNotices/*.txt|ThirdPartyNotices/Ultralight/*) ;;
        Ultralight/resources/*) ;;
        Markato_HTMLPreview.bundle/Info.plist|Markato_HTMLPreview.bundle/*.css) ;;
        Markato_HTMLPreview.bundle/Contents/Info.plist|Markato_HTMLPreview.bundle/Contents/Resources/*.css) ;;
        Markato_MarkdownCore.bundle/Contents/Info.plist|Markato_MarkdownCore.bundle/Info.plist) ;;
        Markato_MarkdownCore.bundle/Contents/Resources/katex.js) ;;
        Markato_MarkdownCore.bundle/katex.js) ;;
        Markato_MarkdownCore.bundle/Contents/_CodeSignature/CodeResources) ;;
        *) echo "Unexpected release resource: $relative" >&2; exit 1 ;;
    esac
done < <(find "$app_path/Contents/Resources" -type f)
echo "Release audit passed: no test runner, test controls, recorder, or development artifacts."
