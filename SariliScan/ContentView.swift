//
//  ContentView.swift
//  SariliScan
//
//  Created by Tez on 24/6/2026.
//

import SwiftUI
import AVFoundation
import ARKit
import simd

struct ContentView: View {
    var onOpenCardPD: () -> Void = {}
    var onOpenProfile: () -> Void = {}
    var onOpenSkinTone: () -> Void = {}

    @State private var faceDetected = false
    @State private var scanState: ScanState = .requestingPermission
    @State private var readout: FaceReadout?
    @State private var showVertexDots = false
    @State private var tappedVertex: Int?
    @State private var frozen = false   // milestone 9: freeze-frame for stable vertex taps

    // DEBUG-ONLY: automatic eyelid index detection state.
    @State private var detector = EyelidIndexDetector()
    @State private var detecting = false
    @State private var detectedLeft: [Int] = []
    @State private var detectedRight: [Int] = []
    @State private var visionDebug: VisionDebugInfo?   // latest Vision diagnostics (async)
    @State private var mediaPipeDebug: MediaPipeDebugInfo?   // latest MediaPipe iris PD (async)
    @State private var visionOrientation: VisionImageOrientation = .initial
    @State private var mappingMode: MappingMode = .normal
    @State private var previewMapping: PreviewMapping = .aspectFill

    // Milestone 7: countdown capture — median PD over ~45 frames while the user
    // fixates a DISTANT target (not the screen). This is the calibration
    // experiment: median raw vs clinical ground truth fits the bias constant.
    @State private var measurePhase: MeasurePhase = .idle
    @State private var measureBuffer: [(raw: Float, corrected: Float)] = []
    @State private var measureResult: MeasureResult?
    
    // Milestone 9: face-dimension harness. Bridge vertex slots are assigned
    // on-device via the tap-to-identify tool (indices are never invented in
    // code; fixed mesh topology means a confirmed index holds for every face).
    // Assignments persist across relaunch via UserDefaults.
    @State private var faceDims: FaceDimensionsReadout?
    @State private var bridgeLIndex: Int? = FaceDimensions.loadIndex("bridgeL")
    @State private var bridgeRIndex: Int? = FaceDimensions.loadIndex("bridgeR")
    @State private var saddleIndex: Int? = FaceDimensions.loadIndex("saddle")

    // Milestone 10: index-free face-shape ratios (see FaceShapeRatios.swift).
    @State private var faceShape: FaceShapeReadout?

    // Geometric suggestions for the bridge slots (the orange guide dots) —
    // recomputed live so the guide tracks the face until the user freezes.
    @State private var bridgeSuggestion: (bridgeL: Int, bridgeR: Int, saddle: Int)?

    enum MeasurePhase: Equatable {
        case idle, countdown(Int), collecting, result
    }

    struct MeasureResult: Sendable {
        let medianRaw: Float
        let medianCorrected: Float
        let spreadRaw: Float      // max - min across the capture
        let frames: Int
    }

    /// Clinical reference for the calibration delta shown on the result card.
    /// n=1 (Simon's pupilometer value) — panel-fit before trusting generally.
    private let clinicalReferencePDMM: Float = 63.0
    
    // MARK: - Positioning guidance (heuristic, not clinically validated)
    //
    // On-device testing (two subjects, identical 63.0mm clinical PD) showed
    // every PD method drifting several mm high when the phone was held closer
    // than ~30cm (TrueDepth's depth estimate gets less reliable near its
    // minimum range) or when head yaw exceeded ~20° (off-axis geometry biases
    // both the image-based and ARKit-transform methods). These thresholds are
    // a starting guardrail from that one comparison, not a validated spec —
    // revisit against a larger panel before trusting the exact numbers.
    private let goodDistanceRangeM: ClosedRange<Float> = 0.30...0.45
    private let maxHeadAngleDegrees: Float = 12

