// SohSense.m — PSVR2 Sense controllers on visionOS (VR-spec D13 / D9), and
// the physical item gestures that ride on their poses.
//
// The plumbing is sm64coopdx-ios's shipped A10 recipe, ported wholesale — its
// ordering is not cosmetic, every deviation from it cost that project a device
// round:
//
//   plist declaration (GCSupportedGameControllers / SpatialGamepad)
//     -> enumerate GCController.controllers + Did{Connect,Disconnect} observers
//     -> register EVERY controller for tracking (the load takes a GCDevice, so
//        it must NOT sit behind the spatial-category gate)
//     -> ar_session_request_authorization(accessory_tracking) FIRST, devices
//        that arrive meanwhile parked and drained on ALLOWED
//     -> ar_accessory_load_from_device (deduped, exactly one 2 s retry)
//     -> accessories -> configuration -> provider -> ar_session_run on the SAME
//        session the authorization was granted on
//     -> per frame: get_latest_anchors + enumerate, chirality per anchor with
//        the accessory's INHERENT chirality as the fallback
//     -> release everything not seen this poll, and on disconnect.
//
// What is OURS rather than the donor's: the kart-native fixed layout (D13), the
// physical item gestures, the wrist mirror, and per-hand haptics (the donor's
// haptics are a stub — there was nothing to copy).
//
// THREADING, per the donor's discipline: GameController callbacks land on the
// main queue, ARKit callbacks on whatever thread ARKit picks, the anchor poll
// runs on the compositor thread and the pad read runs on the ENGINE thread.
// Plain float storage, `volatile int` validity flags published LAST, no locks.
//
// SIMULATOR: no spatial hardware exists, so nothing adopts, nothing loads, the
// provider is never built and the poll early-returns — `vr hands` reports it as
// "absent" rather than failing. The whole gesture layer above the poses is
// still fully exercised there through injection (`vr hand ...`).

#import "SohSense.h"

#import <CoreHaptics/CoreHaptics.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <stdatomic.h>

#define SOHSENSE_MAX_ACCESSORIES 4

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

// Poses live in the ARKit origin frame, exactly like the head pose the VR loop
// queries — same frame, no conversion. `valid` is published LAST (trap 32).
static simd_float4x4 sHandWorld[SOHSENSE_HANDS] = { { { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } } },
                                                    { { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } } } };
static simd_float3 sHandVel[SOHSENSE_HANDS];
static volatile int sHandValid[SOHSENSE_HANDS] = { 0, 0 };
static volatile int sHandHeld[SOHSENSE_HANDS] = { 0, 0 };   // is a hand holding it
static volatile int sHandInjected[SOHSENSE_HANDS] = { 0, 0 };
static int sVelInjected[SOHSENSE_HANDS] = { 0, 0 };

// Buttons, as a per-hand bitmask so the pad read and the dump agree on one
// vocabulary. The injection path writes the same bits the hardware read does,
// which is what makes the gesture asserts meaningful.
enum {
    SOHSENSE_BTN_FACE_A = 1 << 0,  // Cross / Square
    SOHSENSE_BTN_FACE_B = 1 << 1,  // Circle / Triangle
    SOHSENSE_BTN_TRIGGER = 1 << 2, // L2 / R2
    SOHSENSE_BTN_GRIP = 1 << 3,    // L1 / R1
    SOHSENSE_BTN_STICK = 1 << 4,   // thumbstick click
    SOHSENSE_BTN_MENU = 1 << 5,    // Menu / Create
};
static volatile uint32_t sHandBtn[SOHSENSE_HANDS];
static float sHandStickX[SOHSENSE_HANDS], sHandStickY[SOHSENSE_HANDS];
static volatile int sBtnInjected = 0; // any injected button/stick state is live

// Head pose, republished every VR frame; the gestures are all expressed
// relative to it (a throw is "away from me", not "along world -Z").
static simd_float4x4 sHeadWorld = { { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } } };
static int sHaveHead = 0;

// Discovery / authorization / load bookkeeping — every counter here exists
// because the donor's decision table (loads 0 / fails>0 / polls 0 / anchors 0)
// is the only way to tell four very different failures apart from a headset.
static GCController* sPad[SOHSENSE_HANDS];
static int sAuthState = 0; // 0 not asked or pending, 1 allowed, -1 denied
static bool sAuthAsked = false;
static int sLoadOK = 0, sLoadFail = 0, sLoadFailCode = 0;
static int sLastAnchorCount = 0;
static unsigned int sPollCount = 0;
static int sLoggedAnchors = 0;
static int sStarted = 0;
static int sDoffEvents = 0;
static int sCtlSeen = 0;    // controllers adopted since start
static int sSpatialSeen = 0;

// VR R16-D — THE FLAT FOLD. Until this round the whole Sense layer was owned by
// the VR immersive loop: `sStarted` was the writer's guard AND the lifecycle
// flag, and the only per-frame hardware read lived in SohSense_Update, which
// only SohVR_Immersive_Run calls. So in 2D and in the 3D panel the pair fell
// through to SDL's MFi auto-mapper, which recognises exactly three of a spatial
// controller's element names (`Button A`/`Button B`/`Button Menu`) — the user's
// "only the A (gas) button works. Nothing else."
//
// The split is: DISCOVERY + BUTTONS (`sInputStarted`, live in every mode, no
// ARKit and no authorization in its path) vs. POSES + VR FRAME CONTROLS
// (`sStarted`, still VR-only, because sohsense_frame_controls cycles VR views
// and recentres the panel and must never run in flat).
static int sInputStarted = 0;
// The flat half's live test, in ONE place so the red control cannot switch off
// three of the four things it has to switch off.
#define SOHSENSE_FLAT_LIVE() (sInputStarted && sT.flatFold >= 0.5f)
// Every adopted spatial controller, whether or not ARKit has told us which hand
// it is. `sPad[]` is filled ONLY by the accessory load-completion handler
// (chirality), which never runs outside an immersive space — so in flat mode
// this list is the only handle on the hardware. See sohsense_read_hardware's
// hand-agnostic fold.
static GCController* sSpatial[SOHSENSE_MAX_ACCESSORIES];
static int sSpatialCount = 0;

API_AVAILABLE(visionos(26.0))
static ar_accessory_t sAccessory[SOHSENSE_MAX_ACCESSORIES];
static GCController* sAccessoryDevice[SOHSENSE_MAX_ACCESSORIES];
static int sAccessoryCount = 0;
API_AVAILABLE(visionos(26.0))
static ar_accessory_tracking_provider_t sProvider = NULL;
API_AVAILABLE(visionos(26.0))
static ar_session_t sSession = NULL;
static bool sProviderDirty = false;
static GCController* sPending[SOHSENSE_MAX_ACCESSORIES];
static int sPendingCount = 0;

// ---------------------------------------------------------------------------
// Tunables. EVERY gesture number is here and reachable from `vr set`, because
// every one of them is a guess until the user has thrown a banana in the headset.
// ---------------------------------------------------------------------------
static struct {
    float itemHand;   // 0 = left carries the item, 1 = right
    float throwMin;   // m/s below which the gesture does not override MK64
    float throwDot;   // |cos| dead zone: how "along the axis" a throw must be
    float throwHold;  // seconds the vote stays up for the engine thread to read
    float trailOn;    // 1 = the trailing-hold gesture is live
    float trailBack;  // metres BEHIND the head plane that counts as trailing
    float trailDown;  // metres below eye level that also counts as trailing
    float itemInHand; // 1 = draw the armed item at the item hand
    float itemScale;  // metres: the held item's billboard half-size * 2
    float wristOn;    // 1 = the wrist mirror gesture is live
    float wristFace;  // dot(wrist up, wrist->head): how face-up "face-up" is
    float wristFaceX; // ... the EXIT threshold (hysteresis, no flicker)
    float wristGaze;  // dot(gaze, head->wrist): how gaze-adjacent it must be
    float wristGazeX; // ... the exit threshold
    float wristDist;  // metres: the wrist must be within arm's reach
    float wristDistX; // ... the exit distance
    float wristUp;    // metres: pane offset along the wrist's up axis
    float wristScale; // pane size as a fraction of its distance
    float haptics;    // 0 off, 1 on
    float hapticGain; // scales every burst
    // R16-D's RED CONTROL (trap D11). 1 = the flat fold runs (shipping); 0
    // restores the 1.0.0.12 behaviour EXACTLY — no flat pump, the writer gated
    // on sStarted alone, and FlatFoldLive 0 so the touch overlay comes back. It
    // is what makes "the fold is why the pad has bits" falsifiable on ONE
    // binary instead of on two. Session only; the suite asserts it ships at 1.
    float flatFold;
    // R19 item 1's INJECTOR (was R18-B's gpR3): 1 = "the gamepad's LEFT
    // thumbstick button is held", ORed into the real GCController read.
    // Session only, ships 0.
    float gpL3;
    // ...and the leak mask's RED/GREEN: N64 bits to treat as "bound to L3"
    // on top of whatever LUS's mapping CVars say. Session only, ships 0.
    float gpL3Bind;
    // R19 item 1's RED CONTROL: 1 = "the RIGHT thumbstick button is held".
    // R3 does nothing in VR any more; this only feeds gp_r3/gp_r3_edges so the
    // suite can prove an R3 press reaches the shell and toggles nothing.
    float gpR3;
} sT = {
    .itemHand = 1.0f,     .throwMin = 1.2f,    .throwDot = 0.35f,  .throwHold = 0.30f, .trailOn = 1.0f,
    .trailBack = 0.10f,   .trailDown = 0.25f,  .itemInHand = 1.0f, .itemScale = 0.10f,
    .wristOn = 1.0f,      .wristFace = 0.65f,  .wristFaceX = 0.45f, .wristGaze = 0.80f,
    .wristGazeX = 0.65f,  .wristDist = 0.75f,  .wristDistX = 0.95f, .wristUp = 0.10f,
    .wristScale = 0.55f,  .haptics = 1.0f,     .hapticGain = 1.0f,  .flatFold = 1.0f,
};

// Gesture state (all edge detection lives HERE — trap C2: one edge detector,
// and nothing latched crosses a mode boundary because Start/Stop clear it).
static int sThrowsFwd = 0, sThrowsBack = 0, sThrowsPassed = 0;
static const char* sLastThrow = "none";
static float sLastThrowSpeed = 0.0f, sLastThrowDot = 0.0f;
static double sThrowVoteUntil = 0.0; // the vote's deadline (see the throw gesture)
static int sTrailActive = 0, sTrailEvents = 0;
static int sWristActive = 0, sWristEvents = 0;
static float sWristFaceNow = 0.0f, sWristGazeNow = 0.0f, sWristDistNow = 0.0f;
static float sTrailAlongNow = 0.0f, sTrailBelowNow = 0.0f;
static int sUpdates = 0, sWorldUpdates = 0;
static simd_float4x4 sWristPlane = { { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } } };
static int sItemVisible = 0;
static int sPrevArmed = 0, sPrevSpin = 0;
static int sPrevItemBtn = 0;
static int sHapticBursts = 0;

