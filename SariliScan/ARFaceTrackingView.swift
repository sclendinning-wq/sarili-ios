//
//  ARFaceTrackingView.swift
//  SariliScan
//
//  Bridges an ARKit/SceneKit ARSCNView running an ARFaceTrackingConfiguration
//  into SwiftUI, renders a subtle wireframe mesh over the tracked face, and
//  (in debug mode) renders the mesh vertices as dots to identify eyelid indices.
//

import SwiftUI
import ARKit
import SceneKit

/// A SwiftUI wrapper around an `ARSCNView` that runs a face-tracking `ARSession`
/// and draws a semi-transparent wireframe over the detected face. Reports whether
/// a face is currently being tracked back to SwiftUI via the `faceDetected` binding.
struct ARFaceTrackingView: UIViewRepresentable {

    /// Driven from the AR session delegate; true while a face is tracked.
    @Binding var faceDetected: Bool

    /// DEBUG-ONLY: render every face-mesh vertex as a dot, with the eyelid rim
    /// loops highlighted, to confirm eyelid vertex indices on device.
    /// This is shared mutable state read on the render thread and written on the
    /// main thread — fine for a debug toggle, but remove before production
    /// measurement code rather than relying on it for anything load-bearing.
    var showVertexDots: Bool = false
    
    /// DEBUG-ONLY: freeze the AR session so a vertex can be tapped on a still
    /// frame (milestone 9 slot assignment). Pausing keeps the last camera
    /// frame and mesh on screen; taps project against the cached vertices, so
    /// identify-and-assign keeps working while frozen.
    var frozen: Bool = false

    /// Fired on the MAIN thread with a copied, Sendable per-frame sample.
    /// Consumers do all measurement here, decoupled from mesh rendering and
    /// never touching the (non-Sendable) ARFaceAnchor.
    var onSampleReady: ((FaceAnchorSample) -> Void)? = nil

    /// DEBUG-ONLY: fired on the main thread with the mesh vertex index nearest a
    /// tap, so eyelid rim indices can be identified directly on device.
    var onVertexPicked: ((Int) -> Void)? = nil

    /// DEBUG-ONLY: vertex indices to highlight (e.g. auto-detected eyelid rims).
    /// Falls back to EyeLandmarks.allEyeRim when empty.
    var highlightedVertices: [Int] = []

    /// DEBUG-ONLY: geometrically SUGGESTED vertices (orange guide dots) for
    /// the face-dims assignment flow — where the algorithm thinks the bridge
    /// points are, before the user confirms or adjusts.
    var suggestedVertices: [Int] = []

    /// Fired on the MAIN thread with the Vision PD diagnostics for one frame.
    var onVisionDebug: ((VisionDebugInfo) -> Void)? = nil

    /// Fired on the MAIN thread with the MediaPipe iris PD for one frame.
    var onMediaPipeDebug: ((MediaPipeDebugInfo) -> Void)? = nil

    /// Which orientation to feed Vision. Switchable live on device.
    var visionOrientation: VisionImageOrientation = .initial

