// SohHostViewController.h — boots the SDL/SoH engine under the SwiftUI app
// entry (visionOS only) and owns the 2D<->3D transition sequencing (D-030).
#pragma once

#import <UIKit/UIKit.h>

@interface SohHostViewController : UIViewController
@end

#ifdef __cplusplus
extern "C" {
#endif

// Enter/leave the stereoscopic 3D mode. Owns the engine-side sequencing;
// flips the SwiftUI state (Soh_SetSpaceMode) that opens/dismisses the
// actual ImmersiveSpace.
void Soh_Enter3D(bool on);

// Tri-state entry (VR-spec D1): 0 = flat, 1 = 3D panel, 2 = VR. A switch
// between the two immersive modes sequences as dismiss-then-open; Soh_Enter3D
// and Soh_EnterVR are thin wrappers.
void Soh_EnterMode(int mode);
void Soh_EnterVR(bool on);

// Which immersive space is open (0/1/2), as opposed to Soh_Get3DMode which is
// the engine's "rendering offscreen" flag and is 1 for BOTH immersive modes.
int Soh_GetSpaceMode(void);

// Called from SwiftUI after dismissImmersiveSpace completes — the authoritative
// back-to-2D trigger (the 2D window never deactivates under mixed immersion).
void Soh_Exit3DFinalize(void);

// True while 3D mode is active (engine offscreen, space open or opening).
int Soh_Get3DMode(void);

#ifdef __cplusplus
}
#endif