// Engine-side exports this file both reads and writes. gSohVRItemArmed is
// overlay 0053's export (MK64's armed item for player 1); gSohVRThrowDir is the
// gesture's answer, consumed at MK64's own forward/backward decision points
// (0051 rev3) — the game keeps making the decision, we only cast the vote it
// would otherwise read off the stick.
// DEFINED IN SohIosShell.m, not here: game code on EVERY target references
// them (0051 rev3's throw macros, 0053's export) and this file is visionOS-only.
extern volatile int gSohVRItemArmed;
extern volatile int gSohVRThrowDir;
volatile int gSohVRSenseActive = 0; // 1 = a Sense hand is driving the pad
extern volatile unsigned int gSohVRL3Masked; // R19 item 1 (SohIosShell.m; was R3)
extern volatile unsigned int gSohVRL3Bits;

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

static simd_float3 sohsense_pos(simd_float4x4 m) {
    return simd_make_float3(m.columns[3].x, m.columns[3].y, m.columns[3].z);
}

static simd_float3 sohsense_norm(simd_float3 v) {
    float l = simd_length(v);
    return (l > 1e-6f) ? (v / l) : simd_make_float3(0.0f, 0.0f, -1.0f);
}

// The head's forward, flattened to horizontal: a throw is judged against where
// you are FACING, not where you are looking up or down.
static simd_float3 sohsense_head_fwd(void) {
    simd_float3 f = simd_make_float3(-sHeadWorld.columns[2].x, 0.0f, -sHeadWorld.columns[2].z);
    if (simd_length(f) < 1e-4f) {
        // Looking straight up or down: fall back to the head's own up-projection
        // rather than returning a zero vector the dot products would divide by.
        f = simd_make_float3(-sHeadWorld.columns[1].x, 0.0f, -sHeadWorld.columns[1].z);
    }
    return sohsense_norm(f);
}

// ---------------------------------------------------------------------------
// Haptics (ours — the donor shipped a stub)
// ---------------------------------------------------------------------------

static CHHapticEngine* sHaptic[SOHSENSE_HANDS];

static void sohsense_haptics_release(int hand) {
    if (sHaptic[hand] != nil) {
        [sHaptic[hand] stopWithCompletionHandler:nil];
        sHaptic[hand] = nil;
    }
}

void SohSense_Haptic(int hand, float intensity, float seconds) {
    if (hand < 0 || hand >= SOHSENSE_HANDS || sT.haptics < 0.5f || intensity <= 0.0f) {
        return;
    }
    GCController* c = sPad[hand];
    if (c == nil) {
        return;
    }
    intensity *= sT.hapticGain;
    intensity = (intensity < 0.0f) ? 0.0f : (intensity > 1.0f ? 1.0f : intensity);
    if (seconds < 0.01f) {
        seconds = 0.01f;
    }
    if (seconds > 1.0f) {
        seconds = 1.0f;
    }
    GCDeviceHaptics* h = c.haptics;
    if (h == nil) {
        return;
    }
    if (sHaptic[hand] == nil) {
        NSSet<GCHapticsLocality>* locs = h.supportedLocalities;
        GCHapticsLocality loc = (locs != nil && [locs containsObject:GCHapticsLocalityDefault])
                                    ? GCHapticsLocalityDefault
                                    : (GCHapticsLocality)(locs.anyObject ?: GCHapticsLocalityDefault);
        sHaptic[hand] = [h createEngineWithLocality:loc];
        if (sHaptic[hand] == nil) {
            return;
        }
        NSError* err = nil;
        [sHaptic[hand] startAndReturnError:&err];
        if (err != nil) {
            NSLog(@"[sense] haptic engine start failed (hand %d): %@", hand, err);
            sHaptic[hand] = nil;
            return;
        }
        // A haptic engine can be reclaimed at any time (focus, resources); the
        // handler drops ours so the next burst rebuilds instead of playing into
        // a dead engine.
        __block int h2 = hand;
        sHaptic[hand].stoppedHandler = ^(CHHapticEngineStoppedReason r) {
            (void)r;
            sHaptic[h2] = nil;
        };
    }
    CHHapticEventParameter* pi = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity
                                                                               value:intensity];
    CHHapticEventParameter* ps = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness
                                                                               value:0.7f];
    CHHapticEvent* ev = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                      parameters:@[ pi, ps ]
                                                    relativeTime:0.0
                                                        duration:seconds];
    NSError* err = nil;
    CHHapticPattern* pat = [[CHHapticPattern alloc] initWithEvents:@[ ev ] parameters:@[] error:&err];
    if (pat == nil) {
        return;
    }
    id<CHHapticPatternPlayer> player = [sHaptic[hand] createPlayerWithPattern:pat error:&err];
    if (player == nil) {
        return;
    }
    [player startAtTime:0 error:&err];
    sHapticBursts++;
}

void SohSense_HapticBoth(float intensity, float seconds) {
    SohSense_Haptic(SOHSENSE_LEFT, intensity, seconds);
    SohSense_Haptic(SOHSENSE_RIGHT, intensity, seconds);
}

// ---------------------------------------------------------------------------
// Authorization + accessory load (donor recipe, ported verbatim in shape)
// ---------------------------------------------------------------------------

API_AVAILABLE(visionos(26.0))
static void sohsense_load_device_retry(GCController* c, int attempt);

API_AVAILABLE(visionos(26.0))
static void sohsense_load_device(GCController* c) {
    sohsense_load_device_retry(c, 0);
}

API_AVAILABLE(visionos(26.0))
static void sohsense_load_device_retry(GCController* c, int attempt) {
    if (c == nil) {
        return;
    }
    // Dedupe by device identity: a device arrives twice — once queued behind the
    // authorization prompt, once from a later didConnect on a focus change.
    for (int i = 0; i < sAccessoryCount; i++) {
        if (sAccessoryDevice[i] == c) {
            return;
        }
    }
    ar_accessory_load_from_device(
        c, ^(id<GCDevice> device, bool successful, ar_error_t error, ar_accessory_t accessory) {
            (void)device;
            if (!successful || accessory == NULL) {
                sLoadFail++;
                long code = -1;
                CFStringRef desc = NULL;
                if (error != NULL) {
                    code = (long)ar_error_get_error_code(error);
                    CFErrorRef cfe = ar_error_copy_cf_error(error);
                    if (cfe != NULL) {
                        desc = CFErrorCopyDescription(cfe);
                        CFRelease(cfe);
                    }
                }
                sLoadFailCode = (int)code;
                NSLog(@"[sense] accessory load FAILED for '%@' (category '%@') code=%ld attempt=%d desc=%@",
                      c.vendorName, c.productCategory, code, attempt,
                      desc ? (__bridge NSString*)desc : @"(none)");
                if (desc != NULL) {
                    CFRelease(desc);
                }
                // ONE retry, 2 s later: accessory tracking is gated on the app
                // being focused, so a load issued during immersive-space entry
                // can fail for that alone. Both results are logged, so a retry
                // can never hide the first answer.
                if (attempt == 0) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                                       if (@available(visionOS 26.0, *)) {
                                           sohsense_load_device_retry(c, 1);
                                       }
                                   });
                }
                return;
            }
            if (sAccessoryCount >= SOHSENSE_MAX_ACCESSORIES) {
                NSLog(@"[sense] accessory table full — ignoring '%s'", ar_accessory_get_name(accessory));
                return;
            }
            ar_accessory_chirality_t ch = ar_accessory_get_inherent_chirality(accessory);
            sAccessory[sAccessoryCount] = accessory;
            sAccessoryDevice[sAccessoryCount] = c;
            sAccessoryCount++;
            sLoadOK++;
            sProviderDirty = true;
            // Chirality is available HERE, at load completion, before any
            // provider runs — and it is the only authority: GameController has
            // no chirality API at all.
            if (ch == ar_accessory_chirality_left) {
                sPad[SOHSENSE_LEFT] = c;
            } else if (ch == ar_accessory_chirality_right) {
                sPad[SOHSENSE_RIGHT] = c;
            }
            NSLog(@"[sense] accessory LOADED '%s' chirality=%s from '%@' (%d known)",
                  ar_accessory_get_name(accessory),
                  ch == ar_accessory_chirality_left ? "left"
                                                    : ch == ar_accessory_chirality_right ? "right" : "unspecified",
                  c.vendorName, sAccessoryCount);
        });
}

API_AVAILABLE(visionos(26.0))
static void sohsense_request_authorization(void) {
    if (sAuthAsked) {
        return;
    }
    sAuthAsked = true;
    if (sSession == NULL) {
        sSession = ar_session_create();
    }
    NSLog(@"[sense] requesting accessory-tracking authorization");
    ar_session_request_authorization(
        sSession, ar_authorization_type_accessory_tracking, ^(ar_authorization_results_t results, ar_error_t error) {
            __block int state = -1;
            if (results != NULL) {
                ar_authorization_results_enumerate_results(results, ^bool(ar_authorization_result_t r) {
                    if (ar_authorization_result_get_authorization_type(r) == ar_authorization_type_accessory_tracking) {
                        state = (ar_authorization_result_get_status(r) == ar_authorization_status_allowed) ? 1 : -1;
                    }
                    return true;
                });
            }
            sAuthState = state;
            NSLog(@"[sense] accessory-tracking authorization: %s%@", state == 1 ? "ALLOWED" : "DENIED",
                  error ? @" (with error)" : @"");
            if (state != 1) {
                return;
            }
            for (int i = 0; i < sPendingCount; i++) {
                sohsense_load_device(sPending[i]);
            }
            sPendingCount = 0;
        });
}