    func makeCoordinator() -> Coordinator {
        Coordinator(faceDetected: $faceDetected,
                    showVertexDots: showVertexDots,
                    onSampleReady: onSampleReady,
                    onVertexPicked: onVertexPicked,
                    onVisionDebug: onVisionDebug,
                    onMediaPipeDebug: onMediaPipeDebug)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let sceneView = ARSCNView(frame: .zero)
        sceneView.automaticallyUpdatesLighting = true

        // Face tracking requires a device with a TrueDepth front camera. On
        // unsupported devices the parent view shows an explicit message, but we
        // still guard here so we never run an unsupported configuration.
        guard ARFaceTrackingConfiguration.isSupported else {
            return sceneView
        }

        sceneView.delegate = context.coordinator
        sceneView.session.delegate = context.coordinator

        // DEBUG-ONLY: tap-to-identify the nearest mesh vertex.
        context.coordinator.sceneView = sceneView
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        sceneView.addGestureRecognizer(tap)

        let configuration = ARFaceTrackingConfiguration()
        configuration.maximumNumberOfTrackedFaces = 1
        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        return sceneView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // Propagate debug state into the live coordinator.
        context.coordinator.showVertexDots = showVertexDots
        context.coordinator.highlightedVertices = highlightedVertices
        context.coordinator.suggestedVertices = suggestedVertices
        context.coordinator.visionOrientation = visionOrientation
        // Freeze-frame (milestone 9): pause keeps the last frame + mesh on
        // screen for stable tapping; resume re-runs the same configuration
        // WITHOUT reset options, so existing anchors survive and tracking
        // picks straight back up.
        if context.coordinator.isFrozen != frozen {
            context.coordinator.isFrozen = frozen
            if frozen {
                // Order matters: project all vertices to screen space while
                // the camera is still live, THEN pause. Tapping while frozen
                // is served from this snapshot (projectPoint goes stale once
                // the session pauses — observed on device).
                context.coordinator.captureFrozenProjections()
                uiView.session.pause()
                // Keep the SceneKit render loop alive while the AR session is
                // paused, so the tap marker (updated directly from handleTap)
                // still draws on the frozen frame.
                uiView.rendersContinuously = true
            } else if ARFaceTrackingConfiguration.isSupported {
                context.coordinator.clearFrozenProjections()
                uiView.rendersContinuously = false
                let configuration = ARFaceTrackingConfiguration()
                configuration.maximumNumberOfTrackedFaces = 1
                uiView.session.run(configuration)
            }
        }
    }
    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    /// Owns the face mesh geometry and pushes tracked-face state into SwiftUI.
    ///
    /// Acts as both the SceneKit render delegate (to build/update the wireframe
    /// mesh and debug dots) and the AR session delegate (to report detection).
    /// All updates to `faceDetected` are dispatched to the main thread, since
    /// SwiftUI state must only be mutated on the main thread.
    final class Coordinator: NSObject, ARSCNViewDelegate, ARSessionDelegate {
        @Binding private var faceDetected: Bool
        // DEBUG-ONLY shared mutable flags (render thread reads, main thread writes).
        var showVertexDots: Bool
        var highlightedVertices: [Int] = []
        var suggestedVertices: [Int] = []
        var isFrozen = false   // mirrors the freeze toggle; main thread only
        private let onSampleReady: ((FaceAnchorSample) -> Void)?
        private let onVertexPicked: ((Int) -> Void)?
        private let onVisionDebug: ((VisionDebugInfo) -> Void)?
        private let onMediaPipeDebug: ((MediaPipeDebugInfo) -> Void)?

        // Vision PD pipeline (debug). The detector is swappable behind a protocol.
        // visionBusy / visionHistory are touched only on main (ARSession delegate
        // callbacks arrive on the main queue here).
        private let visionPipeline = VisionPDPipeline(detector: VisionPupilDetector())
        private var visionBusy = false
        private var visionHistory: [Float] = []   // recent PDs, for frame variance
        var visionOrientation: VisionImageOrientation = .initial

        // MediaPipe iris PD (milestone 8). Same one-in-flight throttle pattern.
        private let mediaPipeEstimator = MediaPipePDEstimator()
        private var mediaPipeBusy = false

        private weak var allDotsNode: SCNNode?
        private weak var eyelidDotsNode: SCNNode?
        private weak var suggestionDotsNode: SCNNode?
        private weak var markerDotNode: SCNNode?

        // DEBUG-ONLY tap-to-identify state. Only touched on the main thread
        // (latest sample is stored from the main-thread dispatch; taps are main).
        weak var sceneView: ARSCNView?
        private var latestVertices: [SIMD3<Float>] = []
        private var latestFaceTransform = matrix_identity_float4x4
        private var pickedVertexIndex: Int?

        init(faceDetected: Binding<Bool>,
             showVertexDots: Bool,
             onSampleReady: ((FaceAnchorSample) -> Void)?,
             onVertexPicked: ((Int) -> Void)?,
             onVisionDebug: ((VisionDebugInfo) -> Void)?,
             onMediaPipeDebug: ((MediaPipeDebugInfo) -> Void)?) {
            _faceDetected = faceDetected
            self.showVertexDots = showVertexDots
            self.onSampleReady = onSampleReady
            self.onVertexPicked = onVertexPicked
            self.onVisionDebug = onVisionDebug
            self.onMediaPipeDebug = onMediaPipeDebug
        }

        // MARK: - Mesh rendering (ARSCNViewDelegate)

