// SohVisionApp.swift — SwiftUI app entry for the visionOS target (D-030).
//
// visionOS requires a SwiftUI `App` to declare an `ImmersiveSpace` (UIKit
// can't open one), so the app entry is SwiftUI — but it only HOSTS the
// existing UIKit/SDL engine (SohHostViewController boots it) in a WindowGroup,
// and declares the ImmersiveSpace for stereoscopic 3D. All engine/shell logic
// stays in C/ObjC; this file is scene plumbing only. Adapted from the proven
// vkQuake-ios VKQVisionApp.swift.

import SwiftUI
import CompositorServices
import AVFAudio

final class SohAppModel: ObservableObject {
    static let shared = SohAppModel()
    // VR-spec D1 tri-state: 0 = flat, 1 = 3D panel, 2 = VR. Two spaces,
    // never one space with two configurations — merely widening a space's
    // immersion-style set changed the drawable contract and aborted present
    // on a sibling port (trap B2), so `Soh3D` is left exactly as it shipped.
    @Published var mode: Int32 = 0
    // R7 (the user, 1.0.0.3): "why the fuck are you putting VR SETTINGS in its
    // own ornament? every single other iteration had the VR settings in the
    // Gear icon. you just hide the 3D panel settings when you're in VR, and
    // hide VR settings when in 3D mode." So there is ONE sheet behind ONE gear,
    // and `mode` decides which rows it shows. R6's second ornament button and
    // its second sheet are gone.
    @Published var showSettings = false
    // Surroundings for the VR space only. R0 measured the live style switch as
    // contract-safe (byte-identical drawable across three switches), so this
    // is a binding, not a second space.
    @Published var vrFullImmersion = false
    // R9b item 8: visionOS upper-limb visibility on the VR space. Default OFF —
    // your real hands are not on an MK64 wheel. The VR module owns the persisted
    // state (spec D10); this is only the scene-side mirror of it.
    @Published var vrShowHands = false
    // R9b: which section the settings sheet should scroll to, and a sequence
    // number so asking for the SAME section twice still scrolls. There is no
    // tap/scroll injection on these simulators (idb HID delivers nothing on
    // visionOS 27), so this is how a section below the fold gets a screenshot
    // artifact — and it is the same hook a future deep link would use.
    @Published var settingsScrollTo = "view"
    @Published var settingsScrollSeq = 0
}

// Called from ObjC (SohHostViewController) to flip the SwiftUI state that
// actually opens/dismisses the space.
@_cdecl("Soh_SetSpaceMode")
func Soh_SetSpaceMode(_ mode: Int32) {
    DispatchQueue.main.async { SohAppModel.shared.mode = mode }
}

// Open/close the gear sheet from C. There is no tap injection for a visionOS
// ornament (and idb HID is dead on the current sims — memory), so this is how
// the sheet gets a screenshot artifact in the simulator, and how a future deep
// link or gamepad chord can summon it. R7: one sheet, so this opens whichever
// context the current space mode calls for.
@_cdecl("SohVR_ShowSettingsSheet")
func SohVR_ShowSettingsSheet(_ on: Bool) {
    DispatchQueue.main.async { SohAppModel.shared.showSettings = on }
}

// Surroundings (spec D3): Diorama defaults to Passthrough, so VR opens in
// .mixed and switches live.
@_cdecl("SohVR_SetFullImmersion")
func SohVR_SetFullImmersion(_ on: Bool) {
    DispatchQueue.main.async { SohAppModel.shared.vrFullImmersion = on }
}

// Scroll the open settings sheet to a named section (see SohAppModel).
@_cdecl("SohVR_ScrollSettingsTo")
func SohVR_ScrollSettingsTo(_ name: UnsafePointer<CChar>) {
    let id = String(cString: name)
    DispatchQueue.main.async {
        SohAppModel.shared.settingsScrollTo = id
        SohAppModel.shared.settingsScrollSeq += 1
    }
}

// R9b item 8 — "Show Hands". Pushed from SohVR_SetShowHands / on every VR entry
// (SohVR_ApplySurroundings), exactly like the surroundings style above.
@_cdecl("SohVR_ApplyShowHands")
func SohVR_ApplyShowHands(_ on: Bool) {
    DispatchQueue.main.async { SohAppModel.shared.vrShowHands = on }
}

// In 3D, anchor the app's sound stage to the FRONT (at the panel) instead of
// the parked-aside 2D window. Restored on exit.
// VR (spec D8 / trap C3): the head owns the camera and the game world is
// AROUND the player, so the app's own spatial staging must get out of the
// way — the compositor's own spatialization is the right one. Restored BEFORE
// the exit finalize, never after.
private func sohSetAudioBypassed(_ on: Bool) {
    let session = AVAudioSession.sharedInstance()
    do {
        if on {
            if session.category != .playback {
                try session.setCategory(.playback, mode: .default)
            }
            try session.setIntendedSpatialExperience(.bypassed)
            SohIos_SetAudioAnchorStatus(3)
        } else {
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .automatic, anchoringStrategy: .automatic))
        }
        NSLog("[SohVR] Swift: audio spatial experience -> \(on ? "bypassed" : "automatic")")
    } catch {
        NSLog("[SohVR] Swift: setIntendedSpatialExperience(bypassed) failed: \(error)")
        SohIos_SetAudioAnchorStatus(2)
    }
}

private func sohSetAudioFrontStage(_ on: Bool) {
    let session = AVAudioSession.sharedInstance()
    do {
        // SDL configures the session for plain playback; the spatial-experience
        // call can silently no-op under some categories/modes (device symptom:
        // audio stays at the parked window). Assert the compatible setup first.
        if on && session.category != .playback {
            try session.setCategory(.playback, mode: .default)
        }
        if on {
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .large, anchoringStrategy: .front))
            SohIos_SetAudioAnchorStatus(1)
        } else {
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .automatic, anchoringStrategy: .automatic))
        }
        NSLog("[Soh3D] Swift: audio spatial experience -> \(on ? "front" : "automatic")")
    } catch {
        NSLog("[Soh3D] Swift: setIntendedSpatialExperience failed: \(error)")
        SohIos_SetAudioAnchorStatus(2)
    }
}

// Re-apply the front-anchored sound stage every few seconds while in 3D:
// SDL re-configures the audio session behind our back (device symptom: audio
// anchored at the parked-aside window, not the panel).
private var sohAudioTimer: Timer?
private func sohStartAudioReanchor() {
    sohStopAudioReanchor()
    sohSetAudioFrontStage(true)
    sohAudioTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
        sohSetAudioFrontStage(true)
    }
}
private func sohStopAudioReanchor() {
    sohAudioTimer?.invalidate()
    sohAudioTimer = nil
}

