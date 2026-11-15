import Foundation

/// How the ground treats a landing ball (SPEC §12). Defaults are a medium-firm fairway.
public struct GroundModel: Codable, Equatable, Sendable {
    /// Vertical coefficient of restitution per bounce.
    public var restitution: Double = 0.35
    /// Friction impulse coefficient at each bounce (removes horizontal speed).
    public var bounceFriction: Double = 0.5
    /// Rolling-resistance coefficient once bouncing stops (fairway ≈ 0.15–0.25, rough ≈ 0.4).
    public var rollingFriction: Double = 0.25

    public init() {}

    public init(restitution: Double, bounceFriction: Double, rollingFriction: Double) {
        self.restitution = restitution
        self.bounceFriction = bounceFriction
        self.rollingFriction = rollingFriction
    }
}

/// Simplified bounce-and-roll (impulse bounces, then rolling friction). Golfers search for the ball
/// where it *stops*, not where it lands: the Monte Carlo run (§12) showed a driver often finishing
/// 15–25 yd past its landing point, which alone put most balls outside the old landing-point circle.
public enum RollModel {
    /// - Parameters:
    ///   - landing: landing point in the physics frame (z ignored).
    ///   - velocity: velocity at landing.
    /// - Returns: rest point (z = 0).
    public static func rest(landing: Vector3, velocity: Vector3, ground: GroundModel = GroundModel()) -> Vector3 {
        var vh = (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot()
        guard vh > 1e-9 else { return Vector3(landing.x, landing.y, 0) }
        let dir = Vector3(velocity.x / vh, velocity.y / vh, 0)
        var vz = abs(velocity.z)
        var travel = 0.0
        let g = 9.80665
        for _ in 0..<8 {
            vh = max(0, vh - ground.bounceFriction * (1 + ground.restitution) * vz)
            vz *= ground.restitution
            travel += vh * 2 * vz / g
            if vz < 0.5 { break }
        }
        travel += vh * vh / (2 * ground.rollingFriction * g)
        return Vector3(landing.x + dir.x * travel, landing.y + dir.y * travel, 0)
    }
}
