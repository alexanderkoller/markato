#!/bin/bash
# Regenerate all macOS icon representations from the approved transparent master.
set -euo pipefail
cd "$(dirname "$0")/.."
master="App/Branding/Markato-1024.png"
iconset="App/Branding/Markato.iconset"
mkdir -p "$iconset" docs/assets
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$master" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$master" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
# iconutil depends on IconServices, which can reject valid sets in a sandbox.
# Package the PNG representations directly; no service or external library needed.
python3 scripts/package-icon.py "$iconset" App/Resources/Markato.icns
sips -z 256 256 "$master" --out docs/assets/markato-icon.png >/dev/null