struct SohWindowView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SohHostViewController {
        return SohHostViewController()
    }
    func updateUIViewController(_ vc: SohHostViewController, context: Context) {}
}

// Query capabilities so we never request an unsupported combination (which
// makes openImmersiveSpace fail with a generic .error).
struct SohCompositorConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        let layouts = capabilities.supportedLayouts(options: [])
        // D-036 (3D crispness): dynamic foveation concentrates rasterization
        // density where the eyes look — the same mechanism that makes system
        // windows crisp. Our panel pass renders with the drawable's
        // rasterization rate map (SohImmersive.m). UNCONDITIONAL where the
        // hardware supports it (user call, post-validation: no fps impact,
        // "nobody wants blurry" — the old CVar gate only existed for bring-up).
        let fov = capabilities.supportsFoveation
        configuration.isFoveationEnabled = fov
        // rev3 (device round: right eye warped): with LAYERED layout the
        // drawable has one multi-layer rate map, and our per-slice passes
        // always rasterize with layer 0's map — left eye fine, right eye
        // fisheye. Dedicated layout gives each eye its own texture AND its
        // own rate map, which our two-pass loop maps correctly.
        if fov && layouts.contains(.dedicated) {
            configuration.layout = .dedicated
        } else {
            configuration.layout = layouts.contains(.layered) ? .layered : .dedicated
        }
        configuration.colorFormat = capabilities.supportedColorFormats.first ?? .bgra8Unorm_srgb
        configuration.depthFormat = capabilities.supportedDepthFormats.first ?? .depth32Float
        // D-036 second lever RETIRED (2026-07-22): raising maxRenderQuality
        // aborts the compositor on DEVICE too (crash.txt: CompositorNonUI
        // abort in Soh3D_Immersive_Run at 3D entry), not just the sim.
        // Foveation alone is the shipped lever; do not re-attempt a quality
        // raise without a validation API that doesn't abort.
        if #available(visionOS 26.0, *) {
            NSLog("[Soh3D] Swift: default render quality=\(capabilities.defaultRenderQuality.rawValue)")
        }
        NSLog("[Soh3D] Swift: compositor configured (layered=\(layouts.contains(.layered)) foveation=\(fov))")
    }
}

// R11 item 5 — SECTION STRUCTURE.
//
// the user, 1.0.0.7: (a) in 2D mode the 3D-panel settings stopped showing, and
// (b) the modal must show BOTH the 3D settings and the VR settings, ALWAYS,
// each under its own STICKY subheader carrying its own Reset.
//
// So the sheet is a `List` with `.listStyle(.plain)` — the only list style on
// this platform whose SECTION HEADERS PIN — and exactly TWO sections, "3D
// Settings" and "VR Settings". That is what makes the VR header replace the 3D
// one as you scroll into it, and it is also what retires R9b's open question
// (the chrome header that titled the 3D rows "VR Settings" whatever you were
// looking at, because it was not a section header at all).
//
// Two sections means the old inner Sections cannot survive — SwiftUI has no
// nested sections — so each becomes a plain in-list label. The rows and their
// order are unchanged.
private func sohGroupLabel(_ title: String) -> some View {
    Text(title)
        .font(.headline)
        .foregroundStyle(.secondary)
        .padding(.top, 6)
        .listRowSeparator(.hidden)
}

private func sohStickyHeader(_ title: String, reset: @escaping () -> Void) -> some View {
    HStack {
        Text(title)
            .font(.headline)
        Spacer()
        Button("Reset", action: reset)
            .font(.title3)
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 4)
}

// Live 3D-panel settings (persisted in UserDefaults, pushed to the loop's
// setters both on change and on immersive entry).
struct Soh3DSettingsView: View {
    @AppStorage("vp3dDist") private var dist = 3.6
    @AppStorage("vp3dHalfW") private var halfW = 2.75
    @AppStorage("vp3dHalfH") private var halfH = 1.55
    @AppStorage("vp3dHeight") private var height = 0.0
    @AppStorage("vp3dDim") private var dim = 0.8
    @AppStorage("vp3dDepth200") private var depth200 = 85.0 // D-V6: user default
    @AppStorage("vp3dUseFeet") private var useFeet = true // D-V6: user default

    static func resetAll() {
        let d = UserDefaults.standard
        d.set(3.6, forKey: "vp3dDist"); d.set(2.75, forKey: "vp3dHalfW")
        d.set(1.55, forKey: "vp3dHalfH"); d.set(0.0, forKey: "vp3dHeight")
        d.set(0.8, forKey: "vp3dDim"); d.set(85.0, forKey: "vp3dDepth200")
        d.set(true, forKey: "vp3dUseFeet")
        applyAll()
    }

    static func applyAll() {
        let d = UserDefaults.standard
        func f(_ k: String, _ def: Double) -> Float {
            return Float(d.object(forKey: k) != nil ? d.double(forKey: k) : def)
        }
        Soh3D_SetPanel(f("vp3dDist", 3.6), f("vp3dHalfW", 2.75), f("vp3dHalfH", 1.55))
        Soh3D_SetHeight(f("vp3dHeight", 0.0))
        Soh3D_SetDim(f("vp3dDim", 0.8)) // 80% default (user-requested)
        // 100% = 3.25% eye-offset fraction — the user's device-tuned preference
        // (was 130% on the old 2.5% scale; whole scale raised 1.3x so their
        // choice is the new center with headroom both ways).
        // Focus bias pinned at 100% (removed from UI; aiming auto-adapts it).
        Soh3D_SetStereoParams(f("vp3dDepth200", 85.0) / 100.0 * 0.0325, 1.0)
    }

    private func fmt(_ meters: Double) -> String {
        return useFeet ? String(format: "%.1f ft", meters * 3.28084)
                       : String(format: "%.1f m", meters)
    }

