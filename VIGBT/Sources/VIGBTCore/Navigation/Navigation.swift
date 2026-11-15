import Foundation

/// Phase 3.1 smoothing: per-axis Kalman filter in a local East/North frame anchored at the tee.
/// Prediction uses pedometer displacement (steps × stride along the compass heading);
/// GPS fixes are the measurement, weighted by their reported horizontal accuracy.
public struct PositionKalmanFilter: Sendable {
    public let origin: GeoCoordinate
    public private(set) var east: Double
    public private(set) var north: Double
    public private(set) var varianceEast: Double
    public private(set) var varianceNorth: Double
    /// Process noise added per meter walked (m² / m) — stride-length and heading uncertainty.
    public var processNoisePerMeter: Double
    /// Process noise added per second regardless of motion (m² / s).
    public var processNoisePerSecond: Double

    public init(origin: GeoCoordinate, initialVariance: Double = 25,
                processNoisePerMeter: Double = 0.05, processNoisePerSecond: Double = 0.1) {
        self.origin = origin
        self.east = 0
        self.north = 0
        self.varianceEast = initialVariance
        self.varianceNorth = initialVariance
        self.processNoisePerMeter = processNoisePerMeter
        self.processNoisePerSecond = processNoisePerSecond
    }

    public var coordinate: GeoCoordinate { GeoMath.coordinate(east: east, north: north, from: origin) }

    /// Dead-reckoning prediction from pedometer + compass.
    public mutating func predict(distanceWalkedMeters d: Double, headingDeg: Double, elapsedSeconds dt: Double) {
        let h = Units.radians(headingDeg)
        east += d * sin(h)
        north += d * cos(h)
        let q = processNoisePerMeter * abs(d) + processNoisePerSecond * max(0, dt)
        varianceEast += q
        varianceNorth += q
    }

    /// GPS measurement update. `horizontalAccuracy` is CoreLocation's 1-σ radius in meters.
    public mutating func update(gps: GeoCoordinate, horizontalAccuracy: Double) {
        guard horizontalAccuracy > 0 else { return }
        let z = GeoMath.enuOffset(of: gps, from: origin)
        let r = horizontalAccuracy * horizontalAccuracy
        let kE = varianceEast / (varianceEast + r)
        let kN = varianceNorth / (varianceNorth + r)
        east += kE * (z.east - east)
        north += kN * (z.north - north)
        varianceEast *= (1 - kE)
        varianceNorth *= (1 - kN)
    }
}

/// Spoken milestone announcements (Phase 3.2).
public enum NavigationMilestone: Int, Codable, CaseIterable, Comparable, Sendable {
    case yards100 = 100
    case yards50 = 50
    case yards25 = 25
    case arrived = 10

    public static func < (a: Self, b: Self) -> Bool { a.rawValue > b.rawValue } // ordered by progress

    public var announcement: String {
        switch self {
        case .yards100: return "100 yards to your ball."
        case .yards50: return "50 yards to your ball."
        case .yards25: return "25 yards to your ball."
        case .arrived: return "Arrived at search zone. Starting ground scan."
        }
    }
}

public enum CourseAlignment: String, Codable, Sendable {
    case onLine
    case offLeft    // target is to the user's left → turn left
    case offRight   // target is to the user's right → turn right
}

/// One tick of navigation output, consumed by the spatial-audio and VoiceOver layers.
public struct NavigationGuidance: Equatable, Sendable {
    public var distanceRemainingMeters: Double
    public var bearingToTargetDeg: Double
    /// Δψ = ψ_target − ψ_user, wrapped to (−180, 180]. Positive = target is to the right.
    public var headingErrorDeg: Double
    public var alignment: CourseAlignment
    /// Seconds between sonar pulses — shrinks as the user closes in.
    public var pulseIntervalSeconds: Double
    /// Beacon position for `AVAudioEnvironmentNode`, listener-relative meters (x right, z forward…
    /// note AVAudio3D uses −z as forward; the audio layer negates `forward`).
    public var beaconRight: Double
    public var beaconForward: Double
    /// Pitch shift in cents applied when off-line (0 when on-line).
    public var pitchShiftCents: Double
    /// Milestones crossed on this tick (usually empty; at most a few).
    public var milestones: [NavigationMilestone]
    public var hasArrived: Bool

