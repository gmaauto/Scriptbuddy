import AVFoundation
import CoreVideo
import VIGBTCore

/// Phases 1.3 → 2 on a captured clip: decode the frames around T0, build colour + motion masks,
/// find candidate blobs and hand them to `ShotAnalyzer`.
enum ClipAnalysisService {
    struct Output: Sendable {
        var analysis: ShotAnalysis
        var referenceRadiusPixels: Double?
    }

    /// Frames before T0 used to measure the resting ball, and frames after T0 used for tracking.
    static let preFrames = 8
    static let postFrames = 20

    static func analyze(clip: CapturedClip, calibration: TeeCalibration, profile: BallColorProfile?,
                        includeBallistics: Bool, club: Club, zone: SearchZoneCalibration?) async throws -> Output {
        let asset = AVURLAsset(url: clip.url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptureError.exportFailed("Clip has no video.")
        }
        let fps = clip.frameRate
        let start = max(0, clip.impactTime - Double(preFrames) / fps)
        let duration = Double(preFrames + postFrames + 1) / fps

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600_000),
                                       duration: CMTime(seconds: duration, preferredTimescale: 600_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? CaptureError.exportFailed("Could not read the clip.")
        }

        let expectedRadius = CameraPose.expectedBallRadiusPixels(calibration: calibration)
        // Motion blobs: anything between a speck and a few ball-areas. Club and body are rejected here or by the gates.
        let blobs = BlobDetector(minArea: 1, maxArea: max(40, Int(.pi * pow(2.5 * expectedRadius, 2))))
        let scorer = FusionScorer()

        var frames = Array(repeating: [DetectionCandidate](), count: postFrames)
        var restingRadii: [Double] = []
        var previous: FrameMasks?

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let offset = Int(((pts - clip.impactTime) * fps).rounded())
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let masks = buildMasks(pixels, range: profile?.range)

            if offset <= -2, profile?.preset == .white {
                // White ball on the tee: colour alone also matches sky and tee markers.
                if let r = whiteRestingRadius(pixels, expected: expectedRadius) { restingRadii.append(r) }
            } else if offset <= -2, profile != nil {
                // Resting ball on the tee: the best round, colour-matched blob near the expected size.
                let still = blobs.detect(mask: masks.color, width: masks.width, height: masks.height, color: masks.color)
                if let ball = still
                    .filter({ $0.radiusPixels >= 0.4 * expectedRadius && $0.radiusPixels <= 2.5 * expectedRadius })
                    .filter({ scorer.circularity(of: $0) != nil })
                    .max(by: { $0.colorMatchFraction * $0.radiusPixels < $1.colorMatchFraction * $1.radiusPixels }) {
                    restingRadii.append(ball.radiusPixels)
                }
            }
            if offset >= 1, offset <= postFrames, let prev = previous, prev.width == masks.width, prev.height == masks.height {
                let motion = masks.motion(since: prev)
                frames[offset - 1] = blobs.detect(mask: motion, width: masks.width, height: masks.height,
                                                  color: profile == nil ? nil : masks.color)
            }
            previous = masks
        }
        if reader.status == .failed { throw reader.error ?? CaptureError.exportFailed("Decoding failed.") }

        let reference: Double? = restingRadii.isEmpty ? nil : restingRadii.sorted()[restingRadii.count / 2]
        let analysis = ShotAnalyzer().analyze(frames: frames, calibration: calibration,
                                              referenceRadiusPixels: reference, includeBallistics: includeBallistics,
                                              club: club, zone: zone)
        return Output(analysis: analysis, referenceRadiusPixels: reference)
    }

    private static func whiteRestingRadius(_ pixels: CVPixelBuffer, expected: Double) -> Double? {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let h = CVPixelBufferGetHeight(pixels), bpr = CVPixelBufferGetBytesPerRow(pixels)
        var detector = WhiteBallDetector()
        detector.minArea = 2
        let r = detector.detect(bgra: UnsafeRawBufferPointer(start: base, count: bpr * h),
                                width: CVPixelBufferGetWidth(pixels), height: h, bytesPerRow: bpr, step: 1)
        return r.candidates
            .first { $0.radiusPixels >= 0.4 * expected && $0.radiusPixels <= 2.5 * expected }?
            .radiusPixels
    }

    private static func buildMasks(_ pixels: CVPixelBuffer, range: HSVRange?) -> FrameMasks {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let w = CVPixelBufferGetWidth(pixels)
        let h = CVPixelBufferGetHeight(pixels)
        let bpr = CVPixelBufferGetBytesPerRow(pixels)
        guard let base = CVPixelBufferGetBaseAddress(pixels) else {
            return FrameMasks(width: 0, height: 0, step: 1, luma: [], color: [])
        }
        let buffer = UnsafeRawBufferPointer(start: base, count: bpr * h)
        return FrameMasks.build(bgra: buffer, width: w, height: h, bytesPerRow: bpr, step: 1, range: range)
    }
}
