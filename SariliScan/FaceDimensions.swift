//
//  FaceDimensions.swift
//  SariliScan
//
//  Milestone 9 — frontal face-dimension harness (face width, bridge width,
//  bridge height) from the ARKit face mesh.
//
//  Approach, following the project's rules:
//  - NO hardcoded vertex indices are invented. Bridge measurements use vertex
//    slots assigned on-device via the existing tap-to-identify tool; the mesh
//    topology is fixed (~1220 vertices, same indices for every face and every
//    frame), so once an index is confirmed on-device it holds generally.
//  - Face width needs no indices at all: it is the widest x-extent of the mesh
//    within a horizontal band at eye height, computed fresh each frame.
//  - Every number here is UNVALIDATED until checked against a physical
//    caliper/ruler. The ARKit mesh is a fitted morphable model, not a raw
//    depth scan — it can be stable and still be wrong in absolute mm (the
//    exact trap the eye transforms fell into for PD). Also note the mesh ends
//    near the sideburns, so "mesh width" may under-read true temple-to-temple
//    width; the caliper comparison decides how usable it is.
//
//  All measurement happens in face-local space (metres). The face transform is
//  rigid, so distances measured locally equal world-space distances.
//

import Foundation
import SwiftUI
import simd

/// Per-frame face-dimension readout, millimetres.
struct FaceDimensionsReadout: Sendable {
    let faceWidthAtEyeBandMM: Float   // widest mesh extent within the eye-height band
    let maxMeshWidthMM: Float         // widest mesh extent anywhere (for comparison)
    let bandVertexCount: Int          // how many vertices fell in the band (sanity)
    let bridgeWidthXMM: Float?        // |Δx| between assigned bridge L/R vertices
    let bridgeWidth3DMM: Float?       // 3D distance between the same two vertices
    let bridgeHeightMM: Float?        // saddle vertex y minus eye-line y (+ = above pupils)
}

enum FaceDimensions {

    /// Half-height of the eye-level band used for face width, mm. EMPIRICAL
    /// starting value — a frame front sits roughly at eye height, but the band
    /// that best matches a caliper measurement is exactly what the milestone 9
    /// validation is meant to find. Tune against the caliper, not by eye.
    static let eyeBandHalfHeightMM: Float = 8

    static func measure(sample: FaceAnchorSample,
                        bridgeL: Int?,
                        bridgeR: Int?,
                        saddle: Int?) -> FaceDimensionsReadout {
        let vertices = sample.vertices

        // Eye line height in face-local space (mean of the two eye transforms).
        let eyeY = (sample.leftEye.y + sample.rightEye.y) / 2
        let band = eyeBandHalfHeightMM / 1000

        var bandMinX = Float.greatestFiniteMagnitude
        var bandMaxX = -Float.greatestFiniteMagnitude
        var bandCount = 0
        var allMinX = Float.greatestFiniteMagnitude
        var allMaxX = -Float.greatestFiniteMagnitude
        for v in vertices {
            if v.x < allMinX { allMinX = v.x }
            if v.x > allMaxX { allMaxX = v.x }
            if abs(v.y - eyeY) <= band {
                bandCount += 1
                if v.x < bandMinX { bandMinX = v.x }
                if v.x > bandMaxX { bandMaxX = v.x }
            }
        }
        let bandWidthMM: Float = bandCount > 0 ? (bandMaxX - bandMinX) * 1000 : 0
        let maxWidthMM: Float = vertices.isEmpty ? 0 : (allMaxX - allMinX) * 1000

        func vertex(_ index: Int?) -> SIMD3<Float>? {
            guard let index, index >= 0, index < vertices.count else { return nil }
            return vertices[index]
        }

        var bridgeWidthXMM: Float?
        var bridgeWidth3DMM: Float?
        if let l = vertex(bridgeL), let r = vertex(bridgeR) {
            bridgeWidthXMM = abs(l.x - r.x) * 1000
            bridgeWidth3DMM = simd_distance(l, r) * 1000
        }

        var bridgeHeightMM: Float?
        if let s = vertex(saddle) {
            // Face-local +y is up: positive = saddle sits above the pupil line.
            bridgeHeightMM = (s.y - eyeY) * 1000
        }

        return FaceDimensionsReadout(faceWidthAtEyeBandMM: bandWidthMM,
                                     maxMeshWidthMM: maxWidthMM,
                                     bandVertexCount: bandCount,
                                     bridgeWidthXMM: bridgeWidthXMM,
                                     bridgeWidth3DMM: bridgeWidth3DMM,
                                     bridgeHeightMM: bridgeHeightMM)
    }

