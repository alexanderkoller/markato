#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_configuration="${1:-release}"
if [[ "$build_configuration" != release && "$build_configuration" != debug ]]; then
    echo "Usage: bash scripts/build-app.sh [release|debug]" >&2
    exit 2
fi
bash scripts/build-native.sh
swift build -c "$build_configuration" --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
app_parent="$PWD/dist"
if [[ "$build_configuration" == debug ]]; then app_parent="$app_parent/debug"; fi
mkdir -p "$app_parent"
app_path="$app_parent/AstraMarkdown.app"
# Build a fresh bundle so switching configurations cannot retain test artifacts.
stage_dir="$(mktemp -d "$app_parent/.app-build.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
staged_app="$stage_dir/AstraMarkdown.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp App/Info.plist "$staged_app/Contents/Info.plist"
cp ".build/$build_configuration/AstraMarkdown" "$staged_app/Contents/MacOS/"
for resource in Preview.css Preview.js KaTeX.css Example.md ExampleImage.png; do
    cp "App/Resources/$resource" "$staged_app/Contents/Resources/"
done
cp -R App/Resources/ThirdPartyNotices "$staged_app/Contents/Resources/"
core_bundle="$staged_app/Contents/Resources/AstraMarkdown_MarkdownCore.bundle"
mkdir -p "$core_bundle/Contents/Resources"
cp ".build/$build_configuration/AstraMarkdown_MarkdownCore.bundle/Contents/Info.plist" "$core_bundle/Contents/Info.plist"
cp "Sources/MarkdownCore/Resources/katex.js" "$core_bundle/Contents/Resources/"
if [[ "$build_configuration" == release ]]; then
    # The source JS remains directly runnable in debug. Release omits its timing
    # blocks and optional measurement argument, without another JS build tool.
    awk '
        /\/\/ BEGIN DEBUG/ { debug_block=1; next }
        /\/\/ END DEBUG/ { debug_block=0; next }
        !debug_block { gsub(",measure=false", ""); print }
    ' App/Resources/Preview.js > "$staged_app/Contents/Resources/Preview.js"
    bash scripts/check-release.sh "$staged_app"
    strip -S "$staged_app/Contents/MacOS/AstraMarkdown"
fi
codesign --force --deep --sign - "$staged_app"
if [[ -e "$app_path" ]]; then mv "$app_path" "$stage_dir/previous.app"; fi
mv "$staged_app" "$app_path"
echo "$app_path"
