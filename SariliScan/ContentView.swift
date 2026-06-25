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
    @State private var faceDetected = false
    @State private var scanState: ScanState = .requestingPermission
    @State private var readout: FaceReadout?

    enum ScanState {
        case requestingPermission
        case cameraDenied
        case unsupported       // device has no TrueDepth camera / no face tracking
        case ready             // camera authorized and face tracking supported
    }

    /// Raw ARKit floats forwarded from the face anchor. No mm conversion, no averaging.
    struct FaceReadout: Sendable {
        let leftEye: SIMD3<Float>
        let rightEye: SIMD3<Float>
        let eyeDistance: Float
        let faceOrigin: SIMD3<Float>
    }

    var body: some View {
        ZStack(alignment: .top) {
            switch scanState {
            case .ready:
                ARFaceTrackingView(faceDetected: $faceDetected,
                                   onFaceAnchorUpdate: handleFaceAnchor)
                    .ignoresSafeArea()
            case .cameraDenied:
                deniedView
            case .unsupported:
                unsupportedView
            case .requestingPermission:
                Color.black
                    .ignoresSafeArea()
            }

            statusBadge

            if scanState == .ready, let readout {
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

    // MARK: - Debug readout overlay

    private func debugOverlay(_ r: FaceReadout) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("L eye   \(vec(r.leftEye))")
            Text("R eye   \(vec(r.rightEye))")
            Text("eye Δ   \(String(format: "%+.5f", r.eyeDistance))")
            Text("origin  \(vec(r.faceOrigin))")
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.green)
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private func vec(_ v: SIMD3<Float>) -> String {
        String(format: "%+.5f %+.5f %+.5f", v.x, v.y, v.z)
    }

    // MARK: - Face anchor callback (decoupled from mesh rendering)

    private func handleFaceAnchor(_ faceAnchor: ARFaceAnchor) {
        // Reading happens on the SceneKit render thread; capture raw floats into a
        // Sendable value and hand off to the main thread for display.
        let l = faceAnchor.leftEyeTransform.columns.3
        let r = faceAnchor.rightEyeTransform.columns.3
        let o = faceAnchor.transform.columns.3

        let left = SIMD3<Float>(l.x, l.y, l.z)
        let right = SIMD3<Float>(r.x, r.y, r.z)
        let origin = SIMD3<Float>(o.x, o.y, o.z)
        let value = FaceReadout(
            leftEye: left,
            rightEye: right,
            eyeDistance: simd_distance(left, right),
            faceOrigin: origin
        )

        DispatchQueue.main.async {
            self.readout = value
        }
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
