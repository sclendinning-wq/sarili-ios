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
    @State private var showVertexDots = false

    enum ScanState {
        case requestingPermission
        case cameraDenied
        case unsupported       // device has no TrueDepth camera / no face tracking
        case ready             // camera authorized and face tracking supported
    }

    /// Raw ARKit floats forwarded from the face anchor. No averaging, single frame.
    struct FaceReadout: Sendable {
        let leftEye: SIMD3<Float>
        let rightEye: SIMD3<Float>
        let eyeDistance: Float          // metres, eye-transform separation
        let faceOrigin: SIMD3<Float>
        let eyeTransformPDmm: Float      // eye-transform PD, millimetres
        let irisPDmm: Float?             // iris-landmark PD (world space); nil until indices set
    }

    var body: some View {
        ZStack(alignment: .top) {
            switch scanState {
            case .ready:
                ARFaceTrackingView(faceDetected: $faceDetected,
                                   showVertexDots: showVertexDots,
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

            if scanState == .ready {
                vertexToggle
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 20)
                    .padding(.trailing, 16)
            }

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

    // MARK: - Debug readout overlay

    private func debugOverlay(_ r: FaceReadout) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Raw eye-transform readout (kept from milestone 4).
            Text("L eye   \(vec(r.leftEye))")
            Text("R eye   \(vec(r.rightEye))")
            Text("eye Δ   \(String(format: "%+.5f", r.eyeDistance))")
            Text("origin  \(vec(r.faceOrigin))")

            Divider().overlay(.green.opacity(0.4))

            // Side-by-side PD comparison.
            Text("Eye transform PD:   \(mm(r.eyeTransformPDmm))")
            Text("Iris landmark PD:   \(r.irisPDmm.map(mm) ?? "n/a — set iris indices")")
            Text("Coordinate space:   world")
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.green)
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private func vec(_ v: SIMD3<Float>) -> String {
        String(format: "%+.5f %+.5f %+.5f", v.x, v.y, v.z)
    }

    private func mm(_ value: Float) -> String {
        String(format: "%.1fmm", value)
    }

    // MARK: - Face anchor callback (decoupled from mesh rendering)

    private func handleFaceAnchor(_ faceAnchor: ARFaceAnchor) {
        // Reading happens on the SceneKit render thread; capture raw floats into a
        // Sendable value and hand off to the main thread for display.

        // --- Eye-transform PD (existing approach, kept for comparison) ---
        let l = faceAnchor.leftEyeTransform.columns.3
        let r = faceAnchor.rightEyeTransform.columns.3
        let o = faceAnchor.transform.columns.3

        let left = SIMD3<Float>(l.x, l.y, l.z)
        let right = SIMD3<Float>(r.x, r.y, r.z)
        let origin = SIMD3<Float>(o.x, o.y, o.z)
        let eyeDistance = simd_distance(left, right)

        // --- Iris-landmark PD (world space) ---
        // ARFaceGeometry.vertices are in face-local space; transform to world
        // before measuring. Distance is computed between the two iris centres.
        var irisPDmm: Float?
        let vertices = faceAnchor.geometry.vertices
        let faceTransform = faceAnchor.transform
        if let leftIris = worldIrisCentre(IrisLandmarks.leftIrisRing, vertices, faceTransform),
           let rightIris = worldIrisCentre(IrisLandmarks.rightIrisRing, vertices, faceTransform) {
            let pdMetres = simd_distance(leftIris, rightIris)
            irisPDmm = pdMetres * 1000
        }

        let value = FaceReadout(
            leftEye: left,
            rightEye: right,
            eyeDistance: eyeDistance,
            faceOrigin: origin,
            eyeTransformPDmm: eyeDistance * 1000,
            irisPDmm: irisPDmm
        )

        DispatchQueue.main.async {
            self.readout = value
        }
    }

    /// Average of the given iris-ring vertices, transformed from face-local to
    /// world space. Returns nil if no valid indices are configured yet.
    private func worldIrisCentre(_ indices: [Int],
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
