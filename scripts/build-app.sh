#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_configuration="${1:-release}"
if [[ "$build_configuration" != release && "$build_configuration" != debug ]]; then
    echo "Usage: bash scripts/build-app.sh [release|debug]" >&2
    exit 2
fi
bash scripts/build-icons.sh
bash scripts/build-native.sh
default_ultralight_sdk="$PWD/Vendor/Ultralight"
ultralight_sdk="${ASTRA_ULTRALIGHT_SDK:-$default_ultralight_sdk}"
if [[ ! -f "$ultralight_sdk/bin/libUltralight.dylib" || ! -f "$ultralight_sdk/resources/icudt67l.dat" ]]; then
    echo "Ultralight SDK not found at $ultralight_sdk (set ASTRA_ULTRALIGHT_SDK)" >&2
    exit 1
fi
export ASTRA_ULTRALIGHT_SDK="$ultralight_sdk"
swift build -c "$build_configuration" --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
app_parent="$PWD/dist"
if [[ "$build_configuration" == debug ]]; then app_parent="$app_parent/debug"; fi
mkdir -p "$app_parent"
app_path="$app_parent/Markato.app"
# Build a fresh bundle so switching configurations cannot retain test artifacts.
stage_dir="$(mktemp -d "$app_parent/.app-build.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
staged_app="$stage_dir/Markato.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources" "$staged_app/Contents/Frameworks"
cp App/Info.plist "$staged_app/Contents/Info.plist"
cp ".build/$build_configuration/Markato" "$staged_app/Contents/MacOS/"
for resource in Example.md ExampleImage.png Markato.icns; do
    cp "App/Resources/$resource" "$staged_app/Contents/Resources/"
done
cp -R App/Resources/ThirdPartyNotices "$staged_app/Contents/Resources/"
cp "$ultralight_sdk/bin/"*.dylib "$staged_app/Contents/Frameworks/"
mkdir -p "$staged_app/Contents/Resources/Ultralight/resources" "$staged_app/Contents/Resources/ThirdPartyNotices/Ultralight"
cp "$ultralight_sdk/resources/"* "$staged_app/Contents/Resources/Ultralight/resources/"
cp "$ultralight_sdk/license/"* "$staged_app/Contents/Resources/ThirdPartyNotices/Ultralight/"
core_bundle="$staged_app/Contents/Resources/Markato_MarkdownCore.bundle"
mkdir -p "$core_bundle/Contents/Resources"
cp ".build/$build_configuration/Markato_MarkdownCore.bundle/Contents/Info.plist" "$core_bundle/Contents/Info.plist"
cp "Sources/MarkdownCore/Resources/katex.js" "$core_bundle/Contents/Resources/"
cp -R ".build/$build_configuration/Markato_HTMLPreview.bundle" "$staged_app/Contents/Resources/"
if [[ "$build_configuration" == release ]]; then
    bash scripts/check-release.sh "$staged_app"
    strip -S "$staged_app/Contents/MacOS/Markato"
fi
codesign --force --deep --sign - "$staged_app"
if [[ -e "$app_path" ]]; then mv "$app_path" "$stage_dir/previous.app"; fi
mv "$staged_app" "$app_path"
echo "$app_path"
