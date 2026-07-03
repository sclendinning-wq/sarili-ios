//
//  CardPDView.swift
//  SariliScan
//
//  Milestone 6 — card-reference PD TEST HARNESS (not a final medical feature).
//  Proves the card-scale math with MANUAL taps before any automation:
//
//      mm_per_pixel = 85.6 / card_pixel_width
//      PD_mm        = pupil_pixel_distance * mm_per_pixel
//
//  All taps, drawing, and distances live in the displayed image's view-point
//  space. Because PD is a ratio (card and pupils measured in the same units),
//  the unit cancels and PD_mm is correct without image-pixel remapping.
//
//  Separate from the ARKit face scan (face width / bridge / proportions / fit).
//  No automatic pupil detection, prescription, checkout, or recommendations.
//

import SwiftUI
import AVFoundation

// MARK: - Camera (still capture)

// Not ObservableObject: nothing here is observed by SwiftUI (no @Published),
// and under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor the synthesized
// objectWillChange fails the protocol's nonisolated requirement.
final class CardCameraController: NSObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "com.sarili.cardpd.camera")
    private var onCaptured: ((UIImage?) -> Void)?

    func configureAndStart() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            self.queue.async {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                   let input = try? AVCaptureDeviceInput(device: device),
                   self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
                if self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                }
                self.session.commitConfiguration()
                self.session.startRunning()
            }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func capture(_ completion: @escaping (UIImage?) -> Void) {
        onCaptured = completion
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        DispatchQueue.main.async { self.onCaptured?(image) }
    }
}

struct CardCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - Card PD harness

struct CardPDView: View {
    var onClose: () -> Void = {}

    // @State (not @StateObject): keeps one stable instance across renders; the
    // view never observes the controller, it only calls into it.
    @State private var camera = CardCameraController()
    @State private var capturedImage: UIImage?

    @State private var cardLeft: CGPoint?
    @State private var cardRight: CGPoint?
    @State private var pupilLeft: CGPoint?
    @State private var pupilRight: CGPoint?
    @State private var step: TapStep = .cardLeft

    private let cardWidthMM: CGFloat = 85.6   // standard credit-card width

    enum TapStep: Int { case cardLeft, cardRight, pupilLeft, pupilRight, done }

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
                        capturedImage = img
                        resetTaps()
                    }
                } label: {
                    Text("Capture")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                }
            }
            .padding(20)
        }
    }

    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Card PD — test harness").font(.headline)
            Text("Remove glasses. Look straight at the camera.\nHold a credit-card-sized card horizontally under your nose, touching your face. Keep it flat and visible.")
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
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)

                overlayCanvas

                VStack {
                    Spacer()
                    readout
                    controls
                }
                .padding(16)
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { handleTap($0.location) })
        }
    }

    private var overlayCanvas: some View {
        Canvas { ctx, _ in
            func dot(_ p: CGPoint, _ color: Color) {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)),
                         with: .color(color))
            }
            func link(_ a: CGPoint, _ b: CGPoint, _ color: Color) {
                var path = Path(); path.move(to: a); path.addLine(to: b)
                ctx.stroke(path, with: .color(color), lineWidth: 2)
            }
            if let l = cardLeft, let r = cardRight { link(l, r, .yellow) }
            if let l = pupilLeft, let r = pupilRight { link(l, r, .cyan) }
            if let p = cardLeft { dot(p, .yellow) }
            if let p = cardRight { dot(p, .yellow) }
            if let p = pupilLeft { dot(p, .red) }
            if let p = pupilRight { dot(p, .red) }
        }
        .allowsHitTesting(false)
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Card pixel width:     \(fmtPx(cardPixelWidth))")
            Text("Card scale:           \(cardScale.map { String(format: "%.3fmm/px", $0) } ?? "n/a")")
            Text("Pupil pixel distance: \(fmtPx(pupilPixelDistance))")
            Text("Calculated PD:        \(pdMM.map { String(format: "%.1fmm", $0) } ?? "n/a")")
            Text("Card angle:           \(cardAngle.map { String(format: "%.0f°", $0) } ?? "n/a")")
            Text("Image captured:       \(capturedImage == nil ? "no" : "yes")")
            Text("Mode:                 manual tap test harness")
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.green)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
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

    // MARK: Tap handling

    private var stepPrompt: String {
        switch step {
        case .cardLeft:   return "Tap the LEFT edge of the card"
        case .cardRight:  return "Tap the RIGHT edge of the card"
        case .pupilLeft:  return "Tap the LEFT pupil centre"
        case .pupilRight: return "Tap the RIGHT pupil centre"
        case .done:       return "Done — PD calculated. Reset taps to redo."
        }
    }

    private func handleTap(_ location: CGPoint) {
        switch step {
        case .cardLeft:   cardLeft = location;   step = .cardRight
        case .cardRight:  cardRight = location;  step = .pupilLeft
        case .pupilLeft:  pupilLeft = location;  step = .pupilRight
        case .pupilRight: pupilRight = location; step = .done
        case .done:       break
        }
    }

    private func resetTaps() {
        cardLeft = nil; cardRight = nil; pupilLeft = nil; pupilRight = nil
        step = .cardLeft
    }

    // MARK: Math

    private var cardPixelWidth: CGFloat? {
        guard let l = cardLeft, let r = cardRight else { return nil }
        return hypot(l.x - r.x, l.y - r.y)
    }
    private var cardScale: CGFloat? {   // mm per pixel
        guard let w = cardPixelWidth, w > 0 else { return nil }
        return cardWidthMM / w
    }
    private var pupilPixelDistance: CGFloat? {
        guard let l = pupilLeft, let r = pupilRight else { return nil }
        return hypot(l.x - r.x, l.y - r.y)
    }
    private var pdMM: CGFloat? {
        guard let scale = cardScale, let d = pupilPixelDistance else { return nil }
        return d * scale
    }
    private var cardAngle: CGFloat? {   // degrees from horizontal
        guard let l = cardLeft, let r = cardRight else { return nil }
        return abs(atan2(r.y - l.y, r.x - l.x) * 180 / .pi)
    }

    private func fmtPx(_ v: CGFloat?) -> String {
        v.map { String(format: "%.0fpx", $0) } ?? "n/a"
    }
}

#Preview {
    CardPDView()
}
