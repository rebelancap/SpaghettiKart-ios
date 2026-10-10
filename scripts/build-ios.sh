#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build-ios"
PREFIX="$ROOT/work/ios-deps/prefix"
SHIP_O2R="$ROOT/oracle/build-cmake/spaghetti.o2r"
TEAM="${SOH_IOS_TEAM:?set your Apple Developer team id (see README)}"
CONSOLE="${SOH_REMOTE_CONSOLE:-ON}"

[[ -d "$ROOT/vendor/SpaghettiKart/.git" ]] || "$ROOT/scripts/bootstrap.sh"
"$ROOT/scripts/apply-overlay.sh"
[[ -f "$PREFIX/lib/libvorbisfile.a" ]] || "$ROOT/scripts/build-audio-deps-ios.sh"
[[ -f "$SHIP_O2R" ]] || { echo "FATAL: no spaghetti.o2r — run build-oracle.sh + extract-mk64-o2r.sh" >&2; exit 1; }

rm -rf "$BUILD/Release-iphoneos" "$BUILD/Spaghettify.xcarchive" "$BUILD/export"

PMAP="-ffile-prefix-map=$ROOT=. -ffile-prefix-map=$ROOT/vendor/SpaghettiKart=src"
mkdir -p "$BUILD"
printf 'add_compile_options(%s)\n' "$PMAP" > "$BUILD/prefix-map-torch.cmake"

cmake --no-warn-unused-cli -S "$ROOT/vendor/SpaghettiKart" -B "$BUILD" -GXcode \
    -DCMAKE_XCODE_ATTRIBUTE_STRIP_INSTALLED_PRODUCT=NO \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=16.4 -DDEPLOYMENT_TARGET=16.4 \
    "-DCMAKE_C_FLAGS=$PMAP" "-DCMAKE_CXX_FLAGS=$PMAP" \
    "-DCMAKE_OBJC_FLAGS=$PMAP" "-DCMAKE_OBJCXX_FLAGS=$PMAP" \
    "-DCMAKE_PROJECT_torch_INCLUDE=$BUILD/prefix-map-torch.cmake" \
    -DCMAKE_BUILD_TYPE:STRING=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_IGNORE_PREFIX_PATH="$HOME/Miniforge3" \
    "-DSOH_IOS_DEPS_PREFIX=$PREFIX" \
    "-DSOH_O2R_PATH=$SHIP_O2R" \
    "-DSOH_IOS_SHELL_DIR=$ROOT/app/ios" \
    "-DSOH_REMOTE_CONSOLE=$CONSOLE" \
    -DSOH_IOS_BUNDLE_IDENTIFIER=com.rebelancap.spaghettikart \
    "-DSOH_IOS_DEVELOPMENT_TEAM=$TEAM"

cmake --build "$BUILD" --config Release --target Spaghettify --parallel 6 -- -allowProvisioningUpdates

APP="$BUILD/Release-iphoneos/Spaghettify.app"
[[ -d "$APP" ]] || { echo "FATAL: expected app at $APP" >&2; exit 1; }
codesign -dv "$APP" 2>&1 | sed -n '1,3p'
echo "built: $APP"
