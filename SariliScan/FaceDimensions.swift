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

/// DEBUG-ONLY: slot-assignment bar shown in vertex-dots mode. Tap a mesh dot
/// (its index appears in the badge above), then press a slot button to assign
/// that vertex as bridge-left / bridge-right / nose saddle. Assigned vertices
/// join the highlighted (teal) dot layer so the assignment is visually
/// checkable on the live mesh — same trust-check pattern as the iris dots.
struct FaceDimsAssignBar: View {
    let tapped: Int?
    @Binding var bridgeL: Int?
    @Binding var bridgeR: Int?
    @Binding var saddle: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Face dims: tap a dot, then assign it")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white)
            HStack(spacing: 8) {
                slot("Bridge L", $bridgeL, "bridgeL")
                slot("Bridge R", $bridgeR, "bridgeR")
                slot("Saddle", $saddle, "saddle")
                Button("Clear") {
                    bridgeL = nil; bridgeR = nil; saddle = nil
                    FaceDimensions.saveIndex(nil, "bridgeL")
                    FaceDimensions.saveIndex(nil, "bridgeR")
                    FaceDimensions.saveIndex(nil, "saddle")
                }
                .tint(.red)
            }
            .font(.caption2)
            .controlSize(.small)
            .buttonStyle(.bordered)
            .tint(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .padding(10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    private func slot(_ name: String, _ binding: Binding<Int?>, _ key: String) -> some View {
        Button("\(name): \(binding.wrappedValue.map(String.init) ?? "—")") {
            guard let tapped else { return }
            binding.wrappedValue = tapped
            FaceDimensions.saveIndex(tapped, key)
        }
        .disabled(tapped == nil)
    }
}