        /// Builds the wireframe mesh node when a face anchor appears. SceneKit
        /// automatically removes this node when the anchor is removed, so the mesh
        /// shows on detection and disappears when the face is lost.
        func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            guard anchor is ARFaceAnchor,
                  let device = renderer.device,
                  let faceGeometry = ARSCNFaceGeometry(device: device) else {
                return nil
            }

            // Subtle, semi-transparent wireframe: thin lines, no shading.
            let material = faceGeometry.firstMaterial
            material?.fillMode = .lines
            material?.lightingModel = .constant
            material?.diffuse.contents = UIColor.white
            material?.transparency = 0.35
            material?.isDoubleSided = true
            material?.readsFromDepthBuffer = false

            let node = SCNNode(geometry: faceGeometry)

            // Debug dot layers (vertices live in face-local space, so attaching
            // them as children of the face node keeps them aligned with the mesh).
            let allDots = SCNNode()
            node.addChildNode(allDots)
            allDotsNode = allDots

            let eyelidDots = SCNNode()
            node.addChildNode(eyelidDots)
            eyelidDotsNode = eyelidDots

            let suggestionDots = SCNNode()
            node.addChildNode(suggestionDots)
            suggestionDotsNode = suggestionDots

            let markerDots = SCNNode()
            node.addChildNode(markerDots)
            markerDotNode = markerDots

            return node
        }

        /// Conforms the mesh to the face on every frame, refreshes debug dots,
        /// then copies a Sendable sample and hands it to the main thread. The
        /// readout/measurement logic lives in the consumer, kept out of this
        /// mesh-rendering path and off the render thread.
        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let faceAnchor = anchor as? ARFaceAnchor else { return }

            if let faceGeometry = node.geometry as? ARSCNFaceGeometry {
                faceGeometry.update(from: faceAnchor.geometry)
            }

            updateVertexDots(faceAnchor)

            // Copy ARKit data into a Sendable value here on the render thread,
            // then dispatch to main. The non-Sendable ARFaceAnchor never escapes.
            let l = faceAnchor.leftEyeTransform.columns.3
            let r = faceAnchor.rightEyeTransform.columns.3
            let o = faceAnchor.transform.columns.3
            let blinkL = faceAnchor.blendShapes[.eyeBlinkLeft]?.floatValue ?? 0
            let blinkR = faceAnchor.blendShapes[.eyeBlinkRight]?.floatValue ?? 0
            let sample = FaceAnchorSample(
                leftEye: SIMD3<Float>(l.x, l.y, l.z),
                rightEye: SIMD3<Float>(r.x, r.y, r.z),
                leftEyeTransform: faceAnchor.leftEyeTransform,
                rightEyeTransform: faceAnchor.rightEyeTransform,
                faceOrigin: SIMD3<Float>(o.x, o.y, o.z),
                vertices: Array(faceAnchor.geometry.vertices),
                faceTransform: faceAnchor.transform,
                blinkLeft: blinkL,
                blinkRight: blinkR
            )

