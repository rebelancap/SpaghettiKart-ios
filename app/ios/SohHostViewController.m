// SohHostViewController.m — boots the SDL/SoH engine under the SwiftUI app
// entry (visionOS) and owns the 2D<->3D transition sequencing.
//
// Why SwiftUI at the top: an ImmersiveSpace (stereo rendering) can only be
// declared by a SwiftUI App. SDL2main's UIKit shim is therefore NOT linked on
// visionOS; this VC calls the engine's SDL_main once the SwiftUI window scene
// is live. SDL2 then creates its own UIWindow, the shell grafts it onto the
// active scene (SohIosShell.m — NSNotification-based, delegate-free), and
// everything downstream (display link, touch overlay, bridge) works exactly as
// on the SDL-main path. SoH's main() never returns (game loop); SDL pumps the
// UIKit runloop from PumpEvents each frame, so SwiftUI stays serviced — the
// same proven behavior as the old postFinishLaunch path.
//
// 2D->3D sequencing (order is load-bearing — guide §2.7):
//   enter: gSoh3DMode=1 FIRST (engine goes offscreen: renders the eye
//          framebuffers, never acquires the hidden window's drawable — that
//          acquire stalls forever), THEN open the immersive space.
//   exit:  stop the immersive render thread and WAIT for it (it must never
//          touch a layerRenderer SwiftUI is tearing down), THEN dismiss; only
//          Soh_Exit3DFinalize (after dismissal) puts the engine back onscreen.

#import "SohHostViewController.h"
#import "SohImmersive.h"
#import <AVFAudio/AVFAudio.h>

extern void SDL_SetMainReady(void);
extern int SDL_main(int argc, char* argv[]); // soh's main() (0004: main=SDL_main)
extern void Soh_SetSpaceMode(int32_t mode);  // SohVisionApp.swift (@_cdecl)

// Engine-visible 3D state lives in SohIosShell.m (compiled on iPhone too, so
// the Fast3D overlay's strong externs always resolve; mode stays 0 there).
extern volatile int gSoh3DMode;
// Diagnostics: drain-timer liveness + GCD main-queue drain proof (bridge `3d`).
volatile int gSoh3DDrainTicks = 0;
volatile int gSoh3DGcdProbe = 0;

int Soh_Get3DMode(void) {
    return gSoh3DMode;
}

// Engine -> compositor bridge globals also live in SohIosShell.m.
extern void* volatile gSoh3DEyeTexture[2];
extern volatile int gSoh3DEyeFrames[2];

void* Soh3D_GetEyeMTLTexture(int eye) {
    if (eye < 1 || eye > 2) {
        return NULL;
    }
    // Gate on the per-eye rendered flag: the texture is UNDEFINED garbage
    // until first drawn (guide §2.4).
    return gSoh3DEyeFrames[eye - 1] > 0 ? gSoh3DEyeTexture[eye - 1] : NULL;
}

int Soh3D_GetEyeFrames(int eye) {
    return (eye >= 1 && eye <= 2) ? gSoh3DEyeFrames[eye - 1] : 0;
}

static BOOL sohHostBooted = NO;

@implementation SohHostViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (sohHostBooted) {
        return;
    }
    sohHostBooted = YES;
    NSLog(@"[SohHost] window scene live — booting engine (SDL_main)");
    // Boot from a RUNLOOP TIMER, never dispatch_async: soh's main never
    // returns (the N64 graph loop runs on this thread), and a never-ending
    // GCD block would occupy the serial main queue forever — every later
    // main-queue block (all of SwiftUI/MainActor) would starve. A timer
    // callout leaves the queue free; the shell's drain timer services it
    // from inside the game loop.
    [NSTimer scheduledTimerWithTimeInterval:0
                                    repeats:NO
                                      block:^(NSTimer* t) {
                                          SDL_SetMainReady();
                                          static char arg0[] = "spaghetti";
                                          static char* argv[] = { arg0, NULL };
                                          SDL_main(1, argv);
                                          NSLog(@"[SohHost] SDL_main returned (engine quit)");
                                      }];
}

@end

// --- parked 2D window + curtain ("Playing in 3D") --------------------------
static CGSize soh_pre3dSize = { 0, 0 }; // captured at entry START, guarded
static UIView* soh_curtain = nil;

static BOOL Soh_ViewTreeHasMetalLayer(UIView* v, int depth) {
    if (depth > 4) {
        return NO;
    }
    if ([v.layer isKindOfClass:NSClassFromString(@"CAMetalLayer")]) {
        return YES;
    }
    for (UIView* s in v.subviews) {
        if (Soh_ViewTreeHasMetalLayer(s, depth + 1)) {
            return YES;
        }
    }
    return NO;
}

