//
//  ContentView.swift
//  SariliScan
//
//  Created by Tez on 24/6/2026.
//

import SwiftUI
import AVFoundation

struct ContentView: View {
    @State private var faceDetected = false
    @State private var cameraStatus: CameraStatus = .undetermined

    enum CameraStatus {
        case undetermined, authorized, denied
    }

    var body: some View {
        ZStack(alignment: .top) {
            switch cameraStatus {
            case .authorized:
                ARFaceTrackingView(faceDetected: $faceDetected)
                    .ignoresSafeArea()
            case .denied:
                deniedView
            case .undetermined:
                Color.black
                    .ignoresSafeArea()
            }

            statusBadge
        }
        .task {
            await requestCameraAccess()
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
        switch cameraStatus {
        case .authorized:
            return faceDetected ? "Face detected" : "No face detected"
        case .denied:
            return "Camera access denied"
        case .undetermined:
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

    // MARK: - Permission

    private func requestCameraAccess() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraStatus = .authorized
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraStatus = granted ? .authorized : .denied
        case .denied, .restricted:
            cameraStatus = .denied
        @unknown default:
            cameraStatus = .denied
        }
    }
}

#Preview {
    ContentView()
}
