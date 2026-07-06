# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

SariliScan is an iOS app (SwiftUI + ARKit) exploring on-device pupillary distance (PD) measurement and frontal face dimensions (face width, bridge width/height) for eyewear fitting. It is a **research/test-harness codebase**, not a shipping medical product: most screens exist to compare competing measurement methods against each other and against clinical ground truth, not to present a single polished result to an end user. Expect debug overlays, multiple parallel implementations of the same measurement, and empirical constants marked as unvalidated.

## Build & run

- Open `SariliScan.xcworkspace` in Xcode (NOT `SariliScan.xcodeproj` — CocoaPods requires the workspace).
- After adding/changing pods, run `pod install` from the repo root (Podfile targets iOS 17.0, pod `MediaPipeTasksVision`).
- There is no CLI test target/scheme in this repo — build and run from Xcode on a physical device. **Face tracking (ARFaceTrackingConfiguration) requires a real iPhone with a TrueDepth (Face ID) camera; it does not work in the Simulator.** The card-PD flow (`CardPDView`) only needs a front camera and can be tested on more devices, but still needs a physical device for camera access.
- No linter/formatter config is present; match existing style (see conventions below).

## Architecture

### Independent top-level flows, one camera session at a time

`SariliScanApp.swift` → `RootView` switches between exactly one mode at a time, ensuring only one AVCaptureSession/ARSession is ever active:
- **`ContentView`** — the ARKit face-scan flow (PD via TrueDepth face tracking, plus the milestone-9 face-dimension harness and the milestone-10 face-shape ratios).
- **`CardPDView`** — a separate, simpler credit-card-reference PD test harness (manual taps only, no ARKit, works without TrueDepth). Math: `mm_per_pixel = 85.6 / card_pixel_width_px`, then `PD_mm = pupil_pixel_distance_px * mm_per_pixel`.
- **`ProfileCaptureView`** — milestone 11's side-profile harness (raw TrueDepth streaming via AVFoundation, no ARKit — face tracking loses the face at profile angles).

These flows share no state and should stay decoupled — don't reach across `onOpenCardPD`/`onOpenProfile`/`onClose` for anything beyond switching modes.

### The face-scan pipeline (ContentView + ARFaceTrackingView)

`ARFaceTrackingView` (`UIViewRepresentable` wrapping `ARSCNView`) owns the ARKit session and SceneKit face-mesh rendering. Its `Coordinator` is both `ARSCNViewDelegate` (mesh/dots) and `ARSessionDelegate` (frame processing). Per frame, it copies ARKit data into a `FaceAnchorSample` (a `Sendable` value type — see `FaceAnchorSample.swift`) on the render thread and dispatches it to the main thread via `onSampleReady`. **This boundary is deliberate: the non-Sendable `ARFaceAnchor` must never cross into main-actor UI code.** When extending the sample with new per-frame data, add it to `FaceAnchorSample`, not by threading the anchor itself further.

`ContentView.handleSample(_:)` on the main thread is where all measurement happens — it is intentionally decoupled from mesh rendering and the render thread.

### Four independent PD ("pupillary distance") measurement methods, compared side by side

The codebase computes PD four different ways simultaneously, purely so they can be diagnostically compared — there is no single "winning" method wired in yet:

