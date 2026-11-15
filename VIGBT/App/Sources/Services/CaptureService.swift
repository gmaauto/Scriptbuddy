import AVFoundation
import Accelerate
import QuartzCore
import VIGBTCore

/// A trimmed shot clip ready for analysis and replay.
struct CapturedClip: Sendable {
    let url: URL
    /// Impact time T0 in seconds on the clip's own timeline.
    let impactTime: Double
    let frameRate: Double
    let width: Int
    let height: Int
}

enum CaptureError: LocalizedError {
    case noCamera
    case noHighSpeedFormat
    case writerFailed
    case exportFailed(String)
    case noSegments

    var errorDescription: String? {
        switch self {
        case .noCamera: return "No rear camera is available."
        case .noHighSpeedFormat: return "This iPhone cannot record 1080p at 120 frames per second."
        case .writerFailed: return "Could not start recording."
        case .exportFailed(let why): return "Could not save the shot clip. \(why)"
        case .noSegments: return "No video was recorded before the strike."
        }
    }
}

/// Phase 1.1: rolling 5-second pre-roll at 1080p120 + acoustic impact trigger.
///
/// The pre-roll is kept as ~1-second HEVC segments on disk (a `RingBuffer<Segment>`), never as raw
/// frames: 600 raw 1080p frames would need ~1.9 GB (see `RingBufferBudget`). After a trigger, capture
/// continues until T0 + 3.5 s, then the session is stopped and the overlapping segments are stitched
/// and exported as one clip. Every `CMSampleBuffer` is handed to the encoder and released immediately.
final class CaptureService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()

    /// Called on the main queue when the strike is detected (or Test Strike pressed).
    var onImpact: (@MainActor () -> Void)?
    /// Called on the main queue when the clip is exported (or failed).
    var onClip: (@MainActor (Result<CapturedClip, Error>) -> Void)?

    private(set) var fieldOfViewDegrees: Double = 108
    private(set) var frameRate: Double = 120
    private(set) var dimensions = (width: 1920, height: 1080)
    private(set) var isConfigured = false

    /// Sound travel time from tee to microphone, subtracted from the acoustic T0.
    var acousticDelaySeconds: Double = 0.009

    private let sessionQueue = DispatchQueue(label: "vigbt.capture.session")
    private let videoQueue = DispatchQueue(label: "vigbt.capture.video", qos: .userInteractive)
    private let writerPrepQueue = DispatchQueue(label: "vigbt.capture.writerprep", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private let clipWindow = ClipWindow()
    private let segmentDuration = 1.0
    private let segmentDirectory: URL

    // videoQueue-confined state
    private var current: SegmentWriter?
    private var next: SegmentWriter?
    private var segments = RingBuffer<Segment>(capacity: 8)
    private var pendingImpact: Double?
    private var stopAt: Double?
    private let finishing = DispatchGroup()

    // audio-thread state
    private let audioEngine = AVAudioEngine()
    private var detector = ImpactDetector()
    private let audioLock = NSLock()

    override init() {
        segmentDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("preroll", isDirectory: true)
        super.init()
        try? FileManager.default.removeItem(at: segmentDirectory)
        try? FileManager.default.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)
    }

    // MARK: Configuration

    /// Picks the Ultra-Wide camera at 1080p120 (falls back to the Wide camera if the Ultra-Wide has no such format).
    func configure() throws {
        guard !isConfigured else { return }
        let candidates: [AVCaptureDevice.DeviceType] = [.builtInUltraWideCamera, .builtInWideAngleCamera]
        var chosen: (AVCaptureDevice, AVCaptureDevice.Format, Double)?
        for type in candidates {
            guard let dev = AVCaptureDevice.default(type, for: .video, position: .back) else { continue }
            if let best = Self.bestFormat(for: dev) {
                chosen = (dev, best.0, best.1)
                break
            }
        }
        guard let chosen else {
            throw AVCaptureDevice.default(for: .video) == nil ? CaptureError.noCamera : CaptureError.noHighSpeedFormat
        }
        let (dev, format, fps) = chosen

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority
        session.automaticallyConfiguresApplicationAudioSession = false

        let input = try AVCaptureDeviceInput(device: dev)
        guard session.canAddInput(input) else { throw CaptureError.noCamera }
        session.addInput(input)

        try dev.lockForConfiguration()
        dev.activeFormat = format
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        dev.activeVideoMinFrameDuration = frameDuration
        dev.activeVideoMaxFrameDuration = frameDuration
        if dev.isGeometricDistortionCorrectionSupported {
            dev.isGeometricDistortionCorrectionEnabled = true   // keeps the pinhole model valid on the Ultra-Wide
        }
        if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
        dev.unlockForConfiguration()

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { throw CaptureError.noCamera }
        session.addOutput(videoOutput)
        if let c = videoOutput.connection(with: .video) {
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off } // stabilisation crops & warps
            if c.isVideoRotationAngleSupported(0) { c.videoRotationAngle = 0 }              // sensor-native landscape
        }

        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        dimensions = (Int(dims.width), Int(dims.height))
        fieldOfViewDegrees = Double(format.videoFieldOfView)
        frameRate = fps
        device = dev
        isConfigured = true
    }

    private static func bestFormat(for dev: AVCaptureDevice) -> (AVCaptureDevice.Format, Double)? {
        var best: (AVCaptureDevice.Format, Double)?
        for f in dev.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard d.width == 1920, d.height == 1080 else { continue }
            let maxFPS = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            guard maxFPS >= 119 else { continue }
            if best == nil || f.videoFieldOfView > best!.0.videoFieldOfView { best = (f, 120) }
        }
        return best
    }

    // MARK: Arm / disarm

    func arm() throws {
        try configure()
        try startAudio()
        videoQueue.async {
            self.pendingImpact = nil
            self.stopAt = nil
        }
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
        }
        // Let auto-exposure settle, then lock a fast shutter so the ball is not a motion-blur streak.
        sessionQueue.asyncAfter(deadline: .now() + 1.0) { self.applyFastShutter() }
    }

    func disarm() {
        stopAudio()
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
        videoQueue.async {
            self.current?.cancel()
            self.next?.cancel()
            self.current = nil
            self.next = nil
            self.discardSegments()
        }
    }

    /// Manual "Test Strike" for dry runs.
    func testStrike() {
        trigger(at: CACurrentMediaTime())
    }

    private func applyFastShutter(targetSeconds: Double = 1.0 / 2000) {
        guard let dev = device, (try? dev.lockForConfiguration()) != nil else { return }
        defer { dev.unlockForConfiguration() }
        let f = dev.activeFormat
        let target = min(max(targetSeconds, f.minExposureDuration.seconds), f.maxExposureDuration.seconds)
        let currentSeconds = dev.exposureDuration.seconds
        guard currentSeconds.isFinite, currentSeconds > 0 else { return }
        let iso = min(max(dev.iso * Float(currentSeconds / target), f.minISO), f.maxISO)
        dev.setExposureModeCustom(duration: CMTime(seconds: target, preferredTimescale: 1_000_000), iso: iso,
                                  completionHandler: nil)
    }

    // MARK: Audio trigger

    private func startAudio() throws {
        let s = AVAudioSession.sharedInstance()
        // .measurement disables AGC and voice processing, which would flatten the strike transient.
        try s.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try s.setActive(true)
        audioLock.lock()
        detector = ImpactDetector()
        audioLock.unlock()
        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, when in
            self?.process(buffer: buffer, when: when)
        }
        if !audioEngine.isRunning { try audioEngine.start() }
    }

    private func stopAudio() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    private func process(buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        let base = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : CACurrentMediaTime()
        let block = 256 // ≈5 ms at 48 kHz, regardless of the tap's actual buffer size
        var i = 0
        while i < n {
            let len = min(block, n - i)
            var peak: Float = 0
            vDSP_maxmgv(channel + i, 1, &peak, vDSP_Length(len))
            let t = base + Double(i) / sampleRate
            audioLock.lock()
            let fired = detector.process(peakDB: ImpactDetector.decibels(linearPeak: Double(peak)), at: t)
            audioLock.unlock()
            if fired { trigger(at: t - acousticDelaySeconds) }
            i += len
        }
    }

    private func trigger(at hostSeconds: Double) {
        videoQueue.async {
            guard self.pendingImpact == nil else { return }
            self.pendingImpact = hostSeconds
            self.stopAt = self.clipWindow.captureStopTime(impactTime: hostSeconds)
            Task { @MainActor in self.onImpact?() }
        }
    }

    // MARK: Video (videoQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if current == nil {
            current = next ?? makeWriter()
            next = nil
            prepareNextWriter()
        }
        if let start = current?.startSeconds, t - start >= segmentDuration, stopAt == nil {
            rotate()
        }
        current?.append(sampleBuffer)
        if let stop = stopAt, t >= stop {
            finishClip()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Dropped frames simply leave a gap; the tracker tolerates up to `maxMissedFrames`.
    }

    private func makeWriter() -> SegmentWriter? {
        try? SegmentWriter(directory: segmentDirectory, width: dimensions.width, height: dimensions.height, fps: frameRate)
    }

    private func prepareNextWriter() {
        writerPrepQueue.async {
            let w = self.makeWriter()
            self.videoQueue.async { self.next = w }
        }
    }

    private func rotate() {
        guard let old = current else { return }
        current = next ?? makeWriter()
        next = nil
        prepareNextWriter()
        close(old)
    }

    private func close(_ w: SegmentWriter) {
        guard let seg = w.segment(frameRate: frameRate) else {
            w.cancel()
            return
        }
        finishing.enter()
        w.finish {
            self.videoQueue.async {
                if let evicted = self.segments.append(seg) {
                    try? FileManager.default.removeItem(at: evicted.url)
                }
                self.finishing.leave()
            }
        }
    }

    private func finishClip() {
        guard let t0 = pendingImpact else { return }
        stopAt = nil
        pendingImpact = nil
        if let w = current { close(w) }
        current = nil
        next?.cancel()
        next = nil
        // Pause the camera immediately: thermal/battery budget while processing and walking.
        sessionQueue.async { self.session.stopRunning() }
        stopAudio()
        finishing.notify(queue: videoQueue) {
            let window = self.clipWindow.range(impactTime: t0)
            let segs = self.segments.elements
                .filter { $0.end > window.lowerBound && $0.start < window.upperBound }
                .sorted { $0.start < $1.start }
            let all = self.segments.elements
            self.segments.removeAll()
            Task {
                let result: Result<CapturedClip, Error>
                do {
                    result = .success(try await self.export(segments: segs, impactHostTime: t0))
                } catch {
                    result = .failure(error)
                }
                for s in all { try? FileManager.default.removeItem(at: s.url) }
                await MainActor.run { self.onClip?(result) }
            }
        }
    }

    private func discardSegments() {
        for s in segments.elements { try? FileManager.default.removeItem(at: s.url) }
        segments.removeAll()
    }

    // MARK: Export

    private func export(segments: [Segment], impactHostTime t0: Double) async throws -> CapturedClip {
        guard let first = segments.first else { throw CaptureError.noSegments }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CaptureError.exportFailed("No video track.")
        }
        var cursor = CMTime.zero
        for s in segments {
            let asset = AVURLAsset(url: s.url)
            guard let src = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = try await src.load(.timeRange)
            try track.insertTimeRange(range, of: src, at: cursor)
            cursor = cursor + range.duration
        }

        let out = ShotStore.clipsDirectory.appendingPathComponent("shot-\(UUID().uuidString).mov")
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CaptureError.exportFailed("Exporter unavailable.")
        }
        exporter.outputURL = out
        exporter.outputFileType = .mov
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { c.resume() }
        }
        guard exporter.status == .completed else {
            throw CaptureError.exportFailed(exporter.error?.localizedDescription ?? "Unknown error.")
        }
        return CapturedClip(url: out, impactTime: t0 - first.start, frameRate: frameRate,
                            width: dimensions.width, height: dimensions.height)
    }
}

// MARK: - Segment writer

struct Segment: Sendable {
    let url: URL
    /// Host-clock seconds of the first and (one past the) last frame.
    let start: Double
    let end: Double
}

/// One ~1-second HEVC file of the rolling pre-roll.
final class SegmentWriter {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private(set) var startSeconds: Double?
    private var lastSeconds: Double?

    init(directory: URL, width: Int, height: Int, fps: Double) throws {
        url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 60_000_000,
                AVVideoMaxKeyFrameIntervalKey: 12,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureError.writerFailed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CaptureError.writerFailed }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startSeconds == nil {
            writer.startSession(atSourceTime: pts)
            startSeconds = pts.seconds
        }
        if input.isReadyForMoreMediaData, input.append(sampleBuffer) {
            lastSeconds = pts.seconds
        }
    }

    func segment(frameRate: Double) -> Segment? {
        guard let s = startSeconds, let e = lastSeconds else { return nil }
        return Segment(url: url, start: s, end: e + 1 / frameRate)
    }

    func finish(_ completion: @escaping @Sendable () -> Void) {
        input.markAsFinished()
        writer.finishWriting(completionHandler: completion)
    }

    func cancel() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}
