// SohIosShell — grafts the iOS app shell onto SDL's UIWindow.
// v1: ensure landscape (insurance — the app is already landscape via the plist
// + SDL orientation hint; this nudges the scene if it ever starts portrait).
// The on-screen touch-control overlay is added in a later revision. Compiled
// into the soh target (ARC on). LUS calls SohIos_OnWindowCreated after
// SDL_CreateWindow.
//
// NOTE: on the iOS Simulator the device *bezel window* may display the app
// rotated (a cosmetic simulator quirk); `xcrun simctl io <udid> screenshot`
// captures the true landscape framebuffer and is the verification source.
#import "SohIosShell.h" // R16-A: SohVRFrameSnapshot is used above the later import
#import <GameController/GameController.h>
#import <AVFAudio/AVFAudio.h>
#import <QuartzCore/QuartzCore.h>
UIView* SohIos_FindMetalViewIn(UIView* v);
UIView* SohIos_FindMetalView(UIWindow* w);
void SohIos_GlueWindowToScene(UIWindow* w, UIWindowScene* scene);
void SohIos_ForceViewChainAdopt(void);
static UIWindow* SohIos_GameWindowWithMetal(UIView** outMv);
#if TARGET_OS_VISION
extern volatile float gSohIosVisionLongEdge;
#endif
// Written by gfx_metal's command-buffer completed handler (overlay 0028).
volatile float gSohIosGpuMs = 0;
// Cached on the main thread each poll; the bridge reads these (dispatch_sync
// from the bridge thread deadlocks — the game loop owns the main thread).
static volatile float gSohIosDrawableW = 0, gSohIosDrawableH = 0, gSohIosContentsScale = 0;
// D-V7: consecutive nextDrawable failures (written by the engine, 0011 rev3).
// A wedged CAMetalLayer returns nil forever until drawableSize is rewritten —
// the VP "black window after live resize, audio alive" report. The self-heal
// below hard-resets the layer when this climbs.
volatile int gSohIosDrawableFailStreak = 0;

// D-030 stereo (visionOS): engine-visible 3D state. Defined HERE (this file is
// compiled on iPhone too) so the Fast3D overlay's strong externs always
// resolve; on iPhone the mode simply never leaves 0. The host VC (visionOS
// target only) flips the mode; the LUS eye passes publish the textures.
volatile int gSoh3DMode = 0;
void* volatile gSoh3DEyeTexture[2] = { NULL, NULL };
volatile int gSoh3DEyeFrames[2] = { 0, 0 };
volatile int gSoh3DEyeW = 0, gSoh3DEyeH = 0; // 0 = engine default (3840x2160)
volatile float gSoh3DCamDist = 0;            // 0032: camera-to-focus, per frame
volatile float gSoh3DCamP00 = 1.0f;          // 0032 v2: cot(fovx/2)
// R16-C (overlay 0045 rev5): the GAME's own projection aspect --
// gScreenAspect, 1.33333 in 1P racing. The rear-view pane's framebuffer
// was sized as a fraction of the EYE extent per axis, under a comment
// claiming that made the aspects match. It does not: the eye is 1.778 in
// this simulator and 1.246 on the device, and the mirror walk replays the
// GAME's projection, which carries 1.3333. The pane has been horizontally
// stretched (sim) or squeezed (device) for its whole life.
volatile float gSoh3DCamAspect = 1.33333334f;
volatile float gSoh3DCamRight[3] = { 1, 0, 0 };
volatile float gSoh3DCamFwd[3] = { 0, 0, -1 };
volatile float gSoh3DCamEye[3] = { 0, 0, 0 };
// VR R17-A item 1 (overlay 0045 rev6): the PREVIOUS game frame's camera eye.
// The seat has to be interpolated along the same segment the world is.
volatile float gSoh3DCamEyePrev[3] = { 0, 0, 0 };
volatile float gSoh3DDbgConv = 0, gSoh3DDbgSep = 0; // live stereo telemetry
volatile int gSoh3DPaused = 0;                       // 0032 v3: Kaleido open
volatile int gSoh3DAiming = 0;                       // 0032 v4: first-person/aim cam
volatile int gSoh3DInPlay = 0;                       // 0032 v5: gameplay view active
volatile int gSoh3DDbgMenuVis = 0, gSoh3DDbgMenuBuilds = 0; // 3D menu telemetry
volatile int gSoh3DDbgMenuVtx = 0, gSoh3DDbgMenuDraws = 0;  // draw-data + guard-pass
volatile int gSohAudioAnchorStatus = 0;              // spatial anchor: 1 ok / 2 threw
volatile int gSoh3DDbg2DW = 0, gSoh3DDbg2DH = 0;     // engine 2D dims (fill bug)
volatile int gSoh3DDbgCurW = 0, gSoh3DDbgCurH = 0;   // interpreter mCurDimensions (crop diag)

#include <pthread.h>
#include <string.h>

// VR mode (VR-spec R1). Defined HERE for exactly the reason the 3D block
// above is: interpreter.cpp's externs are strong and __IOS__ is defined on
// iPhone too, so the symbols must exist on every target. gSohVRWorldActive
// never leaves 0 anywhere but the visionOS VR loop.
volatile int gSohVRWorldActive = 0;                  // 1 = VR WORLD frames
void* volatile gSoh3DEyeDepthTexture[2] = { NULL, NULL };
volatile unsigned int gSoh3DEyeTag[2] = { 0, 0 };    // pose frame id per eye
void* volatile gSoh3DHudTexture = NULL;              // 0044 HUD framebuffer
volatile int gSohIosPauseReq = 0;                    // 0049: pause on VR exit
volatile int gSohVRDbgClearsAll = 0, gSohVRDbgClearsAlpha = 0; // 0044 clear telemetry

// VR R2 (first-person foundations). Same rule as the block above: the engine's
// externs are strong and __IOS__ is defined on iPhone too, so every symbol is
// defined here for every target and stays at its inert default anywhere but
// the visionOS VR loop.
//   gSohVREyeKey     — 1 = re-key MK64's camera-facing work to the composed
//                      eye (trap A7 billboards + trap D6 sky sprites). VR
//                      WORLD frames only, and never while paused.
//   gSohVREyePosGame — the composed eye in GAME units (positional billboards).
//   gSohVREyeYawBam  — the composed eye's yaw in MK64 binary angles.
//   gSohVREyeFovDeg  — the eye frustum's horizontal FOV, so the sky's
//                      yaw->screen-x mapping is rebuilt on the EYE.
//   gSohVRSkyMode    — 0 = park the sky in the HUD fb and wipe it (R1's
//                      Diorama), 1 = draw it in-eye at infinity (R2's FP).
//   gSohVRAngleCullOff — stand down MK64's ANGLE culls (D5/A2/A3), the ones
//                      that do not funnel through is_within_render_distance.
//   gSohVRKartSpin   — 1 while the player kart is spinning/tumbling (A6).
//                      R7: SPINS ONLY. It used to include `effects & 0x8`,
//                      which is MK64's AIRBORNE bit — every hop raised it and
//                      the comfort filter answered by holding the world's yaw,
//                      which is the whole of the 1.0.0.3 "I rotate around my
//                      driver instead of being him" report (VR-R7-NOTES §1).
//   gSohVRKartAirborne — R7: the airborne bit itself, kept as telemetry so the
//                      dump can show how often it was firing.
volatile int gSohVREyeKey = 0;
volatile float gSohVREyePosGame[3] = { 0, 0, 0 };
volatile int gSohVREyeYawBam = 0;
volatile float gSohVREyeFovDeg = 100.0f;
volatile int gSohVRSkyMode = 0;
volatile int gSohVRAngleCullOff = 0;
volatile int gSohVRKartSpin = 0;
volatile int gSohVRKartAirborne = 0;
// VR R9 (overlay 0054). Defined here on EVERY target for the same reason as the
// block above — the engine's externs are strong and __IOS__ is defined on
// iPhone too, so the iPhone build must still link them even though nothing on
// iPhone ever raises them.
//   gSohVRHideOwnKart  — item 5: 1 while a VR world frame is being drawn in
//                        FIRST PERSON. render_kart skips the LOCAL player's
//                        billboard (and only that quad) while it is set.
//   gSohVRKartRollBam  — item 6: the composed ROLL the kart billboard is drawn
//                        with (player->unk_050[0]); during HIT_EFFECT it is
//                        driven by the tumble angle unk_D9C.
//   gSohVRKartTumble   — item 6: the somersault PHASE, 0..0x1FFF for one full
//                        revolution (player->unk_0A8, the gKartTextureTumbles
//                        index). The somersault has no representation in
//                        player->rotation at all.
//   gSohVRKartHitEffect— item 6: MK64's HIT_EFFECT, i.e. "tumbling after
//                        hitting something", which gSohVRKartSpin deliberately
//                        excludes (0051 rev4).
volatile int gSohVRHideOwnKart = 0;
// R19 item 6 (overlay 0066): 1 = a VR WORLD frame in FIRST PERSON (same
// predicate as gSohVRHideOwnKart, kept separate so a debug toggle of one
// never moves the other). The start-line Lakitu is pushed out only then.
volatile int gSohVRFpWorld = 0;
// R9 item 7: the LAP-clip fix's A/B control (overlay 0054). 1 = fixed
// (shipping), 0 = the 1.0.0.5 behaviour reinstated on purpose so the suite
// can photograph the bug and the fix in the same build.
volatile int gSohVRHudWideSym = 1;
// R9 item 1: the eye-slot handoff gate's A/B control (overlay 0044 rev4).
// 1 = gated (shipping), 0 = the 1.0.0.5 free-running behaviour, so the
// gate's cost can be measured against itself in one build — and so a device
// that ever wedges behind it has one bridge command out.
volatile int gSohVRSlotGate = 1;
// --- R11 item 1: the compositor's IN-USE reference count -------------------
//
// R9's handoff gate asked two questions ("is the GPU still writing this slot"
// and "is this the pointer the loop is currently binding") and both were
// answered from state the ENGINE could see. Neither can see a compositor
// command buffer that has already been ENCODED against a texture and is
// sitting in the queue: the compositor reads gSoh3DEyeTexture[e] into a local,
// encodes a render pass, commits — and that buffer may not execute for tens of
// milliseconds while a 20 Mpix eye pass drains ahead of it. By then publication
// has moved on, the gate's second question reads false, and the engine
// overwrites the exact texture the compositor is about to sample.
//
// So the consumer keeps its own count, from encode to completion, and the gate
// waits on it. Defined here (not in SohImmersive.m) because gfx_metal.cpp links
// on iPhone too, where the table simply stays empty and every query is 0.
//
// R12 item 1 — THE OTHER HALF OF THE HANDSHAKE, and the table's real size.
//
// R11 gave the CONSUMER a claim the producer waits on. It did not give the
// PRODUCER a reservation the consumer waits on, and that is the remaining
// left-eye artefact. The engine's gate answers "is the compositor using this
// slot?" at the moment `Soh3DSetEye` runs — but the slot is not WRITTEN then.
// The eye pass is only ENCODED there; every eye framebuffer's command buffer
// is committed together at the end of the host frame in EndFrameOffscreen, and
// the GPU touches the texture later still. Eye 0 is encoded at the head of the
// frame, so its gate is answered ~33 ms before its pixels are written; eye 1's
// is answered ~16 ms before. The compositor runs at 90-100 Hz, so in eye 0's
// window it gets about THREE chances to latch that slot's pointer, bind it and
// claim it — all of it invisible to a gate that has already returned. Eye 1
// gets half as many. Same code, twice the exposure, and the artefact lands in
// cp_drawable view 0 = the LEFT eye (trap D29: the asymmetry is in TIME).
//
// So the reservation is the mirror image of the claim:
//   * the ENGINE marks a slot OWNED the instant its gate passes (or times
//     out — the write is happening either way), and clears it when that
//     framebuffer's command buffer COMPLETES;
//   * the COMPOSITOR refuses to claim an owned slot. SohVR_TexInUseAdd now
//     RETURNS 0 for a refusal, and the loop binds its last good texture for
//     that eye instead — a coherent frame one publication old, which is what
//     a consumer should show when the producer is mid-write.
// Neither side can be surprised by the other, and neither eye is privileged,
// because ownership covers gate -> completion rather than gate -> return.
//
// SIZING. The old table was 16 entries with a comment that counted 3 eye
// slots x 2 eyes + 3 HUD + 3 mirror = 12 — and forgot the DEPTH textures,
// which the compositor claims by name. The true live set is 18, and with more
// than one compositor command buffer in flight (90-100 Hz against 11 ms of
// latency, routinely two or three on the device) the distinct-texture count
// climbs past that. An overflow DROPS the claim, which hands the engine a
// slot the compositor is about to sample — the exact artefact this table
// exists to prevent, arriving through the table itself. 48 entries covers
// three cbs in flight over the full live set with room to spare, and
// `inuse_overflow` stays on the settings page as the assert.
#include <os/lock.h>
extern volatile int gSohVREngineOwnFix; // defined below; the R12 A/B control
volatile unsigned int gSohVRInUseOverflow = 0;
// R12: refusals — the compositor declined to bind a slot the engine owns.
// Non-zero is the fix DOING something, not a fault; it is per eye so the
// left/right asymmetry stays visible as a number.
// R13 item 2a: widened to the gate's own four slots (0 eye0, 1 eye1, 2 HUD,
// 3 rear-view pane). The HUD's refusal was completely silent — no fallback and
// no counter — which is why "the HUD does not draw in VR" could sit through
// two rounds with the suite green.
volatile unsigned int gSohVRBindDefer[4] = { 0, 0, 0, 0 };
// R13 item 2a: reservations the SWEEP had to drop because the framebuffer that
// took them was never drawn. Non-zero means the leak is real and being caught;
// it is not, by itself, a fault.
volatile unsigned int gSohVROwnSweeps = 0;
// R13 item 2a: how many times the HUD plane was actually ENCODED into a view's
// command buffer, and how many times it fell back to the last good texture.
// `hud_tex=1` only ever proved the engine PUBLISHED something; neither of
// these can be true without the plane reaching the encoder.
volatile unsigned int gSohVRHudEncodes = 0;
volatile unsigned int gSohVRHudLastGood = 0;
#define SOHVR_INUSE_N 48
static void* sSohVRInUseTex[SOHVR_INUSE_N];
static int sSohVRInUseCnt[SOHVR_INUSE_N];
static os_unfair_lock sSohVRInUseLock = OS_UNFAIR_LOCK_INIT;
// R12: the PRODUCER's reservation. Deliberately NOT a flag inside the claim
// table: the engine gates exactly four things (eye 0, eye 1, the HUD, the
// rear-view pane) and a reservation keyed to the TEXTURE leaks the moment a
// framebuffer is resized and hands back a new texture — measured on the first
// stress run, 48 stale owned entries in twelve seconds, which filled the claim
// table and turned every bind into a refusal. Keyed by GATE SLOT it is bounded
// by construction: four entries, each overwritten by its own next gate.
#define SOHVR_OWN_N 4
static void* sSohVROwnTex[SOHVR_OWN_N];
// R13 item 2a: the AGE of each live reservation, in host frames. A reservation
// is taken at the engine's gate and released by the completion handler of the
// framebuffer that gate covered — so a framebuffer that is gated and then NOT
// DRAWN (one gSohVRWorldActive flip between Soh3DSetEye and Interpreter::Run
// is enough; the compositor writes that flag from its own thread every frame)
// never releases, and from the moment its texture becomes the published HUD
// every compositor claim is refused forever. The sweep bounds that: a
// reservation legitimately lives well under a host frame plus GPU latency, so
// anything still standing after SOHVR_OWN_MAX_AGE frames is a leak, and
// dropping it costs at worst one frame of the pre-R12 race instead of a dead
// HUD for the session.
#define SOHVR_OWN_MAX_AGE 8
static unsigned char sSohVROwnAge[SOHVR_OWN_N];

// Caller must hold the lock. Returns the entry for `tex`, allocating one from
// a slot that is neither claimed nor owned; -1 when the table is full.
static int sohvr_inuse_slot(void* tex, int allocate) {
    int free = -1;
    for (int i = 0; i < SOHVR_INUSE_N; i++) {
        if (sSohVRInUseTex[i] == tex) {
            return i;
        }
        if (free < 0 && sSohVRInUseCnt[i] == 0) {
            free = i;
        }
    }
    if (!allocate || free < 0) {
        return -1;
    }
    sSohVRInUseTex[free] = tex;
    sSohVRInUseCnt[free] = 0;
    return free;
}

// Caller must hold the lock.
static int sohvr_owned_locked(void* tex) {
    for (int i = 0; i < SOHVR_OWN_N; i++) {
        if (sSohVROwnTex[i] == tex) {
            return 1;
        }
    }
    return 0;
}

// R12: returns 1 when the claim was recorded, 0 when it was REFUSED (the
// engine owns the slot, or the table is full). A refusal must never be
// ignored: binding after one is exactly the bug.
int SohVR_TexInUseAdd(void* tex) {
    if (tex == NULL) {
        return 0;
    }
    os_unfair_lock_lock(&sSohVRInUseLock);
    int i = sohvr_inuse_slot(tex, 1);
    if (i < 0) {
        // Cannot happen at 48 entries; if it ever does, the safe failure is to
        // refuse the bind rather than to silently hand the engine a texture we
        // are about to sample. Counted so it is not invisible.
        gSohVRInUseOverflow = gSohVRInUseOverflow + 1;
        os_unfair_lock_unlock(&sSohVRInUseLock);
        return 0;
    }
    if (gSohVREngineOwnFix && sohvr_owned_locked(tex)) {
        os_unfair_lock_unlock(&sSohVRInUseLock);
        return 0;
    }
    sSohVRInUseCnt[i]++;
    os_unfair_lock_unlock(&sSohVRInUseLock);
    return 1;
}

// R12: the producer's half. Taken the instant the engine's handoff gate
// returns — including when it TIMES OUT, because the engine writes the slot
// either way and a consumer that keeps binding it is the artefact. `slot` is
// the gate's own eye index (0 eye0, 1 eye1, 2 HUD, 3 rear-view pane), so each
// reservation replaces the previous one for the same gate and nothing can
// accumulate. Released when that framebuffer's command buffer completes.
void SohVR_TexEngineOwn(int slot, void* tex) {
    if (slot < 0 || slot >= SOHVR_OWN_N) {
        return;
    }
    os_unfair_lock_lock(&sSohVRInUseLock);
    sSohVROwnTex[slot] = tex;
    sSohVROwnAge[slot] = 0;
    os_unfair_lock_unlock(&sSohVRInUseLock);
}

// R13 item 2a: called once per host frame from EndFrameOffscreen (overlay 0044
// rev7). See SOHVR_OWN_MAX_AGE above for why an age bound is the right shape
// here: the precise release for a gated-but-not-committed framebuffer lives in
// EndFrameOffscreen, and this catches the ones that never reached
// mDrawnFramebuffers at all.
void SohVR_TexEngineSweep(void) {
    os_unfair_lock_lock(&sSohVRInUseLock);
    for (int i = 0; i < SOHVR_OWN_N; i++) {
        if (sSohVROwnTex[i] == NULL) {
            sSohVROwnAge[i] = 0;
            continue;
        }
        if (sSohVROwnAge[i] < 255) {
            sSohVROwnAge[i]++;
        }
        if (sSohVROwnAge[i] > SOHVR_OWN_MAX_AGE) {
            sSohVROwnTex[i] = NULL;
            sSohVROwnAge[i] = 0;
            gSohVROwnSweeps = gSohVROwnSweeps + 1;
        }
    }
    os_unfair_lock_unlock(&sSohVRInUseLock);
}

// Clears every reservation naming this texture. Called from the completing
// command buffer, which knows its framebuffer's texture but not which gate
// reserved it — and a texture can legitimately be reserved by only one.
void SohVR_TexEngineRelease(void* tex) {
    if (tex == NULL) {
        return;
    }
    os_unfair_lock_lock(&sSohVRInUseLock);
    for (int i = 0; i < SOHVR_OWN_N; i++) {
        if (sSohVROwnTex[i] == tex) {
            sSohVROwnTex[i] = NULL;
            sSohVROwnAge[i] = 0;
        }
    }
    os_unfair_lock_unlock(&sSohVRInUseLock);
}

int SohVR_TexEngineOwned(void* tex) {
    if (tex == NULL) {
        return 0;
    }
    os_unfair_lock_lock(&sSohVRInUseLock);
    int own = sohvr_owned_locked(tex);
    os_unfair_lock_unlock(&sSohVRInUseLock);
    return own;
}

// R12: the table itself, for the bridge. `vr inuse` prints one entry per live
// row so a full table is a fact rather than an inference from the overflow
// counter (which is what the first stress run turned into an hour of guessing).
const char* SohVR_DumpInUse(void) {
    static char line[1024];
    int n = 0;
    int used = 0, owned = 0, claimed = 0;
    n += snprintf(line + n, sizeof(line) - n, "inuse n=%d", SOHVR_INUSE_N);
    os_unfair_lock_lock(&sSohVRInUseLock);
    for (int i = 0; i < SOHVR_INUSE_N; i++) {
        if (sSohVRInUseTex[i] == NULL) {
            continue;
        }
        used++;
        if (sSohVRInUseCnt[i] > 0) {
            claimed++;
        }
        if (n < (int)sizeof(line) - 40) {
            n += snprintf(line + n, sizeof(line) - n, " [%d]%p:c%d", i, sSohVRInUseTex[i],
                          sSohVRInUseCnt[i]);
        }
    }
    for (int i = 0; i < SOHVR_OWN_N; i++) {
        if (sSohVROwnTex[i] != NULL) {
            owned++;
        }
        if (n < (int)sizeof(line) - 32) {
            n += snprintf(line + n, sizeof(line) - n, " own%d=%p", i, sSohVROwnTex[i]);
        }
    }
    os_unfair_lock_unlock(&sSohVRInUseLock);
    snprintf(line + n, sizeof(line) - n, " | used=%d claimed=%d owned=%d overflow=%u", used, claimed,
             owned, gSohVRInUseOverflow);
    return line;
}

// R12: every claim currently outstanding, over the whole table. The resize
// quiesce needs this: R11's version waited only on the RETIRE RING, which
// does not contain the textures the compositor is binding RIGHT NOW, and then
// wiped the table — telling the gate that live claims did not exist.
int SohVR_TexInUseAny(void) {
    int n = 0;
    os_unfair_lock_lock(&sSohVRInUseLock);
    for (int i = 0; i < SOHVR_INUSE_N; i++) {
        n += sSohVRInUseCnt[i];
    }
    os_unfair_lock_unlock(&sSohVRInUseLock);
    return n;
}

void SohVR_TexInUseSub(void* tex) {
    if (tex == NULL) {
        return;
    }
    os_unfair_lock_lock(&sSohVRInUseLock);
    int i = sohvr_inuse_slot(tex, 0);
    if (i >= 0 && sSohVRInUseCnt[i] > 0) {
        sSohVRInUseCnt[i]--;
    }
    os_unfair_lock_unlock(&sSohVRInUseLock);
}

int SohVR_TexInUse(void* tex) {
    if (tex == NULL) {
        return 0;
    }
    os_unfair_lock_lock(&sSohVRInUseLock);
    int i = sohvr_inuse_slot(tex, 0);
    int n = (i >= 0) ? sSohVRInUseCnt[i] : 0;
    os_unfair_lock_unlock(&sSohVRInUseLock);
    return n;
}

// Drop every claim AND every reservation — used by the eye-extent quiesce
// (R11 item 2), which is about to release the textures these pointers name.
// The quiesce must WAIT for the claims to drain before calling this (R12: it
// now waits on SohVR_TexInUseAny, not on the retire ring alone); clearing a
// live claim is telling the gate a lie in the one place it matters most.
void SohVR_TexInUseClear(void) {
    os_unfair_lock_lock(&sSohVRInUseLock);
    memset((void*)sSohVRInUseTex, 0, sizeof(sSohVRInUseTex));
    memset((void*)sSohVRInUseCnt, 0, sizeof(sSohVRInUseCnt));
    memset((void*)sSohVROwnTex, 0, sizeof(sSohVROwnTex));
    os_unfair_lock_unlock(&sSohVRInUseLock);
}

// R11 item 1: the INDEPENDENT assert (spec D11). The engine stamps the low
// byte of the pose tag into 8 corner texels of each eye texture as part of the
// command buffer that renders it; the compositor copies those texels back out
// at BIND time and compares them with the tag it read from gSoh3DEyeTag. Two
// paths that share nothing: one rides the pixels, one rides the CPU-side
// publication bookkeeping. gSohVREyeTagMiss[e] counts disagreements.
volatile int gSohVREyeTagOn = 1;
volatile int gSohVREyeTagFault = 0; // D11 red control: stamp a WRONG tag
// R12 item 1: the STAMP the probe actually compares. Published beside the eye
// texture, one increment per eye pass — unlike the pose tag, which only moves
// when the compositor publishes a pose and therefore goes CONSTANT in exactly
// the conditions this bug needs (see the long note in gfx_metal.cpp rev6).
volatile unsigned int gSoh3DEyeStamp[2] = { 0, 0 };
volatile unsigned int gSohVREyeTagMiss[2] = { 0, 0 };
volatile unsigned int gSohVREyeTagChecks[2] = { 0, 0 };
// R12 item 1 — the probe's SECOND phase, and why R11's could not see this bug.
// R11 encoded ONE readback, at the head of the compositor's command buffer,
// strictly BEFORE the render encoder that runs the world blit. It therefore
// samples the texture at a moment the world blit has not reached yet: a tear
// that begins after the readback and during the blit is invisible to it, and
// that is precisely the tear the user is looking at. The probe now reads the
// same eight texels a SECOND time, encoded after the last view's render pass,
// and a disagreement in either phase counts as a miss. `eye_tag_post_miss`
// breaks out how many were caught only by the late read — a non-zero left
// value there is the artefact, dated.
volatile unsigned int gSohVREyeTagPostMiss[2] = { 0, 0 };
// R12 item 1 — THE SIM STRESS KNOBS (session-only, never persisted, both 0 in
// every shipped configuration). Six rounds failed to reproduce the artefact in
// the simulator because the simulator's compositor timing is benign: its
// command buffers execute almost immediately, so the windows this bug lives in
// are microseconds wide. These widen them on purpose, so the counters can be
// driven RED in a simulator on the unfixed code and GREEN on the fixed code —
// the round's method requirement, and the first non-tautological proof this
// arc has had (spec D11's discriminating-power clause, applied to a race
// rather than to a matrix).
//
//   gSohVRCompDelayMs — sleep between LATCHING the published eye pointers and
//     CLAIMING them. This is the read->claim window, the one the device widens
//     by preempting the compositor thread. While it is open the engine's gate
//     sees no claim on a slot the compositor has already decided to bind.
//   gSohVRCompHoldMs — sleep between finishing the encode and committing the
//     command buffer, with the claims HELD. This is the NEGATIVE control: the
//     claim is supposed to cover encode->completion, so widening this must
//     NOT produce a miss. If it does, the claim is not covering what it says.
volatile int gSohVRCompDelayMs = 0;
volatile int gSohVRCompHoldMs = 0;
// R12 item 1's A/B control: 1 = the producer reservation is live (shipping),
// 0 = the 1.0.0.8 protocol exactly (consumer claim only). One build, both
// behaviours, so the stress evidence is red-before/green-after on the SAME
// binary rather than across two of them.
volatile int gSohVREngineOwnFix = 1;
// R15 item 1 — THE STALE FRAME IN ONE EYE, and the pair rule that ends it.
//
// the user, on 1.0.0.11: "the rendered course content flickers in my left eye a
// lot — it moves barely, or shows a DUPLICATE, then back in place — when I look
// left and right." With the RIGHT eye closed, so it is not a stereo split he is
// describing: the LEFT eye's own image jumps back and forth in time.
//
// The mechanism is the anchor, not the texture. The two eye framebuffers are
// PUBLISHED BY SEPARATE COMPLETION HANDLERS (each eye pass is its own command
// buffer, committed together in EndFrameOffscreen but completing independently),
// so gSoh3DEyeTag[0] and gSoh3DEyeTag[1] can legitimately name DIFFERENT host
// frames for a while every host frame. The compositor already knew that — it
// submitted `min(tagL, tagR)`'s anchor — and the min is exactly the wrong
// answer: it reprojects the eye that is FRESH (tag N) as though it had been
// rendered for the OLDER pose (N-1). One frame of head motion, applied to one
// eye only, appearing and disappearing at the rate the two publications race:
// "moves barely, shows a duplicate, then back in place", while turning, in the
// eye whose publication happens to have landed first.
//
// The R14 per-eye last-good fallback has the same shape and the same effect: a
// claim refused for ONE eye re-presented that eye's previous texture alone.
//
// So the invariant is now: THE PAIR IS ATOMIC. The compositor presents two eye
// textures that carry the SAME pose tag, or it presents the last pair that did
// — both eyes together, reprojected against THAT pair's own anchor. A
// stereo-consistent stale frame, correctly reprojected, is invisible; a
// one-eye stale frame is what the user has been looking at.
//
//   gSohVRPairFix     A/B. 1 = shipping. 0 = the 1.0.0.11 behaviour (per-eye
//                     last-good, min(tag) anchor) — the red control.
//   gSohVRStaleForce  bitmask, sim only: bit 0 refuses eye 0's claim, bit 1
//                     eye 1's. Without it nothing in the tree can produce a
//                     one-eye stale on demand and "the tags matched" would be
//                     a tautology (trap D11).
//   gSohVREyeStale    per eye, how many presented frames were NOT that eye's
//                     freshly published texture. This is the number on the
//                     settings sheet's Steadiness line.
//   gSohVRPairSplits  frames the two eyes' latched pose tags disagreed.
//   gSohVRPairForced  frames neither a matching fresh pair NOR a last-good
//                     pair was available and the mismatched pair was shown.
volatile int gSohVRPairFix = 1;
volatile int gSohVRStaleForce = 0;
volatile unsigned int gSohVREyeStale[2] = { 0, 0 };
volatile unsigned int gSohVRPairSplits = 0;
volatile unsigned int gSohVRPairForced = 0;
volatile unsigned int gSohVRPresentSplits = 0;
volatile unsigned int gSohVRPresentTag[2] = { 0, 0 };
// ============================================================================
// VR R16-A — the left-eye vibrate and the one-frame world flash (1.0.0.12).
// docs/vr-r16-diagnosis/eyes-flicker-and-flash.md is the diagnosis; these are
// its counters, its stress knobs and its A/B controls. Every one of them
// exists because the round needed a NUMBER for something the user could only
// describe, or a RED control so a green could not be vacuous (trap D11).
//
// (b) "the world violently turns in a flash of an eye, then fixes itself":
//   gSohVRSeatFallbacks   compositor frames that composed the world from the
//                         CHASE CAMERA while the game was in play and the view
//                         was first person — i.e. the kart-pose hole. Every one
//                         of these is a seat that jumped to the camera's
//                         look-at point with the camera's heading.
//   gSohVRWorldYawStepMax the largest one-frame step the yaw follower took,
//                         in DEGREES, since the last clear. Ordinary cornering
//                         is bounded by kart_yaw_rate * dt (~2 deg); a snap is
//                         tens of degrees. This is the artefact itself as a
//                         number.
//   gSohVRKartHoleFault   RED CONTROL for the staleness bound: the export site
//                         skips raising the kart pose on one game frame in
//                         every N, so the bound can be shown holding at N below
//                         it and letting go above it. 0 = off (shipping).
//
// (a) "the world vibrates or shakes a tiny bit in my LEFT eye":
//   gSohVREyeBlank        per view, frames PRESENTED with no world blit at all
//                         because that eye's texture was nil. present_splits
//                         structurally cannot see this (it requires BOTH eyes
//                         non-nil), which is why a one-eyed artefact survived a
//                         round that measured itself green.
//   gSohVREyeMono         frames one eye was nil and the other eye's texture
//                         was shown in BOTH views. A mono frame is a comfort
//                         artefact; a black eye is a flash.
//   gSohVREyePubHoldMs    THE MISSING INJECTION. `comphold`/`staleforce` model
//                         the CONSUMER; nothing modelled the PRODUCER's
//                         inter-eye publication gap, which on device is a whole
//                         eye pass (~10 ms) and in the simulator is
//                         microseconds. This delays eye 0's publication by that
//                         much, so the simulator can enter the device's régime.
//                         Dev knob, session only, 0 in every shipped build and
//                         asserted 0 by the suite beside staleforce/comphold.
//   gSohVREyePubAtomic    A/B. 1 = the eye pair is PUBLISHED atomically
//                         (shipping); 0 = the 1.0.0.12 protocol, each eye's
//                         completion handler publishing independently.
//   gSohVRPubOrphans      publications released alone because their sibling
//                         never arrived — the bound that stops an atomic pair
//                         freezing the world if one eye's command buffer is
//                         lost.
//   gSohVRPairHold        1 = the last-good pair's claim is HELD across frames,
//                         so the fallback is always available; 0 = re-claimed
//                         per frame (the 1.0.0.12 behaviour).
//                         SHIPS 0, ON THE MEASUREMENT. The diagnosis expected
//                         the hold to make the fallback always available and so
//                         to cut pair_forced. Measured under the device's own
//                         regime (a 12 ms producer gap plus a pulsed one-eye
//                         refusal): pair_forced 140 held versus 144 not — noise
//                         — while the hold cost the producer 67 skipped host
//                         frames in twelve seconds (5% of them) against 0. It
//                         buys nothing here and it is not free, so it ships off
//                         and the knob stays for the device, where the regime
//                         differs. artifacts/vr-r16/followups.log.
//
// (a), the other half — the un-latched per-eye sky shift:
//   gSohVRSkyShiftId      the compositor frame id the LIVE gSohVRSkyShift pair
//                         belongs to.
//   gSohVRSkyShiftTag     per eye, the id that was current when THAT eye pass
//                         consumed the shift. Latched, the two are equal and
//                         equal the frame's own matrix tag; live, they are two
//                         different head poses ~one eye pass apart, baked into
//                         the pixels where no pair rule can see them.
//   gSohVRSkyTagSkew      how many host frames the two eyes disagreed.
//   gSohVRSkyLatch        A/B / red control. 1 = the eye passes read the frame
//                         snapshot (shipping); 0 = the live global.
volatile unsigned int gSohVRSeatFallbacks = 0;
volatile float gSohVRWorldYawStepMax = 0.0f;
volatile int gSohVRKartHoleFault = 0;
//   gSohVRYawSnap  RED CONTROL for F1 step 4: 1 restores the 1.0.0.12
//                  arming rule, where the yaw follower snapped on exactly
//                  the frames whose seat source had just changed. 0 ships.
volatile int gSohVRYawSnap = 0;
volatile unsigned int gSohVREyeBlank[2] = { 0, 0 };
volatile unsigned int gSohVREyeMono = 0;
volatile int gSohVREyePubHoldMs = 0;
volatile int gSohVREyePubAtomic = 1;
volatile unsigned int gSohVRPubOrphans = 0;
volatile int gSohVRPairHold = 0;
volatile unsigned int gSohVRSkyShiftId = 0;
volatile unsigned int gSohVRSkyShiftTag[2] = { 0, 0 };
volatile unsigned int gSohVRSkyTagSkew = 0;
volatile int gSohVRSkyLatch = 1;
// R11 item 3c: the rear-view pane's sky re-registration (overlay 0044 rev5).
// 1 = the pane's sky keys to the kart's rear, which is what a fixed rear-facing
// camera shows; 0 restores the 1.0.0.7 behaviour, where MK64's screen-space
// cloud sprites — built once per game frame against the COMPOSED EYE yaw —
// slid across the pane with the user's head. A/B, never persisted.
volatile int gSohVRRearSky = 1;
// R15 item 5 — the rear-view pane's GROUND FILL. MK64's sky draws a
// full-width screen-space ramp BELOW the horizon (Sky::DrawFloor, plus 0058's
// lower cap) from the course's FloorTop down to FloorBottom, on every course
// but Rainbow Road. In the eyes the world's own ground covers it. In the pane
// it is the only full-width thing drawn, and it is the only candidate for
// the user's "rear view going downhill shows grey empty space where the uphill
// road behind should be" — his photograph inside Luigi Raceway's tunnel is
// that course's FloorTop {216,232,248} fading to black, with a hard horizontal
// top edge at the pane's own horizon.
//
// AND THE MEASUREMENT SAYS IT IS NOT PAINTING OVER ANYTHING. With the fill
// dropped (`vr set rearfloor 0`, artifacts/vr-r15/cmp-rearfloor.png) the same
// band of the pane goes BLACK, not road: there is no geometry behind it. The
// fill is not covering the road behind — it is filling the hole the rear
// walk's own display list leaves, because MK64 culls its course by SECTION for
// the FORWARD camera and bakes the result into the one list all three walks
// replay (trap D32). Widening that window is a per-track decision with a
// screenshot, never a global switch (trap A3), so the fill STAYS: grey is what
// a missing section looks like with it, and black is what it looks like
// without. 0 is kept as the red control that established this.
volatile int gSohVRRearFloor = 1;
// R16-C — THE REAR PANE'S CAMERA PIVOT, and its red control.
//   0 = 1.0.0.12: rotate the world 180 degrees about `camEye + camFwd*camDist`,
//       which is the chase camera's LOOK-AT POINT — a target 70 units AHEAD of
//       the kart, so the pane camera lands 140 units in front of where a mirror
//       belongs. This is the DEFECT, kept as the red control.
//   1 = the analytic mirror about the KART (0045 rev2's export). The minimum
//       viable fix, and the fallback whenever the look-behind camera is not
//       available (a fly-by, a menu, a custom track that never spawned one).
//   2 = MK64's OWN look-behind camera (0045 rev5): the pane view is built as
//       T = V_rear * V_game^-1, exact C-left parity including the game's
//       smoothing and its WALL PUSHOUT. SHIPS. Falls back to 1 when the rear
//       export is missing or stale, and to 0 when the kart is not there either.
volatile int gSohVRRearPivot = 2;
// R16-C step 4 — the OPPOSITE-DIRECTION course section list (overlay 0059).
// MK64 draws its course as one display list per (section, cardinal direction)
// and the pane replays the list built for the FORWARD camera's yaw quadrant,
// so the geometry genuinely behind the kart was never in the list at all —
// which is the hole R15 proved the grey ground fill is filling. 1 = the rear
// walk draws the section's REAR-direction variant instead (exclusive, never
// additive — trap A4). 0 is the red control.
volatile int gSohVRRearSec = 1;
// How many times the rear walk actually SWAPPED the list — counted only when
// the rear direction bucket DIFFERED from the forward one (trap D32's
// corollary: count the override only when it changed an answer). It therefore
// reads 0 on a straight where both cameras bucket the same way, which is the
// honest answer.
volatile unsigned int gSohVRRearDlSwaps = 0;
// R16-C step 5 — the local kart in the mirror (overlay 0054 rev4). MK64 skips
// the local kart's quad outright in first person, so the pane could never show
// your own tail; a mirror without the thing it is bolted to has no anchor.
//
// IT SHIPS OFF, AND THE MEASUREMENT IS WHY. The span is emitted (
// `ownkart_rear_tags` climbs), the eyes divert it into the mirror sink, and
// the pane draws NOTHING: flipping this knob with the kart parked changed
// 7 pixels out of 2.07 million (rear_diff_frac 0.00007), and the pane
// screenshots have no kart in them at either pivot. That is trap D19 --
// MK64's kart quad is a billboard built to face the FORWARD camera, and the
// pane's camera is 180 degrees from it, so the quad is edge-on and
// G_CULL_BACK removes it. Giving the pane its own per-object facing is a
// separate change (a LOCAL copy of the billboard matrix, per D19) and it is
// not in this round. The sentinels, the sink path and the knob stay so the
// round that does it starts from a measured baseline rather than a guess.
// It also means falsifier F2 was NOT achieved; F1 and F3 carry the round.
volatile int gSohVROwnKartRear = 0;
// How many frames 0054 rev4 emitted that span (the pane was up and the kart
// was hidden). It is the "the instrument is in the path" counter for F2.
volatile unsigned int gSohVROwnKartRearTags = 0;
// VR R17-A item 2a (overlay 0054 rev5): how many times the OTHER two emitters
// of the local kart's quad were suppressed in first person -- the boost flash
// (func_80025DE8, the user's mushroom "faint images ... of my own character's
// head shaking") and the ice reflection. They are the "the predicate is in the
// path" counters: an assert that can only ever NOT see a kart is worth nothing
// (trap D11).
volatile unsigned int gSohVROwnBoostSkips = 0;
volatile unsigned int gSohVROwnReflSkips = 0;
// R16-C step 3 — the pane's framebuffer aspect. 1 = sized at the GAME's own
// projection aspect (gSoh3DCamAspect); 0 = 1.0.0.12, a fraction of the EYE
// extent per axis, which stretched the pane by 33% in this simulator and
// squeezed it by 7% on the device.
volatile int gSohVRRearAspect = 1;
// R13 item 3 (overlay 0044 rev7 + 0058): THE SKY'S PITCH. The composed eye's
// pitch and vertical FOV, published by the compositor from the same matrix the
// eyes render with (trap A7), and the gain the ortho shift is multiplied by.
// gSohVRSkyPitch is a live A/B: 1 = shipping, 0 = the R12 head-locked sky,
// -1 = the shift with its sign flipped. A term whose sign has to be read off
// pixels gets a knob rather than a confident derivation (the tautological-
// assert rule: a matrix compared with itself passed twice while the device was
// upside down).
volatile float gSohVREyePitchDeg = 0.0f;
volatile float gSohVREyeVFovDeg = 90.0f;
volatile float gSohVRSkyPitch = 1.0f;
volatile int gSohVRSkyCamHeight = 0;   // overlay 0058: the game's horizon, in ortho px
// VR R17-A item 3 (overlay 0058 rev4): THE SKY'S LATERAL EXTENT.
// gSohVRSkyWide ships at 1 and adds cap quads to the left and right of the
// gradient; 0 is 1.0.0.13 and the RED CONTROL. gSohVRSkyArFault forces the
// aspect the gradient's own edges are computed at (milli-units; 1246 = the
// Vision Pro's eye), so a simulator whose eye is 1.778 can reproduce a defect
// that only exists below 4:3 -- trap D20's K = 120*AR - 160 family again.
// The three telemetry values are where the edges landed and what aspect the
// game used, which is the diagnosis stated as numbers rather than inferred.
volatile int gSohVRSkyWide = 1;
volatile int gSohVRSkyArFault = 0;
volatile int gSohVRSkyVtxL = 0, gSohVRSkyVtxR = 0;
volatile float gSohVRSkyBuildAr = 0.0f;
volatile unsigned int gSohVRSkySideQuads = 0;
// R14 item 1 — THE SKY, WORLD-LOCKED, DERIVED RATHER THAN FELT.
// R13's shift was a pixel formula: dy = (240/vFovDeg) * (eyePitchDeg -
// camPitchDeg), with a live gain because its SIGN had been read off three
// screenshots instead of derived. On device it was wrong by roughly a factor
// of two in the direction that matters (looking up walked the sky UP as well,
// so the FLOOR quad and its black lower cap climbed into the view — the user's
// "blue -> grey -> black"). Two independent failures were folded into one
// number: an angle-to-pixel conversion that assumed a symmetric frustum, and a
// sign nobody could derive.
//
// The replacement carries no convention at all. The sky's horizon must land on
// screen exactly where the WORLD's horizon lands, and both are just NDC y:
//
//   * WHERE IT MUST GO — project the horizon DIRECTION (the horizontal part of
//     the composed eye's forward, in game space, w = 0) through the LIVE
//     row-vector eye matrix the renderer is handed. A direction, not a point,
//     so the answer cannot depend on where the head is — only on where it
//     LOOKS. That is the user's requirement stated as arithmetic (trap D13: the
//     assert projects through the whole chain, not through P alone).
//   * WHERE IT IS — MK64 puts the horizon at ob[1] = screen->cameraHeight in a
//     guOrtho(0,320,0,240) screen, so its NDC y is 2*camHeight/240 - 1. Pure
//     matrix arithmetic; no handedness question exists.
//
// The shift is the difference, in NDC, applied to the sky ortho's out[3][1].
// Both quantities are measured in the SAME clip space and rasterised by the
// same viewport, so any raster flip cancels: there is nothing left to get
// backwards. gSohVRSkyPitch survives as the A/B gain (0 = the R12 head-locked
// sky) and nothing else keys off pitch degrees any more.
volatile float gSohVRSkyShift[2] = { 0.0f, 0.0f };
volatile int gSohVRSkyShiftValid = 0;
// R15 item 7 — THE CLOUDS' ANGULAR RATE. MK64 maps a sprite's yaw to screen x
// LINEARLY (320/fovDeg pixels per degree, the whole screen spanning fovDeg);
// the world projects through a TANGENT. R3 substituted the eye's fov into the
// game's linear formula, which leaves the sprites moving ~36% faster than the
// scenery at a 100-degree eye fov — the user's "the clouds move a lot as I move
// my head". These two are the eye frustum's own mapping, published for 0051 to
// consume in place of the formula:
//   gSohVRSkyPxPerBam  pixels of MK64's 320-wide sky ortho per BAM of yaw,
//                      matched to the world's rate at the centre of the frame.
//   gSohVRSkyPxCenter  the screen x a zero-yaw direction actually lands on.
//                      160 only if the frustum is symmetric, which this
//                      device's is not.
// gSohVRSkyRate is the A/B: 0 restores the 1.0.0.11 linear mapping exactly.
// gSohVRSkyWorldNdcPerDeg is the INDEPENDENT measurement the suite compares
// against: NDC x per degree read out of the live eye matrix by projecting two
// horizon directions through it, sharing no code with the publication above.
volatile float gSohVRSkyPxPerBam = 1.7578125f / 100.0f;
volatile float gSohVRSkyPxCenter = 160.0f;
volatile float gSohVRSkyWorldNdcPerDeg = 0.0f;
volatile int gSohVRSkyRate = 1;
// R16-B — THE CLOUDS, TRULY WORLD-LOCKED. the user on 1.0.0.12, the build R15
// item 7 was supposed to fix: "the clouds STILL move a lot when I'm moving my
// head around ... even while driving straight". R15 fixed the RATE at ONE
// point (the frame centre) of ONE eye and left the MAPPING linear; the world
// projects through a TANGENT. docs/vr-r16-diagnosis/clouds.md measures three
// surviving mechanisms, two of them larger than the one that was fixed:
//
//   M1  linear-vs-tangent placement, up to 9.8 degrees of slide and a quarter
//       of the frame width at the rim of this device's 105-degree eye.
//   M2  ONE sprite layout replayed into TWO ASYMMETRIC eyes with no per-eye
//       term at all. A direction at infinity MUST land 0.536 NDC apart in the
//       two eyes (that separation IS the outward frustum extension); drawing
//       it at equal NDC is a disparity no depth can fuse. R15 made this half
//       WORSE: it published eye 0's exact centre, so eye 0 became exact and
//       eye 1 wrong by the full 0.536.
//   M3  the sprite yaw was sampled a whole engine frame before the eye matrix
//       the sprites are drawn with -- 3-9 degrees of slide WHILE THE HEAD IS
//       MOVING, which is the user's report word for word. Same shape as R16-A's
//       un-latched sky shift, and closed the same way: through the snapshot.
//
// The publication below is what the layout is built in and what each eye pass
// remaps it by. All of it is derived from sSohVRTan -- the tangents of the very
// frustums the eyes render with (trap A7) -- and none of it is a formula fitted
// to a screenshot.
//   gSohVRSkyTanSum/Span  eye 0's frustum: the ONE reference the single sprite
//                         layout is built in. tan-based placement is
//                         ndc = (2*tan(theta) - tanSum)/span, whose value AND
//                         slope at theta = 0 are exactly R15's, so the fix is a
//                         strict generalisation of what shipped.
//   gSohVRSkyEyeDx/Sx     eye-0 NDC -> eye-e NDC. Both eyes share the span on
//                         this device, so sx is 1 and the whole of M2 is a
//                         constant offset -- but the scale is published anyway,
//                         because "they happen to be equal here" is not a
//                         thing to bake into a matrix.
//   gSohVRSkyTanLo/Hi     the UNION of both eyes' visible tangent range plus a
//                         sprite half-width. MK64's own bounds are keyed to the
//                         fov (+/-77 degrees against an eye that sees -60..+45),
//                         which is why compressed clouds linger at the rim.
//   gSohVRSkyTan          the A/B and RED CONTROL: 0 restores the 1.0.0.12
//                         centre-rate linear mapping exactly, which is what the
//                         off-centre falsifier must FAIL on.
//   gSohVRSkyRoll         step 4's gain. R16-B shipped it at 0 because 0058's
//                         caps extended the gradient VERTICALLY only, and a
//                         45-degree roll pulls the screen corners to a radius of
//                         200 ortho px against a quad that is 160 px wide, so
//                         the gradient's left and right edges came into view.
//                         R17-A's LATERAL caps (0058 rev4, sSohIosSkySide) closed
//                         that: the gradient now extends 2400 ortho px on all
//                         FOUR sides, and the corner-coverage check passes at
//                         +/-45 degrees. R17-B therefore SHIPS ROLL AT 1 -- it
//                         has to, because the dome sprites roll correctly by
//                         construction and a horizon that did not would be worse
//                         than either. `vr set skyroll 0` is the red control.
//                         Rotation is about the eye's OWN frustum centre, not
//                         about NDC (0,0): on an asymmetric frustum forward
//                         lands at ndc x = -(tL+tR)/span (+0.268 on this
//                         device), and rolling about the wrong point is M2
//                         wearing a rotation.
//   gSohVRSkyBuiltYawBam  written by 0051 every game frame: the yaw the sprite
//                         layout was actually built with. 0044 differences it
//                         against the yaw of the frame it is DRAWING to close
//                         M3's residual, and gSohVRSkyLagDeg reports it.
volatile float gSohVRSkyTanSum = 0.0f;
volatile float gSohVRSkySpan = 2.0f;
volatile float gSohVRSkySpanY = 2.0f;
volatile float gSohVRSkyEyeDx[2] = { 0.0f, 0.0f };
volatile float gSohVRSkyEyeSx[2] = { 1.0f, 1.0f };
volatile float gSohVRSkyTanLo = -1.2f;
volatile float gSohVRSkyTanHi = 1.2f;
volatile float gSohVRSkyRollRad[2] = { 0.0f, 0.0f };
volatile int gSohVRSkyTan = 1;
volatile float gSohVRSkyRoll = 1.0f;
volatile int gSohVRSkyBuiltYawBam = 0;
volatile unsigned int gSohVRSkyBuilds = 0;
// Telemetry, written by the eye passes (0044 rev11).
//   gSohVRSkyLagDeg     the LAST frame's dtheta: the yaw the layout was built
//                       with against the yaw of the frame drawing it. With the
//                       head still it is ~0; under a sweep it is the pose gap.
//   gSohVRSkyLagMaxDeg  its running max, cleared by `vr set r16clear 1`.
//   gSohVRSkyAffine     how many times the per-eye affine was applied, per eye
//                       SLOT -- [0] eye 1, [1] eye 2, [2] THE REAR PANE. Slot 2
//                       must stay at 0 forever: §7's risk is that
//                       sSoh3DSkySprites leaks into the pane walk, and this is
//                       that risk stated as a counter instead of a promise.
volatile float gSohVRSkyLagDeg = 0.0f;
volatile float gSohVRSkyLagMaxDeg = 0.0f;
volatile unsigned int gSohVRSkyAffine[3] = { 0, 0, 0 };
// How many eye passes actually FOLDED the pose gap in, as opposed to merely
// measuring it. `vr set skylatch 0` measures and does not correct, which is
// what makes the red/green pair a pair rather than an absence of data.
volatile unsigned int gSohVRSkyLagCorr = 0;

// ---------------------------------------------------------------------------
// R17-B — H5: THE CLOUDS BECOME WORLD GEOMETRY (docs/vr-r16-diagnosis/clouds.md
// section 7, and docs/VR-R17-NOTES.md section E).
//
// the user, on 1.0.0.13 -- the FOURTH build in which the screen-space sky has
// been corrected: "the clouds in my vr world still move around as i move my
// head, they even rotate as i rotate my head, meaning i can make a cloud turn
// on its side. plus they shake in place as i look left and right."
//
// Every one of those three clauses is a residual of CORRECTING an ortho
// layout rather than replacing it, and the residuals are structural:
//   * slide     -- whatever a first-order dtheta correction leaves at the rim,
//                  plus anything the simulator's symmetric frustum cannot show;
//   * roll      -- M5, implemented in R16-B and shipped OFF;
//   * shake     -- the layout is rebuilt at GAME rate from one snapshot yaw
//                  while 0044's dtheta term corrects it at COMPOSITOR rate, so
//                  every game frame the base moves and the correction resets.
//
// H5 removes the mapping instead of correcting it. In gSohVRSkyDome the cloud
// and star sprites are emitted as WORLD-SPACE billboards on a dome of radius
// gSohVRSkyDomeR centred on the eye, through the ordinary matrix stack, under
// the SAME per-eye A*V*P the trees are drawn with (trap A7). M1-M5 vanish by
// construction: there is no yaw->pixel mapping to get wrong, each eye projects
// its own frustum, roll falls out of the projection, and the sprites' world
// positions do not depend on the head at all, so nothing can shake when the
// head moves.
//
//   gSohVRSkyDome    1 = the dome (shipping). 0 = R16-B's ortho sprites, which
//                    is 1.0.0.13 end to end and the RED CONTROL on the same
//                    binary (trap D20). The 0044 per-eye sky affine is BYPASSED
//                    when the dome is on -- gSohVRSkyAffine[0..1] must read 0.
//   gSohVRSkyDomeR   the dome radius in GAME units. The parallax budget is
//                    (head or kart translation)/R radians: at 30000 units a
//                    whole game frame of the player's own travel (R17-A
//                    measured 6.8-9.7 units) is 0.019 degrees and one metre of
//                    head translation (~17.6 units, 0045's scale) is 0.034
//                    degrees. The far plane cannot clip it, because 0044 pins
//                    the dome span's clip z to 0.9995*w -- the same trick the
//                    ortho sky has used since rev2, expressed as a column
//                    proportional to w so it survives a perspective divide.
//   gSohVRSkyDomeSprites / Frames  emitted billboards, and game frames that
//                    emitted any. A zero here with the dome on means the branch
//                    never ran, which is the difference between "no defect" and
//                    "nobody looked" (trap D48).
volatile int gSohVRSkyDome = 1;
volatile float gSohVRSkyDomeR = 30000.0f;
// What the radius actually came out as after the fixed-point clamp (0051
// rev7's soh_ios_sky_dome_radius). Fast3D matrices are s15.16, so the dome's
// translation -- the eye plus R along a unit vector -- must stay inside
// +/-32767 or it WRAPS; the radius degrades rather than the sky teleporting.
volatile float gSohVRSkyDomeRUsed = 0.0f;
// R17-C (overlay 0051 rev8, from the R17-B code review): rev7 applied the
// 500-unit FLOOR after the headroom CAP, so the floor overrode it and an eye
// past ~32267 units got a translation outside the s15.16 range — the very
// wraparound the cap exists to prevent, produced by the clamp itself. The cap
// is absolute now. gSohVRSkyDomeEyeMax is the |eye| the bound was evaluated at,
// published so the assert is arithmetic on the function's own outputs.
volatile float gSohVRSkyDomeEyeMax = 0.0f;
volatile float gSohVRSkyDomeEyeFault = 0.0f;  // inject that |eye|; 0 = off
volatile int gSohVRSkyDomeFloorFault = 0;     // 1 = rev7's order; the RED CONTROL
volatile unsigned int gSohVRSkyDomeSprites = 0;
volatile unsigned int gSohVRSkyDomeFrames = 0;
// THE PROBE SPRITE (the falsifier's "pick one cloud"). 0051 publishes, for the
// FIRST sky actor of screen 0 and in BOTH arms, the quantities the two sides of
// the falsifier need:
//   gSohVRSkyProbeDir   its world DIRECTION, unit, GAME space. Derived from the
//                       authored rotY/mY alone -- no head pose, no eye matrix,
//                       no sprite path -- so it is the ground truth in the red
//                       arm as much as in the green one (trap D11 (a)).
//   gSohVRSkyProbePos   the dome point it was actually drawn at (dome arm), or
//                       its ortho vertex (mX, posY, 0) (ortho arm). w = 1 in
//                       both, so 0044 projects it through the very matrix the
//                       pass draws with.
//   gSohVRSkyProbeUp    the same point displaced by the quad's own +up edge,
//                       for the roll assert.
//   gSohVRSkyProbeAz/El/HalfDeg  the authored angles the conversion produced.
// gSohVRSkyProbeTargetBam selects WHICH sprite the probe follows: the drawn
// one whose |cameraRot| is nearest this angle. 0 (the default) is the cloud
// under the eye's forward; `vr set skyprobe 45` follows one 45 degrees off the
// heading instead, which is where M1's tangent-vs-linear error lives and where
// the user's slide is worst. Both arms select by the same quantity, so the two
// arms always follow the same cloud.
volatile int gSohVRSkyProbeTargetBam = 0;
volatile int gSohVRSkyProbeValid = 0;
volatile int gSohVRSkyProbeOrtho = 0;   // 1 = Pos/Up are ortho px, not world
volatile float gSohVRSkyProbeDir[3] = { 0.0f, 0.0f, 1.0f };
volatile float gSohVRSkyProbePos[3] = { 0.0f, 0.0f, 0.0f };
volatile float gSohVRSkyProbeUp[3] = { 0.0f, 0.0f, 0.0f };
volatile float gSohVRSkyProbeAzDeg = 0.0f;
volatile float gSohVRSkyProbeElDeg = 0.0f;
volatile float gSohVRSkyProbeHalfDeg = 0.0f;
// Written by 0044 in the sky-sprite span, per eye slot, in BOTH arms:
//   gSohVRSkyWalkNdc  where the pass ACTUALLY put the probe sprite, projected
//                     through `out` after every substitution the pass makes.
//   gSohVRSkyRefNdc   where the WORLD puts the same direction, projected
//                     through the composed eye matrix with w = 0. Two paths
//                     that share no code below the eye matrix.
//   gSohVRSkyDomeErr  |walk - ref| per eye, and its running max.
//   gSohVRSkyDomeJit  the mean |SECOND DIFFERENCE| of (walk - ref) across
//                     consecutive walks of the same eye. A constant offset and
//                     a constant RATE both differentiate to zero, so this
//                     isolates the 30 Hz staircase and nothing else -- it is
//                     the user's "shake in place as I look left and right" as a
//                     number, and it is measured in both arms.
//   gSohVRSkyUpDot    cos of the angle between the sprite quad's projected up
//                     edge and the projected world up. 1.0 = upright.
volatile float gSohVRSkyWalkNdc[2][2] = { { 0.0f, 0.0f }, { 0.0f, 0.0f } };
volatile float gSohVRSkyRefNdc[2][2] = { { 0.0f, 0.0f }, { 0.0f, 0.0f } };
volatile float gSohVRSkyDomeErr[2] = { -1.0f, -1.0f };
volatile float gSohVRSkyDomeErrMax[2] = { 0.0f, 0.0f };
volatile float gSohVRSkyDomeJit[2] = { 0.0f, 0.0f };
volatile unsigned int gSohVRSkyDomeJitN[2] = { 0, 0 };
volatile float gSohVRSkyUpDot[2] = { 0.0f, 0.0f };
volatile float gSohVRSkyStereoNdc = 0.0f;   // walk ndc eye0 - eye1
volatile unsigned int gSohVRSkyWalks[3] = { 0, 0, 0 };
// R14 item 4 — the VR pad mask (C buttons + L) and its A/B control. See the
// note at SohVRSense_WritePad. 1 = shipping, 0 = the 1.0.0.10 pad, which is the
// red control the C-left assert needs to be worth anything.
volatile int gSohVRPadMask = 1;
volatile unsigned int gSohVRPadMasked = 0;
// The injector (session only; the suite asserts it ships 0).
volatile int gSohVRPadInject = 0;
// R13 item 1d — THE FAILURE-INJECTION KNOB the alloc-fail work never had.
// `vr set fbfail <n>` makes the Nth next framebuffer-attachment allocation
// return nil (overlay 0055 rev3 consumes it, and the compositor's eye-copy
// allocation consumes it too). Until this existed `alloc_fails=0` in a green
// run was a tautology: nothing in the tree could make it non-zero. Session
// only, never persisted, and the suite asserts it ships at 0.
volatile int gSohIosGfxFbFailIn = 0;
// R11 item 3 telemetry (overlay 0054 rev3), same defined-on-every-target rule.
//   gSohVRCullKartsKept  — karts the FORWARD view cone rejected and the VR
//                          angle-cull override admitted anyway. > 0 is the
//                          proof that "the rear view has no karts in it" is
//                          actually fixed rather than merely compiled in.
//   gSohVROwnShadowTags  — how many times the local kart's shadow has been
//                          bracketed with the 0x5C/0x5D sentinels.
volatile unsigned int gSohVRCullKartsKept = 0;
volatile unsigned int gSohVROwnShadowTags = 0;
//   gSohVRKartsListed    — how many karts this frame's display list contains,
//                          i.e. how many the rear-view walk is handed. The
//                          scene-independent half of the item-3b assert.
volatile unsigned int gSohVRKartsListed = 0;
// R11 item 3b: D11's red control for the cone override. 1 makes MK64's
// view-cone test reject everything, so the override is the only thing that can
// put a kart in the render list. Diagnostic only, never persisted.
volatile int gSohVRConeFault = 0;
// R10 item 2: the ONE engine-side row of the device bisect kit (overlay
// 0058). 1 = every texture samples LOD 0 and no new upload is mipmapped, so
// the deferred-mip-chain rainbow suspect can be ruled in or out from inside
// the headset. 0 in every shipping frame; defined here for the same reason
// the block above is (the engine's externs are strong on every target).
volatile int gSohVRDiagNoMips = 0;
// R9 harness (overlay 0057): an MK64 item id to hand player one, or -1 for
// "do nothing". Consumed once, at check_player_use_item. Only the dev
// console bridge ever writes it, and that is compiled out of public builds.
volatile int gSohVRDbgGrantItem = -1;
volatile int gSohVRKartRollBam = 0;
volatile int gSohVRKartTumble = 0;
volatile int gSohVRKartHitEffect = 0;
// R10 item 5 (overlay 0054 rev2): 1 while MK64 is ADVANCING the tumble phase
// — the low tumble (a green shell), the item tumble, the 0x1000000 tumble and
// lightning. This is the gate the somersault composition needed; rev1 asked
// for HIT_EFFECT, which is a wall scrape, so the flip never fired.
volatile int gSohVRKartTumbling = 0;
// R10 item 5 (overlay 0051 rev5): the effects mask the comfort hold treats as
// a spin, published from the compiled macro so the suite asserts the SHIPPED
// set (banana 0x800, green shell 0x400, spinning-out 0x40|0x80, item, bolt).
volatile unsigned int gSohVRSpinEffectMask = 0;

// VR R6 (the first-person seat). Overlay 0045 rev2 exports the PLAYER KART's
// own pose from gPlayerOne at the GameCamera export site. Same
// defined-on-every-target rule as the block above: the engine's externs are
// strong and __IOS__ is defined on iPhone too.
//   gSohVRKartPos    — the kart's world position, GAME units.
//   gSohVRKartVel    — its velocity, for the "gaze faces the direction of
//                      travel" cross-check.
//   gSohVRKartYawBam — its yaw in MK64 binary angles, in the CAMERA (atan2s)
//                      convention: forward is (sins(yaw), *, coss(yaw)).
//                      R8 / overlay 0045 rev3: this is NOT player->rotation[1]
//                      raw — MK64's kart yaw runs the other way round
//                      (func_8002AE38 advances the kart by sins(-rotation[1]))
//                      and 0045 negates it at the export so exactly one
//                      convention crosses this boundary. Shipping the raw
//                      value is what made steering inverted-orbit in 1.0.0.4.
//   gSohVRKartValid  — 1 once a player-1 racing camera has ever exported a
//                      kart. R16-A: it is NO LONGER CLEARED at the head of the
//                      game frame — see below.
//
// R16-A (F1) — THE HOLE, AND WHY IT WAS THE WHOLE OF (b).
//
// rev2 cleared gSohVRKartValid at the top of game_state_handler and re-raised
// it mid-frame, inside SohVRExportKartPose, which runs during display-list
// construction — i.e. AFTER the whole game update. So on every single game
// frame there was a window, the length of the update, in which "there is no
// kart" was true while a kart existed and was being raced. The compositor
// reads that flag asynchronously at 90-120 Hz, and a compositor frame landing
// in the hole composed the world from the CHASE CAMERA instead: the seat
// jumped to the camera's look-at point (a target AHEAD of the kart — the very
// error R6 removed), the neutral forward became the chase camera's heading
// (mid-corner, tens of degrees off the kart's), and the yaw follower SNAPPED,
// because its time constant was armed only when the seat came from the kart.
// One frame, both eyes, large rotation, self-correcting in ~4 frames, worst in
// a hard corner. That is the user's "the world will violently turn in a flash of
// an eye then fix itself", and `seatflips` had been reading 71-87 per session
// on every "green" suite run with nobody asserting it.
//
// The replacement expresses "no kart" by STALENESS instead of by a hole:
//   gSohVRKartSeq   — a SEQLOCK. Odd while the export is writing, even when
//                     the snapshot is complete. It also closes a real torn
//                     read: three position floats written non-atomically and
//                     consumed by a 120 Hz reader.
//   gSohVRKartFrame — the game frame the snapshot belongs to.
//   gSohVRGameFrame — incremented at the head of every game_state_handler,
//                     which is where the clear used to be. Menus, podium,
//                     fly-by and quit transitions stop exporting, so the age
//                     climbs and the seat falls back within
//                     SOHVR_KART_STALE_FRAMES — which is what the clear was
//                     FOR — while a racing frame can never be invalid.
volatile float gSohVRKartPos[3] = { 0, 0, 0 };
// VR R17-A item 1 (overlay 0045 rev6): the previous game frame's kart
// position, published inside the same seqlock.
volatile float gSohVRKartPosPrev[3] = { 0, 0, 0 };
volatile float gSohVRKartVel[3] = { 0, 0, 0 };
volatile int gSohVRKartYawBam = 0;
volatile int gSohVRKartValid = 0;
volatile unsigned int gSohVRKartSeq = 0;
volatile unsigned int gSohVRKartFrame = 0;
volatile unsigned int gSohVRGameFrame = 0;

// VR R17-A item 1 — THE GHOST DRIVERS, and the machinery that measures them.
//
// ProcessGfxCommands walks the display list N times per GAME frame at
// FrameInterpolation_Interpolate(t) (N = 2 in VR: t = 0.5, then 1.0), so every
// OBJECT it draws advances in sub-frame steps. The VR seat did not: 0044
// composed its eye matrices from a kart pose exported once per game frame. So
// relative to the seat a nearby kart alternated between "on time" and "half a
// game frame ahead" on every present -- a monocular, un-screenshottable,
// speed- and parallax-proportional double image, worst on sharp turns and
// absent at rest. Every clause of the user's 1.0.0.13 report follows from it.
//
//   gSohVRWalkT      overlay 0014 rev2: this walk's own t (1.0 = key frame).
//   gSohVRSeatInterp the A/B. 1 = the seat is lerped with the walk's t
//                    (shipping); 0 = 1.0.0.13 exactly, and the RED CONTROL.
//   gSohVRGhost*     the PROBE, which measures in both arms (trap D48). Per
//                    walk it takes the interpolated GAME camera position
//                    recovered from the display list's own combined
//                    view-projection -- FrameInterpolation's output, sharing no
//                    code with the seat -- minus the seat the eye matrix was
//                    actually composed with, and accumulates the SECOND
//                    DIFFERENCE of that, which is zero for any constant
//                    velocity and equals one whole game frame of travel for a
//                    seat that steps while the world glides.
volatile float gSohVRWalkT = 1.0f;
volatile int gSohVRSeatInterp = 1;
volatile unsigned int gSohVRGhostN = 0;      // walks sampled
volatile float gSohVRGhostJitter = 0.0f;     // mean |2nd difference|, game units
volatile float gSohVRGhostJitterMax = 0.0f;  // worst single sample
volatile float gSohVRGhostStep = 0.0f;       // mean |1st difference| (the walk step)
volatile float gSohVRGhostTMin = 9.0f;       // the t values the walks actually ran at
volatile float gSohVRGhostTMax = -9.0f;
volatile float gSohVRGhostKeyErr = -1.0f;    // |recovered cam eye - gSoh3DCamEye| at t == 1
volatile unsigned int gSohVRGhostKeyN = 0;
volatile float gSohVRSeatDx[3] = { 0.0f, 0.0f, 0.0f }; // the correction just applied
volatile unsigned int gSohVRSeatLerps = 0;   // walks the correction was applied on
volatile unsigned int gSohVRSeatJumps = 0;   // segments rejected as a teleport
// R17-C (overlay 0045 rev7, from the R17-A code review) — THE SEED. rev6 set
// prev = cur on EVERY export, so the first export after a discontinuity paired
// this frame's pose with the pose from before a menu, a fly-by or a race
// restart. A retry respawns on the grid, which is near the finish line the last
// export left the kart on, so the delta is UNDER the 400-unit teleport
// heuristic and is spent as a one-frame seat nudge — R16-A's violent snap.
// 0045 rev7 seeds prev = cur across every such transition.
//   gSohVRSeatSeeds     seeded exports; the "it is in the path" counter.
//   gSohVRSeatSeedFault 0 = shipping. 1 = rev6 exactly (never seed) — the RED
//                       CONTROL. N > 1 = never seed AND fabricate a stale prev
//                       N units away on the first export after a discontinuity,
//                       so the defect has a KNOWN magnitude instead of one that
//                       depends on where the previous race happened to end.
volatile unsigned int gSohVRSeatSeeds = 0;
// R17-C (overlay 0044 rev14): the WATERMARKS the seed fix is asserted on. The
// ghost probe averages over walks and cannot bound ONE walk; these do.
//   gSohVRSeatDeltaMax  the longest segment the seat was asked to interpolate
//                       along, read BEFORE the 400-unit teleport guard.
//   gSohVRSeatDxMax     the largest world translation the correction applied.
// Both cleared by Soh3DGhostReset(), i.e. by `vr set seatinterp` / `seatseedfault`.
volatile float gSohVRSeatDeltaMax = 0.0f;
volatile float gSohVRSeatDxMax = 0.0f;
volatile float gSohVRSeatSeedFault = 0.0f;
// VR R18-A (overlay 0044 rev15, 0054 rev6, 0065) — ONE CLOCK FOR THE SEAT.
//   gSohVRSeatRebase   1 = shipping: the eye matrix is corrected by
//                      (current export - the base the compositor composed it
//                      from) as well as R17-A's (prev - cur)(1 - t). 0 =
//                      1.0.0.16 exactly (the RED CONTROL for this round).
//   gSohVRClassProbe   dev only: 1 makes the game emit G_NOOP 0x70/0x71
//                      class sentinels around the shadow, kart, boost and
//                      particle matrices, and makes 0044 measure, per walk,
//                      each class's drawn position against the eye position
//                      recovered from the ACTUAL composed eye matrix. 0 =
//                      every shipped build: no sentinel is emitted.
//   gSohVRBase*        cause-side telemetry, measured in every arm (D48):
//                      walks whose snapshot base was not the current export.
volatile int gSohVRSeatRebase = 1;
volatile int gSohVRClassProbe = 0;
volatile unsigned int gSohVRBaseWalks = 0;     // eye-1 walks examined
volatile unsigned int gSohVRBaseStale = 0;     // ... whose base != current export
volatile float gSohVRBaseErrMax = 0.0f;        // worst |current export - base|
volatile float gSohVRBaseErrAcc = 0.0f;        // sum, for the mean
volatile unsigned int gSohVRSeatRebases = 0;   // walks the rebase changed the matrix on

// VR R16-C (overlay 0045 rev5) — MK64'S OWN LOOK-BEHIND CAMERA.
//
// The rear-view pane has pivoted its 180-degree world rotation about
// `gSoh3DCamEye + gSoh3DCamFwd * gSoh3DCamDist` since R3. That expression is
// the chase camera's LOOK-AT POINT, and MK64 aims its racing camera at a
// target 70 units AHEAD of the kart (src/camera.c:118-123, unk_3C = (0,0,70))
// — 0045 rev2's own header says so, and R6 fixed the SEAT with the kart export
// and never came back for the pane. So the pane's camera has been sitting 140
// game units in front of where a mirror belongs: the bottom 54% of the pane
// was road AHEAD of the kart drawn backwards, and everything genuinely behind
// was squeezed into the few per cent between there and the horizon. That is
// the user's "too low / close to the road" and most of "it cannot render the
// distance".
//
// The game already owns the right camera. `LookBehindCamera` is a second
// Camera object created for player 1 at spawn whose only difference from the
// chase camera is the Z sign of both kart-local offsets — same height above
// the kart, same pitch, same FOV, same smoothing, and MK64's own WALL PUSHOUT,
// which an analytic mirror about the kart cannot have (in Toad's Turnpike's
// tunnel the analytic mirror can put the pane camera inside the wall). And
// World::TickCameras ticks it EVERY frame whether or not C-left is held, so
// this pose is live, warm and free.
//
// SEQLOCK + frame stamp rather than a validity flag: trap D40, the same
// discipline rev4 gave the kart pose, for the same reason (a 90-120 Hz
// consumer reading floats a ~30 Hz writer stores).
volatile float gSohVRRearPos[3] = { 0, 0, 0 };
volatile float gSohVRRearAt[3] = { 0, 0, 0 };
volatile float gSohVRRearUp[3] = { 0, 1, 0 };
volatile int gSohVRRearValid = 0;
volatile unsigned int gSohVRRearSeq = 0;
volatile unsigned int gSohVRRearFrame = 0;
// VR R21 item 2 (overlay 0045 rev8, 0044 rev16) — THE PANE ON THE WALK'S CLOCK.
//   gSohVRRearPosPrev  the look-behind camera's previous game frame eye, in
//                      the same seqlock as gSohVRRearPos (seeded = cur on a
//                      discontinuity; gSohVRRearSeeds counts those).
//   gSohVRPaneLerp     1 = shipping: the pane's view is built around the
//                      look-behind camera at the walk's own t and around the
//                      game eye the walk's matrix actually carries. 0 =
//                      1.0.1.19 exactly (the RED CONTROL).
//   gSohVRPaneLerps / gSohVRPaneDxMax  applications and the largest
//                      correction (game units), counted in BOTH arms' walks
//                      only when applied (the probe is `vr classes` in
//                      classprobe 2 = the pane walk, which measures both).
volatile float gSohVRRearPosPrev[3] = { 0, 0, 0 };
volatile unsigned int gSohVRRearSeeds = 0;
volatile int gSohVRPaneLerp = 1;
volatile unsigned int gSohVRPaneLerps = 0;
volatile float gSohVRPaneDxMax = 0.0f;
// VR R21 item 3 (overlay 0059 rev2) — THE CINEMATIC CAMERAS. In the results
// and the attract demo MK64's camera is a scripted trackside one (mode 3)
// while the first-person seat stays in player 1's kart, and the course
// section list was picked from the CAMERA. Telemetry is written every VR
// world frame in both arms; gSohVRCineSec is the fix (see the patch header).
volatile int gSohVRCineSec = 1; // ships ON (measured R21, VR-R21-NOTES §3)
volatile int gSohVRCineMode = -1, gSohVRCinePlayer = -1, gSohVRCineCamDir = -1, gSohVRCineSeatDir = -1;
volatile int gSohVRCineCamSec = -1, gSohVRCinePlySec = -1, gSohVRCineIndex = -1, gSohVRCineOwn = -1;
volatile unsigned int gSohVRCineFrames = 0, gSohVRCineDirDiff = 0, gSohVRCineSecDiff = 0, gSohVRCineOverrides = 0;
volatile float gSohVRCineCamKart = 0.0f, gSohVRCineExportErr = 0.0f;

// VR R3 (the rear-view pane, spec D12). Same defined-everywhere rule.
//   gSohVRMirrorActive — 1 = run the THIRD interpreter walk this host frame.
//                      Set by the VR loop only while the pane is visible, so
//                      the pane costs exactly nothing when it is not up.
//   gSoh3DMirrorTexture — the mirror framebuffer's texture, published on GPU
//                      completion exactly like the eyes and the HUD.
//   gSohVRMirrorW/H  — the mirror framebuffer extent (its own sizing domain,
//                      trap D7; the shell derives it from the eye extent x
//                      the pane's render scale so the ASPECT matches — the
//                      mirror walk reuses the game's own projection, which
//                      carries the game's aspect).
//   gSohVRRearItemSeq — a monotone counter bumped by overlay 0051 every time
//                      the 1P kart puts an item out BEHIND it (a backward
//                      shell throw, a dropped banana, a dropped bunch
//                      banana). A forward fire never bumps it. The loop
//                      edge-detects it for the 3 s auto-show.
volatile int gSohVRMirrorActive = 0;
void* volatile gSoh3DMirrorTexture = NULL;
volatile int gSohVRMirrorW = 0, gSohVRMirrorH = 0;
volatile unsigned int gSohVRRearItemSeq = 0;

// VR R4 (spec D13). Both are read by GAME code on every target — overlay
// 0051 rev3's throw macros and 0053's armed-item export are __IOS__-guarded,
// not visionOS-guarded — so they are defined HERE, in the shell every target
// compiles, and not in the visionOS-only SohSense.m. (The iPhone link failed
// exactly this way once; that is why the rule exists.) On iOS nothing ever
// writes them, so the game keeps its stock behaviour bit for bit.
//   gSohVRItemArmed — MK64's armed item for player 1 (0053).
//   gSohVRThrowDir  — the physical throw's vote: 0 none, 1 forward, 2 back.
volatile int gSohVRItemArmed = 0;
volatile int gSohVRThrowDir = 0;

// The pose rendezvous (spec D2/D7, trap B1). The compositor loop composes
// A*V*P for both eyes at the frame's trackable-anchor time and publishes it
// with a monotone frame id; the engine takes the latest pair ONCE per host
// frame and hands the id back with the rendered eye textures, so the loop can
// submit the anchor the frame was actually rendered against. A plain mutex
// held for a 128-byte memcpy — no waiting, so neither side can stall the
// other (a strict rendezvous would peg the engine to the present rate and
// halve it right back, which is trap A1 by another road).
static pthread_mutex_t sSohVREyeMutex = PTHREAD_MUTEX_INITIALIZER;
static float sSohVREyePub[32];
static unsigned int sSohVREyePubId = 0;

void SohIosVR_PublishEyes(const float* m, unsigned int frameId) {
    pthread_mutex_lock(&sSohVREyeMutex);
    memcpy(sSohVREyePub, m, sizeof(sSohVREyePub));
    sSohVREyePubId = frameId;
    pthread_mutex_unlock(&sSohVREyeMutex);
}

// R16-A (F4) — the same rendezvous, widened from 32 floats to the whole
// snapshot. See SohIosShell.h for what it carries and why.
//
// A NOTE ON "THE HEAD OF THE HOST FRAME", because the diagnosis and the engine
// disagree about what a host frame is. The graphics frame runs at ~114 Hz here
// and the GAME frame at ~28 (frame interpolation replays one command list
// several times), and the eye matrices are acquired on the GRAPHICS frame —
// which is what keeps the composed pose moving at the compositor's rate. So
// the snapshot is latched exactly where the matrices already were, at
// Soh3DSetEye(1): both eye passes then read ONE copy, and the game update
// reads the most recently latched copy as a coherent set through the
// gSohVRSnap* mirror below, instead of sampling four live globals at four
// different instants. Moving the acquire down to the game frame would have
// dropped the composed pose to engine rate — a 4x pose-rate regression, which
// in a headset is not a nuance.
static SohVRFrameSnapshot sSohVRSnapPub;  // last published (compositor writes)
static SohVRFrameSnapshot sSohVRSnapCur;  // last latched (engine reads)
// The latched copy, mirrored for the game update. R16-B's per-eye cloud
// placement consumes these; nothing reads them yet beyond the dump line.
volatile unsigned int gSohVRSnapId = 0;
volatile float gSohVRSnapSkyShift[2] = { 0.0f, 0.0f };
volatile float gSohVRSnapSkyPxPerBam = 0.0f, gSohVRSnapSkyPxCenter = 0.0f;
volatile int gSohVRSnapEyeYawBam = 0;
volatile float gSohVRSnapEyePosGame[3] = { 0.0f, 0.0f, 0.0f };
volatile int gSohVRSnapWorldActive = 0;
volatile unsigned int gSohVRSnapLatches = 0;
// R16-B: the sky-placement half of the mirror. 0051 builds the sprite layout
// from THESE, never from the live globals -- that is M3 closed at the source
// rather than only corrected downstream.
volatile float gSohVRSnapSkyTanSum = 0.0f;
volatile float gSohVRSnapSkySpan = 2.0f;
volatile float gSohVRSnapSkyTanLo = -1.2f;
volatile float gSohVRSnapSkyTanHi = 1.2f;

void SohIosVR_PublishFrame(const SohVRFrameSnapshot* snap) {
    if (snap == NULL) {
        return;
    }
    pthread_mutex_lock(&sSohVREyeMutex);
    sSohVRSnapPub = *snap;
    // Keep the legacy 32-float rendezvous in step: it is the same data, and a
    // divergence between the two would be the exact class of bug this round
    // exists to remove.
    memcpy(sSohVREyePub, snap->eyeM, sizeof(sSohVREyePub));
    sSohVREyePubId = snap->id;
    pthread_mutex_unlock(&sSohVREyeMutex);
}

unsigned int SohIosVR_AcquireFrame(float outM[32], float outSky[SOHVR_SKY_SLOTS]) {
    pthread_mutex_lock(&sSohVREyeMutex);
    sSohVRSnapCur = sSohVRSnapPub;
    pthread_mutex_unlock(&sSohVREyeMutex);
    if (outM != NULL) {
        memcpy(outM, sSohVRSnapCur.eyeM, sizeof(sSohVRSnapCur.eyeM));
    }
    if (outSky != NULL) {
        // R16-B: the WHOLE sky payload, in the named slots SohIosShell.h
        // defines and 0044 rev11 mirrors. Everything an eye pass places the
        // sky with now leaves this one latched copy together.
        for (int i = 0; i < SOHVR_SKY_SLOTS; i++) {
            outSky[i] = 0.0f;
        }
        outSky[SOHVR_SKY_SHIFT0] = sSohVRSnapCur.skyShift[0];
        outSky[SOHVR_SKY_SHIFT1] = sSohVRSnapCur.skyShift[1];
        outSky[SOHVR_SKY_DX0] = sSohVRSnapCur.skyEyeDx[0];
        outSky[SOHVR_SKY_DX1] = sSohVRSnapCur.skyEyeDx[1];
        outSky[SOHVR_SKY_SX0] = sSohVRSnapCur.skyEyeSx[0];
        outSky[SOHVR_SKY_SX1] = sSohVRSnapCur.skyEyeSx[1];
        outSky[SOHVR_SKY_ROLL0] = sSohVRSnapCur.skyRollRad[0];
        outSky[SOHVR_SKY_ROLL1] = sSohVRSnapCur.skyRollRad[1];
        outSky[SOHVR_SKY_TANSUM] = sSohVRSnapCur.skyTanSum;
        outSky[SOHVR_SKY_SPAN] = sSohVRSnapCur.skySpan;
        outSky[SOHVR_SKY_YAWBAM] = (float)sSohVRSnapCur.eyeYawBam;
        outSky[SOHVR_SKY_TANLO] = sSohVRSnapCur.skyTanLo;
        outSky[SOHVR_SKY_TANHI] = sSohVRSnapCur.skyTanHi;
        outSky[SOHVR_SKY_SPANY] = sSohVRSnapCur.skySpanY;
        // VR R17-A item 1: the seat and its interpolation segment ride the same
        // latched copy as everything else. One acquire, one moment (F4's rule).
        outSky[SOHVR_SEAT_DX0] = sSohVRSnapCur.seatPrevDelta[0];
        outSky[SOHVR_SEAT_DX1] = sSohVRSnapCur.seatPrevDelta[1];
        outSky[SOHVR_SEAT_DX2] = sSohVRSnapCur.seatPrevDelta[2];
        outSky[SOHVR_SEAT_SRC] = (float)sSohVRSnapCur.seatSrc;
        outSky[SOHVR_SEAT_X] = sSohVRSnapCur.seatGame[0];
        outSky[SOHVR_SEAT_Y] = sSohVRSnapCur.seatGame[1];
        outSky[SOHVR_SEAT_Z] = sSohVRSnapCur.seatGame[2];
        // VR R18-A: the raw base the seat was built from, and its game frame.
        outSky[SOHVR_SEAT_BX] = sSohVRSnapCur.seatBase[0];
        outSky[SOHVR_SEAT_BY] = sSohVRSnapCur.seatBase[1];
        outSky[SOHVR_SEAT_BZ] = sSohVRSnapCur.seatBase[2];
        outSky[SOHVR_SEAT_BF] = (float)sSohVRSnapCur.seatBaseFrame;
    }
    gSohVRSnapId = sSohVRSnapCur.id;
    gSohVRSnapSkyShift[0] = sSohVRSnapCur.skyShift[0];
    gSohVRSnapSkyShift[1] = sSohVRSnapCur.skyShift[1];
    gSohVRSnapSkyPxPerBam = sSohVRSnapCur.skyPxPerBam;
    gSohVRSnapSkyPxCenter = sSohVRSnapCur.skyPxCenter;
    gSohVRSnapEyeYawBam = sSohVRSnapCur.eyeYawBam;
    gSohVRSnapEyePosGame[0] = sSohVRSnapCur.eyePosGame[0];
    gSohVRSnapEyePosGame[1] = sSohVRSnapCur.eyePosGame[1];
    gSohVRSnapEyePosGame[2] = sSohVRSnapCur.eyePosGame[2];
    gSohVRSnapWorldActive = sSohVRSnapCur.worldActive;
    // R16-B: the sprite layout's reference frustum, for the GAME update (0051).
    gSohVRSnapSkyTanSum = sSohVRSnapCur.skyTanSum;
    gSohVRSnapSkySpan = sSohVRSnapCur.skySpan;
    gSohVRSnapSkyTanLo = sSohVRSnapCur.skyTanLo;
    gSohVRSnapSkyTanHi = sSohVRSnapCur.skyTanHi;
    gSohVRSnapLatches = gSohVRSnapLatches + 1;
    return sSohVRSnapCur.id;
}

// Returns the frame id of the pair copied out; 0 means "nothing published
// yet" and the caller leaves the game's own matrices alone.
unsigned int SohIosVR_AcquireEyes(float* out) {
    pthread_mutex_lock(&sSohVREyeMutex);
    memcpy(out, sSohVREyePub, sizeof(sSohVREyePub));
    unsigned int id = sSohVREyePubId;
    pthread_mutex_unlock(&sSohVREyeMutex);
    return id;
}
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <SDL.h>
#import <SDL_syswm.h>
#import "SohIosShell.h"

#include <arpa/inet.h>
#include <execinfo.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <sys/ucontext.h>
#include <stdarg.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <objc/runtime.h> // iOS 27 scene-config hook grafted onto SDL's app delegate (D11)

#pragma mark - Instrumentation helpers

// Thermal state for the perf probe (overlay 0008): 0 nominal, 1 fair,
// 2 serious, 3 critical (NSProcessInfoThermalState).
int SohIos_ThermalState(void) {
    return (int)NSProcessInfo.processInfo.thermalState;
}

// D12 (overlay 0061's SOH_PACE line, = Shipwright D-084): power state beside
// thermal, because Low Power Mode caps the panel at 60 Hz and charging heats
// the phone before thermalState moves. Bits: 1 = Low Power Mode, 2 = charging,
// 4 = full (plugged in), 8 = battery state unknown. Game (main) thread.
int SohIos_PowerState(void) {
    int bits = NSProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0;
#if !TARGET_OS_VISION
    UIDevice* dev = UIDevice.currentDevice;
    if (!dev.batteryMonitoringEnabled) {
        dev.batteryMonitoringEnabled = YES;
    }
    switch (dev.batteryState) {
        case UIDeviceBatteryStateCharging: bits |= 2; break;
        case UIDeviceBatteryStateFull: bits |= 4; break;
        case UIDeviceBatteryStateUnknown: bits |= 8; break;
        default: break;
    }
#endif
    return bits;
}

// Menu visibility, exported by overlay 0013 (OTRGlobals.cpp) — drives the
// touch overlay's auto-hide.
extern int SohIos_IsMenuOpen(void);

// Backgrounded flag, read by the Metal backend (overlay 0016) to stop
// rendering while suspended: nextDrawable in the background is the classic
// cause of post-resume slowdowns and watchdog kills. volatile is enough —
// one writer (main thread), reader tolerates staleness of a frame.
static volatile int gSohIosBackgrounded = 0;
void SohIos_SetBackgrounded(int backgrounded) {
    if (gSohIosBackgrounded != backgrounded) {
        NSLog(@"[SohIosShell] backgrounded=%d", backgrounded);
    }
    gSohIosBackgrounded = backgrounded;
}
int SohIos_IsBackgrounded(void) {
    return gSohIosBackgrounded;
}

// Park tick for overlay 0016. On iOS the game loop RUNS ON THE MAIN
// THREAD (SDL_main), so a sleeping park loop would block the run loop and
// deadlock: the very notifications/timers that clear the backgrounded
// flag are delivered by that run loop (root cause of the black-screen-
// with-audio resume, reproduced on sim 2026-07-12). Instead, service the
// run loop while parked — lifecycle events keep flowing and the flag
// clears the moment the scene foregrounds.
void SohIos_ParkTick(void) {
    if (NSThread.isMainThread) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    } else {
        struct timespec nap = { 0, 50 * 1000 * 1000 };
        nanosleep(&nap, NULL);
    }
}

// Device feedback 2026-07-12: resume sometimes came back to a black screen
// with audio and dead input — the signature of the 0016 park never
// releasing because the scene delegate's foreground callbacks didn't fire.
// Three independent clears now: scene-delegate methods, scene
// notifications (always post), and a 1 s main-thread reconciler — timers
// are frozen while suspended and resume with the run loop, so even if
// every callback path fails, the flag clears within a second of the app
// actually being active again.
static void SohIos_InstallBackgroundReconciler(void) {
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidEnterBackgroundNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* n) {
                                                    NSLog(@"[SohIosShell] notif SceneDidEnterBackground");
                                                    SohIos_SetBackgrounded(1);
                                                }];
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneWillEnterForegroundNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* n) {
                                                    NSLog(@"[SohIosShell] notif SceneWillEnterForeground");
                                                    SohIos_SetBackgrounded(0);
                                                }];
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* n) {
                                                    NSLog(@"[SohIosShell] notif SceneDidActivate");
                                                    SohIos_SetBackgrounded(0);
#if TARGET_OS_VISION
                                                    // A resize-stress scene reconnect delivers a NEW scene; the
                                                    // 0026 main-guard stops the engine re-boot, but the existing
                                                    // SDL window must move onto the new scene or it stays black.
                                                    if ([n.object isKindOfClass:UIWindowScene.class]) {
                                                        UIWindowScene* scene = (UIWindowScene*)n.object;
                                                        for (UIWindow* w in UIApplication.sharedApplication.windows) {
                                                            if (w.isKeyWindow && w.windowScene != scene) {
                                                                NSLog(@"[SohIosShell] re-attaching SDL window to reconnected scene");
                                                                w.windowScene = scene;
                                                                SohIos_GlueWindowToScene(w, scene);
                                                            }
                                                        }
                                                    }
#endif
                                                }];
#if TARGET_OS_VISION
    // D-030: the game loop owns the main thread and SDL's event pump spins the
    // runloop with ~zero timeout, which never reaches the point where the GCD
    // MAIN QUEUE drains — dispatch_async(main) blocks and every SwiftUI
    // main-actor job (ornament button actions, onChange -> openImmersiveSpace)
    // starve forever (the historical bridge dispatch_sync deadlock, same
    // mechanism). Timers DO fire from the pump, so a 60 Hz timer runs the
    // runloop for 0.5 ms in default mode — long enough to hit beforeWaiting
    // and service the main queue. ~0.5 ms of the frame budget, visionOS-only.
    // Belt and suspenders: run the loop briefly (services sources/timers) AND
    // invoke libdispatch's main-queue drain entry directly — SDL's 2 µs pump
    // spins never reach the runloop's own drain point (empirical: the
    // historical bridge dispatch_sync deadlock), and this is the canonical
    // game-engine escape hatch for exactly this loop shape. Main thread +
    // runloop-callout context only (both true in a timer callback).
    extern void _dispatch_main_queue_callback_4CF(void* msg);
    extern volatile int gSoh3DDrainTicks;
    NSTimer* gcdDrain = [NSTimer timerWithTimeInterval:(1.0 / 60.0)
                                               repeats:YES
                                                 block:^(NSTimer* t) {
                                                     gSoh3DDrainTicks++;
                                                     CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0005, false);
                                                     _dispatch_main_queue_callback_4CF(NULL);
                                                 }];
    [NSRunLoop.mainRunLoop addTimer:gcdDrain forMode:NSRunLoopCommonModes];
#endif
    NSTimer* reconciler = [NSTimer timerWithTimeInterval:1.0
                                                 repeats:YES
                                                   block:^(NSTimer* t) {
                                                       static int ticks = 0;
                                                       if (gSohIosBackgrounded && (++ticks % 5 == 0)) {
                                                           NSLog(@"[SohIosShell] reconciler: flag=1 appState=%ld",
                                                                 (long)UIApplication.sharedApplication.applicationState);
                                                       }
                                                       if (gSohIosBackgrounded &&
                                                           UIApplication.sharedApplication.applicationState !=
                                                               UIApplicationStateBackground) {
                                                           NSLog(@"[SohIosShell] background flag reconciled (missed foreground callback)");
                                                           SohIos_SetBackgrounded(0);
                                                       }
                                                   }];
    // NSRunLoopCommonModes: SDL's run-loop servicing can starve the default
    // mode; common modes ride every turn (suspected reason the first
    // reconciler never fired).
    [NSRunLoop.mainRunLoop addTimer:reconciler forMode:NSRunLoopCommonModes];
    NSLog(@"[SohIosShell] background reconciler installed");
}

// LUS console-variable flush (extern "C", API_EXPORT). iOS swipe-kill is
// SIGKILL — desktop SoH's write-on-quit never runs, so CVar/enhancement/bind
// changes made in the menu would be lost. Flush on resign-active (fires
// before background and before any kill). In-game .sav files are already
// written synchronously by SaveManager at save time; this covers config.
extern void CVarSave(void);
extern void CVarClear(const char* name); // D9
extern int32_t CVarGetInteger(const char* name, int32_t defaultValue);
extern void CVarSetInteger(const char* name, int32_t value);
extern float CVarGetFloat(const char* name, float defaultValue);
extern void CVarSetFloat(const char* name, float value);
extern void CVarClearBlock(const char* name);

// VR settings bridge (spec D10, R3). The 0023 settings section is game-side
// C++ compiled on EVERY target, so it can only call a symbol that exists on
// every target — SohImmersive.m is visionOS-only (patch 0013's target_sources).
// This shim is the seam: on visionOS it forwards to the VR module's
// CVar->config apply; everywhere else it is a no-op the linker still resolves.
void SohVRSettings_Changed(void) {
#if TARGET_OS_VISION
    extern void SohVR_SettingsApply(void);
    SohVR_SettingsApply();
#endif
}

// VR R4 (spec D13/D9): the PSVR2 Sense fixed layout, applied at MK64's own
// read_controllers seam (overlay 0053). Same seam discipline as the settings
// callback above — src/main.c is C compiled on EVERY target, SohSense.m is
// visionOS-only (patch 0013's target_sources), so the game calls THIS and the
// forward only exists under TARGET_OS_VISION. On iPhone and on the macOS
// oracle the call is an empty function and the pad is untouched.
void SohVRSense_WritePad(unsigned short* button, signed char* stickX, signed char* stickY) {
#if TARGET_OS_VISION
    // VR R16-D — PUMP THE SENSE PAIR IN EVERY MODE.
    //
    // This seam (overlay 0053, MK64's own read_controllers) runs once per game
    // frame in 2D, in the 3D panel and in VR alike; the layer behind it did not.
    // sohsense_read_hardware was reached only from SohSense_Update, which only
    // SohVR_Immersive_Run calls, so in 2D and in the panel the pair fell through
    // to SDL's MFi auto-mapper — which recognises `Button A`, `Button B` and
    // `Button Menu` on a spatial controller and no other element name. Gas
    // worked, brake did not, steering did not, and `Button B` landed on C-down,
    // which update_controller force-promotes to Z: a phantom item.
    //
    // SohSense_PumpFlat is the hardware read ALONE (never the VR frame controls)
    // and it no-ops while the immersive loop is already reading, so there is
    // exactly one reader at any moment. The guard lives inside it, on `sStarted`
    // rather than on gSoh3DRunning — gSoh3DRunning is 1 in the 3D PANEL too, and
    // the panel pumps nothing.
    extern void SohSense_PumpFlat(void);
    SohSense_PumpFlat();
    extern void SohSense_WritePad(unsigned short* button, signed char* stickX, signed char* stickY);
    SohSense_WritePad(button, stickX, stickY);
#else
    (void)button;
    (void)stickX;
    (void)stickY;
#endif
    // R14 item 4 — THE VR BUTTON MASK, and it belongs HERE rather than in the
    // Sense layout. Removing a binding from SohSense.m only removes ONE of the
    // producers: LUS's SDL path fills gControllerPads before this call and the
    // console bridge's virtual pad rides the same route, so an assert that
    // injects C-left would have flipped the camera on a build whose Sense layer
    // no longer emits it. This is the last fold before update_controller()
    // derives the frame's edges, so masking here is the only place that can
    // honestly claim "the game never sees the bit in VR".
    //
    //   C-LEFT / C-RIGHT — MK64's look-behind. It FLIPS THE GAME CAMERA, and in
    //     VR the eye is bolted to the cockpit while the culling, the rear-view
    //     walk and the chase camera all follow the flip: the user's vanishing
    //     draw distance, his rear pane showing what is in front, and the ~45
    //     degree snap-and-return of the forward viewport are one bug with three
    //     faces. Look-behind is the pane's job in VR.
    //   C-UP / C-DOWN — already suppressed at the Sense layer in R9 (zoom level;
    //     and C-down is force-promoted to Z_TRIG by update_controller, so it
    //     silently fired the player's item). Masked here for the same reason
    //     the other two are: so no producer can reintroduce them.
    //
    // R15 item 6 — L IS BACK, and it is back deliberately. R14 masked it
    // because it is the music-volume cycle and because the port's
    // update_music_volume writes the ARCHIVED gMainMusicVolume, i.e. an
    // accidental squeeze persists. the user's answer on 1.0.0.11: "bring it back
    // — the original game let you adjust/mute music." That is stock MK64
    // behaviour and it is his to have; the persistence is the port's own
    // behaviour in the flat game too, so it is not a VR bug to fix here. Only
    // the four C bits are dropped now.
    //
    // gSohVRWorldActive is the gate, so this is world frames only: the flat
    // game, the panel modes and every VR menu/pause frame keep the full pad.
    // `vr set cmask 0` is the red control (trap D11) — the suite injects C-left
    // with the mask off, watches camfwd_err flip, then turns it back on.
    {
        extern volatile int gSohVRWorldActive;
        // R14 item 4's INJECTOR. The bridge's `btn` map has no C buttons (LUS
        // binds them off a real pad's right stick), so without this the mask
        // could only be asserted by NOT seeing something — which is the shape
        // of assert trap D11 exists to forbid. `vr set cinject <bits>` ORs raw
        // N64 pad bits in HERE, upstream of the mask and downstream of every
        // real producer, so `cmask 0` + an injected C-left flips the camera and
        // `cmask 1` does not, on one binary.
        if (gSohVRPadInject && button) {
            *button |= (unsigned short)gSohVRPadInject;
        }
        if (gSohVRWorldActive && gSohVRPadMask && button) {
            const unsigned short kSohVRPadDrop = 0x000F /* all four C */;
            unsigned short before = *button;
            *button = (unsigned short)(before & (unsigned short)~kSohVRPadDrop);
            if (before != *button) {
                gSohVRPadMasked++;
            }
        }
#if TARGET_OS_VISION
        // R18-B item 3 / R19 item 1 — L3 MUST NOT LEAK TO THE GAME IN VR. A
        // plain gamepad's LEFT-stick click (R19; R18-B used the right one)
        // toggles the rear pane in VR world frames (the producer is
        // SohSense.m's frame controls). MK64 has no default L3 binding and SDL
        // hands it to LUS only as SDL_CONTROLLER_BUTTON_LEFTSTICK, but LUS lets
        // a player BIND it — so for the whole physical press (trap D21: hold,
        // overlap, never alternate) every N64 bit a port-0 mapping routes from
        // SDL button 7 is dropped here, the same last fold the C mask uses. The
        // bound bits are read off LUS's own mapping CVars
        // (gControllers.ButtonMappings.P0-B<bit>-SDLB7.*) only while L3 is down,
        // so the common case costs one GCController read per game frame.
        // `vr set gpl3bind <bits>` forces bound bits for the headless RED/GREEN.
        // R3 is a plain game button again in VR (nothing toggles on it).
        if (gSohVRWorldActive && button) {
            extern int SohSense_GamepadL3Down(void);
            extern float SohSense_GetTunable(const char* key);
            extern const char* CVarGetString(const char* name, const char* defaultValue);
            extern volatile unsigned int gSohVRL3Masked;
            extern volatile unsigned int gSohVRL3Bits;
            if (SohSense_GamepadL3Down()) {
                unsigned short bound = (unsigned short)(int)SohSense_GetTunable("gpl3bind");
                for (int bit = 0; bit < 16; bit++) {
                    char n[96];
                    snprintf(n, sizeof(n), "gControllers.ButtonMappings.P0-B%d-SDLB7.ButtonMappingClass", 1 << bit);
                    const char* cls = CVarGetString(n, "");
                    if (cls != NULL && cls[0] != '\0') {
                        bound |= (unsigned short)(1 << bit);
                    }
                }
                gSohVRL3Bits = bound;
                if (bound && (*button & bound)) {
                    *button = (unsigned short)(*button & (unsigned short)~bound);
                    gSohVRL3Masked++;
                }
            }
        }
#endif
    }
}
#if TARGET_OS_VISION
// R18-B item 3 / R19 item 1: the leak mask's counters (read by SohSense_Dump /
// `vr hands`). L3 since R19 (was R3).
volatile unsigned int gSohVRL3Masked = 0; // game frames an L3-bound bit was dropped
volatile unsigned int gSohVRL3Bits = 0;   // the bound bits last computed
#endif

// Game pause state, exported by overlay 0013 — drives the ≡ button policy
// when a physical controller is active.
extern int SohIos_IsGamePaused(void);

// Title/intro/file-select context (overlay 0013) — the ≡ button stays
// visible there so users can tune settings at the start.
extern int SohIos_IsTitleOrDemo(void);

// Menu touch-scroll queue (overlay 0013/0018): mouse-free scrolling.
extern void SohIos_QueueMenuScroll(float x, float dy);

// Rolling 1s fps from the perf probe (overlay 0008 rev4) for the HUD.
extern void SohIos_HudStats(float* fps);

// Active BGM/fanfare sequence ids (overlay 0013) — wrong-music diagnostics.
extern uint32_t SohIos_ActiveSeqIds(void);

// Any ImGui popup open (overlay 0013): overlay yields all input to it.
extern int SohIos_IsPopupOpen(void);

// First-run fidelity defaults for this device (user feedback 2026-07-10):
// pace to the display's refresh (120 on ProMotion) and render at 200%
// internal resolution. Versioned so later builds can seed more without
// clobbering user changes; only ever runs when the marker is absent.
static void SohIos_SeedDefaultsOnce(void) {
    // MIGRATION (unconditional, runs before any menu draw): gSohIos.MaxFps
    // changed from index semantics (0=60, 1=120) to literal fps values.
    // SoH's combobox does comboMap.at(storedValue) — a legacy 0/1 in the
    // {60,90,120} map throws std::out_of_range = instant abort on menu open
    // (Vision Pro regression, 2026-07-14).
    {
        int mf = CVarGetInteger("gSohIos.MaxFps", 120);
        if (mf <= 1) {
            CVarSetInteger("gSohIos.MaxFps", mf == 0 ? 60 : 120);
        }
    }
    int version = CVarGetInteger("gSohIos.DefaultsVersion", 0);
    // D9: the early exit MUST compare against the LATEST spaghetti version
    // or newer seeds below are dead code on updated devices.
    if (version >= 6) {
        return;
    }
    if (version < 1) {
        CVarSetInteger("gMatchRefreshRate", 1); // SpaghettiKart name (SoH: gSettings.MatchRefreshRate)
    }
    // v2: gInternalResolution back to 1.0 — measured on sim (2026-07-12):
    // the multiplier is only consumed by Fast3dGui's ImGui game-window
    // path, which the iOS present pipeline doesn't use, so the v1 "200%"
    // seed was a no-op — and if the path ever activates, >1.0 would
    // actually DOWNGRADE from native (it multiplies ImGui points, not
    // drawable pixels). The game already renders at native drawable res;
    // true SSAA on iOS is a D7 perf-ladder work item.
    if (version < 2) {
        CVarSetFloat("gInternalResolution", 1.0f);
    }
    // v4: decal z-fighting mode "no vanishing paths" — the dirt-path
    // "line swallowing the path" artifact (task #39, user screenshot) is the
    // decal depth-bias failing at high render heights; upstream ships a
    // height-scaled mode for exactly this. Benefits iPhone equally.
    if (version < 4) {
        CVarSetInteger("gSettings.ZFightingMode", 2);
    }
#if TARGET_OS_VISION
    // v3: ceiling defaults, soak-verified on the M5 Vision Pro (2026-07-16):
    // 4K pack / 100% render scale / 120 fps held 117-119 fps for 22 minutes,
    // thermal never past "fair", gpu_ms p95 < 5 — see MEASUREMENTS.md.
    if (version < 3) {
        CVarSetInteger("gSohIos.MaxFps", 120);
        CVarSetInteger("gSohIos.VisionLongEdge", 3840);
    }
#endif
    // D9 v5: clear the 2026-07-21 live-session texture-tuning experiments —
    // bridge cvarsets persist on clean quit and would silently override the
    // decode-downscale build's compiled defaults.
    if (version < 5) {
        CVarClear("gSohIos.TexCacheBudgetMB");
        CVarClear("gSohIos.MipMinDim");
        CVarClear("gSohIos.TexMaxDim");
        CVarClear("gSohIos.SpriteMaxDim");
        CVarClear("gSohIos.MemPanicMB");
        CVarClear("gSohIos.TexCacheMinEntries");
        CVarClear("gSohIos.TexCacheMaxEntries");
        CVarClear("gSohIos.ResUnloadAtImport");
    }
    // D9 v6: gNoCulling=1 — upstream enhancement disabling the N64's angle
    // culling; the 4:3-tuned cone culled edge-visible billboards on the
    // 2.17:1 panel (the blinking trees/Lakitu, video-reproduced).
    if (version < 6) {
        CVarSetInteger("gNoCulling", 1);
    }
    CVarSetInteger("gSohIos.DefaultsVersion", 6);
    CVarSave();
    NSLog(@"[SohIosShell] defaults seeded v6 (gNoCulling=1 cull-flicker fix)");
}

void SohIos_FlushConfig(const char* why) {
    CVarSave(); // ~13 KB JSON; cheap, safe to repeat
    NSLog(@"[SohIosShell] config flushed (%s)", why ? why : "?");
}

static void SohIos_InstallConfigPersist(void) {
    static BOOL installed = NO;
    if (installed) {
        return;
    }
    installed = YES;
    // Under a scene session UIKit posts UISceneWillDeactivate, NOT the app-
    // level UIApplicationWillResignActive (same scene-vs-app-delegate split
    // that broke URL delivery). Observe both notification names so the flush
    // fires whichever lifecycle the runtime uses; the scene delegate below
    // also calls SohIos_FlushConfig directly as a third path.
    void (^flush)(NSNotification*) = ^(NSNotification* note) { SohIos_FlushConfig("notif"); };
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:flush];
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneWillDeactivateNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:flush];
}

// --- the black box (R6) ------------------------------------------------------
// A fixed-size ring of the last N shell events, held in plain static storage so
// the crash handler can write it out with nothing but write(2). the user cannot
// type bridge commands in the headset, so the only way a device crash tells us
// what he was doing is if the app wrote it down BEFORE it died.
#define SOH_BLACKBOX_LINES 64
#define SOH_BLACKBOX_WIDTH 160
static char sSohBlackBox[SOH_BLACKBOX_LINES][SOH_BLACKBOX_WIDTH];
static volatile unsigned int sSohBlackBoxNext = 0;
static pthread_mutex_t sSohBlackBoxMutex = PTHREAD_MUTEX_INITIALIZER;

void SohIos_LogLine(const char* s) {
    if (s == NULL) {
        return;
    }
    pthread_mutex_lock(&sSohBlackBoxMutex);
    unsigned int i = sSohBlackBoxNext++ % SOH_BLACKBOX_LINES;
    snprintf(sSohBlackBox[i], SOH_BLACKBOX_WIDTH, "%.1f %s", CACurrentMediaTime(), s);
    pthread_mutex_unlock(&sSohBlackBoxMutex);
}

// Formatted convenience; NEVER call this from a signal handler.
void SohIos_LogF(const char* fmt, ...) {
    char buf[SOH_BLACKBOX_WIDTH];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    SohIos_LogLine(buf);
}

int SohIos_BlackBoxDump(char* out, int cap) {
    int used = 0;
    pthread_mutex_lock(&sSohBlackBoxMutex);
    unsigned int n = sSohBlackBoxNext;
    unsigned int start = (n > SOH_BLACKBOX_LINES) ? (n - SOH_BLACKBOX_LINES) : 0;
    for (unsigned int k = start; k < n && used < cap - 2; k++) {
        const char* l = sSohBlackBox[k % SOH_BLACKBOX_LINES];
        int w = snprintf(out + used, (size_t)(cap - used), "%s\n", l);
        if (w < 0) {
            break;
        }
        used += w;
    }
    pthread_mutex_unlock(&sSohBlackBoxMutex);
    return used;
}

// Crash backtraces persisted to Documents/crash.txt — springboard sessions
// are otherwise invisible (predecessor pattern).
//
// R6 hardening, after the user reported "a couple crashes" on the headset and a
// live session died at `vr set vrdbg 6`:
//   * SIGTRAP joins the set. Swift/ObjC `fatalError`, `__builtin_trap` and a
//     good share of Metal validation aborts arrive as SIGTRAP, and until now
//     every one of them produced no file at all.
//   * The previous crash.txt is rotated to crash-prev.txt instead of being
//     truncated away, because the user crashed twice and relaunched in between.
//   * A context header (version, VR mode/view/scale/vrdbg, thread) and the
//     black box ride along, so the file says what he was DOING.
//   * An NSException handler, because an ObjC throw reaches SIGABRT with the
//     interesting frames already unwound — the reason string is the evidence.
// Everything the handler itself does is write(2) into preallocated storage.
extern volatile int gSoh3DMode;
extern volatile int gSohVRCrashCtxMode, gSohVRCrashCtxView, gSohVRCrashCtxDbg;
extern volatile float gSohVRCrashCtxScale;
volatile int gSohVRCrashCtxMode = 0, gSohVRCrashCtxView = -1, gSohVRCrashCtxDbg = 0;
volatile float gSohVRCrashCtxScale = 0.0f;

static char sSohCrashPath[1024];
static char sSohCrashPrevPath[1024];
static char sSohCrashDir[1024];
static char sSohCrashVersion[64] = "?";
static char sSohCrashScratch[SOH_BLACKBOX_LINES * SOH_BLACKBOX_WIDTH + 512];
// R10 item 1: the "last crash" line the settings page shows, and how many
// rotated reports are on disk. Computed at launch (readdir is not something a
// signal handler may do), read by SohVR_GetLastCrash / `vr crashinfo`.
static char sSohCrashLast[160] = "";
static int sSohCrashKept = 0;

// R10 item 1 — CRASH REPORTS ARE NOW ROTATED, NOT OVERWRITTEN.
//
// the user, 1.0.0.6 retest: "i had a couple crashes, maybe check crash logs" —
// and he was right to worry that relaunching had eaten them. R6 gave us ONE
// level of rotation (crash.txt -> crash-prev.txt), so the THIRD crash of a
// session destroys the first, and every crash after that destroys another.
// Two crashes plus a relaunch is exactly the session he reported.
//
// The rule now: every crash gets its OWN file, `crash-<epoch>.txt`, which
// nothing ever overwrites. `crash.txt` survives as a hard LINK to the newest
// one, so the R6 tooling (`vr crashinfo`, the retest brief's Files-app step)
// keeps working unchanged, and so does anything that already knows that name.
// Pruning to the newest SOH_CRASH_KEEP happens at LAUNCH, where a directory
// scan is legal; the handler itself still does nothing but open/write/link.
#define SOH_CRASH_KEEP 5

// VR R16-E — WHY THE FOUR GATE CRASHES HAD AN EMPTY `--- backtrace ---`.
//
// The handler has always called backtrace(3) at its head, and on the four
// 1.0.0.13 gate aborts backtrace() returned ZERO frames. Apple's backtrace()
// walks the frame pointer only after validating it against the CALLING
// THREAD's pthread stack bounds; from inside a signal handler on a thread
// whose bounds it cannot vouch for it gives up and reports nothing rather than
// risk a fault. So on exactly the crash we needed to read, the instrument was
// mute (trap D11, third form: the tool that cannot see the failure it exists
// for).
//
// The fix is to stop depending on it. sigaction(SA_SIGINFO) hands us the
// interrupted thread's REGISTERS, so pc and lr are known exactly, and the
// frame-record chain can be walked ourselves — bounded, alignment-checked and
// monotonic, and only inside the thread's stack when we can establish it, so a
// crash reporter cannot become a second crash. backtrace() is still tried
// first; this runs when it comes back empty.
static uintptr_t sSohCrashSlide = 0;

static int SohIos_UnwindFromContext(void* ucv, void** out, int cap) {
#if defined(__arm64__) || defined(__aarch64__)
    if (ucv == NULL || out == NULL || cap < 2) {
        return 0;
    }
    ucontext_t* uc = (ucontext_t*)ucv;
    _STRUCT_MCONTEXT64* mc = (_STRUCT_MCONTEXT64*)uc->uc_mcontext;
    if (mc == NULL) {
        return 0;
    }
    int n = 0;
    out[n++] = (void*)(uintptr_t)mc->__ss.__pc;
    uintptr_t lr = (uintptr_t)mc->__ss.__lr;
    if (lr != 0 && n < cap) {
        out[n++] = (void*)lr;
    }
    // Stack bounds, when the thread can tell us; without them we stop at pc+lr
    // rather than dereference an unvalidated frame pointer.
    pthread_t self = pthread_self();
    uintptr_t top = (uintptr_t)pthread_get_stackaddr_np(self);
    size_t size = pthread_get_stacksize_np(self);
    if (top == 0 || size == 0) {
        return n;
    }
    uintptr_t bot = top - (uintptr_t)size;
    uintptr_t fp = (uintptr_t)mc->__ss.__fp;
    uintptr_t prev = 0;
    while (n < cap && fp != 0 && (fp & 0xf) == 0 && fp > prev && fp >= bot &&
           fp + 2 * sizeof(uintptr_t) <= top) {
        uintptr_t next = ((uintptr_t*)fp)[0];
        uintptr_t ret = ((uintptr_t*)fp)[1];
        if (ret == 0) {
            break;
        }
        out[n++] = (void*)ret;
        prev = fp;
        fp = next;
    }
    return n;
#else
    (void)ucv; (void)out; (void)cap;
    return 0;
#endif
}

// The report writer, split out of the signal handler in R16-E so the
// std::terminate handler (SohCrashTerminate.cpp) writes the SAME file format
// from a normal context — where the stack is intact and the note says what
// terminate() saw. `note` is an extra header line; NULL for a plain signal.
void SohIos_CrashWriteReport(int sig, const char* note, void** frames, int n) {
    // Rotate: keep the crash BEFORE this one. rename(2) is fine here.
    rename(sSohCrashPath, sSohCrashPrevPath);
    // A per-crash file that nothing will ever overwrite. time(2) and snprintf
    // are what the rest of this handler already relies on; O_EXCL means a
    // second crash inside the same second cannot clobber the first (it falls
    // back to the unique-by-name path below).
    char stamped[1200];
    int w0 = snprintf(stamped, sizeof(stamped), "%s/crash-%llu.txt", sSohCrashDir,
                      (unsigned long long)time(NULL));
    int fd = (w0 > 0 && w0 < (int)sizeof(stamped))
                 ? open(stamped, O_CREAT | O_EXCL | O_WRONLY, 0644)
                 : -1;
    for (int bump = 1; fd < 0 && bump <= 9; bump++) {
        int w1 = snprintf(stamped, sizeof(stamped), "%s/crash-%llu-%d.txt", sSohCrashDir,
                          (unsigned long long)time(NULL), bump);
        if (w1 > 0 && w1 < (int)sizeof(stamped)) {
            fd = open(stamped, O_CREAT | O_EXCL | O_WRONLY, 0644);
        }
    }
    if (fd < 0) {
        // Never lose the report because the stamped name would not open.
        stamped[0] = '\0';
        fd = open(sSohCrashPath, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    }
    if (fd >= 0) {
        char hdr[512];
        // R13 item 1d: the GPU-memory line. Both crashes this round are
        // suspected to follow an allocation failure, and until now the report
        // could not confirm it — the counters lived only in `vr contract`,
        // which needs a live session, so a crash file was mute on exactly the
        // question it was collected to answer. All four are plain volatile
        // scalars: reading them here is signal-safe, and snprintf is what this
        // handler already relies on.
        extern volatile unsigned int gSohIosGfxAllocFails;
        extern volatile unsigned int gSohIosGfxQuiesces;
        extern volatile unsigned int gSohIosGfxFbSkips;
        extern volatile double gSohIosGfxFbBytes;
        int w = snprintf(hdr, sizeof(hdr),
                         "signal %d\nversion %s\nthread %s\ntime %llu\n"
                         "spacemode %d vrmode %d view %d vrdbg %d scale %.1f\n"
                         "alloc_fails %u fb_skips %u quiesces %u fb_mb %.1f\n"
                         "slide 0x%llx\nnote %s\n--- black box ---\n",
                         sig, sSohCrashVersion, pthread_main_np() ? "main" : "secondary",
                         (unsigned long long)time(NULL), gSoh3DMode, gSohVRCrashCtxMode,
                         gSohVRCrashCtxView, gSohVRCrashCtxDbg, gSohVRCrashCtxScale,
                         gSohIosGfxAllocFails, gSohIosGfxFbSkips, gSohIosGfxQuiesces,
                         gSohIosGfxFbBytes / (1024.0 * 1024.0),
                         (unsigned long long)sSohCrashSlide, note ? note : "(none)");
        if (w > 0) {
            (void)write(fd, hdr, (size_t)w);
        }
        int bb = SohIos_BlackBoxDump(sSohCrashScratch, (int)sizeof(sSohCrashScratch));
        if (bb > 0) {
            (void)write(fd, sSohCrashScratch, (size_t)bb);
        }
        const char* sep = "--- backtrace ---\n";
        (void)write(fd, sep, strlen(sep));
        if (n > 0) {
            backtrace_symbols_fd(frames, n, fd);
        } else {
            const char* none = "(no frames — neither backtrace() nor the "
                               "signal-context unwind produced any)\n";
            (void)write(fd, none, strlen(none));
        }
        // R16-E: raw addresses too. `atos -o <binary> -l <slide>` needs these
        // when the symbolic line degrades to image+offset, which is what a
        // stripped Release build gives for our own frames.
        {
            const char* rawhdr = "--- raw addresses ---\n";
            (void)write(fd, rawhdr, strlen(rawhdr));
            for (int i = 0; i < n; i++) {
                char line[64];
                int lw = snprintf(line, sizeof(line), "%d 0x%llx\n", i,
                                  (unsigned long long)(uintptr_t)frames[i]);
                if (lw > 0) {
                    (void)write(fd, line, (size_t)lw);
                }
            }
        }
        close(fd);
        if (stamped[0] != '\0') {
            // crash.txt = the newest report, by hard link. Both names refer to
            // the same inode, so nothing is copied and nothing is lost.
            (void)unlink(sSohCrashPath);
            (void)link(stamped, sSohCrashPath);
        }
    }
}

// R16-E: SA_SIGINFO, so the interrupted registers are available when
// backtrace() comes back empty (see SohIos_UnwindFromContext above), and a
// re-raise that actually reaches the DEFAULT disposition — the signal is
// unblocked first, because a handler entered through sigaction has its own
// signal masked, and a `raise` under that mask only marks it pending and can
// leave the process exiting without the OS ever writing an .ips.
static void SohIos_CrashHandler(int sig, siginfo_t* info, void* uc) {
    (void)info;
    void* frames[64];
    int n = backtrace(frames, 64);
    const char* note = NULL;
    if (n <= 0) {
        n = SohIos_UnwindFromContext(uc, frames, 64);
        note = "backtrace() returned 0 frames — stack below is from the signal "
               "context registers (pc, lr, then the frame-record chain)";
    }
    SohIos_CrashWriteReport(sig, note, frames, n);

    struct sigaction dfl;
    memset(&dfl, 0, sizeof(dfl));
    dfl.sa_handler = SIG_DFL;
    sigemptyset(&dfl.sa_mask);
    sigaction(sig, &dfl, NULL);
    sigset_t unblock;
    sigemptyset(&unblock);
    sigaddset(&unblock, sig);
    pthread_sigmask(SIG_UNBLOCK, &unblock, NULL);
    pthread_kill(pthread_self(), sig);
    // If the signal is somehow still not fatal, do not return into the broken
    // frame — abort() is guaranteed to end the process and produce a report.
    abort();
}

// Launch-time housekeeping for the rotated reports: count them, remember the
// newest one's date for the settings caption, and delete everything past
// SOH_CRASH_KEEP. Deliberately NOT in the handler — readdir/sort/unlink there
// is how a crash reporter becomes a second crash.
static void SohIos_PruneCrashReports(void) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* dir = @(sSohCrashDir);
    NSArray<NSString*>* all = [fm contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray<NSString*>* reports = [NSMutableArray array];
    for (NSString* f in all) {
        if ([f hasPrefix:@"crash-"] && [f hasSuffix:@".txt"] && ![f isEqualToString:@"crash-prev.txt"]) {
            [reports addObject:f];
        }
    }
    // Newest first, by modification date (the name's epoch agrees, but the
    // date is the thing the caption actually shows).
    [reports sortUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
        NSDate* da = [fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:a] error:nil].fileModificationDate;
        NSDate* db = [fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:b] error:nil].fileModificationDate;
        if (da == nil || db == nil) {
            return [b compare:a];
        }
        return [db compare:da];
    }];
    sSohCrashKept = (int)reports.count;
    if (reports.count > 0) {
        NSString* newest = [dir stringByAppendingPathComponent:reports[0]];
        NSDate* when = [fm attributesOfItemAtPath:newest error:nil].fileModificationDate;
        NSString* sig = @"?";
        NSString* body = [NSString stringWithContentsOfFile:newest encoding:NSUTF8StringEncoding error:nil];
        if (body.length) {
            NSArray* lines = [body componentsSeparatedByString:@"\n"];
            if (lines.count && [lines[0] hasPrefix:@"signal "]) {
                sig = [lines[0] substringFromIndex:7];
            }
        }
        NSDateFormatter* df = [NSDateFormatter new];
        df.dateStyle = NSDateFormatterMediumStyle;
        df.timeStyle = NSDateFormatterShortStyle;
        snprintf(sSohCrashLast, sizeof(sSohCrashLast), "%s (signal %s)",
                 when ? [df stringFromDate:when].UTF8String : "unknown date", sig.UTF8String);
    } else {
        sSohCrashLast[0] = '\0';
    }
    for (NSUInteger i = SOH_CRASH_KEEP; i < reports.count; i++) {
        NSString* old = [dir stringByAppendingPathComponent:reports[i]];
        if ([fm removeItemAtPath:old error:nil]) {
            SohIos_LogF("crash reports: pruned %s", reports[i].UTF8String);
        }
    }
    if (reports.count > SOH_CRASH_KEEP) {
        sSohCrashKept = SOH_CRASH_KEEP;
    }
    SohIos_LogF("crash reports: %d kept, last=%s", sSohCrashKept,
                sSohCrashLast[0] ? sSohCrashLast : "none");
}

// The settings-page caption (R10 item 1b): the user must be able to SEE that a
// crash was captured without typing anything or opening Files.
const char* SohIos_LastCrashSummary(void) {
    return sSohCrashLast;
}
int SohIos_CrashReportCount(void) {
    return sSohCrashKept;
}

static void SohIos_ExceptionHandler(NSException* e) {
    SohIos_LogF("UNCAUGHT %s: %s", e.name.UTF8String ?: "?", e.reason.UTF8String ?: "?");
    // The symbols the throw site had, before SIGABRT unwinds them away.
    NSArray* syms = e.callStackSymbols;
    for (NSUInteger i = 0; i < syms.count && i < 24; i++) {
        SohIos_LogLine([syms[i] UTF8String]);
    }
}

static void SohIos_InstallCrashHandler(void) {
    const char* home = getenv("HOME");
    snprintf(sSohCrashPath, sizeof(sSohCrashPath), "%s/Documents/crash.txt", home ? home : "/tmp");
    snprintf(sSohCrashPrevPath, sizeof(sSohCrashPrevPath), "%s/Documents/crash-prev.txt",
             home ? home : "/tmp");
    snprintf(sSohCrashDir, sizeof(sSohCrashDir), "%s/Documents", home ? home : "/tmp");
    {
        NSString* v = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?";
        NSString* b = NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"?";
        snprintf(sSohCrashVersion, sizeof(sSohCrashVersion), "%s (%s)", v.UTF8String, b.UTF8String);
    }
    // SIGTRAP added R6. SIGPIPE is deliberately NOT here — the shell's SIGPIPE
    // policy is its own thing (docs/SHELL-SIGPIPE-ADVISORY.md).
    // Computed here, not in the handler: _dyld_* is not signal-safe, and the
    // main image's slide never changes after launch.
    sSohCrashSlide = (uintptr_t)_dyld_get_image_vmaddr_slide(0);
    int sigs[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP };
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = SohIos_CrashHandler;
    // SA_SIGINFO for the register context (R16-E). NOT SA_ONSTACK: an
    // alternate signal stack is precisely what makes backtrace() give up.
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        sigaction(sigs[i], &sa, NULL);
    }
    NSSetUncaughtExceptionHandler(&SohIos_ExceptionHandler);
    SohIos_LogLine("launch: crash handlers installed");
    // R16-E: the std::terminate instrument. `libc++abi: terminating` with no
    // exception clause is what killed the 1.0.0.13 gate four times, and only a
    // terminate handler sees that stack.
    extern void SohCrash_InstallTerminate(void);
    SohCrash_InstallTerminate();
    // R10 item 1: count/date the rotated reports and prune to the newest five.
    SohIos_PruneCrashReports();
}

// Crash-capture status, for `vr crashinfo` and for the retest script.
int SohIos_CrashInfo(char* out, int cap) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* p = @(sSohCrashPath), *pp = @(sSohCrashPrevPath);
    NSDictionary* a = [fm attributesOfItemAtPath:p error:nil];
    NSDictionary* b = [fm attributesOfItemAtPath:pp error:nil];
    NSString* head = @"";
    if (a != nil) {
        NSString* c = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        NSArray* lines = [c componentsSeparatedByString:@"\n"];
        head = [[lines subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)6, lines.count))]
            componentsJoinedByString:@" | "];
    }
    // R10 item 1: `reports` is the rotated set (crash-<epoch>.txt), `last` is
    // the line the settings page shows. The suite asserts on both.
    return snprintf(out, (size_t)cap,
                    "vr_crashinfo handlers=1 path=%s present=%d bytes=%llu when=%s prev=%d prev_bytes=%llu "
                    "reports=%d keep=%d last=[%s] head=[%s]",
                    sSohCrashPath, a != nil, (unsigned long long)[a fileSize],
                    a != nil ? [a fileModificationDate].description.UTF8String : "-", b != nil,
                    (unsigned long long)[b fileSize], sSohCrashKept, SOH_CRASH_KEEP,
                    sSohCrashLast[0] ? sSohCrashLast : "-", head.UTF8String);
}

#pragma mark - Input trace (Documents/input-trace.txt)

// A user on iPadOS 26.5 reported that a controller's B button opened and
// closed the SoH menu on every press, on top of acting as the in-game B —
// and that unbinding EVERY controller button in SoH did not stop it. It
// could not: the toggle arrives as a keyboard Escape, not as a controller
// button, so it never passes through SoH's binding system at all. iPadOS
// forges UIKit "cancel" input from a game controller and SDL's UIKit
// backend converted it into SDL_SCANCODE_ESCAPE.
//
// Remote users have no console bridge, so the evidence has to travel by
// itself: Documents/input-trace.txt is reachable from the Files app
// (UIFileSharingEnabled) and can simply be sent back.
//
// It is written LAZILY. On a healthy device nothing is ever forged, so
// creating the file at every launch would put a mystery file in every
// user's Files folder for nothing. Instead lines accumulate in a small
// in-memory ring, and the file only materializes the first time a forged
// key is actually dropped — at which point the buffered environment
// (device, iOS version, keyboard, pads) is flushed ahead of it, so the
// evidence arrives with its context. The file existing at all is itself
// the signal that something is still forging input.
#define SOHIOS_TRACE_MAX_LINES 300
#define SOHIOS_TRACE_RING 60
static void SohIos_Trace(NSString* fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void SohIos_TraceArm(void); // first drop: start writing, flush the ring
static volatile int32_t sSohIosTraceLines; // read unlocked: a race just costs a line
static volatile int32_t sSohIosTraceArmed;

static dispatch_queue_t SohIos_TraceQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("soh.ios.trace", DISPATCH_QUEUE_SERIAL); });
    return q;
}

// Queue-confined state — only ever touched inside SohIos_TraceQueue().
static NSMutableArray<NSString*>* sSohIosTraceRing;
static int sSohIosTraceWritten;

static void SohIos_TraceWriteLocked(NSString* line) {
    static NSString* path;
    if (path == nil) {
        path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"input-trace.txt"];
        [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:path];
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static void SohIos_Trace(NSString* fmt, ...) {
    // Hard stop once full — a forged key can arrive on EVERY button press, so
    // this must cost nothing at all after the cap, not just skip the write.
    if (sSohIosTraceLines >= SOHIOS_TRACE_MAX_LINES) {
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    NSString* msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[SohIosInput] %@", msg);
    double t = CACurrentMediaTime();
    dispatch_async(SohIos_TraceQueue(), ^{
        NSString* line = [NSString stringWithFormat:@"%8.2f  %@\n", t, msg];
        if (!sSohIosTraceArmed) {
            if (sSohIosTraceRing == nil) {
                sSohIosTraceRing = [NSMutableArray array];
            }
            [sSohIosTraceRing addObject:line];
            if (sSohIosTraceRing.count > SOHIOS_TRACE_RING) {
                [sSohIosTraceRing removeObjectAtIndex:0];
            }
            return;
        }
        if (sSohIosTraceWritten >= SOHIOS_TRACE_MAX_LINES) {
            return;
        }
        sSohIosTraceLines = ++sSohIosTraceWritten;
        SohIos_TraceWriteLocked(sSohIosTraceWritten == SOHIOS_TRACE_MAX_LINES
                                    ? [line stringByAppendingString:@"[trace full]\n"]
                                    : line);
    });
}

// Called the first time a forged key is dropped. Everything buffered so far
// becomes the header of the file, then tracing goes live.
static void SohIos_TraceArm(void) {
    if (sSohIosTraceArmed) {
        return;
    }
    dispatch_async(SohIos_TraceQueue(), ^{
        if (sSohIosTraceArmed) {
            return;
        }
        sSohIosTraceArmed = 1;
        SohIos_TraceWriteLocked(@"# input-trace: forged input was detected on this device.\n"
                                @"# Lines above the marker are the buffered lead-up.\n");
        for (NSString* buffered in sSohIosTraceRing) {
            SohIos_TraceWriteLocked(buffered);
            sSohIosTraceWritten++;
        }
        sSohIosTraceRing = nil;
        SohIos_TraceWriteLocked(@"# --- live from here ---\n");
        sSohIosTraceLines = sSohIosTraceWritten;
    });
}

// Stamped into SDL_Keysym's otherwise-unused field so the event filter can
// tell the shell's own menu keystrokes (≡ button, restore dot, soh://menu,
// the bridge) apart from anything the system forged.
#define SOHIOS_KEY_MAGIC 0x5348494Fu // 'SHIO'

#pragma mark - Virtual game controller (input backend)

// An SDL virtual game controller: LUS's SDL controller stack sees it as a
// normal pad (auto-mapped by SDL), so the touch overlay drives the game
// through the same path a physical controller would.
static SDL_Joystick* gVirtualPad = NULL;
static SDL_Window* gSdlWindow = NULL;

// Inject a left-click at window point (x, y) via SDL's thread-safe event
// queue — ImGui consumes SDL mouse events, so this can activate ImGui
// buttons (e.g. the extractor's "Yes") on the simulator where real taps
// are unavailable.
static void SohIos_InjectMouseMotion(int x, int y) {
    if (gSdlWindow == NULL) {
        return;
    }
    SDL_Event e;
    SDL_zero(e);
    e.type = SDL_MOUSEMOTION;
    e.motion.windowID = SDL_GetWindowID(gSdlWindow);
    e.motion.x = x;
    e.motion.y = y;
    SDL_PushEvent(&e);
}

static void SohIos_InjectMouseButton(int x, int y, BOOL down) {
    if (gSdlWindow == NULL) {
        return;
    }
    SDL_Event e;
    SDL_zero(e);
    e.type = down ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
    e.button.windowID = SDL_GetWindowID(gSdlWindow);
    e.button.button = SDL_BUTTON_LEFT;
    e.button.state = down ? SDL_PRESSED : SDL_RELEASED;
    e.button.clicks = 1;
    e.button.x = x;
    e.button.y = y;
    SDL_PushEvent(&e);
}

static void SohIos_InjectClick(int x, int y) {
    if (gSdlWindow == NULL) {
        return;
    }
    Uint32 windowID = SDL_GetWindowID(gSdlWindow);
    SDL_Event e;
    SDL_zero(e);
    e.type = SDL_MOUSEMOTION;
    e.motion.windowID = windowID;
    e.motion.x = x;
    e.motion.y = y;
    SDL_PushEvent(&e);
    SDL_zero(e);
    e.type = SDL_MOUSEBUTTONDOWN;
    e.button.windowID = windowID;
    e.button.button = SDL_BUTTON_LEFT;
    e.button.state = SDL_PRESSED;
    e.button.clicks = 1;
    e.button.x = x;
    e.button.y = y;
    SDL_PushEvent(&e);
    SDL_zero(e);
    e.type = SDL_MOUSEBUTTONUP;
    e.button.windowID = windowID;
    e.button.button = SDL_BUTTON_LEFT;
    e.button.state = SDL_RELEASED;
    e.button.clicks = 1;
    e.button.x = x;
    e.button.y = y;
    SDL_PushEvent(&e);
    NSLog(@"[SohIosShell] injected click at (%d,%d)", x, y);
}

static void SohIos_PadAxis(SDL_GameControllerAxis axis, Sint16 value);

static void SohIos_AttachVirtualPad(void) {
    if (gVirtualPad != NULL) {
        return;
    }
    if (SDL_InitSubSystem(SDL_INIT_GAMECONTROLLER) != 0) {
        NSLog(@"[SohIosShell] SDL_InitSubSystem(GAMECONTROLLER) failed: %s", SDL_GetError());
        return;
    }
    SDL_VirtualJoystickDesc desc;
    SDL_zero(desc);
    desc.version = SDL_VIRTUAL_JOYSTICK_DESC_VERSION;
    desc.type = SDL_JOYSTICK_TYPE_GAMECONTROLLER;
    desc.naxes = SDL_CONTROLLER_AXIS_MAX;
    desc.nbuttons = SDL_CONTROLLER_BUTTON_MAX;
    desc.name = "SoH Touch Controls";
    int deviceIndex = SDL_JoystickAttachVirtualEx(&desc);
    if (deviceIndex < 0) {
        NSLog(@"[SohIosShell] AttachVirtualEx failed: %s", SDL_GetError());
        return;
    }
    gVirtualPad = SDL_JoystickOpen(deviceIndex);
    // Triggers idle at raw 0 = half-pressed in trigger space (see
    // SohIos_PadAxis below) — drive them to truly-released immediately.
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_TRIGGERLEFT, 0);
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_TRIGGERRIGHT, 0);
    NSLog(@"[SohIosShell] virtual pad attached (index %d, isGameController=%d)", deviceIndex,
          SDL_IsGameController(deviceIndex));
}

// Inject a key press+release via SDL's thread-safe event queue.
// Mouse-wheel injection: vertical pans over the open menu scroll it (device
// feedback: swipe-to-scroll; sliders stay horizontal drags).
static void SohIos_InjectWheel(float dy) {
    SDL_Event e;
    SDL_zero(e);
    e.type = SDL_MOUSEWHEEL;
    e.wheel.y = (Sint32)dy;
    e.wheel.preciseY = dy;
    e.wheel.direction = SDL_MOUSEWHEEL_NORMAL;
    SDL_PushEvent(&e);
}

// D-030: the ornament's Menu button (SwiftUI — the only reachable control
// surface in 3D; the touch overlay's ≡ is under the parked window's curtain).
void SohIos_ToggleMenuKey(void);
static void SohIos_InjectKey(SDL_Keycode sym, SDL_Scancode scancode) {
    if (gSdlWindow == NULL) {
        return;
    }
    Uint32 windowID = SDL_GetWindowID(gSdlWindow);
    SDL_Event e;
    SDL_zero(e);
    e.type = SDL_KEYDOWN;
    e.key.windowID = windowID;
    e.key.state = SDL_PRESSED;
    e.key.keysym.sym = sym;
    e.key.keysym.scancode = scancode;
    e.key.keysym.unused = SOHIOS_KEY_MAGIC; // survives the Escape guard below
    SDL_PushEvent(&e);
    e.type = SDL_KEYUP;
    e.key.state = SDL_RELEASED;
    SDL_PushEvent(&e);
    NSLog(@"[SohIosShell] injected key %d", (int)sym);
}

// Identity mapping: virtual joystick axis/button N == SDL_CONTROLLER_*_N.
static void SohIos_PadAxis(SDL_GameControllerAxis axis, Sint16 value) {
    if (gVirtualPad == NULL) {
        return;
    }
    // THE Z ROOT CAUSE (device feedback 2026-07-12, found via the `pads`
    // dump): SDL translates full-range raw axes to trigger space as
    // (raw+32768)/2, so raw 0 reads as HALF-PRESSED (16383) — above LUS's
    // press threshold. The virtual pad was therefore holding Z forever:
    // touch-Z "stuck" after one tap, and gamepad Z looked dead because the
    // bit was already set so real presses produced no new edge. Triggers
    // take raw -32768 for released, +32767 for pressed.
    if (axis == SDL_CONTROLLER_AXIS_TRIGGERLEFT || axis == SDL_CONTROLLER_AXIS_TRIGGERRIGHT) {
        value = (value <= 0) ? SDL_JOYSTICK_AXIS_MIN : SDL_JOYSTICK_AXIS_MAX;
    }
    SDL_JoystickSetVirtualAxis(gVirtualPad, axis, value);
}

static void SohIos_PadButton(SDL_GameControllerButton button, BOOL down) {
    if (gVirtualPad) {
        SDL_JoystickSetVirtualButton(gVirtualPad, button, down ? SDL_PRESSED : SDL_RELEASED);
    }
}

// Self-test (env SOH_SELFTEST): repeated button presses so flows can be
// driven on the simulator, where scripted taps are unavailable.
//   SOH_SELFTEST=1|START → START presses T+15s..T+33s (title → file select)
//   SOH_SELFTEST=A       → A presses T+10s..T+28s (confirm ImGui popups,
//                          e.g. the extractor's "Use this rom?"; needs
//                          gSettings.ControlNav=1 for ImGui gamepad nav)
static void SohIos_ScheduleSelfTest(void) {
    const char* mode = getenv("SOH_SELFTEST");
    if (mode == NULL) {
        return;
    }
    // SOH_SELFTEST=CLICK:x1,y1[;x2,y2…] → inject left-clicks cycling through
    // the given window points, T+8s onward (drives ImGui buttons across a
    // multi-popup flow like the extractor's).
    if (strncmp(mode, "CLICK:", 6) == 0) {
        static int pts[8][2];
        int n = 0;
        const char* p = mode + 6;
        while (n < 8 && sscanf(p, "%d,%d", &pts[n][0], &pts[n][1]) == 2) {
            n++;
            p = strchr(p, ';');
            if (p == NULL) {
                break;
            }
            p++;
        }
        if (n > 0) {
            const int rounds = 12;
            NSLog(@"[SohIosShell] SELFTEST armed: %d click point(s), %d rounds from T+8s", n, rounds);
            const int nPts = n;
            for (int i = 0; i < rounds; i++) {
                double at = 8.0 + 2.0 * i;
                int idx = i % nPts;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)),
                               dispatch_get_main_queue(),
                               ^{ SohIos_InjectClick(pts[idx][0], pts[idx][1]); });
            }
        }
        return;
    }
    // SOH_SELFTEST=KEY:esc → inject one Escape key press at T+12s (opens the
    // SoH menu; on-phone this will be a gesture/HUD button later).
    if (strcmp(mode, "KEY:esc") == 0) {
        NSLog(@"[SohIosShell] SELFTEST armed: Escape at T+12s");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{ SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE); });
        return;
    }
    SDL_GameControllerButton btn = SDL_CONTROLLER_BUTTON_START;
    double firstAt = 15.0;
    if (strcmp(mode, "A") == 0) {
        btn = SDL_CONTROLLER_BUTTON_A;
        firstAt = 10.0;
    }
    NSLog(@"[SohIosShell] SELFTEST armed: 8x button %d from T+%.0fs", btn, firstAt);
    for (int i = 0; i < 8; i++) {
        double at = firstAt + 2.5 * i;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSLog(@"[SohIosShell] SELFTEST press #%d (btn %d)", i, btn);
            SohIos_PadButton(btn, YES);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ SohIos_PadButton(btn, NO); });
        });
    }
}

#pragma mark - ROM onboarding (document picker)

static NSString* SohIos_DocumentsPath(void) {
    const char* home = getenv("HOME");
    return [NSString stringWithFormat:@"%s/Documents", home ? home : "/tmp"];
}

static BOOL SohIos_DocumentsHasExt(NSArray<NSString*>* exts) {
    NSArray* files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:SohIos_DocumentsPath() error:nil];
    for (NSString* f in files) {
        if ([exts containsObject:f.pathExtension.lowercaseString]) {
            return YES;
        }
    }
    return NO;
}

// Native first-run flow: if there's no ROM and no extracted archive yet,
// offer a document picker (Files/iCloud) and copy the chosen ROM into
// Documents with sane protection/permissions . The in-engine
// extractor popups then find it and do the rest.
static void SohIos_PresentChooser(UIWindow* window); // D7 (defined below)
static UIWindow* gShellWindow = nil;                 // D7: set on window creation
static volatile int gOnboardLater = 0;               // D7: "Later" chosen

@interface SohIosOnboarding : NSObject <UIDocumentPickerDelegate>
@property(nonatomic, strong) UIWindow* window;
@end

static SohIosOnboarding* gOnboarding = nil;

// D18 (2026-10-09, user report on an iPhone 13 Pro Max): the first-run alert
// sat clipped in the bottom-left of a black landscape screen -- centered in a
// PORTRAIT-sized window (428x926 pt) on a landscape scene. SDL creates its
// UIWindow from the screen bounds, the shell glues it to the scene ONCE
// (SohIos_EnsureLandscape) -- possibly while the scene is still portrait --
// and the re-glue heal lives in the touch overlay, which is installed only
// after mk64.o2r exists, i.e. never during onboarding (and the main thread is
// parked in SohIos_RunRomOnboarding). So nothing corrected a stale window.
// Fit = attach to the active scene, glue the window to the scene's bounds and
// make the presenting VC's view fill it. Called before every onboarding
// presentation and on every onboarding pump tick (scene rotating later).
static UIWindowScene* SohIos_ActiveScene(void); // defined below
static BOOL SohIos_FitWindowForModal(UIWindow* window, const char* why) {
    if (window == nil) {
        return NO;
    }
#if TARGET_OS_VISION
    return NO; // visionOS: free-form window, own heal (syncWithMenuState); unchanged
#endif
    if (getenv("SOH_ONBOARD_NOFIT") != NULL) { // repro hook: the pre-D18 behaviour
        return NO;
    }
    UIWindowScene* scene = window.windowScene ?: SohIos_ActiveScene();
    if (scene == nil) {
        return NO;
    }
    if (window.windowScene != scene) {
        window.windowScene = scene;
    }
    CGRect sb = scene.coordinateSpace.bounds;
    UIView* root = window.rootViewController.view;
    BOOL stale = sb.size.width > 1 && (!CGRectEqualToRect(window.frame, sb) ||
                                       (root != nil && !CGRectEqualToRect(root.frame, window.bounds)));
    if (stale) {
        NSLog(@"[SohIosShell] onboarding fit (%s): window %.0fx%.0f root %.0fx%.0f -> scene %.0fx%.0f (orient %ld)",
              why, window.frame.size.width, window.frame.size.height, root.frame.size.width,
              root.frame.size.height, sb.size.width, sb.size.height, (long)scene.interfaceOrientation);
        SohIos_GlueWindowToScene(window, scene);
        if (root != nil && !CGRectEqualToRect(root.frame, window.bounds)) {
            root.frame = window.bounds;
        }
        [root setNeedsLayout];
        [root layoutIfNeeded];
    }
    return stale;
}

static BOOL SohIos_SceneIsLandscape(UIWindow* window) {
#if TARGET_OS_VISION
    return YES; // no landscape gate on visionOS
#endif
    UIWindowScene* scene = window.windowScene ?: SohIos_ActiveScene();
    if (scene == nil) {
        return NO;
    }
    CGSize s = scene.coordinateSpace.bounds.size;
    return s.width > s.height && UIInterfaceOrientationIsLandscape(scene.interfaceOrientation);
}

// Present an onboarding VC only once the scene has settled landscape (up to
// ~3 s, then present anyway), with the window fitted to the scene first.
static void SohIos_PresentOnboardingVC(UIWindow* window, UIViewController* vc, int attempt) {
    if (getenv("SOH_ONBOARD_STALE_WINDOW") != NULL && attempt == 0) {
        // repro hook: put the window in the reported state (portrait-sized on a
        // landscape scene) right before presenting.
        CGSize s = window.frame.size;
        window.frame = CGRectMake(0, 0, MIN(s.width, s.height), MAX(s.width, s.height));
        NSLog(@"[SohIosShell] SOH_ONBOARD_STALE_WINDOW: window forced to %.0fx%.0f",
              window.frame.size.width, window.frame.size.height);
    }
    if (getenv("SOH_ONBOARD_NOFIT") == NULL && !SohIos_SceneIsLandscape(window) && attempt < 30) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{ SohIos_PresentOnboardingVC(window, vc, attempt + 1); });
        return;
    }
    SohIos_FitWindowForModal(window, "present");
    UIViewController* host = window.rootViewController;
    while (host.presentedViewController != nil && !host.presentedViewController.isBeingDismissed) {
        host = host.presentedViewController;
    }
    NSLog(@"[SohIosShell] onboarding present %@ after %d waits: window %.0fx%.0f root %.0fx%.0f landscape=%d",
          NSStringFromClass(vc.class), attempt, window.bounds.size.width, window.bounds.size.height,
          host.view.bounds.size.width, host.view.bounds.size.height, SohIos_SceneIsLandscape(window));
    [host presentViewController:vc animated:YES completion:nil];
}

@implementation SohIosOnboarding

+ (void)maybePresentIn:(UIWindow*)window {
    // A ROM dropped in via the Files app keeps its own name; the extractor
    // wants baserom.us.z64. Adopt the first *.z64 found (hash is verified
    // by the extractor itself).
    NSString* canonical = [SohIos_DocumentsPath() stringByAppendingPathComponent:@"baserom.us.z64"];
    if (![NSFileManager.defaultManager fileExistsAtPath:canonical]) {
        for (NSString* f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:SohIos_DocumentsPath() error:nil]) {
            if ([f.pathExtension.lowercaseString isEqualToString:@"z64"]) {
                [NSFileManager.defaultManager copyItemAtPath:[SohIos_DocumentsPath() stringByAppendingPathComponent:f]
                                                      toPath:canonical error:nil];
                NSLog(@"[SohIosShell] adopted %@ as baserom.us.z64", f);
                break;
            }
        }
    }
    if (SohIos_DocumentsHasExt(@[ @"z64", @"n64", @"v64" ]) || SohIos_DocumentsHasExt(@[ @"o2r" ])) {
        return; // already has a ROM or is already extracted
    }
    gOnboarding = [SohIosOnboarding new];
    gOnboarding.window = window;
    UIAlertController* a =
        [UIAlertController alertControllerWithTitle:@"Mario Kart 64 ROM needed"
                                            message:@"Pick your legally-owned Mario Kart 64 (US) ROM (.z64). It will "
                                                    @"be copied into this app's Documents folder, then the game will "
                                                    @"offer to extract it."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Choose ROM…"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction* _) { [gOnboarding presentPicker]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Later (drop it in via Files)"
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
    SohIos_PresentOnboardingVC(window, a, 0); // D18
}

- (void)presentPicker {
    NSMutableArray<UTType*>* types = [NSMutableArray array];
    for (NSString* e in @[ @"z64", @"n64", @"v64" ]) {
        UTType* t = [UTType typeWithFilenameExtension:e];
        if (t != nil) {
            [types addObject:t];
        }
    }
    if (types.count == 0) {
        [types addObject:UTTypeData];
    }
    UIDocumentPickerViewController* p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types
                                                                                                    asCopy:YES];
    p.delegate = self;
    SohIos_PresentOnboardingVC(self.window, p, 0); // D18
}

- (void)documentPicker:(UIDocumentPickerViewController*)c didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    if (urls.count == 0) {
        return;
    }
    NSURL* src = urls.firstObject; // asCopy:YES => already a local temp copy
    // SpaghettiKart's mobile extractor reads exactly Documents/baserom.us.z64.
    NSString* dst = [SohIos_DocumentsPath() stringByAppendingPathComponent:@"baserom.us.z64"];
    NSError* err = nil;
    [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
    BOOL ok = [NSFileManager.defaultManager moveItemAtPath:src.path toPath:dst error:&err];
    if (ok) {
        // user-imported data gets NSFileProtectionNone + sane modes.
        [NSFileManager.defaultManager setAttributes:@{
            NSFileProtectionKey : NSFileProtectionNone,
            NSFilePosixPermissions : @0644
        } ofItemAtPath:dst error:nil];
    }
    NSLog(@"[SohIosShell] ROM import %@ -> %@ (%@)", ok ? @"OK" : @"FAILED", dst, err);
    // D7: no confirmation alert — the onboarding pump loop watches for the
    // file and proceeds straight to extraction. On failure, let them retry.
    if (!ok) {
        SohIos_PresentChooser(self.window);
    }
}

@end

// D7: single-flow onboarding. One chooser alert; picker cancel re-presents.
@implementation SohIosOnboarding (SohIosSingleFlow)
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)c {
    SohIos_PresentChooser(self.window);
}
@end

static void SohIos_PresentChooser(UIWindow* window) {
    gOnboarding = [SohIosOnboarding new];
    gOnboarding.window = window;
    UIAlertController* a = [UIAlertController
        alertControllerWithTitle:@"Mario Kart 64 ROM needed"
                            message:@"Pick your legally-owned Mario Kart 64 (US) ROM (.z64). It will be "
                                    @"copied into this app and extracted automatically (a few seconds)."
                     preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Choose ROM…"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction* _) { [gOnboarding presentPicker]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Later (drop it in via Files)"
                                          style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction* _) { gOnboardLater = 1; }]];
    SohIos_PresentOnboardingVC(window, a, 0); // D18
}

// Adopt a Files-dropped *.z64 under any name as baserom.us.z64 (the mobile
// extractor reads exactly that path; hash is verified by the extractor).
static BOOL SohIos_AdoptAnyZ64(void) {
    NSString* canonical = [SohIos_DocumentsPath() stringByAppendingPathComponent:@"baserom.us.z64"];
    if ([NSFileManager.defaultManager fileExistsAtPath:canonical]) {
        return YES;
    }
    for (NSString* f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:SohIos_DocumentsPath() error:nil]) {
        if ([f.pathExtension.lowercaseString isEqualToString:@"z64"]) {
            [NSFileManager.defaultManager copyItemAtPath:[SohIos_DocumentsPath() stringByAppendingPathComponent:f]
                                                  toPath:canonical error:nil];
            NSLog(@"[SohIosShell] adopted %@ as baserom.us.z64", f);
            return YES;
        }
    }
    return NO;
}

// Called by the game (overlay 0017 v2) INSTEAD of its SDL prompt chain when
// mk64.o2r is missing. Runs on the game thread — which on SDL-iOS is the
// UIKit main thread — so we pump the main runloop while waiting, exactly
// like SDL's own message-box implementation. Returns 1 when baserom.us.z64
// is in place (picker completed or Files drop noticed), 0 if the user
// chose "Later".
int SohIos_RunRomOnboarding(void) {
    if (SohIos_AdoptAnyZ64()) {
        return 1;
    }
    if (![NSThread isMainThread]) {
        NSLog(@"[SohIosShell] RunRomOnboarding off main thread — deferring to Files drop");
        return 0;
    }
    UIWindow* w = gShellWindow;
    if (w == nil) {
        NSLog(@"[SohIosShell] RunRomOnboarding: no window yet");
        return 0;
    }
    gOnboardLater = 0;
    // Queue behind the scene-delegate/landscape blocks OnWindowCreated
    // already dispatched, so presentation order is preserved.
    dispatch_async(dispatch_get_main_queue(), ^{ SohIos_PresentChooser(w); });
    NSLog(@"[SohIosShell] onboarding: waiting for ROM (picker or Files drop)");
    while (!gOnboardLater) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                              beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        SohIos_FitWindowForModal(w, "pump"); // D18: follow a late scene rotation
        if (SohIos_AdoptAnyZ64()) {
            [w.rootViewController dismissViewControllerAnimated:YES completion:nil];
            return 1;
        }
    }
    return 0;
}

// 3D menu toggle: a DIRECT request the engine consumes (Fast3dWindow calls
// GetMenu()->ToggleVisibility()). The old esc-key injection dies on device in
// 3D: the immersive space steals input focus, SDL's window reports focus
// lost, and ImGui clears/ignores key state — sim keeps focus, so every sim
// gate passed while the device silently dropped the key.
volatile int gSoh3DMenuToggleReq = 0;
void SohIos_ToggleMenuKey(void) {
    extern volatile int gSoh3DMode;
    if (gSoh3DMode != 0) {
        gSoh3DMenuToggleReq = 1;
    } else {
        SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE);
    }
}

void SohIos_SetAudioAnchorStatus(int s) {
    extern volatile int gSohAudioAnchorStatus;
    gSohAudioAnchorStatus = s;
}

#pragma mark - Remote console bridge (launch-gated TCP)

// D10: bumped at each meaningful publish; `ver` returns it + compile time.
#define SOH_IOS_SHELL_REV "wave2-ssaa"

// Console bridge on TCP 8768 (spaghettikart; soh=8765, 2ship=8766),
// newline-delimited commands. Numeric SOH_CONSOLE overrides the port.
int SohIos_MemFootprintMB(void); // D8: defined below (jetsam metric)
// Converts "needs hands" into "scriptable" for remote testing .
// Protocol (one command per line, replies "ok"/"err …"):
//   ping                 liveness
//   btn NAME [ms]        press virtual pad button (A B START L R) for ms (default 200)
//   z [ms]               press Z (left trigger axis) for ms
//   stick X Y [ms]       deflect stick, floats -1..1, for ms (default 500)
//   click X Y            SDL mouse click at window point
//   key esc              Escape (toggles the SoH menu)
//   thermal              current thermal state
#ifndef SOH_REMOTE_CONSOLE
#define SOH_REMOTE_CONSOLE 0
#endif

#if SOH_REMOTE_CONSOLE
static NSString* SohIos_HandleConsoleLine(NSString* line) {
    NSArray<NSString*>* tok = [[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        componentsSeparatedByString:@" "];
    if (tok.count == 0 || tok[0].length == 0) {
        return @"err empty";
    }
    NSString* cmd = tok[0].lowercaseString;
    if ([cmd isEqualToString:@"ver"]) {
        // D10: build identity — the stale-OTA/stale-build ambiguity has
        // invalidated four device rounds; every session starts with `ver`.
        return [NSString stringWithFormat:@"ok shell=%s built=%s %s", SOH_IOS_SHELL_REV, __DATE__, __TIME__];
    }
    if ([cmd isEqualToString:@"ping"]) {
        return @"ok";
    }
    if ([cmd isEqualToString:@"thermal"]) {
        return [NSString stringWithFormat:@"ok thermal=%d", SohIos_ThermalState()];
    }
    if ([cmd isEqualToString:@"mem"]) {
        // D8: phys_footprint is the number jetsam judges — not resident size.
        return [NSString stringWithFormat:@"ok mem_mb=%d gpu_ms=%.2f thermal=%d",
                                          SohIos_MemFootprintMB(), gSohIosGpuMs, SohIos_ThermalState()];
    }
    if ([cmd isEqualToString:@"cvarset"]) {
        // tok[1] keeps original case — CVar names are case-sensitive.
        if (tok.count == 3) {
            CVarSetInteger(tok[1].UTF8String, tok[2].intValue);
            return [NSString stringWithFormat:@"ok %@=%d", tok[1], tok[2].intValue];
        }
        return @"err usage: cvarset <name> <int>";
    }
    if ([cmd isEqualToString:@"drawable"]) {
        float t = 0;
#if TARGET_OS_VISION
        t = gSohIosVisionLongEdge;
#endif
        return [NSString stringWithFormat:
                @"ok drawable=%.0fx%.0f contentsScale=%.2f target=%.0f cvar=%d msaa=%d gpu_ms=%.2f engine2d=%dx%d cur=%dx%d failstreak=%d",
                gSohIosDrawableW, gSohIosDrawableH, gSohIosContentsScale, t,
                CVarGetInteger("gSohIos.VisionLongEdge", -1), CVarGetInteger("gMSAAValue", 1), gSohIosGpuMs,
                gSoh3DDbg2DW, gSoh3DDbg2DH, gSoh3DDbgCurW, gSoh3DDbgCurH, gSohIosDrawableFailStreak];
    }
    if ([cmd isEqualToString:@"cvar"] && tok.count >= 2) {
        // Live integer CVar get/set — `cvar gSohIos.AsyncShaders 0` is the
        // async-shader kill switch for stutter A/B without a rebuild.
        const char* name = tok[1].UTF8String;
        // `cvar <name> f` READS a float. Without it a float CVar read back with
        // no value goes through the integer path and answers -999, which reads
        // like "missing" for a key that is present and correct (VR R4, checking
        // the per-mode HUD planes).
        if (tok.count == 3 && [tok[2] isEqualToString:@"f"]) {
            return [NSString stringWithFormat:@"ok %@=%.3f", tok[1], CVarGetFloat(name, -999.0f)];
        }
        BOOL isFloat = tok.count >= 3 && [tok[2] containsString:@"."];
        if (tok.count >= 3) {
            if (isFloat) {
                extern void CVarSetFloat(const char* n, float v);
                CVarSetFloat(name, tok[2].floatValue);
            } else {
                CVarSetInteger(name, tok[2].intValue);
            }
            extern void CVarSave(void);
            CVarSave();
        }
        if (isFloat) {
            return [NSString stringWithFormat:@"ok %@=%.3f", tok[1], CVarGetFloat(name, -999.0f)];
        }
        return [NSString stringWithFormat:@"ok %@=%d", tok[1], CVarGetInteger(name, -999)];
    }
    if ([cmd isEqualToString:@"shaderclear"]) {
        // Wipe Library/Caches + tmp (Documents/game data untouched) so the
        // next launch recompiles shaders COLD — the repeatable stutter A/B
        // (2ship findings doc). Relaunch after running this.
        NSFileManager* fm = NSFileManager.defaultManager;
        int removed = 0;
        NSArray<NSString*>* dirs = @[
            NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject ?: @"",
            NSTemporaryDirectory() ?: @""
        ];
        for (NSString* dir in dirs) {
            if (dir.length == 0) {
                continue;
            }
            for (NSString* entry in [fm contentsOfDirectoryAtPath:dir error:nil]) {
                if ([fm removeItemAtPath:[dir stringByAppendingPathComponent:entry] error:nil]) {
                    removed++;
                }
            }
        }
        return [NSString stringWithFormat:@"ok cleared %d entries (relaunch to recompile cold)", removed];
    }
    // Perf round instrument (D15, = Shipwright D-088): `overlayshot NAME`
    // renders ONLY the touch overlay (its view hierarchy, as displayed) into
    // Documents/NAME.png with a transparent background, so overlay drawing can
    // be compared pixel-for-pixel across builds with the game changing below.
    if ([cmd isEqualToString:@"overlayshot"] && tok.count >= 2) {
        NSString* name = tok[1];
        __block NSString* res = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            extern UIView* SohIos_TouchOverlayView(void);
            UIView* o = SohIos_TouchOverlayView();
            if (o == nil) {
                res = @"err no-overlay";
                return;
            }
            UIGraphicsImageRendererFormat* fmt = [UIGraphicsImageRendererFormat preferredFormat];
            fmt.opaque = NO;
            UIGraphicsImageRenderer* r = [[UIGraphicsImageRenderer alloc] initWithSize:o.bounds.size format:fmt];
            NSData* png = [r PNGDataWithActions:^(UIGraphicsImageRendererContext* c) {
                [o drawViewHierarchyInRect:o.bounds afterScreenUpdates:YES];
            }];
            NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString* path = [docs stringByAppendingPathComponent:[name stringByAppendingString:@".png"]];
            res = [png writeToFile:path atomically:YES]
                      ? [NSString stringWithFormat:@"ok %@ %.0fx%.0f@%.0f", path, o.bounds.size.width,
                                                   o.bounds.size.height, fmt.scale]
                      : @"err write";
        });
        for (int i = 0; i < 300 && res == nil; i++) {
            usleep(10 * 1000);
        }
        return res ?: @"err timeout";
    }
    // Perf round instrument (D15, = Shipwright D-088): `stickspin CX CY R SECS
    // [RPS]` lands a synthetic finger at (CX,CY) through the overlay's REAL
    // stick handlers (so the floating stick spawns there), circles it at
    // radius R points, RPS turns per second (default 1; 0 = hold deflected
    // right), moved at 120 Hz like a ProMotion finger, and lifts it after SECS.
    if ([cmd isEqualToString:@"stickspin"] && tok.count >= 5) {
        CGFloat cx = tok[1].floatValue, cy = tok[2].floatValue, r = tok[3].floatValue;
        double secs = tok[4].doubleValue;
        double rps = tok.count >= 6 ? tok[5].doubleValue : 1.0;
        extern int SohIos_SynthStick(int phase, CGFloat x, CGFloat y);
        __block int began = -3;
        dispatch_async(dispatch_get_main_queue(), ^{ began = SohIos_SynthStick(0, cx, cy); });
        for (int i = 0; i < 200 && began == -3; i++) {
            usleep(10 * 1000);
        }
        if (began != 2) {
            return [NSString stringWithFormat:@"err began=%d (2 = stick)", began];
        }
        CFTimeInterval t0 = CACurrentMediaTime();
        __block dispatch_source_t timer =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_t spin = timer;
        dispatch_source_set_timer(spin, DISPATCH_TIME_NOW, NSEC_PER_SEC / 120, NSEC_PER_MSEC);
        dispatch_source_set_event_handler(spin, ^{
            double el = CACurrentMediaTime() - t0;
            if (el >= secs) {
                SohIos_SynthStick(2, cx, cy);
                dispatch_source_cancel(timer);
                timer = nil; // breaks the block <-> source retain cycle
                return;
            }
            double a = 2.0 * M_PI * rps * el;
            SohIos_SynthStick(1, cx + r * cos(a), cy + r * sin(a));
        });
        dispatch_resume(spin);
        return @"ok began=stick";
    }
    // Perf round instrument (D15): `tc A|B|Z [MS]` presses a touch button
    // through the overlay's real applyButton path and releases it after MS
    // (default 200; MK64 hold-to-lock engages past 600).
    if ([cmd isEqualToString:@"tc"] && tok.count >= 2) {
        NSString* label = tok[1].uppercaseString;
        if (![@[ @"A", @"B", @"Z" ] containsObject:label]) {
            return @"err tc A|B|Z [ms]";
        }
        int ms = tok.count >= 3 ? tok[2].intValue : 200;
        extern int SohIos_SynthButton(NSString* label, int down);
        __block int ok = -3;
        dispatch_async(dispatch_get_main_queue(), ^{ ok = SohIos_SynthButton(label, 1); });
        for (int i = 0; i < 200 && ok == -3; i++) {
            usleep(10 * 1000);
        }
        if (ok != 1) {
            return [NSString stringWithFormat:@"err press=%d", ok];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * NSEC_PER_MSEC), dispatch_get_main_queue(),
                       ^{ SohIos_SynthButton(label, 0); });
        return [NSString stringWithFormat:@"ok %@ %dms", label, ms];
    }
    if ([cmd isEqualToString:@"stickregion"] && tok.count >= 3) {
        // Region-logic probe (idb HID cannot reach visionOS app windows, so
        // the spawn-region change is asserted directly; the delivery path is
        // unchanged code proven by the working buttons).
        CGFloat X = tok[1].floatValue, Y = tok[2].floatValue;
        extern int SohIos_ProbeStickRegion(CGFloat x, CGFloat y, CGSize* outBounds);
        __block int r = -1;
        __block CGSize vb = CGSizeZero;
        dispatch_async(dispatch_get_main_queue(), ^{
            CGSize b = CGSizeZero;
            int rr = SohIos_ProbeStickRegion(X, Y, &b);
            vb = b;
            r = rr;
        });
        for (int i = 0; i < 200 && r == -1; i++) {
            usleep(10 * 1000);
        }
        return [NSString stringWithFormat:@"ok in=%d bounds=%.0fx%.0f", r, vb.width, vb.height];
    }
    if ([cmd isEqualToString:@"hideprobe"]) {
        // Customizer hide/show gate (list / select KEY / chiptap / tapedit X Y
        // / save). SohIos_LayoutHideProbe hops to the main thread.
        extern NSString* SohIos_LayoutHideProbe(NSArray<NSString*>* args);
        NSArray<NSString*>* args =
            tok.count >= 2 ? [tok subarrayWithRange:NSMakeRange(1, tok.count - 1)] : @[];
        return SohIos_LayoutHideProbe(args);
    }
    if ([cmd isEqualToString:@"touchvis"]) {
        // R3: is the parked window's touch layer hidden? 1 hidden / 0 visible /
        // -1 no overlay installed. Reads the live UIView, not the intent.
        extern int SohIos_TouchControlsHiddenState(void);
        return [NSString stringWithFormat:@"ok touch_hidden=%d", SohIos_TouchControlsHiddenState()];
    }
    if ([cmd isEqualToString:@"winsize"] && tok.count >= 3) {
        // Repro instrument (round 14): drive the same window-size cycle the
        // device's 3D parking performs, on the sim. (Round 16 correction:
        // this handler previously prefix-matched against the first TOKEN and
        // could never fire — the round-15 park repro actually exercised the
        // ENTRY path's own geometry request, which the sim honors.)
        CGFloat W = tok[1].floatValue, H = tok[2].floatValue;
        BOOL force = tok.count >= 4 && [tok[3] isEqualToString:@"force"];
        dispatch_async(dispatch_get_main_queue(), ^{
#if TARGET_OS_VISION
            extern void Soh_RequestWindowSize(CGSize size);
            Soh_RequestWindowSize(CGSizeMake(W, H));
#endif
            if (force) {
                UIView* mv = nil;
                UIWindow* w = SohIos_GameWindowWithMetal(&mv);
                if (w != nil) {
                    w.frame = CGRectMake(w.frame.origin.x, w.frame.origin.y, W, H);
                    for (UIView* v = mv; v != nil && v != (UIView*)w; v = v.superview) {
                        v.frame = w.bounds;
                    }
                    [w.rootViewController.view setNeedsLayout];
                    [w.rootViewController.view layoutIfNeeded];
                }
            }
        });
        return @"ok winsize";
    }
    if ([cmd isEqualToString:@"geom"]) {
        // Every layer of the 2D window geometry, numerically (round 13: the
        // restore over-crop was only diagnosable by eye — never again).
        extern int SohIos_GeomReport(char* buf, int cap);
        static char gbuf[512];
        __block BOOL filled = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            SohIos_GeomReport(gbuf, (int)sizeof(gbuf));
            filled = YES;
        });
        for (int i = 0; i < 200 && !filled; i++) {
            usleep(10 * 1000); // async+poll: bridge thread must never sync onto main
        }
        return filled ? [NSString stringWithFormat:@"ok %s", gbuf] : @"error: main queue stalled";
    }
    if ([cmd isEqualToString:@"menu"]) {
        SohIos_ToggleMenuKey(); // direct-toggle in 3D, esc injection in 2D
        return @"ok (toggled)";
    }
    if ([cmd isEqualToString:@"audio"]) {
        extern volatile int gSohAudioAnchorStatus; // 0 unset / 1 ok / 2 threw
        AVAudioSession* s = AVAudioSession.sharedInstance;
        return [NSString stringWithFormat:@"ok category=%@ mode=%@ otherAudio=%d anchor=%d",
                                          s.category, s.mode, (int)s.isOtherAudioPlaying,
                                          gSohAudioAnchorStatus];
    }
    if ([cmd isEqualToString:@"fidelity"]) {
        NSString* path = [NSString stringWithFormat:@"%s/Documents/vp3d-fidelity.log", getenv("HOME")];
        NSString* content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        return content.length ? [@"ok\n" stringByAppendingString:content] : @"ok (no fidelity log yet — enter 3D first)";
    }
    if ([cmd isEqualToString:@"crashtest"]) {
        // R6 scope C, DEV ONLY (this whole bridge is compiled out of public
        // builds — trap C7). Proves the handler actually writes crash.txt,
        // instead of hoping it does the next time the user's headset dies.
        //   crashtest sig     SIGTRAP on the calling (bridge) thread
        //   crashtest main    ... on the MAIN/engine thread
        //   crashtest vr      ... on a background thread, standing in for the
        //                     compositor/render thread (same process handler)
        //   crashtest throw   an uncaught ObjC exception
        //   crashtest terminate      std::terminate() on a background thread
        //   crashtest terminatemain  ... on the main thread
        NSString* kind = tok.count >= 2 ? tok[1].lowercaseString : @"sig";
        SohIos_LogF("crashtest %s requested", kind.UTF8String);
        if ([kind isEqualToString:@"main"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __builtin_trap();
            });
        } else if ([kind isEqualToString:@"vr"]) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                __builtin_trap();
            });
        } else if ([kind isEqualToString:@"throw"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSException raise:@"SohIosCrashTest" format:@"deliberate crashtest throw"];
            });
        } else if ([kind isEqualToString:@"terminate"]) {
            // R16-E: the red/green of the terminate instrument itself. A bare
            // std::terminate() on a SECONDARY thread is the exact shape of the
            // gate abort (`libc++abi: terminating`, no exception clause), so
            // this proves the handler names it before abort() erases the stack.
            extern void SohCrash_TestTerminate(void);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                SohCrash_TestTerminate();
            });
        } else if ([kind isEqualToString:@"terminatemain"]) {
            extern void SohCrash_TestTerminate(void);
            dispatch_async(dispatch_get_main_queue(), ^{
                SohCrash_TestTerminate();
            });
        } else {
            __builtin_trap();
        }
        return @"ok crashtest armed";
    }
    if ([cmd isEqualToString:@"crashlog"]) {
        NSString* path = [NSString stringWithFormat:@"%s/Documents/crash.txt", getenv("HOME")];
        NSString* content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        return content.length ? [@"ok\n" stringByAppendingString:content] : @"ok (no crash.txt)";
    }
#if TARGET_OS_VISION
    if ([cmd isEqualToString:@"3d"]) {
        // Remote enter/exit for the stereo mode (the ornament button is system
        // chrome no injected touch can reach). NEVER dispatch_sync from bridge
        // handlers — the game loop owns the main thread.
        extern void Soh_Enter3D(bool on);
        extern int Soh_Get3DMode(void);
        extern volatile int gSoh3DRunning;
        extern volatile int gSoh3DEyeFrames[2];
        extern volatile int gSoh3DDrainTicks, gSoh3DGcdProbe;
        if (tok.count >= 2) {
            // Direct call: gSoh3DMode is a volatile flag and the Swift side
            // marshals to the main actor itself. Also enqueue a GCD probe.
            BOOL on = [tok[1] isEqualToString:@"on"];
            Soh_Enter3D(on);
            dispatch_async(dispatch_get_main_queue(), ^{ gSoh3DGcdProbe++; });
            return @"ok (direct)";
        }
        return [NSString
            stringWithFormat:@"ok mode=%d loop=%d eyeL=%d eyeR=%d camDist=%.1f conv=%.1f sep=%.2f drain=%d probe=%d menuVis=%d menuBuilds=%d menuVtx=%d menuDraws=%d",
                             Soh_Get3DMode(), gSoh3DRunning, gSoh3DEyeFrames[0], gSoh3DEyeFrames[1], gSoh3DCamDist,
                             gSoh3DDbgConv, gSoh3DDbgSep, gSoh3DDrainTicks, gSoh3DGcdProbe, gSoh3DDbgMenuVis,
                             gSoh3DDbgMenuBuilds, gSoh3DDbgMenuVtx, gSoh3DDbgMenuDraws];
    }
#endif
#if TARGET_OS_VISION
    if ([cmd isEqualToString:@"vr"]) {
        // VR diagnostics harness (VR-spec D11). Every reply is one flat
        // key=value line whose LAST field is a monotone seq number.
        //   vr                       all four dumps
        //   vr pose                  pose + eye matrices + IPD check
        //   vr mode                  mode / arbitration state
        //   vr contract              drawable contract + per-eye extents
        //   vr pace                  engine_fps / tick_tps / present cadence
        //   vr inject X Y Z YAW PITCH   synthetic head pose (metres, degrees)
        //   vr inject off            back to the live compositor pose
        //   vr set scale|dist|height V  world-placement tunables (A of A*V*P)
        //   vr recenter              re-base the seat on the head pose NOW (R5)
        //   vr recalc                R18-B: "Recalculate height" (recenter + re-pin the fp seat)
        //   vr set vrdbg 0..6|99     the R5 rainbow-flicker bisect ladder
        //   vr proj                  R6: the RAW rebuilt per-eye projection
        //   vr tan device|off|<8>    force a tangent set (asymmetric asserts)
        //   vr project <eye> x y z   project an eye-space point through P
        //   vr ui [0|1]              open/close the SwiftUI VR settings sheet
        //   vr ui scroll <section>   scroll it to view|rearview|quality|debug|panel
        //   vr reset                 R9b: restore every VR default (the sheet's
        //                            pinned "VR Settings ... Reset" button)
        //   vr diag [<row> 0|1|reset]  R10: the device bisect kit
        //   vr crashinfo             crash.txt presence/size/head + rotation
        //   vr blackbox              the last 64 shell events
        //   vr set eye_budget <px>   R6: eye framebuffer long edge (pacing)
        //   vr set yawmirror <0|1>  R8: mirror the kart yaw in A (the
        //                           1.0.0.4 bug, on purpose) so the drive
        //                           asserts can prove they are able to fail
        //   vr worldproject <eye> <gx> <gy> <gz>  R8: project a GAME-SPACE
        //                           point through the LIVE composed eye
        //                           matrix (P*V*A), not just P
        //   vr kart <x> <y> <z> <yawBam> | off   R7: inject a kart pose
        //   vr pad                   R16-D: the folded N64 pad bits, which half
        //                            of the Sense layer is alive, and the touch
        //                            overlay's presence predicate — in any mode
        extern const char* SohVR_DumpPose(void);
        extern const char* SohVR_DumpMode(void);
        extern const char* SohVR_DumpContract(void);
        extern const char* SohVR_DumpPacing(void);
        extern void SohVR_InjectPose(float x, float y, float z, float yawDeg, float pitchDeg);
        extern void SohVR_ClearInjectedPose(void);
        extern void SohVR_SetTunables(float scale, float dist, float height);
        extern void SohVR_GetTunables(float* scale, float* dist, float* height);
        NSString* sub = tok.count >= 2 ? tok[1].lowercaseString : @"";
        if ([sub isEqualToString:@"pose"]) {
            return [NSString stringWithFormat:@"ok %s", SohVR_DumpPose()];
        }
        if ([sub isEqualToString:@"mode"]) {
            return [NSString stringWithFormat:@"ok %s", SohVR_DumpMode()];
        }
        if ([sub isEqualToString:@"rear"]) {
            // R16-C falsifier F1: the pane's camera, in game units, against
            // MK64's own look-behind camera. Reported whatever `rearpivot` is.
            extern const char* SohVR_DumpRear(void);
            return [NSString stringWithFormat:@"ok %s", SohVR_DumpRear()];
        }
        if ([sub isEqualToString:@"rearview"]) {
            // R11 item 3: what the rear-view walk actually got handed.
            extern const char* SohVR_DumpRearView(void);
            return [NSString stringWithFormat:@"ok %s", SohVR_DumpRearView()];
        }
        if ([sub isEqualToString:@"contract"]) {
            return [NSString stringWithFormat:@"ok %s", SohVR_DumpContract()];
        }
        if ([sub isEqualToString:@"inuse"]) {
            // R12 item 1: the claim/reservation table, entry by entry.
            extern const char* SohVR_DumpInUse(void);
            return [NSString stringWithFormat:@"ok %s", SohVR_DumpInUse()];
        }
        if ([sub isEqualToString:@"pace"]) {
            return [NSString stringWithFormat:@"ok %s", SohVR_DumpPacing()];
        }
        if ([sub isEqualToString:@"proj"]) {
            // R6: the RAW rebuilt per-eye projection + its invariants. `vr pose`
            // reports the COMPOSED matrix, whose row 0 legitimately mixes P00
            // with the off-centre term — reading a per-eye P mismatch off it is
            // how R6 started with the wrong diagnosis. Read P here instead.
            extern const char* SohVR_DumpProj(void);
            return [NSString stringWithFormat:@"ok %s", SohVR_DumpProj()];
        }
        if ([sub isEqualToString:@"cine"]) {
            // R21 item 3 (overlay 0059 rev2): the cinematic camera's section
            // list against the seat's. `vr cine reset` zeroes the counters.
            extern volatile int gSohVRCineSec, gSohVRCineMode, gSohVRCinePlayer, gSohVRCineCamDir,
                gSohVRCineSeatDir, gSohVRCineCamSec, gSohVRCinePlySec, gSohVRCineIndex, gSohVRCineOwn,
                gSohVRFpWorld;
            extern volatile unsigned int gSohVRCineFrames, gSohVRCineDirDiff, gSohVRCineSecDiff,
                gSohVRCineOverrides;
            extern volatile float gSohVRCineCamKart, gSohVRCineExportErr;
            if (tok.count >= 3 && [tok[2] isEqualToString:@"reset"]) {
                gSohVRCineFrames = gSohVRCineDirDiff = gSohVRCineSecDiff = gSohVRCineOverrides = 0;
                return @"ok cine reset";
            }
            return [NSString stringWithFormat:
                @"ok cinesec=%d fp_world=%d cam_mode=%d cam_player=%d screen_player_is_p1=%d cam_dir=%d seat_dir=%d "
                @"cam_sec=%d ply_sec=%d index=%d cine_frames=%u dir_diff=%u sec_diff=%u overrides=%u "
                @"cam_kart=%.1f cam_export_err=%.1f",
                gSohVRCineSec, gSohVRFpWorld, gSohVRCineMode, gSohVRCinePlayer, gSohVRCineOwn,
                gSohVRCineCamDir, gSohVRCineSeatDir, gSohVRCineCamSec, gSohVRCinePlySec, gSohVRCineIndex,
                gSohVRCineFrames, gSohVRCineDirDiff, gSohVRCineSecDiff, gSohVRCineOverrides,
                gSohVRCineCamKart, gSohVRCineExportErr];
        }
        if ([sub isEqualToString:@"classes"]) {
            // R18-A: the per-object-class table (overlay 0044 rev15). One line,
            // `cls=<name>:n,jit,jitmax,dev,devmax,step,interp,tick,dup,back`
            // per class plus the cause-side base telemetry.
            extern const char* Soh3DClassDump(void);
            extern volatile int gSohVRSeatInterp, gSohVRSeatRebase, gSohVRClassProbe;
            extern volatile unsigned int gSohVRBaseWalks, gSohVRBaseStale, gSohVRSeatRebases;
            extern volatile float gSohVRBaseErrMax, gSohVRBaseErrAcc;
            // R21 item 2: classprobe 2 = the table is the PANE walk's; the
            // pane's walk-clock correction and its knob ride on the line.
            extern volatile int gSohVRPaneLerp, gSohVRMirrorActive;
            extern volatile unsigned int gSohVRPaneLerps, gSohVRRearSeeds;
            extern volatile float gSohVRPaneDxMax;
            return [NSString stringWithFormat:
                @"ok seatinterp=%d seatrebase=%d classprobe=%d panelerp=%d pane_lerps=%u pane_dx_max=%.4f "
                @"rear_seeds=%u mirror_active=%d base_walks=%u base_stale=%u "
                @"base_err_mean=%.4f base_err_max=%.4f seat_rebases=%u %s",
                gSohVRSeatInterp, gSohVRSeatRebase, gSohVRClassProbe, gSohVRPaneLerp, gSohVRPaneLerps,
                gSohVRPaneDxMax, gSohVRRearSeeds, gSohVRMirrorActive, gSohVRBaseWalks,
                gSohVRBaseStale, gSohVRBaseWalks ? gSohVRBaseErrAcc / (float)gSohVRBaseWalks : 0.0f,
                gSohVRBaseErrMax, gSohVRSeatRebases, Soh3DClassDump()];
        }
        if ([sub isEqualToString:@"lakitu"]) {
            // R19 item 6 (overlay 0066): the start-line Lakitu's distance to the
            // game camera (the flat reference), the kart and the VR eye, with
            // minima over the visible countdown. `vr lakitu reset` re-arms the
            // minima. `vr set lakitupush 0` = 1.0.0.17.
            extern volatile int gSohVRLakituPush, gSohVRLakituLive, gSohVRFpWorld;
            extern volatile float gSohVRLakituCamD, gSohVRLakituKartD, gSohVRLakituEyeD;
            extern volatile float gSohVRLakituCamKartD, gSohVRLakituCamDMin, gSohVRLakituEyeDMin,
                gSohVRLakituKartDMin;
            extern volatile unsigned int gSohVRLakituTicks, gSohVRLakituPushes;
            extern volatile float gSohVRLakituAzDeg, gSohVRLakituElDeg, gSohVRLakituCamAzDeg, gSohVRLakituCamElDeg;
            // R20 item 2 (0066 rev2): distance factor, lift, and the clearance
            // over the grid row two places ahead (in sprite heights; >= 0.5 is
            // the requirement) with its inputs.
            extern volatile float gSohVRLakituDistK, gSohVRLakituUp, gSohVRLakituRow2D, gSohVRLakituRow2Top,
                gSohVRLakituRow2Lat, gSohVRLakituFwdD, gSohVRLakituBottom, gSohVRLakituClearH,
                gSohVRLakituClearHMin;
            extern volatile int gSohVRLakituAhead;
            if (tok.count >= 3 && [tok[2].lowercaseString isEqualToString:@"reset"]) {
                gSohVRLakituCamDMin = gSohVRLakituEyeDMin = gSohVRLakituKartDMin = 1.0e9f;
                gSohVRLakituClearHMin = 1.0e9f;
                gSohVRLakituTicks = 0;
                gSohVRLakituPushes = 0;
            }
            return [NSString stringWithFormat:
                @"ok lakitupush=%d fp_world=%d live=%d ticks=%u pushes=%u cam_d=%.2f kart_d=%.2f "
                @"eye_d=%.2f cam_kart_d=%.2f cam_d_min=%.2f kart_d_min=%.2f eye_d_min=%.2f az=%.1f el=%.1f cam_az=%.1f cam_el=%.1f "
                @"lakitudist=%.2f lakituup=%.2f fwd_d=%.2f bottom=%.2f ahead=%d row2_d=%.2f row2_top=%.2f row2_lat=%.2f "
                @"row2_clear_h=%.3f row2_clear_h_min=%.3f",
                gSohVRLakituPush, gSohVRFpWorld, gSohVRLakituLive, gSohVRLakituTicks,
                gSohVRLakituPushes, gSohVRLakituCamD, gSohVRLakituKartD, gSohVRLakituEyeD, gSohVRLakituCamKartD,
                gSohVRLakituCamDMin, gSohVRLakituKartDMin, gSohVRLakituEyeDMin, gSohVRLakituAzDeg,
                gSohVRLakituElDeg, gSohVRLakituCamAzDeg, gSohVRLakituCamElDeg, gSohVRLakituDistK, gSohVRLakituUp,
                gSohVRLakituFwdD, gSohVRLakituBottom, gSohVRLakituAhead, gSohVRLakituRow2D, gSohVRLakituRow2Top,
                gSohVRLakituRow2Lat, gSohVRLakituClearH, gSohVRLakituClearHMin];
        }
        if ([sub isEqualToString:@"vbo"]) {
            // R20 item 1 (overlay 0064 rev3): the vertex pool's GPU-lifetime
            // ledger -- walks by kind (flat/eye1/eye2/pane), walks whose pool
            // buffer still had a GPU reader at their start (`busy`), walks that
            // wrote into one anyway (`write_busy`, the hazard), the fix's swaps/
            // allocs/waits, and question (a)'s readback ledger. `vr vbo reset`
            // zeroes it. `vr set vbofix 0` = 1.0.0.18.
            extern const char* SohIos_VboDump(void);
            extern void SohIos_VboReset(void);
            if (tok.count >= 3 && [tok[2].lowercaseString isEqualToString:@"reset"]) {
                SohIos_VboReset();
            }
            return [NSString stringWithFormat:@"ok %s", SohIos_VboDump()];
        }
        if ([sub isEqualToString:@"fbrd"]) {
            // R19 item 4: the jumbotron readback's walk ledger (overlay 0064
            // rev2). Cumulative submits by the walk that SUBMITTED and serves
            // by the walk that PRODUCED the served bytes (flat/eye1/eye2/pane/
            // empty), serve-only skips, forced waits, no-key-walk fallbacks.
            // `vr fbrd reset` zeroes them. `vr set fbrdgate 0` = 1.0.0.17.
            extern const char* SohIos_FbrdDump(void);
            extern void SohIos_FbrdReset(void);
            if (tok.count >= 3 && [tok[2].lowercaseString isEqualToString:@"reset"]) {
                SohIos_FbrdReset();
            }
            if (tok.count >= 4 && [tok[2].lowercaseString isEqualToString:@"save"]) {
                // `vr fbrd save <name>`: the cached 320x240 readback, raw
                // RGBA5551, into Documents/<name>.raw (the jumbotron's bytes).
                extern int SohIos_FbrdSave(const char* path, int* w_out);
                NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
                NSString* path = [docs stringByAppendingPathComponent:[tok[3] stringByAppendingString:@".raw"]];
                int n = 0;
                int kind = SohIos_FbrdSave(path.UTF8String, &n);
                return [NSString stringWithFormat:@"ok fbrd saved=%@ kind=%d px=%d", path.lastPathComponent, kind, n];
            }
            return [NSString stringWithFormat:@"ok %s", SohIos_FbrdDump()];
        }
        if ([sub isEqualToString:@"ghost"]) {
            // R17-A item 1: the seat-vs-world interpolation probe. Measures in
            // both arms; `vr set seatinterp 0` is the red control.
            extern const char* SohVR_DumpGhost(void);
            return [NSString stringWithFormat:@"ok %s", SohVR_DumpGhost()];
        }
        if ([sub isEqualToString:@"sky"]) {
            // R16-B's falsifier line: world NDC against sprite NDC, off-centre,
            // both eyes, from two paths that share no code. Run it under
            // `vr tan device` for the asymmetric case the simulator's own
            // symmetric frustum can never produce.
            extern const char* SohVR_DumpSky(void);
            return [NSString stringWithFormat:@"ok %s", SohVR_DumpSky()];
        }
        if ([sub isEqualToString:@"tan"]) {
            // Force a tangent set so the asymmetric-frustum asserts can run in
            // the simulator. `vr tan device` loads the REAL Vision Pro tangents
            // captured in docs/VR-R6-DEVICE-EVIDENCE.md.
            extern void SohVR_ForceTangents(int on, const float* eye0, const float* eye1);
            extern const char* SohVR_DumpProj(void);
            if (tok.count == 3 && [tok[2].lowercaseString isEqualToString:@"off"]) {
                SohVR_ForceTangents(0, NULL, NULL);
                return [NSString stringWithFormat:@"ok %s", SohVR_DumpProj()];
            }
            if (tok.count == 3 && [tok[2].lowercaseString isEqualToString:@"device"]) {
                const float e0[4] = { -1.7321f, 1.0000f, -1.1918f, 1.0000f };
                const float e1[4] = { -1.0000f, 1.7321f, -1.1918f, 1.0000f };
                SohVR_ForceTangents(1, e0, e1);
                return [NSString stringWithFormat:@"ok %s", SohVR_DumpProj()];
            }
            if (tok.count == 11) {
                float e0[4], e1[4];
                for (int i = 0; i < 4; i++) {
                    e0[i] = tok[2 + i].floatValue;
                    e1[i] = tok[6 + i].floatValue;
                }
                SohVR_ForceTangents(1, e0, e1);
                return [NSString stringWithFormat:@"ok %s", SohVR_DumpProj()];
            }
            return @"err usage: vr tan device | off | <l0 r0 b0 t0 l1 r1 b1 t1>";
        }
        if ([sub isEqualToString:@"project"]) {
            // Analytic check under asymmetric tangents: a point on the frustum's
            // left edge must land at ndc.x = -1 for THAT eye, whatever the
            // off-centre term is.
            extern void SohVR_ProjectEyePoint(int eye, float x, float y, float z, float* outNdc);
            if (tok.count != 6) {
                return @"err usage: vr project <eye0|1> <x> <y> <z>   (eye-space metres, -z forward)";
            }
            float ndc[4];
            SohVR_ProjectEyePoint(tok[2].intValue, tok[3].floatValue, tok[4].floatValue,
                                  tok[5].floatValue, ndc);
            return [NSString stringWithFormat:@"ok vr_project eye=%d ndc=%.5f,%.5f,%.5f w=%.5f",
                                              tok[2].intValue, ndc[0], ndc[1], ndc[2], ndc[3]];
        }
        if ([sub isEqualToString:@"curtain"]) {
            // R8 item 5: the parked window's curtain, self-reported.
            extern const char* Soh_CurtainInfo(void);
            return [NSString stringWithFormat:@"ok %s", Soh_CurtainInfo()];
        }
        if ([sub isEqualToString:@"worldproject"]) {
            // R8: the same point, but through the WHOLE chain the eye renders
            // with (P*V*A), in GAME units. `vr project` only exercises P, which
            // is why five rounds of green projection numbers said nothing about
            // a mirrored world orientation.
            extern int SohVR_ProjectGamePoint(int eye, float x, float y, float z, float* outNdcW);
            if (tok.count != 6) {
                return @"err usage: vr worldproject <eye0|1> <gx> <gy> <gz>   (GAME units)";
            }
            float ndcw[4] = { 0, 0, 0, 0 };
            int ok = SohVR_ProjectGamePoint(tok[2].intValue, tok[3].floatValue, tok[4].floatValue,
                                            tok[5].floatValue, ndcw);
            return [NSString stringWithFormat:@"ok vr_worldproject eye=%d infront=%d ndc=%.5f,%.5f,%.5f w=%.3f",
                                              tok[2].intValue, ok, ndcw[0], ndcw[1], ndcw[2], ndcw[3]];
        }
        if ([sub isEqualToString:@"ui"]) {
            // Open/close the SwiftUI VR settings sheet. There is no tap
            // injection for a visionOS ornament, so this is how the sheet is
            // screenshot-provable in the simulator.
            //   vr ui [0|1]                open/close
            //   vr ui scroll view|rearview|quality|debug|panel
            // R9b: the scroll form exists for the same reason the open form
            // does — idb HID delivers nothing on these simulators, so a section
            // below the fold is otherwise unphotographable.
            extern void SohVR_ShowSettingsSheet(BOOL on);
            extern void SohVR_ScrollSettingsTo(const char* name);
            if (tok.count >= 4 && [tok[2].lowercaseString isEqualToString:@"scroll"]) {
                SohVR_ScrollSettingsTo(tok[3].lowercaseString.UTF8String);
                return [NSString stringWithFormat:@"ok vr ui scroll %@", tok[3].lowercaseString];
            }
            SohVR_ShowSettingsSheet(tok.count >= 3 ? (tok[2].intValue != 0) : YES);
            return @"ok vr ui";
        }
        if ([sub isEqualToString:@"reset"]) {
            // R9b item 4: the same call the sheet's pinned "VR Settings …
            // Reset" button makes, so the suite asserts the button's BEHAVIOUR
            // and not a second implementation of it.
            extern void SohVR_ResetVRDefaults(void);
            SohVR_ResetVRDefaults();
            return [NSString stringWithFormat:@"ok %s", SohVR_DumpMode()];
        }
        if ([sub isEqualToString:@"diag"]) {
            // R10 item 2: the device bisect kit, from the bridge. The settings
            // rows and this command drive the SAME setters, so the suite tests
            // the shipping mechanism and not a copy of it.
            //   vr diag                      the whole mask + the GPU counters
            //   vr diag <key> 0|1            one row (0 = disable the mechanism)
            //   vr diag reset                every row back on
            extern const char* SohVR_DumpDiag(void);
            extern int SohVR_DiagFindKey(const char* key);
            extern void SohVR_SetDiag(int bit, int on);
            extern void SohVR_DiagResetAll(void);
            if (tok.count == 3 && [tok[2].lowercaseString isEqualToString:@"reset"]) {
                SohVR_DiagResetAll();
                return [NSString stringWithFormat:@"ok %s", SohVR_DumpDiag()];
            }
            if (tok.count == 4) {
                int bit = SohVR_DiagFindKey(tok[2].lowercaseString.UTF8String);
                if (bit < 0) {
                    return [NSString stringWithFormat:@"err unknown diag row '%@' — %s", tok[2],
                                                      SohVR_DumpDiag()];
                }
                SohVR_SetDiag(bit, tok[3].intValue != 0);
                return [NSString stringWithFormat:@"ok %s", SohVR_DumpDiag()];
            }
            return [NSString stringWithFormat:@"ok %s", SohVR_DumpDiag()];
        }
        if ([sub isEqualToString:@"crashinfo"]) {
            // R6 scope C: does the crash machinery exist, did it fire, what did
            // it catch? the user can also just share crash.txt from the Files app.
            extern int SohIos_CrashInfo(char* out, int cap);
            static char cbuf[1400];
            SohIos_CrashInfo(cbuf, (int)sizeof(cbuf));
            return [NSString stringWithFormat:@"ok %s", cbuf];
        }
        if ([sub isEqualToString:@"blackbox"]) {
            extern int SohIos_BlackBoxDump(char* out, int cap);
            static char bbuf[12288];
            SohIos_BlackBoxDump(bbuf, (int)sizeof(bbuf));
            return [NSString stringWithFormat:@"ok\n%s", bbuf];
        }
        if ([sub isEqualToString:@"inject"]) {
            if (tok.count == 3 && [tok[2] isEqualToString:@"off"]) {
                SohVR_ClearInjectedPose();
                return [NSString stringWithFormat:@"ok %s", SohVR_DumpPose()];
            }
            extern void SohVR_InjectPoseRoll(float, float, float, float, float, float);
            if (tok.count == 8) {
                // R17-B: the optional sixth argument is head ROLL in degrees.
                SohVR_InjectPoseRoll(tok[2].floatValue, tok[3].floatValue, tok[4].floatValue,
                                     tok[5].floatValue, tok[6].floatValue, tok[7].floatValue);
                return [NSString stringWithFormat:@"ok %s", SohVR_DumpPose()];
            }
            if (tok.count != 7) {
                return @"err usage: vr inject <x> <y> <z> <yawDeg> <pitchDeg> [rollDeg] | vr inject off";
            }
            SohVR_InjectPose(tok[2].floatValue, tok[3].floatValue, tok[4].floatValue, tok[5].floatValue,
                             tok[6].floatValue);
            return [NSString stringWithFormat:@"ok %s", SohVR_DumpPose()];
        }
        if ([sub isEqualToString:@"kart"]) {
            // R7: stand in for overlay 0045's kart-pose export so the
            // cockpit-lock asserts can RAMP the kart's yaw with no race
            // running. `vr kart off` hands the seat back to the engine.
            extern void SohVR_InjectKart(int on, float x, float y, float z, int yawBam);
            if (tok.count == 3 && [tok[2].lowercaseString isEqualToString:@"off"]) {
                SohVR_InjectKart(0, 0, 0, 0, 0);
                return [NSString stringWithFormat:@"ok %s", SohVR_DumpPose()];
            }
            if (tok.count != 6) {
                return @"err usage: vr kart <x> <y> <z> <yawBam> | vr kart off";
            }
            SohVR_InjectKart(1, tok[2].floatValue, tok[3].floatValue, tok[4].floatValue,
                             tok[5].intValue);
            return [NSString stringWithFormat:@"ok %s", SohVR_DumpPose()];
        }
        if ([sub isEqualToString:@"recenter"]) {
            // R5 (device bug 1): the head's position AND yaw right now become
            // the seat. Same entry point the stick-hold gesture uses, so a
            // bridge recenter and a headset recenter are the same code path.
            extern void SohVR_Recenter(void);
            SohVR_Recenter();
            return [NSString stringWithFormat:@"ok %s", SohVR_DumpPose()];
        }
        if ([sub isEqualToString:@"recalc"]) {
            // R18-B item 2c: the settings sheet's "Recalculate height" button,
            // headless. Same function the button calls.
            extern void SohVR_RecalcHeight(void);
            extern unsigned int SohVR_RecalcCount(void);
            extern float SohVR_GetSeatUp(void);
            extern float SohVR_GetSeatFwd(void);
            SohVR_RecalcHeight();
            return [NSString stringWithFormat:@"ok recalcs=%u seat_up=%.3f seat_fwd=%.3f %s", SohVR_RecalcCount(),
                                              SohVR_GetSeatUp(), SohVR_GetSeatFwd(), SohVR_DumpPose()];
        }
        if ([sub isEqualToString:@"view"]) {
            // View mode (spec D3): every placement tunable, the surroundings
            // choice, the sky treatment and the comfort flags are per mode.
            extern void SohVR_SetView(int view);
            extern void SohVR_CycleView(void);
            extern const char* SohVR_GetViewName(void);
            if (tok.count == 2 || (tok.count == 3 && [tok[2].lowercaseString isEqualToString:@"cycle"])) {
                if (tok.count == 3) {
                    SohVR_CycleView();
                }
                return [NSString stringWithFormat:@"ok %s", SohVR_DumpMode()];
            }
            NSString* v = tok[2].lowercaseString;
            if ([v isEqualToString:@"diorama"]) {
                SohVR_SetView(0);
            } else if ([v isEqualToString:@"fp"] || [v isEqualToString:@"first"]) {
                SohVR_SetView(1);
            } else if ([v isEqualToString:@"third"]) {
                SohVR_SetView(2);
            } else {
                return @"err usage: vr view diorama|fp|third|cycle";
            }
            return [NSString stringWithFormat:@"ok %s", SohVR_DumpMode()];
        }
        if ([sub isEqualToString:@"mirror"]) {
            // The rear-view panes (spec D12), R14 item 3 shape.
            //   top 0|1     the "Top" SETTING (persisted, the settings row)
            //   toggle      the LEFT thumbstick click, headless
            //   lefthand    lives on `vr set lefthand`, as it always has
            //   hold 0|1    a bridge-only force on the top pane, so the suite
            //               can raise it without owning the latch
            //   res / mirrored   unchanged
            // `show`, `hide`, `auto` and `rear` are GONE with the auto-show.
            extern void SohVR_SetMirrorHold(int held);
            extern void SohVR_SetMirrorTop(int on);
            extern int SohVR_ToggleMirrorTop(void);
            extern void SohVR_SetMirrorRes(float res);
            extern void SohVR_SetMirrorMirrored(int on);
            if (tok.count == 2) {
                return [NSString stringWithFormat:@"ok %s", SohVR_DumpMode()];
            }
            NSString* m = tok[2].lowercaseString;
            float mv = (tok.count >= 4) ? tok[3].floatValue : 0.0f;
            if ([m isEqualToString:@"hold"]) {
                SohVR_SetMirrorHold((int)mv);
            } else if ([m isEqualToString:@"top"]) {
                SohVR_SetMirrorTop((int)mv);
            } else if ([m isEqualToString:@"toggle"]) {
                SohVR_ToggleMirrorTop();
            } else if ([m isEqualToString:@"res"]) {
                SohVR_SetMirrorRes(mv);
            } else if ([m isEqualToString:@"mirrored"]) {
                SohVR_SetMirrorMirrored((int)mv);
            } else {
                return @"err usage: vr mirror top 0|1 | toggle | hold 0|1 | res <0.15-1> | mirrored 0|1";
            }
            return [NSString stringWithFormat:@"ok %s", SohVR_DumpMode()];
        }
        if ([sub isEqualToString:@"hands"]) {
            // R4 (spec D13): discovery / authorization / per-hand state. In
            // the simulator, where no spatial hardware exists, this reads
            // state=absent auth=unasked and every hand invalid — which is the
            // ANSWER, not a failure.
            extern const char* SohSense_Dump(void);
            return [NSString stringWithFormat:@"ok %s", SohSense_Dump()];
        }
        if ([sub isEqualToString:@"pad"]) {
            // VR R16-D — THE FLAT FOLD'S FALSIFIER, and the round's red control
            // (trap D11). It answers three questions on ONE line, in whatever
            // mode the app is in:
            //   pad/sx/sy   what the Sense fold produces for MK64's pad RIGHT
            //               NOW, evaluated through the very function the
            //               read_controllers seam calls (no second mapping).
            //   started / input_started / d3running / mode
            //               WHICH half is alive. Pre-fix, `started` is 0 in 2D
            //               and the fold is dead, so pad reads 0x0000 no matter
            //               what is injected — that is the RED. Post-fix,
            //               input_started is 1 and pad carries the bits.
            //   present / controllers
            //               the touch overlay's presence predicate and the
            //               inventory it walked, so the "no controller attached"
            //               half of the user's report is assertable too.
            // This does NOT pump. The pad seam pumps once per game frame in
            // every mode, so the line is at most one frame stale — and pumping
            // from the bridge thread would put a SECOND reader on
            // GCController's elements alongside the engine thread, which is
            // exactly the hazard the single-reader guard in SohSense_PumpFlat
            // exists to prevent. A diagnostic must not create the race it is
            // there to observe.
            extern void SohSense_WritePad(unsigned short* button, signed char* stickX, signed char* stickY);
            extern int SohSense_Active(void);
            extern int SohSense_FlatFoldLive(void);
            extern int SohIos_ControllerPresentProbe(void);
            extern const char* SohIos_ControllerInventory(void);
            extern volatile int gSoh3DRunning;
            extern volatile int gSohVRWorldActive;
            extern int Soh_Get3DMode(void);
            static unsigned int padSeq = 0;
            unsigned short b = 0;
            signed char sx = 0, sy = 0;
            SohSense_WritePad(&b, &sx, &sy);
            int started = 0, inputStarted = 0;
            float flatKnob = 1.0f;
            {
                extern float SohSense_GetTunable(const char* key);
                flatKnob = SohSense_GetTunable("flatfold");
            }
            {
                // Read them off the dump rather than exporting two more globals:
                // SohSense_Dump is the single vocabulary this file already
                // shares with the harness.
                const char* d = SohSense_Dump();
                const char* p = strstr(d, "started=");
                if (p) {
                    started = atoi(p + 8);
                }
                p = strstr(d, "input_started=");
                if (p) {
                    inputStarted = atoi(p + 14);
                }
            }
            return [NSString
                stringWithFormat:@"ok vr_pad pad=0x%04x sx=%d sy=%d started=%d input_started=%d flat_fold=%d "
                                 @"active=%d d3running=%d mode=%d world=%d present=%d t_flatfold=%.0f controllers=%s seq=%u",
                                 b, (int)sx, (int)sy, started, inputStarted, SohSense_FlatFoldLive(),
                                 SohSense_Active(), gSoh3DRunning, Soh_Get3DMode(), gSohVRWorldActive,
                                 SohIos_ControllerPresentProbe(), flatKnob, SohIos_ControllerInventory(), ++padSeq];
        }
        if ([sub isEqualToString:@"hand"]) {
            // Synthetic hand injection — the whole gesture layer, assertable
            // with no controllers in the room.
            //   vr hand L|R <x> <y> <z> <yaw> <pitch> <roll>   pose, metres/deg
            //   vr hand L|R vel <vx> <vy> <vz>                 m/s at release
            //   vr hand L|R btn a|b|trigger|grip|stick|menu 0|1
            //   vr hand L|R stick <x> <y>
            //   vr hand off | doff
            extern void SohSense_InjectHand(int hand, float x, float y, float z, float yawDeg, float pitchDeg,
                                            float rollDeg);
            extern void SohSense_InjectVelocity(int hand, float vx, float vy, float vz);
            extern void SohSense_InjectButton(int hand, const char* name, int down);
            extern void SohSense_InjectStick(int hand, float x, float y);
            extern void SohSense_InjectClear(void);
            extern void SohSense_InjectDoff(void);
            extern const char* SohSense_Dump(void);
            static NSString* const kHandUsage =
                @"err usage: vr hand L|R <x> <y> <z> <yaw> <pitch> <roll> | vr hand L|R vel <vx> <vy> <vz> | "
                @"vr hand L|R btn a|b|trigger|grip|stick|menu 0|1 | vr hand L|R stick <x> <y> | "
                @"vr hand item <mk64-item-id> | vr hand off|doff";
            if (tok.count < 3) {
                return kHandUsage;
            }
            NSString* which = tok[2].lowercaseString;
            if ([which isEqualToString:@"item"] && tok.count >= 4) {
                // Force the EXPORT, not the outcome — R3's rear-item precedent.
                // This writes the very global overlay 0053 writes when MK64 arms
                // an item for player 1, so the in-hand billboard's gating, the
                // pickup haptic edge and the throw gesture's "is there anything
                // to throw" all run exactly as a real item box does. Driving a
                // headless kart into an item box is not repeatable; the 0053
                // call site is verified by patch and by reading.
                extern volatile int gSohVRItemArmed;
                gSohVRItemArmed = tok[3].intValue;
                return [NSString stringWithFormat:@"ok %s", SohSense_Dump()];
            }
            if ([which isEqualToString:@"off"]) {
                SohSense_InjectClear();
                return [NSString stringWithFormat:@"ok %s", SohSense_Dump()];
            }
            if ([which isEqualToString:@"doff"]) {
                SohSense_InjectDoff();
                return [NSString stringWithFormat:@"ok %s", SohSense_Dump()];
            }
            int hand = [which isEqualToString:@"l"] || [which isEqualToString:@"left"]    ? 0
                       : [which isEqualToString:@"r"] || [which isEqualToString:@"right"] ? 1
                                                                                          : -1;
            if (hand < 0 || tok.count < 4) {
                return kHandUsage;
            }
            NSString* verb = tok[3].lowercaseString;
            if ([verb isEqualToString:@"vel"] && tok.count == 7) {
                SohSense_InjectVelocity(hand, tok[4].floatValue, tok[5].floatValue, tok[6].floatValue);
            } else if ([verb isEqualToString:@"btn"] && tok.count == 6) {
                SohSense_InjectButton(hand, tok[4].lowercaseString.UTF8String, tok[5].intValue);
            } else if ([verb isEqualToString:@"stick"] && tok.count == 6) {
                SohSense_InjectStick(hand, tok[4].floatValue, tok[5].floatValue);
            } else if (tok.count == 9) {
                SohSense_InjectHand(hand, tok[3].floatValue, tok[4].floatValue, tok[5].floatValue,
                                    tok[6].floatValue, tok[7].floatValue, tok[8].floatValue);
            } else {
                return kHandUsage;
            }
            return [NSString stringWithFormat:@"ok %s", SohSense_Dump()];
        }
        if ([sub isEqualToString:@"stash"]) {
            // Trap C4 / spec D10. `test` performs a REAL override through
            // the production path so the crash-recovery assert exercises the
            // code a later round's first real override will use.
            extern int SohVR_StashCount(void);
            extern int SohVR_StashRecoveredCount(void);
            extern void SohVR_CVarOverrideInt(const char* name, int value);
            extern void SohVR_StashRestoreOnExit(void);
            if (tok.count >= 3 && [tok[2].lowercaseString isEqualToString:@"test"]) {
                CVarSetInteger("gSohVR.StashSelfTest", 11);
                CVarSave();
                SohVR_CVarOverrideInt("gSohVR.StashSelfTest", 99);
                return [NSString stringWithFormat:@"ok stash=%d selftest=%d (pre=11 overridden=99)",
                                                  SohVR_StashCount(),
                                                  CVarGetInteger("gSohVR.StashSelfTest", -1)];
            }
            if (tok.count >= 3 && [tok[2].lowercaseString isEqualToString:@"restore"]) {
                SohVR_StashRestoreOnExit();
            }
            return [NSString stringWithFormat:@"ok stash=%d recovered=%d selftest=%d", SohVR_StashCount(),
                                              SohVR_StashRecoveredCount(),
                                              CVarGetInteger("gSohVR.StashSelfTest", -1)];
        }
        if ([sub isEqualToString:@"set"]) {
            static NSString* const kUsage =
                @"err usage: vr set scale|dist|height|rscale|eye_budget|hud_dist|hud_height|hud_scale|"
                @"seat_up|seat_fwd|third_up|third_back|mirror_x|mirror_y|mirror_dist|mirror_scale|"
                @"horizon|dim|sky|alphacov|full|dbg|vrdbg|yawmirror|hands|spins|flips|headlock| (R4 Sense) item_hand|throw_min|throw_dot|trail_on|"
                @"trail_back|trail_down|item_inhand|item_scale|wrist_on|wrist_face|wrist_face_x|wrist_gaze|"
                @"wrist_gaze_x|wrist_dist|wrist_dist_x|wrist_up|wrist_scale|haptics|haptic_gain|flatfold|"
                @"fbfail|skypitch|cmask|cinject|diagui|pairfix|staleforce|skyrate|rearfloor|hudscan|hudctop|"
                       @"eyepubhold|eyepub|pairhold|skylatch|kartholefault|yawsnap|r16clear|"
                @"skytan|skyroll|skywide|skyarfault|skydome|skydomer|skyprobe|r17clear|seatinterp|ghostclear|"
                @"seatseedfault|skydomeeyefault|skydomefloorfault|seatrebase|classprobe|classclear|panelerp|cinesec|fbrdgate|lakitupush|vbofix|jumbofeed|lakitudist|lakituup|"
                       @"rearpivot|rearsec|rearownkart|rearaspect|rearscan <value>";
            if (tok.count != 4) {
                return kUsage;
            }
            {
                // R4 tunables (spec D13): every gesture threshold. Tried
                // FIRST, and the table in SohSense.m is the only place they are
                // listed — a key it does not know falls through to R3/R2/R1.
                extern int SohSense_SetTunable(const char* key, float value);
                if (SohSense_SetTunable(tok[2].lowercaseString.UTF8String, tok[3].floatValue)) {
                    extern const char* SohSense_Dump(void);
                    return [NSString stringWithFormat:@"ok %s", SohSense_Dump()];
                }
            }
            {
                // R3 tunables: the rear-view pane's placement and third
                // person's camera offsets.
                extern void SohVR_GetMirrorPlane(float* x, float* y, float* dist, float* scale);
                extern void SohVR_SetThird(float up, float back);
                extern void SohVR_GetThird(float* up, float* back);
                NSString* k3 = tok[2].lowercaseString;
                float v3 = tok[3].floatValue;
                // R11 item 4: mirror_x / _y / _dist / _scale are GONE — the
                // pane's placement is hardcoded and HUD-relative now. The
                // getter stays for `vr mode`'s telemetry line and the suite.
                float tu = 0, tb = 0;
                SohVR_GetThird(&tu, &tb);
                if ([k3 isEqualToString:@"mirror_res"]) {
                    extern void SohVR_SetMirrorRes(float res);
                    SohVR_SetMirrorRes(v3);
                    return [NSString stringWithFormat:@"ok %s", SohVR_DumpMode()];
                }
                if ([k3 isEqualToString:@"third_up"]) {
                    SohVR_SetThird(v3, tb);
                    return [NSString stringWithFormat:@"ok %s", SohVR_DumpMode()];
                }
                if ([k3 isEqualToString:@"third_back"]) {
                    SohVR_SetThird(tu, v3);
                    return [NSString stringWithFormat:@"ok %s", SohVR_DumpMode()];
                }
            }
            {
                // R2 tunables. Keys accept the underscored spelling the R2
                // brief names AND R1's run-together spelling, so scripts and
                // notes from either round keep working.
                extern void SohVR_SetSeat(float up, float fwd);
                extern void SohVR_GetSeat(float* up, float* fwd);
                extern void SohVR_SetFixedHorizon(int on);
                extern void SohVR_SetDimLevel(float dim);
                extern void SohVR_SetSkyMode(int on);
                extern void SohVR_SetAlphaCoverage(int on);
                extern void SohVR_SetModeFullImmersion(int on);
                NSString* k = tok[2].lowercaseString;
                float val = tok[3].floatValue;
                float su = 0, sf = 0;
                SohVR_GetSeat(&su, &sf);
                if ([k isEqualToString:@"eye_budget"] || [k isEqualToString:@"eyebudget"]) {
                    // R6 pacing: the eye framebuffer's long edge in pixels,
                    // before the render-scale multiply. The device drawable
                    // reports 5087x4081 and the interpreter was running twice
                    // at that size — 41.5 Mpix/frame, engine at 22.7 fps.
                    extern void SohVR_SetEyeBudget(float px);
                    SohVR_SetEyeBudget(val);
                    return [NSString stringWithFormat:@"ok %s", SohVR_DumpPacing()];
                }
                if ([k isEqualToString:@"yawmirror"] || [k isEqualToString:@"yaw_mirror"]) {
                    // R8 anti-tautology control: mirror the kart yaw inside A
                    // on purpose (the 1.0.0.4 behaviour). The suite reads the
                    // drive asserts with it OFF and again with it ON, and
                    // requires the ON reading to FAIL — which is how a passing
                    // orientation assert proves it could have failed.
                    extern void SohVR_SetYawMirror(int on);
                    SohVR_SetYawMirror((int)val);
                    return [NSString stringWithFormat:@"ok %s", SohVR_DumpPose()];
                }
                if ([k isEqualToString:@"seat_up"] || [k isEqualToString:@"seatup"]) {
                    SohVR_SetSeat(val, sf);
                    return [NSString stringWithFormat:@"ok %s", SohVR_DumpMode()];
                }
                if ([k isEqualToString:@"seat_fwd"] || [k isEqualToString:@"seatfwd"]) {
                    SohVR_SetSeat(su, val);
                    return [NSString stringWithFormat:@"ok %s", SohVR_DumpMode()];
                }
                if ([k isEqualToString:@"horizon"]) {
                    SohVR_SetFixedHorizon((int)val);
                    return [NSString stringWithFormat:@"ok %s", SohVR_DumpMode()];
                }
                if ([k isEqualToString:@"spins"] || [k isEqualToString:@"realisticspins"]) {
                    // R9 item 6: "Realistic Spins (intense)". 0 = the shipped
                    // fixed-horizon hold, 1 = follow the kart through spin-outs
                    // and the airborne hit-somersault.
                    extern void SohVR_SetRealisticSpins(int on);
                    SohVR_SetRealisticSpins((int)val);
                    return [NSString stringWithFormat:@"ok %s", SohVR_DumpMode()];
                }
                if ([k isEqualToString:@"fpopaque"]) {
                    // R10 item 4 safety valve: 0 = the 1.0.0.6 source-alpha
                    // composite in fully dimmed modes (sprites blended a second
                    // time against the dim wash, i.e. faint).
                    extern void SohVR_SetFpOpaque(int on);
                    SohVR_SetFpOpaque((int)val);
                    return [NSString stringWithFormat:@"ok %s", SohVR_DumpMode()];
                }
                if ([k isEqualToString:@"flips"] || [k isEqualToString:@"realisticflips"]) {
                    // R10 item 5: "Realistic Flip-Out" — the mid-air tumble.
                    extern void SohVR_SetRealisticFlips(int on);
                    SohVR_SetRealisticFlips((int)val);
                    return [NSString stringWithFormat:@"ok %s", SohVR_DumpPacing()];
                }
                if ([k isEqualToString:@"hands"] || [k isEqualToString:@"showhands"]) {
                    // R9b item 8: visionOS upper-limb visibility. Default OFF.
                    extern void SohVR_SetShowHands(int on);
                    SohVR_SetShowHands((int)val);
                    return [NSString stringWithFormat:@"ok %s", SohVR_DumpMode()];
                }
                if ([k isEqualToString:@"headlock"]) {
                    // R9 item 4: the head-position leash (first person).
                    extern void SohVR_SetHeadLock(int on);
                    SohVR_SetHeadLock((int)val);
                    return [NSString stringWithFormat:@"ok %s", SohVR_DumpPose()];
                }
                if ([k isEqualToString:@"item"] || [k isEqualToString:@"grantitem"]) {
                    // R9 harness: hand player one an MK64 item (defines.h ITEM_*;
                    // 4 = triple green shell, 3 = green shell, 6 = banana).
                    extern volatile int gSohVRDbgGrantItem;
                    gSohVRDbgGrantItem = (int)val;
                    return [NSString stringWithFormat:@"ok grant_item=%d", (int)val];
                }
                if ([k isEqualToString:@"diagui"]) {
                    // R14 item 6: summon the hidden Diagnostics group for a dev
                    // round. Session only; the sheet re-reads it on its own
                    // half-second tick, so it appears without reopening.
                    extern void SohVR_SetDiagUI(int on);
                    extern int SohVR_GetDiagUI(void);
                    SohVR_SetDiagUI((int)val);
                    return [NSString stringWithFormat:@"ok diagui=%d", SohVR_GetDiagUI()];
                }
                if ([k isEqualToString:@"cinject"]) {
                    // Raw N64 pad bits ORed at the pad fold: 0x0001 C-right,
                    // 0x0002 C-left, 0x0004 C-down, 0x0008 C-up, 0x0020 L.
                    extern volatile int gSohVRPadInject;
                    gSohVRPadInject = ((int)val) & 0xFFFF;
                    return [NSString stringWithFormat:@"ok cinject=0x%04x", gSohVRPadInject];
                }
                if ([k isEqualToString:@"cmask"]) {
                    // R14 item 4's RED CONTROL. 1 = shipping (C buttons and L
                    // never reach the game in a VR world frame), 0 = the
                    // 1.0.0.10 pad. The C-left assert is worthless without it:
                    // with the mask on, an injected C-left leaves camfwd_err at
                    // 0 whether or not the game would have flipped, so the suite
                    // has to see the flip happen first.
                    extern volatile int gSohVRPadMask;
                    gSohVRPadMask = (val != 0.0f) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok cmask=%d", gSohVRPadMask];
                }
                if ([k isEqualToString:@"fbfail"]) {
                    // R13 item 1d — THE MISSING RED CONTROL for the whole
                    // alloc-failure story. `vr set fbfail <n>` makes the Nth
                    // next framebuffer-attachment allocation return nil, so the
                    // depth-mismatch path, the render-pass refusal and the
                    // compositor's eye-copy guard can all be walked on purpose
                    // instead of waited for. Without it `alloc_fails=0` in a
                    // green run proved only that nothing had gone wrong by
                    // accident. Session only; the suite asserts it ships 0.
                    extern volatile int gSohIosGfxFbFailIn;
                    int n = (int)val;
                    gSohIosGfxFbFailIn = (n < 0) ? 0 : (n > 64) ? 64 : n;
                    return [NSString stringWithFormat:@"ok fbfail=%d", gSohIosGfxFbFailIn];
                }
                if ([k isEqualToString:@"skypitch"]) {
                    // R13 item 3, R14 item 1: the sky's world-lock GAIN. 1 =
                    // shipping, 0 = the R12 head-locked sky. R13 also documented
                    // -1 as "the shift with its sign flipped", because its shift
                    // was a felt sign; R14's shift is a difference of two NDC y
                    // values in one clip space and has no sign left to flip, so
                    // the knob is now only ever an on/off A/B and a gain for
                    // exaggerating the effect while photographing it.
                    extern volatile float gSohVRSkyPitch;
                    gSohVRSkyPitch = (val < -4.0f) ? -4.0f : (val > 4.0f) ? 4.0f : val;
                    return [NSString stringWithFormat:@"ok skypitch=%.2f", gSohVRSkyPitch];
                }
                if ([k isEqualToString:@"slotgate"]) {
                    // R9 item 1 A/B control: 0 = the 1.0.0.5 free-running slots.
                    extern volatile int gSohVRSlotGate;
                    gSohVRSlotGate = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok slotgate=%d", gSohVRSlotGate];
                }
                if ([k isEqualToString:@"eyetag"]) {
                    // R11 item 1: the per-eye corner frame-tag probe.
                    extern volatile int gSohVREyeTagOn;
                    gSohVREyeTagOn = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok eyetag=%d", gSohVREyeTagOn];
                }
                if ([k isEqualToString:@"eyetagfault"]) {
                    // R11 item 1, spec D11's RED CONTROL: make the engine
                    // stamp a deliberately wrong tag. eye_tag_miss must count up
                    // while this is 1, or the assert has no discriminating power
                    // and its green means nothing.
                    extern volatile int gSohVREyeTagFault;
                    gSohVREyeTagFault = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok eyetagfault=%d", gSohVREyeTagFault];
                }
                if ([k isEqualToString:@"eyetagreset"]) {
                    extern volatile unsigned int gSohVREyeTagMiss[2], gSohVREyeTagChecks[2];
                    extern volatile unsigned int gSohVREyeTagPostMiss[2], gSohVRBindDefer[4];
                    extern volatile unsigned int gSohVROwnSweeps, gSohVRHudEncodes, gSohVRHudLastGood;
                    gSohVREyeTagMiss[0] = gSohVREyeTagMiss[1] = 0;
                    gSohVREyeTagChecks[0] = gSohVREyeTagChecks[1] = 0;
                    gSohVREyeTagPostMiss[0] = gSohVREyeTagPostMiss[1] = 0;
                    // R13 item 2a: the HUD's own refusal counter and the two
                    // plane counters clear with the rest, so a suite block can
                    // state the window it measured over.
                    for (int i = 0; i < 4; i++) {
                        gSohVRBindDefer[i] = 0;
                    }
                    gSohVROwnSweeps = gSohVRHudEncodes = gSohVRHudLastGood = 0;
                    return @"ok eye_tag counters cleared";
                }
                if ([k isEqualToString:@"compdelay"]) {
                    // R12 item 1, THE STRESS REPRO. Widens the compositor's
                    // read->claim window until the race the device runs at
                    // microsecond scale is visible in a simulator. Session
                    // only; clamped so a fat-fingered value cannot wedge the
                    // loop past the drawable's own deadline by more than a few
                    // frames.
                    extern volatile int gSohVRCompDelayMs;
                    int ms = (int)val;
                    gSohVRCompDelayMs = (ms < 0) ? 0 : (ms > 400) ? 400 : ms;
                    return [NSString stringWithFormat:@"ok compdelay=%d", gSohVRCompDelayMs];
                }
                if ([k isEqualToString:@"comphold"]) {
                    // R12 item 1, the NEGATIVE control: the same magnitude of
                    // delay, but with the claims already taken. A miss here
                    // would mean the claim does not cover encode->completion.
                    extern volatile int gSohVRCompHoldMs;
                    int ms = (int)val;
                    gSohVRCompHoldMs = (ms < 0) ? 0 : (ms > 400) ? 400 : ms;
                    return [NSString stringWithFormat:@"ok comphold=%d", gSohVRCompHoldMs];
                }
                if ([k isEqualToString:@"hudctop"]) {
                    // R15 item 3's A/B: the HUD content-top fraction the pane
                    // is placed from. Session only, never persisted.
                    extern void SohVR_SetHudCTop(float f);
                    extern float SohVR_GetHudCTop(void);
                    SohVR_SetHudCTop(val);
                    return [NSString stringWithFormat:@"ok hudctop=%.4f %s", SohVR_GetHudCTop(),
                                                      SohVR_DumpMode()];
                }
                if ([k isEqualToString:@"hudscan"]) {
                    // R15 item 3: one-shot readback of the published HUD
                    // framebuffer's alpha, so SOHVR_HUD_CONTENT_TOP is a
                    // measurement instead of a guess.
                    extern void SohVR_RequestHudScan(void);
                    SohVR_RequestHudScan();
                    return @"ok hudscan requested (read hud_alpha_top in vr mode)";
                }
                if ([k isEqualToString:@"skyprobe"]) {
                    // R17-B: the probe sprite's target offset from the heading,
                    // in DEGREES. See gSohVRSkyProbeTargetBam.
                    extern volatile int gSohVRSkyProbeTargetBam;
                    float d = val;
                    if (d < -85.0f) { d = -85.0f; }
                    if (d > 85.0f) { d = 85.0f; }
                    gSohVRSkyProbeTargetBam = (int)lrintf(d * 32768.0f / 180.0f);
                    return [NSString stringWithFormat:@"ok skyprobe=%.1f (bam %d)", d,
                                                      gSohVRSkyProbeTargetBam];
                }
                if ([k isEqualToString:@"skydome"]) {
                    // R17-B, and the RED CONTROL for every claim this round.
                    // 1 = the world-space dome (shipping). 0 = R16-B's ortho
                    // sprites, which is 1.0.0.13's sky end to end, on the same
                    // binary (trap D20).
                    extern volatile int gSohVRSkyDome;
                    gSohVRSkyDome = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok skydome=%d", gSohVRSkyDome];
                }
                if ([k isEqualToString:@"skydomer"]) {
                    // The dome radius in GAME units. Smaller values EXAGGERATE
                    // the parallax the radius exists to suppress, which is how
                    // the budget is photographed rather than asserted.
                    extern volatile float gSohVRSkyDomeR;
                    float r = val;
                    gSohVRSkyDomeR = (r < 100.0f) ? 100.0f : (r > 1.0e6f ? 1.0e6f : r);
                    return [NSString stringWithFormat:@"ok skydomer=%.0f", gSohVRSkyDomeR];
                }
                if ([k isEqualToString:@"r17clear"]) {
                    // Clear the R17-B dome probe's running maxima and its
                    // jitter accumulators, so a phase measures its own window
                    // rather than the session (trap D33's rate corollary).
                    extern volatile float gSohVRSkyDomeErrMax[2], gSohVRSkyDomeJit[2];
                    extern volatile unsigned int gSohVRSkyDomeJitN[2], gSohVRSkyWalks[3];
                    extern volatile unsigned int gSohVRSkyDomeSprites, gSohVRSkyDomeFrames;
                    for (int e = 0; e < 2; e++) {
                        gSohVRSkyDomeErrMax[e] = 0.0f;
                        gSohVRSkyDomeJit[e] = 0.0f;
                        gSohVRSkyDomeJitN[e] = 0;
                    }
                    gSohVRSkyWalks[0] = gSohVRSkyWalks[1] = gSohVRSkyWalks[2] = 0;
                    gSohVRSkyDomeSprites = 0;
                    gSohVRSkyDomeFrames = 0;
                    return @"ok r17clear";
                }
                if ([k isEqualToString:@"rearpivot"]) {
                    // R16-C step 1/2, and F1's RED CONTROL. 0 = the 1.0.0.12
                    // look-at pivot (the defect), 1 = the analytic mirror about
                    // the kart, 2 = MK64's own look-behind camera (ships).
                    extern volatile int gSohVRRearPivot;
                    int m = (int)val;
                    gSohVRRearPivot = (m < 0) ? 0 : (m > 2 ? 2 : m);
                    return [NSString stringWithFormat:@"ok rearpivot=%d", gSohVRRearPivot];
                }
                if ([k isEqualToString:@"rearsec"]) {
                    // R16-C step 4, and F3's RED CONTROL: 0 puts the pane back
                    // on the FORWARD camera's direction-bucketed section list.
                    extern volatile int gSohVRRearSec;
                    gSohVRRearSec = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok rearsec=%d", gSohVRRearSec];
                }
                if ([k isEqualToString:@"rearownkart"]) {
                    // R16-C step 5, and F2's instrument: the local kart drawn
                    // in the pane only.
                    extern volatile int gSohVROwnKartRear;
                    gSohVROwnKartRear = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok rearownkart=%d", gSohVROwnKartRear];
                }
                if ([k isEqualToString:@"rearaspect"]) {
                    // R16-C step 3: 0 restores the 1.0.0.12 eye-aspect sizing.
                    extern volatile int gSohVRRearAspect;
                    gSohVRRearAspect = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok rearaspect=%d", gSohVRRearAspect];
                }
                if ([k isEqualToString:@"rearscan"]) {
                    // R16-C falsifiers F2/F3: one dev-gated blit-and-scan of the
                    // PUBLISHED mirror framebuffer (the hudscan recipe, pointed
                    // at the pane). Off the hot path — trap D33 forbids doing
                    // this per frame. The results land in `vr mode`'s
                    // rear_scan_* fields and in the log line it prints.
                    // 1 = scan and STORE as the F2 baseline (run it with
                    // `rearownkart 0`); 2 = scan and report the difference
                    // centroid against that baseline (with the kart on).
                    // 3 = dump the mirror framebuffer to Documents/rear-N.png.
                    extern void SohVR_RequestRearScan(int mode);
                    extern const char* SohVR_RearPngPath(void);
                    SohVR_RequestRearScan((int)val);
                    if ((int)val >= 3) {
                        return [NSString stringWithFormat:@"ok rearscan=3 requested (last png: %s)",
                                                          SohVR_RearPngPath()];
                    }
                    return [NSString stringWithFormat:@"ok rearscan=%d requested (read rear_* in vr mode)",
                                                      (int)val];
                }
                if ([k isEqualToString:@"rearfloor"]) {
                    // R15 item 5's A/B: 1 restores the 1.0.0.11 pane, which
                    // paints MK64's below-horizon colour ramp across it.
                    extern volatile int gSohVRRearFloor;
                    gSohVRRearFloor = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok rearfloor=%d", gSohVRRearFloor];
                }
                if ([k isEqualToString:@"skyrate"]) {
                    // R15 item 7's A/B and red control: 0 restores the linear
                    // 1.7578125/fov sprite mapping the clouds were sliding on.
                    extern volatile int gSohVRSkyRate;
                    gSohVRSkyRate = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok skyrate=%d", gSohVRSkyRate];
                }
                if ([k isEqualToString:@"skytan"]) {
                    // R16-B step 1's A/B and RED CONTROL: 0 restores the
                    // 1.0.0.12 mapping exactly -- linear in yaw, at the world's
                    // rate AT THE FRAME CENTRE, with no per-eye term. That is
                    // the behaviour the off-centre falsifier must FAIL on, and
                    // it must fail on it in the SAME binary that passes with
                    // the knob at 1 (trap D20).
                    extern volatile int gSohVRSkyTan;
                    gSohVRSkyTan = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok skytan=%d", gSohVRSkyTan];
                }
                if ([k isEqualToString:@"lakitupush"]) {
                    // R19 item 6's RED CONTROL (overlay 0066). 1 = shipping.
                    extern volatile int gSohVRLakituPush;
                    gSohVRLakituPush = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok lakitupush=%d", gSohVRLakituPush];
                }
                if ([k isEqualToString:@"lakitudist"] || [k isEqualToString:@"lakituup"]) {
                    // R20 item 2's knobs (overlay 0066 rev2): the fraction of
                    // the chase camera's offset (0.60 ships) and the lift in
                    // game units (the derived default ships). Session only.
                    extern volatile float gSohVRLakituDistK, gSohVRLakituUp;
                    if ([k isEqualToString:@"lakitudist"]) {
                        gSohVRLakituDistK = (val < 0.05) ? 0.05f : (val > 2.0) ? 2.0f : (float)val;
                    } else {
                        gSohVRLakituUp = (val < -50.0) ? -50.0f : (val > 100.0) ? 100.0f : (float)val;
                    }
                    return [NSString stringWithFormat:@"ok lakitudist=%.2f lakituup=%.2f", gSohVRLakituDistK,
                                                      gSohVRLakituUp];
                }
                if ([k isEqualToString:@"vbofix"]) {
                    // R20 item 1's RED CONTROL (overlay 0064 rev3). 1 = shipping:
                    // a walk never begins writing a vertex buffer the GPU is
                    // still reading; 0 = 1.0.0.18. Resets the ledger.
                    extern volatile int gSohVRVboFix;
                    extern void SohIos_VboReset(void);
                    gSohVRVboFix = ((int)val != 0) ? 1 : 0;
                    SohIos_VboReset();
                    return [NSString stringWithFormat:@"ok vbofix=%d (ledger reset)", gSohVRVboFix];
                }
                if ([k isEqualToString:@"jumbofeed"]) {
                    // R20 item 1's device A/B arm. R21 item 1: the settings row
                    // is gone and this is SESSION-ONLY (never persisted; every
                    // launch starts On): 0 = the jumbotron slice is not
                    // emitted in VR world frames at all.
                    extern void SohVR_SetJumboFeed(int on);
                    extern int SohVR_GetJumboFeed(void);
                    SohVR_SetJumboFeed(((int)val != 0) ? 1 : 0);
                    return [NSString stringWithFormat:@"ok jumbofeed=%d", SohVR_GetJumboFeed()];
                }
                if ([k isEqualToString:@"fbrdgate"]) {
                    // R19 item 4's RED CONTROL (overlay 0064 rev2). 1 = shipping:
                    // in a VR world frame only eye 1 of the key walk reads the
                    // jumbotron framebuffer back; 0 = 1.0.0.17 (every walk,
                    // the rear pane's included). Resets the ledger.
                    extern volatile int gSohVRFbrdGate;
                    extern void SohIos_FbrdReset(void);
                    gSohVRFbrdGate = ((int)val != 0) ? 1 : 0;
                    SohIos_FbrdReset();
                    return [NSString stringWithFormat:@"ok fbrdgate=%d (ledger reset)", gSohVRFbrdGate];
                }
                if ([k isEqualToString:@"seatrebase"]) {
                    // R18-A's A/B and RED CONTROL. 1 = shipping: the eye
                    // matrix is moved from the base the COMPOSITOR built it
                    // around to the current game-thread export before R17-A's
                    // (prev - cur)(1 - t) is applied. 0 = 1.0.0.16 exactly.
                    // Resets both probes: a measurement describes ONE arm.
                    extern volatile int gSohVRSeatRebase;
                    extern void Soh3DGhostReset(void);
                    extern void Soh3DClassReset(void);
                    gSohVRSeatRebase = ((int)val != 0) ? 1 : 0;
                    Soh3DGhostReset();
                    Soh3DClassReset();
                    return [NSString stringWithFormat:@"ok seatrebase=%d (probes reset)", gSohVRSeatRebase];
                }
                if ([k isEqualToString:@"classprobe"]) {
                    // R18-A: the per-object-class probe (dev only). 1 makes the
                    // game emit the 0x70/0x71 class sentinels and 0044 measure
                    // each class against the eye recovered from the composed
                    // matrix; 0 = no sentinel emitted at all. Resets the stats.
                    extern volatile int gSohVRClassProbe;
                    extern void Soh3DClassReset(void);
                    // R21 item 2: 2 = sample the REAR PANE's walk instead of
                    // eye 1 (same table, the eye read off the pane's matrix).
                    gSohVRClassProbe = ((int)val == 2) ? 2 : (((int)val != 0) ? 1 : 0);
                    Soh3DClassReset();
                    return [NSString stringWithFormat:@"ok classprobe=%d (reset)", gSohVRClassProbe];
                }
                if ([k isEqualToString:@"panelerp"]) {
                    // R21 item 2 (overlay 0044 rev16): 1 = the pane's view is
                    // moved onto the walk's own t (ships); 0 = 1.0.1.19, the
                    // RED CONTROL. Resets the class table and the counters.
                    extern volatile int gSohVRPaneLerp;
                    extern volatile unsigned int gSohVRPaneLerps;
                    extern volatile float gSohVRPaneDxMax;
                    extern void Soh3DClassReset(void);
                    gSohVRPaneLerp = ((int)val != 0) ? 1 : 0;
                    gSohVRPaneLerps = 0;
                    gSohVRPaneDxMax = 0.0f;
                    Soh3DClassReset();
                    return [NSString stringWithFormat:@"ok panelerp=%d (probes reset)", gSohVRPaneLerp];
                }
                if ([k isEqualToString:@"cinesec"]) {
                    // R21 item 3 (overlay 0059 rev2): 1 = in a first-person VR
                    // world frame under a cinematic camera (mode 3) the eyes'
                    // course section list comes from the seat; 0 = 1.0.1.19.
                    extern volatile int gSohVRCineSec;
                    extern volatile unsigned int gSohVRCineFrames, gSohVRCineDirDiff, gSohVRCineSecDiff,
                        gSohVRCineOverrides;
                    gSohVRCineSec = ((int)val != 0) ? 1 : 0;
                    gSohVRCineFrames = gSohVRCineDirDiff = gSohVRCineSecDiff = gSohVRCineOverrides = 0;
                    return [NSString stringWithFormat:@"ok cinesec=%d (counters reset)", gSohVRCineSec];
                }
                if ([k isEqualToString:@"classclear"]) {
                    extern void Soh3DClassReset(void);
                    Soh3DClassReset();
                    return @"ok classclear";
                }
                if ([k isEqualToString:@"seatinterp"]) {
                    // R17-A item 1's A/B and RED CONTROL. 1 = the seat is
                    // lerped along the same segment, with the same t, as the
                    // walk it is composed for; 0 = 1.0.0.13 exactly, where the
                    // seat steps once per game frame and the world glides.
                    // Setting it also RESETS the probe, so a measurement can
                    // only ever describe one arm.
                    extern volatile int gSohVRSeatInterp;
                    extern void Soh3DGhostReset(void);
                    gSohVRSeatInterp = ((int)val != 0) ? 1 : 0;
                    Soh3DGhostReset();
                    {
                        extern void Soh3DClassReset(void); // R18-A: one arm per measurement
                        Soh3DClassReset();
                    }
                    return [NSString stringWithFormat:@"ok seatinterp=%d (probe reset)", gSohVRSeatInterp];
                }
                if ([k isEqualToString:@"ghostclear"]) {
                    extern void Soh3DGhostReset(void);
                    Soh3DGhostReset();
                    return @"ok ghostclear";
                }
                if ([k isEqualToString:@"seatseedfault"]) {
                    // R17-C's RED CONTROL and fault injector for 0045 rev7's
                    // seed. 0 = shipping (seed prev = cur across a validity
                    // transition, a game-frame discontinuity or the first
                    // export). 1 = rev6 exactly: never seed. N > 1 = never seed
                    // AND fabricate a stale prev N game units away on the first
                    // export after a discontinuity, which is what gives the
                    // defect a known magnitude on a box where a restart's own
                    // stale delta depends on where the last race ended.
                    // Setting it RESETS the ghost probe, exactly like
                    // seatinterp: a measurement describes ONE arm.
                    extern volatile float gSohVRSeatSeedFault;
                    extern void Soh3DGhostReset(void);
                    float f = val;
                    gSohVRSeatSeedFault = (f < 0.0f) ? 0.0f : (f > 4000.0f ? 4000.0f : f);
                    Soh3DGhostReset();
                    return [NSString stringWithFormat:@"ok seatseedfault=%.1f (probe reset)",
                                                      gSohVRSeatSeedFault];
                }
                if ([k isEqualToString:@"skydomeeyefault"]) {
                    // R17-C (overlay 0051 rev8): inject the |eye| the dome's
                    // fixed-point headroom is computed at. Nothing in the port
                    // can park a kart 32000 game units from the origin, and an
                    // assert that can only NOT see something is worthless
                    // (trap D11). 0 = off, which is every shipped build.
                    extern volatile float gSohVRSkyDomeEyeFault;
                    float f = val;
                    gSohVRSkyDomeEyeFault = (f < 0.0f) ? 0.0f : (f > 1.0e6f ? 1.0e6f : f);
                    return [NSString stringWithFormat:@"ok skydomeeyefault=%.0f",
                                                      gSohVRSkyDomeEyeFault];
                }
                if ([k isEqualToString:@"skydomefloorfault"]) {
                    // R17-C's RED CONTROL for the same: 1 restores 0051 rev7's
                    // clamp ORDER, where the 500-unit floor is applied after the
                    // headroom cap and overrides it.
                    extern volatile int gSohVRSkyDomeFloorFault;
                    gSohVRSkyDomeFloorFault = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok skydomefloorfault=%d",
                                                      gSohVRSkyDomeFloorFault];
                }
                if ([k isEqualToString:@"skywide"]) {
                    // R17-A item 3's A/B and RED CONTROL: 0 drops the lateral
                    // cap quads, which is 1.0.0.13 exactly -- the gradient then
                    // stops at 160 -/+ 120*AR and any aspect below 4:3 leaves a
                    // black strip at each edge of the rear-view pane.
                    extern volatile int gSohVRSkyWide;
                    gSohVRSkyWide = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok skywide=%d", gSohVRSkyWide];
                }
                if ([k isEqualToString:@"skyarfault"]) {
                    // R17-A item 3's FAULT INJECTOR (trap D57): force the
                    // aspect the sky gradient's lateral edges are computed at,
                    // in MILLI-units. 1246 is the Vision Pro's eye; this
                    // simulator's is 1778 and cannot show the defect at all.
                    // 0 = off, which is every shipped configuration.
                    extern volatile int gSohVRSkyArFault;
                    int a = (int)val;
                    gSohVRSkyArFault = (a < 0) ? 0 : (a > 4000 ? 4000 : a);
                    return [NSString stringWithFormat:@"ok skyarfault=%d", gSohVRSkyArFault];
                }
                if ([k isEqualToString:@"skyroll"]) {
                    // R16-B step 4's gain, SHIPPING AT 0. The mechanism (M5) is
                    // real -- nothing in the sky path handles head roll -- but
                    // 0058's caps extend the gradient vertically only, and the
                    // coverage check in §7 fails: a 45-degree roll pulls the
                    // screen corners to a radius of 200 ortho px against a quad
                    // 160 px wide, so the gradient's LEFT and RIGHT edges come
                    // into view. Widening the caps laterally is R17's job; the
                    // knob exists so the mechanism can be photographed now.
                    extern volatile float gSohVRSkyRoll;
                    gSohVRSkyRoll = (val < -4.0f) ? -4.0f : (val > 4.0f) ? 4.0f : val;
                    return [NSString stringWithFormat:@"ok skyroll=%.2f", gSohVRSkyRoll];
                }
                if ([k isEqualToString:@"pairfix"]) {
                    // R15 item 1's A/B: 0 restores the 1.0.0.11 protocol (the
                    // per-eye last-good fallback and the min(tag) anchor), so
                    // the split and the fix are measured on ONE binary.
                    extern volatile int gSohVRPairFix;
                    gSohVRPairFix = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok pairfix=%d", gSohVRPairFix];
                }
                if ([k isEqualToString:@"staleforce"]) {
                    // R15 item 1's RED CONTROL. Bit 0 refuses eye 0's claim,
                    // bit 1 eye 1's, for as long as it is set. Nothing else in
                    // the tree can produce a one-eye stale on demand, and an
                    // assert that can only ever NOT see something is worthless
                    // (trap D11).
                    extern volatile int gSohVRStaleForce;
                    gSohVRStaleForce = ((int)val) & 3;
                    return [NSString stringWithFormat:@"ok staleforce=%d", gSohVRStaleForce];
                }
                if ([k isEqualToString:@"eyepubhold"]) {
                    // R16-A, THE MISSING INJECTION (FAL-A1). Delays eye 0's
                    // publication by <ms> inside its own completion handler, so
                    // the two eyes' publications are separated the way they are
                    // on device (~one eye pass, order 10 ms). `comphold` and
                    // `staleforce` model the CONSUMER; nothing modelled the
                    // producer's inter-eye gap, which is why every "0 splits"
                    // number this arc has produced was measured in a régime the
                    // device never enters. Dev knob, session only, clamped, and
                    // asserted 0 in the shipped configuration by the same suite
                    // line that guards staleforce and comphold.
                    extern volatile int gSohVREyePubHoldMs;
                    int ms = (int)val;
                    gSohVREyePubHoldMs = (ms < 0) ? 0 : (ms > 100) ? 100 : ms;
                    return [NSString stringWithFormat:@"ok eyepubhold=%d", gSohVREyePubHoldMs];
                }
                if ([k isEqualToString:@"eyepub"]) {
                    // R16-A F2's A/B: 0 restores the 1.0.0.12 protocol, each
                    // eye's completion handler publishing independently — the
                    // source of every split the pair rule then has to hide.
                    extern volatile int gSohVREyePubAtomic;
                    gSohVREyePubAtomic = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok eyepub=%d", gSohVREyePubAtomic];
                }
                if ([k isEqualToString:@"pairhold"]) {
                    // R16-A F3's A/B: 0 re-claims the last-good pair every
                    // frame (1.0.0.12); 1 holds the claim across frames so the
                    // fallback is always available.
                    extern volatile int gSohVRPairHold;
                    gSohVRPairHold = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok pairhold=%d", gSohVRPairHold];
                }
                if ([k isEqualToString:@"skylatch"]) {
                    // R16-A F4's RED CONTROL: 0 restores the LIVE per-eye read
                    // of gSohVRSkyShift, which places eye 0's sky for one head
                    // pose and eye 1's for another inside one frame.
                    extern volatile int gSohVRSkyLatch;
                    gSohVRSkyLatch = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok skylatch=%d", gSohVRSkyLatch];
                }
                if ([k isEqualToString:@"kartholefault"]) {
                    // R16-A F1's RED CONTROL: the kart-pose export skips N
                    // CONSECUTIVE game frames out of every 16, so the staleness
                    // bound can be shown HOLDING for a burst no longer than the
                    // bound and letting go for one that is. 0 = off.
                    extern volatile int gSohVRKartHoleFault;
                    int n = (int)val;
                    gSohVRKartHoleFault = (n < 0) ? 0 : (n > 15) ? 15 : n;
                    return [NSString stringWithFormat:@"ok kartholefault=%d", gSohVRKartHoleFault];
                }
                if ([k isEqualToString:@"yawsnap"]) {
                    // R16-A F1 step 4's RED CONTROL: 1 = the 1.0.0.12 arming
                    // rule (alpha 1 whenever the seat is not from the kart), so
                    // the snap and the ease are measured on ONE binary.
                    extern volatile int gSohVRYawSnap;
                    gSohVRYawSnap = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok yawsnap=%d", gSohVRYawSnap];
                }
                if ([k isEqualToString:@"r16clear"]) {
                    // R16-A: clear the round's counters, so a suite block can
                    // state the window it measured over (the yaw step is a MAX
                    // and cannot be differenced).
                    extern volatile unsigned int gSohVRSeatFallbacks, gSohVREyeBlank[2];
                    extern volatile unsigned int gSohVRPubOrphans, gSohVREyeMono;
                    extern volatile unsigned int gSohVRSkyTagSkew;
                    extern volatile float gSohVRWorldYawStepMax;
                    gSohVRSeatFallbacks = 0;
                    gSohVRWorldYawStepMax = 0.0f;
                    gSohVREyeBlank[0] = gSohVREyeBlank[1] = 0;
                    gSohVREyeMono = 0;
                    gSohVRPubOrphans = 0;
                    gSohVRSkyTagSkew = 0;
                    // R16-B counters.
                    extern volatile float gSohVRSkyLagMaxDeg;
                    extern volatile unsigned int gSohVRSkyAffine[3];
                    gSohVRSkyLagMaxDeg = 0.0f;
                    gSohVRSkyAffine[0] = gSohVRSkyAffine[1] = gSohVRSkyAffine[2] = 0;
                    extern volatile unsigned int gSohVRSkyLagCorr;
                    gSohVRSkyLagCorr = 0;
                    extern void SohVR_ClearKartStats(void);
                    SohVR_ClearKartStats();
                    return @"ok r16 counters cleared";
                }
                if ([k isEqualToString:@"ownfix"]) {
                    // R12 item 1's A/B: 0 restores the 1.0.0.8 protocol (the
                    // consumer's claim only, no producer reservation), so the
                    // bug and the fix are photographed in ONE build — trap
                    // D20's rule, applied to a race.
                    extern volatile int gSohVREngineOwnFix;
                    gSohVREngineOwnFix = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok ownfix=%d", gSohVREngineOwnFix];
                }
                if ([k isEqualToString:@"conefault"]) {
                    // R11 item 3b, spec D11: force MK64's view-cone test to
                    // reject everything, so the VR angle-cull override is the
                    // only thing that can list a kart.
                    extern volatile int gSohVRConeFault;
                    gSohVRConeFault = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok conefault=%d", gSohVRConeFault];
                }
                if ([k isEqualToString:@"rearsky"]) {
                    // R11 item 3c A/B: 0 restores the 1.0.0.7 head-following sky
                    // in the rear-view pane.
                    extern volatile int gSohVRRearSky;
                    gSohVRRearSky = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok rearsky=%d", gSohVRRearSky];
                }
                if ([k isEqualToString:@"lefthand"]) {
                    // R11 item 4: the pane rides the left controller.
                    extern void SohVR_SetMirrorLeftHand(int on);
                    SohVR_SetMirrorLeftHand((int)val != 0);
                    return [NSString stringWithFormat:@"ok %s", SohVR_DumpMode()];
                }
                if ([k isEqualToString:@"hudwide"]) {
                    // R9 item 7 A/B control: 0 reinstates the clipped LAP.
                    extern volatile int gSohVRHudWideSym;
                    gSohVRHudWideSym = ((int)val != 0) ? 1 : 0;
                    return [NSString stringWithFormat:@"ok hudwide=%d", gSohVRHudWideSym];
                }
                if ([k isEqualToString:@"eyeaspect"] || [k isEqualToString:@"eye_aspect"]) {
                    // R9 item 7 diagnostic: force the eye extent's aspect so the
                    // simulator can render at the DEVICE's 1.246 and reproduce
                    // the clipped LAP element. 0 turns it off.
                    extern void SohVR_SetEyeAspectDbg(float ar);
                    SohVR_SetEyeAspectDbg(val);
                    return [NSString stringWithFormat:@"ok %s", SohVR_DumpPacing()];
                }
                if ([k isEqualToString:@"foveation"] || [k isEqualToString:@"fov"]) {
                    // R9 item 1c: foveated ENGINE rendering. Honoured only where
                    // the runtime actually reports a rasterization rate map; the
                    // simulator reports none (trap D15) and stays on the
                    // full-resolution path whatever this is set to.
                    extern void SohVR_SetFoveation(int on);
                    SohVR_SetFoveation((int)val);
                    return [NSString stringWithFormat:@"ok %s", SohVR_DumpContract()];
                }
                if ([k isEqualToString:@"dim"]) {
                    SohVR_SetDimLevel(val);
                    return [NSString stringWithFormat:@"ok %s", SohVR_DumpMode()];
                }
                if ([k isEqualToString:@"sky"]) {
                    SohVR_SetSkyMode((int)val);
                    return [NSString stringWithFormat:@"ok %s", SohVR_DumpMode()];
                }
                if ([k isEqualToString:@"alphacov"]) {
                    SohVR_SetAlphaCoverage((int)val);
                    return [NSString stringWithFormat:@"ok %s", SohVR_DumpMode()];
                }
                if ([k isEqualToString:@"full"]) {
                    SohVR_SetModeFullImmersion((int)val);
                    return [NSString stringWithFormat:@"ok %s", SohVR_DumpMode()];
                }
            }
            extern void SohVR_SetRenderScale(float scale01);
            extern void SohVR_SetHudPlane(float dist, float height, float scale);
            extern void SohVR_GetHudPlane(float* dist, float* height, float* scale);
            float scale = 0, dist = 0, height = 0;
            SohVR_GetTunables(&scale, &dist, &height);
            float hd = 0, hh = 0, hs = 0;
            SohVR_GetHudPlane(&hd, &hh, &hs);
            NSString* key = tok[2].lowercaseString;
            float v = tok[3].floatValue;
            if ([key isEqualToString:@"vrdbg"]) {
                // R5 bisect ladder (device bug 2). See SohImmersive.m for the
                // level table; 99 = every mitigation at once.
                extern void SohVR_SetVrDbg(int level);
                SohVR_SetVrDbg((int)v);
                return [NSString stringWithFormat:@"ok %s", SohVR_DumpPose()];
            }
            if ([key isEqualToString:@"scale"]) {
                scale = v;
            } else if ([key isEqualToString:@"dist"]) {
                dist = v;
            } else if ([key isEqualToString:@"height"]) {
                height = v;
            } else if ([key isEqualToString:@"rscale"]) {
                SohVR_SetRenderScale(v);
                return [NSString stringWithFormat:@"ok %s", SohVR_DumpContract()];
            } else if ([key isEqualToString:@"huddist"] || [key isEqualToString:@"hud_dist"]) {
                hd = v;
            } else if ([key isEqualToString:@"hudheight"] || [key isEqualToString:@"hud_height"]) {
                hh = v;
            } else if ([key isEqualToString:@"dbg"]) {
                extern void SohVR_SetBlitDebug(int mode);
                SohVR_SetBlitDebug((int)v);
                return [NSString stringWithFormat:@"ok blit dbg=%d (0 off, 1 half-alpha, 2 depth, 3 alpha, 4 plane-magenta, 5 plane-opaque)",
                                                  (int)v];
            } else if ([key isEqualToString:@"hudscale"] || [key isEqualToString:@"hud_scale"]) {
                hs = v;
            } else {
                return kUsage;
            }
            SohVR_SetTunables(scale, dist, height);
            SohVR_SetHudPlane(hd, hh, hs);
            return [NSString stringWithFormat:@"ok %s", SohVR_DumpPose()];
        }
        if ([sub isEqualToString:@"enter"]) {
            // Remote mode switch (the ornament is system chrome no injected
            // touch can reach): 0 = flat, 1 = 3D panel, 2 = VR.
            extern void Soh_EnterMode(int mode);
            if (tok.count != 3) {
                return @"err usage: vr enter 0|1|2";
            }
            int m = tok[2].intValue;
            if (m < 0 || m > 2) {
                return @"err usage: vr enter 0|1|2";
            }
            Soh_EnterMode(m);
            return [NSString stringWithFormat:@"ok requested mode=%d", m];
        }
        if ([sub isEqualToString:@"surround"]) {
            // Live surroundings switch inside the VR space (spec D3; R0
            // proved the style set is contract-stable across live switches).
            extern void SohVR_SetFullImmersion(bool on);
            if (tok.count != 3) {
                return @"err usage: vr surround passthrough|full";
            }
            BOOL full = [tok[2].lowercaseString isEqualToString:@"full"];
            SohVR_SetFullImmersion(full ? true : false);
            return [NSString stringWithFormat:@"ok surround=%@", full ? @"full" : @"passthrough"];
        }
        if (sub.length == 0) {
            return [NSString stringWithFormat:@"ok %s\n%s\n%s\n%s", SohVR_DumpMode(), SohVR_DumpContract(),
                                              SohVR_DumpPose(), SohVR_DumpPacing()];
        }
        return @"err unknown vr subcommand "
               @"(pose|mode|contract|pace|inject|set|view|enter|surround|mirror|stash|hands|hand)";
    }
#endif
    if ([cmd isEqualToString:@"logtail"]) {
        int lines = tok.count >= 2 ? MAX(10, MIN(400, tok[1].intValue)) : 80;
        NSString* dir = [NSString stringWithFormat:@"%s/Documents/logs", getenv("HOME")];
        NSArray* files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
        for (NSString* f in files) {
            if ([f hasSuffix:@".log"]) {
                NSString* content =
                    [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:f]
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
                NSArray* all = [content componentsSeparatedByString:@"\n"];
                NSUInteger start = all.count > (NSUInteger)lines ? all.count - lines : 0;
                return [@"ok\n" stringByAppendingString:
                            [[all subarrayWithRange:NSMakeRange(start, all.count - start)]
                                componentsJoinedByString:@"\n"]];
            }
        }
        return @"ok (no log files)";
    }
    if ([cmd isEqualToString:@"bg"]) {
        return [NSString stringWithFormat:@"ok backgrounded=%d", SohIos_IsBackgrounded()];
    }
    if ([cmd isEqualToString:@"pads"]) {
        // Controller diagnostics: name, mapping, live axes — the Z-dead-on-
        // gamepad investigation reads this on sim AND on device.
        NSMutableString* out = [NSMutableString stringWithString:@"ok "];
        for (int i = 0; i < SDL_NumJoysticks(); i++) {
            if (!SDL_IsGameController(i)) {
                [out appendFormat:@"[j%d %s notGC] ", i, SDL_JoystickNameForIndex(i) ?: "?"];
                continue;
            }
            SDL_GameController* gc = SDL_GameControllerOpen(i); // refcounted; close below only releases our ref
            if (gc == NULL) {
                continue;
            }
            char* map = SDL_GameControllerMapping(gc);
            NSString* mapStr = map ? [NSString stringWithUTF8String:map] : @"none";
            if (map != NULL) {
                SDL_free(map);
            }
            if (mapStr.length > 260) {
                mapStr = [[mapStr substringToIndex:260] stringByAppendingString:@"..."];
            }
            [out appendFormat:@"[gc%d %s axes=%d,%d,%d,%d,%d,%d map=%@] ", i, SDL_GameControllerName(gc) ?: "?",
                              SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_LEFTX),
                              SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_LEFTY),
                              SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_RIGHTX),
                              SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_RIGHTY),
                              SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_TRIGGERLEFT),
                              SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_TRIGGERRIGHT), mapStr];
            SDL_GameControllerClose(gc);
        }
        return out;
    }
    if ([cmd isEqualToString:@"seq"]) {
        uint32_t ids = SohIos_ActiveSeqIds();
        return [NSString stringWithFormat:@"ok bgm=0x%04x fanfare=0x%04x", ids & 0xFFFF, (ids >> 16) & 0xFFFF];
    }
    if ([cmd isEqualToString:@"key"] && tok.count >= 2 && [tok[1] isEqualToString:@"esc"]) {
        SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE);
        return @"ok";
    }
    if ([cmd isEqualToString:@"click"] && tok.count >= 3) {
        SohIos_InjectClick(tok[1].intValue, tok[2].intValue);
        return @"ok";
    }
    if ([cmd isEqualToString:@"z"]) {
        int ms = tok.count >= 2 ? tok[1].intValue : 200;
        SohIos_PadAxis(SDL_CONTROLLER_AXIS_TRIGGERLEFT, 32767);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)), dispatch_get_main_queue(),
                       ^{ SohIos_PadAxis(SDL_CONTROLLER_AXIS_TRIGGERLEFT, 0); });
        return @"ok";
    }
    if ([cmd isEqualToString:@"cpudrive"] && tok.count >= 2) {
        // D17 instrument: hand player 1 to the CPU driver (the editor's
        // human/AI toggle, Tools.cpp) so a headless sim lap reaches the
        // jumbotron. Player.type is the u16 at offset 0; PLAYER_CPU = 0x1000.
        extern unsigned short* gPlayerOne;
        if (gPlayerOne == NULL) {
            return @"err no player";
        }
        if (tok[1].intValue) {
            *gPlayerOne |= 0x1000;
        } else {
            *gPlayerOne &= (unsigned short)~0x1000;
        }
        return [NSString stringWithFormat:@"ok type=0x%04x", *gPlayerOne];
    }
    if ([cmd isEqualToString:@"stick"] && tok.count >= 3) {
        float x = tok[1].floatValue, y = tok[2].floatValue;
        int ms = tok.count >= 4 ? tok[3].intValue : 500;
        SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTX, (Sint16)(MAX(-1.f, MIN(1.f, x)) * 32767));
        SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTY, (Sint16)(MAX(-1.f, MIN(1.f, y)) * 32767));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTX, 0);
            SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTY, 0);
        });
        return @"ok";
    }
    if ([cmd isEqualToString:@"btn"] && tok.count >= 2) {
        static NSDictionary<NSString*, NSNumber*>* map = nil;
        if (map == nil) {
            map = @{
                @"a" : @(SDL_CONTROLLER_BUTTON_A),
                @"b" : @(SDL_CONTROLLER_BUTTON_X), // MK64 brake (see applyButton)
                @"start" : @(SDL_CONTROLLER_BUTTON_START),
                @"l" : @(SDL_CONTROLLER_BUTTON_LEFTSHOULDER),
                @"r" : @(SDL_CONTROLLER_BUTTON_RIGHTSHOULDER),
                // D-pad (VR R2): MK64's pause menu and several map-select rows
                // read the D-PAD, not the analog stick, so `stick` pulses were
                // silently doing nothing there. Menu navigation from the bridge
                // is how every headless sim assert reaches a chosen track.
                @"up" : @(SDL_CONTROLLER_BUTTON_DPAD_UP),
                @"down" : @(SDL_CONTROLLER_BUTTON_DPAD_DOWN),
                @"left" : @(SDL_CONTROLLER_BUTTON_DPAD_LEFT),
                @"right" : @(SDL_CONTROLLER_BUTTON_DPAD_RIGHT),
            };
        }
        NSNumber* b = map[tok[1].lowercaseString];
        if (b == nil) {
            return @"err unknown button";
        }
        int ms = tok.count >= 3 ? tok[2].intValue : 200;
        SDL_GameControllerButton btn = (SDL_GameControllerButton)b.intValue;
        SohIos_PadButton(btn, YES);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)), dispatch_get_main_queue(),
                       ^{ SohIos_PadButton(btn, NO); });
        return @"ok";
    }
    return @"err unknown command";
}

static void SohIos_StartConsoleBridge(BOOL force) {
    // Gated three ways: SOH_CONSOLE env (tool launches: simctl/devicectl), a
    // `console_enabled` file in Documents — creatable/deletable in the Files
    // app, so user-launched builds (OTA/TestFlight) can opt in without a
    // computer — or force=YES (soh://console deep link on a running app).
    static BOOL started = NO; // all callers are on the main thread
    if (started) {
        return;
    }
    BOOL fileGate = NO;
    const char* home = getenv("HOME");
    if (home != NULL) {
        // Accept a .txt suffix too — iOS Files can't create extensionless
        // files without a rename dance.
        NSString* docs = [NSString stringWithFormat:@"%s/Documents", home];
        fileGate = [NSFileManager.defaultManager
                       fileExistsAtPath:[docs stringByAppendingPathComponent:@"console_enabled"]] ||
                   [NSFileManager.defaultManager
                       fileExistsAtPath:[docs stringByAppendingPathComponent:@"console_enabled.txt"]];
    }
    const char* consoleEnv = getenv("SOH_CONSOLE");
    if (!force && consoleEnv == NULL && !fileGate) {
        return; // launch-gated: no listener unless explicitly requested
    }
    // spaghettikart's bridge is ALWAYS 8768 by default (soh=8765, 2ship=8766;
    // simulators share the Mac's localhost). Numeric SOH_CONSOLE overrides.
    int consolePort = 8768;
    if (consoleEnv != NULL) {
        int envPort = atoi(consoleEnv);
        if (envPort > 1024 && envPort <= 65535) {
            consolePort = envPort;
        }
    }
    started = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int srv = socket(AF_INET, SOCK_STREAM, 0);
        if (srv < 0) {
            NSLog(@"[SohIosShell] bridge socket failed: %d", errno);
            return;
        }
        int one = 1;
        setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = INADDR_ANY;
        addr.sin_port = htons(consolePort);
        BOOL bound = NO;
        for (int i = 0; i < 10 && !bound; i++) { // bind retry (predecessor pattern)
            bound = bind(srv, (struct sockaddr*)&addr, sizeof(addr)) == 0;
            if (!bound) {
                usleep(500 * 1000);
            }
        }
        if (!bound || listen(srv, 1) != 0) {
            NSLog(@"[SohIosShell] bridge bind/listen failed: %d", errno);
            close(srv);
            return;
        }
        NSLog(@"[SohIosShell] console bridge listening on :%d", consolePort);
        for (;;) {
            int cli = accept(srv, NULL, NULL);
            if (cli < 0) {
                continue;
            }
            // A client that disconnects before a slow handler replies (btn
            // holds the press across frames) must get EPIPE, not SIGPIPE —
            // an unhandled SIGPIPE killed the whole app mid-session
            // (sim-verified 2026-07-22: launchd "exited due to SIGPIPE";
            // the device round's 12:40 "BRIDGE LOST" fits the same class).
            int nosig = 1;
            setsockopt(cli, SOL_SOCKET, SO_NOSIGPIPE, &nosig, sizeof(nosig));
            NSLog(@"[SohIosShell] bridge client connected");
            FILE* f = fdopen(cli, "r");
            char line[512];
            while (f != NULL && fgets(line, sizeof(line), f) != NULL) {
                NSString* resp = SohIos_HandleConsoleLine([NSString stringWithUTF8String:line] ?: @"");
                dprintf(cli, "%s\n", resp.UTF8String);
            }
            if (f != NULL) {
                fclose(f);
            }
            NSLog(@"[SohIosShell] bridge client disconnected");
        }
    });
}

#else // !SOH_REMOTE_CONSOLE — public build: no listener exists at all.
static void SohIos_StartConsoleBridge(BOOL force) {
    (void)force;
}
#endif

#pragma mark - Deep links (spaghetti:// URL scheme)

static void SohIos_HandleDeepLink(NSString* url) {
    NSLog(@"[SohIosShell] deep link: %@", url);
    if ([url hasPrefix:@"spaghetti://console"]) {
        SohIos_StartConsoleBridge(YES); // one-tap remote debugging opt-in
    } else if ([url hasPrefix:@"spaghetti://menu"]) {
        SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE);
    } else {
        NSLog(@"[SohIosShell] unknown deep link ignored: %@", url);
    }
}

// SDL2's UIKit app delegate delivers incoming custom-scheme URLs as
// SDL_DROPFILE events (application:openURL: -> SDL_SendDropFile). A filter
// (not a watch) can consume them before LUS's FileDropMgr mistakes the URL
// for a file path. NOTE (verified by lldb breakpoints on this runtime):
// iOS 26-era UIKit never calls the legacy application:openURL: on this app
// at all — it runs a scene session (nil delegate) and delivers URL opens
// only via scene:openURLContexts:. The SohIosSceneDelegate below is the
// path that actually fires; this filter stays as belt-and-braces for
// runtimes that still use the legacy delegate.
static int SohIos_EventFilter(void* userdata, SDL_Event* event) {
    if (event->type == SDL_DROPFILE && event->drop.file != NULL &&
        strncmp(event->drop.file, "spaghetti://", 12) == 0) {
        NSString* url = [NSString stringWithUTF8String:event->drop.file];
        SDL_free(event->drop.file);
        event->drop.file = NULL;
        dispatch_async(dispatch_get_main_queue(), ^{ SohIos_HandleDeepLink(url); });
        return 0; // consumed
    }
    // Stray-Escape guard. LUS toggles the menu on Escape (Gui.cpp), and on
    // iOS the ONLY legitimate sources of Escape are this shell's own
    // injections — the ≡ button, the restore dot, the deep link, the bridge.
    // Anything else is forged: iPadOS turns a game controller's B into a
    // UIKit "cancel", which SDL's UIKit backend used to hand over as a
    // keyboard Escape, so B opened/closed the menu on every press. The SDL
    // dependency patch closes both forgery routes at the source; this is
    // the backstop that holds no matter what synthesizes the key.
    if ((event->type == SDL_KEYDOWN || event->type == SDL_KEYUP) &&
        event->key.keysym.scancode == SDL_SCANCODE_ESCAPE && event->key.keysym.unused != SOHIOS_KEY_MAGIC) {
        // Arm first: both hop the same serial queue, so the buffered context
        // is flushed ahead of this line rather than racing it.
        SohIos_TraceArm();
        SohIos_Trace(@"DROPPED forged escape (%@) — a controller or the system sent Escape",
                     event->type == SDL_KEYDOWN ? @"down" : @"up");
        return 0; // consumed: the menu does not move
    }
    if (event->type == SDL_KEYDOWN) {
        SohIos_Trace(@"key down scancode=%d sym=%d%@", (int)event->key.keysym.scancode, (int)event->key.keysym.sym,
                     event->key.keysym.unused == SOHIOS_KEY_MAGIC ? @" (shell)" : @"");
    }
    // First few physical-pad presses only: enough to prove the pad's normal
    // path works, without tracing a whole play session.
    if (event->type == SDL_CONTROLLERBUTTONDOWN) {
        static int seen;
        if (seen++ < 24) {
            SohIos_Trace(@"pad button %d down (joystick %d)", (int)event->cbutton.button, (int)event->cbutton.which);
        }
    }
#if TARGET_OS_VISION
    // VR R3 (spec D12): the rear-view pane's HELD trigger. D-pad DOWN is
    // free during a race — MK64 reads D_JPAD in exactly one in-race place
    // (race_logic.c's lap-skip cheat) and only under gEnableDebugMode. Latched
    // here rather than polled from GCController for two reasons: this is the
    // one place that already sees every source of pad input, and it means the
    // bridge's own virtual pad drives the pane, so it is testable headless.
    // Observed, never consumed — the game still sees the button.
    if ((event->type == SDL_CONTROLLERBUTTONDOWN || event->type == SDL_CONTROLLERBUTTONUP) &&
        event->cbutton.button == SDL_CONTROLLER_BUTTON_DPAD_DOWN) {
        extern void SohVR_SetMirrorHold(int held);
        SohVR_SetMirrorHold(event->type == SDL_CONTROLLERBUTTONDOWN);
    }
#endif
    if (event->type == SDL_CONTROLLERDEVICEADDED) {
        SohIos_Trace(@"pad added: index %d", (int)event->cdevice.which);
    }
    return 1;
}

// The app's scene delegate. As of the iOS 27 SDK (D11, = Shipwright c8de40b)
// it is NAMED IN THE Info.plist scene manifest (overlay 0013) and UIKit
// instantiates it itself; +load below grafts the matching configuration hook
// onto SDL's app delegate, which is the other half the runtime insists on.
// SohIos_InstallSceneDelegate() still attaches it to any scene that arrived
// with delegate == nil, so a build against an older SDK behaves as before.
//
// Lifecycle: the scene callbacks below already carry all shell lifecycle work
// (config flush, background gate) and forward to SDL's app delegate (fwd:).
// SDL itself listens on NSNotificationCenter (SDL_uikitevents.m), and the
// UIApplication notifications still post under a scene life cycle, so nothing
// SDL needs is lost and nothing fires twice (SDLUIKitDelegate implements none
// of the application activation callbacks).
@interface SohIosSceneDelegate : NSObject <UIWindowSceneDelegate>
@end

// The scene UIKit connected us to, remembered the moment it arrives (before
// SDL_main has created any window).
static UIWindowScene* gSohConnectedScene = nil;

@implementation SohIosSceneDelegate
#if !TARGET_OS_VISION
// iOS 27 SDK gate: UIKit kills a UIKit app built against this SDK at launch
// (SIGTRAP in ___UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption)
// unless it adopts scenes, and it checks the APP DELEGATE for the scene-
// configuration hook -- the manifest alone is not enough. The app delegate is
// SDL2's SDLUIKitDelegate (fetched by LUS, not ours to fork), so graft the one
// method onto it at +load, long before UIApplicationMain. class_addMethod (not
// a category) keeps zero link dependency on SDL's class -- on visionOS that
// class is not even the app delegate.
static UISceneConfiguration* SohIos_SceneConfigForSession(id self, SEL _cmd, UIApplication* application,
                                                          UISceneSession* connectingSceneSession,
                                                          UISceneConnectionOptions* options) {
    UISceneConfiguration* cfg = [UISceneConfiguration configurationWithName:@"Default"
                                                               sessionRole:connectingSceneSession.role];
    cfg.delegateClass = SohIosSceneDelegate.class;
    cfg.sceneClass = UIWindowScene.class;
    return cfg;
}

+ (void)load {
    Class sdlDelegate = NSClassFromString(@"SDLUIKitDelegate");
    if (sdlDelegate == Nil) {
        NSLog(@"[SohIosShell] SDLUIKitDelegate not found; scene-config hook NOT installed");
        return;
    }
    SEL sel = @selector(application:configurationForConnectingSceneSession:options:);
    if ([sdlDelegate instancesRespondToSelector:sel]) {
        return; // SDL grew one; leave it alone
    }
    BOOL ok = class_addMethod(sdlDelegate, sel, (IMP)SohIos_SceneConfigForSession, "@@:@@@");
    NSLog(@"[SohIosShell] scene-config hook on SDLUIKitDelegate: %@", ok ? @"installed" : @"FAILED");
}
#endif

// First shell code that runs with a live scene. SDL's game window does not
// exist yet (SDL_main runs on a later run-loop turn), so remember the scene,
// attach any window that already exists (SDL's launch-screen window), and
// hand launch-time spaghetti:// URLs over once the engine is up.
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session
      options:(UISceneConnectionOptions*)connectionOptions {
    if ([scene isKindOfClass:UIWindowScene.class]) {
        UIWindowScene* ws = (UIWindowScene*)scene;
        gSohConnectedScene = ws;
        for (UIWindow* w in UIApplication.sharedApplication.windows) {
            if (w.windowScene == nil) {
                w.windowScene = ws;
            }
        }
        NSLog(@"[SohIosShell] scene connected (%@ windows adopted)", @(UIApplication.sharedApplication.windows.count));
    }
    for (UIOpenURLContext* ctx in connectionOptions.URLContexts) {
        NSString* u = ctx.URL.absoluteString;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{ SohIos_HandleDeepLink(u); });
    }
}
- (void)sceneDidDisconnect:(UIScene*)scene {
    if ((UIScene*)gSohConnectedScene == scene) {
        gSohConnectedScene = nil;
    }
}
- (void)scene:(UIScene*)scene openURLContexts:(NSSet<UIOpenURLContext*>*)URLContexts {
    for (UIOpenURLContext* ctx in URLContexts) {
        SohIos_HandleDeepLink(ctx.URL.absoluteString);
    }
}
- (void)fwd:(SEL)sel {
    id<UIApplicationDelegate> app = UIApplication.sharedApplication.delegate;
    if ([app respondsToSelector:sel]) {
        void (*imp)(id, SEL, UIApplication*) = (void*)[(id)app methodForSelector:sel];
        imp(app, sel, UIApplication.sharedApplication);
    }
}
- (void)sceneWillResignActive:(UIScene*)scene {
    SohIos_FlushConfig("sceneWillResignActive"); // swipe-kill safety
    [self fwd:@selector(applicationWillResignActive:)];
}
- (void)sceneDidEnterBackground:(UIScene*)scene {
    SohIos_FlushConfig("sceneDidEnterBackground");
    SohIos_SetBackgrounded(1); // gate Metal rendering (overlay 0016)
    [self fwd:@selector(applicationDidEnterBackground:)];
}
- (void)sceneWillEnterForeground:(UIScene*)scene {
    SohIos_SetBackgrounded(0);
    [self fwd:@selector(applicationWillEnterForeground:)];
}
- (void)sceneDidBecomeActive:(UIScene*)scene {
    SohIos_SetBackgrounded(0); // belt-and-braces on every activation path
    [self fwd:@selector(applicationDidBecomeActive:)];
}
- (NSUserActivity*)stateRestorationActivityForScene:(UIScene*)scene {
    return nil; // engine re-boots fresh each launch (predecessor lesson)
}
@end

static void SohIos_InstallSceneDelegate(void) {
    static SohIosSceneDelegate* gSceneDelegate = nil;
    if (gSceneDelegate == nil) {
        gSceneDelegate = [SohIosSceneDelegate new];
    }
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.delegate == nil) {
            scene.delegate = gSceneDelegate;
            NSLog(@"[SohIosShell] scene delegate installed on %@", scene);
        }
    }
}

#pragma mark - Touch control overlay (visual v1)

// A translucent overlay drawn over SDL's Metal layer showing the N64 control
// layout: a floating left analog stick and the right-hand button cluster
// (A, B, C-up/down/left/right, Z, R, Start). v1 renders the layout and logs
// touches; input injection (SDL virtual controller) lands in the next revision.
@interface SohIosTouchOverlay : UIView
// D15: drawing entry for the overlay's canvases (hotLabel nil: everything
// except the stick and the hot buttons; otherwise that one button only).
- (void)sohDrawCanvas:(UIView*)view hotLabel:(NSString*)hot;
@end

// D15 (perf rollout 2026-10-09, = Shipwright D-088): the overlay no longer
// draws itself. Its content is split so the frequent changes stop repainting
// a full-screen bitmap on the CPU inside the game thread's SDL event pump
// (LUS's SDLAddRemoveDeviceEventHandler pumps every frame, D13):
//   _stickView   the floating stick's ring + knob as two CAShapeLayers, moved
//                by `position` (no redraw at all while the thumb moves)
//   _canvas      full-size, everything else (buttons, customizer, restore dot)
//                -- redrawn only on layout / visibility / mode changes
//   hot canvases the MK64 hold-to-lock buttons A (gas) and Z (item), each in
//                its own small view, so a press/hold/lock repaints ~70 pt
// All are non-interactive subviews; touches still hit the overlay itself.
@interface SohIosOverlayCanvas : UIView
@property(nonatomic, weak) SohIosTouchOverlay* owner;
@property(nonatomic, copy) NSString* hotLabel;
@end

@implementation SohIosOverlayCanvas
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.contentMode = UIViewContentModeRedraw;
        self.userInteractionEnabled = NO;
    }
    return self;
}
- (void)drawRect:(CGRect)rect {
    [self.owner sohDrawCanvas:self hotLabel:self.hotLabel];
}
@end

typedef struct {
    CGPoint center;   // in this view's points
    CGFloat radius;
    UIColor* color;
    NSString* label;
} SohButton;

// CVar-safe key for a (possibly glyph) button label. Defined with the layout
// customizer below; forward-declared here for the hidden-button helpers.
static NSString* SohIos_LayoutKey(NSString* label);

@implementation SohIosTouchOverlay {
    CGPoint _stickBase;   // set where the finger lands (floating stick)
    CGFloat _stickBaseR;  // full-deflection travel (v2: 54 = old 90 * 0.6)
    CGFloat _stickKnobR;  // knob radius (v2: 34 = old 42 * 0.8)
    CGPoint _stickKnob;   // current knob position
    BOOL _stickActive;
    UITouch* __unsafe_unretained _stickTouch;         // identity only, never dereferenced after end
    BOOL _stickSynth;     // D15: the stick is held by the bridge's synthetic finger
    NSMutableDictionary<NSValue*, NSNumber*>* _touchButtons; // UITouch ptr -> button index
    BOOL _controlsHidden; // while the SoH menu is open: only the restore dot is active
    BOOL _zHeld;          // finger currently on Z (momentary hold)
    BOOL _zLocked;        // double-tap lock engaged (stays held, bright visual)
    CFTimeInterval _zLastTapTime; // for the double-tap window (unused here: MK64 locks by HOLD)
    BOOL _aHeld;          // MK64: finger on A (gas)
    BOOL _aLocked;        // MK64: hold-to-lock engaged on gas
    BOOL _bHeld;          // MK64: brake held (overrides locked gas)
    unsigned _aLockSeq;   // MK64: hold-timer invalidation
    unsigned _zLockSeq;
    Sint16 _lastSentLX, _lastSentLY; // stick-axis coalescing (audio-hitch fix)
    BOOL _controllerMode; // physical controller connected: touch controls hidden
    BOOL _popupOpen;      // any ImGui popup: overlay invisible + fully pass-through
    BOOL _lastMenuBtnVisible; // repaint trigger for pause/title transitions
    UILabel* _perfHud;        // optional fps/thermal readout (gSohIos.PerfHud)
    // Menu touch-router (menu open: overlay owns ALL touches and forwards
    // synthesized mouse events — device feedback: raw drags read as hover +
    // no scrolling): 0=undecided 1=scroll 2=drag 3=hover
    UITouch* __unsafe_unretained _routerTouch;
    int _routerMode;
    CGPoint _routerStart, _routerLast;
    // Layout customizer
    BOOL _editMode;
    NSMutableDictionary<NSString*, NSValue*>* _layoutOverrides; // label -> normalized center
    NSMutableSet<NSString*>* _layoutHidden; // layout keys the user hid from the touch layer
    CGFloat _layoutScale;
    CGPoint _stickHome;   // normalized; CGPointZero = default
    NSString* _editDrag;  // label being dragged, @"__stick", @"__slider", or nil
    NSString* _editSelected; // layout key of the last-touched button: the ONLY
                             // one showing an eye chip in the customizer (nil = none)
    // D15: layered drawing (see SohIosOverlayCanvas).
    UIView* _stickView;
    CAShapeLayer* _ringLayer;
    CAShapeLayer* _knobLayer;
    CGFloat _ringLayerR, _knobLayerR;
    SohIosOverlayCanvas* _canvas;
    NSArray<SohIosOverlayCanvas*>* _hotCanvases; // A, Z
}

- (CGPoint)restoreDotCenter {
    // Top-center, matching the ≡ button's home (START owns bottom-center now).
    return CGPointMake(CGRectGetMidX(self.bounds), self.bounds.origin.y + 55);
}

// The ≡ menu button shows only where menu access makes sense: intro/title/
// file-select (users tune settings at the start) and the game's pause menu.
// Hidden during normal gameplay for BOTH touch and controller input -- unless
// the user turned on "Always Show Menu Button" (gSohIos.MenuAlwaysVisible,
// 0023; DECISIONS.md D10 = reference D-083). Every draw/hit-test path (touch +
// controller mode) goes through here, and syncWithMenuState repaints on a
// change, so the toggle is live with no other edit.
- (BOOL)menuButtonVisible {
    if (CVarGetInteger("gSohIos.MenuAlwaysVisible", 0)) {
        return YES;
    }
    return SohIos_IsGamePaused() || SohIos_IsTitleOrDemo();
}

// A user-hidden button never draws, never intercepts a touch, and never
// gates the floating stick (see hitButton/drawRect/pointInStickRegion). The
// ≡ menu button is EXEMPT — it's the only touch path into the port's menu
// for a controller-less user, so it can never be hidden (a stale MENU.hidden
// CVar is ignored here rather than trusted).
- (BOOL)isButtonHidden:(NSString*)label {
    if ([label isEqualToString:@"≡"]) {
        return NO;
    }
    return [_layoutHidden containsObject:SohIos_LayoutKey(label)];
}

// Toggle from the customizer's per-button eye badge. Returns the new hidden
// state. ≡ can't be hidden. Live: takes effect the moment the customizer
// exits (drawRect/hitButton read _layoutHidden directly); persisted on save.
- (BOOL)toggleHiddenForLabel:(NSString*)label {
    if ([label isEqualToString:@"≡"]) {
        return NO;
    }
    NSString* key = SohIos_LayoutKey(label);
    BOOL nowHidden = ![_layoutHidden containsObject:key];
    if (nowHidden) {
        [_layoutHidden addObject:key];
    } else {
        [_layoutHidden removeObject:key];
    }
    [self setNeedsDisplay];
    return nowHidden;
}

- (CGPoint)zButtonCenter {
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    for (int i = 0; i < n; i++) {
        if ([btns[i].label isEqualToString:@"Z"]) {
            return btns[i].center;
        }
    }
    return CGPointMake(-1000, -1000);
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        // Without Redraw, a window resize stretches the cached bitmap and the
        // controls render squished until the next repaint (visionOS resize).
        self.contentMode = UIViewContentModeRedraw;
        self.multipleTouchEnabled = YES;
        self.userInteractionEnabled = YES;
        _stickBaseR = 54.0; // -40% travel vs v1 (device feel feedback)
        _stickKnobR = 34.0; // -20% knob vs v1
        _touchButtons = [NSMutableDictionary dictionary];
        _layoutOverrides = [NSMutableDictionary dictionary];
        _layoutHidden = [NSMutableSet set];
        _layoutScale = 1.0;
        _stickHome = CGPointZero; // zero = default position
        // D15: stick layers below the button canvas (buttons drew over the
        // stick in the old single drawRect), hot-button canvases on top.
        _stickView = [[UIView alloc] initWithFrame:self.bounds];
        _stickView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _stickView.userInteractionEnabled = NO;
        _stickView.backgroundColor = UIColor.clearColor;
        _ringLayer = [CAShapeLayer layer];
        _ringLayer.fillColor = nil;
        _ringLayer.strokeColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        _ringLayer.lineWidth = 4;
        _ringLayer.hidden = YES;
        _knobLayer = [CAShapeLayer layer];
        _knobLayer.fillColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
        _knobLayer.strokeColor = nil;
        _knobLayer.hidden = YES;
        [_stickView.layer addSublayer:_ringLayer];
        [_stickView.layer addSublayer:_knobLayer];
        [self addSubview:_stickView];
        _canvas = [[SohIosOverlayCanvas alloc] initWithFrame:self.bounds];
        _canvas.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _canvas.owner = self;
        [self addSubview:_canvas];
        NSMutableArray* hot = [NSMutableArray array];
        for (NSString* l in @[ @"A", @"Z" ]) {
            SohIosOverlayCanvas* c = [[SohIosOverlayCanvas alloc] initWithFrame:CGRectZero];
            c.owner = self;
            c.hotLabel = l;
            [self addSubview:c];
            [hot addObject:c];
        }
        _hotCanvases = hot;
        [self loadLayoutFromCVars];
        // EditLayout is a transient trigger, not a setting: a stale persisted
        // 1 (e.g. saved by a config flush mid-edit) must never relaunch the
        // app straight into the customizer.
        CVarSetInteger("gSohIos.EditLayout", 0);
        // The game's menu state (overlay 0013) is authoritative for hiding:
        // it catches every way the menu opens/closes (esc key, deep link,
        // the menu's own X button), not just this overlay's ≡ button.
        __weak SohIosTouchOverlay* weakSelf = self;
        [NSTimer scheduledTimerWithTimeInterval:0.25
                                        repeats:YES
                                          block:^(NSTimer* t) { [weakSelf syncWithMenuState]; }];
    }
    return self;
}

// Physical controller (Backbone etc.) present -> touch controls yield.
// SDL creates no GCController for the virtual touch pad (verified: this
// SDL2 has no GCVirtualController path), but the SIMULATOR synthesizes a
// generic keyboard-passthrough pad named exactly "Gamepad" — real hardware
// reports its brand ("Backbone One", "DualSense", ...). Filter the generic
// name; connects are logged so device runs self-document any mismatch.
static BOOL SohIos_PhysicalControllerPresent(void) {
    // visionOS included: with no pad paired, show the touch controls —
    // pinch-taps make them usable enough to navigate menus (user request).
    // Real pads enumerate normally on the headset; the "Gamepad" filter
    // below handles the simulator's synthetic entry.
    for (GCController* c in GCController.controllers) {
#if TARGET_OS_VISION
        // VR R16-D — THIS REVERSES R4, DELIBERATELY, ON THE USER'S REPORT.
        //
        // R4 (donor trap 29) said a PSVR2 Sense half is NOT "a physical
        // controller" for this predicate: it is filtered out of SDL and driven
        // by the native fixed layout, and counting it would have hidden the
        // touch controls in FLAT mode for a pair merely paired and sitting on
        // the desk. That `continue` was unconditional — every mode, every time.
        // But the native layout did not run in flat mode either, so the pair
        // that "was not a controller" was also not producing input, and the user's
        // 1.0.0.12 report is both halves of that at once: "the touch controls
        // are on screen, which means it thinks no controller is attached."
        //
        // Now that the flat fold drives the pair in every mode, the pair IS a
        // physical controller and the touch pad must yield to it, exactly as it
        // yields to a Backbone. The skip survives only for the case R4 was
        // really protecting: a spatial controller the fold is NOT driving.
        // SohSense_FlatFoldLive() rather than SohSense_Active(), because Active()
        // counts injected hands and stays 1 after a VR session.
        //
        // The consequence R4 feared is now the requested behaviour: a paired
        // pair on the desk hides the on-screen pad. The ≡ menu button's own
        // visibility logic is unchanged, so the menu stays reachable.
        extern int SohSense_IsSpatialController(void* gcController);
        extern int SohSense_FlatFoldLive(void);
        if (SohSense_IsSpatialController((__bridge void*)c) && !SohSense_FlatFoldLive()) {
            continue;
        }
#endif
        if (![(c.vendorName ?: @"") isEqualToString:@"Gamepad"]) {
            return YES;
        }
    }
    return NO;
}

// VR R16-D: the predicate, reachable from the console bridge (`vr pad`). It is
// static and it is polled from a timer, so without this the only evidence of its
// decision was a log line on CHANGE — which is exactly the shape of assert trap
// D11 (proving something by not seeing it). C linkage, one call, no side effects.
int SohIos_ControllerPresentProbe(void) {
    return SohIos_PhysicalControllerPresent() ? 1 : 0;
}

// ... and the inventory it walked, so a device log says WHY it decided that.
const char* SohIos_ControllerInventory(void) {
    static char line[512];
    NSMutableString* s = [NSMutableString string];
    for (GCController* c in GCController.controllers) {
        [s appendFormat:@"%@'%@'/'%@'", s.length ? @"," : @"", c.vendorName ?: @"?", c.productCategory ?: @"?"];
    }
    snprintf(line, sizeof(line), "%s", s.length ? s.UTF8String : "(none)");
    return line;
}

#include <mach/mach.h>
// D8: process physical footprint in MB — the metric jetsam kills on.
// Exported (C linkage) for the 0014 perf line's mem_mb field.
int SohIos_MemFootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        return (int)(info.phys_footprint / (1024 * 1024));
    }
    return -1;
}

// Haptic feedback on touch buttons (gSohIos.Haptics: 0 off, 1 light, 2 strong)
#if TARGET_OS_VISION
// Render Scale (Settings->iOS): consumed by the SDL metal view's drawable
// sizing. Polled below; defaults to full 3840.
volatile float gSohIosVisionLongEdge = 3840.0f;
float SohIos_VisionLongEdge(void) {
    return gSohIosVisionLongEdge;
}
#endif

// Recursive: SDL nests its metal view inside its own view hierarchy.
UIView* SohIos_FindMetalViewIn(UIView* v) {
    if ([v.layer isKindOfClass:NSClassFromString(@"CAMetalLayer")]) {
        return v;
    }
    for (UIView* c in v.subviews) {
        UIView* r = SohIos_FindMetalViewIn(c);
        if (r != nil) {
            return r;
        }
    }
    return nil;
}
// Immediately size the game window to its scene and give it the system
// window treatment (visionOS windows are continuously rounded; a raw
// UIWindow over the SwiftUI hosting window shows square corners otherwise).
// Idempotent — called at every attach point and from the self-heal.
void SohIos_GlueWindowToScene(UIWindow* w, UIWindowScene* scene) {
    if (w == nil || scene == nil) {
        return;
    }
#if TARGET_OS_VISION
    w.layer.cornerRadius = 46.0;
    w.layer.cornerCurve = kCACornerCurveContinuous;
    w.layer.masksToBounds = YES;
#endif
    CGRect sb = scene.coordinateSpace.bounds;
    if (sb.size.width > 1 && !CGRectEqualToRect(w.frame, sb)) {
        w.frame = sb;
        [w setNeedsLayout];
        [w layoutIfNeeded];
    }
}

// Deterministic post-3D restore (device rounds 10-12: detection-based heals
// kept missing it): find the game window, glue to scene, and force the SDL
// view chain — every level, SDL sets child frames explicitly — to re-adopt.
void SohIos_ForceViewChainAdopt(void) {
    for (UIWindow* w in UIApplication.sharedApplication.windows) {
        UIView* mv = SohIos_FindMetalView(w);
        if (mv == nil) {
            continue;
        }
        UIWindowScene* scene = w.windowScene;
        if (scene != nil) {
            SohIos_GlueWindowToScene(w, scene);
        }
        for (UIView* v = mv; v != nil && v != (UIView*)w; v = v.superview) {
            v.frame = w.bounds;
        }
        UIView* root = w.rootViewController.view;
        [root setNeedsLayout];
        [root layoutIfNeeded];
        NSLog(@"[SohIosShell] forced view-chain adopt (window %.0fx%.0f)",
              w.bounds.size.width, w.bounds.size.height);
        return;
    }
}

UIView* SohIos_FindMetalView(UIWindow* w) {
    return w ? SohIos_FindMetalViewIn(w) : nil;
}

// The window that actually hosts the SDL metal view (the touch overlay can
// live elsewhere; every geometry decision below keys off this one).
static UIWindow* SohIos_GameWindowWithMetal(UIView** outMv) {
    for (UIWindow* w in UIApplication.sharedApplication.windows) {
        UIView* mv = SohIos_FindMetalView(w);
        if (mv != nil) {
            if (outMv != NULL) {
                *outMv = mv;
            }
            return w;
        }
    }
    if (outMv != NULL) {
        *outMv = nil;
    }
    return nil;
}

// SSAA hooks for overlay 0036 (Ghostship cross-port adoption). SoH is a
// HEAVY port (HD packs already needed GPU optimization): no device-tier
// auto-default — unset reads as 1.0 (native; already a big step up from the
// sub-native render this fixes). The settings slider (1.0-2.0) always wins.
float SohIos_SsaaFactor(void) {
#if TARGET_OS_VISION
    // D-V3 (playbook §1.4a): ssaa pinned 1.0 on Vision Pro — the 3840
    // long-edge drawable already renders ~2x the panel's angular
    // resolution of the window; above 1.0 is GPU spend with no visible
    // gain. No slider on VP (0023 shows a truth line instead).
    return 1.0f;
#else
    float f = CVarGetFloat("gSohIos.Supersample", 0.0f);
    if (f <= 0.0f) {
        f = 2.0f; // D11: light-port default (reference: 1.0)
    }
    if (f < 1.0f) {
        f = 1.0f;
    }
    if (f > 2.0f) {
        f = 2.0f;
    }
    return f;
#endif
}

// Native pixel width of the game window's drawable — already tracked each
// overlay tick into gSohIosDrawableW by syncWithMenuState (render-thread
// callers just read the cached global; 0 until the layer is sized, which the
// interpreter treats as "no SSAA yet").
uint32_t SohIos_DrawablePixelWidth(void) {
    float w = gSohIosDrawableW, h = gSohIosDrawableH; // file-scope statics, tick-updated
    return (uint32_t)(w > h ? w : h); // long edge = width (landscape-locked)
}

// 3D perf HUD text (overlay 0034 draws it into the eye frames): the 2D HUD is
// a UIKit label on the parked window, invisible on the panel. Same format as
// the label. Returns -1 when the HUD option is off, else thermal state.
int SohIos_PerfHud3DText(char* buf, int cap) {
    if (buf == NULL || cap < 8) {
        return -1;
    }
    buf[0] = 0;
    if (!CVarGetInteger("gSohIos.PerfHud", 0)) {
        return -1;
    }
    float fps = 0;
    SohIos_HudStats(&fps);
    int th = SohIos_ThermalState();
    // ASCII only: ImGui's font atlas has no U+2022 (renders '?', device
    // round 14).
    if (th >= 2) {
        snprintf(buf, cap, "%.0f - HOT", fps);
    } else if (th == 1) {
        snprintf(buf, cap, "%.0f - warm", fps);
    } else {
        snprintf(buf, cap, "%.0f", fps);
    }
    return th;
}

// ---- 3D-exit deterministic restore (device round 13: content rendered
// LARGER than the restored window — the blind timed adopts can glue a
// mid-animation or stale size, and SDL's resize debounce can eat the final
// event so the engine keeps rendering the stale size 1:1, top-left cropped).
// The predecessor ports' pattern instead: restore to the EXACT size captured
// before entering 3D, verify the engine adopted it, and escalate with a real
// bounds change if the resize event was lost. `geom` reports every layer.
static CGSize soh_restoreTarget = { 0, 0 };
static int soh_restoreTicks = 0;
static NSTimer* soh_restoreTimer = nil;
static const char* soh_restoreState = "idle";

static void SohIos_RestoreTick(void) {
    soh_restoreTicks++;
    UIView* mv = nil;
    UIWindow* w = SohIos_GameWindowWithMetal(&mv);
    if (w == nil) {
        soh_restoreState = "no-window";
        if (soh_restoreTicks > 24) {
            [soh_restoreTimer invalidate];
            soh_restoreTimer = nil;
        }
        return;
    }
    UIWindowScene* scene = w.windowScene;
    CGSize sb = scene ? scene.coordinateSpace.bounds.size : CGSizeZero;
    CGSize goal = (soh_restoreTarget.width >= 1) ? soh_restoreTarget : sb;
    BOOL sceneAtGoal = sb.width > 1 && fabs(sb.width - goal.width) <= 2 && fabs(sb.height - goal.height) <= 2;
    if (!sceneAtGoal && soh_restoreTicks < 16) {
        // Re-ask (the first request can race the immersive dismissal); wait
        // for the scene animation to land before touching the view chain.
        if (soh_restoreTicks == 1 || soh_restoreTicks == 8) {
#if TARGET_OS_VISION /* host VC (and scene geometry requests) exist only there */
            extern void Soh_RequestWindowSize(CGSize size);
            Soh_RequestWindowSize(goal);
#endif
        }
        soh_restoreState = "waiting-scene";
        NSLog(@"[SohIosShell] restore tick %d: scene %.0fx%.0f != goal %.0fx%.0f — waiting",
              soh_restoreTicks, sb.width, sb.height, goal.width, goal.height);
        return;
    }
    // Past the wait budget the system evidently won't grant the captured
    // size — adopt the settled scene instead (internal consistency is what
    // prevents the crop; exact size is best-effort on top).
    SohIos_GlueWindowToScene(w, scene);
    for (UIView* v = mv; v != nil && v != (UIView*)w; v = v.superview) {
        v.frame = w.bounds;
    }
    [w.rootViewController.view setNeedsLayout];
    [w.rootViewController.view layoutIfNeeded];
    // Did SDL actually adopt? Engine dims (points) must match the view.
    CGSize vb = mv.bounds.size;
    BOOL engineOk = gSoh3DDbg2DW > 0 && vb.width > 1 &&
                    fabs((float)gSoh3DDbg2DW - vb.width) <= vb.width * 0.02f &&
                    fabs((float)gSoh3DDbg2DH - vb.height) <= vb.height * 0.02f;
    if (engineOk) {
        soh_restoreState = "done";
        NSLog(@"[SohIosShell] restore done in %d ticks: win %.0fx%.0f engine %dx%d",
              soh_restoreTicks, w.bounds.size.width, w.bounds.size.height, gSoh3DDbg2DW, gSoh3DDbg2DH);
        [soh_restoreTimer invalidate];
        soh_restoreTimer = nil;
        return;
    }
    soh_restoreState = "engine-stale";
    if (soh_restoreTicks >= 4 && (soh_restoreTicks % 2) == 0) {
        // SDL's debounce ate the resize: force a REAL bounds change (−1pt,
        // layout, back) so the final size definitely reaches the engine.
        NSLog(@"[SohIosShell] restore tick %d: engine %dx%d != view %.0fx%.0f — jiggling",
              soh_restoreTicks, gSoh3DDbg2DW, gSoh3DDbg2DH, vb.width, vb.height);
        mv.frame = CGRectMake(0, 0, w.bounds.size.width - 1, w.bounds.size.height - 1);
        [mv setNeedsLayout];
        [mv layoutIfNeeded];
        mv.frame = CGRectMake(0, 0, w.bounds.size.width, w.bounds.size.height);
        [mv setNeedsLayout];
        [mv layoutIfNeeded];
    }
    if (soh_restoreTicks > 24) {
        NSLog(@"[SohIosShell] restore GAVE UP: scene %.0fx%.0f win %.0fx%.0f view %.0fx%.0f engine %dx%d",
              sb.width, sb.height, w.bounds.size.width, w.bounds.size.height, vb.width, vb.height,
              gSoh3DDbg2DW, gSoh3DDbg2DH);
        soh_restoreState = "gave-up";
        [soh_restoreTimer invalidate];
        soh_restoreTimer = nil;
    }
}

// Full geometry snapshot for the bridge `geom` command. MAIN THREAD ONLY.
int SohIos_GeomReport(char* buf, int cap) {
    UIView* mv = nil;
    UIWindow* w = SohIos_GameWindowWithMetal(&mv);
    if (w == nil) {
        snprintf(buf, cap, "no game window");
        return 0;
    }
    UIWindowScene* scene = w.windowScene;
    CGRect sb = scene ? scene.coordinateSpace.bounds : CGRectZero;
    CGRect wf = w.frame;
    CGRect mf = mv != nil ? mv.frame : CGRectZero;
    CGSize ds = mv != nil ? ((CAMetalLayer*)mv.layer).drawableSize : CGSizeZero;
    CGFloat cs = mv != nil ? mv.layer.contentsScale : 0;
    snprintf(buf, cap,
             "restore=%s ticks=%d target=%.0fx%.0f scene=%.0fx%.0f win=%.0f,%.0f+%.0fx%.0f "
             "mv=%.0f,%.0f+%.0fx%.0f drawable=%.0fx%.0f scale=%.2f engine2d=%dx%d mode3d=%d",
             soh_restoreState, soh_restoreTicks, soh_restoreTarget.width, soh_restoreTarget.height,
             sb.size.width, sb.size.height, wf.origin.x, wf.origin.y, wf.size.width, wf.size.height,
             mf.origin.x, mf.origin.y, mf.size.width, mf.size.height, ds.width, ds.height, (float)cs,
             gSoh3DDbg2DW, gSoh3DDbg2DH, gSoh3DMode);
    return 1;
}

// Entry must cancel any mid-flight restore (or the timer fights the 480x320
// parking), and can inherit its target as the true pre-3D size (a quick
// re-enter would otherwise capture the half-restored transient).
CGSize SohIos_RestorePendingTarget(void) {
    return (soh_restoreTimer != nil) ? soh_restoreTarget : CGSizeZero;
}

void SohIos_RestoreCancel(void) {
    if (soh_restoreTimer != nil) {
        [soh_restoreTimer invalidate];
        soh_restoreTimer = nil;
        soh_restoreState = "cancelled";
        NSLog(@"[SohIosShell] restore cancelled (3D re-entry)");
    }
}

void SohIos_RestoreWindowTo(CGSize target) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SohIos_RestoreWindowTo(target); });
        return;
    }
    soh_restoreTarget = target;
    soh_restoreTicks = 0;
    soh_restoreState = "running";
    [soh_restoreTimer invalidate];
    soh_restoreTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                       repeats:YES
                                                         block:^(NSTimer* t) { SohIos_RestoreTick(); }];
    NSLog(@"[SohIosShell] restore controller started, target %.0fx%.0f", target.width, target.height);
}

- (void)hapticTap {
#if !TARGET_OS_VISION /* no haptic hardware on Vision Pro */
    int mode = CVarGetInteger("gSohIos.Haptics", 1);
    if (mode <= 0) {
        return;
    }
    UIImpactFeedbackStyle style = (mode >= 2) ? UIImpactFeedbackStyleMedium : UIImpactFeedbackStyleLight;
    UIImpactFeedbackGenerator* gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [gen impactOccurred];
#endif
}

- (void)syncWithMenuState {
    {
        UIView* mv = SohIos_FindMetalView(self.window);
        if (mv != nil) {
            CGSize ds = ((CAMetalLayer*)mv.layer).drawableSize;
            gSohIosDrawableW = ds.width;
            gSohIosDrawableH = ds.height;
            gSohIosContentsScale = mv.layer.contentsScale;
        }
    }
#if TARGET_OS_VISION
    {
        // Self-healing drawable: the SDL metal view's resize DEBOUNCE can lose
        // the final edge (observed at first open under the SwiftUI entry: the
        // scene grows during boot and the drawable stays at the boot size —
        // content fills only part of the window until a manual resize). If the
        // actual drawable disagrees with what the current bounds demand for
        // two consecutive ticks (0.5 s > the 0.3 s debounce), re-derive.
        UIView* mv = SohIos_FindMetalView(self.window);
        if (mv != nil && gSoh3DMode == 0) {
            static int sohMismatchTicks = 0;
            // LAYER 1 (the reproduced fill bug, telemetry engine2d=480x320 vs
            // full drawable): the WINDOW can stay at a stale size while the
            // SCENE has grown (boot growth, 3D-exit restore) — the layout
            // chain that feeds SDL its new size never fires because UIKit
            // thinks nothing changed. Re-glue window to scene on mismatch.
            UIWindowScene* scene = self.window.windowScene;
            if (scene != nil) {
                CGSize sb = scene.coordinateSpace.bounds.size;
                CGSize wb = self.window.bounds.size;
                if (sb.width > 1 &&
                    (fabs(sb.width - wb.width) > 2 || fabs(sb.height - wb.height) > 2)) {
                    NSLog(@"[SohIosShell] window %.0fx%.0f != scene %.0fx%.0f — re-gluing",
                          wb.width, wb.height, sb.width, sb.height);
                }
                SohIos_GlueWindowToScene(self.window, scene);
            }
            // LAYER 3 (device round 10): the METAL VIEW itself can stay at the
            // parked size inside a restored window — then engine2d == view
            // bounds and layer 2 sees no mismatch. View-vs-window is the
            // missing comparison; force the SDL hierarchy to re-adopt.
            {
                CGSize vb2 = mv.bounds.size;
                CGSize wb2 = self.window.bounds.size;
                if (wb2.width > 1 && (fabs(vb2.width - wb2.width) > wb2.width * 0.02f ||
                                      fabs(vb2.height - wb2.height) > wb2.height * 0.02f)) {
                    static int sohViewStaleTicks = 0;
                    if (++sohViewStaleTicks >= 2) {
                        sohViewStaleTicks = 0;
                        NSLog(@"[SohIosShell] metal view %.0fx%.0f != window %.0fx%.0f — re-adopting chain",
                              vb2.width, vb2.height, wb2.width, wb2.height);
                        // Force EVERY level: SDL sets child frames explicitly (no
                        // autoresizing), so nudging layout alone leaves the metal
                        // view parked; and SDL re-learns its size from the VC
                        // view's bounds — set the whole ancestor chain, then let
                        // viewDidLayoutSubviews report the corrected size to SDL.
                        for (UIView* v = mv; v != nil && v != (UIView*)self.window; v = v.superview) {
                            v.frame = self.window.bounds;
                        }
                        UIView* root = self.window.rootViewController.view;
                        [root setNeedsLayout];
                        [root layoutIfNeeded];
                    }
                }
            }
            // LAYER 2: SDL's cached size (engine2d telemetry) vs the view —
            // a lost resize event leaves the engine rendering a sub-rect.
            {
                CGSize vb = mv.bounds.size;
                if (gSoh3DDbg2DW > 0 && vb.width > 1 &&
                    (fabs((float)gSoh3DDbg2DW - vb.width) > vb.width * 0.02f ||
                     fabs((float)gSoh3DDbg2DH - vb.height) > vb.height * 0.02f)) {
                    static int sohSdlStaleTicks = 0;
                    if (++sohSdlStaleTicks >= 3) {
                        sohSdlStaleTicks = 0;
                        NSLog(@"[SohIosShell] engine dims %dx%d != view %.0fx%.0f — re-kicking layout chain",
                              gSoh3DDbg2DW, gSoh3DDbg2DH, vb.width, vb.height);
                        [self.window.rootViewController.view setNeedsLayout];
                        [self.window.rootViewController.view layoutIfNeeded];
                        [mv setNeedsLayout];
                        [mv layoutIfNeeded];
                    }
                }
            }
            // D-V7 (VP device: black window after live resize, audio alive):
            // the engine's drawable acquire is failing repeatedly — geometry
            // checks can all pass while CAMetalLayer is wedged (nil drawables
            // until drawableSize is REWRITTEN). Hard-reset the layer config
            // from current bounds; recovery is then autonomous (~1 s) instead
            // of waiting for the user to nudge the window.
            if (gSohIosDrawableFailStreak >= 2) {
                CGSize hb = mv.bounds.size;
                if (hb.width > 1 && hb.height > 1) {
                    CAMetalLayer* hl = (CAMetalLayer*)mv.layer;
                    float healTarget = (float)CVarGetInteger("gSohIos.VisionLongEdge", 3840);
                    float healLong = MAX(hb.width, hb.height);
                    float healScale = (healTarget > 0 && healLong > 1) ? healTarget / healLong : 2.0f;
                    NSLog(@"[SohIosShell] drawable acquire wedged (streak=%d) — hard-resetting layer "
                          @"(bounds %.0fx%.0f scale %.2f)",
                          gSohIosDrawableFailStreak, hb.width, hb.height, healScale);
                    hl.contentsScale = healScale;
                    hl.drawableSize = CGSizeMake(hb.width * healScale, hb.height * healScale);
                    gSohIosDrawableFailStreak = 0;
                    [mv setNeedsLayout];
                    [mv layoutIfNeeded];
                }
            }
            CGSize b = mv.bounds.size;
            CGSize d = ((CAMetalLayer*)mv.layer).drawableSize;
            float targetLong = (float)CVarGetInteger("gSohIos.VisionLongEdge", 3840);
            float boundsLong = MAX(b.width, b.height);
            float expectLong = MAX(targetLong, boundsLong);
            float actualLong = MAX(d.width, d.height);
            float bAspect = (b.height > 1) ? b.width / b.height : 0;
            float dAspect = (d.height > 1) ? d.width / d.height : 0;
            BOOL sizeOff = fabsf(actualLong - expectLong) > expectLong * 0.02f;
            BOOL aspectOff = (bAspect > 0 && dAspect > 0) && fabsf(dAspect - bAspect) > bAspect * 0.02f;
            if (boundsLong > 1 && (sizeOff || aspectOff)) {
                if (++sohMismatchTicks >= 2) {
                    sohMismatchTicks = 0;
                    NSLog(@"[SohIosShell] drawable mismatch (have %.0fx%.0f, bounds %.0fx%.0f, want long %.0f) — re-deriving",
                          d.width, d.height, b.width, b.height, expectLong);
                    [mv setNeedsLayout];
                    [mv layoutIfNeeded];
                }
            } else {
                sohMismatchTicks = 0;
            }
        }
    }
    {
        float target = (float)CVarGetInteger("gSohIos.VisionLongEdge", 3840);
        if (target != gSohIosVisionLongEdge) {
            gSohIosVisionLongEdge = target;
            // The SDL metal view only re-derives drawableSize in
            // layoutSubviews — poke it so Render Scale applies live.
            UIView* mv = SohIos_FindMetalView(self.window);
            if (mv != nil) {
                [mv setNeedsLayout];
                [mv layoutIfNeeded];
                NSLog(@"[SohIosShell] render scale -> %.0f (drawable re-derive poked)", target);
            } else {
                NSLog(@"[SohIosShell] render scale -> %.0f (METAL VIEW NOT FOUND)", target);
            }
        }
    }
#endif
    // Customizer entry: the ImGui button (0017) sets this CVar; we consume
    // it, close the menu, and enter edit mode (even with a gamepad).
    if (CVarGetInteger("gSohIos.EditLayout", 0)) {
        CVarSetInteger("gSohIos.EditLayout", 0);
        if (SohIos_IsMenuOpen()) {
            SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE);
        }
        _editMode = YES;
        _editSelected = nil; // no eye chips until the user touches a button
        _controlsHidden = NO;
        [self releaseAllControls];
        [self setNeedsDisplay];
        NSLog(@"[SohIosShell] layout customizer entered");
        return;
    }
    if (_editMode) {
        return; // customizer owns the screen; skip hide/show logic
    }
    BOOL open = SohIos_IsMenuOpen() != 0;
    BOOL controller = SohIos_PhysicalControllerPresent();
    BOOL popup = SohIos_IsPopupOpen() != 0;
    BOOL changed = NO;
    // ≡ visibility follows pause/title state (device bug: the button was
    // hit-testable before it was drawn, and lingered after unpause, because
    // nothing repainted on those transitions).
    BOOL menuBtn = [self menuButtonVisible];
    if (menuBtn != _lastMenuBtnVisible) {
        _lastMenuBtnVisible = menuBtn;
        changed = YES;
    }
    if (popup != _popupOpen) {
        _popupOpen = popup;
        if (popup) {
            [self releaseAllControls];
        }
        changed = YES;
    }
    if (controller != _controllerMode) {
        _controllerMode = controller;
        [self releaseAllControls];
        changed = YES;
        // R16-D: the CATEGORY too, not just the vendor name. On device this is
        // the first place the real spatial-controller strings show up outside
        // VR, and it is what says whether the flat fold or the "Gamepad" filter
        // made the decision.
        NSLog(@"[SohIosShell] controller mode %@ (controllers: %s)",
              controller ? @"ON (touch hidden)" : @"OFF (touch active)", SohIos_ControllerInventory());
    }
    if (open != _controlsHidden) {
        _controlsHidden = open;
        if (open) {
            [self releaseAllControls]; // no stuck buttons/stick while hidden
        }
        changed = YES;
    }
    if (changed) {
        // D15 (= Shipwright D-088): controller mode used to repaint the full
        // screen every 0.25 s poll so ≡ could follow pause; _lastMenuBtnVisible
        // (above) now flags exactly that change, in both modes.
        [self setNeedsDisplay];
    }
    // Touch-control opacity (edit mode and open menu stay fully opaque).
    CGFloat opacity = CVarGetFloat("gSohIos.TouchOpacity", 1.0f);
    self.alpha = (_editMode || _controlsHidden) ? 1.0 : MAX(0.25, MIN(1.0, opacity));
    // Remote console toggle: start the bridge on demand (idempotent).
    if (CVarGetInteger("gSohIos.RemoteConsole", 0)) {
        SohIos_StartConsoleBridge(YES);
    }
    // Perf HUD (fps + thermal from the 0008 probe).
    if (CVarGetInteger("gSohIos.PerfHud", 0)) {
        if (_perfHud == nil) {
            // Inset from the corner: the rounded bezel + landscape safe area
            // clipped the thermal suffix ("• warm/HOT") at the old x.
            _perfHud = [[UILabel alloc] initWithFrame:CGRectMake(self.bounds.size.width - 190, 10, 150, 16)];
            _perfHud.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold];
            _perfHud.textColor = [UIColor colorWithWhite:1 alpha:0.85];
            _perfHud.textAlignment = NSTextAlignmentRight;
            _perfHud.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            [self addSubview:_perfHud];
        }
        _perfHud.hidden = NO;
        float fps = 0;
        SohIos_HudStats(&fps);
        // Just the number (user feedback); thermal only when it matters.
        int th = SohIos_ThermalState();
        if (th >= 2) {
            _perfHud.text = [NSString stringWithFormat:@"%.0f \u2022 HOT", fps];
            _perfHud.textColor = [UIColor colorWithRed:1 green:0.4 blue:0.3 alpha:0.95];
        } else if (th == 1) {
            _perfHud.text = [NSString stringWithFormat:@"%.0f \u2022 warm", fps];
            _perfHud.textColor = [UIColor colorWithRed:1 green:0.8 blue:0.4 alpha:0.9];
        } else {
            _perfHud.text = [NSString stringWithFormat:@"%.0f", fps];
            _perfHud.textColor = [UIColor colorWithWhite:1 alpha:0.85];
        }
    } else if (_perfHud != nil) {
        _perfHud.hidden = YES;
    }
}

// Send up-events for everything currently held and recentre the stick.
- (void)releaseAllControls {
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    for (NSNumber* idx in _touchButtons.allValues) {
        NSString* l = btns[idx.intValue].label;
        if (![l isEqualToString:@"≡"] && ![l hasPrefix:@"C"]) {
            [self applyButton:l down:NO];
        }
    }
    [_touchButtons removeAllObjects];
    [self recomputeCAxes]; // dict now empty -> C axes recentre
    _stickActive = NO;
    _stickTouch = nil;
    _stickSynth = NO;
    [self syncStickLayers]; // D15
    _zHeld = NO;
    _zLocked = NO;
    _aHeld = NO;
    _aLocked = NO;
    _bHeld = NO;
    _aLockSeq++;
    _zLockSeq++;
    SohIos_PadButton(SDL_CONTROLLER_BUTTON_A, false); // locked gas off
    _lastSentLX = _lastSentLY = 0;
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_TRIGGERLEFT, 0);
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTX, 0);
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTY, 0);
}

// MK64 (D6): effective gas = finger on A, or lock engaged and brake not
// overriding. Called from every A/B/lock transition.
- (void)mk64UpdateGas {
    SohIos_PadButton(SDL_CONTROLLER_BUTTON_A, _aHeld || (_aLocked && !_bHeld));
}

// Button labels -> virtual pad actions. C-buttons ride the right stick
// (SoH's default C mapping); Z is the left trigger.
- (void)applyButton:(NSString*)label down:(BOOL)down {
    if ([label isEqualToString:@"≡"]) {
        if (down) {
            SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE); // open SoH menu
            _controlsHidden = YES; // get out of the menu's way (restore dot remains)
            [self setNeedsDisplay];
        }
        return;
    }
    if ([label isEqualToString:@"A"]) {
        // MK64 gas (D6): hold >=0.6 s locks gas on (haptic confirms); a tap
        // while locked unlocks. gSohIos.HoldToLock=0 disables the gesture.
        if (down) {
            if (_aLocked) {
                _aLocked = NO; // tap-to-unlock (finger still holds gas)
            } else if (CVarGetInteger("gSohIos.HoldToLock", 1)) {
                unsigned seq = ++_aLockSeq;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.60 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (_aHeld && seq == _aLockSeq) {
                        _aLocked = YES;
                        [self hapticTap];
                        [self sohHotRepaint:@"A"]; // D15
                    }
                });
            }
            _aHeld = YES;
        } else {
            _aHeld = NO;
            _aLockSeq++; // cancel a pending lock
        }
        [self mk64UpdateGas];
        [self sohHotRepaint:@"A"]; // D15: only the A button repaints
    } else if ([label isEqualToString:@"B"]) {
        // MK64 brake (D6): BTN_B <- SDL X in this port's default mappings
        // (SDL B would press C-DOWN). While held it overrides a locked gas
        // WITHOUT untoggling — gas resumes on release.
        _bHeld = down;
        SohIos_PadButton(SDL_CONTROLLER_BUTTON_X, down);
        [self mk64UpdateGas];
    } else if ([label isEqualToString:@"START"]) {
        SohIos_PadButton(SDL_CONTROLLER_BUTTON_START, down);
    } else if ([label isEqualToString:@"L"]) {
        SohIos_PadButton(SDL_CONTROLLER_BUTTON_LEFTSHOULDER, down);
    } else if ([label isEqualToString:@"R"]) {
        SohIos_PadButton(SDL_CONTROLLER_BUTTON_RIGHTSHOULDER, down);
    } else if ([label isEqualToString:@"Z"]) {
        // MK64 item (D6, user policy): a tap is the NATIVE throw and a hold
        // is the native drag — so the lock gesture is HOLD >=0.6 s (haptic
        // confirms), never double-tap (its first tap would fire-and-release
        // the item). Tap while locked unlocks/releases.
        if (down) {
            if (_zLocked) {
                _zLocked = NO; // tap-to-unlock (finger still holds the item)
            } else if (CVarGetInteger("gSohIos.HoldToLock", 1)) {
                unsigned seq = ++_zLockSeq;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.60 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (_zHeld && seq == _zLockSeq) {
                        _zLocked = YES;
                        [self hapticTap];
                        [self sohHotRepaint:@"Z"]; // D15
                    }
                });
            }
            _zHeld = YES;
        } else {
            _zHeld = NO;
            _zLockSeq++; // cancel a pending lock
        }
        SohIos_PadAxis(SDL_CONTROLLER_AXIS_TRIGGERLEFT, (_zHeld || _zLocked) ? 32767 : 0);
        [self sohHotRepaint:@"Z"]; // D15: only the Z button repaints
    } else if ([label hasPrefix:@"C"]) {
        [self recomputeCAxes];
    }
}

// C-buttons combine on the right-stick axes; recompute from all held touches.
- (void)recomputeCAxes {
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    Sint32 rx = 0, ry = 0;
    for (NSNumber* idx in _touchButtons.allValues) {
        NSString* l = btns[idx.intValue].label;
        if ([l isEqualToString:@"C←"]) {
            rx -= 32767;
        } else if ([l isEqualToString:@"C→"]) {
            rx += 32767;
        } else if ([l isEqualToString:@"C↑"]) {
            ry -= 32767;
        } else if ([l isEqualToString:@"C↓"]) {
            ry += 32767;
        }
    }
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_RIGHTX, (Sint16)MAX(-32767, MIN(32767, rx)));
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_RIGHTY, (Sint16)MAX(-32767, MIN(32767, ry)));
}

- (int)hitButton:(CGPoint)p {
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    BOOL menuBtnVisible = [self menuButtonVisible];
    for (int i = 0; i < n; i++) {
        if ([btns[i].label isEqualToString:@"≡"] && !menuBtnVisible) {
            continue; // hidden during normal gameplay: not tappable either
        }
        if ([self isButtonHidden:btns[i].label]) {
            continue; // user-hidden: not drawn, not tappable
        }
        if (hypot(p.x - btns[i].center.x, p.y - btns[i].center.y) <= btns[i].radius * 1.35) {
            return i;
        }
    }
    return -1;
}

// LUS applies Port1.LeftStick.DeadzonePercentage (default 20) to all stick
// input — right for physical sticks, wrong for touch (the touch layer has
// zero mechanical noise; spec wants zero effective deadzone). Precompensate:
// any deflection starts past the deadzone, and the remaining travel maps
// linearly, so walk/run gradation is preserved. Physical pads are untouched.
static const CGFloat kLusDeadzone = 0.20;
static Sint16 SohIos_StickValue(CGFloat n) {
    if (n == 0) {
        return 0;
    }
    CGFloat m = MIN(1.0, fabs(n));
    // gSohIos.StickCurve: 0 linear, 1 expo (finer control near center)
    if (CVarGetInteger("gSohIos.StickCurve", 0) == 1) {
        m = m * m;
    }
    CGFloat v = kLusDeadzone + m * (1.0 - kLusDeadzone);
    return (Sint16)((n < 0 ? -v : v) * 32767);
}

- (void)updateStickAxesFromKnob {
    CGFloat nx = (_stickKnob.x - _stickBase.x) / _stickBaseR;
    CGFloat ny = (_stickKnob.y - _stickBase.y) / _stickBaseR;
    Sint16 lx = SohIos_StickValue(MAX(-1.0, MIN(1.0, nx)));
    Sint16 ly = SohIos_StickValue(MAX(-1.0, MIN(1.0, ny)));
    // Coalesce (device feedback: audio hitched every ~2 s while the touch
    // stick was held): touchesMoved arrives at up to 120 Hz and every
    // SDL_JoystickSetVirtualAxis takes SDL's joystick lock, contending with
    // the game thread's event pump — enough to starve the audio ring.
    // Only forward meaningful changes (~1% of range, and every zero
    // crossing so release is always exact).
    BOOL lxChanged = abs(lx - _lastSentLX) > 300 || ((lx == 0) != (_lastSentLX == 0));
    BOOL lyChanged = abs(ly - _lastSentLY) > 300 || ((ly == 0) != (_lastSentLY == 0));
    if (lxChanged) {
        SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTX, lx);
        _lastSentLX = lx;
    }
    if (lyChanged) {
        SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTY, ly);
        _lastSentLY = ly;
    }
}

// --- Layout customizer ----------------------------------------------------
static NSString* SohIos_LayoutKey(NSString* label) {
    // CVar-safe keys for glyph labels
    if ([label isEqualToString:@"C\u2191"]) return @"CU";
    if ([label isEqualToString:@"C\u2193"]) return @"CD";
    if ([label isEqualToString:@"C\u2190"]) return @"CL";
    if ([label isEqualToString:@"C\u2192"]) return @"CR";
    if ([label isEqualToString:@"\u2261"])  return @"MENU";
    return label;
}

// Canonical layout reference: ALWAYS landscape-shaped (w = long side),
// regardless of the view's momentary orientation — early-boot portrait
// bounds scrambled normalized coords on device (feedback 2026-07-12).
- (CGSize)layoutRefSize {
    CGRect b = self.bounds;
    CGFloat w = CGRectGetWidth(b), h = CGRectGetHeight(b);
    return CGSizeMake(MAX(w, h), MIN(w, h));
}

- (void)loadLayoutFromCVars {
    if (!CVarGetInteger("gSohIos.Layout.Set", 0)) {
        return;
    }
    _layoutScale = CVarGetFloat("gSohIos.Layout.Scale", 1.0f);
    for (NSString* key in @[ @"A", @"B", @"CU", @"CD", @"CL", @"CR", @"Z", @"L", @"R", @"START", @"MENU" ]) {
        float x = CVarGetFloat([NSString stringWithFormat:@"gSohIos.Layout.%@.x", key].UTF8String, -1.0f);
        float y = CVarGetFloat([NSString stringWithFormat:@"gSohIos.Layout.%@.y", key].UTF8String, -1.0f);
        if (x >= 0 && y >= 0) {
            _layoutOverrides[key] = [NSValue valueWithCGPoint:CGPointMake(x, y)];
        }
        // MENU (≡) is never hideable (isButtonHidden exempts it), so a stale
        // MENU.hidden is simply not read back into the set.
        if (![key isEqualToString:@"MENU"] &&
            CVarGetInteger([NSString stringWithFormat:@"gSohIos.Layout.%@.hidden", key].UTF8String, 0)) {
            [_layoutHidden addObject:key];
        }
    }
    float sx = CVarGetFloat("gSohIos.Layout.Stick.x", -1.0f);
    float sy = CVarGetFloat("gSohIos.Layout.Stick.y", -1.0f);
    if (sx >= 0 && sy >= 0) {
        _stickHome = CGPointMake(sx, sy);
    }
}

- (void)saveLayoutToCVars {
    // Clear EVERYTHING first: stale per-button keys from earlier saves were
    // resurrecting on the next launch (device bug: deterministic jumble).
    CVarClearBlock("gSohIos.Layout");
    CVarSetInteger("gSohIos.Layout.Set", 1);
    CVarSetFloat("gSohIos.Layout.Scale", (float)_layoutScale);
    for (NSString* key in _layoutOverrides) {
        CGPoint n = [_layoutOverrides[key] CGPointValue];
        CVarSetFloat([NSString stringWithFormat:@"gSohIos.Layout.%@.x", key].UTF8String, (float)n.x);
        CVarSetFloat([NSString stringWithFormat:@"gSohIos.Layout.%@.y", key].UTF8String, (float)n.y);
    }
    // Hidden buttons are stored independently of position overrides — a user
    // can hide L/R without ever dragging anything (positions stay default).
    for (NSString* key in _layoutHidden) {
        CVarSetInteger([NSString stringWithFormat:@"gSohIos.Layout.%@.hidden", key].UTF8String, 1);
    }
    if (!CGPointEqualToPoint(_stickHome, CGPointZero)) {
        CVarSetFloat("gSohIos.Layout.Stick.x", (float)_stickHome.x);
        CVarSetFloat("gSohIos.Layout.Stick.y", (float)_stickHome.y);
    }
    CVarSave();
}

- (CGPoint)stickHomePoint {
    CGRect b = self.bounds;
    if (CGPointEqualToPoint(_stickHome, CGPointZero)) {
        CGPoint def = CGPointMake(b.origin.x + 150, CGRectGetMaxY(b) - 170);
        return [self applyLefty:def];
    }
    CGSize ref = [self layoutRefSize];
    return [self applyLefty:CGPointMake(_stickHome.x * ref.width, _stickHome.y * ref.height)];
}

// Left-handed mirror (gSohIos.LeftyFlip): flips every X around the canonical
// width. Applied AFTER overrides so customized layouts mirror too.
- (CGPoint)applyLefty:(CGPoint)c {
    if (!CVarGetInteger("gSohIos.LeftyFlip", 0)) {
        return c;
    }
    return CGPointMake([self layoutRefSize].width - c.x, c.y);
}

#define kStickHaloR 150.0

- (CGRect)editChromeRect {
    // Bottom-LEFT per user preference (overlapping the stick halo is fine —
    // the chrome is hit-tested first, and the left side is the least
    // crowded place for customized buttons).
    CGRect b = self.bounds;
    return CGRectMake(b.origin.x + 16, CGRectGetMaxY(b) - 50, 330, 44);
}
- (CGPoint)editResetCenter {
    CGRect c = [self editChromeRect];
    return CGPointMake(CGRectGetMinX(c) + 26, CGRectGetMidY(c));
}
- (CGPoint)editSaveCenter {
    CGRect c = [self editChromeRect];
    return CGPointMake(CGRectGetMaxX(c) - 26, CGRectGetMidY(c));
}
- (CGRect)editSliderRect {
    CGRect c = [self editChromeRect];
    return CGRectMake(CGRectGetMinX(c) + 58, CGRectGetMidY(c) - 4, CGRectGetWidth(c) - 116, 8);
}

- (int)hitButtonForEdit:(CGPoint)pnt {
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    for (int i = 0; i < n; i++) {
        if (hypot(pnt.x - btns[i].center.x, pnt.y - btns[i].center.y) <= MAX(btns[i].radius * 1.35, 30)) {
            return i;
        }
    }
    return -1;
}

// --- Per-button hide/show badge (customizer only) --------------------------
// A small eye chip sits just OUTSIDE the button rim so the whole button body
// stays a drag handle (the badge must not block moving a button around). It
// points away from the local cluster centroid (so MK64's C-diamond spreads
// its badges radially instead of piling up) and is clamped on-screen, so
// edge buttons (L/R top corners) never push it off-screen. eye.slash =
// "tap to hide" on a visible button; eye = "tap to show" on a hidden one.
#define kHideBadgeR 14.0
- (CGPoint)hideBadgeCenterForCenter:(CGPoint)c radius:(CGFloat)r {
    CGRect b = self.bounds;
    SohButton all[16];
    int an = 0;
    [self buttonRects:all count:&an];
    CGFloat sx = 0, sy = 0;
    int cnt = 0;
    for (int i = 0; i < an; i++) {
        CGFloat d = hypot(all[i].center.x - c.x, all[i].center.y - c.y);
        if (d > 1.0 && d < 150.0) {
            sx += all[i].center.x;
            sy += all[i].center.y;
            cnt++;
        }
    }
    CGFloat dirX, dirY;
    if (cnt > 0) {
        dirX = c.x - sx / cnt;
        dirY = c.y - sy / cnt;
        CGFloat nrm = hypot(dirX, dirY);
        if (nrm < 1.0) { // sits on the centroid: default up
            dirX = 0;
            dirY = -1;
        } else {
            dirX /= nrm;
            dirY /= nrm;
        }
    } else {
        dirX = (c.x > CGRectGetMidX(b)) ? -0.7071 : 0.7071;
        dirY = (c.y > CGRectGetMidY(b)) ? -0.7071 : 0.7071;
    }
    CGFloat off = r + kHideBadgeR - 2.0; // badge inner edge ~tangent to the rim
    CGPoint badge = CGPointMake(c.x + dirX * off, c.y + dirY * off);
    CGFloat m = kHideBadgeR + 4.0;
    badge.x = MAX(b.origin.x + m, MIN(CGRectGetMaxX(b) - m, badge.x));
    badge.y = MAX(b.origin.y + m, MIN(CGRectGetMaxY(b) - m, badge.y));
    return badge;
}

// Index of the button whose layout key matches (-1 = none).
- (int)indexForLayoutKey:(NSString*)key {
    if (key == nil) {
        return -1;
    }
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    for (int i = 0; i < n; i++) {
        if ([SohIos_LayoutKey(btns[i].label) isEqualToString:key]) {
            return i;
        }
    }
    return -1;
}

// The eye chip lives ONLY on the currently-selected button. Returns YES and
// (optionally) its center if the selected button has a chip pnt falls in.
- (BOOL)pointHitsSelectedChip:(CGPoint)pnt center:(CGPoint*)outChip {
    int i = [self indexForLayoutKey:_editSelected];
    if (i < 0) {
        return NO;
    }
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    if ([btns[i].label isEqualToString:@"≡"]) {
        return NO; // menu button has no chip (never hideable)
    }
    CGPoint chip = [self hideBadgeCenterForCenter:btns[i].center radius:btns[i].radius];
    if (outChip != NULL) {
        *outChip = chip;
    }
    return hypot(pnt.x - chip.x, pnt.y - chip.y) <= kHideBadgeR + 4.0;
}

- (void)drawHideBadgeAt:(CGPoint)c hidden:(BOOL)hidden {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect ring = CGRectMake(c.x - kHideBadgeR, c.y - kHideBadgeR, kHideBadgeR * 2, kHideBadgeR * 2);
    [[UIColor colorWithWhite:0.10 alpha:0.92] setFill];
    CGContextFillEllipseInRect(ctx, ring);
    [[UIColor colorWithWhite:1.0 alpha:0.85] setStroke];
    CGContextSetLineWidth(ctx, 1.5);
    CGContextStrokeEllipseInRect(ctx, ring);
    UIImageSymbolConfiguration* cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
    UIImage* img = [[UIImage systemImageNamed:(hidden ? @"eye.fill" : @"eye.slash.fill") withConfiguration:cfg]
        imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    if (img != nil) {
        [img drawInRect:CGRectMake(c.x - img.size.width / 2, c.y - img.size.height / 2, img.size.width, img.size.height)];
    } else {
        // Font fallback if SF Symbols is unavailable (should not happen on iOS 15+).
        [self drawGlyph:(hidden ? @"o" : @"x") at:c size:16 alpha:1.0];
    }
}

// Bridge gate probe (idb taps are unreliable on the sim). MAIN THREAD ONLY.
// Selection model: the eye chip shows ONLY on the last-touched (selected)
// button. Subcommands:
//   list          -> "edit=E sel=KEY|none <KEY:h<hidden>:hit<hitself>> ...
//                     selchip=x,y|none" (hitself must be 0 for a hidden button)
//   select KEY    -> drives the REAL editBegan at KEY's button center =
//                    touch-to-select; its chip appears, any prior one clears
//   chiptap       -> drives the REAL editBegan at the SELECTED button's chip;
//                    toggles hide, keeps selection, starts no drag
//   tapedit X Y   -> real editBegan at an arbitrary point (gates ↺/✓ chrome)
//   menutap       -> hitButton + applyButton at the ≡ center (touch route)
//   save          -> saveLayoutToCVars (what ✓ does)
- (NSString*)hideProbe:(NSArray<NSString*>*)a {
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    NSString* sub = a.count >= 1 ? a[0].lowercaseString : @"list";
    // menutap: the touchesBegan route for a tap on the ≡ button's center --
    // hitButton (which applies the menuButtonVisible / Always-Show gate) then
    // applyButton down+up. "hit=none" means a real tap there would miss (D10
    // verification; idb ui tap is dead on the iOS 27 sim runtime). Dev bridge
    // only (the bridge itself is compiled out of release builds).
    if ([sub isEqualToString:@"menutap"]) {
        for (int k = 0; k < n; k++) {
            if (![btns[k].label isEqualToString:@"≡"]) {
                continue;
            }
            int hit = [self hitButton:btns[k].center];
            if (hit < 0 || ![btns[hit].label isEqualToString:@"≡"]) {
                return @"ok hit=none";
            }
            [self applyButton:btns[hit].label down:YES];
            [self applyButton:btns[hit].label down:NO];
            return @"ok hit=menu";
        }
        return @"err no menu button";
    }
    if ([sub isEqualToString:@"select"] && a.count >= 2) {
        int i = [self indexForLayoutKey:a[1].uppercaseString];
        if (i < 0) {
            return @"err no such button";
        }
        [self editBegan:btns[i].center]; // real touch-to-select on the body
        NSString* dragWas = _editDrag ?: @"nil";
        [self editEnded];
        return [NSString stringWithFormat:@"ok sel=%@ editDragWas=%@", _editSelected ?: @"none", dragWas];
    }
    if ([sub isEqualToString:@"chiptap"]) {
        int i = [self indexForLayoutKey:_editSelected];
        if (i < 0) {
            return @"err nothing selected";
        }
        CGPoint chip = CGPointZero;
        BOOL onChip = [self pointHitsSelectedChip:btns[i].center center:&chip]; // center just to fetch chip
        (void)onChip;
        BOOL was = [self isButtonHidden:btns[i].label];
        NSString* selBefore = _editSelected;
        [self editBegan:chip]; // real chip tap
        NSString* dragAfter = _editDrag ?: @"nil"; // must be nil: a chip tap starts no drag
        BOOL now = [self isButtonHidden:btns[i].label];
        [self editEnded];
        return [NSString stringWithFormat:@"ok chiptap %@ %d->%d sel=%@ editDrag=%@", SohIos_LayoutKey(btns[i].label),
                                          was, now, _editSelected ?: @"none",
                                          [selBefore isEqualToString:_editSelected ?: @""] ? dragAfter : @"SELCHANGED"];
    }
    if ([sub isEqualToString:@"save"]) {
        [self saveLayoutToCVars]; // exactly what the customizer's checkmark does
        return @"ok saved";
    }
    if ([sub isEqualToString:@"tapedit"] && a.count >= 3) {
        [self editBegan:CGPointMake(a[1].floatValue, a[2].floatValue)];
        NSString* drag = _editDrag ?: @"nil";
        [self editEnded];
        return [NSString stringWithFormat:@"ok tapedit editMode=%d editDrag=%@", _editMode, drag];
    }
    int seli = [self indexForLayoutKey:_editSelected];
    NSMutableString* s = [NSMutableString stringWithFormat:@"ok edit=%d sel=%@", _editMode, _editSelected ?: @"none"];
    for (int i = 0; i < n; i++) {
        [s appendFormat:@" %@:h%d:hit%d", SohIos_LayoutKey(btns[i].label),
                        [self isButtonHidden:btns[i].label], [self hitButton:btns[i].center] == i];
    }
    if (seli >= 0 && ![btns[seli].label isEqualToString:@"≡"]) {
        CGPoint chip = [self hideBadgeCenterForCenter:btns[seli].center radius:btns[seli].radius];
        [s appendFormat:@" selchip=%.0f,%.0f", chip.x, chip.y];
    } else {
        [s appendString:@" selchip=none"];
    }
    return s;
}

- (void)editBegan:(CGPoint)pnt {
    CGPoint reset = [self editResetCenter], save = [self editSaveCenter];
    CGRect slider = CGRectInset([self editSliderRect], -12, -18);
    if (hypot(pnt.x - reset.x, pnt.y - reset.y) <= 26) {
        [_layoutOverrides removeAllObjects];
        [_layoutHidden removeAllObjects]; // reset restores every button to visible
        _layoutScale = 1.0;
        _stickHome = CGPointZero;
        [self setNeedsDisplay];
        return;
    }
    if (hypot(pnt.x - save.x, pnt.y - save.y) <= 26) {
        [self saveLayoutToCVars];
        _editMode = NO;
        _editDrag = nil;
        [self setNeedsDisplay];
        return;
    }
    if (CGRectContainsPoint(slider, pnt)) {
        _editDrag = @"__slider";
        [self editMoved:pnt];
        return;
    }
    // Eye chip (only on the selected button) is checked BEFORE the button-body
    // drag: tapping it toggles visibility, keeps the selection, and never
    // starts a drag. The chip sits outside the rim, so the body stays a drag
    // handle.
    if ([self pointHitsSelectedChip:pnt center:NULL]) {
        int i = [self indexForLayoutKey:_editSelected];
        SohButton bb[16];
        int bn = 0;
        [self buttonRects:bb count:&bn];
        if (i >= 0) {
            [self toggleHiddenForLabel:bb[i].label];
        }
        return;
    }
    // Touching a button SELECTS it (its eye chip appears; any prior selection's
    // chip disappears) and begins a drag.
    int idx = [self hitButtonForEdit:pnt];
    if (idx >= 0) {
        SohButton btns[16];
        int n = 0;
        [self buttonRects:btns count:&n];
        _editSelected = SohIos_LayoutKey(btns[idx].label); // chip appears here
        _editDrag = _editSelected;
        [self setNeedsDisplay];
        return;
    }
    CGPoint home = [self stickHomePoint];
    if (hypot(pnt.x - home.x, pnt.y - home.y) <= kStickHaloR) {
        _editDrag = @"__stick";
    }
}

- (void)editMoved:(CGPoint)pnt {
    CGRect b = self.bounds;
    if (_editDrag == nil) {
        return;
    }
    if ([_editDrag isEqualToString:@"__slider"]) {
        CGRect s = [self editSliderRect];
        CGFloat frac = MAX(0.0, MIN(1.0, (pnt.x - CGRectGetMinX(s)) / CGRectGetWidth(s)));
        _layoutScale = 0.7 + frac * (1.4 - 0.7);
        [self setNeedsDisplay];
        return;
    }
    CGFloat m = 30;
    CGPoint clamped = CGPointMake(MAX(b.origin.x + m, MIN(CGRectGetMaxX(b) - m, pnt.x)),
                                  MAX(b.origin.y + m, MIN(CGRectGetMaxY(b) - m, pnt.y)));
    // un-mirror before storing so lefty users edit in their own view
    clamped = [self applyLefty:clamped];
    CGSize ref = [self layoutRefSize];
    CGPoint normalized = CGPointMake(clamped.x / ref.width, clamped.y / ref.height);
    if ([_editDrag isEqualToString:@"__stick"]) {
        _stickHome = normalized;
    } else {
        _layoutOverrides[_editDrag] = [NSValue valueWithCGPoint:normalized];
    }
    [self setNeedsDisplay];
}

- (void)editEnded {
    _editDrag = nil;
}
// ----------------------------------------------------------------------------

// The stick is FLOATING: hidden until a touch lands inside its spawn halo
// (customizable home), then its base is wherever the finger came down.
- (BOOL)pointInStickRegion:(CGPoint)p {
#if TARGET_OS_VISION
    // Gaze-pinch has no proprioception — you can't feel where the spawn
    // halo is, so on visionOS the ENTIRE left half spawns the stick
    // (user report: pinch on the left side did nothing). Buttons are
    // hit-tested before the stick region, so they keep priority; near-miss
    // protection below still applies (a missed Z/L pinch must be a dead
    // pinch, not a surprise stick).
    if (p.x >= CGRectGetMidX(self.bounds)) {
        return NO;
    }
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    for (int i = 0; i < n; i++) {
        BOOL guarded = [btns[i].label isEqualToString:@"Z"] || [btns[i].label isEqualToString:@"L"] ||
                       [btns[i].label isEqualToString:@"≡"];
        if (guarded && [self isButtonHidden:btns[i].label]) {
            continue; // a hidden button leaves no dead zone
        }
        // buttonRects radii are already _layoutScale-scaled; only the
        // 26 pt near-miss margin needs scaling here.
        if (guarded &&
            hypot(p.x - btns[i].center.x, p.y - btns[i].center.y) <= btns[i].radius * 1.35 + 26 * _layoutScale) {
            return NO;
        }
    }
    return YES;
#else
    CGPoint home = [self stickHomePoint];
    if (hypot(p.x - home.x, p.y - home.y) > kStickHaloR) {
        return NO;
    }
    // Z protection (device feedback): a halo around Z never spawns the
    // stick — a missed Z tap is a dead tap, not a surprise stick. Skipped
    // when Z is hidden (no button there = no dead zone).
    if (![self isButtonHidden:@"Z"]) {
        CGPoint zC = [self zButtonCenter];
        if (hypot(p.x - zC.x, p.y - zC.y) <= (34 * 1.35 + 26) * _layoutScale) {
            return NO;
        }
    }
    return YES;
#endif
}

- (CGPoint)clampStickBase:(CGPoint)p {
    CGRect b = self.bounds;
    CGFloat m = _stickBaseR + 14; // keep the drawn ring on-screen
    return CGPointMake(MAX(b.origin.x + m, MIN(CGRectGetMaxX(b) - m, p.x)),
                       MAX(b.origin.y + m, MIN(CGRectGetMaxY(b) - m, p.y)));
}

- (NSArray<NSValue*>*)buttonRects:(SohButton*)outButtons count:(int*)outCount {
    CGRect b = self.bounds;
    CGFloat maxX = CGRectGetMaxX(b), maxY = CGRectGetMaxY(b);
    UIColor* cYellow = [UIColor colorWithRed:0.95 green:0.80 blue:0.15 alpha:0.55];
    UIColor* cBlue = [UIColor colorWithRed:0.20 green:0.45 blue:0.95 alpha:0.6];
    UIColor* cGreen = [UIColor colorWithRed:0.20 green:0.75 blue:0.35 alpha:0.6];
    UIColor* cGray = [UIColor colorWithWhite:0.6 alpha:0.55];
    UIColor* cRed = [UIColor colorWithRed:0.85 green:0.2 blue:0.2 alpha:0.6];
    // A/B primary cluster, bottom-right corner (v2: -20% radii per device
    // feel; program-wide unified layout 2026-07-21: cluster up ~20pt off the
    // very corner — Ghostship device-tuned, user wants identical defaults
    // across every HM port).
    CGFloat aX = maxX - 85, aY = maxY - 105;
    // C-button diamond, above the A/B cluster (kept fully on-screen).
    CGFloat cX = maxX - 105, cY = maxY - 235;
    SohButton btns[] = {
        { CGPointMake(aX, aY), 37, cBlue, @"A" },
        { CGPointMake(aX - 92, aY - 18), 32, cGreen, @"B" }, // a hair down toward Z (unified layout)
        { CGPointMake(cX, cY - 38), 27, cYellow, @"C↑" },
        { CGPointMake(cX, cY + 38), 27, cYellow, @"C↓" },
        { CGPointMake(cX - 40, cY), 27, cYellow, @"C←" },
        { CGPointMake(cX + 40, cY), 27, cYellow, @"C→" },
        // Z below A/B, EQUIDISTANT from both (unified layout, Ghostship
        // device-tuned): aX-68, not the plain midpoint aX-46 — A and B sit at
        // different heights (|Z-A|=92.7, |Z-B|=92.2). Thumb-reach beside
        // jump/attack enables the Z→A slide long-jump class of inputs, and it
        // clears the iOS edge-gesture zones that ate the old upper-left spot
        // (the stuck-Z story).
        { CGPointMake(aX - 68, maxY - 42), 34, cGray, @"Z" },
        { CGPointMake(b.origin.x + 80, b.origin.y + 60), 34, cGray, @"L" },
        { CGPointMake(maxX - 80, b.origin.y + 60), 34, cGray, @"R" },
        // START and ≡ swapped per device feedback: START bottom-center,
        // menu button top-center (visible only in intro/pause contexts).
        { CGPointMake(CGRectGetMidX(b), maxY - 45), 30, cRed, @"START" },
        { CGPointMake(CGRectGetMidX(b), b.origin.y + 55), 26, cGray, @"≡" },
    };
    int n = (int)(sizeof(btns) / sizeof(btns[0]));
    for (int i = 0; i < n; i++) {
        // Customized layout: per-button normalized centers (canonical
        // landscape reference) + lefty mirror + global scale.
        NSValue* ov = _layoutOverrides[SohIos_LayoutKey(btns[i].label)];
        if (ov != nil) {
            CGPoint nrm = [ov CGPointValue];
            CGSize ref = [self layoutRefSize];
            btns[i].center = CGPointMake(nrm.x * ref.width, nrm.y * ref.height);
        }
        btns[i].center = [self applyLefty:btns[i].center];
        btns[i].radius *= _layoutScale;
        outButtons[i] = btns[i];
    }
    *outCount = n;
    return nil;
}

- (void)drawGlyph:(NSString*)glyph at:(CGPoint)c size:(CGFloat)fontSize alpha:(CGFloat)alpha {
    NSDictionary* attrs = @{
        NSFontAttributeName : [UIFont boldSystemFontOfSize:fontSize],
        NSForegroundColorAttributeName : [UIColor colorWithWhite:1 alpha:alpha]
    };
    CGSize sz = [glyph sizeWithAttributes:attrs];
    [glyph drawAtPoint:CGPointMake(c.x - sz.width / 2, c.y - sz.height / 2) withAttributes:attrs];
}

// D15: every repaint request reaches the canvases (the old full-view redraw),
// and the stick layers follow the same state. Nothing else.
- (void)setNeedsDisplay {
    [_canvas setNeedsDisplay];
    [self sohLayoutHotCanvases];
    for (SohIosOverlayCanvas* c in _hotCanvases) {
        [c setNeedsDisplay];
    }
    [self syncStickLayers];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self sohLayoutHotCanvases];
    [self syncStickLayers];
}

- (void)sohHotRepaint:(NSString*)label {
    for (SohIosOverlayCanvas* c in _hotCanvases) {
        if ([c.hotLabel isEqualToString:label]) {
            [c setNeedsDisplay];
        }
    }
}

// Each hot canvas covers its button (+ stroke/AA margin) at an integral point
// origin, so its pixels land exactly where the full canvas put them.
- (void)sohLayoutHotCanvases {
    if (_hotCanvases == nil) {
        return;
    }
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    for (SohIosOverlayCanvas* c in _hotCanvases) {
        CGRect f = CGRectZero;
        for (int i = 0; i < n; i++) {
            if ([btns[i].label isEqualToString:c.hotLabel]) {
                CGFloat r = btns[i].radius + 4;
                f = CGRectIntegral(CGRectMake(btns[i].center.x - r, btns[i].center.y - r, r * 2, r * 2));
                break;
            }
        }
        if (!CGRectEqualToRect(f, c.frame)) {
            c.frame = f;
            [c setNeedsDisplay];
        }
    }
}

// Floating stick: position-only updates, no implicit animation, no redraw.
// Visible exactly when the old drawRect drew it.
- (void)syncStickLayers {
    if (_ringLayer == nil) {
        return;
    }
    BOOL show = _stickActive && !_editMode && !_popupOpen && !_controlsHidden && !_controllerMode;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _ringLayer.hidden = !show;
    _knobLayer.hidden = !show;
    if (show) {
        CGFloat scale = self.traitCollection.displayScale > 0 ? self.traitCollection.displayScale : 3.0;
        if (_ringLayer.contentsScale != scale) {
            _ringLayer.contentsScale = scale;
            _knobLayer.contentsScale = scale;
        }
        CGFloat ringR = (_stickBaseR + 8) * _layoutScale;
        if (ringR != _ringLayerR) {
            _ringLayerR = ringR;
            CGRect b = CGRectMake(0, 0, ringR * 2, ringR * 2);
            _ringLayer.bounds = b;
            CGPathRef path = CGPathCreateWithEllipseInRect(b, NULL);
            _ringLayer.path = path;
            CGPathRelease(path);
        }
        CGFloat knobR = _stickKnobR * _layoutScale;
        if (knobR != _knobLayerR) {
            _knobLayerR = knobR;
            CGRect b = CGRectMake(0, 0, knobR * 2, knobR * 2);
            _knobLayer.bounds = b;
            CGPathRef path = CGPathCreateWithEllipseInRect(b, NULL);
            _knobLayer.path = path;
            CGPathRelease(path);
        }
        _ringLayer.position = _stickBase;
        _knobLayer.position = _stickKnob;
    }
    [CATransaction commit];
}

// One gameplay-mode button, exactly as the single drawRect drew it.
- (void)sohDrawButton:(SohButton)bt ctx:(CGContextRef)ctx {
    BOOL isZ = [bt.label isEqualToString:@"Z"];
    BOOL isA = [bt.label isEqualToString:@"A"]; // MK64 gas lock visual
    if ((isZ && _zLocked) || (isA && _aLocked)) {
        // Hold lock engaged: unmistakably "on".
        [[UIColor colorWithRed:0.30 green:0.60 blue:1.0 alpha:0.9] setFill];
        [[UIColor colorWithWhite:1 alpha:0.95] setStroke];
    } else if ((isZ && _zHeld) || (isA && _aHeld)) {
        // Momentary hold: clearly active, dimmer than the lock.
        [[UIColor colorWithRed:0.25 green:0.45 blue:0.8 alpha:0.7] setFill];
        [[UIColor colorWithWhite:1 alpha:0.7] setStroke];
    } else {
        [bt.color setFill];
        [[UIColor colorWithWhite:1 alpha:0.5] setStroke];
    }
    CGRect r = CGRectMake(bt.center.x - bt.radius, bt.center.y - bt.radius, bt.radius * 2, bt.radius * 2);
    CGContextSetLineWidth(ctx, (isZ && _zLocked) || (isA && _aLocked) ? 4 : 3);
    CGContextFillEllipseInRect(ctx, r);
    CGContextStrokeEllipseInRect(ctx, r);
    BOOL labeled = isZ || [bt.label isEqualToString:@"L"] || [bt.label isEqualToString:@"R"] ||
                   [bt.label isEqualToString:@"≡"];
    if (labeled) {
        [self drawGlyph:bt.label at:bt.center size:20 alpha:0.95];
    }
}

- (BOOL)sohIsHotLabel:(NSString*)label {
    return [label isEqualToString:@"A"] || [label isEqualToString:@"Z"];
}

- (void)sohDrawCanvas:(UIView*)view hotLabel:(NSString*)hot {
    CGContextRef ctx = UIGraphicsGetCurrentContext();

    if (hot != nil) {
        // One hot button alone, in overlay coordinates (the canvas sits at an
        // integral origin). Plain gameplay mode only; every other mode is
        // drawn whole by the main canvas.
        if (_editMode || _popupOpen || _controlsHidden || _controllerMode || [self isButtonHidden:hot]) {
            return;
        }
        CGContextTranslateCTM(ctx, -view.frame.origin.x, -view.frame.origin.y);
        SohButton hb[16];
        int hn = 0;
        [self buttonRects:hb count:&hn];
        for (int i = 0; i < hn; i++) {
            if ([hb[i].label isEqualToString:hot]) {
                [self sohDrawButton:hb[i] ctx:ctx];
            }
        }
        return;
    }

    if (_editMode) {
        // --- Customizer: everything visible and draggable ---
        // Stick spawn halo (moves with its home).
        CGPoint home = [self stickHomePoint];
        [[UIColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:0.16] setFill];
        CGContextFillEllipseInRect(
            ctx, CGRectMake(home.x - kStickHaloR, home.y - kStickHaloR, kStickHaloR * 2, kStickHaloR * 2));
        [[UIColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:0.5] setStroke];
        CGContextSetLineWidth(ctx, 2);
        CGContextStrokeEllipseInRect(
            ctx, CGRectMake(home.x - kStickHaloR, home.y - kStickHaloR, kStickHaloR * 2, kStickHaloR * 2));
        CGFloat ringR = (_stickBaseR + 8) * _layoutScale;
        [[UIColor colorWithWhite:1 alpha:0.5] setStroke];
        CGContextSetLineWidth(ctx, 4);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(home.x - ringR, home.y - ringR, ringR * 2, ringR * 2));
        [[UIColor colorWithWhite:1 alpha:0.35] setFill];
        CGFloat knobR = _stickKnobR * _layoutScale;
        CGContextFillEllipseInRect(ctx, CGRectMake(home.x - knobR, home.y - knobR, knobR * 2, knobR * 2));

        // All buttons at their (possibly overridden) spots.
        SohButton ebtns[16];
        int en = 0;
        [self buttonRects:ebtns count:&en];
        for (int i = 0; i < en; i++) {
            SohButton bt = ebtns[i];
            // Hidden buttons are ghosted (low opacity) so the user still sees
            // them to reposition or un-hide. The eye chip appears on the
            // SELECTED button ONLY (the last one touched) — no chip at all
            // until the user touches a button.
            BOOL hidden = [self isButtonHidden:bt.label];
            BOOL selected = (_editSelected != nil && [_editSelected isEqualToString:SohIos_LayoutKey(bt.label)]);
            CGFloat fillA = hidden ? 0.22 : 1.0, strokeA = hidden ? 0.28 : 0.7, glyphA = hidden ? 0.35 : 0.95;
            [[bt.color colorWithAlphaComponent:CGColorGetAlpha(bt.color.CGColor) * fillA] setFill];
            [[UIColor colorWithWhite:1 alpha:(selected ? 1.0 : strokeA)] setStroke];
            CGRect r = CGRectMake(bt.center.x - bt.radius, bt.center.y - bt.radius, bt.radius * 2, bt.radius * 2);
            CGContextSetLineWidth(ctx, selected ? 3 : 2); // selected button: brighter ring
            CGContextFillEllipseInRect(ctx, r);
            CGContextStrokeEllipseInRect(ctx, r);
            [self drawGlyph:bt.label at:bt.center size:16 * _layoutScale alpha:glyphA];
            if (selected && ![bt.label isEqualToString:@"≡"]) {
                [self drawHideBadgeAt:[self hideBadgeCenterForCenter:bt.center radius:bt.radius] hidden:hidden];
            }
        }

        // Chrome strip: [reset][scale slider][save]
        CGRect chrome = [self editChromeRect];
        [[UIColor colorWithWhite:0 alpha:0.55] setFill];
        UIBezierPath* rounded = [UIBezierPath bezierPathWithRoundedRect:chrome cornerRadius:14];
        [rounded fill];
        CGPoint reset = [self editResetCenter];
        [[UIColor colorWithRed:0.85 green:0.25 blue:0.25 alpha:0.9] setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(reset.x - 20, reset.y - 20, 40, 40));
        [self drawGlyph:@"\u21ba" at:reset size:22 alpha:1.0];
        CGPoint save = [self editSaveCenter];
        [[UIColor colorWithRed:0.2 green:0.7 blue:0.35 alpha:0.95] setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(save.x - 20, save.y - 20, 40, 40));
        [self drawGlyph:@"\u2713" at:save size:22 alpha:1.0];
        CGRect s = [self editSliderRect];
        [[UIColor colorWithWhite:1 alpha:0.3] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:s cornerRadius:4] fill];
        CGFloat frac = (_layoutScale - 0.7) / (1.4 - 0.7);
        CGFloat thumbX = CGRectGetMinX(s) + frac * CGRectGetWidth(s);
        [[UIColor whiteColor] setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(thumbX - 10, CGRectGetMidY(s) - 10, 20, 20));
        NSString* pct = [NSString stringWithFormat:@"%d%%", (int)round(_layoutScale * 100)];
        [self drawGlyph:pct at:CGPointMake(CGRectGetMidX(chrome), CGRectGetMinY(chrome) - 12) size:13 alpha:0.9];
        return;
    }

    if (_popupOpen) {
        return; // a popup owns the screen: draw nothing at all
    }

    if (_controlsHidden) {
        // Menu is open: draw only the small restore dot.
        CGPoint dot = [self restoreDotCenter];
        [[UIColor colorWithWhite:1 alpha:0.25] setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(dot.x - 22, dot.y - 22, 44, 44));
        [self drawGlyph:@"≡" at:dot size:18 alpha:0.8];
        return;
    }

    if (_controllerMode) {
        // Physical controller drives the game: no touch controls. The ≡
        // button follows the same visibility policy as touch (intro/title
        // and pause only), keeping the SoH menu reachable without clutter.
        if ([self menuButtonVisible]) {
            SohButton btns[16];
            int n = 0;
            [self buttonRects:btns count:&n];
            SohButton menuBtn = btns[n - 1]; // ≡ is last
            [menuBtn.color setFill];
            CGRect r = CGRectMake(menuBtn.center.x - menuBtn.radius, menuBtn.center.y - menuBtn.radius,
                                  menuBtn.radius * 2, menuBtn.radius * 2);
            CGContextFillEllipseInRect(ctx, r);
            [self drawGlyph:@"≡" at:menuBtn.center size:20 alpha:0.95];
        }
        return;
    }

    // Floating left stick: _stickView's layers (syncStickLayers), not here.

    // Buttons. Labels only where the glyph isn't obvious (L/R/Z + ≡). A and
    // Z are drawn by their own hot canvases so a press repaints only that.
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    BOOL menuBtnVisible = [self menuButtonVisible];
    for (int i = 0; i < n; i++) {
        SohButton bt = btns[i];
        if ([self sohIsHotLabel:bt.label]) {
            continue; // hot canvas
        }
        if ([bt.label isEqualToString:@"≡"] && !menuBtnVisible) {
            continue; // hidden during normal gameplay
        }
        if ([self isButtonHidden:bt.label]) {
            continue; // user-hidden from the touch layer (customizer)
        }
        [self sohDrawButton:bt ctx:ctx];
    }
}

// Pass-through: only the stick zone and button circles intercept touches;
// everywhere else falls through to SDL's view (game taps, ImGui menu).
// While hidden (menu open), ONLY the restore dot intercepts.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event {
    if (_editMode) {
        return YES; // customizer owns the screen
    }
    if (_popupOpen) {
        return NO; // popup owns all input (extractor Yes/No etc.)
    }
    if (_controlsHidden) {
        return YES; // menu open: the touch-router owns every touch
    }
    if (_controllerMode) {
        // Only the ≡ button (and only when visible per policy) is touch-active.
        if (![self menuButtonVisible]) {
            return NO;
        }
        SohButton btns[16];
        int n = 0;
        [self buttonRects:btns count:&n];
        SohButton menuBtn = btns[n - 1];
        return hypot(point.x - menuBtn.center.x, point.y - menuBtn.center.y) <= menuBtn.radius * 1.35;
    }
    if ([self hitButton:point] >= 0) {
        return YES;
    }
    return [self pointInStickRegion:point]; // floating stick spawns anywhere here
}

// --- Menu touch-router -------------------------------------------------
// While the SoH menu is open the overlay owns every touch and forwards
// SYNTHESIZED mouse events, because raw touch-as-mouse reads as hover
// (tooltips) and can never scroll. Taps click; vertical drags scroll
// (wheel); horizontal drags press-and-drag (sliders); a 450 ms hold
// hovers (tooltip), cleared on release.
- (void)routerReset {
    _routerTouch = nil;
    _routerMode = 0;
}

- (void)routerBegan:(UITouch*)t {
    if (_routerTouch != nil) {
        return; // single-touch menu interaction
    }
    _routerTouch = t;
    _routerMode = 0;
    _routerStart = _routerLast = [t locationInView:self];
    const void* captured = (__bridge const void*)t;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ((__bridge const void*)self->_routerTouch == captured && self->_routerMode == 0 && self->_controlsHidden) {
            self->_routerMode = 3; // hover: tooltip appears under the held finger
            SohIos_InjectMouseMotion((int)self->_routerStart.x, (int)self->_routerStart.y);
        }
    });
}

- (void)routerMoved:(UITouch*)t {
    if (t != _routerTouch) {
        return;
    }
    CGPoint pnt = [t locationInView:self];
    if (_routerMode == 0) {
        CGFloat dx = pnt.x - _routerStart.x, dy = pnt.y - _routerStart.y;
        if (hypot(dx, dy) > 8.0) {
            if (fabs(dy) > fabs(dx) * 1.15) {
                _routerMode = 1; // scroll: mouse-free (no hover -> no tooltips/slider side-effects)
            } else {
                _routerMode = 2; // drag: real press for sliders/scrollbars
                SohIos_InjectMouseMotion((int)_routerStart.x, (int)_routerStart.y);
                SohIos_InjectMouseButton((int)_routerStart.x, (int)_routerStart.y, YES);
            }
        }
    }
    if (_routerMode == 1) {
        CGFloat dy = pnt.y - _routerLast.y;
        if (fabs(dy) >= 1.0) {
            SohIos_QueueMenuScroll((float)pnt.x, (float)dy);
            _routerLast = pnt;
        }
    } else if (_routerMode == 2) {
        SohIos_InjectMouseMotion((int)pnt.x, (int)pnt.y);
        _routerLast = pnt;
    }
}

- (void)routerEnded:(UITouch*)t cancelled:(BOOL)cancelled {
    if (t != _routerTouch) {
        return;
    }
    CGPoint pnt = [t locationInView:self];
    if (_routerMode == 2) {
        SohIos_InjectMouseButton((int)pnt.x, (int)pnt.y, NO);
    } else if (_routerMode == 3) {
        // clear the hover so the tooltip dismisses
        SohIos_InjectMouseMotion((int)self.bounds.size.width - 2, (int)self.bounds.size.height - 2);
    } else if (_routerMode == 0 && !cancelled) {
        CGPoint dot = [self restoreDotCenter];
        if (hypot(pnt.x - dot.x, pnt.y - dot.y) <= 34) {
            SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE); // restore dot: close menu
            _controlsHidden = NO;
            [self setNeedsDisplay];
        } else {
            SohIos_InjectClick((int)pnt.x, (int)pnt.y);
        }
    }
    [self routerReset];
}
// ------------------------------------------------------------------------

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (_editMode) {
        for (UITouch* t in touches) {
            [self editBegan:[t locationInView:self]];
            break;
        }
        return;
    }
    if (_controlsHidden) {
        for (UITouch* t in touches) {
            [self routerBegan:t];
        }
        return;
    }
    if (_controllerMode) {
        // pointInside already vetted this as a paused-state ≡ tap.
        SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE);
        _controlsHidden = YES;
        [self setNeedsDisplay];
        return;
    }
    for (UITouch* t in touches) {
        CGPoint p = [t locationInView:self];
        int idx = [self hitButton:p];
        if (idx >= 0) {
            _touchButtons[[NSValue valueWithPointer:(__bridge const void*)t]] = @(idx);
            SohButton btns[16];
            int n = 0;
            [self buttonRects:btns count:&n];
            [self hapticTap];
            [self applyButton:btns[idx].label down:YES];
        } else if (!_stickActive && [self pointInStickRegion:p]) {
            [self sohStickBeganAt:p touch:t];
        }
    }
}

// Floating stick: base is where the finger landed. Shared by the real touch
// path and the bridge's synthetic finger (`stickspin`, perf round D15), so the
// instrument exercises exactly the code a thumb does.
- (void)sohStickBeganAt:(CGPoint)p touch:(UITouch*)t {
    [self hapticTap];
    _stickActive = YES;
    _stickTouch = t;
    _stickBase = [self clampStickBase:p];
    _stickKnob = _stickBase;
    [self updateStickAxesFromKnob];
    [self syncStickLayers]; // D15
}

- (void)sohStickMovedTo:(CGPoint)p {
    CGFloat dx = p.x - _stickBase.x, dy = p.y - _stickBase.y;
    CGFloat d = hypot(dx, dy);
    if (d > _stickBaseR) {
        dx = dx / d * _stickBaseR;
        dy = dy / d * _stickBaseR;
    }
    CGPoint knob = CGPointMake(_stickBase.x + dx, _stickBase.y + dy);
    if (hypot(knob.x - _stickKnob.x, knob.y - _stickKnob.y) < 1.0) {
        return; // sub-point jitter: no axis send, no redraw
    }
    _stickKnob = knob;
    [self updateStickAxesFromKnob];
    [self syncStickLayers]; // D15: move the knob layer; no repaint
}

- (void)sohStickEnded {
    _stickActive = NO;
    _stickTouch = nil;
    _stickKnob = _stickBase;
    _lastSentLX = _lastSentLY = 0;
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTX, 0);
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTY, 0);
    [self syncStickLayers]; // D15
}

// Bridge `stickspin` backend (D15). MAIN THREAD ONLY. phase 0 = finger down
// (spawns the stick only where a real touch would), 1 = move, 2 = lift.
// The synthetic finger has no UITouch, so it is tracked with _stickSynth and
// never collides with a real stick touch.
- (int)sohSynthStick:(int)phase at:(CGPoint)p {
    if (_editMode || _controlsHidden || _controllerMode || _popupOpen) {
        return -1;
    }
    if (phase == 0) {
        if (_stickActive || ![self pointInStickRegion:p]) {
            return 0;
        }
        _stickSynth = YES;
        [self sohStickBeganAt:p touch:nil];
        return 2;
    }
    if (!_stickActive || !_stickSynth) {
        return 0;
    }
    if (phase == 1) {
        [self sohStickMovedTo:p];
    } else {
        _stickSynth = NO;
        [self sohStickEnded];
    }
    return 2;
}

// Bridge `tc` backend (D15). MAIN THREAD ONLY: press/release one button by
// label through the real applyButton path (lock timers included).
- (BOOL)sohSynthButton:(NSString*)label down:(BOOL)down {
    if (_editMode || _controlsHidden || _controllerMode || _popupOpen) {
        return NO;
    }
    [self applyButton:label down:down];
    return YES;
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (_editMode) {
        for (UITouch* t in touches) {
            [self editMoved:[t locationInView:self]];
            break;
        }
        return;
    }
    if (_controlsHidden) {
        for (UITouch* t in touches) {
            [self routerMoved:t];
        }
        return;
    }
    // Button slide-across (Ghostship cross-port fix, device-confirmed): a
    // finger that slides from one button onto a DIFFERENT one transfers the
    // press (release old, press new) — the Z→A slide long-jump / B→A dive
    // class of inputs consoles always had. Sliding through the gap between
    // buttons KEEPS the current button held, so Z stays down right until the
    // finger reaches A. Never stores -1 (empty space leaves the binding
    // untouched); updates _touchButtons BEFORE applyButton so the C-axis
    // recompute sees the post-transfer state.
    if (_touchButtons.count > 0) {
        SohButton sbtns[16];
        int sn = 0;
        [self buttonRects:sbtns count:&sn];
        for (UITouch* t in touches) {
            NSValue* key = [NSValue valueWithPointer:(__bridge const void*)t];
            NSNumber* boundIdx = _touchButtons[key];
            if (boundIdx == nil) {
                continue; // stick touch — handled below
            }
            int boundI = boundIdx.intValue;
            int nowIdx = [self hitButton:[t locationInView:self]];
            if (nowIdx >= 0 && nowIdx != boundI) {
                _touchButtons[key] = @(nowIdx);
                if (boundI >= 0 && boundI < sn) {
                    [self applyButton:sbtns[boundI].label down:NO];
                }
                [self applyButton:sbtns[nowIdx].label down:YES];
            }
        }
    }
    if (!_stickActive) {
        return;
    }
    for (UITouch* t in touches) {
        if (t != _stickTouch || _stickSynth) {
            continue;
        }
        [self sohStickMovedTo:[t locationInView:self]];
    }
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (_editMode) {
        [self editEnded];
        return;
    }
    if (_controlsHidden) {
        for (UITouch* t in touches) {
            [self routerEnded:t cancelled:NO];
        }
        return;
    }
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    for (UITouch* t in touches) {
        NSValue* key = [NSValue valueWithPointer:(__bridge const void*)t];
        NSNumber* idx = _touchButtons[key];
        if (idx != nil) {
            [_touchButtons removeObjectForKey:key];
            [self applyButton:btns[idx.intValue].label down:NO];
        }
        if (t == _stickTouch && !_stickSynth) {
            [self sohStickEnded];
        }
    }
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (_editMode) {
        [self editEnded];
        return;
    }
    if (_controlsHidden) {
        for (UITouch* t in touches) {
            [self routerEnded:t cancelled:YES];
        }
        return;
    }
    [self touchesEnded:touches withEvent:event];
}
@end

static UIWindow* SohIos_GetSDLWindow(struct SDL_Window* sdlWindow) {
    SDL_SysWMinfo wm;
    SDL_VERSION(&wm.version);
    if (!SDL_GetWindowWMInfo(sdlWindow, &wm) || wm.subsystem != SDL_SYSWM_UIKIT) {
        return nil;
    }
    return wm.info.uikit.window;
}

static UIWindowScene* SohIos_ActiveScene(void) {
    UIWindowScene* fallback = gSohConnectedScene;
    for (UIScene* s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        if (s.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene*)s;
        }
        fallback = (UIWindowScene*)s;
    }
    return fallback;
}

// Nudge the scene to landscape if needed. Retries a few times since the scene
// can lag window creation on iOS 26.
static void SohIos_EnsureLandscape(UIWindow* window, int attempt) {
    UIWindowScene* scene = SohIos_ActiveScene();
    if (scene == nil && attempt < 20) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ SohIos_EnsureLandscape(window, attempt + 1); });
        return;
    }
    if (scene == nil) {
        return;
    }
    if (window.windowScene != scene) {
        window.windowScene = scene;
    }
    SohIos_GlueWindowToScene(window, scene);
    UIInterfaceOrientation o = scene.interfaceOrientation;
    if (o == UIInterfaceOrientationLandscapeLeft || o == UIInterfaceOrientationLandscapeRight) {
        return; // already landscape
    }
    if (@available(iOS 16.0, *)) {
        UIWindowSceneGeometryPreferencesIOS* prefs = [[UIWindowSceneGeometryPreferencesIOS alloc]
            initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscape];
        [scene requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError* e) {
            NSLog(@"[SohIosShell] landscape request failed: %@", e);
        }];
        [window.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
    }
}

// Region probe for the bridge `stickregion` command. MAIN THREAD ONLY.
// Returns 1/0 for in/out of the stick spawn region, -2 if no overlay found.
@interface SohIosTouchOverlay (SohStickProbe)
- (BOOL)pointInStickRegion:(CGPoint)p; // defined in the main @implementation
- (NSString*)hideProbe:(NSArray<NSString*>*)a;
- (int)sohSynthStick:(int)phase at:(CGPoint)p;
- (BOOL)sohSynthButton:(NSString*)label down:(BOOL)down;
@end

int SohIos_ProbeStickRegion(CGFloat x, CGFloat y, CGSize* outBounds) {
    for (UIWindow* w in UIApplication.sharedApplication.windows) {
        UIView* root = w.rootViewController.view ?: w;
        for (UIView* v in root.subviews) {
            if ([v isKindOfClass:SohIosTouchOverlay.class]) {
                if (outBounds != NULL) {
                    *outBounds = v.bounds.size;
                }
                return [(SohIosTouchOverlay*)v pointInStickRegion:CGPointMake(x, y)] ? 1 : 0;
            }
        }
    }
    return -2;
}

// Bridge `hideprobe` backend. Dispatches to the main thread (UIKit) and
// polls, mirroring stickregion.
NSString* SohIos_LayoutHideProbe(NSArray<NSString*>* args) {
    __block NSString* out = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* r = @"err no overlay";
        for (UIWindow* w in UIApplication.sharedApplication.windows) {
            UIView* root = w.rootViewController.view ?: w;
            for (UIView* v in root.subviews) {
                if ([v isKindOfClass:SohIosTouchOverlay.class]) {
                    r = [(SohIosTouchOverlay*)v hideProbe:args];
                    break;
                }
            }
        }
        out = r;
    });
    for (int i = 0; i < 200 && out == nil; i++) {
        usleep(10 * 1000);
    }
    return out ?: @"err timeout";
}

// VR R3 (design ruling): the parked window's UIKit touch chips sit ABOVE the VR
// curtain, so in VR a small cluster of flat-screen controls floats in the
// middle of the world. They are hidden on VR entry and restored on exit — the
// ornament (a separate SwiftUI surface) is untouched and keeps owning Exit.
// `hidden` is idempotent and safe from any thread.
static int sSohIosTouchHidden = 0;

static SohIosTouchOverlay* SohIos_FindTouchOverlay(void) {
    for (UIWindow* w in UIApplication.sharedApplication.windows) {
        UIView* root = w.rootViewController.view ?: w;
        for (UIView* v in root.subviews) {
            if ([v isKindOfClass:SohIosTouchOverlay.class]) {
                return (SohIosTouchOverlay*)v;
            }
        }
    }
    return nil;
}

// Perf round instruments (D15), MAIN THREAD ONLY: the bridge's synthetic
// stick finger and button presses, and the overlay view for `overlayshot`.
int SohIos_SynthStick(int phase, CGFloat x, CGFloat y) {
    SohIosTouchOverlay* o = SohIos_FindTouchOverlay();
    return o == nil ? -2 : [o sohSynthStick:phase at:CGPointMake(x, y)];
}
int SohIos_SynthButton(NSString* label, int down) {
    SohIosTouchOverlay* o = SohIos_FindTouchOverlay();
    return o == nil ? -2 : ([o sohSynthButton:label down:down ? YES : NO] ? 1 : 0);
}
UIView* SohIos_TouchOverlayView(void) {
    return SohIos_FindTouchOverlay();
}

void SohIos_SetTouchControlsHidden(int hidden) {
    sSohIosTouchHidden = hidden ? 1 : 0;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SohIos_SetTouchControlsHidden(hidden); });
        return;
    }
    UIView* v = SohIos_FindTouchOverlay();
    if (v != nil) {
        v.hidden = hidden ? YES : NO;
    }
}

// Bridge/suite probe: 1 = the touch layer is hidden, 0 = visible, -1 = the
// overlay does not exist yet (pre-onboarding). Reads the live view when it can
// so the assert cannot pass on the shell's intent alone.
int SohIos_TouchControlsHiddenState(void) {
    if (NSThread.isMainThread) {
        UIView* v = SohIos_FindTouchOverlay();
        return (v == nil) ? -1 : (v.hidden ? 1 : 0);
    }
    // Bridge thread: hop to UIKit and poll, mirroring the hideprobe pattern.
    __block int out = -2;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView* v = SohIos_FindTouchOverlay();
        out = (v == nil) ? -1 : (v.hidden ? 1 : 0);
    });
    for (int i = 0; i < 200 && out == -2; i++) {
        usleep(10 * 1000);
    }
    return (out == -2) ? sSohIosTouchHidden : out;
}

static void SohIos_InstallOverlay(UIWindow* window) {
    // Add the touch overlay above SDL's Metal view, tracking the window bounds.
    for (UIView* v in window.subviews) {
        if ([v isKindOfClass:SohIosTouchOverlay.class]) {
            return; // already installed
        }
    }
    UIView* host = window.rootViewController.view ?: window;
    SohIosTouchOverlay* overlay = [[SohIosTouchOverlay alloc] initWithFrame:host.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [host addSubview:overlay];
#if TARGET_OS_VISION
    // Claim gamepad events app-wide: visionOS otherwise routes pad input to
    // the gaze-and-pinch UI layer and GCController/SDL sees a dead pad
    // (VISION-PRO-GUIDE 1.3).
    if (@available(visionOS 2.0, *)) {
        GCEventInteraction* padClaim = [GCEventInteraction new];
        padClaim.handledEventTypes = GCUIEventTypeGamepad;
        [host addInteraction:padClaim];
        NSLog(@"[SohIosShell] GCEventInteraction gamepad claim installed");
    }
    // An app with an EMPTY Documents dir is invisible in the Files app —
    // seed a readme so the user has a drop target for the ROM/o2r
    // (VISION-PRO-GUIDE 1.5).
    {
        NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString* readme = [docs stringByAppendingPathComponent:@"DROP-ROM-OR-O2R-HERE.txt"];
        if (![NSFileManager.defaultManager fileExistsAtPath:readme]) {
            [@"Drop your Ocarina of Time ROM (.z64) or an extracted oot.o2r here,\n"
              "then relaunch Ship of Harkinian.\n"
                writeToFile:readme atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
#endif
    NSLog(@"[SohIosShell] touch overlay installed (%.0fx%.0f)", host.bounds.size.width, host.bounds.size.height);
    SohIos_AttachVirtualPad();
    SohIos_ScheduleSelfTest();
}

// The overlay would eat the extractor popups' taps (the stick zone overlaps
// them), and it's useless before game data exists — so install it only once
// an extracted archive is present (poll; extraction can take a while).
static void SohIos_InstallOverlayWhenReady(UIWindow* window, int attempt) {
    if (SohIos_DocumentsHasExt(@[ @"o2r" ])) {
        SohIos_InstallOverlay(window);
        return;
    }
    if (attempt < 1200) { // up to ~20 min of onboarding time
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{ SohIos_InstallOverlayWhenReady(window, attempt + 1); });
    }
}

void SohIos_OnWindowCreated(struct SDL_Window* sdlWindow) {
    gSdlWindow = sdlWindow;
    // Not overlay-dependent — must be live during onboarding too (a crash or
    // remote-debug need can precede game data existing).
    SohIos_InstallCrashHandler();
    SohIos_StartConsoleBridge(NO);
    SohIos_InstallConfigPersist(); // flush CVars on resign (swipe-kill safety)
    dispatch_async(dispatch_get_main_queue(), ^{ SohIos_InstallBackgroundReconciler(); });
    SohIos_SeedDefaultsOnce();     // per-device fidelity defaults, first run only
#if TARGET_OS_VISION
    {
        // Trap C4 / spec D10: a leftover VR CVar stash means the last
        // session died with VR overrides live. Restore BEFORE the game reads
        // anything, and load the persisted VR settings for this launch.
        extern void SohVR_StashRestoreOnLaunch(void);
        extern void SohVR_SettingsApply(void);
        SohVR_StashRestoreOnLaunch();
        SohVR_SettingsApply();
        // VR R16-D: adopt the PSVR2 Sense pair at LAUNCH, not at VR entry.
        // Discovery is pure GameController — no ARKit, no immersive space, no
        // authorization round trip — so it can and must run in the flat window,
        // which is where the user uses the pair most. The per-frame read is pumped
        // from SohVRSense_WritePad; see the note there.
        extern void SohSense_StartInput(void);
        SohSense_StartInput();
    }
#endif
    SDL_SetEventFilter(SohIos_EventFilter, NULL); // spaghetti:// deep links
    // Input environment, first lines of the trace: which device, which pads,
    // and whether a hardware keyboard is attached — the last one decides
    // which of SDL's UIKit keyboard routes was even live on the reporter's
    // iPad (pressesBegan: is skipped whenever a GCKeyboard exists).
    NSDictionary* info = NSBundle.mainBundle.infoDictionary;
    SohIos_Trace(@"soh %@ (build %@) on %@ %@", info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"],
                 UIDevice.currentDevice.model, UIDevice.currentDevice.systemVersion);
    SohIos_Trace(@"hardware keyboard attached: %@", GCKeyboard.coalescedKeyboard != nil ? @"YES" : @"no");
    SohIos_Trace(@"controllers: %@",
                 GCController.controllers.count
                     ? [[GCController.controllers valueForKey:@"vendorName"] componentsJoinedByString:@", "]
                     : @"(none yet)");
    UIWindow* window = SohIos_GetSDLWindow(sdlWindow);
    if (window == nil) {
        NSLog(@"[SohIosShell] no UIKit window for SDL window");
        return;
    }
    gShellWindow = window; // D7: game-driven onboarding needs it
    dispatch_async(dispatch_get_main_queue(), ^{
        SohIos_InstallSceneDelegate(); // spaghetti:// URL delivery (scene-routed)
        SohIos_EnsureLandscape(window, 0);
        // D7: onboarding is game-driven (overlay 0017 v2 calls
        // SohIos_RunRomOnboarding when mk64.o2r is missing) — no self-timed
        // alert, so exactly ONE first-run dialog can exist.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{ SohIos_InstallOverlayWhenReady(window, 0); });
    });
}
