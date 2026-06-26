//
//  EyelidIndexDetector.swift
//  SariliScan
//
//  DEBUG / calibration tool. Detects the eyelid mesh-vertex indices by watching
//  which vertices move (in face-local space) while the eye-blink blend shapes
//  are high, then splitting that moving region into left/right by proximity to
//  each eye's transform. Run once with a few blinks, read off / copy the indices,
//  lock them into EyeLandmarks.swift.
//
//  Notes / limitations:
//  - A normal blink fires eyeBlinkLeft AND eyeBlinkRight together, so sides are
//    separated by vertex position, not by which coefficient fired.
//  - Thresholds below are best-effort and will likely need on-device tuning.
//

import Foundation
import simd

final class EyelidIndexDetector {

    enum Phase: Equatable { case idle, collecting, done }
    private(set) var phase: Phase = .idle

    // Tunables — expect to adjust these on device.
    private let neutralBlinkMax: Float = 0.15     // "eyes open"
    private let blinkHighThreshold: Float = 0.6   // "blinking"
    private let requiredBlinkEvents = 3
    private let selectionFraction: Float = 0.45   // keep vertices >= 45% of peak motion
    private let maxPerEye = 12

    private var baseline: [SIMD3<Float>] = []     // EMA of neutral (open-eye) positions
    private var hasBaseline = false
    private var peakDisplacement: [Float] = []    // per-vertex max motion during blinks
    private var blinkEvents = 0
    private var wasBlinking = false

    func start(vertexCount: Int) {
        baseline = Array(repeating: .zero, count: vertexCount)
        peakDisplacement = Array(repeating: 0, count: vertexCount)
        hasBaseline = false
        blinkEvents = 0
        wasBlinking = false
        phase = .collecting
    }

    /// Feed one frame. `blink` is max(blinkLeft, blinkRight). `leftEyeX`/`rightEyeX`
    /// are the eye-transform x positions in face-local space (for the L/R split).
    /// Returns detected (left,right) indices once enough blinks are seen, else nil.
    func ingest(vertices: [SIMD3<Float>],
                leftEyeX: Float,
                rightEyeX: Float,
                blink: Float) -> (left: [Int], right: [Int])? {
        guard phase == .collecting, vertices.count == baseline.count else { return nil }

        if blink < neutralBlinkMax {
            // Track the open-eye baseline.
            if hasBaseline {
                for i in vertices.indices {
                    baseline[i] = baseline[i] * 0.8 + vertices[i] * 0.2
                }
            } else {
                baseline = vertices
                hasBaseline = true
            }
        } else if blink > blinkHighThreshold, hasBaseline {
            // Record how far each vertex moves from neutral during the blink.
            for i in vertices.indices {
                let d = simd_distance(vertices[i], baseline[i])
                if d > peakDisplacement[i] { peakDisplacement[i] = d }
            }
        }

        // Count blink rising edges.
        if blink > blinkHighThreshold, !wasBlinking {
            wasBlinking = true
            blinkEvents += 1
        } else if blink < neutralBlinkMax {
            wasBlinking = false
        }

        if blinkEvents >= requiredBlinkEvents, hasBaseline {
            return finalize(vertices: vertices, leftEyeX: leftEyeX, rightEyeX: rightEyeX)
        }
        return nil
    }

    private func finalize(vertices: [SIMD3<Float>],
                          leftEyeX: Float,
                          rightEyeX: Float) -> (left: [Int], right: [Int]) {
        phase = .done

        let peak = peakDisplacement.max() ?? 0
        guard peak > 0 else { return ([], []) }
        let threshold = peak * selectionFraction

        // Vertices that moved enough to be eyelid candidates.
        let candidates = vertices.indices.filter { peakDisplacement[$0] >= threshold }

        // Split candidates by proximity of x to each eye transform.
        var left: [Int] = []
        var right: [Int] = []
        for i in candidates {
            let x = vertices[i].x
            if abs(x - leftEyeX) <= abs(x - rightEyeX) { left.append(i) } else { right.append(i) }
        }

        // Keep the strongest movers per eye, returned sorted ascending.
        func cap(_ ids: [Int]) -> [Int] {
            Array(ids.sorted { peakDisplacement[$0] > peakDisplacement[$1] }.prefix(maxPerEye)).sorted()
        }
        return (cap(left), cap(right))
    }
}
