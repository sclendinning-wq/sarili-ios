//
//  ARFaceTrackingView.swift
//  SariliScan
//
//  Bridges a RealityKit ARView running an ARFaceTrackingConfiguration into SwiftUI.
//

import SwiftUI
import ARKit
import RealityKit

/// A SwiftUI wrapper around a RealityKit `ARView` that runs a face-tracking
/// `ARSession`. Reports whether a face is currently being tracked back to
/// SwiftUI via the `faceDetected` binding.
struct ARFaceTrackingView: UIViewRepresentable {

    /// Driven from the AR session delegate; true while a face is tracked.
    @Binding var faceDetected: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(faceDetected: $faceDetected)
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        // Face tracking requires a device with a TrueDepth front camera.
        // On unsupported devices (and the simulator) we just return an empty view.
        guard ARFaceTrackingConfiguration.isSupported else {
            return arView
        }

        let configuration = ARFaceTrackingConfiguration()
        configuration.maximumNumberOfTrackedFaces = 1

        arView.session.delegate = context.coordinator
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // Nothing to update; state flows out via the coordinator.
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    /// Receives `ARSession` callbacks and pushes the tracked-face state into SwiftUI.
    ///
    /// All updates to `faceDetected` are dispatched to the main thread, since
    /// `ARSession` may deliver delegate callbacks off the main queue and SwiftUI
    /// state must only be mutated on the main thread.
    final class Coordinator: NSObject, ARSessionDelegate {
        @Binding private var faceDetected: Bool

        init(faceDetected: Binding<Bool>) {
            _faceDetected = faceDetected
        }

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
