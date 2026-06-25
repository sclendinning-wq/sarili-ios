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
    @State private var tappedVertex: Int?

    // DEBUG-ONLY: eyelid index collection state.
    @State private var collectingEye: Eye = .left
    @State private var leftCollected: [Int] = []
    @State private var rightCollected: [Int] = []
    @State private var collectionHistory: [Eye] = []   // order of adds, for Undo

    enum ScanState {
        case requestingPermission
        case cameraDenied
        case unsupported       // device has no TrueDepth camera / no face tracking
        case ready             // camera authorized and face tracking supported
    }

    enum Eye { case left, right }

    /// Raw ARKit floats forwarded from the face anchor. No averaging, single frame.
    struct FaceReadout: Sendable {
        let leftEye: SIMD3<Float>
        let rightEye: SIMD3<Float>
        let eyeDistance: Float          // metres, eye-transform separation
        let faceOrigin: SIMD3<Float>
        let eyeTransformPDmm: Float      // eye-transform PD, millimetres
        let eyelidPDmm: Float?           // eyelid-centroid PD (world space); nil until rim indices set
    }

    var body: some View {
        ZStack(alignment: .top) {
            switch scanState {
            case .ready:
                ARFaceTrackingView(faceDetected: $faceDetected,
                                   showVertexDots: showVertexDots,
                                   onSampleReady: handleSample,
                                   onVertexPicked: handleVertexTap)
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

            if scanState == .ready, showVertexDots {
                tapIdentifyBadge
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 76)

                collectionPanel
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

    // MARK: - Eyelid index collection (debug)

    /// DEBUG-ONLY: collect tapped vertex indices into per-eye lists, with
    /// undo/clear/copy, so eyelid rim indices can be gathered on device.
    private var collectionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Collecting", selection: $collectingEye) {
                Text("Left Eye").tag(Eye.left)
                Text("Right Eye").tag(Eye.right)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 4) {
                Text("Left eyelid indices:  \(format(leftCollected))")
                Text("Right eyelid indices: \(format(rightCollected))")
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.white)
            .lineLimit(3)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button("Undo last", action: undoLast)
                Button("Clear left", action: clearLeft)
                Button("Clear right", action: clearRight)
                Button("Copy indices", action: copyIndices)
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

    /// Called on the main thread when a vertex is tapped. Marks it (yellow) and,
    /// while collecting, appends it to the selected eye list (no duplicates).
    private func handleVertexTap(_ index: Int) {
        tappedVertex = index
        guard showVertexDots else { return }
        switch collectingEye {
        case .left:
            guard !leftCollected.contains(index) else { return }
            leftCollected.append(index)
        case .right:
            guard !rightCollected.contains(index) else { return }
            rightCollected.append(index)
        }
        collectionHistory.append(collectingEye)
    }

    private func undoLast() {
        guard let last = collectionHistory.popLast() else { return }
        switch last {
        case .left:  if !leftCollected.isEmpty { leftCollected.removeLast() }
        case .right: if !rightCollected.isEmpty { rightCollected.removeLast() }
        }
    }

    private func clearLeft() {
        leftCollected.removeAll()
        collectionHistory.removeAll { $0 == .left }
    }

    private func clearRight() {
        rightCollected.removeAll()
        collectionHistory.removeAll { $0 == .right }
    }

    private func copyIndices() {
        let text = """
        Left eyelid rim indices:
        \(format(leftCollected))

        Right eyelid rim indices:
        \(format(rightCollected))
        """
        UIPasteboard.general.string = text
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
            Text("Eye transform PD:     \(mm(r.eyeTransformPDmm))")
            Text("Eyelid centroid PD:   \(r.eyelidPDmm.map(mm) ?? "n/a — set eyelid rim indices")")
            Text("Coordinate space:     world")
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

    // MARK: - Sample callback (runs on the main thread)

    /// Receives a copied, Sendable per-frame sample on the main thread and does
    /// all measurement here, decoupled from the mesh renderer and the render
    /// thread. No raw ARFaceAnchor is involved.
    private func handleSample(_ sample: FaceAnchorSample) {
        // --- Eye-transform PD (existing approach, kept for comparison) ---
        let eyeDistance = simd_distance(sample.leftEye, sample.rightEye)

        // --- Eyelid-centroid PD (world space) ---
        // ARFaceGeometry.vertices are in face-local space; transform to world
        // before measuring. Each eye centre is the centroid of its eyelid rim
        // loop; PD is the distance between the two centres, plus an empirical
        // calibration offset (0 until validated against clinical PD).
        var eyelidPDmm: Float?
        if let leftCentre = worldEyeCentre(EyeLandmarks.leftEyeRim, sample.vertices, sample.faceTransform),
           let rightCentre = worldEyeCentre(EyeLandmarks.rightEyeRim, sample.vertices, sample.faceTransform) {
            let pdMetres = simd_distance(leftCentre, rightCentre)
            eyelidPDmm = pdMetres * 1000 + EyeLandmarks.pdCalibrationOffsetMM
        }

        readout = FaceReadout(
            leftEye: sample.leftEye,
            rightEye: sample.rightEye,
            eyeDistance: eyeDistance,
            faceOrigin: sample.faceOrigin,
            eyeTransformPDmm: eyeDistance * 1000,
            eyelidPDmm: eyelidPDmm
        )
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
