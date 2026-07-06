//
//  FaceShapeRatios.swift
//  SariliScan
//
//  Milestone 10 — face-shape ratios/proportions from the ARKit face mesh.
//
//  Why ratios: milestone 9's open question is whether the fitted mesh is
//  accurate in ABSOLUTE mm. Ratios (width-to-length, forehead/jaw vs
//  cheekbone) are robust to a fixed scale error — if the whole mesh reads 3%
//  small, every ratio is unchanged — so they are cheaper to trust than
//  absolute measurements. They only assume the mesh's PROPORTIONS track the
//  face, which still needs a sanity check on device (compare the readout
//  against what the mirror/photos say about the person's face shape).
//
//  Approach, following the project's rules:
//  - No vertex indices at all. Every width is the widest mesh x-extent
//    within a horizontal band, same index-free technique as milestone 9's
//    face width; band positions are defined RELATIVE to mesh landmarks we
//    already have (chin = lowest vertex, crown = highest vertex, eye line =
//    mean eye-transform height), so they scale with the face.
//  - The band positions (fractions below) are EMPIRICAL STARTING VALUES,
//    not validated anatomy. The harness shows each band's vertex count and
//    the height where the max width occurs so they can be tuned on device.
//  - The ARKit mesh ends near the hairline, not the crown of the head, so
//    "face length" here is mesh-top→chin, which under-reads a true
//    hairline-to-chin length. Fine for comparing faces measured the same
//    way; flagged so nobody mistakes it for the classic beautician number.
//  - The shape label is a coarse heuristic over the ratios, for eyeballing
//    on device only — NOT a validated classifier. Milestone 10 validation =
//    run it on a few faces whose shape category is agreed by humans and see
//    whether the label (and more importantly the ratios) separate them.
//

import Foundation
import simd

/// Per-frame face-shape readout. Widths/lengths in mm (subject to the mesh's
/// absolute scale — the RATIOS are the deliverable), ratios dimensionless.
struct FaceShapeReadout: Sendable {
    let faceLengthMM: Float        // mesh top → chin (mesh ends ~hairline)
    let foreheadWidthMM: Float
    let cheekWidthMM: Float        // widest extent anywhere on the mesh
    let cheekWidthHeightPct: Float // where that widest extent sits, as % of chin→top (diagnostic)
    let jawWidthMM: Float
    let foreheadBandCount: Int     // band vertex counts (sanity — tune bands if tiny)
    let jawBandCount: Int
    // Ratios — the actual milestone 10 deliverable.
    let widthToLength: Float?      // cheek width / face length
    let foreheadToCheek: Float?
    let jawToCheek: Float?
    let shapeGuess: String         // coarse heuristic label, debug only
}

enum FaceShapeRatios {

    // EMPIRICAL band positions (fractions of face height), starting values to
    // tune on device — flagged per the working rules, not validated anatomy.
    //
    // Heights are normalised t ∈ [0,1] from chin (t=0) to mesh top (t=1).
    // The eye line lands around t ≈ 0.55–0.65 on typical fitted meshes; these
    // fractions are chosen relative to that expectation:
    /// Forehead band centre: above the eye line, below the hairline edge.
    static let foreheadCentreT: Float = 0.82
    /// Jaw (gonial) band centre: around mouth/lower-lip height.
    static let jawCentreT: Float = 0.28
    /// Half-height of each band as a fraction of face height.
    static let bandHalfT: Float = 0.05

    static func measure(sample: FaceAnchorSample) -> FaceShapeReadout? {
        let vertices = sample.vertices
        guard !vertices.isEmpty else { return nil }

        // Vertical extent of the mesh in face-local space.
        var minY = Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        for v in vertices {
            if v.y < minY { minY = v.y }
            if v.y > maxY { maxY = v.y }
        }
        let height = maxY - minY
        guard height > 0 else { return nil }

        func bandWidth(centreT: Float) -> (width: Float, count: Int) {
            let lo = minY + (centreT - bandHalfT) * height
            let hi = minY + (centreT + bandHalfT) * height
            var bandMinX = Float.greatestFiniteMagnitude
            var bandMaxX = -Float.greatestFiniteMagnitude
            var count = 0
            for v in vertices where v.y >= lo && v.y <= hi {
                count += 1
                if v.x < bandMinX { bandMinX = v.x }
                if v.x > bandMaxX { bandMaxX = v.x }
            }
            return count > 0 ? (bandMaxX - bandMinX, count) : (0, 0)
        }

        // Cheek width = widest extent anywhere; record WHERE it occurs so the
        // band fractions above can be tuned against reality on device.
        // Scan in thin slices so one stray wide slice low on the face (jaw)
        // vs high (cheekbone) is visible in the diagnostic.
        let sliceCount = 24
        var cheekWidth: Float = 0
        var cheekT: Float = 0
        for i in 0..<sliceCount {
            let t = (Float(i) + 0.5) / Float(sliceCount)
            let (w, _) = bandWidth(centreT: t)
            if w > cheekWidth {
                cheekWidth = w
                cheekT = t
            }
        }

        let (foreheadW, foreheadN) = bandWidth(centreT: foreheadCentreT)
        let (jawW, jawN) = bandWidth(centreT: jawCentreT)

        let lengthMM = height * 1000
        let cheekMM = cheekWidth * 1000
        let foreheadMM = foreheadW * 1000
        let jawMM = jawW * 1000

        let widthToLength: Float? = lengthMM > 0 ? cheekMM / lengthMM : nil
        let foreheadToCheek: Float? = cheekMM > 0 ? foreheadMM / cheekMM : nil
        let jawToCheek: Float? = cheekMM > 0 ? jawMM / cheekMM : nil

        return FaceShapeReadout(
            faceLengthMM: lengthMM,
            foreheadWidthMM: foreheadMM,
            cheekWidthMM: cheekMM,
            cheekWidthHeightPct: cheekT * 100,
            jawWidthMM: jawMM,
            foreheadBandCount: foreheadN,
            jawBandCount: jawN,
            widthToLength: widthToLength,
            foreheadToCheek: foreheadToCheek,
            jawToCheek: jawToCheek,
            shapeGuess: classify(widthToLength: widthToLength,
                                 foreheadToCheek: foreheadToCheek,
                                 jawToCheek: jawToCheek))
    }

    /// COARSE HEURISTIC ONLY — standard face-shape rules of thumb expressed
    /// over the three ratios. Thresholds are guesses to eyeball on device;
    /// the ratios themselves are the trustworthy output, not this label.
    static func classify(widthToLength: Float?,
                         foreheadToCheek: Float?,
                         jawToCheek: Float?) -> String {
        guard let wl = widthToLength, let fc = foreheadToCheek, let jc = jawToCheek else {
            return "n/a"
        }
        if wl < 0.62 { return "oblong?" }                    // much longer than wide
        if jc > 0.92 && fc > 0.92 { return wl > 0.78 ? "square?" : "rect?" }
        if fc > jc + 0.08 { return "heart?" }                // forehead clearly widest
        if jc > fc + 0.08 { return "triangle?" }             // jaw clearly widest
        if wl > 0.80 { return "round?" }                     // nearly as wide as long
        return "oval?"
    }
}
