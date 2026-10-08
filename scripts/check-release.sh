#!/bin/bash
# Inspect the packaged artifact, rather than trusting build configuration alone.
set -euo pipefail
app_path="${1:?Usage: bash scripts/check-release.sh /path/to/AstraMarkdown.app}"
binary="$app_path/Contents/MacOS/AstraMarkdown"
for inspect in symbols strings; do
    if [[ "$inspect" == symbols ]]; then
        captured="$(nm -j "$binary")"
    else
        captured="$(strings -a "$binary")"
    fi
    if printf '%s\n' "$captured" | rg 'IntegrationCheck|TimingDiagnostics|INTEGRATION FAILED|SOURCE PAINT|SMOKE:|--integration-test|--integration-source-paint|--integration-preview-jump|--smoke-test|--diagnostics|scheduleBackgroundPreparation|debugGeometry|debugAlignmentDrift|debugScrollLandmarks|patchCount|parserRequests|highlightApplications|debugMeasuredPosition|FixtureScrollSource|HTMLWorker|astraLocal'; then
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
        Preview.css|Preview.js|KaTeX.css|Example.md|ExampleImage.png|ThirdPartyNotices/*.txt) ;;
        AstraMarkdown_MarkdownCore.bundle/Contents/Info.plist|AstraMarkdown_MarkdownCore.bundle/Info.plist) ;;
        AstraMarkdown_MarkdownCore.bundle/Contents/Resources/lezer.js) ;;
        AstraMarkdown_MarkdownCore.bundle/lezer.js) ;;
        AstraMarkdown_MarkdownCore.bundle/Contents/_CodeSignature/CodeResources) ;;
        *) echo "Unexpected release resource: $relative" >&2; exit 1 ;;
    esac
done < <(find "$app_path/Contents/Resources" -type f)
if rg 'BEGIN DEBUG|END DEBUG|performance\.now|patchMs|layoutMs|changedHTML|measure=false' "$app_path/Contents/Resources/Preview.js"; then
    echo "Release preview contains timing instrumentation" >&2
    exit 1
fi
echo "Release audit passed: no test runner, test controls, recorder, or development artifacts."
