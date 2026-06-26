//
//  VisionPupilDetector.swift
//  SariliScan
//
//  Detects pupil centres directly from the ARKit camera image with the Vision
//  framework (VNDetectFaceLandmarksRequest), then converts the pupil pixel
//  separation to millimetres using the camera focal length AND the ARKit face
//  depth: PD_mm = pixelDistance * depth / focalLengthPx * 1000.
//
//  Caveats (need on-device verification — cannot be validated without hardware):
//  - `orientation` for ARKit's capturedImage is device/orientation dependent.
//    If pupils aren't found or PD is wildly off, try the other cases.
//  - Vision's pupil landmark is an approximate image estimate, not a clinical
//    pupil centre; treat the result as one comparison candidate, not truth.
//

import Foundation
import Vision
import CoreVideo
import CoreGraphics

final class VisionPupilDetector {

    /// Orientation of ARKit's `capturedImage` passed to Vision. LIKELY needs
    /// on-device tuning. Front camera + portrait is commonly `.leftMirrored`;
    /// if detection fails or PD is wrong try `.right`, `.rightMirrored`, `.up`.
    var orientation: CGImagePropertyOrientation = .leftMirrored

    private let queue = DispatchQueue(label: "com.sarili.vision.pupil", qos: .userInitiated)

    /// Runs asynchronously on a background queue. `completion` is called on that
    /// background queue with the PD in mm (or nil); the caller hops to main.
    func detectPD(pixelBuffer: CVPixelBuffer,
                  focalLengthPx: Float,
                  depthMetres: Float,
                  completion: @escaping (Float?) -> Void) {
        let orientation = self.orientation
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
                  let landmarks = face.landmarks,
                  let leftPupil = landmarks.leftPupil,
                  let rightPupil = landmarks.rightPupil else {
                completion(nil)
                return
            }

            // Image size in the oriented space Vision worked in (dims swap for
            // 90° rotations) so pointsInImage maps to the right pixel grid.
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            let rotated: [CGImagePropertyOrientation] = [.left, .right, .leftMirrored, .rightMirrored]
            let imageSize = rotated.contains(orientation)
                ? CGSize(width: h, height: w)
                : CGSize(width: w, height: h)

            guard let lp = leftPupil.pointsInImage(imageSize: imageSize).first,
                  let rp = rightPupil.pointsInImage(imageSize: imageSize).first else {
                completion(nil)
                return
            }

            let pixelDist = Float(hypot(lp.x - rp.x, lp.y - rp.y))
            guard focalLengthPx > 0 else { completion(nil); return }
            let pdMetres = pixelDist * depthMetres / focalLengthPx
            completion(pdMetres * 1000)
        }
    }
}
