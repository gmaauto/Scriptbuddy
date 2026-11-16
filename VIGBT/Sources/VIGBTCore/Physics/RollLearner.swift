import Foundation

/// Learns how far balls are rolling **today, on this course** (SPEC §12.6).
///
/// Ground firmness changes with weather, mowing and the season, and the camera cannot see it; after the
/// compass, roll was the largest remaining error (§12.4). Each found ball shows the roll that actually
/// happened: its position along the predicted roll direction, measured from the predicted landing point,
/// divided by the roll the nominal `GroundModel` predicted. The learner keeps the geometric mean of these
/// ratios with a shrinkage prior (`priorShots` pseudo-shots at 1.0) and clamps each ratio to 0.2–3.
///
/// Monte Carlo (one firmness per 30-shot round, ±25% per shot, 30% of balls in rough): p90 error
/// 34.9 → 30.7 yd and search coverage 86.3% → 88.2%.
public struct RollLearner: Codable, Equatable, Sendable {
    public var priorShots: Double = 2
    /// Predicted rolls shorter than this say little about firmness and are ignored.
    public var minimumRollMeters: Double = 4
    public var ratioBounds: ClosedRange<Double> = 0.2...3.0
    private(set) var sumLog: Double = 0
    private(set) var count: Int = 0

    public init() {}

    /// Multiplier for the nominal roll (1 = medium-firm fairway).
    public var multiplier: Double { exp(sumLog / (Double(count) + priorShots)) }
    public var observations: Int { count }

    /// - Parameters, all in the shot's local frame (metres along the camera heading, + right):
    ///   - landing: predicted landing point.
    ///   - nominalRest: rest point the nominal ground model predicted (before any multiplier).
    ///   - found: where the ball was actually found.
    public mutating func record(landing: (along: Double, right: Double), nominalRest: (along: Double, right: Double),
                                found: (along: Double, right: Double)) {
        let dx = nominalRest.along - landing.along, dy = nominalRest.right - landing.right
        let predicted = (dx * dx + dy * dy).squareRoot()
        guard predicted >= minimumRollMeters else { return }
        let observed = ((found.along - landing.along) * dx + (found.right - landing.right) * dy) / predicted
        let ratio = min(ratioBounds.upperBound, max(ratioBounds.lowerBound, observed / predicted))
        sumLog += log(ratio)
        count += 1
    }
}

/// Converts between GPS coordinates and a shot's local frame (metres along the camera heading, + right).
public enum ShotFrame {
    public static func local(_ c: GeoCoordinate, tee: GeoCoordinate, headingDeg: Double) -> (along: Double, right: Double) {
        let o = GeoMath.enuOffset(of: c, from: tee)
        let h = Units.radians(headingDeg)
        return (o.east * sin(h) + o.north * cos(h), o.east * cos(h) - o.north * sin(h))
    }
}