1. **ARKit eye-transform PD** (raw + corrected) — `PDCorrection.swift`. ARKit's `leftEyeTransform`/`rightEyeTransform` sit at the eyeball *rotation centre*, ~11mm behind the pupil plane, which overreads PD. `PDCorrection.correctedPD` projects each eye origin forward along its own gaze axis onto the pupil plane before measuring. The 11mm offset (`rotationCentreToPupilMM`) is an empirical constant pending clinical validation, not an anatomical fact.
2. **Eyelid-centroid PD** — centroid of manually-identified eyelid rim mesh vertices (`EyeLandmarks.swift`), transformed to world space in `ContentView.worldEyeCentre`. ARKit's face mesh has no iris/pupil vertices, only eyelid rim loops, so this is an approximation. `EyeLandmarks.leftEyeRim`/`rightEyeRim` are **intentionally empty until populated on-device** — never invent indices here; get them from the blink-based auto-detector or the tap-to-identify tool.
3. **Vision-framework pupil PD** — `VisionPupilDetector.swift`, a 4-stage pipeline (detect pixels → pick depth source → px→mm → assemble readout) using `VNDetectFaceLandmarksRequest`. Deliberately computes coordinates *two* ways in parallel (manual bbox composition vs Apple's `pointsInImage`) so a coordinate-space bug would show up as visual disagreement between the two overlays, rather than being silently wrong.
4. **MediaPipe iris PD** (milestone 8) — `MediaPipePDEstimator.swift`, using MediaPipe FaceLandmarker's true iris landmarks (indices 468/473) since Vision's pupil landmark was found on-device not to lock onto the actual pupil. Requires the frame be rotated/mirrored to upright BGRA *before* MediaPipe sees it (passing an orientation flag to `MPImage` instead was observed to return landmarks in the wrong coordinate space — do not "simplify" this back).

All four share depth from the same source (the ARKit eye-transform plane projected to the pupil plane) and the same focal length from `frame.camera.intrinsics`, so their differences reflect the detection stage only, not scale.

When touching PD code, preserve this "compare, don't collapse" structure — don't merge the four methods into one until a validation panel (clinical pupilometer ground truth) says which is actually correct. Constants like `rotationCentreToPupilMM`, `pdCalibrationOffsetMM`, and the positioning-guidance thresholds in `ContentView` (`goodDistanceRangeM`, `maxHeadAngleDegrees`) are all fit from an n=1 or n=2 comparison and are explicitly flagged in comments as starting points, not specs.

### Face dimensions (milestone 9) — `FaceDimensions.swift`

Face width needs no fixed vertex indices: it's computed fresh each frame as the widest x-extent of the mesh within a horizontal band at eye height (`eyeBandHalfHeightMM`). Bridge width/height *do* need specific mesh vertices (nose bridge L/R, saddle), and the project's rule is: **never hardcode a vertex index in source.** Instead, indices are assigned on-device via the tap-to-identify UI (`FaceDimsAssignBar`) and persisted in `UserDefaults` (`FaceDimensions.loadIndex`/`saveIndex`). This works because the ARKit face mesh has a fixed topology (~1220 vertices) — an index confirmed on one face/frame holds for all faces and frames. The same rule applies to `EyeLandmarks.leftEyeRim`/`rightEyeRim`.

### Face-shape ratios (milestone 10) — `FaceShapeRatios.swift` — BUILT, UNVALIDATED

Index-free like milestone 9's face width: every width is the widest mesh x-extent in a horizontal band, with band positions defined as fractions of face height (chin→mesh-top), so they scale with the face. The deliverable is the **ratios** (width:length, forehead:cheek, jaw:cheek) — deliberately robust to the mesh's absolute-scale error that milestone 9 exists to quantify. The band fractions (`foreheadCentreT`, `jawCentreT`, `bandHalfT`) are empirical starting values; the readout shows band vertex counts and where the max width actually sits so they can be tuned on device. The shape label from `classify` is a coarse heuristic for eyeballing only. Validation = run on several faces whose shape category humans agree on; check the ratios separate them.

### Profile capture (milestone 11) — `ProfileCaptureView.swift` — BUILT, UNVALIDATED

Raw TrueDepth streaming (synchronized `AVCaptureVideoDataOutput` + `AVCaptureDepthDataOutput`, 4:3 preset so video/depth share a field of view), no ARKit. Capture freezes a frame; the user taps outer eye corner + top of ear junction; each tap is back-projected through the depth map and per-frame camera intrinsics to a 3D camera-space point (`ProfileMath`), reusing the `mm = px × depth / f` math milestone 8 validated. **The milestone 8 coordinate-space lesson is enforced structurally**: all math lives in raw sensor-buffer space; only the display image is rotated upright (`.leftMirrored`), and taps are mapped back by the inverse transform (a transpose) before touching depth or intrinsics. A CoreMotion tilt readout keeps the phone upright (head pitch is unknowable here — no face anchor in profile). Per-side (L/R) results persist on screen for asymmetry comparison. Unvalidated: the eye→ear distances vs a ruler, the vertical-drop sign convention, and the tap→raw transpose all need on-device confirmation.

### Debug/calibration tooling embedded in the main UI

A large fraction of `ContentView.swift` and `ARFaceTrackingView.swift` is debug instrumentation, not product UI — vertex-dot rendering, tap-to-identify, the blink-based `EyelidIndexDetector` auto-calibration, the Vision orientation/mapping-mode cycling controls, and the countdown-capture calibration flow. These are marked `DEBUG-ONLY` in comments; keep that marking pattern when adding new instrumentation so a future pass knows what's safe to strip before any real release build.

## Conventions to follow

- **All measurement math takes a `Sendable` value-type snapshot** (`FaceAnchorSample`, `VisionDebugInfo`, `MediaPipeDebugInfo`, etc.) rather than passing ARKit/Vision reference types across threads. Follow this pattern for any new per-frame data.
- **Never invent mesh vertex indices.** Get them from on-device tooling (tap-to-identify or the blink detector) and persist/paste them, with a comment noting they're unconfirmed until checked on-device.
- **Flag empirical constants as such** — every calibration constant in this codebase (offsets, thresholds, band heights) carries a comment explaining it's fit from limited on-device comparison, not derived. Keep that discipline for new constants; don't state them as if they were validated.
- Comments in this codebase tend to explain *why* a non-obvious approach was chosen (e.g. why BGRA conversion happens before MediaPipe, why depth uses the pupil-plane projection instead of the eye-transform origin) — match that tone for anything genuinely surprising, rather than describing what the code visibly does.
