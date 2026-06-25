//
//  IrisLandmarks.swift
//  SariliScan
//
//  Vertex indices into ARFaceGeometry.vertices (the ~1220-point face mesh) for
//  the iris ring clusters. ARKit does not document iris vertex indices, so these
//  must be confirmed VISUALLY ON DEVICE using the vertex-identifier debug mode
//  (toggle "Vertices" in the scan view): the iris ring vertices are highlighted
//  in red — adjust the indices below until the highlighted dots sit on each iris.
//
//  Shared single source of truth: used both by the renderer (to highlight the
//  iris clusters) and by the PD measurement path (to compute iris centres).
//

import Foundation

enum IrisLandmarks {

    // ======================================================================
    // TBD ON DEVICE — fill these in after visual confirmation, then rebuild.
    // Leave empty until confirmed: empty means "no iris dots highlighted" and
    // "Iris landmark PD: n/a", which is the intended pre-calibration state.
    // ======================================================================

    /// Vertex indices forming the LEFT iris ring.
    static let leftIrisRing: [Int] = [
        // e.g. 1090, 1091, 1092, 1093, ...   // <- confirm on device
    ]

    /// Vertex indices forming the RIGHT iris ring.
    static let rightIrisRing: [Int] = [
        // e.g. 1010, 1011, 1012, 1013, ...   // <- confirm on device
    ]

    /// Convenience: all iris vertices (for highlighting in the debug dot view).
    static var allIrisRing: [Int] { leftIrisRing + rightIrisRing }
}