    public var distanceRemainingYards: Double { Units.yards(fromMeters: distanceRemainingMeters) }
}

/// Phase 3 navigation engine: converts the filtered user position + heading into guidance.
public struct NavigationEngine: Sendable {
    public let target: TargetCoordinate
    public var onLineToleranceDeg: Double
    public var arrivalRadiusMeters: Double
    /// Pulse interval at/after `farDistanceMeters` and at arrival.
    public var farPulseInterval: Double
    public var nearPulseInterval: Double
    public var farDistanceMeters: Double
    public var offLinePitchCents: Double
    /// Beacon is rendered at a fixed virtual distance so loudness tracks direction, not GPS noise.
    public var beaconDistanceMeters: Double

    private var announced: Set<NavigationMilestone> = []

    public init(target: TargetCoordinate, onLineToleranceDeg: Double = 15,
                arrivalRadiusMeters: Double = Units.meters(fromYards: 10),
                farPulseInterval: Double = 1.2, nearPulseInterval: Double = 0.25,
                farDistanceMeters: Double = Units.meters(fromYards: 150),
                offLinePitchCents: Double = 300, beaconDistanceMeters: Double = 5) {
        self.target = target
        self.onLineToleranceDeg = onLineToleranceDeg
        self.arrivalRadiusMeters = arrivalRadiusMeters
        self.farPulseInterval = farPulseInterval
        self.nearPulseInterval = nearPulseInterval
        self.farDistanceMeters = farDistanceMeters
        self.offLinePitchCents = offLinePitchCents
        self.beaconDistanceMeters = beaconDistanceMeters
    }

    /// Call when the walk starts so milestones the user is already inside are not announced.
    public mutating func begin(from position: GeoCoordinate) {
        let d = Units.yards(fromMeters: GeoMath.distance(from: position, to: target.coordinate))
        announced = Set(NavigationMilestone.allCases.filter { $0 != .arrived && d <= Double($0.rawValue) })
    }

    public mutating func update(position: GeoCoordinate, headingDeg: Double) -> NavigationGuidance {
        let d = GeoMath.distance(from: position, to: target.coordinate)
        let bearing = GeoMath.bearing(from: position, to: target.coordinate)
        let err = Units.signedAngle(bearing - headingDeg)
        let alignment: CourseAlignment = abs(err) <= onLineToleranceDeg ? .onLine : (err < 0 ? .offLeft : .offRight)

        let fraction = min(1, max(0, (d - arrivalRadiusMeters) / max(1, farDistanceMeters - arrivalRadiusMeters)))
        let interval = nearPulseInterval + (farPulseInterval - nearPulseInterval) * fraction

        let rad = Units.radians(err)
        let pitch = alignment == .onLine ? 0 : (err < 0 ? -offLinePitchCents : offLinePitchCents)

        let yards = Units.yards(fromMeters: d)
        var crossed: [NavigationMilestone] = []
        for m in NavigationMilestone.allCases where !announced.contains(m) {
            let hit = m == .arrived ? d <= arrivalRadiusMeters : yards <= Double(m.rawValue)
            if hit {
                announced.insert(m)
                crossed.append(m)
            }
        }
        // If several were crossed at once (GPS jump), only the closest is worth speaking.
        if crossed.count > 1, let last = crossed.max() { crossed = [last] }

        return NavigationGuidance(
            distanceRemainingMeters: d,
            bearingToTargetDeg: bearing,
            headingErrorDeg: err,
            alignment: alignment,
            pulseIntervalSeconds: interval,
            beaconRight: beaconDistanceMeters * sin(rad),
            beaconForward: beaconDistanceMeters * cos(rad),
            pitchShiftCents: pitch,
            milestones: crossed,
            hasArrived: d <= arrivalRadiusMeters)
    }
}