    // R9b: the panel rows are SECTIONS now, not a Form of their own — the
    // sheet builds ONE Form out of the VR sections and these, so "one modal,
    // one column" survives the VR rows becoming visible outside VR (item 1).
    // The onChange handlers moved onto the individual controls for the same
    // reason: a modifier on the enclosing Group would replicate onto every
    // child.
    @ViewBuilder var body: some View {
        sohGroupLabel("Screen").id("panel")
        Group {
            LabeledContent("Distance  \(fmt(dist))") {
                Slider(value: $dist, in: 1.0...8.0) { _ in }
            }
            .onChange(of: dist) { Self.applyAll() }
            LabeledContent("Width  \(fmt(halfW * 2))") {
                Slider(value: $halfW, in: 0.6...4.0)
            }
            .onChange(of: halfW) { Self.applyAll() }
            LabeledContent("Height  \(fmt(halfH * 2))") {
                Slider(value: $halfH, in: 0.4...3.0)
            }
            .onChange(of: halfH) { Self.applyAll() }
            // range reaches ceiling placement for lying-down play
            LabeledContent("Position height  \(fmt(height))") {
                Slider(value: $height, in: -1.5...5.0)
            }
            .onChange(of: height) { Self.applyAll() }
            LabeledContent("Units") {
                Picker("", selection: $useFeet) {
                    Text("m").tag(false)
                    Text("ft").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
            }
        }
        sohGroupLabel("Stereo Depth")
        // Convergence auto-follows the game camera (Link stays on the
        // panel plane); Depth is the one knob most users touch.
        // 0-200% convention shared with the other ports.
        LabeledContent("Depth  \(Int(depth200))%") {
            Slider(value: $depth200, in: 0.0...200.0)
        }
        .onChange(of: depth200) { Self.applyAll() }
        sohGroupLabel("Surroundings")
        LabeledContent("Dim  \(Int(dim * 100))%") {
            Slider(value: $dim, in: 0.0...1.0)
        }
        .onChange(of: dim) { Self.applyAll() }
        // R11 item 5: no "Reset" button down here any more — the section's own
        // sticky header carries it, and two Resets for one section is how you
        // get a bug report about the wrong one.
        Button("Recenter Screen") { Soh3D_Recenter() }
    }
}

// --- R6: the VR settings page, reachable FROM INSIDE THE HEADSET -------------
//
// the user's third report on 1.0.0.2 was "why don't we have ANY options in our
// settings to swap between [modes]. i see no VR section with settings." The
// rows were not missing from the build — overlay 0023's "Vision Pro VR" group
// is in the shipped 1.0.0.2 binary (verified: the strings are in the Mach-O).
// They were UNREACHABLE. D-041: the ImGui port menu is display-only in 3D and
// VR, because the immersive space owns input focus and SDL reports the window
// unfocused, so nothing in that menu can be clicked while the headset is on.
// The only interactive surface in immersive is this SwiftUI ornament — and its
// gear sheet contained nothing but 3D-panel rows.
//
// So the VR page lives here. It is a plain SwiftUI Form: gaze-and-pinch works,
// no gamepad chord to memorise, no bridge command to type (the user cannot type
// bridge commands in the headset — that is now a standing constraint, and it
// is why the debug-bisect ladder is a ROW here rather than a console command).
//
// State: these are NOT @AppStorage. The VR module's per-mode config store is
// the live state and its CVars are the persistence (spec D10); duplicating
// it in UserDefaults is how two sources of truth start. The view reads the
// module on appear and on every mode switch, and writes straight through.
struct SohVRSettingsView: View {
    // R9b item 4: Reset lives in the sheet's PINNED header, above this view.
    // The header bumps this token; the token is what makes the rows re-read the
    // module. (A @State cannot be reset from outside; a re-read can.)
    var resetToken: Int = 0

    @State private var view: Int32 = 1
    // R9b item 2: ONE displayed pair per mode, in the display step the 1.0.0.5
    // sheet already used (1 step = 1 cm), rebased so the user's tuned first-person
    // numbers read as ZERO. The engine quantity behind each one differs by mode
    // — the seat in first person, the chase offsets in third, the world height
    // and the world SCALE in Diorama — and the mapping is `pullPlacement` /
    // `applyHeight` / `applyZoom` below. No units anywhere: they were, in
    // the user's words, "meaningless and added clutter".
    @State private var heightDisp: Double = 0
    @State private var zoomDisp: Double = 0
    // R10 addendum: the HUD plane's height, same convention (1 step = 1 cm,
    // 0 = the shipped default for this mode).
    @State private var hudDisp: Double = 0
    @State private var dim: Double = 0
    @State private var horizon = true
    @State private var spins = true
    @State private var flips = false
    @State private var hands = false
    @State private var mirrorTop = true
    // R14 item 6: the Diagnostics group is bridge-summoned, not shipped.
    @State private var diagUI = false
    @State private var hitch = ""
    // R11 item 4: Side/Height/Distance/Size are DELETED — the placement is
    // hardcoded and rises with the HUD row. "Left hand" is the one row here.
    @State private var mirrorLeftHand = false
    @State private var eyeScale: Double = 1.0
    @State private var vrdbg: Int32 = 0
    // R10 item 2: one entry per bisect row, ON = the shipping mechanism.
    @State private var diagOn: [Bool] = []
    @State private var status = ""
    @State private var perf = ""
    @State private var mem = ""
    // R10: the GPU-side artefact counters, and the crash-capture caption.
    @State private var gpu = ""
    @State private var eyeTag = ""
    @State private var crash = ""
    @State private var telemetry: Timer?

    private static let dbgLevels: [Int32] = [0, 1, 2, 3, 4, 5, 6, 99]
    private static let dbgNames = ["0 Off (normal)", "1 Sky off", "2 Angle cull back",
                                   "3 Mono (one eye's view)", "4 Freeze head tracking",
                                   "5 Near far plane", "6 No interpolation", "99 All except 4"]

