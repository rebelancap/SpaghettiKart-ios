#!/bin/bash
set -euo pipefail

PIN="d1dec0f6f437cf5342a8514f23741da9ded95485" # main, 1.0.0-29, 2026-06-29
REPO="https://github.com/HarbourMasters/SpaghettiKart.git"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/SpaghettiKart"

if [[ ! -d "$VENDOR/.git" ]]; then
    git clone --recurse-submodules "$REPO" "$VENDOR"
fi
git -C "$VENDOR" fetch --tags origin
git -C "$VENDOR" checkout --detach "$PIN"
git -C "$VENDOR" submodule update --init --recursive

echo "vendor pinned: $(git -C "$VENDOR" rev-parse HEAD)"
echo "submodules:"
git -C "$VENDOR" submodule status
