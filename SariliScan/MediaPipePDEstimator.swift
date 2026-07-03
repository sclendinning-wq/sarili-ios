//
//  MediaPipePDEstimator.swift
//  SariliScan
//
//  Milestone 8 — MediaPipe FaceLandmarker iris landmarks + TrueDepth depth.
//
//  Why: ARKit eye-transform PD is precise but carries a PER-PERSON bias
//  (two faces with identical clinical PD read 2.3mm apart), and Apple Vision's
//  pupil landmark was shown on device not to lock onto the pupils. MediaPipe's
//  face landmarker has true iris landmarks (indices 468-477; 468/473 are the
//  iris centres) — it measures the actual pupils in the image. Scale comes
//  from TrueDepth: PD_mm = pupil_pixel_distance * depth / focalLength * 1000.
//
//  Pixel distances are rotation/mirror invariant and fx == fy on this camera,
//  so the orientation only needs to be right for DETECTION to succeed; it
//  cannot bias the PD. The overlay dots remain the visual trust check.
//

import Foundation
import CoreVideo
import CoreGraphics
import UIKit
import MediaPipeTasksVision

/// Per-frame result handed back to the UI.
struct MediaPipeDebugInfo: Sendable {
    let pdMM: Float?
    let pixelDistance: Float?
    let leftIrisNorm: CGPoint?    // top-left normalised, oriented image space
    let rightIrisNorm: CGPoint?
    let status: String            // "ok" / "no face" / "model missing" / error text
}

final class MediaPipePDEstimator {

    // MediaPipe face landmarker iris indices (478-point topology).
    private static let leftIrisCentre = 468
    private static let rightIrisCentre = 473

    private let queue = DispatchQueue(label: "com.sarili.mediapipe.pd", qos: .userInitiated)
    private var landmarker: FaceLandmarker?
    private var initFailed = false

    /// Lazily builds the landmarker on first use (model load is not cheap).
    private func ensureLandmarker() -> FaceLandmarker? {
        if let landmarker { return landmarker }
        guard !initFailed else { return nil }
        guard let modelPath = Bundle.main.path(forResource: "face_landmarker", ofType: "task") else {
            initFailed = true
            return nil
        }
        do {
            let options = FaceLandmarkerOptions()
            options.baseOptions.modelAssetPath = modelPath
            options.runningMode = .image
            options.numFaces = 1
            landmarker = try FaceLandmarker(options: options)
            return landmarker
        } catch {
            print("[Sarili] MediaPipe init failed: \(error)")
            initFailed = true
            return nil
        }
    }

    /// Detects iris centres and converts their pixel separation to mm using the
    /// caller-supplied depth (metres) and focal length (pixels). Completion is
    /// invoked on the internal queue; callers hop to main.
    func estimatePD(pixelBuffer: CVPixelBuffer,
                    focalLengthPx: Float,
                    depthMetres: Float,
                    completion: @escaping (MediaPipeDebugInfo) -> Void) {
        queue.async { [weak self] in
            func fail(_ status: String) {
                completion(MediaPipeDebugInfo(pdMM: nil, pixelDistance: nil,
                                              leftIrisNorm: nil, rightIrisNorm: nil,
                                              status: status))
            }
            guard let self, let landmarker = self.ensureLandmarker() else {
                fail("model missing"); return
            }

            // Front camera, portrait: same orientation Vision detects with.
            let orientation = UIImage.Orientation.leftMirrored

            let result: FaceLandmarkerResult
            do {
                let mpImage = try MPImage(pixelBuffer: pixelBuffer, orientation: orientation)
                result = try landmarker.detect(image: mpImage)
            } catch {
                fail("detect error: \(error.localizedDescription)"); return
            }

            guard let face = result.faceLandmarks.first,
                  face.count > MediaPipePDEstimator.rightIrisCentre else {
                fail("no face"); return
            }

            // Oriented image dimensions (90° rotations swap width/height).
            let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
            let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
            let rotated = [UIImage.Orientation.left, .right, .leftMirrored, .rightMirrored]
                .contains(orientation)
            let imageW = rotated ? h : w
            let imageH = rotated ? w : h

            let l = face[MediaPipePDEstimator.leftIrisCentre]
            let r = face[MediaPipePDEstimator.rightIrisCentre]
            let lPx = CGPoint(x: CGFloat(l.x) * imageW, y: CGFloat(l.y) * imageH)
            let rPx = CGPoint(x: CGFloat(r.x) * imageW, y: CGFloat(r.y) * imageH)
            let pixelDistance = Float(hypot(lPx.x - rPx.x, lPx.y - rPx.y))

            guard focalLengthPx > 0 else { fail("bad intrinsics"); return }
            let pdMM = pixelDistance * depthMetres / focalLengthPx * 1000

            completion(MediaPipeDebugInfo(
                pdMM: pdMM,
                pixelDistance: pixelDistance,
                leftIrisNorm: CGPoint(x: CGFloat(l.x), y: CGFloat(l.y)),
                rightIrisNorm: CGPoint(x: CGFloat(r.x), y: CGFloat(r.y)),
                status: "ok"))
        }
    }
}