    /// Non-nil when the current pose should be corrected before measuring;
    /// nil means positioning looks good. Falls back to a generic instruction
    /// before any frame has been analysed yet.
    private var positioningGuidance: String? {
        guard let visionDebug else {
            return "Hold the phone at arm's length, facing the camera"
        }
        if visionDebug.depthMetres < goodDistanceRangeM.lowerBound {
            return "Move the phone farther away"
        }
        if visionDebug.depthMetres > goodDistanceRangeM.upperBound {
            return "Move the phone a little closer"
        }
        if abs(visionDebug.yaw) > maxHeadAngleDegrees || abs(visionDebug.pitch) > maxHeadAngleDegrees {
            return "Face the camera more directly"
        }
        return nil
    }

    enum ScanState {
        case requestingPermission
        case cameraDenied
        case unsupported       // device has no TrueDepth camera / no face tracking
        case ready             // camera authorized and face tracking supported
    }

    /// ARKit-side PD values for one frame. Single frame, no averaging.
    struct FaceReadout: Sendable {
        let eyeTransformPDmm: Float      // raw rotation-centre PD, millimetres
        let correctedPDmm: Float         // gaze-axis pupil-plane corrected PD
        let offsetAppliedMM: Float       // the correction constant, for the readout
        let eyelidPDmm: Float?           // eyelid-centroid PD (world space); kept in code, not surfaced
    }

    var body: some View {
        ZStack(alignment: .top) {
            switch scanState {
            case .ready:
                ARFaceTrackingView(faceDetected: $faceDetected,
                                   showVertexDots: showVertexDots,
                                   frozen: frozen,
                                   onSampleReady: handleSample,
                                   onVertexPicked: { tappedVertex = $0 },
                                   highlightedVertices: detectedLeft + detectedRight
                                       + [bridgeLIndex, bridgeRIndex, saddleIndex].compactMap { $0 },
                                   suggestedVertices: suggestionDots,
                                   onVisionDebug: { visionDebug = $0 },
                                   onMediaPipeDebug: { mediaPipeDebug = $0 },
                                   visionOrientation: visionOrientation)
                    .ignoresSafeArea()
                    .overlay { pupilOverlay }
            case .cameraDenied:
                deniedView
            case .unsupported:
                unsupportedView
            case .requestingPermission:
                Color.black
                    .ignoresSafeArea()
            }

            statusBadge

            // One instructional prompt owns the screen at a time: the PD
            // measure UI hides while the vertex-assignment flow is active.
            // zIndex keeps the result card (and its Done button) above the
            // debug readout panel, which otherwise renders over it and eats
            // its taps (seen on device).
            if scanState == .ready, !showVertexDots {
                measureUI
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .zIndex(10)
            }

            // Entries to the separate flows: card-reference PD (works without
            // TrueDepth) and raw-TrueDepth profile capture (milestone 11).
            VStack(alignment: .trailing, spacing: 8) {
                harnessButton("Skin tone", "paintpalette", onOpenSkinTone)
                harnessButton("Profile", "person.crop.rectangle", onOpenProfile)
                harnessButton("Card PD", "creditcard", onOpenCardPD)
            }
            .tint(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.bottom, 24)
            .padding(.trailing, 16)

            if scanState == .ready {
                vertexToggle
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 20)
                    .padding(.trailing, 16)

                visionControls
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 20)
                    .padding(.leading, 16)
            }

            if scanState == .ready, showVertexDots {
                tapIdentifyBadge
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 76)
                
