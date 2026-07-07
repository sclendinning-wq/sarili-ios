//
//  ProfileCaptureView.swift
//  SariliScan
//
//  Milestone 11 — side-profile capture TEST HARNESS for ear position and
//  temple length. Front TrueDepth physically cannot see the ears in a frontal
//  scan, and ARKit face tracking loses the face once the head turns to
//  profile — so this uses RAW TrueDepth streaming (AVFoundation video+depth,
//  no ARKit) and manual taps, reusing the mm = pixel × depth / focal-length
//  math validated in milestone 8.
//
//  Flow: hold the phone upright (live tilt readout from CoreMotion), subject
//  turns to show one ear → Capture freezes a synchronized video+depth frame →
//  tap the outer eye corner, then the top of the ear junction → the harness
//  back-projects both taps through the depth map and camera intrinsics to 3D
//  camera-space points and reports the ear-to-eye distance, the screen-
//  vertical drop, and the screen-horizontal span. Capture each side
//  separately; both results stay on screen so real asymmetry can be told
//  apart from capture noise (repeat a side to gauge the noise).
//
//  Coordinate spaces (the milestone 8 lesson — ONE authoritative space):
//  ALL measurement math lives in the raw sensor buffer space (landscape).
//  Only the display image is rotated upright (.leftMirrored, same as the
//  validated milestone 8 path); taps are mapped back into raw space by the
//  inverse transform (a transpose) before touching depth or intrinsics.
//
//  UNVALIDATED until checked against physical ground truth (ruler from eye
//  corner to ear top, on a person, phone level) — including the sign of the
//  vertical drop and the tap→raw transpose, which the on-screen dots and a
//  known geometry (e.g. a ruler held in frame) can confirm on device.
//

import SwiftUI
import AVFoundation
import CoreImage
import CoreMotion
import UIKit
import simd

// MARK: - Captured frame

/// One frozen, synchronized video+depth frame plus the intrinsics needed to
/// back-project taps. Everything is in RAW sensor-buffer space except `image`.
/// @unchecked: CVPixelBuffer isn't Sendable, but this is an immutable snapshot
/// — the depth map is written once at capture and only ever read afterwards —
/// matching the project rule that per-frame data crosses threads as a value
/// snapshot (camera queue → main), never as a live reference.
struct ProfileCapture: @unchecked Sendable {
    let image: UIImage          // upright display image (transposed raw buffer)
    let videoWidth: Int         // raw video buffer dims (landscape sensor space)
    let videoHeight: Int
    let depthMap: CVPixelBuffer // Float32 depth in METRES, raw sensor orientation
    let depthWidth: Int
    let depthHeight: Int
    let fx: Float               // intrinsics in raw video-buffer pixel space
    let fy: Float
    let cx: Float
    let cy: Float
    let intrinsicsSource: String  // "frame attachment" / "calibration (scaled)" / "none"
}

// MARK: - Camera controller (raw TrueDepth streaming, no ARKit)