    // --- the per-mode Height/Zoom mapping (item 2) ---------------------------
    //
    // DISPLAYED-ZERO BASELINES, in metres, so they do not move with a mode's
    // scale. First person's are the user's own tuned values from the 1.0.0.5
    // device round (the sheet showed them as +45 and -14 at 8 u/m); third
    // person's and Diorama's are the shipped effective values, which he will
    // re-tune in the headset and report back.
    private static let fpHeight0 = 0.45
    private static let fpZoom0 = -0.14
    private static let thirdHeight0 = 25.0 / 120.0
    private static let thirdZoom0 = 40.0 / 120.0
    private static let dioHeight0 = -0.40
    // R12 item 3 — THE DIORAMA ZOOM RESCALE. Mirrors SOHVR_DIO_SCALE0 /
    // SOHVR_DIO_SCALE_STEP in SohImmersive.m (the module owns the value, this
    // owns the display — the same duplication rule as every baseline here).
    // the user, 1.0.0.8, verbatim: "the +2 zoom is already very zoomed out, that
    // should be the -10 on a new scale range, so rescale everything to that so
    // you can zoom in more." His +2 on the R11 slider was 500/1.25^2 = 320 u/m,
    // and 320 is now the value at -10; the default and the near end fall out of
    // 320 = S0 * r^10 with r = 1.15. See the long note in SohImmersive.m.
    private static let dioScale0 = 79.1
    // R10 addendum: the HUD plane's per-mode displayed zero, mirroring
    // SOHVR_HUD_HEIGHT0_* in SohImmersive.m (same duplication rule as the
    // baselines above: the module owns the value, this owns the display).
    // R11 item 4: +10 on the 1.0.0.7 scale became the new default.
    // R13 item 7: each moved down 0.23 m with the rescale above.
    // R14 item 2: and each moves back UP 5 cm — R13 read the user's "old -18
    // becomes new +5 (max)" as "he ran out of travel downward" and it was the
    // other way round. His tuned spot is the new MIDDLE of the row.
    private static let hudHeight0: [Int32: Double] = [0: 0.25, 1: -0.30, 2: -0.25]
    // R11 item 5 — THE RANGES, RE-DERIVED. the user, 1.0.0.7: keep ten steps of
    // granularity but make each step MUCH larger for third person (Zoom
    // especially) and larger still for Diorama, because "the most zoomed in was
    // still way too far away" in Diorama. Ten steps of one centimetre was a
    // trim, not a range: third person's chase distance is 40 units and ten
    // steps moved it by twelve.
    //
    // First person keeps its 1 cm trim: that seat is the user's own tuned
    // number and the row exists to nudge it, not to relocate him.
    //
    // Both ZOOM rows are MULTIPLICATIVE, so the extremes are genuinely extreme
    // in both directions and neither can walk through zero into a camera in
    // front of the kart (which an additive step of this size would).
    //   third zoom  x1.14^-d : +10 -> 40 u becomes 10.8 u (in the driver's lap)
    //                          -10 -> 40 u becomes 148 u (a long lens)
    //   diorama zoom x1.15^-d : R12 item 3 re-anchors this row. -10 -> 320 u/m
    //                           (the user's old +2, "already very zoomed out"),
    //                           0 -> 79.1 u/m, +10 -> 19.6 u/m — a SIXTEEN-fold
    //                           span with nearly all of it zooming IN from the
    //                           anchor, and a near end 2.8x closer than R11's.
    // Heights stay additive (they are offsets, not distances) with much bigger
    // steps: 4 cm per step in third person (4.8 game units), 8 cm in Diorama.
    private static let dioZoomRatio = 1.15
    private static let thirdZoomRatio = 1.14
    private static let thirdHeightStep = 0.04  // metres per display step
    private static let dioHeightStep = 0.08

    private var liveScale: Double { max(0.001, Double(SohVR_GetScale())) }
    // Diorama gets the generous range; the other two are a fine trim around a
    // seat that is already where it belongs.
    // Ten steps each way everywhere but first person, whose fine trim stays.
    private var placementRange: ClosedRange<Double> { view == 1 ? -5...5 : -10...10 }
    // R13 item 7 (the user, 1.0.0.9): third person's Zoom opens to -10..+15 — he
    // wants to get closer to the kart than ten multiplicative steps allowed,
    // and +15 at x1.14/step is 40 -> 5.5 game units, effectively in the seat.
    // Height keeps the symmetric range; only Zoom, and only in third person.
    private var zoomRange: ClosedRange<Double> {
        view == 2 ? -10...15 : placementRange
    }

    private func pullPlacement() {
        switch view {
        case 1:
            heightDisp = (Double(SohVR_GetSeatUp()) / liveScale - Self.fpHeight0) * 100.0
            zoomDisp = (Double(SohVR_GetSeatFwd()) / liveScale - Self.fpZoom0) * 100.0
        case 2:
            var u: Float = 0, b: Float = 0
            SohVR_GetThird(&u, &b)
            heightDisp = (Double(u) / liveScale - Self.thirdHeight0) / Self.thirdHeightStep
            // Zoom IN means closer to the kart, i.e. LESS chase distance.
            zoomDisp = -log(max(1e-6, Double(b) / liveScale) / Self.thirdZoom0) / log(Self.thirdZoomRatio)
        default:
            // R13 item 7: the Diorama Height row's sign was INVERTED — the
            // engine quantity is where the WORLD sits, so raising it lowered
            // YOU. the user: "+ must be up". Negated in both directions here and
            // in applyHeight; the displayed zero (and therefore the default) is
            // unchanged, so nobody's tuned value moves.
            heightDisp = -(Double(SohVR_GetHeightM()) - Self.dioHeight0) / Self.dioHeightStep
            zoomDisp = -log(liveScale / Self.dioScale0) / log(Self.dioZoomRatio)
        }
        heightDisp = min(max(heightDisp.rounded(), placementRange.lowerBound), placementRange.upperBound)
        zoomDisp = min(max(zoomDisp.rounded(), zoomRange.lowerBound), zoomRange.upperBound)
        let h0 = Self.hudHeight0[view] ?? 0.0
        // R18-B item 1: the row's 0 is the band's FLOOR (h0 - hudFloor), not h0.
        hudDisp = ((Double(SohVR_GetHudHeightM()) - (h0 - Self.hudFloor)) / Self.hudStep).rounded()
        hudDisp = min(max(hudDisp, Self.hudRange.lowerBound), Self.hudRange.upperBound)
    }
    // Wider than the seat's +/-5: the HUD plane hangs 1.4 m away, so a
    // centimetre of plane is a small angle and 5 of them is not a control.
    // R13 item 7 (the user, 1.0.0.9): "old -18 position becomes new +5 (max),
    // range -5..+5". One display step is still 1 cm, so the whole row shifts
    // down by 23 cm and its top end lands exactly on the height he tuned to.
    // The engine's SOHVR_HUD_HEIGHT0_* moved by the same 0.23 m; see the long
    // note in SohImmersive.m for the mapping and what happens to a persisted
    // value that now falls outside the band.
    // R15 item 2: -5..+15. The zero is unchanged (an archived height keeps
    // meaning the same place); only the ceiling moved — the user, on 1.0.0.11:
    // "still too low, probably needs +15".
    // R17-A item 4: -5..+10 AT 3 cm PER STEP. the user, on 1.0.0.13: "the HUD
    // height max of 15 isn't high enough. probably should make it like 30, but
    // let's rescale it so the max is +10, then users can choose between -5 and
    // +10." So the TRAVEL is what changed: the top is +0.30 m and the bottom
    // -0.15 m about the SAME zero. Trap D34 again — the archived CVar is an
    // ABSOLUTE height in metres and keeps meaning the same place, so nothing is
    // migrated and nothing is remapped: a persisted +0.15 m simply reads +5 on
    // the row now instead of +15. `hudStep` is the one number that carries it.
    // R18-B item 1: 0..10 AT 7.5 cm PER STEP. the user, on 1.0.0.16: "can go to
    // +20 as its currently scaled, but lets not use those numbers, the scale is
    // too wide. rescale -5 to 0 and rescale the +20 to 10". R17's -5 (h0 -
    // 0.15 m) is the new 0 and R17's would-be +20 (h0 + 0.60 m) is the new 10,
    // so one step is 0.75 m / 10 = 7.5 cm and the shipped default h0 reads 2.
    // Still no migration (trap D34): the CVar is absolute metres; only the
    // number beside the slider changes. Mirrors SOHVR_HUD_HEIGHT_DOWN/_UP.
    private static let hudRange: ClosedRange<Double> = 0...10
    private static let hudStep = 0.075 // metres per display step (R17-A 0.03, R18-B 0.075)
    private static let hudFloor = 0.15 // metres below h0 that display 0 sits at

