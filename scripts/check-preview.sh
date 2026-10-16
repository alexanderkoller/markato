#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# The native checks require a macOS graphical session.
npm --prefix Parser test
bash scripts/build-native.sh
cargo test --locked --manifest-path Native/Comrak/Cargo.toml --target-dir .build/comrak
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
swift test -c release --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
bash scripts/build-app.sh release
bash scripts/build-app.sh debug
dist/debug/Markato.app/Contents/MacOS/Markato --integration-test --integration-mermaid
dist/debug/Markato.app/Contents/MacOS/Markato --integration-test --integration-highlighting
dist/debug/Markato.app/Contents/MacOS/Markato --integration-test --integration-empty-edits
dist/debug/Markato.app/Contents/MacOS/Markato --integration-test --integration-comments
dist/debug/Markato.app/Contents/MacOS/Markato --integration-test --integration-comment-edit-stability
dist/debug/Markato.app/Contents/MacOS/Markato --integration-test --integration-paragraph-edit-stability
dist/debug/Markato.app/Contents/MacOS/Markato --integration-test --integration-height-stability
dist/debug/Markato.app/Contents/MacOS/Markato --integration-test --integration-delayed-image-stability
dist/debug/Markato.app/Contents/MacOS/Markato --integration-test --integration-delayed-image-bottom
dist/debug/Markato.app/Contents/MacOS/Markato --integration-test --integration-delayed-image-bottom-untouched
dist/debug/Markato.app/Contents/MacOS/Markato --integration-test --integration-scroll-throughput
dist/debug/Markato.app/Contents/MacOS/Markato --integration-test --integration-preview-jump
exec dist/debug/Markato.app/Contents/MacOS/Markato --integration-test --diagnostics
