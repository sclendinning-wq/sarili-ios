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
//  Stage 1 is behind the `PupilDetector` protocol so the Vision landmark
//  detector can later be swapped for a custom iris detector without touching
//  the conversion / display stages.
//

import Foundation
import Vision
import CoreVideo
import CoreGraphics

// MARK: - Stage 1: pupil detection (swappable)

/// Pupil centres in image pixel coordinates, plus whether a fallback was used.
struct PupilDetectionResult {
    let left: CGPoint
    let right: CGPoint
    let usedFallback: Bool      // true when eye-region centroid stood in for pupils
}

/// Swap-in point: any pupil detector (Vision landmarks today, a custom iris
/// detector later) just needs to return two pupil pixel positions.
protocol PupilDetector {
    func detectPupils(pixelBuffer: CVPixelBuffer,
                      orientation: CGImagePropertyOrientation,
                      completion: @escaping (PupilDetectionResult?) -> Void)
}

/// Vision-based pupil detector. Prefers `leftPupil`/`rightPupil`; if those are
/// unavailable, falls back to the eye-region centroid and flags it.
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
            do {
                try handler.perform([request])
            } catch {
                completion(nil)
                return
            }

            guard let face = (request.results as? [VNFaceObservation])?.first,
                  let landmarks = face.landmarks else {
                completion(nil)
                return
            }

            // Image size in the oriented space Vision used (dims swap for 90°
            // rotations) so pointsInImage maps onto the right pixel grid.
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            let rotated: [CGImagePropertyOrientation] = [.left, .right, .leftMirrored, .rightMirrored]
            let imageSize = rotated.contains(orientation)
                ? CGSize(width: h, height: w)
                : CGSize(width: w, height: h)

            // Centre of a landmark region = centroid of its image points.
            func centre(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
                guard let region, region.pointCount > 0 else { return nil }
                let pts = region.pointsInImage(imageSize: imageSize)
                let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
                return CGPoint(x: sum.x / CGFloat(pts.count), y: sum.y / CGFloat(pts.count))
            }

            if let l = centre(landmarks.leftPupil), let r = centre(landmarks.rightPupil) {
                completion(PupilDetectionResult(left: l, right: r, usedFallback: false))
            } else if let l = centre(landmarks.leftEye), let r = centre(landmarks.rightEye) {
                print("[Sarili] Vision pupil landmarks unavailable — using eye-region fallback")
                completion(PupilDetectionResult(left: l, right: r, usedFallback: true))
            } else {
                completion(nil)
            }
        }
    }
}

// MARK: - Stage 3: pixels -> mm

/// Output of the conversion stage (stage 4 then displays it).
struct VisionPDResult {
    let pdMM: Float
    let pixelDistance: Float
    let usedFallback: Bool
}

/// Owns the swappable detector and turns pupil pixels into a PD in mm using the
/// camera focal length and a caller-provided depth (stage 2).
///
///     PD_mm = pixelDistance * depth / fx * 1000
struct VisionPDPipeline {
    var detector: PupilDetector
    var orientation: CGImagePropertyOrientation = .leftMirrored

    func process(pixelBuffer: CVPixelBuffer,
                 fx: Float,
                 depthMetres: Float,
                 completion: @escaping (VisionPDResult?) -> Void) {
        detector.detectPupils(pixelBuffer: pixelBuffer, orientation: orientation) { pupils in
            guard let pupils, fx > 0 else { completion(nil); return }
            let pixelDistance = Float(hypot(pupils.left.x - pupils.right.x,
                                            pupils.left.y - pupils.right.y))
            let pdMM = pixelDistance * depthMetres / fx * 1000
            completion(VisionPDResult(pdMM: pdMM,
                                      pixelDistance: pixelDistance,
                                      usedFallback: pupils.usedFallback))
        }
    }
}

// MARK: - Stage 4: display bundle

/// Everything the on-screen test-harness readout needs for one frame.
struct VisionDebugInfo: Sendable {
    let pdMM: Float?
    let pixelDistance: Float?
    let depthMetres: Float
    let fx: Float
    let usedFallback: Bool
    let yaw: Float
    let pitch: Float
    let roll: Float
    let trackingState: String
    let frameVarianceMM: Float
}
