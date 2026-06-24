//
//  ARFaceTrackingView.swift
//  SariliScan
//
//  Bridges an ARKit/SceneKit ARSCNView running an ARFaceTrackingConfiguration
//  into SwiftUI, and renders a subtle wireframe mesh over the tracked face.
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

    /// Fired from the SceneKit delegate's `didUpdate` with the live face anchor.
    /// Consumers read raw landmark data here, decoupled from mesh rendering.
    var onFaceAnchorUpdate: ((ARFaceAnchor) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(faceDetected: $faceDetected, onFaceAnchorUpdate: onFaceAnchorUpdate)
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
        // Nothing to update; mesh + state flow through the coordinator.
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    /// Owns the face mesh geometry and pushes tracked-face state into SwiftUI.
    ///
    /// Acts as both the SceneKit render delegate (to build/update the wireframe
    /// mesh) and the AR session delegate (to report detection). All updates to
    /// `faceDetected` are dispatched to the main thread, since SwiftUI state must
    /// only be mutated on the main thread.
    final class Coordinator: NSObject, ARSCNViewDelegate, ARSessionDelegate {
        @Binding private var faceDetected: Bool
        private let onFaceAnchorUpdate: ((ARFaceAnchor) -> Void)?

        init(faceDetected: Binding<Bool>, onFaceAnchorUpdate: ((ARFaceAnchor) -> Void)?) {
            _faceDetected = faceDetected
            self.onFaceAnchorUpdate = onFaceAnchorUpdate
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

            return SCNNode(geometry: faceGeometry)
        }

        /// Conforms the mesh to the face on every frame, then forwards the raw
        /// anchor to consumers. The readout/measurement logic lives in the
        /// callback, kept out of this mesh-rendering path.
        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let faceAnchor = anchor as? ARFaceAnchor else { return }

            if let faceGeometry = node.geometry as? ARSCNFaceGeometry {
                faceGeometry.update(from: faceAnchor.geometry)
            }

            onFaceAnchorUpdate?(faceAnchor)
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