    private func applyHeight(_ d: Double) {
        switch view {
        case 1:
            SohVR_SetSeat(Float((Self.fpHeight0 + d / 100.0) * liveScale), SohVR_GetSeatFwd())
        case 2:
            var u: Float = 0, b: Float = 0
            SohVR_GetThird(&u, &b)
            SohVR_SetThird(Float((Self.thirdHeight0 + d * Self.thirdHeightStep) * liveScale), b)
        default:
            SohVR_SetHeightM(Float(Self.dioHeight0 - d * Self.dioHeightStep)) // R13 item 7: + is UP
        }
    }

    private func applyZoom(_ d: Double) {
        switch view {
        case 1:
            SohVR_SetSeat(SohVR_GetSeatUp(), Float((Self.fpZoom0 + d / 100.0) * liveScale))
        case 2:
            var u: Float = 0, b: Float = 0
            SohVR_GetThird(&u, &b)
            SohVR_SetThird(u, Float(Self.thirdZoom0 * pow(Self.thirdZoomRatio, -d) * liveScale))
        default:
            SohVR_SetScale(Float(Self.dioScale0 * pow(Self.dioZoomRatio, -d)))
        }
    }

    // No units, and a plain 0 rather than "+0".
    private func signed(_ v: Double) -> String {
        let n = Int(v.rounded())
        return n == 0 ? "0" : String(format: "%+d", n)
    }
    private func plain(_ v: Double) -> String { String(Int(v.rounded())) }

    private func pull() {
        view = Int32(SohVR_GetViewIndex())
        pullPlacement()
        dim = Double(SohVR_GetDimLevel())
        horizon = SohVR_GetFixedHorizon() != 0
        spins = SohVR_GetRealisticSpins() != 0
        flips = SohVR_GetRealisticFlips() != 0
        hands = SohVR_GetShowHands() != 0
        mirrorTop = SohVR_GetMirrorTop() != 0
        mirrorLeftHand = SohVR_GetMirrorLeftHand() != 0
        eyeScale = Double(SohVR_GetRenderScale())
        vrdbg = Int32(SohVR_GetVrDbg())
        pullDiag()
        diagUI = SohVR_GetDiagUI() != 0
        refreshStatus()
    }

    private func refreshStatus() {
        // R14 item 6: the bridge can summon the Diagnostics group while the
        // sheet is open, so the half-second tick re-reads it.
        let du = SohVR_GetDiagUI() != 0
        if du != diagUI {
            diagUI = du
        }
        hitch = String(cString: SohVR_HitchLine())
        // R9b: the view mode can change from OUTSIDE this sheet — the gamepad's
        // view-cycle binding and the bridge both call SohVR_SetView — and every
        // row below is per mode. Caught in the sim: `vr view diorama` moved the
        // world and left the picker reading "First Person" with first person's
        // numbers under it. The half-second telemetry tick is already here, so
        // it is also what re-seats the rows.
        if Int32(SohVR_GetViewIndex()) != view {
            pull()
            return
        }
        let kd = SohVR_GetKartDist()
        let err = SohVR_GetCockpitErrDeg()
        if SohVR_GetSeatFromKart() != 0 {
            // R7: cockpit error is the honest cockpit-lock number — the
            // COMPOSED eye's yaw against the kart's, so it reads ~0 with your
            // head straight however hard you are cornering, and reads your
            // head's own yaw when you look around.
            // R8: the STEERING CHECK, in words — an independent number (A's
            // kart forward against the game camera's own world forward), so it
            // shares no sign convention with what it is checking.
            let steer = SohVR_GetCamFwdErrDeg()
            let verdict = abs(steer) < 10 ? "steering OK"
                                          : String(format: "STEERING OFF BY %+.0f°", steer)
            status = String(format: "Seated on the kart — %.0f units from it, gaze %+.0f° off the kart's nose. %@",
                            kd, err, verdict)
        } else {
            status = "Not racing: the seat falls back to the game camera."
        }
        // R7 scope C: the retest asks the user to READ the engine rate at 100%,
        // and he cannot type bridge commands in the headset. So it is a row.
        perf = String(format: "Engine %.0f fps  ·  each eye %d×%d px",
                      SohVR_GetEngineFps(), SohVR_GetEyeW(), SohVR_GetEyeH())
        // R9b: and so are the two memory numbers the R9 retest opens with. The
        // rainbow fix costs ~24% more resident attachments; `alloc fails` must
        // stay 0 and `slot reuse` must stay small.
        mem = String(format: "Video memory %.0f MB  ·  alloc fails %u  ·  slot reuse %u",
                     SohVR_GetFbMB(), SohVR_GetAllocFails(), SohVR_GetSlotShown())
        // R10 item 2: the GPU-side artefact counters. `alloc fails` and
        // `display errors` must both stay 0; either one moving off zero while
        // the rainbows are on screen is the answer by itself.
        gpu = String(format: "Display errors %u  ·  alloc fails %u  ·  slot reuse %u",
                     SohVR_GetCbErrors(), SohVR_GetAllocFails(), SohVR_GetSlotShown())
        // R11 item 1: THE LEFT-EYE NUMBER. The engine stamps each eye's frame
        // tag into its own pixels; the compositor reads it back where it binds
        // and compares. Left counting up while right stays 0 IS the artefact,
        // measured — and the fix has to hold both at 0.
        eyeTag = String(format: "Eye frame mismatches — left %u, right %u (of %u/%u checks). Both must stay 0.",
                        SohVR_GetEyeTagMiss(0), SohVR_GetEyeTagMiss(1),
                        SohVR_GetEyeTagChecks(0), SohVR_GetEyeTagChecks(1))
        // R10 item 1b: the user must be able to SEE that a crash was captured,
        // without typing anything and without opening Files first.
        let last = String(cString: SohIos_LastCrashSummary())
        crash = last.isEmpty
            ? "No crash reports on this device."
            : "Last crash: \(last)  ·  \(SohIos_CrashReportCount()) report(s) saved in Files → On My Apple Vision Pro → Spaghettify."
    }

