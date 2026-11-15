import Foundation

/// Minimal 3-component vector so the core does not depend on `simd` (unavailable on Linux).
///
/// World frame used by the physics engine (right-handed):
/// - `x`: downrange, along the camera's horizontal heading ψ_camera
/// - `y`: to the golfer's LEFT when looking downrange
/// - `z`: up
/// Public APIs report lateral offsets as *positive = right* and convert at the boundary.
public struct Vector3: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vector3(0, 0, 0)
    public static let up = Vector3(0, 0, 1)

    public var length: Double { (x * x + y * y + z * z).squareRoot() }

    public var normalized: Vector3 {
        let l = length
        return l > 0 ? self / l : .zero
    }

    public func dot(_ o: Vector3) -> Double { x * o.x + y * o.y + z * o.z }

    public func cross(_ o: Vector3) -> Vector3 {
        Vector3(y * o.z - z * o.y,
                z * o.x - x * o.z,
                x * o.y - y * o.x)
    }

    public static func + (a: Vector3, b: Vector3) -> Vector3 { Vector3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vector3, b: Vector3) -> Vector3 { Vector3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vector3, s: Double) -> Vector3 { Vector3(a.x * s, a.y * s, a.z * s) }
    public static func * (s: Double, a: Vector3) -> Vector3 { a * s }
    public static func / (a: Vector3, s: Double) -> Vector3 { Vector3(a.x / s, a.y / s, a.z / s) }
    public static prefix func - (a: Vector3) -> Vector3 { Vector3(-a.x, -a.y, -a.z) }
}

// MARK: - Unit helpers

public enum Units {
    public static let metersPerYard = 0.9144
    public static let metersPerSecondPerMph = 0.44704

    @inlinable public static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
    @inlinable public static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    @inlinable public static func yards(fromMeters m: Double) -> Double { m / metersPerYard }
    @inlinable public static func meters(fromYards y: Double) -> Double { y * metersPerYard }
    @inlinable public static func mph(fromMetersPerSecond v: Double) -> Double { v / metersPerSecondPerMph }
    @inlinable public static func metersPerSecond(fromMph v: Double) -> Double { v * metersPerSecondPerMph }

    /// Wraps any angle in degrees into [0, 360).
    @inlinable public static func normalizeBearing(_ deg: Double) -> Double {
        let r = deg.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Wraps any angle in degrees into (-180, 180].
    @inlinable public static func signedAngle(_ deg: Double) -> Double {
        let r = normalizeBearing(deg)
        return r > 180 ? r - 360 : r
    }
}
