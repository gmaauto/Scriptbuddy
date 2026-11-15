import ARKit
import Observation
import VIGBTCore

/// Phase 1.2: a short ARKit pass that measures the camera-to-tee distance with LiDAR, the camera's
/// pitch/roll (from ARKit's gravity-aligned world) and its true-north heading (`.gravityAndHeading`).
///
/// Built for non-visual use: the golfer (or a helper) points the tripod-mounted phone at the tee;
/// the service continuously raycasts from the image centre and announces when the reading is stable.
@MainActor
@Observable
final class CalibrationService: NSObject {
    enum State: Equatable {
        case idle
        case unsupported(String)
        case searching
        case measuring(distance: Double)
        case stable(distance: Double)
    }

    private(set) var state: State = .idle
    let session = ARSession()

    /// Last pose readings (radians / degrees).
    private(set) var pitch: Double = 0
    private(set) var roll: Double = 0
    private(set) var heading: Double = 0
    /// Recent raw compass headings of the camera (ARKit `.gravityAndHeading`), for averaging and a quality check.
    @ObservationIgnored private var recentHeadings: [Double] = []
    /// Circular spread of recent headings, degrees. Above `CompassCorrection.maxSpreadDeg` → interference.
    private(set) var headingSpread: Double = 0

    @ObservationIgnored private var depths: [Double] = []
    nonisolated let throttle = Throttle(interval: 0.15)
    @ObservationIgnored var onStable: ((Double) -> Void)?

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.isSupported
            && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    func start() {
        guard Self.isSupported else {
            state = .unsupported("VIGBT needs an iPhone with a LiDAR scanner (iPhone 12 Pro or newer Pro model).")
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        config.planeDetection = [.horizontal]
        config.frameSemantics.insert(.sceneDepth)
        session.delegate = self
        depths.removeAll()
        recentHeadings.removeAll()
        headingSpread = 0
        state = .searching
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    /// Must be called before the high-speed capture session starts: both need the camera.
    func stop() {
        session.pause()
        if case .stable = state {} else { state = .idle }
    }

    /// Averaged raw heading over the last `count` readings (smooths compass jitter).
    func averagedHeading(last count: Int = 12) -> Double {
        CompassCorrection.circularMean(Array(recentHeadings.suffix(count))) ?? heading
    }

    /// Builds the calibration once stable, with the **raw** averaged compass heading; `AppModel` applies the
    /// compass correction. FOV and dimensions come from the capture format actually used.
    func makeCalibration(fieldOfViewDegrees: Double, width: Int, height: Int, teeLocation: GeoCoordinate) -> TeeCalibration? {
        guard case let .stable(distance) = state else { return nil }
        return TeeCalibration(distanceToTeeMeters: distance, cameraPitchRadians: pitch, cameraRollRadians: roll,
                              cameraHeadingDeg: averagedHeading(), horizontalFOVRadians: Units.radians(fieldOfViewDegrees),
                              imageWidth: Double(width), imageHeight: Double(height), teeLocation: teeLocation)
    }

    /// Tap-to-sample (Phase 1.3): a 15×15 patch at the centre of the current camera image, as HSV.
    /// The camera image is full-range YCbCr 4:2:0 (`capturedImage`).
    func sampleCenterPatch(size: Int = 15) -> [HSV]? {
        guard let frame = session.currentFrame else { return nil }
        let px = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(px) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(px, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(px, 1) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(px, 0)
        let h = CVPixelBufferGetHeightOfPlane(px, 0)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(px, 1)
        let y8 = yBase.assumingMemoryBound(to: UInt8.self)
        let c8 = cBase.assumingMemoryBound(to: UInt8.self)
        var out: [HSV] = []
        let half = size / 2
        for dy in -half...half {
            for dx in -half...half {
                let x = min(max(w / 2 + dx, 0), w - 1)
                let yy = min(max(h / 2 + dy, 0), h - 1)
                let Y = Double(y8[yy * yStride + x])
                let cb = Double(c8[(yy / 2) * cStride + (x / 2) * 2]) - 128
                let cr = Double(c8[(yy / 2) * cStride + (x / 2) * 2 + 1]) - 128
                let r = min(max((Y + 1.402 * cr) / 255, 0), 1)
                let g = min(max((Y - 0.344136 * cb - 0.714136 * cr) / 255, 0), 1)
                let b = min(max((Y + 1.772 * cb) / 255, 0), 1)
                out.append(HSV(r: r, g: g, b: b))
            }
        }
        return out
    }

    fileprivate func apply(_ r: Reading) {
        pitch = r.pitch
        roll = r.roll
        heading = r.heading
        recentHeadings.append(r.heading)
        if recentHeadings.count > 12 { recentHeadings.removeFirst(recentHeadings.count - 12) }
        headingSpread = CompassCorrection.circularSpread(recentHeadings)
        guard let depth = r.depth, (1.0...10.0).contains(depth) else {
            depths.removeAll()
            if case .stable = state { return }
            state = .searching
            return
        }
        depths.append(depth)
        if depths.count > 12 { depths.removeFirst(depths.count - 12) }
        let mean = depths.reduce(0, +) / Double(depths.count)
        let sd = (depths.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(depths.count)).squareRoot()

        if depths.count >= 10, sd < 0.03 {
            if case .stable = state { return }
            state = .stable(distance: mean)
            onStable?(mean)
        } else if case .stable = state, sd < 0.08 {
            return // small wobble after locking: keep the lock
        } else {
            state = .measuring(distance: mean)
        }
    }
}

/// Plain values extracted from an `ARFrame` on ARKit's delegate queue, so no frame is retained.
struct Reading: Sendable {
    var pitch: Double
    var roll: Double
    var heading: Double
    var depth: Double?

    static func make(frame: ARFrame, session: ARSession) -> Reading {
        let t = frame.camera.transform
        let right = simd_make_float3(t.columns.0)
        let up = simd_make_float3(t.columns.1)
        let back = simd_make_float3(t.columns.2)
        let position = simd_make_float3(t.columns.3)
        let forward = -back

        // Gravity (world −Y) in the camera frame (+x right, +y down, +z forward). ARKit's camera axes
        // follow the sensor-native landscape image, the same orientation as the capture buffers.
        let g = Vector3(Double(-right.y), Double(up.y), Double(back.y))
        let pose = CameraPose.pitchAndRoll(gravityInCamera: g)
        // .gravityAndHeading: +X east, −Z true north.
        let heading = CameraPose.heading(east: Double(forward.x), north: Double(-forward.z))

        var depth: Double?
        let query = ARRaycastQuery(origin: position, direction: forward, allowing: .estimatedPlane, alignment: .horizontal)
        if let hit = session.raycast(query).first {
            // Depth along the optical axis, as the pinhole model expects.
            let p = simd_make_float3(hit.worldTransform.columns.3)
            depth = Double(simd_dot(p - position, forward))
        }
        return Reading(pitch: pose.pitch, roll: pose.roll, heading: heading, depth: depth)
    }
}

/// Lock-protected rate limiter usable from ARKit's delegate queue.
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let interval: TimeInterval

    init(interval: TimeInterval) { self.interval = interval }

    func allow() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}

extension CalibrationService: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard throttle.allow() else { return }
        let reading = Reading.make(frame: frame, session: session)
        Task { @MainActor in self.apply(reading) }
    }
}
