//
//  SariliScanApp.swift
//  SariliScan
//
//  Created by Tez on 24/6/2026.
//

import SwiftUI

@main
struct SariliScanApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Switches between the separate systems: the ARKit face scan (face width /
/// bridge / proportions / fit), the card-reference PD test harness, and the
/// raw-TrueDepth profile capture (milestone 11). Only one is in the hierarchy
/// at a time, so only one camera session is ever active.
struct RootView: View {
    enum Mode { case faceScan, cardPD, profile, skinTone }
    @State private var mode: Mode = .faceScan

    var body: some View {
        switch mode {
        case .faceScan:
            ContentView(onOpenCardPD: { mode = .cardPD },
                        onOpenProfile: { mode = .profile },
                        onOpenSkinTone: { mode = .skinTone })
        case .cardPD:
            CardPDView(onClose: { mode = .faceScan })
        case .profile:
            ProfileCaptureView(onClose: { mode = .faceScan })
        case .skinTone:
            SkinToneView(onClose: { mode = .faceScan })
        }
    }
}