                // Milestone 9: assign the tapped vertex to a bridge/saddle slot.
                FaceDimsAssignBar(tapped: tappedVertex,
                                  suggested: currentStepSuggestion,
                                  bridgeL: $bridgeLIndex,
                                  bridgeR: $bridgeRIndex,
                                  saddle: $saddleIndex)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 120)

                detectionPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(12)
            } else if scanState == .ready, let readout {
                debugOverlay(readout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(16)
            }
        }
        .task {
            await startSession()
        }
        .onChange(of: faceDetected) { _, isDetected in
            // Clear the live readout the moment the face is lost.
            if !isDetected { readout = nil }
        }
    }

    // MARK: - Status overlay

    private var statusBadge: some View {
        Text(statusText)
            .font(.headline)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 24)
            .padding(.horizontal, 24)
    }

    private var statusText: String {
        switch scanState {
        case .ready:
            return faceDetected ? "Face detected" : "No face detected"
        case .cameraDenied:
            return "Camera access denied"
        case .unsupported:
            return "Face tracking not supported on this device"
        case .requestingPermission:
            return "Requesting camera access…"
        }
    }

    // MARK: - Countdown PD measurement (milestone 7 calibration)

    @ViewBuilder
    private var measureUI: some View {
        switch measurePhase {
        case .idle:
            // Top-trailing, below the Vertices toggle, so the debug readout
            // panel can't cover it.
            VStack(spacing: 8) {
                Text("Hold the phone at arm's length, face the camera\ndirectly, then look at something far away")
                    .font(.system(.caption2, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
                if let positioningGuidance {
                    Text(positioningGuidance)
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundStyle(.yellow)
                }
                Button { startMeasurement() } label: {
                    Label("Measure PD (look far)", systemImage: "scope")
                        .font(.system(.subheadline, design: .monospaced))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .tint(.yellow)
                .disabled(positioningGuidance != nil)
                .opacity(positioningGuidance != nil ? 0.5 : 1)
            }
            .padding(12)
            .frame(maxWidth: 260)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 64)
            .padding(.trailing, 16)
        case .countdown(let n):
            VStack(spacing: 8) {
                Text("Look at a DISTANT target").font(.headline)
                Text("\(n)").font(.system(size: 64, weight: .bold, design: .monospaced))
                if let positioningGuidance {
                    Text(positioningGuidance)
                        .font(.system(.subheadline, design: .monospaced).bold())
                        .foregroundStyle(.yellow)
                }
            }
            .foregroundStyle(.white)
            .padding(24)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
        case .collecting:
            VStack(spacing: 8) {
                Text("Measuring… keep looking far")
                    .font(.headline)
                    .foregroundStyle(.yellow)
                if let positioningGuidance {
                    Text(positioningGuidance)
                        .font(.system(.subheadline, design: .monospaced).bold())
                        .foregroundStyle(.orange)
                }
            }
            .padding(16)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
        case .result:
            if let r = measureResult {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PD capture — median of \(r.frames) frames").font(.headline)
                    Group {
                        Text("Median raw PD:        \(mm(r.medianRaw))")
                        Text("Median corrected PD:  \(mm(r.medianCorrected))")
                        Text("Spread (max−min):     \(mm(r.spreadRaw))")
                        Text("Clinical reference:   \(mm(clinicalReferencePDMM))")
                        Text("Raw − clinical bias:  \(String(format: "%+.1fmm", r.medianRaw - clinicalReferencePDMM))")
                    }
                    .font(.system(.caption, design: .monospaced))
                    Button("Done") { measurePhase = .idle; measureResult = nil }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                }
                .foregroundStyle(.white)
                .padding(16)
                .frame(maxWidth: 320)
                .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
                // Sit in the clear zone below the top control rows, well away
                // from the debug readout that anchors bottom-leading — centred
                // placement left the Done button buried under it on device.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 170)
            }
        }
    }

    private func startMeasurement() {
        measureBuffer = []
        measureResult = nil
        Task { @MainActor in
            for n in [3, 2, 1] {
                measurePhase = .countdown(n)
                try? await Task.sleep(for: .seconds(1))
            }
            measurePhase = .collecting
        }
    }

    private func finishMeasurement() {
        func median(_ values: [Float]) -> Float {
            let s = values.sorted()
            let m = s.count / 2
            return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
        }
        let raws = measureBuffer.map(\.raw)
        measureResult = MeasureResult(
            medianRaw: median(raws),
            medianCorrected: median(measureBuffer.map(\.corrected)),
            spreadRaw: (raws.max() ?? 0) - (raws.min() ?? 0),
            frames: measureBuffer.count)
        measurePhase = .result
    }

    // MARK: - Vertex identifier toggle

    private var vertexToggle: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                showVertexDots.toggle()
                if showVertexDots {
                    // Entering assignment mode hides the measure UI, so cancel
                    // any in-flight/finished PD capture — otherwise it lingers
                    // invisibly (collecting silently, or holding a stale
                    // result card that reappears later).
                    measurePhase = .idle
                    measureResult = nil
                } else {
                    frozen = false   // never stay frozen with dots off
                }
            } label: {
                Label(showVertexDots ? "Vertices: ON" : "Vertices: OFF",
                      systemImage: "circle.grid.3x3.fill")
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .tint(showVertexDots ? .green : .white)

            // Milestone 9: freeze the frame so a vertex can be tapped without
            // the mesh moving under the finger.
            if showVertexDots {
                Button {
                    frozen.toggle()
                } label: {
                    Label(frozen ? "Frozen — tap dots" : "Freeze frame",
                          systemImage: frozen ? "pause.circle.fill" : "pause.circle")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .tint(frozen ? .yellow : .white)
            }
        }
    }
    /// Suggestion for the assignment step the user is currently ON — the bar
    /// works through the slots in order, so the first unassigned slot is the
    /// current step. Nil once all three are assigned.
    private var currentStepSuggestion: Int? {
        guard let s = bridgeSuggestion else { return nil }
        if bridgeLIndex == nil { return s.bridgeL }
        if bridgeRIndex == nil { return s.bridgeR }
        if saddleIndex == nil { return s.saddle }
        return nil
    }

    /// Orange guide dots: suggestions for slots not yet assigned (assigned
    /// slots already show teal, so suggesting them too would just overlap).
    private var suggestionDots: [Int] {
        guard showVertexDots, let s = bridgeSuggestion else { return [] }
        return [bridgeLIndex == nil ? s.bridgeL : nil,
                bridgeRIndex == nil ? s.bridgeR : nil,
                saddleIndex == nil ? s.saddle : nil].compactMap { $0 }
    }

    /// One capsule entry button per sibling harness flow — a single helper so
    /// the styling can't drift between them.
    private func harnessButton(_ title: String, _ icon: String,
                               _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// DEBUG-ONLY: shows the index of the most recently tapped mesh vertex, so
    /// eyelid rim indices can be read off and pasted into EyeLandmarks.swift.
    private var tapIdentifyBadge: some View {
        Text(tappedVertex.map { "Tapped vertex: \($0)" } ?? "Tap a dot to identify its index")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(tappedVertex == nil ? .white : .yellow)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
    }

    // MARK: - Automatic eyelid detection (debug)

    /// DEBUG-ONLY: blink-based eyelid index detection. Start it, blink a few
    /// times; detected indices are used live and can be copied into code.
    private var detectionPanel: some View {
        let hasResult = !detectedLeft.isEmpty || !detectedRight.isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            Text(detecting
                 ? "Detecting… blink 3 times, hold still"
                 : (hasResult ? "Detected ✓ (using live)" : "Auto-detect eyelid vertices via blink"))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(detecting ? .yellow : (hasResult ? .green : .white))

            VStack(alignment: .leading, spacing: 4) {
                Text("Left eyelid indices:  \(format(detectedLeft))")
                Text("Right eyelid indices: \(format(detectedRight))")
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.white)
            .lineLimit(3)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button(detecting ? "Detecting…" : "Detect (blink 3×)", action: startDetection)
                    .disabled(detecting)
                Button("Copy indices", action: copyIndices)
                    .disabled(!hasResult)
            }
            .font(.caption2)
            .controlSize(.small)
            .buttonStyle(.bordered)
            .tint(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .padding(12)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    private func format(_ list: [Int]) -> String {
        "[" + list.map(String.init).joined(separator: ", ") + "]"
    }

    private func startDetection() {
        detectedLeft = []
        detectedRight = []
        detector = EyelidIndexDetector()   // fresh run
        detecting = true
    }

    private func copyIndices() {
        let text = """
        Left eyelid rim indices:
        \(format(detectedLeft))

        Right eyelid rim indices:
        \(format(detectedRight))
        """
        UIPasteboard.general.string = text
    }

    // MARK: - Vision debug controls (orientation / mapping / preview)

    private var visionControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            cycleButton("Orient: \(visionOrientation.rawValue)", "rotate.3d") {
                visionOrientation = cycle(visionOrientation, VisionImageOrientation.allCases)
            }
            cycleButton("Map: \(mappingMode.rawValue)", "arrow.left.arrow.right") {
                mappingMode = cycle(mappingMode, MappingMode.allCases)
            }
            cycleButton("Fit: \(previewMapping.rawValue)", "rectangle.dashed") {
                previewMapping = cycle(previewMapping, PreviewMapping.allCases)
            }
        }
    }

    private func cycleButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .tint(.white)
    }

    private func cycle<T: Equatable>(_ value: T, _ all: [T]) -> T {
        guard let i = all.firstIndex(of: value) else { return value }
        return all[(i + 1) % all.count]
    }

    // MARK: - Landmark overlay (debug)

    /// Draws BOTH coordinate conversions so we can tell whether our manual
    /// composition is wrong or Vision's landmarks themselves are poor.
    ///   white       = face bounding box
    ///   MANUAL (filled): green/blue eye contours, yellow/pink pupil pts, red centres + cyan line
    ///   APPLE  (hollow): green/blue eye contours, orange/purple pupil pts, white centres + white line
    private var pupilOverlay: some View {
        Canvas { ctx, size in
            // MediaPipe iris centres (milestone 8): magenta — drawn even if the
            // Vision layer has nothing, so the two detectors compare visually.
            if let mp = mediaPipeDebug, let ln = mp.leftIrisNorm, let rn = mp.rightIrisNorm,
               let vd = visionDebug, let mpImageSize = vd.imageSize {
                let lp = mapNormalized(ln, mpImageSize, size)
                let rp = mapNormalized(rn, mpImageSize, size)
                var line = Path(); line.move(to: lp); line.addLine(to: rp)
                ctx.stroke(line, with: .color(Color(red: 1, green: 0, blue: 1)), lineWidth: 2)
                for p in [lp, rp] {
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                             with: .color(Color(red: 1, green: 0, blue: 1)))
                }
            }

            guard let v = visionDebug, let lm = v.landmarks, let imageSize = v.imageSize else { return }
            func m(_ n: CGPoint) -> CGPoint { mapNormalized(n, imageSize, size) }
            func dot(_ p: CGPoint, _ r: CGFloat, _ color: Color) {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                         with: .color(color))
            }
            func ring(_ p: CGPoint, _ r: CGFloat, _ color: Color) {
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                           with: .color(color), lineWidth: 1.5)
            }
            func link(_ a: CGPoint, _ b: CGPoint, _ color: Color, _ width: CGFloat) {
                var line = Path(); line.move(to: a); line.addLine(to: b)
                ctx.stroke(line, with: .color(color), lineWidth: width)
            }

            // Bounding box (map all 4 corners so flips stay correct).
            let bb = lm.boundingBox
            let corners = [CGPoint(x: bb.minX, y: bb.minY), CGPoint(x: bb.maxX, y: bb.minY),
                           CGPoint(x: bb.maxX, y: bb.maxY), CGPoint(x: bb.minX, y: bb.maxY)].map(m)
            var box = Path(); box.addLines(corners + [corners[0]])
            ctx.stroke(box, with: .color(.white), lineWidth: 2)

            // A. Manual — filled dots.
            for p in lm.leftEyeContour  { dot(m(p), 2.5, .green) }
            for p in lm.rightEyeContour { dot(m(p), 2.5, .blue) }
            for p in lm.leftPupilPoints  { dot(m(p), 3, .yellow) }
            for p in lm.rightPupilPoints { dot(m(p), 3, .pink) }
            if let lc = lm.leftPupilCentre, let rc = lm.rightPupilCentre {
                link(m(lc), m(rc), .cyan, 2); dot(m(lc), 6, .red); dot(m(rc), 6, .red)
            }

            // B. Apple pointsInImage — hollow rings / contrasting colours.
            for p in lm.appleLeftEyeContour  { ring(m(p), 3.5, .green) }
            for p in lm.appleRightEyeContour { ring(m(p), 3.5, .blue) }
            for p in lm.appleLeftPupilPoints  { dot(m(p), 3, .orange) }
            for p in lm.appleRightPupilPoints { dot(m(p), 3, .purple) }
            if let lc = lm.appleLeftPupilCentre, let rc = lm.appleRightPupilCentre {
                link(m(lc), m(rc), .white, 1.5); ring(m(lc), 7, .white); ring(m(rc), 7, .white)
            }
        }
        .allowsHitTesting(false)
    }

    /// Maps a top-left normalised point into view coordinates with the current
    /// flip mode and aspect-fill/fit, so a flip/orientation issue is obvious.
    private func mapNormalized(_ n: CGPoint, _ imageSize: CGSize, _ viewSize: CGSize) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        var x = n.x, y = n.y
        switch mappingMode {
        case .normal:  break
        case .flipX:   x = 1 - x
        case .flipY:   y = 1 - y
        case .flipXY:  x = 1 - x; y = 1 - y
        }
        let scale: CGFloat = previewMapping == .aspectFill
            ? max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
            : min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let dispW = imageSize.width * scale
        let dispH = imageSize.height * scale
        let offX = (viewSize.width - dispW) / 2
        let offY = (viewSize.height - dispH) / 2
        return CGPoint(x: offX + x * dispW, y: offY + y * dispH)
    }

    // MARK: - Debug readout overlay

    private func debugOverlay(_ r: FaceReadout) -> some View {
        let v = visionDebug
        let lm = v?.landmarks
        return VStack(alignment: .leading, spacing: 3) {
            Text("ARKit eye-transform PD:   \(mm(r.eyeTransformPDmm)) (raw)")
            Text("Corrected pupil-plane PD: \(mm(r.correctedPDmm)) (offset \(String(format: "%.0f", r.offsetAppliedMM))mm)")
            Text("Fixate a DISTANT target for distance PD")
                .foregroundStyle(.yellow)
            Text("Vision pupil-landmark PD: \(v?.pdMM.map(mm) ?? "n/a")")
            Text("MediaPipe iris PD:        \(mediaPipeDebug?.pdMM.map(mm) ?? "n/a") [\(mediaPipeDebug?.status ?? "off")]")
            Text("Pixel pupil distance:     \(v?.pixelDistance.map { String(format: "%.0fpx", $0) } ?? "n/a")")
            Text("Depth used:               \(v.map { String(format: "%.2fm", $0.depthMetres) } ?? "n/a")")
            Text("fx / fy:                  \(v.map { String(format: "%.0f / %.0f", $0.fx, $0.fy) } ?? "n/a")")
            Text("Head yaw/pitch/roll:      \(v.map { String(format: "%.0f / %.0f / %.0f", $0.yaw, $0.pitch, $0.roll) } ?? "n/a")  (debug)")
            Text("Tracking state:           \(v?.trackingState ?? "n/a")")
            Text("Frame variance:           \(v.map { String(format: "%.1fmm", $0.frameVarianceMM) } ?? "n/a")")
            Text("Vision image orientation: \(v?.orientationName ?? visionOrientation.rawValue)")
            Text("Detector mode:            \(v?.detectorMode ?? "n/a")")
            Text("Coordinate confidence:    \(v?.coordinateConfidence ?? "n/a")")
            Text("Face bounding box:        \(rect(lm?.boundingBox))")
            Text("L/R eye contour count:    \(lm.map { "\($0.leftEyeContour.count) / \($0.rightEyeContour.count)" } ?? "n/a")")
            Text("L/R pupil point count:    \(lm.map { "\($0.leftPupilPoints.count) / \($0.rightPupilPoints.count)" } ?? "n/a")")
            Text("Mapping mode:             \(mappingMode.rawValue)")
            Text("Preview mapping:          \(previewMapping.rawValue)")
            Text("— Face dims (M9, unvalidated vs caliper) —")
                .foregroundStyle(.cyan)
            Text("Width @ eye band (±\(String(format: "%.0f", FaceDimensions.eyeBandHalfHeightMM))mm): \(faceDims.map { mm($0.faceWidthAtEyeBandMM) } ?? "n/a")  [\(faceDims?.bandVertexCount ?? 0) verts]")
            Text("Max mesh width:           \(faceDims.map { mm($0.maxMeshWidthMM) } ?? "n/a")")
            Text("Bridge width Δx / 3D:     \(faceDims?.bridgeWidthXMM.map(mm) ?? "n/a") / \(faceDims?.bridgeWidth3DMM.map(mm) ?? "n/a")")
            Text("Bridge height vs pupils:  \(faceDims?.bridgeHeightMM.map { String(format: "%+.1fmm", $0) } ?? "assign saddle vertex")")
            Text("— Face shape (M10, ratios > absolutes) —")
                .foregroundStyle(.cyan)
            Text("Length (mesh top→chin):   \(faceShape.map { mm($0.faceLengthMM) } ?? "n/a")")
            Text("Forehead / cheek / jaw:   \(faceShape.map { "\(mm($0.foreheadWidthMM)) / \(mm($0.cheekWidthMM)) / \(mm($0.jawWidthMM))" } ?? "n/a")")
            Text("Cheek max-width at:       \(faceShape.map { String(format: "%.0f%% of face height", $0.cheekWidthHeightPct) } ?? "n/a")")
            Text("W:L / F:C / J:C ratios:   \(faceShape.map { "\(ratio($0.widthToLength)) / \(ratio($0.foreheadToCheek)) / \(ratio($0.jawToCheek))" } ?? "n/a")")
            Text("Shape guess (heuristic):  \(faceShape?.shapeGuess ?? "n/a")  [\(faceShape?.foreheadBandCount ?? 0)/\(faceShape?.jawBandCount ?? 0) band verts]")
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.green)
        .padding(10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        // Read-only panel: never intercept taps meant for controls beneath it.
        .allowsHitTesting(false)
    }

    private func ratio(_ value: Float?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "n/a"
    }

    private func mm(_ value: Float) -> String {
        String(format: "%.1fmm", value)
    }

    private func rect(_ r: CGRect?) -> String {
        guard let r else { return "n/a" }
        return String(format: "%.2f, %.2f, %.2f, %.2f", r.origin.x, r.origin.y, r.size.width, r.size.height)
    }

    // MARK: - Sample callback (runs on the main thread)

    /// Receives a copied, Sendable per-frame sample on the main thread and does
    /// all measurement here, decoupled from the mesh renderer and the render
    /// thread. No raw ARFaceAnchor is involved.
    private func handleSample(_ sample: FaceAnchorSample) {
        // --- Eyelid auto-detection (debug) ---
        if detecting {
            if detector.phase == .idle { detector.start(vertexCount: sample.vertices.count) }
            let blink = max(sample.blinkLeft, sample.blinkRight)
            if let result = detector.ingest(vertices: sample.vertices,
                                            leftEyeX: sample.leftEye.x,
                                            rightEyeX: sample.rightEye.x,
                                            blink: blink) {
                detectedLeft = result.left
                detectedRight = result.right
                detecting = false
                print("[Sarili] Detected left eyelid indices: \(format(result.left))")
                print("[Sarili] Detected right eyelid indices: \(format(result.right))")
            }
        }

        // --- Eyelid-centroid PD (world space) ---
        // ARFaceGeometry.vertices are in face-local space; transform to world
        // before measuring. Each eye centre is the centroid of its eyelid rim
        // loop; PD is the distance between the two centres, plus an empirical
        // calibration offset (0 until validated against clinical PD). Prefer
        // auto-detected indices; fall back to the static EyeLandmarks set.
        let leftIndices = detectedLeft.isEmpty ? EyeLandmarks.leftEyeRim : detectedLeft
        let rightIndices = detectedRight.isEmpty ? EyeLandmarks.rightEyeRim : detectedRight
        var eyelidPDmm: Float?
        if let leftCentre = worldEyeCentre(leftIndices, sample.vertices, sample.faceTransform),
           let rightCentre = worldEyeCentre(rightIndices, sample.vertices, sample.faceTransform) {
            let pdMetres = simd_distance(leftCentre, rightCentre)
            eyelidPDmm = pdMetres * 1000 + EyeLandmarks.pdCalibrationOffsetMM
        }

        // --- Gaze-axis pupil-plane correction (milestone 7) ---
        // Projects each eye origin forward along its gaze axis onto the pupil
        // plane before measuring; removes the rotation-centre overread and the
        // convergence error together. See PDCorrection.swift for the rationale.
        let correction = PDCorrection.correctedPD(
            leftEyeTransform: sample.leftEyeTransform,
            rightEyeTransform: sample.rightEyeTransform)

        readout = FaceReadout(eyeTransformPDmm: correction.rawPDmm,
                              correctedPDmm: correction.correctedPDmm,
                              offsetAppliedMM: correction.offsetAppliedMM,
                              eyelidPDmm: eyelidPDmm)

        // --- Face dimensions (milestone 9 harness) ---
        faceDims = FaceDimensions.measure(sample: sample,
                                          bridgeL: bridgeLIndex,
                                          bridgeR: bridgeRIndex,
                                          saddle: saddleIndex)

        // --- Face-shape ratios (milestone 10 harness) ---
        // Only while the readout that displays it is visible (vertex mode
        // shows the assignment UI instead) — the scan is ~26 full vertex
        // passes per frame, pointless when nothing shows the result.
        faceShape = showVertexDots ? nil : FaceShapeRatios.measure(sample: sample)

        // --- Bridge-slot suggestions (assignment guide) ---
        // Only needed while the assignment UI is up; the last value computed
        // before a freeze is what the frozen frame shows.
        bridgeSuggestion = showVertexDots ? FaceDimensions.suggestBridgePoints(sample: sample) : nil

        // --- Countdown capture (milestone 7 calibration) ---
        if measurePhase == .collecting {
            measureBuffer.append((raw: correction.rawPDmm, corrected: correction.correctedPDmm))
            if measureBuffer.count >= 45 { finishMeasurement() }
        }
    }

    /// Average of the given eyelid-rim vertices, transformed from face-local to
    /// world space. Returns nil if no valid indices are configured yet.
    private func worldEyeCentre(_ indices: [Int],
                                _ vertices: [SIMD3<Float>],
                                _ faceTransform: simd_float4x4) -> SIMD3<Float>? {
        var sum = SIMD3<Float>(repeating: 0)
        var count: Float = 0
        for index in indices where index >= 0 && index < vertices.count {
            let localPosition = vertices[index]
            let localVector = SIMD4<Float>(localPosition.x, localPosition.y, localPosition.z, 1.0)
            let worldVector = faceTransform * localVector
            sum += SIMD3<Float>(worldVector.x, worldVector.y, worldVector.z)
            count += 1
        }
        guard count > 0 else { return nil }
        return sum / count
    }

    // MARK: - Denied state

    private var deniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Camera access is required to scan your face.")
                .multilineTextAlignment(.center)
            Text("Enable camera access for Sarili in Settings, then return to the app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Unsupported state

    private var unsupportedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "faceid")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Face tracking isn’t supported on this device.")
                .multilineTextAlignment(.center)
            Text("Sarili needs an iPhone with a TrueDepth (Face ID) front camera to scan your face.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Permission + capability

    @MainActor
    private func startSession() async {
        // First confirm the device can actually do face tracking; surface this
        // explicitly rather than letting it look like "no face detected".
        guard ARFaceTrackingConfiguration.isSupported else {
            scanState = .unsupported
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            scanState = .ready
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            scanState = granted ? .ready : .cameraDenied
        case .denied, .restricted:
            scanState = .cameraDenied
        @unknown default:
            scanState = .cameraDenied
        }
    }
}

#Preview {
    ContentView()
}
