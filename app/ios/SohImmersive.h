// SohImmersive.h — visionOS stereoscopic "3D screen" mode (CompositorServices).
// Ported from the proven vkQuake-ios implementation (its VKQImmersive.m, itself
// descended from quake3e-ios D-019). See Shipwright-ios D-030.
#pragma once

#import <CompositorServices/CompositorServices.h>

#ifdef __cplusplus
extern "C" {
#endif

// The frame loop. Runs on a DEDICATED thread (main thread would block the
// engine's display-link pump). Returns when stopped or the layer invalidates.
void Soh3D_Immersive_Run(cp_layer_renderer_t layer_renderer);

// Stop/running handshake: set stop, then wait for running==0 BEFORE dismissing
// the immersive space (the loop must never touch a layerRenderer SwiftUI is
// tearing down).
extern volatile int gSoh3DStop;
extern volatile int gSoh3DRunning;

// Panel placement + tuning (live; called from settings and enter sequencing).
void Soh3D_SetPanel(float dist, float halfW, float halfH);
void Soh3D_SetHeight(float h);
void Soh3D_SetDim(float dim); // 0..1 UI scale; perceptual curve applied inside
void Soh3D_Recenter(void);    // re-capture the head anchor next tracked frame

// Engine bridge (Fast3D overlay; NULL/0 until the eye framebuffers exist —
// the loop shows a built-in test pattern so the compositor path is testable
// before the engine side lands).
void* Soh3D_GetEyeMTLTexture(int eye); // 1=left, 2=right; NULL = not ready
int Soh3D_GetEyeFrames(int eye);       // completed renders per eye (liveness)

// Shell reconcile when the system (Crown) dismisses the space out from under us.
void Soh3D_Immersive_Ended(void);

// --- VR core + diagnostics harness (VR-spec D2/D11) ----------------------
// Inert unless VR mode is entered: composes the A*V*P eye pair from the 0045
// camera basis, the head pose and the drawable's projection, and answers the
// bridge dump family on :8768. Every dump is one flat key=value line whose
// LAST field is a monotone sequence number.

// Mode (D1 tri-state). 0 = flat, 1 = 3D panel, 2 = VR. The panel path still
// owns gSoh3DMode; this is the VR-side view of the same state machine.
int SohVR_GetMode(void);
void SohVR_SetMode(int mode);

// Per-mode world placement (A of A*V*P). scale = game units per metre.
void SohVR_SetTunables(float scale, float dist, float height);
void SohVR_GetTunables(float* scale, float* dist, float* height);

// Synthetic pose injection (D11): makes the eye math answerable headless in
// the simulator, where CompositorServices reports views=1 with identity pose.
// Position in metres, yaw/pitch in degrees, in the ARKit origin frame.
void SohVR_InjectPose(float x, float y, float z, float yawDeg, float pitchDeg);
// R17-B: the same, with head ROLL — the axis nothing could inject before.
void SohVR_InjectPoseRoll(float x, float y, float z, float yawDeg, float pitchDeg, float rollDeg);
void SohVR_ClearInjectedPose(void);

// Recompute the eye pair from the current pose/contract/tunables. Returns the
// number of eyes composed (always 2 — the second is synthesized when the
// runtime reports a single view). Safe to call from any thread.
int SohVR_ComposeEyes(void);

// Row-vector (Fast3D convention) world->clip matrix for eye 1 (left) / 2
// (right), valid after SohVR_ComposeEyes. NULL for an out-of-range eye.
const float* SohVR_GetEyeMatrix(int eye);

// The VR frame loop (R1). Same contract as Soh3D_Immersive_Run — dedicated
// thread, stop/running handshake via gSoh3DStop/gSoh3DRunning — but it renders
// the head-tracked world per eye and falls back to the world-locked panel for
// non-gameplay frames (spec §5 R1, item 6).
void SohVR_Immersive_Run(cp_layer_renderer_t layer_renderer);

// Diorama placement extras beyond scale/dist/height: surroundings dim is the
// panel's Soh3D_SetDim; this is the VR-side eye render scale (D7 sizing).
void SohVR_SetRenderScale(float scale01);

// Live-tunable HUD plane (spec D6). Distance in metres ahead of the player,
// height in metres relative to eye level, scale multiplies the plane's size.
void SohVR_SetHudPlane(float dist, float height, float scale);
void SohVR_GetHudPlane(float* dist, float* height, float* scale);
// VR R10 addendum (the user, 1.0.0.6): "the VR HUD plane sits a little too low by
// default." The default is 8 cm higher in every mode now, and this pair backs
// the new "HUD height" row — metres above eye level in the CURRENT view mode,
// persisted per mode, displayed as a centimetre offset from that default.
// Both setters run the pane/HUD deconflict, so the rear-view pane can never be
// pushed into the HUD by either row.
void SohVR_SetHudHeightM(float h);
float SohVR_GetHudHeightM(void);

// Dump family. Caller owns nothing; the returned buffer is a static per-kind
// line, valid until the next call for that kind.
const char* SohVR_DumpPose(void);     // pose + eye matrices + IPD check
const char* SohVR_DumpMode(void);     // mode / arbitration state
const char* SohVR_DumpContract(void); // drawable contract + per-eye extents
const char* SohVR_DumpPacing(void);   // engine_fps / tick_tps / present cadence
const char* SohVR_DumpProj(void);     // R6: the RAW rebuilt per-eye projection

// R6 harness: force a tangent set so the ASYMMETRIC-frustum asserts run in the
// simulator (which only ever reports a symmetric one — the blind spot that let
// the device's off-centre frustum go five rounds without a test). Pass NULL
// arrays with on=0 to restore the drawable's own tangents.
void SohVR_ForceTangents(int on, const float* eye0, const float* eye1);
// Project an EYE-space point through eye e's rebuilt P; outNdc is x,y,z,w.
void SohVR_ProjectEyePoint(int eye, float x, float y, float z, float* outNdc);

// --- R6: the in-headset settings surface (SwiftUI ornament sheet) ------------
// The ImGui "Vision Pro VR" group is display-only in immersive (D-041), so the
// reachable surface is the ornament. These are its backing accessors.
int SohVR_ViewCount(void);
void SohVR_SetViewIndex(int v);
int SohVR_GetViewIndex(void);
const char* SohVR_GetViewName(void);
float SohVR_GetScale(void);
void SohVR_SetScale(float s);
void SohVR_SetSeat(float up, float fwd);
float SohVR_GetSeatUp(void);
float SohVR_GetSeatFwd(void);
void SohVR_SetDimLevel(float dim);
float SohVR_GetDimLevel(void);
void SohVR_SetFixedHorizon(int on);
int SohVR_GetFixedHorizon(void);
// VR R9 item 6: "Realistic Spins (intense)" — OFF = today's fixed-horizon
// comfort hold; ON = the view follows the kart through spin-outs and through
// the airborne hit-somersault. Persisted, default OFF.
// VR R10 item 5 supersedes this pair's meaning: "Realistic Spin-Out" is the
// in-plane 360 yaw follow and now DEFAULTS ON; the mid-air tumble moved to its
// own row below.
void SohVR_SetRealisticSpins(int on);
int SohVR_GetRealisticSpins(void);
// VR R10 item 5: "Realistic Flip-Out" — the composed roll + somersault when a
// shell or a bolt puts you in the air. Persisted, default OFF.
void SohVR_SetRealisticFlips(int on);
int SohVR_GetRealisticFlips(void);
// VR R9 item 4: the head-position leash (first person). Persisted, default ON.
// `Drift` is how far the head is from the seat baseline in metres; `Comp` is
// how much of that the world placement is currently cancelling.
void SohVR_SetHeadLock(int on);
int SohVR_GetHeadLock(void);
float SohVR_GetHeadLockDrift(void);
float SohVR_GetHeadLockComp(void);
// VR R9 item 1c: foveated engine rendering. `Cap` is whether the RUNTIME
// exposes a rasterization rate map at all — 0 in the simulator (trap D15), so
// the toggle is inert there and the full-resolution path runs. Persisted,
// default OFF this round; see docs/VR-R9-NOTES.md section A.1c.
void SohVR_SetFoveation(int on);
int SohVR_GetFoveation(void);
int SohVR_GetFoveationCap(void);
// VR R9 item 7 (diagnostic, not persisted): force the eye extent's aspect, so
// the simulator can render at the DEVICE's 1.246 and reproduce the LAP clip.
void SohVR_SetEyeAspectDbg(float ar);
float SohVR_GetEyeAspectDbg(void);
float SohVR_GetRenderScale(void);
float SohVR_GetEyeBudget(void);
void SohVR_SetEyeBudget(float px);
void SohVR_SetVrDbg(int level);
int SohVR_GetVrDbg(void);
// VR R10 item 2: THE DEVICE BISECT KIT. Ten independent rows, each disabling
// exactly one rainbow suspect, live and mid-race, ordered by prior probability
// (row 0 is the likeliest). `SohVR_GetDiag` returns 1 when the mechanism is ON
// (the shipping behaviour) — the settings toggles bind straight to it. Session
// state only: never persisted, because an archived diagnostic poisons the next
// A/B. See SohImmersive.m's kit header for the reasoning behind the ordering.
int SohVR_DiagCount(void);
const char* SohVR_DiagLabel(int bit);
const char* SohVR_DiagHelp(int bit);
int SohVR_GetDiag(int bit);
void SohVR_SetDiag(int bit, int on);
// R14 item 6: the Diagnostics group's visibility. 0 (shipping) hides the whole
// group — the bisect toggles, the counter captions, the crash line and the old
// bisect ladder — from the settings sheet. `vr set diagui 1` summons it for a
// dev round; the bridge is compiled out of public builds, so this is dev-only
// by construction. Session state, never persisted.
// R14 item 5: the hitch/jiggle correlation, as one readable sentence.
const char* SohVR_HitchLine(void);
int SohVR_GetDiagUI(void);
void SohVR_SetDiagUI(int on);
void SohVR_DiagResetAll(void);
int SohVR_DiagFindKey(const char* key);
const char* SohVR_DumpDiag(void);
// Compositor command-buffer failures — the cheapest GPU-side artefact signal
// there is, and one no screenshot can show. Reported on the settings page.
unsigned int SohVR_GetCbErrors(void);
// R11 item 1: the per-eye frame-tag mismatch counters (spec D11's
// independent assert). 0/0 is the only acceptable device reading.
unsigned int SohVR_GetEyeTagMiss(int e);
unsigned int SohVR_GetEyeTagChecks(int e);
void SohVR_Recenter(void);
// R14 item 3: the Rear View section's two rows. "Top" is the HUD-anchored pane
// (its in-race latch is the LEFT thumbstick click); "Left hand" is the
// wrist-style pane, always on while racing. Auto-show is gone.
void SohVR_SetMirrorTop(int on);
int SohVR_GetMirrorTop(void);
int SohVR_ToggleMirrorTop(void);
// R20 item 1's jumbotron feed switch. R21 item 1: no settings row, not
// persisted, always On at launch; `vr set jumbofeed 0` (session-only) = no
// jumbotron slice in VR world frames -- the device A/B for the rainbow flash.
void SohVR_SetJumboFeed(int on);
int SohVR_GetJumboFeed(void);
// R11 item 4 (the user, 1.0.0.7, FINAL): the pane's Side/Height/Distance/Size
// rows are DELETED and the placement is hardcoded — Side 0, Distance 150,
// Size 50 — with the height derived from the HUD row so the pane auto-rises
// with it. SohVR_PlacePane is the only writer; the getter remains for
// telemetry and the suite.
void SohVR_PlacePane(void);
void SohVR_GetMirrorPlane(float* x, float* y, float* dist, float* scale);
// R11 item 4: "Left hand" — the pane rides the left controller instead of its
// fixed place above the HUD. Persisted, default OFF.
void SohVR_SetMirrorLeftHand(int on);
int SohVR_GetMirrorLeftHand(void);
// R9b item 2: the per-mode placement pair behind the "Height"/"Zoom" rows.
// First person edits the SEAT, third person the chase offsets, Diorama the
// world height and the world SCALE (its zoom). All three persist per mode.
void SohVR_SetThird(float up, float back);
void SohVR_GetThird(float* up, float* back);
float SohVR_GetHeightM(void);  // metres, CURRENT view (A's world height)
void SohVR_SetHeightM(float h);
// R9b item 8: visionOS upper-limb (hands) visibility on the immersive space.
// Persisted, default OFF.
void SohVR_SetShowHands(int on);
int SohVR_GetShowHands(void);
// R9b item 4: the "VR Settings … Reset" header button. Restores every VR
// default in one call — all three modes' placement pairs, every toggle, the
// rear-view pane and the render quality — then persists.
void SohVR_ResetVRDefaults(void);
// R18-B item 2c: the first-person "Recalculate height" button — re-base the
// head on the live pose (Soh3D_Recenter), drop the head-lock compensation and
// re-apply the pinned seat (Height -5 / Zoom +5). Logs `[SohVR] recalc height`.
void SohVR_RecalcHeight(void);
unsigned int SohVR_RecalcCount(void);
// R9b: the memory instruments on the settings page (the user cannot type bridge
// commands in the headset, and the R9 retest opens by asking for these two).
float SohVR_GetFbMB(void);
unsigned int SohVR_GetAllocFails(void);
unsigned int SohVR_GetSlotShown(void);
float SohVR_GetKartDist(void);
float SohVR_GetGazeDot(void);
int SohVR_GetSeatFromKart(void);
// R7: the honest cockpit-lock measure (composed eye yaw - kart yaw, degrees),
// the engine rate and the live eye framebuffer size — all read by the in-VR
// settings page, because the user cannot type bridge commands in the headset.
float SohVR_GetCockpitErrDeg(void);
// R8: the independent steering check (A's kart forward vs the GAME CAMERA's
// world forward, degrees). ~0 = the convention is right; a mirrored convention
// reads twice the heading. Surfaced in the settings sheet so the headset
// retest does not depend on the user judging a sign by feel.
float SohVR_GetCamFwdErrDeg(void);
float SohVR_GetEngineFps(void);
int SohVR_GetEyeW(void);
int SohVR_GetEyeH(void);
void SohVR_InjectKart(int on, float x, float y, float z, int yawBam);

#ifdef __cplusplus
}
#endif