// Same non-ObservableObject pattern as CardCameraController: nothing here is
// observed by SwiftUI, callbacks hop to main explicitly.
final class ProfileCameraController: NSObject, AVCaptureDataOutputSynchronizerDelegate {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private let queue = DispatchQueue(label: "com.sarili.profile.camera")
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])
    private let motion = CMMotionManager()

    private var pendingCapture = false
    private var onCaptured: ((ProfileCapture?) -> Void)?

    // Stored, not computed: the SwiftUI body reads this every render and a
    // device-discovery query per render is wasted work.
    let hasTrueDepth: Bool =
        AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) != nil

    func configureAndStart() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            self.queue.async { self.configureSession() }
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        session.beginConfiguration()
        // 4:3 preset so the video and depth buffers share the same field of
        // view — a 16:9 preset crops video relative to the 4:3 depth map and
        // a plain scale between them would then be geometrically wrong.
        session.sessionPreset = .vga640x480
        if session.canAddInput(input) { session.addInput(input) }

        videoOutput.videoSettings =
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        if session.canAddOutput(depthOutput) { session.addOutput(depthOutput) }
        // Filtered depth fills holes by interpolation — smoother taps, but
        // remember values near edges are partly synthetic.
        depthOutput.isFilteringEnabled = true

        // Highest-RESOLUTION Float32 depth format (`first` would silently pick
        // the lowest-res one and halve measurement resolution); fall back to
        // the highest-res format of any type and convert at capture time
        // (the conversion handles disparity too).
        let formats = device.activeFormat.supportedDepthDataFormats
        func dims(_ f: AVCaptureDevice.Format) -> Int32 {
            CMVideoFormatDescriptionGetDimensions(f.formatDescription).width
        }
        let float32Formats = formats.filter {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
        }
        let depthFormat = (float32Formats.isEmpty ? formats : float32Formats)
            .max { dims($0) < dims($1) }
        if let depthFormat {
            try? device.lockForConfiguration()
            device.activeDepthDataFormat = depthFormat
            device.unlockForConfiguration()
        }

        // Per-frame intrinsics rider (fx/fy/cx/cy in raw buffer pixels) — the
        // same scale source the milestone 8 PD math validated.
        if let connection = videoOutput.connection(with: .video),
           connection.isCameraIntrinsicMatrixDeliverySupported {
            connection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }

        let sync = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
        sync.setDelegate(self, queue: queue)
        synchronizer = sync

        session.commitConfiguration()
        session.startRunning()
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    /// Requests that the next synchronized video+depth pair be frozen and
    /// handed back (on main) as a ProfileCapture. The completion is stored on
    /// the camera queue so the delegate callback never races the write.
    func capture(_ completion: @escaping (ProfileCapture?) -> Void) {
        queue.async {
            self.onCaptured = completion
            self.pendingCapture = true
        }
    }

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        guard pendingCapture,
              let videoData = synchronizedDataCollection.synchronizedData(for: videoOutput)
                  as? AVCaptureSynchronizedSampleBufferData,
              !videoData.sampleBufferWasDropped,
              let depthData = synchronizedDataCollection.synchronizedData(for: depthOutput)
                  as? AVCaptureSynchronizedDepthData,
              !depthData.depthDataWasDropped else { return }

        pendingCapture = false
        let capture = ProfileCameraController.process(sampleBuffer: videoData.sampleBuffer,
                                                      depthData: depthData.depthData,
                                                      ciContext: ciContext)
        // Snapshot the completion HERE on the camera queue (where capture()
        // writes it) so the main-thread hop never reads it cross-queue.
        let completion = onCaptured
        DispatchQueue.main.async { completion?(capture) }
    }

    private static func process(sampleBuffer: CMSampleBuffer,
                                depthData: AVDepthData,
                                ciContext: CIContext) -> ProfileCapture? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let videoW = CVPixelBufferGetWidth(pixelBuffer)
        let videoH = CVPixelBufferGetHeight(pixelBuffer)

        // Upright, mirrored display image — the same .leftMirrored orientation
        // milestone 8 validated for the front camera. Math stays in raw space;
        // only pixels for DISPLAY are rotated.
        let oriented = CIImage(cvPixelBuffer: pixelBuffer).oriented(.leftMirrored)
        guard let cgImage = ciContext.createCGImage(oriented, from: oriented.extent) else { return nil }
        let image = UIImage(cgImage: cgImage)

        // Depth (or disparity) → Float32 metres.
        let depth32 = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap = depth32.depthDataMap

        // Intrinsics: per-frame attachment first, depth calibration as backup.
        var fx: Float = 0, fy: Float = 0, cx: Float = 0, cy: Float = 0
        var source = "none"
        if let attachment = CMGetAttachment(sampleBuffer,
                                            key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                            attachmentModeOut: nil) as? Data {
            // loadUnaligned: matrix_float3x3 wants 16-byte alignment and the
            // CFData bytes aren't guaranteed to provide it.
            let m = attachment.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
            fx = m.columns.0.x; fy = m.columns.1.y
            cx = m.columns.2.x; cy = m.columns.2.y
            source = "frame attachment"
        } else if let calibration = depth32.cameraCalibrationData {
            let m = calibration.intrinsicMatrix
            let ref = calibration.intrinsicMatrixReferenceDimensions
            if ref.width > 0 {
                let scale = Float(videoW) / Float(ref.width)
                fx = m.columns.0.x * scale; fy = m.columns.1.y * scale
                cx = m.columns.2.x * scale; cy = m.columns.2.y * scale
                source = "calibration (scaled)"
            }
        }

        return ProfileCapture(image: image,
                              videoWidth: videoW, videoHeight: videoH,
                              depthMap: depthMap,
                              depthWidth: CVPixelBufferGetWidth(depthMap),
                              depthHeight: CVPixelBufferGetHeight(depthMap),
                              fx: fx, fy: fy, cx: cx, cy: cy,
                              intrinsicsSource: source)
    }

    // MARK: Phone-level check (CoreMotion)

    /// Reports the phone's tilt from portrait-upright, in degrees, on main.
    /// Pitch of the HEAD isn't knowable here (no ARKit face anchor in profile);
    /// keeping the PHONE level is the controllable half of the geometry.
    func startMotion(_ onTilt: @escaping (Double) -> Void) {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { data, _ in
            guard let g = data?.gravity else { return }
            let norm = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
            guard norm > 0 else { return }
            // Portrait upright ⇒ gravity ≈ (0, −1, 0) in device coordinates.
            let cosTilt = min(max(-g.y / norm, -1), 1)
            onTilt(acos(cosTilt) * 180 / .pi)
        }
    }

    func stopMotion() { motion.stopDeviceMotionUpdates() }
}

