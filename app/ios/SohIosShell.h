// SohIosShell — the iOS app-shell that grafts onto SDL's UIWindow.
// Lives in the Shipwright-ios repo (NOT vendor); added to the soh target by
// overlay 0012. LUS calls SohIos_OnWindowCreated after SDL_CreateWindow.
#ifndef SOH_IOS_SHELL_H
#define SOH_IOS_SHELL_H

#ifdef __cplusplus
extern "C" {
#endif

struct SDL_Window;

// VR R16-A (F4) — THE PER-FRAME SNAPSHOT.
//
// The eye matrices were already latched once per host frame and read by both
// eye passes from an engine-local copy. NOTHING ELSE the frame is drawn with
// was: the sky's per-eye vertical shift was read LIVE, inside each eye pass,
// out of a global the compositor rewrites at 90-120 Hz — so eye 0's sky was
// placed for head pose T and eye 1's for T+k, inside a frame whose matrices
// came from T-m. Stereo-inconsistent, motion-correlated, and invisible to
// every pair rule because it is baked into the pixels while both eyes carry
// the same pose tag. This struct is the fix: ONE copy per frame, acquired
// once, read by everything.
//
// Per-eye fields go in the arrays (R16-B adds the clouds' per-eye sprite
// placement here); whole-frame fields stay scalar.
typedef struct {
    unsigned int id;        // == the pose frame id; 0 means nothing published
    float eyeM[32];         // both eyes' A*V*P, eye 0 then eye 1
    float skyShift[2];      // per eye, from THIS id's matrices
    float skyPxPerBam;      // the sprite mapping 0051 builds the sky with
    float skyPxCenter;
    int eyeYawBam;          // composed eye yaw, MK64 binary angles
    float eyePosGame[3];    // composed eye position, game units
    float eyeFovDeg;
    float eyePitchDeg;
    int worldActive;        // the frame's own answer, not a live re-read
    // VR R16-B — the clouds, per eye. M1/M2 in docs/vr-r16-diagnosis/clouds.md:
    // MK64 builds ONE sprite layout per game frame and both eye passes replay
    // it, so the layout has to be built in ONE reference frustum (eye 0's) and
    // remapped into the other eye by the pass that draws it. skyTanSum/skySpan
    // ARE that reference frustum; skyEyeDx/skyEyeSx are the exact eye-0 -> eye-e
    // NDC remap (ndc' = sx*ndc + dx); skyTanLo/Hi are the UNION of both eyes'
    // visible tangent range, because a sprite culled out of one eye only is a
    // stereo-rivalry bug of its own.
    float skyTanSum;        // tL + tR of eye 0 -- the layout's reference
    float skySpan;          // tR - tL of eye 0
    float skyEyeDx[2];      // per eye: eye-0 NDC -> this eye's NDC, offset
    float skyEyeSx[2];      //                                      scale
    float skyTanLo;         // union visibility bounds, in eye-0 tangents
    float skyTanHi;
    float skyRollRad[2];    // head roll about the eye forward vs game up (step 4)
    float skySpanY;         // tT - tB of eye 0 (roll is composed in tangent space)
    // VR R17-A item 1 — THE SEAT, and the segment it must be interpolated
    // along. seatGame is the world-space point the eye matrices above were
    // composed around; seatPrevDelta is (previous game frame's seat) minus it,
    // so the seat at the walk's own interpolation factor t is
    // seatGame + seatPrevDelta * (1 - t). Both in GAME units, because that is
    // the space a pre-multiplied world transform acts in. seatSrc says which
    // base the shell used (1 = the kart's own pose, 0 = the chase camera).
    float seatGame[3];
    float seatPrevDelta[3];
    int seatSrc;
    // VR R18-A — THE BASE THE MATRICES ABOVE WERE BUILT FROM. seatGame is the
    // seat point; seatBase is the raw pose it was derived from (the kart's
    // position, or the chase camera's eye in the camera-seated modes) AS THE
    // COMPOSITOR READ IT, and seatBaseFrame the game frame that pose was
    // exported on (0 for the camera). The compositor composes at 60-90 Hz and
    // the walks run on the game thread right after the export, so a walk can
    // latch a snapshot composed from the PREVIOUS game frame's pose. R17-A's
    // correction assumed the base was always the current export; 0044 rev15
    // corrects by (current export - seatBase) instead of assuming it is zero.
    float seatBase[3];
    unsigned int seatBaseFrame;
} SohVRFrameSnapshot;

// The flat sky payload SohIosVR_AcquireFrame copies out for the eye passes.
// A flat array rather than the struct itself because the consumer is a patch
// into libultraship's interpreter.cpp, which declares the rendezvous extern "C"
// and must not grow a dependency on this header. Indices are named on BOTH
// sides and asserted equal by the suite's snapshot line.
// R17-A widened this from 16 to 24: it is the FRAME payload, not only the
// sky's half of it (the name is kept because it is the contract's name on both
// sides of the interface and renaming it in two files buys nothing).
#define SOHVR_SKY_SLOTS      28
#define SOHVR_SKY_SHIFT0     0   /* per-eye vertical NDC shift (R14) */
#define SOHVR_SKY_SHIFT1     1
#define SOHVR_SKY_DX0        2   /* per-eye horizontal affine (R16-B step 2) */
#define SOHVR_SKY_DX1        3
#define SOHVR_SKY_SX0        4
#define SOHVR_SKY_SX1        5
#define SOHVR_SKY_ROLL0      6   /* per-eye roll, radians (R16-B step 4) */
#define SOHVR_SKY_ROLL1      7
#define SOHVR_SKY_TANSUM     8   /* the reference frustum the layout was built in */
#define SOHVR_SKY_SPAN       9
#define SOHVR_SKY_YAWBAM    10   /* THIS frame's eye yaw, for the step-3 dtheta */
#define SOHVR_SKY_TANLO     11
#define SOHVR_SKY_TANHI     12
#define SOHVR_SKY_SPANY     13   /* vertical span, for the roll's tangent-space compose */
/* VR R17-A item 1: the seat, and the segment it is interpolated along. */
#define SOHVR_SEAT_DX0      16   /* previous game frame's seat MINUS this one */
#define SOHVR_SEAT_DX1      17
#define SOHVR_SEAT_DX2      18
#define SOHVR_SEAT_SRC      19   /* 1 = the kart's pose, 0 = the chase camera */
#define SOHVR_SEAT_X        20   /* the seat the eye matrices were composed at */
#define SOHVR_SEAT_Y        21
#define SOHVR_SEAT_Z        22
/* VR R18-A: the raw pose the seat was derived from, and its game frame. */
#define SOHVR_SEAT_BX       24
#define SOHVR_SEAT_BY       25
#define SOHVR_SEAT_BZ       26
#define SOHVR_SEAT_BF       27

// Compositor side: publish the frame just composed (one mutex, one memcpy).
void SohIosVR_PublishFrame(const SohVRFrameSnapshot* snap);
// Engine side: latch the published snapshot at the head of the host frame and
// copy out the two things the eye passes need. Returns the id (0 = nothing).
unsigned int SohIosVR_AcquireFrame(float outM[32], float outSky[SOHVR_SKY_SLOTS]);

// Called (once) right after LUS creates its SDL window on iOS. Grafts the
// window onto the active UIWindowScene, forces landscape, and installs the
// on-screen touch-control overlay.
void SohIos_OnWindowCreated(struct SDL_Window* window);

#ifdef __cplusplus
}
#endif

#endif // SOH_IOS_SHELL_H
