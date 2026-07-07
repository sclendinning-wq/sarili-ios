//
//  SkinToneView.swift
//  SariliScan
//
//  Milestone 12 — skin-tone classification TEST HARNESS (not a shipping
//  feature). Goal: a COARSE, repeatable skin-tone read (lightness category +
//  warm/cool undertone) usable for eyewear colour recommendations — not exact
//  colour matching, which phone camera processing makes unreliable.
//
//  The core problem is auto white balance: the camera silently recolours every
//  photo to suit the scene, so raw pixel colour is not comparable across
//  shots. The harness solves it the same way milestone 6 solved scale with a
//  credit card: a PHYSICAL REFERENCE IN FRAME. The user holds a plain WHITE
//  card/paper next to their face and taps it first; every skin sample is then
//  white-balanced against that reference (von Kries scaling), which cancels
//  the camera's colour cast to first order. No reference, no reading.
//
//  Measurement chain per patch (all standard colourimetry, not fitted):
//      sRGB tap sample (averaged over a patch)
//        → linearise → white-balance against the reference
//        → CIE XYZ (D65) → CIELAB
//        → ITA° = atan((L* − 50) / b*)   [Individual Typology Angle]
//  ITA is the standard dermatology metric for skin tone; the category bands
//  in `itaCategory` are published literature values (Chardon/Del Bino), NOT
//  fitted here — but the whole phone-camera pipeline feeding them is
//  UNVALIDATED until compared against known references on device (e.g. a
//  makeup-foundation shade card, or two people with clearly different skin
//  tone photographed in the same light).
//
//  The undertone (warm/cool) split from the Lab hue angle is an EMPIRICAL
//  heuristic with a starting threshold — flagged inline, tune on device.
//
//  Reuses CardCameraController (front-camera still capture) from the card-PD
//  harness. The captured image is redrawn upright ONCE at capture, so display,
//  tap, and pixel-sampling coordinates are a single space (milestone 8 lesson:
//  one authoritative coordinate space, transforms applied in one place).
//

import SwiftUI
import UIKit
import CoreGraphics

// MARK: - Colour math (standard sRGB/D65 colourimetry — published constants)

enum SkinToneMath {

    struct Lab: Sendable {
        let L: Double
        let a: Double
        let b: Double

        /// Individual Typology Angle, degrees — the literature formula
        /// atan((L*−50)/b*), NOT atan2: for b* ≤ 0 (only reachable with a
        /// non-neutral "white" reference) atan2 would jump into the 90–180°
        /// range and misread a mid tone as "very light"; plain atan stays in
        /// (−90°, 90°) like the published metric.
        var itaDegrees: Double {
            b == 0 ? (L >= 50 ? 90 : -90) : atan((L - 50) / b) * 180 / .pi
        }

        /// Lab hue angle, degrees (0° = +a* red axis, 90° = +b* yellow axis).
        var hueDegrees: Double { atan2(b, a) * 180 / .pi }
    }

