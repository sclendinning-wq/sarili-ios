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

/// Switches between the two separate systems: the ARKit face scan (face width /
/// bridge / proportions / fit) and the card-reference PD test harness. Only one
/// is in the hierarchy at a time, so only one camera session is ever active.
struct RootView: View {
    enum Mode { case faceScan, cardPD }
    @State private var mode: Mode = .faceScan

    var body: some View {
        switch mode {
        case .faceScan:
            ContentView(onOpenCardPD: { mode = .cardPD })
        case .cardPD:
            CardPDView(onClose: { mode = .faceScan })
        }
    }
}
