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

    /// Fired on the MAIN thread with the Vision PD diagnostics for one frame.
    var onVisionDebug: ((VisionDebugInfo) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(faceDetected: $faceDetected,
                    showVertexDots: showVertexDots,
                    onSampleReady: onSampleReady,
                    onVertexPicked: onVertexPicked,
                    onVisionDebug: onVisionDebug)
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
        private let onSampleReady: ((FaceAnchorSample) -> Void)?
        private let onVertexPicked: ((Int) -> Void)?
        private let onVisionDebug: ((VisionDebugInfo) -> Void)?

        // Vision PD pipeline (debug). The detector is swappable behind a protocol.
        // visionBusy / visionHistory are touched only on main (ARSession delegate
        // callbacks arrive on the main queue here).
        private let visionPipeline = VisionPDPipeline(detector: VisionPupilDetector())
        private var visionBusy = false
        private var visionHistory: [Float] = []   // recent PDs, for frame variance

        private weak var allDotsNode: SCNNode?
        private weak var eyelidDotsNode: SCNNode?
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
             onVisionDebug: ((VisionDebugInfo) -> Void)?) {
            _faceDetected = faceDetected
            self.showVertexDots = showVertexDots
            self.onSampleReady = onSampleReady
            self.onVertexPicked = onVertexPicked
            self.onVisionDebug = onVisionDebug
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

        /// Projects every cached vertex to screen space and reports the index of
        /// the one nearest the tap, so eyelid rim indices can be read on device.
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let sceneView, !latestVertices.isEmpty else { return }
            let location = gesture.location(in: sceneView)

            var bestIndex: Int?
            var bestDistance = CGFloat.greatestFiniteMagnitude
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

            if let bestIndex {
                pickedVertexIndex = bestIndex
                onVertexPicked?(bestIndex)
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
            let depth = (abs(leftEyeCam.z) + abs(rightEyeCam.z)) / 2

            let fx = frame.camera.intrinsics.columns.0.x

            // Diagnostics available regardless of Vision success.
            let faceInCamera = cameraInverse * faceAnchor.transform
            let euler = Coordinator.eulerDegrees(faceInCamera)
            let tracking = Coordinator.describe(frame.camera.trackingState)
            let pixelBuffer = frame.capturedImage

            visionBusy = true
            visionPipeline.process(pixelBuffer: pixelBuffer, fx: fx, depthMetres: depth) { [weak self] result in
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

                    onVisionDebug(VisionDebugInfo(
                        pdMM: result?.pdMM,
                        pixelDistance: result?.pixelDistance,
                        depthMetres: depth,
                        fx: fx,
                        usedFallback: result?.usedFallback ?? false,
                        yaw: euler.yaw, pitch: euler.pitch, roll: euler.roll,
                        trackingState: tracking,
                        frameVarianceMM: variance
                    ))
                }
            }
        }

        /// Approximate yaw/pitch/roll (degrees) from a camera-relative transform.
        /// Convention may need sign/axis tweaks on device; debug only.
        static func eulerDegrees(_ t: simd_float4x4) -> (yaw: Float, pitch: Float, roll: Float) {
            let r2x = t.columns.2.x, r2y = t.columns.2.y, r2z = t.columns.2.z
            let pitch = atan2(-r2y, sqrt(r2x * r2x + r2z * r2z))
            let yaw = atan2(r2x, r2z)
            let roll = atan2(t.columns.0.y, t.columns.1.y)
            let k = Float(180.0 / Float.pi)
            return (yaw * k, pitch * k, roll * k)
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
