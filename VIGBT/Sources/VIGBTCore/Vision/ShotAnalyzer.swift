import Foundation

/// Camera orientation helpers shared by calibration (ARKit/CoreMotion) and the extractor.
public enum CameraPose {
    /// Pitch and roll from the gravity direction expressed in the camera frame
    /// (+x image right, +y image down, +z along the optical axis). Any magnitude.
    /// Inverse of `LaunchVectorExtractor.level`: levelling this vector yields (0, 1, 0).
    public static func pitchAndRoll(gravityInCamera g: Vector3) -> (pitch: Double, roll: Double) {
        let n = g.normalized
        let pitch = asin(min(1, max(-1, -n.z)))
        let roll = atan2(n.x, n.y)
        return (pitch, roll)
    }

    /// True-north heading of a horizontal direction given its East and North components.
    public static func heading(east: Double, north: Double) -> Double {
        Units.normalizeBearing(Units.degrees(atan2(east, north)))
    }

    /// Expected ball radius in pixels at the tee: f · R_ball / D_tee.
    public static func expectedBallRadiusPixels(calibration: TeeCalibration,
                                                ballRadiusMeters: Double = 0.021335) -> Double {
        calibration.focalLengthPixels * ballRadiusMeters / calibration.distanceToTeeMeters
    }
}

public struct ShotAnalysis: Sendable {
    public var centroids: [TrackedCentroid]
    public var launch: LaunchVector?
    public var spin: SpinEstimate?
    public var trajectory: TrajectorySolution?
    public var landing: LandingEstimate?
    /// Human-readable reason when the launch could not be measured (spoken to the user).
    public var failureReason: String?

    public var succeeded: Bool { launch != nil }
}

/// Glue for Phases 1.3 → 2: size-gate candidates, track, extract the launch vector and,
/// when entitled, run ballistics and projection.
public struct ShotAnalyzer: Sendable {
    public var tracker: BallTracker
    public var extractor: LaunchVectorExtractor
    public var estimator: LandingZoneEstimator
    /// Candidates whose radius falls outside [min, max] × expected tee radius are discarded.
    /// The lower bound is generous because a ball flying away from the lens shrinks quickly.
    public var radiusGate: ClosedRange<Double>

    public init(tracker: BallTracker = BallTracker(), extractor: LaunchVectorExtractor = LaunchVectorExtractor(),
                estimator: LandingZoneEstimator = LandingZoneEstimator(), radiusGate: ClosedRange<Double> = 0.2...2.5) {
        self.tracker = tracker
        self.extractor = extractor
        self.estimator = estimator
        self.radiusGate = radiusGate
    }

    public func sizeGate(_ candidates: [DetectionCandidate], expectedRadius: Double) -> [DetectionCandidate] {
        let lo = max(0.75, radiusGate.lowerBound * expectedRadius)
        let hi = radiusGate.upperBound * expectedRadius
        return candidates.filter { $0.radiusPixels >= lo && $0.radiusPixels <= hi }
    }

    /// - Parameters:
    ///   - frames: candidates for frames T0+1, T0+2, …
    ///   - referenceRadiusPixels: ball radius measured on the tee before impact, if available.
    ///   - includeBallistics: false on the free tier (launch readout only).
    public func analyze(frames: [[DetectionCandidate]], calibration: TeeCalibration,
                        referenceRadiusPixels: Double?, includeBallistics: Bool,
                        spin: SpinEstimate? = nil, wind: Vector3 = .zero) -> ShotAnalysis {
        let expected = referenceRadiusPixels ?? CameraPose.expectedBallRadiusPixels(calibration: calibration)
        let gated = frames.map { sizeGate($0, expectedRadius: expected) }
        let track = tracker.track(frames: gated)
        var result = ShotAnalysis(centroids: track)
        do {
            let launch = try extractor.extract(centroids: track, calibration: calibration,
                                               referenceRadiusPixels: referenceRadiusPixels)
            guard launch.ballSpeed.isFinite, launch.ballSpeed > 3, launch.launchAngleDeg > -5 else {
                result.failureReason = "The ball's launch could not be measured reliably. Please try again."
                return result
            }
            result.launch = launch
            if includeBallistics {
                let est = estimator.estimate(launch: launch, calibration: calibration, spin: spin, wind: wind)
                result.spin = est.spin
                result.trajectory = est.trajectory
                result.landing = est.landing
            }
        } catch LaunchVectorExtractor.ExtractionError.insufficientPoints(let found, _) {
            result.failureReason = found == 0
                ? "The ball was not seen leaving the tee. Check the camera view and lighting."
                : "The ball was only seen in \(found) frames. Move the tripod closer or improve lighting."
        } catch {
            result.failureReason = "The ball's launch could not be measured. Please try again."
        }
        return result
    }
}

// MARK: - Spoken readouts

public enum Readout {
    /// Whole-number rendering without `String(format:)` + `%@`, which is not portable to Linux.
    static func whole(_ x: Double) -> String { String(Int(x.rounded())) }

    public static func launch(_ l: LaunchVector) -> String {
        let side = abs(l.azimuthDeg) < 1 ? "straight"
            : "\(whole(abs(l.azimuthDeg))) degrees \(l.azimuthDeg > 0 ? "right" : "left")"
        return "Ball speed \(whole(l.ballSpeedMph)) miles per hour. "
            + "Launch angle \(whole(l.launchAngleDeg)) degrees. Direction \(side)."
    }

    public static func landing(_ l: LandingEstimate) -> String {
        let carry = Units.yards(fromMeters: l.carryMeters)
        let lateral = Units.yards(fromMeters: l.lateralMeters)
        let radius = Units.yards(fromMeters: l.searchRadiusMeters)
        let side = abs(lateral) < 2 ? "on line" : "\(whole(abs(lateral))) yards \(lateral > 0 ? "right" : "left")"
        return "Estimated carry \(whole(carry)) yards, \(side). Search zone plus or minus \(whole(radius)) yards."
    }

    public static func distance(yards: Double) -> String {
        "\(whole(max(0, yards))) yards to go"
    }
}
