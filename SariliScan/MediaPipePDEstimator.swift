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
//  The frame is rotated/mirrored upright and converted to BGRA *before* it
//  reaches MediaPipe, so the landmarks come back in the same upright image
//  space they are measured and drawn in. Passing an orientation flag to
//  MPImage instead was observed on device to return landmarks in the
//  UNROTATED buffer's coordinate space, which stretched pixel distances by
//  the sensor aspect ratio (PD read 4/3 too high) and misplaced the overlay
//  dots. The overlay dots remain the visual trust check.
//

import Foundation
import CoreVideo
import CoreGraphics
import CoreImage
import ImageIO
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
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// ARKit's `capturedImage` is a YCbCr landscape buffer; MediaPipe needs
    /// 32BGRA and (to keep every coordinate space identical) an already-upright
    /// image. Applies the same leftMirrored orientation the Vision path uses,
    /// then renders to a fresh BGRA buffer. A per-frame copy, but MediaPipe
    /// already runs throttled to one in-flight frame at a time.
    private func orientedBGRABuffer(from pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let oriented = CIImage(cvPixelBuffer: pixelBuffer).oriented(.leftMirrored)
        let width = Int(oriented.extent.width)
        let height = Int(oriented.extent.height)
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var bgraBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_32BGRA,
                                          attrs as CFDictionary,
                                          &bgraBuffer)
        guard status == kCVReturnSuccess, let output = bgraBuffer else { return nil }
        ciContext.render(oriented, to: output)
        return output
    }

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

            // Pixels are made upright + mirrored here, so MediaPipe gets .up and
            // its landmarks are guaranteed to be in this oriented image space.
            guard let orientedBuffer = self.orientedBGRABuffer(from: pixelBuffer) else {
                fail("pixel conversion failed"); return
            }

            let result: FaceLandmarkerResult
            do {
                let mpImage = try MPImage(pixelBuffer: orientedBuffer, orientation: .up)
                result = try landmarker.detect(image: mpImage)
            } catch {
                fail("detect error: \(error.localizedDescription)"); return
            }

            guard let face = result.faceLandmarks.first,
                  face.count > MediaPipePDEstimator.rightIrisCentre else {
                fail("no face"); return
            }

            // Landmarks are normalised against the oriented buffer itself.
            let imageW = CGFloat(CVPixelBufferGetWidth(orientedBuffer))
            let imageH = CGFloat(CVPixelBufferGetHeight(orientedBuffer))

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