// MARK: - Depth sampling + back-projection

enum ProfileMath {

    /// Median depth (metres) over a 5×5 window at (x, y) in DEPTH-MAP pixels.
    /// Rejects non-finite / implausible values (< 5cm or > 5m).
    static func sampleDepth(_ map: CVPixelBuffer, x: Int, y: Int) -> Float? {
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map)
        let h = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)

        var values: [Float] = []
        for dy in -2...2 {
            let yy = y + dy
            guard yy >= 0, yy < h else { continue }
            let row = base.advanced(by: yy * rowBytes).assumingMemoryBound(to: Float32.self)
            for dx in -2...2 {
                let xx = x + dx
                guard xx >= 0, xx < w else { continue }
                let v = row[xx]
                if v.isFinite, v > 0.05, v < 5 { values.append(v) }
            }
        }
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }

    /// Back-projects a raw-video-buffer pixel to a 3D camera-space point
    /// (metres) using the depth map and intrinsics:
    ///     X = (x − cx)/fx · Z,  Y = (y − cy)/fy · Z,  Z = depth(x, y)
    static func cameraPoint(rawX: Float, rawY: Float, capture: ProfileCapture) -> SIMD3<Float>? {
        guard capture.fx > 0, capture.fy > 0,
              capture.videoWidth > 0, capture.videoHeight > 0 else { return nil }
        let dx = Int(rawX * Float(capture.depthWidth) / Float(capture.videoWidth))
        let dy = Int(rawY * Float(capture.depthHeight) / Float(capture.videoHeight))
        guard let z = sampleDepth(capture.depthMap, x: dx, y: dy) else { return nil }
        return SIMD3((rawX - capture.cx) / capture.fx * z,
                     (rawY - capture.cy) / capture.fy * z,
                     z)
    }
}

// MARK: - Profile harness view

struct ProfileCaptureView: View {
    var onClose: () -> Void = {}

    enum Side: String, CaseIterable, Identifiable {
        case left = "Left", right = "Right"
        var id: String { rawValue }
    }

    enum TapStep { case eyeCorner, earTop, done }

    struct Measurement {
        let distance3DMM: Float    // eye corner → ear top, straight line (≈ temple length)
        let dropMM: Float          // screen-vertical component, screen-DOWN positive
        let horizontalMM: Float    // screen-horizontal component
        let depthEyeM: Float
        let depthEarM: Float
    }

    /// Max phone tilt (degrees from portrait-upright) treated as acceptable.
    /// EMPIRICAL starting value — how much tilt visibly corrupts the vertical
    /// drop is one of the things on-device validation must establish.
    private let maxTiltDegrees: Double = 5

    /// A retap only adjusts a finished measurement when it lands within this
    /// distance of an existing marker — a stray touch far from both must not
    /// silently move a point and corrupt the result. EMPIRICAL UI radius.
    private let maxAdjustDistancePt: CGFloat = 80

    @State private var camera = ProfileCameraController()
    @State private var capture: ProfileCapture?
    @State private var side: Side = .left
    @State private var step: TapStep = .eyeCorner
    @State private var tiltDegrees: Double?
    @State private var status: String?

    // View-space tap points for drawing; camera-space points for math.
    @State private var eyeViewPoint: CGPoint?
    @State private var earViewPoint: CGPoint?
    @State private var eyeCameraPoint: SIMD3<Float>?
    @State private var earCameraPoint: SIMD3<Float>?

