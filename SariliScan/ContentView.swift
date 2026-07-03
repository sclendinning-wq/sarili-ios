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

    @State private var faceDetected = false
    @State private var scanState: ScanState = .requestingPermission
    @State private var readout: FaceReadout?
    @State private var showVertexDots = false
    @State private var tappedVertex: Int?

    // DEBUG-ONLY: automatic eyelid index detection state.
    @State private var detector = EyelidIndexDetector()
    @State private var detecting = false
    @State private var detectedLeft: [Int] = []
    @State private var detectedRight: [Int] = []
    @State private var visionDebug: VisionDebugInfo?   // latest Vision diagnostics (async)
    @State private var visionOrientation: VisionImageOrientation = .initial
    @State private var mappingMode: MappingMode = .normal
    @State private var previewMapping: PreviewMapping = .aspectFill

    // Milestone 7: countdown capture — median PD over ~45 frames while the user
    // fixates a DISTANT target (not the screen). This is the calibration
    // experiment: median raw vs clinical ground truth fits the bias constant.
    @State private var measurePhase: MeasurePhase = .idle
    @State private var measureBuffer: [(raw: Float, corrected: Float)] = []
    @State private var measureResult: MeasureResult?

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
                                   onSampleReady: handleSample,
                                   onVertexPicked: { tappedVertex = $0 },
                                   highlightedVertices: detectedLeft + detectedRight,
                                   onVisionDebug: { visionDebug = $0 },
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

            if scanState == .ready {
                measureUI
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            // Entry to the separate card-reference PD flow (works without TrueDepth).
            Button { onOpenCardPD() } label: {
                Label("Card PD", systemImage: "creditcard")
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
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
            Button { startMeasurement() } label: {
                Label("Measure PD (look far)", systemImage: "scope")
                    .font(.system(.subheadline, design: .monospaced))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .tint(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 84)
        case .countdown(let n):
            VStack(spacing: 8) {
                Text("Look at a DISTANT target").font(.headline)
                Text("\(n)").font(.system(size: 64, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(.white)
            .padding(24)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
        case .collecting:
            Text("Measuring… keep looking far")
                .font(.headline)
                .foregroundStyle(.yellow)
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
        Button {
            showVertexDots.toggle()
        } label: {
            Label(showVertexDots ? "Vertices: ON" : "Vertices: OFF",
                  systemImage: "circle.grid.3x3.fill")
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .tint(showVertexDots ? .green : .white)
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
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.green)
        .padding(10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
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