            DispatchQueue.main.async {
                // Cache latest geometry for the (main-thread) tap handler.
                self.latestVertices = sample.vertices
                self.latestFaceTransform = sample.faceTransform
                self.onSampleReady?(sample)
            }
        }

        // MARK: - Vertex identifier (debug)

        private func updateVertexDots(_ faceAnchor: ARFaceAnchor) {
            guard showVertexDots else {
                allDotsNode?.isHidden = true
                eyelidDotsNode?.isHidden = true
                suggestionDotsNode?.isHidden = true
                markerDotNode?.isHidden = true
                return
            }

            let vertices = faceAnchor.geometry.vertices

            // All vertices: small translucent white dots for context.
            let allPoints = vertices.map { SCNVector3($0.x, $0.y, $0.z) }
            allDotsNode?.geometry = Coordinator.pointCloud(
                allPoints, color: UIColor.white.withAlphaComponent(0.45), size: 4)
            allDotsNode?.isHidden = false

            // Eyelid rim vertices: large, distinct cyan dots so the loops stand
            // out clearly against the white cloud. Prefer live-highlighted
            // (auto-detected) indices; fall back to the static EyeLandmarks set.
            let highlightSource = highlightedVertices.isEmpty ? EyeLandmarks.allEyeRim : highlightedVertices
            let eyelidPoints = highlightSource
                .filter { $0 >= 0 && $0 < vertices.count }
                .map { SCNVector3(vertices[$0].x, vertices[$0].y, vertices[$0].z) }
            eyelidDotsNode?.geometry = eyelidPoints.isEmpty
                ? nil
                : Coordinator.pointCloud(eyelidPoints, color: .systemTeal, size: 22)
            eyelidDotsNode?.isHidden = false

            // Suggested vertices (face-dims guide): orange, sized between the
            // teal highlights and the yellow tap marker so all three layers
            // stay tellable apart at a glance.
            let suggestionPoints = suggestedVertices
                .filter { $0 >= 0 && $0 < vertices.count }
                .map { SCNVector3(vertices[$0].x, vertices[$0].y, vertices[$0].z) }
            suggestionDotsNode?.geometry = suggestionPoints.isEmpty
                ? nil
                : Coordinator.pointCloud(suggestionPoints, color: .systemOrange, size: 28)
            suggestionDotsNode?.isHidden = false

            // Tapped vertex: a single large yellow marker for identification.
            if let idx = pickedVertexIndex, idx >= 0, idx < vertices.count {
                let p = vertices[idx]
                markerDotNode?.geometry = Coordinator.pointCloud(
                    [SCNVector3(p.x, p.y, p.z)], color: .systemYellow, size: 34)
            } else {
                markerDotNode?.geometry = nil
            }
            markerDotNode?.isHidden = false
        }

        // MARK: - Tap to identify (debug)

        /// Screen positions of every vertex, captured at the moment of freezing
        /// (milestone 9). projectPoint returns stale results once the session
        /// is paused (observed on device), so frozen taps are served from this
        /// snapshot instead. x = .infinity marks vertices that were off-screen.
        private var frozenProjections: [CGPoint] = []

        func captureFrozenProjections() {
            frozenProjections = []
            guard let sceneView, !latestVertices.isEmpty else { return }
            frozenProjections = latestVertices.map { vertex in
                let world = latestFaceTransform * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
                let projected = sceneView.projectPoint(SCNVector3(world.x, world.y, world.z))
                guard projected.z >= 0, projected.z <= 1 else {
                    return CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
                }
                return CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
            }
        }

        func clearFrozenProjections() {
            frozenProjections = []
        }

        /// Projects every cached vertex to screen space and reports the index of
        /// the one nearest the tap, so eyelid rim indices can be read on device.
        /// While frozen, matches against the freeze-time projection snapshot.
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let sceneView, !latestVertices.isEmpty else { return }
            let location = gesture.location(in: sceneView)

            var bestIndex: Int?
            var bestDistance = CGFloat.greatestFiniteMagnitude

            if isFrozen, !frozenProjections.isEmpty {
                for (index, point) in frozenProjections.enumerated() where point.x.isFinite {
                    let dx = point.x - location.x
                    let dy = point.y - location.y
                    let distance = dx * dx + dy * dy
                    if distance < bestDistance {
                        bestDistance = distance
                        bestIndex = index
                    }
                }
            } else {
                for (index, vertex) in latestVertices.enumerated() {
                    let world = latestFaceTransform * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
                    let projected = sceneView.projectPoint(SCNVector3(world.x, world.y, world.z))
                    // Skip vertices behind the camera / outside the clip range.
                    guard projected.z >= 0, projected.z <= 1 else { continue }
                    let dx = CGFloat(projected.x) - location.x
                    let dy = CGFloat(projected.y) - location.y
                    let distance = dx * dx + dy * dy
                    if distance < bestDistance {
                        bestDistance = distance
                        bestIndex = index
                    }
                }
            }

            if let bestIndex {
                pickedVertexIndex = bestIndex
                onVertexPicked?(bestIndex)

                // While frozen, renderer(_:didUpdate:) never fires, so the
                // yellow marker would otherwise not redraw until unfreezing.
                // Update its geometry directly here (main thread; the render
                // loop is kept alive via rendersContinuously while frozen).
                if isFrozen, bestIndex < latestVertices.count {
                    let p = latestVertices[bestIndex]
                    markerDotNode?.geometry = Coordinator.pointCloud(
                        [SCNVector3(p.x, p.y, p.z)], color: .systemYellow, size: 34)
                    markerDotNode?.isHidden = false
                }
            }
        }
        /// Builds an SCNGeometry that renders the given points as dots.
        static func pointCloud(_ points: [SCNVector3], color: UIColor, size: CGFloat) -> SCNGeometry {
            let source = SCNGeometrySource(vertices: points)
            let indices = (0..<points.count).map { UInt32($0) }
            let element = SCNGeometryElement(indices: indices, primitiveType: .point)
            element.pointSize = size
            element.minimumPointScreenSpaceRadius = size
            element.maximumPointScreenSpaceRadius = size

            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.lightingModel = .constant
            material.isDoubleSided = true
            material.readsFromDepthBuffer = false
            geometry.firstMaterial = material
            return geometry
        }

        // MARK: - Vision pupil PD (ARSessionDelegate frame)

        /// Throttled (one in-flight at a time). Runs the four-stage Vision PD
        /// pipeline and assembles the diagnostic readout for one frame.
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard let onVisionDebug, !visionBusy,
                  let faceAnchor = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first else {
                return
            }

            let cameraInverse = simd_inverse(frame.camera.transform)

            // Stage 2 — depth source: the ARKit eye-transform plane (mean of the
            // two eyes in camera space), the best available estimate of pupil depth.
            let leftEyeWorld = faceAnchor.transform * faceAnchor.leftEyeTransform
            let rightEyeWorld = faceAnchor.transform * faceAnchor.rightEyeTransform
            let leftEyeCam = cameraInverse * leftEyeWorld.columns.3
            let rightEyeCam = cameraInverse * rightEyeWorld.columns.3
            // Depth at the PUPIL plane, not the eyeball rotation centre. The
            // eye transforms sit ~11mm behind the pupils (see PDCorrection);
            // image-based methods (Vision, MediaPipe) measure the pupils, so
            // using rotation-centre depth inflates px→mm by ~3% at arm's
            // length (~+2mm on a 63mm PD). Project forward along the gaze
            // axis with the same empirical offset PDCorrection uses.
            func pupilLocal(_ t: simd_float4x4) -> SIMD4<Float> {
                let origin = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
                var gaze = simd_normalize(SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z))
                if gaze.z < 0 { gaze = -gaze }   // face-local +Z points out of the face
                let p = origin + gaze * (PDCorrection.rotationCentreToPupilMM / 1000)
                return SIMD4<Float>(p.x, p.y, p.z, 1)
            }
            let leftPupilCam = cameraInverse * (faceAnchor.transform * pupilLocal(faceAnchor.leftEyeTransform))
            let rightPupilCam = cameraInverse * (faceAnchor.transform * pupilLocal(faceAnchor.rightEyeTransform))
            let depth = (abs(leftPupilCam.z) + abs(rightPupilCam.z)) / 2

            let fx = frame.camera.intrinsics.columns.0.x
            let fy = frame.camera.intrinsics.columns.1.y

            // Diagnostics available regardless of Vision success.
            // Roll from the inter-eye line (reliable: ~0° for an upright face).
            // Yaw/pitch from the face forward axis in camera space (approx).
            let faceInCamera = cameraInverse * faceAnchor.transform
            let k = Float(180.0 / Float.pi)
            let roll = atan2(rightEyeCam.y - leftEyeCam.y, rightEyeCam.x - leftEyeCam.x) * k
            let fwd = faceInCamera.columns.2
            let yaw = atan2(fwd.x, fwd.z) * k
            let pitch = atan2(-fwd.y, sqrt(fwd.x * fwd.x + fwd.z * fwd.z)) * k
            let tracking = Coordinator.describe(frame.camera.trackingState)
            let pixelBuffer = frame.capturedImage
            let orientation = visionOrientation

            // MediaPipe iris PD (milestone 8) — same buffer/depth/focal length,
            // independent throttle so a slow model can't stall the Vision path.
            if let onMediaPipeDebug, !mediaPipeBusy {
                mediaPipeBusy = true
                mediaPipeEstimator.estimatePD(pixelBuffer: pixelBuffer,
                                              focalLengthPx: fx,
                                              depthMetres: depth) { [weak self] info in
                    DispatchQueue.main.async {
                        self?.mediaPipeBusy = false
                        onMediaPipeDebug(info)
                    }
                }
            }

            visionBusy = true
            visionPipeline.process(pixelBuffer: pixelBuffer,
                                   fx: fx,
                                   depthMetres: depth,
                                   orientation: orientation.cg) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.visionBusy = false

                    // Frame variance = std-dev of recent Vision PDs (not averaging
                    // the output — a stability metric only).
                    var variance: Float = 0
                    if let pd = result?.pdMM {
                        self.visionHistory.append(pd)
                        if self.visionHistory.count > 10 { self.visionHistory.removeFirst() }
                        variance = Coordinator.stdDev(self.visionHistory)
                    }

                    let det = result?.detection
                    let mode: String
                    if det == nil { mode = "unavailable" }
                    else if det?.usedFallback == true { mode = "fallback eye region" }
                    else { mode = "pupil landmarks" }

                    // Confidence: a coarse single pupil point per eye can never be
                    // trusted on PD plausibility alone — require visual confirmation.
                    let coarsePupil = (det?.leftPupilPoints.count ?? 0) <= 1
                        || (det?.rightPupilPoints.count ?? 0) <= 1
                    let pdOK = (result?.pdMM).map { $0 >= 45 && $0 <= 80 } ?? false
                    let confidence: String
                    if mode != "pupil landmarks" { confidence = "needs checking" }
                    else if coarsePupil { confidence = "needs visual confirmation" }
                    else if pdOK && variance < 3 { confidence = "OK" }
                    else { confidence = "needs checking" }

                    let landmarks = det.map {
                        VisionLandmarks(boundingBox: $0.boundingBox,
                                        leftEyeContour: $0.leftEyeContour,
                                        rightEyeContour: $0.rightEyeContour,
                                        leftPupilPoints: $0.leftPupilPoints,
                                        rightPupilPoints: $0.rightPupilPoints,
                                        leftPupilCentre: $0.leftPupilCentre,
                                        rightPupilCentre: $0.rightPupilCentre,
                                        appleLeftEyeContour: $0.appleLeftEyeContour,
                                        appleRightEyeContour: $0.appleRightEyeContour,
                                        appleLeftPupilPoints: $0.appleLeftPupilPoints,
                                        appleRightPupilPoints: $0.appleRightPupilPoints,
                                        appleLeftPupilCentre: $0.appleLeftPupilCentre,
                                        appleRightPupilCentre: $0.appleRightPupilCentre)
                    }

                    onVisionDebug(VisionDebugInfo(
                        pdMM: result?.pdMM,
                        pixelDistance: result?.pixelDistance,
                        depthMetres: depth,
                        fx: fx,
                        fy: fy,
                        yaw: yaw, pitch: pitch, roll: roll,
                        trackingState: tracking,
                        frameVarianceMM: variance,
                        orientationName: orientation.rawValue,
                        detectorMode: mode,
                        coordinateConfidence: confidence,
                        imageSize: det?.imageSize,
                        landmarks: landmarks
                    ))
                }
            }
        }

        static func describe(_ state: ARCamera.TrackingState) -> String {
            switch state {
            case .normal: return "normal"
            case .notAvailable: return "not available"
            case .limited(let reason):
                switch reason {
                case .initializing: return "limited: initializing"
                case .excessiveMotion: return "limited: excessive motion"
                case .insufficientFeatures: return "limited: low features"
                case .relocalizing: return "limited: relocalizing"
                @unknown default: return "limited"
                }
            }
        }

        static func stdDev(_ values: [Float]) -> Float {
            guard values.count > 1 else { return 0 }
            let mean = values.reduce(0, +) / Float(values.count)
            let varSum = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            return sqrt(varSum / Float(values.count))
        }

        // MARK: - Detection state (ARSessionDelegate)

        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            if let face = anchors.compactMap({ $0 as? ARFaceAnchor }).first {
                DispatchQueue.main.async {
                    self.faceDetected = face.isTracked
                }
            }
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            if let face = anchors.compactMap({ $0 as? ARFaceAnchor }).first {
                DispatchQueue.main.async {
                    self.faceDetected = face.isTracked
                }
            }
        }

        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
            if anchors.contains(where: { $0 is ARFaceAnchor }) {
                DispatchQueue.main.async {
                    self.faceDetected = false
                }
            }
        }
    }
}
