//
//  FaceAnchorSample.swift
//  SariliScan
//
//  A Sendable, value-type snapshot of the data we need from an ARFaceAnchor for
//  a single frame. Copied on the SceneKit render thread and handed to the main
//  thread, so the non-Sendable ARFaceAnchor (and ARKit reference types in
//  general) never cross a thread boundary into main-actor-isolated UI code.
//

import Foundation
import simd

struct FaceAnchorSample: Sendable {
    /// Left eye transform translation (face-local), columns.3.
    let leftEye: SIMD3<Float>
    /// Right eye transform translation (face-local), columns.3.
    let rightEye: SIMD3<Float>
    /// Face anchor origin (world), transform.columns.3.
    let faceOrigin: SIMD3<Float>
    /// Face mesh vertices in face-local space (ARFaceGeometry.vertices).
    let vertices: [SIMD3<Float>]
    /// Face anchor world transform, for converting local vertices to world space.
    let faceTransform: simd_float4x4
    /// eyeBlinkLeft blend-shape coefficient [0,1].
    let blinkLeft: Float
    /// eyeBlinkRight blend-shape coefficient [0,1].
    let blinkRight: Float
}
