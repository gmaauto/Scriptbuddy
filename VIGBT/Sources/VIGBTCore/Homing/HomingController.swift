import Foundation

/// Haptic/audio events emitted by the close-range homing state machine (Phase 4.3).
public enum HomingEvent: Equatable, Sendable {
    /// Ball entered the field of view → subtle double-tap.
    case peripheralDetected
    /// Geiger tick; the haptic layer schedules the next tick `interval` seconds later.
    case tick(interval: Double, intensity: Double)
    /// Ball lost from view.
    case lost
    /// Ball centred and within range → confirmation tone + `.success` notification haptic.
    case locked
}

/// One detection from the ground scanner, in normalized image coordinates.
public struct GroundDetection: Equatable, Sendable {
    /// Offset of the ball centroid from image centre, each in [−1, 1].
    public var offsetX: Double
    public var offsetY: Double
    /// Estimated distance to the ball (LiDAR depth at the centroid when available), meters.
    public var distanceMeters: Double?

    public init(offsetX: Double, offsetY: Double, distanceMeters: Double?) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.distanceMeters = distanceMeters
    }

    /// 0 at centre, 1 at the image edge/corner (clamped).
    public var centerError: Double { min(1, (offsetX * offsetX + offsetY * offsetY).squareRoot()) }
}

public struct HomingController: Sendable {
    public var slowestTickInterval: Double
    public var fastestTickInterval: Double
    /// Normalized centre error under which the ball counts as centred.
    public var centeredTolerance: Double
    public var lockDistanceMeters: Double
    /// Consecutive centred frames required to lock (debounces false positives on grass).
    public var framesToLock: Int
    /// Consecutive empty frames before reporting `.lost`.
    public var framesToLose: Int

    public private(set) var isTracking = false
    public private(set) var isLocked = false
    private var centeredStreak = 0
    private var missStreak = 0

    public init(slowestTickInterval: Double = 0.6, fastestTickInterval: Double = 0.05,
                centeredTolerance: Double = 0.12, lockDistanceMeters: Double = 2.0,
                framesToLock: Int = 6, framesToLose: Int = 8) {
        self.slowestTickInterval = slowestTickInterval
        self.fastestTickInterval = fastestTickInterval
        self.centeredTolerance = centeredTolerance
        self.lockDistanceMeters = lockDistanceMeters
        self.framesToLock = framesToLock
        self.framesToLose = framesToLose
    }

    public mutating func reset() {
        isTracking = false
        isLocked = false
        centeredStreak = 0
        missStreak = 0
    }

    /// Feed once per processed frame (nil = no ball detected this frame).
    public mutating func process(_ detection: GroundDetection?) -> [HomingEvent] {
        guard !isLocked else { return [] }
        guard let det = detection else {
            centeredStreak = 0
            guard isTracking else { return [] }
            missStreak += 1
            if missStreak >= framesToLose {
                isTracking = false
                missStreak = 0
                return [.lost]
            }
            return []
        }
        missStreak = 0
        var events: [HomingEvent] = []
        if !isTracking {
            isTracking = true
            events.append(.peripheralDetected)
        }
        let err = det.centerError
        let closeness = 1 - err
        let interval = fastestTickInterval + (slowestTickInterval - fastestTickInterval) * err
        events.append(.tick(interval: interval, intensity: 0.3 + 0.7 * closeness))

        let inRange = det.distanceMeters.map { $0 <= lockDistanceMeters } ?? false
        if err <= centeredTolerance, inRange {
            centeredStreak += 1
            if centeredStreak >= framesToLock {
                isLocked = true
                events.append(.locked)
            }
        } else {
            centeredStreak = 0
        }
        return events
    }
}
