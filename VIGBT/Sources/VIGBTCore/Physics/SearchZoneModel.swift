import Foundation

/// Where a found ball actually was, relative to where it was predicted (meters, along the camera heading).
public struct LandingErrorSample: Equatable, Sendable {
    public var club: Club?
    public var predictedCarryMeters: Double
    /// + = ball found further than predicted.
    public var alongError: Double
    /// + = ball found further right than predicted.
    public var lateralError: Double
}

/// Learned correction for the landing zone: a carry bias, a lateral bias (both as fractions of carry) and
/// a search-radius factor replacing the fixed R_search = 0.08 × carry.
public struct SearchZoneCalibration: Codable, Equatable, Sendable {
    public var carryBias: Double
    public var lateralBias: Double
    public var radiusFactor: Double
    public var sampleCount: Int

    public static let uncalibrated = SearchZoneCalibration(carryBias: 0, lateralBias: 0, radiusFactor: 0.08, sampleCount: 0)

    public init(carryBias: Double, lateralBias: Double, radiusFactor: Double, sampleCount: Int) {
        self.carryBias = carryBias
        self.lateralBias = lateralBias
        self.radiusFactor = radiusFactor
        self.sampleCount = sampleCount
    }

    public func corrected(carry: Double, lateral: Double) -> (carry: Double, lateral: Double, radius: Double) {
        let c = carry * (1 + carryBias)
        return (c, lateral + lateralBias * carry, radiusFactor * c)
    }
}

/// Learns the golfer's real landing pattern from shots whose ball was found (Phase 4 lock position).
/// This is the ball-finder version of the per-club dispersion patterns commercial golf apps show:
/// every found ball is ground truth for the prediction.
public enum SearchZoneModel {
    /// Minimum found balls before a calibration replaces the default.
    public static let minimumSamples = 5
    /// Radius covers this fraction of past misses (after bias removal).
    public static let coverage = 0.8
    public static let radiusFactorBounds: ClosedRange<Double> = 0.04...0.20
    /// Bias is capped so a few odd shots cannot drag the prediction far.
    public static let maxBias = 0.15

    public static func samples(from shots: [ShotRecord]) -> [LandingErrorSample] {
        shots.compactMap { s -> LandingErrorSample? in
            guard s.isSimulated != true, let landing = s.landing, let found = s.foundLocation,
                  landing.carryMeters > 20 else { return nil }
            let tee = s.calibration.teeLocation
            let o = GeoMath.enuOffset(of: found, from: tee)
            let h = Units.radians(s.calibration.cameraHeadingDeg)
            // Along the camera heading, and to its right.
            let along = o.east * sin(h) + o.north * cos(h)
            let right = o.east * cos(h) - o.north * sin(h)
            return LandingErrorSample(club: s.club, predictedCarryMeters: landing.carryMeters,
                                      alongError: along - landing.carryMeters,
                                      lateralError: right - landing.lateralMeters)
        }
    }

    /// Calibration for a club category, falling back to all clubs, then to the default.
    public static func calibration(for club: Club?, shots: [ShotRecord], window: Int = 20) -> SearchZoneCalibration {
        let recent = shots.sorted { $0.capturedAt > $1.capturedAt }
        let all = samples(from: recent)
        let forClub = all.filter { club != nil && $0.club == club }
        let use = forClub.count >= minimumSamples ? Array(forClub.prefix(window)) : Array(all.prefix(window))
        guard use.count >= minimumSamples else { return .uncalibrated }

        let along = use.map { $0.alongError / $0.predictedCarryMeters }
        let lateral = use.map { $0.lateralError / $0.predictedCarryMeters }
        let carryBias = clamp(median(along), -maxBias, maxBias)
        let lateralBias = clamp(median(lateral), -maxBias, maxBias)
        let residuals = zip(along, lateral).map { a, l in
            ((a - carryBias) * (a - carryBias) + (l - lateralBias) * (l - lateralBias)).squareRoot()
        }.sorted()
        let idx = min(residuals.count - 1, Int((Double(residuals.count) * coverage).rounded(.up)) - 1)
        let factor = clamp(residuals[max(0, idx)], radiusFactorBounds.lowerBound, radiusFactorBounds.upperBound)
        return SearchZoneCalibration(carryBias: carryBias, lateralBias: lateralBias, radiusFactor: factor,
                                     sampleCount: use.count)
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }
}
