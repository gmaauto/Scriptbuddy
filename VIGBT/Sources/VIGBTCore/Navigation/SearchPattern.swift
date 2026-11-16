import Foundation

/// Guided search inside the search ellipse (SPEC §12.7).
///
/// Along-line errors are about twice the lateral ones (§12.3), and the golfer approaches from the tee, so
/// half of all balls lie *short* of the predicted rest point. Walking to the centre with the scanner off
/// passes many of them. The pattern instead starts scanning at the near end of the ellipse, walks the long
/// axis to the far end, then sweeps lanes `2 × sweepHalfWidth` apart, alternating sides, out to 1.25× the
/// ellipse half-width.
///
/// Search study (30,000 shots, shipped configuration, 6 m detection range for a pink ball): median walk in
/// the zone 43 m → 30 m and balls found within 250 m 88.1% → 90.0%, versus "walk to the centre, then
/// spiral". Walking past the ellipse ends made it worse.
public enum SearchPattern {
    /// Waypoint in the zone frame: metres along the flight line from the predicted rest point (+ = away
    /// from the tee) and across it (+ = right).
    public struct Leg: Equatable, Sendable {
        public var along: Double
        public var right: Double
        /// Spoken instruction on reaching the previous waypoint.
        public var instruction: String
    }

    /// - Parameters:
    ///   - halfLength / halfWidth: search ellipse semi-axes (m).
    ///   - sweepHalfWidth: width either side of the walking line the scanner reliably covers (≈ 0.7 × detection range).
    public static func legs(halfLength A: Double, halfWidth L: Double, sweepHalfWidth w: Double) -> [Leg] {
        let spacing = max(1, 2 * w)
        var legs = [Leg(along: -A, right: 0, instruction: "Search zone starts here. Scanning. Walk slowly straight ahead."),
                    Leg(along: A, right: 0, instruction: "Keep walking straight ahead, scanning from side to side.")]
        var k = 1, side = 1.0, xEnd = A
        while Double(k) * spacing <= 1.25 * L, legs.count < 40 {
            let y = side * Double(k) * spacing
            let turn = y > legs[legs.count - 1].right ? "right" : "left"
            legs.append(Leg(along: xEnd, right: y, instruction: "Turn \(turn) and walk \(Int((abs(y - legs[legs.count - 1].right)).rounded())) metres."))
            legs.append(Leg(along: -xEnd, right: y, instruction: "Turn \(turn == "right" ? "left" : "right") and walk back along the next lane, scanning."))
            xEnd = -xEnd
            if side < 0 { k += 1 }
            side = -side
        }
        return legs
    }

    /// Converts a zone-frame point to GPS. `bearingDeg` is the flight line's true bearing (tee → predicted rest).
    public static func coordinate(along: Double, right: Double, center: GeoCoordinate, bearingDeg: Double) -> GeoCoordinate {
        let d = (along * along + right * right).squareRoot()
        guard d > 1e-6 else { return center }
        return GeoMath.destination(from: center, distanceMeters: d,
                                   bearingDeg: bearingDeg + Units.degrees(atan2(right, along)))
    }
}

/// Steps the golfer through a `SearchPattern`.
public struct SearchGuide: Sendable {
    public let center: GeoCoordinate
    public let bearingDeg: Double
    public let legs: [SearchPattern.Leg]
    /// A waypoint counts as reached within this distance (GPS is ± 3–5 m).
    public var reachRadiusMeters: Double = 4
    public private(set) var index = 0

    public init(landing: LandingEstimate, tee: GeoCoordinate, detectionRangeMeters: Double) {
        center = landing.target.coordinate
        bearingDeg = GeoMath.bearing(from: tee, to: landing.target.coordinate)
        let A = landing.searchAlongMeters ?? landing.searchRadiusMeters
        let L = landing.searchLateralMeters ?? landing.searchRadiusMeters
        legs = SearchPattern.legs(halfLength: A, halfWidth: L, sweepHalfWidth: 0.7 * detectionRangeMeters)
    }

    /// Where to walk now (nil when the pattern is finished).
    public var currentWaypoint: GeoCoordinate? {
        guard index < legs.count else { return nil }
        return SearchPattern.coordinate(along: legs[index].along, right: legs[index].right, center: center, bearingDeg: bearingDeg)
    }

    /// The near end of the zone, where walking guidance should hand over to the search.
    public var entryPoint: GeoCoordinate { SearchPattern.coordinate(along: legs[0].along, right: 0, center: center, bearingDeg: bearingDeg) }

    public var isFinished: Bool { index >= legs.count }
    public var progressText: String { isFinished ? "Search pattern complete." : "Search leg \(index + 1) of \(legs.count)." }

    /// Advances past every waypoint the golfer has reached. Returns the instruction to speak, if any.
    public mutating func update(position: GeoCoordinate) -> String? {
        var spoken: String?
        while let wp = currentWaypoint, GeoMath.distance(from: position, to: wp) <= reachRadiusMeters {
            index += 1
            spoken = index < legs.count ? legs[index].instruction
                : "That completes the search pattern. Keep sweeping here, or go back to walking guidance."
        }
        return spoken
    }
}
