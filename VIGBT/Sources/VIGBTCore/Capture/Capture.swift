import Foundation

/// Fixed-capacity circular buffer. The iOS capture layer stores *encoded* sample references
/// (HEVC packets / segment indices), never raw pixel buffers — see `RingBufferBudget`.
public struct RingBuffer<Element>: Sequence {
    private var storage: [Element?]
    private var head = 0
    public private(set) var count = 0
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    /// Appends, overwriting the oldest element when full. Returns the evicted element, if any,
    /// so the caller can release its memory immediately.
    @discardableResult
    public mutating func append(_ e: Element) -> Element? {
        let idx = (head + count) % capacity
        if count < capacity {
            storage[idx] = e
            count += 1
            return nil
        }
        let evicted = storage[head]
        storage[head] = e
        head = (head + 1) % capacity
        return evicted
    }

    public mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
    }

    public var isFull: Bool { count == capacity }

    /// Oldest → newest.
    public var elements: [Element] { (0..<count).compactMap { storage[(head + $0) % capacity] } }

    public func makeIterator() -> IndexingIterator<[Element]> { elements.makeIterator() }
}

/// Memory sizing for the 5-second pre-roll. Raw 1080p NV12 is ~3.1 MB/frame, so 600 raw frames
/// would need ~1.9 GB — far beyond iOS jetsam limits. The capture layer must therefore keep the
/// pre-roll HEVC-encoded (e.g. `AVAssetWriter` writing short rolling segments, or
/// `VTCompressionSession` packets) and decode only the trimmed window after the trigger.
public struct RingBufferBudget: Sendable {
    public var seconds: Double
    public var frameRate: Double
    public var width: Int
    public var height: Int

    public init(seconds: Double = 5, frameRate: Double = 120, width: Int = 1920, height: Int = 1080) {
        self.seconds = seconds
        self.frameRate = frameRate
        self.width = width
        self.height = height
    }

    public var frameCount: Int { Int((seconds * frameRate).rounded(.up)) }
    /// NV12 (4:2:0) = 1.5 bytes per pixel.
    public var rawBytes: Int { frameCount * width * height * 3 / 2 }
    /// Approximate HEVC footprint at the given bitrate.
    public func encodedBytes(bitsPerSecond: Double = 60_000_000) -> Int { Int(bitsPerSecond / 8 * seconds) }
}

/// The trimmed export window around impact: [T0 − 1.5 s, T0 + 3.5 s].
public struct ClipWindow: Equatable, Sendable {
    public var preRoll: Double = 1.5
    public var postRoll: Double = 3.5

    public init(preRoll: Double = 1.5, postRoll: Double = 3.5) {
        self.preRoll = preRoll
        self.postRoll = postRoll
    }

    public func range(impactTime t0: Double) -> ClosedRange<Double> { (t0 - preRoll)...(t0 + postRoll) }
    /// Capture must keep running until this time before it can be paused and the clip written.
    public func captureStopTime(impactTime t0: Double) -> Double { t0 + postRoll }
}

/// Acoustic impact detector (Phase 1.1). Feed one peak level per audio buffer (from
/// `AVAudioEngine` input tap, e.g. 256-frame buffers ≈ 5.3 ms at 48 kHz).
///
/// Triggers when the buffer peak exceeds an adaptive noise floor by `thresholdDB` *and* the absolute
/// level exceeds `minimumPeakDB`, followed by a refractory period to ignore echoes and the follow-through.
public struct ImpactDetector: Sendable {
    public var thresholdDB: Double
    public var minimumPeakDB: Double
    public var refractorySeconds: Double
    /// Exponential smoothing factor for the noise floor (per buffer).
    public var floorSmoothing: Double

    public private(set) var noiseFloorDB: Double
    private var lastTrigger: Double?

    public init(thresholdDB: Double = 24, minimumPeakDB: Double = -20, refractorySeconds: Double = 2.0,
                floorSmoothing: Double = 0.02, initialNoiseFloorDB: Double = -50) {
        self.thresholdDB = thresholdDB
        self.minimumPeakDB = minimumPeakDB
        self.refractorySeconds = refractorySeconds
        self.floorSmoothing = floorSmoothing
        self.noiseFloorDB = initialNoiseFloorDB
    }

    /// Converts a linear peak sample magnitude (0…1) to dBFS.
    public static func decibels(linearPeak: Double) -> Double {
        20 * log10(max(linearPeak, 1e-9))
    }

    /// - Returns: `true` exactly once per impact (time = T0).
    public mutating func process(peakDB: Double, at time: Double) -> Bool {
        if let last = lastTrigger, time - last < refractorySeconds {
            return false
        }
        if peakDB >= noiseFloorDB + thresholdDB, peakDB >= minimumPeakDB {
            lastTrigger = time
            return true
        }
        // Only quiet-ish buffers update the floor so a rising swing whoosh can't mask the strike.
        if peakDB < noiseFloorDB + thresholdDB / 2 {
            noiseFloorDB += floorSmoothing * (peakDB - noiseFloorDB)
        }
        return false
    }

    /// Manual "Test Strike" button: forces a trigger regardless of audio.
    public mutating func forceTrigger(at time: Double) {
        lastTrigger = time
    }
}
