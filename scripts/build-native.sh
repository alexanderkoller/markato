#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cargo build --release --locked --manifest-path Native/Comrak/Cargo.toml --target-dir .build/comrak

