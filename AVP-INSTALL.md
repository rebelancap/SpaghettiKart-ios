# Installing SpaghettiKart on Apple Vision Pro

This is an iOS and visionOS build of [SpaghettiKart](https://github.com/HarbourMasters/SpaghettiKart), Harbour Masters' native Mario Kart 64 port, on [libultraship](https://github.com/HarbourMasters/libultraship), rendering natively on Metal. On Apple Vision Pro it runs in a freely resizable 2D window, and a stereoscopic 3D mode puts the race on a world-locked panel floating in your room.

## What you need

- Apple Vision Pro on visionOS 2 or later
- Your own Mario Kart 64 ROM
- For the prebuilt app: SideStore on the headset, installed with the [visionOS fork of iloader](https://github.com/rebelancap/iloader/releases#release-visionos) on an Apple Silicon Mac
- To build from source: macOS with Xcode and `cmake` (`brew install cmake`)
- Optional: a game controller (Backbone, DualSense, Xbox and others). The window also shows the on-screen touch layout.

## Your game files

Neither this repository nor the app contains any game content. You supply your own Mario Kart 64 ROM.

1. Install the app and open it.
2. The app walks you through adding your ROM on first launch. Extraction runs inside the app on the headset; no PC tools or companion app are needed.

Texture packs and other `.o2r` mods are optional; the 4K pack is recommended for the Vision Pro 3D mode. Copy the `.o2r` into *On My Apple Vision Pro → SpaghettiKart → mods* in the Files app, relaunch, and turn on **Use Alternate Assets** in the game's menu. Keep plenty of free space and install one pack at a time. See [Texture packs](README.md#texture-packs-strongly-recommended) in the README.

## Install the prebuilt app

1. Install SideStore on the headset with the [visionOS fork of iloader](https://github.com/rebelancap/iloader/releases#release-visionos). It runs on an Apple Silicon Mac and pairs with the headset over Wi-Fi: no cable, no Dev Strap, no Xcode.
2. In SideStore, go to *Sources → +* and paste this source, then install SpaghettiKart:

   ```
   https://raw.githubusercontent.com/rebelancap/harbourmasters-ports/main/apps-visionos.json
   ```

   The app updates from this source when new versions ship.

To install by hand instead, download `spaghettikart-*-visionOS.ipa` from the [latest release](https://github.com/rebelancap/SpaghettiKart-ios/releases/latest) and install it through SideStore or AltStore.

## Build from source

From a checkout of this repo:

```sh
scripts/bootstrap.sh          # clone + pin upstream SpaghettiKart (submodules recursive)
scripts/build-oracle.sh       # native macOS build
scripts/extract-mk64-o2r.sh   # builds mk64.o2r from your ROM, and spaghetti.o2r
SOH_IOS_TEAM=<your team ID> scripts/build-visionos.sh   # signed Apple Vision Pro build
```

`scripts/build-visionos.sh` needs `spaghetti.o2r`, which `scripts/extract-mk64-o2r.sh` produces. That script reads your ROM from `work/gamedata/mk64.us.z64` and checks it is the supported US version (by SHA-1). The build script takes your Apple Developer team ID from `SOH_IOS_TEAM` and writes the app to `build-visionos/Release-xros/Spaghettify.app`.

Upstream SpaghettiKart is vendored unmodified and pinned by commit. Every local change is a patch in `overlay/patches/`, applied by `scripts/apply-overlay.sh`; a patch that fails to apply fails the build. Simulator and iPhone builds are in [Building from source](README.md#building-from-source).

## Notes

- The 3D mode has live settings for stereo depth, focus, screen size, distance and height, and surroundings dimming, plus a recenter button.
- Apps sideloaded with a free Apple account expire after 7 days (paid developer accounts last a year). SideStore refreshes them in the background; if the app stops launching, open SideStore and let it re-sign.
- If the app crashes, it writes `crash.txt` and a `logs/` folder to *On My Apple Vision Pro → SpaghettiKart* in Files. Attach them to a [GitHub issue](https://github.com/rebelancap/SpaghettiKart-ios/issues).
- MARIO KART 64 is © Nintendo. This project is not affiliated with or endorsed by Nintendo, and ships no Nintendo content.