static void sohsense_register_device(GCController* c) {
    if (c == nil) {
        return;
    }
    if (@available(visionOS 26.0, *)) {
        sohsense_request_authorization();
        if (sAuthState == 1) {
            sohsense_load_device(c);
            return;
        }
        if (sAuthState == -1) {
            return; // denied: a load would only fail
        }
        if (sPendingCount < SOHSENSE_MAX_ACCESSORIES) {
            sPending[sPendingCount++] = c;
        }
    }
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

int SohSense_IsSpatialController(void* gcController) {
    GCController* c = (__bridge GCController*)gcController;
    if (c == nil) {
        return 0;
    }
    if (@available(visionOS 26.0, *)) {
        return [c.productCategory isEqualToString:GCProductCategorySpatialController] ? 1 : 0;
    }
    return 0;
}

static void sohsense_log_inventory(GCController* c) {
    NSLog(@"[sense] controller vendor='%@' category='%@'", c.vendorName, c.productCategory);
    NSLog(@"[sense]   buttons: %@", c.physicalInputProfile.buttons.allKeys);
    NSLog(@"[sense]   axes:    %@", c.physicalInputProfile.axes.allKeys);
    NSLog(@"[sense]   dpads:   %@", c.physicalInputProfile.dpads.allKeys);
    // Did the declaration survive CMake + Xcode plist processing into the built
    // product? One line closes that doubt permanently (donor trap 4) — and it is
    // the difference between "the pair is untrackable" and "we never asked".
    NSLog(@"[sense]   bundle GCSupportedGameControllers = %@",
          [NSBundle.mainBundle objectForInfoDictionaryKey:@"GCSupportedGameControllers"]);
}

static void sohsense_adopt(GCController* c) {
    if (c == nil) {
        return;
    }
    sCtlSeen++;
    sohsense_log_inventory(c);
    // Register EVERY controller for tracking, spatial or not: the load takes a
    // GCDevice, and hiding it behind the spatial gate is exactly the bug that
    // meant the donor never once asked the question.
    sohsense_register_device(c);
    if (!SohSense_IsSpatialController((__bridge void*)c)) {
        NSLog(@"[sense] '%@' is not a spatial controller — leaving it to the SDL path", c.productCategory);
        return;
    }
    sSpatialSeen++;
    // R16-D: keep the handle. Deduped — adopt runs both from the initial
    // enumeration and from GCControllerDidConnectNotification, and a controller
    // present at Start arrives on both routes on some launches.
    for (int i = 0; i < sSpatialCount; i++) {
        if (sSpatial[i] == c) {
            return;
        }
    }
    if (sSpatialCount < SOHSENSE_MAX_ACCESSORIES) {
        sSpatial[sSpatialCount++] = c;
    }
}

static void sohsense_forget(GCController* c) {
    if (c == nil) {
        return;
    }
    for (int i = 0; i < sPendingCount; i++) {
        if (sPending[i] != c) {
            continue;
        }
        for (int j = i; j < sPendingCount - 1; j++) {
            sPending[j] = sPending[j + 1];
        }
        sPending[--sPendingCount] = nil;
        break;
    }
    for (int i = 0; i < sAccessoryCount; i++) {
        if (sAccessoryDevice[i] != c) {
            continue;
        }
        for (int j = i; j < sAccessoryCount - 1; j++) {
            sAccessory[j] = sAccessory[j + 1];
            sAccessoryDevice[j] = sAccessoryDevice[j + 1];
        }
        sAccessoryCount--;
        sAccessory[sAccessoryCount] = NULL;
        sAccessoryDevice[sAccessoryCount] = nil;
        sProviderDirty = true;
        break;
    }
    for (int h = 0; h < SOHSENSE_HANDS; h++) {
        if (sPad[h] == c) {
            sPad[h] = nil;
            sohsense_haptics_release(h);
            NSLog(@"[sense] %s controller disconnected", h == SOHSENSE_LEFT ? "LEFT" : "RIGHT");
        }
    }
    // R16-D: and the flat fold's handle goes with it, or the flat fold would go
    // on reading a dead GCController and SohSense_FlatFoldLive() would keep
    // hiding the touch controls after the pair was put down.
    for (int i = 0; i < sSpatialCount; i++) {
        if (sSpatial[i] != c) {
            continue;
        }
        for (int j = i; j < sSpatialCount - 1; j++) {
            sSpatial[j] = sSpatial[j + 1];
        }
        sSpatial[--sSpatialCount] = nil;
        break;
    }
    // RELEASE EVERYTHING (spec D9 / donor's rule): a controller that vanishes
    // mid-press must not leave a button held or a hand frozen in mid-air. This is
    // also trap C2's rule at a device boundary rather than a mode boundary.
    SohSense_InjectDoff();
}

// ---------------------------------------------------------------------------
// Provider + per-frame anchor poll
// ---------------------------------------------------------------------------

API_AVAILABLE(visionos(26.0))
static void sohsense_rebuild_provider(void) {
    sProviderDirty = false;
    sProvider = NULL;
    sHandValid[SOHSENSE_LEFT] = sHandValid[SOHSENSE_RIGHT] = 0;
    if (sAccessoryCount == 0) {
        return;
    }
    ar_accessories_t set = ar_accessories_create();
    for (int i = 0; i < sAccessoryCount; i++) {
        if (sAccessory[i] != NULL) {
            ar_accessories_add_accessory(set, sAccessory[i]);
        }
    }
    ar_accessory_tracking_configuration_t cfg = ar_accessory_tracking_configuration_create();
    ar_accessory_tracking_configuration_set_accessories(cfg, set);
    // The SAME session the authorization was granted on. A fresh one is
    // unauthorized again — and it is a DEDICATED session, not the VR loop's
    // world-tracking one: accessories load and disconnect asynchronously, and a
    // failure there must never disturb the tracking the whole mode depends on.
    if (sSession == NULL) {
        sSession = ar_session_create();
    }
    sProvider = ar_accessory_tracking_provider_create(cfg);
    ar_data_providers_t providers = ar_data_providers_create_with_data_providers(sProvider, NULL);
    ar_session_run(sSession, providers);
    NSLog(@"[sense] accessory tracking running with %d accessory(s)", sAccessoryCount);
}

// The VR loop creates its own world-tracking session; this returns a provider
// set the loop can extend if a future round decides to consolidate. Today the
// accessory provider runs on its own session (see above), so this simply hands
// back the world-tracking set unchanged — the seam exists so consolidating is a
// one-line change rather than a restructure.
ar_data_providers_t SohSense_MakeProviders(ar_world_tracking_provider_t wtp) {
    return ar_data_providers_create_with_data_providers(wtp, NULL);
}

static void sohsense_poll_anchors(void) {
    if (@available(visionOS 26.0, *)) {
        if (sProviderDirty) {
            sohsense_rebuild_provider();
        }
        if (sProvider == NULL) {
            return;
        }
        ar_accessory_anchors_t anchors = ar_accessory_tracking_provider_get_latest_anchors(sProvider);
        if (anchors == NULL) {
            return;
        }
        size_t n = ar_accessory_anchors_get_count(anchors);
        sLastAnchorCount = (int)n;
        __block int seenMask = 0;
        __block int logThis = 0;
        if (sLoggedAnchors < 5 || (sPollCount % 900) == 0) {
            logThis = 1;
            sLoggedAnchors++;
        }
        sPollCount++;
        ar_accessory_anchors_enumerate_anchors(anchors, ^bool(ar_accessory_anchor_t anchor) {
            bool tracked = ar_accessory_anchor_is_tracked(anchor);
            ar_accessory_chirality_t ch = ar_accessory_anchor_get_held_chirality(anchor);
            simd_float4x4 xf = ar_accessory_anchor_get_origin_from_anchor_transform(anchor);
            if (logThis) {
                NSLog(@"[sense]   anchor tracked=%d held=%d chirality=%s pos=(%.3f, %.3f, %.3f)", tracked,
                      ar_accessory_anchor_is_held(anchor),
                      ch == ar_accessory_chirality_left ? "left"
                                                        : ch == ar_accessory_chirality_right ? "right" : "unspecified",
                      (double)xf.columns[3].x, (double)xf.columns[3].y, (double)xf.columns[3].z);
            }
            if (!tracked) {
                return true;
            }
            // held_chirality is "which hand is holding it NOW" and can be
            // unspecified (a controller on a table). Fall back to the
            // accessory's inherent chirality; never guess from position.
            int hand = -1;
            if (ch == ar_accessory_chirality_left) {
                hand = SOHSENSE_LEFT;
            } else if (ch == ar_accessory_chirality_right) {
                hand = SOHSENSE_RIGHT;
            } else {
                ar_accessory_t acc = ar_accessory_anchor_get_accessory(anchor);
                if (acc != NULL) {
                    ar_accessory_chirality_t inh = ar_accessory_get_inherent_chirality(acc);
                    if (inh == ar_accessory_chirality_left) {
                        hand = SOHSENSE_LEFT;
                    } else if (inh == ar_accessory_chirality_right) {
                        hand = SOHSENSE_RIGHT;
                    }
                }
            }
            if (hand < 0 || sHandInjected[hand]) {
                return true; // injection wins: the sim asserts must be stable
            }
            sHandWorld[hand] = xf;
            // Velocity from the anchor, not from differencing positions: ARKit
            // already has it and a hand-rolled delta rides our own poll jitter.
            sHandVel[hand] = ar_accessory_anchor_get_velocity(anchor);
            sHandHeld[hand] = ar_accessory_anchor_is_held(anchor) ? 1 : 0;
            sHandValid[hand] = 1; // published LAST
            seenMask |= (1 << hand);
            return true;
        });
        for (int h = 0; h < SOHSENSE_HANDS; h++) {
            if (!(seenMask & (1 << h)) && !sHandInjected[h]) {
                sHandValid[h] = 0;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Button read (hardware) — the FIXED kart layout's raw half
// ---------------------------------------------------------------------------

static bool sohsense_btn(GCController* c, NSString* name) {
    if (c == nil) {
        return false;
    }
    GCControllerButtonInput* b = c.physicalInputProfile.buttons[name];
    return b ? b.isPressed : false;
}

// Name-agnostic fallback so a naming surprise degrades instead of killing the
// pad (donor trap 26 — guessing `GCInputLeftTrigger` cost that project its Z).
static bool sohsense_btn_like(GCController* c, NSString* needle) {
    if (c == nil) {
        return false;
    }
    for (NSString* k in c.physicalInputProfile.buttons.allKeys) {
        if ([k rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) {
            GCControllerButtonInput* b = c.physicalInputProfile.buttons[k];
            if (b != nil && b.isPressed) {
                return true;
            }
        }
    }
    return false;
}

static GCControllerDirectionPad* sohsense_stick(GCController* c) {
    if (c == nil) {
        return nil;
    }
    GCPhysicalInputProfile* p = c.physicalInputProfile;
    GCControllerDirectionPad* d = p.dpads[GCInputThumbstick];
    if (d != nil) {
        return d;
    }
    for (NSString* k in p.dpads.allKeys) {
        return p.dpads[k]; // the first of any name
    }
    return nil;
}

// One controller's buttons, as this file's bit vocabulary. Factored out of
// sohsense_read_hardware in R16-D so the hand-agnostic flat fold reads a half
// through EXACTLY the same code the chirality-known path reads it through —
// trap C2's rule applied to the reader: one reader, not two that can drift.
static uint32_t sohsense_read_buttons(GCController* c) {
    uint32_t b = 0;
    if (sohsense_btn(c, GCInputButtonA)) {
        b |= SOHSENSE_BTN_FACE_A;
    }
    if (sohsense_btn(c, GCInputButtonB)) {
        b |= SOHSENSE_BTN_FACE_B;
    }
    // GCInputTrigger is SINGULAR — one per hand device; there is no
    // Left/Right variant to try.
    if (sohsense_btn(c, GCInputTrigger) || sohsense_btn_like(c, @"Trigger")) {
        b |= SOHSENSE_BTN_TRIGGER;
    }
    if (sohsense_btn(c, GCInputGripButton) || sohsense_btn_like(c, @"Grip")) {
        b |= SOHSENSE_BTN_GRIP;
    }
    if (sohsense_btn(c, GCInputThumbstickButton)) {
        b |= SOHSENSE_BTN_STICK;
    }
    if (sohsense_btn(c, GCInputButtonMenu)) {
        b |= SOHSENSE_BTN_MENU;
    }
    return b;
}

static void sohsense_read_hardware(void) {
    if (sBtnInjected) {
        return; // the harness owns the buttons this session
    }
    for (int h = 0; h < SOHSENSE_HANDS; h++) {
        GCController* c = sPad[h];
        if (c == nil) {
            sHandBtn[h] = 0;
            sHandStickX[h] = sHandStickY[h] = 0.0f;
            continue;
        }
        sHandBtn[h] = sohsense_read_buttons(c);
        GCControllerDirectionPad* d = sohsense_stick(c);
        sHandStickX[h] = d ? d.xAxis.value : 0.0f;
        sHandStickY[h] = d ? d.yAxis.value : 0.0f;
    }

    // R16-D — THE HAND-AGNOSTIC FOLD, and why it has to exist.
    //
    // `sPad[LEFT]/sPad[RIGHT]` are assigned ONLY in the ARKit accessory
    // load-completion handler, from ar_accessory_get_inherent_chirality.
    // GameController exposes NO handedness API (checked again against the XROS
    // 26.5 headers), and ARKit accessory tracking needs an immersive space — so
    // OUTSIDE VR both slots are nil for ever and the loop above reads nothing.
    // Rather than leave flat mode dead, fold every adopted spatial half whose
    // hand is not known into the slots WritePad reads:
    //
    //   symmetric bits (A, B, trigger, menu) -> BOTH halves. WritePad already
    //     treats them symmetrically (A/B off `rb`, Z off `lb|rb`, START off
    //     `lb|rb`), so this reproduces the VR layout exactly.
    //   grip -> RIGHT ONLY, i.e. both grips are HOP (R_TRIG) and no L is ever
    //     emitted. L is MK64's music-volume cycle, and this port's
    //     update_music_volume writes the ARCHIVED gMainMusicVolume: a wrong hop
    //     costs one corner, a stray squeeze persists into the flat game's
    //     settings for ever (R14 item 4a's reasoning, DECISIONS.md §7).
    //   thumbstick click -> RIGHT ONLY. Its only consumers are the VR view
    //     cycle and the pane latch, both right-handed; nothing reads it in flat.
    //   thumbstick -> the LEFT slot, which is the one WritePad steers from.
    //
    // On DEVICE in VR this loop is inert: chirality arrives, sPad is filled, and
    // every spatial half is skipped by the `== sPad[h]` test below.
    for (int i = 0; i < sSpatialCount; i++) {
        GCController* c = sSpatial[i];
        if (c == nil || c == sPad[SOHSENSE_LEFT] || c == sPad[SOHSENSE_RIGHT]) {
            continue; // no controller, or its hand is known and already read
        }
        uint32_t b = sohsense_read_buttons(c);
        const uint32_t sym = SOHSENSE_BTN_FACE_A | SOHSENSE_BTN_FACE_B | SOHSENSE_BTN_TRIGGER | SOHSENSE_BTN_MENU;
        for (int h = 0; h < SOHSENSE_HANDS; h++) {
            if (sPad[h] == nil) {
                sHandBtn[h] |= (b & sym);
            }
        }
        if ((b & (SOHSENSE_BTN_GRIP | SOHSENSE_BTN_STICK)) && sPad[SOHSENSE_RIGHT] == nil) {
            sHandBtn[SOHSENSE_RIGHT] |= (b & (SOHSENSE_BTN_GRIP | SOHSENSE_BTN_STICK));
        }
        if (sPad[SOHSENSE_LEFT] == nil) {
            GCControllerDirectionPad* d = sohsense_stick(c);
            float x = d ? d.xAxis.value : 0.0f, y = d ? d.yAxis.value : 0.0f;
            // First deflected half wins the wheel; a half at rest never
            // overwrites a half that is steering (same rule WritePad uses
            // against a gamepad held in the other hand).
            if (x != 0.0f || y != 0.0f) {
                sHandStickX[SOHSENSE_LEFT] = x;
                sHandStickY[SOHSENSE_LEFT] = y;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// The FIXED N64 layout (spec D13/D9): kart-native, and deliberately NOT a
// user bind. It is applied at MK64's own `read_controllers` seam (overlay 0053),
// AFTER osContGetReadData, so it ORs onto whatever the pad already reported and
// no LUS binding layer stands between a Sense button and its N64 bit.
// ---------------------------------------------------------------------------

// MK64/N64 button bits — the same numbers include/PR/os_cont.h uses. Repeated
// here rather than included because this file is shell code and must build
// without the game's headers.
#define SOHSENSE_A_BUTTON 0x8000
#define SOHSENSE_B_BUTTON 0x4000
#define SOHSENSE_Z_TRIG 0x2000
#define SOHSENSE_START_BUTTON 0x1000
#define SOHSENSE_U_JPAD 0x0800
#define SOHSENSE_D_JPAD 0x0400
#define SOHSENSE_L_JPAD 0x0200
#define SOHSENSE_R_JPAD 0x0100
#define SOHSENSE_L_TRIG 0x0020
#define SOHSENSE_R_TRIG 0x0010
#define SOHSENSE_U_CBUTTONS 0x0008
#define SOHSENSE_D_CBUTTONS 0x0004
#define SOHSENSE_L_CBUTTONS 0x0002
#define SOHSENSE_R_CBUTTONS 0x0001

static signed char sohsense_to_stick(float v) {
    float s = v * 127.0f;
    if (s > 127.0f) {
        s = 127.0f;
    }
    if (s < -127.0f) {
        s = -127.0f;
    }
    return (signed char)s;
}

// One edge detector for the tap-vs-hold controls, and it lives here (trap C2).
typedef struct {
    int prev;
    double downAt;
    int held;
} SohSenseTap;
static SohSenseTap sTapViewCycle, sTapMenu, sTapMirror;
static int sStartPulse = 0;
// R9 item 2: the rear-view pane's latch (right stick down toggles it).
static int sMirrorLatch = 0;
// R10 item 3a: the latch's hysteresis state and its debounce clock. See
// sohsense_frame_controls.
static int sMirrorArmed = 0;         // 1 = the stick is past the ARM threshold
static double sMirrorLastToggle = 0.0;
static int sMirrorLeftClickPrev = 0;
static int sMirrorRStickArmed = 0; // R15 item 4: the right stick's Schmitt latch
static unsigned int sMirrorToggles = 0, sMirrorSuppressed = 0;
// R19 item 1 (was R18-B item 3's R3): the gamepad L3 producer's edge state
// and its own counters, plus R3's edge counter (the red control: counted,
// never fires).
static int sGpL3Prev = 0;
static unsigned int sGpL3Edges = 0, sGpL3Fires = 0;
static int sGpR3Prev = 0;
static unsigned int sGpR3Edges = 0;

// IS A PLAIN GAMEPAD'S LEFT (left=1) / RIGHT (left=0) THUMBSTICK BUTTON DOWN?
// Read on the GameController side, not SDL's, so it works for ANY
// GCExtendedGamepad (SDL only turns it into L3/R3 for the game, which MK64
// ignores). PSVR2 Sense halves are skipped: they are the Sense layout's (their
// LEFT click is already the Top toggle; their right click is the view cycle).
// The bridge's `vr set gpl3|gpr3 1|0` ORs in a held button so the producer is
// assertable headless.
static int sohsense_gamepad_thumb_down(int left) {
    int down = ((left ? sT.gpL3 : sT.gpR3) >= 0.5f) ? 1 : 0;
    for (GCController* c in GCController.controllers) {
        if (SohSense_IsSpatialController((__bridge void*)c)) {
            continue;
        }
        GCExtendedGamepad* g = c.extendedGamepad;
        GCControllerButtonInput* b = (g == nil) ? nil : (left ? g.leftThumbstickButton : g.rightThumbstickButton);
        if (b != nil && b.isPressed) {
            down = 1;
        }
    }
    return down;
}
// R19 item 1 — the user (1.0.0.17): "change the hide/show rear view to LEFT
// stick press to match vr controllers". Called by the VR frame controls (the
// producer) and by the shell's pad seam (the leak mask), so both see the same
// button.
int SohSense_GamepadL3Down(void) {
    return sohsense_gamepad_thumb_down(1);
}
// R3 is NOT a producer any more (R19); read only for the red control's counter.
int SohSense_GamepadR3Down(void) {
    return sohsense_gamepad_thumb_down(0);
}

int SohSense_Active(void) {
    // R16-D adds the third clause. `sPad[]` only ever fills from ARKit
    // chirality, which needs an immersive space — so before this, a pair that
    // was adopted, enumerated and readable in a flat window still read as
    // "no Sense controller" and WritePad returned on every frame.
    return (sHandValid[SOHSENSE_LEFT] || sHandValid[SOHSENSE_RIGHT] || sPad[SOHSENSE_LEFT] != nil ||
            sPad[SOHSENSE_RIGHT] != nil || (SOHSENSE_FLAT_LIVE() && sSpatialCount > 0))
               ? 1
               : 0;
}

// R16-D: 1 while the flat fold is driving a real spatial pair — the predicate
// the touch overlay's presence test asks, and deliberately NOT SohSense_Active()
// (which counts injected hands and stays 1 after a VR session).
int SohSense_FlatFoldLive(void) {
    return (SOHSENSE_FLAT_LIVE() && sSpatialCount > 0) ? 1 : 0;
}

void SohSense_WritePad(unsigned short* button, signed char* stickX, signed char* stickY) {
    // R16-D relaxes the guard: `sStarted` is the VR half's lifecycle now, and
    // the fold must also run when only the flat half is up.
    if (button == NULL || !(sStarted || SOHSENSE_FLAT_LIVE()) || !SohSense_Active()) {
        return;
    }
    gSohVRSenseActive = 1;
    uint32_t lb = sHandBtn[SOHSENSE_LEFT], rb = sHandBtn[SOHSENSE_RIGHT];
    unsigned short b = 0;

    // STEER: the left thumbstick, and only when it is actually deflected, so a
    // gamepad held in the other hand still works (donor precedent: both feed
    // one pad, nothing is overwritten with zero).
    signed char sx = sohsense_to_stick(sHandStickX[SOHSENSE_LEFT]);
    signed char sy = sohsense_to_stick(sHandStickY[SOHSENSE_LEFT]);
    if (stickX != NULL && sx != 0) {
        *stickX = sx;
    }
    if (stickY != NULL && sy != 0) {
        *stickY = sy;
    }

    // GAS / BRAKE on the right hand's face buttons.
    if (rb & SOHSENSE_BTN_FACE_A) {
        b |= SOHSENSE_A_BUTTON;
    }
    if (rb & SOHSENSE_BTN_FACE_B) {
        b |= SOHSENSE_B_BUTTON;
    }
    // R9 item 2 — the user's layout, in his words: "BOTH triggers → Z. Right
    // grip → R, left grip → L."
    //
    // ITEM (Z) on EITHER trigger. Which hand is the "item hand" still decides
    // where the in-hand billboard and the throw gesture live (sT.itemHand), but
    // it no longer decides which trigger fires the item: a kart game wants the
    // item on the finger that is already curled, whichever hand that is. The
    // trailing-hold gesture can also assert it — see below.
    int itemHand = (sT.itemHand >= 0.5f) ? SOHSENSE_RIGHT : SOHSENSE_LEFT;
    if ((lb & SOHSENSE_BTN_TRIGGER) || (rb & SOHSENSE_BTN_TRIGGER) || sTrailActive) {
        b |= SOHSENSE_Z_TRIG;
    }
    // HOP / POWERSLIDE on the RIGHT grip; the MUSIC VOLUME CYCLE (L) on the LEFT.
    //
    // R15 item 6 — L IS RESTORED. R14 unbound the left grip on the reasoning
    // below; the user's answer on 1.0.0.11 is "bring it back — the original game
    // let you adjust/mute music", so the binding returns exactly as MK64 has
    // it. The archived-CVar note stands and is not a bug to fix here: the flat
    // game persists gMainMusicVolume the same way, and stock behaviour is what
    // was asked for. The R14 pad mask keeps dropping the four C bits and no
    // longer drops L (see SohVRSense_WritePad).
    //
    // R14 item 4a — L IS THE MUSIC VOLUME CYCLE, and the R9 comment that used to
    // sit here ("the horn/unused bit on most karts") was simply wrong about this
    // game. `race_logic.c:777` reads L's press edge in the in-race controller
    // loop, steps D_800DC5A8 through 0/1/2 and calls func_800029B0(), which is
    // update_music_volume(127 | 75 | 0) — and the port's implementation of that
    // writes the ARCHIVED CVar gMainMusicVolume, so one accidental squeeze does
    // not merely duck the music for a lap, it persists the change into the flat
    // game's settings and re-applies it at the start of every subsequent race.
    // the user never asked for it and squeezed the grip constantly; that is the
    // whole of "left grip cycles music volume".
    //
    // L has no other consumer in racing (the exhaustive list: a START-suppressor,
    // gEnableDebugMode combos, the crash screen, the off-by-default moon-jump
    // cheat, and freecam — which short-circuits normal input entirely). So there
    // is nothing to preserve and no binding worth keeping: the left grip is left
    // unbound rather than moved onto some other bit, because trap C2 says an
    // input that does two things is worse than an input that does one.
    if (rb & SOHSENSE_BTN_GRIP) {
        b |= SOHSENSE_R_TRIG;
    }
    if (lb & SOHSENSE_BTN_GRIP) {
        b |= SOHSENSE_L_TRIG;
    }
    // C BUTTONS: NONE of them are produced in VR.
    //
    // R14 item 4b — C-LEFT IS THE GAME'S OWN LOOK-BEHIND, and in VR that is a
    // camera FLIP under a head-locked eye. the user's report is three symptoms of
    // one cause: hold the right stick left and (a) "the distance disappears" —
    // MK64's section/distance culling follows the flipped camera, so everything
    // ahead leaves the display list; (b) "the rear view shows what's in FRONT" —
    // the pane's walk rotates 180 degrees about the kart from a camera that is
    // already reversed; (c) "the viewport snap-rotates ~45 degrees left and
    // back" — the game camera swinging round while the VR eye stays bolted to
    // the cockpit. Look-behind is the PANE's job in VR and the game camera must
    // never flip under the eye, so C-left goes with C-right (its mirror), and
    // C-up/C-down were already suppressed in R9 for their own reasons: C-up is
    // the zoom level, which in VR only shifts background elements, and C-down is
    // force-promoted to Z_TRIG by update_controller, so every right-stick-down
    // in 1.0.0.5 silently fired the player's item.
    //
    // The right stick keeps its two real VR jobs: the click (view cycle / hold to
    // recenter) and, before R14, the down-latch on the pane — see
    // sohsense_frame_controls().
    // START: asserted for exactly as long as MENU is physically held.
    //
    // R9 item 3 — THE DOUBLE-PRESS. 1.0.0.5 fired START on RELEASE, in a
    // two-frame pulse. SDL also has this controller (0038's Spatial-Controller
    // filter is gated on SohSense_Active(), which is set from an async,
    // authorization-gated accessory load that routinely loses the race against
    // GCControllerDidConnectNotification), and LUS binds SDL's START on PRESS.
    // Two producers, ORed into one pad, firing at DIFFERENT TIMES: press-edge
    // from SDL pauses the game, MK64 clears buttonPressed, and the release-edge
    // from here then reads as a SECOND fresh 0->1 transition, which the pause
    // menu takes as "unpause". One tap, pause then instantly unpause — exactly
    // the user's report.
    //
    // The fix is trap C2/B8's rule: ONE edge, at the consuming fold. Holding the
    // bit for the whole physical press makes the two producers' intervals
    // OVERLAP instead of alternate, so MK64's own edge detector (the only one
    // there is) sees a single 0->1 whether SDL is filtered out or not. No
    // dependence on winning the connect race.
    if ((lb | rb) & SOHSENSE_BTN_MENU) {
        b |= SOHSENSE_START_BUTTON;
    }
    (void)itemHand;
    *button |= b;
}

// The view-mode / recenter / pane controls, run once per VR frame rather than
// per pad read — they talk to the VR module, not to the game's pad.
static void sohsense_frame_controls(void) {
    extern void SohVR_CycleView(void);
    extern void Soh3D_Recenter(void);
    extern void SohVR_SetMirrorHoldSense(int held);
    double t = CACurrentMediaTime();
    // RIGHT stick click: tap cycles the view mode, hold (0.4 s) recenters.
    int now = (sHandBtn[SOHSENSE_RIGHT] & SOHSENSE_BTN_STICK) ? 1 : 0;
    if (now && !sTapViewCycle.prev) {
        sTapViewCycle.downAt = t;
        sTapViewCycle.held = 0;
    }
    if (now && !sTapViewCycle.held && (t - sTapViewCycle.downAt) > 0.4) {
        sTapViewCycle.held = 1;
        Soh3D_Recenter();
    }
    if (!now && sTapViewCycle.prev && !sTapViewCycle.held) {
        SohVR_CycleView();
    }
    sTapViewCycle.prev = now;
    // REAR-VIEW "TOP" PANE — R14 item 3, and the control moves to where the user
    // asked for it: "turned on or off with their left joystick click".
    //
    // Everything that used to live here is gone with it. R9 bound the pane to
    // RIGHT STICK DOWN because the left click read false on the hardware it was
    // written against; R10 then had to wrap that in a Schmitt trigger and a
    // debounce because one threshold is not an edge detector (trap D25) and a
    // deflected stick dithers. A CLICK has none of those problems — it is a
    // digital button with a real press edge — so the analog latch, its arm/
    // disarm thresholds and the right-stick binding all go, which also hands the
    // right stick back with nothing on it but the view cycle.
    //
    // The 250 ms debounce stays. It costs nothing and it is the one part of R10
    // that was defending against the hardware rather than against the code.
    {
        // R15 item 4: TWO producers, one latch. the user asked for the right
        // stick pushed DOWN back as well as the left click — it is the control
        // R9 shipped and the one his hands still reach for. An analog axis is
        // not an edge, so it gets a Schmitt trigger (arm past -0.70, re-arm
        // only after it comes back inside -0.40) rather than one threshold,
        // which is trap D25 stated as a constant; and both producers share the
        // 250 ms debounce and the single toggle entry point, so no combination
        // of the two can double-flip.
        extern int SohVR_ToggleMirrorTop(void);
        int fire = 0;
        int lclick = (sHandBtn[SOHSENSE_LEFT] & SOHSENSE_BTN_STICK) ? 1 : 0;
        if (lclick && !sMirrorLeftClickPrev) {
            fire = 1;
        }
        sMirrorLeftClickPrev = lclick;
        {
            float ry = sHandStickY[SOHSENSE_RIGHT];
            if (!sMirrorRStickArmed && ry <= -0.70f) {
                sMirrorRStickArmed = 1;
                fire = 1;
            } else if (sMirrorRStickArmed && ry > -0.40f) {
                sMirrorRStickArmed = 0;
            }
        }
        // R18-B item 3 / R19 item 1 — THE THIRD PRODUCER: a plain gamepad's
        // LEFT stick click (R19; R18-B shipped the RIGHT one), in VR world
        // frames only. the user (R19): "change the hide/show rear view to LEFT
        // stick press to match vr controllers". A digital
        // button with a real press edge (trap D25), so a plain prev/now edge;
        // it joins the SAME `fire` flag, the same 250 ms debounce and the same
        // single entry point as the two Sense producers, so no combination of
        // the three can double-flip. Outside a world frame the edge state is
        // still tracked (so a press held across the boundary fires nothing
        // when the world resumes) but never fires.
        {
            extern volatile int gSohVRWorldActive;
            int l3 = SohSense_GamepadL3Down();
            if (l3 && !sGpL3Prev) {
                sGpL3Edges++;
                if (gSohVRWorldActive) {
                    sGpL3Fires++;
                    fire = 1;
                }
            }
            sGpL3Prev = l3;
            // R3: counted for the red control, never fires (R19).
            int r3 = SohSense_GamepadR3Down();
            if (r3 && !sGpR3Prev) {
                sGpR3Edges++;
            }
            sGpR3Prev = r3;
        }
        if (fire) {
            if ((t - sMirrorLastToggle) < 0.25) {
                sMirrorSuppressed++; // a bounce, not a press
            } else {
                sMirrorLastToggle = t;
                sMirrorToggles++;
                sMirrorLatch = SohVR_ToggleMirrorTop();
            }
        }
    }
}

// ---------------------------------------------------------------------------
// The gestures (spec D13)
// ---------------------------------------------------------------------------

// (a) THROW. MK64 already makes a binary forward/backward decision at item
// release, reading the stick; the gesture casts that vote from the hand's
// velocity instead. Below `throwMin` we do not vote at all — a slow release is
// MK64's business, and a gesture that always votes would make the stick dead.
static void sohsense_gesture_throw(int itemHand, int itemBtnNow) {
    if (sPrevItemBtn && !itemBtnNow) {
        // RELEASE: this is the instant MK64 reads. Decide now, once.
        gSohVRThrowDir = 0;
        sThrowVoteUntil = 0.0;
        if (sHandValid[itemHand]) {
            simd_float3 v = sHandVel[itemHand];
            float speed = simd_length(v);
            simd_float3 fwd = sohsense_head_fwd();
            float d = (speed > 1e-4f) ? simd_dot(v / speed, fwd) : 0.0f;
            sLastThrowSpeed = speed;
            sLastThrowDot = d;
            if (speed >= sT.throwMin && d >= sT.throwDot) {
                gSohVRThrowDir = 1;
                sThrowVoteUntil = CACurrentMediaTime() + (double)sT.throwHold;
                sThrowsFwd++;
                sLastThrow = "forward";
                SohSense_Haptic(itemHand, 0.8f, 0.06f);
            } else if (speed >= sT.throwMin && d <= -sT.throwDot) {
                gSohVRThrowDir = 2;
                sThrowVoteUntil = CACurrentMediaTime() + (double)sT.throwHold;
                sThrowsBack++;
                sLastThrow = "backward";
                SohSense_Haptic(itemHand, 0.8f, 0.06f);
            } else {
                sThrowsPassed++;
                sLastThrow = "passed"; // MK64's own stick test decides
            }
        } else {
            sThrowsPassed++;
            sLastThrow = "passed";
        }
    } else if (!itemBtnNow && sThrowVoteUntil > 0.0 && CACurrentMediaTime() > sThrowVoteUntil) {
        // THE VOTE HAS TO OUTLIVE THE FRAME THAT CAST IT. The release is
        // detected on the COMPOSITOR thread at the headset's rate, and MK64
        // reads the vote on the ENGINE thread at 30 Hz — so clearing it on the
        // next compositor frame (~11 ms) would routinely wipe it before the
        // game ever looked (the engine frame is ~33 ms). It is held for
        // `throw_hold` seconds instead and then cleared, which is still far
        // shorter than the gap to any possible next throw: the item is gone.
        gSohVRThrowDir = 0;
        sThrowVoteUntil = 0.0;
    }
    sPrevItemBtn = itemBtnNow;
}

// (c) TRAILING HOLD. MK64's hold-behind IS "keep Z down", so this needs no game
// surgery at all: while the item hand is held back and down, the layout asserts
// Z for you. Leaving the zone releases it, and the throw classifier above runs
// on that release exactly as if you had let go of the trigger.
static void sohsense_gesture_trail(int itemHand) {
    if (sT.trailOn < 0.5f || !sHandValid[itemHand] || !sHaveHead) {
        if (sTrailActive) {
            sTrailActive = 0;
        }
        return;
    }
    simd_float3 hp = sohsense_pos(sHandWorld[itemHand]);
    simd_float3 head = sohsense_pos(sHeadWorld);
    simd_float3 fwd = sohsense_head_fwd();
    float along = simd_dot(hp - head, fwd);     // negative = behind you
    float below = head.y - hp.y;                // positive = below eye level
    sTrailAlongNow = along;
    sTrailBelowNow = below;
    int inZone = (along < -sT.trailBack) && (below > sT.trailDown);
    if (inZone && !sTrailActive) {
        sTrailActive = 1;
        sTrailEvents++;
        SohSense_Haptic(itemHand, 0.35f, 0.05f);
    } else if (!inZone && sTrailActive) {
        sTrailActive = 0;
    }
}

// (d) WRIST MIRROR. Glance at your left wrist, face-up, and R3's rear-view pane
// comes to it — the watch-check. Enter and exit thresholds are separate on all
// three tests, so the pane cannot flicker at the boundary.
static void sohsense_gesture_wrist(void) {
    if (sT.wristOn < 0.5f || !sHandValid[SOHSENSE_LEFT] || !sHaveHead) {
        sWristActive = 0;
        return;
    }
    simd_float4x4 w = sHandWorld[SOHSENSE_LEFT];
    simd_float3 wp = sohsense_pos(w);
    simd_float3 head = sohsense_pos(sHeadWorld);
    simd_float3 toWrist = wp - head;
    float dist = simd_length(toWrist);
    simd_float3 gaze = sohsense_norm(simd_make_float3(-sHeadWorld.columns[2].x, -sHeadWorld.columns[2].y,
                                                      -sHeadWorld.columns[2].z));
    float gazeDot = (dist > 1e-4f) ? simd_dot(toWrist / dist, gaze) : 0.0f;
    // "Face up" = the back of the wrist is turned towards your eyes, which is
    // what checking a watch does. The wrist's own +Y is the axis that turns.
    simd_float3 wristUp = sohsense_norm(simd_make_float3(w.columns[1].x, w.columns[1].y, w.columns[1].z));
    float faceDot = (dist > 1e-4f) ? simd_dot(wristUp, -toWrist / dist) : 0.0f;

    sWristFaceNow = faceDot;
    sWristGazeNow = gazeDot;
    sWristDistNow = dist;
    int active;
    if (!sWristActive) {
        active = (faceDot >= sT.wristFace) && (gazeDot >= sT.wristGaze) && (dist <= sT.wristDist);
    } else {
        // Looser on the way out — hysteresis on every one of the three tests.
        active = (faceDot >= sT.wristFaceX) && (gazeDot >= sT.wristGazeX) && (dist <= sT.wristDistX);
    }
    if (active && !sWristActive) {
        sWristEvents++;
        SohSense_Haptic(SOHSENSE_LEFT, 0.3f, 0.04f);
    }
    sWristActive = active;
    if (active) {
        // The pane's plane, at the wrist: offset along the wrist's up axis so it
        // floats above the strap rather than inside the arm, and oriented like
        // the wrist itself.
        simd_float4x4 m = w;
        m.columns[3].x += wristUp.x * sT.wristUp;
        m.columns[3].y += wristUp.y * sT.wristUp;
        m.columns[3].z += wristUp.z * sT.wristUp;
        sWristPlane = m;
        // R14 item 3: the gesture no longer summons the pane. "Left Hand" is a
        // toggle now, and a gesture that ALSO shows the pane is precisely the
        // "it appears even with Left hand OFF" half of the user's report. The
        // detector stays for its telemetry and its haptic tick, and drives
        // nothing.
    }
}

// (b) ITEM IN HAND. Visible whenever MK64 says an item is armed (0053's export)
// and the item hand is tracked.
static void sohsense_gesture_item_in_hand(int itemHand) {
    sItemVisible = (sT.itemInHand >= 0.5f && gSohVRItemArmed != 0 && sHandValid[itemHand]) ? 1 : 0;
}

// ---------------------------------------------------------------------------
// Per-frame entry point
// ---------------------------------------------------------------------------

void SohSense_Update(double presTime, simd_float4x4 originFromHead, int worldFrame) {
    (void)presTime;
    if (!sStarted) {
        return;
    }
    sHeadWorld = originFromHead;
    sHaveHead = 1;
    sUpdates++;
    if (worldFrame) {
        sWorldUpdates++;
    }
    sohsense_poll_anchors();
    sohsense_read_hardware();
    sohsense_frame_controls();

    int itemHand = (sT.itemHand >= 0.5f) ? SOHSENSE_RIGHT : SOHSENSE_LEFT;
    if (!worldFrame) {
        // Non-gameplay frames (menus, the panel fallback): gestures stand down
        // and every latch drops, so nothing crosses the boundary (trap C2).
        gSohVRThrowDir = 0;
        sThrowVoteUntil = 0.0;
        sTrailActive = 0;
        sItemVisible = 0;
        sWristActive = 0;
        sPrevItemBtn = 0;
        return;
    }
    // The item button, as the gesture layer sees it: the physical trigger/grip
    // OR the trailing hold. ONE reading, used by both the pad write and the
    // throw classifier, so they can never disagree about when a release
    // happened.
    uint32_t ib = sHandBtn[itemHand];
    int itemBtnNow = ((ib & SOHSENSE_BTN_TRIGGER) || (ib & SOHSENSE_BTN_GRIP) || sTrailActive) ? 1 : 0;
    sohsense_gesture_trail(itemHand);
    // Re-read after the trail gesture may have dropped: a trail release IS an
    // item release, and it must reach the classifier on the same frame.
    itemBtnNow = ((ib & SOHSENSE_BTN_TRIGGER) || (ib & SOHSENSE_BTN_GRIP) || sTrailActive) ? 1 : 0;
    sohsense_gesture_throw(itemHand, itemBtnNow);
    sohsense_gesture_item_in_hand(itemHand);
    sohsense_gesture_wrist();

    // Haptic hooks (spec D13). No new engine seam: the pickup edge is 0053's
    // armed-item export and the hit thump is 0051's spin flag, both of which
    // already exist for other reasons.
    {
        extern volatile int gSohVRKartSpin;
        int armed = gSohVRItemArmed;
        if (armed != 0 && sPrevArmed == 0) {
            SohSense_Haptic(itemHand, 0.5f, 0.08f); // item pickup: the item hand
        }
        sPrevArmed = armed;
        int spin = gSohVRKartSpin;
        if (spin && !sPrevSpin) {
            SohSense_HapticBoth(1.0f, 0.18f); // taking a hit: a thump in both
        }
        sPrevSpin = spin;
    }
}

// Engine rumble -> both hands (spec D13). Called from the shell's rumble
// path; kept separate from the hit thump so a long engine rumble and a hit can
// be told apart in the dump.
void SohSense_EngineRumble(float strength, float seconds) {
    SohSense_HapticBoth(strength, seconds);
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

// R16-D — DISCOVERY, in every mode. Nothing in here needs ARKit, an immersive
// space or an authorization round trip: it is pure GameController adoption plus
// the two connect/disconnect observers. Called once at shell launch on visionOS
// (SohIos_OnWindowCreated) and again by SohSense_Start; idempotent.
void SohSense_StartInput(void) {
    if (sInputStarted) {
        return;
    }
    sInputStarted = 1;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (GCController* c in GCController.controllers) {
            sohsense_adopt(c);
        }
        static int observed = 0;
        if (!observed) {
            observed = 1;
            [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification
                                                            object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification* n) {
                                                            sohsense_adopt((GCController*)n.object);
                                                        }];
            [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidDisconnectNotification
                                                            object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification* n) {
                                                            sohsense_forget((GCController*)n.object);
                                                        }];
        }
        NSLog(@"[sense] input backend ready (%lu controller(s) present, %d spatial)",
              (unsigned long)GCController.controllers.count, sSpatialCount);
    });
}

// R16-D — the FLAT per-frame hardware read, called from the shell's pad seam
// (SohVRSense_WritePad) once per game frame in every mode.
//
// Deliberately NOT sohsense_frame_controls(): that cycles the VR view mode,
// recentres the panel and drives the rear-pane latch, none of which may happen
// in a flat window. This is the hardware read and nothing else.
//
// The guard is `sStarted`, NOT `gSoh3DRunning`. gSoh3DRunning is 1 in the 3D
// PANEL mode as well as in VR (both Soh3D_Immersive_Run and SohVR_Immersive_Run
// set it), and the panel mode never pumps the Sense layer — gating on it would
// have left mode 1 exactly as broken as it was. `sStarted` is set only by
// SohSense_Start, i.e. only by the VR loop that is already pumping, so this is
// the precise "is somebody else reading" question and there is never a second
// reader.
void SohSense_PumpFlat(void) {
    if (sStarted || !SOHSENSE_FLAT_LIVE()) {
        return;
    }
    sohsense_read_hardware();
}

void SohSense_Start(void) {
    if (sStarted) {
        return;
    }
    sStarted = 1;
    // Every latch starts clear on every VR entry: nothing from the last session
    // may cross into this one (trap C2).
    SohSense_InjectDoff();
    sTapViewCycle.prev = sTapMenu.prev = sTapMirror.prev = 0;
    sStartPulse = 0;
    sMirrorLatch = 0;
    // R10 item 3a: the hysteresis/debounce state goes with it.
    sMirrorArmed = 0;
    sMirrorLeftClickPrev = 0;
    sMirrorRStickArmed = 0;
    sMirrorLastToggle = 0.0;
    sGpL3Prev = 0; // R18-B item 3 / R19: no L3 edge crosses a VR entry
    sGpR3Prev = 0;
    // R16-D: discovery is shared with the flat fold and lives there now. On a
    // normal launch it has already run; this call is the idempotent belt.
    SohSense_StartInput();
}

// R16-D — this stops the VR HALF ONLY. It used to mean "the Sense layer is
// off"; it now means "the immersive loop is done with it". `sInputStarted`, the
// observers and the adopted spatial list are all left alone, because the flat
// fold outlives the immersive space — that is the whole point of the round.
//
// It must still InjectDoff(): a VR exit taken with the item trigger down would
// otherwise carry Z into the flat game, and now that the flat fold keeps
// running there is no second clear behind it.
void SohSense_Stop(void) {
    if (!sStarted) {
        return;
    }
    sStarted = 0;
    // RELEASE EVERYTHING, unconditionally and idempotently — the same discipline
    // the VR exit finalize follows (spec D8/D9). A VR exit while an item
    // trigger is down must not leave Z asserted in the flat game.
    SohSense_InjectDoff();
    gSohVRSenseActive = 0;
    for (int h = 0; h < SOHSENSE_HANDS; h++) {
        sohsense_haptics_release(h);
    }
}

// ---------------------------------------------------------------------------
// Queries the compositor makes
// ---------------------------------------------------------------------------

int SohSense_HandPose(int hand, simd_float4x4* out) {
    if (hand < 0 || hand >= SOHSENSE_HANDS || !sHandValid[hand]) {
        return 0;
    }
    if (out != NULL) {
        *out = sHandWorld[hand];
    }
    return 1;
}

int SohSense_ItemHand(void) {
    return (sT.itemHand >= 0.5f) ? SOHSENSE_RIGHT : SOHSENSE_LEFT;
}

int SohSense_ItemHandPose(simd_float4x4* out) {
    return SohSense_HandPose(SohSense_ItemHand(), out);
}

int SohSense_ItemInHandVisible(void) {
    return sItemVisible;
}

float SohSense_ItemScale(void) {
    return sT.itemScale;
}

int SohSense_ArmedItem(void) {
    return gSohVRItemArmed;
}

int SohSense_WristMirrorActive(void) {
    return sWristActive;
}

float SohSense_WristScale(void) {
    return sT.wristScale;
}

int SohSense_WristMirrorPose(simd_float4x4* out) {
    if (!sWristActive) {
        return 0;
    }
    if (out != NULL) {
        *out = sWristPlane;
    }
    return 1;
}

// R14 item 3 — THE LEFT-HAND PANE'S POSE, ungated.
//
// This is R4's wrist plane with every reason it could disappear removed. the user
// likes how it follows (it IS the hand pose, so it turns as the wrist turns);
// what he does not like is that it vanishes "when the hand rotates too far or
// moves too far forward" — which was never a tracking failure at all, it was
// the WATCH-CHECK GESTURE's three threshold tests (face-up dot, gaze-adjacency
// dot, arm's-length distance) doing exactly what they were written to do. With
// the pane on a toggle, those tests have nothing left to decide, so none of
// them is consulted here.
//
// The one real disappearance left is the controller dropping out of tracking
// for a poll or two (sHandValid is cleared for any hand the accessory
// enumeration does not see). A pane that blinks on a dropped poll reads as a
// bug, so the last good pose is held for SOHSENSE_PANE_HOLD seconds — long
// enough to ride out a blink, short enough that a controller genuinely put down
// takes the pane with it rather than leaving it stuck in mid-air.
#define SOHSENSE_PANE_HOLD 0.75
static simd_float4x4 sPanePoseLast;
static double sPanePoseLastAt = 0.0;
static unsigned int sPaneHoldFrames = 0;
int SohSense_LeftPanePose(simd_float4x4* out) {
    if (sHandValid[SOHSENSE_LEFT]) {
        simd_float4x4 m = sHandWorld[SOHSENSE_LEFT];
        // Offset along the hand's own up axis, so the plane floats above the
        // controller rather than inside the fist — R4's wristUp, unchanged.
        simd_float3 up = sohsense_norm(simd_make_float3(m.columns[1].x, m.columns[1].y, m.columns[1].z));
        m.columns[3].x += up.x * sT.wristUp;
        m.columns[3].y += up.y * sT.wristUp;
        m.columns[3].z += up.z * sT.wristUp;
        sPanePoseLast = m;
        sPanePoseLastAt = CACurrentMediaTime();
        if (out != NULL) {
            *out = m;
        }
        return 1;
    }
    if (sPanePoseLastAt > 0.0 && (CACurrentMediaTime() - sPanePoseLastAt) < SOHSENSE_PANE_HOLD) {
        sPaneHoldFrames++;
        if (out != NULL) {
            *out = sPanePoseLast;
        }
        return 1;
    }
    return 0;
}
unsigned int SohSense_PaneHoldFrames(void) {
    return sPaneHoldFrames;
}

// ---------------------------------------------------------------------------
// Tunables
// ---------------------------------------------------------------------------

static struct {
    const char* key;
    float* slot;
    float lo, hi;
} const kTunables[] = {
    { "item_hand", &sT.itemHand, 0.0f, 1.0f },      { "throw_min", &sT.throwMin, 0.05f, 12.0f },
    { "throw_dot", &sT.throwDot, 0.0f, 0.99f },     { "throw_hold", &sT.throwHold, 0.02f, 2.0f },
    { "trail_on", &sT.trailOn, 0.0f, 1.0f },
    { "trail_back", &sT.trailBack, 0.0f, 1.0f },    { "trail_down", &sT.trailDown, -1.0f, 1.0f },
    { "item_inhand", &sT.itemInHand, 0.0f, 1.0f },  { "item_scale", &sT.itemScale, 0.01f, 1.0f },
    { "wrist_on", &sT.wristOn, 0.0f, 1.0f },        { "wrist_face", &sT.wristFace, -1.0f, 1.0f },
    { "wrist_face_x", &sT.wristFaceX, -1.0f, 1.0f }, { "wrist_gaze", &sT.wristGaze, -1.0f, 1.0f },
    { "wrist_gaze_x", &sT.wristGazeX, -1.0f, 1.0f }, { "wrist_dist", &sT.wristDist, 0.05f, 3.0f },
    { "wrist_dist_x", &sT.wristDistX, 0.05f, 3.0f }, { "wrist_up", &sT.wristUp, -0.5f, 0.5f },
    { "wrist_scale", &sT.wristScale, 0.05f, 3.0f },  { "haptics", &sT.haptics, 0.0f, 1.0f },
    { "haptic_gain", &sT.hapticGain, 0.0f, 2.0f },
    { "flatfold", &sT.flatFold, 0.0f, 1.0f },
    { "gpl3", &sT.gpL3, 0.0f, 1.0f },
    { "gpl3bind", &sT.gpL3Bind, 0.0f, 65535.0f },
    { "gpr3", &sT.gpR3, 0.0f, 1.0f },
};

int SohSense_SetTunable(const char* key, float value) {
    if (key == NULL) {
        return 0;
    }
    for (size_t i = 0; i < sizeof(kTunables) / sizeof(kTunables[0]); i++) {
        if (strcmp(key, kTunables[i].key) != 0) {
            continue;
        }
        if (value < kTunables[i].lo) {
            value = kTunables[i].lo;
        }
        if (value > kTunables[i].hi) {
            value = kTunables[i].hi;
        }
        *kTunables[i].slot = value;
        return 1;
    }
    return 0;
}

float SohSense_GetTunable(const char* key) {
    if (key != NULL) {
        for (size_t i = 0; i < sizeof(kTunables) / sizeof(kTunables[0]); i++) {
            if (strcmp(key, kTunables[i].key) == 0) {
                return *kTunables[i].slot;
            }
        }
    }
    return 0.0f;
}

// ---------------------------------------------------------------------------
// Injection (D11) — how every gesture above is asserted with no hardware
// ---------------------------------------------------------------------------

static simd_float4x4 sohsense_euler(float x, float y, float z, float yawDeg, float pitchDeg, float rollDeg) {
    float cy = cosf(yawDeg * (float)M_PI / 180.0f), sy = sinf(yawDeg * (float)M_PI / 180.0f);
    float cp = cosf(pitchDeg * (float)M_PI / 180.0f), sp = sinf(pitchDeg * (float)M_PI / 180.0f);
    float cr = cosf(rollDeg * (float)M_PI / 180.0f), sr = sinf(rollDeg * (float)M_PI / 180.0f);
    simd_float4x4 Y = matrix_identity_float4x4, P = matrix_identity_float4x4, R = matrix_identity_float4x4;
    Y.columns[0] = simd_make_float4(cy, 0, -sy, 0);
    Y.columns[2] = simd_make_float4(sy, 0, cy, 0);
    P.columns[1] = simd_make_float4(0, cp, sp, 0);
    P.columns[2] = simd_make_float4(0, -sp, cp, 0);
    R.columns[0] = simd_make_float4(cr, sr, 0, 0);
    R.columns[1] = simd_make_float4(-sr, cr, 0, 0);
    simd_float4x4 m = simd_mul(Y, simd_mul(P, R));
    m.columns[3] = simd_make_float4(x, y, z, 1.0f);
    return m;
}

void SohSense_InjectHand(int hand, float x, float y, float z, float yawDeg, float pitchDeg, float rollDeg) {
    if (hand < 0 || hand >= SOHSENSE_HANDS) {
        return;
    }
    simd_float4x4 m = sohsense_euler(x, y, z, yawDeg, pitchDeg, rollDeg);
    if (!sVelInjected[hand]) {
        // Derived velocity, so a script that only moves the hand still produces
        // a plausible throw. `vr hand <h> vel ...` overrides it for the
        // classification asserts, where a number from wall-clock deltas over a
        // TCP round trip would be anyone's guess.
        static double last[SOHSENSE_HANDS];
        double now = CACurrentMediaTime();
        double dt = (last[hand] > 0.0) ? (now - last[hand]) : 0.0;
        if (dt > 1e-3 && dt < 1.0 && sHandValid[hand]) {
            simd_float3 d = simd_make_float3(x, y, z) - sohsense_pos(sHandWorld[hand]);
            sHandVel[hand] = d / (float)dt;
        }
        last[hand] = now;
    }
    sHandWorld[hand] = m;
    sHandHeld[hand] = 1;
    sHandInjected[hand] = 1;
    sHandValid[hand] = 1; // published LAST
}

void SohSense_InjectVelocity(int hand, float vx, float vy, float vz) {
    if (hand < 0 || hand >= SOHSENSE_HANDS) {
        return;
    }
    sHandVel[hand] = simd_make_float3(vx, vy, vz);
    sVelInjected[hand] = 1;
}

void SohSense_InjectStick(int hand, float x, float y) {
    if (hand < 0 || hand >= SOHSENSE_HANDS) {
        return;
    }
    sBtnInjected = 1;
    sHandStickX[hand] = (x < -1.0f) ? -1.0f : (x > 1.0f ? 1.0f : x);
    sHandStickY[hand] = (y < -1.0f) ? -1.0f : (y > 1.0f ? 1.0f : y);
}

void SohSense_InjectButton(int hand, const char* name, int down) {
    if (hand < 0 || hand >= SOHSENSE_HANDS || name == NULL) {
        return;
    }
    uint32_t bit = 0;
    if (strcmp(name, "a") == 0) {
        bit = SOHSENSE_BTN_FACE_A;
    } else if (strcmp(name, "b") == 0) {
        bit = SOHSENSE_BTN_FACE_B;
    } else if (strcmp(name, "trigger") == 0) {
        bit = SOHSENSE_BTN_TRIGGER;
    } else if (strcmp(name, "grip") == 0) {
        bit = SOHSENSE_BTN_GRIP;
    } else if (strcmp(name, "stick") == 0) {
        bit = SOHSENSE_BTN_STICK;
    } else if (strcmp(name, "menu") == 0) {
        bit = SOHSENSE_BTN_MENU;
    } else {
        return;
    }
    sBtnInjected = 1;
    if (down) {
        sHandBtn[hand] |= bit;
    } else {
        sHandBtn[hand] &= ~bit;
    }
}

void SohSense_InjectClear(void) {
    for (int h = 0; h < SOHSENSE_HANDS; h++) {
        sHandInjected[h] = 0;
        sVelInjected[h] = 0;
        sHandValid[h] = 0;
        sHandVel[h] = simd_make_float3(0, 0, 0);
    }
    sBtnInjected = 0;
}

// The doff path, and the one every "everything must let go" caller shares:
// disconnect, VR exit, VR entry, and the harness's own `vr hand doff`.
void SohSense_InjectDoff(void) {
    for (int h = 0; h < SOHSENSE_HANDS; h++) {
        sHandBtn[h] = 0;
        sHandStickX[h] = sHandStickY[h] = 0.0f;
        sHandValid[h] = 0;
        sHandHeld[h] = 0;
        sHandInjected[h] = 0;
        sVelInjected[h] = 0;
        sHandVel[h] = simd_make_float3(0, 0, 0);
    }
    sBtnInjected = 0;
    sTrailActive = 0;
    sWristActive = 0;
    sItemVisible = 0;
    sPrevItemBtn = 0;
    sStartPulse = 0;
    sTapMirror.prev = 0;
    sMirrorLatch = 0;
    // R10 item 3a: the hysteresis/debounce state goes with it.
    sMirrorArmed = 0;
    sMirrorLeftClickPrev = 0;
    sMirrorRStickArmed = 0;
    sMirrorLastToggle = 0.0;
    gSohVRThrowDir = 0;
    sThrowVoteUntil = 0.0;
    sDoffEvents++;
}

// ---------------------------------------------------------------------------
// Dump — one flat key=value line, seq LAST (D11). Reads "absent" gracefully.
// ---------------------------------------------------------------------------

static char sSenseLine[1500]; // R18-B: was 1100; R19: 1400 -> 1500 for the gp_l3 + gp_r3 fields
static unsigned int sSenseSeq = 0;

const char* SohSense_Dump(void) {
    const char* auth = (sAuthState == 1) ? "allowed" : (sAuthState == -1) ? "denied" : (sAuthAsked ? "pending" : "unasked");
    const char* state;
    int injected = sHandInjected[SOHSENSE_LEFT] || sHandInjected[SOHSENSE_RIGHT];
    if (injected) {
        state = "injected"; // the harness owns the hands (simulator asserts)
    } else if (sSpatialSeen == 0 && sLoadOK == 0) {
        // No spatial controller has ever been seen. This is the SIMULATOR's
        // answer and it is not a failure — note that a plain gamepad may still
        // have been adopted and refused authorization (the sim's synthetic
        // "Gamepad" does exactly that), which is why the test is on `spatial`
        // and not on `controllers`.
        state = "absent";
    } else if (sLoadOK == 0 && sLoadFail > 0) {
        state = "load-failed";
    } else if (sLoadOK == 0) {
        state = "unloaded";
    } else if (sPollCount == 0) {
        state = "provider-idle";
    } else if (sLastAnchorCount == 0) {
        state = "no-anchors";
    } else {
        state = "tracking";
    }
    simd_float3 lp = sohsense_pos(sHandWorld[SOHSENSE_LEFT]), rp = sohsense_pos(sHandWorld[SOHSENSE_RIGHT]);
    // R9 items 2/3: run the fixed layout against a SCRATCH pad so the dump can
    // report the exact N64 bits it is producing. Same function MK64's
    // read_controllers seam calls, so there is no second copy of the mapping to
    // drift (trap C2, applied to the test as well as to the code).
    unsigned short sohPadBits = 0;
    signed char sohPadSx = 0, sohPadSy = 0;
    SohSense_WritePad(&sohPadBits, &sohPadSx, &sohPadSy);
    snprintf(sSenseLine, sizeof(sSenseLine),
             "vr_hands started=%d state=%s auth=%s controllers=%d spatial=%d loads=%d fails=%d failcode=%d "
             "accessories=%d polls=%u anchors=%d doffs=%d active=%d "
             "L_valid=%d L_inj=%d L_pos=%.3f,%.3f,%.3f L_vel=%.2f,%.2f,%.2f L_btn=0x%02x L_stick=%.2f,%.2f "
             "R_valid=%d R_inj=%d R_pos=%.3f,%.3f,%.3f R_vel=%.2f,%.2f,%.2f R_btn=0x%02x R_stick=%.2f,%.2f "
             "item_hand=%d armed=%d item_vis=%d throw_dir=%d throws_fwd=%d throws_back=%d throws_passed=%d "
             "last_throw=%s last_speed=%.2f last_dot=%.2f trail=%d trail_events=%d "
             "wrist=%d wrist_events=%d wrist_face_now=%.2f wrist_gaze_now=%.2f wrist_dist_now=%.2f "
             "trail_along=%.2f trail_below=%.2f updates=%d world_updates=%d haptics=%d bursts=%d "
             "t_throw_min=%.2f t_throw_dot=%.2f t_throw_hold=%.2f t_trail_back=%.2f t_trail_down=%.2f "
             "t_wrist_face=%.2f t_wrist_gaze=%.2f t_wrist_dist=%.2f t_item_scale=%.3f t_wrist_scale=%.2f "
             // R9 items 2/3: the N64 pad bits this layout PRODUCES right now,
             // evaluated the same way MK64's read_controllers seam evaluates
             // them. That makes the whole binding table a headless assert
             // instead of something only a headset can check.
             "pad=0x%04x pad_sx=%d pad_sy=%d mirror_latch=%d mirror_armed=%d mirror_toggles=%u "
             // R16-D: the flat fold's own state, so `vr hands` alone can tell
             // "the VR loop is pumping" from "the flat fold is pumping".
             "mirror_bounces=%u input_started=%d spatial_now=%d flat_fold=%d t_flatfold=%.0f "
             // R19 item 1: the gamepad L3 producer (was R18-B's R3), and R3's
             // red-control counter (edges counted, never a toggle).
             "gp_l3=%d gp_l3_edges=%u gp_l3_fires=%u t_gpl3=%.0f gp_l3_masked=%u gp_l3_bits=0x%04x "
             "gp_r3=%d gp_r3_edges=%u t_gpr3=%.0f seq=%u",
             sStarted, state, auth, sCtlSeen, sSpatialSeen, sLoadOK, sLoadFail, sLoadFailCode, sAccessoryCount,
             sPollCount, sLastAnchorCount, sDoffEvents, SohSense_Active(), sHandValid[SOHSENSE_LEFT],
             sHandInjected[SOHSENSE_LEFT], lp.x, lp.y, lp.z, sHandVel[SOHSENSE_LEFT].x, sHandVel[SOHSENSE_LEFT].y,
             sHandVel[SOHSENSE_LEFT].z, sHandBtn[SOHSENSE_LEFT], sHandStickX[SOHSENSE_LEFT],
             sHandStickY[SOHSENSE_LEFT], sHandValid[SOHSENSE_RIGHT], sHandInjected[SOHSENSE_RIGHT], rp.x, rp.y, rp.z,
             sHandVel[SOHSENSE_RIGHT].x, sHandVel[SOHSENSE_RIGHT].y, sHandVel[SOHSENSE_RIGHT].z,
             sHandBtn[SOHSENSE_RIGHT], sHandStickX[SOHSENSE_RIGHT], sHandStickY[SOHSENSE_RIGHT],
             SohSense_ItemHand(), gSohVRItemArmed, sItemVisible, gSohVRThrowDir, sThrowsFwd, sThrowsBack,
             sThrowsPassed, sLastThrow, sLastThrowSpeed, sLastThrowDot, sTrailActive, sTrailEvents, sWristActive,
             sWristEvents, sWristFaceNow, sWristGazeNow, sWristDistNow, sTrailAlongNow, sTrailBelowNow,
             sUpdates, sWorldUpdates, (int)(sT.haptics >= 0.5f), sHapticBursts, sT.throwMin, sT.throwDot, sT.throwHold, sT.trailBack,
             sT.trailDown, sT.wristFace, sT.wristGaze, sT.wristDist, sT.itemScale, sT.wristScale, sohPadBits,
             (int)sohPadSx, (int)sohPadSy, sMirrorLatch, sMirrorArmed, sMirrorToggles,
             sMirrorSuppressed, sInputStarted, sSpatialCount, SohSense_FlatFoldLive(), sT.flatFold,
             SohSense_GamepadL3Down(), sGpL3Edges, sGpL3Fires, sT.gpL3, gSohVRL3Masked, gSohVRL3Bits,
             SohSense_GamepadR3Down(), sGpR3Edges, sT.gpR3,
             ++sSenseSeq);
    return sSenseLine;
}
