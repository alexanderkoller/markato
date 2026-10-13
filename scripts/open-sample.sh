#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
open -n "$PWD/dist/Markato.app" --args --sample