    // R8 (the user, 1.0.0.4 retest): "NOT a separate dual-column VR page; VR rows
    // go in the SAME modal as the rest of the settings." R9b goes one further —
    // these are SECTIONS, not a Form, and the sheet composes them with the
    // 3D-panel sections into ONE Form, so the VR rows are reachable from flat
    // 2D mode too (item 1) without ever becoming a second page.
    @ViewBuilder var body: some View {
        viewSection
            .onAppear {
                pull()
                // Live telemetry: the seat, the performance line and the memory
                // line all move while he drives, and all three are read by the
                // retest.
                telemetry?.invalidate()
                telemetry = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    refreshStatus()
                }
            }
            .onDisappear { telemetry?.invalidate(); telemetry = nil }
            // item 4: the pinned header's Reset button bumps the token.
            .onChange(of: resetToken) { _, _ in pull() }
        rearViewSection
        renderQualitySection
        // R14 item 6 — THE DIAGNOSTICS GROUP SHIPS HIDDEN. the user's sheet is
        // the one he uses to PLAY; ten bisect toggles, a crash caption, three
        // counter lines and an "older bisect ladder" picker are a dev
        // instrument that has been sitting in front of him for four rounds. It
        // is summoned with `vr set diagui 1` from the bridge (which is compiled
        // out of public builds entirely), so a dev round loses nothing and a
        // normal session never sees it.
        if diagUI {
            debugSection
        }
    }

    @ViewBuilder private var viewSection: some View {
        // R9b item 3: "Where you sit" is gone; the mode picker and the mode's
        // own placement pair are ONE group called "View".
        sohGroupLabel("View").id("view")
        Group {
            Picker("Mode", selection: $view) {
                Text("First Person").tag(Int32(1))
                Text("Third Person").tag(Int32(2))
                Text("Diorama").tag(Int32(0))
            }
            .pickerStyle(.segmented)
            .onChange(of: view) { _, v in
                SohVR_SetViewIndex(Int32(v))
                pull() // every tunable below is PER MODE
            }
            // R18-B item 2: FIRST PERSON HAS NO HEIGHT/ZOOM ROWS ANY MORE.
            // the user, 1.0.0.16: "lets hardcode height to -5, zoom to +5 and
            // then remove them. they dont change much anyway, but maybe have a
            // recalculate height button in case the game needs it (vr can
            // sometimes mess this up, and a recalculation fixes it)". The seat
            // is pinned in the engine (sohvr_pin_fp_seat: 3.20 u up, -0.72 u
            // forward at 8 u/m) and re-pinned on every first-person entry; the
            // archived rows' values are overridden, not migrated (trap D34).
            // Third person and Diorama keep their rows exactly as they were.
            if view == 1 {
                Button("Recalculate height") {
                    SohVR_RecalcHeight()
                    refreshStatus()
                }
                Text("Puts your seat back at the driver's eye line if VR has lost track of where your head is.")
                    .font(.caption)
            } else {
                LabeledContent("Height  \(signed(heightDisp))") {
                    Slider(value: $heightDisp, in: placementRange, step: 1)
                }
                .onChange(of: heightDisp) { _, v in applyHeight(v); refreshStatus() }
                LabeledContent("Zoom  \(signed(zoomDisp))") {
                    Slider(value: $zoomDisp, in: zoomRange, step: 1)
                }
                .onChange(of: zoomDisp) { _, v in applyZoom(v); refreshStatus() }
            }
            // R9b item 7: first person and third person are fully immersive, so
            // there is nothing to dim — the row exists only in Diorama, where
            // the default is 0 (full passthrough).
            if view == 0 {
                LabeledContent("Dim  \(Int(dim * 100))%") {
                    Slider(value: $dim, in: 0...1)
                }
                .onChange(of: dim) { _, v in SohVR_SetDimLevel(Float(v)) }
            }
            // R10 addendum: "the VR HUD plane sits a little too low by default."
            // The default moved up 8 cm in every mode; this row is the trim,
            // and 0 is the NEW default.
            LabeledContent("HUD height  \(plain(hudDisp))") { // R18-B: 0..10, no sign
                Slider(value: $hudDisp, in: Self.hudRange, step: 1)
            }
            .onChange(of: hudDisp) { _, v in
                // R11 item 4: the pane's height is DERIVED from this row now
                // (SohVR_PlacePane), so raising the HUD raises the pane with it
                // and there is nothing here left to re-read.
                // R17-A item 4: 3 cm per display step (Self.hudStep).
                // R18-B item 1: 7.5 cm per step from the floor h0 - 0.15 m.
                SohVR_SetHudHeightM(Float((Self.hudHeight0[view] ?? 0.0) - Self.hudFloor + v * Self.hudStep))
            }
            // R14 item 6: "Fixed horizon" is GONE. the user: "what is fixed
            // horizon? i don't know what that setting is" — and he is right not
            // to: it is the ORIGINAL R3 comfort-hold naming, which R10 replaced
            // with the two rows below and then left in place beside them. Two
            // controls for one idea, one of them named after its implementation.
            // The engine field survives at its default (the held-yaw follower
            // also runs whenever the seat is on the kart, which is every racing
            // frame, so the row was very nearly inert as well as confusing).
            // R10 item 5: two rows, not one. A spin-out is yaw; a flip-out is
            // the mid-air tumble a shell or a bolt throws you into. Spin-out
            // ships ON (the user's call); flip-out ships OFF and is the intense
            // one. With spin-out off the horizon now holds for EVERY spin
            // class — including a banana, which used to slip through.
            Toggle("Realistic Spin-Out", isOn: $spins)
                .onChange(of: spins) { _, v in SohVR_SetRealisticSpins(v ? 1 : 0) }
            Toggle("Realistic Flip-Out", isOn: $flips)
                .onChange(of: flips) { _, v in SohVR_SetRealisticFlips(v ? 1 : 0) }
            Toggle("Show Hands", isOn: $hands)
                .onChange(of: hands) { _, v in SohVR_SetShowHands(v ? 1 : 0) }
            // R9b item 9: no Recenter row. The head-position leash
            // (SohVR_SetHeadLock, R9a) puts the seat back by itself.
        }
        // R14 item 6: the seat/steering line and the memory line are
        // diagnostics — they move to the hidden group with the rest.
        if diagUI {
            Text(status).font(.caption)
            Text(mem).font(.caption)
        }
    }

