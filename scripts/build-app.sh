#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_configuration="${1:-release}"
if [[ "$build_configuration" != release && "$build_configuration" != debug ]]; then
    echo "Usage: bash scripts/build-app.sh [release|debug]" >&2
    exit 2
fi
swift build -c "$build_configuration" --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
app_path="$PWD/dist/AstraMarkdown.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp App/Info.plist "$app_path/Contents/Info.plist"
cp ".build/$build_configuration/AstraMarkdown" "$app_path/Contents/MacOS/"
cp -R App/Resources/. "$app_path/Contents/Resources/"
cp -R ".build/$build_configuration/AstraMarkdown_MarkdownCore.bundle" "$app_path/Contents/Resources/"
# Remove resources belonging to the replaced native preview dependencies.
rm -rf "$app_path/Contents/Resources/textual_Textual.bundle" "$app_path/Contents/Resources/swiftui-math_SwiftUIMath.bundle"
for obsolete_notice in Textual SwiftUIMath MathFonts ConcurrencyExtras; do
    rm -f "$app_path/Contents/Resources/ThirdPartyNotices/$obsolete_notice.txt"
done
codesign --force --deep --sign - "$app_path"
echo "$app_path"
