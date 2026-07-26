#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/spikes/spaghetti-sim-build/Release-iphonesimulator/Spaghettify.app"
BUNDLE_ID="com.harbourmasters.spaghettikart"
UDID="DF37AC66-DF2D-493A-AA86-19CCD5B776A6" # SpaghettiKart-iPhone-Air (D4)
MK64="$ROOT/oracle/shiphome/mk64.o2r"
ROM="$ROOT/work/gamedata/mk64.us.z64"
SHOT="${1:-sim-boot}"
MODE="${2:-}"

[[ -d "$APP" ]] || { echo "FATAL: no sim app at $APP — run scripts/build-sim.sh" >&2; exit 1; }

xcrun simctl bootstatus "$UDID" -b   # boots if needed, waits until ready
xcrun simctl install "$UDID" "$APP"

CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)
mkdir -p "$CONTAINER/Documents"
if [[ "$MODE" == "--rom-only" ]]; then
    rm -f "$CONTAINER/Documents/mk64.o2r"
    cp "$ROM" "$CONTAINER/Documents/baserom.us.z64"
    echo "seeded baserom.us.z64 (extraction path) into $CONTAINER/Documents"
else
    [[ -f "$MK64" ]] || { echo "FATAL: no mk64.o2r — run scripts/extract-mk64-o2r.sh" >&2; exit 1; }
    cp "$MK64" "$CONTAINER/Documents/mk64.o2r"
    echo "seeded mk64.o2r into $CONTAINER/Documents"
fi

xcrun simctl launch "$UDID" "$BUNDLE_ID" || true
echo "launched $BUNDLE_ID on sim; waiting for boot…"

for _ in $(seq 1 14); do
    grep -rq "Setup Race\|Loading Track" "$CONTAINER/Documents/logs" 2>/dev/null && break
    sleep 5
done

mkdir -p "$ROOT/artifacts"
xcrun simctl io "$UDID" screenshot "$ROOT/artifacts/$SHOT.png"
echo "captured artifacts/$SHOT.png"
sips -g pixelWidth -g pixelHeight "$ROOT/artifacts/$SHOT.png" 2>/dev/null | tail -2 || true

LOGDIR="$CONTAINER/Documents/logs"
if [[ -d "$LOGDIR" ]]; then
    rm -rf "$ROOT/artifacts/$SHOT-logs"
    cp -R "$LOGDIR" "$ROOT/artifacts/$SHOT-logs"
    echo "--- SOH_PERF (simulator, non-authoritative) ---"
    grep -h "SOH_PERF" "$ROOT/artifacts/$SHOT-logs"/* 2>/dev/null | tail -3 || echo "(no perf lines yet)"
fi