    @ViewBuilder private var rearViewSection: some View {
        // R14 item 3 (the user, 1.0.0.10, verbatim shape): the section is called
        // "Rear View" and it has exactly TWO toggles. Auto-show is gone — the
        // feature and the row — because an item-triggered popup is a surprise in
        // a headset, and the rear-item edge detector behind it was the third
        // attempt at a control nobody asked for.
        //
        // The two are INDEPENDENT and both can be on at once: one mirror
        // texture, two planes.
        sohGroupLabel("Rear View").id("rearview")
        Toggle("Top", isOn: $mirrorTop)
            .onChange(of: mirrorTop) { _, v in SohVR_SetMirrorTop(v ? 1 : 0) }
        Toggle("Left Hand", isOn: $mirrorLeftHand)
            .onChange(of: mirrorLeftHand) { _, v in SohVR_SetMirrorLeftHand(v ? 1 : 0) }
        // R18-B item 2a: say plainly that Left Hand needs a tracked VR
        // controller. R19 item 2: Top's toggle is the LEFT stick click on both
        // a VR controller and a gamepad now (R19 item 1 moved the gamepad's).
        Text("Top sits just above the HUD — show or hide it mid-race by clicking the LEFT stick on either a VR controller or a gamepad. Left Hand needs a tracked VR controller (PlayStation VR2 Sense) and rides it like a wing mirror; with only a gamepad it shows nothing.")
            .font(.caption)
        // R21 item 1: the R20 "Jumbotron live feed" row is gone -- the
        // rainbow fix is device-confirmed, the feed is always on, and the
        // A/B survives only as the session-only `vr set jumbofeed 0`.
    }

    @ViewBuilder private var renderQualitySection: some View {
        sohGroupLabel("Render quality").id("quality")
        Group {
            // R7 (the user, 1.0.0.3): "the render scale absolutely needs to be at
            // least 100%". ONE slider, shipping at 100%. R9b item 11: the range
            // is NOT narrowed to 75-100 until the rainbow fix is proven on the
            // device at 100%.
            LabeledContent("\(Int(eyeScale * 100))% of native") {
                Slider(value: $eyeScale, in: 0.25...1.0, step: 0.05)
            }
            .onChange(of: eyeScale) { _, v in SohVR_SetRenderScale(Float(v)); refreshStatus() }
            Text(perf).font(.caption)
            Text("100% renders each eye at the headset's full per-eye resolution. Drop it only if the game feels slow-motion — the engine fps above is the number to watch.")
                .font(.caption)
            // R14 item 5: the ONE diagnostic that stays visible in normal use
            // this round, because the retest has to read it in the headset the
            // moment the jiggle happens and the user cannot type bridge commands.
            Text(hitch).font(.caption)
        }
    }

