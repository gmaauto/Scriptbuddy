import AVFoundation
import CoreGraphics
import VIGBTCore

/// Phase 4.1–4.2: rear Wide camera at 1080p60 with continuous autofocus and auto torch, scanning
/// each frame with the active colour profile for a round, ball-sized blob.
final class GroundScanService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    /// Called on the main queue for every processed frame (nil = no ball in view).
    var onDetection: (@MainActor (GroundDetection?) -> Void)?
    /// Low-vision ball highlight frames (SPEC §11), about 10 per second while enabled.
    var onHighlight: (@MainActor (CGImage?) -> Void)?
    var highlightEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _highlightEnabled }
        set { lock.lock(); _highlightEnabled = newValue; lock.unlock() }
    }
    var highlightPalette: ThemePalette {
        get { lock.lock(); defer { lock.unlock() }; return _highlightPalette }
        set { lock.lock(); _highlightPalette = newValue; lock.unlock() }
    }
    private var _highlightEnabled = true
    private var _highlightPalette = ThemePalette.highContrastDark
    private var frameCounter = 0

    private let sessionQueue = DispatchQueue(label: "vigbt.scan.session")
    private let videoQueue = DispatchQueue(label: "vigbt.scan.video", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var configured = false
    private var focalLengthPixels: Double = 1500
    private let lock = NSLock()
    private var profile: BallColorProfile?
    private let whiteDetector = WhiteBallDetector()
    private let scorer = FusionScorer()
    /// Processing step: 2 → 960×540 masks, plenty for a ball within ~10 m.
    private let step = 2

    func start(profile: BallColorProfile) {
        lock.lock()
        self.profile = profile
        lock.unlock()
        sessionQueue.async {
            do {
                try self.configureIfNeeded()
            } catch {
                return
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CaptureError.noCamera
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority
        let input = try AVCaptureDeviceInput(device: dev)
        guard session.canAddInput(input) else { throw CaptureError.noCamera }
        session.addInput(input)

        let format = dev.formats.first { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == 1920 && d.height == 1080 && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 60 }
        }
        try dev.lockForConfiguration()
        if let format {
            dev.activeFormat = format
            dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
            dev.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
        }
        if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
        if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
        if dev.hasTorch, dev.isTorchModeSupported(.auto) { dev.torchMode = .auto } // torch assist in low light
        dev.unlockForConfiguration()

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { throw CaptureError.noCamera }
        session.addOutput(output)

        let dims = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
        let fov = Units.radians(Double(dev.activeFormat.videoFieldOfView))
        focalLengthPixels = (Double(dims.width) / 2) / tan(fov / 2)
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        let profile = self.profile
        lock.unlock()
        guard let profile else { return }

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        let w = CVPixelBufferGetWidth(pixels)
        let h = CVPixelBufferGetHeight(pixels)
        let bpr = CVPixelBufferGetBytesPerRow(pixels)
        var masks: FrameMasks?
        var best: DetectionCandidate?
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            let bytes = UnsafeRawBufferPointer(start: base, count: bpr * h)
            if profile.preset == .white {
                // White balls: colour alone matches sky, sand and lines, so use the dedicated detector.
                let r = whiteDetector.detect(bgra: bytes, width: w, height: h, bytesPerRow: bpr, step: step)
                masks = r.masks
                best = r.candidates.first
            } else {
                let m = FrameMasks.build(bgra: bytes, width: w, height: h, bytesPerRow: bpr, step: step, range: profile.range)
                masks = m
                best = BlobDetector(minArea: 3, maxArea: m.width * m.height / 8)
                    .detect(mask: m.color, width: m.width, height: m.height, color: m.color, step: step)
                    .compactMap { b -> (DetectionCandidate, Double)? in
                        guard let circ = scorer.circularity(of: b) else { return nil }
                        return (b, circ * b.radiusPixels)
                    }
                    .max { $0.1 < $1.1 }?.0
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        guard let masks else { return }

        var detection: GroundDetection?
        if let b = best {
            let distance = focalLengthPixels * 0.021335 / b.radiusPixels
            detection = GroundDetection(offsetX: (b.centerX / Double(w)) * 2 - 1,
                                        offsetY: (b.centerY / Double(h)) * 2 - 1,
                                        distanceMeters: distance)
        }
        Task { @MainActor in self.onDetection?(detection) }

        frameCounter += 1
        if highlightEnabled, frameCounter % 6 == 0 { // 60 fps capture → 10 fps highlight
            let p = highlightPalette
            let img = BallHighlight.render(masks: masks, ball: best, highlight: p.accent, ring: p.pin, background: p.background)
            let cg = Self.makeImage(img)
            Task { @MainActor in self.onHighlight?(cg) }
        }
    }

    private static func makeImage(_ img: BallHighlight.Image) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(img.rgba) as CFData) else { return nil }
        return CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
