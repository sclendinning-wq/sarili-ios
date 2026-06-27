//
//  VisionPupilDetector.swift
//  SariliScan
//
//  TEST HARNESS (not a final medical feature). PD-from-image pipeline kept in
//  four strictly separate stages:
//
//      1. detect pupil pixels   (PupilDetector — swappable)
//      2. choose depth source   (caller: ARKit eye-transform plane)
//      3. convert pixels -> mm   (VisionPDPipeline)
//      4. display / log result   (VisionDebugInfo, assembled by the caller)
//
//  COORDINATE PATH (made explicit so it can be inspected):
//
//      VNFaceLandmarkRegion2D.normalizedPoints   // normalised INSIDE the
//                                                // face bounding box, BL origin
//        -> compose with VNFaceObservation.boundingBox (also normalised, BL)
//        -> full-image normalised point          // [0,1] over the whole image
//        -> flip Y to top-left origin            // for SwiftUI overlay
//
//  We deliberately do NOT use `pointsInImage(imageSize:)` here: composing the
//  bounding box by hand makes the "are these region-local or full-image points?"
//  question explicit, which is the exact thing we're trying to verify.
//

import Foundation
import Vision
import CoreVideo
import CoreGraphics

// MARK: - Orientation + mapping (single source, switchable on device)

enum VisionImageOrientation: String, CaseIterable, Sendable {
    case leftMirrored, rightMirrored, up, down
    var cg: CGImagePropertyOrientation {
        switch self {
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        case .up: return .up
        case .down: return .down
        }
    }
    static let initial: VisionImageOrientation = .leftMirrored
}

/// X/Y flip applied to normalised points before drawing.
enum MappingMode: String, CaseIterable, Sendable {
    case normal, flipX, flipY, flipXY
}

/// How the camera preview fills the view — must match for the overlay to align.
enum PreviewMapping: String, CaseIterable, Sendable {
    case aspectFill, aspectFit
}

// MARK: - Stage 1: pupil detection (swappable)

/// All landmark geometry for one face, in FULL-IMAGE normalised coordinates with
/// a TOP-LEFT origin (ready for a SwiftUI overlay). Pupil centres are the
/// centroids of the pupil landmark points (or eye contour on fallback).
struct PupilDetectionResult {
    let imageSize: CGSize
    let boundingBox: CGRect
    let leftEyeContour: [CGPoint]
    let rightEyeContour: [CGPoint]
    let leftPupilPoints: [CGPoint]
    let rightPupilPoints: [CGPoint]
    let leftPupilCentre: CGPoint?
    let rightPupilCentre: CGPoint?
    let usedFallback: Bool
}

protocol PupilDetector {
    func detectPupils(pixelBuffer: CVPixelBuffer,
                      orientation: CGImagePropertyOrientation,
                      completion: @escaping (PupilDetectionResult?) -> Void)
}

final class VisionPupilDetector: PupilDetector {

    private let queue = DispatchQueue(label: "com.sarili.vision.pupil", qos: .userInitiated)