    /// sRGB gamma → linear.
    static func linearise(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Von Kries white balance in linear RGB: scales each channel so the
    /// reference sample becomes neutral grey at its own luminance. Cancels
    /// the camera's colour cast to first order; needs a genuinely white/grey
    /// reference or it introduces a cast instead of removing one.
    static func whiteBalance(_ rgb: SIMD3<Double>, reference: SIMD3<Double>) -> SIMD3<Double>? {
        let minChannel = 0.02   // reference channel this dark = not a white card
        guard reference.x > minChannel, reference.y > minChannel, reference.z > minChannel else {
            return nil
        }
        let refLuma = 0.2126729 * reference.x + 0.7151522 * reference.y + 0.0721750 * reference.z
        return SIMD3(rgb.x * refLuma / reference.x,
                     rgb.y * refLuma / reference.y,
                     rgb.z * refLuma / reference.z)
    }

    /// Linear sRGB → CIELAB (D65). Standard matrices/white point, not fitted.
    static func lab(fromLinear rgb: SIMD3<Double>) -> Lab {
        let x = 0.4124564 * rgb.x + 0.3575761 * rgb.y + 0.1804375 * rgb.z
        let y = 0.2126729 * rgb.x + 0.7151522 * rgb.y + 0.0721750 * rgb.z
        let z = 0.0193339 * rgb.x + 0.1191920 * rgb.y + 0.9503041 * rgb.z
        // D65 reference white.
        let xn = 0.95047, yn = 1.0, zn = 1.08883
        func f(_ t: Double) -> Double {
            let d = 6.0 / 29.0
            return t > d * d * d ? cbrt(t) : t / (3 * d * d) + 4.0 / 29.0
        }
        let fx = f(x / xn), fy = f(y / yn), fz = f(z / zn)
        return Lab(L: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    /// Published ITA° bands (Chardon/Del Bino skin-tone literature). The BANDS
    /// are literature values; whether this phone pipeline lands skin in the
    /// right band is exactly what milestone 12 validation must check.
    static func itaCategory(_ ita: Double) -> String {
        switch ita {
        case 55...:      return "very light"
        case 41..<55:    return "light"
        case 28..<41:    return "intermediate"
        case 10..<28:    return "tan"
        case (-30)..<10: return "brown"
        default:         return "dark"
        }
    }

    /// EMPIRICAL undertone heuristic from the Lab hue angle: yellow-dominant
    /// skin reads warm, red-dominant reads cool. The 45°/55° split is a
    /// STARTING GUESS to tune on device against people whose undertone is
    /// known (e.g. from foundation matching) — not a validated threshold.
    static func undertone(hueDegrees h: Double) -> String {
        if h > 55 { return "warm?" }
        if h < 45 { return "cool?" }
        return "neutral?"
    }
}

// MARK: - Skin-tone harness view

struct SkinToneView: View {
    var onClose: () -> Void = {}

    enum TapStep: Int, CaseIterable {
        case whiteRef, forehead, cheek, jaw, done
    }

    struct PatchSample {
        let viewPoint: CGPoint      // for drawing the marker
        let rawRGB: SIMD3<Double>   // gamma sRGB 0–1, uncorrected (diagnostic)
        let lab: SkinToneMath.Lab?  // white-balanced; nil until reference exists
    }

    @State private var camera = CardCameraController()
    @State private var capturedImage: UIImage?    // redrawn upright at capture
    @State private var step: TapStep = .whiteRef
    @State private var whiteRef: PatchSample?
    @State private var patches: [TapStep: PatchSample] = [:]  // forehead/cheek/jaw
    @State private var status: String?

    private let skinSteps: [TapStep] = [.forehead, .cheek, .jaw]

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if let image = capturedImage {
                markupView(image)
            } else {
                captureView
            }

            topBar
        }
        .onAppear { camera.configureAndStart() }
        .onDisappear { camera.stop() }
    }

    // MARK: Capture stage

    private var captureView: some View {
        ZStack(alignment: .bottom) {
            CardCameraPreview(session: camera.session)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                instructionCard
                Button {
                    camera.capture { img in
                        // Bake the EXIF orientation into the bitmap once, so
                        // display space == pixel space for taps and sampling.
                        capturedImage = img.map(Self.normalizedUpright)
                        resetTaps()
                        status = img == nil ? "Capture failed — try again" : nil
                    }
                } label: {
                    Text("Capture")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                }
                if let status {
                    Text(status)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }
            .padding(20)
        }
    }

    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Skin tone — test harness (M12)").font(.headline)
            Text("Face soft, even light (no direct sun, no strong lamp to one side). Hold a plain WHITE card or paper next to your cheek — it is the colour reference; without it the camera's white balance makes readings incomparable. Remove glasses; keep hair off the forehead.")
                .font(.footnote)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Markup stage

    private func markupView(_ image: UIImage) -> some View {
        GeometryReader { geo in
            ZStack {
                // Tap gesture lives on the IMAGE, not the ZStack — on the
                // stack, taps landing on the readout/controls panels fall
                // through and get recorded as skin samples at whatever pixel
                // sits behind the panel.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { handleTap($0.location, in: geo.size, image: image) })

                overlayCanvas

                VStack {
                    Spacer()
                    readout
                    controls
                }
                .padding(16)
            }
        }
    }

    private var overlayCanvas: some View {
        Canvas { ctx, _ in
            func marker(_ p: CGPoint, _ color: Color) {
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)),
                           with: .color(color), lineWidth: 3)
            }
            if let w = whiteRef { marker(w.viewPoint, .white) }
            if let p = patches[.forehead] { marker(p.viewPoint, .yellow) }
            if let p = patches[.cheek] { marker(p.viewPoint, .orange) }
            if let p = patches[.jaw] { marker(p.viewPoint, .red) }
        }
        .allowsHitTesting(false)
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("— Skin tone (M12, unvalidated pipeline) —").foregroundStyle(.cyan)
            Text("White ref RGB:    \(whiteRef.map { rgbText($0.rawRGB) } ?? "n/a — tap it first")")
            patchLine("Forehead", .forehead)
            patchLine("Cheek", .cheek)
            patchLine("Jaw", .jaw)
            if let median = medianLab {
                Text("Median  L*/a*/b*: \(labText(median))")
                Text("Median  ITA°:     \(String(format: "%.0f°", median.itaDegrees))  → \(SkinToneMath.itaCategory(median.itaDegrees))")
                    .foregroundStyle(.yellow)
                Text("Undertone (hue \(String(format: "%.0f°", median.hueDegrees))): \(SkinToneMath.undertone(hueDegrees: median.hueDegrees))")
                    .foregroundStyle(.yellow)
            }
            if let status {
                Text(status).foregroundStyle(.orange)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.green)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }

    private func patchLine(_ name: String, _ key: TapStep) -> Text {
        let padded = name.padding(toLength: 8, withPad: " ", startingAt: 0)
        guard let p = patches[key] else { return Text("\(padded) Lab/ITA:  n/a") }
        guard let lab = p.lab else { return Text("\(padded) Lab/ITA:  no white ref") }
        return Text("\(padded) Lab/ITA:  \(labText(lab))  \(String(format: "%.0f°", lab.itaDegrees))")
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Text(stepPrompt)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.top, 8)
            HStack(spacing: 10) {
                Button("Reset taps") { resetTaps() }
                Button("Retake") { capturedImage = nil; resetTaps() }
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private var topBar: some View {
        HStack {
            Button { onClose() } label: {
                Label("Face scan", systemImage: "chevron.left")
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .tint(.white)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private var stepPrompt: String {
        switch step {
        case .whiteRef: return "Tap the WHITE reference card"
        case .forehead: return "Tap mid-FOREHEAD skin"
        case .cheek:    return "Tap CHEEK skin (not blush/shadow areas)"
        case .jaw:      return "Tap JAW skin"
        case .done:     return "Done — Reset taps to redo, or Retake"
        }
    }

    // MARK: Tap handling + sampling

    private func handleTap(_ location: CGPoint, in viewSize: CGSize, image: UIImage) {
        guard step != .done else { return }

        guard let rgb = Self.averagePatchRGB(image: image, viewPoint: location, viewSize: viewSize) else {
            status = "Couldn't sample there — tap inside the photo"
            return
        }
        status = nil

        if step == .whiteRef {
            whiteRef = PatchSample(viewPoint: location, rawRGB: rgb, lab: nil)
            // A believable white card should be bright and near-neutral; warn
            // (don't block — it's a harness) if it looks like something else.
            let maxC = max(rgb.x, max(rgb.y, rgb.z))
            let minC = min(rgb.x, min(rgb.y, rgb.z))
            if maxC < 0.35 {
                status = "White ref looks dark — more light, or retap"
            } else if maxC - minC > 0.25 {
                status = "White ref looks strongly coloured — is that the card?"
            }
        } else {
            patches[step] = PatchSample(viewPoint: location, rawRGB: rgb, lab: correctedLab(rgb))
        }
        advanceStep()
    }

    /// Linearise, white-balance against the reference, convert to Lab.
    private func correctedLab(_ rgb: SIMD3<Double>) -> SkinToneMath.Lab? {
        guard let ref = whiteRef?.rawRGB else { return nil }
        let linear = SIMD3(SkinToneMath.linearise(rgb.x),
                           SkinToneMath.linearise(rgb.y),
                           SkinToneMath.linearise(rgb.z))
        let refLinear = SIMD3(SkinToneMath.linearise(ref.x),
                              SkinToneMath.linearise(ref.y),
                              SkinToneMath.linearise(ref.z))
        guard let balanced = SkinToneMath.whiteBalance(linear, reference: refLinear) else { return nil }
        return SkinToneMath.lab(fromLinear: balanced)
    }

    /// Median-by-ITA of the sampled patches (median of 3 resists one bad tap,
    /// e.g. a shadowed jaw or a strand of hair on the forehead). Only defined
    /// once ALL patches are in — "median" of a partial set silently biases
    /// toward whichever patch happened to be tapped.
    private var medianLab: SkinToneMath.Lab? {
        let labs = skinSteps.compactMap { patches[$0]?.lab }
        guard labs.count == skinSteps.count else { return nil }
        return labs.sorted { $0.itaDegrees < $1.itaDegrees }[labs.count / 2]
    }

    private func advanceStep() {
        let order: [TapStep] = [.whiteRef, .forehead, .cheek, .jaw, .done]
        if let i = order.firstIndex(of: step), i + 1 < order.count {
            step = order[i + 1]
        }
    }

    private func resetTaps() {
        whiteRef = nil
        patches = [:]
        step = .whiteRef
        status = nil
    }

    private func rgbText(_ rgb: SIMD3<Double>) -> String {
        String(format: "%.2f / %.2f / %.2f", rgb.x, rgb.y, rgb.z)
    }

    private func labText(_ lab: SkinToneMath.Lab) -> String {
        String(format: "%.0f / %+.0f / %+.0f", lab.L, lab.a, lab.b)
    }

    // MARK: Static image helpers

    /// Redraws the image so EXIF orientation is baked into the bitmap —
    /// afterwards `cgImage` pixel coordinates match what's on screen and taps
    /// need no orientation transform (one authoritative coordinate space).
    static func normalizedUpright(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up { return image }
        // Explicit 1× scale: the renderer's default is the SCREEN scale (3×),
        // which would silently allocate a 9×-pixel bitmap of a 12MP photo
        // (hundreds of MB → jetsam risk) and interpolate the pixels sampled.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// Average sRGB (gamma, 0–1) over a small patch around a tap. The tap is
    /// in VIEW coordinates over a scaledToFit image; this maps through the
    /// letterboxing to image points, then samples an 8×8 downscale of a
    /// patch whose size scales with the photo resolution.
    static func averagePatchRGB(image: UIImage,
                                viewPoint: CGPoint,
                                viewSize: CGSize) -> SIMD3<Double>? {
        guard let cg = image.cgImage else { return nil }
        let imgW = image.size.width
        let imgH = image.size.height
        guard imgW > 0, imgH > 0, viewSize.width > 0, viewSize.height > 0 else { return nil }

        // View → image points (scaledToFit letterbox), then → pixels.
        let fit = min(viewSize.width / imgW, viewSize.height / imgH)
        let offX = (viewSize.width - imgW * fit) / 2
        let offY = (viewSize.height - imgH * fit) / 2
        let ix = (viewPoint.x - offX) / fit
        let iy = (viewPoint.y - offY) / fit
        guard ix >= 0, iy >= 0, ix < imgW, iy < imgH else { return nil }
        let pxScale = CGFloat(cg.width) / imgW
        let px = ix * pxScale
        let py = iy * pxScale

        // Patch ~2% of the photo's larger side: big enough to average out
        // sensor noise/pores, small enough to stay inside a cheek.
        let half = max(4, CGFloat(max(cg.width, cg.height)) * 0.01)
        let rect = CGRect(x: px - half, y: py - half, width: half * 2, height: half * 2)
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            .integral
        guard !rect.isEmpty, let cropped = cg.cropping(to: rect) else { return nil }

        // Downscale the patch to 8×8 and average those pixels — deterministic
        // mean regardless of the patch's original size.
        let side = 8
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }

        let p = data.assumingMemoryBound(to: UInt8.self)
        var r = 0.0, g = 0.0, b = 0.0
        for i in 0..<(side * side) {
            r += Double(p[i * 4])
            g += Double(p[i * 4 + 1])
            b += Double(p[i * 4 + 2])
        }
        let n = Double(side * side) * 255
        return SIMD3(r / n, g / n, b / n)
    }
}

#Preview {
    SkinToneView()
}
