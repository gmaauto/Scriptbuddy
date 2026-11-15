import Foundation

/// Compass error handling (SPEC §12.4). The phone compass is the largest error the golfer cannot see:
/// ±3° is ≈ 10 yd sideways at 200 yd, and steel carts, phone cases and pins make it worse. Two fixes,
/// which can be combined:
///
/// - **Sighting** (`CompassCorrection.sightingError`): at setup, aim the tripod camera at the flag. ARKit
///   tracks the rotation between the flag and the tee precisely, so the only error left is the GPS bearing
///   of the tee→flag line (≈ 1–2° at 100–220 m).
/// - **Self-correction** (`SessionCompassLearner`): every ball found from the same tripod setup shows the
///   heading error directly (the bearing to the found ball versus the predicted one). Needs no helper.
///
/// Monte Carlo (§12.5): coverage 84% → 90% with either method; with entered wind as well, 91%, which lets
/// the search ellipse shrink by 35% at 85% coverage.
public enum CompassCorrection {
    /// Circular mean of headings, degrees [0, 360).
    public static func circularMean(_ degs: [Double]) -> Double? {
        guard !degs.isEmpty else { return nil }
        let s = degs.reduce(0) { $0 + sin(Units.radians($1)) }
        let c = degs.reduce(0) { $0 + cos(Units.radians($1)) }
        return Units.normalizeBearing(Units.degrees(atan2(s, c)))
    }

    /// Circular standard deviation, degrees. Large spread → magnetic interference or an uncalibrated compass.
    public static func circularSpread(_ degs: [Double]) -> Double {
        guard degs.count > 1 else { return 0 }
        let n = Double(degs.count)
        let s = degs.reduce(0) { $0 + sin(Units.radians($1)) } / n
        let c = degs.reduce(0) { $0 + cos(Units.radians($1)) } / n
        let r = min(1, max(1e-12, (s * s + c * c).squareRoot()))
        return Units.degrees((-2 * log(r)).squareRoot())
    }

    /// Heading readings must agree within this spread before the calibration is trusted.
    public static let maxSpreadDeg = 4.0

    /// Compass error measured by sighting the flag: compass reading minus the true bearing tee → flag.
    /// Subtract it from compass headings in the same AR session.
    public static func sightingError(sightedHeadingDeg: Double, tee: GeoCoordinate, flag: GeoCoordinate) -> Double {
        Units.signedAngle(sightedHeadingDeg - GeoMath.bearing(from: tee, to: flag))
    }
}

/// Learns the compass error of one tripod setup from the balls found from it.
///
/// After a found ball, (bearing to the predicted rest − bearing to the found ball) equals the compass error
/// still uncorrected plus that shot's own sideways error. Averaging with a shrinkage prior (`shrinkage`
/// pseudo-observations at zero) and clamping outliers converges on the setup's error within a few shots.
public struct SessionCompassLearner: Codable, Equatable, Sendable {
    public var shrinkage: Double = 1
    public var outlierClampDeg: Double = 12
    /// Shots shorter than this say little about angle and are ignored.
    public var minimumDistanceMeters: Double = 30
    private(set) var sum: Double = 0
    private(set) var weight: Double = 0

    public init() {}

    /// Current estimate of the compass error to subtract from raw headings, degrees.
    public var errorDeg: Double { weight == 0 ? 0 : sum / (weight + shrinkage) }
    public var observationWeight: Double { weight }
    /// True once a sighting or at least one found ball has informed the estimate.
    public var isCorrected: Bool { weight > 0 }

    /// Seeds the estimate from a flag sighting, which counts as several found balls.
    public mutating func addSighting(errorDeg: Double, weight w: Double = 3) {
        sum += w * Units.signedAngle(errorDeg)
        weight += w
    }

    /// - Parameters:
    ///   - appliedErrorDeg: the correction that was subtracted when this shot was predicted.
    public mutating func recordFoundBall(tee: GeoCoordinate, predicted: GeoCoordinate, found: GeoCoordinate,
                                         appliedErrorDeg: Double) {
        guard GeoMath.distance(from: tee, to: found) >= minimumDistanceMeters,
              GeoMath.distance(from: tee, to: predicted) >= minimumDistanceMeters else { return }
        let observed = Units.signedAngle(GeoMath.bearing(from: tee, to: predicted) - GeoMath.bearing(from: tee, to: found))
        let estimate = min(outlierClampDeg, max(-outlierClampDeg, observed + appliedErrorDeg))
        sum += estimate
        weight += 1
    }

    /// Raw compass heading → corrected heading.
    public func corrected(_ rawHeadingDeg: Double) -> Double {
        Units.normalizeBearing(rawHeadingDeg - errorDeg)
    }
}