    // MARK: - Geometric slot suggestions (index-free guide)

    // EMPIRICAL guide constants — these position the orange SUGGESTION dots
    // only; nothing is persisted until the user visually confirms against
    // their own face, so these are guide starting values, not calibration:
    /// Lateral offset of each nose pad from the face centreline.
    static let padOffsetXMM: Float = 9
    /// Vertical offset of the pad target BELOW the eye line. Tuned across
    /// three on-device rounds (n=2): 4mm read as bottom-of-pad-zone (too
    /// low), and the chosen convention is saddle ON the pupil line with the
    /// pads just below it — so 2mm below. Still empirical.
    static let padDropMM: Float = 2
    /// Half-window searched around each pad target.
    static let padWindowMM: Float = 6

    /// Index-free geometric SUGGESTIONS for the three bridge slots, computed
    /// fresh from the live mesh (no invented indices — these come out of
    /// geometry evaluated on-device, then the user confirms visually before
    /// anything is saved, keeping the never-hardcode-indices rule intact).
    ///
    /// Pads: the most FORWARD (max z) vertex in a small window ±padOffsetXMM
    /// from the centreline, padDropMM below the eye line — at that lateral
    /// offset the forward-most surface is the nose flank where a pad rests.
    /// The left/right sign comes from the eye transforms, not an assumed
    /// axis convention.
    /// Saddle: the crest of the nose ridge AT the pupil line — the max-z
    /// vertex on the centreline within a small y-window around the eye line.
    /// (Earlier version hunted the lowest ridge dip up to 20mm above; the
    /// on-device convention chosen is saddle-on-pupil-line, pads below.)
    static func suggestBridgePoints(sample: FaceAnchorSample)
        -> (bridgeL: Int, bridgeR: Int, saddle: Int)? {
        let vertices = sample.vertices
        guard !vertices.isEmpty else { return nil }
        let midX = (sample.leftEye.x + sample.rightEye.x) / 2
        let eyeY = (sample.leftEye.y + sample.rightEye.y) / 2
        let leftSign: Float = sample.leftEye.x >= midX ? 1 : -1

        let padX = padOffsetXMM / 1000
        let padY = padDropMM / 1000
        let win = padWindowMM / 1000

        // Nearest vertex to the target point. (An earlier version took the
        // most FORWARD vertex in the window, but z rises toward the nose
        // ridge, so that biased both pads toward the centreline and made the
        // suggested pads sit too close together.) The x-window is kept
        // narrower than the y-window so it can't reach the ridge zone.
        let xWin: Float = 3.0 / 1000
        func pad(_ sign: Float) -> Int? {
            let cx = midX + sign * padX
            let cy = eyeY - padY
            var best: Int?
            var bestD = Float.greatestFiniteMagnitude
            for (i, v) in vertices.enumerated() {
                let dx = v.x - cx
                let dy = v.y - cy
                guard abs(dx) <= xWin, abs(dy) <= win else { continue }
                let d = dx * dx + dy * dy
                if d < bestD { bestD = d; best = i }
            }
            return best
        }

        let ridgeHalfX: Float = 4.0 / 1000
        let ridgeHalfY: Float = 3.0 / 1000   // ± window around the eye line
        var saddle: Int?
        var saddleZ = -Float.greatestFiniteMagnitude
        for (i, v) in vertices.enumerated()
        where abs(v.x - midX) <= ridgeHalfX && abs(v.y - eyeY) <= ridgeHalfY {
            if v.z > saddleZ { saddleZ = v.z; saddle = i }
        }

        guard let l = pad(leftSign), let r = pad(-leftSign), let s = saddle else { return nil }
        return (bridgeL: l, bridgeR: r, saddle: s)
    }

    // MARK: - Assigned-index persistence
    //
    // Assigned bridge indices survive relaunch so the tap-assignment only has
    // to be done once per install. Uses object(forKey:) because integer(forKey:)
    // returns 0 for "missing" and 0 is a valid vertex index.

