#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/SpaghettiKart"
BUILD="$ROOT/oracle/build-cmake"

"$ROOT/scripts/apply-overlay.sh"

cmake -S "$VENDOR" -B "$BUILD" -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_IGNORE_PREFIX_PATH="$HOME/Miniforge3"

cmake --build "$BUILD" -j 6

echo "oracle binary: $BUILD/Spaghettify"
