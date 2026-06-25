//
//  ARFaceTrackingView.swift
//  SariliScan
//
//  Bridges an ARKit/SceneKit ARSCNView running an ARFaceTrackingConfiguration
//  into SwiftUI, renders a subtle wireframe mesh over the tracked face, and
//  (in debug mode) renders the mesh vertices as dots to identify iris indices.
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

    /// DEBUG-ONLY: render every face-mesh vertex as a dot, with the iris ring
    /// clusters highlighted, to confirm iris vertex indices on device.
    /// This is shared mutable state read on the render thread and written on the
    /// main thread — fine for a debug toggle, but remove before production
    /// measurement code rather than relying on it for anything load-bearing.
    var showVertexDots: Bool = false

    /// Fired on the MAIN thread with a copied, Sendable per-frame sample.
    /// Consumers do all measurement here, decoupled from mesh rendering and
    /// never touching the (non-Sendable) ARFaceAnchor.
    var onSampleReady: ((FaceAnchorSample) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(faceDetected: $faceDetected,
                    showVertexDots: showVertexDots,
                    onSampleReady: onSampleReady)
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

        let configuration = ARFaceTrackingConfiguration()
        configuration.maximumNumberOfTrackedFaces = 1
        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        return sceneView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // Propagate the debug toggle into the live coordinator.
        context.coordinator.showVertexDots = showVertexDots
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
        // DEBUG-ONLY shared mutable flag (render thread reads, main thread writes).
        var showVertexDots: Bool
        private let onSampleReady: ((FaceAnchorSample) -> Void)?

        private weak var allDotsNode: SCNNode?
        private weak var irisDotsNode: SCNNode?

        init(faceDetected: Binding<Bool>,
             showVertexDots: Bool,
             onSampleReady: ((FaceAnchorSample) -> Void)?) {
            _faceDetected = faceDetected
            self.showVertexDots = showVertexDots
            self.onSampleReady = onSampleReady
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

            let irisDots = SCNNode()
            node.addChildNode(irisDots)
            irisDotsNode = irisDots

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
            let sample = FaceAnchorSample(
                leftEye: SIMD3<Float>(l.x, l.y, l.z),
                rightEye: SIMD3<Float>(r.x, r.y, r.z),
                faceOrigin: SIMD3<Float>(o.x, o.y, o.z),
                vertices: Array(faceAnchor.geometry.vertices),
                faceTransform: faceAnchor.transform
            )

            DispatchQueue.main.async {
                self.onSampleReady?(sample)
            }
        }

        // MARK: - Vertex identifier (debug)

        private func updateVertexDots(_ faceAnchor: ARFaceAnchor) {
            guard showVertexDots else {
                allDotsNode?.isHidden = true
                irisDotsNode?.isHidden = true
                return
            }

            let vertices = faceAnchor.geometry.vertices

            // All vertices: small translucent white dots.
            let allPoints = vertices.map { SCNVector3($0.x, $0.y, $0.z) }
            allDotsNode?.geometry = Coordinator.pointCloud(
                allPoints, color: UIColor.white.withAlphaComponent(0.5), size: 5)
            allDotsNode?.isHidden = false

            // Iris ring vertices: larger red dots (empty until indices confirmed).
            let irisPoints = IrisLandmarks.allIrisRing
                .filter { $0 >= 0 && $0 < vertices.count }
                .map { SCNVector3(vertices[$0].x, vertices[$0].y, vertices[$0].z) }
            irisDotsNode?.geometry = irisPoints.isEmpty
                ? nil
                : Coordinator.pointCloud(irisPoints, color: .systemRed, size: 14)
            irisDotsNode?.isHidden = false
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
