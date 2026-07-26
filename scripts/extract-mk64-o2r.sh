#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/SpaghettiKart"
BUILD="$ROOT/oracle/build-cmake"
TORCH="$BUILD/TorchExternal/src/TorchExternal-build/torch"
ROM="$ROOT/work/gamedata/mk64.us.z64"

[[ -f "$ROM" ]] || { echo "FATAL: ROM missing at $ROM" >&2; exit 1; }
[[ -x "$TORCH" ]] || { echo "FATAL: standalone torch not built — run scripts/build-oracle.sh" >&2; exit 1; }

EXPECTED="579c48e211ae952530ffc8738709f078d5dd215e"
ACTUAL="$(shasum -a 1 "$ROM" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo "FATAL: ROM sha1 $ACTUAL != supported US $EXPECTED" >&2; exit 1; }

cp -f "$ROM" "$VENDOR/baserom.us.z64"

cd "$VENDOR"
time "$TORCH" o2r baserom.us.z64 --additional-files meta/mods.toml
"$TORCH" pack assets spaghetti.o2r o2r

for f in mk64.o2r spaghetti.o2r; do
    [[ -s "$VENDOR/$f" ]] || { echo "FATAL: $f missing/empty in vendor root" >&2; exit 1; }
    cp -f "$VENDOR/$f" "$BUILD/$f"
    ls -la "$BUILD/$f"
done

DIRT="$(git -C "$VENDOR" status --porcelain | grep -vE '^ M CMakeLists\.txt$|^ M torch$' || true)"
TORCH_DIRT="$(git -C "$VENDOR/torch" status --porcelain | grep -vE '^ M CMakeLists\.txt$' || true)"
TORCH_SHA="$(git -C "$VENDOR/torch" rev-parse HEAD)"
if [[ -n "$DIRT" || -n "$TORCH_DIRT" || "$TORCH_SHA" != "2d474ddb8da8b213fbdbb49d0273ce31fa955f35" ]]; then
    echo "FATAL: extraction dirtied vendor beyond the overlay:" >&2
    echo "vendor: $DIRT" >&2
    echo "torch:  $TORCH_DIRT (HEAD $TORCH_SHA)" >&2
    exit 1
fi
echo "vendor pristine (overlay-only modifications)"
