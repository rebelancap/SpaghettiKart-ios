// SohImmersive.m — visionOS stereoscopic "3D screen" render loop.
//
// Near-verbatim port of vkQuake-ios VKQImmersive.m (proven on this user's
// device), retargeted at SoH/Fast3D: the engine renders BOTH eyes per host
// frame into two offscreen Metal textures (Fast3D framebuffers, overlay-side);
// this loop composites them onto a world-locked quad — left texture to the
// left eye slice, right to the right — with the ARKit head pose placing the
// panel, never the aim.
//
// The loop shape is LOAD-BEARING (guide §2.3): frame pacing via
// cp_time_wait_until(optimal_input_time) + a per-frame ar device anchor set on
// the drawable + cleared/written depth + a command queue created from the
// drawable's own device + @autoreleasepool. Remove any one and the panel is
// black or the process aborts.

#import "SohImmersive.h"
#import "SohSense.h"
#import <Metal/Metal.h>
#import <ARKit/ARKit.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>
#import <ImageIO/ImageIO.h>            // R16-C: the pane framebuffer, as a PNG
#import <UniformTypeIdentifiers/UTCoreTypes.h>

// VR core observers (implemented at the bottom of this file). They are pure
// observers of the presenting loop — no rendering behaviour depends on them,
// so the 3D-panel path stays byte-equivalent in behaviour.
static void sohvr_capture_contract(cp_drawable_t drawable);
static void sohvr_build_foveation_map(id<MTLDevice> dev); // R9 item 1c
static void sohvr_publish_pose(simd_float4x4 originFromHead, int anchorNow);
static void sohvr_note_present(void);

volatile int gSoh3DStop = 0;
volatile int gSoh3DRunning = 0;
static int soh3d_frameCount = 0;

// R14 item 5 — the hitch suspects. Declared here because the first of them is
// incremented well above sohvr_note_present, which is where they are sampled.
static unsigned int sSohVRWorldFlaps, sSohVRSeatFlips, sSohVRDumps, sSohVRDtFalls;
static unsigned int sSohVRHitches = 0;
static double sSohVRHitchAt = 0.0;
static double sSohVRHitchMs = 0.0;
static double sSohVRFrameMsAvg = 0.0;
static double sSohVRPresentLast = 0.0;
// The suspects, sampled AT the hitch so the caption can name one. Each is a
// snapshot of a counter that is also live in `vr pace`.
static unsigned int sSohVRHitchWorldFlaps = 0, sSohVRHitchSeatFlips = 0;
static unsigned int sSohVRHitchDumps = 0, sSohVRHitchDtFalls = 0, sSohVRHitchRebases = 0;

// --- world-lock math ---------------------------------------------------------
static simd_float4x4 soh3d_translate(float x, float y, float z) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[3] = simd_make_float4(x, y, z, 1.0f);
    return m;
}
static simd_float4x4 soh3d_scale(float x, float y, float z) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0].x = x;
    m.columns[1].y = y;
    m.columns[2].z = z;
    return m;
}

// Panel placement: captured from the head pose once tracking converges, then
// world-locked; recomputed from the frozen head each frame so live tuning of
// distance/size moves the panel in real time.
static float soh3d_screenDist = 3.6f;  // metres from the captured head position
static float soh3d_screenHalfW = 2.75f;
static float soh3d_screenHalfH = 1.55f;
static float soh3d_screenHeight = 0.0f; // metres above eye level

// --- eye extent: ONE owner (R1 debt, paid in R2) -----------------------------
// gSoh3DEyeW/H had two writers — Soh3D_SetPanel derived them from the panel
// aspect, and the VR loop derived them from the drawable extent x render scale
// (trap D7). In VR the loop happened to win every frame because it ran later,
// which is a race dressed as a rule. Now there is a single setter with an
// explicit priority: VR (2) outranks the panel (1), and the panel's value is
// remembered so leaving VR restores it exactly.
enum { SOH_EYE_OWNER_NONE = 0, SOH_EYE_OWNER_PANEL = 1, SOH_EYE_OWNER_VR = 2 };
static int sSohEyeOwner = SOH_EYE_OWNER_NONE;
static int sSohEyePanelW = 0, sSohEyePanelH = 0;

static void soh3d_set_eye_extent(int owner, int w, int h) {
    extern volatile int gSoh3DEyeW, gSoh3DEyeH;
    if (w < 128 || h < 128) {
        return;
    }
    if (owner == SOH_EYE_OWNER_PANEL) {
        sSohEyePanelW = w;
        sSohEyePanelH = h;
    }
    if (owner < sSohEyeOwner) {
        return; // a higher-priority owner holds the extent
    }
    sSohEyeOwner = owner;
    gSoh3DEyeW = w;
    gSoh3DEyeH = h;
}

// Called when the VR loop stops: hand the extent back to the panel's value.
static void soh3d_release_vr_eye_extent(void) {
    if (sSohEyeOwner != SOH_EYE_OWNER_VR) {
        return;
    }
    sSohEyeOwner = SOH_EYE_OWNER_NONE;
    if (sSohEyePanelW >= 128 && sSohEyePanelH >= 128) {
        soh3d_set_eye_extent(SOH_EYE_OWNER_PANEL, sSohEyePanelW, sSohEyePanelH);
    }
}

void Soh3D_SetPanel(float dist, float halfW, float halfH) {
    if (dist >= 1.0f && dist <= 8.0f)
        soh3d_screenDist = dist;
    if (halfW >= 0.6f && halfW <= 4.0f)
        soh3d_screenHalfW = halfW;
    if (halfH >= 0.4f && halfH <= 3.0f)
        soh3d_screenHalfH = halfH;
    // D-V5 (device feedback, first VP round): the EYE RENDER follows the
    // panel's aspect — like the 2D window, a wider/taller panel extends the
    // game's FOV instead of stretching a fixed 16:9 image. Long edge pinned
    // at 3840; the engine reads these globals every StartFrame (0044) and
    // its diff-guard reallocs the eye fb once per change (instant); the
    // compositor's sampling copies re-create on size mismatch.
    {
        float sohAspect = soh3d_screenHalfW / soh3d_screenHalfH;
        int sohW, sohH;
        if (sohAspect >= 1.0f) {
            sohW = 3840;
            sohH = (int)(3840.0f / sohAspect + 0.5f);
        } else {
            sohH = 3840;
            sohW = (int)(3840.0f * sohAspect + 0.5f);
        }
        sohW &= ~1;
        sohH &= ~1;
        if (sohW < 128)
            sohW = 128;
        if (sohH < 128)
            sohH = 128;
        soh3d_set_eye_extent(SOH_EYE_OWNER_PANEL, sohW, sohH);
    }
}
void Soh3D_SetHeight(float h) {
    if (h >= -1.5f && h <= 10.0f)
        soh3d_screenHeight = h;
}

static bool soh3d_haveScreenAnchor = false;
static simd_float4x4 soh3d_frozenHead;

void Soh3D_Recenter(void) {
    soh3d_haveScreenAnchor = false; // next tracked frame re-captures the pose
    // R5 (bug 1b): the same gesture has to recentre the VR WORLD, not only the
    // 3D panel. Before this, the stick-hold recenter did nothing at all in VR.
    extern void SohVR_Recenter(void);
    SohVR_Recenter();
}

// Surroundings dimming: fullscreen black layer under the panel. Perceptual
// curve 1-(1-d)^2.2 — linear "doesn't get dark until 80%" (vkQuake-measured).
static float soh3d_dimLevel = 0.0f;
void Soh3D_SetDim(float dim) {
    dim = (dim < 0.0f) ? 0.0f : (dim > 1.0f) ? 1.0f : dim;
    soh3d_dimLevel = 1.0f - powf(1.0f - dim, 2.2f);
}

static simd_float4x4 soh3d_make_screen_anchor(simd_float4x4 originFromDevice) {
    simd_float3 headPos = originFromDevice.columns[3].xyz;
    simd_float3 fwd = -originFromDevice.columns[2].xyz; // gaze forward
    fwd.y = 0.0f;                                       // level (no pitch/roll)
    float len = simd_length(fwd);
    fwd = (len < 1e-4f) ? simd_make_float3(0, 0, -1) : fwd / len;

    simd_float3 pos = headPos + fwd * soh3d_screenDist;
    pos.y += soh3d_screenHeight;
    simd_float3 normal = simd_normalize(headPos - pos);
    simd_float3 up = simd_make_float3(0, 1, 0);
    simd_float3 right = simd_normalize(simd_cross(up, normal));
    up = simd_cross(normal, right);

    simd_float4x4 m;
    m.columns[0] = simd_make_float4(right, 0.0f);
    m.columns[1] = simd_make_float4(up, 0.0f);
    m.columns[2] = simd_make_float4(normal, 0.0f);
    m.columns[3] = simd_make_float4(pos, 1.0f);
    return m;
}

// Persistent mipmapped per-eye sampling copies of the engine's eye textures.
static id<MTLTexture> soh3d_eyeCopy[2];

// R13 item 1c — THE ONE UNCHECKED ALLOCATION IN THE COMPOSITOR, and it is the
// screenshot-shaped one. Both eye-copy sites called
// `newTextureWithDescriptor:` and passed the result straight into
// `copyFromTexture:toTexture:` on the next statement. These are full
// eye-extent MIPMAPPED textures — the largest single object the compositor
// asks for — and a nil destination is not a dropped frame, it is a Metal
// assertion and a SIGTRAP/SIGABRT. A Siri screenshot is exactly the moment
// where the allocation can fail AND the app is pushed out of a world frame
// onto this path. Counted, logged once, and the frame simply skips its copy.
// The fbfail knob is honoured here too, so the guard has a red control.
extern volatile int gSohIosGfxFbFailIn;
// R16-A — the round's counters and knobs (defined in SohIosShell.m, where
// every target links them). File scope: they are read from the world
// matrix, the sky shift, the present loop and both dump lines.
extern volatile int gSoh3DInPlay;
extern volatile unsigned int gSohVRSeatFallbacks;
extern volatile float gSohVRWorldYawStepMax;
extern volatile int gSohVRKartHoleFault;
extern volatile int gSohVRYawSnap;
extern volatile unsigned int gSohVREyeBlank[2];
extern volatile unsigned int gSohVREyeMono;
extern volatile int gSohVREyePubHoldMs;
extern volatile int gSohVREyePubAtomic;
extern volatile unsigned int gSohVRPubOrphans;
extern volatile int gSohVRPairHold;
// R16-A F4: the fields the per-frame snapshot is assembled from. They are
// written by SohVR_ComposeEyes and read once, at publish time.
extern volatile float gSohVRSkyShift[2];
extern volatile float gSohVRSkyPxPerBam, gSohVRSkyPxCenter;
extern volatile int gSohVREyeYawBam;
extern volatile float gSohVREyePosGame[3];
extern volatile float gSohVREyeFovDeg, gSohVREyePitchDeg;
extern volatile unsigned int gSohVRSkyShiftId;
extern volatile unsigned int gSohVRSnapId, gSohVRSnapLatches;
extern volatile unsigned int gSohVRSkyShiftTag[2];
extern volatile unsigned int gSohVRSkyTagSkew;
extern volatile int gSohVRSkyLatch;
// R16-B — the sprite layout's reference frustum, the per-eye remap, the union
// bounds and the two knobs. Written here, published in the snapshot, consumed
// by 0051 (the layout) and 0044 (the eye pass).
extern volatile float gSohVRSkyTanSum, gSohVRSkySpan, gSohVRSkySpanY;
extern volatile float gSohVRSkyEyeDx[2], gSohVRSkyEyeSx[2];
extern volatile float gSohVRSkyTanLo, gSohVRSkyTanHi;
extern volatile float gSohVRSkyRollRad[2];
extern volatile int gSohVRSkyTan;
extern volatile float gSohVRSkyRoll;
extern volatile int gSohVRSkyBuiltYawBam;
extern volatile unsigned int gSohVRSkyBuilds;
extern volatile float gSohVRSkyLagDeg, gSohVRSkyLagMaxDeg;
extern volatile unsigned int gSohVRSkyAffine[3];
extern volatile unsigned int gSohVRSkyLagCorr;
extern volatile int gSohVRSkyRate;
extern volatile int gSohVRSnapEyeYawBam;
static unsigned int sSohVRCopySkips = 0;
static id<MTLTexture> soh3d_eyecopy_new(id<MTLDevice> dev, MTLTextureDescriptor* td) {
    id<MTLTexture> t = nil;
    if (gSohIosGfxFbFailIn > 0) {
        gSohIosGfxFbFailIn = gSohIosGfxFbFailIn - 1;
        if (gSohIosGfxFbFailIn == 0) {
            t = nil; // injected failure
        } else {
            t = [dev newTextureWithDescriptor:td];
        }
    } else {
        t = [dev newTextureWithDescriptor:td];
    }
    if (t == nil) {
        sSohVRCopySkips++;
        if (sSohVRCopySkips <= 8) {
            NSLog(@"[SohVR] eye-copy allocation FAILED (%lux%lu) — skipping the copy for this frame "
                  @"(copy_skips=%u)",
                  (unsigned long)td.width, (unsigned long)td.height, sSohVRCopySkips);
        }
    }
    return t;
}

// R11 review finding — hiding the frame-tag strip on the PANEL paths.
//
// Overlay 0044 rev5 stamps the pose tag's low byte into eight texels at the eye
// texture's origin, which is the top-left of the visible image. The VR world
// blit hides that strip in its fragment shader (sohvr_world_fs, which cannot
// touch the texture because the tag read-back blit reads it directly). The two
// panel paths cannot do that — they hand the copy to the shipped quad/plane
// shaders, which have no idea a tag exists — but they do not have to: they
// sample a COPY, not the engine's texture, so the strip can simply be painted
// over IN THE COPY. The eight texels immediately to its RIGHT (not the row
// below — see sohvr_world_fs for why the row matters), same texture,
// non-overlapping regions, encoded before the mipmap generation that would
// otherwise smear the tag up the chain. The engine's texture, and therefore
// the probe, is untouched.
static void soh3d_scrub_tag_strip(id<MTLBlitCommandEncoder> blit, id<MTLTexture> copy) {
    extern volatile int gSohVREyeTagOn;
    if (!gSohVREyeTagOn || copy == nil || copy.width < 24 || copy.height < 2) {
        return;
    }
    [blit copyFromTexture:copy
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(8, 0, 0)
               sourceSize:MTLSizeMake(8, 1, 1)
                toTexture:copy
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
}

// Test pattern shown until the engine's eye framebuffers exist (M2 gate: the
// compositor path is verifiable in the sim before any Fast3D work lands).
static id<MTLTexture> soh3d_testPattern;
static id<MTLTexture> soh3d_make_test_pattern(id<MTLDevice> dev) {
    const int W = 640, H = 360, TILE = 40;
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:W
                                                                                 height:H
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    uint32_t* px = malloc(W * H * 4);
    for (int y = 0; y < H; y++) {
        for (int x = 0; x < W; x++) {
            bool a = ((x / TILE) + (y / TILE)) & 1;
            // magenta/teal checker: unmistakably "test pattern", never "bug"
            px[y * W + x] = a ? 0xFFB4287D : 0xFF7DB428;
        }
    }
    [t replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:px bytesPerRow:W * 4];
    free(px);
    return t;
}

// One-shot fidelity report: measures the ACTUAL panel supersample ratio
// (drawable px/FOV vs panel angular size vs game texture) so resolution is a
// number, not a guess. Written to Documents/vp3d-fidelity.log (OTA-readable).
static bool soh3d_fidelityLogged = false;
static void soh3d_log_fidelity(cp_drawable_t drawable, id<MTLTexture> gameTex) {
    if (soh3d_fidelityLogged || gameTex == nil)
        return;
    cp_view_t view = cp_drawable_get_view(drawable, 0);
    MTLViewport vp = cp_view_texture_map_get_viewport(cp_view_get_view_texture_map(view));
    simd_float4x4 proj = matrix_identity_float4x4;
    if (__builtin_available(visionOS 2.0, *))
        proj = cp_drawable_compute_projection(drawable, cp_axis_direction_convention_right_up_back, 0);
    double m00 = fabs(proj.columns[0].x), m11 = fabs(proj.columns[1].y);
    double fovH = (m00 > 1e-6) ? 2.0 * atan(1.0 / m00) : 0.0;
    double fovV = (m11 > 1e-6) ? 2.0 * atan(1.0 / m11) : 0.0;
    if (vp.width < 1 || vp.height < 1 || fovH < 1e-4 || fovV < 1e-4)
        return;
    double pxPerRadH = vp.width / fovH, pxPerRadV = vp.height / fovV;
    double panAngH = 2.0 * atan(soh3d_screenHalfW / soh3d_screenDist);
    double panAngV = 2.0 * atan(soh3d_screenHalfH / soh3d_screenDist);
    double footH = panAngH * pxPerRadH, footV = panAngV * pxPerRadV;
    double ssH = footH > 1 ? gameTex.width / footH : 0.0;
    double ssV = footV > 1 ? gameTex.height / footV : 0.0;

    NSString* docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString* report = [NSString
        stringWithFormat:@"Ship of Harkinian Vision Pro 3D fidelity report\n"
                          "===============================================\n"
                          "Compositor drawable (per eye): %.0f x %.0f px\n"
                          "Per-eye FOV: %.1f x %.1f deg\n"
                          "Game render target (per eye): %lu x %lu px\n"
                          "Panel angular size: %.1f x %.1f deg\n"
                          "Panel footprint in drawable: %.0f x %.0f px\n"
                          "SUPERSAMPLE RATIO: %.2fx H, %.2fx V (%s)\n",
                         (double)vp.width, (double)vp.height, fovH * 180.0 / M_PI, fovV * 180.0 / M_PI,
                         (unsigned long)gameTex.width, (unsigned long)gameTex.height, panAngH * 180.0 / M_PI,
                         panAngV * 180.0 / M_PI, footH, footV, ssH, ssV,
                         (ssH >= 1.0 && ssV >= 1.0) ? "supersampling" : "UNDERSAMPLING"];
    [report writeToFile:[docs stringByAppendingPathComponent:@"vp3d-fidelity.log"]
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:NULL];
    NSLog(@"[Soh3D] fidelity: drawable %.0fx%.0f/eye game %lux%lu supersample %.2fx/%.2fx", (double)vp.width,
          (double)vp.height, (unsigned long)gameTex.width, (unsigned long)gameTex.height, ssH, ssV);
    soh3d_fidelityLogged = true;
}

// Panel quad + dim layer pipelines, compiled at runtime from drawable formats.
static id<MTLRenderPipelineState> soh3d_pipeline;
static id<MTLRenderPipelineState> soh3d_dimPipeline;
static id<MTLDepthStencilState> soh3d_depthState;
static id<MTLDepthStencilState> soh3d_dimDepthState;

static NSString* const kSoh3DQuadShader =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VOut { float4 pos [[position]]; float2 uv; };\n"
     "vertex VOut soh3d_vs(uint vid [[vertex_id]], constant float4x4& mvp [[buffer(0)]]) {\n"
     "  const float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
     "  VOut o; o.pos = mvp * float4(p[vid], 0.0, 1.0);\n"
     "  o.uv = float2((p[vid].x+1.0)*0.5, 1.0-(p[vid].y+1.0)*0.5);\n"
     "  return o;\n"
     "}\n"
     "fragment float4 soh3d_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
     "                         constant float& srgbDecode [[buffer(0)]]) {\n"
     "  constexpr sampler s(filter::linear, mip_filter::linear, max_anisotropy(16));\n"
     "  float4 c = tex.sample(s, in.uv);\n"
     "  if (srgbDecode > 0.5) c.rgb = pow(c.rgb, float3(2.2));\n"
     "  return float4(c.rgb, 1.0);\n"
     "}\n"
     "vertex float4 soh3d_dim_vs(uint vid [[vertex_id]]) {\n"
     "  const float2 p[3] = { float2(-1,-3), float2(3,1), float2(-1,1) };\n"
     "  return float4(p[vid], 0.9999, 1.0);\n"
     "}\n"
     "fragment float4 soh3d_dim_fs(constant float& dim [[buffer(0)]]) {\n"
     "  return float4(0.0, 0.0, 0.0, dim);\n"
     "}\n";

static void soh3d_build_pipeline(id<MTLDevice> dev, MTLPixelFormat colorFmt, MTLPixelFormat depthFmt) {
    NSError* err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kSoh3DQuadShader options:nil error:&err];
    if (!lib) {
        NSLog(@"[Soh3D] shader compile FAILED: %@", err.localizedDescription);
        return;
    }
    MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"soh3d_vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"soh3d_fs"];
    pd.colorAttachments[0].pixelFormat = colorFmt;
    pd.depthAttachmentPixelFormat = depthFmt;
    soh3d_pipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!soh3d_pipeline) {
        NSLog(@"[Soh3D] pipeline FAILED: %@", err.localizedDescription);
        return;
    }
    MTLDepthStencilDescriptor* dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionAlways;
    dd.depthWriteEnabled = YES; // compositor reprojects on depth; must be real
    soh3d_depthState = [dev newDepthStencilStateWithDescriptor:dd];

    MTLRenderPipelineDescriptor* dp = [MTLRenderPipelineDescriptor new];
    dp.vertexFunction = [lib newFunctionWithName:@"soh3d_dim_vs"];
    dp.fragmentFunction = [lib newFunctionWithName:@"soh3d_dim_fs"];
    dp.colorAttachments[0].pixelFormat = colorFmt;
    dp.colorAttachments[0].blendingEnabled = YES;
    dp.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    dp.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    dp.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    dp.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    dp.depthAttachmentPixelFormat = depthFmt;
    soh3d_dimPipeline = [dev newRenderPipelineStateWithDescriptor:dp error:&err];
    if (!soh3d_dimPipeline)
        NSLog(@"[Soh3D] dim pipeline FAILED: %@", err.localizedDescription);
    MTLDepthStencilDescriptor* dd2 = [MTLDepthStencilDescriptor new];
    dd2.depthCompareFunction = MTLCompareFunctionAlways;
    dd2.depthWriteEnabled = YES;
    soh3d_dimDepthState = [dev newDepthStencilStateWithDescriptor:dd2];
    NSLog(@"[Soh3D] quad pipeline built (colorFmt=%lu depthFmt=%lu)", (unsigned long)colorFmt,
          (unsigned long)depthFmt);
}

void Soh3D_Immersive_Run(cp_layer_renderer_t layer_renderer) {
    gSoh3DStop = 0;
    gSoh3DRunning = 1;
    int notifyEnded = 0; // only a system/Crown dismissal reconciles via Ended

    id<MTLCommandQueue> queue = nil;
    soh3d_frameCount = 0;
    soh3d_haveScreenAnchor = false; // re-center each time 3D is entered
    soh3d_eyeCopy[0] = soh3d_eyeCopy[1] = nil;
    soh3d_fidelityLogged = false;

    ar_world_tracking_configuration_t wtc = ar_world_tracking_configuration_create();
    ar_world_tracking_provider_t wtp = ar_world_tracking_provider_create(wtc);
    ar_session_t arSession = ar_session_create();
    ar_data_providers_t providers = ar_data_providers_create_with_data_providers(wtp, NULL);
    ar_session_run(arSession, providers);

    NSLog(@"[Soh3D] render loop started (ARKit world tracking running)");

    int running = 1;
    while (running) {
        if (gSoh3DStop) {
            NSLog(@"[Soh3D] stop requested, exiting cleanly (frames=%d)", soh3d_frameCount);
            running = 0;
            continue;
        }
        switch (cp_layer_renderer_get_state(layer_renderer)) {
            case cp_layer_renderer_state_paused:
                cp_layer_renderer_wait_until_running(layer_renderer);
                continue;
            case cp_layer_renderer_state_invalidated:
                NSLog(@"[Soh3D] layer invalidated, exiting loop (frames=%d)", soh3d_frameCount);
                notifyEnded = 1;
                running = 0;
                continue;
            case cp_layer_renderer_state_running:
            default:
                break;
        }

        @autoreleasepool {
            cp_frame_t frame = cp_layer_renderer_query_next_frame(layer_renderer);
            if (frame == NULL)
                continue;

            cp_frame_timing_t timing = cp_frame_predict_timing(frame);
            cp_frame_start_update(frame);
            cp_frame_end_update(frame);
            cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));

            cp_frame_start_submission(frame);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            cp_drawable_t drawable = cp_frame_query_drawable(frame);
#pragma clang diagnostic pop
            if (drawable == NULL) {
                // A failed drawable query INVALIDATES the frame — calling
                // end_submission on it ABORTS (guide trap list; device crash
                // 2026-07-16: the window-parking geometry animation at entry
                // +1.5s makes the compositor skip a drawable). Just drop it.
                continue;
            }

            if (queue == nil) {
                id<MTLTexture> t0 = cp_drawable_get_color_texture(drawable, 0);
                queue = [t0.device newCommandQueue];
                soh3d_build_pipeline(t0.device, t0.pixelFormat,
                                     cp_drawable_get_depth_texture(drawable, 0).pixelFormat);
                soh3d_testPattern = soh3d_make_test_pattern(t0.device);
                sohvr_capture_contract(drawable); // D11 harness: contract line
                NSLog(@"[Soh3D] drawable %lux%lu views=%zu colorFmt=%lu", (unsigned long)t0.width,
                      (unsigned long)t0.height, cp_drawable_get_view_count(drawable),
                      (unsigned long)t0.pixelFormat);
            }

            CFTimeInterval presTime = cp_time_to_cf_time_interval(
                cp_frame_timing_get_presentation_time(cp_drawable_get_frame_timing(drawable)));
            ar_device_anchor_t anchor = ar_device_anchor_create();
            ar_device_anchor_query_status_t anchorStatus =
                ar_world_tracking_provider_query_device_anchor_at_timestamp(wtp, presTime, anchor);
            cp_drawable_set_device_anchor(drawable, anchor);

            if (!soh3d_haveScreenAnchor && anchorStatus == ar_device_anchor_query_status_success &&
                soh3d_frameCount > 30) {
                soh3d_frozenHead = ar_device_anchor_get_origin_from_anchor_transform(anchor);
                soh3d_haveScreenAnchor = true;
                sohvr_publish_pose(soh3d_frozenHead, 1); // D11 harness: entry anchor
                NSLog(@"[Soh3D] screen anchored at head (%.2f,%.2f,%.2f)", soh3d_frozenHead.columns[3].x,
                      soh3d_frozenHead.columns[3].y, soh3d_frozenHead.columns[3].z);
            }

            id<MTLCommandBuffer> command_buffer = [queue commandBuffer];

            // Copy both per-eye engine textures into mipmapped sampling copies
            // (on THIS queue, so copy + sample are coherent). Falls back to the
            // test pattern until the engine's eye framebuffers exist.
            id<MTLTexture> monoTex = nil;
            for (int e = 0; e < 2; e++) {
                id<MTLTexture> src = (__bridge id<MTLTexture>)Soh3D_GetEyeMTLTexture(e + 1);
                if (!src)
                    continue;
                monoTex = src;
                if (soh3d_eyeCopy[e] == nil || soh3d_eyeCopy[e].width != src.width ||
                    soh3d_eyeCopy[e].height != src.height || soh3d_eyeCopy[e].pixelFormat != src.pixelFormat) {
                    MTLTextureDescriptor* td =
                        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
                                                                           width:src.width
                                                                          height:src.height
                                                                       mipmapped:YES];
                    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
                    td.storageMode = MTLStorageModePrivate;
                    soh3d_eyeCopy[e] = soh3d_eyecopy_new(src.device, td);
                }
                if (soh3d_eyeCopy[e] == nil) {
                    continue; // R13 item 1c: no destination, no copy this frame
                }
                id<MTLBlitCommandEncoder> blit = [command_buffer blitCommandEncoder];
                [blit copyFromTexture:src toTexture:soh3d_eyeCopy[e]];
                soh3d_scrub_tag_strip(blit, soh3d_eyeCopy[e]);
                if (soh3d_eyeCopy[e].mipmapLevelCount > 1)
                    [blit generateMipmapsForTexture:soh3d_eyeCopy[e]];
                [blit endEncoding];
            }
            if (monoTex == nil)
                monoTex = soh3d_testPattern;

            id<MTLTexture> color = cp_drawable_get_color_texture(drawable, 0);
            id<MTLTexture> depth = cp_drawable_get_depth_texture(drawable, 0);
            size_t views = cp_drawable_get_view_count(drawable);

            simd_float4x4 placement = soh3d_haveScreenAnchor ? soh3d_make_screen_anchor(soh3d_frozenHead)
                                                             : soh3d_translate(0.0f, 0.0f, -soh3d_screenDist);
            simd_float4x4 model = simd_mul(placement, soh3d_scale(soh3d_screenHalfW, soh3d_screenHalfH, 1.0f));
            simd_float4x4 originFromDevice = ar_device_anchor_get_origin_from_anchor_transform(anchor);

            if (soh3d_haveScreenAnchor && soh3d_frameCount > 60)
                soh3d_log_fidelity(drawable, monoTex);

            float srgbDecode = 0.0f;
            {
                MTLPixelFormat sf = monoTex.pixelFormat, df = color.pixelFormat;
                BOOL srcEncoded = (sf == MTLPixelFormatBGRA8Unorm || sf == MTLPixelFormatRGBA8Unorm);
                BOOL dstLinear = (df == MTLPixelFormatBGRA8Unorm_sRGB || df == MTLPixelFormatRGBA8Unorm_sRGB ||
                                  df == MTLPixelFormatRGBA16Float);
                srgbDecode = (srcEncoded && dstLinear) ? 1.0f : 0.0f;
            }

            for (size_t v = 0; v < views; v++) {
                // D-036 rev3: fully layout-agnostic targeting via the view's
                // texture map (dedicated layout: texture per view, slice 0;
                // layered: texture 0, slice per view). With foveation each
                // DEDICATED view carries its own rate map, indexed by the
                // view's texture index — attaching the wrong eye's map is the
                // round-1 "right eye fisheye that moves with the head".
                cp_view_t soh3dView = cp_drawable_get_view(drawable, v);
                cp_view_texture_map_t soh3dTmap = cp_view_get_view_texture_map(soh3dView);
                size_t soh3dTexIdx = cp_view_texture_map_get_texture_index(soh3dTmap);
                size_t soh3dSlice = cp_view_texture_map_get_slice_index(soh3dTmap);
                MTLViewport soh3dVp = cp_view_texture_map_get_viewport(soh3dTmap);

                MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
                pass.colorAttachments[0].texture = cp_drawable_get_color_texture(drawable, soh3dTexIdx);
                pass.colorAttachments[0].slice = soh3dSlice;
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
                {
                    size_t soh3dRmCount = cp_drawable_get_rasterization_rate_map_count(drawable);
                    if (soh3dRmCount > 0) {
                        pass.rasterizationRateMap = cp_drawable_get_rasterization_rate_map(
                            drawable, soh3dTexIdx < soh3dRmCount ? soh3dTexIdx : 0);
                    }
                }
                id<MTLTexture> soh3dDepthTex = cp_drawable_get_depth_texture(drawable, soh3dTexIdx);
                if (soh3dDepthTex) {
                    pass.depthAttachment.texture = soh3dDepthTex;
                    pass.depthAttachment.slice = soh3dSlice;
                    pass.depthAttachment.loadAction = MTLLoadActionClear;
                    pass.depthAttachment.storeAction = MTLStoreActionStore;
                    pass.depthAttachment.clearDepth = 1.0;
                }
                // This eye's texture: its own stereo image if ready, else mono.
                id<MTLTexture> tex = (v < 2 && soh3d_eyeCopy[v]) ? soh3d_eyeCopy[v] : monoTex;

                id<MTLRenderCommandEncoder> enc = [command_buffer renderCommandEncoderWithDescriptor:pass];
                // Foveation contract: rasterize in the view's LOGICAL viewport
                // (from the texture map); the rate map compresses to physical.
                [enc setViewport:soh3dVp];
                float dimNow = soh3d_dimLevel;
                if (dimNow > 0.003f && soh3d_dimPipeline) {
                    [enc setRenderPipelineState:soh3d_dimPipeline];
                    [enc setDepthStencilState:soh3d_dimDepthState];
                    [enc setFragmentBytes:&dimNow length:sizeof(dimNow) atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                }
                if (tex && soh3d_pipeline) {
                    cp_view_t view = cp_drawable_get_view(drawable, v);
                    simd_float4x4 deviceFromEye = cp_view_get_transform(view);
                    simd_float4x4 eyeFromOrigin = simd_inverse(simd_mul(originFromDevice, deviceFromEye));
                    simd_float4x4 proj = matrix_identity_float4x4;
                    if (__builtin_available(visionOS 2.0, *))
                        proj = cp_drawable_compute_projection(drawable,
                                                              cp_axis_direction_convention_right_up_back, v);
                    simd_float4x4 mvp = simd_mul(proj, simd_mul(eyeFromOrigin, model));

                    [enc setRenderPipelineState:soh3d_pipeline];
                    [enc setDepthStencilState:soh3d_depthState];
                    [enc setVertexBytes:&mvp length:sizeof(mvp) atIndex:0];
                    [enc setFragmentBytes:&srgbDecode length:sizeof(srgbDecode) atIndex:0];
                    [enc setFragmentTexture:tex atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
                }
                [enc endEncoding];
            }

            cp_drawable_encode_present(drawable, command_buffer);
            [command_buffer commit];
            sohvr_publish_pose(originFromDevice, 0); // D11 harness: live pose
            sohvr_note_present();                    // D11 harness: present cadence

            soh3d_frameCount++;
            if (soh3d_frameCount == 3 || (soh3d_frameCount % 600) == 0)
                NSLog(@"[Soh3D] frame %d — source %lux%lu eyeL=%d eyeR=%d framesL=%d framesR=%d srgbDecode=%.0f",
                      soh3d_frameCount, (unsigned long)monoTex.width, (unsigned long)monoTex.height,
                      (int)(soh3d_eyeCopy[0] != nil), (int)(soh3d_eyeCopy[1] != nil), Soh3D_GetEyeFrames(1),
                      Soh3D_GetEyeFrames(2), srgbDecode);

            cp_frame_end_submission(frame);
        }
    }

    soh3d_eyeCopy[0] = soh3d_eyeCopy[1] = nil;
    soh3d_testPattern = nil;
    if (notifyEnded)
        Soh3D_Immersive_Ended();
    gSoh3DRunning = 0; // signal the shell LAST, after cleanup
}

#pragma mark - VR core + diagnostics harness (VR-spec D2/D11)

// This section is INERT until VR mode is entered (SohVR_SetMode(2)); the flat
// and 3D-panel paths never call into it, so their behaviour is unchanged.
//
// It owns three things R1 builds directly on:
//   1. the A*V*P composition (D2) — game world -> player space -> eye -> clip,
//      emitted in Fast3D's ROW-vector convention;
//   2. the drawable contract capture (view count, per-eye extents, the
//      asymmetric frustum tangents recovered from cp_drawable_compute_projection);
//   3. the console-bridge dump family (D11), including synthetic pose
//      injection so the stereo asserts run headless in the simulator.
//
// Convention notes, written down because getting them wrong is trap B3:
//   * simd_float4x4 here is COLUMN-vector (p' = M * p), matching ARKit and
//     CompositorServices.
//   * Fast3D multiplies ROW vectors (clip = v * MP), so the matrix handed to
//     the engine is the TRANSPOSE of the composed column-vector EyeVP.
//   * The compositor's own projection is REVERSE-Z with an infinite far plane;
//     the engine is forward-Z (clear 1.0, less/less-equal). We therefore take
//     only the asymmetric FRUSTUM from cp_drawable_compute_projection (exact,
//     no hand-rolled FOV) and rebuild the depth mapping forward. Depth handoff
//     to the drawable's depth texture is R1 work and needs the conversion.

static volatile int sSohVRMode = 0; // 0 flat, 1 panel3D, 2 vr
static const char* sSohVRModeReason = "boot";

// --- view modes (spec D3, R2) ---------------------------------------------
// Diorama (the R1 bring-up vehicle, track as a tabletop model over
// passthrough), First-person (the SHIPPING DEFAULT — you sit in the kart), and
// Third-person (R3 territory, present here only so the cycle is complete).
// Every placement tunable, the surroundings choice, the sky treatment and the
// comfort flags are PER MODE and remembered across switches.
enum { SOHVR_VIEW_DIORAMA = 0, SOHVR_VIEW_FP = 1, SOHVR_VIEW_THIRD = 2, SOHVR_VIEW_COUNT = 3 };
static const char* const kSohVRViewName[SOHVR_VIEW_COUNT] = { "diorama", "fp", "third" };

typedef struct {
    float scale;    // game units per metre (trap D4 — MK64's own number)
    float dist;     // metres: the seat/camera point in front of you
    float height;   // metres relative to the entry eye height
    float hudDist;  // HUD plane, metres ahead in player space
    float hudHeight;
    float hudScale;
    float dim;         // surroundings: 0 = passthrough, 1 = fully dimmed
    int fullImmersion; // 1 = .full immersion style instead of .mixed
    int sky;           // 0 = park the sky in the HUD fb and wipe it (R1),
                       // 1 = render it in-eye at infinity, re-keyed (R2)
    int fixedHorizon;  // trap A6: the world stays level through spins
    int alphaCov;      // 1 = trust the (0034 rev2) destination alpha as the
                       // coverage mask; 0 = R1's depth/luminance keys
} SohVRViewCfg;

// Starting constants: Diorama exactly as R1 shipped it (unregressed by
// construction); First-person from R0's camDist derivation — ~45 units/m is
// 1:1, Dimmed surroundings per spec D3, sky ON because FP stares at it,
// fixed horizon ON because trap A6 says the head must not be force-rotated.
// THIRD-PERSON (R3): 120 units/m, derived rather than guessed. MK64's chase
// camera sits camDist ~= 120..200 game units behind the kart (measured: 120.4
// on Wario Stadium, 0045's export), and the kart wants to sit a comfortable
// ~1.0-1.5 m in front of you at this scale — so scale = camDist / 1.25 m ~=
// 120 u/m, which lands between Diorama's 500 and first person's 45 exactly as
// the spec expects. dist stays 0 because in third person YOU are the
// camera: the kart's apparent distance comes from camDist/scale, not from
// pushing the world away.
//
// R6 (the user's second headset round): first person's scale drops 45 -> 38 u/m.
// "The world isn't big enough" — fewer game units per metre makes every metre
// of the track bigger around you. Still tunable, now from inside the headset.
//
// R9b (the user, after the 1.0.0.5 device round): FIRST PERSON'S SCALE IS
// SETTLED AT 8 u/m and the World-size slider is GONE. He tuned the seat at 8
// and 8 is what the tuned numbers below mean; a knob that can move it would
// invalidate them silently. Diorama keeps a scale knob — it is that mode's
// "Zoom" row — and third person's scale stays at its derived 120.
// R10 addendum (the user, 1.0.0.6): "the VR HUD plane sits a little TOO LOW by
// default." It does — the HUD plane's height is per mode and has never had a
// row of its own, so the only way to move it has been a bridge command. These
// are the NEW defaults, each 8 cm above the 1.0.0.6 values (fp -0.30, third
// -0.25, diorama 0.25), and they are also the displayed ZERO of the new "HUD
// height" row — same convention as every other placement row: 1 display step
// = 1 cm, no units, 0 = the shipped default.
// R11 item 4 (the user, 1.0.0.7): the value he settled on in the headset was
// +10 on the R10 scale, so that value becomes the new default and the row
// shows it as 0. One display step is still 1 cm, the row's range is unchanged.
// R13 item 7 — THE HUD-HEIGHT RESCALE (the user, 1.0.0.9, verbatim): "old -18
// position becomes new +5 (max), range -5..+5".
//
// He tuned the row to -18 on the 1.0.0.9 scale (1 display step = 1 cm, range
// +/-20) and asked for that position to become the TOP of a new, shorter range
// — i.e. he wants room to go LOWER still and none at all to go higher, which
// is the shape of someone who ran out of travel downward. Keeping the 1 cm
// step, that fixes everything:
//
//   new +5  = old -18  (his tuned position, now the highest available)
//   new  0  = old -23  (the new default)
//   new -5  = old -28  (the new floor)
//
// The per-mode zeros below therefore move down by 0.23 m. The persisted CVar
// holds the ABSOLUTE height in metres, so a tuned value inside the new band is
// preserved literally and reads as the right number on the new row; one
// outside it is clamped onto the nearest end on load (SohVR_SettingsApply),
// which for a config still holding the 1.0.0.9 DEFAULT means the HUD drops to
// new +5 — the user's own tuned spot — rather than to an arbitrary place.
//
// R14 item 2 — AND THAT READING WAS THE WRONG WAY ROUND. R13 took "old -18
// becomes new +5 (max)" as "he ran out of travel downward" and pinned his
// tuned spot to the TOP of the band; on device it turned out he had run out
// going UP, and even +5 was still too low. STATUS.md carried the risk as an
// open question ("whether +5 is high enough, or the whole row wants moving up
// again") and the device answered it. His instruction this round is exact:
// shift the whole band up so that the CURRENT +5 becomes roughly the new
// MIDDLE, range unchanged at -5..+5. One display step stays 1 cm, so every
// per-mode zero moves UP by 0.05 m:
//
//   new  0  = R13 +5  (his tuned position, now the middle)
//   new +5  = 5 cm above anything 1.0.0.10 could reach
//   new -5  = R13  0  (the whole of the old upper half is still reachable)
//
// The remap needs no new code and that is deliberate: the CVar has held an
// ABSOLUTE height since R11, so his persisted -0.30 m is inside the new band
// and is preserved LITERALLY — it simply reads as 0 instead of +5 on the row.
// A value below the new floor is clamped onto it by the same load-time clause
// R13 added, which for a config still holding the 1.0.0.10 default lands on
// new -5. (R12's Diorama zoom rescale and R13's own used exactly this rule;
// trap D34's lesson is that the archived VALUE is the thing to keep stable,
// not the number printed beside the slider.)
#define SOHVR_HUD_HEIGHT0_FP (-0.30f)
#define SOHVR_HUD_HEIGHT0_THIRD (-0.25f)
#define SOHVR_HUD_HEIGHT0_DIO 0.25f
// The row's band around the per-mode zero, in metres (1 display step = 1 cm).
//
// R15 item 2 — THE BAND GROWS UPWARD, and only upward. the user on 1.0.0.11:
// "still too low, probably needs +15". R14 moved every per-mode zero up 5 cm
// and left the band symmetric at +/-5, which put his tuned spot in the middle
// with five centimetres of headroom; the device says he wants three times that.
// So 0 STAYS EXACTLY WHERE IT IS (trap D34: the archived absolute height must
// keep meaning the same place) and the ceiling alone moves to +15. The floor
// stays at -5 because nobody has ever asked for lower.
//
// R17-A item 4 — THE BAND IS RESCALED, NOT EXTENDED. the user on 1.0.0.13: "the
// HUD height max of 15 isn't high enough. probably should make it like 30, but
// let's rescale it so the max is +10, then users can choose between -5 and
// +10." One display STEP is now 3 cm (SohVisionApp.swift's `hudStep`), so the
// row reads -5..+10 and the TRAVEL is -0.15 m .. +0.30 m about the same zero:
// twice R15's headroom, at a third of the rows. Trap D34 for the third round
// running -- the CVar is an absolute height in metres and keeps meaning the
// same place, so a persisted +0.15 m is preserved LITERALLY and simply reads
// +5 instead of +15. Nothing is migrated. These two constants are the ENGINE
// side of that band and must equal 5 and 10 display steps respectively; the
// load-time clause below clamps a persisted value onto them.
//
// R18-B item 1 — THE BAND IS RENUMBERED AND THE TOP OPENS TO +0.60 m. the user on
// 1.0.0.16: "hud height still needs a higher max, can go to +20 as its
// currently scaled, but lets not use those numbers, the scale is too wide.
// rescale -5 to 0 and rescale the +20 to 10 so that there's less steps between
// jumps." +20 at 3 cm is +0.60 m; R17's -5 is -0.15 m. So the row reads
// 0..10 at 7.5 cm a step (SohVisionApp.swift's `hudStep`/`hudFloor`): display
// 0 = h0 - 0.15 m, display 2 = h0 (the shipped default), display 10 = h0 +
// 0.60 m. The FLOOR is unchanged; only the ceiling moved. Trap D34 for the
// fourth round running: the CVar is still an absolute height in metres, so an
// archived value keeps meaning the same place and merely displays a different
// number (R17's +5 = +0.15 m now reads 4). These two constants must equal 2
// and 8 display steps of 7.5 cm respectively.
#define SOHVR_HUD_HEIGHT_DOWN 0.15f
#define SOHVR_HUD_HEIGHT_UP 0.60f
//
// R19 item 3 — THE DEFAULT MOVES TO DISPLAY 5 FOR NEW INSTALLS. the user on
// 1.0.0.17: "make HUD height of +5 the default for new installs." Display 5 =
// h0 - 0.15 + 5 * 0.075 = h0 + 0.225 m. Only the TABLE default moves (the
// per-mode value used when no gSohVR.HudPlane.Height.* and no legacy
// gSohVR.HudHeight is archived, and the Reset button's target). h0 itself
// (sohvr_hud_height0, SohVisionApp.swift's hudHeight0) does NOT move: it is the
// band's anchor, and moving it would shift every archived value's displayed
// number. Trap D34 for the fifth round: an archived absolute height is still
// read literally -- the user's own setting does not move.
#define SOHVR_HUD_DEFAULT_UP 0.225f
// The per-mode HUD zero, by view index, for the pane's HUD-relative placement.
static float sohvr_hud_height0(int view) {
    switch (view) {
        case 1:
            return SOHVR_HUD_HEIGHT0_FP;
        case 2:
            return SOHVR_HUD_HEIGHT0_THIRD;
        default:
            return SOHVR_HUD_HEIGHT0_DIO;
    }
}

// R9b: the DISPLAYED-ZERO baselines behind the per-mode Height/Zoom rows, in
// METRES so they are independent of the mode's scale. Reset restores exactly
// these, and the settings sheet shows the offset from them (1 display step =
// 1 cm, the unit the 1.0.0.5 UI already used — the numbers the user read off it).
#define SOHVR_FP_HEIGHT0_M 0.45f    // his +45 reading becomes 0
#define SOHVR_FP_ZOOM0_M (-0.14f)   // his -14 reading becomes 0
#define SOHVR_THIRD_HEIGHT0_M (25.0f / 120.0f)
#define SOHVR_THIRD_ZOOM0_M (40.0f / 120.0f)
// R13 item 7: third person's shipped Zoom is +4 on its multiplicative row
// (x1.14 per step), i.e. 40 / 1.14^4 = 23.7 game units of chase distance.
// The DISPLAYED zero stays SOHVR_THIRD_ZOOM0_M, so the row reads +4 out of
// the box — which is what the user asked for, and what makes the new -10..+15
// range sit around the place he actually drives from.
#define SOHVR_THIRD_ZOOM_DEFAULT_M (SOHVR_THIRD_ZOOM0_M / 1.688960f)
#define SOHVR_DIO_HEIGHT0_M (-0.40f)
// R12 item 3 — THE DIORAMA ZOOM RESCALE (the user, 1.0.0.8, verbatim): "the +2
// zoom is already very zoomed out, that should be the -10 on a new scale
// range, so rescale everything to that so you can zoom in more."
//
// The R11 slider was scale(d) = 500 * 1.25^-d, so his +2 was 500/1.25^2 =
// 320 u/m. That number is the ANCHOR: on the new slider it is the value at
// -10, the far zoomed-OUT end. Everything else on the range zooms in from
// there, which is the whole ask — R11's range spent half of itself on
// zoom-OUT that he never wanted and could not use.
//
// Solving 320 = S0 * r^10 fixes the default once the step ratio is chosen.
// r = 1.15 (a hair coarser than third person's 1.14, so the row keeps the
// same ten-steps-each-way FEEL the other placement rows have) gives
// S0 = 320 / 1.15^10 = 79.1 u/m and a near end of 79.1 / 1.15^10 = 19.6 u/m.
//
//   new -10 -> 320.0 u/m  == the old +2, the user's "already very zoomed out"
//   new   0 -> 79.1 u/m   == 4x zoomed in from there (and 6.3x from the old
//                            default of 500), which is what "well zoomed-in
//                            from old +2" means
//   new +10 -> 19.6 u/m   == 2.8x closer than R11's most-zoomed-in (54 u/m)
//                            and only 2.4x short of first person's life-size
//                            8 u/m -- the track fills the room
//
// The persisted CVar holds the ABSOLUTE scale in u/m, not the display index,
// so a user's tuned zoom is preserved literally as long as it lands inside
// the new band; a value outside it (500, the R11 default, is the common one)
// is clamped onto the nearest end, which for 500 is exactly the new -10.
// SOHVR_DIO_SCALE_MIN/MAX are the band, and SohVR_SettingsApply enforces it
// on load so the slider and the world can never disagree.
#define SOHVR_DIO_SCALE0 79.1f
#define SOHVR_DIO_SCALE_STEP 1.15f
#define SOHVR_DIO_SCALE_MIN 19.55f  // 79.1 / 1.15^10, the +10 end (most zoomed IN)
#define SOHVR_DIO_SCALE_MAX 320.0f  // 79.1 * 1.15^10, the -10 end (most zoomed OUT)
static SohVRViewCfg sSohVRCfg[SOHVR_VIEW_COUNT] = {
    /* diorama */ { SOHVR_DIO_SCALE0, 1.50f, -0.40f, 1.50f, SOHVR_HUD_HEIGHT0_DIO + SOHVR_HUD_DEFAULT_UP, 0.70f, 0.0f, 0, 0, 0,
                    0 },
    /* fp      */ { 8.0f, 0.00f, 0.00f, 1.40f, SOHVR_HUD_HEIGHT0_FP + SOHVR_HUD_DEFAULT_UP, 0.90f, 1.0f, 0, 1, 1, 1 },
    /* third   */ { 120.0f, 0.00f, 0.00f, 1.45f, SOHVR_HUD_HEIGHT0_THIRD + SOHVR_HUD_DEFAULT_UP, 0.85f, 1.0f, 0, 1, 1, 1 },
};
// spec D3: First-person is the DEFAULT view mode.
static int sSohVRView = SOHVR_VIEW_FP;

// First-person seat, in GAME units, relative to the PLAYER KART's own origin
// (overlay 0045 rev2 exports it; see sohvr_world_matrix for why the old
// camera-derived seat was wrong). Live-tunable because the final numbers are a
// device judgement.
//
// R6: 24 units up is ~0.63 m at 38 u/m — a kart driver's eye line — and +10
// units forward puts the eye just ahead of the kart's centre so the driver
// billboard (which is drawn AT the kart origin and always rendered, per the
// standing ruling) sits at/below the eye and behind it, out of the forward
// view. RaYRoD ships the same "slightly up and forward" seat in his MK64 VR.
// R7 (the user, 1.0.0.3: "i am still raised up high weirdly"). R6 shipped 24 u
// up / 10 u forward. An MK64 kart's collision radius is 5.5-6.0 game units
// (gKartBoundingBoxSizeTable) — roughly 11-12 units across — so 24 units above
// the kart origin is TWO KART WIDTHS up: a camera hovering over the driver,
// not the driver. Halved to a driver's-head height, with just enough forward
// offset to keep the always-drawn driver billboard behind the eye rather than
// through it. Both are live sliders, labelled in centimetres now, and the
// headset renders the verdict.
//
// R9b — THE USER'S TUNED SEAT IS NOW THE DEFAULT. On 1.0.0.5 he settled on the
// values the sheet displayed as +45 (height) and -14 (forward) at 8 u/m, which
// in game units at that scale are 0.45*8 = 3.6 up and -0.14*8 = -1.12 forward.
// The settings rows now display those as 0 and offer +/-5 around them.
static float sSohVRSeatUp = SOHVR_FP_HEIGHT0_M * 8.0f;
static float sSohVRSeatFwd = SOHVR_FP_ZOOM0_M * 8.0f;

// R18-B item 2 — THE FIRST-PERSON SEAT IS HARDCODED; ITS TWO ROWS ARE GONE.
// the user on 1.0.0.16: "lets hardcode height to -5, zoom to +5 and then remove
// them. they dont change much anyway". Those are the first-person rows' floor
// and ceiling on the +/-5 cm fine trim (SohVisionApp.swift `placementRange`,
// 1 display step = 1 cm about SOHVR_FP_HEIGHT0_M / SOHVR_FP_ZOOM0_M):
//   Height -5 -> 0.45 - 0.05 = 0.40 m -> 3.20 game units up at 8 u/m
//   Zoom   +5 -> -0.14 + 0.05 = -0.09 m -> -0.72 game units forward at 8 u/m
// (the Zoom row's +d is applyZoom's `fpZoom0 + d/100`, i.e. FORWARD of the
// tuned seat; -0.72 u is still behind the kart origin, just 0.4 u less so).
// Trap D34: the archived gSohVR.SeatUp/SeatFwd are OVERRIDDEN, not migrated —
// sohvr_pin_fp_seat runs at settings load, on every entry into first person,
// on Reset and on "Recalculate height". `vr set seat_up/seat_fwd` survives as a
// bridge-only shove (it is how the recalc is asserted headless).
#define SOHVR_FP_SEAT_PIN_UP_M (SOHVR_FP_HEIGHT0_M - 0.05f)  // display -5
#define SOHVR_FP_SEAT_PIN_FWD_M (SOHVR_FP_ZOOM0_M + 0.05f)   // display +5
static unsigned int sSohVRSeatPins = 0;
static unsigned int sSohVRRecalcs = 0;
static void sohvr_pin_fp_seat(const char* why) {
    float sc = sSohVRCfg[SOHVR_VIEW_FP].scale;
    if (!(sc > 1e-3f)) {
        sc = 8.0f;
    }
    float up = SOHVR_FP_SEAT_PIN_UP_M * sc, fwd = SOHVR_FP_SEAT_PIN_FWD_M * sc;
    if (sSohVRSeatPins == 0 || sSohVRSeatUp != up || sSohVRSeatFwd != fwd) {
        // Log the FIRST pin and any pin that actually moved something (an
        // archived tuning being overridden, a bridge shove being undone) —
        // never the no-op re-pins on every first-person entry (trap D33).
        NSLog(@"[SohVR] fp seat pinned (%s): up %.3f -> %.3f u, fwd %.3f -> %.3f u (Height -5 / Zoom +5)", why,
              sSohVRSeatUp, up, sSohVRSeatFwd, fwd);
    }
    sSohVRSeatUp = up;
    sSohVRSeatFwd = fwd;
    sSohVRSeatPins++;
}

// Third-person camera offsets, in GAME units relative to the CHASE camera
// point 0045 exports. The chase camera is already behind and above the kart —
// third person only nudges it further back and up so you look slightly DOWN on
// the kart instead of straight along the road (25 u ~= 0.21 m and 40 u ~=
// 0.33 m at the mode's 120 u/m).
// R13 item 7 (the user, 1.0.0.9): third person's defaults are Height 0 / Zoom
// +4, and the Zoom row's range opens to -10..+15. The row is multiplicative at
// x1.14 per step, so +4 is 40 / 1.14^4 = 23.7 game units of chase distance —
// closer to the kart than the R11 default by a third. Height's displayed zero
// is unchanged, so its default reads 0 exactly as before.
static float sSohVRThirdUp = 25.0f;
static float sSohVRThirdBack = SOHVR_THIRD_ZOOM_DEFAULT_M * 120.0f; // 23.7 u

// Placement extras (R1): eye render scale and the HUD plane (spec D6).
static float sSohVRRenderScale = 1.0f; // eye framebuffer vs drawable extent
// R6 (the 120 Hz / 22.7 fps device finding): the eye framebuffer's long edge,
// in pixels, before the render-scale multiply. See the clamp in the VR loop
// for the measurement that set it.
//
// R7 — DEFAULT RAISED TO EFFECTIVELY-OFF. R6 shipped 2048 as the default,
// which against the device's 5087-wide per-eye viewport is 40% of native
// linear density in the FOVEA, and the user's verdict was "the render scale
// absolutely needs to be at least 100%, it looks AWFUL at your default of
// 50%". He is right and the arithmetic says why: the compositor's viewport is
// the LOGICAL (screen-space) extent, and the drawable's rasterization rate map
// runs at rate 1.0 in the foveal region — so one logical pixel there IS one
// physical pixel, and 100% really is 5087. The budget stays as a diagnostic
// ceiling (`vr set eye_budget`) but no longer clamps by default; RENDER
// QUALITY (sSohVRRenderScale, 25-100%) is now the single user knob and it
// ships at 1.00. The cheap way to make 100% affordable is foveated eye
// rendering — bind the drawable's own rate map on the ENGINE's eye pass so the
// periphery costs a fraction — which is 0044-family engine work and is next
// round's (VR-R7-NOTES section 4).
static double sSohVREyeBudget = 16384.0;
// R9 item 7 (diagnostic, never persisted): force the eye extent to a given
// ASPECT so the simulator can be made to render at the DEVICE's 1.246 and
// reproduce the clipped LAP element. 0 = off. See the VR loop.
static float sSohVREyeAspectDbg = 0.0f;
static int sSohVREyeClamped = 0;
static int sSohVREyeW = 0, sSohVREyeH = 0; // what the clamp actually asked for
// The live tunables are ALIASES onto the active view's config, so `vr set`
// edits the mode you are actually in and the value survives a mode cycle.
#define sSohVRScale (sSohVRCfg[sSohVRView].scale)
#define sSohVRDist (sSohVRCfg[sSohVRView].dist)
#define sSohVRHeight (sSohVRCfg[sSohVRView].height)
#define sSohVRHudDist (sSohVRCfg[sSohVRView].hudDist)
#define sSohVRHudHeight (sSohVRCfg[sSohVRView].hudHeight)
#define sSohVRHudScale (sSohVRCfg[sSohVRView].hudScale)
// R10 item 4: the safety valve for the fully-dimmed opaque composite above.
// 1 = shipping. `vr set fpopaque 0` restores 1.0.0.6's blend exactly.
static int sSohVRFpOpaque = 1;
static int sSohVRDbgMode = 0; // D11 blit diagnostics, see the shader
void SohVR_SetFpOpaque(int on) {
    sSohVRFpOpaque = on ? 1 : 0;
}
int SohVR_GetFpOpaque(void) {
    return sSohVRFpOpaque;
}
void SohVR_SetBlitDebug(int mode) {
    sSohVRDbgMode = (mode < 0 || mode > 5) ? 0 : mode;
}

// --- the R5 bisect ladder (`vr set vrdbg N`) ---------------------------------
// Device bug 2 of the first headset round: constant rainbow flicker — two huge
// flat gradient triangles over the sky, the start-banner area smeared into
// repeated stair-step slabs, a checkered wall half-stepped. NONE of it
// reproduces in the simulator, so the isolation has to happen in the headset,
// in one pass, without a rebuild between hypotheses. Each level turns ONE
// suspect off; level 99 turns them all off at once (bar 4, which stops head
// tracking and would confound the others). Ladder discipline: try 99 first —
// if 99 is clean the cause is in the set, then walk 1,2,3,5,6 to name it.
//
//   0  everything normal (shipping behaviour)
//   1  SKY OFF          — park-and-wipe like Diorama (H-A: the sky far-pin
//                         pass, whose ortho clip-Z rewrite has only ever been
//                         exercised against the simulator's SYMMETRIC frustum
//                         tangents; the device's are asymmetric)
//   2  ANGLE CULL BACK  — restores MK64's view-direction culling (0048/0051
//                         stand it down in VR). RaYRoD's patches 3-4 recorded
//                         exactly this symptom — "geometry drawn twice, flat
//                         patches & smears" — when more of the course is drawn
//                         than the game was authored to draw (traps A3/A4)
//   3  MONO EYES        — both eyes render eye 0's matrix. If the artefacts
//                         vanish, the fault is in per-eye asymmetry (the
//                         tangent recovery / eye transform), not in the scene
//   4  FROZEN POSE      — compose against the entry baseline instead of the
//                         live head. World stops head-tracking (expected); if
//                         the flicker stops with it, the fault is pose churn
//   5  DEPTH CLAMP      — engine far plane 1000 m instead of 10000 m. The
//                         compositor reports an INFINITE far on device and a
//                         forward-Z float depth buffer over 0.05-10000 m is
//                         the classic z-fight/banding recipe (H-D)
//   6  NO INTERPOLATION — pins gInterpolationFPS to 30, so the engine walks
//                         the display list ONCE per game frame instead of
//                         twice. The eye framebuffers ping-pong across only
//                         TWO slots; two sub-frames in flight can overwrite
//                         the slot the compositor is still sampling, which
//                         would read as exactly this flicker (H-B's real
//                         residue — see VR-R5-NOTES §3)
static int sSohVRDbgVr = 0;
static int sohvr_dbg_on(int level) {
    return (sSohVRDbgVr == level) || (sSohVRDbgVr == 99 && level != 4);
}
int SohVR_GetVrDbg(void) {
    return sSohVRDbgVr;
}
void SohVR_SetVrDbg(int level) {
    if (level < 0 || (level > 6 && level != 99)) {
        level = 0;
    }
    int was = sSohVRDbgVr;
    sSohVRDbgVr = level;
    if (was == 6 || was == 99 || level == 6 || level == 99) {
        // Interpolation rides an ARCHIVED CVar, so it goes through the
        // crash-safe stash (trap C4 / spec D10) — a crash while probing
        // must not bake 30 fps interpolation into the flat game.
        extern void SohVR_CVarOverrideInt(const char* name, int value);
        if (level == 6 || level == 99) {
            SohVR_CVarOverrideInt("gInterpolationFPS", 30);
        } else {
            extern void SohVR_StashRestoreOnExit(void);
            SohVR_StashRestoreOnExit();
        }
    }
    // R6 (scope D): every ladder change goes into the LOG SINK, not just the
    // console — a device bisect screenshot is worthless if the level that
    // produced it has to be remembered. `logtail` and crash.txt both see this.
    NSLog(@"[SohVR] VRDBG level %d -> %d (view=%s scale=%.1f seat=%.1f/%.1f eye=%dx%d)", was, level,
          kSohVRViewName[sSohVRView], sSohVRScale, sSohVRSeatUp, sSohVRSeatFwd, sSohVREyeW, sSohVREyeH);
    extern void SohIos_LogLine(const char* s);
    char line[256];
    snprintf(line, sizeof(line), "[SohVR] VRDBG level %d -> %d", was, level);
    SohIos_LogLine(line);
}

// --- R10 item 2: THE DEVICE BISECT KIT ---------------------------------------
//
// the user's 1.0.0.6 verdict: the rainbow/flicker artefacts are NOT gone and NOT
// improved. R9's publish race was real and was measured (46,040 slot reuses in
// one session, down to 59) — and it was evidently not the device's failure
// mode, or not all of it. That is now SIX rounds of hypotheses, every one of
// which died to the same asymmetry: **the artefacts have never once appeared
// in the simulator.** They are device-only, constant at high render quality,
// reduced but never zero at low quality, and unaffected by the R9 fix.
//
// So this round does not ship a seventh hypothesis. It ships the INSTRUMENT.
//
// The R5/R6 ladder (`vrdbg`, above) was the right idea and the wrong shape: it
// is a PICKER, so exactly one suspect can be off at a time, the levels are
// numbered rather than named, and level 99's "all except 4" is a compound that
// cannot be attributed. the user never walked it, and reading it back, it is not
// something a person wearing a headset mid-race would want to walk.
//
// The kit is a set of INDEPENDENT toggles instead. Every row is ON in a normal
// frame; each one turns off exactly ONE mechanism, live, safely, mid-race; and
// each is labelled in plain words. The retest script is "flip one row at a
// time, top to bottom, and report which row kills the rainbows" — and the rows
// are ORDERED BY PRIOR PROBABILITY, so his first flip is the likeliest winner.
//
// The ordering, and why (full reasoning in docs/VR-R10-NOTES.md §2):
//
//  1 DEPTH HANDOFF   The compositor REPROJECTS on the depth we hand it, and
//                    only on device: `comp_far_inf=1` there, so the shader's
//                    `compNear/z` branch has literally never executed anywhere
//                    else, and the simulator does no reprojection at all.
//                    Reprojection error scales with how stale the frame is,
//                    which scales with render quality — "constant at high,
//                    reduced at low" is its signature. And what wrong
//                    reprojection LOOKS like is the user's screenshot: geometry
//                    sheared toward a vanishing point, flat gradient triangles,
//                    stair-step slabs. Nothing else on this list explains all
//                    four observations at once.
//  2 FOVEATED RASTER The drawable's rasterization rate map is attached to the
//                    compositor passes. `rmCount > 0` is DEVICE-ONLY (trap
//                    D15: the simulator exposes none), so this code path has
//                    never executed in any green run we have ever taken. Under
//                    a rate map, logical and physical pixels differ
//                    non-linearly in bands — which is what "the checkered wall
//                    half-stepped" describes.
//  3 TEXTURE MIPMAPS A texture uploaded this frame has UNINITIALISED mip
//                    levels until the deferred blit (overlay 0021); sampling
//                    those minified is arbitrary memory read as colour, i.e. a
//                    rainbow. 0021 rev11 mitigates it; whether the mitigation
//                    is complete on a driver that does not zero-fill fresh
//                    allocations is exactly what this row asks. (Overlay 0058.)
//  4 SKY PASS        "Two huge flat gradient triangles over the sky" is
//                    literally the sky. The far-pin pass rewrites ortho clip Z
//                    and has only ever been exercised against the simulator's
//                    SYMMETRIC frustum; the device's is strongly asymmetric.
//  5 FAR DRAW PLANE  Forward-Z float depth across 0.05-10000 m is the classic
//                    banding/z-fight recipe, and it is the input to row 1.
//  6 EXTRA DRAW DIST MK64's view-direction cull is stood down in VR (0048), so
//                    more of the course is drawn than the game was authored to
//                    draw — RaYRoD's patches 3-4 recorded this exact symptom.
//  7 HUD & PANES     The HUD plane, the rear-view pane and the item chip ride
//                    the SAME encoder as the world blit, at different target
//                    sizes (trap B4: scissor/viewport cache poisoning).
//  8 STEREO          Both eyes render eye 0's matrix. If the artefacts stop,
//                    the fault is per-eye asymmetry, not the scene.
//  9 INTERPOLATION   Pins gInterpolationFPS to 30: one display-list walk per
//                    game frame instead of two.
// 10 HANDOFF GATE    R9's fix itself, so its contribution is falsifiable.
//
// State is per session and NOT persisted (trap D11's cousin: an archived
// diagnostic poisons the next A/B). Every flip is logged into the black box,
// so a crash report says which rows were off.
enum {
    SOHVR_DIAG_DEPTH = 0,
    SOHVR_DIAG_FOVMAP,
    SOHVR_DIAG_MIPS,
    SOHVR_DIAG_SKY,
    SOHVR_DIAG_FARPLANE,
    SOHVR_DIAG_DRAWDIST,
    SOHVR_DIAG_PANES,
    SOHVR_DIAG_STEREO,
    SOHVR_DIAG_INTERP,
    SOHVR_DIAG_SLOTGATE,
    SOHVR_DIAG_COUNT
};
static unsigned int sSohVRDiagOff = 0; // bit SET = that mechanism is DISABLED
static const char* const kSohVRDiagKey[SOHVR_DIAG_COUNT] = {
    "depth", "fovmap", "mips", "sky", "farplane", "drawdist", "panes", "stereo", "interp", "slotgate"
};
static const char* const kSohVRDiagLabel[SOHVR_DIAG_COUNT] = {
    "Depth handoff", "Foveated raster", "Texture mipmaps", "Sky pass",
    "Far draw plane", "Extra draw distance", "HUD & panes", "Stereo (two eyes)",
    "Frame interpolation", "Handoff gate"
};
static const char* const kSohVRDiagHelp[SOHVR_DIAG_COUNT] = {
    "Off: the headset stops re-projecting the picture on the game's depth.",
    "Off: the headset's variable-resolution raster map is not used.",
    "Off: textures sample their full-size pixels only.",
    "Off: the sky is wiped instead of pinned at the horizon.",
    "Off: the game stops drawing anything past 1000 m.",
    "Off: the course draws only what the original game drew.",
    "Off: the lap counter, the rear-view pane and the item in hand are hidden.",
    "Off: both eyes are given the left eye's view.",
    "Off: the game draws 30 frames a second instead of 60.",
    "Off: the frame handoff added in the previous build is bypassed."
};
static int sohvr_diag_off(int bit) {
    return (int)((sSohVRDiagOff >> (unsigned)bit) & 1u);
}
// R14 item 6 — the Diagnostics group's visibility. See SohImmersive.h.
static int sSohVRDiagUI = 0;
// R14 item 5 — the hitch line, for the settings sheet. the user cannot type in
// the headset (memory: headset-debug-ergonomics), so the correlation has to be
// readable AS A SENTENCE while the jiggle is fresh: how many, how long ago, and
// which suspect had moved at that moment.
const char* SohVR_HitchLine(void) {
    static char line[420];
    extern volatile unsigned int gSohVREyeStale[2];
    extern volatile unsigned int gSohVRPairSplits, gSohVRPairForced, gSohVRPresentSplits;
    double ago = (sSohVRHitchAt > 0.0) ? (CACurrentMediaTime() - sSohVRHitchAt) : -1.0;
    int n = 0;
    if (sSohVRHitches == 0) {
        n = snprintf(line, sizeof(line), "Steadiness: no hitches yet (frame %.1f ms).",
                     sSohVRFrameMsAvg);
    } else {
        n = snprintf(line, sizeof(line),
                     "Steadiness: %u hitch(es), last %.0f s ago and %.0f ms long. At that moment — "
                     "dumps %u, world flaps %u, seat flips %u, slow frames %u, recentres %u.",
                     sSohVRHitches, ago, sSohVRHitchMs, sSohVRHitchDumps, sSohVRHitchWorldFlaps,
                     sSohVRHitchSeatFlips, sSohVRHitchDtFalls, sSohVRHitchRebases);
    }
    // R15 item 1: the one-eye stale counter. "Repeats" is a frame that had to
    // be shown a second time; "left/right" is which eye's fresh image was NOT
    // used. Both eyes must always move together, so a LOPSIDED pair here is the
    // fault the user was seeing and an equal pair is the fix doing its job.
    if (n > 0 && n < (int)sizeof(line)) {
        int m = snprintf(line + n, sizeof(line) - (size_t)n,
                         " Repeated frames %u (left %u, right %u, unpaired %u).", gSohVRPairSplits,
                         gSohVREyeStale[0], gSohVREyeStale[1], gSohVRPairForced);
        // R16-A: and the kart-pose hole, so the next retest reports a NUMBER
        // for "the world violently turns in a flash of an eye" instead of a
        // feeling. Both must read 0 while racing in first person.
        if (m > 0 && n + m < (int)sizeof(line)) {
            n += m;
            snprintf(line + n, sizeof(line) - (size_t)n, " Seat drops %u, worst turn step %.0f deg.",
                     gSohVRSeatFallbacks, gSohVRWorldYawStepMax);
        }
    }
    return line;
}
int SohVR_GetDiagUI(void) {
    return sSohVRDiagUI;
}
void SohVR_SetDiagUI(int on) {
    sSohVRDiagUI = on ? 1 : 0;
}
int SohVR_DiagCount(void) {
    return SOHVR_DIAG_COUNT;
}
const char* SohVR_DiagLabel(int bit) {
    return (bit >= 0 && bit < SOHVR_DIAG_COUNT) ? kSohVRDiagLabel[bit] : "?";
}
const char* SohVR_DiagHelp(int bit) {
    return (bit >= 0 && bit < SOHVR_DIAG_COUNT) ? kSohVRDiagHelp[bit] : "";
}
// 1 = the mechanism is ON (the shipping behaviour). The UI rows read this.
int SohVR_GetDiag(int bit) {
    return (bit >= 0 && bit < SOHVR_DIAG_COUNT) ? !sohvr_diag_off(bit) : 1;
}
void SohVR_SetDiag(int bit, int on) {
    if (bit < 0 || bit >= SOHVR_DIAG_COUNT) {
        return;
    }
    unsigned int was = sSohVRDiagOff;
    if (on) {
        sSohVRDiagOff &= ~(1u << (unsigned)bit);
    } else {
        sSohVRDiagOff |= (1u << (unsigned)bit);
    }
    if (was == sSohVRDiagOff) {
        return;
    }
    // Three of the ten are not read per frame by this file, so they are pushed
    // where they live the moment the row moves.
    if (bit == SOHVR_DIAG_MIPS) {
        extern volatile int gSohVRDiagNoMips;
        gSohVRDiagNoMips = on ? 0 : 1;
    } else if (bit == SOHVR_DIAG_SLOTGATE) {
        extern volatile int gSohVRSlotGate;
        gSohVRSlotGate = on ? 1 : 0;
    } else if (bit == SOHVR_DIAG_INTERP) {
        // Interpolation rides an ARCHIVED CVar, so it goes through the
        // crash-safe stash and the engine-thread confinement (trap C4 /
        // spec D10, and the R6 crash that taught us both).
        extern void SohVR_CVarOverrideInt(const char* name, int value);
        extern void SohVR_StashRestoreOnExit(void);
        if (on) {
            SohVR_StashRestoreOnExit();
        } else {
            SohVR_CVarOverrideInt("gInterpolationFPS", 30);
        }
    }
    NSLog(@"[SohVR] DIAG %s -> %s (mask=0x%03x)", kSohVRDiagKey[bit], on ? "on" : "OFF", sSohVRDiagOff);
    extern void SohIos_LogLine(const char* s);
    char line[128];
    snprintf(line, sizeof(line), "[SohVR] DIAG %s %s (mask=0x%03x)", kSohVRDiagKey[bit],
             on ? "on" : "OFF", sSohVRDiagOff);
    SohIos_LogLine(line);
}
void SohVR_DiagResetAll(void) {
    for (int i = 0; i < SOHVR_DIAG_COUNT; i++) {
        SohVR_SetDiag(i, 1);
    }
}
int SohVR_DiagFindKey(const char* key) {
    if (key == NULL) {
        return -1;
    }
    for (int i = 0; i < SOHVR_DIAG_COUNT; i++) {
        if (strcmp(key, kSohVRDiagKey[i]) == 0) {
            return i;
        }
    }
    return -1;
}
// Per-pass GPU error counters, so the page can say whether the COMPOSITOR's
// own command buffers are failing — the cheapest GPU-side artefact signal
// there is, and one no screenshot can show.
static unsigned int sSohVRCbErrors = 0;
static unsigned int sSohVRCbErrLast = 0;
unsigned int SohVR_GetCbErrors(void) {
    return sSohVRCbErrors;
}
const char* SohVR_DumpDiag(void) {
    static char line[512];
    int n = snprintf(line, sizeof(line), "vr_diag mask=0x%03x", sSohVRDiagOff);
    for (int i = 0; i < SOHVR_DIAG_COUNT && n > 0 && n < (int)sizeof(line); i++) {
        n += snprintf(line + n, sizeof(line) - (size_t)n, " %s=%d", kSohVRDiagKey[i],
                      SohVR_GetDiag(i));
    }
    extern volatile unsigned int gSohIosGfxAllocFails;
    if (n > 0 && n < (int)sizeof(line)) {
        snprintf(line + n, sizeof(line) - (size_t)n, " cb_errors=%u cb_err_last=%u alloc_fails=%u",
                 sSohVRCbErrors, sSohVRCbErrLast, gSohIosGfxAllocFails);
    }
    return line;
}

// R6: how many composed eye matrices came back non-finite. A NaN/Inf in the
// injected VP is the cheapest possible explanation for "triangles explode
// toward a vanishing point", and it costs 32 isfinite() calls a frame to rule
// in or out — which is worth doing before anyone instruments the vertex path.
static unsigned int sSohVRBadMtx = 0;
static unsigned int sSohVRBadMtxLastSeq = 0;

// --- the rear-view pane (spec D12, R3) ------------------------------------
// A small mono panel, off to the side, showing what is directly behind the
// kart. It is R1's plane compositor pointed at a different texture — the
// machinery was deliberately built as "a texture on a plane in player space",
// not "the HUD", precisely so this round could re-aim it (and so the next idea
// the user has can re-aim it again).
//
// THE IMAGE IS A TRUE REAR VIEW, MIRRORED AT COMPOSITE TIME. The engine-side
// walk (0044 rev3) rotates the WORLD 180 degrees about the vertical axis
// through the kart and reuses the game's own projection — a proper rotation,
// so winding and therefore backface culling are untouched. Building a
// left-handed "mirrored" basis in the engine instead would invert the winding
// and cull every visible face, which is the trap this avoids. The MIRROR
// CONVENTION (a kart on your right appears on the right of the pane, the way a
// real rear-view mirror reads, not the way a reversing camera does) is then a
// single U flip in the plane shader — free, and reversible from the bridge for
// the headset comparison.
static int sSohVRMirrorMirrored = 1;   // 1 = flip U (mirror convention)
// R10 item 3b — THE PANE MOVED, AND IT MOVED FOR A MEASURABLE REASON.
// artifacts/vr-r10/user-rearview-clipped-by-hud.png: the pane appears top
// left and is SLICED by the rank column and the wall behind it. That is not a
// z-fight, it is arithmetic. In first person the HUD plane sits at dist 1.40
// with scale 0.90, so its half-width is 0.5*1.40*0.90 = 0.63 m and (at the
// device's 1.246 eye aspect) its half-height is 0.50 m. The pane at the old
// -0.52 / +0.34 with scale 0.40 at dist 1.55 spans x -0.83..-0.21 and y
// 0.09..0.59 — straight through the HUD's top-left quadrant, and BEHIND it
// (1.55 m vs 1.40 m), so the reverse-Z Greater test correctly hides the
// overlap. Two changes, and both are needed: the default is now directly
// ABOVE the HUD (a real rear-view mirror's place, and clear of it by
// construction), and the pane draws on TOP of everything regardless — see the
// draw site.
// R11 item 4 (the user, 1.0.0.7, FINAL): the four Auto-show sliders are GONE and
// these are the values they are frozen at — Side 0, Height +70, Distance 150,
// Size 50, in the units the removed rows displayed. The pane is furniture now,
// not a tunable.
//
// Height is the one that is not a constant. the user: "the rear-view pane must
// AUTO-RISE with HUD height so raising the HUD never collides with or crowds
// the pane — the pane offset is relative to the HUD's current height, not
// absolute." So the shipped +70 is expressed as an offset from THIS MODE'S HUD
// zero, which makes it read +70 in every mode at the default and track the HUD
// row 1:1 from there. sohvr_place_pane() is the only writer.
//
// R14 item 2 — THE GAP, and why 0.70 was never "just above the HUD".
// the user's 1.0.0.10 photo (artifacts/vr-r14/user-hud-low-pane-gap.png) shows
// roughly fifteen degrees of empty sky between the pane's bottom edge and the
// LAP/TIME row. Two compounding causes, and only the second is obvious:
//
//  (a) 0.70 is an ABSOLUTE height, not a clearance. With the HUD row at its
//      zero (-0.30 m in first person) the constant put the pane a full metre
//      above the HUD plane's centre, which nothing derived and nothing checked.
//  (b) The deconflict guard treated the HUD PLANE'S RECTANGLE as the thing to
//      clear, and that rectangle is the whole 320x240 game screen — most of
//      which is transparent. MK64 draws the lap counter, the item window and
//      the timer about a third of the way down that screen, so the plane's
//      geometric top edge sits far above anything the player can see. Clearing
//      the rectangle therefore clears empty pixels, and it would have re-lifted
//      the pane to ~0.70 even if (a) alone had been fixed.
//
// SOHVR_HUD_CONTENT_TOP is the fix for (b): the fraction of the HUD
// framebuffer's height, measured down from its top, that carries no HUD at all.
// Both the placement and the guard use the CONTENT top it implies, so "the pane
// sits just above the HUD" finally means the visible HUD.
//
// R15 item 3 — THE PADDING WENT TO ZERO, and the constant is why.
//
// the user's 1.0.0.11 photograph (artifacts/vr-r15/user-pane-overlaps-hud.png)
// has the pane's bottom edge sitting ON the lap counter: R14 closed the fifteen
// degrees of sky and then closed the gap as well. 0.30 was read off a picture,
// and it UNDERSHOOTS — MK64 puts the LAP row and the timer within a few per
// cent of the top of the 320x240 screen, not a third of the way down, so the
// "content top" it implies is far below the real one and the pane is placed
// into the HUD.
//
// So the value is MEASURED now (`vr set hudscan 1` reads the published HUD
// framebuffer's own alpha; see sohvr_hud_alpha_scan) and the placement is
// DERIVED from it rather than being a constant with a guard behind it:
//
//     pane bottom = HUD content top + SOHVR_PANE_HUD_GAP
//
// which makes "the pane sits just above the HUD with a visible gap" true by
// construction at every HUD height, instead of true only when the deconflict
// guard happens to fire. The guard stays as a floor under it.
#define SOHVR_MIRROR_X 0.00f
#define SOHVR_HUD_CONTENT_TOP 0.06f
// ~7 cm at the pane's 1.5 m distance: about two and a half degrees of clear
// sky between the HUD's top row and the pane's bottom edge.
#define SOHVR_PANE_HUD_GAP 0.07f
#define SOHVR_MIRROR_DIST 1.50f
#define SOHVR_MIRROR_SCALE 0.50f
// R11 item 4: visionOS-style rounded corners on the pane, in units of its own
// half-height (0.18 = a corner about a fifth of the way in, which is what the
// system's own glass panels read like at arm's length).
#define SOHVR_PANE_CORNER 0.18f
// R13 item 5: WHICH placement drew the pane this frame, and how often each
// has. The map's point is that every failure in this path is silent — the
// hand losing tracking for one poll, the two degenerate-basis guards, a claim
// refusal — and "it hides sometimes" cannot be diagnosed without a per-branch
// number. `vr mode` carries mirror_placement and the four counters.
enum { SOHVR_PANE_NONE = 0, SOHVR_PANE_HUD = 1, SOHVR_PANE_LEFTHAND = 2, SOHVR_PANE_WRIST = 3 };
static int sSohVRPanePlacement = SOHVR_PANE_NONE;
static unsigned int sSohVRPaneDraws[4] = { 0, 0, 0, 0 };
static unsigned int sSohVRPaneDrops = 0;   // left-hand pose present but unusable
static int sSohVRPaneDeconflicted = 0;     // 1 = the guard lifted Y this frame
static int sSohVRLeftHandLive = 0;         // left-hand mode ON and the hand tracked
static float sSohVRMirrorX = SOHVR_MIRROR_X;
static float sSohVRMirrorY = 0.30f;
// The live content-top fraction. Compiled default above; `vr set hudctop <f>`
// moves it for an A/B without a rebuild, and it is never persisted.
static float sSohVRHudCTop = SOHVR_HUD_CONTENT_TOP;
static float sSohVRMirrorDist = SOHVR_MIRROR_DIST;
static float sSohVRMirrorScale = SOHVR_MIRROR_SCALE;
// R11 item 4: "Left hand" — the pane rides the LEFT controller like a wing
// mirror you hold, instead of the fixed placement above the HUD. Persisted.
static int sSohVRMirrorLeftHand = 0;
// Resolution as a fraction of the eye extent PER AXIS: 0.5 = a quarter of the
// pixels, which is the spec's "~quarter eye res". This is the first thing
// that drops if the pane costs frame time (spec D12 / D4 ladder).
static float sSohVRMirrorRes = 0.5f;
// R14 item 3 — REAR VIEW, RESTATED AS TWO INDEPENDENT PANES.
//
// the user's instruction retires the whole "when does the pane appear" state
// machine that R10, R11 and R13 each fixed a different corner of. There is no
// auto-show any more: an item-triggered popup is a surprise in a headset, and
// the edge detector behind it (gSohVRRearItemSeq) was itself the third answer
// to trap D25. What is left is two switches the player owns —
//
//   TOP        the HUD-anchored pane. The SETTING enables it; the LEFT
//              THUMBSTICK CLICK toggles it on and off during a race, which is
//              where the user wants the control ("turned on or off with their
//              left joystick click"). One latch, one producer, no thresholds.
//   LEFT HAND  the wrist-style pane. ON means ALWAYS ON while racing, with the
//              left controller tracked; OFF means never, gesture or no gesture.
//
// and they are INDEPENDENT: both on draws both panes, from the one mirror
// texture, which is free — it is one texture and two planes, and the engine's
// third walk is already gated on "either of them wants it".
static int sSohVRMirrorTop = 1;         // the "Top" setting (persisted)
static int sSohVRMirrorTopOn = 1;       // ... and its in-race latch (session)
static int sSohVRMirrorHold = 0;        // bridge/D-pad force, diagnostics only
static int sSohVRMirrorVisible = 0;     // computed once per compositor frame
static int sSohVRMirrorShows = 0;       // show events since entry (suite)
static int sSohVRTopToggles = 0;        // left-click toggles seen (suite)
static int sSohVRMirrorFrames = 0;      // frames the pane was up
// Which panes want to be on screen THIS frame, decided once per compositor
// frame beside sSohVRMirrorVisible so the draw site cannot disagree with the
// latch that made the engine render the walk.
static int sSohVRPaneTopLive = 0;
static int sSohVRPaneHandLive = 0;

// The held trigger. Default D-PAD DOWN, and it is genuinely free: MK64 reads
// D_JPAD during a race in exactly one place (race_logic.c's lap-skip cheat)
// and only when gEnableDebugMode is set, which it is not in a shipped build.
// The state is latched by the shell's SDL event filter rather than polled from
// GCController, which means the bridge's own `btn down 400` drives it too —
// the pane is testable headless.
void SohVR_SetMirrorHold(int held) {
    sSohVRMirrorHold = held ? 1 : 0;
}
// R14 item 3 — the "Top" setting and its in-race latch.
//
// Turning the setting ON re-arms the latch, so a player who enables the row in
// the settings sheet sees the pane immediately rather than having to find the
// stick click as well. Turning it off leaves the latch alone: re-enabling the
// row later brings back the state the player last chose.
void SohVR_SetMirrorTop(int on) {
    extern void SohVR_SettingsSave(void);
    int want = on ? 1 : 0;
    if (want && !sSohVRMirrorTop) {
        sSohVRMirrorTopOn = 1;
    }
    sSohVRMirrorTop = want;
    SohVR_SettingsSave();
}
int SohVR_GetMirrorTop(void) {
    return sSohVRMirrorTop;
}
// R20 item 1 — "Jumbotron live feed". The device A/B arm for the left-eye
// rainbow flash: OFF = in a VR world frame the game emits no jumbotron slice at
// all (no eye copy, no slice draw, no readback -- overlay 0064 rev3,
// framebuffer_effects.c) and the Luigi Raceway / Wario Stadium screens hold
// their last image. Engine global lives in gfx_metal.cpp (0064 rev3), so it is
// defined on iPhone too.
// R21 item 1: the user confirmed the R20 vertex-pool fix on device (zero rainbow
// flashes on 1.0.1.19), so the settings ROW is gone and the feed is ALWAYS ON.
// What is left is a SESSION-ONLY bridge diagnostic (`vr set jumbofeed 0`): it
// is never persisted and never read back, and an archived Off value from
// 1.0.1.19 is ignored and cleared at settings load (trap D34: delete the row
// AND the archived value, or a forgotten Off would outlive the switch).
void SohVR_SetJumboFeed(int on) {
    extern volatile int gSohVRJumboFeed;
    gSohVRJumboFeed = on ? 1 : 0;
}
int SohVR_GetJumboFeed(void) {
    extern volatile int gSohVRJumboFeed;
    return gSohVRJumboFeed;
}
// The LEFT thumbstick click. One edge in, one flip out — the producer side is a
// tap detector in SohSense.m, so nothing here can double-toggle (trap D25: the
// old rear-view control armed and disarmed at the same threshold).
int SohVR_ToggleMirrorTop(void) {
    if (!sSohVRMirrorTop) {
        return 0; // the row is off; the click does nothing rather than something
    }
    sSohVRMirrorTopOn = !sSohVRMirrorTopOn;
    sSohVRTopToggles++;
    return sSohVRMirrorTopOn;
}
// R10 addendum — THE HUD AND THE PANE MAY NOT BE PUSHED INTO EACH OTHER.
//
// Two placements now move independently (the new "HUD height" row and the
// Auto-show pane's Side/Height/Distance/Size), and the pane no longer loses a
// depth test to the HUD, so an overlap would not read as clipping any more —
// it would read as the pane sitting ON the lap counter, which is worse. So
// whichever one moved, the pane is the one that yields: if the two planes
// overlap laterally, the pane is lifted to clear the HUD's top edge by 4 cm.
//
// Half-extents are computed the way the draw site computes them: half-width =
// 0.5 * dist * scale, half-height = half-width / aspect, aspect from the live
// eye extent (the textures follow it). A guard, not a layout engine — it only
// ever moves the pane UP, and only when the rectangles actually intersect.
static float sohvr_plane_aspect(void) {
    if (sSohVREyeW > 0 && sSohVREyeH > 0) {
        return (float)sSohVREyeW / (float)sSohVREyeH;
    }
    return 16.0f / 9.0f;
}
// R14 item 2: the two numbers the pane/HUD stack is decided by, exported so the
// suite can assert the stack is TIGHT rather than photograph it and hope.
static float sohvr_hud_content_top(void) {
    float ar = sohvr_plane_aspect();
    float hudHW = 0.5f * sSohVRHudDist * sSohVRHudScale;
    float hudHH = (ar > 1e-3f) ? hudHW / ar : hudHW;
    return sSohVRHudHeight + hudHH * (1.0f - 2.0f * sSohVRHudCTop);
}
// R16-C step 3: the PANE's own aspect, which is no longer the eye's. The quad
// is drawn from the texture's aspect (sohvr_draw_plane_ex), so the stack maths
// has to read the same number or the deconflict under-estimates the pane's
// height and lets it sit on the HUD.
static float sohvr_pane_aspect(void) {
    extern volatile int gSohVRMirrorW, gSohVRMirrorH;
    if (gSohVRMirrorW > 0 && gSohVRMirrorH > 0) {
        return (float)gSohVRMirrorW / (float)gSohVRMirrorH;
    }
    return sohvr_plane_aspect();
}
static float sohvr_pane_bottom(void) {
    float ar = sohvr_pane_aspect();
    float paneHW = 0.5f * sSohVRMirrorDist * sSohVRMirrorScale;
    float paneHH = (ar > 1e-3f) ? paneHW / ar : paneHW;
    return sSohVRMirrorY - paneHH;
}
static void sohvr_deconflict_panes(void) {
    float ar = sohvr_plane_aspect();
    float par = sohvr_pane_aspect();
    float hudHW = 0.5f * sSohVRHudDist * sSohVRHudScale;
    float hudHH = (ar > 1e-3f) ? hudHW / ar : hudHW;
    float paneHW = 0.5f * sSohVRMirrorDist * sSohVRMirrorScale;
    float paneHH = (par > 1e-3f) ? paneHW / par : paneHW;
    if (fabsf(sSohVRMirrorX) >= (hudHW + paneHW)) {
        return; // clear of each other sideways; nothing to do
    }
    // R14 item 2: the HUD's CONTENT top, not the plane's geometric top. See the
    // note beside SOHVR_HUD_CONTENT_TOP — clearing the empty upper third of the
    // HUD framebuffer is what produced the user's fifteen degrees of sky.
    float hudTop = sSohVRHudHeight + hudHH * (1.0f - 2.0f * sSohVRHudCTop);
    float paneBottom = sSohVRMirrorY - paneHH;
    if (paneBottom >= hudTop) {
        return;
    }
    float wanted = hudTop + paneHH + SOHVR_PANE_HUD_GAP;
    if (wanted > 3.0f) {
        wanted = 3.0f;
    }
    sSohVRPaneDeconflicted = (wanted > sSohVRMirrorY) ? 1 : 0;
    if (wanted > sSohVRMirrorY) {
        NSLog(@"[SohVR] pane/HUD deconflict: pane y %.2f -> %.2f (hud top %.2f)", sSohVRMirrorY, wanted,
              hudTop);
        sSohVRMirrorY = wanted;
    }
}

// R11 item 4: THE ONLY WRITER of the pane's placement. Hardcoded except for
// the height, which follows the HUD row, and then the R10 deconflict guard
// gets the last word — the user's "it disappears a lot or gets hidden" has now
// had three independent causes (a threshold that was not an edge detector, a
// depth test it lost, and a placement that could be aimed into the HUD), and
// removing the aiming rows removes the third for good.
//
// Called from the compositor loop every frame the pane is considered, so it
// cannot go stale behind a mode switch, a Reset, or a HUD-height drag.
void SohVR_PlacePane(void) {
    sSohVRMirrorX = SOHVR_MIRROR_X;
    sSohVRMirrorDist = SOHVR_MIRROR_DIST;
    sSohVRMirrorScale = SOHVR_MIRROR_SCALE;
    // R15 item 3: DERIVED, not a constant plus a guard. The pane's bottom edge
    // is one gap above the HUD's measured content top, so raising the HUD row
    // raises the pane by exactly the same amount and the padding is the same
    // number at every setting.
    float ar = sohvr_pane_aspect(); // R16-C step 3: the PANE's aspect, not the eye's
    float paneHW = 0.5f * sSohVRMirrorDist * sSohVRMirrorScale;
    float paneHH = (ar > 1e-3f) ? paneHW / ar : paneHW;
    sSohVRMirrorY = sohvr_hud_content_top() + paneHH + SOHVR_PANE_HUD_GAP;
    if (sSohVRMirrorY > 3.0f) {
        sSohVRMirrorY = 3.0f;
    }
    sohvr_deconflict_panes();
}
// R15 item 3's A/B, session only.
void SohVR_SetHudCTop(float f) {
    if (f >= 0.0f && f <= 0.5f) {
        sSohVRHudCTop = f;
        SohVR_PlacePane();
    }
}
float SohVR_GetHudCTop(void) {
    return sSohVRHudCTop;
}
void SohVR_GetMirrorPlane(float* x, float* y, float* dist, float* scale) {
    if (x) {
        *x = sSohVRMirrorX;
    }
    if (y) {
        *y = sSohVRMirrorY;
    }
    if (dist) {
        *dist = sSohVRMirrorDist;
    }
    if (scale) {
        *scale = sSohVRMirrorScale;
    }
}
// R11 item 4: the "Left hand" row.
void SohVR_SetMirrorLeftHand(int on) {
    extern void SohVR_SettingsSave(void);
    sSohVRMirrorLeftHand = on ? 1 : 0;
    SohVR_SettingsSave();
}
int SohVR_GetMirrorLeftHand(void) {
    return sSohVRMirrorLeftHand;
}
void SohVR_SetMirrorRes(float res) {
    if (res >= 0.15f && res <= 1.0f) {
        sSohVRMirrorRes = res;
    }
}
void SohVR_SetMirrorMirrored(int on) {
    sSohVRMirrorMirrored = on ? 1 : 0;
}
int SohVR_MirrorVisible(void) {
    return sSohVRMirrorVisible;
}

// Pose state. sSohVRAnchor is origin_from_head captured at entry with pitch
// and roll levelled out (world placement must not inherit head tilt); the
// live pose drives V. R0 freezes them to the same capture.
static simd_float4x4 sSohVRAnchor = {
    .columns = { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } }
};
static simd_float4x4 sSohVRHeadPose = {
    .columns = { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } }
};
static int sSohVRHaveAnchor = 0;
static int sSohVRPoseInjected = 0;

// --- the alignment baseline (R5, guide §12.5) --------------------------------
// FIRST DEVICE ROUND BUG 1. In the simulator the head pose is the IDENTITY, so
// "the entry anchor" and "the ARKit origin" are the same matrix and a missing
// re-base step is invisible. On DEVICE the origin is the floor of wherever the
// space opened: the head sits 1.6-1.8 m above it and an arbitrary distance to
// the side, and if that pose is ever composed into V without the matching
// placement in A, the whole offset shows up as altitude (~70-80 game units at
// first person's 45 u/m — chase-cam height) and lateral drift, WORSE on a
// mid-session entry because by then the player has walked around the room.
//
// The rule, therefore: the world is never placed against a pose we have not
// validated. `sSohVRRebaseReq` asks for a capture; the capture only takes a
// pose the tracker actually returned AND whose height is plausible; and a VR
// world frame is refused until a baseline exists (`sSohVRBaseValid`). Entry
// clears the baseline (so entry-at-start and entry-mid-race take the identical
// path); recenter only ARMS a new capture and keeps the old baseline live
// until it lands, so a recenter never drops a frame to the panel fallback.
#define SOHVR_BASE_H_MIN 0.6f // guide §12.5 sanity gate: a seated child ...
#define SOHVR_BASE_H_MAX 2.6f // ... to a tall adult standing, in metres
#define SOHVR_BASE_FORCE_TRIES 240 // ~2.5 s of refusals: take it anyway, loudly
static simd_float3 sSohVRBasePos = { 0, 0, 0 };
static float sSohVRBaseYawDeg = 0.0f;
static int sSohVRBaseValid = 0;   // a baseline has been captured this session
static int sSohVRRebaseReq = 1;   // capture on the next pose that qualifies
static int sSohVRBaseForced = 0;  // the height gate was overridden to avoid a wedge
static int sSohVRBaseRejects = 0; // poses refused by the gate since the request
static int sSohVRRecenters = 0;   // baselines captured by an explicit recenter


// Drawable contract, captured by whichever loop is presenting.
static int sSohVRViewCount = 0;         // as reported by the runtime
static int sSohVRContractValid = 0;
// device_from_eye per eye. Seeded with the SYNTHETIC pair (identity + 63 mm
// along eye X) so the eye math is answerable before any drawable exists —
// without this the dumps compose from a zero matrix and read NaN.
static simd_float4x4 sSohVREyeXform[2] = {
    { .columns = { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } } },
    { .columns = { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0.063f, 0, 0, 1 } } }
};
static float sSohVRTan[2][4];           // per eye: L, R, B, T tangents
static double sSohVRExtent[2][2];       // per eye: viewport w, h
static int sSohVRTexIdx[2], sSohVRSlice[2];
static unsigned long sSohVRColorFmt = 0, sSohVRDepthFmt = 0;
static int sSohVRLayout = -1, sSohVRRateMaps = 0, sSohVRTexCount = 0;
// R8: the rasterization rate map, as numbers (0 everywhere in the simulator).
static int sSohVRRateMapPhysW = 0, sSohVRRateMapPhysH = 0;
static int sSohVRRateMapScrW = 0, sSohVRRateMapScrH = 0, sSohVRRateMapLayers = 0;
static float sSohVRDepthNear = 0.05f, sSohVRDepthFar = 1000.0f;
// The compositor's own reverse-Z range, for the depth conversion (R1).
static float sSohVRCompFar = 0.0f;
static int sSohVRCompFarInfinite = 1;

// Composed results.
static float sSohVREyeMtx[2][4][4]; // row-vector world->clip, Fast3D order
static simd_float3 sSohVREyePos[2]; // eye positions in the ARKit origin frame
static simd_float3 sSohVRIpdDelta;  // eye1 - eye0 expressed in eye0's frame
static int sSohVRComposed = 0;

// Present cadence (third leg of the pacing triple), fed by the immersive loops.
static double sSohVRPresentHz = 0.0;
static uint32_t sSohVRPresentCount = 0;
static double sSohVRPresentWindowStart = 0.0;
static uint32_t sSohVRPresentTotal = 0;

// Monotone sequence number: written LAST on every dump line so a truncated or
// interleaved read is detectable.
static uint32_t sSohVRSeq = 0;

// R1 loop state, declared here because the dump family reads it. The loop
// itself lives at the bottom of this file.
static int sSohVRLoopFrames = 0;      // compositor frames since VR entry
static int sSohVRLoopWorldFrames = 0; // ... of which head-tracked world frames
static int sSohVRLoopPanelFrames = 0; // ... of which panel-fallback frames
static int sSohVRTimeouts = 0;        // pose pairs the anchor ring had lost
static unsigned int sSohVRFrameId = 0;        // last pose pair published
static unsigned int sSohVRLastSubmittedId = 0; // last pose pair actually shown
static const char* sSohVRWorldReason = "boot"; // why a frame is NOT world

int SohVR_GetMode(void) {
    return sSohVRMode;
}
void SohVR_SetMode(int mode) {
    sSohVRMode = mode;
    sSohVRModeReason = (mode == 2) ? "vr-enter" : (mode == 1) ? "panel-enter" : "flat";
}

void SohVR_SetTunables(float scale, float dist, float height) {
    if (scale >= 1.0f && scale <= 100000.0f)
        sSohVRScale = scale;
    if (dist >= 0.05f && dist <= 50.0f)
        sSohVRDist = dist;
    if (height >= -10.0f && height <= 10.0f)
        sSohVRHeight = height;
}
void SohVR_GetTunables(float* scale, float* dist, float* height) {
    if (scale)
        *scale = sSohVRScale;
    if (dist)
        *dist = sSohVRDist;
    if (height)
        *height = sSohVRHeight;
}

// Level a head pose to yaw only — world placement must not inherit pitch/roll.
static simd_float4x4 sohvr_yaw_level(simd_float4x4 originFromHead) {
    simd_float3 pos = originFromHead.columns[3].xyz;
    simd_float3 fwd = -originFromHead.columns[2].xyz;
    fwd.y = 0.0f;
    float len = simd_length(fwd);
    fwd = (len < 1e-4f) ? simd_make_float3(0, 0, -1) : fwd / len;
    simd_float3 up = simd_make_float3(0, 1, 0);
    simd_float3 right = simd_normalize(simd_cross(up, -fwd));
    simd_float4x4 m;
    m.columns[0] = simd_make_float4(right, 0.0f);
    m.columns[1] = simd_make_float4(up, 0.0f);
    m.columns[2] = simd_make_float4(-fwd, 0.0f);
    m.columns[3] = simd_make_float4(pos, 1.0f);
    return m;
}

// Tentative declaration: the comfort filter below owns this flag, and a
// baseline capture has to re-seat it (the world's yaw moves with the baseline).
static int sSohVRHaveHeldYaw;

// Is this the identity pose? The simulator reports exactly that (C6), and an
// identity baseline is a no-op re-base — so it is accepted without meeting the
// height gate, which is what keeps the whole headless suite meaningful.
static int sohvr_pose_is_identity(simd_float4x4 m) {
    for (int c = 0; c < 4; c++) {
        for (int r = 0; r < 4; r++) {
            float want = (r == c) ? 1.0f : 0.0f;
            if (fabsf(m.columns[c][r] - want) > 1e-5f) {
                return 0;
            }
        }
    }
    return 1;
}

// Fold the inverse of the head pose at entry/recenter into A: the head's
// LOCATION and YAW at that moment become the mode's viewpoint exactly. Pitch
// and roll stay live on the head (levelled out here) — trap B1's rule that
// nothing comfort-shaped touches the submitted pose cuts both ways.
// Returns 1 if a baseline was captured.
static int sohvr_capture_baseline(simd_float4x4 m, const char* why) {
    int identity = sohvr_pose_is_identity(m);
    float h = m.columns[3].y;
    int plausible = (h >= SOHVR_BASE_H_MIN && h <= SOHVR_BASE_H_MAX);
    int forced = 0;
    if (!identity && !plausible) {
        sSohVRBaseRejects++;
        if (sSohVRBaseRejects < SOHVR_BASE_FORCE_TRIES) {
            return 0; // keep waiting — a floor-origin pose must never be the seat
        }
        // Never wedge the player in the panel fallback over a sanity gate: take
        // the pose, say so in the dump, and log it once.
        forced = 1;
        NSLog(@"[SohVR] BASELINE height gate overridden after %d refusals (h=%.2f m, why=%s)",
              sSohVRBaseRejects, h, why);
    }
    simd_float4x4 levelled = sohvr_yaw_level(m);
    sSohVRAnchor = levelled;
    sSohVRBasePos = m.columns[3].xyz;
    {
        simd_float3 f = -levelled.columns[2].xyz; // levelled gaze
        sSohVRBaseYawDeg = atan2f(-f.x, -f.z) * 180.0f / (float)M_PI;
    }
    sSohVRBaseForced = forced;
    sSohVRBaseValid = 1;
    sSohVRHaveAnchor = 1;
    sSohVRRebaseReq = 0;
    sSohVRBaseRejects = 0;
    sSohVRHaveHeldYaw = 0; // the comfort filter re-seats with the world
    NSLog(@"[SohVR] BASELINE why=%s pos=%.3f,%.3f,%.3f yaw=%.1f forced=%d identity=%d", why, sSohVRBasePos.x,
          sSohVRBasePos.y, sSohVRBasePos.z, sSohVRBaseYawDeg, forced, identity);
    return 1;
}

// Recenter: the head's position AND yaw right now become the seat. Armed
// rather than applied when the live pose does not qualify, so the next good
// frame lands it; the previous baseline stays in force meanwhile.
void SohVR_Recenter(void) {
    sSohVRRebaseReq = 1;
    sSohVRBaseRejects = 0;
    sSohVRRecenters++;
    if (sohvr_capture_baseline(sSohVRHeadPose, "recenter")) {
        return;
    }
    NSLog(@"[SohVR] recenter armed — waiting for a pose that passes the height gate");
}

int SohVR_RecenterCount(void) {
    return sSohVRRecenters;
}

// R18-B item 2c — "RECALCULATE HEIGHT". the user: "maybe have a recalculate
// height button in case the game needs it (vr can sometimes mess this up, and
// a recalculation fixes it)". The first-person eye is kart pose + seat (the
// pinned offsets) re-based by the head baseline captured at VR entry, plus
// the R9a head-lock compensation. What "messes it up" on a device is the
// BASELINE (captured at a bad moment — headset still settling, a forced
// capture past the height gate) or a seat that something else moved. So this
// runs exactly what a fresh VR entry runs: re-arm the baseline on the live
// head pose (Soh3D_Recenter — the 3D anchor and SohVR_Recenter, the same entry
// the stick-hold recenter uses), drop the head-lock compensation and the
// comfort follower's held yaw so both re-seat from the new baseline, and
// re-apply the pinned seat. The kart pose itself is re-read every frame, so
// nothing about it is cached here to re-derive.
static simd_float3 sSohVRHeadLockComp; // tentative: defined with the leash below
static double sSohVRHeadLockTime;
void SohVR_RecalcHeight(void) {
    extern void Soh3D_Recenter(void);
    const float upBefore = sSohVRSeatUp, fwdBefore = sSohVRSeatFwd;
    const float baseYBefore = sSohVRBaseValid ? sSohVRBasePos.y : -1.0f;
    const float compYBefore = sSohVRHeadLockComp.y;
    sohvr_pin_fp_seat("recalc height");
    sSohVRHeadLockComp = simd_make_float3(0, 0, 0);
    sSohVRHeadLockTime = 0.0;
    sSohVRHaveHeldYaw = 0;
    Soh3D_Recenter();
    sSohVRRecalcs++;
    NSLog(@"[SohVR] recalc height: seat up %.3f -> %.3f u, fwd %.3f -> %.3f u; head baseline y %.3f -> %.3f m "
          @"(%s); headlock comp y %.3f -> 0",
          upBefore, sSohVRSeatUp, fwdBefore, sSohVRSeatFwd, baseYBefore,
          sSohVRBaseValid ? sSohVRBasePos.y : -1.0f, sSohVRRebaseReq ? "re-base armed" : "re-based", compYBefore);
}
unsigned int SohVR_RecalcCount(void) {
    return sSohVRRecalcs;
}

void SohVR_InjectPose(float x, float y, float z, float yawDeg, float pitchDeg) {
    SohVR_InjectPoseRoll(x, y, z, yawDeg, pitchDeg, 0.0f);
}
// R17-B: an injected pose with ROLL. the user's third clause is "they even rotate
// as i rotate my head, meaning i can make a cloud turn on its side", and until
// now nothing in this port could tilt a head: `vr inject` had five arguments
// and the simulator's own pose is identity, so every roll assert that could
// have been written would have been taken at roll 0 and passed vacuously
// (trap D11's corollary -- most asserts have a blind configuration, and this
// one's was the only configuration available).
void SohVR_InjectPoseRoll(float x, float y, float z, float yawDeg, float pitchDeg, float rollDeg) {
    float cy = cosf(yawDeg * (float)M_PI / 180.0f), sy = sinf(yawDeg * (float)M_PI / 180.0f);
    float cp = cosf(pitchDeg * (float)M_PI / 180.0f), sp = sinf(pitchDeg * (float)M_PI / 180.0f);
    // Yaw about +Y then pitch about the yawed +X, ARKit convention (-Z gaze).
    simd_float3 fwd = simd_make_float3(-sy * cp, sp, -cy * cp);
    simd_float3 worldUp = simd_make_float3(0, 1, 0);
    simd_float3 right = simd_normalize(simd_cross(fwd, worldUp));
    simd_float3 up = simd_cross(right, fwd);
    if (rollDeg != 0.0f) {
        const float cr = cosf(rollDeg * (float)M_PI / 180.0f);
        const float sr = sinf(rollDeg * (float)M_PI / 180.0f);
        const simd_float3 r2 = right * cr + up * sr;
        const simd_float3 u2 = up * cr - right * sr;
        right = r2;
        up = u2;
    }
    simd_float4x4 m;
    m.columns[0] = simd_make_float4(right, 0.0f);
    m.columns[1] = simd_make_float4(up, 0.0f);
    m.columns[2] = simd_make_float4(-fwd, 0.0f);
    m.columns[3] = simd_make_float4(simd_make_float3(x, y, z), 1.0f);
    sSohVRHeadPose = m;
    sSohVRPoseInjected = 1;
    if (sSohVRRebaseReq) {
        // An injected pose is a valid pose: this is how the device re-base is
        // asserted headless (R5 suite case).
        sohvr_capture_baseline(m, "inject");
    }
}
void SohVR_ClearInjectedPose(void) {
    sSohVRPoseInjected = 0;
}

// Publish the live head pose / entry anchor from a presenting loop. Ignored
// while a synthetic pose is injected, so an injected assert cannot be raced by
// the compositor.
// `poseValid` is the TRACKER's verdict on this pose (R5): an untracked query
// hands back a matrix that looks like the ARKit origin, and taking that as the
// baseline is precisely bug 1 of the first device round.
static void sohvr_publish_pose(simd_float4x4 originFromHead, int poseValid) {
    if (sSohVRPoseInjected)
        return;
    sSohVRHeadPose = originFromHead;
    if (sSohVRRebaseReq && poseValid) {
        sohvr_capture_baseline(originFromHead, "entry");
    }
}

// Capture the per-eye contract from a live drawable. The frustum tangents are
// RECOVERED from the runtime's own projection (never hand-rolled): for a
// column-vector asymmetric frustum, columns[0].x = 2/(tR-tL) and
// columns[2].x = (tR+tL)/(tR-tL), so tR = (c2x+1)/c0x and tL = (c2x-1)/c0x.
static void sohvr_capture_contract(cp_drawable_t drawable) {
    size_t views = cp_drawable_get_view_count(drawable);
    sSohVRViewCount = (int)views;
    sSohVRTexCount = (int)cp_drawable_get_texture_count(drawable);
    sSohVRRateMaps = (int)cp_drawable_get_rasterization_rate_map_count(drawable);
    // R8 (foveation reconnaissance, item 2). Foveated ENGINE rendering needs
    // exactly three numbers, and none of them can be obtained in the
    // simulator: the sim's drawable reports ratemaps=0, so there is nothing to
    // bind and nothing to size an eye framebuffer against. Capture them here
    // so the FIRST device run of 1.0.0.5 answers the question the next round
    // has to start from — physical size is what a foveated eye framebuffer
    // would be, screen size is what it costs today, and their ratio is the
    // saving. See VR-R8-NOTES section 3.
    sSohVRRateMapPhysW = sSohVRRateMapPhysH = 0;
    sSohVRRateMapScrW = sSohVRRateMapScrH = 0;
    sSohVRRateMapLayers = 0;
    if (sSohVRRateMaps > 0) {
        id<MTLRasterizationRateMap> rm = cp_drawable_get_rasterization_rate_map(drawable, 0);
        if (rm != nil) {
            MTLSize phys = [rm physicalSizeForLayer:0];
            MTLSize scr = rm.screenSize;
            sSohVRRateMapPhysW = (int)phys.width;
            sSohVRRateMapPhysH = (int)phys.height;
            sSohVRRateMapScrW = (int)scr.width;
            sSohVRRateMapScrH = (int)scr.height;
            sSohVRRateMapLayers = (int)rm.layerCount;
        }
    }
    id<MTLTexture> t0 = cp_drawable_get_color_texture(drawable, 0);
    id<MTLTexture> d0 = cp_drawable_get_depth_texture(drawable, 0);
    sSohVRColorFmt = (unsigned long)t0.pixelFormat;
    sSohVRDepthFmt = (unsigned long)d0.pixelFormat;
    sSohVRLayout = (t0.arrayLength > 1) ? 1 : 0; // 1 = layered-ish, 0 = dedicated

    // R1 (spec D2 as amended): the depth handoff CONVERTS, so both ends of
    // the conversion have to be the runtime's own numbers, never constants.
    // depth_range is reported in REVERSE-Z order: x = far, y = near, and far
    // is routinely infinite. The engine's forward-Z frustum is built on the
    // SAME near so only the far term differs in the conversion.
    {
        simd_float2 dr = cp_drawable_get_depth_range(drawable);
        float compFar = dr.x, compNear = dr.y;
        sSohVRCompFarInfinite = !isfinite(compFar) || compFar <= compNear;
        if (compNear > 1e-4f && compNear < 10.0f) {
            sSohVRDepthNear = compNear;
        }
        sSohVRCompFar = sSohVRCompFarInfinite ? 0.0f : compFar;
        // Engine far: the compositor's when it has one, otherwise a finite
        // stand-in large enough that a diorama never reaches it.
        sSohVRDepthFar = sSohVRCompFarInfinite ? 10000.0f : compFar;
    }

    for (int e = 0; e < 2; e++) {
        size_t v = ((size_t)e < views) ? (size_t)e : 0;
        cp_view_t view = cp_drawable_get_view(drawable, v);
        cp_view_texture_map_t tmap = cp_view_get_view_texture_map(view);
        MTLViewport vp = cp_view_texture_map_get_viewport(tmap);
        sSohVRExtent[e][0] = vp.width;
        sSohVRExtent[e][1] = vp.height;
        sSohVRTexIdx[e] = (int)cp_view_texture_map_get_texture_index(tmap);
        sSohVRSlice[e] = (int)cp_view_texture_map_get_slice_index(tmap);

        simd_float4x4 deviceFromEye = cp_view_get_transform(view);
        if ((size_t)e >= views) {
            // D11/C6: the simulator reports ONE view with an identity eye
            // transform. Synthesize the missing eye by displacing +0.063 m
            // along eye-space X so the stereo asserts have something to check.
            // On a real device this branch never runs.
            deviceFromEye = simd_mul(deviceFromEye, soh3d_translate(0.063f, 0.0f, 0.0f));
        }
        sSohVREyeXform[e] = deviceFromEye;

        simd_float4x4 proj = matrix_identity_float4x4;
        if (__builtin_available(visionOS 2.0, *))
            proj = cp_drawable_compute_projection(drawable, cp_axis_direction_convention_right_up_back, v);
        float c0x = proj.columns[0].x, c1y = proj.columns[1].y;
        float c2x = proj.columns[2].x, c2y = proj.columns[2].y;
        if (fabsf(c0x) > 1e-6f && fabsf(c1y) > 1e-6f) {
            sSohVRTan[e][0] = (c2x - 1.0f) / c0x; // left
            sSohVRTan[e][1] = (c2x + 1.0f) / c0x; // right
            sSohVRTan[e][2] = (c2y - 1.0f) / c1y; // bottom
            sSohVRTan[e][3] = (c2y + 1.0f) / c1y; // top
        }
    }
    sSohVRContractValid = 1;
    sohvr_build_foveation_map(t0.device);
}

// --- R9 item 1c: FOVEATED ENGINE RENDERING -----------------------------------
//
// The plan is VR-R8-NOTES §2.3 and this is its first three steps. The engine's
// eye pass rasterizes 5087x4081 PHYSICAL pixels per eye at 100% render quality;
// almost all of them are in the periphery, where the headset's own optics throw
// them away. Rendering them is both the perf cost R8 measured (engine_fps 22.70,
// the game at 75% speed) and — through the ~830 MB of attachments they imply —
// half of the memory-pressure story behind the rainbows.
//
// Two things R8 established that this code obeys:
//
//  * The map must be OURS, not the drawable's. The drawable's map is dynamic
//    (it tracks the eyes) and belongs to that drawable; the engine renders its
//    eye framebuffers on its own thread at ~30 fps, AHEAD of time, and the
//    compositor consumes them at 90-120 Hz across several drawables with
//    several different maps. Sampling a texture warped by map A through map B
//    is geometry swimming as the foveation pattern moves — which is
//    uncomfortably close to the artefact class this round exists to remove.
//    So: a FIXED map we own, self-consistent by construction. Static foveation
//    rather than eye-tracked, which is the great majority of the saving.
//
//  * No two-space encoder is needed (R7 thought there was). A rate map applies
//    to a whole render pass, but `rasterization_rate_map_decoder` runs in the
//    FRAGMENT SHADER: the world blit converts its own screen coordinate to the
//    physical one and samples the pre-warped eye texture there, so the
//    compositor pass keeps ITS map, its logical viewport, and the dim wash and
//    HUD plane are untouched.
//
// TRAP D15 governs what can be proven here: THE SIMULATOR HAS NO
// RASTERIZATION RATE MAP AT ALL (`ratemaps=0`, every frame, every view). So the
// capability is detected off the live drawable and the whole feature is gated
// on it: on device it can be turned on, in the simulator it is structurally
// impossible and the full-resolution path runs unchanged — which is the path
// the suite covers.
static id<MTLRasterizationRateMap> sSohVRFoveMap = nil;
static int sSohVRFoveCap = 0;      // the runtime reports rate maps at all
static int sSohVRFoveEnabled = 0;  // the user's toggle (persisted)
static int sSohVRFovePhysW = 0, sSohVRFovePhysH = 0;
static int sSohVRFoveScrW = 0, sSohVRFoveScrH = 0;
static float sSohVRFoveSaving = 0.0f; // 1 - physical/screen pixel ratio

static void sohvr_build_foveation_map(id<MTLDevice> dev) {
    // Capability: the runtime exposes rate maps on this drawable at all. In the
    // simulator this is 0 and stays 0, so everything below is skipped and the
    // engine keeps rendering at full resolution (trap D15).
    sSohVRFoveCap = (sSohVRRateMaps > 0 && sSohVRRateMapScrW > 0) ? 1 : 0;
    if (!sSohVRFoveCap || dev == nil) {
        return;
    }
    int wantW = sSohVREyeW > 0 ? sSohVREyeW : sSohVRRateMapScrW;
    int wantH = sSohVREyeH > 0 ? sSohVREyeH : sSohVRRateMapScrH;
    if (sSohVRFoveMap != nil && sSohVRFoveScrW == wantW && sSohVRFoveScrH == wantH) {
        return; // already built at this size
    }
    if (@available(visionOS 1.0, *)) {
        // A fixed, symmetric quality falloff: full rate across the middle
        // ~40% of each axis, tapering to 40% at the edges. Eleven zones per
        // axis is enough for the taper to be invisible and cheap to describe.
        const int kZones = 11;
        float q[kZones];
        for (int i = 0; i < kZones; i++) {
            float c = ((float)i + 0.5f) / (float)kZones; // 0..1 across the axis
            float d = fabsf(c - 0.5f) * 2.0f;            // 0 centre, 1 edge
            float v = (d < 0.4f) ? 1.0f : (1.0f - (d - 0.4f) / 0.6f * 0.6f);
            q[i] = v;
        }
        MTLRasterizationRateLayerDescriptor* layer =
            [[MTLRasterizationRateLayerDescriptor alloc] initWithSampleCount:MTLSizeMake(kZones, kZones, 0)];
        for (int i = 0; i < kZones; i++) {
            layer.horizontalSampleStorage[i] = q[i];
            layer.verticalSampleStorage[i] = q[i];
        }
        MTLRasterizationRateMapDescriptor* desc =
            [MTLRasterizationRateMapDescriptor rasterizationRateMapDescriptorWithScreenSize:MTLSizeMake(wantW, wantH,
                                                                                                       0)
                                                                                      layer:layer];
        desc.label = @"SohVR fixed foveation";
        id<MTLRasterizationRateMap> map = [dev newRasterizationRateMapWithDescriptor:desc];
        if (map == nil) {
            NSLog(@"[SohVR] foveation: newRasterizationRateMapWithDescriptor FAILED (%dx%d) — staying full-res",
                  wantW, wantH);
            sSohVRFoveCap = 0;
            return;
        }
        MTLSize phys = [map physicalSizeForLayer:0];
        sSohVRFoveMap = map;
        sSohVRFoveScrW = wantW;
        sSohVRFoveScrH = wantH;
        sSohVRFovePhysW = (int)phys.width;
        sSohVRFovePhysH = (int)phys.height;
        double scrPx = (double)wantW * (double)wantH;
        double physPx = (double)phys.width * (double)phys.height;
        sSohVRFoveSaving = (scrPx > 0.0) ? (float)(1.0 - physPx / scrPx) : 0.0f;
        NSLog(@"[SohVR] foveation map built: screen=%dx%d physical=%dx%d saving=%.1f%% (enabled=%d)", wantW, wantH,
              sSohVRFovePhysW, sSohVRFovePhysH, sSohVRFoveSaving * 100.0f, sSohVRFoveEnabled);
    }
}

void SohVR_SetFoveation(int on) {
    extern void SohVR_SettingsSave(void);
    sSohVRFoveEnabled = on ? 1 : 0;
    SohVR_SettingsSave();
}
int SohVR_GetFoveation(void) {
    return sSohVRFoveEnabled;
}
int SohVR_GetFoveationCap(void) {
    return sSohVRFoveCap;
}

// The engine's far plane, in metres. ONE owner, because the projection and the
// depth handoff in the blit shader must agree exactly — converting with a
// different far than you projected with is a depth bug that looks like a
// z-fight (R5 ladder level 5, H-D).
static float sohvr_engine_far(void) {
    float f = sSohVRDepthFar;
    // R5 ladder level 5 (H-D): pull the far plane in. The compositor reports an
    // INFINITE far on device, so the engine's forward-Z stand-in is 10000 m
    // against a ~0.05 m near — a 200000:1 range in a float depth buffer, whose
    // precision is worst exactly where the artefacts are (far geometry).
    if ((sohvr_dbg_on(5) || sohvr_diag_off(SOHVR_DIAG_FARPLANE)) && f > 1000.0f) {
        f = 1000.0f;
    }
    return f;
}

// Forward-Z Metal projection ([0,1] depth, near->0) from recovered tangents.
static simd_float4x4 sohvr_projection(int eye) {
    float tL = sSohVRTan[eye][0], tR = sSohVRTan[eye][1];
    float tB = sSohVRTan[eye][2], tT = sSohVRTan[eye][3];
    if (tR - tL < 1e-6f || tT - tB < 1e-6f) {
        // Headless fallback: a symmetric 90x90 frustum, flagged in the dump.
        tL = -1.0f; tR = 1.0f; tB = -1.0f; tT = 1.0f;
    }
    float n = sSohVRDepthNear, f = sohvr_engine_far();
    simd_float4x4 p = (simd_float4x4){ { { 0 }, { 0 }, { 0 }, { 0 } } };
    p.columns[0] = simd_make_float4(2.0f / (tR - tL), 0, 0, 0);
    p.columns[1] = simd_make_float4(0, 2.0f / (tT - tB), 0, 0);
    p.columns[2] = simd_make_float4((tR + tL) / (tR - tL), (tT + tB) / (tT - tB), -f / (f - n), -1.0f);
    p.columns[3] = simd_make_float4(0, 0, -f * n / (f - n), 0);
    return p;
}

// --- comfort: fixed horizon through spins (trap A6, R2) ----------------------
// RaYRoD's patch-3 lesson, taken deliberately rather than letting it fall out
// of the matrix code: during a banana spin / collision tumble the game camera
// whips through a full revolution, and a head bolted to that basis is carried
// with it. The fix lives in A (never in the submitted pose — trap B1): the
// world's yaw is HELD at its pre-spin value while the spin flag is up, and the
// pitch/roll of the camera basis is dropped entirely, so the kart spins under
// a level, still world. "Authentic" (`vr set horizon 0`) restores the raw
// basis for the device comparison the user will make.
static float sSohVRHeldYaw = 0.0f;   // radians, the yaw A is actually using
static int sSohVRHaveHeldYaw = 0;
static int sSohVRSpinLatched = 0;    // 1 while the game reports a spin/tumble
static float sSohVRSpinBlend = 1.0f; // 0 = fully held, 1 = fully following
static double sSohVRLastWorldTime = 0.0;
static int sSohVRSpinEvents = 0;

// --- R7: cockpit lock ------------------------------------------------------
// The composition was never missing (R6 already builds A's rotation from the
// KART's forward, so the kart frame IS the player frame). What broke it was
// this filter being held down: overlay 0051 rev3 raised gSohVRKartSpin on
// MK64's AIRBORNE bit, which is set on every hop and bump, and a raised spin
// flag parks sSohVRSpinBlend at 0 — the seat rides the kart while the gaze
// stays where the last landing left it. 0051 rev4 fixes the source; these two
// constants make the filter unable to cause it again.
//
//  * SOHVR_SPIN_HOLD_MAX — a hold that never ends is indistinguishable from a
//    broken cockpit lock. Even a genuine spin releases after this.
//  * SOHVR_YAW_TAU — the kart yaw is an ENGINE-TICK quantity (30 Hz engine /
//    60 Hz tick) and A is composed at the compositor's 90-120 Hz, so snapping
//    to it transmits the tick staircase straight into the head. A 35 ms time
//    constant removes the staircase and costs ~3 deg of lag at a hard turn
//    (90 deg/s), which is under the just-noticeable threshold. It lives in A,
//    never in the submitted pose (trap B1).
#define SOHVR_SPIN_HOLD_MAX 2.5f
#define SOHVR_YAW_TAU 0.035f
static float sSohVRSpinHold = 0.0f;     // seconds the yaw has been held
static float sSohVRCockpitErrDeg = 0.0f; // composed eye yaw - kart yaw, degrees

// R9 item 4 — the head-position leash. See the block at the end of
// sohvr_world_matrix for the derivation and for why the compensation lives in A
// and never anywhere near the submitted pose (trap B1).
//   DEADZONE — metres of free head travel, sway keeps its parallax inside it.
//   TAU      — how fast the excess is eased out; 0.30 s is slow enough not to
//              read as the world shoving back, fast enough that two steps are
//              gone before you have taken a third.
#define SOHVR_HEADLOCK_DEADZONE 0.12f
#define SOHVR_HEADLOCK_TAU 0.30f
static int sSohVRHeadLock = 1;                             // ON by default
static simd_float3 sSohVRHeadLockComp = { 0, 0, 0 };       // metres, origin space
static double sSohVRHeadLockTime = 0.0;
static float sSohVRHeadLockDrift = 0.0f;                   // |head - baseline|, m

// R9 item 6 — "Realistic Spins (intense)". Persisted; default OFF (off = the
// fixed-horizon comfort hold this port has always shipped).
// R10 item 5 — TWO toggles, superseding R9's single "Realistic Spins".
//
// the user's spec, and it splits along a line R9 had already found and then
// merged back together: a SPIN-OUT is yaw (you revolve on the road), a
// FLIP-OUT is the mid-air somersault a shell or a bolt throws you into. They
// are different sensations, they have different comfort costs, and they now
// have a row each.
//
//   Realistic Spin-Out  — the in-plane 360 yaw follow. DEFAULT ON: this is
//                         what R9's row did, and the user wants it as the
//                         shipped behaviour.
//   Realistic Flip-Out  — the composed tumble (roll + somersault pitch).
//                         DEFAULT OFF; it is the intense one, and it did not
//                         work at all in 1.0.0.6 (0054 rev2 explains why).
//
// Turning Spin-Out OFF must hold the horizon for EVERY spin class, not just
// the ones the flag happened to know about — 0051 rev5 is that fix.
static int sSohVRRealisticSpins = 1;
static int sSohVRRealisticFlips = 0;
static float sSohVRTumbleRollDeg = 0.0f, sSohVRTumblePitchDeg = 0.0f;

// R9b item 8 — "Show Hands". visionOS draws the wearer's real arms over an
// immersive space when the scene asks for it; a driver's own hands are NOT on
// an MK64 wheel, so the default is OFF and this is the opt-in. Persisted; the
// SwiftUI side owns the actual `.upperLimbVisibility` modifier.
static int sSohVRShowHands = 0;

// Kart-pose injection (R7 suite): the headless asserts need to RAMP the kart's
// yaw with no race running. When armed these stand in for overlay 0045's
// exports everywhere A reads them, so the whole cockpit-lock composition is
// exercised in the simulator.
static int sSohVRKartInject = 0;
static simd_float3 sSohVRKartInjPos = { 0, 0, 0 };
static int sSohVRKartInjYawBam = 0;

// The kart pose A is built on: injected when armed, overlay 0045's export
// otherwise. ONE reader, so the telemetry can never disagree with the matrix.
// R16-A (F1): how many GAME frames a kart snapshot may be old before the seat
// stops believing it. Three is two frames of grace at the engine's ~30 Hz
// (~100 ms): long enough that no scheduling accident can produce a false
// "no kart" mid-race, short enough that a menu, a podium or a quit transition
// — none of which export — drops the seat back to the camera immediately.
#define SOHVR_KART_STALE_FRAMES 3u
static unsigned int sSohVRKartRetries = 0; // seqlock retries, telemetry only
// R16-C: the look-behind camera export's own seqlock health (0045 rev5).
static unsigned int sSohVRRearRetries = 0;
static unsigned int sSohVRRearAgeMax = 0;
static unsigned int sSohVRKartAgeMax = 0;  // worst snapshot age seen, frames
// R17-A item 1: the PREVIOUS game frame's kart position, latched by the same
// seqlock read as the current one. A file static rather than a fourth out
// parameter because sohvr_kart_pose has four call sites and only the A build
// wants it -- and because a value read OUTSIDE the seqlock would be the exact
// torn read rev4 was written to close.
static simd_float3 sSohVRKartPosPrevRead = { 0, 0, 0 };
// R18-A: the game frame the pose above was exported on, latched by the same
// seqlock read. The snapshot carries it so the engine can tell a walk that
// latched a matrix composed from the PREVIOUS game frame's pose.
static unsigned int sSohVRKartFrameRead = 0;
static int sohvr_kart_pose(simd_float3* pos, int* yawBam) {
    extern volatile float gSohVRKartPos[3], gSohVRKartPosPrev[3];
    extern volatile int gSohVRKartYawBam, gSohVRKartValid;
    extern volatile unsigned int gSohVRKartSeq, gSohVRKartFrame, gSohVRGameFrame;
    if (sSohVRKartInject) {
        if (pos) {
            *pos = sSohVRKartInjPos;
        }
        if (yawBam) {
            *yawBam = sSohVRKartInjYawBam;
        }
        // An injected kart does not move between game frames, so the seat's
        // interpolation segment is a point and the correction is exactly zero.
        sSohVRKartPosPrevRead = sSohVRKartInjPos;
        sSohVRKartFrameRead = 0;
        return 1;
    }
    if (!gSohVRKartValid) {
        return 0; // no player-1 racing camera has ever exported a kart
    }
    // THE SEQLOCK READ (overlay 0045 rev4 writes the other half). Odd means a
    // write is in progress; an unequal pair either side of the payload means
    // one landed across our read. Bounded: the writer runs at the engine's
    // ~30 Hz and this reader at 90-120 Hz, so a single retry is already
    // generous and four is belt-and-braces.
    float kx = 0.0f, ky = 0.0f, kz = 0.0f;
    float px = 0.0f, py = 0.0f, pz = 0.0f;
    unsigned int kFrame = 0;
    int kYaw = 0;
    int got = 0;
    for (int t = 0; t < 4; t++) {
        unsigned int s0 = gSohVRKartSeq;
        if (s0 & 1u) {
            sSohVRKartRetries++;
            continue;
        }
        __sync_synchronize();
        kx = gSohVRKartPos[0];
        ky = gSohVRKartPos[1];
        kz = gSohVRKartPos[2];
        px = gSohVRKartPosPrev[0]; // R17-A item 1: the other end of the segment
        py = gSohVRKartPosPrev[1];
        pz = gSohVRKartPosPrev[2];
        kYaw = gSohVRKartYawBam;
        kFrame = gSohVRKartFrame;
        __sync_synchronize();
        if (gSohVRKartSeq == s0) {
            got = 1;
            break;
        }
        sSohVRKartRetries++;
    }
    if (!got) {
        return 0;
    }
    // STALENESS, NOT A HOLE. The frame counter advances at the head of every
    // game frame in every state, so this is "how many game frames since a
    // racing camera last exported a kart" — 0 or 1 while racing, unbounded the
    // moment the game stops racing.
    unsigned int age = gSohVRGameFrame - kFrame;
    if (age > sSohVRKartAgeMax && age < 1000u) {
        sSohVRKartAgeMax = age;
    }
    if (age > SOHVR_KART_STALE_FRAMES) {
        return 0;
    }
    if (pos) {
        *pos = simd_make_float3(kx, ky, kz);
    }
    if (yawBam) {
        *yawBam = kYaw;
    }
    sSohVRKartPosPrevRead = simd_make_float3(px, py, pz);
    sSohVRKartFrameRead = kFrame;
    return 1;
}

// R16-A: cleared by `vr set r16clear 1` with the rest of the round's counters.
void SohVR_ClearKartStats(void) {
    sSohVRKartRetries = 0;
    sSohVRKartAgeMax = 0;
}
void SohVR_InjectKart(int on, float x, float y, float z, int yawBam) {
    sSohVRKartInject = on ? 1 : 0;
    sSohVRKartInjPos = simd_make_float3(x, y, z);
    sSohVRKartInjYawBam = (int)(short)yawBam;
}
float SohVR_GetCockpitErrDeg(void) {
    return sSohVRCockpitErrDeg;
}

static simd_float3 sSohVRSeatGame = { 0, 0, 0 }; // R5: A's seat point, game units
// R17-A item 1: (previous game frame's seat) - (this one), game units. Rides
// the frame snapshot to the engine, which applies it scaled by (1 - walk t).
static simd_float3 sSohVRSeatPrevDelta = { 0, 0, 0 };
// R18-A: the raw pose `origin` was derived from (kart position, or the chase
// camera's eye) and the game frame it came from. Rides the snapshot so 0044
// rev15 can correct the matrix by (current export - this) on the game thread.
static simd_float3 sSohVRSeatBase = { 0, 0, 0 };
static unsigned int sSohVRSeatBaseFrame = 0;

static float sSohVRSeatErr = 0.0f;               // |composed head - seat|, game units
// R6 seat-correctness telemetry. `seat_src` says which derivation ran,
// `kart_dist` is how far the seat sits from the kart's own origin (the whole
// of the user's "I can see myself" bug as one number), and `gaze_dot` is the
// composed neutral gaze against the kart's forward: +1 = looking down the
// road, -1 = looking at your own back.
static int sSohVRSeatFromKart = 0;
static float sSohVRKartDist = 0.0f;
static float sSohVRGazeDot = 0.0f;

// --- R8: the INDEPENDENT orientation ground truth ----------------------------
//
// R7 shipped `cockpit_err` as "the honest number" and it read 0.00 deg through
// a full +-90 deg of injected kart yaw while the DEVICE was steering inverted.
// It is tautological, and the reason is now written down so the trap does not
// fire a third time: `cockpit_err` takes the composed eye's yaw out through
// atan2f(fwdGame.x, fwdGame.z) and compares it to the kart yaw that A was
// built from with (sinf, cosf). Test and implementation share the SAME angle
// convention, so a mirrored convention cancels exactly and the error is zero
// by construction.
//
// The R8 measure never touches an angle at all. `gSohVRKartVel` is
// `gPlayerOne->velocity`, which MK64 integrates straight into the kart's
// position (`nextX = posX + player->velocity[0]`, player_controller.c:2044) —
// a WORLD-SPACE displacement, produced by physics, with no binary angle and no
// convention anywhere in its derivation. So:
//
//   drive_dot   = dot(travel direction, the forward A was built from). ~+1.
//   drive_ndcx  = the NDC x of a point 400 units along the TRAVEL direction,
//                 projected through the LIVE composed eye matrix — the very
//                 matrix Fast3D renders the eye with. "Is the place I am
//                 driving to in front of my eyes?" ~0.
//
// Neither reads gSohVRKartYawBam, so neither can cancel against it, and
// `drive_ndcx` additionally proves the whole chain (yaw -> A -> V -> P ->
// clip) rather than just its first link. `vr set yawmirror 1` flips the kart
// yaw sign inside A on purpose: the suite takes both readings and REQUIRES the
// mirrored one to fail loudly, which is how it proves the assert can fail at
// the heading it was taken at (the anti-tautology guard).
static int sSohVRYawMirror = 0;         // diagnostic: mirror the kart yaw in A
static simd_float3 sSohVRWorldFwd = { 0, 0, 1 }; // the forward A was built from
static float sSohVRKartSpeed = 0.0f;    // |velocity.xz|, game units per frame
static float sSohVRDriveDot = 0.0f;     // travel dir . A's forward
static float sSohVRDriveNdcX = 0.0f;    // NDC x of the point being driven at
static float sSohVRDriveW = 0.0f;       // its clip w (>0 = in front of the eye)
static int sSohVRDriveValid = 0;
static float sSohVRCamFwdErrDeg = 0.0f;       // A's kart forward vs the game camera's
static float sSohVRCamFwdErrMirrorDeg = 0.0f; // ... and what the mirrored convention would read

float SohVR_GetCamFwdErrDeg(void) {
    return sSohVRCamFwdErrDeg;
}

int SohVR_GetYawMirror(void) {
    return sSohVRYawMirror;
}
void SohVR_SetYawMirror(int on) {
    sSohVRYawMirror = on ? 1 : 0;
}

static float sohvr_wrap_pi(float a) {
    while (a > (float)M_PI) {
        a -= 2.0f * (float)M_PI;
    }
    while (a < -(float)M_PI) {
        a += 2.0f * (float)M_PI;
    }
    return a;
}

// A: game world -> player space. Built from 0045's exported camera basis plus
// the mode's tunables. All comfort/damping belongs HERE (trap B1) — never in
// the pose submitted to the compositor.
static simd_float4x4 sohvr_world_matrix(void) {
    extern volatile float gSoh3DCamRight[3], gSoh3DCamFwd[3], gSoh3DCamEye[3];
    extern volatile float gSoh3DCamDist;
    extern volatile int gSohVRKartSpin;
    simd_float3 right = simd_make_float3(gSoh3DCamRight[0], gSoh3DCamRight[1], gSoh3DCamRight[2]);
    simd_float3 fwd = simd_make_float3(gSoh3DCamFwd[0], gSoh3DCamFwd[1], gSoh3DCamFwd[2]);
    simd_float3 eye = simd_make_float3(gSoh3DCamEye[0], gSoh3DCamEye[1], gSoh3DCamEye[2]);
    if (simd_length(right) < 1e-4f || simd_length(fwd) < 1e-4f) {
        right = simd_make_float3(1, 0, 0);
        fwd = simd_make_float3(0, 0, 1);
        eye = simd_make_float3(0, 0, 0);
    }
    right = simd_normalize(right);
    fwd = simd_normalize(fwd);
    simd_float3 up = simd_cross(right, fwd); // 0045 exports right = fwd x up

    const SohVRViewCfg* cfg = &sSohVRCfg[sSohVRView];

    // FIRST-PERSON SEAT — R6, the headline fix of the round.
    //
    // R2..R5 derived the seat from the CHASE CAMERA: `eye + fwd * camDist`,
    // i.e. the camera's LOOK-AT point. That is not the kart. MK64's racing
    // camera aims at `player->pos + R(yaw) * unk_3C` (src/camera.c) — a target
    // offset AHEAD of the kart, not the kart itself — so the seat landed in
    // front of the machine with the kart BEHIND the eye. Turn your head and
    // there is Toad, exactly as the user reported. (There is no 180 deg yaw
    // error: see docs/VR-R6-NOTES.md for the arithmetic.)
    //
    // The seat now comes from the kart's OWN pose (overlay 0045 rev2 exports
    // gSohVRKartPos / gSohVRKartYawBam from gPlayerOne at the camera's own
    // export site, player 1 only). Eye = kart origin + seat offsets expressed
    // in the KART's frame, and the neutral gaze is the KART's forward — so
    // "looking ahead" is the road ahead and "looking behind" is the track
    // behind, by construction.
    //
    // MK64 yaw convention, verified in the source rather than by feel (trap
    // B3): `camera->rot[1] = atan2s(dx, dz)` (src/code_80091440.c:57) and
    // `cameras[i].rot[1] = gPlayerOne[i].rotation[1]` (src/camera.c:1281) —
    // the kart's rotation[1] is the SAME binary angle, so
    // forward = (sins(yaw), 0, coss(yaw)). That is the identical convention
    // the eye re-key below already round-trips through atan2f(x, z).
    //
    // R7 — WHY THIS IS "COCKPIT LOCK": because `fwd` below becomes the kart's
    // forward, and the rotation A is built from turns that forward into the
    // player's -Z, the KART FRAME IS THE PLAYER FRAME. The kart turns left and
    // the world rotates right around a stationary player, with the gaze still
    // boresighted down the road; the head's own rotation composes on top
    // through V, so look-behind still works by turning your head. That was
    // already true in R6 — see the filter below for what was defeating it.
    simd_float3 kartPos;
    int kartYawBam = 0;
    int kartValid = sohvr_kart_pose(&kartPos, &kartYawBam);
    simd_float3 origin = eye;
    // R14 item 5: the seat source is reset here and decided below, so the EDGE
    // has to be taken across the whole decision — an increment on either write
    // counts the per-frame reset and reads as a flip every single frame (it
    // read 6699 in one race before this was fixed, which is the counter being
    // wrong, not the seat).
    const int sohSeatWas = sSohVRSeatFromKart;
    sSohVRSeatFromKart = 0;
    if (sSohVRView == SOHVR_VIEW_FP && kartValid) {
        // R8: `kartYawBam` arrives in the CAMERA (atan2s) convention — overlay
        // 0045 rev3 negates MK64's player->rotation[1] at the export boundary,
        // because the two conventions are mirrored and rev2 shipped the raw
        // value. That mirror is the whole of the inverted-orbit steering bug:
        // it makes A's yaw run BACKWARDS against the kart's real heading, so
        // the kart turns left and the world turns left with it instead of
        // against it. See the patch header for the physics citation, and
        // `drive_ndcx` below for the assert that would have caught it.
        float kyaw = (float)kartYawBam * (float)M_PI / 32768.0f;
        if (sSohVRYawMirror) {
            kyaw = -kyaw; // diagnostic control: the R7 behaviour, on purpose
        }
        simd_float3 kFwd = simd_make_float3(sinf(kyaw), 0.0f, cosf(kyaw));
        origin = kartPos;
        origin.y += sSohVRSeatUp;
        origin += kFwd * sSohVRSeatFwd;
        // The neutral gaze IS the kart's forward. Everything downstream (the
        // fixed-horizon filter, the rotation build) reads `fwd`.
        fwd = kFwd;
        up = simd_make_float3(0, 1, 0);
        right = simd_normalize(simd_cross(fwd, up)); // 0045 convention
        up = simd_cross(right, fwd);
        sSohVRSeatFromKart = 1;
    } else if (sSohVRView == SOHVR_VIEW_FP || sSohVRView == SOHVR_VIEW_THIRD) {
        // FALLBACK (no kart pose: menus, fly-by, podium, or a build whose
        // 0045 rev2 export never fired) and the THIRD-person camera, which
        // deliberately stays on the chase camera the game was authored for.
        simd_float3 fwdLevel = simd_make_float3(fwd.x, 0.0f, fwd.z);
        float fl = simd_length(fwdLevel);
        fwdLevel = (fl < 1e-4f) ? simd_make_float3(0, 0, 1) : fwdLevel / fl;
        float camD = gSoh3DCamDist;
        if (!(camD > 1.0f && camD < 5000.0f)) {
            camD = 200.0f;
        }
        if (sSohVRView == SOHVR_VIEW_FP) {
            origin = eye + fwd * camD;
            origin.y += sSohVRSeatUp;
            origin += fwdLevel * sSohVRSeatFwd;
        } else {
            // THIRD (R3): stay AT the chase camera — it is already behind and
            // above the kart, and it is the shot the game was authored for —
            // pulled a little further back and lifted a little, so the kart
            // reads as a model in front of you rather than a bumper cam.
            origin = eye - fwdLevel * sSohVRThirdBack;
            origin.y += sSohVRThirdUp;
        }
    }
    if (sSohVRSeatFromKart != sohSeatWas) {
        sSohVRSeatFlips++; // R14 item 5: a genuine change of seat source
    }
    // R17-A item 1 — THE SEGMENT THE SEAT MUST BE INTERPOLATED ALONG.
    //
    // `origin` above is built from a pose exported ONCE PER GAME FRAME, while
    // every object the display list draws is placed by
    // FrameInterpolation_Interpolate(t) at the walk's own sub-frame t. So the
    // world glides and the seat steps, and relative to the seat a nearby kart
    // alternates between on-time and half a game frame ahead on every present.
    // This is the previous game frame's seat MINUS this one, in game units;
    // the ENGINE applies it scaled by (1 - t), where t is the walk's own factor
    // (overlay 0014 rev2 publishes it, 0044 rev13 consumes it).
    //
    // Only the BASE moves per game frame: the seat offsets (seat_up/seat_fwd,
    // third_up/third_back) are constants, and the direction they are expressed
    // in is the yaw follower's output, which already runs at compositor rate
    // and is continuous. So the base's own step IS the seat's step.
    {
        extern volatile float gSoh3DCamEyePrev[3];
        simd_float3 basePrev;
        if (sSohVRSeatFromKart) {
            basePrev = sSohVRKartPosPrevRead;
            sSohVRSeatPrevDelta = basePrev - kartPos;
        } else {
            basePrev = simd_make_float3(gSoh3DCamEyePrev[0], gSoh3DCamEyePrev[1], gSoh3DCamEyePrev[2]);
            sSohVRSeatPrevDelta = basePrev - simd_make_float3(gSoh3DCamEye[0], gSoh3DCamEye[1], gSoh3DCamEye[2]);
        }
        // A course change, a respawn or a Lakitu pickup teleports the base;
        // interpolating across that would smear the whole world for one game
        // frame. 400 game units is far past anything a 30 Hz frame of racing
        // can produce (MK64 tops out around 18 units per frame) and far short
        // of any teleport.
        if (simd_length(sSohVRSeatPrevDelta) > 400.0f) {
            sSohVRSeatPrevDelta = simd_make_float3(0, 0, 0);
        }
        // R18-A: the base `origin` was built from, as read HERE (compositor
        // thread). R17-A's engine-side correction assumed this equals the
        // export current at the walk; it is not, whenever the compositor
        // composed before the game thread's export for the frame being walked.
        if (sSohVRSeatFromKart) {
            // An INJECTED kart is not the export, and correcting the matrix
            // onto the export would undo the injection every suite yaw/seat
            // assert relies on: publish no base (0044 then applies no rebase).
            sSohVRSeatBase = sSohVRKartInject ? simd_make_float3(0, 0, 0) : kartPos;
            sSohVRSeatBaseFrame = sSohVRKartFrameRead;
        } else {
            sSohVRSeatBase = eye; // the camera eye `origin` was built from, not a re-read
            sSohVRSeatBaseFrame = 0;
        }
    }
    // R16-A (FAL-B). `seatflips` counts the EDGES; this counts the FRAMES the
    // world was composed from the chase camera while a kart existed and was
    // being raced in first person. That is the artefact's own population: each
    // one seats the player at the camera's look-at point (ahead of the kart)
    // with the camera's heading (mid-corner, tens of degrees off the kart's),
    // and — before F1 — with the yaw follower snapping instead of easing.
    if (gSoh3DInPlay && sSohVRView == SOHVR_VIEW_FP && !sSohVRSeatFromKart) {
        gSohVRSeatFallbacks = gSohVRSeatFallbacks + 1;
    }

    // FIXED HORIZON + SPIN HOLD (trap A6) + R7 COCKPIT YAW SMOOTHING.
    //
    // Runs whenever there is a horizon to fix OR a kart yaw to smooth. Two
    // separate jobs share one follower:
    //   * the SPIN HOLD parks the follow rate at 0 while the game reports a
    //     genuine spin, and eases back over 0.45 s (trap A6);
    //   * the TIME CONSTANT stops the follower snapping to a 30 Hz engine
    //     quantity at 90-120 Hz. Third person and Diorama keep their exact
    //     shipped feel: tau is only armed when the yaw source is the kart.
    if (cfg->fixedHorizon || sSohVRSeatFromKart) {
        float yawNow = atan2f(fwd.x, fwd.z);
        double now = CACurrentMediaTime();
        float dt = (sSohVRLastWorldTime > 0.0) ? (float)(now - sSohVRLastWorldTime) : (1.0f / 90.0f);
        sSohVRLastWorldTime = now;
        if (dt < 0.0f || dt > 0.25f) {
            dt = 1.0f / 90.0f;
            sSohVRDtFalls++; // R14 item 5: a hitched frame, counted where it lands
        }
        if (!sSohVRHaveHeldYaw) {
            sSohVRHeldYaw = yawNow;
            sSohVRHaveHeldYaw = 1;
            sSohVRSpinBlend = 1.0f;
        }
        // R9 item 6 — "Realistic Spins (intense)". Default OFF, i.e. exactly the
        // behaviour above: the horizon is held through a spin and eased back.
        // With it ON the hold never engages, so the composed view follows the
        // kart all the way round a spin-out; the airborne somersault is composed
        // separately below (the spin hold could not produce it — a somersault is
        // pitch, and this filter only ever touched yaw).
        int spinning = cfg->fixedHorizon && !sSohVRRealisticSpins && (gSohVRKartSpin != 0);
        // R7 safety valve: a hold that never ends is exactly what a broken
        // cockpit lock feels like, so it cannot outlast a real spin.
        if (spinning) {
            sSohVRSpinHold += dt;
            if (sSohVRSpinHold > SOHVR_SPIN_HOLD_MAX) {
                spinning = 0;
            }
        } else {
            sSohVRSpinHold = 0.0f;
        }
        if (spinning && !sSohVRSpinLatched) {
            sSohVRSpinEvents++;
        }
        sSohVRSpinLatched = spinning;
        if (spinning) {
            sSohVRSpinBlend = 0.0f; // hold: the world does NOT follow the spin
        } else if (sSohVRSpinBlend < 1.0f) {
            sSohVRSpinBlend += dt / 0.45f; // ease back over ~0.45 s
            if (sSohVRSpinBlend > 1.0f) {
                sSohVRSpinBlend = 1.0f;
            }
        }
        // Follow the yaw at the blend rate; the shortest-arc delta keeps the
        // wrap at +/-pi from throwing the world a full turn. `alpha` is the
        // per-frame share of a first-order follower with time constant
        // SOHVR_YAW_TAU, and it is 1 (an exact snap, R6's behaviour) for every
        // mode whose yaw source is not the kart.
        // R16-A (F1 step 4): FIRST PERSON ALWAYS SMOOTHS, belt-and-braces.
        // `alpha` was 1 — an exact snap — on precisely the frames where the
        // seat source had just changed and `yawNow` had therefore jumped to a
        // DIFFERENT QUANTITY (the chase camera's heading instead of the
        // kart's). The follower was armed against exactly that and was
        // disarmed by exactly that. F1's seqlock removes the source of the
        // flip; this caps the damage of any future one at a few degrees.
        // Diorama and Third keep R6's exact snap feel, which is deliberate
        // there (their yaw source never changes underneath them).
        //
        // `vr set yawsnap 1` restores the 1.0.0.12 arming rule exactly, and it
        // is the RED CONTROL this step needed: the simulator enters the
        // kart-pose hole about once every fifteen seconds of racing, which is
        // far too rare to measure a distribution against, but `kartholefault`
        // can produce hundreds of seat drops on demand — and with the old
        // arming rule every one of them is an exact snap. Without this knob
        // "the follower eases" could only ever have been asserted against a
        // build that does not exist any more (trap D11).
        float alpha = 1.0f;
        if (sSohVRSeatFromKart || (sSohVRView == SOHVR_VIEW_FP && !gSohVRYawSnap)) {
            alpha = 1.0f - expf(-dt / SOHVR_YAW_TAU);
        }
        float d = sohvr_wrap_pi(yawNow - sSohVRHeldYaw);
        const float sohHeldWas = sSohVRHeldYaw;
        sSohVRHeldYaw = sohvr_wrap_pi(sSohVRHeldYaw + d * sSohVRSpinBlend * alpha);
        // R16-A (FAL-B): THE ARTEFACT AS A NUMBER. The largest single-frame
        // step the world's yaw took, in degrees, while racing in first person.
        // Ordinary cornering is bounded by the kart's own yaw rate times dt
        // (~180 deg/s * 11 ms ~ 2 deg); a seat-source snap is tens of degrees,
        // which is exactly what "the world violently turns in a flash of an
        // eye" is. Gated on in_play so a menu transition — where the snap is
        // deliberate — cannot pollute the number.
        if (gSoh3DInPlay && sSohVRView == SOHVR_VIEW_FP) {
            float sohStep = fabsf(sohvr_wrap_pi(sSohVRHeldYaw - sohHeldWas)) * 180.0f / (float)M_PI;
            if (sohStep > gSohVRWorldYawStepMax) {
                gSohVRWorldYawStepMax = sohStep;
            }
        }
        fwd = simd_make_float3(sinf(sSohVRHeldYaw), 0.0f, cosf(sSohVRHeldYaw));
        up = simd_make_float3(0, 1, 0);
        right = simd_normalize(simd_cross(fwd, up)); // 0045 convention
        up = simd_cross(right, fwd);
    } else {
        sSohVRHaveHeldYaw = 0;
        sSohVRSpinBlend = 1.0f;
    }

    // R8: the forward A is ACTUALLY built from, after the horizon/spin filter.
    // The drive asserts compare travel against this, not against the raw yaw.
    sSohVRWorldFwd = fwd;

    // R9 item 6 — THE SOMERSAULT, and it is deliberately downstream of the
    // assert forward above.
    //
    // the user wants "Realistic Spins (intense)" to tumble the view with the kart
    // when you get hit and go over. The somersault does not exist in
    // `player->rotation` (rotation[0] and rotation[2] are only ever zeroed for a
    // Player) — MK64 animates it as a SPRITE, so overlay 0054 exports the two
    // quantities the sprite is built from: `gSohVRKartTumble`, the tumble phase
    // (0..0x1FFF is one full revolution, the gKartTextureTumbles index), and
    // `gSohVRKartRollBam`, the composed lean/roll the kart billboard is drawn
    // with (driven by the real tumble angle unk_D9C while HIT_EFFECT is set).
    //
    // ROLL applies whenever the toggle is on — it is the kart's lean, and in the
    // seat you should feel it. PITCH applies only when the kart is airborne AND
    // hit, which is the somersault and nothing else: a plain hop must not
    // somersault the horizon (that mistake is 0051 rev3's cockpit-lock bug in a
    // different costume).
    //
    // Default OFF, and with it off not one line below executes, so R8's matrix
    // is bit-for-bit unchanged.
    sSohVRTumbleRollDeg = 0.0f;
    sSohVRTumblePitchDeg = 0.0f;
    if (sSohVRRealisticFlips && sSohVRSeatFromKart) {
        extern volatile int gSohVRKartRollBam, gSohVRKartTumble, gSohVRKartHitEffect;
        extern volatile int gSohVRKartTumbling;
        extern volatile int gSohVRKartAirborne;
        const float kBamToRad = (float)M_PI / 32768.0f;
        float roll = (float)gSohVRKartRollBam * kBamToRad;
        float pitch = 0.0f;
        // R10 item 5 — THE FLIP DID NOT WORK, and the gate was the reason.
        // rev1 asked for `airborne && HIT_EFFECT`, and HIT_EFFECT is a WALL
        // SCRAPE, not a shell hit — so the condition was essentially never
        // true during the very tumble it was written for. 0054 rev2 exports
        // `gSohVRKartTumbling`, which is exactly the set of effects in which
        // MK64 is advancing the tumble phase this pitch is built from. The
        // airborne bit is kept as a second condition ONLY as belt-and-braces
        // against a grounded tumble state: a plain hop still must not
        // somersault the horizon (0051 rev3's bug in a different costume),
        // and a tumble always leaves the ground.
        if (gSohVRKartTumbling && (gSohVRKartAirborne || gSohVRKartHitEffect)) {
            pitch = (float)gSohVRKartTumble * (2.0f * (float)M_PI) / 8192.0f;
        }
        sSohVRTumbleRollDeg = roll * 180.0f / (float)M_PI;
        sSohVRTumblePitchDeg = pitch * 180.0f / (float)M_PI;
        if (fabsf(roll) > 1e-4f || fabsf(pitch) > 1e-4f) {
            float cr = cosf(roll), sr = sinf(roll);
            simd_float3 r2 = right * cr + up * sr;   // roll about the kart forward
            simd_float3 u2 = up * cr - right * sr;
            float cp = cosf(pitch), sp = sinf(pitch);
            simd_float3 f3 = fwd * cp + u2 * sp;     // somersault about the right axis
            simd_float3 u3 = u2 * cp - fwd * sp;
            right = simd_normalize(r2);
            up = simd_normalize(u3);
            fwd = simd_normalize(f3);
        }
    }

    // Rotation: world delta -> local (x=right, y=up, z=-forward). Column j of a
    // column-vector matrix is the image of basis vector j, so column j carries
    // (right[j], up[j], -fwd[j]).
    simd_float4x4 rot;
    for (int j = 0; j < 3; j++)
        rot.columns[j] = simd_make_float4(right[j], up[j], -fwd[j], 0.0f);
    rot.columns[3] = simd_make_float4(0, 0, 0, 1);

    // R5: the seat point this A was built around, in GAME units. The pose dump
    // reports how far the composed head actually lands from it (`seat_err`),
    // which is the whole of device bug 1 expressed as one number: with the head
    // at the entry/recenter baseline it must be ~0, and every metre of
    // unaligned head offset shows up here as `scale` game units.
    sSohVRSeatGame = origin;
    {
        // R6 seat asserts. Both numbers are frame-invariant (they do not care
        // that the kart is moving) and both work on device.
        // NOTE (R7): `gaze_dot` below is close to TAUTOLOGICAL in first person
        // — it compares the fwd this function just built from the kart yaw
        // against that same kart yaw, so it can only ever fall below 1 through
        // the spin hold. The honest cockpit-lock measure is `cockpit_err` in
        // SohVR_ComposeEyes: the COMPOSED EYE's yaw (taken back into game space
        // through inverse(A), i.e. through the live head pose) against the
        // kart's. Read that one.
        if (kartValid) {
            simd_float3 kp = kartPos;
            sSohVRKartDist = simd_length(origin - kp);
            float kyaw = (float)kartYawBam * (float)M_PI / 32768.0f;
            if (sSohVRYawMirror) {
                kyaw = -kyaw;
            }
            simd_float3 kFwd = simd_make_float3(sinf(kyaw), 0.0f, cosf(kyaw));
            simd_float3 gaze = simd_make_float3(fwd.x, 0.0f, fwd.z);
            float gl = simd_length(gaze);
            sSohVRGazeDot = (gl > 1e-4f) ? simd_dot(gaze / gl, kFwd) : 0.0f;

            // R8: THE CONVENTION ASSERT, against ground truth that contains no
            // binary angle at all. gSoh3DCamFwd is normalize(camera->lookAt -
            // camera->pos) — two world-space positions, straight out of the
            // vectors guLookAt consumed (overlay 0045). MK64's racing camera
            // sits behind the kart and looks down its nose, so the forward we
            // BUILD from the yaw export must agree with it. A mirrored yaw
            // convention shows up here as twice the heading, and it cannot
            // cancel: nothing in this comparison ever reads a BAM.
            //
            // `camfwd_err_mirror` is the same angle computed with the yaw
            // mirrored, and it is the honest discriminating-power number: it
            // says how wrong the WRONG convention would look right now. Near a
            // heading of 0 or 180 degrees the mirror is a no-op and BOTH
            // numbers are ~0, which is exactly why R7's start-line asserts
            // could not have caught this. The suite drives until the mirror
            // number is large before believing the small one.
            {
                simd_float2 cf = simd_make_float2(gSoh3DCamFwd[0], gSoh3DCamFwd[2]);
                float cl = simd_length(cf);
                if (cl > 1e-4f) {
                    cf /= cl;
                    simd_float2 k2 = simd_make_float2(kFwd.x, kFwd.z);
                    simd_float2 km = simd_make_float2(-kFwd.x, kFwd.z);
                    const float kDeg = 180.0f / (float)M_PI;
                    sSohVRCamFwdErrDeg = atan2f(k2.x * cf.y - k2.y * cf.x, simd_dot(k2, cf)) * kDeg;
                    sSohVRCamFwdErrMirrorDeg = atan2f(km.x * cf.y - km.y * cf.x, simd_dot(km, cf)) * kDeg;
                } else {
                    sSohVRCamFwdErrDeg = 0.0f;
                    sSohVRCamFwdErrMirrorDeg = 0.0f;
                }
            }
        } else {
            sSohVRKartDist = -1.0f;
            sSohVRGazeDot = 0.0f;
            sSohVRCamFwdErrDeg = 0.0f;
            sSohVRCamFwdErrMirrorDeg = 0.0f;
        }
    }

    {
        // R6: keep the crash header's VR context fresh (one store per frame).
        extern volatile int gSohVRCrashCtxMode, gSohVRCrashCtxView, gSohVRCrashCtxDbg;
        extern volatile float gSohVRCrashCtxScale;
        gSohVRCrashCtxMode = sSohVRMode;
        gSohVRCrashCtxView = sSohVRView;
        gSohVRCrashCtxDbg = sSohVRDbgVr;
        gSohVRCrashCtxScale = sSohVRScale;
    }

    float inv = 1.0f / (sSohVRScale > 1e-3f ? sSohVRScale : 1.0f);
    simd_float4x4 a = simd_mul(rot, soh3d_translate(-origin.x, -origin.y, -origin.z));
    a = simd_mul(soh3d_scale(inv, inv, inv), a);
    a = simd_mul(soh3d_translate(0.0f, sSohVRHeight, -sSohVRDist), a);
    simd_float4x4 A = simd_mul(sSohVRAnchor, a);

    // R9 item 4 — THE HEAD-POSITION LEASH (and the death of the Recenter row).
    //
    // the user: take two steps in the room and you translate out of the kart —
    // the driver's viewpoint slides off the seat and only a manual Recenter
    // puts it back. A seated driver's head does not travel, so the fix is to
    // stop letting it.
    //
    // Trap B1 is the constraint and it is absolute: the submitted anchor is
    // always the TRUE device pose, and the pose V is built from is the same
    // object. Nothing here touches either. The compensation goes where every
    // comfort behaviour in this port goes — into A, the WORLD PLACEMENT. If the
    // head has moved by d from the baseline, translating the world by the same d
    // in ORIGIN space makes the eye's position relative to the world constant
    // again:  V·(T(d)·A)·p = R⁻¹·(A·p + d − h) = R⁻¹·(A·p − h₀) for d = h − h₀.
    // Head ROTATION is untouched — it lives in R and still composes exactly as
    // it always has, so look-behind and leaning your head to see round the
    // wheel are unaffected.
    //
    // It is a LEASH, not a rigid clamp. Inside SOHVR_HEADLOCK_DEADZONE the
    // compensation is zero, so ordinary head sway keeps its parallax (killing
    // ALL translational parallax reads as a world glued to your face, which is
    // its own kind of sick-making). Beyond it the excess is eased out over
    // SOHVR_HEADLOCK_TAU, so walking is cancelled smoothly rather than snapping.
    // The upshot is that the drift a Recenter used to fix now fixes itself, all
    // the time, without the player thinking about it — which is why the Recenter
    // ROW leaves the settings sheet this round. The bridge command stays, as a
    // diagnostic.
    if (sSohVRHeadLock && sSohVRView == SOHVR_VIEW_FP && sSohVRBaseValid) {
        double now = CACurrentMediaTime();
        float dt = (sSohVRHeadLockTime > 0.0) ? (float)(now - sSohVRHeadLockTime) : (1.0f / 90.0f);
        sSohVRHeadLockTime = now;
        if (!(dt > 0.0f && dt < 0.25f)) {
            dt = 1.0f / 90.0f;
            sSohVRDtFalls++; // R14 item 5: a hitched frame, counted where it lands
        }
        simd_float3 off = sSohVRHeadPose.columns[3].xyz - sSohVRBasePos;
        float len = simd_length(off);
        simd_float3 target = simd_make_float3(0, 0, 0);
        if (len > SOHVR_HEADLOCK_DEADZONE) {
            target = off * ((len - SOHVR_HEADLOCK_DEADZONE) / len);
        }
        float k = 1.0f - expf(-dt / SOHVR_HEADLOCK_TAU);
        sSohVRHeadLockComp += (target - sSohVRHeadLockComp) * k;
        sSohVRHeadLockDrift = len;
        A = simd_mul(soh3d_translate(sSohVRHeadLockComp.x, sSohVRHeadLockComp.y, sSohVRHeadLockComp.z), A);
    } else {
        sSohVRHeadLockComp = simd_make_float3(0, 0, 0);
        sSohVRHeadLockTime = 0.0;
        sSohVRHeadLockDrift = 0.0f;
    }
    return A;
}

// R8: project a GAME-SPACE point through the LIVE composed eye matrix — the
// same row-vector matrix Fast3D is handed for that eye, read back out of the
// same array. `vr project` only exercises P; this exercises P*V*A end to end,
// which is what an orientation assert has to do. Returns 0 behind the eye.
static int sohvr_project_game_point(int eye, simd_float3 p, float* ndc3, float* wOut) {
    if (eye < 0 || eye > 1) {
        return 0;
    }
    const float v[4] = { p.x, p.y, p.z, 1.0f };
    float clip[4] = { 0, 0, 0, 0 };
    for (int c = 0; c < 4; c++) {
        float s = 0.0f;
        for (int r = 0; r < 4; r++) {
            s += v[r] * sSohVREyeMtx[eye][r][c];
        }
        clip[c] = s;
    }
    if (wOut) {
        *wOut = clip[3];
    }
    if (!(clip[3] > 1e-6f) || !isfinite(clip[3])) {
        return 0; // behind the eye (or a non-finite matrix): no NDC exists
    }
    if (ndc3) {
        ndc3[0] = clip[0] / clip[3];
        ndc3[1] = clip[1] / clip[3];
        ndc3[2] = clip[2] / clip[3];
    }
    return 1;
}

// R14 item 1 — project a game-space DIRECTION through the live eye matrix and
// return its NDC y. Same array, same row-vector convention and same code shape
// as sohvr_project_game_point above; the ONLY difference is v[3] = 0, which is
// exactly what makes it a direction: the matrix's translation column never
// enters, so head POSITION (and therefore the user's height) cannot move the
// answer. Returns 0 when the direction is behind the eye or the matrix is not
// finite.
static int sohvr_project_game_dir_xy(int eye, simd_float3 d, float* ndcX, float* ndcY) {
    if (eye < 0 || eye > 1) {
        return 0;
    }
    const float v[4] = { d.x, d.y, d.z, 0.0f };
    float clip[4] = { 0, 0, 0, 0 };
    for (int c = 0; c < 4; c++) {
        float s = 0.0f;
        for (int r = 0; r < 4; r++) {
            s += v[r] * sSohVREyeMtx[eye][r][c];
        }
        clip[c] = s;
    }
    if (!(clip[3] > 1e-6f) || !isfinite(clip[3]) || !isfinite(clip[1]) || !isfinite(clip[0])) {
        return 0;
    }
    if (ndcX) {
        *ndcX = clip[0] / clip[3];
    }
    if (ndcY) {
        *ndcY = clip[1] / clip[3];
    }
    return 1;
}
static int sohvr_project_game_dir(int eye, simd_float3 d, float* ndcY) {
    return sohvr_project_game_dir_xy(eye, d, NULL, ndcY);
}

// R14 item 1 — the sky's per-eye ortho shift. Called once per composed frame,
// immediately after the eye matrices are written, with the composed eye's
// forward in GAME space.
//
//   target  = NDC y of the world horizon under this eye's matrix. The horizon
//             direction is the eye forward flattened to level: (fx, 0, fz)
//             normalised. Flattening is what makes it the HORIZON and not the
//             gaze — pitch the head and the direction is unchanged, so the
//             target moves down the screen by exactly the head's pitch, which
//             is the entire behaviour being asked for.
//   current = NDC y the game has already placed the sky's horizon at:
//             guOrtho(0,320,0,240) maps ob[1] -> 2*ob[1]/240 - 1, and MK64 puts
//             the horizon vertex at ob[1] = screen->cameraHeight (0058 exports
//             it). No convention, no fov, no degrees.
//
// Clamped to +/-8 NDC (four screen heights) so a straight-up gaze, where the
// horizon has no finite projection at all, degrades to "the whole view is the
// course's top sky colour" rather than to an infinity. 0058's cap quads are
// sized to cover the clamp.
#define SOHVR_SKY_SHIFT_CLAMP 8.0f
static simd_float3 sSohVRSkyDirLast = { 0.0f, 0.0f, 1.0f };
// R16-B: each eye's roll about its own forward relative to GAME up, written by
// the compose loop and published in the frame snapshot (step 4).
static float sSohVRSkyRollRad[2] = { 0.0f, 0.0f };

// ---------------------------------------------------------------------------
// R16-B — THE SPRITE PLACEMENT, IN ONE PLACE.
//
// This is the function 0051 consumes and the falsifier measures, and it exists
// as ONE function so the probe cannot drift from the consumer. R15's probe
// compared the sprite rate against a quantity the sprite rate was DERIVED from,
// so the two agreed by construction and the -0.06% it reported was arithmetic
// rather than evidence (the tautological-assert trap, and the reason five
// rounds of "green" never saw any of this).
//
// theta is the sprite's own `cameraRot`, in radians: MK64's eye yaw plus the
// sprite's authored rotY. For a cloud fixed in the world that quantity moves
// exactly opposite to the direction's angle off the heading — cameraRot =
// eyeYaw + rotY with rotY constant, while the off-heading angle is
// worldYaw - eyeYaw — which is why the falsifier below evaluates the sprite at
// -delta when it projects the world at +delta, and why the game's own mapping
// (screen x INCREASING with cameraRot) is the right sign to begin with.
//
// The answer is the eye-0 reference NDC; sohvr_sky_sprite_ndc_eye applies the
// per-eye affine 0044 applies in the eye pass.
static float sohvr_sky_sprite_ndc_ref(float thetaRad, int tangent) {
    const float span = (gSohVRSkySpan > 1e-4f) ? gSohVRSkySpan : 2.0f;
    if (tangent) {
        return (2.0f * tanf(thetaRad) - gSohVRSkyTanSum) / span;
    }
    // The 1.0.0.12 mapping, rebuilt from the SAME published parameters 0051
    // consumes: x_px = pxCenter + pxPerBam*bam, ndc = 2*x_px/320 - 1.
    const float bam = thetaRad * 32768.0f / (float)M_PI;
    const float px = gSohVRSkyPxCenter + gSohVRSkyPxPerBam * bam;
    return 2.0f * px / 320.0f - 1.0f;
}
static float sohvr_sky_sprite_ndc_eye(int eye, float thetaRad, int tangent) {
    const float ref = sohvr_sky_sprite_ndc_ref(thetaRad, tangent);
    if (!tangent) {
        // 1.0.0.12 applied NO per-eye term at all: one layout, both eyes. That
        // is M2, and reproducing it faithfully is what makes eye 1 fail the
        // falsifier at every offset including zero.
        return ref;
    }
    const int e = (eye == 1) ? 1 : 0;
    return gSohVRSkyEyeSx[e] * ref + gSohVRSkyEyeDx[e];
}

// The falsifier itself (clouds.md §6). For each offset from the heading, and
// for BOTH eyes: where the WORLD puts a direction at that offset (projected
// through the live composed eye matrix — the whole chain, trap D13), against
// where the SPRITE mapping puts a cloud that sits at that direction. Two paths
// that share no code. Results land in gSohVRSkyOff* for the `vr sky` dump.
#define SOHVR_SKY_OFF_N 7
static const float kSohVRSkyOffDeg[SOHVR_SKY_OFF_N] = { 0.0f, 15.0f, -15.0f, 30.0f, -30.0f, 45.0f, -45.0f };
static float sSohVRSkyOffWorld[2][SOHVR_SKY_OFF_N];
static float sSohVRSkyOffSprite[2][SOHVR_SKY_OFF_N];
static int sSohVRSkyOffOk[2][SOHVR_SKY_OFF_N];
static float sSohVRSkyOffMax[2] = { 0.0f, 0.0f };
static void sohvr_sky_offcentre_probe(simd_float3 dir, int tangent) {
    for (int e = 0; e < 2; e++) {
        sSohVRSkyOffMax[e] = 0.0f;
        for (int k = 0; k < SOHVR_SKY_OFF_N; k++) {
            const float a = kSohVRSkyOffDeg[k] * (float)M_PI / 180.0f;
            const float ca = cosf(a), sa = sinf(a);
            // The same rotation sohvr_update_sky_shift uses: it takes the
            // heading (sin y, 0, cos y) to (sin(y+a), 0, cos(y+a)), i.e. it
            // ADDS a to MK64's yaw. So this is a world direction `a` further
            // round than the heading.
            const simd_float3 d =
                simd_make_float3(dir.x * ca + dir.z * sa, 0.0f, -dir.x * sa + dir.z * ca);
            float wx = 0.0f;
            sSohVRSkyOffOk[e][k] = sohvr_project_game_dir_xy(e, d, &wx, NULL);
            sSohVRSkyOffWorld[e][k] = wx;
            sSohVRSkyOffSprite[e][k] = sohvr_sky_sprite_ndc_eye(e, -a, tangent);
            if (sSohVRSkyOffOk[e][k]) {
                const float err = fabsf(sSohVRSkyOffWorld[e][k] - sSohVRSkyOffSprite[e][k]);
                if (err > sSohVRSkyOffMax[e]) {
                    sSohVRSkyOffMax[e] = err;
                }
            }
        }
    }
}
static void sohvr_update_sky_shift(simd_float3 fwdGame) {
    extern volatile float gSohVRSkyShift[2];
    extern volatile int gSohVRSkyShiftValid;
    // R16-A (FAL-A2): stamp the pair with the compositor frame id it belongs
    // to. This compose will be published as sSohVRFrameId + 1 (the id is
    // incremented immediately after SohVR_ComposeEyes returns), so an eye pass
    // that reads the LIVE global can record which head pose it actually
    // consumed — and two eye passes half a frame apart record two different
    // ones. Wrap follows the publisher's rule: 0 means "nothing published".
    {
        unsigned int sohNextId = sSohVRFrameId + 1u;
        gSohVRSkyShiftId = (sohNextId == 0u) ? 1u : sohNextId;
    }
    extern volatile int gSohVRSkyCamHeight;
    simd_float2 flat = simd_make_float2(fwdGame.x, fwdGame.z);
    float fl = simd_length(flat);
    simd_float3 dir;
    if (fl > 1e-3f) {
        dir = simd_make_float3(flat.x / fl, 0.0f, flat.y / fl);
        sSohVRSkyDirLast = dir;
    } else {
        // Straight up or straight down: the horizontal forward is noise. Hold
        // the last good heading rather than letting the sky spin (the yaw
        // re-key has the same degeneracy and the same answer).
        dir = sSohVRSkyDirLast;
    }
    // R15 item 7's INDEPENDENT GROUND TRUTH. Two horizon directions two
    // degrees either side of the heading, projected through the LIVE eye matrix
    // (the whole chain, trap D13), give the WORLD's angular rate in NDC x per
    // degree at the centre of the frame. The sprites' rate is published
    // separately from the eye's frustum tangents and consumed by 0051; the two
    // paths share no code, so the suite can require them to AGREE — and with
    // `vr set skyrate 0` (the linear 1.7578125/fov mapping) it can require them
    // to DISAGREE first.
    {
        extern volatile float gSohVRSkyWorldNdcPerDeg;
        const float kD = 2.0f * (float)M_PI / 180.0f;
        float ca = cosf(kD), sa = sinf(kD);
        simd_float3 dA = simd_make_float3(dir.x * ca + dir.z * sa, 0.0f, -dir.x * sa + dir.z * ca);
        simd_float3 dB = simd_make_float3(dir.x * ca - dir.z * sa, 0.0f, dir.x * sa + dir.z * ca);
        float xa = 0.0f, xb = 0.0f;
        if (sohvr_project_game_dir_xy(0, dA, &xa, NULL) &&
            sohvr_project_game_dir_xy(0, dB, &xb, NULL)) {
            gSohVRSkyWorldNdcPerDeg = fabsf(xa - xb) / 4.0f;
        }
    }
    // R16-B's falsifier (clouds.md §6). R15's rate comparison above is a RATE,
    // at the CENTRE, of ONE eye, and it takes the absolute value — so it is
    // blind to the mapping's curvature (M1), to the other eye (M2) and to the
    // sign. This one is signed, off-centre and per eye, and it runs every
    // composed frame so `vr sky` can print the table on demand.
    sohvr_sky_offcentre_probe(dir, (gSohVRSkyTan && gSohVRSkyRate) ? 1 : 0);
    const float current = 2.0f * (float)gSohVRSkyCamHeight / 240.0f - 1.0f;
    // THE INVARIANT: BOTH eyes shift or NEITHER does. A per-eye validity would
    // let one eye take a fresh shift while the other took 0 (or a stale one) on
    // the same frame — the sky sitting at two different heights in the two eyes,
    // which is exactly the divergence a near-straight-up gaze can produce, since
    // the level horizon direction can fall behind one eye a frame before the
    // other. So the pair is computed into locals first and published only
    // together.
    float s[2] = { 0.0f, 0.0f };
    int allOk = 1;
    for (int e = 0; e < 2; e++) {
        float target = 0.0f;
        if (!sohvr_project_game_dir(e, dir, &target)) {
            allOk = 0;
            break;
        }
        float v = target - current;
        if (v > SOHVR_SKY_SHIFT_CLAMP) {
            v = SOHVR_SKY_SHIFT_CLAMP;
        } else if (v < -SOHVR_SKY_SHIFT_CLAMP) {
            v = -SOHVR_SKY_SHIFT_CLAMP;
        }
        s[e] = v;
    }
    if (allOk) {
        gSohVRSkyShift[0] = s[0];
        gSohVRSkyShift[1] = s[1];
        gSohVRSkyShiftValid = 1;
    }
    // else: hold the LAST GOOD pair (and the previous valid flag) untouched —
    // the same "hold last good" answer sSohVRSkyDirLast gives the degenerate
    // heading above, and the one the +/-8 clamp was sized for: a straight-up
    // gaze degrades to the held, clamped sky rather than snapping back to the
    // game's unshifted horizon in one eye. Before the first good frame the pair
    // is {0,0} with valid = 0, so the consumer simply does nothing.
}

int SohVR_ComposeEyes(void) {
    simd_float4x4 A = sohvr_world_matrix();
    // R5 ladder level 4: compose against the captured baseline, so the head
    // stops driving V at all (the world locks to the entry pose).
    simd_float4x4 originFromDevice = sohvr_dbg_on(4) ? sSohVRAnchor : sSohVRHeadPose;
    simd_float3x3 eye0Rot;
    // R16-B (M5 / step 4): GAME UP, expressed in origin space. A maps game ->
    // origin, so this is the direction the sky's screen-vertical axis is
    // supposed to be aligned with. Each eye's roll is the angle between it and
    // the eye's own up, about the eye's forward — the quantity nothing in the
    // sky path has ever had (the comfort filter levels the WORLD basis; head
    // roll stays live on the eye by design, trap B1).
    const simd_float3 sohUpGameInOrigin =
        simd_normalize(simd_mul(A, simd_make_float4(0.0f, 1.0f, 0.0f, 0.0f)).xyz);
    for (int e = 0; e < 2; e++) {
        // R5 ladder level 3: both eyes take eye 0's transform and eye 0's
        // frustum — a mono image in a stereo drawable. It keeps the IPD dump
        // honest (it reports what it composed) and isolates per-eye asymmetry.
        int eSrc = (sohvr_dbg_on(3) || sohvr_diag_off(SOHVR_DIAG_STEREO)) ? 0 : e;
        simd_float4x4 originFromEye = simd_mul(originFromDevice, sSohVREyeXform[eSrc]);
        sSohVREyePos[e] = originFromEye.columns[3].xyz;
        {
            // The eye's right and up, in origin space. Roll is measured in the
            // plane those two span, which is exactly the plane MK64's ortho sky
            // is drawn in — so the angle IS the rotation the sky would need.
            const simd_float3 sohR = originFromEye.columns[0].xyz;
            const simd_float3 sohU = originFromEye.columns[1].xyz;
            sSohVRSkyRollRad[e] = atan2f(simd_dot(sohUpGameInOrigin, sohR),
                                         simd_dot(sohUpGameInOrigin, sohU));
        }
        if (e == 0) {
            eye0Rot = simd_matrix(originFromEye.columns[0].xyz, originFromEye.columns[1].xyz,
                                  originFromEye.columns[2].xyz);
        }
        simd_float4x4 V = simd_inverse(originFromEye); // world -> eye
        simd_float4x4 P = sohvr_projection(eSrc);
        simd_float4x4 eyeVP = simd_mul(P, simd_mul(V, A));
        // Fast3D multiplies ROW vectors: hand it the transpose.
        simd_float4x4 rowMajor = simd_transpose(eyeVP);
        int bad = 0;
        for (int r = 0; r < 4; r++)
            for (int c = 0; c < 4; c++) {
                float v = rowMajor.columns[c][r];
                if (!isfinite(v)) {
                    bad = 1;
                }
                sSohVREyeMtx[e][r][c] = v;
            }
        if (bad) {
            // Log-only (scope D): never substitute a "safe" matrix — that would
            // hide the very frame the evidence needs.
            sSohVRBadMtx++;
            if (sSohVRBadMtx - sSohVRBadMtxLastSeq >= 90) { // ~1 s of frames
                sSohVRBadMtxLastSeq = sSohVRBadMtx;
                NSLog(@"[SohVR] NON-FINITE eye matrix (eye=%d count=%u view=%s scale=%.1f vrdbg=%d)", e,
                      sSohVRBadMtx, kSohVRViewName[sSohVRView], sSohVRScale, sSohVRDbgVr);
            }
        }
    }
    // IPD in EYE space: rotate the world-space eye separation into eye 0's
    // frame. Anything other than ~+0.063 on X is a convention bug (trap B3).
    simd_float3 dWorld = sSohVREyePos[1] - sSohVREyePos[0];
    sSohVRIpdDelta = simd_mul(simd_transpose(eye0Rot), dWorld);
    sSohVRComposed = 1;

    // --- the eye, expressed in GAME space (R2, trap A7 / trap D6) ------------
    // MK64 aims two whole families of things at the camera: positional
    // billboards (kart sprites face the camera POSITION —
    // player_controller.c's atan2s(pos - camera->pos)) and yaw-keyed
    // screen-space work (sBillBoardMtx and the sky's cloud/star sprites, both
    // keyed to camera->rot[1]). In VR the head owns neither, so both are
    // re-keyed to the COMPOSED EYE — derived from the very matrix the eyes
    // render with, which is trap A7's rule: never a second, separately
    // derived eye-facing.
    {
        extern volatile float gSohVREyePosGame[3];
        extern volatile int gSohVREyeYawBam;
        extern volatile float gSohVREyeFovDeg;
        simd_float4x4 Ainv = simd_inverse(A);
        simd_float3 headArkit = sSohVRHeadPose.columns[3].xyz;
        simd_float3 fwdArkit = -sSohVRHeadPose.columns[2].xyz;
        simd_float4 posGame4 = simd_mul(Ainv, simd_make_float4(headArkit, 1.0f));
        simd_float3 fwdGame = simd_mul(Ainv, simd_make_float4(fwdArkit, 0.0f)).xyz;
        float fl = simd_length(fwdGame);
        if (fl > 1e-6f) {
            fwdGame /= fl;
        }
        gSohVREyePosGame[0] = posGame4.x;
        gSohVREyePosGame[1] = posGame4.y;
        gSohVREyePosGame[2] = posGame4.z;
        sSohVRSeatErr = simd_length(posGame4.xyz - sSohVRSeatGame);
        // MK64's yaw convention: forward = (sins(yaw), *, coss(yaw)), and
        // atan2s(x, z) is its inverse. 65536 binary-angle units per turn.
        float yaw = atan2f(fwdGame.x, fwdGame.z);
        gSohVREyeYawBam = (int)(short)lrintf(yaw * 32768.0f / (float)M_PI);
        // R7 COCKPIT-LOCK TELEMETRY. This is the measurement the user's report
        // needed and R6 did not have: the composed eye's yaw comes back out of
        // the very matrix the eyes render with, so comparing it to the kart's
        // yaw asks "is my gaze pointed down the kart's forward?" and nothing
        // else. Neutral head + cockpit lock => 0 deg through any turn. Head
        // yawed +90 deg => +90 deg (the sign the eye-re-key suite line has
        // asserted green since R2 — never chosen by feel, trap B3).
        {
            int kYaw = 0;
            if (sohvr_kart_pose(NULL, &kYaw)) {
                sSohVRCockpitErrDeg =
                    (float)(short)(gSohVREyeYawBam - kYaw) * 180.0f / 32768.0f;
            } else {
                sSohVRCockpitErrDeg = 0.0f;
            }
        }
        // The eye's horizontal FOV, so the sky's yaw->screen-x mapping can be
        // rebuilt on the EYE's frustum instead of the game camera's.
        float tL = sSohVRTan[0][0], tR = sSohVRTan[0][1];
        float fov = (tR - tL > 1e-4f) ? (atanf(tR) - atanf(tL)) * 180.0f / (float)M_PI : 100.0f;
        gSohVREyeFovDeg = fov;
        // R15 item 7 — THE CLOUDS' ANGULAR RATE, which has been wrong since R3.
        //
        // the user, on 1.0.0.11: "the clouds move a lot as I move my head;
        // shouldn't they stay in the sky?" They should, and the reason they do
        // not is a LINEAR mapping standing in for a TANGENT one.
        //
        // MK64 places a cloud at x_px = 160 + (1.7578125 / fovDeg) * yawBam.
        // 1.7578125 * (65536/360) = 320, so that is exactly 320/fovDeg pixels
        // per degree: the whole 320-px screen spans fovDeg degrees, LINEARLY.
        // The world does not project that way — it projects through a tangent,
        // and its rate at the centre of the frame is 320/(tR - tL) px per
        // radian. R3 substituted the EYE's fov into the game's linear formula
        // and stopped there, so the two rates differ by
        // (tR - tL) / (2*tan(fov/2)) * ... — at a 100-degree eye fov the
        // sprites move about 36% FASTER than the scenery under head yaw. That
        // is a cloud sliding across the sky every time the user turns his head.
        //
        // The fix publishes the rate the EYE's own frustum implies, in the
        // units the sprite build consumes (pixels per BAM), plus the screen x
        // that a zero-yaw direction actually lands on — the frustum is
        // ASYMMETRIC on this device, so the centre of projection is not 160.
        //   x_ndc(theta) = 2*(tan(theta) - tL)/(tR - tL) - 1
        //   x_px         = 160 * (1 + x_ndc)
        //   dx_px/dtheta at 0 = 320/(tR - tL)   [radians]
        //   per BAM                            = (320/(tR-tL)) * pi/32768
        // gSohVRSkyRate is the A/B: 1 = shipping, 0 = the 1.0.0.11 linear
        // mapping, which is the red control the assert needs.
        {
            extern volatile float gSohVRSkyPxPerBam, gSohVRSkyPxCenter;
            float span = tR - tL;
            if (gSohVRSkyRate && span > 1e-4f) {
                gSohVRSkyPxPerBam = (320.0f / span) * ((float)M_PI / 32768.0f);
                gSohVRSkyPxCenter = 160.0f * (1.0f - (tR + tL) / span);
            } else {
                gSohVRSkyPxPerBam = 1.7578125f / ((fov > 1.0f) ? fov : 100.0f);
                gSohVRSkyPxCenter = 160.0f;
            }
        }
        // R16-B — THE MAPPING, not just its slope at one point (clouds.md M1),
        // AND THE OTHER EYE (M2). See the long note beside gSohVRSkyTanSum in
        // SohIosShell.m for what each of these is.
        //
        // The one sprite layout MK64 builds per game frame is built in eye 0's
        // frustum, exactly:   ndc = (2*tan(theta) - tanSum) / span
        // whose value and slope at theta = 0 are R15's published centre and
        // rate, so nothing that was right stops being right. Eye e's own NDC is
        // then a pure affine of eye 0's, because the two frustums differ only
        // in where they are CENTRED (and, in general, by a scale):
        //   ndc_e = (2*tan - (tL_e+tR_e))/span_e = sx*ndc_0 + dx
        //   sx = span_0/span_e,  dx = ((tL_0+tR_0) - (tL_e+tR_e))/span_e
        // On this device span_0 == span_e exactly (both eyes are 105 degrees,
        // mirror-imaged), so sx is 1 and dx is +/-0.536 — the whole of M2 is a
        // constant offset, and the fix in the eye pass is four lines.
        {
            const float span0 = tR - tL;
            if (span0 > 1e-4f) {
                gSohVRSkyTanSum = tL + tR;
                gSohVRSkySpan = span0;
                float ndcLo = 1.0e9f, ndcHi = -1.0e9f;
                for (int se = 0; se < 2; se++) {
                    const float tLe = sSohVRTan[se][0], tRe = sSohVRTan[se][1];
                    const float spanE = tRe - tLe;
                    if (!(spanE > 1e-4f)) {
                        gSohVRSkyEyeSx[se] = 1.0f;
                        gSohVRSkyEyeDx[se] = 0.0f;
                        continue;
                    }
                    gSohVRSkyEyeSx[se] = span0 / spanE;
                    gSohVRSkyEyeDx[se] = ((tL + tR) - (tLe + tRe)) / spanE;
                    // This eye sees eye-0 NDC in [(-1-dx)/sx, (1-dx)/sx].
                    const float a = (-1.0f - gSohVRSkyEyeDx[se]) / gSohVRSkyEyeSx[se];
                    const float b = (1.0f - gSohVRSkyEyeDx[se]) / gSohVRSkyEyeSx[se];
                    const float lo = (a < b) ? a : b, hi = (a < b) ? b : a;
                    if (lo < ndcLo) {
                        ndcLo = lo;
                    }
                    if (hi > ndcHi) {
                        ndcHi = hi;
                    }
                }
                // The UNION of the two eyes, plus a sprite half-width of margin
                // (0.2 NDC — a 64x32 cloud at MK64's authored scales is at most
                // ~48 of 320 px wide). Culling to one eye's range would drop a
                // sprite out of ONE eye, which is a stereo-rivalry bug of its
                // own; culling to the fov, as MK64 does, keeps sprites 17
                // degrees past the edge of a frustum that only reaches +45.
                if (ndcLo < ndcHi) {
                    gSohVRSkyTanLo = (span0 * (ndcLo - 0.2f) + (tL + tR)) * 0.5f;
                    gSohVRSkyTanHi = (span0 * (ndcHi + 0.2f) + (tL + tR)) * 0.5f;
                }
                gSohVRSkyRollRad[0] = sSohVRSkyRollRad[0];
                gSohVRSkyRollRad[1] = sSohVRSkyRollRad[1];
                const float spanY0 = sSohVRTan[0][3] - sSohVRTan[0][2];
                if (spanY0 > 1e-4f) {
                    gSohVRSkySpanY = spanY0;
                }
            }
        }
        // R13 item 3 — THE SKY'S PITCH, exported at last. Yaw has been re-keyed
        // since R2 and pitch never was: MK64 builds its horizon (and therefore
        // every cloud's Y, which is derived from the same screen->cameraHeight)
        // from the GAME chase camera, so looking up in the headset walked the
        // world past a sky that stayed exactly where it was. Both quantities
        // come out of the SAME composed forward the yaw above does — trap A7's
        // rule — and the VERTICAL half of sSohVRTan, which has been captured
        // since R0 and never once consumed.
        {
            extern volatile float gSohVREyePitchDeg, gSohVREyeVFovDeg;
            float fy = fwdGame.y;
            if (fy > 1.0f) {
                fy = 1.0f;
            } else if (fy < -1.0f) {
                fy = -1.0f;
            }
            gSohVREyePitchDeg = asinf(fy) * 180.0f / (float)M_PI;
            float tB = sSohVRTan[0][2], tT = sSohVRTan[0][3];
            float vfov = (tT - tB > 1e-4f) ? (atanf(tT) - atanf(tB)) * 180.0f / (float)M_PI : 90.0f;
            gSohVREyeVFovDeg = vfov;
        }
        // R14 item 1 — the sky's ortho shift, per eye, derived and not felt.
        // See the long note beside gSohVRSkyShift in SohIosShell.m. Two NDC y
        // values in the same clip space: where the world's horizon lands under
        // the live eye matrix, and where MK64 has already put the sky's. Their
        // difference is the shift. The horizon is submitted as a DIRECTION
        // (w = 0) — that is what makes the answer independent of head HEIGHT,
        // which is the half of the user's report a pitch formula could never have
        // been checked against.
        sohvr_update_sky_shift(fwdGame);
    }

    // --- R8: the drive asserts (independent ground truth) --------------------
    // Everything here comes from gSohVRKartVel (a world-space displacement out
    // of MK64's own physics) and from sSohVREyeMtx (the composed matrix the eye
    // renders with). No binary angle is read, so nothing can cancel.
    {
        extern volatile float gSohVRKartVel[3];
        extern volatile int gSohVRKartValid;
        simd_float3 kartPos;
        sSohVRDriveValid = 0;
        sSohVRKartSpeed = 0.0f;
        if (gSohVRKartValid && !sSohVRKartInject && sohvr_kart_pose(&kartPos, NULL)) {
            simd_float2 v = simd_make_float2(gSohVRKartVel[0], gSohVRKartVel[2]);
            float sp = simd_length(v);
            sSohVRKartSpeed = sp;
            // 0.5 units/frame is a crawl; below it the direction is noise.
            if (sp > 0.5f) {
                simd_float3 dir = simd_make_float3(v.x / sp, 0.0f, v.y / sp);
                simd_float3 f = simd_make_float3(sSohVRWorldFwd.x, 0.0f, sSohVRWorldFwd.z);
                float fl = simd_length(f);
                sSohVRDriveDot = (fl > 1e-4f) ? simd_dot(dir, f / fl) : 0.0f;
                simd_float3 target = kartPos + dir * 400.0f;
                target.y += sSohVRSeatUp; // level with the eye, not the tarmac
                float ndc[3], w;
                if (sohvr_project_game_point(0, target, ndc, &w)) {
                    sSohVRDriveNdcX = ndc[0];
                    sSohVRDriveW = w;
                    sSohVRDriveValid = 1;
                }
            }
        }
    }
    return 2;
}

// --- view modes: selection + per-mode state (spec D3) ---------------------
void SohVR_ApplySurroundings(void);
// Tentative declaration: the settings section below owns this flag, and
// SohVR_SetView needs to know whether the config has been read yet before it
// re-points the HUD sliders' scratch register at the new mode.
static int sSohVRSettingsLoaded;

int SohVR_GetView(void) {
    return sSohVRView;
}
const char* SohVR_GetViewName(void) {
    return kSohVRViewName[sSohVRView];
}
void SohVR_SetView(int view) {
    if (view < 0 || view >= SOHVR_VIEW_COUNT) {
        return;
    }
    int wasView = sSohVRView;
    sSohVRView = view;
    sSohVRHaveHeldYaw = 0; // re-seat the comfort filter on every mode change
    if (view == SOHVR_VIEW_FP) {
        sohvr_pin_fp_seat("enter first person"); // R18-B item 2
    }
    sSohVRSpinBlend = 1.0f;
    SohVR_ApplySurroundings();
    extern void SohVR_SettingsSave(void);
    SohVR_SettingsSave(); // the mode you left VR in is the mode you come back to
    if (wasView != view && sSohVRSettingsLoaded) {
        // R4: re-point the HUD sliders' scratch register at the mode you just
        // entered, so the three rows show ITS numbers rather than the ones you
        // were editing a moment ago in another mode.
        extern void CVarSetFloat(const char* name, float value);
        extern void CVarSetInteger(const char* name, int32_t value);
        extern void CVarSave(void);
        CVarSetFloat("gSohVR.HudDist", sSohVRCfg[view].hudDist);
        CVarSetFloat("gSohVR.HudHeight", sSohVRCfg[view].hudHeight);
        CVarSetFloat("gSohVR.HudScale", sSohVRCfg[view].hudScale);
        CVarSetInteger("gSohVR.HudScratchMode", view);
        CVarSave();
    }
}

// Surroundings are per-mode (spec D3) and R0 proved the style set switches
// live inside one space, so a view change re-applies it immediately.
void SohVR_ApplySurroundings(void) {
    extern void SohVR_SetFullImmersion(bool on);
    extern void SohVR_ApplyShowHands(bool on);
    if (sSohVRMode == 2) {
        SohVR_SetFullImmersion(sSohVRCfg[sSohVRView].fullImmersion ? true : false);
    }
    // R9b item 8: the space's upper-limb visibility follows the same path as
    // the surroundings style — pushed on entry and on every change.
    SohVR_ApplyShowHands(sSohVRShowHands ? true : false);
}
void SohVR_CycleView(void) {
    SohVR_SetView((sSohVRView + 1) % SOHVR_VIEW_COUNT);
}
void SohVR_SetSeat(float up, float fwd) {
    extern void SohVR_SettingsSave(void);
    if (up >= -200.0f && up <= 400.0f) {
        sSohVRSeatUp = up;
    }
    if (fwd >= -400.0f && fwd <= 400.0f) {
        sSohVRSeatFwd = fwd;
    }
    SohVR_SettingsSave(); // R7: the seat you tuned is the seat you come back to
}
void SohVR_SetThird(float up, float back) {
    if (up >= -200.0f && up <= 400.0f) {
        sSohVRThirdUp = up;
    }
    if (back >= -400.0f && back <= 800.0f) {
        sSohVRThirdBack = back;
    }
    // R9b: third person's pair is a persisted settings row now (item 2).
    extern void SohVR_SettingsSave(void);
    SohVR_SettingsSave();
}
void SohVR_GetThird(float* up, float* back) {
    if (up) {
        *up = sSohVRThirdUp;
    }
    if (back) {
        *back = sSohVRThirdBack;
    }
}
void SohVR_GetSeat(float* up, float* fwd) {
    if (up) {
        *up = sSohVRSeatUp;
    }
    if (fwd) {
        *fwd = sSohVRSeatFwd;
    }
}
void SohVR_SetFixedHorizon(int on) {
    extern void SohVR_SettingsSave(void);
    sSohVRCfg[sSohVRView].fixedHorizon = on ? 1 : 0;
    sSohVRHaveHeldYaw = 0;
    SohVR_SettingsSave();
}
void SohVR_SetDimLevel(float dim) {
    extern void SohVR_SettingsSave(void);
    sSohVRCfg[sSohVRView].dim = (dim < 0.0f) ? 0.0f : (dim > 1.0f) ? 1.0f : dim;
    SohVR_SettingsSave();
}
void SohVR_SetSkyMode(int on) {
    sSohVRCfg[sSohVRView].sky = on ? 1 : 0;
}
void SohVR_SetAlphaCoverage(int on) {
    sSohVRCfg[sSohVRView].alphaCov = on ? 1 : 0;
}
void SohVR_SetModeFullImmersion(int on) {
    sSohVRCfg[sSohVRView].fullImmersion = on ? 1 : 0;
    SohVR_ApplySurroundings();
}
// R9 item 6 — the toggle agent 2 wires into the settings sheet as
// "Realistic Spins (intense)". Global (not per-view): it is a comfort verdict
// about your stomach, not a property of a camera placement.
void SohVR_SetRealisticSpins(int on) {
    extern void SohVR_SettingsSave(void);
    sSohVRRealisticSpins = on ? 1 : 0;
    sSohVRHaveHeldYaw = 0; // the comfort follower re-seats on the change
    SohVR_SettingsSave();
}
int SohVR_GetRealisticSpins(void) {
    return sSohVRRealisticSpins;
}

// R10 item 5: the second row. OFF = the horizon never tumbles, which is
// exactly 1.0.0.6's behaviour bit for bit.
void SohVR_SetRealisticFlips(int on) {
    extern void SohVR_SettingsSave(void);
    sSohVRRealisticFlips = on ? 1 : 0;
    SohVR_SettingsSave();
}
int SohVR_GetRealisticFlips(void) {
    return sSohVRRealisticFlips;
}
// R9 item 4 — the head-position leash. Exposed for the bridge and for the
// settings sheet if agent 2 wants a row; ON is the shipping behaviour.
void SohVR_SetHeadLock(int on) {
    extern void SohVR_SettingsSave(void);
    sSohVRHeadLock = on ? 1 : 0;
    sSohVRHeadLockComp = simd_make_float3(0, 0, 0);
    sSohVRHeadLockTime = 0.0;
    SohVR_SettingsSave();
}
int SohVR_GetHeadLock(void) {
    return sSohVRHeadLock;
}
float SohVR_GetHeadLockDrift(void) {
    return sSohVRHeadLockDrift;
}
float SohVR_GetHeadLockComp(void) {
    return simd_length(sSohVRHeadLockComp);
}
// R9b item 8 — "Show Hands". The state lives here (spec D10: the VR module
// is the one source of truth and its CVars are the persistence), and the
// SwiftUI side owns the scene modifier that acts on it.
void SohVR_SetShowHands(int on) {
    extern void SohVR_SettingsSave(void);
    extern void SohVR_ApplyShowHands(bool on); // @_cdecl in SohVisionApp.swift
    sSohVRShowHands = on ? 1 : 0;
    SohVR_ApplyShowHands(sSohVRShowHands ? true : false);
    SohVR_SettingsSave();
}
int SohVR_GetShowHands(void) {
    return sSohVRShowHands;
}

// R9b item 2 — Diorama's "Height" row edits A's world height directly (it is
// already metres); first person and third person edit their own offsets.
float SohVR_GetHeightM(void) {
    return sSohVRHeight;
}
void SohVR_SetHeightM(float h) {
    extern void SohVR_SettingsSave(void);
    if (h >= -10.0f && h <= 10.0f) {
        sSohVRHeight = h;
        SohVR_SettingsSave();
    }
}

// R9b item 4 — the Reset button in the pinned "VR Settings" header. ONE call
// that puts every VR row back to the recorded default, including all three
// modes' Height/Zoom pairs (so a mode you are not currently in is reset too —
// the per-mode setters can only ever reach the active mode).
void SohVR_ResetVRDefaults(void) {
    extern void SohVR_SettingsSave(void);
    static const SohVRViewCfg kDefaults[SOHVR_VIEW_COUNT] = {
        /* diorama */ { SOHVR_DIO_SCALE0, 1.50f, SOHVR_DIO_HEIGHT0_M, 1.50f, SOHVR_HUD_HEIGHT0_DIO + SOHVR_HUD_DEFAULT_UP, 0.70f,
                        0.0f, 0, 0, 0, 0 },
        /* fp      */ { 8.0f, 0.00f, 0.00f, 1.40f, SOHVR_HUD_HEIGHT0_FP + SOHVR_HUD_DEFAULT_UP, 0.90f, 1.0f, 0, 1, 1, 1 },
        /* third   */ { 120.0f, 0.00f, 0.00f, 1.45f, SOHVR_HUD_HEIGHT0_THIRD + SOHVR_HUD_DEFAULT_UP, 0.85f, 1.0f, 0, 1, 1, 1 },
    };
    for (int m = 0; m < SOHVR_VIEW_COUNT; m++) {
        sSohVRCfg[m] = kDefaults[m];
    }
    sohvr_pin_fp_seat("reset"); // R18-B item 2: Reset lands on the pin too
    sSohVRThirdUp = SOHVR_THIRD_HEIGHT0_M * kDefaults[SOHVR_VIEW_THIRD].scale;
    sSohVRThirdBack = SOHVR_THIRD_ZOOM_DEFAULT_M * kDefaults[SOHVR_VIEW_THIRD].scale;
    // R11 item 4: the pane has no rows left to reset — one call puts it back.
    SohVR_PlacePane();
    sSohVRMirrorLeftHand = 0;
    sSohVRMirrorTop = 1;
    sSohVRMirrorTopOn = 1;
    {
        extern volatile int gSohVRJumboFeed;
        gSohVRJumboFeed = 1; // R20 item 1: Reset = the new-install default (On)
    }
    sSohVRRealisticSpins = 1; // R10 item 5: spin-out ON, flip-out OFF
    sSohVRRealisticFlips = 0;
    sSohVRHeadLock = 1;
    sSohVRFoveEnabled = 0;
    sSohVRRenderScale = 1.0f; // item 11: 100% stays the default
    sSohVRDbgVr = 0;
    SohVR_DiagResetAll(); // R10 item 2: Reset also puts every Diagnostics row back on
    sSohVRHaveHeldYaw = 0;
    sSohVRSpinBlend = 1.0f;
    SohVR_SetShowHands(0);
    SohVR_ApplySurroundings();
    SohVR_SettingsSave();
}

// R9b — the memory instruments, as page-readable numbers. The R9 retest opens
// with "are the rainbows gone at 100%?" and "does alloc_fails stay 0 / what is
// fb_mb?", and the user cannot type a bridge command in the headset.
float SohVR_GetFbMB(void) {
    extern volatile double gSohIosGfxFbBytes;
    return (float)(gSohIosGfxFbBytes / (1024.0 * 1024.0));
}
unsigned int SohVR_GetAllocFails(void) {
    extern volatile unsigned int gSohIosGfxAllocFails;
    return gSohIosGfxAllocFails;
}
// R11 item 1: the numbers the DEVICE reports back for the left-eye verdict.
// If eye_tag_miss[0] climbs while [1] stays 0, the bug is reproduced
// numerically — and the fix has to drive both to 0 on the user's next run.
unsigned int SohVR_GetEyeTagMiss(int e) {
    extern volatile unsigned int gSohVREyeTagMiss[2];
    return (e >= 0 && e <= 1) ? gSohVREyeTagMiss[e] : 0u;
}
unsigned int SohVR_GetEyeTagChecks(int e) {
    extern volatile unsigned int gSohVREyeTagChecks[2];
    return (e >= 0 && e <= 1) ? gSohVREyeTagChecks[e] : 0u;
}

unsigned int SohVR_GetSlotShown(void) {
    extern volatile unsigned int gSohIosGfxSlotWaitShown;
    return gSohIosGfxSlotWaitShown;
}

// R9 item 7: the eye-aspect diagnostic override (0 = off). Not persisted.
void SohVR_SetEyeAspectDbg(float ar) {
    sSohVREyeAspectDbg = (ar > 0.01f && ar < 10.0f) ? ar : 0.0f;
}
float SohVR_GetEyeAspectDbg(void) {
    return sSohVREyeAspectDbg;
}

#pragma mark - Crash-safe CVar stash (spec D10 / trap C4)

// A VR crash must never bake a VR override into the flat game's config. The
// shape is quake3e's D9: before VR overrides an ARCHIVED CVar, the original
// value is written to NSUserDefaults (not a static — a static dies with the
// process, which is exactly the case this protects against); a normal exit
// restores and clears it; a launch that finds a leftover stash knows the last
// session died with overrides live and restores them before anything reads
// them.
//
// INVENTORY, audited 2026-08-20 (R3): the VR path overrides *no* archived CVar
// today. Everything VR changes at runtime is either a shell static
// (per-mode view config, seat, planes) or a volatile global the engine reads
// (gSohVRSkyMode, gSohVREyeKey, gSohVRAngleCullOff, gSohVRWorldActive,
// gSohVRMirrorActive) — none of which is persisted. The two things that looked
// like candidates are not:
//   * 0047's internal-resolution pin is a PLATFORM-wide pin (every iOS/visionOS
//     frame, flat included), applied by the settings widget, not by VR.
//   * 0050's screen-fill skip is patch-gated on gSohVRWorldActive — no CVar.
// The mechanism ships anyway, with a self-test entry the suite drives end to
// end (override -> SIGKILL -> relaunch -> restored), because the first override
// a later round adds must land on a proven path, not a fresh one.
static NSString* const kSohVRStashKey = @"SohVR.CVarStash";

// --- R6: CVar writes are THREAD-CONFINED -------------------------------------
// The live device session died the instant `vr set vrdbg 6` was typed. That
// level is the one that writes an ARCHIVED CVar (`gInterpolationFPS`) through
// the stash — from the BRIDGE THREAD, mid-race. Overlay 0025 makes the CVar
// map itself safe, but the *consumers* are not: `gInterpolationFPS` sizes the
// `mtx_replacements` vector the interpolator is walking, and re-sizing that
// underneath a frame in flight is a use-after-free waiting to happen. The two
// spontaneous crashes the user reported are the same shape (a settings write
// landing mid-frame).
//
// The engine runs on the MAIN THREAD on this platform (SDL_main; see
// SohIos_ParkTick), so "the engine thread" is the main queue, and every VR
// CVar/config mutation now hops there. Already-on-main callers run inline so
// the settings rows keep their synchronous semantics.
static void sohvr_on_engine_thread(void (^work)(void)) {
    if (NSThread.isMainThread) {
        work();
    } else {
        dispatch_async(dispatch_get_main_queue(), work);
    }
}

static void sohvr_stash_record(const char* name, int isFloat) {
    NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary* stash = [([d dictionaryForKey:kSohVRStashKey] ?: @{}) mutableCopy];
    NSString* key = @(name);
    if (stash[key] != nil) {
        return; // already stashed this session — never overwrite the ORIGINAL
    }
    extern int32_t CVarGetInteger(const char* name, int32_t defaultValue);
    extern float CVarGetFloat(const char* name, float defaultValue);
    stash[key] = @{
        @"f" : @(isFloat),
        @"v" : isFloat ? @(CVarGetFloat(name, 0.0f)) : @(CVarGetInteger(name, 0))
    };
    [d setObject:stash forKey:kSohVRStashKey];
    [d synchronize]; // the whole point: survive a SIGKILL from here on
}

void SohVR_CVarOverrideInt(const char* name, int value) {
    NSString* n = @(name);
    sohvr_on_engine_thread(^{
        extern void CVarSetInteger(const char* name, int32_t value);
        sohvr_stash_record(n.UTF8String, 0);
        CVarSetInteger(n.UTF8String, value);
    });
}
void SohVR_CVarOverrideFloat(const char* name, float value) {
    NSString* n = @(name);
    sohvr_on_engine_thread(^{
        extern void CVarSetFloat(const char* name, float value);
        sohvr_stash_record(n.UTF8String, 1);
        CVarSetFloat(n.UTF8String, value);
    });
}

// Restore + clear. Used by BOTH the normal exit path and the launch recovery,
// so there is exactly one restore implementation. Returns how many entries it
// put back.
static int sohvr_stash_restore(const char* why) {
    NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
    NSDictionary* stash = [d dictionaryForKey:kSohVRStashKey];
    if (stash.count == 0) {
        return 0;
    }
    extern void CVarSetInteger(const char* name, int32_t value);
    extern void CVarSetFloat(const char* name, float value);
    extern void CVarSave(void);
    int n = 0;
    for (NSString* key in stash) {
        NSDictionary* e = stash[key];
        if (![e isKindOfClass:NSDictionary.class]) {
            continue;
        }
        if ([e[@"f"] intValue]) {
            CVarSetFloat(key.UTF8String, [e[@"v"] floatValue]);
        } else {
            CVarSetInteger(key.UTF8String, [e[@"v"] intValue]);
        }
        n++;
    }
    CVarSave();
    [d removeObjectForKey:kSohVRStashKey];
    [d synchronize];
    NSLog(@"[SohVR] cvar stash restored %d entr%s (%s)", n, n == 1 ? "y" : "ies", why);
    return n;
}

void SohVR_StashRestoreOnExit(void) {
    // R6: the restore writes CVars AND calls CVarSave() (a full config write).
    // Same thread confinement as the override that created the stash.
    sohvr_on_engine_thread(^{
        sohvr_stash_restore("vr-exit");
    });
}

// Called once at launch, from the shell's boot path, BEFORE the game can read
// the values. A non-empty stash here means the last session died (crash or
// swipe-kill) with VR overrides live.
static int sSohVRStashRecovered = -1;
void SohVR_StashRestoreOnLaunch(void) {
    sSohVRStashRecovered = sohvr_stash_restore("launch-recovery");
}
int SohVR_StashCount(void) {
    NSDictionary* stash = [NSUserDefaults.standardUserDefaults dictionaryForKey:kSohVRStashKey];
    return (int)stash.count;
}
int SohVR_StashRecoveredCount(void) {
    return sSohVRStashRecovered;
}

#pragma mark - Settings rows: the persisted backing store (spec D10)

// The per-mode config store R2 built is the LIVE state; these CVars are its
// persistence. Two directions, both explicit:
//   * SohVR_SettingsApply() — CVars -> config. Called at launch, on every VR
//     entry, and from the 0023 settings rows' callbacks.
//   * SohVR_SettingsSave()  — config -> CVars + CVarSave. Called by every
//     `vr set`/`vr view` mutation, so a tunable found in the headset is still
//     there after a restart without anyone having to remember to save.
// Defaults are the hardcoded table values, so a fresh install and a wiped
// config behave identically.
static int sSohVRSettingsLoaded = 0; // (declared tentatively above)

void SohVR_SettingsApply(void) {
    extern int32_t CVarGetInteger(const char* name, int32_t defaultValue);
    extern float CVarGetFloat(const char* name, float defaultValue);
    static const char* const kDimName[SOHVR_VIEW_COUNT] = { "gSohVR.Dim.Diorama", "gSohVR.Dim.Fp",
                                                            "gSohVR.Dim.Third" };
    int v = CVarGetInteger("gSohVR.ViewMode", SOHVR_VIEW_FP);
    if (v >= 0 && v < SOHVR_VIEW_COUNT) {
        sSohVRView = v;
    }
    for (int m = 0; m < SOHVR_VIEW_COUNT; m++) {
        float dim = CVarGetFloat(kDimName[m], sSohVRCfg[m].dim);
        sSohVRCfg[m].dim = (dim < 0.0f) ? 0.0f : (dim > 1.0f) ? 1.0f : dim;
    }
    sSohVRCfg[SOHVR_VIEW_FP].fixedHorizon = CVarGetInteger("gSohVR.FixedHorizon", 1) ? 1 : 0;
    sSohVRCfg[SOHVR_VIEW_THIRD].fixedHorizon = sSohVRCfg[SOHVR_VIEW_FP].fixedHorizon;
    // R14 item 3: "Top" replaces "Auto-show". A device that already carries
    // gSohVR.MirrorAuto is not migrated onto it — they mean different things
    // (one was "pop up on an item", one is "the pane is enabled") and trap D34
    // says a quiet migration reinstates a deleted feature. Top ships ON.
    sSohVRMirrorTop = CVarGetInteger("gSohVR.MirrorTop", 1) ? 1 : 0;
    sSohVRMirrorTopOn = sSohVRMirrorTop;
    {
        // R20 item 1's row is gone (R21 item 1): the feed is ALWAYS ON at
        // load. An archived Off from 1.0.1.19 is ignored, logged once, and
        // cleared so it cannot come back if the row ever does (trap D34).
        extern volatile int gSohVRJumboFeed;
        extern void CVarClear(const char* name);
        if (CVarGetInteger("gSohVR.JumbotronFeed", 1) == 0) {
            NSLog(@"[SohVR] R21: ignoring archived gSohVR.JumbotronFeed=0 (the row was removed; the jumbotron feed is always on) -- cleared");
        }
        CVarClear("gSohVR.JumbotronFeed");
        gSohVRJumboFeed = 1;
    }
    // R9: both new toggles. Realistic Spins DEFAULT OFF (off = the fixed-horizon
    // comfort hold); the head-position leash DEFAULT ON (it is what makes the
    // Recenter row unnecessary — see sohvr_world_matrix).
    sSohVRRealisticSpins = CVarGetInteger("gSohVR.RealisticSpins", 1) ? 1 : 0;
    sSohVRRealisticFlips = CVarGetInteger("gSohVR.RealisticFlips", 0) ? 1 : 0;
    sSohVRHeadLock = CVarGetInteger("gSohVR.HeadLock", 1) ? 1 : 0;
    // R9b item 8: hands OFF by default.
    sSohVRShowHands = CVarGetInteger("gSohVR.ShowHands", 0) ? 1 : 0;
    {
        // R9b item 2: third person's and Diorama's halves of the per-mode
        // Height/Zoom pair. First person's (SeatUp/SeatFwd) is loaded below —
        // it has persisted since R7. Diorama's "Zoom" IS its world scale
        // (sm64coopdx's diorama precedent); first person's scale is SETTLED at
        // the table's 8 u/m and deliberately has no CVar, so it can never drift
        // away from the seat numbers that were tuned at it.
        float v;
        v = CVarGetFloat("gSohVR.ThirdUp", sSohVRThirdUp);
        if (v >= -200.0f && v <= 400.0f) {
            sSohVRThirdUp = v;
        }
        v = CVarGetFloat("gSohVR.ThirdBack", sSohVRThirdBack);
        if (v >= -400.0f && v <= 800.0f) {
            sSohVRThirdBack = v;
        }
        v = CVarGetFloat("gSohVR.DioHeight", sSohVRCfg[SOHVR_VIEW_DIORAMA].height);
        if (v >= -10.0f && v <= 10.0f) {
            sSohVRCfg[SOHVR_VIEW_DIORAMA].height = v;
        }
        // R12 item 3: the persisted value is an ABSOLUTE world scale, so a
        // zoom tuned inside the new band survives the rescale literally. One
        // outside it is REMAPPED onto the nearest end rather than left where
        // it was: a live scale the slider cannot represent is exactly how a
        // Reset or a single nudge produces a jump the user did not ask for
        // (trap D34's cousin — an archived value outliving the range that
        // produced it). The R11 default of 500 lands on 320, which IS the new
        // -10 and is the value the user was looking at when he asked for this.
        v = CVarGetFloat("gSohVR.DioScale", sSohVRCfg[SOHVR_VIEW_DIORAMA].scale);
        if (v >= 5.0f && v <= 2000.0f) {
            sSohVRCfg[SOHVR_VIEW_DIORAMA].scale =
                (v < SOHVR_DIO_SCALE_MIN) ? SOHVR_DIO_SCALE_MIN
                                          : (v > SOHVR_DIO_SCALE_MAX) ? SOHVR_DIO_SCALE_MAX : v;
        }
    }
    // R11 item 4: the pane's Side/Height/Distance/Size are HARDCODED now, so
    // none of them load — and the four archived CVars from 1.0.0.7 are
    // deliberately ignored rather than migrated, because an archived value is
    // exactly what would resurrect the placement the user asked us to delete.
    sSohVRMirrorLeftHand = CVarGetInteger("gSohVR.MirrorLeftHand", sSohVRMirrorLeftHand) ? 1 : 0;
    SohVR_PlacePane();
    // R9 item 1c: foveated engine rendering. DEFAULT OFF this round — see
    // docs/VR-R9-NOTES.md section A.1c for why, in one line: the rainbow fix
    // and foveation both land in 0044's eye-framebuffer plumbing, and a build
    // where both changed at once cannot answer the question the user is
    // actually testing. `vr set foveation 1` turns it on in the headset.
    sSohVRFoveEnabled = CVarGetInteger("gSohVR.Foveation", 0) ? 1 : 0;
    {
        // R4, paying R3's debt (VR-R3-NOTES §12.2): the HUD plane is per mode
        // like every other tunable, so its PERSISTENCE is per mode too. R3 wrote
        // three shared CVars, which meant switching modes overwrote the values
        // of the mode you left — the live store was already per mode, only the
        // config was not.
        //
        // The per-mode names live under their OWN gSohVR.HudPlane.* subtree and
        // NOT under gSohVR.HudDist.*: LUS stores CVars as a flattened JSON
        // pointer tree, so a key that is a float ("gSohVR.HudDist", the widget
        // scratch below) and a key that is an object ("gSohVR.HudDist.fp")
        // cannot coexist — unflatten throws and the app aborts on the next
        // config write. Found the hard way, 2026-08-20.
        //
        // MIGRATION: the legacy shared names are read first and seed EVERY mode
        // that has no per-mode value of its own, so an existing config keeps the
        // numbers its owner tuned instead of snapping back to the table
        // defaults. Once each mode is saved the legacy names stop mattering;
        // they are never written again.
        //
        // R19 item 3 — "never written again" WAS FALSE: the scratch block below
        // writes these same three names (with gSohVR.HudScratchMode) on every
        // Apply. So on a fresh install the SECOND Apply read the first one's
        // scratch -- the CURRENT mode's value -- as a "legacy" config and seeded
        // every mode with no per-mode value from it: measured, a fresh install
        // archived third = fp's -0.075 m and diorama = fp's value clamped onto
        // its floor (0.10 m) instead of their own defaults (R18-B saw the same
        // leak as "third person's HUD row read 1"). A config that carries
        // HudScratchMode is past the migration by construction, so its shared
        // names are scratch, not legacy, and are not read here.
        const int sohLegacyHud = CVarGetInteger("gSohVR.HudScratchMode", -1) < 0;
        float ld = sohLegacyHud ? CVarGetFloat("gSohVR.HudDist", -1.0f) : -1.0f;
        float lh = sohLegacyHud ? CVarGetFloat("gSohVR.HudHeight", -999.0f) : -999.0f;
        float ls = sohLegacyHud ? CVarGetFloat("gSohVR.HudScale", -1.0f) : -1.0f;
        for (int m = 0; m < SOHVR_VIEW_COUNT; m++) {
            char n[64];
            float v;
            snprintf(n, sizeof(n), "gSohVR.HudPlane.Dist.%s", kSohVRViewName[m]);
            v = CVarGetFloat(n, (ld >= 0.3f && ld <= 20.0f) ? ld : sSohVRCfg[m].hudDist);
            if (v >= 0.3f && v <= 20.0f) {
                sSohVRCfg[m].hudDist = v;
            }
            snprintf(n, sizeof(n), "gSohVR.HudPlane.Height.%s", kSohVRViewName[m]);
            v = CVarGetFloat(n, (lh >= -5.0f && lh <= 5.0f) ? lh : sSohVRCfg[m].hudHeight);
            if (v >= -5.0f && v <= 5.0f) {
                // R13 item 7: the band moved, so a persisted absolute height can
                // now sit outside it. Preserve it literally when it fits (a
                // tuned value must survive an update) and clamp it onto the
                // nearest end when it does not — the same rule R12 used for the
                // Diorama zoom rescale, for the same reason: the slider and the
                // world must never be able to disagree.
                float h0 = sohvr_hud_height0(m);
                float lo = h0 - SOHVR_HUD_HEIGHT_DOWN, hi = h0 + SOHVR_HUD_HEIGHT_UP;
                sSohVRCfg[m].hudHeight = (v < lo) ? lo : (v > hi) ? hi : v;
            }
            snprintf(n, sizeof(n), "gSohVR.HudPlane.Scale.%s", kSohVRViewName[m]);
            v = CVarGetFloat(n, (ls >= 0.2f && ls <= 5.0f) ? ls : sSohVRCfg[m].hudScale);
            if (v >= 0.2f && v <= 5.0f) {
                sSohVRCfg[m].hudScale = v;
            }
        }
    }
    {
        // The three settings ROWS are still one set of sliders — "edit the mode
        // you are in", the same rule `vr set`'s aliases follow — so the shared
        // CVars stay as the widget's SCRATCH register. gSohVR.HudScratchMode
        // records which mode the scratch currently belongs to: if it matches,
        // the numbers in it are a slider edit and are adopted into that mode; if
        // it does not, they belong to a mode we have since left and are simply
        // overwritten. That is what makes nine per-mode values reachable through
        // three rows without the rows ever writing into the wrong mode.
        extern void CVarSetFloat(const char* name, float value);
        extern void CVarSetInteger(const char* name, int32_t value);
        int scratchMode = CVarGetInteger("gSohVR.HudScratchMode", -1);
        if (scratchMode == sSohVRView) {
            float hd = CVarGetFloat("gSohVR.HudDist", sSohVRCfg[sSohVRView].hudDist);
            float hh = CVarGetFloat("gSohVR.HudHeight", sSohVRCfg[sSohVRView].hudHeight);
            float hs = CVarGetFloat("gSohVR.HudScale", sSohVRCfg[sSohVRView].hudScale);
            if (hd >= 0.3f && hd <= 20.0f) {
                sSohVRCfg[sSohVRView].hudDist = hd;
            }
            if (hh >= -5.0f && hh <= 5.0f) {
                sSohVRCfg[sSohVRView].hudHeight = hh;
            }
            if (hs >= 0.2f && hs <= 5.0f) {
                sSohVRCfg[sSohVRView].hudScale = hs;
            }
        }
        CVarSetFloat("gSohVR.HudDist", sSohVRCfg[sSohVRView].hudDist);
        CVarSetFloat("gSohVR.HudHeight", sSohVRCfg[sSohVRView].hudHeight);
        CVarSetFloat("gSohVR.HudScale", sSohVRCfg[sSohVRView].hudScale);
        CVarSetInteger("gSohVR.HudScratchMode", sSohVRView);
    }
    {
        float rs = CVarGetFloat("gSohVR.EyeScale", sSohVRRenderScale);
        if (rs >= 0.25f && rs <= 2.0f) {
            sSohVRRenderScale = rs;
        }
    }
    {
        // R7: the seat persists. the user asked to "adjust the seat height and
        // forward" — a tuning he has to redo on every launch is not a tuning.
        float su = CVarGetFloat("gSohVR.SeatUp", sSohVRSeatUp);
        float sf = CVarGetFloat("gSohVR.SeatFwd", sSohVRSeatFwd);
        if (su >= -20.0f && su <= 80.0f) {
            sSohVRSeatUp = su;
        }
        if (sf >= -60.0f && sf <= 60.0f) {
            sSohVRSeatFwd = sf;
        }
        // R18-B item 2: ...and is then OVERRIDDEN. The first-person seat is
        // hardcoded now (Height -5 / Zoom +5); reading the archived pair first
        // is deliberate, so the pin's log line names what it threw away.
        sohvr_pin_fp_seat("settings load");
    }
    sSohVRSettingsLoaded = 1;
    SohVR_ApplySurroundings();
}

void SohVR_SettingsSave(void) {
    if (!sSohVRSettingsLoaded) {
        return; // never persist before the first load: that would write defaults
    }
    // R6 (the `vr set vrdbg 6` crash): this function ends in CVarSave(), a full
    // config serialise, and EVERY `vr set` / settings row calls it. Off the
    // engine thread that is a config write racing a frame. Hop first.
    if (!NSThread.isMainThread) {
        sohvr_on_engine_thread(^{
            SohVR_SettingsSave();
        });
        return;
    }
    extern void CVarSetInteger(const char* name, int32_t value);
    extern void CVarSetFloat(const char* name, float value);
    extern void CVarSave(void);
    static const char* const kDimName[SOHVR_VIEW_COUNT] = { "gSohVR.Dim.Diorama", "gSohVR.Dim.Fp",
                                                            "gSohVR.Dim.Third" };
    CVarSetInteger("gSohVR.ViewMode", sSohVRView);
    for (int m = 0; m < SOHVR_VIEW_COUNT; m++) {
        CVarSetFloat(kDimName[m], sSohVRCfg[m].dim);
    }
    CVarSetInteger("gSohVR.FixedHorizon", sSohVRCfg[SOHVR_VIEW_FP].fixedHorizon);
    CVarSetInteger("gSohVR.MirrorTop", sSohVRMirrorTop);
    // R21 item 1: gSohVR.JumbotronFeed is no longer written (session-only).
    CVarSetInteger("gSohVR.RealisticSpins", sSohVRRealisticSpins);
    CVarSetInteger("gSohVR.RealisticFlips", sSohVRRealisticFlips);
    CVarSetInteger("gSohVR.HeadLock", sSohVRHeadLock);
    CVarSetInteger("gSohVR.Foveation", sSohVRFoveEnabled);
    CVarSetInteger("gSohVR.ShowHands", sSohVRShowHands);
    // R9b: the other two thirds of the per-mode Height/Zoom pair, plus the
    // rear-view pane's placement.
    CVarSetFloat("gSohVR.ThirdUp", sSohVRThirdUp);
    CVarSetFloat("gSohVR.ThirdBack", sSohVRThirdBack);
    CVarSetFloat("gSohVR.DioHeight", sSohVRCfg[SOHVR_VIEW_DIORAMA].height);
    CVarSetFloat("gSohVR.DioScale", sSohVRCfg[SOHVR_VIEW_DIORAMA].scale);
    // R11 item 4: the pane's placement is furniture, not a setting — nothing
    // to archive. Only the "Left hand" row persists.
    CVarSetInteger("gSohVR.MirrorLeftHand", sSohVRMirrorLeftHand);
    // Per mode (R4): every mode's plane, every save — so switching modes can no
    // longer overwrite the mode you left. The legacy shared names are read for
    // migration in Apply and deliberately never written again.
    for (int m = 0; m < SOHVR_VIEW_COUNT; m++) {
        char n[64];
        snprintf(n, sizeof(n), "gSohVR.HudPlane.Dist.%s", kSohVRViewName[m]);
        CVarSetFloat(n, sSohVRCfg[m].hudDist);
        snprintf(n, sizeof(n), "gSohVR.HudPlane.Height.%s", kSohVRViewName[m]);
        CVarSetFloat(n, sSohVRCfg[m].hudHeight);
        snprintf(n, sizeof(n), "gSohVR.HudPlane.Scale.%s", kSohVRViewName[m]);
        CVarSetFloat(n, sSohVRCfg[m].hudScale);
    }
    CVarSetFloat("gSohVR.EyeScale", sSohVRRenderScale);
    CVarSetFloat("gSohVR.SeatUp", sSohVRSeatUp);
    CVarSetFloat("gSohVR.SeatFwd", sSohVRSeatFwd);
    CVarSave();
}

const float* SohVR_GetEyeMatrix(int eye) {
    if (eye != 1 && eye != 2)
        return NULL;
    return &sSohVREyeMtx[eye - 1][0][0];
}

// --- dumps ------------------------------------------------------------------
// One flat key=value line each; seq is written LAST (D11).

static char sSohVRPoseLine[2000];
static char sSohVRModeLine[3072];
static char sSohVRContractLine[1050];
static char sSohVRPacingLine[1100];
static char sSohVRProjLine[900];

const char* SohVR_DumpPose(void) {
    SohVR_ComposeEyes();
    float ipd = simd_length(sSohVRIpdDelta);
    int pass = (fabsf(sSohVRIpdDelta.x - 0.063f) <= 0.004f && fabsf(sSohVRIpdDelta.y) <= 0.004f &&
                fabsf(sSohVRIpdDelta.z) <= 0.004f);
    extern volatile float gSoh3DCamRight[3], gSoh3DCamFwd[3], gSoh3DCamEye[3];
    extern volatile float gSoh3DCamDist;
    extern volatile float gSohVRKartPos[3];
    extern volatile int gSohVRKartYawBam, gSohVRKartValid;
    snprintf(sSohVRPoseLine, sizeof(sSohVRPoseLine),
             "vr_pose injected=%d anchored=%d views=%d psrc=%s "
             "base_valid=%d base_pos=%.3f,%.3f,%.3f base_yaw=%.1f base_forced=%d base_rejects=%d "
             "rebase_req=%d recenters=%d vrdbg=%d seat_err=%.1f seat_game=%.1f,%.1f,%.1f "
             "seat_src=%s kart_valid=%d kart_pos=%.1f,%.1f,%.1f kart_yaw=%d kart_dist=%.1f gaze_dot=%.3f "
             "cockpit_err=%.2f kart_inject=%d spin_held_s=%.2f "
             "kart_speed=%.2f drive_valid=%d drive_dot=%.3f drive_ndcx=%.3f drive_w=%.1f yaw_mirror=%d "
             "camfwd_err=%.2f camfwd_err_mirror=%.2f "
             "head=%.4f,%.4f,%.4f eye0=%.4f,%.4f,%.4f eye1=%.4f,%.4f,%.4f "
             "ipd_eye_dx=%.5f ipd_eye_dy=%.5f ipd_eye_dz=%.5f ipd_len=%.5f ipd_check=%s "
             "cam_eye=%.1f,%.1f,%.1f cam_fwd=%.3f,%.3f,%.3f cam_right=%.3f,%.3f,%.3f cam_dist=%.1f "
             "scale=%.1f dist=%.2f height=%.2f "
             "eyeL_row0=%.5f,%.5f,%.5f,%.5f eyeL_row3=%.5f,%.5f,%.5f,%.5f "
             "eyeR_row0=%.5f,%.5f,%.5f,%.5f eyeR_row3=%.5f,%.5f,%.5f,%.5f seq=%u",
             sSohVRPoseInjected, sSohVRHaveAnchor, sSohVRViewCount,
             sSohVRContractValid ? "drawable" : "synthetic", sSohVRBaseValid, sSohVRBasePos.x,
             sSohVRBasePos.y, sSohVRBasePos.z, sSohVRBaseYawDeg, sSohVRBaseForced, sSohVRBaseRejects,
             sSohVRRebaseReq, sSohVRRecenters, sSohVRDbgVr, sSohVRSeatErr, sSohVRSeatGame.x,
             sSohVRSeatGame.y, sSohVRSeatGame.z, sSohVRSeatFromKart ? "kart" : "camera", gSohVRKartValid,
             gSohVRKartPos[0], gSohVRKartPos[1], gSohVRKartPos[2], gSohVRKartYawBam, sSohVRKartDist,
             sSohVRGazeDot, sSohVRCockpitErrDeg, sSohVRKartInject, sSohVRSpinHold,
             sSohVRKartSpeed, sSohVRDriveValid, sSohVRDriveDot, sSohVRDriveNdcX, sSohVRDriveW,
             sSohVRYawMirror,
             sSohVRCamFwdErrDeg, sSohVRCamFwdErrMirrorDeg,
             sSohVRHeadPose.columns[3].x,
             sSohVRHeadPose.columns[3].y, sSohVRHeadPose.columns[3].z, sSohVREyePos[0].x, sSohVREyePos[0].y,
             sSohVREyePos[0].z, sSohVREyePos[1].x, sSohVREyePos[1].y, sSohVREyePos[1].z, sSohVRIpdDelta.x,
             sSohVRIpdDelta.y, sSohVRIpdDelta.z, ipd, pass ? "PASS" : "FAIL", gSoh3DCamEye[0], gSoh3DCamEye[1],
             gSoh3DCamEye[2], gSoh3DCamFwd[0], gSoh3DCamFwd[1], gSoh3DCamFwd[2], gSoh3DCamRight[0],
             gSoh3DCamRight[1], gSoh3DCamRight[2], gSoh3DCamDist, sSohVRScale, sSohVRDist, sSohVRHeight,
             sSohVREyeMtx[0][0][0], sSohVREyeMtx[0][0][1], sSohVREyeMtx[0][0][2], sSohVREyeMtx[0][0][3],
             sSohVREyeMtx[0][3][0], sSohVREyeMtx[0][3][1], sSohVREyeMtx[0][3][2], sSohVREyeMtx[0][3][3],
             sSohVREyeMtx[1][0][0], sSohVREyeMtx[1][0][1], sSohVREyeMtx[1][0][2], sSohVREyeMtx[1][0][3],
             sSohVREyeMtx[1][3][0], sSohVREyeMtx[1][3][1], sSohVREyeMtx[1][3][2], sSohVREyeMtx[1][3][3],
             ++sSohVRSeq);
    return sSohVRPoseLine;
}

// R6: the RAW rebuilt per-eye projection, and the invariants it must satisfy.
//
// Why this dump exists. The R6 live-bridge pull read `eyeL_row0[0]` vs
// `eyeR_row0[0]` off `vr pose`, saw them differ under the device's asymmetric
// tangents, and concluded P00 differed between eyes. It does not: `eye*_row0`
// is a row of the COMPOSED world->clip matrix (P*V*A, transposed for Fast3D),
// whose [0] element is `P00*(VA)[0][0] + c2x*(VA)[2][0]` — and c2x is exactly
// the off-centre term, equal and opposite between the eyes. The two dumps are
// therefore SUPPOSED to differ by 2*c2x*(VA)[2][0]. (The arithmetic on the
// captured sample is in docs/VR-R6-NOTES.md; it closes to four decimals.)
//
// So `vr proj` prints P itself. If a future device pull wants to accuse the
// rebuild, it can read P directly instead of inferring it through A and V.
static int sohvr_proj_invariants(char* why, size_t cap) {
    simd_float4x4 p0 = sohvr_projection(0), p1 = sohvr_projection(1);
    float spanX0 = sSohVRTan[0][1] - sSohVRTan[0][0], spanX1 = sSohVRTan[1][1] - sSohVRTan[1][0];
    float spanY0 = sSohVRTan[0][3] - sSohVRTan[0][2], spanY1 = sSohVRTan[1][3] - sSohVRTan[1][2];
    int ok = 1;
    why[0] = '\0';
    // (a) equal tangent SPAN => equal scale terms, whatever the off-centre is.
    if (fabsf(spanX0 - spanX1) < 1e-3f && fabsf(p0.columns[0].x - p1.columns[0].x) > 1e-4f) {
        snprintf(why, cap, "p00_mismatch");
        ok = 0;
    } else if (fabsf(spanY0 - spanY1) < 1e-3f && fabsf(p0.columns[1].y - p1.columns[1].y) > 1e-4f) {
        snprintf(why, cap, "p11_mismatch");
        ok = 0;
    }
    // (b) the off-centre terms live ONLY in the z-row skew slots. Every other
    // slot that could absorb them must be exactly zero.
    const simd_float4x4* ps[2] = { &p0, &p1 };
    for (int e = 0; e < 2 && ok; e++) {
        const simd_float4x4* p = ps[e];
        if (p->columns[0].y != 0.0f || p->columns[0].z != 0.0f || p->columns[0].w != 0.0f ||
            p->columns[1].x != 0.0f || p->columns[1].z != 0.0f || p->columns[1].w != 0.0f ||
            p->columns[3].x != 0.0f || p->columns[3].y != 0.0f || p->columns[3].w != 0.0f) {
            snprintf(why, cap, "offcentre_leaked_eye%d", e);
            ok = 0;
        }
    }
    return ok;
}

const char* SohVR_DumpProj(void) {
    simd_float4x4 p0 = sohvr_projection(0), p1 = sohvr_projection(1);
    char why[48];
    int ok = sohvr_proj_invariants(why, sizeof(why));
    float c2x0 = p0.columns[2].x, c2x1 = p1.columns[2].x;
    snprintf(sSohVRProjLine, sizeof(sSohVRProjLine),
             "vr_proj contract=%d near=%.4f far=%.1f "
             "eye0_tan=%.4f,%.4f,%.4f,%.4f eye1_tan=%.4f,%.4f,%.4f,%.4f "
             "spanx0=%.4f spanx1=%.4f spany0=%.4f spany1=%.4f "
             "p00_e0=%.6f p00_e1=%.6f p11_e0=%.6f p11_e1=%.6f "
             "c2x_e0=%.6f c2x_e1=%.6f c2y_e0=%.6f c2y_e1=%.6f "
             "p22=%.6f p32=%.6f bad_mtx=%u invariants=%s%s%s seq=%u",
             sSohVRContractValid, sSohVRDepthNear, sohvr_engine_far(), sSohVRTan[0][0], sSohVRTan[0][1],
             sSohVRTan[0][2], sSohVRTan[0][3], sSohVRTan[1][0], sSohVRTan[1][1], sSohVRTan[1][2],
             sSohVRTan[1][3], sSohVRTan[0][1] - sSohVRTan[0][0], sSohVRTan[1][1] - sSohVRTan[1][0],
             sSohVRTan[0][3] - sSohVRTan[0][2], sSohVRTan[1][3] - sSohVRTan[1][2], p0.columns[0].x,
             p1.columns[0].x, p0.columns[1].y, p1.columns[1].y, c2x0, c2x1, p0.columns[2].y, p1.columns[2].y,
             p0.columns[2].z, p0.columns[3].z, sSohVRBadMtx, ok ? "PASS" : "FAIL", ok ? "" : ":",
             ok ? "" : why, ++sSohVRSeq);
    return sSohVRProjLine;
}

// Force a tangent set (the R6 device fixture) so the asymmetric-frustum
// asserts run headless in the simulator, where the runtime only ever reports
// a SYMMETRIC frustum — the exact blind spot that let this go five rounds
// without an assert. `off` restores whatever the drawable reported.
static int sSohVRTanForced = 0;
static float sSohVRTanSaved[2][4];
void SohVR_ForceTangents(int on, const float* eye0, const float* eye1) {
    if (on && !sSohVRTanForced) {
        memcpy(sSohVRTanSaved, sSohVRTan, sizeof(sSohVRTan));
    }
    if (on) {
        for (int i = 0; i < 4; i++) {
            sSohVRTan[0][i] = eye0[i];
            sSohVRTan[1][i] = eye1[i];
        }
        sSohVRTanForced = 1;
    } else if (sSohVRTanForced) {
        memcpy(sSohVRTan, sSohVRTanSaved, sizeof(sSohVRTan));
        sSohVRTanForced = 0;
    }
}

// R16-B — the off-centre falsifier, as one parseable line (clouds.md §6).
//
// For each offset from the heading and for BOTH eyes it reports the WORLD's NDC
// x (projected through the live composed eye matrix) and the SPRITE mapping's,
// computed by the same function 0051 consumes. Tokens are
// `o<eye>_<signed deg>=<world>,<sprite>,<err>` so the suite can read any single
// cell without parsing a table. `off_max` is the worst |world - sprite| per eye,
// which is the assert.
// R17-A item 1 — THE GHOST LINE. Everything the seat-interpolation argument
// rests on, as one sentence of numbers, measured in BOTH arms (trap D48).
//
//   ghost_jitter  the mean |second difference| of (interpolated game camera
//                 position - the seat this walk was composed with), in GAME
//                 units per walk. A second difference is zero for any constant
//                 velocity, so this is the ALTERNATING term and nothing else:
//                 a seat that steps once per game frame while the world glides
//                 in halves reads one whole game frame of travel here, and a
//                 seat interpolated along the same segment reads ~0.
//   ghost_step    the mean |first difference| -- how far the world moves per
//                 walk, i.e. the scale the jitter should be judged against.
//   walk_t        the interpolation factors the walks actually ran at. Two
//                 walks per game frame in VR means 0.50 and 1.00; if this reads
//                 1.00/1.00 the engine is walking once and there is no ghost
//                 to measure (`vr set vrdbg 6` does exactly that).
//   key_err       at the key-frame walk (t = 1) the camera position recovered
//                 from the display list MUST equal the one overlay 0045
//                 exported this game frame. If it does not, either t is not
//                 what this code thinks or the recovery is wrong, and every
//                 other number on the line is void. Reported, never assumed.
//   seat_lerps    walks the correction was actually applied on -- the "the fix
//                 is in the path" counter (trap D11).
static char sSohVRGhostLine[512];
const char* SohVR_DumpGhost(void) {
    extern volatile unsigned int gSohVRGhostN, gSohVRGhostKeyN, gSohVRSeatLerps, gSohVRSeatJumps;
    extern volatile unsigned int gSohVRSeatSeeds;
    extern volatile float gSohVRSeatSeedFault;
    extern volatile float gSohVRSeatDeltaMax, gSohVRSeatDxMax;
    extern volatile float gSohVRGhostJitter, gSohVRGhostJitterMax, gSohVRGhostStep;
    extern volatile float gSohVRGhostTMin, gSohVRGhostTMax, gSohVRGhostKeyErr;
    extern volatile float gSohVRSeatDx[3], gSohVRWalkT;
    extern volatile int gSohVRSeatInterp;
    snprintf(sSohVRGhostLine, sizeof(sSohVRGhostLine),
             "seatinterp=%d ghost_n=%u ghost_jitter=%.4f ghost_jitter_max=%.4f ghost_step=%.4f "
             "walk_t=%.3f,%.3f walk_t_now=%.3f key_err=%.4f key_n=%u "
             "seat_lerps=%u seat_dx=%.3f,%.3f,%.3f seat_src=%d seat_delta=%.3f,%.3f,%.3f "
             "seat_jumps=%u seat_seeds=%u seatseedfault=%.1f "
             "seat_delta_max=%.3f seat_dx_max=%.3f seq=%u",
             gSohVRSeatInterp, gSohVRGhostN, gSohVRGhostJitter, gSohVRGhostJitterMax,
             gSohVRGhostStep, gSohVRGhostTMin, gSohVRGhostTMax, gSohVRWalkT, gSohVRGhostKeyErr,
             gSohVRGhostKeyN, gSohVRSeatLerps, gSohVRSeatDx[0], gSohVRSeatDx[1], gSohVRSeatDx[2],
             sSohVRSeatFromKart, sSohVRSeatPrevDelta.x, sSohVRSeatPrevDelta.y, sSohVRSeatPrevDelta.z,
             gSohVRSeatJumps, gSohVRSeatSeeds, gSohVRSeatSeedFault,
             gSohVRSeatDeltaMax, gSohVRSeatDxMax, ++sSohVRSeq);
    return sSohVRGhostLine;
}

static char sSohVRSkyLine[2048];
const char* SohVR_DumpSky(void) {
    SohVR_ComposeEyes();
    int n = snprintf(sSohVRSkyLine, sizeof(sSohVRSkyLine),
                     "skytan=%d skyrate=%d skyroll=%.2f tansum=%.4f span=%.4f "
                     "dx=%.4f,%.4f sx=%.4f,%.4f tanlo=%.4f tanhi=%.4f "
                     "off_max=%.4f,%.4f lag_deg=%.2f lag_max=%.2f "
                     "affine=%u,%u,%u lag_corr=%u builds=%u builtyaw=%d snapyaw=%d",
                     gSohVRSkyTan, gSohVRSkyRate, gSohVRSkyRoll, gSohVRSkyTanSum, gSohVRSkySpan,
                     gSohVRSkyEyeDx[0], gSohVRSkyEyeDx[1], gSohVRSkyEyeSx[0], gSohVRSkyEyeSx[1],
                     gSohVRSkyTanLo, gSohVRSkyTanHi, sSohVRSkyOffMax[0], sSohVRSkyOffMax[1],
                     gSohVRSkyLagDeg, gSohVRSkyLagMaxDeg, gSohVRSkyAffine[0], gSohVRSkyAffine[1],
                     gSohVRSkyAffine[2], gSohVRSkyLagCorr, gSohVRSkyBuilds, gSohVRSkyBuiltYawBam,
                     gSohVRSnapEyeYawBam);
    // R17-B — THE DOME. The probe sprite's world DIRECTION is published by
    // 0051 in BOTH arms, from the authored rotY/mY alone, so the truth side of
    // this comparison is identical whichever sky is drawn (trap D48). The
    // shell projects it here through the LIVE composed eye matrix -- the whole
    // chain, trap D13 -- and 0044 reports where the PASS actually put the
    // sprite. dome_err is the difference; dome_jit is its mean second
    // difference across walks, which is the shake.
    {
        extern volatile int gSohVRSkyDome, gSohVRSkyProbeValid, gSohVRSkyProbeOrtho;
        extern volatile float gSohVRSkyDomeR, gSohVRSkyDomeRUsed;
        extern volatile float gSohVRSkyDomeEyeMax, gSohVRSkyDomeEyeFault;
        extern volatile int gSohVRSkyDomeFloorFault;
        extern volatile float gSohVRSkyProbeDir[3], gSohVRSkyProbePos[3];
        extern volatile float gSohVRSkyProbeAzDeg, gSohVRSkyProbeElDeg, gSohVRSkyProbeHalfDeg;
        extern volatile float gSohVRSkyWalkNdc[2][2], gSohVRSkyRefNdc[2][2];
        extern volatile float gSohVRSkyDomeErr[2], gSohVRSkyDomeErrMax[2], gSohVRSkyDomeJit[2];
        extern volatile unsigned int gSohVRSkyDomeJitN[2], gSohVRSkyWalks[3];
        extern volatile float gSohVRSkyUpDot[2], gSohVRSkyStereoNdc;
        extern volatile unsigned int gSohVRSkyDomeSprites, gSohVRSkyDomeFrames;
        float wnd[2] = { 9.0e9f, 9.0e9f };
        int wok[2] = { 0, 0 };
        const simd_float3 pd = simd_make_float3(gSohVRSkyProbeDir[0], gSohVRSkyProbeDir[1],
                                                gSohVRSkyProbeDir[2]);
        for (int e = 0; e < 2; e++) {
            float x = 0.0f;
            wok[e] = sohvr_project_game_dir_xy(e, pd, &x, NULL);
            wnd[e] = x;
        }
        n += snprintf(sSohVRSkyLine + n, sizeof(sSohVRSkyLine) - (size_t)n,
                      " dome=%d domer=%.0f domer_used=%.0f domer_eyemax=%.0f "
                      "domer_eyefault=%.0f domer_floorfault=%d dome_sprites=%u dome_frames=%u probe_ok=%d "
                      "probe_ortho=%d probe_az=%.2f probe_el=%.2f probe_half=%.3f "
                      "probe_dir=%.4f,%.4f,%.4f shell_ndc=%.4f,%.4f,%d%d "
                      "probe_pos=%.1f,%.1f,%.1f "
                      "walk_ndc=%.4f,%.4f/%.4f,%.4f ref_ndc=%.4f,%.4f/%.4f,%.4f dome_err=%.4f,%.4f "
                      "dome_errmax=%.4f,%.4f dome_jit=%.5f,%.5f dome_jitn=%u,%u "
                      "up_dot=%.4f,%.4f stereo_ndc=%.4f walks=%u,%u,%u",
                      gSohVRSkyDome, gSohVRSkyDomeR, gSohVRSkyDomeRUsed,
                      gSohVRSkyDomeEyeMax, gSohVRSkyDomeEyeFault, gSohVRSkyDomeFloorFault,
                      gSohVRSkyDomeSprites, gSohVRSkyDomeFrames,
                      gSohVRSkyProbeValid, gSohVRSkyProbeOrtho, gSohVRSkyProbeAzDeg,
                      gSohVRSkyProbeElDeg, gSohVRSkyProbeHalfDeg, gSohVRSkyProbeDir[0],
                      gSohVRSkyProbeDir[1], gSohVRSkyProbeDir[2], wnd[0], wnd[1], wok[0], wok[1],
                      gSohVRSkyProbePos[0], gSohVRSkyProbePos[1], gSohVRSkyProbePos[2],
                      gSohVRSkyWalkNdc[0][0], gSohVRSkyWalkNdc[0][1], gSohVRSkyWalkNdc[1][0],
                      gSohVRSkyWalkNdc[1][1], gSohVRSkyRefNdc[0][0], gSohVRSkyRefNdc[0][1],
                      gSohVRSkyRefNdc[1][0], gSohVRSkyRefNdc[1][1],
                      gSohVRSkyDomeErr[0], gSohVRSkyDomeErr[1],
                      gSohVRSkyDomeErrMax[0], gSohVRSkyDomeErrMax[1], gSohVRSkyDomeJit[0],
                      gSohVRSkyDomeJit[1], gSohVRSkyDomeJitN[0], gSohVRSkyDomeJitN[1],
                      gSohVRSkyUpDot[0], gSohVRSkyUpDot[1], gSohVRSkyStereoNdc,
                      gSohVRSkyWalks[0], gSohVRSkyWalks[1], gSohVRSkyWalks[2]);
    }
    for (int e = 0; e < 2 && n > 0 && n < (int)sizeof(sSohVRSkyLine); e++) {
        for (int k = 0; k < SOHVR_SKY_OFF_N && n < (int)sizeof(sSohVRSkyLine); k++) {
            n += snprintf(sSohVRSkyLine + n, sizeof(sSohVRSkyLine) - (size_t)n,
                          " o%d_%d=%.4f,%.4f,%.4f", e, (int)kSohVRSkyOffDeg[k],
                          sSohVRSkyOffWorld[e][k], sSohVRSkyOffSprite[e][k],
                          sSohVRSkyOffOk[e][k]
                              ? fabsf(sSohVRSkyOffWorld[e][k] - sSohVRSkyOffSprite[e][k])
                              : -1.0f);
        }
    }
    return sSohVRSkyLine;
}

// Project a point in EYE space through eye `e`'s rebuilt P and report clip/NDC.
// The suite uses it for the analytic check under asymmetric tangents: a point
// sitting exactly on the frustum's left edge must land at ndc.x = -1.
// R8: game space -> clip, through the LIVE composed eye matrix (P*V*A).
int SohVR_ProjectGamePoint(int e, float x, float y, float z, float* outNdcW) {
    SohVR_ComposeEyes();
    float ndc[3] = { 0, 0, 0 }, w = 0.0f;
    int ok = sohvr_project_game_point((e == 1) ? 1 : 0, simd_make_float3(x, y, z), ndc, &w);
    if (outNdcW) {
        outNdcW[0] = ndc[0];
        outNdcW[1] = ndc[1];
        outNdcW[2] = ndc[2];
        outNdcW[3] = w;
    }
    return ok;
}

void SohVR_ProjectEyePoint(int e, float x, float y, float z, float* outNdc) {
    simd_float4x4 p = sohvr_projection((e == 1) ? 1 : 0);
    simd_float4 c = simd_mul(p, simd_make_float4(x, y, z, 1.0f));
    float w = (fabsf(c.w) > 1e-9f) ? c.w : 1e-9f;
    outNdc[0] = c.x / w;
    outNdc[1] = c.y / w;
    outNdc[2] = c.z / w;
    outNdc[3] = c.w;
}

const char* SohVR_DumpMode(void) {
    extern int Soh_Get3DMode(void);
    extern volatile int gSoh3DPaused, gSoh3DInPlay;
    extern volatile int gSohVRWorldActive;
    extern volatile unsigned int gSoh3DEyeTag[2];
    extern volatile int gSohVRKartSpin, gSohVREyeKey, gSohVREyeYawBam;
    extern volatile int gSohVRKartAirborne;
    extern volatile int gSohVRSkyMode, gSohVRAngleCullOff;
    extern volatile int gSohVRRearSky;
    extern volatile int gSohVREyeTagOn, gSohVREyeTagFault;
    extern volatile unsigned int gSohVREyeTagMiss[2], gSohVREyeTagChecks[2];
    extern volatile unsigned int gSohVRInUseOverflow;
    extern volatile unsigned int gSohVREyeTagPostMiss[2], gSohVRBindDefer[4];
    extern volatile unsigned int gSoh3DEyeStamp[2];
    extern void* volatile gSoh3DEyeTexture[2];
    extern volatile int gSohVREngineOwnFix, gSohVRCompDelayMs, gSohVRCompHoldMs;
    extern volatile float gSohVREyePosGame[3], gSohVREyeFovDeg;
    extern void* volatile gSoh3DMirrorTexture;
    extern volatile int gSohVRMirrorW, gSohVRMirrorH;
    extern volatile unsigned int gSohVRRearItemSeq;
    // R13: the new telemetry (items 2a, 3, 5, 1d).
    extern volatile int gSohVRSkyCamHeight;
    extern volatile float gSohVREyePitchDeg, gSohVREyeVFovDeg, gSohVRSkyPitch;
    // R14 items 1 and 4.
    extern volatile float gSohVRSkyShift[2];
    extern volatile int gSohVRSkyShiftValid, gSohVRPadMask, gSohVRPadInject;
    extern volatile unsigned int gSohVRPadMasked;
    extern volatile unsigned int gSohVRHudEncodes, gSohVRHudLastGood, gSohVROwnSweeps;
    // R15 item 1.
    extern volatile int gSohVRPairFix, gSohVRStaleForce;
    // R15 items 3, 5, 7.
    extern volatile float gSohVRHudAlphaTop, gSohVRHudAlphaBot;
    extern volatile int gSohVRRearPivot, gSohVRRearSec, gSohVROwnKartRear, gSohVRRearAspect;
    extern volatile unsigned int gSohVRRearDlSwaps;
    extern volatile float gSohVRRearFlat, gSohVRRearGrey, gSohVRRearDiffRow, gSohVRRearDiffFrac;
    extern volatile float gSohVRRearDiffLo;
    extern volatile unsigned int gSohVRRearScans;
    extern volatile int gSohVRRearScanW, gSohVRRearScanH;
    extern volatile unsigned int gSohVRHudScans;
    extern volatile int gSohVRRearFloor, gSohVRSkyRate;
    extern volatile float gSohVRSkyPxPerBam, gSohVRSkyPxCenter, gSohVRSkyWorldNdcPerDeg;
    extern volatile unsigned int gSohVRPresentTag[2], gSohVREyeStale[2];
    extern volatile unsigned int gSohVRPairSplits, gSohVRPairForced, gSohVRPresentSplits;
    extern volatile int gSohIosGfxFbFailIn;
    // R17-A items 2a and 3.
    extern volatile unsigned int gSohVROwnBoostSkips, gSohVROwnReflSkips;
    extern volatile int gSohVRSkyWide, gSohVRSkyArFault, gSohVRSkyVtxL, gSohVRSkyVtxR;
    extern volatile float gSohVRSkyBuildAr;
    extern volatile unsigned int gSohVRSkySideQuads;
    extern int SohVR_StashCount(void);
    extern int SohVR_StashRecoveredCount(void);
    snprintf(sSohVRModeLine, sizeof(sSohVRModeLine),
             "vr_mode mode=%d reason=%s panel_mode=%d loop_running=%d loop_stop=%d "
             "eye_frames=%d,%d paused=%d in_play=%d anchored=%d injected=%d contract=%d "
             "world_active=%d world_reason=%s frames=%d world_frames=%d panel_frames=%d "
             "pose_id=%u shown_id=%u eye_tag=%u,%u pose_timeouts=%d "
             "view=%s view_id=%d dim=%.2f full=%d sky=%d horizon=%d alphacov=%d "
             "seat_up=%.1f seat_fwd=%.1f spin=%d airborne=%d cockpit_err=%.2f spin_hold=%d spin_blend=%.2f spin_events=%d "
             "eyekey=%d eye_yaw=%d eye_game=%.1f,%.1f,%.1f eye_fov=%.1f "
             "mirror=%d mirror_hold=%d mirror_top=%d mirror_shows=%d top_toggles=%d "
             "mirror_frames=%d mirror_tex=%d mirror_fb=%dx%d mirror_res=%.2f mirror_mirrored=%d "
             "mirror_x=%.2f mirror_y=%.2f mirror_dist=%.2f mirror_scale=%.2f rear_seq=%u "
             "third_up=%.1f third_back=%.1f stash=%d stash_recovered=%d "
             // R9b: the settings-restructure state, so the suite can assert the
             // per-mode Height/Zoom pair, the two new toggles and the scale
             // that no longer has a slider.
             "scale=%.1f height=%.2f spins=%d flips=%d hud_height=%.2f hands=%d headlock=%d rscale=%.2f "
             "base_valid=%d recenters=%d vrdbg=%d fp_opaque=%d diag=0x%03x sky_live=%d anglecull_off=%d "
             // R11: the pane's new state and the R11 A/B controls.
             "lefthand=%d rearsky=%d eyetag=%d eyetagfault=%d "
             "eye_tag_miss=%u/%u eye_tag_checks=%u/%u inuse_overflow=%u "
             // R12 item 1: the late-read breakdown, the bind refusals (the
             // producer reservation actually firing) and the two stress knobs,
             // so a suite line can state the CONDITIONS it measured under.
             "eye_tag_post_miss=%u/%u bind_defer=%u/%u eye_stamp=%u,%u eye_tex=%p,%p ownfix=%d compdelay=%d comphold=%d "
             // R13: the HUD's own visibility numbers (item 2), the pane's
             // per-branch draw counters (item 5) and the sky's pitch pair
             // (item 3). Every one of these exists because the round found a
             // failure that had NO number attached to it.
             "hud_defer=%u hud_encodes=%u hud_lastgood=%u own_sweeps=%u "
             "mirror_placement=%d pane_hud=%u pane_lefthand=%u pane_wrist=%u pane_drops=%u "
             "pane_deconflict=%d lefthand_live=%d "
             // R14: the sky's world-lock, stated as the two NDC y values it is
             // the difference of (item 1), and the VR pad mask (item 4).
             "cam_height=%d eye_pitch=%.1f eye_vfov=%.1f skypitch=%.2f "
             "sky_ndc_cur=%.3f sky_ndc_tgt=%.3f sky_shift=%.3f,%.3f sky_shift_ok=%d "
             "cmask=%d cmasked=%u cinject=0x%04x diagui=%d "
             // R14 item 2: the pane/HUD stack, as the two numbers that decide it.
             "hud_ctop=%.3f pane_bottom=%.3f "
             // R15 item 1: the pair rule's numbers. present_tag is the POSE TAG
             // each eye's presented image was rendered for; the suite asserts
             // the two are EQUAL under stress, which is the whole invariant.
             "pairfix=%d staleforce=%d present_tag=%u,%u eye_stale=%u,%u "
             "pair_splits=%u pair_forced=%u present_splits=%u "
             // R15 item 3: the HUD's own alpha, so the content-top constant is
             // a measurement. item 5: the pane's ground fill. item 7: the
             // clouds' angular rate, published and measured, by two paths.
             "hud_ctop_k=%.4f hud_alpha_top=%.4f hud_alpha_bot=%.4f hud_scans=%u pane_gap=%.3f "
             "rearfloor=%d skyrate=%d sky_pxbam=%.6f sky_pxcenter=%.1f "
             "sky_sprite_ndc_deg=%.5f sky_world_ndc_deg=%.5f "
             // R16-A: the blank eye (the one-eyed failure present_splits
             // cannot see), the mono frame that replaces it, the atomic
             // publication A/B and its orphan bound, the producer-gap
             // injection, and the sky shift's per-eye latch tags.
             "eye_blank=%u,%u eye_mono=%u eyepub=%d eyepubhold=%d pub_orphans=%u pairhold=%d "
             "skylatch=%d sky_shift_tag=%u,%u sky_tag_skew=%u kartholefault=%d yawsnap=%d "
             // R16-B: the clouds' knobs and the pose gap that survived R16-A's
             // latch, in degrees. sky_off_max is the falsifier's worst
             // world-vs-sprite disagreement over +/-45 degrees, per eye.
             "skytan=%d skyroll=%.2f sky_lag_deg=%.2f sky_lag_max=%.2f "
             "sky_off_max=%.4f,%.4f sky_affine=%u,%u,%u sky_lag_corr=%u "
             // R16-A F1: the kart snapshot's own health — how old the worst
             // snapshot the seat accepted was, how often the seqlock made the
             // reader go round again, and the bound both are judged against.
             "kart_age_max=%u kart_retries=%u kart_stale_k=%u "
             // R16-A F4: the frame snapshot the engine last latched — its id
             // (which is the eye matrices' own pose tag) and how many times it
             // has been latched, so a suite line can prove the rendezvous is
             // running rather than assuming it.
             "snap_id=%u snap_latches=%u "
             // R16-C: the rear pane's knobs, its section-list override counter
             // and the framebuffer scan (falsifiers F2/F3).
             "rearpivot=%d rearsec=%d rearownkart=%d rearaspect=%d rear_dl_swaps=%u "
             "rear_scan_fb=%dx%d rear_scans=%u rear_flat=%.4f rear_grey=%.4f "
             "rear_diff_row=%.4f rear_diff_frac=%.5f rear_diff_lo=%.5f rear_age_max=%u rear_retries=%u "
             // R17-A item 2a: the two OTHER emitters of the local kart's quad,
             // suppressed in first person. item 3: where the sky gradient's
             // lateral edges landed, the aspect the game computed them at, and
             // the two controls -- 160 -/+ 120*AR is below 0 and above 320 for
             // anything wider than 4:3 and INSIDE them for anything narrower,
             // which is the whole of the rear pane's black strips.
             "own_boost_skips=%u own_refl_skips=%u "
             "skywide=%d skyarfault=%d sky_vtx_l=%d sky_vtx_r=%d sky_build_ar=%.4f sky_sides=%u "
             "fbfail=%d seq=%u",
             sSohVRMode, sSohVRModeReason, Soh_Get3DMode(), gSoh3DRunning, gSoh3DStop, Soh3D_GetEyeFrames(1),
             Soh3D_GetEyeFrames(2), gSoh3DPaused, gSoh3DInPlay, sSohVRHaveAnchor, sSohVRPoseInjected,
             sSohVRContractValid, gSohVRWorldActive, sSohVRWorldReason, sSohVRLoopFrames,
             sSohVRLoopWorldFrames, sSohVRLoopPanelFrames, sSohVRFrameId, sSohVRLastSubmittedId,
             gSoh3DEyeTag[0], gSoh3DEyeTag[1], sSohVRTimeouts, kSohVRViewName[sSohVRView], sSohVRView,
             sSohVRCfg[sSohVRView].dim, sSohVRCfg[sSohVRView].fullImmersion, sSohVRCfg[sSohVRView].sky,
             sSohVRCfg[sSohVRView].fixedHorizon, sSohVRCfg[sSohVRView].alphaCov, sSohVRSeatUp, sSohVRSeatFwd,
             gSohVRKartSpin, gSohVRKartAirborne, sSohVRCockpitErrDeg, sSohVRSpinLatched, sSohVRSpinBlend,
             sSohVRSpinEvents, gSohVREyeKey,
             gSohVREyeYawBam, gSohVREyePosGame[0], gSohVREyePosGame[1], gSohVREyePosGame[2],
             gSohVREyeFovDeg, sSohVRMirrorVisible, sSohVRMirrorHold, sSohVRMirrorTop, sSohVRMirrorShows,
             sSohVRTopToggles, sSohVRMirrorFrames, (int)(gSoh3DMirrorTexture != NULL), gSohVRMirrorW,
             gSohVRMirrorH, sSohVRMirrorRes, sSohVRMirrorMirrored, sSohVRMirrorX, sSohVRMirrorY,
             sSohVRMirrorDist, sSohVRMirrorScale, gSohVRRearItemSeq, sSohVRThirdUp, sSohVRThirdBack,
             SohVR_StashCount(), SohVR_StashRecoveredCount(),
             sSohVRScale, sSohVRHeight, sSohVRRealisticSpins, sSohVRRealisticFlips, sSohVRHudHeight,
             sSohVRShowHands, sSohVRHeadLock,
             sSohVRRenderScale, sSohVRBaseValid, sSohVRRecenters, sSohVRDbgVr, sSohVRFpOpaque,
             sSohVRDiagOff,
             gSohVRSkyMode, gSohVRAngleCullOff, sSohVRMirrorLeftHand, gSohVRRearSky, gSohVREyeTagOn,
             gSohVREyeTagFault, gSohVREyeTagMiss[0], gSohVREyeTagMiss[1], gSohVREyeTagChecks[0],
             gSohVREyeTagChecks[1], gSohVRInUseOverflow, gSohVREyeTagPostMiss[0],
             gSohVREyeTagPostMiss[1], gSohVRBindDefer[0], gSohVRBindDefer[1], gSoh3DEyeStamp[0],
             gSoh3DEyeStamp[1], (void*)gSoh3DEyeTexture[0], (void*)gSoh3DEyeTexture[1],
             gSohVREngineOwnFix,
             gSohVRCompDelayMs, gSohVRCompHoldMs,
             gSohVRBindDefer[2], gSohVRHudEncodes, gSohVRHudLastGood, gSohVROwnSweeps,
             sSohVRPanePlacement, sSohVRPaneDraws[SOHVR_PANE_HUD],
             sSohVRPaneDraws[SOHVR_PANE_LEFTHAND], sSohVRPaneDraws[SOHVR_PANE_WRIST],
             sSohVRPaneDrops, sSohVRPaneDeconflicted, sSohVRLeftHandLive,
             gSohVRSkyCamHeight, gSohVREyePitchDeg, gSohVREyeVFovDeg, gSohVRSkyPitch,
             2.0f * (float)gSohVRSkyCamHeight / 240.0f - 1.0f,
             (2.0f * (float)gSohVRSkyCamHeight / 240.0f - 1.0f) + gSohVRSkyShift[0],
             gSohVRSkyShift[0], gSohVRSkyShift[1], gSohVRSkyShiftValid,
             gSohVRPadMask, gSohVRPadMasked, gSohVRPadInject, sSohVRDiagUI,
             sohvr_hud_content_top(), sohvr_pane_bottom(),
             gSohVRPairFix, gSohVRStaleForce, gSohVRPresentTag[0], gSohVRPresentTag[1],
             gSohVREyeStale[0], gSohVREyeStale[1], gSohVRPairSplits, gSohVRPairForced,
             gSohVRPresentSplits, sSohVRHudCTop, gSohVRHudAlphaTop, gSohVRHudAlphaBot, gSohVRHudScans,
             sohvr_pane_bottom() - sohvr_hud_content_top(), gSohVRRearFloor, gSohVRSkyRate,
             gSohVRSkyPxPerBam, gSohVRSkyPxCenter,
             2.0f * gSohVRSkyPxPerBam * 182.0444f / 320.0f, gSohVRSkyWorldNdcPerDeg,
             gSohVREyeBlank[0], gSohVREyeBlank[1], gSohVREyeMono, gSohVREyePubAtomic,
             gSohVREyePubHoldMs, gSohVRPubOrphans, gSohVRPairHold, gSohVRSkyLatch,
             gSohVRSkyShiftTag[0], gSohVRSkyShiftTag[1], gSohVRSkyTagSkew, gSohVRKartHoleFault,
             gSohVRYawSnap, gSohVRSkyTan, gSohVRSkyRoll, gSohVRSkyLagDeg, gSohVRSkyLagMaxDeg,
             sSohVRSkyOffMax[0], sSohVRSkyOffMax[1], gSohVRSkyAffine[0], gSohVRSkyAffine[1],
             gSohVRSkyAffine[2], gSohVRSkyLagCorr,
             sSohVRKartAgeMax, sSohVRKartRetries, SOHVR_KART_STALE_FRAMES,
             gSohVRSnapId, gSohVRSnapLatches,
             gSohVRRearPivot, gSohVRRearSec, gSohVROwnKartRear, gSohVRRearAspect, gSohVRRearDlSwaps,
             gSohVRRearScanW, gSohVRRearScanH, gSohVRRearScans, gSohVRRearFlat, gSohVRRearGrey,
             gSohVRRearDiffRow, gSohVRRearDiffFrac, gSohVRRearDiffLo, sSohVRRearAgeMax,
             sSohVRRearRetries,
             gSohVROwnBoostSkips, gSohVROwnReflSkips, gSohVRSkyWide, gSohVRSkyArFault, gSohVRSkyVtxL,
             gSohVRSkyVtxR, gSohVRSkyBuildAr, gSohVRSkySideQuads, gSohIosGfxFbFailIn, ++sSohVRSeq);
    return sSohVRModeLine;
}

const char* SohVR_DumpContract(void) {
    extern volatile int gSoh3DEyeW, gSoh3DEyeH;
    // R9: the Metal backend's own counters (overlay 0044 rev4 / 0055).
    extern volatile unsigned int gSohIosGfxAllocFails, gSohIosGfxSlotWaits, gSohIosGfxSlotStarves;
    extern volatile unsigned int gSohIosGfxSlotWaitBusy, gSohIosGfxSlotWaitShown, gSohIosGfxSlotWaitUs;
    extern volatile double gSohIosGfxFbBytes;
    extern volatile unsigned int gSohIosGfxQuiesces; // R11 item 2
    extern volatile unsigned int gSohIosGfxFbRecreates; // R12 item 1
    extern volatile unsigned int gSohIosGfxFbSkips;     // R13 item 1a
    extern volatile unsigned int gSohIosGfxAlphaFbs;    // R13 item 2 (the HUD)
    extern volatile unsigned int gSohIosGfxSlotPicks, gSohIosGfxSlotPickFails, gSohIosGfxSlotSkips;
    extern volatile unsigned int gSohIosGfxStarveEye[4];
    extern void* volatile gSoh3DHudTexture;
    extern volatile int gSohVRDbgClearsAll, gSohVRDbgClearsAlpha;
    snprintf(sSohVRContractLine, sizeof(sSohVRContractLine),
             "vr_contract valid=%d views=%d textures=%d ratemaps=%d layout=%d colorFmt=%lu depthFmt=%lu "
             "near=%.3f far=%.1f "
             "eye0_vp=%.0fx%.0f eye0_tex=%d eye0_slice=%d eye0_tan=%.4f,%.4f,%.4f,%.4f "
             "eye1_vp=%.0fx%.0f eye1_tex=%d eye1_slice=%d eye1_tan=%.4f,%.4f,%.4f,%.4f "
             "engine_eye_fb=%dx%d "
             "depth=fwd->revZ eng_near=%.4f eng_far=%.1f comp_near=%.4f comp_far=%.1f comp_far_inf=%d "
             "rscale=%.2f hud_dist=%.2f hud_height=%.2f hud_scale=%.2f hud_tex=%d "
             "clears_vr=%d clears_alpha=%d hud_w=%d hud_h=%d vrdbg=%d "
             "rm_layers=%d rm_phys=%dx%d rm_screen=%dx%d "
             // R9 item 1b: THE ALLOCATION TELEMETRY the user's device reports back
             // at the Siri-screenshot moment. fb_mb is what the framebuffer
             // attachments actually cost right now (four eye slots + the HUD,
             // colour and depth); alloc_fails counts newTexture returning nil,
             // which before 0055 left a framebuffer permanently dead; slot_waits
             // / slot_starves say how often the eye-slot handoff gate engaged and
             // how often it had to give up (0044 rev4).
             "fb_mb=%.1f alloc_fails=%u slot_waits=%u slot_starves=%u "
             "slot_busy=%u slot_shown=%u slot_wait_ms=%.1f "
             // R9 item 1c: foveated engine rendering. cap=0 in the simulator, and
             // that is trap D15 rather than a bug — there is no rate map here to
             // build one against, so the full-resolution path is what runs.
             // R11: quiesces counts eye-extent resizes that unpublished and
             // drained the attachments before releasing them (item 2), and
             // cb_errors is R10's compositor command-buffer error counter,
             // repeated here so one dump carries the whole GPU picture.
             "fove_cap=%d fove_on=%d fove_phys=%dx%d fove_screen=%dx%d fove_saving=%.3f "
             "quiesces=%u fb_recreates=%u slot_picks=%u slot_pickfails=%u "
             "slot_skips=%u starve_eye=%u/%u/%u/%u cb_errors=%u "
             // R13 item 1: fb_skips counts render passes REFUSED because the
             // framebuffer's descriptor could not be made whole (overlay 0055
             // rev3), copy_skips the compositor's eye-copy allocations that
             // came back nil. Both used to be crashes.
             "fb_skips=%u copy_skips=%u alphacov_fbs=%u seq=%u",
             sSohVRContractValid, sSohVRViewCount, sSohVRTexCount, sSohVRRateMaps, sSohVRLayout, sSohVRColorFmt,
             sSohVRDepthFmt, sSohVRDepthNear, sohvr_engine_far(), sSohVRExtent[0][0], sSohVRExtent[0][1],
             sSohVRTexIdx[0], sSohVRSlice[0], sSohVRTan[0][0], sSohVRTan[0][1], sSohVRTan[0][2],
             sSohVRTan[0][3], sSohVRExtent[1][0], sSohVRExtent[1][1], sSohVRTexIdx[1], sSohVRSlice[1],
             sSohVRTan[1][0], sSohVRTan[1][1], sSohVRTan[1][2], sSohVRTan[1][3], gSoh3DEyeW, gSoh3DEyeH,
             sSohVRDepthNear, sohvr_engine_far(), sSohVRDepthNear, sSohVRCompFar, sSohVRCompFarInfinite,
             sSohVRRenderScale, sSohVRHudDist, sSohVRHudHeight, sSohVRHudScale,
             (int)(gSoh3DHudTexture != NULL), gSohVRDbgClearsAll, gSohVRDbgClearsAlpha,
             (int)((__bridge id<MTLTexture>)gSoh3DHudTexture).width,
             (int)((__bridge id<MTLTexture>)gSoh3DHudTexture).height, sSohVRDbgVr,
             sSohVRRateMapLayers, sSohVRRateMapPhysW, sSohVRRateMapPhysH, sSohVRRateMapScrW,
             sSohVRRateMapScrH, gSohIosGfxFbBytes / (1024.0 * 1024.0), gSohIosGfxAllocFails,
             gSohIosGfxSlotWaits, gSohIosGfxSlotStarves, gSohIosGfxSlotWaitBusy, gSohIosGfxSlotWaitShown,
             gSohIosGfxSlotWaitUs / 1000.0, sSohVRFoveCap, sSohVRFoveEnabled,
             sSohVRFovePhysW, sSohVRFovePhysH, sSohVRFoveScrW, sSohVRFoveScrH, sSohVRFoveSaving,
             gSohIosGfxQuiesces, gSohIosGfxFbRecreates, gSohIosGfxSlotPicks,
             gSohIosGfxSlotPickFails, gSohIosGfxSlotSkips, gSohIosGfxStarveEye[0], gSohIosGfxStarveEye[1],
             gSohIosGfxStarveEye[2], gSohIosGfxStarveEye[3], sSohVRCbErrors, gSohIosGfxFbSkips,
             sSohVRCopySkips, gSohIosGfxAlphaFbs, ++sSohVRSeq);
    return sSohVRContractLine;
}

// R11 item 3 — THE REAR-VIEW CONTENT DUMP.
//
// The three rear-view bugs the user photographed are all "the mirror walk replays
// a display list that was built for the FORWARD camera", and none of them is
// visible in a simulator screenshot of a pane that is 40 degrees wide. So the
// engine reports what it did: how many karts the VR override admitted that the
// forward view-cone had rejected (3b), how many times the local kart's shadow
// was bracketed for the sink (3a), and whether the sky re-key is live (3c).
// R19 item 5 — SOH_VRGLITCH: THE RAINBOW-CLASS COUNTERS AS ONE LINE IN THE
// DEVICE LOG. the user (1.0.0.17): a quick rainbow flash 5-6 times in a 3-minute
// Luigi Raceway race. The simulator's 3-minute runs tick none of the R9-R12
// rainbow counters (VR-R19-NOTES §5), so the next evidence has to come off the
// headset: every 600 compositor frames (~7 s at 90 Hz) the DELTAS of every
// counter that has ever meant "the compositor showed something it should not
// have" (or nearly did) go into Documents/logs as `SOH_VRGLITCH`, beside
// SOH_PERF. Only nonzero deltas are printed, so a clean window is one short
// line. Snapshotted on the render thread (plain loads), formatted and written
// on a utility queue via SohIos_SpdLogLine (trap: R14 item 5, a log that perturbs what it measures).
#define SOHVR_GLITCH_N 17
static unsigned int sSohVRGlitchPrev[SOHVR_GLITCH_N];
static int sSohVRGlitchArmed = 0;
static unsigned int sSohVRGlitchLines = 0;
static void sohvr_glitch_tick(unsigned int frames) {
    extern volatile unsigned int gSohVREyeTagMiss[2], gSohVRInUseOverflow, gSohVREyeTagPostMiss[2];
    extern volatile unsigned int gSohVRBindDefer[4], gSohVRPairForced, gSohVREyeMono, gSohVRPubOrphans;
    extern volatile unsigned int gSohIosGfxSlotStarves, gSohIosGfxSlotWaitShown, gSohIosGfxFbRecreates;
    extern volatile unsigned int gSohIosGfxAllocFails, gSohIosGfxFbSkips, gSohVREyeBlank[2];
    extern unsigned int SohIos_FbrdWaitsAll(void);
    // R20 item 1 (0064 rev3): the vertex pool. vbo_busy = walks whose pool
    // buffer still had a GPU reader when they began (the fix swaps those out);
    // vbo_write = walks that wrote into one anyway -- the mechanism behind the
    // left-eye rainbow, and 0 is the only good reading with the fix on.
    extern unsigned int SohIos_VboBusyAll(void), SohIos_VboWriteBusyAll(void);
    static const char* const kNames[SOHVR_GLITCH_N] = {
        "pair_forced", "bind_defer", "eye_mono", "eye_blank", "slot_starves", "slot_shown", "fb_recreates",
        "alloc_fails", "fb_skips", "cb_errors", "copy_skips", "eye_tag_miss", "eye_tag_post_miss",
        "pub_orphans", "fbrd_wait", "vbo_busy", "vbo_write" };
    unsigned int now[SOHVR_GLITCH_N] = {
        gSohVRPairForced, gSohVRBindDefer[0] + gSohVRBindDefer[1], gSohVREyeMono,
        gSohVREyeBlank[0] + gSohVREyeBlank[1], gSohIosGfxSlotStarves, gSohIosGfxSlotWaitShown,
        gSohIosGfxFbRecreates, gSohIosGfxAllocFails, gSohIosGfxFbSkips, sSohVRCbErrors, sSohVRCopySkips,
        gSohVREyeTagMiss[0] + gSohVREyeTagMiss[1], gSohVREyeTagPostMiss[0] + gSohVREyeTagPostMiss[1],
        gSohVRPubOrphans, SohIos_FbrdWaitsAll(), SohIos_VboBusyAll(), SohIos_VboWriteBusyAll() };
    if (!sSohVRGlitchArmed) {
        memcpy(sSohVRGlitchPrev, now, sizeof(now));
        sSohVRGlitchArmed = 1;
        return;
    }
    char body[512];
    int n = 0;
    for (int i = 0; i < SOHVR_GLITCH_N && n < (int)sizeof(body) - 48; i++) {
        const unsigned int d = now[i] - sSohVRGlitchPrev[i];
        if (d != 0) {
            n += snprintf(body + n, sizeof(body) - n, " %s=+%u", kNames[i], d);
        }
    }
    memcpy(sSohVRGlitchPrev, now, sizeof(now));
    const unsigned int seq = ++sSohVRGlitchLines;
    NSString* line = [NSString stringWithFormat:@"SOH_VRGLITCH seq=%u frames=%u%s", seq, frames,
                                                n > 0 ? body : " clean"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        extern void SohIos_SpdLogLine(const char* line); // 0064 rev2 (not the blackbox's SohIos_LogLine)
        SohIos_SpdLogLine(line.UTF8String);
    });
}
// The last line's sequence number, for the suite.
unsigned int SohVR_GlitchLines(void) {
    return sSohVRGlitchLines;
}

static char sSohVRRearLine[256];
const char* SohVR_DumpRearView(void) {
    extern volatile unsigned int gSohVRCullKartsKept;
    extern volatile unsigned int gSohVROwnShadowTags;
    extern volatile unsigned int gSohVRKartsListed;
    extern volatile int gSohVRConeFault;
    extern volatile int gSohVRRearSky;
    extern volatile int gSohVRAngleCullOff;
    extern volatile unsigned int gSohVROwnKartRearTags;
    snprintf(sSohVRRearLine, sizeof(sSohVRRearLine),
             "vr_rearview karts_listed=%u karts_kept=%u own_shadow_tagged=%d own_shadow_tags=%u "
             "rearsky=%d anglecull_off=%d conefault=%d mirror=%d ownkart_rear_tags=%u",
             gSohVRKartsListed, gSohVRCullKartsKept, gSohVROwnShadowTags > 0 ? 1 : 0, gSohVROwnShadowTags,
             gSohVRRearSky, gSohVRAngleCullOff, gSohVRConeFault, sSohVRMirrorVisible,
             gSohVROwnKartRearTags);
    return sSohVRRearLine;
}

// R16-C — THE REAR PANE'S CAMERA, AS A NUMBER (falsifier F1).
//
// Three candidate pane cameras, all in GAME units, all reported UNCONDITIONALLY
// whatever `rearpivot` is set to (trap D48: gating the measurement on the same
// flag as the fix makes the red control read "no error" when it means "nobody
// looked"):
//
//   legacy   — what 1.0.0.12 ships: the world rotated 180 degrees about
//              `camEye + camFwd*camDist`, i.e. the pane camera at
//              `2*lookAt - camEye`, at the chase camera's own height.
//   analytic — the same rotation about the KART (0045 rev2's export).
//   rear     — MK64's OWN look-behind camera (0045 rev5), which is the
//              ground truth: it is a different object, ticked by
//              World::TickCameras, placed by the game's own camera code,
//              and it shares no arithmetic with either of the other two.
//
// The errors are |candidate - rear| in game units. On 1.0.0.12 the diagnosis
// predicts legacy_err ~= 140 (MK64 aims its racing camera 70 units AHEAD of
// the kart, so mirroring about the look-at point overshoots by 2*70) and
// analytic_err small (MK64's asymmetric eye/target smoothing, plus the wall
// pushout the analytic mirror does not have).
#define SOHVR_REAR_STALE_FRAMES 3u
static int sohvr_rear_cam(simd_float3* pos, simd_float3* at, simd_float3* up, unsigned int* ageOut) {
    extern volatile float gSohVRRearPos[3], gSohVRRearAt[3], gSohVRRearUp[3];
    extern volatile int gSohVRRearValid;
    extern volatile unsigned int gSohVRRearSeq, gSohVRRearFrame, gSohVRGameFrame;
    if (!gSohVRRearValid) {
        return 0;
    }
    float p0[3] = { 0, 0, 0 }, a0[3] = { 0, 0, 0 }, u0[3] = { 0, 1, 0 };
    unsigned int f0 = 0;
    int got = 0;
    for (int tr = 0; tr < 4; tr++) {
        unsigned int s0 = gSohVRRearSeq;
        if (s0 & 1u) {
            sSohVRRearRetries++;
            continue;
        }
        __sync_synchronize();
        for (int i = 0; i < 3; i++) {
            p0[i] = gSohVRRearPos[i];
            a0[i] = gSohVRRearAt[i];
            u0[i] = gSohVRRearUp[i];
        }
        f0 = gSohVRRearFrame;
        __sync_synchronize();
        if (gSohVRRearSeq == s0) {
            got = 1;
            break;
        }
        sSohVRRearRetries++;
    }
    if (!got) {
        return 0;
    }
    unsigned int age = gSohVRGameFrame - f0;
    if (age > sSohVRRearAgeMax && age < 1000u) {
        sSohVRRearAgeMax = age;
    }
    if (ageOut) {
        *ageOut = age;
    }
    if (age > SOHVR_REAR_STALE_FRAMES) {
        return 0;
    }
    if (pos) {
        *pos = simd_make_float3(p0[0], p0[1], p0[2]);
    }
    if (at) {
        *at = simd_make_float3(a0[0], a0[1], a0[2]);
    }
    if (up) {
        *up = simd_make_float3(u0[0], u0[1], u0[2]);
    }
    return 1;
}
void SohVR_ClearRearStats(void) {
    sSohVRRearRetries = 0;
    sSohVRRearAgeMax = 0;
}

static char sSohVRRearCamLine[640];
const char* SohVR_DumpRear(void) {
    extern volatile float gSoh3DCamRight[3], gSoh3DCamFwd[3], gSoh3DCamEye[3];
    extern volatile float gSoh3DCamDist, gSoh3DCamAspect;
    extern volatile int gSohVRRearPivot;
    extern volatile int gSohVRMirrorW, gSohVRMirrorH;
    extern volatile unsigned int gSohVRRearDlSwaps;
    extern volatile int gSohVRRearSec, gSohVROwnKartRear;

    simd_float3 kart = simd_make_float3(0, 0, 0);
    int kyaw = 0;
    const int kartOk = sohvr_kart_pose(&kart, &kyaw);
    const simd_float3 eye = simd_make_float3(gSoh3DCamEye[0], gSoh3DCamEye[1], gSoh3DCamEye[2]);
    const simd_float3 fwd = simd_make_float3(gSoh3DCamFwd[0], gSoh3DCamFwd[1], gSoh3DCamFwd[2]);
    float kd = gSoh3DCamDist;
    if (!(kd > 1.0f && kd < 5000.0f)) {
        kd = 200.0f;
    }
    // The pivot is a VERTICAL axis, so both candidates keep the chase camera's
    // own Y — exactly what the matrix does.
    const simd_float3 kLegacy = simd_make_float3(eye.x + fwd.x * kd, eye.y, eye.z + fwd.z * kd);
    const simd_float3 kKart = simd_make_float3(kart.x, eye.y, kart.z);
    const simd_float3 panelLegacy = 2.0f * kLegacy - eye;
    const simd_float3 panelKart = 2.0f * kKart - eye;

    simd_float3 rpos = simd_make_float3(0, 0, 0), rat = simd_make_float3(0, 0, 0),
                rup = simd_make_float3(0, 1, 0);
    unsigned int rage = 0;
    const int rearOk = sohvr_rear_cam(&rpos, &rat, &rup, &rage);
    const float legacyErr = rearOk ? simd_length(panelLegacy - rpos) : -1.0f;
    const float analyticErr = rearOk ? simd_length(panelKart - rpos) : -1.0f;
    // The EFFECTIVE camera is whichever the live `rearpivot` makes 0044 use.
    // Mode 2 sources it from the same export the error is measured against, so
    // it is reported as 0 BY CONSTRUCTION and says so — the discriminating
    // numbers are legacy_err and analytic_err, which come from the chase
    // camera and the kart respectively and share no arithmetic with the rear
    // camera at all (trap D11).
    float effErr = -1.0f;
    if (rearOk) {
        effErr = (gSohVRRearPivot >= 2) ? 0.0f : (gSohVRRearPivot == 1 ? analyticErr : legacyErr);
    }
    const float paneAspect = (gSohVRMirrorH > 0) ? ((float)gSohVRMirrorW / (float)gSohVRMirrorH) : 0.0f;
    snprintf(sSohVRRearCamLine, sizeof(sSohVRRearCamLine),
             "vr_rear pivot=%d kart_ok=%d kart=%.1f,%.1f,%.1f kart_yaw=%d "
             "cam=%.1f,%.1f,%.1f camfwd=%.3f,%.3f,%.3f cam_dist=%.1f "
             "rear_ok=%d rear_age=%u rear_pos=%.1f,%.1f,%.1f rear_at=%.1f,%.1f,%.1f "
             "legacy_pane=%.1f,%.1f,%.1f analytic_pane=%.1f,%.1f,%.1f "
             "legacy_err=%.2f analytic_err=%.2f eff_err=%.2f eff_tautological=%d "
             "rear_retries=%u rear_age_max=%u "
             "aspect_game=%.4f aspect_pane=%.4f rear_dl_swaps=%u rearsec=%d rearownkart=%d",
             gSohVRRearPivot, kartOk, kart.x, kart.y, kart.z, kyaw, eye.x, eye.y, eye.z, fwd.x, fwd.y,
             fwd.z, gSoh3DCamDist, rearOk, rage, rpos.x, rpos.y, rpos.z, rat.x, rat.y, rat.z,
             panelLegacy.x, panelLegacy.y, panelLegacy.z, panelKart.x, panelKart.y, panelKart.z,
             legacyErr, analyticErr, effErr, (gSohVRRearPivot >= 2) ? 1 : 0, sSohVRRearRetries,
             sSohVRRearAgeMax, gSoh3DCamAspect, paneAspect, gSohVRRearDlSwaps, gSohVRRearSec,
             gSohVROwnKartRear);
    return sSohVRRearCamLine;
}

const char* SohVR_DumpPacing(void) {
    extern volatile int gSoh3DEyeW, gSoh3DEyeH;
    // R10 item 5: 0054 rev2's tumble-phase-is-animating flag, so the suite can
    // assert the FLIP gate from outside.
    extern volatile int gSohVRKartTumbling;
    extern volatile unsigned int gSohVRSpinEffectMask;
    const int gSohVRKartTumblingRO = gSohVRKartTumbling;
    const unsigned int gSohVRSpinMaskRO = gSohVRSpinEffectMask;
    extern void SohIos_PacingStats(float* engFps, float* tickTps);
    extern volatile float gSohIosGpuMs;
    float engFps = 0.0f, tickTps = 0.0f;
    SohIos_PacingStats(&engFps, &tickTps);
    snprintf(sSohVRPacingLine, sizeof(sSohVRPacingLine),
             "vr_pace engine_fps=%.2f tick_tps=%.2f present_hz=%.2f presents=%u gpu_ms=%.2f "
             "eye_vp=%.0fx%.0f eye_fb=%dx%d eye_budget=%.0f eye_clamped=%d eye_mpix=%.2f rscale=%.2f "
             "eye_owner=%s engine_eye=%dx%d panel_eye=%dx%d "
             // R9 item 4: how far the head has wandered from the seat baseline,
             // and how much of that the world placement is cancelling.
             "headlock=%d head_drift=%.3f head_comp=%.3f "
             // R9 item 6: the toggle, and the rotation it is composing.
             "spins=%d flips=%d tumbling=%d spin_mask=0x%08x tumble_roll=%.1f tumble_pitch=%.1f "
             // R9 item 7: the eye-aspect diagnostic (0 = off).
             "eye_aspect_dbg=%.3f "
             // R14 item 5 — THE HITCH DETECTOR and its suspects. `hitches` is
             // the SYMPTOM (a present interval past 2.5x the running mean);
             // `hitch_ago` is how long ago the last one was, so a report can be
             // correlated by the clock; the rest are the causes, each also
             // snapshotted AT the hitch (hitch_*) so a single reading names one.
             "hitches=%u hitch_ago=%.1f hitch_ms=%.1f frame_ms=%.2f "
             "worldflaps=%u seatflips=%u dumps=%u dtfalls=%u "
             "hitch_worldflaps=%u hitch_seatflips=%u hitch_dumps=%u hitch_dtfalls=%u hitch_rebases=%u "
             // R16-A (FAL-B): the kart-pose hole, as the two numbers the user's
             // "violent turn in a flash of an eye" actually is — how many
             // frames were seated on the chase camera while racing, and the
             // largest one-frame yaw step the world took.
             "seat_fallbacks=%u world_yaw_step_max=%.2f "
             "seq=%u",
             engFps, tickTps, sSohVRPresentHz, sSohVRPresentTotal, gSohIosGpuMs, sSohVRExtent[0][0],
             sSohVRExtent[0][1], sSohVREyeW, sSohVREyeH, sSohVREyeBudget, sSohVREyeClamped,
             (double)sSohVREyeW * (double)sSohVREyeH / 1.0e6, sSohVRRenderScale,
             (sSohEyeOwner == SOH_EYE_OWNER_VR) ? "vr" : (sSohEyeOwner == SOH_EYE_OWNER_PANEL ? "panel" : "none"),
             gSoh3DEyeW, gSoh3DEyeH, sSohEyePanelW, sSohEyePanelH, sSohVRHeadLock, sSohVRHeadLockDrift,
             simd_length(sSohVRHeadLockComp), sSohVRRealisticSpins, sSohVRRealisticFlips,
             gSohVRKartTumblingRO, gSohVRSpinMaskRO, sSohVRTumbleRollDeg,
             sSohVRTumblePitchDeg, sSohVREyeAspectDbg,
             sSohVRHitches, (sSohVRHitchAt > 0.0) ? (CACurrentMediaTime() - sSohVRHitchAt) : -1.0,
             sSohVRHitchMs, sSohVRFrameMsAvg,
             sSohVRWorldFlaps, sSohVRSeatFlips, sSohVRDumps, sSohVRDtFalls,
             sSohVRHitchWorldFlaps, sSohVRHitchSeatFlips, sSohVRHitchDumps, sSohVRHitchDtFalls,
             sSohVRHitchRebases, gSohVRSeatFallbacks, gSohVRWorldYawStepMax, ++sSohVRSeq);
    return sSohVRPacingLine;
}

// Called by a presenting loop immediately after cp_drawable_encode_present.
// R14 item 5 — THE HITCH DETECTOR.
//
// the user: "every 10-15 seconds the entire game view moves/jiggles briefly."
// That is a frame the compositor did not get on time — in a headset a late
// frame is not a stutter, it is the whole world sliding, because the pose the
// picture was rendered against no longer matches the pose it is displayed at.
// Nothing in this loop measured it, so the first job is to make the SYMPTOM a
// number, and the second is to make each SUSPECT a number taken at the same
// moment, so the retest reads "which counter moved when it jiggled" instead of
// asking the user to describe a feeling.
//
// A hitch is a present interval more than 2.5x the running median. The median
// is a cheap exponential tracker rather than a real one — it only has to be
// close, because the ratio it is compared against is deliberately generous.
static void sohvr_note_present(void) {
    sSohVRPresentTotal++;
    sSohVRPresentCount++;
    double now = CACurrentMediaTime();
    if (sSohVRPresentLast > 0.0) {
        double ms = (now - sSohVRPresentLast) * 1000.0;
        if (ms > 0.0 && ms < 2000.0) {
            if (sSohVRFrameMsAvg <= 0.0) {
                sSohVRFrameMsAvg = ms;
            } else if (ms > sSohVRFrameMsAvg * 2.5 && sSohVRPresentTotal > 30) {
                sSohVRHitches++;
                sSohVRHitchAt = now;
                sSohVRHitchMs = ms;
                sSohVRHitchWorldFlaps = sSohVRWorldFlaps;
                sSohVRHitchSeatFlips = sSohVRSeatFlips;
                sSohVRHitchDumps = sSohVRDumps;
                sSohVRHitchDtFalls = sSohVRDtFalls;
                sSohVRHitchRebases = (unsigned int)sSohVRRecenters;
            }
            // Slow tracker so one hitch cannot raise the bar for the next.
            sSohVRFrameMsAvg += (ms - sSohVRFrameMsAvg) * 0.02;
        }
    }
    sSohVRPresentLast = now;
    if (sSohVRPresentWindowStart <= 0.0) {
        sSohVRPresentWindowStart = now;
        return;
    }
    double el = now - sSohVRPresentWindowStart;
    if (el >= 1.0) {
        sSohVRPresentHz = sSohVRPresentCount / el;
        sSohVRPresentCount = 0;
        sSohVRPresentWindowStart = now;
    }
}

#pragma mark - VR mode: the head-tracked frame loop (VR-spec R1)

// The real VR loop. Structurally the 3D-panel loop — the frame shape in
// Soh3D_Immersive_Run is load-bearing and is reproduced here verbatim
// (predict timing -> wait optimal input -> query drawable -> device anchor ->
// encode -> present) — with three things layered on:
//
//   1. LIVE POSE RENDEZVOUS (spec D7, trap B1). Every compositor frame
//      composes A*V*P for both eyes from the anchor queried at THIS frame's
//      trackable-anchor time and publishes it with a monotone frame id. The
//      engine takes the latest pair once per host frame and hands the id back
//      out with the eye textures; the loop looks that id up in an anchor ring
//      and submits THAT anchor with the drawable. The pose the pixels were
//      rendered from and the pose presented with them are therefore the same
//      object, without the loop ever having to block on the engine (a strict
//      rendezvous would peg presentation to the engine's 30 Hz — trap A1 by
//      another road).
//
//   2. DEPTH HANDOFF WITH CONVERSION (spec D2 as amended). The engine
//      renders forward-Z; the drawable is reverse-Z with a usually-infinite
//      far plane. The per-eye blit reconstructs view distance from the
//      engine's depth texture and re-encodes it in the compositor's
//      convention, so reprojection has real geometry to work with.
//
//   3. PLANE COMPOSITING (spec D6, and D12's rear-view pane later). A
//      texture placed on a quad in player space with true disparity and real
//      depth. The HUD is its first customer; the machinery is deliberately
//      "a texture on a plane", not "the HUD".
//
// Non-gameplay frames (menus, title, loading, podium) fall back to the shipped
// world-locked panel presentation inside the SAME space, with a reason code in
// `vr mode` naming the predicate that failed.

extern volatile int gSohVRWorldActive;
extern void* volatile gSoh3DEyeDepthTexture[2];
extern volatile unsigned int gSoh3DEyeTag[2];
extern void* volatile gSoh3DHudTexture;
extern volatile int gSohIosPauseReq;
extern volatile int gSoh3DEyeW, gSoh3DEyeH;
extern void SohIosVR_PublishEyes(const float* m, unsigned int frameId);
#import "SohIosShell.h" // R16-A F4: SohVRFrameSnapshot / SohIosVR_PublishFrame
// R3 (spec D12): the rear-view pane's third walk and its published texture.
extern volatile int gSohVRMirrorActive;
extern void* volatile gSoh3DMirrorTexture;
extern volatile int gSohVRMirrorW, gSohVRMirrorH;
extern volatile unsigned int gSohVRRearItemSeq;
// R11 item 1: the in-use claim the engine's handoff gate waits on, and the
// independent per-eye frame-tag probe. Both live in SohIosShell.m (see the
// long note there) because gfx_metal.cpp links on iPhone too.
// R12 item 1: Add RETURNS whether the claim was recorded — a refusal means the
// engine has reserved that slot at its gate and binding it anyway is the bug.
extern int SohVR_TexInUseAdd(void* tex);
extern void SohVR_TexInUseSub(void* tex);
extern void SohVR_TexInUseClear(void);
extern volatile int gSohVREyeTagOn;
extern volatile int gSohVREyeTagFault;
extern volatile unsigned int gSohVREyeTagMiss[2];
extern volatile unsigned int gSohVREyeTagChecks[2];
extern volatile unsigned int gSohVRInUseOverflow;
// R12 item 1: the post-blit probe phase, the bind refusals, the two sim stress
// knobs and the A/B that turns the producer reservation off.
extern volatile unsigned int gSohVREyeTagPostMiss[2];
extern volatile unsigned int gSoh3DEyeStamp[2];
// R13 item 2a: four slots now (0 eye0, 1 eye1, 2 HUD, 3 rear-view pane).
extern volatile unsigned int gSohVRBindDefer[4];
extern volatile unsigned int gSohVROwnSweeps, gSohVRHudEncodes, gSohVRHudLastGood;
extern volatile int gSohVRCompDelayMs;
extern volatile int gSohVRCompHoldMs;
extern volatile int gSohVREngineOwnFix;
// R15 item 1: the pair rule, its red control and its counters (SohIosShell.m).
extern volatile int gSohVRPairFix;
extern volatile int gSohVRStaleForce;
extern volatile unsigned int gSohVREyeStale[2];
extern volatile unsigned int gSohVRPairSplits;
extern volatile unsigned int gSohVRPairForced;
extern volatile unsigned int gSohVRPresentSplits;
extern volatile unsigned int gSohVRPresentTag[2];

// R12 item 1: the last coherent eye pair the loop actually bound. Shown when
// the engine owns the freshly published slot — one publication old and whole,
// rather than whatever the engine happens to be writing this instant.
static id<MTLTexture> sSohVRLastEyeTex[2];
static id<MTLTexture> sSohVRLastEyeDepth[2];
static unsigned int sSohVRLastEyeTag[2] = { 0, 0 };
static unsigned int sSohVRLastEyePose[2] = { 0, 0 };
// R15 item 1: the last COHERENT PAIR — two textures published for the same
// pose tag. This is what a refusal or a half-landed publication falls back to,
// both eyes together, so a stale frame is stereo-consistent and reprojected
// against its own anchor (i.e. invisible) rather than one eye displaced by a
// frame of head motion (i.e. the user's flicker).
static id<MTLTexture> sSohVRPairTex[2];
static id<MTLTexture> sSohVRPairDepth[2];
// R16-A (F3.3): the textures whose claim is HELD across frames, so the
// recorded pair is always still there to fall back to. nil when the hold is
// off or the claim was refused.
static id<MTLTexture> sSohVRPairHeld[2];
static unsigned int sSohVRPairStamp[2] = { 0, 0 };
static unsigned int sSohVRPairPose = 0;
// R13 item 2a: the same idea for the HUD, which had no fallback at all.
static id<MTLTexture> sSohVRLastHudTex;

// --- R11 item 1: the corner frame-tag readback ------------------------------
//
// The engine stamps the low byte of the pose tag into eight corner texels of
// each eye texture (black = 0, white = 1, the only two byte values an sRGB
// round trip preserves exactly), inside the very command buffer that renders
// the eye. Here we copy those eight texels back out in the compositor's OWN
// command buffer — so the copy happens at exactly the moment the render pass
// samples the texture — and compare them, in the completion handler, with the
// tag we read from gSoh3DEyeTag when we bound it.
//
// spec D11 in full: the ground truth (the pixels) contains none of the
// quantity under test (the publication bookkeeping); no injection is involved;
// and `vr set eyetagfault 1` makes the engine stamp a deliberately wrong byte,
// which the suite requires to drive the counter RED before it accepts a green.
// R12: two readbacks per eye per frame now, so the ring doubles.
#define SOHVR_TAGRING 8
static id<MTLBuffer> sSohVRTagBuf[2][SOHVR_TAGRING];
static unsigned int sSohVRTagRingIdx[2] = { 0, 0 };

// R12 item 1: `phase` 0 is R11's read, encoded at the head of the command
// buffer; phase 1 is the new one, encoded after the last view's render pass.
// R11 had only phase 0, which is strictly BEFORE the world blit it is meant to
// vouch for — a tear that begins during the blit could not be seen at all.
// Both phases count into eye_tag_miss (the user's sentence keeps its meaning and
// gets strictly more sensitive); phase 1 also counts into eye_tag_post_miss so
// the two can be told apart in the log.
static void sohvr_tag_probe(id<MTLCommandBuffer> cb, int e, id<MTLTexture> src, unsigned int expectTag,
                            int phase) {
    if (!gSohVREyeTagOn || src == nil || src.width < 8 || e < 0 || e > 1) {
        return;
    }
    unsigned int slot = sSohVRTagRingIdx[e] % SOHVR_TAGRING;
    sSohVRTagRingIdx[e]++;
    if (sSohVRTagBuf[e][slot] == nil) {
        sSohVRTagBuf[e][slot] = [src.device newBufferWithLength:32
                                                        options:MTLResourceStorageModeShared];
        if (sSohVRTagBuf[e][slot] == nil) {
            return;
        }
    }
    id<MTLBuffer> dst = sSohVRTagBuf[e][slot];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:src
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(8, 1, 1)
                 toBuffer:dst
        destinationOffset:0
   destinationBytesPerRow:32
 destinationBytesPerImage:32];
    [blit endEncoding];
    unsigned char want = (unsigned char)(expectTag & 0xFFu);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        const unsigned char* px = (const unsigned char*)dst.contents;
        unsigned char got = 0;
        for (int i = 0; i < 8; i++) {
            if (px[i * 4] >= 128) {
                got |= (unsigned char)(1u << i);
            }
        }
        gSohVREyeTagChecks[e] = gSohVREyeTagChecks[e] + 1;
        if (got != want) {
            gSohVREyeTagMiss[e] = gSohVREyeTagMiss[e] + 1;
            if (phase != 0) {
                gSohVREyeTagPostMiss[e] = gSohVREyeTagPostMiss[e] + 1;
            }
        }
    }];
}

// --- R15 item 3: WHERE THE HUD ACTUALLY IS, measured off its own pixels -----
//
// R14 introduced SOHVR_HUD_CONTENT_TOP — "the fraction of the HUD framebuffer's
// height, measured down from its top, that carries no HUD" — and set it to 0.30
// by eye. the user's 1.0.0.11 photograph shows the consequence: the pane's bottom
// edge now sits ON the lap counter. 0.30 UNDERSHOOTS, badly, because MK64's HUD
// starts within a few per cent of the top of the 320x240 screen (the LAP row and
// the timer), not a third of the way down.
//
// A constant read off a photograph is what produced the overlap, so this round
// measures it: `vr set hudscan 1` blits the published HUD framebuffer's upper
// rows back into a shared buffer and finds the FIRST row carrying any alpha at
// all. One shot, dev-gated, off the hot path — trap D33 forbids doing it per
// frame. `hud_alpha_top` is in `vr mode`, and the suite asserts the compiled
// constant does not undershoot it.
static int sSohVRHudScanReq = 0;
volatile float gSohVRHudAlphaTop = -1.0f;
volatile float gSohVRHudAlphaBot = -1.0f;
volatile unsigned int gSohVRHudScans = 0;
void SohVR_RequestHudScan(void) {
    sSohVRHudScanReq = 1;
}
static void sohvr_hud_alpha_scan(id<MTLCommandBuffer> cb, id<MTLTexture> hud) {
    if (!sSohVRHudScanReq || hud == nil) {
        return;
    }
    if (hud.pixelFormat != MTLPixelFormatBGRA8Unorm && hud.pixelFormat != MTLPixelFormatRGBA8Unorm &&
        hud.pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB &&
        hud.pixelFormat != MTLPixelFormatRGBA8Unorm_sRGB) {
        NSLog(@"[SohVR] hudscan: unsupported pixel format %lu", (unsigned long)hud.pixelFormat);
        sSohVRHudScanReq = 0;
        return;
    }
    sSohVRHudScanReq = 0;
    const NSUInteger w = hud.width, h = hud.height;
    if (w == 0 || h == 0 || (uint64_t)w * (uint64_t)h * 4ull > 96ull * 1024ull * 1024ull) {
        NSLog(@"[SohVR] hudscan: %lux%lu is too large to read back", (unsigned long)w, (unsigned long)h);
        return;
    }
    const NSUInteger rowBytes = w * 4;
    id<MTLBuffer> dst = [hud.device newBufferWithLength:rowBytes * h
                                                options:MTLResourceStorageModeShared];
    if (dst == nil) {
        return;
    }
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:hud
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(w, h, 1)
                 toBuffer:dst
        destinationOffset:0
   destinationBytesPerRow:rowBytes
 destinationBytesPerImage:rowBytes * h];
    [blit endEncoding];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        const unsigned char* px = (const unsigned char*)dst.contents;
        NSInteger first = -1, last = -1;
        for (NSUInteger y = 0; y < h; y++) {
            const unsigned char* row = px + y * rowBytes;
            int any = 0;
            for (NSUInteger x = 0; x < w; x++) {
                if (row[x * 4 + 3] >= 16) {
                    any = 1;
                    break;
                }
            }
            if (any) {
                if (first < 0) {
                    first = (NSInteger)y;
                }
                last = (NSInteger)y;
            }
        }
        if (first >= 0) {
            gSohVRHudAlphaTop = (float)first / (float)h;
            gSohVRHudAlphaBot = (float)(last + 1) / (float)h;
        } else {
            gSohVRHudAlphaTop = 1.0f;
            gSohVRHudAlphaBot = 1.0f;
        }
        gSohVRHudScans = gSohVRHudScans + 1;
        NSLog(@"[SohVR] hudscan: %lux%lu content rows %ld..%ld -> top %.4f bottom %.4f",
              (unsigned long)w, (unsigned long)h, (long)first, (long)last, gSohVRHudAlphaTop,
              gSohVRHudAlphaBot);
    }];
}

// R16-C — THE REAR PANE'S FRAMEBUFFER, SCANNED (falsifiers F2 and F3).
//
// Same recipe as sohvr_hud_alpha_scan above (trap D37: measure the framebuffer,
// then DERIVE the placement; and trap D33: one shot, dev-gated, never per
// frame), pointed at the published mirror texture.
//
// F3 — THE HOLE, AS A NUMBER. R15 established that the grey band in the pane is
// MK64's below-horizon ground fill showing through a hole in the display list,
// not paint over a road: dropping the fill (`vr set rearfloor 0`) turns the
// same band BLACK. So the honest metric is not "how much grey" — a repaint
// could move that — it is "how many rows carry NO GEOMETRY AT ALL", and a row
// with no geometry is a row whose colour barely changes across x, because
// everything screen-space the pane draws (the gradient, the fill, its black
// cap) is a full-width horizontal band. rear_flat is that fraction over the
// pane's LOWER HALF, which the horizon (37-39% of pane height, measured off
// the user's image 3) is always above. It reads the same with the fill on or off,
// which is exactly what makes it immune to the repaint objection; rear_grey is
// reported beside it as the non-black part of the same set, for continuity with
// R15's artefacts.
//
// F2 — THE OWN KART'S ROW. Nothing in a single frame distinguishes the kart
// quad from the road, so the measurement is a DIFFERENCE: scan once with
// `rearownkart 0` (mode 1, stored as the baseline), then again with it on
// (mode 2), and report the centroid row of the pixels that changed. With the
// kart parked on flat road that difference IS the kart, and its row is a pure
// pixel fact about where the pane camera is standing — it shares nothing with
// the matrices under test.
static int sSohVRRearScanReq = 0;
static unsigned char* sSohVRRearBase = NULL;
static size_t sSohVRRearBaseLen = 0;
static NSUInteger sSohVRRearBaseW = 0, sSohVRRearBaseH = 0;
volatile float gSohVRRearFlat = -1.0f;
volatile float gSohVRRearGrey = -1.0f;
volatile float gSohVRRearDiffRow = -1.0f;
volatile float gSohVRRearDiffFrac = -1.0f;
volatile unsigned int gSohVRRearScans = 0;
volatile int gSohVRRearScanW = 0, gSohVRRearScanH = 0;
volatile float gSohVRRearDiffLo = -1.0f;
static char sSohVRRearPngPath[256] = { 0 };
void SohVR_RequestRearScan(int mode) {
    sSohVRRearScanReq = (mode <= 1) ? 1 : (mode >= 3 ? 3 : 2);
}
const char* SohVR_RearPngPath(void) {
    return sSohVRRearPngPath;
}
static void sohvr_rear_scan(id<MTLCommandBuffer> cb, id<MTLTexture> mirror) {
    if (!sSohVRRearScanReq || mirror == nil) {
        return;
    }
    if (mirror.pixelFormat != MTLPixelFormatBGRA8Unorm && mirror.pixelFormat != MTLPixelFormatRGBA8Unorm &&
        mirror.pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB &&
        mirror.pixelFormat != MTLPixelFormatRGBA8Unorm_sRGB) {
        NSLog(@"[SohVR] rearscan: unsupported pixel format %lu", (unsigned long)mirror.pixelFormat);
        sSohVRRearScanReq = 0;
        return;
    }
    const int mode = sSohVRRearScanReq;
    sSohVRRearScanReq = 0;
    const NSUInteger w = mirror.width, h = mirror.height;
    if (w == 0 || h == 0 || (uint64_t)w * (uint64_t)h * 4ull > 96ull * 1024ull * 1024ull) {
        NSLog(@"[SohVR] rearscan: %lux%lu is too large to read back", (unsigned long)w, (unsigned long)h);
        return;
    }
    const NSUInteger rowBytes = w * 4;
    id<MTLBuffer> dst = [mirror.device newBufferWithLength:rowBytes * h
                                                  options:MTLResourceStorageModeShared];
    if (dst == nil) {
        return;
    }
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:mirror
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(w, h, 1)
                 toBuffer:dst
        destinationOffset:0
   destinationBytesPerRow:rowBytes
 destinationBytesPerImage:rowBytes * h];
    [blit endEncoding];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        const unsigned char* px = (const unsigned char*)dst.contents;
        // --- F3: flat (= no geometry) rows over the pane's lower half -------
        const NSUInteger y0 = h / 2;
        NSUInteger flat = 0, grey = 0, rows = 0;
        for (NSUInteger y = y0; y < h; y++) {
            const unsigned char* row = px + y * rowBytes;
            int lo[3] = { 255, 255, 255 }, hi[3] = { 0, 0, 0 };
            long sum = 0;
            // Every 4th column: the metric is a band test, not an edge test.
            for (NSUInteger x = 0; x < w; x += 4) {
                for (int c = 0; c < 3; c++) {
                    const int v = row[x * 4 + c];
                    if (v < lo[c]) {
                        lo[c] = v;
                    }
                    if (v > hi[c]) {
                        hi[c] = v;
                    }
                    sum += v;
                }
            }
            const int span = (hi[0] - lo[0]) + (hi[1] - lo[1]) + (hi[2] - lo[2]);
            const long mean = sum / (long)(3 * ((w + 3) / 4));
            rows++;
            if (span <= 24) { // a full-width screen-space band, nothing drawn on it
                flat++;
                if (mean >= 16) {
                    grey++;
                }
            }
        }
        gSohVRRearFlat = rows ? (float)flat / (float)rows : -1.0f;
        gSohVRRearGrey = rows ? (float)grey / (float)rows : -1.0f;
        gSohVRRearScanW = (int)w;
        gSohVRRearScanH = (int)h;
        // --- F2: the difference centroid ------------------------------------
        if (mode == 1) {
            if (sSohVRRearBaseLen != rowBytes * h) {
                free(sSohVRRearBase);
                sSohVRRearBase = (unsigned char*)malloc(rowBytes * h);
                sSohVRRearBaseLen = sSohVRRearBase ? rowBytes * h : 0;
            }
            if (sSohVRRearBase) {
                memcpy(sSohVRRearBase, px, rowBytes * h);
                sSohVRRearBaseW = w;
                sSohVRRearBaseH = h;
            }
            gSohVRRearDiffRow = -1.0f;
            gSohVRRearDiffFrac = -1.0f;
        } else if (sSohVRRearBase && sSohVRRearBaseW == w && sSohVRRearBaseH == h) {
            double wsum = 0.0;
            unsigned long n = 0, nlo = 0;
            for (NSUInteger y = 0; y < h; y++) {
                const unsigned char* a = px + y * rowBytes;
                const unsigned char* b = sSohVRRearBase + y * rowBytes;
                for (NSUInteger x = 0; x < w; x++) {
                    const int d = abs((int)a[x * 4 + 0] - (int)b[x * 4 + 0]) +
                                  abs((int)a[x * 4 + 1] - (int)b[x * 4 + 1]) +
                                  abs((int)a[x * 4 + 2] - (int)b[x * 4 + 2]);
                    if (d >= 48) {
                        wsum += (double)y;
                        n++;
                        if (y >= h / 2) {
                            nlo++;
                        }
                    }
                }
            }
            gSohVRRearDiffFrac = (float)((double)n / (double)(w * h));
            gSohVRRearDiffRow = n ? (float)(wsum / (double)n / (double)h) : -1.0f;
            gSohVRRearDiffLo = (float)((double)nlo / (double)(w * (h - h / 2)));
        }
        if (mode == 3) {
            // R16-C: THE PANE ITSELF, as a file. A composited-eye screenshot
            // shows the pane a few hundred pixels across and cannot settle a
            // question about what is IN it; this is the mirror framebuffer,
            // full size, written where the harness can pull it off the sim.
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            const int bgra = (mirror.pixelFormat == MTLPixelFormatBGRA8Unorm ||
                              mirror.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB);
            CGBitmapInfo bi = (CGBitmapInfo)kCGImageAlphaNoneSkipFirst |
                              (bgra ? kCGBitmapByteOrder32Little : kCGBitmapByteOrder32Big);
            CGContextRef ctx = CGBitmapContextCreate((void*)px, w, h, 8, rowBytes, cs, bi);
            if (ctx) {
                CGImageRef img = CGBitmapContextCreateImage(ctx);
                if (img) {
                    NSString* dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                        NSUserDomainMask, YES) firstObject];
                    NSString* path = [dir stringByAppendingPathComponent:
                                              [NSString stringWithFormat:@"rear-%u.png", gSohVRRearScans]];
                    NSURL* url = [NSURL fileURLWithPath:path];
                    CGImageDestinationRef d =
                        CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
                    if (d) {
                        CGImageDestinationAddImage(d, img, NULL);
                        CGImageDestinationFinalize(d);
                        CFRelease(d);
                        snprintf(sSohVRRearPngPath, sizeof(sSohVRRearPngPath), "%s", path.UTF8String);
                        NSLog(@"[SohVR] rearscan: wrote %@", path);
                    }
                    CGImageRelease(img);
                }
                CGContextRelease(ctx);
            }
            CGColorSpaceRelease(cs);
        }
        gSohVRRearScans = gSohVRRearScans + 1;
        NSLog(@"[SohVR] rearscan(%d): %lux%lu flat=%.4f grey=%.4f diff_row=%.4f diff_frac=%.5f diff_lo=%.5f",
              mode, (unsigned long)w, (unsigned long)h, gSohVRRearFlat, gSohVRRearGrey, gSohVRRearDiffRow,
              gSohVRRearDiffFrac, gSohVRRearDiffLo);
    }];
}

// R14 item 3 — decide, once per compositor frame, WHICH panes are up, and
// therefore whether the engine pays for a third interpreter walk at all
// (spec D12: "renders ONLY while the pane is visible"). The auto-show, its
// rear-item edge detector, its 3-second deadline and the Sense right-stick
// latch are all gone; what is left is two owner-controlled switches and a
// bridge force that exists only so the suite can drive the pane headless.
//
// The two live flags are computed HERE rather than at the draw site, which is
// the R13 lesson restated: gSohVRMirrorActive is the only thing that makes the
// engine render the mirror at all, so a draw condition the latch does not know
// about gives that draw a stale or NULL texture. One decision, two consumers.
static void sohvr_mirror_decide(int worldActive) {
    int handTracked = 0;
    if (sSohVRMirrorLeftHand && worldActive) {
        simd_float4x4 probe;
        handTracked = SohSense_LeftPanePose(&probe) ? 1 : 0;
    }
    sSohVRPaneHandLive = handTracked;
    sSohVRPaneTopLive = (worldActive && sSohVRMirrorTop && sSohVRMirrorTopOn) ? 1 : 0;
    if (sSohVRMirrorHold && worldActive) {
        sSohVRPaneTopLive = 1; // the bridge/D-pad force: the suite's handle
    }
    sSohVRLeftHandLive = sSohVRPaneHandLive;
}
static int sohvr_mirror_should_show(void) {
    return (sSohVRPaneTopLive || sSohVRPaneHandLive) ? 1 : 0;
}

// --- R6: the in-headset settings surface -------------------------------------
// the user's third report was "I see no VR section with settings". The rows DO
// exist (overlay 0023's "Vision Pro VR" group is in the 1.0.0.2 binary — the
// strings are there), but they live in the ImGui port menu, which D-041 made
// DISPLAY-ONLY in 3D/VR: the immersive space takes input focus, so the menu
// cannot be driven from inside the headset at all. The only interactive
// surface in immersive is the SwiftUI ornament — whose gear sheet, until this
// round, contained nothing but 3D-panel rows. So there genuinely was no way
// for him to reach a VR setting while wearing the device.
//
// These accessors are the sheet's backing. Everything is plain C so the
// bridging header can see it; each setter persists through the same
// SohVR_SettingsSave path the bridge uses, and every one of them is safe to
// call from the main thread (which is where SwiftUI runs, and which is also
// the engine thread — see sohvr_on_engine_thread).
int SohVR_ViewCount(void) {
    return SOHVR_VIEW_COUNT;
}
void SohVR_SetViewIndex(int v) {
    SohVR_SetView(v);
}
int SohVR_GetViewIndex(void) {
    return sSohVRView;
}
float SohVR_GetScale(void) {
    return sSohVRScale;
}
void SohVR_SetScale(float s) {
    extern void SohVR_SettingsSave(void);
    // R12 item 3: the bridge keeps its wide range (it is a diagnostic, and
    // `vr set scale` is how a value outside the slider gets tried at all);
    // the SLIDER's band is SOHVR_DIO_SCALE_MIN..MAX and is enforced by the
    // display mapping, which cannot produce an index outside -10..+10.
    if (s >= 5.0f && s <= 2000.0f) {
        sSohVRScale = s;
        SohVR_SettingsSave();
    }
}
float SohVR_GetSeatUp(void) {
    return sSohVRSeatUp;
}
float SohVR_GetSeatFwd(void) {
    return sSohVRSeatFwd;
}
float SohVR_GetDimLevel(void) {
    return sSohVRCfg[sSohVRView].dim;
}
int SohVR_GetFixedHorizon(void) {
    return sSohVRCfg[sSohVRView].fixedHorizon;
}
float SohVR_GetRenderScale(void) {
    return sSohVRRenderScale;
}
float SohVR_GetEyeBudget(void) {
    return (float)sSohVREyeBudget;
}
void SohVR_SetEyeBudget(float px) {
    // R7: the ceiling reaches past the device's 5087-wide viewport now, so
    // "no clamp" is expressible. Below 512 is never useful.
    if (px >= 512.0f && px <= 16384.0f) {
        sSohVREyeBudget = (double)px;
    }
}
// R7 telemetry for the settings page: the user cannot type bridge commands in
// the headset, so the numbers the retest asks him for have to be ON the page.
float SohVR_GetEngineFps(void) {
    extern void SohIos_PacingStats(float* engFps, float* tickTps);
    float f = 0.0f, t = 0.0f;
    SohIos_PacingStats(&f, &t);
    return f;
}
int SohVR_GetEyeW(void) {
    return sSohVREyeW;
}
int SohVR_GetEyeH(void) {
    return sSohVREyeH;
}
// The one number the retest is really about: is the seat at the kart?
float SohVR_GetKartDist(void) {
    return sSohVRKartDist;
}
float SohVR_GetGazeDot(void) {
    return sSohVRGazeDot;
}
int SohVR_GetSeatFromKart(void) {
    return sSohVRSeatFromKart;
}

void SohVR_SetRenderScale(float scale01) {
    extern void SohVR_SettingsSave(void);
    if (scale01 >= 0.25f && scale01 <= 2.0f) {
        sSohVRRenderScale = scale01;
        SohVR_SettingsSave();
    }
}
void SohVR_SetHudPlane(float dist, float height, float scale) {
    extern void SohVR_SettingsSave(void);
    if (dist >= 0.3f && dist <= 20.0f) {
        sSohVRHudDist = dist;
    }
    if (height >= -5.0f && height <= 5.0f) {
        sSohVRHudHeight = height;
    }
    if (scale >= 0.2f && scale <= 5.0f) {
        sSohVRHudScale = scale;
    }
    sohvr_deconflict_panes();
    SohVR_SettingsSave();
}

// R10 addendum: the "HUD height" row's backing pair. Metres above eye level in
// the CURRENT view mode, exactly like every other placement tunable — the row
// shows it as an offset in centimetres from that mode's shipped default.
void SohVR_SetHudHeightM(float h) {
    extern void SohVR_SettingsSave(void);
    if (h >= -5.0f && h <= 5.0f) {
        sSohVRHudHeight = h;
    }
    sohvr_deconflict_panes();
    SohVR_SettingsSave();
}
float SohVR_GetHudHeightM(void) {
    return sSohVRHudHeight;
}
void SohVR_GetHudPlane(float* dist, float* height, float* scale) {
    if (dist) {
        *dist = sSohVRHudDist;
    }
    if (height) {
        *height = sSohVRHudHeight;
    }
    if (scale) {
        *scale = sSohVRHudScale;
    }
}

// --- the anchor ring (trap B1) ----------------------------------------------
// Retains the ar_device_anchor_t each published pose id was built from, so the
// drawable carrying that frame's pixels can be submitted with it. 32 slots is
// half a second of compositor frames — far more than the engine can lag by
// before the timeout path takes over.
// R9: 128 entries, was 32. The ring holds the anchors the engine's eye
// textures were rendered against, so its DEPTH is how far the engine is
// allowed to fall behind the compositor before the loop has to re-present
// against a stale anchor (trap B1's fallback) and count a pose timeout. At
// 32 entries and 60-120 Hz that is only 0.27-0.53 s, and the R9 eye-slot
// gate deliberately throttles the engine to the compositor — so a scene
// load or a gate starve could push a frame past the window and taint every
// timeout assert after it. 128 gives ~1-2 s of history for a handful of
// pointers. It is head-room, not a fix for anything: pose_timeouts must
// still read 0.
#define SOHVR_RING 128
static ar_device_anchor_t sSohVRRing[SOHVR_RING];
static unsigned int sSohVRRingId[SOHVR_RING];

static ar_device_anchor_t sohvr_ring_lookup(unsigned int id) {
    if (id == 0) {
        return nil;
    }
    unsigned int slot = id % SOHVR_RING;
    return (sSohVRRingId[slot] == id) ? sSohVRRing[slot] : nil;
}

// --- gameplay predicate (spec §5 R1 item 6) -------------------------------
// gSoh3DInPlay (0045) is already exactly "1P racing, not mid-quit-transition":
// menus, title, loading and the podium all clear it. The camera check catches
// the frames where the state says racing but 0045 has not captured a basis
// yet — entering with a dead basis would seat the world at the origin.
static int sohvr_world_frame_ok(void) {
    extern volatile int gSoh3DInPlay;
    extern volatile float gSoh3DCamFwd[3], gSoh3DCamRight[3];
    extern volatile float gSoh3DCamDist;
    if (!gSoh3DInPlay) {
        sSohVRWorldReason = "not-in-play";
        return 0;
    }
    float fl = gSoh3DCamFwd[0] * gSoh3DCamFwd[0] + gSoh3DCamFwd[1] * gSoh3DCamFwd[1] +
               gSoh3DCamFwd[2] * gSoh3DCamFwd[2];
    float rl = gSoh3DCamRight[0] * gSoh3DCamRight[0] + gSoh3DCamRight[1] * gSoh3DCamRight[1] +
               gSoh3DCamRight[2] * gSoh3DCamRight[2];
    if (fl < 1e-6f || rl < 1e-6f || !(gSoh3DCamDist > 0.0f)) {
        sSohVRWorldReason = "no-camera";
        return 0;
    }
    sSohVRWorldReason = "ok";
    return 1;
}

// --- pipelines ---------------------------------------------------------------
// Two of them: the per-eye world blit (colour + depth conversion) and the
// general plane compositor. Both write real depth, because the compositor
// reprojects on it.

typedef struct {
    float engNear, engFar;   // the engine's forward-Z frustum
    float compNear, compFar; // the compositor's reverse-Z range
    float compFarInfinite;   // 1 = infinite far, use the n/z limit form
    float srgbDecode;
    float hasDepth;          // 0 = no engine depth yet: colour alpha, far depth
    float dbgMode;           // D11: 0 normal, 1 force-alpha, 2 depth, 3 alpha
    float useAlphaCov;       // R2: trust destination alpha as the coverage mask
    // R10 item 2, row 1 ("Depth handoff"): 1 = write ONE constant depth for
    // every covered pixel instead of the converted engine depth, so the
    // compositor's reprojection has nothing per-pixel to shear on. Coverage is
    // untouched (it still comes from the real depth buffer), so the only thing
    // that changes is what CompositorServices reprojects with.
    float flatDepth;
    // R10 item 4 — WHY YOUR OWN ITEMS LOOK FAINT.
    // The world blit composites the eye texture with SOURCE-ALPHA blending, so
    // a pixel the engine drew at partial coverage is mixed with whatever is
    // behind it. In FIRST PERSON what is behind it is the surroundings DIM
    // WASH — solid black at dim = 1.0 — so every alpha-blended sprite (the
    // orbiting shells, the trailing banana, smoke, sparkles) is multiplied
    // toward black and reads as washed out. In the flat game those same
    // sprites blend against the SCENE, because the engine composited them
    // there itself. The eye texture already contains that composite; all the
    // second blend does is dim it a second time.
    // So in a FULLY DIMMED mode — where there is by definition no passthrough
    // to key against — coverage is forced to 1 and the eye texture is shown as
    // the engine drew it. Diorama and any partially-dimmed mode are unchanged
    // by construction (this is 0 unless dim >= 0.999).
    float forceOpaque;
    // R11 review finding: 1 = the engine is stamping the frame-tag strip into
    // the eye texture's top-left 8x1 texels, so hide that strip at DISPLAY
    // time (see sohvr_world_fs). Mirrors gSohVREyeTagOn exactly — when the
    // tags are off there is nothing to hide and the remap must not run.
    float tagMask;
} SohVRBlitParams;

static id<MTLRenderPipelineState> sSohVRWorldPipe;
static id<MTLRenderPipelineState> sSohVRPlanePipe;
static id<MTLRenderPipelineState> sSohVRDimPipe;
static id<MTLDepthStencilState> sSohVRWorldDepth;
static id<MTLDepthStencilState> sSohVRPlaneDepth;

static NSString* const kSohVRShader =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VROut { float4 pos [[position]]; float2 uv; };\n"
     "struct VRFrag { float4 color [[color(0)]]; float depth [[depth(any)]]; };\n"
     "struct VRParams { float engNear; float engFar; float compNear; float compFar;\n"
     "                  float compFarInfinite; float srgbDecode; float hasDepth; float dbgMode;\n"
     "                  float useAlphaCov; float flatDepth; float forceOpaque; float tagMask; };\n"
     "// Forward-Z [0,1] (near->0) back to view distance, then out in the\n"
     "// compositor's reverse-Z convention (1 near, 0 far).\n"
     "static inline float vr_convert_depth(float d, constant VRParams& p) {\n"
     "  float den = p.engFar - d * (p.engFar - p.engNear);\n"
     "  if (den < 1e-6) { return 0.0; }\n"
     "  float z = p.engFar * p.engNear / den;\n"
     "  float r = p.compFarInfinite > 0.5 ? (p.compNear / max(z, 1e-6))\n"
     "                                    : ((p.compNear / (p.compNear - p.compFar)) *\n"
     "                                       (1.0 - p.compFar / max(z, 1e-6)));\n"
     "  return clamp(r, 0.0, 1.0);\n"
     "}\n"
     "vertex VROut sohvr_fs_vs(uint vid [[vertex_id]]) {\n"
     "  const float2 p[3] = { float2(-1,-3), float2(3,1), float2(-1,1) };\n"
     "  VROut o; o.pos = float4(p[vid], 0.5, 1.0);\n"
     "  o.uv = float2((p[vid].x+1.0)*0.5, 1.0-(p[vid].y+1.0)*0.5);\n"
     "  return o;\n"
     "}\n"
     "fragment VRFrag sohvr_world_fs(VROut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
     "                               depth2d<float> dep [[texture(1)]],\n"
     "                               constant VRParams& p [[buffer(0)]]) {\n"
     "  constexpr sampler s(filter::linear);\n"
     "  constexpr sampler sd(filter::nearest);\n"
     "  // R11 review finding: the frame-tag strip (overlay 0044 rev5 stamps the\n"
     "  // pose tag's low byte into eight texels at the TEXTURE ORIGIN, which is\n"
     "  // the top-left of the visible image) must stay in the pixels -- it is\n"
     "  // the compositor's only independent proof that the eye it is about to\n"
     "  // show is the eye it thinks it bound. But it must not be SEEN. It cannot\n"
     "  // be scrubbed out of the texture either: the tag read-back blit is\n"
     "  // encoded against this same texture (sohvr_tag_probe, earlier in this\n"
     "  // very command buffer) and reads the real texels directly, not through\n"
     "  // this shader, so anything that rewrote them would blind the probe.\n"
     "  // So the strip is hidden HERE, at sample time: over its footprint we\n"
     "  // sample a neighbouring texel instead, and the corner shows a duplicate\n"
     "  // of its own surroundings -- nine pixels, one pixel tall, at eye\n"
     "  // resolution. The neighbour is taken ALONG THE ROW (texel 11 of row 0),\n"
     "  // not from the row below: measured on the sim, the eye framebuffer's\n"
     "  // row 0 is a black edge row while row 1 is already scene content, so\n"
     "  // sampling downwards traded a flickering strip for a static coloured\n"
     "  // notch in an otherwise black row. Copying along the row makes the strip\n"
     "  // indistinguishable from the rest of the row it lives in, whatever that\n"
     "  // row happens to be. The footprint is widened past texel 8 (and through\n"
     "  // row 1) so the linear filter cannot bleed a tag texel in from just\n"
     "  // outside it, and the replacement column is far enough right that its\n"
     "  // own filter neighbourhood is tag-free.\n"
     "  // Gated on tagMask == gSohVREyeTagOn: with the tags off the image is\n"
     "  // untouched, byte for byte.\n"
     "  float2 uv = in.uv;\n"
     "  if (p.tagMask > 0.5) {\n"
     "    float tw = float(max(tex.get_width(), 24u));\n"
     "    float th = float(max(tex.get_height(), 2u));\n"
     "    if (uv.x < 9.5 / tw && uv.y < 1.5 / th) { uv.x = 11.5 / tw; }\n"
     "  }\n"
     "  float4 c = tex.sample(s, uv);\n"
     "  if (p.srgbDecode > 0.5) { c.rgb = pow(c.rgb, float3(2.2)); }\n"
     "  // Depth keeps the UNREMAPPED uv: only the colour texture carries a tag,\n"
     "  // so coverage stays exact everywhere including under the strip.\n"
     "  float d = p.hasDepth > 0.5 ? dep.sample(sd, in.uv) : 1.0;\n"
     "  VRFrag o;\n"
     "  // Coverage comes from DEPTH, and ONLY from depth. The engine's colour\n"
     "  // alpha is not usable as a mask here: measured on the sim, the eye\n"
     "  // framebuffer comes back with alpha 1 across the whole background even\n"
     "  // though the depth buffer is still at its clear value there, so some\n"
     "  // full-screen depth-less paint is running after the (alpha-0) clear.\n"
     "  // The depth buffer says exactly what the engine actually drew, which is\n"
     "  // the question a coverage mask is asking. Cost: content drawn with depth\n"
     "  // writes off does not composite in VR — nothing in a race frame does\n"
     "  // today, and the HUD (which is all of it) rides its own plane.\n"
     "  float cov = (d < 0.999999) ? 1.0 : 0.0;\n"
     "  // R2: with overlay 0034 rev2 the VR framebuffers write TRUE destination\n"
     "  // alpha, so the colour alpha is an honest coverage mask again — and it\n"
     "  // is the ONLY one that sees content drawn with depth writes off, which\n"
     "  // is exactly what MK64's sky is. useAlphaCov is per view mode: on for\n"
     "  // first-person (sky in-eye), off for Diorama so R1's passthrough\n"
     "  // behaviour is unchanged by construction.\n"
     "  if (p.useAlphaCov > 0.5) { cov = max(cov, c.a); }\n"
     "  // R10 item 4: fully dimmed modes show the engine's own composite.\n"
     "  if (p.forceOpaque > 0.5) { cov = 1.0; }\n"
     "  o.color = float4(c.rgb, cov);\n"
     "  o.depth = vr_convert_depth(d, p);\n"
     "  // R10 item 2, row 1: one constant depth at 8 m, in the compositor's own\n"
     "  // reverse-Z convention. Far enough that the HUD/rear-view planes still\n"
     "  // win the depth test in front of it.\n"
     "  if (p.flatDepth > 0.5) {\n"
     "    float zf = 8.0;\n"
     "    o.depth = p.compFarInfinite > 0.5 ? (p.compNear / zf)\n"
     "                                      : ((p.compNear / (p.compNear - p.compFar)) *\n"
     "                                         (1.0 - p.compFar / zf));\n"
     "    o.depth = clamp(o.depth, 0.0, 1.0);\n"
     "  }\n"
     "  // D11 diagnostics (`vr set dbg N`): 1 = uniform half coverage (does the\n"
     "  // room show through at all?), 2 = the engine depth we were handed,\n"
     "  // 3 = the engine colour alpha. Never on in a normal frame.\n"
     "  if (p.dbgMode > 0.5 && p.dbgMode < 3.5) {\n"
     "    if (p.dbgMode < 1.5) { o.color = float4(c.rgb, 0.35); }\n"
     "    else if (p.dbgMode < 2.5) { o.color = float4(d, d, d, 1.0); }\n"
     "    else { o.color = float4(c.a, c.a, c.a, 1.0); }\n"
     "  }\n"
     "  return o;\n"
     "}\n"
     "vertex VROut sohvr_plane_vs(uint vid [[vertex_id]], constant float4x4& mvp [[buffer(0)]]) {\n"
     "  const float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
     "  VROut o; o.pos = mvp * float4(p[vid], 0.0, 1.0);\n"
     "  o.uv = float2((p[vid].x+1.0)*0.5, 1.0-(p[vid].y+1.0)*0.5);\n"
     "  return o;\n"
     "}\n"
     "// Surroundings dim for VR WORLD frames (spec D3): a full-slice black\n"
     "// wash written at the REVERSE-Z far plane (0.0) so every later pass wins\n"
     "// the depth test, and contributing real alpha so `.mixed` passthrough is\n"
     "// covered rather than merely darkened. First-person defaults to 1.0.\n"
     "vertex float4 sohvr_dim_vs(uint vid [[vertex_id]]) {\n"
     "  const float2 p[3] = { float2(-1,-3), float2(3,1), float2(-1,1) };\n"
     "  return float4(p[vid], 0.0, 1.0);\n"
     "}\n"
     "fragment float4 sohvr_dim_fs(constant float& dim [[buffer(0)]]) {\n"
     "  return float4(0.0, 0.0, 0.0, dim);\n"
     "}\n"
     "fragment float4 sohvr_plane_fs(VROut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
     "                               constant float4& params [[buffer(0)]],\n"
     "                               constant float2& pflags [[buffer(1)]]) {\n"
     "  constexpr sampler s(filter::linear);\n"
     "  // R3 (spec D12): pflags.x flips U so the rear-view pane reads as a\n"
     "  // MIRROR (a kart on your right appears on the right) rather than as a\n"
     "  // reversing camera. The engine renders a true rear view with correct\n"
     "  // winding; the convention is applied here, where it is free.\n"
     "  float2 uv = float2(pflags.x > 0.5 ? (1.0 - in.uv.x) : in.uv.x, in.uv.y);\n"
     "  // R11 item 4: ROUNDED CORNERS (params.w, in units of the plane's half\n"
     "  // HEIGHT; 0 = square, which is every plane but the rear-view pane). A\n"
     "  // rounded-rectangle SDF in the plane's own aspect, and the corner is a\n"
     "  // discard rather than an alpha ramp because the pane composites OPAQUE\n"
     "  // — an alpha ramp there would be a grey fringe, not a soft edge.\n"
     "  if (params.w > 0.001) {\n"
     "    float ar = float(tex.get_width()) / float(max(tex.get_height(), 1u));\n"
     "    float2 p = (uv - 0.5) * 2.0 * float2(ar, 1.0);\n"
     "    float2 b = float2(ar, 1.0) - params.w;\n"
     "    float2 d = abs(p) - b;\n"
     "    if (length(max(d, 0.0)) - params.w > 0.0) { discard_fragment(); }\n"
     "  }\n"
     "  float4 c = tex.sample(s, uv);\n"
     "  // pflags.y: composite as an OPAQUE panel. The pane is a physical mirror\n"
     "  // housing, not a coverage mask — the sky and anything else drawn with\n"
     "  // depth writes off must not punch holes in it.\n"
     "  if (pflags.y > 0.5) {\n"
     "    if (params.x > 0.5) { c.rgb = pow(c.rgb, float3(2.2)); }\n"
     "    return float4(c.rgb, 1.0);\n"
     "  }\n"
     "  if (params.x > 0.5) { c.rgb = pow(c.rgb, float3(2.2)); }\n"
     "  // D11 (`vr set dbg N`): 4 = solid magenta (is the plane placed and\n"
     "  // passing the depth test at all?), 5 = the plane texture, opaque (is\n"
     "  // there anything in the HUD framebuffer?).\n"
     "  if (params.y > 3.5 && params.y < 4.5) { return float4(1.0, 0.0, 1.0, 1.0); }\n"
     "  if (params.y > 4.5) { return float4(c.rgb, 1.0); }\n"
     "  // R1 keyed the plane off LUMINANCE, because the N64 blender LUS\n"
     "  // emulates left destination alpha at the clear value and pure-black HUD\n"
     "  // pixels (glyph outlines) therefore dropped out. R2 does the real fix:\n"
     "  // overlay 0034 rev2 gives the VR framebuffers a pipeline whose ALPHA\n"
     "  // blend actually accumulates coverage (src One / dst OneMinusSrcAlpha),\n"
     "  // so c.a is the true mask. params.x's sign carries the choice: >= 2 =\n"
     "  // trust alpha, 0 = the R1 luminance key (kept as the fallback the\n"
     "  // Diorama path and any pipeline-compile failure land on). params.y is\n"
     "  // the dbg blit mode, params.z the alpha-coverage choice.\n"
     "  if (params.z > 0.5) { return float4(c.rgb, c.a); }\n"
     "  float lum = max(c.r, max(c.g, c.b));\n"
     "  return float4(c.rgb, max(c.a, smoothstep(0.0, 0.05, lum)));\n"
     "}\n";

static void sohvr_build_pipelines(id<MTLDevice> dev, MTLPixelFormat colorFmt, MTLPixelFormat depthFmt) {
    NSError* err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kSohVRShader options:nil error:&err];
    if (!lib) {
        NSLog(@"[SohVR] shader compile FAILED: %@", err.localizedDescription);
        return;
    }
    MTLRenderPipelineDescriptor* wd = [MTLRenderPipelineDescriptor new];
    wd.vertexFunction = [lib newFunctionWithName:@"sohvr_fs_vs"];
    wd.fragmentFunction = [lib newFunctionWithName:@"sohvr_world_fs"];
    wd.colorAttachments[0].pixelFormat = colorFmt;
    // Alpha 0 where the engine drew nothing: .mixed then shows the room around
    // the diorama (R0 finding 3; the engine-side half is 0044's clear colour).
    wd.colorAttachments[0].blendingEnabled = YES;
    wd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    wd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    wd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    wd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    wd.depthAttachmentPixelFormat = depthFmt;
    sSohVRWorldPipe = [dev newRenderPipelineStateWithDescriptor:wd error:&err];
    if (!sSohVRWorldPipe) {
        NSLog(@"[SohVR] world pipeline FAILED: %@", err.localizedDescription);
    }

    MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"sohvr_plane_vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"sohvr_plane_fs"];
    pd.colorAttachments[0].pixelFormat = colorFmt;
    pd.colorAttachments[0].blendingEnabled = YES;
    pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pd.depthAttachmentPixelFormat = depthFmt;
    sSohVRPlanePipe = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!sSohVRPlanePipe) {
        NSLog(@"[SohVR] plane pipeline FAILED: %@", err.localizedDescription);
    }

    MTLRenderPipelineDescriptor* dd0 = [MTLRenderPipelineDescriptor new];
    dd0.vertexFunction = [lib newFunctionWithName:@"sohvr_dim_vs"];
    dd0.fragmentFunction = [lib newFunctionWithName:@"sohvr_dim_fs"];
    dd0.colorAttachments[0].pixelFormat = colorFmt;
    dd0.colorAttachments[0].blendingEnabled = YES;
    dd0.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    dd0.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    dd0.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    dd0.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    dd0.depthAttachmentPixelFormat = depthFmt;
    sSohVRDimPipe = [dev newRenderPipelineStateWithDescriptor:dd0 error:&err];
    if (!sSohVRDimPipe) {
        NSLog(@"[SohVR] dim pipeline FAILED: %@", err.localizedDescription);
    }

    MTLDepthStencilDescriptor* wdd = [MTLDepthStencilDescriptor new];
    wdd.depthCompareFunction = MTLCompareFunctionAlways;
    wdd.depthWriteEnabled = YES; // the compositor reprojects on depth
    sSohVRWorldDepth = [dev newDepthStencilStateWithDescriptor:wdd];

    MTLDepthStencilDescriptor* pdd = [MTLDepthStencilDescriptor new];
    // Reverse-Z: nearer is GREATER. The plane therefore occludes the world
    // only where it really is in front of it, and vice versa.
    pdd.depthCompareFunction = MTLCompareFunctionGreater;
    pdd.depthWriteEnabled = YES;
    sSohVRPlaneDepth = [dev newDepthStencilStateWithDescriptor:pdd];
    NSLog(@"[SohVR] pipelines built (colorFmt=%lu depthFmt=%lu)", (unsigned long)colorFmt,
          (unsigned long)depthFmt);
}

static id<MTLTexture> sSohVRDummyDepth;
static id<MTLTexture> sohvr_dummy_depth(id<MTLDevice> dev) {
    if (sSohVRDummyDepth == nil) {
        MTLTextureDescriptor* td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                               width:1
                                                              height:1
                                                           mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        sSohVRDummyDepth = [dev newTextureWithDescriptor:td];
    }
    return sSohVRDummyDepth;
}

static float sohvr_srgb_decode(MTLPixelFormat src, MTLPixelFormat dst) {
    BOOL srcEncoded = (src == MTLPixelFormatBGRA8Unorm || src == MTLPixelFormatRGBA8Unorm);
    BOOL dstLinear = (dst == MTLPixelFormatBGRA8Unorm_sRGB || dst == MTLPixelFormatRGBA8Unorm_sRGB ||
                      dst == MTLPixelFormatRGBA16Float);
    return (srcEncoded && dstLinear) ? 1.0f : 0.0f;
}

// A texture on a plane in PLAYER space (spec D6 now, D12's rear-view pane
// later — keep it general). The plane hangs off the entry anchor, not the live
// head: head-locked 2D is the diplopia/comfort trap B10 warns about, and a
// player-space plane is what the rear-view pane will want too.
// R3 generalises it two ways the rear-view pane needs and the HUD does not: a
// LATERAL offset (the pane hangs off to the side of gaze, the HUD is centred)
// and the two composite flags (mirror the image, composite opaque). Both are
// inert at their defaults, so the HUD's behaviour is unchanged.
static void sohvr_draw_plane_ex(id<MTLRenderCommandEncoder> enc, simd_float4x4 eyeFromOrigin, simd_float4x4 proj,
                                id<MTLTexture> tex, float xoff, float dist, float height, float scale,
                                MTLPixelFormat dstFmt, int flipU, int opaque, float corner, int depthAlways) {
    // R10 item 2, row 7 ("HUD & panes"): the HUD plane, the rear-view pane and
    // the item chip all come through here and through sohvr_draw_plane_at, and
    // nothing else does — so one guard in each turns the whole plane stack off.
    if (tex == nil || sSohVRPlanePipe == nil || sohvr_diag_off(SOHVR_DIAG_PANES)) {
        return;
    }
    float aspect = (tex.height > 0) ? (float)tex.width / (float)tex.height : (16.0f / 9.0f);
    float halfW = 0.5f * dist * scale;
    float halfH = (aspect > 1e-3f) ? halfW / aspect : halfW;
    simd_float4x4 model = simd_mul(sSohVRAnchor, soh3d_translate(xoff, height, -dist));
    model = simd_mul(model, soh3d_scale(halfW, halfH, 1.0f));
    simd_float4x4 mvp = simd_mul(proj, simd_mul(eyeFromOrigin, model));
    simd_float4 planeParams =
        simd_make_float4(sohvr_srgb_decode(tex.pixelFormat, dstFmt), (float)sSohVRDbgMode,
                         sSohVRCfg[sSohVRView].alphaCov ? 1.0f : 0.0f, corner);
    simd_float2 planeFlags = simd_make_float2(flipU ? 1.0f : 0.0f, opaque ? 1.0f : 0.0f);
    [enc setRenderPipelineState:sSohVRPlanePipe];
    // dbg >= 4 also drops the depth test, so "placed but occluded" and "not
    // drawn at all" are distinguishable.
    // R10 item 3b: `opaque` is only ever set for the REAR-VIEW PANE, and it
    // already means "a physical panel, not a coverage mask". It now also
    // means the panel draws ON TOP: the pane is the last thing encoded, so a
    // depth-Always state puts it above the HUD plane whatever their relative
    // distances are. Without this, aiming the pane anywhere the HUD reaches
    // SLICES it (artifacts/vr-r10/user-rearview-clipped-by-hud.png) — the
    // pane sat 15 cm behind the HUD plane and lost the reverse-Z test.
    // R13 item 2b — DEPTH AND COMPOSITING ARE NO LONGER THE SAME FLAG. They
    // were, and that is why R11 item 5 could not be implemented: the HUD needed
    // depth-ALWAYS (so lowering third-person Height stops burying the place
    // indicator and the minimap in the road) but must NOT become an opaque
    // billboard, and `opaque` forced both at once. Commit 4c54576 claimed the
    // change and only added a corner argument, so the HUD has been drawing
    // depth-Greater ever since and the ground clip was never fixed.
    [enc setDepthStencilState:((sSohVRDbgMode >= 4 || opaque || depthAlways) ? sSohVRWorldDepth
                                                                            : sSohVRPlaneDepth)];
    [enc setVertexBytes:&mvp length:sizeof(mvp) atIndex:0];
    [enc setFragmentBytes:&planeParams length:sizeof(planeParams) atIndex:0];
    [enc setFragmentBytes:&planeFlags length:sizeof(planeFlags) atIndex:1];
    [enc setFragmentTexture:tex atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

static void sohvr_draw_plane(id<MTLRenderCommandEncoder> enc, simd_float4x4 eyeFromOrigin, simd_float4x4 proj,
                             id<MTLTexture> tex, float dist, float height, float scale,
                             MTLPixelFormat dstFmt) {
    // R11 item 5 (user-3rdperson-hud-ground-clip.png): the HUD plane draws
    // DEPTH-ALWAYS, exactly like the rear-view pane. Lowering the third-person
    // Height row sinks the plane into the track and the place indicator and the
    // minimap were being eaten by the road. A HUD is not world geometry; it has
    // no business losing a depth test to it, and the plane is encoded after the
    // world blit so "always" means "on top".
    sohvr_draw_plane_ex(enc, eyeFromOrigin, proj, tex, 0.0f, dist, height, scale, dstFmt, 0, 0, 0.0f, 1);
}

// R4: the same plane, placed by an arbitrary ORIGIN-frame pose instead of an
// offset in the entry anchor's frame. The wrist mirror and the item in hand are
// both "a texture on a plane" exactly like the HUD and the rear-view pane —
// they just get their pose from a Sense controller rather than from a tunable.
// `halfW` is in metres (the plane's half-width); the height follows the
// texture's aspect, as everywhere else.
static void sohvr_draw_plane_at(id<MTLRenderCommandEncoder> enc, simd_float4x4 eyeFromOrigin, simd_float4x4 proj,
                                id<MTLTexture> tex, simd_float4x4 originFromPlane, float halfW,
                                MTLPixelFormat dstFmt, int flipU, int opaque, float corner, int depthAlways) {
    if (tex == nil || sSohVRPlanePipe == nil || halfW <= 0.0f || sohvr_diag_off(SOHVR_DIAG_PANES)) {
        return;
    }
    float aspect = (tex.height > 0) ? (float)tex.width / (float)tex.height : 1.0f;
    float halfH = (aspect > 1e-3f) ? halfW / aspect : halfW;
    simd_float4x4 model = simd_mul(originFromPlane, soh3d_scale(halfW, halfH, 1.0f));
    simd_float4x4 mvp = simd_mul(proj, simd_mul(eyeFromOrigin, model));
    simd_float4 planeParams =
        simd_make_float4(sohvr_srgb_decode(tex.pixelFormat, dstFmt), (float)sSohVRDbgMode,
                         sSohVRCfg[sSohVRView].alphaCov ? 1.0f : 0.0f, corner);
    simd_float2 planeFlags = simd_make_float2(flipU ? 1.0f : 0.0f, opaque ? 1.0f : 0.0f);
    [enc setRenderPipelineState:sSohVRPlanePipe];
    // R10 item 3b: `opaque` is only ever set for the REAR-VIEW PANE, and it
    // already means "a physical panel, not a coverage mask". It now also
    // means the panel draws ON TOP: the pane is the last thing encoded, so a
    // depth-Always state puts it above the HUD plane whatever their relative
    // distances are. Without this, aiming the pane anywhere the HUD reaches
    // SLICES it (artifacts/vr-r10/user-rearview-clipped-by-hud.png) — the
    // pane sat 15 cm behind the HUD plane and lost the reverse-Z test.
    // R13 item 2b — DEPTH AND COMPOSITING ARE NO LONGER THE SAME FLAG. They
    // were, and that is why R11 item 5 could not be implemented: the HUD needed
    // depth-ALWAYS (so lowering third-person Height stops burying the place
    // indicator and the minimap in the road) but must NOT become an opaque
    // billboard, and `opaque` forced both at once. Commit 4c54576 claimed the
    // change and only added a corner argument, so the HUD has been drawing
    // depth-Greater ever since and the ground clip was never fixed.
    [enc setDepthStencilState:((sSohVRDbgMode >= 4 || opaque || depthAlways) ? sSohVRWorldDepth
                                                                            : sSohVRPlaneDepth)];
    [enc setVertexBytes:&mvp length:sizeof(mvp) atIndex:0];
    [enc setFragmentBytes:&planeParams length:sizeof(planeParams) atIndex:0];
    [enc setFragmentBytes:&planeFlags length:sizeof(planeFlags) atIndex:1];
    [enc setFragmentTexture:tex atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

// The held item's stand-in art (spec D13 "item in hand"). MK64's item
// sprites live inside a display list the engine builds once per host frame, so
// they cannot be sampled as a standalone texture without an engine-side export
// — that export is the round's ONE deferred seam (VR-R4-NOTES §6). Until it
// lands, the item renders as a soft disc tinted by item id: the POSE, the
// gating and the gesture are all real and tunable in the headset; only the art
// is a placeholder, and it is labelled as such everywhere it appears.
static id<MTLTexture> sSohVRItemChip;
static int sSohVRItemChipId = -1;
static id<MTLTexture> sohvr_item_chip(id<MTLDevice> dev, int itemId) {
    if (sSohVRItemChip != nil && sSohVRItemChipId == itemId) {
        return sSohVRItemChip;
    }
    // MK64 item ids (include/enums.h ITEM_*): the colours are the recognisable
    // ones so a glance at your hand says which item you are carrying.
    float r = 0.9f, g = 0.9f, b = 0.9f;
    switch (itemId) {
        case 1: r = 0.15f; g = 0.85f; b = 0.25f; break;  // green shell
        case 2: r = 0.90f; g = 0.15f; b = 0.15f; break;  // red shell
        case 3: r = 0.95f; g = 0.85f; b = 0.20f; break;  // banana
        case 4: r = 0.85f; g = 0.75f; b = 0.15f; break;  // banana bunch
        case 5: case 6: case 7: r = 0.95f; g = 0.55f; b = 0.55f; break; // mushrooms
        case 8: r = 0.95f; g = 0.85f; b = 0.55f; break;  // super mushroom
        case 9: r = 0.65f; g = 0.65f; b = 0.95f; break;  // boo
        case 10: r = 0.98f; g = 0.90f; b = 0.30f; break; // star
        case 11: r = 0.55f; g = 0.55f; b = 0.95f; break; // thunderbolt
        case 12: r = 0.75f; g = 0.55f; b = 0.25f; break; // fake item box
        default: break;
    }
    const int N = 64;
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:N
                                                                                 height:N
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    uint8_t* px = (uint8_t*)malloc((size_t)N * N * 4);
    if (px == NULL) {
        return nil;
    }
    for (int y = 0; y < N; y++) {
        for (int x = 0; x < N; x++) {
            float dx = (x + 0.5f) / N - 0.5f, dy = (y + 0.5f) / N - 0.5f;
            float d = sqrtf(dx * dx + dy * dy) * 2.0f;
            float a = (d >= 1.0f) ? 0.0f : (d < 0.82f ? 1.0f : (1.0f - (d - 0.82f) / 0.18f));
            float k = 1.0f - 0.35f * d; // a cheap highlight so it reads as round
            uint8_t* p = &px[(y * N + x) * 4];
            p[0] = (uint8_t)(255.0f * r * k * a);
            p[1] = (uint8_t)(255.0f * g * k * a);
            p[2] = (uint8_t)(255.0f * b * k * a);
            p[3] = (uint8_t)(255.0f * a);
        }
    }
    [t replaceRegion:MTLRegionMake2D(0, 0, N, N) mipmapLevel:0 withBytes:px bytesPerRow:N * 4];
    free(px);
    sSohVRItemChip = t;
    sSohVRItemChipId = itemId;
    return t;
}

void SohVR_Immersive_Run(cp_layer_renderer_t layer_renderer) {
    gSoh3DStop = 0;
    gSoh3DRunning = 1;
    gSohVRWorldActive = 0;
    int notifyEnded = 0;
    id<MTLCommandQueue> queue = nil;
    sSohVRLoopFrames = sSohVRLoopWorldFrames = sSohVRLoopPanelFrames = 0;
    sSohVRTimeouts = 0;
    // R5 (bug 1): every VR entry re-bases from scratch, and world frames wait
    // for the capture. Mid-race entry is therefore identical to entry at the
    // start line — the asymmetry the user saw on the first device round is
    // structurally impossible now, not merely unlikely.
    sSohVRHaveAnchor = 0;
    sSohVRBaseValid = 0;
    sSohVRRebaseReq = 1;
    sSohVRBaseRejects = 0;
    sSohVRBaseForced = 0;
    sSohVRRecenters = 0;
    sSohVRAnchor = matrix_identity_float4x4;
    soh3d_haveScreenAnchor = false;
    soh3d_eyeCopy[0] = soh3d_eyeCopy[1] = nil;
    for (int i = 0; i < SOHVR_RING; i++) {
        sSohVRRing[i] = nil;
        sSohVRRingId[i] = 0;
    }
    ar_device_anchor_t lastGoodAnchor = nil;
    sSohVRHaveHeldYaw = 0; // comfort filter re-seats on every VR entry (A6)
    sSohVRSpinBlend = 1.0f;
    sSohVRSpinEvents = 0;
    sSohVRLastWorldTime = 0.0;
    sSohVRMirrorVisible = 0;
    sSohVRMirrorHold = 0;
    sSohVRMirrorTopOn = sSohVRMirrorTop; // the latch re-arms on every VR entry
    sSohVRPaneTopLive = sSohVRPaneHandLive = 0;
    sSohVRMirrorShows = sSohVRTopToggles = sSohVRMirrorFrames = 0;
    gSohVRMirrorActive = 0;
    {
        // Settings first (spec D10): the persisted view mode, surroundings
        // and planes are what this session opens with, not last session's
        // in-memory state.
        extern void SohVR_SettingsApply(void);
        SohVR_SettingsApply();
    }
    SohVR_ApplySurroundings(); // the entry view's surroundings choice (D3)

    ar_world_tracking_configuration_t wtc = ar_world_tracking_configuration_create();
    ar_world_tracking_provider_t wtp = ar_world_tracking_provider_create(wtc);
    ar_session_t arSession = ar_session_create();
    ar_data_providers_t providers = ar_data_providers_create_with_data_providers(wtp, NULL);
    ar_session_run(arSession, providers);
    NSLog(@"[SohVR] render loop started (ARKit world tracking running)");
    // R4: the Sense backend comes up with the loop and goes down with it — its
    // accessory tracking rides its OWN ar_session (SohSense.m explains why), so
    // nothing it does can disturb the world tracking above.
    SohSense_Start();

    int running = 1;
    while (running) {
        if (gSoh3DStop) {
            NSLog(@"[SohVR] stop requested, exiting cleanly (frames=%d world=%d panel=%d)", sSohVRLoopFrames,
                  sSohVRLoopWorldFrames, sSohVRLoopPanelFrames);
            running = 0;
            continue;
        }
        switch (cp_layer_renderer_get_state(layer_renderer)) {
            case cp_layer_renderer_state_paused:
                cp_layer_renderer_wait_until_running(layer_renderer);
                continue;
            case cp_layer_renderer_state_invalidated:
                NSLog(@"[SohVR] layer invalidated, exiting loop (frames=%d)", sSohVRLoopFrames);
                notifyEnded = 1;
                running = 0;
                continue;
            case cp_layer_renderer_state_running:
            default:
                break;
        }

        @autoreleasepool {
            cp_frame_t frame = cp_layer_renderer_query_next_frame(layer_renderer);
            if (frame == NULL) {
                continue;
            }
            cp_frame_timing_t timing = cp_frame_predict_timing(frame);
            cp_frame_start_update(frame);
            cp_frame_end_update(frame);
            cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));
            cp_frame_start_submission(frame);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            cp_drawable_t drawable = cp_frame_query_drawable(frame);
#pragma clang diagnostic pop
            if (drawable == NULL) {
                // A failed drawable query invalidates the frame; end_submission
                // on it ABORTS. Drop it, exactly as the panel loop does.
                continue;
            }

            if (queue == nil) {
                id<MTLTexture> t0 = cp_drawable_get_color_texture(drawable, 0);
                queue = [t0.device newCommandQueue];
                sohvr_build_pipelines(t0.device, t0.pixelFormat,
                                      cp_drawable_get_depth_texture(drawable, 0).pixelFormat);
                soh3d_build_pipeline(t0.device, t0.pixelFormat,
                                     cp_drawable_get_depth_texture(drawable, 0).pixelFormat);
                sohvr_capture_contract(drawable);
                NSLog(@"[SohVR] CONTRACT %s", SohVR_DumpContract());
            }

            // --- pose: query once, at the frame's trackable-anchor time ------
            CFTimeInterval presTime = cp_time_to_cf_time_interval(
                cp_frame_timing_get_presentation_time(cp_drawable_get_frame_timing(drawable)));
            ar_device_anchor_t anchor = ar_device_anchor_create();
            ar_device_anchor_query_status_t anchorStatus =
                ar_world_tracking_provider_query_device_anchor_at_timestamp(wtp, presTime, anchor);
            simd_float4x4 originFromDevice = ar_device_anchor_get_origin_from_anchor_transform(anchor);
            int anchored = (anchorStatus == ar_device_anchor_query_status_success);

            // R5 (bug 1): publish the pose FIRST, so a pending re-base is
            // serviced by THIS frame's pose, and refuse a world frame until a
            // baseline exists. Entry-at-start and entry-mid-race then take the
            // identical path — neither can ever compose the world against the
            // raw ARKit origin (the floor of wherever the space opened).
            sohvr_publish_pose(originFromDevice, anchored);

            // --- world vs panel arbitration ----------------------------------
            int wantWorld = sohvr_world_frame_ok() && anchored && sSohVRBaseValid;
            // R14 item 5: every wantWorld transition releases and re-acquires
            // the VR eye extent, which is a full framebuffer resize on the
            // engine side (a quiesce plus two reallocations). One blip per lap
            // would be exactly the reported cadence.
            {
                static int sohWantPrev = -1;
                if (sohWantPrev >= 0 && wantWorld != sohWantPrev) {
                    sSohVRWorldFlaps++;
                }
                sohWantPrev = wantWorld;
            }
            if (!wantWorld && anchored && !sSohVRBaseValid) {
                sSohVRWorldReason = "rebasing";
            }
            gSohVRWorldActive = wantWorld;
            // R8 item 3 — THE 2D PANEL ASPECT REGRESSION, and its mechanism.
            //
            // the user, 1.0.0.4 retest: "the menu panel was correct on the first
            // launch, but quitting from a game back to the menu brings the
            // stretch back." Exactly so, and the owner arbitration says why.
            // The VR extent is claimed inside `if (wantWorld)` below, and it is
            // never given back: sSohEyeOwner stays OWNER_VR for the rest of the
            // session, so every later Soh3D_SetPanel is refused by the priority
            // rule and the PANEL FALLBACK — the flat game shown on a quad while
            // you are in a menu — keeps rendering at the VR eye's aspect.
            //
            // In the simulator the VR eye is 3840x2160 and the panel wants
            // 3840x2164, so the fault is four pixels wide and invisible. On
            // DEVICE the VR eye is 5087x4081 (aspect 1.25) and the panel quad
            // is ~1.77: the menu is squashed to three-quarters of its width and
            // stretched to fill. First launch is clean because wantWorld has
            // never been true yet, which is precisely the shape of his report.
            //
            // The extent is a per-frame lease now: VR holds it only while it is
            // actually drawing a world frame, and hands it straight back to the
            // panel the moment it is not. `eye_owner` in `vr pace` is the
            // assert (the sim cannot show this one in pixels).
            if (!wantWorld) {
                soh3d_release_vr_eye_extent();
            }
            {
                // Per-mode engine-side switches, republished every frame so a
                // live `vr view` switch takes effect on the next eye pass. All
                // of them are 0 outside VR world frames, so flat/panel builds
                // are untouched (the spec's non-negotiable).
                extern volatile int gSohVRSkyMode, gSohVREyeKey, gSohVRAngleCullOff;
                extern volatile int gSoh3DPaused;
                const SohVRViewCfg* cfg = &sSohVRCfg[sSohVRView];
                // R5 ladder level 1 (H-A): park and wipe the sky instead of
                // pinning it at the far plane.
                gSohVRSkyMode =
                    (wantWorld && cfg->sky && !sohvr_dbg_on(1) && !sohvr_diag_off(SOHVR_DIAG_SKY)) ? 1 : 0;
                // Trap A7: eye-facing derives from the composed eye matrix and
                // applies to WORLD frames only — never the panel fallback, and
                // never while the game is paused (the donor's pause screen
                // inherited eye-facing and broke; ours must not).
                gSohVREyeKey = (wantWorld && !gSoh3DPaused) ? 1 : 0;
                // R5 ladder level 2 (traps A3/A4): give MK64 its view-direction
                // culling back, so the course draws only what it was authored
                // to draw. Look-behind stops working — that is the trade the
                // probe is measuring.
                gSohVRAngleCullOff =
                    (wantWorld && !sohvr_dbg_on(2) && !sohvr_diag_off(SOHVR_DIAG_DRAWDIST)) ? 1 : 0;
                // R9 item 5: your own kart's billboard is suppressed in FIRST
                // PERSON world frames and nowhere else — not in Diorama, not in
                // third person, not on a panel frame, not in the flat game.
                // Overlay 0054 skips exactly the local player's quad; the
                // shadow, the drift particles and every ITEM you are carrying
                // (the orbiting triple shells, a trailing banana) still draw.
                extern volatile int gSohVRHideOwnKart;
                gSohVRHideOwnKart = (wantWorld && sSohVRView == SOHVR_VIEW_FP) ? 1 : 0;
                // R19 item 6 (overlay 0066): the same predicate, as its own
                // flag, for the start-line Lakitu push.
                extern volatile int gSohVRFpWorld;
                gSohVRFpWorld = (wantWorld && sSohVRView == SOHVR_VIEW_FP) ? 1 : 0;
            }

            if (wantWorld) {
                // Publish the eye pair for THIS pose under the shell's mutex
                // and park the anchor it was built from in the ring. (The pose
                // itself was published above, before the arbitration — R5.)
                {
                    double exW = sSohVRExtent[0][0], exH = sSohVRExtent[0][1];
                    // R6 — THE PACING BUG. Until this round the cap below was
                    // `#if TARGET_OS_SIMULATOR`, on the written assumption that
                    // "device extents are ~1920 and never hit this". The first
                    // live device contract pull says otherwise:
                    //
                    //   eye0_vp=5087x4081  engine_eye_fb=5086x4080  rscale=1.00
                    //
                    // 5086x4080 is 20.8 Mpix, rendered TWICE per host frame by
                    // the Fast3D interpreter — 41.5 Mpix of fill per frame, on
                    // a headset whose per-eye panel is 3660x3200 and whose
                    // compositor presents at 120 Hz. The engine was dragged to
                    // engine_fps=22.70 / tick_tps=45.39: the game ran at 75%
                    // speed in VR, which is exactly what the user has been
                    // playing. (The viewport is the drawable's PHYSICAL,
                    // pre-rasterization-rate-map size; the compositor's own
                    // render passes never rasterize all of it.)
                    //
                    // The cap is therefore unconditional, and it is a BUDGET
                    // (long edge in pixels), not a fraction — a fraction of an
                    // extent that turns out to be 5087 is how we got here. The
                    // render-scale slider still multiplies on top, so the user
                    // can trade sharpness for headroom either way.
                    // R9 item 7 — THE INSTRUMENT THAT MAKES THE LAP CLIP
                    // REPRODUCIBLE HERE. The clip is a function of the EYE
                    // ASPECT and nothing else: `K = 120*AR - 160` is negative
                    // only below 4:3, and the simulator's drawable is 3840x2160
                    // (AR 1.78, K = +53) while the device's eye is 5087x4081
                    // (AR 1.25, K = -10.4). So the sim cannot show the bug at
                    // its own aspect, and a green screenshot here would be
                    // trap-D11 vacuous. `vr set eyeaspect 1.246` reshapes the
                    // eye extent to the DEVICE's aspect, which reproduces the
                    // clipped LAP in the simulator exactly — and then proves the
                    // fix against it. Diagnostic only, never persisted, 0 = off.
                    if (sSohVREyeAspectDbg > 0.01f) {
                        exH = exW / (double)sSohVREyeAspectDbg;
                    }
                    if (exW > sSohVREyeBudget || exH > sSohVREyeBudget) {
                        double k = sSohVREyeBudget / (exW > exH ? exW : exH);
                        exW *= k;
                        exH *= k;
                        sSohVREyeClamped = 1;
                    } else {
                        sSohVREyeClamped = 0;
                    }
                    int w = (int)(exW * sSohVRRenderScale) & ~1;
                    int h = (int)(exH * sSohVRRenderScale) & ~1;
                    // Eye extents are their OWN sizing domain (trap D7): derived
                    // from the drawable's physical extent times the render
                    // scale, never from the flat pipeline's internal-res/SSAA.
                    sSohVREyeW = w;
                    sSohVREyeH = h;
                    soh3d_set_eye_extent(SOH_EYE_OWNER_VR, w, h);
                    // The rear-view pane's own sizing domain (trap D7): a
                    // fraction of the EYE extent per axis, so its aspect
                    // matches — the mirror walk reuses the game's own
                    // projection, which already carries the game's aspect, and
                    // a different aspect would stretch the image.
                    int mw = (int)(w * sSohVRMirrorRes) & ~1;
                    int mh = (int)(h * sSohVRMirrorRes) & ~1;
                    // R16-C step 3 — AND THE COMMENT ABOVE WAS WRONG (trap D46:
                    // a comment explaining why something is unnecessary outlives
                    // its truth). A fraction of the EYE extent per axis gives the
                    // pane the EYE's aspect, not the game's: the eye is 1.778 in
                    // this simulator and 1.246 on the device, while the walk
                    // replays the game's own projection, which carries
                    // gScreenAspect = 1.3333. So the pane has been stretched by
                    // 33% horizontally in the sim and squeezed by 7% on device
                    // for its whole life. The pane's target is sized at the
                    // GAME's aspect now — fixed in the SIZING domain rather than
                    // by scaling clip x, which would either pillarbox a quarter
                    // of the pane away or clip 7% off its sides.
                    extern volatile int gSohVRRearAspect;
                    extern volatile float gSoh3DCamAspect;
                    if (gSohVRRearAspect) {
                        float ga = gSoh3DCamAspect;
                        if (!(ga > 0.5f && ga < 4.0f)) {
                            ga = 1.33333334f;
                        }
                        // Reshape at CONSTANT AREA, not constant width: the
                        // pane's framebuffer is resident memory and the OOM
                        // question is live (STATUS: no crash file and no .ips =
                        // SIGKILL). Holding mw and deriving mh would have cost
                        // a third more pixels than 1.0.0.12 spent.
                        const double area = (double)mw * (double)mh;
                        mh = ((int)(sqrt(area / (double)ga) + 0.5)) & ~1;
                        mw = ((int)((double)mh * (double)ga + 0.5)) & ~1;
                    }
                    if (mw < 128) {
                        mw = 128;
                    }
                    if (mh < 128) {
                        mh = 128;
                    }
                    gSohVRMirrorW = mw;
                    gSohVRMirrorH = mh;
                }
                {
                    int wasVisible = sSohVRMirrorVisible;
                    // R14 item 3: ONE decision, two panes. See
                    // sohvr_mirror_decide — the flags it writes are what the
                    // draw site reads, so the draw can never want a pane the
                    // latch did not make the engine render (R13's lesson: the
                    // latch is the only thing that raises gSohVRMirrorActive,
                    // and without it a widened draw gets a NULL texture).
                    // spec D12's perf gate is kept in shape: world-active,
                    // and for the hand pane the controller actually tracked.
                    sohvr_mirror_decide(1);
                    sSohVRMirrorVisible = sohvr_mirror_should_show();
                    if (!sSohVRMirrorVisible) {
                        sSohVRPanePlacement = SOHVR_PANE_NONE;
                    }
                    if (sSohVRMirrorVisible && !wasVisible) {
                        sSohVRMirrorShows++;
                    }
                    if (sSohVRMirrorVisible) {
                        sSohVRMirrorFrames++;
                    }
                    // R11 item 4: the pane's placement is derived from the HUD
                    // row every frame, so a HUD drag, a mode switch or a Reset
                    // can never leave it stale (and cannot leave it hidden).
                    SohVR_PlacePane();
                    // The ONLY thing that makes the engine pay for a third
                    // walk. Cleared below on every non-world frame and on exit.
                    gSohVRMirrorActive = sSohVRMirrorVisible;
                }
                SohVR_ComposeEyes();
                float pub[32];
                for (int e = 0; e < 2; e++) {
                    const float* m = SohVR_GetEyeMatrix(e + 1);
                    for (int i = 0; i < 16; i++) {
                        pub[e * 16 + i] = m[i];
                    }
                }
                sSohVRFrameId++;
                if (sSohVRFrameId == 0) {
                    sSohVRFrameId = 1; // 0 means "nothing published"
                }
                unsigned int slot = sSohVRFrameId % SOHVR_RING;
                sSohVRRing[slot] = anchor;
                sSohVRRingId[slot] = sSohVRFrameId;
                // R16-A (F4): publish the WHOLE frame, not just the matrices.
                // SohVR_ComposeEyes has just written every field below from
                // this one head pose, so the snapshot is the frame's own
                // coherent description of itself — and the engine reads it in
                // one copy instead of sampling the globals live, per eye pass,
                // at 90-120 Hz (which is what made eye 0's sky and eye 1's sky
                // two different head poses inside one frame).
                {
                    SohVRFrameSnapshot snap;
                    memset(&snap, 0, sizeof(snap));
                    snap.id = sSohVRFrameId;
                    memcpy(snap.eyeM, pub, sizeof(snap.eyeM));
                    snap.skyShift[0] = gSohVRSkyShift[0];
                    snap.skyShift[1] = gSohVRSkyShift[1];
                    snap.skyPxPerBam = gSohVRSkyPxPerBam;
                    snap.skyPxCenter = gSohVRSkyPxCenter;
                    snap.eyeYawBam = gSohVREyeYawBam;
                    snap.eyePosGame[0] = gSohVREyePosGame[0];
                    snap.eyePosGame[1] = gSohVREyePosGame[1];
                    snap.eyePosGame[2] = gSohVREyePosGame[2];
                    snap.eyeFovDeg = gSohVREyeFovDeg;
                    snap.eyePitchDeg = gSohVREyePitchDeg;
                    snap.worldActive = gSohVRWorldActive;
                    // R16-B: the sprite layout's reference frustum and the
                    // per-eye remap ride in the SAME snapshot as the matrices
                    // they must agree with. That is M3 — the clouds were keyed
                    // to a pose the world never used — closed structurally
                    // rather than corrected numerically.
                    snap.skyTanSum = gSohVRSkyTanSum;
                    snap.skySpan = gSohVRSkySpan;
                    snap.skyEyeDx[0] = gSohVRSkyEyeDx[0];
                    snap.skyEyeDx[1] = gSohVRSkyEyeDx[1];
                    snap.skyEyeSx[0] = gSohVRSkyEyeSx[0];
                    snap.skyEyeSx[1] = gSohVRSkyEyeSx[1];
                    snap.skyTanLo = gSohVRSkyTanLo;
                    snap.skyTanHi = gSohVRSkyTanHi;
                    snap.skyRollRad[0] = gSohVRSkyRollRad[0];
                    snap.skyRollRad[1] = gSohVRSkyRollRad[1];
                    snap.skySpanY = gSohVRSkySpanY;
                    // R17-A item 1: the seat and the segment it is interpolated
                    // along, in the SAME latched copy as the matrices it was
                    // used to build (R16-A F4's rule -- one moment, one copy).
                    snap.seatGame[0] = sSohVRSeatGame.x;
                    snap.seatGame[1] = sSohVRSeatGame.y;
                    snap.seatGame[2] = sSohVRSeatGame.z;
                    snap.seatPrevDelta[0] = sSohVRSeatPrevDelta.x;
                    snap.seatPrevDelta[1] = sSohVRSeatPrevDelta.y;
                    snap.seatPrevDelta[2] = sSohVRSeatPrevDelta.z;
                    snap.seatSrc = sSohVRSeatFromKart;
                    snap.seatBase[0] = sSohVRSeatBase.x; // R18-A
                    snap.seatBase[1] = sSohVRSeatBase.y;
                    snap.seatBase[2] = sSohVRSeatBase.z;
                    snap.seatBaseFrame = sSohVRSeatBaseFrame;
                    SohIosVR_PublishFrame(&snap);
                }
            } else {
                sSohVRMirrorVisible = 0;
                sSohVRPanePlacement = SOHVR_PANE_NONE;
                sSohVRLeftHandLive = 0;
                gSohVRMirrorActive = 0; // no world frame, no third walk
                if (!soh3d_haveScreenAnchor && anchored && sSohVRLoopFrames > 30) {
                    soh3d_frozenHead = originFromDevice;
                    soh3d_haveScreenAnchor = true;
                    NSLog(@"[SohVR] panel fallback anchored (reason=%s)", sSohVRWorldReason);
                }
            }

            // R4: hand poses AFTER the eye pair is published — the gestures are
            // expressed against THIS frame's head pose, and polling first would
            // place this frame's hands with last frame's placement (a lag you
            // notice exactly while moving, which is when you look at your hands).
            SohSense_Update(presTime, originFromDevice, wantWorld);

            id<MTLCommandBuffer> cb = [queue commandBuffer];

            // --- source textures ---------------------------------------------
            //
            // R12 item 1 — LATCH, CLAIM, VERIFY. R11 latched the published
            // pointer and claimed it two statements later, and treated that gap
            // as if it were nothing. It is not nothing: the engine's handoff
            // gate can run inside it and see no claim on a slot this frame has
            // already decided to bind. Worse, the gate itself does not run at
            // the moment the slot is WRITTEN — the eye pass is only encoded at
            // Soh3DSetEye, and every eye framebuffer commits together at the
            // end of the host frame — so eye 0's gate is answered a full host
            // frame before its pixels land, and eye 1's half a frame before.
            // Three compositor frames fit in eye 0's window and one and a half
            // in eye 1's: same code, twice the exposure, artefact in view 0 =
            // the LEFT eye (trap D29 again, one level further out).
            //
            // The protocol is therefore a real handshake, both directions:
            //   1. latch the published (texture, depth, tag) triple;
            //   2. CLAIM the colour texture. SohVR_TexInUseAdd REFUSES if the
            //      engine has reserved that slot at its gate — the producer's
            //      half of the same table;
            //   3. VERIFY publication has not moved since the latch. If it has,
            //      drop the claim and go round again (bounded: publication
            //      changes at 30 Hz and we are at 90-100 Hz, so one retry is
            //      already generous).
            // On refusal or exhaustion we bind the LAST GOOD texture for that
            // eye — a coherent frame one publication old, which is the right
            // thing for a consumer to show while the producer is mid-write, and
            // is exactly what the rainbows are not.
            id<MTLTexture> eyeTex[2] = { nil, nil };
            id<MTLTexture> eyeDepth[2] = { nil, nil };
            unsigned int eyeBoundTag[2] = { 0, 0 };
            // R15 item 1: the POSE tag each latched texture was rendered for.
            // gSoh3DEyeStamp is a per-eye sequence and is not comparable across
            // eyes; gSoh3DEyeTag is the shell's own frame id, which BOTH eye
            // passes of one host frame render against — so it is the only thing
            // that can say "these two images are the same moment".
            unsigned int eyePoseTag[2] = { 0, 0 };
            int eyeFresh[2] = { 0, 0 };
            NSMutableArray<id<MTLTexture>>* held = [NSMutableArray arrayWithCapacity:8];
            for (int e = 0; e < 2; e++) {
                for (int tryN = 0; tryN < 4; tryN++) {
                    id<MTLTexture> t = (__bridge id<MTLTexture>)Soh3D_GetEyeMTLTexture(e + 1);
                    if (t == nil) {
                        break;
                    }
                    // The stress knob widens exactly this window (and nothing
                    // else) so the race can be reproduced in a simulator.
                    if (gSohVRCompDelayMs > 0) {
                        usleep((useconds_t)gSohVRCompDelayMs * 1000);
                    }
                    // R15 item 1's red control: model a refusal for this eye
                    // alone, which is the condition the device produces and the
                    // simulator otherwise never does.
                    if (gSohVRStaleForce & (1 << e)) {
                        gSohVRBindDefer[e] = gSohVRBindDefer[e] + 1;
                        break;
                    }
                    if (!SohVR_TexInUseAdd((__bridge void*)t)) {
                        gSohVRBindDefer[e] = gSohVRBindDefer[e] + 1;
                        break; // the engine owns it; fall through to last-good
                    }
                    // The STAMP is read AFTER the claim, never before. Reading
                    // it first is what R11 did with the pose tag, and it pairs
                    // a value from time T with pixels the engine may rewrite at
                    // T+n: measured 156 misses out of 156 checks under 150 ms
                    // of induced delay. Once the claim is recorded the engine's
                    // gate cannot re-enter the slot, so a stamp read here is
                    // stable for as long as we hold it. R12 reads the per-pass
                    // stamp rather than the pose tag because the pose tag stops
                    // changing whenever the compositor slows down — which is
                    // every condition this bug lives in.
                    unsigned int tag = gSoh3DEyeStamp[e];
                    // R16-A (F3.4, diagnosis A4): the POSE TAG and the DEPTH are
                    // read HERE, inside the window the verify below closes.
                    // They used to be read after it, and the publish handler
                    // writes depth before the stamp — so a publication landing
                    // between the verify and those two lines paired colour(N)
                    // with depth(N+1) and pose tag N+1 on one eye. Nanoseconds
                    // wide and 30 Hz deep, so not the reported symptom, but it
                    // is a genuine ordering defect and it is free to close.
                    unsigned int poseTag = gSoh3DEyeTag[e];
                    id<MTLTexture> tDepth = (__bridge id<MTLTexture>)gSoh3DEyeDepthTexture[e];
                    if (gSohVREngineOwnFix &&
                        ((__bridge void*)t != Soh3D_GetEyeMTLTexture(e + 1) ||
                         gSoh3DEyeStamp[e] != tag)) {
                        // Publication moved across the claim, so the stamp we
                        // just read may belong to a NEWER texture than the one
                        // we hold. Let it go and re-latch; publication moves at
                        // engine rate and we are faster than that, so one more
                        // pass is already generous.
                        SohVR_TexInUseSub((__bridge void*)t);
                        continue;
                    }
                    eyeTex[e] = t;
                    eyeBoundTag[e] = tag;
                    eyePoseTag[e] = poseTag;
                    eyeFresh[e] = 1;
                    eyeDepth[e] = tDepth;
                    [held addObject:t];
                    break;
                }
                if (!gSohVRPairFix && eyeTex[e] == nil && gSohVREngineOwnFix &&
                    sSohVRLastEyeTex[e] != nil) {
                    // The 1.0.0.11 behaviour, kept as the red control only:
                    // ONE eye re-presented one publication late.
                    eyeTex[e] = sSohVRLastEyeTex[e];
                    eyeDepth[e] = sSohVRLastEyeDepth[e];
                    eyeBoundTag[e] = sSohVRLastEyeTag[e];
                    eyePoseTag[e] = sSohVRLastEyePose[e];
                    if (SohVR_TexInUseAdd((__bridge void*)eyeTex[e])) {
                        [held addObject:eyeTex[e]];
                    } else {
                        eyeTex[e] = nil; // the engine took it back; show nothing
                        eyeDepth[e] = nil;
                    }
                }
                if (eyeTex[e] != nil) {
                    sSohVRLastEyeTex[e] = eyeTex[e];
                    sSohVRLastEyeDepth[e] = eyeDepth[e];
                    sSohVRLastEyeTag[e] = eyeBoundTag[e];
                    sSohVRLastEyePose[e] = eyePoseTag[e];
                }
            }
            // --- R15 item 1: THE PAIR IS ATOMIC --------------------------------
            //
            // Present two eye textures carrying the SAME pose tag, or present the
            // last pair that did — both eyes together, and reproject against THAT
            // pair's own anchor. See the long note in SohIosShell.m beside
            // gSohVRPairFix for why min(tagL, tagR) was the bug rather than a
            // conservative choice.
            unsigned int presentTag = 0;
            int presentTagValid = 0;
            // R16-A (F3.3): a held claim must not outlive the world frames it
            // exists for. Leaving VR, or turning the hold off from the bridge,
            // hands the slot straight back to the engine.
            if (!wantWorld || !gSohVRPairHold) {
                for (int e = 0; e < 2; e++) {
                    if (sSohVRPairHeld[e] != nil) {
                        SohVR_TexInUseSub((__bridge void*)sSohVRPairHeld[e]);
                        sSohVRPairHeld[e] = nil;
                    }
                }
            }
            if (gSohVRPairFix && wantWorld) {
                int pairOK = (eyeTex[0] != nil && eyeTex[1] != nil && eyeFresh[0] && eyeFresh[1] &&
                              eyePoseTag[0] == eyePoseTag[1] && eyePoseTag[0] != 0);
                if (pairOK) {
                    for (int e = 0; e < 2; e++) {
                        // R16-A (F3.3): HOLD THE RECORDED PAIR'S CLAIM. The
                        // fallback used to re-claim the pair every frame it
                        // needed it, which meant the engine could legitimately
                        // re-enter the slot in between and the fallback then
                        // had nothing to fall back TO — the condition that
                        // produces a pair_forced frame, and with it min(tag)
                        // and the blank eye. Claiming it once, for as long as
                        // it is the recorded pair, makes the fallback always
                        // available and makes the age clause below a
                        // diagnostic rather than a gate. The cost is one eye
                        // slot per eye held out of the engine's three-slot
                        // ping-pong: watch slot_starves and the pick-slot skip
                        // rate (diagnosis §6).
                        if (gSohVRPairHold && sSohVRPairHeld[e] != eyeTex[e]) {
                            if (sSohVRPairHeld[e] != nil) {
                                SohVR_TexInUseSub((__bridge void*)sSohVRPairHeld[e]);
                                sSohVRPairHeld[e] = nil;
                            }
                            if (SohVR_TexInUseAdd((__bridge void*)eyeTex[e])) {
                                sSohVRPairHeld[e] = eyeTex[e];
                            }
                        }
                        sSohVRPairTex[e] = eyeTex[e];
                        sSohVRPairDepth[e] = eyeDepth[e];
                        sSohVRPairStamp[e] = eyeBoundTag[e];
                    }
                    sSohVRPairPose = eyePoseTag[0];
                    presentTag = eyePoseTag[0];
                    presentTagValid = 1;
                } else {
                    gSohVRPairSplits = gSohVRPairSplits + 1;
                    // Both eyes fall back together, or neither does.
                    id<MTLTexture> pt[2] = { sSohVRPairTex[0], sSohVRPairTex[1] };
                    int got = 0;
                    if (pt[0] != nil && pt[1] != nil) {
                        if (SohVR_TexInUseAdd((__bridge void*)pt[0])) {
                            if (SohVR_TexInUseAdd((__bridge void*)pt[1])) {
                                got = 1;
                            } else {
                                SohVR_TexInUseSub((__bridge void*)pt[0]);
                            }
                        }
                    }
                    // AND THE HELD PAIR MUST STILL BE THE FRAME WE RECORDED.
                    // Once the pair stops being published it is no longer
                    // protected by the engine's gate, so between recording it
                    // and re-presenting it the engine can legitimately re-enter
                    // the slot, finish and PUBLISH it. The claim above closes
                    // the mid-write case (the gate's reservation refuses it);
                    // this closes the completed one, which the R11 frame-tag
                    // probe caught at 16 misses in 1202 checks the first time
                    // the pair rule shipped. A re-published texture carries a
                    // stamp we did not record, so comparing the two is exact.
                    if (got) {
                        for (int e = 0; e < 2; e++) {
                            if (pt[e] == (__bridge id<MTLTexture>)Soh3D_GetEyeMTLTexture(e + 1) &&
                                gSoh3DEyeStamp[e] != sSohVRPairStamp[e]) {
                                got = 0;
                            }
                            // AND IT MUST BE AT MOST ONE PUBLICATION OLD. The
                            // identity test above catches a slot the engine has
                            // already finished and re-published; this closes the
                            // one it is about to take. gSoh3DEyeStamp is a
                            // per-eye monotone publish counter, so the distance
                            // is exact: at one publication behind, the engine
                            // must still cycle through the other two ping-pong
                            // slots before it can reach this one, which is two
                            // host frames away and the compositor is faster than
                            // that. Beyond that the answer is pair_forced, which
                            // is one frame of the old behaviour rather than a
                            // frame the engine may be writing underneath us.
                            unsigned int live = gSoh3DEyeStamp[e];
                            unsigned int had = sSohVRPairStamp[e];
                            if (live != had && (unsigned int)(live - had) > 1u) {
                                got = 0;
                            }
                        }
                        if (!got) {
                            SohVR_TexInUseSub((__bridge void*)pt[0]);
                            SohVR_TexInUseSub((__bridge void*)pt[1]);
                            sSohVRPairTex[0] = nil;
                            sSohVRPairTex[1] = nil;
                            // R16-A (F3.3): the recorded pair is gone, so the
                            // claim held on it goes with it — a held claim on
                            // a pair nobody will present again would keep an
                            // eye slot out of the engine's rotation forever.
                            for (int e = 0; e < 2; e++) {
                                if (sSohVRPairHeld[e] != nil) {
                                    SohVR_TexInUseSub((__bridge void*)sSohVRPairHeld[e]);
                                    sSohVRPairHeld[e] = nil;
                                }
                            }
                        }
                    }
                    if (got) {
                        [held addObject:pt[0]];
                        [held addObject:pt[1]];
                    }
                    if (got) {
                        for (int e = 0; e < 2; e++) {
                            if (!eyeFresh[e] || eyeTex[e] != sSohVRPairTex[e]) {
                                gSohVREyeStale[e] = gSohVREyeStale[e] + 1;
                            }
                            eyeTex[e] = sSohVRPairTex[e];
                            eyeDepth[e] = sSohVRPairDepth[e];
                            eyeBoundTag[e] = sSohVRPairStamp[e];
                            eyePoseTag[e] = sSohVRPairPose;
                        }
                        presentTag = sSohVRPairPose;
                        presentTagValid = (presentTag != 0);
                    } else {
                        // No coherent pair anywhere: show what we have rather
                        // than a black world, and COUNT it, because this is the
                        // only path left that can put two moments in front of
                        // two eyes.
                        gSohVRPairForced = gSohVRPairForced + 1;
                    }
                }
            }
            // R16-A (F3.2): NEVER PRESENT AN EYE WITH NO WORLD. If exactly one
            // eye survived the claim/fallback, show that eye's texture in BOTH
            // views for this frame. In first person dim is 1.0, so the eye that
            // got nothing received the black dim wash and the HUD plane and
            // nothing else — one compositor frame of a BLACK EYE, which is a
            // flicker in the literal sense and is exactly what present_splits
            // (both eyes non-nil, by construction) could never see. A mono
            // frame is a comfort artefact; a black eye is a flash.
            // Gated on the pair rule's own A/B so `vr set pairfix 0` still
            // reproduces the 1.0.0.12 behaviour end to end — including the
            // blank eye, which is the fault eye_blank exists to count. An
            // assert that can never be shown red is worthless (trap D11).
            if (gSohVRPairFix && wantWorld && (eyeTex[0] == nil) != (eyeTex[1] == nil)) {
                const int good = (eyeTex[0] != nil) ? 0 : 1;
                const int bad = 1 - good;
                eyeTex[bad] = eyeTex[good];
                eyeDepth[bad] = eyeDepth[good];
                eyeBoundTag[bad] = eyeBoundTag[good];
                eyePoseTag[bad] = eyePoseTag[good];
                gSohVREyeMono = gSohVREyeMono + 1;
            }
            gSohVRPresentTag[0] = eyePoseTag[0];
            gSohVRPresentTag[1] = eyePoseTag[1];
            // R15 item 1's ASSERT, as a counter rather than a sample: how many
            // frames were PRESENTED with the two eyes carrying different pose
            // tags. Under the pair rule this can only be a pair_forced frame
            // (no coherent pair existed anywhere); with `vr set pairfix 0` it
            // climbs at the rate the two publications race, which in the
            // simulator alone is about a fifth of all frames.
            if (wantWorld && eyeTex[0] != nil && eyeTex[1] != nil &&
                eyePoseTag[0] != eyePoseTag[1]) {
                gSohVRPresentSplits = gSohVRPresentSplits + 1;
            }

            // --- pick the anchor that matches the pixels we are about to show -
            // Trap B1: the submitted anchor must be the one the eye textures
            // were rendered against, not the one we just queried. A tag the
            // ring no longer holds means the engine has fallen further behind
            // than half a second — re-present against the last good anchor
            // rather than lying about the pose.
            //
            // R15 item 1: it is chosen AFTER the eye pair is latched, and from
            // the pair that is actually being PRESENTED. It used to be
            // min(gSoh3DEyeTag[0], gSoh3DEyeTag[1]), read before the latch —
            // which reprojects the FRESH eye against the OLDER eye's pose and
            // is the whole of the user's one-eye flicker. With the pair rule the
            // two tags are equal by construction and there is no min to take.
            ar_device_anchor_t submitAnchor = anchor;
            if (wantWorld) {
                unsigned int tag;
                if (presentTagValid) {
                    tag = presentTag;
                } else {
                    // R16-A (F3.1): NEVER min(tag). R15 identified min() as
                    // the whole of the 1.0.0.11 one-eye flicker and then left
                    // it standing on exactly this path — the forced frames.
                    // min() reprojects the FRESH eye against the OLDER eye's
                    // pose, which is one frame of head motion applied to one
                    // eye. With F2 the two tags are equal and there is nothing
                    // to choose; if they somehow differ, take the LARGER, so
                    // the anchor matches the freshest pixels on screen rather
                    // than the stalest.
                    unsigned int tagL = eyePoseTag[0] ? eyePoseTag[0] : gSoh3DEyeTag[0];
                    unsigned int tagR = eyePoseTag[1] ? eyePoseTag[1] : gSoh3DEyeTag[1];
                    tag = (tagL > tagR) ? tagL : tagR;
                }
                ar_device_anchor_t matched = sohvr_ring_lookup(tag);
                if (matched != nil) {
                    submitAnchor = matched;
                    lastGoodAnchor = matched;
                    sSohVRLastSubmittedId = tag;
                } else if (lastGoodAnchor != nil) {
                    submitAnchor = lastGoodAnchor;
                    sSohVRTimeouts++;
                }
            }
            cp_drawable_set_device_anchor(drawable, submitAnchor);
            simd_float4x4 submittedFromOrigin =
                ar_device_anchor_get_origin_from_anchor_transform(submitAnchor);
            id<MTLTexture> hudTex = (__bridge id<MTLTexture>)gSoh3DHudTexture;
            id<MTLTexture> mirrorTex = (__bridge id<MTLTexture>)gSoh3DMirrorTexture;

            // --- R11 item 1: CLAIM every remaining engine texture this command
            // buffer references, and release every claim when it COMPLETES.
            // The eye colour textures were claimed above, as part of the latch;
            // depth, HUD and mirror are claimed here. A refusal on these three
            // is not worth a fallback (depth degrades to the 1x1 stand-in, and
            // the HUD/mirror planes simply do not draw for a frame), so an
            // unclaimed one is dropped rather than bound.
            {
                // ARC forbids a pointer-to-object-pointer array, so the four
                // are claimed by name rather than through a loop.
#define SOHVR_CLAIM_OR_DROP(t)                                                                     \
    do {                                                                                           \
        if ((t) != nil) {                                                                          \
            if (SohVR_TexInUseAdd((__bridge void*)(t))) {                                          \
                [held addObject:(t)];                                                              \
            } else {                                                                               \
                (t) = nil;                                                                         \
            }                                                                                      \
        }                                                                                          \
    } while (0)
                SOHVR_CLAIM_OR_DROP(eyeDepth[0]);
                SOHVR_CLAIM_OR_DROP(eyeDepth[1]);
                // R13 item 2a — THE HUD GETS THE SAME SAFETY NET THE EYES HAVE.
                // A HUD claim refusal used to be completely silent: no counter,
                // no fallback, the plane simply did not draw. That is survivable
                // for one frame and fatal for a session, because the refusal
                // that matters is a LEAKED gate reservation — the engine owns
                // slot 2 forever, so every frame after the leak refuses the same
                // texture and the HUD never comes back. The leak itself is fixed
                // above (overlay 0044 rev7 + SohVR_TexEngineSweep); this is the
                // net under it, and gSohVRBindDefer[2] is finally wired so a
                // refusal is a NUMBER on the settings page instead of an
                // invisible missing HUD.
                if (hudTex != nil) {
                    if (SohVR_TexInUseAdd((__bridge void*)hudTex)) {
                        [held addObject:hudTex];
                        sSohVRLastHudTex = hudTex;
                    } else {
                        gSohVRBindDefer[2] = gSohVRBindDefer[2] + 1;
                        hudTex = nil;
                    }
                }
                if (hudTex == nil && sSohVRLastHudTex != nil) {
                    if (SohVR_TexInUseAdd((__bridge void*)sSohVRLastHudTex)) {
                        hudTex = sSohVRLastHudTex;
                        [held addObject:hudTex];
                        gSohVRHudLastGood = gSohVRHudLastGood + 1;
                    }
                }
                if (mirrorTex != nil) {
                    if (SohVR_TexInUseAdd((__bridge void*)mirrorTex)) {
                        [held addObject:mirrorTex];
                    } else {
                        gSohVRBindDefer[3] = gSohVRBindDefer[3] + 1;
                        mirrorTex = nil;
                    }
                }
#undef SOHVR_CLAIM_OR_DROP
                [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
                    for (id<MTLTexture> t in held) {
                        SohVR_TexInUseSub((__bridge void*)t);
                    }
                }];
            }
            if (wantWorld) {
                for (int e = 0; e < 2; e++) {
                    sohvr_tag_probe(cb, e, eyeTex[e], eyeBoundTag[e], 0);
                }
            }
            sohvr_hud_alpha_scan(cb, hudTex);
            sohvr_rear_scan(cb, mirrorTex);

            if (!wantWorld) {
                // Panel fallback: mipmapped sampling copies, exactly as the
                // shipped 3D path builds them (its quad shader samples them).
                for (int e = 0; e < 2; e++) {
                    id<MTLTexture> src = eyeTex[e];
                    if (!src) {
                        continue;
                    }
                    if (soh3d_eyeCopy[e] == nil || soh3d_eyeCopy[e].width != src.width ||
                        soh3d_eyeCopy[e].height != src.height ||
                        soh3d_eyeCopy[e].pixelFormat != src.pixelFormat) {
                        MTLTextureDescriptor* td =
                            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
                                                                               width:src.width
                                                                              height:src.height
                                                                           mipmapped:YES];
                        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
                        td.storageMode = MTLStorageModePrivate;
                        soh3d_eyeCopy[e] = soh3d_eyecopy_new(src.device, td);
                    }
                    if (soh3d_eyeCopy[e] == nil) {
                        continue; // R13 item 1c: no destination, no copy this frame
                    }
                    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
                    [blit copyFromTexture:src toTexture:soh3d_eyeCopy[e]];
                    soh3d_scrub_tag_strip(blit, soh3d_eyeCopy[e]);
                    if (soh3d_eyeCopy[e].mipmapLevelCount > 1) {
                        [blit generateMipmapsForTexture:soh3d_eyeCopy[e]];
                    }
                    [blit endEncoding];
                }
            }

            id<MTLTexture> color0 = cp_drawable_get_color_texture(drawable, 0);
            size_t views = cp_drawable_get_view_count(drawable);
            simd_float4x4 panelModel =
                simd_mul(soh3d_haveScreenAnchor ? soh3d_make_screen_anchor(soh3d_frozenHead)
                                                : soh3d_translate(0.0f, 0.0f, -soh3d_screenDist),
                         soh3d_scale(soh3d_screenHalfW, soh3d_screenHalfH, 1.0f));

            for (size_t v = 0; v < views; v++) {
                cp_view_t view = cp_drawable_get_view(drawable, v);
                cp_view_texture_map_t tmap = cp_view_get_view_texture_map(view);
                size_t texIdx = cp_view_texture_map_get_texture_index(tmap);
                size_t slice = cp_view_texture_map_get_slice_index(tmap);
                MTLViewport vp = cp_view_texture_map_get_viewport(tmap);

                MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
                pass.colorAttachments[0].texture = cp_drawable_get_color_texture(drawable, texIdx);
                pass.colorAttachments[0].slice = slice;
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
                {
                    // R10 item 2, row 2 ("Foveated raster"). rmCount > 0 is
                    // DEVICE-ONLY (trap D15), so this attachment has never once
                    // executed in a green simulator run — which is exactly the
                    // profile of the thing we are hunting.
                    size_t rmCount = cp_drawable_get_rasterization_rate_map_count(drawable);
                    if (rmCount > 0 && !sohvr_diag_off(SOHVR_DIAG_FOVMAP)) {
                        pass.rasterizationRateMap =
                            cp_drawable_get_rasterization_rate_map(drawable, texIdx < rmCount ? texIdx : 0);
                    }
                }
                id<MTLTexture> depthTex = cp_drawable_get_depth_texture(drawable, texIdx);
                if (depthTex) {
                    pass.depthAttachment.texture = depthTex;
                    pass.depthAttachment.slice = slice;
                    pass.depthAttachment.loadAction = MTLLoadActionClear;
                    pass.depthAttachment.storeAction = MTLStoreActionStore;
                    // Reverse-Z: the FAR value is 0.
                    pass.depthAttachment.clearDepth = 0.0;
                }

                simd_float4x4 deviceFromEye = cp_view_get_transform(view);
                simd_float4x4 eyeFromOrigin = simd_inverse(simd_mul(submittedFromOrigin, deviceFromEye));
                simd_float4x4 proj = matrix_identity_float4x4;
                if (__builtin_available(visionOS 2.0, *)) {
                    proj = cp_drawable_compute_projection(drawable, cp_axis_direction_convention_right_up_back, v);
                }

                id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
                // Foveation contract: rasterize in the view's LOGICAL viewport;
                // the rate map compresses to physical. New target sizes (the
                // HUD plane) ride the same encoder, so the viewport is set once
                // per pass and never inherited (trap B4).
                [enc setViewport:vp];

                if (wantWorld) {
                    // Surroundings (spec D3): the dim wash goes down FIRST,
                    // at the reverse-Z far plane, so the world blit (depth
                    // Always) still wins every pixel it covers. First-person
                    // defaults to fully Dimmed; Diorama to passthrough.
                    float dimNow = sSohVRCfg[sSohVRView].dim;
                    if (dimNow > 0.003f && sSohVRDimPipe != nil) {
                        [enc setRenderPipelineState:sSohVRDimPipe];
                        [enc setDepthStencilState:sSohVRWorldDepth];
                        [enc setFragmentBytes:&dimNow length:sizeof(dimNow) atIndex:0];
                        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                    }
                    id<MTLTexture> src = (v < 2) ? eyeTex[v] : eyeTex[0];
                    id<MTLTexture> srcDepth = (v < 2) ? eyeDepth[v] : eyeDepth[0];
                    // R16-A (FAL-A1): THE COUNTER present_splits STRUCTURALLY
                    // CANNOT BE. That assert requires BOTH eyes non-nil, so the
                    // one failure mode that produces a genuinely one-eyed
                    // artefact — an eye presented with no world blit at all,
                    // which in first person (dim 1.0) is a BLACK eye for one
                    // compositor frame — was excluded from it by construction.
                    if (src == nil && v < 2) {
                        gSohVREyeBlank[v] = gSohVREyeBlank[v] + 1;
                    }
                    if (src != nil && sSohVRWorldPipe != nil) {
                        SohVRBlitParams params;
                        params.engNear = sSohVRDepthNear;
                        params.engFar = sohvr_engine_far();
                        params.compNear = sSohVRDepthNear;
                        params.compFar = sSohVRCompFar;
                        params.compFarInfinite = sSohVRCompFarInfinite ? 1.0f : 0.0f;
                        params.srgbDecode = sohvr_srgb_decode(src.pixelFormat, color0.pixelFormat);
                        params.hasDepth = (srcDepth != nil) ? 1.0f : 0.0f;
                        params.dbgMode = (float)sSohVRDbgMode;
                        params.useAlphaCov = sSohVRCfg[sSohVRView].alphaCov ? 1.0f : 0.0f;
                        params.flatDepth = sohvr_diag_off(SOHVR_DIAG_DEPTH) ? 1.0f : 0.0f;
                        params.forceOpaque =
                            (sSohVRFpOpaque && sSohVRCfg[sSohVRView].dim >= 0.999f) ? 1.0f : 0.0f;
                        // R11 review finding: hide the frame-tag strip in the
                        // displayed image exactly when the engine is stamping
                        // it. The probe still reads the real texels (its blit
                        // is encoded above, against the texture itself).
                        params.tagMask = gSohVREyeTagOn ? 1.0f : 0.0f;
                        [enc setRenderPipelineState:sSohVRWorldPipe];
                        [enc setDepthStencilState:sSohVRWorldDepth];
                        [enc setFragmentBytes:&params length:sizeof(params) atIndex:0];
                        [enc setFragmentTexture:src atIndex:0];
                        // Until the engine has published a depth texture (the
                        // first frame or two), a 1x1 stand-in keeps the binding
                        // legal and the shader falls back to colour alpha.
                        [enc setFragmentTexture:(srcDepth != nil ? srcDepth
                                                                 : sohvr_dummy_depth(color0.device))
                                        atIndex:1];
                        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                    }
                    // HUD on its plane (spec D6). Same machinery D12's
                    // rear-view pane will re-aim.
                    // R13 item 2c: "the plane was ENCODED this frame" — the
                    // counter the suite's tautological hud_tex=1 line never
                    // had. hud_tex reads the engine's PUBLICATION variable and
                    // is upstream of the claim, the panes diag row, the depth
                    // test and coverage; it can read 1 through every one of the
                    // ways the HUD actually goes missing.
                    if (hudTex != nil && !sohvr_diag_off(SOHVR_DIAG_PANES)) {
                        gSohVRHudEncodes = gSohVRHudEncodes + 1;
                    }
                    sohvr_draw_plane(enc, eyeFromOrigin, proj, hudTex, sSohVRHudDist, sSohVRHudHeight,
                                     sSohVRHudScale, color0.pixelFormat);
                    // The rear-view pane (spec D12) — the same plane
                    // machinery, off to the side, mono (both eyes sample the
                    // ONE mirror texture, so it reads as a flat panel at its
                    // plane's depth, which is what a mirror is), mirrored and
                    // opaque. Drawn only while it is visible, and only if the
                    // engine has actually published a mirror texture.
                    // R13 item 5 — LEFT HAND MEANS ALWAYS ON. The three
                    // placements are an if/else-if/else, and the whole group
                    // used to sit inside `if (sSohVRMirrorVisible)` — so with
                    // "Left hand" ON the pane still vanished the moment the
                    // 3-second auto-show window lapsed, which is the user's
                    // "sometimes does NOT show". The visibility latch upstream
                    // now raises sSohVRMirrorVisible (and therefore
                    // gSohVRMirrorActive, without which the engine never renders
                    // the mirror walk at all and this plane would sample a stale
                    // or NULL texture) whenever left-hand mode is on, the world
                    // is active and the left controller is actually tracked —
                    // D12's perf gate kept, just widened by one term.
                    // R14 item 3 — TWO PANES, INDEPENDENTLY. The if/else-if/else
                    // is gone: the user's two switches are orthogonal and both on
                    // must draw both. It costs nothing — one mirror texture, two
                    // planes, and the engine's third walk is already gated on
                    // "either of them wants it" (sohvr_mirror_decide).
                    //
                    // The R11 "face the eye from the hand's position" variant is
                    // DELETED. the user's verdict on it was blunt: blurry, and it
                    // does not rotate with the hand. Both halves are the same
                    // fact — a plane that always squares up to the eye has no
                    // relationship to the controller you are holding, so it
                    // reads as a decal floating near your fist rather than as a
                    // mirror bolted to it, and every wrist movement smears it
                    // across the texture instead of turning it. The surviving
                    // placement is R4's: the plane IS the hand pose, offset
                    // along the hand's own up axis, so it turns as your wrist
                    // turns — which is the one he says follows well.
                    if (sSohVRPaneTopLive) {
                        sohvr_draw_plane_ex(enc, eyeFromOrigin, proj,
                                            mirrorTex, sSohVRMirrorX,
                                            sSohVRMirrorDist, sSohVRMirrorY, sSohVRMirrorScale,
                                            color0.pixelFormat, sSohVRMirrorMirrored, 1,
                                            SOHVR_PANE_CORNER, 1);
                        sSohVRPanePlacement = SOHVR_PANE_HUD;
                        sSohVRPaneDraws[SOHVR_PANE_HUD]++;
                    }
                    if (sSohVRPaneHandLive) {
                        simd_float4x4 handPane;
                        if (SohSense_LeftPanePose(&handPane)) {
                            simd_float4x4 eyeInv = simd_inverse(eyeFromOrigin);
                            simd_float3 ep = simd_make_float3(eyeInv.columns[3].x, eyeInv.columns[3].y,
                                                              eyeInv.columns[3].z);
                            simd_float3 hp = simd_make_float3(handPane.columns[3].x, handPane.columns[3].y,
                                                              handPane.columns[3].z);
                            float d = simd_length(hp - ep);
                            if (!(d > 0.05f)) {
                                d = 0.5f; // hand inside the head: size it sanely
                            }
                            sohvr_draw_plane_at(enc, eyeFromOrigin, proj, mirrorTex, handPane,
                                                0.5f * d * SohSense_WristScale(),
                                                color0.pixelFormat, sSohVRMirrorMirrored, 1,
                                                SOHVR_PANE_CORNER, 1);
                            sSohVRPanePlacement = SOHVR_PANE_LEFTHAND;
                            sSohVRPaneDraws[SOHVR_PANE_LEFTHAND]++;
                        } else {
                            // The latch said the hand was live and the pose has
                            // gone in the same frame. Counted, because "it
                            // blinked out" is exactly the report this path
                            // produces and R13 shipped it without a number.
                            sSohVRPaneDrops++;
                        }
                    }
                    // The item in your hand (spec D13). Placeholder art, real
                    // pose: a billboard-sized plane at the item hand, gated on
                    // MK64 actually having an item armed.
                    if (SohSense_ItemInHandVisible()) {
                        simd_float4x4 hand;
                        if (SohSense_ItemHandPose(&hand)) {
                            sohvr_draw_plane_at(enc, eyeFromOrigin, proj,
                                                sohvr_item_chip(color0.device, SohSense_ArmedItem()), hand,
                                                0.5f * SohSense_ItemScale(), color0.pixelFormat, 0, 0,
                                                0.0f, 0);
                        }
                    }
                } else {
                    // Panel fallback — the shipped world-locked presentation.
                    id<MTLTexture> tex = (v < 2 && soh3d_eyeCopy[v]) ? soh3d_eyeCopy[v] : soh3d_eyeCopy[0];
                    float dimNow = soh3d_dimLevel;
                    if (dimNow > 0.003f && soh3d_dimPipeline) {
                        [enc setRenderPipelineState:soh3d_dimPipeline];
                        [enc setDepthStencilState:soh3d_dimDepthState];
                        [enc setFragmentBytes:&dimNow length:sizeof(dimNow) atIndex:0];
                        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                    }
                    if (tex != nil && soh3d_pipeline != nil) {
                        simd_float4x4 mvp = simd_mul(proj, simd_mul(eyeFromOrigin, panelModel));
                        float srgb = sohvr_srgb_decode(tex.pixelFormat, color0.pixelFormat);
                        [enc setRenderPipelineState:soh3d_pipeline];
                        [enc setDepthStencilState:soh3d_depthState];
                        [enc setVertexBytes:&mvp length:sizeof(mvp) atIndex:0];
                        [enc setFragmentBytes:&srgb length:sizeof(srgb) atIndex:0];
                        [enc setFragmentTexture:tex atIndex:0];
                        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
                    }
                }
                [enc endEncoding];
            }

            // R12 item 1: the probe's LATE read. Encoded after every view's
            // render pass, so the pair of readbacks brackets the world blit
            // instead of preceding it. A tear that begins inside the blit —
            // the only kind that can put mid-render garbage on the screen and
            // still leave the head read clean — shows up here and nowhere else.
            if (wantWorld) {
                for (int e = 0; e < 2; e++) {
                    sohvr_tag_probe(cb, e, eyeTex[e], eyeBoundTag[e], 1);
                }
            }
            cp_drawable_encode_present(drawable, cb);
            // R12 item 1's NEGATIVE control: hold the finished command buffer
            // back with every claim already taken. The claim is supposed to
            // cover encode -> completion, so no amount of delay here may
            // produce a tag miss; if one appears, the claim is not covering
            // what its comment says it covers.
            if (gSohVRCompHoldMs > 0) {
                usleep((useconds_t)gSohVRCompHoldMs * 1000);
            }
            // R10 item 2: the cheapest GPU-side artefact signal there is — did
            // the COMPOSITOR's own command buffer fail? A screenshot cannot show
            // this, and the settings page reports it with no action from the user.
            [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
                if (done.error != nil) {
                    sSohVRCbErrors++;
                    sSohVRCbErrLast = (unsigned int)done.error.code;
                }
            }];
            [cb commit];
            sohvr_note_present();
            sSohVRLoopFrames++;
            if (wantWorld) {
                sSohVRLoopWorldFrames++;
            } else {
                sSohVRLoopPanelFrames++;
            }
            // R14 item 5 — THE PRIME SUSPECT, and it was our own diagnostic.
            //
            // This built a ~2.5 KB string from ~100 snprintf arguments and
            // NSLogged it ON THE RENDER THREAD, inside the frame, immediately
            // before cp_frame_end_submission — every 600 compositor frames.
            // That is 6.7 s at 90 Hz and 13.3 s at 45 Hz, which is where a
            // 20 Mpix eye pass at 100% quality actually runs: squarely inside
            // the user's "every 10-15 seconds". A frame that misses its deadline
            // in a headset does not read as a stutter, it reads as the whole
            // world sliding, because the picture is displayed against a pose it
            // was not rendered for. Trap D33 wrote the rule after a log flooded
            // the instrument reading it; this is the same fault one level worse
            // — a log that perturbs the thing it is describing.
            //
            // It is now built and logged on a background queue, and only when
            // the dev diagnostics are summoned. The counter stays either way,
            // so the retest can tell a dump apart from the other suspects.
            if (sSohVRLoopFrames == 3 || (sSohVRLoopFrames % 600) == 0) {
                sohvr_glitch_tick(sSohVRLoopFrames); // R19 item 5: SOH_VRGLITCH
                sSohVRDumps++;
                if (SohVR_GetDiagUI()) {
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        NSLog(@"[SohVR] %s", SohVR_DumpMode());
                    });
                }
            }
            cp_frame_end_submission(frame);
        }
    }

    // Leaving VR: the engine must be back on its normal matrices BEFORE the
    // shell puts it back on the window swapchain, and nothing may keep a
    // reference to a drawable-owned object past this point.
    gSohVRWorldActive = 0;
    {
        // Every VR-only engine switch goes inert on the way out, so the flat
        // and 3D-panel paths cannot inherit a VR behaviour (spec §3).
        extern volatile int gSohVRSkyMode, gSohVREyeKey, gSohVRAngleCullOff;
        extern volatile int gSohVRHideOwnKart;
        // R14 item 1: the sky's world-lock goes inert too, so the flat game and
        // the 3D panel cannot inherit a stale ortho shift.
        extern volatile float gSohVRSkyShift[2];
        extern volatile int gSohVRSkyShiftValid;
        gSohVRSkyShift[0] = 0.0f;
        gSohVRSkyShift[1] = 0.0f;
        gSohVRSkyShiftValid = 0;
        gSohVRSkyMode = 0;
        gSohVREyeKey = 0;
        gSohVRAngleCullOff = 0;
        gSohVRHideOwnKart = 0; // R9 item 5: your kart comes back on the way out
        {
            extern volatile int gSohVRFpWorld;
            gSohVRFpWorld = 0; // R19 item 6: no Lakitu push outside VR
        }
        gSohVRMirrorActive = 0; // R3: no third walk outside VR world frames
        sSohVRMirrorVisible = 0;
        sSohVRPaneTopLive = sSohVRPaneHandLive = 0;
        sSohVRMirrorHold = 0;
    }
    // R4: release EVERY Sense button and drop every gesture latch on the way
    // out. Unconditional and idempotent like the rest of the finalize, so the
    // Crown's exit path clears them too — a VR exit mid-throw must not leave Z
    // asserted in the flat game (spec D9, trap C2).
    SohSense_Stop();
    SohVR_StashRestoreOnExit(); // C4: hand the flat game its CVars back
    soh3d_release_vr_eye_extent();
    for (int i = 0; i < SOHVR_RING; i++) {
        sSohVRRing[i] = nil;
        sSohVRRingId[i] = 0;
    }
    soh3d_eyeCopy[0] = soh3d_eyeCopy[1] = nil;
    if (notifyEnded) {
        Soh3D_Immersive_Ended();
    }
    gSoh3DRunning = 0; // signal the shell LAST, after cleanup
}
