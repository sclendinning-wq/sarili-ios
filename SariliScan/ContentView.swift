//
//  ContentView.swift
//  SariliScan
//
//  Created by Tez on 24/6/2026.
//

import SwiftUI

struct ContentView: View {
    @State private var faceDetected = false

    var body: some View {
        ZStack(alignment: .top) {
            ARFaceTrackingView(faceDetected: $faceDetected)
                .ignoresSafeArea()

            Text(faceDetected ? "Face detected" : "No face detected")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 24)
        }
    }
}

#Preview {
    ContentView()
}
