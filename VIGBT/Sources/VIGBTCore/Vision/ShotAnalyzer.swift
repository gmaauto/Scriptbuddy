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
    /// Reprojection fit used whenever the resting ball on the tee was seen (SPEC §12).
    public var fitter: ReprojectionFitter = ReprojectionFitter()
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
                        club: Club = .auto, spin: SpinEstimate? = nil, wind: Vector3 = .zero,
                        zone: SearchZoneCalibration? = nil, restingBall: DetectionCandidate? = nil,
                        compassAndWindCorrected: Bool = false, rollMultiplier: Double = 1,
                        surfaceMap: SurfaceMap? = nil) -> ShotAnalysis {
        let expected = referenceRadiusPixels ?? CameraPose.expectedBallRadiusPixels(calibration: calibration)
        let gated = frames.map { sizeGate($0, expectedRadius: expected) }
        let track = tracker.track(frames: gated)
        var result = ShotAnalysis(centroids: track)
        do {
            var launch = try extractor.extract(centroids: track, calibration: calibration,
                                               referenceRadiusPixels: referenceRadiusPixels)
            var fittedSpin: SpinEstimate?
            if let tee = restingBall {
                // Refine with the tee-anchored reprojection fit; it also recovers the spin axis from curvature.
                let prior = (spin ?? SpinEstimator.estimate(club: club, launchAngleDeg: launch.launchAngleDeg)).rpm
                if let fit = fitter.fit(centroids: track, tee: (tee.centerX, tee.centerY), calibration: calibration,
                                        initial: launch, spinPrior: prior) {
                    launch = fit.launch
                    fittedSpin = fit.spin
                }
            }
            guard launch.ballSpeed.isFinite, launch.ballSpeed > 3, launch.launchAngleDeg > -5 else {
                result.failureReason = "The ball's launch could not be measured reliably. Please try again."
                return result
            }
            result.launch = launch
            if includeBallistics {
                let spin = spin ?? fittedSpin ?? SpinEstimator.estimate(club: club, launchAngleDeg: launch.launchAngleDeg)
                var estimator = estimator
                estimator.compassAndWindCorrected = compassAndWindCorrected
                estimator.rollMultiplier = rollMultiplier
                let est = estimator.estimate(launch: launch, calibration: calibration, spin: spin, wind: wind, zone: zone,
                                             surfaceMap: surfaceMap)
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

// MARK: - Simulated shots

/// Generates a physically consistent fake shot (calibration + per-frame detections) so the full
/// pipeline, replay, navigation and paywall can be exercised in the iOS Simulator or without a ball.
public enum ShotSimulator {
    public struct Output: Sendable {
        public var calibration: TeeCalibration
        public var frames: [[DetectionCandidate]]
        public var referenceRadiusPixels: Double
    }

    /// Down-the-line tripod: 1.1 m high, tee 3 m ahead and slightly right, Ultra-Wide 108° FOV.
    public static func make(launch: LaunchVector, teeLocation: GeoCoordinate, cameraHeadingDeg: Double,
                            frames: Int = 16) -> Output {
        let teeWorld = Vector3(3.0, -0.25, -1.1)
        let pitch = -atan2(1.1, 3.0)
        var cal = TeeCalibration(distanceToTeeMeters: 1, cameraPitchRadians: pitch, cameraRollRadians: 0,
                                 cameraHeadingDeg: cameraHeadingDeg, horizontalFOVRadians: Units.radians(108),
                                 teeLocation: teeLocation)
        let synth = LaunchVectorExtractor.synthesizeCentroids(launch: launch, calibration: cal,
                                                              teeWorldPosition: teeWorld, frames: 1...frames)
        cal.distanceToTeeMeters = cal.focalLengthPixels * 0.021335 / synth.referenceRadius
        let detections: [[DetectionCandidate]] = synth.centroids.map { c in
            let inFrame = c.x >= 0 && c.x < cal.imageWidth && c.y >= 0 && c.y < cal.imageHeight
            let ball = DetectionCandidate(centerX: c.x, centerY: c.y, width: 2 * c.radiusPixels,
                                          height: 2 * c.radiusPixels, colorMatchFraction: 0.9)
            // The vacated tee spot and the club head always show up in the motion mask too.
            let teeSpot = DetectionCandidate(centerX: synth.centroids[0].x - 40, centerY: synth.centroids[0].y + 30,
                                             width: 2 * synth.referenceRadius, height: 2 * synth.referenceRadius,
                                             colorMatchFraction: 0.1)
            let club = DetectionCandidate(centerX: cal.imageWidth / 2, centerY: cal.imageHeight * 0.8,
                                          width: 90, height: 40, colorMatchFraction: 0)
            return inFrame ? [club, teeSpot, ball] : [club]
        }
        return Output(calibration: cal, frames: detections, referenceRadiusPixels: synth.referenceRadius)
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
        let restOut = Units.yards(fromMeters: l.restCarry)
        let lateral = Units.yards(fromMeters: l.restLateral)
        let side = abs(lateral) < 2 ? "on line" : "\(whole(abs(lateral))) yards \(lateral > 0 ? "right" : "left")"
        var text = "Estimated carry \(whole(carry)) yards."
        switch l.landingSurface {
        case .water?: text += " It may have gone in the water."
        case let s? where s != .fairway: text += " It should land \(s.phrase)."
        default: break
        }
        if l.rollMeters >= Units.meters(fromYards: 2) {
            text += " It should stop about \(whole(restOut)) yards out, \(side)."
        } else {
            text += " It should stop close to where it lands, \(side)."
        }
        if let a = l.searchAlongMeters, let c = l.searchLateralMeters {
            text += " Search zone \(whole(Units.yards(fromMeters: a))) yards long and \(whole(Units.yards(fromMeters: c))) yards wide each way."
        } else {
            text += " Search zone plus or minus \(whole(Units.yards(fromMeters: l.searchRadiusMeters))) yards."
        }
        return text
    }

    /// Compact on-screen form, e.g. "152 yd".
    public static func distanceShort(meters: Double) -> String {
        "\(whole(Units.yards(fromMeters: max(0, meters)))) yd"
    }

    public static func distance(yards: Double) -> String {
        "\(whole(max(0, yards))) yards to go"
    }
}
