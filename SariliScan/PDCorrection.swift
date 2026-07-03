//
//  PDCorrection.swift
//  SariliScan
//
//  Milestone 7 — gaze-axis offset correction for ARKit eye-transform PD.
//
//  Why: ARKit's leftEyeTransform/rightEyeTransform sit at the eyeball ROTATION
//  CENTRE, ~10-13mm behind the pupil plane. Measuring between rotation centres
//  overreads clinical PD (observed ~1.5-2.8mm), and the geometry explains it:
//  when the eyes converge on a near target the rotation centres are farther
//  apart than the pupils. Projecting each eye origin forward along its own
//  gaze axis onto the pupil plane, then measuring between the projected
//  points, removes both the anatomical offset and (because the gaze axes
//  tilt inward with convergence) the convergence error at the same time.
//
//  The offset below is an EMPIRICAL constant to be fitted against clinical
//  ground truth (pupilometer) on a validation panel — treat it as a starting
//  point, not anatomy gospel. ARKit's internal eye model is undocumented.
//
//  Measurement protocol note: the corrected value approximates NEAR PD at the
//  user's current fixation. For DISTANCE PD (what most prescriptions use),
//  instruct the user to fixate a distant target past the phone, which makes
//  the gaze axes near-parallel.
//

import Foundation
import simd

enum PDCorrection {

    /// Forward offset (mm) from the eyeball rotation centre to the pupil plane.
    /// EMPIRICAL — refit against a clinical validation panel before trusting.
    static let rotationCentreToPupilMM: Float = 11.0

    /// Result of the corrected-PD computation for one frame.
    struct Result: Sendable {
        let correctedPDmm: Float     // distance between pupil-plane points
        let rawPDmm: Float           // distance between rotation centres
        let offsetAppliedMM: Float   // the constant used, for the readout
    }

    /// Projects each eye's origin forward along its own gaze axis by the
    /// rotation-centre→pupil offset and measures between the projected points.
    ///
    /// Gaze axis: the eye transform's Z column, sign-corrected so it points out
    /// of the face (the face anchor's +Z is out of the face; ARKit's eye-node
    /// axis convention is undocumented, so we normalise the sign explicitly
    /// rather than assuming it).
    static func correctedPD(leftEyeTransform: simd_float4x4,
                            rightEyeTransform: simd_float4x4) -> Result {
        let offsetMetres = rotationCentreToPupilMM / 1000

        func pupilPoint(_ t: simd_float4x4) -> SIMD3<Float> {
            let origin = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            var gaze = simd_normalize(SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z))
            // Face-local +Z points out of the face; ensure the gaze axis does too.
            if gaze.z < 0 { gaze = -gaze }
            return origin + gaze * offsetMetres
        }

        let leftOrigin = SIMD3<Float>(leftEyeTransform.columns.3.x,
                                      leftEyeTransform.columns.3.y,
                                      leftEyeTransform.columns.3.z)
        let rightOrigin = SIMD3<Float>(rightEyeTransform.columns.3.x,
                                       rightEyeTransform.columns.3.y,
                                       rightEyeTransform.columns.3.z)

        let rawPDmm = simd_distance(leftOrigin, rightOrigin) * 1000
        let correctedPDmm = simd_distance(pupilPoint(leftEyeTransform),
                                          pupilPoint(rightEyeTransform)) * 1000

        return Result(correctedPDmm: correctedPDmm,
                      rawPDmm: rawPDmm,
                      offsetAppliedMM: rotationCentreToPupilMM)
    }
}
