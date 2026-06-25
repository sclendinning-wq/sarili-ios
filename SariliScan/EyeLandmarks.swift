//
//  EyeLandmarks.swift
//  SariliScan
//
//  Vertex indices into ARFaceGeometry.vertices (the ~1220-point face mesh) for
//  the EYELID RIM loops (the opening/outline of each eye). ARKit's face mesh
//  does NOT contain iris or pupil vertices — only these eyelid rim loops — so
//  the eye centre is estimated as the centroid of each rim loop.
//
//  Source / how to populate:
//  Apple does not document these indices, and no public source publishes a
//  reliable list (facelandmarks.com is an INTERACTIVE picker, not a reference
//  table; the only eye groups it exposes are eyelid loops). Identify the rim
//  vertices on device using the "Eyelid" debug toggle (or facelandmarks.com),
//  then paste ~6–8 indices per eye below and rebuild. The large distinct dots
//  let you confirm/correct the loops visually against your own face.
//
//  Refs: facelandmarks.com ; oxfordechoes.com/ios-arkit-face-tracking-vertices ;
//  Apple ARFaceGeometry docs (vertex count only, no index map).
//
//  Shared single source of truth: used by the renderer (to highlight the rim)
//  and the measurement path (to compute eye centres).
//

import Foundation

enum EyeLandmarks {

    // ======================================================================
    // TBD ON DEVICE — empty by design. Empty == no rim dots highlighted and
    // "Eyelid centroid PD: n/a", which is the intended pre-calibration state.
    // Do NOT fabricate these: wrong indices silently corrupt the PD reading.
    // ======================================================================

    /// Vertex indices forming the LEFT eyelid rim loop (~6–8 vertices).
    static let leftEyeRim: [Int] = [
        // e.g. 1093, 1094, 1095, ...   // <- confirm on device
    ]

    /// Vertex indices forming the RIGHT eyelid rim loop (~6–8 vertices).
    static let rightEyeRim: [Int] = [
        // e.g. 1013, 1014, 1015, ...   // <- confirm on device
    ]

    /// Convenience: all rim vertices (for highlighting in the debug dot view).
    static var allEyeRim: [Int] { leftEyeRim + rightEyeRim }

    /// EMPIRICAL calibration offset (mm) added to the eyelid-centroid PD.
    /// Must be derived from optometrist validation against known clinical PD —
    /// this is NOT an anatomical constant. Leave 0 until validated on real eyes.
    static let pdCalibrationOffsetMM: Float = 0.0
}