    func detectPupils(pixelBuffer: CVPixelBuffer,
                      orientation: CGImagePropertyOrientation,
                      completion: @escaping (PupilDetectionResult?) -> Void) {
        queue.async {
            let request = VNDetectFaceLandmarksRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                orientation: orientation,
                                                options: [:])
            do { try handler.perform([request]) } catch { completion(nil); return }

            guard let face = (request.results as? [VNFaceObservation])?.first,
                  let landmarks = face.landmarks else {
                completion(nil)
                return
            }

            // Oriented image size (dims swap for 90° rotations).
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            let rotated: [CGImagePropertyOrientation] = [.left, .right, .leftMirrored, .rightMirrored]
            let imageSize = rotated.contains(orientation)
                ? CGSize(width: h, height: w)
                : CGSize(width: w, height: h)

            // EXPLICIT coordinate composition: region-local (inside bbox, BL) ->
            // full-image normalised (BL) -> top-left origin.
            let bbox = face.boundingBox   // full-image normalised, bottom-left
            func toFullTopLeft(_ np: CGPoint) -> CGPoint {
                let fx = bbox.origin.x + np.x * bbox.size.width
                let fyBottomLeft = bbox.origin.y + np.y * bbox.size.height
                return CGPoint(x: fx, y: 1 - fyBottomLeft)
            }
            func region(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint] {
                (r?.normalizedPoints ?? []).map(toFullTopLeft)
            }
            func centroid(_ pts: [CGPoint]) -> CGPoint? {
                guard !pts.isEmpty else { return nil }
                let s = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
                return CGPoint(x: s.x / CGFloat(pts.count), y: s.y / CGFloat(pts.count))
            }

            let leftEye = region(landmarks.leftEye)
            let rightEye = region(landmarks.rightEye)
            let leftPupilPts = region(landmarks.leftPupil)
            let rightPupilPts = region(landmarks.rightPupil)

            var usedFallback = false
            var leftCentre = centroid(leftPupilPts)
            var rightCentre = centroid(rightPupilPts)
            if leftCentre == nil || rightCentre == nil {
                leftCentre = centroid(leftEye)
                rightCentre = centroid(rightEye)
                usedFallback = true
                print("[Sarili] Vision pupil landmarks unavailable — using eye-region fallback")
            }

            // Bounding box to top-left origin for the overlay.
            let bboxTL = CGRect(x: bbox.origin.x,
                                y: 1 - bbox.origin.y - bbox.size.height,
                                width: bbox.size.width,
                                height: bbox.size.height)

            completion(PupilDetectionResult(
                imageSize: imageSize,
                boundingBox: bboxTL,
                leftEyeContour: leftEye,
                rightEyeContour: rightEye,
                leftPupilPoints: leftPupilPts,
                rightPupilPoints: rightPupilPts,
                leftPupilCentre: leftCentre,
                rightPupilCentre: rightCentre,
                usedFallback: usedFallback
            ))
        }
    }
}

// MARK: - Stage 3: pixels -> mm

struct VisionPDResult {
    let pdMM: Float?
    let pixelDistance: Float?
    let detection: PupilDetectionResult
}

struct VisionPDPipeline {
    var detector: PupilDetector

    func process(pixelBuffer: CVPixelBuffer,
                 fx: Float,
                 depthMetres: Float,
                 orientation: CGImagePropertyOrientation,
                 completion: @escaping (VisionPDResult?) -> Void) {
        detector.detectPupils(pixelBuffer: pixelBuffer, orientation: orientation) { det in
            guard let det else { completion(nil); return }
            if let lc = det.leftPupilCentre, let rc = det.rightPupilCentre, fx > 0 {
                let dxPx = Float(lc.x - rc.x) * Float(det.imageSize.width)
                let dyPx = Float(lc.y - rc.y) * Float(det.imageSize.height)
                let pixelDistance = (dxPx * dxPx + dyPx * dyPx).squareRoot()
                let pdMM = pixelDistance * depthMetres / fx * 1000
                completion(VisionPDResult(pdMM: pdMM, pixelDistance: pixelDistance, detection: det))
            } else {
                completion(VisionPDResult(pdMM: nil, pixelDistance: nil, detection: det))
            }
        }
    }
}

// MARK: - Stage 4: display bundle

/// Landmark geometry for the overlay (full-image normalised, top-left origin).
struct VisionLandmarks: Sendable {
    let boundingBox: CGRect
    let leftEyeContour: [CGPoint]
    let rightEyeContour: [CGPoint]
    let leftPupilPoints: [CGPoint]
    let rightPupilPoints: [CGPoint]
    let leftPupilCentre: CGPoint?
    let rightPupilCentre: CGPoint?
}

struct VisionDebugInfo: Sendable {
    let pdMM: Float?
    let pixelDistance: Float?
    let depthMetres: Float
    let fx: Float
    let fy: Float
    let yaw: Float
    let pitch: Float
    let roll: Float
    let trackingState: String
    let frameVarianceMM: Float
    let orientationName: String
    let detectorMode: String          // "pupil landmarks" / "fallback eye region" / "unavailable"
    let coordinateConfidence: String  // "OK" / "needs checking"
    let imageSize: CGSize?
    let landmarks: VisionLandmarks?
}
