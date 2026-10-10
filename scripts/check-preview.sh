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
exec dist/debug/AstraMarkdown.app/Contents/MacOS/AstraMarkdown --integration-test --diagnostics
