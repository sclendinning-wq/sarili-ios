//
//  ContentView.swift
//  SariliScan
//
//  Created by Tez on 24/6/2026.
//

import SwiftUI
import AVFoundation
import ARKit

struct ContentView: View {
    @State private var faceDetected = false
    @State private var scanState: ScanState = .requestingPermission

    enum ScanState {
        case requestingPermission
        case cameraDenied
        case unsupported       // device has no TrueDepth camera / no face tracking
        case ready             // camera authorized and face tracking supported
    }

    var body: some View {
        ZStack(alignment: .top) {
            switch scanState {
            case .ready:
                ARFaceTrackingView(faceDetected: $faceDetected)
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
        }
        .task {
            await startSession()
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