    @ViewBuilder private var debugSection: some View {
        // R10 item 2 — THE BISECT KIT, as rows.
        //
        // The R6 ladder below is kept (it is what the older notes reference),
        // but it is no longer the thing we ask the user to walk: a picker can
        // only turn ONE suspect off at a time and its levels are numbered
        // rather than named. These toggles are independent, plain-worded and
        // safe to flip mid-race, and they are ORDERED BY PRIOR PROBABILITY —
        // the first row is the likeliest cause, so his first flip is the one
        // most likely to answer the question.
        //
        // Standing requirement since R6: the user cannot type bridge commands in
        // the headset, so anything we ask him to walk ships as a row he can tap.
        sohGroupLabel("Diagnostics").id("debug")
        Group {
            Text("Chasing the rainbow flicker. Every row is ON for normal play. Turn ONE off at a time, from the top, and tell us which one stops it.")
                .font(.caption)
            // R10 item 1b: the crash line goes ABOVE the ten rows, because it is
            // the one thing here the user needs to see WITHOUT scrolling — a
            // caption below ten toggles is a caption nobody reads.
            Text(crash).font(.caption)
            ForEach(0..<Int(SohVR_DiagCount()), id: \.self) { i in
                Toggle(isOn: Binding(
                    get: { diagOn.indices.contains(i) ? diagOn[i] : true },
                    set: { v in
                        if diagOn.indices.contains(i) { diagOn[i] = v }
                        SohVR_SetDiag(Int32(i), v ? 1 : 0)
                    })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(i + 1). \(String(cString: SohVR_DiagLabel(Int32(i))))")
                        Text(String(cString: SohVR_DiagHelp(Int32(i))))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(gpu).font(.caption)
            Text(eyeTag).font(.caption)
            Button("Turn everything back on") {
                SohVR_DiagResetAll()
                pullDiag()
            }
            Text("These settings are not saved — restarting the app puts every row back on.")
                .font(.caption)
            Picker("Older bisect ladder", selection: $vrdbg) {
                ForEach(Array(Self.dbgLevels.enumerated()), id: \.offset) { i, lvl in
                    Text(Self.dbgNames[i]).tag(lvl)
                }
            }
            .onChange(of: vrdbg) { _, v in SohVR_SetVrDbg(Int32(v)) }
        }
    }

    private func pullDiag() {
        let n = Int(SohVR_DiagCount())
        diagOn = (0..<n).map { SohVR_GetDiag(Int32($0)) != 0 }
    }
}

struct SohRootView: View {
    @ObservedObject private var model = SohAppModel.shared
    // R9b item 4: bumped by the pinned header's Reset button; the VR rows watch
    // it and re-read the module when it changes.
    @State private var vrResetToken = 0
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        SohWindowView()
            .ignoresSafeArea()
            // 3D + settings in a BOTTOM ornament, pushed fully BELOW the
            // window (the default centered ornament straddles the boundary and
            // overlaps game content).
            .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
                HStack(spacing: 16) {
                    // spec D1: "3D" and "VR" side by side while flat; a
                    // single "Exit" once either space is open (the ornament
                    // stays visible and interactive even in FULL immersion —
                    // R0 measured that, artifacts/vr-r0/v2b-full.png).
                    if model.mode == 0 {
                        Button("3D") { Soh_EnterMode(1) }
                        Button("VR") { Soh_EnterMode(2) }
                    } else {
                        Button(model.mode == 2 ? "Exit VR" : "Exit 3D") { Soh_EnterMode(0) }
                    }
                    // D-041: no "Menu" button in 3D. The enhancements menu is
                    // display-only on the panel (no in-immersive input — that
                    // would need gaze/RealityKit or a second nav model), so
                    // opening it there was a dead end. 3D-panel comfort settings
                    // live in the gear sheet below; for the full menu, tap
                    // "Exit 3D", change it in 2D (fully touch-interactive), and
                    // tap "3D" again — the transition is seamless.
                    // ONE gear, and R8 makes it ICON ONLY. the user, verbatim on
                    // the 1.0.0.4 retest: "do not write SETTINGS, that is
                    // stupid, redundant and outside the scope of every port
                    // we've ever done." R7 still shipped a Label with text
                    // ("VR Settings" / "Settings") next to the glyph; it is a
                    // bare gearshape now, with the words carried only by the
                    // accessibility label. It opens the SAME sheet in every
                    // mode — the sheet decides which rows exist.
                    Button {
                        model.showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Settings")
                }
                .font(.title3)
                .buttonStyle(.borderless)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassBackgroundEffect()
                .opacity(0.85)
                .padding(.top, 14)
            }
            // SwiftUI sheet (a UIKit modal silently fails over an open
            // ImmersiveSpace). Width-only frame; own Done bar.
            .sheet(isPresented: $model.showSettings) {
                VStack(spacing: 0) {
                    HStack {
                        // R8: ONE modal, one title. Not "VR Settings" vs "3D
                        // Screen Settings" — the VR rows are rows in the same
                        // settings modal as everything else, and a modal that
                        // renames itself reads as a second page.
                        Text("Settings")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Button("Done") { model.showSettings = false }
                            .font(.title3)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    Divider()
                    // R11 item 5: BOTH groups, ALWAYS, each under its own
                    // sticky section header carrying its own Reset. R9b's
                    // chrome header is gone — it could not pin per section, so
                    // it titled the 3D rows "VR Settings" — and so is R9b's
                    // `if !vr` gate, which is what took the 3D-panel rows off
                    // the sheet in 2D. `.plain` is the list style that pins
                    // section headers on this platform.
                    ScrollViewReader { proxy in
                        List {
                            // R13 item 6 — THE RULE, third iteration, in
                            // the user's own words: in VR mode ONLY the VR section
                            // shows; in 3D mode ONLY the 3D section shows; in 2D
                            // BOTH show. It supersedes R12 item 2, which read
                            // his "the 3D Settings section needs to be HIDDEN
                            // when you're in 3D mode" as a one-way hide and left
                            // VR showing both — so 1.0.0.9 put the panel rows in
                            // front of him in the headset, which is what he came
                            // back about.
                            //
                            // Hiding means dropping the whole Section, header
                            // included: a pinned header over an empty group is
                            // the R9b regression again. The VR loop's non-world
                            // fallback still uses the panel placement; it is
                            // simply tuned from 2D, where both sections are
                            // present, rather than from inside the headset.
                            if model.mode != 2 {
                                Section {
                                    Soh3DSettingsView()
                                } header: {
                                    sohStickyHeader("3D Settings") { Soh3DSettingsView.resetAll() }
                                }
                            }
                            if model.mode != 1 {
                                Section {
                                    SohVRSettingsView(resetToken: vrResetToken)
                                } header: {
                                    sohStickyHeader("VR Settings") {
                                        SohVR_ResetVRDefaults()
                                        vrResetToken += 1
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .onChange(of: model.settingsScrollSeq) { _, _ in
                            withAnimation { proxy.scrollTo(model.settingsScrollTo, anchor: .top) }
                        }
                    }
                }
                // R8: one width for both contexts — the dual-column VR page is
                // gone, so the VR sheet is the same single-column modal shape.
                .frame(minWidth: 700)
            }
            .onChange(of: model.mode) { _, mode in
                NSLog("[Soh3D] Swift: space mode onChange -> \(mode)")
                Task {
                    if mode == 1 {
                        Soh3DSettingsView.applyAll() // panel state before first frame
                        sohStartAudioReanchor()
                        let r = await openImmersiveSpace(id: "Soh3D")
                        NSLog("[Soh3D] Swift: openImmersiveSpace(Soh3D) -> \(String(describing: r))")
                        if case .error = r {
                            Soh_EnterMode(0) // roll back engine offscreen mode
                        } else {
                            sohSetAudioFrontStage(true)
                        }
                    } else if mode == 2 {
                        Soh3DSettingsView.applyAll() // the panel fallback uses it too
                        sohSetAudioBypassed(true)
                        let r = await openImmersiveSpace(id: "SohVR")
                        NSLog("[SohVR] Swift: openImmersiveSpace(SohVR) -> \(String(describing: r))")
                        if case .error = r {
                            sohSetAudioBypassed(false)
                            Soh_EnterMode(0)
                        }
                    } else {
                        await dismissImmersiveSpace()
                        NSLog("[Soh3D] Swift: dismissed immersive")
                        sohStopAudioReanchor()
                        // Audio restored BEFORE the finalize, never after
                        // (spec D8 / trap C3).
                        sohSetAudioBypassed(false)
                        sohSetAudioFrontStage(false)
                        // The window never deactivates under mixed immersion —
                        // this is the authoritative back-to-2D trigger.
                        Soh_Exit3DFinalize()
                    }
                }
            }
    }
}

@main
struct SohVisionApp: App {
    @ObservedObject private var model = SohAppModel.shared
    var body: some Scene {
        WindowGroup {
            SohRootView()
        }
        ImmersiveSpace(id: "Soh3D") {
            CompositorLayer(configuration: SohCompositorConfiguration()) { layerRenderer in
                // This closure runs on the MAIN thread; the frame loop must
                // NOT (it would block the engine's display-link pump).
                NSLog("[Soh3D] Swift: CompositorLayer ready — spawning render thread")
                let renderThread = Thread { Soh3D_Immersive_Run(layerRenderer) }
                renderThread.name = "Soh3D-Immersive"
                renderThread.stackSize = 2 << 20
                renderThread.start()
            }
        }
        // Mixed = panel floats in passthrough. Merely ALLOWING .progressive
        // changes the drawable contract and encode_present aborts. This
        // configuration is FROZEN (spec D1) — VR gets its own space rather
        // than widening this one.
        .immersionStyle(selection: .constant(.mixed), in: .mixed)

        // VR (spec D1/D3). ONE space with a live-switchable style set:
        // R0 proved that exact configuration presents 2233 frames across three
        // live switches with a byte-identical drawable contract, so per-mode
        // surroundings do not need a second space.
        ImmersiveSpace(id: "SohVR") {
            CompositorLayer(configuration: SohCompositorConfiguration()) { layerRenderer in
                NSLog("[SohVR] Swift: CompositorLayer ready — spawning VR render thread")
                let renderThread = Thread { SohVR_Immersive_Run(layerRenderer) }
                renderThread.name = "SohVR-Immersive"
                renderThread.stackSize = 2 << 20
                renderThread.start()
            }
        }
        .immersionStyle(selection: Binding<any ImmersionStyle>(
            get: { () -> any ImmersionStyle in
                return model.vrFullImmersion ? FullImmersionStyle.full : MixedImmersionStyle.mixed
            },
            set: { _ in }), in: .mixed, .full)
        // R9b item 8: the wearer's own arms, off by default.
        .upperLimbVisibility(model.vrShowHands ? .visible : .hidden)
    }
}
