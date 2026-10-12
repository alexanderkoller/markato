#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep bundled C dependencies (Oniguruma) compatible with the app's minimum OS.
export MACOSX_DEPLOYMENT_TARGET=15.0
cargo build --release --locked --manifest-path Native/Comrak/Cargo.toml --target-dir .build/comrak
