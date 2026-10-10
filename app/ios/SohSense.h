// SohSense.h — PSVR2 Sense controllers on visionOS (VR-spec D13 / D9).
//
// Discovery + poses + a FIXED kart-native N64 layout, plus the physical item
// gestures the user asked for (throw forward / over the shoulder, item in hand,
// trailing hold, and the wrist mirror). The recipe is sm64coopdx-ios's shipped
// A10 backend, ported: GameController for buttons/sticks/haptics, ARKit
// accessory tracking for poses, one release-everything path on doff.
//
// EVERYTHING here compiles unconditionally into the visionOS target. The paths
// that need real hardware are gated at runtime and reported by the `vr hands`
// dump, which reads "absent" gracefully in the simulator — where the entire
// gesture layer is still exercised through pose/button INJECTION.
#pragma once

#import <ARKit/ARKit.h>
#import <simd/simd.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { SOHSENSE_LEFT = 0, SOHSENSE_RIGHT = 1, SOHSENSE_HANDS = 2 };

// --- lifecycle ---------------------------------------------------------------
// Called from the VR loop. Providers are attached BEFORE ar_session_run: the
// accessory-tracking provider has to ride the same session as world tracking or
// its poses are in a different origin frame.
ar_data_providers_t SohSense_MakeProviders(ar_world_tracking_provider_t wtp);
void SohSense_Start(void);                       // VR half on (poses + frame controls)
void SohSense_Stop(void);                        // VR half off; the flat fold survives
void SohSense_Update(double presTime, simd_float4x4 originFromHead, int worldFrame);

// VR R16-D — THE FLAT FOLD. Until this round the Sense layer existed only inside
// the VR immersive loop, so in the flat window and in the 3D panel the pair fell
// through to SDL's MFi auto-mapper, which matches a spatial controller's element
// names on three of its buttons and nothing else ("only the A button works").
//
//   SohSense_StartInput  discovery + the connect/disconnect observers. No ARKit,
//                        no immersive space, no authorization in its path.
//                        Called once at shell launch on visionOS; idempotent.
//   SohSense_PumpFlat    the per-frame HARDWARE READ, and only that — never
//                        sohsense_frame_controls, which cycles VR views. Called
//                        from the shell's pad seam every frame in every mode;
//                        it no-ops while the VR loop is doing the reading.
//   SohSense_FlatFoldLive  1 while the flat fold is driving a REAL spatial pair
//                        (not an injected one) — the touch overlay's presence
//                        test asks this, so the on-screen pad yields to the
//                        Sense controllers in 2D exactly as it does to a gamepad.
void SohSense_StartInput(void);
void SohSense_PumpFlat(void);
int SohSense_FlatFoldLive(void);

// 1 while a Sense controller is connected or a hand pose is live (injected
// counts). The pad-layer presence predicate and the SDL filter both read it, so
// they can never disagree about whether the native backend is in charge.
int SohSense_Active(void);
int SohSense_IsSpatialController(void* gcController);

// The FIXED N64 layout, applied at MK64's own read_controllers seam (overlay
// 0053) — ORed onto the pad the normal path already produced, with no LUS
// binding layer in between. Buttons are N64 bits; the stick is only written
// when the Sense stick is actually deflected.
void SohSense_WritePad(unsigned short* button, signed char* stickX, signed char* stickY);

// --- poses (ARKit origin frame, column-vector like everything in the loop) ---
int SohSense_HandPose(int hand, simd_float4x4* outOriginFromHand);
int SohSense_ItemHand(void);                     // which hand carries the item
int SohSense_ItemHandPose(simd_float4x4* outOriginFromHand);

// --- the features the compositor asks about each frame -----------------------
int SohSense_ItemInHandVisible(void);            // draw the held-item billboard
int SohSense_WristMirrorActive(void);            // D13: watch-check gesture
int SohSense_WristMirrorPose(simd_float4x4* outOriginFromPlane);
// R14 item 3: the LEFT-HAND pane's pose — R4's wrist plane with the watch-check
// gesture's three threshold tests removed and a short last-good hold added, so
// a toggled-on pane rides the controller continuously instead of appearing and
// vanishing on wrist angle. Returns 0 only when the controller has been out of
// tracking for longer than the hold.
int SohSense_LeftPanePose(simd_float4x4* outOriginFromPlane);
unsigned int SohSense_PaneHoldFrames(void);
int SohSense_ArmedItem(void);                    // MK64's armed item (0053)
float SohSense_ItemScale(void);                  // metres, the held billboard
float SohSense_WristScale(void);                 // wrist pane size fraction

// --- haptics (per hand; no-ops when the hand is absent) ----------------------
void SohSense_Haptic(int hand, float intensity, float seconds);
void SohSense_HapticBoth(float intensity, float seconds);
void SohSense_EngineRumble(float strength, float seconds); // engine -> both hands

// --- tunables (every one of them a `vr set` key — they WILL be retuned) ------
int SohSense_SetTunable(const char* key, float value); // 1 = key known
float SohSense_GetTunable(const char* key);

// --- injection (D11 harness: the gesture layer is fully assertable headless) -
void SohSense_InjectHand(int hand, float x, float y, float z, float yawDeg, float pitchDeg, float rollDeg);
void SohSense_InjectVelocity(int hand, float vx, float vy, float vz);
void SohSense_InjectButton(int hand, const char* name, int down);
void SohSense_InjectStick(int hand, float x, float y);
void SohSense_InjectClear(void);
void SohSense_InjectDoff(void);                  // "both controllers went away"

// --- dump --------------------------------------------------------------------
const char* SohSense_Dump(void);

#ifdef __cplusplus
}
#endif
