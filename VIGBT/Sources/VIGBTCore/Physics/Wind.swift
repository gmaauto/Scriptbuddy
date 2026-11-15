import Foundation

/// Wind strength as a golfer would describe it (SPEC §12.4). Presets, not numbers, because nobody on a
/// course can measure wind; the Monte Carlo run assumes a ±40% judgement error before snapping to these.
public enum WindStrength: String, Codable, CaseIterable, Identifiable, Sendable {
    case calm, light, moderate, strong, veryStrong

    public var id: String { rawValue }
    public var mph: Double {
        switch self {
        case .calm: return 0
        case .light: return 5
        case .moderate: return 10
        case .strong: return 15
        case .veryStrong: return 20
        }
    }

    public var displayName: String {
        switch self {
        case .calm: return "Calm"
        case .light: return "Light (5 mph)"
        case .moderate: return "Moderate (10 mph)"
        case .strong: return "Strong (15 mph)"
        case .veryStrong: return "Very strong (20 mph)"
        }
    }
}

/// Where the wind comes **from**, relative to the shot's target line: eight directions a golfer can
/// feel on their face and ears.
public enum WindDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case into, intoFromRight, fromRight, helpingFromRight, helping, helpingFromLeft, fromLeft, intoFromLeft

    public var id: String { rawValue }
    /// Clockwise angle from the target direction to the direction the wind comes from.
    public var angleDeg: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0) * 45
    }

    public var displayName: String {
        switch self {
        case .into: return "Into you"
        case .intoFromRight: return "Into you, from the right"
        case .fromRight: return "From the right"
        case .helpingFromRight: return "Behind you, from the right"
        case .helping: return "Behind you (helping)"
        case .helpingFromLeft: return "Behind you, from the left"
        case .fromLeft: return "From the left"
        case .intoFromLeft: return "Into you, from the left"
        }
    }
}

/// Wind entered by the golfer, stored as an absolute true bearing so it stays correct as they move
/// around the course and the target line changes.
public struct WindInput: Codable, Equatable, Sendable {
    public var strength: WindStrength
    /// True bearing the wind blows **from**, degrees.
    public var fromBearingDeg: Double
    public var enteredAt: Date

    /// Wind older than this is treated as unknown (it changes through a round).
    public static let maxAge: TimeInterval = 2 * 3600

    public init(strength: WindStrength, fromBearingDeg: Double, enteredAt: Date = Date()) {
        self.strength = strength
        self.fromBearingDeg = Units.normalizeBearing(fromBearingDeg)
        self.enteredAt = enteredAt
    }

    /// From a golfer's description, relative to the target line they are facing.
    public init(strength: WindStrength, direction: WindDirection, targetBearingDeg: Double, enteredAt: Date = Date()) {
        self.init(strength: strength, fromBearingDeg: targetBearingDeg + direction.angleDeg, enteredAt: enteredAt)
    }

    public var speedMetersPerSecond: Double { Units.metersPerSecond(fromMph: strength.mph) }

    public func isStale(at now: Date = Date()) -> Bool { now.timeIntervalSince(enteredAt) > Self.maxAge }

    /// Wind velocity in the physics frame of a camera with the given heading (x forward, y left, z up).
    public func vector(cameraHeadingDeg: Double) -> Vector3 {
        let towards = fromBearingDeg + 180
        let rel = Units.radians(towards - cameraHeadingDeg) // clockwise from forward
        let s = speedMetersPerSecond
        return Vector3(s * cos(rel), -s * sin(rel), 0)
    }

    /// Headwind component for a shot on the given bearing, mph (+ = into the golfer, − = helping).
    public func headwindMph(shotBearingDeg: Double) -> Double {
        strength.mph * cos(Units.radians(fromBearingDeg - shotBearingDeg))
    }

    /// Spoken confirmation relative to a target bearing.
    public func description(targetBearingDeg: Double) -> String {
        guard strength != .calm else { return "Wind calm." }
        let rel = Units.normalizeBearing(fromBearingDeg - targetBearingDeg)
        let dir = WindDirection.allCases[Int((rel / 45).rounded()) % 8]
        return "Wind \(strength.displayName.lowercased()), \(dir.displayName.lowercased())."
    }
}