// The GAME window: SDL's UIWindow (hosts the CAMetalLayer view). The key
// window at ornament-tap time is the SwiftUI HOSTING window — curtains and
// geometry aimed at "key" hit the wrong window (device round 2 finding).
static UIWindow* Soh_KeyGameWindow(void) {
    for (UIWindow* w in UIApplication.sharedApplication.windows) {
        if (Soh_ViewTreeHasMetalLayer(w, 0)) {
            return w;
        }
    }
    for (UIWindow* w in UIApplication.sharedApplication.windows) {
        if (w.isKeyWindow) {
            return w;
        }
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

void Soh_RequestWindowSize(CGSize size) { // non-static: restore controller re-requests
    UIWindow* w = Soh_KeyGameWindow();
    UIWindowScene* scene = w.windowScene;
    if (scene == nil) {
        NSLog(@"[SohHost] geometry request skipped: no scene");
        return;
    }
    @try {
        UIWindowSceneGeometryPreferencesVision* prefs =
            [[UIWindowSceneGeometryPreferencesVision alloc] initWithSize:size];
        [scene requestGeometryUpdateWithPreferences:prefs
                                       errorHandler:^(NSError* e) {
                                           NSLog(@"[SohHost] geometry update failed: %@", e);
                                       }];
        NSLog(@"[SohHost] geometry request %.0fx%.0f", size.width, size.height);
    } @catch (NSException* ex) {
        NSLog(@"[SohHost] geometry request THREW: %@", ex);
    }
}

// mode: 1 = 3D panel, 2 = VR. R8 (the user, 1.0.0.4 retest): the parked window
// in VR is the STANDARD BLACK CURTAIN, exactly like 3D mode — same opaque
// black, same 28 pt type, only the word changes. This OVERRULES the R6 design
// ruling (a near-transparent slab with a small "VR" chip, on the reasoning
// that an opaque black slab squats inside the diorama); the user decided in the
// headset and his call stands. spec D-note updated in VR-spec.md.
// The window still stays alive and parked either way — it hosts the ornament
// that owns Exit (spec D8 / the B rules).
static void Soh_SetCurtain2(bool show, int mode) {
    UIWindow* w = Soh_KeyGameWindow();
    if (show) {
        if (soh_curtain != nil || w == nil) {
            return;
        }
        const BOOL vr = (mode == 2);
        UIView* v = [[UIView alloc] initWithFrame:w.bounds];
        v.backgroundColor = UIColor.blackColor;
        v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        UILabel* l = [[UILabel alloc] initWithFrame:v.bounds];
        l.text = vr ? @"Playing in VR" : @"Playing in 3D";
        l.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
        l.font = [UIFont systemFontOfSize:28 weight:UIFontWeightSemibold];
        l.textAlignment = NSTextAlignmentCenter;
        l.autoresizingMask = v.autoresizingMask;
        [v addSubview:l];
        [w addSubview:v];
        soh_curtain = v;
    } else if (soh_curtain != nil) {
        [soh_curtain removeFromSuperview];
        soh_curtain = nil;
    }
}

static void Soh_SetCurtain(bool show) {
    Soh_SetCurtain2(show, 1);
}

// R8: the curtain, as one bridge-readable line. UIKit placements cannot be
// seen by an engine screenshot (program spec ground rule 6), so the view
// logs its own state instead.
const char* Soh_CurtainInfo(void) {
    static char line[220];
    __block NSString* s = @"curtain=0";
    void (^grab)(void) = ^{
        UIView* v = soh_curtain;
        if (v == nil) {
            s = @"curtain=0";
            return;
        }
        CGFloat r = 0, g = 0, b = 0, a = 0;
        [v.backgroundColor getRed:&r green:&g blue:&b alpha:&a];
        UILabel* l = v.subviews.firstObject;
        s = [NSString stringWithFormat:@"curtain=1 bg_rgba=%.2f,%.2f,%.2f,%.2f text=%@ pt=%.0f",
                                       r, g, b, a,
                                       [l isKindOfClass:UILabel.class]
                                           ? [((UILabel*)l).text stringByReplacingOccurrencesOfString:@" "
                                                                                           withString:@"_"]
                                           : @"none",
                                       [l isKindOfClass:UILabel.class] ? ((UILabel*)l).font.pointSize : 0.0];
    };
    if (NSThread.isMainThread) {
        grab();
    } else {
        dispatch_sync(dispatch_get_main_queue(), grab);
    }
    snprintf(line, sizeof(line), "%s", s.UTF8String);
    return line;
}

// D1 tri-state (VR-spec): 0 = flat, 1 = 3D panel, 2 = VR. gSoh3DMode stays
// the ENGINE's "render offscreen into eye framebuffers" flag — identical for
// both immersive modes — and sSohSpaceMode records WHICH space is open, so a
// 3D<->VR switch can sequence as dismiss-then-open (spec D1: the Soh3D
// space's own configuration is never touched).
static int sSohSpaceMode = 0;
static int sSohPendingMode = -1; // mode to open once the current one is gone

int Soh_GetSpaceMode(void) {
    return sSohSpaceMode;
}

// Every exit path, including the Digital Crown's (trap C1 / spec D8):
// pause the game and write the config synchronously, because a system
// dismissal is frequently the first half of a swipe-kill and swipe-kill is
// SIGKILL. Idempotent — the pause request self-clears in 0049 and CVarSave is
// cheap and repeatable.
static void Soh_ImmersiveExitSafety(const char* why) {
    extern volatile int gSohIosPauseReq;
    extern void SohIos_FlushConfig(const char* why);
    gSohIosPauseReq = 1;
    SohIos_FlushConfig(why);
}

void Soh_EnterMode(int mode) {
    // UIKit work below (curtain, geometry) — marshal any off-main caller.
    // The GCD main queue drains now (shell 60 Hz drain timer), so this is
    // reliable from any thread, including the console bridge.
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ Soh_EnterMode(mode); });
        return;
    }
    if (mode < 0 || mode > 2) {
        return;
    }
    if (mode == sSohSpaceMode) {
        return;
    }
    if (mode != 0 && sSohSpaceMode != 0) {
        // 3D <-> VR: dismiss first, reopen when the loop has really stopped.
        NSLog(@"[SohHost] mode %d -> %d: dismiss-then-open", sSohSpaceMode, mode);
        sSohPendingMode = mode;
        Soh_EnterMode(0);
        return;
    }
    bool on = (mode != 0);
    if (on) {
        if (gSoh3DMode) {
            return;
        }
        sSohSpaceMode = mode;
        SohVR_SetMode(mode);
        NSLog(@"[SohHost] entering mode %d: engine offscreen, opening space", mode);
        // D-041: the 3D menu is display-only, and there's no "Menu" button in
        // immersive anymore. If the 2D menu is open when we enter, close it now
        // — while still 2D-focused (before the space opens and steals SDL's
        // input focus), so the esc actually lands — so we never render a dead,
        // non-interactive menu on the panel.
        {
            extern int SohIos_IsMenuOpen(void);
            extern void SohIos_ToggleMenuKey(void);
            if (SohIos_IsMenuOpen()) {
                SohIos_ToggleMenuKey(); // gSoh3DMode still 0 -> esc -> closes it
            }
        }
        // Capture the pre-3D size at entry START, before anything moves, and
        // never re-capture an already-parked size (the "window stays tiny"
        // trap — guide §2.7).
        extern CGSize SohIos_RestorePendingTarget(void);
        extern void SohIos_RestoreCancel(void);
        CGSize pending = SohIos_RestorePendingTarget();
        SohIos_RestoreCancel(); // a live restore timer would fight the parking
        if (soh_pre3dSize.width < 1) {
            if (pending.width >= 1) {
                // Re-entered mid-restore: the scene is a half-restored
                // transient — the in-flight target IS the true pre-3D size.
                soh_pre3dSize = pending;
            } else {
                UIWindowScene* scene = Soh_KeyGameWindow().windowScene;
                soh_pre3dSize = scene ? scene.coordinateSpace.bounds.size : CGSizeZero;
            }
            NSLog(@"[SohHost] captured pre-3D size %.0fx%.0f", soh_pre3dSize.width, soh_pre3dSize.height);
        }
        gSoh3DMode = 1; // BEFORE the space opens (drawable-acquire stall trap)
        // R3 (design ruling): the touch chips are flat-screen controls. They sit
        // above the curtain, so in an immersive mode they float in the world as
        // a cluster of dead buttons — hide the whole layer here and restore it
        // in the (unconditional, idempotent) exit finalize. The ornament is a
        // separate SwiftUI surface and keeps owning Exit.
        {
            extern void SohIos_SetTouchControlsHidden(int hidden);
            SohIos_SetTouchControlsHidden(1);
        }
        Soh_SetSpaceMode((int32_t)mode);
        // Park AFTER entry settles (a resize animation racing the transition
        // wedged a sibling); curtain immediately — the frozen frame confuses.
        Soh_SetCurtain2(true, mode);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           if (gSoh3DMode) {
                               Soh_RequestWindowSize(CGSizeMake(480, 320));
                           }
                       });
    } else {
        if (!gSoh3DMode) {
            return;
        }
        NSLog(@"[SohHost] exiting mode %d: stopping render thread first", sSohSpaceMode);
        Soh_ImmersiveExitSafety("immersive-exit");
        sSohSpaceMode = 0;
        SohVR_SetMode(0);
        gSoh3DStop = 1;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            // Wait for the loop to leave the layerRenderer (2 s timeout — it
            // paces at the compositor cadence, so this is normally <30 ms).
            // BOUNDED, always: a render thread blocked on a paused layer would
            // otherwise never run its exit code (trap C1).
            for (int i = 0; i < 200 && gSoh3DRunning; i++) {
                usleep(10 * 1000);
            }
            if (gSoh3DRunning) {
                NSLog(@"[SohHost] WARNING: render thread still running at dismiss");
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                Soh_SetSpaceMode(0); // Swift dismisses, then finalizes
            });
        });
    }
}