    static func loadIndex(_ key: String) -> Int? {
        UserDefaults.standard.object(forKey: "faceDims." + key) as? Int
    }

    static func saveIndex(_ index: Int?, _ key: String) {
        if let index {
            UserDefaults.standard.set(index, forKey: "faceDims." + key)
        } else {
            UserDefaults.standard.removeObject(forKey: "faceDims." + key)
        }
    }
}

/// DEBUG-ONLY: guided slot assignment shown in vertex-dots mode. One step at
/// a time (bridge LEFT → bridge RIGHT → saddle). Each step shows an ORANGE
/// guide dot on the mesh at the geometrically suggested spot; the user either
/// accepts it ("Use suggested") or taps a nearby dot to fine-tune ("Use
/// tapped"). Each step needs a FRESH tap — the previous step's tap can't be
/// reused by accident. Assigned vertices join the teal dot layer so every
/// assignment stays visually checkable on the live mesh.
struct FaceDimsAssignBar: View {
    let tapped: Int?
    /// Geometric suggestion for the CURRENT step (the orange dot).
    let suggested: Int?
    @Binding var bridgeL: Int?
    @Binding var bridgeR: Int?
    @Binding var saddle: Int?

    /// Tap consumed by the previous confirm; a step only enables "Use tapped"
    /// once a different vertex has been tapped.
    @State private var consumedTap: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let step = currentStep {
                Text("Face dims — step \(stepNumber)/3: \(step.title)")
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundStyle(.yellow)
                Text(step.prompt)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white)
                Text(suggested != nil
                     ? "ORANGE dot = suggested spot. Accept it, or tap a dot near it to adjust."
                     : "No suggestion this frame — tap the dot yourself (freeze helps)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.orange)
                if let freshTap {
                    Text("Tapped vertex \(freshTap)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.green)
                }
                HStack(spacing: 8) {
                    Button("Use suggested") { confirm(step, suggested) }
                        .disabled(suggested == nil)
                        .tint(.orange)
                    Button("Use tapped") { confirm(step, freshTap) }
                        .disabled(freshTap == nil)
                        .tint(.white)
                    Button("Start over") { clearAll() }
                        .tint(.red)
                }
                .font(.caption2)
                .controlSize(.small)
                .buttonStyle(.bordered)
            } else {
                Text("Face dims: all 3 points assigned ✓ — live readings running")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green)
                Button("Redo points") { clearAll() }
                    .font(.caption2)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
        }
        .padding(10)
        .frame(maxWidth: 300)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    private struct Step {
        let title: String
        let prompt: String
        let binding: Binding<Int?>
        let key: String
    }

    private var currentStep: Step? {
        if bridgeL == nil {
            return Step(title: "Bridge LEFT",
                        prompt: "Where the LEFT nose pad would rest (left side of the nose bridge)",
                        binding: $bridgeL, key: "bridgeL")
        }
        if bridgeR == nil {
            return Step(title: "Bridge RIGHT",
                        prompt: "Where the RIGHT nose pad would rest",
                        binding: $bridgeR, key: "bridgeR")
        }
        if saddle == nil {
            return Step(title: "Nose SADDLE",
                        prompt: "The dip at the top of the nose, where a frame bridge sits",
                        binding: $saddle, key: "saddle")
        }
        return nil
    }

    private var stepNumber: Int {
        [bridgeL, bridgeR, saddle].filter { $0 != nil }.count + 1
    }

    /// A tap that hasn't already been consumed by a previous confirm.
    private var freshTap: Int? {
        tapped == consumedTap ? nil : tapped
    }

    private func confirm(_ step: Step, _ index: Int?) {
        guard let index else { return }
        step.binding.wrappedValue = index
        FaceDimensions.saveIndex(index, step.key)
        consumedTap = tapped
    }

    private func clearAll() {
        bridgeL = nil; bridgeR = nil; saddle = nil
        // Consume the current tap too — after a reset, step 1 should demand a
        // genuinely fresh tap, not inherit whatever was tapped last.
        consumedTap = tapped
        FaceDimensions.saveIndex(nil, "bridgeL")
        FaceDimensions.saveIndex(nil, "bridgeR")
        FaceDimensions.saveIndex(nil, "saddle")
    }
}