    @State private var results: [Side: Measurement] = [:]

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if !camera.hasTrueDepth {
                noTrueDepthView
            } else if let capture {
                markupView(capture)
            } else {
                captureView
            }

            topBar
        }
        .onAppear {
            camera.configureAndStart()
            camera.startMotion { tiltDegrees = $0 }
        }
        .onDisappear {
            camera.stop()
            camera.stopMotion()
        }
    }

    // MARK: Capture stage

    private var captureView: some View {
        ZStack(alignment: .bottom) {
            CardCameraPreview(session: camera.session)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                instructionCard
                tiltBadge
                Picker("Side", selection: $side) {
                    ForEach(Side.allCases) { s in Text("\(s.rawValue) ear").tag(s) }
                }
                .pickerStyle(.segmented)
                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                Button {
                    camera.capture { cap in
                        capture = cap
                        resetTaps()
                        status = cap == nil ? "Capture failed — try again" : nil
                    }
                } label: {
                    Text("Capture \(side.rawValue) profile")
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
            Text("Profile capture — test harness (M11)").font(.headline)
            Text("Hold the phone UPRIGHT at arm's length (watch the tilt readout). Turn your head so your \(side.rawValue.uppercased()) ear faces the camera, eyes level. A second person pressing Capture is easiest.")
                .font(.footnote)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private var tiltBadge: some View {
        let tilt = tiltDegrees
        let ok = (tilt ?? 99) <= maxTiltDegrees
        return Text(tilt.map { String(format: "Phone tilt: %.0f°%@", $0, ok ? " ✓" : "  — hold upright") }
                    ?? "Phone tilt: n/a")
            .font(.system(.caption, design: .monospaced).bold())
            .foregroundStyle(ok ? .green : .yellow)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
    }

    // MARK: Markup stage

    private func markupView(_ capture: ProfileCapture) -> some View {
        GeometryReader { geo in
            ZStack {
                // Tap gesture on the IMAGE, not the ZStack: on the stack,
                // taps landing on the readout/controls panels fall through
                // and register as measurement points behind the panel.
                Image(uiImage: capture.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { handleTap($0.location, in: geo.size) })

                overlayCanvas

                VStack {
                    Spacer()
                    readout(capture)
                    controls
                }
                .padding(16)
            }
        }
    }

    private var overlayCanvas: some View {
        Canvas { ctx, _ in
            func dot(_ p: CGPoint, _ color: Color) {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)),
                         with: .color(color))
            }
            if let a = eyeViewPoint, let b = earViewPoint {
                var line = Path(); line.move(to: a); line.addLine(to: b)
                ctx.stroke(line, with: .color(.cyan), lineWidth: 2)
            }
            if let p = eyeViewPoint { dot(p, .red) }
            if let p = earViewPoint { dot(p, .yellow) }
        }
        .allowsHitTesting(false)
    }

    private func readout(_ capture: ProfileCapture) -> some View {
        let current = results[side]
        let other: Side = side == .left ? .right : .left
        let otherResult = results[other]
        return VStack(alignment: .leading, spacing: 3) {
            Text("— Profile (M11, unvalidated vs ruler) —").foregroundStyle(.cyan)
            Text("Side:                 \(side.rawValue)")
            Text("Eye→ear 3D distance:  \(current.map { mm($0.distance3DMM) } ?? "n/a")")
            Text("Vertical drop (scrn): \(current.map { String(format: "%+.1fmm (down +)", $0.dropMM) } ?? "n/a")")
            Text("Horizontal span:      \(current.map { mm($0.horizontalMM) } ?? "n/a")")
            Text("Depth eye / ear:      \(current.map { String(format: "%.2f / %.2fm", $0.depthEyeM, $0.depthEarM) } ?? "n/a")")
            Text("Intrinsics:           \(capture.intrinsicsSource) (fx \(String(format: "%.0f", capture.fx)))")
            Text("Video / depth px:     \(capture.videoWidth)×\(capture.videoHeight) / \(capture.depthWidth)×\(capture.depthHeight)")
            if let otherResult {
                Text("\(other.rawValue) side (last):     \(mm(otherResult.distance3DMM)), drop \(String(format: "%+.1fmm", otherResult.dropMM))")
                if let current {
                    Text("L/R asymmetry:        Δ3D \(String(format: "%.1fmm", abs(current.distance3DMM - otherResult.distance3DMM))), Δdrop \(String(format: "%.1fmm", abs(current.dropMM - otherResult.dropMM)))")
                        .foregroundStyle(.yellow)
                }
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

    private var controls: some View {
        VStack(spacing: 8) {
            Text(stepPrompt)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.top, 8)
            HStack(spacing: 10) {
                Button("Reset taps") { resetTaps() }
                Button("Retake") { capture = nil; resetTaps() }
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
        case .eyeCorner: return "Tap the OUTER corner of the eye"
        case .earTop:    return "Tap the TOP of the ear junction (where a temple arm rests)"
        case .done:      return "Done — retap either point to adjust, or Retake"
        }
    }

    // MARK: Tap handling

    private func handleTap(_ location: CGPoint, in viewSize: CGSize) {
        guard let capture else { return }

        // View point → displayed-image pixel (scaledToFit letterboxing).
        let imgW = capture.image.size.width    // = raw buffer HEIGHT (rotated for display)
        let imgH = capture.image.size.height   // = raw buffer WIDTH
        guard imgW > 0, imgH > 0 else { return }
        let scale = min(viewSize.width / imgW, viewSize.height / imgH)
        let offX = (viewSize.width - imgW * scale) / 2
        let offY = (viewSize.height - imgH * scale) / 2
        let ix = (location.x - offX) / scale
        let iy = (location.y - offY) / scale
        guard ix >= 0, iy >= 0, ix < imgW, iy < imgH else { return }

        // Distinguish "no intrinsics on this capture" (retap won't help; the
        // whole capture lacks mm scale) from "no depth at that pixel" (retap
        // nearby) — cameraPoint fails for both and the messages must differ.
        guard capture.fx > 0 else {
            status = "No camera intrinsics in this capture — Retake"
            return
        }
        // Display image is the transposed raw buffer (.leftMirrored: 0th raw
        // row → display left, 0th raw column → display top), so the inverse
        // mapping is a plain transpose: raw x = display y, raw y = display x.
        let rawX = Float(iy)
        let rawY = Float(ix)
        guard let camPoint = ProfileMath.cameraPoint(rawX: rawX, rawY: rawY, capture: capture) else {
            status = "No depth at that point — tap again"
            return
        }
        status = nil

        switch step {
        case .eyeCorner:
            eyeViewPoint = location
            eyeCameraPoint = camPoint
            step = .earTop
        case .earTop:
            earViewPoint = location
            earCameraPoint = camPoint
            step = .done
        case .done:
            // "Retap either point to adjust": move whichever existing marker
            // is nearer — but only when the tap lands close to one, so a
            // stray touch can't silently move a point and corrupt the result.
            guard let eye = eyeViewPoint, let ear = earViewPoint else { return }
            let dEye = hypot(eye.x - location.x, eye.y - location.y)
            let dEar = hypot(ear.x - location.x, ear.y - location.y)
            guard min(dEye, dEar) <= maxAdjustDistancePt else {
                status = "Tap ignored — tap ON a marker to adjust it"
                return
            }
            if dEye < dEar {
                eyeViewPoint = location
                eyeCameraPoint = camPoint
            } else {
                earViewPoint = location
                earCameraPoint = camPoint
            }
        }
        computeMeasurement(capture)
    }

    private func computeMeasurement(_ capture: ProfileCapture) {
        guard let a = eyeCameraPoint, let b = earCameraPoint else { return }
        let d = b - a
        // Display-vertical ↔ raw x ↔ camera X (transpose mapping, see
        // handleTap). Screen-down positive; with the phone upright (tilt ≈ 0)
        // screen-vertical ≈ gravity-vertical. Sign convention UNVALIDATED
        // until checked on device against a known geometry.
        results[side] = Measurement(distance3DMM: simd_length(d) * 1000,
                                    dropMM: d.x * 1000,
                                    horizontalMM: abs(d.y) * 1000,
                                    depthEyeM: a.z,
                                    depthEarM: b.z)
    }

    private func resetTaps() {
        eyeViewPoint = nil; earViewPoint = nil
        eyeCameraPoint = nil; earCameraPoint = nil
        step = .eyeCorner
        status = nil
    }

    private func mm(_ v: Float) -> String { String(format: "%.1fmm", v) }

    // MARK: No TrueDepth fallback

    private var noTrueDepthView: some View {
        VStack(spacing: 16) {
            Image(systemName: "faceid")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Profile capture needs a TrueDepth (Face ID) front camera.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ProfileCaptureView()
}