// Compatibility shim: the ornament, the bridge and the rollback path all still
// speak the original boolean.
void Soh_Enter3D(bool on) {
    Soh_EnterMode(on ? 1 : 0);
}

void Soh_EnterVR(bool on) {
    Soh_EnterMode(on ? 2 : 0);
}

// Live stereo tuning from the SwiftUI sheet: CVar-backed (the eye passes
// read these every pass), persisted with the rest of the config.
extern void CVarSetFloat(const char* name, float value);
extern void CVarSave(void);
void Soh3D_SetStereoParams(float depthFrac, float convBias) {
    // NOTE round-5 bug: this wrote the OLD CVar names (StereoSep/StereoConv)
    // while the adaptive engine reads StereoDepth/StereoConvBias — the Depth
    // slider was connected to nothing. Names now match the engine.
    CVarSetFloat("gSohIos.StereoDepth", depthFrac);
    CVarSetFloat("gSohIos.StereoConvBias", convBias);
    CVarSave();
}

void Soh_Exit3DFinalize(void) {
    NSLog(@"[SohHost] immersive exit finalized — engine back onscreen");
    // Unconditional and idempotent (trap C1): whichever path got here — the
    // ornament, the Crown, a system dismissal — the engine goes back on the
    // window swapchain, the curtain drops, the window is restored, the game is
    // paused and the config is on disk.
    Soh_ImmersiveExitSafety("immersive-finalize");
    SohVR_SetMode(0);
    gSoh3DMode = 0;
    Soh_SetCurtain(false);
    {
        // Flat again: the touch layer comes back (R3, and unconditional here
        // for the same reason everything else in this function is — whichever
        // path got us out, the flat game must be whole).
        extern void SohIos_SetTouchControlsHidden(int hidden);
        SohIos_SetTouchControlsHidden(0);
    }
    // Restore to the EXACT size captured before entering 3D (predecessor
    // ports' pattern) — the controller requests the geometry, waits for the
    // scene to land, adopts the view chain, and verifies the engine followed
    // (round 13: blind timed adopts left the engine rendering a stale larger
    // size, top-left cropped).
    extern void SohIos_RestoreWindowTo(CGSize target);
    SohIos_RestoreWindowTo(soh_pre3dSize);
    soh_pre3dSize = CGSizeMake(0, 0); // allow a fresh capture next entry
    // A 3D<->VR switch parked its target here: open the other space now that
    // this one is fully gone (spec D1 — never mutate a live space's
    // configuration; dismiss, then open).
    if (sSohPendingMode > 0) {
        int next = sSohPendingMode;
        sSohPendingMode = -1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ Soh_EnterMode(next); });
    }
}

// Crown/system dismissal (loop saw layer invalidated): reconcile the shell +
// SwiftUI state so the ornament button and engine mode match reality.
// Crown/system dismissal is a FIRST-CLASS exit path (trap C1), not a variant
// of the ornament's: the loop already left the layer, so all that remains is
// to reconcile the shell + SwiftUI state and run the same unconditional
// safety work every other exit runs.
void Soh3D_Immersive_Ended(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gSoh3DMode) {
            NSLog(@"[SohHost] immersive ended by system — reconciling to 2D");
            Soh_ImmersiveExitSafety("system-dismissal");
            sSohSpaceMode = 0;
            SohVR_SetMode(0);
            Soh_SetSpaceMode(0);
        }
    });
}
